@tool
extends EditorPlugin

# WMT Terrain editor plugin.
# Shows a "Terrain" bottom-panel tab (wireframe toggle + chunk placement) and,
# whenever a WMT node is selected, draws a circle cursor in the 3D editor
# viewport that follows the mouse over the terrain surface.
#
# A WMT node owns all of its chunks: clicking a ghost outline adds a new
# 256x256 chunk region to the same node (no child nodes), sculpting flows
# seamlessly across the whole grid. Wireframe is drawn on the terrain surface
# itself via a shader override (wireframe_overlay.gdshader), so it follows
# sculpting and grid changes automatically with no second mesh to manage.

const WmtScript = preload("res://wmt/wmt.gd")
const TerrainPanelScene = preload("res://addons/terrain_editor/terrain_editor_panel.tscn")
const TerrainModesScript = preload("res://addons/terrain_editor/terrain_editor_modes.gd")
const TerrainToolbarScript = preload("res://addons/terrain_editor/terrain_editor_toolbar.gd")
const UNDO_FILE := "user://wmt_undo_history.txt"
const UNDO_FILE_LIMIT := 100

# Wireframe is drawn ON the terrain itself — no separate line mesh. The
# wireframe_overlay.gdshader re-derives each fragment's grid cell from its
# interpolated local position (WMT local coords lie exactly on the absolute
# cell lattice) and lightens the true cell borders + X diagonals, which are
# exactly the terrain's real triangle edges. Toggling just swaps the node's
# material_override between the overlay shader and a flat material; there is
# nothing to keep in sync when sculpting or resizing, and hidden/absent cells
# simply have no rasterized fragments.
const TerrainOverlayShaderPath := "res://addons/terrain_editor/terrain_overlay.gdshader"

var panel: Control
var terrain: WmtScript
var wireframe_on := false
# Wireframe grid styling: white (false) or black (true) edges, and thickness
# in edge_width shader units (0 = hairline).
var wireframe_black := false
var wireframe_thickness := 1.0
# Brush cursor styling (Settings page): both brush rings share one color and
# one world-unit thickness, and drape flat on the terrain surface like the
# wireframe lines instead of a physical band.
var brush_color := Color(1.0, 0.3, 0.25)
var brush_thickness := 0.2
# Extra overlay layers (floating toolbar toggles): colored WMT (tile) lattice
# every SQUARES_PER_TILE cells, chunk lattice every CHUNK_CELLS cells, and the
# scene's directional light ("WMT Sun") that lights the terrain.
var wmt_lines_on := false
var chunk_lines_on := false
# The toolbar "shading" toggle now just switches the scene's directional light
# (the "WMT Sun") on and off: the terrain itself is always lit by Godot's real
# lights/environment, so this button toggles the light source.
var shading_on := false
# Manual override for the vertex-tint (painted light) overlay. Default ON so
# painted tints show until the user turns them off from the toolbar toggle.
var vertex_colors_on := true
# Properties applied to the scene's directional light node (live update from
# the Settings panel; persisted only so an auto-created light matches).
var sun_color := Color.WHITE
var sun_energy := 1.5
# Shadow distance (meters) and shadow atlas size index into
# TerrainEditorPanel.SHADOW_ATLAS_SIZES (0..3 = 2048..16384).
var sun_shadow_distance := 100.0
var sun_shadow_resolution := 2
# Thickness of the chunk/tile lattice lines, separate from the wireframe grid.
var tile_line_thickness := 1.0
# Off by default: a directional light's shadow cascades are re-fitted to the
# camera frustum every frame, so shadows visibly crawl/fade over the terrain as
# you orbit. Enable via the Lighting page when you want them.
var sun_shadow := false
# Environment (ambient / skylight) settings, applied to the edited scene's
# WorldEnvironment. The terrain is lit by real Godot lighting, so these are the
# only way to fill the light the sun does not reach.
var env_ambient_color := Color(0.42, 0.47, 0.55)
var env_ambient_energy := 1.0
var env_sky_energy := 0.5
# Lazy overlay material for the terrain-surface lines (see
# terrain_overlay.gdshader). Toggling swaps the node's material_override
# (the terrain's flat look follows the mesh automatically, and shader edges
# track the fragment lattice, so nothing else needs rebuilding). Persists
# across mesh rebuilds.
var _wireframe_mat: ShaderMaterial
# Height-field shading texture cache: keyed by (terrain, mesh) so it is only
# rebuilt when the surface actually changes. `mesh` is a new ArrayMesh instance
# after every rebuild_mesh(), so a pure height edit invalidates it exactly once.
# Stamp of the height lattice the cached atlas was built from. Mid-stroke
# height edits bump WMT's height_version without replacing the mesh instance,
# so comparing this here (not just the mesh identity) is what makes sculpt /
# set-height refresh the shading live.
var toolbar: TerrainToolbarScript
# Per-tile hide painting (Ctrl+LMB show / Ctrl+RMB hide in the tiles tab).
var hide_painting := false
var hide_value := false  # what the active hide press applies
# Latches a Shift+LMB hide/unhide press so the ONE toggle per press stays
# applied for the whole hold; cleared when the button is released.
var _hide_stroke_applied := false
# Set while a hide-paint drag has flipped tiles but the (expensive) overlay
# + ring re-drape is being deferred to stroke end.
var _tile_overlay_dirty := false
var _release_debounce := 0

# Basic paint tab state: selected splatmap channel index into
# WmtScript.PAINT_CHANNELS, brush opacity/flow (0..1) and the world-space
# stamp spacing. Stamping writes four independent R8 splat planes per tile,
# embedded in the .wmt file itself (v9), plus per-tile texture overrides,
# anchored per tile (no retroactive global combo).
var paint_channel := 0
# The paint TOOLBOX: one slot per splat channel. It is the "current colours"
# palette - shown in the channel popup and used as the brush definition and
# the default for tiles that have no mapping yet. Loading it from a tile via
# Ctrl+RMB reflects THAT tile's actual per-channel textures; assigning a
# texture anchors only the tile under the picker, never retroactively.
var paint_channel_textures: Array[String] = ["", "", "", ""]
var paint_channel_tilings: Array[float] = [16.0, 16.0, 16.0, 16.0]
var paint_channel_depths: Array[float] = [0.2, 0.2, 0.2, 0.2]
var paint_depth := 0.2
var paint_opacity := 1.0
var paint_flow := 1.0
var paint_spacing := 8.0
# Spray paint: while Shift+LMB is held the brush keeps stamping at the cursor
# even when it does not move, on a fixed time interval (seconds).
var paint_spray_on := true
var paint_spray_interval := 0.05
var paint_stroking := false
var _last_stamp_pos := Vector3.ZERO
var _paint_stroke_first := false
# Tile the paint cursor most recently stamped on: texture assignments from the
# panel / Shift+click picker anchor their per-tile override here.
var _last_painted_tile := Vector2i(-1, -1)
# Per-channel Texture2DArray + nearest layout atlas, rebuilt lazily when the
# tile->texture mapping changes (assignment, first paint on a fresh tile, undo).
var _paint_texture_atlas_dirty := true
var _chan_arrays: Array = []
var _chan_layouts: Array = []
# Reused backing images for the layout atlases (avoids reallocating + rebuilding
# a w*h image every fresh tile during a stroke; only the tile blocks are refilled).
var _chan_layout_imgs: Array = []
# Distinct-texture signature the cached arrays were built from; when only the
# tile->texture LAYOUT changed (fresh tile gaining a channel during a stroke)
# the expensive 512px layer packing is skipped.
var _atlas_paths_key := ""
# Resource existence is checked per (tile, slot) on every atlas rebuild; cache
# it so a long stroke doesn't hammer the resource loader.
var _path_exists_cache := {}
var _paint_dirty := false
var _spray_timer := 0.0
# Per-stroke undo snapshot: tile key -> pixels-or-null captured the first time
# a stroke touches that tile. Mirrors the same script's WmtScript state.
var _stroke_paint_before := {}
# Vertex-color paint (TAB_VERTEX_COLOR): strokes run like paint strokes but
# stamp terrain vertices (Shift+LMB). Per-stroke undo snapshot is a vertex
# texel index -> pre-stroke Color map, pushed like the paint steps.
var vertex_color := Color.WHITE
var vertex_strength := 0.2
var vertex_opacity := 1.0
var vertex_flow := 1.0
# Vertex brush sweep/spray, mirroring the paint brush: the stroke sub-divides
# the segment the mouse travelled (spacing) and keeps building at a stationary
# cursor (spray). Without these, flow had nothing to act on.
var vertex_spacing := 4.0
var vertex_spray_on := true
var vertex_spray_interval := 0.05
var _vertex_last_stamp_pos := Vector3.ZERO
var _vertex_spray_timer := 0.0
var _vertex_stroke_first := true
var vertex_stroking := false
var _stroke_tiles_before := {}
var _vertex_dirty := false
# Tile selection for paint mode: a set (Dictionary) of Vector2i tile keys.
# LMB toggles the tiles under the brush circle (drag spirals over new tiles),
# Alt+RMB handles the whole chunk under the cursor. Selected tiles get
# a 50% blue overlay, and with a selection a channel/texture change applies to
# EVERY selected tile (bulk assignment); with no selection it hits a single tile.
var _paint_selected := {}
# Tiles already toggled during the current selection drag, so a sweep toggles
# each tile it passes over exactly once instead of flickering on held frames.
var _sel_drag_touched := {}
# WMT hide/unhide brush stroke. `_wmt_drag_touched` keeps a tile from toggling
# twice when the brush dwells on it, `_wmt_drag_snap` is the single undo snapshot
# taken before the stroke's FIRST toggle (so one drag is one undo step, not one
# per tile), and `_wmt_drag_chunks` collects the dirty chunks to save once.
var _wmt_drag_touched := {}
var _wmt_drag_chunks := {}
var _wmt_drag_snap: Variant = null
var _wmt_drag_dirty := false
# True while the left button is held after a press that landed ON the terrain in
# an editing mode. The editor's Select tool drags any SELECTED node, and the
# terrain is selected in every editing mode (see _sync_selection_to_mode), so an
# accidental drag used to shove the whole terrain around. Consuming the press
# and every event until the button is released stops the editor from ever
# starting that drag, while clicks on anything else still reach it.
var _terrain_drag_guard := false
# The terrain transform captured when the guard went up, so a drag the editor
# started anyway can be undone on release.
var _terrain_drag_xform := Transform3D.IDENTITY
# Set when a chunk delete removed a .wmt file: the editor's filesystem VFS only
# learns about deletions from a scan(), and scanning synchronously in the delete
# frame is what used to freeze the editor, so the scan is deferred to the next
# idle _process instead.
var _pending_fs_scan := false
var _autosave_popup: AcceptDialog
var _autosave_accum := 0.0
const AUTOSAVE_INTERVAL := 600.0
# Objects mode must not select or move the terrain. The editor's Select tool owns
# LMB in that mode, so with the terrain selected any stray drag shoves the whole
# world around; and selecting the terrain there is meaningless anyway (it is not
# an object the user is placing). The editor exposes no "unselectable" flag, so
# both are enforced from here: the selection is filtered per frame, and the
# transform is re-pinned to what it was when Objects mode was entered.
var _objects_mode_prev_sel: Array = []
var _objects_mode_fixing := false
var _objects_mode_xform := Transform3D.IDENTITY
var _objects_mode_xform_valid := false
# Alt state latched from the mouse events themselves. The Alt+LMB selection drag
# is driven by _process polling, and polling Input.is_key_pressed(KEY_ALT) can
# read false while a button is held even though the events that reach _input
# carry alt_pressed (the paint/select modifiers then disagree, and Alt+drag
# silently selects nothing). Mouse events are authoritative here, so remember
# Alt for as long as events keep arriving and let a short expiry plus the
# button release drop it again.
var _alt_latched := false
var _alt_latch_msec := 0
const _ALT_LATCH_MS := 400
# The tile targeted by the channel popup / eyedropper (Ctrl+RMB / Ctrl+LMB);
# also updated by plain brush strokes while painting.
var _picker_tile := Vector2i(-1, -1)
# Rebuild flags + backing images for the selection (blue) and non-paintable
# (red) overlays. Masks are R8 images on the tile lattice (one texel per tile),
# bound to the overlay shader and BLENDED over the base color.
var _side_sel_dirty := true
var _side_nopaint_dirty := true
var _sel_mask_img: Image = null
# Tile-lattice dimensions the cached sel/nopaint masks were built for; a change
# means the masks are the wrong size and must be rebuilt.
var _mask_tile_counts := Vector2i(-1, -1)
var _nopaint_mask_img: Image = null
var _sel_mask_tex: ImageTexture = null
var _nopaint_mask_tex: ImageTexture = null
var _paint_popup: PopupPanel = null
var _paint_popup_boxes: Array = []  # one Button per channel (texture preview / selection rim)
var _paint_popup_tilings: Array = []  # one SpinBox per channel (texture tiling)
var _paint_popup_depths: Array = []  # one SpinBox per channel (pinned masked depth)
var _paint_popup_syncing := false
# The vertex-paint color selector (Ctrl+RMB in the vertex-color tab). A real
# popup window, so an outside click closes it and the click that closes it can
# never start a paint stroke underneath.
var _vertex_color_popup: PopupPanel = null
var _vertex_color_picker: ColorPicker = null
var _vertex_color_syncing := false
# Texture picker: lists every image under res://tileset so any channel can map
# to a real texture instead of a flat color. Cached loads avoid re-reading.
var _texture_popup: PopupPanel = null
var _texture_list: ItemList = null
var _texture_picker_channel := 0
var _texture_search: LineEdit = null
# Persistent texture dock: a bottom-panel tab (right of the Shader Editor) that
# mirrors the popup picker. Both share the last-searched filter string plus the
# preview-size slider so the two never drift apart and both are remembered
# across sessions.
var _texture_dock: Control = null
var _texture_dock_search: LineEdit = null
var _texture_dock_list: ItemList = null
var _last_texture_search := ""
var _texture_preview_pct := 100.0
var _texture_cache: Dictionary = {}
var _tileset_entries: Array = []  # [{path, name}] sorted by path

var cursor_radius := 2.0
# Inner falloff circle as a fraction of cursor_radius. 0 = dot (cone-shaped
# brush), 1 = same as master circle (cylinder). The brush falloff morphs
# between linear (cone) at 0 and flat (cylinder) at 1, dome in the middle.
var falloff_ratio := 0.5
# Brush strength multiplier (Alt+scroll), in the 0.05..5.0 range where 1.0 is
# the default SCULPT_SPEED intensity. Applies to raise, lower and smoothing.
var sculpt_strength := 1.0
var cursor_local := Vector3.ZERO
var sculpting := false
var stroke_terrain: WmtScript
var sculpt_direction := 1.0
var smoothing := false
var ghost_keys := {}  # Vector2i key ("slot on the chunk lattice") -> true

var active_tab := 0
var modes: TerrainModesScript
var undo_stack: Array[Dictionary] = []
var redo_stack: Array[Dictionary] = []
var stroke_snapshot := {}
var stroke_changed := false
var stroke_touched_keys: Array = []  # chunk keys edited by the current stroke
var _selftest_mode := false
var _motion_spy_left := 40
var _scan_deferred := false
# Guards the deferred rescan below. The editor reloads a plugin by freeing the old
# instance while deferred calls aimed at it are still queued, and a queued
# Callable is not cancelled by that free. Re-entering a freed plugin is what
# crashed the editor during "Scanning for file changes", so every rescan is
# gated on the plugin still being alive and in the tree.
var _exiting := false
# Stroke recorder (see SCULPT_RECORD); collects edits per frame and dumps the
# last stroke to /tmp/wmt_sculpt_log.txt on release.
var sculpt_log: TerrainSculptLog = TerrainSculptLog.new()
var tile_mi: MeshInstance3D
var terrain_outline_mi: MeshInstance3D
var ghost_mi: MeshInstance3D
const UNDO_LIMIT := 100
# How far a near-white vertex-paint top layer is pushed past 1.0 (see the
# SUPER-WHITE note in terrain_overlay.gdshader). A full white stroke reads as
# blend 1.5, so white actually brightens light terrain instead of being a no-op.
# 0.0 restores the plain W3C blend.
const VERTEX_TINT_BOOST := 0.5

const TAB_WMT := 0
const TAB_ZONES := 1
const TAB_SCULPT := 2
const TAB_PAINT := 3
const TAB_VERTEX_COLOR := 4
const TAB_OBJECTS := 5
const TAB_SETTINGS := 6
# Sub-tools inside the Sculpt tab (set height is merged into it): the panel's
# Sculpt / Set Height / Smooth radio buttons drive this, so all three strokes
# share one tab.
const SCULPT_TOOL_SCULPT := 0
const SCULPT_TOOL_SET_HEIGHT := 1
const SCULPT_TOOL_SMOOTH := 2
var sculpt_tool := SCULPT_TOOL_SCULPT

# Sub-tools inside the Sculpt -> Smooth submode.
const SMOOTH_TOOL_RAISE := 0
const SMOOTH_TOOL_FLATTEN := 1
const SMOOTH_TOOL_SMOOTH := 2
const SMOOTH_TOOL_LOWER := 3
var smooth_tool := SMOOTH_TOOL_SMOOTH

func _is_sculpt_tab() -> bool:
	return active_tab == TAB_SCULPT and sculpt_tool == SCULPT_TOOL_SCULPT

func _is_set_height_tab() -> bool:
	return active_tab == TAB_SCULPT and sculpt_tool == SCULPT_TOOL_SET_HEIGHT

func _is_smooth_tab() -> bool:
	return active_tab == TAB_SCULPT and sculpt_tool == SCULPT_TOOL_SMOOTH

# Four fixed paint channels, each an independent alpha splat plane. The names
# shown in the paint page and the right-click channel popup.
const PAINT_CHANNEL_NAMES := [
	"R", "G", "B", "A",
]
# Common layer resolution for the per-channel Texture2DArrays (resized on
# build; the shader samples them tiled so this only needs to resolve fine
# detail, it is not per-tile-baked).
const TEX_LAYER_PX := 512

const TILES_LIFT := 0.05
const TERRAIN_LIFT := 0.15
const GHOST_LIFT := 0.5
const BAR_THICK := 0.3

const COL_TILE := Color(1, 0, 0)
const COL_TERRAIN := Color(0, 0, 1)
const COL_GHOST := Color(0, 0, 1)

const RP_TILE := 25
const RP_TERRAIN := 30
const RP_GHOST := 40

const CURSOR_RADIUS_MIN := 0.25
const CURSOR_RADIUS_MAX := 64.0
const CURSOR_RADIUS_STEP := 1.25
const FALLOFF_STEP := 0.05
const STRENGTH_STEP := 1.3

const SCULPT_SPEED := 8.0

# Stroke recorder: while true, every sculpt/smooth stroke is logged frame by
# frame (cursor position, step, each corner/center edit with before/after,
# dirty mesh-vertex count) and the last stroke is dumped to
# /tmp/wmt_sculpt_log.txt (plus res://debug/wmt_sculpt_log.txt) on release,
# along with a before/after ASCII height map of the affected region. Lets a
# remote debugger reconstruct exactly what moved during a "sculpt glitch".
const SCULPT_RECORD := true

func _enter_tree() -> void:
	panel = TerrainPanelScene.instantiate()
	add_control_to_dock(EditorPlugin.DOCK_SLOT_RIGHT_UL, panel)

	_load_settings()
	if panel != null and panel.has_method("set_sun"):
		panel.set_sun(sun_color, sun_energy, sun_shadow)
	if panel != null and panel.has_method("set_shadow_extras"):
		panel.set_shadow_extras(sun_shadow_distance, sun_shadow_resolution)
	if panel != null and panel.has_method("set_tile_line_thickness"):
		panel.set_tile_line_thickness(tile_line_thickness)
	if panel != null and panel.has_method("set_env_state"):
		panel.set_env_state(env_ambient_color, env_ambient_energy, env_sky_energy)
	if panel != null and panel.get("object_browse_button") != null \
			and not panel.object_browse_button.pressed.is_connected(_open_object_picker):
		panel.object_browse_button.pressed.connect(_open_object_picker)
	if panel != null and panel.has_method("set_vertex_state"):
		panel.set_vertex_state(vertex_color, vertex_strength, vertex_opacity, vertex_flow)
		panel.set_vertex_brush_state(vertex_spacing, vertex_spray_on,
			vertex_spray_interval)
	_ensure_ring()
	# The editor viewport is recreated on boot and on scene changes, which
	# resets its debug_draw, so re-apply the current lighting state once it
	# exists.
	call_deferred("_apply_scene_lighting")
	# Pre-existing .wmt files on disk only show up in the FileSystem dock after
	# a save (because _save_terrain calls fs.update_file() per chunk). Run one
	# full scan after the editor finishes booting so they appear immediately.
	call_deferred("_refresh_filesystem")
	# The persistent texture dock attaches to the bottom panel; the editor must
	# be fully up before the tab is added, so defer it too.
	call_deferred("_ensure_texture_dock")

	if not EditorInterface.get_selection().selection_changed.is_connected(_on_selection_changed):
		EditorInterface.get_selection().selection_changed.connect(_on_selection_changed)
	if panel != null and not panel.wireframe_toggled.is_connected(_on_wireframe_toggled):
		panel.wireframe_toggled.connect(_on_wireframe_toggled)
	if panel != null and not panel.wireframe_color_changed.is_connected(_on_wireframe_color_changed):
		panel.wireframe_color_changed.connect(_on_wireframe_color_changed)
	if panel != null and not panel.wireframe_thickness_changed.is_connected(_on_wireframe_thickness_changed):
		panel.wireframe_thickness_changed.connect(_on_wireframe_thickness_changed)
	if panel != null and not panel.brush_color_changed.is_connected(_on_brush_color_changed):
		panel.brush_color_changed.connect(_on_brush_color_changed)
	if panel != null and not panel.brush_thickness_changed.is_connected(_on_brush_thickness_changed):
		panel.brush_thickness_changed.connect(_on_brush_thickness_changed)
	if panel != null and not panel.paint_opacity_changed.is_connected(_on_paint_opacity_changed):
		panel.paint_opacity_changed.connect(_on_paint_opacity_changed)
	if panel != null and not panel.paint_flow_changed.is_connected(_on_paint_flow_changed):
		panel.paint_flow_changed.connect(_on_paint_flow_changed)
	if panel != null and not panel.paint_spacing_changed.is_connected(_on_paint_spacing_changed):
		panel.paint_spacing_changed.connect(_on_paint_spacing_changed)
	if panel != null and not panel.paint_spray_toggled.is_connected(_on_paint_spray_toggled):
		panel.paint_spray_toggled.connect(_on_paint_spray_toggled)
	if panel != null and not panel.paint_spray_interval_changed.is_connected(_on_paint_spray_interval_changed):
		panel.paint_spray_interval_changed.connect(_on_paint_spray_interval_changed)
	if panel != null and not panel.radius_changed.is_connected(_on_radius_changed):
		panel.radius_changed.connect(_on_radius_changed)
	if panel != null and not panel.strength_changed.is_connected(_on_strength_changed):
		panel.strength_changed.connect(_on_strength_changed)
	if panel != null and not panel.falloff_changed.is_connected(_on_falloff_changed):
		panel.falloff_changed.connect(_on_falloff_changed)
	if panel != null and not panel.sculpt_tool_changed.is_connected(_on_sculpt_tool_changed):
		panel.sculpt_tool_changed.connect(_on_sculpt_tool_changed)
	if panel != null and not panel.smooth_tool_changed.is_connected(_on_smooth_tool_changed):
		panel.smooth_tool_changed.connect(_on_smooth_tool_changed)
	if panel != null and not panel.sun_color_changed.is_connected(_on_sun_color_changed):
		panel.sun_color_changed.connect(_on_sun_color_changed)
	if panel != null and not panel.sun_energy_changed.is_connected(_on_sun_energy_changed):
		panel.sun_energy_changed.connect(_on_sun_energy_changed)
	if panel != null and not panel.sun_shadow_distance_changed.is_connected(_on_sun_shadow_distance_changed):
		panel.sun_shadow_distance_changed.connect(_on_sun_shadow_distance_changed)
	if panel != null and not panel.sun_shadow_resolution_changed.is_connected(_on_sun_shadow_resolution_changed):
		panel.sun_shadow_resolution_changed.connect(_on_sun_shadow_resolution_changed)
	if panel != null and not panel.tile_line_thickness_changed.is_connected(_on_tile_line_thickness_changed):
		panel.tile_line_thickness_changed.connect(_on_tile_line_thickness_changed)
	if panel != null and not panel.sun_shadow_toggled.is_connected(_on_sun_shadow_toggled):
		panel.sun_shadow_toggled.connect(_on_sun_shadow_toggled)
	if panel != null and not panel.env_ambient_color_changed.is_connected(_on_env_ambient_color_changed):
		panel.env_ambient_color_changed.connect(_on_env_ambient_color_changed)
	if panel != null and not panel.env_ambient_energy_changed.is_connected(_on_env_ambient_energy_changed):
		panel.env_ambient_energy_changed.connect(_on_env_ambient_energy_changed)
	if panel != null and not panel.env_sky_energy_changed.is_connected(_on_env_sky_energy_changed):
		panel.env_sky_energy_changed.connect(_on_env_sky_energy_changed)
	if panel != null and not panel.object_browse_requested.is_connected(_open_object_picker):
		panel.object_browse_requested.connect(_open_object_picker)
	if panel != null and not panel.paint_channel_selected.is_connected(_on_paint_channel_selected):
		panel.paint_channel_selected.connect(_on_paint_channel_selected)
	if panel != null and not panel.paint_texture_requested.is_connected(_on_paint_texture_requested):
		panel.paint_texture_requested.connect(_on_paint_texture_requested)
	if panel != null and not panel.paint_depth_changed.is_connected(_on_paint_depth_changed):
		panel.paint_depth_changed.connect(_on_paint_depth_changed)
	if panel != null and not panel.wipe_channel_pressed.is_connected(_wipe_channel_scoped):
		panel.wipe_channel_pressed.connect(_wipe_channel_scoped)
	if panel != null and not panel.wipe_tile_pressed.is_connected(_wipe_tile_scoped):
		panel.wipe_tile_pressed.connect(_wipe_tile_scoped)
	if panel != null and not panel.vertex_color_changed.is_connected(_on_vertex_color_changed):
		panel.vertex_color_changed.connect(_on_vertex_color_changed)
	if panel != null and not panel.vertex_strength_changed.is_connected(_on_vertex_strength_changed):
		panel.vertex_strength_changed.connect(_on_vertex_strength_changed)
	if panel != null and not panel.vertex_opacity_changed.is_connected(_on_vertex_opacity_changed):
		panel.vertex_opacity_changed.connect(_on_vertex_opacity_changed)
	if panel != null and not panel.vertex_flow_changed.is_connected(_on_vertex_flow_changed):
		panel.vertex_flow_changed.connect(_on_vertex_flow_changed)
	if panel != null and not panel.vertex_spacing_changed.is_connected(_on_vertex_spacing_changed):
		panel.vertex_spacing_changed.connect(_on_vertex_spacing_changed)
	if panel != null and not panel.vertex_spray_toggled.is_connected(_on_vertex_spray_toggled):
		panel.vertex_spray_toggled.connect(_on_vertex_spray_toggled)
	if panel != null and not panel.vertex_spray_interval_changed.is_connected(_on_vertex_spray_interval_changed):
		panel.vertex_spray_interval_changed.connect(_on_vertex_spray_interval_changed)
	if panel != null and not panel.wipe_vertex_pressed.is_connected(_wipe_vertex_tile_scoped):
		panel.wipe_vertex_pressed.connect(_wipe_vertex_tile_scoped)
	if panel != null and not panel.grid_toggled.is_connected(_on_grid_toggled):
		panel.grid_toggled.connect(_on_grid_toggled)
	if panel != null and not panel.save_requested.is_connected(_on_save_requested):
		panel.save_requested.connect(_on_save_requested)
	if panel != null and not panel.load_requested.is_connected(_on_load_requested):
		panel.load_requested.connect(_on_load_requested)
	modes = TerrainModesScript.new()
	modes.name = "WmtModeSwitcher"
	toolbar = TerrainToolbarScript.new()
	toolbar.name = "WmtToolbar"
	# Floating toolbars live in the editor viewport's GUI (NOT inside the render
	# SubViewport) so their buttons get real clicks — SubViewport children
	# render but never receive GUI input here.
	var op := _overlay_parent()
	if op != null:
		op.add_child(modes)
		op.add_child(toolbar)
	if not modes.mode_changed.is_connected(_on_mode_changed):
		modes.mode_changed.connect(_on_mode_changed)
	_setup_autosave()
	if toolbar != null:
		toolbar.load_pressed.connect(_on_load_requested)
		toolbar.save_pressed.connect(_on_save_requested)
		toolbar.wireframe_toggled.connect(_on_wireframe_toggled)
		toolbar.grid_toggled.connect(_on_grid_toggled)
		toolbar.shading_toggled.connect(_on_shading_toggled)
		toolbar.vertex_toggled.connect(_on_vertex_toggled)
	_sync_toolbar_states()
	call_deferred("_position_overlays")
	if not modes.mode_changed.is_connected(_on_mode_changed):
		modes.mode_changed.connect(_on_mode_changed)
	_setup_autosave()
	if panel != null and panel.has_method("get_tab_index"):
		active_tab = panel.get_tab_index()
	if panel != null and panel.has_method("set_wireframe_state"):
		panel.set_wireframe_state(wireframe_on, wireframe_black, wireframe_thickness)
	if panel != null and panel.has_method("update_radius_label"):
		panel.update_radius_label(cursor_radius)
	if panel != null and panel.has_method("update_falloff_label"):
		panel.update_falloff_label(falloff_ratio)
	if panel != null and panel.has_method("update_strength_label"):
		panel.update_strength_label(sculpt_strength)
	if panel != null and panel.has_method("set_brush_state"):
		panel.set_brush_state(brush_color, brush_thickness)
	if panel != null and panel.has_method("set_paint_state"):
		panel.set_paint_state(paint_opacity, paint_flow, paint_spacing, paint_spray_on, paint_spray_interval)
	if panel != null and panel.has_method("set_spray_state"):
		panel.set_spray_state(paint_spray_on)
	if panel != null and panel.has_method("set_paint_channel"):
		panel.set_paint_channel(paint_channel)
	if panel != null and panel.has_method("set_paint_channel_textures"):
		panel.set_paint_channel_textures(paint_channel_textures)
	if panel != null and panel.has_method("set_sculpt_tool"):
		panel.set_sculpt_tool(sculpt_tool)
	if panel != null and panel.has_method("set_grid_state"):
		panel.set_grid_state(wmt_lines_on or chunk_lines_on)
	_switch_mode(active_tab)
	_on_selection_changed()
	print("[WMT Terrain] plugin loaded")
	if OS.get_environment("WMT_SELFTEST") == "1":
		_selftest_mode = true
		if OS.get_environment("WMT_SELFTEST_DRIVE") == "1":
			call_deferred("_selftest")

# The clickable overlay parent for floating toolbars: the editor viewport's GUI
# Control (holds the SubViewportContainer + native toolbars), NOT the render
# SubViewport. Falls back to the SubViewport itself if the structure differs
# (the toolbars would then only render, clicks unsupported).
func _overlay_parent() -> Node:
	var sv := EditorInterface.get_editor_viewport_3d()
	if sv == null:
		return null
	var p := sv.get_parent()
	if p is SubViewportContainer:
		var gp := p.get_parent()
		if gp is Control:
			return gp
	return sv

func _position_overlays() -> void:
	# Deferred at boot and on scene changes; skip if the plugin is on its way out.
	if _exiting or not is_inside_tree():
		return
	if modes != null and is_instance_valid(modes):
		modes.move_to_front()
		modes.set_anchors_and_offsets_preset(Control.PRESET_CENTER_LEFT, Control.PRESET_MODE_KEEP_SIZE)
		modes.offset_left += 8.0
		modes.offset_right += 8.0
	if toolbar != null and is_instance_valid(toolbar):
		toolbar.move_to_front()
		toolbar.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP, Control.PRESET_MODE_KEEP_SIZE)
		toolbar.offset_top += 6.0
		toolbar.offset_bottom += 6.0

func _first_wmt(node: Node) -> Variant:
	if node == null:
		return null
	if node is WmtScript:
		return node
	for c in node.get_children():
		var r := _first_wmt(c)
		if r != null:
			return r
	return null

# The cursor pipeline keys off the selected WMT node, but opening a scene
# leaves the root (not the WMT child) selected, so nothing ever engages when
# the user just hovers. Once, quietly, adopt the scene's WMT into the
# selection when nothing is selected yet: selection_changed fires, the normal
# attach/cursor flow runs, and the user gets a cursor without knowing they had
# to click the node first. An explicit non-empty selection always wins.
# The WMT a mode switch / paste should act on, WITHOUT requiring it to be
# selected: whatever the plugin is already editing, else the first WMT in the
# scene. Selecting a pasted object (or anything else) must not stop a paste
# from finding the terrain, which is what used to force a re-select first.
func _target_terrain() -> Variant:
	if terrain != null and is_instance_valid(terrain):
		return terrain
	var w := _first_wmt(EditorInterface.get_edited_scene_root())
	if w != null:
		# Keep the plugin's own state pointing at it so the raycast helpers
		# (which read `terrain`) hit the right node.
		terrain = w
	return w

# Select the terrain for an editing mode, so the inspector shows it and the
# docked selection always matches the tool that is active. Objects mode does the
# opposite and starts from a clean slate.
func _sync_selection_to_mode(index: int) -> void:
	var sel := EditorInterface.get_selection()
	if sel == null:
		return
	if index == TAB_OBJECTS:
		sel.clear()
		return
	var t := _target_terrain()
	if t != null:
		sel.clear()
		sel.add_node(t)

# Remember where the terrain sits when Objects mode starts, so the editor's
# gizmo can never drag it away. Cleared the moment an editing mode is picked
# again - those modes are allowed to place the terrain.
func _lock_terrain_for_objects_mode(index: int) -> void:
	if index != TAB_OBJECTS:
		_objects_mode_xform_valid = false
		return
	var t := _target_terrain()
	if t != null:
		_objects_mode_xform = t.global_transform
		_objects_mode_xform_valid = true

# Objects mode: drop the terrain from the selection and put it back where it
# was. Only the terrain is removed - whatever else was selected stays selected,
# since the usual cause is a stray click on the terrain while working on real
# objects.
func _enforce_objects_mode_terrain_lock() -> void:
	if active_tab != TAB_OBJECTS or _objects_mode_fixing:
		return
	var t := _target_terrain()
	if t == null:
		return
	if _objects_mode_xform_valid and not t.global_transform.is_equal_approx(
			_objects_mode_xform):
		# The editor moved it (gizmo drag, or an undo/redo of an earlier edit).
		# Put it straight back and leave the scene tree clean.
		t.global_transform = _objects_mode_xform
	var sel := EditorInterface.get_selection()
	if sel == null:
		return
	var picked := sel.get_selected_nodes()
	if not picked.has(t):
		_objects_mode_prev_sel = []
		return
	_objects_mode_fixing = true
	var others: Array = []
	for n in picked:
		if n != t:
			others.append(n)
	sel.clear()
	for n in others:
		if is_instance_valid(n):
			sel.add_node(n)
	_objects_mode_prev_sel = others
	_objects_mode_fixing = false

func _consider_auto_select() -> void:
	if terrain != null and is_instance_valid(terrain):
		return
	var sel := EditorInterface.get_selection()
	if not sel.get_selected_nodes().is_empty():
		return
	var w := _first_wmt(EditorInterface.get_edited_scene_root())
	if w != null:
		sel.add_node(w)

func _refresh_filesystem() -> void:
	# Deferred at boot; skip if the plugin is on its way out.
	if _exiting or not is_inside_tree():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	# The editor scan alone skips unknown binary formats like .wmt, so those
	# files only ever showed up after _save_terrain() force-registered them via
	# fs.update_file(). Register every existing .wmt up front so the FileSystem
	# dock lists them without requiring a save.
	var registered: Array = []
	for p in _collect_wmt_files("res://"):
		fs.update_file(p)
		registered.append(p)
	if OS.get_environment("WMT_SELFTEST") == "1":
		for p in registered:
			var back: Variant = null
			if fs.has_method("get_filesystem_path"):
				back = fs.get_filesystem_path(p)
			print("[WMT fs] registered=", p, " readback=", back)
		print("[WMT fs] total=", registered.size())
	if not _scan_deferred:
		_scan_deferred = true
		var t := get_tree().create_timer(2.0)
		t.timeout.connect(_refresh_filesystem_scan)

func _refresh_filesystem_scan() -> void:
	# The plugin can be torn down between the timer firing and this running, and
	# a deferred call already queued is not withdrawn when the plugin is freed.
	if _exiting or not is_inside_tree():
		return
	var fs := EditorInterface.get_resource_filesystem()
	if fs == null:
		return
	if fs.is_scanning():
		# Re-deferring from inside the flush is what used to crash: this runs
		# from CallQueue::flush(), which the filesystem scan itself drives, so a
		# self-rescheduling call here re-entered the scan that was running it.
		# Poll on a timer instead, which cannot nest into the same flush.
		var t := get_tree().create_timer(0.5)
		t.timeout.connect(_refresh_filesystem_scan, CONNECT_ONE_SHOT)
	else:
		fs.scan()

func _collect_wmt_files(base: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(base)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var path := base.path_join(entry)
		if dir.current_is_dir():
			if not entry.begins_with("."):
				out.append_array(_collect_wmt_files(path))
		elif entry.get_extension().to_lower() == "wmt":
			out.append(path)
		entry = dir.get_next()
	dir.list_dir_end()
	return out

func _selftest() -> void:
	print("[WMT4 selftest] begin")
	var root := EditorInterface.get_edited_scene_root()
	print("[WMT4 selftest] edited_root=", root)
	var found := _first_wmt(root)
	print("[WMT4 selftest] first_wmt=", found, " parsed_via_is=", found is WmtScript)
	await get_tree().create_timer(0.5).timeout
	await get_tree().process_frame
	print("[WMT4 selftest] wave1 terrain=", terrain, " valid=", is_instance_valid(terrain))
	if terrain != null:
		var aabb: AABB = terrain.get_aabb()
		print("[WMT4 selftest] terrain aabb=", aabb, " size=", aabb.size)
		var center := aabb.get_center()
		var down := _raycast_terrain_surface(terrain.to_local(center + Vector3(0, 200, 0)), Vector3.DOWN)
		print("[WMT4 selftest] down-ray(center+200) -> ", down)
		print("[WMT4 selftest] brush_on after center ray: ", _wb("brush_on"), " allowed=", _ring_allowed())
		var vp: SubViewport = EditorInterface.get_editor_viewport_3d()
		if vp != null:
			var cam := vp.get_camera_3d()
			var mouse := vp.get_mouse_position()
			var rect := vp.get_visible_rect()
			print("[WMT4 selftest] vp size=", rect, " mouse=", mouse,
				" has_point=", rect.has_point(mouse), " cam=", cam)
			if cam != null:
				var origin := terrain.to_local(cam.project_ray_origin(mouse))
				var basis := terrain.global_transform.basis
				var dir := (basis.inverse() * cam.project_ray_normal(mouse)).normalized()
				var hit := _raycast_terrain_surface(origin, dir)
				print("[WMT4 selftest] cam-ray(mouse) -> ", hit)
				if hit != null:
					cursor_local = hit
					await get_tree().process_frame
					print("[WMT4 selftest] ring after drape: center=", cursor_local,
						" brushed=", _wb("brush_on"), " w=", _wb("brush_width"))
			if cam != null:
				print("[WMT4 selftest] --- wave2: full real path (drive cam + pick center) ---")
				active_tab = TAB_SCULPT
				var rect2 := vp.get_visible_rect()
				var mc := rect2.get_center()
				cam.global_position = terrain.to_global(terrain.get_aabb().get_center() + Vector3(0, 300, 500))
				cam.look_at(terrain.to_global(terrain.get_aabb().get_center()), Vector3.UP)
				await get_tree().process_frame
				_pick_cursor(mc)
				await get_tree().process_frame
				print("[WMT4 selftest] picked center -> brush_on=", _wb("brush_on"))
				_pick_cursor(Vector2(rect2.position.x + 1, rect2.position.y + 1))
				await get_tree().process_frame
				print("[WMT4 selftest] sky-point -> brush_on=", _wb("brush_on"), " (expect false)")
	print("[WMT4 selftest] --- wave3: real-window mouse warp (x11/wayland as available) ---")
	for k in 6:
		await get_tree().create_timer(0.5).timeout
		if is_instance_valid(terrain):
			break
	var vp3: SubViewport = EditorInterface.get_editor_viewport_3d()
	if vp3 == null:
		print("[WMT4 selftest] wave3: no 3d viewport")
	elif not is_instance_valid(terrain):
		print("[WMT4 selftest] wave3: terrain STILL null after wait (scene not loaded) -> select a WMT node manually")
	else:
		var anchor: Control = null
		var w := vp3 as Node
		while w != null:
			if w is Control:
				anchor = w as Control
				break
			w = w.get_parent()
		print("[WMT4 selftest] wave3 window=", DisplayServer.window_get_size(),
			" vp=", vp3, " anchor=", anchor, " anchor_rect=",
			(anchor.get_global_rect() if anchor != null else Rect2()))
		var targets: Array = [
			Vector2(0.5, 0.5),
			Vector2(0.3, 0.45),
			Vector2(0.7, 0.6),
			Vector2(0.2, 0.3),
		]
		for i in targets.size():
			var win_pos := Vector2.ZERO
			if anchor != null:
				win_pos = anchor.get_global_rect().position + anchor.get_global_rect().size * (targets[i] as Vector2)
			else:
				win_pos = vp3.get_visible_rect().get_center()
			DisplayServer.warp_mouse(Vector2i(win_pos))
			await get_tree().create_timer(0.7).timeout
			var rv := vp3.get_visible_rect()
			var mv := vp3.get_mouse_position()
			print("[WMT4 selftest] wave3 warp", i, " win=", win_pos, " -> vp_mouse=", mv,
				" has=", rv.has_point(mv), " brush=", _wb("brush_on"), " cursor=", cursor_local)
		await get_tree().create_timer(1.0).timeout
		print("[WMT4 selftest] wave3 settle: brush=", _wb("brush_on"), " cursor=", cursor_local)
	print("[WMT4 selftest] done (premature exit will say otherwise)")

func _wb(param: String) -> Variant:
	# Selftest read of one brush shader parameter (null when no material yet).
	if _wireframe_mat == null or not is_instance_valid(_wireframe_mat):
		return "no-mat"
	return _wireframe_mat.get_shader_parameter(param)

func _brush_enabled() -> bool:
	# True once the cursor sits on the terrain surface (the shader brush is
	# actively draped), replacing the old ring-node attach check.
	if _wireframe_mat == null or not is_instance_valid(_wireframe_mat):
		return false
	return bool(_wireframe_mat.get_shader_parameter("brush_on"))

func _ensure_ring() -> void:
	# The brush cursor lives in the overlay shader (see _drape_ring), so there
	# is no 3D ring node to (re)build anymore. Kept as a no-op so legacy call
	# sites keep working.
	return

func _ring_color() -> Color:
	return Color(brush_color.r, brush_color.g, brush_color.b, 0.85)

# A second, thinner annulus inside the cursor marking where the brush is at
# full strength (falloff_ratio of the master radius). Drawn by the overlay
# shader (brush_falloff_* uniforms, see _drape_ring). No-op stub for legacy
# call sites.
func _ensure_falloff_ring() -> void:
	return

func _apply_brush_style() -> void:
	_drape_ring()

func _exit_tree() -> void:
	# Set first, and before _save_terrain() runs, because a teardown that can
	# still reach the filesystem or queue a deferred call is exactly the case
	# that crashed the editor. Every deferred entry point checks this.
	_exiting = true
	sculpting = false
	_save_terrain()
	if EditorInterface.get_selection().selection_changed.is_connected(_on_selection_changed):
		EditorInterface.get_selection().selection_changed.disconnect(_on_selection_changed)
	if panel != null and panel.wireframe_toggled.is_connected(_on_wireframe_toggled):
		panel.wireframe_toggled.disconnect(_on_wireframe_toggled)
	if panel != null and panel.wireframe_color_changed.is_connected(_on_wireframe_color_changed):
		panel.wireframe_color_changed.disconnect(_on_wireframe_color_changed)
	if panel != null and panel.wireframe_thickness_changed.is_connected(_on_wireframe_thickness_changed):
		panel.wireframe_thickness_changed.disconnect(_on_wireframe_thickness_changed)
	if panel != null and panel.brush_color_changed.is_connected(_on_brush_color_changed):
		panel.brush_color_changed.disconnect(_on_brush_color_changed)
	if panel != null and panel.brush_thickness_changed.is_connected(_on_brush_thickness_changed):
		panel.brush_thickness_changed.disconnect(_on_brush_thickness_changed)
	if panel != null and panel.paint_opacity_changed.is_connected(_on_paint_opacity_changed):
		panel.paint_opacity_changed.disconnect(_on_paint_opacity_changed)
	if panel != null and panel.paint_flow_changed.is_connected(_on_paint_flow_changed):
		panel.paint_flow_changed.disconnect(_on_paint_flow_changed)
	if panel != null and panel.paint_spacing_changed.is_connected(_on_paint_spacing_changed):
		panel.paint_spacing_changed.disconnect(_on_paint_spacing_changed)
	if panel != null and panel.paint_spray_toggled.is_connected(_on_paint_spray_toggled):
		panel.paint_spray_toggled.disconnect(_on_paint_spray_toggled)
	if panel != null and panel.paint_spray_interval_changed.is_connected(_on_paint_spray_interval_changed):
		panel.paint_spray_interval_changed.disconnect(_on_paint_spray_interval_changed)
	if panel != null and panel.radius_changed.is_connected(_on_radius_changed):
		panel.radius_changed.disconnect(_on_radius_changed)
	if panel != null and panel.strength_changed.is_connected(_on_strength_changed):
		panel.strength_changed.disconnect(_on_strength_changed)
	if panel != null and panel.falloff_changed.is_connected(_on_falloff_changed):
		panel.falloff_changed.disconnect(_on_falloff_changed)
	if panel != null and panel.sculpt_tool_changed.is_connected(_on_sculpt_tool_changed):
		panel.sculpt_tool_changed.disconnect(_on_sculpt_tool_changed)
	if panel != null and panel.smooth_tool_changed.is_connected(_on_smooth_tool_changed):
		panel.smooth_tool_changed.disconnect(_on_smooth_tool_changed)
	if panel != null and panel.sun_color_changed.is_connected(_on_sun_color_changed):
		panel.sun_color_changed.disconnect(_on_sun_color_changed)
	if panel != null and panel.sun_energy_changed.is_connected(_on_sun_energy_changed):
		panel.sun_energy_changed.disconnect(_on_sun_energy_changed)
	if panel != null and panel.sun_shadow_distance_changed.is_connected(_on_sun_shadow_distance_changed):
		panel.sun_shadow_distance_changed.disconnect(_on_sun_shadow_distance_changed)
	if panel != null and panel.sun_shadow_resolution_changed.is_connected(_on_sun_shadow_resolution_changed):
		panel.sun_shadow_resolution_changed.disconnect(_on_sun_shadow_resolution_changed)
	if panel != null and panel.tile_line_thickness_changed.is_connected(_on_tile_line_thickness_changed):
		panel.tile_line_thickness_changed.disconnect(_on_tile_line_thickness_changed)
	if panel != null and panel.sun_shadow_toggled.is_connected(_on_sun_shadow_toggled):
		panel.sun_shadow_toggled.disconnect(_on_sun_shadow_toggled)
	if panel != null and panel.paint_channel_selected.is_connected(_on_paint_channel_selected):
		panel.paint_channel_selected.disconnect(_on_paint_channel_selected)
	if panel != null and panel.paint_texture_requested.is_connected(_on_paint_texture_requested):
		panel.paint_texture_requested.disconnect(_on_paint_texture_requested)
	if panel != null and panel.paint_depth_changed.is_connected(_on_paint_depth_changed):
		panel.paint_depth_changed.disconnect(_on_paint_depth_changed)
	if panel != null and panel.wipe_channel_pressed.is_connected(_wipe_channel_scoped):
		panel.wipe_channel_pressed.disconnect(_wipe_channel_scoped)
	if panel != null and panel.wipe_tile_pressed.is_connected(_wipe_tile_scoped):
		panel.wipe_tile_pressed.disconnect(_wipe_tile_scoped)
	if panel != null and panel.vertex_color_changed.is_connected(_on_vertex_color_changed):
		panel.vertex_color_changed.disconnect(_on_vertex_color_changed)
	if panel != null and panel.vertex_strength_changed.is_connected(_on_vertex_strength_changed):
		panel.vertex_strength_changed.disconnect(_on_vertex_strength_changed)
	if panel != null and panel.vertex_opacity_changed.is_connected(_on_vertex_opacity_changed):
		panel.vertex_opacity_changed.disconnect(_on_vertex_opacity_changed)
	if panel != null and panel.vertex_flow_changed.is_connected(_on_vertex_flow_changed):
		panel.vertex_flow_changed.disconnect(_on_vertex_flow_changed)
	if panel != null and panel.vertex_spacing_changed.is_connected(_on_vertex_spacing_changed):
		panel.vertex_spacing_changed.disconnect(_on_vertex_spacing_changed)
	if panel != null and panel.vertex_spray_toggled.is_connected(_on_vertex_spray_toggled):
		panel.vertex_spray_toggled.disconnect(_on_vertex_spray_toggled)
	if panel != null and panel.vertex_spray_interval_changed.is_connected(_on_vertex_spray_interval_changed):
		panel.vertex_spray_interval_changed.disconnect(_on_vertex_spray_interval_changed)
	if panel != null and panel.wipe_vertex_pressed.is_connected(_wipe_vertex_tile_scoped):
		panel.wipe_vertex_pressed.disconnect(_wipe_vertex_tile_scoped)
	if panel != null and panel.grid_toggled.is_connected(_on_grid_toggled):
		panel.grid_toggled.disconnect(_on_grid_toggled)
	if panel != null and panel.save_requested.is_connected(_on_save_requested):
		panel.save_requested.disconnect(_on_save_requested)
	if panel != null and panel.load_requested.is_connected(_on_load_requested):
		panel.load_requested.disconnect(_on_load_requested)
	if modes != null and modes.mode_changed.is_connected(_on_mode_changed):
		modes.mode_changed.disconnect(_on_mode_changed)
	if toolbar != null:
		if toolbar.load_pressed.is_connected(_on_load_requested):
			toolbar.load_pressed.disconnect(_on_load_requested)
		if toolbar.save_pressed.is_connected(_on_save_requested):
			toolbar.save_pressed.disconnect(_on_save_requested)
		if toolbar.wireframe_toggled.is_connected(_on_wireframe_toggled):
			toolbar.wireframe_toggled.disconnect(_on_wireframe_toggled)
		if toolbar.grid_toggled.is_connected(_on_grid_toggled):
			toolbar.grid_toggled.disconnect(_on_grid_toggled)
		if toolbar.shading_toggled.is_connected(_on_shading_toggled):
			toolbar.shading_toggled.disconnect(_on_shading_toggled)
		if toolbar.vertex_toggled.is_connected(_on_vertex_toggled):
			toolbar.vertex_toggled.disconnect(_on_vertex_toggled)
	_hide_ring()
	_clear_wireframe_overlay()
	_hide_tiles_overlay()
	if _paint_popup != null:
		if _paint_popup.get_parent() != null:
			_paint_popup.get_parent().remove_child(_paint_popup)
		_paint_popup.queue_free()
	_paint_popup = null
	_paint_popup_boxes.clear()
	_paint_popup_tilings.clear()
	if _texture_popup != null:
		if _texture_popup.get_parent() != null:
			_texture_popup.get_parent().remove_child(_texture_popup)
		_texture_popup.queue_free()
	_texture_popup = null
	_texture_list = null
	# Remove the persistent dock tab and free its tree (best-effort: the bottom
	# panel may already be tearing down when the plugin deactivates).
	if _texture_dock != null and is_instance_valid(_texture_dock):
		# remove_control_from_bottom_panel also frees the control (queue_free),
		# so guard against the bottom panel already tearing down on exit.
		if _texture_dock.get_parent() != null:
			remove_control_from_bottom_panel(_texture_dock)
		else:
			_texture_dock.queue_free()
	_texture_dock = null
	_texture_dock_search = null
	_texture_dock_list = null
	# Free the previewed object scene with the popup so a disabled plugin does
	# not keep an instanced prop alive in memory.
	if _object_preview_instance != null and is_instance_valid(_object_preview_instance):
		_object_preview_instance.queue_free()
	_object_preview_instance = null
	if _object_popup != null and is_instance_valid(_object_popup):
		_object_popup.queue_free()
	_object_popup = null
	_object_list = null
	_object_search = null
	_object_preview_vp = null
	_object_preview_stage = null
	_object_preview_cam = null
	_object_preview_name = null
	if modes != null:
		if modes.get_parent() != null:
			modes.get_parent().remove_child(modes)
		modes.queue_free()
	if toolbar != null:
		if toolbar.get_parent() != null:
			toolbar.get_parent().remove_child(toolbar)
		toolbar.queue_free()
	if panel != null:
		remove_control_from_docks(panel)
		panel.queue_free()

func _overlay_cover_aabb() -> AABB:
	var cover := AABB(Vector3(-8, -512, -8), Vector3(144, 1024, 144))
	if terrain != null and is_instance_valid(terrain) and terrain.get_aabb().size.length() > 0.001:
		cover = terrain.get_aabb().grow(terrain.CHUNK_WIDTH + 8.0)
	return cover

func _input(event: InputEvent) -> void:
	# Outside click closes the object browser, and nothing else does. A click
	# inside it stays open (so a pick can be followed by another pick), a paste
	# stays open, and Enter closes it. Handling this here rather than relying on
	# the popup's own behaviour is deliberate: a plain PopupPanel is not
	# guaranteed to dismiss itself on an outside click, and a browser that will
	# not get out of the way is worse than one that closes a shade too eagerly.
	if event is InputEventMouseButton and _object_picker_open():
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT \
				and not _point_over_object_popup(mb.position):
			_object_popup.visible = false
	# Objects-mode keys are handled FIRST: the generic key block below returns
	# for every key event, so Ctrl+C / Ctrl+V placed in the Objects branch
	# further down would never be reached. Paste is deliberately a KEY and not a
	# click: a click is how scene objects get selected and deselected, so
	# pasting on click would make the selection impossible to change once
	# anything was on the clipboard.
	if active_tab == TAB_OBJECTS and event is InputEventKey:
		var kev := event as InputEventKey
		if kev.pressed and not kev.echo:
			# Escape and Enter are the "done here" gestures. Enter only reaches
			# this when the list (not the search box) has the focus, because the
			# box consumes its own Enter first.
			if kev.keycode == KEY_ESCAPE and _object_picker_open():
				_object_popup.visible = false
				EditorInterface.get_editor_viewport_3d().set_input_as_handled()
				return
			if kev.ctrl_pressed:
				# Ctrl+C / Ctrl+V must not reach the search box, or pasting into
				# the filter would paste a terrain object into the scene.
				if kev.keycode == KEY_C and not _object_search_has_focus():
					_copy_selected_objects()
					EditorInterface.get_editor_viewport_3d().set_input_as_handled()
					return
				if kev.keycode == KEY_V and not _object_search_has_focus():
					# The browser deliberately STAYS open: this is the whole
					# point, so a group can be pasted straight into the scene and
					# the next group picked without reopening it. It closes on an
					# outside click or Enter, not on pasting.
					_paste_objects_at_cursor()
					EditorInterface.get_editor_viewport_3d().set_input_as_handled()
					return
		# Every other key falls through to the generic key block below, so
		# Ctrl+Z / Ctrl+Y undo still work while in Objects mode: that block skips
		# its own sculpt history in this tab and leaves the event for the editor,
		# which is what makes gizmo moves and pastes undoable.
	if event is InputEventKey:
		# Cast up front: reading event.physical_keycode straight off the
		# InputEvent-typed parameter is an illegal property access at runtime
		# ("Invalid access to property or key 'key_physicalcode'"), which broke
		# every Ctrl+Z / Ctrl+Y in the viewport. Note it is physical_keycode in
		# Godot 4; key_physicalcode was the Godot 3 name.
		var kev := event as InputEventKey
		if kev.pressed and not kev.echo:
			if _paint_popup_open() and kev.keycode == KEY_ESCAPE:
				_close_paint_popup()
				EditorInterface.get_editor_viewport_3d().set_input_as_handled()
				return
			if _text_edit_focused():
				return
			# Sculpt undo/redo is ours ONLY in the sculpting tabs. In Objects
			# mode the things being moved are ordinary scene nodes dragged with
			# the editor's own gizmo, and the editor already records that in its
			# own history - but this block used to run first in every tab and
			# mark the event handled, so Ctrl+Z replayed a terrain stroke (or did
			# nothing) instead of undoing the move, and Ctrl+Y could never redo.
			# Letting the event through untouched hands it back to the editor,
			# which is what makes gizmo moves and pastes undoable.
			var sculpt_tab := active_tab != TAB_OBJECTS
			if sculpt_tab and kev.ctrl_pressed and (kev.keycode == KEY_Z or kev.physical_keycode == KEY_Z):
				var vp := EditorInterface.get_editor_viewport_3d()
				if kev.shift_pressed:
					_redo_sculpt()
					vp.set_input_as_handled()
				else:
					_undo_sculpt()
					vp.set_input_as_handled()
			elif sculpt_tab and kev.ctrl_pressed and (kev.keycode == KEY_Y or kev.physical_keycode == KEY_Y):
				_redo_sculpt()
				EditorInterface.get_editor_viewport_3d().set_input_as_handled()
		return
	# Objects mode is a pure scene-editing mode: hand every non-key event back
	# to the editor so the default Select/Transform gizmo can pick and move
	# objects. Do this BEFORE terrain selection/auto-select so a selected WMT
	# node still lets the user manipulate other objects around it. (Ctrl+C /
	# Ctrl+V are handled at the top of _input, before the key block.)
	if active_tab == TAB_OBJECTS:
		if terrain != null and is_instance_valid(terrain):
			_hide_ring()
		# Ctrl+RMB opens the model viewer, and it has to be handled HERE: this
		# block returns unconditionally, and Objects mode also drops the terrain
		# out of the selection on purpose (so terrain == null and the
		# auto-select gate below bails too). Any RMB shortcut registered further
		# down was therefore unreachable in this tab - the browser simply never
		# opened, from the viewport or anywhere else.
		if event is InputEventMouseButton:
			var omb := event as InputEventMouseButton
			if omb.button_index == MOUSE_BUTTON_RIGHT and omb.pressed \
					and omb.ctrl_pressed and not omb.shift_pressed \
					and not omb.alt_pressed:
				_open_object_picker()
				EditorInterface.get_editor_viewport_3d().set_input_as_handled()
		return
	if _selftest_mode and event is InputEventMouseMotion and _motion_spy_left > 0:
		_motion_spy_left -= 1
		var sp_vp := EditorInterface.get_editor_viewport_3d()
		var sp_rect := sp_vp.get_visible_rect()
		print("[WMT4 spy] #%d evt_pos=%s vp_mouse=%s rect=%s has=%s terrain_null=%s brush=%s" % [
			40 - _motion_spy_left, event.position, sp_vp.get_mouse_position(),
			sp_rect, sp_rect.has_point(sp_vp.get_mouse_position()), terrain == null,
			_wb("brush_on")])
	if terrain == null:
		_consider_auto_select()
		if terrain == null:
			return
	var vp := EditorInterface.get_editor_viewport_3d()
	if event is InputEventMouseMotion:
		_latch_alt(event.alt_pressed, false)
		if _pointer_over_floats():
			return
		if vp.get_visible_rect().has_point(vp.get_mouse_position()):
			_update_cursor_position()
		elif not sculpting:
			_hide_ring()
		return
	if event is InputEventMouseButton:
		# Latch the Alt state off the events themselves (see _alt_down()).
		_latch_alt(event.alt_pressed, not event.pressed)
		if _pointer_over_floats():
			return
		if not vp.get_visible_rect().has_point(vp.get_mouse_position()):
			return
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if mb.button_index == MOUSE_BUTTON_LEFT:
				if not mb.pressed:
					# Belt and braces: if the editor did grab the node on the
					# press (it owns the viewport, so swallowing the event is not
					# a guarantee), put the terrain back where the drag started.
					# Nothing in the editing modes moves the terrain itself, so
					# any movement during a guarded drag is the editor's.
					if _terrain_drag_guard and terrain != null \
							and is_instance_valid(terrain) \
							and not terrain.global_transform.is_equal_approx(_terrain_drag_xform):
						terrain.global_transform = _terrain_drag_xform
					_terrain_drag_guard = false
				elif _press_lands_on_terrain():
					# A left press that starts ON the terrain belongs to the
					# plugin (tile toggle / paint / sculpt), and the terrain is
					# selected in every editing mode - so without this the
					# editor's Select tool picks it up and drags the whole terrain
					# on any stray left-drag. Mark the event handled to block the
					# editor, but DO NOT return: the rest of this function still
					# has to run the plugin's own action for this very press.
					_terrain_drag_guard = true
					_terrain_drag_xform = terrain.global_transform
					vp.set_input_as_handled()
		# While the channel popup is open: a click on the popup reaches its box
		# buttons; any other press closes it and is consumed so it cannot start
		# a paint stroke or a sculpt stroke underneath.
		if _paint_popup_open():
			if event.pressed:
				if not _pointer_over_paint_popup():
					_close_paint_popup()
					vp.set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			if event.ctrl_pressed and not event.shift_pressed and not event.alt_pressed:
				_resize_ring(cursor_radius * CURSOR_RADIUS_STEP)
				vp.set_input_as_handled()
			elif event.shift_pressed and not event.ctrl_pressed and not event.alt_pressed:
				_resize_falloff(falloff_ratio + FALLOFF_STEP)
				vp.set_input_as_handled()
			elif event.alt_pressed and not event.ctrl_pressed and not event.shift_pressed:
				_resize_strength(sculpt_strength * STRENGTH_STEP)
				vp.set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			if event.ctrl_pressed and not event.shift_pressed and not event.alt_pressed:
				_resize_ring(cursor_radius / CURSOR_RADIUS_STEP)
				vp.set_input_as_handled()
			elif event.shift_pressed and not event.ctrl_pressed and not event.alt_pressed:
				_resize_falloff(falloff_ratio - FALLOFF_STEP)
				vp.set_input_as_handled()
			elif event.alt_pressed and not event.ctrl_pressed and not event.shift_pressed:
				_resize_strength(sculpt_strength / STRENGTH_STEP)
				vp.set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_RIGHT:
			if active_tab == TAB_PAINT and event.pressed \
					and event.ctrl_pressed and not event.shift_pressed and not event.alt_pressed:
				# Ctrl+RMB is the ONLY channel-picker shortcut.
				_toggle_paint_popup(event.position)
				vp.set_input_as_handled()
				return
			if active_tab == TAB_VERTEX_COLOR and event.pressed \
					and not event.alt_pressed:
				# The whole vertex-paint right-button surface lives here, so a
				# stray RMB can never reach the editor's own handling.
				if event.ctrl_pressed and not event.shift_pressed:
					# Ctrl+RMB is the vertex-color selector - the same shortcut the
					# paint tab uses for its channel picker, so muscle memory carries
					# over and neither tab has a right-click hole.
					_toggle_vertex_color_popup()
					vp.set_input_as_handled()
					return
				if event.shift_pressed and not event.ctrl_pressed:
					# Shift+RMB is the erase stroke; the stroke itself is polled
					# in _process, so the press only has to be swallowed.
					vp.set_input_as_handled()
					return
			if active_tab == TAB_PAINT and event.pressed \
					and event.alt_pressed and not event.ctrl_pressed and not event.shift_pressed:
				# Alt+RMB: unselect every tile in the chunk under the cursor;
				# if none of them are selected, select them all instead.
				_update_cursor_position()
				_toggle_select_chunk_under_cursor()
				vp.set_input_as_handled()
				return
			if event.pressed and active_tab == TAB_WMT:
				if event.shift_pressed:
					var s_key := _chunk_under_mouse()
					if s_key != null:
						_delete_chunk(s_key)
						vp.set_input_as_handled()
			return
		if event.button_index == MOUSE_BUTTON_LEFT:
			if active_tab == TAB_WMT:
				if event.pressed:
					if event.shift_pressed and not event.ctrl_pressed:
						# Shift+LMB over an empty ghost slot lays down a new
						# chunk; anywhere else the hide/unhide TOGGLE DRAG starts
						# (the drag continues in _process for as long as the
						# button is held).
						if not _try_place_at_mouse():
							vp.set_input_as_handled()
					elif not event.shift_pressed and not event.ctrl_pressed \
							and not event.alt_pressed:
						# Plain LMB starts the hide/unhide BRUSH DRAG. The
						# press itself toggles nothing: _begin_wmt_drag only
						# samples the cursor, and _wmt_drag_frame then toggles
						# every tile the circle covers, for as long as the
						# button is held. A click is just the one-tile case.
						if not _pointer_over_floats():
							_begin_wmt_drag()
						vp.set_input_as_handled()
					elif event.shift_pressed:
						vp.set_input_as_handled()
				return
			if active_tab != TAB_SCULPT:
				if active_tab == TAB_PAINT:
					# Ctrl+LMB on the terrain is the channel eyedropper: it
					# selects the channel whose texture is painted there.
					if event.pressed and event.ctrl_pressed \
							and not event.shift_pressed and not event.alt_pressed:
						_update_cursor_position()
						_eyedrop_paint_channel()
					# Plain (and Alt) LMB toggles the tiles under the brush
					# circle; the drag continues in _process for as long as the
					# button is held (each new tile the circle enters toggles
					# once), so there is nothing to do on the press itself.
					# Paint strokes run on raw button-state polling in _process;
					# swallow press+release so the editor never treats an LMB
					# hold-drag as a camera orbit.
					vp.set_input_as_handled()
					_update_cursor_position()
				elif active_tab == TAB_VERTEX_COLOR:
					# Ctrl+LMB is the vertex-color eyedropper: it picks up the
					# color already painted under the cursor, so you can extend
					# a stroke from its own color instead of guessing it.
					if event.pressed and event.ctrl_pressed \
							and not event.shift_pressed and not event.alt_pressed:
						_update_cursor_position()
						_eyedrop_vertex_tint()
					# Vertex-color strokes run on raw button-state polling in
					# _process; swallow press and release so plain-LMB painting
					# never orbits the camera.
					vp.set_input_as_handled()
					_update_cursor_position()
				return
			if _is_set_height_tab() and not _set_height_enabled():
				return
			# Sculpt strokes are driven entirely by _process (button-state
			# polling) so they run continuously for as long as LMB is held,
			# regardless of whether the editor swallowed the modifier-click.
			# Swallow press and release so the editor never steals or toggles.
			vp.set_input_as_handled()
			_update_cursor_position()
		else:
			_update_cursor_position()

func _process(delta: float) -> void:
	_autosave_accum += delta
	if _autosave_accum >= AUTOSAVE_INTERVAL:
		_autosave_accum = 0.0
		_on_autosave_timeout()
	# A chunk delete removed a .wmt file; the editor's VFS only drops deleted
	# files on a scan(). Do it here, outside the delete frame, so the file really
	# disappears from the project instead of lingering as a stale entry.
	if _pending_fs_scan:
		_pending_fs_scan = false
		var rfs := EditorInterface.get_resource_filesystem()
		if rfs != null:
			rfs.scan()
	# Objects mode owns the LMB, so the terrain must stay unselected and
	# un-movable there (see the _objects_mode_* comment).
	_remember_vp_mouse()
	_sync_object_selection()
	_enforce_objects_mode_terrain_lock()
	# Sculpting is purely button-state driven: a stroke runs for every frame
	# LMB is held over the terrain, and only ends after the button has been
	# up for a couple of frames. This makes holding continuous even when the
	# editor consumed the initial modifier-click, and immune to a stray frame
	# where the button state reads as released.
	var held := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var over_float := _pointer_over_floats()
	# Paint strokes reuse the same held-polling as sculpting but only run while
	# SHIFT+LMB is held (plain LMB stays inert so the viewport never orbits).
	# The atlas is pushed to the overlay the same frame strokes change it, so
	# paint appears live instead of only when the stroke is released.
	var paint_hotkey := Input.is_key_pressed(KEY_SHIFT)
	var paint_now := active_tab == TAB_PAINT and is_instance_valid(terrain) and held \
			and paint_hotkey and _cursor_inside_viewport() and not over_float \
			and not _paint_popup_open() and not _texture_picker_open()
	var sel_hotkey := _alt_down() \
		and not Input.is_key_pressed(KEY_SHIFT) and not Input.is_key_pressed(KEY_CTRL)
	var sel_now := active_tab == TAB_PAINT and is_instance_valid(terrain) and held \
		and sel_hotkey and _cursor_inside_viewport() and not over_float \
		and not _paint_popup_open() and not _texture_picker_open()
	# WMT's hide/unhide brush: plain LMB only, no modifiers (Shift lays a chunk
	# down, Ctrl is reserved), so a held drag sweeps tiles.
	var wmt_hotkey := not Input.is_key_pressed(KEY_SHIFT) and not Input.is_key_pressed(KEY_CTRL)
	var wmt_now := active_tab == TAB_WMT and is_instance_valid(terrain) and held \
		and wmt_hotkey and _cursor_inside_viewport() and not over_float
	# Vertex-color strokes: Shift+LMB paints the picked color, Shift+RMB paints
	# the eraser (50% gray), Ctrl+LMB is the eyedropper ONLY. The modifiers are
	# mutually exclusive, so Ctrl can never fall through into a paint or erase
	# stroke, and a plain LMB is a deliberate nothing so the viewport never
	# orbits while over the terrain.
	var vctrl := Input.is_key_pressed(KEY_CTRL)
	var vshift := Input.is_key_pressed(KEY_SHIFT)
	var vlmb := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var vrmb := Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT)
	var vpaint := vlmb and vshift and not vctrl and not vrmb
	var verase := vrmb and vshift and not vctrl and not vlmb
	var vertex_now := active_tab == TAB_VERTEX_COLOR and is_instance_valid(terrain) \
			and (vpaint or verase) and _cursor_inside_viewport() and not over_float \
			and not _paint_popup_open() and not _texture_picker_open() \
			and not _vertex_color_popup_open()
	if _is_sculpt_tab() and is_instance_valid(terrain) and held \
			and _cursor_inside_viewport() and not over_float:
		_apply_stroke_mods()
		if smoothing or sculpt_direction != 0.0:
			_release_debounce = 0
			if not sculpting or not is_instance_valid(stroke_terrain):
				_begin_stroke()
			_sculpt_frame(delta)
		else:
			_release_debounce = 0
	elif _is_smooth_tab() and is_instance_valid(terrain) and held \
			and _cursor_inside_viewport() and not over_float:
		_release_debounce = 0
		if not sculpting or not is_instance_valid(stroke_terrain):
			_begin_stroke()
		_smooth_tool_frame(delta)
	elif _is_set_height_tab() and is_instance_valid(terrain) and held \
			and _cursor_inside_viewport() and not over_float:
		if Input.is_key_pressed(KEY_CTRL) and not Input.is_key_pressed(KEY_SHIFT) and not Input.is_key_pressed(KEY_ALT):
			_eyedrop_set_height()
		else:
			if not _set_height_enabled():
				pass
			else:
				_release_debounce = 0
				if not sculpting or not is_instance_valid(stroke_terrain):
					_begin_stroke()
				_set_height_frame(delta)
	elif sel_now:
		_release_debounce = 0
		_sel_drag_frame()
	elif wmt_now:
		_release_debounce = 0
		_wmt_drag_frame()
	elif paint_now:
		_release_debounce = 0
		if not paint_stroking or not is_instance_valid(terrain):
			_begin_paint_stroke()
		_paint_frame(delta)
		if _paint_dirty:
			# LIVE: rebuild the paint atlas and refresh the overlay material the
			# moment a stroke changes it, so the view tracks the brush.
			_apply_terrain_overlays()
			_paint_dirty = false
	elif vertex_now:
		_release_debounce = 0
		if not vertex_stroking or not is_instance_valid(terrain):
			_begin_vertex_stroke()
		_vertex_frame(delta, verase)
		if _vertex_dirty:
			# The tint lattice upload is cheap (only rebuilt on change); refresh
			# the overlay live so the stroke tracks the brush.
			_apply_terrain_overlays()
			_vertex_dirty = false
	elif paint_stroking:
		_release_debounce += 1
		if _release_debounce >= 2:
			_end_paint_stroke()
			_release_debounce = 0
	elif vertex_stroking:
		_release_debounce += 1
		if _release_debounce >= 2:
			_end_vertex_stroke()
			_release_debounce = 0
	elif sculpting:
		_release_debounce += 1
		if _release_debounce >= 2:
			_end_stroke()
			_release_debounce = 0
	else:
		_release_debounce = 0
	if not sel_now and not _sel_drag_touched.is_empty():
		_sel_drag_touched.clear()
	# The hide/unhide stroke is committed on release, so its single undo step
	# covers the whole sweep.
	if not wmt_now and _wmt_drag_dirty:
		_end_wmt_drag()
	if active_tab == TAB_WMT:
		_tiles_process()

func _cursor_inside_viewport() -> bool:
	var vp := EditorInterface.get_editor_viewport_3d()
	return vp.get_visible_rect().has_point(vp.get_mouse_position())

# True when the mouse is over either floating overlay (top toolbar or mode
# sidebar), including their buttons. Input targeting those must be left alone:
# the plugin's own click handling and stroke polling would otherwise swallow
# the toolbar/mode button presses and start sculpting under them.
func _pointer_over_floats() -> bool:
	var vp := get_viewport()
	if vp == null:
		return false
	var hc := vp.gui_get_hovered_control()
	var n: Node = hc
	while n != null:
		if n == modes or n == toolbar or n == _paint_popup or n == _texture_popup:
			return true
		n = n.get_parent()
	return false

func _pointer_over_paint_popup() -> bool:
	return is_instance_valid(_paint_popup) and _paint_popup.visible \
			and _pointer_within_popup(_paint_popup)

func _pointer_within_popup(popup: Window) -> bool:
	return Rect2(Vector2.ZERO, popup.size).has_point(popup.get_mouse_position())

func _paint_popup_open() -> bool:
	return is_instance_valid(_paint_popup) and _paint_popup.visible

func _texture_picker_open() -> bool:
	return is_instance_valid(_texture_popup) and _texture_popup.visible

func _vertex_color_popup_open() -> bool:
	return is_instance_valid(_vertex_color_popup) and _vertex_color_popup.visible

# ---- vertex-paint color selector (Ctrl+RMB) --------------------------------
func _toggle_vertex_color_popup() -> void:
	if _vertex_color_popup_open():
		_vertex_color_popup.visible = false
		return
	_ensure_vertex_color_popup()
	if _vertex_color_popup == null or _vertex_color_picker == null:
		# _ensure already logged why. Bailing here (rather than dereferencing a
		# null picker) is what keeps a failed build from throwing on the next
		# line and skipping popup_centered entirely.
		return
	# Show the color the NEXT stroke will use.
	_vertex_color_syncing = true
	_vertex_color_picker.color = vertex_color
	_vertex_color_syncing = false
	# Sized explicitly: popup_centered() with no argument uses the combined
	# minimum size, which for a ColorPicker is tall enough to land off-screen -
	# and an off-screen popup is exactly what "the shortcut does nothing" looks
	# like from the user's side.
	_vertex_color_popup.popup_centered(Vector2i(300, 470))

func _ensure_vertex_color_popup() -> void:
	if _vertex_color_popup != null and is_instance_valid(_vertex_color_popup):
		return
	var op := _overlay_parent()
	if op == null:
		return
	var pc := PopupPanel.new()
	pc.name = "WmtVertexColorPopup"
	# Exclusive: an outside click closes it AND is consumed, so the click that
	# dismisses the picker can never start a paint stroke underneath it.
	pc.exclusive = true
	# Parent FIRST, then build. A popup that is not in the tree cannot be shown,
	# and anything that throws mid-build would otherwise leave a finished window
	# that was never added - which reads as "the shortcut does nothing".
	op.add_child(pc)
	var refs := build_vertex_color_popup_contents(pc)
	# Never keep a half-built popup. If the builder aborted partway (a bad
	# property, a renamed API) it hands back a Dictionary without the keys, and
	# every later access on it throws - which used to strand an empty, never-
	# shown window in the tree and report nothing but "the shortcut does
	# nothing". Validate up front, tear it down, and say so loudly.
	var picker_ref = refs.get("picker") if typeof(refs) == TYPE_DICTIONARY else null
	var eraser_ref = refs.get("eraser") if typeof(refs) == TYPE_DICTIONARY else null
	if not (picker_ref is ColorPicker) or not (eraser_ref is Button):
		push_error("[WMT] vertex color popup failed to build (picker=%s eraser=%s) - \
the Ctrl+RMB selector is unavailable" % [str(picker_ref), str(eraser_ref)])
		pc.queue_free()
		_vertex_color_popup = null
		_vertex_color_picker = null
		return
	_vertex_color_popup = pc
	_vertex_color_picker = picker_ref
	_vertex_color_picker.color_changed.connect(_on_vertex_picker_color_changed)
	(eraser_ref as Button).pressed.connect(_on_vertex_eraser_button)

# The selector's contents. Static, and it hands back the widgets it created, so
# the whole window can be built and exercised without an editor instance - the
# same shape as build_object_popup_contents. The two callbacks are wired by the
# instance, which is what knows the plugin's color/eraser rules.
static func build_vertex_color_popup_contents(pc: PopupPanel) -> Dictionary:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.14, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.47, 0.52)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(8)
	pc.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	pc.add_child(vb)
	var title := Label.new()
	title.text = "Vertex paint color"
	title.add_theme_font_size_override("font_size", 12)
	vb.add_child(title)
	var picker := ColorPicker.new()
	picker.name = "VertexColorPicker"
	picker.edit_alpha = false
	# ColorPicker.edit_fields DOES NOT EXIST in this Godot version. Assigning it
	# threw "Invalid assignment of property or key 'edit_fields'", which ABORTED
	# this function on the spot: the returned Dictionary came back empty, so
	# refs["picker"] failed, _vertex_color_picker stayed null, and
	# _toggle_vertex_color_popup then died on the next line - never reaching
	# popup_centered(). The whole selector was unreachable and the only symptom
	# was "the shortcut does nothing". hex_visible is the real property for the
	# hex entry, and is what makes a picked color readable/copyable.
	picker.hex_visible = true
	picker.sliders_visible = true
	# A ColorPicker's natural minimum is big enough to make popup_centered()
	# size the window off-screen, so the layout is bounded explicitly here.
	picker.custom_minimum_size = Vector2(260.0, 320.0)
	vb.add_child(picker)
	# One click to the eraser, so the 50%-gray rule is discoverable instead of
	# being folklore about the color picker.
	var eraser := Button.new()
	eraser.name = "VertexEraserButton"
	eraser.text = "Eraser (50% gray)"
	eraser.tooltip_text = "Picks 50% gray, which erases the tint back to neutral." \
		+ "\nThe same thing as Shift+RMB while painting."
	vb.add_child(eraser)
	var hint := Label.new()
	hint.name = "VertexColorHint"
	hint.text = "Shift+LMB paint   Shift+RMB erase   Ctrl+LMB pick from terrain"
	hint.add_theme_font_size_override("font_size", 10)
	hint.add_theme_color_override("font_color", Color(0.68, 0.72, 0.78))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	hint.custom_minimum_size = Vector2(260.0, 0.0)
	vb.add_child(hint)
	return {"picker": picker, "eraser": eraser, "hint": hint}

func _on_vertex_picker_color_changed(c: Color) -> void:
	# Pushing a color INTO the picker must not loop back out as a user edit,
	# which would reset the pick just from opening the popup.
	if _vertex_color_syncing:
		return
	_on_vertex_color_changed(c)

func _on_vertex_eraser_button() -> void:
	_vertex_color_syncing = true
	if _vertex_color_picker != null:
		_vertex_color_picker.color = WmtScript.VERTEX_TINT_ERASER
	_vertex_color_syncing = false
	_on_vertex_color_changed(WmtScript.VERTEX_TINT_ERASER)

func _ensure_paint_popup() -> void:
	if _paint_popup != null and is_instance_valid(_paint_popup):
		return
	var op := _overlay_parent()
	if op == null:
		return
	var pc := PopupPanel.new()
	pc.name = "WmtPaintChannelPopup"
	# Real popup window: exclusive so an outside click closes it AND is consumed
	# (it can never start a paint/sculpt stroke underneath the picker).
	pc.exclusive = true
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.14, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.47, 0.52)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(8)
	pc.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_paint_popup_boxes.clear()
	_paint_popup_tilings.clear()
	_paint_popup_depths.clear()
	for i in range(WmtScript.PAINT_CHANNELS):
		var col := VBoxContainer.new()
		col.add_theme_constant_override("separation", 3)
		var b := Button.new()
		b.custom_minimum_size = Vector2(88.0, 88.0)
		b.tooltip_text = "%s \u2014 click = select this channel\nShift+click = select and assign its texture" % PAINT_CHANNEL_NAMES[i]
		b.focus_mode = Control.FOCUS_NONE
		b.gui_input.connect(_on_paint_channel_box_input.bind(i))
		_paint_popup_boxes.append(b)
		var lbl := Label.new()
		lbl.text = PAINT_CHANNEL_NAMES[i]
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.custom_minimum_size = Vector2(58.0, 0.0)
		lbl.add_theme_font_size_override("font_size", 11)
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tspin := SpinBox.new()
		tspin.min_value = 1.0
		tspin.max_value = 256.0
		tspin.step = 1.0
		tspin.value = paint_channel_tilings[i] if i < paint_channel_tilings.size() else 16.0
		tspin.tooltip_text = "How many times channel %s's texture repeats across one tile" % PAINT_CHANNEL_NAMES[i]
		tspin.custom_minimum_size = Vector2(56.0, 0.0)
		tspin.alignment = HORIZONTAL_ALIGNMENT_CENTER
		tspin.value_changed.connect(_on_channel_tiling_changed.bind(i))
		_paint_popup_tilings.append(tspin)
		var dspin := SpinBox.new()
		dspin.min_value = 0.01
		dspin.max_value = 1.0
		dspin.step = 0.01
		dspin.value = paint_channel_depths[i] if i < paint_channel_depths.size() else paint_depth
		dspin.tooltip_text = "Masked depth for channel %s on the pinned tile(s); overrides the global Depth setting" % PAINT_CHANNEL_NAMES[i]
		dspin.custom_minimum_size = Vector2(56.0, 0.0)
		dspin.alignment = HORIZONTAL_ALIGNMENT_CENTER
		dspin.value_changed.connect(_on_channel_depth_changed.bind(i))
		_paint_popup_depths.append(dspin)
		col.add_child(b)
		col.add_child(lbl)
		col.add_child(tspin)
		col.add_child(dspin)
		row.add_child(col)
	vb.add_child(row)
	pc.add_child(vb)
	op.add_child(pc)
	_paint_popup = pc
	_refresh_paint_popup_sel()

func _toggle_paint_popup(_mouse_pos: Vector2) -> void:
	if _paint_popup_open():
		_close_paint_popup()
		return
	# Anchor the popup to the tile under the cursor and load THAT tile's actual
	# per-channel textures into the toolbox, so the popup shows what the picked
	# tile really uses (and texture assignments below affect only that tile).
	var t := terrain if is_instance_valid(terrain) else null
	if t != null and cursor_local != null:
		var tk := _tile_under_cursor()
		if tk != Vector2i(-1, -1) and t.tile_paints.has(tk):
			_picker_tile = tk
			_pull_tile_textures_into_toolbox(t, tk)
			_pull_tile_tilings_into_toolbox(t, tk)
			_pull_tile_depths_into_toolbox(t, tk)
	_ensure_paint_popup()
	if _paint_popup == null:
		return
	# Center the popup on the editor viewport(screen) instead of at the cursor.
	_paint_popup.popup_centered()
	_refresh_paint_popup_sel()

func _close_paint_popup() -> void:
	if _paint_popup != null and is_instance_valid(_paint_popup):
		_paint_popup.visible = false

func _refresh_paint_popup_sel() -> void:
	for i in _paint_popup_boxes.size():
		var b := _paint_popup_boxes[i] as Button
		if b == null:
			continue
		var path := paint_channel_textures[i] if i < paint_channel_textures.size() else ""
		b.icon = null
		b.expand_icon = false
		if path != "":
			var tex := _channel_tex(path)
			if tex != null:
				b.icon = tex
				b.expand_icon = true
		b.tooltip_text = PAINT_CHANNEL_NAMES[i]
		if path != "":
			b.tooltip_text += " \u2014 texture: %s" % path
		b.tooltip_text += "\nClick = select this channel, Shift+click = select and assign its texture"
		var sel := i == paint_channel
		var sbs := StyleBoxFlat.new()
		# With no texture the box shows the channel's physical side colour
		# (white = splatting its WHITE side, black = its BLACK side); a textured
		# channel previews the texture with NO background fill (transparent box,
		# just the thumbnail + selection ring). Boxes stay borderless; only the
		# ACTIVE channel gets a thick blue ring so it's easy to spot.
		if b.icon == null:
			sbs.bg_color = Color(0.98, 0.98, 0.96) if i % 2 == 0 else Color(0.07, 0.07, 0.08)
		else:
			sbs.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		sbs.set_corner_radius_all(0)
		if sel:
			sbs.set_border_width_all(3)
			sbs.border_color = Color(0.18, 0.55, 1.0)
		else:
			sbs.set_border_width_all(0)
		b.add_theme_stylebox_override("normal", sbs)
		b.add_theme_stylebox_override("hover", sbs)
		b.add_theme_stylebox_override("pressed", sbs)
		b.add_theme_stylebox_override("focus", sbs)
	_paint_popup_syncing = true
	for i in _paint_popup_tilings.size():
		var sp := _paint_popup_tilings[i] as SpinBox
		if sp != null:
			sp.value = paint_channel_tilings[i] if i < paint_channel_tilings.size() else 16.0
	for i in _paint_popup_depths.size():
		var dsp := _paint_popup_depths[i] as SpinBox
		if dsp != null:
			dsp.value = paint_channel_depths[i] if i < paint_channel_depths.size() else paint_depth
	_paint_popup_syncing = false

func _on_paint_channel_box_input(ev: InputEvent, index: int) -> void:
	if not (ev is InputEventMouseButton):
		return
	var mb := ev as InputEventMouseButton
	if not mb.pressed or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	_select_paint_channel(index, mb.shift_pressed)

func _select_paint_channel(index: int, open_picker: bool) -> void:
	if index < 0 or index >= WmtScript.PAINT_CHANNELS:
		return
	_close_paint_popup()
	_on_paint_channel_selected(index)
	if open_picker:
		_open_texture_picker(index)

func _on_channel_tiling_changed(value: float, index: int) -> void:
	if _paint_popup_syncing:
		return
	if index < 0 or index >= WmtScript.PAINT_CHANNELS:
		return
	var v := clampf(value, 1.0, 256.0)
	# Same scoping as texture changes: the toolbox slot is the spinbox's
	# "default", but with tiles selected the change pins every selected tile,
	# and otherwise it pins the right-clicked (picker) tile.
	paint_channel_tilings[index] = v
	_set_tile_tiling_scoped(index, v)
	_save_overlay_prefs()
	_apply_terrain_overlays()

# The tiles a paint-mode popup change applies to: the full selection, plus the
# popup/eyedropper anchor tile when it isn't already selected. The anchor stays
# in the mix so an edit made inside the popup right-clicked open on one tile of
# a selection visibly hits the tile it was opened on too.
func _paint_scoped_targets() -> Array:
	var t := terrain if is_instance_valid(terrain) else null
	var out: Array = []
	if not _paint_selected.is_empty():
		for key in _paint_selected:
			var tk := key as Vector2i
			if tk.x >= 0 and tk.y >= 0 and not out.has(tk):
				out.append(tk)
	var anchor := _anchor_tile()
	if anchor != Vector2i(-1, -1) and t != null and t.tile_textures.has(anchor) \
			and not out.has(anchor):
		out.append(anchor)
	return out

# Write a channel tiling change to every tile a texture/tiling change would hit
# (the selection plus the popup/eyedropper anchor tile). Purely per-tile: tiles
# without an override keep using the toolbox default.
func _set_tile_tiling_scoped(channel: int, value: float) -> void:
	var t := terrain if is_instance_valid(terrain) else null
	if t == null:
		return
	for tk in _paint_scoped_targets():
		_set_tile_tiling(t, tk, channel, value)
	# Layouts carry the per-tile repeat, so any pin forces an atlas rebuild.
	_paint_texture_atlas_dirty = true

# Pin one channel's repeat count on a tile, keeping the tile's other channel
# tilings intact.
func _set_tile_tiling(t: WmtScript, tk: Vector2i, channel: int, value: float) -> void:
	var tarr: Array = t.tile_tilings.get(tk, [])
	while tarr.size() <= channel:
		tarr.append(16.0)
	tarr[channel] = clampf(value, 1.0, 256.0)
	t.set_tile_tilings(tk.x, tk.y, tarr)

func _on_channel_depth_changed(value: float, index: int) -> void:
	if _paint_popup_syncing:
		return
	if index < 0 or index >= WmtScript.PAINT_CHANNELS:
		return
	var v := clampf(value, 0.01, 1.0)
	paint_channel_depths[index] = v
	_set_tile_depth_scoped(index, v)
	_save_overlay_prefs()
	_apply_terrain_overlays()

# Write a channel depth change to every tile a texture/tiling change would hit
# (the selection plus the popup/eyedropper anchor tile). Purely per-tile: tiles
# without an override keep using the global paint depth.
func _set_tile_depth_scoped(channel: int, value: float) -> void:
	var t := terrain if is_instance_valid(terrain) else null
	if t == null:
		return
	for tk in _paint_scoped_targets():
		_set_tile_depth(t, tk, channel, value)
	_paint_texture_atlas_dirty = true

# Pin one channel's masked depth on a tile, keeping the tile's other channel
# depths intact.
func _set_tile_depth(t: WmtScript, tk: Vector2i, channel: int, value: float) -> void:
	var darr: Array = t.tile_depths.get(tk, [])
	while darr.size() <= channel:
		darr.append(0.2)
	darr[channel] = clampf(value, 0.01, 1.0)
	t.set_tile_depths(tk.x, tk.y, darr)

func _on_paint_texture_requested(channel: int) -> void:
	if channel < 0 or channel >= WmtScript.PAINT_CHANNELS:
		return
	if channel < WmtScript.PAINT_CHANNELS:
		paint_channel = channel
		if panel != null and panel.has_method("set_paint_channel"):
			panel.set_paint_channel(channel)
	_refresh_paint_popup_sel()
	_save_overlay_prefs()
	_open_texture_picker(channel)

func _channel_tex(path: String) -> Texture2D:
	if path == "":
		return null
	if _texture_cache.has(path):
		return _texture_cache[path]
	var tex := load(path) as Texture2D
	if tex != null:
		_texture_cache[path] = tex
	return tex

# The "foo_s.png" specular-style sibling of a tileset texture: its ALPHA channel
# doubles as the texture's blend mask (#4). Absent when there is no _s file.
func _channel_mask(path: String) -> Texture2D:
	if path == "":
		return null
	var sm := path.get_basename() + "_s." + path.get_extension()
	if not ResourceLoader.exists(sm):
		return null
	return _channel_tex(sm)

# "_s" textures are masks, not surfaces: they never appear in the picker (#2).
# Tileset sibling images that are never pickable surfaces: "_s" soft blend
# masks (the alphamap baked into the array layer alpha) and "_h" heightmaps.
func _is_aux_variant(path: String) -> bool:
	var base := path.get_file().get_basename().to_lower()
	return base.ends_with("_s") or base.ends_with("_h")

# Ctrl+LMB eyedropper: load the per-channel textures of the tile under the
# cursor into the toolbox, anchor the picker to it, then select the splat
# channel that owns the spot (via WmtScript.channel_at_local) so the user
# paints exactly what is already there. Returns true on a painted spot.
func _eyedrop_paint_channel() -> bool:
	if cursor_local == null:
		return false
	if terrain == null or not is_instance_valid(terrain):
		return false
	if not terrain.has_method("channel_at_local"):
		return false
	var t := terrain
	var ci := t.channel_at_local(cursor_local)
	if ci < 0 or ci >= WmtScript.PAINT_CHANNELS:
		return false
	var tk := _tile_under_cursor()
	if tk != Vector2i(-1, -1):
		_picker_tile = tk
		if t.tile_paints.has(tk):
			_pull_tile_textures_into_toolbox(t, tk)
			_pull_tile_tilings_into_toolbox(t, tk)
	_on_paint_channel_selected(ci)
	return true

# Ctrl+LMB eyedropper for vertex color: read the color stored in the tint
# splatmap under the cursor and push it into the picker. Unpainted texels report
# coverage 0 and are ignored, so the picker keeps the color you already had.
func _eyedrop_vertex_tint() -> bool:
	if cursor_local == null:
		return false
	if terrain == null or not is_instance_valid(terrain):
		return false
	if not terrain.has_method("tint_at_local"):
		return false
	var t := terrain
	var c: Color = t.tint_at_local(cursor_local)
	if c.a <= 0.002:
		return false
	vertex_color = Color(c.r, c.g, c.b, 1.0)
	_save_overlay_prefs()
	if panel != null and panel.has_method("set_vertex_color"):
		panel.set_vertex_color(vertex_color)
	return true

func _collect_tileset_files(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if dir.current_is_dir():
			if not f.begins_with("."):
				_collect_tileset_files(dir_path.path_join(f), out)
		else:
			var p := dir_path.path_join(f)
			if p.get_extension().to_lower() in ["png", "jpg", "jpeg", "webp", "bmp"]:
				out.append({"path": p})
		f = dir.get_next()
	dir.list_dir_end()

func _scan_tileset() -> void:
	if not _tileset_entries.is_empty():
		return
	_collect_tileset_files("res://tileset", _tileset_entries)
	_tileset_entries.sort_custom(func(a, b): return str(a["path"]) < str(b["path"]))

func _ensure_texture_popup() -> void:
	if _texture_popup != null and is_instance_valid(_texture_popup):
		return
	var op := _overlay_parent()
	if op == null:
		return
	var pc := PopupPanel.new()
	pc.name = "WmtTexturePickerPopup"
	# A real popup window: it grabs input so the thumbnails are actually
	# clickable, closes on outside click / ESC, and sits above the viewport.
	pc.exclusive = true
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.14, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.47, 0.52)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(8)
	pc.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.add_child(_make_texture_preview_slider())
	var search := LineEdit.new()
	search.placeholder_text = "Search textures\u2026"
	search.clear_button_enabled = true
	search.add_theme_font_size_override("font_size", 12)
	search.text = _last_texture_search
	search.text_changed.connect(_on_texture_search_changed)
	vb.add_child(search)
	_texture_search = search
	var list := ItemList.new()
	list.name = "item_list"
	# Wide strip so all tileset images are easy to scan at once; previews are
	# 1.2x the previous size (96px -> 115px) so filenames stay readable.
	list.custom_minimum_size = Vector2(1220.0, 480.0)
	list.icon_mode = ItemList.ICON_MODE_TOP
	list.max_columns = 6
	list.fixed_icon_size = Vector2(115.0, 115.0)
	list.same_column_width = true
	list.fixed_column_width = 194
	list.max_text_lines = 2
	# Godot appends .bind() args AFTER the signal's own arguments, so binding
	# the list FIRST would hand (index, pos, mbi) to the typed `list` param and
	# every click would die with a conversion error. Forward explicitly instead.
	list.item_clicked.connect(func(index: int, _at_position: Vector2, mbi: int) -> void:
		_on_texture_item_clicked(list, index, _at_position, mbi))
	list.item_activated.connect(func(index: int) -> void:
		_on_texture_item_activated(list, index))
	vb.add_child(list)
	pc.add_child(vb)
	op.add_child(pc)
	_texture_popup = pc
	_texture_list = list

# Persistent bottom-panel tab that mirrors the popup texture picker (lands to
# the right of the built-in Shader Editor tab). Shares the popup's remembered
# search string, so the last filter survives restarts and both browsers always
# show the same grid.
func _ensure_texture_dock() -> void:
	# Deferred at boot; skip if the plugin is on its way out.
	if _exiting or not is_inside_tree():
		return
	if _texture_dock != null and is_instance_valid(_texture_dock):
		return
	var d := PanelContainer.new()
	d.name = "WmtTextureDock"
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.12, 0.13, 0.15, 1.0)
	sb.border_color = Color(0.30, 0.33, 0.38)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(8)
	d.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	vb.add_child(_make_texture_preview_slider())
	var search := LineEdit.new()
	search.placeholder_text = "Search textures\u2026"
	search.clear_button_enabled = true
	search.add_theme_font_size_override("font_size", 12)
	search.text = _last_texture_search
	search.text_changed.connect(_on_texture_search_changed)
	vb.add_child(search)
	_texture_dock_search = search
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.icon_mode = ItemList.ICON_MODE_TOP
	list.max_columns = 18
	list.fixed_icon_size = Vector2(86.0, 86.0)
	list.same_column_width = true
	list.fixed_column_width = 150
	list.max_text_lines = 2
	list.item_clicked.connect(func(index: int, _at_position: Vector2, mbi: int) -> void:
		_on_texture_item_clicked(list, index, _at_position, mbi))
	list.item_activated.connect(func(index: int) -> void:
		_on_texture_item_activated(list, index))
	vb.add_child(list)
	_texture_dock_list = list
	d.add_child(vb)
	var dock_tab: Button = add_control_to_bottom_panel(d, "Texture Browser")
	if dock_tab == null:
		d.queue_free()
		_texture_dock_list = null
		_texture_dock_search = null
		return
	_texture_dock = d
	_scan_tileset()
	_fill_texture_list(list)

# --- Object clipboard / paste ------------------------------------------------
# The world folder's object scenes (the imported .gltf props). The browser lists
# them like the texture browser lists tileset images; clicking one copies it.
# Pure geometry helpers for the object clipboard, kept static so they can be
# exercised without an editor instance.
#
# The group pivot is the AVERAGE of the copied members' origins. A single object
# pivots on its own origin, so pasting always lands the object's own origin (not
# its center) under the mouse.
static func group_pivot(origins: Array) -> Vector3:
	if origins.is_empty():
		return Vector3.ZERO
	var sum := Vector3.ZERO
	for o in origins:
		sum += (o as Vector3)
	return sum / float(origins.size())

# Where a member lands when the group is pasted with its pivot at "pivot":
# its own basis (rotation/scale) is kept and only the position is rebased, so
# the distances between the copied members are preserved exactly.
static func placed_transform(basis: Basis, offset: Vector3, pivot: Vector3) -> Transform3D:
	return Transform3D(basis, pivot + offset)

const OBJECT_ROOT := "res://world"
# Folder objects live in, so the browser only lists the world folder.
var _object_entries: Array = []
var _object_popup: PopupPanel = null
var _object_list: ItemList = null
# Live 3D preview of the highlighted object, rendered in its own SubViewport
# next to the list (the objects are .gltf props with no thumbnail of their own).
var _object_preview_box: SubViewportContainer
var _object_preview_vp: SubViewport = null
var _object_preview_stage: Node3D = null
var _object_preview_cam: Camera3D = null
var _object_preview_name: Label = null
var _object_preview_instance: Node = null
var _object_search: LineEdit = null
var _last_object_search := ""
# The object clipboard: one entry per copied object, each a Dictionary of
# {path, name, offset, xform, radius, size}. offset is relative to the clipboard
# PIVOT (0,0,0), never an absolute world position, so a pasted group keeps the
# shape of the copy instead of landing at the old coordinates.
var _object_clipboard: Array = []
# Objects copied with a single Ctrl+C keep their exact transform; a group copy
# (two or more) is rebased on the pivot and only the offsets are kept.
var _object_clip_is_group := false
# The instances created by the last paste, so they can be selected afterwards.
var _last_pasted: Array = []
# The scene paths that were selected in the browser last time it was open, so
# reopening can put the selection back. Paths, not indices: the list is
# re-filtered by the search box, so an index means something different every
# time.
var _object_selected_paths: Array[String] = []
# The last row the pointer was over, remembered so a reopen can land on it, plus
# the row index itself (the path survives the list being re-filtered, an index
# does not).
var _object_hover_path := ""
var _object_hover_index := -1
# Fingerprint of the browser's selection, diffed each frame to catch every kind
# of selection change - including ctrl-clicking a row back off, for which
# ItemList offers no signal of its own.
var _object_sel_signature := ""
# The last mouse position that was over the 3D viewport, and whether we have
# one. A paste is aimed with the mouse, but while the browser is open the
# pointer is over the browser - so the live position is the wrong one to use
# and this is what the paste actually aims at.
var _last_vp_mouse := Vector2.ZERO
var _last_vp_mouse_valid := false

func _scan_objects() -> void:
	if not _object_entries.is_empty():
		return
	_collect_object_files(OBJECT_ROOT, _object_entries)
	_object_entries.sort_custom(func(a, b): return str(a["path"]) < str(b["path"]))

static func _collect_object_files(dir_path: String, out: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var f := dir.get_next()
	while f != "":
		if dir.current_is_dir():
			if not f.begins_with("."):
				_collect_object_files(dir_path.path_join(f), out)
		else:
			# Object scenes: imported .gltf/.glb props plus any authored .tscn.
			var p := dir_path.path_join(f)
			if p.get_extension().to_lower() in ["gltf", "glb", "tscn", "scn"]:
				out.append({"path": p})
		f = dir.get_next()
	dir.list_dir_end()

func _open_object_picker() -> void:
	_scan_objects()
	_ensure_object_popup()
	if _object_popup == null or _object_list == null:
		return
	if _object_search != null:
		_object_search.text = _last_object_search
		_object_search.grab_focus()
	_refresh_object_picker_list()
	# Put the highlight back where it was left: the middle of the rows that were
	# picked, else the row last hovered, else the top one. Done after the list
	# is rebuilt (the search filter renumbers everything) and before showing, so
	# the browser never flashes up empty and then fills in.
	_restore_object_selection()
	_object_popup.popup_centered()

func _ensure_object_popup() -> void:
	if _object_popup != null and is_instance_valid(_object_popup):
		return
	var op := _overlay_parent()
	if op == null:
		print("[WMT objects] no overlay parent - object browser cannot open")
		return
	var pc := PopupPanel.new()
	pc.name = "WmtObjectPickerPopup"
	pc.exclusive = true
	# Parent the window into the tree BEFORE anything else is built. Anything
	# that fails while assembling the contents (the 3D preview especially) must
	# not leave a fully built window that was never added, because the window
	# would then look like it "never opened".
	_object_popup = pc
	op.add_child(pc)
	var refs := build_object_popup_contents(pc)
	_object_search = refs["search"]
	_object_list = refs["list"]
	_object_preview_vp = refs["preview_vp"]
	_object_preview_box = refs["preview_box"]
	_object_preview_stage = refs["preview_stage"]
	_object_preview_cam = refs["preview_cam"]
	_object_preview_name = refs["preview_name"]
	# The builder is static and knows nothing of the instance handlers, so the
	# instance wires them here. Clicking a row is what copies the object, and
	# selecting one is what starts the preview - with these unconnected the
	# browser looked perfectly alive but did nothing at all.
	# Stop burning GPU on a preview nobody can see once the browser closes.
	_object_popup.visibility_changed.connect(_on_object_popup_visibility_changed)
	_object_search.text_changed.connect(_on_object_search_changed)
	_object_list.item_selected.connect(_on_object_item_selected)
	_object_list.item_activated.connect(_on_object_item_activated)
	# ItemList has no hover signal and no deselect signal in Godot 4 (it has
	# item_hovered/deselected on some builds and NOT on others - connecting a
	# missing signal is a runtime error, not a parse error, so it has to be
	# avoided by construction). Hover is therefore taken from the list's own
	# gui_input, and a deselect is caught by _sync_object_selection() diffing the
	# selection every frame, which is correct no matter which signal the click
	# happened to emit.
	_object_list.gui_input.connect(_on_object_list_gui_input)

# The window's contents. Static, and it hands back every widget it created, so
# the whole window (search + list + live 3D preview) can be built and exercised
# without an editor instance.
static func build_object_popup_contents(pc: PopupPanel) -> Dictionary:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.14, 0.16, 0.97)
	sb.border_color = Color(0.42, 0.47, 0.52)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(0)
	sb.set_content_margin_all(8)
	pc.add_theme_stylebox_override("panel", sb)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	var search := LineEdit.new()
	search.placeholder_text = "Search objects\u2026"
	search.clear_button_enabled = true
	search.add_theme_font_size_override("font_size", 12)
	vb.add_child(search)
	# List on the left, live 3D preview of the highlighted object on the right.
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	vb.add_child(row)
	var list := ItemList.new()
	list.name = "item_list"
	list.custom_minimum_size = Vector2(300.0, 420.0)
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.max_columns = 1
	# Multi-select: the browser is also the paste source, and pasting a group
	# of props in one go is the common case. Ctrl/Cmd-click and Shift-click
	# both add to the selection, and the whole selection is what gets copied.
	list.select_mode = ItemList.SELECT_MULTI
	list.add_theme_font_size_override("font_size", 12)
	row.add_child(list)
	var preview_holder := VBoxContainer.new()
	preview_holder.add_theme_constant_override("separation", 4)
	row.add_child(preview_holder)
	var preview_frame := PanelContainer.new()
	var pstyle := StyleBoxFlat.new()
	pstyle.bg_color = Color(0.09, 0.1, 0.12, 1.0)
	pstyle.border_color = Color(0.42, 0.47, 0.52)
	pstyle.set_border_width_all(1)
	preview_frame.add_theme_stylebox_override("panel", pstyle)
	# The SIZE belongs on the PanelContainer, not on the SubViewport: a
	# SubViewport is a Viewport, not a Control, so it has no
	# custom_minimum_size - setting one threw mid-build and aborted the window
	# before it was ever parented, which is why the browser "never opened".
	preview_frame.custom_minimum_size = Vector2(220.0, 220.0)
	preview_holder.add_child(preview_frame)
	# The SubViewport MUST sit inside a SubViewportContainer. A SubViewport only
	# ever renders into an offscreen ViewportTexture, and a bare SubViewport
	# parented to a plain Control draws NOTHING - there was no code path that
	# ever blitted that texture to the screen, so the preview pane stayed an
	# empty dark box no matter what was instanced into it. SubViewportContainer
	# is the node that actually draws its SubViewport's output, and with
	# stretch on it also keeps the viewport sized to the frame.
	var preview_box := SubViewportContainer.new()
	preview_box.stretch = true
	preview_box.custom_minimum_size = Vector2(220.0, 220.0)
	preview_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview_frame.add_child(preview_box)
	var preview_vp := SubViewport.new()
	preview_vp.name = "ObjectPreview"
	preview_vp.size = Vector2i(220, 220)
	preview_vp.transparent_bg = false
	preview_vp.own_world_3d = true
	# Render while the browser is open, not "once": UPDATE_ONCE fires a single
	# frame, and the popup re-lays-out its contents (and the container resizes
	# the viewport) every time it is shown, which recycles the texture and
	# leaves the frame permanently blank. A 220x220 viewport is cheap.
	preview_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	preview_box.add_child(preview_vp)
	var preview_name := Label.new()
	preview_name.text = "No object selected"
	preview_name.add_theme_font_size_override("font_size", 11)
	preview_name.add_theme_color_override("font_color", Color(0.8, 0.84, 0.9))
	preview_name.custom_minimum_size = Vector2(220.0, 30.0)
	preview_name.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	preview_holder.add_child(preview_name)
	# The camera and its key/fill lights live in the SubViewport's own world.
	var preview_stage := Node3D.new()
	preview_vp.add_child(preview_stage)
	var pkey := DirectionalLight3D.new()
	pkey.light_energy = 1.4
	pkey.rotation_degrees = Vector3(-42.0, 38.0, 0.0)
	preview_stage.add_child(pkey)
	var pfill := DirectionalLight3D.new()
	pfill.light_energy = 0.5
	pfill.light_specular = 0.0
	pfill.rotation_degrees = Vector3(-20.0, -140.0, 0.0)
	preview_stage.add_child(pfill)
	var preview_cam := Camera3D.new()
	preview_cam.fov = 40.0
	preview_stage.add_child(preview_cam)
	# A SubViewport renders through whichever camera is CURRENT in its own
	# world; without this the viewport drew nothing and the preview pane stayed
	# empty even though the object was instanced and framed correctly.
	preview_cam.current = true
	pc.add_child(vb)
	return {"search": search, "list": list, "preview_vp": preview_vp,
		"preview_box": preview_box, "preview_stage": preview_stage,
		"preview_cam": preview_cam, "preview_name": preview_name}

func _on_object_popup_visibility_changed() -> void:
	if _object_popup == null or _object_preview_vp == null:
		return
	# Keep rendering only while the browser is actually on screen AND holding a
	# preview, so showing the list (with no selection) is free.
	var want := _object_popup.visible and _object_preview_instance != null \
		and is_instance_valid(_object_preview_instance)
	_object_preview_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if want \
		else SubViewport.UPDATE_DISABLED

func _on_object_search_changed(v: String) -> void:
	_last_object_search = v
	_save_overlay_prefs()
	# Remember what is picked NOW, because the rebuild below clears the
	# selection, and _restore_object_selection reads it back. Re-finding by path
	# is what keeps the same object highlighted as the filter narrows the rows
	# around it, instead of jumping to whatever lands on the old index.
	_remember_object_selection()
	_refresh_object_picker_list()
	_restore_object_selection()

func _refresh_object_picker_list() -> void:
	if _object_list == null:
		return
	_object_list.clear()
	var q := _last_object_search.strip_edges().to_lower()
	for e in _object_entries:
		var path := str(e["path"])
		if q != "" and not path.to_lower().contains(q):
			continue
		var rel := path
		if rel.begins_with(OBJECT_ROOT + "/"):
			rel = rel.substr(OBJECT_ROOT.length() + 1)
		var idx := _object_list.item_count
		_object_list.add_item(_two_line_texture_label(rel))
		_object_list.set_item_metadata(idx, path)
		_object_list.set_item_tooltip(idx, path)

# ItemList.item_selected / item_activated pass ONLY the index (unlike
# item_clicked, which also passes the list), so these take a single argument -
# binding them to a (list, index) signature silently did nothing on click.
# Render the object under the cursor/highlight into the SubViewport beside the
# list, drawing it through the SubViewportContainer that actually blits the
# viewport's texture to the screen.
func _refresh_object_preview(index: int = -1) -> void:
	if _object_preview_vp == null or _object_preview_stage == null \
			or _object_preview_cam == null:
		return
	if _object_list == null or index < 0 or index >= _object_list.item_count:
		_clear_object_preview()
		return
	var path := str(_object_list.get_item_metadata(index))
	if path == "" or not ResourceLoader.exists(path):
		_clear_object_preview()
		return
	var px := load(path) as PackedScene
	if px == null:
		_clear_object_preview()
		return
	_clear_object_preview()
	var inst := px.instantiate()
	if inst == null:
		return
	_object_preview_stage.add_child(inst)
	_object_preview_instance = inst
	# Frame the object's actual bounds so a huge tree and a small rock are both
	# shown filling the box instead of a speck or a clipped giant.
	var bounds := AABB()
	var first := true
	for m in inst.find_children("*", "VisualInstance3D", true, false):
		var vi := m as VisualInstance3D
		if vi == null:
			continue
		var b := vi.get_aabb()
		if first:
			bounds = b
			first = false
		else:
			bounds = bounds.merge(b)
	if first or bounds.size.length() <= 0.001:
		bounds = AABB(Vector3(-0.5, 0.0, -0.5), Vector3.ONE)
	frame_camera(_object_preview_cam, bounds)
	_object_preview_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	if _object_preview_name != null:
		_object_preview_name.text = "%s\nsize %.1f x %.1f x %.1f" % [
			path.get_file(), bounds.size.x, bounds.size.y, bounds.size.z]

# Frame a camera on a bounds box: a three-quarter view from above-front (the
# usual asset-preview angle), pulled back far enough that the object fills the
# frame instead of being a speck or clipped. Static so it is testable.
static func frame_camera(cam: Camera3D, bounds: AABB) -> void:
	if cam == null:
		return
	var b := bounds
	if b.size.length() <= 0.001:
		b = AABB(Vector3(-0.5, 0.0, -0.5), Vector3.ONE)
	var center := b.get_center()
	var radius := maxf(b.size.length() * 0.5, 0.5)
	var dist := radius / tan(deg_to_rad(cam.fov * 0.5)) * 1.15
	var dir := Vector3(0.75, 0.55, 1.0).normalized()
	cam.position = center + dir * dist
	cam.look_at(center, Vector3.UP)

func _clear_object_preview() -> void:
	if _object_preview_instance != null and is_instance_valid(_object_preview_instance):
		_object_preview_instance.queue_free()
	_object_preview_instance = null
	if _object_preview_vp != null:
		_object_preview_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _object_preview_name != null:
		_object_preview_name.text = "No object selected"

func _on_object_item_selected(index: int) -> void:
	# The whole SELECTION is the clipboard, not just the row that was clicked,
	# so building a group is: click the first row, Ctrl+click the rest.
	_copy_selection_from_picker()
	# The index MUST be forwarded: _refresh_object_preview defaults to -1, and
	# the -1 guard clears the preview and returns. So a single click copied the
	# object and left the preview pane empty, while a double-click (which does
	# pass the index) rendered fine - which is why this read as "previews don't
	# work" rather than as a wiring bug.
	# With several rows selected the preview is ambiguous, so it follows the row
	# under the pointer when there is one and otherwise the newest pick.
	_refresh_object_preview(index if _selected_object_count() <= 1 \
			else _hovered_object_index())

# Hover tracking. There is no item_hovered signal to use, so the row under the
# pointer is read straight off the list's own input. Remembered so the next open
# can land on this row, and it is also the best preview target while several rows
# are selected and there is no longer a single "the" selected row.
func _on_object_list_gui_input(event: InputEvent) -> void:
	if _object_list == null or _object_list.item_count == 0:
		return
	if event is InputEventMouseMotion:
		_set_object_hover(_object_list.get_item_at_position((event as InputEventMouseMotion).position))
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
			_set_object_hover(_object_list.get_item_at_position(mb.position))

func _set_object_hover(index: int) -> void:
	if _object_list == null or index < 0 or index >= _object_list.item_count:
		return
	if index == _object_hover_index:
		return
	_object_hover_index = index
	var path := str(_object_list.get_item_metadata(index))
	if path != "":
		_object_hover_path = path
	if _selected_object_count() > 1:
		_refresh_object_preview(index)

# The selection can change in ways that are not one signal: a plain click, a
# Ctrl+click that ADDS a row, a Ctrl+click that takes one back OFF, a Shift+click
# that fills a range, or the arrow keys. Rather than guess which signal covers
# which, the selection is diffed once a frame while the browser is open and
# anything that moved rebuilds the clipboard. Cheap - a small array compare - and
# it only runs while the browser is actually on screen.
func _sync_object_selection() -> void:
	if _object_list == null:
		return
	var sig := str(_object_list.get_selected_items())
	if not _object_picker_open():
		_object_sel_signature = sig
		return
	if sig == _object_sel_signature:
		return
	_object_sel_signature = sig
	_copy_selection_from_picker()
	var sel: Array = _object_list.get_selected_items()
	_refresh_object_preview(int(sel[0]) if sel.size() == 1 else -1)

func _on_object_item_activated(index: int) -> void:
	_copy_selection_from_picker()
	_refresh_object_preview(index)
	# Enter (and double-click) is the "I'm done here" gesture, so it closes.
	# A plain click does NOT: the whole point of the browser staying open is
	# that you can Ctrl+V into the scene and then keep picking.
	if _object_popup != null and is_instance_valid(_object_popup):
		_object_popup.visible = false

# ItemList has no clear_selection()/unselect_all() and no find_item_metadata()
# either, so both are done by hand.
func _clear_object_selection() -> void:
	if _object_list == null:
		return
	for i in _object_list.get_selected_items():
		_object_list.deselect(int(i))

func _object_index_of_path(path: String) -> int:
	if _object_list == null or path == "":
		return -1
	for i in _object_list.item_count:
		if str(_object_list.get_item_metadata(i)) == path:
			return i
	return -1

func _selected_object_count() -> int:
	if _object_list == null:
		return 0
	return _object_list.get_selected_items().size()

func _hovered_object_index() -> int:
	if _object_list == null or _object_hover_index < 0:
		return -1
	if _object_hover_index >= _object_list.item_count:
		return -1
	return _object_hover_index

# The row the browser should highlight when it opens: the middle of whatever was
# selected last time, else the row the pointer was last over, else the top one.
# Paths rather than indices, because the search box changes what each index
# means between openings.
func _restore_object_selection() -> void:
	if _object_list == null:
		return
	# The list is repopulated by the search filter, so re-find the remembered
	# rows by path and drop any that the current filter hides.
	var indices: Array[int] = []
	for p in _object_selected_paths:
		var found := _object_index_of_path(p)
		if found >= 0:
			indices.append(found)
	if indices.is_empty() and _object_hover_path != "":
		var h := _object_index_of_path(_object_hover_path)
		if h >= 0:
			indices.append(h)
	_clear_object_selection()
	if indices.is_empty():
		# Nothing remembered (or all of it filtered away): start at the top
		# rather than leaving the browser with no selection at all.
		if _object_list.item_count > 0:
			_object_list.select(0)
			_remember_object_selection()
			_copy_selection_from_picker()
			_refresh_object_preview(0)
		return
	# "The one in the center" of the previous selection: the middle row of the
	# remembered ones, by position in the list. Picking the middle rather than
	# the first means reopening lands you back in the middle of what you were
	# working with, not back at one edge of it.
	indices.sort()
	var pick: int = indices[indices.size() / 2]
	_object_list.select(pick)
	_remember_object_selection()
	_copy_selection_from_picker()
	_refresh_object_preview(pick)

func _remember_object_selection() -> void:
	_object_selected_paths.clear()
	if _object_list == null:
		return
	for i in _object_list.get_selected_items():
		var idx := int(i)
		if idx >= 0 and idx < _object_list.item_count:
			_object_selected_paths.append(str(_object_list.get_item_metadata(idx)))

# Clicking rows in the browser copies them to the clipboard: one entry per
# selected row, with the system's clipboard text set to the joined paths so it
# survives across the editor and other tools.
func _copy_selection_from_picker() -> void:
	if _object_list == null:
		return
	var rows := _object_list.get_selected_items()
	# Keep the per-frame diff in step, so the next frame does not see a "change"
	# that this very call just made and copy everything a second time.
	_object_sel_signature = str(rows)
	_remember_object_selection()
	if rows.is_empty():
		# Nothing selected: drop the clipboard rather than silently pasting
		# whatever happened to be there from a previous pick.
		_object_clipboard = []
		_object_clip_is_group = false
		_sync_object_preview()
		return
	var paths: Array[String] = []
	for r in rows:
		var idx := int(r)
		if idx < 0 or idx >= _object_list.item_count:
			continue
		var path := str(_object_list.get_item_metadata(idx))
		if path != "":
			paths.append(path)
	if paths.size() == 1:
		_copy_single_object(paths[0])
		DisplayServer.clipboard_set(paths[0])
	elif paths.size() > 1:
		_copy_object_group(paths)
		DisplayServer.clipboard_set("\n".join(paths))
	_sync_object_preview()

# Several browser rows picked at once: the same group semantics as a Ctrl+C of
# scene nodes - the members are stored as offsets from the group pivot so the
# spacing the user picked survives the paste. A browser group has no rotations
# (rows are just files), so every basis is identity and the pivot is the
# average, which makes the paste land the group centred under the cursor.
func _copy_object_group(paths: Array[String]) -> void:
	var entries: Array = []
	var loaded: Array[PackedScene] = []
	var total := 0.0
	for path in paths:
		if not ResourceLoader.exists(path):
			push_warning("[WMT objects] missing file, cannot copy: " + path)
			continue
		var px := load(path) as PackedScene
		if px == null:
			push_warning("[WMT objects] this object could not be loaded (a missing "
				+ "material or texture?), so it cannot be copied: " + path)
			continue
		loaded.append(px)
		total += _object_footprint_radius(px)
	if loaded.is_empty():
		return
	# Every member is centred on the group, so the offsets are all zero and the
	# pivot is the centre of the pasted footprint. They stack at the cursor
	# rather than spreading out over the old world positions.
	for i in loaded.size():
		var path2 := paths[i] if i < paths.size() else ""
		if path2 == "":
			continue
		entries.append({
			"path": path2,
			"name": path2.get_file(),
			"offset": Vector3.ZERO,
			"basis": Basis.IDENTITY,
			"radius": _object_footprint_radius(loaded[i]),
		})
	_object_clipboard = entries
	_object_clip_is_group = true
	_sync_object_preview()

# A scene node's local origin relative to a pivot, plus a rough footprint radius
# for the preview. Instances are sized from the packed scene's mesh AABB so a
# big tree and a small rock read differently in the stamp.
static func _object_footprint_radius(px: PackedScene) -> float:
	if px == null:
		return 1.0
	var inst := px.instantiate()
	if inst == null:
		return 1.0
	var acc := 0.0
	for m in inst.find_children("*", "VisualInstance3D", true, false):
		var vi := m as VisualInstance3D
		if vi == null or not vi.visible:
			continue
		var b := vi.get_aabb()
		acc = maxf(acc, b.size.length() * 0.5)
	inst.free()
	return maxf(0.35, acc)

# Copy a single scene path: one clipboard entry whose offset is zero, because a
# single object pastes by its own origin (not its center).
func _copy_single_object(path: String) -> void:
	if not ResourceLoader.exists(path):
		push_warning("[WMT objects] missing file, cannot copy: " + path)
		return
	var px := load(path) as PackedScene
	if px == null:
		# A scene can be on disk but unloadable (a material or texture it
		# references is missing). Say so rather than swallowing the click and
		# leaving the user wondering why nothing happened.
		push_warning("[WMT objects] this object could not be loaded (a missing "
			+ "material or texture?), so it cannot be copied: " + path)
		return
	var radius := _object_footprint_radius(px)
	_object_clipboard = [{
		"path": path,
		"name": path.get_file(),
		"offset": Vector3.ZERO,
		"basis": Basis.IDENTITY,
		"radius": radius,
	}]
	_object_clip_is_group = false
	_sync_object_preview()

# Copy whatever scene nodes the user has selected. A single node copies as one
# object (pastes by its own origin). Two or more copy as a GROUP: the pivot is
# the average of the members' origins, and each member is stored as an offset
# from that pivot plus its own basis, so pasting the group anywhere keeps the
# exact distances between the members instead of their old world coordinates.
func _copy_selected_objects() -> void:
	var sel := EditorInterface.get_selection()
	var nodes: Array = sel.get_selected_nodes() if sel != null else []
	var out: Array = []
	var sum := Vector3.ZERO
	for n in nodes:
		if not (n is Node3D):
			continue
		var node := n as Node3D
		var path := node.scene_file_path
		if path == "" or not ResourceLoader.exists(path):
			continue
		# If an ancestor of this node is also selected, the ancestor's scene
		# already contains it, so only copy the top of each selected subtree.
		var nested := false
		for other in nodes:
			if other != node and other is Node and node.is_ancestor_of(other):
				nested = true
				break
		if nested:
			continue
		var px := load(path) as PackedScene
		out.append({"path": path, "name": path.get_file(),
			"basis": node.global_transform.basis,
			"origin": node.global_position,
			"radius": _object_footprint_radius(px)})
		sum += node.global_position
	if out.is_empty():
		return
	# The pivot is the average of the member origins: a single object pivots on
	# its own origin, a group on the average, which is the point that then
	# follows the mouse on paste.
	var pivot := group_pivot(out.map(func(e: Dictionary) -> Vector3:
		return e["origin"]))
	for e in out:
		e["offset"] = (e["origin"] as Vector3) - pivot
		e.erase("origin")
	_object_clipboard = out
	_object_clip_is_group = out.size() > 1
	_sync_object_preview()
	var paths := PackedStringArray()
	for e in _object_clipboard:
		paths.append(str(e["path"]))
	DisplayServer.clipboard_set("\n".join(paths))
	print("[WMT objects] copied %d object(s), pivot %s" % [
		out.size(), str(pivot.round())])

func _sync_object_preview() -> void:
	if panel != null and panel.has_method("set_object_clipboard"):
		panel.set_object_clipboard(_object_clipboard)

# Paste the clipboard onto the terrain under the mouse. The ray hit point is the
# PIVOT: for a single object that is the object's own origin, for a group it is
# the group's average center, and each member keeps its relative offset from it.
func _paste_objects_at_cursor() -> void:
	if _object_clipboard.is_empty():
		return
	# Resolve the terrain from the plugin state or the scene, never from the
	# editor selection: pasting must not require selecting the WMT first.
	var t := _target_terrain()
	if t == null or not is_instance_valid(t):
		return
	# Aim at the last point the pointer was over the VIEWPORT, not at wherever
	# the pointer is now: pasting straight out of the object browser means the
	# pointer is on the browser, and the browser is deliberately left open.
	var aim := _paste_mouse_position()
	var local_pt: Variant = _local_point_under_mouse(aim)
	if local_pt == null:
		# Fall back to the flat plane so a paste at the horizon still lands
		# instead of silently doing nothing.
		local_pt = _flat_point_under_mouse(aim)
	if local_pt == null:
		return
	var pivot: Vector3 = t.to_global(local_pt)
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var placed := 0
	# The instances and their target transforms are staged first and applied by
	# the undo action, so the tree and the history can never disagree.
	var created: Array[Node] = []
	var xforms: Array[Transform3D] = []
	_last_pasted.clear()
	for e in _object_clipboard:
		var path := str(e["path"])
		if not ResourceLoader.exists(path):
			continue
		var px := load(path) as PackedScene
		if px == null:
			continue
		var inst := px.instantiate()
		if inst == null:
			continue
		var off: Vector3 = e.get("offset", Vector3.ZERO)
		var basis: Basis = e.get("basis", Basis.IDENTITY)
		# The origin (single) / group pivot (group) lands exactly on the hit;
		# members keep their own rotation and scale and are placed by
		# pivot + their stored relative offset, so the copy's spacing survives.
		_last_pasted.append(inst)
		created.append(inst)
		xforms.append(placed_transform(basis, off, pivot))
		placed += 1
	if placed > 0:
		# Record the whole paste as ONE editor action. Committing the action is
		# what actually performs the add, so the nodes are not parented here
		# first - doing both would paste two of everything on the first try and
		# one of nothing on undo. The undo side frees the instances (which
		# detaches them from the tree), and redo re-runs the add side, so a
		# pasted group can be taken back as a unit and put back as a unit.
		var urm := EditorInterface.get_editor_undo_redo()
		var label := "Paste object" if placed == 1 else "Paste %d objects" % placed
		urm.create_action(label)
		for i in created.size():
			var node: Node = created[i]
			urm.add_do_method(root, "add_child", node)
			urm.add_do_method(node, "set_owner", root)
			urm.add_do_method(node, "set_transform", xforms[i])
			urm.add_undo_method(node, "free")
		urm.commit_action()
		# Hand the new objects to the editor straight away so they can be moved
		# or rotated without another click. This is also what used to "unselect"
		# the terrain, which the next paste no longer cares about.
		var sel := EditorInterface.get_selection()
		if sel != null:
			sel.clear()
			for inst2 in _last_pasted:
				if is_instance_valid(inst2):
					sel.add_node(inst2)
		print("[WMT objects] pasted %d object(s) at %s" % [placed, str(pivot.round())])

func _open_texture_picker(channel: int) -> void:
	if channel < 0 or channel >= WmtScript.PAINT_CHANNELS:
		return
	_texture_picker_channel = channel
	_scan_tileset()
	_ensure_texture_popup()
	if _texture_popup == null or _texture_list == null:
		return
	if _texture_search != null:
		_texture_search.text = _last_texture_search
		_texture_search.grab_focus()
	_refresh_texture_picker_list(_last_texture_search)
	# Center the picker on the editor viewport(screen).
	_texture_popup.popup_centered()

# One shared handler for both search boxes: remember the last filter (persisted
# across sessions), then rebuild the grids.
func _on_texture_search_changed(v: String) -> void:
	_last_texture_search = v
	_save_overlay_prefs()
	_refresh_texture_picker_list(v)

# Shared preview-size slider row (placed above the search box in BOTH browsers).
# Changing it re-sizes every thumbnail instantly; the percentage persists.
func _make_texture_preview_slider() -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var lbl := Label.new()
	lbl.text = "Preview size"
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.custom_minimum_size = Vector2(74.0, 0.0)
	row.add_child(lbl)
	var sl := HSlider.new()
	sl.min_value = 50.0
	sl.max_value = 300.0
	sl.step = 25.0
	sl.custom_minimum_size = Vector2(0.0, 18.0)
	sl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sl.value = _texture_preview_pct
	var pct := Label.new()
	pct.text = "%d%%" % int(_texture_preview_pct)
	pct.add_theme_font_size_override("font_size", 11)
	pct.custom_minimum_size = Vector2(38.0, 0.0)
	row.add_child(sl)
	row.add_child(pct)
	sl.value_changed.connect(_on_texture_preview_changed)
	sl.value_changed.connect(func(v: float) -> void: pct.text = "%d%%" % int(v))
	return row

func _on_texture_preview_changed(v: float) -> void:
	_texture_preview_pct = clampf(v, 50.0, 300.0)
	_save_overlay_prefs()
	_refresh_texture_picker_list(_last_texture_search)

# Apply the current preview percentage to one browser's grid (icon tile size,
# column width, and column count for the fixed-width popup).
func _apply_texture_list_layout(list: ItemList) -> void:
	if list == null:
		return
	var s := _texture_preview_pct / 100.0
	var iw := 115.0
	var cw := 194.0
	if list == _texture_dock_list:
		iw = 86.0
		cw = 150.0
	var icon := int(round(iw * s))
	var colw := int(round(cw * s))
	list.fixed_icon_size = Vector2(icon, icon)
	list.fixed_column_width = colw
	if list == _texture_dock_list:
		list.max_columns = 18
	else:
		list.max_columns = maxi(3, int(1200.0 / max(colw, 1)))

# Fill (or refill, honoring the search filter) both texture browsers. The "None
# - flat color" entry stays first; "_s" blend-mask siblings stay unpickable.
func _refresh_texture_picker_list(_filter := "") -> void:
	_fill_texture_list(_texture_list)
	if _texture_dock_list != null:
		_fill_texture_list(_texture_dock_list)

func _fill_texture_list(list: ItemList) -> void:
	if list == null:
		return
	_apply_texture_list_layout(list)
	var current := paint_channel_textures[_texture_picker_channel] \
			if _texture_picker_channel < paint_channel_textures.size() else ""
	var q := _last_texture_search.strip_edges().to_lower()
	list.clear()
	list.add_item("None \u2014 flat color")
	list.set_item_metadata(0, "")
	var sel := -1
	for e in _tileset_entries:
		var path := str(e["path"])
		# "_s" siblings are blend masks, never pickable surfaces (#2).
		if _is_aux_variant(path):
			continue
		if q != "":
			var fn := path.get_file().to_lower()
			if not fn.contains(q) and not path.to_lower().contains(q):
				continue
		var idx := list.item_count
		# Label each texture with its path relative to the tileset folder
		# (e.g. "expansion07/desertzone/8des_rock03_512.png") so same-named
		# files from different folders stay distinguishable; wraps to 2 lines.
		var rel := path
		const TILESET_ROOT := "res://tileset"
		if rel.begins_with(TILESET_ROOT + "/"):
			rel = rel.substr(TILESET_ROOT.length() + 1)
		list.add_item(_two_line_texture_label(rel), _channel_tex(path))
		list.set_item_metadata(idx, path)
		list.set_item_tooltip(idx, path)
		if path == current:
			sel = idx
	if sel >= 0:
		list.select(sel)

# ItemList has no text autowrap: fold a long relative path onto a second line
# at a folder boundary (never splitting the filename) so the picker's
# max_text_lines = 2 shows folder + file cleanly.
func _two_line_texture_label(rel: String) -> String:
	if rel.length() <= 24:
		return rel
	var cut := rel.rfind("/", 20)
	if cut <= 0:
		return rel
	return rel.left(cut) + "\n" + rel.substr(cut + 1)

func _close_texture_picker() -> void:
	if _texture_popup != null and is_instance_valid(_texture_popup):
		_texture_popup.visible = false

# Shared by the popup and the docked texture tab: the bound ItemList tells the
# handlers which grid the click came from.
func _on_texture_item_clicked(list: ItemList, index: int, at_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index != MOUSE_BUTTON_LEFT:
		return
	_assign_picked_texture(list, index)

func _on_texture_item_activated(list: ItemList, index: int) -> void:
	_assign_picked_texture(list, index)

func _assign_picked_texture(list: ItemList, index: int) -> void:
	if list == null:
		return
	if index < 0 or index >= list.item_count:
		return
	# The popup opens FOR one channel (splat button / Ctrl+RMB) and assigns to
	# it; the docked browser has no session of its own, so it assigns to the
	# ACTIVE paint channel - clicking a texture there changes what the brush
	# will paint, which is what "it does nothing" used to look like.
	var channel := _texture_picker_channel
	if list == _texture_dock_list:
		channel = paint_channel
	var path := String(list.get_item_metadata(index))
	_assign_channel_texture(channel, path)
	# Assigning from either browser is a full pick; the popup closes, the dock
	# tab stays put so painting can continue side by side.
	_close_texture_picker()

func _assign_channel_texture(channel: int, path: String) -> void:
	if channel < 0 or channel >= WmtScript.PAINT_CHANNELS:
		return
	while paint_channel_textures.size() <= channel:
		paint_channel_textures.append("")
	paint_channel_textures[channel] = path
	# With any tiles selected the assignment is per-tile BUT multi-target: every
	# selected tile gets this channel set to this texture (painted or not, so it
	# pre-maps tiles you're about to paint). With no selection it anchors to a
	# single tile (the channel popup / eyedropper pick, else the last painted).
	# Nothing is retroactive and there is no global combo fallback.
	var t := terrain if is_instance_valid(terrain) else null
	var applied := 0
	if t != null and not _paint_selected.is_empty():
		for key in _paint_selected:
			var tk := key as Vector2i
			if tk.x < 0 or tk.y < 0:
				continue
			_set_tile_slot_texture(t, tk, channel, path)
			applied += 1
	elif t != null:
		var target := _anchor_tile()
		if target != Vector2i(-1, -1) and t.tile_textures.has(target):
			_set_tile_slot_texture(t, target, channel, path)
			applied = 1
	_paint_texture_atlas_dirty = true
	_side_nopaint_dirty = true
	if panel != null and panel.has_method("set_paint_channel_textures"):
		panel.set_paint_channel_textures(paint_channel_textures)
	_refresh_paint_popup_sel()
	_save_overlay_prefs()
	_apply_terrain_overlays()
	var who: String = PAINT_CHANNEL_NAMES[channel] if channel < PAINT_CHANNEL_NAMES.size() else "Base"
	var where := ("%d selected tile(s)" % applied) if applied > 1 else "paint combo"
	var what := path if path != "" else "flat color"
	print("[WMT] %s \u2192 %s (%s)" % [who, where, what])

func _begin_paint_stroke() -> void:
	if not is_instance_valid(terrain):
		return
	paint_stroking = true
	var t := terrain
	_last_stamp_pos = Vector3(-1.0e9, 0.0, -1.0e9)
	_paint_stroke_first = true
	_spray_timer = 0.0
	_stroke_paint_before.clear()
	stroke_touched_keys.clear()
	_paint_dirty = false
	_update_cursor_position()

func _paint_frame(delta: float) -> void:
	var t := terrain
	if t == null or not is_instance_valid(t):
		return
	if not _brush_enabled():
		return
	var center := cursor_local
	if _paint_stroke_first:
		_paint_stroke_first = false
		_stamp_paint(center)
		_last_stamp_pos = center
		return
	var start := _last_stamp_pos
	var dist := (center - start).length()
	# Sweep the brush along the segment that the mouse travelled this frame so
	# a hold-drag leaves a connected stroke instead of a row of discrete dabs.
	# The path is sub-divided such that neighbouring brush circles overlap
	# (step <= radius); the spacing setting only caps how fine the sweep is.
	var radius := maxf(cursor_radius, 0.25)
	var step := minf(paint_spacing, maxf(radius * 0.5, t.SQUARE_EDGE))
	if dist >= 0.05:
		var n := maxi(1, int(ceil(dist / maxf(step, 0.01))))
		for i in range(1, n + 1):
			var p := start.lerp(center, float(i) / float(n))
			_stamp_paint(p)
		_last_stamp_pos = center
		_spray_timer = 0.0
		return
	# The cursor is (nearly) stationary: with spray paint on, keep stamping on
	# the fixed interval so holding Shift+LMB paints even without moving.
	_spray_timer += delta
	if paint_spray_on and _spray_timer >= paint_spray_interval:
		_spray_timer = 0.0
		_stamp_paint(center)
		_last_stamp_pos = center

# Stamp the selected splatmap channel color along the brush circle: only the
# texels inside the ring get color, shaped by the same radial falloff profile
# the cursor shows. Unpainted tiles gain their first tile the moment a texel
# is touched (see WmtScript.paint_tile_stamp). The stroke does NOT carry a
# global combo: per tile, the brush texture is pinned to the channel that
# already maps it (seamless), or the first channel with no texture, and the
# mapping is written per tile as it is painted.
func _stamp_paint(center: Vector3) -> void:
	var t := terrain
	if t == null or not is_instance_valid(t):
		return
	var ci := clampi(paint_channel, 0, WmtScript.PAINT_CHANNELS - 1)
	var brush_tex := _brush_texture()
	var amount := clampf(paint_flow * paint_opacity, 0.0, 1.0)
	var edge := t.TILE_EDGE
	var radius := maxf(cursor_radius, 0.25)
	var radius2 := radius * radius
	var tgx0 := floori((center.x - radius) / edge)
	var tgx1 := floori((center.x + radius) / edge)
	var tgz0 := floori((center.z - radius) / edge)
	var tgz1 := floori((center.z + radius) / edge)
	var sp := t.SQUARES_PER_TILE
	var strength := func(d: float) -> float: return _brush_falloff(d, radius)
	for tgz in range(tgz0, tgz1 + 1):
		for tgx in range(tgx0, tgx1 + 1):
			var bx := tgx * edge
			var bz := tgz * edge
			if bx < float(t.cell_x0) * t.SQUARE_EDGE or bz < float(t.cell_z0) * t.SQUARE_EDGE \
					or bx + edge > float(t.cell_x1) * t.SQUARE_EDGE \
					or bz + edge > float(t.cell_z1) * t.SQUARE_EDGE:
				continue
			var ck: Vector2i = t._chunk_of(tgx * sp, tgz * sp)
			if not t.has_chunk(ck.x, ck.y):
				continue
			var nearest_x := clampf(center.x, bx, bx + edge)
			var nearest_z := clampf(center.z, bz, bz + edge)
			var dx := center.x - nearest_x
			var dz := center.z - nearest_z
			if dx * dx + dz * dz > radius2:
				continue
			# Capture the tile's pre-stroke pixels the first time this stroke
			# touches it (the read must happen before painting so the fresh
			# tile's neutral state isn't captured as the "before" state).
			var skey := Vector2i(tgx, tgz)
			var captured := false
			var before: PackedByteArray
			if not _stroke_paint_before.has(skey):
				before = t.paint_pixels(tgx, tgz)
				captured = true
			# A textured brush paints the tile on the channel that keeps the
			# texture seamless across tiles; a tile with no room for it is
			# simply skipped (it shows up red via the overlay).
			var eff_ci := ci
			if brush_tex != "":
				var auto_ci := _auto_channel_for_brush(t, skey, brush_tex)
				if auto_ci < 0:
					continue
				eff_ci = auto_ci
				if not t.tile_textures.has(skey) or _resolved_tile_tex(t, skey, eff_ci) != brush_tex:
					var tarr: Array = t.tile_textures.get(skey, [])
					while tarr.size() <= eff_ci:
						tarr.append("")
					tarr[eff_ci] = brush_tex
					t.set_tile_textures(skey.x, skey.y, tarr)
					_paint_texture_atlas_dirty = true
					# A new channel mapping adopts the toolbox's repeat count so
					# painting a texture transfers its SIZE too (not just the
					# texture) onto the target tile. The toolbox mirrors the
					# eyedropped/popup tile, so "paint this texture from tile X
					# onto Y" keeps X's size where X had it pinned; a fresh
					# default stays 16. An existing per-tile pin on the target
					# always wins.
					if eff_ci < paint_channel_tilings.size():
						var tiling_arr: Variant = t.tile_tilings.get(skey, [])
						var pinned := tiling_arr is Array and eff_ci < (tiling_arr as Array).size() \
								and float((tiling_arr as Array)[eff_ci]) >= 1.0
						if not pinned:
							_set_tile_tiling(t, skey, eff_ci, paint_channel_tilings[eff_ci])
					# Whole-tile FILL only lands on tiles with NO paint data yet:
					# first paint covers the fresh tile with the brush texture, but
					# repainting an already-painted tile just stamps into its
					# existing coverage - never re-fills the whole tile.
					if not t.tile_paints.has(skey):
						t.paint_tile_fill(tgx, tgz, eff_ci, 1.0)
						# The whole-tile fill is itself a visible change, but the
						# follow-up stamp below is a no-op on a freshly filled tile,
						# so without explicit dirty marking neither the mid-stroke
						# nor the end-of-stroke overlay refresh would fire and the
						# fill would only show up after a reload.
						_paint_dirty = true
						_last_painted_tile = skey
						if not stroke_touched_keys.has(ck):
							stroke_touched_keys.append(ck)
			if t.paint_tile_stamp(tgx, tgz, center.x, center.z, radius, eff_ci, amount, strength):
				_last_painted_tile = skey
				if captured:
					_stroke_paint_before[skey] = before
				_paint_dirty = true
				if not stroke_touched_keys.has(ck):
					stroke_touched_keys.append(ck)

func _end_paint_stroke() -> void:
	if not paint_stroking:
		return
	paint_stroking = false
	# A stroke may have grown tiles' texture mappings (auto channel pick): the
	# red non-paintable overlay needs a fresh pass once the stroke settles.
	_side_nopaint_dirty = true
	var t := terrain if is_instance_valid(terrain) else null
	if t != null:
		if not stroke_touched_keys.is_empty():
			# The overlay was already refreshed live during the stroke; this
			# final pass is cheap (the atlas is cached once clean) and ensures
			# the released frame shows the finished result before saving.
			_apply_terrain_overlays()
			_drape_ring()
			print("[WMT] painted %d tile(s)" % t.tile_paints.size())
			var touched := stroke_touched_keys.duplicate()
			if not _stroke_paint_before.is_empty():
				# One undo step per stroke, pushed on the SAME custom stack the
				# sculpt strokes use, so Ctrl+Z / Ctrl+Y roll the whole stroke
				# back/forward regardless of mode (per-tile pixel data,
				# embedded file format, no sidecar PNGs).
				var before: Array = []
				var after: Array = []
				for skey in _stroke_paint_before:
					before.append([skey, _stroke_paint_before[skey]])
					after.append([skey, t.paint_pixels(skey.x, skey.y)])
				undo_stack.append({
					"paint_before": before,
					"paint_after": after,
					"touched": touched,
				})
				if undo_stack.size() > UNDO_LIMIT:
					undo_stack.pop_front()
				redo_stack.clear()
				call_deferred("_save_undo_to_file")
				_save_terrain(t, touched)
			else:
				_save_terrain(t, touched)
		else:
			_save_terrain(t)
		stroke_touched_keys.clear()
	_stroke_paint_before.clear()
	_paint_dirty = false

# Undo/redo target for paint strokes: restore tile pixels from a snapshot
# ([[Vector2i, PackedByteArray-or-null], ...]), refresh the live overlay and
# save just the touched chunks so Ctrl+Z always leaves disk consistent.
func _apply_paint_undo(t: WmtScript, entries: Array, touched: Array) -> void:
	if t == null or not is_instance_valid(t):
		return
	t.paint_restore(entries)
	_paint_texture_atlas_dirty = true
	call_deferred("_apply_paint_undo_deferred", t)

# ---- Vertex-color paint strokes --------------------------------------------
func _begin_vertex_stroke() -> void:
	if not is_instance_valid(terrain):
		return
	vertex_stroking = true
	stroke_terrain = terrain
	_stroke_tiles_before.clear()
	stroke_touched_keys.clear()
	_vertex_dirty = false
	_vertex_last_stamp_pos = Vector3(-1.0e9, 0.0, -1.0e9)
	_vertex_stroke_first = true
	_vertex_spray_timer = 0.0
	_update_cursor_position()

func _vertex_frame(delta: float, erasing: bool) -> void:
	var t := stroke_terrain
	if t == null or not is_instance_valid(t):
		return
	if cursor_local == null:
		return
	# Opacity caps the deposit, flow scales how much a single stamp adds and
	# strength is the per-stroke gain - all three multiply like the splat brush.
	var amount := clampf(vertex_strength * vertex_opacity * vertex_flow, 0.0, 1.0)
	if amount <= 0.0:
		return
	var center := cursor_local
	if _vertex_stroke_first:
		_vertex_stroke_first = false
		_vertex_stamp_at(t, center, erasing, amount)
		_vertex_last_stamp_pos = center
		return
	var start := _vertex_last_stamp_pos
	var dist := (center - start).length()
	# Sweep along the segment the mouse travelled this frame, exactly like the
	# paint brush. This is what makes FLOW do anything: the stroke used to stamp
	# once per FRAME at the cursor, so a fast drag left bare gaps between dabs.
	# The per-stamp deposit lerps toward full coverage, so without this a texel
	# saturated the moment the brush passed over it a few times.
	var radius := maxf(cursor_radius, 0.25)
	var step := minf(vertex_spacing, maxf(radius * 0.5, t.SQUARE_EDGE))
	if dist >= 0.05:
		var n := maxi(1, int(ceil(dist / maxf(step, 0.01))))
		# Compensate for how much the stamps OVERLAP, so "amount" means what one
		# PASS of the stroke deposits rather than what a single dab does. At
		# step = radius*0.5 a texel is covered by ~4 consecutive stamps, so
		# without this a fast drag landed amount x 4 in one frame and every
		# intensity control read as dead. Clamped so sparse stamps (spacing wider
		# than the brush) still deposit the full amount each.
		var overlap := clampf(step / maxf(2.0 * radius, 0.01), 0.02, 1.0)
		var per_stamp := amount * overlap
		for i in range(1, n + 1):
			_vertex_stamp_at(t, start.lerp(center, float(i) / float(n)),
				erasing, per_stamp)
		_vertex_last_stamp_pos = center
		_vertex_spray_timer = 0.0
		return
	# The cursor is (nearly) stationary. With spray on, keep building up at the
	# cursor so a held button still paints instead of doing nothing. These are
	# deliberately UNCOMPENSATED: build-up at a stationary cursor is the whole
	# point of spray, so each tick deposits the full amount.
	_vertex_spray_timer += delta
	if vertex_spray_on and _vertex_spray_timer >= vertex_spray_interval:
		_vertex_spray_timer = 0.0
		_vertex_stamp_at(t, center, erasing, amount)
		_vertex_last_stamp_pos = center

# One vertex-tint stamp at a single point: every tile whose footprint the brush
# covers gets a soft radial stamp into its RGBA8 tint block (TINT_TILE_PX texels
# per tile = 16x16 = 2 texels/cell), so strokes feather instead of snapping to
# the quad lattice. Each touched tile is snapshotted before its first stamp for
# the stroke's undo step.
func _vertex_stamp_at(t: WmtScript, c: Vector3, erasing: bool, amount: float) -> void:
	var radius := maxf(cursor_radius, 0.25)
	# An erase stroke clears the texel back to the neutral (alpha 0) tint so the
	# tile drops out of the splatmap; a paint stroke deposits the picked color
	# at the stroke's coverage. `vertex_color` may itself be the eraser swatch
	# (50% gray), which erases even without the erase binding.
	# The stamp decides paint-vs-erase from the COLOR it is handed
	# (is_eraser_color == 50% gray), not from a flag - so an erase has to
	# actually pass the eraser swatch. Passing VERTEX_TINT_NEUTRAL here looked
	# right (it is the erase TARGET) but is transparent black, which is not the
	# eraser: the stamp took the PAINT branch, snapped RGB to black and built
	# coverage, so the eraser blackened the terrain instead of clearing it.
	var target: Color = WmtScript.VERTEX_TINT_ERASER if erasing \
			or WmtScript.is_eraser_color(vertex_color) else vertex_color
	_record_stroke_touched(t, c, radius)
	var edge := t.SQUARE_EDGE
	var tstep := edge * t.SQUARES_PER_TILE
	var tgx0 := maxi(0, int(floor((c.x - radius) / tstep)))
	var tgx1 := maxi(0, int(floor((c.x + radius) / tstep)))
	var tgz0 := maxi(0, int(floor((c.z - radius) / tstep)))
	var tgz1 := maxi(0, int(floor((c.z + radius) / tstep)))
	var fall: Callable = func(d: float) -> float: return _brush_falloff(d, radius)
	for tgz in range(tgz0, tgz1 + 1):
		for tgx in range(tgx0, tgx1 + 1):
			var k := Vector2i(tgx, tgz)
			if not _stroke_tiles_before.has(k):
				_stroke_tiles_before[k] = t.tint_tile_pixels(tgx, tgz)
			if t.paint_tint_stamp(tgx, tgz, c.x, c.z, radius, target, amount, fall):
				_vertex_dirty = true

func _end_vertex_stroke() -> void:
	if not vertex_stroking:
		return
	vertex_stroking = false
	var t := terrain if is_instance_valid(terrain) else null
	if t != null:
		if not stroke_touched_keys.is_empty():
			# The tint atlas was already refreshed live; the final pass just
			# makes the released frame show the finished result before saving.
			_apply_terrain_overlays()
			_drape_ring()
			var touched := stroke_touched_keys.duplicate()
			if not _stroke_tiles_before.is_empty():
				var before: Array = []
				var after: Array = []
				for vk in _stroke_tiles_before:
					var tk := vk as Vector2i
					before.append([tk, _stroke_tiles_before[vk]])
					after.append([tk, t.tint_tile_pixels(tk.x, tk.y)])
				undo_stack.append({
					"v_before": before,
					"v_after": after,
					"vtouched": touched,
				})
				if undo_stack.size() > UNDO_LIMIT:
					undo_stack.pop_front()
				redo_stack.clear()
				call_deferred("_save_undo_to_file")
				_save_terrain(t, touched)
			else:
				_save_terrain(t, touched)
		else:
			_save_terrain(t)
		stroke_touched_keys.clear()
	_stroke_tiles_before.clear()
	_vertex_dirty = false

# Undo/redo target for vertex-tint strokes: restore whole tile blocks from a
# snapshot ([[Vector2i, PackedByteArray], ...]), refresh the overlay and save
# touched chunks so Ctrl+Z always leaves disk consistent.
func _apply_vertex_undo(t: WmtScript, entries: Array, touched: Array) -> void:
	if t == null or not is_instance_valid(t):
		return
	t.restore_tint_tiles(entries)
	_vertex_dirty = true
	call_deferred("_apply_vertex_undo_deferred", t)

# A vertex-color wipe hits the selection (or the anchor tile), regardless of
# whether those tiles carry splat paint.
func _vertex_wipe_targets(t: WmtScript) -> Array:
	var keys: Array = []
	if not _paint_selected.is_empty():
		for key in _paint_selected:
			var tk := key as Vector2i
			if tk.x >= 0 and tk.y >= 0:
				keys.append(tk)
		return keys
	var target := _anchor_tile()
	if target != Vector2i(-1, -1):
		keys.append(target)
	return keys

func _wipe_vertex_tile_scoped() -> void:
	var t := terrain if is_instance_valid(terrain) else null
	if t == null:
		return
	var keys := _vertex_wipe_targets(t)
	if keys.is_empty():
		return
	var touched: Array = []
	var before: Array = []
	var after: Array = []
	var any := false
	for tk in keys:
		var tg := tk as Vector2i
		_append_touched_chunk(t, tg, touched)
		before.append([tg, t.tint_tile_pixels(tg.x, tg.y)])
		if t.wipe_tint_tile(tg.x, tg.y) > 0:
			any = true
		after.append([tg, t.tint_tile_pixels(tg.x, tg.y)])
	if not any:
		return
	undo_stack.append({"v_before": before, "v_after": after, "vtouched": touched})
	if undo_stack.size() > UNDO_LIMIT:
		undo_stack.pop_front()
	redo_stack.clear()
	_vertex_dirty = true
	_apply_terrain_overlays()
	_drape_ring()
	_save_terrain(t, touched)
	print("[WMT] wiped vertex tint on %d tile(s)" % keys.size())

func _append_touched_chunk(t: WmtScript, tk: Vector2i, touched: Array) -> void:
	var ck: Vector2i = t._chunk_of(tk.x * t.SQUARES_PER_TILE, tk.y * t.SQUARES_PER_TILE)
	if not touched.has(ck):
		touched.append(ck)

# A wipe targets every selected tile, or the anchor tile when nothing is
# selected (picker tile first, then the last painted tile).
func _wipe_targets(t: WmtScript) -> Array:
	var keys: Array = []
	if not _paint_selected.is_empty():
		for key in _paint_selected:
			var tk := key as Vector2i
			if tk.x >= 0 and tk.y >= 0 and t.tile_paints.has(tk):
				keys.append(tk)
		return keys
	var target := _anchor_tile()
	if target != Vector2i(-1, -1) and t.tile_paints.has(target):
		keys.append(target)
	return keys

# Textures/tilings/depths snapshot for one tile, in the paint_restore entry
# format (payload + optional meta so undo/redo restores the overlays too).
func _wipe_snapshot(t: WmtScript, tk: Vector2i) -> Array:
	return [
		tk,
		t.paint_pixels(tk.x, tk.y),
		[
			t.tile_textures.get(tk, []).duplicate(),
			t.tile_tilings.get(tk, []).duplicate(),
			t.tile_depths.get(tk, []).duplicate(),
		],
	]

func _wipe_touched_chunks(t: WmtScript, keys: Array) -> Array:
	var out: Array = []
	for k in keys:
		var tk := k as Vector2i
		if tk.x < 0 or tk.y < 0:
			continue
		var ck: Vector2i = t._chunk_of(tk.x * t.SQUARES_PER_TILE, tk.y * t.SQUARES_PER_TILE)
		if t.has_chunk(ck.x, ck.y) and not out.has(ck):
			out.append(ck)
	return out

func _finish_wipe(t: WmtScript, keys: Array, before: Array, after: Array) -> void:
	_paint_texture_atlas_dirty = true
	if _paint_popup_open() and _picker_tile != Vector2i(-1, -1) \
			and t.tile_paints.has(_picker_tile):
		_pull_tile_textures_into_toolbox(t, _picker_tile)
		_pull_tile_tilings_into_toolbox(t, _picker_tile)
		_pull_tile_depths_into_toolbox(t, _picker_tile)
	_refresh_paint_popup_sel()
	_side_sel_dirty = true
	_side_nopaint_dirty = true
	_apply_terrain_overlays()
	var touched := _wipe_touched_chunks(t, keys)
	undo_stack.append({
		"paint_before": before,
		"paint_after": after,
		"touched": touched,
	})
	if undo_stack.size() > UNDO_LIMIT:
		undo_stack.pop_front()
	redo_stack.clear()
	_save_terrain(t, touched)

func _wipe_channel_scoped(channel: int) -> void:
	var t := terrain if is_instance_valid(terrain) else null
	if t == null or channel < 0 or channel >= WmtScript.PAINT_CHANNELS:
		return
	var keys := _wipe_targets(t)
	if keys.is_empty():
		return
	var before: Array = []
	var after: Array = []
	var changed := false
	for k in keys:
		var tk := k as Vector2i
		before.append(_wipe_snapshot(t, tk))
		if t.wipe_channel(tk.x, tk.y, channel):
			changed = true
		after.append(_wipe_snapshot(t, tk))
	if not changed:
		return
	_finish_wipe(t, keys, before, after)
	print("[WMT] wiped channel %d from %d tile(s)" % [channel, keys.size()])

func _wipe_tile_scoped() -> void:
	var t := terrain if is_instance_valid(terrain) else null
	if t == null:
		return
	var keys := _wipe_targets(t)
	if keys.is_empty():
		return
	var before: Array = []
	var after: Array = []
	var changed := false
	for k in keys:
		var tk := k as Vector2i
		before.append(_wipe_snapshot(t, tk))
		if t.wipe_tile(tk.x, tk.y):
			changed = true
		after.append(_wipe_snapshot(t, tk))
	if not changed:
		return
	_finish_wipe(t, keys, before, after)
	print("[WMT] wiped %d tile(s)" % keys.size())

func _resize_ring(new_radius: float) -> void:
	cursor_radius = clampf(new_radius, CURSOR_RADIUS_MIN, CURSOR_RADIUS_MAX)
	if panel != null and panel.has_method("update_radius_label"):
		panel.update_radius_label(cursor_radius)
	_drape_ring()
	_save_overlay_prefs()

func _brush_falloff(d: float, radius: float) -> float:
	# Brush strength across the master circle as a function of distance d.
	# u = d/radius. The inner falloff circle sits at u = falloff_ratio: the
	# region inside it is at full strength, the skirt beyond falls to zero.
	# Shape exponent q = 1/(1-t) morphs the profile with the circle size:
	#   t=0   (dot)      q=1     -> 1-u      linear cone
	#   t=0.5 (halfway)  q=2     -> 1-u^2    parabola dome
	#   t->1  (master)   q->inf  -> ~1       cylinder
	# Anything in between is the natural interpolation of those shapes.
	var u := clampf(d / radius, 0.0, 1.0)
	var t := clampf(falloff_ratio, 0.0, 0.999)
	if u <= 0.0:
		return 1.0
	return 1.0 - pow(u, 1.0 / (1.0 - t))

func _resize_strength(new_strength: float) -> void:
	sculpt_strength = clampf(new_strength, 0.05, 12.0)
	if panel != null and panel.has_method("update_strength_label"):
		panel.update_strength_label(sculpt_strength)
	_save_overlay_prefs()

func _resize_falloff(new_ratio: float) -> void:
	if new_ratio <= 0.0:
		falloff_ratio = 0.0
	elif new_ratio >= 1.0:
		falloff_ratio = 1.0
	else:
		falloff_ratio = new_ratio
	if panel != null and panel.has_method("update_falloff_label"):
		panel.update_falloff_label(falloff_ratio)
	_drape_ring()
	_save_overlay_prefs()

# Don't hijack Ctrl+Z/Y/Ctrl+Y while the user is typing in an editor text
# field (inspector, script, node rename): let those keystrokes reach the
# field unhandled.
# True when the browser's filter box owns the keyboard. The browser grabs the
# search box's focus when it opens, so without this every Ctrl+V the user typed
# into the filter pasted objects into the scene instead of pasting text.
# Is this viewport-space point inside the open browser? The popup is a
# subwindow of the editor, so its rect is in the same coordinates the mouse
# events arrive in.
func _point_over_object_popup(pos: Vector2) -> bool:
	if _object_popup == null or not is_instance_valid(_object_popup):
		return false
	# Grown by a few pixels so a click on the window's own border or shadow
	# still counts as inside: a click just off the edge should not dismiss the
	# browser the user is still pointing at.
	return Rect2(_object_popup.position, _object_popup.size).grow(6.0).has_point(pos)

func _object_search_has_focus() -> bool:
	if _object_search == null or not is_instance_valid(_object_search):
		return false
	return _object_search.has_focus()

func _object_picker_open() -> bool:
	return _object_popup != null and is_instance_valid(_object_popup) \
		and _object_popup.visible

# The viewport position a paste should land on. A paste is aimed with the mouse,
# but the browser is the thing being aimed FROM: while it is open the pointer is
# over the browser, so the live position is either off the viewport or - worse -
# somewhere else entirely on screen. The last position that was actually over the
# 3D viewport is what the user was pointing at when they picked the object, so
# that is the point they get.
func _paste_mouse_position() -> Vector2:
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d()
	if vp == null:
		return Vector2(-1.0, -1.0)
	if not _object_picker_open() and vp.get_visible_rect().has_point(vp.get_mouse_position()):
		return vp.get_mouse_position()
	if _last_vp_mouse_valid:
		return _last_vp_mouse
	return vp.get_mouse_position()

# Remember where the pointer was over the viewport. Sampled only while the
# browser is closed, so opening it does not overwrite the aim point with the
# position of the click that opened it, and moving across the browser does not
# either.
func _remember_vp_mouse() -> void:
	if _object_picker_open():
		return
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d()
	if vp == null:
		return
	var m := vp.get_mouse_position()
	if vp.get_visible_rect().has_point(m):
		_last_vp_mouse = m
		_last_vp_mouse_valid = true

func _text_edit_focused() -> bool:
	var fw: Control = EditorInterface.get_base_control().get_viewport().gui_get_focus_owner()
	if fw is LineEdit or fw is TextEdit or fw is CodeEdit or fw is SpinBox or fw is OptionButton:
		return true
	if fw != null and fw.has_method("get_editable") and fw.get_editable():
		return true
	return false

func _capture_state(t: WmtScript) -> Dictionary:
	return {
		"hm": t.heightmap.duplicate(),
		"ch": t.center_h.duplicate(),
		"hid": t.hidden_tiles.duplicate(),
		"chunks": t.chunks.duplicate(),
		"x0": t.cell_x0,
		"x1": t.cell_x1,
		"z0": t.cell_z0,
		"z1": t.cell_z1,
	}

func _restore_state(t: WmtScript, s: Dictionary) -> void:
	t.chunks = (s["chunks"] as Array).duplicate()
	t.cell_x0 = s["x0"]
	t.cell_x1 = s["x1"]
	t.cell_z0 = s["z0"]
	t.cell_z1 = s["z1"]
	t.GRID_SQUARES_X = t.cell_x1 - t.cell_x0
	t.GRID_SQUARES_Z = t.cell_z1 - t.cell_z0
	t.TERRAIN_WIDTH = float(t.GRID_SQUARES_X) * t.SQUARE_EDGE
	t.TERRAIN_DEPTH = float(t.GRID_SQUARES_Z) * t.SQUARE_EDGE
	t.heightmap = (s["hm"] as PackedFloat32Array).duplicate()
	t.center_h = (s["ch"] as PackedFloat32Array).duplicate()
	t.hidden_tiles = (s.get("hid", PackedByteArray()) as PackedByteArray).duplicate()
	# Undo/redo restore heights in place; bump height_version so the cached
	# rebuilds instead of keeping the stale pre-undo heights in the shading.
	t.height_version += 1

func _begin_stroke() -> void:
	if not is_instance_valid(terrain):
		return
	sculpting = true
	stroke_terrain = terrain
	_apply_stroke_mods()
	stroke_snapshot = _capture_state(stroke_terrain)
	stroke_changed = false
	_tile_overlay_dirty = false
	if SCULPT_RECORD:
		sculpt_log.reset()
	_update_cursor_position()

# Read the modifier keys live so a held stroke can switch between raise /
# lower / smooth without letting go, and so auto-started strokes (whose press
# the editor consumed) get the right mode. A plain LMB does nothing.
func _apply_stroke_mods() -> void:
	if Input.is_key_pressed(KEY_SHIFT):
		sculpt_direction = 1.0
		smoothing = false
	elif Input.is_key_pressed(KEY_CTRL):
		sculpt_direction = -1.0
		smoothing = false
	elif Input.is_key_pressed(KEY_ALT):
		sculpt_direction = 0.0
		smoothing = true
	else:
		sculpt_direction = 0.0
		smoothing = false

func _end_stroke() -> void:
	if not sculpting:
		return
	sculpting = false
	var t := stroke_terrain if is_instance_valid(stroke_terrain) else terrain
	if stroke_changed and is_instance_valid(t):
		undo_stack.append(stroke_snapshot)
		if undo_stack.size() > UNDO_LIMIT:
			undo_stack.pop_front()
		redo_stack.clear()
		if SCULPT_RECORD and sculpt_log.frames.size() > 0:
			sculpt_log.write_log(t, stroke_snapshot.get("hm", PackedFloat32Array()), stroke_snapshot.get("ch", PackedFloat32Array()))
	stroke_snapshot = {}
	stroke_terrain = null
	stroke_changed = false
	if is_instance_valid(t):
		if _tile_overlay_dirty:
			_tile_overlay_dirty = false
			if active_tab == TAB_WMT:
				_rebuild_overlay_layers()
			_drape_ring()
		if stroke_touched_keys.is_empty():
			_save_terrain(t)
		else:
			_save_terrain(t, stroke_touched_keys)
		stroke_touched_keys.clear()


func _undo_file_path() -> String:
	return UNDO_FILE

func _save_undo_to_file() -> void:
	var f := FileAccess.open(_undo_file_path(), FileAccess.WRITE)
	if f == null:
		return
	var count := undo_stack.size()
	f.store_string(JSON.stringify({"count": count, "ts": Time.get_unix_time_from_system()}))
	f.close()

func _load_undo_from_file() -> void:
	if not FileAccess.file_exists(_undo_file_path()):
		return
	var f := FileAccess.open(_undo_file_path(), FileAccess.READ)
	if f == null:
		return
	var txt := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(txt)
	if typeof(parsed) == TYPE_DICTIONARY:
		var d = parsed as Dictionary
		if d.has("undo") and typeof(d["undo"]) == TYPE_ARRAY:
			undo_stack.clear()
			var arr = d["undo"] as Array
			var start := max(0, arr.size() - UNDO_FILE_LIMIT)
			for i in range(start, arr.size()):
				undo_stack.append(arr[i])

func _undo_sculpt() -> bool:
	if sculpting or not is_instance_valid(terrain) or undo_stack.is_empty():
		return false
	if redo_stack.size() >= UNDO_LIMIT:
		redo_stack.pop_front()
	var snap: Dictionary = undo_stack.pop_back()
	redo_stack.append(snap)
	call_deferred("_save_undo_to_file")
	if snap.has("v_before"):
		# Vertex-color steps restore per-vertex tints (and save the touched
		# chunks) via the same helper; no mesh rebuild needed.
		_apply_vertex_undo(terrain, snap["v_before"], snap.get("vtouched", []))
		return true
	if snap.has("paint_before"):
		# Paint steps restore tile pixels (and save the touched chunks) via the
		# same helper; no mesh rebuild needed.
		_apply_paint_undo(terrain, snap["paint_before"], snap.get("touched", []))
		return true
	_restore_state(terrain, snap)
	_apply_after_edit()
	return true

func _redo_sculpt() -> bool:
	if sculpting or not is_instance_valid(terrain) or redo_stack.is_empty():
		return false
	var snap: Dictionary = redo_stack.pop_back()
	if undo_stack.size() >= UNDO_LIMIT:
		undo_stack.pop_front()
	undo_stack.append(snap)
	if snap.has("v_after"):
		_apply_vertex_undo(terrain, snap["v_after"], snap.get("vtouched", []))
		return true
	if snap.has("paint_after"):
		_apply_paint_undo(terrain, snap["paint_after"], snap.get("touched", []))
		return true
	_restore_state(terrain, snap)
	_apply_after_edit()
	return true

func _apply_after_edit() -> void:
	if not is_instance_valid(terrain):
		return
	call_deferred("_apply_after_edit_deferred")

func _apply_after_edit_deferred() -> void:
	if not is_instance_valid(terrain):
		return
	terrain.rebuild_mesh()
	call_deferred("_apply_after_edit_deferred2")

func _apply_after_edit_deferred2() -> void:
	if not is_instance_valid(terrain):
		return
	_refresh_overlay_height()
	_drape_ring()
	if active_tab == TAB_WMT:
		_rebuild_overlay_layers()
	print("[WMT] undo/redo applied")

func _sculpt_frame(delta: float) -> void:
	var t := stroke_terrain
	if t == null or not is_instance_valid(t):
		return
	if not _brush_enabled():
		return
	_apply_stroke_mods()
	var center := cursor_local
	var edge := t.SQUARE_EDGE
	var radius := maxf(cursor_radius, 0.5)
	# Clamp the per-frame step so a hiccup frame (huge delta) can't lurch the
	# brush up in one jump; holding stays smooth.
	var step := clampf(SCULPT_SPEED * delta * sculpt_direction * sculpt_strength, -0.25, 0.25)
	var dirty_corners := {}
	var dirty_centers := {}
	var rec_corners: Array = []
	var rec_centers: Array = []
	_record_stroke_touched(t, center, radius)
	var gx_min := maxi(t.cell_x0, int(floor((center.x - radius) / edge)))
	var gx_max := mini(t.cell_x1, int(ceil((center.x + radius) / edge)))
	var gz_min := maxi(t.cell_z0, int(floor((center.z - radius) / edge)))
	var gz_max := mini(t.cell_z1, int(ceil((center.z + radius) / edge)))
	for gz in range(gz_min, gz_max + 1):
		for gx in range(gx_min, gx_max + 1):
			if not t.corner_emitted(gx, gz):
				continue
			var wx := gx * edge
			var wz := gz * edge
			var d := sqrt((wx - center.x) * (wx - center.x) + (wz - center.z) * (wz - center.z))
			if d > radius:
				continue
			var falloff := _brush_falloff(d, radius)
			var cur := t.get_height(gx, gz)
			var next_val: float
			if smoothing:
				next_val = lerpf(cur, t.get_neighbor_average(gx, gz), clampf(SCULPT_SPEED * delta * falloff * sculpt_strength, 0.0, 1.0))
			else:
				next_val = cur + step * falloff
			if absf(next_val - cur) > 1e-6:
				stroke_changed = true
				t.set_height(gx, gz, next_val)
				dirty_corners[Vector2i(gx, gz)] = next_val
				if SCULPT_RECORD:
					rec_corners.append([gx, gz, d, falloff, cur, next_val])

	# Center vertex of each tile is sculptable too.
	var cx_min := maxi(t.cell_x0, int(floor((center.x - radius) / edge - 0.5)))
	var cx_max := mini(t.cell_x1, int(ceil((center.x + radius) / edge - 0.5)))
	var cz_min := maxi(t.cell_z0, int(floor((center.z - radius) / edge - 0.5)))
	var cz_max := mini(t.cell_z1, int(ceil((center.z + radius) / edge - 0.5)))
	for cz in range(cz_min, cz_max + 1):
		if cz < t.cell_z0 or cz >= t.cell_z1:
			continue
		for cx in range(cx_min, cx_max + 1):
			if cx < t.cell_x0 or cx >= t.cell_x1:
				continue
			var ci := (cz - t.cell_z0) * t.GRID_SQUARES_X + (cx - t.cell_x0)
			if not t.cell_emitted(ci):
				continue
			var wx := (cx + 0.5) * edge
			var wz := (cz + 0.5) * edge
			var d := sqrt((wx - center.x) * (wx - center.x) + (wz - center.z) * (wz - center.z))
			if d > radius:
				continue
			var falloff := _brush_falloff(d, radius)
			var cur := t.get_center_height(cx, cz)
			var next_val: float
			if smoothing:
				next_val = lerpf(cur, t.get_center_average(cx, cz), clampf(SCULPT_SPEED * delta * falloff * sculpt_strength, 0.0, 1.0))
			else:
				next_val = cur + step * falloff
			if absf(next_val - cur) > 1e-6:
				stroke_changed = true
				t.set_center_height(cx, cz, next_val)
				dirty_centers[Vector2i(cx, cz)] = next_val
				if SCULPT_RECORD:
					rec_centers.append([cx, cz, d, falloff, cur, next_val])
	var dirty_vi := t.update_height_vertices(dirty_corners, dirty_centers)
	if SCULPT_RECORD:
		sculpt_log.record_frame(center, radius, step, smoothing, rec_corners, rec_centers, dirty_vi.size())
	# Live shading: the height atlas must follow the in-place vertex patch
	# instead of snapping to the finished surface at stroke end.
	_refresh_overlay_height(Rect2i(gx_min, gz_min, gx_max - gx_min + 1, gz_max - gz_min + 1))
	_drape_ring()

func _set_height_enabled() -> bool:
	if not _is_set_height_tab():
		return false
	if panel == null or panel.set_height_spin == null:
		return true
	return true

# Set Height sub-tool (inside the Sculpt mode): dragging the brush moves every corner/center under the ring
# toward the target height (panel.set_height_spin.value), gated on the Absolute
# checkbox. Falloff fades the influence toward the brush edge; repeat-frame
# lerp makes holding settle each point onto the exact target. Target is clamped
# to >= 0 (heights can't go below zero, and set_height floors the writes too).
func _set_height_frame(delta: float) -> void:
	var t := stroke_terrain
	if t == null or not is_instance_valid(t):
		return
	if not _brush_enabled():
		return
	if not _set_height_enabled():
		return
	var target := maxf(0.0, panel.set_height_spin.value)
	var center := cursor_local
	var edge := t.SQUARE_EDGE
	var radius := maxf(cursor_radius, 0.5)
	var mix := clampf(SCULPT_SPEED * delta * sculpt_strength, 0.0, 1.0)
	var dirty_corners := {}
	var dirty_centers := {}
	var rec_corners: Array = []
	var rec_centers: Array = []
	_record_stroke_touched(t, center, radius)
	var gx_min := maxi(t.cell_x0, int(floor((center.x - radius) / edge)))
	var gx_max := mini(t.cell_x1, int(ceil((center.x + radius) / edge)))
	var gz_min := maxi(t.cell_z0, int(floor((center.z - radius) / edge)))
	var gz_max := mini(t.cell_z1, int(ceil((center.z + radius) / edge)))
	for gz in range(gz_min, gz_max + 1):
		for gx in range(gx_min, gx_max + 1):
			if not t.corner_emitted(gx, gz):
				continue
			var wx := gx * edge
			var wz := gz * edge
			var d := sqrt((wx - center.x) * (wx - center.x) + (wz - center.z) * (wz - center.z))
			if d > radius:
				continue
			var falloff := _brush_falloff(d, radius)
			var cur := t.get_height(gx, gz)
			var next_val := lerpf(cur, target, clampf(mix * falloff, 0.0, 1.0))
			if absf(next_val - cur) > 1e-6:
				stroke_changed = true
				t.set_height(gx, gz, next_val)
				dirty_corners[Vector2i(gx, gz)] = next_val
				if SCULPT_RECORD:
					rec_corners.append([gx, gz, d, falloff, cur, next_val])

	# Center vertex of each tile is set too.
	var cx_min := maxi(t.cell_x0, int(floor((center.x - radius) / edge - 0.5)))
	var cx_max := mini(t.cell_x1, int(ceil((center.x + radius) / edge - 0.5)))
	var cz_min := maxi(t.cell_z0, int(floor((center.z - radius) / edge - 0.5)))
	var cz_max := mini(t.cell_z1, int(ceil((center.z + radius) / edge - 0.5)))
	for cz in range(cz_min, cz_max + 1):
		if cz < t.cell_z0 or cz >= t.cell_z1:
			continue
		for cx in range(cx_min, cx_max + 1):
			if cx < t.cell_x0 or cx >= t.cell_x1:
				continue
			var ci := (cz - t.cell_z0) * t.GRID_SQUARES_X + (cx - t.cell_x0)
			if not t.cell_emitted(ci):
				continue
			var wx := (cx + 0.5) * edge
			var wz := (cz + 0.5) * edge
			var d := sqrt((wx - center.x) * (wx - center.x) + (wz - center.z) * (wz - center.z))
			if d > radius:
				continue
			var falloff := _brush_falloff(d, radius)
			var cur := t.get_center_height(cx, cz)
			var next_val := lerpf(cur, target, clampf(mix * falloff, 0.0, 1.0))
			if absf(next_val - cur) > 1e-6:
				stroke_changed = true
				t.set_center_height(cx, cz, next_val)
				dirty_centers[Vector2i(cx, cz)] = next_val
				if SCULPT_RECORD:
					rec_centers.append([cx, cz, d, falloff, cur, next_val])
	var dirty_vi := t.update_height_vertices(dirty_corners, dirty_centers)
	if SCULPT_RECORD:
		sculpt_log.record_frame(center, radius, 0.0, false, rec_corners, rec_centers, dirty_vi.size())
	_refresh_overlay_height(Rect2i(gx_min, gz_min, gx_max - gx_min + 1, gz_max - gz_min + 1))
	_drape_ring()

# Smooth submode (Sculpt tab -> "[ ] Smooth"): the active raise/flatten/smooth/
# lower sub-tool drives a single LMB drag inside the brush circle.
#   Raise    every point moves toward the HIGHEST vertex in the brush radius
#            (valleys climb up to the peak and the surface rounds off toward it)
#   Flatten  every point moves toward the AVERAGE height in the radius
#   Smooth   regular neighbor-average smoothing
#   Lower    every point moves toward the LOWEST vertex in the radius
# Like Set Height the influence lerps each frame and fades with the falloff, so
# holding settles every point onto the target without ever passing it.
func _smooth_tool_frame(delta: float) -> void:
	var t := stroke_terrain
	if t == null or not is_instance_valid(t):
		return
	if not _brush_enabled():
		return
	var tool := SMOOTH_TOOL_SMOOTH
	if panel != null and panel.has_method("get_smooth_tool"):
		tool = panel.get_smooth_tool()
	var center := cursor_local
	var edge := t.SQUARE_EDGE
	var radius := maxf(cursor_radius, 0.5)
	var dirty_corners := {}
	var dirty_centers := {}
	var rec_corners: Array = []
	var rec_centers: Array = []
	_record_stroke_touched(t, center, radius)
	var gx_min := maxi(t.cell_x0, int(floor((center.x - radius) / edge)))
	var gx_max := mini(t.cell_x1, int(ceil((center.x + radius) / edge)))
	var gz_min := maxi(t.cell_z0, int(floor((center.z - radius) / edge)))
	var gz_max := mini(t.cell_z1, int(ceil((center.z + radius) / edge)))
	var cx_min := maxi(t.cell_x0, int(floor((center.x - radius) / edge - 0.5)))
	var cx_max := mini(t.cell_x1, int(ceil((center.x + radius) / edge - 0.5)))
	var cz_min := maxi(t.cell_z0, int(floor((center.z - radius) / edge - 0.5)))
	var cz_max := mini(t.cell_z1, int(ceil((center.z + radius) / edge - 0.5)))
	var target := 0.0
	if tool != SMOOTH_TOOL_SMOOTH:
		# Surface stats over the brush footprint (corners + center vertices).
		var h_max := -INF
		var h_min := INF
		var h_sum := 0.0
		var h_count := 0
		for gz in range(gz_min, gz_max + 1):
			for gx in range(gx_min, gx_max + 1):
				if not t.corner_emitted(gx, gz):
					continue
				var wx := gx * edge
				var wz := gz * edge
				var dx := wx - center.x
				var dz := wz - center.z
				if dx * dx + dz * dz > radius * radius:
					continue
				var cur := t.get_height(gx, gz)
				h_max = maxf(h_max, cur)
				h_min = minf(h_min, cur)
				h_sum += cur
				h_count += 1
		for cz in range(cz_min, cz_max + 1):
			if cz < t.cell_z0 or cz >= t.cell_z1:
				continue
			for cx in range(cx_min, cx_max + 1):
				if cx < t.cell_x0 or cx >= t.cell_x1:
					continue
				var ci := (cz - t.cell_z0) * t.GRID_SQUARES_X + (cx - t.cell_x0)
				if not t.cell_emitted(ci):
					continue
				var wx := (cx + 0.5) * edge
				var wz := (cz + 0.5) * edge
				var dx := wx - center.x
				var dz := wz - center.z
				if dx * dx + dz * dz > radius * radius:
					continue
				var cur := t.get_center_height(cx, cz)
				h_max = maxf(h_max, cur)
				h_min = minf(h_min, cur)
				h_sum += cur
				h_count += 1
		if tool == SMOOTH_TOOL_RAISE:
			target = h_max
		elif tool == SMOOTH_TOOL_LOWER:
			target = h_min
		else:
			target = h_sum / float(maxi(h_count, 1))
	var mix := clampf(SCULPT_SPEED * delta * sculpt_strength, 0.0, 1.0)
	var smooth_mode := tool == SMOOTH_TOOL_SMOOTH
	for gz in range(gz_min, gz_max + 1):
		for gx in range(gx_min, gx_max + 1):
			if not t.corner_emitted(gx, gz):
				continue
			var wx := gx * edge
			var wz := gz * edge
			var d := sqrt((wx - center.x) * (wx - center.x) + (wz - center.z) * (wz - center.z))
			if d > radius:
				continue
			var falloff := _brush_falloff(d, radius)
			var cur := t.get_height(gx, gz)
			var m := clampf(mix * falloff, 0.0, 1.0)
			var next_val: float
			if smooth_mode:
				next_val = lerpf(cur, t.get_neighbor_average(gx, gz), m)
			else:
				next_val = lerpf(cur, target, m)
			if absf(next_val - cur) > 1e-6:
				stroke_changed = true
				t.set_height(gx, gz, next_val)
				dirty_corners[Vector2i(gx, gz)] = next_val
				if SCULPT_RECORD:
					rec_corners.append([gx, gz, d, falloff, cur, next_val])
	for cz in range(cz_min, cz_max + 1):
		if cz < t.cell_z0 or cz >= t.cell_z1:
			continue
		for cx in range(cx_min, cx_max + 1):
			if cx < t.cell_x0 or cx >= t.cell_x1:
				continue
			var ci := (cz - t.cell_z0) * t.GRID_SQUARES_X + (cx - t.cell_x0)
			if not t.cell_emitted(ci):
				continue
			var wx := (cx + 0.5) * edge
			var wz := (cz + 0.5) * edge
			var d := sqrt((wx - center.x) * (wx - center.x) + (wz - center.z) * (wz - center.z))
			if d > radius:
				continue
			var falloff := _brush_falloff(d, radius)
			var cur := t.get_center_height(cx, cz)
			var m := clampf(mix * falloff, 0.0, 1.0)
			var next_val: float
			if smooth_mode:
				next_val = lerpf(cur, t.get_center_average(cx, cz), m)
			else:
				next_val = lerpf(cur, target, m)
			if absf(next_val - cur) > 1e-6:
				stroke_changed = true
				t.set_center_height(cx, cz, next_val)
				dirty_centers[Vector2i(cx, cz)] = next_val
				if SCULPT_RECORD:
					rec_centers.append([cx, cz, d, falloff, cur, next_val])
	var dirty_vi := t.update_height_vertices(dirty_corners, dirty_centers)
	if SCULPT_RECORD:
		sculpt_log.record_frame(center, radius, 0.0, smooth_mode, rec_corners, rec_centers, dirty_vi.size())
	_refresh_overlay_height(Rect2i(gx_min, gz_min, gx_max - gx_min + 1, gz_max - gz_min + 1))
	_drape_ring()

# Tiles tab: while Shift+LMB is held, hide/unhide the tile(s) under the cursor.
# The toggle applies exactly ONCE per press (anchor tile decides direction), so
# a fast drag can't stroboscope tiles back and forth; the stroke just idles
# until the button is released. Overlay/mesh rebuilds stay deferred to stroke
# end so a multi-tile circle only re-drapes once.
func _tiles_process() -> void:
	if terrain == null or not is_instance_valid(terrain):
		_end_hide_paint()
		return
	var shift := Input.is_key_pressed(KEY_SHIFT)
	var lmb := Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT)
	var painting := shift and lmb and _cursor_inside_viewport() and not _pointer_over_floats()
	if not painting:
		_hide_stroke_applied = false
		_end_hide_paint()
		return
	if hide_painting and _hide_stroke_applied:
		return
	if not hide_painting or not is_instance_valid(stroke_terrain):
		if hide_painting:
			_end_hide_paint()
		hide_value = not _tile_hidden_at_cursor(terrain)
		hide_painting = true
		_begin_stroke()
	_paint_tile_under_cursor(hide_value)
	_hide_stroke_applied = true

# Whether the tile directly under the mouse cursor is hidden (the anchor used
# to pick the direction of a Shift+LMB hide drag).
func _tile_hidden_at_cursor(t: WmtScript) -> bool:
	if t == null or not is_instance_valid(t):
		return false
	var hit := _flat_point_under_mouse()
	if hit == null:
		return false
	var edge := t.TILE_EDGE
	var tgx := int(floor((hit as Vector3).x / edge))
	var tgz := int(floor((hit as Vector3).z / edge))
	return t.is_tile_hidden(tgx * t.SQUARES_PER_TILE, tgz * t.SQUARES_PER_TILE)

func _paint_tile_under_cursor(hidden_state: bool) -> void:
	var t := stroke_terrain
	if t == null or not is_instance_valid(t):
		return
	var hit := _flat_point_under_mouse()
	if hit == null:
		return
	var hp: Vector3 = hit
	# Hide/unhide EVERY tile whose footprint intersects the brush circle, not
	# just the one under the cursor. Tiles are CHUNK_TILES per chunk side and
	# align to the chunk lattice, so bounding box + circle-square distance is
	# enough to enumerate the affected tile lattice exactly.
	var edge := t.TILE_EDGE
	var cx := hp.x
	var cz := hp.z
	var radius := cursor_radius
	var radius2 := radius * radius
	var tgx0 := floori((cx - radius) / edge)
	var tgx1 := floori((cx + radius) / edge)
	var tgz0 := floori((cz - radius) / edge)
	var tgz1 := floori((cz + radius) / edge)
	var sp := t.SQUARES_PER_TILE
	var changed := false
	for tgz in range(tgz0, tgz1 + 1):
		for tgx in range(tgx0, tgx1 + 1):
			var bx := tgx * edge
			var bz := tgz * edge
			if bx < float(t.cell_x0) * t.SQUARE_EDGE or bz < float(t.cell_z0) * t.SQUARE_EDGE \
					or bx + edge > float(t.cell_x1) * t.SQUARE_EDGE \
					or bz + edge > float(t.cell_z1) * t.SQUARE_EDGE:
				continue
			var ck: Vector2i = t._chunk_of(tgx * sp, tgz * sp)
			if not t.has_chunk(ck.x, ck.y):
				continue
			var nearest_x := clampf(cx, bx, bx + edge)
			var nearest_z := clampf(cz, bz, bz + edge)
			var dx := cx - nearest_x
			var dz := cz - nearest_z
			if dx * dx + dz * dz > radius2:
				continue
			if t.is_tile_hidden(tgx * sp, tgz * sp) == hidden_state:
				continue
			t.set_tile_hidden(tgx * sp, tgz * sp, hidden_state)
			stroke_changed = true
			if not stroke_touched_keys.has(ck):
				stroke_touched_keys.append(ck)
			changed = true
	if changed:
		# The overlay and cursor ring are expensive to re-drape; defer both to
		# stroke end so a fast multi-tile drag only rebuilds them once.
		_tile_overlay_dirty = true

func _end_hide_paint() -> void:
	if not hide_painting:
		return
	hide_painting = false
	_end_stroke()

func _on_selection_changed() -> void:
	var previous := terrain
	var sel := EditorInterface.get_selection()
	var nodes := sel.get_selected_nodes()
	var found: Variant = null
	for n in nodes:
		if n is WmtScript:
			found = n
			break
	var new_terrain := found as WmtScript
	if _paint_popup_open():
		_close_paint_popup()
	# A stroke survives selection churn on its own node (e.g. Ctrl-click
	# toggling); only a different node being focused ends the current stroke.
	if sculpting and is_instance_valid(stroke_terrain) \
			and new_terrain != stroke_terrain and new_terrain != null:
		_end_stroke()
	if paint_stroking and terrain != new_terrain:
		_end_paint_stroke()
	if vertex_stroking and terrain != new_terrain:
		_end_vertex_stroke()
	terrain = new_terrain
	if terrain != previous:
		undo_stack.clear()
		redo_stack.clear()
		_hide_tiles_overlay()
		_clear_wireframe_overlay()
		_end_hide_paint()
		# Paint-mode per-tile state belongs to the focused terrain.
		_paint_selected.clear()
		_picker_tile = Vector2i(-1, -1)
		_side_sel_dirty = true
		_side_nopaint_dirty = true
		_sel_mask_tex = null
		_nopaint_mask_tex = null
		# A brand-new (still unpainted) terrain must not inherit the previous
		# node's brush textures: the Ctrl+RMB menu would advertise paint from
		# the old terrain that doesn't exist here.
		if terrain != null and terrain.tile_paints.is_empty():
			_reset_paint_toolbox()
	if terrain != null:
		_ensure_ring()
		_attach_ring()
		_apply_terrain_overlays()
		_refresh_brush_visibility()
		call_deferred("_update_cursor_position")
	else:
		_hide_ring()
		_hide_tiles_overlay()
	if panel != null and panel.has_method("set_terrain_active"):
		panel.set_terrain_active(terrain != null)

# Start the paint toolbox from a clean slate (empty channel textures, default
# repeat counts) for a terrain that has no paint yet, and mirror that state
# into the panel + popup so nothing from the previous terrain lingers.
func _reset_paint_toolbox(report := false) -> void:
	var changed := false
	var tex: Array[String] = []
	for i in range(WmtScript.PAINT_CHANNELS):
		tex.append("")
	if paint_channel_textures != tex:
		paint_channel_textures = tex
		changed = true
	var til: Array[float] = []
	for i in range(WmtScript.PAINT_CHANNELS):
		til.append(16.0)
	if paint_channel_tilings != til:
		paint_channel_tilings = til
		changed = true
	if not changed:
		return
	if panel != null and panel.has_method("set_paint_channel_textures"):
		panel.set_paint_channel_textures(paint_channel_textures)
	_refresh_paint_popup_sel()
	if report:
		print("[WMT] paint toolbox cleared for a fresh terrain")

func _update_cursor_position() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d()
	_pick_cursor(vp.get_mouse_position())

# Pick the terrain surface under the given 3D-viewport point and drape the
# brush ring there (or hide it when the point misses the surface / the ring
# has no parent to attach to).
func _pick_cursor(mouse: Vector2) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d()
	var camera := vp.get_camera_3d()
	if camera == null:
		if _selftest_mode:
			print("[WMT4 pick] no camera, mouse=", mouse)
		return
	if not vp.get_visible_rect().has_point(mouse):
		if _selftest_mode:
			print("[WMT4 pick] OUTSIDE vp rect mouse=", mouse, " rect=", vp.get_visible_rect())
		_hide_ring()
		return
	var origin := terrain.to_local(camera.project_ray_origin(mouse))
	var basis := terrain.global_transform.basis
	var dir := (basis.inverse() * camera.project_ray_normal(mouse)).normalized()
	var hit := _raycast_terrain_surface(origin, dir)
	if hit == null:
		if _selftest_mode:
			print("[WMT4 pick] MISS mouse=", mouse, " cam_pos=", camera.global_position,
				" cam_look=", camera.get_global_transform().basis.z, " ray0=", origin, " dir=", dir,
				" grid=%dx%d aabb=%s" % [terrain.GRID_SQUARES_X, terrain.GRID_SQUARES_Z, terrain.get_aabb()])
		_hide_ring()
		return
	cursor_local = hit
	_drape_ring()

# March a ray through the terrain volume (local space) cell by cell and test
# it against each cell's four X-surface triangles (2 bilinear halves + the
# sculptable center vertex). Exact per-triangle tests catch any surface,
# including thin raised-center spikes that fixed-step marching would straddle
# and skip entirely.
func _raycast_terrain_surface(origin: Vector3, dir: Vector3) -> Variant:
	if terrain == null or not is_instance_valid(terrain):
		return null
	# Use the CUSTOM aabb when the terrain has one: that is the box the renderer
	# culls and fits shadows against, and wmt keeps it deliberately padded, so a
	# ray is never rejected for geometry that is on screen. get_aabb() returns
	# the raw mesh AABB instead, which goes stale the moment a stroke patches
	# vertices in place.
	var aabb: AABB = terrain.get_aabb()
	var custom: AABB = terrain.get_custom_aabb()
	if custom.size.length() > 0.001:
		aabb = custom
	if aabb.size == Vector3.ZERO:
		return null
	# Pad the slab in Y: on untouched ground the raw mesh AABB is zero-thick
	# (all heights 0), so the ray would meet the surface exactly at the slab
	# exit and boundary-tie out -> the brush vanishes/ flickers on unsculpted
	# terrain. Expanding Y makes the surface plane cut the interior of the
	# test volume, so the DDA returns the true first hit.
	aabb.position.y -= 1.0
	aabb.size.y += 2.0
	var t0 := 0.0
	var t1 := 9000.0
	for axis in [0, 2]:
		var o := origin[axis]
		var d := dir[axis]
		if absf(d) < 1e-9:
			if o < aabb.position[axis] or o > aabb.end[axis]:
				return null
		else:
			var ta := (aabb.position[axis] - o) / d
			var tb := (aabb.end[axis] - o) / d
			if ta > tb:
				var tmp := ta
				ta = tb
				tb = tmp
			t0 = maxf(t0, ta)
			t1 = minf(t1, tb)
			if t0 > t1:
				return null
	t0 = maxf(t0, 0.0)
	if t1 <= t0:
		return null
	var ty_a := t0
	var ty_b := t1
	if absf(dir.y) < 1e-9:
		if origin.y < aabb.position.y or origin.y > aabb.end.y:
			return null
	else:
		ty_a = (aabb.position.y - origin.y) / dir.y
		ty_b = (aabb.end.y - origin.y) / dir.y
		if ty_a > ty_b:
			var tmp := ty_a
			ty_a = ty_b
			ty_b = tmp
		ty_a = maxf(ty_a, t0)
		ty_b = minf(ty_b, t1)
		if ty_b <= ty_a:
			return null
	t0 = ty_a
	t1 = ty_b
	# If the ray starts at/below the surface (camera inside the terrain), the
	# entry point is the hit.
	var prev := origin + dir * t0
	var prev_s := terrain.sample_surface(Vector3(prev.x, 0.0, prev.z))
	if prev.y <= prev_s:
		return Vector3(prev.x, prev_s, prev.z)
	# Walk the crossed grid cells near-to-far (ray passes through the xz
	# footprint from t0 to t1) and take the first triangle hit.
	var e := terrain.SQUARE_EDGE
	var p := origin + dir * t0
	var gx := int(floorf(p.x / e))
	var gz := int(floorf(p.z / e))
	var t := t0
	var sx := 1 if dir.x > 0.0 else (-1 if dir.x < 0.0 else 0)
	var sz := 1 if dir.z > 0.0 else (-1 if dir.z < 0.0 else 0)
	var tx_next := INF
	var tz_next := INF
	var guard := 0
	while t < t1:
		var cell_t := _cell_ray_hit(terrain, gx, gz, origin, dir)
		if cell_t < t1:
			var hp := origin + dir * cell_t
			return Vector3(hp.x, terrain.sample_surface(Vector3(hp.x, 0.0, hp.z)), hp.z)
		# Next gridline crossing along x and/or z.
		if sx != 0 and tx_next == INF:
			tx_next = ((gx + (1 if sx > 0 else 0)) * e - origin.x) / dir.x
		if sz != 0 and tz_next == INF:
			tz_next = ((gz + (1 if sz > 0 else 0)) * e - origin.z) / dir.z
		if sx == 0 and sz == 0:
			return null
		if tx_next >= t1 and tz_next >= t1:
			return null
		if tx_next == tz_next:
			if tx_next < t1:
				gx += sx
				gz += sz
				t = tx_next
			tx_next = INF
			tz_next = INF
		elif tx_next < tz_next:
			if tx_next < t1:
				gx += sx
				t = tx_next
			tx_next = INF
		else:
			if tz_next < t1:
				gz += sz
				t = tz_next
			tz_next = INF
		guard += 1
		if guard > (terrain.GRID_SQUARES_X + terrain.GRID_SQUARES_Z + 8) * 4:
			return null
	return null

# Ray vs the cell's four X-surface triangles. Returns the hit distance t
# (positive) or INF on a miss.
func _cell_ray_hit(terrain: WMT, gx: int, gz: int, origin: Vector3, dir: Vector3) -> float:
	if gx < terrain.cell_x0 or gz < terrain.cell_z0 or gx >= terrain.cell_x1 or gz >= terrain.cell_z1:
		return INF
	var e := terrain.SQUARE_EDGE
	var w := float(gx) * e
	var h := float(gz) * e
	var tl := Vector3(w, terrain.get_height(gx, gz), h)
	var tr := Vector3(w + e, terrain.get_height(gx + 1, gz), h)
	var br := Vector3(w + e, terrain.get_height(gx + 1, gz + 1), h + e)
	var bl := Vector3(w, terrain.get_height(gx, gz + 1), h + e)
	var c := Vector3(w + e * 0.5, terrain.get_center_height(gx, gz), h + e * 0.5)
	var best := INF
	best = minf(best, _ray_tri_hit(origin, dir, tr, c, tl))
	best = minf(best, _ray_tri_hit(origin, dir, br, c, tr))
	best = minf(best, _ray_tri_hit(origin, dir, bl, c, br))
	best = minf(best, _ray_tri_hit(origin, dir, tl, c, bl))
	return best

func _ray_tri_hit(origin: Vector3, dir: Vector3, v0: Vector3, v1: Vector3, v2: Vector3) -> float:
	var e1 := v1 - v0
	var e2 := v2 - v0
	var pv := dir.cross(e2)
	var det := e1.dot(pv)
	if absf(det) < 1e-9:
		return INF
	var inv := 1.0 / det
	var tv := origin - v0
	var u := tv.dot(pv) * inv
	if u < -1e-4 or u > 1.0 + 1e-4:
		return INF
	var qv := tv.cross(e1)
	var v := dir.dot(qv) * inv
	if v < -1e-4 or u + v > 1.0 + 1e-4:
		return INF
	var tt := e2.dot(qv) * inv
	return tt if tt > 0.0 else INF

func _attach_ring() -> void:
	# The brush cursor lives in the overlay shader, so there is no ring node to
	# parent to the terrain anymore. _drape_ring() pushes geometry into the
	# material; kept as a no-op for legacy call sites.
	return

func _hide_ring() -> void:
	if _wireframe_mat == null or not is_instance_valid(_wireframe_mat):
		return
	_wireframe_mat.set_shader_parameter("brush_on", false)
	_wireframe_mat.set_shader_parameter("brush_falloff_on", false)

func _ring_allowed() -> bool:
	# Show the brush cursor in every terrain-editing tab (tiles, zones, sculpt,
	# paint, vertex), but never in Objects mode (there the ring would swallow
	# the viewport and block selecting/moving scene objects) nor in Settings
	# mode (nothing is painted there, so the ring is just noise over the
	# environment/object controls).
	return active_tab != TAB_OBJECTS and active_tab != TAB_SETTINGS

func _on_mode_changed(index: int) -> void:
	_switch_mode(index)

var _switching_mode := false
func _switch_mode(index: int) -> void:
	if _switching_mode:
		return
	_switching_mode = true
	if sculpting:
		_end_stroke()
	if paint_stroking:
		_end_paint_stroke()
	if vertex_stroking:
		_end_vertex_stroke()
	if _paint_popup_open():
		_close_paint_popup()
	call_deferred("_switch_mode_deferred", index)

func _refresh_brush_visibility() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	# The brush cursor stays visible in every editing mode (its radius marks the
	# WMT tile hide/unhide area too); only the falloff circle is kept out of WMT
	# tiles mode, since tile painting is binary and has no inner ring to show.
	# Objects mode gets no cursor at all so the viewport stays free for normal
	# object selection and manipulation.
	if active_tab == TAB_OBJECTS:
		_hide_ring()
		_hide_tiles_overlay()
		return
	if active_tab == TAB_WMT:
		_rebuild_overlay_layers()
	else:
		_hide_tiles_overlay()
	_update_cursor_position()

func _make_overlay_material(c: Color, alpha: float, priority: int) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Depth test ON: lines draped on the surface are hidden wherever the mesh
	# itself occludes them (hill backsides, crests in the way) instead of
	# showing through everything.
	m.no_depth_test = false
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_color = Color(c.r, c.g, c.b, alpha)
	m.render_priority = priority
	return m

# Drape a line over the terrain surface: sample the mesh height every tile
# edge along the segment and emit a ribbon that follows it exactly.
func _append_draped_line(pts: PackedVector3Array, idx: PackedInt32Array, cols: PackedColorArray,
		ax: float, az: float, bx: float, bz: float, thick: float, lift: float, color: Color) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	var dx := bx - ax
	var dz := bz - az
	var len := sqrt(dx * dx + dz * dz)
	if len < 1e-6:
		return
	var seg_x := dx / len
	var seg_z := dz / len
	var px := -seg_z
	var pz := seg_x
	var half := thick * 0.5
	var samples := maxi(1, int(ceil(len / terrain.SQUARE_EDGE)))
	var start_n := pts.size()
	for i in range(samples + 1):
		var prog := minf(float(i) / float(samples), 1.0)
		var sx_ := ax + dx * prog
		var sz_ := az + dz * prog
		var h := terrain.sample_height(Vector3(sx_, 0.0, sz_)) + lift
		pts.append(Vector3(sx_ - px * half, h, sz_ - pz * half))
		pts.append(Vector3(sx_ + px * half, h, sz_ + pz * half))
	for i in range(samples):
		var a := start_n + i * 2
		idx.append(a)
		idx.append(a + 2)
		idx.append(a + 1)
		idx.append(a + 1)
		idx.append(a + 2)
		idx.append(a + 3)
	for i in range((samples + 1) * 2):
		cols.append(color)

func _ribbon_mesh(pts: PackedVector3Array, idx: PackedInt32Array, cols: PackedColorArray) -> ArrayMesh:
	var la := []
	la.resize(Mesh.ARRAY_MAX)
	la[Mesh.ARRAY_VERTEX] = pts
	la[Mesh.ARRAY_INDEX] = idx
	la[Mesh.ARRAY_COLOR] = cols
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, la)
	return mesh

func _make_overlay_node(node_name: String, mesh: ArrayMesh, color: Color, alpha: float, priority: int) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = node_name
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.mesh = mesh
	mi.set_material_override(_make_overlay_material(color, alpha, priority))
	mi.set_custom_aabb(_overlay_cover_aabb())
	if terrain != null and is_instance_valid(terrain):
		terrain.add_child(mi)
	return mi

func _rebuild_overlay_layers() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	_hide_tiles_overlay()
	var t := terrain
	var cw := t.CHUNK_WIDTH

	# Blue chunk outlines: perimeter of every existing chunk, draped.
	var ch_pts := PackedVector3Array()
	var ch_idx := PackedInt32Array()
	var ch_cols := PackedColorArray()
	for c in t.chunks:
		var chx: int = (c as Vector2i).x
		var chz: int = (c as Vector2i).y
		var ax := chx * cw
		var az := chz * cw
		_append_draped_line(ch_pts, ch_idx, ch_cols, ax, az, ax + cw, az, BAR_THICK, TERRAIN_LIFT, COL_TERRAIN)
		_append_draped_line(ch_pts, ch_idx, ch_cols, ax + cw, az, ax + cw, az + cw, BAR_THICK, TERRAIN_LIFT, COL_TERRAIN)
		_append_draped_line(ch_pts, ch_idx, ch_cols, ax + cw, az + cw, ax, az + cw, BAR_THICK, TERRAIN_LIFT, COL_TERRAIN)
		_append_draped_line(ch_pts, ch_idx, ch_cols, ax, az + cw, ax, az, BAR_THICK, TERRAIN_LIFT, COL_TERRAIN)
	terrain_outline_mi = _make_overlay_node("WmtChunkOverlay", _ribbon_mesh(ch_pts, ch_idx, ch_cols), COL_TERRAIN, 1.0, RP_TERRAIN)

	# Ghost: perimeter plus inner red tile grid of each candidate chunk slot.
	_compute_ghost_keys()
	if not ghost_keys.is_empty():
		var g_pts := PackedVector3Array()
		var g_idx := PackedInt32Array()
		var g_cols := PackedColorArray()
		var tline := cw / float(t.CHUNK_TILES)
		for key in ghost_keys:
			var k: Vector2i = key
			var gx0 := k.x * cw
			var gz0 := k.y * cw
			_append_draped_line(g_pts, g_idx, g_cols, gx0, gz0, gx0 + cw, gz0, BAR_THICK, GHOST_LIFT, COL_GHOST)
			_append_draped_line(g_pts, g_idx, g_cols, gx0 + cw, gz0, gx0 + cw, gz0 + cw, BAR_THICK, GHOST_LIFT, COL_GHOST)
			_append_draped_line(g_pts, g_idx, g_cols, gx0 + cw, gz0 + cw, gx0, gz0 + cw, BAR_THICK, GHOST_LIFT, COL_GHOST)
			_append_draped_line(g_pts, g_idx, g_cols, gx0, gz0 + cw, gx0, gz0, BAR_THICK, GHOST_LIFT, COL_GHOST)
			var gi := gx0
			while gi <= gx0 + cw + 1e-6:
				_append_draped_line(g_pts, g_idx, g_cols, gi, gz0, gi, gz0 + cw, BAR_THICK * 0.5, GHOST_LIFT, COL_GHOST)
				gi += tline
			var gj := gz0
			while gj <= gz0 + cw + 1e-6:
				_append_draped_line(g_pts, g_idx, g_cols, gx0, gj, gx0 + cw, gj, BAR_THICK * 0.5, GHOST_LIFT, COL_GHOST)
				gj += tline
		ghost_mi = _make_overlay_node("WmtGhostOverlay", _ribbon_mesh(g_pts, g_idx, g_cols), COL_GHOST, 0.8, RP_GHOST)
	else:
		ghost_mi = null

# True if any tile in chunk-lattice column `tcol` (tile coords, -1 or CHUNK_TILES
# = outside this chunk) is visible; used to cull red tile-border lines over
# hidden-only columns.
func chx_is_tile_col_visible(t: WmtScript, chx: int, chz: int, tcol: int) -> bool:
	if tcol < 0 or tcol >= t.CHUNK_TILES:
		return false
	for trow in range(t.CHUNK_TILES):
		var gx := chx * t.CHUNK_CELLS + tcol * t.SQUARES_PER_TILE
		var gz := chz * t.CHUNK_CELLS + trow * t.SQUARES_PER_TILE
		if not t.is_tile_hidden(gx, gz):
			return true
	return false

func chx_is_tile_row_visible(t: WmtScript, chx: int, chz: int, trow: int) -> bool:
	if trow < 0 or trow >= t.CHUNK_TILES:
		return false
	for tcol in range(t.CHUNK_TILES):
		var gx := chx * t.CHUNK_CELLS + tcol * t.SQUARES_PER_TILE
		var gz := chz * t.CHUNK_CELLS + trow * t.SQUARES_PER_TILE
		if not t.is_tile_hidden(gx, gz):
			return true
	return false

func _compute_ghost_keys() -> void:
	ghost_keys.clear()
	if terrain == null or not is_instance_valid(terrain):
		return
	for c in terrain.chunks:
		var k: Vector2i = c
		for off in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var o2: Vector2i = off
			var nk := k + o2
			if not terrain.has_chunk(nk.x, nk.y):
				ghost_keys[nk] = true

func _try_place_at_mouse() -> bool:
	if terrain == null or not is_instance_valid(terrain):
		return false
	if ghost_keys.is_empty():
		return false
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d()
	var camera := vp.get_camera_3d()
	if camera == null:
		return false
	var mouse := vp.get_mouse_position()
	if not vp.get_visible_rect().has_point(mouse):
		return false
	var origin := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)
	if absf(dir.y) < 1e-6:
		return false
	var plane_y := terrain.global_position.y
	var t := (plane_y - origin.y) / dir.y
	if t <= 0.0:
		return false
	var hit := origin + dir * t
	var local := terrain.to_local(hit)
	var cw := terrain.CHUNK_WIDTH
	var key := Vector2i(int(floor(local.x / cw)), int(floor(local.z / cw)))
	if not ghost_keys.has(key):
		return false
	_place_terrain_at(key)
	return true

func _place_terrain_at(key: Vector2i) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	if terrain.has_chunk(key.x, key.y):
		return
	var snap := _capture_state(terrain)
	if not terrain.add_chunk(key.x, key.y):
		return
	undo_stack.append(snap)
	if undo_stack.size() > UNDO_LIMIT:
		undo_stack.pop_front()
	redo_stack.clear()
	if active_tab == TAB_WMT:
		_rebuild_overlay_layers()
	_save_terrain(terrain, [key])
	print("[WMT] added chunk %d,%d" % [key.x, key.y])

func _record_stroke_touched(t: WmtScript, center: Vector3, radius: float) -> void:
	if t == null or not is_instance_valid(t):
		return
	var cw := t.CHUNK_WIDTH
	var ax := int(floor((center.x - radius) / cw))
	var bx := int(floor((center.x + radius) / cw))
	var az := int(floor((center.z - radius) / cw))
	var bz := int(floor((center.z + radius) / cw))
	for cz in range(az, bz + 1):
		for cx in range(ax, bx + 1):
			if t.has_chunk(cx, cz):
				var key := Vector2i(cx, cz)
				if not stroke_touched_keys.has(key):
					stroke_touched_keys.append(key)

# Raycast the rendered terrain surface under the mouse in local space, or
# null if the mouse is off the viewport or doesn't hit the terrain.
# True when the left-button press under the cursor actually hits the terrain
# surface. Used to decide whether this press belongs to the plugin (and must not
# become an editor node-drag) or to the scene.
func _press_lands_on_terrain() -> bool:
	if terrain == null or not is_instance_valid(terrain):
		return false
	var vp := EditorInterface.get_editor_viewport_3d()
	if vp == null or not vp.get_visible_rect().has_point(vp.get_mouse_position()):
		return false
	var camera := vp.get_camera_3d()
	if camera == null:
		return false
	var mouse := vp.get_mouse_position()
	var origin := terrain.to_local(camera.project_ray_origin(mouse))
	var dir := (terrain.global_transform.basis.inverse() \
		* camera.project_ray_normal(mouse)).normalized()
	return _raycast_terrain_surface(origin, dir) != null

# mouse defaults to the live pointer. A negative x means "use the live pointer";
# passing a real position is for the paste, which has to aim at where the user
# was pointing in the viewport rather than at the browser that is now open.
func _local_point_under_mouse(mouse: Vector2 = Vector2(-1.0, -1.0)) -> Variant:
	if terrain == null or not is_instance_valid(terrain):
		return null
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d()
	if mouse.x < 0.0:
		mouse = vp.get_mouse_position()
	if not vp.get_visible_rect().has_point(mouse):
		return null
	var camera := vp.get_camera_3d()
	if camera == null:
		return null
	var origin := terrain.to_local(camera.project_ray_origin(mouse))
	var basis := terrain.global_transform.basis
	var dir := (basis.inverse() * camera.project_ray_normal(mouse)).normalized()
	return _raycast_terrain_surface(origin, dir)

# Local space point on the flat XZ plane at the terrain's origin height, under
# the mouse. Unlike _local_point_under_mouse() this NEVER misses a HIDDEN tile,
# whose mesh triangles collapse to degenerate points the surface raycast can't
# hit - that miss is what made single clicks and Shift+LMB "flash" instead of
# toggling visibility.
func _flat_point_under_mouse(at: Vector2 = Vector2(-1.0, -1.0)) -> Variant:
	if terrain == null or not is_instance_valid(terrain):
		return null
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d()
	var mouse: Vector2 = vp.get_mouse_position() if at.x < 0.0 else at
	if not vp.get_visible_rect().has_point(mouse):
		return null
	var camera := vp.get_camera_3d()
	if camera == null:
		return null
	var origin := camera.project_ray_origin(mouse)
	var dir := camera.project_ray_normal(mouse)
	if absf(dir.y) < 1e-6:
		return null
	var t := (terrain.global_position.y - origin.y) / dir.y
	if t <= 0.0:
		return null
	return terrain.to_local(origin + dir * t)

# Single plain-LMB click in the tiles tab: toggle the one tile under the
# cursor between hidden and visible, with a full snapshot for undo/redo.
func _toggle_tile_under_cursor() -> void:
	var t := terrain
	if t == null or not is_instance_valid(t):
		return
	var hit := _flat_point_under_mouse()
	if hit == null:
		return
	var hp: Vector3 = hit
	var edge := t.TILE_EDGE
	var tgx := int(floor(hp.x / edge))
	var tgz := int(floor(hp.z / edge))
	var bx := tgx * edge
	var bz := tgz * edge
	if bx < float(t.cell_x0) * t.SQUARE_EDGE or bz < float(t.cell_z0) * t.SQUARE_EDGE \
			or bx + edge > float(t.cell_x1) * t.SQUARE_EDGE \
			or bz + edge > float(t.cell_z1) * t.SQUARE_EDGE:
		return
	var ck: Vector2i = t._chunk_of(tgx * t.SQUARES_PER_TILE, tgz * t.SQUARES_PER_TILE)
	if not t.has_chunk(ck.x, ck.y):
		return
	var was_hidden := t.is_tile_hidden(tgx * t.SQUARES_PER_TILE, tgz * t.SQUARES_PER_TILE)
	var snap := _capture_state(t)
	t.set_tile_hidden(tgx * t.SQUARES_PER_TILE, tgz * t.SQUARES_PER_TILE, not was_hidden)
	undo_stack.append(snap)
	if undo_stack.size() > UNDO_LIMIT:
		undo_stack.pop_front()
	redo_stack.clear()
	_rebuild_overlay_layers()
	_save_terrain(t, [ck])
	_update_cursor_position()
	print("[WMT] %s tile %d,%d" % ["hid" if not was_hidden else "showed", tgx, tgz])

func _chunk_under_mouse() -> Variant:
	if terrain == null or not is_instance_valid(terrain):
		return null
	var hit := _local_point_under_mouse()
	if hit == null:
		return null
	var cw := terrain.CHUNK_WIDTH
	var key := Vector2i(int(floor(hit.x / cw)), int(floor(hit.z / cw)))
	if terrain.has_chunk(key.x, key.y):
		return key
	return null

func _delete_chunk(key: Vector2i) -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	if not terrain.has_chunk(key.x, key.y):
		return
	if terrain.chunks.size() <= 1:
		print("[WMT] cannot delete the only chunk")
		return
	var snap := _capture_state(terrain)
	if not terrain.remove_chunk(key.x, key.y):
		return
	undo_stack.append(snap)
	if undo_stack.size() > UNDO_LIMIT:
		undo_stack.pop_front()
	redo_stack.clear()
	_apply_after_edit()
	_save_terrain(terrain)
	print("[WMT] deleted chunk %d,%d (%d remaining)" % [key.x, key.y, terrain.chunks.size()])

# Delete `cx_cz.wmt` files for chunks the terrain no longer has. Returns the
# paths actually removed, because the editor's filesystem VFS only learns about
# deletions from a scan() - update_file() covers changed files, not gone ones -
# and without that the deleted chunk keeps showing up (and can be read back) as
# if it were still on disk.
func _cleanup_stale_chunk_files(t: WmtScript, base: String) -> Array:
	var removed: Array = []
	if t == null or not is_instance_valid(t) or base == "":
		return removed
	var da := DirAccess.open(base)
	if da == null:
		return removed
	var re := RegEx.new()
	re.compile("^(-?\\d+)_(-?\\d+)\\.wmt$")
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if not da.current_is_dir():
			var m := re.search(fname)
			if m != null:
				var key := Vector2i(int(m.get_string(1)), int(m.get_string(2)))
				if not t.has_chunk(key.x, key.y):
					var full := base.path_join(fname)
					var err := DirAccess.remove_absolute(full)
					if err != OK:
						push_warning("[WMT] could not remove stale chunk file %s" % full)
					else:
						removed.append(full)
		fname = da.get_next()
	da.list_dir_end()
	return removed

# Ctrl+LMB / Ctrl+RMB in the tiles tab hide/show individual tiles; the mesh
# and overlays rebuild from the terrain's emit set automatically (and the
# wireframe overlay follows the fragment lattice, so it needs no rebuild).
func _hide_tiles_overlay() -> void:
	for mi in [tile_mi, terrain_outline_mi, ghost_mi]:
		if mi != null:
			if is_instance_valid(mi):
				mi.queue_free()
	tile_mi = null
	terrain_outline_mi = null
	ghost_mi = null

func _build_ring_mesh() -> ArrayMesh:
	# The brush cursor is drawn in the overlay shader now (see _drape_ring);
	# this no-op exists only so legacy call sites / the selftest keep parsing.
	return ArrayMesh.new()

func _drape_ring() -> void:
	# The brush cursor lives IN the overlay shader now (fragment bands, same
	# fwidth technique as the tile lines), so "draping" is just pushing the
	# cursor parameters into the material. The shader keeps the ring a constant
	# screen thickness at any zoom and can never z-fight or clip like the old
	# 3D ribbon mesh did.
	if _wireframe_mat == null or not is_instance_valid(_wireframe_mat) \
			or terrain == null or not is_instance_valid(terrain) \
			or cursor_local == null:
		return
	if not _ring_allowed():
		_wireframe_mat.set_shader_parameter("brush_on", false)
		return
	_wireframe_mat.set_shader_parameter("brush_on", true)
	_wireframe_mat.set_shader_parameter("brush_center",
		Vector2(cursor_local.x, cursor_local.z))
	_wireframe_mat.set_shader_parameter("brush_radius", cursor_radius)
	_wireframe_mat.set_shader_parameter("brush_width", brush_thickness * 4.0 + 0.5)
	_wireframe_mat.set_shader_parameter("brush_color", brush_color)
	var falloff_on := falloff_ratio < 0.999 and active_tab != TAB_WMT
	_wireframe_mat.set_shader_parameter("brush_falloff_on", falloff_on)
	if falloff_on:
		_wireframe_mat.set_shader_parameter("brush_falloff_radius", cursor_radius * falloff_ratio)

# Overlay: instead of a second line mesh, the terrain draws its own cells,
# tile and chunk lattices, plus optional shading, straight onto itself.
# terrain_overlay.gdshader derives each lattice from the fragment's
# interpolated local position (which sits exactly on the absolute cell lattice
# — wmt rebuilds corner/center verts at integer * edge multiples), so the real
# edges are highlighted with no topology tracking, no per-flip updates, and no
# geometry from hidden/absent cells.

func _ensure_overlay_mat() -> ShaderMaterial:
	if _wireframe_mat == null or not is_instance_valid(_wireframe_mat):
		_wireframe_mat = ShaderMaterial.new()
		_wireframe_mat.shader = load(TerrainOverlayShaderPath)
	var t := terrain if is_instance_valid(terrain) else null
	_wireframe_mat.set_shader_parameter("base_color",
		t.flat_color if t != null else Color.WHITE)
	_wireframe_mat.set_shader_parameter("square_edge",
		t.SQUARE_EDGE if t != null else 2.0)
	_wireframe_mat.set_shader_parameter("tile_cells",
		float(t.SQUARES_PER_TILE) if t != null else 8.0)
	_wireframe_mat.set_shader_parameter("chunk_cells",
		float(t.CHUNK_CELLS) if t != null else 128.0)
	_wireframe_mat.set_shader_parameter("show_wire", wireframe_on)
	_wireframe_mat.set_shader_parameter("wire_color",
		Color(1.0, 1.0, 1.0) if not wireframe_black else Color(0.0, 0.0, 0.0))
	_wireframe_mat.set_shader_parameter("edge_width", wireframe_thickness)
	_wireframe_mat.set_shader_parameter("show_tile_lines", wmt_lines_on)
	_wireframe_mat.set_shader_parameter("tile_width", tile_line_thickness)
	_wireframe_mat.set_shader_parameter("show_chunk_lines", chunk_lines_on)
	_wireframe_mat.set_shader_parameter("chunk_width", tile_line_thickness)
	# Paint (v11 .wmt): four per-channel texture arrays + layout atlases and the
	# splat/top atlases drive the layered (Photoshop) paint render. The atlases
	# are rebuilt lazily and cached until dirty, so this stays cheap between
	# strokes.
	var pt := t
	_wireframe_mat.set_shader_parameter("has_paint",
		(true if pt != null and pt.tile_paints.size() > 0 else false))
	if pt != null:
		_wireframe_mat.set_shader_parameter("paint_origin",
			Vector2(pt.tile_origin_x(), pt.tile_origin_z()))
		_wireframe_mat.set_shader_parameter("atlas_tiles",
			Vector2(pt.tile_count_x(), pt.tile_count_z()))
		# The selection / non-paintable overlays are one mask texel per tile, so
		# a cached mask from a smaller grid gets sampled across the new size and
		# the highlight lands offset and stretched. Adding or deleting a chunk
		# reflows the tile grid, so rebuild both masks whenever it changes.
		var tcs := Vector2i(pt.tile_count_x(), pt.tile_count_z())
		if tcs != _mask_tile_counts:
			_mask_tile_counts = tcs
			_side_sel_dirty = true
			_side_nopaint_dirty = true
		_wireframe_mat.set_shader_parameter("tile_edge", pt.TILE_EDGE)
		_wireframe_mat.set_shader_parameter("paint_tile_px", float(WmtScript.PAINT_TILE_PX))
		_wireframe_mat.set_shader_parameter("splat_pad", float(WmtScript.SPLAT_PAD))
		# Vertex tint is its own padded atlas: finer 16x16 blocks, own echo pad.
		_wireframe_mat.set_shader_parameter("tint_tile_px", float(WmtScript.TINT_TILE_PX))
		_wireframe_mat.set_shader_parameter("tint_pad", float(WmtScript.TINT_PAD))
	# Per-channel textures + the splat/top atlases drive the layered paint render.
	_set_paint_channel_params(_wireframe_mat)
	if t != null:
		# Vertex-tint splatmap: uploaded (rebuild on demand) whenever any tile
		# is tinted; otherwise the shader skips the emission add entirely. Its atlas
		# is padded like the splat atlas but with a finer 16x16 tint lattice, so
		# the shader samples it with the tint pitch (origin = the TILE lattice).
		if not t.tint_is_empty():
			var vt := t.tint_atlas_texture()
			_wireframe_mat.set_shader_parameter("vertex_tint_on",
				vertex_colors_on and not t.tint_is_empty())
			if vt != null:
				_wireframe_mat.set_shader_parameter("vertex_tint_tex", vt)
			_wireframe_mat.set_shader_parameter("vertex_tint_origin",
				Vector2(t.tile_origin_x(), t.tile_origin_z()))
			# SUPER-WHITE: how far a near-white top layer is pushed past 1.0. Set
			# every time so a shader reload cannot leave it at the default while
			# the rest of the params are fresh.
			_wireframe_mat.set_shader_parameter("vertex_tint_boost", VERTEX_TINT_BOOST)
		else:
			_wireframe_mat.set_shader_parameter("vertex_tint_on", false)
	return _wireframe_mat


func _set_paint_channel_params(m: ShaderMaterial) -> void:
	_ensure_texture_atlas()
	var t := terrain if is_instance_valid(terrain) else null
	for i in range(WmtScript.PAINT_CHANNELS):
		var arr: Texture2DArray = _chan_arrays[i] if i < _chan_arrays.size() else null
		var layout: ImageTexture = _chan_layouts[i] if i < _chan_layouts.size() else null
		m.set_shader_parameter("chan_arr%d" % i, arr)
		m.set_shader_parameter("chan_layout%d" % i, layout)
	# One RGBA splatmap atlas carries all channel weights underneath; per-tile
	# texture repeat lives in the layout textures' green channel. Rendering is a
	# masked-depth blend over those weights (competitive coverage -> brush
	# falloff + alphamap feathering). The R8 top map only serves the eyedropper
	# (paint order) and is not bound to the shader.
	m.set_shader_parameter("splat_splatmap", t.paint_splat_texture() if t != null else null)
	m.set_shader_parameter("paint_depth", paint_depth)
	# Paint-mode overlays: blue over selected tiles, red over tiles the current
	# brush texture can't paint. Masks are rebuilt lazily on the same tile
	# lattice as the splat atlas and blended over the base at 50%.
	_rebuild_side_masks()
	m.set_shader_parameter("sel_mask_tex", _sel_mask_tex)
	m.set_shader_parameter("nopaint_mask_tex", _nopaint_mask_tex)
	m.set_shader_parameter("sel_on", (1.0 if _paint_selected.size() > 0 else 0.0))
	# The red "this brush can't paint here" mask is PAINT-MODE-ONLY feedback. It
	# was on in every tab, so a WMT or vertex-colour user saw tiles go red for
	# a constraint that does not even exist outside painting.
	m.set_shader_parameter("nopaint_on",
		(1.0 if active_tab == TAB_PAINT and t != null and t.tile_paints.size() > 0 and
			_brush_texture() != "" else 0.0))

# Resolve which texture the tile actually paints with for slot `slot`
# (0..PAINT_CHANNELS-1): strictly the tile's own per-slot override. No global
# fallback - a tile only ever shows what was assigned to it. A blank path
# (unmapped slot) resolves to "".
func _resolved_tile_tex(t: WmtScript, key: Vector2i, slot: int) -> String:
	var path := t.tile_texture_path(key.x, key.y, slot)
	if path != "" and not _path_exists(path):
		return ""
	return path

func _path_exists(path: String) -> bool:
	if not _path_exists_cache.has(path):
		_path_exists_cache[path] = ResourceLoader.exists(path)
	return _path_exists_cache[path]

# Resolve the layer a painted tile's slot renders with at atlas build time: the
# tile's own per-slot override, else -- for a tile with NO assigned texture in
# ANY slot -- the first texture that channel ever received (fallbacks[c] is the
# head of that channel's path list). A freshly painted empty tile thus fills
# with the first painted texture instead of white/black; tiles that already have
# any mapping keep blank slots blank (those render black as an intentional flat
# spot). Never touches unpainted tiles (only painted keys are iterated).
func _fill_fallback_tile_tex(t: WmtScript, key: Vector2i, slot: int, fallbacks: Array) -> String:
	var path := _resolved_tile_tex(t, key, slot)
	if path != "":
		return path
	if (fallbacks[slot] as String) != "":
		var any_tex := false
		for c in range(WmtScript.PAINT_CHANNELS):
			if _resolved_tile_tex(t, key, c) != "":
				any_tex = true
				break
		if not any_tex:
			return fallbacks[slot]
	return ""

# The tile the brush cursor currently hovers over (tile-lattice key), or
# Vector2i(-1, -1) when the cursor misses the terrain / is outside the grid.
func _tile_under_cursor() -> Vector2i:
	var t := terrain
	if t == null or not is_instance_valid(t) or cursor_local == null:
		return Vector2i(-1, -1)
	var edge := float(t.TILE_EDGE)
	var tgx := int(floor(cursor_local.x / edge))
	var tgz := int(floor(cursor_local.z / edge))
	if tgx < 0 or tgz < 0 or tgx >= t.tile_count_x() or tgz >= t.tile_count_z():
		return Vector2i(-1, -1)
	return Vector2i(tgx, tgz)

# Where a channel/texture assignment lands when NO tiles are selected: the
# tile the popup / eyedropper targeted, else the last painted tile. (With a
# selection, assignments target every selected tile instead.)
func _anchor_tile() -> Vector2i:
	if _picker_tile != Vector2i(-1, -1):
		return _picker_tile
	return _last_painted_tile

# The texture of the currently selected paint-channel slot ("" = flat color).
func _brush_texture() -> String:
	if paint_channel < 0 or paint_channel >= paint_channel_textures.size():
		return ""
	return paint_channel_textures[paint_channel]

# Pick the channel a brush texture should paint into on `skey`, per tile:
# a channel that already maps the texture is reused (this is what keeps
# texturing seamless across tile borders), otherwise the first channel with no
# texture, preferring the user's currently selected slot. Returns -1 when the
# tile has no free channel (not paintable - the overlay shows it red).
func _auto_channel_for_brush(t: WmtScript, skey: Vector2i, tex: String) -> int:
	var arr: Array = t.tile_textures.get(skey, [])
	var first_empty := -1
	for i in range(WmtScript.PAINT_CHANNELS):
		var v: String = str(arr[i]) if i < arr.size() else ""
		if v == tex:
			return i
		if v == "" and first_empty < 0:
			first_empty = i
	if first_empty < 0:
		return -1
	if paint_channel >= 0 and paint_channel < WmtScript.PAINT_CHANNELS \
			and (str(arr[paint_channel]) if paint_channel < arr.size() else "") == "":
		return paint_channel
	return first_empty

# Set one channel's texture override on a tile, keeping the tile's other
# slots intact (no unscoped wipe). Creates the mapping even for tiles that are
# not painted yet so a selection can pre-map textures before painting.
func _set_tile_slot_texture(t: WmtScript, tk: Vector2i, channel: int, path: String) -> void:
	var tarr: Array = t.tile_textures.get(tk, [])
	while tarr.size() <= channel:
		tarr.append("")
	tarr[channel] = path
	t.set_tile_textures(tk.x, tk.y, tarr)

# Load the tile's per-channel texture mapping into the paint toolbox (the
# popup / eyedropper view) so it reflects what this actual tile uses.
func _pull_tile_textures_into_toolbox(t: WmtScript, tk: Vector2i) -> void:
	var arr: Array = t.tile_textures.get(tk, [])
	var norm := paint_channel_textures.duplicate()
	while norm.size() < WmtScript.PAINT_CHANNELS:
		norm.append("")
	var changed := false
	for i in range(WmtScript.PAINT_CHANNELS):
		var v: String = str(arr[i]) if i < arr.size() else ""
		if norm[i] != v:
			norm[i] = v
			changed = true
	if changed:
		paint_channel_textures = norm
		if panel != null and panel.has_method("set_paint_channel_textures"):
			panel.set_paint_channel_textures(paint_channel_textures)
		_refresh_paint_popup_sel()
		# The toolbox re-mirrored a tile's textures -> the brush changed, so the
		# non-paintable overlay has to reflect the new brush right away.
		_side_nopaint_dirty = true
		_apply_terrain_overlays()
	_save_overlay_prefs()

# Mirror textures: loading a tile into the popup / eyedropper also shows its
# per-channel repeat counts. Slots without a tile override keep the toolbox
# default (which is also what the editor would use to render that tile).
func _pull_tile_tilings_into_toolbox(t: WmtScript, tk: Vector2i) -> void:
	var arr: Variant = t.tile_tilings.get(tk)
	var changed := false
	# Mirror the render default (16.0) for slots without a tile override, so the
	# spinboxes always show exactly what that tile renders.
	for i in range(WmtScript.PAINT_CHANNELS):
		var v := 16.0
		if arr is Array and i < arr.size() and float(arr[i]) >= 1.0:
			v = clampf(float(arr[i]), 1.0, 256.0)
		if i < paint_channel_tilings.size() and not is_equal_approx(paint_channel_tilings[i], v):
			paint_channel_tilings[i] = v
			changed = true
	if changed:
		_refresh_paint_popup_sel()

# Mirror depths: loading a tile into the popup / eyedropper also shows its
# per-channel masked-depth pins. Slots without a tile override show the global
# paint depth (what that tile would render with).
func _pull_tile_depths_into_toolbox(t: WmtScript, tk: Vector2i) -> void:
	var arr: Variant = t.tile_depths.get(tk)
	var changed := false
	for i in range(WmtScript.PAINT_CHANNELS):
		var v := paint_depth
		if arr is Array and i < arr.size() and float(arr[i]) > 0.0:
			v = clampf(float(arr[i]), 0.01, 1.0)
		if i < paint_channel_depths.size() and not is_equal_approx(paint_channel_depths[i], v):
			paint_channel_depths[i] = v
			changed = true
	if changed:
		_refresh_paint_popup_sel()

# (Re)build the selection (blue) and non-paintable (red) overlay masks when
# their dirty flags are set. Masks are R8 images on the tile lattice (one
# texel per tile, coordinates = tile indices) bound to the overlay shader.
func _rebuild_side_masks() -> void:
	var t := terrain if is_instance_valid(terrain) else null
	if t == null:
		_sel_mask_tex = null
		_nopaint_mask_tex = null
		return
	if _side_sel_dirty:
		_rebuild_side_sel_mask(t)
	if _side_nopaint_dirty:
		_rebuild_side_nopaint_mask(t)

func _rebuild_side_sel_mask(t: WmtScript) -> void:
	var tx := t.tile_count_x()
	var tz := t.tile_count_z()
	var img := Image.create(tx, tz, false, Image.FORMAT_R8)
	img.fill(Color(0, 0, 0, 1))
	for key in _paint_selected:
		var k := key as Vector2i
		if k.x >= 0 and k.y >= 0 and k.x < tx and k.y < tz:
			img.set_pixel(k.x, k.y, Color(1, 0, 0, 1))
	_sel_mask_img = img
	_sel_mask_tex = ImageTexture.create_from_image(img)
	_side_sel_dirty = false

func _rebuild_side_nopaint_mask(t: WmtScript) -> void:
	var tx := t.tile_count_x()
	var tz := t.tile_count_z()
	var img := Image.create(tx, tz, false, Image.FORMAT_R8)
	img.fill(Color(0, 0, 0, 1))
	var brush := _brush_texture()
	if brush != "":
		for key in t.tile_paints:
			var k := key as Vector2i
			if k.x < 0 or k.y < 0 or k.x >= tx or k.y >= tz:
				continue
			if _auto_channel_for_brush(t, k, brush) < 0:
				img.set_pixel(k.x, k.y, Color(1, 0, 0, 1))
	_nopaint_mask_img = img
	_nopaint_mask_tex = ImageTexture.create_from_image(img)
	_side_nopaint_dirty = false

# Record the Alt state carried by a mouse event. `released` clears it so letting
# go of Alt mid-drag ends the selection drag even if no further Alt-less event
# arrives.
func _latch_alt(alt_pressed: bool, released: bool) -> void:
	if released:
		_alt_latched = false
	elif alt_pressed:
		_alt_latched = true
		_alt_latch_msec = Time.get_ticks_msec()

# Alt is down if either the polled key state says so or a mouse event said so
# recently enough to still be part of the current drag.
func _alt_down() -> bool:
	if _alt_latched and Time.get_ticks_msec() - _alt_latch_msec <= _ALT_LATCH_MS:
		return true
	return Input.is_key_pressed(KEY_ALT)

# Selection drag frame: toggle the selection state of every tile the brush circle
# touches, once per tile per drag (the touched set is cleared when the button
# goes up). The blue overlay refreshes only when something actually changed.
func _sel_drag_frame() -> void:
	var t := terrain
	if t == null or not is_instance_valid(t) or cursor_local == null:
		return
	var radius := maxf(cursor_radius, 0.25)
	var tiles := _tiles_within_radius(t, cursor_local, radius)
	var changed := false
	for key in tiles:
		if _sel_drag_touched.has(key):
			continue
		_sel_drag_touched[key] = true
		_toggle_tile_selection(key)
		changed = true
	if changed:
		_side_sel_dirty = true
		_apply_terrain_overlays()

# ---- WMT hide/unhide brush -------------------------------------------------
# Hold LMB in WMT mode and every tile the brush circle enters toggles its hidden
# state, so one stroke hides (or reveals) a whole swath instead of demanding a
# click per tile - the same brush behaviour Paint mode already had.
#
# The circle is evaluated in GRID space, not by raycasting the visible mesh, so
# a hidden tile is still under the cursor and can be brought back. A raycast
# would skip exactly the tiles the brush is there to restore.
func _begin_wmt_drag() -> void:
	_update_cursor_position()

func _wmt_drag_frame() -> void:
	var t := terrain
	if t == null or not is_instance_valid(t) or cursor_local == null:
		return
	var radius := maxf(cursor_radius, 0.25)
	var changed := false
	for key in _tiles_within_radius(t, cursor_local, radius):
		if _wmt_drag_touched.has(key):
			continue
		# Mark it even when the chunk is missing: a tile that cannot toggle now
		# must not be re-evaluated every frame the brush rests on it.
		_wmt_drag_touched[key] = true
		var ck: Vector2i = t._chunk_of(key.x * t.SQUARES_PER_TILE,
			key.y * t.SQUARES_PER_TILE)
		if not t.has_chunk(ck.x, ck.y):
			continue
		if _wmt_drag_snap == null:
			# One snapshot for the whole stroke, so undo takes back the entire
			# sweep in a single step.
			_wmt_drag_snap = _capture_state(t)
		var cell: Vector2i = key * int(t.SQUARES_PER_TILE)
		t.set_tile_hidden(cell.x, cell.y, not t.is_tile_hidden(cell.x, cell.y))
		_wmt_drag_chunks[ck] = true
		_wmt_drag_dirty = true
		changed = true
	if changed:
		# Live: the hide ring follows the stroke instead of snapping in on
		# release.
		_rebuild_overlay_layers()
		_apply_terrain_overlays()

func _end_wmt_drag() -> void:
	if _wmt_drag_dirty and _wmt_drag_snap != null and is_instance_valid(terrain):
		undo_stack.append(_wmt_drag_snap)
		if undo_stack.size() > UNDO_LIMIT:
			undo_stack.pop_front()
		redo_stack.clear()
		var touched: Array = _wmt_drag_chunks.keys()
		_save_terrain(terrain, touched)
	_wmt_drag_touched.clear()
	_wmt_drag_chunks.clear()
	_wmt_drag_snap = null
	_wmt_drag_dirty = false

# Toggle a single tile's membership in the paint selection.
func _toggle_tile_selection(tk: Vector2i) -> void:
	if _paint_selected.has(tk):
		_paint_selected.erase(tk)
	else:
		_paint_selected[tk] = true

# All in-grid tile keys whose bounds the circle at `center` touches, using the
# same circle-vs-tile geometry as the paint stamp (see _stamp_paint).
func _tiles_within_radius(t: WmtScript, center: Vector3, radius: float) -> Array:
	var out: Array = []
	var edge := float(t.TILE_EDGE)
	var tgx0 := floori((center.x - radius) / edge)
	var tgx1 := floori((center.x + radius) / edge)
	var tgz0 := floori((center.z - radius) / edge)
	var tgz1 := floori((center.z + radius) / edge)
	var r2 := radius * radius
	for tgz in range(tgz0, tgz1 + 1):
		for tgx in range(tgx0, tgx1 + 1):
			if tgx < 0 or tgz < 0 or tgx >= t.tile_count_x() or tgz >= t.tile_count_z():
				continue
			var bx := tgx * edge
			var bz := tgz * edge
			var nx := clampf(center.x, bx, bx + edge)
			var nz := clampf(center.z, bz, bz + edge)
			var dx := center.x - nx
			var dz := center.z - nz
			if dx * dx + dz * dz <= r2:
				out.append(Vector2i(tgx, tgz))
	return out

# Alt+RMB: flip the whole chunk under the cursor - if any of its tiles are
# selected, clear every tile in the chunk; otherwise select all of them.
func _toggle_select_chunk_under_cursor() -> void:
	var t := terrain if is_instance_valid(terrain) else null
	if t == null or not is_instance_valid(t):
		return
	var ck := _chunk_under_mouse()
	if ck == null:
		return
	if not t.has_chunk(ck.x, ck.y):
		return
	var per_side := int(round(float(t.CHUNK_WIDTH) / float(t.TILE_EDGE)))
	var tiles: Array = []
	var any_selected := false
	for tgz in range(ck.y * per_side, ck.y * per_side + per_side):
		for tgx in range(ck.x * per_side, ck.x * per_side + per_side):
			var key := Vector2i(tgx, tgz)
			if tgx < 0 or tgz < 0 or tgx >= t.tile_count_x() or tgz >= t.tile_count_z():
				continue
			var tck: Vector2i = t._chunk_of(tgx * t.SQUARES_PER_TILE, tgz * t.SQUARES_PER_TILE)
			if not t.has_chunk(tck.x, tck.y):
				continue
			tiles.append(key)
			if _paint_selected.has(key):
				any_selected = true
	if tiles.is_empty():
		return
	for key in tiles:
		if any_selected:
			_paint_selected.erase(key)
		else:
			_paint_selected[key] = true
	_side_sel_dirty = true
	_apply_terrain_overlays()

# Rebuild the per-channel Texture2DArrays + nearest layout atlases whenever the
# tile->texture mapping changed (assignment, first paint on a fresh tile, undo,
# terrain reload). The layouts mirror the paint atlas tile-block lattice so the
# shader indexes them with the same puv; byte = array layer (1-based, 0 = none).
func _ensure_texture_atlas() -> void:
	if not _paint_texture_atlas_dirty:
		return
	_paint_texture_atlas_dirty = false
	var t := terrain if is_instance_valid(terrain) else null
	if t == null or t.tile_paints.is_empty():
		_chan_arrays = []
		_chan_layouts = []
		_atlas_paths_key = ""
		return
	var tx := t.tile_count_x()
	var tz := t.tile_count_z()
	if tx <= 0 or tz <= 0:
		return
	# Distinct textures per slot across all painted tiles -> layer index.
	var layer_lists: Array = []
	var path_lists: Array = []
	for c in range(WmtScript.PAINT_CHANNELS):
		layer_lists.append({})
		path_lists.append([])
	for key in t.tile_paints:
		for c in range(WmtScript.PAINT_CHANNELS):
			var path := _resolved_tile_tex(t, key as Vector2i, c)
			if path == "" or (layer_lists[c] as Dictionary).has(path):
				continue
			(layer_lists[c] as Dictionary)[path] = (path_lists[c] as Array).size() + 1
			(path_lists[c] as Array).append(path)
	var fallbacks: Array = []
	for c in range(WmtScript.PAINT_CHANNELS):
		fallbacks.append((path_lists[c] as Array)[0] if not (path_lists[c] as Array).is_empty() else "")
	var ox := t.tile_origin_x()
	var oz := t.tile_origin_z()
	var w := tx * WmtScript.PAINT_TILE_PX
	var h := tz * WmtScript.PAINT_TILE_PX
	if _chan_layout_imgs.size() < WmtScript.PAINT_CHANNELS:
		_chan_layout_imgs.resize(WmtScript.PAINT_CHANNELS)
	if _chan_layouts.size() < WmtScript.PAINT_CHANNELS:
		_chan_layouts.resize(WmtScript.PAINT_CHANNELS)
	for c in range(WmtScript.PAINT_CHANNELS):
		var img: Image = _chan_layout_imgs[c]
		if img == null or img.get_width() != w or img.get_height() != h:
			img = Image.create(w, h, false, Image.FORMAT_RGBA8)
			_chan_layout_imgs[c] = img
		else:
			img.fill(Color(0.0, 0.0, 0.0, 1.0))
		for key in t.tile_paints:
			var k: Vector2i = key
			var path := _fill_fallback_tile_tex(t, k, c, fallbacks)
			if path == "":
				continue
			# Per-tile tiling ONLY. Tiles without an override get the built-in
			# default (16) - never the toolbox value, so editing one channel's
			# size can only ever affect the tiles it was pinned to.
			# Depth is baked only when the tile pins one; unpinned channels use
			# the global paint depth (the shader's B=0 sentinel), so changing
			# the global Depth never needs an atlas rebuild.
			var til := t.tile_tiling(k.x, k.y, c)
			if til < 1.0:
				til = 16.0
			var dep := t.tile_depth(k.x, k.y, c)
			_put_layout_block(img, k, ox, oz, int((layer_lists[c] as Dictionary)[path]), til, dep)
		var itex: ImageTexture = _chan_layouts[c]
		if itex == null or not is_instance_valid(itex) \
				or itex.get_width() != w or itex.get_height() != h:
			_chan_layouts[c] = ImageTexture.create_from_image(img)
		else:
			itex.update(img)
	var key_parts: Array = []
	for c in range(WmtScript.PAINT_CHANNELS):
		key_parts.append(",".join(path_lists[c]))
	var new_key := "|".join(key_parts)
	if new_key != _atlas_paths_key or _chan_arrays.size() < WmtScript.PAINT_CHANNELS:
		var arrs: Array = []
		for c in range(WmtScript.PAINT_CHANNELS):
			arrs.append(_build_layer_array(path_lists[c]))
		_chan_arrays = arrs
		_atlas_paths_key = new_key

func _put_layout_block(img: Image, key: Vector2i, ox: int, oz: int, layer: int, til: float, depth: float) -> void:
	var px := (key.x - ox) * WmtScript.PAINT_TILE_PX
	var py := (key.y - oz) * WmtScript.PAINT_TILE_PX
	if px < 0 or py < 0 or px + WmtScript.PAINT_TILE_PX > img.get_width() \
			or py + WmtScript.PAINT_TILE_PX > img.get_height():
		return
	# R = array layer byte (1-based, 0 = none), G = tiling byte
	# (round(repeat) - 1, so 1..256 -> 0..255), B = per-tile masked-depth byte
	# (round(depth * 255), 0 = no pin -> the global paint depth). Native fill
	# (one call per tile block) instead of 4096 GDScript set_pixel calls.
	var til_byte := clampi(int(roundf(til)) - 1, 0, 255)
	var dep_byte := 0
	if depth > 0.0:
		dep_byte = clampi(int(roundf(clampf(depth, 0.01, 1.0) * 255.0)), 1, 255)
	img.fill_rect(Rect2i(px, py, WmtScript.PAINT_TILE_PX, WmtScript.PAINT_TILE_PX),
		Color(float(layer) / 255.0, float(til_byte) / 255.0, float(dep_byte) / 255.0, 1.0))

# Pack one distinct texture into an array layer (resized to TEX_LAYER_PX), with
# its "_s" mask alpha baked into the alpha channel so the shader samples both
# from a single array fetch. Falls back to a neutral placeholder layer (the
# shader never samples it: layout 0 gates the weight to zero).
func _build_layer_array(paths: Array) -> Texture2DArray:
	var images: Array = []
	for path in paths:
		var tex := _channel_tex(String(path))
		if tex == null:
			continue
		images.append(_pack_layer_image(String(path), tex))
	if images.is_empty():
		images.append(_placeholder_layer())
	var arr := Texture2DArray.new()
	arr.create_from_images(images)
	return arr

func _pack_layer_image(path: String, tex: Texture2D) -> Image:
	var src: Image = tex.get_image()
	var img: Image
	if src.is_empty():
		img = _placeholder_layer()
	else:
		if src.get_width() != TEX_LAYER_PX or src.get_height() != TEX_LAYER_PX:
			src.resize(TEX_LAYER_PX, TEX_LAYER_PX, Image.INTERPOLATE_LANCZOS)
		if src.get_format() != Image.FORMAT_RGBA8:
			src.convert(Image.FORMAT_RGBA8)
		# Copy: the texture's own image must not be mutated in place.
		img = src.duplicate()
	var mask := _channel_mask(path)
	if mask != null:
		var msrc: Image = mask.get_image()
		if not msrc.is_empty():
			if msrc.get_width() != TEX_LAYER_PX or msrc.get_height() != TEX_LAYER_PX:
				msrc.resize(TEX_LAYER_PX, TEX_LAYER_PX, Image.INTERPOLATE_LANCZOS)
			if msrc.get_format() != Image.FORMAT_RGBA8:
				msrc.convert(Image.FORMAT_RGBA8)
			# Replace the alpha byte directly in the raw buffer instead of
			# 262144 get_pixel/set_pixel pairs per layer (the old freeze).
			var dst_bytes := img.get_data()
			var src_bytes := msrc.get_data()
			var count := mini(dst_bytes.size(), src_bytes.size())
			var i := 3
			while i < count:
				dst_bytes[i] = src_bytes[i]
				i += 4
			img = Image.create_from_data(TEX_LAYER_PX, TEX_LAYER_PX, false,
				Image.FORMAT_RGBA8, dst_bytes)
	return img

func _placeholder_layer() -> Image:
	var img := Image.create(TEX_LAYER_PX, TEX_LAYER_PX, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.5, 0.5, 0.5, 1.0))
	return img

# The terrain keeps the overlay shader as its material_override at all times
# (paint needs it present even when every line layer is off). Both the fill
# color and the overlay lines live in that one shader, so toggling never
# rebuilds the mesh.
# Live shading refresh: called every sculpt / set-height frame so the height
# atlas tracks the in-place vertex patch instead of snapping at stroke end.
# Cheap when heights are unchanged (the texture cache short-circuits), and the
# same ShaderMaterial instance is reused so the rasterizer picks the new
# texture up immediately. grid_rect is the brush's corner-cell footprint in
# grid coordinates; only those atlas pixels are repainted.
# Live sculpt follow-up: after a stroke patches vertices in place, grow the
# terrain's culling box so the freshly sculpted heights stay inside it (a box
# that lags behind would let the frustum cull the mesh mid-stroke - the reason
# the old oversized-box hack existed). grid_rect is the brush's corner-cell
# footprint in grid coordinates.
func _refresh_overlay_height(grid_rect := Rect2i()) -> void:
	var t := terrain if is_instance_valid(terrain) else null
	if t == null:
		return
	var local := grid_rect
	if local.size.x > 0:
		local.position -= Vector2i(t.cell_x0, t.cell_z0)
	t.refresh_cover_aabb(local)

func _apply_terrain_overlays() -> void:
	if not is_instance_valid(terrain):
		return
	# The overlay shader is ALWAYS the terrain's material now: paint needs it
	# to be present even when every line layer is off, so the flat fallback was
	# removed (the fill color still comes from the shader's base_color).
	terrain.material_override = _ensure_overlay_mat()
	_sync_toolbar_states()

# Floating-toolbar toggles must mirror whatever changed the overlay state.
func _sync_toolbar_states() -> void:
	if toolbar != null and is_instance_valid(toolbar):
		toolbar.set_states(wireframe_on, wmt_lines_on or chunk_lines_on, shading_on,
			vertex_colors_on)
	if panel != null and is_instance_valid(panel) and panel.has_method("set_grid_state"):
		panel.set_grid_state(wmt_lines_on or chunk_lines_on)

func _clear_wireframe_overlay() -> void:
	# Drop our reference so the next apply builds a fresh material for the new
	# selection. The previous terrain keeps the overlay instance it already
	# holds, so its painted/shaded look survives deselection.
	_wireframe_mat = null
	# The per-channel texture arrays are built for the selected terrain; reset
	# so a different node rebuilds its own mapping.
	_chan_arrays = []
	_chan_layouts = []
	_atlas_paths_key = ""
	_paint_texture_atlas_dirty = true
	_last_painted_tile = Vector2i(-1, -1)

# Overlay options are remembered per project and restored on the next editor
# launch (see _load_settings at plugin load).
const WMT_PREFS := "wmt"
const PREFS_WF_ON := "wireframe_on"
const PREFS_WF_BLACK := "wireframe_black"
const PREFS_WF_THICKNESS := "wireframe_thickness"
const PREFS_WMT_LINES := "wmt_lines"
const PREFS_CHUNK_LINES := "chunk_lines"
# Freshly-named pref so every project starts with the directional light ON (the
# terrain is always lit by real Godot lights; the toolbar toggle reveals/hides
# the scene's sun and persists that choice under this key).
const PREFS_SHADING := "shading_smooth"
const PREFS_VERTEX_COLORS := "vertex_colors"
# Properties persisted for the scene's directional light (used so an
# auto-created "WMT Sun" picks up your last settings).
const PREFS_SUN_COLOR := "sun_color"
const PREFS_SUN_ENERGY := "sun_energy"
const PREFS_SUN_SHADOW_DISTANCE := "sun_shadow_distance"
const PREFS_SUN_SHADOW_RESOLUTION := "sun_shadow_resolution"
const PREFS_TILE_LINE_THICKNESS := "tile_line_thickness"
const PREFS_SUN_SHADOW := "sun_shadow"
const PREFS_ENV_AMBIENT_COLOR := "env_ambient_color"
const PREFS_ENV_AMBIENT_ENERGY := "env_ambient_energy"
const PREFS_ENV_SKY_ENERGY := "env_sky_energy"
const PREFS_BRUSH_COLOR := "brush_color"
const PREFS_BRUSH_THICKNESS := "brush_thickness"
const PREFS_BRUSH_RADIUS := "brush_radius"
const PREFS_FALLOFF := "brush_falloff"
const PREFS_STRENGTH := "brush_strength"
const PREFS_PAINT_CHANNEL := "paint_channel"
const PREFS_PAINT_CHANNEL_TEXTURES := "paint_channel_textures"
const PREFS_PAINT_CHANNEL_TILINGS := "paint_channel_tilings"
const PREFS_PAINT_DEPTH := "paint_depth"
const PREFS_PAINT_OPACITY := "paint_opacity"
const PREFS_PAINT_FLOW := "paint_flow"
const PREFS_PAINT_SPACING := "paint_spacing"
const PREFS_PAINT_SPRAY := "paint_spray"
const PREFS_PAINT_SPRAY_INTERVAL := "paint_spray_interval"
const PREFS_VERTEX_COLOR := "vertex_color"
const PREFS_VERTEX_STRENGTH := "vertex_strength"
const PREFS_VERTEX_OPACITY := "vertex_opacity"
const PREFS_VERTEX_FLOW := "vertex_flow"
const PREFS_VERTEX_SPACING := "vertex_spacing"
const PREFS_VERTEX_SPRAY := "vertex_spray"
const PREFS_VERTEX_SPRAY_INTERVAL := "vertex_spray_interval"
const PREFS_TEX_SEARCH := "texture_search_last"
const PREFS_TEX_PREVIEW := "texture_preview_pct"

func _load_settings() -> void:
	var es := EditorInterface.get_editor_settings()
	wireframe_on = es.get_project_metadata(WMT_PREFS, PREFS_WF_ON, false)
	wireframe_black = es.get_project_metadata(WMT_PREFS, PREFS_WF_BLACK, false)
	wireframe_thickness = es.get_project_metadata(WMT_PREFS, PREFS_WF_THICKNESS, 1.0)
	wmt_lines_on = es.get_project_metadata(WMT_PREFS, PREFS_WMT_LINES, false)
	chunk_lines_on = es.get_project_metadata(WMT_PREFS, PREFS_CHUNK_LINES, false)
	shading_on = es.get_project_metadata(WMT_PREFS, PREFS_SHADING, true)
	vertex_colors_on = es.get_project_metadata(WMT_PREFS, PREFS_VERTEX_COLORS, true)
	sun_color = es.get_project_metadata(WMT_PREFS, PREFS_SUN_COLOR, Color.WHITE)
	sun_energy = clampf(es.get_project_metadata(WMT_PREFS, PREFS_SUN_ENERGY, 1.5), 0.0, 5.0)
	sun_shadow_distance = maxf(float(es.get_project_metadata(WMT_PREFS,
		PREFS_SUN_SHADOW_DISTANCE, 100.0)), 0.0)
	sun_shadow_resolution = clampi(int(es.get_project_metadata(WMT_PREFS,
		PREFS_SUN_SHADOW_RESOLUTION, 2)), 0, 3)
	tile_line_thickness = clampf(float(es.get_project_metadata(WMT_PREFS,
		PREFS_TILE_LINE_THICKNESS, 1.0)), 0.0, 6.0)
	sun_shadow = es.get_project_metadata(WMT_PREFS, PREFS_SUN_SHADOW, false)
	env_ambient_color = es.get_project_metadata(WMT_PREFS, PREFS_ENV_AMBIENT_COLOR,
		Color(0.42, 0.47, 0.55))
	env_ambient_energy = clampf(float(es.get_project_metadata(WMT_PREFS,
		PREFS_ENV_AMBIENT_ENERGY, 1.0)), 0.0, 5.0)
	env_sky_energy = clampf(float(es.get_project_metadata(WMT_PREFS,
		PREFS_ENV_SKY_ENERGY, 0.5)), 0.0, 1.0)
	brush_color = es.get_project_metadata(WMT_PREFS, PREFS_BRUSH_COLOR, Color(1.0, 0.3, 0.25))
	brush_thickness = es.get_project_metadata(WMT_PREFS, PREFS_BRUSH_THICKNESS, 0.2)
	cursor_radius = clampf(es.get_project_metadata(WMT_PREFS, PREFS_BRUSH_RADIUS, 2.0), CURSOR_RADIUS_MIN, CURSOR_RADIUS_MAX)
	falloff_ratio = clampf(es.get_project_metadata(WMT_PREFS, PREFS_FALLOFF, 0.5), 0.0, 1.0)
	sculpt_strength = clampf(es.get_project_metadata(WMT_PREFS, PREFS_STRENGTH, 1.0), 0.05, 12.0)
	paint_channel = es.get_project_metadata(WMT_PREFS, PREFS_PAINT_CHANNEL, 0)
	var ptex: Array = es.get_project_metadata(WMT_PREFS, PREFS_PAINT_CHANNEL_TEXTURES, [])
	paint_channel_textures = ["", "", "", ""]
	if ptex is Array:
		for i in range(mini(ptex.size(), WmtScript.PAINT_CHANNELS)):
			paint_channel_textures[i] = str(ptex[i])
	var tils: Array = es.get_project_metadata(WMT_PREFS, PREFS_PAINT_CHANNEL_TILINGS, [])
	paint_channel_tilings = [16.0, 16.0, 16.0, 16.0]
	if tils is Array:
		for i in range(mini(tils.size(), WmtScript.PAINT_CHANNELS)):
			paint_channel_tilings[i] = clampf(float(tils[i]), 1.0, 256.0)
	paint_depth = clampf(
		es.get_project_metadata(WMT_PREFS, PREFS_PAINT_DEPTH, 0.2), 0.01, 1.0)
	paint_opacity = es.get_project_metadata(WMT_PREFS, PREFS_PAINT_OPACITY, 1.0)
	paint_flow = es.get_project_metadata(WMT_PREFS, PREFS_PAINT_FLOW, 1.0)
	paint_spacing = es.get_project_metadata(WMT_PREFS, PREFS_PAINT_SPACING, 8.0)
	paint_spray_on = es.get_project_metadata(WMT_PREFS, PREFS_PAINT_SPRAY, true)
	paint_spray_interval = clampf(es.get_project_metadata(WMT_PREFS, PREFS_PAINT_SPRAY_INTERVAL, 0.05), 0.01, 1.0)
	vertex_color = es.get_project_metadata(WMT_PREFS, PREFS_VERTEX_COLOR, Color.WHITE)
	vertex_strength = clampf(es.get_project_metadata(WMT_PREFS, PREFS_VERTEX_STRENGTH, 0.2), 0.0, 1.0)
	vertex_opacity = clampf(es.get_project_metadata(WMT_PREFS, PREFS_VERTEX_OPACITY, 1.0), 0.0, 1.0)
	vertex_flow = clampf(es.get_project_metadata(WMT_PREFS, PREFS_VERTEX_FLOW, 1.0), 0.0, 1.0)
	vertex_spacing = clampf(es.get_project_metadata(WMT_PREFS, PREFS_VERTEX_SPACING, 4.0), 0.5, 64.0)
	vertex_spray_on = es.get_project_metadata(WMT_PREFS, PREFS_VERTEX_SPRAY, true)
	vertex_spray_interval = clampf(es.get_project_metadata(WMT_PREFS,
		PREFS_VERTEX_SPRAY_INTERVAL, 0.05), 0.01, 1.0)
	_last_texture_search = str(es.get_project_metadata(WMT_PREFS, PREFS_TEX_SEARCH, ""))
	_texture_preview_pct = clampf(float(es.get_project_metadata(WMT_PREFS, PREFS_TEX_PREVIEW, 100.0)), 50.0, 300.0)

func _save_overlay_prefs() -> void:
	var es := EditorInterface.get_editor_settings()
	es.set_project_metadata(WMT_PREFS, PREFS_WF_ON, wireframe_on)
	es.set_project_metadata(WMT_PREFS, PREFS_WF_BLACK, wireframe_black)
	es.set_project_metadata(WMT_PREFS, PREFS_WF_THICKNESS, float(wireframe_thickness))
	es.set_project_metadata(WMT_PREFS, PREFS_WMT_LINES, wmt_lines_on)
	es.set_project_metadata(WMT_PREFS, PREFS_CHUNK_LINES, chunk_lines_on)
	es.set_project_metadata(WMT_PREFS, PREFS_SHADING, shading_on)
	es.set_project_metadata(WMT_PREFS, PREFS_VERTEX_COLORS, vertex_colors_on)
	es.set_project_metadata(WMT_PREFS, PREFS_SUN_COLOR, sun_color)
	es.set_project_metadata(WMT_PREFS, PREFS_SUN_ENERGY, float(sun_energy))
	es.set_project_metadata(WMT_PREFS, PREFS_SUN_SHADOW_DISTANCE,
		float(sun_shadow_distance))
	es.set_project_metadata(WMT_PREFS, PREFS_SUN_SHADOW_RESOLUTION,
		int(sun_shadow_resolution))
	es.set_project_metadata(WMT_PREFS, PREFS_TILE_LINE_THICKNESS,
		float(tile_line_thickness))
	es.set_project_metadata(WMT_PREFS, PREFS_SUN_SHADOW, sun_shadow)
	es.set_project_metadata(WMT_PREFS, PREFS_ENV_AMBIENT_COLOR, env_ambient_color)
	es.set_project_metadata(WMT_PREFS, PREFS_ENV_AMBIENT_ENERGY, float(env_ambient_energy))
	es.set_project_metadata(WMT_PREFS, PREFS_ENV_SKY_ENERGY, float(env_sky_energy))
	es.set_project_metadata(WMT_PREFS, PREFS_BRUSH_COLOR, brush_color)
	es.set_project_metadata(WMT_PREFS, PREFS_BRUSH_THICKNESS, float(brush_thickness))
	es.set_project_metadata(WMT_PREFS, PREFS_BRUSH_RADIUS, float(cursor_radius))
	es.set_project_metadata(WMT_PREFS, PREFS_FALLOFF, float(falloff_ratio))
	es.set_project_metadata(WMT_PREFS, PREFS_STRENGTH, float(sculpt_strength))
	es.set_project_metadata(WMT_PREFS, PREFS_PAINT_CHANNEL, paint_channel)
	es.set_project_metadata(WMT_PREFS, PREFS_PAINT_CHANNEL_TEXTURES, paint_channel_textures)
	es.set_project_metadata(WMT_PREFS, PREFS_PAINT_CHANNEL_TILINGS, paint_channel_tilings)
	es.set_project_metadata(WMT_PREFS, PREFS_PAINT_DEPTH, float(paint_depth))
	es.set_project_metadata(WMT_PREFS, PREFS_PAINT_OPACITY, float(paint_opacity))
	es.set_project_metadata(WMT_PREFS, PREFS_PAINT_FLOW, float(paint_flow))
	es.set_project_metadata(WMT_PREFS, PREFS_PAINT_SPACING, float(paint_spacing))
	es.set_project_metadata(WMT_PREFS, PREFS_PAINT_SPRAY, paint_spray_on)
	es.set_project_metadata(WMT_PREFS, PREFS_PAINT_SPRAY_INTERVAL, float(paint_spray_interval))
	es.set_project_metadata(WMT_PREFS, PREFS_VERTEX_COLOR, vertex_color)
	es.set_project_metadata(WMT_PREFS, PREFS_VERTEX_STRENGTH, float(vertex_strength))
	es.set_project_metadata(WMT_PREFS, PREFS_VERTEX_OPACITY, float(vertex_opacity))
	es.set_project_metadata(WMT_PREFS, PREFS_VERTEX_FLOW, float(vertex_flow))
	es.set_project_metadata(WMT_PREFS, PREFS_VERTEX_SPACING, float(vertex_spacing))
	es.set_project_metadata(WMT_PREFS, PREFS_VERTEX_SPRAY, vertex_spray_on)
	es.set_project_metadata(WMT_PREFS, PREFS_VERTEX_SPRAY_INTERVAL,
		float(vertex_spray_interval))
	es.set_project_metadata(WMT_PREFS, PREFS_TEX_SEARCH, _last_texture_search)
	es.set_project_metadata(WMT_PREFS, PREFS_TEX_PREVIEW, float(_texture_preview_pct))

func _on_wireframe_toggled(on: bool) -> void:
	wireframe_on = on
	if panel != null and panel.wireframe_button != null:
		panel.wireframe_button.button_pressed = on
	_save_overlay_prefs()
	_apply_terrain_overlays()

func _on_wireframe_color_changed(black: bool) -> void:
	wireframe_black = black
	_save_overlay_prefs()
	_apply_terrain_overlays()

func _on_wireframe_thickness_changed(width: float) -> void:
	wireframe_thickness = width
	_save_overlay_prefs()
	_apply_terrain_overlays()

func _on_tile_line_thickness_changed(width: float) -> void:
	tile_line_thickness = clampf(width, 0.0, 6.0)
	_save_overlay_prefs()
	_apply_terrain_overlays()

func _on_brush_color_changed(color: Color) -> void:
	brush_color = color
	_save_overlay_prefs()
	_apply_brush_style()

# Vertex painting uses its OWN color (independent of the brush cursor ring).
# Both choices persist so a reboot doesn't reset the stroke to an invisible
# white erase.
func _on_vertex_color_changed(color: Color) -> void:
	# Only the NEXT strokes take this color: the picked color is written into
	# the tint texture per texel, so changing it here does not repaint anything
	# that is already on the terrain.
	vertex_color = color
	_save_overlay_prefs()

func _on_vertex_strength_changed(value: float) -> void:
	vertex_strength = clampf(value, 0.0, 1.0)
	_save_overlay_prefs()

func _on_vertex_opacity_changed(value: float) -> void:
	vertex_opacity = clampf(value, 0.0, 1.0)
	_save_overlay_prefs()

func _on_vertex_flow_changed(value: float) -> void:
	vertex_flow = clampf(value, 0.0, 1.0)
	_save_overlay_prefs()

func _on_vertex_spacing_changed(value: float) -> void:
	vertex_spacing = clampf(value, 0.5, 64.0)
	_save_overlay_prefs()

func _on_vertex_spray_toggled(on: bool) -> void:
	vertex_spray_on = on
	_save_overlay_prefs()

func _on_vertex_spray_interval_changed(value: float) -> void:
	vertex_spray_interval = clampf(value, 0.01, 1.0)
	_save_overlay_prefs()

func _on_brush_thickness_changed(width: float) -> void:
	brush_thickness = width
	_save_overlay_prefs()
	_apply_brush_style()

func _on_paint_opacity_changed(value: float) -> void:
	paint_opacity = clampf(value, 0.0, 1.0)
	_save_overlay_prefs()

func _on_paint_flow_changed(value: float) -> void:
	paint_flow = clampf(value, 0.0, 1.0)
	_save_overlay_prefs()

func _on_paint_spacing_changed(value: float) -> void:
	paint_spacing = clampf(value, 0.5, 64.0)
	_save_overlay_prefs()

func _on_paint_spray_toggled(on: bool) -> void:
	paint_spray_on = on
	if panel != null and panel.has_method("set_spray_state"):
		panel.set_spray_state(on)
	_save_overlay_prefs()

func _on_paint_spray_interval_changed(value: float) -> void:
	paint_spray_interval = clampf(value, 0.01, 1.0)
	_save_overlay_prefs()

func _on_radius_changed(value: float) -> void:
	cursor_radius = clampf(value, CURSOR_RADIUS_MIN, CURSOR_RADIUS_MAX)
	_drape_ring()
	_save_overlay_prefs()

func _on_strength_changed(value: float) -> void:
	sculpt_strength = clampf(value, 0.05, 12.0)
	_save_overlay_prefs()

func _on_falloff_changed(value: float) -> void:
	falloff_ratio = clampf(value, 0.0, 1.0)
	if panel != null and panel.has_method("update_falloff_label"):
		panel.update_falloff_label(falloff_ratio)
	_drape_ring()
	_save_overlay_prefs()

func _on_sculpt_tool_changed(tool: int) -> void:
	if tool == SCULPT_TOOL_SET_HEIGHT:
		sculpt_tool = SCULPT_TOOL_SET_HEIGHT
	elif tool == SCULPT_TOOL_SMOOTH:
		sculpt_tool = SCULPT_TOOL_SMOOTH
	else:
		sculpt_tool = SCULPT_TOOL_SCULPT
	if panel != null and panel.has_method("set_sculpt_tool"):
		panel.set_sculpt_tool(sculpt_tool)
	_refresh_brush_visibility()
	_drape_ring()

func _on_smooth_tool_changed(tool: int) -> void:
	if tool >= SMOOTH_TOOL_RAISE and tool <= SMOOTH_TOOL_LOWER:
		smooth_tool = tool
	if panel != null and panel.has_method("set_smooth_tool"):
		panel.set_smooth_tool(smooth_tool)

func _on_paint_channel_selected(index: int) -> void:
	if index < 0 or index >= WmtScript.PAINT_CHANNELS:
		return
	paint_channel = index
	if panel != null and panel.has_method("set_paint_channel"):
		panel.set_paint_channel(paint_channel)
	_refresh_paint_popup_sel()
	_save_overlay_prefs()
	# The selected slot's texture is the brush: tiles that can't take it show
	# red immediately, and clear red the moment a paintable one is picked.
	_side_nopaint_dirty = true
	_apply_terrain_overlays()
	var tex := paint_channel_textures[index] if index < paint_channel_textures.size() else ""
	var what := tex.get_file() if tex != "" else "no texture"
	print("[WMT] paint channel: %s \u2014 %s" % [PAINT_CHANNEL_NAMES[index], what])

func _on_paint_depth_changed(x: float) -> void:
	paint_depth = clampf(x, 0.01, 1.0)
	_save_overlay_prefs()
	_apply_terrain_overlays()

# The merged toolbar toggle drives colored tile-lattice and chunk-lattice lines
# together; both stay in sync so prefs and the shader flags never diverge.
func _on_grid_toggled(on: bool) -> void:
	wmt_lines_on = on
	chunk_lines_on = on
	if panel != null and panel.has_method("set_grid_state"):
		panel.set_grid_state(on)
	_save_overlay_prefs()
	_apply_terrain_overlays()

func _on_vertex_toggled(on: bool) -> void:
	vertex_colors_on = on
	_save_overlay_prefs()
	_apply_terrain_overlays()

# The toolbar "shading" toggle drives the scene's directional light node: ON
# reveals it (lighting the terrain with real Godot shading), OFF hides it.
func _on_shading_toggled(on: bool) -> void:
	shading_on = on
	_save_overlay_prefs()
	_sync_sun_visibility()
	_apply_scene_lighting()

# The toolbar's light button is really a LIGHTING toggle, not just a sun
# visibility switch: with the light off the whole scene is shown flat. Hiding
# the sun alone would leave the terrain unlit (near black) while everything else
# stayed shaded, so "off" now renders the viewport unshaded, which is what the
# editor's own unshaded debug draw is for.
func _apply_scene_lighting() -> void:
	# Deferred at boot; skip if the plugin is on its way out.
	if _exiting or not is_inside_tree():
		return
	var vp := EditorInterface.get_editor_viewport_3d()
	if vp == null:
		return
	vp.debug_draw = Viewport.DEBUG_DRAW_DISABLED if shading_on \
		else Viewport.DEBUG_DRAW_UNSHADED

# Find the scene's directional light to drive (the first DirectionalLight3D in
# the edited scene). If there is none, create "WMT Sun" off the scene root and
# give it the persisted position/properties below.
func _sun_light() -> DirectionalLight3D:
	var root := EditorInterface.get_edited_scene_root()
	var sun: DirectionalLight3D = null
	if root != null:
		for n in root.find_children("*", "DirectionalLight3D", true, false):
			if n is DirectionalLight3D:
				sun = n
				break
	if sun == null:
		sun = DirectionalLight3D.new()
		sun.name = "WMT Sun"
		if root != null:
			root.add_child(sun)
			sun.owner = root
	# A high sun plus stable, fade-free, well-biased shadows (see _configure_sun).
	_configure_sun(sun)
	sun.light_color = sun_color
	sun.light_energy = sun_energy
	sun.shadow_enabled = sun_shadow
	_apply_sun_shadow_extras(sun)
	return sun

# Make the scene's directional light match the toolbar visibility only if it
# already exists (never auto-create from here - toggling/panel edits do).
func _sync_sun_visibility() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	for n in root.find_children("*", "DirectionalLight3D", true, false):
		if n is DirectionalLight3D:
			var sun := n as DirectionalLight3D
			sun.visible = shading_on
			# Re-apply the stable shadow/angle config plus the persisted sun
			# values so the terrain stops shimmering as the camera moves
			# (idempotent, no auto-create).
			_configure_sun(sun)
			sun.light_color = sun_color
			sun.light_energy = sun_energy
			sun.shadow_enabled = sun_shadow
			_apply_sun_shadow_extras(sun)
			return

# Shared sun configuration applied to whichever DirectionalLight3D the plugin
# drives. A high sun angle plus a fade-free, well-biased shadow map keeps the
# terrain's lighting and shadows stable while orbiting the camera.
func _configure_sun(sun: DirectionalLight3D) -> void:
	if sun == null:
		return
	# A directional light points along -Z, so a rotation.x near -60 aims it down
	# from high up (a near-horizon sun flips brightness as the camera orbits).
	sun.rotation_degrees = Vector3(-60.0, 35.0, 0.0)
	# directional_shadow_max_distance deliberately NOT set here: this function
	# and _apply_sun_shadow_extras() both used to write it (0.0 here, the panel
	# value there), so the result depended on call order and a code path that
	# only ran this one left the light with unlimited shadow range.
	sun.directional_shadow_fade_start = 1.0
	sun.shadow_blur = 1.4
	sun.shadow_normal_bias = 1.4
	sun.shadow_bias = 0.04

# Find the scene's WorldEnvironment to drive (the first WorldEnvironment in
# the edited scene). If there is none, create "WMT Environment" off the scene
# root and give it the persisted ambient values.
func _world_environment() -> WorldEnvironment:
	var root := EditorInterface.get_edited_scene_root()
	var we: WorldEnvironment = null
	if root != null:
		for n in root.find_children("*", "WorldEnvironment", true, false):
			if n is WorldEnvironment:
				we = n
				break
	if we == null:
		we = WorldEnvironment.new()
		we.name = "WMT Environment"
		if root != null:
			root.add_child(we)
			we.owner = root
	_apply_env_state(we)
	return we

# The light a sky would pour onto the terrain: its top and horizon colors
# averaged. Reads whatever Sky the environment already has, so a hand-authored
# sky in the project drives the fill too.
func _sky_ambient_color(env: Environment) -> Color:
	var mat: Material = null
	if env != null and env.sky != null:
		mat = env.sky.sky_material
	if mat is ProceduralSkyMaterial:
		var psm := mat as ProceduralSkyMaterial
		return (psm.sky_top_color + psm.sky_horizon_color) * 0.5
	if mat is PanoramaSkyMaterial:
		return Color(0.5, 0.5, 0.5)
	# No usable sky: fall back to a neutral daylight so the slider still does
	# something visible instead of going dark.
	return Color(0.5, 0.5, 0.5)

# Apply the current environment settings to an existing WorldEnvironment node.
func _apply_env_state(we: WorldEnvironment) -> void:
	if we == null:
		return
	var env := we.environment
	if env == null:
		env = Environment.new()
		we.environment = env
	# The ambient SOURCE has to be the color for the color box to mean
	# anything: with the default source (background) the ambient light is
	# derived from background_mode/background_color and ambient_light_color is
	# ignored entirely - which is exactly why the ambient + skylight controls
	# did nothing.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_energy = env_ambient_energy
	# The sky has to exist before its colors can be sampled for the fill below.
	if env.sky == null:
		var sky := Sky.new()
		var sky_mat := ProceduralSkyMaterial.new()
		sky_mat.sky_top_color = Color(0.38, 0.5, 0.72)
		sky_mat.sky_horizon_color = Color(0.62, 0.66, 0.7)
		sky_mat.ground_bottom_color = Color(0.2, 0.18, 0.16)
		sky_mat.ground_horizon_color = Color(0.45, 0.42, 0.38)
		sky.sky_material = sky_mat
		env.sky = sky
	# Skylight is folded into the ambient COLOR here rather than left to
	# ambient_light_sky_contribution. That property mixes in sky radiance, but
	# it is easy to have it silently contribute nothing (a Sky the renderer
	# never evaluates contributes zero), which is what made this slider look
	# dead. Computing the fill from the sky material's own colors makes the
	# slider move the ambient for certain, and 0 still means exactly the flat
	# ambient color below, so the color box keeps its meaning.
	var sky_fill := _sky_ambient_color(env)
	env.ambient_light_color = env_ambient_color.lerp(sky_fill,
		clampf(env_sky_energy, 0.0, 1.0))
	env.ambient_light_sky_contribution = 0.0
	# The sky is deliberately NOT used as the background (that stays the flat
	# color below), which is what lets the terrain pick up sky-colored fill
	# without changing the viewport backdrop.
	# Keep it stable and compatible with the matte terrain shader (no reflection)
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.1, 0.12, 0.16)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

func _sync_environment() -> void:
	var root := EditorInterface.get_edited_scene_root()
	if root == null:
		return
	for n in root.find_children("*", "WorldEnvironment", true, false):
		if n is WorldEnvironment:
			_apply_env_state(n)
			return


func _on_sun_color_changed(color: Color) -> void:
	sun_color = color
	_sun_light().light_color = color
	_save_overlay_prefs()

func _on_sun_energy_changed(value: float) -> void:
	sun_energy = value
	_sun_light().light_energy = value
	_save_overlay_prefs()

# The directional shadow atlas SIZE is a project setting in Godot 4, not a
# property on DirectionalLight3D - assigning sun.directional_shadow_atlas_size
# threw "Invalid assignment of property or key 'directional_shadow_atlas_size'"
# on every change, so the shadow resolution control did nothing. Only the
# distance belongs on the light; the resolution goes to the renderer setting.
const SUN_SHADOW_ATLAS_SETTING := "rendering/lights_and_shadows/directional_shadow/size"
# Godot 4 accepts 0 (= "use the project default"), 1, 2 or 4 for this setting.
# The shadow-atlas size choices the UI offers live in
# TerrainEditorPanel.SHADOW_ATLAS_SIZES, and they are deliberately NOT mirrored
# here: the atlas is a startup-only global, so there is nothing for this plugin
# to apply them to. (They used to be mirrored, misaligned by one slot - the UI
# said 2048 where the plugin wrote 0 - and 0 is not even a legal value for
# rendering/lights_and_shadows/directional_shadow/size, whose range is 256..16384.)

func _apply_sun_shadow_extras(sun: DirectionalLight3D) -> void:
	if sun == null:
		return
	# Shadow RANGE is a per-light property, honoured live, so this is the one
	# shadow control the panel can genuinely drive.
	sun.directional_shadow_max_distance = sun_shadow_distance
	# Shadow RESOLUTION is not a per-light property, and this is why it is NOT
	# set here. All directional shadows are packed into a single global atlas
	# whose size the renderer allocates ONCE at startup from
	# ProjectSettings; writing that setting from a plugin at editor runtime does
	# not resize the atlas that is already live, it just pushes a value the
	# renderer is not going to re-read into the configuration it is using right
	# now. It also used to write index 0, which is 0 - and 0 is not a legal
	# value for it at all: the property is an enum spanning 256..16384. So
	# simply switching the sun on was putting an invalid shadow-atlas size into
	# the live renderer config. To change the atlas size, set
	# rendering/lights_and_shadows/directional_shadow/size in Project Settings
	# and restart the editor.
	print("[WMT lighting] directional shadow atlas size is a startup-only global "
		+ "(current %d, UI index %d); set it in Project Settings to change it"
		% [ProjectSettings.get_setting(SUN_SHADOW_ATLAS_SETTING, 0), sun_shadow_resolution])

func _on_sun_shadow_distance_changed(value: float) -> void:
	sun_shadow_distance = maxf(value, 0.0)
	_apply_sun_shadow_extras(_sun_light())
	_save_overlay_prefs()

func _on_sun_shadow_resolution_changed(index: int) -> void:
	sun_shadow_resolution = clampi(index, 0, 3)
	_apply_sun_shadow_extras(_sun_light())
	_save_overlay_prefs()

func _on_sun_shadow_toggled(on: bool) -> void:
	sun_shadow = on
	_sun_light().shadow_enabled = on
	_save_overlay_prefs()

func _on_env_ambient_color_changed(color: Color) -> void:
	env_ambient_color = color
	_world_environment()
	_save_overlay_prefs()

func _on_env_ambient_energy_changed(value: float) -> void:
	env_ambient_energy = clampf(value, 0.0, 5.0)
	_world_environment()
	_save_overlay_prefs()

func _on_env_sky_energy_changed(value: float) -> void:
	env_sky_energy = clampf(value, 0.0, 1.0)
	_world_environment()
	_save_overlay_prefs()

func _on_save_requested() -> void:
	if not is_instance_valid(terrain):
		return
	if str(terrain.terrain_file) == "":
		_prompt_file_dialog(true)
		return
	_save_terrain()

func _on_load_requested() -> void:
	if not is_instance_valid(terrain):
		return
	_prompt_file_dialog(false)

func _set_terrain_file(path: String) -> void:
	if not is_instance_valid(terrain):
		return
	var old := str(terrain.terrain_file)
	if old == path:
		return
	var urm := EditorInterface.get_editor_undo_redo()
	urm.create_action("Set terrain file")
	urm.add_do_property(terrain, "terrain_file", path)
	urm.add_undo_property(terrain, "terrain_file", old)
	urm.commit_action()

func _prompt_file_dialog(save: bool) -> void:
	if not is_instance_valid(terrain) or panel == null:
		return
	var fd := EditorFileDialog.new()
	fd.access = EditorFileDialog.ACCESS_RESOURCES
	fd.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE if save else EditorFileDialog.FILE_MODE_OPEN_FILE
	if save:
		fd.filters = PackedStringArray(["*.wmt ; WMT Terrain"])
	else:
		# Any single .wmt is selectable; a master 0_0.wmt auto-loads its
		# sibling chunk files, a lone chunk file is imported as raw.
		fd.filters = PackedStringArray(["*.wmt ; WMT Terrain"])
	var base_dir := str(terrain.terrain_file).get_base_dir()
	if base_dir == "":
		base_dir = "res://wmt"
	if save:
		fd.set_current_dir(base_dir)
		fd.set_current_file("0_0.wmt")
		fd.file_selected.connect(func(p: String) -> void:
			_set_terrain_file(p)
			_save_terrain()
		)
	else:
		fd.set_current_dir(base_dir)
		fd.file_selected.connect(func(p: String) -> void:
			_set_terrain_file(p)
			_load_terrain(p)
		)
	panel.add_child(fd)
	fd.popup_centered_ratio(0.5)
	fd.closed.connect(func() -> void:
		if is_instance_valid(fd):
			fd.queue_free()
	)

func _load_terrain(path: String) -> void:
	if not is_instance_valid(terrain):
		return
	if terrain.load_wmt(path):
		if str(terrain.terrain_file) == "":
			_set_terrain_file(path)
		if path.get_file() != "0_0.wmt":
			# Raw import: re-persist as per-chunk files under the master name.
			_save_terrain(terrain)
		_apply_terrain_overlays()
		_drape_ring()
		if active_tab == TAB_WMT:
			_rebuild_overlay_layers()
		print("[WMT] loaded " + path)
	else:
		push_warning("[WMT] failed to load %s" % path)

func _save_terrain(t: WmtScript = null, only: Array = []) -> void:
	if t == null:
		t = terrain
	if not is_instance_valid(t):
		return
	var path := str(t.terrain_file)
	if path == "":
		return
	var base := path.get_base_dir()
	if base == "":
		return
	var master := base.path_join("0_0.wmt")
	if path != master:
		t.terrain_file = master
	var wrote := t.save_wmt(master, only)
	# Always sweep, even when the write reported failure: a chunk file left
	# behind for a deleted chunk is what makes a delete look like it never
	# happened (the file is re-read as if the chunk were still there).
	var removed := _cleanup_stale_chunk_files(t, base)
	if not removed.is_empty():
		print("[WMT] removed %d stale chunk file(s): %s" % [removed.size(), removed])
		# The editor's filesystem only notices deletions on a scan(); defer it so
		# the delete frame itself stays cheap (a synchronous scan here is what
		# used to freeze the editor).
		_pending_fs_scan = true
	if not wrote:
		push_warning("[WMT] terrain save reported failure for %s" % master)
	var fs := EditorInterface.get_resource_filesystem()
	if wrote:
		# Targeted update_file() per written chunk instead of a full project
		# scan() - scan() on every stroke end was the main editor freeze.
		if only.is_empty():
			for c in t.chunks:
				var ck: Vector2i = c
				fs.update_file("%s/%d_%d.wmt" % [base, ck.x, ck.y])
			print("[WMT] saved %d chunk(s) -> %s" % [t.chunks.size(), master])
		else:
			for k in only:
				var ck2: Vector2i = k
				fs.update_file("%s/%d_%d.wmt" % [base, ck2.x, ck2.y])
			print("[WMT] saved %d chunk(s)" % only.size())

func _eyedrop_set_height() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	if cursor_local == null:
		_update_cursor_position()
	if cursor_local == null:
		return
	var h := terrain.sample_surface(cursor_local)
	if panel != null and panel.set_height_spin != null:
		panel.set_height_spin.value = maxf(0.0, h)
	print("[WMT] Set Height picked: %.2f" % panel.set_height_spin.value)


func _switch_mode_deferred(index: int) -> void:
	active_tab = index
	if panel != null:
		panel.set_mode(index)
		if index == TAB_SCULPT and panel.has_method("set_sculpt_tool"):
			panel.set_sculpt_tool(sculpt_tool)
		if index == TAB_SCULPT and panel.has_method("set_smooth_tool"):
			panel.set_smooth_tool(smooth_tool)
		if panel.has_method("update_radius_label"):
			panel.update_radius_label(cursor_radius)
		if panel.has_method("update_falloff_label"):
			panel.update_falloff_label(falloff_ratio)
		if panel.has_method("update_strength_label"):
			panel.update_strength_label(sculpt_strength)
	if modes != null:
		modes.set_active(index)
	_sync_selection_to_mode(index)
	_lock_terrain_for_objects_mode(index)
	_refresh_brush_visibility()
	_switching_mode = false

func _setup_autosave() -> void:
	pass

func _on_autosave_timeout() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	call_deferred("_autosave_do")

func _autosave_do() -> void:
	if terrain == null or not is_instance_valid(terrain):
		return
	_save_terrain(terrain)
	var dlg := AcceptDialog.new()
	dlg.title = "Autosaving"
	dlg.dialog_text = "Autosaving terrain..."
	dlg.ok_button_text = "OK"
	add_child(dlg)
	dlg.popup_centered(Vector2(300, 100))
	var t := get_tree()
	if t != null:
		t.create_timer(1.2).timeout.connect(func(): if is_instance_valid(dlg): dlg.queue_free())


func _apply_paint_undo_deferred(t) -> void:
	if not is_instance_valid(t):
		return
	_apply_terrain_overlays()
	_drape_ring()

func _apply_vertex_undo_deferred(t) -> void:
	if not is_instance_valid(t):
		return
	_apply_terrain_overlays()
	_drape_ring()

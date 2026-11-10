@tool
extends VBoxContainer

# Terrain editor dock panel (docked right in the editor, not a bottom tab).
# There is NO tab strip: the floating mode sidebar in the viewport
# (terrain_editor_modes.gd) chooses the mode and the plugin lands on this
# panel via set_mode(), which shows exactly one page of contents.
#
# Pages:
#   WMT        - chunk/tile visibility editing help
#   Zones      - placeholder
#   Sculpt     - Sculpt/Set Height/Smooth radios (Set Height and the Smooth
#                submode's raise/flatten/smooth/lower are sub-tools here),
#                radius/strength/falloff brush rows
#   Paint      - splat color box that opens a popup (channel swatches only;
#                retinting happens in the Ctrl+RMB viewport popup's color
#                button)
#   Vertex     - placeholder
#   Objects    - placeholder
#   Settings   - file load/save, wireframe, grid borders, the scene's
#                directional light (the "WMT Sun"), brush look, and the single
#                consolidated keybinds list

signal wireframe_toggled(on: bool)
signal wireframe_color_changed(black: bool)
signal wireframe_thickness_changed(width: float)
signal grid_toggled(on: bool)
signal radius_changed(value: float)
signal strength_changed(value: float)
signal falloff_changed(value: float)
signal sculpt_tool_changed(tool: int)
signal smooth_tool_changed(tool: int)
# Scene directional light (drives the DirectionalLight3D node live).
signal sun_color_changed(color: Color)
signal sun_energy_changed(value: float)
signal sun_shadow_toggled(on: bool)
signal sun_shadow_distance_changed(value: float)
signal sun_shadow_resolution_changed(index: int)
signal tile_line_thickness_changed(value: float)
signal env_ambient_color_changed(color: Color)
signal env_ambient_energy_changed(value: float)
signal env_sky_energy_changed(value: float)
signal object_browse_requested
signal paint_channel_selected(index: int)
signal paint_texture_requested(channel: int)
signal paint_depth_changed(value: float)
signal wipe_channel_pressed(channel: int)
signal wipe_tile_pressed
signal save_requested
signal load_requested
signal brush_color_changed(color: Color)
signal brush_thickness_changed(width: float)
signal paint_opacity_changed(value: float)
signal paint_flow_changed(value: float)
signal paint_spacing_changed(value: float)
signal paint_spray_toggled(on: bool)
signal paint_spray_interval_changed(value: float)
# Vertex-color paint page.
signal vertex_color_changed(color: Color)
signal vertex_strength_changed(value: float)
signal vertex_opacity_changed(value: float)
signal vertex_flow_changed(value: float)
signal vertex_spacing_changed(value: float)
signal vertex_spray_toggled(on: bool)
signal vertex_spray_interval_changed(value: float)
signal wipe_vertex_pressed

const TOOL_SCULPT := 0
const TOOL_SET_HEIGHT := 1
const TOOL_SMOOTH := 2

# Sub-tools inside the Sculpt -> Smooth submode ("[ ] smooth" reveals these):
#   raise    smooth everything up to the highest vertex in the brush radius
#   flatten  level everything in the brush radius
#   smooth   regular smoothing in the brush radius
#   lower    smooth everything down to the lowest vertex in the brush radius
const SMOOTH_TOOL_RAISE := 0
const SMOOTH_TOOL_FLATTEN := 1
const SMOOTH_TOOL_SMOOTH := 2
const SMOOTH_TOOL_LOWER := 3
const PAINT_CHANNEL_NAMES := [
	"Splat 1", "Splat 2", "Splat 3", "Splat 4", "Splat 5", "Splat 6",
]

# Keybind lines are capped at 30 characters (~240px at the default editor
# font) so the whole paragraph stays a narrow column in the Settings tab.
const KEYBIND_LINE_WIDTH := 240.0

var plugin: EditorPlugin = null

var wireframe_button: CheckBox
var bw_button: CheckButton
var thick_spin: SpinBox
var grid_check: CheckBox
var brush_color_button: ColorPickerButton
var vertex_color_button: ColorPickerButton
var vertex_strength_spin: SpinBox
var vertex_opacity_spin: SpinBox
var vertex_flow_spin: SpinBox
var vertex_spacing_spin: SpinBox
var vertex_spray_check: CheckBox
var vertex_spray_interval_spin: SpinBox
var _vertex_syncing := false
var brush_thick_spin: SpinBox
var sun_color_button: ColorPickerButton
var sun_energy_slider: HSlider
var sun_shadow_check: CheckBox
var sun_shadow_dist_spin: SpinBox
var sun_shadow_res_slider: HSlider
var tile_thick_spin: SpinBox
var _keybind_window: PopupPanel = null
var _keybind_search: LineEdit = null
var _keybind_groups: VBoxContainer = null
var env_ambient_button: ColorPickerButton
var env_ambient_slider: HSlider
var env_sky_slider: HSlider
var object_preview: Control
var object_browse_button: Button
# Clipboard contents shown by the object stamp: one entry per copied object
# ({path, name, offset, size}) or empty for an empty clipboard.
var object_clipboard: Array = []
var paint_opacity_spin: SpinBox
var paint_flow_spin: SpinBox
var paint_spacing_spin: SpinBox
var paint_spray_check: CheckBox
var paint_spray_interval_spin: SpinBox
var save_button: Button
var load_button: Button
var pages: Array = []
var sculpt_radio: CheckBox
var set_height_radio: CheckBox
var set_height_box: VBoxContainer
var set_height_spin: SpinBox
var smooth_radio: CheckBox
var smooth_tool_box: VBoxContainer
var smooth_tool_raise: CheckBox
var smooth_tool_flatten: CheckBox
var smooth_tool_smooth: CheckBox
var smooth_tool_lower: CheckBox
var radius_spin: SpinBox
var radius_spin_paint: SpinBox
var strength_spin: SpinBox
var falloff_spin: SpinBox
var falloff_spin_paint: SpinBox
var splat_square: Button
var depth_spin: SpinBox
var paint_channel := 0
var paint_channel_textures: Array[String] = []
var _current_mode := -1
var _syncing := false
var _sculpt_group := ButtonGroup.new()
var _smooth_group := ButtonGroup.new()

func _ready() -> void:
	_build_header()
	_build_pages()

	radius_spin.value_changed.connect(func(v: float):
		if _syncing:
			return
		radius_changed.emit(v))
	strength_spin.value_changed.connect(func(v: float):
		if _syncing:
			return
		strength_changed.emit(v / 100.0))
	falloff_spin.value_changed.connect(func(v: float):
		if _syncing:
			return
		falloff_changed.emit(v / 100.0))
	radius_spin_paint.value_changed.connect(func(v: float):
		if _syncing:
			return
		radius_changed.emit(v))
	falloff_spin_paint.value_changed.connect(func(v: float):
		if _syncing:
			return
		falloff_changed.emit(v / 100.0))
	sculpt_radio.toggled.connect(func(on: bool):
		if on:
			_set_sculpt_tool_gui(TOOL_SCULPT))
	set_height_radio.toggled.connect(func(on: bool):
		if on:
			_set_sculpt_tool_gui(TOOL_SET_HEIGHT))
	smooth_radio.toggled.connect(func(on: bool):
		if on:
			_set_sculpt_tool_gui(TOOL_SMOOTH))
	smooth_tool_raise.toggled.connect(func(on: bool):
		if on:
			_set_smooth_tool_gui(SMOOTH_TOOL_RAISE))
	smooth_tool_flatten.toggled.connect(func(on: bool):
		if on:
			_set_smooth_tool_gui(SMOOTH_TOOL_FLATTEN))
	smooth_tool_smooth.toggled.connect(func(on: bool):
		if on:
			_set_smooth_tool_gui(SMOOTH_TOOL_SMOOTH))
	smooth_tool_lower.toggled.connect(func(on: bool):
		if on:
			_set_smooth_tool_gui(SMOOTH_TOOL_LOWER))
	sun_color_button.color_changed.connect(func(c: Color):
		if _syncing:
			return
		sun_color_changed.emit(c))
	# The _syncing guard is what stops a programmatic push (set_shadow_extras /
	# set_tile_line_thickness) from bouncing back out as a user edit and saving
	# the prefs again.
	tile_thick_spin.value_changed.connect(func(v: float):
		if _syncing:
			return
		tile_line_thickness_changed.emit(v))
	sun_shadow_dist_spin.value_changed.connect(func(v: float):
		if _syncing:
			return
		sun_shadow_distance_changed.emit(v))
	sun_shadow_check.toggled.connect(func(on: bool):
		if _syncing:
			return
		sun_shadow_toggled.emit(on))
	wireframe_button.toggled.connect(_on_wireframe_pressed)
	bw_button.toggled.connect(func(on: bool): wireframe_color_changed.emit(on))
	thick_spin.value_changed.connect(func(v: float): wireframe_thickness_changed.emit(v))
	grid_check.toggled.connect(func(on: bool): grid_toggled.emit(on))
	brush_color_button.color_changed.connect(func(c: Color): brush_color_changed.emit(c))
	brush_thick_spin.value_changed.connect(func(v: float): brush_thickness_changed.emit(v))
	paint_opacity_spin.value_changed.connect(func(v: float): paint_opacity_changed.emit(v))
	paint_flow_spin.value_changed.connect(func(v: float): paint_flow_changed.emit(v))
	paint_spacing_spin.value_changed.connect(func(v: float): paint_spacing_changed.emit(v))
	paint_spray_check.toggled.connect(func(on: bool):
		paint_spray_interval_spin.editable = on
		paint_spray_interval_spin.modulate = Color(1.0, 1.0, 1.0) if on else Color(0.6, 0.6, 0.6)
		paint_spray_toggled.emit(on))
	paint_spray_interval_spin.value_changed.connect(func(v: float): paint_spray_interval_changed.emit(v))
	splat_square.pressed.connect(func(): paint_texture_requested.emit(paint_channel))
	depth_spin.value_changed.connect(func(v: float): paint_depth_changed.emit(v))
	save_button.pressed.connect(func(): save_requested.emit())
	load_button.pressed.connect(func(): load_requested.emit())
	set_mode(0)

func _build_header() -> void:
	add_theme_constant_override("separation", 4)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 6)
	add_child(header)

	var title := Label.new()
	title.text = "WMT Terrain"
	title.add_theme_font_size_override("font_size", 14)
	header.add_child(title)

	header.add_child(HSeparator.new())

func _build_pages() -> void:
	var content := VBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 4)
	add_child(content)

	pages.clear()
	for page in [_make_wmt_page(), _make_zones_page(), _make_sculpt_page(),
			_make_paint_page(), _make_vertex_page(), _make_objects_page(),
			_make_settings_page()]:
		pages.append(page)
		content.add_child(page)

func set_mode(index: int) -> void:
	if index == _current_mode:
		return
	if pages.is_empty():
		_current_mode = index
		return
	_current_mode = index
	for i in pages.size():
		if pages[i] != null:
			pages[i].visible = i == index

func get_tab_index() -> int:
	return maxi(_current_mode, 0)

func _make_wmt_page() -> Control:
	var page := VBoxContainer.new()
	return page

func _make_zones_page() -> Control:
	return _placeholder("Biome/zone tools will live here.")

func _make_sculpt_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	var tool_row := HBoxContainer.new()
	tool_row.add_theme_constant_override("separation", 6)
	sculpt_radio = CheckBox.new()
	sculpt_radio.text = "Sculpt"
	sculpt_radio.tooltip_text = "Raise / lower / smooth the height field (modifier brushes)"
	sculpt_radio.focus_mode = Control.FOCUS_NONE
	sculpt_radio.button_group = _sculpt_group
	sculpt_radio.button_pressed = true
	tool_row.add_child(sculpt_radio)
	set_height_radio = CheckBox.new()
	set_height_radio.text = "Set Height"
	set_height_radio.tooltip_text = "Drag to push the surface to an absolute height"
	set_height_radio.focus_mode = Control.FOCUS_NONE
	set_height_radio.button_group = _sculpt_group
	tool_row.add_child(set_height_radio)
	smooth_radio = CheckBox.new()
	smooth_radio.text = "Smooth"
	smooth_radio.tooltip_text = "Raise / flatten / smooth / lower toward the brush's extremes"
	smooth_radio.focus_mode = Control.FOCUS_NONE
	smooth_radio.button_group = _sculpt_group
	tool_row.add_child(smooth_radio)
	tool_row.add_child(_spacer())
	page.add_child(tool_row)

	set_height_box = VBoxContainer.new()
	set_height_box.add_theme_constant_override("separation", 6)
	set_height_box.visible = false

	var height_row := HBoxContainer.new()
	height_row.add_theme_constant_override("separation", 10)
	set_height_box.add_child(height_row)
	var height_label := Label.new()
	height_label.text = "Height"
	height_label.custom_minimum_size = Vector2(60.0, 0.0)
	height_row.add_child(height_label)
	set_height_spin = SpinBox.new()
	set_height_spin.min_value = 0.0
	set_height_spin.max_value = 10000.0
	set_height_spin.step = 1.0
	set_height_spin.value = 0.0
	set_height_spin.custom_minimum_size = Vector2(72.0, 0.0)
	set_height_spin.editable = true
	set_height_spin.modulate = Color(1, 1, 1)
	set_height_spin.tooltip_text = "Target surface height (0 = ground level; heights never go below 0)"
	height_row.add_child(set_height_spin)
	height_row.add_child(_spacer())

	var tip := Label.new()
	tip.text = "LMB drag pushes the surface toward the target height. Ctrl+LMB picks height."
	tip.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	set_height_box.add_child(tip)
	page.add_child(set_height_box)

	# Smooth submode: selecting it reveals the raise/flatten/smooth/lower
	# sub-tools. These are real square checkboxes in a ButtonGroup, so exactly
	# one is active but they render as ordinary boxes rather than switches.
	smooth_tool_box = VBoxContainer.new()
	smooth_tool_box.add_theme_constant_override("separation", 6)
	smooth_tool_box.visible = false

	var sub_root := Label.new()
	sub_root.text = "Sub-tool"
	sub_root.add_theme_font_size_override("font_size", 12)
	sub_root.add_theme_color_override("font_color", Color(0.7, 0.75, 0.8))
	smooth_tool_box.add_child(sub_root)

	smooth_tool_raise = CheckBox.new()
	smooth_tool_raise.text = "Raise"
	smooth_tool_raise.tooltip_text = "Smooth everything up to the highest vertex inside the brush radius"
	smooth_tool_raise.focus_mode = Control.FOCUS_NONE
	smooth_tool_raise.button_group = _smooth_group
	smooth_tool_box.add_child(smooth_tool_raise)

	smooth_tool_flatten = CheckBox.new()
	smooth_tool_flatten.text = "Flatten"
	smooth_tool_flatten.tooltip_text = "Level everything inside the brush radius"
	smooth_tool_flatten.focus_mode = Control.FOCUS_NONE
	smooth_tool_flatten.button_group = _smooth_group
	smooth_tool_box.add_child(smooth_tool_flatten)

	smooth_tool_smooth = CheckBox.new()
	smooth_tool_smooth.text = "Smooth"
	smooth_tool_smooth.tooltip_text = "Regular smoothing inside the brush radius"
	smooth_tool_smooth.focus_mode = Control.FOCUS_NONE
	smooth_tool_smooth.button_group = _smooth_group
	smooth_tool_smooth.button_pressed = true
	smooth_tool_box.add_child(smooth_tool_smooth)

	smooth_tool_lower = CheckBox.new()
	smooth_tool_lower.text = "Lower"
	smooth_tool_lower.tooltip_text = "Smooth everything down to the lowest vertex inside the brush radius"
	smooth_tool_lower.focus_mode = Control.FOCUS_NONE
	smooth_tool_lower.button_group = _smooth_group
	smooth_tool_box.add_child(smooth_tool_lower)

	var s_tip := Label.new()
	s_tip.text = "LMB drag runs the selected sub-tool inside the brush circle."
	s_tip.add_theme_color_override("font_color", Color(0.75, 0.75, 0.75))
	s_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	smooth_tool_box.add_child(s_tip)
	page.add_child(smooth_tool_box)

	page.add_child(_value_row("Radius", "brush radius of the cursor circle / paint", 0.25, 64.0, 0.25, 2.0))
	radius_spin = page.get_child(page.get_child_count() - 1).get_node("Value") as SpinBox

	page.add_child(_value_row("Strength", "sculpt strength as a percent (Alt + wheel)", 5.0, 1200.0, 5.0, 100.0))
	strength_spin = page.get_child(page.get_child_count() - 1).get_node("Value") as SpinBox

	page.add_child(_value_row("Falloff", "how much the stroke tapers at the edge (Shift + wheel)", 0.0, 100.0, 1.0, 50.0))
	falloff_spin = page.get_child(page.get_child_count() - 1).get_node("Value") as SpinBox

	var info := VBoxContainer.new()
	info.add_theme_constant_override("separation", 0)
	var rl := Label.new()
	rl.name = "cursor_radius_label"
	info.add_child(rl)
	var ff := Label.new()
	ff.name = "cursor_falloff_label"
	info.add_child(ff)
	var st := Label.new()
	st.name = "cursor_strength_label"
	info.add_child(st)
	page.add_child(info)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(spacer)
	return page

func _set_sculpt_tool_gui(tool: int) -> void:
	if set_height_box != null:
		set_height_box.visible = tool == TOOL_SET_HEIGHT
	if smooth_tool_box != null:
		smooth_tool_box.visible = tool == TOOL_SMOOTH
	sculpt_tool_changed.emit(tool)

func _set_smooth_tool_gui(tool: int) -> void:
	smooth_tool_changed.emit(tool)

func _value_row(label_text: String, tip: String, vmin: float, vmax: float, vstep: float, vdef: float) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.name = "ValueRow"
	var lbl := Label.new()
	lbl.text = label_text
	lbl.custom_minimum_size = Vector2(90.0, 0.0)
	row.add_child(lbl)
	var spin := SpinBox.new()
	spin.name = "Value"
	spin.min_value = vmin
	spin.max_value = vmax
	spin.step = vstep
	spin.value = vdef
	spin.tooltip_text = tip
	spin.custom_minimum_size = Vector2(84.0, 0.0)
	row.add_child(spin)
	row.add_child(_spacer())
	return row

func _make_paint_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	var color_row := HBoxContainer.new()
	color_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	color_row.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_child(color_row)
	splat_square = Button.new()
	splat_square.custom_minimum_size = Vector2(198.0, 198.0)
	splat_square.tooltip_text = "Channel texture \u2014 click to assign a tileset texture to the paint channel (Ctrl+RMB in the viewport switches channels)"
	splat_square.focus_mode = Control.FOCUS_NONE
	color_row.add_child(splat_square)
	var chan_row := HBoxContainer.new()
	chan_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	chan_row.alignment = BoxContainer.ALIGNMENT_CENTER
	page.add_child(chan_row)
	var wipe_chan := Button.new()
	wipe_chan.text = "Wipe channel"
	wipe_chan.tooltip_text = "Erase the selected channel's paint (and its texture override) from the selected / picked tiles"
	wipe_chan.focus_mode = Control.FOCUS_NONE
	wipe_chan.pressed.connect(func() -> void: wipe_channel_pressed.emit(paint_channel))
	chan_row.add_child(wipe_chan)
	var wipe_tile := Button.new()
	wipe_tile.text = "Wipe tile"
	wipe_tile.tooltip_text = "Erase ALL paint from the selected / picked tiles (weights, textures, tilings, depths)"
	wipe_tile.focus_mode = Control.FOCUS_NONE
	wipe_tile.pressed.connect(func() -> void: wipe_tile_pressed.emit())
	chan_row.add_child(wipe_tile)

	var depth_row := HBoxContainer.new()
	depth_row.add_theme_constant_override("separation", 10)
	page.add_child(depth_row)
	var depth_tile_lbl := Label.new()
	depth_tile_lbl.text = "Depth"
	depth_tile_lbl.custom_minimum_size = Vector2(50.0, 0.0)
	depth_row.add_child(depth_tile_lbl)
	depth_spin = SpinBox.new()
	depth_spin.min_value = 0.01
	depth_spin.max_value = 1.0
	depth_spin.step = 0.01
	depth_spin.value = 0.2
	depth_spin.tooltip_text = "How aggressively the top layer buries the ones below it (masked-depth blending)"
	depth_spin.custom_minimum_size = Vector2(90.0, 0.0)
	depth_row.add_child(depth_spin)

	page.add_child(_value_row("Radius", "paint brush radius", 0.25, 64.0, 0.25, 2.0))
	radius_spin_paint = page.get_child(page.get_child_count() - 1).get_node("Value") as SpinBox
	page.add_child(_value_row("Falloff", "how much paint tapers at the brush edge", 0.0, 100.0, 1.0, 50.0))
	falloff_spin_paint = page.get_child(page.get_child_count() - 1).get_node("Value") as SpinBox

	page.add_child(_paint_row("Opacity", "paint_opacity", "How strong the paint applies per stroke", 0.0, 1.0, 0.05))
	page.add_child(_paint_row("Flow", "paint_flow", "How much each brush stamp adds (fine-grained: 4 decimal digits)", 0.0, 1.0, 0.0001))
	page.add_child(_paint_row("Spacing", "paint_spacing", "Min distance between paint stamps (world units)", 0.5, 64.0, 0.5))

	var spray_row := HBoxContainer.new()
	spray_row.add_theme_constant_override("separation", 10)
	var spray_lbl := Label.new()
	spray_lbl.text = "Spray paint"
	spray_lbl.custom_minimum_size = Vector2(90.0, 0.0)
	spray_lbl.tooltip_text = "Keep painting while Shift+left-click is held, even when the cursor doesn't move"
	spray_row.add_child(spray_lbl)
	paint_spray_check = CheckBox.new()
	paint_spray_check.tooltip_text = spray_lbl.tooltip_text
	paint_spray_check.button_pressed = true
	spray_row.add_child(paint_spray_check)
	var spray_rate_lbl := Label.new()
	spray_rate_lbl.text = "Every"
	spray_rate_lbl.tooltip_text = "Seconds between spray stamps at a stationary cursor"
	spray_row.add_child(spray_rate_lbl)
	paint_spray_interval_spin = SpinBox.new()
	paint_spray_interval_spin.min_value = 0.01
	paint_spray_interval_spin.max_value = 1.0
	paint_spray_interval_spin.step = 0.01
	paint_spray_interval_spin.value = 0.05
	paint_spray_interval_spin.tooltip_text = spray_rate_lbl.tooltip_text
	spray_row.add_child(paint_spray_interval_spin)
	paint_spray_interval_spin.custom_minimum_size = Vector2(70.0, 0.0)
	page.add_child(spray_row)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(spacer)
	_update_splat_square()
	return page

func _paint_row(label: String, var_name: String, tip: String, vmin: float, vmax: float, vstep: float) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	var lbl := Label.new()
	lbl.text = label
	lbl.custom_minimum_size = Vector2(90.0, 0.0)
	row.add_child(lbl)
	var spin := SpinBox.new()
	spin.min_value = vmin
	spin.max_value = vmax
	spin.step = vstep
	spin.tooltip_text = tip
	spin.custom_minimum_size = Vector2(84.0, 0.0)
	row.add_child(spin)
	row.add_child(_spacer())
	match var_name:
		"paint_opacity":
			paint_opacity_spin = spin
			spin.value = 1.0
		"paint_flow":
			paint_flow_spin = spin
			spin.value = 1.0
		"paint_spacing":
			paint_spacing_spin = spin
			spin.value = 8.0
		"vertex_opacity":
			vertex_opacity_spin = spin
			spin.value = 1.0
		"vertex_flow":
			vertex_flow_spin = spin
			spin.value = 1.0
		"vertex_spacing":
			vertex_spacing_spin = spin
			spin.value = 4.0
	return row

func _make_vertex_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	var color_row := HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 10)
	page.add_child(color_row)
	var color_label := Label.new()
	color_label.text = "Color"
	color_label.custom_minimum_size = Vector2(90.0, 0.0)
	color_row.add_child(color_label)
	vertex_color_button = ColorPickerButton.new()
	vertex_color_button.color = Color.WHITE
	# The W3C blend, not a multiply: 50% gray is the no-op and is therefore the
	# eraser, and black is a real color that darkens (it cannot push a base that
	# is already above 0.5 below 0.5, so black is not a "make it black" pick).
	vertex_color_button.tooltip_text = "Top layer blended into the albedo per texel." \
		+ "\n50% gray is the neutral no-op and ERASES." \
		+ "\nBlack darkens instead of erasing." \
		+ "\nCtrl+RMB on the terrain opens the full selector."
	vertex_color_button.custom_minimum_size = Vector2(80.0, 0.0)
	color_row.add_child(vertex_color_button)
	var vcol_eraser := Button.new()
	vcol_eraser.text = "Erase"
	vcol_eraser.tooltip_text = "Pick 50% gray (the eraser). Same as holding Shift."
	vcol_eraser.pressed.connect(func() -> void: set_vertex_color(ERASER_COLOR))
	color_row.add_child(vcol_eraser)
	color_row.add_child(_spacer())

	var stren_row := HBoxContainer.new()
	stren_row.add_theme_constant_override("separation", 10)
	page.add_child(stren_row)
	var stren_label := Label.new()
	stren_label.text = "Strength"
	stren_label.custom_minimum_size = Vector2(90.0, 0.0)
	stren_row.add_child(stren_label)
	vertex_strength_spin = SpinBox.new()
	vertex_strength_spin.min_value = 0.0
	vertex_strength_spin.max_value = 1.0
	vertex_strength_spin.step = 0.05
	# 0.2, not 0.5: a single dab used to land half-strength and read as
	# "it just paints really strongly", which left Opacity and Flow looking
	# inert because the default was already near saturation.
	vertex_strength_spin.value = 0.2
	vertex_strength_spin.tooltip_text = "Overall stroke gain: how much one pass of the stroke deposits (0 = nothing)"
	vertex_strength_spin.custom_minimum_size = Vector2(84.0, 0.0)
	stren_row.add_child(vertex_strength_spin)
	stren_row.add_child(_spacer())

	page.add_child(_paint_row("Opacity", "vertex_opacity", "Caps how much the stroke is allowed to deposit in total", 0.0, 1.0, 0.05))
	page.add_child(_paint_row("Flow", "vertex_flow", "How much each stamp of the sweep adds (overlapping stamps are compensated, so this reads as one pass's density)", 0.0, 1.0, 0.01))
	# Spacing and spray are what make Flow visible: the stroke is swept along
	# the path the mouse travelled and keeps stamping at a stationary cursor,
	# exactly like the paint brush.
	page.add_child(_paint_row("Spacing", "vertex_spacing", "Min distance between vertex-tint stamps (world units)", 0.5, 64.0, 0.5))
	var vspray_row := HBoxContainer.new()
	vspray_row.add_theme_constant_override("separation", 10)
	page.add_child(vspray_row)
	var vspray_lbl := Label.new()
	vspray_lbl.text = "Spray paint"
	vspray_lbl.custom_minimum_size = Vector2(90.0, 0.0)
	vspray_lbl.tooltip_text = "Keep painting while Shift+LMB is held, even when the cursor doesn't move"
	vspray_row.add_child(vspray_lbl)
	vertex_spray_check = CheckBox.new()
	vertex_spray_check.tooltip_text = vspray_lbl.tooltip_text
	vertex_spray_check.button_pressed = true
	vspray_row.add_child(vertex_spray_check)
	var vspray_rate_lbl := Label.new()
	vspray_rate_lbl.text = "Every"
	vspray_rate_lbl.tooltip_text = "Seconds between vertex-tint spray stamps at a stationary cursor"
	vspray_row.add_child(vspray_rate_lbl)
	vertex_spray_interval_spin = SpinBox.new()
	vertex_spray_interval_spin.min_value = 0.01
	vertex_spray_interval_spin.max_value = 1.0
	vertex_spray_interval_spin.step = 0.01
	vertex_spray_interval_spin.value = 0.05
	vertex_spray_interval_spin.tooltip_text = vspray_rate_lbl.tooltip_text
	vspray_row.add_child(vertex_spray_interval_spin)
	vspray_row.add_child(_spacer())

	var wipe_row := HBoxContainer.new()
	wipe_row.add_theme_constant_override("separation", 6)
	page.add_child(wipe_row)
	var wipe_vertex_btn := Button.new()
	wipe_vertex_btn.text = "Wipe vertex tint"
	wipe_vertex_btn.tooltip_text = "Clear vertex tints back to neutral (no tint at all) on the selection (or the tile under the cursor)"
	wipe_vertex_btn.pressed.connect(func() -> void:
		wipe_vertex_pressed.emit()
	)
	wipe_row.add_child(wipe_vertex_btn)
	wipe_row.add_child(_spacer())

	# Initial sync with the plugin defaults (kept in the panel so the page is
	# self-contained in standalone checks).
	vertex_color_button.color_changed.connect(func(c: Color) -> void:
		if not _vertex_syncing:
			vertex_color_changed.emit(c)
	)
	vertex_strength_spin.value_changed.connect(func(v: float) -> void:
		if not _vertex_syncing:
			vertex_strength_changed.emit(v)
	)
	if vertex_opacity_spin != null:
		vertex_opacity_spin.value_changed.connect(func(v: float) -> void:
			if not _vertex_syncing:
				vertex_opacity_changed.emit(v)
		)
	if vertex_flow_spin != null:
		vertex_flow_spin.value_changed.connect(func(v: float) -> void:
			if not _vertex_syncing:
				vertex_flow_changed.emit(v)
		)
	if vertex_spacing_spin != null:
		vertex_spacing_spin.value_changed.connect(func(v: float) -> void:
			if not _vertex_syncing:
				vertex_spacing_changed.emit(v)
		)
	if vertex_spray_check != null:
		vertex_spray_check.toggled.connect(func(on: bool) -> void:
			vertex_spray_interval_spin.editable = on
			vertex_spray_interval_spin.modulate = Color(1.0, 1.0, 1.0) if on \
				else Color(0.6, 0.6, 0.6)
			vertex_spray_toggled.emit(on))
	if vertex_spray_interval_spin != null:
		vertex_spray_interval_spin.value_changed.connect(func(v: float) -> void:
			if not _vertex_syncing:
				vertex_spray_interval_changed.emit(v)
		)
	vertex_color_changed.emit(vertex_color_button.color)
	vertex_strength_changed.emit(vertex_strength_spin.value)
	return page

# Plugin -> panel push for the persisted vertex tint (color + strength loaded
# from project metadata). The guard stops a programmatic push from echoing
# back into vertex_color_changed / vertex_strength_changed, which would bounce
# an unnecessary prefs save right after boot.
# Push just the picked color, e.g. after the Ctrl+LMB vertex eyedropper read a
# color off the terrain. Same echo guard as set_vertex_state: a programmatic
# push must not bounce back out as a user edit.
# The shadow atlas sizes Godot exposes, as slider positions 0-3.
const SHADOW_ATLAS_SIZES := [2048, 4096, 8192, 16384]

func _shadow_atlas_label(index: int) -> String:
	var i := clampi(index, 0, SHADOW_ATLAS_SIZES.size() - 1)
	return str(SHADOW_ATLAS_SIZES[i])

func shadow_atlas_size(index: int) -> int:
	var i := clampi(index, 0, SHADOW_ATLAS_SIZES.size() - 1)
	return SHADOW_ATLAS_SIZES[i]

func set_vertex_color(color: Color) -> void:
	_vertex_syncing = true
	if vertex_color_button != null:
		vertex_color_button.color = color
	_vertex_syncing = false

func set_vertex_state(color: Color, strength: float, opacity: float, flow: float) -> void:
	_vertex_syncing = true
	if vertex_color_button != null:
		vertex_color_button.color = color
	if vertex_strength_spin != null:
		vertex_strength_spin.value = clampf(strength, 0.0, 1.0)
	if vertex_opacity_spin != null:
		vertex_opacity_spin.value = clampf(opacity, 0.0, 1.0)
	if vertex_flow_spin != null:
		vertex_flow_spin.value = clampf(flow, 0.0, 1.0)
	_vertex_syncing = false

# Spacing and spray live outside set_vertex_state: they are stroke SHAPE, not
# stroke intensity, and they have their own signals so the plugin can persist
# them independently of the strength/opacity/flow triple.
func set_vertex_brush_state(spacing: float, spray_on: bool,
		spray_interval: float) -> void:
	_vertex_syncing = true
	if vertex_spacing_spin != null:
		vertex_spacing_spin.value = clampf(spacing, 0.5, 64.0)
	if vertex_spray_check != null:
		vertex_spray_check.button_pressed = spray_on
	if vertex_spray_interval_spin != null:
		vertex_spray_interval_spin.value = clampf(spray_interval, 0.01, 1.0)
		vertex_spray_interval_spin.editable = spray_on
		vertex_spray_interval_spin.modulate = Color(1.0, 1.0, 1.0) if spray_on \
			else Color(0.6, 0.6, 0.6)
	_vertex_syncing = false

func _make_objects_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	var head := Label.new()
	head.text = "Object"
	head.add_theme_font_size_override("font_size", 13)
	head.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	head.tooltip_text = "Copy objects from the world folder (or select them in the scene and press Ctrl+C), then click the terrain in the viewport to paste them."
	page.add_child(head)

	# The object stamp, the counterpart of the paint channel preview: it shows
	# whatever is on the clipboard and, for a group, the relative layout.
	object_preview = Control.new()
	object_preview.name = "object_preview"
	object_preview.custom_minimum_size = Vector2(198.0, 198.0)
	object_preview.tooltip_text = "Clipboard preview: the copied object, or the group's relative layout and distances. Click to open the object browser."
	object_preview.mouse_filter = Control.MOUSE_FILTER_STOP
	object_preview.draw.connect(_draw_object_preview)
	object_preview.gui_input.connect(_on_object_preview_input)
	page.add_child(object_preview)

	var name_label := Label.new()
	name_label.name = "object_name_label"
	name_label.text = "Clipboard: empty"
	name_label.add_theme_font_size_override("font_size", 11)
	name_label.add_theme_color_override("font_color", Color(0.78, 0.82, 0.88))
	name_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	name_label.custom_minimum_size = Vector2(0.0, 34.0)
	page.add_child(name_label)

	var browse_row := HBoxContainer.new()
	browse_row.add_theme_constant_override("separation", 6)
	page.add_child(browse_row)
	object_browse_button = Button.new()
	object_browse_button.text = "Browse objects\u2026"
	object_browse_button.tooltip_text = "List every object scene in the world folder; clicking one copies it to the clipboard"
	object_browse_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	browse_row.add_child(object_browse_button)
	browse_row.add_child(_spacer())

	var hint := Label.new()
	# No Paste button: pasting is a viewport gesture (Ctrl+V drops the clipboard
	# under the mouse), so the button only ever duplicated a shortcut that has to
	# be used in the viewport anyway - the one place the button is not visible.
	hint.text = "Ctrl+C copies the selected scene objects. Ctrl+V in the viewport drops them on the terrain under the mouse."
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(hint)
	return page

func _make_settings_page() -> Control:
	var page := VBoxContainer.new()
	page.add_theme_constant_override("separation", 8)

	var file_head := Label.new()
	file_head.text = "File"
	file_head.add_theme_font_size_override("font_size", 13)
	file_head.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	page.add_child(file_head)

	var file_row := HBoxContainer.new()
	file_row.add_theme_constant_override("separation", 6)
	page.add_child(file_row)
	load_button = Button.new()
	load_button.text = "Load .wmt"
	load_button.tooltip_text = "Load a .wmt terrain file"
	file_row.add_child(load_button)
	save_button = Button.new()
	save_button.text = "Save .wmt"
	save_button.tooltip_text = "Save the terrain (one .wmt file per chunk)"
	file_row.add_child(save_button)
	file_row.add_child(_spacer())

	var wf_head := Label.new()
	wf_head.text = "Wireframe"
	wf_head.add_theme_font_size_override("font_size", 13)
	wf_head.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	page.add_child(wf_head)

	# Wireframe grid + its black/white switch share one row - they are two
	# settings of the same thing, so they read better side by side than as two
	# stacked lines with a "Grid colors" heading in between.
	var wf_row := HBoxContainer.new()
	wf_row.add_theme_constant_override("separation", 10)
	page.add_child(wf_row)
	wireframe_button = CheckBox.new()
	wireframe_button.text = "Wireframe grid"
	wireframe_button.tooltip_text = "Light the terrain cell edges with the wireframe shader"
	wireframe_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wf_row.add_child(wireframe_button)
	# CheckButton is Godot's switch-style toggle (it slides), not a CheckBox.
	bw_button = CheckButton.new()
	bw_button.text = "Black / White"
	bw_button.tooltip_text = "Toggle wireframe grid edges between white and black"
	bw_button.custom_minimum_size = Vector2(0.0, 0.0)
	wf_row.add_child(bw_button)

	var thick_row := HBoxContainer.new()
	thick_row.add_theme_constant_override("separation", 10)
	page.add_child(thick_row)
	var thick_label := Label.new()
	thick_label.text = "Thickness"
	thick_label.custom_minimum_size = Vector2(90.0, 0.0)
	thick_row.add_child(thick_label)
	thick_spin = SpinBox.new()
	thick_spin.min_value = 0.0
	thick_spin.max_value = 6.0
	thick_spin.step = 0.5
	thick_spin.value = 1.0
	thick_spin.tooltip_text = "Wireframe grid thickness"
	thick_spin.custom_minimum_size = Vector2(84.0, 0.0)
	thick_row.add_child(thick_spin)
	thick_row.add_child(_spacer())

	# Tile lines: the WMT chunk/tile lattice, with its own thickness next to the
	# label instead of sharing the wireframe thickness above.
	var tile_row := HBoxContainer.new()
	tile_row.add_theme_constant_override("separation", 10)
	page.add_child(tile_row)
	grid_check = CheckBox.new()
	grid_check.text = "Tile lines"
	grid_check.tooltip_text = "Show the blue chunk-lattice and red tile-lattice lines (same toggle as the toolbar)"
	grid_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tile_row.add_child(grid_check)
	tile_thick_spin = SpinBox.new()
	tile_thick_spin.min_value = 0.0
	tile_thick_spin.max_value = 6.0
	tile_thick_spin.step = 0.5
	tile_thick_spin.value = 1.0
	tile_thick_spin.tooltip_text = "Tile line thickness"
	tile_thick_spin.custom_minimum_size = Vector2(84.0, 0.0)
	tile_row.add_child(tile_thick_spin)
	tile_row.add_child(_spacer())

	var light_head := Label.new()
	light_head.text = "Lighting"
	light_head.add_theme_font_size_override("font_size", 13)
	light_head.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	light_head.tooltip_text = "Lighting controls drive the scene's directional light node live (an existing DirectionalLight3D in the scene, or the auto-created \"WMT Sun\")."
	page.add_child(light_head)
	# The lighting page controls the scene's DirectionalLight3D node directly:
	# color, energy, indirect energy and shadows. The terrain is lit by real
	# Godot lighting, so these properties update the light itself (no shader
	# uniforms anymore).
	var sun_row := HBoxContainer.new()
	sun_row.add_theme_constant_override("separation", 10)
	page.add_child(sun_row)
	var sun_label := Label.new()
	sun_label.text = "Sun"
	sun_label.custom_minimum_size = Vector2(90.0, 0.0)
	sun_row.add_child(sun_label)
	sun_color_button = ColorPickerButton.new()
	sun_color_button.color = Color.WHITE
	sun_color_button.tooltip_text = "Light color: tints everything the sun lights (e.g. warm orange at sunset)"
	sun_color_button.custom_minimum_size = Vector2(80.0, 0.0)
	sun_row.add_child(sun_color_button)
	sun_energy_slider = HSlider.new()
	sun_energy_slider.min_value = 0.0
	sun_energy_slider.max_value = 3.0
	sun_energy_slider.step = 0.01
	sun_energy_slider.value = 1.5
	sun_energy_slider.custom_minimum_size = Vector2(110.0, 0.0)
	sun_energy_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sun_energy_slider.tooltip_text = "Light energy: overall brightness of the sun"
	sun_row.add_child(sun_energy_slider)
	var sun_val := Label.new()
	sun_val.text = "1.50"
	sun_val.custom_minimum_size = Vector2(36.0, 0.0)
	sun_row.add_child(sun_val)
	sun_energy_slider.value_changed.connect(func(v: float) -> void:
		sun_val.text = "%.2f" % v
		if _syncing:
			return
		sun_energy_changed.emit(v))
	sun_row.add_child(_spacer())

	var shadow_row := HBoxContainer.new()
	shadow_row.add_theme_constant_override("separation", 10)
	page.add_child(shadow_row)
	var shadow_label := Label.new()
	shadow_label.text = "Shadows"
	shadow_label.custom_minimum_size = Vector2(90.0, 0.0)
	shadow_row.add_child(shadow_label)
	sun_shadow_check = CheckBox.new()
	sun_shadow_check.text = "Cast"
	sun_shadow_check.button_pressed = false
	sun_shadow_check.tooltip_text = "Cast shadows from the sun. Off by default: directional shadow cascades re-fit to the camera, so the shadow pattern shifts as you orbit the view."
	sun_shadow_check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shadow_row.add_child(sun_shadow_check)
	shadow_row.add_child(_spacer())

	# Shadow distance: how far from the camera shadows are still drawn. A small
	# value keeps the cascades tight (crisper near the view) and is much cheaper
	# than a huge range, at the cost of shadows popping out further away.
	var shadow_dist_row := HBoxContainer.new()
	shadow_dist_row.add_theme_constant_override("separation", 10)
	page.add_child(shadow_dist_row)
	var shadow_dist_label := Label.new()
	shadow_dist_label.text = "Distance"
	shadow_dist_label.custom_minimum_size = Vector2(90.0, 0.0)
	shadow_dist_row.add_child(shadow_dist_label)
	sun_shadow_dist_spin = SpinBox.new()
	sun_shadow_dist_spin.min_value = 0.0
	sun_shadow_dist_spin.max_value = 500.0
	sun_shadow_dist_spin.step = 1.0
	sun_shadow_dist_spin.value = 100.0
	sun_shadow_dist_spin.tooltip_text = "Shadow distance: how far away shadows are still drawn (meters)"
	sun_shadow_dist_spin.custom_minimum_size = Vector2(110.0, 0.0)
	shadow_dist_row.add_child(sun_shadow_dist_spin)
	shadow_dist_row.add_child(_spacer())

	# Shadow resolution: the shadow atlas size. Bigger = crisper shadows and a
	# much bigger memory/GPU cost, so this is a slider over the four sizes Godot
	# supports rather than a free-form number.
	var shadow_res_row := HBoxContainer.new()
	shadow_res_row.add_theme_constant_override("separation", 10)
	page.add_child(shadow_res_row)
	var shadow_res_label := Label.new()
	shadow_res_label.text = "Resolution"
	shadow_res_label.custom_minimum_size = Vector2(90.0, 0.0)
	shadow_res_row.add_child(shadow_res_label)
	sun_shadow_res_slider = HSlider.new()
	sun_shadow_res_slider.min_value = 0.0
	sun_shadow_res_slider.max_value = 3.0
	sun_shadow_res_slider.step = 1.0
	sun_shadow_res_slider.value = 2.0
	sun_shadow_res_slider.custom_minimum_size = Vector2(110.0, 0.0)
	sun_shadow_res_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sun_shadow_res_slider.tooltip_text = "Shadow resolution: shadow atlas size (2048 / 4096 / 8192 / 16384)"
	shadow_res_row.add_child(sun_shadow_res_slider)
	var shadow_res_val := Label.new()
	shadow_res_val.text = "8192"
	shadow_res_val.custom_minimum_size = Vector2(56.0, 0.0)
	shadow_res_row.add_child(shadow_res_val)
	sun_shadow_res_slider.value_changed.connect(func(v: float) -> void:
		shadow_res_val.text = _shadow_atlas_label(int(v))
		if _syncing:
			return
		sun_shadow_resolution_changed.emit(int(v)))
	shadow_res_row.add_child(_spacer())

	# Ambient / sky: the environment light that fills everything the sun does
	# not reach. Without it the terrain's unlit sides go pure black, which is
	# what made the WMT look wrong next to imported world objects.
	var env_head := Label.new()
	env_head.text = "Environment"
	env_head.add_theme_font_size_override("font_size", 13)
	env_head.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	env_head.tooltip_text = "Drives the edited scene's WorldEnvironment → Environment (an existing WorldEnvironment, or an auto-created \"WMT Environment\")."
	page.add_child(env_head)

	var amb_row := HBoxContainer.new()
	amb_row.add_theme_constant_override("separation", 10)
	page.add_child(amb_row)
	var amb_label := Label.new()
	amb_label.text = "Ambient"
	amb_label.custom_minimum_size = Vector2(90.0, 0.0)
	amb_row.add_child(amb_label)
	env_ambient_button = ColorPickerButton.new()
	env_ambient_button.color = Color(0.42, 0.47, 0.55)
	env_ambient_button.tooltip_text = "Ambient light color: the flat fill color light that reaches every surface (sky bounce)"
	env_ambient_button.custom_minimum_size = Vector2(80.0, 0.0)
	amb_row.add_child(env_ambient_button)
	env_ambient_button.color_changed.connect(func(c: Color) -> void:
		if _syncing:
			return
		env_ambient_color_changed.emit(c))
	env_ambient_slider = HSlider.new()
	env_ambient_slider.min_value = 0.0
	env_ambient_slider.max_value = 3.0
	env_ambient_slider.step = 0.01
	env_ambient_slider.value = 1.0
	env_ambient_slider.custom_minimum_size = Vector2(110.0, 0.0)
	env_ambient_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	env_ambient_slider.tooltip_text = "Ambient energy: brightness of the flat fill light"
	amb_row.add_child(env_ambient_slider)
	var amb_val := Label.new()
	amb_val.text = "1.00"
	amb_val.custom_minimum_size = Vector2(36.0, 0.0)
	amb_row.add_child(amb_val)
	env_ambient_slider.value_changed.connect(func(v: float) -> void:
		amb_val.text = "%.2f" % v
		if _syncing:
			return
		env_ambient_energy_changed.emit(v))
	amb_row.add_child(_spacer())

	var sky_row := HBoxContainer.new()
	sky_row.add_theme_constant_override("separation", 10)
	page.add_child(sky_row)
	var sky_label := Label.new()
	sky_label.text = "Skylight"
	sky_label.custom_minimum_size = Vector2(90.0, 0.0)
	sky_row.add_child(sky_label)
	env_sky_slider = HSlider.new()
	env_sky_slider.min_value = 0.0
	env_sky_slider.max_value = 1.0
	env_sky_slider.step = 0.01
	env_sky_slider.value = 0.5
	env_sky_slider.custom_minimum_size = Vector2(191.0, 0.0)
	env_sky_slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	env_sky_slider.tooltip_text = "Skylight: how much of the ambient comes from the sky instead of the color below (0 = color only, 1 = all sky)"
	sky_row.add_child(env_sky_slider)
	var sky_val := Label.new()
	sky_val.text = "1.00"
	sky_val.custom_minimum_size = Vector2(36.0, 0.0)
	sky_row.add_child(sky_val)
	env_sky_slider.value_changed.connect(func(v: float) -> void:
		sky_val.text = "%.2f" % v
		if _syncing:
			return
		env_sky_energy_changed.emit(v))
	sky_row.add_child(_spacer())

	var brush_head := Label.new()
	brush_head.text = "Brush"
	brush_head.add_theme_font_size_override("font_size", 13)
	brush_head.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	page.add_child(brush_head)

	var color_row := HBoxContainer.new()
	color_row.add_theme_constant_override("separation", 10)
	page.add_child(color_row)
	var color_label := Label.new()
	color_label.text = "Color"
	color_label.custom_minimum_size = Vector2(90.0, 0.0)
	color_row.add_child(color_label)
	brush_color_button = ColorPickerButton.new()
	brush_color_button.color = Color(1.0, 0.3, 0.25)
	brush_color_button.tooltip_text = "Color of the brush cursor rings"
	brush_color_button.custom_minimum_size = Vector2(80.0, 0.0)
	color_row.add_child(brush_color_button)
	color_row.add_child(_spacer())

	var thick_row2 := HBoxContainer.new()
	thick_row2.add_theme_constant_override("separation", 10)
	page.add_child(thick_row2)
	var bthick_label := Label.new()
	bthick_label.text = "Thickness"
	bthick_label.custom_minimum_size = Vector2(90.0, 0.0)
	thick_row2.add_child(bthick_label)
	brush_thick_spin = SpinBox.new()
	brush_thick_spin.min_value = 0.02
	brush_thick_spin.max_value = 2.0
	brush_thick_spin.step = 0.05
	brush_thick_spin.value = 0.2
	brush_thick_spin.tooltip_text = "Width of the brush cursor ring in world units"
	brush_thick_spin.custom_minimum_size = Vector2(84.0, 0.0)
	thick_row2.add_child(brush_thick_spin)
	thick_row2.add_child(_spacer())

	var kb_head := Label.new()
	kb_head.text = "Keybinds"
	kb_head.add_theme_font_size_override("font_size", 13)
	kb_head.add_theme_color_override("font_color", Color(0.85, 0.9, 1.0))
	page.add_child(kb_head)

	page.add_child(_keybinds_button())

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	page.add_child(spacer)
	return page

# --- Object clipboard preview -------------------------------------------------
# The object stamp draws the same idea as the paint channel preview: whatever is
# on the clipboard, at the same scale, so you can see what will land before you
# click the terrain. One object = a single footprint (sized from the object, so
# a big tree looks big). A group = a top-down scatter of every member at its
# true offset from the group pivot, with the group pivot marked, which is what
# makes the relative distances (and the shape of the copy) readable.
func set_object_clipboard(entries: Array) -> void:
	object_clipboard = entries
	if object_preview != null:
		object_preview.queue_redraw()
	var lbl := _object_name_label()
	if lbl != null:
		if entries.is_empty():
			lbl.text = "Clipboard: empty"
		elif entries.size() == 1:
			lbl.text = str(entries[0].get("name", "?"))
		else:
			lbl.text = "Group of %d objects" % entries.size()

func _object_name_label() -> Label:
	var page := object_preview.get_parent() if object_preview != null else null
	if page == null:
		return null
	return page.get_node_or_null("object_name_label") as Label

func _on_object_preview_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb != null and mb.pressed and mb.button_index == MOUSE_BUTTON_LEFT:
		object_browse_requested.emit()
		accept_event()

func _draw_object_preview() -> void:
	var c := object_preview
	if c == null:
		return
	var r := Rect2(Vector2.ZERO, c.size)
	# Background + border, same neutral fill the flat paint swatch uses so the
	# box reads as a stamp rather than part of the page.
	c.draw_rect(r, Color(0.12, 0.13, 0.15, 0.9), true)
	c.draw_rect(r, Color(0.35, 0.39, 0.44, 0.9), false, 1.0)
	if object_clipboard.is_empty():
		var font := c.get_theme_default_font()
		if font != null:
			var fs := 12
			var txt := "No object copied"
			var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			c.draw_string(font, Vector2((r.size.x - tw) * 0.5, r.size.y * 0.5),
				txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0.55, 0.57, 0.6))
			var hint2 := "Ctrl+C in the scene, or click to browse"
			var hw := font.get_string_size(hint2, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			c.draw_string(font, Vector2((r.size.x - hw) * 0.5, r.size.y * 0.5 + 15.0),
				hint2, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.42, 0.44, 0.47))
		return
	# Work in the XZ plane, centred on the group pivot (offset 0,0 is the pivot
	# for a group, the origin for a single object).
	var offsets: Array[Vector2] = []
	var radii: Array[float] = []
	for e in object_clipboard:
		var off: Vector3 = e.get("offset", Vector3.ZERO)
		offsets.append(Vector2(off.x, off.z))
		radii.append(maxf(0.35, float(e.get("radius", 1.0))))
	var span := 1.0
	for i in offsets.size():
		span = maxf(span, absf(offsets[i].x) + radii[i])
		span = maxf(span, absf(offsets[i].y) + radii[i])
	# Fit with a margin so the outermost footprint never touches the border.
	var margin := 10.0
	var scale := minf((r.size.x - margin * 2.0) * 0.5 / span,
		(r.size.y - margin * 2.0) * 0.5 / span)
	var mid := r.size * 0.5
	var to_px := func(o: Vector2) -> Vector2:
		return mid + Vector2(o.x, o.y) * scale
	# Axes through the pivot: the paste point.
	c.draw_line(to_px.call(Vector2(-span, 0.0)), to_px.call(Vector2(span, 0.0)),
		Color(0.30, 0.33, 0.37, 0.8), 1.0)
	c.draw_line(to_px.call(Vector2(0.0, -span)), to_px.call(Vector2(0.0, span)),
		Color(0.30, 0.33, 0.37, 0.8), 1.0)
	# Group members are tinted per index and joined by lines so the spacing
	# between them is obvious even when the footprints do not touch.
	var font := c.get_theme_default_font()
	for i in offsets.size():
		var col := _preview_tint(i)
		if i > 0:
			c.draw_line(to_px.call(offsets[0]), to_px.call(offsets[i]),
				Color(col.r, col.g, col.b, 0.35), 1.0)
	for i in offsets.size():
		var col := _preview_tint(i)
		var p := to_px.call(offsets[i])
		var rad := radii[i] * scale
		c.draw_circle(p, rad, Color(col.r, col.g, col.b, 0.35))
		c.draw_arc(p, rad, 0.0, TAU, 24, col, 1.0)
		if rad < 3.0:
			c.draw_circle(p, 1.5, col)
	# The pivot marker: this is the point that follows the mouse on paste, and
	# for a single object it is the object's own origin (not its center).
	var pivot := to_px.call(Vector2.ZERO)
	c.draw_line(pivot + Vector2(-4.0, 0.0), pivot + Vector2(4.0, 0.0),
		Color(1.0, 0.85, 0.3, 0.95), 1.0)
	c.draw_line(pivot + Vector2(0.0, -4.0), pivot + Vector2(0.0, 4.0),
		Color(1.0, 0.85, 0.3, 0.95), 1.0)
	if font != null and object_clipboard.size() > 1:
		# Distance labels between each member and the pivot, in world units.
		for i in offsets.size():
			if offsets[i].is_zero_approx():
				continue
			var d := offsets[i].length()
			var lp: Vector2 = (pivot + to_px.call(offsets[i])) * 0.5
			var txt := "%.1f" % d
			var tw := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
			c.draw_string(font, lp + Vector2(-tw * 0.5, -3.0), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(0.85, 0.88, 0.92, 0.9))
	if font != null and object_clipboard.size() == 1:
		var e0: Dictionary = object_clipboard[0]
		var nm := str(e0.get("name", "")).get_file().get_basename()
		var nw := font.get_string_size(nm, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		c.draw_string(font, Vector2(mid.x - nw * 0.5, r.size.y - 6.0), nm,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(0.85, 0.88, 0.92, 0.95))
		var hint2 := "origin \u2192 cursor"
		var hw := font.get_string_size(hint2, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		c.draw_string(font, Vector2(mid.x - hw * 0.5, 14.0), hint2,
			HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.85, 0.3, 0.8))

func _preview_tint(i: int) -> Color:
	var tints := [Color(0.55, 0.78, 1.0), Color(0.62, 0.9, 0.6), Color(1.0, 0.76, 0.5),
		Color(0.95, 0.62, 0.85), Color(0.7, 0.9, 0.9), Color(0.9, 0.9, 0.6)]
	return tints[i % tints.size()]

func _placeholder(hint: String) -> Control:
	var page := VBoxContainer.new()
	var label := Label.new()
	label.text = hint
	label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	page.add_child(label)
	return page

# Keybinds, grouped by the mode they belong to. Kept as data so the searchable
# window can filter them, and so a binding is described in exactly one place.
# The vertex-paint eraser swatch. Duplicated from WmtScript.VERTEX_TINT_ERASER
# because the panel must not preload the terrain script just to paint a swatch.
const ERASER_COLOR := Color(0.5, 0.5, 0.5, 1.0)

const KEYBIND_GROUPS := [
	{"mode": "Sculpt", "binds": [
		["raise", "Shift+LMB"],
		["lower", "Ctrl+LMB"],
		["smooth", "Alt+LMB"],
		["Undo / redo", "Ctrl+Z / Ctrl+Y"],
	]},
	{"mode": "Paint", "binds": [
		["select tiles", "Alt+LMB (drag)"],
		["paint", "Shift+LMB"],
		["eyedrop channel", "Ctrl+LMB"],
		["channel picker", "Ctrl+RMB"],
		["select every tile in the chunk", "Alt+RMB"],
	]},
	{"mode": "Vertex color", "binds": [
		["paint the picked color", "Shift+LMB"],
		["paint the eraser (50% gray)", "Shift+RMB"],
		["eyedrop color", "Ctrl+LMB"],
		["color selector", "Ctrl+RMB"],
		["eraser swatch", "the Erase button, or the selector"],
	]},
	{"mode": "Chunks", "binds": [
		["hide / show tiles", "LMB (drag with the brush)"],
		["add a chunk", "Shift+LMB"],
		["delete a chunk", "Shift+RMB"],
	]},
	{"mode": "Objects", "binds": [
		["model viewer (browse + preview)", "Ctrl+RMB"],
		["browse objects", "the Browse objects button"],
		["copy the selected scene objects", "Ctrl+C"],
		["paste onto the terrain", "Ctrl+V"],
	]},
	{"mode": "Brush", "binds": [
		["radius", "Ctrl+wheel"],
		["falloff", "Shift+wheel"],
		["strength", "Alt+wheel"],
		["spray rate", "Every, under Spray paint"],
	]},
	{"mode": "General", "binds": [
		["close popup", "ESC"],
		["keybinds", "the Keybinds button, in Settings"],
	]},
]

# One button that opens a searchable window: a long keybind list does not belong
# inline in the settings page, and the list is long enough that users need to
# search it rather than scroll.
func _keybinds_button() -> Control:
	var box := VBoxContainer.new()
	box.name = "keybinds_box"
	var btn := Button.new()
	btn.name = "keybinds_open"
	btn.text = "Keybinds  \u25B8"
	btn.tooltip_text = "Open the keybind list (searchable, grouped per mode)"
	btn.focus_mode = Control.FOCUS_NONE
	btn.pressed.connect(_open_keybinds_window)
	box.add_child(btn)
	return box

func _open_keybinds_window() -> void:
	if _keybind_window != null and is_instance_valid(_keybind_window):
		_keybind_window.popup_centered(Vector2i(520, 620))
		return
	var win := PopupPanel.new()
	# A POPUP, not a Window: it closes on an outside click and swallows that
	# click, so dismissing the list can never select a terrain tile or start a
	# stroke behind it. A separate Window needed an explicit close button and
	# left the editor's own input live while it was up.
	win.name = "WmtKeybinds"
	win.exclusive = true
	win.min_size = Vector2i(420, 320)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.13, 0.14, 0.16, 0.98)
	sb.border_color = Color(0.42, 0.47, 0.52)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(8)
	win.add_theme_stylebox_override("panel", sb)
	# Parent FIRST: a popup that is not in the tree cannot be shown, and the
	# build below is long enough that an early return would otherwise leave a
	# fully built window that was never added.
	add_child(win)
	var root_box := VBoxContainer.new()
	root_box.add_theme_constant_override("separation", 6)
	win.add_child(root_box)

	var search := LineEdit.new()
	search.name = "keybind_search"
	search.placeholder_text = "Search keybinds\u2026"
	search.clear_button_enabled = true
	root_box.add_child(search)

	var scroll := ScrollContainer.new()
	scroll.name = "keybind_scroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	root_box.add_child(scroll)

	var list := VBoxContainer.new()
	list.name = "keybind_list"
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)

	# One collapsible section per mode, each row "action  ....  keys". Built
	# from a toggle button plus a body because this Godot build has no
	# FoldContainer; the header label is what the search matches against.
	for g in KEYBIND_GROUPS:
		var mode := str(g["mode"])
		var section := VBoxContainer.new()
		section.name = "keybind_group_%s" % mode.to_lower().replace(" ", "_")
		section.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.set_meta("title_label", mode)
		list.add_child(section)
		var head := Button.new()
		head.name = "keybind_head"
		head.text = "\u25BE " + mode
		head.toggle_mode = true
		head.button_pressed = true
		head.alignment = HORIZONTAL_ALIGNMENT_LEFT
		head.focus_mode = Control.FOCUS_NONE
		section.add_child(head)
		var body := VBoxContainer.new()
		body.name = "keybind_body"
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		section.add_child(body)
		head.toggled.connect(func(on: bool) -> void:
			body.visible = on
			head.text = ("\u25BE " + mode) if on else ("\u25B8 " + mode))
		for entry in g["binds"]:
			var row := HBoxContainer.new()
			row.name = "keybind_row"
			row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var what := Label.new()
			what.text = str(entry[0])
			what.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(what)
			var keys := Label.new()
			keys.text = str(entry[1])
			keys.add_theme_color_override("font_color", Color(0.65, 0.8, 1.0))
			row.add_child(keys)
			body.add_child(row)

	_keybind_window = win
	_keybind_search = search
	_keybind_groups = list
	search.text_changed.connect(_filter_keybinds)
	win.popup_centered(Vector2i(520, 620))

# Filter the sections by mode, and each row by action or key. Hiding a section
# when nothing in it matches keeps the window from showing empty headers.
func _filter_keybinds(query: String) -> void:
	var q := query.strip_edges().to_lower()
	if _keybind_groups == null or not is_instance_valid(_keybind_groups):
		return
	for section in _keybind_groups.get_children():
		var mode := str(section.get_meta("title_label", ""))
		var mode_hit := q == "" or mode.to_lower().contains(q)
		var any_row := false
		var body: Control = null
		for c in section.get_children():
			if c.name == "keybind_body":
				body = c
				break
		if body == null:
			continue
		for row in body.get_children():
			# Match on both the action and the key combination, so "ctrl" and
			# "eyedrop" both find the eyedropper row.
			var text := mode.to_lower() + " " + mode
			for lbl in row.get_children():
				if lbl is Label:
					text += " " + (lbl as Label).text.to_lower()
			var hit := mode_hit or text.contains(q)
			row.visible = hit
			if hit:
				any_row = true
		# A collapsed section whose header matched the query still shows, so
		# searching "paint" reveals the Paint header even with no row inside.
		section.visible = any_row or mode_hit

func _select_channel(index: int, emit: bool) -> void:
	paint_channel = index
	_update_splat_square()
	if emit:
		paint_channel_selected.emit(index)

func _update_splat_square() -> void:
	_update_tex_button(splat_square, paint_channel, "Channel")

# White/black side is gone: each channel is now its own splat plane, so the
# swatch is neutral and just shows the assigned texture (or "no texture").

# Each channel is its own splat plane; the assigned texture (or flat color) is
# shown as the icon.
func _update_tex_button(btn: Button, slot: int, who: String) -> void:
	if btn == null:
		return
	var path := ""
	if slot >= 0 and slot < paint_channel_textures.size():
		path = paint_channel_textures[slot]
	btn.icon = null
	btn.expand_icon = false
	if path != "" and ResourceLoader.exists(path):
		var tex := load(path) as Texture2D
		if tex != null:
			btn.icon = tex
			btn.expand_icon = true
	var white := (slot % 2) == 0
	var sbs := StyleBoxFlat.new()
	# No background behind a real texture preview: the thumbnail is the whole
	# control, so the stamp shows the texture alone (a dark box behind it was
	# just noise). Only the flat-color (untextured) state keeps a neutral fill
	# so the swatch stays clickable/visible.
	if btn.icon != null:
		sbs.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	else:
		sbs.bg_color = Color(0.14, 0.15, 0.17)
	sbs.set_corner_radius_all(2)
	sbs.set_border_width_all(1)
	sbs.border_color = Color(1.0, 1.0, 1.0, 0.18)
	btn.add_theme_stylebox_override("normal", sbs)
	btn.add_theme_stylebox_override("hover", sbs)
	btn.add_theme_stylebox_override("pressed", sbs)
	btn.add_theme_stylebox_override("focus", sbs)
	var name: String = who
	if slot < PAINT_CHANNEL_NAMES.size():
		name = PAINT_CHANNEL_NAMES[slot]
	if path != "":
		btn.tooltip_text = "%s \u2014 texture: %s\nClick to assign a different tileset texture" % [name, path]
	else:
		btn.tooltip_text = "%s \u2014 flat %s (no texture).\nClick to assign a tileset texture" % [name, "white" if white else "black"]

func _spacer() -> Control:
	var s := Control.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return s

func set_wireframe_state(on: bool, black: bool, thickness: float) -> void:
	if wireframe_button != null:
		wireframe_button.button_pressed = on
	if bw_button != null:
		bw_button.button_pressed = black
	if thick_spin != null:
		thick_spin.value = thickness

func set_brush_state(color: Color, thickness: float) -> void:
	if brush_color_button != null:
		brush_color_button.color = color
	if brush_thick_spin != null:
		brush_thick_spin.value = thickness

func set_grid_state(on: bool) -> void:
	if grid_check != null:
		grid_check.set_pressed_no_signal(on)

func set_paint_channel(index: int) -> void:
	_select_channel(clampi(index, 0, PAINT_CHANNEL_NAMES.size() - 1), false)
	_update_splat_square()

func get_paint_channel() -> int:
	return paint_channel

func set_paint_depth(value: float) -> void:
	if depth_spin != null:
		depth_spin.set_value_no_signal(value)

func set_paint_channel_textures(textures: Array[String]) -> void:
	paint_channel_textures = textures.duplicate() if textures != null else []
	_update_splat_square()

func set_paint_state(opacity: float, flow: float, spacing: float, spray_on: bool = true, spray_interval: float = 0.05) -> void:
	if paint_opacity_spin != null:
		paint_opacity_spin.value = opacity
	if paint_flow_spin != null:
		paint_flow_spin.value = flow
	if paint_spacing_spin != null:
		paint_spacing_spin.value = spacing
	set_spray_state(spray_on)
	if paint_spray_interval_spin != null:
		paint_spray_interval_spin.value = spray_interval

func set_spray_state(on: bool) -> void:
	if paint_spray_check != null:
		paint_spray_check.button_pressed = on
	if paint_spray_interval_spin != null:
		paint_spray_interval_spin.editable = on
		paint_spray_interval_spin.modulate = Color(1.0, 1.0, 1.0) if on else Color(0.6, 0.6, 0.6)

func get_sculpt_tool() -> int:
	if set_height_radio != null and set_height_radio.button_pressed:
		return TOOL_SET_HEIGHT
	if smooth_radio != null and smooth_radio.button_pressed:
		return TOOL_SMOOTH
	return TOOL_SCULPT

func set_sculpt_tool(tool: int) -> void:
	var is_set := tool == TOOL_SET_HEIGHT
	var is_smooth := tool == TOOL_SMOOTH
	if sculpt_radio != null and set_height_radio != null and smooth_radio != null:
		sculpt_radio.set_pressed_no_signal(not is_set and not is_smooth)
		set_height_radio.set_pressed_no_signal(is_set)
		smooth_radio.set_pressed_no_signal(is_smooth)
	if set_height_box != null:
		set_height_box.visible = is_set
	if smooth_tool_box != null:
		smooth_tool_box.visible = is_smooth

func get_smooth_tool() -> int:
	if smooth_tool_raise != null and smooth_tool_raise.button_pressed:
		return SMOOTH_TOOL_RAISE
	if smooth_tool_flatten != null and smooth_tool_flatten.button_pressed:
		return SMOOTH_TOOL_FLATTEN
	if smooth_tool_lower != null and smooth_tool_lower.button_pressed:
		return SMOOTH_TOOL_LOWER
	return SMOOTH_TOOL_SMOOTH

func set_smooth_tool(tool: int) -> void:
	if smooth_tool_raise != null:
		smooth_tool_raise.set_pressed_no_signal(tool == SMOOTH_TOOL_RAISE)
	if smooth_tool_flatten != null:
		smooth_tool_flatten.set_pressed_no_signal(tool == SMOOTH_TOOL_FLATTEN)
	if smooth_tool_smooth != null:
		smooth_tool_smooth.set_pressed_no_signal(tool == SMOOTH_TOOL_SMOOTH)
	if smooth_tool_lower != null:
		smooth_tool_lower.set_pressed_no_signal(tool == SMOOTH_TOOL_LOWER)

func set_sun(color: Color, energy: float, shadow: bool) -> void:
	_syncing = true
	if sun_color_button != null:
		sun_color_button.color = color
	if sun_energy_slider != null:
		sun_energy_slider.value = energy
	if sun_shadow_check != null:
		sun_shadow_check.button_pressed = shadow
	_syncing = false

# Shadow distance / resolution and the tile-line thickness are their own
# pushes, so the plugin can refresh them independently of the sun row.
func set_shadow_extras(distance: float, res_index: int) -> void:
	_syncing = true
	if sun_shadow_dist_spin != null:
		sun_shadow_dist_spin.value = distance
	if sun_shadow_res_slider != null:
		sun_shadow_res_slider.value = clampi(res_index, 0, SHADOW_ATLAS_SIZES.size() - 1)
	_syncing = false

func set_tile_line_thickness(value: float) -> void:
	_syncing = true
	if tile_thick_spin != null:
		tile_thick_spin.value = value
	_syncing = false

# Push the current environment state back into the controls (used at startup
# and when the plugin re-reads the scene's WorldEnvironment).
func set_env_state(ambient: Color, energy: float, sky: float) -> void:
	_syncing = true
	if env_ambient_button != null:
		env_ambient_button.color = ambient
	if env_ambient_slider != null:
		env_ambient_slider.value = energy
	if env_sky_slider != null:
		env_sky_slider.value = sky
	_syncing = false

func update_radius_label(r: float) -> void:
	if radius_spin == null and radius_spin_paint == null:
		return
	_syncing = true
	if radius_spin != null:
		radius_spin.value = r
	if radius_spin_paint != null:
		radius_spin_paint.value = r
	_syncing = false
	var radius_label := _find_node("cursor_radius_label")
	if radius_label is Label:
		radius_label.text = "Cursor radius: %.2f" % r

func update_falloff_label(t: float) -> void:
	if falloff_spin == null and falloff_spin_paint == null:
		return
	_syncing = true
	var pct := t * 100.0
	if falloff_spin != null:
		falloff_spin.value = pct
	if falloff_spin_paint != null:
		falloff_spin_paint.value = pct
	_syncing = false
	var ff := _find_node("cursor_falloff_label")
	if ff is Label:
		var shape := "cone"
		if t >= 0.666:
			shape = "cylinder"
		elif t >= 0.333:
			shape = "dome"
		ff.text = "Falloff: %d%%  (%s)" % [int(round(t * 100.0)), shape]

func update_strength_label(s: float) -> void:
	if strength_spin == null:
		return
	_syncing = true
	strength_spin.value = s * 100.0
	_syncing = false
	var st := _find_node("cursor_strength_label")
	if st is Label:
		st.text = "Strength: %d%%" % int(round(s * 100.0))

func set_terrain_active(active: bool) -> void:
	if load_button != null:
		load_button.disabled = not active
	if save_button != null:
		save_button.disabled = not active

func _find_node(node_name: String) -> Control:
	if not is_inside_tree():
		return null
	return find_child(node_name, true, false) as Control

func _on_wireframe_pressed(on: bool) -> void:
	wireframe_toggled.emit(on)
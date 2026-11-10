@tool
@icon("res://wmt/icon_wmt.svg")
class_name WMT
extends MeshInstance3D

# A WMT (World Map Tile) is ONE node that holds one or more rectangular
# terrain regions called "chunks". Every chunk is a 16x16 tile block
# (256x256 world units) placed on the chunk lattice, and each tile is an
# 8x8 block of squares. All chunks of a node share a single continuous
# heightmap grid, so sculpting flows seamlessly across chunk borders, the
# grid itself knows which chunks exist (and therefore where new ones may be
# placed), and one wireframe covers the lot.
#
#  wmt    = node with N chunks
#  chunk  = 16 x 16 tiles (256 x 256 world units, 128 x 128 squares)
#  tile   = 8 x 8 squares (16 x 16 world units)  <- hide/show unit, red grid unit
#  square = 2 x 2 world units, 4 triangles (X pattern, 1 central vertex)
#
# Every square corner AND every square center carry their own height. Both
# are sculptable (corner heights live in `heightmap`, centers in `center_h`).
# The corner grid is stored as a full (G+1) x (G+1) lattice, so border and
# inter-chunk seam corners are real, sculptable vertices instead of reading
# out-of-row garbage. Saved as a compact binary ".wmt" file.
#
# The rendered mesh uses a FIXED vertex layout: every grid cell always owns
# exactly 5 vertices (TL/TR/BR/BL/center) at mesh index ci*5..ci*5+4, and the
# index buffer is static (8 triangles per cell, built once per grid). Cells
# that belong to no existing chunk, or are hidden, are collapsed to a
# degenerate single point (zero-area), so the surface shows only real chunks
# and hidden tiles vanish — while the buffer layout never changes. That makes
# per-tile hide/show a cheap in-place vertex patch and the wireframe an O(cells)
# topology, and lets the incremental sculpt writer address any vertex by
# (cell, slot) = (vi / 5, vi % 5) with no per-build reverse map. The node IS
# the mesh (extends MeshInstance3D), so nothing needs to be added underneath
# it.

# Tiles per chunk side (16 x 16 tiles = 256 x 256 units).
const CHUNK_TILES := 16
# Squares per tile side (tile = 8 x 8 squares = 64 squares).
const SQUARES_PER_TILE := WmtTile.SQUARES_PER_TILE
# Edge of one mesh square (the X-pattern 4-triangle quad).
const SQUARE_EDGE := WmtTile.SQUARE_EDGE
# Edge of one logical tile (= SQUARES_PER_TILE squares).
const TILE_EDGE := SQUARE_EDGE * float(SQUARES_PER_TILE)
# Cells per chunk side (128 x 128 squares).
const CHUNK_CELLS := CHUNK_TILES * SQUARES_PER_TILE
const CHUNK_WIDTH := CHUNK_CELLS * SQUARE_EDGE

const TRIANGLES_PER_CELL := 4
const VERTICES_PER_CELL := 5

# Injective int encoding for chunk-lattice keys inside _chunk_key_set:
# key(cx, cz) = (cx + _KEY_BIAS) * _KEY_STRIDE + (cz + _KEY_BIAS). Valid for
# |cx|, |cz| < _KEY_BIAS (16384 chunk slots in any direction covers far more
# than any real terrain).
const _KEY_BIAS := 16384
const _KEY_STRIDE := 32768

# Mesh-vertex "collapsed" position used for cells of absent/hidden tiles:
# every vertex degenerates to this single point so zero-area triangles draw
# nothing while the index/vertex layout stays stable.
const DEGENERATE_POS := Vector3(0.0, 0.0, 0.0)

# 1 shape edition: chunks are stored as Vector2i chunk indices. The square
# grid covers the union rectangle of all chunks with `cell_x0/z0/x1/z1`
# holding the square bounds in absolute (local-space) square coordinates.
# cell_x0/.../cell_x1 are inclusive for the corner lattice: corners exist at
# gx in [cell_x0, cell_x1].
var chunks: Array = []
var cell_x0 := 0
var cell_x1 := 0
var cell_z0 := 0
var cell_z1 := 0

# Current grid dimensions (in squares) and world size, derived from chunks.
var GRID_SQUARES_X := 0
var GRID_SQUARES_Z := 0
var TERRAIN_WIDTH := 0.0
var TERRAIN_DEPTH := 0.0

# Corner-height lattice: (GRID_SQUARES_X + 1) x (GRID_SQUARES_Z + 1) floats.
# Index for absolute corner (gx, gz) is
#   (gz - cell_z0) * (GRID_SQUARES_X + 1) + (gx - cell_x0)
# where gx in [cell_x0, cell_x1] (border corners included).
var heightmap := PackedFloat32Array()
# Monotonic stamp bumped on every height write (set_height, live vertex
# patch, clear, resize, load). The editor plugin compares this against the
# cached shading atlas so mid-stroke height edits rebuild it immediately
# instead of waiting for the next rebuild_mesh().
var height_version := 0
# Center-height array: GRID_SQUARES_X * GRID_SQUARES_Z floats (one per square).
var center_h := PackedFloat32Array()
# Per-square hide flag, uniform within each 8x8 tile block (1 = not rendered /
# not sculptable). Same grid indexing as center_h. Saved with the chunk file
# as one byte per tile so hiding persists.
var hidden_tiles := PackedByteArray()
# Static (never changes for a given grid) index buffer: 8 triangles per cell
# against the fixed vi = ci*5..ci*5+4 layout. Rebuilt only when the grid size
# changes. Lets rebuild_mesh() after a pure height edit skip index work and
# lets tile hide/show skip a full mesh rebuild entirely.
var _static_indices := PackedInt32Array()
var _static_grid_sx := 0
var _static_grid_sz := 0
# Chunk-lattice occupancy as injective int keys ((cx+BIAS)*STRIDE + (cz+BIAS)),
# refreshed when the chunk set changes. cell_emitted()/corner_emitted() consult
# it so sculpting and the wireframe never touch cells of absent chunks.
var _chunk_key_set: Dictionary = {}
# Byte stride of one vertex in the mesh's position buffer, measured from the
# surface format at build time (positions are stored consecutively, not
# interleaved with normals/tangents, so this is 12 bytes). Used to keep
# incremental surface_update_vertex_region() writes vertex-aligned.
var _vertex_stride := 12

# Per-instance terrain persistence. Empty by default so a fresh terrain stays
# flat; assign a path (plugin Save dialog) and the editor auto-restores it on
# scene open. Format is the compact binary ".wmt" (see save_wmt / load_wmt).
@export var terrain_file := ""

# Also restore terrain_file at runtime (game). Editor always auto-restores.
@export var load_in_game := false

# Flat unlit look for the terrain surface (no directional shading).
@export var flat_color := Color.WHITE

func _init() -> void:
	# A fresh WMT starts with one chunk at the origin (0,0): a 256x256 area.
	chunks = [Vector2i(0, 0)]
	_recompute_extents()
	_resize_grid(cell_x0, cell_x1, cell_z0, cell_z1, cell_x0, cell_x1, cell_z0, cell_z1)

func _ready() -> void:
	rebuild_mesh()
	_apply_flat_material()
	if Engine.is_editor_hint() or load_in_game:
		if terrain_file != "":
			load_wmt(terrain_file)

func _apply_flat_material() -> void:
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = flat_color
	material_override = mat
	if Engine.is_editor_hint():
		load_wmt(terrain_file)

func _recompute_extents() -> void:
	var has := false
	var cx0 := 0
	var cx1 := 0
	var cz0 := 0
	var cz1 := 0
	for c in chunks:
		var cx: int = (c as Vector2i).x
		var cz: int = (c as Vector2i).y
		if not has:
			cx0 = cx
			cx1 = cx
			cz0 = cz
			cz1 = cz
			has = true
		else:
			cx0 = mini(cx0, cx)
			cx1 = maxi(cx1, cx)
			cz0 = mini(cz0, cz)
			cz1 = maxi(cz1, cz)
	if not has:
		cell_x0 = 0
		cell_x1 = 0
		cell_z0 = 0
		cell_z1 = 0
	else:
		cell_x0 = cx0 * CHUNK_CELLS
		cell_x1 = (cx1 + 1) * CHUNK_CELLS
		cell_z0 = cz0 * CHUNK_CELLS
		cell_z1 = (cz1 + 1) * CHUNK_CELLS
	_refresh_chunk_keys()

func _chunk_key_id(cx: int, cz: int) -> int:
	return (cx + _KEY_BIAS) * _KEY_STRIDE + (cz + _KEY_BIAS)

func _refresh_chunk_keys() -> void:
	_chunk_key_set.clear()
	for c in chunks:
		var k: Vector2i = c
		_chunk_key_set[_chunk_key_id(k.x, k.y)] = true

func _set_bounds(nx0: int, nx1: int, nz0: int, nz1: int) -> void:
	cell_x0 = nx0
	cell_x1 = nx1
	cell_z0 = nz0
	cell_z1 = nz1
	GRID_SQUARES_X = nx1 - nx0
	GRID_SQUARES_Z = nz1 - nz0
	TERRAIN_WIDTH = float(GRID_SQUARES_X) * SQUARE_EDGE
	TERRAIN_DEPTH = float(GRID_SQUARES_Z) * SQUARE_EDGE
	_paint_atlas_dirty = true
	refresh_cover_aabb()
	set_custom_aabb(_cover_aabb())

# surface_update_vertex_region leaves the mesh AABB stale, so the terrain could
# otherwise get frustum-culled mid-stroke whenever sculpted heights leave the
# initial bounding box. Cover the whole grid volume up front, but with a Y range
# derived from the ACTUAL heights (padded) instead of a fixed 32k box: Godot
# fits directional shadows against the light's cull AABB, and a 32k-tall box
# collapses the shadow map's texel density, making shadows crawl and fade as the
# camera moves.
func _cover_aabb() -> AABB:
	var pad := 8.0
	var lo_y := _cover_min_y - _HEIGHT_PAD
	var hi_y := _cover_max_y + _HEIGHT_PAD
	return AABB(
		Vector3(float(cell_x0) * SQUARE_EDGE - pad, lo_y, float(cell_z0) * SQUARE_EDGE - pad),
		Vector3(TERRAIN_WIDTH + pad * 2.0, (hi_y - lo_y) + _HEIGHT_PAD * 2.0, TERRAIN_DEPTH + pad * 2.0))

# Extra slack (world units) kept above/below the measured height range so a
# stroke can climb past the sampled extremes without the terrain ever being
# frustum-culled (the original reason for the oversized box).
const _HEIGHT_PAD := 64.0

# Grow the cached height range. `rect` is the cell rect whose corner heights just
# changed (empty = rescan the whole lattice with a stride, for grid changes).
# Only ever widens, and per-stroke it only touches the brush footprint, so this
# is cheap enough to call every sculpt frame.
func refresh_cover_aabb(rect: Rect2i = Rect2i()) -> void:
	var hm := heightmap
	if hm.is_empty():
		return
	var stride := GRID_SQUARES_X + 1
	var rows := GRID_SQUARES_Z + 1
	# The heightmap can be momentarily SMALLER than the current grid bounds:
	# _load_master() calls _set_bounds() (which rescans here) BEFORE it resizes
	# heightmap to the loaded grid, and _resize_grid() swaps the arrays after
	# the bounds too. Indexing with the new stride against the old array threw
	# "Out of bounds get index" and aborted the refresh, leaving a stale box.
	# Bail out instead - the box is refreshed again from rebuild_mesh().
	if stride < 1 or rows < 1 or stride * rows > hm.size():
		return
	var lo := INF
	var hi := -INF
	if rect.size.x > 0 and rect.size.y > 0:
		# Brush footprint: cell rect -> the corner lattice it touches (+1).
		var i0 := maxi(0, rect.position.x)
		var i1 := mini(stride - 1, rect.position.x + rect.size.x)
		var j0 := maxi(0, rect.position.y)
		var j1 := mini(rows - 1, rect.position.y + rect.size.y)
		for j in range(j0, j1 + 1):
			var base := j * stride
			for i in range(i0, i1 + 1):
				var h := hm[base + i]
				lo = minf(lo, h)
				hi = maxf(hi, h)
	else:
		# Whole grid: stride-sample it (the +-_HEIGHT_PAD slack absorbs the
		# in-between extremes; a later stroke that touches one grows the box).
		var step := 4
		for j in range(0, rows, step):
			var base := j * stride
			for i in range(0, stride, step):
				var h := hm[base + i]
				lo = minf(lo, h)
				hi = maxf(hi, h)
	if lo == INF:
		return
	var grew := false
	if lo < _cover_min_y:
		_cover_min_y = lo
		grew = true
	if hi > _cover_max_y:
		_cover_max_y = hi
		grew = true
	if grew:
		set_custom_aabb(_cover_aabb())

var _cover_min_y := INF
var _cover_max_y := -INF

func _resize_grid(ox0: int, ox1: int, oz0: int, oz1: int, nx0: int, nx1: int, nz0: int, nz1: int) -> bool:
	var nsx := nx1 - nx0
	var nsz := nz1 - nz0
	if nsx <= 0 or nsz <= 0:
		heightmap = PackedFloat32Array()
		center_h = PackedFloat32Array()
		hidden_tiles = PackedByteArray()
		_static_indices = PackedInt32Array()
		_static_grid_sx = 0
		_static_grid_sz = 0
		_chunk_key_set = {}
		_set_bounds(nx0, nx1, nz0, nz1)
		return false
	# Corner lattice is one row/column larger than the cell grid.
	var nhm := PackedFloat32Array()
	nhm.resize((nsx + 1) * (nsz + 1))
	nhm.fill(0.0)
	var nch := PackedFloat32Array()
	nch.resize(nsx * nsz)
	nch.fill(0.0)
	var nhid := PackedByteArray()
	nhid.resize(nsx * nsz)
	nhid.fill(0)
	if heightmap.size() > 0:
		var old_sx := GRID_SQUARES_X
		var gx_lo := maxi(ox0, nx0)
		var gx_hi := mini(ox1, nx1)
		var gz_lo := maxi(oz0, nz0)
		var gz_hi := mini(oz1, nz1)
		for gz in range(gz_lo, gz_hi + 1):
			var old_row := (gz - oz0) * (old_sx + 1)
			var new_row := (gz - nz0) * (nsx + 1)
			for gx in range(gx_lo, gx_hi + 1):
				var oi := old_row + (gx - ox0)
				var ni := new_row + (gx - nx0)
				nhm[ni] = heightmap[oi]
		var cgx_lo := maxi(ox0, nx0)
		var cgx_hi := mini(ox1 - 1, nx1 - 1)
		var cgz_lo := maxi(oz0, nz0)
		var cgz_hi := mini(oz1 - 1, nz1 - 1)
		for gz in range(cgz_lo, cgz_hi + 1):
			var old_row := (gz - oz0) * old_sx
			var new_row := (gz - nz0) * nsx
			for gx in range(cgx_lo, cgx_hi + 1):
				var oi := old_row + (gx - ox0)
				var ni := new_row + (gx - nx0)
				nch[ni] = center_h[oi]
				if hidden_tiles.size() > 0:
					nhid[ni] = hidden_tiles[oi]
	heightmap = nhm
	center_h = nch
	hidden_tiles = nhid
	height_version += 1
	_set_bounds(nx0, nx1, nz0, nz1)
	return true

func has_chunk(cx: int, cz: int) -> bool:
	return Vector2i(cx, cz) in chunks

func add_chunk(cx: int, cz: int) -> bool:
	var key := Vector2i(cx, cz)
	if key in chunks:
		return false
	chunks.append(key)
	var o_x0 := cell_x0
	var o_x1 := cell_x1
	var o_z0 := cell_z0
	var o_z1 := cell_z1
	_recompute_extents()
	_resize_grid(o_x0, o_x1, o_z0, o_z1, cell_x0, cell_x1, cell_z0, cell_z1)
	rebuild_mesh()
	return true

func remove_chunk(cx: int, cz: int) -> bool:
	var key := Vector2i(cx, cz)
	var i := chunks.find(key)
	if i == -1:
		return false
	chunks.remove_at(i)
	var o_x0 := cell_x0
	var o_x1 := cell_x1
	var o_z0 := cell_z0
	var o_z1 := cell_z1
	_recompute_extents()
	_resize_grid(o_x0, o_x1, o_z0, o_z1, cell_x0, cell_x1, cell_z0, cell_z1)
	rebuild_mesh()
	return true

# Absolute chunk-lattice coords of the chunk owning absolute cell (gx, gz).
func _chunk_of(gx: int, gz: int) -> Vector2i:
	return Vector2i(
		floori(float(gx) / float(CHUNK_CELLS)),
		floori(float(gz) / float(CHUNK_CELLS)))

# True if the cell belongs to an existing chunk and is not hidden, i.e. it is
# part of the emitted mesh and sculptable. With the fixed vertex layout every
# cell index is always valid mesh geometry, but only "emitted" (visible) cells
# carry real heights; the others sit collapsed at the degenerate point.
func cell_emitted(ci: int) -> bool:
	if ci < 0 or ci >= hidden_tiles.size():
		return false
	if hidden_tiles[ci] != 0:
		return false
	var gx := cell_x0 + (ci % GRID_SQUARES_X)
	var gz := cell_z0 + (ci / GRID_SQUARES_X)
	return _chunk_key_set.has(_chunk_key_id(
			floori(float(gx) / float(CHUNK_CELLS)),
			floori(float(gz) / float(CHUNK_CELLS))))

# True if the corner (gx, gz) touches at least one emitted cell, i.e. raising
# it changes the rendered mesh. Border corners (gx == cell_x1) are included.
func corner_emitted(gx: int, gz: int) -> bool:
	if gx < cell_x0 or gz < cell_z0 or gx > cell_x1 or gz > cell_z1:
		return false
	for o in CellOffsets.SHARED:
		var bx := gx + int(o[0])
		var bz := gz + int(o[1])
		if bx < cell_x0 or bz < cell_z0 or bx >= cell_x1 or bz >= cell_z1:
			continue
		if cell_emitted(_center_index(bx, bz)):
			return true
	return false

# Corner-cell offsets used to find the up-to-4 cells that share a corner, with
# the slot that corner occupies in each cell (TL=0, TR=1, BR=2, BL=3).
class CellOffsets:
	const SHARED: Array = [[0, 0, 0], [-1, 0, 1], [0, -1, 3], [-1, -1, 2]]

func rebuild_mesh() -> void:
	_refresh_chunk_keys()
	var sxs := GRID_SQUARES_X
	var szs := GRID_SQUARES_Z
	if sxs <= 0 or szs <= 0:
		_static_indices = PackedInt32Array()
		_static_grid_sx = 0
		_static_grid_sz = 0
		mesh = null
		return
	var n_cells := sxs * szs
	# Static index buffer (per-cell 8 triangles against the fixed vi = ci*5..+4
	# layout) is rebuilt ONLY when the grid dimensions change.
	var surf_dirty := _static_indices.size() != n_cells * 12 \
			or _static_grid_sx != sxs or _static_grid_sz != szs
	if surf_dirty:
		_static_indices = PackedInt32Array()
		_static_indices.resize(n_cells * 12)
		_static_grid_sx = sxs
		_static_grid_sz = szs
		for j in range(szs):
			for i in range(sxs):
				var g: int = j * sxs + i
				var b := g * VERTICES_PER_CELL
				_static_indices[g * 12 + 0] = b + 1
				_static_indices[g * 12 + 1] = b + 4
				_static_indices[g * 12 + 2] = b + 0
				_static_indices[g * 12 + 3] = b + 2
				_static_indices[g * 12 + 4] = b + 4
				_static_indices[g * 12 + 5] = b + 1
				_static_indices[g * 12 + 6] = b + 3
				_static_indices[g * 12 + 7] = b + 4
				_static_indices[g * 12 + 8] = b + 2
				_static_indices[g * 12 + 9] = b + 0
				_static_indices[g * 12 + 10] = b + 4
				_static_indices[g * 12 + 11] = b + 3

	# Fill every cell's 5 vertices: real heights for emitted cells, the
	# degenerate point for absent/hidden ones. Same fixed layout each time.
	var hm := heightmap
	var ch := center_h
	var hid := hidden_tiles
	var cset := _chunk_key_set
	var hm_rows := sxs + 1
	var x_off := cell_x0
	var z_off := cell_z0
	var edge := SQUARE_EDGE
	var edge_half := edge * 0.5
	var chunk_cells := CHUNK_CELLS
	var vpc := VERTICES_PER_CELL
	var deg := DEGENERATE_POS
	var vertices := PackedVector3Array()
	vertices.resize(n_cells * vpc)
	var normals := PackedVector3Array()
	normals.resize(n_cells * vpc)
	var vo := 0
	for j in range(szs):
		var gz := z_off + j
		var wz := float(gz) * edge
		var kz := floori(float(gz) / float(chunk_cells)) + _KEY_BIAS
		var kz_term := kz
		var hm_row := j * hm_rows
		# Row mask off chunks so the per-cell check stays int math only.
		for i in range(sxs):
			var gx := x_off + i
			var wx := float(gx) * edge
			var kx := floori(float(gx) / float(chunk_cells)) + _KEY_BIAS
			var cix := i + j * sxs
			var key := kx * _KEY_STRIDE + kz_term
			if cset.has(key) and hid[cix] == 0:
				var h_tl := hm[hm_row + i]
				var h_tr := hm[hm_row + i + 1]
				var h_bl := hm[hm_row + hm_rows + i]
				var h_br := hm[hm_row + hm_rows + i + 1]
				var h_c := ch[cix]
				vertices[vo + 0] = Vector3(wx, h_tl, wz)
				vertices[vo + 1] = Vector3(wx + edge, h_tr, wz)
				vertices[vo + 2] = Vector3(wx + edge, h_br, wz + edge)
				vertices[vo + 3] = Vector3(wx, h_bl, wz + edge)
				vertices[vo + 4] = Vector3(wx + edge_half, h_c, wz + edge_half)
				# Real per-vertex normals, exactly like the imported world
				# objects: Godot's lighting AND its directional shadow normal
				# offset both need them (a mesh with no normal array leaves the
				# vertex normal at zero, which is what made the terrain's
				# shadows crawl while the glTF meshes stayed rock solid).
				normals[vo + 0] = _corner_normal(gx, gz)
				normals[vo + 1] = _corner_normal(gx + 1, gz)
				normals[vo + 2] = _corner_normal(gx + 1, gz + 1)
				normals[vo + 3] = _corner_normal(gx, gz + 1)
				normals[vo + 4] = _center_normal(gx, gz)
			else:
				for s in range(vpc):
					vertices[vo + s] = deg
					normals[vo + s] = Vector3.UP
			vo += vpc

	var new_mesh := ArrayMesh.new()
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = vertices
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_INDEX] = _static_indices
	new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var fmt := new_mesh.surface_get_format(0)
	_vertex_stride = RenderingServer.mesh_surface_get_format_vertex_stride(fmt, vertices.size())
	self.mesh = new_mesh
	# The mesh was just rebuilt from the (now correctly sized) heightmap, so this
	# is the first moment the cover box can be measured reliably. Doing it here
	# covers every path that swaps in a new heightmap - load, resize, undo - and
	# keeps the box from staying stale (or never being set) after a grid change.
	refresh_cover_aabb()

# Corner-lattice index of absolute corner (gx, gz) (borders included).
func _corner_index(gx: int, gz: int) -> int:
	return (gz - cell_z0) * (GRID_SQUARES_X + 1) + (gx - cell_x0)

func _height_at(gx: int, gz: int) -> float:
	if gx < cell_x0 or gz < cell_z0 or gx > cell_x1 or gz > cell_z1:
		return 0.0
	var gi := _corner_index(gx, gz)
	if gi >= heightmap.size() or gi < 0:
		return 0.0
	return heightmap[gi]

func set_height(gx: int, gz: int, h: float) -> void:
	if gx < cell_x0 or gz < cell_z0 or gx > cell_x1 or gz > cell_z1:
		return
	heightmap[_corner_index(gx, gz)] = maxf(h, 0.0)
	height_version += 1

func get_height(gx: int, gz: int) -> float:
	return _height_at(gx, gz)

# Smooth vertex normal of corner (gx, gz) from central differences on the
# height lattice (one-sided at the borders, so the edges stay stable). Same
# lattice, same gradient the shader used to reconstruct per fragment - just
# evaluated once per vertex here so Godot can shade and shadow the terrain
# like any other mesh.
func _corner_normal(gx: int, gz: int) -> Vector3:
	var edge := SQUARE_EDGE
	var l := _height_at(gx - 1, gz) if gx > cell_x0 else _height_at(gx, gz)
	var r := _height_at(gx + 1, gz) if gx < cell_x1 else _height_at(gx, gz)
	var d := _height_at(gx, gz - 1) if gz > cell_z0 else _height_at(gx, gz)
	var u := _height_at(gx, gz + 1) if gz < cell_z1 else _height_at(gx, gz)
	var span_x := float((1 if gx > cell_x0 else 0) + (1 if gx < cell_x1 else 0)) * edge
	var span_z := float((1 if gz > cell_z0 else 0) + (1 if gz < cell_z1 else 0)) * edge
	var dhdx := 0.0
	var dhdz := 0.0
	if span_x > 0.0:
		dhdx = (r - l) / span_x
	if span_z > 0.0:
		dhdz = (u - d) / span_z
	return Vector3(-dhdx, 1.0, -dhdz).normalized()

# Cell-center normal: average of the four corner normals (smooth across the
# 5-vertex cell, so the center vertex never facets the surface).
func _center_normal(gx: int, gz: int) -> Vector3:
	var n := _corner_normal(gx, gz) + _corner_normal(gx + 1, gz) \
		+ _corner_normal(gx + 1, gz + 1) + _corner_normal(gx, gz + 1)
	if n.length_squared() < 0.000001:
		return Vector3.UP
	return n.normalized()

func get_neighbor_average(gx: int, gz: int) -> float:
	var sum := 0.0
	var n := 0
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			if dx == 0 and dz == 0:
				continue
			var nx := gx + dx
			var nz := gz + dz
			if nx < cell_x0 or nz < cell_z0 or nx > cell_x1 or nz > cell_z1:
				continue
			sum += heightmap[_corner_index(nx, nz)]
			n += 1
	if n == 0:
		return 0.0
	return sum / float(n)

# Cell index (squares only, no border row/column) of absolute cell (gx, gz).
func _center_index(gx: int, gz: int) -> int:
	return (gz - cell_z0) * GRID_SQUARES_X + (gx - cell_x0)

func _center_height(gi: int) -> float:
	if gi < 0 or gi >= center_h.size():
		return 0.0
	return center_h[gi]

func set_center_height(gx: int, gz: int, h: float) -> void:
	if gx < cell_x0 or gz < cell_z0 or gx >= cell_x1 or gz >= cell_z1:
		return
	center_h[_center_index(gx, gz)] = maxf(h, 0.0)
	height_version += 1

func get_center_height(gx: int, gz: int) -> float:
	if gx < cell_x0 or gz < cell_z0 or gx >= cell_x1 or gz >= cell_z1:
		return 0.0
	return _center_height(_center_index(gx, gz))

# Base (lowest) cell of the tile containing cell (gx, gz). Tiles are aligned to
# the chunk lattice (CHUNK_CELLS % SQUARES_PER_TILE == 0), so floor(gx / 8) * 8
# is consistent even for negative chunk lattices.
func _tile_base_cell(gx: int, gz: int) -> Vector2i:
	return Vector2i(
		floori(float(gx) / float(SQUARES_PER_TILE)) * SQUARES_PER_TILE,
		floori(float(gz) / float(SQUARES_PER_TILE)) * SQUARES_PER_TILE)

# Per-tile hide/show. Hidden tiles are not rendered, not sculptable, and the
# hide state is persisted with the chunk file (see save_wmt). (gx, gz) is any
# cell inside the tile.
func is_tile_hidden(gx: int, gz: int) -> bool:
	var b := _tile_base_cell(gx, gz)
	if b.x < cell_x0 or b.y < cell_z0 or b.x >= cell_x1 or b.y >= cell_z1:
		return true
	var ci := _center_index(b.x, b.y)
	return ci >= 0 and ci < hidden_tiles.size() and hidden_tiles[ci] != 0

func set_tile_hidden(gx: int, gz: int, hidden: bool) -> void:
	var b := _tile_base_cell(gx, gz)
	var flipped := false
	for dz in range(SQUARES_PER_TILE):
		for dx in range(SQUARES_PER_TILE):
			var cx := b.x + dx
			var cz := b.y + dz
			if cx < cell_x0 or cz < cell_z0 or cx >= cell_x1 or cz >= cell_z1:
				continue
			var ci := _center_index(cx, cz)
			var now := 1 if hidden else 0
			if hidden_tiles[ci] != now:
				hidden_tiles[ci] = now
				flipped = true
	# The mesh has a fixed vertex layout, so a tile flip only rewrites the
	# affected 8x8 block's 320 vertex records in place — no full rebuild, no
	# index churn. (When the mesh doesn't exist yet, callers rebuild normally.)
	if flipped and mesh != null and (mesh as ArrayMesh).get_surface_count() > 0:
		_patch_tile_mesh(b.x, b.y)

# Rewrite just the 8x8 block of cells starting at tile-cell (tgx, tgz) in the
# mesh's fixed vertex buffer (V*VERTICES_PER_CELL contiguous records per cell).
# Cells that were just hidden collapse to the degenerate point; cells that were
# just revealed get their real heights back from the stored arrays.
func _patch_tile_mesh(tgx: int, tgz: int) -> void:
	var m := mesh as ArrayMesh
	if m == null or m.get_surface_count() == 0:
		return
	var stride := _vertex_stride
	var edge := SQUARE_EDGE
	var edge_half := edge * 0.5
	var hm := heightmap
	var ch := center_h
	var hm_rows := GRID_SQUARES_X + 1
	var x_off := cell_x0
	var z_off := cell_z0
	var vpc := VERTICES_PER_CELL
	var deg := DEGENERATE_POS
	var cis := PackedInt32Array()
	for dj in range(SQUARES_PER_TILE):
		var gz := tgz + dj
		if gz < z_off or gz >= z_off + GRID_SQUARES_Z:
			continue
		for di in range(SQUARES_PER_TILE):
			var gx := tgx + di
			if gx < x_off or gx >= x_off + GRID_SQUARES_X:
				continue
			cis.append((gz - z_off) * GRID_SQUARES_X + (gx - x_off))
	if cis.is_empty():
		return
	var i := 0
	while i < cis.size():
		var j := i
		while j < cis.size() and cis[j] == cis[i] + (j - i):
			j += 1
		var pts := PackedVector3Array()
		for k in range(i, j):
			var ci := cis[k]
			var jj := ci / GRID_SQUARES_X
			var ii := ci - jj * GRID_SQUARES_X
			if cell_emitted(ci):
				var gx := x_off + ii
				var gz := z_off + jj
				var wx := float(gx) * edge
				var wz := float(gz) * edge
				var row := jj * hm_rows
				pts.append(Vector3(wx, hm[row + ii], wz))
				pts.append(Vector3(wx + edge, hm[row + ii + 1], wz))
				pts.append(Vector3(wx + edge, hm[row + hm_rows + ii + 1], wz + edge))
				pts.append(Vector3(wx, hm[row + hm_rows + ii], wz + edge))
				pts.append(Vector3(wx + edge_half, ch[ci], wz + edge_half))
			else:
				for s in range(vpc):
					pts.append(deg)
		m.surface_update_vertex_region(0, cis[i] * vpc * stride, pts.to_byte_array())
		i = j

#
# Per-tile paint: ONE RGBA8 splatmap per tile with all PAINT_PLANES channels
# packed into the color components (plane 0 = R, 1 = G, 2 = B, 3 = A), each
# PAINT_TILE_PX x PAINT_TILE_PX, stored as raw RGBA bytes inside the .wmt paint
# block (v11) - no sidecar PNGs, no separate per-channel images. A byte 0..255 is
# that channel's splat COVERAGE weight. Stamps write COMPETITIVE coverage (the
# InnoGames terrain-splat model): the painted channel rises toward 255 and every
# other channel falls by the exact same amount, so the channels always sum to <=
# 1 (the base material holds the remainder) and repainting an older channel
# brings it back - nothing is erased permanently. Paint_tile_stamp also records
# which channel OWNS each texel in the per-texel top map (paint order, v11) for
# the eyedropper; the overlay shader renders the weights with a masked-depth
# blend, which gives brush falloff, bilinear-feathered splat transitions and
# alphamap feathering (see the _top block vs "til" blocks in the paint format).
const PAINT_CHANNELS := 4
const PAINT_TILE_PX := 64
const PAINT_PLANES := 4
const PAINT_PLANE_BYTES := PAINT_TILE_PX * PAINT_TILE_PX
# Edge-replicated guard strip around every tile's block in the splatmap ATLAS
# (not the per-tile payload). The atlas is bilinearly filtered, so without
# padding the 64px blocks rub against each other at the texel seams: a painted
# tile's edge bleeds the neighbour block's weights in (alien textures at tile
# edges), and leaked weight on an unpainted tile reads as painted coverage the
# dead-channel fallback renders BLACK. Each cell is the block plus its own
# replicated edge ring (SPLAT_PAD on every side), so bilinear taps near a seam
# land in the tile's OWN cloned edge - no cross-block bleed, and painted edges
# stay painted instead of fading to the bare white base.
const SPLAT_PAD := 2
const SPLAT_PITCH := PAINT_TILE_PX + 2 * SPLAT_PAD

# Vector2i(tgx,tgz) -> {}. Registry of which tiles are painted; existence
# drives the splat atlases, the has_paint toggle and the save block.
var tile_paints := {}
# Vector2i(tgx,tgz) -> PackedByteArray of PAINT_PLANES * PAINT_PLANE_BYTES raw
# R8 plane bytes (plane c occupies [c*PAINT_PLANE_BYTES, (c+1)*...)). The
# working copy for stamps and atlas rebuilds; hydrated from the embedded .wmt
# data at load, created on first stamp.
var _tile_splats := {}
# Vector2i(tgx,tgz) -> Array[String] of up to PAINT_PLANES texture paths, one
# per paint channel ("" = no texture -> that channel contributes nothing). Each
# tile owns its own mapping; a fresh tile gains slots as channels are painted
# (auto-selected by the editor so a texture keeps the same channel per tile,
# which is what makes texturing seamless across tile borders).
var tile_textures := {}

# Vector2i(tgx,tgz) -> Array[float] of per-channel texture REPEAT counts (one
# per paint channel, 1..256, default 16). Scoped exactly like tile_textures: a
# tile only carries an entry when the editor wrote a per-tile value (selected
# tiles / the right-clicked tile); tiles without an entry use the editor's
# global per-channel tiling. Persisted in the .wmt v10 paint block.
var tile_tilings := {}

# Vector2i(tgx,tgz) -> Array[float] of per-channel masked-depth overrides (one
# per paint channel, 0.01..1.0, default 0.2). Scoped exactly like tile_tilings:
# a tile only carries an entry when the editor wrote a per-tile value; tiles
# without an entry use the editor's global paint depth. Persisted like the
# paint data. Stored as-is; the .wmt save treats it like the other paint maps.
var tile_depths := {}
# Vector2i(tgx,tgz) -> PackedByteArray of PAINT_PLANE_BYTES, one byte per splat
# texel = the channel that OWNS that texel's surface (0..PAINT_PLANES-1), or 255
# for bare ground (no paint has touched the texel yet). This is the paint ORDER:
# stamping channel C sets C there, and the eyedropper (channel_at_local) returns
# the last-painted channel even where the competitive weights are tied (e.g. the
# 50/50 mid-stroke of a soft dab). The renderer uses the weights, not this map.
# Tiles without an entry are derived from the splat weights at load (argmax;
# ties -> lowest channel), which keeps older files behaving. Persisted in the
# .wmt v11 paint block.
var tile_tops := {}

# Vertex-color paint: a per-MESH-VERTEX tint, now superseded by the per-tile
# additive-light splat below (the BRUSH stamps tile tint blocks, not vertices).
# The current tint is a per-tile RGBA8 ADDITIVE-light splat (see below); the
# legacy const only survives as the erase/undo target (the black neutral).
# Black (0.0) = no tint; PAINTING (especially white) ADDS light to the surface.
# "No tint here": black with ZERO coverage. The alpha matters - the shader
# blends as mix(0.5 gray, rgb, a), so a neutral texel has to be alpha 0 to stay
# on the 0.5 no-op. A black texel with alpha 1 would mean "fully covered black"
# and darken the terrain to nothing.
const VERTEX_TINT_NEUTRAL := Color(0.0, 0.0, 0.0, 0.0)

# The ERASER swatch, and the test for "is this picked color the eraser?".
#
# Erasing used to be keyed on BLACK, which made the darkest possible paint
# impossible: the one color you reach for to knock a bright highlight back down
# was the same color that deleted the texel outright. In the W3C blend a top
# layer of 0.0 is a legal, meaningful value (below 0.5 it runs through the
# multiply branch, so black genuinely darkens), and the blend's own neutral is
# 0.5 - so 50% gray is the color that means "no effect", which makes it the
# natural eraser swatch. Black is now just another paintable color.
const VERTEX_TINT_ERASER := Color(0.5, 0.5, 0.5, 1.0)

# True when `c` is the eraser swatch. The comparison is fuzzy (an epsilon band
# around 0.5) so a color a hair off - a hand-picked swatch, a round-tripped
# value, a saved preference - still erases instead of silently painting a
# no-op that the user then has to hunt down.
static func is_eraser_color(c: Color) -> bool:
	return absf(c.r - 0.5) <= 0.02 and absf(c.g - 0.5) <= 0.02 and absf(c.b - 0.5) <= 0.02

# Vertex-tint splatmap: one RGBA8 tint block per painted tile (TINT_TILE_PX ^ 2
# texels = 16x16 per tile = 2 texels per cell), laid out in the SAME padded
# atlas scheme as the splat weights so the overlay shader samples it identically
# (but with its own smaller pitch: TINT_PAD echo ring). The tint is ADDITIVE
# LIGHT painted onto the surface: black (0) = no change, painting (esp. white)
# adds light per channel and is fed to the shader as EMISSION, so tinted areas
# light THEMSELVES on top of the real scene lighting - baked-in light flares,
# painted highlights, a light's cast. The eraser (black) lerps texels back to 0.
const TINT_TILE_PX := 16
const TINT_PAD := 2
const TINT_PITCH := TINT_TILE_PX + 2 * TINT_PAD
const TINT_TILE_BYTES := TINT_TILE_PX * TINT_TILE_PX * 4
# Per-texel vertex tint, stored as RGBA8 per TINT_TILE_PX^2 texel:
#   RGB = the picked color, A = how much of it is there (coverage).
# 0,0,0,0 is "unpainted" (neutral, reads as no blend in the shader). The color
# lives per texel rather than in a shader uniform so re-picking a color does not
# recolor paint that is already down.
var tile_tints := {}            # Vector2i tile -> PackedByteArray (null = unpainted)
var _tint_atlas_img: Image = null
var _tint_atlas_tex: ImageTexture = null
var _tint_atlas_dirty := true
var _splat_atlas_img: Image = null       # reused RGBA8 splatmap working image
var _splat_atlas_tex: ImageTexture = null
var _top_atlas_img: Image = null         # reused R8 "surface owner" image
var _top_atlas_tex: ImageTexture = null
var _paint_atlas_dirty := true
var _top_atlas_dirty := true

func tile_count_x() -> int:
	return GRID_SQUARES_X / SQUARES_PER_TILE

func tile_count_z() -> int:
	return GRID_SQUARES_Z / SQUARES_PER_TILE

func tile_origin_x() -> int:
	return cell_x0 / SQUARES_PER_TILE

func tile_origin_z() -> int:
	return cell_z0 / SQUARES_PER_TILE

# Raw R8 splat bytes for one tile: PAINT_PLANES planes of PAINT_PLANE_BYTES
# each, plane c at offset c*PAINT_PLANE_BYTES. Painted tiles are hydrated from
# the embedded .wmt paint data at load; anything registered but not yet hydrated
# (or unregistered) reads back as all-zero (no paint). Never touches disk.
func _tile_splat_bytes(tgx: int, tgz: int) -> PackedByteArray:
	var key := Vector2i(tgx, tgz)
	if _tile_splats.has(key):
		return _tile_splats[key]
	var bytes := PackedByteArray()
	bytes.resize(PAINT_PLANES * PAINT_PLANE_BYTES)
	_tile_splats[key] = bytes
	return bytes

# The tile's per-texel surface-owner bytes (0..3 = channel, 255 = bare).
# Tiles without an explicit top map (older files / freshly-upgraded ones) are
# derived from the splat weights: each texel picks its argmax channel, ties go
# to the lowest channel, all-zero texels are bare. The derived map is cached so
# the first stamp on such a tile only overrides the texels it touches.
func _tile_top_bytes(tgx: int, tgz: int) -> PackedByteArray:
	var key := Vector2i(tgx, tgz)
	if tile_tops.has(key):
		return tile_tops[key]
	var out := PackedByteArray()
	out.resize(PAINT_PLANE_BYTES)
	out.fill(255)
	var splats: PackedByteArray = _tile_splats.get(key, PackedByteArray())
	if splats.size() == PAINT_PLANES * PAINT_PLANE_BYTES:
		for i in range(PAINT_PLANE_BYTES):
			var best_c := -1
			var bv := 0
			for c in range(PAINT_PLANES):
				var w := splats[c * PAINT_PLANE_BYTES + i]
				if w == 0:
					continue
				if w > bv:
					bv = w
					best_c = c
			if best_c >= 0:
				out[i] = best_c
	tile_tops[key] = out
	return out

# The surface channel at index idx of the tile's top map, or 255 = bare ground.
func tile_top(tgx: int, tgz: int, idx: int) -> int:
	if idx < 0 or idx >= PAINT_PLANE_BYTES:
		return 255
	return _tile_top_bytes(tgx, tgz)[idx]

# The tile's per-slot texture override for `slot` (0..PAINT_PLANES-1), or ""
# when the tile stores no override for that slot.
func tile_texture_path(tgx: int, tgz: int, slot: int) -> String:
	var arr: Variant = tile_textures.get(Vector2i(tgx, tgz))
	if arr is Array and slot >= 0 and slot < arr.size():
		return str(arr[slot])
	return ""

# Store (or update) the tile's per-slot texture overrides. `paths` is a plain
# Array of up to PAINT_PLANES path strings; shorter arrays or "" entries mean
# "no override" for that slot. Returns the stored copy.
func set_tile_textures(tgx: int, tgz: int, paths: Array) -> Array:
	var copy: Array = []
	for i in range(mini(paths.size(), PAINT_PLANES)):
		copy.append(str(paths[i]))
	if copy.is_empty():
		tile_textures.erase(Vector2i(tgx, tgz))
	else:
		tile_textures[Vector2i(tgx, tgz)] = copy
	return copy

# The tile's per-channel texture repeat (`slot` 0..PAINT_PLANES-1), or -1.0
# when the tile stores no tiling override (the editor then uses its global
# per-channel tiling).
func tile_tiling(tgx: int, tgz: int, slot: int) -> float:
	var arr: Variant = tile_tilings.get(Vector2i(tgx, tgz))
	if arr is Array and slot >= 0 and slot < arr.size():
		return float(arr[slot])
	return -1.0

# Store (or update) the tile's per-channel repeat overrides. `values` is a
# plain Array of up to PAINT_PLANES floats (1..256). Returns the stored copy.
func set_tile_tilings(tgx: int, tgz: int, values: Array) -> Array:
	var copy: Array = []
	for i in range(mini(values.size(), PAINT_PLANES)):
		copy.append(float(values[i]))
	if copy.is_empty():
		tile_tilings.erase(Vector2i(tgx, tgz))
	else:
		tile_tilings[Vector2i(tgx, tgz)] = copy
	return copy

# The tile's per-channel masked-depth override (`slot` 0..PAINT_PLANES-1), or
# -1.0 when the tile stores no depth override (the editor then uses its global
# paint depth). Mirrors tile_tiling().
func tile_depth(tgx: int, tgz: int, slot: int) -> float:
	var arr: Variant = tile_depths.get(Vector2i(tgx, tgz))
	if arr is Array and slot >= 0 and slot < arr.size():
		return float(arr[slot])
	return -1.0

# Store (or update) the tile's per-channel depth overrides (0.01..1.0). Returns
# the stored copy.
func set_tile_depths(tgx: int, tgz: int, values: Array) -> Array:
	var copy: Array = []
	for i in range(mini(values.size(), PAINT_PLANES)):
		copy.append(float(values[i]))
	if copy.is_empty():
		tile_depths.erase(Vector2i(tgx, tgz))
	else:
		tile_depths[Vector2i(tgx, tgz)] = copy
	return copy

# ---- Vertex-tint splatmap (additive painted light) ---------------------------
# Per-tile RGBA8 tint blocks of TINT_TILE_PX texels per tile (2 texels/cell).
# The tint ADDS LIGHT per channel: black (0) = no change (the neutral the blocks
# start from and wipe back to), painting (esp. white) adds light that the shader
# feeds into EMISSION. Mirrors the splat atlas (padded, origin = the tile
# lattice) so the overlay shader shares the exact padded-uv reconstruction.

# Files written before the tint color moved into the texel stored an
# accumulated color in RGB with a permanently 0 alpha. Those texels are
# "painted but at an unknown coverage", so promote alpha to full and let the
# shader's neutral blend keep them looking the same. Idempotent, and a genuinely
# empty (0,0,0,0) texel is left alone.
func _migrate_tint_block(b: PackedByteArray) -> PackedByteArray:
	var touched := false
	for i in range(0, b.size(), 4):
		if b[i + 3] == 0 and (b[i] != 0 or b[i + 1] != 0 or b[i + 2] != 0):
			b[i + 3] = 255
			touched = true
	return b

func _fresh_tint_block() -> PackedByteArray:
	var b := PackedByteArray()
	b.resize(TINT_TILE_BYTES)
	b.fill(0)
	return b

func _tile_tint_block(tgx: int, tgz: int) -> PackedByteArray:
	var k := Vector2i(tgx, tgz)
	if not tile_tints.has(k):
		tile_tints[k] = _fresh_tint_block()
	return tile_tints[k]

# Current tint at tile texel (px, py); neutral (no light) when unpainted.
func tint_texel_at(tgx: int, tgz: int, px: int, py: int) -> Color:
	var k := Vector2i(tgx, tgz)
	if not tile_tints.has(k):
		return VERTEX_TINT_NEUTRAL
	var b: PackedByteArray = tile_tints[k]
	var idx := (py * TINT_TILE_PX + px) * 4
	return Color(b[idx] / 255.0, b[idx + 1] / 255.0, b[idx + 2] / 255.0,
			b[idx + 3] / 255.0)

# Tint at a world-local point, as RGBA = color + coverage. Used by the
# Ctrl+LMB vertex-color eyedropper; unpainted reports coverage 0.
func tint_at_local(pos: Vector3) -> Color:
	var edge := TILE_EDGE
	var tgx := int(floor(pos.x / edge))
	var tgz := int(floor(pos.z / edge))
	var step := edge / float(TINT_TILE_PX)
	var px := clampi(int(floor((pos.x - tgx * edge) / step)), 0, TINT_TILE_PX - 1)
	var py := clampi(int(floor((pos.z - tgz * edge) / step)), 0, TINT_TILE_PX - 1)
	return tint_texel_at(tgx, tgz, px, py)

# Copy of one tile's tint block (for undo snapshots; neutral when unpainted).
func tint_tile_pixels(tgx: int, tgz: int) -> PackedByteArray:
	var k := Vector2i(tgx, tgz)
	return tile_tints[k].duplicate() if tile_tints.has(k) else _fresh_tint_block()

# A per-texel brush stamp scaled by amount * strength_at(d) (the radial
# falloff), exactly like paint_tile_stamp. The tint ADDS light per channel: each
# texel gains f * 255 * color (clamped at full), so repeated stamps build up
# toward the tint and a full dab reaches it directly - "painting light".
# Stamping BLACK is the eraser: texels lerp back toward the neutral 0, so the
# painted light is removed smoothly. Returns true if any byte changed - tiles
# are born here.
func paint_tint_stamp(tgx: int, tgz: int, center_x: float, center_z: float,
		radius: float, color: Color, amount: float,
		strength_at: Callable) -> bool:
	if radius <= 0.0 or amount <= 0.0:
		return false
	var b := _tile_tint_block(tgx, tgz)
	var step := TILE_EDGE / float(TINT_TILE_PX)
	var tx0 := float(tgx) * TILE_EDGE
	var tz0 := float(tgz) * TILE_EDGE
	var tr := color.r
	var tg := color.g
	var tb := color.b
	var erasing := is_eraser_color(color)
	var amin := maxi(0, int(floor((center_x - radius - tx0) / step)) - 1)
	var amax := mini(TINT_TILE_PX - 1, int(ceil((center_x + radius - tx0) / step)) + 1)
	var bmin := maxi(0, int(floor((center_z - radius - tz0) / step)) - 1)
	var bmax := mini(TINT_TILE_PX - 1, int(ceil((center_z + radius - tz0) / step)) + 1)
	var changed := false
	for py in range(bmin, bmax + 1):
		var wz := tz0 + (py + 0.5) * step
		for px in range(amin, amax + 1):
			var wx := tx0 + (px + 0.5) * step
			var dx := wx - center_x
			var dz := wz - center_z
			var d := sqrt(dx * dx + dz * dz)
			if d > radius:
				continue
			var f := amount * (strength_at.call(d) as float)
			if f <= 0.0:
				continue
			var idx := (py * TINT_TILE_PX + px) * 4
			var cur_r := b[idx]
			var cur_g := b[idx + 1]
			var cur_b := b[idx + 2]
			var cur_a := b[idx + 3]
			var nr: int
			var ng: int
			var nb: int
			var na: int
			if erasing:
				nr = clampi(int(roundf(lerpf(cur_r, 0.0, f))), 0, 255)
				ng = clampi(int(roundf(lerpf(cur_g, 0.0, f))), 0, 255)
				nb = clampi(int(roundf(lerpf(cur_b, 0.0, f))), 0, 255)
				na = clampi(int(roundf(lerpf(cur_a, 0.0, f))), 0, 255)
			else:
				# The texel becomes "this color, at this strength": RGB snaps to
				# the picked color and the strength lives in alpha alone.
				#
				# Both matters. Snapping RGB (instead of lerping it by the
				# strength) keeps the stored color the real picked color - scaling
				# it down by the strength too would make a half-strength stroke
				# blend to mix(0.5 gray, color*0.5, 0.5) = plain neutral, i.e. a
				# faint stroke would do nothing at all. And because the shader
				# falls off with alpha, a hard RGB step is invisible: the rim of
				# the brush lands at low coverage, not at a visible hue edge.
				nr = clampi(int(roundf(tr * 255.0)), 0, 255)
				ng = clampi(int(roundf(tg * 255.0)), 0, 255)
				nb = clampi(int(roundf(tb * 255.0)), 0, 255)
				na = clampi(int(roundf(lerpf(cur_a, 255.0, f))), 0, 255)
			if nr != cur_r or ng != cur_g or nb != cur_b or na != cur_a:
				b[idx + 3] = na
				b[idx] = nr
				b[idx + 1] = ng
				b[idx + 2] = nb
				changed = true
	var k := Vector2i(tgx, tgz)
	var neutral := true
	for i in range(0, b.size(), 4):
		if b[i] != 0 or b[i + 1] != 0 or b[i + 2] != 0 or b[i + 3] != 0:
			neutral = false
			break
	if neutral:
		# A fully-neutral (all-black) block adds no light and is a no-op (and
		# keeps tint_is_empty honest): always drop it, so erased tiles leave
		# the splatmap entirely.
		tile_tints.erase(k)
	if changed:
		_tint_atlas_dirty = true
	return changed

# Erase every non-neutral texel inside tile (tgx, tgz). Returns how many
# texels changed (0 when the tile was already clean).
func wipe_tint_tile(tgx: int, tgz: int) -> int:
	var k := Vector2i(tgx, tgz)
	if not tile_tints.has(k):
		return 0
	var b: PackedByteArray = tile_tints[k]
	var removed := 0
	for i in range(0, b.size(), 4):
		if b[i] != 0 or b[i + 1] != 0 or b[i + 2] != 0:
			b[i] = 0
			b[i + 1] = 0
			b[i + 2] = 0
			removed += 1
	if removed > 0:
		tile_tints.erase(k)
		_tint_atlas_dirty = true
	return removed

# Restore whole tile blocks (undo/redo target). `entries` =
# [[Vector2i, PackedByteArray], ...]; neutral (all-black) blocks erase their tile.
func restore_tint_tiles(entries: Array) -> void:
	var changed := false
	for e in entries:
		var k: Vector2i = e[0]
		var blk: PackedByteArray = e[1]
		var is_empty := true
		for i in range(0, blk.size(), 4):
			if blk[i] != 0 or blk[i + 1] != 0 or blk[i + 2] != 0 or blk[i + 3] != 0:
				is_empty = false
				break
		if is_empty:
			tile_tints.erase(k)
		else:
			tile_tints[k] = blk
		changed = true
	if changed:
		_tint_atlas_dirty = true

func tint_is_empty() -> bool:
	return tile_tints.is_empty()

# Rebuild (if dirty) and return the tint splatmap as a padded RGBA8 atlas.
# Uses the same _padded_splat_block echo-ring scheme as the splat atlas, but
# with the finer TINT_TILE_PX / TINT_PAD lattice, so the shader samples it
# with the matching tint-pitch uv reconstruction (see terrain_overlay.gdshader).
func tint_atlas_texture() -> ImageTexture:
	if _tint_atlas_img == null or not is_instance_valid(_tint_atlas_tex) \
			or _tint_atlas_img.get_width() != _tint_atlas_w() \
			or _tint_atlas_img.get_height() != _tint_atlas_h():
		_rebuild_tint_atlas()
	elif _tint_atlas_dirty:
		_rebuild_tint_atlas()
	return _tint_atlas_tex

func _tint_atlas_w() -> int:
	return maxi(tile_count_x(), 1) * TINT_PITCH

func _tint_atlas_h() -> int:
	return maxi(tile_count_z(), 1) * TINT_PITCH

func _rebuild_tint_atlas() -> void:
	_tint_atlas_dirty = false
	var w := _tint_atlas_w()
	var h := _tint_atlas_h()
	var ox := tile_origin_x()
	var oz := tile_origin_z()
	if _tint_atlas_img == null or _tint_atlas_img.get_width() != w \
			or _tint_atlas_img.get_height() != h:
		_tint_atlas_img = Image.create(w, h, false, Image.FORMAT_RGBA8)
	# Bare atlas cells must be (0,0,0,0) - black with ZERO coverage. The shader
	# blends as mix(0.5 gray, rgb, a), so alpha 0 keeps the neutral 0.5 and bare
	# cells leave the terrain untouched. A plain Color(0,0,0) has alpha 1, which
	# reads as "fully covered black": the blend collapses to 0 and the terrain
	# goes black. The alpha is the whole point of the fill.
	_tint_atlas_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for key in tile_tints:
		var tgx: int = (key as Vector2i).x
		var tgz: int = (key as Vector2i).y
		var px := (tgx - ox) * TINT_PITCH
		var py := (tgz - oz) * TINT_PITCH
		if px < 0 or py < 0 or px + TINT_PITCH > w or py + TINT_PITCH > h:
			continue
		var timg := Image.create_from_data(
			TINT_TILE_PX, TINT_TILE_PX, false, Image.FORMAT_RGBA8,
			tile_tints[key])
		_tint_atlas_img.blit_rect(
			_padded_splat_block(timg, TINT_TILE_PX, TINT_PAD),
			Rect2i(0, 0, TINT_PITCH, TINT_PITCH), Vector2i(px, py))
	if _tint_atlas_tex == null or not is_instance_valid(_tint_atlas_tex) \
			or _tint_atlas_tex.get_width() != w or _tint_atlas_tex.get_height() != h:
		_tint_atlas_tex = ImageTexture.create_from_image(_tint_atlas_img)
	else:
		_tint_atlas_tex.update(_tint_atlas_img)

# Stamp the brush into one tile's splat planes as a COMPETITIVE coverage paint
# (the standard terrain-splat model): every texel inside the brush circle rises
# the painted channel toward FULL by amount * strength_at(d) and lowers every
# OTHER channel by the exact same amount. That keeps the total coverage <= 1
# (the unpainted base holds the remainder) and is what makes real brush
# FALLOFF visible again: a 50% dab over a full channel leaves both at half
# strength, so the masked-depth renderer feathered blends them right there.
# The competition is reversible - repainting the previous channel brings it back
# in full - and nothing is ever permanently erased. A full dab replaces the
# texel with the painted channel. `amount` is the per-stamp strength,
# `strength_at` the radial falloff callable (distance -> 0..1). Returns true if
# any byte changed. A fresh tile starts at all-zero.
func paint_tile_stamp(tgx: int, tgz: int, center_x: float, center_z: float,
		radius: float, channel: int, amount: float, strength_at: Callable) -> bool:
	if channel < 0 or channel >= PAINT_PLANES:
		return false
	var key := Vector2i(tgx, tgz)
	var splats := _tile_splat_bytes(tgx, tgz)
	var tops := _tile_top_bytes(tgx, tgz)
	var edge := TILE_EDGE
	var tx := tgx * edge
	var tz := tgz * edge
	var step := edge / float(PAINT_TILE_PX)
	var radius2 := radius * radius
	var amt := clampf(amount, 0.0, 1.0)
	var changed := false
	for py in range(PAINT_TILE_PX):
		for px in range(PAINT_TILE_PX):
			var wx := tx + (px + 0.5) * step
			var wz := tz + (py + 0.5) * step
			var dx := wx - center_x
			var dz := wz - center_z
			var d2 := dx * dx + dz * dz
			if d2 > radius2:
				continue
			var s := 1.0
			if strength_at.is_valid():
				s = clampf(strength_at.call(sqrt(d2)), 0.0, 1.0)
			var a := amt * s
			if a < 0.001:
				continue
			var idx := py * PAINT_TILE_PX + px
			var touched := false
			for c in range(PAINT_PLANES):
				var o := c * PAINT_PLANE_BYTES + idx
				var cur := splats[o]
				var nv: int
				if c == channel:
					nv = int(round(lerpf(float(cur), 255.0, a)))
				else:
					nv = int(round(float(cur) * (1.0 - a)))
				nv = clampi(nv, 0, 255)
				if nv != cur:
					splats[o] = nv
					touched = true
			# The painted channel is this texel's surface (paint order for the
			# eyedropper); the competitive weights drive the actual render.
			if tops[idx] != channel:
				tops[idx] = channel
				touched = true
			if touched:
				changed = true
	if changed:
		tile_paints[key] = {}
		_paint_atlas_dirty = true
		_top_atlas_dirty = true
	return changed

# Competitive whole-tile fill: raise one channel toward `amount` across EVERY
# texel of the tile while the other channels recede by (1 - amount). First paint
# on a tile - or a repaint of a channel whose texture was unassigned, leaving a
# gap - materializes the brush's texture over the whole tile instead of leaving
# unpainted texels bare. No-op when there is nothing to change; stamps the tile
# into `tile_paints` like paint_tile_stamp so the atlas/top rebuilds pick it up.
func paint_tile_fill(tgx: int, tgz: int, channel: int, amount: float) -> bool:
	if channel < 0 or channel >= PAINT_PLANES:
		return false
	var key := Vector2i(tgx, tgz)
	var splats := _tile_splat_bytes(tgx, tgz)
	var tops := _tile_top_bytes(tgx, tgz)
	var amt := clampf(amount, 0.0, 1.0)
	var changed := false
	if amt > 0.001:
		for py in range(PAINT_TILE_PX):
			for px in range(PAINT_TILE_PX):
				var idx := py * PAINT_TILE_PX + px
				var touched := false
				for c in range(PAINT_PLANES):
					var cur := splats[c * PAINT_PLANE_BYTES + idx]
					var nv: int
					if c == channel:
						nv = int(round(lerpf(float(cur), 255.0, amt)))
					else:
						nv = int(round(float(cur) * (1.0 - amt)))
					nv = clampi(nv, 0, 255)
					if nv != cur:
						splats[c * PAINT_PLANE_BYTES + idx] = nv
						touched = true
				if tops[idx] != channel:
					tops[idx] = channel
					touched = true
				if touched:
					changed = true
	if changed:
		tile_paints[key] = {}
		_paint_atlas_dirty = true
		_top_atlas_dirty = true
	return changed

# Remove one channel's whole splat plane from a tile: every weight in that
# plane crosses back to zero and the tile's top bytes fall back to the next
# strongest channel (or bare when nothing remains), mirroring how competitive
# paint would have left them. The channel's texture override on the tile is
# cleared too. When the tile ends fully zero it drops back to unpainted
# (textures/tilings/depths erased as well). Returns true if anything changed.
# Never materializes paint data for an unpainted tile.
func wipe_channel(tgx: int, tgz: int, channel: int) -> bool:
	if channel < 0 or channel >= PAINT_PLANES:
		return false
	var key := Vector2i(tgx, tgz)
	if not tile_paints.has(key):
		return false
	var splats: PackedByteArray = _tile_splats.get(key, PackedByteArray())
	if splats.size() != PAINT_PLANES * PAINT_PLANE_BYTES:
		return false
	var tops := _tile_top_bytes(tgx, tgz)
	var changed := false
	for i in range(PAINT_PLANE_BYTES):
		var o := channel * PAINT_PLANE_BYTES + i
		if splats[o] != 0:
			splats[o] = 0
			changed = true
		if tops[i] == channel:
			var bv := 0
			var bc := 255
			for c in range(PAINT_PLANES):
				if c == channel:
					continue
				var w := splats[c * PAINT_PLANE_BYTES + i]
				if w > bv:
					bv = w
					bc = c
			if tops[i] != bc:
				tops[i] = bc
				changed = true
	if not changed:
		return false
	_paint_atlas_dirty = true
	_top_atlas_dirty = true
	if not _splats_nonzero(splats):
		_drop_tile_on_wipe(key)
	else:
		_clear_tile_texture_slot(key, channel)
	return true

# Remove ALL painting from a tile: splat weights, top map, and every per-tile
# texture/tiling/depth override. Returns true when the tile used to be painted.
func wipe_tile(tgx: int, tgz: int, _channel := -1) -> bool:
	var key := Vector2i(tgx, tgz)
	if not tile_paints.has(key):
		return false
	_drop_tile_on_wipe(key)
	return true

# Erase a tile from every paint data store. The cached splat/top atlases must
# be marked dirty here, not by the caller: the cache holds the tile's old block
# and is returned unchanged otherwise, so a wipe that leaves OTHER tiles painted
# would keep rendering the wiped tile's stale paint. Every wipe path funnels
# through this function.
func _drop_tile_on_wipe(key: Vector2i) -> void:
	_tile_splats.erase(key)
	tile_tops.erase(key)
	tile_textures.erase(key)
	tile_tilings.erase(key)
	tile_depths.erase(key)
	tile_paints.erase(key)
	_paint_atlas_dirty = true
	_top_atlas_dirty = true

# Clear one channel's texture override from a tile's texture array, removing
# the array entirely when no overrides remain.
func _clear_tile_texture_slot(key: Vector2i, channel: int) -> void:
	var arr: Variant = tile_textures.get(key)
	if arr is Array and channel >= 0 and channel < arr.size():
		var copy: Array = []
		for v in arr:
			copy.append(str(v))
		copy[channel] = ""
		while not copy.is_empty() and str(copy[copy.size() - 1]) == "":
			copy.remove_at(copy.size() - 1)
		if copy.is_empty():
			tile_textures.erase(key)
		else:
			tile_textures[key] = copy

# Copy of one tile's raw splat bytes (PAINT_PLANES * PAINT_TILE_PX^2), used to
# snapshot a stroke for undo/redo. Always a fresh copy so later stamps cannot
# mutate the captured snapshot.
func paint_pixels(tgx: int, tgz: int) -> PackedByteArray:
	return _tile_splat_bytes(tgx, tgz).duplicate()

# The paint channel index that owns the spot under a local-space terrain
# position: 0..5 when painted there, -1 when unpainted. Same lattice math the
# overlay shader uses to find the paint texel.
func channel_at_local(pos: Vector3) -> int:
	var edge := TILE_EDGE
	var tgx := int(floor(pos.x / edge))
	var tgz := int(floor(pos.z / edge))
	var tx := tgx * edge
	var tz := tgz * edge
	var step := edge / float(PAINT_TILE_PX)
	var px := clampi(int(floor((pos.x - tx) / step)), 0, PAINT_TILE_PX - 1)
	var py := clampi(int(floor((pos.z - tz) / step)), 0, PAINT_TILE_PX - 1)
	var key := Vector2i(tgx, tgz)
	if not tile_paints.has(key):
		return -1
	var idx := py * PAINT_TILE_PX + px
	var top := _tile_top_bytes(tgx, tgz)[idx]
	return top if top < PAINT_PLANES else -1

# Restore tiles from a paint snapshot. `entries` is an array of
# [Vector2i, PackedByteArray] pairs; an all-zero (or malformed) payload clears
# the tile back to unpainted, dropping any per-tile overlays too. An optional
# third element [textures, tilings, depths] rewrites those per-tile overrides
# verbatim (empty lists erase them) — used by the wipe undo/redo. Rebuilds the
# atlases on the next texture request.
func paint_restore(entries: Array) -> void:
	for e in entries:
		var key: Vector2i = e[0]
		var data: Variant = e[1]
		var payload := PackedByteArray()
		var ok := false
		if data is PackedByteArray and data.size() == PAINT_PLANES * PAINT_PLANE_BYTES:
			payload = data
			ok = true
		var materialized := ok and _splats_nonzero(payload)
		if materialized:
			_tile_splats[key] = payload.duplicate()
			tile_paints[key] = {}
		else:
			_tile_splats.erase(key)
			tile_paints.erase(key)
			tile_textures.erase(key)
			tile_tilings.erase(key)
			tile_depths.erase(key)
		if e.size() >= 3:
			var meta: Array = e[2]
			var meta_textures: Array = meta[0] if meta.size() > 0 else []
			var meta_tilings: Array = meta[1] if meta.size() > 1 else []
			var meta_depths: Array = meta[2] if meta.size() > 2 else []
			if meta_textures.is_empty():
				tile_textures.erase(key)
			else:
				tile_textures[key] = (meta_textures as Array).duplicate()
			if meta_tilings.is_empty():
				tile_tilings.erase(key)
			else:
				tile_tilings[key] = (meta_tilings as Array).duplicate()
			if meta_depths.is_empty():
				tile_depths.erase(key)
			else:
				tile_depths[key] = (meta_depths as Array).duplicate()
		tile_tops.erase(key)
	_paint_atlas_dirty = true
	_top_atlas_dirty = true

func _splats_nonzero(data: PackedByteArray) -> bool:
	for b in data:
		if b != 0:
			return true
	return false

# The single RGBA splatmap atlas of all channels over the tile lattice (row/col
# aligned with the WMT tile grid): texel = (plane 0, 1, 2, 3) of that tile's
# splatmap. Rebuilt lazily; returns null while unpainted.
func paint_splat_texture() -> ImageTexture:
	if _paint_atlas_dirty:
		_rebuild_paint_atlas()
	return _splat_atlas_tex

func _rebuild_paint_atlas() -> void:
	_paint_atlas_dirty = false
	var tx := tile_count_x()
	var tz := tile_count_z()
	# Every tile owns a SPLAT_PITCH-wide cell: the real PAINT_TILE_PX block
	# centered with an SPLAT_PAD ring of ITS OWN edge texels cloned around it
	# (lead + tail). Zero-guaranteed only where no tile is painted there - a
	# painted block is edge-replicated, so a bilinear tap near a tile seam reads
	# the tile's own clamped edge and painted sides stay painted.
	var w := maxi(tx, 1) * SPLAT_PITCH
	var h := maxi(tz, 1) * SPLAT_PITCH
	var ox := tile_origin_x()
	var oz := tile_origin_z()
	if _splat_atlas_img == null or _splat_atlas_img.get_width() != w \
			or _splat_atlas_img.get_height() != h:
		_splat_atlas_img = Image.create(w, h, false, Image.FORMAT_RGBA8)
	# Neutral fill must be ALL-ZERO RGBA: the alpha byte here is paint CHANNEL 3
	# (RGBA splat), not a texture alpha. Filling A=255 made every untouched
	# texel read as fully channel-3 covered, which the shader's dead-channel
	# guard rendered black instead of showing the white base.
	_splat_atlas_img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for key in tile_paints:
		var tgx: int = (key as Vector2i).x
		var tgz: int = (key as Vector2i).y
		var px := (tgx - ox) * SPLAT_PITCH
		var py := (tgz - oz) * SPLAT_PITCH
		if px < 0 or py < 0 or px + SPLAT_PITCH > w or py + SPLAT_PITCH > h:
			continue
		var splats: PackedByteArray = _tile_splats.get(key, PackedByteArray())
		if splats.size() != PAINT_PLANES * PAINT_PLANE_BYTES:
			continue
		# Interleave the four R8 planes into one RGBA splatmap tile block.
		var rgba := PackedByteArray()
		rgba.resize(PAINT_PLANE_BYTES * PAINT_PLANES)
		for i in range(PAINT_PLANE_BYTES):
			rgba[i * PAINT_PLANES + 0] = splats[i]
			rgba[i * PAINT_PLANES + 1] = splats[PAINT_PLANE_BYTES + i]
			rgba[i * PAINT_PLANES + 2] = splats[2 * PAINT_PLANE_BYTES + i]
			rgba[i * PAINT_PLANES + 3] = splats[3 * PAINT_PLANE_BYTES + i]
		var timg := Image.create_from_data(
			PAINT_TILE_PX, PAINT_TILE_PX, false, Image.FORMAT_RGBA8, rgba)
		_splat_atlas_img.blit_rect(
			_padded_splat_block(timg, PAINT_TILE_PX, SPLAT_PAD),
			Rect2i(0, 0, SPLAT_PITCH, SPLAT_PITCH), Vector2i(px, py))
	if _splat_atlas_tex == null or not is_instance_valid(_splat_atlas_tex) \
			or _splat_atlas_tex.get_width() != w or _splat_atlas_tex.get_height() != h:
		_splat_atlas_tex = ImageTexture.create_from_image(_splat_atlas_img)
	else:
		_splat_atlas_tex.update(_splat_atlas_img)

# Clones a tile's real splat block plus an edge-replicated ring of its own
# border texels (SPLAT_PAD on all four sides). Replication keeps the bilinear
# seam sampling continuous: a tap just inside a block edge blends the edge with
# a copy of the SAME edge instead of a zero gap (which faded painted tiles to
# the bare white base) or a neighbour block (which bled alien textures in).
func _padded_splat_block(timg: Image, tile_px: int, pad: int) -> Image:
	var pitch := tile_px + 2 * pad
	var out := Image.create(pitch, pitch, false, Image.FORMAT_RGBA8)
	out.blit_rect(
		timg, Rect2i(0, 0, tile_px, tile_px),
		Vector2i(pad, pad))
	for r in range(pad):
		out.blit_rect(timg, Rect2i(0, 0, tile_px, 1), Vector2i(pad, r))
		out.blit_rect(timg, Rect2i(0, tile_px - 1, tile_px, 1),
			Vector2i(pad, pad + tile_px + r))
	for c in range(pad):
		out.blit_rect(timg, Rect2i(0, 0, 1, tile_px), Vector2i(c, pad))
		out.blit_rect(timg, Rect2i(tile_px - 1, 0, 1, tile_px),
			Vector2i(pad + tile_px + c, pad))
	var tl := timg.get_pixel(0, 0)
	var tr := timg.get_pixel(tile_px - 1, 0)
	var bl := timg.get_pixel(0, tile_px - 1)
	var br := timg.get_pixel(tile_px - 1, tile_px - 1)
	for r in range(pad):
		for c in range(pad):
			out.set_pixel(c, r, tl)
			out.set_pixel(pad + tile_px + c, r, tr)
			out.set_pixel(c, pad + tile_px + r, bl)
			out.set_pixel(pad + tile_px + c,
				pad + tile_px + r, br)
	return out

# The single R8 atlas telling WHICH channel owns each texel's surface (byte =
# channel index, 255 = bare ground -> base material). Same lattice/world
# alignment as the splatmap; consumed directly by the overlay shader.
func paint_top_texture() -> ImageTexture:
	if _top_atlas_dirty:
		_rebuild_top_atlas()
	return _top_atlas_tex

func _rebuild_top_atlas() -> void:
	_top_atlas_dirty = false
	var tx := tile_count_x()
	var tz := tile_count_z()
	var w := maxi(tx, 1) * PAINT_TILE_PX
	var h := maxi(tz, 1) * PAINT_TILE_PX
	var ox := tile_origin_x()
	var oz := tile_origin_z()
	if _top_atlas_img == null or _top_atlas_img.get_width() != w \
			or _top_atlas_img.get_height() != h:
		_top_atlas_img = Image.create(w, h, false, Image.FORMAT_R8)
	_top_atlas_img.fill(Color(1.0, 0.0, 0.0, 1.0))
	for key in tile_paints:
		var tgx: int = (key as Vector2i).x
		var tgz: int = (key as Vector2i).y
		var px := (tgx - ox) * PAINT_TILE_PX
		var py := (tgz - oz) * PAINT_TILE_PX
		if px < 0 or py < 0 or px + PAINT_TILE_PX > w or py + PAINT_TILE_PX > h:
			continue
		var tops: PackedByteArray = _tile_top_bytes(tgx, tgz)
		if tops.size() != PAINT_PLANE_BYTES:
			continue
		var timg := Image.create_from_data(
			PAINT_TILE_PX, PAINT_TILE_PX, false, Image.FORMAT_R8, tops)
		_top_atlas_img.blit_rect(
			timg, Rect2i(0, 0, PAINT_TILE_PX, PAINT_TILE_PX), Vector2i(px, py))
	if _top_atlas_tex == null or not is_instance_valid(_top_atlas_tex) \
			or _top_atlas_tex.get_width() != w or _top_atlas_tex.get_height() != h:
		_top_atlas_tex = ImageTexture.create_from_image(_top_atlas_img)
	else:
		_top_atlas_tex.update(_top_atlas_img)

# Chunk-lattice slot of absolute cell (gx, gz), or null if the cell lies
# outside the current grid.
func chunk_slot_of_cell(gx: int, gz: int) -> Variant:
	if gx < cell_x0 or gz < cell_z0 or gx >= cell_x1 or gz >= cell_z1:
		return null
	return _chunk_of(gx, gz)

func get_center_average(gx: int, gz: int) -> float:
	if gx < cell_x0 or gz < cell_z0 or gx >= cell_x1 or gz >= cell_z1:
		return 0.0
	return (_height_at(gx, gz) + _height_at(gx + 1, gz) + _height_at(gx, gz + 1) + _height_at(gx + 1, gz + 1)) * 0.25

func _derive_centers() -> void:
	var n := GRID_SQUARES_X * GRID_SQUARES_Z
	if n <= 0:
		center_h = PackedFloat32Array()
		return
	if center_h.size() != n:
		center_h.resize(n)
	for gz in range(GRID_SQUARES_Z):
		for gx in range(GRID_SQUARES_X):
			var ax := cell_x0 + gx
			var az := cell_z0 + gz
			var h := (_height_at(ax, az) + _height_at(ax + 1, az) + _height_at(ax, az + 1) + _height_at(ax + 1, az + 1)) * 0.25
			center_h[gz * GRID_SQUARES_X + gx] = h

# Exact height of the rendered X mesh at a local point: finds the tile cell
# and the triangle inside it, then interpolates with corner/center heights.
func sample_surface(local_pos: Vector3) -> float:
	var fx := local_pos.x / SQUARE_EDGE
	var fz := local_pos.z / SQUARE_EDGE
	if fx < float(cell_x0) or fz < float(cell_z0) or fx >= float(cell_x1) or fz >= float(cell_z1):
		return 0.0
	var gx := int(floorf(fx))
	var gz := int(floorf(fz))
	var tx := fx - gx
	var tz := fz - gz
	var h_tl := _height_at(gx, gz)
	var h_tr := _height_at(gx + 1, gz)
	var h_br := _height_at(gx + 1, gz + 1)
	var h_bl := _height_at(gx, gz + 1)
	var h_c := _center_height(_center_index(gx, gz))
	var p := Vector2(tx, tz)
	var tl := Vector2(0.0, 0.0)
	var tr := Vector2(1.0, 0.0)
	var br := Vector2(1.0, 1.0)
	var bl := Vector2(0.0, 1.0)
	var c := Vector2(0.5, 0.5)
	if _point_in_tri(p, tr, c, tl):
		return _tri_height(p, tr, c, tl, h_tr, h_c, h_tl)
	if _point_in_tri(p, br, c, tr):
		return _tri_height(p, br, c, tr, h_br, h_c, h_tr)
	if _point_in_tri(p, bl, c, br):
		return _tri_height(p, bl, c, br, h_bl, h_c, h_br)
	return _tri_height(p, tl, c, bl, h_tl, h_c, h_bl)

func _cross2(a: Vector2, b: Vector2) -> float:
	return a.x * b.y - a.y * b.x

func _point_in_tri(p: Vector2, a: Vector2, b: Vector2, c: Vector2) -> bool:
	var s1 := _cross2(b - a, p - a)
	var s2 := _cross2(c - b, p - b)
	var s3 := _cross2(a - c, p - c)
	var has_neg := s1 < 0.0 or s2 < 0.0 or s3 < 0.0
	var has_pos := s1 > 0.0 or s2 > 0.0 or s3 > 0.0
	return not (has_neg and has_pos)

func _tri_height(p: Vector2, a: Vector2, b: Vector2, c: Vector2, ha: float, hb: float, hc: float) -> float:
	var den := _cross2(b - a, c - a)
	if absf(den) < 1e-12:
		return ha
	var wa := _cross2(b - p, c - p) / den
	var wb := _cross2(c - p, a - p) / den
	var wc := 1.0 - wa - wb
	return ha * wa + hb * wb + hc * wc

func sample_height(local_pos: Vector3) -> float:
	var fx := local_pos.x / SQUARE_EDGE
	var fz := local_pos.z / SQUARE_EDGE
	var gx := floorf(fx)
	var gz := floorf(fz)
	var tx := fx - gx
	var tz := fz - gz
	var h00 := _height_at(int(gx), int(gz))
	var h10 := _height_at(int(gx) + 1, int(gz))
	var h01 := _height_at(int(gx), int(gz) + 1)
	var h11 := _height_at(int(gx) + 1, int(gz) + 1)
	var h0 := lerpf(h00, h10, tx)
	var h1 := lerpf(h01, h11, tx)
	return lerpf(h0, h1, tz)

func clear_heights() -> void:
	if GRID_SQUARES_X <= 0 or GRID_SQUARES_Z <= 0:
		return
	heightmap.fill(0.0)
	center_h.fill(0.0)
	hidden_tiles.fill(0)
	height_version += 1
	rebuild_mesh()

# Compact binary ".wmt" chunk file. Each chunk saves as its OWN file named
# `cx_cz.wmt` (chunk lattice coords), so with N chunks there are N files. The
# 0_0.wmt file is the "master": loading it auto-loads every sibling chunk file
# in the same folder back into one node. This keeps single-chunk writes tiny
# (129x129 corner lattice + 128x128 centers + 16x16 hide flags) no matter how
# big the terrain gets.
#
# Per-chunk (version 5) layout:
#   offset  size         field
#   0       4            magic "WMTX" (u32, little-endian)
#   4       4            version (u32 = 5)
#   8       4            grid_squares_x (u32 = 128 = squares per chunk side)
#   12      4            grid_squares_z (u32 = 128)
#   16      4            square_edge (f32 = 2.0)
#   20      (G+1)^2*4    heightmap: corner lattice, G = sx = sz
#   ...     G^2*4        center_h: center vertex heights (per square)
#   ...     T^2          hidden_tiles: 1 byte per tile (T = G/8 = 16), 1 = hidden
#   ...     u32 paint_count, then per painted tile (v9):
#             u8 ti, u8 tj, u32 dlen, dlen R8 plane bytes (PAINT_PLANES *
#             PAINT_TILE_PX^2; one independent single-channel splat plane per
#             paint channel), then u8 tex_count, then tex_count entries
#             [u8 slot, u8 len, len UTF-8 path]: the tile's per-slot texture
#             overrides (slot 0..PAINT_PLANES-1 = paint channels). Slots
#             without an entry mean "no texture".
#             Then (v10+) u8 tiling_count, then tiling_count entries
#             [u8 slot, u8 byte] where byte = round(repeat) - 1 (so repeat
#             1..256 encodes to 0..255): the tile's per-slot texture repeat.
#             Tiles without tiling entries use the editor's global default.
#
# Version 2/3 files (single chunk) and version 4 files (multi-chunk, one blob,
# no center array in v2) still load when their grid size matches the current
# chunk size.
const WMT_MAGIC_NUM := 0x58544D57
const WMT_VERSION := 13
const CHUNK_FILE_RE := "^(-?\\d+)_(-?\\d+)\\.wmt$"

func _write_chunk_file(dest: String, cx: int, cz: int) -> bool:
	if not has_chunk(cx, cz):
		return false
	var bx := cx * CHUNK_CELLS
	var bz := cz * CHUNK_CELLS
	if bx < cell_x0 or bz < cell_z0 or bx + CHUNK_CELLS > cell_x1 or bz + CHUNK_CELLS > cell_z1:
		return false
	var n := CHUNK_CELLS
	var cs := n + 1  # corner grid side (borders included)
	var hm := PackedFloat32Array()
	hm.resize(cs * cs)
	for cy in range(cs):
		for cx2 in range(cs):
			hm[cy * cs + cx2] = heightmap[_corner_index(bx + cx2, bz + cy)]
	var ch := PackedFloat32Array()
	ch.resize(n * n)
	var hid := PackedByteArray()
	hid.resize(CHUNK_TILES * CHUNK_TILES)
	hid.fill(0)
	var gsx := GRID_SQUARES_X
	for j in range(n):
		for i in range(n):
			ch[j * n + i] = center_h[(bz + j - cell_z0) * gsx + (bx + i - cell_x0)]
	# One hide byte per tile (aggregate the 8x8 cell block).
	for tj in range(CHUNK_TILES):
		for ti in range(CHUNK_TILES):
			var hid_byte := 0
			for dj in range(SQUARES_PER_TILE):
				for di in range(SQUARES_PER_TILE):
					var src := (bz + tj * SQUARES_PER_TILE + dj - cell_z0) * gsx \
							+ (bx + ti * SQUARES_PER_TILE + di - cell_x0)
					if src >= 0 and src < hidden_tiles.size() and hidden_tiles[src] != 0:
						hid_byte = 1
			hid[tj * CHUNK_TILES + ti] = hid_byte
	var data := PackedByteArray()
	data.resize(20)
	data.encode_u32(0, WMT_MAGIC_NUM)
	data.encode_u32(4, WMT_VERSION)
	data.encode_u32(8, n)
	data.encode_u32(12, n)
	data.encode_float(16, SQUARE_EDGE)
	data.append_array(hm.to_byte_array())
	data.append_array(ch.to_byte_array())
	data.append_array(hid)
	# v10+ paint block: u32 count, then per painted tile: u8 ti, u8 tj,
	# u32 data_len, then data_len raw R8 plane bytes (PAINT_PLANES *
	# PAINT_TILE_PX^2, one plane per channel), then per-tile texture overrides
	# (u8 count, then [u8 slot, u8 len, len-path] entries), then per-tile
	# tiling overrides (u8 count, then [u8 slot, u8 tilbyte]) and the v11
	# per-tile surface-owner map (u8 flag; when 1, PAINT_TILE_PX^2 R8 bytes, one
	# per splat texel, 0..3 = channel / 255 = bare). The plane data, texture
	# paths and tilings live IN the file - no sidecar PNGs.
	var paint_tiles: Array = []
	for tj in range(CHUNK_TILES):
		for ti in range(CHUNK_TILES):
			var key := Vector2i(cx * CHUNK_TILES + ti, cz * CHUNK_TILES + tj)
			if tile_paints.has(key):
				paint_tiles.append([ti, tj, key])
	data.resize(data.size() + 4)
	data.encode_u32(data.size() - 4, paint_tiles.size())
	for pt in paint_tiles:
		var tkey: Vector2i = pt[2]
		var raw: PackedByteArray = _tile_splat_bytes(tkey.x, tkey.y)
		data.append(pt[0])
		data.append(pt[1])
		data.resize(data.size() + 4)
		data.encode_u32(data.size() - 4, raw.size())
		data.append_array(raw)
		var tarr: Array = []
		var stor: Variant = tile_textures.get(tkey)
		if stor is Array:
			tarr = stor
		data.append(tarr.size())
		for s in range(tarr.size()):
			var path_b: PackedByteArray = str(tarr[s]).to_utf8_buffer()
			data.append(s)
			data.append(path_b.size())
			data.append_array(path_b)
		# v10: per-tile per-channel tiling overrides (byte = round(repeat) - 1).
		var tils: Array = []
		var tstor: Variant = tile_tilings.get(tkey)
		if tstor is Array:
			tils = tstor
		data.append(tils.size())
		for s in range(tils.size()):
			data.append(s)
			data.append(clampi(int(roundf(float(tils[s]))) - 1, 0, 255))
		# v11: per-texel surface-owner map (always explicit when saving; loads
		# of older files derive the same map from the splat weights).
		var tops: PackedByteArray = _tile_top_bytes(tkey.x, tkey.y)
		if tops.size() == PAINT_PLANE_BYTES:
			data.append(1)
			data.resize(data.size() + 2)
			data.encode_u16(data.size() - 2, tops.size())
			data.append_array(tops)
		else:
			data.append(0)
	# v13+ vertex-tint splatmap block: u32 tile count, then per painted tile a
	# chunk-relative tile index (u8 ti, u8 tj), a u32 data_len and the tile's
	# RGBA8 tint block (TINT_TILE_BYTES). Unpainted (neutral) tiles are absent.
	var tint_keys: Array = []
	for tk in tile_tints:
		var tg: Vector2i = tk
		if tg.x >= bx / SQUARES_PER_TILE and tg.x < bx / SQUARES_PER_TILE + CHUNK_TILES \
				and tg.y >= bz / SQUARES_PER_TILE and tg.y < bz / SQUARES_PER_TILE + CHUNK_TILES:
			tint_keys.append(tg)
	data.resize(data.size() + 4)
	data.encode_u32(data.size() - 4, tint_keys.size())
	for tg in tint_keys:
		var blk: PackedByteArray = tile_tints[tg]
		data.append((tg.x - bx / SQUARES_PER_TILE) & 0xFF)
		data.append((tg.y - bz / SQUARES_PER_TILE) & 0xFF)
		data.resize(data.size() + 4)
		data.encode_u32(data.size() - 4, blk.size())
		data.append_array(blk)
	var f := FileAccess.open(dest, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true

# Write one `cx_cz.wmt` chunk file per chunk, into `path`'s base directory.
# `path` itself is the master file (0_0.wmt). `only` optionally limits which
# chunks get rewritten (used on stroke end to touch just moved chunks).
func save_wmt(path: String, only: Array = []) -> bool:
	if chunks.is_empty() or GRID_SQUARES_X * GRID_SQUARES_Z != center_h.size():
		return false
	var base := path.get_base_dir()
	if base == "":
		return false
	if not DirAccess.dir_exists_absolute(base):
		if DirAccess.make_dir_recursive_absolute(base) != OK:
			return false
	var ok := true
	for c in chunks:
		var k: Vector2i = c
		if only.is_empty() or (only as Array).has(k):
			var dest := "%s/%d_%d.wmt" % [base, k.x, k.y]
			if not _write_chunk_file(dest, k.x, k.y):
				ok = false
	return ok

# Parse any .wmt file into a payload dict (or {} on failure):
# {"sx","sz","edge","hm","ch","hidden","paints","corner_hi","chunks"} where
# sx/sz are the stored grid size in SQUARES, `corner_hi` is true when the
# stored hm is a (sx+1)x(sz+1) corner lattice (v5+) and false when it is
# sx x sz (v2/v3), `hidden` holds one byte per TILE (v5+), and `paints` maps
# tile-local (ti,tj) to {"file","color"} (v6+).
func _parse_wmt_file(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data := f.get_buffer(f.get_length())
	f.close()
	if data.size() < 24:
		return {}
	if data.decode_u32(0) != WMT_MAGIC_NUM:
		return {}
	var version: int = data.decode_u32(4)
	if version < 2 or version > WMT_VERSION:
		return {}
	var sx: int = data.decode_u32(8)
	var sz: int = data.decode_u32(12)
	var nchunks := 0
	var body := 24
	var chunk_list: Array = []
	var corner_hi := false
	if version == 4:
		# v4 = legacy multi-chunk single blob. Best-effort: keep the chunk
		# list and grid dims as stored; nothing newer applies.
		nchunks = data.decode_u32(20)
		if nchunks == 0 or data.size() < 24 + nchunks * 8:
			return {}
		for i in range(nchunks):
			chunk_list.append(Vector2i(data.decode_s32(24 + i * 8), data.decode_s32(24 + i * 8 + 4)))
		body = 24 + nchunks * 8
	else:
		# v2/v3/v5 = single chunk. Per-chunk files must match the current
		# chunk size so the chunk lattice stays consistent.
		body = 20
		chunk_list = [Vector2i(0, 0)]
		if sx != CHUNK_CELLS or sz != CHUNK_CELLS:
			return {}
		corner_hi = version >= 5
	var hm_row := sx + (1 if corner_hi else 0)
	if data.size() < body + hm_row * hm_row * 4:
		return {}
	var hm := data.slice(body, body + hm_row * hm_row * 4).to_float32_array()
	if hm.size() != hm_row * hm_row:
		return {}
	var ch := PackedFloat32Array()
	ch.resize(sx * sz)
	ch.fill(0.0)
	if (version == 3 or version == 5) and data.size() >= body + hm_row * hm_row * 4 + sx * sz * 4:
		var ct := data.slice(body + hm_row * hm_row * 4, body + hm_row * hm_row * 4 + sx * sz * 4).to_float32_array()
		if ct.size() == sx * sz:
			ch = ct
		else:
			_derive_payload_centers(hm, sx, sz, corner_hi, ch)
	else:
		_derive_payload_centers(hm, sx, sz, corner_hi, ch)
	var hid := PackedByteArray()
	var tiles_per_side := CHUNK_TILES if corner_hi else 0
	if version >= 5 and (sx / SQUARES_PER_TILE) == CHUNK_TILES \
			and data.size() >= body + hm_row * hm_row * 4 + sx * sz * 4 + tiles_per_side * tiles_per_side:
		hid = data.slice(body + hm_row * hm_row * 4 + sx * sz * 4, \
				body + hm_row * hm_row * 4 + sx * sz * 4 + tiles_per_side * tiles_per_side)
	var paints := {}
	var paint_splats := {}
	var paint_textures := {}
	var paint_tilings := {}
	var paint_tops := {}
	var paint_pos := -1
	if version >= 6:
		var pos := body + hm_row * hm_row * 4 + sx * sz * 4 + tiles_per_side * tiles_per_side
		if data.size() >= pos + 4:
			var cnt := data.decode_u32(pos)
			pos += 4
			for k in range(cnt):
				if data.size() < pos + 6:
					break
				var ti := data.decode_u8(pos)
				var tj := data.decode_u8(pos + 1)
				var kk := Vector2i(ti, tj)
				pos += 2
				if version >= 9:
					# v9+: PAINT_PLANES raw R8 splat planes + per-tile paths.
					if data.size() < pos + 4:
						break
					var dlen := data.decode_u32(pos)
					pos += 4
					if data.size() < pos + dlen:
						break
					if dlen == PAINT_PLANES * PAINT_PLANE_BYTES:
						paint_splats[kk] = data.slice(pos, pos + dlen)
						paints[kk] = {}
					pos += dlen
					var tcnt := 0
					if data.size() >= pos + 1:
						tcnt = data.decode_u8(pos)
						pos += 1
					var tarr: Array = []
					for t in range(tcnt):
						if data.size() < pos + 2:
							break
						var slot := data.decode_u8(pos)
						var nlen := data.decode_u8(pos + 1)
						pos += 2
						if data.size() < pos + nlen:
							break
						while tarr.size() <= slot:
							tarr.append("")
						tarr[slot] = data.slice(pos, pos + nlen).get_string_from_utf8()
						pos += nlen
					if not tarr.is_empty():
						paint_textures[kk] = tarr
					# v10+: per-tile per-channel tiling overrides.
					if version >= 10:
						var tilcnt := 0
						if data.size() >= pos + 1:
							tilcnt = data.decode_u8(pos)
							pos += 1
						var tarr2: Array = []
						for t in range(tilcnt):
							if data.size() < pos + 2:
								break
							var slot2 := data.decode_u8(pos)
							var b := data.decode_u8(pos + 1)
							pos += 2
							while tarr2.size() <= slot2:
								tarr2.append(16.0)
							tarr2[slot2] = float(b + 1)
						if not tarr2.is_empty():
							paint_tilings[kk] = tarr2
						# v11: per-texel surface-owner map (0..3 = channel,
						# 255 = bare). Older files simply omit it.
						if version >= 11:
							var topflag := 0
							if data.size() >= pos + 1:
								topflag = data.decode_u8(pos)
								pos += 1
							if topflag != 0:
								if data.size() < pos + 2:
									break
								var tlen := data.decode_u16(pos)
								pos += 2
								if data.size() < pos + tlen:
									break
								if tlen == PAINT_PLANE_BYTES:
									paint_tops[kk] = data.slice(pos, pos + tlen)
								pos += tlen
				elif version >= 8:
					# v8: embedded RGBA8 splatmap + per-tile texture paths.
					# Decode the RGBA image into the four R8 splat planes.
					if data.size() < pos + 4:
						break
					var dlen := data.decode_u32(pos)
					pos += 4
					if data.size() < pos + dlen:
						break
					if dlen == PAINT_TILE_PX * PAINT_TILE_PX * 4:
						var raw := data.slice(pos, pos + dlen)
						var img := Image.create_from_data(PAINT_TILE_PX, PAINT_TILE_PX, false,
								Image.FORMAT_RGBA8, raw)
						if img != null:
							paint_splats[kk] = _splats_from_planes(img)
							paints[kk] = {}
						pos += dlen
						var tcnt := 0
						if data.size() >= pos + 1:
							tcnt = data.decode_u8(pos)
							pos += 1
						var tarr: Array = []
						for t in range(tcnt):
							if data.size() < pos + 2:
								break
							var slot := data.decode_u8(pos)
							var nlen := data.decode_u8(pos + 1)
							pos += 2
							if data.size() < pos + nlen:
								break
							while tarr.size() <= slot:
								tarr.append("")
							tarr[slot] = data.slice(pos, pos + nlen).get_string_from_utf8()
							pos += nlen
						if not tarr.is_empty():
							paint_textures[kk] = tarr
					else:
						pos += dlen
				elif version == 7:
					# v7 embedded RGBA8 pixel data was channel-COLOR per texel;
					# remap each opaque texel to its owning channel's splat
					# plane (best-effort forward port).
					if data.size() < pos + 4:
						break
					var dlen := data.decode_u32(pos)
					pos += 4
					if data.size() < pos + dlen:
						break
					if dlen == PAINT_TILE_PX * PAINT_TILE_PX * 4:
						var raw := data.slice(pos, pos + dlen)
						var img := Image.create_from_data(PAINT_TILE_PX, PAINT_TILE_PX, false,
								Image.FORMAT_RGBA8, raw)
						if img != null:
							paint_splats[kk] = _remap_color_paint(img)
							paints[kk] = {}
						pos += dlen
					else:
						pos += dlen
				else:
					# v6 legacy: sidecar PNG file name + nominal channel color.
					if data.size() < pos + 8:
						break
					var nlen := data.decode_u32(pos)
					pos += 4
					if data.size() < pos + nlen + 4:
						break
					var name := data.slice(pos, pos + nlen).get_string_from_utf8()
					pos += nlen
					paints[kk] = {
						"file": name,
						"color": Color(data.decode_u8(pos) / 255.0, data.decode_u8(pos + 1) / 255.0,
								data.decode_u8(pos + 2) / 255.0, data.decode_u8(pos + 3) / 255.0),
					}
					pos += 4
			paint_pos = pos
	# v13+: vertex-tint splatmap block after the paint block. Per painted
	# tile: u8 ti, u8 tj (chunk-relative), u32 data_len, data_len RGBA8 tint
	# bytes. v12 files carried the old per-vertex lattice instead - kept byte-
	# aligned for the skip here, but its tints are superseded by v13 blocks.
	var tint_tiles_p := {}
	if version >= 13 and paint_pos >= 0 and data.size() >= paint_pos + 4:
		var tcnt := data.decode_u32(paint_pos)
		paint_pos += 4
		for k in range(tcnt):
			if data.size() < paint_pos + 6:
				break
			var ti: int = data.decode_u8(paint_pos)
			var tj: int = data.decode_u8(paint_pos + 1)
			var dlen := data.decode_u32(paint_pos + 2)
			paint_pos += 6
			if data.size() < paint_pos + dlen:
				paint_pos += dlen
				break
			if dlen == TINT_TILE_BYTES:
				tint_tiles_p[Vector2i(ti, tj)] = data.slice(paint_pos, paint_pos + dlen)
			paint_pos += dlen
	elif version >= 12 and paint_pos >= 0 and data.size() >= paint_pos + 4:
		var vcnt := data.decode_u32(paint_pos)
		paint_pos += 4
		for k in range(vcnt):
			if data.size() < paint_pos + 8:
				break
			paint_pos += 8
	return {
		"sx": sx,
		"sz": sz,
		"edge": data.decode_float(16),
		"hm": hm,
		"ch": ch,
		"hidden": hid,
		"paints": paints,
		"paint_splats": paint_splats,
		"paint_textures": paint_textures,
		"paint_tilings": paint_tilings,
		"paint_tops": paint_tops,
		"tint_tiles": tint_tiles_p,
		"corner_hi": corner_hi,
		"chunks": chunk_list,
	}

# Corner-average derivation for files without center data (v2). Matches the
# old whole-grid derive: out-of-range edge corners are treated as 0.
func _derive_payload_centers(hm: PackedFloat32Array, sx: int, sz: int, corner_hi: bool, ch: PackedFloat32Array) -> void:
	var hm_row := sx + (1 if corner_hi else 0)
	for j in range(sz):
		for i in range(sx):
			var i0 := i
			var i1 := i + 1
			var j0 := j
			var j1 := j + 1
			if not corner_hi:
				i1 = i + 1 if i + 1 < sx else sx - 1
				j1 = j + 1 if j + 1 < sz else sz - 1
			var h00 := hm[j0 * hm_row + i0]
			var h10 := hm[j0 * hm_row + i1]
			var h01 := hm[j1 * hm_row + i0]
			var h11 := hm[j1 * hm_row + i1]
			ch[j * sx + i] = (h00 + h10 + h01 + h11) * 0.25

# Decode the old v7/v8 channel-COLOR tile image into the four R8 splat planes:
# each opaque texel snaps to its nearest old palette colour and pushes that
# channel's plane to full. Old channel map: Red->0, Green->1, Blue->2,
# White->0, Black->3 (legacy 5-colour palettes clamped to PAINT_PLANES).
func _remap_color_paint(img: Image) -> PackedByteArray:
	var old := [
		Color(1.0, 0.0, 0.0),
		Color(0.0, 1.0, 0.0),
		Color(0.0, 0.0, 1.0),
		Color(1.0, 1.0, 1.0),
		Color(0.0, 0.0, 0.0),
	]
	var to_channel := [0, 1, 2, 0, 3]
	var out := PackedByteArray()
	out.resize(PAINT_PLANES * PAINT_PLANE_BYTES)
	for py in range(PAINT_TILE_PX):
		for px in range(PAINT_TILE_PX):
			var c := img.get_pixel(px, py)
			if c.a < 0.5:
				continue
			var best := 0
			var bd := 1e10
			for i in old.size():
				var dc: Color = c - old[i]
				var d2: float = dc.r * dc.r + dc.g * dc.g + dc.b * dc.b
				if d2 < bd:
					bd = d2
					best = i
			var ch: int = to_channel[best]
			out[ch * PAINT_PLANE_BYTES + py * PAINT_TILE_PX + px] = 255
	return out

# Decode the old v8 RGBA tile image (R/G/B = three black/white splat planes,
# A = painted marker) into one RGBA splatmap: four paint planes (R,G,B,A).
func _splats_from_planes(img: Image) -> PackedByteArray:
	var out := PackedByteArray()
	out.resize(PAINT_PLANES * PAINT_PLANE_BYTES)
	for py in range(PAINT_TILE_PX):
		for px in range(PAINT_TILE_PX):
			var c := img.get_pixel(px, py)
			var idx := py * PAINT_TILE_PX + px
			out[0 * PAINT_PLANE_BYTES + idx] = clampi(int(round(c.r * 255.0)), 0, 255)
			out[1 * PAINT_PLANE_BYTES + idx] = clampi(int(round(c.g * 255.0)), 0, 255)
			out[2 * PAINT_PLANE_BYTES + idx] = clampi(int(round(c.b * 255.0)), 0, 255)
			out[3 * PAINT_PLANE_BYTES + idx] = clampi(int(round(c.a * 255.0)), 0, 255)
	return out

# Place a payload's chunk into this node's grid arrays, offset by chunk-lattice
# key `key`. Payload hm may be a (G+1)x(G+1) corner lattice (corner_hi) or a
# GxG grid of cell-TL corners (legacy); hidden is a per-tile byte array.
func _place_payload(key: Vector2i, p: Dictionary) -> void:
	var psx: int = p["sx"]
	var psz: int = p["sz"]
	var phm: PackedFloat32Array = p["hm"]
	var pch: PackedFloat32Array = p["ch"]
	var phid: PackedByteArray = p["hidden"]
	var paints: Dictionary = p.get("paints", {})
	var corner_hi: bool = p["corner_hi"]
	var bx: int = (key as Vector2i).x * CHUNK_CELLS
	var bz: int = (key as Vector2i).y * CHUNK_CELLS
	var hm_row := psx + (1 if corner_hi else 0)
	var sx := GRID_SQUARES_X
	var cnx := sx + 1
	for j in range(psz + (1 if corner_hi else 0)):
		for i in range(psx + (1 if corner_hi else 0)):
			var ax := bx + i
			var az := bz + j
			if ax < cell_x0 or az < cell_z0 or ax > cell_x1 or az > cell_z1:
				continue
			heightmap[(az - cell_z0) * cnx + (ax - cell_x0)] = maxf(phm[j * hm_row + i], 0.0)
	for j in range(psz):
		for i in range(psx):
			var ax := bx + i
			var az := bz + j
			if ax >= cell_x1 or az >= cell_z1:
				continue
			center_h[(az - cell_z0) * sx + (ax - cell_x0)] = maxf(pch[j * psx + i], 0.0)
	var tiles := CHUNK_TILES if corner_hi else 0
	if phid.size() == tiles * tiles:
		for tj in range(tiles):
			for ti in range(tiles):
				var flag := phid[tj * tiles + ti]
				for dj in range(SQUARES_PER_TILE):
					for di in range(SQUARES_PER_TILE):
						var ax := bx + ti * SQUARES_PER_TILE + di
						var az := bz + tj * SQUARES_PER_TILE + dj
						if ax >= cell_x1 or az >= cell_z1:
							continue
						hidden_tiles[(az - cell_z0) * sx + (ax - cell_x0)] = flag
	for ptk in paints:
		var ti: int = (ptk as Vector2i).x
		var tj: int = (ptk as Vector2i).y
		var tgx := bx / SQUARES_PER_TILE + ti
		var tgz := bz / SQUARES_PER_TILE + tj
		tile_paints[Vector2i(tgx, tgz)] = paints[ptk]
	# v9 embedded splat planes hydrate the plane cache; legacy v6 stays lazy
	# (its nominal color fill is not representable as splats).
	var paint_splats: Dictionary = p.get("paint_splats", {})
	for pik in paint_splats:
		var tgx := bx / SQUARES_PER_TILE + (pik as Vector2i).x
		var tgz := bz / SQUARES_PER_TILE + (pik as Vector2i).y
		_tile_splats[Vector2i(tgx, tgz)] = paint_splats[pik]
	# v8/v9/v10 per-tile texture overrides (slot 0..PAINT_PLANES-1 channels).
	var paint_textures: Dictionary = p.get("paint_textures", {})
	for ptk2 in paint_textures:
		var tgx := bx / SQUARES_PER_TILE + (ptk2 as Vector2i).x
		var tgz := bz / SQUARES_PER_TILE + (ptk2 as Vector2i).y
		tile_textures[Vector2i(tgx, tgz)] = (paint_textures[ptk2] as Array).duplicate()
	# v10 per-tile tiling overrides (same scoping as the textures).
	var paint_tilings: Dictionary = p.get("paint_tilings", {})
	for ptk3 in paint_tilings:
		var tgx := bx / SQUARES_PER_TILE + (ptk3 as Vector2i).x
		var tgz := bz / SQUARES_PER_TILE + (ptk3 as Vector2i).y
		tile_tilings[Vector2i(tgx, tgz)] = (paint_tilings[ptk3] as Array).duplicate()
	# v11 per-texel surface-owner maps (paint order for the eyedropper).
	# Tiles without one (older files) derive it lazily from the splat weights.
	var paint_tops: Dictionary = p.get("paint_tops", {})
	for ptk4 in paint_tops:
		var tgx := bx / SQUARES_PER_TILE + (ptk4 as Vector2i).x
		var tgz := bz / SQUARES_PER_TILE + (ptk4 as Vector2i).y
		tile_tops[Vector2i(tgx, tgz)] = (paint_tops[ptk4] as PackedByteArray).duplicate()
	# v13 per-tile vertex-tint splatmap blocks, chunk-relative tile indices.
	var tint_blocks: Dictionary = p.get("tint_tiles", {})
	for tbk in tint_blocks:
		var tg: Vector2i = tbk
		var tint_key := Vector2i(bx / SQUARES_PER_TILE + tg.x, bz / SQUARES_PER_TILE + tg.y)
		tile_tints[tint_key] = _migrate_tint_block(
			(tint_blocks[tbk] as PackedByteArray).duplicate())
	_tint_atlas_dirty = true
	_paint_atlas_dirty = true
	_top_atlas_dirty = true

# Loading 0_0.wmt = the master: merge its chunk plus every sibling chunk file
# in the same folder into this (single) node.
func _load_master(path: String) -> bool:
	var dir := path.get_base_dir()
	if dir == "":
		return false
	var entries := {}
	var re := RegEx.new()
	re.compile(CHUNK_FILE_RE)
	var da := DirAccess.open(dir)
	if da == null:
		return false
	da.list_dir_begin()
	var fname := da.get_next()
	while fname != "":
		if not da.current_is_dir():
			if re.search(fname) != null:
				var payload := _parse_wmt_file(dir.path_join(fname))
				if not payload.is_empty() and (payload["chunks"] as Array).size() == 1:
					var m := re.search(fname)
					var key := Vector2i(int(m.get_string(1)), int(m.get_string(2)))
					entries[key] = payload
		fname = da.get_next()
	da.list_dir_end()
	if entries.is_empty() or not entries.has(Vector2i(0, 0)):
		return false
	chunks.clear()
	tile_paints.clear()
	_tile_splats.clear()
	tile_textures.clear()
	tile_tilings.clear()
	tile_tops.clear()
	tile_tints.clear()
	_tint_atlas_dirty = true
	for key in entries:
		chunks.append(key)
	_recompute_extents()
	_set_bounds(cell_x0, cell_x1, cell_z0, cell_z1)
	var sx := GRID_SQUARES_X
	var sz := GRID_SQUARES_Z
	if sx * sz == 0:
		return false
	heightmap = PackedFloat32Array()
	center_h = PackedFloat32Array()
	hidden_tiles = PackedByteArray()
	heightmap.resize((sx + 1) * (sz + 1))
	center_h.resize(sx * sz)
	hidden_tiles.resize(sx * sz)
	heightmap.fill(0.0)
	center_h.fill(0.0)
	hidden_tiles.fill(0)
	for key in entries:
		_place_payload(key, entries[key])
	height_version += 1
	rebuild_mesh()
	return true

# Raw import of an arbitrary .wmt file (v2/v3 single chunk or v4 multi-chunk).
func _load_raw(path: String) -> bool:
	var payload := _parse_wmt_file(path)
	if payload.is_empty():
		return false
	var chunk_list: Array = payload["chunks"]
	var sx: int = payload["sx"]
	var sz: int = payload["sz"]
	chunks = (chunk_list as Array).duplicate()
	tile_paints.clear()
	_tile_splats.clear()
	tile_textures.clear()
	tile_tilings.clear()
	tile_tops.clear()
	tile_tints.clear()
	_tint_atlas_dirty = true
	_recompute_extents()
	_set_bounds(cell_x0, cell_x1, cell_z0, cell_z1)
	if cell_x1 - cell_x0 != sx or cell_z1 - cell_z0 != sz:
		return false
	heightmap = PackedFloat32Array()
	center_h = PackedFloat32Array()
	hidden_tiles = PackedByteArray()
	heightmap.resize((sx + 1) * (sz + 1))
	center_h.resize(sx * sz)
	hidden_tiles.resize(sx * sz)
	heightmap.fill(0.0)
	center_h.fill(0.0)
	hidden_tiles.fill(0)
	for key in chunk_list:
		_place_payload(key, payload)
	height_version += 1
	rebuild_mesh()
	return true

func load_wmt(path: String) -> bool:
	if path.get_file() == "0_0.wmt":
		return _load_master(path)
	return _load_raw(path)

# Incremental surface update for the hot sculpting path: write ONLY the
# touched corner/center vertex y values instead of rebuilding the whole mesh
# every frame. `corners` and `centers` map absolute cell (Vector2i) -> float.
# This also keeps the heightmap/center arrays in sync.
#
# The y floats are emitted as contiguous runs (one surface update per dirty
# run, typically one per affected grid row) rather than one call per vertex,
# so cost scales with the brush footprint, not the grid size. Returns the
# PackedInt32Array of touched mesh-vertex indices so callers can update a
# wireframe or overlay with matching granularity.
func update_height_vertices(corners: Dictionary, centers: Dictionary) -> PackedInt32Array:
	var dirty := {}
	if corners.is_empty() and centers.is_empty():
		return PackedInt32Array()
	for key in corners:
		var gx: int = (key as Vector2i).x
		var gz: int = (key as Vector2i).y
		# Corners include the border row/column (gx in [cell_x0, cell_x1]).
		if gx < cell_x0 or gz < cell_z0 or gx > cell_x1 or gz > cell_z1:
			continue
		var h: float = maxf(corners[key], 0.0)
		heightmap[_corner_index(gx, gz)] = h
		# A corner vertex is shared by up to 4 cells (as its TL/TR/BL/BR). Each
		# cell owns a private copy at vi = ci*5 + slot, so write all of them.
		for o in CellOffsets.SHARED:
			var bx: int = gx + int(o[0])
			var bz2: int = gz + int(o[1])
			if bx < cell_x0 or bz2 < cell_z0 or bx >= cell_x1 or bz2 >= cell_z1:
				continue
			var ci := _center_index(bx, bz2)
			if not cell_emitted(ci):
				continue
			dirty[ci * VERTICES_PER_CELL + int(o[2])] = h
	for key in centers:
		var gx: int = (key as Vector2i).x
		var gz: int = (key as Vector2i).y
		if gx < cell_x0 or gz < cell_z0 or gx >= cell_x1 or gz >= cell_z1:
			continue
		var h: float = maxf(centers[key], 0.0)
		var ci := _center_index(gx, gz)
		center_h[ci] = h
		if cell_emitted(ci):
			dirty[ci * VERTICES_PER_CELL + 4] = h
	if not dirty.is_empty():
		_write_dirty_vertex_runs(dirty)
		height_version += 1
	return PackedInt32Array(dirty.keys())

func _write_dirty_vertex_runs(dirty: Dictionary) -> void:
	var m := mesh as ArrayMesh
	if m == null or m.get_surface_count() == 0:
		return
	# The surface's vertex buffer holds consecutive position records only
	# (normals/tangents live in a separate attribute buffer), so one vertex is
	# exactly _vertex_stride bytes and surface_update_vertex_region wants FULL
	# per-vertex Vector3 records (12 bytes each) starting at a vertex-aligned
	# byte offset. Fixed layout: vi = ci*5 + slot, so a dirty index maps back
	# to (cell, slot) by division — no reverse map needed, and _vertex_pos()
	# always reflects the just-applied heights.
	var stride := _vertex_stride
	var vpc := VERTICES_PER_CELL
	var addrs: PackedInt32Array = dirty.keys()
	addrs.sort()
	var i := 0
	while i < addrs.size():
		var start := addrs[i]
		var j := i
		while j < addrs.size() and addrs[j] == start + (j - i):
			j += 1
		var pts := PackedVector3Array()
		for k in range(i, j):
			var vi := addrs[k]
			pts.append(_vertex_pos(vi / vpc, vi % vpc))
		m.surface_update_vertex_region(0, start * stride, pts.to_byte_array())
		i = j

# Absolute local-space position of a mesh vertex (cell index -> slot). Must
# mirror rebuild_mesh() exactly so incremental edits never drift from the
# mesh. Also the mapping the wireframe and the tile patch use. (For the
# degenerate collapsed cells it intentionally returns the REAL height data;
# callers must gate on cell_emitted(), which the writer always does.)
func _vertex_pos(ci: int, slot: int) -> Vector3:
	var gx := cell_x0 + (ci % GRID_SQUARES_X)
	var gz := cell_z0 + (ci / GRID_SQUARES_X)
	var wx := gx * SQUARE_EDGE
	var wz := gz * SQUARE_EDGE
	match slot:
		0:
			return Vector3(wx, _height_at(gx, gz), wz)
		1:
			return Vector3(wx + SQUARE_EDGE, _height_at(gx + 1, gz), wz)
		2:
			return Vector3(wx + SQUARE_EDGE, _height_at(gx + 1, gz + 1), wz + SQUARE_EDGE)
		3:
			return Vector3(wx, _height_at(gx, gz + 1), wz + SQUARE_EDGE)
	return Vector3(wx + SQUARE_EDGE * 0.5, _center_height(ci), wz + SQUARE_EDGE * 0.5)
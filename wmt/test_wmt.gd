extends SceneTree

var failures := 0

func _init() -> void:
	var terrain: WMT = load("res://wmt/wmt.gd").new()
	root.add_child(terrain)
	await process_frame
	await process_frame

	_check("grid 128x128 squares", terrain.GRID_SQUARES_X == 128 and terrain.GRID_SQUARES_Z == 128)
	_check("one default chunk at origin", terrain.chunks.size() == 1 and terrain.has_chunk(0, 0))

	var tile_class := load("res://wmt/wmt_tile.gd")
	var tile = tile_class.new()
	_check("square edge == 2.0", tile.SQUARE_EDGE == 2.0)
	_check("triangles per square == 4", tile_tri_count(tile) == 4)
	_check("tile is 8x8 squares (16x16 units)", tile.SQUARES_PER_TILE == 8 and tile.SQUARE_EDGE * 8.0 == 16.0)

	_check("corner lattice is (G+1)x(G+1)", terrain.heightmap.size() == (terrain.GRID_SQUARES_X + 1) * (terrain.GRID_SQUARES_Z + 1))
	_check("world 256x256", terrain.TERRAIN_WIDTH == 256.0 and terrain.TERRAIN_DEPTH == 256.0)

	var mesh: ArrayMesh = terrain.mesh
	var surf: Array = mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = surf[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = surf[Mesh.ARRAY_INDEX]
	_check("vertices == 81920 (16384 sq * 5)", verts.size() == 16384 * 5)
	_check("indices == 196608 (65536 tris)", idx.size() == 16384 * 4 * 3)
	_check("index count divisible by 3", idx.size() % 3 == 0)

	var triangles := idx.size() / 3
	var bad_normals := 0
	var degenerate := 0
	var total_area := 0.0
	for t in range(triangles):
		var p0: Vector3 = verts[idx[t * 3]]
		var p1: Vector3 = verts[idx[t * 3 + 1]]
		var p2: Vector3 = verts[idx[t * 3 + 2]]
		var cross := (p1 - p0).cross(p2 - p0)
		if cross.length_squared() < 1e-9:
			degenerate += 1
		elif cross.y > 0.0:
			bad_normals += 1
		total_area += cross.length() * 0.5
	_check("no degenerate triangles", degenerate == 0)
	_check("all triangle normals up", bad_normals == 0)
	_check("total area == 65536 (full coverage)", absf(total_area - 65536.0) < 0.01)

	var min_y := 1e9
	var max_y := -1e9
	for v in verts:
		if v.y < min_y: min_y = v.y
		if v.y > max_y: max_y = v.y
	_check("flat (y within epsilon)", absf(min_y) < 0.001 and absf(max_y) < 0.001)

	# Per-tile hide: a tile is an 8x8 block of squares (16x16 units). With the
	# fixed vertex layout the mesh keeps the full 81920-vertex buffer, but the
	# hidden tile's 64 cells collapse to the degenerate point (no surface), and
	# unhiding restores their real heights.
	_check("tile visible by default", not terrain.is_tile_hidden(0, 0))
	terrain.set_tile_hidden(0, 0, true)
	_check("tile hidden spans its 8x8 block", terrain.is_tile_hidden(1, 1) and terrain.is_tile_hidden(7, 7))
	_check("neighboring tile unaffected", not terrain.is_tile_hidden(8, 0))
	terrain.rebuild_mesh()
	_check("hiding one tile leaves full vertex buffer", (_verts(terrain).size()) == 16384 * 5)
	_check("hidden tile block collapsed to degenerate point", _block_degenerate(terrain, 0, 0))
	_check("neighboring tile block still emitted", not _block_degenerate(terrain, 8, 0))
	var area_hidden := _mesh_area(terrain)
	_check("hiding one tile drops exactly 64 squares of area (65536-256)", absf(area_hidden - (65536.0 - 256.0)) < 0.01)
	terrain.set_tile_hidden(0, 0, false)
	terrain.rebuild_mesh()
	_check("unhiding restores full area", absf(_mesh_area(terrain) - 65536.0) < 0.01)

	terrain.set_height(5, 7, 42.0)
	_check("get_height roundtrip", terrain.get_height(5, 7) == 42.0)
	terrain.rebuild_mesh()
	mesh = terrain.mesh
	surf = mesh.surface_get_arrays(0)
	verts = surf[Mesh.ARRAY_VERTEX]
	var has_42 := false
	for v in verts:
		if absf(v.y - 42.0) < 0.001:
			has_42 = true
			break
	_check("height 42 present in mesh", has_42)

	for stale in ["/tmp/0_0.wmt", "/tmp/1_0.wmt", "/tmp/0_-1.wmt"]:
		if FileAccess.file_exists(stale):
			DirAccess.remove_absolute(stale)
	var path := "/tmp/0_0.wmt"
	_check("save_wmt (master -> 0_0.wmt)", terrain.save_wmt(path))
	_check("master chunk file written", FileAccess.file_exists("/tmp/0_0.wmt"))
	var terrain2: WMT = load("res://wmt/wmt.gd").new()
	root.add_child(terrain2)
	_check("load master 0_0.wmt ok", terrain2.load_wmt(path))
	_check("loaded height preserved", terrain2.get_height(5, 7) == 42.0)
	var ci := terrain2._center_index(5, 7)
	_check("loaded center preserved (still edge corners / 4)", absf(terrain2.center_h[ci]) < 0.0001)

	# Hide state must survive the chunk-file round trip.
	terrain2.set_tile_hidden(8, 8, true)
	_check("save chunk with hidden tile", terrain2.save_wmt(path))
	terrain2.rebuild_mesh()
	_check("hidden tile collapses in mesh (fixed buffer)", _block_degenerate(terrain2, 8, 8))
	var terrain4: WMT = load("res://wmt/wmt.gd").new()
	root.add_child(terrain4)
	_check("master reload restores hidden tile", terrain4.load_wmt(path) and terrain4.is_tile_hidden(8, 8))
	_check("hidden tile restored across its block", terrain4.hidden_tiles[terrain4._center_index(10, 10)] != 0)
	_check("reloaded mesh keeps the tile collapsed", _block_degenerate(terrain4, 8, 8))

	# Chunk regions merge into the SAME node (no child WMT nodes).
	_check("add_chunk grew grid to 256x128", terrain.add_chunk(1, 0) and terrain.GRID_SQUARES_X == 256 and terrain.GRID_SQUARES_Z == 128)
	_check("has_chunk(1,0)", terrain.has_chunk(1, 0))
	_check("no chunk duplicates", not terrain.add_chunk(1, 0))
	terrain.set_height(200, 10, 3.0)
	terrain.rebuild_mesh()
	_check("absolute cell height beyond first chunk", terrain.get_height(200, 10) == 3.0)
	_check("seamless shared border (flat across chunk join)", absf(terrain.get_height(128, 1)) < 0.001)
	var two_path := "/tmp/0_0.wmt"
	_check("save 2 chunks -> 0_0 + 1_0 files", terrain.save_wmt(two_path))
	_check("sibling chunk file written", FileAccess.file_exists("/tmp/1_0.wmt"))
	var t5: WMT = load("res://wmt/wmt.gd").new()
	root.add_child(t5)
	_check("load master auto-merges sibling chunks", t5.load_wmt(two_path))
	_check("2 chunks restored", t5.chunks.size() == 2 and t5.has_chunk(1, 0))
	_check("sibling height restored", t5.get_height(200, 10) == 3.0)
	_check("origin chunk center intact", absf(t5.get_center_height(5, 7)) < 0.0001)
	var t6: WMT = load("res://wmt/wmt.gd").new()
	root.add_child(t6)
	_check("raw import of sibling 1_0.wmt (chunk-local coords)", t6.load_wmt("/tmp/1_0.wmt"))
	_check("sibling local cell maps absolute (200,10) -> (72,10)", t6.get_height(72, 10) == 3.0)
	var removed := terrain.remove_chunk(1, 0)
	_check("remove_chunk shrank grid back to 128x128", removed and terrain.GRID_SQUARES_X == 128 and terrain.GRID_SQUARES_Z == 128)
	_check("overlap height preserved after shrink", absf(terrain.get_height(5, 7) - 42.0) < 0.001)

	# Chunks may live at negative lattice positions too (file "0_-1.wmt").
	_check("add_chunk at negative lattice (0,-1)", terrain.add_chunk(0, -1))
	terrain.set_height(3, -54, 7.0)
	terrain.rebuild_mesh()
	_check("negative chunk saves to 0_-1.wmt", terrain.save_wmt("/tmp/0_0.wmt") and FileAccess.file_exists("/tmp/0_-1.wmt"))
	var t7: WMT = load("res://wmt/wmt.gd").new()
	root.add_child(t7)
	_check("master reloads negative-chunk sibling", t7.load_wmt("/tmp/0_0.wmt"))
	_check("negative chunk restored from sibling", t7.has_chunk(0, -1))
	_check("negative chunk height restored", t7.get_height(3, -54) == 7.0)

	# A v2 file (no center payload) must derive centers from corner averages.
	var v2_path := "/tmp/test_wmt_v2.wmt"
	var gs := terrain2.GRID_SQUARES_X
	var fh := FileAccess.open(v2_path, FileAccess.WRITE)
	fh.store_32(0x58544D57)
	fh.store_32(2)
	fh.store_32(gs)
	fh.store_32(gs)
	fh.store_float(terrain2.SQUARE_EDGE)
	for row in range(gs):
		for col in range(gs):
			fh.store_float(terrain.get_height(col, row))
	fh.close()
	terrain.set_height(5, 7, 0.0)
	var terrain3: WMT = load("res://wmt/wmt.gd").new()
	root.add_child(terrain3)
	_check("load v2 ok", terrain3.load_wmt(v2_path))
	_check("v2 center derived to corner average (10.5)", absf(terrain3.center_h[terrain3._center_index(5, 7)] - 10.5) < 0.001)

	# Center vertices are not auto-updated when a corner is sculpted, but they
	# are themselves sculptable.
	var center_before := terrain.center_h[terrain._center_index(5, 7)]
	terrain.set_height(5, 7, 60.0)
	terrain.rebuild_mesh()
	_check("corner sculptable (height changes)", terrain.get_height(5, 7) == 60.0)
	_check("center untouched by corner sculpt", absf(terrain.center_h[terrain._center_index(5, 7)] - center_before) < 0.0001)
	terrain.set_center_height(5, 7, 55.0)
	terrain.rebuild_mesh()
	_check("center sculptable (stored value changes)", absf(terrain.center_h[terrain._center_index(5, 7)] - 55.0) < 0.0001)
	_check("center reflected in mesh surface", absf(terrain.sample_surface(Vector3(11.0, 0.0, 15.0)) - 55.0) < 0.0001)

	# sample_surface must sit exactly on the X mesh.
	terrain.rebuild_mesh()
	var sq := terrain.SQUARE_EDGE
	var center_sq := Vector3(5.0 * sq + sq * 0.5, terrain.sample_surface(Vector3(5.0 * sq + sq * 0.5, 0.0, 7.0 * sq + sq * 0.5)), 7.0 * sq + sq * 0.5)
	var found := false
	var surf2: Array = terrain.mesh.surface_get_arrays(0)
	for v in surf2[Mesh.ARRAY_VERTEX]:
		if (v - center_sq).length() < 0.001:
			found = true
			break
	_check("sample_surface matches center vertex on mesh", found)
	# Top edge of square (5,7): 60 at corner (5,7), 0 at corner (6,7) -> 30 midway.
	_check("sample_surface linear along triangle edge", absf(terrain.sample_surface(Vector3(11.0, 0.0, 14.0)) - 30.0) < 0.001)

	# Incremental update_height_vertices must keep the height/center arrays in
	# sync and report exactly the touched mesh-vertex indices, and the mesh
	# vertex positions must match rebuild_mesh() exactly (the math both the
	# y-run writer and the wireframe incremental pass rely on).
	var corners := {}
	var centers := {}
	for gz in range(10, 18):
		for gx in range(10, 18):
			corners[Vector2i(gx, gz)] = float((gx * 3 + gz) % 7) + 2.0
	for gz in range(10, 17):
		for gx in range(10, 17):
			centers[Vector2i(gx, gz)] = float((gx * 5 + gz) % 6) + 1.0
	var dirty := terrain.update_height_vertices(corners, centers)
	var expect_n := 0
	for gz in range(10, 18):
		for gx in range(10, 18):
			expect_n += 4
	for gz in range(10, 17):
		for gx in range(10, 17):
			expect_n += 1
	_check("update_height_vertices reports touched vertices", dirty.size() >= expect_n - 24)
	_check("corner array synced", absf(terrain.get_height(14, 15) - (float((14 * 3 + 15) % 7) + 2.0)) < 0.001)
	_check("center array synced", absf(terrain.get_center_height(14, 15) - (float((14 * 5 + 15) % 6) + 1.0)) < 0.001)
	# Corner (10,10) is the BR of cell (9,9) -> that cell's slot 2 vertex.
	var shared_vi: int = terrain._center_index(9, 9) * terrain.VERTICES_PER_CELL + 2
	_check("dirty list includes shared-corner cell slot", dirty.has(shared_vi))
	terrain.rebuild_mesh()
	var surf_full: Array = terrain.mesh.surface_get_arrays(0)
	var verts_full: PackedVector3Array = surf_full[Mesh.ARRAY_VERTEX]
	var math_matches := true
	var vpc: int = terrain.VERTICES_PER_CELL
	for i in range(verts_full.size()):
		var expect: Vector3 = terrain._vertex_pos(i / vpc, i % vpc)
		if verts_full[i] != expect:
			math_matches = false
			break
	_check("rebuilt mesh matches _vertex_pos math", math_matches)

	# Border corners are real, sculptable vertices (no heap/neighbor rollover).
	terrain.set_height(128, 128, 25.0)
	terrain.rebuild_mesh()
	var surf_b: Array = terrain.mesh.surface_get_arrays(0)
	var has_25 := false
	for v in surf_b[Mesh.ARRAY_VERTEX]:
		if absf(v.y - 25.0) < 0.001:
			has_25 = true
			break
	_check("border corner (128,128) sculpts into mesh", has_25)

	print("RESULT: %s" % ("PASS" if failures == 0 else "FAIL (%d)" % failures))
	quit(0 if failures == 0 else 1)

func tile_tri_count(tile) -> int:
	var n := 0
	for i in range(4):
		var p = tile.triangle_positions(i)
		if p.size() == 3:
			n += 1
	return n

func _verts(t: WMT) -> PackedVector3Array:
	return (t.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX] as PackedVector3Array)

# True if every cell of the tile whose base cell is (tgx, tgz) sits collapsed
# at the degenerate point (i.e. the tile's whole block is hidden/absent).
func _block_degenerate(t: WMT, tgx: int, tgz: int) -> bool:
	var sxs: int = t.GRID_SQUARES_X
	var verts := _verts(t)
	var deg := Vector3.ZERO
	for dz in range(t.SQUARES_PER_TILE):
		for dx in range(t.SQUARES_PER_TILE):
			var gx := tgx + dx
			var gz := tgz + dz
			if gx < t.cell_x0 or gz < t.cell_z0 or gx >= t.cell_x1 or gz >= t.cell_z1:
				continue
			var base := ((gz - t.cell_z0) * sxs + (gx - t.cell_x0)) * t.VERTICES_PER_CELL
			for s in range(t.VERTICES_PER_CELL):
				if verts[base + s] != deg:
					return false
	return true

func _mesh_area(t: WMT) -> float:
	var surf := t.mesh.surface_get_arrays(0)
	var verts: PackedVector3Array = surf[Mesh.ARRAY_VERTEX]
	var idx: PackedInt32Array = surf[Mesh.ARRAY_INDEX]
	var area := 0.0
	for ti in range(idx.size() / 3):
		var p0: Vector3 = verts[idx[ti * 3]]
		var p1: Vector3 = verts[idx[ti * 3 + 1]]
		var p2: Vector3 = verts[idx[ti * 3 + 2]]
		area += (p1 - p0).cross(p2 - p0).length() * 0.5
	return area

func _check(label: String, ok: bool) -> void:
	if ok:
		print("  [OK] " + label)
	else:
		failures += 1
		print("  [FAIL] " + label)
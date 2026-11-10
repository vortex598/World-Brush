class_name TerrainSculptLog
extends RefCounted

# Stroke recorder used by the terrain editor plugin. While a sculpt/smooth
# stroke is active the plugin records, per frame, the cursor, brush radius,
# step and every corner/center edit (with falloff and before/after heights),
# plus the dirty mesh-vertex count. On stroke release write_log() dumps the
# last stroke to /tmp/wmt_sculpt_log.txt and res://debug/wmt_sculpt_log.txt:
# per-frame tables, per-touched-vertex deltas, and before/after ASCII height
# maps of the affected region. Lets a remote debugger reconstruct exactly what
# moved during a "sculpt glitch".

var frames: Array = []
var union_corners := {}
var union_centers := {}
var begin_ms: int = 0

func reset() -> void:
	frames = []
	union_corners = {}
	union_centers = {}
	begin_ms = Time.get_ticks_msec()

func record_frame(center: Vector3, radius: float, step: float, smoothing: bool, corners: Array, centers: Array, dirty_count: int) -> void:
	var rec := {
		"t": Time.get_ticks_msec() - begin_ms,
		"c": [center.x, center.z],
		"r": radius,
		"step": step,
		"smooth": smoothing,
		"corners": corners.duplicate(),
		"centers": centers.duplicate(),
		"dirty": dirty_count,
	}
	frames.append(rec)
	for e in corners:
		union_corners[Vector2i(e[0], e[1])] = true
	for e in centers:
		union_centers[Vector2i(e[0], e[1])] = true

func write_log(t: WMT, before_hm: PackedFloat32Array, before_ch: PackedFloat32Array) -> void:
	if t == null or t.is_queued_for_deletion():
		return
	var edge := t.SQUARE_EDGE
	var out := PackedStringArray()
	out.append("WMT sculpt stroke record")
	out.append("grid x=[%d..%d] z=[%d..%d]  edge=%s  frames=%d" % [t.cell_x0, t.cell_x1, t.cell_z0, t.cell_z1, str(edge), frames.size()])
	var cmin := Vector2i(1 << 30, 1 << 30)
	var cmax := Vector2i(-(1 << 30), -(1 << 30))
	for key in union_corners:
		var k: Vector2i = key
		cmin = Vector2i(mini(cmin.x, k.x), mini(cmin.y, k.y))
		cmax = Vector2i(maxi(cmax.x, k.x), maxi(cmax.y, k.y))
	for key in union_centers:
		var k: Vector2i = key
		cmin = Vector2i(mini(cmin.x, k.x), mini(cmin.y, k.y))
		cmax = Vector2i(maxi(cmax.x, k.x), maxi(cmax.y, k.y))
	cmin = cmin - Vector2i(2, 2)
	cmax = cmax + Vector2i(2, 2)
	cmin = Vector2i(maxi(cmin.x, t.cell_x0), maxi(cmin.y, t.cell_z0))
	cmax = Vector2i(mini(cmax.x, t.cell_x1), mini(cmax.y, t.cell_z1))
	out.append("region cells x=[%d..%d] z=[%d..%d]  (world x=[%s..%s] z=[%s..%s])" % [cmin.x, cmax.x, cmin.y, cmax.y, str(cmin.x * edge), str(cmax.x * edge), str(cmin.y * edge), str(cmax.y * edge)])

	out.append("--- frames (t=ms since stroke begin, c=cursor local, r=radius, step=per-frame height, nc=n corners edited, nct=n centers edited, dirty=n mesh vertices updated)")
	for i in range(frames.size()):
		var fr: Dictionary = frames[i]
		out.append("f%03d t=%d c=[%.1f,%.1f] r=%.2f step=%+.4f smooth=%s nc=%d nct=%d dirty=%d" % [i, fr["t"], fr["c"][0], fr["c"][1], fr["r"], fr["step"], str(fr["smooth"]), fr["corners"].size(), fr["centers"].size(), fr["dirty"]])

	for i in range(frames.size()):
		var fr: Dictionary = frames[i]
		var cs := _fmt_edits(fr["corners"])
		var nts := _fmt_edits(fr["centers"])
		if not cs.is_empty():
			out.append("f%03d corners %s" % [i, cs])
		if not nts.is_empty():
			out.append("f%03d centers %s" % [i, nts])

	var ckeys := union_corners.keys()
	ckeys.sort_custom(func(a, b): return (a as Vector2i).y < (b as Vector2i).y if (a as Vector2i).y != (b as Vector2i).y else (a as Vector2i).x < (b as Vector2i).x)
	out.append("--- touched corner deltas (gx,gz): before -> after, d")
	for key in ckeys:
		var k: Vector2i = key
		var bv := _corner_val(t, before_hm, k.x, k.y)
		var av := t.get_height(k.x, k.y)
		out.append("corner(%d,%d): %+.3f -> %+.3f  d=%+.3f" % [k.x, k.y, bv, av, av - bv])
	var tkeys := union_centers.keys()
	tkeys.sort_custom(func(a, b): return (a as Vector2i).y < (b as Vector2i).y if (a as Vector2i).y != (b as Vector2i).y else (a as Vector2i).x < (b as Vector2i).x)
	out.append("--- touched center deltas (cx,cz): before -> after, d")
	for key in tkeys:
		var k: Vector2i = key
		var bv := _center_val(t, before_ch, k.x, k.y)
		var av := t.get_center_height(k.x, k.y)
		out.append("center(%d,%d): %+.3f -> %+.3f  d=%+.3f" % [k.x, k.y, bv, av, av - bv])

	# ASCII height maps over the region. Legend: '.'=0, magnitude scaled by the
	# absolute range; uppercase A-I = positive delta, lowercase a-i = negative.
	var corner_lo := 1e18
	var corner_hi := -1e18
	for gz in range(cmin.y, cmax.y + 2):
		for gx in range(cmin.x, cmax.x + 2):
			var bv := _corner_val(t, before_hm, gx, gz)
			var av := t.get_height(gx, gz)
			corner_lo = minf(av, minf(bv, corner_lo))
			corner_hi = maxf(av, maxf(bv, corner_hi))
	out.append("--- corners BEFORE (z top to bottom, cols = x)")
	out.append_array(_grid_rows(cmin.x, cmin.y, cmax.x, cmax.y, corner_lo, corner_hi, false, false,
		func(gx: int, gz: int) -> float: return _corner_val(t, before_hm, gx, gz)))
	out.append("--- corners AFTER")
	out.append_array(_grid_rows(cmin.x, cmin.y, cmax.x, cmax.y, corner_lo, corner_hi, false, false,
		func(gx: int, gz: int) -> float: return t.get_height(gx, gz)))
	out.append("--- corners DELTA (A-I up, a-i down, '.'=0, delta*2 rounded)")
	out.append_array(_grid_rows(cmin.x, cmin.y, cmax.x, cmax.y, 0.0, 1.0, true, false,
		func(gx: int, gz: int) -> float: return t.get_height(gx, gz) - _corner_val(t, before_hm, gx, gz)))
	if before_ch.size() > 0:
		var center_lo := 1e18
		var center_hi := -1e18
		for cz in range(cmin.y, cmax.y + 1):
			for cx in range(cmin.x, cmax.x + 1):
				var bv := _center_val(t, before_ch, cx, cz)
				var av := t.get_center_height(cx, cz)
				center_lo = minf(av, minf(bv, center_lo))
				center_hi = maxf(av, maxf(bv, center_hi))
		out.append("--- centers BEFORE")
		out.append_array(_grid_rows(cmin.x, cmin.y, cmax.x, cmax.y, center_lo, center_hi, false, true,
			func(cx: int, cz: int) -> float: return _center_val(t, before_ch, cx, cz)))
		out.append("--- centers AFTER")
		out.append_array(_grid_rows(cmin.x, cmin.y, cmax.x, cmax.y, center_lo, center_hi, false, true,
			func(cx: int, cz: int) -> float: return t.get_center_height(cx, cz)))
		out.append("--- centers DELTA")
		out.append_array(_grid_rows(cmin.x, cmin.y, cmax.x, cmax.y, 0.0, 1.0, true, true,
			func(cx: int, cz: int) -> float: return t.get_center_height(cx, cz) - _center_val(t, before_ch, cx, cz)))

	var body := "\n".join(out)
	_write_files(body)
	print("WMT_SCULPT_LOG written: /tmp/wmt_sculpt_log.txt  (res://debug/wmt_sculpt_log.txt)")

func _write_files(body: String) -> void:
	for path in ["/tmp/wmt_sculpt_log.txt", "res://debug/wmt_sculpt_log.txt"]:
		var f := FileAccess.open(path, FileAccess.WRITE)
		if f:
			f.store_string(body)
			f.close()

func _corner_val(t: WMT, hm: PackedFloat32Array, gx: int, gz: int) -> float:
	if hm.is_empty():
		return 0.0
	if gx < t.cell_x0 or gz < t.cell_z0 or gx > t.cell_x1 or gz > t.cell_z1:
		return 0.0
	var gi := (gz - t.cell_z0) * (t.GRID_SQUARES_X + 1) + (gx - t.cell_x0)
	if gi < 0 or gi >= hm.size():
		return 0.0
	return hm[gi]

func _center_val(t: WMT, ch: PackedFloat32Array, cx: int, cz: int) -> float:
	if ch.is_empty():
		return 0.0
	if cx < t.cell_x0 or cz < t.cell_z0 or cx >= t.cell_x1 or cz >= t.cell_z1:
		return 0.0
	var gi := (cz - t.cell_z0) * t.GRID_SQUARES_X + (cx - t.cell_x0)
	if gi < 0 or gi >= ch.size():
		return 0.0
	return ch[gi]

func _fmt_edits(edits: Array) -> String:
	var parts := PackedStringArray()
	for e in edits:
		parts.append("[%d,%d d=%.2f f=%.2f %+.3f->%+.3f]" % [e[0], e[1], e[2], e[3], e[4], e[5]])
	return ", ".join(parts)

func _grid_rows(x0: int, z0: int, x1: int, z1: int, lo: float, hi: float, is_delta: bool, centers: bool, fn: Callable) -> PackedStringArray:
	var rows := PackedStringArray()
	var x_hi := x1 + (0 if centers else 1)
	var z_hi := z1 + (0 if centers else 1)
	for z in range(z_hi, z0 - 1, -1):
		var row := ""
		for x in range(x0, x_hi + 1):
			var v: float = fn.call(x, z)
			if is_delta:
				if absf(v) < 0.0005:
					row += "."
				else:
					var m := clampi(int(round(absf(v) * 2.0)), 1, 9)
					row += ("ABCDEFGHI"[m - 1] if v > 0 else "abcdefghi"[m - 1])
			else:
				row += _height_char(v, lo, hi)
		rows.append(row)
	return rows

func _height_char(v: float, lo: float, hi: float) -> String:
	if absf(v) < 0.0005:
		return "."
	var rng := hi - lo
	if rng <= 0.0001:
		return ("+" if v > 0 else "-")
	var idx := clampi(int(floor((v - lo) / rng * 14.0)), 0, 14)
	return " .':-[(=+*#%@&$"[idx]
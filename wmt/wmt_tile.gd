@tool
class_name WmtTile
extends RefCounted

# A WmtTile is one grid SQUARE of a WMT (the smallest mesh element). Its
# surface is split into 4 triangles forming an X: both diagonals plus the two
# cross edges meet at the center vertex. One logical terrain "tile" (the block
# you hide / see in the red grid) contains SQUARES_PER_TILE^2 = 64 of these
# squares, arranged in an 8x8 block.
#
#  wmt     = 16 x 16 tiles per chunk (256 x 256 world units)
#  tile    = 8 x 8 squares (64 squares, 16 x 16 world units)
#  square  = 4 triangles (X pattern, 1 central vertex), 2 x 2 world units
#
#      a ---- b
#      | \  / |
#      |  \/  |
#      |  /\  |
#      | /  \ |
#      d ---- c
#
# The two diagonals (a-c and b-d) cross at the center vertex, splitting the
# square into 4 triangular cells. Triangle winding (CCW from above -> normals
# up, no back-face culling):
#   0: a center b  1: b center c  2: c center d  3: d center a

const TRIANGLES_PER_SQUARE := 4
const SQUARE_EDGE := 2.0
const HALF_EDGE := SQUARE_EDGE * 0.5
const SQUARES_PER_TILE := 8

const a := Vector3(0.0, 0.0, 0.0)
const b := Vector3(SQUARE_EDGE, 0.0, 0.0)
const c := Vector3(SQUARE_EDGE, 0.0, SQUARE_EDGE)
const d := Vector3(0.0, 0.0, SQUARE_EDGE)
const center := Vector3(HALF_EDGE, 0.0, HALF_EDGE)

func triangle_indices(tidx: int) -> Array:
	match tidx:
		0:
			return [1, 4, 0]
		1:
			return [2, 4, 1]
		2:
			return [3, 4, 2]
		3:
			return [0, 4, 3]
	return [1, 4, 0]

func triangle_positions(tidx: int, origin: Vector3 = Vector3.ZERO) -> Array:
	var local := [a, b, c, d, center]
	var idx := triangle_indices(tidx)
	var out := []
	for i in idx:
		out.append(origin + local[i])
	return out
// WMT terrain wireframe overlay.
//
// Draws the terrain's TRUE triangle edges as lighter lines directly on the
// terrain surface — no separate line mesh. The WMT mesh keeps every vertex
// position on the absolute cell lattice (window corners at integer * square_edge,
// cell centers at integer + half), so an interpolated fragment coordinate maps
// back to its grid cell exactly:
//
//   c = local_pos.xz / square_edge          -> cell index (float)
//   f = fract(c - 0.5) - 0.5                -> offset within the cell, [-.5,.5]
//   db = min(|f.x|, |f.y|)                  -> distance to the cell borders
//   dd = min(|f.x-f.y|, |f.x+f.y|) * 1/sqrt2 -> distance to the X diagonals
//   d  = min(db, dd)
//
// dd's zero lines run from each cell corner to the center — exactly the plan
// view of the two WMT triangles per cell, whose shared diagonal edge follows
// that same path. So the lattice + X diagonals are precisely the terrain's real
// polygon edges; edges that border a hidden/absent tile vanish simply because
// those degenerate triangles rasterize no fragments.
//
// NOTE: the plugin no longer uses this shader (replaced by terrain_overlay.gdshader),
// but main.tscn still references it as a resource, so it stays for scene compat.
shader_type spatial;
render_mode unshaded, cull_back;

uniform vec3 base_color : source_color = vec3(0.5, 0.62, 0.5);
uniform vec3 edge_color : source_color = vec3(0.92, 0.94, 0.88);
uniform float square_edge : hint_range(0.25, 64.0) = 2.0;
uniform float edge_width : hint_range(0.0, 6.0) = 1.0;
uniform float edge_opacity : hint_range(0.0, 1.0) = 1.0;

varying vec3 local_frag_pos;

void vertex() {
	local_frag_pos = VERTEX;
}

void fragment() {
	vec2 cell = local_frag_pos.xz / square_edge;
	vec2 f = fract(cell - 0.5) - 0.5;

	float db = min(abs(f.x), abs(f.y));
	float dd = min(abs(f.x - f.y), abs(f.x + f.y)) * 0.70710678;
	float d = min(db, dd);

	// edge_width ~ 0 gives a hairline; larger values thicken the highlight.
	float af = fwidth(d);
	float edge = 1.0 - smoothstep(af * 0.5, af * (0.5 + edge_width), d);
	edge *= edge_opacity;

	ALBEDO = mix(base_color, edge_color, edge);
}
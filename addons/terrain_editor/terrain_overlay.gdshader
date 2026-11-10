// WMT terrain overlay.
//
// One shader for all terrain-surface decoration, driven entirely by the
// fragment's interpolated LOCAL position (the WMT mesh keeps every vertex on
// the absolute cell lattice, so coordinates map back to the grid exactly):
//
//   c = local_pos.xz / square_edge            -> cell index (float)
//   f = fract(c - 0.5) - 0.5                  -> offset within cell, [-.5,.5]
//   db = min(|f.x|, |f.y|)                    -> distance to cell borders
//   dd = min(|f.x-f.y|, |f.x+f.y|) * 1/sqrt2  -> distance to the X diagonals
//   d  = min(db, dd)
//
// dd's zero lines run from each cell corner to the center — the plan view of
// the two WMT triangles per cell, whose shared diagonal follows that path. So
// the cell lattice + X diagonals are precisely the terrain's real polygon
// edges. Edges bordering a hidden/absent tile vanish because those degenerate
// triangles rasterize no fragments.
//
// Layers, each independently toggleable (uniform-gated so one material works):
//   - wireframe: every cell edge, colored white or black (the classic look).
//   - WMT lines: the tile lattice (every SQUARES_PER_TILE cells), cyan.
//   - chunk lines: the chunk lattice (every CHUNK_CELLS cells), orange.
//   - tint: the painted vertex color is BLENDED onto the terrain texture per
//     channel (see wmt_vertex_blend), so the paint lands in the albedo and is
//     lit by the REAL scene lighting like everything else.
// The surface is LIT by Godot like any normal material: the fragment only
// composes the albedo (flat fill + painted textures + lattice lines + cursor)
// and reconstructs a smooth per-fragment NORMAL from the uploaded height
// lattice, then the engine shades it with the scene's actual lights. It is kept
// perfectly matte (specular forced to 0), so the terrain shading is static -
// rotating the view never produces shiny glints.
//
// base_color mirrors the terrain's flat_color so toggling a layer never
// changes the fill.
shader_type spatial;
// Shading model copied from the plain StandardMaterial3D the terrain can be
// given in the editor (all defaults): opaque, per-pixel, cull_back, Lambert
// diffuse, no extra feature terms. Shading NORMAL is left alone on purpose, so
// Godot lights the terrain through the mesh's own smooth vertex normals
// (wmt fills Mesh.ARRAY_NORMAL on every rebuild) - the exact path the imported
// glTF objects take, which is why their light and shadows hold still while the
// camera moves. Writing our own NORMAL here is what used to make the terrain's
// lighting crawl and fade.
render_mode cull_back, diffuse_lambert;

uniform vec3 base_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float square_edge : hint_range(0.25, 64.0) = 2.0;
uniform float tile_cells = 8.0;
uniform float chunk_cells = 128.0;

uniform bool show_wire = false;
uniform vec3 wire_color : source_color = vec3(1.0, 1.0, 1.0);
uniform float edge_width : hint_range(0.0, 6.0) = 1.0;

uniform bool show_tile_lines = false;
uniform vec3 tile_color : source_color = vec3(0.30, 0.85, 1.0);
uniform float tile_width : hint_range(0.0, 6.0) = 1.0;

uniform bool show_chunk_lines = false;
uniform vec3 chunk_color : source_color = vec3(1.0, 0.55, 0.15);
uniform float chunk_width : hint_range(0.0, 6.0) = 1.0;

uniform float line_opacity : hint_range(0.0, 1.0) = 1.0;

// The terrain is LIT by Godot like any normal material: the fragment only
// composites the albedo (flat fill + painted textures + lattice lines + cursor)
// and lets the engine light it with the scene's real lights using the mesh's
// vertex normals. The surface is kept matte (metallic 0, roughness 1,
// specular 0) so it never grows a view-dependent highlight; the lambert
// diffuse term carries the shading, exactly like the default
// StandardMaterial3D the imported world meshes use.
// Splat coverage below which a texel is treated as bare ground (shows the
// white base); at or above it the base material is excluded and only the
// painted channels blend, so channel seams and light stroke edges never pick
// up the pale base albedo.
const float BASE_EPS = 0.003;

// Paint: ONE RGBA splatmap texture over the tile lattice stores the channel
// weights (R,G,B,A = channels 0..3, 0..255). Painting writes COMPETITIVE
// coverage the InnoGames way - the painted channel rises toward full and every
// other channel falls by the same amount, so the channels sum to <= 1 and the
// ground material holds the remainder. Each channel also owns a
// Texture2DArray of the DISTINCT tileset textures used on the terrain plus a
// nearest-filtered per-tile LAYOUT atlas (R = which array layer, G = per-tile
// repeat byte). Rendering is a masked-depth blend (InnoGames): a material's
// height = its splat weight x its layer's mask alpha (the "_s" soft alpha), the
// base material is a 5th height = base_height x (1 - coverage), and only the
// materials within paint_depth of the strongest one blend in. That gives real
// brush falloff (a partial dab leaves the two channels neck-and-neck *inside*
// the stroke, so they feather there), bilinear-feathered texture transitions,
// and live alphamap blending - while a full dab still replaces the texel.
uniform sampler2D splat_splatmap : repeat_disable, filter_linear;
uniform sampler2DArray chan_arr0 : source_color, repeat_enable, filter_linear;
uniform sampler2DArray chan_arr1 : source_color, repeat_enable, filter_linear;
uniform sampler2DArray chan_arr2 : source_color, repeat_enable, filter_linear;
uniform sampler2DArray chan_arr3 : source_color, repeat_enable, filter_linear;
uniform sampler2D chan_layout0 : repeat_disable, filter_nearest;
uniform sampler2D chan_layout1 : repeat_disable, filter_nearest;
uniform sampler2D chan_layout2 : repeat_disable, filter_nearest;
uniform sampler2D chan_layout3 : repeat_disable, filter_nearest;
// Depth of the masked blend: how far below the strongest material other
// materials still contribute. Larger = softer, wider crossfades.
uniform float paint_depth : hint_range(0.01, 1.0) = 0.2;
// Height of the unpainted base as the 5th masked-depth material (amount =
// 1 - sum(splat)). Higher feathers strokes into the base colour (build-up),
// lower makes painted coverage snap hard against the base.
uniform float base_height : hint_range(0.01, 1.0) = 0.35;
uniform bool has_paint = false;
uniform vec2 paint_origin = vec2(0.0);
uniform vec2 atlas_tiles = vec2(16.0);
uniform float tile_edge : hint_range(1.0, 256.0) = 16.0;
uniform float paint_tile_px = 64.0;
// Guard pad around each splat ATMAS block (see WMT.SPLAT_PAD). The atlas is
// bilinearly filtered, so the pad keeps a block's bilinear taps inside its own
// guard ring instead of reading the neighbour tile's block.
uniform float splat_pad = 2.0;
// Apply the painted vertex color onto the terrain texture, per channel:
//   base  = the terrain texture's channel value (0-1, the bottom layer)
//   blend = the painted vertex color's channel value (0-1, the top layer)
//     base < 0.5  ->  2 * base * blend                    (boosted Multiply)
//     base >= 0.5 ->  1 - 2 * (1 - base) * (1 - blend)    (boosted Screen)
// 50% gray is the neutral: blend = 0.5 returns base unchanged, so unpainted
// terrain is untouched. Dark texture pixels are multiplied, light ones screened.
vec3 wmt_vertex_blend(vec3 base, vec3 blend) {
	vec3 boosted_multiply = 2.0 * base * blend;
	vec3 boosted_screen = vec3(1.0) - 2.0 * (vec3(1.0) - base) * (vec3(1.0) - blend);
	return mix(boosted_multiply, boosted_screen, step(vec3(0.5), base));
}

// Vertex tint (painted color, blended): a per-tile RGBA8 splatmap laid out in
// the SAME padded atlas as the splat weights (block = PAINT_TILE_PX with an
// edge-replicated splat_pad ring on both sides), so it shares the exact spuv
// reconstruction below. Origin = the tile lattice. The stored RGB is the picked
// COLOR and the stored ALPHA is the COVERAGE; fragment() walks the top layer
// from the 0.5 neutral out to that color and blends it with wmt_vertex_blend.
// Nothing here comes from a global color uniform, so re-picking a color only
// affects paint applied from now on.
uniform bool vertex_tint_on = false;
// The per-texel tint splatmap: RGB = the color that was painted there, A = how
// much of it is there. See the SUPER-WHITE note in fragment().
uniform sampler2D vertex_tint_tex : repeat_disable, filter_linear;
uniform vec2 vertex_tint_origin = vec2(0.0);
// How far a near-white top layer is pushed past 1.0 (see SUPER-WHITE in
// fragment()). 0 disables it and restores the plain W3C blend; 0.5 makes a full
// white stroke read as blend 1.5.
uniform float vertex_tint_boost : hint_range(0.0, 1.0) = 0.5;
// Vertex-tint atlas geometry: finer 16x16 texel blocks per tile with their own
// echo-ring pad (the splat atlas uploads paint_tile_px / splat_pad for its 64px
// pitch; tint blocks use THIS pitch instead).
uniform int tint_tile_px = 16;
uniform int tint_pad = 2;

// Paint-mode overlays: R8 masks on the tile lattice (texel = tile, component
// value 0/1), blended over the base at 50% - blue for selected tiles, red for
// tiles the current brush texture can't paint into. Driven by sel_on /
// nopaint_on so a null/inactive mask never leaks in.
uniform sampler2D sel_mask_tex : repeat_disable, filter_nearest;
uniform sampler2D nopaint_mask_tex : repeat_disable, filter_nearest;
uniform float sel_on = 0.0;
uniform float nopaint_on = 0.0;

// Brush cursor drawn straight into the fragment (same technique as the tile
// lines, so it keeps constant screen thickness and is always a direct overlay
// on top of the terrain - no 3D mesh ribbon to z-fight or clip). brush_center
// is the brush's LOCAL position on the terrain plane. brush_falloff_radius < 0
// (or brush_falloff_on false) hides the inner falloff circle.
uniform bool brush_on = false;
uniform vec2 brush_center = vec2(0.0);
uniform float brush_radius = 2.0;
uniform float brush_width = 1.25;
uniform vec3 brush_color : source_color = vec3(1.0, 0.55, 0.15);
uniform bool brush_falloff_on = false;
uniform float brush_falloff_radius = -1.0;

// Map a GLOBAL tint-lattice texel index to its atlas UV, sampled at the texel
// CENTRE (+0.5). The tint lattice is continuous ACROSS tile borders: texel
// (px,py) of whichever tile owns it lives inside that tile's padded block, so
// flooring the global index gives the owning tile and the remainder gives the
// texel within it. The four bilinear taps either side of a tile border are
// therefore fetched from adjacent tiles' blocks and the ramp stays continuous.
//
// This is what removes the hard seams. Sampling per-tile instead restarted the
// interpolation at every tile edge, so a fragment on one side of a border
// ramped to tile A's edge texel and the fragment on the other side ramped out
// of tile B's edge texel. Those two texels are independent samples of
// independent blocks, so nothing forced them to agree and the result jumped by
// a visible step at every tile boundary.
vec2 wmt_tint_texel_uv(vec2 g) {
	vec2 pitch = vec2(float(tint_tile_px + 2 * tint_pad));
	vec2 t = floor(g / float(tint_tile_px));
	vec2 loc = g - t * float(tint_tile_px);
	vec2 tile_off = t - vertex_tint_origin;
	return (tile_off * pitch + vec2(float(tint_pad)) + loc + 0.5) / (atlas_tiles * pitch);
}

varying vec3 local_frag_pos;

void vertex() {
	local_frag_pos = VERTEX;
}

// Weighted average of the two strongest LIVE channel albedos. Drops into the
// masked-depth blend wherever the base material would otherwise dominate (bare
// texels between two painted covers), so channel seams cross-fade between the
// two textures instead of flashing the white base through the gap. Fully bare
// texels (no live weight at all) keep the base color.
vec3 channel_seam(vec4 ww, vec3 a0, vec3 a1, vec3 a2, vec3 a3, vec3 base) {
	float ws[4] = float[4](ww.x, ww.y, ww.z, ww.w);
	vec3 alb[4] = vec3[4](a0, a1, a2, a3);
	float m1 = -1.0;
	int i1 = 0;
	for (int i = 0; i < 4; ++i) {
		if (ws[i] > m1) { m1 = ws[i]; i1 = i; }
	}
	float m2 = -1.0;
	int i2 = 0;
	for (int i = 0; i < 4; ++i) {
		if (i != i1 && ws[i] > m2) { m2 = ws[i]; i2 = i; }
	}
	if (m1 < 1e-5) { return base; }
	return (alb[i1] * m1 + alb[i2] * m2) / max(m1 + m2, 1e-5);
}

void fragment() {
	// The painted texture is part of the terrain surface: bake it into the
	// albedo FIRST so painted tiles then get shading and the wire/tile/chunk
	// lattice lines the same way unpainted terrain does.
	vec3 col = base_color;
	if (has_paint) {
		vec2 tpos = local_frag_pos.xz / tile_edge;
		vec2 tile = floor(tpos);
		vec2 within = tpos - tile;
		vec2 tile_off = tile - paint_origin;
		// The UNPADDED (pitch = paint_tile_px) texel address drives the layout
		// textures and the selection/non-paintable masks: they are per-tile
		// lattices sampled NEAREST (one texel per tile), so they must not shift
		// into the pad.
		vec2 real_off = clamp(within, vec2(0.00001), vec2(0.99999)) * paint_tile_px;
		vec2 pixel = tile_off * paint_tile_px + real_off;
		vec2 puv = pixel / (atlas_tiles * paint_tile_px);
		// The SPLAT weights, however, are FILTER_LINEAR: address them through a
		// PADDED atlas cell (block = paint_tile_px with an edge-replicated
		// splat_pad ring on BOTH sides) so bilinear taps near a tile seam land
		// in the tile's own cloned edge texels instead of crossing into the
		// neighbour block or a zero gap. Bleeding in, black outlines, AND white
		// seams all disappear: a painted tile keeps its paint up to its edge.
		vec2 pitch = vec2(paint_tile_px + 2.0 * splat_pad);
		vec2 real_span = atlas_tiles * pitch;
		vec2 splat_px = tile_off * pitch + vec2(splat_pad) + real_off;
		vec2 spuv = splat_px / real_span;
		// Splat weights are FILTER_LINEAR bilinear over the texel grid, so the
		// R,G,B,A blend smoothly (no chunky pixels) and the painted channel can
		// never exceed 1.0 (competitive stamp, see header). One splat texel per
		// tile block pixel.
		vec4 v = texture(splat_splatmap, spuv);
		// Layout RGB bytes per channel: R = array layer (1-based, 0 = none),
		// G = per-tile texture repeat byte (round(repeat) - 1, so 1..256 ->
		// 0..255), B = per-tile masked-depth byte (round(depth * 255), so
		// 0.01..1.0 -> 1..255; 0 = no override -> the global paint_depth).
		// round() guards against UNORM float re-scaling inaccuracies.
		vec4 l0v = texture(chan_layout0, puv);
		vec4 l1v = texture(chan_layout1, puv);
		vec4 l2v = texture(chan_layout2, puv);
		vec4 l3v = texture(chan_layout3, puv);
		float ly0 = floor(l0v.r * 255.0 + 0.5);
		float ly1 = floor(l1v.r * 255.0 + 0.5);
		float ly2 = floor(l2v.r * 255.0 + 0.5);
		float ly3 = floor(l3v.r * 255.0 + 0.5);
		float rb0 = floor(l0v.g * 255.0 + 0.5);
		float rb1 = floor(l1v.g * 255.0 + 0.5);
		float rb2 = floor(l2v.g * 255.0 + 0.5);
		float rb3 = floor(l3v.g * 255.0 + 0.5);
		float dp0 = floor(l0v.b * 255.0 + 0.5);
		float dp1 = floor(l1v.b * 255.0 + 0.5);
		float dp2 = floor(l2v.b * 255.0 + 0.5);
		float dp3 = floor(l3v.b * 255.0 + 0.5);
		// A channel with no assigned layer is DEAD: zero its weight so its splat
		// bytes can't blend an empty sample in against an untextured channel.
		vec4 cad = vec4(step(0.5, ly0), step(0.5, ly1), step(0.5, ly2), step(0.5, ly3));
		vec4 w = v * cad;
		float kg = clamp(w.x + w.y + w.z + w.w, 0.0, 1.0);
		// Painted coverage BEFORE dead-gating: a texel whose splat weight sits in
		// a channel with no assigned layer drops out of kg (it has no texture to
		// blend) and would fall through to the white base, reading as "bare
		// ground". The switch below renders such texels BLACK instead.
		float kgraw = clamp(v.x + v.y + v.z + v.w, 0.0, 1.0);
		// Per-channel repeat from that channel's own layout byte, so each
		// texture scales independently per tile.
		vec2 u0 = fract(local_frag_pos.xz / max(tile_edge / max(1.0 + rb0, 0.5), 1e-4));
		vec2 u1 = fract(local_frag_pos.xz / max(tile_edge / max(1.0 + rb1, 0.5), 1e-4));
		vec2 u2 = fract(local_frag_pos.xz / max(tile_edge / max(1.0 + rb2, 0.5), 1e-4));
		vec2 u3 = fract(local_frag_pos.xz / max(tile_edge / max(1.0 + rb3, 0.5), 1e-4));
		// Albedo + mask alpha per channel (the "_s" soft alpha IS the alphamap
		// that feathers the material's blend at its texture boundary).
		vec4 t0 = texture(chan_arr0, vec3(u0, ly0 - 1.0));
		vec4 t1 = texture(chan_arr1, vec3(u1, ly1 - 1.0));
		vec4 t2 = texture(chan_arr2, vec3(u2, ly2 - 1.0));
		vec4 t3 = texture(chan_arr3, vec3(u3, ly3 - 1.0));
		// InnoGames masked-depth blend: height_i = splat weight x mask alpha.
		// The base material participates ONLY where the texel is essentially
		// bare: as a 5th height it would otherwise sit fractionally inside
		// covered texels and its white albedo bleed pale seams where painted
		// channels meet and along light stroke wisps. Gating it out makes
		// painted seams blend channel-to-channel; the bilinear splat feather
		// (weights falling to 0 across the texel boundary) still softens the
		// painted edge against the bare base just outside the coverage.
		vec4 hgt = w * vec4(t0.a, t1.a, t2.a, t3.a);
		float bgs = (kg < BASE_EPS) ? base_height : 0.0;
		float mxv = max(max(hgt.x, hgt.y), max(hgt.z, max(hgt.w, bgs)));
		// threshold must never go BELOW the max: with it negative, every channel
		// with zero height (unavailable layer, or the mask alpha dipping under
		// paint_depth - these tilesets' "_s" masks peak around 0.4) gains a
		// positive band weight b = 0 - thr whose black/white albedo drags the
		// texel gray. Clamping keeps zero-height materials out of the blend.
		// Depth is PER CHANNEL: each channel's own layout B byte (0 = tile has
		// no override -> the global paint_depth), so a pinned depth only ever
		// feathers that channel's blend on the tiles it was set for.
		vec4 dep = vec4(
			mix(paint_depth, dp0 / 255.0, step(0.5, dp0)),
			mix(paint_depth, dp1 / 255.0, step(0.5, dp1)),
			mix(paint_depth, dp2 / 255.0, step(0.5, dp2)),
			mix(paint_depth, dp3 / 255.0, step(0.5, dp3)));
		vec4 thrv = max(mxv - dep, vec4(0.0));
		vec4 b = max(hgt - thrv, vec4(0.0));
		float thr = max(mxv - paint_depth, 0.0);
		float bb = max(bgs - thr, 0.0);
		float sb = b.x + b.y + b.z + b.w + bb;
		if (sb > 1e-5) {
			// The base-material term is a seam blend of the top-2 live channels
			// (weighted) instead of flat white, so where two painted covers meet
			// across a bare gap the texel reads as a cross-fade of the two
			// textures, not a white flash. Fully-bare texels fall back to base.
			col = (t0.rgb * b.x + t1.rgb * b.y + t2.rgb * b.z + t3.rgb * b.w
				+ channel_seam(w, t0.rgb, t1.rgb, t2.rgb, t3.rgb, base_color) * bb) / sb;
		}
		// A texel with real painted coverage whose channels are ALL dead (a
		// flat-color weight with no texture anywhere to blend) shows BLACK, so
		// an untextured splat mark reads as such instead of white base.
		if (kgraw >= BASE_EPS && kg < BASE_EPS) {
			col = vec3(0.0);
		} else {
			if (kg >= BASE_EPS && sb < 1e-5) {
				// Every live channel masks to zero (a transparent hole in the
				// "_s" alpha). Inside a running channel MIXTURE the weight trace
				// is left to its natural look, so feather bands don't flash where
				// the alpha dips. Only when ONE channel fully owns the texel is
				// the hole resolved, to the channel's own texture color.
				float wtop = max(max(w.x, w.y), max(w.z, w.w));
				float wsecond = max(max((w.x >= wtop - 1e-4) ? 0.0 : w.x,
						(w.y >= wtop - 1e-4) ? 0.0 : w.y),
					max((w.z >= wtop - 1e-4) ? 0.0 : w.z,
						(w.w >= wtop - 1e-4) ? 0.0 : w.w));
				if (wsecond < 0.02) {
					// That single channel fully owns the texel, so the transparent
					// hole in its "_s" mask must NOT fall through to the base: the
					// texture's own pixels hold the real albedo there (photo
					// viewers show the pixels even under 0-alpha), so paint the
					// channel's actual color in the hole instead of a synthetic
					// gray/dark stain. The tiling sample above (t0..t3) already
					// matches the repeat the channel uses everywhere else. This
					// holds ONLY at full weight: a rim texel under a partial
					// falloff has zero masked height, so its hole falls through to
					// the base and the brush edge fades the alpha-0 texels there
					// instead of cutting them at full texture color.
					if (clamp(kg, 0.0, 1.0) > 0.999) {
						if (w.x >= wtop - 1e-4) { col = t0.rgb; }
						else if (w.y >= wtop - 1e-4) { col = t1.rgb; }
						else if (w.z >= wtop - 1e-4) { col = t2.rgb; }
						else { col = t3.rgb; }
					}
				}
			}
			// Soft-brush fade: the masked-depth blend renders the winning
			// channel's ALBEDO near-flat across its whole covered footprint, so
			// a dab's radial falloff only ever hid behind the "_s" mask alpha
			// (texels under 0-alpha clamped to full color -> hard cut at the
			// mask boundary). Where the paint weight (kg) sits below FULL,
			// cross-fade the finished texel toward the base, so the brush's
			// own falloff forces the fade on EVERY texel - including the
			// mask-alpha-0 holes - instead of cutting hard there.
			col = mix(base_color, col, clamp(kg, 0.0, 1.0));
		}
	}
	// Vertex tint: a per-texel color splatmap BLENDED onto the terrain albedo
	// (which already carries the splatmap's own layered paint - this runs after
	// it, so vertex paint stacks on top of the painted textures rather than
	// replacing them). The stored color is the top layer of the W3C blend above,
	// so the same picked color reads consistently over light and dark textures.
	if (vertex_tint_on) {
		// One CONTINUOUS tint lattice over the whole chunk, not one per tile.
		// `tp` is the fragment's position in tile units, so `g` is its position
		// in tint-texel units, globally. Bilinear filtering is then done by hand
		// so each of the four taps is addressed through wmt_tint_texel_uv() and
		// therefore resolves to the right tile even when the tap falls just
		// outside this tile. That keeps the ramp smooth across tile borders
		// instead of restarting at each one, and sampling at texel centres
		// removes the old half-texel offset (which blurred the whole lattice and
		// needed an ugly within-clamp to stop the edges bleeding).
		vec2 tp = local_frag_pos.xz / tile_edge;
		vec2 g = tp * float(tint_tile_px);
		vec2 f = g - 0.5;
		vec2 i0 = floor(f);
		vec2 fr = f - i0;
		vec4 c00 = texture(vertex_tint_tex, wmt_tint_texel_uv(i0));
		vec4 c10 = texture(vertex_tint_tex, wmt_tint_texel_uv(i0 + vec2(1.0, 0.0)));
		vec4 c01 = texture(vertex_tint_tex, wmt_tint_texel_uv(i0 + vec2(0.0, 1.0)));
		vec4 c11 = texture(vertex_tint_tex, wmt_tint_texel_uv(i0 + vec2(1.0, 1.0)));
		vec4 vt = mix(mix(c00, c10, fr.x), mix(c01, c11, fr.x), fr.y);
		// The splatmap stores the picked color per texel in RGB and how much of
		// it is there in A, so the blend reads straight from the texture: alpha
		// walks it out of the neutral 0.5 gray toward that color. Nothing here
		// depends on a global uniform, so re-picking a color only affects paint
		// applied from now on - existing paint keeps the color it was laid down
		// with. Unpainted texels are (0,0,0,0): alpha 0 keeps the neutral 0.5.
		vec3 blend = mix(vec3(0.5), clamp(vt.rgb, vec3(0.0), vec3(1.0)),
			clamp(vt.a, 0.0, 1.0));
		// SUPER-WHITE. A top layer of exactly 1.0 is a no-op on any base already
		// above 0.5 (the screen branch returns 1), so painting white over light
		// terrain did nothing at all - the one color you reach for to blow
		// highlights out could not. Lifting a near-white top layer past 1.0
		// makes the screen branch return 1 + boost*(1-base): white now bites on
		// mid tones, while the multiply branch below 0.5 triples instead of
		// doubling. The lift is gated by smoothstep so only genuinely bright
		// picks are super-charged - mids and darks keep the exact formula.
		// Terrain already at 1.0 still cannot go brighter (1 + boost*0), so this
		// cannot blow out to infinite white; it just makes white mean something.
		//
		// The lift is ALSO scaled by coverage. A full-strength stroke is
		// super-white, but a single light dab lands on a normal 1.0 top layer -
		// otherwise a barely-there mark instantly reads as a blown-out highlight
		// and every intensity control above looks like it does nothing.
		blend += smoothstep(vec3(0.7), vec3(1.0), blend) * vertex_tint_boost
			* clamp(vt.a, 0.0, 1.0);
		col = wmt_vertex_blend(clamp(col, vec3(0.0), vec3(1.0)), blend);
	}
	vec2 cell = local_frag_pos.xz / square_edge;
	vec2 f = fract(cell - 0.5) - 0.5;
	float db = min(abs(f.x), abs(f.y));
	float dd = min(abs(f.x - f.y), abs(f.x + f.y)) * 0.70710678;
	float d = min(db, dd);
	float af = fwidth(d);

	if (show_wire) {
		float edge = 1.0 - smoothstep(af * 0.5, af * (0.5 + edge_width), d);
		col = mix(col, wire_color, edge * line_opacity);
	}

	if (show_tile_lines) {
		float tw = square_edge * tile_cells;
		vec2 tf = fract(local_frag_pos.xz / tw - 0.5) - 0.5;
		float dt = min(abs(tf.x), abs(tf.y));
		float atf = fwidth(dt);
		float te = 1.0 - smoothstep(atf * 0.5, atf * (0.5 + tile_width), dt);
		col = mix(col, tile_color, te * line_opacity);
	}

	if (show_chunk_lines) {
		float cw = square_edge * chunk_cells;
		vec2 cf = fract(local_frag_pos.xz / cw - 0.5) - 0.5;
		float dc = min(abs(cf.x), abs(cf.y));
		float acf = fwidth(dc);
		float ce = 1.0 - smoothstep(acf * 0.5, acf * (0.5 + chunk_width), dc);
		col = mix(col, chunk_color, ce * line_opacity);
	}

	if (sel_on > 0.5 || nopaint_on > 0.5) {
		// Overlays live on the tile lattice, sampled through the same atlas uv
		// (one mask texel per tile). Blend at 50% over everything painted so
		// the selection / non-paintable state stays legible on any texture.
		vec2 tpos = local_frag_pos.xz / tile_edge;
		vec2 tile = floor(tpos);
		vec2 within = tpos - tile;
		vec2 pixel = (tile - paint_origin + clamp(within, vec2(0.00001), vec2(0.99999))) * paint_tile_px;
		vec2 puv = pixel / (atlas_tiles * paint_tile_px);
		if (sel_on > 0.5) {
			float sm = texture(sel_mask_tex, puv).r;
			col = mix(col, vec3(0.15, 0.45, 1.0), sm * 0.5);
		}
		if (nopaint_on > 0.5) {
			float np = texture(nopaint_mask_tex, puv).r;
			col = mix(col, vec3(1.0, 0.15, 0.15), np * 0.5);
		}
	}

	// Brush cursor as a direct overlay, drawn LAST so it always reads on top of
	// the paint, shading, lattice lines and selection masks. Constant screen
	// thickness via fwidth (exactly like the tile/chunk lines) - zoom never
	// fattens or thins it, and it can't z-fight because it lives in the same
	// fragment as the surface it marks.
	if (brush_on) {
		vec2 pos = local_frag_pos.xz - brush_center;
		float dcen = length(pos);
		float dr = dcen - brush_radius;
		float af = fwidth(dr);
		float band = 1.0 - smoothstep(af * 0.5, af * (0.5 + brush_width), abs(dr));
		col = mix(col, brush_color, band * line_opacity);
		if (brush_falloff_on) {
			float df = dcen - brush_falloff_radius;
			float af2 = fwidth(df);
			float band2 = 1.0 - smoothstep(af2 * 0.5, af2 * (0.5 + brush_width * 0.6), abs(df));
			col = mix(col, brush_color, band2 * line_opacity * 0.85);
		}
	}

	ALBEDO = col;
	// Matte finish, same as the default StandardMaterial3D: metallic 0 and
	// roughness 1, with the specular lobe dropped so no view-dependent
	// highlight can appear (glint on a moving sun is what made the old
	// look unstable). All the visible shading now comes from the Lambert
	// diffuse term over the mesh's vertex normals.
	METALLIC = 0.0;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
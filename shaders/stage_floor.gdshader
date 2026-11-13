// Polished dark stage floor: large glossy tiles with thin joints, two brass
// inlay rings around the stage and a warm pool of light under the machine.
// It is glossy on purpose — the curtain's up-lights, the marquee bulbs and
// the stage spots are mirrored in it (screen-space reflections when enabled,
// the sky otherwise) — but its own color stays very dark, so the floor never
// competes with the machine standing on it.
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.03, 0.022, 0.058);
uniform vec3 pool_color : source_color = vec3(0.2, 0.07, 0.19);
uniform vec3 brass_color : source_color = vec3(0.55, 0.4, 0.17);
uniform vec2 pool_center = vec2(0.0, 0.15);
uniform float pool_radius = 6.0;
uniform float tile_size = 1.6;
uniform float ring_a = 2.5;
uniform float ring_b = 3.6;
uniform float energy = 1.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 p = world_pos.xz;
	float r = length(p - pool_center);

	// Tiles: each one a touch different in tone and polish. The joints fade
	// out with distance instead of turning into shimmer.
	vec2 g = p / tile_size;
	vec2 id = floor(g);
	vec2 f = fract(g);
	float tone = hash21(id);
	float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	float px = max(fwidth(g.x), fwidth(g.y));
	float joint = (1.0 - smoothstep(0.006, 0.006 + px * 1.5, edge)) / (1.0 + px * 60.0);

	// Brass inlay rings around the stage.
	float ring_px = fwidth(r);
	float rings = 1.0 - smoothstep(0.022, 0.022 + ring_px * 1.5, min(abs(r - ring_a), abs(r - ring_b)));
	rings /= 1.0 + ring_px * 12.0;

	float pool = smoothstep(pool_radius, 0.8, r);
	vec3 col = base_color * (0.8 + 0.4 * tone);
	col += pool_color * pool * (0.32 + 0.14 * energy);
	col *= 1.0 - joint * 0.65;
	col = mix(col, brass_color, rings);

	ALBEDO = col;
	METALLIC = rings * 0.9;
	ROUGHNESS = mix(mix(0.14 + 0.1 * tone, 0.55, joint), 0.3, rings);
	SPECULAR = 0.5;
}

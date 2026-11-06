// Party backdrop for the drawing machine.
// Deep indigo -> purple/magenta haze gradient, soft drifting bokeh "party
// lights" and slow colored washes. Everything stays well below the glow
// threshold (HDR 1.2) so the machine's flashes, spin light and festoon bulbs
// still pop. `energy` (1 idle, ~1.4 spinning, pulse on reveal) is driven
// from bingo_machine.gd.
shader_type sky;

uniform vec3 top_color : source_color = vec3(0.045, 0.035, 0.13);
uniform vec3 mid_color : source_color = vec3(0.16, 0.055, 0.24);
uniform vec3 horizon_color : source_color = vec3(0.30, 0.09, 0.28);
uniform float energy = 1.0;
uniform float bokeh_strength = 0.2;
uniform float wash_strength = 0.09;

float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

// Party palette: pink, gold, cyan, violet, orange.
vec3 party_color(float t) {
	if (t < 0.2) return vec3(1.0, 0.35, 0.7);
	if (t < 0.4) return vec3(1.0, 0.78, 0.3);
	if (t < 0.6) return vec3(0.3, 0.85, 1.0);
	if (t < 0.8) return vec3(0.65, 0.45, 1.0);
	return vec3(1.0, 0.55, 0.25);
}

vec3 base_gradient(float h) {
	vec3 col = mix(horizon_color, mid_color, smoothstep(0.0, 0.28, h));
	col = mix(col, top_color, smoothstep(0.28, 0.85, h));
	if (h < 0.0) {
		col = horizon_color * 0.55;
	}
	return col;
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;
	vec3 col = base_gradient(h);
	if (AT_CUBEMAP_PASS) {
		// Reflections / radiance: static gradient only (no per-frame re-bake).
		COLOR = col;
	} else {
		float az = atan(d.x, -d.z);
		float el = asin(clamp(h, -1.0, 1.0));
		float above = smoothstep(-0.04, 0.12, h);
		// Two layers of soft bokeh discs drifting sideways.
		for (int layer = 0; layer < 2; layer++) {
			float scale = layer == 0 ? 5.5 : 9.0;
			float speed = layer == 0 ? 0.012 : 0.02;
			vec2 g = vec2(az, el) * scale + vec2(TIME * speed * (0.8 + 0.4 * energy), 0.0);
			vec2 cell = floor(g);
			vec2 f = fract(g);
			float rnd = hash12(cell + float(layer) * 17.0);
			if (rnd > 0.52) {
				vec2 c = vec2(hash12(cell + 3.1), hash12(cell + 7.7)) * 0.6 + 0.2;
				float r = mix(0.14, 0.32, hash12(cell + 11.3)) * (layer == 0 ? 1.0 : 0.7);
				float dist = length(f - c);
				float disk = smoothstep(r, r * 0.55, dist);
				disk += smoothstep(r * 1.02, r * 0.95, dist) * 0.25;  // faint rim like a lens bokeh
				float tw = 0.55 + 0.45 * sin(TIME * (0.5 + rnd * 1.4) * (0.7 + 0.5 * energy) + rnd * 40.0);
				vec3 lc = party_color(hash12(cell + 5.5));
				float k = layer == 0 ? 1.0 : 0.55;
				col += lc * disk * tw * bokeh_strength * k * energy * above;
			}
		}
		// Slow colored washes, like moving stage lights on the back wall.
		for (int i = 0; i < 3; i++) {
			float fi = float(i);
			float cx = sin(TIME * (0.07 + 0.03 * fi) + fi * 2.1) * 1.1;
			float cy = 0.25 + 0.12 * sin(TIME * (0.05 + 0.02 * fi) + fi);
			vec2 p = vec2(az - cx, (el - cy) * 1.6);
			float w = exp(-dot(p, p) * 3.0);
			col += party_color(fract(0.13 + fi * 0.29)) * w * wash_strength * energy * above;
		}
		// Gentle vignette keeps the eye on the machine and the number.
		float v = length((SCREEN_UV - 0.5) * vec2(1.1, 1.0));
		col *= mix(1.0, 0.72, smoothstep(0.35, 0.85, v));
		COLOR = col;
	}
}

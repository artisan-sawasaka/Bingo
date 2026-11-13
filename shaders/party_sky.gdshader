// Sky dome around the stage set. It is hardly ever seen directly (the curtain
// surrounds the stage) — its job is lighting: the gold and chrome parts of the
// machine and the glossy floor mirror it. A dark indigo-to-magenta gradient
// with a few large, soft "party light" blobs gives those reflections color.
// Completely static (no TIME, no per-frame parameters), so the reflection
// cubemap is baked once instead of being rebuilt every frame.
shader_type sky;

uniform vec3 top_color : source_color = vec3(0.045, 0.035, 0.13);
uniform vec3 mid_color : source_color = vec3(0.16, 0.055, 0.24);
uniform vec3 horizon_color : source_color = vec3(0.30, 0.09, 0.28);
uniform float blob_strength = 0.35;

vec3 blob(vec3 dir, vec3 toward, vec3 color, float tightness) {
	float d = max(0.0, dot(dir, normalize(toward)));
	return color * pow(d, tightness);
}

void sky() {
	vec3 d = normalize(EYEDIR);
	float h = d.y;
	vec3 col = mix(horizon_color, mid_color, smoothstep(0.0, 0.28, h));
	col = mix(col, top_color, smoothstep(0.28, 0.85, h));
	if (h < 0.0) {
		col = mix(horizon_color, horizon_color * 0.45, smoothstep(0.0, -0.4, h));
	}
	vec3 lights = blob(d, vec3(-0.7, 0.45, -0.5), vec3(1.0, 0.35, 0.7), 14.0);
	lights += blob(d, vec3(0.75, 0.5, -0.4), vec3(0.3, 0.8, 1.0), 16.0);
	lights += blob(d, vec3(0.1, 0.8, 0.6), vec3(1.0, 0.75, 0.35), 10.0);
	lights += blob(d, vec3(-0.5, 0.35, 0.8), vec3(0.6, 0.45, 1.0), 12.0);
	COLOR = col + lights * blob_strength;
}

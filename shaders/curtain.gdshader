// Stage curtain behind the drawing machine: dark velvet hanging in soft
// pleats, lit from the floor by a row of colored up-lights.
//
// It is a BACKDROP: everything here is deliberately dark, low in contrast and
// soft (no sharp detail), so it reads as "out of focus" behind the machine:
//   * all values stay far below the glow threshold (nothing blooms)
//   * `focus_uv` marks where the machine is on screen; the curtain is dimmed
//     around it, so the glass drum always sits on a calm, dark area
//   * unshaded and fog-free: the look does not depend on the scene lights
// `energy` (1 idle .. ~1.4 while drawing, short pulse on a reveal) only makes
// the up-lights breathe a little stronger.
shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;

uniform vec3 velvet_color : source_color = vec3(0.105, 0.04, 0.165);
uniform vec3 wall_center = vec3(0.0, 0.0, 0.15);
uniform float wall_radius = 11.0;
uniform float wall_height = 9.0;
// Distance between two up-lights along the curtain (m).
uniform float light_spacing = 2.6;
uniform float light_strength = 0.2;
uniform float energy = 1.0;
// Screen position (0..1) of the machine, and how much the curtain is dimmed there.
uniform vec2 focus_uv = vec2(0.31, 0.45);
uniform float focus_dim = 0.5;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

float hash11(float p) {
	p = fract(p * 0.1031);
	p *= p + 33.33;
	p *= p + p;
	return fract(p);
}

// Restrained party palette for the up-lights.
vec3 light_color(float i) {
	float t = fract(i * 0.25 + 0.05);
	// Neighbouring hues only (no warm / cold jumps): calm, and it leaves the
	// gold and red of the machine as the only warm colors on screen.
	if (t < 0.25) return vec3(0.9, 0.28, 0.66);   // magenta
	if (t < 0.5) return vec3(0.55, 0.34, 1.0);    // violet
	if (t < 0.75) return vec3(0.3, 0.46, 1.0);    // blue
	return vec3(0.72, 0.3, 0.9);                  // purple
}

void fragment() {
	vec3 d = world_pos - wall_center;
	// Meters along the curtain; 0 = straight behind the machine.
	float s = atan(d.x, -d.z) * wall_radius;
	float y = world_pos.y;
	float up = clamp(y / wall_height, 0.0, 1.0);

	// Pleats: wide folds that wander a little, plus finer creases. The fabric
	// gathers toward the top, so the folds get tighter up there.
	float wander = sin(s * 0.8 + y * 0.3) * 0.4 + sin(y * 1.5 + s * 2.0) * 0.05;
	float phase = (s + wander) * (8.5 + 1.5 * up);
	float fold = sin(phase);
	float crease = sin(phase * 2.7 + 1.3);
	// Side light: one flank of every fold is brighter than the other.
	float lit = 0.5 + 0.5 * (cos(phase + 0.7) * 0.75 + crease * 0.25);
	float valley = smoothstep(-0.3, -1.0, fold);
	float pleat = mix(0.5, 1.0, lit) * (1.0 - 0.35 * valley);

	// Darker toward the top: the eye stays low, where the machine is.
	vec3 col = velvet_color * pleat * mix(1.2, 0.22, smoothstep(0.0, 0.8, up));
	// Velvet sheen on the ridges, only where light reaches.
	col += velvet_color * pow(lit, 6.0) * 0.5 * (1.0 - up);

	// Up-lights on the floor: soft cones that widen as they rise.
	float nearest = floor(s / light_spacing + 0.5);
	vec3 glow = vec3(0.0);
	for (int k = -1; k <= 1; k++) {
		float i = nearest + float(k);
		float ds = s - i * light_spacing;
		float w = 0.5 + 0.3 * y;
		float cone = exp(-(ds * ds) / (w * w)) * exp(-y / 2.3) * smoothstep(-0.05, 0.3, y);
		float breathe = 0.78 + 0.22 * sin(TIME * (0.22 + 0.1 * hash11(i + 7.0)) + i * 2.4);
		glow += light_color(i) * cone * breathe;
	}
	col += glow * light_strength * (0.55 + 0.45 * energy) * mix(0.55, 1.0, pleat);

	// Calm, dark area behind the machine + gentle vignette toward the corners.
	float dist = distance(SCREEN_UV, focus_uv);
	col *= mix(1.0 - focus_dim, 1.0, smoothstep(0.1, 0.42, dist));
	col *= mix(1.0, 0.7, smoothstep(0.55, 1.0, dist));
	ALBEDO = col;
}

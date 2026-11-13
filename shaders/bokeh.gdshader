// Out-of-focus party lights: every string-light bulb is drawn as a soft
// "bokeh" disc (camera-facing quad, additive) — a flat, translucent circle
// with a slightly brighter rim, like a defocused lens would show it. This is
// what makes the backdrop read as far away and out of focus without a
// full-screen blur pass.
//   instance COLOR.rgb  = light color, COLOR.a = brightness
//   INSTANCE_CUSTOM.x   = twinkle phase, .y = twinkle speed
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform float energy = 1.0;
uniform float strength = 0.2;

varying vec4 light;
varying float twinkle;

void vertex() {
	light = COLOR;
	twinkle = 0.72 + 0.28 * sin(TIME * INSTANCE_CUSTOM.y * (0.7 + 0.3 * energy) + INSTANCE_CUSTOM.x);
	// Face the camera, keep the instance scale.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
			vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
			vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
			vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
			vec4(0.0, 0.0, 0.0, 1.0));
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	float r = length(UV - vec2(0.5)) * 2.0;
	float disc = 1.0 - smoothstep(0.86, 1.0, r);
	float rim = smoothstep(0.62, 0.9, r) * disc;
	float core = 1.0 - smoothstep(0.0, 0.9, r);
	float shape = disc * (0.62 + 0.38 * rim + 0.12 * core);
	ALBEDO = light.rgb * shape * light.a * twinkle * strength * (0.75 + 0.25 * energy);
}

// A faint shaft of stage light hanging in the air behind the machine (one
// flat quad per beam, additive). UV.y = 0 at the lamp (top), 1 at the floor;
// the shaft widens downward and fades out before it reaches the floor.
// Kept very dim on purpose: it adds haze and depth, it is not a light show.
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, fog_disabled, shadows_disabled;

uniform vec3 beam_color : source_color = vec3(1.0, 0.5, 0.8);
uniform float strength = 0.06;

void fragment() {
	float along = UV.y;
	float half_width = mix(0.06, 0.5, along);
	float across = abs(UV.x - 0.5);
	float body = smoothstep(half_width, half_width * 0.1, across);
	float fade = pow(1.0 - along, 1.25) * smoothstep(0.0, 0.08, along);
	ALBEDO = beam_color * body * body * fade * strength;
}

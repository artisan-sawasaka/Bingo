// Bingo ball with the number PRINTED on its surface (not a floating billboard).
// The label texture (white disc + number, transparent outside) is projected
// orthographically along `label_dir` (local space) onto the sphere, on both
// sides of the ball. Because it is part of the surface it follows the curve,
// gets the same lighting / gloss, and rotates with the ball.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 base_color : source_color = vec4(1.0);
uniform sampler2D label_tex : source_color, filter_linear, repeat_disable;
uniform vec3 label_dir = vec3(0.0, 0.0, 1.0);
// Half size of the label on the tangent plane, as a fraction of the ball radius.
uniform float label_radius : hint_range(0.1, 1.0) = 0.66;
uniform bool show_label = false;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.22;
uniform float clearcoat_value : hint_range(0.0, 1.0) = 0.6;

varying vec3 local_pos;

void vertex() {
	local_pos = VERTEX;
}

void fragment() {
	vec3 albedo = base_color.rgb;
	if (show_label) {
		vec3 p = normalize(local_pos);
		vec3 d = normalize(label_dir);
		vec3 up = abs(d.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
		vec3 tx = normalize(cross(up, d));
		vec3 ty = cross(d, tx);
		float side = dot(p, d) >= 0.0 ? 1.0 : -1.0;  // second print on the back
		vec2 q = vec2(dot(p, tx * side), dot(p, ty)) / label_radius;
		vec2 uv = vec2(q.x * 0.5 + 0.5, 0.5 - q.y * 0.5);
		if (all(greaterThanEqual(uv, vec2(0.0))) && all(lessThanEqual(uv, vec2(1.0)))) {
			vec4 l = texture(label_tex, uv);
			albedo = mix(albedo, l.rgb, l.a);
		}
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness_value;
	CLEARCOAT = clearcoat_value;
	CLEARCOAT_ROUGHNESS = 0.15;
}

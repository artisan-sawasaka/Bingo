// Party stage floor: dark violet with a warm light pool under the machine and
// a very faint dance-floor tile grid. Lit (receives shadows / spot light).
shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

uniform vec3 base_color : source_color = vec3(0.06, 0.045, 0.11);
uniform vec3 pool_color : source_color = vec3(0.34, 0.12, 0.3);
uniform vec3 grid_color : source_color = vec3(0.35, 0.22, 0.55);
uniform vec2 pool_center = vec2(0.2, 0.4);
uniform float pool_radius = 5.5;
uniform float energy = 1.0;

varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 p = world_pos.xz;
	float r = length(p - pool_center);
	float pool = smoothstep(pool_radius, 0.8, r);
	vec2 cell = abs(fract(p * 0.5) - 0.5);
	float line = smoothstep(0.485, 0.5, max(cell.x, cell.y)) * smoothstep(9.0, 2.0, r);
	vec3 col = base_color + pool_color * pool * (0.55 + 0.25 * energy);
	col += grid_color * line * 0.18;
	ALBEDO = col;
	ROUGHNESS = 0.78;
	SPECULAR = 0.08;  // low: avoids a bright rim-light streak at the far edge
}

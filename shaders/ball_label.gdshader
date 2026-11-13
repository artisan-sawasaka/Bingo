// Bingo ball with its number PRINTED on the surface (not a floating billboard).
// Drawn through MultiMesh, so every ball in the drum / on the stage rim is one
// instance of the same mesh + material:
//   instance COLOR        = ball color (number band)
//   INSTANCE_CUSTOM.x     = number (1..999, 0 = blank ball)
//   INSTANCE_CUSTOM.y     = flash 0..1 (emission pulse when the ball is hit)
// The label (white disc, colored ring, digits, underline) is built in the
// shader from a 10-layer digit texture and projected along local +Z onto both
// sides of the sphere, so it follows the curve, the lighting and the tumbling.
// The underline keeps 6 / 9 / 66 / 99 readable while the ball is upside down.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

// Layers 0..9 = glyphs "0".."9" (red channel = ink coverage), with mipmaps.
uniform sampler2DArray digit_tex : filter_linear_mipmap_anisotropic, repeat_disable;
uniform bool digits_ready = false;
// Label disc radius on the tangent plane, as a fraction of the ball radius.
uniform float label_radius : hint_range(0.1, 1.0) = 0.74;
// Glyph cell width / height.
uniform float digit_aspect = 0.8;
// Where the ink of the digits really is inside a glyph cell, measured after
// the glyphs were rendered (ball_visuals.gd): top / bottom as a fraction of
// the cell height (0 = top), and the widest digit as a fraction of the cell
// width. The number is sized and placed from these, not from font metrics.
uniform float ink_top = 0.2;
uniform float ink_bottom = 0.85;
uniform float ink_width = 0.75;
uniform float roughness_value : hint_range(0.0, 1.0) = 0.22;
uniform float clearcoat_value : hint_range(0.0, 1.0) = 0.6;
uniform float flash_energy = 0.6;

varying vec3 local_pos;
varying vec3 ball_color;
varying float ball_number;
varying float ball_flash;

void vertex() {
	local_pos = VERTEX;
	ball_color = COLOR.rgb;
	ball_number = INSTANCE_CUSTOM.x;
	ball_flash = INSTANCE_CUSTOM.y;
}

void fragment() {
	vec3 albedo = ball_color;
	int n = int(ball_number + 0.5);
	if (n > 0) {
		vec3 p = normalize(local_pos);
		float side = p.z >= 0.0 ? 1.0 : -1.0;  // second print on the back
		vec2 q = vec2(p.x * side, p.y) / label_radius;
		// Derivatives are taken before any branch (texture lookups below sit in
		// conditionals, where implicit derivatives would be undefined).
		vec2 dqx = dFdx(q);
		vec2 dqy = dFdy(q);
		float r = length(q);
		float aa = clamp(length(vec2(length(dqx), length(dqy))), 0.002, 0.2);
		float disc = 1.0 - smoothstep(1.0 - aa, 1.0 + aa, r);
		if (disc > 0.0) {
			float ring = smoothstep(0.83 - aa, 0.83 + aa, r);
			float luma = dot(ball_color, vec3(0.3, 0.6, 0.1));
			// White / silver balls get a grey ring, colored balls a darker shade.
			vec3 ring_col = mix(ball_color * 0.5, vec3(0.5, 0.52, 0.6), smoothstep(0.75, 0.9, luma));
			vec3 label = mix(vec3(0.97, 0.97, 0.95), ring_col, ring);
			int count = n >= 100 ? 3 : (n >= 10 ? 2 : 1);
			// Layout in label units (disc radius = 1, white area up to 0.83):
			// digits of height `tall`, a gap, then the underline; the whole
			// block is centered on the disc and stays clear of the ring.
			float tall = count == 3 ? 0.52 : (count == 2 ? 0.72 : 1.02);
			float gap = tall * 0.12;
			float thick = tall * 0.1;
			float base = (gap + thick - tall) * 0.5;                // bottom edge of the digits
			float h = tall / max(0.05, ink_bottom - ink_top);       // glyph cell height
			float cw = h * digit_aspect;                            // glyph cell width
			float adv = ink_width * cw * 1.08;                      // widest digit + a little air
			float y0 = base - (0.5 - ink_bottom) * h;               // center of the glyph cells
			float ink = 0.0;
			if (digits_ready) {
				int div = count == 3 ? 100 : (count == 2 ? 10 : 1);
				for (int i = 0; i < 3; i++) {
					if (i >= count) {
						break;
					}
					int dgt = (n / div) % 10;
					div = max(1, div / 10);
					float cx = (float(i) - float(count - 1) * 0.5) * adv;
					vec2 uv = vec2((q.x - cx) / cw + 0.5, 0.5 - (q.y - y0) / h);
					if (uv.x > 0.0 && uv.x < 1.0 && uv.y > 0.0 && uv.y < 1.0) {
						vec2 gx = vec2(dqx.x / cw, -dqx.y / h);
						vec2 gy = vec2(dqy.x / cw, -dqy.y / h);
						ink = max(ink, textureGrad(digit_tex, vec3(uv, float(dgt)), gx, gy).r);
					}
				}
			}
			float bar_half_w = adv * float(count) * 0.44;
			float bar_y = base - gap - thick * 0.5;
			float bar = (1.0 - smoothstep(bar_half_w - aa, bar_half_w + aa, abs(q.x)))
					* (1.0 - smoothstep(thick * 0.5 - aa, thick * 0.5 + aa, abs(q.y - bar_y)));
			ink = max(ink, bar) * (1.0 - ring);
			label = mix(label, vec3(0.06, 0.07, 0.12), ink);
			albedo = mix(albedo, label, disc);
		}
	}
	ALBEDO = albedo;
	ROUGHNESS = roughness_value;
	CLEARCOAT = clearcoat_value;
	CLEARCOAT_ROUGHNESS = 0.15;
	EMISSION = (ball_color * 0.55 + vec3(0.45)) * ball_flash * flash_energy;
}

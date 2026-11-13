// Marquee bulbs on the stage rim. Instance COLOR.rgb = bulb color,
// COLOR.a = brightness (0 = off, 1 = idle glow, above 1 blooms).
shader_type spatial;
render_mode unshaded, shadows_disabled;

uniform float energy = 2.2;

varying vec4 bulb;

void vertex() {
	bulb = COLOR;
}

void fragment() {
	// An unlit bulb is still visible as dim glass.
	ALBEDO = bulb.rgb * (0.07 + bulb.a * energy);
}

extends "res://tests/test_case.gd"
## The stage set behind the machine (curtain, out-of-focus lights, light
## shafts) and the switch for the screen-space extras.

const Backdrop = preload("res://scripts/machine/backdrop.gd")
const BingoMachine = preload("res://scripts/machine/bingo_machine.gd")


func test_backdrop_builds_curtain_lights_and_beams() -> void:
	var b = Backdrop.new()
	add_child(b)
	var curtain: MeshInstance3D = b.get_node_or_null("Curtain")
	check(curtain != null, "curtain exists")
	if curtain != null:
		var wall: CylinderMesh = curtain.mesh
		check(not wall.cap_top and not wall.cap_bottom, "an open wall around the stage, no lid")
		# The camera stands about 8 m from the stage center: it must be inside the curtain.
		check(wall.top_radius > 9.0, "curtain is far enough behind the machine: %.1f m" % wall.top_radius)
		eq(curtain.cast_shadow, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, "backdrop casts no shadows")
	var expected := 0
	for g in Backdrop.GARLANDS:
		expected += int(g[3]) - 1
	eq(b.bokeh_count(), expected, "one bokeh disc per bulb")
	eq(b.beam_count(), Backdrop.BEAMS.size(), "light shafts")
	# Every string of lights hangs high (above the drum on screen), behind the stage.
	for g in Backdrop.GARLANDS:
		var a: Vector3 = g[0]
		var c: Vector3 = g[1]
		var sag: float = g[2]
		check(minf(a.y, c.y) - sag > 2.6, "string lights stay above the machine")
		check(a.z < -4.0 and c.z < -4.0, "string lights are behind the stage")
	# Light shafts stay faint.
	for spec in Backdrop.BEAMS:
		var strength: float = spec[3]
		check(strength <= 0.1, "light shaft is faint: %.3f" % strength)
	# Runs with any excitement level and focus point.
	b.energy = 2.5
	b.set_focus(Vector2(0.3, 0.4))
	b._process(0.1)
	b.energy = 0.0
	b._process(0.1)
	b.queue_free()


func test_machine_can_switch_the_screen_space_effects() -> void:
	var m = BingoMachine.new()
	add_child(m)
	check(m.backdrop != null, "machine has its backdrop")
	check(m.effects_high, "extras are on by default")
	check(m._env.ssr_enabled and m._env.ssao_enabled, "floor reflections and contact shadows on")
	m.set_effects_quality(false)
	check(not m.effects_high and not m._env.ssr_enabled and not m._env.ssao_enabled, "both off in the light mode")
	m.set_effects_quality(true)
	check(m._env.ssr_enabled, "and on again")
	# The polished floor is on its own render layer so that glare-prone lights can skip it.
	var floor: MeshInstance3D = m.get_node_or_null("Floor")
	check(floor != null, "floor exists")
	if floor != null:
		eq(floor.layers, BingoMachine.FLOOR_LAYER, "floor render layer")
	eq(m._spin_light.light_cull_mask & BingoMachine.FLOOR_LAYER, 0, "spin light leaves the floor out")
	m.queue_free()

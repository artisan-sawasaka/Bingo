extends Node3D
## The stage set behind the drawing machine. A backdrop, not a show: every
## part is dark, soft and slow, so the machine in front stays the brightest,
## sharpest and busiest thing on screen.
##   * a curved velvet curtain with pleats and a row of colored up-lights
##     (shaders/curtain.gdshader), dimmed where the machine stands on screen
##   * strings of party lights drawn out of focus, as bokeh discs
##     (shaders/bokeh.gdshader) — three rows at different depths
##   * a few very faint shafts of light hanging in the air
## bingo_machine.gd sets `energy` (1 idle, a little higher while drawing) and
## `set_focus()` (where the machine is on screen).

const CurtainShader = preload("res://shaders/curtain.gdshader")
const BeamShader = preload("res://shaders/light_beam.gdshader")
const BokehShader = preload("res://shaders/bokeh.gdshader")

const COLORS := [
	Color(1.0, 0.35, 0.7),   # pink
	Color(1.0, 0.78, 0.3),   # gold
	Color(0.3, 0.85, 1.0),   # cyan
	Color(0.65, 0.45, 1.0),  # violet
	Color(1.0, 0.55, 0.25),  # orange
]

## String lights: start, end, sag (m), bulb count, bokeh size (m), brightness.
## Farther rows are larger and dimmer, like lights further out of focus.
## They hang high, above the drum on screen — never behind the glass.
const GARLANDS := [
	[Vector3(-9.5, 3.75, -6.5), Vector3(10.0, 3.6, -6.5), 0.55, 24, 0.3, 1.0],
	[Vector3(-11.0, 4.25, -9.2), Vector3(11.5, 4.4, -9.2), 0.5, 22, 0.46, 0.6],
]

## Light shafts: lamp position, tilt (degrees, + leans right), color index, strength.
const BEAMS := [
	[Vector3(-4.6, 7.4, -3.4), 13.0, 0, 0.085],
	[Vector3(-1.8, 7.6, -5.0), 5.0, 3, 0.06],
	[Vector3(2.2, 7.6, -4.6), -6.0, 2, 0.06],
	[Vector3(5.2, 7.4, -3.2), -14.0, 3, 0.075],
]
const BEAM_LENGTH := 8.2
const BEAM_WIDTH := 3.4

## Center of the stage on the floor; the curtain is a circle around it.
var center := Vector3(0.0, 0.0, 0.15)
var radius := 11.0
var height := 9.0
var energy := 1.0

var _curtain_mat: ShaderMaterial
var _bokeh_mat: ShaderMaterial
var _beams: Array = []   # [{ pivot: Node3D, mat: ShaderMaterial, tilt: float, strength: float, phase: float }]
var _time := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 7
	_build_curtain()
	_build_bokeh()
	_build_beams()


func _build_curtain() -> void:
	# The inside of an open cylinder around the stage.
	var wall := CylinderMesh.new()
	wall.top_radius = radius
	wall.bottom_radius = radius
	wall.height = height
	wall.radial_segments = 96
	wall.rings = 1
	wall.cap_top = false
	wall.cap_bottom = false
	_curtain_mat = ShaderMaterial.new()
	_curtain_mat.shader = CurtainShader
	_curtain_mat.set_shader_parameter("wall_center", center)
	_curtain_mat.set_shader_parameter("wall_radius", radius)
	_curtain_mat.set_shader_parameter("wall_height", height)
	var mi := MeshInstance3D.new()
	mi.name = "Curtain"
	mi.mesh = wall
	mi.material_override = _curtain_mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = center + Vector3(0, height * 0.5, 0)
	add_child(mi)


func _build_bokeh() -> void:
	var count := 0
	for g in GARLANDS:
		count += int(g[3]) - 1
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_bokeh_mat = ShaderMaterial.new()
	_bokeh_mat.shader = BokehShader
	quad.material = _bokeh_mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = quad
	mm.instance_count = count
	var k := 0
	for g in GARLANDS:
		var a: Vector3 = g[0]
		var b: Vector3 = g[1]
		var sag: float = g[2]
		var n: int = g[3]
		var size: float = g[4]
		var bright: float = g[5]
		for i in range(1, n):
			var t := float(i) / n
			var p := a.lerp(b, t) - Vector3(0, sag * 4.0 * t * (1.0 - t), 0)
			# Not a ruler-straight row of equal dots: bulbs hang a little unevenly.
			p += Vector3(_rng.randf_range(-0.22, 0.22), _rng.randf_range(-0.1, 0.1), _rng.randf_range(-0.3, 0.3))
			var s := size * _rng.randf_range(0.7, 1.35)
			mm.set_instance_transform(k, Transform3D(Basis.IDENTITY * s, p))
			var c: Color = COLORS[k % COLORS.size()]
			mm.set_instance_color(k, Color(c.r, c.g, c.b, bright * _rng.randf_range(0.7, 1.0)))
			mm.set_instance_custom_data(k, Color(_rng.randf() * TAU, _rng.randf_range(0.5, 1.6), 0.0, 0.0))
			k += 1
	var mi := MultiMeshInstance3D.new()
	mi.name = "BokehLights"
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)


func _build_beams() -> void:
	for spec in BEAMS:
		var lamp: Vector3 = spec[0]
		var tilt: float = spec[1]
		var color: Color = COLORS[int(spec[2])]
		var strength: float = spec[3]
		var quad := QuadMesh.new()
		quad.size = Vector2(BEAM_WIDTH, BEAM_LENGTH)
		var mat := ShaderMaterial.new()
		mat.shader = BeamShader
		mat.set_shader_parameter("beam_color", color)
		mat.set_shader_parameter("strength", strength)
		quad.material = mat
		var pivot := Node3D.new()
		pivot.name = "Beam%d" % _beams.size()
		pivot.position = lamp
		pivot.rotation.z = deg_to_rad(tilt)
		var mi := MeshInstance3D.new()
		mi.mesh = quad
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.position = Vector3(0, -BEAM_LENGTH * 0.5, 0)  # the lamp end sits at the pivot
		pivot.add_child(mi)
		add_child(pivot)
		_beams.append({"pivot": pivot, "mat": mat, "tilt": deg_to_rad(tilt), "strength": strength, "phase": _rng.randf() * TAU})


## Where the machine is on screen (0..1): the curtain stays dark around it.
func set_focus(uv: Vector2) -> void:
	if _curtain_mat != null:
		_curtain_mat.set_shader_parameter("focus_uv", uv)


func bokeh_count() -> int:
	var mi: MultiMeshInstance3D = get_node_or_null("BokehLights")
	return mi.multimesh.instance_count if mi != null else 0


func beam_count() -> int:
	return _beams.size()


func _process(delta: float) -> void:
	_time += delta
	var e := clampf(energy, 0.8, 2.2)
	_curtain_mat.set_shader_parameter("energy", e)
	_bokeh_mat.set_shader_parameter("energy", e)
	for beam in _beams:
		var pivot: Node3D = beam.pivot
		var mat: ShaderMaterial = beam.mat
		var tilt: float = beam.tilt
		var phase: float = beam.phase
		var strength: float = beam.strength
		# A slow, small sway; a touch brighter while a number is drawn.
		pivot.rotation.z = tilt + sin(_time * 0.17 + phase) * 0.05
		mat.set_shader_parameter("strength", strength * (0.6 + 0.4 * e))

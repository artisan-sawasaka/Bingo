extends Node3D
## Game-show lighting around the machine:
##   * a row of marquee bulbs on the side of the stage (one MultiMesh). Idle:
##     slow alternating twinkle. Drawing: a chase running clockwise, faster and
##     brighter with `drive`. Reveal: every bulb flashes in the ball's color.
##   * two colored spot lights sweeping over the floor while the drum spins.
## bingo_machine.gd sets `drive` (0 idle .. 1 full spin) and calls `flash()`.

const MarqueeShader = preload("res://shaders/marquee.gdshader")

const WARM := Color(1.0, 0.74, 0.32)
const SWEEP_COLORS := [Color(1.0, 0.35, 0.75), Color(0.3, 0.8, 1.0)]

var center := Vector3(0.0, 0.085, 0.15)
var radius := 1.87
var bulb_count := 48
## 0 = idle, 1 = drum at full speed.
var drive := 0.0

var _mm: MultiMesh
var _phase := 0.0
var _chase := 0.0
var _flash := 0.0
var _flash_color := Color.WHITE
var _sweeps: Array[SpotLight3D] = []
var _sweep_angle := 0.0


func _ready() -> void:
	var bulb := SphereMesh.new()
	bulb.radius = 0.036
	bulb.height = 0.072
	bulb.radial_segments = 10
	bulb.rings = 5
	var mat := ShaderMaterial.new()
	mat.shader = MarqueeShader
	bulb.material = mat
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = bulb
	_mm.instance_count = bulb_count
	for i in bulb_count:
		_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, bulb_position(i)))
		_mm.set_instance_color(i, Color(WARM.r, WARM.g, WARM.b, 0.5))
	var mi := MultiMeshInstance3D.new()
	mi.name = "Marquee"
	mi.multimesh = _mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	for i in SWEEP_COLORS.size():
		var spot := SpotLight3D.new()
		spot.name = "Sweep%d" % i
		spot.light_color = SWEEP_COLORS[i]
		spot.spot_angle = 17.0
		spot.spot_range = 12.0
		spot.spot_attenuation = 0.6
		spot.light_energy = 0.0
		spot.shadow_enabled = false
		# Colored pools on the floor only: on the polished floor a specular
		# highlight would be a white glare wandering around the stage.
		spot.light_specular = 0.0
		add_child(spot)
		_sweeps.append(spot)


## Clockwise seen from above, starting at the front (+Z) — same sense as the ball ring.
func bulb_position(i: int) -> Vector3:
	var a := TAU * float(i) / float(bulb_count)
	return center + Vector3(-sin(a) * radius, 0.0, cos(a) * radius)


func flash(color: Color) -> void:
	_flash = 1.0
	_flash_color = color.lerp(Color.WHITE, 0.25)


func _process(delta: float) -> void:
	_phase += delta
	_chase += delta * (1.5 + 16.0 * drive)
	_flash = move_toward(_flash, 0.0, delta * 1.3)
	var lit := 0.35 + 0.25 * drive
	for i in bulb_count:
		var level: float
		if drive > 0.02:
			# Three bright heads running around the rim with fading tails.
			var x := fposmod(_chase - float(i), float(bulb_count) / 3.0) / (float(bulb_count) / 3.0)
			level = lit * 0.4 + (1.0 - x) * (1.0 - x) * (0.7 + 1.2 * drive)
		else:
			var odd := 1.0 if i % 2 == 0 else -1.0
			level = lit + 0.3 * odd * sin(_phase * 1.4)
		var c := WARM.lerp(_flash_color, _flash)
		_mm.set_instance_color(i, Color(c.r, c.g, c.b, level + _flash * 1.6))
	# Floor sweeps: two cones circling the machine in opposite directions.
	_sweep_angle += delta * (0.25 + 2.6 * drive)
	for i in _sweeps.size():
		var spot := _sweeps[i]
		var dir := 1.0 if i == 0 else -1.0
		var a := _sweep_angle * dir + i * PI
		var aim := Vector3(center.x + cos(a) * 2.6, 0.0, center.z + sin(a) * 2.0)
		var from := Vector3(center.x + (2.4 if i == 0 else -2.4), 4.4, center.z + 1.6)
		spot.look_at_from_position(from, aim, Vector3.UP)
		spot.light_energy = move_toward(spot.light_energy, 1.2 + 9.0 * drive, delta * 14.0)

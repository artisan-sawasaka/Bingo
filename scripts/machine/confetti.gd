extends Node3D
## Paper confetti: a pooled MultiMesh of small two-sided quads that tumble,
## flutter down and fade. `burst()` pops from a point (number reveal),
## `rain()` drops a shower from above (all numbers drawn).

const MAX_PIECES := 520
const COLORS := [
	Color(1.0, 0.35, 0.7),
	Color(1.0, 0.8, 0.25),
	Color(0.3, 0.85, 1.0),
	Color(0.65, 0.45, 1.0),
	Color(0.35, 0.9, 0.5),
	Color(1.0, 1.0, 1.0),
]

## Pieces stop falling here (the floor around the stage).
var floor_y := 0.02

var _mm: MultiMesh
var _pos := PackedVector3Array()
var _vel := PackedVector3Array()
var _axis := PackedVector3Array()
var _angle := PackedFloat32Array()
var _spin := PackedFloat32Array()
var _life := PackedFloat32Array()
var _phase := PackedFloat32Array()
var _size := PackedFloat32Array()
var _next := 0
var _time := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	var quad := QuadMesh.new()
	quad.size = Vector2(0.06, 0.036)
	var mat := StandardMaterial3D.new()
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.roughness = 0.6
	mat.metallic = 0.2
	# A little self-light so pieces in shadow still read as colorful paper.
	mat.emission_enabled = true
	mat.emission = Color(0.25, 0.22, 0.3)
	mat.emission_energy_multiplier = 0.6
	quad.material = mat
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = quad
	_mm.instance_count = MAX_PIECES
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = _mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.custom_aabb = AABB(Vector3(-30, -5, -30), Vector3(60, 40, 60))
	add_child(mi)
	_pos.resize(MAX_PIECES)
	_vel.resize(MAX_PIECES)
	_axis.resize(MAX_PIECES)
	_angle.resize(MAX_PIECES)
	_spin.resize(MAX_PIECES)
	_life.resize(MAX_PIECES)
	_phase.resize(MAX_PIECES)
	_size.resize(MAX_PIECES)
	var hidden := Transform3D(Basis.IDENTITY * 0.0, Vector3.ZERO)
	for i in MAX_PIECES:
		_life[i] = 0.0
		_mm.set_instance_transform(i, hidden)


func active_pieces() -> int:
	var n := 0
	for i in MAX_PIECES:
		if _life[i] > 0.0:
			n += 1
	return n


func _spawn(pos: Vector3, vel: Vector3, life: float, tint: Color, tint_amount: float) -> void:
	var i := _next
	_next = (_next + 1) % MAX_PIECES
	_pos[i] = pos
	_vel[i] = vel
	var axis := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
	_axis[i] = axis.normalized() if axis.length_squared() > 0.001 else Vector3.RIGHT
	_angle[i] = _rng.randf() * TAU
	_spin[i] = _rng.randf_range(5.0, 14.0) * (1.0 if _rng.randf() < 0.5 else -1.0)
	_life[i] = life
	_phase[i] = _rng.randf() * TAU
	_size[i] = _rng.randf_range(0.8, 1.5)
	var c: Color = COLORS[_rng.randi_range(0, COLORS.size() - 1)]
	_mm.set_instance_color(i, c.lerp(tint, tint_amount).srgb_to_linear())


## Pops `count` pieces up and outward from `origin`. `tint` pulls part of the
## pieces toward one color (the color of the drawn ball).
func burst(origin: Vector3, count: int, speed: float = 3.0, tint: Color = Color.WHITE) -> void:
	for k in count:
		var a := _rng.randf() * TAU
		var out := _rng.randf_range(0.25, 1.0)
		var dir := Vector3(cos(a) * out, _rng.randf_range(0.9, 1.7), sin(a) * out)
		_spawn(origin + dir * 0.03, dir * speed * _rng.randf_range(0.55, 1.0), _rng.randf_range(2.2, 3.6), tint, 0.5 if k % 2 == 0 else 0.0)


## Lets `count` pieces fall from a disc of `radius` at `height` above `center`.
func rain(center: Vector3, radius: float, height: float, count: int) -> void:
	for k in count:
		var a := _rng.randf() * TAU
		var r := sqrt(_rng.randf()) * radius
		var p := center + Vector3(cos(a) * r, height + _rng.randf_range(0.0, 2.5), sin(a) * r)
		_spawn(p, Vector3(_rng.randf_range(-0.3, 0.3), _rng.randf_range(-0.6, 0.0), _rng.randf_range(-0.3, 0.3)), _rng.randf_range(5.0, 8.0), Color.WHITE, 0.0)


func _process(delta: float) -> void:
	_time += delta
	var hidden := Transform3D(Basis.IDENTITY * 0.0, Vector3.ZERO)
	var drag := maxf(0.0, 1.0 - 2.2 * delta)
	for i in MAX_PIECES:
		var life := _life[i]
		if life <= 0.0:
			continue
		life -= delta
		_life[i] = life
		if life <= 0.0:
			_mm.set_instance_transform(i, hidden)
			continue
		var p := _pos[i]
		var v := _vel[i]
		if p.y > floor_y:
			# Paper: strong air drag, slow fall, sideways flutter.
			v.y -= 3.4 * delta
			v.x *= drag
			v.z *= drag
			if v.y < 0.0:
				v.y = maxf(v.y, -1.1)
			else:
				v.y *= maxf(0.0, 1.0 - 1.4 * delta)
			var ph := _phase[i]
			p += (v + Vector3(sin(_time * 3.1 + ph), 0.0, cos(_time * 2.6 + ph * 1.3)) * 0.35) * delta
			_angle[i] += _spin[i] * delta
			if p.y <= floor_y:
				p.y = floor_y
				_life[i] = minf(life, 1.2)  # rests a moment, then fades
		_pos[i] = p
		_vel[i] = v
		var fade := clampf(life / 0.5, 0.0, 1.0)
		_mm.set_instance_transform(i, Transform3D(Basis(_axis[i], _angle[i]) * (_size[i] * fade), p))

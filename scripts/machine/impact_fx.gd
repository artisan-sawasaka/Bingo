extends Node3D
## Small additive light effects, all drawn from two pooled MultiMeshes:
##   * star sparks / flares (camera-facing) — ball hits, the rolling trail, reveals
##   * ripples (flat rings lying on a surface) — hits on the drum glass, landings
## Everything is brighter than the glow threshold, so it blooms a little.

const MAX_STARS := 320
const MAX_RIPPLES := 28

var _star_mm: MultiMesh
var _s_pos := PackedVector3Array()
var _s_vel := PackedVector3Array()
var _s_life := PackedFloat32Array()   # seconds left (<= 0: free)
var _s_span := PackedFloat32Array()   # total life
var _s_size := PackedFloat32Array()   # size at birth (m)
var _s_grow := PackedFloat32Array()   # size factor reached at death
var _s_grav := PackedFloat32Array()
var _s_col: Array[Color] = []
var _s_next := 0

var _ripple_mm: MultiMesh
var _r_xf: Array[Transform3D] = []
var _r_life := PackedFloat32Array()
var _r_span := PackedFloat32Array()
var _r_size := PackedFloat32Array()
var _r_col: Array[Color] = []
var _r_next := 0

var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_star_mm = _make_pool(MAX_STARS, _star_texture(), true)
	_ripple_mm = _make_pool(MAX_RIPPLES, _ring_texture(), false)
	_s_pos.resize(MAX_STARS)
	_s_vel.resize(MAX_STARS)
	_s_life.resize(MAX_STARS)
	_s_span.resize(MAX_STARS)
	_s_size.resize(MAX_STARS)
	_s_grow.resize(MAX_STARS)
	_s_grav.resize(MAX_STARS)
	_s_col.resize(MAX_STARS)
	_r_xf.resize(MAX_RIPPLES)
	_r_life.resize(MAX_RIPPLES)
	_r_span.resize(MAX_RIPPLES)
	_r_size.resize(MAX_RIPPLES)
	_r_col.resize(MAX_RIPPLES)
	var hidden := Transform3D(Basis.IDENTITY * 0.0, Vector3.ZERO)
	for i in MAX_STARS:
		_s_life[i] = 0.0
		_s_col[i] = Color.WHITE
		_star_mm.set_instance_transform(i, hidden)
	for i in MAX_RIPPLES:
		_r_life[i] = 0.0
		_r_col[i] = Color.WHITE
		_r_xf[i] = Transform3D.IDENTITY
		_ripple_mm.set_instance_transform(i, hidden)


func _make_pool(capacity: int, tex: Texture2D, billboard: bool) -> MultiMesh:
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.vertex_color_use_as_albedo = true
	mat.albedo_texture = tex
	mat.albedo_color = Color(1.7, 1.7, 1.7)  # HDR: above the glow threshold
	mat.disable_receive_shadows = true
	if billboard:
		mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
		mat.billboard_keep_scale = true
	quad.material = mat
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = quad
	mm.instance_count = capacity
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Particles fly anywhere around the machine: never cull the pool as a whole.
	mi.custom_aabb = AABB(Vector3(-30, -5, -30), Vector3(60, 40, 60))
	add_child(mi)
	return mm


## Soft core with a thin 4-point streak.
static func _star_texture() -> ImageTexture:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var u := (x + 0.5) / size * 2.0 - 1.0
			var v := (y + 0.5) / size * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var glow := exp(-r * r * 10.0)
			var streak := exp(-absf(v) * 26.0) * exp(-absf(u) * 2.8) + exp(-absf(u) * 26.0) * exp(-absf(v) * 2.8)
			var a := clampf(glow + streak * 0.75, 0.0, 1.0) * smoothstep(1.0, 0.75, r)
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


static func _ring_texture() -> ImageTexture:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var u := (x + 0.5) / size * 2.0 - 1.0
			var v := (y + 0.5) / size * 2.0 - 1.0
			var r := sqrt(u * u + v * v)
			var band := exp(-pow((r - 0.8) / 0.075, 2.0))
			var haze := exp(-pow((r - 0.55) / 0.3, 2.0)) * 0.18
			img.set_pixel(x, y, Color(1, 1, 1, clampf(band + haze, 0.0, 1.0) * smoothstep(1.0, 0.94, r)))
	return ImageTexture.create_from_image(img)


func active_stars() -> int:
	var n := 0
	for i in MAX_STARS:
		if _s_life[i] > 0.0:
			n += 1
	return n


func active_ripples() -> int:
	var n := 0
	for i in MAX_RIPPLES:
		if _r_life[i] > 0.0:
			n += 1
	return n


func _add_star(pos: Vector3, vel: Vector3, color: Color, size: float, life: float, grow: float, gravity: float) -> void:
	var i := _s_next
	_s_next = (_s_next + 1) % MAX_STARS
	_s_pos[i] = pos
	_s_vel[i] = vel
	_s_col[i] = color
	_s_size[i] = size
	_s_span[i] = life
	_s_life[i] = life
	_s_grow[i] = grow
	_s_grav[i] = gravity


## A hit: one quick flare at the contact point plus a few flying sparks.
## strength 0..1 (how hard), `normal` = direction of the hit.
func hit(pos: Vector3, normal: Vector3, color: Color, strength: float) -> void:
	var s := clampf(strength, 0.0, 1.0)
	_add_star(pos, Vector3.ZERO, color.lerp(Color.WHITE, 0.45), 0.1 + 0.12 * s, 0.13 + 0.07 * s, 1.8, 0.0)
	var count := 2 + int(round(4.0 * s))
	for k in count:
		var dir := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
		# Sparks leave sideways from the line of the hit.
		dir -= normal * dir.dot(normal) * 0.8
		if dir.length_squared() < 0.0001:
			dir = Vector3.UP
		var speed := _rng.randf_range(0.5, 1.3) * (0.6 + s)
		_add_star(pos, dir.normalized() * speed, color.lerp(Color(1.0, 0.95, 0.75), 0.4), _rng.randf_range(0.035, 0.065), _rng.randf_range(0.22, 0.42), 0.25, 2.5)


## A ring spreading on a surface whose outward direction is `normal`.
func ripple(pos: Vector3, normal: Vector3, color: Color, size: float, life: float = 0.4) -> void:
	var n := normal.normalized() if normal.length_squared() > 0.0001 else Vector3.UP
	var x := n.cross(Vector3.UP)
	if x.length_squared() < 0.0001:
		x = n.cross(Vector3.RIGHT)
	x = x.normalized()
	var i := _r_next
	_r_next = (_r_next + 1) % MAX_RIPPLES
	_r_xf[i] = Transform3D(Basis(x, n.cross(x).normalized(), n), pos)
	_r_col[i] = color
	_r_size[i] = size
	_r_span[i] = life
	_r_life[i] = life


## One soft glowing dot that stays where it was born (rolling-ball trail).
func puff(pos: Vector3, color: Color, size: float, life: float = 0.35) -> void:
	_add_star(pos, Vector3(0, 0.05, 0), color, size, life, 0.3, 0.0)


## Big celebratory burst (number reveal): flare + a ring of sparks.
func burst(pos: Vector3, color: Color, count: int = 22, speed: float = 2.2) -> void:
	_add_star(pos, Vector3.ZERO, color.lerp(Color.WHITE, 0.6), 0.5, 0.3, 2.6, 0.0)
	for k in count:
		var a := TAU * (float(k) + _rng.randf()) / count
		var dir := Vector3(cos(a), _rng.randf_range(0.35, 1.2), sin(a)).normalized()
		var c := color.lerp(Color(1.0, 0.92, 0.6), _rng.randf_range(0.2, 0.7))
		_add_star(pos, dir * speed * _rng.randf_range(0.6, 1.1), c, _rng.randf_range(0.05, 0.1), _rng.randf_range(0.45, 0.85), 0.2, 4.0)


func _process(delta: float) -> void:
	var hidden := Transform3D(Basis.IDENTITY * 0.0, Vector3.ZERO)
	for i in MAX_STARS:
		var life := _s_life[i]
		if life <= 0.0:
			continue
		life -= delta
		_s_life[i] = life
		if life <= 0.0:
			_star_mm.set_instance_transform(i, hidden)
			continue
		var v := _s_vel[i]
		v.y -= _s_grav[i] * delta
		v *= maxf(0.0, 1.0 - 1.6 * delta)
		_s_vel[i] = v
		var p := _s_pos[i] + v * delta
		_s_pos[i] = p
		var u := 1.0 - life / _s_span[i]   # 0 at birth -> 1 at death
		var size := _s_size[i] * lerpf(1.0, _s_grow[i], u)
		_star_mm.set_instance_transform(i, Transform3D(Basis.IDENTITY * size, p))
		var c := _s_col[i]
		c.a = (1.0 - u) * (1.0 - u)
		_star_mm.set_instance_color(i, c)
	for i in MAX_RIPPLES:
		var life := _r_life[i]
		if life <= 0.0:
			continue
		life -= delta
		_r_life[i] = life
		if life <= 0.0:
			_ripple_mm.set_instance_transform(i, hidden)
			continue
		var u := 1.0 - life / _r_span[i]
		var xf := _r_xf[i]
		var size := _r_size[i] * (0.25 + 0.75 * (1.0 - (1.0 - u) * (1.0 - u)))
		_ripple_mm.set_instance_transform(i, Transform3D(xf.basis * size, xf.origin))
		var c := _r_col[i]
		c.a = (1.0 - u) * 0.9
		_ripple_mm.set_instance_color(i, c)

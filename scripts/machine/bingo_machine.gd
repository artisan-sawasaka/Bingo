extends Node3D
## 3D drawing machine presenter. It NEVER decides numbers: `play_draw(number)`
## visualizes a result that GameController already decided and saved.
##
## What is on stage always mirrors the game:
##   * drum  – one numbered ball per number that is still left (DrumSim keeps
##             them moving; hard hits throw sparks)
##   * tray  – the ball drawn last
##   * ring  – every ball drawn before, resting on the stage rim. When the next
##             draw starts, the tray ball hops to the front of the ring and the
##             older ones roll one place clockwise (BallRing).
## The drawn ball itself follows a scripted path (drum -> exit -> chute -> tray).

const PrimitiveMachine = preload("res://scripts/machine/primitive_machine.gd")
const BallColors = preload("res://scripts/util/ball_colors.gd")
const BallVisuals = preload("res://scripts/machine/ball_visuals.gd")
const DrumSim = preload("res://scripts/machine/drum_sim.gd")
const BallRing = preload("res://scripts/machine/ball_ring.gd")
const ImpactFx = preload("res://scripts/machine/impact_fx.gd")
const Confetti = preload("res://scripts/machine/confetti.gd")
const StageLights = preload("res://scripts/machine/stage_lights.gd")
const PartySkyShader = preload("res://shaders/party_sky.gdshader")
const StageFloorShader = preload("res://shaders/stage_floor.gdshader")
const Backdrop = preload("res://scripts/machine/backdrop.gd")

const MODEL_PATH := "res://assets/models/bingo_machine.glb"
const BALL_MODEL_PATH := "res://assets/models/bingo_ball.glb"
const IDLE_SPIN := 0.25
const MAX_SPIN := 9.0
## How hard the air blower stirs the balls while nothing is being drawn (1 = draw).
## 0: the balls rest in a pile and only roll a little with the slowly turning
## drum; they jump around only while a number is being drawn.
const IDLE_AGITATION := 0.0
## The ball in the tray is shown a little larger than the ones in the drum.
const TRAY_SCALE := 1.15
const RING_SHIFT_SEC := 0.6
## Render layer of the floor (lights can leave it out through their cull mask).
const FLOOR_LAYER := 2
const MAX_HITS_PER_FRAME := 4
const MAX_WALL_HITS_PER_FRAME := 2

## stage: "start" | "spin" | "eject" | "land" | "reveal" | "done"
signal stage_reached(stage: String, number: int)

var camera: Camera3D
var model: Node3D
var drum: Node3D
var drum_center := Vector3.ZERO
## Usable radius for the center of a standard (BALL_RADIUS) ball — model contract.
var inner_radius := 0.6
## Radius of the balls in this game (smaller when there are hundreds of them).
var ball_radius: float = PrimitiveMachine.BALL_RADIUS
var exit_marker: Node3D
var tray_marker: Node3D
var chute_points: Array[Vector3] = []
var camera_target := Vector3(0.06, 0.94, 0.4)
var using_glb := false

var max_number := 75
var visuals: BallVisuals
var sim: DrumSim
var ring: BallRing
var fx: ImpactFx
var confetti: Confetti
var stage_lights: StageLights

var _drum_mmi: MultiMeshInstance3D
var _ring_mmi: MultiMeshInstance3D
var _flashing := {}          # drum ball index -> true while its hit glow fades
var _tray_ball: Node3D = null
var _tray_flash := 0.0
var _flying: Dictionary = {}
var _omega := IDLE_SPIN
var _timeline := -1.0
var _timing := {}
var _fired := {}
var _number := 0
var _variant := 0
var _last_variant := -1
var _rng := RandomNumberGenerator.new()
var _flash: OmniLight3D
var _spin_light: SpotLight3D
var _font: SystemFont
var _exit_dir := Vector3(0, -0.65, 0.76).normalized()
var _trail_left := 0.0
# ring animation
var _ring_t := -1.0          # seconds into the shift, -1 = at rest
var _ring_dirty := true
var _ring_from := Vector3.ZERO
var _ring_from_r := 0.085
var _ring_leaving := 0       # number rolling off the end of a full lap
var _ring_has_entry := false
# party backdrop
var _sky_mat: ShaderMaterial
var _floor_mat: ShaderMaterial
var _env: Environment
## Curtain, out-of-focus party lights and light shafts behind the machine.
var backdrop: Backdrop
## Floor reflections + contact shadows (screen-space; can be switched off on slow PCs).
var effects_high := true
var _energy := 1.0
var _reveal_pulse := 0.0
var _drive := 0.0            # 0 idle .. 1 drum at full speed

# camera framing (set by UI layout)
var _view_rect := Rect2(0, 0, 1, 1)  # normalized rect of the screen where the machine should appear
var _cam_dist := 5.5
var _cam_yaw := 0.0
var _cam_push := 0.0
var _cam_punch := 0.0
var _cam_rest := Vector3(0.2, 2.2, 7.0)


func _ready() -> void:
	_rng.randomize()
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["Arial Black", "Segoe UI Black", "Arial", "Yu Gothic UI"])
	_font.font_weight = 900
	_build_environment()
	_load_model()
	visuals = BallVisuals.new()
	if ResourceLoader.exists(BALL_MODEL_PATH):
		var ball_scene = load(BALL_MODEL_PATH)
		if ball_scene is PackedScene:
			visuals.use_scene_mesh(ball_scene)
	add_child(visuals.make_digit_viewport(_font))
	sim = DrumSim.new()
	_drum_mmi = visuals.make_instance_node(1, "DrumBalls")
	add_child(_drum_mmi)
	_ring_mmi = visuals.make_instance_node(1, "RingBalls")
	add_child(_ring_mmi)
	fx = ImpactFx.new()
	fx.name = "ImpactFx"
	add_child(fx)
	confetti = Confetti.new()
	confetti.name = "Confetti"
	add_child(confetti)
	camera = Camera3D.new()
	camera.fov = 38.0
	camera.near = 0.05
	camera.far = 60.0
	add_child(camera)
	camera.current = true
	# Before a game exists the drum shows a standard 75-ball set.
	var all: Array = []
	for n in range(1, 76):
		all.append(n)
	set_state(75, all, [])


# ---------------------------------------------------------------- setup

func _build_environment() -> void:
	# The sky is hidden behind the curtain; it colors the reflections on the
	# gold / chrome parts and the glossy floor. Static, so it is baked once.
	_sky_mat = ShaderMaterial.new()
	_sky_mat.shader = PartySkyShader
	var sky := Sky.new()
	sky.sky_material = _sky_mat
	sky.radiance_size = Sky.RADIANCE_SIZE_128
	sky.process_mode = Sky.PROCESS_MODE_QUALITY
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.34, 0.52)
	env.ambient_light_energy = 0.55
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY  # metals reflect the party colors
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	env.glow_intensity = 0.6
	env.glow_bloom = 0.04
	env.glow_hdr_threshold = 1.2
	# A light haze: things further back lose a little contrast (depth), nothing more.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.11, 0.045, 0.15)
	env.fog_light_energy = 1.0
	env.fog_density = 0.55
	env.fog_depth_begin = 10.0
	env.fog_depth_end = 26.0
	env.fog_sky_affect = 0.0
	# Screen-space extras (switchable, see set_effects_quality): the glossy
	# floor mirrors the curtain lights and the stage; soft contact shadows.
	env.ssr_max_steps = 96
	env.ssr_fade_in = 0.2
	env.ssr_fade_out = 2.5
	env.ssr_depth_tolerance = 0.4
	env.ssao_radius = 0.35
	env.ssao_intensity = 1.3
	env.ssao_power = 1.4
	_env = env
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	backdrop = Backdrop.new()
	backdrop.name = "Backdrop"
	add_child(backdrop)
	set_effects_quality(true)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-48, -28, 0)
	key.light_energy = 1.25
	key.light_color = Color(1.0, 0.96, 0.9)
	key.shadow_enabled = true
	# The whole scene is within a few meters: keep the shadow map for that range
	# (the default 100 m made the shadows between the balls blotchy).
	key.directional_shadow_max_distance = 16.0
	add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-20, 150, 0)
	rim.light_energy = 0.7
	rim.light_color = Color(0.45, 0.6, 1.0)
	# The rim light shines toward the camera: on the polished floor it would be
	# a large blue glare, so the floor (render layer 2) is left out of it.
	rim.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER
	add_child(rim)

	_spin_light = SpotLight3D.new()
	_spin_light.spot_angle = 28.0
	_spin_light.light_energy = 0.0
	_spin_light.light_color = Color(1.0, 0.8, 0.4)
	_spin_light.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER  # no glare on the polished floor
	add_child(_spin_light)
	_spin_light.look_at_from_position(Vector3(0, 3.6, 1.6), Vector3(0, 1.4, 0))

	_flash = OmniLight3D.new()
	_flash.omni_range = 2.2
	_flash.light_energy = 0.0
	_flash.light_cull_mask = 0xFFFFF & ~FLOOR_LAYER
	add_child(_flash)

	# floor (polished; reaches the curtain all around)
	var floor := MeshInstance3D.new()
	floor.name = "Floor"
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	floor.mesh = pm
	floor.layers = FLOOR_LAYER
	floor.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_floor_mat = ShaderMaterial.new()
	_floor_mat.shader = StageFloorShader
	floor.material_override = _floor_mat
	add_child(floor)


func _load_model() -> void:
	model = null
	if ResourceLoader.exists(MODEL_PATH):
		var scene = load(MODEL_PATH)
		if scene is PackedScene:
			var inst: Node3D = scene.instantiate()
			if _validate_contract(inst):
				model = inst
				using_glb = true
			else:
				push_warning("bingo_machine.glb does not satisfy docs/model-contract.md; using primitives")
				inst.free()
	if model == null:
		model = PrimitiveMachine.build()
	add_child(model)
	drum = model.find_child("Drum", true, false)
	var interior: Node3D = model.find_child("DrumInterior", true, false)
	drum_center = interior.global_position if interior.is_inside_tree() else interior.position
	inner_radius = absf(interior.global_transform.basis.get_scale().x)
	exit_marker = model.find_child("ExitMarker", true, false)
	tray_marker = model.find_child("TrayMarker", true, false)
	chute_points.clear()
	var i := 1
	while true:
		var cp: Node3D = model.find_child("ChutePoint_%d" % i, true, false)
		if cp == null:
			break
		chute_points.append(cp.global_position)
		i += 1
	var ct: Node3D = model.find_child("CameraTarget", true, false)
	if ct != null:
		camera_target = ct.global_position
	var out := exit_marker.global_position - drum_center
	if out.length_squared() > 0.0001:
		_exit_dir = out.normalized()
	_flash.position = tray_marker.global_position + Vector3(0, 0.35, 0.25)
	# Lap of the drawn balls: optional marker, else the rim of the default stage.
	ring = BallRing.new()
	var rm: Node3D = model.find_child("BallRing", true, false)
	if rm != null:
		ring.center = rm.global_position
		ring.radius = maxf(0.3, absf(rm.global_transform.basis.get_scale().x))
	else:
		ring.center = PrimitiveMachine.STAGE_CENTER + Vector3(0, PrimitiveMachine.STAGE_TOP, 0)
		ring.radius = PrimitiveMachine.RING_RADIUS
	stage_lights = StageLights.new()
	stage_lights.name = "StageLights"
	stage_lights.center = Vector3(ring.center.x, ring.center.y * 0.5, ring.center.z)
	stage_lights.radius = ring.radius + 0.19
	# The marquee row belongs to the built-in stage; a custom model brings its own look.
	stage_lights.bulb_count = 0 if using_glb else 48
	add_child(stage_lights)


static func _validate_contract(inst: Node) -> bool:
	for n in ["Drum", "DrumInterior", "ExitMarker", "TrayMarker", "ChutePoint_1"]:
		if inst.find_child(n, true, false) == null:
			push_warning("model contract: missing node '%s'" % n)
			return false
	return true


# ---------------------------------------------------------------- public API

## Shows a game exactly as it is, without animation:
## `remaining` = numbers still in the drum, `drawn` = draw order (the last one
## sits in the tray, the earlier ones on the ring).
func set_state(p_max: int, remaining: Array, drawn: Array) -> void:
	_timeline = -1.0
	_fired = {}
	_omega = IDLE_SPIN
	_spin_light.light_energy = 0.0
	if not _flying.is_empty():
		var old: Node3D = _flying.node
		old.queue_free()
		_flying = {}
	max_number = maxi(1, p_max)
	var wall := inner_radius + PrimitiveMachine.BALL_RADIUS
	var r: float = DrumSim.ball_radius_for(max_number, wall, PrimitiveMachine.BALL_RADIUS)
	ball_radius = r
	sim.setup(remaining, wall - ball_radius, ball_radius)
	sim.agitation = IDLE_AGITATION
	sim.omega = _omega
	_rebuild_drum()
	# ring + tray
	ring.configure(max_number, ball_radius)
	var retired: Array = drawn.duplicate()
	var last := 0
	if not retired.is_empty():
		last = int(retired.pop_back())
	ring.set_from_draw_order(retired)
	_ring_t = -1.0
	_ring_leaving = 0
	_ring_has_entry = false
	_rebuild_ring()
	_clear_tray()
	if last > 0:
		_tray_ball = visuals.make_single(last, max_number, ball_radius)
		add_child(_tray_ball)
		_tray_ball.global_position = _tray_rest_position()
		_tray_ball.scale = Vector3.ONE * TRAY_SCALE
		_face_camera(_tray_ball, 1.0)


## Plays the draw sequence. timing = { start, spin_end, eject_end, reveal_end } (seconds).
func play_draw(number: int, timing: Dictionary) -> void:
	if not _flying.is_empty():
		_land()  # the previous animation was cut short (watchdog): finish it now
	_number = number
	_timing = timing
	_timeline = 0.0
	_fired = {}
	var choices := [0, 1, 2]
	choices.erase(_last_variant)
	_variant = choices[_rng.randi_range(0, choices.size() - 1)]
	_last_variant = _variant
	_spin_light.light_color = Color.from_hsv(_rng.randf(), 0.45, 1.0)
	_retire_tray_ball()


func is_playing() -> bool:
	return _timeline >= 0.0


## Normalized screen rect (0..1) where the machine should be framed.
func set_view_rect(r: Rect2) -> void:
	_view_rect = r
	# The curtain keeps a calm, dark area where the drum is (a little above the middle).
	if backdrop != null:
		backdrop.set_focus(r.position + r.size * Vector2(0.5, 0.4))


## true: the floor mirrors the stage and the curtain lights, and small contact
## shadows are added (screen-space effects). false: skip them — the picture is
## a bit plainer but cheaper to draw on weak graphics hardware.
func set_effects_quality(high: bool) -> void:
	effects_high = high
	if _env != null:
		_env.ssr_enabled = high
		_env.ssao_enabled = high


## Confetti shower for "every number has been drawn".
func celebrate() -> void:
	confetti.rain(Vector3(ring.center.x, 0.0, ring.center.z), ring.radius + 0.6, 3.2, 360)
	stage_lights.flash(Color(1.0, 0.85, 0.4))
	_reveal_pulse = 1.0


## Numbers currently shown inside the drum / on the ring (newest first) / in the tray.
func drum_numbers() -> Array[int]:
	return sim.numbers()


func ring_numbers() -> Array[int]:
	return ring.numbers.duplicate()


func tray_number() -> int:
	if not _flying.is_empty():
		return _number
	return int(_tray_ball.get_meta("number", 0)) if _tray_ball != null else 0


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	visuals.poll_bake()
	if _timeline >= 0.0:
		_advance_timeline(delta)
	else:
		_omega = move_toward(_omega, IDLE_SPIN, delta * 6.0)
		_drive = move_toward(_drive, 0.0, delta * 2.5)
		_cam_push = move_toward(_cam_push, 0.0, delta * 0.5)
		_cam_yaw = move_toward(_cam_yaw, 0.0, delta * 0.2)
	if drum != null:
		drum.rotate_object_local(Vector3.RIGHT, _omega * delta)
	sim.omega = _omega
	sim.agitation = lerpf(IDLE_AGITATION, 1.0, _drive)
	sim.step(delta)
	_show_impacts()
	_sync_drum(delta)
	_update_camera()
	_update_ring(delta)
	# Keep the printed number of the ball in the tray turned toward the camera.
	if _tray_ball != null and _flying.is_empty():
		_face_camera(_tray_ball, delta * 14.0)
		if _tray_flash > 0.0:
			_tray_flash = move_toward(_tray_flash, 0.0, delta * 2.2)
			var body: MultiMeshInstance3D = _tray_ball.get_node("Body")
			BallVisuals.set_flash(body.multimesh, 0, int(_tray_ball.get_meta("number", 0)), _tray_flash)
	_flash.light_energy = move_toward(_flash.light_energy, 0.0, delta * 6.0)
	_cam_punch = move_toward(_cam_punch, 0.0, delta * 3.5)
	_update_party(delta)


## Backdrop "excitement": a bit livelier while spinning, a short burst on reveal.
func _update_party(delta: float) -> void:
	var spinning := _timeline >= 0.0 and not _fired.has("reveal")
	var target := 1.4 if spinning else 1.0
	_energy = move_toward(_energy, target, delta * 1.5)
	_reveal_pulse = move_toward(_reveal_pulse, 0.0, delta * 0.7)
	var e := _energy + _reveal_pulse * 0.9
	if _floor_mat != null:
		_floor_mat.set_shader_parameter("energy", e)
	if backdrop != null:
		backdrop.energy = e
	if stage_lights != null:
		stage_lights.drive = _drive


func _advance_timeline(delta: float) -> void:
	_timeline += delta
	var t := _timeline
	var t_start: float = _timing.get("start", 0.2)
	var t_spin: float = _timing.get("spin_end", 1.4)
	var t_eject: float = _timing.get("eject_end", 1.85)
	var t_reveal: float = _timing.get("reveal_end", 2.4)
	_fire_once("start", 0.0)
	# drum speed profile
	if t < t_spin:
		var u := clampf((t - 0.0) / maxf(0.01, t_spin), 0.0, 1.0)
		var ramp := smoothstep(0.0, 0.3, u) * (1.0 - smoothstep(0.75, 1.0, u) * 0.85)
		_omega = lerpf(IDLE_SPIN, MAX_SPIN, ramp)
		_drive = ramp
		_spin_light.light_energy = 3.6 * ramp
		# Shortly before the exit opens, the drawn ball is pulled to it.
		if t >= t_spin - minf(0.55, t_spin * 0.42) and not _fired.has("steer"):
			_fired["steer"] = true
			sim.steer(sim.index_of(_number), _exit_dir * sim.radius)
	else:
		_omega = move_toward(_omega, IDLE_SPIN, delta * 10.0)
		_drive = move_toward(_drive, 0.0, delta * 2.5)
		_spin_light.light_energy = move_toward(_spin_light.light_energy, 0.0, delta * 10.0)
	if t >= t_start:
		_fire_once("spin", t_start)
	if t >= t_spin and not _fired.has("eject"):
		_fire_once("eject", t_spin)
		_begin_eject()
	if not _flying.is_empty():
		_update_flying(t, t_spin, t_eject, delta)
	if t >= t_eject and not _fired.has("land"):
		_fire_once("land", t_eject)
		_land()
	if t >= t_eject + (t_reveal - t_eject) * 0.15 and not _fired.has("reveal"):
		_fire_once("reveal", t_eject)
		_reveal()
	# camera variants
	var spin_u := clampf(t / maxf(0.01, t_spin), 0.0, 1.0)
	match _variant:
		0:
			_cam_push = lerpf(0.0, 0.06, spin_u)
		1:
			_cam_push = lerpf(0.0, 0.16, smoothstep(0.0, 1.0, spin_u))
		2:
			_cam_yaw = sin(spin_u * PI) * 0.12
			_cam_push = 0.08 * spin_u
	if t >= t_reveal:
		_timeline = -1.0
		_fire_once("done", t_reveal)


func _fire_once(stage: String, _at: float) -> void:
	if _fired.has(stage):
		return
	_fired[stage] = true
	stage_reached.emit(stage, _number)


# ---------------------------------------------------------------- balls in the drum

## Colors / numbers of every drum instance (after the set of balls changed).
func _rebuild_drum() -> void:
	var mm := _drum_mmi.multimesh
	var n := sim.count()
	if mm.instance_count < n or mm.instance_count > maxi(1, n) * 2 + 8:
		mm.instance_count = maxi(1, n)
	for i in n:
		sim.flash[i] = 0.0
		BallVisuals.paint(mm, i, sim.num[i], max_number)
	_flashing.clear()
	mm.visible_instance_count = n
	_sync_drum(0.0)


func _sync_drum(delta: float) -> void:
	var mm := _drum_mmi.multimesh
	var n := sim.count()
	var k := ball_radius / visuals.mesh_radius
	for i in n:
		mm.set_instance_transform(i, Transform3D(Basis(sim.rot[i]) * k, drum_center + sim.pos[i]))
	if _flashing.is_empty():
		return
	for key in _flashing.keys():
		var i: int = key
		if i >= n:
			_flashing.erase(key)
			continue
		var f := maxf(0.0, sim.flash[i] - delta * 3.8)
		sim.flash[i] = f
		BallVisuals.set_flash(mm, i, sim.num[i], f)
		if f <= 0.0:
			_flashing.erase(key)


func _flash_ball(i: int, amount: float) -> void:
	if i < 0 or i >= sim.count():
		return
	sim.flash[i] = maxf(sim.flash[i], amount)
	_flashing[i] = true


## Sparks where balls hit each other, a ripple where one hits the glass.
func _show_impacts() -> void:
	if sim.impacts.is_empty():
		return
	var shown := 0
	var walls := 0
	for hit in sim.impacts:
		if shown >= MAX_HITS_PER_FRAME:
			break
		var speed: float = hit.speed
		var a: int = hit.a
		var b: int = hit.b
		var point: Vector3 = hit.point
		var normal: Vector3 = hit.normal
		var strength := clampf((speed - sim.impact_speed) / 3.0, 0.0, 1.0)
		# At full spin dozens of balls are hit at once: glow less so the drum does not wash out.
		var glow := 1.0 - 0.45 * _drive
		var col: Color = BallColors.color_for(sim.num[a], max_number)
		if b >= 0:
			var other: Color = BallColors.color_for(sim.num[b], max_number)
			fx.hit(drum_center + point, normal, col.lerp(other, 0.5).lightened(0.25), strength)
			_flash_ball(a, (0.35 + 0.45 * strength) * glow)
			_flash_ball(b, (0.35 + 0.45 * strength) * glow)
			shown += 1
		elif walls < MAX_WALL_HITS_PER_FRAME and speed > sim.impact_speed * 1.5:
			fx.ripple(drum_center + point, normal, col.lightened(0.45), ball_radius * (2.6 + 2.4 * strength), 0.36)
			_flash_ball(a, (0.3 + 0.4 * strength) * glow)
			walls += 1
			shown += 1


func _tray_rest_position() -> Vector3:
	# TrayMarker is the center of a standard ball; other sizes rest on the same pad.
	return tray_marker.global_position + Vector3(0, ball_radius * TRAY_SCALE - PrimitiveMachine.BALL_RADIUS, 0)


## Rotation that turns the printed number (local +Z) toward `eye`, upright.
static func _facing(from: Vector3, eye: Vector3) -> Basis:
	var to := eye - from
	if to.length_squared() < 0.000001:
		return Basis.IDENTITY
	return Basis.looking_at(to.normalized(), Vector3.UP, true)


func _face_camera(ball: Node3D, weight: float) -> void:
	var body: Node3D = ball.get_node_or_null("Body")
	if body == null or camera == null:
		return
	var target := Quaternion(_facing(ball.global_position, camera.global_position))
	var cur := Quaternion(body.basis.orthonormalized())
	body.basis = Basis(cur.slerp(target, clampf(weight, 0.0, 1.0)))


func _begin_eject() -> void:
	# The ball that carries the drawn number leaves the drum.
	var start_pos := drum_center + _exit_dir * sim.radius
	var start_rot := Quaternion.IDENTITY
	var idx := sim.index_of(_number)
	sim.steer(-1)
	if idx >= 0:
		var taken := sim.remove_at(idx)
		var p: Vector3 = taken.pos
		var q: Quaternion = taken.rot
		start_pos = drum_center + p
		start_rot = q
		_rebuild_drum()
	var ball := visuals.make_single(_number, max_number, ball_radius)
	add_child(ball)
	ball.global_position = start_pos
	var body: Node3D = ball.get_node("Body")
	body.basis = Basis(start_rot)
	var drop := Vector3(0, ball_radius - PrimitiveMachine.BALL_RADIUS, 0)
	var path: Array[Vector3] = [start_pos, exit_marker.global_position + drop]
	for cp in chute_points:
		path.append(cp + drop)
	path.append(_tray_rest_position())
	var lengths: Array[float] = [0.0]
	for i in range(1, path.size()):
		lengths.append(lengths[i - 1] + path[i].distance_to(path[i - 1]))
	_flying = {"node": ball, "path": path, "lengths": lengths}
	_trail_left = 0.0
	var col: Color = BallColors.color_for(_number, max_number)
	fx.ripple(exit_marker.global_position, _exit_dir, col.lightened(0.4), 0.5, 0.35)


func _update_flying(t: float, t0: float, t1: float, delta: float) -> void:
	var u := clampf((t - t0) / maxf(0.01, t1 - t0), 0.0, 1.0)
	var e := u * u * (1.6 - 0.6 * u)  # accelerating like rolling downhill
	var lengths: Array[float] = _flying.lengths
	var total: float = lengths[lengths.size() - 1]
	var s := e * total
	var path: Array[Vector3] = _flying.path
	var pos: Vector3 = path[path.size() - 1]
	for i in range(1, path.size()):
		if s <= lengths[i]:
			var seg := lengths[i] - lengths[i - 1]
			var k := (s - lengths[i - 1]) / maxf(0.0001, seg)
			pos = path[i - 1].lerp(path[i], k)
			break
	var node: Node3D = _flying.node
	var prev := node.global_position
	node.global_position = pos
	var body := node.get_node_or_null("Body")
	if body != null:
		var mv := pos - prev
		if mv.length() > 0.0001:
			var axis := mv.cross(Vector3.UP).normalized()
			if axis.length() > 0.5:
				body.rotate(axis, -mv.length() / ball_radius)
	# Glowing trail behind the rolling ball.
	_trail_left -= delta
	if _trail_left <= 0.0:
		_trail_left = 0.028
		var col: Color = BallColors.color_for(_number, max_number)
		fx.puff(pos, col.lightened(0.35), ball_radius * 1.7, 0.32)


func _land() -> void:
	if _flying.is_empty():
		return
	var node: Node3D = _flying.node
	node.global_position = _tray_rest_position()
	_tray_ball = node
	_flying = {}
	var tw := node.create_tween()
	tw.tween_property(node, "position:y", node.position.y + ball_radius * 0.6, 0.09).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(node, "position:y", node.position.y, 0.12).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BOUNCE)
	var col: Color = BallColors.color_for(_number, max_number)
	fx.ripple(tray_marker.global_position - Vector3(0, PrimitiveMachine.BALL_RADIUS - 0.012, 0), Vector3.UP, col.lightened(0.4), 0.55, 0.3)


func _reveal() -> void:
	if _tray_ball == null:
		return
	_face_camera(_tray_ball, 1.0)  # the printed number turns to the audience
	_tray_ball.scale = Vector3.ONE * 0.8
	var tw := _tray_ball.create_tween()
	tw.tween_property(_tray_ball, "scale", Vector3.ONE * (TRAY_SCALE + 0.2), 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_tray_ball, "scale", Vector3.ONE * TRAY_SCALE, 0.2)
	var col: Color = BallColors.color_for(_number, max_number)
	var at := tray_marker.global_position
	_flash.light_color = col.lightened(0.3)
	_flash.light_energy = 2.6
	_tray_flash = 1.0
	_reveal_pulse = 1.0
	_cam_punch = 1.0
	fx.burst(at + Vector3(0, 0.05, 0), col.lightened(0.2), 24, 2.3)
	fx.ripple(at - Vector3(0, PrimitiveMachine.BALL_RADIUS - 0.014, 0), Vector3.UP, col.lightened(0.5), 1.25, 0.55)
	confetti.burst(at + Vector3(0, 0.12, 0), 70, 3.1, col.lightened(0.15))
	stage_lights.flash(col)


func _clear_tray() -> void:
	if _tray_ball == null:
		return
	_tray_ball.queue_free()
	_tray_ball = null
	_tray_flash = 0.0


# ---------------------------------------------------------------- ring of drawn balls

## The ball in the tray retires: it hops to the head of the ring while every
## older ball rolls one place clockwise.
func _retire_tray_ball() -> void:
	if _tray_ball == null:
		return
	var number := int(_tray_ball.get_meta("number", 0))
	_ring_from = _tray_ball.global_position
	_ring_from_r = ball_radius * _tray_ball.scale.x
	_clear_tray()
	if number <= 0:
		return
	_ring_leaving = ring.push(number)
	_ring_has_entry = true
	_ring_t = 0.0
	_rebuild_ring()


func _rebuild_ring() -> void:
	var mm := _ring_mmi.multimesh
	var need := ring.capacity + 1
	if mm.instance_count != need:
		mm.instance_count = need
	var count := ring.numbers.size()
	for k in count:
		BallVisuals.paint(mm, k, ring.numbers[k], max_number)
	if _ring_leaving > 0:
		BallVisuals.paint(mm, count, _ring_leaving, max_number)
	mm.visible_instance_count = count
	_ring_dirty = true
	_update_ring(0.0)


func _update_ring(delta: float) -> void:
	if _ring_t < 0.0 and not _ring_dirty:
		return
	var mm := _ring_mmi.multimesh
	var count := ring.numbers.size()
	var e := 1.0
	if _ring_t >= 0.0:
		_ring_t += delta
		var u := clampf(_ring_t / RING_SHIFT_SEC, 0.0, 1.0)
		e = u * u * (3.0 - 2.0 * u)
		if u >= 1.0:
			_ring_t = -1.0
			_ring_leaving = 0
			_ring_has_entry = false
			e = 1.0
	var k_scale := ring.ball_r / visuals.mesh_radius
	var moving := e < 1.0
	for k in count:
		var pos: Vector3
		var scl := k_scale
		var roll := 0.0
		var slot := float(k)
		if moving:
			if k == 0 and _ring_has_entry:
				# Hop from the tray down to the head of the lap.
				pos = _ring_from.lerp(ring.slot_position(0.0), e)
				pos.y += sin(e * PI) * 0.3
				scl = lerpf(_ring_from_r, ring.ball_r, e) / visuals.mesh_radius
				roll = (1.0 - e) * TAU
			else:
				slot = float(k) - 1.0 + e
				pos = ring.slot_position(slot)
				roll = e * TAU
		else:
			pos = ring.slot_position(slot)
		var face := _facing(pos, _cam_rest)
		if roll != 0.0:
			# Rolling along the lap: spin around the axis across the direction of travel.
			face = Basis(Vector3.UP.cross(ring.slot_tangent(slot)).normalized(), roll) * face
		mm.set_instance_transform(k, Transform3D(face * scl, pos))
	if moving and _ring_leaving > 0:
		# The oldest ball of a full lap rolls on and shrinks away.
		var tail := ring.slot_position(float(count) - 1.0 + e)
		mm.set_instance_transform(count, Transform3D(_facing(tail, _cam_rest) * (k_scale * (1.0 - e)), tail))
		mm.visible_instance_count = count + 1
	else:
		mm.visible_instance_count = count
	_ring_dirty = false


# ---------------------------------------------------------------- camera

func _update_camera() -> void:
	if camera == null:
		return
	var vp := get_viewport()
	if vp == null:
		return
	var size := vp.get_visible_rect().size
	if size.x <= 0 or size.y <= 0:
		return
	var aspect := size.x / size.y
	var half_tan := tan(deg_to_rad(camera.fov * 0.5))
	# Machine bounding size (meters) we want to fit inside the view rect:
	# the whole stage including the lap of drawn balls at its front edge.
	var need_h := 2.82
	var need_w := 3.95
	var dist_h := need_h / (2.0 * half_tan * maxf(0.05, _view_rect.size.y))
	var dist_w := need_w / (2.0 * half_tan * aspect * maxf(0.05, _view_rect.size.x))
	var base_dist := maxf(dist_h, dist_w)
	_cam_dist = base_dist * (1.0 - _cam_push - 0.025 * _cam_punch)
	var elev := deg_to_rad(13.0)
	var dir := Vector3(sin(_cam_yaw) * cos(elev), sin(elev), cos(_cam_yaw) * cos(elev))
	var target := camera_target
	camera.global_position = target + dir * _cam_dist
	camera.look_at(target, Vector3.UP)
	# Shift the frustum so `target` lands at the center of the view rect.
	var cx := _view_rect.position.x + _view_rect.size.x * 0.5
	var cy := _view_rect.position.y + _view_rect.size.y * 0.5
	var ndc_x := cx * 2.0 - 1.0
	var ndc_y := 1.0 - cy * 2.0
	camera.h_offset = -ndc_x * _cam_dist * half_tan * aspect
	camera.v_offset = -ndc_y * _cam_dist * half_tan
	# Where the eye really is when the camera rests (h/v_offset move the camera
	# sideways). Balls on the lap face this point, and the head of the lap is
	# the spot of the stage rim nearest to it — not the camera's little moves
	# during a draw.
	var rest := target + Vector3(0.0, sin(elev), cos(elev)) * base_dist
	rest += Vector3.RIGHT * (-ndc_x * base_dist * half_tan * aspect)
	rest += Vector3(0.0, cos(elev), -sin(elev)) * (-ndc_y * base_dist * half_tan)
	if rest.distance_squared_to(_cam_rest) > 0.0001:
		_cam_rest = rest
		ring.head_deg = -rad_to_deg(atan2(rest.x - ring.center.x, rest.z - ring.center.z))
		_ring_dirty = true

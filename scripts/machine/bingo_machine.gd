extends Node3D
## 3D drawing machine presenter. It NEVER decides numbers: `play_draw(number)`
## visualizes a result that GameController already decided and saved.
## Ball tumbling inside the drum uses a tiny custom visual simulation; the
## drawn ball is a scripted path (exit -> chute -> tray), fully controlled.

const PrimitiveMachine = preload("res://scripts/machine/primitive_machine.gd")
const BallColors = preload("res://scripts/util/ball_colors.gd")
const BallLabelShader = preload("res://shaders/ball_label.gdshader")
const PartySkyShader = preload("res://shaders/party_sky.gdshader")
const StageFloorShader = preload("res://shaders/stage_floor.gdshader")
const PartyLights = preload("res://scripts/machine/party_lights.gd")

const MODEL_PATH := "res://assets/models/bingo_machine.glb"
const BALL_MODEL_PATH := "res://assets/models/bingo_ball.glb"
const MAX_VISUAL_BALLS := 32
const IDLE_SPIN := 0.25
const MAX_SPIN := 9.0

## stage: "start" | "spin" | "eject" | "land" | "reveal" | "done"
signal stage_reached(stage: String, number: int)

var camera: Camera3D
var model: Node3D
var drum: Node3D
var drum_center := Vector3.ZERO
var inner_radius := 0.6
var ball_radius := PrimitiveMachine.BALL_RADIUS
var exit_marker: Node3D
var tray_marker: Node3D
var chute_points: Array[Vector3] = []
var camera_target := Vector3(0, 1.1, 0)
var using_glb := false

var max_number := 75
var _balls: Array = []      # [{ node, p: Vector3 (drum-local, world axes), v: Vector3 }]
var _ball_mesh: Mesh
var _ball_scene: PackedScene = null
var _tray_ball: Node3D = null
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
# party backdrop
var _sky_mat: ShaderMaterial
var _floor_mat: ShaderMaterial
var _party: Node3D
var _energy := 1.0
var _reveal_pulse := 0.0

# camera framing (set by UI layout)
var _view_rect := Rect2(0, 0, 1, 1)  # normalized rect of the screen where the machine should appear
var _cam_dist := 5.5
var _cam_yaw := 0.0
var _cam_push := 0.0


func _ready() -> void:
	_rng.randomize()
	_font = SystemFont.new()
	_font.font_names = PackedStringArray(["Arial Black", "Segoe UI Black", "Arial", "Yu Gothic UI"])
	_font.font_weight = 900
	_build_environment()
	_load_model()
	_ball_mesh = PrimitiveMachine.make_ball_mesh()
	if ResourceLoader.exists(BALL_MODEL_PATH):
		_ball_scene = load(BALL_MODEL_PATH)
	camera = Camera3D.new()
	camera.fov = 38.0
	camera.near = 0.05
	camera.far = 60.0
	add_child(camera)
	camera.current = true
	set_ball_count(24)
	for i in 90:
		_simulate(1.0 / 60.0)


# ---------------------------------------------------------------- setup

func _build_environment() -> void:
	# Party backdrop: colorful but dark enough that glow / flashes still pop
	# (everything in the sky stays below the glow threshold).
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
	# Depth fog melts the floor's far edge into the horizon haze of the sky.
	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	env.fog_light_color = Color(0.30, 0.09, 0.28) * 0.55
	env.fog_light_energy = 1.0
	env.fog_density = 1.0
	env.fog_depth_begin = 8.0
	env.fog_depth_end = 16.0
	env.fog_sky_affect = 0.0
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	_party = PartyLights.new()
	_party.name = "PartyLights"
	add_child(_party)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-48, -28, 0)
	key.light_energy = 1.25
	key.light_color = Color(1.0, 0.96, 0.9)
	key.shadow_enabled = true
	add_child(key)
	var rim := DirectionalLight3D.new()
	rim.rotation_degrees = Vector3(-20, 150, 0)
	rim.light_energy = 0.7
	rim.light_color = Color(0.45, 0.6, 1.0)
	add_child(rim)

	_spin_light = SpotLight3D.new()
	_spin_light.spot_angle = 28.0
	_spin_light.light_energy = 0.0
	_spin_light.light_color = Color(1.0, 0.8, 0.4)
	add_child(_spin_light)
	_spin_light.look_at_from_position(Vector3(0, 3.6, 1.6), Vector3(0, 1.4, 0))

	_flash = OmniLight3D.new()
	_flash.omni_range = 2.2
	_flash.light_energy = 0.0
	add_child(_flash)

	# floor
	var floor := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(40, 40)
	floor.mesh = pm
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
	_flash.position = tray_marker.global_position + Vector3(0, 0.35, 0.25)


static func _validate_contract(inst: Node) -> bool:
	for n in ["Drum", "DrumInterior", "ExitMarker", "TrayMarker", "ChutePoint_1"]:
		if inst.find_child(n, true, false) == null:
			push_warning("model contract: missing node '%s'" % n)
			return false
	return true


# ---------------------------------------------------------------- public API

func set_max_number(n: int) -> void:
	max_number = n


## Shows `count` balls tumbling in the drum (capped).
func set_ball_count(count: int) -> void:
	var target := clampi(count, 0, MAX_VISUAL_BALLS)
	while _balls.size() > target:
		var b = _balls.pop_back()
		b.node.queue_free()
	while _balls.size() < target:
		_balls.append(_spawn_inner_ball())


## Puts the ball of `number` in the tray (used on restore). 0 = empty tray.
func show_in_tray(number: int) -> void:
	_clear_tray(false)
	if number <= 0:
		return
	_tray_ball = _make_ball(number, true)
	add_child(_tray_ball)
	_tray_ball.global_position = tray_marker.global_position
	_tray_ball.scale = Vector3.ONE * 1.15
	_set_label_visible(_tray_ball, true)
	_face_camera(_tray_ball, 1.0)


## Plays the draw sequence. timing = { start, spin_end, eject_end, reveal_end } (seconds).
func play_draw(number: int, timing: Dictionary, remaining_after: int) -> void:
	_number = number
	_timing = timing
	_timeline = 0.0
	_fired = {}
	_remaining_after = remaining_after
	var choices := [0, 1, 2]
	choices.erase(_last_variant)
	_variant = choices[_rng.randi_range(0, choices.size() - 1)]
	_last_variant = _variant
	_spin_light.light_color = Color.from_hsv(_rng.randf(), 0.45, 1.0)
	_clear_tray(true)


func is_playing() -> bool:
	return _timeline >= 0.0


## Normalized screen rect (0..1) where the machine should be framed.
func set_view_rect(r: Rect2) -> void:
	_view_rect = r


var _remaining_after := 0


# ---------------------------------------------------------------- per frame

func _process(delta: float) -> void:
	if _timeline >= 0.0:
		_advance_timeline(delta)
	else:
		_omega = move_toward(_omega, IDLE_SPIN, delta * 6.0)
		_cam_push = move_toward(_cam_push, 0.0, delta * 0.5)
		_cam_yaw = move_toward(_cam_yaw, 0.0, delta * 0.2)
	if drum != null:
		drum.rotate_object_local(Vector3.RIGHT, _omega * delta)
	_simulate(delta)
	_update_camera()
	# Keep the printed number of the ball in the tray turned toward the camera.
	if _tray_ball != null and _flying.is_empty():
		_face_camera(_tray_ball, delta * 8.0)
	_flash.light_energy = move_toward(_flash.light_energy, 0.0, delta * 6.0)
	_update_party(delta)


## Backdrop "excitement": a bit livelier while spinning, a short burst on reveal.
func _update_party(delta: float) -> void:
	var spinning := _timeline >= 0.0 and not _fired.has("reveal")
	var target := 1.4 if spinning else 1.0
	_energy = move_toward(_energy, target, delta * 1.5)
	_reveal_pulse = move_toward(_reveal_pulse, 0.0, delta * 0.7)
	var e := _energy + _reveal_pulse * 0.9
	if _sky_mat != null:
		_sky_mat.set_shader_parameter("energy", e)
	if _floor_mat != null:
		_floor_mat.set_shader_parameter("energy", e)
	if _party != null:
		_party.energy = e


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
		_spin_light.light_energy = 6.0 * ramp
	else:
		_omega = move_toward(_omega, IDLE_SPIN, delta * 10.0)
		_spin_light.light_energy = move_toward(_spin_light.light_energy, 0.0, delta * 10.0)
	if t >= t_start:
		_fire_once("spin", t_start)
	if t >= t_spin and not _fired.has("eject"):
		_fire_once("eject", t_spin)
		_begin_eject()
	if not _flying.is_empty():
		_update_flying(t, t_spin, t_eject)
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


# ---------------------------------------------------------------- balls

func _make_ball(number: int, with_label: bool) -> Node3D:
	var holder := Node3D.new()
	var color: Color = BallColors.color_for(number, max_number) if number > 0 else BallColors.PALETTE[_rng.randi_range(0, 4)]
	var body: Node3D
	if _ball_scene != null:
		body = _ball_scene.instantiate()
		_tint(body, color)
	else:
		var mi := MeshInstance3D.new()
		mi.mesh = _ball_mesh
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.22
		m.metallic = 0.05
		m.clearcoat_enabled = true
		m.clearcoat = 0.6
		mi.material_override = m
		body = mi
	body.name = "Body"
	holder.add_child(body)
	if with_label:
		# The number is printed ON the ball surface by a shader (follows the
		# curve and the lighting) instead of a floating billboard.
		var mat := ShaderMaterial.new()
		mat.shader = BallLabelShader
		mat.set_shader_parameter("base_color", color)
		mat.set_shader_parameter("label_tex", _make_label_texture(holder, number, color))
		mat.set_shader_parameter("label_dir", Vector3(0, 0, 1))
		mat.set_shader_parameter("show_label", false)
		if _ball_scene != null:
			_apply_label_material(body, mat)
		else:
			(body as MeshInstance3D).material_override = mat
		holder.set_meta("label_mat", mat)
	return holder


## White disc + number rendered once into a small offscreen viewport.
func _make_label_texture(holder: Node3D, number: int, ball_color: Color) -> Texture2D:
	var vp := SubViewport.new()
	vp.name = "LabelViewport"
	vp.size = Vector2i(256, 256)
	vp.transparent_bg = true
	vp.disable_3d = true
	vp.msaa_2d = Viewport.MSAA_4X
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	var disc := Panel.new()
	var st := StyleBoxFlat.new()
	st.bg_color = Color(0.98, 0.98, 0.96)
	st.set_corner_radius_all(124)
	st.set_border_width_all(10)
	st.border_color = ball_color.darkened(0.35) if BallColors.band(number, max_number) != 2 else Color(0.55, 0.57, 0.65)
	st.anti_aliasing = true
	disc.add_theme_stylebox_override("panel", st)
	disc.position = Vector2(4, 4)
	disc.size = Vector2(248, 248)
	vp.add_child(disc)
	var lbl := Label.new()
	lbl.text = str(number)
	lbl.add_theme_font_override("font", _font)
	lbl.add_theme_font_size_override("font_size", 150 if number < 10 else (124 if number < 100 else 90))
	lbl.add_theme_color_override("font_color", Color(0.07, 0.08, 0.13))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.position = Vector2(0, 4)
	lbl.size = Vector2(256, 248)
	vp.add_child(lbl)
	holder.add_child(vp)
	return vp.get_texture()


## Blender ball: the surfaces whose material name contains "BallBase" get the label shader.
func _apply_label_material(n: Node, mat: ShaderMaterial) -> void:
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		for s in mi.get_surface_override_material_count():
			var base := mi.get_active_material(s)
			if base != null and String(base.resource_name).to_lower().contains("ballbase"):
				mi.set_surface_override_material(s, mat)
	for c in n.get_children():
		_apply_label_material(c, mat)


func _tint(n: Node, color: Color) -> void:
	if n is MeshInstance3D:
		var mi: MeshInstance3D = n
		for s in mi.get_surface_override_material_count():
			var base := mi.get_active_material(s)
			if base is StandardMaterial3D and String(base.resource_name).to_lower().contains("ballbase"):
				var m: StandardMaterial3D = base.duplicate()
				m.albedo_color = color
				mi.set_surface_override_material(s, m)
	for c in n.get_children():
		_tint(c, color)


func _set_label_visible(ball: Node3D, v: bool) -> void:
	var mat = ball.get_meta("label_mat", null)
	if mat is ShaderMaterial:
		mat.set_shader_parameter("show_label", v)


## Rotation that turns the printed number (local +Z) toward the camera, upright.
func _facing_basis(ball: Node3D) -> Basis:
	if camera == null:
		return Basis.IDENTITY
	var to_cam := camera.global_position - ball.global_position
	if to_cam.length() < 0.001:
		return Basis.IDENTITY
	return Basis.looking_at(to_cam.normalized(), Vector3.UP, true)


func _face_camera(ball: Node3D, weight: float) -> void:
	var body: Node3D = ball.get_node_or_null("Body")
	if body == null:
		return
	var target := Quaternion(_facing_basis(ball))
	var cur := Quaternion(body.basis.orthonormalized())
	body.basis = Basis(cur.slerp(target, clampf(weight, 0.0, 1.0)))


func _spawn_inner_ball() -> Dictionary:
	var node := _make_ball(0, false)
	add_child(node)
	var p := Vector3(_rng.randf_range(-0.5, 0.5), _rng.randf_range(-0.6, 0.2), _rng.randf_range(-0.5, 0.5)) * inner_radius
	if p.length() > inner_radius * 0.9:
		p = p.normalized() * inner_radius * 0.9
	node.global_position = drum_center + p
	node.rotation = Vector3(_rng.randf() * TAU, _rng.randf() * TAU, 0)
	return {"node": node, "p": p, "v": Vector3.ZERO}


func _simulate(delta: float) -> void:
	var steps := 2
	var dt := minf(delta, 1.0 / 30.0) / steps
	var R := inner_radius
	var r2 := ball_radius * 2.0
	var omega_v := Vector3(_omega, 0, 0)
	for s in steps:
		for b in _balls:
			b.v += Vector3(0, -6.5, 0) * dt
			b.v *= 1.0 - 0.25 * dt
			b.p += b.v * dt
			var d: float = b.p.length()
			if d > R:
				var n: Vector3 = b.p / d
				b.p = n * R
				var vn: float = b.v.dot(n)
				if vn > 0.0:
					b.v -= n * vn * 1.45
				var v_wall := omega_v.cross(b.p)
				var vt: Vector3 = b.v - n * b.v.dot(n)
				var wt := v_wall - n * v_wall.dot(n)
				b.v += (wt - vt) * clampf(9.0 * dt, 0.0, 1.0)
		var count := _balls.size()
		for i in count:
			var a = _balls[i]
			for j in range(i + 1, count):
				var c = _balls[j]
				var dv: Vector3 = c.p - a.p
				var dist2 := dv.length_squared()
				if dist2 < r2 * r2 and dist2 > 0.000001:
					var dist := sqrt(dist2)
					var n2 := dv / dist
					var push := (r2 - dist) * 0.5
					a.p -= n2 * push
					c.p += n2 * push
					var rel: float = (c.v - a.v).dot(n2)
					if rel < 0.0:
						var imp := n2 * rel * 0.75
						a.v += imp
						c.v -= imp
	for b in _balls:
		b.node.global_position = drum_center + b.p
		b.node.rotate_x(_omega * delta * 0.7)


func _begin_eject() -> void:
	# Take the lowest ball out of the visual pile (or spawn one at the bottom).
	var pick := -1
	var lowest := INF
	for i in _balls.size():
		if _balls[i].p.y < lowest:
			lowest = _balls[i].p.y
			pick = i
	var start_pos := drum_center + Vector3(0, -inner_radius * 0.8, 0.1)
	if pick >= 0:
		var b = _balls[pick]
		start_pos = b.node.global_position
		b.node.queue_free()
		_balls.remove_at(pick)
	var ball := _make_ball(_number, true)
	add_child(ball)
	ball.global_position = start_pos
	var path: Array[Vector3] = [start_pos, exit_marker.global_position]
	path.append_array(chute_points)
	path.append(tray_marker.global_position)
	var lengths: Array[float] = [0.0]
	for i in range(1, path.size()):
		lengths.append(lengths[i - 1] + path[i].distance_to(path[i - 1]))
	_flying = {"node": ball, "path": path, "lengths": lengths}
	# keep the pile size consistent with what is left
	var want := mini(_remaining_after, MAX_VISUAL_BALLS)
	while _balls.size() < want:
		_balls.append(_spawn_inner_ball())
	while _balls.size() > want:
		_balls.pop_back().node.queue_free()


func _update_flying(t: float, t0: float, t1: float) -> void:
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


func _land() -> void:
	if _flying.is_empty():
		return
	var node: Node3D = _flying.node
	node.global_position = tray_marker.global_position
	_tray_ball = node
	_flying = {}
	var tw := create_tween()
	tw.tween_property(node, "position:y", node.position.y + ball_radius * 0.6, 0.09).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(node, "position:y", node.position.y, 0.12).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_BOUNCE)


func _reveal() -> void:
	if _tray_ball == null:
		return
	_face_camera(_tray_ball, 1.0)  # the printed number turns to the audience
	_set_label_visible(_tray_ball, true)
	_tray_ball.scale = Vector3.ONE * 0.8
	var tw := create_tween()
	tw.tween_property(_tray_ball, "scale", Vector3.ONE * 1.35, 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(_tray_ball, "scale", Vector3.ONE * 1.15, 0.2)
	_flash.light_color = BallColors.color_for(_number, max_number).lightened(0.3)
	_flash.light_energy = 2.2
	_reveal_pulse = 1.0


func _clear_tray(animated: bool) -> void:
	if _tray_ball == null:
		return
	var old := _tray_ball
	_tray_ball = null
	if animated:
		var tw := create_tween()
		tw.tween_property(old, "scale", Vector3.ONE * 0.01, 0.18)
		tw.tween_callback(old.queue_free)
	else:
		old.queue_free()


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
	# Machine bounding size (meters) we want to fit inside the view rect.
	var need_h := 2.55
	var need_w := 3.7
	var dist_h := need_h / (2.0 * half_tan * maxf(0.05, _view_rect.size.y))
	var dist_w := need_w / (2.0 * half_tan * aspect * maxf(0.05, _view_rect.size.x))
	_cam_dist = maxf(dist_h, dist_w) * (1.0 - _cam_push)
	var elev := deg_to_rad(9.0)
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

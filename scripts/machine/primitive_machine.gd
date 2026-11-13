extends RefCounted
## Builds the placeholder machine from primitive meshes using EXACTLY the node
## names of docs/model-contract.md, so a Blender GLB can replace it 1:1.
##   Machine (root)
##     Drum            – rotates around local +X; origin = drum center
##       (glass, rings, axle as children)
##     DrumInterior    – Node3D at drum center; scale.x = usable inner radius (m)
##     ExitMarker      – where the drawn ball leaves the drum
##     ChutePoint_1..N – path from exit to tray
##     TrayMarker      – resting center of the drawn ball
##     BallRing        – lap of the already-drawn balls on the stage rim:
##                       position = lap center on the stage surface, scale.x = lap radius (m)
##     CameraTarget    – what the camera looks at

const DRUM_CENTER := Vector3(0.0, 1.55, 0.0)
const DRUM_RADIUS := 0.8
const BALL_RADIUS := 0.085
## Everything that does not rotate must stay outside this sphere around
## DRUM_CENTER (drum rings reach DRUM_RADIUS + 0.025) — see tests/unit/test_machine_model.gd.
const DRUM_SWEEP_RADIUS := DRUM_RADIUS + 0.035
const STAGE_TOP := 0.16
## Body (red pedestal) top; the drum's lowest point is DRUM_CENTER.y - DRUM_SWEEP_RADIUS = 0.725.
const BODY_TOP := 0.6
## Exit direction from the drum center (front-bottom) and how far outside the sweep it sits.
const EXIT_DIR := Vector3(0.0, -0.65, 0.76)
const EXIT_CLEARANCE := 0.12
## Stage (round base) and the lap where drawn balls rest, just inside its gold trim.
const STAGE_CENTER := Vector3(0.0, 0.0, 0.15)
const STAGE_RADIUS := 1.75
const RING_RADIUS := 1.645


static func _mat(color: Color, metallic: float = 0.0, roughness: float = 0.5, emission: Color = Color.BLACK, emission_energy: float = 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	m.metallic = metallic
	m.roughness = roughness
	if emission_energy > 0.0:
		m.emission_enabled = true
		m.emission = emission
		m.emission_energy_multiplier = emission_energy
	return m


static func _mesh(parent: Node3D, mesh: Mesh, mat: Material, pos: Vector3, name: String = "", rot: Vector3 = Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	mi.rotation = rot
	if not name.is_empty():
		mi.name = name
	parent.add_child(mi)
	return mi


static func _marker(parent: Node3D, name: String, pos: Vector3, scale: float = 1.0) -> Node3D:
	var n := Node3D.new()
	n.name = name
	n.position = pos
	n.scale = Vector3.ONE * scale
	parent.add_child(n)
	return n


static func build() -> Node3D:
	var root := Node3D.new()
	root.name = "Machine"

	var gold := _mat(Color(0.95, 0.72, 0.28), 0.9, 0.28)
	var dark := _mat(Color(0.08, 0.09, 0.14), 0.3, 0.45)
	var red := _mat(Color(0.75, 0.08, 0.16), 0.2, 0.35)
	var chrome := _mat(Color(0.82, 0.84, 0.9), 1.0, 0.15)

	# --- stage
	var stage := CylinderMesh.new()
	stage.top_radius = STAGE_RADIUS
	stage.bottom_radius = STAGE_RADIUS + 0.1
	stage.height = STAGE_TOP
	stage.radial_segments = 96
	_mesh(root, stage, dark, STAGE_CENTER + Vector3(0, STAGE_TOP * 0.5, 0), "Stage")
	var trim := TorusMesh.new()
	trim.inner_radius = STAGE_RADIUS - 0.03
	trim.outer_radius = STAGE_RADIUS + 0.05
	trim.rings = 96
	_mesh(root, trim, _mat(Color(1.0, 0.8, 0.35), 0.6, 0.3, Color(1.0, 0.7, 0.25), 0.45), STAGE_CENTER + Vector3(0, STAGE_TOP + 0.005, 0), "StageTrim")
	# Lap of the drawn balls: they rest between this inner rail and the trim.
	_marker(root, "BallRing", STAGE_CENTER + Vector3(0, STAGE_TOP, 0), RING_RADIUS)
	var ring_rail := TorusMesh.new()
	ring_rail.inner_radius = RING_RADIUS - BALL_RADIUS - 0.034
	ring_rail.outer_radius = RING_RADIUS - BALL_RADIUS - 0.01
	ring_rail.rings = 96
	ring_rail.ring_segments = 12
	_mesh(root, ring_rail, gold, STAGE_CENTER + Vector3(0, STAGE_TOP + 0.004, 0), "RingRail")
	var lane := TorusMesh.new()
	lane.inner_radius = RING_RADIUS - 0.03
	lane.outer_radius = RING_RADIUS + 0.03
	lane.rings = 96
	lane.ring_segments = 8
	# A thin, slightly glowing line marks the lap under the balls.
	_mesh(root, lane, _mat(Color(0.5, 0.2, 0.6), 0.2, 0.5, Color(0.75, 0.35, 1.0), 0.55), STAGE_CENTER + Vector3(0, STAGE_TOP - 0.024, 0), "RingLane")

	# --- body / pedestal under the drum
	# Kept low so the rotating drum frame never touches it (clearance >= 0.1 m).
	var body := CylinderMesh.new()
	body.top_radius = 0.4
	body.bottom_radius = 0.62
	body.height = BODY_TOP - STAGE_TOP
	_mesh(root, body, red, Vector3(0, STAGE_TOP + body.height * 0.5, 0), "Body")
	var collar := TorusMesh.new()
	collar.inner_radius = 0.36
	collar.outer_radius = 0.44
	_mesh(root, collar, gold, Vector3(0, BODY_TOP, 0), "Collar")

	# --- side posts + axle bearings
	var post_h := DRUM_CENTER.y - STAGE_TOP + 0.04
	for sx in [-1.0, 1.0]:
		var post := BoxMesh.new()
		post.size = Vector3(0.12, post_h, 0.22)
		_mesh(root, post, gold, Vector3(sx * 0.98, STAGE_TOP + post_h * 0.5, 0), "Post")
		var cap := SphereMesh.new()
		cap.radius = 0.11
		cap.height = 0.22
		_mesh(root, cap, chrome, Vector3(sx * 0.98, DRUM_CENTER.y, 0), "Bearing")
		var foot := BoxMesh.new()
		foot.size = Vector3(0.3, 0.06, 0.5)
		_mesh(root, foot, dark, Vector3(sx * 0.98, 0.19, 0), "Foot")

	# --- drum (rotating)
	var drum := Node3D.new()
	drum.name = "Drum"
	drum.position = DRUM_CENTER
	root.add_child(drum)
	var glass := SphereMesh.new()
	glass.radius = DRUM_RADIUS
	glass.height = DRUM_RADIUS * 2.0
	glass.radial_segments = 48
	glass.rings = 24
	var gm := StandardMaterial3D.new()
	gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	gm.albedo_color = Color(0.7, 0.88, 1.0, 0.12)
	gm.roughness = 0.04
	gm.metallic = 0.0
	gm.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	gm.rim_enabled = true
	gm.rim = 0.6
	gm.rim_tint = 0.3
	gm.cull_mode = BaseMaterial3D.CULL_BACK
	_mesh(drum, glass, gm, Vector3.ZERO, "DrumGlass")
	for i in 3:
		var ring := TorusMesh.new()
		ring.inner_radius = DRUM_RADIUS - 0.015
		ring.outer_radius = DRUM_RADIUS + 0.025
		ring.rings = 48
		_mesh(drum, ring, gold, Vector3.ZERO, "DrumRing%d" % i, Vector3(i * PI / 3.0, 0, 0))
	var equator := TorusMesh.new()
	equator.inner_radius = DRUM_RADIUS - 0.01
	equator.outer_radius = DRUM_RADIUS + 0.035
	equator.rings = 48
	_mesh(drum, equator, chrome, Vector3.ZERO, "DrumEquator", Vector3(0, 0, PI / 2.0))
	var axle := CylinderMesh.new()
	axle.top_radius = 0.04
	axle.bottom_radius = 0.04
	axle.height = 1.9
	_mesh(drum, axle, chrome, Vector3.ZERO, "Axle", Vector3(0, 0, PI / 2.0))
	var hub := CylinderMesh.new()
	hub.top_radius = 0.13
	hub.bottom_radius = 0.13
	hub.height = 0.06
	for sx in [-1.0, 1.0]:
		_mesh(drum, hub, red, Vector3(sx * (DRUM_RADIUS + 0.02), 0, 0), "Hub", Vector3(0, 0, PI / 2.0))

	_marker(root, "DrumInterior", DRUM_CENTER, DRUM_RADIUS - 0.03 - BALL_RADIUS)

	# --- exit + chute + tray (front-right), all outside the drum's sweep sphere
	var exit_dir := EXIT_DIR.normalized()
	var exit_pos := DRUM_CENTER + exit_dir * (DRUM_SWEEP_RADIUS + EXIT_CLEARANCE)
	_marker(root, "ExitMarker", exit_pos)
	# A ring around the ball's exit point, facing away from the drum.
	var spout := TorusMesh.new()
	spout.inner_radius = BALL_RADIUS + 0.015
	spout.outer_radius = BALL_RADIUS + 0.05
	var spout_mi := _mesh(root, spout, gold, exit_pos, "Spout")
	spout_mi.basis = _basis_y_to(exit_dir)
	var pts := [
		exit_pos + Vector3(0.14, -0.08, 0.16),
		exit_pos + Vector3(0.42, -0.2, 0.32),
		exit_pos + Vector3(0.74, -0.32, 0.46),
	]
	for i in pts.size():
		_marker(root, "ChutePoint_%d" % (i + 1), pts[i])
	var tray_pos := exit_pos + Vector3(0.98, -0.4, 0.56)
	_marker(root, "TrayMarker", tray_pos)
	# chute rails
	var prev: Vector3 = exit_pos
	for p in pts + [tray_pos]:
		var seg: Vector3 = p - prev
		var len := seg.length()
		var rail := CylinderMesh.new()
		rail.top_radius = 0.018
		rail.bottom_radius = 0.018
		rail.height = len
		for side in [-1.0, 1.0]:
			var mi := MeshInstance3D.new()
			mi.mesh = rail
			mi.material_override = chrome
			var mid: Vector3 = (prev + p) * 0.5 - Vector3(0, BALL_RADIUS * 0.7, 0)
			var dir: Vector3 = seg.normalized()
			var side_dir: Vector3 = dir.cross(Vector3.UP).normalized() * side * (BALL_RADIUS * 0.85)
			mi.position = mid + side_dir
			mi.basis = _basis_y_to(dir)
			mi.name = "ChuteRail"
			root.add_child(mi)
		prev = p
	var tray := CylinderMesh.new()
	tray.top_radius = 0.24
	tray.bottom_radius = 0.2
	tray.height = 0.06
	_mesh(root, tray, gold, tray_pos - Vector3(0, BALL_RADIUS + 0.03, 0), "Tray")
	var tray_pad := CylinderMesh.new()
	tray_pad.top_radius = 0.2
	tray_pad.bottom_radius = 0.2
	tray_pad.height = 0.02
	_mesh(root, tray_pad, _mat(Color(0.45, 0.05, 0.12), 0.0, 0.9), tray_pos - Vector3(0, BALL_RADIUS - 0.005, 0), "TrayPad")
	# Slim, so the balls on the lap pass next to it without touching.
	var stand := CylinderMesh.new()
	stand.top_radius = 0.035
	stand.bottom_radius = 0.048
	stand.height = tray_pos.y - BALL_RADIUS - 0.06 - 0.16
	_mesh(root, stand, gold, Vector3(tray_pos.x, 0.16 + stand.height * 0.5, tray_pos.z), "TrayStand")

	_marker(root, "CameraTarget", Vector3(0.06, 0.94, 0.4))
	return root


static func _basis_y_to(dir: Vector3) -> Basis:
	var y := dir.normalized()
	var x := y.cross(Vector3.FORWARD)
	if x.length() < 0.01:
		x = y.cross(Vector3.RIGHT)
	x = x.normalized()
	var z := x.cross(y).normalized()
	return Basis(x, y, z)


static func make_ball_mesh() -> Mesh:
	var s := SphereMesh.new()
	s.radius = BALL_RADIUS
	s.height = BALL_RADIUS * 2.0
	s.radial_segments = 24
	s.rings = 12
	return s

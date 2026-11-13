extends RefCounted
## Shared look of every bingo ball: ONE mesh + ONE material, drawn through
## MultiMesh (the drum, the stage rim and the ball in the tray are all
## instances). The number is per-instance data, so 75 (or 999) numbered balls
## cost a single draw call — see shaders/ball_label.gdshader.
##
## The digit glyphs are rendered once in a small SubViewport and then baked
## into a mipmapped Texture2DArray (a ViewportTexture has no mipmaps, and the
## numbers on distant balls would shimmer). Headless runs never render, so the
## bake simply never happens there (balls keep a blank label).

const PrimitiveMachine = preload("res://scripts/machine/primitive_machine.gd")
const BallColors = preload("res://scripts/util/ball_colors.gd")
const BallLabelShader = preload("res://shaders/ball_label.gdshader")

const CELL := Vector2i(128, 160)
## Glyphs are drawn with their baseline at BASELINE inside the cell. The size is
## chosen so that the whole digit (about 0.72 em tall, plus overshoot) stays
## inside the cell for any fallback font; the exact ink box is measured after
## rendering and handed to the shader (ink_top / ink_bottom / ink_width).
const FONT_SIZE := 150
const BASELINE := 134
## Red value (0-255) that counts as ink when measuring the glyphs.
const INK_LEVEL := 110
## Frames to wait before reading the digit viewport back.
const BAKE_AFTER_FRAMES := 3
const BAKE_GIVE_UP_FRAMES := 240

var mesh: Mesh
## Radius of `mesh` in its own units; instances are scaled to the wanted size.
var mesh_radius: float = PrimitiveMachine.BALL_RADIUS
var material: ShaderMaterial
var digits_ready := false
## Ink box of the baked digits inside a cell (pixels); empty until baked.
var ink_box := Rect2i()

var _viewport: SubViewport = null
var _frames := 0


func _init() -> void:
	material = ShaderMaterial.new()
	material.shader = BallLabelShader
	material.set_shader_parameter("digit_aspect", float(CELL.x) / float(CELL.y))
	material.set_shader_parameter("digits_ready", false)
	var s := SphereMesh.new()
	s.radius = mesh_radius
	s.height = mesh_radius * 2.0
	s.radial_segments = 28
	s.rings = 14
	s.material = material
	mesh = s


## Uses the ball of a Blender GLB instead of the primitive sphere. Surfaces
## whose material name contains "BallBase" get the number shader (docs/model-contract.md).
func use_scene_mesh(scene: PackedScene) -> bool:
	var inst := scene.instantiate()
	var found: MeshInstance3D = null
	if inst is MeshInstance3D:
		found = inst
	else:
		var list := inst.find_children("*", "MeshInstance3D", true, false)
		if not list.is_empty():
			found = list[0]
	var ok := false
	if found != null and found.mesh != null:
		var m: Mesh = found.mesh.duplicate()
		var replaced := 0
		for s in m.get_surface_count():
			var base := m.surface_get_material(s)
			if base != null and String(base.resource_name).to_lower().contains("ballbase"):
				m.surface_set_material(s, material)
				replaced += 1
		if replaced > 0:
			mesh = m
			var aabb := m.get_aabb()
			mesh_radius = maxf(0.001, maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z)) * 0.5)
			ok = true
		else:
			push_warning("bingo_ball.glb has no material named *BallBase*; using the built-in ball")
	inst.free()
	return ok


## Offscreen strip with the glyphs 0-9 (white on black). Add it to the tree,
## then call poll_bake() every frame until `digits_ready`.
func make_digit_viewport(font: Font) -> SubViewport:
	var vp := SubViewport.new()
	vp.name = "BallDigits"
	vp.size = Vector2i(CELL.x * 10, CELL.y)
	vp.transparent_bg = false
	vp.disable_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Drawn directly at a known baseline. (A Label cannot be used here: it grows
	# to the font's full line height, which is taller than the cell, and the
	# lower part of every digit ended up outside the texture.)
	var canvas := Control.new()
	canvas.size = Vector2(vp.size)
	canvas.draw.connect(func():
		canvas.draw_rect(Rect2(Vector2.ZERO, canvas.size), Color.BLACK)
		for d in 10:
			canvas.draw_string(font, Vector2(d * CELL.x, BASELINE), str(d), HORIZONTAL_ALIGNMENT_CENTER, CELL.x, FONT_SIZE, Color.WHITE))
	vp.add_child(canvas)
	_viewport = vp
	_frames = 0
	return vp


## Returns true once the digits are baked (or baking was given up).
func poll_bake() -> bool:
	if digits_ready or _viewport == null:
		return true
	_frames += 1
	if _frames < BAKE_AFTER_FRAMES:
		return false
	var img: Image = null
	if DisplayServer.get_name() != "headless":
		img = _viewport.get_texture().get_image()
	if img == null or img.is_empty():
		if _frames < BAKE_GIVE_UP_FRAMES and DisplayServer.get_name() != "headless":
			return false
		_drop_viewport()
		return true
	# The first frames can still be black: wait until some ink has arrived.
	if not _has_ink(img):
		if _frames < BAKE_GIVE_UP_FRAMES:
			return false
		_drop_viewport()
		return true
	var layers: Array[Image] = []
	var box := Rect2i()
	var widest := 0
	for d in 10:
		var cell := img.get_region(Rect2i(d * CELL.x, 0, CELL.x, CELL.y))
		cell.convert(Image.FORMAT_R8)
		var ink := ink_rect(cell)
		if ink.size.x > 0:
			box = ink if box.size.x == 0 else box.merge(ink)
			widest = maxi(widest, ink.size.x)
		cell.generate_mipmaps()
		layers.append(cell)
	ink_box = box
	var tex := Texture2DArray.new()
	if tex.create_from_images(layers) == OK:
		material.set_shader_parameter("digit_tex", tex)
		if box.size.y > 0 and widest > 0:
			# Where the digits really are inside a cell: the shader sizes and
			# places the number from this, so nothing depends on font metrics.
			material.set_shader_parameter("ink_top", float(box.position.y) / CELL.y)
			material.set_shader_parameter("ink_bottom", float(box.end.y) / CELL.y)
			material.set_shader_parameter("ink_width", float(widest) / CELL.x)
		material.set_shader_parameter("digits_ready", true)
		digits_ready = true
		print("ball digits baked: ink box %s of cell %s, widest digit %d px" % [box, CELL, widest])
	_drop_viewport()
	return true


## Bounding box of the ink (red > INK_LEVEL) in an R8 image; empty when blank.
static func ink_rect(cell: Image) -> Rect2i:
	var w := cell.get_width()
	var h := cell.get_height()
	var bytes := cell.get_data()
	var left := w
	var right := -1
	var top := h
	var bottom := -1
	for y in h:
		var row := y * w
		for x in w:
			if bytes[row + x] > INK_LEVEL:
				if x < left:
					left = x
				if x > right:
					right = x
				if y < top:
					top = y
				bottom = y
	if right < 0:
		return Rect2i()
	return Rect2i(left, top, right - left + 1, bottom - top + 1)


func _has_ink(img: Image) -> bool:
	var y := BASELINE - FONT_SIZE / 3
	for x in range(0, img.get_width(), 4):
		if img.get_pixel(x, y).r > 0.5:
			return true
	return false


func _drop_viewport() -> void:
	if _viewport != null and is_instance_valid(_viewport):
		_viewport.queue_free()
	_viewport = null


func make_multimesh(capacity: int) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = maxi(1, capacity)
	mm.visible_instance_count = 0
	return mm


func make_instance_node(capacity: int, node_name: String) -> MultiMeshInstance3D:
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = make_multimesh(capacity)
	return mi


## Color / number of instance `i`. The shader reads raw (linear) values.
static func paint(mm: MultiMesh, i: int, number: int, max_number: int, flash: float = 0.0) -> void:
	mm.set_instance_color(i, instance_color(number, max_number))
	mm.set_instance_custom_data(i, Color(float(number), flash, 0.0, 0.0))


static func set_flash(mm: MultiMesh, i: int, number: int, flash: float) -> void:
	mm.set_instance_custom_data(i, Color(float(number), flash, 0.0, 0.0))


static func instance_color(number: int, max_number: int) -> Color:
	return BallColors.color_for(number, max_number).srgb_to_linear()


## A single free-standing ball (the one that rolls out and rests in the tray):
## holder Node3D with a "Body" child that carries the rotation.
func make_single(number: int, max_number: int, radius: float) -> Node3D:
	var holder := Node3D.new()
	holder.name = "Ball%d" % number
	var body := make_instance_node(1, "Body")
	body.multimesh.visible_instance_count = 1
	body.multimesh.set_instance_transform(0, Transform3D(Basis.IDENTITY * (radius / mesh_radius), Vector3.ZERO))
	paint(body.multimesh, 0, number, max_number)
	holder.add_child(body)
	holder.set_meta("number", number)
	return holder

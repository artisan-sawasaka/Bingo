extends "res://tests/test_case.gd"
## Numbers printed on the balls: the digit glyphs must lie completely inside
## their texture cell (a clipped glyph showed up as digits with the bottom cut off).

const BallVisuals = preload("res://scripts/machine/ball_visuals.gd")


func _cell_with_ink(rect: Rect2i) -> Image:
	var img := Image.create(BallVisuals.CELL.x, BallVisuals.CELL.y, false, Image.FORMAT_R8)
	img.fill(Color.BLACK)
	if rect.size.x > 0:
		img.fill_rect(rect, Color.WHITE)
	return img


func test_ink_box_is_measured_exactly() -> void:
	var rect := Rect2i(17, 24, 94, 112)
	eq(BallVisuals.ink_rect(_cell_with_ink(rect)), rect, "bounding box of the ink")
	eq(BallVisuals.ink_rect(_cell_with_ink(Rect2i())), Rect2i(), "blank cell has no ink")
	# Faint anti-aliasing fringe does not count as ink.
	var img := _cell_with_ink(Rect2i(40, 40, 10, 10))
	img.set_pixel(5, 5, Color(0.2, 0.2, 0.2))
	eq(BallVisuals.ink_rect(img), Rect2i(40, 40, 10, 10), "fringe ignored")


func test_glyphs_are_drawn_inside_the_cell() -> void:
	# Digits are about 0.72 em tall and sit on the baseline (round ones dip about 2 % below).
	var size: int = BallVisuals.FONT_SIZE
	var baseline: int = BallVisuals.BASELINE
	check(baseline + int(size * 0.06) < BallVisuals.CELL.y, "room below the baseline for overshoot")
	check(baseline - int(size * 0.8) > 0, "room above the tallest digit")
	check(int(size * 0.75) < BallVisuals.CELL.x, "the widest digit fits the cell width")


func test_every_ball_is_an_instance_with_its_number() -> void:
	var visuals := BallVisuals.new()
	var mm := visuals.make_multimesh(75)
	eq(mm.instance_count, 75, "one instance per ball")
	check(mm.use_colors and mm.use_custom_data, "color and number are per-instance data")
	BallVisuals.paint(mm, 3, 42, 75)  # (headless rendering keeps no instance data to read back)
	var single := visuals.make_single(7, 75, 0.085)
	eq(int(single.get_meta("number")), 7, "free-standing ball knows its number")
	check(single.get_node_or_null("Body") != null, "body node carries the rotation")
	single.free()

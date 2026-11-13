extends "res://tests/test_case.gd"

const BallColors = preload("res://scripts/util/ball_colors.gd")


func test_ten_colors_by_tens_digit() -> void:
	eq(BallColors.PALETTE.size(), 10, "10 colors")
	for n in range(1, 10):
		eq(BallColors.group(n), 0, "%d in 0-9" % n)
	for g in 10:
		for n in range(g * 10, g * 10 + 10):
			eq(BallColors.group(n), g, "%d" % n)
			eq(BallColors.color_for(n, 75), BallColors.PALETTE[g], "color of %d" % n)
	check(BallColors.color_for(9, 75) != BallColors.color_for(10, 75), "9 and 10 differ")
	check(BallColors.color_for(19, 75) != BallColors.color_for(20, 75), "19 and 20 differ")


func test_colors_do_not_depend_on_max_number() -> void:
	for n in [1, 15, 16, 42, 75]:
		for mx in [75, 90, 100, 999]:
			eq(BallColors.color_for(n, mx), BallColors.color_for(n), "%d at max %d" % [n, mx])


func test_from_100_the_colors_repeat() -> void:
	eq(BallColors.group(100), 0, "100-109 like 0-9")
	eq(BallColors.group(115), 1, "110-119 like 10-19")
	eq(BallColors.group(999), 9, "990-999 like 90-99")
	eq(BallColors.color_for(105, 999), BallColors.color_for(5, 999), "same color")


func test_0_to_9_is_blue() -> void:
	var c: Color = BallColors.color_for(5)
	check(c.b > c.r and c.b > c.g, "blue: %s" % str(c))


func test_colors_are_distinct() -> void:
	var p: Array = BallColors.PALETTE
	for i in p.size():
		for j in range(i + 1, p.size()):
			var a: Color = p[i]
			var b: Color = p[j]
			var d := Vector3(a.r - b.r, a.g - b.g, a.b - b.b).length()
			check(d > 0.25, "groups %d / %d too close (%.2f)" % [i, j, d])


func test_text_on_every_color_is_readable() -> void:
	# History board cells: number printed on the ball color.
	for g in 10:
		var n := g * 10 + 5
		var bg: Color = BallColors.color_for(n)
		var cr: float = BallColors.contrast(bg, BallColors.ink_for(n))
		check(cr >= 4.0, "group %d contrast %.2f" % [g, cr])


func test_bingo_letters_still_follow_card_columns() -> void:
	eq(BallColors.letter_for(1, 75), "B", "1")
	eq(BallColors.letter_for(15, 75), "B", "15")
	eq(BallColors.letter_for(16, 75), "I", "16")
	eq(BallColors.letter_for(45, 75), "N", "45")
	eq(BallColors.letter_for(60, 75), "G", "60")
	eq(BallColors.letter_for(75, 75), "O", "75")
	eq(BallColors.letter_for(10, 90), "", "no letters unless max is 75")

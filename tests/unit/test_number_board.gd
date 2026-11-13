extends "res://tests/test_case.gd"

const NumberBoard = preload("res://scripts/ui/number_board.gd")
const BallColors = preload("res://scripts/util/ball_colors.gd")


func test_rows_follow_the_tens_digit() -> void:
	eq(NumberBoard.cell_of(1), Vector2i(1, 0), "1: first row, after the empty 0 cell")
	eq(NumberBoard.cell_of(9), Vector2i(9, 0), "9: end of first row")
	eq(NumberBoard.cell_of(10), Vector2i(0, 1), "10 starts row 2")
	eq(NumberBoard.cell_of(19), Vector2i(9, 1), "19 ends row 2")
	eq(NumberBoard.cell_of(75), Vector2i(5, 7), "75")
	eq(NumberBoard.cell_of(100), Vector2i(0, 10), "100")
	eq(NumberBoard.cell_of(999), Vector2i(9, 99), "999")


func test_row_count() -> void:
	eq(NumberBoard.row_count(0), 0, "no game")
	eq(NumberBoard.row_count(1), 1, "1")
	eq(NumberBoard.row_count(9), 1, "1-9")
	eq(NumberBoard.row_count(10), 2, "1-9 + 10")
	eq(NumberBoard.row_count(75), 8, "0-9 ... 70-75")
	eq(NumberBoard.row_count(99), 10, "0-9 ... 90-99")
	eq(NumberBoard.row_count(100), 11, "100 on its own row")
	eq(NumberBoard.row_count(999), 100, "999")


func test_every_row_is_one_color_and_cells_are_unique() -> void:
	var used := {}
	for n in range(1, 1000):
		var c: Vector2i = NumberBoard.cell_of(n)
		check(not used.has(c), "cell of %d is free" % n)
		used[c] = true
		check(c.y < NumberBoard.row_count(999), "%d inside the grid" % n)
		var row_color: Color = BallColors.PALETTE[c.y % 10]
		eq(BallColors.color_for(n), row_color, "%d has its row's color" % n)

extends "res://tests/test_case.gd"
## Drawn balls on the stage rim: the newest at the head (front), older ones
## shifted clockwise, a whole 75 game in one lap.

const BallRing = preload("res://scripts/machine/ball_ring.gd")

const BALL := 0.085


func _ring(max_number: int, base_r: float = BALL) -> BallRing:
	var ring := BallRing.new()
	ring.configure(max_number, base_r)
	return ring


func test_whole_75_game_fits_in_one_lap() -> void:
	var ring := _ring(75)
	eq(ring.capacity, 74, "74 retired balls (the 75th stays in the tray)")
	check(ring.ball_r <= BALL and ring.ball_r > 0.06, "balls only a little smaller: %.4f" % ring.ball_r)
	check(ring.spacing() >= ring.ball_r * 2.0, "neighbours do not overlap")
	# A full lap closes evenly: slot 74 would be slot 0 again.
	check(ring.slot_position(74.0).distance_to(ring.slot_position(0.0)) < 0.001, "lap closes")


func test_small_games_keep_full_size_balls() -> void:
	var ring := _ring(30)
	eq(ring.ball_r, BALL, "full size")
	check(ring.capacity >= 29, "all 29 retired balls fit: capacity %d" % ring.capacity)


func test_neighbours_never_overlap() -> void:
	for max_number in [10, 75, 90, 100, 300, 999]:
		var base: float = BALL if max_number <= 150 else 0.05
		var ring := _ring(max_number, base)
		var chord := ring.slot_position(0.0).distance_to(ring.slot_position(1.0))
		check(chord >= ring.ball_r * 2.0, "max %d: chord %.4f vs diameter %.4f" % [max_number, chord, ring.ball_r * 2.0])
		check(ring.ball_r >= minf(BallRing.MIN_BALL_RADIUS, base) - 0.0001, "max %d: ball not smaller than the minimum" % max_number)
		check(ring.capacity >= 1, "capacity")


func test_head_is_the_front_and_older_balls_go_clockwise() -> void:
	var ring := _ring(75)
	ring.head_deg = 0.0
	var c := ring.center
	var head := ring.slot_position(0.0)
	check(absf(head.x - c.x) < 0.0001 and head.z > c.z, "slot 0 is at the front (+Z, toward the audience)")
	check(absf(head.y - (c.y + ring.ball_r)) < 0.0001, "balls rest on the stage surface")
	# Clockwise seen from above: front -> left (-X) -> back (-Z) -> right (+X).
	var quarter := ring.angle_position(PI * 0.5)
	check(quarter.x < c.x - ring.radius * 0.99 and absf(quarter.z - c.z) < 0.001, "a quarter lap later: left side")
	var half := ring.angle_position(PI)
	check(half.z < c.z - ring.radius * 0.99, "half a lap later: back")
	var three := ring.angle_position(PI * 1.5)
	check(three.x > c.x + ring.radius * 0.99, "three quarters: right side")
	# Each older slot is further along that direction.
	for k in 10:
		var a := ring.slot_position(float(k))
		var b := ring.slot_position(float(k + 1))
		check(b.x < a.x, "slot %d is left of slot %d near the front" % [k + 1, k])
		check((b - a).normalized().dot(ring.slot_tangent(float(k) + 0.5)) > 0.99, "tangent points along the travel direction")


func test_head_direction_can_be_turned() -> void:
	var ring := _ring(75)
	ring.head_deg = -15.0  # toward +X (the camera stands a little to the right)
	var head := ring.slot_position(0.0)
	check(head.x > ring.center.x, "head moved to the right")
	check(ring.slot_position(1.0).x < head.x, "still shifting clockwise")


func test_newest_ball_takes_the_head() -> void:
	var ring := _ring(75)
	eq(ring.push(5), 0, "nothing falls off")
	ring.push(9)
	ring.push(12)
	var newest_first: Array[int] = [12, 9, 5]
	eq(ring.numbers, newest_first, "newest first")
	ring.set_from_draw_order([3, 1, 4, 15])
	var restored: Array[int] = [15, 4, 1, 3]
	eq(ring.numbers, restored, "restored: last drawn at the head")


func test_full_lap_lets_the_oldest_go() -> void:
	var ring := BallRing.new()
	ring.radius = 0.3
	ring.configure(100, BALL)
	var cap := ring.capacity
	check(cap >= 5 and cap < 30, "small test lap: capacity %d" % cap)
	for n in range(1, cap + 1):
		eq(ring.push(n), 0, "fits")
	eq(ring.numbers.size(), cap, "lap is full")
	eq(ring.push(50), 1, "the oldest ball (1) leaves")
	eq(ring.numbers.size(), cap, "still one lap")
	eq(ring.numbers[0], 50, "newest at the head")
	eq(ring.numbers[cap - 1], 2, "second oldest is now last")
	var order: Array = []
	for n in range(1, cap + 4):
		order.append(n)
	ring.set_from_draw_order(order)
	eq(ring.numbers.size(), cap, "restore keeps only what fits")
	eq(ring.numbers[0], cap + 3, "restore keeps the newest")

extends "res://tests/test_case.gd"
## Balls inside the drum: one per remaining number, always moving, never
## escaping, and the drawn one can be steered out. (Visual only — the draw
## itself is decided by GameController.)

const DrumSim = preload("res://scripts/machine/drum_sim.gd")

const RADIUS := 0.685
const BALL := 0.085
const DT := 1.0 / 60.0


func _range(n: int) -> Array:
	var out: Array = []
	for i in range(1, n + 1):
		out.append(i)
	return out


func _make(n: int, seed_value: int = 7) -> DrumSim:
	var sim := DrumSim.new()
	sim.set_seed(seed_value)
	var r: float = DrumSim.ball_radius_for(n, RADIUS + BALL, BALL)
	sim.setup(_range(n), RADIUS + BALL - r, r)
	return sim


func _run(sim: DrumSim, steps: int) -> void:
	for i in steps:
		sim.step(DT)


func _mean_speed(sim: DrumSim) -> float:
	var total := 0.0
	for v in sim.vel:
		total += v.length()
	return total / maxf(1.0, sim.count())


func _all_inside(sim: DrumSim) -> bool:
	for p in sim.pos:
		if not is_finite(p.x) or not is_finite(p.y) or not is_finite(p.z):
			return false
		if p.length() > sim.radius + 0.0005:
			return false
	return true


func test_one_ball_per_remaining_number() -> void:
	var sim := _make(75)
	eq(sim.count(), 75, "75 balls for a fresh 75 game")
	var nums := sim.numbers()
	nums.sort()
	var all: Array[int] = []
	all.assign(_range(75))
	eq(nums, all, "every number exactly once")
	# A game in progress: only what is left.
	var rest: Array[int] = [3, 14, 15, 60]
	sim.setup(rest, RADIUS, BALL)
	var left := sim.numbers()
	left.sort()
	eq(left, rest, "only the remaining numbers")
	sim.setup([], RADIUS, BALL)
	eq(sim.count(), 0, "empty drum when everything is drawn")
	sim.step(DT)  # must not fail with no balls


func test_ball_size_shrinks_only_for_huge_games() -> void:
	var r75: float = DrumSim.ball_radius_for(75, RADIUS + BALL, BALL)
	eq(r75, BALL, "75 balls keep the standard size")
	var r999: float = DrumSim.ball_radius_for(999, RADIUS + BALL, BALL)
	check(r999 < BALL * 0.7 and r999 > 0.03, "999 balls are smaller but visible: %.3f" % r999)


func test_balls_stay_inside_and_do_not_sink_into_each_other() -> void:
	var sim := _make(75)
	sim.agitation = 0.3
	sim.omega = 0.25
	_run(sim, 400)
	check(_all_inside(sim), "all centers inside the drum while idling")
	check(sim.max_overlap() < BALL * 0.6, "idle overlap %.3f m" % sim.max_overlap())
	sim.agitation = 1.0
	sim.omega = 9.0
	_run(sim, 240)
	check(_all_inside(sim), "all centers inside the drum at full spin")
	check(sim.max_overlap() < BALL * 0.9, "spin overlap %.3f m" % sim.max_overlap())


func test_blower_keeps_the_balls_moving_at_random() -> void:
	var sim := _make(75, 1)
	sim.agitation = 0.3
	sim.omega = 0.25
	_run(sim, 300)
	var speed := 0.0
	var highest := -INF
	for i in 180:
		sim.step(DT)
		speed += _mean_speed(sim)
		for p in sim.pos:
			highest = maxf(highest, p.y)
	speed /= 180.0
	check(speed > 0.12, "balls keep moving while idle: mean speed %.3f m/s" % speed)
	check(highest > -0.25 * RADIUS, "some balls get tossed up: highest %.3f" % highest)
	# Different seeds end up in different arrangements (no fixed loop).
	var other := _make(75, 2)
	other.agitation = 0.3
	other.omega = 0.25
	_run(other, 480)
	var same := 0
	for i in sim.count():
		var j := other.index_of(sim.num[i])
		if sim.pos[i].distance_to(other.pos[j]) < 0.02:
			same += 1
	check(same < 10, "arrangements differ between runs (%d balls in the same place)" % same)


func test_without_the_blower_the_pile_comes_to_rest() -> void:
	var sim := _make(40)
	sim.agitation = 0.0
	sim.omega = 0.0
	_run(sim, 900)
	# What is left is solver creep of well under a millimeter per frame (not visible).
	check(_mean_speed(sim) < 0.06, "still pile: mean speed %.3f m/s" % _mean_speed(sim))


## Nothing is being drawn: blower off, drum turning slowly. After the draw
## before it, the balls must settle into a pile and stay there (no hopping).
func test_idle_pile_does_not_hop() -> void:
	var sim := _make(75)
	sim.agitation = 1.0
	sim.omega = 9.0
	_run(sim, 90)
	sim.agitation = 0.0
	sim.omega = 0.25
	_run(sim, 240)  # 4 s to settle
	var hits := 0
	var fastest := 0.0
	var highest := -INF
	for i in 240:
		sim.step(DT)
		hits += sim.impacts.size()
		for k in sim.count():
			fastest = maxf(fastest, sim.vel[k].length())
			highest = maxf(highest, sim.pos[k].y)
	eq(hits, 0, "no hard hits (so no sparks) while idle")
	check(fastest < 0.9, "no ball is thrown around: fastest %.2f m/s" % fastest)
	check(highest < 0.0, "the pile stays in the lower half of the drum: highest %.2f" % highest)
	check(_all_inside(sim), "still inside")


func test_hard_hits_are_reported() -> void:
	var sim := _make(75)
	sim.agitation = 1.0
	sim.omega = 9.0
	var ball_hits := 0
	var wall_hits := 0
	for i in 240:
		sim.step(DT)
		for hit in sim.impacts:
			var speed: float = hit.speed
			var a: int = hit.a
			var b: int = hit.b
			var point: Vector3 = hit.point
			check(speed >= sim.impact_speed, "reported hit is above the threshold")
			check(a >= 0 and a < sim.count() and b < sim.count(), "valid ball indices")
			check(point.length() <= sim.radius + sim.ball_r * 1.5, "hit point is inside the drum")
			if b >= 0:
				ball_hits += 1
			else:
				wall_hits += 1
		if sim.impacts.size() > 1:
			var first: float = sim.impacts[0].speed
			var second: float = sim.impacts[1].speed
			check(first >= second, "strongest hit first")
	check(ball_hits > 10, "ball-ball hits seen while spinning: %d" % ball_hits)
	check(wall_hits > 0, "hits on the glass seen while spinning: %d" % wall_hits)


func test_drawn_ball_is_steered_to_the_exit_and_taken_out() -> void:
	var sim := _make(75)
	sim.agitation = 1.0
	sim.omega = 9.0
	_run(sim, 120)
	var exit_point := Vector3(0.0, -0.65, 0.76).normalized() * sim.radius
	var idx := sim.index_of(42)
	check(idx >= 0, "ball 42 is in the drum")
	sim.steer(idx, exit_point)
	_run(sim, 30)  # half a second
	idx = sim.index_of(42)
	check(sim.pos[idx].distance_to(exit_point) < 0.1, "ball 42 is at the exit: %.3f m away" % sim.pos[idx].distance_to(exit_point))
	var taken := sim.remove_at(idx)
	eq(int(taken.num), 42, "the removed ball is 42")
	eq(sim.count(), 74, "74 left")
	eq(sim.index_of(42), -1, "42 is gone")
	var nums := sim.numbers()
	nums.sort()
	var expected: Array[int] = []
	for n in range(1, 76):
		if n != 42:
			expected.append(n)
	eq(nums, expected, "all other numbers are still there")
	check(_all_inside(sim), "still consistent after the removal")
	_run(sim, 30)
	check(_all_inside(sim), "keeps running after the removal")


func test_removing_another_ball_keeps_the_steered_one() -> void:
	var sim := _make(10)
	var last := sim.count() - 1
	var steered_number := sim.num[last]
	sim.steer(last, Vector3(0, -sim.radius, 0))
	sim.remove_at(0)  # the last ball moves into slot 0
	_run(sim, 40)
	var idx := sim.index_of(steered_number)
	check(sim.pos[idx].distance_to(Vector3(0, -sim.radius, 0)) < 0.12, "the steered ball is still the one being pulled")
	eq(sim.remove_at(99).size(), 0, "out-of-range removal is ignored")


func test_999_balls_stay_inside_and_apart() -> void:
	var sim := _make(999)
	eq(sim.count(), 999, "999 balls")
	sim.agitation = 0.6
	sim.omega = 4.0
	_run(sim, 90)
	check(_all_inside(sim), "all 999 inside")
	# The grid broadphase must find every contact, or balls would pile into each other.
	check(sim.max_overlap() < sim.ball_r * 0.9, "overlap %.4f m (ball %.4f m)" % [sim.max_overlap(), sim.ball_r])

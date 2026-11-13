extends RefCounted
## Where the already-drawn balls rest: one lap around the rim of the stage.
##
## Slot 0 (the "head") is the spot the audience sees best — the front of the
## stage. Every time a ball retires from the tray it takes slot 0 and all the
## older ones move one slot CLOCKWISE (seen from above: front -> left -> back
## -> right), so the newest ball is always in front.
##
## Pure layout + bookkeeping (no nodes), see tests/unit/test_ball_ring.gd.

## Smallest ring ball; with more balls than fit, the oldest ones leave the ring.
const MIN_BALL_RADIUS := 0.05
## Free space between neighbours, as a fraction of the diameter.
const GAP := 0.04

## Center of the lap, on the stage surface.
var center := Vector3(0.0, 0.16, 0.15)
var radius := 1.645
## Direction of the head slot in degrees: 0 = front (+Z), positive = clockwise.
var head_deg := 0.0
var ball_r := 0.085
var capacity := 0
## Drawn numbers resting on the ring, newest first (index = slot).
var numbers: Array[int] = []


## Sizes the balls so that a whole game (max_number - 1 retired balls) fits in
## one lap when possible; `base_r` is the size of the balls in the drum.
func configure(max_number: int, base_r: float) -> void:
	var circumference := TAU * radius
	var need := maxi(1, max_number - 1)
	var fit := circumference / (need * 2.0 * (1.0 + GAP))
	ball_r = minf(base_r, maxf(minf(MIN_BALL_RADIUS, base_r), fit))
	capacity = maxi(1, int(floor(circumference / spacing() + 0.0001)))
	if numbers.size() > capacity:
		numbers.resize(capacity)


## Center-to-center distance of neighbours along the lap.
func spacing() -> float:
	var natural := ball_r * 2.0 * (1.0 + GAP)
	# A full lap closes evenly (no odd gap between the oldest and the newest).
	var n := maxi(1, int(floor(TAU * radius / natural + 0.0001)))
	return TAU * radius / n


## Angle of (fractional) slot `k` in radians, clockwise seen from above.
func slot_angle(k: float) -> float:
	return deg_to_rad(head_deg) + k * spacing() / radius


func angle_position(angle: float) -> Vector3:
	return center + Vector3(-sin(angle) * radius, ball_r, cos(angle) * radius)


## Ball center of (fractional) slot `k`.
func slot_position(k: float) -> Vector3:
	return angle_position(slot_angle(k))


## Unit vector of the clockwise travel direction at slot `k`.
func slot_tangent(k: float) -> Vector3:
	var a := slot_angle(k)
	return Vector3(-cos(a), 0.0, -sin(a))


## Replaces the content from the draw order (oldest first), WITHOUT the ball
## that is currently in the tray.
func set_from_draw_order(retired: Array) -> void:
	numbers.clear()
	for i in range(retired.size() - 1, -1, -1):
		if numbers.size() >= capacity:
			break
		numbers.append(int(retired[i]))


## A ball retires to the head; everything else shifts one slot clockwise.
## Returns the number pushed off the end of a full lap (0 = none).
func push(number: int) -> int:
	numbers.push_front(number)
	if numbers.size() > capacity:
		return numbers.pop_back()
	return 0

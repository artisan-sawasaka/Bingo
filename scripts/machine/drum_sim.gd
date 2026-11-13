extends RefCounted
## Visual-only simulation of the numbered balls inside the drum. It NEVER
## decides a draw: GameController picks the number, and the presenter then
## steers that ball to the exit (`steer`) and takes it out (`remove_at`).
##
## One entry per ball that is really left in the game. Positions are relative
## to the drum center (world axes). Besides gravity, the rotating wall and
## ball-ball collisions, an "air blower" keeps the balls moving at random:
##   * an upward jet in the middle column (balls rise there, rain down the sides)
##   * a slowly reversing swirl + per-ball turbulence
##   * random "popcorn" kicks
## `agitation` scales all of it: 0 while idle (the pile rests), 1.0 during a draw.
## Hard hits are reported in `impacts` so the presenter can show sparks.

const GRAVITY := 6.5
const JET := 27.0
const SWIRL := 3.2
const TURBULENCE := 5.0
## Random kicks per ball per second at agitation 1.
const KICK_RATE := 0.85
const DRAG := 0.5
## Extra damping while the blower is off, so the pile settles and stays calm.
const REST_DRAG := 2.2
const WALL_BOUNCE := 1.45   # 1 + restitution
const BALL_BOUNCE := 0.75   # (1 + restitution) / 2
const MAX_RECORDED_IMPACTS := 24

## Radius of the sphere the ball CENTERS stay inside (m).
var radius := 0.6
var ball_r := 0.085
## Drum spin around +X (rad/s).
var omega := 0.0
var agitation := 0.0
var time := 0.0

var pos := PackedVector3Array()
var vel := PackedVector3Array()
var spin := PackedVector3Array()     # angular velocity (rad/s)
var rot: Array[Quaternion] = []
var num := PackedInt32Array()
var flash := PackedFloat32Array()    # hit glow 0..1 (decayed by the presenter)
var _phase := PackedFloat32Array()

## Hits of the last step(), strongest first: { point, speed, a, b, normal }.
## `b` is -1 for the wall. Points are relative to the drum center.
var impacts: Array = []
## Minimum closing speed (m/s) that counts as a visible hit.
var impact_speed := 1.15

var _steer := -1
var _steer_point := Vector3.ZERO
var _rng := RandomNumberGenerator.new()

# broadphase grid (cells of one ball diameter, padded by one cell per side)
var _dim := 0
var _cell := PackedInt32Array()
var _start := PackedInt32Array()
var _fill := PackedInt32Array()
var _sorted := PackedInt32Array()
var _offs := PackedInt32Array()


func _init() -> void:
	_rng.randomize()


func set_seed(s: int) -> void:
	_rng.seed = s


func count() -> int:
	return pos.size()


## Ball radius that keeps `total` balls from over-filling a drum whose wall is
## `wall_radius` away from the center (they should fill about a third of it).
static func ball_radius_for(total: int, wall_radius: float, max_radius: float) -> float:
	if total <= 0:
		return max_radius
	return minf(max_radius, wall_radius * pow(0.2 / float(total), 1.0 / 3.0))


## Replaces all balls: one per entry of `numbers`, stacked loosely at the bottom.
func setup(numbers: Array, p_radius: float, p_ball_r: float) -> void:
	radius = maxf(0.05, p_radius)
	ball_r = maxf(0.005, p_ball_r)
	var n := numbers.size()
	pos.resize(n)
	vel.resize(n)
	spin.resize(n)
	num.resize(n)
	flash.resize(n)
	_phase.resize(n)
	rot.resize(n)
	_steer = -1
	_dim = 0
	impacts.clear()
	var order: Array = numbers.duplicate()
	# Fisher-Yates: which number sits where is purely cosmetic.
	for i in range(order.size() - 1, 0, -1):
		var j := _rng.randi_range(0, i)
		var tmp = order[i]
		order[i] = order[j]
		order[j] = tmp
	var slots := _lattice(n)
	for i in n:
		var p: Vector3
		if i < slots.size():
			p = slots[i]
		else:
			p = Vector3(_rng.randf_range(-0.5, 0.5), _rng.randf_range(-0.2, 0.6), _rng.randf_range(-0.5, 0.5)) * radius
		pos[i] = p
		vel[i] = Vector3.ZERO
		spin[i] = Vector3(_rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0), _rng.randf_range(-2.0, 2.0))
		num[i] = int(order[i])
		flash[i] = 0.0
		_phase[i] = _rng.randf() * TAU
		rot[i] = _random_rotation()


func _random_rotation() -> Quaternion:
	var axis := Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0), _rng.randf_range(-1.0, 1.0))
	if axis.length_squared() < 0.0001:
		axis = Vector3.UP
	return Quaternion(axis.normalized(), _rng.randf() * TAU)


## Non-overlapping start positions, lowest first (a loose cubic stack).
func _lattice(n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	var s := ball_r * 2.06
	var limit := radius - ball_r * 0.1
	var y := -limit
	var layer := 0
	while y <= limit and out.size() < n:
		var rho := sqrt(maxf(0.0, limit * limit - y * y))
		var shift := s * 0.5 if layer % 2 == 1 else 0.0
		var steps := int(rho / s) + 1
		for ix in range(-steps, steps + 1):
			for iz in range(-steps, steps + 1):
				var x := ix * s + shift
				var z := iz * s + shift
				if x * x + z * z <= rho * rho:
					out.append(Vector3(x + _rng.randf_range(-0.004, 0.004), y, z + _rng.randf_range(-0.004, 0.004)))
		y += s * 0.9
		layer += 1
	if out.size() > n:
		out.resize(n)
	return out


func index_of(number: int) -> int:
	return num.find(number)


func numbers() -> Array[int]:
	var out: Array[int] = []
	for v in num:
		out.append(v)
	return out


## Pulls ball `index` toward `point` (the inside of the exit). -1 = release.
func steer(index: int, point: Vector3 = Vector3.ZERO) -> void:
	_steer = index if index >= 0 and index < pos.size() else -1
	_steer_point = point


## Takes a ball out (swap-remove). Returns { pos, rot, num, vel }.
func remove_at(i: int) -> Dictionary:
	var n := pos.size()
	if i < 0 or i >= n:
		return {}
	var out := {"pos": pos[i], "rot": rot[i], "num": num[i], "vel": vel[i]}
	var last := n - 1
	if i != last:
		pos[i] = pos[last]
		vel[i] = vel[last]
		spin[i] = spin[last]
		num[i] = num[last]
		flash[i] = flash[last]
		_phase[i] = _phase[last]
		rot[i] = rot[last]
	pos.resize(last)
	vel.resize(last)
	spin.resize(last)
	num.resize(last)
	flash.resize(last)
	_phase.resize(last)
	rot.resize(last)
	if _steer == i:
		_steer = -1
	elif _steer == last:
		_steer = i
	return out


func step(delta: float) -> void:
	impacts.clear()
	var n := pos.size()
	var frame_dt := minf(delta, 1.0 / 30.0)
	if n == 0 or frame_dt <= 0.0:
		time += frame_dt
		return
	# Measured: 75 balls 0.4 ms, 300 balls 1.6 ms per frame with two substeps.
	# Very large games get one coarser step to stay cheap (999 balls: 5 ms).
	var steps := 2 if n <= 500 else 1
	var dt := frame_dt / steps
	for s in steps:
		time += dt
		_kick(dt)
		_integrate(dt)
		_collide()
	_rotate(frame_dt)
	if impacts.size() > 1:
		impacts.sort_custom(func(a, b): return a.speed > b.speed)


func _kick(dt: float) -> void:
	var n := pos.size()
	var expected := agitation * KICK_RATE * n * dt
	var kicks := int(expected)
	if _rng.randf() < expected - kicks:
		kicks += 1
	var power := 0.55 + 0.45 * minf(agitation, 1.0)
	for k in kicks:
		var i := _rng.randi_range(0, n - 1)
		if i == _steer:
			continue
		vel[i] += Vector3(_rng.randf_range(-1.0, 1.0), _rng.randf_range(1.3, 2.8), _rng.randf_range(-1.0, 1.0)) * power


func _integrate(dt: float) -> void:
	var n := pos.size()
	var big_r := radius
	var r2 := big_r * big_r
	var inv_r := 1.0 / big_r
	var blowing := agitation > 0.001
	var jet := agitation * JET
	var turb := agitation * TURBULENCE
	var swirl := agitation * SWIRL * sin(time * 0.55)
	var core2 := (0.42 * big_r) * (0.42 * big_r)
	var y_lo := -0.3 * big_r
	var y_hi := 0.8 * big_r
	var drag := maxf(0.0, 1.0 - (DRAG + REST_DRAG * (1.0 - clampf(agitation * 4.0, 0.0, 1.0))) * dt)
	var omega_v := Vector3(omega, 0, 0)
	var grip := clampf(9.0 * dt, 0.0, 1.0)
	var t := time
	var thr := impact_speed
	for i in n:
		var p := pos[i]
		var v := vel[i]
		if i == _steer:
			# Spring toward the exit: this ball is about to roll out.
			v += ((_steer_point - p) * 260.0 - v * 30.0) * dt
		else:
			var a := Vector3(0.0, -GRAVITY, 0.0)
			if blowing:
				var c := exp(-(p.x * p.x + p.z * p.z) / core2)
				var up := 1.0 - smoothstep(y_lo, y_hi, p.y)
				var ph := _phase[i]
				a.y += jet * c * up + turb * 0.6 * sin(t * 2.9 + ph * 2.3)
				a.x += turb * sin(t * 2.3 + ph) - swirl * p.z * inv_r
				a.z += turb * sin(t * 1.9 + ph * 1.7) + swirl * p.x * inv_r
			v += a * dt
		v *= drag
		p += v * dt
		var d2 := p.length_squared()
		if d2 > r2:
			var d := sqrt(d2)
			var nrm := p / d
			p = nrm * big_r
			var vn := v.dot(nrm)
			if vn > 0.0:
				v -= nrm * (vn * WALL_BOUNCE)
				if vn > thr and impacts.size() < MAX_RECORDED_IMPACTS:
					impacts.append({"point": p + nrm * ball_r, "speed": vn, "a": i, "b": -1, "normal": nrm})
			# The rotating wall drags the ball along (that is what lifts the pile).
			var rel := v - omega_v.cross(p)
			var slide := rel - nrm * rel.dot(nrm)
			v -= slide * grip
			spin[i] = spin[i].lerp(slide.cross(nrm) / ball_r, 0.25)
		pos[i] = p
		vel[i] = v


## Ball-ball contacts through a uniform grid (cell = one diameter), so the cost
## stays linear for hundreds of balls.
func _collide() -> void:
	var n := pos.size()
	if n < 2:
		return
	var dia := ball_r * 2.0
	var dia2 := dia * dia
	var inv := 1.0 / dia
	var ext := radius + ball_r * 0.5
	var dim := int(ceil(2.0 * ext * inv)) + 3
	if dim != _dim:
		_build_grid(dim)
	if _cell.size() != n:
		_cell.resize(n)
		_sorted.resize(n)
	var cells := dim * dim * dim
	_start.fill(0)
	for i in n:
		var p := pos[i]
		var c := (int((p.x + ext) * inv) + 1) + dim * ((int((p.y + ext) * inv) + 1) + dim * (int((p.z + ext) * inv) + 1))
		c = clampi(c, 0, cells - 1)
		_cell[i] = c
		_start[c + 1] += 1
	for c in cells:
		_start[c + 1] += _start[c]
	for c in cells:
		_fill[c] = _start[c]
	for i in n:
		var c := _cell[i]
		_sorted[_fill[c]] = i
		_fill[c] += 1
	var thr := -impact_speed
	var inv_ball := 1.0 / ball_r
	var last_cell := cells - 1
	var steered := _steer
	for i in n:
		var ca := _cell[i]
		var pi := pos[i]
		for oi in 14:
			var cb := ca + _offs[oi]
			if cb < 0 or cb > last_cell:
				continue
			for k in range(_start[cb], _start[cb + 1]):
				var j := _sorted[k]
				if oi == 0 and j <= i:
					continue
				var dv := pos[j] - pi
				var dist2 := dv.length_squared()
				if dist2 >= dia2 or dist2 < 0.0000001:
					continue
				var dist := sqrt(dist2)
				var n2 := dv / dist
				var pen := dia - dist
				# The ball on its way to the exit is not pushed aside: the others make room.
				var wi := 0.5
				if i == steered:
					wi = 0.0
				elif j == steered:
					wi = 1.0
				pi -= n2 * (pen * wi)
				pos[j] += n2 * (pen * (1.0 - wi))
				var rv := vel[j] - vel[i]
				var closing := rv.dot(n2)
				if closing < 0.0:
					var imp := n2 * (closing * BALL_BOUNCE * 2.0)
					vel[i] += imp * wi
					vel[j] -= imp * (1.0 - wi)
					# The glancing part of the hit makes both balls spin.
					var w := n2.cross(rv) * (inv_ball * 0.5)
					spin[i] = spin[i].lerp(w, 0.3)
					spin[j] = spin[j].lerp(w, 0.3)
					if closing < thr and impacts.size() < MAX_RECORDED_IMPACTS:
						impacts.append({"point": pi + n2 * ball_r, "speed": -closing, "a": i, "b": j, "normal": n2})
		pos[i] = pi
	# Being pushed apart must not move a ball through the glass.
	var r2 := radius * radius
	for i in n:
		var p := pos[i]
		var d2 := p.length_squared()
		if d2 > r2:
			pos[i] = p * (radius / sqrt(d2))


func _build_grid(dim: int) -> void:
	_dim = dim
	var cells := dim * dim * dim
	_start.resize(cells + 1)
	_fill.resize(cells)
	# Own cell first, then the 13 "forward" neighbours (each pair is visited once).
	_offs.resize(14)
	_offs[0] = 0
	var k := 1
	for dz in range(-1, 2):
		for dy in range(-1, 2):
			for dx in range(-1, 2):
				if dz > 0 or (dz == 0 and dy > 0) or (dz == 0 and dy == 0 and dx > 0):
					_offs[k] = dx + dim * (dy + dim * dz)
					k += 1


func _rotate(dt: float) -> void:
	var damp := maxf(0.0, 1.0 - 0.9 * dt)
	for i in pos.size():
		var w := spin[i] * damp
		spin[i] = w
		var len := w.length()
		var ang := len * dt
		if ang > 0.0005:
			rot[i] = (Quaternion(w / len, ang) * rot[i]).normalized()


## Deepest overlap between any two balls, in meters (tests / diagnostics).
func max_overlap() -> float:
	var worst := 0.0
	var dia := ball_r * 2.0
	for i in pos.size():
		for j in range(i + 1, pos.size()):
			worst = maxf(worst, dia - pos[i].distance_to(pos[j]))
	return worst

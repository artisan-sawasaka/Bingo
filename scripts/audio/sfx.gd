extends Node
## Procedurally synthesized sound effects (no external audio assets / licenses).
## Replaceable later by dropping files into res://assets/audio/ with the same
## names (start.ogg / rattle.ogg / riser.ogg / release.ogg / reveal.ogg / pop.ogg /
## finish.ogg / error.ogg).

const RATE := 44100
## Every effect plays on its own bus, so its level is independent of the BGM.
const BUS := "SFX"

var _players := {}
var _streams := {}


func _ready() -> void:
	ensure_bus()
	_streams = {
		"start": _override("start", _make_start()),
		"rattle": _override("rattle", _make_rattle(1.2)),
		"riser": _override("riser", _make_riser(1.2)),
		"pop": _override("pop", _make_pop()),
		"release": _override("release", _make_release()),
		"reveal": _override("reveal", _make_chime([880.0, 1318.5], 1.1)),
		"finish": _override("finish", _make_chime([659.3, 830.6, 987.8, 1318.5], 2.0)),
		"error": _override("error", _make_chime([220.0, 207.7], 0.5)),
	}
	for key in _streams:
		var p := AudioStreamPlayer.new()
		p.stream = _streams[key]
		p.bus = BUS
		add_child(p)
		_players[key] = p


## Sounds still ringing when the app closes would be reported as leaked objects.
func _exit_tree() -> void:
	for key in _players:
		var p: AudioStreamPlayer = _players[key]
		p.stop()


func play(name: String, pitch: float = 1.0, volume_db: float = 0.0) -> void:
	var p: AudioStreamPlayer = _players.get(name)
	if p == null:
		return
	p.pitch_scale = pitch
	p.volume_db = volume_db
	p.play()


func stop(name: String) -> void:
	var p: AudioStreamPlayer = _players.get(name)
	if p != null:
		p.stop()


func is_playing(name: String) -> bool:
	var p: AudioStreamPlayer = _players.get(name)
	return p != null and p.playing


static func ensure_bus() -> int:
	var bus := AudioServer.get_bus_index(BUS)
	if bus < 0:
		AudioServer.add_bus()
		bus = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus, BUS)
		AudioServer.set_bus_send(bus, "Master")
	return bus


## Level of all sound effects, 0..1 (the BGM has its own level, see bgm.gd).
static func set_volume(linear: float) -> void:
	var bus := ensure_bus()
	AudioServer.set_bus_volume_db(bus, linear_to_db(clampf(linear, 0.0001, 1.0)))
	AudioServer.set_bus_mute(bus, linear <= 0.001)


static func get_volume() -> float:
	var bus := ensure_bus()
	if AudioServer.is_bus_mute(bus):
		return 0.0
	return db_to_linear(AudioServer.get_bus_volume_db(bus))


func _override(name: String, fallback: AudioStream) -> AudioStream:
	for ext in ["ogg", "wav", "mp3"]:
		var p := "res://assets/audio/%s.%s" % [name, ext]
		if ResourceLoader.exists(p):
			var s = load(p)
			if s is AudioStream:
				return s
	return fallback


static func _to_wav(samples: PackedFloat32Array) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		var v := int(clampf(samples[i], -1.0, 1.0) * 32767.0)
		data.encode_s16(i * 2, v)
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w


static func _make_start() -> AudioStreamWAV:
	# Mechanical "clunk": low thump + short noise burst.
	var n := int(RATE * 0.25)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	for i in n:
		var t := float(i) / RATE
		var thump := sin(TAU * (90.0 - 40.0 * t) * t) * exp(-t * 22.0)
		var click := rng.randf_range(-1.0, 1.0) * exp(-t * 90.0) * 0.5
		s[i] = (thump * 0.8 + click) * 0.8
	return _to_wav(s)


static func _make_rattle(length: float) -> AudioStreamWAV:
	# Balls tumbling: random clicks whose density follows the drum speed curve.
	var n := int(RATE * length)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 23
	var i := 0
	while i < n:
		var u := float(i) / n
		var speed := sin(u * PI)  # accelerate then decelerate
		var gap := int(RATE * lerpf(0.06, 0.012, speed))
		var amp := 0.25 + 0.35 * speed
		var freq := rng.randf_range(1800.0, 3200.0)
		var dur := int(RATE * 0.012)
		for k in dur:
			if i + k >= n:
				break
			var t := float(k) / RATE
			s[i + k] += sin(TAU * freq * t) * exp(-t * 400.0) * amp * rng.randf_range(0.6, 1.0)
		i += maxi(1, gap + rng.randi_range(-gap / 3, gap / 3))
	return _to_wav(s)


static func _make_riser(length: float) -> AudioStreamWAV:
	# Anticipation while the drum spins: a soft tone gliding upward with a
	# quickening flutter, fading in and cut off just before the ball drops.
	var n := int(RATE * length)
	var s := PackedFloat32Array()
	s.resize(n)
	var ph := 0.0
	var flutter := 0.0
	for i in n:
		var u := float(i) / n
		ph += TAU * lerpf(260.0, 780.0, u * u) / RATE
		flutter += TAU * lerpf(5.0, 17.0, u) / RATE
		var env := smoothstep(0.0, 0.25, u) * (1.0 - smoothstep(0.9, 1.0, u))
		s[i] = (sin(ph) + 0.3 * sin(ph * 2.0)) * (0.6 + 0.4 * sin(flutter)) * env * 0.3
	return _to_wav(s)


static func _make_pop() -> AudioStreamWAV:
	# Bright "pop" under the reveal chime: a fast downward chirp plus a tick of noise.
	var n := int(RATE * 0.16)
	var s := PackedFloat32Array()
	s.resize(n)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var ph := 0.0
	for i in n:
		var t := float(i) / RATE
		ph += TAU * (420.0 + 1500.0 * exp(-t * 45.0)) / RATE
		var tick := rng.randf_range(-1.0, 1.0) * exp(-t * 220.0) * 0.35
		s[i] = (sin(ph) * exp(-t * 26.0) * 0.75 + tick) * minf(1.0, i / 20.0)
	return _to_wav(s)


static func _make_release() -> AudioStreamWAV:
	# Ball dropping into the chute: two soft knocks + roll.
	var n := int(RATE * 0.45)
	var s := PackedFloat32Array()
	s.resize(n)
	for i in n:
		var t := float(i) / RATE
		var knock1 := sin(TAU * 520.0 * t) * exp(-t * 60.0)
		var t2 := maxf(0.0, t - 0.12)
		var knock2 := sin(TAU * 430.0 * t2) * exp(-t2 * 50.0) * (1.0 if t >= 0.12 else 0.0)
		var roll := sin(TAU * 140.0 * t + sin(TAU * 31.0 * t) * 2.0) * 0.15 * exp(-t * 6.0)
		s[i] = (knock1 * 0.6 + knock2 * 0.5 + roll) * 0.7
	return _to_wav(s)


static func _make_chime(freqs: Array, length: float) -> AudioStreamWAV:
	var n := int(RATE * length)
	var s := PackedFloat32Array()
	s.resize(n)
	var step := 0.09
	for i in n:
		var t := float(i) / RATE
		var v := 0.0
		for k in freqs.size():
			var tk := t - k * step
			if tk < 0.0:
				continue
			var f: float = freqs[k]
			var env := exp(-tk * 3.2) * minf(1.0, tk * 400.0)
			v += (sin(TAU * f * tk) + 0.35 * sin(TAU * f * 2.0 * tk) + 0.12 * sin(TAU * f * 3.01 * tk)) * env
		s[i] = v * 0.22
	return _to_wav(s)

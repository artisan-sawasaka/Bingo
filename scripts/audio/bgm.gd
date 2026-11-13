extends Node
## Quiet background music, synthesized at startup (no external audio assets /
## licenses): a 16-bar mellow loop — soft electric-piano chords, a round bass,
## a sparse vibraphone melody and a light shaker.
##
## The loop is rendered once on a worker thread (about 38 s of audio; the app
## never waits for it) and then plays seamlessly: notes that ring past the end
## wrap around to the beginning. It ducks while a number is being drawn so the
## machine's sounds stay in front.
## Replaceable by dropping res://assets/audio/bgm.ogg (or .wav / .mp3).

const RATE := 22050
const BPM := 100.0
const BARS := 16
## Loudest sample after normalization (headroom for the effects on top).
const PEAK := 0.6
## Level while a draw is running, relative to the normal level.
const DUCK := 0.42

## One chord per bar: [bass MIDI note, [chord MIDI notes]].
const CHORDS := {
	"C": [48, [55, 59, 60, 64]],    # Cmaj7
	"Am": [45, [55, 57, 60, 64]],   # Am7
	"Dm": [50, [53, 57, 60, 62]],   # Dm7
	"G": [43, [53, 55, 59, 62]],    # G7
	"F": [41, [53, 57, 60, 64]],    # Fmaj7
	"Em": [40, [52, 55, 59, 62]],   # Em7
}
const PROGRESSION := ["C", "Am", "Dm", "G", "C", "Am", "Dm", "G", "F", "Em", "Dm", "G", "F", "Em", "Dm", "G"]
## Melody per bar: [eighth-note slot 0..7, MIDI note, length in slots].
const MELODY := [
	[[0, 76, 2], [2, 79, 1], [3, 81, 3], [6, 79, 2]],
	[[0, 76, 3], [3, 74, 1], [4, 72, 4]],
	[[0, 74, 2], [2, 77, 1], [3, 81, 3], [6, 77, 2]],
	[[0, 79, 3], [3, 76, 1], [4, 74, 4]],
	[[0, 76, 2], [2, 79, 1], [3, 84, 3], [6, 83, 2]],
	[[0, 81, 3], [3, 79, 1], [4, 76, 4]],
	[[0, 77, 2], [2, 81, 1], [3, 86, 3], [6, 84, 2]],
	[[0, 83, 3], [3, 81, 1], [4, 79, 4]],
	[[1, 81, 1], [2, 84, 2], [4, 81, 1], [5, 79, 3]],
	[[1, 79, 1], [2, 83, 2], [4, 79, 1], [5, 76, 3]],
	[[1, 77, 1], [2, 81, 2], [4, 77, 1], [5, 74, 3]],
	[[0, 79, 2], [2, 81, 2], [4, 83, 2], [6, 86, 2]],
	[[1, 81, 1], [2, 84, 2], [4, 88, 1], [5, 84, 3]],
	[[1, 79, 1], [2, 83, 2], [4, 86, 1], [5, 83, 3]],
	[[0, 81, 2], [2, 77, 2], [4, 74, 2], [6, 77, 2]],
	[[0, 79, 4], [4, 71, 2], [6, 74, 2]],
]

static var _cached: AudioStream = null

## 0..1 (settings, independent of the sound-effect level). 0 or `enabled = false` = silent.
var volume := 0.3
var enabled := true

var _player: AudioStreamPlayer
var _thread: Thread = null
var _cancel := false
var _ducked := false
var _level := 0.0     # current linear gain (smoothed)
var _ready_to_play := false


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.bus = "Master"
	_player.volume_db = -80.0
	add_child(_player)
	var custom := _override()
	if custom != null:
		_start(custom)
	elif _cached != null:
		_start(_cached)
	elif DisplayServer.get_name() != "headless":
		# Tests / headless tools have no audio output: nothing to render for.
		_thread = Thread.new()
		_thread.start(_render_job)


func _exit_tree() -> void:
	_cancel = true
	if _player != null:
		_player.stop()
	if _thread != null:
		_thread.wait_to_finish()
		_thread = null


func is_ready() -> bool:
	return _ready_to_play


func is_audible() -> bool:
	return _ready_to_play and enabled and volume > 0.001


func set_level(p_volume: float, p_enabled: bool) -> void:
	volume = clampf(p_volume, 0.0, 1.0)
	enabled = p_enabled


## Lower the music while a number is being drawn.
func set_ducked(on: bool) -> void:
	_ducked = on


func _process(delta: float) -> void:
	if _thread != null and not _thread.is_alive():
		var stream = _thread.wait_to_finish()
		_thread = null
		if stream is AudioStream:
			_cached = stream
			_start(stream)
	if not _ready_to_play:
		return
	var target := 0.0
	if enabled:
		target = volume * (DUCK if _ducked else 1.0)
	# Quick dip when a draw starts, slow swell back.
	var rate := 1.6 if target < _level else 0.45
	_level = move_toward(_level, target, delta * rate)
	if _level <= 0.0005:
		if not _player.stream_paused:
			_player.stream_paused = true
	else:
		if _player.stream_paused:
			_player.stream_paused = false
		_player.volume_db = linear_to_db(_level)


func _start(stream: AudioStream) -> void:
	_player.stream = stream
	_player.volume_db = -80.0
	_player.play()
	_player.stream_paused = true
	_level = 0.0
	_ready_to_play = true


func _override() -> AudioStream:
	for ext in ["ogg", "wav", "mp3"]:
		var p := "res://assets/audio/bgm.%s" % ext
		if ResourceLoader.exists(p):
			var s = load(p)
			if s is AudioStreamWAV:
				if s.loop_mode == AudioStreamWAV.LOOP_DISABLED:
					s.loop_mode = AudioStreamWAV.LOOP_FORWARD
				return s
			if s is AudioStream:
				if "loop" in s:
					s.loop = true
				return s
	return null


func _render_job() -> AudioStream:
	var data := render(BARS, func(): return _cancel)
	if data.is_empty():
		return null
	return make_stream(data)


# ---------------------------------------------------------------- synthesis

static func frames_for(bars: int) -> int:
	return int(round(bars * 4.0 * 60.0 / BPM * RATE))


static func make_stream(data: PackedByteArray) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = true
	w.data = data
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = data.size() / 4
	return w


## Renders `bars` bars as interleaved 16-bit stereo. `cancelled` (optional
## Callable -> bool) is polled between notes; an empty array means cancelled.
static func render(bars: int = BARS, cancelled: Callable = Callable()) -> PackedByteArray:
	var total := frames_for(bars)
	var left := PackedFloat32Array()
	var right := PackedFloat32Array()
	left.resize(total)
	right.resize(total)
	var beat := 60.0 / BPM * RATE          # frames per beat
	var slot := beat * 0.5                  # frames per eighth note
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261111
	for bar in bars:
		if cancelled.is_valid() and cancelled.call():
			return PackedByteArray()
		var chord: Array = CHORDS[PROGRESSION[bar % PROGRESSION.size()]]
		var root: int = chord[0]
		var notes: Array = chord[1]
		var t0 := bar * 4.0 * beat
		# --- electric piano: the chord on beat 1, an answer on the "and" of 2
		for hit in [[0.0, 1.0, 3.2], [1.5, 0.62, 2.0]]:
			var when: float = hit[0]
			var gain: float = hit[1]
			var beats: float = hit[2]
			for i in notes.size():
				var midi: int = notes[i]
				# Rolled a little, low to high, like a hand on the keys.
				var start := int(t0 + when * beat + i * 0.012 * RATE)
				var pan := -0.35 + 0.7 * float(i) / maxf(1.0, notes.size() - 1.0)
				_tone(left, right, start, int(beats * beat), _hz(midi), 0.11 * gain, pan, 0.75, 0.3, 0.3, 0.06, 0.05, 0.004)
		if cancelled.is_valid() and cancelled.call():
			return PackedByteArray()
		# --- bass: root, a light push, the fifth, a pickup into the next bar
		for hit in [[0.0, root, 1.0, 1.4], [1.5, root, 0.45, 0.45], [2.0, root + 7, 0.8, 1.2], [3.5, root, 0.5, 0.45]]:
			var when: float = hit[0]
			var midi: int = hit[1]
			var gain: float = hit[2]
			var beats: float = hit[3]
			_tone(left, right, int(t0 + when * beat), int(beats * beat), _hz(midi), 0.3 * gain, 0.0, 0.5, 0.4, 0.35, 0.0, 0.1, 0.008)
		# --- vibraphone melody
		var line: Array = MELODY[bar % MELODY.size()]
		for note in line:
			var s: int = note[0]
			var midi: int = note[1]
			var len_slots: int = note[2]
			_tone(left, right, int(t0 + s * slot), int((len_slots + 2.5) * slot), _hz(midi), 0.16, 0.25, 0.55, 0.0, 0.2, 0.22, 0.035, 0.003)
		# --- shaker on every eighth (offbeats a bit stronger), soft thump on 1 and 3
		for s in 8:
			var accent := 1.0 if s % 2 == 1 else 0.55
			_shaker(left, right, int(t0 + s * slot), 0.035 * accent, rng, 0.3 if s % 2 == 1 else -0.3)
		for b in [0.0, 2.0]:
			var when: float = b
			_thump(left, right, int(t0 + when * beat), 0.22)
	if cancelled.is_valid() and cancelled.call():
		return PackedByteArray()
	# Normalize and pack.
	var peak := 0.0001
	for i in total:
		peak = maxf(peak, maxf(absf(left[i]), absf(right[i])))
	var k := PEAK / peak * 32767.0
	var data := PackedByteArray()
	data.resize(total * 4)
	for i in total:
		data.encode_s16(i * 4, int(clampf(left[i] * k, -32767.0, 32767.0)))
		data.encode_s16(i * 4 + 2, int(clampf(right[i] * k, -32767.0, 32767.0)))
	return data


static func _hz(midi: int) -> float:
	return 440.0 * pow(2.0, (midi - 69) / 12.0)


## One decaying note: fundamental + 2nd harmonic + a short bright partial.
## Frames past the end of the buffer wrap around (seamless loop).
##   decay: time constant of the fundamental (s); h2 / h2_decay: 2nd harmonic
##   level and time constant; bell / bell_decay: 4th harmonic ("tine") ditto.
static func _tone(left: PackedFloat32Array, right: PackedFloat32Array, start: int, frames: int, freq: float, amp: float, pan: float,
		decay: float, h2: float, h2_decay: float, bell: float, bell_decay: float, attack: float) -> void:
	var total := left.size()
	if total == 0 or frames <= 0:
		return
	var w := TAU * freq / RATE
	var gl := amp * sqrt(0.5 * (1.0 - pan))
	var gr := amp * sqrt(0.5 * (1.0 + pan))
	var env := 1.0
	var env_k := exp(-1.0 / (decay * RATE))
	var e2 := h2
	var e2_k := exp(-1.0 / (maxf(0.001, h2_decay) * RATE))
	var e4 := bell
	var e4_k := exp(-1.0 / (maxf(0.001, bell_decay) * RATE))
	var attack_frames := maxf(1.0, attack * RATE)
	var release := maxi(1, mini(frames / 2, int(0.03 * RATE)))
	var ph := 0.0
	var idx := posmod(start, total)
	for i in frames:
		var a := env
		if i < attack_frames:
			a *= i / attack_frames
		if i >= frames - release:
			a *= float(frames - i) / release
		var s := (sin(ph) + e2 * sin(ph * 2.0) + e4 * sin(ph * 4.0)) * a
		left[idx] += s * gl
		right[idx] += s * gr
		ph += w
		env *= env_k
		e2 *= e2_k
		e4 *= e4_k
		idx += 1
		if idx >= total:
			idx = 0


static func _shaker(left: PackedFloat32Array, right: PackedFloat32Array, start: int, amp: float, rng: RandomNumberGenerator, pan: float) -> void:
	var total := left.size()
	var frames := int(0.07 * RATE)
	var gl := amp * sqrt(0.5 * (1.0 - pan))
	var gr := amp * sqrt(0.5 * (1.0 + pan))
	var prev := 0.0
	var env := 1.0
	var env_k := exp(-1.0 / (0.018 * RATE))
	var idx := posmod(start, total)
	for i in frames:
		var n := rng.randf_range(-1.0, 1.0)
		var s := (n - prev) * env * minf(1.0, i / 40.0)  # difference = crude high-pass
		prev = n
		left[idx] += s * gl
		right[idx] += s * gr
		env *= env_k
		idx += 1
		if idx >= total:
			idx = 0


static func _thump(left: PackedFloat32Array, right: PackedFloat32Array, start: int, amp: float) -> void:
	var total := left.size()
	var frames := int(0.22 * RATE)
	var ph := 0.0
	var idx := posmod(start, total)
	for i in frames:
		var t := float(i) / RATE
		ph += TAU * (48.0 + 55.0 * exp(-t * 28.0)) / RATE
		var s := sin(ph) * exp(-t * 16.0) * minf(1.0, i / 30.0) * amp * 0.7071
		left[idx] += s
		right[idx] += s
		idx += 1
		if idx >= total:
			idx = 0

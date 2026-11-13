extends "res://tests/test_case.gd"
## Synthesized background music: a seamless stereo loop with headroom.

const Bgm = preload("res://scripts/audio/bgm.gd")


func test_loop_is_audible_but_has_headroom() -> void:
	var bars := 2
	var data: PackedByteArray = Bgm.render(bars)
	var frames: int = Bgm.frames_for(bars)
	eq(data.size(), frames * 4, "16-bit stereo for exactly %d bars" % bars)
	var peak := 0
	var energy := 0.0
	var differs := false
	for i in frames:
		var l := data.decode_s16(i * 4)
		var r := data.decode_s16(i * 4 + 2)
		peak = maxi(peak, maxi(absi(l), absi(r)))
		energy += float(l) * l + float(r) * r
		if l != r:
			differs = true
	var rms := sqrt(energy / (frames * 2.0)) / 32767.0
	check(peak <= int(Bgm.PEAK * 32767.0) + 1, "never louder than the headroom limit: %d" % peak)
	check(peak > 12000, "normalized: peak %d" % peak)
	check(rms > 0.03 and rms < 0.3, "soft but audible: rms %.3f" % rms)
	check(differs, "stereo")


func test_notes_wrap_around_the_loop_point() -> void:
	# The last bass pickup / melody notes ring into the first frames of the loop.
	var one: PackedByteArray = Bgm.render(1)
	var frames: int = Bgm.frames_for(1)
	var head := 0
	for i in 200:
		head = maxi(head, absi(one.decode_s16(i * 4)))
	check(head > 0, "sound at frame 0 (first beat)")
	# No step at the seam: last and first samples are close together.
	var last := one.decode_s16((frames - 1) * 4)
	var first := one.decode_s16(0)
	check(absi(first - last) < 6000, "no click at the loop point: %d -> %d" % [last, first])


func test_stream_loops_forever() -> void:
	var data: PackedByteArray = Bgm.render(1)
	var stream: AudioStreamWAV = Bgm.make_stream(data)
	eq(stream.loop_mode, AudioStreamWAV.LOOP_FORWARD, "loops")
	eq(stream.loop_begin, 0, "from the start")
	eq(stream.loop_end, Bgm.frames_for(1), "to the last frame")
	check(stream.stereo, "stereo")
	eq(stream.mix_rate, Bgm.RATE, "mix rate")
	check(absf(stream.get_length() - 2.4) < 0.01, "one bar at 100 BPM is 2.4 s: %.3f" % stream.get_length())


func test_render_can_be_cancelled() -> void:
	var data: PackedByteArray = Bgm.render(4, func(): return true)
	eq(data.size(), 0, "cancelled render returns nothing")


func test_score_is_complete() -> void:
	eq(Bgm.PROGRESSION.size(), Bgm.BARS, "one chord per bar")
	eq(Bgm.MELODY.size(), Bgm.BARS, "one melody line per bar")
	for chord_name in Bgm.PROGRESSION:
		check(Bgm.CHORDS.has(chord_name), "chord %s is defined" % chord_name)
	for bar in Bgm.MELODY:
		for note in bar:
			var slot: int = note[0]
			var midi: int = note[1]
			check(slot >= 0 and slot < 8, "melody slot inside the bar")
			check(midi >= 60 and midi <= 96, "melody stays in a gentle register: %d" % midi)


func test_level_follows_settings_and_ducks() -> void:
	var bgm = Bgm.new()
	add_child(bgm)
	# Headless: nothing is rendered, the node just stays silent.
	check(not bgm.is_audible(), "silent until a stream is ready")
	bgm._start(Bgm.make_stream(Bgm.render(1)))
	bgm.set_level(0.4, true)
	for i in 200:
		bgm._process(0.05)
	check(absf(bgm._level - 0.4) < 0.001, "reaches the set level")
	check(bgm.is_audible(), "audible")
	bgm.set_ducked(true)
	for i in 200:
		bgm._process(0.05)
	check(absf(bgm._level - 0.4 * Bgm.DUCK) < 0.001, "lower while a number is drawn")
	bgm.set_ducked(false)
	bgm.set_level(0.4, false)
	for i in 200:
		bgm._process(0.05)
	eq(bgm._level, 0.0, "off")
	check(bgm._player.stream_paused, "paused while off")
	check(not bgm.is_audible(), "not audible when switched off")
	bgm.queue_free()

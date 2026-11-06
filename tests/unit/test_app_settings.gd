extends "res://tests/test_case.gd"

const AppSettings = preload("res://scripts/core/app_settings.gd")


func test_fixed_speeds_are_returned_as_is() -> void:
	var s := AppSettings.new("user://test_tmp/unused.json")
	var rng := RandomNumberGenerator.new()
	for k in ["short", "normal", "long"]:
		s.speed = k
		for i in 5:
			eq(s.pick_speed(rng), k, "fixed " + k)


func test_random_picks_each_of_the_three() -> void:
	var s := AppSettings.new("user://test_tmp/unused.json")
	s.speed = "random"
	var rng := RandomNumberGenerator.new()
	rng.seed = 1234
	var seen := {}
	for i in 300:
		var k := s.pick_speed(rng)
		check(k in ["short", "normal", "long"], "random gave " + k)
		seen[k] = int(seen.get(k, 0)) + 1
	eq(seen.size(), 3, "all three speeds occur")
	for k in seen:
		check(seen[k] > 60, "%s chosen %d/300 times" % [k, seen[k]])


func test_timing_and_watchdog_length() -> void:
	eq(AppSettings.timing_for("normal").reveal_end, 2.4, "normal 2.4s")
	check(absf(AppSettings.timing_for("short").reveal_end - 1.8) < 0.001, "short 1.8s")
	check(absf(AppSettings.timing_for("long").reveal_end - 3.12) < 0.001, "long 3.12s")
	var s := AppSettings.new("user://test_tmp/unused.json")
	s.speed = "random"
	check(absf(s.max_reveal_sec() - 3.12) < 0.001, "random watchdog covers the longest")
	s.speed = "short"
	check(absf(s.max_reveal_sec() - 1.8) < 0.001, "short watchdog")


func test_random_survives_save_and_load() -> void:
	var dir := scratch_dir("settings_random")
	var s := AppSettings.new(dir + "settings.json")
	s.speed = "random"
	s.save_file()
	var s2 := AppSettings.new(dir + "settings.json")
	s2.load_file()
	eq(s2.speed, "random", "random persisted")
	var f := FileAccess.open(dir + "settings.json", FileAccess.WRITE)
	f.store_string("{\"speed\": \"turbo\"}")
	f.close()
	var s3 := AppSettings.new(dir + "settings.json")
	s3.load_file()
	eq(s3.speed, "normal", "unknown value ignored")

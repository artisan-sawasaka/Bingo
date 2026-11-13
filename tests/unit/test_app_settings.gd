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


func test_bgm_settings_survive_save_and_load() -> void:
	var dir := scratch_dir("settings_bgm")
	var s := AppSettings.new(dir + "settings.json")
	check(s.bgm_enabled, "BGM is on by default")
	check(s.bgm_volume > 0.0 and s.bgm_volume <= 0.5, "default BGM level is modest: %.2f" % s.bgm_volume)
	s.bgm_volume = 0.15
	s.bgm_enabled = false
	s.save_file()
	var s2 := AppSettings.new(dir + "settings.json")
	s2.load_file()
	check(absf(s2.bgm_volume - 0.15) < 0.0001, "BGM level persisted")
	check(not s2.bgm_enabled, "BGM off persisted")
	var f := FileAccess.open(dir + "settings.json", FileAccess.WRITE)
	f.store_string("{\"bgm_volume\": 7, \"bgm_enabled\": \"yes\"}")
	f.close()
	var s3 := AppSettings.new(dir + "settings.json")
	s3.load_file()
	eq(s3.bgm_volume, 1.0, "out-of-range level is clamped")
	check(s3.bgm_enabled, "non-boolean switch is ignored")
	# Settings written by an earlier version (no BGM keys) keep the defaults.
	f = FileAccess.open(dir + "settings.json", FileAccess.WRITE)
	f.store_string("{\"volume\": 0.5}")
	f.close()
	var s4 := AppSettings.new(dir + "settings.json")
	s4.load_file()
	check(s4.bgm_enabled and absf(s4.bgm_volume - 0.3) < 0.0001, "old settings file: BGM defaults")


func test_effects_switch_survives_save_and_load() -> void:
	var dir := scratch_dir("settings_effects")
	var s := AppSettings.new(dir + "settings.json")
	check(s.effects_high, "extras are on by default")
	s.effects_high = false
	s.save_file()
	var s2 := AppSettings.new(dir + "settings.json")
	s2.load_file()
	check(not s2.effects_high, "light mode persisted")
	var f := FileAccess.open(dir + "settings.json", FileAccess.WRITE)
	f.store_string("{\"effects_high\": \"no\"}")
	f.close()
	var s3 := AppSettings.new(dir + "settings.json")
	s3.load_file()
	check(s3.effects_high, "non-boolean value is ignored")


func test_se_and_bgm_levels_are_separate_settings() -> void:
	var dir := scratch_dir("settings_levels")
	var s := AppSettings.new(dir + "settings.json")
	check(absf(s.se_volume - 0.8) < 0.0001, "default SE level")
	s.se_volume = 0.25
	s.bgm_volume = 0.6
	s.save_file()
	var s2 := AppSettings.new(dir + "settings.json")
	s2.load_file()
	check(absf(s2.se_volume - 0.25) < 0.0001, "SE level persisted on its own")
	check(absf(s2.bgm_volume - 0.6) < 0.0001, "BGM level persisted on its own")
	var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(dir + "settings.json"))
	check(saved.has("se_volume") and saved.has("bgm_volume") and not saved.has("volume"), "file has the two levels, no overall volume")
	# A file from before the split: the single "volume" becomes the SE level.
	var f := FileAccess.open(dir + "settings.json", FileAccess.WRITE)
	f.store_string("{\"volume\": 0.5}")
	f.close()
	var old := AppSettings.new(dir + "settings.json")
	old.load_file()
	check(absf(old.se_volume - 0.5) < 0.0001, "old overall volume -> SE level")
	check(absf(old.bgm_volume - 0.3) < 0.0001, "BGM keeps its default")
	# ...and a BGM level saved relative to that volume keeps its loudness.
	f = FileAccess.open(dir + "settings.json", FileAccess.WRITE)
	f.store_string("{\"volume\": 0.5, \"bgm_volume\": 0.4}")
	f.close()
	var mid := AppSettings.new(dir + "settings.json")
	mid.load_file()
	check(absf(mid.se_volume - 0.5) < 0.0001, "SE from the old volume")
	check(absf(mid.bgm_volume - 0.2) < 0.0001, "relative BGM level converted: %.3f" % mid.bgm_volume)
	# The new key wins over a leftover old one and nothing is rescaled.
	f = FileAccess.open(dir + "settings.json", FileAccess.WRITE)
	f.store_string("{\"volume\": 0.1, \"se_volume\": 0.7, \"bgm_volume\": 0.4}")
	f.close()
	var cur := AppSettings.new(dir + "settings.json")
	cur.load_file()
	check(absf(cur.se_volume - 0.7) < 0.0001 and absf(cur.bgm_volume - 0.4) < 0.0001, "new keys are used as they are")


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

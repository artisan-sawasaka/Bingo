extends "res://tests/test_case.gd"

const GameState = preload("res://scripts/core/game_state.gd")
const RandomSource = preload("res://scripts/core/random_source.gd")


func test_validate_text_boundaries() -> void:
	eq(GameState.validate_max_number_text("75").ok, true, "75")
	eq(GameState.validate_max_number_text("75").value, 75, "75 value")
	eq(GameState.validate_max_number_text("1").ok, true, "1")
	eq(GameState.validate_max_number_text("999").ok, true, "999")
	eq(GameState.validate_max_number_text(" 30 ").value, 30, "trim")
	for bad in ["", "   ", "0", "-1", "-75", "1000", "99999999999999999999", "7.5", "1e2", "abc", "７５", "+5", "0x10", "75a"]:
		eq(GameState.validate_max_number_text(bad).ok, false, "reject '%s'" % bad)


func test_create_invalid_returns_null() -> void:
	var rng := RandomSource.seeded(1)
	check(GameState.create(0, rng) == null, "0")
	check(GameState.create(-5, rng) == null, "negative")
	check(GameState.create(1000, rng) == null, "1000")
	check(GameState.create(1, rng) != null, "1 ok")


func test_75_draws_unique_then_exhausted() -> void:
	var rng := RandomSource.secure()
	var s = GameState.create(75, rng)
	var seen := {}
	for i in 75:
		var n: int = s.draw(rng, "req-%08d" % i)
		check(n >= 1 and n <= 75, "range %d" % n)
		check(not seen.has(n), "duplicate %d at draw %d" % [n, i + 1])
		seen[n] = true
	eq(seen.size(), 75, "all drawn")
	check(s.is_finished(), "finished")
	eq(s.draw(rng, "req-extra-76"), 0, "76th draw must fail")
	eq(s.drawn.size(), 75, "still 75")
	eq(s.version, 76, "version")


func test_boundary_999_and_1() -> void:
	var rng := RandomSource.seeded(42)
	var s = GameState.create(999, rng)
	var seen := {}
	for i in 999:
		var n: int = s.draw(rng, "")
		if seen.has(n):
			fail("duplicate %d" % n)
			return
		seen[n] = true
	check(s.is_finished(), "999 finished")
	var one = GameState.create(1, rng)
	eq(one.draw(rng, ""), 1, "only number")
	check(one.is_finished(), "1 finished")


func test_uniformity_rough() -> void:
	# First draw of a 5-number game, 5000 trials: each bucket ~1000 (±20%).
	var rng := RandomSource.secure()
	var counts := [0, 0, 0, 0, 0, 0]
	for t in 5000:
		var s = GameState.create(5, rng)
		counts[s.draw(rng, "")] += 1
	for n in range(1, 6):
		check(counts[n] > 800 and counts[n] < 1200, "bucket %d = %d" % [n, counts[n]])


func test_roundtrip_and_request_log() -> void:
	var rng := RandomSource.seeded(7)
	var s = GameState.create(75, rng)
	for i in 10:
		s.draw(rng, "request-%04d" % i)
	var text := JSON.stringify(s.to_dict())
	var res := GameState.from_dict(JSON.parse_string(text))
	check(res.ok, "roundtrip ok: %s" % res.error)
	var r = res.state
	eq(r.drawn, s.drawn, "order")
	eq(r.remaining, s.remaining, "remaining")
	eq(r.version, s.version, "version")
	eq(r.find_request("request-0003"), 4, "request index")
	eq(r.find_request("unknown-req"), -1, "unknown")


func test_from_dict_rejects_tampered() -> void:
	var rng := RandomSource.seeded(3)
	var s = GameState.create(10, rng)
	s.draw(rng, "")
	s.draw(rng, "")
	var base: Dictionary = JSON.parse_string(JSON.stringify(s.to_dict()))
	var dup := base.duplicate(true)
	dup.remaining.append(dup.drawn[0])
	check(not GameState.from_dict(dup).ok, "duplicate number")
	var missing := base.duplicate(true)
	missing.remaining.remove_at(0)
	check(not GameState.from_dict(missing).ok, "missing number")
	var outr := base.duplicate(true)
	outr.remaining[0] = 11
	check(not GameState.from_dict(outr).ok, "out of range")
	var badv := base.duplicate(true)
	badv.version = 99
	check(not GameState.from_dict(badv).ok, "version mismatch")
	var badmax := base.duplicate(true)
	badmax.max_number = 0
	check(not GameState.from_dict(badmax).ok, "max 0")
	var frac := base.duplicate(true)
	frac.drawn[0] = 1.5
	check(not GameState.from_dict(frac).ok, "fractional")
	check(not GameState.from_dict("x").ok, "string")
	check(not GameState.from_dict(null).ok, "null")


func test_new_game_ids_roundtrip_and_validation() -> void:
	var rng := RandomSource.seeded(11)
	var s = GameState.create(75, rng)
	s.set_new_game_origin("phone-ng-0002", ["phone-ng-0001", "bad id", "x"])
	eq(s.new_game_ids, ["phone-ng-0001", "phone-ng-0002"] as Array[String], "valid ids kept in order")
	var d: Dictionary = JSON.parse_string(JSON.stringify(s.to_dict()))
	var r := GameState.from_dict(d)
	eq(r.state.new_game_ids, s.new_game_ids, "persisted")
	d.erase("new_game_ids")
	check(GameState.from_dict(d).ok, "older saves without the field still load")
	d["new_game_ids"] = ["<script>", 5, "ok-id-12345"]
	eq(GameState.from_dict(d).state.new_game_ids, ["ok-id-12345"] as Array[String], "invalid entries dropped")
	var many: Array = []
	for i in 30:
		many.append("ng-id-%04d" % i)
	s.set_new_game_origin("ng-last-0001", many)
	eq(s.new_game_ids.size(), GameState.NEW_GAME_ID_LIMIT, "capped")
	eq(s.new_game_ids[-1], "ng-last-0001", "newest kept")


func test_clone_is_independent() -> void:
	var rng := RandomSource.seeded(9)
	var s = GameState.create(20, rng)
	var c = s.clone()
	c.draw(rng, "abcdefgh1")
	eq(s.drawn.size(), 0, "original untouched")
	eq(s.remaining.size(), 20, "original remaining")
	eq(s.request_log.size(), 0, "original log")

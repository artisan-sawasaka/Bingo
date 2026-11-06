extends "res://tests/test_case.gd"

const GameController = preload("res://scripts/core/game_controller.gd")
const SaveStore = preload("res://scripts/core/save_store.gd")
const RandomSource = preload("res://scripts/core/random_source.gd")

var _n := 0


func _ctrl(dir: String) -> GameController:
	var c = GameController.new(SaveStore.new(dir), RandomSource.secure())
	c.cooldown_sec = 0.0
	add_child(c)
	return c


func _rid() -> String:
	_n += 1
	return "test-req-%06d" % _n


func _spin_and_finish(c: GameController) -> Dictionary:
	var r = c.request_spin(_rid(), "test")
	if r.accepted and not r.duplicate:
		c.notify_animation_finished(r.draw_index)
	return r


func test_full_game_75_no_duplicates_and_76th_rejected() -> void:
	var c = _ctrl(scratch_dir("ctrl_full"))
	check(c.start_new_game(75).ok, "start")
	var seen := {}
	for i in 75:
		var r = _spin_and_finish(c)
		if not check(r.accepted, "draw %d accepted (%s)" % [i + 1, r.reason]):
			return
		var n: int = c.state.last_number()
		check(not seen.has(n), "duplicate %d" % n)
		seen[n] = true
	eq(c.phase_name(), "finished", "phase finished")
	var r76 = c.request_spin(_rid(), "test")
	check(not r76.accepted, "76th rejected")
	eq(r76.reason, "finished", "reason")
	eq(c.state.drawn.size(), 75, "75 drawn")


func test_spin_while_spinning_is_rejected() -> void:
	var c = _ctrl(scratch_dir("ctrl_busy"))
	c.start_new_game(75)
	var r1 = c.request_spin(_rid(), "a")
	check(r1.accepted, "first")
	for i in 20:
		var r = c.request_spin(_rid(), "b")
		check(not r.accepted and r.reason == "busy", "busy %d" % i)
	eq(c.state.drawn.size(), 1, "only one draw")
	c.notify_animation_finished(r1.draw_index)
	eq(c.phase_name(), "ready", "ready again")


func test_duplicate_request_id_is_idempotent() -> void:
	var c = _ctrl(scratch_dir("ctrl_dup"))
	c.start_new_game(75)
	var id := _rid()
	var r1 = c.request_spin(id, "a")
	var r2 = c.request_spin(id, "a")
	check(r2.accepted and r2.duplicate, "dup while spinning")
	eq(r2.draw_index, r1.draw_index, "same index")
	c.notify_animation_finished(r1.draw_index)
	var r3 = c.request_spin(id, "a")
	check(r3.duplicate, "dup after finish")
	eq(c.state.drawn.size(), 1, "no extra draw")


func test_invalid_request_ids() -> void:
	var c = _ctrl(scratch_dir("ctrl_invalid"))
	c.start_new_game(75)
	for bad in ["", "short", "has space here", "x".repeat(65), "日本語のIDです日本語"]:
		var r = c.request_spin(bad, "a")
		check(not r.accepted and r.reason == "invalid", "reject '%s'" % bad)
	eq(c.state.drawn.size(), 0, "nothing drawn")


func test_not_started_and_paused() -> void:
	var c = _ctrl(scratch_dir("ctrl_paused"))
	eq(c.request_spin(_rid(), "a").reason, "not_started", "setup")
	c.start_new_game(10)
	c.set_paused(true)
	eq(c.request_spin(_rid(), "a").reason, "paused", "paused")
	c.set_paused(false)
	check(c.request_spin(_rid(), "a").accepted, "unpaused")


func test_save_failure_blocks_draw() -> void:
	var c = _ctrl(scratch_dir("ctrl_savefail"))
	c.start_new_game(75)
	c.store.debug_fail_writes = true
	var errors := []
	c.save_error.connect(func(m): errors.append(m))
	var r = c.request_spin(_rid(), "a")
	check(not r.accepted, "rejected")
	eq(r.reason, "save_failed", "reason")
	eq(c.phase_name(), "ready", "no animation started")
	eq(c.state.drawn.size(), 0, "memory unchanged")
	eq(errors.size(), 1, "error emitted")
	c.store.debug_fail_writes = false
	check(c.request_spin(_rid(), "a").accepted, "works after recovery")


func test_new_game_refused_when_archive_fails() -> void:
	var c = _ctrl(scratch_dir("ctrl_archive_fail"))
	c.start_new_game(75)
	_spin_and_finish(c)
	var before: Array = c.state.drawn.duplicate()
	var id: String = c.state.game_id
	c.store.debug_fail_archive = true
	var errors := []
	c.save_error.connect(func(m): errors.append(m))
	var r: Dictionary = c.start_new_game(50)
	check(not r.ok, "reset refused")
	eq(c.state.game_id, id, "same game kept")
	eq(c.state.drawn, before, "draws kept")
	eq(errors.size(), 1, "error reported")
	c.store.debug_fail_archive = false
	check(c.start_new_game(50).ok, "works once archiving works")


func test_archive_copies_are_verified() -> void:
	var dir := scratch_dir("ctrl_archive_real")
	var c = _ctrl(dir)
	c.start_new_game(30)
	_spin_and_finish(c)
	# A regular FILE named "archive" makes the folder impossible to create.
	var f := FileAccess.open(dir + "archive", FileAccess.WRITE)
	f.store_string("x")
	f.close()
	check(not c.start_new_game(40).ok, "real archive failure refuses the reset")
	eq(c.state.max_number, 30, "still the old game")
	DirAccess.remove_absolute(dir + "archive")
	check(c.start_new_game(40).ok, "reset after the folder can be created")
	var files := DirAccess.get_files_at(dir + "archive")
	check(files.size() >= 1, "previous game archived (%d files)" % files.size())


func test_restart_restores_order_and_remaining() -> void:
	var dir := scratch_dir("ctrl_restart")
	var c = _ctrl(dir)
	c.start_new_game(75)
	for i in 20:
		_spin_and_finish(c)
	var order: Array[int] = c.state.drawn.duplicate()
	# Crash in the middle of an animation: draw is saved but not revealed.
	var r = c.request_spin(_rid(), "a")
	check(r.accepted, "pending draw")
	order.append(c.state.last_number())
	c.queue_free()
	var c2 = _ctrl(dir)
	check(c2.restore(), "restored")
	eq(c2.state.drawn, order, "order incl. pending draw")
	eq(c2.state.remaining.size(), 75 - 21, "remaining")
	eq(c2.phase_name(), "ready", "ready after restore")
	var r2 = _spin_and_finish(c2)
	check(r2.accepted, "continue after restore")
	eq(c2.state.drawn.size(), 22, "22")


func test_snapshot_hides_pending_number() -> void:
	var c = _ctrl(scratch_dir("ctrl_snapshot"))
	c.start_new_game(75)
	_spin_and_finish(c)
	var first: int = c.state.last_number()
	var r = c.request_spin(_rid(), "a")
	var snap = c.get_snapshot()
	eq(snap.phase, "spinning", "phase")
	eq(snap.drawn_count, 1, "revealed count only")
	eq(snap.last_number, first, "last revealed number")
	check(not snap.can_spin, "cannot spin")
	c.notify_animation_finished(r.draw_index)
	snap = c.get_snapshot()
	eq(snap.drawn_count, 2, "after reveal")
	eq(snap.last_number, c.state.last_number(), "new number")


func test_watchdog_forces_finish() -> void:
	var c = _ctrl(scratch_dir("ctrl_watchdog"))
	c.start_new_game(75)
	c.expected_animation_sec = 0.1
	c.watchdog_margin_sec = 0.1
	c.request_spin(_rid(), "a")
	c.tick(0.15)
	eq(c.phase_name(), "spinning", "not yet")
	c.tick(0.1)
	eq(c.phase_name(), "ready", "forced")


func test_cooldown_after_finish() -> void:
	var c = _ctrl(scratch_dir("ctrl_cooldown"))
	c.cooldown_sec = 0.5
	c.start_new_game(75)
	_spin_and_finish(c)
	eq(c.request_spin(_rid(), "a").reason, "busy", "cooldown")
	c.tick(0.6)
	check(c.request_spin(_rid(), "a").accepted, "after cooldown")


func test_last_ball() -> void:
	var c = _ctrl(scratch_dir("ctrl_last"))
	c.start_new_game(2)
	check(_spin_and_finish(c).accepted, "1")
	var r = c.request_spin(_rid(), "a")
	check(r.accepted, "2 (last)")
	eq(c.request_spin(_rid(), "b").reason, "busy", "busy during last")
	c.notify_animation_finished(r.draw_index)
	eq(c.phase_name(), "finished", "finished")
	eq(c.get_snapshot().remaining, 0, "remaining 0")

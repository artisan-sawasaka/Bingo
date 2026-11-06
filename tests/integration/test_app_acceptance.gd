extends "res://tests/test_case.gd"
## Acceptance on the real main scene (UI + 3D presenter + controller + server
## wiring). Keyboard tests push real InputEventKey events through the viewport.
## Engine.time_scale is raised so 75 animations run quickly.

const PORT := 18790

var _profile := ""


func before_each() -> void:
	_profile = "itest_%d" % Time.get_ticks_usec()
	Engine.time_scale = 25.0


func after_each() -> void:
	Engine.time_scale = 1.0


func _make_main() -> Node:
	var main = load("res://scenes/main.tscn").instantiate()
	main.profile_override = _profile
	main.port_override = PORT
	add_child(main)
	await tree.process_frame
	return main


func _wait_ready(main) -> bool:
	return await wait_until(func(): return main.controller.phase_name() != "spinning", 8.0)


## Presses and releases a key through the real input pipeline (GUI first, then _unhandled_input).
func _key(keycode: Key, unicode: int = 0) -> void:
	for pressed in [true, false]:
		var ev := InputEventKey.new()
		ev.keycode = keycode
		ev.physical_keycode = keycode
		ev.unicode = unicode if pressed else 0
		ev.pressed = pressed
		tree.root.push_input(ev)
	await tree.process_frame


func _type(text: String) -> void:
	for ch in text:
		await _key(KEY_0 + (ch.unicode_at(0) - 48), ch.unicode_at(0))


func test_75_draws_through_app_then_restart() -> void:
	var main = await _make_main()
	main._start_game(75)
	eq(main.controller.phase_name(), "ready", "ready after start")
	var seen := {}
	for i in 75:
		# Hammer: several keyboard spins in the same frame must yield one draw.
		main._keyboard_spin()
		main._keyboard_spin()
		main._keyboard_spin()
		if not check(main.controller.phase_name() == "spinning", "spinning at draw %d" % (i + 1)):
			return
		if not check(await _wait_ready(main), "animation finished %d" % (i + 1)):
			return
		await wait_until(func(): return main.controller.can_spin() or main.controller.phase_name() == "finished", 3.0)
		var n: int = main.controller.state.last_number()
		check(not seen.has(n), "duplicate %d" % n)
		seen[n] = true
	eq(seen.size(), 75, "75 unique")
	eq(main.controller.state.drawn.size(), 75, "exactly 75 draws")
	eq(main.controller.phase_name(), "finished", "finished")
	main._keyboard_spin()
	eq(main.controller.state.drawn.size(), 75, "76th not drawn")
	var order: Array = main.controller.state.drawn.duplicate()
	main.queue_free()
	await wait_frames(3)
	var main2 = await _make_main()
	eq(main2.controller.state.drawn, order, "restored order after restart")
	eq(main2.controller.phase_name(), "finished", "still finished")
	check(main2.overlays.is_open("restore"), "restore screen shown")
	main2.queue_free()
	await wait_frames(3)


func test_first_run_setup_by_keyboard() -> void:
	var main = await _make_main()
	await wait_frames(2)
	eq(main.screen_name(), "setup", "setup on first run")
	await _key(KEY_ESCAPE)
	eq(main.screen_name(), "setup", "Esc cannot leave setup without a game")
	await _key(KEY_BACKSPACE)
	await _key(KEY_BACKSPACE)
	await _type("0")
	eq(main.overlays._setup_input.text, "0", "typed into the field")
	await _key(KEY_ENTER)
	check(main.controller.state == null, "0 rejected")
	await _key(KEY_BACKSPACE)
	await _type("30")
	await _key(KEY_ENTER)
	check(main.controller.state != null, "game started")
	eq(main.controller.state.max_number, 30, "max 30 from keyboard")
	eq(main.screen_name(), "main", "back to main")
	main.queue_free()
	await wait_frames(3)


func test_keyboard_screens_spin_history_and_reset() -> void:
	var main = await _make_main()
	main._start_game(75)
	await wait_frames(2)  # the first-run setup screen is freed at frame end
	await _key(KEY_SPACE)
	eq(main.controller.phase_name(), "spinning", "Space draws")
	await _wait_ready(main)
	await wait_until(func(): return main.controller.can_spin(), 2.0)
	# H: history screen and back
	await _key(KEY_H)
	eq(main.screen_name(), "history", "H opens history")
	check(main.history.visible, "history visible")
	await _key(KEY_ESCAPE)
	eq(main.screen_name(), "main", "Esc returns to main")
	await _key(KEY_H)
	# Space on the history screen draws and returns to the main screen
	await _key(KEY_SPACE)
	eq(main.controller.phase_name(), "spinning", "Space draws from history")
	eq(main.screen_name(), "main", "history closed for the draw")
	await _wait_ready(main)
	await wait_until(func(): return main.controller.can_spin(), 2.0)
	eq(main.controller.state.drawn.size(), 2, "2 drawn")
	# M: max-number screen pauses drawing; Esc cancels and keeps the game
	await _key(KEY_M)
	await wait_frames(2)
	eq(main.screen_name(), "setup", "M opens setup")
	check(main.controller.paused, "paused on setup")
	await _key(KEY_SPACE)  # goes into the LineEdit, must not draw
	eq(main.controller.state.drawn.size(), 2, "no draw while setup open")
	await _key(KEY_ESCAPE)
	eq(main.screen_name(), "main", "Esc cancels setup")
	eq(main.controller.state.drawn.size(), 2, "game kept")
	# M → type 90 → Enter → confirmation (focus on Cancel) → Enter cancels
	await _key(KEY_M)
	await wait_frames(2)
	# Invalid text is rejected as typed — never converted into a number.
	var cases := [
		["h", [[KEY_H, 104]]],
		["-1", [[KEY_MINUS, 45], [KEY_1, 49]]],
		["7.5", [[KEY_7, 55], [KEY_PERIOD, 46], [KEY_5, 53]]],
		["７５", [[KEY_7, 0xFF17], [KEY_5, 0xFF15]]],
	]
	for c in cases:
		main.overlays._setup_input.select_all()
		for k in c[1]:
			await _key(k[0], k[1])
		var typed: String = main.overlays._setup_input.text
		eq(typed, c[0], "typed as-is (no conversion)")
		await _key(KEY_ENTER)
		await wait_frames(2)
		check(not main.overlays.is_open("confirm_reset"), "'%s' must not reach the confirmation" % typed)
		check(not main.overlays._setup_error.text.is_empty(), "'%s' shows an error" % typed)
		eq(main.controller.state.max_number, 75, "'%s' changed nothing" % typed)
	main.overlays._setup_input.select_all()
	await _type("90")
	await _key(KEY_ENTER)
	await wait_frames(2)
	check(main.overlays.is_open("confirm_reset"), "confirmation shown")
	await _key(KEY_ENTER)
	await wait_frames(2)
	check(not main.overlays.is_open("confirm_reset"), "Enter on Cancel closes confirmation")
	eq(main.controller.state.max_number, 75, "not reset yet")
	# Enter again → confirmation → Right → Enter = reset with 90
	await _key(KEY_ENTER)
	await wait_frames(2)
	await _key(KEY_RIGHT)
	await _key(KEY_ENTER)
	await wait_frames(2)
	eq(main.controller.state.max_number, 90, "reset to 90")
	eq(main.controller.state.drawn.size(), 0, "fresh game")
	eq(main.screen_name(), "main", "main after reset")
	check(not main.controller.paused, "unpaused")
	# Q / S / F1 open and Esc closes
	await _key(KEY_Q)
	check(main.overlays.is_open("connect"), "Q connect")
	await _key(KEY_Q)
	check(not main.overlays.is_open("connect"), "Q closes connect")
	await _key(KEY_S)
	check(main.overlays.is_open("settings"), "S settings")
	check(main.controller.paused, "paused in settings")
	await _key(KEY_ESCAPE)
	check(not main.overlays.is_open("settings"), "Esc closes settings")
	await _key(KEY_F1)
	check(main.overlays.is_open("help"), "F1 help")
	await _key(KEY_ESCAPE)
	check(not main.overlays.is_open("help"), "Esc closes help")
	# L: in-app license notices (exe alone carries them)
	await _key(KEY_L)
	await wait_frames(2)
	check(main.overlays.is_open("licenses"), "L opens licenses")
	var lic: TextEdit = main.overlays._layers["licenses"].find_child("LicenseText", true, false)
	check(lic != null, "license text shown")
	if lic != null:
		check(lic.text.contains("Godot Engine"), "Godot license")
		check(lic.text.contains("Permission is hereby granted"), "MIT text")
		check(lic.text.contains("Project Nayuki"), "QR algorithm credit")
		check(main.get_viewport().gui_get_focus_owner() == lic, "text focused for keyboard scrolling")
		await _key(KEY_PAGEDOWN)
		await wait_frames(2)
		var after_page := lic.scroll_vertical
		check(after_page > 0.0, "PageDown scrolls the view at once")
		await _key(KEY_END)
		await wait_frames(2)
		check(lic.scroll_vertical > after_page, "End jumps further down")
		await _key(KEY_HOME)
		await wait_frames(2)
		eq(lic.scroll_vertical, 0.0, "Home back to the top")
	await _key(KEY_ESCAPE)
	check(not main.overlays.is_open("licenses"), "Esc closes licenses")
	main.queue_free()
	await wait_frames(3)


func test_random_speed_draws_complete() -> void:
	var main = await _make_main()
	main.settings.speed = "random"
	main._apply_settings()
	main._start_game(20)
	await wait_frames(2)
	var used := {}
	for i in 12:
		main._keyboard_spin()
		check(main.controller.phase_name() == "spinning", "spinning %d" % i)
		used[main._draw_speed] = true
		check(await _wait_ready(main), "finished %d" % i)
		await wait_until(func(): return main.controller.can_spin(), 2.0)
	eq(main.controller.state.drawn.size(), 12, "12 draws")
	check(used.size() >= 2, "random used several speeds: %s" % str(used.keys()))
	main.queue_free()
	await wait_frames(3)


func test_remote_new_game_is_idempotent_across_restart() -> void:
	var main = await _make_main()
	main._start_game(75)
	var r: Dictionary = main.remote_new_game("phone-ng-restart1", "60")
	check(r.ok and not r.duplicate, "applied once")
	main._keyboard_spin()
	await _wait_ready(main)
	eq(main.controller.state.drawn.size(), 1, "one draw in the new game")
	# PC restarts before the phone got the reply; the phone re-sends the same id.
	main.queue_free()
	await wait_frames(3)
	var main2 = await _make_main()
	var again: Dictionary = main2.remote_new_game("phone-ng-restart1", "60")
	check(again.ok and again.duplicate, "re-send after restart is a duplicate")
	eq(main2.controller.state.drawn.size(), 1, "game not reset again")
	main2.queue_free()
	await wait_frames(3)


func test_remote_reset_refused_during_pc_confirmation() -> void:
	var main = await _make_main()
	main._start_game(75)
	await wait_frames(2)
	main.open_setup_screen()
	await wait_frames(2)
	main.overlays._setup_input.text = "90"
	main.overlays._submit_setup()  # opens the PC confirmation
	await wait_frames(2)
	check(main.overlays.is_open("confirm_reset"), "PC confirmation open")
	var r: Dictionary = main.remote_new_game("phone-ng-during-confirm", "50")
	check(not r.ok, "remote reset refused while the PC confirms")
	eq(main.controller.state.max_number, 75, "game unchanged")
	check(main.overlays.is_open("confirm_reset"), "PC confirmation still open")
	main.queue_free()
	await wait_frames(3)


func test_remote_handlers() -> void:
	var main = await _make_main()
	eq(main.remote_show_screen("history").ok, false, "no history before a game")
	var r: Dictionary = main.remote_new_game("phone-req-0001", "75")
	check(r.ok, "phone starts first game")
	eq(main.controller.state.max_number, 75, "75")
	var dup: Dictionary = main.remote_new_game("phone-req-0001", "60")
	check(dup.ok and dup.duplicate, "same request id is not applied twice")
	eq(main.controller.state.max_number, 75, "still 75")
	eq(main.remote_new_game("phone-req-0002", "1000").ok, false, "out of range")
	eq(main.remote_new_game("phone-req-0003", "abc").ok, false, "not a number")
	eq(main.remote_new_game("phone-req-0006", "75      x").ok, false, "padded garbage rejected")
	eq(main.remote_new_game("phone-req-0007", "7.5").ok, false, "fraction rejected")
	check(main.remote_show_screen("history").ok, "history")
	eq(main.get_remote_snapshot().screen, "history", "snapshot screen")
	check(main.remote_show_screen("main").ok, "main")
	check(main.remote_show_screen("setup").ok, "setup")
	eq(main.get_remote_snapshot().screen, "setup", "setup screen")
	check(not main.get_remote_snapshot().can_spin, "cannot spin during setup")
	main.remote_setup_draft("42")
	eq(main.overlays._setup_input.text, "42", "draft mirrored on TV")
	check(main.remote_show_screen("main").ok, "cancel back to main")
	main._keyboard_spin()
	eq(main.controller.phase_name(), "spinning", "spinning")
	eq(main.remote_show_screen("history").ok, false, "no switching while spinning")
	eq(main.remote_new_game("phone-req-0004", "50").ok, false, "no reset while spinning")
	await _wait_ready(main)
	var r2: Dictionary = main.remote_new_game("phone-req-0005", "50")
	check(r2.ok, "reset from phone")
	eq(main.controller.state.max_number, 50, "50")
	eq(main.controller.state.drawn.size(), 0, "fresh")
	main.queue_free()
	await wait_frames(3)

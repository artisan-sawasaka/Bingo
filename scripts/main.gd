extends Node
## Application root: wires GameController (truth), RemoteServer (phone/iPad),
## BingoMachine (3D presenter), TV screens (main / history / max-number) and SFX.
##
## Screens: "main" (machine + current number), "history" (all drawn numbers),
## "setup" (max number / reset). Every operation has a keyboard key (see open_help()).
##
## Dev-only command line options (after `--`):
##   --windowed            ignore the fullscreen setting
##   --capture=PATH        save a screenshot PATH (png) after --capture-delay seconds, then
##   --capture-delay=SEC   (default 3)            ...quit if --quit-after-capture
##   --quit-after-capture
##   --demo-spin=SEC       trigger one keyboard spin SEC seconds after start
##   --profile=NAME        keep data in user://profiles/NAME/ (tests, demos)
##   --port=N              remote server port override
##   --auto-start=N        start a new game with max N when nothing is restored
##   --demo-draws=N        draw N numbers instantly at startup (screenshots)
##   --show=connect|settings|history|setup|help|licenses  open that screen at startup (screenshots)
##   --low-effects         force the "高画質エフェクト" setting off for this run
##   --gpu-report          print the measured GPU / CPU render time with each capture

const GameController = preload("res://scripts/core/game_controller.gd")
const GameState = preload("res://scripts/core/game_state.gd")
const SaveStore = preload("res://scripts/core/save_store.gd")
const AppSettings = preload("res://scripts/core/app_settings.gd")
const RemoteServer = preload("res://scripts/net/remote_server.gd")
const RemoteSecret = preload("res://scripts/net/remote_secret.gd")
const BingoMachine = preload("res://scripts/machine/bingo_machine.gd")
const Hud = preload("res://scripts/ui/hud.gd")
const HistoryScreen = preload("res://scripts/ui/history_screen.gd")
const Overlays = preload("res://scripts/ui/overlays.gd")
const UiKit = preload("res://scripts/ui/ui_kit.gd")
const Sfx = preload("res://scripts/audio/sfx.gd")
const Bgm = preload("res://scripts/audio/bgm.gd")
const RandomSource = preload("res://scripts/core/random_source.gd")

var settings := AppSettings.new()
var controller: GameController
var server: RemoteServer
var machine: BingoMachine
var hud: Hud
var history: HistoryScreen
var overlays: Overlays
var sfx: Sfx
var bgm: Bgm
var _ui_root: Control
var _rng := RandomSource.secure()
var _args := {}
var _mouse_idle := 0.0
var _last_max := 75
var _speed_rng := RandomNumberGenerator.new()
var _draw_speed := "normal"  # speed actually used by the current / last draw

## Set by tests before add_child(): forces --profile / --port / --windowed.
var profile_override := ""
var port_override := 0


func _ready() -> void:
	_speed_rng.randomize()
	_parse_args()
	if not profile_override.is_empty():
		_args["profile"] = profile_override
		_args["windowed"] = "1"
	if port_override > 0:
		_args["port"] = str(port_override)
	# --profile=NAME keeps dev/test runs away from the real game data.
	var base := "user://"
	if _args.has("profile"):
		base = "user://profiles/%s/" % String(_args["profile"]).validate_filename()
		DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(base))
	settings = AppSettings.new(base + "settings.json")
	settings.load_file()
	print("Bingo Drum 3D %s  Godot %s  data: %s" % [ProjectSettings.get_setting("application/config/version"), Engine.get_version_info().string, ProjectSettings.globalize_path(base)])

	controller = GameController.new(SaveStore.new(base), RandomSource.secure())
	controller.name = "GameController"
	add_child(controller)
	controller.expected_animation_sec = settings.max_reveal_sec()

	sfx = Sfx.new()
	sfx.name = "Sfx"
	add_child(sfx)
	bgm = Bgm.new()
	bgm.name = "Bgm"
	add_child(bgm)

	machine = BingoMachine.new()
	machine.name = "BingoMachine"
	add_child(machine)

	var layer := CanvasLayer.new()
	add_child(layer)
	_ui_root = Control.new()
	UiKit.full_rect(_ui_root)
	_ui_root.theme = UiKit.make_theme()
	_ui_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_ui_root)
	hud = Hud.new()
	_ui_root.add_child(hud)
	history = HistoryScreen.new()
	history.visible = false
	_ui_root.add_child(history)
	overlays = Overlays.new()
	overlays.settings = settings
	_ui_root.add_child(overlays)

	server = RemoteServer.new()
	server.name = "RemoteServer"
	add_child(server)
	server.setup(controller, RemoteSecret.new(base + "remote_secret.json"))
	server.app = self
	if _args.has("port"):
		settings.port = int(_args["port"])
	overlays.server = server

	_connect_signals()
	_apply_settings()

	if not server.start(settings.port):
		overlays.show_error("スマホ用サーバーを開始できません：%s（他のアプリがポートを使用中の可能性）。キーボードで操作できます（F1：キー一覧）。" % server.start_error)
	elif not server.missing_files().is_empty():
		overlays.show_error("リモコン用ファイルが見つかりません：%s" % ", ".join(server.missing_files()))

	if controller.restore():
		var s = controller.state
		_last_max = s.max_number
		_reset_presenters()
		overlays.open_restore(s.max_number, s.drawn_count(), s.last_number(), s.is_finished())
		print("restored game %s: %d drawn" % [s.game_id, s.drawn_count()])
	elif _args.has("auto-start"):
		_start_game(int(_args["auto-start"]))
	else:
		hud.set_state(0, [], "setup")
		overlays.open_setup(75, "", controller.last_error)
	_update_status()

	if _args.has("demo-draws") and controller.state != null:
		# Dev only: fill a game instantly for screenshots (same draw path, no animation wait).
		var cd := controller.cooldown_sec
		controller.cooldown_sec = 0.0
		for i in int(_args["demo-draws"]):
			var r := controller.request_spin("demo-" + _rng.random_hex(8), "demo")
			if r.accepted:
				controller.notify_animation_finished(r.draw_index)
		controller.cooldown_sec = cd
		_reset_presenters()
	match String(_args.get("show", "")):
		"connect":
			overlays.close("restore")
			overlays.open_connect()
		"settings":
			overlays.close("restore")
			overlays.open_settings(_game_info())
		"history":
			overlays.close("restore")
			show_history(true)
		"setup":
			overlays.close("restore")
			open_setup_screen()
		"help":
			overlays.close("restore")
			overlays.open_help()
		"licenses":
			overlays.close("restore")
			overlays.open_licenses()
	if _args.has("demo-spin"):
		get_tree().create_timer(float(_args["demo-spin"])).timeout.connect(func(): _keyboard_spin())
	if _args.has("gpu-report"):
		RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if _args.has("capture"):
		# Screenshot runs must not steal keyboard focus from whatever the user is typing in.
		DisplayServer.window_set_flag(DisplayServer.WINDOW_FLAG_NO_FOCUS, true)
		var delay := float(_args.get("capture-delay", "3"))
		get_tree().create_timer(delay).timeout.connect(_capture)


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--"):
			var kv: PackedStringArray = a.substr(2).split("=", true, 1)
			_args[kv[0]] = kv[1] if kv.size() > 1 else "1"


func _connect_signals() -> void:
	controller.spin_started.connect(_on_spin_started)
	controller.spin_finished.connect(_on_spin_finished)
	controller.save_error.connect(_on_save_error)
	controller.state_changed.connect(_update_status)
	machine.stage_reached.connect(_on_stage)
	server.clients_changed.connect(func(_n):
		_update_status()
		overlays.refresh_connect())
	overlays.layers_changed.connect(_on_layers_changed)
	overlays.start_game_requested.connect(func(v): _start_game(v))
	overlays.setup_cancel_requested.connect(_cancel_setup)
	overlays.setup_requested.connect(open_setup_screen)
	overlays.settings_changed.connect(func():
		_apply_settings()
		settings.save_file())
	# Moving the SE slider plays a short sample so the level can be judged by ear.
	overlays.se_preview_requested.connect(func():
		if not sfx.is_playing("pop"):
			sfx.play("pop"))
	overlays.reissue_token_requested.connect(_reissue_token)
	overlays.quit_requested.connect(func(): get_tree().quit())
	get_viewport().size_changed.connect(_update_view_rect)


func _apply_settings() -> void:
	Sfx.set_volume(settings.se_volume)
	bgm.set_level(settings.bgm_volume, settings.bgm_enabled)
	machine.set_effects_quality(settings.effects_high and not _args.has("low-effects"))
	hud.set_safe_margin(settings.safe_margin)
	history.set_safe_margin(settings.safe_margin)
	controller.expected_animation_sec = settings.max_reveal_sec()
	var want_fs := settings.fullscreen and not _args.has("windowed")
	var mode := DisplayServer.window_get_mode()
	var is_fs := mode == DisplayServer.WINDOW_MODE_FULLSCREEN or mode == DisplayServer.WINDOW_MODE_EXCLUSIVE_FULLSCREEN
	if want_fs and not is_fs:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	elif not want_fs and is_fs:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	_update_view_rect.call_deferred()


func _update_view_rect() -> void:
	machine.set_view_rect(hud.machine_view_rect())


func _process(delta: float) -> void:
	# Hide the mouse cursor on the TV after a few idle seconds.
	_mouse_idle += delta
	if _mouse_idle > 3.0 and Input.mouse_mode == Input.MOUSE_MODE_VISIBLE and not overlays.any_open():
		Input.mouse_mode = Input.MOUSE_MODE_HIDDEN


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_mouse_idle = 0.0
		if Input.mouse_mode != Input.MOUSE_MODE_VISIBLE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	# The max-number field would swallow Esc (it only leaves edit mode), so
	# handle Esc for the setup / confirmation screens before the GUI sees it.
	if event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_ESCAPE:
		if overlays.is_open("confirm_reset") or overlays.is_open("setup"):
			_back()
			get_viewport().set_input_as_handled()


# ---------------------------------------------------------------- screens

func screen_name() -> String:
	if overlays.is_open("setup") or overlays.is_open("confirm_reset"):
		return "setup"
	if history.visible:
		return "history"
	return "main"


func show_history(on: bool) -> void:
	if on and controller.state == null:
		return
	if on:
		overlays.close("connect")
		overlays.close("restore")
		overlays.close("help")
		overlays.close("licenses")
		history.set_state(controller.state.max_number, controller.revealed_numbers(), controller.phase_name())
	if history.visible == on:
		return
	history.visible = on
	_on_layers_changed()


func open_setup_screen() -> Dictionary:
	if controller.is_spinning():
		overlays.toast("抽選中は開けません", 1.5)
		return {"ok": false, "message": "抽選中は開けません"}
	if overlays.is_open("setup"):
		return {"ok": true, "message": ""}
	for n in ["settings", "connect", "restore", "help", "licenses"]:
		overlays.close(n)
	var info := ""
	if controller.state != null:
		var s = controller.state
		info = "最大 %d ・ %d球抽選済み ・ 残り %d" % [s.max_number, s.drawn_count(), s.remaining.size()]
	overlays.open_setup(controller.state.max_number if controller.state != null else _last_max, info)
	return {"ok": true, "message": ""}


func _cancel_setup() -> void:
	if controller.state == null:
		return  # nothing to go back to
	overlays.close("confirm_reset")
	overlays.close("setup")


func _on_layers_changed() -> void:
	controller.set_paused(overlays.is_blocking())
	_update_status()
	if server != null:
		server.notify_state_changed()


func _reissue_token() -> void:
	var saved := server.reissue_token()
	overlays.refresh_connect()
	if saved:
		overlays.toast("QRを再発行しました。スマホ・iPadで新しいQRを読み取ってください")
	else:
		# Old links are cut off now, but a restart could bring the old code back.
		overlays.show_error("QRの再発行を保存できませんでした：%s\n今は古いQRは使えませんが、アプリを再起動すると古いQRが再び有効になる可能性があります。保存先（%%APPDATA%%\\BingoDrum3D）を確認して再発行し直してください。" % server.secret.last_error)
		sfx.play("error")


# ---------------------------------------------------------------- keyboard (every operation)

func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var handled := true
	match event.keycode:
		KEY_SPACE, KEY_ENTER, KEY_KP_ENTER:
			if not overlays.is_blocking():
				_keyboard_spin()
		KEY_ESCAPE:
			_back()
		KEY_H:
			if not overlays.is_blocking() and not controller.is_spinning():
				show_history(not history.visible)
		KEY_M:
			open_setup_screen()
		KEY_Q:
			if overlays.is_open("connect"):
				overlays.close("connect")
			elif not overlays.is_blocking():
				overlays.open_connect()
		KEY_S:
			if not overlays.is_blocking() and not controller.is_spinning():
				overlays.open_settings(_game_info())
		KEY_I:
			if overlays.is_open("connect"):
				overlays.next_ip()
		KEY_R:
			if overlays.is_open("connect"):
				_reissue_token()
		KEY_F1, KEY_QUESTION, KEY_SLASH:
			if not overlays.is_blocking():
				overlays.open_help()
		KEY_L:
			if overlays.is_open("licenses"):
				overlays.close("licenses")
			elif not overlays.is_blocking() and not controller.is_spinning():
				overlays.open_licenses()
		KEY_B:
			if not overlays.is_blocking():
				toggle_bgm()
		KEY_F11:
			settings.fullscreen = not settings.fullscreen
			_args.erase("windowed")
			_apply_settings()
			settings.save_file()
		_:
			handled = false
	if handled:
		get_viewport().set_input_as_handled()


## Esc: close the top-most screen; on the main screen open settings.
func _back() -> void:
	if overlays.is_open("confirm_reset"):
		overlays.close("confirm_reset")
		overlays.focus_setup_input.call_deferred()
	elif overlays.is_open("setup"):
		_cancel_setup()
	elif overlays.is_open("settings"):
		overlays.close("settings")
	elif overlays.is_open("licenses"):
		overlays.close("licenses")
	elif overlays.is_open("help"):
		overlays.close("help")
	elif overlays.is_open("connect"):
		overlays.close("connect")
	elif overlays.is_open("restore"):
		overlays.close("restore")
	elif history.visible:
		show_history(false)
	elif not controller.is_spinning():
		overlays.open_settings(_game_info())


## B key: background music on / off (the level is in the settings screen).
func toggle_bgm() -> void:
	settings.bgm_enabled = not settings.bgm_enabled
	_apply_settings()
	settings.save_file()
	if settings.bgm_enabled and settings.bgm_volume <= 0.001:
		overlays.toast("BGM：オン（設定で BGM の音量が 0 になっています）", 2.0)
	else:
		overlays.toast("BGM：オン" if settings.bgm_enabled else "BGM：オフ", 1.5)


func _keyboard_spin() -> void:
	var r := controller.request_spin("kbd-" + _rng.random_hex(8), "keyboard")
	if not r.accepted:
		overlays.toast(r.message, 1.5)


func _game_info() -> String:
	if controller.state == null:
		return "ゲーム未開始"
	var s = controller.state
	return "最大番号 %d ・ %d球抽選済み ・ 残り %d ・ 保存先 %s" % [s.max_number, s.drawn_count(), s.remaining.size(), controller.store.base_dir]


# ---------------------------------------------------------------- remote (phone / iPad)

func get_remote_snapshot() -> Dictionary:
	var s := controller.get_snapshot()
	s["screen"] = screen_name()
	s["modal"] = overlays.top_modal()
	s["default_max"] = controller.state.max_number if controller.state != null else _last_max
	s["min_max"] = GameState.MIN_MAX_NUMBER
	s["max_max"] = GameState.MAX_MAX_NUMBER
	return s


func remote_show_screen(screen: String) -> Dictionary:
	if controller.is_spinning():
		return {"ok": false, "message": "抽選中は画面を切り替えられません"}
	if overlays.is_open("settings") or overlays.is_open("confirm_reset"):
		return {"ok": false, "message": "PC側で設定・確認画面を表示中です"}
	match screen:
		"main", "history":
			if controller.state == null:
				return {"ok": false, "message": "先に最大番号を決めてゲームを開始してください"}
			overlays.close("setup")
			overlays.close("help")
			overlays.close("licenses")
			if screen == "history":
				show_history(true)
			else:
				overlays.close("connect")
				show_history(false)
		"setup":
			return open_setup_screen()
	return {"ok": true, "message": ""}


func remote_setup_draft(text: String) -> void:
	overlays.set_setup_draft(text)


## The phone asks its own two-step confirmation before sending this.
## The request id is saved with the new game, so a re-send (also after a PC
## restart) is answered as a duplicate and never resets twice.
func remote_new_game(request_id: String, max_text: String) -> Dictionary:
	if controller.was_new_game_applied(request_id):
		var cur: int = controller.state.max_number
		return {"ok": true, "duplicate": true, "message": "最大 %d で開始済み" % cur}
	var v := GameState.validate_max_number_text(max_text)
	if not v.ok:
		return {"ok": false, "message": v.error}
	if controller.is_spinning():
		return {"ok": false, "message": "抽選中です"}
	if overlays.is_open("settings") or overlays.is_open("confirm_reset"):
		return {"ok": false, "message": "PC側で設定・確認画面を表示中です"}
	var r := _start_game(int(v.value), request_id)
	return {"ok": r.ok, "duplicate": false, "message": ("最大 %d で開始しました" % int(v.value)) if r.ok else String(r.error)}


# ---------------------------------------------------------------- flow

## Starts / resets the game. Used by keyboard (after the TV confirmation) and phone.
func _start_game(max_number: int, request_id: String = "") -> Dictionary:
	if controller.is_spinning():
		return {"ok": false, "error": "抽選中です"}
	var r := controller.start_new_game(max_number, request_id)
	if not r.ok:
		overlays.setup_error(r.error)
		return r
	_last_max = max_number
	overlays.close("confirm_reset")
	overlays.close("setup")
	overlays.close("restore")
	overlays.show_error("")
	_reset_presenters()
	overlays.toast("ゲーム開始！（1〜%d）レバーを引くと抽選します" % max_number, 3.0)
	_update_status()
	server.notify_state_changed()
	return {"ok": true, "error": ""}


func _reset_presenters() -> void:
	var s = controller.state
	# Drum = the numbers still left, tray = the last ball, stage rim = the earlier ones.
	machine.set_state(s.max_number, s.remaining, s.drawn)
	hud.set_state(s.max_number, controller.revealed_numbers(), controller.phase_name())
	history.set_state(s.max_number, controller.revealed_numbers(), controller.phase_name())
	overlays.show_banner("全ての番号が出ました" if s.is_finished() else "")
	show_history(false)


func _on_spin_started(info: Dictionary) -> void:
	for n in ["connect", "restore", "help", "licenses"]:
		overlays.close(n)
	show_history(false)
	overlays.show_error("")
	hud.show_spinning(controller.revealed_numbers().size())
	bgm.set_ducked(true)  # the machine's sounds come first during a draw
	# "ランダム" picks short / normal / long for each draw.
	_draw_speed = settings.pick_speed(_speed_rng)
	machine.play_draw(int(info.number), AppSettings.timing_for(_draw_speed))
	print("draw #%d accepted (source=%s, speed=%s)" % [info.draw_index, info.source, _draw_speed])


func _on_stage(stage: String, _number: int) -> void:
	var k: float = AppSettings.factor_of(_draw_speed)
	match stage:
		"start":
			sfx.play("start")
			sfx.play("rattle", 1.0 / k)
			sfx.play("riser", 1.0 / k, -9.0)
		"eject":
			sfx.stop("rattle")
			sfx.stop("riser")
			sfx.play("release")
		"reveal":
			sfx.play("reveal")
			sfx.play("pop", 1.0, -5.0)
			if controller.state != null:
				hud.reveal(controller.state.drawn, "finished" if controller.state.is_finished() else "ready")
		"done":
			var p := controller.pending_info()
			if not p.is_empty():
				controller.notify_animation_finished(int(p.draw_index))


func _on_spin_finished(_info: Dictionary) -> void:
	bgm.set_ducked(false)
	# Watchdog path or normal path: make sure every screen shows the confirmed state.
	if controller.state != null:
		var s = controller.state
		hud.set_state(s.max_number, controller.revealed_numbers(), controller.phase_name())
		history.set_state(s.max_number, controller.revealed_numbers(), controller.phase_name())
		if s.is_finished():
			overlays.show_banner("全ての番号が出ました！")
			sfx.play("finish")
			machine.celebrate()
	_update_status()


func _on_save_error(message: String) -> void:
	overlays.show_error(message + "\n抽選は行われていません。ディスクの空き容量や保存先を確認してください。")
	sfx.play("error")


## The main screen stays clean: the status line only appears when attention is needed.
func _update_status() -> void:
	var n := server.client_count() if server != null else 0
	var txt := ""
	var col := UiKit.BAD
	if server == null or not server.running:
		txt = "リモコン：サーバー停止中（キーボードで操作できます　F1：キー一覧）"
	elif n == 0:
		txt = "リモコン未接続（Q：接続画面　F1：キー一覧）"
	if controller.paused and controller.phase_name() != "setup":
		txt += ("   ・   " if not txt.is_empty() else "") + "設定中（抽選停止）"
		col = UiKit.ACCENT if n > 0 else UiKit.BAD
	hud.set_status(txt, col)


## --capture-count=N --capture-interval=SEC saves N frames (PATH, PATH-2.png, ...)
## so animations can be checked from stills.
func _capture() -> void:
	var count := maxi(1, int(_args.get("capture-count", "1")))
	var interval := float(_args.get("capture-interval", "0.25"))
	var base: String = _args["capture"]
	for shot in count:
		await RenderingServer.frame_post_draw
		if _args.has("gpu-report"):
			var rid := get_viewport().get_viewport_rid()
			print("render time: gpu %.2f ms, cpu %.2f ms, %d fps (effects %s)" % [
				RenderingServer.viewport_get_measured_render_time_gpu(rid),
				RenderingServer.viewport_get_measured_render_time_cpu(rid),
				int(Engine.get_frames_per_second()),
				"high" if machine.effects_high else "low"])
		var img := get_viewport().get_texture().get_image()
		if _args.has("capture-crop"):
			# x,y,w,h in pixels; the region is enlarged 3x for close inspection.
			var c: PackedStringArray = String(_args["capture-crop"]).split(",")
			if c.size() == 4:
				img = img.get_region(Rect2i(int(c[0]), int(c[1]), int(c[2]), int(c[3])))
				img.resize(img.get_width() * 3, img.get_height() * 3, Image.INTERPOLATE_LANCZOS)
		var path := base if shot == 0 else "%s-%d.%s" % [base.get_basename(), shot + 1, base.get_extension()]
		var err := img.save_png(path)
		print("capture saved: %s (%s)" % [path, error_string(err)])
		if shot < count - 1:
			await get_tree().create_timer(interval).timeout
	if _args.has("quit-after-capture"):
		get_tree().quit()

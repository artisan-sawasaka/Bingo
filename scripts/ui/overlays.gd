extends Control
## Modal screens: max-number / reset screen, reset confirmation, restore
## notice, phone connection (QR), settings, banners and toasts.
## Every button is keyboard focusable (Tab / arrows + Enter).

const UiKit = preload("res://scripts/ui/ui_kit.gd")
const GameState = preload("res://scripts/core/game_state.gd")
const AppSettings = preload("res://scripts/core/app_settings.gd")
const QrCode = preload("res://scripts/util/qr_code.gd")
const Licenses = preload("res://scripts/util/licenses.gd")

## The user confirmed a (new) game with this max number.
signal start_game_requested(max_number: int)
## The user left the max-number screen without starting (only when a game exists).
signal setup_cancel_requested
signal setup_requested
signal settings_changed
## The SE volume slider moved: play a sample at the new level.
signal se_preview_requested
signal reissue_token_requested
signal quit_requested
## Any layer opened or closed.
signal layers_changed

var settings: AppSettings
var server: Node  # RemoteServer

var _layers := {}       # name -> Control
var _setup_input: LineEdit
var _setup_error: Label
var _setup_has_game := false
var _setup_game_info := ""
var _connect_qr: TextureRect
var _connect_url: Label
var _connect_status: Label
var _connect_ip_btn: Button
var _ip_index := 0
var _banner: PanelContainer
var _banner_label: Label
var _toast: PanelContainer
var _toast_label: Label
var _toast_tween: Tween
var _error_banner: PanelContainer
var _error_label: Label

## Layers that pause drawing while open.
const BLOCKING := ["setup", "confirm_reset", "settings"]


func _ready() -> void:
	UiKit.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_banners()


func is_open(name: String) -> bool:
	return _layers.has(name) and is_instance_valid(_layers[name])


func is_blocking() -> bool:
	for n in BLOCKING:
		if is_open(n):
			return true
	return false


func any_open() -> bool:
	for n in _layers:
		if is_open(n):
			return true
	return false


## Name of the top-most modal for the phone ("" when none).
func top_modal() -> String:
	for n in ["confirm_reset", "settings", "setup", "licenses", "help", "connect", "restore"]:
		if is_open(n):
			return n
	return ""


func close(name: String) -> void:
	if not is_open(name):
		return
	_layers[name].queue_free()
	_layers.erase(name)
	layers_changed.emit()


func close_all() -> void:
	for n in _layers.keys():
		close(n)


func _open(name: String, layer: Control) -> void:
	if is_open(name):
		_layers[name].queue_free()
		_layers.erase(name)
	_layers[name] = layer
	add_child(layer)
	layers_changed.emit()


func _key_hint(text: String) -> Label:
	return UiKit.label(text, 22, Color(0.5, 0.55, 0.72), HORIZONTAL_ALIGNMENT_CENTER)


# ---------------------------------------------------------------- max number / reset

## game_info non-empty = a game is in progress (starting will reset it after a confirmation).
func open_setup(default_max: int = GameState.DEFAULT_MAX_NUMBER, game_info: String = "", notice: String = "") -> void:
	_setup_has_game = not game_info.is_empty()
	_setup_game_info = game_info
	var m := UiKit.modal(1040)
	var box: VBoxContainer = m.box
	box.add_child(UiKit.label("最大番号の設定" if not _setup_has_game else "最大番号の設定・リセット", 60, UiKit.ACCENT, HORIZONTAL_ALIGNMENT_CENTER))
	if not notice.is_empty():
		var nl := UiKit.label(notice, 26, UiKit.BAD, HORIZONTAL_ALIGNMENT_CENTER)
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(nl)
	if _setup_has_game:
		var gi := UiKit.label("現在のゲーム：%s\n開始すると、これまでの番号はリセットされます（記録は archive に保存）。" % game_info, 26, UiKit.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
		gi.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		box.add_child(gi)
	else:
		box.add_child(UiKit.label("抽選する番号の最大値を入力してください（1〜N を抽選します）", 28, UiKit.MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_child(UiKit.label("最大番号", 40))
	_setup_input = LineEdit.new()
	_setup_input.text = str(default_max)
	_setup_input.max_length = 4
	_setup_input.custom_minimum_size = Vector2(240, 104)
	_setup_input.alignment = HORIZONTAL_ALIGNMENT_CENTER
	_setup_input.add_theme_font_size_override("font_size", 64)
	_setup_input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_NUMBER
	_setup_input.keep_editing_on_text_submit = true
	_setup_input.text_submitted.connect(func(_t): _submit_setup())
	# The raw text is validated as typed (no silent conversion: "-1", "7.5",
	# full-width digits, letters are rejected with an error, never turned into a number).
	_setup_input.text_changed.connect(func(_t): _setup_error.text = "")
	row.add_child(_setup_input)
	row.add_child(UiKit.label("（%d〜%d）" % [GameState.MIN_MAX_NUMBER, GameState.MAX_MAX_NUMBER], 30, UiKit.MUTED))
	box.add_child(row)
	_setup_error = UiKit.label("", 28, UiKit.BAD, HORIZONTAL_ALIGNMENT_CENTER)
	box.add_child(_setup_error)
	box.add_child(UiKit.label("紙のビンゴカードは通常 1〜75 です。ゲーム中は最大番号を変えられません（変えるとリセット）。", 24, UiKit.MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	if _setup_has_game:
		var cancel := UiKit.button("キャンセル（Esc）", 32)
		cancel.pressed.connect(func(): setup_cancel_requested.emit())
		btns.add_child(cancel)
	var conn := UiKit.button("スマホ接続画面（Q）", 30)
	conn.pressed.connect(open_connect)
	btns.add_child(conn)
	var start := UiKit.button("リセットして開始…" if _setup_has_game else "ゲーム開始", 40)
	start.custom_minimum_size = Vector2(320, 88)
	start.pressed.connect(_submit_setup)
	btns.add_child(start)
	box.add_child(btns)
	box.add_child(_key_hint("数字キーで入力 → Enter で決定　／　Tab・矢印でボタン移動" + ("　／　Esc でキャンセル" if _setup_has_game else "")))
	_open("setup", m.root)
	focus_setup_input.call_deferred()


## Godot 4.4+: a focused LineEdit only accepts typing in "editing" mode.
func focus_setup_input() -> void:
	if not is_open("setup") or _setup_input == null:
		return
	_setup_input.grab_focus()
	_setup_input.edit()
	_setup_input.select_all()


func _submit_setup() -> void:
	var res := GameState.validate_max_number_text(_setup_input.text)
	if not res.ok:
		_setup_error.text = res.error
		focus_setup_input()
		return
	if _setup_has_game:
		_open_confirm_reset(int(res.value))
	else:
		start_game_requested.emit(int(res.value))


## Mirrors the value typed on the phone into the TV's input field.
func set_setup_draft(text: String) -> void:
	if not is_open("setup") or _setup_input == null:
		return
	_setup_input.text = text
	_setup_input.caret_column = text.length()
	_setup_error.text = ""


func setup_error(text: String) -> void:
	if is_open("setup"):
		_setup_error.text = text


func _open_confirm_reset(value: int) -> void:
	var m := UiKit.modal(1000)
	var box: VBoxContainer = m.box
	box.add_child(UiKit.label("最終確認", 52, UiKit.BAD, HORIZONTAL_ALIGNMENT_CENTER))
	var body := UiKit.label("最大番号 %d で新しいゲームを始めます。\n現在のゲーム（%s）はリセットされます。" % [value, _setup_game_info], 30, UiKit.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(body)
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	var cancel := UiKit.button("キャンセル", 34)
	cancel.pressed.connect(func():
		close("confirm_reset")
		focus_setup_input())
	btns.add_child(cancel)
	var go := UiKit.button("リセットして開始", 34)
	go.add_theme_color_override("font_color", UiKit.BAD)
	go.pressed.connect(func():
		close("confirm_reset")
		start_game_requested.emit(value))
	btns.add_child(go)
	box.add_child(btns)
	box.add_child(_key_hint("← → で選択して Enter　／　Esc でキャンセル"))
	_open("confirm_reset", m.root)
	cancel.grab_focus.call_deferred()


# ---------------------------------------------------------------- restore

func open_restore(max_number: int, count: int, last: int, finished: bool) -> void:
	var m := UiKit.modal(900)
	var box: VBoxContainer = m.box
	box.add_child(UiKit.label("前回のゲームを復元しました", 50, UiKit.ACCENT, HORIZONTAL_ALIGNMENT_CENTER))
	var body := "最大番号 %d   ・   %d球抽選済み   ・   残り %d" % [max_number, count, max_number - count]
	box.add_child(UiKit.label(body, 32, UiKit.TEXT, HORIZONTAL_ALIGNMENT_CENTER))
	if last > 0:
		box.add_child(UiKit.label("最後の番号： %d" % last, 40, UiKit.TEXT, HORIZONTAL_ALIGNMENT_CENTER))
	if finished:
		box.add_child(UiKit.label("このゲームは全ての番号が出ています。新しいゲームは M キー（最大番号・リセット）から。", 26, UiKit.MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	else:
		box.add_child(UiKit.label("このまま続けられます。スマホのレバーを引くとこの画面は閉じます。", 26, UiKit.MUTED, HORIZONTAL_ALIGNMENT_CENTER))
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	var conn := UiKit.button("スマホ接続画面（Q）", 30)
	conn.pressed.connect(func():
		close("restore")
		open_connect())
	btns.add_child(conn)
	var ok := UiKit.button("続ける", 40)
	ok.custom_minimum_size = Vector2(260, 84)
	ok.pressed.connect(func(): close("restore"))
	btns.add_child(ok)
	box.add_child(btns)
	box.add_child(_key_hint("Enter で続ける"))
	_open("restore", m.root)
	ok.grab_focus.call_deferred()


# ---------------------------------------------------------------- connect / QR

func open_connect() -> void:
	var m := UiKit.modal(1500)
	var box: VBoxContainer = m.box
	box.add_child(UiKit.label("スマホ・iPad（リモコン）を接続", 50, UiKit.ACCENT, HORIZONTAL_ALIGNMENT_CENTER))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 48)
	box.add_child(row)
	var qr_bg := PanelContainer.new()
	qr_bg.add_theme_stylebox_override("panel", UiKit.panel_style(Color.WHITE, 16))
	row.add_child(qr_bg)
	_connect_qr = TextureRect.new()
	_connect_qr.custom_minimum_size = Vector2(480, 480)
	_connect_qr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_connect_qr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_connect_qr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	qr_bg.add_child(_connect_qr)
	var info := VBoxContainer.new()
	info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	info.add_theme_constant_override("separation", 14)
	row.add_child(info)
	for line in [
		"1. スマホ・iPadをこのPCと同じ Wi-Fi / LAN に接続",
		"2. カメラでQRコードを読み取り、表示されたリンクを開く",
		"3. 画面のレバーを下まで引いて離すと抽選されます",
	]:
		var l := UiKit.label(line, 30)
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		info.add_child(l)
	info.add_child(UiKit.label("接続先（QRには接続コード付きのURLが入っています）", 24, UiKit.MUTED))
	_connect_url = UiKit.label("", 40, UiKit.ACCENT)
	info.add_child(_connect_url)
	_connect_status = UiKit.label("", 28, UiKit.MUTED)
	info.add_child(_connect_status)
	var note := UiKit.label("つながらない時：Windowsファイアウォールで「プライベート ネットワーク」を許可／ゲストWi-Fi・VPNを使わない／下のボタンで別のIPを試す。\nLAN内の通信は暗号化されません。公共Wi-Fiでは使わないでください。", 22, UiKit.MUTED)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.custom_minimum_size = Vector2(860, 0)
	info.add_child(note)
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	_connect_ip_btn = UiKit.button("別のIPを表示（I）", 28)
	_connect_ip_btn.pressed.connect(next_ip)
	btns.add_child(_connect_ip_btn)
	var reissue := UiKit.button("QRを再発行（R）", 28)
	reissue.pressed.connect(func(): reissue_token_requested.emit())
	btns.add_child(reissue)
	var close_btn := UiKit.button("閉じる（Q / Esc）", 32)
	close_btn.pressed.connect(func(): close("connect"))
	btns.add_child(close_btn)
	box.add_child(btns)
	box.add_child(_key_hint("I：別のIP　R：QR再発行（古い接続を無効化）　Q / Esc：閉じる　Space：閉じて抽選"))
	_open("connect", m.root)
	# The network may have changed since the server started (Wi-Fi joined late,
	# new DHCP address, cable unplugged): read the addresses again so the QR
	# and the server's Host check use the current ones.
	if server != null:
		server.refresh_addresses()
	refresh_connect()


func next_ip() -> void:
	_ip_index += 1
	refresh_connect()


func refresh_connect() -> void:
	if not is_open("connect") or server == null:
		return
	var addrs: Array = server.lan_addresses()
	if not server.running:
		_connect_url.text = "サーバー停止中"
		_connect_status.text = server.start_error
		_connect_qr.texture = null
		return
	if addrs.is_empty():
		_connect_url.text = "LANのIPアドレスが見つかりません"
		_connect_status.text = "Wi-Fi / 有線LANに接続しているか確認してください（このPC内のテスト: http://127.0.0.1:%d/）" % server.port
		_connect_qr.texture = null
		_connect_ip_btn.disabled = true
		return
	_ip_index = _ip_index % addrs.size()
	var a: Dictionary = addrs[_ip_index]
	_connect_ip_btn.disabled = addrs.size() <= 1
	_connect_url.text = server.base_url(a.ip)
	var label: String = a.name if not String(a.name).is_empty() else "ネットワーク"
	if not a.get("active", true):
		label += "・未接続の可能性"
	var n: int = server.client_count()
	_connect_status.text = "%s（%d/%d）   ・   接続中のリモコン：%d台" % [label, _ip_index + 1, addrs.size(), n]
	var q = QrCode.encode_text(server.pairing_url(a.ip), QrCode.ECC_M)
	if q != null:
		_connect_qr.texture = ImageTexture.create_from_image(q.to_image(8, 4))


# ---------------------------------------------------------------- settings

func open_settings(game_info: String) -> void:
	var m := UiKit.modal(1040)
	var box: VBoxContainer = m.box
	box.add_child(UiKit.label("設定", 50, UiKit.ACCENT, HORIZONTAL_ALIGNMENT_CENTER))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 30)
	grid.add_theme_constant_override("v_separation", 20)
	box.add_child(grid)

	# Two independent levels: sound effects (SE) and background music (BGM).
	grid.add_child(UiKit.label("効果音（SE）の音量", 32))
	var vol := HSlider.new()
	vol.name = "SeVolume"
	vol.min_value = 0
	vol.max_value = 100
	vol.step = 5
	vol.value = settings.se_volume * 100.0
	vol.custom_minimum_size = Vector2(520, 48)
	vol.focus_mode = Control.FOCUS_ALL
	vol.value_changed.connect(func(v):
		settings.se_volume = v / 100.0
		settings_changed.emit()
		se_preview_requested.emit())
	grid.add_child(vol)

	grid.add_child(UiKit.label("BGM の音量", 32))
	var bgm_row := HBoxContainer.new()
	bgm_row.add_theme_constant_override("separation", 18)
	var bgm_vol := HSlider.new()
	bgm_vol.name = "BgmVolume"
	bgm_vol.min_value = 0
	bgm_vol.max_value = 100
	bgm_vol.step = 5
	bgm_vol.value = settings.bgm_volume * 100.0
	bgm_vol.custom_minimum_size = Vector2(300, 48)
	bgm_vol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bgm_vol.focus_mode = Control.FOCUS_ALL
	bgm_vol.value_changed.connect(func(v):
		settings.bgm_volume = v / 100.0
		settings_changed.emit())
	bgm_row.add_child(bgm_vol)
	var bgm_on := CheckButton.new()
	bgm_on.name = "BgmSwitch"
	bgm_on.button_pressed = settings.bgm_enabled
	bgm_on.text = "オン（Bキー）"
	bgm_on.add_theme_font_size_override("font_size", 26)
	bgm_on.toggled.connect(func(on):
		settings.bgm_enabled = on
		settings_changed.emit())
	bgm_row.add_child(bgm_on)
	grid.add_child(bgm_row)

	grid.add_child(UiKit.label("演出の長さ", 32))
	var speed := OptionButton.new()
	speed.add_theme_font_size_override("font_size", 30)
	var keys: Array = AppSettings.SPEED_OPTIONS
	for k in keys:
		if k == "random":
			speed.add_item("%s（毎回 短い・標準・長い のどれか）" % AppSettings.SPEED_LABELS[k])
		else:
			speed.add_item("%s（約%.1f秒）" % [AppSettings.SPEED_LABELS[k], AppSettings.BASE_TIMING.reveal_end * AppSettings.SPEEDS[k]])
	speed.selected = keys.find(settings.speed)
	speed.item_selected.connect(func(i):
		settings.speed = keys[i]
		settings_changed.emit())
	grid.add_child(speed)

	grid.add_child(UiKit.label("高画質エフェクト", 32))
	var fx := CheckButton.new()
	fx.name = "EffectsSwitch"
	fx.button_pressed = settings.effects_high
	fx.text = "床の映り込み・接地の影（動きが重い時はオフ）"
	fx.add_theme_font_size_override("font_size", 26)
	fx.toggled.connect(func(on):
		settings.effects_high = on
		settings_changed.emit())
	grid.add_child(fx)

	grid.add_child(UiKit.label("フルスクリーン", 32))
	var fs := CheckButton.new()
	fs.button_pressed = settings.fullscreen
	fs.text = "F11でも切替"
	fs.add_theme_font_size_override("font_size", 26)
	fs.toggled.connect(func(on):
		settings.fullscreen = on
		settings_changed.emit())
	grid.add_child(fs)

	grid.add_child(UiKit.label("画面の余白（テレビの端切れ対策）", 32))
	var margin := HSlider.new()
	margin.min_value = 0
	margin.max_value = 8
	margin.step = 1
	margin.value = roundf(settings.safe_margin * 100.0)
	margin.custom_minimum_size = Vector2(520, 48)
	margin.focus_mode = Control.FOCUS_ALL
	margin.value_changed.connect(func(v):
		settings.safe_margin = v / 100.0
		settings_changed.emit())
	grid.add_child(margin)

	var info := UiKit.label(game_info, 24, UiKit.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info)
	var btns := HBoxContainer.new()
	btns.alignment = BoxContainer.ALIGNMENT_CENTER
	var conn := UiKit.button("スマホ接続（Q）", 28)
	conn.pressed.connect(func():
		close("settings")
		open_connect())
	btns.add_child(conn)
	var newgame := UiKit.button("最大番号・リセット（M）", 28)
	newgame.pressed.connect(func():
		close("settings")
		setup_requested.emit())
	btns.add_child(newgame)
	var lic := UiKit.button("ライセンス（L）", 28)
	lic.pressed.connect(func():
		close("settings")
		open_licenses())
	btns.add_child(lic)
	var quit := UiKit.button("アプリを終了", 28)
	quit.pressed.connect(func(): quit_requested.emit())
	btns.add_child(quit)
	var close_btn := UiKit.button("閉じる（Esc）", 32)
	close_btn.pressed.connect(func(): close("settings"))
	btns.add_child(close_btn)
	box.add_child(btns)
	box.add_child(_key_hint("↑↓ / Tab で項目移動、← → で値を変更、Enter で決定、Esc で閉じる"))
	_open("settings", m.root)
	vol.grab_focus.call_deferred()


# ---------------------------------------------------------------- licenses

## Third-party notices inside the app, so the exe alone carries them.
func open_licenses() -> void:
	var m := UiKit.modal(1500)
	var box: VBoxContainer = m.box
	box.add_child(UiKit.label("ライセンス表記", 50, UiKit.ACCENT, HORIZONTAL_ALIGNMENT_CENTER))
	var summary := UiKit.label(Licenses.SUMMARY_JA, 26, UiKit.TEXT)
	summary.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(summary)
	# Read-only TextEdit: handles ~100 KB of text and scrolls with ↑↓ / PageUp / PageDown.
	var text := TextEdit.new()
	text.name = "LicenseText"
	text.text = Licenses.build_text()
	text.editable = false
	text.context_menu_enabled = false
	text.shortcut_keys_enabled = true
	text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	text.custom_minimum_size = Vector2(1400, 540)
	text.add_theme_font_size_override("font_size", 20)
	text.add_theme_color_override("font_readonly_color", Color(0.85, 0.88, 0.97))
	text.add_theme_stylebox_override("read_only", UiKit.panel_style(Color(0.04, 0.05, 0.1), 12))
	# Viewer keys scroll the view directly (the default first moves an invisible caret).
	text.gui_input.connect(func(ev: InputEvent):
		if not (ev is InputEventKey) or not ev.pressed:
			return
		var page := maxf(1.0, text.get_visible_line_count() - 1)
		var delta := 0.0
		match ev.keycode:
			KEY_DOWN: delta = 3.0
			KEY_UP: delta = -3.0
			KEY_PAGEDOWN: delta = page
			KEY_PAGEUP: delta = -page
			KEY_HOME: delta = -INF
			KEY_END: delta = INF
			_: return
		text.scroll_vertical = clampf(text.scroll_vertical + delta, 0.0, maxf(0.0, text.get_line_count() * 4.0))
		text.accept_event())
	box.add_child(text)
	var close_btn := UiKit.button("閉じる（Esc）", 32)
	close_btn.pressed.connect(func(): close("licenses"))
	var c := CenterContainer.new()
	c.add_child(close_btn)
	box.add_child(c)
	box.add_child(_key_hint("↑↓ / PageUp / PageDown でスクロール　／　Tab でボタンへ　／　Esc で閉じる"))
	_open("licenses", m.root)
	text.grab_focus.call_deferred()


# ---------------------------------------------------------------- help

func open_help() -> void:
	var m := UiKit.modal(1100)
	var box: VBoxContainer = m.box
	box.add_child(UiKit.label("キー操作", 50, UiKit.ACCENT, HORIZONTAL_ALIGNMENT_CENTER))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 40)
	grid.add_theme_constant_override("v_separation", 10)
	for pair in [
		["Space / Enter", "抽選（番号一覧画面からでも可）"],
		["H", "これまでに出た番号の一覧画面 ⇔ メイン画面"],
		["M", "最大番号の設定・リセット画面"],
		["Q", "スマホ・iPad 接続画面（QR）"],
		["S / Esc", "設定（Esc は画面を閉じる・戻る）"],
		["B", "BGM のオン／オフ（音量は設定画面）"],
		["F11", "フルスクリーン切替"],
		["L", "ライセンス表記"],
		["F1 / ?", "このキー一覧"],
	]:
		grid.add_child(UiKit.label(pair[0], 32, UiKit.ACCENT))
		grid.add_child(UiKit.label(pair[1], 32))
	box.add_child(grid)
	var close_btn := UiKit.button("閉じる（Esc）", 32)
	close_btn.pressed.connect(func(): close("help"))
	var c := CenterContainer.new()
	c.add_child(close_btn)
	box.add_child(c)
	_open("help", m.root)
	close_btn.grab_focus.call_deferred()


# ---------------------------------------------------------------- banners / toast

func _build_banners() -> void:
	_banner = PanelContainer.new()
	_banner.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.12, 0.1, 0.02, 0.92), 20))
	_banner_label = UiKit.label("", 44, UiKit.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_banner.add_child(_banner_label)
	_banner.visible = false
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_banner)
	_error_banner = PanelContainer.new()
	_error_banner.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.45, 0.04, 0.1, 0.95), 16))
	_error_label = UiKit.label("", 30, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_error_banner.add_child(_error_label)
	_error_banner.visible = false
	_error_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_error_banner)
	_toast = PanelContainer.new()
	_toast.add_theme_stylebox_override("panel", UiKit.panel_style(Color(0.1, 0.13, 0.24, 0.95), 16))
	_toast_label = UiKit.label("", 28, UiKit.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	_toast.add_child(_toast_label)
	_toast.visible = false
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_toast)
	resized.connect(_layout_banners)


func _layout_banners() -> void:
	var s := size
	for p in [_banner, _error_banner, _toast]:
		p.reset_size()
	_banner.position = Vector2((s.x - 700.0 - _banner.size.x) * 0.5, s.y * 0.06)
	_error_banner.size.x = minf(s.x * 0.7, 1300)
	_error_banner.position = Vector2((s.x - _error_banner.size.x) * 0.5, s.y * 0.02)
	_toast.position = Vector2((s.x - _toast.size.x) * 0.5, s.y * 0.5)


func show_banner(text: String) -> void:
	_banner_label.text = text
	_banner.visible = not text.is_empty()
	_layout_banners.call_deferred()


func show_error(text: String) -> void:
	_error_label.text = text
	_error_banner.visible = not text.is_empty()
	_layout_banners.call_deferred()


func toast(text: String, seconds: float = 2.5) -> void:
	_toast_label.text = text
	_toast.visible = true
	_toast.modulate.a = 1.0
	_layout_banners.call_deferred()
	if _toast_tween:
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_interval(seconds)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.4)
	_toast_tween.tween_callback(func(): _toast.visible = false)

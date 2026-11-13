extends Control
## TV main screen overlay: ONLY the current number (right) on top of the 3D
## machine (left). Past numbers live on the separate history screen.

const UiKit = preload("res://scripts/ui/ui_kit.gd")
const BallColors = preload("res://scripts/util/ball_colors.gd")

const PANEL_W := 700.0

var safe_margin := 0.03
var max_number := 75

var _panel: Panel
var _caption: Label
var _letter: Label
var _number: Label
var _sub: Label
var _status: Label
var _number_tween: Tween
var _glow: TextureRect
var _glow_tween: Tween


func _ready() -> void:
	UiKit.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel = Panel.new()
	_panel.add_theme_stylebox_override("panel", UiKit.panel_style(UiKit.PANEL, 32))
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.clip_contents = true
	add_child(_panel)
	# Soft light in the color of the drawn ball behind the number; bursts on reveal.
	var grad := Gradient.new()
	grad.set_color(0, Color(1, 1, 1, 0.9))
	grad.set_color(1, Color(1, 1, 1, 0.0))
	grad.add_point(0.45, Color(1, 1, 1, 0.3))
	var gtex := GradientTexture2D.new()
	gtex.gradient = grad
	gtex.fill = GradientTexture2D.FILL_RADIAL
	gtex.fill_from = Vector2(0.5, 0.5)
	gtex.fill_to = Vector2(1.0, 0.5)
	gtex.width = 256
	gtex.height = 256
	_glow = TextureRect.new()
	_glow.texture = gtex
	_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_glow.stretch_mode = TextureRect.STRETCH_SCALE
	_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_glow.modulate = Color(1, 1, 1, 0.0)
	_panel.add_child(_glow)
	_caption = UiKit.label("今回の番号", 46, UiKit.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_panel.add_child(_caption)
	_letter = UiKit.label("", 96, UiKit.ACCENT, HORIZONTAL_ALIGNMENT_CENTER)
	_letter.add_theme_font_override("font", UiKit.font(900))
	_panel.add_child(_letter)
	_number = UiKit.label("", 380, UiKit.TEXT, HORIZONTAL_ALIGNMENT_CENTER)
	_number.add_theme_font_override("font", UiKit.number_font())
	_number.add_theme_constant_override("outline_size", 22)
	_number.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.6))
	_panel.add_child(_number)
	_sub = UiKit.label("", 36, UiKit.MUTED, HORIZONTAL_ALIGNMENT_CENTER)
	_panel.add_child(_sub)
	_status = UiKit.label("", 24, UiKit.MUTED)
	# Dark pill behind the text: stays readable on the colorful party backdrop.
	var pill := UiKit.panel_style(Color(0.03, 0.02, 0.08, 0.72), 18)
	pill.content_margin_left = 16
	pill.content_margin_right = 16
	pill.content_margin_top = 4
	pill.content_margin_bottom = 4
	_status.add_theme_stylebox_override("normal", pill)
	add_child(_status)
	resized.connect(_layout)
	_layout()


func set_safe_margin(m: float) -> void:
	safe_margin = m
	_layout()


func _layout() -> void:
	var s := size
	if s.x <= 0:
		return
	var m := Vector2(s.x, s.y) * safe_margin
	var panel_h := s.y - m.y * 2.0
	_panel.position = Vector2(s.x - m.x - PANEL_W, m.y)
	_panel.size = Vector2(PANEL_W, panel_h)
	var w := PANEL_W
	_caption.position = Vector2(0, 40)
	_caption.size = Vector2(w, 60)
	_letter.position = Vector2(0, 120)
	_letter.size = Vector2(w, 110)
	_number.position = Vector2(0, 230)
	_number.size = Vector2(w, maxf(240.0, panel_h - 230 - 140))
	_number.pivot_offset = _number.size * 0.5
	var glow_size := w * 1.25
	_glow.size = Vector2(glow_size, glow_size)
	_glow.position = _number.position + _number.size * 0.5 - _glow.size * 0.5
	_glow.pivot_offset = _glow.size * 0.5
	_sub.position = Vector2(0, panel_h - 110)
	_sub.size = Vector2(w, 60)
	_status.position = Vector2(m.x + 8, m.y)
	_status.reset_size()  # pill hugs the text


## Normalized rect (0..1) of the free area for the 3D machine.
func machine_view_rect() -> Rect2:
	var s := size
	if s.x <= 0 or s.y <= 0:
		return Rect2(0, 0, 0.6, 1.0)
	var m := Vector2(s.x, s.y) * safe_margin
	var r := Rect2(m.x, m.y + 30, s.x - PANEL_W - m.x * 2.0 - 24.0, s.y - m.y * 2.0 - 30)
	return Rect2(r.position / s, r.size / s)


## Small operational line (remote connection etc). Empty text hides it.
func set_status(text: String, color: Color = UiKit.MUTED) -> void:
	_status.text = text
	_status.visible = not text.is_empty()
	_status.add_theme_color_override("font_color", color.lightened(0.15))
	_status.reset_size()


## Full refresh without animation. `revealed` = numbers in draw order.
func set_state(p_max: int, revealed: Array, phase: String) -> void:
	max_number = p_max
	var last: int = int(revealed[revealed.size() - 1]) if not revealed.is_empty() else 0
	_show_number(last, false)
	_update_sub(revealed.size(), phase)


func show_spinning(revealed_count: int) -> void:
	_caption.text = "抽選中…"
	_caption.add_theme_color_override("font_color", UiKit.ACCENT)
	if _number_tween:
		_number_tween.kill()
	_number_tween = create_tween()
	_number_tween.tween_property(_number, "modulate:a", 0.25, 0.25)
	_number_tween.parallel().tween_property(_number, "scale", Vector2.ONE * 0.6, 0.25)
	_letter.modulate.a = 0.25
	if _glow_tween:
		_glow_tween.kill()
	_glow_tween = create_tween()
	_glow_tween.tween_property(_glow, "modulate:a", 0.0, 0.25)
	_sub.text = "%d球目" % (revealed_count + 1)
	if revealed_count == 0:
		_number.text = ""


func reveal(revealed: Array, phase: String) -> void:
	var n: int = int(revealed[revealed.size() - 1])
	_show_number(n, true)
	_update_sub(revealed.size(), phase)


func _show_number(n: int, animate: bool) -> void:
	_caption.text = "今回の番号"
	_caption.add_theme_color_override("font_color", UiKit.MUTED)
	if _number_tween:
		_number_tween.kill()
	if _glow_tween:
		_glow_tween.kill()
	if n <= 0:
		_glow.modulate.a = 0.0
		_number.text = "—" if max_number > 0 else ""
		_number.add_theme_font_size_override("font_size", 140)
		_number.add_theme_color_override("font_color", UiKit.MUTED)
		_letter.text = ""
		_number.modulate.a = 1.0
		_number.scale = Vector2.ONE
		return
	_number.text = str(n)
	var col := BallColors.color_for(n, max_number)
	_number.add_theme_color_override("font_color", col.lightened(0.25) if BallColors.band(n, max_number) != 2 else Color.WHITE)
	_letter.text = BallColors.letter_for(n, max_number)
	_letter.add_theme_color_override("font_color", col.lightened(0.2))
	_letter.modulate.a = 1.0
	_number.add_theme_font_size_override("font_size", 380 if n < 100 else 290)
	var glow_col := col.lightened(0.15)
	_glow.scale = Vector2.ONE
	if animate:
		_glow.modulate = Color(glow_col.r, glow_col.g, glow_col.b, 0.95)
		_glow.scale = Vector2.ONE * 0.35
		_glow_tween = create_tween()
		_glow_tween.tween_property(_glow, "scale", Vector2.ONE * 1.25, 0.45).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_glow_tween.parallel().tween_property(_glow, "modulate:a", 0.2, 1.1).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		_glow_tween.tween_property(_glow, "scale", Vector2.ONE, 0.6)
	else:
		_glow.modulate = Color(glow_col.r, glow_col.g, glow_col.b, 0.2)
	if animate:
		_number.modulate.a = 0.0
		_number.scale = Vector2.ONE * 1.6
		_number_tween = create_tween()
		_number_tween.tween_property(_number, "modulate:a", 1.0, 0.12)
		_number_tween.parallel().tween_property(_number, "scale", Vector2.ONE, 0.32).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	else:
		_number.modulate.a = 1.0
		_number.scale = Vector2.ONE


func _update_sub(count: int, phase: String) -> void:
	if max_number <= 0:
		_sub.text = ""
	elif phase == "finished":
		_sub.text = "全ての番号が出ました"
	elif count == 0:
		_sub.text = "1〜%d" % max_number
	else:
		_sub.text = "%d球目" % count

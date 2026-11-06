extends RefCounted
## Small helpers to build the TV UI in code (no hand-written .tscn needed).

const BG := Color(0.035, 0.045, 0.085)
const PANEL := Color(0.07, 0.09, 0.16, 0.86)
const PANEL_SOLID := Color(0.08, 0.1, 0.18, 0.98)
const TEXT := Color(0.95, 0.96, 1.0)
const MUTED := Color(0.6, 0.65, 0.82)
const ACCENT := Color(1.0, 0.8, 0.2)
const OK := Color(0.22, 0.85, 0.59)
const BAD := Color(1.0, 0.33, 0.44)

static var _font_cache := {}


static func font(weight: int = 700) -> Font:
	if _font_cache.has(weight):
		return _font_cache[weight]
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["BIZ UDPGothic", "Yu Gothic UI", "Yu Gothic", "Meiryo UI", "Meiryo", "Segoe UI", "Arial"])
	f.font_weight = weight
	f.antialiasing = TextServer.FONT_ANTIALIASING_GRAY
	_font_cache[weight] = f
	return f


static func number_font() -> Font:
	if _font_cache.has("num"):
		return _font_cache["num"]
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["Arial Black", "Segoe UI Black", "Bahnschrift", "Arial", "Yu Gothic UI"])
	f.font_weight = 900
	_font_cache["num"] = f
	return f


static func make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = font(700)
	t.default_font_size = 30
	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("panel", "PanelContainer", panel_style(PANEL_SOLID, 22))
	var normal := panel_style(Color(0.16, 0.2, 0.34), 14)
	normal.content_margin_left = 26
	normal.content_margin_right = 26
	normal.content_margin_top = 12
	normal.content_margin_bottom = 12
	var hover := normal.duplicate()
	hover.bg_color = Color(0.22, 0.28, 0.46)
	var pressed := normal.duplicate()
	pressed.bg_color = Color(0.12, 0.15, 0.26)
	var focus := normal.duplicate()
	focus.bg_color = Color(0.22, 0.28, 0.46)
	focus.border_color = ACCENT
	focus.set_border_width_all(4)
	var disabled := normal.duplicate()
	disabled.bg_color = Color(0.12, 0.13, 0.18)
	for kind in ["Button", "OptionButton", "CheckButton"]:
		t.set_stylebox("normal", kind, normal)
		t.set_stylebox("hover", kind, hover)
		t.set_stylebox("pressed", kind, pressed)
		t.set_stylebox("focus", kind, focus)
		t.set_stylebox("disabled", kind, disabled)
		t.set_color("font_color", kind, TEXT)
		t.set_color("font_hover_color", kind, TEXT)
		t.set_color("font_pressed_color", kind, ACCENT)
		t.set_color("font_focus_color", kind, TEXT)
		t.set_color("font_disabled_color", kind, Color(0.45, 0.48, 0.6))
	var le := panel_style(Color(0.04, 0.05, 0.1), 12)
	le.border_color = Color(0.35, 0.42, 0.7)
	le.set_border_width_all(3)
	le.content_margin_left = 20
	le.content_margin_right = 20
	var le_focus := le.duplicate()
	le_focus.border_color = ACCENT
	t.set_stylebox("normal", "LineEdit", le)
	t.set_stylebox("focus", "LineEdit", le_focus)
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_color("caret_color", "LineEdit", ACCENT)
	t.set_constant("separation", "VBoxContainer", 16)
	t.set_constant("separation", "HBoxContainer", 16)
	var grabber := panel_style(ACCENT, 12)
	t.set_stylebox("slider", "HSlider", panel_style(Color(0.16, 0.2, 0.34), 8))
	t.set_stylebox("grabber_area", "HSlider", panel_style(Color(0.85, 0.65, 0.15), 8))
	t.set_stylebox("grabber_area_highlight", "HSlider", grabber)
	return t


static func panel_style(color: Color, radius: int = 18) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(radius)
	s.content_margin_left = 28
	s.content_margin_right = 28
	s.content_margin_top = 22
	s.content_margin_bottom = 22
	s.anti_aliasing = true
	return s


static func label(text: String, size: int = 30, color: Color = TEXT, align: int = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	return l


static func button(text: String, size: int = 30) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", size)
	b.focus_mode = Control.FOCUS_ALL
	return b


static func full_rect(c: Control) -> Control:
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.offset_left = 0
	c.offset_top = 0
	c.offset_right = 0
	c.offset_bottom = 0
	return c


## A dimmed full-screen layer with a centered card. Returns { root, card, box }.
static func modal(width: int = 900) -> Dictionary:
	var root := Control.new()
	full_rect(root)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.03, 0.72)
	full_rect(dim)
	root.add_child(dim)
	var center := CenterContainer.new()
	full_rect(center)
	root.add_child(center)
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(width, 0)
	center.add_child(card)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 22)
	card.add_child(box)
	return {"root": root, "card": card, "box": box}

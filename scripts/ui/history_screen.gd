extends Control
## Separate full-screen page: every number 1..N in rows of 10, drawn ones filled.
## Toggled with H (keyboard) or the "番号一覧" button on the phone / iPad.

const UiKit = preload("res://scripts/ui/ui_kit.gd")
const NumberBoard = preload("res://scripts/ui/number_board.gd")

var safe_margin := 0.03
var _bg: ColorRect
var _title: Label
var _counts: Label
var _hint: Label
var _board_panel: Panel
var _board: NumberBoard


func _ready() -> void:
	UiKit.full_rect(self)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_bg = ColorRect.new()
	_bg.color = Color(0.03, 0.04, 0.08, 1.0)
	UiKit.full_rect(_bg)
	add_child(_bg)
	_title = UiKit.label("これまでに出た番号", 54, UiKit.ACCENT)
	add_child(_title)
	_counts = UiKit.label("", 40, UiKit.TEXT, HORIZONTAL_ALIGNMENT_RIGHT)
	add_child(_counts)
	_board_panel = Panel.new()
	_board_panel.add_theme_stylebox_override("panel", UiKit.panel_style(UiKit.PANEL, 22))
	add_child(_board_panel)
	_board = NumberBoard.new()
	_board_panel.add_child(_board)
	_hint = UiKit.label("H / Esc：メイン画面に戻る　　Space：抽選（メイン画面に戻って抽選）", 24, Color(0.5, 0.55, 0.72), HORIZONTAL_ALIGNMENT_RIGHT)
	add_child(_hint)
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
	var w := s.x - m.x * 2.0
	_title.position = m
	_title.size = Vector2(w * 0.6, 70)
	_counts.position = Vector2(m.x + w * 0.4, m.y)
	_counts.size = Vector2(w * 0.6, 70)
	var board_top := m.y + 84.0
	_board_panel.position = Vector2(m.x, board_top)
	_board_panel.size = Vector2(w, s.y - board_top - m.y - 44.0)
	_board.position = Vector2(18, 16)
	_board.size = _board_panel.size - Vector2(36, 32)
	_hint.position = Vector2(m.x, s.y - m.y - 34.0)
	_hint.size = Vector2(w, 32)


func set_state(max_number: int, revealed: Array, phase: String) -> void:
	_board.set_state(max_number, revealed)
	if max_number <= 0:
		_counts.text = ""
	elif phase == "finished":
		_counts.text = "%d球 ・ 全ての番号が出ました" % revealed.size()
	else:
		_counts.text = "%d球 ・ 残り %d  （1〜%d）" % [revealed.size(), max_number - revealed.size(), max_number]

extends Control
## Every number 1..N, 10 per row (1-10, 11-20, ...). Drawn numbers are filled
## with their ball color, the latest one pulses. When N is large the rows are
## split into side-by-side blocks so the cells stay readable.
## Custom-drawn (one rect + one string per cell) so N up to 999 stays cheap.

const BallColors = preload("res://scripts/util/ball_colors.gd")
const UiKit = preload("res://scripts/ui/ui_kit.gd")

const PER_ROW := 10
const BLOCK_GAP := 28.0

var max_number := 75
var drawn := {}       # number -> draw index
var latest := 0
var _pulse := 0.0
var _num_font: Font


func _ready() -> void:
	_num_font = UiKit.number_font()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)


func set_state(p_max: int, numbers: Array) -> void:
	max_number = p_max
	drawn.clear()
	for i in numbers.size():
		drawn[int(numbers[i])] = i + 1
	latest = int(numbers[numbers.size() - 1]) if not numbers.is_empty() else 0
	queue_redraw()


func _process(delta: float) -> void:
	if latest > 0 and is_visible_in_tree():
		_pulse = fmod(_pulse + delta * 2.2, TAU)
		queue_redraw()


## Returns { blocks, rows_per_block, cw, ch } maximizing the cell size.
func layout() -> Dictionary:
	var rows_total := int(ceil(float(max_number) / PER_ROW))
	var best := {"blocks": 1, "rows_per_block": rows_total, "cw": 1.0, "ch": 1.0}
	var best_score := -1.0
	for blocks in range(1, rows_total + 1):
		var rpb := int(ceil(float(rows_total) / blocks))
		var cw := (size.x - BLOCK_GAP * (blocks - 1)) / float(PER_ROW * blocks)
		var ch := size.y / float(rpb)
		if cw <= 0.0 or ch <= 0.0:
			break
		# Readability is limited by the smaller of width and (a bit taller than) height.
		var score := minf(cw, ch * 1.5)
		if score > best_score:
			best_score = score
			best = {"blocks": blocks, "rows_per_block": rpb, "cw": cw, "ch": ch}
	return best


func _draw() -> void:
	if max_number <= 0:
		return
	var l := layout()
	var rpb: int = l.rows_per_block
	var cw: float = l.cw
	var ch: float = minf(l.ch, cw * 0.9)  # don't stretch cells into tall bars
	var block_w := cw * PER_ROW
	var gap := clampf(minf(cw, ch) * 0.07, 1.0, 8.0)
	var fs := int(clampf(minf(ch * 0.6, cw * 0.42), 8.0, 96.0))
	# Center the whole grid vertically when cells were capped.
	var used_h := ch * mini(rpb, int(ceil(float(max_number) / PER_ROW)))
	var y0 := maxf(0.0, (size.y - used_h) * 0.5)
	for n in range(1, max_number + 1):
		var idx := n - 1
		var row := idx / PER_ROW
		var col := idx % PER_ROW
		var block := row / rpb
		var row_in_block := row % rpb
		var origin := Vector2(block * (block_w + BLOCK_GAP), y0)
		var rect := Rect2(origin + Vector2(col * cw + gap * 0.5, row_in_block * ch + gap * 0.5), Vector2(cw - gap, ch - gap))
		var is_drawn := drawn.has(n)
		var fill: Color
		var ink: Color
		if is_drawn:
			fill = BallColors.color_for(n, max_number)
			ink = BallColors.ink_for(n, max_number)
		else:
			fill = Color(0.1, 0.12, 0.2, 0.92)
			ink = Color(0.42, 0.46, 0.62)
		draw_rect(rect, fill)
		if n == latest:
			var glow := 0.5 + 0.5 * sin(_pulse)
			var w := maxf(2.0, gap * 1.1)
			draw_rect(rect.grow(w * 0.5), Color(1, 1, 1, 0.55 + 0.45 * glow), false, w)
		var s := str(n)
		var tsz := _num_font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(_num_font, Vector2(rect.position.x + (rect.size.x - tsz.x) * 0.5, rect.position.y + rect.size.y * 0.5 + fs * 0.36), s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, ink)

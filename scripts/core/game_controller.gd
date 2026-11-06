extends Node
## Authoritative game flow. All spin requests (phone lever, keyboard, tests)
## go through `request_spin()`. The result is decided and persisted HERE,
## before any animation starts. Presenters only visualize the decided number
## and report back via `notify_animation_finished()`.

const GameState = preload("res://scripts/core/game_state.gd")
const SaveStore = preload("res://scripts/core/save_store.gd")
const RandomSource = preload("res://scripts/core/random_source.gd")

enum Phase { SETUP, READY, SPINNING, FINISHED }
const PHASE_NAMES := {Phase.SETUP: "setup", Phase.READY: "ready", Phase.SPINNING: "spinning", Phase.FINISHED: "finished"}

signal phase_changed(phase: int)
## Emitted after the draw is saved. info = { draw_index, number, request_id, source }
signal spin_started(info: Dictionary)
## Emitted when the reveal is complete. info = { draw_index, number }
signal spin_finished(info: Dictionary)
signal state_changed
signal save_error(message: String)

var store: SaveStore
var rng: RefCounted
var state: GameState = null
var phase: int = Phase.SETUP
## Modal UI (settings / confirm dialogs) blocks spins while open.
var paused: bool = false
var restored_from_save: bool = false
var last_error: String = ""

## Animation length the presenter promised; used for the watchdog.
var expected_animation_sec: float = 2.4
var watchdog_margin_sec: float = 3.0
var cooldown_sec: float = 0.3

var _pending: Dictionary = {}
var _watchdog_left: float = -1.0
var _cooldown_left: float = 0.0


func _init(p_store: SaveStore = null, p_rng: RefCounted = null) -> void:
	store = p_store if p_store != null else SaveStore.new()
	rng = p_rng if p_rng != null else RandomSource.secure()


func _process(delta: float) -> void:
	tick(delta)


## Separated from _process so tests can drive time deterministically.
func tick(delta: float) -> void:
	if _cooldown_left > 0.0:
		_cooldown_left = maxf(0.0, _cooldown_left - delta)
		if _cooldown_left <= 0.0:
			state_changed.emit()  # can_spin flipped to true
	if phase == Phase.SPINNING and _watchdog_left >= 0.0:
		_watchdog_left -= delta
		if _watchdog_left < 0.0:
			push_warning("GameController: animation watchdog fired; forcing reveal")
			_finish_pending()


## Loads the latest save. Returns true when a game was restored.
func restore() -> bool:
	var res: Dictionary = store.load_latest()
	if res.state != null:
		state = res.state
		restored_from_save = true
		_set_phase(Phase.FINISHED if state.is_finished() else Phase.READY)
		state_changed.emit()
		return true
	if res.corrupted:
		if store.archive_current("corrupted") == OK:
			last_error = "保存データが破損していたため読み込めませんでした（ファイルは archive に退避しました）"
		else:
			last_error = "保存データが破損していたため読み込めませんでした（archive への退避にも失敗: %s）" % store.last_error
	_set_phase(Phase.SETUP)
	return false


## Starts a new game (archives previous save files first). Returns { ok, error }.
## request_id (remote "new_game") is saved with the game so a re-send is
## recognised as a duplicate even after a restart.
func start_new_game(max_number: int, request_id: String = "") -> Dictionary:
	if phase == Phase.SPINNING:
		return {"ok": false, "error": "抽選演出中は開始できません"}
	var check: Dictionary = GameState.validate_max_number(max_number)
	if not check.ok:
		return {"ok": false, "error": check.error}
	var s: GameState = GameState.create(max_number, rng)
	s.set_new_game_origin(request_id, state.new_game_ids if state != null else [])
	if state != null:
		# The previous game's record must be safely archived before it can be replaced.
		if store.archive_current(state.game_id) != OK:
			last_error = "前のゲームの記録を退避できないため、新しいゲームを開始しませんでした: " + store.last_error
			save_error.emit(last_error)
			return {"ok": false, "error": last_error}
	var err: Error = store.save(s)
	if err != OK:
		last_error = "保存に失敗しました: " + store.last_error
		save_error.emit(last_error)
		return {"ok": false, "error": last_error}
	state = s
	restored_from_save = false
	_pending = {}
	_cooldown_left = 0.0
	_set_phase(Phase.READY)
	state_changed.emit()
	return {"ok": true, "error": ""}


## True when this (saved) game or an earlier one was created by request_id.
func was_new_game_applied(request_id: String) -> bool:
	return state != null and state.new_game_ids.has(request_id)


## Returns to the setup screen without deleting anything. The old save stays
## on disk until a new game is saved (and is archived at that moment).
func go_to_setup() -> void:
	if phase == Phase.SPINNING:
		return
	state = null
	_pending = {}
	_set_phase(Phase.SETUP)
	state_changed.emit()


static func is_valid_request_id(id) -> bool:
	if typeof(id) != TYPE_STRING:
		return false
	var s: String = id
	if s.length() < 8 or s.length() > 64:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		var ok := (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45 or c == 95
		if not ok:
			return false
	return true


## The single entry point for drawing.
## Returns { accepted, duplicate, reason, message, draw_index }.
func request_spin(request_id: String, source: String = "unknown") -> Dictionary:
	if not is_valid_request_id(request_id):
		return _reject("invalid", "不正なリクエストです")
	if state != null:
		var prev: int = state.find_request(request_id)
		if prev >= 1:
			return {"accepted": true, "duplicate": true, "reason": "", "message": "受付済み", "draw_index": prev}
	match phase:
		Phase.SETUP:
			return _reject("not_started", "ゲームが開始されていません")
		Phase.SPINNING:
			return _reject("busy", "抽選中です")
		Phase.FINISHED:
			return _reject("finished", "全ての番号が出ました")
	if paused:
		return _reject("paused", "PC側で設定画面を表示中です")
	if _cooldown_left > 0.0:
		return _reject("busy", "少し待ってから引いてください")
	# Decide + persist on a copy; commit to memory only after a successful save.
	var next: GameState = state.clone()
	var number: int = next.draw(rng, request_id)
	if number <= 0:
		return _reject("finished", "全ての番号が出ました")
	var err: Error = store.save(next)
	if err != OK:
		last_error = "保存に失敗したため抽選を中止しました: " + store.last_error
		save_error.emit(last_error)
		return _reject("save_failed", "PC側で保存エラーが発生しました")
	state = next
	_pending = {"draw_index": state.drawn_count(), "number": number, "request_id": request_id, "source": source}
	_watchdog_left = expected_animation_sec + watchdog_margin_sec
	_set_phase(Phase.SPINNING)
	spin_started.emit(_pending.duplicate())
	state_changed.emit()
	return {"accepted": true, "duplicate": false, "reason": "", "message": "受付", "draw_index": _pending.draw_index}


func _reject(reason: String, message: String) -> Dictionary:
	return {"accepted": false, "duplicate": false, "reason": reason, "message": message, "draw_index": -1}


## Called by the presenter when the reveal animation has finished.
func notify_animation_finished(draw_index: int) -> void:
	if phase != Phase.SPINNING or _pending.is_empty():
		return
	if draw_index != int(_pending.draw_index):
		return
	_finish_pending()


func _finish_pending() -> void:
	var info := {"draw_index": _pending.get("draw_index", 0), "number": _pending.get("number", 0)}
	_pending = {}
	_watchdog_left = -1.0
	_cooldown_left = cooldown_sec
	_set_phase(Phase.FINISHED if state.is_finished() else Phase.READY)
	spin_finished.emit(info)
	state_changed.emit()


func _set_phase(p: int) -> void:
	if phase == p:
		return
	phase = p
	phase_changed.emit(p)


func set_paused(value: bool) -> void:
	if paused == value:
		return
	paused = value
	state_changed.emit()


func phase_name() -> String:
	return PHASE_NAMES.get(phase, "setup")


func is_spinning() -> bool:
	return phase == Phase.SPINNING


func pending_info() -> Dictionary:
	return _pending.duplicate()


## Numbers whose reveal has completed (excludes the one being animated).
func revealed_numbers() -> Array[int]:
	if state == null:
		return []
	var arr: Array[int] = state.drawn.duplicate()
	if phase == Phase.SPINNING and not arr.is_empty():
		arr.remove_at(arr.size() - 1)
	return arr


func can_spin() -> bool:
	return phase == Phase.READY and not paused and _cooldown_left <= 0.0


## Snapshot for remotes. Never contains the number currently being animated.
func get_snapshot() -> Dictionary:
	var revealed := revealed_numbers()
	var recent: Array = []
	for i in range(revealed.size() - 1, maxi(-1, revealed.size() - 6), -1):
		recent.append(revealed[i])
	var maxn: int = state.max_number if state != null else 0
	return {
		"game_id": state.game_id if state != null else "",
		"version": state.version if state != null else 0,
		"phase": phase_name(),
		"paused": paused,
		"max_number": maxn,
		"drawn_count": revealed.size(),
		"remaining": maxn - revealed.size(),
		"last_number": revealed[revealed.size() - 1] if not revealed.is_empty() else null,
		"recent": recent,
		"can_spin": can_spin(),
	}

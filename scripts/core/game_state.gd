extends RefCounted
## Pure, serializable bingo game state.
## - `drawn` keeps the confirmed draw order (index 0 = 1st ball).
## - `remaining` keeps every number not drawn yet (sorted ascending).
## - Invariant: drawn ∪ remaining == {1..max_number}, drawn ∩ remaining == ∅.
## No Node / scene dependencies so it can be unit tested headless.

const SCHEMA_VERSION := 1
const MIN_MAX_NUMBER := 1
const MAX_MAX_NUMBER := 999
const DEFAULT_MAX_NUMBER := 75
const REQUEST_LOG_LIMIT := 64

var game_id: String = ""
var max_number: int = 0
var drawn: Array[int] = []
var remaining: Array[int] = []
var version: int = 0
var created_at: int = 0
var updated_at: int = 0
## Recently accepted spin requests: [{ "id": String, "draw_index": int }]
var request_log: Array = []
## Request ids of recent "new game" commands (the last one created this game).
## Persisted so a re-sent new_game is never applied twice, even across restarts.
var new_game_ids: Array[String] = []
const NEW_GAME_ID_LIMIT := 16


static func _script() -> GDScript:
	return load("res://scripts/core/game_state.gd")


## Validates user text for the max number. Returns { ok, value, error }.
static func validate_max_number_text(text: String) -> Dictionary:
	var t := text.strip_edges()
	if t.is_empty():
		return {"ok": false, "value": 0, "error": "最大番号を入力してください"}
	if t.length() > 6:
		return {"ok": false, "value": 0, "error": "%d〜%d の整数を入力してください" % [MIN_MAX_NUMBER, MAX_MAX_NUMBER]}
	for i in t.length():
		var c := t.unicode_at(i)
		if c < 48 or c > 57:  # only ASCII digits (rejects '-', '+', '.', 'e', full-width)
			return {"ok": false, "value": 0, "error": "%d〜%d の整数を入力してください" % [MIN_MAX_NUMBER, MAX_MAX_NUMBER]}
	var v := t.to_int()
	return validate_max_number(v)


static func validate_max_number(v: int) -> Dictionary:
	if v < MIN_MAX_NUMBER or v > MAX_MAX_NUMBER:
		return {"ok": false, "value": v, "error": "%d〜%d の範囲で入力してください" % [MIN_MAX_NUMBER, MAX_MAX_NUMBER]}
	return {"ok": true, "value": v, "error": ""}


static func create(p_max_number: int, rng: RefCounted) -> RefCounted:
	var check := validate_max_number(p_max_number)
	if not check.ok:
		return null
	var s = _script().new()
	s.game_id = rng.random_hex(8)
	s.max_number = p_max_number
	var rem: Array[int] = []
	for n in range(1, p_max_number + 1):
		rem.append(n)
	s.remaining = rem
	s.version = 1
	s.created_at = int(Time.get_unix_time_from_system())
	s.updated_at = s.created_at
	s.request_log = []
	return s


func clone() -> RefCounted:
	var s = _script().new()
	s.game_id = game_id
	s.max_number = max_number
	s.drawn = drawn.duplicate()
	s.remaining = remaining.duplicate()
	s.version = version
	s.created_at = created_at
	s.updated_at = updated_at
	s.request_log = request_log.duplicate(true)
	s.new_game_ids = new_game_ids.duplicate()
	return s


func is_finished() -> bool:
	return remaining.is_empty()


func drawn_count() -> int:
	return drawn.size()


func last_number() -> int:
	return drawn[drawn.size() - 1] if not drawn.is_empty() else 0


## Returns the 1-based draw index produced by `request_id`, or -1.
func find_request(request_id: String) -> int:
	for entry in request_log:
		if entry.get("id", "") == request_id:
			return int(entry.get("draw_index", -1))
	return -1


## Draws one number uniformly from `remaining`. Mutates this state.
## Returns the drawn number, or 0 when nothing remains.
func draw(rng: RefCounted, request_id: String) -> int:
	if remaining.is_empty():
		return 0
	var idx: int = rng.randi_below(remaining.size())
	var number: int = remaining[idx]
	remaining.remove_at(idx)
	drawn.append(number)
	version += 1
	updated_at = int(Time.get_unix_time_from_system())
	if not request_id.is_empty():
		request_log.append({"id": request_id, "draw_index": drawn.size()})
		while request_log.size() > REQUEST_LOG_LIMIT:
			request_log.remove_at(0)
	return number


func to_dict() -> Dictionary:
	return {
		"schema": SCHEMA_VERSION,
		"game_id": game_id,
		"max_number": max_number,
		"drawn": drawn.duplicate(),
		"remaining": remaining.duplicate(),
		"last_number": last_number(),
		"version": version,
		"created_at": created_at,
		"updated_at": updated_at,
		"request_log": request_log.duplicate(true),
		"new_game_ids": new_game_ids.duplicate(),
		"finished": is_finished(),
	}


static func is_valid_request_id(id) -> bool:
	if typeof(id) != TYPE_STRING:
		return false
	var s: String = id
	if s.length() < 8 or s.length() > 64:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45 or c == 95):
			return false
	return true


## Records the new-game request that created this state, keeping earlier ids.
func set_new_game_origin(request_id: String, previous_ids: Array) -> void:
	var ids: Array[String] = []
	for v in previous_ids:
		if is_valid_request_id(v) and not ids.has(String(v)):
			ids.append(String(v))
	if is_valid_request_id(request_id) and not ids.has(request_id):
		ids.append(request_id)
	while ids.size() > NEW_GAME_ID_LIMIT:
		ids.remove_at(0)
	new_game_ids = ids


static func _as_int(v, out: Array) -> bool:
	# JSON numbers arrive as float; accept only exact integers.
	if typeof(v) == TYPE_INT:
		out.append(v)
		return true
	if typeof(v) == TYPE_FLOAT and is_finite(v) and v == floor(v) and absf(v) < 1e15:
		out.append(int(v))
		return true
	return false


## Strictly validates and rebuilds a state. Returns { ok, state, error }.
static func from_dict(d) -> Dictionary:
	if typeof(d) != TYPE_DICTIONARY:
		return {"ok": false, "state": null, "error": "not a dictionary"}
	var tmp := []
	if not _as_int(d.get("schema"), tmp) or tmp[0] != SCHEMA_VERSION:
		return {"ok": false, "state": null, "error": "unsupported schema"}
	if typeof(d.get("game_id")) != TYPE_STRING or String(d.game_id).is_empty():
		return {"ok": false, "state": null, "error": "bad game_id"}
	tmp.clear()
	if not _as_int(d.get("max_number"), tmp) or not validate_max_number(tmp[0]).ok:
		return {"ok": false, "state": null, "error": "bad max_number"}
	var maxn: int = tmp[0]
	if typeof(d.get("drawn")) != TYPE_ARRAY or typeof(d.get("remaining")) != TYPE_ARRAY:
		return {"ok": false, "state": null, "error": "bad arrays"}
	var seen := {}
	var drawn_arr: Array[int] = []
	for v in d.drawn:
		tmp.clear()
		if not _as_int(v, tmp) or tmp[0] < 1 or tmp[0] > maxn or seen.has(tmp[0]):
			return {"ok": false, "state": null, "error": "bad drawn entry"}
		seen[tmp[0]] = true
		drawn_arr.append(tmp[0])
	var rem_arr: Array[int] = []
	for v in d.remaining:
		tmp.clear()
		if not _as_int(v, tmp) or tmp[0] < 1 or tmp[0] > maxn or seen.has(tmp[0]):
			return {"ok": false, "state": null, "error": "bad remaining entry"}
		seen[tmp[0]] = true
		rem_arr.append(tmp[0])
	if seen.size() != maxn:
		return {"ok": false, "state": null, "error": "numbers do not cover 1..max"}
	tmp.clear()
	if not _as_int(d.get("version"), tmp) or tmp[0] < 1:
		return {"ok": false, "state": null, "error": "bad version"}
	var ver: int = tmp[0]
	if ver != drawn_arr.size() + 1:
		return {"ok": false, "state": null, "error": "version mismatch"}
	if d.has("last_number"):
		tmp.clear()
		var expected_last: int = drawn_arr[drawn_arr.size() - 1] if not drawn_arr.is_empty() else 0
		if not _as_int(d.last_number, tmp) or tmp[0] != expected_last:
			return {"ok": false, "state": null, "error": "last_number mismatch"}
	var s = _script().new()
	s.game_id = String(d.game_id)
	s.max_number = maxn
	s.drawn = drawn_arr
	rem_arr.sort()
	s.remaining = rem_arr
	s.version = ver
	tmp.clear()
	s.created_at = tmp[0] if _as_int(d.get("created_at", 0), tmp) else 0
	tmp.clear()
	s.updated_at = tmp[0] if _as_int(d.get("updated_at", 0), tmp) else 0
	var log := []
	if typeof(d.get("request_log")) == TYPE_ARRAY:
		for e in d.request_log:
			if typeof(e) != TYPE_DICTIONARY or typeof(e.get("id")) != TYPE_STRING:
				continue
			tmp.clear()
			if _as_int(e.get("draw_index"), tmp) and tmp[0] >= 1 and tmp[0] <= drawn_arr.size():
				log.append({"id": String(e.id), "draw_index": tmp[0]})
	s.request_log = log
	var ng: Array[String] = []
	if typeof(d.get("new_game_ids")) == TYPE_ARRAY:  # optional (older saves lack it)
		for v in d.new_game_ids:
			if is_valid_request_id(v) and not ng.has(String(v)):
				ng.append(String(v))
	s.new_game_ids = ng
	return {"ok": true, "state": s, "error": ""}

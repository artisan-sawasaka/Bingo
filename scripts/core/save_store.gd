extends RefCounted
## Crash-safe persistence for GameState.
##
## Write protocol (save):
##   1. Serialize wrapper {format, seq, checksum(sha256 of payload), payload} to <name>.tmp
##   2. Flush, close, read back and verify byte-equality
##   3. Rename current <name> -> <name>.bak, then <name>.tmp -> <name>
## Load picks the valid candidate (main / tmp / bak) with the highest `seq`,
## so a crash at any point restores the most recent fully-written state.
## Corrupted / partial files fail checksum or schema validation and are ignored.

const GameState = preload("res://scripts/core/game_state.gd")
const FORMAT := "bingo-drum-save"
## v2: checksum covers seq + payload (v1 covered only the payload).
const FORMAT_VERSION := 2

var base_dir: String
var file_name: String
var last_error: String = ""
## For tests / manual verification of the error path.
var debug_fail_writes: bool = false
## Test hook: simulate a crash after tmp was opened (truncated) for writing.
var debug_crash_during_write: bool = false
## Test hook: make archive_current() fail.
var debug_fail_archive: bool = false
var _seq: int = 0


func _init(p_base_dir: String = "user://", p_file_name: String = "game_state.json") -> void:
	base_dir = ProjectSettings.globalize_path(p_base_dir)
	if not base_dir.ends_with("/") and not base_dir.ends_with("\\"):
		base_dir += "/"
	file_name = p_file_name


func main_path() -> String:
	return base_dir + file_name


func tmp_path() -> String:
	return base_dir + file_name + ".tmp"


func bak_path() -> String:
	return base_dir + file_name + ".bak"


func archive_dir() -> String:
	return base_dir + "archive/"


static func _sha256(text: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(text.to_utf8_buffer())
	return ctx.finish().hex_encode()


## Saves the state. Returns OK or an error code (last_error has details).
func save(state: RefCounted) -> Error:
	last_error = ""
	if debug_fail_writes:
		last_error = "書き込み失敗（テスト用に強制）"
		return ERR_FILE_CANT_WRITE
	var mk := DirAccess.make_dir_recursive_absolute(base_dir)
	if mk != OK and not DirAccess.dir_exists_absolute(base_dir):
		last_error = "保存フォルダを作成できません (%s)" % error_string(mk)
		return ERR_FILE_CANT_WRITE
	# Never truncate the only copy of the latest confirmed state: a complete
	# tmp left by a crash / failed promote is promoted to main first.
	var settle := _settle_tmp()
	if settle != OK:
		return settle
	_sync_seq()
	var payload_text := JSON.stringify(state.to_dict(), "", true)
	var seq := _seq + 1
	var wrapper := {
		"format": FORMAT,
		"format_version": FORMAT_VERSION,
		"seq": seq,
		# seq decides which file is restored, so it is covered by the checksum too.
		"checksum": _checksum_v2(seq, payload_text),
		"payload": payload_text,
	}
	var text := JSON.stringify(wrapper, "", true)
	var f := FileAccess.open(tmp_path(), FileAccess.WRITE)
	if f == null:
		last_error = "一時ファイルを開けません (%s)" % error_string(FileAccess.get_open_error())
		return ERR_FILE_CANT_WRITE
	if debug_crash_during_write:
		# Test hook: behave like a crash right after tmp was truncated.
		f.store_string(text.left(text.length() / 2))
		f.close()
		last_error = "書き込み中に中断（テスト用）"
		return ERR_FILE_CANT_WRITE
	f.store_string(text)
	f.flush()
	var werr := f.get_error()
	f.close()
	if werr != OK:
		last_error = "一時ファイルへの書き込みに失敗 (%s)" % error_string(werr)
		return ERR_FILE_CANT_WRITE
	var back := FileAccess.get_file_as_string(tmp_path())
	if back != text:
		last_error = "書き込み内容の検証に失敗"
		return ERR_FILE_CORRUPT
	if FileAccess.file_exists(main_path()):
		if FileAccess.file_exists(bak_path()):
			DirAccess.remove_absolute(bak_path())
		var r1 := DirAccess.rename_absolute(main_path(), bak_path())
		if r1 != OK:
			# Not fatal: tmp is complete and has the highest seq; load() will find it.
			push_warning("SaveStore: could not rotate backup: %s" % error_string(r1))
			DirAccess.remove_absolute(main_path())
	var r2 := DirAccess.rename_absolute(tmp_path(), main_path())
	if r2 != OK:
		# tmp still holds the verified new state; load() will pick it up and the
		# next save() promotes it (or refuses to write) before touching tmp.
		push_warning("SaveStore: could not promote tmp: %s" % error_string(r2))
	_seq += 1
	return OK


## A complete tmp newer than main is the latest confirmed state: promote it
## (main -> bak, tmp -> main). A partial / older tmp is discarded. If the
## promotion fails we refuse to save, because writing tmp would destroy it.
func _settle_tmp() -> Error:
	if not FileAccess.file_exists(tmp_path()):
		return OK
	var t := _read_candidate(tmp_path())
	var m := _read_candidate(main_path())
	if not t.ok or (m.ok and not _outranks(t, m)):
		DirAccess.remove_absolute(tmp_path())  # never confirmed, or superseded by main
		return OK
	if FileAccess.file_exists(main_path()):
		if FileAccess.file_exists(bak_path()):
			DirAccess.remove_absolute(bak_path())
		if DirAccess.rename_absolute(main_path(), bak_path()) != OK:
			last_error = "保存データの整理に失敗しました（main→bak）"
			return ERR_FILE_CANT_WRITE
	if DirAccess.rename_absolute(tmp_path(), main_path()) != OK:
		last_error = "最新の保存データを確定できません（tmp→main）"
		return ERR_FILE_CANT_WRITE
	_seq = maxi(_seq, int(t.seq))
	return OK


## Keeps the next seq above every file on disk, even for a store that never
## called load_latest(), so a new save can never rank below an old backup.
func _sync_seq() -> void:
	for p in [main_path(), bak_path()]:
		var c := _read_candidate(p)
		if c.ok:
			_seq = maxi(_seq, int(c.seq))


static func _checksum_v2(seq: int, payload_text: String) -> String:
	return _sha256("bingo-drum-save/v2\nseq=%d\n%s" % [seq, payload_text])


## Positive integer seq from JSON (arrives as float); -1 when invalid.
static func _parse_seq(v) -> int:
	if typeof(v) == TYPE_INT and v >= 1:
		return v
	if typeof(v) == TYPE_FLOAT and is_finite(v) and v == floor(v) and v >= 1.0 and v < 1e15:
		return int(v)
	return -1


## { ok, exists, seq, state, legacy } — legacy = format v1 whose checksum did
## not cover seq (written by earlier builds; still readable, ranked below v2).
func _read_candidate(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "exists": false}
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return {"ok": false, "exists": true, "error": "json"}
	if parsed.get("format") != FORMAT or typeof(parsed.get("payload")) != TYPE_STRING:
		return {"ok": false, "exists": true, "error": "format"}
	var payload_text: String = parsed.payload
	var seq := _parse_seq(parsed.get("seq"))
	if seq < 1:
		return {"ok": false, "exists": true, "error": "seq"}
	var legacy := false
	if parsed.has("format_version"):
		if _parse_seq(parsed.format_version) != FORMAT_VERSION:
			return {"ok": false, "exists": true, "error": "format_version"}
		if _checksum_v2(seq, payload_text) != parsed.get("checksum", ""):
			return {"ok": false, "exists": true, "error": "checksum"}
	else:
		legacy = true
		if _sha256(payload_text) != parsed.get("checksum", ""):
			return {"ok": false, "exists": true, "error": "checksum"}
	var res := GameState.from_dict(JSON.parse_string(payload_text))
	if not res.ok:
		return {"ok": false, "exists": true, "error": res.error}
	return {"ok": true, "exists": true, "seq": seq, "state": res.state, "legacy": legacy}


## Candidate order: any checksum-protected (v2) file outranks legacy files
## (whose seq is not protected); within the same kind the higher seq wins.
static func _outranks(a: Dictionary, b: Dictionary) -> bool:
	var av := 0 if a.get("legacy", false) else 1
	var bv := 0 if b.get("legacy", false) else 1
	if av != bv:
		return av > bv
	return int(a.seq) > int(b.seq)


## Returns { state (or null), found_files (bool), corrupted (bool), source }.
func load_latest() -> Dictionary:
	var best := {}
	var best_src := ""
	var any_exists := false
	var any_corrupt := false
	for entry in [[main_path(), "main"], [tmp_path(), "tmp"], [bak_path(), "bak"]]:
		var c := _read_candidate(entry[0])
		if c.exists:
			any_exists = true
		if not c.ok:
			if c.exists:
				any_corrupt = true
				push_warning("SaveStore: ignoring %s (%s)" % [entry[1], c.get("error", "?")])
			continue
		_seq = maxi(_seq, c.seq)
		if best.is_empty() or _outranks(c, best):
			best = c
			best_src = entry[1]
	var state = best.state if not best.is_empty() else null
	return {"state": state, "found_files": any_exists, "corrupted": any_corrupt and state == null, "source": best_src}


## Copies existing save files to archive/ (used before starting a new game).
## Returns OK only if every existing file was copied and verified; otherwise
## last_error is set and the caller must not replace the game.
func archive_current(tag: String) -> Error:
	last_error = ""
	if debug_fail_archive:
		last_error = "記録の退避に失敗（テスト用に強制）"
		return ERR_FILE_CANT_WRITE
	var sources: Array[String] = []
	for p in [main_path(), tmp_path(), bak_path()]:
		if FileAccess.file_exists(p):
			sources.append(p)
	if sources.is_empty():
		return OK
	var mk := DirAccess.make_dir_recursive_absolute(archive_dir())
	if mk != OK and not DirAccess.dir_exists_absolute(archive_dir()):
		last_error = "archive フォルダを作成できません (%s)" % error_string(mk)
		return ERR_FILE_CANT_WRITE
	var stamp := Time.get_datetime_string_from_system(false, false).replace(":", "-").replace("T", "_")
	var safe_tag := tag.validate_filename()
	for p in sources:
		var dst: String = archive_dir() + "%s_%s_%s" % [stamp, safe_tag, p.get_file()]
		var err := DirAccess.copy_absolute(p, dst)
		if err != OK or FileAccess.get_file_as_bytes(dst) != FileAccess.get_file_as_bytes(p):
			last_error = "記録を archive に退避できません (%s)" % (error_string(err) if err != OK else "内容が一致しません")
			return ERR_FILE_CANT_WRITE
	return OK

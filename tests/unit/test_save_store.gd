extends "res://tests/test_case.gd"

const GameState = preload("res://scripts/core/game_state.gd")
const SaveStore = preload("res://scripts/core/save_store.gd")
const RandomSource = preload("res://scripts/core/random_source.gd")


func _state(draws: int, maxn: int = 75) -> RefCounted:
	var rng := RandomSource.seeded(draws + 100)
	var s = GameState.create(maxn, rng)
	for i in draws:
		s.draw(rng, "rq-%06d" % i)
	return s


func test_save_and_load_roundtrip() -> void:
	var dir := scratch_dir("save_roundtrip")
	var store := SaveStore.new(dir)
	var s = _state(12)
	eq(store.save(s), OK, "save")
	var store2 := SaveStore.new(dir)
	var res := store2.load_latest()
	check(res.state != null, "loaded")
	eq(res.state.drawn, s.drawn, "order preserved")
	eq(res.state.remaining.size(), 63, "remaining")
	eq(res.source, "main", "source")


func test_latest_wins_and_backup_exists() -> void:
	var dir := scratch_dir("save_latest")
	var store := SaveStore.new(dir)
	var s = _state(0)
	var rng := RandomSource.seeded(5)
	for i in 5:
		s.draw(rng, "rq-x-%04d" % i)
		eq(store.save(s), OK, "save %d" % i)
	check(FileAccess.file_exists(store.bak_path()), "bak exists")
	check(not FileAccess.file_exists(store.tmp_path()), "tmp promoted")
	var res := SaveStore.new(dir).load_latest()
	eq(res.state.drawn.size(), 5, "latest")


func test_corrupted_main_falls_back_to_backup() -> void:
	var dir := scratch_dir("save_corrupt")
	var store := SaveStore.new(dir)
	var s = _state(3)
	store.save(s)
	var rng := RandomSource.seeded(1)
	s.draw(rng, "rq-corrupt1")
	store.save(s)  # main = 4 draws, bak = 3 draws
	var f := FileAccess.open(store.main_path(), FileAccess.WRITE)
	f.store_string("{\"format\":\"bingo-drum-save\",\"seq\":99,\"checksum\":\"00\",\"payload\":\"{}\"}")
	f.close()
	var res := SaveStore.new(dir).load_latest()
	check(res.state != null, "recovered")
	eq(res.state.drawn.size(), 3, "from backup")
	eq(res.source, "bak", "source bak")


func test_truncated_main_and_complete_tmp() -> void:
	# Simulates a crash after tmp was written but before it replaced main.
	var dir := scratch_dir("save_tmp")
	var store := SaveStore.new(dir)
	var s = _state(2)
	store.save(s)
	var good_main := FileAccess.get_file_as_string(store.main_path())
	var rng := RandomSource.seeded(2)
	s.draw(rng, "rq-tmp-0001")
	store.save(s)
	# Move the newest file back to .tmp and put the older one as main.
	DirAccess.rename_absolute(store.main_path(), store.tmp_path())
	var f := FileAccess.open(store.main_path(), FileAccess.WRITE)
	f.store_string(good_main)
	f.close()
	var res := SaveStore.new(dir).load_latest()
	eq(res.state.drawn.size(), 3, "tmp with higher seq wins")
	eq(res.source, "tmp", "source tmp")
	# Truncated tmp must be ignored.
	var t := FileAccess.open(store.tmp_path(), FileAccess.WRITE)
	t.store_string(FileAccess.get_file_as_string(store.main_path()).substr(0, 40))
	t.close()
	var res2 := SaveStore.new(dir).load_latest()
	eq(res2.state.drawn.size(), 2, "truncated tmp ignored")


func test_restored_tmp_survives_crash_during_next_write() -> void:
	# main = 2 draws, tmp = 3 draws (newest, never promoted). After restoring
	# from tmp, a crash while writing the 4th draw must not lose draw #3.
	var dir := scratch_dir("save_tmp_protect")
	var store := SaveStore.new(dir)
	var s = _state(2)
	store.save(s)
	var older_main := FileAccess.get_file_as_string(store.main_path())
	var rng := RandomSource.seeded(4)
	s.draw(rng, "rq-protect-01")
	store.save(s)
	DirAccess.rename_absolute(store.main_path(), store.tmp_path())
	var f := FileAccess.open(store.main_path(), FileAccess.WRITE)
	f.store_string(older_main)
	f.close()
	var restarted := SaveStore.new(dir)
	var res := restarted.load_latest()
	eq(res.source, "tmp", "restored from tmp")
	var restored = res.state
	eq(restored.drawn.size(), 3, "3 draws restored")
	var expected: Array = restored.drawn.duplicate()
	restored.draw(rng, "rq-protect-02")
	restarted.debug_crash_during_write = true
	check(restarted.save(restored) != OK, "simulated crash")
	var after := SaveStore.new(dir).load_latest()
	check(after.state != null, "still loadable")
	eq(after.state.drawn, expected, "draw #3 kept after the crash")


func test_fresh_store_never_ranks_below_existing_files() -> void:
	# A store that skips load_latest() must still write a higher seq than disk.
	var dir := scratch_dir("save_seq_sync")
	var a := SaveStore.new(dir)
	a.save(_state(1))
	a.save(_state(2))
	a.save(_state(3))
	var b := SaveStore.new(dir)
	eq(b.save(_state(5)), OK, "save")
	eq(SaveStore.new(dir).load_latest().state.drawn.size(), 5, "newest wins")


func _rewrite_field(path: String, key: String, value) -> void:
	var d: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(path))
	d[key] = value
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(JSON.stringify(d))
	f.close()


func test_tampered_seq_cannot_promote_an_old_backup() -> void:
	var dir := scratch_dir("save_seq_tamper")
	var store := SaveStore.new(dir)
	var s = _state(0)
	var rng := RandomSource.seeded(8)
	for i in 3:
		s.draw(rng, "rq-seq-%04d" % i)
		store.save(s)  # main = 3 draws, bak = 2 draws
	_rewrite_field(store.bak_path(), "seq", 19)  # payload + checksum untouched
	var res := SaveStore.new(dir).load_latest()
	eq(res.source, "main", "tampered bak rejected")
	eq(res.state.drawn.size(), 3, "latest state kept")
	for bad in [0, -1, 1.5, "7", null]:
		var d2 := scratch_dir("save_seq_bad")
		var st2 := SaveStore.new(d2)
		st2.save(_state(1))
		_rewrite_field(st2.main_path(), "seq", bad)
		check(SaveStore.new(d2).load_latest().state == null, "seq %s rejected" % str(bad))


func test_legacy_v1_file_loads_and_is_outranked_by_v2() -> void:
	var dir := scratch_dir("save_legacy")
	var old = _state(4)
	var payload := JSON.stringify(old.to_dict(), "", true)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(payload.to_utf8_buffer())
	var legacy := {"format": "bingo-drum-save", "seq": 50, "checksum": ctx.finish().hex_encode(), "payload": payload}
	var store := SaveStore.new(dir)
	DirAccess.make_dir_recursive_absolute(dir)
	var f := FileAccess.open(store.main_path(), FileAccess.WRITE)
	f.store_string(JSON.stringify(legacy))
	f.close()
	var res := SaveStore.new(dir).load_latest()
	eq(res.state.drawn.size(), 4, "files from earlier builds still load")
	var s = res.state
	s.draw(RandomSource.seeded(1), "rq-legacy-01")
	eq(store.save(s), OK, "save over a legacy file")
	_rewrite_field(store.bak_path(), "seq", 999)  # the legacy bak has an unprotected seq
	eq(SaveStore.new(dir).load_latest().state.drawn.size(), 5, "v2 main outranks any legacy seq")


func test_all_corrupted_reports_corruption() -> void:
	var dir := scratch_dir("save_allbad")
	var store := SaveStore.new(dir)
	var f := FileAccess.open(store.main_path(), FileAccess.WRITE)
	f.store_string("garbage")
	f.close()
	var res := store.load_latest()
	check(res.state == null, "no state")
	check(res.corrupted, "corrupted flag")


func test_no_files() -> void:
	var dir := scratch_dir("save_none")
	var res := SaveStore.new(dir).load_latest()
	check(res.state == null and not res.found_files and not res.corrupted, "empty")


func test_unwritable_dir_fails() -> void:
	var dir := scratch_dir("save_unwritable")
	# A regular file where the directory should be makes every write fail.
	var blocker := dir + "blocker"
	var f := FileAccess.open(blocker, FileAccess.WRITE)
	f.store_string("x")
	f.close()
	var store := SaveStore.new(blocker + "/sub/")
	check(store.save(_state(1)) != OK, "save must fail")
	check(not store.last_error.is_empty(), "error message")


func test_new_game_seq_beats_old_backup() -> void:
	var dir := scratch_dir("save_newgame")
	var store := SaveStore.new(dir)
	var old = _state(40)
	store.save(old)
	store.save(old)
	var fresh = _state(0, 30)
	store.save(fresh)
	var res := SaveStore.new(dir).load_latest()
	eq(res.state.max_number, 30, "new game wins over old backup")

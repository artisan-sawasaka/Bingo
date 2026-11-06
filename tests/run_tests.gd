extends SceneTree
## Headless test runner.
##   Godot_console.exe --headless --path . -s res://tests/run_tests.gd [-- --filter=name]
## Every tests/unit/*.gd and tests/integration/*.gd file is a script extending
## tests/test_case.gd; every method starting with "test_" is run (may be a coroutine).

const TestCase = preload("res://tests/test_case.gd")

var _filter := ""


func _initialize() -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--filter="):
			_filter = arg.substr(9)
	_run.call_deferred()


func _list_scripts(dir_path: String) -> Array[String]:
	var out: Array[String] = []
	var d := DirAccess.open(dir_path)
	if d == null:
		return out
	for f in d.get_files():
		if f.begins_with("test_") and f.ends_with(".gd"):
			out.append(dir_path.path_join(f))
	out.sort()
	return out


func _run() -> void:
	var scripts := _list_scripts("res://tests/unit") + _list_scripts("res://tests/integration")
	var passed := 0
	var failed := 0
	var failures: Array[String] = []
	for path in scripts:
		var script: GDScript = load(path)
		if script == null:
			failed += 1
			failures.append("%s: failed to load" % path)
			continue
		var methods: Array[String] = []
		for m in script.get_script_method_list():
			var mname: String = m.name
			if mname.begins_with("test_") and not methods.has(mname):
				methods.append(mname)
		for mname in methods:
			var full := "%s::%s" % [path.get_file().get_basename(), mname]
			if not _filter.is_empty() and full.find(_filter) < 0:
				continue
			var tc: TestCase = script.new()
			tc.tree = self
			root.add_child(tc)
			await tc.before_each()
			await tc.call(mname)
			await tc.after_each()
			if tc.failures.is_empty():
				passed += 1
				print("  PASS  ", full)
			else:
				failed += 1
				print("  FAIL  ", full)
				for msg in tc.failures:
					print("        - ", msg)
					failures.append("%s: %s" % [full, msg])
			tc.queue_free()
			await process_frame
	print("")
	print("RESULT: %d passed, %d failed" % [passed, failed])
	quit(0 if failed == 0 else 1)

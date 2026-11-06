extends Node
## Minimal assertion base class for the headless test runner.

var tree: SceneTree
var failures: Array[String] = []


func before_each() -> void:
	pass


func after_each() -> void:
	pass


func fail(msg: String) -> void:
	failures.append(msg)


func check(cond: bool, msg: String = "check failed") -> bool:
	if not cond:
		failures.append(msg)
	return cond


func eq(actual, expected, msg: String = "") -> bool:
	if typeof(actual) != typeof(expected) and not (_is_num(actual) and _is_num(expected)):
		failures.append("%s expected %s (%s) got %s (%s)" % [msg, str(expected), type_string(typeof(expected)), str(actual), type_string(typeof(actual))])
		return false
	if actual != expected:
		failures.append("%s expected %s got %s" % [msg, str(expected), str(actual)])
		return false
	return true


func _is_num(v) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## Creates an empty scratch directory under user://test_tmp/<name>/
func scratch_dir(name: String) -> String:
	var p := ProjectSettings.globalize_path("user://test_tmp/" + name + "/")
	_rm_rf(p)
	DirAccess.make_dir_recursive_absolute(p)
	return p


func _rm_rf(path: String) -> void:
	var d := DirAccess.open(path)
	if d == null:
		return
	for f in d.get_files():
		DirAccess.remove_absolute(path.path_join(f))
	for sub in d.get_directories():
		_rm_rf(path.path_join(sub))
	DirAccess.remove_absolute(path)


func wait_frames(n: int) -> void:
	for i in n:
		await tree.process_frame


func wait_until(cond: Callable, timeout_sec: float = 3.0) -> bool:
	var start := Time.get_ticks_msec()
	while not cond.call():
		if Time.get_ticks_msec() - start > int(timeout_sec * 1000.0):
			return false
		await tree.process_frame
	return true

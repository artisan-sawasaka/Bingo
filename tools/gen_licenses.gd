extends SceneTree
## Writes the third-party notices next to the exported app (the same text is
## also shown inside the app: settings → ライセンス / L key).
##   Godot_console.exe --headless --path . -s res://tools/gen_licenses.gd -- --out=build/windows/THIRD_PARTY_LICENSES.txt

const Licenses = preload("res://scripts/util/licenses.gd")


func _initialize() -> void:
	var out := "build/windows/THIRD_PARTY_LICENSES.txt"
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--out="):
			out = a.substr(6)
	var text := Licenses.build_text()
	var abs_out := out if out.is_absolute_path() else ProjectSettings.globalize_path("res://").path_join(out)
	DirAccess.make_dir_recursive_absolute(abs_out.get_base_dir())
	var f := FileAccess.open(abs_out, FileAccess.WRITE)
	if f == null:
		printerr("cannot write ", abs_out)
		quit(1)
		return
	f.store_string(text)
	f.close()
	print("wrote ", abs_out, " (", text.length(), " chars)")
	quit(0)

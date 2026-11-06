extends RefCounted
## Operator secret for the phone remote. Generated with the OS CSPRNG,
## persisted in user:// so a crash/restart does not force re-scanning the QR,
## and re-issuable from the connection screen (invalidates every old link).

var path: String
var token: String = ""


func _init(p_path: String = "user://remote_secret.json") -> void:
	path = ProjectSettings.globalize_path(p_path)


static func generate_token() -> String:
	var bytes := Crypto.new().generate_random_bytes(18)  # 144 bit
	return Marshalls.raw_to_base64(bytes).replace("+", "-").replace("/", "_").replace("=", "")


static func is_well_formed(t) -> bool:
	if typeof(t) != TYPE_STRING:
		return false
	var s: String = t
	if s.length() < 16 or s.length() > 64:
		return false
	for i in s.length():
		var c := s.unicode_at(i)
		if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 45 or c == 95):
			return false
	return true


## Set when the last reissue() could not be saved (old code may return on restart).
var last_error: String = ""


func load_or_create() -> String:
	var saved := _read_saved()
	if not saved.is_empty():
		token = saved
		return token
	reissue()
	return token


func _read_saved() -> String:
	if not FileAccess.file_exists(path):
		return ""
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) == TYPE_DICTIONARY and is_well_formed(d.get("token")):
		return d.token
	return ""


## Switches to a new token immediately (old QR links stop working now) and
## saves it via tmp -> verify -> replace. Returns true only when the new
## token is what a restart will load; otherwise last_error explains why.
func reissue() -> bool:
	token = generate_token()
	last_error = ""
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var tmp := path + ".tmp"
	var text := JSON.stringify({"token": token, "created_at": int(Time.get_unix_time_from_system())})
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		last_error = "接続コードを保存できません（%s）" % error_string(FileAccess.get_open_error())
		return false
	f.store_string(text)
	f.close()
	if FileAccess.get_file_as_string(tmp) != text:
		DirAccess.remove_absolute(tmp)
		last_error = "接続コードの保存内容を確認できません"
		return false
	var err := DirAccess.rename_absolute(tmp, path)
	if err != OK:
		DirAccess.remove_absolute(tmp)
		last_error = "接続コードの保存ファイルを置き換えられません（%s）" % error_string(err)
		return false
	if _read_saved() != token:
		last_error = "保存した接続コードを確認できません"
		return false
	return true


## Constant-time comparison.
static func matches(expected: String, given) -> bool:
	if typeof(given) != TYPE_STRING or expected.is_empty():
		return false
	var a := expected.to_utf8_buffer()
	var b := String(given).to_utf8_buffer()
	var diff := a.size() ^ b.size()
	for i in a.size():
		var bv: int = b[i] if i < b.size() else 0
		diff |= a[i] ^ bv
	return diff == 0

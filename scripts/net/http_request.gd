extends RefCounted
## Minimal HTTP/1.1 request-head parser (no bodies accepted).

const MAX_HEAD_BYTES := 8192


## Parses the request head from `buf`.
## Returns { status: "incomplete" } | { status: "error", code, reason } |
##         { status: "ok", method, target, path, query, version, headers, head_len }
static func parse(buf: PackedByteArray) -> Dictionary:
	var end := _find_head_end(buf)
	if end < 0:
		if buf.size() > MAX_HEAD_BYTES:
			return {"status": "error", "code": 431, "reason": "Request Header Fields Too Large"}
		return {"status": "incomplete"}
	if end > MAX_HEAD_BYTES:
		return {"status": "error", "code": 431, "reason": "Request Header Fields Too Large"}
	var head := buf.slice(0, end).get_string_from_ascii()
	var lines := head.split("\r\n")
	if lines.is_empty():
		return {"status": "error", "code": 400, "reason": "Bad Request"}
	var parts := lines[0].split(" ")
	if parts.size() != 3 or not parts[2].begins_with("HTTP/1."):
		return {"status": "error", "code": 400, "reason": "Bad Request"}
	var headers := {}
	for i in range(1, lines.size()):
		var line: String = lines[i]
		if line.is_empty():
			continue
		var colon := line.find(":")
		if colon <= 0:
			return {"status": "error", "code": 400, "reason": "Bad Request"}
		var key := line.substr(0, colon).strip_edges().to_lower()
		var value := line.substr(colon + 1).strip_edges()
		if headers.has(key):
			headers[key] = headers[key] + ", " + value
		else:
			headers[key] = value
	var target: String = parts[1]
	var path := target
	var query := ""
	var q := target.find("?")
	if q >= 0:
		path = target.substr(0, q)
		query = target.substr(q + 1)
	var hash := path.find("#")
	if hash >= 0:
		path = path.substr(0, hash)
	return {
		"status": "ok",
		"method": parts[0],
		"target": target,
		"path": path,
		"query": query,
		"version": parts[2],
		"headers": headers,
		"head_len": end + 4,
	}


static func _find_head_end(buf: PackedByteArray) -> int:
	var n := buf.size()
	var limit := mini(n, MAX_HEAD_BYTES + 4)
	for i in range(0, limit - 3):
		if buf[i] == 13 and buf[i + 1] == 10 and buf[i + 2] == 13 and buf[i + 3] == 10:
			return i
	return -1


static func header_has_token(headers: Dictionary, key: String, token: String) -> bool:
	var v: String = headers.get(key, "")
	for part in v.split(","):
		if part.strip_edges().to_lower() == token.to_lower():
			return true
	return false

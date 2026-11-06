extends Node
## LAN remote server: static HTTP for web-remote/ + WebSocket (/ws) on ONE port.
## Implemented on TCPServer so we can enforce Host / Origin checks, size limits,
## rate limits and token auth ourselves (WebSocketPeer.accept_stream cannot
## expose the Origin header).
##
## Security model (see docs/protocol.md):
##   * Host header must be a local address of this PC (DNS-rebinding defense).
##   * WebSocket Origin must equal "http://<Host>" (blocks cross-site pages).
##   * First WS message must be `hello` with the operator token (from QR #k=…).
##   * Only authenticated sockets may send `spin_request`.

const WsCodec = preload("res://scripts/net/ws_codec.gd")
const HttpRequest = preload("res://scripts/net/http_request.gd")
const NetInfo = preload("res://scripts/net/net_info.gd")
const RemoteSecret = preload("res://scripts/net/remote_secret.gd")

signal clients_changed(count: int)
signal log_event(text: String)

const PROTOCOL_VERSION := 1
const MAX_CONNECTIONS := 24
const HTTP_TIMEOUT_MS := 5000
const AUTH_TIMEOUT_MS := 5000
const IDLE_TIMEOUT_MS := 30000
const MAX_WS_MESSAGE := 4096
## Unprocessed WebSocket bytes kept per connection (a few full messages).
const MAX_WS_BUFFER := 16384
## Bytes taken from a socket per frame.
const MAX_READ_PER_POLL := 16384
const BUCKET_CAPACITY := 20.0
const BUCKET_REFILL_PER_SEC := 10.0
const SPIN_MIN_INTERVAL_MS := 400
const AUTH_FAIL_LIMIT := 5
const AUTH_BLOCK_MS := 60000

const STATIC_FILES := {
	"/": ["index.html", "text/html; charset=utf-8"],
	"/index.html": ["index.html", "text/html; charset=utf-8"],
	"/styles.css": ["styles.css", "text/css; charset=utf-8"],
	"/app.js": ["app.js", "text/javascript; charset=utf-8"],
}

enum ConnState { HTTP, WS, CLOSED }


class Conn:
	var peer: StreamPeerTCP
	var ip: String = ""
	var state: int = 0
	var buf := PackedByteArray()
	var codec
	var created_ms: int = 0
	var last_rx_ms: int = 0
	var authed: bool = false
	var client_id: String = ""
	var bucket: float = 20.0
	var bucket_ms: int = 0
	var last_spin_ms: int = -100000
	var last_cmd_ms: int = -100000
	var close_at_ms: int = -1
	## Deferred close frame { code, reason, at } so the client can read the
	## preceding message (some clients drop queued messages on close).
	var pending_close: Dictionary = {}


var controller: Node = null
## Optional application handler (main.gd). Must provide:
##   get_remote_snapshot() -> Dictionary
##   remote_show_screen(screen: String) -> { ok, message }
##   remote_setup_draft(text: String) -> void
##   remote_new_game(request_id: String, max_text: String) -> { ok, duplicate, message }
var app: Object = null
var web_root: String = "res://web-remote/"
var port: int = 8765
var preferred_port: int = 8765
var token: String = ""
var secret: RemoteSecret = null
var running: bool = false
var start_error: String = ""
## Extra hosts accepted in the Host header (tests).
var extra_allowed_hosts: Array[String] = []

var _server := TCPServer.new()
var _conns: Array = []
var _files := {}
var _allowed_hosts := {}
var _lan := []
var _auth_failures := {}  # ip -> [timestamps]
var _blocked_until := {}  # ip -> ms


func setup(p_controller: Node, p_secret: RemoteSecret) -> void:
	controller = p_controller
	secret = p_secret
	token = secret.load_or_create() if secret != null else ""
	controller.state_changed.connect(_on_state_changed)
	controller.spin_started.connect(_on_spin_started)
	controller.spin_finished.connect(_on_spin_finished)


func start(p_port: int = -1, tries: int = 10) -> bool:
	if p_port > 0:
		preferred_port = p_port
	_load_files()
	refresh_addresses()
	start_error = ""
	for i in tries:
		var candidate := preferred_port + i
		var err := _server.listen(candidate, "*")
		if err == OK:
			port = candidate
			running = true
			refresh_addresses()
			_log("リモートサーバー開始 port=%d" % port)
			return true
	start_error = "ポート %d〜%d を開けませんでした" % [preferred_port, preferred_port + tries - 1]
	_log(start_error)
	return false


func stop() -> void:
	for c in _conns:
		_close_now(c)
	_conns.clear()
	_server.stop()
	running = false


func _exit_tree() -> void:
	stop()


## Returns false when the new token could not be saved (the old QR may become
## valid again after a restart); secret.last_error has the reason.
func reissue_token() -> bool:
	var saved := true
	if secret != null:
		saved = secret.reissue()
		token = secret.token
	# Drop every authenticated socket: old links must stop working.
	for c in _conns:
		if c.state == ConnState.WS and c.authed:
			_send_json(c, {"type": "auth_failed", "message": "接続用QRが再発行されました。新しいQRコードを読み取ってください"})
			c.authed = false
			_close_ws_deferred(c, 4001, "token reissued")
	clients_changed.emit(client_count())
	return saved


func refresh_addresses() -> void:
	_lan = NetInfo.lan_addresses()
	_allowed_hosts.clear()
	for h in ["localhost", "127.0.0.1"]:
		_allowed_hosts["%s:%d" % [h, port]] = true
	for a in _lan:
		_allowed_hosts["%s:%d" % [a.ip, port]] = true
	for h in extra_allowed_hosts:
		_allowed_hosts[h] = true


func lan_addresses() -> Array:
	return _lan


func base_url(ip: String) -> String:
	return "http://%s:%d/" % [ip, port]


## URL encoded into the QR code. The token rides in the fragment so it is never
## sent in HTTP request lines / logs.
func pairing_url(ip: String) -> String:
	return base_url(ip) + "#k=" + token


func client_count() -> int:
	var n := 0
	for c in _conns:
		if c.state == ConnState.WS and c.authed:
			n += 1
	return n


func _load_files() -> void:
	_files.clear()
	for route in STATIC_FILES:
		var fname: String = STATIC_FILES[route][0]
		var p := web_root.path_join(fname)
		if FileAccess.file_exists(p):
			_files[fname] = FileAccess.get_file_as_bytes(p)
		else:
			push_error("RemoteServer: missing web file %s" % p)


func missing_files() -> Array[String]:
	var out: Array[String] = []
	for route in STATIC_FILES:
		var fname: String = STATIC_FILES[route][0]
		if not _files.has(fname) and not out.has(fname):
			out.append(fname)
	return out


func _process(_delta: float) -> void:
	poll()


func poll() -> void:
	if not running:
		return
	var now := Time.get_ticks_msec()
	while _server.is_connection_available():
		var peer := _server.take_connection()
		if peer == null:
			break
		if _conns.size() >= MAX_CONNECTIONS:
			peer.disconnect_from_host()
			continue
		peer.set_no_delay(true)
		var c := Conn.new()
		c.peer = peer
		c.ip = peer.get_connected_host()
		c.state = ConnState.HTTP
		c.created_ms = now
		c.last_rx_ms = now
		c.bucket_ms = now
		c.bucket = BUCKET_CAPACITY
		_conns.append(c)
	var changed := false
	for c in _conns.duplicate():
		var was_authed: bool = c.authed and c.state == ConnState.WS
		_service(c, now)
		if c.state == ConnState.CLOSED:
			_conns.erase(c)
			if was_authed:
				changed = true
	if changed:
		clients_changed.emit(client_count())


func _service(c: Conn, now: int) -> void:
	c.peer.poll()
	var st := c.peer.get_status()
	if st != StreamPeerTCP.STATUS_CONNECTED:
		_close_now(c)
		return
	if c.close_at_ms >= 0:
		if now >= c.close_at_ms:
			_close_now(c)
		return
	if not c.pending_close.is_empty():
		if now >= int(c.pending_close.at):
			_close_ws(c, c.pending_close.code, c.pending_close.reason)
		return
	var avail := c.peer.get_available_bytes()
	if avail > 0:
		# Bounded read per frame; anything more stays in the OS socket buffer.
		var res := c.peer.get_data(mini(avail, MAX_READ_PER_POLL))
		if res[0] == OK:
			c.last_rx_ms = now
			if c.state == ConnState.HTTP:
				c.buf.append_array(res[1])
			else:
				c.codec.feed(res[1])
				# Unprocessed WebSocket bytes are capped: a flood of (control)
				# frames faster than we consume them closes the connection.
				if c.codec.buffered_size() > MAX_WS_BUFFER:
					_log("受信バッファ超過のため切断 (%s)" % c.ip)
					_close_ws(c, 1009, "receive buffer limit")
					return
	if c.state == ConnState.HTTP:
		_service_http(c, now)
	elif c.state == ConnState.WS:
		_service_ws(c, now)


# ---------------------------------------------------------------- HTTP

func _service_http(c: Conn, now: int) -> void:
	var req := HttpRequest.parse(c.buf)
	if req.status == "incomplete":
		if now - c.created_ms > HTTP_TIMEOUT_MS:
			_close_now(c)
		return
	if req.status == "error":
		_http_respond(c, req.code, req.reason, "text/plain; charset=utf-8", req.reason.to_utf8_buffer())
		return
	var headers: Dictionary = req.headers
	var host: String = String(headers.get("host", "")).to_lower()
	if not _allowed_hosts.has(host):
		_http_respond(c, 421, "Misdirected Request", "text/plain; charset=utf-8", "Unknown host".to_utf8_buffer())
		return
	var method: String = req.method
	var path: String = req.path
	if path == "/ws":
		if method != "GET":
			_http_respond(c, 405, "Method Not Allowed", "text/plain", PackedByteArray())
			return
		_upgrade(c, req, host, now)
		return
	if method != "GET" and method != "HEAD":
		_http_respond(c, 405, "Method Not Allowed", "text/plain", PackedByteArray())
		return
	if path == "/favicon.ico":
		_http_respond(c, 204, "No Content", "", PackedByteArray())
		return
	if path == "/healthz":
		_http_respond(c, 200, "OK", "text/plain; charset=utf-8", "ok".to_utf8_buffer(), method == "HEAD")
		return
	if STATIC_FILES.has(path):
		var fname: String = STATIC_FILES[path][0]
		if not _files.has(fname):
			_http_respond(c, 500, "Internal Server Error", "text/plain; charset=utf-8", ("missing " + fname).to_utf8_buffer())
			return
		_http_respond(c, 200, "OK", STATIC_FILES[path][1], _files[fname], method == "HEAD", host)
		return
	_http_respond(c, 404, "Not Found", "text/plain; charset=utf-8", "Not Found".to_utf8_buffer())


func _http_respond(c: Conn, code: int, reason: String, ctype: String, body: PackedByteArray, head_only: bool = false, host: String = "") -> void:
	var h := "HTTP/1.1 %d %s\r\n" % [code, reason]
	if not ctype.is_empty():
		h += "Content-Type: %s\r\n" % ctype
	h += "Content-Length: %d\r\n" % body.size()
	h += "Cache-Control: no-store\r\n"
	h += "X-Content-Type-Options: nosniff\r\n"
	h += "Referrer-Policy: no-referrer\r\n"
	h += "X-Frame-Options: DENY\r\n"
	if ctype.begins_with("text/html") and not host.is_empty():
		h += "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src ws://%s; base-uri 'none'; form-action 'none'; frame-ancestors 'none'\r\n" % host
	h += "Connection: close\r\n\r\n"
	var out := h.to_ascii_buffer()
	if not head_only:
		out.append_array(body)
	c.peer.put_data(out)
	_close_after(c, 50)


# ---------------------------------------------------------------- WebSocket

func _upgrade(c: Conn, req: Dictionary, host: String, now: int) -> void:
	var headers: Dictionary = req.headers
	if not HttpRequest.header_has_token(headers, "upgrade", "websocket") or not HttpRequest.header_has_token(headers, "connection", "upgrade"):
		_http_respond(c, 400, "Bad Request", "text/plain", "WebSocket upgrade required".to_utf8_buffer())
		return
	if String(headers.get("sec-websocket-version", "")) != "13":
		_http_respond(c, 426, "Upgrade Required", "text/plain", PackedByteArray())
		return
	var origin: String = String(headers.get("origin", "")).to_lower()
	if origin != "http://" + host:
		_log("WS拒否: Origin不一致 (%s)" % c.ip)
		_http_respond(c, 403, "Forbidden", "text/plain", "Origin not allowed".to_utf8_buffer())
		return
	if _is_blocked(c.ip, now):
		_http_respond(c, 429, "Too Many Requests", "text/plain", PackedByteArray())
		return
	var key: String = headers.get("sec-websocket-key", "")
	if key.length() < 16 or key.length() > 64:
		_http_respond(c, 400, "Bad Request", "text/plain", PackedByteArray())
		return
	var resp := "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: %s\r\n\r\n" % WsCodec.accept_key(key)
	c.peer.put_data(resp.to_ascii_buffer())
	c.state = ConnState.WS
	c.codec = WsCodec.new()
	c.codec.max_message_bytes = MAX_WS_MESSAGE
	c.created_ms = now
	var rest: PackedByteArray = c.buf.slice(req.head_len)
	c.buf = PackedByteArray()
	if not rest.is_empty():
		c.codec.feed(rest)


func _service_ws(c: Conn, now: int) -> void:
	for i in 32:
		var ev: Dictionary = c.codec.next_event()
		if ev.is_empty():
			break
		# Every frame (text AND control frames like ping/pong) spends a token.
		if ev.type != "error" and ev.type != "close" and not _take_token(c, now):
			_log("受信レート超過のため切断 (%s)" % c.ip)
			_close_ws(c, 1008, "rate limited")
			return
		match ev.type:
			"error":
				_close_ws(c, ev.code, ev.reason)
				return
			"close":
				_send_raw(c, WsCodec.encode_close(1000))
				_close_after(c, 50)
				return
			"ping":
				_send_raw(c, WsCodec.encode_frame(WsCodec.OP_PONG, ev.data))
			"pong", "fragment":
				pass  # token already spent above
			"binary":
				_close_ws(c, 1003, "binary not supported")
				return
			"text":
				_handle_message(c, ev.data, now)
				if c.state != ConnState.WS or c.close_at_ms >= 0 or not c.pending_close.is_empty():
					return
	if not c.authed and now - c.created_ms > AUTH_TIMEOUT_MS:
		_close_ws(c, 4001, "auth timeout")
	elif now - c.last_rx_ms > IDLE_TIMEOUT_MS:
		_close_ws(c, 1001, "idle")


func _take_token(c: Conn, now: int) -> bool:
	var dt := float(now - c.bucket_ms) / 1000.0
	c.bucket_ms = now
	c.bucket = minf(BUCKET_CAPACITY, c.bucket + dt * BUCKET_REFILL_PER_SEC)
	if c.bucket < 1.0:
		return false
	c.bucket -= 1.0
	return true


func _is_blocked(ip: String, now: int) -> bool:
	return _blocked_until.has(ip) and now < int(_blocked_until[ip])


func _note_auth_failure(ip: String, now: int) -> void:
	var arr: Array = _auth_failures.get(ip, [])
	arr = arr.filter(func(t): return now - int(t) < AUTH_BLOCK_MS)
	arr.append(now)
	_auth_failures[ip] = arr
	if arr.size() >= AUTH_FAIL_LIMIT:
		_blocked_until[ip] = now + AUTH_BLOCK_MS
		_log("認証失敗が続いたため %s を一時ブロック" % ip)


static func _is_valid_client_id(v) -> bool:
	if typeof(v) != TYPE_STRING:
		return false
	var s: String = v
	if s.length() < 4 or s.length() > 64:
		return false
	for i in s.length():
		var ch := s.unicode_at(i)
		if not ((ch >= 48 and ch <= 57) or (ch >= 65 and ch <= 90) or (ch >= 97 and ch <= 122) or ch == 45 or ch == 95):
			return false
	return true


func _handle_message(c: Conn, text: String, now: int) -> void:
	var msg = JSON.parse_string(text)
	if typeof(msg) != TYPE_DICTIONARY or typeof(msg.get("type")) != TYPE_STRING:
		_send_json(c, {"type": "error", "reason": "bad_message", "message": "不正なメッセージ"})
		return
	var mtype: String = msg.type
	if not c.authed:
		if mtype != "hello":
			_close_ws(c, 4001, "hello required")
			return
		if _is_blocked(c.ip, now):
			_close_ws(c, 4029, "blocked")
			return
		if not RemoteSecret.matches(token, msg.get("token")):
			_note_auth_failure(c.ip, now)
			_log("認証失敗 (%s)" % c.ip)
			_send_json(c, {"type": "auth_failed", "message": "接続コードが違います。PC画面のQRコードを読み取り直してください"})
			_close_ws_deferred(c, 4001, "auth failed")
			return
		c.authed = true
		c.client_id = String(msg.get("client_id", "")) if _is_valid_client_id(msg.get("client_id")) else "anon"
		_log("リモート接続 (%s)" % c.ip)
		_send_json(c, {"type": "welcome", "v": PROTOCOL_VERSION, "state": _snapshot()})
		clients_changed.emit(client_count())
		return
	match mtype:
		"ping":
			var t = msg.get("t", 0)
			_send_json(c, {"type": "pong", "t": t if (typeof(t) == TYPE_FLOAT or typeof(t) == TYPE_INT) else 0})
		"get_state":
			_send_json(c, {"type": "state_snapshot", "state": _snapshot()})
		"show_screen":
			var screen = msg.get("screen")
			if typeof(screen) != TYPE_STRING or not (screen in ["main", "history", "setup"]):
				_send_json(c, {"type": "command_result", "command": "show_screen", "ok": false, "message": "不正な画面指定です"})
				return
			if app == null:
				_send_json(c, {"type": "command_result", "command": "show_screen", "ok": false, "message": "未対応"})
				return
			var r: Dictionary = app.remote_show_screen(screen)
			_send_json(c, {"type": "command_result", "command": "show_screen", "screen": screen, "ok": r.ok, "message": r.get("message", "")})
		"setup_draft":
			var v = msg.get("max_number")
			if app != null and (typeof(v) == TYPE_STRING or typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT):
				var s := _number_text(v)
				if s.length() <= 4:
					app.remote_setup_draft(s)
		"new_game":
			var ngid = msg.get("request_id")
			if typeof(ngid) != TYPE_STRING or not controller.is_valid_request_id(ngid):
				_send_json(c, {"type": "new_game_result", "request_id": "", "ok": false, "message": "不正なリクエストです"})
				return
			if now - c.last_cmd_ms < SPIN_MIN_INTERVAL_MS:
				_send_json(c, {"type": "new_game_result", "request_id": ngid, "ok": false, "message": "操作が速すぎます"})
				return
			c.last_cmd_ms = now
			if app == null:
				_send_json(c, {"type": "new_game_result", "request_id": ngid, "ok": false, "message": "未対応"})
				return
			var mv = msg.get("max_number")
			var max_text := _number_text(mv) if (typeof(mv) == TYPE_STRING or typeof(mv) == TYPE_FLOAT or typeof(mv) == TYPE_INT) else ""
			if max_text.length() > 16:
				_send_json(c, {"type": "new_game_result", "request_id": ngid, "ok": false, "message": "最大番号が不正です"})
				return
			var ng: Dictionary = app.remote_new_game(ngid, max_text)
			_send_json(c, {"type": "new_game_result", "request_id": ngid, "ok": ng.ok, "duplicate": ng.get("duplicate", false), "message": ng.get("message", "")})
		"spin_request":
			var rid = msg.get("request_id")
			if typeof(rid) != TYPE_STRING or not controller.is_valid_request_id(rid):
				_send_json(c, {"type": "spin_rejected", "request_id": "", "reason": "invalid", "message": "不正なリクエストです"})
				return
			if now - c.last_spin_ms < SPIN_MIN_INTERVAL_MS:
				_send_json(c, {"type": "spin_rejected", "request_id": rid, "reason": "rate_limited", "message": "操作が速すぎます"})
				return
			c.last_spin_ms = now
			var r: Dictionary = controller.request_spin(rid, "remote:" + c.client_id)
			if r.accepted:
				# The state lets a client that re-sent an already finished draw
				# (duplicate) see at once that nothing is spinning any more.
				_send_json(c, {"type": "spin_accepted", "request_id": rid, "draw_index": r.draw_index, "duplicate": r.duplicate, "state": _snapshot()})
			else:
				_send_json(c, {"type": "spin_rejected", "request_id": rid, "reason": r.reason, "message": r.message, "state": _snapshot()})
		_:
			_send_json(c, {"type": "error", "reason": "unknown_type", "message": "未対応のメッセージ"})


## JSON numbers arrive as float; an integral 75.0 becomes "75" (same value).
## Strings are returned EXACTLY as sent — never trimmed or truncated — so
## GameState.validate_max_number_text() judges the original input.
static func _number_text(v) -> String:
	if typeof(v) == TYPE_INT:
		return str(v)
	if typeof(v) == TYPE_FLOAT:
		if is_finite(v) and v == floor(v) and absf(v) < 1e7:
			return str(int(v))
		return "x"
	return String(v)


func _snapshot() -> Dictionary:
	if app != null:
		return app.get_remote_snapshot()
	return controller.get_snapshot()


## Called by the app when something outside the controller changed (screen, modal).
func notify_state_changed() -> void:
	_on_state_changed()


func _send_json(c: Conn, data: Dictionary) -> void:
	_send_raw(c, WsCodec.encode_text(JSON.stringify(data)))


func _send_raw(c: Conn, bytes: PackedByteArray) -> void:
	if c.state == ConnState.CLOSED:
		return
	if c.peer.get_status() == StreamPeerTCP.STATUS_CONNECTED:
		c.peer.put_data(bytes)


func _broadcast(data: Dictionary) -> void:
	var bytes := WsCodec.encode_text(JSON.stringify(data))
	for c in _conns:
		if c.state == ConnState.WS and c.authed and c.close_at_ms < 0:
			_send_raw(c, bytes)


func _close_ws(c: Conn, code: int, reason: String) -> void:
	_send_raw(c, WsCodec.encode_close(code, reason))
	_close_after(c, 100)


func _close_ws_deferred(c: Conn, code: int, reason: String, delay_ms: int = 300) -> void:
	if c.pending_close.is_empty():
		c.pending_close = {"code": code, "reason": reason, "at": Time.get_ticks_msec() + delay_ms}


func _close_after(c: Conn, ms: int) -> void:
	if c.close_at_ms < 0:
		c.close_at_ms = Time.get_ticks_msec() + ms


func _close_now(c: Conn) -> void:
	if c.state == ConnState.CLOSED:
		return
	c.state = ConnState.CLOSED
	c.peer.disconnect_from_host()


func _log(t: String) -> void:
	print("[remote] ", t)
	log_event.emit(t)


# ---------------------------------------------------------------- controller events

func _on_state_changed() -> void:
	_broadcast({"type": "state_snapshot", "state": _snapshot()})


func _on_spin_started(info: Dictionary) -> void:
	_broadcast({"type": "spin_started", "draw_index": info.draw_index})


func _on_spin_finished(info: Dictionary) -> void:
	_broadcast({"type": "animation_finished", "draw_index": info.draw_index, "number": info.number, "state": _snapshot()})

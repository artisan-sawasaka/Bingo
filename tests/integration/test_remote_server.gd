extends "res://tests/test_case.gd"
## End-to-end tests against the real server using Godot's own WebSocket client
## (an independent RFC 6455 implementation) and HTTPClient.

const GameController = preload("res://scripts/core/game_controller.gd")
const SaveStore = preload("res://scripts/core/save_store.gd")
const RandomSource = preload("res://scripts/core/random_source.gd")
const RemoteServer = preload("res://scripts/net/remote_server.gd")
const RemoteSecret = preload("res://scripts/net/remote_secret.gd")
const WsCodec = preload("res://scripts/net/ws_codec.gd")

const PORT := 18765

var ctrl: GameController
var server: RemoteServer
var _rid := 0


func before_each() -> void:
	var dir := scratch_dir("remote_" + str(Time.get_ticks_usec()))
	ctrl = GameController.new(SaveStore.new(dir), RandomSource.secure())
	ctrl.cooldown_sec = 0.0
	add_child(ctrl)
	server = RemoteServer.new()
	add_child(server)
	server.setup(ctrl, RemoteSecret.new(dir + "secret.json"))
	check(server.start(PORT, 1), "server start: " + server.start_error)
	ctrl.start_new_game(75)


func after_each() -> void:
	server.stop()


func _next_id() -> String:
	_rid += 1
	return "itest-%08d" % _rid


func _client(origin: String = "http://127.0.0.1:%d" % PORT) -> WebSocketPeer:
	var ws := WebSocketPeer.new()
	if not origin.is_empty():
		ws.handshake_headers = PackedStringArray(["Origin: " + origin])
	ws.connect_to_url("ws://127.0.0.1:%d/ws" % PORT)
	return ws


## Polls until the socket is open or closed.
func _wait_open(ws: WebSocketPeer) -> int:
	await wait_until(func():
		ws.poll()
		var s := ws.get_ready_state()
		return s == WebSocketPeer.STATE_OPEN or s == WebSocketPeer.STATE_CLOSED, 3.0)
	return ws.get_ready_state()


## Collects messages until one of `type` arrives (or timeout). Returns it or {}.
func _wait_msg(ws: WebSocketPeer, type: String, inbox: Array, timeout: float = 3.0) -> Dictionary:
	var found := {}
	var start := Time.get_ticks_msec()
	while Time.get_ticks_msec() - start < int(timeout * 1000):
		ws.poll()
		while ws.get_available_packet_count() > 0:
			var m = JSON.parse_string(ws.get_packet().get_string_from_utf8())
			inbox.append(m)
			if found.is_empty() and typeof(m) == TYPE_DICTIONARY and m.get("type") == type:
				found = m
		if not found.is_empty():
			return found
		if ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
			return {}
		await tree.process_frame
	return {}


func _send(ws: WebSocketPeer, d: Dictionary) -> void:
	ws.send_text(JSON.stringify(d))


func _authed_client() -> WebSocketPeer:
	var ws := _client()
	if await _wait_open(ws) != WebSocketPeer.STATE_OPEN:
		fail("could not open websocket")
		return ws
	_send(ws, {"type": "hello", "v": 1, "token": server.token, "client_id": "test-client"})
	var w := await _wait_msg(ws, "welcome", [])
	check(not w.is_empty(), "welcome received")
	return ws


func test_auth_spin_and_reveal_flow() -> void:
	var ws := await _authed_client()
	var inbox := []
	var rid := _next_id()
	_send(ws, {"type": "spin_request", "request_id": rid})
	var acc := await _wait_msg(ws, "spin_accepted", inbox)
	check(not acc.is_empty(), "spin_accepted")
	eq(acc.get("request_id"), rid, "request id echoed")
	eq(acc.get("duplicate"), false, "not duplicate")
	eq(ctrl.phase_name(), "spinning", "spinning")
	# No message before the reveal may leak the number.
	for m in inbox:
		check(not (m is Dictionary and m.has("number")), "number leaked before reveal: %s" % str(m))
	ctrl.notify_animation_finished(1)
	var fin := await _wait_msg(ws, "animation_finished", inbox)
	eq(fin.get("number"), ctrl.state.last_number(), "number on reveal")
	eq(fin.state.drawn_count, 1, "count")
	ws.close()


func test_duplicate_request_and_busy() -> void:
	var ws := await _authed_client()
	var rid := _next_id()
	_send(ws, {"type": "spin_request", "request_id": rid})
	await _wait_msg(ws, "spin_accepted", [])
	await wait_frames(30)  # > SPIN_MIN_INTERVAL? (400ms) – wait properly below
	await wait_until(func(): return false, 0.45)
	_send(ws, {"type": "spin_request", "request_id": rid})
	var dup := await _wait_msg(ws, "spin_accepted", [])
	eq(dup.get("duplicate"), true, "duplicate flagged")
	eq(dup.state.phase, "spinning", "state attached (still spinning)")
	await wait_until(func(): return false, 0.45)
	_send(ws, {"type": "spin_request", "request_id": _next_id()})
	var rej := await _wait_msg(ws, "spin_rejected", [])
	eq(rej.get("reason"), "busy", "busy while spinning")
	eq(ctrl.state.drawn.size(), 1, "exactly one draw")
	ws.close()


func test_resend_after_finished_draw_reports_ready() -> void:
	# Reply lost, draw finished, client reconnects and re-sends the same id.
	var ws := await _authed_client()
	var rid := _next_id()
	_send(ws, {"type": "spin_request", "request_id": rid})
	await _wait_msg(ws, "spin_accepted", [])
	ctrl.notify_animation_finished(1)
	ws.close()
	await wait_until(func(): return ctrl.can_spin(), 2.0)
	var ws2 := await _authed_client()
	_send(ws2, {"type": "spin_request", "request_id": rid})
	var dup := await _wait_msg(ws2, "spin_accepted", [])
	eq(dup.get("duplicate"), true, "duplicate")
	eq(dup.state.phase, "ready", "attached state says ready, so the remote can unlock")
	check(dup.state.can_spin, "can spin again")
	eq(ctrl.state.drawn.size(), 1, "no second draw")
	ws2.close()


func test_rapid_fire_from_two_clients() -> void:
	var a := await _authed_client()
	var b := await _authed_client()
	for i in 10:
		_send(a, {"type": "spin_request", "request_id": _next_id()})
		_send(b, {"type": "spin_request", "request_id": _next_id()})
	await wait_until(func(): return false, 0.5)
	a.poll()
	b.poll()
	eq(ctrl.state.drawn.size(), 1, "only one draw from 20 requests")
	a.close()
	b.close()


func test_wrong_token_rejected() -> void:
	var ws := _client()
	eq(await _wait_open(ws), WebSocketPeer.STATE_OPEN, "open")
	_send(ws, {"type": "hello", "v": 1, "token": "wrong-token-wrong-token", "client_id": "x1234"})
	var inbox := []
	var m := await _wait_msg(ws, "auth_failed", inbox)
	check(not m.is_empty(), "auth_failed (inbox=%s state=%d code=%d)" % [str(inbox), ws.get_ready_state(), ws.get_close_code()])
	await wait_until(func():
		ws.poll()
		return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, 2.0)
	eq(ws.get_ready_state(), WebSocketPeer.STATE_CLOSED, "closed")
	eq(ctrl.state.drawn.size(), 0, "no draw")


func test_spin_without_hello_closes() -> void:
	var ws := _client()
	eq(await _wait_open(ws), WebSocketPeer.STATE_OPEN, "open")
	_send(ws, {"type": "spin_request", "request_id": _next_id()})
	await wait_until(func():
		ws.poll()
		return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, 2.0)
	eq(ws.get_ready_state(), WebSocketPeer.STATE_CLOSED, "closed")
	eq(ws.get_close_code(), 4001, "close code")
	eq(ctrl.state.drawn.size(), 0, "no draw")


func test_bad_origin_rejected() -> void:
	var ws := _client("http://evil.example")
	eq(await _wait_open(ws), WebSocketPeer.STATE_CLOSED, "handshake refused")
	var ws2 := _client("")
	eq(await _wait_open(ws2), WebSocketPeer.STATE_CLOSED, "missing origin refused")


func test_oversize_message_closes() -> void:
	var ws := await _authed_client()
	ws.send_text("{\"type\":\"ping\",\"pad\":\"" + "a".repeat(5000) + "\"}")
	await wait_until(func():
		ws.poll()
		return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, 2.0)
	eq(ws.get_ready_state(), WebSocketPeer.STATE_CLOSED, "closed")
	eq(ws.get_close_code(), 1009, "1009 too big")


func test_reconnect_gets_snapshot() -> void:
	var ws := await _authed_client()
	_send(ws, {"type": "spin_request", "request_id": _next_id()})
	await _wait_msg(ws, "spin_accepted", [])
	ctrl.notify_animation_finished(1)
	ws.close()
	var ws2 := _client()
	eq(await _wait_open(ws2), WebSocketPeer.STATE_OPEN, "reopen")
	_send(ws2, {"type": "hello", "v": 1, "token": server.token, "client_id": "test-client"})
	var w := await _wait_msg(ws2, "welcome", [])
	eq(w.state.drawn_count, 1, "snapshot after reconnect")
	eq(w.state.last_number, ctrl.state.last_number(), "last number")
	ws2.close()


func test_token_reissue_kicks_clients() -> void:
	var ws := await _authed_client()
	var old := server.token
	server.reissue_token()
	check(server.token != old, "new token")
	var m := await _wait_msg(ws, "auth_failed", [])
	check(not m.is_empty(), "kicked")


class FakeApp:
	var ctrl
	var screen := "main"
	var drafts: Array = []
	var new_games: Array = []

	func get_remote_snapshot() -> Dictionary:
		var s: Dictionary = ctrl.get_snapshot()
		s["screen"] = screen
		return s

	func remote_show_screen(sc: String) -> Dictionary:
		screen = sc
		return {"ok": true, "message": ""}

	func remote_setup_draft(t: String) -> void:
		drafts.append(t)

	func remote_new_game(id: String, t: String) -> Dictionary:
		new_games.append([id, t])
		return {"ok": t == "90", "duplicate": false, "message": "x"}


func test_screen_draft_and_new_game_commands() -> void:
	var fake := FakeApp.new()
	fake.ctrl = ctrl
	server.app = fake
	var ws := await _authed_client()
	_send(ws, {"type": "show_screen", "screen": "history"})
	var r1 := await _wait_msg(ws, "command_result", [])
	eq(r1.get("ok"), true, "show_screen ok")
	eq(fake.screen, "history", "app switched")
	_send(ws, {"type": "get_state"})
	var snap := await _wait_msg(ws, "state_snapshot", [])
	eq(snap.state.get("screen"), "history", "snapshot carries screen")
	_send(ws, {"type": "show_screen", "screen": "../../evil"})
	var r2 := await _wait_msg(ws, "command_result", [])
	eq(r2.get("ok"), false, "unknown screen rejected")
	eq(fake.screen, "history", "unchanged")
	_send(ws, {"type": "setup_draft", "max_number": "88"})
	_send(ws, {"type": "setup_draft", "max_number": 77.0})
	_send(ws, {"type": "setup_draft", "max_number": "1234567890"})
	await wait_until(func(): return fake.drafts.size() >= 2, 2.0)
	await wait_frames(5)
	eq(fake.drafts, ["88", "77"], "drafts forwarded (too long ignored)")
	_send(ws, {"type": "new_game", "request_id": _next_id(), "max_number": 90.0})
	var ng := await _wait_msg(ws, "new_game_result", [])
	eq(ng.get("ok"), true, "new_game ok")
	eq(fake.new_games[0][1], "90", "float 90.0 forwarded as text 90")
	await wait_until(func(): return false, 0.45)
	_send(ws, {"type": "new_game", "request_id": "bad id", "max_number": 75})
	var bad := await _wait_msg(ws, "new_game_result", [])
	eq(bad.get("ok"), false, "invalid request id rejected")
	eq(fake.new_games.size(), 1, "app not called for invalid id")
	_send(ws, {"type": "new_game", "request_id": _next_id(), "max_number": 7.5})
	var frac := await _wait_msg(ws, "new_game_result", [])
	eq(frac.get("ok"), false, "fractional rejected by app validation")
	ws.close()


func test_new_game_text_is_passed_unmodified() -> void:
	var fake := FakeApp.new()
	fake.ctrl = ctrl
	server.app = fake
	var ws := await _authed_client()
	_send(ws, {"type": "new_game", "request_id": _next_id(), "max_number": "75      x"})
	var r := await _wait_msg(ws, "new_game_result", [])
	eq(r.get("ok"), false, "rejected")
	eq(fake.new_games[0][1], "75      x", "app received the exact text (no trim / truncation)")
	await wait_until(func(): return false, 0.45)
	_send(ws, {"type": "new_game", "request_id": _next_id(), "max_number": "1".repeat(40)})
	var long := await _wait_msg(ws, "new_game_result", [])
	eq(long.get("ok"), false, "overlong text refused")
	eq(fake.new_games.size(), 1, "overlong text never reaches the app")
	ws.close()


func test_commands_require_auth() -> void:
	var fake := FakeApp.new()
	fake.ctrl = ctrl
	server.app = fake
	var ws := _client()
	eq(await _wait_open(ws), WebSocketPeer.STATE_OPEN, "open")
	_send(ws, {"type": "new_game", "request_id": _next_id(), "max_number": 90})
	await wait_until(func():
		ws.poll()
		return ws.get_ready_state() == WebSocketPeer.STATE_CLOSED, 2.0)
	eq(ws.get_close_code(), 4001, "closed without hello")
	eq(fake.new_games.size(), 0, "no new game without auth")


## Raw TCP WebSocket client (handshake by hand) to send arbitrary frames.
func _raw_ws() -> StreamPeerTCP:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", PORT)
	await wait_until(func():
		peer.poll()
		return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED, 2.0)
	var req := "GET /ws HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nOrigin: http://127.0.0.1:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n" % [PORT, PORT]
	peer.put_data(req.to_ascii_buffer())
	var got := PackedByteArray()
	await wait_until(func():
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			got.append_array(peer.get_data(n)[1])
		return got.get_string_from_ascii().find("\r\n\r\n") >= 0, 2.0)
	check(got.get_string_from_ascii().begins_with("HTTP/1.1 101"), "raw handshake accepted")
	return peer


func test_control_frame_flood_is_cut_off() -> void:
	var peer := await _raw_ws()
	var hello := JSON.stringify({"type": "hello", "v": 1, "token": server.token, "client_id": "flooder"})
	peer.put_data(WsCodec.encode_client_frame(WsCodec.OP_TEXT, hello.to_utf8_buffer()))
	await wait_until(func(): return server.client_count() == 1, 2.0)
	eq(server.client_count(), 1, "authenticated")
	var flood := PackedByteArray()
	var ping := WsCodec.encode_client_frame(WsCodec.OP_PING, PackedByteArray())
	for i in 5000:
		flood.append_array(ping)
	peer.put_data(flood)
	var closed := await wait_until(func():
		peer.poll()
		return peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or server.client_count() == 0, 3.0)
	check(closed, "flooding connection is closed")
	eq(server.client_count(), 0, "no authenticated client left")
	eq(ctrl.state.drawn.size(), 0, "nothing drawn")
	# A normal client still works afterwards.
	var ws := await _authed_client()
	_send(ws, {"type": "spin_request", "request_id": _next_id()})
	check(not (await _wait_msg(ws, "spin_accepted", [])).is_empty(), "server still serves others")
	ws.close()


func test_empty_fragment_flood_is_cut_off() -> void:
	var peer := await _raw_ws()
	var hello := JSON.stringify({"type": "hello", "v": 1, "token": server.token, "client_id": "fragger"})
	peer.put_data(WsCodec.encode_client_frame(WsCodec.OP_TEXT, hello.to_utf8_buffer()))
	await wait_until(func(): return server.client_count() == 1, 2.0)
	var flood := WsCodec.encode_client_frame(WsCodec.OP_TEXT, PackedByteArray(), false)
	var cont := WsCodec.encode_client_frame(WsCodec.OP_CONT, PackedByteArray(), false)
	for i in 3000:
		flood.append_array(cont)
	peer.put_data(flood)
	var closed := await wait_until(func():
		peer.poll()
		return peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or server.client_count() == 0, 3.0)
	check(closed, "empty-fragment flood is closed by the per-frame limit")
	eq(server.client_count(), 0, "no client left")


func _http_get(path: String, host: String) -> Dictionary:
	var peer := StreamPeerTCP.new()
	peer.connect_to_host("127.0.0.1", PORT)
	await wait_until(func():
		peer.poll()
		return peer.get_status() == StreamPeerTCP.STATUS_CONNECTED, 2.0)
	peer.put_data(("GET %s HTTP/1.1\r\nHost: %s\r\n\r\n" % [path, host]).to_ascii_buffer())
	var data := PackedByteArray()
	await wait_until(func():
		peer.poll()
		var n := peer.get_available_bytes()
		if n > 0:
			data.append_array(peer.get_data(n)[1])
		return peer.get_status() != StreamPeerTCP.STATUS_CONNECTED, 3.0)
	var text := data.get_string_from_utf8()
	var code := text.substr(9, 3).to_int() if text.length() > 12 else 0
	return {"code": code, "text": text}


func test_http_static_and_host_check() -> void:
	var host := "127.0.0.1:%d" % PORT
	var r := await _http_get("/", host)
	eq(r.code, 200, "index 200")
	check(r.text.find("<html") >= 0, "html body")
	check(r.text.find("Content-Security-Policy") >= 0, "csp header")
	eq((await _http_get("/app.js", host)).code, 200, "app.js")
	eq((await _http_get("/styles.css", host)).code, 200, "styles.css")
	eq((await _http_get("/../project.godot", host)).code, 404, "no traversal")
	eq((await _http_get("/scripts/core/game_state.gd", host)).code, 404, "no arbitrary files")
	eq((await _http_get("/", "evil.example:%d" % PORT)).code, 421, "bad host")

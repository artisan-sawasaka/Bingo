extends "res://tests/test_case.gd"

const WsCodec = preload("res://scripts/net/ws_codec.gd")
const HttpRequest = preload("res://scripts/net/http_request.gd")
const RemoteSecret = preload("res://scripts/net/remote_secret.gd")
const NetInfo = preload("res://scripts/net/net_info.gd")


func test_accept_key_rfc_example() -> void:
	# RFC 6455 section 1.3 example.
	eq(WsCodec.accept_key("dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=", "accept")


func test_masked_text_roundtrip_all_length_forms() -> void:
	for n in [0, 5, 125, 126, 1000, 4096]:
		var codec := WsCodec.new()
		codec.max_message_bytes = 70000
		var text := "a".repeat(n)
		codec.feed(WsCodec.encode_client_frame(WsCodec.OP_TEXT, text.to_utf8_buffer()))
		var ev := codec.next_event()
		eq(ev.get("type"), "text", "type n=%d" % n)
		eq(String(ev.get("data", "")).length(), n, "len n=%d" % n)


func test_byte_by_byte_feeding() -> void:
	var codec := WsCodec.new()
	var frame := WsCodec.encode_client_frame(WsCodec.OP_TEXT, "{\"type\":\"ping\"}".to_utf8_buffer())
	for i in frame.size():
		check(codec.next_event().is_empty(), "incomplete at %d" % i)
		codec.feed(frame.slice(i, i + 1))
	eq(codec.next_event().get("data"), "{\"type\":\"ping\"}", "complete")


func test_two_frames_in_one_chunk_and_utf8() -> void:
	var codec := WsCodec.new()
	var buf := WsCodec.encode_client_frame(WsCodec.OP_TEXT, "抽選".to_utf8_buffer())
	buf.append_array(WsCodec.encode_client_frame(WsCodec.OP_PING, "hi".to_ascii_buffer()))
	codec.feed(buf)
	eq(codec.next_event().get("data"), "抽選", "utf8")
	var ping := codec.next_event()
	eq(ping.get("type"), "ping", "ping")
	eq(ping.data.get_string_from_ascii(), "hi", "ping payload")


func test_fragmented_message() -> void:
	var codec := WsCodec.new()
	codec.feed(WsCodec.encode_client_frame(WsCodec.OP_TEXT, "hel".to_ascii_buffer(), false))
	codec.feed(WsCodec.encode_client_frame(WsCodec.OP_PING, PackedByteArray()))  # control frame interleaved
	codec.feed(WsCodec.encode_client_frame(WsCodec.OP_CONT, "lo".to_ascii_buffer(), true))
	eq(codec.next_event().get("type"), "fragment", "first fragment is its own event")
	eq(codec.next_event().get("type"), "ping", "interleaved ping")
	eq(codec.next_event().get("data"), "hello", "reassembled")


func test_every_frame_is_an_event() -> void:
	# Empty non-final continuation frames must not be swallowed silently.
	var codec := WsCodec.new()
	codec.feed(WsCodec.encode_client_frame(WsCodec.OP_TEXT, PackedByteArray(), false))
	for i in 50:
		codec.feed(WsCodec.encode_client_frame(WsCodec.OP_CONT, PackedByteArray(), false))
	var n := 0
	while true:
		var ev := codec.next_event()
		if ev.is_empty():
			break
		eq(ev.get("type"), "fragment", "fragment %d" % n)
		n += 1
	eq(n, 51, "one event per frame")


func test_rejects_unmasked_oversize_rsv_and_bad_control() -> void:
	var c1 := WsCodec.new()
	c1.feed(WsCodec.encode_frame(WsCodec.OP_TEXT, "x".to_ascii_buffer()))
	eq(c1.next_event().get("code"), 1002, "unmasked")
	var c2 := WsCodec.new()
	c2.max_message_bytes = 100
	c2.feed(WsCodec.encode_client_frame(WsCodec.OP_TEXT, "a".repeat(101).to_ascii_buffer()))
	eq(c2.next_event().get("code"), 1009, "too big")
	var c3 := WsCodec.new()
	var f := WsCodec.encode_client_frame(WsCodec.OP_TEXT, "x".to_ascii_buffer())
	f[0] = f[0] | 0x40
	c3.feed(f)
	eq(c3.next_event().get("code"), 1002, "rsv")
	var c4 := WsCodec.new()
	c4.feed(WsCodec.encode_client_frame(WsCodec.OP_PING, "x".to_ascii_buffer(), false))
	eq(c4.next_event().get("code"), 1002, "fragmented control")
	var c5 := WsCodec.new()
	c5.feed(WsCodec.encode_client_frame(WsCodec.OP_CONT, "x".to_ascii_buffer()))
	eq(c5.next_event().get("code"), 1002, "stray continuation")
	var c6 := WsCodec.new()
	c6.max_message_bytes = 10
	c6.feed(WsCodec.encode_client_frame(WsCodec.OP_TEXT, "123456".to_ascii_buffer(), false))
	c6.feed(WsCodec.encode_client_frame(WsCodec.OP_CONT, "123456".to_ascii_buffer(), true))
	eq(c6.next_event().get("type"), "fragment", "first piece")
	eq(c6.next_event().get("code"), 1009, "fragments exceed limit")


func test_close_frame() -> void:
	var codec := WsCodec.new()
	codec.feed(WsCodec.encode_client_frame(WsCodec.OP_CLOSE, PackedByteArray([0x03, 0xE8, 0x62, 0x79, 0x65])))
	var ev := codec.next_event()
	eq(ev.get("type"), "close", "type")
	eq(ev.get("code"), 1000, "code")
	eq(ev.get("reason"), "bye", "reason")


func test_server_frame_encoding_lengths() -> void:
	eq(WsCodec.encode_text("abc").slice(0, 2), PackedByteArray([0x81, 3]), "short")
	var mid := WsCodec.encode_text("a".repeat(300))
	eq(mid.slice(0, 4), PackedByteArray([0x81, 126, 0x01, 0x2C]), "16-bit")
	var big := WsCodec.encode_text("a".repeat(70000))
	eq(big[1], 127, "64-bit marker")
	eq(big.size(), 70000 + 10, "64-bit size")


func test_http_parse() -> void:
	var req := "GET /app.js?x=1 HTTP/1.1\r\nHost: 192.168.1.5:8765\r\nConnection: keep-alive, Upgrade\r\nUpgrade: websocket\r\n\r\n".to_ascii_buffer()
	var r := HttpRequest.parse(req)
	eq(r.status, "ok", "ok")
	eq(r.method, "GET", "method")
	eq(r.path, "/app.js", "path")
	eq(r.query, "x=1", "query")
	eq(r.headers.host, "192.168.1.5:8765", "host")
	check(HttpRequest.header_has_token(r.headers, "connection", "upgrade"), "token")
	eq(HttpRequest.parse("GET / HTTP/1.1\r\nHost: x".to_ascii_buffer()).status, "incomplete", "incomplete")
	eq(HttpRequest.parse("garbage\r\n\r\n".to_ascii_buffer()).status, "error", "bad line")
	var huge := ("GET / HTTP/1.1\r\nX: " + "a".repeat(9000)).to_ascii_buffer()
	eq(HttpRequest.parse(huge).code, 431, "too large")


func test_secret_token_and_compare() -> void:
	var t := RemoteSecret.generate_token()
	check(RemoteSecret.is_well_formed(t), "well formed %s" % t.length())
	check(t.length() >= 22, "length")
	check(RemoteSecret.matches(t, t), "match")
	check(not RemoteSecret.matches(t, t + "x"), "longer")
	check(not RemoteSecret.matches(t, t.substr(0, t.length() - 1)), "shorter")
	check(not RemoteSecret.matches(t, null), "null")
	check(not RemoteSecret.matches("", ""), "empty expected")
	check(RemoteSecret.generate_token() != t, "random")


func test_secret_reissue_persists_or_reports_failure() -> void:
	var dir := scratch_dir("secret_reissue")
	var s := RemoteSecret.new(dir + "remote_secret.json")
	var first := s.load_or_create()
	check(RemoteSecret.is_well_formed(first), "created")
	check(s.reissue(), "reissue saved")
	var second := s.token
	check(second != first, "new token")
	eq(RemoteSecret.new(dir + "remote_secret.json").load_or_create(), second, "restart loads the reissued token")
	# Read-only file: the new token cannot replace it -> must report failure.
	FileAccess.set_read_only_attribute(dir + "remote_secret.json", true)
	var ok := s.reissue()
	FileAccess.set_read_only_attribute(dir + "remote_secret.json", false)
	check(not ok, "failure reported when the file cannot be replaced")
	check(not s.last_error.is_empty(), "reason given")
	check(s.token != second, "old links are still cut off in memory")


func test_private_ip_detection() -> void:
	for ip in ["192.168.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255"]:
		check(NetInfo.is_private_ipv4(ip), ip)
	for ip in ["8.8.8.8", "172.32.0.1", "127.0.0.1", "169.254.1.1", "::1", "fe80::1", "abc"]:
		check(not NetInfo.is_private_ipv4(ip), "not " + ip)

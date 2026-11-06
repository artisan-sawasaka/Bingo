extends RefCounted
## RFC 6455 WebSocket framing (server side). Pure byte logic, unit tested.
## - Client frames MUST be masked; server frames are never masked.
## - No extensions are negotiated, so RSV bits must be zero.
## - Fragmented messages are reassembled up to `max_message_bytes`.

const OP_CONT := 0x0
const OP_TEXT := 0x1
const OP_BINARY := 0x2
const OP_CLOSE := 0x8
const OP_PING := 0x9
const OP_PONG := 0xA
const GUID := "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

var max_message_bytes: int = 4096
var _buf := PackedByteArray()
var _frag := PackedByteArray()
var _frag_opcode: int = -1
## Set when a protocol violation happened: { code, reason }.
var error: Dictionary = {}


static func accept_key(sec_websocket_key: String) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA1)
	ctx.update((sec_websocket_key + GUID).to_utf8_buffer())
	return Marshalls.raw_to_base64(ctx.finish())


func feed(bytes: PackedByteArray) -> void:
	_buf.append_array(bytes)


func buffered_size() -> int:
	return _buf.size()


## Returns the event for the next complete FRAME or {} when more bytes are needed.
## Events: { type: "text", data: String } | { type: "binary", data } |
##         { type: "fragment" } (a non-final piece of a fragmented message) |
##         { type: "ping", data } | { type: "pong", data } |
##         { type: "close", code, reason } | { type: "error", code, reason }
func next_event() -> Dictionary:
	if not error.is_empty():
		return {}
	while true:
		if _buf.size() < 2:
			return {}
		var b0: int = _buf[0]
		var b1: int = _buf[1]
		var fin := (b0 & 0x80) != 0
		var rsv := b0 & 0x70
		var opcode := b0 & 0x0F
		var masked := (b1 & 0x80) != 0
		var len7 := b1 & 0x7F
		var header := 2
		var plen := len7
		if len7 == 126:
			if _buf.size() < 4:
				return {}
			plen = (_buf[2] << 8) | _buf[3]
			header = 4
		elif len7 == 127:
			if _buf.size() < 10:
				return {}
			if _buf[2] & 0x80:
				return _fail(1002, "invalid length")
			plen = 0
			for i in 8:
				plen = (plen << 8) | _buf[2 + i]
			header = 10
		if rsv != 0:
			return _fail(1002, "rsv bits set")
		if not masked:
			return _fail(1002, "client frame not masked")
		var is_control := opcode >= 0x8
		if is_control and (not fin or plen > 125):
			return _fail(1002, "bad control frame")
		if not is_control and opcode not in [OP_CONT, OP_TEXT, OP_BINARY]:
			return _fail(1002, "unknown opcode")
		if is_control and opcode not in [OP_CLOSE, OP_PING, OP_PONG]:
			return _fail(1002, "unknown control opcode")
		if plen > max_message_bytes or _frag.size() + plen > max_message_bytes:
			return _fail(1009, "message too big")
		var total := header + 4 + plen
		if _buf.size() < total:
			return {}
		var mask := _buf.slice(header, header + 4)
		var payload := _buf.slice(header + 4, total)
		for i in payload.size():
			payload[i] = payload[i] ^ mask[i & 3]
		_buf = _buf.slice(total)
		if is_control:
			match opcode:
				OP_PING:
					return {"type": "ping", "data": payload}
				OP_PONG:
					return {"type": "pong", "data": payload}
				OP_CLOSE:
					var code := 1005
					var reason := ""
					if payload.size() >= 2:
						code = (payload[0] << 8) | payload[1]
						reason = payload.slice(2).get_string_from_utf8()
					return {"type": "close", "code": code, "reason": reason}
		# Every frame yields an event (non-final fragments yield "fragment"), so
		# the caller can rate-limit per FRAME, not per completed message.
		if opcode == OP_CONT:
			if _frag_opcode < 0:
				return _fail(1002, "unexpected continuation")
			_frag.append_array(payload)
			if not fin:
				return {"type": "fragment"}
			var op := _frag_opcode
			var data := _frag
			_frag = PackedByteArray()
			_frag_opcode = -1
			return _data_event(op, data)
		# TEXT / BINARY start
		if _frag_opcode >= 0:
			return _fail(1002, "expected continuation")
		if not fin:
			_frag_opcode = opcode
			_frag = payload
			return {"type": "fragment"}
		return _data_event(opcode, payload)
	return {}


func _data_event(opcode: int, data: PackedByteArray) -> Dictionary:
	if opcode == OP_TEXT:
		var s := data.get_string_from_utf8()
		# Invalid UTF-8 yields an empty / altered string; reject when lengths disagree badly.
		if s.is_empty() and not data.is_empty():
			return _fail(1007, "invalid utf-8")
		return {"type": "text", "data": s}
	return {"type": "binary", "data": data}


func _fail(code: int, reason: String) -> Dictionary:
	error = {"code": code, "reason": reason}
	return {"type": "error", "code": code, "reason": reason}


## Encodes an unmasked server frame.
static func encode_frame(opcode: int, payload: PackedByteArray, fin: bool = true) -> PackedByteArray:
	var out := PackedByteArray()
	out.append((0x80 if fin else 0x00) | (opcode & 0x0F))
	var n := payload.size()
	if n < 126:
		out.append(n)
	elif n < 65536:
		out.append(126)
		out.append((n >> 8) & 0xFF)
		out.append(n & 0xFF)
	else:
		out.append(127)
		for i in range(7, -1, -1):
			out.append((n >> (i * 8)) & 0xFF)
	out.append_array(payload)
	return out


static func encode_text(text: String) -> PackedByteArray:
	return encode_frame(OP_TEXT, text.to_utf8_buffer())


static func encode_close(code: int, reason: String = "") -> PackedByteArray:
	var p := PackedByteArray([(code >> 8) & 0xFF, code & 0xFF])
	p.append_array(reason.to_utf8_buffer().slice(0, 120))
	return encode_frame(OP_CLOSE, p)


## Encodes a MASKED frame (client side) — used by tests only.
static func encode_client_frame(opcode: int, payload: PackedByteArray, fin: bool = true, mask_key: PackedByteArray = PackedByteArray([0x12, 0x34, 0x56, 0x78])) -> PackedByteArray:
	var out := PackedByteArray()
	out.append((0x80 if fin else 0x00) | (opcode & 0x0F))
	var n := payload.size()
	if n < 126:
		out.append(0x80 | n)
	elif n < 65536:
		out.append(0x80 | 126)
		out.append((n >> 8) & 0xFF)
		out.append(n & 0xFF)
	else:
		out.append(0x80 | 127)
		for i in range(7, -1, -1):
			out.append((n >> (i * 8)) & 0xFF)
	out.append_array(mask_key)
	var masked := payload.duplicate()
	for i in masked.size():
		masked[i] = masked[i] ^ mask_key[i & 3]
	out.append_array(masked)
	return out

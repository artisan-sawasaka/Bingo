extends RefCounted
## QR Code encoder (ISO/IEC 18004, model 2), byte mode only.
## Algorithm follows Project Nayuki's reference implementation (MIT).
## Usage: var m := QrCode.encode_text("http://...", QrCode.ECC_M)  -> { size, modules: PackedByteArray }

const ECC_L := 0
const ECC_M := 1
const ECC_Q := 2
const ECC_H := 3
const _FORMAT_BITS := [1, 0, 3, 2]  # L, M, Q, H

const _ECC_CODEWORDS_PER_BLOCK := [
	[-1, 7, 10, 15, 20, 26, 18, 20, 24, 30, 18, 20, 24, 26, 30, 22, 24, 28, 30, 28, 28, 28, 28, 30, 30, 26, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
	[-1, 10, 16, 26, 18, 24, 16, 18, 22, 22, 26, 30, 22, 22, 24, 24, 28, 28, 26, 26, 26, 26, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28, 28],
	[-1, 13, 22, 18, 26, 18, 24, 18, 22, 20, 24, 28, 26, 24, 20, 30, 24, 28, 28, 26, 30, 28, 30, 30, 30, 30, 28, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
	[-1, 17, 28, 22, 16, 22, 28, 26, 26, 24, 28, 24, 28, 22, 24, 24, 30, 28, 28, 26, 28, 30, 24, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30, 30],
]
const _NUM_ERROR_CORRECTION_BLOCKS := [
	[-1, 1, 1, 1, 1, 1, 2, 2, 2, 2, 4, 4, 4, 4, 4, 6, 6, 6, 6, 7, 8, 8, 9, 9, 10, 12, 12, 12, 13, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 24, 25],
	[-1, 1, 1, 1, 2, 2, 4, 4, 4, 5, 5, 5, 8, 9, 9, 10, 10, 11, 13, 14, 16, 17, 17, 18, 20, 21, 23, 25, 26, 28, 29, 31, 33, 35, 37, 38, 40, 43, 45, 47, 49],
	[-1, 1, 1, 2, 2, 4, 4, 6, 6, 8, 8, 8, 10, 12, 16, 12, 17, 16, 18, 21, 20, 23, 23, 25, 27, 29, 34, 34, 35, 38, 40, 43, 45, 48, 51, 53, 56, 59, 62, 65, 68],
	[-1, 1, 1, 2, 4, 4, 4, 5, 6, 8, 8, 11, 11, 16, 16, 18, 16, 19, 21, 25, 25, 25, 34, 30, 32, 35, 37, 40, 42, 45, 48, 51, 54, 57, 60, 63, 66, 70, 74, 77, 81],
]

var version: int
var size: int
var ecl: int
var mask: int
var modules := PackedByteArray()
var _is_function := PackedByteArray()


## Encodes UTF-8 text. Returns null if it does not fit in version 40.
## forced_mask = -1 picks the mask with the lowest penalty.
static func encode_text(text: String, p_ecl: int = ECC_M, forced_mask: int = -1):
	var data := text.to_utf8_buffer()
	for ver in range(1, 41):
		var cc_bits := 8 if ver <= 9 else 16
		var need := 4 + cc_bits + data.size() * 8
		var cap := _num_data_codewords(ver, p_ecl) * 8
		if data.size() < (1 << cc_bits) and need <= cap:
			var q = load("res://scripts/util/qr_code.gd").new()
			q._build(ver, p_ecl, data, forced_mask)
			return q
	return null


func get_module(x: int, y: int) -> bool:
	if x < 0 or y < 0 or x >= size or y >= size:
		return false
	return modules[y * size + x] != 0


## Renders to an Image (black on white) with a quiet zone of `border` modules.
func to_image(scale: int = 8, border: int = 4) -> Image:
	var dim := (size + border * 2) * scale
	var img := Image.create(dim, dim, false, Image.FORMAT_L8)
	img.fill(Color.WHITE)
	for y in size:
		for x in size:
			if get_module(x, y):
				img.fill_rect(Rect2i((x + border) * scale, (y + border) * scale, scale, scale), Color.BLACK)
	return img


# ------------------------------------------------------------------ build

static func _num_raw_data_modules(ver: int) -> int:
	var result := (16 * ver + 128) * ver + 64
	if ver >= 2:
		var num_align := ver / 7 + 2
		result -= (25 * num_align - 10) * num_align - 55
		if ver >= 7:
			result -= 36
	return result


static func _num_data_codewords(ver: int, p_ecl: int) -> int:
	return _num_raw_data_modules(ver) / 8 - _ECC_CODEWORDS_PER_BLOCK[p_ecl][ver] * _NUM_ERROR_CORRECTION_BLOCKS[p_ecl][ver]


func _build(ver: int, p_ecl: int, data: PackedByteArray, forced_mask: int) -> void:
	version = ver
	ecl = p_ecl
	size = ver * 4 + 17
	modules.resize(size * size)
	modules.fill(0)
	_is_function.resize(size * size)
	_is_function.fill(0)

	# Bit stream: mode (byte=0100), count, data, terminator, padding.
	var bits: Array[int] = []
	_append_bits(bits, 0x4, 4)
	_append_bits(bits, data.size(), 8 if ver <= 9 else 16)
	for b in data:
		_append_bits(bits, b, 8)
	var cap_bits := _num_data_codewords(ver, p_ecl) * 8
	_append_bits(bits, 0, mini(4, cap_bits - bits.size()))
	_append_bits(bits, 0, (8 - bits.size() % 8) % 8)
	var pad := 0xEC
	while bits.size() < cap_bits:
		_append_bits(bits, pad, 8)
		pad = 0x11 if pad == 0xEC else 0xEC
	var codewords := PackedByteArray()
	codewords.resize(bits.size() / 8)
	for i in bits.size():
		codewords[i >> 3] = codewords[i >> 3] | (bits[i] << (7 - (i & 7)))

	_draw_function_patterns()
	var all := _add_ecc_and_interleave(codewords)
	_draw_codewords(all)

	if forced_mask < 0:
		var best := 0
		var min_penalty := 1 << 60
		for m in 8:
			_apply_mask(m)
			_draw_format_bits(m)
			var p := _penalty_score()
			if p < min_penalty:
				best = m
				min_penalty = p
			_apply_mask(m)  # XOR again to undo
		forced_mask = best
	mask = forced_mask
	_apply_mask(mask)
	_draw_format_bits(mask)
	_is_function = PackedByteArray()


static func _append_bits(bits: Array[int], val: int, length: int) -> void:
	for i in range(length - 1, -1, -1):
		bits.append((val >> i) & 1)


func _set_function(x: int, y: int, dark: bool) -> void:
	modules[y * size + x] = 1 if dark else 0
	_is_function[y * size + x] = 1


func _draw_function_patterns() -> void:
	for i in size:
		_set_function(6, i, i % 2 == 0)
		_set_function(i, 6, i % 2 == 0)
	_draw_finder(3, 3)
	_draw_finder(size - 4, 3)
	_draw_finder(3, size - 4)
	var pos := _alignment_positions()
	var n := pos.size()
	for i in n:
		for j in n:
			if not ((i == 0 and j == 0) or (i == 0 and j == n - 1) or (i == n - 1 and j == 0)):
				_draw_alignment(pos[i], pos[j])
	_draw_format_bits(0)  # placeholder, overwritten later
	_draw_version()


func _draw_finder(x: int, y: int) -> void:
	for dy in range(-4, 5):
		for dx in range(-4, 5):
			var dist := maxi(absi(dx), absi(dy))
			var xx := x + dx
			var yy := y + dy
			if xx >= 0 and xx < size and yy >= 0 and yy < size:
				_set_function(xx, yy, dist != 2 and dist != 4)


func _draw_alignment(x: int, y: int) -> void:
	for dy in range(-2, 3):
		for dx in range(-2, 3):
			_set_function(x + dx, y + dy, maxi(absi(dx), absi(dy)) != 1)


func _alignment_positions() -> Array[int]:
	var out: Array[int] = []
	if version == 1:
		return out
	var num_align := version / 7 + 2
	var step := (version * 8 + num_align * 3 + 5) / (num_align * 4 - 4) * 2
	out.append(6)
	var tail: Array[int] = []
	var p := size - 7
	for i in num_align - 1:
		tail.push_front(p)
		p -= step
	out.append_array(tail)
	return out


func _draw_format_bits(m: int) -> void:
	var fb: int = _FORMAT_BITS[ecl]
	var data: int = (fb << 3) | m
	var rem: int = data
	for i in 10:
		rem = (rem << 1) ^ ((rem >> 9) * 0x537)
	var bits: int = ((data << 10) | rem) ^ 0x5412
	for i in range(0, 6):
		_set_function(8, i, _bit(bits, i))
	_set_function(8, 7, _bit(bits, 6))
	_set_function(8, 8, _bit(bits, 7))
	_set_function(7, 8, _bit(bits, 8))
	for i in range(9, 15):
		_set_function(14 - i, 8, _bit(bits, i))
	for i in range(0, 8):
		_set_function(size - 1 - i, 8, _bit(bits, i))
	for i in range(8, 15):
		_set_function(8, size - 15 + i, _bit(bits, i))
	_set_function(8, size - 8, true)  # always dark


func _draw_version() -> void:
	if version < 7:
		return
	var rem := version
	for i in 12:
		rem = (rem << 1) ^ ((rem >> 11) * 0x1F25)
	var bits := (version << 12) | rem
	for i in 18:
		var b := _bit(bits, i)
		var a := size - 11 + i % 3
		var c := i / 3
		_set_function(a, c, b)
		_set_function(c, a, b)


static func _bit(x: int, i: int) -> bool:
	return ((x >> i) & 1) != 0


func _add_ecc_and_interleave(data: PackedByteArray) -> PackedByteArray:
	var num_blocks: int = _NUM_ERROR_CORRECTION_BLOCKS[ecl][version]
	var block_ecc_len: int = _ECC_CODEWORDS_PER_BLOCK[ecl][version]
	var raw_codewords := _num_raw_data_modules(version) / 8
	var num_short_blocks := num_blocks - raw_codewords % num_blocks
	var short_block_len := raw_codewords / num_blocks
	var blocks: Array = []
	var divisor := _rs_divisor(block_ecc_len)
	var k := 0
	for i in num_blocks:
		var dat_len := short_block_len - block_ecc_len + (0 if i < num_short_blocks else 1)
		var dat := data.slice(k, k + dat_len)
		k += dat_len
		var ecc := _rs_remainder(dat, divisor)
		var block := dat.duplicate()
		if i < num_short_blocks:
			block.append(0)  # padding slot, skipped when interleaving
		block.append_array(ecc)
		blocks.append(block)
	var result := PackedByteArray()
	var blen: int = blocks[0].size()
	for i in blen:
		for j in blocks.size():
			if i != short_block_len - block_ecc_len or j >= num_short_blocks:
				result.append(blocks[j][i])
	return result


static func _rs_divisor(degree: int) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(degree)
	result.fill(0)
	result[degree - 1] = 1
	var root := 1
	for i in degree:
		for j in degree:
			result[j] = _rs_mul(result[j], root)
			if j + 1 < degree:
				result[j] = result[j] ^ result[j + 1]
		root = _rs_mul(root, 0x02)
	return result


static func _rs_remainder(data: PackedByteArray, divisor: PackedByteArray) -> PackedByteArray:
	var result := PackedByteArray()
	result.resize(divisor.size())
	result.fill(0)
	for b in data:
		var factor: int = b ^ result[0]
		result = result.slice(1)
		result.append(0)
		for i in divisor.size():
			result[i] = result[i] ^ _rs_mul(divisor[i], factor)
	return result


static func _rs_mul(x: int, y: int) -> int:
	var z := 0
	for i in range(7, -1, -1):
		z = (z << 1) ^ ((z >> 7) * 0x11D)
		z ^= ((y >> i) & 1) * x
	return z & 0xFF


func _draw_codewords(data: PackedByteArray) -> void:
	var i := 0
	var right := size - 1
	while right >= 1:
		if right == 6:
			right = 5
		for vert in size:
			for j in 2:
				var x := right - j
				var upward := ((right + 1) & 2) == 0
				var y := size - 1 - vert if upward else vert
				if _is_function[y * size + x] == 0 and i < data.size() * 8:
					modules[y * size + x] = 1 if _bit(data[i >> 3], 7 - (i & 7)) else 0
					i += 1
		right -= 2


func _apply_mask(m: int) -> void:
	for y in size:
		for x in size:
			var invert := false
			match m:
				0: invert = (x + y) % 2 == 0
				1: invert = y % 2 == 0
				2: invert = x % 3 == 0
				3: invert = (x + y) % 3 == 0
				4: invert = (x / 3 + y / 2) % 2 == 0
				5: invert = x * y % 2 + x * y % 3 == 0
				6: invert = (x * y % 2 + x * y % 3) % 2 == 0
				7: invert = ((x + y) % 2 + x * y % 3) % 2 == 0
			if invert and _is_function[y * size + x] == 0:
				modules[y * size + x] = modules[y * size + x] ^ 1


func _penalty_score() -> int:
	var result := 0
	# Adjacent modules in rows/columns with same color + finder-like patterns.
	for pass_i in 2:
		for a in size:
			var run_color := false
			var run_len := 0
			var history := [0, 0, 0, 0, 0, 0, 0]
			for b in size:
				var dark := get_module(b, a) if pass_i == 0 else get_module(a, b)
				if dark == run_color:
					run_len += 1
					if run_len == 5:
						result += 3
					elif run_len > 5:
						result += 1
				else:
					_finder_add_history(run_len, history)
					if not run_color:
						result += _finder_count_patterns(history) * 40
					run_color = dark
					run_len = 1
			result += _finder_terminate_and_count(run_color, run_len, history) * 40
	# 2x2 blocks.
	for y in size - 1:
		for x in size - 1:
			var c := get_module(x, y)
			if c == get_module(x + 1, y) and c == get_module(x, y + 1) and c == get_module(x + 1, y + 1):
				result += 3
	# Dark/light balance.
	var dark_count := 0
	for v in modules:
		dark_count += v
	var total := size * size
	var k := int(ceil(absf(dark_count * 20.0 - total * 10.0) / total)) - 1
	result += maxi(k, 0) * 10
	return result


func _finder_count_patterns(h: Array) -> int:
	var n: int = h[1]
	var core: bool = n > 0 and h[2] == n and h[3] == n * 3 and h[4] == n and h[5] == n
	return (1 if core and h[0] >= n * 4 and h[6] >= n else 0) + (1 if core and h[6] >= n * 4 and h[0] >= n else 0)


func _finder_terminate_and_count(run_color: bool, run_len: int, h: Array) -> int:
	if run_color:
		_finder_add_history(run_len, h)
		run_len = 0
	run_len += size
	_finder_add_history(run_len, h)
	return _finder_count_patterns(h)


func _finder_add_history(run_len: int, h: Array) -> void:
	if h[0] == 0:
		run_len += size  # light border before the first run
	h.pop_back()
	h.push_front(run_len)

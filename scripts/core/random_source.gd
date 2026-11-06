extends RefCounted
## Uniform integer source used by the draw logic.
## Default implementation uses Godot's Crypto (OS CSPRNG) with rejection
## sampling so every remaining number has exactly the same probability.
## Tests may inject a seeded source via `RandomSource.seeded(seed)`.

var _crypto: Crypto = null
var _rng: RandomNumberGenerator = null


static func secure() -> RefCounted:
	var s = load("res://scripts/core/random_source.gd").new()
	s._crypto = Crypto.new()
	return s


static func seeded(seed_value: int) -> RefCounted:
	var s = load("res://scripts/core/random_source.gd").new()
	s._rng = RandomNumberGenerator.new()
	s._rng.seed = seed_value
	return s


## Returns an integer in [0, n). n must be >= 1.
func randi_below(n: int) -> int:
	assert(n >= 1)
	if n == 1:
		return 0
	if _rng != null:
		return _rng.randi_range(0, n - 1)
	# Rejection sampling on 32-bit values: unbiased for any n <= 2^32.
	var space := 4294967296  # 2^32
	var limit := space - (space % n)
	while true:
		var r := _random_u32()
		if r < limit:
			return r % n
	return 0


func _random_u32() -> int:
	if _crypto == null:
		_crypto = Crypto.new()
	var bytes: PackedByteArray = _crypto.generate_random_bytes(4)
	return bytes.decode_u32(0)


## Random hex string of `byte_count` bytes (for IDs). Uses CSPRNG unless seeded.
func random_hex(byte_count: int) -> String:
	var bytes := PackedByteArray()
	if _rng != null:
		bytes.resize(byte_count)
		for i in byte_count:
			bytes[i] = _rng.randi_range(0, 255)
	else:
		if _crypto == null:
			_crypto = Crypto.new()
		bytes = _crypto.generate_random_bytes(byte_count)
	return bytes.hex_encode()

extends RefCounted
## Non-critical user preferences (user://settings.json). Game results are NOT here.

## Fixed animation speeds (factor applied to BASE_TIMING).
const SPEEDS := {"short": 0.75, "normal": 1.0, "long": 1.3}
## Options shown in the settings screen, in order. "random" = one of SPEEDS per draw.
const SPEED_OPTIONS := ["short", "normal", "long", "random"]
const SPEED_LABELS := {"short": "短い", "normal": "標準", "long": "長い", "random": "ランダム"}

## Base draw sequence (seconds, before the speed factor). Brief §2.3.
const BASE_TIMING := {"start": 0.2, "spin_end": 1.4, "eject_end": 1.85, "reveal_end": 2.4}

var path: String
var volume: float = 0.8
var speed: String = "normal"
var fullscreen: bool = true
var safe_margin: float = 0.03
var port: int = 8765


func _init(p_path: String = "user://settings.json") -> void:
	path = p_path


func load_file() -> void:
	if not FileAccess.file_exists(path):
		return
	var d = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(d) != TYPE_DICTIONARY:
		return
	if typeof(d.get("volume")) == TYPE_FLOAT:
		volume = clampf(d.volume, 0.0, 1.0)
	if typeof(d.get("speed")) == TYPE_STRING and SPEED_OPTIONS.has(d.speed):
		speed = d.speed
	if typeof(d.get("fullscreen")) == TYPE_BOOL:
		fullscreen = d.fullscreen
	if typeof(d.get("safe_margin")) == TYPE_FLOAT:
		safe_margin = clampf(d.safe_margin, 0.0, 0.1)
	if typeof(d.get("port")) == TYPE_FLOAT and d.port >= 1024 and d.port <= 65000:
		port = int(d.port)


func save_file() -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("settings: cannot write %s" % path)
		return
	f.store_string(JSON.stringify({"volume": volume, "speed": speed, "fullscreen": fullscreen, "safe_margin": safe_margin, "port": port}, "  "))
	f.close()


## Speed key used for the next draw: the setting itself, or (for "random")
## one of short / normal / long chosen uniformly.
func pick_speed(rng: RandomNumberGenerator) -> String:
	if speed == "random":
		var keys: Array = SPEEDS.keys()
		return keys[rng.randi_range(0, keys.size() - 1)]
	return speed if SPEEDS.has(speed) else "normal"


static func factor_of(speed_key: String) -> float:
	return SPEEDS.get(speed_key, 1.0)


static func timing_for(speed_key: String) -> Dictionary:
	var k := factor_of(speed_key)
	var out := {}
	for key in BASE_TIMING:
		out[key] = BASE_TIMING[key] * k
	return out


## Longest animation the current setting can produce (for the reveal watchdog).
func max_reveal_sec() -> float:
	var k := factor_of(speed)
	if speed == "random":
		for v in SPEEDS.values():
			k = maxf(k, v)
	return BASE_TIMING.reveal_end * k

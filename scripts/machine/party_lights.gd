extends Node3D
## Festoon string lights hanging behind the machine (party mood). Bulbs share
## one material per color; brightness twinkles and follows `energy`
## (1 idle, higher while spinning / on reveal) set by bingo_machine.gd.

const COLORS := [
	Color(1.0, 0.35, 0.7),   # pink
	Color(1.0, 0.78, 0.3),   # gold
	Color(0.3, 0.85, 1.0),   # cyan
	Color(0.65, 0.45, 1.0),  # violet
	Color(1.0, 0.55, 0.25),  # orange
]

## Each garland: start, end, sag (m), bulb count.
const GARLANDS := [
	[Vector3(-7.0, 3.9, -4.5), Vector3(6.5, 4.1, -4.5), 0.9, 34],
	[Vector3(-6.0, 3.2, -6.5), Vector3(7.5, 3.0, -6.5), 0.7, 30],
]

var energy := 1.0
var _mats: Array[StandardMaterial3D] = []
var _phase := 0.0


func _ready() -> void:
	var bulb := SphereMesh.new()
	bulb.radius = 0.055
	bulb.height = 0.11
	bulb.radial_segments = 10
	bulb.rings = 5
	for c in COLORS:
		var m := StandardMaterial3D.new()
		m.albedo_color = c
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = 1.6
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_mats.append(m)
	var wire_mat := StandardMaterial3D.new()
	wire_mat.albedo_color = Color(0.08, 0.06, 0.1)
	wire_mat.roughness = 0.8
	var k := 0
	for g in GARLANDS:
		var a: Vector3 = g[0]
		var b: Vector3 = g[1]
		var sag: float = g[2]
		var n: int = g[3]
		var prev := Vector3.ZERO
		for i in n + 1:
			var t := float(i) / n
			var p := a.lerp(b, t) - Vector3(0, sag * 4.0 * t * (1.0 - t), 0)
			if i > 0:
				_add_wire(prev, p, wire_mat)
			if i > 0 and i < n:
				var mi := MeshInstance3D.new()
				mi.mesh = bulb
				mi.material_override = _mats[k % _mats.size()]
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				mi.position = p - Vector3(0, 0.07, 0)
				add_child(mi)
				k += 1
			prev = p


func _add_wire(a: Vector3, b: Vector3, mat: Material) -> void:
	var seg := b - a
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.008
	cyl.bottom_radius = 0.008
	cyl.height = seg.length()
	cyl.radial_segments = 4
	cyl.rings = 1
	var mi := MeshInstance3D.new()
	mi.mesh = cyl
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = (a + b) * 0.5
	var y := seg.normalized()
	var x := y.cross(Vector3.FORWARD).normalized()
	mi.basis = Basis(x, y, x.cross(y).normalized())
	add_child(mi)


func _process(delta: float) -> void:
	_phase += delta * (0.8 + 0.9 * energy)
	for i in _mats.size():
		var tw := 0.7 + 0.3 * sin(_phase * (1.3 + 0.37 * i) + i * 1.9)
		_mats[i].emission_energy_multiplier = (1.1 + 0.6 * energy) * tw

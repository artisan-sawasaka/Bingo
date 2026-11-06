extends "res://tests/test_case.gd"
## The rotating drum (and its frame rings) must never pass through a static part.

const PrimitiveMachine = preload("res://scripts/machine/primitive_machine.gd")


func _is_under(n: Node, ancestor: Node) -> bool:
	var p := n.get_parent()
	while p != null:
		if p == ancestor:
			return true
		p = p.get_parent()
	return false


func _local_to_root(n: Node3D, root: Node3D) -> Transform3D:
	var t := n.transform
	var p := n.get_parent()
	while p != null and p != root:
		t = (p as Node3D).transform * t
		p = p.get_parent()
	return t


## Smallest distance from `center` to the mesh (box: exact via AABB; others: vertices).
func _min_distance(mi: MeshInstance3D, root: Node3D, center: Vector3) -> float:
	var xf := _local_to_root(mi, root)
	if mi.mesh is BoxMesh:
		var aabb: AABB = xf * mi.mesh.get_aabb()
		var closest := Vector3(
			clampf(center.x, aabb.position.x, aabb.end.x),
			clampf(center.y, aabb.position.y, aabb.end.y),
			clampf(center.z, aabb.position.z, aabb.end.z))
		return closest.distance_to(center)
	var best := INF
	var arrays: Array = (mi.mesh as PrimitiveMesh).get_mesh_arrays()
	for v in arrays[Mesh.ARRAY_VERTEX]:
		best = minf(best, (xf * v).distance_to(center))
	return best


func test_static_parts_clear_the_drum_sweep() -> void:
	var root: Node3D = PrimitiveMachine.build()
	var drum: Node3D = root.find_child("Drum", true, false)
	var center := PrimitiveMachine.DRUM_CENTER
	var limit := PrimitiveMachine.DRUM_SWEEP_RADIUS
	var checked := 0
	for n in root.find_children("*", "MeshInstance3D", true, false):
		var mi: MeshInstance3D = n
		if mi == drum or _is_under(mi, drum):
			continue
		var d := _min_distance(mi, root, center)
		check(d > limit + 0.02, "%s is %.3f m from the drum center (sweep %.3f)" % [mi.name, d, limit])
		checked += 1
	check(checked >= 10, "checked %d static meshes" % checked)
	root.free()


func test_exit_and_path_are_outside_the_drum() -> void:
	var root: Node3D = PrimitiveMachine.build()
	var center := PrimitiveMachine.DRUM_CENTER
	var limit := PrimitiveMachine.DRUM_SWEEP_RADIUS
	for name in ["ExitMarker", "ChutePoint_1", "ChutePoint_2", "ChutePoint_3", "TrayMarker"]:
		var m: Node3D = root.find_child(name, true, false)
		check(m != null, name + " exists")
		if m != null:
			check(m.position.distance_to(center) > limit, "%s outside the sweep" % name)
	root.free()

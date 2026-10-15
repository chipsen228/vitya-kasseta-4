extends SceneTree

const Batch = preload("res://src/static_visual_batch.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var errors: Array[String] = []
	var owner := Node3D.new()
	owner.name = "home-tonya-bed"
	owner.position = Vector3(4, 2, -3)
	owner.rotation.y = 0.42
	var mat := StandardMaterial3D.new()
	for i in 4:
		var mi := _box(mat, Vector3(i * 0.4, 0.2 * i, -0.1 * i))
		mi.rotation = Vector3(0.05 * i, 0.31 * i, 0)
		owner.add_child(mi)
	var independent := _box(mat, Vector3(0, 3, 0))
	independent.name = "heap"
	owner.add_child(independent)
	var hinge := Node3D.new()
	hinge.name = "leaf"
	hinge.position = Vector3(-1, 0.8, 0)
	var panel := _box(mat, Vector3(0.4, 0, 0))
	hinge.add_child(panel)
	owner.add_child(hinge)
	var other_mat := StandardMaterial3D.new()
	var other := _box(other_mat, Vector3(1, 0.2, 1))
	owner.add_child(other)
	var photo_refs: Array[MeshInstance3D] = []
	for i in 2:
		var photo := MeshInstance3D.new()
		photo.mesh = QuadMesh.new()
		photo.material_override = mat
		photo.position = Vector3(i * 0.2, 4, 0)
		owner.add_child(photo)
		photo_refs.append(photo)
	var geometry_before := _geometry(owner)
	var hinge_before := hinge.transform
	var panel_before := panel.transform
	var stats: Dictionary = Batch.build({String(owner.name): owner})
	var geometry_after := _geometry(owner)
	if int(stats["saved"]) != 3:
		errors.append("four equal-material pieces must become one")
	if geometry_before["triangles"] != geometry_after["triangles"]:
		errors.append("triangle count changed")
	# SurfaceTool packs positions to roughly 0.00005 m. Compare every vertex,
	# including multiplicity, within a 0.2 mm tolerance for that conversion.
	var before_bounds: AABB = geometry_before["bounds"]
	var after_bounds: AABB = geometry_after["bounds"]
	if before_bounds.position.distance_to(after_bounds.position) > 0.0002 or before_bounds.end.distance_to(after_bounds.end) > 0.0002:
		errors.append("owner-local visual bounds changed: %s -> %s" % [before_bounds, after_bounds])
	if not _same_vertices(geometry_before["vertices"], geometry_after["vertices"]):
		errors.append("transformed visual vertices changed beyond 0.2 mm")
	if owner.get_node_or_null("heap") != independent or owner.get_node_or_null("leaf") != hinge:
		errors.append("named gameplay children were replaced")
	for photo: MeshInstance3D in photo_refs:
		if not is_instance_valid(photo) or not photo.mesh is QuadMesh:
			errors.append("photo QuadMesh identity was not preserved")
	if hinge.transform != hinge_before or panel.transform != panel_before:
		errors.append("hinge origin or panel rest pose changed")
	hinge.rotation.y += 0.7
	if panel.get_parent() != hinge or panel.transform != panel_before:
		errors.append("panel no longer belongs to rotating hinge")
	get_root().add_child(owner)
	await process_frame
	owner.visible = false
	await process_frame
	for child: Node in owner.get_children():
		if child is Node3D and (child as Node3D).is_visible_in_tree():
			errors.append("owner visibility does not hide a batch")
	owner.visible = true
	await process_frame
	if not independent.is_visible_in_tree() or not other.is_visible_in_tree():
		errors.append("visibility restore lost a named/material child")
	if int(Batch.build({String(owner.name): owner})["saved"]) != 0:
		errors.append("batching is not idempotent")
	owner.free()
	if OS.get_cmdline_user_args().has("--world"):
		_check_world(errors)
	if errors.is_empty():
		print("test_static_visual_batch: PASS (vertices, AABB, triangles, visibility, independent hinge, idempotence)")
		quit(0)
	else:
		for error: String in errors:
			printerr("FAIL test_static_visual_batch: ", error)
		quit(1)


func _box(material: Material, position: Vector3) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.30, 0.25, 0.40)
	mesh.material = material
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = position
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _geometry(owner: Node3D) -> Dictionary:
	var out := {"triangles": 0, "bounds": AABB(), "vertices": []}
	_collect(owner, Transform3D.IDENTITY, out)
	return out


func _collect(node: Node3D, transform: Transform3D, out: Dictionary) -> void:
	for child: Node in node.get_children():
		if not child is Node3D:
			continue
		var local := transform * (child as Node3D).transform
		if child is MeshInstance3D:
			var mi := child as MeshInstance3D
			var faces := mi.mesh.get_faces()
			for vertex: Vector3 in faces:
				var p := local * vertex
				if (out["vertices"] as Array).is_empty():
					out["bounds"] = AABB(p, Vector3.ZERO)
				else:
					out["bounds"] = (out["bounds"] as AABB).expand(p)
				(out["vertices"] as Array).append(p)
			out["triangles"] += faces.size() / 3
		_collect(child as Node3D, local, out)


func _same_vertices(before: Array, after: Array) -> bool:
	if before.size() != after.size():
		return false
	var remaining := after.duplicate()
	for vertex: Vector3 in before:
		var match_index := -1
		for i in remaining.size():
			if vertex.distance_squared_to(remaining[i]) <= 0.0002 * 0.0002:
				match_index = i
				break
		if match_index < 0:
			print("batch missing vertex within 0.2 mm: ", vertex)
			return false
		remaining.remove_at(match_index)
	return remaining.is_empty()

func _check_world(errors: Array[String]) -> void:
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	var built := WorldBuilder.build(world, mats, col)
	var stats: Dictionary = built.get("visual_batch", {})
	print("static_visual_batch world: ", stats)
	if int(stats.get("saved", 0)) <= 0:
		errors.append("real world did not batch any audited decor")
	for id: String in ["yard-spray-barrel", "home-kitchen-bowl"]:
		var owner: Node3D = built["decor"].get(id)
		var child := "mix" if id == "yard-spray-barrel" else "heap"
		if owner == null or owner.get_node_or_null(child) == null:
			errors.append("missing real gameplay child " + id + "/" + child)
	world.free()
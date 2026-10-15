## Рендерные треугольники, материалы, риг и отмена постановочной анимации.
extends SceneTree

var errors: Array[String] = []

func _initialize() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var actors := Actors.new(world).build()
	for who: String in ["threat", "echo"]:
		actors.show(who, true)
		var rig: Dictionary = actors._rigs[who]
		var joints := actors._action_joints(rig)
		var rest: Array[Transform3D] = []
		for joint: Node3D in joints:
			rest.append(joint.transform)
		_check(actors.begin_action(who, "run"), "cannot begin run " + who)
		for t: float in [0.0, 0.155, 0.31, 0.465]:
			_check(actors.sample_action(who, "run", t), "cannot sample run")
			var chest: Node3D = rig["chest"]
			_check(chest.rotation.x < -Actors.STOOP - 0.10, "run has no forward lean")
			var before := chest.transform
			actors.walk_anim(who, 0.1, {"speed": 0, "moving": false})
			_check(chest.transform.is_equal_approx(before), "walk_anim overwrote action")
		var run_stop: Array[Transform3D] = []
		for joint: Node3D in joints:
			run_stop.append(joint.transform)
		actors.sample_action(who, "stop", 0.0)
		for i in joints.size():
			_check((joints[i] as Node3D).transform.is_equal_approx(run_stop[i]), "stop snaps running joint " + str(i))
		actors.sample_action(who, "stop", 0.28)
		_check(absf((rig["legs"][0]["hip"] as Node3D).rotation.x) < 0.001, "stop keeps running stride")
		for action: String in ["shovel_windup", "shovel_impact", "shovel"]:
			for t: float in [0.0, 0.15, 0.30, 0.65, 0.95]:
				_check(actors.sample_action(who, action, t), "cannot sample " + action)
				var prop := (actors._actions[who]["prop"] as Node3D)
				_check(prop != null and prop.visible, "missing independent shovel visual")
				if prop == null:
					continue
				_check(not _has_physics(prop), "action prop adds physics")
				for i in 2:
					var arm: Dictionary = rig["arms"][i]
					var shoulder: Node3D = arm["shoulder"]
					var elbow: Node3D = arm["elbow"]
					var wrist: Node3D = arm["wrist"]
					var actual := shoulder.transform * elbow.transform * wrist.transform * Vector3.ZERO
					var target := prop.transform * Vector3(0, 0.10 if i == 0 else -0.105, 0)
					_check(actual.distance_to(target) < 0.002, "two-hand grip separates from shaft " + action)
					var hand: MeshInstance3D = arm["hand"]
					_check(hand.mesh == actors._kit.get("grip"), "fingers do not close around shovel")
					var hand_basis := shoulder.basis * elbow.basis * wrist.basis
					_check(hand_basis.y.is_equal_approx(prop.basis.y), "hand channel does not follow shaft")
		actors.end_action(who)
		_check(not actors._actions.has(who), "action ownership persists after cleanup")
		_check((rig["chest"] as Node3D).get_node_or_null("action-shovel") == null, "shovel survived cleanup")
		for i in joints.size():
			_check((joints[i] as Node3D).transform.is_equal_approx(rest[i]), "cleanup changed original joint " + str(i))
		for arm: Dictionary in rig["arms"]:
			_check((arm["hand"] as MeshInstance3D).mesh == actors._kit["hand"], "closed hand survived cleanup")
		actors.end_action(who)
		actors.walk_anim(who, 0.1, {"speed": 1.2, "moving": true})
		_check(absf((rig["legs"][0]["hip"] as Node3D).rotation.x) > 0.005, "walk did not resume")
	_check(not actors.begin_action("echo", "unknown"), "unknown action accepted")
	for spec: Dictionary in DetailedProps.catalog():
		var key := String(spec["key"])
		var baked := ProceduralAssets.fetch(key, spec["params"])
		_check(not baked.is_empty(), "missing bake " + key)
		if baked.is_empty():
			continue
		var first := DetailedProps.generate(key, spec["params"])
		var second := DetailedProps.generate(key, spec["params"])
		var total := 0
		_check((baked["meshes"] as Array).size() <= 3, "prop exceeds three material surfaces")
		for i in (first["meshes"] as Array).size():
			var mesh: ArrayMesh = first["meshes"][i]
			_check(mesh.get_faces() == (second["meshes"][i] as ArrayMesh).get_faces(), "non-deterministic prop " + key)
			total += _geometry(mesh, key)
			_check(mesh.surface_get_material(0) != null, "missing baked material " + key)
		if key in ["prop/bench", "prop/waterBarrel"]:
			_check(total <= 200, "rural prop triangle budget " + key + ": " + str(total))
	for family: String in VehicleVisuals.SIZES:
		var asset := ProceduralAssets.fetch("vehicle/" + family)
		_check(not asset.is_empty(), "vehicle missing baked asset " + family)
		if asset.is_empty():
			continue
		var size: Vector3 = VehicleVisuals.SIZES[family]
		var box := AABB(Vector3(-size.x * 0.5, 0, -size.z * 0.5), size).grow(0.002)
		_check((asset["meshes"] as Array).size() == 4, "vehicle material batches changed")
		for mesh: ArrayMesh in asset["meshes"]:
			_geometry(mesh, "vehicle/" + family)
			_check(box.encloses(mesh.get_aabb()), "vehicle exceeds collision dimensions")
	if errors.is_empty():
		print("PASS test_model_refresh: rendered winding/materials, deterministic bakes, 2-hand grip, action ownership/cleanup, rural <=200 tris")
		quit(0)
	else:
		for error: String in errors:
			printerr("FAIL test_model_refresh: ", error)
		quit(1)


func _geometry(mesh: Mesh, key: String) -> int:
	var triangles := 0
	for surface in mesh.get_surface_count():
		var data := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = data[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = data[Mesh.ARRAY_TEX_UV]
		var indices: Variant = data[Mesh.ARRAY_INDEX]
		var indexed: bool = indices is PackedInt32Array and not indices.is_empty()
		var count: int = indices.size() if indexed else vertices.size()
		_check(count % 3 == 0, "incomplete triangles " + key)
		for t in range(0, count - 2, 3):
			var a: int = int(indices[t]) if indexed else t
			var b: int = int(indices[t + 1]) if indexed else t + 1
			var c: int = int(indices[t + 2]) if indexed else t + 2
			var cross := (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a])
			if cross.length_squared() < 1e-14 or cross.dot(normals[a]) >= -1e-10:
				_check(false, "degenerate/reversed triangle " + key + ": " + str(triangles))
				return triangles
			_check(vertices[a].is_finite() and uvs[a].is_finite(), "non-finite geometry " + key)
			triangles += 1
	return triangles


func _has_physics(node: Node) -> bool:
	if node is CollisionObject3D:
		return true
	for child: Node in node.get_children():
		if _has_physics(child):
			return true
	return false


func _check(ok: bool, message: String) -> void:
	if not ok and not errors.has(message):
		errors.append(message)

# Синтетические ресурсы живут в памяти; эталон OFF снимается в том же мире.
extends SceneTree

var fails := 0
var started := false


func _process(_dt: float) -> bool:
	if not started:
		started = true
		_run()
	return false


func _check(ok: bool, message: String) -> void:
	if not ok:
		fails += 1
		printerr("test_skin_layer: " + message)


func _run() -> void:
	# Production assets were archived; explicit in-memory fixtures remain supported.
	SkinLayer.current = null
	var live_skin := SkinLayer.load_all()
	_check(not live_skin.enabled, "внешний скин должен быть отключён в активной игре")
	_check(live_skin.map.is_empty() and live_skin.packed_cache.is_empty(), "активная игра загрузила архивные HQ-ресурсы")
	SkinLayer.current = null
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	world.name = "SkinTestWorld"
	root.add_child(world)
	var built := WorldBuilder.build(world, mats, col)
	var props := Props.new(mats)
	var pdata := GameData.props()
	props.load_models(pdata["PROPS"])
	props.build(world, pdata["PROPS"], col)
	var actors := Actors.new(world, mats).build()
	var base := _snapshot(world)
	var collision := _collision(col)
	var parity: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://parity/world_boxes.json"))
	_check(col.box_count(CollisionWorld.SET_STATIC) == int(parity["collideCount"]), "collideCount не совпадает с паритетом")
	_check(col.box_count(CollisionWorld.SET_BLOCKERS) == int(parity["blockerCount"]), "blockerCount не совпадает с паритетом")
	_check(col.box_count(CollisionWorld.SET_PROPS) == int(parity["propColliderCount"]), "propColliderCount не совпадает с паритетом")
	_check(int(built["triangles"]) == 3885, "3885 collision triangles")
	var disabled := SkinLayer.from_config({"enabled": false, "assets": {"props/zhiguli": {"path": "memory:car"}}})
	disabled.apply(world, props, mats)
	_check(_snapshot(world) == base, "enabled:false изменил базу")
	print("test_skin_layer OFF: nodes=%s meshes=%s surfaces=%s triangles=%s materials=%s transform_hash=%s" % [base["nodes"], base["meshes"], base["surfaces"], base["triangles"], base["materials"].size(), base["transforms"]])

	var prop := props.get_prop("car")
	_check(prop != null, "нет исходного car")
	if prop == null:
		props.dispose()
		world.free()
		quit(1)
		return
	var prop_box := PropsSkin.local_aabb(prop)
	var building := _holder("synthetic-building", Vector3(3, 4, 5), world)
	building.set_meta("skin_key", "buildings/test/house")
	building.set_meta("skin_owner", NodePath("."))
	var interior := _holder("synthetic-interior", Vector3(1, 2, 1), world)
	interior.set_meta("skin_key", "interiors/test/table")
	var scatter := _scatter(world)
	var scatter_buffer := scatter.multimesh.buffer.duplicate()
	var scatter_count := scatter.multimesh.instance_count
	var fig := actors.figure("echo")
	var actor_box := PropsSkin.local_aabb(fig)
	var image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
	image.fill(Color(0.31, 0.42, 0.25))
	var texture := ImageTexture.create_from_image(image)
	var ground_key := _ground_key(mats)
	var assets := {
		"props/zhiguli": {"path": "memory:car"},
		"buildings/test/house": {"path": "memory:house", "ry": PI * 0.5},
		"interiors/test/table": {"path": "memory:table"},
		"scatter/test-tree": {"path": "memory:tree"},
		"actors/echo": {"path": "memory:actor", "bones": {
			"body": "Hips", "legs/0/hip": "LeftUpLeg", "arms/1/elbow": "RightForeArm"}},
		"ground/" + ground_key: {"albedo": texture, "normal": texture, "roughness": 0.73},
	}
	var cache := {
		"memory:car": _packed(prop_box.size),
		"memory:house": _packed(Vector3(5, 4, 3)),
		"memory:table": _packed(Vector3(1, 2, 1)),
		"memory:tree": _packed(Vector3(1, 3, 1)),
		"memory:actor": _packed(actor_box.size, true),
	}
	var skin := SkinLayer.from_config({"enabled": true, "assets": assets}, cache)
	SkinLayer.current = skin
	var prop_name := prop.name
	var figure_name := fig.name
	skin.apply(world, props, mats)
	actors._skin_figure("echo", fig)
	_check(skin.skipped.is_empty(), "валидные ассеты пропущены: " + skin.report())
	_check(prop.name == prop_name and fig.name == figure_name, "переименован владелец")
	_check(_collision(col) == collision, "скин изменил коллизию/блокеры")
	_check(scatter.multimesh.instance_count == scatter_count, "scatter instance_count")
	_check(scatter.multimesh.buffer == scatter_buffer, "scatter instance transforms/colors/custom data")
	_check(scatter.multimesh.mesh is ArrayMesh, "scatter не получил ArrayMesh")
	_fit_check(prop, prop_box)
	_fit_check(building, AABB(Vector3(-1.5, 0, -2.5), Vector3(3, 4, 5)))
	_fit_check(interior, AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 2, 1)))
	_fit_check(fig, actor_box)
	_check(_close_box(scatter.multimesh.mesh.get_aabb(), AABB(Vector3(-0.5, 0, -0.5), Vector3(1, 3, 1))), "scatter AABB ±2%")
	var skinned_car := prop.get_node_or_null("skin") as Node3D
	if skinned_car != null:
		var mesh: MeshInstance3D = PropsSkin._meshes(skinned_car)[0]
		_check(is_equal_approx(mesh.visibility_range_end, Props.VIS_END), "не перенесена дальность 48 м")
		_check(mesh.get_active_material(0) is ShaderMaterial, "материал GLB не прошёл через PSX")
	var driver := fig.get_node_or_null("skin-bone-driver") as Actors.SkinBoneDriver
	_check(driver != null, "нет драйвера Skeleton3D")
	if driver != null:
		for binding: Dictionary in driver.bindings:
			var joint: Node3D = binding["joint"]
			joint.rotation = Vector3(0.23, -0.31, 0.17)
		driver.sync_pose()
		driver.sync_pose()
		_check_bones(driver)
		actors.walk_anim("echo", 0.12, {"speed": 1.1})
		driver.sync_pose()
		_check_bones(driver)
		var body: Node3D = driver.bindings[0]["joint"]
		body.position.y += 0.12
		driver.sync_pose()
		var binding: Dictionary = driver.bindings[0]
		var expected: Vector3 = binding["rest_position"] + binding["position_basis"] * (body.position - Vector3(binding["source_position"]))
		_check(driver.skeleton.get_bone_pose_position(int(binding["bone"])).is_equal_approx(expected), "драйвер потерял bob таза")

	var extra := _holder("cached-car", prop_box.size, world)
	var extra_model := skin.apply_node("props/zhiguli", extra)
	if extra_model != null and skinned_car != null:
		_check(PropsSkin._meshes(extra_model)[0].mesh == PropsSkin._meshes(skinned_car)[0].mesh, "PackedScene не переиспользует mesh")
		_check(PropsSkin._meshes(extra_model)[0].get_active_material(0) == PropsSkin._meshes(skinned_car)[0].get_active_material(0), "нет кэша материалов")
	var applied_before := skin.applied.size()
	skin.apply(world, props, mats)
	_check(skin.applied.size() == applied_before, "повторное apply дублирует скин")
	_test_rejection(world)
	_test_batch(world)
	_test_tree_batch(world)
	_test_anonymous_props(world, props)
	_test_real_batch(world)
	_check(_collision(col) == collision, "коллизия изменилась после всех категорий")
	print(skin.report())
	SkinLayer.current = null
	props.dispose()
	world.free()
	if fails == 0:
		print("test_skin_layer: PASS")
	else:
		printerr("test_skin_layer: FAIL (%d)" % fails)
	quit(0 if fails == 0 else 1)


func _ground_key(mats: Materials) -> String:
	for key: String in ["grass", "ground", "dirt", "soil"]:
		if mats.get_mat(key) != null:
			return key
	return "grass"


func _check_bones(driver: Actors.SkinBoneDriver) -> void:
	for binding: Dictionary in driver.bindings:
		var joint: Node3D = binding["joint"]
		var expected: Quaternion = (Quaternion(binding["rest_rotation"]) * joint.quaternion).normalized()
		var got := driver.skeleton.get_bone_pose_rotation(int(binding["bone"]))
		_check(absf(expected.dot(got)) > 0.99999, "углы конечности не переданы кости")


func _test_rejection(world: Node3D) -> void:
	var holder := _holder("rejection", Vector3.ONE, world)
	var bad_scene := _packed(Vector3.ONE)
	var raw := bad_scene.instantiate()
	var collision := StaticBody3D.new()
	raw.add_child(collision)
	collision.owner = raw
	bad_scene.pack(raw)
	raw.free()
	var resources := {"memory:cube": _packed(Vector3.ONE), "memory:collision": bad_scene}
	for description: Dictionary in [
		{"path": "res://missing-skin.glb"},
		{"path": "memory:cube", "offset": [0, 3, 0]},
		{"path": "memory:cube", "fit": "wrong"},
		{"path": "memory:cube", "fit": "none", "ry": 0.5},
		{"path": "memory:collision"},
	]:
		var skin := SkinLayer.from_config({"assets": {"props/reject": description}}, resources)
		var before := _snapshot(holder)
		_check(skin.apply_node("props/reject", holder) == null, "невалидный ассет принят")
		_check(_snapshot(holder) == before, "отказ изменил исходную сцену")
		_check(skin.skipped.has("props/reject"), "отказ не попал в report")
	holder.set_meta("skin_unavailable_reason", "динамический дочерний узел")
	var protected := SkinLayer.from_config({"assets": {"interiors/test/protected": {"path": "memory:cube"}}}, resources)
	var unchanged := _snapshot(holder)
	_check(protected.apply_node("interiors/test/protected", holder) == null, "динамический owner принят")
	_check(_snapshot(holder) == unchanged, "защита динамического owner изменила геометрию")
	holder.remove_meta("skin_unavailable_reason")
	var bad_bones := SkinLayer.from_config({"assets": {"actors/reject": {
		"path": "memory:actor", "bones": {"body": "MissingBone"}}}},
		{"memory:actor": _packed(Vector3.ONE, true)})
	var before := _snapshot(holder)
	_check(bad_bones.apply_actor("reject", holder, {"body": holder}) == null, "невалидная кость принята")
	_check(_snapshot(holder) == before, "ошибка bones скрыла исходную фигуру")


func _test_batch(world: Node3D) -> void:
	var holder := Node3D.new()
	holder.name = "batch-fixture"
	world.add_child(holder)
	var source := MeshInstance3D.new()
	source.name = "merged-original"
	var left := _box(Vector3(2, 2, 2))
	var st := SurfaceTool.new()
	st.append_from(left, 0, Transform3D.IDENTITY)
	st.append_from(left, 0, Transform3D(Basis.IDENTITY, Vector3(5, 0, 0)))
	source.mesh = st.commit()
	holder.add_child(source)
	var count: int = left.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	source.set_meta("skin_parts", {"buildings/test/left": [Vector2i(0, count)]})
	var original := source.mesh
	var neighbor_arrays := source.mesh.surface_get_arrays(0)
	var skin := SkinLayer.from_config({"assets": {"buildings/test/left": {"path": "memory:left"}}}, {"memory:left": _packed(Vector3(2, 2, 2))})
	skin.apply_world(holder)
	_check(skin.skipped.is_empty(), "batch отклонён: " + skin.report())
	_check(source.mesh == original and source.name == "merged-original", "batch потерял исходный узел/mesh")
	var residual := source.get_node_or_null("skin_residual") as MeshInstance3D
	_check(residual != null and residual.mesh != null, "соседние треугольники удалены")
	if residual != null and residual.mesh != null:
		var after: PackedVector3Array = residual.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var before: PackedVector3Array = neighbor_arrays[Mesh.ARRAY_VERTEX]
		_check(after == before.slice(count), "batch изменил соседние вершины")


func _test_tree_batch(world: Node3D) -> void:
	var holder := Node3D.new()
	holder.name = "tree-batch-fixture"
	world.add_child(holder)
	var original := _box(Vector3(2, 3, 1))
	var transforms := [
		Transform3D(Basis.from_euler(Vector3(0.13, 0.7, -0.08)).scaled(Vector3(1.1, 1.6, 0.9)), Vector3(3, 0, 2)),
		Transform3D(Basis.from_euler(Vector3(-0.09, -0.3, 0.06)).scaled(Vector3(0.8, 1.3, 1.2)), Vector3(-4, 1, -2)),
	]
	var surface := SurfaceTool.new()
	for transform: Transform3D in transforms:
		surface.append_from(original, 0, transform)
	var source := MeshInstance3D.new()
	source.name = "original-trees"
	source.mesh = surface.commit()
	holder.add_child(source)
	var count: int = original.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	var tree_parts: Dictionary = {}
	for i in transforms.size():
		tree_parts["fixture:%d" % i] = {"key": "scatter/fixture", "transform": transforms[i],
			"ranges": [Vector2i(count * i, count)]}
	source.set_meta("skin_tree_parts", tree_parts)
	var skin := SkinLayer.from_config({"assets": {"scatter/fixture": {"path": "memory:tree"}}},
		{"memory:tree": _packed(Vector3(2, 3, 1))})
	skin.apply_world(holder)
	_check(skin.skipped.is_empty() and skin.applied.size() == 2, "батч деревьев: " + skin.report())
	var models: Array = []
	for child: Node in holder.get_children():
		if child.has_meta("skin_asset"):
			models.append(child)
	_check(models.size() == 2, "потерян экземпляр дерева")
	for i in models.size():
		var model: Node3D = models[i]
		_check(model.transform.is_equal_approx(transforms[i]), "потерян полный transform дерева")
	_check(source.mesh != null and source.layers == 0, "удалён исходный tree mesh")


func _test_anonymous_props(world: Node3D, props: Props) -> void:
	var holders: Array[Node3D] = []
	for i in 2:
		var node := props.spawn({"m": "farm-bigbarn", "at": [200 + i * 12, 0, 200], "col": false})
		_check(node != null, "fixture реквизита без id")
		if node != null:
			holders.append(node)
	if holders.size() != 2:
		return
	var box := PropsSkin.local_aabb(holders[0])
	var skin := SkinLayer.from_config({"assets": {"props/farm-bigbarn": {"path": "memory:barn"}}},
		{"memory:barn": _packed(box.size)})
	skin.apply(world, props)
	for holder: Node3D in holders:
		_fit_check(holder, box)
	var count := skin.applied.size()
	skin.apply(world, props)
	_check(skin.applied.size() == count, "повторная подмена no-id реквизита")


func _test_real_batch(world: Node3D) -> void:
	var keys: Dictionary = {}
	for node: Node in SkinLayer._nodes(world):
		if node is MeshInstance3D and node.has_meta("skin_parts"):
			for key: String in node.get_meta("skin_parts"):
				if not keys.has(key):
					keys[key] = []
				keys[key].append(node)
	if keys.is_empty():
		_check(false, "у реального мира нет skin_parts построек")
		return
	var key: String = keys.keys()[0]
	var box := AABB()
	var first := true
	for node: MeshInstance3D in keys[key]:
		var part := SkinLayer._select_vertices(node.mesh, SkinLayer._range_indices(node.get_meta("skin_parts")[key]))
		_check(part != null, "реальный диапазон не соответствует mesh")
		if part == null:
			return
		var local: AABB = PropsSkin._rel(world, node) * part.get_aabb()
		box = local if first else box.merge(local)
		first = false
	var skin := SkinLayer.from_config({"assets": {key: {"path": "memory:building"}}}, {"memory:building": _packed(box.size)})
	skin.apply_world(world)
	_check(skin.skipped.is_empty() and skin.applied.size() == 1, "реальная постройка не заменена: " + skin.report())
	print("test_skin_layer real building: ", key, ", keys=", keys.size())


func _fit_check(holder: Node3D, want: AABB) -> void:
	var model := holder.get_node_or_null("skin") as Node3D
	_check(model != null, "нет skin у " + String(holder.name))
	if model != null:
		_check(_close_box(model.transform * PropsSkin.local_aabb(model), want), "AABB ±2% у " + String(holder.name))


func _close_box(got: AABB, want: AABB) -> bool:
	for axis in 3:
		var tol := maxf(0.00001, want.size[axis] * SkinLayer.FIT_TOL)
		if absf(got.size[axis] - want.size[axis]) > tol or absf(got.position[axis] - want.position[axis]) > tol:
			return false
	return true


func _box(size: Vector3) -> ArrayMesh:
	var box := BoxMesh.new()
	box.size = size
	var st := SurfaceTool.new()
	st.append_from(box, 0, Transform3D(Basis.IDENTITY, Vector3(0, size.y * 0.5, 0)))
	st.deindex()
	var mesh := st.commit()
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(0.42, 0.51, 0.35)
	mesh.surface_set_material(0, material)
	return mesh


func _holder(label: String, size: Vector3, parent: Node3D) -> Node3D:
	var holder := Node3D.new()
	holder.name = label
	parent.add_child(holder)
	var mi := MeshInstance3D.new()
	mi.name = "original"
	mi.mesh = _box(size)
	mi.visibility_range_end = 56.0
	holder.add_child(mi)
	return holder


func _packed(size: Vector3, skeleton := false) -> PackedScene:
	var model := Node3D.new()
	var mi := MeshInstance3D.new()
	mi.mesh = _box(size)
	model.add_child(mi)
	mi.owner = model
	if skeleton:
		var rig := Skeleton3D.new()
		model.add_child(rig)
		rig.owner = model
		for bone: String in ["Hips", "LeftUpLeg", "RightForeArm"]:
			rig.add_bone(bone)
			var index := rig.get_bone_count() - 1
			rig.set_bone_rest(index, Transform3D(Basis.from_euler(Vector3(0.07, 0.13, -0.09)), Vector3.ZERO))
	var scene := PackedScene.new()
	_check(scene.pack(model) == OK, "PackedScene.pack")
	model.free()
	return scene


func _scatter(parent: Node3D) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.use_custom_data = true
	mm.mesh = _box(Vector3(1, 3, 1))
	mm.instance_count = 3
	for i in 3:
		mm.set_instance_transform(i, Transform3D(Basis.from_euler(Vector3(0, i * 0.31, 0)), Vector3(i * 3, 0, 4)))
		mm.set_instance_color(i, Color(0.2 * i, 0.6, 0.7))
		mm.set_instance_custom_data(i, Color(0.1, i * 0.2, 0.3))
	var node := MultiMeshInstance3D.new()
	node.name = "synthetic-scatter"
	node.multimesh = mm
	node.visibility_range_end = 45.0
	node.set_meta("skin_key", "scatter/test-tree")
	parent.add_child(node)
	return node


func _snapshot(world: Node3D) -> Dictionary:
	var result := {"nodes": 0, "meshes": 0, "surfaces": 0, "triangles": 0, "materials": [], "transforms": []}
	var materials: Dictionary = {}
	var transforms: Array = []
	for node: Node in SkinLayer._nodes(world):
		result["nodes"] += 1
		if node is Node3D:
			transforms.append([String(world.get_path_to(node)), node.transform, node.visible])
		var mesh: Mesh = null
		var instances := 1
		if node is MeshInstance3D:
			mesh = node.mesh
		elif node is MultiMeshInstance3D and node.multimesh != null:
			mesh = node.multimesh.mesh
			instances = node.multimesh.instance_count
			transforms.append(node.multimesh.buffer)
		if mesh == null:
			continue
		result["meshes"] += 1
		result["surfaces"] += mesh.get_surface_count()
		transforms.append([node.layers, mesh.get_instance_id()])
		for surface in mesh.get_surface_count():
			var arrays := mesh.surface_get_arrays(surface)
			var count: int = arrays[Mesh.ARRAY_VERTEX].size()
			if arrays[Mesh.ARRAY_INDEX] != null and not arrays[Mesh.ARRAY_INDEX].is_empty():
				count = arrays[Mesh.ARRAY_INDEX].size()
			result["triangles"] += (count / 3) * instances
			var material := node.get_active_material(surface) as Material if node is MeshInstance3D else mesh.surface_get_material(surface)
			if material != null:
				var properties: Dictionary = {}
				for property: Dictionary in material.get_property_list():
					if int(property["usage"]) & PROPERTY_USAGE_STORAGE:
						properties[property["name"]] = material.get(property["name"])
				materials[material.get_instance_id()] = var_to_str(properties)
	result["materials"] = materials.keys()
	result["material_hash"] = var_to_str(materials).sha256_text()
	result["transforms"] = var_to_str(transforms).sha256_text()
	return result


func _collision(col: CollisionWorld) -> String:
	var values: Array = []
	for set_id in CollisionWorld.SET_COUNT:
		values.append(col.box_count(set_id))
		for i in col.box_count(set_id):
			values.append(col.box_aabb_d(set_id, i))
	return var_to_str(values).sha256_text()

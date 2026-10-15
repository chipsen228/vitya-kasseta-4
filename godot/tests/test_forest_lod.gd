extends SceneTree
const INPUT_FOREST := preload("res://src/forest_lod_mesh.gd")
var failures: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _check(ok: bool,message: String) -> void:
	if not ok: failures.append(message)

func _input_mesh(positions: Dictionary, triangles: int, lift: float) -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	for id: String in positions:
		for triangle in triangles:
			for vertex: Vector3 in [Vector3.ZERO,Vector3(.4,0,0),Vector3(0,.5,0)]:
				vertices.append(positions[id]+vertex+Vector3(0,lift,float(triangle)*.05))
				normals.append(Vector3.BACK)
				uv.append(Vector2(float(triangle),vertex.y))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return mesh

func _input_fixture_geometry(tree: INPUT_FOREST) -> void:
	var expected := {Mesh.ARRAY_VERTEX:PackedVector3Array(),Mesh.ARRAY_NORMAL:PackedVector3Array(),Mesh.ARRAY_TEX_UV:PackedVector2Array()}
	for id: String in tree.anchors:
		var arrays: Array = tree._background_arrays if tree.background_ids.has(id) else tree._far_arrays if tree.far_ids.has(id) else tree._near_arrays
		var parts: Dictionary = tree.background_ranges if tree.background_ids.has(id) else tree.far_ranges if tree.far_ids.has(id) else tree.near_ranges
		for span: Vector2i in parts[id]:
			for channel: int in expected:
				var values: Variant = expected[channel]
				# Independent element-by-element reference for Packed slice/append.
				for index in range(span.x,span.x+span.y): values.append(arrays[channel][index])
				expected[channel] = values
	var actual := tree.mesh.surface_get_arrays(0)
	for channel: int in expected: _check(actual[channel] == expected[channel],"same-input cache changed selected vertex/NORMAL/UV buffer")

func _same_inputs_fixture() -> void:
	var positions := {"a":Vector3.ZERO,"b":Vector3(30,0,0),"c":Vector3(60,0,0)}
	var high := {"a":[Vector2i(0,6)],"b":[Vector2i(6,6)],"c":[Vector2i(12,6)]}
	var low := {"a":[Vector2i(0,3)],"b":[Vector2i(3,3)],"c":[Vector2i(6,3)]}
	var tree := INPUT_FOREST.new()
	root.add_child(tree)
	tree.set_process(false)
	var near := _input_mesh(positions,2,0)
	tree.mesh = near
	var far := _input_mesh(positions,1,.1)
	var background := _input_mesh(positions,1,.2)
	tree.configure(far,positions,high,low,background,low)
	var camera := Vector3.ZERO
	tree.update_for_camera(camera)
	_check(not tree.far_ids.has("a") and tree.far_ids.has("b") and tree.background_ids.has("c"),"initial same-input fixture policy wrong")
	_input_fixture_geometry(tree)
	var evaluations: int = tree._camera_evaluations
	var mesh_id := tree.mesh.get_instance_id()
	var cache_order := tree._mixed_order.duplicate()
	for repeat in 20: tree.update_for_camera(camera)
	_check(tree._camera_evaluations == evaluations and tree._same_input_hits == 20,"identical inputs still recompute anchors")
	_check(tree.mesh.get_instance_id() == mesh_id and tree._mixed_order == cache_order,"identical inputs touched geometry/cache eviction")
	camera.x += .000001
	tree.update_for_camera(camera)
	_check(tree._camera_evaluations == evaluations+1,"tiny exact camera movement was suppressed")
	evaluations = tree._camera_evaluations
	tree.position.x += .000001
	tree.update_for_camera(camera)
	_check(tree._camera_evaluations == evaluations+1,"tiny exact global transform change was suppressed")
	evaluations = tree._camera_evaluations
	tree.anchors["b"] += Vector3(40,0,0)
	tree.update_for_camera(camera)
	_check(tree._camera_evaluations == evaluations+1 and tree.background_ids.has("b"),"direct public anchor edit was suppressed")
	evaluations = tree._camera_evaluations
	tree.far_ids.clear()
	tree.update_for_camera(camera)
	_check(tree._camera_evaluations == evaluations+1 and tree.far_ids.has("b"),"direct public far_ids edit was suppressed")
	evaluations = tree._camera_evaluations
	tree.background_ids["a"] = true
	tree.update_for_camera(camera)
	_check(tree._camera_evaluations == evaluations+1 and not tree.background_ids.has("a"),"direct public background_ids edit was suppressed")
	_input_fixture_geometry(tree)
	evaluations = tree._camera_evaluations
	tree.select_far(false)
	_check(not tree._input_cached,"explicit select_far did not invalidate camera inputs")
	tree.update_for_camera(camera)
	_check(tree._camera_evaluations == evaluations+1 and tree.background_ids.has("b"),"same camera after select_far did not restore per-tree policy")
	evaluations = tree._camera_evaluations
	tree.mesh = near
	tree.configure(far,positions,high,low,background,low)
	tree.update_for_camera(camera)
	_check(tree._camera_evaluations == evaluations+1 and not tree.background_ids.has("b"),"same camera after configure reused old anchors/IDs")
	tree.transform = Transform3D.IDENTITY
	# Exact pre-existing entry/exit boundaries and hysteresis; no movement epsilon.
	for distance: float in [21.0,21.00001,19.0,18.99999]:
		tree.update_for_camera(Vector3(distance,0,0))
		_check(tree.far_ids.has("a") == (distance == 21.00001 or distance == 19.0),"far threshold/hysteresis changed at "+str(distance))
	for distance: float in [36.0,36.00001,34.0,33.99999]:
		tree.update_for_camera(Vector3(distance,0,0))
		_check(tree.background_ids.has("a") == (distance == 36.00001 or distance == 34.0),"background threshold/hysteresis changed at "+str(distance))
	_input_fixture_geometry(tree)
	tree.free()

func _packed_ranges_fixture() -> void:
	var positions := {"a":Vector3.ZERO,"b":Vector3(30,0,0),"c":Vector3(60,0,0)}
	# Split and interleave the high ranges so a contiguous copy cannot pass.
	var high := {"a":[Vector2i(0,3),Vector2i(9,3)],"b":[Vector2i(3,3),Vector2i(12,3)],"c":[Vector2i(6,3),Vector2i(15,3)]}
	var low := {"a":[Vector2i(0,3)],"b":[Vector2i(3,3)],"c":[Vector2i(6,3)]}
	var tree := INPUT_FOREST.new()
	root.add_child(tree)
	tree.set_process(false)
	tree.mesh = _input_mesh(positions,2,0)
	tree.configure(_input_mesh(positions,1,.1),positions,high,low,_input_mesh(positions,1,.2),low)
	for mask in 27:
		var levels: Array[int] = [mask%3,(mask/3)%3,mask/9]
		var far: Dictionary = {}
		var background: Dictionary = {}
		for index in 3:
			var id: String = positions.keys()[index]
			if levels[index]>0: far[id]=true
			if levels[index]==2: background[id]=true
		tree._select_geometry(far,background)
		if mask==0: _check(tree.mesh==tree.near_mesh,"all-near selection rebuilt geometry")
		elif mask==13: _check(tree.mesh==tree.far_mesh,"all-far selection rebuilt geometry")
		elif mask==26: _check(tree.mesh==tree.background_mesh,"all-background selection rebuilt geometry")
		else: _input_fixture_geometry(tree)
		_check(tree.mesh.get_surface_count()==1 and tree.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]==null,"Packed assembly changed surface/index policy")
		_check(tree._mixed_cache.size()<=2,"Packed assembly expanded mixed cache")
		var builds: int = tree._mixed_builds
		var total: int = tree._total_build_usec
		var selected_mesh: ArrayMesh = tree.mesh
		tree._select_geometry(far,background)
		_check(tree._mixed_builds==builds and tree._total_build_usec==total and tree.mesh==selected_mesh,"cached selection rebuilt mesh or changed diagnostics")
	_check(tree._mixed_builds==24,"mixed build counter includes cache hits or uniform selections")
	_check(tree._total_build_usec>=tree._max_build_usec and tree._max_build_usec>=tree._last_build_usec,"mixed timing counters inconsistent")
	var original := tree.near_mesh.surface_get_arrays(0)
	var subset := INPUT_FOREST._subset(tree.near_mesh,high,{"c":true,"a":true})
	var actual: Array = (subset["mesh"] as ArrayMesh).surface_get_arrays(0)
	# Reordered IDs and fragmented ranges must preserve exact element order.
	var expected_indices := [6,7,8,15,16,17,0,1,2,9,10,11]
	for channel: int in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL,Mesh.ARRAY_TEX_UV]:
		_check(actual[channel].size()==expected_indices.size(),"subset Packed channel size changed")
		for index in expected_indices.size():
			_check(actual[channel][index]==original[channel][expected_indices[index]],"subset Packed element/order changed")
	_check(subset["ranges"]=={"c":[Vector2i(0,6)],"a":[Vector2i(6,6)]},"subset range remapping changed")
	tree.free()

func _run() -> void:
	_same_inputs_fixture()
	_packed_ranges_fixture()
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	root.add_child(world)
	WorldBuilder.build(world,mats,col)
	await process_frame
	var candidate: ForestLodMesh
	var near_count := 0
	var far_count := 0
	var chunks := 0
	for node: Node in world.get_children():
		if not node is ForestLodMesh: continue
		var tree := node as ForestLodMesh
		chunks += 1
		near_count += tree.near_mesh.get_faces().size()/3
		far_count += tree.far_mesh.get_faces().size()/3
		_check(tree.near_mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX] == null,"near перестал быть неиндексированным")
		_check(tree.mesh == tree.near_mesh,"не сохранена ближняя геометрия")
		var anchor: Vector3 = tree.global_transform*tree.anchors.values()[0]
		tree.update_for_camera(anchor+Vector3(5,0,0))
		_check(not tree.far_ids.has(tree.anchors.keys()[0]),"ближнее дерево на5м не high")
		var expected_vertices := 0
		for id: String in tree.anchors:
			var ranges: Dictionary=tree.background_ranges if tree.background_ids.has(id) else tree.far_ranges if tree.far_ids.has(id) else tree.near_ranges
			for span: Vector2i in ranges[id]: expected_vertices+=span.y
		_check(tree.mesh.get_faces().size()==expected_vertices,"mixed mesh не совпадает с фактической high/low выборкой")
		var far_position := tree.global_transform*tree.near_mesh.get_aabb().end+Vector3(30,0,30)
		tree.update_for_camera(far_position)
		_check(tree.far_active and tree.mesh.get_faces().size()<=tree.far_mesh.get_faces().size(),"дальний чанк не перешёл на low/background")
		tree.update_for_camera(anchor)
		tree.select_far(false)
		if candidate == null and tree.near_ranges.size()>2:
			candidate=tree
	_check(chunks>0 and far_count<near_count,"лес не получил более дешёвую фактическую сетку")
	for camera_position: Vector3 in [Vector3(36.8,1.68,-38.3),Vector3(11,1.68,-12)]:
		var previous_policy := 0
		var per_tree_policy := 0
		for node: Node in world.get_children():
			if not node is ForestLodMesh: continue
			var tree := node as ForestLodMesh
			tree.select_far(false)
			tree.update_for_camera(camera_position)
			previous_policy += tree.far_mesh.get_faces().size()/3 if tree.far_active else tree.near_mesh.get_faces().size()/3
			per_tree_policy += tree.mesh.get_faces().size()/3
			_check(tree._mixed_cache.size()<=ForestLodMesh.MIXED_CACHE_LIMIT,"не ограничен кэш смешанного чанка")
		print("forest camera ",camera_position," old_chunk_policy=",previous_policy," per_tree_policy=",per_tree_policy," saved=",previous_policy-per_tree_policy)
	_check(candidate!=null,"нет реального составного чанка для SkinLayer-проверки")
	if candidate!=null:
		var id: String=candidate.near_ranges.keys()[0]
		var selected := SkinLayer._select_vertices(candidate.near_mesh,SkinLayer._range_indices(candidate.near_ranges[id]))
		var target_box := selected.get_aabb()
		var fixture := Node3D.new()
		var box := MeshInstance3D.new()
		var box_mesh := BoxMesh.new()
		box_mesh.size=target_box.size
		box.mesh=box_mesh
		fixture.add_child(box)
		box.owner=fixture
		var packed := PackedScene.new()
		packed.pack(fixture)
		fixture.free()
		var skin := SkinLayer.from_config({"assets":{"scatter/lod-fixture":{"path":"memory:forest-lod"}}},
			{"memory:forest-lod":packed})
		var removed := 0
		for span: Vector2i in candidate.far_ranges[id]: removed+=span.y
		var before := candidate.far_mesh.get_faces().size()
		var background_removed := 0
		for span: Vector2i in candidate.background_ranges[id]: background_removed+=span.y
		var background_before := candidate.background_mesh.get_faces().size()
		candidate.select_far(true)
		var applied := skin._apply_batch("scatter/lod-fixture",world,[candidate],
			{candidate:candidate.near_ranges[id]},"lod-fixture")
		_check(applied,"SkinLayer не смог выбрать high-range после far: "+skin.report())
		var residual := candidate.get_node_or_null("skin_residual") as ForestLodMesh
		_check(residual!=null and residual.far_mesh!=null,"SkinLayer потерял готовый low остатка")
		if residual!=null and residual.far_mesh!=null:
			_check(residual.far_mesh.get_faces().size()==before-removed,"low остатка возвращает заменённое дерево")
			_check(not residual.anchors.has(id),"LOD сохранил якорь удалённого дерева")
			_check(residual.background_mesh.get_faces().size()==background_before-background_removed,"background остатка возвращает заменённое дерево")
			residual.update_for_camera(Vector3(1000,0,1000))
			_check(residual.mesh==residual.background_mesh and not residual.background_ids.has(id),"остаток не переключает дальнюю геометрию без удалённого дерева")
			residual.select_far(true)
			_check(residual.mesh==residual.far_mesh,"остаток не переключает фактическую геометрию")
			residual.select_far(false)
			_check(residual.mesh==residual.near_mesh,"остаток не возвращает high")
	print("forest LOD actual chunks=",chunks," high_triangles=",near_count," low_triangles=",far_count)
	for message: String in failures: printerr("test_forest_lod: ",message)
	print("test_forest_lod: ","PASS" if failures.is_empty() else "FAIL")
	world.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)

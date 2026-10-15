## Проверяет bake LOD, реальный camera-distance switch и восстановление near.
extends SceneTree

var errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.current = true
	var mats := Materials.new()
	mats.load_all()
	for family: String in VehicleVisuals.SIZES:
		var asset := ProceduralAssets.fetch("vehicle/"+family)
		var holder := Node3D.new()
		root.add_child(holder)
		VehicleVisuals.build(mats,{"family":family},holder)
		_check_asset(asset,"vehicle/"+family)
		_check_switch(holder,camera,4,16.0)
		holder.free()
	for spec: Dictionary in DetailedProps.catalog():
		var kind := String(spec["key"]).trim_prefix("prop/")
		if kind not in ["woodpile","jarShelf"]:
			continue
		var asset := ProceduralAssets.fetch(spec["key"],spec["params"])
		_check_asset(asset,spec["key"])
		var def: Dictionary = spec["params"].duplicate()
		def["make"] = kind
		var holder := Node3D.new()
		root.add_child(holder)
		DetailedProps.build(mats,def,holder)
		_check_switch(holder,camera,(asset["meshes"] as Array).size(),14.0 if kind=="woodpile" else 10.0)
		holder.free()
	camera.free()
	if errors.is_empty():
		print("PASS test_model_lod: 2 far surfaces, bounds/axes, camera switching/hysteresis, exact near restoration")
		quit(0)
	else:
		for error: String in errors:
			printerr("FAIL test_model_lod: ",error)
		quit(1)


func _check_asset(asset: Dictionary,key: String) -> void:
	_check(not asset.is_empty(),"missing asset "+key)
	if asset.is_empty(): return
	var far: Array = asset.get("lod_meshes",[])
	_check(far.size()==2,"far surface count "+key)
	var near_triangles := 0
	var far_triangles := 0
	for mesh: ArrayMesh in asset["meshes"]:
		near_triangles += ProceduralAssets.triangles(mesh)
	for mesh: ArrayMesh in far:
		far_triangles += ProceduralAssets.triangles(mesh)
		_check((asset["bounds"] as AABB).grow(0.002).encloses(mesh.get_aabb()),"far bounds/anchor changed "+key+": "+str(mesh.get_aabb())+" outside "+str(asset["bounds"]))
		_check(mesh.surface_get_material(0)!=null,"far material missing "+key)
		var data := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = data[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = data[Mesh.ARRAY_INDEX] if data[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else vertices.size()
		for i in range(0,count,3):
			var a := indices[i] if not indices.is_empty() else i
			var b := indices[i+1] if not indices.is_empty() else i+1
			var c := indices[i+2] if not indices.is_empty() else i+2
			var cross := (vertices[b]-vertices[a]).cross(vertices[c]-vertices[a])
			_check(cross.length_squared()>0.0000000000001,"degenerate far triangle "+key)
			_check(cross.dot(normals[a]+normals[b]+normals[c])<0,"far winding changed "+key)
	_check(far_triangles<near_triangles*0.40,"insufficient LOD reduction "+key)
	print("LOD ",key," near=",near_triangles," far=",far_triangles)


func _check_switch(holder: Node3D,camera: Camera3D,expected_nodes: int,distance: float) -> void:
	var leader := holder.get_child(0) as ModelLodMesh
	_check(leader!=null,"LOD leader missing")
	if leader==null: return
	var original: Array = []
	for piece: MeshInstance3D in holder.get_children():
		original.append([piece.mesh,piece.material_override,piece.transform])
	camera.position = Vector3(0,1.7,distance+3)
	leader._process(0.2)
	_check(leader.far_active,"distance did not activate far LOD")
	var visible_count := 0
	for piece: MeshInstance3D in holder.get_children():
		if piece.visible: visible_count+=1
	_check(visible_count==2,"far draw calls exceed two")
	camera.position = Vector3(0,0,distance)
	leader._process(0.2)
	_check(leader.far_active,"LOD has no hysteresis")
	camera.position = Vector3(0,0,distance-3)
	leader._process(0.2)
	_check(not leader.far_active,"distance did not restore near LOD")
	_check(holder.get_child_count()==expected_nodes,"LOD adds draw nodes")
	for i in holder.get_child_count():
		var piece: MeshInstance3D = holder.get_child(i)
		_check(piece.visible and piece.mesh==original[i][0] and piece.material_override==original[i][1],"near resources changed")
		_check(piece.transform==original[i][2],"LOD changes visual axis/position")


func _check(condition: bool,message: String) -> void:
	if not condition: errors.append(message)

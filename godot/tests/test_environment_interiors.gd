extends SceneTree
const FINISH := preload("res://src/environment_interiors.gd")
const REGISTRY := preload("res://src/environment_registry.gd")
var errors: Array[String] = []
func _initialize() -> void: run.call_deferred()
func check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)
func area(poly: Array) -> float: return FINISH._area(poly)
func snapshot(col: CollisionWorld) -> String:
	return var_to_str([col._data,col._active,col._by_id])
func mesh_area(mi: MeshInstance3D) -> float:
	if mi.mesh == null or mi.layers == 0 or not mi.visible: return 0.0
	var result := 0.0
	for surface in mi.mesh.get_surface_count():
		var a := mi.mesh.surface_get_arrays(surface)
		var v: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
		var idx: Variant = a[Mesh.ARRAY_INDEX]
		if idx != null and not idx.is_empty():
			for k in range(0,idx.size(),3): result += (v[idx[k+1]]-v[idx[k]]).cross(v[idx[k+2]]-v[idx[k]]).length()*.5
		else:
			for k in range(0,v.size(),3): result += (v[k+1]-v[k]).cross(v[k+2]-v[k]).length()*.5
	return result
func run() -> void:
	var poly := [{"p":Vector3(-2,0,0),"uv":Vector2(-2,0)},{"p":Vector3(2,0,0),"uv":Vector2(2,0)},{"p":Vector3(2,0,2),"uv":Vector2(2,2)}]
	for point: Dictionary in poly:
		point["uv2"] = (point["uv"] as Vector2)*.5
		point["color"] = Color((point["p"].x+2)*.25,0,0)
		point["tangent"] = Plane(Vector3.RIGHT,1)
	var box := {"box":[-1.0,1.0,-1.0,1.0],"floor":0.04,"height":2.0}
	var cut := FINISH._cut(poly,box)
	var sum := area(cut.inside)
	for piece: Array in cut.outside: sum += area(piece)
	check(absf(sum-area(poly)) < .00001,"cut coplanar area conservation")
	for point: Dictionary in cut.inside:
		check((point.uv as Vector2).distance_to(Vector2(point.p.x,point.p.z)) < .00001,"cut UV interpolation")
		check((point.uv2 as Vector2).distance_to(Vector2(point.p.x,point.p.z)*.5) < .00001,"cut UV2 interpolation")
		check(absf(point.color.r-(point.p.x+2)*.25) < .00001,"cut color interpolation")
	var world := Node3D.new()
	root.add_child(world)
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var built := WorldBuilder.build(world,mats,col)
	var registry := REGISTRY.apply(world,built,mats)
	var before := snapshot(col)
	var legacy: Dictionary = {}
	var hidden: Dictionary = {}
	var originals: Dictionary = {}
	for node: Node in SkinLayer._nodes(world):
		if node is MeshInstance3D and node.has_meta("skin_parts"):
			originals[node.get_instance_id()] = node.mesh
			if node.has_meta("environment_hidden_vertices"): hidden[node.get_instance_id()] = node.get_meta("environment_hidden_vertices").duplicate()
		if node is Node3D and not node.has_meta("skin_parts") and not node.has_meta("environment_residual") and node.name != "environment-residual":
			legacy[node.get_instance_id()] = {"transform":node.transform,"visible":node.visible,"mesh":node.mesh if node is MeshInstance3D else null,"material":node.material_override if node is MeshInstance3D else null}
	var start := Time.get_ticks_msec()
	var result := FINISH.apply(world,mats,built)
	result["verification_msec"] = Time.get_ticks_msec()-start
	check(before == snapshot(col),"physics data/active/IDs changed")
	check(result.errors.is_empty(),"source arrays unsupported")
	check(result.moved_triangles > 100,"no meaningful interior transfer")
	check(absf(result.moved_area-result.replacement_area-result.retained_area) < .002,"world area conservation")
	for node: Node in SkinLayer._nodes(world):
		var id := node.get_instance_id()
		if originals.has(id):
			check(node.mesh == originals[id],"original mesh was mutated")
			if node.has_meta("environment_hidden_vertices"):
				var residual: MeshInstance3D = node.get_meta("environment_residual")
				var total: int = node.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
				var expected := total-(node.get_meta("environment_hidden_vertices") as Dictionary).size()
				var actual: int = residual.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() if residual.mesh != null else 0
				check(actual == expected,"residual vertex count disagrees with mask")
				check(node.layers == 0,"original remains visible under replacement")
			if hidden.has(id):
				for vertex: int in hidden[id]: check(node.get_meta("environment_hidden_vertices").has(vertex),"registry hidden vertex restored")
		if legacy.has(id):
			check(node.transform == legacy[id].transform and node.visible == legacy[id].visible,"existing prop/story transform changed")
			if node is MeshInstance3D: check(node.mesh == legacy[id].mesh and node.material_override == legacy[id].material,"existing prop/story material changed")
		if node is MeshInstance3D and node.has_meta("environment_interior"):
			var a: Array = node.mesh.surface_get_arrays(0)
			check(a[Mesh.ARRAY_VERTEX].size() == a[Mesh.ARRAY_TEX_UV].size(),"new surface UV count")
	var count := SkinLayer._nodes(world).size()
	check(FINISH.apply(world,mats,built) == result and count == SkinLayer._nodes(world).size(),"apply is not idempotent")
	result["registry_active"] = registry.get("active",false)
	result["registry_removed_triangles"] = registry.get("removed_triangles",0)
	result["verification_errors"] = errors
	result["verified"] = errors.is_empty()
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			var path := arg.trim_prefix("--output=")
			DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			var file := FileAccess.open(path, FileAccess.WRITE)
			if file != null:
				file.store_string(JSON.stringify(result, "\t"))
				file.close()
			else: check(false, "cannot write optional report " + path)
	for error: String in errors: printerr(error)
	print("test_environment_interiors: ","PASS" if errors.is_empty() else "FAIL", " moved=",result.moved_triangles," wall/floor replacement=",result.replacement_triangles," baseboard=",result.decor_triangles," area_delta=",result.moved_area-result.replacement_area-result.retained_area," apply_ms=",result.verification_msec)
	world.queue_free()
	await process_frame
	quit(0 if errors.is_empty() else 1)

extends SceneTree

# Frozen from the original two-surface horizon before partitioning, in Godot
# 4.7.1. Canonical whole triangles include byte-exact vertex, normal/tangent
# and UV/COLOR streams; cyclic rotations preserve winding, reversals do not.
const HORIZON_ORIGINAL_SHA256 := "87435b94639d8be82588f4732d84e3aa419e052976378c12d3ce0df2013aed30"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var errs: Array[String] = []
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	var built := WorldBuilder.build(world, mats, col)
	var snt: Dictionary = built.get("snt", {})
	var q: Dictionary = snt.get("quest", {})
	var nodes: Dictionary = snt.get("nodes", {})
	var horizon := world.get_node_or_null("rural-horizon") as Node3D
	if horizon == null:
		errs.append("дальний слой отсутствует")
	else:
		var tris := 0
		var surfaces := 0
		var shared: Material = null
		if horizon is MeshInstance3D: errs.append("original horizon is still renderable")
		if horizon.get_child_count() != 6: errs.append("horizon must contain six immutable chunks")
		if horizon.transform != Transform3D.IDENTITY: errs.append("horizon holder transform changed")
		for child: Node in horizon.get_children():
			var chunk := child as MeshInstance3D
			if chunk == null or chunk.mesh == null:
				errs.append("horizon contains a non-mesh child");continue
			tris += chunk.mesh.get_faces().size()/3
			surfaces += chunk.mesh.get_surface_count()
			if shared == null: shared = chunk.material_override
			if chunk.material_override == null or chunk.material_override != shared: errs.append("horizon material was duplicated or replaced")
			if chunk.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF: errs.append("horizon chunk casts shadows")
			if chunk.visibility_range_begin != 0.0 or chunk.visibility_range_end != 0.0: errs.append("horizon introduces distance hiding")
			if chunk.get_script() != null or chunk.get_child_count() != 0: errs.append("horizon chunk introduces a controller or extra geometry")
			if chunk.transform != Transform3D.IDENTITY: errs.append("horizon chunk transform changed")
		if tris != 12458 or surfaces != 6:
			errs.append("дальний слой превысил 6 surfaces / 20000 triangles")
		if _horizon_signature(horizon) != HORIZON_ORIGINAL_SHA256: errs.append("horizon changed frozen packed triangle/winding/UV/COLOR/normal/tangent multiset")
		if built["rural"]["landscape"]["far_draw_calls"] != 6 or built["rural"]["landscape"]["far_triangles"] != 12458: errs.append("horizon report differs from actual six chunks")
		_test_horizon_culling(horizon,errs)
		print("rural horizon: ", tris, " triangles / ", surfaces, " surface(s); frozen oracle ",HORIZON_ORIGINAL_SHA256)
	for id: String in ["snt-p01-gate", "snt-p01-ring", "snt-p01-traces",
			"snt-signal-handle", "snt-p01-mug", "snt-p01-glove",
			"snt-p01-first-tracks", "snt-p01-tag-cross"]:
		if not nodes.get(id) is Node3D:
			errs.append("нет изменяемого узла " + id)
	for key: String in ["watch_log", "yard_inspect", "signal", "return_inspect",
			"silhouette", "ring_initial", "ring_return", "last_round", "water_marks"]:
		if not q.get(key) is Vector3:
			errs.append("нет якоря " + key)
	if nodes.has("snt-p01-ring"):
		var ring: Node3D = nodes["snt-p01-ring"]
		if ring.position != q.get("ring_initial"):
			errs.append("круг собран не в исходной позе")
		if (q["ring_return"] as Vector3).distance_to(ring.position) < 0.5:
			errs.append("возвратная поза круга не отличается от исходной")
	for id: String in ["snt-p01-traces", "snt-p01-tag-cross"]:
		if nodes.has(id) and (nodes[id] as Node3D).visible:
			errs.append(id + " виден до звонка")
	# Узкие ходовые полосы у сценарных целей не занимают стол/скамья.
	for at: Vector3 in [Vector3(19.0, 0.8, -41.2), Vector3(19.0, 0.8, -42.25),
			Vector3(4.40, 0.8, -37.75), Vector3(7.1, 0.8, -68.65)]:
		if col.point_hit(at.x, at.y, at.z, CollisionWorld.ALL_SOLID):
			errs.append("проход к сценической цели перекрыт: " + str(at))
	if col.box_count(CollisionWorld.SET_STATIC) != 311 \
			or col.box_count(CollisionWorld.SET_BLOCKERS) != 4 \
			or int(built.get("triangles", 0)) != 3885:
		errs.append("базовая геометрия потеряла паритет 311/4/3885")
	# Последовательная сборка не должна оставлять старые узлы или накапливать коллизии.
	var second_col := CollisionWorld.new()
	var second_root := Node3D.new()
	var second := WorldBuilder.build(second_root, mats, second_col)
	if second_col.box_count(CollisionWorld.SET_OVERLAY) != col.box_count(CollisionWorld.SET_OVERLAY):
		errs.append("повторная сборка меняет число overlay boxes")
	if ((second["snt"] as Dictionary)["nodes"] as Dictionary).size() != nodes.size():
		errs.append("повторная сборка меняет набор узлов")
	second_root.free()
	world.free()
	if errs.is_empty():
		print("test_rural_geometry: PASS")
		quit(0)
	else:
		for e in errs:
			print("FAIL rural_geometry: ", e)
		quit(1)


func _horizon_signature(horizon: Node3D) -> String:
	var triangles: Array[String] = []
	for node: Node in horizon.get_children():
		var chunk := node as MeshInstance3D
		if chunk == null or chunk.mesh == null: continue
		for surface in chunk.mesh.get_surface_count():
			var raw := RenderingServer.mesh_get_surface(chunk.mesh.get_rid(),surface)
			var format: int = raw["format"]
			var count: int = raw["vertex_count"]
			var ps := RenderingServer.mesh_surface_get_format_vertex_stride(format,count)
			var ns := RenderingServer.mesh_surface_get_format_normal_tangent_stride(format,count)
			var no := RenderingServer.mesh_surface_get_format_offset(format,count,Mesh.ARRAY_NORMAL)
			var ats := RenderingServer.mesh_surface_get_format_attribute_stride(format,count)
			var vb: PackedByteArray = raw["vertex_data"]
			var ab: PackedByteArray = raw["attribute_data"]
			for first in range(0,count,3):
				var vertices: Array[String] = []
				for offset in 3:
					var at := first+offset
					vertices.append(vb.slice(at*ps,(at+1)*ps).hex_encode()+vb.slice(no+at*ns,no+(at+1)*ns).hex_encode()+ab.slice(at*ats,(at+1)*ats).hex_encode())
				var cycle: Array[String] = ["|".join(vertices),"|".join([vertices[1],vertices[2],vertices[0]]),"|".join([vertices[2],vertices[0],vertices[1]])]
				cycle.sort();triangles.append(cycle[0])
	triangles.sort()
	return "\n".join(triangles).sha256_text()


func _test_horizon_culling(horizon: Node3D,errors: Array[String]) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(1280,720)
	root.add_child(viewport)
	var camera := Camera3D.new()
	viewport.add_child(camera)
	camera.fov=70.0;camera.near=.08;camera.far=90.0
	var points := [["yard",Vector3(0,1.65,-1.2),PI,-.04],
		["second-line",Vector3(-18,1.65,-21),PI*.5,.04],
		["snt-gate",Vector3(36.8,1.65,-38.3),PI*.5,.02],
		["snt-water",Vector3(-4,1.65,-53.8),PI*.5,.02],
		["snt-dead-end",Vector3(7.1,1.65,-66.4),0.0,.02],
		["drive-away",Vector3(7.6,1.65,-5.2),1.728,-.03],
		["gap-to-second-line",Vector3(11,1.65,-12),0.0,.06]]
	for point: Array in points:
		camera.transform=Transform3D(Basis.from_euler(Vector3(point[3],point[2],0),EULER_ORDER_YXZ),point[1])
		var planes := camera.get_frustum()
		var triangles := 0
		var calls := 0
		for child: MeshInstance3D in horizon.get_children():
			var box: AABB = child.transform*child.mesh.get_aabb()
			var inside := true
			for plane: Plane in planes:
				var minimum := box.position
				if plane.normal.x < 0: minimum.x = box.end.x
				if plane.normal.y < 0: minimum.y = box.end.y
				if plane.normal.z < 0: minimum.z = box.end.z
				if plane.distance_to(minimum) > 0: inside=false;break
			if inside:
				triangles += child.mesh.get_faces().size()/3
				calls += child.mesh.get_surface_count()
		if triangles > 12458 or calls > 6: errors.append("horizon partition exceeds original geometry or six global calls")
		if point[0] == "snt-gate" and triangles > 3458: errors.append("horizon partition saves fewer than9000 gate triangles at real16:9aspect")
		print("horizon camera ",point[0],": triangles=",triangles," calls=",calls)
	viewport.free()

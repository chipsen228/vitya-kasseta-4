# Профильный тест процедурных фигур фазы 19.
# Godot --headless --path godot --script res://tests/test_actor_geometry.gd
extends SceneTree


func _initialize() -> void:
	var errs: Array[String] = []
	var world := Node3D.new()
	root.add_child(world)
	var actors := Actors.new(world).build()
	var assigned_faces := _assigned_faces(errs)
	var triangle_counts := {}

	for who: String in Actors.KEYS:
		var fig := actors.figure(who)
		if fig == null:
			errs.append("нет фигуры %s" % who)
			continue
		var tris := _triangles(fig)
		triangle_counts[who] = tris
		if tris <= 0 or tris >= 700:
			errs.append("%s: %d треугольников, требуется 1..699" % [who, tris])
		if _has_box(fig):
			errs.append("%s: остался видимый BoxMesh" % who)
		if _has_physics(fig):
			errs.append("%s: процедурная фигура получила физическое тело" % who)
		if _has_quad(fig):
			errs.append("%s: лицо вынесено в отдельный QuadMesh" % who)
		var face_path := String(assigned_faces.get(who, Actors.FACE_TEX))
		if not actors.set_face(who, face_path):
			errs.append("%s: не назначилась текстура %s" % [who, face_path])
		else:
			_check_face_surface(who, actors._rigs[who]["head"], face_path, errs)

	# Вторая эмоция наблюдателя проходит тем же draw call и материалом, что первая.
	var watcher_alt := String(assigned_faces.get("watcher-alt", ""))
	if watcher_alt == "" or not actors.set_face("watcher", watcher_alt):
		errs.append("watcher: не назначилась вторая текстура лица")
	else:
		_check_face_material("watcher-alt", actors._rigs["watcher"]["head"], watcher_alt, errs)

	var threat := actors.figure("threat")
	var arkady := actors.figure("arkady")
	var shouter := actors.figure("shouter")
	var watcher := actors.figure("watcher")
	var valya := actors.figure("valya")
	if not _visible_named(threat, "cap") or _visible_named(arkady, "cap"):
		errs.append("кепка должна отличать Витю/эхо от соседей")
	if _scale_x(shouter, "torso-frustum") <= _scale_x(arkady, "torso-frustum"):
		errs.append("крикун не шире Аркадия в плечах")
	if _scale_x(watcher, "torso-frustum") >= _scale_x(arkady, "torso-frustum"):
		errs.append("наблюдатель не тоньше Аркадия")
	if float(valya.get_meta("height")) >= float(arkady.get_meta("height")):
		errs.append("Валя не ниже Аркадия")
	if not _visible_named(valya, "profile-skirt") or not _visible_named(valya, "profile-headscarf"):
		errs.append("у Вали нет юбки или платка")

	actors.show("arkady", true)
	actors.place("arkady", 0.0, 0.0, 0.0)
	actors.walk_anim("arkady", 0.1, {"speed": 1.2, "moving": true})
	var arkady_rig: Dictionary = actors._rigs["arkady"]
	var arkady_legs: Array = arkady_rig["legs"]
	var first_leg: Dictionary = arkady_legs[0]
	var ankle: Node3D = first_leg["ankle"]
	if absf(ankle.rotation.x) < 0.001:
		errs.append("перекат стопы не участвует в цикле ходьбы")

	if errs.is_empty():
		print("PASS test_actor_geometry: profiles, anatomical head/hand, face winding/UV/textures, foot roll, <700 tris")
		print("actor triangles: ", triangle_counts)
		quit(0)
		return
	print("FAIL test_actor_geometry: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


func _triangles(node: Node) -> int:
	var total := 0
	if node is MeshInstance3D:
		var mesh := (node as MeshInstance3D).mesh
		if mesh != null:
			for surface in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(surface)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				var index_data: Variant = arrays[Mesh.ARRAY_INDEX]
				var count := vertices.size()
				if index_data is PackedInt32Array and not (index_data as PackedInt32Array).is_empty():
					count = (index_data as PackedInt32Array).size()
				total += int(count / 3)
	for child in node.get_children():
		total += _triangles(child)
	return total


func _has_box(node: Node) -> bool:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh is BoxMesh and (node as MeshInstance3D).visible:
		return true
	for child in node.get_children():
		if _has_box(child):
			return true
	return false


func _has_physics(node: Node) -> bool:
	if node is CollisionObject3D:
		return true
	for child in node.get_children():
		if _has_physics(child):
			return true
	return false


func _has_quad(node: Node) -> bool:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh is QuadMesh:
		return true
	for child in node.get_children():
		if _has_quad(child):
			return true
	return false


func _assigned_faces(errs: Array[String]) -> Dictionary:
	var out := {"threat": Actors.FACE_TEX, "echo": Actors.FACE_TEX}
	var file := FileAccess.open("res://data/street.json", FileAccess.READ)
	if file == null:
		errs.append("не открылся data/street.json для проверки назначенных лиц")
		return out
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if not (parsed is Dictionary):
		errs.append("data/street.json не разобрался")
		return out
	var neighbours: Dictionary = (parsed as Dictionary).get("NEIGHBOURS", {})
	for who: String in ["arkady", "shouter", "watcher", "valya"]:
		var definition: Dictionary = neighbours.get(who, {})
		out[who] = String(definition.get("face", ""))
		if String(out[who]) == "":
			errs.append("%s: в street.json не назначено лицо" % who)
	var watcher: Dictionary = neighbours.get("watcher", {})
	out["watcher-alt"] = String(watcher.get("face2", ""))
	return out


func _check_face_surface(who: String, head: MeshInstance3D, expected_path: String,
		errs: Array[String]) -> void:
	if not head.mesh is ArrayMesh or head.mesh.get_surface_count() != 2:
		errs.append("%s: единая голова должна иметь skin+face поверхности" % who)
		return
	_check_face_material(who, head, expected_path, errs)
	var arrays := head.mesh.surface_get_arrays(1)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if vertices.size() < 24 or vertices.size() != uvs.size():
		errs.append("%s: недостаточно геометрии лица/UV" % who)
		return
	var uv_min := Vector2(INF, INF)
	var uv_max := Vector2(-INF, -INF)
	var depth_min := INF
	var depth_max := -INF
	for i in vertices.size():
		var p := vertices[i]
		uv_min = uv_min.min(uvs[i])
		uv_max = uv_max.max(uvs[i])
		depth_min = minf(depth_min, p.z)
		depth_max = maxf(depth_max, p.z)
		if absf(p.x) > Actors.HEAD_W * 0.5 + 0.00001 or absf(p.y) > Actors.HEAD_H * 0.5 + 0.00001 \
				or absf(p.z) > Actors.HEAD_D * 0.5 + 0.00001:
			errs.append("%s: лицо вышло за исходный HEAD AABB" % who)
			break
		if normals[i].dot(Vector3.FORWARD) <= 0:
			errs.append("%s: лицевая normal отвернута от камеры" % who)
			break
		if p.x < -0.001 and uvs[i].x < 0.5 or p.x > 0.001 and uvs[i].x > 0.5:
			errs.append("%s: текстура лица зеркальная по U" % who)
			break
		var row := -1
		for level in ObjectGeometry.FACE_LEVELS.size():
			if absf(p.y - float(ObjectGeometry.FACE_LEVELS[level])) < 0.0001:
				row = level
				break
		if row < 0 or absf(uvs[i].y - float(ObjectGeometry.FACE_V[row])) > 0.0001:
			errs.append("%s: UV не соответствуют анатомическим уровням портрета" % who)
			break
	if depth_max - depth_min < 0.025:
		errs.append("%s: лицо осталось плоским" % who)
	if not uv_min.is_equal_approx(Vector2(Actors.FACE_U0, 1.0 - Actors.FACE_V1)) \
			or not uv_max.is_equal_approx(Vector2(Actors.FACE_U1, 1.0 - Actors.FACE_V0)):
			errs.append("%s: изменён UV crop фотографии" % who)
	# Эти ограничения проверяют сам визуальный дефект, а не повторяют формулу:
	# низ портрета содержит рубашку, а края на уровне щёк содержат чёрный фон.
	for i in vertices.size():
		if vertices[i].y < -0.09 and (uvs[i].x < 0.37 or uvs[i].x > 0.63 or uvs[i].y > 0.85):
			errs.append("%s: подбородок захватывает тёмную рубашку портрета" % who)
			break
		if absf(vertices[i].y) < 0.035 and (uvs[i].x < 0.24 or uvs[i].x > 0.76):
			errs.append("%s: UV щёк захватывают чёрный фон портрета" % who)
			break
	for surface in 2:
		var data := head.mesh.surface_get_arrays(surface)
		var vv: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
		var nn: PackedVector3Array = data[Mesh.ARRAY_NORMAL]
		for tri in range(0, vv.size(), 3):
			var cross := (vv[tri + 1] - vv[tri]).cross(vv[tri + 2] - vv[tri])
			if cross.length_squared() < 1e-14 or cross.dot(nn[tri]) >= -1e-9:
				errs.append("%s: winding головы surface=%d triangle=%d" % [who, surface, tri / 3])
				break


func _check_face_material(who: String, head: MeshInstance3D, expected_path: String,
		errs: Array[String]) -> void:
	var material := head.get_active_material(1) as ShaderMaterial
	if material == null or material.shader == null or material.shader.resource_path != Actors.PSX_SHADER:
		errs.append("%s: лицо не использует PSX-материал" % who)
		return
	var texture := material.get_shader_parameter("albedo_tex") as Texture2D
	if texture == null or texture.resource_path != expected_path:
		errs.append("%s: на лице %s вместо %s" % [who,
			texture.resource_path if texture != null else "null", expected_path])


func _named(node: Node, wanted: String) -> Node:
	if node.name == wanted:
		return node
	for child in node.get_children():
		var hit := _named(child, wanted)
		if hit != null:
			return hit
	return null


func _visible_named(node: Node, wanted: String) -> bool:
	var hit := _named(node, wanted)
	return hit is Node3D and (hit as Node3D).visible


func _scale_x(node: Node, wanted: String) -> float:
	var hit := _named(node, wanted) as Node3D
	return hit.scale.x if hit != null else 0.0

extends SceneTree


func _initialize() -> void:
	Materials.render_hq_enabled=OS.get_cmdline_user_args().has("--hq")
	var errs: Array[String] = []
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)

	_check_house_styles(errs)
	_check_empty_house(built, col, errs)
	_check_lakes(root, col, errs)
	_check_tower_and_sign(root, errs)
	_check_mill(root, built, col, errs)
	_check_low_poly_trees(root, errs)
	_check_replaced_props(errs)
	var proxies: Array = (built.get("scatter", {}) as Dictionary).get("collision_proxies", [])
	if proxies.is_empty():
		errs.append("scatter collision-proxy включён в данных, но ни один не принят")

	root.free()
	if errs.is_empty():
		print("test_world_visuals: PASS")
		quit(0)
		return
	print("FAIL test_world_visuals: расхождений ", errs.size())
	for e: String in errs:
		print("  - ", e)
	quit(1)


func _check_house_styles(errs: Array[String]) -> void:
	var houses: Array = StreetWorld.data().get("HOUSES", [])
	var by_id := {}
	for h: Dictionary in houses:
		by_id[String(h.get("id", ""))] = h
	for row: Array in [["redhouse", "siding-red-old"], ["boarded", "siding-grey-old"]]:
		var h: Dictionary = by_id.get(row[0], {})
		if String(h.get("wallMaterial", "")) != String(row[1]):
			errs.append("%s: неверный семантический материал стен" % row[0])
	var red: Dictionary = by_id.get("redhouse", {})
	var rx: Array = red.get("x", [])
	var rz: Array = red.get("z", [])
	if rx.size() != 2 or rz.size() != 2 or not is_equal_approx(float(rx[0]), -1.6) \
			or not is_equal_approx(float(rx[1]), 3.4) \
			or not is_equal_approx(float(rz[0]), -13.0) \
			or not is_equal_approx(float(rz[1]), -7.5):
		errs.append("footprint красного дома изменён")


func _check_empty_house(built: Dictionary, col: CollisionWorld,
		errs: Array[String]) -> void:
	var outskirts: Dictionary = built.get("outskirts", {})
	var house: Dictionary = outskirts.get("empty_house", {})
	if house.get("x", []) != [-8.997, -6.443] or house.get("z", []) != [-27.117, -24.483]:
		errs.append("пустой дом не сохранил footprint farm-smallbarn")
		return
	var door: Array = house.get("door", [])
	var x := (float(door[0]) + float(door[1])) * 0.5
	# Южная дверь и центр комнаты обязаны принимать капсулу игрока.
	for p: Vector2 in [Vector2(x, -24.55), Vector2(x, -25.60)]:
		var hit := col.capsule_hit_d(p.x, 0.32, p.y, p.x, 1.48, p.y, 0.30,
			CollisionWorld.ALL_SOLID)
		if not hit.is_empty():
			errs.append("пустой дом недоступен в точке %s: %s" % [p, hit])


func _check_lakes(root: Node3D, col: CollisionWorld, errs: Array[String]) -> void:
	for id: String in ["story-lake-waterway", "snt-lake-waterway"]:
		var n := root.find_child(id, true, false)
		if n == null:
			errs.append("%s: waterway marker absent" % id)
			continue
		if not Materials.render_hq_enabled and not bool(n.get_meta("bucketed", false)):
			errs.append("%s: вода не попала в общий material bucket" % id)
			continue
		if int(n.get_meta("point_count", 0)) < 12 \
				or int(n.get_meta("triangle_count", 0)) <= 0:
			errs.append("%s: произвольный невыпуклый берег не триангулирован" % id)
		if int(n.get_meta("layer_count", 0)) != (1 if Materials.render_hq_enabled else 3) \
				or int(n.get_meta("animated_samples", 0)) != 2 \
				or float(n.get_meta("max_displacement_m", 1.0)) > 0.01:
			errs.append("%s: нет дешёвых слоёв мелководье/глубина/ил" % id)
		if Materials.render_hq_enabled:
			var surface := root.find_child(id.trim_suffix("-waterway")+"-surface",true,false) as MeshInstance3D
			if surface==null or surface.mesh.get_surface_count()!=1:
				errs.append("%s: HQ water must have a single surface" % id)
			elif (surface.material_override as ShaderMaterial).shader.resource_path!="res://shaders/environment_water.gdshader":
				errs.append("%s: HQ depth-writing water shader missing" % id)
		if String(n.get_meta("texture_path", "")) \
				!= "res://assets/atlases/waterway-psx-atlas-v2.png":
			errs.append("%s: не подключён версионный PSX-атлас воды" % id)
	var snt := root.find_child("snt-lake-waterway", true, false)
	if snt != null and int(snt.get_meta("source_polygon_count", 0)) < 3:
		errs.append("озеро СНТ не соединено с двумя участками реки")
	# У СНТ причал остаётся прежним. У пруда Вали настила больше нет: доступно
	# восточное мелководье, глубина блокируется, маршрут к водокачке сухой.
	for row: Array in [
		[-0.45, -45.30, false, "конец причала СНТ"],
		[-2.15, -44.40, true, "вода сбоку причала СНТ"],
		[-0.45, -46.10, true, "вода за причалом СНТ"],
		[-17.70, -54.00, false, "водопропуск второго проезда"],
		[-17.30, -58.10, true, "внутри северной реки"],
		[-17.70, -58.10, false, "сухая кромка за контуром северной реки"],
		[-19.55, -29.00, false, "мелководье у сети Вали"],
		[-22.00, -29.00, true, "глубина за сетью Вали"],
		[-18.50, -29.00, false, "сухой маршрут к водокачке"],
	]:
		var blocked := col.point_hit(float(row[0]), 0.80, float(row[1]),
			CollisionWorld.ALL_SOLID)
		if blocked != bool(row[2]):
			errs.append("%s: water blocker=%s, ожидалось %s" % [row[3], blocked, row[2]])
	var pond: Dictionary = OutskirtsWorld.data().get("POND", {})
	var water: Dictionary = pond.get("water", {})
	for row: Array in [
		[Vector3(-18.50, 0.0, -29.00), "dry"],
		[Vector3(-19.55, 0.0, -29.00), "shallow"],
		[Vector3(-22.00, 0.0, -29.00), "deep"],
	]:
		var got := LakeVisuals.sample_water(row[0], water)
		if got != String(row[1]):
			errs.append("sample_water(%s)=%s, ожидалось %s" % [row[0], got, row[1]])
	var story := root.find_child("story-lake-waterway", true, false)
	if story != null:
		if not is_equal_approx(float(story.get_meta("surface_y", 0.0)), 0.055):
			errs.append("зеркало пруда не поднято до y=0.055")
		var reeds := int(story.get_meta("reed_group_count", 0))
		if reeds < 10 or reeds > 14:
			errs.append("у пруда %d групп камыша, нужно 10--14" % reeds)
		if int(story.get_meta("deep_blocker_count", 0)) < 1:
			errs.append("глубокая вода не имеет отдельных blocker-ов")
	for id: String in ["valya-lake-boat", "snt-lake-boat"]:
		var boat := root.find_child(id, true, false)
		if boat == null:
			errs.append("%s: нет low-poly лодки" % id)
			continue
		var triangle_count := int(boat.get_meta("triangle_count", 0))
		if triangle_count < 40 or triangle_count > 60:
			errs.append("%s: лодка вне бюджета 40–60 треугольников" % id)


func _check_tower_and_sign(root: Node3D, errs: Array[String]) -> void:
	var tower := root.find_child("outskirts-water-tower", true, false)
	if tower == null:
		errs.append("нет процедурной водонапорной башни")
	else:
		var tank_ok := false
		for child: Node in tower.get_children():
			if child is MeshInstance3D and (child as MeshInstance3D).mesh is CylinderMesh:
				var cm := (child as MeshInstance3D).mesh as CylinderMesh
				if cm.radial_segments == 10:
					tank_ok = true
		if not tank_ok:
			errs.append("бак башни не 10-гранный")
	var texts: Array[String] = []
	for n: Node in root.find_children("*", "Label3D", true, false):
		var label := n as Label3D
		texts.append(label.text)
		if label.text in ["ФЕРМА →", "ВОДОКАЧКА →"]:
			if label.font == null or not label.font.resource_path.ends_with(
					"pt-mono-cyrillic-400.woff2"):
				errs.append("%s: указатель не использует локальный кириллический шрифт" % label.text)
			if label.texture_filter != BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS:
				errs.append("%s: atlas без mipmapped-фильтра" % label.text)
			if String(label.get_meta("atlas_text", "")) != label.text:
				errs.append("%s: текст вышел за детерминированный atlas-контракт" % label.text)
	for want: String in ["ФЕРМА →", "ВОДОКАЧКА →"]:
		if not texts.has(want):
			errs.append("на указателе нет точного текста «%s»" % want)


func _check_mill(root: Node3D, built: Dictionary, col: CollisionWorld,
		errs: Array[String]) -> void:
	var mill_def: Dictionary = {}
	for prop: Dictionary in GameData.props().get("PROPS", []):
		if String(prop.get("id", "")) == "old-windmill":
			mill_def = prop
			break
	var mill_at: Array = mill_def.get("at", [])
	if mill_at.size() != 3 or Vector3(float(mill_at[0]), float(mill_at[1]),
			float(mill_at[2])).distance_to(Vector3(21.0, 0.0, -29.0)) > 0.01 \
			or String(mill_def.get("m", "")) != "farm-windmill":
		errs.append("farm-windmill не возвращён отдельной локацией в (21,0,-29)")
	elif not is_equal_approx(float(mill_def.get("s", 0.0)), 1.30):
		errs.append("старая мельница не увеличена ровно вдвое: нужен scale 1.30")
	var mill_cfg: Dictionary = OutskirtsWorld.data().get("MILL", {})
	if not is_equal_approx(float(mill_cfg.get("lowerY", 0.0)), 4.10) \
			or not is_equal_approx(float(mill_cfg.get("upperY", 0.0)), 8.30):
		errs.append("площадки мельницы не подняты на 4.10/8.30 м")
	var outskirts: Dictionary = built.get("outskirts", {})
	var nodes: Dictionary = outskirts.get("nodes", {})
	for id: String in ["mill-wheel", "mill-journal", "mill-coat"]:
		if not (nodes.get(id) is Node3D):
			errs.append("у мельницы нет сюжетного узла %s" % id)
	var expected_nodes := {
		"mill-wheel": Vector3(19.16, 5.66, -28.80),
		"mill-journal": Vector3(21.84, 8.46, -29.68),
		"mill-coat": Vector3(19.92, 8.30, -29.50),
	}
	for id: String in expected_nodes:
		var node: Variant = nodes.get(id)
		if node is Node3D and (node as Node3D).position.distance_to(expected_nodes[id]) > 0.001:
			errs.append("%s не пересчитан от центра мельницы с коэффициентом 2" % id)
	for blocker: String in ["mill-wall-back", "mill-wall-side", "mill-wall-front",
			"mill-door-lintel", "mill-platform"]:
		if not col.is_blocker_active(blocker):
			errs.append("мельница не имеет физического объёма %s" % blocker)
	if not col.is_blocker_active("mill-upper-blade"):
		errs.append("верхняя лестница мельницы не закрыта лопастью до тормоза")
	var dump: Dictionary = OutskirtsWorld.data().get("DUMP", {})
	var car: Array = dump.get("car", [])
	var shifer: Array = dump.get("shifer", [])
	var barrels: Array = dump.get("barrels", [])
	var dump_ok := car.size() == 3 and shifer.size() == 3 and barrels.size() == 3
	if dump_ok:
		dump_ok = Vector3(float(car[0]), float(car[1]), float(car[2])).distance_to(
			Vector3(26.0, 0.0, -31.0)) < 0.001
		dump_ok = dump_ok and Vector3(float(shifer[0]), float(shifer[1]),
			float(shifer[2])).distance_to(Vector3(22.8, 0.0, -34.2)) < 0.001
		var expected_barrels := [Vector3(17.8, 0.0, -25.8),
			Vector3(25.8, 0.0, -27.0), Vector3(24.8, 0.0, -33.5)]
		for i in 3:
			var row: Array = barrels[i]
			dump_ok = dump_ok and row.size() == 3 and Vector3(float(row[0]),
				float(row[1]), float(row[2])).distance_to(expected_barrels[i]) < 0.001
	if not dump_ok:
		errs.append("свалка не разнесена вокруг увеличенного footprint мельницы")


func _check_low_poly_trees(root: Node3D, errs: Array[String]) -> void:
	var marker: Node = null
	for node: Node in root.find_children("*", "Node3D", true, false):
		if bool(node.get_meta("bucketed", false)) and node.has_meta("tree_count"):
			marker = node
			break
	if marker == null:
		errs.append("нет объединённой low-poly геометрии деревьев")
		return
	if not bool(marker.get_meta("bucketed", false)) or int(marker.get_meta("tree_count", 0)) <= 0:
		errs.append("деревья не попали в material buckets")
	var radial := int(marker.get_meta("radial_segments", 0))
	var tiers := int(marker.get_meta("tiers", 0))
	if radial < 6 or radial > 8 or tiers < 3 or tiers > 4:
		errs.append("деревья: неверные 6–8 граней или 3–4 яруса")
	if bool(marker.get_meta("casts_shadow", true)):
		errs.append("деревья отбрасывают тени")
	if int(marker.get_meta("orchard_count", 0)) <= 0:
		errs.append("яблони двора не переведены в low-poly MultiMesh")
	if int(marker.get_meta("silhouette_variants", 0)) < 7 \
			or int(marker.get_meta("orchard_variants", 0)) < 3:
		errs.append("не хватает семи лесных и трёх яблоневых силуэтов")
	if not bool(marker.get_meta("house_canopy_clearance", false)):
		errs.append("ряды деревьев не фильтруют расширенные footprint домов")
	if int(marker.get_meta("scary_tree_count", 0)) != 5:
		errs.append("пять сохранённых страшных деревьев отсутствуют")


func _check_replaced_props(errs: Array[String]) -> void:
	for p: Dictionary in GameData.props().get("PROPS", []):
		var at: Array = p.get("at", [])
		if String(p.get("m", "")) == "farm-windmill" and at == [-15, 3, -29]:
			errs.append("старый farm-windmill всё ещё заспавнен над водокачкой")
		if String(p.get("m", "")) == "farm-smallbarn" and at == [-7.72, 0, -25.8]:
			errs.append("старый farm-smallbarn всё ещё заспавнен поверх пустого дома")
	if not FileAccess.file_exists("res://assets/models/farm-smallbarn.glb"):
		errs.append("исходный ассет farm-smallbarn удалён")

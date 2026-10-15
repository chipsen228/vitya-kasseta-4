extends SceneTree

var errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	root.add_child(world)
	var built := WorldBuilder.build(world,mats,col)
	await process_frame
	var registry := RuralDressing.placement_registry()
	for owner: String in ["room:privy","prop:summer-shower","outskirts:FARM:barn",
			"outskirts:PUMP:base","outskirts:CLUB:hall","rural:shed:0","snt:p02:greenhouse","snt:p05:porch"]:
		if not registry.any(func(item: Dictionary)->bool: return item.get("owner","")==owner):
			errors.append("реестр пропустил "+owner)
	var tree_marker: Node = built["decor"]["trees:bucketed"]
	var instances: Array = tree_marker.get_meta("instances")
	var orchard: Dictionary = built["yard"]["orchard"]["trees"]
	if orchard.size()!=4:
		errors.append("нужно четыре доступные яблони, найдено %d" % orchard.size())
	for row: Dictionary in instances:
		if row.get("source","")!="yard-orchard":
			continue
		var id := int(row["tree_index"])
		var position := Vector2(float(row["x"]),float(row["z"]))
		var fruit: Node3D = built["yard"]["nodes"]["apples-%d" % id]
		if not position.is_equal_approx(Vector2(fruit.position.x,fruit.position.z)):
			errors.append("крона и плоды яблони%d расходятся" % id)
		if not orchard.has(id) or not position.is_equal_approx(Vector2(orchard[id]["x"],orchard[id]["z"])):
			errors.append("крона и look-якорь яблони%d расходятся" % id)
		var radius := float(orchard[id]["crown"])
		if not StreetWorld._tree_position_clear(position,radius,StreetWorld.TREE_BOUNDS,StreetWorld.tree_footprints()):
			errors.append("поставленная яблоня%d пересекает строение или проход" % id)
		if not col.point_hit(position.x,0.5,position.y,CollisionWorld.MASK_OVERLAY):
			errors.append("яблоня%d потеряла физический ствол" % id)
	var facades: Dictionary = built["snt"].get("facades",{})
	for plot: Dictionary in SntWorld.data().get("PLOTS",[]):
		var id := String(plot["id"])
		if plot["house"].get("kind","")=="veranda":
			continue
		if not facades.has(id):
			errors.append("нет собранного фасада "+id)
			continue
		var layout: Dictionary = facades[id]
		var door: Dictionary = layout["door"]
		if float(door["y1"])-float(door["y0"]) < 1.95 or float(door["y1"])-float(door["y0"])>2.05:
			errors.append(id+" дверь вне1.95..2.05м")
		for win: Dictionary in layout["windows"]:
			var gap := maxf(float(door["a"])-float(win["c"]),float(win["a"])-float(door["c"]))-2.0*SntWorld.PL_TRIM
			if gap < 0.119:
				errors.append(id+" наличники окна и двери пересеклись")
			_check_projection(world,id,layout,win,"glass")
		_check_projection(world,id,layout,door,"shedwood")
	# Полоса учитывает всю физическую геометрию, включая крыльцо и дворовые extras.
	var p05: Dictionary = SntWorld.data()["PLOTS"][4]
	if absf(float(p05["house"]["x"][1])-float(p05["house"]["x"][0])-2.8)>0.001 or absf(float(p05["house"]["z"][1])-float(p05["house"]["z"][0])-3.8)>0.001:
		errors.append("p05 габарит не2.8×3.8")
	for z_step in 47:
		var z := -48.5 + float(z_step)*0.13
		for x_step in 11:
			var x := 7.71+float(x_step)*0.119
			if col.point_hit(x,0.15,z,CollisionWorld.MASK_OVERLAY) or col.point_hit(x,1.0,z,CollisionWorld.MASK_OVERLAY):
				errors.append("p05 восточная полоса1.2м перекрыта в%s" % Vector2(x,z))
				break
	# Дом №109: смотрим в реальные треугольники южного фасада.
	for key: String in built["outskirts"].get("facades",{}):
		var facade: Dictionary = built["outskirts"]["facades"][key]
		var cfg: Dictionary = OutskirtsWorld.data()["SECOND_LINE"]["houses"][key]
		var skin_id := String(cfg.get("id",""))
		var holes: Array = [facade["door"]]
		holes.append_array(facade["windows"])
		for hole_index in holes.size():
			var hole: Array = holes[hole_index]
			if hole.size()!=2:
				continue
			var along := lerpf(float(hole[0]),float(hole[1]),0.30 if hole_index>0 else 0.5)
			var origin := Vector3(along,1.56,float(facade["front"])+0.40)
			var hits := _house_ray(world,skin_id,"SECOND_LINE-"+key,origin,Vector3.FORWARD)
			if hits.is_empty() or float(hits["distance"])<0.415:
				errors.append("дом109/"+key+" передняя стена закрывает настоящий проём "+str(hits))
			elif not String(hits["material"]).contains("glass" if hole_index>0 else "shedwood"):
				errors.append("дом109/"+key+" стекло или створка закрыты тёмным задником "+str(hits))
	if col.box_count(CollisionWorld.SET_STATIC)!=311 or col.box_count(CollisionWorld.SET_BLOCKERS)!=4 or int(built["triangles"])!=3885:
		errors.append("потерян паритет311/4/3885")
	# Реальные лучи кадра69: близкий срез кровли не должен светить металлом в небе.
	var bath_basis := Basis.from_euler(Vector3(0.04,PI*1.62,0),EULER_ORDER_YXZ)
	for pixel: Vector2 in [Vector2(900,130),Vector2(600,250),Vector2(1100,45)]:
		var tangent := tan(deg_to_rad(70.0)*0.5)
		var ray := (bath_basis*Vector3((pixel.x/1280.0*2.0-1.0)*tangent*1280.0/720.0,
			(1.0-pixel.y/720.0*2.0)*tangent,-1.0)).normalized()
		var edge_hit := _house_ray(world,"","BANYA",Vector3(1.2,2.03,21.6),ray)
		if edge_hit.is_empty() or not String(edge_hit.get("material","")).contains("dark"):
			errors.append("срез кровли69 снова даёт белую полосу "+str(edge_hit))
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--oracle="):
			var file := FileAccess.open(arg.trim_prefix("--oracle="),FileAccess.WRITE)
			if file==null:
				errors.append("не удалось записать oracle")
			else:
				var trees: Array = []
				for row: Dictionary in instances:
					if row.get("source","") in ["scary-six","yard-orchard"]:
						trees.append(row)
				file.store_string(JSON.stringify({"validated":errors.is_empty(),"trees":trees,"errors":errors},"\t"))
				file.close()
	world.free()
	if errors.is_empty():
		print("test_rural_placement: PASS (actual tree instances, 14 facades, 1.2m p05 corridor, 5 second-line facades)")
		quit(0)
	else:
		for err: String in errors:
			print("FAIL rural_placement: ",err)
		quit(1)

func _check_projection(world: Node3D,id: String,layout: Dictionary,hole: Dictionary,expected: String) -> void:
	var along := (float(hole["a"])+float(hole["c"]))*0.5
	# Рядом с переплётом, чтобы луч проверял стекло, а не центральную рейку.
	if expected=="glass":
		along=lerpf(float(hole["a"]),float(hole["c"]),0.30)
	var height := (float(hole["y0"])+float(hole["y1"]))*0.5
	var outward := float(layout["outward"])
	var at := float(layout["wall_at"])
	var origin := Vector3(at+outward, height,along) if layout["sideways"] else Vector3(along,height,at+outward)
	var direction := Vector3(-outward,0,0) if layout["sideways"] else Vector3(0,0,-outward)
	var hit := _house_ray(world,id,"",origin,direction)
	if hit.is_empty() or not String(hit.get("material","")).contains(expected):
		errors.append(id+" настоящая проекция "+String(hole["kind"])+" закрыта стеной: "+str(hit))

func _house_ray(world: Node3D,id: String,fallback: String,origin: Vector3,direction: Vector3) -> Dictionary:
	var nearest := INF
	var result: Dictionary = {}
	for node: Node in world.get_children():
		if not node is MeshInstance3D or not node.has_meta("skin_parts"):
			continue
		var mesh_node := node as MeshInstance3D
		var ranges: Dictionary = node.get_meta("skin_parts")
		var ids: Dictionary = node.get_meta("skin_part_ids",{})
		var arrays: Array = mesh_node.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		for owner: String in ranges:
			if not ((not id.is_empty() and String(ids.get(owner,""))==id) or (not fallback.is_empty() and owner.contains(fallback))):
				continue
			for span: Vector2i in ranges[owner]:
				for triangle in range(span.x,span.x+span.y,3):
					var hit: Variant = Geometry3D.ray_intersects_triangle(origin,direction,
						mesh_node.global_transform*vertices[triangle],mesh_node.global_transform*vertices[triangle+1],mesh_node.global_transform*vertices[triangle+2])
					if hit is Vector3:
						var distance := origin.distance_to(hit)
						if distance<nearest:
							nearest=distance
							result={"distance":distance,"material":String(mesh_node.name),"position":hit}
	return result

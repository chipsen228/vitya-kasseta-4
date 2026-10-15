## Добавление к существующей геометрии СНТ: только SET_OVERLAY.
class_name SntEpisodeWorld
extends RefCounted

const NINA := Vector3(27.5, 0.20, -42.4)
const GREENHOUSE := Vector3(30.3, 0.0, -46.8)
const SEMYON := Vector3(-28.5, 0.0, -49.25)
const RETRY := Vector3(9.6, 0.0, -70.0)

static func build(b: WorldBuilder, out: Dictionary) -> void:
	out["collision_additions"] = []
	out["collision_replacements"] = {
		"snt-north": "split at x8.6..10.6 for service gate",
		"snt-west": "split at z-56..-53 for forest return",
	}
	var q: Dictionary = out["quest"]
	q.merge({"nina": NINA + Vector3.UP * 1.2,
		"nina_greenhouse": GREENHOUSE + Vector3.UP * 1.2,
		"semyon": SEMYON + Vector3.UP * 1.2,
		"pump": Vector3(-26.0, 1.0, -49.0),
		"pump_filter": Vector3(-26.0, 0.50, -49.27),
		"radio": Vector3(7.1, 0.7, -58.86), "forest_retry": RETRY}, true)
	_resident_signs(b, out)
	_workshop(b, out)
	_forest(b, out)
	_anchors(out)
	out["pursuit_graph"] = graph()

static func _resident_signs(b: WorldBuilder, out: Dictionary) -> void:
	for p: Dictionary in out["plots"]:
		var face := String(p.get("face", "s"))
		var px: Array = p["x"]
		var pz: Array = p["z"]
		var at := Vector3(float(px[0]) + 1.65, 1.05, float(pz[1]) + 0.075)
		var yaw := 0.0
		if face == "n":
			at.z = float(pz[0]) - 0.075
			yaw = PI
		elif face == "e" or face == "w":
			at = Vector3(float(px[1]) + 0.075 if face == "e" else float(px[0]) - 0.075,
				1.05, float(pz[0]) + 1.7)
			yaw = PI * 0.5 if face == "e" else -PI * 0.5
		var caption := "%s\nУчасток № %d" % [String(p["residents"]), int(String(p["id"]).trim_prefix("p"))]
		_sign(b, out, "resident-" + String(p["id"]), caption, at, yaw, 1.50)
	_sign(b, out, "snt-workshop-sign", "РЯБОВ С. Н.\nРемонт насосов", Vector3(-27.1, 1.8, -49.55), PI, 1.7)

static func _sign(b: WorldBuilder, out: Dictionary, id: String, caption: String,
		at: Vector3, yaw: float, width: float) -> void:
	var holder := RuralDressing._holder(b, out["nodes"], id, at)
	holder.rotation.y = yaw
	var text := Label3D.new()
	text.text = caption
	text.font_size = 30
	text.pixel_size = 0.0039
	text.outline_size = 2
	text.modulate = Color("cdc7ac")
	text.shaded = true
	text.visibility_range_end = 20.0
	holder.add_child(text)
	RuralDressing._piece(b, holder, Vector3(0, 0, -0.035), Vector3(width, 0.36, 0.05), "boards")

static func _workshop(b: WorldBuilder, out: Dictionary) -> void:
	# Навес открыт к проезду. Ручной насос уже создан EverydayWorld.
	SntWorld._shell(b, -29.35, -24.75, 2.05, 2.14, -50.10, -48.0, "tin")
	for x: float in [-29.3, -24.8]:
		SntWorld._shell(b, x - 0.06, x + 0.06, 0.0, 2.1, -49.72, -49.60, "boards")
		_solid(b, out, Vector3(x - 0.06, 0, -49.72), Vector3(0.12, 2.1, 0.12), "snt-workshop-post-" + str(x))
	var wedge := RuralDressing._holder(b, out["nodes"], "snt-pump-wedge", Vector3(-26.12, 0.95, -49.01))
	RuralDressing._piece(b, wedge, Vector3.ZERO, Vector3(0.09, 0.05, 0.25), "boards")
	wedge.visible = false
	var cover := RuralDressing._holder(b, out["nodes"], "snt-pump-filter", Vector3(-26.0, 0.5, -49.25))
	RuralDressing._piece(b, cover, Vector3.ZERO, Vector3(0.21, 0.13, 0.055), "metal")
	var cloth := RuralDressing._holder(b, out["nodes"], "snt-pump-cloth", Vector3(-25.83, 0.52, -49.27))
	RuralDressing._piece(b, cloth, Vector3.ZERO, Vector3(0.22, 0.045, 0.16), "fabric")
	RuralDressing._piece(b, cloth, Vector3(0.10, 0.027, 0.02), Vector3(0.09, 0.012, 0.055), "metal")
	cloth.visible = false
	var shutter := RuralDressing._holder(b, out["nodes"], "snt-nina-shutter", Vector3(28.90, 1.55, -43.04))
	RuralDressing._piece(b, shutter, Vector3(-0.24, 0, 0), Vector3(0.48, 0.86, 0.045), "boards")
	shutter.rotation.y = -0.3
	var bucket := RuralDressing._holder(b, out["nodes"], "snt-workshop-bucket", Vector3(-27.4, 0.48, -49.46))
	for i in 8:
		var angle := float(i) * TAU / 8.0
		RuralDressing._piece(b, bucket, Vector3(cos(angle) * 0.12, 0.13, sin(angle) * 0.12), Vector3(0.075, 0.26, 0.048), "metal")
	RuralDressing._piece(b, bucket, Vector3(0, 0.015, 0), Vector3(0.24, 0.025, 0.24), "metal")
	RuralDressing._piece(b, bucket, Vector3(0, 0.34, 0), Vector3(0.25, 0.026, 0.026), "metal")
	StaticVisualBatch.merge_owner(bucket)
	SntWorld._shell(b, -27.68, -27.14, 0.42, 0.48, -49.68, -49.25, "boards")
	SntWorld._shell(b, -27.65, -27.57, 0, 0.42, -49.62, -49.32, "boards")
	SntWorld._shell(b, -27.23, -27.15, 0, 0.42, -49.62, -49.32, "boards")
	# Окно во внутренней стене открытой веранды Зуева, поверхность перед solid.
	SntWorld._shell(b, 10.29, 11.41, 1.02, 1.98, -60.39, -60.37, "dark")
	SntWorld._face_trim(b, false, -60.01, 10.3, 11.4, 1.03, 1.97)
	for xx: float in [10.25, 11.42]:
		SntWorld._shell(b, xx, xx + 0.065, 1.0, 2.03, -60.39, -60.01, "trim")
	SntWorld._shell(b, 10.3, 11.4, 1.03, 1.97, -60.05, -60.03, "glass")

static func _forest(b: WorldBuilder, out: Dictionary) -> void:
	# Оба пути плоские; единая плита исключает щели между поворотами.
	SntWorld._shell(b, -59.0, 14.0, -0.06, 0.0, -86.0, -72.0, "grass", 4)
	SntWorld._shell(b, -59.0, -46.0, -0.06, 0.0, -72.0, -52.0, "grass", 4)
	_solid(b, out, Vector3(-59, -0.20, -86), Vector3(73, 0.20, 14), "snt-forest-floor-north")
	_solid(b, out, Vector3(-59, -0.20, -72), Vector3(13, 0.20, 20), "snt-forest-floor-west")
	var paths: Array = [
		[[9.6, -67.7], [9.6, -74.5]], [[9.6, -74.5], [7.1, -74.5]],
		[[7.1, -74.5], [7.1, -78.0]], [[7.1, -78.0], [-12.0, -78.0]],
		[[-12.0, -78.0], [-12.0, -82.0]], [[-12.0, -82.0], [-34.0, -82.0]],
		[[-34.0, -82.0], [-34.0, -78.0]], [[-34.0, -78.0], [-52.0, -78.0]],
		[[-12.0, -78.0], [-34.0, -78.0]], [[-52.0, -78.0], [-52.0, -65.0]],
		[[-52.0, -65.0], [-55.0, -65.0]], [[-55.0, -65.0], [-55.0, -54.5]],
		[[-52.0, -65.0], [-52.0, -54.5]], [[-55.0, -54.5], [-44.0, -54.5]],
		[[-44.0, -54.5], [-26.0, -54.5]], [[-26.0, -54.5], [-26.0, -52.0]],
		[[-26.0, -52.0], [-20.0, -52.0]],
	]
	out["forest_paths"] = paths
	for segment: Array in paths:
		var a := Vector2(segment[0][0], segment[0][1])
		var z := Vector2(segment[1][0], segment[1][1])
		SntWorld._shell(b, minf(a.x, z.x) - 1.10, maxf(a.x, z.x) + 1.10,
			0.004, 0.012, minf(a.y, z.y) - 1.10, maxf(a.y, z.y) + 1.10, "dirt", 2)
	# Периметр отнесён от тропы. Твёрдые стволы не стоят на её центре.
	_solid(b, out, Vector3(-59, 0, -86.4), Vector3(73, 4, 0.4), "snt-forest-bound-n")
	_solid(b, out, Vector3(-59.4, 0, -86.4), Vector3(0.4, 4, 34.4), "snt-forest-bound-w")
	_solid(b, out, Vector3(14, 0, -86.4), Vector3(0.4, 4, 14.4), "snt-forest-bound-e")
	_solid(b, out, Vector3(-59.4, 0, -52), Vector3(13.4, 4, 0.4), "snt-forest-bound-s")
	var trees: Array = []
	for row: Array in [[-8,-74.7],[-22,-74.8],[-38,-74.8],[-42,-82.8],[-48,-83.0],[-48,-70.0],[-48,-61.5],[-57,-69.0],[-20,-85.0],[-28,-80.0]]:
		var x := float(row[0])
		var z := float(row[1])
		trees.append({"x": x, "z": z, "h": 5.8, "w": 0.56})
		_solid(b, out, Vector3(x - 0.24, 0, z - 0.24), Vector3(0.48, 4.0, 0.48), "snt-forest-tree-" + str(x))
	_forest_background(b, out, trees)
	# Калитка у восточного края будки; маршрут не пересекает её старую стену.
	_solid(b, out, Vector3(8.6, 0, -72.12), Vector3(2.0, 1.75, 0.16), "snt-forest-gate")
	var gate := RuralDressing._holder(b, out["nodes"], "snt-forest-gate", Vector3(8.6, 0, -72.04))
	for i in 9:
		RuralDressing._piece(b, gate, Vector3(0.12 + i * 0.235, 0.77, 0), Vector3(0.16, 1.52, 0.07), "boards")
	for y: float in [0.33, 1.19]:
		RuralDressing._piece(b, gate, Vector3(1.08, y, 0.045), Vector3(2.15, 0.10, 0.09), "boards")
	StaticVisualBatch.merge_owner(gate)
	for at: Vector3 in [Vector3(8.55, 0, -72.04), Vector3(10.65, 0, -72.04)]:
		SntWorld._shell(b, at.x - 0.08, at.x + 0.08, 0, 2.0, at.z - 0.08, at.z + 0.08, "boards")
	_sign(b, out, "snt-forest-sign", "СЛУЖЕБНАЯ ТРОПА\n← К 4-Й ЛИНИИ", Vector3(10.6, 2.35, -71.9), 0, 2.4)
	for at: Vector3 in [Vector3(-12, 1.15, -76.8), Vector3(-50.7, 1.15, -65.0), Vector3(-45, 1.15, -55.7)]:
		_sign(b, out, "snt-route-marker-" + str(at.x), "4-я линия\nК Рябовым", at, 0.0, 1.5)
		SntWorld._shell(b, at.x - 0.055, at.x + 0.055, 0, 1.4, at.z - 0.055, at.z + 0.055, "boards")

## Ряды за твёрдым периметром закрывают кромку земли, оставаясь декорацией.
## Готовые локальные card-кроны и их native LOD читаются из ProceduralAssets.
## Новых материалов, текстур и геометрии при каждом кадре здесь нет.
static func _forest_background(b: WorldBuilder, out: Dictionary, foreground: Array) -> void:
	var physics_before := 0
	for set_id in CollisionWorld.SET_COUNT: physics_before += b.col.box_count(set_id)
	SntWorld._shell(b, -83, 39, -0.14, -0.035, -113, -86, "grass", 8)
	SntWorld._shell(b, -83, -59, -0.14, -0.035, -86, -46, "grass", 8)
	SntWorld._shell(b, 14, 39, -0.14, -0.035, -86, -70, "grass", 8)
	var trees: Array = []
	for row: Dictionary in foreground:
		trees.append({"at":Vector3(row["x"],0,row["z"]),"height":row["h"],"width":2.05,"low":false})
	# Смещение рядов и разная высота убирают прямую стенку одинаковых верхушек.
	for band in 3:
		for i in 22:
			var x := -70.0 + float(i)*4.65 + float(band)*1.55
			var z := -87.8 - float(band)*7.3 + sin(float(i)*1.71+band)*1.5
			var h := 6.8 + float(band)*0.85 + 2.0*sin(float(i)*2.11+band)
			trees.append({"at":Vector3(x,-0.035,z),"height":h,"width":3.0+float((i+band)%3)*0.42,"low":true})
		for i in 9:
			var x := -61.7 - float(band)*7.2 + sin(float(i)*2.03+band)*1.1
			var z := -88.0 + float(i)*4.65 + float(band)*1.45
			trees.append({"at":Vector3(x,-0.035,z),"height":6.3+float((i+band)%5)*0.65,
				"width":3.0+float((i+band)%3)*0.40,"low":true})
	for band in 2:
		for i in 5:
			trees.append({"at":Vector3(17.0+band*7.6+sin(i*1.9),-0.035,-89.0+i*4.3+band),
				"height":6.5+float(i%4)*0.7,"width":3.1+float(i%3)*0.3,"low":true})
	var shrubs: Array = []
	for i in 37:
		shrubs.append({"at":Vector3(-62+i*2.2,-0.035,-87.1-sin(i*1.31)*0.65),
			"height":1.7+float(i%4)*0.28,"width":2.7+float(i%3)*0.35,"low":false})
	for i in 17:
		shrubs.append({"at":Vector3(-60.9-sin(i*1.73)*0.5,-0.035,-87+i*2.3),
			"height":1.8+float(i%4)*0.24,"width":2.7+float(i%3)*0.3,"low":false})
	for i in 8:
		shrubs.append({"at":Vector3(15.6+sin(i*1.73)*0.5,-0.035,-88+i*2.1),
			"height":1.8+float(i%3)*0.25,"width":2.7,"low":false})
	var report := {"trees":trees.size(),"shrubs":shrubs.size(),"triangles":0,"surfaces":0,
		"physics_delta":0,"native_lod":true,"material_source":"ProceduralAssets baked cache",
		"placement":"foreground trunks unchanged; additional rows beyond solid perimeter"}
	var groups: Dictionary = {}
	for i in trees.size():
		var variant: int = [2,4,1][i%3]
		_forest_instance(groups,trees[i],"forest/tree",variant,i)
	for i in shrubs.size():
		_forest_instance(groups,shrubs[i],"scatter/nat-bush",-1,i)
	var holder := Node3D.new()
	holder.name = "snt-forest-background"
	b.decor[String(holder.name)] = holder
	for key: String in groups:
		var group: Dictionary = groups[key]
		var pieces: Array = group["pieces"]
		var first: Dictionary = pieces[0]
		var bounds: AABB = first["transform"]*(first["high"] as ArrayMesh).get_aabb()
		for piece: Dictionary in pieces:
			bounds = bounds.merge(piece["transform"]*(piece["high"] as ArrayMesh).get_aabb())
		var center := bounds.get_center()
		var high := SurfaceTool.new()
		var low := SurfaceTool.new()
		high.begin(Mesh.PRIMITIVE_TRIANGLES)
		low.begin(Mesh.PRIMITIVE_TRIANGLES)
		for piece: Dictionary in pieces:
			var xf: Transform3D = piece["transform"]
			xf.origin -= center
			high.append_from(piece["high"],0,xf)
			low.append_from(piece["low"],0,xf)
		var mesh := ProceduralAssets._with_lod(high.commit(),low.commit())
		var node := MeshInstance3D.new()
		node.name = "forest-background-%d" % int(report["surfaces"])
		node.position = center
		node.mesh = mesh
		node.material_override = ProceduralAssets.material(group["material"])
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		# Из проездов деревни дальние ячейки видны сквозь дома и только
		# расходуют кадр. Ближайшие к лесной петле ряды остаются в радиусе60м.
		node.visibility_range_end = 60.0
		node.lod_bias = 0.7
		node.set_meta("forest_background",true)
		holder.add_child(node)
		report["surfaces"] += 1
		report["triangles"] += ProceduralAssets.triangles(mesh)
	var physics_after := 0
	for set_id in CollisionWorld.SET_COUNT: physics_after += b.col.box_count(set_id)
	report["physics_delta"] = physics_after-physics_before
	out["forest_background"] = report
	holder.set_meta("forest_background_report",report)

static func _forest_instance(groups: Dictionary, row: Dictionary, asset: String, variant: int, index: int) -> void:
	var at: Vector3 = row["at"]
	var low := bool(row["low"])
	var basis := Basis(Vector3.UP,float(index)*2.39996)
	var w := float(row["width"])
	basis = basis.scaled(Vector3(w,float(row["height"]),w*(0.85+0.075*float(index%3))))
	var cached := ProceduralAssets.fetch(asset,{"variant":variant} if variant>=0 else {})
	var high_parts: Array = cached["lod_meshes"] if low else cached["meshes"]
	var low_parts: Array = cached["lod_meshes"]
	for part in high_parts.size():
		if (high_parts[part] as ArrayMesh).get_surface_count()==0: continue
		var material := String(cached["material_keys"][part])
		# Варианты берёз, кусты и оба LOD используют общий листовой материал.
		# Их отдельные MultiMesh раздували кадр, хотя ячейка и материал совпадали.
		var key := "%s:%d:%d" % [material,floori(at.x/32.0),floori(at.z/32.0)]
		if not groups.has(key): groups[key] = {"material":material,"pieces":[]}
		(groups[key]["pieces"] as Array).append({"high":high_parts[part],"low":low_parts[part],
			"transform":Transform3D(basis,at)})

static func _solid(b: WorldBuilder, out: Dictionary, at: Vector3, size: Vector3, id: String) -> void:
	SntWorld._solid(b, out, at.x, at.x + size.x, at.y, at.y + size.y, at.z, at.z + size.z, id)
	(out["collision_additions"] as Array).append({"id": id, "aabb": AABB(at, size), "set": CollisionWorld.SET_OVERLAY})

static func graph() -> Dictionary:
	var points: Array[Vector3] = [
		Vector3(19,0,-41.65), Vector3(19,0,-38.3), Vector3(12.2,0,-38.3), Vector3(12.2,0,-53.8),
		Vector3(-20,0,-53.8), Vector3(-20,0,-61.8), Vector3(3.4,0,-61.8), Vector3(3.4,0,-64.1),
		Vector3(7.1,0,-64.1), Vector3(9.6,0,-66.5), RETRY, Vector3(9.6,0,-74.5),
		Vector3(7.1,0,-74.5), Vector3(7.1,0,-78), Vector3(-12,0,-78), Vector3(-12,0,-82),
		Vector3(-34,0,-82), Vector3(-34,0,-78), Vector3(-52,0,-78), Vector3(-52,0,-65),
		Vector3(-55,0,-65), Vector3(-55,0,-54.5), Vector3(-52,0,-54.5), Vector3(-44,0,-54.5),
		Vector3(-26,0,-54.5), Vector3(-26,0,-52), Vector3(-20,0,-52),
		Vector3(36.8,0,-38.3), Vector3(36.8,0,-34.2), Vector3(-28.5,0,-51.0),
	]
	var edges: Array = []
	for i in 26: edges.append([i, i + 1])
	edges.append_array([[14,17],[19,22],[21,22],[26,4],[1,27],[27,28],[24,29]])
	return {"points": points, "edges": edges, "exits": [Vector3(-44,0,-54.5),Vector3(36.8,0,-34.2)],
		"retry": RETRY, "spawn": Vector3(19,0,-41.65), "path_width": 2.2, "max_step": 0.20}

static func _anchors(out: Dictionary) -> void:
	out["scare_anchors"] = {
		"snt-nina-porch": _anchor(Vector3(27.5,0,-40),Vector3.FORWARD,1.0,Vector3(28.67,0,-42),Vector3(29.3,0,-42)),
		"snt-semyon-workshop": _anchor(Vector3(-28.5,0,-51),Vector3.BACK,1.0,Vector3(-27.6,0,-49.25),Vector3(-26.8,0,-49.25)),
		"snt-zuev-window": _anchor(Vector3(9,0.2,-58.35),Vector3.FORWARD,1.3,Vector3(10.75,1.55,-60.21),Vector3(10.75,1.55,-60.20),true),
		"snt-forest-crossing": _anchor(Vector3(7.1,0,-75),Vector3.FORWARD,1.1,Vector3(5.8,0,-76.6),Vector3(8.4,0,-76.6)),
	}
	out["scare_anchors"]["snt-nina-porch"]["prop_node"] = out["nodes"]["snt-nina-shutter"]
	out["scare_anchors"]["snt-nina-porch"]["prop_kind"] = "shutter"
	out["scare_anchors"]["snt-semyon-workshop"]["prop_node"] = out["nodes"]["snt-workshop-bucket"]
	out["scare_anchors"]["snt-semyon-workshop"]["prop_kind"] = "bucket"
	out["scare_anchors"]["snt-semyon-workshop"]["prop_drop"] = 0.48

static func _anchor(at: Vector3, normal: Vector3, half_width: float, from: Vector3, to: Vector3, face := false) -> Dictionary:
	return {"at":at,"normal":normal,"half_width":half_width,"dy":0.6,"from":from,"to":to,
		"sound_at":from+Vector3.UP*0.5,"face":face}

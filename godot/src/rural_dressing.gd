## Дворы, семейства фасадов и дальняя опушка. Геометрия без новых базовых коллизий.
class_name RuralDressing
extends RefCounted

const SAMPLE_ONLY := false
const FAMILIES := ["log", "mansard", "plaster", "garden"]
const WALLS := {"log": "log", "mansard": "siding-grey-old",
	"plaster": "whitewash", "garden": "siding-ochre"}
static var _placement_cache: Array = []

## Общий реестр строится из тех же данных, что стены и физические прокси.
static func placement_registry() -> Array:
	if not _placement_cache.is_empty():
		return _placement_cache.duplicate()
	var out: Array = []
	var site := GameData.site()
	for id: String in (site.get("ROOMS", {}) as Dictionary):
		var room: Dictionary = site["ROOMS"][id]
		if float(room.get("h", 0.0)) > 0.01:
			_register(out, "room:" + id, room.get("x", []), room.get("z", []))
	for h: Dictionary in StreetWorld.data().get("HOUSES", []):
		_register(out, "street:" + String(h.get("id", "")), h.get("x", []), h.get("z", []))
	var office: Dictionary = StreetWorld.data().get("OFFICE", {})
	_register(out, "street:office", office.get("x", []), office.get("z", []))
	var index := 0
	for group: Dictionary in site.get("NEIGHBOURS", []):
		for h: Array in group.get("houses", []):
			var x := float(h[0])
			var z := float(h[1])
			var w := float(h[2])
			var d := float(h[3])
			_register(out, "neighbour:%d" % index, [x-w*0.5,x+w*0.5], [z-d*0.5,z+d*0.5])
			if z > 0.0:
				var shed := neighbour_shed(x, z, w, d)
				out.append({"owner": "rural:shed:%d" % index, "rect": shed})
			index += 1
	# Только строительные ветви: GROUND/OUTER/SECOND_LINE обозначают землю.
	for key: String in ["FARM", "PUMP", "CLUB", "FIELD", "GARDENS", "DUMP"]:
		_register_buildings(out, OutskirtsWorld.data().get(key, {}), "outskirts:" + key)
	for key: String in ["CELLAR_SHED", "BANYA", "GREENHOUSE"]:
		_register_buildings(out, YardWorld.data().get(key, {}), "yard:" + key)
	for p: Dictionary in SntWorld.data().get("PLOTS", []):
		var house: Dictionary = p.get("house", {})
		var id := String(p.get("id", "plot"))
		_register(out, "snt:" + id, house.get("x", []), house.get("z", []))
		if not house.is_empty() and house.get("kind", "locked") != "veranda":
			out.append({"owner": "snt:" + id + ":porch", "rect": SntWorld.porch_rect(house, String(p.get("face", "s")))})
		for e: Dictionary in p.get("extras", []):
			var rect := SntWorld.extra_rect(e)
			if rect.size.x > 0.0:
				out.append({"owner": "snt:" + id + ":" + String(e.get("k", "")), "rect": rect})
		var car: Dictionary = p.get("car", {})
		if not car.is_empty():
			out.append({"owner": "snt:" + id + ":car", "rect": StreetWorld._tree_rect(VehicleVisuals.world_box(car))})
	for house: Dictionary in SntWorld.data().get("INSIDE", []):
		_register(out, "snt:" + String(house.get("id", "inside")), house.get("x", []), house.get("z", []))
	for prop: Dictionary in GameData.props().get("PROPS", []):
		if prop.get("col", null) is bool and prop["col"] == false:
			continue
		var name := String(prop.get("m", prop.get("make", "")))
		if name in ["tree", "tree-tall", "tree-autumn"]:
			continue
		var dims: Variant = prop.get("col", null)
		if not dims is Array:
			dims = {"waterBarrel": [0.70,0.90,0.70], "box-large": [1.2,0.8,1.2],
				"box-large-open": [1.2,0.8,1.2], "barrel": [0.7,0.9,0.7], "barrel-open": [0.7,0.9,0.7]}.get(name, [])
		var at: Array = prop.get("at", [])
		if (dims as Array).size() != 3 or at.size() != 3 or float(at[1]) > 2.0:
			continue
		var yaw := float(prop.get("ry", 0.0))
		var hx := (absf(cos(yaw))*float(dims[0]) + absf(sin(yaw))*float(dims[2]))*0.5
		var hz := (absf(sin(yaw))*float(dims[0]) + absf(cos(yaw))*float(dims[2]))*0.5
		_register(out, "prop:" + String(prop.get("id", name)), [float(at[0])-hx,float(at[0])+hx], [float(at[2])-hz,float(at[2])+hz])
	var nav_file := FileAccess.open("res://data/nav_baked.json", FileAccess.READ)
	if nav_file != null:
		var nav: Variant = JSON.parse_string(nav_file.get_as_text())
		if nav is Dictionary:
			var nodes: Dictionary = {}
			for node: Dictionary in nav.get("nodes", []):
				if String(node.get("layer", "")) == "plot":
					nodes[String(node["id"])] = node
			for id: String in nodes:
				var n: Dictionary = nodes[id]
				var a := Vector2(float(n["x"]), float(n["z"]))
				out.append({"owner": id, "kind": "nav", "rect": Rect2(a-Vector2.ONE*0.01,Vector2.ONE*0.02)})
				for edge: Dictionary in n.get("edges", []):
					var to := String(edge.get("to", ""))
					if not nodes.has(to) or id >= to:
						continue
					var dest: Dictionary = nodes[to]
					var c := Vector2(float(dest["x"]), float(dest["z"]))
					# Тонкий bounding rect точен для осевых рёбер, диагональ сэмплируем.
					var samples := maxi(1, ceili(a.distance_to(c)/0.20))
					for sample in range(samples+1):
						var point := a.lerp(c,float(sample)/float(samples))
						out.append({"owner": id+"->"+to, "kind": "nav", "rect": Rect2(point-Vector2.ONE*0.01,Vector2.ONE*0.02)})
	_placement_cache = out
	return out.duplicate()

static func _register(out: Array, id: String, xr: Array, zr: Array) -> void:
	if xr.size() == 2 and zr.size() == 2:
		out.append({"owner": id, "rect": StreetWorld._tree_rect([xr[0],xr[1],zr[0],zr[1]])})

static func _register_buildings(out: Array, value: Variant, id: String) -> void:
	if value is Dictionary:
		var cfg: Dictionary = value
		var box: Array = cfg.get("box", [])
		if box.size() == 4:
			out.append({"owner": id, "rect": StreetWorld._tree_rect(box)})
		if cfg.get("x", null) is Array and cfg.get("z", null) is Array:
			_register(out, id, cfg["x"], cfg["z"])
		for key: String in cfg:
			if cfg[key] is Dictionary or cfg[key] is Array:
				_register_buildings(out, cfg[key], id+":"+key)
	elif value is Array:
		for i in (value as Array).size():
			if value[i] is Dictionary:
				_register_buildings(out, value[i], id+":"+str(i))

static func neighbour_shed(x: float, z: float, w: float, d: float) -> Rect2:
	var back := z + d*0.5 + 2.8
	var side := x + (-1.0 if x < 0.0 else 1.0)*(w*0.5+1.7)
	return Rect2(side-0.9,back-1.0,1.8,2.0)

static func family(index: int) -> String:
	return FAMILIES[posmod(index, FAMILIES.size())]

static func wall_material(kind: String) -> String:
	return String(WALLS.get(kind, "neighbour"))

static func build(b: WorldBuilder) -> Dictionary:
	var count := 0
	for group: Dictionary in b.site.get("NEIGHBOURS", []):
		for h: Array in group.get("houses", []):
			var index := count
			count += 1
			if SAMPLE_ONLY and index > 3 and index != 6:
				continue
			var x := float(h[0])
			var z := float(h[1])
			var w := float(h[2])
			var d := float(h[3])
			var eave := float(h[4])
			var rebuilt := (OutskirtsWorld.data().get("SECOND_LINE",{}).get("houses",{}) as Dictionary).has(str(index))
			var details := b.skin_begin("buildings","outskirts" if rebuilt else "site","",
				("SECOND_LINE-" if rebuilt else "NEIGHBOURS-")+str(index))
			house_details(b, Rect2(x - w / 2.0, z - d / 2.0, w, d),
				eave, family(index), "neighbour-%02d" % index)
			b.skin_end(details)
			if z > 0.0:
				var yard_mark := b.skin_begin("interiors","environment","yard-neighbour-%02d" % index)
				_near_yard(b, x, z, w, d, index)
				b.skin_end(yard_mark)
				var fence_mark := b.skin_begin("fences","environment","yard-neighbour-%02d" % index)
				_near_yard_boundary(b,x,z,w,d)
				b.skin_end(fence_mark)
	var landscape := EnvironmentLandscape.build(b)
	_shop_goods(b)
	return {"neighbours": mini(count, 5) if SAMPLE_ONLY else count,
		"far_draw_calls": landscape["far_draw_calls"], "far_triangles": landscape["far_triangles"],
		"landscape":landscape, "sample": SAMPLE_ONLY}

static func _shop_goods(b: WorldBuilder) -> void:
	var shop: Dictionary = VillageWorld.data().get("SHOP", {})
	var shelves: Array = shop.get("shelves", [])
	if shelves.size() != 4:
		return
	var floor_y := float(shop.get("floor", 0.14))
	var mark := b.skin_begin("details", "village", "shop-goods")
	# Бумажные этикетки и крышки используют уже существующие бакеты сельпо.
	for i in 11:
		var x := float(shelves[0])+0.57+float(i)*0.62
		var y := floor_y+0.80+float(i%3)*0.60
		var z := float(shelves[3])-0.055
		_box(b,Vector3(x,y,z),Vector3(0.21,0.14,0.014),"trim" if i%3 else "fabric")
		_box(b,Vector3(x,y-0.018,z+0.01),Vector3(0.12,0.012,0.008),"dark")
		_box(b,Vector3(x,y+0.128,z-0.10),Vector3(0.31,0.012,0.21),"metal")
	for i in 6:
		var can := CylinderMesh.new()
		can.top_radius = 0.072
		can.bottom_radius = 0.072
		can.height = 0.20+float(i%2)*0.045
		can.radial_segments = 6
		can.rings = 1
		var at := Vector3(float(shelves[0])+0.94+float(i)*1.14,
			floor_y+0.67+float((i+1)%3)*0.60+can.height*0.5,float(shelves[3])-0.12)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.append_from(can,0,Transform3D(Basis.IDENTITY,at))
		b.append_mesh("metal",st.commit())
		_box(b,at+Vector3(0,0,0.074),Vector3(0.09,0.095,0.008),"fabric")
	b.skin_end(mark)

static func house_details(b: WorldBuilder, rect: Rect2, eave: float,
		kind: String, id: String, face := "s") -> void:
	var x0 := rect.position.x
	var x1 := rect.end.x
	var z0 := rect.position.y
	var z1 := rect.end.y
	var variant := house_variant(id)
	# Низ стены темнеет от брызг; водосток и отмостка привязаны к углу.
	for zz: float in [z0 - 0.025, z1 + 0.025]:
		_box(b, Vector3((x0 + x1) * 0.5, 0.19, zz),
			Vector3(rect.size.x, 0.24, 0.035), "plinth")
	_box(b, Vector3(x1 + 0.065, eave * 0.5, z0 + 0.14),
		Vector3(0.085, eave, 0.085), "metal")
	_box(b, Vector3(x1 + 0.06, 0.075, z0 + 0.14),
		Vector3(0.45, 0.07, 0.48), "dirt")
	for zz: float in [z0 - 0.09, z1 + 0.09]:
		_box(b, Vector3((x0 + x1) * 0.5, eave - 0.06, zz),
			Vector3(rect.size.x + 0.20, 0.11, 0.12), "trim")
	for xx: float in [x0 - 0.025, x1 + 0.025]:
		_box(b, Vector3(xx,0.18,(z0+z1)*0.5),Vector3(0.035,0.22,rect.size.y),"plinth")
		if (face == "e" and xx>x1) or (face == "w" and xx<x0):
			continue
		# Торцы видны при обходе дома: подоконник, старая рама, четыре стёкла.
		var wx := xx + (-0.035 if xx < x0 else 0.035)
		var wz := lerpf(z0,z1,0.34+0.13*float(variant))
		_box(b,Vector3(wx,1.53,wz),Vector3(0.055,0.83,0.93),"trim")
		_box(b,Vector3(wx+(-0.033 if xx < x0 else 0.033),1.53,wz),Vector3(0.03,0.67,0.77),"dark")
		_box(b,Vector3(wx+(-0.05 if xx < x0 else 0.05),1.53,wz),Vector3(0.035,0.67,0.045),"trim")
		_box(b,Vector3(wx+(-0.05 if xx < x0 else 0.05),1.53,wz),Vector3(0.035,0.045,0.77),"trim")
		_box(b,Vector3(wx,1.07,wz),Vector3(0.20,0.055,1.04),"tin")
	# Ремонтная заплата меняет положение между тремя версиями одного семейства.
	var repair_x := lerpf(x0,x1,0.26+0.21*float(variant))
	_box(b,Vector3(repair_x,0.57,z0-0.028),Vector3(0.38+0.08*variant,0.14,0.038),
		"brick" if kind == "plaster" else "boards")
	_box(b,Vector3((x0+x1)*0.5,0.012,z0-0.19),Vector3(rect.size.x+0.30,0.018,0.30),"dirt")
	var back_z := z1+0.05 if face == "n" else z0-0.05
	var outward := 1.0 if face == "n" else -1.0
	_box(b,Vector3((x0+x1)*0.5,1.49,back_z),Vector3(0.86,0.77,0.06),"trim")
	_box(b,Vector3((x0+x1)*0.5,1.49,back_z+outward*0.042),Vector3(0.69,0.61,0.034),"dark")
	_box(b,Vector3((x0+x1)*0.5,1.49,back_z+outward*0.06),Vector3(0.044,0.61,0.04),"trim")
	match kind:
		"log":
			# Выступы торцов венцов дают срубу объём при сохранении общей сетки.
			for y in range(1, 6):
				for xx: float in [x0 + 0.10, x1 - 0.10]:
					for zz: float in [z0 - 0.07, z1 + 0.07]:
						_box(b, Vector3(xx, float(y) * (eave-0.20)/6.0, zz),
							Vector3(0.25, 0.15, 0.22), "log")
		"mansard":
			# Торцевое окно под коньком, наличник и слуховая створка.
			for xx: float in [x0 - 0.072, x1 + 0.072]:
				_box(b, Vector3(xx, eave + 0.40, (z0 + z1) * 0.5),
					Vector3(0.035, 0.64, 0.78), "trim")
				_box(b, Vector3(xx + (-0.025 if xx < x0 else 0.025),
					eave + 0.40, (z0 + z1) * 0.5), Vector3(0.028, 0.47, 0.58), "dark")
		"plaster":
			for xx: float in [x0 + 0.12, x1 - 0.12]:
				for zz: float in [z0 - 0.025, z1 + 0.025]:
					_box(b, Vector3(xx, 0.62, zz), Vector3(0.20, 0.14, 0.04), "brick")
		"garden":
			for xx: float in [x0 + 0.06, x1 - 0.06]:
				_box(b, Vector3(xx, eave * 0.5, z1 + 0.04),
					Vector3(0.13, eave, 0.07), "trim")
	# Короткий дымоход с колпаком; никаких новых теневых источников.
	var chimney_x := x0 + rect.size.x * (0.24+0.17*float(variant))
	_box(b, Vector3(chimney_x, eave + 1.15, (z0 + z1) * 0.5),
		Vector3(0.34, 1.05, 0.38), "brick")
	_box(b, Vector3(chimney_x, eave + 1.70, (z0 + z1) * 0.5),
		Vector3(0.48, 0.08, 0.52), "tin")
	var marker := Node3D.new()
	marker.name = "rural-house:" + id
	marker.set_meta("family",kind)
	marker.set_meta("variant",variant)
	marker.set_meta("footprint",rect)
	b.decor[marker.name] = marker

static func house_variant(id: String) -> int:
	return posmod(int(id.trim_prefix("p")) if id.begins_with("p") else int(id.get_slice("-",1)),3)

static func _near_yard(b: WorldBuilder, x: float, z: float, w: float,
		d: float, index: int) -> void:
	var shed := neighbour_shed(x,z,w,d)
	var back := shed.get_center().y
	var side := shed.get_center().x
	_garden(b, Vector2(x, back), 3.5, 2.1, index)
	# Сарайчик во дворе соседа виден с балкона поверх ограды.
	_box(b, Vector3(side, 0.9, back), Vector3(1.8, 1.8, 2.0), "shedwood")
	b._slope(side - 1.04, side + 1.04, back - 1.13, back + 1.13,
		2.02, 1.83, "neighbourroof", 0.08, false)
	_box(b, Vector3(side, 0.78, back - 1.015), Vector3(0.74, 1.55, 0.04), "dark")
	# Два невысоких плодовых дерева используют общий существующий MultiMesh.
	StreetWorld.add_low_poly_trees(b, "rural-orchard-%d" % index, [
		{"x": x - w * 0.33, "z": back + 2.8, "h": 3.4, "w": 1.0, "kind": "orchard"},
		{"x": x + w * 0.35, "z": back + 3.3, "h": 3.8, "w": 1.1, "kind": "orchard"}])

static func _near_yard_boundary(b: WorldBuilder,x: float,z: float,w: float,d: float) -> void:
	var side := neighbour_shed(x,z,w,d).get_center().x
	# Забор с двумя прожилинами замыкает боковую границу, не выходит на улицу.
	for yy: float in [0.45, 0.92]:
		_box(b, Vector3(side + 1.25, yy, z + d * 0.5 + 2.6),
			Vector3(0.075, 0.09, 7.0), "boards")
	for k in 5:
		_box(b, Vector3(side + 1.25, 0.62, z + d * 0.5 - 0.7 + float(k) * 1.65),
			Vector3(0.10, 1.24, 0.10), "boards")

static func plot_details(b: WorldBuilder, p: Dictionary) -> void:
	var id := String(p.get("id", ""))
	if SAMPLE_ONLY and id != "p01":
		return
	var h: Dictionary = p.get("house", {})
	var hx: Array = h.get("x", [])
	var hz: Array = h.get("z", [])
	if hx.size() != 2 or hz.size() != 2:
		return
	var rect := Rect2(float(hx[0]), float(hz[0]),
		float(hx[1]) - float(hx[0]), float(hz[1]) - float(hz[0]))
	var house_mark := b.skin_begin("buildings","snt",id,"PLOTS")
	house_details(b, rect, float(h.get("eave", 2.75)),
		String(h.get("family", "log" if id == "p01" else "garden")), id, String(p.get("face", "s")))
	b.skin_end(house_mark)
	var px: Array = p["x"]
	var pz: Array = p["z"]
	var width := float(px[1]) - float(px[0])
	var depth := float(pz[1]) - float(pz[0])
	# Грядки не пересекают калитку и полосу от калитки к крыльцу.
	if width >= 6.0 and depth >= 8.0:
		_garden(b, Vector2(float(px[0]) + 0.73, (float(pz[0]) + float(pz[1])) * 0.5),
			0.75, depth - 2.0, int(id.trim_prefix("p")))
	_number(b, p)

static func _garden(b: WorldBuilder, at: Vector2, w: float, d: float, seed: int) -> void:
	for k in 3:
		var xx := at.x - w * 0.5 + w * (float(k) + 0.5) / 3.0
		_box(b, Vector3(xx, 0.045, at.y), Vector3(w * 0.22, 0.08, d), "dirt")
		for j in 4:
			var zz := at.y - d * 0.5 + d * (float(j) + 0.5) / 4.0
			_box(b, Vector3(xx, 0.14, zz),
				Vector3(w * 0.12, 0.16 + 0.03 * float((seed + j) % 3), 0.24), "grass")

static func _number(b: WorldBuilder, p: Dictionary) -> void:
	var face := String(p.get("face", "s"))
	var px: Array = p["x"]
	var pz: Array = p["z"]
	var along := float(px[0]) + 0.50
	var point := Vector3(along, 1.0, float(pz[1]) + 0.055)
	var basis := Basis()
	if face == "n":
		point.z = float(pz[0]) - 0.055
		basis = Basis(Vector3.UP, PI)
	elif face == "e" or face == "w":
		point = Vector3(float(px[1]) + 0.055 if face == "e" else float(px[0]) - 0.055,
			1.0, float(pz[0]) + 0.6)
		basis = Basis(Vector3.UP, PI * 0.5 if face == "e" else -PI * 0.5)
	b._emit_rot_box("trim", point, Vector3(0.22, 0.14, 0.025), basis, 1, 1, 1)
	var digits := String(p.get("id", "p00")).trim_prefix("p")
	var patterns := ["111101101101111", "010110010010111", "111001111100111",
		"111001111001111", "101101111001001", "111100111001111",
		"111100111101111", "111001001001001", "111101111101111", "111101111001111"]
	for digit in digits.length():
		var pattern: String = patterns[int(digits[digit])]
		for pixel in 15:
			if pattern[pixel] != "1":
				continue
			var local := Vector3(-0.16 + float(digit) * 0.19 + float(pixel % 3) * 0.043,
				0.086 - float(pixel / 3) * 0.043, 0.030)
			b._emit_rot_box("dark", point + basis * local, Vector3(0.018, 0.018, 0.008),
				basis, 1, 1, 1)

static func quest_props(b: WorldBuilder, out: Dictionary) -> void:
	var q := {
		"watch_log": Vector3(4.35, 0.82, -38.65),
		"yard_inspect": Vector3(20.35, 0.66, -42.96),
		"signal": Vector3(8.07, 1.3, -67.75),
		"return_inspect": Vector3(19.15, 0.3, -42.30),
		"silhouette": Vector3(8.07, 0.0, -70.1),
		"office_echo": Vector3(4.35, 1.85, -41.065),
		"last_round": Vector3(-15.20, 0.50, -39.05),
		"water_marks": Vector3(-1.40, 0.55, -40.63),
		"ring_initial": Vector3(20.35, 0.66, -42.96),
		"ring_return": Vector3(19.48, 0.28, -42.65),
		"ring_initial_rotation": Vector3(PI * 0.5, 0.0, 0.0),
		"ring_return_rotation": Vector3.ZERO,
		"gate_closed": -1.05, "gate_open": -2.2,
	}
	out["quest"] = q
	var nodes: Dictionary = out["nodes"]
	var gate := _holder(b, nodes, "snt-p01-gate", Vector3(18.3, 0.0, -41.0))
	for k in 6:
		_piece(b, gate, Vector3(0.095 + float(k) * 0.21, 0.58, 0.0),
			Vector3(0.16, 1.1, 0.055), "boards")
	for y: float in [0.30, 0.86]:
		_piece(b, gate, Vector3(0.62, y, 0.035), Vector3(1.30, 0.085, 0.06), "boards")
	gate.rotation.y = float(q["gate_closed"])
	preload("res://src/static_visual_batch.gd").merge_owner(gate)
	var ring := _holder(b, nodes, "snt-p01-ring", q["ring_initial"])
	var torus := TorusMesh.new()
	torus.inner_radius = 0.26
	torus.outer_radius = 0.44
	torus.rings = 16
	torus.ring_segments = 6
	torus.material = b.mats.flat(0xc26b42, true)
	var ring_mesh := MeshInstance3D.new()
	ring_mesh.mesh = torus
	ring_mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	ring.add_child(ring_mesh)
	ring.rotation = q["ring_initial_rotation"]
	var tracks := _holder(b, nodes, "snt-p01-traces", Vector3.ZERO)
	for k in 8:
		_piece(b, tracks, Vector3(19.0 + (-0.12 if k % 2 == 0 else 0.12), 0.023,
			-41.15 - float(k) * 0.16), Vector3(0.11, 0.012, 0.22), "dark")
	preload("res://src/static_visual_batch.gd").merge_owner(tracks)
	tracks.visible = false
	var handle := _holder(b, nodes, "snt-signal-handle", q["signal"])
	_piece(b, handle, Vector3(0.0, 0.0, 0.0), Vector3(0.06, 0.33, 0.07), "metal")
	_piece(b, handle, Vector3(0.09, -0.16, 0.0), Vector3(0.18, 0.07, 0.08), "boards")
	preload("res://src/static_visual_batch.gd").merge_owner(handle)
	_box(b, Vector3(8.07, 1.24, -67.84), Vector3(0.40, 0.55, 0.10), "visual:counter")
	_box(b, Vector3(4.35, 0.74, -38.65), Vector3(1.4, 0.12, 0.76), "boards")
	for xx: float in [3.78, 4.92]:
		for zz: float in [-38.93, -38.37]:
			_box(b, Vector3(xx, 0.34, zz), Vector3(0.08, 0.68, 0.08), "boards")
	_box(b, q["watch_log"], Vector3(0.44, 0.026, 0.34), "fabric")
	_box(b, Vector3(4.35, 0.839, -38.65), Vector3(0.39, 0.01, 0.29), "trim")
	_box(b, Vector3(19.0, 0.02, -42.0), Vector3(0.80, 0.025, 1.85), "dirt")
	_box(b, Vector3(-1.4, 0.62, -40.67), Vector3(0.10, 1.24, 0.10), "boards")
	for k in 4:
		_box(b, Vector3(-1.4, 0.24 + float(k) * 0.15, -40.63),
			Vector3(0.12 + float(k % 2) * 0.04, 0.028, 0.04), "trim")
	_box(b, Vector3(-15.20, 0.18, -39.05), Vector3(0.5, 0.31, 0.44), "fabric")
	_sign(b, "snt-sign-third", "3-я линия\n← Правление СНТ", Vector3(34.6, 1.7, -37.3), 0.0)
	_sign(b, "snt-sign-fourth", "← 4-я линия\nСлужебный сигнал", Vector3(11.3, 1.8, -51.2), 0.0)
	_sign(b, "snt-sign-bend-west", "Сигнал  →", Vector3(-22.45, 1.7, -55.9), PI * 0.5)
	_sign(b, "snt-sign-bend-north", "Сигнал  →", Vector3(-21.2, 1.7, -63.4), 0.0)
	_sign(b, "snt-sign-signal", "СИГНАЛЬНЫЙ ПОСТ\nРучной привод", Vector3(6.0, 2.12, -69.14), 0.0)
	_sign(b, "snt-sign-office", "ПРАВЛЕНИЕ\nЖурнал обходов", Vector3(5.90, 1.70, -35.95), 0.0)

	_box(b, Vector3(8.07, 0.675, -67.84), Vector3(0.12, 1.35, 0.12), "visual:boards")
	SntWorld._solid(b, out, 8.01, 8.13, 0.0, 1.35, -67.90, -67.78, "snt-signal-post")
	_box(b, Vector3(19.98, 1.57, -43.025), Vector3(0.24, 0.65, 0.018), "fabric")
	_box(b, Vector3(20.48, 1.30, -43.026), Vector3(0.65, 0.065, 0.02), "boards")
	_office_bell(b)
	_watch_details(b, out)

static func _sign(b: WorldBuilder, id: String, caption: String, at: Vector3, yaw: float) -> void:
	var root := Node3D.new()
	root.name = id
	root.position = at
	root.rotation.y = yaw
	var label := Label3D.new()
	label.text = caption
	label.font_size = 40
	label.pixel_size = 0.0055
	label.outline_size = 3
	label.modulate = Color(0.82, 0.81, 0.69)
	label.no_depth_test = false
	label.shaded = true
	label.visibility_range_end = 30.0
	root.add_child(label)
	_piece(b, root, Vector3(0, 0, -0.06), Vector3(2.1, 0.68, 0.07), "boards")
	if id == "snt-sign-third" or id == "snt-sign-fourth" or id.begins_with("snt-sign-bend"):
		_piece(b, root, Vector3(0, -at.y * 0.5, -0.10), Vector3(0.09, at.y, 0.09), "boards")
	b.decor[id] = root

static func _holder(b: WorldBuilder, nodes: Dictionary, id: String, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = id
	n.position = at
	b.decor[id] = n
	nodes[id] = n
	return n

static func _piece(b: WorldBuilder, parent: Node3D, at: Vector3,
		size: Vector3, key: String) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = b.mats.get_mat(key)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visibility_range_end = 40.0
	parent.add_child(mi)

static func _box(b: WorldBuilder, at: Vector3, size: Vector3, key: String) -> void:
	b.box(at.x - size.x * 0.5, at.x + size.x * 0.5,
		at.y - size.y * 0.5, at.y + size.y * 0.5,
		at.z - size.z * 0.5, at.z + size.z * 0.5, key, 0.0, false)

static func _watch_details(b: WorldBuilder, out: Dictionary) -> void:
	var nodes: Dictionary = out["nodes"]
	var bench := Vector3(20.9, 0.43, -42.1)
	_box(b, bench, Vector3(1.30, 0.06, 0.40), "boards")
	for x: float in [20.36, 21.44]:
		_box(b, Vector3(x, 0.20, -42.1), Vector3(0.09, 0.40, 0.32), "boards")
	SntWorld._solid(b, out, 20.25, 21.55, 0.0, 0.46, -42.30, -41.90, "p01-watch-bench")
	SntWorld._solid(b, out, 3.65, 5.05, 0.0, 0.80, -39.03, -38.27, "snt-watch-table")
	var mug := _holder(b, nodes, "snt-p01-mug", Vector3(20.65, 0.52, -42.1))
	var cup := CylinderMesh.new()
	cup.top_radius = 0.067
	cup.bottom_radius = 0.052
	cup.height = 0.12
	cup.radial_segments = 10
	cup.rings = 1
	cup.material = b.mats.get_mat("trim")
	var cm := MeshInstance3D.new()
	cm.mesh = cup
	cm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mug.add_child(cm)
	var inner := CylinderMesh.new()
	inner.top_radius = 0.057
	inner.bottom_radius = 0.057
	inner.height = 0.007
	inner.radial_segments = 10
	inner.rings = 1
	inner.material = b.mats.get_mat("dark")
	var im := MeshInstance3D.new()
	im.mesh = inner
	im.position.y = 0.062
	im.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mug.add_child(im)
	var grip := TorusMesh.new()
	grip.inner_radius = 0.022
	grip.outer_radius = 0.038
	grip.rings = 10
	grip.ring_segments = 5
	grip.material = b.mats.get_mat("trim")
	var gm := MeshInstance3D.new()
	gm.mesh = grip
	gm.position = Vector3(0, 0.0, 0.072)
	gm.rotation.z = PI * 0.5
	gm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mug.add_child(gm)
	preload("res://src/static_visual_batch.gd").merge_owner(mug)
	_box(b, Vector3(21.05, 0.48, -42.08), Vector3(0.13, 0.025, 0.08), "trim")
	_box(b, Vector3(21.12, 0.488, -42.08), Vector3(0.09, 0.018, 0.074), "boards")
	for k in 4:
		_box(b, Vector3(21.04 + float(k) * 0.015, 0.494, -42.07),
			Vector3(0.007, 0.006, 0.08), "boards")
	_box(b, Vector3(21.1, 1.80, -42.95), Vector3(2.2, 0.012, 0.012), "fabric")
	var glove := _holder(b, nodes, "snt-p01-glove", Vector3(21.20, 1.67, -42.95))
	_piece(b, glove, Vector3.ZERO, Vector3(0.10, 0.14, 0.024), "fabric")
	for k in 4:
		_piece(b, glove, Vector3(-0.039 + float(k) * 0.027, 0.094, 0.0),
			Vector3(0.021, 0.05 + float(k % 2) * 0.014, 0.026), "fabric")
	_piece(b, glove, Vector3(-0.068, 0.025, 0), Vector3(0.045, 0.044, 0.026), "fabric")
	preload("res://src/static_visual_batch.gd").merge_owner(glove)
	var first := _holder(b, nodes, "snt-p01-first-tracks", Vector3.ZERO)
	for x: float in [18.88, 19.14]:
		_piece(b, first, Vector3(x, 0.021, -41.16), Vector3(0.11, 0.011, 0.25), "dark")
	preload("res://src/static_visual_batch.gd").merge_owner(first)
	var tag_at := Vector3(20.92, 1.07, -42.955)
	_box(b, tag_at, Vector3(0.27, 0.40, 0.018), "boards")
	for k in 5:
		_box(b, tag_at + Vector3(0.0, 0.13 - float(k) * 0.063, 0.013),
			Vector3(0.16, 0.009, 0.008), "dark")
	var cross := _holder(b, nodes, "snt-p01-tag-cross", tag_at + Vector3(0, 0, 0.026))
	_piece(b, cross, Vector3.ZERO, Vector3(0.012, 0.36, 0.008), "dark")
	(cross.get_child(0) as Node3D).rotation.z = -0.50
	cross.visible = false
	# Светлая верёвка и узел на спасательном круге.
	var ring: Node3D = nodes["snt-p01-ring"]
	_piece(b, ring, Vector3(0.36, 0.0, 0.0), Vector3(0.11, 0.07, 0.07), "trim")
	_piece(b, ring, Vector3(0.43, 0.0, -0.07), Vector3(0.035, 0.025, 0.18), "fabric")
	# Плащ, фонарь, сухая рукавица и пустой крючок в дровянике.
	for k in 3:
		_box(b, Vector3(-15.2, 0.24 + float(k) * 0.10, -39.05),
			Vector3(0.64 - float(k) * 0.09, 0.085, 0.40), "fabric")
	_box(b, Vector3(-14.75, 0.21, -39.04), Vector3(0.18, 0.31, 0.15), "metal")
	_box(b, Vector3(-14.75, 0.27, -38.958), Vector3(0.12, 0.13, 0.015), "dark")
	_box(b, Vector3(-15.58, 0.11, -39.03), Vector3(0.12, 0.08, 0.20), "fabric")
	_box(b, Vector3(-15.2, 1.4, -40.34), Vector3(0.12, 0.05, 0.16), "metal")
	_box(b, Vector3(-15.2, 1.22, -40.325), Vector3(0.24, 0.16, 0.018), "trim")
	_box(b, Vector3(-15.21, 0.45, -39.06), Vector3(0.19, 0.008, 0.13), "trim")
	# Рейка у мостков: деления остаются над мелководьем.
	_box(b, Vector3(-1.24, 0.15, -41.4), Vector3(0.12, 0.025, 1.55), "boards")
	for k in 7:
		_box(b, Vector3(-1.24, 0.17, -40.76 - float(k) * 0.20),
			Vector3(0.12, 0.005, 0.022), "trim")

static func _office_bell(b: WorldBuilder) -> void:
	_box(b, Vector3(4.35, 1.78, -41.13), Vector3(0.30, 0.38, 0.055), "boards")
	var dome := CylinderMesh.new()
	dome.top_radius = 0.115
	dome.bottom_radius = 0.13
	dome.height = 0.08
	dome.radial_segments = 12
	dome.rings = 1
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	st.append_from(dome, 0, Transform3D(Basis(Vector3.RIGHT, PI * 0.5),
		Vector3(4.35, 1.85, -41.065)))
	b.append_mesh("metal", st.commit())
	_box(b, Vector3(4.35, 1.67, -41.04), Vector3(0.035, 0.15, 0.05), "metal")

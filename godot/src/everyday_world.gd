class_name EverydayWorld
extends RefCounted

# Отдельные владельцы нужны петлям. Статические детали объединяются внутри
# своего владельца и не попадают в заменяемые скином оболочки домов.
static func build(root: Node3D, mats: Materials, col: CollisionWorld, built: Dictionary) -> Dictionary:
	var out := {"enabled": true, "nodes": {}, "targets": {}, "definitions": []}
	var holder := Node3D.new()
	holder.name = "EverydayDecor"
	root.add_child(holder)
	out["root"] = holder
	_cabinet(holder, mats, out, "decor-shed-cabinet", Vector3(5.30, 0.12, 11.70), -PI * 0.5)
	_notice(holder, mats, out, "decor-board-notice", Vector3(-31.50, 1.5, -7.30),
		"ПРАВЛЕНИЕ", ["Правление СНТ\n\nВ субботу, 16 августа, ремонтируем настил у водокачки. Начало в десять. У кого есть молоток и гвозди, приносите. Доски оставлены под навесом.\n\nПредседатель. 11.08.2003"])
	_notice(holder, mats, out, "decor-club-notice", Vector3(10.45, 1.55, -26.82),
		"КЛУБ", ["Объявление\n\nМашина за мусором придёт в пятницу утром. Мешки складывать у въезда, справа от будки. Ветки и строительный мусор водитель не забирает.\n\nПосле кино стулья ставить к стене. Ключ сдавать в правление."])
	if not (built.get("snt", {}) as Dictionary).is_empty():
		for p: Dictionary in SntWorld.data().get("PLOTS", []):
			if String(p.get("id", "")) in ["p02", "p03", "p07", "p10", "p14"]:
				_gate(holder, mats, col, out, p)
		_cabinet(holder, mats, out, "decor-snt-cabinet", Vector3(-16.35, 0, -40.16), PI)
		var bare_metal := _pump_paint(mats, false)
		_barrel(holder, mats, out, bare_metal)
		_pump(holder, mats, out)
		_radio(holder, mats, out, bare_metal)
		_notice(holder, mats, out, "decor-snt-entry-notice", Vector3(34.55, 1.55, -34.25),
			"СНТ «ВОСХОД»", ["СНТ «ВОСХОД»\n\nПроезд оставлять свободным. Калитки за собой прикрывать. Объявления о поливе вывешивают у правления."])
	return out


static func _owner(parent: Node3D, out: Dictionary, id: String, at: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = id
	n.position = at
	parent.add_child(n)
	(out["nodes"] as Dictionary)[id] = n
	return n


static func _box(parent: Node3D, mats: Materials, at: Vector3, size: Vector3, key: String) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	mesh.material = mats.get_mat(key)
	var n := MeshInstance3D.new()
	n.mesh = mesh
	n.position = at
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(n)
	return n


static func _cylinder(parent: Node3D, mats: Materials, at: Vector3, radius: float,
		height: float, key: String, segments := 12) -> MeshInstance3D:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = height
	mesh.radial_segments = segments
	if segments < 12: mesh.rings = 0
	mesh.material = mats.get_mat(key)
	var n := MeshInstance3D.new()
	n.mesh = mesh
	n.position = at
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(n)
	return n


static func _finish(owner: Node3D) -> void:
	StaticVisualBatch.merge_owner(owner)
	var top: Node = owner
	while top.get_parent() != null and not String(top.name).begins_with("decor-"):
		top = top.get_parent()
	# Moving leaves retain their own pivots and blockers. Small contents and
	# text do not need a separate GPU surface from the far end of the village.
	var distance := 34.0 if String(top.name).begins_with("decor-gate-") else 18.0
	var pending: Array[Node] = [owner]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		pending.append_array(node.get_children())
		if node is GeometryInstance3D:
			node.visibility_range_end = distance
			node.visibility_range_end_margin = 1.0
			node.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED


static func _define(out: Dictionary, id: String, kind: String, owner: Node3D,
		point: Vector3, moving: Node3D = null) -> Dictionary:
	var d := {"id": id, "kind": kind, "owner": owner, "point": point,
		"flag": "" if kind in ["pump", "radio"] else id + ("-read" if kind == "notice" else "-open"),
		"seconds": 1.0 if kind == "pump" else 0.6}
	if moving != null: d["moving"] = moving
	(out["definitions"] as Array).append(d)
	(out["targets"] as Dictionary)[id] = point
	return d


static func _gate(parent: Node3D, mats: Materials, col: CollisionWorld, out: Dictionary, p: Dictionary) -> void:
	var id := "decor-gate-" + String(p["id"])
	var wk: Array = p["wicket"]
	var north := String(p["face"]) == "n"
	var z := float(p["z"][0]) + 0.04 if north else float(p["z"][1]) - 0.04
	var x := float(wk[0])
	var width := float(wk[1]) - x
	var hinge := Vector3(x, 0, z)
	var owner := _owner(parent, out, id, hinge)
	var leaf := Node3D.new()
	leaf.name = "leaf"
	owner.add_child(leaf)
	for k in 7:
		_box(leaf, mats, Vector3(0.10 + float(k) * (width - 0.20) / 6.0, 0.60, 0),
			Vector3(0.15, 1.14, 0.055), "boards")
	for y: float in [0.30, 0.87]:
		_box(leaf, mats, Vector3(width * 0.5, y, -0.04), Vector3(width - 0.05, 0.07, 0.055), "boards")
	_box(leaf, mats, Vector3(width - 0.12, 0.71, 0.055), Vector3(0.07, 0.14, 0.07), "metal")
	for y: float in [0.25, 0.90]:
		_cylinder(owner, mats, Vector3(0, y, 0), 0.035, 0.16, "metal")
	_finish(leaf)
	_finish(owner)
	col.add_box_d(CollisionWorld.SET_OVERLAY, x, 0.0, z - 0.06, x + width, 1.18, z + 0.06, id)
	var d := _define(out, id, "gate", owner, hinge + Vector3(width * 0.52, 0.82, 0), leaf)
	d["blocker"] = id
	d["hinge"] = hinge
	d["width"] = width
	d["height"] = 1.18
	d["angle"] = -1.48 if north else 1.48


static func _cabinet(parent: Node3D, mats: Materials, out: Dictionary, id: String, at: Vector3, yaw: float) -> void:
	var owner := _owner(parent, out, id, at)
	owner.rotation.y = yaw
	# Полая тумба: задник, стенки, три полки, без сплошного объёма внутри.
	_box(owner, mats, Vector3(0, 0.73, 0.18), Vector3(0.86, 1.46, 0.055), "shedwood")
	for x: float in [-0.43, 0.43]:
		_box(owner, mats, Vector3(x, 0.73, 0), Vector3(0.05, 1.46, 0.42), "shedwood")
	for y: float in [0.04, 0.50, 0.98, 1.43]:
		_box(owner, mats, Vector3(0, y, 0), Vector3(0.86, 0.055, 0.42), "boards")
	# Лейка, коробка гвоздей, рукоятки и свёрнутая верёвка видны после открытия.
	_cylinder(owner, mats, Vector3(-0.20, 0.66, 0.04), 0.13, 0.25, "metal")
	var spout := _cylinder(owner, mats, Vector3(-0.05, 0.67, -0.07), 0.032, 0.24, "metal")
	spout.rotation.z = -0.85
	_box(owner, mats, Vector3(0.22, 1.10, 0.02), Vector3(0.24, 0.16, 0.24), "trim")
	for x: float in [-0.21, -0.07, 0.07]:
		_box(owner, mats, Vector3(x, 1.19, 0.03), Vector3(0.035, 0.32, 0.035), "boards")
		_box(owner, mats, Vector3(x, 1.31, 0.025), Vector3(0.08, 0.05, 0.08), "metal")
	for k in 4:
		_cylinder(owner, mats, Vector3(0.20, 0.10 + float(k) * 0.055, 0.02), 0.13, 0.04, "fabric")
	var leaf := Node3D.new()
	leaf.name = "leaf"
	leaf.position = Vector3(-0.42, 0, -0.23)
	owner.add_child(leaf)
	_box(leaf, mats, Vector3(0.42, 0.73, 0), Vector3(0.84, 1.40, 0.045), "shedwood")
	_box(leaf, mats, Vector3(0.75, 0.81, -0.045), Vector3(0.035, 0.13, 0.07), "metal")
	_finish(leaf)
	_finish(owner)
	var point := at + Basis(Vector3.UP, yaw) * Vector3(0, 1.05, -0.29)
	var d := _define(out, id, "cabinet", owner, point, leaf)
	d["angle"] = 1.65


static func _barrel(parent: Node3D, mats: Materials, out: Dictionary, metal: Material) -> void:
	var at := Vector3(30.25, 0.0, -60.8)
	var owner := _owner(parent, out, "decor-p07-barrel", at)
	# Старый визуальный цилиндр p07 исключает SntWorld; его твёрдая коробка
	# остаётся на месте. Здесь стенки, дно и обод, без крышки над водой.
	for k in 16:
		var angle := TAU * float(k) / 16.0
		var panel := _box(owner, mats, Vector3(sin(angle) * 0.325, 0.43, cos(angle) * 0.325),
			Vector3(0.132, 0.86, 0.035), "metal")
		panel.rotation.y = angle
	_cylinder(owner, mats, Vector3(0, 0.035, 0), 0.33, 0.045, "metal")
	for y: float in [0.16, 0.72, 0.86]:
		var ring := TorusMesh.new()
		ring.inner_radius = 0.297 if y > 0.8 else 0.325
		ring.outer_radius = 0.351
		ring.rings = 16
		ring.ring_segments = 6
		ring.material = mats.get_mat("metal")
		var hoop := MeshInstance3D.new()
		hoop.mesh = ring
		hoop.position.y = y
		hoop.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		owner.add_child(hoop)
	_cylinder(owner, mats, Vector3(0, 0.69, 0), 0.292, 0.012, "water")
	var lid := Node3D.new()
	lid.name = "lid"
	lid.position = Vector3(0, 0.90, -0.32)
	owner.add_child(lid)
	_cylinder(lid, mats, Vector3(0, 0, 0.32), 0.34, 0.025, "metal")
	_box(lid, mats, Vector3(0, 0.025, 0.32), Vector3(0.14, 0.035, 0.065), "metal")
	_replace_metal(owner, mats.get_mat("metal"), metal)
	_finish(lid)
	_finish(owner)
	var d := _define(out, "decor-p07-barrel", "barrel", owner, at + Vector3(0, 0.98, 0), lid)
	d["axis"] = "x"
	d["angle"] = -1.65


static func _pump(parent: Node3D, mats: Materials, out: Dictionary) -> void:
	var owner := _owner(parent, out, "decor-p10-pump", Vector3(-26.0, 0, -49.0))
	var paint := _pump_paint(mats)
	var body := _cylinder(owner, mats, Vector3(0, 0.49, 0), 0.095, 0.92, "metal")
	(body.mesh as PrimitiveMesh).material = paint
	_cylinder(owner, mats, Vector3(0, 0.06, 0), 0.21, 0.10, "metal")
	var spout := _cylinder(owner, mats, Vector3(0.20, 0.78, 0), 0.045, 0.34, "metal")
	(spout.mesh as PrimitiveMesh).material = paint
	spout.rotation.z = PI * 0.5
	# Four hexagonal bolts and one eight-sided flange add 128 triangles.
	for x: float in [-0.13, 0.13]:
		for z: float in [-0.13, 0.13]:
			_cylinder(owner, mats, Vector3(x, 0.123, z), 0.022, 0.026, "metal", 6)
	_cylinder(owner, mats, Vector3(0, 0.33, 0), 0.13, 0.045, "metal", 8)
	owner.set_meta("everyday_added_triangles", 128)
	var handle := Node3D.new()
	handle.name = "handle"
	handle.position = Vector3(-0.05, 0.98, 0)
	owner.add_child(handle)
	_box(handle, mats, Vector3(-0.25, 0, 0), Vector3(0.55, 0.055, 0.07), "metal")
	_box(handle, mats, Vector3(-0.49, 0, 0), Vector3(0.16, 0.09, 0.09), "boards")
	_finish(handle)
	_finish(owner)
	_define(out, "decor-p10-pump", "pump", owner, owner.position + Vector3(-0.15, 1.03, 0), handle)


static func _pump_paint(mats: Materials, painted := true) -> Material:
	var image := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var noise := posmod(x * 37 + y * 53 + x * y * 7, 31)
			var chipped := posmod(x * 11 + y * 3, 64) < (4 if painted else 2) and noise < 19
			var base := Color(0.22, 0.31, 0.25) if painted else Color(0.46, 0.50, 0.53)
			var color := base if not chipped else Color(0.37, 0.18, 0.075)
			image.set_pixel(x, y, color.lightened(float(noise) * 0.0017))
	var paint := mats.get_mat("metal").duplicate() as ShaderMaterial
	paint.resource_name = "everyday-painted-cast-iron" if painted else "everyday-worn-galvanized-metal"
	var params: Dictionary = paint.get_meta("skin_hq_params", {}).duplicate()
	params["albedo_tex"] = ImageTexture.create_from_image(image)
	params["albedo"] = Color.WHITE
	params["roughness_value"] = 0.82 if painted else 0.68
	params["metallic_value"] = 0.18 if painted else 0.35
	paint.set_meta("skin_hq_params", params)
	for key: String in params: paint.set_shader_parameter(key, params[key])
	return paint


static func _replace_metal(owner: Node3D, source: Material, material: Material) -> void:
	for node: Node in SkinLayer._nodes(owner):
		if node is MeshInstance3D and node.get_active_material(0) == source:
			node.material_override = material


static func _radio(parent: Node3D, mats: Materials, out: Dictionary, metal: Material) -> void:
	var owner := _owner(parent, out, "decor-p09-radio", Vector3(7.1, 0.50, -59.0))
	_box(owner, mats, Vector3(0, 0.16, 0), Vector3(0.50, 0.31, 0.17), "shedwood")
	_box(owner, mats, Vector3(0.08, 0.16, 0.092), Vector3(0.26, 0.21, 0.012), "dark")
	for x: float in [-0.01, 0.045, 0.10, 0.155]:
		_box(owner, mats, Vector3(x, 0.16, 0.103), Vector3(0.017, 0.19, 0.008), "metal")
	_box(owner, mats, Vector3(-0.15, 0.24, 0.096), Vector3(0.10, 0.035, 0.008), "trim")
	var dial := Node3D.new()
	dial.name = "dial"
	dial.position = Vector3(-0.15, 0.11, 0.115)
	owner.add_child(dial)
	var knob := _cylinder(dial, mats, Vector3.ZERO, 0.035, 0.035, "metal")
	knob.rotation.x = PI * 0.5
	_box(dial, mats, Vector3(0, 0.015, 0.02), Vector3(0.008, 0.03, 0.008), "trim")
	_box(owner, mats, Vector3(-0.16, 0.48, -0.03), Vector3(0.012, 0.43, 0.012), "metal")
	_replace_metal(owner, mats.get_mat("metal"), metal)
	_finish(dial)
	_finish(owner)
	_define(out, "decor-p09-radio", "radio", owner, owner.position + Vector3(0, 0.2, 0.14), dial)


static func _notice(parent: Node3D, mats: Materials, out: Dictionary, id: String,
		at: Vector3, title: String, pages: Array) -> void:
	var owner := _owner(parent, out, id, at)
	_box(owner, mats, Vector3.ZERO, Vector3(0.67, 0.76, 0.055), "boards")
	for k in 3:
		var paper := _box(owner, mats, Vector3(-0.16 + float(k) * 0.16, 0.12 - float(k % 2) * 0.19, 0.034),
			Vector3(0.24, 0.30, 0.008), "trim")
		paper.rotation.z = -0.08 + float(k) * 0.065
		for line in 4:
			_box(owner, mats, Vector3(-0.16 + float(k) * 0.16, 0.21 - float(k % 2) * 0.19 - float(line) * 0.055, 0.041),
				Vector3(0.16 - float(line % 2) * 0.025, 0.009, 0.005), "dark")
	_finish(owner)
	var d := _define(out, id, "notice", owner, at + Vector3(0, 0, 0.09))
	d["title"] = title
	d["pages"] = pages

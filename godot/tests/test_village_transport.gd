# Единый источник парковок, геометрия колёс и физическое крепление ламп.
extends SceneTree

func _initialize() -> void:
	var errors: Array[String] = []
	var data := SntWorld.data()
	var defs: Dictionary = {}
	for prop: Dictionary in GameData.props()["PROPS"]:
		if prop.has("_snt"):
			defs[String(prop["_snt"])] = prop
	if defs.size() != 15:
		errors.append("SNT cars: %d != 15" % defs.size())
	var measured: Dictionary = {}
	var mats := Materials.new()
	mats.load_all()
	for plot: Dictionary in data["PLOTS"]:
		var id := String(plot["id"])
		var car: Dictionary = plot["car"]
		if car.has("box"):
			errors.append(id + ": duplicate collision coordinates")
		if not VehicleVisuals.SIZES.has(String(car.get("family", ""))):
			errors.append(id + ": unknown vehicle family")
			continue
		var size := VehicleVisuals.dimensions(car)
		var bounds := VehicleVisuals.world_box(car)
		var rect := Rect2(Vector2(bounds[0], bounds[2]), Vector2(bounds[1] - bounds[0], bounds[3] - bounds[2]))
		var def: Dictionary = defs.get(id, {})
		if def.get("at") != car["at"] or not is_equal_approx(float(def.get("ry", 0)), float(car.get("ry", 0))):
			errors.append(id + ": visual and collision positions differ")
		var holder := Node3D.new()
		VehicleVisuals.build(mats, def, holder)
		if holder.get_child_count() != 4:
			errors.append(id + ": vehicle exceeded four material batches")
		var expected := AABB(Vector3(-size.x * 0.5, 0, -size.z * 0.5), size).grow(0.002)
		for child: MeshInstance3D in holder.get_children():
			var box := child.mesh.get_aabb()
			if not expected.encloses(box):
				errors.append(id + ": visual outside collision envelope " + String(child.name))
		var family := String(car["family"])
		var belt := 1.12 if family == "uaz" else 0.93
		var body := _rendered_stats((holder.get_child(0) as MeshInstance3D).mesh, belt)
		var glass := _rendered_stats((holder.get_child(1) as MeshInstance3D).mesh, belt)
		# Inspect referenced triangles: an AABB also includes unused vertices.
		if float(body["height"]) < size.y - 0.046 or int(body["above_belt"]) < 10:
			errors.append(id + ": cabin/roof has no rendered triangles above beltline")
		if int(glass["above_belt"]) < (12 if family == "sedan" else 16):
			errors.append(id + ": cabin windows are not referenced by rendered triangles")
		if not measured.has(family):
			var triangles := 0
			for child: MeshInstance3D in holder.get_children():
				triangles += int(_rendered_stats(child.mesh, belt)["triangles"])
			measured[family] = triangles
			print("vehicle geometry %s: rendered_tris=%d cabin_tris=%d glass_tris=%d" %
				[family, triangles, body["above_belt"], glass["above_belt"]])
		holder.free()
		# Проверка свободного подхода.
		for road: Dictionary in data["ROADS"]:
			var a := Vector2(float(road["x"][0]), float(road["z"][0]))
			var b := Vector2(float(road["x"][1]), float(road["z"][1]))
			var center := (a + b) * 0.5
			var long_x := b.x - a.x > b.y - a.y
			var length := b.x - a.x if long_x else b.y - a.y
			for step in range(int(ceil(length / 0.25)) + 1):
				var distance := minf(length, step * 0.25)
				var at := Vector2(a.x + distance, center.y) if long_x else Vector2(center.x, a.y + distance)
				if rect.grow(0.28).has_point(at):
					errors.append(id + ": blocks road center at " + str(at))
					break
		# Проверка свободного подхода.
		for yard: Dictionary in data["PLOTS"]:
			var wicket: Array = yard.get("wicket", [])
			if wicket.size() != 2:
				continue
			var mid := (float(wicket[0]) + float(wicket[1])) * 0.5
			var direction := Vector2.ZERO
			var gate := Vector2.ZERO
			match String(yard["face"]):
				"s":
					gate = Vector2(mid, float(yard["z"][1]))
					direction = Vector2(0, 1)
				"n":
					gate = Vector2(mid, float(yard["z"][0]))
					direction = Vector2(0, -1)
				"e":
					gate = Vector2(float(yard["x"][1]), mid)
					direction = Vector2(1, 0)
				"w":
					gate = Vector2(float(yard["x"][0]), mid)
					direction = Vector2(-1, 0)
			for step in 7:
				if rect.grow(0.28).has_point(gate + direction * step * 0.25):
					errors.append(id + ": blocks wicket " + String(yard["id"]))
					break
	var rig := LightRig.new()
	for id: String in LightCone.LAMP_IDS:
		var lamp := rig._lamp_by_id(id)
		var spec: Dictionary = lamp.get("fixture", {})
		if spec.is_empty():
			errors.append(id + ": no physical fixture")
			continue
		var anchor: Vector3 = lamp["pos"]
		if anchor != spec["anchor"]:
			errors.append(id + ": separated bulb/light/fixture anchors")
		var bulb_box := AABB(anchor - Vector3.ONE * LightRig.BULB_RADIUS, Vector3.ONE * LightRig.BULB_RADIUS * 2.0)
		if not LampFixtures.body_bounds(anchor).encloses(bulb_box):
			errors.append(id + ": bulb protrudes beyond housing")
	if LightRig.POOL_SIZE != 2:
		errors.append("source pool changed")
	rig.free()
	if errors.is_empty():
		print("test_village_transport: PASS (15 cars, clear roads/wickets, lamp mounts)")
		quit(0)
	else:
		for error: String in errors:
			print("FAIL: ", error)
		quit(1)


func _rendered_stats(mesh: Mesh, belt: float) -> Dictionary:
	var height := 0.0
	var above_belt := 0
	var triangles := 0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		var indexed: bool = indices is PackedInt32Array and not indices.is_empty()
		var count: int = indices.size() if indexed else vertices.size()
		for start in range(0, count - 2, 3):
			var cabin := false
			for offset in 3:
				var index: int = int(indices[start + offset]) if indexed else start + offset
				height = maxf(height, vertices[index].y)
				cabin = cabin or vertices[index].y > belt + 0.025
			triangles += 1
			if cabin:
				above_belt += 1
	return {"height": height, "above_belt": above_belt, "triangles": triangles}

extends SceneTree

const STANCES := {
	"decor-shed-cabinet": Vector3(6.75, 0.12, 11.70),
	"decor-snt-cabinet": Vector3(-16.30, 0, -38.84),
	"decor-p07-barrel": Vector3(30.15, 0, -59.90),
	"decor-p10-pump": Vector3(-25.15, 0, -49.10),
	"decor-p09-radio": Vector3(7.1, 0, -57.5),
	"decor-board-notice": Vector3(-31.5, 0, -6.2),
	"decor-club-notice": Vector3(10.45, 0, -26.15),
	"decor-snt-entry-notice": Vector3(34.55, 0, -33.22),
}

class FakeControls extends RefCounted:
	var at := Vector3.ZERO
	func feet() -> Vector3: return at

var errors: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var holder := Node3D.new()
	root.add_child(holder)
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var built := WorldBuilder.build(holder, mats, col)
	var props := Props.new(mats)
	var static_props: Array = GameData.props().get("PROPS", [])
	props.load_models(static_props)
	props.build(holder, static_props, col)
	var before: Array[int] = []
	for set_id in CollisionWorld.SET_COUNT: before.append(col.box_count(set_id))
	var world := EverydayWorld.build(holder, mats, col, built)
	for id: String in world["nodes"]:
		var expected_range := 34.0 if id.begins_with("decor-gate-") else 18.0
		var geometry_count := 0
		for node: Node in SkinLayer._nodes(world["nodes"][id]):
			if not node is GeometryInstance3D: continue
			geometry_count += 1
			_check(is_equal_approx(node.visibility_range_end, expected_range),
				"decor visual range disagrees with owner " + id)
			_check(node.visibility_range_end_margin == 1.0,
				"decor visual range has no transition margin " + id)
		_check(geometry_count > 0, "decor owner has no visible geometry " + id)
	for set_id in CollisionWorld.SET_COUNT:
		_check(col.box_count(set_id) == before[set_id] + (5 if set_id == CollisionWorld.SET_OVERLAY else 0),
			"everyday collision delta in set " + str(set_id))
	var physics := PhysicsBodies.new()
	holder.add_child(physics)
	physics.build(col)
	var s := GameState.new()
	s.chapter = "arrive"
	var controls := FakeControls.new()
	var c := {"state": s, "col": col, "controls": controls, "physics": physics}
	var everyday := EverydayInteractions.new(c, world)
	var interact := Interact.new()
	interact.occluder = col
	everyday.register(interact)
	var camera := Camera3D.new()
	holder.add_child(camera)
	c["renderer"] = {"camera": camera}
	await process_frame
	var cabinet: Dictionary = everyday.definitions["decor-shed-cabinet"]
	var leaf: Node3D = cabinet["moving"]
	for step in 25:
		leaf.rotation.y = float(cabinet["angle"]) * float(step) / 24.0
		for piece: Node in SkinLayer._nodes(leaf):
			if not piece is MeshInstance3D: continue
			var door_bounds: AABB = piece.global_transform * piece.get_aabb()
			for prop: Node in SkinLayer._nodes(props.root):
				if prop is MeshInstance3D and prop.visible:
					_check(not door_bounds.intersects(prop.global_transform * prop.get_aabb()),
						"cabinet door intersects existing prop " + str(prop.get_path()))
	leaf.rotation.y = 0.0
	var pump: Node3D = world["nodes"]["decor-p10-pump"]
	var pump_triangles := 0
	var pump_materials: Dictionary = {}
	var paint_found := false
	for piece: Node in SkinLayer._nodes(pump):
		if not piece is MeshInstance3D: continue
		pump_triangles += piece.mesh.get_faces().size() / 3
		for surface in piece.mesh.get_surface_count():
			var material: Material = piece.get_active_material(surface)
			pump_materials[material.get_instance_id()] = true
			if material.resource_name == "everyday-painted-cast-iron":
				paint_found = true
				Materials.set_material_quality(material, true)
				_check(material.get_shader_parameter("albedo_tex") is ImageTexture,
					"paint texture lost during HQ quality switch")
	_check(paint_found, "pump has no painted cast iron")
	_check(pump_triangles - 456 == 128 and pump_materials.size() == 3,
		"pump additions exceed 128 triangles or one material: " + str([pump_triangles, pump_materials.size()]))
	var maximum_usec := 0
	var ray_usec := 0
	var rays := 0
	for id: String in everyday.definitions:
		var d: Dictionary = everyday.definitions[id]
		var poses: Array[Vector3] = []
		if String(d["kind"]) == "gate":
			var point: Vector3 = d["point"]
			poses = [Vector3(point.x, 0, point.z - 1.1), Vector3(point.x, 0, point.z + 1.1)]
		else: poses.append(STANCES[id])
		for feet: Vector3 in poses:
			feet = _clear_stance(col, feet, d["point"])
			controls.at = feet
			camera.position = feet + Vector3(0, 1.65, 0)
			camera.look_at(d["point"])
			_check(not col.point_hit(feet.x, feet.y + 0.85, feet.z, CollisionWorld.ALL_SOLID), "stance in wall " + id)
			var hit := col.capsule_hit(feet + Vector3(0, 0.32, 0), feet + Vector3(0, 1.45, 0), 0.30,
				CollisionWorld.ALL_SOLID)
			_check(hit.is_empty() or float(hit.get("depth", 0.0)) < 0.025, "stance capsule blocked " + id)
			var found: Variant = interact.find(camera, s)
			_check(found is Dictionary and found["id"] == id, "real-world target blocked/out of range " + id)
			if String(d["kind"]) == "gate" and found is Dictionary and found["id"] == id:
				var gate_index: int = col._by_id[CollisionWorld.SET_OVERLAY][id][0]
				var shape: CollisionShape3D = physics._shapes[CollisionWorld.SET_OVERLAY][gate_index]
				_check(not shape.disabled and col.is_blocker_active(id), "closed gate native shape disagrees " + id)
				_check(interact.use(c), "closed gate E failed from stance " + str(feet) + " " + id)
				_check(shape.disabled and not col.is_blocker_active(id) and not s.has(d["flag"]),
					"opening gate physics/stable flag disagree " + id)
				everyday.update(0.61)
				_check(s.has(d["flag"]) and shape.disabled and not col.is_blocker_active(id), "opened gate state disagrees " + id)
				s.set_flag(d["flag"], false)
				everyday.resync(s)
				_check(not shape.disabled and col.is_blocker_active(id), "gate restore did not restore native shape " + id)
			for repetition in 10:
				var start := Time.get_ticks_usec()
				interact.visible(camera.global_position, d["point"], CollisionWorld.ALL_SOLID)
				var elapsed := Time.get_ticks_usec() - start
				maximum_usec = maxi(maximum_usec, elapsed)
				ray_usec += elapsed
				rays += 1
	var barrel: Node3D = world["nodes"]["decor-p07-barrel"]
	_check(barrel.get_node_or_null("lid") != null, "barrel lost independent lid")
	_check(not (built["decor"] as Dictionary).has("rural-extra:p07-barrel"), "p07 old capped visual still exists")
	print("everyday ALL_SOLID ray: mean=", float(ray_usec) / max(1, rays), "us max=", maximum_usec, "us, samples=", rays)
	props.dispose()
	holder.queue_free()
	await process_frame
	for error: String in errors: printerr(error)
	print("test_everyday_geometry: ", "PASS" if errors.is_empty() else "FAIL")
	quit(0 if errors.is_empty() else 1)


func _clear_stance(col: CollisionWorld, preferred: Vector3, point: Vector3) -> Vector3:
	for radius: float in [0.0, 0.25, 0.50, 0.75]:
		for direction in 8:
			var angle := float(direction) * TAU / 8.0
			var feet := preferred + Vector3(cos(angle), 0, sin(angle)) * radius
			var floor_hit: Dictionary = col.ray_down(feet.x, 0.50, feet.z, CollisionWorld.ALL_SOLID)
			if not floor_hit.is_empty(): feet.y = float(floor_hit["y"])
			if (feet + Vector3(0, 1.65, 0)).distance_to(point) > 2.2: continue
			if col.point_hit(feet.x, feet.y + 0.85, feet.z, CollisionWorld.ALL_SOLID): continue
			var hit := col.capsule_hit(feet + Vector3(0, 0.32, 0), feet + Vector3(0, 1.45, 0), 0.30, CollisionWorld.ALL_SOLID)
			if hit.is_empty() or float(hit.get("depth", 0.0)) < 0.025: return feet
	return preferred


func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

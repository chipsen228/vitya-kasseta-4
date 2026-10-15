extends SceneTree

const GARDEN_CLEAR := Rect2(-4.5, 17.0, 7.8, 10.1)


func _initialize() -> void:
	var errors: Array[String] = []
	_check_scatter(errors)
	_check_dressing(errors)

	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	var yard: Dictionary = built.get("yard", {})
	var valya: Dictionary = built.get("valya", {})
	_check_garden_nodes(yard, valya, errors)
	_check_wet_sync(yard, errors)
	_check_banya_writing(yard, errors)
	_check_apple_batch(mats, errors)
	_check_parity_shelf(errors)
	root.free()

	if errors.is_empty():
		print("test_garden_home: PASS (4 wet rows, 4 digs, 3 crop MultiMeshes, no new collision)")
		quit(0)
		return
	for error: String in errors:
		printerr("FAIL test_garden_home: ", error)
	quit(1)


func _check_scatter(errors: Array[String]) -> void:
	var found := false
	for raw: Variant in Scatter.data().get("CLEAR", []):
		if not raw is Array or (raw as Array).size() != 4:
			continue
		var a: Array = raw
		var r := Rect2(float(a[0]), float(a[2]),
			float(a[1]) - float(a[0]), float(a[3]) - float(a[2]))
		if r == GARDEN_CLEAR:
			found = true
	if not found:
		errors.append("scatter CLEAR lacks garden x[-4.5,3.3] z[17.0,27.1]")


func _check_garden_nodes(yard: Dictionary, valya: Dictionary,
		errors: Array[String]) -> void:
	var nodes: Dictionary = yard.get("nodes", {})
	for i in 4:
		var wet: Variant = nodes.get("wet-row-%d" % i)
		if not wet is MeshInstance3D:
			errors.append("wet-row-%d is missing or not a visual mesh" % i)
			continue
		if (wet as MeshInstance3D).visible:
			errors.append("wet-row-%d must start hidden" % i)
		var want_z := 17.4 + float(i) * 2.1 + 0.55
		if absf((wet as MeshInstance3D).position.z - want_z) > 0.001:
			errors.append("wet-row-%d moved from watering section" % i)
	if nodes.has("wet-row-4"):
		errors.append("removed fifth watering section still exists")
	var crops := ["garden-crops-potato", "garden-crops-cabbage",
		"garden-crops-onion-sunflower"]
	for id: String in crops:
		var crop: Variant = nodes.get(id)
		if not crop is MultiMeshInstance3D:
			errors.append("%s is not a MultiMesh" % id)
			continue
		var mmi := crop as MultiMeshInstance3D
		if mmi.multimesh == null or mmi.multimesh.instance_count == 0:
			errors.append("%s has no plants" % id)
		if mmi.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			errors.append("%s casts shadows" % id)
	var dug_nodes: Dictionary = valya.get("nodes", {})
	for i in 4:
		var dug: Variant = dug_nodes.get("garden-dug-%d" % i)
		if not dug is Node3D or (dug as Node3D).get_child_count() < 2:
			errors.append("garden-dug-%d has no low-poly reveal" % i)
	if not (valya.get("boxes", []) as Array).is_empty():
		errors.append("optional garden reveals added collision boxes")


func _check_wet_sync(yard: Dictionary, errors: Array[String]) -> void:
	var quest := OutskirtsQuest.new({"world": {"yard": yard}}, {})
	var state := GameState.new()
	state.set_flag("watered-1")
	state.set_flag("watered-4")
	quest.resync(state)
	var nodes: Dictionary = yard.get("nodes", {})
	for i in 4:
		var n := nodes.get("wet-row-%d" % i) as Node3D
		if n == null or n.visible != (i == 1):
			errors.append("wet-row-%d does not follow watered-%d on resync" % [i, i])
	state.set_flag("water-done")
	quest.resync(state)
	for i in 4:
		var n := nodes.get("wet-row-%d" % i) as Node3D
		if n == null or not n.visible:
			errors.append("legacy water-done did not show wet-row-%d" % i)


func _check_banya_writing(yard: Dictionary, errors: Array[String]) -> void:
	var pane: Variant = (yard.get("nodes", {}) as Dictionary).get("banya-win-w")
	if not (pane is Node3D):
		errors.append("west banya pane is missing")
		return
	var writing := (pane as Node3D).get_node_or_null("story-writing") as Node3D
	if writing == null:
		errors.append("banya story writing is missing")
		return
	if writing.visible or String(writing.get_meta("story_text", "")) != "НЕ ХОДИ НА ОЗЕРО\nКЛЮЧ У ДВЕРИ":
		errors.append("banya story writing has wrong initial state or text")
	if not (writing is MeshInstance3D) or not ((writing as MeshInstance3D).mesh is ArrayMesh):
		errors.append("banya story writing is not the embedded ArrayMesh pane")
	elif String((writing as MeshInstance3D).mesh.get_meta("steam_texture", "")) \
			!= "res://assets/pictures/banya-window-steam-v2.webp":
		errors.append("banya story writing does not use the versioned steam texture")
	else:
		var surface := ((writing as MeshInstance3D).mesh as ArrayMesh).surface_get_arrays(0)
		var verts: PackedVector3Array = surface[Mesh.ARRAY_VERTEX]
		if verts.size() != 8:
			errors.append("banya story pane must contain exactly two embedded faces")
		elif verts[0].x * verts[4].x >= 0.0:
			errors.append("banya story faces are not on opposite sides of the glass")
		var norms: PackedVector3Array = surface[Mesh.ARRAY_NORMAL]
		var ids: PackedInt32Array = surface[Mesh.ARRAY_INDEX]
		for first: int in [0, 6]:
			var a: Vector3 = verts[ids[first]]
			var ab: Vector3 = verts[ids[first + 1]] - a
			var ac: Vector3 = verts[ids[first + 2]] - a
			if ab.cross(ac).dot(norms[ids[first]]) >= 0.0:
				errors.append("banya story face has non-Godot winding")
	var texture := load("res://assets/pictures/banya-window-steam-v2.webp") as Texture2D
	if texture == null or texture.get_width() != 320 or texture.get_height() != 256:
		errors.append("banya steam texture is not an imported 320x256 image")
	var state := GameState.new()
	var quest := OutskirtsQuest.new({"world": {"yard": yard}}, {})
	state.set_flag("banya-hot")
	quest.resync(state)
	if not writing.visible:
		errors.append("banya-hot does not reveal the story writing on resync")


func _check_apple_batch(mats: Materials, errors: Array[String]) -> void:
	var props := Props.new(mats)
	var parts: Array = props._make("applePile", {"id": "basket-check", "count": 18, "r": 0.35})
	if parts.size() != 1:
		errors.append("one apple basket uses %d meshes instead of one" % parts.size())
	elif (parts[0].get("inst", []) as Array).size() != 18:
		errors.append("apple MultiMesh lost deterministic instances")


func _check_dressing(errors: Array[String]) -> void:
	var d: Dictionary = VisualDressing.data()
	var calendar := _find(d.get("atlas_quads", []), "hall-calendar")
	if calendar.is_empty():
		errors.append("hall visual calendar is missing")
	else:
		var p: Array = calendar.get("position", [])
		if p.size() != 3 or absf(float(p[0]) + 5.485) > 0.001:
			errors.append("hall visual calendar is not on the free west wall")
		if p.size() == 3 and float(p[2]) >= 13.20:
			errors.append("hall visual calendar overlaps the west window")

	for raw: Variant in d.get("boxes", []):
		if not raw is Dictionary:
			continue
		var box: Dictionary = raw
		if String(box.get("cluster", "")) != "kitchen-spice-shelf":
			continue
		var p: Array = box.get("position", [])
		var s: Array = box.get("size", [])
		if p.size() == 3 and s.size() == 3 and float(p[2]) + float(s[2]) * 0.5 >= 10.85:
			errors.append("kitchen shelf or jars overlap the z=11.3 doorway")
	var back := _find(d.get("boxes", []), "attic-cassette-crate", Vector3(1.20, 4.22, 9.73))
	if back.is_empty():
		errors.append("parity tape shelf has no visual back panel")


func _check_parity_shelf(errors: Array[String]) -> void:
	var props: Array = GameData.props().get("PROPS", [])
	var shelf := _find(props, "tape-shelf")
	if shelf.is_empty():
		errors.append("tape-shelf id is missing")
		return
	var at: Array = shelf.get("at", [])
	if at.size() != 3 or Vector3(float(at[0]), float(at[1]), float(at[2])) != Vector3(1.2, 3.3, 9.75):
		errors.append("parity tape shelf moved")
	if shelf.has("col") and shelf["col"] is bool and shelf["col"] == false:
		errors.append("parity tape shelf collider was removed")


func _find(rows: Array, cluster_or_id: String, at := Vector3(INF, INF, INF)) -> Dictionary:
	for raw: Variant in rows:
		if not raw is Dictionary:
			continue
		var d: Dictionary = raw
		if String(d.get("cluster", d.get("id", ""))) != cluster_or_id:
			continue
		if is_finite(at.x):
			var p: Array = d.get("position", [])
			if p.size() != 3:
				continue
			var got := Vector3(float(p[0]), float(p[1]), float(p[2]))
			if not got.is_equal_approx(at):
				continue
		return d
	return {}

# Read-only triangle inventory; counts source topology, not measured GPU passes.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1280, 720)
	var main: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 1800:
		if bool(main.get("boot_ready")):
			break
		await process_frame
	if not bool(main.get("boot_ready")):
		printerr("profile_visible_geometry: boot timeout")
		quit(1)
		return
	main.set("running", false)
	var chain: RenderChain = main.get("render_chain")
	chain.apply_preset("hq")
	var camera := chain.camera
	for record: Dictionary in StaticShadowBatch.records(chain.world_root):
		for proxy: MeshInstance3D in record["proxies"]:
			var triangles := proxy.mesh.get_faces().size() / 3
			if triangles >= 3000:
				print("HEAVY_SHADOW_CELL ", proxy.name, " tris=", triangles, " bounds=", proxy.get_aabb())
	for point: Dictionary in [
		{"name":"route-peak", "at":Vector3(7.5941,1.68,-5.92096), "yaw":1.986913, "pitch":-0.044150},
		{"name":"snt-gate", "at":Vector3(36.8,1.68,-38.3), "yaw":PI * 0.5, "pitch":0.02},
		{"name":"gap-to-second-line", "at":Vector3(11,1.68,-12), "yaw":0.0, "pitch":0.06},
	]:
		camera.position = point["at"]
		camera.rotation = Vector3(float(point["pitch"]), float(point["yaw"]), 0.0)
		camera.force_update_transform()
		var rows: Array[Dictionary] = []
		_collect(chain.world_root, camera, rows)
		rows.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a["tris"] > b["tris"])
		var total := 0
		var tree_tris := 0
		var shadow_only := 0
		for row: Dictionary in rows:
			if int(row["shadow"]) == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY:
				shadow_only += int(row["tris"])
			else:
				total += int(row["tris"])
			if String(row["name"]).contains("proc-") or String(row["name"]).contains("scatter-nat-"):
				tree_tris += int(row["tris"])
		print("PROFILE_VISIBLE_GEOMETRY point=", point["name"], " source_tris=", total,
			" nature_tris=", tree_tris, " shadow_proxy_tris=", shadow_only, " rows=", rows.size(),
			" viewport=", chain.world_view.size)
		for row: Dictionary in rows.slice(0, mini(40, rows.size())):
			print(JSON.stringify(row))
		print("VISIBLE_GEOMETRY_JSON=" + JSON.stringify({"point":point["name"],
			"source_tris":total, "rows":rows, "caveat":"source topology; excludes shader fog and actual GPU LOD/shadow-pass multiplicity"}))
	main.free()
	quit(0)

func _collect(node: Node, camera: Camera3D, rows: Array[Dictionary]) -> void:
	if node is GeometryInstance3D and (node as GeometryInstance3D).is_visible_in_tree():
		var geometry := node as GeometryInstance3D
		var mesh: Mesh
		var copies := 1
		var bounds := AABB()
		if node is MeshInstance3D:
			var instance := node as MeshInstance3D
			mesh = instance.mesh
			bounds = instance.global_transform * instance.get_aabb()
		elif node is MultiMeshInstance3D:
			var instance := node as MultiMeshInstance3D
			if instance.multimesh != null:
				mesh = instance.multimesh.mesh
				copies = instance.multimesh.instance_count if instance.multimesh.visible_instance_count < 0 \
					else instance.multimesh.visible_instance_count
				bounds = instance.global_transform * instance.get_aabb()
		var distance := camera.global_position.distance_to(bounds.get_center())
		var in_range := (geometry.visibility_range_end <= 0.0 or distance <= geometry.visibility_range_end + geometry.visibility_range_end_margin) \
			and (geometry.visibility_range_begin <= 0.0 or distance >= geometry.visibility_range_begin - geometry.visibility_range_begin_margin)
		if mesh != null and in_range and _in_frustum(camera, bounds):
			var tris := 0
			for surface in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(surface)
				var indices: Variant = arrays[Mesh.ARRAY_INDEX]
				tris += (indices.size() if indices != null and not indices.is_empty() \
					else (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
			rows.append({"name":String(node.name), "path":String(node.get_path()),
				"tris":tris * copies, "instances":copies, "distance":snappedf(distance,0.1),
				"size":str(bounds.size), "center":str(bounds.get_center()),
				"shadow":int(geometry.cast_shadow), "range_end":geometry.visibility_range_end})
	for child: Node in node.get_children():
		_collect(child, camera, rows)

func _in_frustum(camera: Camera3D, bounds: AABB) -> bool:
	var middle := camera.global_position - camera.global_basis.z * 5.0
	for plane: Plane in camera.get_frustum():
		var sign := 1.0 if plane.distance_to(middle) <= 0.0 else -1.0
		var any_inside := false
		for corner in 8:
			if plane.distance_to(bounds.get_endpoint(corner)) * sign <= 0.0:
				any_inside = true
				break
		if not any_inside:
			return false
	return true

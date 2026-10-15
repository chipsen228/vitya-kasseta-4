# One ordinary GPU boot: the production helper captures/restores its own world.
# Headless cannot validate GLES prewarming or the render-facing guard.
extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var cpu_hand_guard := "--cpu-hand-guard" in OS.get_cmdline_user_args()
	if DisplayServer.get_name() == "headless" and not cpu_hand_guard:
		printerr("check_boot_warm: requires real GPU")
		quit(2)
		return
	var main: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for _i in 3600:
		if bool(main.get("boot_ready")):
			break
		await process_frame
	if cpu_hand_guard:
		var errors := _check_hand_restore_cpu(main)
		for error: String in errors: printerr("check_boot_warm CPU hand guard: ", error)
		print("check_boot_warm CPU hand guard: ", "PASS" if errors.is_empty() else "FAIL", " (no GPU draw claim)")
		main.queue_free()
		await process_frame
		await process_frame
		quit(0 if errors.is_empty() else 1)
		return
	var passed := bool(main.get("boot_ready")) and bool(main.get_meta("boot_warm_ran", false)) \
		and bool(main.get_meta("boot_warm_restored", false)) \
		and bool(main.get_meta("boot_capture_warm_ran", false)) \
		and bool(main.get_meta("boot_capture_warm_restored", false)) \
		and bool(main.get_meta("boot_departure_warm_ran", false)) \
		and bool(main.get_meta("boot_departure_warm_restored", false)) \
		and bool(main.get_meta("boot_departure_warm_physics_restored", false))
	var label_proof: Dictionary = main.get_meta("boot_label_warm",{})
	if not bool(label_proof.get("restored",false)) or int(label_proof.get("count",0)) < 28 \
			or label_proof.get("draws",[]).size() != 8:
		printerr("check_boot_warm: actual glyph/outline warm incomplete")
		passed = false
	for record: Dictionary in label_proof.get("draws",[]):
		if int(record.get("draw",{}).get("calls",0)) <= 0: passed = false
	if int(main.get_meta("boot_world_real_lamp_views", 0)) != 8 \
			or int(main.get_meta("boot_world_warm_views", 0)) != 13 \
			or main.get_meta("boot_world_warm_omni_counts", []) != [0, 1, 2, 3] \
			or int(main.get_meta("boot_capture_warm_approaches", 0)) != 2 \
			or int(main.get_meta("boot_departure_warm_views", 0)) != Chapters.DRIVE_SHOTS.size() * 3 \
			or main.get_meta("boot_departure_warm_shots", []) != [0, 1, 2, 3] \
			or main.get_meta("boot_departure_warm_omni_counts", []) != [0, 1, 2, 3] \
			or int(main.get_meta("boot_departure_warm_car_meshes", 0)) <= 0:
		printerr("check_boot_warm: yard/house lamps, capture start or four-shot departure coverage incomplete")
		passed = false
	var forest_draws: Array = main.get_meta("boot_episode_forest_warm", [])
	var corner_draws: Array = main.get_meta("boot_forest_corner_strip", [])
	if corner_draws.size() != 32: passed = false
	for draw: Dictionary in corner_draws:
		if not bool(draw.get("forced_current_lod",false)) or int(draw.get("draw",{}).get("calls",0)) <= 0:
			passed = false
	var expected_eyes := [Vector3(-12, 1.62, -78), Vector3(-34, 1.62, -78)]
	if forest_draws.size() != expected_eyes.size() * 2: passed = false
	for draw: Dictionary in forest_draws:
		if draw.get("eye") not in expected_eyes or int(draw.get("draw", {}).get("calls", 0)) <= 0 \
				or draw.get("forest_meshes_in_frustum",[]).is_empty():
			printerr("check_boot_warm: forest camera not drawn: ", draw)
			passed = false
	for draw: Dictionary in forest_draws:
		var on := bool(draw.get("flashlight"))
		if bool(draw.get("spot_visible")) != on or (float(draw.get("spot_energy",-1)) > 0.02) != on:
			printerr("check_boot_warm: actual Spot state mismatch: ",draw)
			passed = false
	var occluded_draws: Array = main.get_meta("boot_occluded_forest_warm",[])
	if occluded_draws.size() != 32 or not bool(main.get_meta("boot_occluded_forest_restored",false)) \
			or not bool(main.get_meta("boot_occluded_forest_policy_restored",false)):
		printerr("check_boot_warm: native forest warm/restore failed")
		passed = false
	var admitted_draws := 0
	for draw: Dictionary in occluded_draws:
		if not draw.get("forest_meshes_in_frustum",[]).is_empty(): admitted_draws += 1
		if not bool(draw.get("native_occlusion")) or int(draw.get("draw",{}).get("calls",0)) <= 0:
			printerr("check_boot_warm: occluded forest mesh admission absent: ",draw)
			passed = false
	# The south-facing views at x=-12 look into the village, outside the forest cells.
	if admitted_draws < 28:
		printerr("check_boot_warm: forest material coverage incomplete: ",admitted_draws)
		passed = false
	for eye: Vector3 in expected_eyes:
		for on: bool in [false,true]:
			var found := false
			for draw: Dictionary in forest_draws:
				found = found or (draw.get("eye") == eye and draw.get("flashlight") == on)
			if not found: passed = false
	print("check_boot_warm: forest actual draw records=", forest_draws.size())
	var lamp_draws: Array = main.get_meta("boot_world_real_lamp_draws", [])
	var indoor_lamp_draws := 0
	if lamp_draws.size() != 8: passed = false
	for draw: Dictionary in lamp_draws:
		if draw.get("ids", []).is_empty():
			printerr("check_boot_warm: real lamp pool empty at ", draw.get("eye"))
			passed = false
		if not bool(draw.get("outdoor", true)):
			indoor_lamp_draws += 1
			var actual_ids: Array = draw.get("ids", []).duplicate()
			actual_ids.sort()
			if draw.get("zone") != "floor1" or actual_ids != ["hall", "kitchen"]:
				printerr("check_boot_warm: indoor draw did not select actual floor1 lamp IDs: ", draw)
				passed = false
	if indoor_lamp_draws != 2: passed = false
	var hand_proof := _check_hand_draws(main)
	var reader_proof: Dictionary = main.get_meta("boot_reader_warm", {})
	var expected_notices := {}
	var everyday: EverydayInteractions = main.get("everyday")
	for id: String in everyday.definitions:
		var definition: Dictionary = everyday.definitions[id]
		if definition.get("kind", "") == "notice": expected_notices[id] = definition
	var warmed_ids: Array[String] = []
	for page: Dictionary in reader_proof.get("pages", []):
		var id := String(page.get("id", ""))
		if not expected_notices.has(id):
			passed = false
			continue
		var definition: Dictionary = expected_notices[id]
		var pages: Array = definition.get("pages", [])
		var index := int(page.get("index", -1))
		if index < 0 or index >= pages.size():
			passed = false
			continue
		if page.get("title_sha256") != String(definition.get("title", "")).sha256_text() \
				or page.get("body_sha256") != String(pages[index]).sha256_text() \
				or int(page.get("draw_frames", 0)) != 3:
			passed = false
		warmed_ids.append(id)
	var expected_ids: Array = expected_notices.keys()
	expected_ids.sort()
	if warmed_ids != expected_ids or warmed_ids.size() != 3 or expected_notices.size() != 3 \
			or int(reader_proof.get("draw_frames", 0)) != 9 \
			or not bool(reader_proof.get("enabled", false)) \
			or not bool(reader_proof.get("state_restored", false)) \
			or not bool(reader_proof.get("reader_unchanged", false)) \
			or not bool(reader_proof.get("world_restored", false)) \
			or not bool(reader_proof.get("physics_restored", false)) \
			or int(reader_proof.get("paper_texture_rid", 0)) <= 0 \
			or not reader_proof.get("errors", []).is_empty():
		printerr("check_boot_warm: actual notice Reader prewarm or state guard incomplete: ", reader_proof)
		passed = false
	var reader_labels: Array[Label] = [main.get("ui").get("_reader_title"), main.get("ui").get("_reader_body"), main.get("ui").get("_reader_page")]
	var font_index := 0
	for font: Dictionary in reader_proof.get("fonts_after", []):
		var font_id := int(font.get("font_id", 0))
		if font.get("rids", []).is_empty() or font_id == 0 or not instance_from_id(font_id) is Font \
				or font_index >= reader_labels.size() \
				or reader_labels[font_index].get_theme_font("font").get_instance_id() != font_id:
			printerr("check_boot_warm: actual Reader font identity invalid: ", font)
			passed = false
		font_index += 1
	if reader_proof.get("fonts_after", []).size() != 3: passed = false
	print("check_boot_warm: actual Reader pages=", warmed_ids, " draw frames=", reader_proof.get("draw_frames", 0),
		" UI/world/physics restored=", reader_proof.get("state_restored", false), "/",
		reader_proof.get("world_restored", false), "/", reader_proof.get("physics_restored", false))
	if not hand_proof["errors"].is_empty():
		for error: String in hand_proof["errors"]: printerr("check_boot_warm: ", error)
		passed = false
	print("check_boot_warm: HandView actual models=", hand_proof["models"],
		" drawable variants=", hand_proof["drawables"], " surfaces=", hand_proof["surfaces"],
		" verified=", hand_proof["errors"].is_empty())
	var pinned: Array = main.get_meta("boot_departure_resources", [])
	if pinned.size() != 1 or not pinned[0] is StandardMaterial3D \
			or pinned[0].transparency != BaseMaterial3D.TRANSPARENCY_ALPHA \
			or pinned[0].shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED:
		printerr("check_boot_warm: exhaust generated shader has no retained matching material")
		passed = false
	var inventory: Dictionary = main.get("built").get("environment",{}).get("scene_inventory",{})
	var world: Node3D = main.get("render_chain").world_root
	var live_multimeshes := 0
	var indexed_multimeshes := 0
	var empty_multimeshes := 0
	for node: Node in SkinLayer._nodes(world):
		if String(node.name).begins_with("BootDeparture") or String(node.name).begins_with("WarmHeadlight"):
			printerr("check_boot_warm: temporary departure node survived: ", node.get_path())
			passed = false
		if not node is MultiMeshInstance3D or node.multimesh == null or node.layers == 0: continue
		var count: int = node.multimesh.instance_count
		if node.multimesh.visible_instance_count >= 0: count = mini(count,node.multimesh.visible_instance_count)
		if count == 0: empty_multimeshes += 1
		elif node.multimesh.mesh != null: live_multimeshes += 1
	for record: Dictionary in inventory.get("objects",[]):
		var node: Node = root.get_node_or_null(record["node"])
		if not node is MultiMeshInstance3D: continue
		indexed_multimeshes += 1
		var count: int = node.multimesh.instance_count
		if node.multimesh.visible_instance_count >= 0: count = mini(count,node.multimesh.visible_instance_count)
		if int(record["instances"]) != count or count <= 0 or GameData.vec3(record["bounds"]["size"]).length_squared() <= 0.0:
			printerr("check_boot_warm: incorrect actual GPU MultiMesh inventory: ",record["node"])
			passed = false
	if indexed_multimeshes != live_multimeshes or int(inventory.get("excluded_empty_multimeshes",-1)) != empty_multimeshes:
		printerr("check_boot_warm: live/empty MultiMesh inventory differs from actual scene")
		passed = false
	var verge: Dictionary = main.get("built").get("environment_verge", {})
	var verified_groups := 0
	var verified_instances := 0
	for group: Dictionary in verge.get("groups", []):
		var node: MultiMeshInstance3D = verge["nodes"].get(group["id"])
		if node == null or node.multimesh == null:
			passed = false
			continue
		var mm := node.multimesh
		var actual: PackedFloat32Array = mm.buffer
		var written: PackedFloat32Array = node.get_meta("environment_written_buffer")
		if actual != written or actual.size() != int(group["instances"]) * 12:
			printerr("check_boot_warm: actual vegetation upload differs: ", group["id"])
			passed = false
			continue
		var bounds := AABB()
		for i in mm.instance_count:
			var box: AABB = node.global_transform * mm.get_instance_transform(i) * mm.mesh.get_aabb()
			bounds = box if i == 0 else bounds.merge(box)
		var intended := AABB(GameData.vec3(group["bounds"]["min"]), GameData.vec3(group["bounds"]["size"]))
		if not bounds.position.is_equal_approx(intended.position) or not bounds.size.is_equal_approx(intended.size):
			printerr("check_boot_warm: actual vegetation bounds differ: ", group["id"])
			passed = false
		verified_groups += 1
		verified_instances += mm.instance_count
	if verified_groups != 4 or verified_instances != 8 or not verge.get("errors", ["missing"]).is_empty():
		printerr("check_boot_warm: vegetation GPU admission incomplete")
		passed = false
	verge["actual_gpu_buffer_verified"] = passed and verified_groups == 4 and verified_instances == 8
	print("check_boot_warm: vegetation GPU readback groups=", verified_groups, " instances=", verified_instances,
		" verified=", verge["actual_gpu_buffer_verified"])
	print("check_boot_warm: ", "PASS" if passed else "FAIL", " (single production boot; actual HandView/yard/house/capture/four departure shots; pose/material/player/story/physics guard)")
	main.queue_free()
	await process_frame
	await process_frame
	quit(0 if passed else 1)


# Independent scene walk: every real drawable/material surface must have its
# own isolated post-draw GPU proof in the actual HandView, including MultiMesh.
func _check_hand_draws(main: Node) -> Dictionary:
	var errors: Array[String] = []
	var proof: Dictionary = main.get_meta("boot_hand_warm", {})
	var chain: RenderChain = main.get("render_chain")
	var held: HeldItems = main.get("held_items")
	var flashlight: Flashlight = main.get("flashlight")
	var expected_ids: Array[String] = []
	for id: String in HeldItems.SLOT_ORDER:
		if id != HeldItems.EMPTY: expected_ids.append(id)
	if proof.get("ids", []) != expected_ids or expected_ids.size() != 13 \
			or proof.get("viewport") != String(chain.hand_view.get_path()) \
			or proof.get("render_info_type") != "visible" \
			or not bool(proof.get("restored", false)) or not bool(proof.get("physics_restored", false)) \
			or chain.hand_view.find_world_3d() == chain.world_view.find_world_3d():
		errors.append("HandView model list/world/restoration guard failed")
	for error: String in proof.get("errors", []): errors.append(error)
	var expected: Dictionary = {}
	var models: Dictionary = held.get("_models")
	for id: String in expected_ids:
		var model: Node = flashlight.model if id == HeldItems.FLASHLIGHT else models.get(id)
		if model == null:
			errors.append("actual held model missing: " + id)
			continue
		for node: Node in SkinLayer._nodes(model):
			var mesh: Mesh = null
			var instances := 1
			if node is MeshInstance3D and node.layers != 0:
				mesh = node.mesh
			elif node is MultiMeshInstance3D and node.layers != 0 and node.multimesh != null:
				mesh = node.multimesh.mesh
				instances = node.multimesh.instance_count
				if node.multimesh.visible_instance_count >= 0:
					instances = mini(instances, node.multimesh.visible_instance_count)
			if mesh == null or instances == 0: continue
			var surfaces: Array = []
			for i in mesh.get_surface_count():
				var material: Material = mesh.surface_get_material(i)
				if node.material_override != null: material = node.material_override
				elif node is MeshInstance3D and node.get_surface_override_material(i) != null:
					material = node.get_surface_override_material(i)
				surfaces.append({"surface": i, "material_id": material.get_instance_id() if material != null else 0,
					"shader": material.shader.resource_path if material is ShaderMaterial and material.shader != null else "StandardMaterial3D"})
			var variants: Array[String] = []
			variants.assign(["on", "off"] if id == HeldItems.FLASHLIGHT else ["base"])
			for variant: String in variants:
				var key := id + "/" + variant + "/" + String(node.get_path())
				expected[key] = {"mesh_id": mesh.get_instance_id(), "instances": instances,
					"surfaces": surfaces, "triangles": mesh.get_faces().size() / 3 * instances}
	var witnessed: Dictionary = {}
	var surface_count := 0
	for record: Dictionary in proof.get("records", []):
		var key: String = String(record.get("id")) + "/" + String(record.get("variant")) + "/" + String(record.get("node"))
		if not expected.has(key) or witnessed.has(key):
			errors.append("unexpected/duplicate HandView drawable: " + key)
			continue
		witnessed[key] = true
		var source: Dictionary = expected[key]
		var draw: Dictionary = record.get("draw", {})
		if record.get("mesh_id") != source["mesh_id"] or record.get("instances") != source["instances"] \
				or record.get("surfaces") != source["surfaces"] or record.get("expected_triangles") != source["triangles"] \
				or int(draw.get("draw_calls", 0)) < source["surfaces"].size() \
				or int(draw.get("triangles", 0)) < int(source["triangles"]) \
				or int(record.get("model_draw", {}).get("draw_calls", 0)) <= 0 or not bool(record.get("verified", false)):
			errors.append("HandView actual resource/material/isolated GPU draw differs: " + key)
		surface_count += source["surfaces"].size()
	for key: String in expected:
		if not witnessed.has(key): errors.append("unwarmed actual HandView drawable: " + key)
	return {"models": expected_ids.size(), "drawables": witnessed.size(), "surfaces": surface_count, "errors": errors}


func _check_hand_restore_cpu(main: Node) -> Array[String]:
	var errors: Array[String] = []
	if not bool(main.get("boot_ready")):
		errors.append("ordinary boot incomplete")
		return errors
	var chain: RenderChain = main.get("render_chain")
	var held: HeldItems = main.get("held_items")
	var flashlight: Flashlight = main.get("flashlight")
	var saved: Dictionary = main.call("_warm_visual_snapshot")
	var collision: CollisionWorld = main.get("col")
	var physics := [collision.get("_data").duplicate(true), collision.get("_active").duplicate(true)]
	var models: Dictionary = (held.get("_models") as Dictionary).duplicate()
	models[HeldItems.FLASHLIGHT] = flashlight.model
	var drawables := 0
	var corners := 0
	if models.size() != 13: errors.append("actual nonempty slots must contain 13 models")
	for id: String in models:
		var model: Node3D = models[id]
		var geometry: Array[GeometryInstance3D] = []
		for node: Node in SkinLayer._nodes(model):
			if node is MeshInstance3D and node.mesh != null: geometry.append(node)
			elif node is MultiMeshInstance3D and node.multimesh != null and node.multimesh.mesh != null: geometry.append(node)
		if geometry.is_empty(): errors.append("empty actual model: " + id)
		main.call("_warm_hand_fit", model, geometry)
		model.visible = not model.visible
		for node: GeometryInstance3D in geometry:
			drawables += 1
			var boxes: Array[AABB] = []
			if node is MeshInstance3D:
				boxes.append(node.global_transform * node.mesh.get_aabb())
			else:
				for i in node.multimesh.instance_count:
					boxes.append(node.global_transform * node.multimesh.get_instance_transform(i) * node.multimesh.mesh.get_aabb())
			for box: AABB in boxes:
				for i in 8:
					corners += 1
					if not chain.hand_camera.is_position_in_frustum(box.get_endpoint(i)):
						errors.append("fitted actual hand mesh outside frustum: " + String(node.get_path()))
			node.visible = not node.visible
			node.position += Vector3(0.001, -0.002, 0.003)
	chain.set("_hands_on", not bool(chain.get("_hands_on")))
	chain.hand_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	(chain.get("_post_mat") as ShaderMaterial).set_shader_parameter("hand_mix", 0.375)
	main.call("_restore_warm_visual", saved)
	if saved != main.call("_warm_visual_snapshot"):
		errors.append("poses/visibility/resources/held runtime/viewport modes/world state were not restored exactly")
	if physics != [collision.get("_data"), collision.get("_active")]: errors.append("physics ledger changed")
	print("check_boot_warm CPU hand guard: models=", models.size(), " drawables=", drawables, " frustum corners=", corners,
		" physics/player/story/resources/held/HandView restored=", saved == main.call("_warm_visual_snapshot"))
	return errors

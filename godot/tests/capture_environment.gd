# Одинаковые доступные камеры для исходной и новой сборки.
extends SceneTree

var capture_errors: Array[String] = []
var house_footprints: Array = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var output := "res://../output/environment-refresh/after/coverage"
	var filter := ""
	var matrix := false
	var details := false
	var camera_plan := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
		if arg.begins_with("--filter="): filter = arg.trim_prefix("--filter=")
		if arg == "--matrix": matrix = true
		if arg == "--details": details = true
		if arg.begins_with("--camera-plan="): camera_plan = arg.trim_prefix("--camera-plan=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	root.borderless = true
	root.min_size = Vector2i(1280, 720)
	root.size = Vector2i(1280, 720)
	var main: Node = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for i in 2400:
		if main.get("boot_ready"): break
		await process_frame
	if not main.get("boot_ready"):
		printerr("capture_environment: FAIL boot timeout")
		quit(1)
		return
	main.call("_start_game")
	var ui: Overlays = main.get("ui")
	for i in 90:
		if ui.card.open: ui.advanceCard()
		await process_frame
	main.set("running", false)
	main.set_process(false)
	var player: Player = main.get("player")
	player.release_lock()
	ui.showHud(false)
	var chain: RenderChain = main.get("render_chain")
	chain.apply_preset("hq")
	# Fit complete roofs at eye height; keep the near LOD visible in review shots.
	chain.camera.fov = 82.0
	main.call("_ctx_set_door", "gate", true, true)
	var lights: LightRig = main.get("lights")
	var coverage: Dictionary = main.get("built").get("environment", {})
	for category: String in ["errors", "public", "interiors"]:
		var failures: Array = coverage.get(category, []) if category == "errors" else coverage.get(category, {}).get("errors", [])
		for failure: String in failures: capture_errors.append(category + ": " + failure)
	(main.get("flashlight") as Flashlight).give()
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://assets/models/environment/manifest.json"))
	house_footprints = manifest.get("houses", []).duplicate()
	house_footprints.append_array(manifest.get("services", []))
	var rows: Array = []
	var views: Array = []
	for house: Dictionary in manifest.get("houses", []):
		if not filter.is_empty() and not String(house["id"]) in filter.split(","): continue
		var box: Array = house["footprint"]
		var center := Vector3((float(box[0])+float(box[1]))*0.5, 0, (float(box[2])+float(box[3]))*0.5)
		var face := String(house.get("face", "s"))
		if house["id"] == "vitya": face = "n"
		var direction: Vector3 = {"n": Vector3.FORWARD, "s": Vector3.BACK, "e": Vector3.RIGHT, "w": Vector3.LEFT}[face]
		var half: float = ((float(box[1])-float(box[0])) if face in ["e","w"] else (float(box[3])-float(box[2])))*0.5
		var side := direction.cross(Vector3.UP)
		var height := float(house["ridge"])
		var width: float = ((float(box[3])-float(box[2])) if face in ["e","w"] else (float(box[1])-float(box[0])))
		var street_distance := maxf(5.0, maxf(height*0.72,width*0.45))
		var facade := center + direction*(half+street_distance) + Vector3(0,1.62,0)
		# The front birch obscures this house from the straight-on road position.
		if house["id"] == "neighbour-04": facade += side*3.6
		if camera_plan.is_empty(): facade = _clear_stance(main.get("col"), facade, side)
		var target := center + Vector3(0,height*0.47,0)
		views.append({"id":house["id"], "view":"facade", "at":facade,"target":target})
		var yard_at := facade+side*3.5
		if camera_plan.is_empty(): yard_at = _clear_stance(main.get("col"),yard_at,side)
		views.append({"id":house["id"], "view":"yard", "at":yard_at,"target":center+side*1.6+Vector3(0,height*0.36,0)})
	if details:
		views.clear()
		var detail_plan: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/environment_views.json"))
		for record: Dictionary in detail_plan["views"]:
			if not filter.is_empty() and not String(record["id"]) in filter.split(","): continue
			var at: Array = record["at"]
			var target: Array = record["target"]
			var view := record.duplicate()
			view["at"] = Vector3(at[0],at[1],at[2])
			view["target"] = Vector3(target[0],target[1],target[2])
			if camera_plan.is_empty() and not bool(record.get("fixed_stance",false)):
				view["at"] = _clear_stance(main.get("col"),view["at"],Vector3.RIGHT)
			views.append(view)
	if not camera_plan.is_empty():
		var metadata: Dictionary = {}
		for view: Dictionary in views: metadata[String(view["id"])+"/"+String(view["view"])] = view
		views.clear()
		var saved: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(camera_plan))
		for shot: Dictionary in saved["captures"]:
			if shot["mode"] != "neutral": continue
			if not filter.is_empty() and not String(shot["id"]) in filter.split(","): continue
			var at: Array = shot["camera"]
			var target: Array = shot["target"]
			chain.camera.fov = float(shot["fov"])
			var view: Dictionary = metadata.get(String(shot["id"])+"/"+String(shot["view"]),{}).duplicate()
			view.merge({"id":shot["id"],"view":shot["view"],"at":Vector3(at[0],at[1],at[2]),"target":Vector3(target[0],target[1],target[2])},true)
			views.append(view)
	var modes: Array = ["neutral", "game"]
	if matrix: modes += ["night-flash", "night-dark", "rain", "blackout"]
	for mode: String in modes:
		chain.set_vhs_amount(0.0 if mode == "neutral" else 0.30)
		lights.set_night_immediate(0.10 if mode in ["neutral","game"] else 1.0)
		lights.powerOn = mode != "blackout"
		main.get("weather").clear()
		chain.set_vhs(&"rain", 0.80 if mode == "rain" else 0.0)
		var flash: Flashlight = main.get("flashlight")
		flash.on = mode in ["night-flash","rain"]
		flash.light.visible = flash.on
		for view: Dictionary in views:
			var decor: Variant = main.get("everyday")
			if decor != null and view.has("reset"):
				var def: Dictionary = decor.definitions[view["reset"]]
				var flag := String(def.get("flag",""))
				if not flag.is_empty(): (main.get("state") as GameState).set_flag(flag,false)
				decor.resync(main.get("state"))
				player.place(view["at"].x,float(view.get("floor_y",0.035)),view["at"].z,0.0)
				if not String(view.get("action","")).is_empty():
					if not decor.use(view["action"]): capture_errors.append("Detail activation failed: %s" % view["action"])
					decor.update(0.35 if String(def["kind"]) == "pump" else 0.61)
			chain.camera.global_position = view["at"]
			chain.camera.look_at(view["target"])
			for i in 24:
				lights.update(1.0/60.0,chain.camera.global_position,"plot",true)
				flash.set("_body", chain.camera.global_position + chain.camera.global_basis.x*0.17 - chain.camera.global_basis.y*0.13)
				flash.set("_aim", view["target"])
				flash.update(0.0)
				await process_frame
			await RenderingServer.frame_post_draw
			var image := root.get_texture().get_image() if ui.reader.open else chain.post_view.get_texture().get_image()
			var filename := "%s-%s-%s.png" % [view["id"],view["view"],mode]
			assert(image.save_png(output.path_join(filename)) == OK)
			rows.append({"file":filename,"id":view["id"],"view":view["view"],"mode":mode,
				"camera":[view["at"].x,view["at"].y,view["at"].z],
				"target":[view["target"].x,view["target"].y,view["target"].z],"fov":chain.camera.fov,"stats":chain.stats()})
			ui.closeReader()
	var file := FileAccess.open(output.path_join("captures.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify({"captures":rows,"coverage":coverage,"errors":capture_errors},"\t"))
	file.close()
	for error: String in capture_errors: printerr("capture_environment: " + error)
	print("capture_environment: %s %d captures" % ["PASS" if capture_errors.is_empty() else "FAIL",rows.size()])
	main.queue_free()
	await process_frame
	await process_frame
	quit(0 if capture_errors.is_empty() else 1)

func _clear_stance(col: CollisionWorld, origin: Vector3, side: Vector3) -> Vector3:
	for offset: float in [0.0,1.2,-1.2,2.4,-2.4,3.6,-3.6,4.8,-4.8]:
		var at := origin + side*offset
		# Hollow buildings pass the capsule test, but obscure an exterior view.
		var inside_house := false
		for house: Dictionary in house_footprints:
			var box: Array = house["footprint"]
			if at.x >= float(box[0])-.3 and at.x <= float(box[1])+.3 and at.z >= float(box[2])-.3 and at.z <= float(box[3])+.3:
				inside_house = true
				break
		if inside_house: continue
		if col.point_hit(at.x, at.y, at.z, CollisionWorld.ALL_SOLID): continue
		if col.capsule_hit(at+Vector3(0,-1.2,0),at+Vector3(0,-0.22,0),0.27,CollisionWorld.ALL_SOLID).is_empty():
			return at
	capture_errors.append("No accessible capture stance: %s" % origin)
	return origin

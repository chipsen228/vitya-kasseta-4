# Runtime owners remain authoritative when their decorative meshes change.
# Optional --snapshot=absolute.json records collision/interaction contracts.
extends SceneTree

var _errors: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	var main: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for _i in 900:
		if _boot_ready(main):
			break
		await process_frame
	if not _boot_ready(main):
		printerr("test_graphics_bindings: FAIL boot timeout")
		quit(1)
		return
	main.call("_start_game")
	await _cards(main)
	_snapshot(main)
	_check_doors(main)
	_check_flashlight_suppression(main)
	await _check_apples(main)
	await _check_endings(main)
	for error: String in _errors:
		printerr("FAIL test_graphics_bindings: ", error)
	print("test_graphics_bindings: %s (owners, apples/retry, five endings, early drive, cinematic hands)" % ("PASS" if _errors.is_empty() else "FAIL"))
	quit(0 if _errors.is_empty() else 1)


func _snapshot(main: Node) -> void:
	var path := ""
	var reference := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--snapshot="):
			path = arg.trim_prefix("--snapshot=")
		elif arg.begins_with("--reference="):
			reference = arg.trim_prefix("--reference=")
	if path.is_empty():
		return
	var col: CollisionWorld = main.get("col")
	var collisions: Array = []
	for set_id in CollisionWorld.SET_COUNT:
		var boxes: Array = []
		for i in col.box_count(set_id):
			boxes.append(Array(col.box_aabb_d(set_id, i)))
		collisions.append({"set": set_id, "count": boxes.size(), "boxes": boxes})
	var interactions: Array = []
	var interact: Interact = main.get("interact")
	for entry: Dictionary in interact.list:
		var position: Vector3 = entry.get("pos", Vector3.ZERO)
		interactions.append({"id": entry.get("id", ""), "pos": [position.x, position.y, position.z], "radius": entry.get("r", 0.0)})
	var nav: NavGraph = main.get("nav")
	var snapshot := {"collisions": collisions, "interactions": interactions, "navigation": nav.stats()}
	if not reference.is_empty():
		var old: Variant = JSON.parse_string(FileAccess.get_file_as_string(reference))
		if old is not Dictionary:
			_errors.append("cannot parse reference snapshot " + reference)
		else:
			for set_id in CollisionWorld.SET_COUNT:
				var before: Array = old.get("collisions", [])[set_id].get("boxes", [])
				var after: Array = collisions[set_id]["boxes"]
				if _sorted_json(before) != _sorted_json(after):
					_errors.append("collision set %d changed from verified baseline" % set_id)
			if _sorted_json(old.get("interactions", [])) != _sorted_json(interactions):
				_errors.append("interaction IDs/positions/radii changed from verified baseline")
			# JSON numbers deserialize as floats; normalize both sides before typed equality.
			var navigation: Dictionary = JSON.parse_string(JSON.stringify(snapshot["navigation"]))
			if not (old.get("navigation", {}) as Dictionary).recursive_equal(navigation, 0):
				_errors.append("navigation stats changed from verified baseline")
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		_errors.append("cannot save functional snapshot " + path)
	else:
		file.store_string(JSON.stringify(snapshot, "\t"))
		file.close()
		print("functional snapshot: ", path)


func _sorted_json(values: Array) -> Array[String]:
	var out: Array[String] = []
	for value: Variant in values:
		out.append(JSON.stringify(value, "", true))
	out.sort()
	return out


func _check_doors(main: Node) -> void:
	var built: Dictionary = main.get("built")
	var col: CollisionWorld = main.get("col")
	for blocker: Dictionary in built.get("blockers", []):
		var id := String(blocker.get("id", ""))
		if not id.begins_with("door-"):
			continue
		var owner := blocker.get("node") as Node3D
		if owner == null:
			_errors.append(id + " has no visual owner")
			continue
		var origin := owner.position
		var closed := col.is_blocker_active(id)
		main.call("_ctx_set_door", id, true, true)
		if col.is_blocker_active(id) or absf(owner.rotation.y) < 1.0:
			_errors.append(id + " opening did not move visual and blocker together")
		if not owner.position.is_equal_approx(origin):
			_errors.append(id + " changed hinge origin")
		main.call("_ctx_set_door", id, false, true)
		if not col.is_blocker_active(id) or absf(owner.rotation.y) > 0.001:
			_errors.append(id + " closing did not restore visual and blocker")
		main.call("_ctx_set_door", id, not closed, true)


func _check_apples(main: Node) -> void:
	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var ctx: Dictionary = main.get("ctx")
	var yard: Dictionary = (ctx.get("world", {}) as Dictionary).get("yard", {})
	var nodes: Dictionary = yard.get("nodes", {})
	state.give("flashlight")
	chapters.go("tapes")
	await _cards(main)
	var before := state.snapshot()
	for i in 3:
		var id := "apples-%d" % i
		var owner := nodes.get(id) as Node3D
		if owner == null or owner.get_child_count() == 0:
			_errors.append(id + " has no fruit visual owner/mesh")
			continue
		await _use(main, "apple-tree-%d" % i)
		if owner.visible or not state.has("apple-picked-%d" % i):
			_errors.append(id + " remains after collection")
	state.restore(before)
	Interact.resync_world(ctx)
	for i in 3:
		var owner := nodes.get("apples-%d" % i) as Node3D
		if owner == null or not owner.visible:
			_errors.append("retry did not restore apples-%d" % i)


func _check_flashlight_suppression(main: Node) -> void:
	var flashlight: Flashlight = main.get("flashlight")
	flashlight.give()
	flashlight.on = true
	flashlight.light.light_energy = 14.0 * Flashlight.ENERGY_SCALE
	# Begin with the actual lit render state, as it is before entering a cinematic.
	flashlight.update(0.0)
	var battery := flashlight.battery
	var energy := flashlight.light.light_energy
	var shadows := flashlight.light.shadow_enabled
	flashlight.set_cinematic_suppressed(true)
	if flashlight.light.visible:
		_errors.append("cinematic left the real spotlight visible while update is frozen")
	if (flashlight.cone != null and flashlight.cone.visible) or (flashlight.halo != null and flashlight.halo.visible):
		_errors.append("cinematic left the beam cone/halo visible")
	flashlight.set_cinematic_suppressed(false)
	if not flashlight.light.visible or flashlight.light.light_energy != energy:
		_errors.append("cinematic cleanup did not restore the spotlight")
	if not flashlight.on or not flashlight.owned or flashlight.battery != battery:
		_errors.append("cinematic suppression changed flashlight gameplay state")
	if flashlight.light.shadow_enabled != shadows or flashlight._shadow_on != shadows:
		_errors.append("cinematic suppression invalidated the shadow-state cache")


func _check_endings(main: Node) -> void:
	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var ctx: Dictionary = main.get("ctx")
	var cut: Cutscene = main.get("cutscene")
	var chain: RenderChain = main.get("render_chain")
	for which: String in ["alone", "morning", "kovrigin", "quiet", "caught"]:
		main.call("_on_restart")
		state.give("flashlight")
		state.give("car-key")
		state.set_flag("tank-full")
		chapters.go("dark")
		await _cards(main)
		state.evidence = which in ["morning", "kovrigin"]
		if which == "kovrigin":
			state.set_flag("kovrigin-letter")
			state.give("kovrigin-tapes")
		if which == "quiet":
			state.set_flag("hatch-sealed")
			chapters.call("_gate_drive", ctx, null)
		elif which == "caught":
			chapters.go("gate")
			await _cards(main)
			state.failCount = 2
			chapters.emit("caught")
		else:
			# Take the ordinary pre-village car interaction, including its delay.
			await _use(main, "car-drive")
			var started := Time.get_ticks_msec()
			while not cut.playing and state.chapter != "end" and Time.get_ticks_msec() - started < 5000:
				await process_frame
			if not cut.playing:
				_errors.append(which + " early drive did not start the car scene")
			else:
				if float(chain.get_vhs(&"hand_mix")) > 0.01:
					_errors.append(which + " cinematic did not hide hands")
				for _i in 110:
					if not cut.playing:
						break
					cut.update(0.1)
					await process_frame
		var ending_wait := Time.get_ticks_msec()
		while state.ending == null and Time.get_ticks_msec() - ending_wait < 5000:
			await process_frame
		print("ending probe ", which, ": ", str(state.ending))
		if str(state.ending) != which or state.chapter != "end":
			_errors.append("ending %s became %s / %s" % [which, state.ending, state.chapter])
		if cut.playing:
			_errors.append(which + " ending left its cutscene running")


func _use(main: Node, id: String) -> void:
	var interact: Interact = main.get("interact")
	var state: GameState = main.get("state")
	for entry: Dictionary in interact.list:
		if String(entry.get("id", "")) != id:
			continue
		if entry.has("when") and not bool((entry["when"] as Callable).call(state)):
			_errors.append(id + " is unavailable in its prepared state")
			return
		interact.target = entry
		interact.use(main.get("ctx"))
		await process_frame
		return
	_errors.append("missing interaction " + id)


func _cards(main: Node) -> void:
	var ui: Overlays = main.get("ui")
	for _i in 50:
		if ui.card.open:
			ui.advanceCard()
		await process_frame


func _boot_ready(main: Node) -> bool:
	if main.get("chapters") == null:
		return false
	var ready: Variant = main.get("boot_ready")
	if ready != null:
		return bool(ready)
	# Old builds finish startup after chapters exists; wait for the loading screen.
	var ui: Node = main.get("ui")
	var loading: Control = ui.get("_load") if ui != null else null
	return loading != null and not loading.visible

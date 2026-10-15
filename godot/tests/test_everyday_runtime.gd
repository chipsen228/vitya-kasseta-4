extends SceneTree

var errors: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var main: Node = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for frame in 1600:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		printerr("test_everyday_runtime: boot failed")
		quit(1)
		return
	main.call("_start_game")
	var ui: Overlays = main.get("ui")
	for card in 80:
		if not ui.card.open: break
		ui.advanceCard()
	main.set_process(false)
	var c: Dictionary = main.get("ctx")
	var s: GameState = c["state"]
	var everyday: EverydayInteractions = c.get("everyday")
	if everyday == null:
		printerr("test_everyday_runtime: missing controller")
		quit(1)
		return
	_legacy_targets(c["interact"], everyday)
	var chapters: Chapters = c["chapters"]
	var capture: CaptureRecovery = c["capture"]
	var audio: GameAudio = c["audio"]
	var gate: Dictionary = everyday.definitions["decor-gate-p02"]
	chapters.go("arrive", true)
	c["controls"].place(0, 0, 4, 0)
	_check(everyday.use(gate["id"]), "animation before pause")
	main.call("_set_paused", true)
	var angle := everyday._moving_angle(gate)
	for frame in 4:
		main.call("_process", 0.05)
		await process_frame
	_check(everyday._moving_angle(gate) == angle, "main pause advanced gate")
	main.call("_set_paused", false)
	main.call("_process", 0.05)
	_check(everyday._moving_angle(gate) > angle, "main did not resume gate")
	everyday.update(0.61)
	chapters.pushTask(true)
	var saved := str(s.checkpoint)
	_check(s.has(gate["flag"]), "open gate before checkpoint")
	_check(everyday.use(gate["id"]), "partial close before retry")
	everyday.update(0.20)
	chapters.retry()
	_check(s.has(gate["flag"]) and str(s.checkpoint) == saved and everyday.animations.is_empty(), "retry lost stable decor/checkpoint")
	_check(not (c["col"] as CollisionWorld).is_blocker_active(gate["id"]), "retry left open gate collider")
	_check(everyday.use(gate["id"]), "partial close before capture")
	everyday.update(0.20)
	_check(everyday.use(EverydayInteractions.RADIO_OWNER), "radio before capture")
	_check(capture.begin("dark"), "capture did not start")
	_check(everyday.animations.is_empty() and s.has(gate["flag"]) and everyday.radio_remaining == 0.0,
		"capture retained transient decor")
	_check(not audio._spatial_owners.has(EverydayInteractions.RADIO_OWNER), "capture retained radio audio")
	_check(not everyday.use(EverydayInteractions.RADIO_OWNER), "capture permits radio")
	var recovery_save := s.snapshot()
	capture.cancel()
	s.restore(recovery_save)
	main.call("_process", 0.05)
	_check(capture.active() and everyday.animations.is_empty(), "saved recovery did not cancel decor")
	capture.cancel()
	chapters.go("arrive", true)
	_check(everyday.use(EverydayInteractions.RADIO_OWNER), "radio before paused cutscene")
	main.call("_set_paused", true)
	main.call("_process", 0.05)
	_check(everyday.radio_remaining == EverydayInteractions.RADIO_SECONDS \
		and audio._spatial_owners.has(EverydayInteractions.RADIO_OWNER), "pause cancelled radio instead of pausing")
	var cutscene: Cutscene = c["cutscene"]
	cutscene.playing = true
	cutscene.paused = true
	main.call("_process", 0.05)
	_check(everyday.radio_remaining == 0.0 and not audio._spatial_owners.has(EverydayInteractions.RADIO_OWNER) \
		and not everyday.use(EverydayInteractions.RADIO_OWNER),
		"frozen cutscene retained radio")
	cutscene.cancel()
	cutscene.paused = false
	main.call("_set_paused", false)
	_check(everyday.use(EverydayInteractions.RADIO_OWNER), "radio before mandatory horror")
	var horror: HorrorDirector = c["horror"]
	horror.hold(3.0, "mandatory")
	main.call("_set_paused", true)
	main.call("_process", 0.05)
	_check(everyday.radio_remaining == 0.0 and not audio._spatial_owners.has(EverydayInteractions.RADIO_OWNER) \
		and not everyday.use(EverydayInteractions.RADIO_OWNER), "frozen mandatory horror retained or restarted radio")
	_check(not s.has("decor-p09-radio-used") and not s.flags.has(""), "scene cancellation persisted radio state")
	horror.invalidate()
	main.call("_set_paused", false)
	_check(everyday.use(EverydayInteractions.RADIO_OWNER), "radio before chapter")
	chapters.go("light", true)
	_check(everyday.radio_remaining == 0.0 and everyday.radio_cooldown == 0.0, "chapter retained radio runtime")
	_check(everyday.use("decor-shed-cabinet"), "cabinet before restart")
	everyday.update(0.20)
	main.call("_on_restart")
	_check(s.flags.is_empty() and everyday.animations.is_empty() and everyday.radio_remaining == 0.0,
		"new game retained decor")
	for id: String in everyday.definitions:
		var d: Dictionary = everyday.definitions[id]
		if String(d["kind"]) in ["gate", "cabinet", "barrel"]:
			_check(is_zero_approx(everyday._moving_angle(d)), "new game left open " + id)
	main.queue_free()
	await process_frame
	for error: String in errors: printerr(error)
	print("test_everyday_runtime: ", "PASS" if errors.is_empty() else "FAIL")
	quit(0 if errors.is_empty() else 1)


func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)


func _legacy_targets(interact: Interact, everyday: EverydayInteractions) -> void:
	var legacy: Dictionary = {}
	for target: Dictionary in interact.list:
		if everyday.definitions.has(target["id"]): continue
		legacy[target["id"]] = target
		_check(int(target.get("los_mask", CollisionWorld.MASK_STATIC)) == CollisionWorld.MASK_STATIC \
			and not target.has("los_ignore_blocker"), "legacy LOS changed " + String(target["id"]))
	_check(legacy.size() == 274, "actual main lost legacy descriptors: " + str(legacy.size()))
	# Optional approved ledger supplies all original positions/radii without an output-path dependency.
	for argument: String in OS.get_cmdline_user_args():
		if not argument.begins_with("--baseline="): continue
		var path := argument.trim_prefix("--baseline=")
		_check(FileAccess.file_exists(path), "baseline file missing " + path)
		if not FileAccess.file_exists(path): continue
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		_check(data is Dictionary and data.get("interactions") is Array, "invalid baseline ledger")
		if not data is Dictionary or not data.get("interactions") is Array: continue
		var rows: Array = data["interactions"]
		_check(rows.size() == legacy.size(), "legacy descriptor count differs from baseline")
		for row: Dictionary in rows:
			var id := String(row["id"])
			_check(legacy.has(id), "missing baseline target " + id)
			if not legacy.has(id): continue
			var pos: Array = row["pos"]
			var expected := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
			_check((legacy[id]["pos"] as Vector3).distance_squared_to(expected) < 1e-10 \
				and is_equal_approx(float(legacy[id]["r"]), float(row["radius"])), "legacy target moved " + id)
		print("actual main legacy ledger: ", rows.size(), " original IDs/positions/radii checked")

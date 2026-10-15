# Размещение синхронизирует отдельную камеру даже при отключённом update().
extends SceneTree

var errors: Array[String] = []
var checks := 0
var integration_completed := false

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	_unit_placement()
	await _main_transitions()
	_check(integration_completed and checks >= 30, "integration aborted before all placement transitions completed")
	for message: String in errors: printerr("test_player_placement: ", message)
	print("test_player_placement: ", "PASS" if errors.is_empty() else "FAIL", " checks=", checks)
	quit(0 if errors.is_empty() else 1)

func _unit_placement() -> void:
	var player := Player.new()
	var camera := Camera3D.new()
	player.camera = camera
	camera.position = Vector3(9, 8, 7)
	player.place(1, 2, 3, 0.2)
	_check(player.position == Vector3(1, 2, 3) and camera.position == Vector3(9, 8, 7), "pre-tree placement changed an unbound global camera")
	root.add_child(camera)
	root.add_child(player)
	player.enabled = false
	player.pitch = -0.41
	player.pitch_target = 0.27
	player.bob_amount = 0.8
	player.bob_phase = 1.7
	player.velocity = Vector3(2, 3, 4)
	player.place(CaptureRecovery.CELLAR.x, CaptureRecovery.CELLAR.y, CaptureRecovery.CELLAR.z, 0.8)
	_check(camera.global_position.is_equal_approx(player.eyes()), "disabled standing camera did not move synchronously")
	_check(camera.global_basis.is_equal_approx(Basis.from_euler(Vector3(-0.41, 0.8, 0), EULER_ORDER_YXZ)), "placement changed pitch or used the old yaw")
	_check(player.height == Player.STAND_HEIGHT and player.height_target == Player.STAND_HEIGHT and not player.enabled, "placement changed height or control ownership")
	_check(player.pitch == -0.41 and player.pitch_target == 0.27, "placement changed current/target pitch")
	_check(player.velocity == Vector3.ZERO and player.bob_amount == 0 and player.yaw_target == 0.8, "placement retained stale motion/bob/yaw target")
	var placed_camera := camera.global_transform
	player.update(0.016)
	_check(camera.global_transform == placed_camera, "disabled update disturbed the placed camera")
	player.height = Player.CROUCH_HEIGHT
	player.height_target = Player.CROUCH_HEIGHT
	player.call("_apply_height")
	player.pitch = 0.31
	player.pitch_target = -0.2
	player.place(-3.6, 0.45, 8.5, -0.65)
	_check(camera.global_position.is_equal_approx(Vector3(-3.6, 1.59, 8.5)), "crouched placement used standing eye height")
	_check(player.height == Player.CROUCH_HEIGHT and player.height_target == Player.CROUCH_HEIGHT and player.pitch == 0.31 and player.pitch_target == -0.2, "crouched placement changed height/pitch")
	var detached := Camera3D.new()
	detached.position = Vector3(5, 6, 7)
	player.camera = detached
	player.place(2, 3, 4, 1.0)
	_check(detached.position == Vector3(5, 6, 7), "placement wrote global state to a detached camera")
	player.camera = null
	player.place(3, 4, 5)
	_check(player.feet() == Vector3(3, 4, 5), "placement without a camera failed")
	detached.free()
	player.free()
	camera.free()

func _main_transitions() -> void:
	var main: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for _i in 1600:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		_check(false, "actual Main boot timeout")
		main.queue_free()
		await process_frame
		return
	main.call("_start_game")
	var ui: Overlays = main.get("ui")
	for _i in 60:
		if not ui.card.open: break
		ui.advanceCard()
	main.set_process(false)
	var ctx: Dictionary = main.get("ctx")
	var player: Player = ctx["controls"]
	var camera: Camera3D = ctx["renderer"].camera
	var state: GameState = ctx["state"]
	var chapters: Chapters = ctx["chapters"]
	var capture: CaptureRecovery = ctx["capture"]
	var cut: Cutscene = ctx["cutscene"]
	main.call("_cancel_horror_runtime")
	state.chapter = "village"
	state.ending = null
	state.threatState = "patrol"
	state.set_flag("placement-preserve")
	state.give("car-key")
	state.checkpoint = GameState.new().snapshot()
	chapters.current = (chapters.get("_defs") as Dictionary)["village"]
	chapters.timers.clear()
	main.set("running", true)
	main.set("paused", false)
	player.height = Player.STAND_HEIGHT
	player.height_target = Player.STAND_HEIGHT
	player.call("_apply_height")
	player.pitch = -0.47
	player.pitch_target = -0.47
	var flags := state.flags.duplicate(true)
	var checkpoint: Variant = state.checkpoint
	var inventory := state.inventory.duplicate(true)
	var hatch: Dictionary = {}
	for item: Dictionary in GameData.site()["HATCHES"]:
		if item["id"] == "hatch-cellar": hatch = item
	_check(not hatch.is_empty(), "actual cellar hatch missing")
	var top: Vector3 = GameData.vec3(hatch["top"])
	var bottom: Vector3 = GameData.vec3(hatch["bottom"])
	player.place(top.x, top.y, top.z, 0.0)
	main.call("_use_hatch", {"hatch": hatch, "down": true})
	var first_return := false
	var until := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < until:
		await process_frame
		if player.feet().distance_to(bottom) < 0.01:
			first_return = true
			_check(bool(main.get("busy")) and not player.enabled, "hatch fixture missed the disabled first fade-up frame")
			_check(camera.global_position.is_equal_approx(player.eyes()), "hatch first fade-up frame retained the upper-floor camera")
			_check(player.pitch == -0.47 and camera.global_basis.is_equal_approx(Basis.from_euler(Vector3(-0.47, 0, 0), EULER_ORDER_YXZ)), "ordinary hatch descent reset the player's pitch")
			break
	_check(first_return, "ordinary hatch did not reach the cellar")
	until = Time.get_ticks_msec() + 3000
	while bool(main.get("busy")) and Time.get_ticks_msec() < until: await process_frame
	_check(not bool(main.get("busy")) and player.enabled, "hatch fade did not finish")
	_check(state.flags == flags and state.checkpoint == checkpoint and state.inventory == inventory, "ordinary hatch changed story flags/checkpoint/inventory")
	player.place(0, 0, 2, 0)
	player.pitch = 0.52
	player.pitch_target = 0.52
	_check(capture.begin("placement", false), "actual capture did not start")
	var capture_flags := state.flags.duplicate(true)
	cut.update(1.5)
	_check(cut.skip(), "actual capture skip did not finish")
	_check(capture.phase == "cellar" and player.feet().is_equal_approx(CaptureRecovery.CELLAR), "capture skip did not place the player")
	_check(camera.current and camera.global_position.is_equal_approx(player.eyes()) and camera.global_basis.is_equal_approx(Basis.IDENTITY), "capture skip exposed stale position/pitch before the next update")
	_check(player.height == Player.STAND_HEIGHT and is_equal_approx(camera.global_position.y, 0.13), "cellar transfer changed standing height or eye height")
	_check(state.flags == capture_flags and state.checkpoint == checkpoint and state.inventory == inventory, "capture completion changed story flags/checkpoint/inventory")
	await physics_frame
	var probe := CapsuleShape3D.new()
	probe.radius = Player.RADIUS
	probe.height = Player.STAND_HEIGHT - Player.STAND_PROBE_LIFT
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = probe
	query.collision_mask = Player.MASK_WORLD
	query.exclude = [player.get_rid()]
	query.margin = 0.001
	query.transform = Transform3D(Basis.IDENTITY, CaptureRecovery.CELLAR + Vector3(0, (Player.STAND_HEIGHT + Player.STAND_PROBE_LIFT) * 0.5, 0))
	_check(player.get_world_3d().direct_space_state.intersect_shape(query, 8).is_empty(), "standing recovery capsule overlaps actual native cellar geometry")
	var saved := state.snapshot()
	capture.cancel()
	state.restore(saved)
	player.pitch = -0.63
	player.pitch_target = -0.63
	player.enabled = false
	player.place(0, 0, 2, 0.8)
	_check(capture.resume_saved(), "saved recovery did not resume")
	_check(camera.global_position.is_equal_approx(player.eyes()) and camera.global_basis.is_equal_approx(Basis.IDENTITY), "resume_saved exposed stale position/pitch before the next update")
	_check(player.pitch == 0 and player.pitch_target == 0 and player.height == Player.STAND_HEIGHT, "saved recovery failed to reset pitch while preserving height")
	_check(state.flags == capture_flags and state.checkpoint == checkpoint and state.inventory == inventory, "saved recovery placement changed story flags/checkpoint/inventory")
	capture.cancel()
	player.place(0, 0, 2, 0.3)
	player.pitch = 0.39
	player.pitch_target = 0.39
	_check(capture.begin("placement", false), "normal capture fixture did not start")
	cut.update(CaptureRecovery.LENGTH + 0.1)
	_check(capture.phase == "cellar" and camera.current and camera.global_position.is_equal_approx(player.eyes()) and camera.global_basis.is_equal_approx(Basis.IDENTITY), "normal capture finish exposed stale camera before the next update")
	_check(state.flags == capture_flags and state.checkpoint == checkpoint and state.inventory == inventory, "normal capture completion changed story flags/checkpoint/inventory")
	capture.cancel()
	main.queue_free()
	await process_frame
	await process_frame
	integration_completed = true

func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: errors.append(message)

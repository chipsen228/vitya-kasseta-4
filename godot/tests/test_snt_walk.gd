# Реальное движение Player по коридорам СНТ без телепортации между целями.
extends SceneTree

var _frames := 0
var _distance := 0.0
var _errors: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var main: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 1800:
		if bool(main.get("boot_ready")):
			break
		await process_frame
	main.call("_start_game")
	var ui: Overlays = main.get("ui")
	for i in 90:
		if ui.card.open:
			ui.advanceCard()
		await process_frame
	main.set("running", false)
	var p: Player = main.get("player")
	p.release_lock()
	p.enabled = true
	p.frozen = false
	p.place(36.8, 0.02, -33.0, 0.0)
	var path := [
		Vector2(36.8, -38.3), Vector2(12.2, -38.3),
		Vector2(12.2, -35.4), Vector2(4.4, -35.4), Vector2(4.4, -37.55),
		Vector2(4.4, -35.4), Vector2(-15.3, -35.4), Vector2(-15.3, -39.0),
		Vector2(-15.3, -35.4), Vector2(-0.45, -35.4), Vector2(-0.45, -40.2),
		Vector2(-0.45, -35.4), Vector2(12.2, -35.4), Vector2(12.2, -38.3),
		Vector2(19, -38.3), Vector2(19, -42.0), Vector2(19, -38.3),
		Vector2(12.2, -38.3), Vector2(12.2, -53.8), Vector2(-20, -53.8),
		Vector2(-20, -61.8), Vector2(3.4, -61.8), Vector2(3.4, -64.1), Vector2(7.1, -64.1), Vector2(8.07, -66.3),
		Vector2(7.1, -64.1), Vector2(3.4, -64.1), Vector2(3.4, -61.8), Vector2(-20, -61.8), Vector2(-20, -53.8),
		Vector2(12.2, -53.8), Vector2(12.2, -38.3), Vector2(19, -38.3), Vector2(19, -42.0),
	]
	Input.action_press("move_forward")
	var targets := {4: "snt-watch-log", 7: "snt-last-round", 10: "snt-watermarks", 15: "snt-yard", 24: "snt-signal", 33: "snt-return"}
	for index in path.size():
		if not await _walk(p, path[index]):
			break
		if targets.has(index):
			_check_target(main, String(targets[index]))
	Input.action_release("move_forward")
	for error in _errors:
		printerr("FAIL ", error)
	print("test_snt_walk: %s distance=%.1fm walking_time=%.1fs waypoints=%d" % ["PASS" if _errors.is_empty() else "FAIL", _distance, float(_frames) / 60.0, path.size()])
	quit(0 if _errors.is_empty() else 1)

func _walk(p: Player, target: Vector2) -> bool:
	var start := Vector2(p.feet().x, p.feet().z)
	var limit := int((start.distance_to(target) / Player.SPEED_WALK + 5.0) * 60.0)
	for i in limit:
		var current := Vector2(p.feet().x, p.feet().z)
		if current.distance_to(target) < 0.12:
			return true
		var direction := target - current
		p.yaw = atan2(-direction.x, -direction.y)
		p.yaw_target = p.yaw
		await physics_frame
		p.update(1.0 / 60.0)
		_frames += 1
		_distance += current.distance_to(Vector2(p.feet().x, p.feet().z))
		if p.feet().y < -0.5:
			_errors.append("fall at %s toward %s" % [p.feet(), target])
			return false
	_errors.append("blocked at %s toward %s" % [p.feet(), target])
	return false

func _check_target(main: Node, id: String) -> void:
	var state: GameState = main.get("state")
	state.chapter = "village"
	for flag: String in ["mill-clue", "snt-watch-read", "snt-yard-seen"]:
		state.set_flag(flag)
	if id == "snt-return":
		# The full investigation is covered by test_snt_quest; this walk checks
		# the unchanged physical approach to the returning Lebedev interaction.
		for flag: String in ["snt-booth-used", "snt-nina-greenhouse", "snt-route-known", "snt-radio-heard"]:
			state.set_flag(flag)
	var ctx: Dictionary = main.get("ctx")
	ctx["snt"].resync(state)
	var interaction: Interact = main.get("interact")
	for definition: Dictionary in interaction.list:
		if String(definition.get("id", "")) != id:
			continue
		var player: Player = main.get("player")
		var target: Vector3 = definition["pos"]
		var delta := target - player.eyes()
		player.yaw = atan2(-delta.x, -delta.z)
		player.yaw_target = player.yaw
		player.pitch = atan2(delta.y, Vector2(delta.x, delta.z).length())
		player.pitch_target = player.pitch
		player.call("_apply_camera")
		var found: Variant = interaction.find(main.get("render_chain").camera, state)
		if not found is Dictionary or String(found.get("id", "")) != id:
			_errors.append("target cannot be selected after walking: " + id + " got " + str(found))
		return
	_errors.append("missing target " + id)

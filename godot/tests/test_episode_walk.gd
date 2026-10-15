# Real Player collision movement through both forest loops at the stock physics rate.
extends SceneTree

var errors: Array[String] = []
var frames := 0
var distance := 0.0
var reached := 0
var min_x := INF
var min_z := INF
var max_step := 0.0
var col: CollisionWorld
const LIMIT_SECONDS := 180.0

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var main: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for frame in 1800:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		printerr("FAIL test_episode_walk: boot")
		quit(1)
		return
	main.call("_start_game")
	var ui: Overlays = main.get("ui")
	for frame in 40:
		if ui.card.open: ui.advanceCard()
		await process_frame
	main.set_process(false)
	var c: Dictionary = main.get("ctx")
	var state: GameState = c["state"]
	state.chapter = "village"
	state.set_flag("mill-clue")
	state.set_flag("snt-booth-used")
	c["snt"].resync(state)
	col = c["col"]
	var p: Player = c["controls"]
	p.release_lock()
	p.enabled = true
	p.frozen = false
	# The sole placement is the real external-capture retry anchor.
	p.place(9.6, 0.02, -70.0, 0.0)
	var path: Array[Vector2] = [
		Vector2(9.6,-74.5), Vector2(7.1,-74.5), Vector2(7.1,-78),
		Vector2(-12,-78), Vector2(-12,-82), Vector2(-34,-82), Vector2(-34,-78),
		Vector2(-12,-78), Vector2(-34,-78), Vector2(-52,-78), Vector2(-52,-65),
		Vector2(-55,-65), Vector2(-55,-54.5), Vector2(-52,-54.5),
		Vector2(-52,-65), Vector2(-52,-54.5), Vector2(-44,-54.5),
		Vector2(-26,-54.5), Vector2(-26,-52), Vector2(-20,-52), Vector2(-20,-53.8),
		Vector2(12.2,-53.8), Vector2(12.2,-38.3), Vector2(19,-38.3),
		Vector2(36.8,-38.3), Vector2(36.8,-34.2),
	]
	Input.action_press("move_forward")
	Input.action_press("run")
	for target in path:
		if not await _walk(p, target): break
		reached += 1
		if reached == 17: print("test_episode_walk: west exit reached through both forest loops")
	Input.action_release("run")
	Input.action_release("move_forward")
	_check(reached == path.size(), "route incomplete: %d/%d" % [reached, path.size()])
	_check(min_x < -54.8 and min_z < -81.8, "forest extent clamped before outer branches")
	_check(Vector2(p.feet().x, p.feet().z).distance_to(Vector2(36.8,-34.2)) < 0.2, "old south exit not reached")
	for error in errors: printerr("FAIL ", error)
	print("test_episode_walk: %s distance=%.1fm active_time=%.1fs waypoints=%d/%d max_step=%.3fm stock_ticks=%d" % ["PASS" if errors.is_empty() else "FAIL", distance, float(frames)/Engine.physics_ticks_per_second, reached, path.size(), max_step, Engine.physics_ticks_per_second])
	quit(0 if errors.is_empty() else 1)

func _walk(p: Player, target: Vector2) -> bool:
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	var start := Vector2(p.feet().x, p.feet().z)
	var limit := int((start.distance_to(target) / Player.SPEED_WALK + 4.0) / dt)
	var stalled := 0.0
	for frame in limit:
		var before := p.feet()
		var current := Vector2(before.x, before.z)
		if current.distance_to(target) < 0.12: return true
		if float(frames) * dt > LIMIT_SECONDS:
			errors.append("active-time budget exceeded")
			return false
		var direction := target - current
		p.yaw = atan2(-direction.x, -direction.y)
		p.yaw_target = p.yaw
		await physics_frame
		# Player has no _physics_process; the shipping main calls update. This is
		# the same controller and move_and_slide at the unmodified physics rate.
		p.update(dt)
		frames += 1
		var feet := p.feet()
		var moved := current.distance_to(Vector2(feet.x, feet.z))
		distance += moved
		min_x = minf(min_x, feet.x)
		min_z = minf(min_z, feet.z)
		max_step = maxf(max_step, feet.y - before.y)
		stalled = stalled + dt if moved < 0.001 else 0.0
		if feet.y < -0.5 or feet.y > 0.5:
			errors.append("invalid route height %s toward %s" % [feet,target])
			return false
		if stalled > 1.5:
			errors.append("blocked at %s toward %s collisions=%d" % [feet,target,p.get_slide_collision_count()])
			return false
		# Sample a 1.4m clear corridor across every forest leg, including gate.
		# Capsule radius .3 plus lateral .4 checks both edges, not only centre.
		if frames % 20 == 0 and (feet.z < -70.0 or feet.x < -46.0):
			var across := Vector3(-direction.y,0,direction.x).normalized() * 0.4
			for offset: Vector3 in [-across,across]:
				var at := feet + offset
				var hit := col.capsule_hit(at + Vector3(0,0.34,0), at + Vector3(0,1.45,0),0.3,CollisionWorld.ALL_SOLID)
				_check(hit.is_empty(), "forest corridor narrower than 1.4m at " + str(at))
	errors.append("waypoint timed out at %s toward %s" % [p.feet(),target])
	return false

func _check(ok: bool, message: String) -> void:
	if not ok and not errors.has(message): errors.append(message)

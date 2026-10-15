# Проверки режиссёра: одна очередь, действие перед выходом, поколение таймеров.
extends SceneTree

class Controls:
	extends RefCounted
	var position := Vector3.ZERO
	func feet() -> Vector3: return position

class Renderer:
	extends RefCounted
	var camera: Camera3D
	var world_root: Node3D

class Audio:
	extends RefCounted
	var played := 0
	func spatial_sfx(_id: String, _pos: Vector3, _gain: float, _distance: float) -> bool:
		played += 1
		return true
	func spatial_loop(_id: String, _pos: Vector3, _on: bool, _gain: float, _distance: float) -> bool: return true

var errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var state := GameState.new()
	state.chapter = "village"
	var ctrl := Controls.new()
	var renderer := Renderer.new()
	renderer.world_root = Node3D.new()
	root.add_child(renderer.world_root)
	renderer.camera = Camera3D.new()
	renderer.world_root.add_child(renderer.camera)
	var audio := Audio.new()
	var c := {"state": state, "controls": ctrl, "renderer": renderer, "audio": audio,
		"scaresOn": func() -> bool: return true}
	var director := HorrorDirector.new(c)
	c["horror"] = director
	director.update(0.0)
	var ids: Dictionary = {}
	for event: Dictionary in HorrorDirector.EVENTS:
		_check(not ids.has(event["id"]), "catalog duplicate " + event["id"])
		ids[event["id"]] = true
		_check(GameState.CHAPTERS.has(event["chapter"]), "catalog invalid chapter")
	_check(ids.size() >= 10, "fewer than ten event groups")
	_check(HorrorDirector.STRONG_COOLDOWN >= 75.0, "strong cooldown shorter than 75 sec")
	director.context("test-return", "horror-tin")
	director.update(6.0)
	_check(audio.played == 0, "event fired while player still reading/standing at action")
	ctrl.position.x = 5.0
	director.update(0.1, true)
	_check(audio.played == 0, "event fired under overlay/pause")
	director.update(0.1)
	_check(audio.played == 1 and state.horror_seen.has("test-return"), "exit did not play/mark once")
	director.update(2.0)
	director.context("test-return", "horror-tin")
	ctrl.position.x += 6.0
	director.update(80.0)
	_check(audio.played == 1, "seen event replayed")
	var snap := state.snapshot()
	state.horror_seen["later"] = true
	state.set_flag("dread-test-once").set_flag("omen-test-once").set_flag("story-test-later")
	state.restore(snap)
	_check(state.horror_seen.has("later"), "retry erased monotonic seen")
	_check(state.has("dread-test-once") and state.has("omen-test-once") and not state.has("story-test-later"), "legacy once/story restore contract changed")
	state.restore('{"chapter":"dark","flags":[],"inventory":[]}')
	_check(state.recovery.is_empty() and state.recovery_completed_count == 0, "old save defaults failed")
	state.reset()
	_check(state.horror_seen.is_empty(), "new game kept seen")
	var calls := [0]
	director.after(1.0, func() -> void: calls[0] += 1)
	director.update(2.0, true)
	_check(calls[0] == 0, "timer advanced while paused")
	director.invalidate()
	director.update(2.0)
	_check(calls[0] == 0, "old generation callback survived reset")
	state.chapter = "village"
	director.update(0.0)
	c["scaresOn"] = func() -> bool: return false
	director.context("off-return")
	ctrl.position.x += 5.0
	director.update(3.0)
	_check(audio.played == 1, "scares-off played optional abrupt event")
	var col := CollisionWorld.new()
	col.add_box(CollisionWorld.SET_STATIC, AABB(Vector3(-10,-0.25,-10), Vector3(20,0.25,20)))
	c["col"] = col
	_check(director.trajectory_clear(Vector3(-3,0,0), Vector3(3,0,0)), "clear ground path rejected")
	col.add_box(CollisionWorld.SET_OVERLAY, AABB(Vector3(-0.2,0,-1), Vector3(0.4,2.5,2)))
	_check(not director.trajectory_clear(Vector3(-3,0,0), Vector3(3,0,0)), "trajectory crossed overlay wall")
	for filename: String in ["main.gd", "chapters.gd", "interact.gd", "street_quest.gd", "valya_quest.gd", "village_quest.gd"]:
		var source := FileAccess.get_file_as_string("res://src/" + filename)
		_check(not source.contains('scare.play('), filename + " contains photo scare.play")
		_check(not source.contains('get("scare")'), filename + " contains photo context callback")
	director.invalidate()
	c.clear()
	renderer.world_root.free()
	if errors.is_empty():
		print("test_scares_budget: PASS (13 groups, once/reset, pause/generation, AllSolid, zero photo callbacks)")
		call_deferred("quit", 0)
	else:
		for error: String in errors: printerr(error)
		call_deferred("quit", 1)

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

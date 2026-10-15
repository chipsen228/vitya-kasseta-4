extends SceneTree

class UI extends RefCounted:
	var card_done: Callable
	var card_count := 0
	var task: Variant = null
	func showCards(_cards: Array, done: Callable, _seconds := 0.0) -> void:
		card_done = done
		card_count += 1
	func finish_cards() -> void:
		var done := card_done
		card_done = Callable()
		if done.is_valid(): done.call()
	func setTask(value: Variant) -> void: task = value
	func setChapterTag(_value: Variant) -> void: pass
	func say(_text: Variant, _seconds: float) -> void: pass
	func hideFail() -> void: pass

class Audio extends RefCounted:
	func rewind(_seconds: float) -> void: pass
	func start_outdoors() -> void: pass
	func sfx(_id: String) -> bool: return true
	func knock(_count: int, _gap: float) -> void: pass

class Lights extends RefCounted:
	var lamps := {"shop-win": false}
	var grid: Dictionary = {}
	func snapshot() -> Dictionary: return {"lamps": lamps.duplicate(), "grid": grid.duplicate()}
	func restore(value: Dictionary) -> void:
		lamps = value["lamps"].duplicate()
		grid = value["grid"].duplicate()
	func set_story_night(_value: float) -> void: pass
	func set_off_grid(id: String, on: bool) -> void: grid[id] = on
	func setLamp(id: String, on: bool) -> void: lamps[id] = on

class Flash extends RefCounted:
	func snapshot() -> Dictionary: return {}
	func restore(_value: Dictionary) -> void: pass

class Renderer extends RefCounted:
	var world_root: Node3D
	func set_tracking(_value: float) -> void: pass

class Controls extends RefCounted:
	var camera: Camera3D
	var enabled := true
	var pitch := 0.0
	var pitch_target := 0.0
	var at := Vector3.ZERO
	func place(x: float, y: float, z: float, _yaw: float) -> void: at = Vector3(x, y, z)
	func request_lock() -> void: pass

class PropsStub extends RefCounted:
	var car: Node3D
	var colliders: Array = [{"cx": 1.1, "cy": 0.7, "cz": -2.7,
		"hx": 0.9, "hy": 0.7, "hz": 2.1, "yaw": PI / 2.0}]
	func get_prop(id: String) -> Node3D: return car if id == "car" else null
	func rebuild_collision(col: CollisionWorld) -> void:
		col.clear_set(CollisionWorld.SET_PROPS)
		for shape: Dictionary in colliders:
			col.add_rot_box_d(CollisionWorld.SET_PROPS,
				shape["cx"], shape["cy"], shape["cz"], shape["hx"], shape["hy"], shape["hz"],
				CollisionWorld.AXIS_Y, shape["yaw"])

class ActorsStub extends RefCounted:
	var shown := false
	func place(_id: String, _x: float, _y: float, _z: float, _yaw: float) -> void: pass
	func face(_id: String, _x: float, _z: float) -> void: pass
	func show(_id: String, on: bool) -> void: shown = on

var errors: Array[String] = []
var dialogue_done: Callable


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := Node3D.new()
	root.add_child(scene)
	var renderer := Renderer.new()
	renderer.world_root = scene
	var controls := Controls.new()
	controls.camera = Camera3D.new()
	scene.add_child(controls.camera)
	var props := PropsStub.new()
	props.car = Node3D.new()
	props.car.position = Vector3(1.1, 0.0, -2.7)
	scene.add_child(props.car)
	var parked := props.car.transform
	var state := GameState.new()
	var ui := UI.new()
	var lights := Lights.new()
	var actors := ActorsStub.new()
	var col := CollisionWorld.new()
	var cut := Cutscene.new()
	var interact := Interact.new()
	var c := {"state": state, "ui": ui, "lights": lights, "audio": Audio.new(),
		"flashlight": Flash.new(), "renderer": renderer, "controls": controls,
		"props": props, "actors": actors, "col": col, "cutscene": cut,
		"interact": interact, "playDialogue": _dialogue, "world": {}}
	var chapters := Chapters.new(c)
	c["chapters"] = chapters
	chapters.start()
	_check(state.chapter == "prologue" and ui.card_count == 1, "new game begins with intro cards")
	ui.finish_cards()
	_check(cut.playing, "cards launch visible arrival at shop")
	cut.update(6.0)
	_check(state.chapter == "prologue", "arrival stays at shop, not house")
	_check(controls.at.x > 25.0 and controls.at.z < -5.0, "player stands at shop")
	_check(actors.shown and col.point_hit(29.8, 0.7, -3.2, CollisionWorld.MASK_PROPS), "neighbour and parked car present")
	_check(not col.point_hit(1.1, 0.7, -2.7, CollisionWorld.MASK_PROPS), "no invisible parked car left at the house")
	_check(_available(interact, state, "intro-shop-door"), "shop door is interactive")
	_check(not _available(interact, state, "intro-shop-leave"), "cannot skip conversation by leaving")
	_use(interact, c, "intro-shop-door")
	_check(state.has("intro-shop-checked"), "knock advances the shop task")
	_use(interact, c, "intro-shop-talk")
	var stale := dialogue_done
	chapters.retry()
	stale.call()
	_check(not state.has("intro-shop-talked"), "interrupted dialogue cannot complete after retry")
	_check(ui.card_count == 1 and not cut.playing, "retry does not replay cards or arrival")
	_check(state.has("intro-shop-checked"), "retry retains completed shop action")
	_use(interact, c, "intro-shop-talk")
	dialogue_done.call()
	_check(state.has("intro-shop-talked"), "conversation unlocks departure")
	chapters.retry()
	_check(state.has("intro-shop-talked") and _available(interact, state, "intro-shop-leave"), "retry retains conversation checkpoint")
	_use(interact, c, "intro-shop-leave")
	_check(state.chapter == "arrive", "departure enters original arrival chapter")
	ui.finish_cards()
	_check(controls.at.x < 2.0 and state.task == GameData.texts()["TASKS"]["chain"], "house arrival keeps original first task")
	_check(props.car.transform == parked and not actors.shown, "car and neighbour restored after intro")
	_check(col.point_hit(1.1, 0.7, -2.7, CollisionWorld.MASK_PROPS), "house car collision restored")
	_check(not col.point_hit(29.8, 0.7, -3.2, CollisionWorld.MASK_PROPS), "no invisible parked car left at shop")
	_check(not col.is_blocker_active("intro-shop-car") and not lights.lamps["shop-win"], "intro collider and lighting removed")
	_check(not state.has("shop-open") and not state.hasItem("shop-key"), "late shop quest remains locked")
	var at_house := controls.at
	state.give("key")
	chapters.pushTask(true)
	chapters.retry()
	_check(state.chapter == "arrive" and state.hasItem("key") and controls.at == at_house, "later retry keeps progress and does not return to shop")
	_check(not _available(interact, state, "intro-shop-door"), "intro interactions are disabled in later chapters")
	state.reset()
	chapters.start()
	ui.finish_cards()
	_check(cut.playing and not state.has("intro-shop-talked"), "new game replays intro with fresh progress")
	chapters.go("arrive", true)
	cut.update(6.0)
	_check(state.chapter == "arrive" and not state.has("intro-shop-arrived"), "cancelled arrival cannot hijack chapter")
	_check(props.car.transform == parked, "cancelled arrival restores car")
	if errors.is_empty(): print("test_intro_shop: PASS (new game, shop actions, retry, cancellation, later progress)")
	for error: String in errors: printerr(error)
	c.clear()
	interact.list.clear()
	chapters.ctx.clear()
	chapters = null
	scene.free()
	quit(0 if errors.is_empty() else 1)


func _dialogue(lines: Array, done: Callable) -> void:
	_check(lines.size() >= 4, "intro contains the first conversation")
	dialogue_done = done


func _available(interact: Interact, state: GameState, id: String) -> bool:
	for point: Dictionary in interact.list:
		if point["id"] == id: return point["when"].call(state)
	return false


func _use(interact: Interact, c: Dictionary, id: String) -> void:
	for point: Dictionary in interact.list:
		if point["id"] == id:
			point["onUse"].call(c)
			return
	_check(false, "missing interaction: " + id)


func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

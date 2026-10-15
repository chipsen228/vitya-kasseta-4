# Реальная геометрия бани, Interact.find/use и retry главы; часы ускорены dt.
extends SceneTree


class FakeUI:
	extends RefCounted
	var line := ""
	func say(text: String, _seconds := 0.0) -> void: line = text
	func toast(_text: String) -> void: pass
	func hideFail() -> void: pass
	func setTask(_task: Variant) -> void: pass
	func setChapterTag(_tag: Variant) -> void: pass


class FakeAudio:
	extends RefCounted
	func sfx(_id: String, _gain := 1.0) -> bool: return true
	func door(_open: bool) -> void: pass


class FakeRenderer:
	extends RefCounted
	var camera: Camera3D
	func set_tracking(_value: float) -> void: pass


class FakeSnapshot:
	extends RefCounted
	func snapshot() -> Dictionary: return {}
	func restore(_value: Variant) -> void: pass


class FakeControls:
	extends RefCounted
	var enabled := true
	var frozen := false
	var at := Vector3(5.0, 0.12, 22.0)
	func feet() -> Vector3: return at
	func place(x: float, y: float, z: float, _yaw := 0.0) -> void:
		at = Vector3(x, y, z)


var _done := false
var _errors: Array[String] = []


func _process(_delta: float) -> bool:
	if _done: return true
	_done = true
	_run()
	return true


func _run() -> void:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var b := WorldBuilder.new()
	b.mats = mats
	b.col = col
	b.site = GameData.site()
	var yard := {"nodes": {}, "boxes": []}
	YardWorld._banya(b, YardWorld.data()["BANYA"], yard)
	YardWorld._cellar_shed(b, YardWorld.data()["SHED"], yard)
	var world_root := Node3D.new()
	root.add_child(world_root)
	b._finish(world_root)
	var camera := Camera3D.new()
	root.add_child(camera)
	var state := GameState.new()
	state.chapter = "village"
	var ui := FakeUI.new()
	var renderer := FakeRenderer.new()
	renderer.camera = camera
	var ctx := {"state": state, "ui": ui, "audio": FakeAudio.new(),
		"renderer": renderer, "world": {"yard": yard}, "col": col,
		"controls": FakeControls.new(), "lights": FakeSnapshot.new(),
		"flashlight": FakeSnapshot.new(), "scaresOn": func() -> bool: return false}
	var director := HorrorDirector.new(ctx)
	ctx["horror"] = director
	var quest := OutskirtsQuest.new(ctx, {})
	ctx["outskirts"] = quest
	var chapters := Chapters.new(ctx)
	# Keep real go/retry while isolating this regression from unrelated story entry.
	chapters._defs["village"] = {"task": func(_s: GameState) -> String: return "Дождаться прогрева бани."}
	ctx["emit"] = func(event: String, payload: Variant = null) -> void: chapters.emit(event, payload)
	var interact := Interact.new()
	interact.ctx_ref = ctx
	interact.occluder = col
	Interact._runtime_ctx = ctx
	Interact._register_yard(interact, ctx)
	var texts := GameData.texts()
	quest._register_banya(interact, texts["PROMPTS"], texts["BEATS"], texts["LOOKS"])
	Interact._plot_banya(interact, texts["PROMPTS"], texts["BEATS"], texts["LOOKS"], {})
	chapters.go("village", true)
	var key: Node3D = yard["nodes"]["cellar-shed-key"]
	key.visible = true
	var key_pos := key.global_position
	var inspect := _definition(interact, "banya-key-inspect")
	var pickup := _definition(interact, "banya-key")
	var steam := _definition(interact, "banya-steam")
	_check(int(inspect.get("priority", 0)) == 3 and int(steam.get("priority", 0)) == 5
		and int(pickup.get("priority", 0)) == 6, "приоритеты осмотра/окна/подбора не равны 3/5/6")
	_check(inspect.get("target_node") == key and pickup.get("target_node") == key,
		"действия ключа не привязаны к узлу модели")

	# Early inspection must win over the facade and explain each missing step.
	_aim(camera, key_pos + Vector3(0.0, 0.14, 0.8), key_pos)
	_use_selected(interact, camera, ctx, "banya-key-inspect")
	_check(ui.line.contains("растоплю") and not state.hasItem("cellar-shed-key"), "ранний осмотр не объясняет растопку")
	state.set_flag("banya-fired")
	_use_selected(interact, camera, ctx, "banya-key-inspect")
	_check(ui.line.contains("заслонку"), "осмотр растопленной бани не объясняет заслонку")

	# Start through the real damper interaction, then exercise pause and retry.
	_aim(camera, Vector3(4.6, 1.68, 24.3), Vector3(3.52, 1.35, 24.30))
	_use_selected(interact, camera, ctx, "banya-damper")
	_check(state.has("damper-shut"), "заслонка не закрылась")
	quest.resume_pending_timers()
	quest.resume_pending_timers()
	_check(director._timers.size() == 1, "повторное восстановление размножило таймер нагрева")
	var stale_generation := quest._banya_timer_generation
	director.update(149.0, false)
	_check(not state.has("banya-hot"), "баня нагрелась раньше 150 секунд")
	director.update(900.0, true)
	_check(not state.has("banya-hot"), "баня нагрелась на паузе")
	_aim(camera, key_pos + Vector3(0.0, 0.14, 0.8), key_pos)
	_use_selected(interact, camera, ctx, "banya-key-inspect")
	_check(ui.line.contains("ещё греется"), "осмотр не объясняет ожидание прогрева")
	chapters.pushTask(true)
	chapters.retry()
	_check(director._timers.size() == 1, "retry потерял нагрев после go() или создал дубли")
	quest._complete_banya_heat(stale_generation, ctx, {})
	_check(not state.has("banya-hot"), "старый callback прогрел новую попытку")
	director.update(149.0, false)
	_check(not state.has("banya-hot"), "retry не оставил полный интервал 150 секунд")
	director.update(1.0, false)
	_check(state.has("banya-hot"), "после retry баня не прогрелась за 150 секунд")
	_check((yard["nodes"]["banya-win-w"] as Node3D).get_node("story-writing").visible,
		"нагрев не показал надпись на стекле")
	_use_selected(interact, camera, ctx, "banya-key-inspect")
	_check(ui.line.contains("Прочитаю"), "горячая баня не направляет к надписи")

	# Read the actual pane; only then may find() select pickup.
	_aim(camera, Vector3(3.8, 1.68, 22.3), steam["pos"])
	_use_selected(interact, camera, ctx, "banya-steam")
	_check(state.has("banya-written"), "реальное наведение на окно не дало прочитать надпись")
	var before_pickup := state.snapshot()
	_aim(camera, key_pos + Vector3(0.0, 0.14, 0.8), key_pos)
	_use_selected(interact, camera, ctx, "banya-key")
	_check(state.hasItem("cellar-shed-key") and not key.visible, "подбор не выдал предмет или не скрыл модель")
	_check(_selected_id(interact, camera, state) != "banya-key", "взятый ключ остался целью")

	# The old shed door ID and inventory contract must still work.
	_aim(camera, Vector3(-4.55, 1.68, 2.30), Vector3(-5.55, 1.05, 2.30))
	_use_selected(interact, camera, ctx, "cellar-shed-door")
	_check(state.has("cellar-shed-open") and not col.is_blocker_active("door-cellar-shed"),
		"ключ не открыл прежнюю дверь погреба")
	state.restore(before_pickup)
	Interact.resync_world(ctx)
	_check(key.visible and not state.hasItem("cellar-shed-key"), "откат не восстановил модель ключа")

	# A view from the street crosses the actual north wall of the bathhouse.
	_aim(camera, key_pos + Vector3(0.0, 0.14, -0.5), key_pos)
	_check(_selected_id(interact, camera, state) != "banya-key", "find разрешил подбор через стену бани")
	interact.target = pickup
	_check(not interact.use(ctx) and not state.hasItem("cellar-shed-key"), "use пропустил старую цель через закрытую стену")
	# Moving the model moves both action anchors, including the cached descriptor.
	key.position.x += 0.10
	_aim(camera, key.global_position + Vector3(0.0, 0.14, 0.8), key.global_position)
	_check(_selected_id(interact, camera, state) == "banya-key", "перенесённая модель потеряла действие")
	_check((pickup["pos"] as Vector3).distance_to(key.global_position) < 0.001, "якорь подбора отстал от модели")
	col.add_box_d(CollisionWorld.SET_BLOCKERS, 5.4, 1.0, 21.7, 6.1, 2.0, 21.8, "test-key-shutter")
	_check(_selected_id(interact, camera, state) != "banya-key", "закрытая створка не закрыла ключ на неподвижной камере")
	interact.target = pickup
	_check(not interact.use(ctx), "use не перепроверил закрывшуюся створку")
	col.set_blocker_active("test-key-shutter", false)
	_check(_selected_id(interact, camera, state) == "banya-key", "открытая створка оставила старый результат видимости")

	# A capture cancellation without a chapter change must also restore one timer.
	state.set_flag("banya-written", false)
	state.set_flag("banya-hot", false)
	quest.resync(state)
	director.invalidate("capture")
	quest.resume_pending_timers()
	quest.resume_pending_timers()
	_check(director._timers.size() == 1, "возврат после поимки потерял или размножил нагрев")
	var old_callback: Callable = director._timers[0]["cb"]
	state.reset()
	quest.resync(state)
	director.invalidate("reset")
	quest.resume_pending_timers()
	old_callback.call()
	_check(director._timers.is_empty() and not state.has("banya-hot"), "новая игра сохранила старый нагрев")
	Interact._runtime_ctx = {}
	ctx.erase("emit")
	ctx.erase("outskirts")
	ctx.erase("horror")
	world_root.free()
	camera.free()
	if _errors.is_empty():
		print("test_banya_key: PASS (aim/use, model anchor, wall, hints, window, 150s, pause, retry, pickup, shed, reset)")
		quit(0)
	else:
		for error: String in _errors: printerr("FAIL test_banya_key: ", error)
		quit(1)


func _definition(interact: Interact, id: String) -> Dictionary:
	for entry: Dictionary in interact.list:
		if String(entry.get("id", "")) == id: return entry
	_errors.append("нет дескриптора " + id)
	return {}


func _aim(camera: Camera3D, eye: Vector3, at: Vector3) -> void:
	camera.global_position = eye
	camera.look_at(at)


func _selected_id(interact: Interact, camera: Camera3D, state: GameState) -> String:
	var target: Variant = interact.find(camera, state)
	return "" if target == null else String(target.get("id", ""))


func _use_selected(interact: Interact, camera: Camera3D, ctx: Dictionary, id: String) -> void:
	var got := _selected_id(interact, camera, ctx["state"])
	_check(got == id, "наведение ожидало %s, выбрало %s" % [id, got])
	if got == id: _check(interact.use(ctx), "не выполнилось действие " + id)


func _check(ok: bool, message: String) -> void:
	if not ok: _errors.append(message)

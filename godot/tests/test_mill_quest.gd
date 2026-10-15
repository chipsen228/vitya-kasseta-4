extends SceneTree


class FakeControls:
	extends Node3D

	var enabled := true
	var frozen := false
	var yaw := 0.0
	var yaw_target := 0.0
	var pitch := 0.0
	var pitch_target := 0.0
	var camera := Camera3D.new()

	func _init() -> void:
		add_child(camera)

	func feet() -> Vector3:
		return global_position

	func place(x: float, y: float, z: float, new_yaw := 0.0) -> void:
		global_position = Vector3(x, y, z)
		yaw = new_yaw
		yaw_target = new_yaw


class FakeUI:
	extends RefCounted

	var reader_close: Callable = Callable()
	var title := ""
	var pages: Array = []

	func say(_line: String, _seconds: float) -> void:
		pass

	func setReaderTitle(value: String) -> void:
		title = value

	func openReader(_title: Variant, value: Variant, on_close: Variant = null) -> void:
		pages = value
		if on_close is Callable:
			reader_close = on_close

	func close_reader() -> void:
		if reader_close.is_valid():
			var done := reader_close
			reader_close = Callable()
			done.call()


class FakeAudio:
	extends RefCounted

	var steps := 0

	func steps_above(count := 4) -> void:
		steps += int(count)

	func creak(_volume := 1.0) -> void:
		pass

	func sfx(_id: String, _volume := 1.0) -> void:
		pass


class FakeCollision:
	extends RefCounted

	var blade_active := true

	func set_blocker_active(id: String, active: bool) -> void:
		if id == "mill-upper-blade":
			blade_active = active


class FakePhysics:
	extends RefCounted

	var syncs := 0

	func sync() -> void:
		syncs += 1


var _done := false


func _process(_dt: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true


func _run() -> void:
	var errors: Array[String] = []
	var state := GameState.new()
	state.chapter = "village"
	var controls := FakeControls.new()
	root.add_child(controls)
	controls.global_position = Vector3(19.28, 0.0, -26.12)
	controls.camera.global_position = controls.global_position + Vector3(0, 1.68, 0)
	var ui := FakeUI.new()
	var audio := FakeAudio.new()
	var col := FakeCollision.new()
	var physics := FakePhysics.new()
	var visual_nodes := {
		"mill-wheel": Node3D.new(),
		"mill-journal": Node3D.new(),
		"mill-coat": Node3D.new(),
	}
	for node: Node3D in visual_nodes.values():
		root.add_child(node)
	var ctx := {
		"state": state, "controls": controls, "ui": ui, "audio": audio,
		"col": col, "physics": physics,
	}
	var quest := OutskirtsQuest.new(ctx, {"nodes": visual_nodes})
	var interact := Interact.new()
	quest.register(interact)
	var base := _definition(interact, "mill-base")
	var lower := _definition(interact, "mill-ladder-lower")
	var wheel := _definition(interact, "mill-wheel")
	var upper := _definition(interact, "mill-ladder-upper")
	var journal := _definition(interact, "mill-journal")
	if base.is_empty() or lower.is_empty() or wheel.is_empty() \
			or upper.is_empty() or journal.is_empty():
		errors.append("не зарегистрированы все пять обязательных действий")
	else:
		var expected := {
			"mill-base": Vector3(19.28, 1.84, -26.36),
			"mill-ladder-lower": Vector3(19.28, 1.72, -26.36),
			"mill-wheel": Vector3(19.16, 5.66, -28.80),
			"mill-ladder-upper": Vector3(22.36, 6.04, -26.90),
			"mill-journal": Vector3(21.84, 8.68, -29.68),
		}
		for def: Dictionary in [base, lower, wheel, upper, journal]:
			var id := String(def["id"])
			if (def["pos"] as Vector3).distance_to(expected[id]) > 0.001:
				errors.append("%s не пересчитан от центра мельницы с коэффициентом 2" % id)
		if quest._mill_feet("lower", "ground").distance_to(
				Vector3(19.28, 4.10, -27.36)) > 0.001 \
				or quest._mill_feet("upper", "lower").distance_to(
				Vector3(22.36, 8.30, -27.46)) > 0.001:
			errors.append("высоты/выходы площадок мельницы не стали 4.10/8.30 м")
		if bool((base["when"] as Callable).call(state)):
			errors.append("мельница открыла сюжет до кассеты с чердака")
		state.set_flag("bathloft-found")
		if String(quest.mill_task(state)) != String(GameData.texts()["TASKS"]["millReach"]):
			errors.append("старый village-save без mill-clue не получил задачу мельницы")
		(base["onUse"] as Callable).call(ctx)
		if not state.has("mill-seen"):
			errors.append("осмотр не поставил mill-seen")
		(lower["onUse"] as Callable).call(ctx)
		_finish_transition(quest, ctx, "lower", "ground", PI)
		if quest._mill_level != "lower" or controls.frozen or not controls.enabled:
			errors.append("нижняя лестница не вернула обычное движение на площадке")
		if bool((upper["when"] as Callable).call(state)):
			errors.append("верхняя лестница доступна до тормоза")
		(wheel["onUse"] as Callable).call(ctx)
		if not state.has("mill-braked") or col.blade_active or physics.syncs < 1:
			errors.append("тормоз не снял именованный blocker верхней лестницы")
		(upper["onUse"] as Callable).call(ctx)
		_finish_transition(quest, ctx, "upper", "lower", 0.0)
		if quest._mill_level != "upper":
			errors.append("верхняя лестница не привела на площадку")
		(journal["onUse"] as Callable).call(ctx)
		if ui.pages.size() != 2 or not ui.reader_close.is_valid():
			errors.append("журнал не открыл две сюжетные страницы")
		if state.has("mill-clue"):
			errors.append("mill-clue поставлен не чтением журнала, а раньше")
		ui.close_reader()
		if not state.has("mill-clue") or not state.has("lake-told") or not state.evidence:
			errors.append("журнал не поставил mill-clue/lake-told/evidence")
		if (visual_nodes["mill-journal"] as Node3D).visible \
				or (visual_nodes["mill-coat"] as Node3D).visible:
			errors.append("журнал и человекообразный ватник не исчезли после чтения")

	# Retry at either platform never serialises the height and always restores
	# ordinary input on the ground runtime state.
	quest._mill_level = "upper"
	controls.enabled = false
	controls.frozen = true
	quest.resync(state)
	if quest._mill_level != "ground" or controls.frozen or not controls.enabled:
		errors.append("retry на площадке не сбросил runtime-высоту и управление")
	if col.blade_active:
		errors.append("resync сохранения с mill-braked снова включил лопасть-blocker")

	controls.queue_free()
	for node: Node3D in visual_nodes.values():
		node.queue_free()
	if errors.is_empty():
		print("test_mill_quest: PASS (gates, ladders, brake, journal, retry)")
		quit(0)
		return
	for error: String in errors:
		printerr("FAIL test_mill_quest: ", error)
	quit(1)


func _finish_transition(quest: OutskirtsQuest, ctx: Dictionary,
		target: String, from: String, yaw: float) -> void:
	if quest._mill_tween != null:
		quest._mill_tween.kill()
		quest._mill_tween = null
	var feet := quest._mill_feet(target, from)
	quest._finish_mill_transition(quest._mill_generation, ctx, target, feet, yaw)


func _definition(interact: Interact, id: String) -> Dictionary:
	for def: Dictionary in interact.list:
		if String(def.get("id", "")) == id:
			return def
	return {}

extends SceneTree


class FakeControls:
	extends Node3D

	var enabled := true
	var frozen := false
	var yaw := PI / 2.0
	var yaw_target := PI / 2.0
	var pitch := 0.0
	var pitch_target := 0.0
	var camera := Camera3D.new()

	func _init() -> void:
		add_child(camera)

	func setup() -> void:
		global_position = Vector3(8.05, 0.0, 23.90)
		camera.global_position = Vector3(8.05, 1.68, 23.90)

	func feet() -> Vector3:
		return global_position

	func place(x: float, y: float, z: float, new_yaw := 0.0) -> void:
		global_position = Vector3(x, y, z)
		yaw = new_yaw
		yaw_target = new_yaw


class FakeVoice:
	extends RefCounted

	var calls := 0
	var last_key := ""

	func say_vitya_key(key: String, _duration: float, _delay: float) -> void:
		calls += 1
		last_key = key


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
	controls.setup()
	var voice := FakeVoice.new()
	var ctx := {"state": state, "controls": controls, "voice": voice}
	var quest := OutskirtsQuest.new(ctx, {})
	var interact := Interact.new()
	quest.register(interact)
	var ladder := _definition(interact, "bathloft")
	var cassette := _definition(interact, "bathloft-cassette")
	if ladder.is_empty() or cassette.is_empty():
		errors.append("нет двух отдельных действий лестницы и кассеты")
	else:
		state.set_flag("banya-written")
		if bool((ladder["when"] as Callable).call(state)):
			errors.append("лестница доступна без зажжённой керосинки")
		state.set_flag("lantern-lit")
		if not bool((ladder["when"] as Callable).call(state)):
			errors.append("готовая лестница недоступна")
		(ladder["onUse"] as Callable).call(ctx)
		if state.has("bathloft-found"):
			errors.append("первое E у лестницы сразу выдало кассету")
		if quest._bathloft_phase != "ascending":
			errors.append("первое E не запустило подъём")
		# Retry during ascent restores the exact gameplay controller and a second
		# attempt can start from the same persisted prerequisites.
		quest.resync(state)
		if quest._bathloft_phase != "ground" or not controls.enabled or controls.frozen:
			errors.append("retry во время подъёма не вернул управление")
		(ladder["onUse"] as Callable).call(ctx)
		if quest._bathloft_tween != null:
			quest._bathloft_tween.kill()
			quest._bathloft_tween = null
		quest._finish_bathloft_ascent(quest._bathloft_generation, ctx)
		if not bool((cassette["when"] as Callable).call(state)):
			errors.append("наверху не появилось действие с кассетой")
		(cassette["onUse"] as Callable).call(ctx)
		if not state.has("bathloft-found") or not state.evidence:
			errors.append("второе E не выставило кассету и evidence")
		if voice.calls != 1 or voice.last_key != "phase14-3":
			errors.append("phase14-3 не прозвучал ровно один раз при снятии кассеты")
		(cassette["onUse"] as Callable).call(ctx)
		if quest._bathloft_phase != "inspecting":
			errors.append("повторное E изменило завершённую сцену")
		if voice.calls != 1:
			errors.append("повторное E проиграло phase14-3 ещё раз")

	# Retry must invalidate the outstanding voice/descent callbacks and restore
	# the ordinary camera/controller instead of serialising a halfway state.
	quest.resync(state)
	if quest._bathloft_phase != "ground" or not controls.enabled or controls.frozen:
		errors.append("resync не отменил сцену и не вернул управление")

	# A separate synthetic attempt reaches the descent phase, then retry must
	# cancel that tween as well. Resetting the persisted flag is test scaffolding,
	# not a save format or gameplay transition.
	state.set_flag("bathloft-found", false)
	(ladder["onUse"] as Callable).call(ctx)
	if quest._bathloft_tween != null:
		quest._bathloft_tween.kill()
		quest._bathloft_tween = null
	quest._finish_bathloft_ascent(quest._bathloft_generation, ctx)
	(cassette["onUse"] as Callable).call(ctx)
	quest._begin_bathloft_descent(quest._bathloft_generation, ctx)
	if quest._bathloft_phase != "descending":
		errors.append("осмотр кассеты не перешёл в видимый спуск")
	quest.resync(state)
	if quest._bathloft_phase != "ground" or not controls.enabled or controls.frozen:
		errors.append("retry во время спуска не вернул камеру и управление")

	# One four-triangle ArrayMesh has two correctly wound physical faces. Godot
	# uses clockwise front faces, so the geometric cross product points opposite
	# the supplied vertex normal. The
	# outside is not a second text object and its shared UV orientation mirrors
	# the writing naturally through the pane.
	var steam := YardWorld._steam_window_mesh(1.0, 0.40, 0.50)
	if steam.get_surface_count() != 1 or int(steam.surface_get_array_len(0)) != 8 \
			or int(steam.surface_get_array_index_len(0)) != 12:
		errors.append("паровое окно не является одним двухсторонним ArrayMesh")
	else:
		var arrays: Array = steam.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var front := _triangle_normal(vertices, indices, 0)
		var back := _triangle_normal(vertices, indices, 6)
		if front.x > -0.99 or back.x < 0.99:
			errors.append("у внутренней/наружной граней окна неверная намотка")
	if not bool(steam.get_meta("physical_mirror", false)):
		errors.append("окно не помечено как физически зеркальное")

	var yard_interact := Interact.new()
	Interact._register_yard(yard_interact, {})
	var key := _definition(yard_interact, "banya-key")
	if key.is_empty() or int(key.get("priority", 0)) != 6 \
			or (key.get("pos", Vector3.ZERO) as Vector3).distance_to(
				Vector3(5.67, 1.54, 21.38)) > 0.01:
		errors.append("ключ не получил отдельную точку у двери и priority 6")
	var plot_interact := Interact.new()
	Interact._plot_banya(plot_interact, {"take": "", "look": ""}, {}, {}, {})
	var old_window := _definition(plot_interact, "banya-window")
	state.set_flag("banya-fired")
	state.set_flag("banya-hot", false)
	if old_window.is_empty() or not bool((old_window["when"] as Callable).call(state)):
		errors.append("обычный осмотр окна недоступен до нагрева")
	state.set_flag("banya-hot")
	if bool((old_window["when"] as Callable).call(state)):
		errors.append("обычный осмотр окна перехватывает горячее сюжетное окно")

	controls.queue_free()
	if errors.is_empty():
		print("test_bathloft: PASS (two actions, lantern gate, retry cancellation)")
		quit(0)
		return
	for error: String in errors:
		printerr("FAIL test_bathloft: ", error)
	quit(1)


func _definition(interact: Interact, id: String) -> Dictionary:
	for def: Dictionary in interact.list:
		if String(def.get("id", "")) == id:
			return def
	return {}


func _triangle_normal(vertices: PackedVector3Array, indices: PackedInt32Array,
		offset: int) -> Vector3:
	var a := vertices[indices[offset]]
	var b := vertices[indices[offset + 1]]
	var c := vertices[indices[offset + 2]]
	return (b - a).cross(c - a).normalized()

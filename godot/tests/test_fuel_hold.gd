# Реальные target/find/use, физическая E и выбор канистры. Мир и GPU не нужны.
# Основной цикл проверяется через тот же main._street_runtime_free, который
# раньше запирал квест на 600 секунд сразу после StreetStalk.begin().
extends SceneTree

const Main = preload("res://src/main.gd")

class Feet extends RefCounted:
	# Обочина: бочка в радиусе E, игрок вне полосы обнаружения патруля.
	var at := Vector3(-13.0, 0.0, -0.89)
	func feet() -> Vector3: return at

class Messages extends RefCounted:
	var last := ""
	func say(message: String, _seconds: float) -> void: last = message

class Sounds extends RefCounted:
	var played: Array[String] = []
	func sfx(id: String) -> bool:
		played.append(id)
		return true
	func heartbeat(_count: int, _bpm: int) -> void: pass

class Figures extends RefCounted:
	var shown := false
	func place(_id: String, _x: float, _y: float, _z: float, _yaw: float) -> void: pass
	func show(_id: String, on: bool) -> void: shown = on
	func walk_anim(_id: String, _dt: float, _options: Dictionary) -> void: pass

var errors: Array[String] = []
var events: Array[String] = []
var state := GameState.new()
var interaction := Interact.new()
var held := HeldItems.new()
var camera := Camera3D.new()
var main := Main.new()
var quest: StreetQuest
var stalker: StreetStalk
var director: HorrorDirector
var feet := Feet.new()
var figures := Figures.new()
var sounds := Sounds.new()
var context: Dictionary = {}
var barrel := Vector3.ZERO


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	root.add_child(camera)
	root.add_child(held)
	state.chapter = "street"
	state.set_flag("street-old-man")
	context = {"state": state, "controls": feet, "ui": Messages.new(),
		"audio": sounds, "heldItems": held, "interact": interaction,
		"actors": figures, "texts": GameData.texts(),
		"holdEcho": main._ctx_hold_echo,
		"emit": func(id: String, _payload: Variant = null) -> void: events.append(id)}
	director = HorrorDirector.new(context)
	context["horror"] = director
	stalker = StreetStalk.new(context, 1)
	context["stalk"] = stalker
	main.state = state
	main.phone = Phone.new(null, root)
	main.ui = Overlays.new()
	main.tape_player = TapePlayer.new(null, null, root)
	main.horror = director
	main.haunt = Haunt.new(context, figures, null, 1)
	main.stalk = stalker
	main.running = true
	main.ctx = context
	var source := StreetWorld.data()
	var street_data := {"objects": source["OBJECTS"], "office": source["OFFICE"]}
	quest = StreetQuest.new(context, street_data, null, stalker)
	main.street = quest
	quest.register(interaction)
	interaction.ctx_ref = context
	var at: Array = street_data["objects"]["barrel"]
	barrel = Vector3(float(at[0]), float(at[1]) + 0.9, float(at[2]))
	_aim(barrel)
	_check(_target_is("fuel-barrel"), "бочка не выбирается настоящим find()")
	_press()
	_tick(3.2)
	_check(not state.has("fuel"), "топливо получено без второго разговора и канистры")
	_release()
	state.set_flag("arkady-2")
	_press()
	_tick(3.2)
	_check(not state.has("fuel"), "топливо получено без канистры")
	_release()
	state.give("flashlight")
	state.give("canister")
	held.sync(state)
	held.equip("flashlight")
	state.set_flag("street-old-man")
	stalker.begin()
	_check(director.owner == "stalk", "патруль не владеет своим hold")
	_check(director.exclusive(), "патруль не занял двойника")
	_check(main.haunt.global_cd >= 600.0, "патруль не зарезервировал двойника у Haunt")
	_check(not main._runtime_free(), "случайные появления могут украсть двойника патруля")
	_check(main._street_runtime_free(), "патруль заморозил собственные тики на 600 секунд")
	_check(String(interaction.promptFor(interaction.target, state)).contains("3 с"), "до нажатия нет инструкции удержания")
	_tick(1.5) # Первая точка патруля лежит у разворота с паузой 1.4 с.
	var initial := stalker.pos()
	_press()
	_check(held.selected_id() == "canister", "E у бочки не выбрала канистру из инвентаря")
	_tick(1.0)
	_check(stalker.pos().distance_to(initial) > 0.1, "при наполнении дед стоит замороженным")
	_check(not state.has("fuel"), "наполнение завершилось раньше трёх секунд")
	_check(String(interaction.promptFor(interaction.target, state)).contains("33 %"), "подсказка не показывает прогресс")
	_release()
	_tick(0.05)
	_check(not quest._pouring and is_zero_approx(quest._pour), "отпускание E оставило наливание")

	_press()
	_tick(1.0)
	main.paused = true
	_tick(5.0)
	_check(not state.has("fuel") and not quest._pouring, "пауза не отменила незавершённое наливание")
	_release()
	main.paused = false
	main.phone.open = true
	_check(not main._street_runtime_free(), "меню телефона пропустило наливание")
	main.phone.open = false
	main.ui.reader.open = true
	_check(not main._street_runtime_free(), "чтение записки пропустило наливание")
	main.ui.reader.open = false
	_press()
	_tick(1.0)
	camera.look_at(camera.global_position + Vector3.RIGHT, Vector3.UP)
	_tick(0.05)
	_check(not quest._pouring, "отведение прицела не отменило удержание")
	_release()
	_aim(barrel)
	_press()
	_tick(1.0)
	var checkpoint := state.snapshot()
	quest.cancel_runtime()
	state.restore(checkpoint)
	_check(not quest._pouring and not state.has("fuel"), "откат сохранил незавершённое действие")
	_release()
	_press()
	_tick(1.0)
	interaction.use(context)
	_tick(2.1)
	_check(state.has("fuel"), "три секунды E на бочке не наполнили канистру")
	_check(events.count("fuel") == 1, "завершение наливания отправлено не один раз")
	_check(sounds.played.has("canister-pour"), "нет звука наливания")
	_tick(4.0)
	_release()
	_check(events.count("fuel") == 1, "удержание после завершения повторно выдало топливо")

	# Защита владения: finish не гасит фигуру уже начавшейся поимки.
	director.owner = "capture"
	director.hold_left = 4.0
	figures.shown = true
	stalker.finish()
	_check(director.owner == "capture" and director.hold_left == 4.0 and figures.shown,
		"finish патруля прервал чужую сцену")
	director.owner = ""
	director.hold_left = 0.0
	stalker.begin()
	stalker.finish()
	_check(director.hold_left == 0.0 and director.owner == "", "finish не освободил 600-секундный hold")
	_check(main.haunt.global_cd <= HorrorDirector.STRONG_COOLDOWN, "finish оставил Haunt заблокированным на 600 секунд")
	_check(not figures.shown, "после finish осталась фигура патруля")
	stalker.begin()
	director.invalidate()
	stalker.finish()
	_check(not figures.shown, "откат с invalidate оставил фигуру патруля")

	Input.action_release("interact")
	director.invalidate()
	context.clear()
	interaction.list.clear()
	interaction.target = null
	quest._arkady_point.clear()
	main.ui.free()
	main.free()
	if errors.is_empty():
		print("test_fuel_hold: PASS — target, E, canister, release, pause, gaze, retry, stalk ownership")
	else:
		for error in errors: printerr("FAIL test_fuel_hold: ", error)
	quit(0 if errors.is_empty() else 1)


func _aim(at: Vector3) -> void:
	camera.global_position = feet.at + Vector3(0.0, 1.65, 0.0)
	camera.look_at(at, Vector3.UP)
	interaction.find(camera, state)


func _target_is(id: String) -> bool:
	return interaction.target is Dictionary and String(interaction.target.get("id", "")) == id


func _press() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_E
	event.pressed = true
	Input.parse_input_event(event)
	Input.flush_buffered_events()
	_check(Input.is_action_pressed("interact"), "физическая E не привязана к interact")
	if event.is_action_pressed("interact"):
		interaction.use(context)


func _release() -> void:
	var event := InputEventKey.new()
	event.physical_keycode = KEY_E
	event.pressed = false
	Input.parse_input_event(event)
	Input.flush_buffered_events()


func _tick(seconds: float) -> void:
	for _frame in int(ceil(seconds / 0.05)):
		interaction.find(camera, state)
		if main._street_runtime_free():
			quest.update(0.05)
			stalker.update(0.05)
		else:
			quest.cancel_runtime()


func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

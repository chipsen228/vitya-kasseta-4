# Runtime-слоты предметов: фильтрация по GameState, колесо, F, откат,
# блокирующие режимы, кассета и независимость обычного [E].
extends SceneTree

const BOOT_FRAMES := 700
const ITEMS := [
	["flashlight", "flashlight"], ["lantern", "lantern"], ["bag", "bag"],
	["firewood", "firewood"], ["apple-basket", "apple-basket"],
	["poison", "poison"], ["sprayer", "sprayer"], ["canister", "canister"],
	["leyka", "leyka"], ["scythe", "scythe"],
	["tool-shovel", "tool-shovel"], ["distributor", "distributor"],
	["crowbar", "crowbar"],
]


func _initialize() -> void:
	_run()


func _run() -> void:
	var scene: PackedScene = load("res://src/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	var waited := 0
	while (main.get("held_items") == null or main.get("chapters") == null) \
			and waited < BOOT_FRAMES:
		await process_frame
		waited += 1
	if main.get("held_items") == null:
		printerr("test_held_items: боут не завершился")
		quit(1)
		return

	main.call("_start_game")
	await _close_cards(main)
	var held: HeldItems = main.get("held_items")
	var state: GameState = main.get("state")
	var flashlight: Flashlight = main.get("flashlight")
	var chain: RenderChain = main.get("render_chain")
	var ui: Overlays = main.get("ui")
	var player: Player = main.get("player")
	var errs: Array[String] = []

	# Действия существуют в проекте, а runtime привязывает к ним настоящее колесо.
	for action in [&"equip_prev", &"equip_next"]:
		if not InputMap.has_action(action):
			errs.append("нет InputMap-действия %s" % action)
		elif not _has_wheel(action):
			errs.append("у %s нет события колеса" % action)

	# Каждый новый сюжетный предмет становится выбранным автоматически.
	state.reset()
	held.clear_runtime()
	held.sync(state)
	for pair: Array in ITEMS:
		state.give(String(pair[0]))
		if pair[0] == "flashlight":
			flashlight.give()
		held.sync(state)
		if held.selected_id() != pair[1]:
			errs.append("автоподбор %s выбрал %s" % [pair[0], held.selected_id()])

	# Каждая активная модель укладывается в договорный бюджет.
	for pair: Array in ITEMS:
		var id := String(pair[1])
		if not held.equip(id):
			errs.append("полный инвентарь не даёт экипировать %s" % id)
			continue
		var budget := held.active_budget()
		if not bool(budget["within_budget"]):
			errs.append("%s: бюджет %s" % [id, budget])

	# Прокрутка с горящего фонарика выбирает следующий слот и гасит только луч.
	held.equip("flashlight")
	flashlight.on = true
	var battery := flashlight.battery
	held.cycle(1)
	if held.selected_id() != "lantern":
		errs.append("cycle(1) после фонаря выбрал %s" % held.selected_id())
	if flashlight.on:
		errs.append("колесо не выключило луч фонарика")
	if not flashlight.owned or flashlight.battery != battery:
		errs.append("колесо изменило владение или батарею фонарика")
	held.cycle(-1)
	if held.selected_id() != "flashlight":
		errs.append("cycle(-1) не вернул фонарик")
	if not flashlight.model.visible:
		errs.append("выключенный выбранный фонарик не виден в HandView")
	if float(chain.get_vhs(&"hand_mix")) < 0.99:
		errs.append("видимые руки не включили hand_mix композитора")

	# Остановка HandView не очищает его последнюю текстуру. Кат-сцена обязана
	# отдельно погасить uniform, не меняя слот, луч, заряд или владение.
	flashlight.on = true
	var cinematic_selected := held.selected_id()
	var cinematic_battery := flashlight.battery
	var cinematic_owned := flashlight.owned
	held.set_cinematic_hidden(true)
	if float(chain.get_vhs(&"hand_mix")) > 0.01:
		errs.append("cinematic hidden оставил устаревшую текстуру HandView в композите")
	if held.selected_id() != cinematic_selected or not flashlight.on \
			or flashlight.battery != cinematic_battery or flashlight.owned != cinematic_owned:
		errs.append("скрытие рук изменило слот, луч, заряд или владение фонарём")
	held.set_cinematic_hidden(false)
	if float(chain.get_vhs(&"hand_mix")) < 0.99:
		errs.append("cleanup кат-сцены не восстановил hand_mix")
	if held.selected_id() != cinematic_selected or not flashlight.on \
			or flashlight.battery != cinematic_battery or flashlight.owned != cinematic_owned:
		errs.append("cleanup кат-сцены не восстановил состояние фонаря")

	# F принудительно выбирает фонарик и переключает свет.
	held.equip("bag")
	flashlight.on = false
	main.call("_unhandled_input", _action("flashlight"))
	if held.selected_id() != "flashlight" or not flashlight.on:
		errs.append("F не выбрал и не включил фонарик")

	# Выбор в снимок не попадает. Доступный прежний слот переживает restore,
	# недоступный откатывается сначала к фонарику, затем к первому предмету.
	held.equip("bag")
	var snap := state.snapshot()
	var parsed: Dictionary = JSON.parse_string(snap)
	for forbidden in ["held", "heldItem", "selected", "selectedSlot"]:
		if parsed.has(forbidden):
			errs.append("runtime-выбор записан в GameState.%s" % forbidden)
	state.restore(snap)
	held.sync(state)
	if held.selected_id() != "bag":
		errs.append("restore доступного слота не сохранил прежний выбор")
	state.set_flag("groceries")
	held.sync(state)
	if held.selected_id() != "flashlight":
		errs.append("исчезнувшая сумка не откатилась к фонарику")
	state.reset()
	state.give("bag")
	held.sync(state)
	held.equip("bag")
	state.reset()
	state.give("lantern")
	held.sync(state)
	if held.selected_id() != "lantern":
		errs.append("без фонарика fallback не выбрал первый доступный слот")

	# Условия расходования. Лейка и лопата остаются до ОБОИХ своих финалов.
	errs.append_array(_filter_case(held, state, "bag", ["groceries"]))
	errs.append_array(_filter_case(held, state, "firewood", ["banya-fired"]))
	errs.append_array(_filter_case(held, state, "apple-basket", ["apples-tossed"]))
	errs.append_array(_filter_case(held, state, "poison", ["spray-mixed"]))
	errs.append_array(_filter_case(held, state, "sprayer", ["bugs-done"]))
	errs.append_array(_filter_case(held, state, "canister", ["tank-full"]))
	errs.append_array(_filter_case(held, state, "scythe", ["mow-done"]))
	errs.append_array(_filter_case(held, state, "distributor", ["distributor-in"]))
	errs.append_array(_filter_case(held, state, "crowbar", ["well-freed"]))
	errs.append_array(_two_flag_case(held, state, "leyka", "water-done", "seedlings-done"))
	errs.append_array(_two_flag_case(held, state, "tool-shovel", "grave-dug", "bed-dug"))

	# Сюжетное применение показывает модель уже израсходованной канистры, но
	# не подменяет постоянный selected_id.
	state.reset()
	state.give("flashlight")
	held.clear_runtime()
	held.sync(state)
	held.equip("flashlight")
	held.show_story_event("tank-full")
	if held.selected_id() != "flashlight":
		errs.append("сюжетный показ изменил постоянный выбранный слот")
	var canister: Node3D = chain.hand_root.get_node_or_null("Held-canister")
	if canister == null or not canister.visible:
		errs.append("tank-full не показал канистру кратким viewmodel")

	# Кассета подавляет HandView и возвращает ровно прежнюю готовность.
	held.show_story_event("")
	held.equip("flashlight")
	var before_mode := chain.hand_view.render_target_update_mode
	chain.begin_tape_mode()
	if chain.hand_view.render_target_update_mode != SubViewport.UPDATE_DISABLED:
		errs.append("кассета не подавила HandView")
	chain.end_tape_mode()
	if chain.hand_view.render_target_update_mode != before_mode:
		errs.append("кассета не восстановила HandView")

	# Все перечисленные блокирующие режимы запрещают колесо. Проверяем общий
	# предикат, через который проходит каждое equip_prev/equip_next событие.
	main.set("paused", false)
	ui.scareOpen = false
	ui.card.open = false
	ui.reader.open = false
	ui.photo.open = false
	ui.hideFail()
	main.get("tape_player").set("open", false)
	main.get("phone").set("open", false)
	main.get("phone").set("_talking", false)
	player.enabled = true
	player.request_lock()
	if not bool(main.call("_held_items_input_enabled", true)):
		errs.append("чистый игровой режим ошибочно блокирует колесо")
	errs.append_array(_blocked_modes(main, ui, player))
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if bool(main.call("_held_items_input_enabled")):
		errs.append("освобождённая мышь не блокирует колесо")
	player.request_lock()

	# [E] по-прежнему идёт прямо в Interact и не меняет выбранный предмет.
	var used := [false]
	var interact: Interact = main.get("interact")
	interact.target = {"id": "held-e", "onUse": func(_ctx: Dictionary) -> void:
		used[0] = true}
	var selected_before := held.selected_id()
	main.call("_unhandled_input", _action("interact"))
	if not used[0]:
		errs.append("[E] перестал вызывать Interact.use")
	if held.selected_id() != selected_before:
		errs.append("[E] изменил выбранный предмет")

	# Полная сцена держит сотни RID; освобождаем её до quit(), чтобы тест не
	# маскировал настоящие ошибки длинным отчётом dummy-renderer об утечках.
	main.queue_free()
	await process_frame
	await process_frame
	if errs.is_empty():
		print("test_held_items: PASS")
		quit(0)
		return
	print("FAIL test_held_items: расхождений ", errs.size())
	for err: String in errs:
		print("  - ", err)
	quit(1)


func _filter_case(held: HeldItems, state: GameState, id: String,
		flags: Array) -> Array[String]:
	var out: Array[String] = []
	state.reset()
	state.give(id)
	held.clear_runtime()
	held.sync(state)
	if not held.equip(id):
		out.append("%s недоступен до расходования" % id)
	for flag: String in flags:
		state.set_flag(flag)
	held.sync(state)
	if held.equip(id):
		out.append("%s доступен после %s" % [id, flags])
	return out


func _two_flag_case(held: HeldItems, state: GameState, id: String,
		first: String, second: String) -> Array[String]:
	var out: Array[String] = []
	state.reset()
	state.give(id)
	held.clear_runtime()
	held.sync(state)
	state.set_flag(first)
	held.sync(state)
	if not held.equip(id):
		out.append("%s исчез уже после одного флага %s" % [id, first])
	state.set_flag(second)
	held.sync(state)
	if held.equip(id):
		out.append("%s доступен после обоих флагов" % id)
	return out


func _blocked_modes(main: Node, ui: Overlays, player: Player) -> Array[String]:
	var out: Array[String] = []
	var checks := [
		["pause", func(on: bool) -> void: main.set("paused", on)],
		["screamer", func(on: bool) -> void: ui.scareOpen = on],
		["card", func(on: bool) -> void: ui.card.open = on],
		["fail", func(on: bool) -> void:
			if on: ui.showFail("test")
			else: ui.hideFail()],
		["photo", func(on: bool) -> void: ui.photo.open = on],
		["reader", func(on: bool) -> void: ui.reader.open = on],
		["tape", func(on: bool) -> void: main.get("tape_player").set("open", on)],
		["phone", func(on: bool) -> void: main.get("phone").set("open", on)],
		["player-disabled", func(on: bool) -> void: player.enabled = not on],
	]
	for pair: Array in checks:
		(pair[1] as Callable).call(true)
		if bool(main.call("_held_items_input_enabled", true)):
			out.append("режим %s не блокирует колесо" % pair[0])
		(pair[1] as Callable).call(false)
	return out


func _has_wheel(action: StringName) -> bool:
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventMouseButton:
			var button := (event as InputEventMouseButton).button_index
			if button == MOUSE_BUTTON_WHEEL_UP or button == MOUSE_BUTTON_WHEEL_DOWN:
				return true
	return false


func _action(name: StringName) -> InputEventAction:
	var event := InputEventAction.new()
	event.action = name
	event.pressed = true
	return event


func _close_cards(main: Node) -> void:
	var ui: Overlays = main.get("ui")
	for _i in 80:
		if ui.card.open:
			ui.advanceCard()
		await process_frame

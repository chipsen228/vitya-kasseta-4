# Линия бабки Вали целиком (фаза 15, часть 2).
#
# Тот же способ, что в smoke_water.gd и smoke_village.gd: игра ведётся так,
# как её ведёт игрок — точка ищется по id, ставится целью и жмётся [E].
# Флагами выставляется только ПОДГОТОВКА (ключ от сельпо, полив), потому что
# за неё отвечают другие тесты.
#
# ПЯТЬ ВЕЩЕЙ, РАДИ КОТОРЫХ ОН И НАПИСАН.
#
# 1. ЛИНИЯ ПРОХОДИМА ЦЕЛИКОМ. Валя -> камни -> Валя -> коса -> три полосы ->
#    тропа -> холм -> Валя -> второй этаж -> пустая ограда. Десять звеньев,
#    семь мест; порвётся любое — и игрок останется с задачей, которую нельзя
#    выполнить, а по картинке это неотличимо от «я чего-то не нашёл».
# 2. ПОРЯДОК КАМНЕЙ ЗНАЧИТ ХОТЬ ЧТО-ТО. Круг, который складывается в любом
#    порядке, — не загадка, а пять нажатий. Здесь он собирается НЕПРАВИЛЬНО
#    нарочно, и проверяется, что он рассыпался целиком.
# 3. КАЖДЫЙ ЗАМОК ОТКАЗЫВАЕТ ВСЛУХ. Шкаф без ключа, покос без косы, холм
#    без лопаты — три места, где игра говорит «нет». Молчаливое «нет»
#    читается багом.
# 4. ЗАДАЧА ВЕДЁТ. Строка после каждого звена сверяется с TASKS: ступень,
#    которая не переводит задачу дальше, оставляет игрока с прежней
#    подсказкой на выполненном шаге.
# 5. ДО СЕЛЬПО ЛИНИЯ МОЛЧИТ. У главы одна основная линия за раз, и «поговорить
#    с женщиной» поверх «сходи в сельпо» — это две.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/smoke_valya.gd
extends SceneTree

const BOOT_FRAMES := 600


func _initialize() -> void:
	_run()


func _run() -> void:
	var scene: PackedScene = load("res://src/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)

	var waited := 0
	while main.get("chapters") == null and waited < BOOT_FRAMES:
		await process_frame
		waited += 1
	if main.get("chapters") == null:
		printerr("smoke_valya: боут не завершился")
		quit(1)
		return

	var built: Dictionary = main.get("built")
	if (built.get("valya", {}) as Dictionary).is_empty():
		print("SKIP smoke_valya: нет data/valya.json — линии в сборке нет")
		quit(0)
		return

	main.call("_start_game")
	await process_frame

	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var interact: Interact = main.get("interact")
	var ctx: Dictionary = main.get("ctx")
	var player: Player = main.get("player")
	var tasks: Dictionary = GameData.texts()["TASKS"]

	var errs: Array[String] = []

	state.give("flashlight")
	state.give("car-key")
	# Полный новый обход проверяет test_snt_quest; здесь готовим вход в линию Вали.
	state.set_flag("snt-returned")
	chapters.go("village")
	await _cards(main)
	if state.chapter != "village":
		errs.append("go('village') не встало: глава %s" % state.chapter)

	# L0: постоянная Валя видна и при занятой постановочным испугом сцене.
	var director: HorrorDirector = ctx["horror"]
	director.hold(1.0, "mandatory")
	errs.append_array(await _near_valya(main, player))
	var valya: Node3D = (ctx["actors"] as Actors).get_actor("valya")
	if valya == null or not valya.visible:
		errs.append("L0: Валя у ограды не видна игроку")
	if not state.has("valya-seen"):
		errs.append("L0: приближение к видимой Вале не отмечено")
	var talk: Variant = _find(interact, "valya-talk")
	if talk == null or (talk.has("when") and not bool((talk["when"] as Callable).call(state))):
		errs.append("L0: первый разговор с Валей у ограды недоступен")
	chapters.pushTask()
	if String(state.task) == String(tasks.get("valyaTalk", "")):
		errs.append("L0: Валя предложена до сельпо — две основные линии разом")

	director.update(1.0)

	# Основную линию главы проходим сразу: за неё отвечает smoke_village.
	errs.append_array(await _use(interact, ctx, "car-hood", state))
	errs.append_array(await _use(interact, ctx, "arkady-door", state))
	errs.append_array(await _use(interact, ctx, "shop-key", state))
	errs.append_array(await _use(interact, ctx, "shop-door", state))
	if not state.has("shop-open"):
		errs.append("подготовка: сельпо не открылось, задачи ниже не проверить")
	# ФАЗА 17. Ступень сельпо держится до бегунка, а не до открытой двери.
	errs.append_array(await _use(interact, ctx, "shop-crate", state))
	if not state.hasItem("distributor"):
		errs.append("подготовка: бегунок не взялся, задачи ниже не проверить")
	# Полив и улика стоят ВЫШЕ линии Вали в _village_task (chapters.gd), и это
	# правильно: у главы одна основная линия за раз. Обе закрываем флагами —
	# за них отвечают smoke_water.gd и smoke_village.gd.
	state.set_flag("water-done")
	state.set_flag("boarded-tapes")
	# ФАЗА 18. Баня и погреб тоже встали ВЫШЕ линии Вали и тоже стали
	# обязательными (решение Петра, Chapters.village_chores_done). За саму
	# петлю отвечает smoke_village.gd; здесь она такой же фон, как полив.
	state.set_flag("damper-shut")
	state.set_flag("banya-written")
	state.set_flag("bathloft-found")
	state.set_flag("mill-clue")
	state.set_flag("snt-returned")

	# ---- L1: первая встреча ----
	chapters.pushTask()
	if String(state.task) != String(tasks.get("valyaTalk", "")):
		errs.append("L1: сельпо открыто, а задача не про Валю: «%s»" % state.task)
	errs.append_array(await _talk(main, interact, ctx, state))
	if not state.has("valya-1"):
		errs.append("L1: первый разговор не закрылся")
	if not state.hasItem("valya-key"):
		errs.append("L1: ключ от шкафа не выдан")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("valyaStones", "")):
		errs.append("L1: задача после разговора не про камни: «%s»" % state.task)

	# ---- L2: камни. Сначала НЕВЕРНЫЙ порядок ----
	var order: Array = (ValyaWorld.data().get("STONES", {}) as Dictionary).get("order", [])
	if order.size() != 5:
		errs.append("L2: в данных не пять камней")
	else:
		# Первый верно, второй неверно — и круг обязан рассыпаться ЦЕЛИКОМ,
		# то есть первый камень вернуться к ограде и снова стать доступным.
		errs.append_array(await _use(interact, ctx, "valya-stone-%d" % int(order[0]), state))
		errs.append_array(await _use(interact, ctx, "valya-stone-%d" % int(order[2]), state))
		var again: Variant = _find(interact, "valya-stone-%d" % int(order[0]))
		if again == null or not bool(((again as Dictionary)["when"] as Callable).call(state)):
			errs.append("L2: уложенный камень не вернулся к ограде — круг не рассыпался")
		if state.has("stones-done"):
			errs.append("L2: круг сложился в неверном порядке")
		# А теперь правильный.
		for i in order:
			errs.append_array(await _use(interact, ctx, "valya-stone-%d" % int(i), state))
		if not state.has("stones-done"):
			errs.append("L2: круг не сложился и в верном порядке")

	# ---- L3: вторая встреча ----
	errs.append_array(await _talk(main, interact, ctx, state))
	if not state.has("valya-2"):
		errs.append("L3: второй разговор не закрылся")
	if not state.has("lake-told"):
		errs.append("L3: озеро не открылось после рассказа про внука")

	# ---- L4: шкаф и коса ----
	errs.append_array(await _use(interact, ctx, "shed-locker", state))
	if not state.has("locker-open"):
		errs.append("L4: шкаф не открылся ключом Вали")
	errs.append_array(await _use(interact, ctx, "shed-locker", state))
	if not state.hasItem("scythe"):
		errs.append("L4: коса не взялась")

	# ---- L5: три полосы ----
	for i in 3:
		errs.append_array(await _use(interact, ctx, "mow-%d" % i, state))
	if not state.has("mow-done"):
		errs.append("L5: три полосы скошены, а тропы нет")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("valyaGrave", "")):
		errs.append("L5: после покоса задача не про тропу: «%s»" % state.task)

	# ---- L6: холм. Отказ без лопаты — нарочно ----
	errs.append_array(await _use(interact, ctx, "grave-dig", state))
	if state.has("grave-dug"):
		errs.append("L6: холм раскопался без лопаты")
	errs.append_array(await _use(interact, ctx, "grave-shovel", state))
	if not state.hasItem("tool-shovel"):
		errs.append("L6: лопата не взялась")
	errs.append_array(await _use(interact, ctx, "grave-dig", state))
	if not state.has("grave-dug"):
		errs.append("L6: холм не раскопался и лопатой")

	# ---- L7: третья встреча и второй этаж ----
	errs.append_array(await _talk(main, interact, ctx, state))
	if not state.has("valya-3"):
		errs.append("L7: третий разговор не закрылся")
	errs.append_array(await _use(interact, ctx, "redhouse-desk-item", state))
	if not state.has("redhouse-notebook"):
		errs.append("L7: улика со второго этажа не взялась")

	# ---- L8: пустая ограда ----
	var gone: Variant = _find(interact, "valya-gone")
	if gone == null:
		errs.append("L8: нет точки «valya-gone»")
	else:
		errs.append_array(await _use(interact, ctx, "valya-gone", state))
		if not state.has("valya-gone"):
			errs.append("L8: возвращение к ограде ничего не дало")

	# ---- L10 (фаза 17): линия кончилась — строка задачи не пропала ----
	# Линия Вали стала обязательной, и она же последняя обязательная ступень
	# главы. Каскад после неё обязан выдать что-то живое: пустая строка задачи
	# на закрытой линии — это игрок, который стоит посреди деревни и не знает,
	# что игра от него хочет.
	chapters.pushTask()
	var after: String = String(state.task)
	if after == "" or after == "<null>":
		errs.append("L10: линия закрыта, а строка задачи пуста")
	elif after != String(tasks.get("backToCar", "")) \
			and after != String(tasks.get("boarded", "")):
		errs.append("L10: после линии Вали задача не про машину и не про "
			+ "улику: «%s»" % after)

	# ---- L9: озеро и пятая грядка ----
	errs.append_array(await _use(interact, ctx, "lake-net", state))
	if not state.has("net-pulled"):
		errs.append("L9: сеть не вытащилась")
	for i in 4:
		errs.append_array(await _use(interact, ctx, "garden-bed-%d" % i, state))
		if not state.has("garden-dug-%d" % i):
			errs.append("L9: секция %d не раскопалась" % i)
	if not state.has("bed-dug") or not state.has("garden-skeleton"):
		errs.append("L9: агрегат раскопок или скелет не выставлен")

	if errs.is_empty():
		print("smoke_valya: PASS")
		quit(0)
		return
	print("FAIL smoke_valya: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ---------- служебное ----------

## Подойти к ограде и постоять: флаг «увидел Валю» ставит neighbours по
## расстоянию, а не точка интеракта.
func _near_valya(main: Node, player: Player) -> Array[String]:
	var out: Array[String] = []
	for _i in 20:
		player.place(3.45, 0.0, -4.9, 0.0)
		await process_frame
	return out


## Заговорить и ДОСЛУШАТЬ. Реплики листаются skipLine(), а не таймером:
## три разговора по десять строк — это полторы минуты живого времени,
## и тест ждал бы их честно.
func _talk(main: Node, interact: Interact, ctx: Dictionary,
		state: GameState) -> Array[String]:
	var out: Array[String] = await _use(interact, ctx, "valya-talk", state)
	var phone: Phone = main.get("phone")
	for _i in 60:
		if not phone.talking:
			break
		phone.skipLine()
		await process_frame
	await process_frame
	return out


func _find(interact: Interact, id: String) -> Variant:
	for d: Dictionary in interact.list:
		if String(d["id"]) == id:
			return d
	return null


func _use(interact: Interact, ctx: Dictionary, id: String,
		state: GameState) -> Array[String]:
	var out: Array[String] = []
	var d: Variant = _find(interact, id)
	if d == null:
		out.append("нет точки «%s» в списке" % id)
		return out
	var def: Dictionary = d
	if def.has("when") and not bool((def["when"] as Callable).call(state)):
		out.append("точка «%s» закрыта условием when на своём шаге" % id)
		return out
	interact.target = def
	interact.use(ctx)
	await process_frame
	return out


func _cards(main: Node) -> void:
	var ui: Overlays = main.get("ui")
	for _i in 40:
		if not ui.card.open:
			await process_frame
			continue
		ui.advanceCard()
		await process_frame
	await process_frame

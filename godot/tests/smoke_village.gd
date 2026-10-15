# Сквозной прогон главы ДЕРЕВНЯ (фаза 12).
#
# Смысл тот же, что у smoke_street.gd: игра ведётся ровно тем способом, каким
# её ведёт игрок — точка ищется по id, ставится целью и жмётся [E]. Ни один шаг
# не выставляется флагом напрямую, иначе тест проверял бы сам себя.
#
# ТРИ ВЕЩИ, РАДИ КОТОРЫХ ОН И НАПИСАН.
#
# 1. ГЛАВА ЗАПЕРТА РОВНО ТЕМ, ЧТО ОБЪЯВЛЕНО, И НИЧЕМ БОЛЬШЕ.
#
#    ФАЗА 17, СМЕНА КОНТРАКТА. До неё этот блок доказывал ОБРАТНОЕ: «глава
#    обязана выпускать без добровольных шагов». Так и было — замков во второй
#    половине игры стояло два, флаг 'distributor-in' без единой проверки и цепь
#    на воротах, — и вся ночь схлопывалась в «сходил в сельпо, поставил бегунок,
#    уехал». Полив, линия Вали, улики, погост, колодец, красный дом и СНТ были
#    построены, озвучены, покрыты тестами и необязательны.
#
#    Теперь обязательны три вещи: вся цепочка полива, ОДНА улика (письмо или
#    кассеты) и вся линия Вали. Проверка при этом нужна СИЛЬНЕЕ прежнего, она
#    просто переехала на другую сторону: бегунок с незакрытыми линиями не
#    встаёт и отказывает ВСЛУХ, а с закрытыми — встаёт и выпускает в ВОРОТА.
#    Скрытая зависимость сверх этих трёх так же непроходима, как раньше.
#
# 2. ЗАМОК УЛИКИ ЗАКРЫВАЕТСЯ ЛЮБОЙ ПОЛОВИНОЙ И НЕ ЗАКРЫВАЕТСЯ САМ. Письмо у
#    Аркадия и кассеты в заколоченном доме — по одной, каждой достаточно.
#    Прогоняется дважды, обеими. Считается по ФЛАГУ 'boarded-tapes', а не по
#    предмету: тот же предмет выдаёт холм Вали на её обязательной линии, и по
#    предмету замок закрывался бы сам собой.
# 3. ЧЕТВЁРТАЯ КОНЦОВКА СЧИТАЕТСЯ ПО ЖИВЫМ ТОЧКАМ. «ПИСЬМО» требует ОБЕИХ
#    половин человеческой истории: письма в правление и кассет из заколоченного
#    дома. Проверяется это тем же способом — сходить и взять.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/smoke_village.gd
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
		printerr("smoke_village: боут не завершился")
		quit(1)
		return

	var built: Dictionary = main.get("built")
	if (built.get("village", {}) as Dictionary).is_empty():
		print("SKIP smoke_village: нет data/village.json — главы ДЕРЕВНЯ в сборке нет")
		quit(0)
		return

	main.call("_start_game")
	await process_frame

	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var interact: Interact = main.get("interact")
	var ctx: Dictionary = main.get("ctx")
	var ui: Overlays = main.get("ui")
	var col: CollisionWorld = main.get("col")
	var tasks: Dictionary = GameData.texts()["TASKS"]

	var errs: Array[String] = []

	# Игрок дошёл до деревни: всё, что было до неё, — предмет других тестов.
	state.give("flashlight")
	state.give("car-key")
	chapters.go("village")
	await _cards(main, ui)
	if state.chapter != "village":
		errs.append("go('village') не встало: глава %s" % state.chapter)

	# ---- V1: капот ----
	chapters.pushTask()
	if String(state.task) != String(tasks.get("hood", "")):
		errs.append("V1: задача не про капот: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "car-hood", state))
	if not state.has("distributor-gone"):
		errs.append("V1: пустой трамблёр не отыгран")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("askArkady", "")):
		errs.append("V1: бегунка нет, а задача не про Аркадия: «%s»" % state.task)

	# ---- V3 раньше времени: сельпо обязано быть заперто И СКАЗАТЬ ОБ ЭТОМ ----
	# Точка живая: запертая без слов дверь читается как баг, а не как задача.
	errs.append_array(await _use(interact, ctx, "shop-door", state))
	if state.has("shop-open"):
		errs.append("V3: сельпо открылось без ключа")
	if not col.is_blocker_active("door-shop"):
		errs.append("V3: створка сельпо погашена, хотя дверь заперта")

	# ---- V2: Аркадий ----
	errs.append_array(await _use(interact, ctx, "arkady-door", state))
	if not state.has("arkady-empty"):
		errs.append("V2: пустой дом Аркадия не отыгран")
	errs.append_array(await _use(interact, ctx, "shop-key", state))
	if not state.hasItem("shop-key"):
		errs.append("V2: ключ от сельпо не взялся")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("shop", "")):
		errs.append("V2: ключ на руках, а задача не про сельпо: «%s»" % state.task)

	# ---- V3: сельпо ----
	errs.append_array(await _use(interact, ctx, "shop-door", state))
	if not state.has("shop-open"):
		errs.append("V3: сельпо не открылось ключом")
	if col.is_blocker_active("door-shop"):
		errs.append("V3: дверь открыта, а створка в четвёртом наборе не погашена — "
			+ "войти нельзя")
	errs.append_array(await _use(interact, ctx, "shop-ledger", state))
	await _reader(ui)
	if not state.has("shop-ledger"):
		errs.append("V3: журнал прихода не прочитан")
	errs.append_array(await _use(interact, ctx, "shop-crate", state))
	if not state.hasItem("distributor"):
		errs.append("V3: бегунок не взялся")
	chapters.pushTask()
	# ФАЗА 17. Было «задача про машину». Ровно эта строка и прятала половину
	# главы: chapters._village_task вторым же условием возвращал backToCar,
	# как только бегунок оказывался в кармане, — выше полива и выше линии Вали.
	# При этом просьба деда про огород звучит ВСЛУХ на открытии сельпо, то есть
	# минуту назад. Теперь очередь идёт дальше: полив.
	# ФАЗА 18. Первой после сельпо идёт БАНЯ, а не полив, и это не подмена
	# порядка. Парилка греется 150 секунд, и единственное задание игры,
	# которое нельзя выполнить одним нажатием, положено на то, чем игрок
	# и так занят: заслонку прикрыл — пошёл поливать — вернулся, пар есть.
	if String(state.task) != String(tasks.get("farmKey", "")):
		errs.append("V3: бегунок на руках, а задача не про водокачку: «%s»" % state.task)

	# Телефон на стене: три реплики Сергея, дыхание и одна фраза с того конца.
	errs.append_array(await _use(interact, ctx, "shop-phone", state))
	await _dialogue(main)
	if not state.has("shop-called"):
		errs.append("V3: разговор по телефону сельпо не закрылся")

	# ---- V6: бегунок в руках, а деревня не отпускает ----
	# Ни полива, ни улики, ни линии Вали — глава обязана отказать И СКАЗАТЬ,
	# чего не хватает. Молчаливое «нет» у машины, к которой игрок принёс нужную
	# деталь, читается поломкой, а не задачей.
	if state.has("boarded-in") or state.has("grave-seen"):
		errs.append("тест сам зашёл в заколоченный дом раньше своей очереди")
	errs.append_array(await _use(interact, ctx, "car-hood", state))
	if state.has("distributor-in"):
		errs.append("V6: бегунок встал, хотя в деревне не сделано ничего — "
			+ "глава заперта одним замком, как до фазы 17")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("farmKey", "")):
		errs.append("V6: отказ не оставил строку задачи: «%s»" % state.task)

	# ---- V7: after four rows, banya and cellar are traversed on foot ----
	state.set_flag("water-done")
	#
	# Решение Петра: обе постройки обязательны до отъезда. Флагами такое не
	# проверяется — так проверяется только замок. Здесь петля идёт целиком,
	# точка за точкой, в том порядке, в котором её пройдёт игрок:
	# дрова -> каменка -> заслонка -> пар -> надпись -> ключ -> погреб ->
	# керосинка -> чердак бани. Ни одного нового объекта в ней нет: всё это
	# построено в фазах 11-15 и было необязательным настолько, что ни одна
	# строка задачи в баню не вела.
	errs.append_array(await _use(interact, ctx, "banya-fire", state))
	if state.has("banya-fired"):
		errs.append("V7: каменка затопилась БЕЗ дров")
	errs.append_array(await _use(interact, ctx, "woodpile", state))
	if not state.hasItem("firewood"):
		errs.append("V7: дрова из поленницы не взялись")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("banyaStoke", "")):
		errs.append("V7: дрова на руках, а задача не про каменку: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "banya-fire", state))
	if not state.has("banya-fired"):
		errs.append("V7: каменка не затопилась и с дровами")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("banyaDamper", "")):
		errs.append("V7: баня топится, а задача не про заслонку: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "banya-damper", state))
	if not state.has("damper-shut"):
		errs.append("V7: заслонка не прикрылась")
	# Вторая половина петли идёт ПОСЛЕ полива — так каскад и построен: пока
	# баня греется, игрок поливает. Полив здесь фон, за него отвечает
	# smoke_water.gd; закрываем флагом, иначе задача честно ведёт на ферму.
	# Пар идёт через BANYA_WARM = 150 секунд реального времени: ждать их
	# в тесте нечем и незачем, флаг ставит тот же таймер.
	chapters.pushTask()
	if String(state.task) != String(tasks.get("boarded", "")):
		errs.append("V7: пока баня греется HUD не предложил улику: «%s»" % state.task)
	state.set_flag("banya-hot")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("banyaSteam", "")):
		errs.append("V7: пар есть, а задача не про парилку: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "banya-steam", state))
	if not state.has("banya-written"):
		errs.append("V7: надпись на стекле не прочиталась")
	if not state.has("lake-told"):
		errs.append("V7: надпись «НЕ ХОДИ НА ОЗЕРО» не открыла линию озера — "
			+ "второй вход в неё и был смыслом этой ступени")
	# Ключ с гвоздя у двери бани. Он мог уже лежать в кармане с МАНСАРДЫ —
	# тогда ступень пропускается, и это правильно.
	if not state.hasItem("cellar-shed-key"):
		chapters.pushTask()
		if String(state.task) != String(tasks.get("banyaKey", "")):
			errs.append("V7: надпись прочитана, а задача не про ключ: «%s»" % state.task)
		errs.append_array(await _use(interact, ctx, "banya-key", state))
	if not state.hasItem("cellar-shed-key"):
		errs.append("V7: ключ с биркой «погреб» не взялся")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("cellarShed", "")):
		errs.append("V7: ключ на руках, а задача не про погреб: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "cellar-shed-door", state))
	if not state.has("cellar-shed-open"):
		errs.append("V7: погреб не открылся ключом из бани")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("cellarLantern", "")):
		errs.append("V7: погреб открыт, а задача не про керосинку: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "shed-lantern", state))
	if not state.hasItem("lantern"):
		errs.append("V7: керосинка из погреба не взялась")
	# Чердак бани в темноте: керосинку надо ЗАЖЕЧЬ. Единственное применение
	# предмета, который до фазы 18 не открывал ничего.
	var early_loft: Variant = _find(interact, "bathloft")
	if early_loft == null or bool((early_loft as Dictionary)["when"].call(state)):
		errs.append("V7: лестница предлагает действие до зажжённой керосинки")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("lanternLight", "")):
		errs.append("V7: керосинка на руках, а задача не зажечь её: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "lantern-light", state))
	if not state.has("lantern-lit"):
		errs.append("V7: керосинка не зажглась от каменки")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("bathloft", "")):
		errs.append("V7: лампа горит, а задача не про чердак бани: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "bathloft", state))
	if state.has("bathloft-found"):
		errs.append("V7: первое действие у лестницы сразу выдало кассету")
	await create_timer(2.65).timeout
	errs.append_array(await _use(interact, ctx, "bathloft-cassette", state))
	if not state.has("bathloft-found"):
		errs.append("V7: кассета с балки чердака бани не взялась и с лампой")
	# Автоспуска больше нет: кассета оставляет игрока наверху, а E у лаза
	# запускает видимый обратный переход.
	errs.append_array(await _use(interact, ctx, "bathloft-exit", state))
	await create_timer(2.35).timeout
	var player: Player = ctx.get("controls")
	if player == null or not player.enabled or player.frozen:
		errs.append("V7: спуск с чердака не вернул управление")

	# ---- V8: обязательная мельница по карандашному знаку кассеты ----
	chapters.pushTask()
	if String(state.task) != String(tasks.get("millReach", "")):
		errs.append("V8: после кассеты задача не ведёт к мельнице: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "mill-base", state))
	if not state.has("mill-seen"):
		errs.append("V8: мельница во время штиля не осмотрена")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("millLower", "")):
		errs.append("V8: после осмотра задача не про нижнюю площадку: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "mill-ladder-lower", state))
	await create_timer(1.75).timeout
	chapters.pushTask()
	if String(state.task) != String(tasks.get("millBrake", "")):
		errs.append("V8: на нижней площадке задача не про тормоз: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "mill-wheel", state))
	if not state.has("mill-braked") or col.is_blocker_active("mill-upper-blade"):
		errs.append("V8: колесо не остановило лопасти/не освободило верхнюю лестницу")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("millTop", "")):
		errs.append("V8: после тормоза задача не про верхнюю площадку: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "mill-ladder-upper", state))
	await create_timer(1.75).timeout
	chapters.pushTask()
	if String(state.task) != String(tasks.get("millJournal", "")):
		errs.append("V8: наверху задача не про журнал: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "mill-journal", state))
	await _reader(ui)
	if not state.has("mill-clue") or not state.has("lake-told") or not state.evidence:
		errs.append("V8: журнал не выставил mill-clue, lake-told и evidence")

	# ---- концовка без добровольных шагов ----
	var plain: Variant = chapters.call("_ending_of", state)
	if String(plain) == "kovrigin":
		errs.append("концовка «ПИСЬМО» выпала без письма и кассет")

	# ---- замок улики: кассеты, потом письмо ----
	# Полив и линию Вали закрываем флагами: за них отвечают smoke_water.gd
	# и smoke_valya.gd, а здесь они только фон под третье условие.
	errs.append_array(await _use(interact, ctx, "boarded-tapes", state))
	if not state.hasItem("kovrigin-tapes"):
		errs.append("кассеты из заколоченного дома не взялись")
	if not state.has("boarded-tapes"):
		errs.append("кассеты взяты, а флаг улики не встал — замок считает "
			+ "по флагу, потому что тот же предмет выдаёт холм Вали")
	state.set_flag("water-done")
	state.set_flag("valya-gone")
	# ФАЗА 18. Баня и погреб — две новые доли того же замка (решение Петра).
	# Здесь они фон, как полив и Валя; за саму петлю отвечает V7 ниже.
	state.set_flag("banya-written")
	state.set_flag("bathloft-found")
	state.set_flag("mill-clue")
	# Встречи, погоня и заключительный разговор покрыты test_snt_quest/test_snt_pursuit.
	# Для проверки прежних улик готовим их новый сюжетный prerequisite.
	state.set_flag("snt-returned")
	if not Chapters.village_chores_done(state):
		errs.append("V6: кассеты на руках, полив, Валя, баня и погреб "
			+ "закрыты — а замок главы всё равно не сложился")
	# Каждая из двух новых долей обязана держать замок в одиночку: иначе
	# «обязательны» значит «объявлены обязательными».
	for flag: String in ["banya-written", "bathloft-found", "mill-clue", "snt-returned"]:
		state.set_flag(flag, false)
		if Chapters.village_chores_done(state):
			errs.append("V6: замок сложился без «%s» — ступень не обязательна"
				% flag)
		state.set_flag(flag)
	# Второй прогон того же замка, другой половиной. Кассеты уже взяты —
	# снимаем флаг на один вопрос и возвращаем.
	state.set_flag("boarded-tapes", false)
	if Chapters.village_chores_done(state):
		errs.append("V6: замок улики закрыт без письма и без кассет — он пуст")
	errs.append_array(await _use(interact, ctx, "kovrigin-letter", state))
	await _reader(ui)
	if not state.has("kovrigin-letter"):
		errs.append("письмо в правление не прочиталось")
	if not Chapters.village_chores_done(state):
		errs.append("V6: письмо в правление не закрывает замок улики")
	state.set_flag("boarded-tapes")

	# ---- V6б: три линии закрыты — глава отпускает ----
	errs.append_array(await _use(interact, ctx, "car-hood", state))
	if not state.has("distributor-in"):
		errs.append("V6б: полив, улика и линия Вали закрыты, а бегунок не встал")
	_advance(chapters, 5.0)
	await _cards(main, ui)
	if state.chapter != "gate":
		errs.append("глава не перешла в ВОРОТА: %s" % state.chapter)

	# ---- четвёртая концовка: письмо И кассеты ----
	var full: Variant = chapters.call("_ending_of", state)
	if String(full) != "kovrigin":
		errs.append("письмо и кассеты на руках, а концовка «%s»" % String(full))
	var endings: Dictionary = GameData.texts()["ENDINGS"]
	if not endings.has("kovrigin"):
		errs.append("в текстах нет концовки «kovrigin»")

	# ---- ФАЗА 13: линия. Расписание -> монтировка -> ворот -> свёрток ----
	#
	# Проверяется ровно то, ради чего цепочку и делали короткой: единственная
	# связка «предмет отсюда нужен там» обязана быть проходимой и обязана
	# отказывать вслух. Ворот без монтировки — это не тупик, это реплика.
	errs.append_array(await _use(interact, ctx, "well-winch", state))
	if state.has("well-freed"):
		errs.append("ворот колодца провернулся без монтировки")
	errs.append_array(await _use(interact, ctx, "stop-half", state))
	if not state.has("schedule-half"):
		errs.append("вторая половина расписания не взялась из-под скамьи")
	errs.append_array(await _use(interact, ctx, "stop-schedule-fix", state))
	if not state.has("schedule-done"):
		errs.append("расписание не сложилось")
	errs.append_array(await _use(interact, ctx, "crowbar", state))
	if not state.hasItem("crowbar"):
		errs.append("монтировка из кабины трактора не взялась")
	errs.append_array(await _use(interact, ctx, "well-winch", state))
	if not state.has("well-freed"):
		errs.append("ворот не провернулся монтировкой")
	errs.append_array(await _use(interact, ctx, "well-winch", state))
	if not state.has("well-raised"):
		errs.append("ведро не поднялось после того, как ворот пошёл")
	errs.append_array(await _use(interact, ctx, "well-bundle", state))
	if not state.hasItem("well-bundle"):
		errs.append("свёрток из ведра не взялся")

	# ---- ФАЗА 13: красный дом ----
	errs.append_array(await _use(interact, ctx, "redhouse-door", state))
	if not state.has("redhouse-in"):
		errs.append("красный дом не отыгран")
	errs.append_array(await _use(interact, ctx, "redhouse-drawing", state))
	if not state.looked.has("redhouse-drawing"):
		errs.append("детский рисунок на стене не осмотрен")

	print("smoke_village: глава %s, улик %s, концовка %s"
		% [state.chapter, state.evidence, String(full)])
	if errs.is_empty():
		print("smoke_village: PASS")
		quit(0)
		return
	print("FAIL smoke_village: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ---------- служебное ----------

func _find(interact: Interact, id: String) -> Variant:
	for d: Dictionary in interact.list:
		if String(d["id"]) == id:
			return d
	return null


## Нажать [E] на точке. Возвращает список расхождений: не нашлась точка или
## её условие when не пустило — это и есть разорванное звено цепочки.
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
	if id == "banya-key":
		var at := Interact._bound_position(def)
		ctx["controls"].place(at.x, 0.12, at.z + 0.8, 0.0)
		var camera: Camera3D = ctx["renderer"].camera
		camera.global_position = at + Vector3(0.0, 0.14, 0.8)
		camera.look_at(at)
		var selected: Variant = interact.find(camera, state)
		if selected == null or String(selected.get("id", "")) != id:
			out.append("???? ?? ?????? ???????? ?????????? ??????? ????")
			return out
	interact.target = def
	if not interact.use(ctx): out.append("Interact.use ??????? ??? ?%s?" % id)
	await process_frame
	return out


func _cards(main: Node, ui: Overlays) -> void:
	for _i in 40:
		if not ui.card.open:
			await process_frame
			continue
		ui.advanceCard()
		await process_frame
	await process_frame


func _reader(ui: Overlays) -> void:
	if ui.reader.open:
		ui.closeReader()
	await process_frame


func _dialogue(main: Node) -> void:
	var phone: Phone = main.get("phone")
	var n := 0
	while phone.talking and n < 60:
		phone.skipLine()
		n += 1
		await process_frame
	await process_frame


func _advance(chapters: Chapters, seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		chapters.update(0.25)
		left -= 0.25

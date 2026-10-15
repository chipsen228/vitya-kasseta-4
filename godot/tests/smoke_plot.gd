# Сквозной прогон трёх заданий участка (фаза 13).
#
# Смысл тот же, что у smoke_street.gd и smoke_village.gd: игра ведётся ровно
# тем способом, каким её ведёт игрок — точка ищется по id, ставится целью
# и жмётся [E]. Ни один шаг не выставляется флагом напрямую, иначе тест
# проверял бы сам себя.
#
# ТРИ ВЕЩИ, РАДИ КОТОРЫХ ОН И НАПИСАН.
#
# 1. НИ ОДНО ИЗ ТРЁХ ЗАДАНИЙ НЕ ЗАПИРАЕТ ГЛАВУ. Баня, яблони и клопы —
#    добровольные целиком, и выход из глав держат прежние события. Скрытая
#    зависимость здесь означала бы главу, из которой нет выхода, а по картинке
#    это неотличимо от поломки.
# 2. ПОРЯДОК СТУПЕНЕЙ ЧИТАЕТСЯ ИЗ СТРОКИ ЗАДАЧИ. Опрыскиватель, яд, бочка,
#    грядки — и на каждом шаге задача обязана называть следующий, а не общий
#    «потравить клопов». Проверяется сравнением с TASKS.
# 3. МОКРЫЕ СЛЕДЫ ВКЛЮЧАЕТ ИГРОК. Это главная перемена фазы: следы от бани
#    к крыльцу появляются в ТЕМНОТЕ, только если баню истопил он сам. Тест
#    гоняет блэкаут дважды — с истопленной баней и с холодной, — и сверяет
#    видимость узла. Ошибка здесь тихая: следы либо появляются всегда (как
#    было до фазы 13, и тогда они не значат ничего), либо не появляются
#    никогда, и самая дорогая мелочь фазы 11 пропадает молча.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/smoke_plot.gd
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
		printerr("smoke_plot: боут не завершился")
		quit(1)
		return

	var built: Dictionary = main.get("built")
	var yard: Dictionary = built.get("yard", {})
	if yard.is_empty():
		print("SKIP smoke_plot: нет data/yard.json — заданий участка в сборке нет")
		quit(0)
		return

	main.call("_start_game")
	await process_frame

	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var interact: Interact = main.get("interact")
	var ctx: Dictionary = main.get("ctx")
	var ui: Overlays = main.get("ui")
	var tasks: Dictionary = GameData.texts()["TASKS"]
	var nodes: Dictionary = yard.get("nodes", {})

	var errs: Array[String] = []

	# ---------- СВЕТ: истопить баню ----------
	state.give("flashlight")
	chapters.go("light")
	await _cards(main, ui)
	# Ступени СВЕТА до бани — чужие, они предмет других тестов. Выставляем их
	# флагами, и это не подгонка: строка задачи ОБЯЗАНА показывать баню
	# последней, после всей обязательной рутины, и проверить это можно только
	# доведя лестницу до её конца.
	state.set_flag("breaker-on")
	state.set_flag("power-on")
	state.set_flag("note-read")
	state.set_flag("groceries")
	state.callsMade["hospital"] = true
	state.callsMade["neighbour"] = true
	state.set_flag("window-hall")
	state.set_flag("window-living")
	state.set_flag("window-aunt")
	state.set_flag("kettle-on")

	# Каменка без дров обязана сказать об этом, а не промолчать: замок,
	# который себя не объясняет, читается как баг.
	errs.append_array(await _use(interact, ctx, "banya-fire", state))
	if state.has("banya-fired"):
		errs.append("баня затопилась без дров")

	errs.append_array(await _use(interact, ctx, "woodpile", state))
	if not state.hasItem("firewood"):
		errs.append("дрова из поленницы не взялись")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("loft", "")):
		errs.append("добровольные дрова увели раннюю главу с мансарды: «%s»" % state.task)

	errs.append_array(await _use(interact, ctx, "banya-fire", state))
	if not state.has("banya-fired"):
		errs.append("каменка не затопилась дровами")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("loft", "")):
		errs.append("добровольная баня заменила раннюю задачу мансарды")

	# ---------- ПЛЁНКИ: обтрясти яблони ----------
	chapters.go("tapes")
	await _cards(main, ui)
	# Та же оговорка, что в СВЕТЕ: обязательные ступени ПЛЁНОК выставляем
	# флагами, чтобы лестница задачи дошла до сада.
	state.tapesWatched["3"] = true
	state.tapesWatched["5"] = true
	state.give("ladder")
	state.set_flag("roof-entered")
	state.set_flag("notebook-read")
	state.give("tape-x")
	errs.append_array(await _use(interact, ctx, "apple-tree-0", state))
	if not state.has("apple-picked-0"):
		errs.append("первая яблоня не обтряслась")
	var fruit: Variant = nodes.get("apples-0")
	if fruit is Node3D and (fruit as Node3D).visible:
		errs.append("яблоня обтрясена, а плоды на ней остались")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("orchard", "")):
		errs.append("первая яблоня обтрясена, а задача не про сад: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "apple-tree-1", state))
	errs.append_array(await _use(interact, ctx, "apple-tree-2", state))
	if not state.has("apples-done"):
		errs.append("три яблони обтрясены, а задание не закрылось")

	# ---------- ТЕМНОТА: мокрые следы и клопы ----------
	chapters.go("dark")
	await _cards(main, ui)
	# И здесь то же самое: щиток, тайник, ключи и вещи на верстаке — ступени
	# фаз 9 и 12, клопы стоят после них.
	state.set_flag("saw-boots")
	state.set_flag("stash-found")
	state.give("car-key")
	state.looked["shed-things"] = true
	chapters.call("_blackout", ctx, true)
	await process_frame
	var steps: Variant = nodes.get("wet-steps")
	if steps is Node3D and not (steps as Node3D).visible:
		errs.append("баня истоплена, а мокрых следов от неё нет")

	# Витя орёт с огорода. Событие, а не флаг: в игре его заводит таймер
	# блэкаута, и пройти оно обязано тем же путём.
	chapters.emit("bugs-shout")
	await process_frame
	if not state.has("bugs-heard"):
		errs.append("крик про клопов не отыгрался")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("bugsSprayer", "")):
		errs.append("клопы услышаны, а задача не про опрыскиватель: «%s»" % state.task)

	errs.append_array(await _use(interact, ctx, "sprayer", state))
	if not state.hasItem("sprayer"):
		errs.append("опрыскиватель из предбанника не взялся")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("bugsPoison", "")):
		errs.append("опрыскиватель на руках, а задача не про яд: «%s»" % state.task)

	# Бочка без яда обязана сказать об этом.
	errs.append_array(await _use(interact, ctx, "spray-barrel", state))
	if state.has("spray-mixed"):
		errs.append("раствор развёлся без яда")

	# Погреб открывают ключом из бани — это шаг фазы 11 и предмет другого теста.
	state.set_flag("cellar-shed-open")

	# ---------- ПОГРЕБ ОБЯЗАН ВЫПУСКАТЬ ----------
	#
	# ФАЗА 17, ТУПИК, НАЙДЕННЫЙ ЖИВЬЁМ. Керосинка на полке захлопывает за
	# игроком дверь — беззвучно и через 2.2 с, чтобы он стоял к ней спиной.
	# Первое нажатие на дверь: «заело», полнокадровый удар. Второе обязано
	# ОТКРЫТЬ — так обещает комментарий у shed_use с фазы 11.
	#
	# Кода на это не было ни строчки: ветка второго нажатия говорила описание
	# двери и выходила, а блокер 'door-cellar-shed' оставался активным. Игрок
	# запирался в погребе НАВСЕГДА — выхода нет, [R] работает только с экрана
	# провала, отладочный прыжок — только из командной строки.
	#
	# test_reachable.gd к этому слеп: он гасит все блокеры разом перед
	# заливкой. Проверка идёт по БЛОКЕРУ, а не по флагу: флаг снимается
	# и в сломанной версии тоже.
	var shed_col: CollisionWorld = main.get("col")
	state.set_flag("shed-door-seen")
	state.set_flag("shed-door-shut")
	shed_col.set_blocker_active("door-cellar-shed", true)
	errs.append_array(await _use(interact, ctx, "cellar-shed-door", state))
	if not shed_col.is_blocker_active("door-cellar-shed"):
		errs.append("погреб: дверь открылась с первого раза — сцены «заело» нет")
	errs.append_array(await _use(interact, ctx, "cellar-shed-door", state))
	if shed_col.is_blocker_active("door-cellar-shed"):
		errs.append("погреб: дверь не открылась и со второго раза — игрок, "
			+ "взявший керосинку, заперт там до конца прохождения")

	errs.append_array(await _use(interact, ctx, "poison", state))
	if not state.hasItem("poison"):
		errs.append("яд с полки погреба не взялся")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("bugsMix", "")):
		errs.append("яд на руках, а задача не про бочку: «%s»" % state.task)

	errs.append_array(await _use(interact, ctx, "spray-barrel", state))
	if not state.has("spray-mixed"):
		errs.append("раствор не развёлся при яде и опрыскивателе")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("bugsSpray", "")):
		errs.append("раствор готов, а задача не про грядки: «%s»" % state.task)

	for i in 3:
		errs.append_array(await _use(interact, ctx, "garden-row-%d" % i, state))
	if not state.has("bugs-done"):
		errs.append("три грядки опрысканы, а задание не закрылось")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("lead", "")):
		errs.append("клопы закрыты, а задача не вернулась к машине: «%s»" % state.task)

	# ---------- главное отрицание: холодная баня следов не даёт ----------
	# Второй прогон от чистого состояния. Игрок не топил — следов нет, и это
	# не забывчивость, а условие: следы значат «в бане мылись», а мыться
	# в холодной бане негде.
	var cold := GameState.new()
	cold.chapter = "dark"
	cold.set_flag("blackout")
	if steps is Node3D:
		(steps as Node3D).visible = false
	var saved: GameState = main.get("state")
	main.set("state", cold)
	ctx["state"] = cold
	chapters.ctx["state"] = cold
	chapters.call("_blackout", ctx, true)
	await process_frame
	if steps is Node3D and (steps as Node3D).visible:
		errs.append("баню не топили, а мокрые следы всё равно появились — "
			+ "перемена фазы 13 не работает")
	main.set("state", saved)
	ctx["state"] = saved
	chapters.ctx["state"] = saved

	print("smoke_plot: баня %s, яблонь %d, клопы %s"
		% [state.has("banya-fired"), Interact._apples_picked(state),
			state.has("bugs-done")])
	if errs.is_empty():
		print("smoke_plot: PASS")
		quit(0)
		return
	print("FAIL smoke_plot: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ---------- служебное ----------

func _find(interact: Interact, id: String) -> Variant:
	for d: Dictionary in interact.list:
		if String(d["id"]) == id:
			return d
	return null


## Нажать [E] на точке. Точка, закрытая своим `when`, — это разорванное звено
## цепочки, и молчать о нём нельзя. Исключение одно: шаги, которые тест
## нарочно пробует РАНЬШЕ времени (каменка без дров, бочка без яда), — там
## точка обязана быть открыта и обязана отказать репликой.
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


func _cards(main: Node, ui: Overlays) -> void:
	for _i in 40:
		if not ui.card.open:
			await process_frame
			continue
		ui.advanceCard()
		await process_frame
	await process_frame

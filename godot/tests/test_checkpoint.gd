# Контрольная точка стоит на КАЖДОЙ задаче (фаза 18).
#
# ЖАЛОБА ПЕТРА, ПУНКТ ТРЕТИЙ. «Поимка отбрасывает в начало главы». Так и было:
# чекпоинт снимался в трёх местах на всю игру — вход в главу (chapters.go),
# хлопок автомата в ТЕМНОТЕ и начало опасного отрезка УЛИЦЫ. В ДЕРЕВНЕ,
# выросшей до двух десятков ступеней, он был один — на входе, и любая смерть
# стирала полчаса.
#
# ТРИ УТВЕРЖДЕНИЯ, И ТРЕТЬЕ ВАЖНЕЕ ПЕРВЫХ ДВУХ.
#
#   1. Сменилась строка задачи — переснялся чекпоинт.
#   2. После retry() задача и инвентарь те же, что были на чекпоинте.
#   3. Предмет, взятый ДО чекпоинта, остаётся невидимым в мире, а предмет,
#      взятый ПОСЛЕ, — возвращается на своё место. Подбор гасит холдер
#      (interact.gd), а state.restore() откатывает только инвентарь: без
#      возврата видимости задачный чекпоинт делает хуже, чем было, — предмет
#      исчезает и из мира, и из рук.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_checkpoint.gd
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
		printerr("test_checkpoint: боут не завершился")
		quit(1)
		return

	main.call("_start_game")
	await process_frame

	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var interact: Interact = main.get("interact")
	var ctx: Dictionary = main.get("ctx")
	var props: Props = main.get("props")

	var errs: Array[String] = []

	# МАНСАРДА: четыре кассеты на полке — единственное место игры, где предметы
	# берутся подряд и у каждого свой холдер. Ровно то, что нужно проверить.
	state.give("flashlight")
	chapters.go("loft")
	await _cards(main)
	if state.chapter != "loft":
		errs.append("go('loft') не встало: глава %s" % state.chapter)

	# ---- 1. смена строки задачи переснимает чекпоинт ----
	var cp0: Variant = state.checkpoint
	var task0: Variant = state.task
	state.set_flag("diary-read")
	chapters.pushTask()
	if String(state.task) == String(task0):
		errs.append("подготовка: задача не сменилась, проверять нечего")
	elif String(state.checkpoint) == String(cp0):
		errs.append("1: строка задачи сменилась, а чекпоинт остался прежним")

	# ---- 2. предмет ДО чекпоинта ----
	errs.append_array(await _use(interact, ctx, "tape-1", state))
	if not state.hasItem("tape-1"):
		errs.append("подготовка: первая кассета не взялась")
	# Ещё одна ступень — и чекпоинт встаёт УЖЕ С КАССЕТОЙ на руках.
	state.give("mobile")
	chapters.pushTask()
	var task_cp: Variant = state.task
	var cp: Variant = state.checkpoint

	# ---- 3. предмет ПОСЛЕ чекпоинта ----
	errs.append_array(await _use(interact, ctx, "tape-2", state))
	if not state.hasItem("tape-2"):
		errs.append("подготовка: вторая кассета не взялась")
	if _visible(props, "tape-2"):
		errs.append("подготовка: взятая кассета осталась видна на полке")

	# ---- откат ----
	chapters.retry()
	await _cards(main)

	if String(state.checkpoint) != String(cp):
		errs.append("2: после retry() чекпоинт съехал")
	if String(state.task) != String(task_cp):
		errs.append("2: после retry() задача другая: «%s» вместо «%s»"
			% [state.task, task_cp])
	if not state.hasItem("tape-1"):
		errs.append("2: кассета, взятая ДО чекпоинта, пропала из инвентаря")
	if state.hasItem("tape-2"):
		errs.append("2: кассета, взятая ПОСЛЕ чекпоинта, осталась в инвентаре")
	if _visible(props, "tape-1"):
		errs.append("3: кассета, взятая ДО чекпоинта, снова лежит на полке — "
			+ "она и в руках, и в мире")
	if not _visible(props, "tape-2"):
		errs.append("3: кассета, взятая ПОСЛЕ чекпоинта, не вернулась на полку "
			+ "— она исчезла и из мира, и из рук")

	if errs.is_empty():
		print("test_checkpoint: PASS")
		quit(0)
		return
	print("FAIL test_checkpoint: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


func _visible(props: Props, id: String) -> bool:
	var n: Node3D = props.get_prop(id)
	return n != null and n.visible


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

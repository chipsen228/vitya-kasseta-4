# Сквозной прогон главы УЛИЦА (фаза 9).
#
# Смысл тот же, что у smoke_boot.gd: поймать рантайм-ошибки склейки, которых
# не видит check_compile, — ctx-Callable, Variant-методы, порядок событий.
# Только здесь проверяется ещё и СЦЕПКА ШАГОВ: глава кончается не по таймеру,
# а по цепочке из десяти действий, и разорванное звено выглядит в игре как
# «задача есть, а сделать её нечем».
#
# Игра ведётся ровно тем же способом, каким её ведёт игрок: находим дескриптор
# по id, ставим его целью и жмём [E]. Ни один шаг не выставляется флагом
# напрямую — иначе тест проверял бы сам себя.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/smoke_street.gd
extends SceneTree

const BOOT_FRAMES := 600
const DIALOGUE_LINES := 60      # сколько строк максимум пролистываем


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
		printerr("smoke_street: боут не завершился")
		quit(1)
		return

	var street_data: Dictionary = (main.get("built") as Dictionary).get("street", {})
	if street_data.is_empty():
		print("SKIP smoke_street: нет data/street.json — главы УЛИЦА в сборке нет")
		quit(0)
		return

	main.call("_start_game")
	await process_frame

	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var interact: Interact = main.get("interact")
	var nb: Neighbours = main.get("neighbours")
	var quest: StreetQuest = main.get("street")
	var ctx: Dictionary = main.get("ctx")
	var ui: Overlays = main.get("ui")

	var errs: Array[String] = []

	# Игрок дошёл до улицы: кассеты и дневник — не предмет этого теста,
	# их сцепку сторожит своя ветка в chapters.gd.
	state.give("flashlight")
	chapters.go("street")
	await _cards(main, ui)
	if state.chapter != "street":
		errs.append("go('street') не встало: глава %s" % state.chapter)

	if not nb.arkady_here():
		errs.append("Аркадий не вышел на улицу")

	# Точка «заговорить» обязана ехать за ним, а не стоять там, где её создали.
	# Она и стояла: Interact.add() мержит дескриптор в СВОЙ словарь, quest двигал
	# мёртвую копию, и первый разговор открывался единственный раз за главу —
	# когда Аркадий на своём кругу проходил мимо собственной калитки.
	var talk_was: Vector3 = (_find(interact, "arkady-talk") as Dictionary)["pos"]
	for _i in 200:
		nb.update(0.1)
		quest.update(0.1)
	var talk_now: Vector3 = (_find(interact, "arkady-talk") as Dictionary)["pos"]
	var walked := nb.arkady_pos()
	if talk_was.distance_to(talk_now) < 1.0:
		errs.append("точка «заговорить» осталась на месте, пока сосед шёл")
	if Vector2(talk_now.x, talk_now.z).distance_to(Vector2(walked.x, walked.z)) > 0.2:
		errs.append("точка «заговорить» разошлась с Аркадием: %.1f м"
			% Vector2(talk_now.x, talk_now.z).distance_to(Vector2(walked.x, walked.z)))

	# ----- S1: стук и корзина -----
	chapters.emit("knock")
	await process_frame
	if not state.has("apples-there"):
		errs.append("S1: после стука корзина не появилась")

	# ----- S2: корзину взять и выбросить -----
	errs.append_array(await _use(main, interact, ctx, "apple-note", state))
	await _reader(main, ui)
	errs.append_array(await _use(main, interact, ctx, "apple-basket", state))
	if not state.hasItem("apple-basket"):
		errs.append("S2: корзина не взялась")

	# ----- S2а: кухня (фаза 12) -----
	# Между «взял» и «выбросил» встали два шага, и они уводят игрока с крыльца
	# на кухню и обратно к воротам: дом он проходит ещё раз ровно в ту минуту,
	# когда дом уже перестал быть безопасным.
	#
	# Сначала — ведро ДО кухни. Точка обязана остаться живой и отказать вслух:
	# молча не сработавшее ведро неотличимо от поломки.
	errs.append_array(await _use(main, interact, ctx, "apple-bin", state))
	if state.has("apples-tossed"):
		errs.append("S2a: корзина выброшена, минуя тёрку — вся цепочка мимо")

	errs.append_array(await _use(main, interact, ctx, "kitchen-grater", state))
	if not state.has("apples-grated"):
		errs.append("S2a: яблоки не натёрлись")
	chapters.pushTask()
	var tasks_kitchen: Dictionary = GameData.texts()["TASKS"]
	if String(state.task) != String(tasks_kitchen.get("taste", "")):
		errs.append("S2a: натёрли, а задача не про пробу: «%s»" % state.task)
	errs.append_array(await _use(main, interact, ctx, "kitchen-bowl", state))
	if not state.has("apples-tasted"):
		errs.append("S2a: попробовать не вышло")

	errs.append_array(await _use(main, interact, ctx, "apple-bin", state))
	if not state.has("apples-tossed"):
		errs.append("S2: корзина не выброшена")

	# Скример через четыре секунды — прокручиваем таймеры главы.
	_advance(chapters, 5.0)
	await process_frame

	# ----- S3: машина не заводится -----
	errs.append_array(await _use(main, interact, ctx, "car-drive", state))
	if not state.has("car-dead"):
		errs.append("S3: пустой бак не отыгран")

	# ----- S5: первый разговор -----
	errs.append_array(await _use(main, interact, ctx, "arkady-talk", state))
	await _dialogue(main)
	if not state.has("arkady-1"):
		errs.append("S5: первый разговор не закрылся")

	# ----- S6: ключ от правления -----
	errs.append_array(await _use(main, interact, ctx, "office-key", state))
	if not state.hasItem("office-key"):
		errs.append("S6: ключ от правления не взялся")

	# ----- S8: правление, канистра, журнал -----
	errs.append_array(await _use(main, interact, ctx, "office-door", state))
	if not state.has("office-open"):
		errs.append("S8: правление не открылось")

	# Задача и точка обязаны сходиться. Расходились они ровно здесь: правление
	# открыто -> задача звала к Аркадию, а «заговорить» ждало канистру. Игрок
	# доходил до соседа, жал [E], и не происходило ничего — глава вставала.
	chapters.pushTask()
	var tasks: Dictionary = GameData.texts()["TASKS"]
	var talk: Variant = _find(interact, "arkady-talk")
	var talk_open := talk != null \
		and bool(((talk as Dictionary)["when"] as Callable).call(state))
	if talk_open:
		errs.append("S8: второй разговор открылся без канистры")
	if String(state.task) != String(tasks.get("canister", "")):
		errs.append("S8: канистры нет, а задача не про неё: «%s»" % state.task)

	errs.append_array(await _use(main, interact, ctx, "canister-empty", state))
	if not state.hasItem("canister"):
		errs.append("S8: канистра не взялась")
	errs.append_array(await _use(main, interact, ctx, "duty-log", state))
	await _reader(main, ui)
	if not state.has("duty-log"):
		errs.append("S8: журнал дежурств не прочитан")
	if not state.evidence:
		errs.append("S8: журнал не поднял улику")

	# ----- S9: второй разговор -----
	errs.append_array(await _use(main, interact, ctx, "arkady-talk", state))
	await _dialogue(main)
	if not state.has("arkady-2"):
		errs.append("S9: второй разговор не закрылся")

	# ----- S10: бочка, удержание [E] -----
	errs.append_array(await _fuel_hold(main, interact, state))
	if not state.has("fuel"):
		errs.append("S10: удержание [E] у бочки не налило топлива")

	errs.append_array(await _use(main, interact, ctx, "car-fill", state))
	if not state.has("tank-full"):
		errs.append("S10: бак не залит")

	# ----- переход в ТЕМНОТУ -----
	errs.append_array(await _use(main, interact, ctx, "car-drive", state))
	if not state.has("street-done"):
		errs.append("S10: пустое зажигание не отыграно")
	_advance(chapters, 5.0)
	await _cards(main, ui)
	if state.chapter != "dark":
		errs.append("глава не перешла в ТЕМНОТУ: %s" % state.chapter)
	if not state.has("second-lap"):
		errs.append("второй виток не сработал на входе в ТЕМНОТУ")

	# Ключи от машины — новая точка в подполе.
	errs.append_array(await _use(main, interact, ctx, "car-keys", state))
	if not state.hasItem("car-key"):
		errs.append("ключи от машины не взялись")

	print("smoke_street: шагов пройдено, глава %s, улик %s"
		% [state.chapter, state.evidence])
	if errs.is_empty():
		print("smoke_street: PASS")
		quit(0)
		return
	print("FAIL smoke_street: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ---------- служебное ----------

## Настоящий игровой цикл: позиция игрока, выбор цели и физическая клавиша.
## Прямой quest.update обходил блокировку main._runtime_free после выхода деда.
func _fuel_hold(main: Node, interact: Interact, state: GameState) -> Array[String]:
	var out: Array[String] = []
	var barrel: Dictionary = _find(interact, "fuel-barrel")
	var at: Vector3 = barrel["pos"]
	var player: Player = main.get("player")
	var camera: Camera3D = main.get("render_chain").camera
	# Подойти по передней обочине пешком, слева от столба (-13,-0.9).
	# Включена обычная физика Player: телепорт в радиус E скрывал бы выталкивание.
	player.place(at.x - 3.0, at.y - 0.9, at.z + 1.90, -PI * 0.5)
	player.pitch = 0.0
	player.pitch_target = 0.0
	for _frame in 3: await physics_frame
	Input.action_press("move_forward")
	for _frame in 120:
		await physics_frame
		if player.feet().x >= at.x - 0.8: break
	Input.action_release("move_forward")
	for _frame in 12: await physics_frame
	if player.feet().x < at.x - 0.9:
		out.append("S10: физика не пустила к бочке спереди: %s" % player.feet())
		return out
	var delta := at - (player.feet() + Vector3(0.0, Player.STAND_HEIGHT - Player.EYE_DROP, 0.0))
	player.yaw = atan2(-delta.x, -delta.z)
	player.yaw_target = player.yaw
	player.pitch = atan2(delta.y, Vector2(delta.x, delta.z).length())
	player.pitch_target = player.pitch
	player.call("_apply_camera")
	var found: Variant = interact.find(camera, state)
	if not (found is Dictionary) or String(found.get("id", "")) != "fuel-barrel":
		out.append("S10: прицел у бочки выбрал %s; feet=%s eye=%s radius=%.2f distance=%.2f visible=%s" %
			[str(found), player.feet(), camera.global_position, barrel["r"],
			camera.global_position.distance_to(at), interact.visible(camera.global_position, at)])
		return out
	var quest: StreetQuest = main.get("street")
	var hold_at := player.feet()
	var key := InputEventKey.new()
	key.physical_keycode = KEY_E
	key.pressed = true
	Input.parse_input_event(key)
	Input.flush_buffered_events()
	if not quest._pouring:
		out.append("S10: физическое нажатие E не начало удержание")
	for _frame in 240:
		await physics_frame
		if state.has("fuel"): break
	key = InputEventKey.new()
	key.physical_keycode = KEY_E
	key.pressed = false
	Input.parse_input_event(key)
	Input.flush_buffered_events()
	if player.feet().distance_to(hold_at) > 0.12:
		out.append("S10: физика вытолкнула игрока во время удержания: %s → %s" % [hold_at, player.feet()])
	print("fuel real approach: feet=", player.feet(), " filled=", state.has("fuel"),
		" stalk=", main.get("stalk").active(), " owner=", main.get("horror").owner)
	return out


func _find(interact: Interact, id: String) -> Variant:
	for d: Dictionary in interact.list:
		if String(d["id"]) == id:
			return d
	return null


## Нажать [E] на точке. Возвращает список расхождений: не нашлась точка или
## её условие when не пустило — это и есть разорванное звено цепочки.
func _use(main: Node, interact: Interact, ctx: Dictionary, id: String,
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


## Пролистать карточку главы.
func _cards(main: Node, ui: Overlays) -> void:
	for _i in 40:
		if not ui.card.open:
			await process_frame
			continue
		ui.advanceCard()
		await process_frame
	await process_frame


## Закрыть ридер, если он открылся.
func _reader(main: Node, ui: Overlays) -> void:
	if ui.reader.open:
		ui.closeReader()
	await process_frame


## Пролистать диалог до конца тем же [E], каким его листает игрок.
func _dialogue(main: Node) -> void:
	var phone: Phone = main.get("phone")
	var n := 0
	while phone.talking and n < DIALOGUE_LINES:
		phone.skipLine()
		n += 1
		await process_frame
	await process_frame


## Прокрутить таймеры главы, не тратя реального времени.
func _advance(chapters: Chapters, seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		chapters.update(0.25)
		left -= 0.25

# Сквозной прогон цепочки полива (фаза 14).
#
# Тот же способ, что в smoke_village.gd: игра ведётся так, как её ведёт игрок —
# точка ищется по id, ставится целью и жмётся [E]. Ни один шаг не выставляется
# флагом напрямую, иначе тест проверял бы сам себя.
#
# ТРИ ВЕЩИ, РАДИ КОТОРЫХ ОН И НАПИСАН.
#
# 1. ЦЕПОЧКА ОБЯЗАНА БЫТЬ ПРОХОДИМОЙ ЦЕЛИКОМ. Пустая бочка -> сухой кран ->
#    ключ на ферме -> замок водокачки -> рубильник -> кран даёт воду -> лейка
#    -> четыре грядки. Восемь звеньев, семь мест, две локации; порвётся любое —
#    и игрок останется с задачей, которую нельзя выполнить, а по картинке это
#    неотличимо от «я чего-то не нашёл».
# 2. КАЖДЫЙ ОТКАЗ ОБЯЗАН БЫТЬ ВСЛУХ. Кран без насоса, замок без ключа, лейка
#    без воды — три места, где игра говорит «нет». Молчаливое «нет» читается
#    багом. Поэтому здесь каждый отказ ЖМЁТСЯ НАРОЧНО, до того как звено
#    выполнено, и проверяется, что флаг не встал.
# 3. ЗАДАЧА ОБЯЗАНА ВЕСТИ. Строка бегунка после каждого звена сверяется с
#    TASKS: ступень, которая не переводит задачу дальше, оставляет игрока
#    с прежней подсказкой на выполненном шаге.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/smoke_water.gd
extends SceneTree

const BOOT_FRAMES := 600

# Кольца и румбы подхода: те же, что в test_points_visible.gd. Ближе 0.55 м
# капсула вечно в самом предмете, дальше 2.5 м уже не дотянуться.
const AIM_RINGS := [0.55, 0.75, 1.00, 1.30, 1.70, 2.10, 2.50]
const AIM_ANGLES := 24
const AIM_FLOOR_PROBES := [0.55, 1.95, 0.15]

# Сборка, поднятая _run(): её спрашивает _aim_at. Искать её по последнему
# ребёнку корня нельзя — Interact._after добавляет туда свои таймеры.
var _main: Node = null


func _initialize() -> void:
	_run()


func _run() -> void:
	var scene: PackedScene = load("res://src/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)
	_main = main

	var waited := 0
	while main.get("chapters") == null and waited < BOOT_FRAMES:
		await process_frame
		waited += 1
	if main.get("chapters") == null:
		printerr("smoke_water: боут не завершился")
		quit(1)
		return

	var built: Dictionary = main.get("built")
	if (built.get("outskirts", {}) as Dictionary).is_empty():
		print("SKIP smoke_water: нет data/outskirts.json — околицы в сборке нет")
		quit(0)
		return

	main.call("_start_game")
	await process_frame

	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var interact: Interact = main.get("interact")
	var ctx: Dictionary = main.get("ctx")
	var col: CollisionWorld = main.get("col")
	var tasks: Dictionary = GameData.texts()["TASKS"]

	var errs: Array[String] = []

	# Всё, что было до деревни, — предмет других тестов.
	state.give("flashlight")
	state.give("car-key")
	chapters.go("village")
	await _cards(main)
	if state.chapter != "village":
		errs.append("go('village') не встало: глава %s" % state.chapter)

	# Основную линию главы проходим сразу: полив стоит НИЖЕ неё в
	# chapters._village_task, и до бегунка с ключом от сельпо строка задачи
	# принадлежит капоту и Аркадию. Проверять поверх них нечего.
	errs.append_array(await _use(interact, ctx, "car-hood", state))
	errs.append_array(await _use(interact, ctx, "arkady-door", state))
	errs.append_array(await _use(interact, ctx, "shop-key", state))
	if not state.hasItem("shop-key"):
		errs.append("подготовка: ключ от сельпо не взялся, задачи ниже не проверить")

	# ---- W0: до сельпо и до бочки задачи о поливе нет ----
	# Ключ от сельпо в кармане, но в сельпо игрок ещё не заходил и в бочку
	# не заглядывал — про полив ему знать неоткуда.
	chapters.pushTask()
	if String(state.task) == String(tasks.get("farmKey", "")):
		errs.append("W0: полив предложен до сельпо и до бочки")

	# ---- W0б (фаза 15): сельпо открылось — полив ВСТАЁТ В ЗАДАЧУ ----
	# Это и есть главная правка фазы 15 по сюжету. До неё строка про ферму
	# стояла седьмой в очереди и не показывалась ни разу за прохождение:
	# выше неё шесть ранних return, а вход в цепочку требовал флага, который
	# не ставился. Околица при этом была построена и достижима.
	errs.append_array(await _use(interact, ctx, "shop-door", state))
	if not state.has("shop-open"):
		errs.append("W0б: сельпо не открылось ключом")
	# ФАЗА 17. Дверь открыта — ступень сельпо ещё НЕ пройдена: игрок шёл сюда
	# за бегунком, и строка обязана держаться, пока деталь не в кармане.
	chapters.pushTask()
	if String(state.task) != String(tasks.get("shop", "")):
		errs.append("W0б: дверь открыта, бегунка нет, а задача уже не про "
			+ "сельпо: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "shop-crate", state))
	if not state.hasItem("distributor"):
		errs.append("W0б: бегунок из ящика не взялся")
	# ФАЗА 18. Между сельпо и поливом встала ТОПКА БАНИ (решение Петра: баня
	# и погреб обязательны). Она стоит именно там, потому что парилка греется
	# 150 секунд, а полив идёт на том же участке и занимает как раз их:
	# заслонку прикрыл — пошёл поливать — вернулся, пар есть. Здесь топка —
	# фон, за неё отвечает smoke_village.gd; закрываем её флагом.
	chapters.pushTask()
	if String(state.task) != String(tasks.get("farmKey", "")):
		errs.append("W0б: бегунок в кармане, а задача не про ферму: «%s»" % state.task)

	# ---- W1: пустая бочка у грядок ----
	# Второй вход в ту же цепочку: игрок мог зайти с другого конца. Точка
	# здесь — ОСМОТР из LOOKS, а не дескриптор бочки: с фазы 15 бочка гаснет
	# в главе ДЕРЕВНЯ и уступает ему место (см. interact.gd, spray-barrel).
	errs.append_array(await _use(interact, ctx, "garden-barrel-empty", state))
	if not state.looked.has("garden-barrel-empty"):
		errs.append("W1: пустая бочка не осмотрена")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("farmKey", "")):
		errs.append("W1: бочка осмотрена, а задача не про ключ: «%s»" % state.task)

	# ---- W2: кран сипит воздухом ----
	# Отказ нарочно: насос не пущен, воды нет, и игра обязана сказать об этом.
	errs.append_array(await _use(interact, ctx, "banya-tap", state))
	if state.has("leyka-filled"):
		errs.append("W2: кран дал воду до рубильника")

	# ---- W3: замок водокачки без ключа ----
	errs.append_array(await _use(interact, ctx, "door-pump", state))
	if state.has("pump-open"):
		errs.append("W3: водокачка открылась без ключа")
	if not col.is_blocker_active("door-pump"):
		errs.append("W3: створка водокачки погашена, хотя дверь заперта")

	# ---- W4: ключ на ферме ----
	errs.append_array(await _use(interact, ctx, "farm-key", state))
	if not state.hasItem("farm-key"):
		errs.append("W4: ключ с гвоздя не взялся")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("pumpDoor", "")):
		errs.append("W4: ключ на руках, а задача не про водокачку: «%s»" % state.task)

	# ---- W5: замок, рубильник ----
	errs.append_array(await _use(interact, ctx, "door-pump", state))
	if not state.has("pump-open"):
		errs.append("W5: водокачка не открылась ключом")
	if col.is_blocker_active("door-pump"):
		errs.append("W5: дверь открыта, а створка в четвёртом наборе не погашена — "
			+ "войти нельзя")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("pumpBreaker", "")):
		errs.append("W5: дверь открыта, а задача не про рубильник: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "pump-breaker", state))
	if not state.has("pump-on"):
		errs.append("W5: рубильник не сработал")
	var lights: Variant = ctx.get("lights")
	if lights != null and not bool(lights.isOn("pump")):
		errs.append("W5: насос пущен, а лампа будки не зажглась — подтверждения нет")

	# ---- W6: кран без лейки ----
	errs.append_array(await _use(interact, ctx, "banya-tap", state))
	if state.has("leyka-filled"):
		errs.append("W6: лейка наполнилась, не будучи на руках")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("leyka", "")):
		errs.append("W6: воды хватает, а задача не про лейку: «%s»" % state.task)

	# ---- W7: лейка из сарая, вода из крана ----
	errs.append_array(await _use(interact, ctx, "shed-leyka", state))
	if not state.hasItem("leyka"):
		errs.append("W7: лейка с полки не взялась")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("tapWater", "")):
		errs.append("W7: лейка на руках, а задача не про кран: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "banya-tap", state))
	if not state.has("leyka-filled"):
		errs.append("W7: кран не налил воду в лейку")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("waterRows", "")):
		errs.append("W7: лейка полная, а задача не про грядки: «%s»" % state.task)

	# ---- W8: четыре грядки ----
	# Пятая — та, под которой пусто: вода уходит мгновенно. Отдельного флага
	# у неё нет намеренно, связка узнаётся, а не объявляется, — но политой
	# она обязана считаться, иначе цепочка не закроется.
	for i in 4:
		errs.append_array(await _use(interact, ctx, "water-row-%d" % i, state))
		if not state.has("watered-%d" % i):
			errs.append("W8: грядка %d не полита" % i)
	if not state.has("water-done"):
		errs.append("W8: четыре грядки политы, а цепочка не закрылась")

	# ---- W-конец (фаза 17): полив закрыт — очередь идёт ДАЛЬШЕ ПО НОЧИ ----
	# До фазы 17 строка задачи уходила на машину ещё в сельпо, за час до этого
	# места, и всё, что здесь пройдено, игрок делал бы вопреки подсказке.
	# Теперь очередь после полива ведёт к следующему обязательному шагу, а не
	# к капоту. Улику закрываем флагом: за неё отвечает smoke_village.gd.
	chapters.pushTask()
	if String(state.task) != String(tasks.get("banyaFire", "")):
		errs.append("W-конец: после полива задача не ведёт в баню: «%s»" % state.task)
	# ФАЗА 18. Сразу за поливом идёт ВТОРАЯ ПОЛОВИНА БАНИ — пар, надпись,
	# ключ, погреб, керосинка, чердак, — и только за ней линия Вали.
	# Пар в тесте не ждём: BANYA_WARM это 150 секунд реального времени.
	state.set_flag("damper-shut")
	state.set_flag("boarded-tapes")
	state.set_flag("banya-written")
	state.set_flag("bathloft-found")
	state.set_flag("mill-clue")
	state.set_flag("snt-returned")
	chapters.pushTask()
	if String(state.task) != String(tasks.get("valyaTalk", "")):
		errs.append("W-конец: после бани задача не про Валю: «%s»" % state.task)

	# ---- W9: теплица тем же ведром ----
	errs.append_array(await _use(interact, ctx, "greenhouse-vent", state))
	if not state.has("vent-shut"):
		errs.append("W9: форточка теплицы не закрылась")
	errs.append_array(await _use(interact, ctx, "greenhouse-seedlings", state))
	if not state.has("seedlings-done"):
		errs.append("W9: рассада не полита")

	print("smoke_water: глава %s, звеньев пройдено 9, грядок 4, лейка %s"
		% [state.chapter, state.hasItem("leyka")])
	if errs.is_empty():
		print("smoke_water: PASS")
		quit(0)
		return
	print("FAIL smoke_water: расхождений ", errs.size())
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
##
## Точки, которые ЖМУТСЯ НАРОЧНО РАНО (кран без насоса, замок без ключа),
## закрытыми не считаются: их when пускает всегда, отказывает сама onUse
## репликой. Если бы отказ жил в when, игрок не увидел бы даже подсказки.
##
## ФАЗА 16, ВТОРОЙ РЕЖИМ. Раньше цель просто присваивалась: interact.target =
## def. Тест доказывал порядок флагов и НИЧЕГО не знал о том, видно ли точку.
## Ровно поэтому он был зелёный при кране, у которого не было ни одного
## полигона: игрок приходил к бане и не мог набрать воду, а прогон рапортовал
## «девять звеньев пройдено». Теперь игрок ставится в точку подхода, целится и
## берёт цель через Interact.find() — как рукой.
func _use(interact: Interact, ctx: Dictionary, id: String,
		state: GameState, aim := true) -> Array[String]:
	var out: Array[String] = []
	var d: Variant = _find(interact, id)
	if d == null:
		out.append("нет точки «%s» в списке" % id)
		return out
	var def: Dictionary = d
	if def.has("when") and not bool((def["when"] as Callable).call(state)):
		out.append("точка «%s» закрыта условием when на своём шаге" % id)
		return out
	if aim:
		var why := _aim_at(def, state)
		if why != "":
			out.append("точка «%s»: %s" % [id, why])
			# Прицелиться не вышло — цепочку всё равно ведём дальше, иначе
			# один провал прячет все звенья ниже.
			interact.target = def
	else:
		interact.target = def
	interact.use(ctx)
	await process_frame
	return out


## Встать так, чтобы точка нашлась прицелом. Возвращает "" при успехе или
## причину — ту же, что видит игрок: некуда встать, не видно, уводит на чужое.
func _aim_at(def: Dictionary, state: GameState) -> String:
	if _main == null:
		return "сборка не поднята"
	var interact: Interact = _main.get("interact")
	var col: CollisionWorld = _main.get("col")
	var player: Player = _main.get("player")
	if interact == null or col == null or player == null or player.camera == null:
		return "нет игрока или камеры в сборке"
	var id := String(def["id"])
	var pos: Vector3 = def["pos"]
	var rr := float(def["r"])
	var rival := ""
	var stood := false
	for rad: float in AIM_RINGS:
		if rad > rr:
			break
		for ai in AIM_ANGLES:
			var ang := TAU * float(ai) / float(AIM_ANGLES)
			var x := pos.x + rad * cos(ang)
			var z := pos.z + rad * sin(ang)
			# Пол ищем с нескольких высот: точка может лежать в сарае под
			# перекрытием, в погребе или на стене, и луч из одной высоты
			# находит то плиту над головой, то верстак под рукой.
			for up: float in AIM_FLOOR_PROBES:
				var fl := col.ray_down(x, pos.y + up, z, CollisionWorld.ALL_SOLID)
				if fl.is_empty():
					continue
				var fy := float(fl["y"])
				if col.point_hit(x, fy + 0.90, z, CollisionWorld.ALL_SOLID):
					continue
				var hit := col.capsule_hit_d(x, fy + 0.33, z, x, fy + 1.48, z, 0.30,
					CollisionWorld.ALL_SOLID)
				if not hit.is_empty() and float(hit["depth"]) > 0.06 \
						and absf(float(hit["ny"])) < 0.5:
					continue
				var eye := Vector3(x, fy + player.height - Player.EYE_DROP, z)
				var v := pos - eye
				if v.length() > rr or v.length() < 0.05:
					continue
				stood = true
				var dir := v.normalized()
				# Камеру ставим тем же порядком эйлеров, что _apply_camera: YXZ.
				player.place(x, fy, z, atan2(-dir.x, -dir.z))
				player.pitch = asin(clampf(dir.y, -1.0, 1.0))
				player.pitch_target = player.pitch
				player.camera.global_transform = Transform3D(
					Basis.from_euler(Vector3(player.pitch, player.yaw, 0.0), EULER_ORDER_YXZ),
					eye)
				var got: Variant = interact.find(player.camera, state)
				if got != null and String((got as Dictionary)["id"]) == id:
					return ""
				if got != null and rival == "":
					rival = String((got as Dictionary)["id"])
	if not stood:
		return "негде встать в радиусе %.2f м" % rr
	if rival != "":
		return "прицел уводит на «%s»" % rival
	return "точку не видно ни с одной позиции подхода"


func _cards(main: Node) -> void:
	var ui: Overlays = main.get("ui")
	for _i in 40:
		if not ui.card.open:
			await process_frame
			continue
		ui.advanceCard()
		await process_frame
	await process_frame

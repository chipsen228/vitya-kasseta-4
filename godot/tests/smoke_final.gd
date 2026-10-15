# Финал целиком: сумка, ворота, погоня, обе развязки (фаза 15).
#
# Тот же способ, что в smoke_village.gd и smoke_water.gd: игра ведётся так,
# как её ведёт игрок — точка ищется по id, ставится целью и жмётся [E].
# Флагами выставляется только ПОДГОТОВКА (бак, ключи), потому что за неё
# отвечают другие тесты.
#
# ЧЕТЫРЕ ВЕЩИ, РАДИ КОТОРЫХ ОН И НАПИСАН.
#
# 1. УЕХАТЬ, НЕ ПОДОЙДЯ К ВОРОТАМ, НЕЛЬЗЯ. До фазы 15 car-drive спрашивал
#    только atLeast("street"): игрок мог сесть в машину и уехать, ни разу
#    не тронув цепь, то есть мимо единственной сцены, где деда видно вплотную.
# 2. ПОСЛЕДНИЙ ШАГ СЮЖЕТА — В ДОМЕ. Первая строка задачи в главе обязана
#    вести за кассетами, а не к воротам.
# 3. ПОГОНЯ ОБЯЗАНА НАЧАТЬСЯ И СОКРАЩАТЬ ДИСТАНЦИЮ. Настоящий дед (ai.gd)
#    до фазы 15 был заперт на участке: улицы нет в навграфе, и выйти за
#    ворота он не мог физически. Здесь проверяется, что режим final включился
#    и что расстояние между ним и игроком РЕАЛЬНО падает.
# 4. ДВЕ РАЗВЯЗКИ. Догнал — концовка "caught". Уехал — та же концовка, что
#    была до фазы 15 (без улик это "alone"): старые финалы не тронуты.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/smoke_final.gd
extends SceneTree

const BOOT_FRAMES := 600
const WAIT_FRAMES := 900        # потолок ожидания концовки, кадров
const CHASE_STEPS := 60         # шагов по 0.1 с на замер сближения


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
		printerr("smoke_final: боут не завершился")
		quit(1)
		return

	main.call("_start_game")
	await process_frame

	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var interact: Interact = main.get("interact")
	var ctx: Dictionary = main.get("ctx")
	var player: Player = main.get("player")
	var threat: Variant = main.get("threat")
	var tasks: Dictionary = GameData.texts()["TASKS"]
	# ФАЗА 18: провал у ворот проверяется по failOpen, см. F5.
	var ui: Overlays = main.get("ui")

	var errs: Array[String] = []
	var chase := ""

	# ---- ПРОГОН А: догнал ----
	errs.append_array(await _to_gate(main, state, chapters))

	# F1. Ворота заперты — машина не трогается.
	var drive: Variant = _find(interact, "car-drive")
	if drive == null:
		errs.append("F1: нет точки «car-drive»")
	elif bool(((drive as Dictionary)["when"] as Callable).call(state)):
		errs.append("F1: машина пускает при накинутой цепи — уехать можно мимо ворот")

	# F2. Первая задача главы — за кассетами, и она выполнима.
	chapters.pushTask()
	if String(state.task) != String(tasks.get("bagTapes", "")):
		errs.append("F2: первая задача ВОРОТ не про сумку: «%s»" % state.task)
	errs.append_array(await _use(interact, ctx, "final-bag", state))
	if player.frozen:
		errs.append("F2: FINAL_AT_GATE froze the player after packing the bag")
	var phone: Phone = main.get("phone")
	if phone == null or not phone.talking:
		errs.append("F2: FINAL_AT_GATE did not start through the shared line player")
	if not state.has("bag-packed"):
		errs.append("F2: сумка не собралась")
	chapters.pushTask()
	if String(state.task) == String(tasks.get("bagTapes", "")):
		errs.append("F2: сумка собрана, а задача осталась прежней")

	# F3. Цепь снята — только теперь машина пускает.
	#
	# ФАЗА 17. Сначала — что она НЕ СНИМАЕТСЯ ДО СУМКИ. Погоня стартует ровно
	# по снятой цепи, а монолог у крыльца морозит игрока на семнадцать секунд:
	# снявший цепь раньше сумки попадается гарантированно. Проверка идёт на
	# отдельном состоянии, потому что сумка выше по тексту уже собрана.
	state.set_flag("bag-packed", false)
	errs.append_array(await _use(interact, ctx, "gate-chain", state))
	if state.has("gate-open"):
		errs.append("F3: цепь снялась до сумки — погоня начнётся посреди "
			+ "монолога у крыльца, и уйти от неё нечем")
	state.set_flag("bag-packed")
	errs.append_array(await _use(interact, ctx, "gate-chain", state))
	if not state.has("gate-open"):
		errs.append("F3: цепь не снялась при ключе в кармане")
	if drive != null and not bool(((drive as Dictionary)["when"] as Callable).call(state)):
		errs.append("F3: ворота открыты, а машина всё равно не пускает")

	# F4. Погоня: таймер сцены у створки отсчитывается, режим включается.
	chapters.update(5.0)
	await process_frame
	if threat == null:
		errs.append("F4: угрозы в сборке нет вовсе")
	elif not bool(threat.get("final_mode")):
		errs.append("F4: ворота открыты, а погоня не началась")
	else:
		var feet := player.feet()
		var d0 := _dist(threat, feet)
		if d0 < 6.0 or d0 > 16.0:
			errs.append("F4: стартовая дистанция %.1f м — не похоже на двенадцать" % d0)
		# Игрок стоит на месте, дед идёт. Сорок шагов по 0.1 с — шесть секунд,
		# за них он обязан съесть больше трети форы.
		for _i in CHASE_STEPS:
			threat.update(0.1)
			await process_frame
			if state.chapter == "end":
				break
		var d1 := _dist(threat, player.feet())
		chase = "%.1f -> %.1f м за %.0f с" % [d0, d1, CHASE_STEPS * 0.1]
		if d1 >= d0 - 1.0 and state.chapter != "end":
			errs.append("F4: за шесть секунд дистанция %.1f -> %.1f — он не идёт" % [d0, d1])

	# F5. Первые две поимки сохраняют текущую игру в подвале; третья завершает запись.
	if threat != null and state.chapter != "end":
		var feet2 := player.feet()
		threat.call("place_at", feet2.x + 0.4, feet2.y, feet2.z + 0.4)
		for _i in 40:
			threat.update(0.05)
			await process_frame
			if state.chapter == "end" or not state.recovery.is_empty():
				break
	# Безопасный пропуск проигрывает тот же удар и переносит в подвал.
	if (ctx["capture"] as CaptureRecovery).phase == "hit":
		(ctx["cutscene"] as Cutscene).skip()
	await _wait_end(main, state)
	if state.chapter == "end":
		errs.append("F5: первая поимка дала концовку вместо восстановления в подвале")
	elif state.recovery.is_empty() or String(state.recovery.get("phase", "")) != "cellar":
		errs.append("F5: первая поимка не вернула игрока в управляемый подвал")
	if state.failCount < 1:
		errs.append("F5: провал не сосчитан — третьей поимки не наступит никогда")
	# Выходим через существующий люк, сохранив открытые ворота.
	if not state.recovery.is_empty():
		errs.append_array(await _use(interact, ctx, CaptureRecovery.LIGHT_ID, state))
		errs.append_array(await _use(interact, ctx, CaptureRecovery.HATCH_ID, state))
		for h: Dictionary in GameData.site()["HATCHES"]:
			if h["id"] == "hatch-cellar":
				main.call("_use_hatch", {"hatch": h, "down": false})
				break
		await create_timer(1.2).timeout
		if not state.recovery.is_empty() or not state.has("gate-open"):
			errs.append("F5: выход из подвала не завершил восстановление с открытыми воротами")
	state.failCount = 2
	chapters.emit("caught")
	if (ctx["capture"] as CaptureRecovery).phase == "hit":
		(ctx["cutscene"] as Cutscene).skip()
	var got_end := await _wait_end(main, state)
	if not got_end or state.chapter != "end":
		errs.append("F5: третья поимка не дала концовку")
	elif str(state.ending) != "caught":
		errs.append("F5: третья поимка дала концовку «%s», а не «caught»"
			% str(state.ending))

	# F6 (фаза 16). На ПОИМКЕ катсцены отъезда быть не должно: его догнали,
	# уезжать некому. Сцена, сыгранная здесь, показала бы уезжающую машину
	# ровно после того, как игрока поймали.
	var cut_a: Variant = main.get("cutscene")
	if cut_a != null and bool(cut_a.playing):
		errs.append("F6: катсцена отъезда сыграла на концовке «поимка»")
	if not Chapters.NO_DRIVE.has("quiet") or not Chapters.NO_DRIVE.has("caught"):
		errs.append("F6: список концовок без отъезда неполон: %s"
			% str(Chapters.NO_DRIVE.keys()))
	if Chapters.DRIVE_LEN > Cutscene.MAX_LEN or Chapters.DRIVE_LEN > 10.0:
		errs.append("F6: катсцена длиной %.1f с — дольше десяти" % Chapters.DRIVE_LEN)
	# Четыре обязательных плана, сумма секунд равна десяти секундам сцены.
	# Кадр, который короче своей доли, оставляет хвост сцены на камере из
	# ниоткуда: _apply_shot берёт последний кадр и держит его молча.
	if Chapters.DRIVE_SHOTS.size() != 4:
		errs.append("F6: кадров в катсцене %d, а раскадровка — четыре"
			% Chapters.DRIVE_SHOTS.size())
	var sec := 0.0
	for sh: Dictionary in Chapters.DRIVE_SHOTS:
		sec += float(sh.get("sec", 0.0))
	if absf(sec - Chapters.DRIVE_LEN) > 0.001:
		errs.append("F6: сумма кадров %.2f с, а сцена длится %.2f с"
			% [sec, Chapters.DRIVE_LEN])

	# ---- ПРОГОН Б: уехал ----
	main.call("_on_restart")
	await process_frame
	errs.append_array(await _to_gate(main, state, chapters))
	errs.append_array(await _use(interact, ctx, "final-bag", state))
	errs.append_array(await _use(interact, ctx, "gate-chain", state))
	if not state.has("gate-open"):
		errs.append("Б: цепь не снялась на втором прогоне")
	# Садимся в машину сразу: между двумя оборотами стартёра две с половиной
	# секунды, и дед их не успевает — в этом весь баланс погони.
	errs.append_array(await _use(interact, ctx, "car-drive", state))

	# ФАЗА 16. Между «нажал ехать» и титрами встала катсцена отъезда. Проверок
	# четыре, и каждая про свою беду: сцена не сыграла вовсе (финал опять
	# обрывается на карточке), сцена не отдаёт управление (игрок залип), сцена
	# не пропускается (на втором прохождении это читается зависанием), сцена
	# СЪЕЛА концовку (после неё state.ending обязан быть тем же, что был бы).
	var cut: Variant = main.get("cutscene")
	# Стартёр крутит два оборота с паузой в две с половиной секунды, и
	# «ехать» приходит не в том же кадре, в котором нажали.
	var started := false
	for _i in WAIT_FRAMES:
		if cut != null and bool(cut.playing):
			started = true
			break
		if state.chapter == "end":
			break
		await process_frame
	if cut == null:
		errs.append("Б: сценарной камеры нет в сборке вовсе")
	elif not started:
		errs.append("Б: катсцена отъезда не началась на живой концовке")
	else:
		if state.chapter == "end":
			errs.append("Б: титры пошли, не дождавшись катсцены")
		# ФАЗА 17, ОКНО НЕЧУВСТВИТЕЛЬНОСТИ. Пропуск — тем же вызовом, что
		# делает main._unhandled_input. В первые Cutscene.SKIP_AFTER секунд
		# он обязан НЕ СРАБОТАТЬ: сцену запускает то же нажатие [E], которым
		# игрок завёл машину, стартёр растянут на 2.6 с, и это нажатие
		# доезжало сюда и гасило сцену в первом же её кадре.
		cut.skip()
		await process_frame
		if not bool(cut.playing):
			errs.append("Б: катсцена погасла от нажатия в первую же секунду — "
				+ "это то самое нажатие, которым игрок завёл машину")
		# Прокручиваем саму погоню: это проверяет не только окно пропуска, но и
		# ссылочное runtime-состояние лямбды. Скаляры здесь захватываются по
		# значению и раньше возвращали Витю к x=0.35 каждый кадр.
		while float(cut.call("time")) < 3.75 and bool(cut.playing):
			cut.update(0.1)
			await process_frame
		var drive_actors: Variant = ctx.get("actors")
		var drive_echo: Node3D = drive_actors.get_actor("echo") \
			if drive_actors != null else null
		var drive_props: Variant = ctx.get("props")
		var drive_car: Node3D = drive_props.get_prop("car") if drive_props != null else null
		if drive_echo == null or drive_echo.position.x < 2.0:
			errs.append("Б: Витя не добежал до двери машины в широком плане")
		while float(cut.call("time")) < 6.55 and bool(cut.playing):
			cut.update(0.1)
			await process_frame
		if drive_echo != null and drive_car != null \
				and drive_echo.position.x - drive_car.position.x < 4.0:
			errs.append("Б: боковой трекинг не увеличил разрыв погони")
		while float(cut.call("time")) < 8.35 and bool(cut.playing):
			cut.update(0.1)
			await process_frame
		var stopped_x := drive_echo.position.x if drive_echo != null else 0.0
		while float(cut.call("time")) < 9.20 and bool(cut.playing):
			cut.update(0.1)
			await process_frame
		if drive_echo != null and absf(drive_echo.position.x - stopped_x) > 0.08:
			errs.append("Б: Витя продолжил погоню после %.1f с" % Chapters.DRIVE_STOP_CHASE)
		if drive_car == null or drive_car.position.x > -20.0:
			errs.append("Б: машина не ушла на запад по квадратичной траектории")
		# После проверенного полного действия пропуск обязан работать, иначе на
		# втором прохождении оставшиеся секунды читаются зависанием.
		if bool(cut.playing):
			cut.skip()
			await process_frame
			if bool(cut.playing):
				errs.append("Б: катсцена не пропустилась и после окна в %.1f с"
					% Cutscene.SKIP_AFTER)

	var drove := await _wait_end(main, state)
	if not drove:
		errs.append("Б: машина не завелась со второго оборота")
	elif String(state.ending) == "caught":
		errs.append("Б: чистый отъезд дал концовку поимки")
	elif String(state.ending) != "alone":
		errs.append("Б: чистый отъезд без улик дал «%s», а не «alone»" % state.ending)

	# ФАЗА 17. Концовка ровно одна. «Ехать» приходит ОТЛОЖЕННО, через 2.6 с
	# после нажатия: за эти секунды игрок успевает нажать [E] ещё раз, а игру
	# успевают кончить поимкой. Второе событие не должно ни переписать
	# концовку, ни завести катсцену поверх титров.
	var was := String(state.ending)
	chapters.emit("drive")
	await process_frame
	if String(state.ending) != was:
		errs.append("Б: второе «ехать» переписало концовку: «%s» -> «%s»"
			% [was, state.ending])
	if cut != null and bool(cut.playing):
		errs.append("Б: второе «ехать» завело катсцену поверх титров")

	print("погоня: ", chase if chase != "" else "не замерена")
	if errs.is_empty():
		print("smoke_final: PASS")
		quit(0)
		return
	print("FAIL smoke_final: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ---------- служебное ----------

## Довести игру до главы ВОРОТА с подготовкой: фонарь, бак, оба ключа.
## Всё это — предмет других тестов, здесь оно только фон.
func _to_gate(main: Node, state: GameState, chapters: Chapters) -> Array[String]:
	var out: Array[String] = []
	state.give("flashlight")
	state.give("car-key")
	state.give("chain-key")
	state.set_flag("tank-full")
	# ФАЗА 17. Плюс три линии деревни. До ВОРОТ игрок доходит только с ними
	# (chapters.village_chores_done), а точка 'car-drive' с фазы 17 держит их
	# страховкой — на случай старого сохранения, [R] и отладочного прыжка мимо
	# village_quest.fixed(). За сами линии отвечают smoke_water.gd,
	# smoke_valya.gd и smoke_village.gd; здесь они фон.
	state.set_flag("water-done")
	state.set_flag("valya-gone")
	state.set_flag("boarded-tapes")
	# ФАЗА 18. Плюс баня и погреб: решением Петра они вошли в тот же замок.
	# За саму петлю отвечает smoke_village.gd, здесь она фон.
	state.set_flag("banya-written")
	state.set_flag("bathloft-found")
	state.set_flag("mill-clue")
	state.set_flag("snt-returned")
	chapters.go("gate")
	await _cards(main)
	if state.chapter != "gate":
		out.append("go('gate') не встало: глава %s" % state.chapter)
	return out


func _dist(threat: Variant, feet: Vector3) -> float:
	var p: Vector3 = threat.get("pos")
	return Vector2(p.x - feet.x, p.z - feet.z).length()


func _wait_end(main: Node, state: GameState) -> bool:
	var ui: Overlays = main.get("ui")
	for _i in WAIT_FRAMES:
		if state.chapter == "end" or ui.failOpen or String(state.recovery.get("phase", "")) == "cellar":
			return true
		if ui.card.open:
			ui.advanceCard()
		await process_frame
	return state.chapter == "end"


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

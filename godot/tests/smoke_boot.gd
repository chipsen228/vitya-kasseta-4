# Смоук склейки (lead, фаза 4): боут main.tscn в headless, старт игры и ~300
# игровых кадров с прожатием интро-карточек. Ловит рантайм-ошибки динамических
# вызовов (ctx-Callable, Variant-методы, сигналы), которые check_compile не
# видит: они падают только при исполнении. Рендер здесь Dummy — картинку и
# шейдеры проверяет оконный смоук, не этот тест.
#
# Запуск: Godot…_console.exe --headless --path godot --script res://tests/smoke_boot.gd
extends SceneTree

const BOOT_FRAMES := 600     # боуту хватает ~10 await-кадров; запас на сборку мира
const PLAY_FRAMES := 300


func _initialize() -> void:
	_run()


func _run() -> void:
	var scene: PackedScene = load("res://src/main.tscn")
	if scene == null:
		push_error("smoke_boot: нет res://src/main.tscn")
		quit(1)
		return
	var main: Node = scene.instantiate()
	root.add_child(main)

	# Боут завершён, когда появились chapters (последний шаг _boot перед
	# старт-экраном) — poll по кадрам, как ждал бы живой игрок.
	var waited := 0
	while main.get("chapters") == null and waited < BOOT_FRAMES:
		await process_frame
		waited += 1
	if main.get("chapters") == null:
		push_error("smoke_boot: боут не завершился за %d кадров" % BOOT_FRAMES)
		quit(1)
		return
	print("smoke_boot: боут завершён (кадров: %d)" % waited)

	var ui: Overlays = main.get("ui")
	var state: GameState = main.get("state")

	main.call("_start_game")
	await process_frame
	if not bool(main.get("running")):
		push_error("smoke_boot: _start_game не поднял running")
		quit(1)
		return

	# Интро-карточки держат frozen через ui.busy — прожимаем их, как игрок
	# жмёт Space, иначе главы и угроза не потикают ни кадра.
	var advanced := 0
	for i in PLAY_FRAMES:
		if ui.card.open and (i % 10) == 0:
			ui.advanceCard()
			advanced += 1
		await process_frame

	var player: Player = main.get("player")
	var f := player.feet()
	var threat: Threat = main.get("threat")
	print("smoke_boot: глава '%s' %s, карточек прожато %d, ноги (%.2f %.2f %.2f), угроза %s"
		% [state.chapter, state.timecode(), advanced, f.x, f.y, f.z, state.threatState])

	# Голос (фаза 5). Модуль обязан быть всегда — даже когда озвучки в сборке
	# нет: половина точек вызова спрашивает у него, звучала ли реплика.
	var voice: GameVoice = main.get("voice")
	if voice == null:
		push_error("smoke_boot: voice не создан")
		quit(1)
		return
	var voiced := ""
	if voice.enabled:
		# Известный ключ должен отдавать длину: если манифест на месте, а файлы
		# не импортированы, вся озвучка молчит без единого сообщения в логе.
		var key := GameVoice.line_key("vitya", String(GameData.texts()["THREAT_AT_GATE"]))
		var sec := voice.play_dialogue_line("vitya", String(GameData.texts()["THREAT_AT_GATE"]))
		voiced = ", озвучка %d реплик, «у ворот» %.2f с" % [1 if sec > 0.0 else 0, sec]
		if not voice.has_line(key) or sec <= 0.0:
			push_error("smoke_boot: озвучка включена, но реплика не играет — "
				+ "прогнать --headless --import")
			quit(1)
			return
	else:
		voiced = ", озвучки в сборке нет (субтитры)"
	print("smoke_boot: голос собран", voiced)

	var fails := 0
	if not bool(main.get("running")):
		push_error("smoke_boot: running обвалился по ходу кадров")
		fails += 1
	if state.chapter == "prologue" and advanced > 2:
		push_error("smoke_boot: карточки прожаты, а глава не сдвинулась с prologue")
		fails += 1
	if threat == null:
		push_error("smoke_boot: threat не создан")
		fails += 1

	if fails > 0:
		print("smoke_boot: FAIL (%d)" % fails)
		quit(1)
		return
	print("smoke_boot: PASS")
	quit(0)

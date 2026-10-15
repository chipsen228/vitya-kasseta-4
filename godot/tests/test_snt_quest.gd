extends SceneTree

# Проверка восстановления состояния и доступности.
const BOOT_FRAMES := 600
var errors: Array[String] = []
const STAGES := [
	["snt-watch-log", "snt-watch-read"], ["snt-nina-talk", "snt-nina-met"],
	["snt-nina-greenhouse", "snt-nina-greenhouse"], ["snt-yard", "snt-yard-seen"],
	["snt-semyon-talk", "snt-semyon-met"], ["snt-pump-source", "snt-pump-found"],
	["snt-pump-fix", "snt-pump-fixed"], ["snt-pump-filter", "snt-filter-read"],
	["snt-route-map", "snt-route-known"], ["snt-radio-tune", "snt-radio-set"],
	["snt-radio-listen", "snt-radio-heard"], ["snt-signal", "snt-booth-used"],
	["snt-return", "snt-return-inspected"], ["@begin", "snt-pursuit-started"],
	["@escape", "snt-pursuit-escaped"], ["snt-semyon-talk", "snt-returned"],
]
var _aimed: Dictionary = {}


func _initialize() -> void:
	_run()


func _run() -> void:
	var main: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for frame in BOOT_FRAMES:
		if main.get("chapters") != null:
			break
		await process_frame
	if main.get("chapters") == null:
		printerr("test_snt_quest: boot failed")
		quit(1)
		return
	main.call("_start_game")
	await _cards(main)
	main.set_process(false)
	main.get("player").set_physics_process(false)
	var ctx: Dictionary = main.get("ctx")
	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var interact: Interact = main.get("interact")
	var ui: Overlays = main.get("ui")
	var audio: GameAudio = main.get("audio")
	var quest: SntQuest = ctx.get("snt")
	ctx["playDialogue"] = func(_rows: Array, done: Callable) -> void: done.call()
	if quest == null:
		_fail("SntQuest не зарегистрирован")
		_finish()
		return
	var world: Dictionary = (ctx["world"] as Dictionary)["snt"]
	var nodes: Dictionary = world["nodes"]
	var points: Dictionary = world["quest"]
	for id: String in ["snt-watch-log", "snt-yard", "snt-signal", "snt-return", "snt-watermarks", "snt-last-round"]:
		if _definition(interact, id).is_empty():
			_fail("не зарегистрирована точка " + id)
	if audio._spatial_pool.size() != GameAudio.SPATIAL_VOICES:
		_fail("пространственный пул имеет неверный размер")
	var chain: RenderChain = main.get("render_chain")
	if not chain.world_view.audio_listener_enable_3d:
		_fail("у игрового viewport выключен 3D listener")
	for voice: AudioStreamPlayer3D in audio._spatial_pool:
		if voice.get_world_3d() != chain.camera.get_world_3d():
			_fail("пространственный голос находится вне игрового World3D")

	# Early residents remain visible; investigation conditions own progression.
	var scares_before: Variant = ctx.get("scaresOn")
	for early_chapter: String in ["street","dark","village"]:
		for scares_enabled: bool in [false,true]:
			state.reset()
			ctx["scaresOn"] = func() -> bool: return scares_enabled
			chapters.go(early_chapter,true)
			var residents: Variant = ctx["episodeActors"]
			for who: String in ["nina","semyon"]:
				var person: Node3D = residents.figure(who)
				if person == null or not person.visible:
					_fail("early resident hidden: " + early_chapter + "/" + who)
			for early_id: String in ["snt-nina-talk","snt-semyon-talk","snt-nina-greenhouse"]:
				var definition := _definition(interact,early_id)
				var active := bool((definition["when"] as Callable).call(state))
				var should_talk := early_id != "snt-nina-greenhouse"
				if active != should_talk:
					_fail("early resident hint/greenhouse availability: " + early_chapter + "/" + early_id)
				if active:
					var who := "nina" if early_id == "snt-nina-talk" else "semyon"
					if not residents.figure(who).visible: _fail("active early hint has invisible resident")
				(definition["onUse"] as Callable).call(ctx)
			for flag: String in SntQuest.FLAGS + SntEpisode.PROGRESS:
				if state.has(flag): _fail("early resident granted progress: " + flag)
	state.reset()
	state.set_flag("mill-clue")
	chapters.go("village",true)
	for pair: Array in [["snt-nina-talk","nina"],["snt-semyon-talk","semyon"]]:
		var definition := _definition(interact,String(pair[0]))
		if bool((definition["when"] as Callable).call(state)) and not ctx["episodeActors"].figure(String(pair[1])).visible:
			_fail("active interaction has invisible resident: " + String(pair[0]))
	var greenhouse := _definition(interact,"snt-nina-greenhouse")
	if bool((greenhouse["when"] as Callable).call(state)):
		_fail("greenhouse ghost prompt available before Nina meeting")
	ctx["scaresOn"] = scares_before

	_seed(state)
	chapters.go("village", true)
	# Проверка восстановления состояния и доступности.
	state.flags.erase("mill-clue")
	for id: String in ["snt-watch-log", "snt-yard", "snt-signal", "snt-nina-talk", "snt-semyon-talk", "snt-pump-source"]:
		_use(interact, ctx, id)
		_close_reader(ui)
	for flag: String in SntQuest.FLAGS:
		if state.has(flag):
			_fail("ранний визит поставил " + flag)
	state.set_flag("mill-clue")
	chapters.pushTask()
	if String(state.task) != String(GameData.texts()["TASKS"]["sntWatch"]):
		_fail("старый village-save не получил журнал обходов")

	# Проверка восстановления состояния и доступности.
	_use(interact, ctx, "snt-watch-log")
	var stale: Callable = ui.reader.onClose
	chapters.retry()
	ui.closeReader()
	if stale.is_valid():
		stale.call()
	if state.has("snt-watch-read"):
		_fail("старый reader callback пережил retry")
	_use(interact, ctx, "snt-watch-log")
	_close_reader(ui)
	var delayed: Array[Callable] = []
	ctx["playDialogue"] = func(_rows: Array, done: Callable) -> void: delayed.append(done)
	_use(interact, ctx, "snt-nina-talk")
	if delayed.is_empty():
		_fail("разговор с Ниной не передал callback диалога")
	else:
		chapters.retry()
		delayed[0].call()
		if state.has("snt-nina-met"): _fail("старый callback разговора пережил retry")
	ctx["playDialogue"] = func(_rows: Array, done: Callable) -> void: done.call()
	_seed(state)
	chapters.go("village", true)

	var old_scares: Variant = ctx.get("scaresOn")
	ctx["scaresOn"] = func() -> bool: return false
	var inventory_before := state.inventory.duplicate()
	var evidence_before := state.evidence
	var stages := STAGES
	for index in stages.size():
		var flag: String = stages[index][1]
		_check_story_gates(interact, state)
		var before := str(state.checkpoint)
		main.get("flashlight").battery = 47.0
		main.get("flashlight").on = false
		_use(interact, ctx, stages[index][0])
		_close_reader(ui)
		if not state.has(flag):
			_fail("этап не поставил " + flag)
		_check_story_gates(interact, state)
		if str(state.checkpoint) == before:
			_fail("emit не переснял checkpoint на " + flag)
		var parsed: Variant = JSON.parse_string(str(state.checkpoint))
		if not (parsed is Dictionary) or not (parsed.get("flags", []) as Array).has(flag):
			_fail("в checkpoint нет " + flag)
		if flag == "snt-booth-used":
			if not quest.exclusive_runtime():
				_fail("ручной сигнал не запустил сцену")
			main.call("_set_paused", true)
			var scene_time := quest._scene_time
			for frame in 3:
				await physics_frame
				await process_frame
			main.call("_process", 0.5)
			if quest._scene_time != scene_time:
				_fail("пауза не заморозила сцену")
			for voice: AudioStreamPlayer3D in audio._spatial_pool:
				if voice.playing and not voice.stream_paused:
					_fail("местный звук продолжился под паузой: stored=%s, main_process=%s, paused=%s, voice=%s" % [audio._spatial_paused, main.is_processing(), main.get("paused"), voice.name])
			main.call("_set_paused", false)
			quest.update(3.5)
			if quest._echo_owned:
				_fail("выключенные испуги показали силуэт у будки")
			for voice: AudioStreamPlayer3D in audio._spatial_pool:
				if voice.playing and voice.stream == audio._shots.get("stinger-2"):
					_fail("при выключенных испугах прозвучал удар")
			quest.update(6.0)
			if quest.exclusive_runtime() or quest._echo_owned:
				_fail("сцена не освободила двойника")
		var checkpoint := str(state.checkpoint)
		var light_checkpoint: Dictionary = (chapters._light_snap as Dictionary).duplicate(true)
		main.get("lights").setLamp("snt-booth", false)
		main.get("flashlight").battery = 5.0
		(nodes["snt-p01-gate"] as Node3D).rotation.y = 0.0
		(nodes["snt-p01-ring"] as Node3D).position = Vector3.ZERO
		chapters.retry()
		if not state.has(flag) or str(state.checkpoint) != checkpoint:
			_fail("retry потерял checkpoint " + flag)
		if absf(float(main.get("flashlight").battery) - 47.0) > 0.1:
			_fail("retry не восстановил фонарь " + flag)
		var light_now: Dictionary = main.get("lights").snapshot()
		if light_now["lamps"] != light_checkpoint["lamps"] or light_now["offGrid"] != light_checkpoint["offGrid"]:
			_fail("retry не восстановил свет " + flag)
		_check_world(state, nodes, points)
		if quest.exclusive_runtime() or quest._echo_owned:
			_fail("retry повторил сцену " + flag)
		for voice: AudioStreamPlayer3D in audio._spatial_pool:
			if voice.playing:
				_fail("retry не очистил местный звук")
		_use(interact, ctx, stages[index][0], true)
		_close_reader(ui)
		if str(state.checkpoint) != checkpoint or quest.exclusive_runtime():
			_fail("повторное действие дублировало этап " + flag)
	ctx["scaresOn"] = old_scares
	if state.inventory != inventory_before or state.evidence != evidence_before:
		_fail("обход изменил инвентарь или evidence")
	for forbidden: String in ["kovrigin-letter", "boarded-tapes", "valya-gone", "grave-dug"]:
		if state.has(forbidden):
			_fail("обход выдал флаг концовки " + forbidden)
	if String(state.task) != String(GameData.texts()["TASKS"]["boarded"]):
		_fail("после обхода не вернулось прежнее задание улики")
	for id: String in ["snt-watermarks", "snt-last-round"]:
		_use(interact, ctx, id)
		_close_reader(ui)
	if state.inventory != inventory_before or state.evidence != evidence_before:
		_fail("необязательные находки изменили условия концовок")

	# Мельницу можно прочитать раньше полива: задача на HUD не меняется,
	# но каждый переход обхода обязан снять собственную контрольную точку.
	_seed(state)
	state.flags.erase("water-done")
	chapters.go("village", true)
	var early_task: Variant = state.task
	if String(early_task) != String(GameData.texts()["TASKS"]["farmKey"]):
		_fail("early-order fixture не оставил задачу полива над обходом")
	for index in stages.size():
		var flag: String = stages[index][1]
		var old_checkpoint := str(state.checkpoint)
		main.get("flashlight").battery = 52.0
		main.get("flashlight").on = false
		_use(interact, ctx, stages[index][0])
		_close_reader(ui)
		if state.task != early_task:
			_fail("ранний обход сменил прежнюю задачу на этапе " + flag)
		if not state.has(flag) or str(state.checkpoint) == old_checkpoint:
			_fail("ранний переход без смены HUD не сохранил " + flag)
		if quest.exclusive_runtime():
			quest.update(SntQuest.SCENE_SECONDS)
		var early_lights: Dictionary = (chapters._light_snap as Dictionary).duplicate(true)
		main.get("lights").setLamp("snt-booth", false)
		main.get("flashlight").battery = 3.0
		chapters.retry()
		if not state.has(flag) or state.task != early_task:
			_fail("retry потерял ранний обход с неизменной задачей: " + flag)
		if absf(float(main.get("flashlight").battery) - 52.0) > 0.1:
			_fail("ранний checkpoint не сохранил фонарь: " + flag)
		var restored_lights: Dictionary = main.get("lights").snapshot()
		if restored_lights["lamps"] != early_lights["lamps"]:
			_fail("ранний checkpoint не сохранил свет: " + flag)
		_check_world(state, nodes, points)

	# Проверка восстановления состояния и доступности.
	state.reset()
	Interact.resync_world(ctx)
	quest.update(12.0)
	_check_world(state, nodes, points)
	if quest.exclusive_runtime() or quest._echo_owned:
		_fail("новая игра сохранила сцену прошлого прохождения")
	# Проверка восстановления состояния и доступности.
	for chapter: String in ["gate", "end"]:
		state.chapter = chapter
		state.set_flag("mill-clue")
		var snap := state.snapshot()
		state.restore(snap)
		Interact.resync_world(ctx)
		quest.update(10.0)
		if state.chapter != chapter or SntQuest.task_for(state) != null:
			_fail("старый " + chapter + " откатился в СНТ")
		for row: Array in stages:
			var id := String(row[0])
			var def := _definition(interact, id)
			if not def.is_empty() and bool((def["when"] as Callable).call(state)):
				_fail("обязательная точка активна после village: " + id)

	# Проверка восстановления состояния и доступности.
	_seed(state)
	state.set_flag("distributor-in")
	state.set_flag("village-done")
	state.set_flag("valya-gone")
	state.set_flag("kovrigin-letter")
	chapters.go("village", true)
	if String(state.task) != String(GameData.texts()["TASKS"]["sntWatch"]):
		_fail("старые флаги ремонта обошли последний обход")
	for flag: String in SntQuest.FLAGS:
		state.set_flag(flag)
	chapters.emit("snt-returned")
	var resumes := false
	for timer: Dictionary in chapters.timers:
		resumes = resumes or String(timer.get("event", "")) == "to-gate"
	if not resumes or not state.has("distributor-in") or not state.has("kovrigin-letter"):
		_fail("старый ремонт после обхода не продолжил главу с сохранением флагов")
	chapters.retry()
	resumes = false
	for timer: Dictionary in chapters.timers:
		resumes = resumes or String(timer.get("event", "")) == "to-gate"
	if not resumes:
		_fail("retry потерял переход старого отремонтированного состояния")
	# Completed legacy saves bypass the new meetings; incomplete ones keep old findings.
	_seed(state)
	state.set_flag("snt-returned")
	chapters.go("village", true)
	if SntQuest.task_for(state) != null or quest.episode.pending_pursuit:
		_fail("старый завершённый обход потребовал новый эпизод")
	if state.has("snt-nina-met"):
		_fail("миграция выдала несыгранные новые встречи")
	_seed(state)
	for old_flag: String in ["snt-watch-read", "snt-yard-seen", "snt-booth-used"]:
		state.set_flag(old_flag)
	chapters.go("village", true)
	if not String(state.task).contains("Нину"):
		_fail("старый незавершённый обход не направил к Нине")
	_use(interact, ctx, "snt-return", true)
	_close_reader(ui)
	if state.has("snt-return-inspected") or quest.episode.pending_pursuit:
		_fail("старый booth-save обошёл новые встречи через snt-return")
	for old_flag: String in ["snt-watch-read", "snt-yard-seen", "snt-booth-used"]:
		if not state.has(old_flag): _fail("миграция потеряла прежнюю находку " + old_flag)
	_use(interact, ctx, "snt-nina-talk")
	if not state.has("snt-nina-met"): _fail("старый booth-save не продолжил новые встречи")
	for row: Array in STAGES:
		var id := String(row[0])
		if not id.begins_with("@") and not _aimed.has(id): _fail("точка ни разу не выбрана реальным find: " + id)
	quest.cancel_runtime()
	ctx["pursuit"].cancel()
	_finish()


func _seed(state: GameState) -> void:
	state.reset()
	state.chapter = "village"
	state.give("shop-key")
	state.give("distributor")
	for flag: String in ["distributor-gone", "water-done", "damper-shut", "banya-written", "bathloft-found", "mill-clue"]:
		state.set_flag(flag)


func _check_world(state: GameState, nodes: Dictionary, points: Dictionary) -> void:
	var changed := state.has("snt-booth-used")
	if (nodes["snt-p01-traces"] as Node3D).visible != changed:
		_fail("следы не совпадают с сохранённым этапом")
	var expected: Vector3 = points["ring_return" if changed else "ring_initial"]
	if (nodes["snt-p01-ring"] as Node3D).position.distance_to(expected) > 0.001:
		_fail("круг не вернулся в сохранённую позу")
	var gate := float(points["gate_open" if changed else "gate_closed"])
	if absf((nodes["snt-p01-gate"] as Node3D).rotation.y - gate) > 0.001:
		_fail("калитка не вернулась в сохранённую позу")


func _definition(interact: Interact, id: String) -> Dictionary:
	for def: Dictionary in interact.list:
		if String(def.get("id", "")) == id:
			return def
	return {}


func _check_story_gates(interact: Interact, state: GameState) -> void:
	for id: String in ["kovrigin-letter", "valya-talk"]:
		var def := _definition(interact, id)
		if def.is_empty():
			_fail("нет прежней сюжетной точки " + id)
		elif bool((def["when"] as Callable).call(state)) != state.has("snt-returned"):
			_fail("письмо/первая встреча с Валей не соответствуют завершению обхода: " + id)


func _use(interact: Interact, ctx: Dictionary, id: String, repeated := false) -> void:
	var state: GameState = ctx["state"]
	var quest: SntQuest = ctx["snt"]
	var pursuit: SntPursuit = ctx["pursuit"]
	if id == "@begin":
		if state.has("snt-pursuit-escaped"): return
		quest.update(0.01)
		if not pursuit.active(): _fail("возвращение к Лебедевым не начало погоню")
		return
	if id == "@escape":
		if state.has("snt-pursuit-escaped"): return
		quest.update(0.01)
		pursuit.update(SntPursuit.WARNING_SECONDS)
		var exit: Vector3 = pursuit.graph["exits"][1]
		ctx["controls"].place(exit.x, exit.y, exit.z, 0.0)
		pursuit.update(0.01)
		return
	var def := _definition(interact, id)
	if def.is_empty():
		_fail("нет точки " + id)
		return
	if not bool((def["when"] as Callable).call(ctx["state"])):
		if not repeated: _fail("точка закрыта на своём этапе: " + id)
		return
	if _aim(interact, ctx, id, def):
		if not interact.use(ctx): _fail("Interact.use отказал для " + id)
		_aimed[id] = true
	else:
		_fail("нет доступного наведения Interact.find на " + id)
		(def["onUse"] as Callable).call(ctx)


func _aim(interact: Interact, ctx: Dictionary, id: String, def: Dictionary) -> bool:
	var at: Vector3 = def["pos"]
	var col: CollisionWorld = ctx["col"]
	var camera: Camera3D = ctx["renderer"].camera
	for distance: float in [0.75, 1.15, 1.65, 2.0]:
		for turn in 24:
			var angle := float(turn) * TAU / 24.0
			var feet := at + Vector3(cos(angle) * distance, 0.0, sin(angle) * distance)
			var floor_hit := col.ray_down(feet.x, 2.6, feet.z, CollisionWorld.ALL_SOLID)
			if floor_hit.is_empty(): continue
			feet.y = float(floor_hit["y"])
			if feet.y > 0.65: continue
			var hit := col.capsule_hit(feet + Vector3.UP * 0.34, feet + Vector3.UP * 1.42, 0.30, CollisionWorld.ALL_SOLID)
			if not hit.is_empty() and float(hit.get("depth", 0.0)) > 0.02: continue
			ctx["controls"].place(feet.x, feet.y, feet.z, 0.0)
			camera.global_position = feet + Vector3.UP * 1.62
			camera.look_at(at)
			var selected: Variant = interact.find(camera, ctx["state"])
			if selected != null and String(selected.get("id", "")) == id: return true
	return false


func _close_reader(ui: Overlays) -> void:
	if ui.reader.open:
		ui.reader.index = ui.reader.pages.size() - 1
		ui.closeReader()


func _cards(main: Node) -> void:
	var ui: Overlays = main.get("ui")
	for frame in 40:
		if ui.card.open:
			ui.advanceCard()
		await process_frame


func _fail(message: String) -> void:
	errors.append(message)


func _finish() -> void:
	for message: String in errors:
		printerr("FAIL test_snt_quest: ", message)
	if errors.is_empty():
		print("test_snt_quest: PASS (16 stages, aim/use, checkpoints/retry, unchanged HUD, legacy saves, pause, quiet scene, spatial World3D)")
	quit(0 if errors.is_empty() else 1)

# Живая склейка main: реальные источники поимки, подпол, стартер и концовки.
extends SceneTree
var errors: Array[String] = []

func _initialize() -> void:
	_run()

func _run() -> void:
	var main: Node = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for _i in 1600:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		printerr("test_capture_recovery: boot timeout")
		quit(1)
		return
	main.call("_start_game")
	var ui: Overlays = main.get("ui")
	for _i in 60:
		if not ui.card.open: break
		ui.advanceCard()
	main.set_process(false)
	var c: Dictionary = main.get("ctx")
	var state: GameState = c["state"]
	var chapters: Chapters = c["chapters"]
	var capture: CaptureRecovery = c["capture"]
	var director: HorrorDirector = c["horror"]
	var cut: Cutscene = c["cutscene"]
	var interact: Interact = c["interact"]
	var ctrl: Player = c["controls"]
	var flash: Flashlight = c["flashlight"]
	var threat: Threat = c["threat"]
	var warm_guard: Dictionary = main.call("_warm_visual_snapshot")
	await main.call("_warm_capture_views")
	_check(bool(main.get_meta("boot_capture_warm_restored", false)) and warm_guard == main.call("_warm_visual_snapshot"), "capture visual warmup changed story/player/pose/material/light or left temporary nodes")
	_phone_race_cases(main)
	state.reset()
	_prepare(main, "dark")
	state.checkpoint = GameState.new().snapshot()
	state.chapterTime = 83.0
	state.task = "Сохранённая текущая задача"
	state.give("car-key").give("chain-key").give("tape-3")
	state.set_flag("water-done").set_flag("gate-open")
	state.evidence = true
	flash.owned = true
	flash.on = false
	flash.battery = 0.0
	var inv := state.inventory.duplicate()
	var flags := state.flags.duplicate()
	var light_snap: Dictionary = c["lights"].snapshot()
	var snap: Variant = state.checkpoint
	ctrl.place(0.0, 0.0, 4.0, 0.0)
	threat.place_at(0.8, 0.0, 4.0)
	threat.grace = 0.0
	state.threatState = "hunt"
	threat.call("_catch", state, ctrl.feet())
	_check(capture.phase == "hit" and state.threatState == "absent", "Threat catch did not hand over before emit")
	_check(state.failCount == 1, "recoverable catch count differs from one")
	_check(not bool(main.call("_runtime_free")), "same frame still permits haunt controllers")
	cut.update(1.5)
	var stopped := cut.time()
	main.call("_set_paused", true)
	cut.update(2.0)
	_check(cut.time() == stopped and not cut.skip(), "pause progressed/skipped capture")
	main.call("_set_paused", false)
	_check(cut.skip(), "safe skip did not finish capture")
	_check(capture.phase == "cellar" and ctrl.feet().distance_to(CaptureRecovery.CELLAR) < 0.01, "capture did not enter playable existing cellar")
	_check(capture.impact_played and c["renderer"].camera.current, "skip missed impact or kept scene camera")
	_check(state.inventory == inv and state.flags == flags and state.evidence, "capture mutated current story/inventory")
	_check(state.chapter == "dark" and state.chapterTime == 83.0 and state.checkpoint == snap, "capture retried or reentered chapter")
	_check(flash.battery == 0.0 and c["lights"].snapshot() == light_snap, "capture replenished battery or story lighting")
	_check(_use(interact, c, "cellar-stash") == false, "recovery allowed evidence/key stash")
	_check(_use(interact, c, "car-drive") == false, "recovery allowed unrelated interaction")
	var recovery_save := state.snapshot()
	var saved_count := state.failCount
	capture.cancel()
	state.restore(recovery_save)
	_check(capture.resume_saved() and capture.phase == "cellar" and state.failCount == saved_count, "saved recovery did not restore cellar without duplicate catch")
	_check(capture.checkpoint.get("task") == "Сохранённая текущая задача", "saved recovery lost its own task checkpoint")
	_check(_use(interact, c, CaptureRecovery.LIGHT_ID), "emergency light action unavailable")
	_check(_use(interact, c, CaptureRecovery.HATCH_ID), "hatch board action unavailable")
	_check(state.inventory == inv and flash.battery == 0.0, "recovery actions give inventory or battery")
	var hatch: Dictionary = {}
	for h: Dictionary in GameData.site()["HATCHES"]:
		if h["id"] == "hatch-cellar": hatch = h
	main.call("_use_hatch", {"hatch": hatch, "down": false})
	main.call("_set_paused", true)
	await create_timer(0.65).timeout
	_check(capture.phase == "exit" and ctrl.feet().y < 0.0 and bool(main.get("busy")), "hatch fade/teleport advanced while paused")
	main.call("_set_paused", false)
	await create_timer(1.2).timeout
	_check(not capture.active() and state.recovery_completed_count == 1 and not bool(main.get("busy")), "exit did not finish after fade")
	_check(state.task == "Сохранённая текущая задача" and state.inventory == inv and state.flags == flags, "exit did not resume current task/flags")
	# Второй источник: StreetStalk должен отдать echo без _apply после catch.
	_prepare(main, "village")
	var stalk: StreetStalk = c["stalk"]
	stalk.begin(true)
	stalk.call("_catch")
	_check(capture.phase == "hit" and not stalk.active(), "street source catch not exclusive")
	var actor: Node3D = c["actors"].get_actor("echo")
	var owned_pos := actor.position
	stalk.update(0.05)
	_check(actor.position == owned_pos, "street reapplied pose after synchronous catch")
	cut.update(1.5)
	cut.skip()
	_check(bool(state.recovery.get("hatch_free", false)), "repeat recovery did not shorten the two actions")
	capture.begin_exit()
	capture.finish_exit()
	# Стартер обеих веток: старый callback не должен уехать из подпола.
	for ch: String in ["dark", "gate"]:
		_prepare(main, ch)
		state.set_flag("tank-full").set_flag("gate-open").set_flag("bag-packed")
		state.set_flag("water-done").set_flag("valya-gone").set_flag("kovrigin-letter")
		state.give("car-key")
		_check(_use(interact, c, "car-drive"), "starter point unavailable for " + ch)
		_check(state.has("starter-on"), "starter generation missing for " + ch)
		_check(capture.begin("dark"), "capture did not interrupt starter for " + ch)
		cut.update(1.5)
		cut.skip()
		director.update(5.0)
		_check(not state.has("drive-played") and state.chapter == ch and not state.has("starter-on"), "old starter drove from cellar for " + ch)
		capture.cancel()
	_prepare(main, "gate")
	state.failCount = 0
	state.set_flag("gate-open").set_flag("bag-packed")
	_check(capture.begin("gate"), "recoverable gate catch failed")
	cut.update(1.5)
	cut.skip()
	capture.begin_exit()
	capture.finish_exit()
	chapters.update(0.05)
	_check(not threat.final_mode and state.has("gate-open"), "gate chase began in cellar or chain reset")
	ctrl.place(0.0, 0.0, 4.0, 0.0)
	chapters.update(0.05)
	_check(threat.final_mode and state.threatState == "hunt" and threat.grace >= 7.9, "gate chase did not resume outside after begin_final with grace")
	# Глобальные два провала терминальны у ворот; терминальная поимка не прибавляет счётчик.
	_prepare(main, "gate")
	state.failCount = 2
	chapters.emit("caught")
	_check(capture.terminal and state.failCount == 2, "gate terminal threshold/count changed")
	cut.update(1.5)
	cut.skip()
	_check(state.chapter == "end" and state.ending == "caught" and state.recovery.is_empty(), "gate terminal catch did not end with caught")
	# Все пять прежних исходов остаются в таблице и выборе сюжета.
	var endings: Dictionary = GameData.texts()["ENDINGS"]
	for id: String in ["alone", "morning", "kovrigin", "quiet", "caught"]:
		_check(endings.has(id), "ending removed: " + id)
	state.reset()
	_check(String(chapters.call("_ending_of", state)) == "alone", "alone ending selection changed")
	state.evidence = true
	_check(String(chapters.call("_ending_of", state)) == "morning", "morning ending selection changed")
	state.set_flag("kovrigin-letter").give("kovrigin-tapes")
	_check(String(chapters.call("_ending_of", state)) == "kovrigin", "letter ending selection changed")
	for ending: String in ["alone", "morning", "kovrigin", "quiet"]:
		_prepare(main, "gate")
		state.flags.clear()
		state.inventory.clear()
		state.evidence = ending == "morning"
		if ending == "kovrigin": state.set_flag("kovrigin-letter").give("kovrigin-tapes")
		if ending == "quiet": state.set_flag("hatch-sealed")
		chapters.call("_gate_drive", c, null)
		if cut.playing:
			cut.update(1.5)
			cut.skip()
		_check(state.ending == ending and state.chapter == "end", "actual ending path changed for " + ending)
	_check(int(GameState.CLOCK["gate"]) == 25 * 3600 + 50 * 60 and int(GameState.CLOCK["end"]) == 26 * 3600 + 30 * 60, "01:50/02:30 clock contract changed")
	main.call("_cancel_horror_runtime")
	c.clear()
	main.queue_free()
	await process_frame
	await process_frame
	if errors.is_empty():
		print("test_capture_recovery: PASS (sources, pause/skip, cellar actions, empty battery, starter/phone races, terminal gate, five endings)")
		call_deferred("quit", 0)
	else:
		for error: String in errors: printerr(error)
		call_deferred("quit", 1)

func _prepare(main: Node, chapter: String) -> void:
	main.call("_cancel_horror_runtime")
	var c: Dictionary = main.get("ctx")
	var state: GameState = c["state"]
	state.chapter = chapter
	state.ending = null
	state.threatState = "patrol"
	var chapters: Chapters = c["chapters"]
	chapters.current = (chapters.get("_defs") as Dictionary)[chapter]
	chapters.timers.clear()
	main.set("running", true)
	main.set("paused", false)
	c["cutscene"].paused = false
	c["controls"].enabled = true
	var ui: Overlays = c["ui"]
	ui.card.queue.clear()
	ui.card.onDone = Callable()
	ui.advanceCard()

func _use(interact: Interact, c: Dictionary, id: String) -> bool:
	for point: Dictionary in interact.list:
		if point["id"] == id:
			interact.target = point
			return interact.use(c)
	return false

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)


func _phone_race_cases(main: Node) -> void:
	var c: Dictionary = main.get("ctx")
	var state: GameState = c["state"]
	var phone: Phone = main.get("phone")
	var audio: GameAudio = main.get("audio")
	var capture: CaptureRecovery = c["capture"]
	var director: HorrorDirector = c["horror"]
	for stage: String in ["dial", "talking"]:
		_prepare(main, "dark")
		state.callsMade.clear()
		phone.set("_talking", false)
		phone.onDialogueEnd = Callable()
		main.call("_ctx_open_phone")
		var picked := false
		for i in phone.options.size():
			if String(phone.options[i].get("id", "")) == "hospital":
				phone.sel = i
				phone.pick()
				picked = true
				break
		_check(picked, "phone race preparation cannot dial hospital")
		if stage == "talking":
			audio.call("_tick_timers", 2.0)
			director.update(2.0)
			_check(phone.talking, "phone race preparation did not enter dialogue")
		_check(capture.begin("dark"), "phone race could not start actual capture")
		# Deliver timers through their actual schedulers, then complete stale lines.
		audio.call("_tick_timers", 2.0)
		director.update(2.0)
		for _i in 80: phone.skipLine()
		_check(not state.callsMade.has("hospital"), "PHONE_RACE: " + stage + " callback mutated callsMade during capture")
		_check(not phone.open and not phone.talking, "PHONE_RACE: " + stage + " left phone active during capture")
		_check(not c["controls"].enabled, "PHONE_RACE: stale callback restored controls during hit")
	for action: String in ["capture", "chapter", "retry", "newgame"]:
		_prepare(main, "dark")
		state.set_flag("phone-callback-leak", false)
		var lines: Array = [["note", "Проверка прерванной реплики."]]
		main.call("_ctx_play_dialogue", lines, func() -> void: state.set_flag("phone-callback-leak"))
		var stale := phone.onDialogueEnd
		if action == "capture":
			capture.begin("dark")
		elif action == "chapter":
			(c["chapters"] as Chapters).go("dark", true)
		elif action == "retry":
			state.checkpoint = state.snapshot()
			(c["chapters"] as Chapters).retry()
		else:
			main.call("_cancel_horror_runtime")
			state.reset()
		if stale.is_valid(): stale.call()
		_check(not state.has("phone-callback-leak"), "PHONE_RACE: old dialogue callback survived " + action)
	_prepare(main, "dark")
	state.callsMade.clear()
	main.call("_ctx_open_phone")
	for i in phone.options.size():
		if String(phone.options[i].get("id", "")) == "hospital":
			phone.sel = i
			phone.pick()
			break
	director.update(2.0, true)
	_check(not phone.talking, "phone dial advanced while paused")
	director.update(2.0)
	_check(phone.talking, "current dial never began after pause")
	for _i in 80: phone.skipLine()
	_check(state.callsMade.has("hospital"), "current phone completion no longer records callsMade")
	state.set_flag("phone-callback-leak", false)
	main.call("_ctx_play_dialogue", [["note", "Действующий разговор."]], func() -> void: state.set_flag("phone-callback-leak"))
	_check(c["controls"].frozen, "current frozen dialogue no longer locks movement")
	phone.skipLine()
	_check(state.has("phone-callback-leak") and not c["controls"].frozen, "current dialogue failed completion/unfreeze")
	main.call("_ctx_open_phone")
	var old_pick := phone.onPick
	capture.begin("dark")
	if old_pick.is_valid(): old_pick.call({"id": "hospital"})
	_check(not phone.open and not phone.talking and not c["controls"].enabled, "old menu callback reopened phone/restored controls during capture")
	main.call("_cancel_horror_runtime")

# Real ending handlers after the new episode; no direct end() shortcuts.
extends SceneTree

var errors: Array[String] = []
var main: Node
var c: Dictionary
var state: GameState
var chapters: Chapters
var ui: Overlays
var interaction: Interact

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	main = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for frame in 1800:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		printerr("FAIL test_episode_endings: boot")
		quit(1)
		return
	main.call("_start_game")
	ui = main.get("ui")
	for frame in 40:
		if ui.card.open: ui.advanceCard()
		await process_frame
	main.set_process(false)
	c = main.get("ctx")
	state = c["state"]
	chapters = c["chapters"]
	interaction = c["interact"]
	c["scaresOn"] = func() -> bool: return false
	for expected: String in ["alone", "morning", "kovrigin"]:
		_seed("gate", expected, false)
		_check(chapters._ending_of(state) == expected, expected + ": old selection changed")
		# Every partial episode snapshot must preserve the original ending decision.
		for flag: String in SntQuest.FLAGS:
			state.set_flag(flag)
			_check(chapters._ending_of(state) == expected, expected + ": selection changed by " + flag)
		for flag: String in SntEpisode.PROGRESS:
			state.set_flag(flag)
			_check(chapters._ending_of(state) == expected, expected + ": selection changed by " + flag)
		state.set_flag("gate-open", false)
		_check(not _available("car-drive"), expected + ": closed gate allows driving")
		state.set_flag("gate-open")
		_check(_available("car-drive"), expected + ": prepared car is unavailable")
		_use_car(expected)
		_tick_to_end()
		_check_ending(expected)

	# Quiet keeps precedence over all evidence, including the new investigation.
	_seed("gate", "kovrigin", true)
	state.set_flag("saw-him-sleeping")
	var seal := _definition("seal-hatch")
	_check(_available("seal-hatch"), "quiet: sealing interaction unavailable")
	interaction.target = seal
	_check(interaction.use(c), "quiet: seal-hatch use failed")
	_check(state.has("hatch-sealed"), "quiet: sealing did not persist")
	_use_car("quiet")
	_tick_to_end()
	_check_ending("quiet")
	_check(not c["cutscene"].playing, "quiet: departure cutscene started")

	# The old third gate capture must remain terminal, unlike external Snt capture.
	_seed("gate", "kovrigin", true)
	state.failCount = 2
	chapters.emit("caught")
	_check(c["capture"].active() and c["capture"].terminal, "caught: old terminal capture did not begin")
	_check(String(state.recovery.get("kind", "")) == "gate", "caught: external capture profile leaked")
	_tick_to_end()
	_check_ending("caught")
	_check(state.recovery.is_empty(), "caught: terminal ending left cellar recovery")
	_check(not c["cutscene"].playing, "caught: departure cutscene started")

	# Street departure remains legal before any new episode progress.
	_seed("street", "alone", false)
	_check(not state.has("snt-returned"), "early: fixture accidentally completed episode")
	_check(_available("car-drive"), "early: street departure blocked")
	_use_car("early")
	_tick_to_end()
	_check_ending("alone")
	_check(not state.has("snt-returned"), "early: departure silently completed episode")
	for error in errors: printerr("FAIL ", error)
	print("test_episode_endings: %s five_endings=5 early_departure=1" % ("PASS" if errors.is_empty() else "FAIL"))
	quit(0 if errors.is_empty() else 1)

func _seed(chapter: String, expected: String, episode: bool) -> void:
	c["pursuit"].cancel()
	c["capture"].cancel()
	c["cutscene"].cancel()
	ui.card.open = false
	ui.card.queue.clear()
	ui.card.onDone = Callable()
	state.reset()
	state.evidence = expected != "alone"
	state.give("flashlight")
	state.give("car-key")
	state.give("chain-key")
	state.set_flag("tank-full")
	if chapter == "gate":
		for flag: String in ["water-done", "valya-gone", "boarded-tapes", "banya-written", "bathloft-found", "mill-clue", "bag-packed", "gate-open"]:
			state.set_flag(flag)
	if expected == "kovrigin":
		state.set_flag("kovrigin-letter")
		# A letter without tapes still follows the original evidence branch.
		_check(chapters._ending_of(state) == "morning", "letter alone unexpectedly chooses kovrigin")
		state.give("kovrigin-tapes")
	if episode:
		for flag: String in SntQuest.FLAGS: state.set_flag(flag)
		for flag: String in SntEpisode.PROGRESS: state.set_flag(flag)
	chapters.go(chapter, true)
	if chapter == "gate":
		state.set_flag("gate-open")
		(c["setGate"] as Callable).call(true)
	state.threatState = "absent"
	c["controls"].enabled = true
	c["controls"].frozen = false

func _use_car(label: String) -> void:
	var p: Player = c["controls"]
	var anchor := Vector3(1.1, 1.0, -3.6)
	var aimed := false
	var last_id := "null"
	for radius: float in [1.0,1.4,1.8,2.1]:
		if aimed: break
		for index in 24:
			var angle := TAU * float(index) / 24.0
			var feet := Vector3(anchor.x + cos(angle)*radius,0.02,anchor.z+sin(angle)*radius)
			if not (c["col"] as CollisionWorld).capsule_hit(feet+Vector3(0,.35,0),feet+Vector3(0,1.45,0),.3,CollisionWorld.ALL_SOLID).is_empty(): continue
			p.place(feet.x,feet.y,feet.z,0.0)
			var delta: Vector3 = anchor - p.eyes()
			p.yaw = atan2(-delta.x, -delta.z)
			p.yaw_target = p.yaw
			p.pitch = atan2(delta.y, Vector2(delta.x, delta.z).length())
			p.pitch_target = p.pitch
			p.call("_apply_camera")
			var found: Variant = interaction.find(main.get("render_chain").camera, state)
			last_id = String(found.get("id", "")) if found is Dictionary else "null"
			if last_id == "car-drive":
				aimed = true
				break
	_check(aimed, label + ": real aim does not select car-drive; got " + last_id)
	if not aimed: return
	_check(interaction.use(c), label + ": car interaction rejected")
	_check(state.has("starter-on"), label + ": ignition did not start")

func _tick_to_end() -> void:
	for tick in 400:
		if state.chapter == "end": return
		c["horror"].update(0.05, false)
		if c["cutscene"].playing: c["cutscene"].update(0.05)
	_check(false, "ending timed out in " + state.chapter)

func _check_ending(expected: String) -> void:
	_check(state.chapter == "end" and str(state.ending) == expected, "expected " + expected + ", got " + str(state.ending))
	var pages: Array = GameData.texts()["ENDINGS"][expected]["pages"]
	_check(ui.card.open, expected + ": no ending card")
	_check(String(ui.get("_card_text").text) == String(pages[0]), expected + ": wrong first ending page")
	_check(ui.card.queue == pages.slice(1), expected + ": incomplete ending pages")
	if state.chapter != "end": return
	chapters.emit("drive")
	_check(str(state.ending) == expected and not c["cutscene"].playing, expected + ": delayed drive overwrote ending")

func _definition(id: String) -> Dictionary:
	for definition: Dictionary in interaction.list:
		if String(definition.get("id", "")) == id: return definition
	return {}

func _available(id: String) -> bool:
	var definition := _definition(id)
	return not definition.is_empty() and bool((definition["when"] as Callable).call(state))

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

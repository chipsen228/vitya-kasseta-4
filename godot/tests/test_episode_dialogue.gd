# Live Phone/main dialogue isolation, without synchronous completion callbacks.
extends SceneTree

var errors: Array[String] = []
var main: Node
var c: Dictionary
var state: GameState
var phone: Phone
var player: Player
var ui: Overlays
var audio: GameAudio
var director: HorrorDirector
var delayed := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	main = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for frame in 1800:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		printerr("FAIL test_episode_dialogue: boot")
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
	phone = main.get("phone")
	player = c["controls"]
	audio = c["audio"]
	director = c["horror"]
	c["scaresOn"] = func() -> bool: return true
	for kind: String in ["haunt","startle","threshold"]:
		_test_live_cancel(kind)
	for person: String in ["nina", "semyon"]:
		await _run_conversation(person)
	await _test_self_voice_pause()
	_test_walk_timing()
	main.call("_cancel_dialogue_runtime")
	c["threat"].end_final()
	audio.clear_spatial()
	Input.action_release("move_forward")
	for error in errors: printerr("FAIL ", error)
	print("test_episode_dialogue: %s live_conversations=2 pause_input=3 self_voice=1 sound_slots=6 walk_storm=2.4s" % ("PASS" if errors.is_empty() else "FAIL"))
	quit(0 if errors.is_empty() else 1)

func _test_walk_timing() -> void:
	_seed()
	var chapters: Chapters = c["chapters"]
	chapters.go("gate",true)
	state.set_flag("bag-packed")
	state.threatState = "absent"
	var handlers: Dictionary = chapters.current["on"]
	var original_storm: Callable = handlers["porch-storm"]
	var marker := {"fired":false,"elapsed":0.0,"at":-1.0}
	handlers["porch-storm"] = func(context: Dictionary, payload: Variant) -> void:
		marker["fired"] = true
		marker["at"] = marker["elapsed"]
		original_storm.call(context,payload)
	# The production bagged event starts FINAL_AT_GATE through real Phone and
	# schedules the existing storm. Walking narration must not stall chapters.
	chapters.emit("bagged")
	_check(phone.talking and state.has("final-said"), "walk narration: FINAL_AT_GATE did not start")
	_check(not bool(main.get("_dialogue_frozen")) and not player.frozen, "walk narration: movement incorrectly frozen")
	for tick in 50:
		marker["elapsed"] = float(tick + 1) * 0.05
		main.call("_process",0.05)
	handlers["porch-storm"] = original_storm
	_check(phone.talking and not bool(main.get("_dialogue_frozen")), "walk narration: real monologue ended before storm verification")
	_check(bool(marker["fired"]) and float(marker["at"]) >= 2.35 and float(marker["at"]) <= 2.5, "walk narration: porch-storm timer stalled during FINAL_AT_GATE")

func _run_conversation(person: String) -> void:
	_seed()
	var id := "snt-" + person + "-talk"
	var flag := "snt-" + person + "-met"
	var definition := _definition(id)
	_check(not definition.is_empty(), "missing " + id)
	if definition.is_empty(): return
	_check(bool((definition["when"] as Callable).call(state)), id + ": unavailable")
	# Production Snt interaction -> unmodified c.playDialogue -> real Phone.
	(definition["onUse"] as Callable).call(c)
	_check(phone.talking and phone.dlgIndex == 0, person + ": real Phone did not start")
	_check(player.frozen and bool(main.get("_dialogue_frozen")), person + ": dialogue did not freeze movement")
	_check(not state.has(flag), person + ": unfinished conversation granted progress")
	_check(not bool(main.call("_runtime_free")), person + ": threat runtime allowed during speech")
	var first_subtitle := String(ui.get("_subtitle").text)
	_check(int(ui.get("_subPrio")) == GameVoice.PRIO_LINE, person + ": speech subtitle lost priority")
	ui.say("test lower-priority noise", 0.2, GameVoice.PRIO_VITYA)
	_check(String(ui.get("_subtitle").text) == first_subtitle, person + ": random line replaced speech")

	# In-memory sound isolates pool priority/pause from optional paid recordings.
	# Phone timing, subtitle callbacks and completion are the real dialogue.
	audio.stop_spatial_owner("dialogue:spatial")
	var speech_at: Vector3 = phone.spatial_dialogue_source.call(person)
	_check(speech_at.is_finite(), person + ": no physical voice source")
	var sample := _silent_sample()
	_check(audio.spatial_stream(sample, speech_at, 0.01, 24.0, "dialogue:spatial", 4), person + ": speech source rejected")
	var speech_slot := audio._spatial_owners.find("dialogue:spatial")
	_check(speech_slot >= GameAudio.SPATIAL_LOOP_VOICES, person + ": speech consumed an ambient slot")
	if speech_slot < 0: return
	for index in 12:
		audio.spatial_stream(sample, player.feet(), 0.01, 12.0, "test-low-%d" % index, 0)
	_check(audio._spatial_owners[speech_slot] == "dialogue:spatial" and audio._spatial_priorities[speech_slot] == 4, person + ": low sounds stole speech")
	_check(audio._spatial_pool.size() == 8, person + ": source pool size changed")
	_check(audio._spatial_owners[0] == "" and audio._spatial_owners[1] == "", person + ": one-shots consumed ambient channels")
	# Native 3D playback starts on physics ticks; setters before the first tick
	# cannot exercise playback pause. Keep the real pool and all pause asserts.
	await physics_frame
	await physics_frame
	_check(audio._spatial_pool[speech_slot].playing, person + ": speech fixture never started native playback")

	var threat: Variant = c["threat"]
	var feet := player.feet()
	_check(threat.begin_final(feet, feet + Vector3(0,0,4),3.0), person + ": nearby threat fixture failed")
	threat.place_at(feet.x + 0.45,feet.y,feet.z)
	var threat_before: Vector3 = threat.pos
	var player_before := Vector2(feet.x,feet.z)
	var seen_before := state.horror_seen.duplicate(true)
	var clock_before := phone.dlgTimer
	var index_before := phone.dlgIndex
	director.cooldown = 13.0
	delayed = false
	director.after(0.1,func() -> void: delayed = true)
	c["chapters"].timer("village-remind",0.01)
	Input.action_press("move_forward")
	for tick in 6: main.call("_process",0.05)
	Input.action_release("move_forward")
	_check(phone.talking and phone.dlgIndex == index_before and phone.dlgTimer < clock_before, person + ": live speech did not advance normally")
	_check(Vector2(player.feet().x,player.feet().z).distance_to(player_before) < 0.01, person + ": frozen player moved")
	_check(threat.pos == threat_before, person + ": nearby threat moved during dialogue")
	_check(not c["capture"].active() and state.recovery.is_empty(), person + ": captured during dialogue")
	_check(String(ui.get("_subtitle").text) == first_subtitle, person + ": chapter reminder overwrote speech")
	var reminder_waiting := false
	for timer: Dictionary in c["chapters"].timers:
		if String(timer.get("event","")) == "village-remind" and is_equal_approx(float(timer["t"]),0.01): reminder_waiting = true
	_check(reminder_waiting, person + ": chapter reminder advanced during speech")
	_check(not delayed and is_equal_approx(director.cooldown,13.0), person + ": horror scheduler advanced during dialogue")
	_check(state.horror_seen == seen_before and not director.thresholds.active(), person + ": scare started during dialogue")
	_check(not audio._spatial_pool[speech_slot].stream_paused, person + ": normal speech audio paused")
	_check(audio._spatial_pool[speech_slot].global_position == speech_at, person + ": speech source followed the player")

	# Real Escape input pauses timing/audio and blocks E/advance skipping.
	_input("pause")
	_check(bool(main.get("paused")), person + ": pause input ignored during speech")
	var paused_clock := phone.dlgTimer
	var paused_index := phone.dlgIndex
	_input("interact")
	_input("advance")
	for tick in 10: main.call("_process",0.05)
	await physics_frame
	await physics_frame
	_check(phone.dlgIndex == paused_index and is_equal_approx(phone.dlgTimer,paused_clock), person + ": pause advanced/skipped a line")
	_check(audio._spatial_pool[speech_slot].stream_paused, person + ": speech source plays in pause")
	_check(threat.pos == threat_before and not c["capture"].active() and not delayed, person + ": pause advanced danger")
	_input("pause")
	_check(not bool(main.get("paused")), person + ": second Escape did not resume")
	main.call("_process",0.05)
	await physics_frame
	await physics_frame
	_check(phone.dlgTimer < paused_clock and player.frozen, person + ": resume lost dialogue timing/freeze")
	_check(not audio._spatial_pool[speech_slot].stream_paused, person + ": speech source did not resume")

	# The production input completion callback grants progress, then danger resumes.
	for line in 64:
		if not phone.talking: break
		_input("advance")
	_check(not phone.talking and state.has(flag), person + ": completed dialogue failed to grant progress")
	_check(not player.frozen and not bool(main.get("_dialogue_frozen")), person + ": dialogue left controls frozen")
	_check(bool(main.call("_runtime_free")), person + ": threat runtime did not resume")
	threat.place_at(feet.x + 3.0,feet.y,feet.z)
	var resume_at: Vector3 = threat.pos
	for tick in 4: main.call("_process",0.05)
	_check(threat.pos.distance_to(resume_at) > 0.02, person + ": threat remains stopped after dialogue")
	_check(delayed and director.cooldown < 13.0, person + ": horror scheduler remains stopped after dialogue")
	_check(not audio.spatial_owner_active("dialogue:spatial"), person + ": completed voice remained active")
	threat.end_final()

func _test_self_voice_pause() -> void:
	_seed()
	var voice: GameVoice = c["voice"]
	var definition := _definition("snt-nina-talk")
	(definition["onUse"] as Callable).call(c)
	_check(phone.talking, "self voice: Nina conversation did not start")
	# Read the current authored line, including the corrected office-journal text.
	# Do not substitute a stream: this checks the shipped manifest and real voice.
	for line in 16:
		if not phone.talking: break
		if String(phone.dialogue[phone.dlgIndex][0]) == "self": break
		_input("advance")
	if not phone.talking or String(phone.dialogue[phone.dlgIndex][0]) != "self":
		_check(false, "self voice: no protagonist line in Nina conversation")
		return
	var text := String(phone.dialogue[phone.dlgIndex][1])
	var authored: Array = SntEpisode.data()["dialogues"]["nina_first"]
	_check(text == String(authored[1][1]), "self voice: wrong authored protagonist line")
	var key := GameVoice.line_key("self",text)
	var entry: Dictionary = voice._lines.get(key,{})
	_check(voice.enabled and not entry.is_empty(), "self voice: current authored line missing from voice manifest")
	_check(String(entry.get("ch","")) == GameVoice.CH_SELF, "self voice: protagonist line routed to wrong channel")
	var source: AudioStreamPlayer = voice._players.get(GameVoice.CH_SELF)
	if source == null or entry.is_empty():
		_check(false, "self voice: no production AudioStreamPlayer/recording")
		return
	var dt := 1.0 / float(Engine.physics_ticks_per_second)
	for frame in 4:
		await physics_frame
		main.call("_process",dt)
	_check(source.playing and source.stream != null and not source.stream_paused, "self voice: real recording did not start")
	var playing_at := source.get_playback_position()
	for frame in 8:
		await physics_frame
		main.call("_process",dt)
	_check(source.get_playback_position() > playing_at + 0.01, "self voice: playback did not advance before pause")

	_input("pause")
	await physics_frame
	await physics_frame
	var paused_at := source.get_playback_position()
	var paused_clock := phone.dlgTimer
	var paused_index := phone.dlgIndex
	_check(bool(main.get("paused")) and player.frozen, "self voice: Escape did not pause stationary dialogue")
	_check(source.stream_paused, "self voice: non-spatial channel was not paused")
	_input("interact")
	_input("advance")
	for frame in 12:
		await physics_frame
		main.call("_process",dt)
	_check(phone.talking and phone.dlgIndex == paused_index and is_equal_approx(phone.dlgTimer,paused_clock), "self voice: pause advanced/skipped protagonist line")
	_check(absf(source.get_playback_position() - paused_at) <= 0.025, "self voice: audio playback advanced in pause")
	_check(source.stream_paused and not state.has("snt-nina-met"), "self voice: pause completed/stopped the unfinished dialogue")

	_input("pause")
	for frame in 10:
		await physics_frame
		main.call("_process",dt)
	_check(not bool(main.get("paused")) and phone.talking and player.frozen, "self voice: Escape did not resume the same stationary dialogue")
	_check(not source.stream_paused and source.playing, "self voice: non-spatial channel did not resume")
	_check(phone.dlgIndex == paused_index and phone.dlgTimer < paused_clock, "self voice: line timer did not resume in place")
	_check(source.get_playback_position() > paused_at + 0.01, "self voice: audio did not continue after resume")

	# A new line requested while paused must stay pending. Stopping dialogue
	# cancels that request, so resume cannot start an abandoned voice afterward.
	_input("pause")
	voice.stop_dialogue()
	var queued_seconds := voice.play_dialogue_line("self",text)
	_check(queued_seconds > 0.0, "self voice: queued line lost its recording duration")
	await physics_frame
	await physics_frame
	_check(not source.playing, "self voice: new voice started while paused")
	voice.stop_dialogue()
	_input("pause")
	await physics_frame
	await physics_frame
	_check(not source.playing, "self voice: cancelled pending voice started on resume")
	main.call("_cancel_dialogue_runtime")

func _test_live_cancel(kind: String) -> void:
	_seed()
	var legacy_echo: Node3D = c["actors"].get_actor("echo")
	var echo_seed_visible := legacy_echo.visible if legacy_echo != null else false
	_check(legacy_echo != null and not echo_seed_visible, kind + ": legacy echo already visible after seed")
	director.cooldown = 0.0
	state.horror_seen["test-dialogue-preserved"] = true
	state.threatState = "absent"
	var started := false
	if kind == "haunt":
		started = c["haunt"].force("greenhouse-out")
	elif kind == "startle":
		started = c["startle"].force("stop-bench")
	else:
		# A physical threshold on the already checked straight village road.
		var e: Dictionary = ThresholdScares.EVENTS[11].duplicate(true)
		e["id"] = "test-dialogue-live-threshold"
		e["from"] = Vector3(12.2,0,-42.3)
		e["to"] = Vector3(12.2,0,-40.3)
		e["face"] = false
		e["sound_only"] = false
		var delta: Vector3 = Vector3(e["from"]) + Vector3.UP * 1.45 - player.eyes()
		player.yaw = atan2(-delta.x,-delta.z)
		player.yaw_target = player.yaw
		player.pitch = atan2(delta.y,Vector2(delta.x,delta.z).length())
		player.pitch_target = player.pitch
		player.call("_apply_camera")
		started = director.thresholds._begin(e)
	_check(started, kind + ": live visual fixture did not start")
	var echo_active_visible := legacy_echo.visible if legacy_echo != null else false
	if kind == "threshold":
		_check(director.thresholds._actor == c["episodeActors"], "threshold fixture used legacy fallback instead of native walker")
		_check(echo_active_visible == echo_seed_visible, "native threshold changed legacy echo visibility before dialogue")
	var history := state.horror_seen.duplicate(true)
	var definition := _definition("snt-nina-talk")
	(definition["onUse"] as Callable).call(c)
	_check(phone.talking, kind + ": production dialogue did not start")
	_check(c["haunt"].point == null and String(c["startle"].get("_live")) == "", kind + ": previous figure survived dialogue start")
	_check(not director.thresholds.active() and director._live.is_empty(), kind + ": active scare survived dialogue start")
	var echo: Node3D = c["actors"].get_actor("echo")
	var walker: Node3D = c["episodeActors"].figure("walker")
	var face: Node3D = c["episodeActors"].figure("window_face")
	_check(echo != null and not echo.visible, kind + ": echo still visible (seed=%s active=%s)" % [echo_seed_visible,echo_active_visible])
	_check(walker != null and not walker.visible and face != null and not face.visible, kind + ": threshold figure still visible")
	_check(state.horror_seen == history, kind + ": cancelling scene lost once-only history")

func _seed() -> void:
	main.call("_set_paused",false)
	main.call("_cancel_dialogue_runtime")
	c["pursuit"].cancel()
	c["capture"].cancel()
	c["threat"].end_final()
	c["stalk"].finish()
	audio.clear_spatial()
	state.reset()
	# The post-mill episode follows taking the distributor; otherwise village
	# entry deliberately starts the earlier street stalk and its shared echo.
	state.give("distributor")
	for flag: String in ["water-done","banya-written","banya-hot","bathloft-found","mill-clue","snt-watch-read","snt-yard-seen"]:
		state.set_flag(flag)
	c["chapters"].go("village",true)
	state.threatState = "hunt"
	player.enabled = true
	player.frozen = false
	player.place(12.2,0.02,-38.3,0.0)
	player.velocity = Vector3.ZERO
	director.cooldown = 13.0

func _silent_sample() -> AudioStreamWAV:
	var sample := AudioStreamWAV.new()
	sample.format = AudioStreamWAV.FORMAT_8_BITS
	sample.mix_rate = 8000
	var samples := PackedByteArray()
	samples.resize(80000)
	samples.fill(128)
	sample.data = samples
	sample.loop_mode = AudioStreamWAV.LOOP_FORWARD
	sample.loop_end = samples.size()
	return sample

func _definition(id: String) -> Dictionary:
	for definition: Dictionary in (c["interact"] as Interact).list:
		if String(definition.get("id","")) == id: return definition
	return {}

func _input(action: String) -> void:
	var event := InputEventAction.new()
	event.action = action
	event.pressed = true
	main.call("_unhandled_input",event)

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

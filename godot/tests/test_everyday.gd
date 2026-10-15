extends SceneTree

class FakeControls extends RefCounted:
	var at := Vector3(0, 0, 4)
	func feet() -> Vector3: return at

class FakeUi extends RefCounted:
	var on_close := Callable()
	var reader_title := "Предыдущая сюжетная записка"
	var rendered_title := ""
	func say(_text: String, _seconds: float) -> void: pass
	func setReaderTitle(title: String) -> void: reader_title = title
	func openReader(_title: String, _pages: Array, done: Callable) -> void:
		rendered_title = reader_title
		on_close = done
	func finish() -> void:
		if on_close.is_valid(): on_close.call()
		on_close = Callable()

class FakeExclusive extends RefCounted:
	var on := false
	func exclusive_runtime() -> bool: return on
	func exclusive() -> bool: return on

var errors: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var world_root := Node3D.new()
	root.add_child(world_root)
	var camera := Camera3D.new()
	world_root.add_child(camera)
	camera.current = true
	var audio := GameAudio.new()
	root.add_child(audio)
	await process_frame
	audio.bind_spatial_world(world_root)
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var world := EverydayWorld.build(world_root, mats, col, {"snt": {"enabled": true}})
	var s := GameState.new()
	s.chapter = "arrive"
	s.task = "Задача до визита"
	s.give("test-item")
	s.checkpoint = s.snapshot()
	var controls := FakeControls.new()
	var ui := FakeUi.new()
	var exclusive := FakeExclusive.new()
	var c := {"state": s, "col": col, "controls": controls, "ui": ui, "audio": audio,
		"renderer": {"camera": camera}, "snt": exclusive, "horror": exclusive}
	var everyday := EverydayInteractions.new(c, world)
	c["everyday"] = everyday
	var interact := Interact.new()
	interact.occluder = col
	interact.ctx_ref = c
	everyday.register(interact)
	_check(everyday.definitions.size() == 13 and interact.list.size() == 13, "all 13 descriptors")
	for target: Dictionary in interact.list:
		var d: Dictionary = everyday.definitions[target["id"]]
		_check(String(target.get("los_ignore_blocker", "")) == String(d["blocker"]) if String(d["kind"]) == "gate" \
			else not target.has("los_ignore_blocker"), "LOS ignores something other than self gate " + String(d["id"]))
	_check(col.box_count(CollisionWorld.SET_OVERLAY) == 5, "five named overlay gate blockers")
	for set_id in [CollisionWorld.SET_STATIC, CollisionWorld.SET_BLOCKERS, CollisionWorld.SET_PROPS]:
		_check(col.box_count(set_id) == 0, "everyday changed parity collision set")
	var original_checkpoint := str(s.checkpoint)
	var original_inventory := s.inventory.duplicate()
	for id: String in everyday.definitions:
		var d: Dictionary = everyday.definitions[id]
		_check((d["owner"] as Node3D).get_child_count() > 0, "unmodelled " + id)
		_check(everyday.use(id), "early use " + id)
		if String(d["kind"]) == "notice":
			_check(ui.rendered_title == String(d["title"]), "notice inherited another reader title " + id)
			_check(not s.has(d["flag"]), "notice flag before close")
			ui.finish()
		elif String(d["kind"]) == "radio":
			everyday.update(4.0)
			everyday.update(4.0)
		else:
			_check(not everyday.use(id), "repeat started second animation " + id)
			if String(d["flag"]) != "": _check(not s.has(d["flag"]), "flag before completion " + id)
			everyday.update(float(d["seconds"]) * 0.25)
			if String(d["kind"]) == "pump":
				_check(absf((d["moving"] as Node3D).rotation.z) > 0.2, "pump handle did not move")
			else: _check(absf(everyday._moving_angle(d)) > 0.1, "part did not move " + id)
			everyday.update(float(d["seconds"]) * 0.75 + 0.001)
			if String(d["flag"]) != "": _check(s.has(d["flag"]), "completed state missing " + id)
	_check(s.inventory == original_inventory and s.task == "Задача до визита" and str(s.checkpoint) == original_checkpoint,
		"decor changed inventory/task/checkpoint")
	for flag: String in s.flags: _check(flag.begins_with("decor-"), "story flag from decor " + flag)
	_check(not s.flags.has("") and not s.has("decor-p10-pump-used") and not s.has("decor-p09-radio-used"),
		"pump/radio persisted runtime state")
	# Калитка выбирается с обеих сторон, закрытая створка не заслоняет собственную точку.
	for id: String in everyday.definitions:
		var d: Dictionary = everyday.definitions[id]
		if String(d["kind"]) != "gate": continue
		s.set_flag(d["flag"], false)
		everyday.resync(s)
		for side: float in [-1.0, 1.0]:
			camera.position = (d["point"] as Vector3) + Vector3(0, 0, side * 1.1)
			camera.look_at(d["point"])
			await process_frame
			var found: Variant = interact.find(camera, s)
			_check(found is Dictionary and found["id"] == id, "gate inaccessible from side " + id + ":" + str(side))
	# Проверка всего пути закрывания, включая игрока, вошедшего после начала движения.
	var gate: Dictionary = everyday.definitions["decor-gate-p02"]
	_check(everyday.use(gate["id"]), "gate open")
	everyday.update(0.61)
	controls.at = gate["hinge"] + Vector3(0.5, 0, -0.5)
	_check(not everyday.use(gate["id"]) and s.has(gate["flag"]), "close accepted occupied arc")
	controls.at = Vector3.ZERO
	_check(everyday.use(gate["id"]), "clear close rejected")
	everyday.update(0.15)
	controls.at = gate["hinge"] + Vector3(0.6, 0, -0.1)
	everyday.update(0.15)
	_check(not everyday.animations.has(gate["id"]) and s.has(gate["flag"]) and not col.is_blocker_active(gate["id"]),
		"closing trapped player who entered arc")
	controls.at = Vector3.ZERO
	_check(everyday.use(gate["id"]), "clear close restart")
	everyday.update(0.61)
	_check(col.is_blocker_active(gate["id"]) and not s.has(gate["flag"]), "closed gate collider/state disagree")
	# Отмена незавершённого открытия сохраняет безопасное открытое состояние.
	var before_race := s.snapshot()
	_check(everyday.use(gate["id"]), "opening before cancel race")
	everyday.update(0.15)
	controls.at = gate["hinge"] + Vector3(0.6, 0, 0)
	everyday.cancel_runtime()
	_check(everyday.animations.is_empty() and s.has(gate["flag"]) and not col.is_blocker_active(gate["id"]) \
		and is_equal_approx(everyday._moving_angle(gate), float(gate["angle"])), "cancel opening trapped player or desynced stable state")
	_check(str(s.checkpoint) == original_checkpoint, "safety cancel changed checkpoint")
	s.restore(before_race)
	everyday.resync(s)
	_check(not s.has(gate["flag"]) and col.is_blocker_active(gate["id"]) \
		and is_zero_approx(everyday._moving_angle(gate)), "resync did not restore checkpoint gate after safety cancel")
	controls.at = Vector3.ZERO
	# Таймер радио замораживается вместе с ручным update; E выключает до cooldown.
	_check(everyday.use(EverydayInteractions.RADIO_OWNER), "radio start")
	await physics_frame
	await physics_frame
	audio.set_spatial_paused(true)
	var remaining := everyday.radio_remaining
	for frame in 3: await process_frame
	_check(everyday.radio_remaining == remaining, "radio timer progressed without game update")
	for voice: AudioStreamPlayer3D in audio._spatial_pool:
		if voice.playing: _check(voice.stream_paused, "playing voice did not pause")
	audio.set_spatial_paused(false)
	_check(everyday.use(EverydayInteractions.RADIO_OWNER) and everyday.radio_remaining == 0.0 and everyday.radio_cooldown > 0.0,
		"radio repeat did not switch off preserving cooldown")
	_check(not everyday.use(EverydayInteractions.RADIO_OWNER), "radio restarted during cooldown")
	everyday.update(8.0)
	_check(everyday.use(EverydayInteractions.RADIO_OWNER), "radio did not rearm after cooldown")
	everyday.update(3.99)
	_check(everyday.radio_remaining > 0.0, "radio stopped before four seconds")
	everyday.update(0.02)
	_check(everyday.radio_remaining == 0.0 and not audio._spatial_owners.has(EverydayInteractions.RADIO_OWNER), "radio survived four seconds")
	# Cancel/resync возвращает сохранённое положение, не завершает незаконченный ход.
	everyday.cancel_runtime()
	var snap := s.snapshot()
	_check(everyday.use(gate["id"]), "partial gate")
	everyday.update(0.25)
	_check(everyday.use(EverydayInteractions.RADIO_OWNER), "radio before cancel")
	everyday.cancel_runtime()
	_check(everyday.animations.is_empty() and is_zero_approx(everyday._moving_angle(gate)) and not s.has(gate["flag"]),
		"cancel committed unfinished animation")
	_check(everyday.radio_remaining == 0.0 and everyday.radio_cooldown == 0.0, "cancel retained radio runtime")
	s.set_flag(gate["flag"])
	everyday.resync(s)
	s.restore(snap)
	everyday.resync(s)
	_check(is_zero_approx(everyday._moving_angle(gate)) and col.is_blocker_active(gate["id"]), "restore failed to close gate")
	# Старый reader callback не пишет флаг после отмены или новой игры.
	s.set_flag("decor-board-notice-read", false)
	everyday.use("decor-board-notice")
	var stale := ui.on_close
	everyday.cancel_runtime()
	stale.call()
	_check(not s.has("decor-board-notice-read"), "stale notice callback survived cancel")
	exclusive.on = true
	_check(not everyday.use(EverydayInteractions.RADIO_OWNER) and not everyday.use("decor-shed-cabinet"), "exclusive scene permits decor")
	exclusive.on = false
	s.reset()
	everyday.resync(s)
	_check(s.flags.is_empty() and everyday.animations.is_empty(), "new game retained decor")
	_los_tests(camera, s)
	# Owner stop не гасит звук после перераспределения слота.
	audio.spatial_sfx("radio-veranda", Vector3.ZERO, 0.3, 10, EverydayInteractions.RADIO_OWNER)
	for shot in 8: audio.spatial_sfx("horror-tin", Vector3.ZERO, 0.3, 10, "other")
	await physics_frame
	await physics_frame
	audio.stop_spatial_owner(EverydayInteractions.RADIO_OWNER)
	for index in audio._spatial_owners.size():
		if audio._spatial_owners[index] == "other": _check(audio._spatial_pool[index].playing, "stale radio owner stopped reused voice")
	_check(audio._spatial_pool.size() == 6, "radio allocated extra sources")
	audio.clear_spatial()
	audio.queue_free()
	world_root.queue_free()
	await process_frame
	for error: String in errors: printerr(error)
	print("test_everyday: ", "PASS" if errors.is_empty() else "FAIL", " (13 interactions)")
	quit(0 if errors.is_empty() else 1)


func _los_tests(camera: Camera3D, s: GameState) -> void:
	var cw := CollisionWorld.new()
	cw.add_box_d(CollisionWorld.SET_OVERLAY, -0.3, 0.0, -0.1, 0.3, 2.0, 0.1, "wall")
	var interact := Interact.new()
	interact.occluder = cw
	var at := Vector3(0, 0.8, -0.8)
	interact.add({"id": "decor-test", "pos": at, "r": 2.2, "priority": -0.75, "los_mask": CollisionWorld.ALL_SOLID})
	camera.position = Vector3(0, 0.8, 0.8)
	camera.look_at(at)
	_check(interact.find(camera, s) == null, "ALL_SOLID target through overlay wall")
	cw.set_blocker_active("wall", false)
	_check(interact.find(camera, s) != null, "inactive blocker stayed cached")
	cw.set_blocker_active("wall", true)
	_check(interact.find(camera, s) == null, "reactivated blocker stayed cached")
	camera.position = Vector3(0, 0.8, 0.05)
	camera.look_at(at)
	_check(interact.find(camera, s) == null, "ALL_SOLID camera inside wall saw through it")
	camera.position = Vector3(0, 0.8, 0.8)
	camera.look_at(at)
	cw.set_blocker_active("wall", false)
	interact.add({"id": "story-test", "pos": at, "r": 2.2})
	_check(interact.find(camera, s)["id"] == "story-test", "decor won over story")
	cw.add_rot_box_d(CollisionWorld.SET_OVERLAY, 0, 0.8, 0, 0.4, 0.8, 0.06, CollisionWorld.AXIS_Y, 0.7, "rotated")
	_check(not interact.visible(camera.position, at, CollisionWorld.ALL_SOLID), "rotated OBB did not occlude")
	_endpoint_los_tests(camera, s)


func _endpoint_los_tests(camera: Camera3D, s: GameState) -> void:
	var cw := CollisionWorld.new()
	var point := Vector3(0, 1.1, 2.0)
	var eye := Vector3(0, 1.6, 0)
	cw.add_box_d(CollisionWorld.SET_OVERLAY, -0.7, 0, 1.94, 0.7, 2, 2.06, "self-gate")
	cw.add_box_d(CollisionWorld.SET_STATIC, -1, 0, 1.90, 1, 2, 1.95, "foreign-thin-wall")
	var it := Interact.new()
	it.occluder = cw
	_check(it.visible(eye, point), "legacy story endpoint tolerance changed")
	_check(not it.visible(eye, point, CollisionWorld.ALL_SOLID, "self-gate"), "self ignore hid a foreign wall before gate")
	cw.set_blocker_active("foreign-thin-wall", false)
	var unchanged := var_to_str([cw._data, cw._active, cw._by_id])
	for side: float in [0.0, 4.0]:
		var from := Vector3(0, 1.6, side)
		_check(not it.visible(from, point, CollisionWorld.ALL_SOLID), "closed self slab did not occlude")
		_check(it.visible(from, point, CollisionWorld.ALL_SOLID, "self-gate"), "closed gate unreachable from side " + str(side))
	_check(var_to_str([cw._data, cw._active, cw._by_id]) == unchanged, "visibility mutated blocker state")
	# Wall starts behind the self slab's first hit, only 1 cm from the target.
	cw.add_box_d(CollisionWorld.SET_OVERLAY, -1, 0, 1.99, 1, 2, 1.999, "foreign-after-self")
	_check(not it.visible(eye, point, CollisionWorld.ALL_SOLID, "self-gate"), "foreign wall behind ignored slab was hidden")
	var inside := Vector3(0, 1.1, 1.995)
	_check(not it.visible(inside, point, CollisionWorld.ALL_SOLID, "self-gate"), "inside solid short ray accepted hit zero")
	_check(not it.visible(inside, inside, CollisionWorld.ALL_SOLID, "self-gate"), "inside solid zero-length ray accepted")
	cw.set_blocker_active("foreign-after-self", false)
	var calls := {"count": 0}
	it.add({"id": "gate-los-test", "pos": point, "r": 2.2, "los_mask": CollisionWorld.ALL_SOLID,
		"los_ignore_blocker": "self-gate", "onUse": func(_ctx: Dictionary) -> void: calls["count"] += 1})
	camera.position = eye
	camera.look_at(point)
	_check(it.find(camera, s) != null, "self gate not found before foreign activation")
	cw.set_blocker_active("foreign-after-self", true)
	unchanged = var_to_str([cw._data, cw._active, cw._by_id])
	var c := {"state": s, "renderer": {"camera": camera}}
	_check(not it.use(c) and calls["count"] == 0, "E used cached target after foreign wall activation")
	_check(it.find(camera, s) == null, "find cached ALL_SOLID despite active wall")
	_check(var_to_str([cw._data, cw._active, cw._by_id]) == unchanged, "find/use temporarily toggled blockers")
	cw.set_blocker_active("foreign-after-self", false)
	_check(it.find(camera, s) != null and it.use(c) and calls["count"] == 1, "same-eye ALL_SOLID did not recover after deactivation")
	cw.add_rot_box_d(CollisionWorld.SET_PROPS, 0, 1.0, 1.93, 0.5, 1.0, 0.008, CollisionWorld.AXIS_Y, 0.7, "foreign-rotated")
	_check(not it.visible(eye, point, CollisionWorld.ALL_SOLID, "self-gate"), "ignored gate hid thin rotated foreign OBB")
	cw.set_blocker_active("foreign-rotated", false)
	_check(it.visible(eye, point, CollisionWorld.ALL_SOLID, "self-gate"), "inactive rotated OBB still occludes")


func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

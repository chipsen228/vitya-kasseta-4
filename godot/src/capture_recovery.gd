# Поимка и игровой выход из существующего подпола. Сюжет не откатывается.
class_name CaptureRecovery
extends RefCounted

const LENGTH := 3.8
const LIGHT_ID := "recovery-light"
const HATCH_ID := "recovery-hatch-free"
const CELLAR := Vector3(-3.0, -1.55, 10.5)

var c: Dictionary
var phase := "idle"
var generation := 0
var checkpoint: Dictionary = {}
var source: Dictionary = {}
var terminal := false
var impact_played := false
var windup_played := false
var _from := Vector3.ZERO
var _contact := Vector3.ZERO
var _light: OmniLight3D
var _fixture: Node3D
var _board: MeshInstance3D
var _external_time := 0.0
var _external_anchor := Vector3.ZERO

func begin_external(captor: String, retry_anchor: Vector3) -> bool:
	var s: GameState = c["state"]
	if active() or s.chapter != "village": return false
	generation += 1
	phase = "external-hit"
	_external_time = 0.0
	_external_anchor = retry_anchor
	terminal = false
	s.failCount += 1
	s.hidden = false
	s.threatState = "absent"
	s.recovery = {"phase": phase, "kind": "snt", "captor": captor,
		"retry_anchor": [retry_anchor.x, retry_anchor.y, retry_anchor.z], "terminal": false}
	_call("cancelDialogue")
	var director: Variant = c.get("horror")
	if director != null: director.invalidate("capture")
	c["controls"].enabled = false
	c["controls"].frozen = false
	c["interact"].target = null
	_cinematic(true)
	c["ui"].say("Обходчик рядом. Отступить к служебному входу.", 3.0)
	if _scares_on(): _sound("horror-cloth", c["controls"].feet(), 0.4)
	return true

func update_external(dt: float) -> void:
	if phase != "external-hit": return
	_external_time += dt
	var actors: Variant = c.get("episodeActors")
	if actors != null: actors.sample_action("walker", "capture", _external_time)
	c["renderer"].set_fade(1.0 - clampf((_external_time - 1.8) / 1.0, 0.0, 1.0))
	if _external_time < 2.9: return
	c["external_retry_anchor"] = _external_anchor
	c["chapters"].retry()
	_call("resumeControl")

func _init(context: Dictionary) -> void:
	c = context

func active() -> bool:
	return phase != "idle"

func allows(id: String) -> bool:
	if not active():
		return true
	return phase == "cellar" and (id == LIGHT_ID or id == HATCH_ID)

func hatch_allowed(id: String, down: bool) -> bool:
	return not active() or (phase == "cellar" and id == "hatch-cellar" \
		and not down and bool((c["state"] as GameState).recovery.get("hatch_free", false)))

func register(interact: Interact) -> void:
	interact.add({"id": LIGHT_ID, "pos": CELLAR + Vector3(0.0, 1.1, -0.55),
		"r": 2.2, "cone": 0.8, "priority": 5, "prompt": "включить аварийную лампу",
		"when": func(s: GameState) -> bool:
			return phase == "cellar" and not bool(s.recovery.get("light_on", false)),
		"onUse": func(_ctx: Dictionary) -> void: light_on()})
	interact.add({"id": HATCH_ID, "pos": Vector3(-4.45, -0.95, 8.5),
		"r": 2.0, "cone": 0.8, "priority": 5, "prompt": "отодвинуть доску под люком",
		"when": func(s: GameState) -> bool:
			return phase == "cellar" and bool(s.recovery.get("light_on", false)) \
				and not bool(s.recovery.get("hatch_free", false)),
		"onUse": func(_ctx: Dictionary) -> void: free_hatch()})

func begin(kind: String, is_terminal := false) -> bool:
	if active() or (c["state"] as GameState).chapter == "end":
		return false
	var director: Variant = c.get("horror")
	if director != null:
		director.invalidate("capture")
	generation += 1
	var stamp := generation
	terminal = is_terminal
	phase = "hit"
	_call("cancelDialogue")
	impact_played = false
	windup_played = false
	var s: GameState = c["state"]
	checkpoint = {"task": s.task, "threat": String(c.get("catch_previous_threat", s.threatState)),
		"chapter": s.chapter, "kind": kind, "gate_chase": s.chapter == "gate" and s.has("gate-open"),
		"lights": c["lights"].snapshot(), "flash": c["flashlight"].snapshot()}
	if not terminal:
		s.failCount += 1
		if s.failCount >= 3:
			_call("slowThreat", [0.9])
	s.hidden = false
	s.threatState = "absent"
	s.set_flag("starter-on", false)
	c["drive_attempt_id"] = int(c.get("drive_attempt_id", 0)) + 1
	s.recovery = {"phase": phase, "kind": kind, "task": s.task,
		"light_on": false, "hatch_free": false, "terminal": terminal,
		"checkpoint": checkpoint.duplicate(true)}
	c["controls"].enabled = false
	c["controls"].frozen = false
	_cinematic(true)
	c["interact"].target = null
	var th: Variant = c.get("threat")
	if th != null:
		th.end_final()
	var stalk: Variant = c.get("stalk")
	if stalk != null:
		stalk.finish()
	_call("holdEcho", [LENGTH + 1.0])
	var actor: Variant = c["actors"]
	actor.show("threat", false)
	var feet: Vector3 = c["controls"].feet()
	source = (c.get("catch_source", {}) as Dictionary).duplicate(true)
	var caught_at: Vector3 = source.get("pos", feet + c["controls"].forward())
	var direction := caught_at - feet
	direction.y = 0.0
	if direction.length_squared() < 0.01:
		direction = c["controls"].forward()
		direction.y = 0.0
	direction = direction.normalized()
	_contact = feet + direction * 0.85
	_from = caught_at
	# Продлить подход можно только по свободному коридору на этом же этаже.
	if director != null:
		for distance: float in [5.0, 3.5, 2.0]:
			var candidate := feet + direction * distance
			if director.trajectory_clear(candidate, _contact):
				_from = candidate
				break
	actor.show("echo", true)
	actor.place("echo", _from.x, _from.y, _from.z, 0.0)
	actor.face("echo", feet.x, feet.z)
	if actor.has_method("begin_action"):
		actor.begin_action("echo", "run")
	var chain: Variant = c["renderer"]
	var eye: Vector3 = chain.camera.global_position
	var look := _contact + Vector3(0.0, 1.2, 0.0)
	var shots: Array = [
		{"pos": eye, "look_at": look, "sec": 3.0},
		{"pos": eye, "pos_to": feet + Vector3(0.12, 0.23, 0.0),
			"look_at": look, "look_at_to": look + Vector3(0.0, 0.5, 0.0),
			"roll": 0.0, "roll_to": -1.12, "sec": LENGTH - 3.0}]
	var cut: Variant = c.get("cutscene")
	if cut == null or not cut.play(chain.world_root, chain.camera, shots, LENGTH,
		func(t: float) -> void:
			if stamp == generation: _sample(t),
		func() -> void:
			if stamp == generation: _finish_hit()):
		_finish_hit()
	return true

func _sample(t: float) -> void:
	var actors: Variant = c["actors"]
	var p := _from.lerp(_contact, clampf(t / 2.0, 0.0, 1.0))
	actors.place("echo", p.x, p.y, p.z, 0.0)
	var feet: Vector3 = c["controls"].feet()
	actors.face("echo", feet.x, feet.z)
	var action := "run"
	var local_t := t
	if t >= 2.93:
		action = "shovel_impact"
		local_t = t - 2.93
	elif t >= 2.28:
		action = "shovel_windup"
		local_t = t - 2.28
	elif t >= 2.0:
		action = "stop"
		local_t = t - 2.0
	if actors.has_method("sample_action"):
		actors.sample_action("echo", action, local_t)
	if t >= 2.28 and not windup_played:
		windup_played = true
		if _scares_on(): _sound("horror-shovel-windup", p, 0.45)
	if t >= 3.0 and not impact_played:
		impact_played = true
		if _scares_on():
			_sound("horror-shovel-impact", p, 0.6)
			c["renderer"].set_tracking(0.16)
	if t >= 3.4:
		c["renderer"].set_fade(1.0 - clampf((t - 3.4) / 0.4, 0.0, 1.0))

func _finish_hit() -> void:
	_cinematic(false)
	_cleanup_actor()
	c["renderer"].set_tracking(0.0)
	c["renderer"].set_fade(1.0)
	if terminal:
		phase = "idle"
		(c["state"] as GameState).recovery = {}
		_call("terminalCaught")
		return
	var s: GameState = c["state"]
	phase = "cellar"
	s.recovery["phase"] = phase
	c["lights"].restore(checkpoint["lights"])
	c["flashlight"].restore(checkpoint["flash"])
	c["controls"].pitch = 0.0
	c["controls"].pitch_target = 0.0
	c["controls"].place(CELLAR.x, CELLAR.y, CELLAR.z, 0.0)
	c["controls"].enabled = true
	_make_light(false)
	if s.recovery_completed_count > 0:
		light_on()
		free_hatch()
	else:
		c["ui"].setTask("Включить аварийную лампу. Освободить люк.")
		c["ui"].say("Подпол. Над люком доска. Сначала свет.", 4.5)
	_call("resumeControl")

func light_on() -> void:
	if phase != "cellar": return
	(c["state"] as GameState).recovery["light_on"] = true
	_make_light(true)
	c["audio"].click()
	c["ui"].setTask("Отодвинуть доску под люком и подняться.")

func free_hatch() -> void:
	if phase != "cellar" or not bool((c["state"] as GameState).recovery.get("light_on", false)): return
	(c["state"] as GameState).recovery["hatch_free"] = true
	if is_instance_valid(_board):
		_board.position.x -= 1.0
		_board.rotation.z = 0.18
	c["audio"].creak(0.4)
	c["ui"].setTask("Подняться через люк.")

func begin_exit() -> void:
	if phase == "cellar":
		phase = "exit"
		(c["state"] as GameState).recovery["phase"] = phase

func finish_exit() -> void:
	if phase != "exit": return
	var s: GameState = c["state"]
	s.recovery_completed_count += 1
	s.recovery = {}
	phase = "idle"
	_free_light()
	s.task = checkpoint.get("task")
	c["ui"].setTask(s.task)
	_call("resumeRecovery", [checkpoint])
	checkpoint = {}


func resume_saved() -> bool:
	var s: GameState = c["state"]
	if active() or s.recovery.is_empty(): return false
	if String(s.recovery.get("kind", "")) == "snt":
		var at: Array = s.recovery.get("retry_anchor", [7.1, 0, -66.5])
		c["external_retry_anchor"] = Vector3(float(at[0]), float(at[1]), float(at[2]))
		c["chapters"].retry()
		return true
	var saved: Dictionary = s.recovery.duplicate(true)
	var old_checkpoint: Variant = saved.get("checkpoint", {})
	checkpoint = old_checkpoint.duplicate(true) if old_checkpoint is Dictionary else {}
	if checkpoint.is_empty():
		checkpoint = {"task": saved.get("task", s.task), "threat": "patrol", "kind": saved.get("kind", "dark"),
			"chapter": s.chapter, "gate_chase": s.chapter == "gate" and s.has("gate-open"),
			"lights": c["lights"].snapshot(), "flash": c["flashlight"].snapshot()}
	var director: Variant = c.get("horror")
	if director != null: director.invalidate("capture")
	generation += 1
	if bool(saved.get("terminal", false)):
		s.recovery = {}
		_call("terminalCaught")
		return true
	phase = "cellar"
	s.recovery = saved
	s.recovery["phase"] = phase
	s.threatState = "absent"
	s.hidden = false
	c["controls"].frozen = false
	c["controls"].pitch = 0.0
	c["controls"].pitch_target = 0.0
	c["controls"].place(CELLAR.x, CELLAR.y, CELLAR.z, 0.0)
	c["controls"].enabled = true
	c["lights"].restore(checkpoint["lights"])
	c["flashlight"].restore(checkpoint["flash"])
	_make_light(bool(saved.get("light_on", false)))
	if bool(saved.get("hatch_free", false)):
		free_hatch()
	elif bool(saved.get("light_on", false)):
		c["ui"].setTask("Отодвинуть доску под люком и подняться.")
	else:
		c["ui"].setTask("Включить аварийную лампу. Освободить люк.")
	_call("resumeControl")
	return true

func cancel() -> void:
	generation += 1
	phase = "idle"
	checkpoint = {}
	_free_light()
	_cleanup_actor()
	_cinematic(false)
	if c.get("state") != null:
		(c["state"] as GameState).recovery = {}
	var chain: Variant = c.get("renderer")
	if chain != null:
		chain.set_tracking(0.0)
		chain.set_fade(1.0)

func _make_light(on: bool) -> void:
	if _light == null:
		_light = OmniLight3D.new()
		_light.name = "RecoveryEmergencyLight"
		_light.light_color = Color(1.0, 0.72, 0.38)
		_light.omni_range = 6.0
		_light.shadow_enabled = false
		c["renderer"].world_root.add_child(_light)
		_light.position = CELLAR + Vector3(0.0, 1.4, -0.55)
		_make_recovery_props()
	# Слабый ориентир виден и при пустой батарее. Это отдельная лампа.
	_light.light_energy = 1.6 if on else 0.18

func _free_light() -> void:
	if is_instance_valid(_light): _light.queue_free()
	_light = null
	if is_instance_valid(_fixture): _fixture.queue_free()
	if is_instance_valid(_board): _board.queue_free()
	_fixture = null
	_board = null


func _make_recovery_props() -> void:
	var root: Node3D = c["renderer"].world_root
	_fixture = Node3D.new()
	_fixture.name = "RecoveryLampFixture"
	root.add_child(_fixture)
	_fixture.position = CELLAR + Vector3(0.0, 1.1, -0.55)
	var body := MeshInstance3D.new()
	var cage := CylinderMesh.new()
	cage.top_radius = 0.11
	cage.bottom_radius = 0.14
	cage.height = 0.30
	cage.radial_segments = 10
	var metal := StandardMaterial3D.new()
	metal.albedo_color = Color(0.16, 0.18, 0.13)
	cage.material = metal
	body.mesh = cage
	_fixture.add_child(body)
	var bulb := MeshInstance3D.new()
	var glass := SphereMesh.new()
	glass.radius = 0.075
	glass.height = 0.15
	glass.radial_segments = 10
	glass.rings = 5
	var glow := StandardMaterial3D.new()
	glow.albedo_color = Color(0.9, 0.65, 0.30)
	glow.emission_enabled = true
	glow.emission = Color(0.6, 0.30, 0.06)
	glass.material = glow
	bulb.mesh = glass
	bulb.position.z = 0.115
	_fixture.add_child(bulb)
	_board = MeshInstance3D.new()
	_board.name = "RecoveryHatchBoard"
	var plank := BoxMesh.new()
	plank.size = Vector3(1.30, 0.10, 0.23)
	var wood := StandardMaterial3D.new()
	wood.albedo_color = Color(0.27, 0.19, 0.12)
	wood.roughness = 0.96
	plank.material = wood
	_board.mesh = plank
	root.add_child(_board)
	_board.position = Vector3(-4.45, -0.85, 8.5)
	_board.rotation.y = 0.12

func _cleanup_actor() -> void:
	var a: Variant = c.get("actors")
	if a == null: return
	if a.has_method("end_action"): a.end_action("echo")
	a.show("echo", false)

func _scares_on() -> bool:
	var cb: Variant = c.get("scaresOn")
	return cb == null or bool(cb.call())

func _call(key: String, args: Array = []) -> void:
	var cb: Variant = c.get(key)
	if cb is Callable: cb.callv(args)


func _sound(id: String, at: Vector3, gain: float) -> void:
	var audio: Variant = c.get("audio")
	if audio == null: return
	if audio.has_method("spatial_sfx") and bool(audio.spatial_sfx(id, at, gain, 12.0)): return
	if not bool(audio.sfx(id, gain)): audio.knock(1, 0.0)


func _cinematic(on: bool) -> void:
	var held: Variant = c.get("heldItems")
	if held != null and held.has_method("set_cinematic_hidden"): held.set_cinematic_hidden(on)
	var flash: Variant = c.get("flashlight")
	if flash != null and flash.has_method("set_cinematic_suppressed"): flash.set_cinematic_suppressed(on)

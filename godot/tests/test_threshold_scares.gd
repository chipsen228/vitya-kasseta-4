extends SceneTree

class Controls extends RefCounted:
	var p := Vector3.ZERO
	func feet() -> Vector3: return p

class Renderer extends RefCounted:
	var camera: Camera3D
	var world_root: Node3D

class Audio extends RefCounted:
	var played := 0
	var available := true
	func spatial_sfx(_id: String, _at: Vector3, _gain: float, _distance: float) -> bool:
		if available: played += 1
		return available

class DummyActors extends RefCounted:
	var shown := false
	var at := Vector3.ZERO
	func place(_id: String, x: float, y: float, z: float, _yaw := 0.0) -> void: at = Vector3(x,y,z)
	func face(_id: String, _x: float, _z: float) -> void: pass
	func show(_id: String, on: bool) -> void: shown = on

class Pursuit extends RefCounted:
	var on := true
	func active() -> bool: return on
	func exclusive_runtime() -> bool: return on

var errors: Array[String] = []
var ctx: Dictionary
var controls: Controls
var state: GameState
var renderer: Renderer
var audio: Audio
var director: HorrorDirector
var threshold: ThresholdScares
var enabled := true

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	controls = Controls.new()
	state = GameState.new()
	state.chapter = "village"
	renderer = Renderer.new()
	renderer.world_root = Node3D.new()
	root.add_child(renderer.world_root)
	renderer.camera = Camera3D.new()
	renderer.world_root.add_child(renderer.camera)
	audio = Audio.new()
	ctx = {"state":state,"controls":controls,"renderer":renderer,"audio":audio,
		"episodeActors":DummyActors.new(),"scaresOn":func() -> bool:return enabled}
	director = HorrorDirector.new(ctx)
	ctx["horror"] = director
	threshold = director.thresholds
	_catalog()
	_all_stages()
	_once_and_movement()
	_blocked_and_off()
	_failed_start()
	await _audio_priorities()
	await _geometry()
	director.invalidate()
	ctx.clear()
	renderer.world_root.free()
	for error: String in errors: printerr(error)
	print("test_threshold_scares: %s (14 directed thresholds, load/reverse/retry/off/block/cooldown, ALL_SOLID anchors)" % ("PASS" if errors.is_empty() else "FAIL"))
	quit(0 if errors.is_empty() else 1)

func _catalog() -> void:
	_check(ThresholdScares.EVENTS.size() == 14,"threshold count")
	var ids := {}
	for e: Dictionary in ThresholdScares.EVENTS:
		_check(not ids.has(e["id"]),"duplicate " + e["id"])
		ids[e["id"]] = true
		var at: Vector3 = e["at"]
		var normal: Vector3 = e["normal"]
		_check(ThresholdScares.crossed(e,at-normal*0.2,at+normal*0.2),"forward rejected " + e["id"])
		_check(not ThresholdScares.crossed(e,at+normal*0.2,at-normal*0.2),"reverse accepted " + e["id"])
		_check(not ThresholdScares.crossed(e,Vector3.INF,at),"load accepted " + e["id"])
		_check(not ThresholdScares.crossed(e,at-normal*8.0,at+normal*0.2),"teleport accepted " + e["id"])

func _setup() -> Dictionary:
	state.reset()
	state.chapter = "village"
	director.invalidate()
	director.cooldown = 0.0
	enabled = true
	audio.available = true
	audio.played = 0
	ctx["episodeActors"] = DummyActors.new()
	ctx.erase("pursuit")
	ctx.erase("col")
	return threshold.event(ThresholdScares.EVENTS[3])

func _all_stages() -> void:
	for raw: Dictionary in ThresholdScares.EVENTS:
		_setup()
		var e := threshold.event(raw)
		for flag: String in e.get("need",[]): state.set_flag(flag)
		var checkpoint := state.snapshot()
		_cross_stage(e)
		_check(state.horror_seen.has(e["id"]),"eligible physical stage failed " + e["id"])
		_check(audio.played == 1,"physical stage did not start local sound " + e["id"])
		threshold._end()
		director.cooldown = 0.0
		_cross_stage(e)
		_check(audio.played == 1,"repeat stage replayed " + e["id"])
		state.restore(checkpoint)
		director.invalidate("retry")
		director.cooldown = 0.0
		_cross_stage(e)
		_check(audio.played == 1,"retry stage replayed " + e["id"])
		state.reset()
		state.chapter = "village"
		for flag: String in e.get("need",[]): state.set_flag(flag)
		director.invalidate()
		_cross_stage(e)
		_check(audio.played == 2,"new game stage did not reset " + e["id"])

func _cross_stage(e: Dictionary) -> void:
	for offset: float in [-0.2,0.2]:
		var at := Vector3(e["at"]) + Vector3(e["normal"]) * offset
		var eye := at if bool(e.get("camera_route",false)) else at + Vector3(0,1.62,0)
		controls.p = at
		renderer.camera.position = eye
		var target := Vector3(e["from"]) + (Vector3.ZERO if bool(e.get("face",false)) else Vector3(0,1.45,0))
		renderer.camera.look_at(target,Vector3.UP)
		if bool(e.get("camera_route",false)): threshold.update_bathloft(0.05,eye,"loft")
		else: threshold.update(0.05,false)

func _audio_priorities() -> void:
	var real_audio := GameAudio.new()
	root.add_child(real_audio)
	real_audio.bind_spatial_world(renderer.world_root)
	for i in 6:
		_check(real_audio.spatial_sfx("horror-run-wood",Vector3.ZERO,1.0,20.0,"warning",3),"warning allocation failed")
	await physics_frame
	_check(not real_audio.spatial_sfx("horror-run-wood",Vector3.ZERO,1.0,20.0,"decoration",0),"decoration stole warning source")
	_check(real_audio.spatial_sfx("horror-run-wood",Vector3.ZERO,1.0,20.0,"speech",4),"speech did not preempt lower priority")
	real_audio.clear_spatial()
	var voice := GameVoice.new(real_audio)
	root.add_child(voice)
	var entries: Dictionary = voice.get("_lines")
	_check(not entries.is_empty(),"voice manifest absent")
	if not entries.is_empty():
		entries[GameVoice.line_key("test-source","test sentence")] = entries.values()[0]
		var source := Vector3(7.1,0.7,-58.86)
		_check(voice.play_spatial_dialogue_line("test-source","test sentence",source) > 0,"spatial dialogue did not start")
		await physics_frame
		_check(voice.dialogue_active(),"spatial speech invisible to dialogue arbiter")
		for i in 8: real_audio.spatial_sfx("horror-run-wood",Vector3.ZERO,1.0,20.0,"decoration",0)
		var owners: Array = real_audio.get("_spatial_owners")
		var slot := owners.find("dialogue:spatial")
		_check(slot >= 0,"decoration stole spatial dialogue")
		if slot >= 0:
			var player: AudioStreamPlayer3D = real_audio.get("_spatial_pool")[slot]
			_check(player.global_position.is_equal_approx(source),"radio voice detached from source")
			real_audio.set_spatial_paused(true,false)
			_check(not player.stream_paused,"dialogue UI paused its own spatial speech")
			real_audio.set_spatial_paused(true)
			_check(player.stream_paused,"actual pause did not pause spatial speech")
			real_audio.set_spatial_paused(false)
		voice.stop_dialogue()
		_check(not voice.dialogue_active(),"stop_dialogue left radio speech active")
	voice.free()
	real_audio.clear_spatial()
	# Spatial players were intentionally reparented into the visible world.
	for player: AudioStreamPlayer3D in real_audio.get("_spatial_pool"):
		player.reparent(real_audio)
	real_audio.free()

func _move(e: Dictionary, offset: float, blocked := false) -> void:
	controls.p = Vector3(e["at"]) + Vector3(e["normal"]) * offset
	renderer.camera.position = controls.p + Vector3(0,1.62,0)
	renderer.camera.look_at(Vector3(e["from"]) + Vector3(0,1.4,0),Vector3.UP)
	threshold.update(0.05,blocked)

func _once_and_movement() -> void:
	var e := _setup()
	_move(e,0.2)
	_check(audio.played == 0,"load inside fired")
	_move(e,-0.2)
	_check(audio.played == 0,"reverse traversal fired")
	var checkpoint := state.snapshot()
	_move(e,0.2)
	_check(audio.played == 1 and state.horror_seen.has(e["id"]),"forward did not start")
	_check(director.cooldown >= 75.0,"strong cooldown")
	_check(threshold.anchors.has(e["id"]),"physical markers missing")
	threshold.update(2.0,false)
	_check(not bool(ctx["episodeActors"].shown),"decorative actor stayed visible")
	director.cooldown = 0.0
	_move(e,-0.2)
	_move(e,0.2)
	_check(audio.played == 1,"repeat replayed")
	state.restore(checkpoint)
	director.invalidate("retry")
	director.cooldown = 0.0
	_move(e,-0.2)
	_move(e,0.2)
	_check(audio.played == 1,"retry replayed")
	state.reset()
	state.chapter = "village"
	director.invalidate()
	_move(e,-0.2)
	_move(e,0.2)
	_check(audio.played == 2,"new game did not reset once")
	_setup()
	state.set_flag("startle-shed-in")
	_move(e,-0.2)
	_move(e,0.2)
	_check(audio.played == 0,"legacy alias replayed")

func _blocked_and_off() -> void:
	var e := _setup()
	_move(e,-0.2)
	_move(e,0.2,true)
	_move(e,0.5)
	_check(audio.played == 0 and state.horror_seen.is_empty(),"blocked crossing queued or consumed")
	_move(e,-0.2)
	enabled = false
	_move(e,0.2)
	_check(audio.played == 0 and state.horror_seen.is_empty(),"off crossing consumed")
	enabled = true
	_move(e,0.5)
	_check(audio.played == 0,"off crossing played late")
	_move(e,-0.2)
	director.cooldown = 1.0
	_move(e,0.2)
	director.cooldown = 0.0
	_move(e,0.5)
	_check(audio.played == 0,"cooldown crossing played late")
	ctx["pursuit"] = Pursuit.new()
	_move(e,-0.2)
	_move(e,0.2)
	_check(audio.played == 0,"pursuit did not own runtime")
	ctx.erase("pursuit")
	_move(e,-0.2)
	_move(e,0.2)
	_check(audio.played == 1,"unblocked next crossing did not play")
	threshold.update(0.1,true)
	_check(not threshold.active() and not bool(ctx["episodeActors"].shown),"pause failed to cancel visual")

func _failed_start() -> void:
	var e := _setup()
	ctx.erase("episodeActors")
	audio.available = false
	_move(e,-0.2)
	_move(e,0.2)
	_check(state.horror_seen.is_empty() and director.cooldown == 0.0,"failed presentation consumed event")
	ctx["episodeActors"] = DummyActors.new()
	var col := CollisionWorld.new()
	col.add_box(CollisionWorld.SET_STATIC,AABB(Vector3(0,-0.2,0),Vector3(20,0.2,20)))
	ctx["col"] = col
	_check(threshold.geometry_clear(e),"safe test path rejected")
	col.add_box(CollisionWorld.SET_OVERLAY,AABB(Vector3(6.7,0,8.9),Vector3(0.2,3,0.3)))
	_check(not threshold.geometry_clear(e),"path crossed overlay obstacle")
	_check(not threshold.visible_from(Vector3(6.8,1.62,10),Vector3(6.8,1.5,8),true),"ALL_SOLID visibility ignored overlay")

func _geometry() -> void:
	_setup()
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	root.add_child(world)
	var built := WorldBuilder.build(world,mats,col)
	var props := Props.new(mats)
	var data := GameData.props()
	props.load_models(data["PROPS"])
	props.build(world,data["PROPS"],col)
	props.rebuild_collision(col)
	for b: Dictionary in built.get("blockers",[]): col.set_blocker_active(String(b["id"]),false)
	ctx["world"] = built
	ctx["col"] = col
	for raw: Dictionary in ThresholdScares.EVENTS:
		var e := threshold.event(raw)
		var id := String(e["id"])
		# SNT geometry is authored by the environment module and must declare anchors.
		if id.begins_with("snt-") and not (built.get("snt",{}).get("scare_anchors",{}) as Dictionary).has(id):
			_check(false,"missing authored SNT anchor " + id)
			continue
		_check(threshold.geometry_clear(e),"unsafe world trajectory/face " + id)
		if not threshold.geometry_clear(e) and not bool(e.get("face",false)):
			for step in 13:
				var p := Vector3(e["from"]).lerp(e["to"],float(step)/12.0)
				var floor_hit := col.ray_down(p.x,p.y+0.55,p.z,CollisionWorld.ALL_SOLID)
				var hit := col.capsule_hit(p+Vector3(0,.34,0),p+Vector3(0,1.37,0),.32,CollisionWorld.ALL_SOLID)
				print("anchor probe ",id," ",p," floor=",floor_hit.get("y","none")," body=",hit)
		if bool(e.get("sound_only",false)): continue
		var eye := Vector3(e["at"]) + (Vector3.ZERO if bool(e.get("camera_route",false)) else Vector3(0,1.62,0))
		_check(threshold.visible_from(eye,e["from"],bool(e.get("face",false))),"world anchor invisible " + id)
	_front_door_geometry(col)
	props.dispose()
	world.free()
	ctx.erase("world")
	ctx.erase("col")

func _front_door_geometry(col: CollisionWorld) -> void:
	# Проверяем путь от наружной двери и обычный горизонтальный взгляд.
	# Центр старого маркера стоял у кухни и скрывал неверный путь за двумя стенами.
	state.reset()
	state.chapter = "light"
	director.invalidate()
	director.cooldown = 0.0
	var e := threshold.event(ThresholdScares.EVENTS[12])
	var eye_height := Player.STAND_HEIGHT - Player.EYE_DROP
	renderer.camera.fov = 70.0
	renderer.camera.keep_aspect = Camera3D.KEEP_HEIGHT
	for z: float in [6.8, 6.96, 7.08]:
		controls.p = Vector3(-2.3, 0.45, z)
		renderer.camera.position = controls.p + Vector3.UP * eye_height
		renderer.camera.rotation = Vector3(0.0, PI, 0.0)
		var body := col.capsule_hit(controls.p + Vector3.UP * 0.31,
			controls.p + Vector3.UP * 1.39, 0.30, CollisionWorld.ALL_SOLID)
		_check(body.is_empty() or float(body.get("depth",0.0)) < 0.02, "outer entry path collides at z=" + str(z))
		_check(threshold.visible_from(renderer.camera.global_position,e["from"],false), "entry figure hidden behind wall/prop at z=" + str(z))
		threshold.update(0.05, false)
	_check(state.horror_seen.has("house-entry-shadow") and threshold.active(), "normal outer-door approach missed first entry scare")
	_check((ctx["episodeActors"] as DummyActors).shown, "entry figure was not shown in veranda")
	threshold._end()

func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

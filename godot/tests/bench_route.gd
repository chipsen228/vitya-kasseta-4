# Windowed GPU camera traversal. Gameplay navigation is covered separately.
# Cold means first traversal after boot, not an empty OS/driver shader cache.
# Run without --headless. --strict enforces the requested 60 FPS/16.7 ms gate.
extends SceneTree

const ROUTE := [
	{"id": "yard", "pos": Vector3(0, 0, -1.2), "yaw": PI, "night": 0.10},
	{"id": "porch", "pos": Vector3(-2.3, 0, 3.4), "yaw": PI, "night": 0.25},
	{"id": "hall", "pos": Vector3(-3.0, 0.45, 11.0), "yaw": PI, "night": 0.55},
	{"id": "kitchen", "pos": Vector3(-0.4, 0.45, 11.4), "yaw": PI * 1.25, "night": 0.55},
	{"id": "stairs", "pos": Vector3(-5.05, 2.05, 12.7), "yaw": PI * 0.5, "night": 0.65},
	{"id": "tonya", "pos": Vector3(0.62, 3.30, 14.05), "yaw": PI * 0.78, "night": 0.70},
	{"id": "yard-return", "pos": Vector3(0, 0, 2.0), "yaw": 0.0, "night": 0.80},
	{"id": "street", "pos": Vector3(-5.5, 0, -3.6), "yaw": PI * 0.5, "night": 1.0},
	{"id": "second-line", "pos": Vector3(-18, 0, -21), "yaw": PI * 0.5, "night": 1.0},
	{"id": "pond", "pos": Vector3(-23, 0, -22.10), "yaw": 0.0, "night": 1.0},
	{"id": "mill", "pos": Vector3(15.5, 0, -23), "yaw": -0.74, "night": 1.0},
	{"id": "snt-gate", "pos": Vector3(36.8, 0, -38.3), "yaw": PI * 0.5, "night": 1.0},
	{"id": "snt-office", "pos": Vector3(4.4, 0, -37.4), "yaw": 0.0, "night": 1.0},
	{"id": "snt-p01", "pos": Vector3(19, 0, -40), "yaw": 0.0, "night": 1.0},
	{"id": "snt-water", "pos": Vector3(-4, 0, -53.8), "yaw": PI * 0.5, "night": 1.0},
	{"id": "snt-dead-end", "pos": Vector3(7.1, 0, -66.4), "yaw": 0.0, "night": 1.0},
	{"id": "gate-return", "pos": Vector3(7.6, 0, -5.2), "yaw": 1.728, "night": 1.0},
]

var _output := ""
var _lap_seconds := 60.0
var _strict := false
var _profile_components := false
var _main: Node
var _results: Array = []
var _frame_samples: Dictionary = {}
var _route_stalls: Array = []
var _geometry_peaks: Array = []
var _everyday_actions: Array = []
var _capture_triggers: Array = []
var _departure_triggers: Array = []
var _failures: Array[String] = []


func _initialize() -> void:
	_run()


func _run() -> void:
	var dimensions := Vector2i(1280, 720)
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--measure-size="):
			var parts := arg.trim_prefix("--measure-size=").split("x")
			dimensions = Vector2i(int(parts[0]), int(parts[1]))
	root.mode = Window.MODE_WINDOWED
	root.borderless = true
	root.min_size = dimensions
	root.size = dimensions
	root.position = Vector2i.ZERO
	await process_frame
	await process_frame
	if DisplayServer.get_name() == "headless":
		printerr("bench_route: FAIL requires a window and real GPU; headless is not a render measurement")
		quit(2)
		return
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--strict":
			_strict = true
		elif arg == "--profile-components":
			_profile_components = true
		elif arg.begins_with("--output="):
			_output = arg.trim_prefix("--output=")
		elif arg.begins_with("--lap-seconds="):
			_lap_seconds = maxf(20.0, float(arg.trim_prefix("--lap-seconds=")))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var boot_started := Time.get_ticks_usec()
	_main = load(ProjectSettings.globalize_path("res://../output/last-round/diagnostics/profile_route_main.gd")).new() if _profile_components \
		else (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	for _i in 900:
		if _boot_ready(_main):
			break
		await process_frame
	if not _boot_ready(_main):
		printerr("bench_route: FAIL boot timeout")
		quit(1)
		return
	var boot_ms := float(Time.get_ticks_usec() - boot_started) / 1000.0
	var boot_vsync: int = DisplayServer.window_get_vsync_mode()
	var boot_chain: RenderChain = _main.get("render_chain")
	var boot_preset: String = boot_chain.render_preset()
	_main.call("_start_game")
	var ui: Overlays = _main.get("ui")
	for _i in 60:
		if ui.card.open:
			ui.advanceCard()
		await process_frame
	# Measure the requested window and HQ buffer, independently of user settings.
	if not boot_chain.apply_preset("hq"):
		printerr("bench_route: FAIL cannot apply HQ preset")
		quit(2)
		return
	await process_frame
	await process_frame
	if root.size != dimensions or boot_chain.render_preset() != "hq":
		printerr("bench_route: FAIL measurement setup requested ", dimensions,
			" hq, got ", root.size, " ", boot_chain.render_preset())
		quit(2)
		return
	if dimensions == Vector2i(1280, 720) and boot_chain.stats().get("buffer") != "1280x720":
		printerr("bench_route: FAIL requested 1280x720 internal buffer, got ", boot_chain.stats().get("buffer"))
		quit(2)
		return
	var player: Player = _main.get("player")
	player.release_lock()
	var state: GameState = _main.get("state")
	state.give("flashlight")
	var flashlight: Flashlight = _main.get("flashlight")
	flashlight.give()
	flashlight.on = true
	var held: HeldItems = _main.get("held_items")
	held.sync(state)
	held.equip("flashlight")
	var measurement_vsync: int = DisplayServer.window_get_vsync_mode()
	for lap: String in ["cold", "warm"]:
		await _traverse(lap)
		await _everyday_scene(lap)
		await _snt_scene(lap)
		await _capture_scene(lap)
		await _drive(lap)
	var chain: RenderChain = _main.get("render_chain")
	var expected_names: Array[String] = ["cold-route", "cold-everyday", "cold-snt-scene", "cold-capture", "cold-departure",
		"warm-route", "warm-everyday", "warm-snt-scene", "warm-capture", "warm-departure"]
	var actual_names: Array[String] = []
	for row: Dictionary in _results:
		actual_names.append(String(row.get("name", "")))
	var complete := actual_names == expected_names
	if not complete:
		_failures.append("Incomplete route results: expected %s, got %s" % [expected_names, actual_names])
	if root.size != dimensions or chain.render_preset() != "hq":
		complete = false
		_failures.append("Measurement window or preset changed during route")
	var report := {
		"gpu": RenderingServer.get_video_adapter_name(),
		"renderer": RenderingServer.get_current_rendering_method(),
		"display_server": DisplayServer.get_name(),
		"window_size": [root.size.x, root.size.y], "internal_buffer": chain.stats().get("buffer"),
		"boot_ms": boot_ms, "lap_seconds": _lap_seconds,
		"preset": chain.render_preset(), "boot_preset": boot_preset,
		"boot_vsync_mode": boot_vsync, "measurement_vsync_mode": measurement_vsync,
		"final_vsync_mode": DisplayServer.window_get_vsync_mode(),
		"cold_definition": "first route after boot; OS and driver caches retained",
		"route_definition": "scripted GPU camera traversal; game loop, NPC, rain, storm, blackout, all 13 decorative animations/notices, SNT scene, capture and departure. Decoration uses controller activation; ordinary E and continuous physical movement are verified by test_environment_routes",
		"thresholds": {"average_fps_min": 60.0, "p95_ms_max": 16.7, "frame_ms_max": 50.0, "calls_max": 1600, "triangles_max": 220000},
		"strict": _strict, "profile_components": _profile_components, "results": _results, "target_failures": _failures,
		"cpu_monitor_note": "Godot TIME_PROCESS/TIME_PHYSICS_PROCESS previous-frame monitors, not a GPU timestamp",
		"frame_samples_ms": _frame_samples, "route_stalls": _route_stalls, "geometry_peaks": _geometry_peaks,
		"everyday_actions": _everyday_actions,
		"capture_triggers": _capture_triggers,
		"departure_triggers": _departure_triggers,
	}
	if not _output.is_empty():
		var file := FileAccess.open(_output, FileAccess.WRITE)
		if file == null:
			printerr("bench_route: FAIL cannot write " + _output)
			quit(1)
			return
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	for failure: String in _failures:
		print("bench_route target miss: ", failure)
	var passed := complete and (not _strict or _failures.is_empty())
	print("bench_route: %s (real GPU; cold/warm routes, SNT scenes and four-shot departures)" % ("PASS" if passed else "FAIL"))
	_main.queue_free()
	await process_frame
	await process_frame
	quit(0 if passed else 1)


func _traverse(lap: String) -> void:
	var player: Player = _main.get("player")
	var lights: LightRig = _main.get("lights")
	var weather: Weather = _main.get("weather")
	var actors: Actors = _main.get("actors")
	var chapters: Chapters = _main.get("chapters")
	var state: GameState = _main.get("state")
	var ui: Overlays = _main.get("ui")
	ui.showStartScreen(false)
	ui.showHud(true)
	chapters.go("arrive", true)
	state.ending = null
	state.threatState = "absent"
	_main.set("running", true)
	_main.get("threat").set("speedScale", 0.0)
	var ctx: Dictionary = _main.get("ctx")
	(ctx["holdEcho"] as Callable).call(_lap_seconds + 15.0)
	chapters.timers.clear()
	weather.clear()
	lights.powerOn = true
	for id: String in lights.state:
		lights.setLamp(id, id in ["porch", "hall", "kitchen", "landing", "vitya"])
	var flashlight: Flashlight = _main.get("flashlight")
	flashlight.battery = 100.0
	flashlight.on = true
	player.enabled = false
	var samples: Array[float] = []
	var cpu_process: Array[float] = []
	var cpu_physics: Array[float] = []
	var max_calls := 0
	var max_tris := 0
	var geometry_peak: Dictionary = {}
	var elapsed := 0.0
	var storm_sent := false
	var blackout_sent := false
	var started := Time.get_ticks_usec()
	while elapsed < _lap_seconds:
		var frame_start := Time.get_ticks_usec()
		var index_f := minf(elapsed / _lap_seconds * (ROUTE.size() - 1), ROUTE.size() - 1.001)
		var index := int(index_f)
		var blend := smoothstep(0.0, 1.0, index_f - index)
		var a: Dictionary = ROUTE[index]
		var b: Dictionary = ROUTE[index + 1]
		var position: Vector3 = (a["pos"] as Vector3).lerp(b["pos"], blend)
		var yaw := lerp_angle(float(a["yaw"]), float(b["yaw"]), blend) + sin(elapsed * 1.7) * 0.32
		player.place(position.x, position.y, position.z, yaw)
		player.pitch = sin(elapsed * 0.9) * 0.12
		player.pitch_target = player.pitch
		player.call("_apply_camera")
		lights.set_night_immediate(lerpf(float(a["night"]), float(b["night"]), blend))
		weather.set_rain(0.85 if elapsed > _lap_seconds * 0.35 else 0.15)
		if not blackout_sent and elapsed > _lap_seconds * 0.45:
			blackout_sent = true
			chapters.call("_blackout", ctx, true)
		if not storm_sent and elapsed > _lap_seconds * 0.58:
			storm_sent = true
			weather.storm(1.0, 0.3)
		actors.place("echo", position.x - sin(yaw) * 3.0, position.y, position.z - cos(yaw) * 3.0, yaw)
		actors.show("echo", true)
		var animation_dt := float(samples[-1]) / 1000.0 if not samples.is_empty() else 1.0 / 60.0
		actors.walk_anim("echo", animation_dt, {"speed": 1.5})
		await process_frame
		var ms := float(Time.get_ticks_usec() - frame_start) / 1000.0
		samples.append(ms)
		var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		cpu_process.append(process_ms)
		cpu_physics.append(physics_ms)
		if ms > 50.0:
			if _profile_components:
				print("route_stall_components ", JSON.stringify({"elapsed": elapsed, "ms": ms, "main": _main.get("profile_report"), "audio": _main.get("audio").get("profile_report")}))
			_route_stalls.append({"lap": lap, "frame": samples.size() - 1,
				"elapsed_s": elapsed, "ms": ms, "process_ms": process_ms, "physics_ms": physics_ms,
				"from": a["id"], "to": b["id"],
				"position": [position.x, position.y, position.z]})
		var stats: Dictionary = _main.get("render_chain").stats()
		max_calls = maxi(max_calls, int(stats.get("calls", 0)))
		if int(stats.get("tris", 0)) > max_tris:
			geometry_peak = {"lap": lap, "elapsed_s": elapsed, "from": a["id"], "to": b["id"], "position": [position.x, position.y, position.z], "yaw": yaw, "stats": stats}
		max_tris = maxi(max_tris, int(stats.get("tris", 0)))
		elapsed = float(Time.get_ticks_usec() - started) / 1000000.0
	actors.show("echo", false)
	_geometry_peaks.append(geometry_peak)
	_record(lap + "-route", samples, max_calls, max_tris, cpu_process, cpu_physics)



func _everyday_scene(lap: String) -> void:
	var decor: EverydayInteractions = _main.get("everyday")
	# Decoration is measured between scripted scenes; its priority guard stays active.
	_main.call("_cancel_dialogue_runtime")
	_main.get("horror").invalidate()
	var player: Player = _main.get("player")
	var state: GameState = _main.get("state")
	var ui: Overlays = _main.get("ui")
	state.chapter = "light"
	state.ending = null
	# Each lap measures opening, not a close arc through the benchmark stance.
	for d: Dictionary in decor.definitions.values():
		if not String(d["flag"]).is_empty(): state.set_flag(d["flag"],false)
	decor.resync(state)
	_main.get("chapters").timers.clear()
	# holdEcho claims an exclusive scripted scene, so the genuine decoration
	# guard correctly rejects every use. Suppress only ambient scheduling here.
	var horror: HorrorDirector = _main.get("horror")
	horror.cooldown = maxf(horror.cooldown,45.0)
	_main.get("haunt").hold(45.0)
	_main.get("startle").clear()
	var stances := {
		"decor-shed-cabinet": Vector2(6.75,11.70),
		"decor-snt-cabinet": Vector2(-16.3,-38.84),
		"decor-p07-barrel": Vector2(30.15,-59.9),
		"decor-p10-pump": Vector2(-25.15,-49.1),
		"decor-p09-radio": Vector2(7.1,-57.5),
		"decor-board-notice": Vector2(-31.5,-6.2),
		"decor-club-notice": Vector2(10.45,-26.15),
		"decor-snt-entry-notice": Vector2(35.05,-33.22),
		"decor-gate-p02": Vector2(27.528,-39.94),
		"decor-gate-p03": Vector2(35.528,-39.94),
		"decor-gate-p07": Vector2(27.528,-55.94),
		"decor-gate-p10": Vector2(-28.472,-51.06),
		"decor-gate-p14": Vector2(-1.472,-63.94)}
	var samples: Array[float] = []
	var cpu_process: Array[float] = []
	var cpu_physics: Array[float] = []
	var calls := 0
	var tris := 0
	for id: String in stances:
		var definition: Dictionary = decor.definitions[id]
		var kind: String = definition["kind"]
		var at: Vector2 = stances[id]
		var target: Vector3 = decor.definitions[id]["point"]
		var floor_y := 0.12 if id == "decor-shed-cabinet" else 0.035
		var delta := target-Vector3(at.x,floor_y+1.62,at.y)
		player.place(at.x,floor_y,at.y,atan2(-delta.x,-delta.z))
		player.pitch = atan2(delta.y,Vector2(delta.x,delta.z).length())
		player.pitch_target = player.pitch
		player.call("_apply_camera")
		var guard: Dictionary = _everyday_guard_state()
		var moving: Node3D = definition.get("moving")
		var original_rotation: Vector3 = moving.rotation if moving != null else Vector3.ZERO
		var started := Time.get_ticks_usec()
		var activated: bool = decor.use(id)
		if not activated: _failures.append("Decoration benchmark activation failed: " + id + " " + JSON.stringify(guard))
		var animation_started: bool = ui.reader.open if kind == "notice" else decor.radio_remaining > 0.0 if kind == "radio" else decor.animations.has(id)
		if activated and not animation_started: _failures.append("Decoration benchmark no runtime started: " + id)
		var pose_changed: bool = moving != null and moving.rotation != original_rotation
		var first_frame := true
		while Time.get_ticks_usec()-started < 1300000:
			var frame_start := started if first_frame else Time.get_ticks_usec()
			first_frame = false
			await process_frame
			if moving != null and moving.rotation != original_rotation: pose_changed = true
			samples.append(float(Time.get_ticks_usec()-frame_start)/1000.0)
			cpu_process.append(Performance.get_monitor(Performance.TIME_PROCESS)*1000.0)
			cpu_physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0)
			var stats: Dictionary = _main.get("render_chain").stats()
			calls = maxi(calls,int(stats.get("calls",0)))
			tris = maxi(tris,int(stats.get("tris",0)))
		ui.closeReader()
		var completed: bool = state.has(definition["flag"]) if kind in ["gate","cabinet","barrel","notice"] else not decor.animations.has(id) if kind == "pump" else decor.radio_remaining <= 0.0
		if activated and kind != "notice" and not pose_changed: _failures.append("Decoration benchmark moving pose unchanged: " + id)
		if activated and kind != "radio" and not completed: _failures.append("Decoration benchmark did not complete: " + id)
		_everyday_actions.append({"lap":lap,"id":id,"kind":kind,"activation":activated,
			"runtime_started":animation_started,"pose_changed":pose_changed if kind != "notice" else null,
			"completed":completed,"radio_seconds_remaining":decor.radio_remaining if kind == "radio" else null,
			"priority_guard":guard})
	decor.cancel_runtime()
	_record(lap+"-everyday",samples,calls,tris,cpu_process,cpu_physics)


func _everyday_guard_state() -> Dictionary:
	var ctx: Dictionary = _main.get("ctx")
	var state: GameState = _main.get("state")
	var horror: HorrorDirector = _main.get("horror")
	return {"chapter":state.chapter,"hidden":state.hidden,"capture_active":ctx["capture"].active(),
		"cutscene_playing":ctx["cutscene"].playing,"snt_exclusive":ctx["snt"].exclusive_runtime(),
		"outskirts_exclusive":ctx["outskirts"].exclusive_runtime(),"horror_exclusive":horror.exclusive(),
		"horror_owner":horror.owner,"horror_hold_left":horror.hold_left}

func _snt_scene(lap: String) -> void:
	var ctx: Dictionary = _main.get("ctx")
	var quest: Variant = ctx.get("snt")
	if quest == null:
		return
	var chapters: Chapters = _main.get("chapters")
	var state: GameState = _main.get("state")
	chapters.go("village", true)
	chapters.timers.clear()
	state.flags.erase("snt-booth-used")
	for flag: String in ["mill-clue", "snt-watch-read", "snt-yard-seen"]:
		state.set_flag(flag)
	quest.resync(state)
	var player: Player = _main.get("player")
	player.enabled = false
	player.place(8.07, 0.0, -66.3, 0.0)
	player.pitch = 0.0
	player.pitch_target = 0.0
	player.call("_apply_camera")
	_main.set("running", true)
	_main.get("weather").set_rain(0.85)
	quest.call("_signal", ctx)
	var samples: Array[float] = []
	var cpu_process: Array[float] = []
	var cpu_physics: Array[float] = []
	var calls := 0
	var tris := 0
	var started := Time.get_ticks_usec()
	while quest.exclusive_runtime() and Time.get_ticks_usec() - started < 20000000:
		var frame_start := Time.get_ticks_usec()
		await process_frame
		samples.append(float(Time.get_ticks_usec() - frame_start) / 1000.0)
		cpu_process.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		cpu_physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		var stats: Dictionary = _main.get("render_chain").stats()
		calls = maxi(calls, int(stats.get("calls", 0)))
		tris = maxi(tris, int(stats.get("tris", 0)))
	if samples.is_empty() or quest.exclusive_runtime():
		_failures.append("SNT scene failed to run/finish")
	else:
		_record(lap + "-snt-scene", samples, calls, tris, cpu_process, cpu_physics)
	quest.cancel_runtime()

func _capture_scene(lap: String) -> void:
	var ctx: Dictionary = _main.get("ctx")
	var capture: Variant = ctx.get("capture")
	var state: GameState = _main.get("state")
	state.chapter = "village"
	state.ending = null
	var player: Player = _main.get("player")
	player.place(0.0, 0.0, 2.0, 0.0)
	player.pitch = 0.0
	player.pitch_target = 0.0
	player.call("_apply_camera")
	var expected_eye: Vector3 = player.eyes()
	var chain: RenderChain = _main.get("render_chain")
	var trigger_eye: Vector3 = chain.camera.global_position
	var trigger: Dictionary = {"lap":lap,"expected_eye":[expected_eye.x,expected_eye.y,expected_eye.z],
		"trigger_eye":[trigger_eye.x,trigger_eye.y,trigger_eye.z],
		"player_feet":[player.feet().x,player.feet().y,player.feet().z],
		"eye_error_m":trigger_eye.distance_to(expected_eye)}
	trigger.merge(_current_camera_witness())
	_capture_triggers.append(trigger)
	if trigger_eye.distance_to(expected_eye) > 0.00001:
		_failures.append("Capture trigger camera differs from actual Player eyes: " + JSON.stringify(trigger))
	_main.set("running", true)
	ctx["catch_source"] = {"pos": Vector3(0, 0, -1.0)}
	if capture == null or not capture.begin("benchmark", false):
		_failures.append("Capture scene failed to start")
		return
	var samples: Array[float] = []
	var cpu_process: Array[float] = []
	var cpu_physics: Array[float] = []
	var calls := 0
	var tris := 0
	var geometry_peak: Dictionary = {}
	var started := Time.get_ticks_usec()
	while String(capture.phase) == "hit" and Time.get_ticks_usec() - started < 10000000:
		var frame_start := Time.get_ticks_usec()
		await process_frame
		samples.append(float(Time.get_ticks_usec() - frame_start) / 1000.0)
		cpu_process.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		cpu_physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		var stats: Dictionary = _main.get("render_chain").stats()
		calls = maxi(calls, int(stats.get("calls", 0)))
		if int(stats.get("tris",0)) > tris:
			geometry_peak = {"lap":lap,"phase":"capture","elapsed_s":float(frame_start-started)/1000000.0,"stats":stats}
			geometry_peak.merge(_current_camera_witness())
		tris = maxi(tris, int(stats.get("tris", 0)))
	_geometry_peaks.append(geometry_peak)
	if String(capture.phase) != "cellar":
		_failures.append("Capture scene failed to finish")
	else:
		_record(lap + "-capture", samples, calls, tris, cpu_process, cpu_physics)
	capture.cancel()

func _drive(lap: String) -> void:
	var chapters: Chapters = _main.get("chapters")
	var state: GameState = _main.get("state")
	state.chapter = "gate"
	state.ending = null
	var ctx: Dictionary = _main.get("ctx")
	# Capture leaves the Player in the cellar. Departure starts at the car's
	# normal outside approach, as in shots.gd, before Cutscene stores its camera.
	state.set_flag("gate-open")
	var player: Player = _main.get("player")
	player.place(1.1, 0.0, -5.6, PI)
	player.pitch = 0.0
	player.pitch_target = 0.0
	player.call("_apply_camera")
	var chain: RenderChain = _main.get("render_chain")
	var interact: Interact = _main.get("interact")
	var definition: Dictionary = {}
	for candidate: Dictionary in interact.list:
		if candidate.get("id", "") == "car-drive": definition = candidate; break
	var feet: Vector3 = player.feet()
	var capsule_clear := interact.occluder.capsule_hit(feet+Vector3.UP*(Player.RADIUS+0.01),
		feet+Vector3.UP*(player.height-Player.RADIUS),Player.RADIUS,CollisionWorld.ALL_SOLID).is_empty()
	var target: Variant = interact.find(chain.camera,state)
	var los := not definition.is_empty() and interact.visible(player.eyes(),definition["pos"],
		int(definition.get("los_mask",CollisionWorld.MASK_STATIC)))
	var trigger: Dictionary = {"lap":lap,"player_feet":[feet.x,feet.y,feet.z],
		"expected_eye":[player.eyes().x,player.eyes().y,player.eyes().z],
		"eye_error_m":chain.camera.global_position.distance_to(player.eyes()),
		"capsule_clear":capsule_clear,"line_of_sight":los,
		"interaction_target":String(target.get("id","")) if target is Dictionary else null,
		"target_position":[definition["pos"].x,definition["pos"].y,definition["pos"].z] if not definition.is_empty() else null}
	trigger.merge(_current_camera_witness())
	_departure_triggers.append(trigger)
	if not capsule_clear or not los or trigger["interaction_target"] != "car-drive" \
			or float(trigger["eye_error_m"]) > 0.00001:
		_failures.append("Departure trigger is not the ordinary clear car approach: " + JSON.stringify(trigger))
	chapters.call("_drive_away", ctx, "alone")
	var cut: Cutscene = _main.get("cutscene")
	var samples: Array[float] = []
	var cpu_process: Array[float] = []
	var cpu_physics: Array[float] = []
	var max_calls := 0
	var max_tris := 0
	var geometry_peak: Dictionary = {}
	var drive_started := Time.get_ticks_usec()
	while cut.playing:
		var started := Time.get_ticks_usec()
		await process_frame
		var ms := float(Time.get_ticks_usec() - started) / 1000.0
		var process_ms := Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		var physics_ms := Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		samples.append(ms)
		cpu_process.append(process_ms)
		cpu_physics.append(physics_ms)
		if ms > 50.0:
			var stall := {"lap": lap, "phase": "departure", "frame": samples.size() - 1,
				"elapsed_s": float(started - drive_started) / 1000000.0, "ms": ms,
				"process_ms": process_ms, "physics_ms": physics_ms, "from": "departure", "to": "departure"}
			stall.merge(_current_camera_witness())
			_route_stalls.append(stall)
		var stats: Dictionary = _main.get("render_chain").stats()
		max_calls = maxi(max_calls, int(stats.get("calls", 0)))
		if int(stats.get("tris",0)) > max_tris:
			geometry_peak = {"lap":lap,"phase":"departure","elapsed_s":float(started-drive_started)/1000000.0,"stats":stats}
			geometry_peak.merge(_current_camera_witness())
		max_tris = maxi(max_tris, int(stats.get("tris", 0)))
	_geometry_peaks.append(geometry_peak)
	_record(lap + "-departure", samples, max_calls, max_tris, cpu_process, cpu_physics)
	var ui: Overlays = _main.get("ui")
	# The ending card belongs to the measured scene. Dismiss it before lap two.
	for _i in 40:
		if ui.card.open:
			ui.advanceCard()
		await process_frame


func _current_camera_witness() -> Dictionary:
	var chain: RenderChain = _main.get("render_chain")
	var camera: Camera3D = chain.world_view.get_camera_3d()
	if camera == null: return {"camera":null,"position":null,"rotation":null}
	var position: Vector3 = camera.global_position
	var rotation: Vector3 = camera.global_rotation
	return {"camera":String(camera.get_path()),"position":[position.x,position.y,position.z],
		"rotation":[rotation.x,rotation.y,rotation.z]}


func _record(label: String, samples: Array[float], calls: int, tris: int,
		cpu_process: Array[float], cpu_physics: Array[float]) -> void:
	if samples.is_empty():
		_failures.append(label + ": no rendered frames")
		return
	var ordered := samples.duplicate()
	ordered.sort()
	_frame_samples[label] = samples
	var total := 0.0
	var stalls := 0
	for ms: float in samples:
		total += ms
		if ms > 50.0:
			stalls += 1
	var average := total / samples.size()
	var fps := 1000.0 / maxf(average, 0.001)
	var p95: float = ordered[mini(ordered.size() - 1, ceili(ordered.size() * 0.95) - 1)]
	var row := {"name": label, "frames": samples.size(), "average_fps": fps,
		"average_ms": average, "p95_ms": p95, "max_ms": ordered[-1],
		"frames_over_50_ms": stalls, "max_calls": calls, "max_triangles": tris,
		"process_monitor_ms": _monitor_summary(cpu_process),
		"physics_monitor_ms": _monitor_summary(cpu_physics)}
	_results.append(row)
	print("bench_route %s: avg_fps=%.2f p95_ms=%.3f max_ms=%.3f stalls=%d calls=%d tris=%d" % [label, fps, p95, ordered[-1], stalls, calls, tris])
	if fps < 60.0 or p95 > 16.7 or stalls > 0 or calls > 1600 or tris > 220000:
		_failures.append(label + ": " + JSON.stringify(row))


func _boot_ready(main: Node) -> bool:
	if main.get("chapters") == null:
		return false
	var ready: Variant = main.get("boot_ready")
	if ready != null:
		return bool(ready)
	# Old builds finish startup after chapters exists; wait for the loading screen.
	var ui: Node = main.get("ui")
	var loading: Control = ui.get("_load") if ui != null else null
	return loading != null and not loading.visible


func _monitor_summary(samples: Array[float]) -> Dictionary:
	if samples.is_empty():
		return {}
	var ordered := samples.duplicate()
	ordered.sort()
	return {"p95_ms": ordered[mini(ordered.size() - 1, ceili(ordered.size() * 0.95) - 1)],
		"max_ms": ordered[-1]}

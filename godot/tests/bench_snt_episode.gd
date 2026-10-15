## Непрерывный GPU маршрут СНТ. Холодный = первый проход после запуска процесса.
## Физическое прохождение проверяет test_snt_episode_geometry; здесь камера
## движется по тем же коридорам непрерывно, а обычный игровой цикл работает.
extends SceneTree

const ROUTE := [
	Vector3(36.8,0,-38.3),Vector3(27.5,0,-38.3),Vector3(27.5,0,-40.6),Vector3(27.5,0,-38.3),
	Vector3(12.2,0,-38.3),Vector3(12.2,0,-53.8),Vector3(-20,0,-53.8),
	Vector3(-20,0,-52),Vector3(-26,0,-52),Vector3(-28.5,0,-51),Vector3(-28.5,0,-49.45),
	Vector3(-28.5,0,-51),Vector3(-26,0,-52),Vector3(-20,0,-52),Vector3(-20,0,-53.8),
	Vector3(9,0,-53.8),Vector3(9,0,-57.5),Vector3(9,0.2,-58.0),Vector3(9,0,-57.5),
	Vector3(9,0,-53.8),Vector3(12.2,0,-53.8),Vector3(12.2,0,-38.3),
	Vector3(19,0,-38.3),Vector3(19,0,-40.2),Vector3(19,0,-38.3),
	Vector3(12.2,0,-38.3),Vector3(12.2,0,-53.8),Vector3(-20,0,-53.8),
	Vector3(-20,0,-61.8),Vector3(3.4,0,-61.8),Vector3(3.4,0,-64.1),Vector3(7.1,0,-64.1),
	Vector3(9.6,0,-66.5),Vector3(9.6,0,-74.5),Vector3(7.1,0,-74.5),Vector3(7.1,0,-78),
	Vector3(-12,0,-78),Vector3(-12,0,-82),Vector3(-34,0,-82),Vector3(-34,0,-78),
	Vector3(-52,0,-78),Vector3(-52,0,-65),Vector3(-55,0,-65),Vector3(-55,0,-54.5),
	Vector3(-44,0,-54.5),Vector3(-26,0,-54.5),Vector3(-28.5,0,-51),
]
const PURSUIT_INDEX := 23
var failures: Array[String] = []
var _seconds := 160.0
var _strict := false
var _out := "res://../output/episode/bench-route.json"
var _main: Node
var _forest_nodes: Array[ForestLodMesh] = []
var _forest_build_seen: Dictionary = {}
var _preview := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var size := Vector2i(1280,720)
	for arg: String in OS.get_cmdline_user_args():
		if arg == "--strict": _strict = true
		elif arg == "--repair-preview": _preview = true
		elif arg.begins_with("--output="): _out = arg.trim_prefix("--output=")
		elif arg.begins_with("--lap-seconds="): _seconds = maxf(90.0,float(arg.trim_prefix("--lap-seconds=")))
		elif arg.begins_with("--measure-size="):
			var parts := arg.trim_prefix("--measure-size=").split("x")
			size = Vector2i(int(parts[0]),int(parts[1]))
	if DisplayServer.get_name() == "headless":
		printerr("bench_snt_episode: real GPU required")
		quit(2)
		return
	root.mode = Window.MODE_WINDOWED
	root.borderless = true
	root.min_size = size
	root.size = size
	root.position = Vector2i.ZERO
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var boot := Time.get_ticks_usec()
	_main = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	for i in 3600:
		if bool(_main.get("boot_ready")): break
		await process_frame
	if not bool(_main.get("boot_ready")):
		printerr("bench_snt_episode: boot timeout")
		quit(1)
		return
	var boot_ms := float(Time.get_ticks_usec()-boot)/1000.0
	var corner_records: Array = _main.get_meta("boot_forest_corner_strip",[])
	if corner_records.size() != 32 or not bool(_main.get_meta("boot_occluded_forest_restored",false)):
		failures.append("forest corner warm coverage/restore incomplete")
	for record: Dictionary in corner_records:
		if not bool(record.get("forced_current_lod",false)) or int(record.get("draw",{}).get("calls",0)) <= 0:
			failures.append("forest corner actual draw incomplete")
	_main.call("_start_game")
	var ui: Overlays = _main.get("ui")
	for i in 90:
		if ui.card.open: ui.advanceCard()
		await process_frame
	if _preview: await _repair_previews()
	_main.get("chapters").go("arrive",true)
	var chain: RenderChain = _main.get("render_chain")
	for node: Node in SkinLayer._nodes(chain.world_root):
		if node is ForestLodMesh: _forest_nodes.append(node)
	chain.apply_preset("hq")
	if bool(_main.get("_frame_probe_on")):
		for viewport: Viewport in [root,chain.world_view,chain.hand_view]:
			RenderingServer.viewport_set_measure_render_time(viewport.get_viewport_rid(),true)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var results: Array = []
	for lap: String in ["cold","warm"]:
		results.append(await _lap(lap))
	var repeated_stalls: Array = []
	for cold: Dictionary in results[0]["stalls"]:
		for warm: Dictionary in results[1]["stalls"]:
			if int(cold["segment"]) == int(warm["segment"]) and not int(cold["segment"]) in repeated_stalls:
				repeated_stalls.append(int(cold["segment"]))
	if not repeated_stalls.is_empty(): failures.append("Frames above 50ms recur on cold/warm route segments: " + str(repeated_stalls))
	if root.size != size: failures.append("Window size changed")
	var report := {"gpu":RenderingServer.get_video_adapter_name(),"renderer":RenderingServer.get_current_rendering_method(),
		"label_warm_proof":_main.get_meta("boot_label_warm",{}),
		"forest_corner_warm_proof":_main.get_meta("boot_forest_corner_strip",[]),
		"warm_restore":_main.get_meta("boot_occluded_forest_restored",false),
		"warm_restore_differences":_main.get_meta("boot_world_restore_differences",[]),
		"window":[root.size.x,root.size.y],"buffer":chain.stats().get("buffer"),"boot_ms":boot_ms,
		"cold_definition":"first continuous route after boot; OS and driver caches retained",
		"route_definition":"continuous scripted camera; running game loop, rain, native threshold crossing, NPC and SntPursuit",
		"thresholds":{"average_fps_min":60,"p95_ms_max":16.7,"repeatable_frame_ms_max":50,"calls_max":1600,"triangles_max":220000},
		"strict":_strict,"results":results,"repeated_stall_segments":repeated_stalls,"failures":failures}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_out.get_base_dir()))
	var file := FileAccess.open(_out,FileAccess.WRITE)
	if file == null:
		printerr("bench_snt_episode: cannot write output")
		quit(1)
		return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	for failure in failures: print("bench_snt_episode target miss: ",failure)
	print("bench_snt_episode: %s" % ("PASS" if failures.is_empty() else "TARGET_MISS"))
	_main.queue_free()
	await process_frame
	quit(1 if _strict and not failures.is_empty() else 0)

func _repair_previews() -> void:
	var folder := _out.get_base_dir().path_join("review")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	var player: Player = _main.get("player")
	var ui: Overlays = _main.get("ui")
	var cut: Cutscene = _main.get("cutscene")
	if cut.playing: cut.update(6.0)
	player.release_lock()
	player.enabled = false
	_main.set_process(false)
	for i in 6: await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png(folder.path_join("store-arrival.png"))
	_main.get("chapters").go("arrive",true)
	_main.call("_ctx_set_door","door-front",true,true)
	var c: Dictionary = _main.get("ctx")
	var horror: HorrorDirector = c["horror"]
	var state: GameState = c["state"]
	c["scaresOn"] = func() -> bool: return true
	_main.call("_cancel_dialogue_runtime")
	ui._subTimer = 0.0
	ui.showHud(false)
	for pose: Array in [
		["house-entry-shadow","arrive",Vector3(-2.3,.45,6.8),Vector3(-2.3,.45,7.08),"veranda"],
		["house-roof-shadow","tapes",Vector3(-4.15,5.9,13.6),Vector3(-4.15,5.9,14.0),"roofspace"]]:
		state.chapter = pose[1]
		horror.invalidate()
		horror.cooldown = 0
		horror.hold_left = 0
		player.place(pose[2].x,pose[2].y,pose[2].z,PI)
		player.pitch = 0
		player.pitch_target = 0
		player.call("_apply_camera")
		horror.thresholds.sync_position()
		player.place(pose[3].x,pose[3].y,pose[3].z,PI)
		horror.thresholds.update(0.05,false)
		if not state.horror_seen.has(pose[0]): failures.append("preview: physical threshold failed " + pose[0])
		horror.thresholds.update(.30,false)
		var lights: LightRig = _main.get("lights")
		lights.powerOn = true
		lights.setLamp(pose[4],true)
		lights.update(1.0,player.camera.global_position,pose[4],false)
		_main.get("environment_occlusion").update()
		for i in 6: await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png(folder.path_join(String(pose[0])+".png"))
		horror.invalidate()
	_main.set_process(true)
	ui.showHud(true)

func _lap(name_: String) -> Dictionary:
	var c: Dictionary = _main.get("ctx")
	var state: GameState = c["state"]
	var player: Player = c["controls"]
	var ui: Overlays = c["ui"]
	var horror: HorrorDirector = c["horror"]
	var pursuit: SntPursuit = c["pursuit"]
	var lights: LightRig = _main.get("lights")
	var weather: Weather = _main.get("weather")
	var chain: RenderChain = _main.get("render_chain")
	_main.call("_cancel_dialogue_runtime")
	pursuit.cancel()
	horror.invalidate()
	state.chapter = "village"
	state.ending = null
	state.threatState = "absent"
	state.horror_seen.clear()
	for flag: String in ["snt-pursuit-escaped","snt-returned","snt-return-inspected","snt-pursuit-started","snt-nina-met"]:
		state.flags.erase(flag)
	for flag: String in ["mill-clue","snt-watch-read","snt-nina-greenhouse","snt-yard-seen","snt-semyon-met",
		"snt-pump-found","snt-pump-fixed","snt-filter-read","snt-route-known","snt-radio-set","snt-radio-heard","snt-booth-used"]:
		state.flags[flag] = true
	c["snt"].resync(state)
	state.flags["decor-gate-p02-open"] = true
	state.flags["decor-gate-p10-open"] = true
	_main.get("everyday").resync(state)
	c["scaresOn"] = func() -> bool: return true
	_main.get("chapters").timers.clear()
	_main.get("haunt").hold(_seconds+15.0)
	_main.get("startle").clear()
	_main.get("threat").set("speedScale",0.0)
	ui.showStartScreen(false)
	ui.showHud(true)
	player.release_lock()
	player.enabled = false
	_main.set("running",true)
	lights.set_night_immediate(0.9)
	lights.powerOn = true
	weather.set_rain(0.85)
	var lengths: Array[float] = [0.0]
	for i in ROUTE.size()-1: lengths.append(lengths[-1]+ROUTE[i].distance_to(ROUTE[i+1]))
	var samples: Array[float] = []
	var stalls: Array = []
	var max_calls := 0
	var max_tris := 0
	var pursued := false
	var render_history: Array = []
	var forest_history: Array = []
	var index := 0
	var begin := Time.get_ticks_usec()
	var elapsed := 0.0
	while elapsed < _seconds:
		var frame := Time.get_ticks_usec()
		var distance := clampf(elapsed/_seconds,0,1)*lengths[-1]
		while index < ROUTE.size()-2 and lengths[index+1] < distance: index += 1
		var blend := (distance-lengths[index])/maxf(lengths[index+1]-lengths[index],0.001)
		var pos: Vector3 = ROUTE[index].lerp(ROUTE[index+1],blend)
		var ahead: Vector3 = ROUTE[index+1]-ROUTE[index]
		var heading := atan2(-ahead.x,-ahead.z)
		# Turn before a corner instead of teleporting orientation at a waypoint.
		if index < ROUTE.size()-2 and blend > 0.75:
			var after: Vector3 = ROUTE[index+2]-ROUTE[index+1]
			heading = lerp_angle(heading,atan2(-after.x,-after.z),(blend-0.75)*4.0)
		player.place(pos.x,pos.y,pos.z,heading+sin(elapsed*0.75)*0.12)
		player.pitch = sin(elapsed*0.43)*0.065
		player.pitch_target = player.pitch
		player.call("_apply_camera")
		if not pursued and index >= PURSUIT_INDEX:
			pursued = pursuit.begin()
		await process_frame
		var ms := float(Time.get_ticks_usec()-frame)/1000.0
		samples.append(ms)
		var stats := chain.stats()
		var forest_builds: Array = []
		for tree: ForestLodMesh in _forest_nodes:
			var id := tree.get_instance_id()
			if int(_forest_build_seen.get(id,0)) != tree._mixed_builds:
				forest_builds.append({"node":String(tree.get_path()),"builds":tree._mixed_builds,
					"build_usec":tree._last_build_usec,"max_build_usec":tree._max_build_usec})
				_forest_build_seen[id] = tree._mixed_builds
		forest_history.append(forest_builds)
		if forest_history.size() > 4: forest_history.pop_front()
		if bool(_main.get("_frame_probe_on")):
			var occlusion: Node = _main.get("environment_occlusion")
			var frame_render := {"setup_ms":RenderingServer.get_frame_setup_time_cpu(),
				"occlusion":(occlusion.get("report") as Dictionary).duplicate() if occlusion != null else {}}
			frame_render["occlusion"].erase("plane_records")
			frame_render["occlusion"].erase("source_records")
			for viewport: Viewport in [root,chain.world_view,chain.hand_view]:
				var rid := viewport.get_viewport_rid()
				frame_render[String(viewport.name)] = {"cpu_ms":RenderingServer.viewport_get_measured_render_time_cpu(rid),
					"gpu_ms":RenderingServer.viewport_get_measured_render_time_gpu(rid)}
			render_history.append(frame_render)
			if render_history.size() > 4: render_history.pop_front()
			for recent: Dictionary in stalls:
				if recent.get("render_after",[]).size() < 4:
					recent.get("render_after").append(frame_render.duplicate(true))
		max_calls = maxi(max_calls,int(stats.get("calls",0)))
		max_tris = maxi(max_tris,int(stats.get("tris",0)))
		if ms > 50.0:
			var stall := {"ms":ms,"segment":index,"position":[pos.x,pos.y,pos.z]}
			stall["forest_build_history"] = forest_history.duplicate(true)
			if bool(_main.get("_frame_probe_on")):
				stall["main_cpu_ms"] = (_main.get("_frame_probe") as Dictionary).duplicate()
				stall["collision_revision"] = c["col"].revision
				stall["path_cache_revision"] = pursuit._cache_revision
				stall["walker_position"] = [pursuit.position.x,pursuit.position.y,pursuit.position.z]
				stall["render_history"] = render_history.duplicate(true)
				stall["render_after"] = []
				print("PROFILE STALL ", JSON.stringify(stall))
			stalls.append(stall)
		elapsed = float(Time.get_ticks_usec()-begin)/1000000.0
	var sorted := samples.duplicate()
	sorted.sort()
	var sum := 0.0
	for ms: float in samples: sum += ms
	var avg := sum/maxf(samples.size(),1)
	var p95: float = sorted[mini(sorted.size()-1,int(sorted.size()*0.95))]
	var seen: Array = []
	for key: String in state.horror_seen:
		if String(key).begins_with("snt-"): seen.append(key)
	if not stalls.is_empty(): failures.append(name_+": frames above 50ms: "+str(stalls.size()))
	if not pursued: failures.append(name_+": pursuit did not begin")
	if pursued and not state.has("snt-pursuit-escaped"): failures.append(name_+": pursuit did not reach an escape")
	if seen.is_empty(): failures.append(name_+": no runtime threshold event shown")
	if 1000.0/avg < 60.0: failures.append(name_+": average FPS below 60")
	if p95 > 16.7: failures.append(name_+": p95 above 16.7ms")
	if max_calls > 1600 or max_tris > 220000: failures.append(name_+": geometry budget exceeded")
	return {"name":name_,"frames":samples.size(),"average_fps":1000.0/avg,"p95_ms":p95,
		"max_ms":sorted[-1],"max_calls":max_calls,"max_triangles":max_tris,"stalls":stalls,
		"threshold_events":seen,"pursuit_started":pursued,"pursuit_escaped":state.has("snt-pursuit-escaped"),
		"frame_samples_ms":samples,"route_distance_m":lengths[-1]}

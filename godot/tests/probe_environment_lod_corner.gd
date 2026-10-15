## Diagnostic only: short camera route with per-owner CPU/LOD/shadow counters.
## Run with --profile-environment-lod --frame-profile; not an FPS acceptance run.
extends SceneTree

const ROUTE := [Vector3(-6,0,-78),Vector3(-12,0,-78),Vector3(-12,0,-82),Vector3(-18,0,-82)]
var _main: Node
var _owners: Array[EnvironmentLod] = []
var _switch_seen: Dictionary = {}
var _out := "res://../output/episode/probe-environment-lod-corner-before.json"
var _hide_labels := false

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name()=="headless" or not EnvironmentLod._profile_enabled:
		printerr("probe requires real GPU and --profile-environment-lod")
		quit(2)
		return
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): _out=arg.trim_prefix("--output=")
		elif arg=="--hide-labels": _hide_labels=true
	root.mode=Window.MODE_WINDOWED
	root.borderless=true
	root.min_size=Vector2i(1280,720)
	root.size=Vector2i(1280,720)
	root.position=Vector2i.ZERO
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	_main=(load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	for i in 1800:
		if bool(_main.get("boot_ready")): break
		await process_frame
	if not bool(_main.get("boot_ready")):
		printerr("probe boot timeout")
		quit(1)
		return
	var chain: RenderChain=_main.get("render_chain")
	var startup_preset := {"after_boot":chain.render_preset(),"hq_after_boot":Materials.render_hq_enabled}
	_main.call("_start_game")
	startup_preset["after_start_game"]=chain.render_preset()
	var ui: Overlays=_main.get("ui")
	for i in 90:
		if ui.card.open: ui.advanceCard()
		await process_frame
	startup_preset["before_probe_hq"]=chain.render_preset()
	chain.apply_preset("hq")
	startup_preset["after_probe_hq"]=chain.render_preset()
	for node: Node in SkinLayer._nodes(chain.world_root):
		if node is EnvironmentLod:
			_owners.append(node)
			_switch_seen[node.get_instance_id()]=node._profile_level_switches
	var c: Dictionary=_main.get("ctx")
	var state: GameState=c["state"]
	_main.call("_cancel_dialogue_runtime")
	c["pursuit"].cancel()
	c["horror"].invalidate()
	state.chapter="village"
	state.ending=null
	state.threatState="absent"
	state.flags["snt-booth-used"]=true
	c["snt"].resync(state)
	_main.get("threat").set("speedScale",0.0)
	ui.showStartScreen(false)
	ui.showHud(true)
	var player: Player=c["controls"]
	player.release_lock()
	player.enabled=false
	_main.set("running",true)
	var lights: LightRig=_main.get("lights")
	lights.set_night_immediate(.9)
	lights.powerOn=true
	_main.get("weather").set_rain(.85)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var labels: Array=[]
	for node: Node in SkinLayer._nodes(chain.world_root):
		if not node is Label3D and not node is Sprite3D: continue
		var label_ := node as GeometryInstance3D
		labels.append({"node":String(node.get_path()),"kind":node.get_class(),
			"position":[label_.global_position.x,label_.global_position.y,label_.global_position.z],
			"layers":label_.layers,"range_end":label_.visibility_range_end,
			"text":(node as Label3D).text if node is Label3D else ""})
		if _hide_labels: label_.layers=0
	print("corner labels=",labels.size()," hidden=",_hide_labels," user_data=",OS.get_user_data_dir())
	var before := _global_stats()
	var results: Array=[]
	for lap: String in ["cold","warm"]:
		results.append(await _lap(lap,player,chain))
	var report := {"diagnostic_only":true,"gpu":RenderingServer.get_video_adapter_name(),
		"owners":_owners.size(),"boot_counters":before,"final_counters":_global_stats(),"results":results,
		"hide_labels":_hide_labels,"labels":labels,"user_data_dir":OS.get_user_data_dir(),"startup_preset":startup_preset}
	var file := FileAccess.open(_out,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("environment corner probe ",_out," owners=",_owners.size()," final=",JSON.stringify(_global_stats()))
	_main.queue_free()
	await process_frame
	quit()

func _global_stats() -> Dictionary:
	return {"process_usec":EnvironmentLod._profile_process_usec,"shadow_builds":EnvironmentLod._profile_shadow_builds,
		"shadow_build_usec":EnvironmentLod._profile_shadow_build_usec,"shadow_max_usec":EnvironmentLod._profile_shadow_max_usec}

func _lap(label_: String,player: Player,chain: RenderChain) -> Dictionary:
	var lengths: Array[float]=[0.0]
	for i in ROUTE.size()-1: lengths.append(lengths[-1]+ROUTE[i].distance_to(ROUTE[i+1]))
	var frames: Array=[]
	var stalls: Array=[]
	var history: Array=[]
	var previous := _global_stats()
	var start := Time.get_ticks_usec()
	var elapsed := 0.0
	var segment := 0
	while elapsed < 8.0:
		var frame := Time.get_ticks_usec()
		var distance := clampf(elapsed/8.0,0,1)*lengths[-1]
		while segment<ROUTE.size()-2 and lengths[segment+1]<distance: segment+=1
		var blend := (distance-lengths[segment])/(lengths[segment+1]-lengths[segment])
		var point: Vector3=ROUTE[segment].lerp(ROUTE[segment+1],blend)
		var ahead: Vector3=ROUTE[segment+1]-ROUTE[segment]
		var heading := atan2(-ahead.x,-ahead.z)
		if segment<ROUTE.size()-2 and blend>.75:
			var after: Vector3=ROUTE[segment+2]-ROUTE[segment+1]
			heading=lerp_angle(heading,atan2(-after.x,-after.z),(blend-.75)*4)
		player.place(point.x,point.y,point.z,heading+sin(elapsed*.75)*.12)
		player.pitch=sin(elapsed*.43)*.065
		player.pitch_target=player.pitch
		player.call("_apply_camera")
		await process_frame
		var ms := (Time.get_ticks_usec()-frame)/1000.0
		var now := _global_stats()
		var changed: Array=[]
		var slowest: EnvironmentLod
		for owner_: EnvironmentLod in _owners:
			if slowest==null or owner_._profile_last_process_usec>slowest._profile_last_process_usec: slowest=owner_
			var id := owner_.get_instance_id()
			if int(_switch_seen.get(id,0))!=owner_._profile_level_switches:
				changed.append({"node":String(owner_.get_path()),"level":owner_.current_level,
					"cpu_usec":owner_._profile_last_process_usec,"frame":owner_._profile_last_process_frame,
					"medium":owner_.levels[1].resource_path})
				_switch_seen[id]=owner_._profile_level_switches
		var render := chain.stats()
		var row := {"ms":ms,"point":[point.x,point.z],"heading":heading,"segment":segment,
			"lod_cpu_usec":int(now.process_usec)-int(previous.process_usec),
			"shadow_builds":int(now.shadow_builds)-int(previous.shadow_builds),
			"shadow_usec":int(now.shadow_build_usec)-int(previous.shadow_build_usec),
			"shadow_last_source":EnvironmentLod._profile_shadow_last_source,"switches":changed,
			"slowest_node":String(slowest.get_path()),"slowest_usec":slowest._profile_last_process_usec,
			"calls":render.get("calls",0),"tris":render.get("tris",0),
			"main_cpu":(_main.get("_frame_probe") as Dictionary).duplicate()}
		frames.append(row)
		history.append(row)
		if history.size()>4: history.pop_front()
		if ms>50.0:
			stalls.append({"ms":ms,"point":[point.x,point.z],"history":history.duplicate(true)})
			print("corner stall ",label_," ",ms,"ms point=",point," lod_cpu=",row.lod_cpu_usec," shadow=",row.shadow_usec," switches=",JSON.stringify(changed))
		previous=now
		elapsed=(Time.get_ticks_usec()-start)/1000000.0
	return {"name":label_,"frames":frames,"stalls":stalls}

## Одинаковые постановочные кадры. Запуск с реальным GPU, по одному разрешению.
## --capture-size=1280x720|1600x900|1920x1080|2560x1440 --filter=nina,forest-gate
extends SceneTree

const SIZES := [Vector2i(1280,720),Vector2i(1600,900),Vector2i(1920,1080),Vector2i(2560,1440)]
# Match five historical cameras exactly; other views document the new episode.
const MATCHED_CAMERAS := {
    "balcony": [0.0,0.02], "third-line": [PI*0.5,0.02],
    "lane-lamp": [PI*0.75,0.14], "car-sedan": [PI*0.70,-0.10],
    "car-uaz": [-PI*0.70,-0.02],
}
const VIEWS := [
	["balcony",Vector3(-2.4,3.3,8.1),Vector3(-2.4,4.0,-12),""],
	["third-line",Vector3(36.8,0,-38.3),Vector3(20,1.5,-38.4),""],
	["fourth-line",Vector3(-16,0,-53.8),Vector3(-30,1.5,-53.8),""],
	["nina",Vector3(27.5,0,-39.8),Vector3(27.5,1.4,-42.4),"nina"],
	["nina-greenhouse",Vector3(30.3,0,-44.8),Vector3(30.3,1.3,-46.8),"greenhouse"],
	["nina-shutter",Vector3(27.5,0,-39.8),Vector3(28.75,1.55,-43.04),"shutter"],
	["semyon",Vector3(-28.5,0,-51.8),Vector3(-28.5,1.25,-49.25),""],
	["pump",Vector3(-25.25,0,-49.8),Vector3(-26,0.85,-49.0),"pump"],
	["radio",Vector3(8.4,0.2,-58.0),Vector3(7.1,0.7,-58.86),""],
	["zuev-window",Vector3(9,0.2,-58.35),Vector3(10.75,1.55,-60.21),"zuev"],
	["forest-gate",Vector3(9.6,0,-69),Vector3(9.6,1.6,-73.2),""],
	["forest-north",Vector3(7.1,0,-78),Vector3(-15,1.55,-78),""],
	["forest-branches",Vector3(-12,0,-78),Vector3(-22,1.55,-80),""],
	["forest-west",Vector3(-52,0,-62),Vector3(-53.5,1.55,-54.5),""],
	["forest-crossing",Vector3(7.1,0,-75),Vector3(7.1,1.2,-76.6),"crossing"],
	["walker-peek",Vector3(19,0,-39.8),Vector3(19,1.25,-41.65),"peek"],
	["walker-chase",Vector3(19,0,-39.0),Vector3(19,1.25,-41.65),"chase"],
	["walker-capture",Vector3(19,0,-40.45),Vector3(19,1.45,-41.65),"capture"],
	["stairs-window",Vector3(-2.90,3.3,12.68),Vector3(2.38,4.58,11.80),"stairs"],
	["mill-head-hand",Vector3(22.1,8.3,-27.46),Vector3(19.95,9.66,-29.45),"mill"],
	["lane-lamp",Vector3(-25,0,-19.5),Vector3(-28,2.8,-16.5),""],
	["entry-lamp",Vector3(36.8,0,-34.2),Vector3(36.8,2.8,-39),""],
	["car-sedan",Vector3(24.8,0,-38.3),Vector3(17.5,0.85,-36.95),""],
	["car-uaz",Vector3(26.5,0,-38.3),Vector3(30.7,0.85,-36.95),""],
]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var dimensions := SIZES[0]
	var output := "res://../output/episode/review"
	var filter := ""
	var mode := "dusk"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--capture-size="):
			var xy := arg.trim_prefix("--capture-size=").split("x")
			dimensions = Vector2i(int(xy[0]),int(xy[1]))
		elif arg.begins_with("--output="): output = arg.trim_prefix("--output=")
		elif arg.begins_with("--filter="): filter = arg.trim_prefix("--filter=")
		elif arg.begins_with("--mode="): mode = arg.trim_prefix("--mode=")
	if DisplayServer.get_name() == "headless" or not dimensions in SIZES:
		printerr("shots_snt_episode: real GPU and one of four review sizes required")
		quit(2)
		return
	output = output.path_join("%dx%d" % [dimensions.x,dimensions.y])
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	root.mode = Window.MODE_WINDOWED
	root.borderless = true
	root.min_size = dimensions
	root.size = dimensions
	root.position = Vector2i.ZERO
	var main: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 1800:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		printerr("shots_snt_episode: boot timeout")
		quit(1)
		return
	main.call("_start_game")
	var ui: Overlays = main.get("ui")
	for i in 90:
		if ui.card.open: ui.advanceCard()
		await process_frame
	main.set("running",false)
	main.get("chapters").go("arrive",true)
	main.set_process(false)
	var ctx: Dictionary = main.get("ctx")
	var state: GameState = ctx["state"]
	var actors: SntEpisodeActors = ctx["episodeActors"]
	var player: Player = ctx["controls"]
	var lights: LightRig = main.get("lights")
	var chain: RenderChain = main.get("render_chain")
	chain.apply_preset("hq")
	player.release_lock()
	player.enabled = false
	ui.showHud(false)
	main.get("weather").clear()
	var rows: Array = []
	for view: Array in VIEWS:
		if filter != "" and not String(view[0]) in filter.split(","): continue
		state.chapter = "village"
		state.flags["snt-booth-used"] = true
		state.flags.erase("snt-nina-met")
		state.flags.erase("snt-pump-fixed")
		state.flags.erase("snt-filter-read")
		if String(view[3]) == "greenhouse": state.flags["snt-nina-met"] = true
		if String(view[3]) == "pump":
			state.flags["snt-pump-fixed"] = true
			state.flags["snt-filter-read"] = true
		ctx["snt"].resync(state)
		for who: String in ["walker","window_face"]:
			actors.end_action(who)
			actors.show(who,false)
		var eye: Vector3 = view[1] + Vector3.UP * 1.62
		_pose(ctx,actors,String(view[3]),eye)
		lights.set_night_immediate(0.15 if mode == "dusk" else 1.0)
		lights.powerOn = mode != "blackout"
		for id: String in lights.state: lights.setLamp(id,true)
		var feet: Vector3 = view[1]
		var delta: Vector3 = view[2] - eye
		player.place(feet.x,feet.y,feet.z,atan2(-delta.x,-delta.z))
		player.pitch = atan2(delta.y,Vector2(delta.x,delta.z).length())
		if MATCHED_CAMERAS.has(String(view[0])):
			var angles: Array = MATCHED_CAMERAS[String(view[0])]
			player.place(feet.x,feet.y,feet.z,float(angles[0]))
			player.pitch = float(angles[1])
		player.pitch_target = player.pitch
		player.call("_apply_camera")
		for i in 40:
			lights.update(1.0/60.0,chain.camera.global_position,"street",true)
			await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		var file := "%s-%s.png" % [view[0],mode]
		if img.get_size() != dimensions or img.save_png(output.path_join(file)) != OK:
			printerr("shots_snt_episode: invalid capture ",file," size=",img.get_size())
			quit(1)
			return
		rows.append({"file":file,"feet":[feet.x,feet.y,feet.z],"window":[root.size.x,root.size.y],
			"image":[img.get_width(),img.get_height()],"yaw":player.yaw,"pitch":player.pitch,"matched_historical_camera":MATCHED_CAMERAS.has(String(view[0])),"stats":chain.stats(),"posed_reference":true,"buffer":chain.stats().get("buffer"),"capture":"window output; HQ internal buffer retains 1280x720 cap"})
	var manifest := output.path_join("captures-%s.json" % mode)
	if filter != "" and FileAccess.file_exists(manifest):
		var old: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest))
		if old is Array:
			var updated: Array = rows.map(func(row: Dictionary) -> String: return row["file"])
			for row: Dictionary in old:
				if not row["file"] in updated: rows.append(row)
	var file := FileAccess.open(manifest,FileAccess.WRITE)
	file.store_string(JSON.stringify(rows,"\t"))
	file.close()
	print("shots_snt_episode: PASS captures=%d size=%s mode=%s" % [rows.size(),dimensions,mode])
	main.queue_free()
	await process_frame
	quit(0)

func _pose(ctx: Dictionary, actors: SntEpisodeActors, mode: String, eye: Vector3) -> void:
	var who := ""
	var at := Vector3.ZERO
	var action := "peek"
	match mode:
		"zuev": who = "window_face"; at = Vector3(10.75,1.55,-60.21)
		"stairs": who = "window_face"; at = Vector3(2.38,4.58,11.80)
		"mill": who = "window_face"; at = Vector3(19.95,9.66,-29.45)
		"crossing": who = "walker"; at = Vector3(7.1,0,-76.6); action = "run"
		"peek", "chase", "capture": who = "walker"; at = Vector3(19,0,-41.65); action = mode
	if who != "":
		actors.place(who,at.x,at.y,at.z)
		actors.face(who,eye.x,eye.z)
		actors.show(who,true)
		actors.begin_action(who,action)
		actors.sample_action(who,action,0.55)
	if mode == "shutter":
		var world: Dictionary = ctx["world"]
		var snt: Dictionary = world.get("snt",{})
		var node: Node3D = snt.get("nodes",{}).get("snt-nina-shutter")
		if node != null: node.rotation.y = -1.45

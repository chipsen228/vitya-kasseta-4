# Съёмка одинаковых камер для старой и новой сборки. Только локальные ресурсы.
extends SceneTree

const VIEWS := [
	["balcony", Vector3(-2.4, 3.3, 8.1), 0.0, 0.02],
	["neighbours-west", Vector3(-8.4, 0, -3.4), 0.3, 0.04],
	["neighbours-east", Vector3(15.6, 0, -3.6), 0.0, 0.04],
	["second-line", Vector3(-18, 0, -21), PI * 0.5, 0.04],
	["lane-lamp", Vector3(-25, 0, -19.5), PI * .75, .14],
	["entry-lamp", Vector3(36.8, 0, -33.0), 0.0, 0.12],
	["third-line", Vector3(36.8, 0, -38.3), PI * 0.5, 0.02],
	["p01", Vector3(19, 0, -38.6), 0.0, 0.04],
	["p01-return", Vector3(19, 0, -40.2), 0.0, -0.12],
	["car-sedan", Vector3(24.8, 0, -38.3), PI * .70, -0.10],
	["car-wagon", Vector3(3.8, 0, -54.2), -PI * 0.75, -0.10],
	["car-uaz", Vector3(26.5, 0, -38.3), -PI * 0.70, -0.02],
	["fourth-line", Vector3(4, 0, -53.8), PI * 0.5, 0.02],
	["lake", Vector3(-4, 0, -53.6), PI, 0.02],
	["last-line", Vector3(-18.5, 0, -61.8), -PI * 0.5, 0.02],
	["booth", Vector3(7.1, 0, -65.2), 0.0, 0.04],
	["office", Vector3(4.4, 0, -34.95), 0.0, 0.03],
	["office-inside", Vector3(4.4, 0, -37.35), 0.0, -0.40],
	["booth-silhouette", Vector3(8.07, 0, -66.3), 0.0, 0.0],
	["shower-clearance", Vector3(9.9, 0, 15.7), PI * 0.72, 0.02],
	["privy", Vector3(8.6, 0, 19.0), PI, 0.02],
	["p05", Vector3(8.3, 0, -42.1), PI * 0.12, 0.02],
	["kitchen-detail", Vector3(-0.4, 0.45, 11.4), PI, -0.05],
	["vitya-model", Vector3(0.0, 0.0, 0.25), PI, -0.04],
	["vitya-run", Vector3(0.0, 0.0, 0.25), PI, -0.04],
	["vitya-shovel", Vector3(0.0, 0.0, 0.25), PI, -0.04],
]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var out := "res://../output/last-round/matrix"
	var filter := ""
	var dimensions := Vector2i(1280,720)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--output="):
			out = arg.trim_prefix("--output=")
		if arg.begins_with("--capture-size="):
			var parts := arg.trim_prefix("--capture-size=").split("x")
			dimensions = Vector2i(int(parts[0]), int(parts[1]))
		if arg.begins_with("--filter="):
			filter = arg.trim_prefix("--filter=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	root.mode = Window.MODE_WINDOWED
	root.borderless = true
	root.min_size = dimensions
	root.size = dimensions
	root.position = Vector2i.ZERO
	await process_frame
	await process_frame
	if root.size != dimensions:
		printerr("shots_last_round: FAIL requested window ", dimensions, " got ", root.size)
		quit(1)
		return
	var main: Node = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 1800:
		if bool(main.get("boot_ready")):
			break
		await process_frame
	if not bool(main.get("boot_ready")):
		printerr("shots_last_round: FAIL boot")
		quit(1)
		return
	main.call("_start_game")
	var ui: Variant = main.get("ui")
	for i in 90:
		if ui.card.open:
			ui.advanceCard()
		await process_frame
	main.set("running", false)
	main.set_process(false)
	var ctx: Dictionary = main.get("ctx")
	var state: Variant = main.get("state")
	var lights: Variant = main.get("lights")
	var player: Variant = main.get("player")
	var chain: Variant = main.get("render_chain")
	chain.apply_preset("hq")
	player.release_lock()
	main.get("weather").clear()
	ui.showHud(false)
	var rows: Array = []
	# Filtered recaptures replace matching files while retaining the other views.
	if not filter.is_empty():
		var previous: Variant = JSON.parse_string(FileAccess.get_file_as_string(out.path_join("captures.json"))) \
			if FileAccess.file_exists(out.path_join("captures.json")) else null
		if previous is Array:
			for row: Variant in previous:
				if row is Dictionary and row.has("file"):
					rows.append(row)
	for mode: String in ["dusk", "night", "blackout"]:
		for view: Array in VIEWS:
			if not filter.is_empty() and not String(view[0]) in filter.split(","):
				continue
			var runtime: Variant = ctx.get("snt")
			if runtime != null:
				state.chapter = "village"
				state.flags.erase("snt-booth-used")
				if String(view[0]) == "p01-return":
					state.flags["snt-booth-used"] = true
				runtime.resync(state)
				if String(view[0]) == "booth-silhouette":
					for flag: String in ["mill-clue", "snt-watch-read", "snt-yard-seen"]:
						state.set_flag(flag)
					runtime.call("_signal", ctx)
					runtime.update(3.5)
			lights.set_night_immediate(0.10 if mode == "dusk" else 1.0)
			lights.powerOn = mode != "blackout"
			for id: String in lights.state:
				lights.setLamp(id, true)
			var actors: Variant = main.get("actors")
			actors.end_action("threat")
			var actor_view := String(view[0]).begins_with("vitya-")
			actors.show("threat", actor_view)
			if actor_view:
				actors.place("threat", 0.0, 0.0, 3.2)
				actors.face("threat", 0.0, 0.25)
				if String(view[0]) == "vitya-run":
					actors.begin_action("threat", "run")
					actors.sample_action("threat", "run", 0.12)
				if String(view[0]) == "vitya-shovel":
					actors.begin_action("threat", "shovel")
					actors.sample_action("threat", "shovel", 0.55)
			var pos: Vector3 = view[1]
			player.place(pos.x, pos.y, pos.z, float(view[2]))
			player.pitch = float(view[3])
			player.pitch_target = player.pitch
			player.call("_apply_camera")
			for i in 40:
				lights.update(1.0 / 60.0, chain.camera.global_position, "street", true)
				await process_frame
			await RenderingServer.frame_post_draw
			var img: Image = chain.post_view.get_texture().get_image()
			var file := "%s-%s.png" % [view[0], mode]
			if img.save_png(out.path_join(file)) != OK:
				printerr("shots_last_round: FAIL save " + file)
				quit(1)
				return
			var record := {"file": file, "window": [root.size.x, root.size.y], "image": [img.get_width(), img.get_height()], "stats": chain.stats()}
			var replaced := false
			for index in rows.size():
				if String(rows[index].get("file", "")) == file:
					rows[index] = record
					replaced = true
					break
			if not replaced:
				rows.append(record)
	var f := FileAccess.open(out.path_join("captures.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(rows, "\t"))
	print("shots_last_round: PASS %d captures" % rows.size())
	main.queue_free()
	await process_frame
	await process_frame
	quit(0)

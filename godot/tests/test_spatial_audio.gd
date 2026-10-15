extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var errors: Array[String] = []
	var audio := GameAudio.new()
	root.add_child(audio)
	var world := Node3D.new()
	root.add_child(world)
	var listener := Camera3D.new()
	world.add_child(listener)
	listener.current = true
	await process_frame
	audio.bind_spatial_world(world)
	var pool: Array = audio.get("_spatial_pool")
	if pool.size() != 8 or GameAudio.SPATIAL_LOOP_VOICES != 2:
		errors.append("spatial source budget")
	if not audio.spatial_loop("horror-amb-house", Vector3.ZERO, true):
		errors.append("house loop missing")
	if not audio.spatial_loop("horror-amb-cellar", Vector3.ONE, true):
		errors.append("cellar loop missing")
	if audio.spatial_loop("horror-amb-shore", Vector3.ZERO, true):
		errors.append("third loop exceeded budget")
	for i in 10:
		if not audio.spatial_sfx("horror-run-wood", Vector3(i, 0, 0)):
			errors.append("shot missing")
	if (audio.get("_spatial_loop_names") as Array) != ["horror-amb-house", "horror-amb-cellar"]:
		errors.append("shots stole ambient voices")
	await physics_frame
	await physics_frame
	audio.set_spatial_paused(true)
	for voice: AudioStreamPlayer3D in pool:
		if not voice.stream_paused:
			errors.append("unpaused spatial voice")
	audio.set_spatial_paused(false)
	audio.set_volume(0.25)
	if not is_equal_approx(audio.volume, 0.25):
		errors.append("user volume ignored")
	audio.clear_spatial()
	await physics_frame
	for voice: AudioStreamPlayer3D in pool:
		if voice.playing:
			errors.append("voice survived cleanup")
	if audio.get("_spatial_loop_names") != ["", ""]:
		errors.append("loop reservation survived cleanup")
	audio.queue_free()
	world.queue_free()
	await process_frame
	for error: String in errors:
		printerr(error)
	print("test_spatial_audio: ", "PASS" if errors.is_empty() else "FAIL")
	quit(0 if errors.is_empty() else 1)

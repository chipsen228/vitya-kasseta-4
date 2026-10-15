# Windowed pixel check for both compose shaders; a headless pass is invalid.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("test_vhs_compose: FAIL requires real rendering")
		quit(2)
		return
	var errors: Array[String] = []
	root.size = Vector2i(1280,720)
	var chain := RenderChain.new()
	root.add_child(chain)
	chain.set_hands_visible(false)
	chain.world_env.background_color = Color(0.48,0.37,0.29)
	for preset: String in ["hq", "retro"]:
		chain.apply_preset(preset)
		chain.set_tracking(0.0)
		chain.set_fade(1.0)
		var frames: Array[PackedByteArray] = []
		for amount: float in [0.0,0.3,1.0]:
			chain.set_vhs_amount(amount)
			for _i in 5:
				await process_frame
			await RenderingServer.frame_post_draw
			var captured := chain.post_view.get_texture().get_image()
			captured.convert(Image.FORMAT_RGBA8)
			frames.append(captured.get_data())
		if frames[0] == frames[1] or frames[1] == frames[2]:
			errors.append(preset+": VHS strength does not change rendered pixels")
		chain.set_tracking(0.8)
		chain.set_fade(0.4)
		chain.set_vhs_amount(0.0)
		chain.apply_preset("retro" if preset == "hq" else "hq")
		if not is_equal_approx(float(chain.get_vhs("tracking")),0.8) or not is_equal_approx(chain.get_fade(),0.4):
			errors.append(preset+": strength/preset erased story effects")
	RenderChain.set_shader_global("flashlight_on",0.0)
	if float(RenderChain.get_shader_global("flashlight_on")) != 0.0:
		errors.append("shader global cache mismatch")
	chain.queue_free()
	await process_frame
	for error: String in errors:
		printerr(error)
	print("test_vhs_compose: ","PASS" if errors.is_empty() else "FAIL", " (real pixels HQ/Retro; story uniform preservation)")
	quit(0 if errors.is_empty() else 1)

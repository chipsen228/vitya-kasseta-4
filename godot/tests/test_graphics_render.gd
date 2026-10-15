extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var errors: Array[String] = []
	var chain := RenderChain.new()
	root.add_child(chain)
	chain.apply_preset("hq")
	for size: Vector2i in [Vector2i(1280,720), Vector2i(1600,900), Vector2i(1920,1080), Vector2i(2560,1440)]:
		root.size = size
		await process_frame
		if chain.buffer_size() != Vector2i(1280,720):
			errors.append("buffer exceeds 720p: " + str(chain.buffer_size()))
	if chain.world_env.fog_enabled:
		errors.append("double fog")
	if chain.screen.texture_filter != CanvasItem.TEXTURE_FILTER_LINEAR:
		errors.append("nearest screen filter")
	for key: String in ["quantization_strength", "comb_strength"]:
		if float(chain.get_vhs(key)) != 0.0:
			errors.append("permanent effect: " + key)
	chain.set_tracking(0.8)
	chain.set_fade(0.4)
	if not is_equal_approx(chain.vhs_amount(), 0.3) or not is_equal_approx(float(chain.get_vhs("effect_strength")), 0.3):
		errors.append("soft VHS default missing")
	chain.set_vhs_amount(0.0)
	chain.apply_preset("retro")
	chain.apply_preset("hq")
	if float(chain.get_vhs("grain_strength")) != 0.0 or float(chain.get_vhs("effect_strength")) != 0.0:
		errors.append("VHS off changed by preset")
	chain.set_vhs_amount(0.65)
	if not is_equal_approx(float(chain.get_vhs("tracking")), 0.8) or not is_equal_approx(chain.get_fade(), 0.4):
		errors.append("VHS setting erased story effect")
	chain.begin_tape_mode()
	if not chain.is_tape_mode() or not is_equal_approx(float(chain.get_vhs("tracking")), 0.8):
		errors.append("story/tape uniforms lost")
	chain.end_tape_mode()
	if absf(chain.get_fade() - 0.4) > 0.0001:
		errors.append("story fade lost")
	for name: String in ["psx_hq", "psx_hq_alpha", "psx_hq_glass", "psx_water_hq"]:
		var source := FileAccess.get_file_as_string("res://shaders/" + name + ".gdshader")
		if not source.contains("FOG = vec4(psx_fog_color") or not source.contains("flashlight_cookie_at"):
			errors.append("inconsistent light/fog: " + name)
	if SkinLayer.load_all().enabled:
		errors.append("external skin active")
	chain.queue_free()
	await process_frame
	if errors.is_empty():
		print("test_graphics_render: PASS")
	else:
		for error: String in errors:
			printerr(error)
	quit(0 if errors.is_empty() else 1)

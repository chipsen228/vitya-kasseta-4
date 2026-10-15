extends SceneTree

var _ran := false


func _process(_delta: float) -> bool:
	if _ran:
		return false
	_ran = true
	var errors: Array[String] = []

	var probe := LightCone.make_lamp("Probe")
	if probe.mesh == null or probe.mesh.get_faces().size() / 3 != LightCone.SEGMENTS:
		errors.append("меш конуса не совпадает с бюджетом сегментов")
	if probe.material_override == null or not probe.material_override is ShaderMaterial:
		errors.append("у конуса нет общего ShaderMaterial")

	Materials.render_hq_enabled = false
	var materials := Materials.new().load_all()
	for key: String in Materials.HQ_GROUND_ROUGHNESS:
		var material := materials.get_mat(key) as ShaderMaterial
		Materials.set_material_quality(material, true)
		if material.shader.resource_path not in [Materials.HQ_SHADER,Materials.HQ_OPAQUE_SHADER]:
			errors.append("%s не переключился на HQ-шейдер" % key)
		var got := float(material.get_shader_parameter("roughness_value"))
		if not is_equal_approx(got, float(Materials.HQ_GROUND_ROUGHNESS[key])):
			errors.append("%s roughness %.3f" % [key, got])
		Materials.set_material_quality(material, false)
		if material.shader.resource_path != Materials.PSX_SHADER:
			errors.append("%s не вернул ретро-шейдер" % key)

	var chain := RenderChain.new()
	root.add_child(chain)
	var lights := LightRig.new(chain, materials)
	chain.world_root.add_child(lights)
	if lights.pool.size() != LightRig.POOL_SIZE:
		errors.append("пул реальных ламп вырос")
	for light: OmniLight3D in lights.pool:
		if light.shadow_enabled:
			errors.append("лампа пула получила тень")
	if lights.cones.size() != LightCone.LAMP_IDS.size():
		errors.append("конусы есть не у всех фонарей эталона")
	if lights.halos.size() != lights.cones.size() or lights.light_pools.size() != lights.cones.size():
		errors.append("у части фонарей отсутствуют ореол или пятно")
	var retro_sky_energy := chain.world_env.background_energy_multiplier

	chain.apply_preset("hq")
	lights.powerOn = true
	lights.setLamp("stop", true)
	lights.set_night_immediate(1.0)
	var stop_at := Vector3(-42.60, 2.16, -6.60)
	lights.update(0.2, stop_at, "street", true)
	var stop_cone := lights.cones.get("stop") as MeshInstance3D
	if stop_cone == null or not stop_cone.visible:
		errors.append("HQ не показал конус остановки")
	var stop_halo := lights.halos.get("stop") as MeshInstance3D
	var stop_pool := lights.light_pools.get("stop") as MeshInstance3D
	if stop_halo == null or stop_pool == null or not stop_pool.visible:
		errors.append("HQ не создал ореол и пятно остановки")
	else:
		var stop_floor := float((VillageWorld.data()["STOP"] as Dictionary)["floor"])
		if stop_pool.position.y <= stop_floor:
			errors.append("пятно остановки скрыто под её площадкой")
		var near_camera := stop_halo.position + Vector3(0.0, 0.0, 3.0)
		lights.update(0.2, near_camera, "street", true)
		var near_size := float(stop_halo.get_instance_shader_parameter("halo_size"))
		var near_strength := float(stop_halo.get_instance_shader_parameter("halo_strength"))
		lights.update(0.2, near_camera + Vector3(0.0, 0.0, 20.0), "street", true)
		if not stop_halo.visible or float(stop_halo.get_instance_shader_parameter("halo_size")) <= near_size \
				or float(stop_halo.get_instance_shader_parameter("halo_strength")) >= near_strength:
			errors.append("дальний ореол не увеличился или не потерял яркость")
		lights.setLamp("stop", false)
		lights.update(0.2, near_camera, "street", true)
		if stop_halo.visible or stop_pool.visible or stop_cone.visible:
			errors.append("выключенная лампа оставила световые эффекты")
		lights.setLamp("stop", true)
		lights.update(0.2, near_camera, "street", true)
	if chain.world_env.fog_enabled:
		errors.append("HQ удвоил туман материалов через Environment fog")
	if not is_equal_approx(chain.world_env.adjustment_saturation,
			RenderChain.HQ_ADJUST_SATURATION):
		errors.append("HQ не применил низкую насыщенность")

	chain.apply_preset("retro")
	lights.update(0.2, stop_at, "street", true)
	if stop_cone != null and stop_cone.visible:
		errors.append("ретро оставил конус света")
	if (stop_halo != null and stop_halo.visible) or (stop_pool != null and stop_pool.visible):
		errors.append("ретро оставил ореол или пятно")
	if not is_equal_approx(chain.world_env.background_energy_multiplier, retro_sky_energy):
		errors.append("ретро не восстановил яркость неба")
	if chain.world_env.fog_enabled:
		errors.append("ретро унаследовал HQ Environment fog")
	if not is_equal_approx(chain.world_env.adjustment_saturation,
			RenderChain.ADJUST_SATURATION):
		errors.append("ретро не вернул прежнюю насыщенность")

	probe.free()
	chain.queue_free()
	if errors.is_empty():
		print("test_night_atmosphere: PASS")
		quit(0)
	else:
		for error: String in errors:
			printerr(error)
		printerr("test_night_atmosphere: FAIL (%d)" % errors.size())
		quit(1)
	return false

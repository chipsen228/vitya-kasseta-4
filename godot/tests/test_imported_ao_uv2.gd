extends SceneTree

func _initialize() -> void:
	var image := Image.create(4, 4, false, Image.FORMAT_RGB8)
	image.fill(Color(0.2, 0.7, 0.9))
	var texture := ImageTexture.create_from_image(image)
	for transparency in [BaseMaterial3D.TRANSPARENCY_DISABLED, BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR]:
		var source := StandardMaterial3D.new()
		source.ao_enabled = true
		source.ao_texture = texture
		source.ao_on_uv2 = true
		source.vertex_color_use_as_albedo = true
		source.ao_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_GREEN
		source.uv1_scale = Vector3(3, 5, 1)
		source.uv2_scale = Vector3(0.5, 0.75, 1)
		source.uv2_offset = Vector3(0.1, 0.2, 0)
		source.transparency = transparency
		var material := Materials.convert_imported_material(source, true) as ShaderMaterial
		assert(material.get_shader_parameter("ao_tex") == texture)
		assert(material.get_shader_parameter("use_vertex_color") == true)
		assert(material.get_shader_parameter("ao_on_uv2") == true)
		assert(material.get_shader_parameter("ao_uv2_scale") == Vector2(0.5, 0.75))
		assert(material.get_shader_parameter("ao_uv2_offset") == Vector2(0.1, 0.2))
		assert(material.get_shader_parameter("ao_channel") == Vector4(0, 1, 0, 0))
		assert(material.get_shader_parameter("uv_scale") == Vector2(3, 5))
		assert(material.shader.code.contains("ao_on_uv2 ? UV2"))
		Materials.set_material_quality(material, false)
		assert(material.get_shader_parameter("use_vertex_color") == true)
		assert(material.shader.code.contains("COLOR"))
		Materials.set_material_quality(material, true)
		assert(material.get_shader_parameter("ao_on_uv2") == true)
		assert(Materials.convert_imported_material(source, true) == material)
	print("test_imported_ao_uv2: PASS (UV channels, transforms, texture channel, material cache, quality roundtrip)")
	quit(0)

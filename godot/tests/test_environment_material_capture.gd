extends SceneTree

var output := "res://../art/environment/diagnostic"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	root.borderless = true
	root.size = Vector2i(1280,720)
	var main: Node = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for i in 2400:
		if main.get("boot_ready"): break
		await process_frame
	assert(main.get("boot_ready"),"boot timeout")
	main.call("_start_game")
	var ui: Overlays = main.get("ui")
	for i in 90:
		if ui.card.open: ui.advanceCard()
		await process_frame
	main.set("running",false)
	main.set_process(false)
	(main.get("player") as Player).release_lock()
	ui.showHud(false)
	var chain: RenderChain = main.get("render_chain")
	chain.apply_preset("hq")
	chain.set_vhs_amount(0.0)
	main.get("weather").clear()
	var lights: LightRig = main.get("lights")
	lights.set_night_immediate(0.10)
	lights.powerOn = true
	var camera := chain.camera
	camera.global_position = Vector3(-0.6,1.62,1.4)
	camera.look_at(Vector3(-0.6,3.0,11.4))
	var meshes: Array[MeshInstance3D] = []
	var records: Array = []
	for node: Node in EnvironmentRegistry.SOURCE_SELECTION._nodes(main):
		if node is MeshInstance3D and node.has_meta("environment_owner"):
			meshes.append(node as MeshInstance3D)
			if String(node.get_meta("environment_owner")) in ["vitya","p07"]:
				records.append(_inspect(node as MeshInstance3D))
	for mode: String in ["both","no-ao","no-normal","neither"]:
		for mi: MeshInstance3D in meshes:
			var levels: Array = mi.call("quality_meshes") if mi.has_method("quality_meshes") else [mi.mesh]
			for mesh: Mesh in levels:
				for surface in mesh.get_surface_count():
					var material := (mi.get_active_material(surface) if mesh == mi.mesh else mesh.surface_get_material(surface)) as ShaderMaterial
					if material == null: continue
					var params: Dictionary = material.get_meta("skin_hq_params",{})
					material.set_shader_parameter("use_ao",bool(params.get("use_ao",false)) and mode in ["both","no-normal"])
					material.set_shader_parameter("use_normal",bool(params.get("use_normal",false)) and mode in ["both","no-ao"])
		for i in 30:
			lights.update(1.0/60.0,camera.global_position,"plot",true)
			await process_frame
		await RenderingServer.frame_post_draw
		assert(chain.post_view.get_texture().get_image().save_png(output.path_join("main-"+mode+".png")) == OK)
	var file := FileAccess.open(output.path_join("material-audit.json"),FileAccess.WRITE)
	file.store_string(JSON.stringify(records,"\t"))
	file.close()
	print("test_environment_material_capture: PASS four comparisons")
	main.queue_free()
	await process_frame
	await process_frame
	quit()

func _inspect(mi: MeshInstance3D) -> Dictionary:
	var out := {"owner":mi.get_meta("environment_owner"),"surfaces":[]}
	for surface in mi.mesh.get_surface_count():
		var material := mi.mesh.surface_get_material(surface) as ShaderMaterial
		var arrays := mi.mesh.surface_get_arrays(surface)
		var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var tex := material.get_shader_parameter("ao_tex") as Texture2D
		var image: Image = tex.get_image() if tex != null else null
		if image != null and image.is_compressed(): image.decompress()
		var row := {"shader":material.shader.resource_path,"params":{},"uv2_min":[1,1],"uv2_max":[0,0],"colors_min":[1,1,1,1],"colors_max":[0,0,0,0],"samples":[]}
		for key: String in ["use_ao","ao_on_uv2","ao_uv2_scale","ao_uv2_offset","use_normal","normal_strength","metallic_value","albedo","use_vertex_color"]:
			row["params"][key] = str(material.get_shader_parameter(key))
		for i in uv2.size():
			for k in 2:
				row["uv2_min"][k]=minf(row["uv2_min"][k],uv2[i][k])
				row["uv2_max"][k]=maxf(row["uv2_max"][k],uv2[i][k])
			if not colors.is_empty():
				for k in 4:
					row["colors_min"][k]=minf(row["colors_min"][k],colors[i][k])
					row["colors_max"][k]=maxf(row["colors_max"][k],colors[i][k])
		var count := indices.size() if not indices.is_empty() else positions.size()
		for offset in range(0,count,3):
			var a := indices[offset] if not indices.is_empty() else offset
			var b := indices[offset+1] if not indices.is_empty() else offset+1
			var c := indices[offset+2] if not indices.is_empty() else offset+2
			var p := (positions[a]+positions[b]+positions[c])/3.0 + mi.position
			if p.y < 0.8 or p.y > 2.2 or normals[a].z > -0.85 or row["samples"].size() >= 12: continue
			var uv := (uv2[a]+uv2[b]+uv2[c])/3.0
			var ao := image.get_pixel(clampi(int(uv.x*image.get_width()),0,image.get_width()-1),clampi(int(uv.y*image.get_height()),0,image.get_height()-1)).r if image != null else -1.0
			var flipped := image.get_pixel(clampi(int(uv.x*image.get_width()),0,image.get_width()-1),clampi(int((1.0-uv.y)*image.get_height()),0,image.get_height()-1)).r if image != null else -1.0
			row["samples"].append({"point":str(p),"uv2":str(uv),"ao":ao,"ao_flip_v":flipped,"color":str(colors[a]) if not colors.is_empty() else "none"})
		out["surfaces"].append(row)
	return out

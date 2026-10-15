## Оконная GPU-проверка настоящего чанка WorldBuilder на20/30м.
extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	root.size=Vector2i(800,600)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderChain.register_shader_globals()
	var world := Node3D.new()
	root.add_child(world)
	WorldBuilder.build(world,Materials.new().load_all(),CollisionWorld.new())
	await process_frame
	var chunk: ForestLodMesh
	for node: Node in world.get_children():
		if node is ForestLodMesh and (node as ForestLodMesh).anchors.size()>3:
			chunk=node
			break
	if chunk==null:
		quit(1)
		return
	for node: Node in SkinLayer._nodes(world):
		if node is GeometryInstance3D:
			(node as GeometryInstance3D).visible=node==chunk
	var camera := Camera3D.new()
	camera.fov=70.0
	camera.far=120.0
	world.add_child(camera)
	camera.make_current()
	var edge := Vector3(INF,0,0)
	for position: Vector3 in chunk.anchors.values():
		var point := chunk.global_transform*position
		if point.x<edge.x: edge=point
	chunk.select_far(false)
	var samples: Array = []
	for distance: float in [20.0,30.0]:
		camera.global_position=edge+Vector3(-distance,3,0)
		camera.look_at(chunk.global_position)
		for _i in 40:
			chunk.update_for_camera(camera.global_position)
			await process_frame
		await RenderingServer.frame_post_draw
		samples.append({"distance_m":distance,"far_active":chunk.far_active,
			"gpu_triangles":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
			"gpu_calls":RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
			"mesh_triangles":chunk.mesh.get_faces().size()/3})
	var passed := not bool(samples[0]["far_active"]) and bool(samples[1]["far_active"]) \
		and int(samples[0]["gpu_triangles"])>int(samples[1]["gpu_triangles"]) \
		and int(samples[0]["gpu_calls"])==int(samples[1]["gpu_calls"]) \
		and int(samples[1]["gpu_calls"])>0
	var result := {"passed":passed,"samples":samples,"chunk":String(chunk.name)}
	print("bench_forest_lod: ",JSON.stringify(result))
	print("bench_forest_lod: ","PASS" if passed else "FAIL")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			var file := FileAccess.open(argument.trim_prefix("--output="),FileAccess.WRITE)
			file.store_string(JSON.stringify(result,"\t"))
	quit(0 if passed else 1)

extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if "--main" in OS.get_cmdline_user_args():
		await _trace_main()
		return
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	root.add_child(world)
	WorldBuilder.build(world,mats,col)
	var props := Props.new(mats)
	props.load_models(GameData.props().get("PROPS",[]))
	props.build(world,GameData.props().get("PROPS",[]),col)
	await process_frame
	var origin := Vector3(1.2,1.68,21.6)
	var basis := Basis.from_euler(Vector3(0.04,PI*1.62,0),EULER_ORDER_YXZ)
	for pixel: Vector2 in [Vector2(900,130),Vector2(600,250),Vector2(1100,45)]:
		var tangent := tan(deg_to_rad(70.0)*0.5)
		var ray := (basis*Vector3((pixel.x/1280.0*2.0-1.0)*tangent*1280.0/720.0,
			(1.0-pixel.y/720.0*2.0)*tangent,-1.0)).normalized()
		var hits: Array = []
		_trace(world,origin,ray,hits)
		hits.sort_custom(func(a:Dictionary,b:Dictionary)->bool: return a["distance"]<b["distance"])
		print("TRACE ",pixel," ",JSON.stringify(hits.slice(0,8)))
	world.queue_free()
	await process_frame
	quit(0)

func _trace_main() -> void:
	var main: Node = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for _i in 1600:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		quit(1)
		return
	main.call("_start_game")
	var ui: Overlays = main.get("ui")
	for _i in 90:
		if ui.card.open: ui.advanceCard()
		await process_frame
	var player: Player = main.get("player")
	var chain: RenderChain = main.get("render_chain")
	for _i in 30:
		player.place(1.2,0.0,21.6,PI*1.62)
		player.pitch=0.04
		player.pitch_target=0.04
		player.call("_apply_camera")
		await process_frame
	print("ACTUAL_CAMERA ",chain.camera.global_transform," feet=",player.feet()," height=",player.height," fov=",chain.camera.fov)
	var camera := chain.camera
	for pixel: Vector2 in [Vector2(900,130),Vector2(600,250),Vector2(1100,45)]:
		var tangent := tan(deg_to_rad(camera.fov)*0.5)
		var ray := (camera.global_basis*Vector3((pixel.x/1280.0*2.0-1.0)*tangent*1280.0/720.0,
			(1.0-pixel.y/720.0*2.0)*tangent,-1.0)).normalized()
		var hits: Array = []
		_trace(main,camera.global_position,ray,hits)
		hits.sort_custom(func(a:Dictionary,b:Dictionary)->bool: return a["distance"]<b["distance"])
		print("MAIN_TRACE ",pixel," ",JSON.stringify(hits.slice(0,10)))
	main.queue_free()
	await process_frame
	quit(0)

func _trace(node: Node,origin: Vector3,ray: Vector3,hits: Array) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).visible:
		var mi := node as MeshInstance3D
		for surface in mi.mesh.get_surface_count():
			var arrays := mi.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indexes: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
			var count := indexes.size() if not indexes.is_empty() else vertices.size()
			var nearest := INF
			var triangle := -1
			var points: Array = []
			for index in range(0,count,3):
				var a := mi.global_transform*vertices[indexes[index] if not indexes.is_empty() else index]
				var b := mi.global_transform*vertices[indexes[index+1] if not indexes.is_empty() else index+1]
				var c := mi.global_transform*vertices[indexes[index+2] if not indexes.is_empty() else index+2]
				var hit: Variant = Geometry3D.ray_intersects_triangle(origin,ray,a,b,c)
				if hit is Vector3 and origin.distance_to(hit)<nearest:
					nearest=origin.distance_to(hit)
					triangle=index
					points=[str(a),str(b),str(c)]
			if triangle>=0:
				var owners: Array = []
				var ranges: Dictionary = mi.get_meta("skin_parts",{})
				for key: String in ranges:
					for span: Vector2i in ranges[key]:
						if triangle>=span.x and triangle<span.x+span.y:
							owners.append(key)
				hits.append({"path":str(mi.get_path()),"surface":surface,"triangle":triangle,"distance":nearest,"owners":owners,"points":points})
	for child: Node in node.get_children():
		_trace(child,origin,ray,hits)

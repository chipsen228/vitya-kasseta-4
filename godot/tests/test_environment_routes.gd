## Непрерывный маршрут настоящим Player. Единственный place() задаёт старт во дворе.
extends SceneTree

var errors: Array[String] = []
var main: Node
var player: Player
var frames := 0
var distance := 0.0
var opened := 0
var used: Dictionary = {}
var checkpoints := 0
const OUTPUT := "C:/Users/Peter Zakharov/Desktop/vitya-godot/output/environment-refresh/"
var guarantees: Dictionary = {}
var walked: Array[Dictionary] = []
var e_events: Array[Dictionary] = []
var checkpoint_rows: Array[Dictionary] = []
var max_step := 0.0
var started_at := Time.get_ticks_msec()

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	main=(load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for i in 4000:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		errors.append("main boot did not complete")
		_finish()
		return
	_capture_guarantees()
	if OS.get_cmdline_user_args().has("--guards-only"):
		_finish()
		return
	main.call("_start_game")
	await _cards()
	# До финальной погони проверяем геометрию. Переходов сюжета тест не вызывает.
	var state: GameState=main.get("state")
	state.chapter="light"
	main.set("running",false)
	player=main.get("player")
	player.release_lock()
	player.enabled=true
	player.frozen=false
	player.place(0.0,0.035,1.25,0.0)
	await physics_frame
	Engine.physics_ticks_per_second=600
	if not await _path([Vector2(6.8,1.25),Vector2(6.8,8.8)]) or not await _use("shed-door") \
			or not await _path([Vector2(6.8,10.6),Vector2(6.75,11.70)]) \
			or not await _everyday("decor-shed-cabinet") \
			or not await _path([Vector2(6.8,10.6),Vector2(6.8,8.8),Vector2(6.8,1.25),Vector2(0,1.25)]):
		_finish()
		return
	if not await _use("gate-chain",true):
		_finish()
		return
	if not state.has("gate-open"):
		errors.append("original gate failed to open via E")
		_finish()
		return
	# Player._slide compensates engine dt: шаг игрока остаётся 1/60, физика ускоряет CI.
	Engine.physics_ticks_per_second=600
	var paths := [
		[Vector2(0,-0.7),Vector2(-2.4,-0.7),Vector2(-2.4,-5.2),Vector2(-10.5,-5.2),Vector2(-10.5,-16.5),
			Vector2(-17.7,-16.5),Vector2(-18.5,-19.2),Vector2(-21.6,-19.2),Vector2(-22,-16.5),
			Vector2(-21.6,-19.2),Vector2(-18.5,-19.2),Vector2(-17.7,-16.5),Vector2(-10.2,-16.5),
			Vector2(-8.7,-16.0),Vector2(2.2,-16.0),Vector2(3.4,-16.5),Vector2(15.2,-16.5),
			Vector2(15.2,-33),Vector2(13,-35.4),Vector2(13,-38.3),Vector2(12.2,-39.3),Vector2(27.528,-39.3)],
		[Vector2(35.528,-39.3)],
		[Vector2(12.2,-39.3),Vector2(12.2,-49.7),Vector2(3.9,-49.7),Vector2(3.9,-42.2),
			Vector2(3.9,-49.7),Vector2(12.2,-49.7),Vector2(12.2,-54.7),Vector2(39,-54.7),Vector2(27.528,-54.7)],
		[Vector2(12.2,-54.7),Vector2(-20.6,-54.7),Vector2(-20.6,-51.1),Vector2(-28.472,-51.1)],
		[Vector2(-20.6,-51.1),Vector2(-20.6,-54.7),Vector2(-20.6,-61.8),Vector2(3.4,-61.8),Vector2(3.4,-64.1),
			Vector2(7.1,-64.1),Vector2(8.07,-66.3),Vector2(7.1,-64.1),Vector2(3.4,-64.1),
			Vector2(3.4,-61.8),Vector2(-1.472,-61.8)],
		[Vector2(-1.472,-61.8),Vector2(-20.6,-61.8),Vector2(-20.6,-54.7),Vector2(12.2,-54.7),
			Vector2(12.2,-39.3),Vector2(12.2,-35.4),Vector2(-0.45,-35.4),Vector2(-0.45,-40.2),
			Vector2(-0.45,-45.3),Vector2(-0.45,-40.2),Vector2(-0.45,-35.4),Vector2(12.2,-35.4),
			Vector2(12.2,-39.3),Vector2(37.95,-39.3),Vector2(37.95,-33),Vector2(37.95,-16.5),
			Vector2(21,-16.5),Vector2(19.6,-18.1),Vector2(16.4,-18.1),Vector2(15.2,-16.5),
			Vector2(11,-16.5),Vector2(11,-5.2),Vector2(-2.4,-5.2),Vector2(-2.4,-0.7),Vector2(0,-0.7),Vector2(0,1.25)]
	]
	var gates := [
		["decor-gate-p02",Vector2(27.528,-39.94),Vector2(27.528,-41.7)],
		["decor-gate-p03",Vector2(35.528,-39.94),Vector2(35.528,-41.7)],
		["decor-gate-p07",Vector2(27.528,-55.94),Vector2(27.528,-57.7)],
		["decor-gate-p10",Vector2(-28.472,-51.06),Vector2(-28.472,-49.3)],
		["decor-gate-p14",Vector2(-1.472,-63.94),Vector2(-1.472,-65.7)]]
	for index in paths.size():
		if index==0:
			if not await _path([Vector2(0,-0.7),Vector2(-2.4,-0.7),Vector2(-2.4,-5.2),Vector2(-31.5,-5.2),Vector2(-31.5,-6.2)]) \
					or not await _everyday("decor-board-notice") \
					or not await _path([Vector2(-31.5,-5.2),Vector2(-2.4,-5.2),Vector2(-2.4,-0.7),Vector2(0,-0.7)]): break
		if not await _path(paths[index]): break
		if index==0:
			if not await _path([Vector2(12.2,-39.3),Vector2(13,-38.3),Vector2(13,-35.4),Vector2(15.2,-33),
					Vector2(15.2,-26.15),Vector2(10.45,-26.15)]) or not await _everyday("decor-club-notice") \
					or not await _path([Vector2(15.2,-26.15),Vector2(15.2,-33),Vector2(13,-35.4),Vector2(-15.3,-35.4),
					Vector2(-15.3,-38.5),Vector2(-16.3,-38.84)]) or not await _everyday("decor-snt-cabinet") \
					or not _checkpoint("snt-last-round") \
					or not await _path([Vector2(-15.3,-38.5),Vector2(-15.3,-35.4),Vector2(4.4,-35.4),Vector2(4.4,-37.5)]) \
					or not _checkpoint("snt-watch-log") \
					or not await _path([Vector2(4.4,-35.4),Vector2(13,-35.4),Vector2(13,-38.3),Vector2(12.2,-39.3),
					Vector2(19,-39.3),Vector2(19,-41.6),Vector2(20.35,-41.6)]) or not _checkpoint("snt-yard") \
					or not await _path([Vector2(19,-41.6),Vector2(19,-39.3),Vector2(27.528,-39.3)]): break
		if index==3:
			if not await _path([Vector2(-20.6,-51.1),Vector2(-20.6,-54.7),Vector2(9,-54.7),Vector2(9,-57.5),Vector2(7.1,-57.5)]) \
					or not await _everyday("decor-p09-radio") \
					or not await _path([Vector2(9,-57.5),Vector2(9,-54.7),Vector2(-20.6,-54.7),Vector2(-20.6,-51.1),Vector2(-28.472,-51.1)]): break
		if index<gates.size():
			var gate: Array=gates[index]
			if not await _walk(gate[1]) or not await _use(gate[0]): break
			var everyday: Variant=main.get("ctx").get("everyday")
			if everyday==null:
				errors.append("EverydayController absent")
				break
			everyday.update(0.61)
			await physics_frame
			if not await _walk(gate[2]) or not await _walk(gate[1]): break
			opened+=1
			used[gate[0]]=true
			if index==2:
				if not await _path([Vector2(27.528,-57.7),Vector2(30.15,-57.7),Vector2(30.15,-59.9)]) \
						or not await _everyday("decor-p07-barrel") \
						or not await _path([Vector2(30.15,-57.7),Vector2(27.528,-57.7),Vector2(27.528,-55.94)]): break
			if index==3:
				if not await _path([Vector2(-28.472,-49.3),Vector2(-25.15,-49.3),Vector2(-25.15,-49.1)]) \
						or not await _everyday("decor-p10-pump") \
						or not await _path([Vector2(-25.15,-49.3),Vector2(-28.472,-49.3),Vector2(-28.472,-51.06)]): break
		if index==5:
			if not await _path([Vector2(0,-0.7),Vector2(-2.4,-0.7),Vector2(-2.4,-5.2),Vector2(11,-5.2),Vector2(11,-16.5),
					Vector2(15.2,-16.5),Vector2(16.4,-18.1),Vector2(19.6,-18.1),Vector2(21,-16.5),Vector2(37.95,-16.5),
					Vector2(37.95,-33.7),Vector2(35.05,-33.7),Vector2(35.05,-33.22)]) or not await _everyday("decor-snt-entry-notice") \
					or not await _path([Vector2(36.8,-33.4)]) or not _checkpoint("snt-sign") \
					or not await _path([Vector2(37.95,-33),Vector2(37.95,-39.3),Vector2(12.2,-39.3),
					Vector2(12.2,-35.4),Vector2(-0.45,-35.4),Vector2(-0.45,-40.2)]) or not _checkpoint("snt-watermarks") \
					or not await _path([Vector2(-0.45,-35.4),Vector2(12.2,-35.4),Vector2(13,-38.3),Vector2(12.2,-39.3),
					Vector2(12.2,-54.7),Vector2(-20.6,-54.7),Vector2(-20.6,-61.8),Vector2(3.4,-61.8),Vector2(3.4,-64.1),
					Vector2(7.1,-64.1),Vector2(8.07,-66.3)]) or not _checkpoint("snt-signal") \
					or not await _path([Vector2(7.1,-64.1),Vector2(3.4,-64.1),Vector2(3.4,-61.8),Vector2(-20.6,-61.8),
					Vector2(-20.6,-54.7),Vector2(12.2,-54.7),Vector2(12.2,-39.3),Vector2(37.95,-39.3),
					Vector2(37.95,-33),Vector2(37.95,-16.5),Vector2(21,-16.5),Vector2(19.6,-18.1),Vector2(16.4,-18.1),
					Vector2(15.2,-16.5),Vector2(11,-16.5),Vector2(11,-5.2),Vector2(-2.4,-5.2),Vector2(-2.4,-0.7),Vector2(0,-0.7),Vector2(0,1.25)]): break
	if opened!=5: errors.append("ordinary gates traversed %d/5" % opened)
	if used.size()!=13: errors.append("ordinary E interactions %d/13" % used.size())
	if checkpoints!=6: errors.append("inherited geometry checkpoints %d/6" % checkpoints)
	if Vector2(player.feet().x,player.feet().z).distance_to(Vector2(0,1.25)) > .11: errors.append("Player did not return home")
	Engine.physics_ticks_per_second=60
	_finish()

func _path(points: Array) -> bool:
	for p: Vector2 in points:
		if not await _walk(p): return false
	return true

func _walk(target: Vector2) -> bool:
	player.frozen=false
	player.enabled=true
	var start := Vector2(player.feet().x,player.feet().z)
	var limit := int((start.distance_to(target)/Player.SPEED_WALK+6.0)*60.0)
	Input.action_press("move_forward")
	for i in limit:
		var now := Vector2(player.feet().x,player.feet().z)
		if now.distance_to(target)<0.10:
			Input.action_release("move_forward")
			walked.append({"start":[start.x,start.y],"target":[target.x,target.y],"actual":[now.x,now.y],"frames":i,"arrival_error_m":now.distance_to(target)})
			return true
		var delta := target-now
		player.yaw=atan2(-delta.x,-delta.y)
		player.yaw_target=player.yaw
		await physics_frame
		player.update(1.0/60.0)
		frames+=1
		var step := now.distance_to(Vector2(player.feet().x,player.feet().z))
		max_step=maxf(max_step,step)
		distance+=step
		if step>.22:
			errors.append("discontinuous Player movement: "+str(step)+"m")
			break
		if player.feet().y< -0.5:
			errors.append("fall at "+str(player.feet()))
			break
	Input.action_release("move_forward")
	for i in player.get_slide_collision_count():
		var contact := player.get_slide_collision(i)
		var body: Node=contact.get_collider()
		var shape_index := contact.get_collider_shape_index()
		var col: CollisionWorld=main.get("col")
		var owners: Array[String]=[]
		var set_index := int(String(body.name).trim_prefix("set_")) if String(body.name).begins_with("set_") else -1
		if set_index>=0:
			var by_id: Array=col.get("_by_id")
			for id: String in by_id[set_index]:
				var indices: PackedInt32Array=by_id[set_index][id]
				if indices.has(shape_index): owners.append(id)
		printerr("route native collision: body=",body.name," shape=",shape_index," owners=",owners," normal=",contact.get_normal())
	errors.append("Player blocked at "+str(player.feet())+" toward "+str(target))
	return false

func _use(id: String,via_e := true) -> bool:
	Input.action_release("move_forward")
	for i in 10:
		await physics_frame
		player.update(1.0/60.0)
	await _cards()
	var interact: Interact=main.get("interact")
	var definition: Dictionary={}
	for row: Dictionary in interact.list:
		if row.get("id","")==id: definition=row; break
	if definition.is_empty():
		errors.append("missing target "+id)
		return false
	var delta: Vector3=definition["pos"]-player.eyes()
	player.yaw=atan2(-delta.x,-delta.z)
	player.yaw_target=player.yaw
	player.pitch=atan2(delta.y,Vector2(delta.x,delta.z).length())
	player.pitch_target=player.pitch
	player.call("_apply_camera")
	var found: Variant=interact.find(main.get("render_chain").camera,main.get("state"))
	if not found is Dictionary or found.get("id","")!=id:
		errors.append("cannot select "+id+" after walking; got "+str(found))
		return false
	interact.target=found
	if via_e:
		var feet_before := player.feet()
		main.set("running",true)
		var event := InputEventAction.new()
		event.action="interact"
		event.pressed=true
		main.call("_unhandled_input",event)
		main.set("running",false)
		if player.feet().distance_to(feet_before)>.22:
			errors.append("E interaction moved Player discontinuously: "+id)
			return false
		e_events.append({"id":id,"feet":[feet_before.x,feet_before.y,feet_before.z],"target_distance":player.eyes().distance_to(definition["pos"]),"ordinary_e":true,"selected_by":"Interact.find"})
		print("route E: ",id," frames=",frames," distance=",snappedf(distance,.1))
	else:
		interact.use(main.get("ctx"))
	return true

func _everyday(id: String) -> bool:
	if not await _use(id): return false
	var everyday: EverydayInteractions=main.get("ctx").get("everyday")
	var definition: Dictionary=everyday.definitions[id]
	var kind := String(definition["kind"])
	var state: GameState=main.get("state")
	if kind=="notice":
		var ui: Overlays=main.get("ui")
		if not ui.reader.open:
			errors.append("notice reader failed to open "+id)
			return false
		var event := InputEventAction.new()
		event.action="interact"; event.pressed=true
		main.set("running",true)
		main.call("_unhandled_input",event)
		main.set("running",false)
		if ui.reader.open or not state.has(definition["flag"]):
			errors.append("notice E dismissal failed "+id)
			return false
	elif kind=="radio":
		if everyday.radio_remaining<=0.0:
			errors.append("radio did not start")
			return false
		everyday.update(4.01)
		if everyday.radio_remaining!=0.0:
			errors.append("radio did not finish")
			return false
	else:
		everyday.update(1.01 if kind=="pump" else 0.61)
		if kind!="pump" and not state.has(definition["flag"]):
			errors.append("everyday effect missing "+id)
			return false
		if everyday.animations.has(id):
			errors.append("everyday animation did not finish "+id)
			return false
	used[id]=true
	return true

# Квестовые ограничения проверяются собственными story tests; здесь актуальный
# Player должен физически подойти, иметь нужную дистанцию и незакрытый взгляд.
func _checkpoint(id: String) -> bool:
	var interact: Interact=main.get("interact")
	for definition: Dictionary in interact.list:
		if definition.get("id","")!=id: continue
		var point: Vector3=definition["pos"]
		if player.eyes().distance_to(point)>float(definition["r"]) \
				or not interact.visible(player.eyes(),point,CollisionWorld.ALL_SOLID):
			errors.append("inherited target range/LOS failed "+id+" at "+str(player.feet()))
			return false
		checkpoints+=1
		checkpoint_rows.append({"id":id,"feet":[player.feet().x,player.feet().y,player.feet().z],"distance":player.eyes().distance_to(point),"radius":definition["r"],"all_solid_los":true})
		return true
	errors.append("missing inherited target "+id)
	return false

func _cards() -> void:
	var ui: Overlays=main.get("ui")
	for i in 120:
		if ui.card.open: ui.advanceCard()
		if not ui.card.open and not ui.busy: return
		await process_frame

func _finish() -> void:
	Input.action_release("move_forward")
	Engine.physics_ticks_per_second=60
	var guards_only:=OS.get_cmdline_user_args().has("--guards-only")
	var report := {"passed":errors.is_empty(),"environment":"off" if OS.get_cmdline_user_args().has("--environment=off") else "full",
		"scope":"boot geometry guards only; no Player tour" if guards_only else "continuous Player tour",
		"render_preset":(main.get("render_chain") as RenderChain).render_preset() if is_instance_valid(main) and main.get("render_chain")!=null else "",
		"player_class":"Player", "start_place_calls":0 if guards_only else 1,"teleports_after_start":null if guards_only else (0 if max_step<=.22 else -1),
		"movement_source":"Input.move_forward + Player.update(1/60) + native physics frames",
		"startup_fixture":"chapter light; ordinary gate-chain and shed-door opened through E",
		"distance_m":distance,"physics_frames":frames,"max_horizontal_step_m":max_step,
		"gates_opened_and_crossed_both_directions":opened,"ordinary_e_count":used.size(),"used_ids":used.keys(),
		"inherited_geometry_checkpoints":checkpoint_rows,"e_events":e_events,"walked_waypoints":walked,
		"elapsed_wall_seconds":float(Time.get_ticks_msec()-started_at)/1000.0,"guarantees":guarantees,
		"final_feet":[player.feet().x,player.feet().y,player.feet().z] if is_instance_valid(player) else [],"errors":errors,
		"visual_verified":false,"story_endings_verified":false}
	var file:=FileAccess.open(OUTPUT+"final-player-route"+("-guards" if guards_only else "")+("-off" if OS.get_cmdline_user_args().has("--environment=off") else "")+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	for error: String in errors: printerr("FAIL environment_routes: ",error)
	if guards_only:
		print("test_environment_route_guards: %s legacy=%s overlay=%d roofs=%d horizon=%s" % ["PASS" if errors.is_empty() else "FAIL",str(guarantees.get("legacy_counts",[])),guarantees.get("overlay_boxes",0),guarantees.get("roof_shapes",0),str(guarantees.get("horizon",{}))])
	else:
		print("test_environment_routes: %s distance=%.1fm frames=%d gates=%d/5 E=%d/13 checkpoints=%d/6" % ["PASS" if errors.is_empty() else "FAIL",distance,frames,opened,used.size(),checkpoints])
	if is_instance_valid(main):
		main.queue_free()
		await process_frame
		await process_frame
	quit(0 if errors.is_empty() else 1)

func _capture_guarantees() -> void:
	var col: CollisionWorld=main.get("col")
	var built: Dictionary=main.get("built")
	var world: Node3D=(main.get("render_chain") as RenderChain).world_root
	var original: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(OUTPUT+"before/physics.json"))
	var approved: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(OUTPUT+"after/physics.json"))
	var counts: Array=[]
	var base_equal:=true
	var overlay_equal:=true
	var roof_count:=0
	var roofs_equal:=true
	for set_id in CollisionWorld.SET_COUNT:
		counts.append(col.box_count(set_id))
		var expected: Array=original["sets"][set_id] if set_id<3 else approved["sets"][set_id]
		if expected.size()!=col.box_count(set_id):
			if set_id<3: base_equal=false
			else: overlay_equal=false
		for index in mini(expected.size(),col.box_count(set_id)):
			var shape: Array=Array(col._data[set_id].slice(index*14,index*14+14))
			var same:=_shape_same(shape,expected[index]["shape"]) and bool(col._active[set_id][index])==bool(expected[index]["active"])
			if set_id<3: base_equal=base_equal and same
			else: overlay_equal=overlay_equal and same
			if set_id==CollisionWorld.SET_STATIC and int(shape[6])==CollisionWorld.AXIS_X:
				for neighbour: Dictionary in GameData.site()["NEIGHBOURS"]:
					var found:=false
					for house: Array in neighbour["houses"]:
						if absf(float(shape[8])-float(house[0]))<.00001 and absf(float(shape[10])-float(house[1]))<float(house[3])*.5+.3 and absf(float(shape[9])-(float(house[4])+.65))<.00001:
							roof_count+=1
							roofs_equal=roofs_equal and same
							found=true
							break
					if found: break
	if not base_equal or counts.slice(0,3)!=[311,4,83] or int(built["triangles"])!=3885: errors.append("legacy shape14/base311/4/83/3885 mismatch")
	if not overlay_equal: errors.append("overlay shape14 differs from approved exact fixture snapshot")
	if roof_count!=18 or not roofs_equal: errors.append("18 original neighbour roof AABB/axis/angle mismatch")
	var nav_sha:=FileAccess.get_sha256("res://data/nav_baked.json")
	var nav_original:=FileAccess.get_sha256("C:/Users/Peter Zakharov/Desktop/vitya-environment-backup-2026-10-03-144820/godot/data/nav_baked.json")
	if nav_sha!=nav_original: errors.append("original navgraph SHA256 mismatch")
	var registry: Dictionary=built.get("environment",{})
	if OS.get_cmdline_user_args().has("--environment=off"):
		pass
	elif registry.get("sample_mode",false) or registry.get("houses",[]).size()!=30 or registry.get("yards",[]).size()!=30 or registry.get("services",[]).size()!=13 or registry.get("resources",[]).size()!=219 or not registry.get("errors",[]).is_empty():
		errors.append("route did not load complete 73/219 production environment")
	var water_rows: Array=[]
	for id: String in ["story-lake","snt-lake"]:
		var node:=world.get_node_or_null(id+"-surface") as MeshInstance3D
		if node==null: errors.append("HQ water missing "+id);continue
		var material:=node.material_override as ShaderMaterial
		var triangles:=node.mesh.get_faces().size()/3
		water_rows.append({"id":id,"surfaces":node.mesh.get_surface_count(),"triangles":triangles,"opaque_depth_write":material.shader.code.contains("depth_draw_opaque") and not material.shader.code.contains("ALPHA"),"shadows_off":node.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF})
		if node.mesh.get_surface_count()!=1 or material.shader.resource_path!="res://shaders/environment_water.gdshader": errors.append("water is not one HQ depth surface")
	var east_max:=-INF
	for polygon: PackedVector2Array in built["snt"]["waterway"]["outlines"]:
		for point: Vector2 in polygon: east_max=maxf(east_max,point.x)
	if east_max>3.20001: errors.append("SNT water extends east of3.2")
	var far:=world.get_node("rural-horizon") as Node3D
	var far_triangles:=0
	var far_surfaces:=0
	if far is MeshInstance3D or far.get_child_count()!=6: errors.append("horizon old drawmesh retained or chunks missing")
	for chunk: MeshInstance3D in far.get_children():
		far_triangles+=chunk.mesh.get_faces().size()/3
		far_surfaces+=chunk.mesh.get_surface_count()
		if chunk.cast_shadow!=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF: errors.append("horizon chunk casts shadows")
	if far_surfaces!=6 or far_triangles!=12458: errors.append("horizon budget or original triangle count changed")
	var landscape: Dictionary=built["rural"]["landscape"]
	if landscape["fog_sheets"].size()!=6: errors.append("not six compatibility fog sheets")
	guarantees={"legacy_counts":counts.slice(0,3),"base_triangles":built["triangles"],"base_shape14_same_as_original":base_equal,
		"shape_component_tolerance":.000000001,"overlay_boxes":counts[3],"overlay_shape14_same_as_approved":overlay_equal,
		"roof_shapes":roof_count,"roof_shape14_aabb_axis_angle_same":roofs_equal,"nav_sha256":nav_sha,"nav_original_sha256":nav_original,
		"nav_stats":(main.get("nav") as NavGraph).stats(),"nav_original_stats":original["navigation"],
		"registry":{"houses":registry.get("houses",[]).size(),"yards":registry.get("yards",[]).size(),"services":registry.get("services",[]).size(),"resources":registry.get("resources",[]).size(),"errors":registry.get("errors",[])},
		"waters":water_rows,"snt_water_east_max":east_max,"water_blockers":built["snt"]["water_blockers"].size(),
		"horizon":{"surfaces":far_surfaces,"triangles":far_triangles,"trees":far.get_meta("silhouette_count"),"mounds":far.get_meta("mound_count"),"families":far.get_meta("silhouette_families")},"fog_sheets":landscape["fog_sheets"].size()}
	print("route production: ",JSON.stringify(guarantees["registry"])," legacy=",counts," roofs=",roof_count)

func _shape_same(a: Array,b: Array) -> bool:
	if a.size()!=14 or b.size()!=14: return false
	for component in 14:
		if absf(float(a[component])-float(b[component]))>.000000001: return false
	return true

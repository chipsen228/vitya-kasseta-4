## Диагностический actual-main аудит. Камеры проверяем геометрией; художественную оценку дают кадры.
extends SceneTree

const INTERIORS := preload("res://src/environment_interiors.gd")
const OUTPUT := "C:/Users/Peter Zakharov/Desktop/vitya-godot/output/environment-refresh/"
var errors: Array[String]=[]
var main: Node
var world: Node3D
var col: CollisionWorld


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	main=(load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for index in 5000:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		printerr("review inventory: boot did not finish");quit(1);return
	main.set("running",false)
	world=(main.get("render_chain") as RenderChain).world_root
	col=main.get("col")
	await physics_frame
	var built: Dictionary=main.get("built")
	var coverage: Dictionary=built.get("environment",{})
	var off:=OS.get_cmdline_user_args().has("--environment=off")
	var report: Dictionary={"capture_stage":"actual main boot_ready after final scene material quality",
		"environment":"off" if off else ("sample" if OS.get_cmdline_user_args().has("--environment-sample") else "production"), "render_preset":(main.get("render_chain") as RenderChain).render_preset(),
		"visual_verified":false,"visual_reason":"Headless geometry/material audit; no GPU frame or artistic approval",
		"physics":_physics(),"nav_sha256":FileAccess.get_sha256("res://data/nav_baked.json"),
		"base_triangles":built.get("triangles",0),"rooms":[],"cars":[],"public_sites":[],"registry_services":[],
		"public_added":built.get("environment_public",{}),"interior_finish":built.get("environment_interiors",{}),
		"registry_errors":coverage.get("errors",[]),"registry_actual_resources":coverage.get("resources",[]),
		"vehicle_source_sha256":FileAccess.get_sha256("res://src/vehicle_visuals.gd")}
	var legacy: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/environment_views.json"))
	var preferred: Dictionary={}
	for view: Dictionary in legacy["views"]:
		if view.get("view","")=="detail": preferred[view["id"]]=view
	for room: Dictionary in INTERIORS._rooms():
		var view: Dictionary=preferred.get(room["id"],INTERIORS._view(room))
		var eye: Array=view.get("at",view.get("eye",[]))
		if room["id"]=="arkady":
			# The original whole-house collider covers this visual niche. Review it from the existing porch.
			var door: Array=StreetWorld.data()["HOUSES"][0]["door"]
			var x: float=(float(door[0])+float(door[1]))*.5
			var control:=_stance({"id":"arkady","box":[x-.85,x+.85,-7.0,-6.05],"floor":0.0},Vector2(x,-6.525),view["target"])
			control["location"]="exterior-threshold"
			control["source_room_footprint"]=room["box"]
			control["note"]="Original solid whole-house proxy blocks the visual vestibule; no walkable interior claimed"
			report["rooms"].append(control)
		else: report["rooms"].append(_stance(room,Vector2(float(eye[0]),float(eye[2])),view["target"]))
	report["roof_side"]=_roof_side()
	for plot: Dictionary in SntWorld.data().get("PLOTS",[]): report["cars"].append(_car(plot))
	for row: Dictionary in coverage.get("retained_objects",[]):
		if row["kind"]!="public-site": continue
		var checked:=row.duplicate(true)
		checked["actual_meshes"]=[]
		for path: String in row["nodes"]:
			var mi:=world.get_node_or_null(path) as MeshInstance3D
			if mi!=null: checked["actual_meshes"].append(_mesh(mi.mesh,mi))
		checked["visual_verified"]=false
		report["public_sites"].append(checked)
	for source: Dictionary in EnvironmentRegistry.manifest().get("services",[]):
		var mi:=world.get_node_or_null("environment-"+String(source["id"])) as MeshInstance3D
		var row: Dictionary={"owner":source["id"],"present":mi!=null,"paths":source["paths"],"sourceowners":source.get("owner_keys",[]),"visual_verified":false}
		if mi!=null: row["actual_geometry"]=_mesh(mi.mesh,mi)
		report["registry_services"].append(row)
	if report["rooms"].size()!=18: errors.append("room coverage is not 18")
	if report["cars"].size()!=15: errors.append("car coverage is not 15")
	if report["physics"]["counts"].slice(0,3)!=[311,4,83] or int(report["base_triangles"])!=3885: errors.append("base311/4/83/3885 changed")
	var baseline_path:=OUTPUT+"environment-review-runtime-off.json"
	if not off and FileAccess.file_exists(baseline_path):
		var baseline: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(baseline_path))
		report["physics_same_as_off"]=_same_physics(report["physics"],baseline["physics"])
		if not report["physics_same_as_off"]: errors.append("production environment changed physics from actual-main off")
		report["nav_same_as_off"]=report["nav_sha256"]==baseline["nav_sha256"]
		if not report["nav_same_as_off"]: errors.append("production environment changed navgraph")
	report["geometry_errors"]=errors
	var output:=OUTPUT+"environment-review-runtime"+("-off" if off else "")+".json"
	var file:=FileAccess.open(output,FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	for error: String in errors: printerr("review inventory: ",error)
	print("environment review: %s rooms=%d cars=%d public=%d services=%d/%d" % ["PASS" if errors.is_empty() else "FAIL",report["rooms"].size(),report["cars"].size(),report["public_sites"].size(),coverage.get("services",[]).size(),report["registry_services"].size()])
	main.queue_free()
	await process_frame
	await process_frame
	quit(0 if errors.is_empty() else 1)


func _physics() -> Dictionary:
	var counts: Array=[];var shapes: Array=[];var active: Array=[];var ids: Array=[]
	for index in CollisionWorld.SET_COUNT:
		counts.append(col.box_count(index))
		shapes.append(_hash(col._data[index].to_byte_array()))
		active.append(_hash(col._active[index]))
		ids.append(JSON.stringify(col._by_id[index],"",true).sha256_text())
	var native:=0
	for node: Node in SkinLayer._nodes(world):
		if node is CollisionShape3D: native+=1
	return {"counts":counts,"shape_sha256":shapes,"active_sha256":active,"id_sha256":ids,"native_shapes":native}

func _same_physics(current: Dictionary,baseline: Dictionary) -> bool:
	# JSON numeric values parse as float; byte hashes remain the exact geometry contract.
	if int(current["native_shapes"])!=int(baseline["native_shapes"]): return false
	for index in CollisionWorld.SET_COUNT:
		if int(current["counts"][index])!=int(baseline["counts"][index]): return false
		for key: String in ["shape_sha256","active_sha256","id_sha256"]:
			if String(current[key][index])!=String(baseline[key][index]): return false
	return true


func _hash(bytes: PackedByteArray) -> String:
	var ctx:=HashingContext.new();ctx.start(HashingContext.HASH_SHA256);ctx.update(bytes)
	return ctx.finish().hex_encode()


func _stance(room: Dictionary,preferred: Vector2,target: Array) -> Dictionary:
	var box: Array=room["box"]
	var nominal:=float(room["floor"])
	var candidates: Array[Vector2]=[preferred]
	var centre:=Vector2((float(box[0])+float(box[1]))*.5,(float(box[2])+float(box[3]))*.5)
	candidates.append(centre)
	var x:=float(box[0])+.34
	while x<float(box[1])-.33:
		var z:=float(box[2])+.34
		while z<float(box[3])-.33:
			candidates.append(Vector2(x,z));z+=.16
		x+=.16
	candidates.sort_custom(func(a: Vector2,b: Vector2) -> bool: return a.distance_squared_to(preferred)<b.distance_squared_to(preferred))
	var player:=main.get("player") as Player
	var space:=world.get_world_3d().direct_space_state
	var shape:=CapsuleShape3D.new();shape.radius=Player.RADIUS;shape.height=Player.STAND_HEIGHT
	var probes:=0
	for at: Vector2 in candidates:
		if at.x<float(box[0])+.30 or at.x>float(box[1])-.30 or at.y<float(box[2])+.30 or at.y>float(box[3])-.30: continue
		probes+=1
		var floor_hit:=col.ray_down(at.x,nominal+.20,at.y,CollisionWorld.ALL_SOLID)
		if floor_hit.is_empty() or absf(float(floor_hit["y"])-nominal)>.06 or (floor_hit["normal"] as Vector3).y<.90: continue
		var floor_y:=float(floor_hit["y"])
		var hit:=col.capsule_hit(Vector3(at.x,floor_y+.32,at.y),Vector3(at.x,floor_y+1.50,at.y),.30,CollisionWorld.ALL_SOLID)
		if float(hit.get("depth",0))>.002: continue
		var query:=PhysicsShapeQueryParameters3D.new();query.shape=shape;query.collision_mask=Player.MASK_WORLD
		query.exclude=[player.get_rid()];query.transform=Transform3D(Basis.IDENTITY,Vector3(at.x,floor_y+.02+Player.STAND_HEIGHT*.5,at.y))
		if not space.intersect_shape(query,1).is_empty(): continue
		return {"id":room["id"],"footprint":box,"floor_y":floor_y,"nominal_floor_y":nominal,
			"at":[at.x,floor_y+1.62,at.y],"target":target,"preferred":[preferred.x,preferred.y],
			"stance_shift":at.distance_to(preferred),"probes":probes,"capsule_clear":true,"native_jolt_clear":true,
			"standing_height":Player.STAND_HEIGHT,"capsule_radius":Player.RADIUS,"visual_verified":false}
	errors.append("no normal standing stance in room "+String(room["id"]))
	return {"id":room["id"],"footprint":box,"floor_y":nominal,"at":[preferred.x,nominal+1.62,preferred.y],"target":target,"capsule_clear":false,"native_jolt_clear":false,"probes":probes}


func _car(plot: Dictionary) -> Dictionary:
	var id:=String(plot["id"]);var def: Dictionary=plot["car"]
	var holder:=world.get_node_or_null("props/snt-car-"+id) as Node3D
	if holder==null: errors.append("missing car "+id);return {"id":id,"present":false}
	var expected:=Basis(Vector3.UP,float(def.get("ry",0)))
	var axis_error:=maxf(holder.basis.x.distance_to(expected.x),maxf(holder.basis.y.distance_to(expected.y),holder.basis.z.distance_to(expected.z)))
	if axis_error>.0001: errors.append("wrong final car axes "+id)
	var car_indices: PackedInt32Array=col._by_id[CollisionWorld.SET_OVERLAY].get(id+"-car",PackedInt32Array())
	var index: int=car_indices[0] if car_indices.size()==1 else -1
	var collision: Array=[]
	if index>=0: collision=Array(col._data[CollisionWorld.SET_OVERLAY].slice(index*14,index*14+14))
	else: errors.append("missing original car collider "+id)
	var box:=VehicleVisuals.world_box(def)
	if not collision.is_empty():
		for check: Array in [[0,box[0]],[2,box[2]],[3,box[1]],[5,box[3]],[1,0.0],[4,VehicleVisuals.dimensions(def).y]]:
			if absf(float(collision[check[0]])-float(check[1]))>.00001: errors.append("car collider differs from unchanged world_box "+id)
	var row: Dictionary={"id":id,"present":true,"source_kind":"retained baked procedural vehicle; no environment GLB replacement",
		"family":holder.get_meta("vehicle_family",""),"at":[holder.position.x,holder.position.y,holder.position.z],
		"yaw":float(def.get("ry",0)),"front_axis":_vec(-holder.basis.z),"right_axis":_vec(holder.basis.x),"up_axis":_vec(holder.basis.y),
		"paint_source":int(def.get("paint",0)),"baked_vehicle_resource":ProceduralAssets.asset_path("vehicle/"+String(def["family"])),
		"axis_error":axis_error,"near_meshes":[],"far_meshes":[],"active_meshes":[],"collision_id":id+"-car","collision_shape14":collision,
		"camera_refs":[],"visual_verified":false,"primitive_meshes":[],"near_triangles":0,"far_triangles":0}
	var views: Dictionary=JSON.parse_string(FileAccess.get_file_as_string("res://data/environment_views.json"))
	for view: Dictionary in views["views"]:
		if view.get("owner","")=="snt-car-"+id: row["camera_refs"].append(view)
	var lod:=holder.get_node_or_null("body") as ModelLodMesh
	if lod!=null:
		row["active_lod"]="far" if lod.far_active else "near";row["switch_distance"]=lod.switch_distance
		for number in lod.near_meshes.size():
			var piece:=lod.pieces[number] as MeshInstance3D
			var mesh:=_mesh(lod.near_meshes[number],piece,lod.near_materials[number])
			row["near_meshes"].append(mesh);row["near_triangles"]+=mesh["triangles"]
		for number in lod.far_meshes.size():
			var piece:=lod.pieces[number] as MeshInstance3D
			var mesh:=_mesh(lod.far_meshes[number],piece,lod.far_materials[number])
			row["far_meshes"].append(mesh);row["far_triangles"]+=mesh["triangles"]
	else: errors.append("missing original car LOD "+id)
	for node: Node in SkinLayer._nodes(holder):
		if node is CollisionObject3D or node is CollisionShape3D: errors.append("new native car collision "+id)
		if not node is MeshInstance3D: continue
		var mi:=node as MeshInstance3D
		if mi.mesh is PrimitiveMesh: row["primitive_meshes"].append(String(holder.get_path_to(mi)))
		if mi.visible and mi.layers!=0: row["active_meshes"].append(_mesh(mi.mesh,mi))
	if row["near_triangles"]<500: errors.append("unexpectedly trivial near car "+id)
	return row


func _roof_side() -> Dictionary:
	var row:=_stance({"id":"hero-roof-side","box":[4.5,8.5,-5.0,-1.0],"floor":0.0},Vector2(6.5,-3),[-1.0,6.5,13.0])
	var eye:=Vector3(row["at"][0],row["at"][1],row["at"][2])
	var target:=Vector3(-1,6.5,13)
	var camera: Camera3D=(main.get("render_chain") as RenderChain).camera
	camera.global_position=eye
	camera.look_at(target)
	for node: Node in SkinLayer._nodes(world):
		if node is EnvironmentLod: (node as EnvironmentLod)._process(.13)
		elif node is ModelLodMesh: (node as ModelLodMesh)._process(.13)
	var first: Dictionary={}
	var nearest:=INF
	var examined:=0
	for node: Node in SkinLayer._nodes(world):
		if not node is MeshInstance3D: continue
		var mi:=node as MeshInstance3D
		if mi.mesh==null or mi.layers==0 or not mi.is_visible_in_tree(): continue
		if mi.visibility_range_end>0 and eye.distance_to(mi.global_position)>mi.visibility_range_end: continue
		var transform:=mi.global_transform
		var local_start:=transform.affine_inverse()*eye
		var local_end:=transform.affine_inverse()*(eye+(target-eye).normalized()*100.0)
		if mi.mesh.get_aabb().intersects_segment(local_start,local_end)==null: continue
		for surface in mi.mesh.get_surface_count():
			var arrays:=mi.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
			var count:=indices.size() if not indices.is_empty() else vertices.size()
			for index in range(0,count,3):
				examined+=1
				var a:=transform*vertices[indices[index] if not indices.is_empty() else index]
				var b:=transform*vertices[indices[index+1] if not indices.is_empty() else index+1]
				var c:=transform*vertices[indices[index+2] if not indices.is_empty() else index+2]
				var hit: Variant=Geometry3D.ray_intersects_triangle(eye,(target-eye).normalized(),a,b,c)
				if hit is Vector3 and eye.distance_to(hit)<nearest:
					nearest=eye.distance_to(hit)
					first={"node":String(world.get_path_to(mi)),"surface":surface,"distance":nearest,"point":_vec(hit),"environment_owner":mi.get_meta("environment_owner","")}
	row["first_mesh_ray"]=first
	row["ray_triangles_examined"]=examined
	row["target_owner_verified"]=String(first.get("node","")).contains("environment-vitya")
	row["note"]="Side roof control: actual visible first mesh ray reaches environment-vitya; capsule and Jolt stance verified"
	if not OS.get_cmdline_user_args().has("--environment=off") and not row["target_owner_verified"]: errors.append("hero side view blocked by "+String(first.get("node","none")))
	return row


func _vec(v: Vector3) -> Array:
	return [v.x,v.y,v.z]


func _mesh(mesh: Mesh,mi: MeshInstance3D,override: Material=null) -> Dictionary:
	var out: Dictionary={"node":String(world.get_path_to(mi)),"mesh_class":mesh.get_class() if mesh!=null else "null",
		"mesh_resource":mesh.resource_path if mesh!=null else "","triangles":0,"surfaces":[],"normal_vertices":0,"uv_vertices":0,"tangent_vertices":0}
	if mesh==null: return out
	var box:=mesh.get_aabb();out["local_bounds"]={"min":_vec(box.position),"size":_vec(box.size)}
	for surface in mesh.get_surface_count():
		var arrays:=mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var indices: Variant=arrays[Mesh.ARRAY_INDEX]
		out["triangles"]+=(indices.size() if indices!=null and not indices.is_empty() else vertices.size())/3
		for field: int in [Mesh.ARRAY_NORMAL,Mesh.ARRAY_TEX_UV,Mesh.ARRAY_TANGENT]:
			var values: Variant=arrays[field]
			var key: String="normal_vertices" if field==Mesh.ARRAY_NORMAL else "uv_vertices" if field==Mesh.ARRAY_TEX_UV else "tangent_vertices"
			if values!=null: out[key]+=values.size()/4 if field==Mesh.ARRAY_TANGENT else values.size()
		var material: Material=override if override!=null else mi.get_active_material(surface)
		var descriptor: Dictionary={"class":material.get_class() if material!=null else "null","shader":"","textures":{},"parameters":{}}
		if material is ShaderMaterial:
			var shader:=material as ShaderMaterial
			descriptor["shader"]=shader.shader.resource_path
			for uniform: Dictionary in shader.shader.get_shader_uniform_list():
				var value: Variant=shader.get_shader_parameter(uniform["name"])
				if value is Texture2D: descriptor["textures"][uniform["name"]]=value.resource_path
				elif value is float or value is bool or value is int: descriptor["parameters"][uniform["name"]]=value
				elif value is Color: descriptor["parameters"][uniform["name"]]=[value.r,value.g,value.b,value.a]
		if descriptor["shader"]==Materials.PSX_SHADER: errors.append("postquality retained PSX material "+String(mi.name))
		out["surfaces"].append(descriptor)
	return out

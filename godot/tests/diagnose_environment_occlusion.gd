## Diagnostic only. No production integration or acceptance-budget changes.
## GPU: --script res://tests/diagnose_environment_occlusion.gd -- --run-gpu --render=hq
## CPU extraction oracle: same script with --headless and -- --cpu-only.
## Native culling uses full instance AABBs; directional shadow submissions remain
## independent (renderer_scene_cull.cpp:2927-2930,3240-3249, a13da4feb).
extends SceneTree

const VIEWS := [
	{"id":"route-peak","eye":Vector3(-.0650889575,1.68,1.933727622),
		"yaw":.280756237,"pitch":sin(22.740736*.9)*.12},
	{"id":"cellar-transfer","eye":Vector3(-3,.1300000548,10.5),"yaw":0.0,"pitch":0.0},
]
const HQ_PATHS := [Materials.HQ_SHADER,Materials.HQ_OPAQUE_SHADER,
	Materials.HQ_ALPHA_SHADER,Materials.HQ_OPAQUE_ALPHA_SHADER]
const GROUND_KEYS := ["grass","dirt","gravel"]
var main: Node
var chain: RenderChain
var output := "res://../output/environment-refresh/native-occlusion.json"
var report: Dictionary = {"diagnostic_only":true,"production_integration":false,
	"gpu_verified":false,"cpu_oracle_executed":false,"views":[],"errors":[],
	"scope":"current visible opaque WorldBuilder ground/slabs/walls + source-derived EnvironmentInteriors floor/wall",
	"holes":"exact admitted triangle subset; no hull, rectangle fill, weld, decimation or physics geometry",
	"production_limit":"Occluder subsets are view-specific: front-facing cull_back triangles and source ranges are evaluated per eye. They cannot become a permanent moving-camera occluder without separate synchronization/closed-solid proof.",
	"shadow_limit":"Directional shadow collection does not use camera occlusion predicate",
	"sources":["https://docs.godotengine.org/en/stable/tutorials/3d/occlusion_culling.html",
		"https://docs.godotengine.org/en/stable/classes/class_viewport.html#class-viewport-property-use-occlusion-culling",
		"output/environment-refresh/godot-a13da4feb-renderer_scene_cull.cpp:2927",
		"output/environment-refresh/godot-a13da4feb-renderer_scene_cull.cpp:3240"]}
var time_overrides: Array[Dictionary] = []
var frozen_nodes: Array[Dictionary] = []
var wall_owners: Dictionary = {}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	for arg: String in args:
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	_cpu_oracle()
	if args.has("--cpu-only"):
		_finish()
		return
	if not args.has("--run-gpu") or DisplayServer.get_name() == "headless":
		report["errors"].append("GPU diagnostic requires explicit --run-gpu, a real window and Compatibility renderer")
		_finish()
		return
	root.size = Vector2i(1280,720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	main = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for i in 3000:
		if main.get("boot_ready"): break
		await process_frame
	if not main.get("boot_ready"):
		report["errors"].append("Actual Main boot timeout")
		await _cleanup()
		_finish()
		return
	chain = main.get("render_chain")
	chain.apply_preset("hq")
	main.set("running",false)
	report["renderer"] = RenderingServer.get_current_rendering_method()
	report["gpu"] = RenderingServer.get_video_adapter_name()
	report["engine"] = Engine.get_version_info()
	report["buffer"] = chain.stats().get("buffer")
	if report["renderer"] != "gl_compatibility":
		report["errors"].append("Fixture requests actual gl_compatibility")
	for row: Dictionary in GameData.site()["WALLS"]:
		wall_owners["buildings/site/"+String(row.get("id","WALLS"))] = true
	var col: CollisionWorld = main.get("col")
	var physics_before := _physics_stamp(col)
	var sources: Array[Dictionary] = _sources(chain.world_root)
	report["eligible_source_nodes"] = sources.size()
	var before: Array[Dictionary] = _source_stamp(sources)
	var prior_occlusion := chain.world_view.use_occlusion_culling
	for view: Dictionary in VIEWS:
		_set_view(view)
		for i in 96: await process_frame
		# The renderer keeps the real current LOD/visibility/material state. Only
		# test-local TIME shaders and animation clocks are held for byte comparison.
		_freeze_scene()
		var extracted := _extract(sources,chain.camera.global_position,chain.camera.cull_mask)
		var record: Dictionary = {"id":view["id"],"eye":_v(chain.camera.global_position),
			"rotation":_v(chain.camera.global_rotation),"source_triangles":extracted["triangles"],
			"source_records":extracted["records"],"vertices_sha256":_sha(extracted["vertices"].to_byte_array()),
			"indices_sha256":_sha(extracted["indices"].to_byte_array()),"rejected":extracted["rejected"],
			"cull_back_triangles":extracted["cull_back_triangles"],"cull_disabled_triangles":extracted["cull_disabled_triangles"],
			"camera_independent_triangles":extracted["camera_independent_triangles"]}
		var native := OccluderInstance3D.new()
		native.name = "diagnostic-exact-source-occluder"
		var shape := ArrayOccluder3D.new()
		shape.set_arrays(extracted["vertices"],extracted["indices"])
		native.occluder = shape
		chain.world_root.add_child(native)
		native.top_level = true
		native.global_transform = Transform3D.IDENTITY
		if shape.get_vertices() != extracted["vertices"] or shape.get_indices() != extracted["indices"]:
			report["errors"].append("Native ArrayOccluder3D array roundtrip changed source subset: "+String(view["id"]))
		var off_a: Dictionary = await _sample(String(view["id"]),"off-a",false)
		var on: Dictionary = await _sample(String(view["id"]),"on",true)
		var off_b: Dictionary = await _sample(String(view["id"]),"off-b",false)
		record["off_a"] = _without_pixels(off_a)
		record["on"] = _without_pixels(on)
		record["off_b"] = _without_pixels(off_b)
		record["off_repeat_diff"] = _pixel_diff(off_a["pixels"],off_b["pixels"])
		record["on_diff"] = _pixel_diff(off_a["pixels"],on["pixels"])
		record["visual_identity_verified"] = record["off_repeat_diff"]["different_bytes"] == 0 \
			and record["on_diff"]["different_bytes"] == 0
		record["calls_delta"] = int(off_a["stats"]["calls"])-int(on["stats"]["calls"])
		record["triangles_delta"] = int(off_a["stats"]["tris"])-int(on["stats"]["tris"])
		record["observed_effect"] = record["calls_delta"] != 0 or record["triangles_delta"] != 0
		if extracted["triangles"] == 0: report["errors"].append("No admitted exact opaque cohort: "+String(view["id"]))
		if not record["visual_identity_verified"]:
			report["errors"].append("Pixel identity not verified; OFF repeat nondeterminism is not waived: "+String(view["id"]))
		report["views"].append(record)
		native.queue_free()
		await process_frame
		_unfreeze_scene()
	chain.world_view.use_occlusion_culling = prior_occlusion
	report["source_geometry_material_pose_visibility_unchanged"] = before == _source_stamp(sources)
	report["physics_unchanged"] = physics_before == _physics_stamp(col)
	if not report["source_geometry_material_pose_visibility_unchanged"] or not report["physics_unchanged"]:
		report["errors"].append("Diagnostic failed source/physics identity guard")
	report["gpu_executed"] = true
	report["gpu_verified"] = report["errors"].is_empty()
	report["meaning"] = "Two isolated fixed views, not whole-route geometry/FPS acceptance. Zero effect with a nonempty cohort requires engine/backend investigation; it does not prove unsupported Compatibility."
	await _cleanup()
	_finish()

func _set_view(view: Dictionary) -> void:
	chain.camera.make_current()
	chain.camera.global_position = view["eye"]
	chain.camera.global_rotation = Vector3(view["pitch"],view["yaw"],0)
	var lights: LightRig = main.get("lights")
	lights.powerOn = true
	for id: String in lights.state: lights.setLamp(id,id in ["porch","hall","kitchen","landing","vitya"])
	lights.set_night_immediate(.8)
	lights.update(1.0,chain.camera.global_position,"plot",true)
	var flashlight: Flashlight = main.get("flashlight")
	flashlight.on = true
	flashlight.light.visible = true
	flashlight.set("_body",chain.camera.global_position)
	flashlight.set("_aim",chain.camera.global_position-chain.camera.global_basis.z*6.0)
	flashlight.update(0.0)

func _sample(id: String,stage: String,enabled: bool) -> Dictionary:
	chain.world_view.use_occlusion_culling = enabled
	# Native occlusion has temporal hysteresis; settle both toggles identically.
	for i in 48: await process_frame
	var samples: Array[float] = []
	var cpu: Array[float] = []
	var peak: Dictionary = {"calls":0,"tris":0,"objects":0}
	for i in 90:
		var start := Time.get_ticks_usec()
		await process_frame
		samples.append(float(Time.get_ticks_usec()-start)/1000.0)
		cpu.append(Performance.get_monitor(Performance.TIME_PROCESS)*1000.0)
		var stats: Dictionary = chain.stats()
		for field: String in peak: peak[field] = maxi(int(peak[field]),int(stats.get(field,0)))
	await RenderingServer.frame_post_draw
	var image := chain.world_view.get_texture().get_image()
	var path := output.get_base_dir().path_join("native-occlusion-"+id+"-"+stage+".png")
	var image_error := image.save_png(path)
	if image_error != OK: report["errors"].append("Cannot save diagnostic PNG: "+path)
	samples.sort()
	cpu.sort()
	return {"use_occlusion_culling":chain.world_view.use_occlusion_culling,"stats":peak,
		"p95_ms":samples[mini(samples.size()-1,int(ceil(samples.size()*.95))-1)],
		"mean_ms":_mean(samples),"mean_cpu_process_ms":_mean(cpu),
		"frames":samples.size(),"image":path,"image_size":[image.get_width(),image.get_height()],
		"pixels":image.get_data(),"pixel_sha256":_sha(image.get_data())}

func _sources(world: Node3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for node: Node in SkinLayer._nodes(world):
		if not node is MeshInstance3D: continue
		var mesh_node := node as MeshInstance3D
		if not _static_source(mesh_node): continue
		var ancestor: Node = mesh_node
		while ancestor != world and not String(ancestor.name).begins_with("merged"):
			ancestor = ancestor.get_parent()
		var interior := node.has_meta("environment_interior_role") \
			and String(node.get_meta("environment_interior_role")) in ["floor","wall"]
		if not interior and ancestor == world: continue
		var original := mesh_node if interior else ancestor as MeshInstance3D
		if original == null: continue
		var accepted: Dictionary = {}
		if original.has_meta("skin_parts") and original.mesh != null and original.mesh.get_surface_count() == 1:
			var arrays := original.mesh.surface_get_arrays(0)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var parts: Dictionary = original.get_meta("skin_parts")
			for owner: String in parts:
				if not _owner_allowed(owner): continue
				for span: Vector2i in parts[owner]:
					for index in range(span.x,span.x+span.y,3):
						if index+2 >= verts.size(): continue
						accepted[_triangle_key(verts[index],verts[index+1],verts[index+2])] = owner
		var ground := false
		for key: String in GROUND_KEYS:
			if String(original.name).contains("_"+key+"_") or String(original.name).contains(":"+key+":"): ground = true
		result.append({"node":mesh_node,"original":original,"interior":interior,
			"ground":ground,"allowed_triangles":accepted})
	return result

func _static_source(node: MeshInstance3D) -> bool:
	if not node.mesh is ArrayMesh or node.layers == 0 or not node.is_visible_in_tree() or node.get_script() != null \
			or node.get_node_or_null(node.skeleton) is Skeleton3D or (node.mesh as ArrayMesh).get_blend_shape_count() != 0 \
			or node.material_overlay != null: return false
	if node.global_basis.determinant()<=0.000001: return false
	for mark: String in ["static_shadow_proxy","environment_shadow_proxy","skin_asset","independent_visual","dynamic_pool"]:
		if node.has_meta(mark): return false
	if node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY: return false
	return true

func _owner_allowed(owner: String) -> bool:
	return wall_owners.has(owner) or owner.begins_with("buildings/site/SLABS-")

func _extract(sources: Array[Dictionary],eye: Vector3,camera_mask: int = 1) -> Dictionary:
	var vertices := PackedVector3Array()
	var indices := PackedInt32Array()
	var records: Array[Dictionary] = []
	var rejected: Dictionary = {"source_inactive":0,"range":0,"material":0,"noncohort":0,
		"nonplanar_axis":0,"backface":0,"invalid_geometry":0}
	var cull_back := 0
	var cull_disabled := 0
	var camera_independent := 0
	for source: Dictionary in sources:
		var node: MeshInstance3D = source["node"]
		if not _static_source(node) or (node.layers&camera_mask)==0: rejected["source_inactive"] += 1; continue
		if not _range_safe(node,eye): rejected["range"] += 1; continue
		var count := 0
		var owners: Dictionary = {}
		var mesh := node.mesh as ArrayMesh
		for surface in node.mesh.get_surface_count():
			var cull := _opaque_cull(node.get_active_material(surface))
			if cull < 0: rejected["material"] += 1; continue
			if mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
				rejected["invalid_geometry"] += 1; continue
			var arrays := node.mesh.surface_get_arrays(surface)
			var deformed := false
			for slot in [Mesh.ARRAY_BONES,Mesh.ARRAY_WEIGHTS,Mesh.ARRAY_CUSTOM0,Mesh.ARRAY_CUSTOM1,Mesh.ARRAY_CUSTOM2,Mesh.ARRAY_CUSTOM3]:
				if arrays[slot]!=null and not arrays[slot].is_empty(): deformed = true
			if deformed: rejected["invalid_geometry"] += 1; continue
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var order: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if order.is_empty():
				order.resize(verts.size())
				for index in verts.size(): order[index] = index
			if order.size()%3 != 0: rejected["invalid_geometry"] += 1; continue
			for index in range(0,order.size(),3):
				if order[index]<0 or order[index+1]<0 or order[index+2]<0 \
						or order[index]>=verts.size() or order[index+1]>=verts.size() or order[index+2]>=verts.size():
					rejected["invalid_geometry"] += 1; continue
				var a := verts[order[index]]
				var b := verts[order[index+1]]
				var c := verts[order[index+2]]
				var owner := String(source["allowed_triangles"].get(_triangle_key(a,b,c),""))
				a = node.global_transform*a
				b = node.global_transform*b
				c = node.global_transform*c
				var axis := _axis(a,b,c)
				if axis < 0: rejected["nonplanar_axis"] += 1; continue
				if owner.is_empty() and not source["interior"] and not (source["ground"] and axis == 1):
					rejected["noncohort"] += 1; continue
				var normal := (b-a).cross(c-a)
				if not a.is_finite() or not b.is_finite() or not c.is_finite() or normal.length_squared()<1e-12:
					rejected["invalid_geometry"] += 1; continue
				# Godot front faces use clockwise winding. Native occluders are
				# double-sided, so include only visible fronts for cull_back sources.
				if cull == BaseMaterial3D.CULL_BACK and normal.dot(eye-a)>=-1e-9:
					rejected["backface"] += 1; continue
				var start := vertices.size()
				vertices.append_array(PackedVector3Array([a,b,c]))
				indices.append_array(PackedInt32Array([start,start+1,start+2]))
				count += 1
				if cull == BaseMaterial3D.CULL_BACK: cull_back += 1
				else:
					cull_disabled += 1
					if node.visibility_range_begin==0.0 and node.visibility_range_end==0.0: camera_independent += 1
				if not owner.is_empty(): owners[owner] = true
		if count > 0:
			records.append({"node":String(node.get_path()),"source":String(source["original"].get_path()),
				"mesh_resource":node.mesh.resource_path,"source_mesh_id":node.mesh.get_instance_id(),
				"triangles":count,"owners":owners.keys(),"interior_role":node.get_meta("environment_interior_role","")})
	return {"vertices":vertices,"indices":indices,"triangles":indices.size()/3,"records":records,"rejected":rejected,
		"cull_back_triangles":cull_back,"cull_disabled_triangles":cull_disabled,"camera_independent_triangles":camera_independent}

func _range_safe(node: MeshInstance3D,eye: Vector3) -> bool:
	# Native range is a renderer-side check; an OccluderInstance has no range.
	# Admit only the stable interior of both origin/center distances per view.
	for point: Vector3 in [node.global_position,node.global_transform*node.mesh.get_aabb().get_center()]:
		var distance := eye.distance_to(point)
		if node.visibility_range_begin>0 and distance<=node.visibility_range_begin+node.visibility_range_begin_margin: return false
		if node.visibility_range_end>0 and distance>=node.visibility_range_end-node.visibility_range_end_margin: return false
	return node.visibility_parent == NodePath("") \
		and node.visibility_range_fade_mode == GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

func _opaque_cull(material: Material) -> int:
	if not material is ShaderMaterial or material.next_pass != null: return -1
	var shader_material := material as ShaderMaterial
	if shader_material.shader == null or shader_material.shader.resource_path not in HQ_PATHS: return -1
	if not EnvironmentLod._undeformed_hq(shader_material.shader): return -1
	var cut: Variant = shader_material.get_shader_parameter("alpha_cut")
	var color: Variant = shader_material.get_shader_parameter("albedo")
	if cut != null and (not cut is float and not cut is int or float(cut)!=0.0): return -1
	if color != null and (not color is Color or (color as Color).a!=1.0): return -1
	return BaseMaterial3D.CULL_DISABLED if shader_material.shader.resource_path in [Materials.HQ_ALPHA_SHADER,Materials.HQ_OPAQUE_ALPHA_SHADER] else BaseMaterial3D.CULL_BACK

func _axis(a: Vector3,b: Vector3,c: Vector3) -> int:
	for axis in 3:
		if a[axis] == b[axis] and a[axis] == c[axis]: return axis
	return -1

func _triangle_key(a: Vector3,b: Vector3,c: Vector3) -> String:
	return PackedVector3Array([a,b,c]).to_byte_array().hex_encode()

func _freeze_scene() -> void:
	for node: Node in SkinLayer._nodes(main):
		frozen_nodes.append({"node":node,"process":node.is_processing(),"physics":node.is_physics_processing()})
		node.set_process(false)
		node.set_physics_process(false)
		if node is AnimationPlayer and node.is_playing():
			frozen_nodes[-1]["animation"] = true
			node.pause()
		if node is MeshInstance3D and node.mesh != null:
			for surface in node.mesh.get_surface_count():
				var material := node.get_active_material(surface) as ShaderMaterial
				if material == null or material.shader == null or not material.shader.code.contains("TIME"): continue
				var copy := material.duplicate() as ShaderMaterial
				var shader := Shader.new()
				var pattern := RegEx.new()
				pattern.compile("\\bTIME\\b")
				shader.code = pattern.sub(material.shader.code,"0.0",true)
				copy.shader = shader
				time_overrides.append({"node":node,"surface":surface,"prior":node.get_surface_override_material(surface)})
				node.set_surface_override_material(surface,copy)

func _unfreeze_scene() -> void:
	for row: Dictionary in time_overrides:
		row["node"].set_surface_override_material(row["surface"],row["prior"])
	time_overrides.clear()
	for row: Dictionary in frozen_nodes:
		row["node"].set_process(row["process"])
		row["node"].set_physics_process(row["physics"])
		if row.has("animation"): row["node"].play()
	frozen_nodes.clear()

func _source_stamp(sources: Array[Dictionary]) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for row: Dictionary in sources:
		var node: MeshInstance3D = row["node"]
		var hashes: Array = []
		var materials: Array = []
		for surface in node.mesh.get_surface_count():
			var arrays := node.mesh.surface_get_arrays(surface)
			for slot in Mesh.ARRAY_MAX:
				var value: Variant = arrays[slot]
				hashes.append(_sha(var_to_bytes(value)))
			var material := node.get_active_material(surface)
			materials.append(material.get_instance_id() if material != null else 0)
		result.append({"id":node.get_instance_id(),"mesh":node.mesh.get_instance_id(),"arrays":hashes,
			"materials":materials,"transform":node.global_transform,"visible":node.visible,"layers":node.layers,
			"shadow":node.cast_shadow,"begin":node.visibility_range_begin,"end":node.visibility_range_end})
	return result

func _physics_stamp(col: CollisionWorld) -> String:
	return _sha(var_to_bytes([col.get("_data"),col.get("_active"),col.get("_by_id")]))

func _cpu_oracle() -> void:
	# Four filled panels leave a genuine window/door gap. Native arrays must
	# contain precisely these triangles; center ray stays unobstructed.
	var verts := PackedVector3Array()
	for box: Rect2 in [Rect2(-2,0,1,3),Rect2(1,0,1,3),Rect2(-1,0,2,1),Rect2(-1,2,2,1)]:
		var a := Vector3(box.position.x,box.position.y,0)
		var b := Vector3(box.end.x,box.position.y,0)
		var c := Vector3(box.end.x,box.end.y,0)
		var d := Vector3(box.position.x,box.end.y,0)
		verts.append_array(PackedVector3Array([a,c,b,a,d,c]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var node := MeshInstance3D.new()
	node.name = "environment-interior-oracle"
	node.mesh = mesh
	var material := ShaderMaterial.new()
	material.shader = load(Materials.HQ_OPAQUE_SHADER)
	node.material_override = material
	node.set_meta("environment_interior_role","wall")
	var world := Node3D.new()
	world.add_child(node)
	root.add_child(world)
	var source: Array[Dictionary] = [{"node":node,"original":node,"interior":true,"ground":false,"allowed_triangles":{}}]
	var extracted := _extract(source,Vector3(0,1.5,3))
	_check(extracted["vertices"]==verts,"Exact opaque panels changed")
	_check(int(extracted["triangles"])==8,"Window panels were filled/removed")
	_check(not _ray_hits(extracted["vertices"],Vector3(0,1.5,3),Vector3(0,0,-1)),"Window hole closed")
	_check(_ray_hits(extracted["vertices"],Vector3(-1.5,1.5,3),Vector3(0,0,-1)),"Solid wall panel absent")
	_check(_extract(source,Vector3(0,1.5,-3))["triangles"]==0,"Back-culled wall admitted from behind")
	var door_vertices := PackedVector3Array()
	door_vertices.append_array(verts.slice(0,12))
	door_vertices.append_array(verts.slice(18,24))
	_check(not _ray_hits(door_vertices,Vector3(0,.5,3),Vector3(0,0,-1)),"Door hole closed")
	_check(_ray_hits(door_vertices,Vector3(0,2.5,3),Vector3(0,0,-1)),"Door lintel absent")
	node.layers = 0
	_check(_extract(source,Vector3(0,1.5,3))["triangles"]==0,"layers0 source admitted")
	node.layers = 1
	node.visible = false
	_check(_extract(source,Vector3(0,1.5,3))["triangles"]==0,"hidden source admitted")
	node.visible = true
	material.set_shader_parameter("alpha_cut",.5)
	_check(_extract(source,Vector3(0,1.5,3))["triangles"]==0,"alpha-cut hole source admitted")
	material.set_shader_parameter("alpha_cut",0.0)
	node.set_meta("dynamic_pool",true)
	_check(_extract(source,Vector3(0,1.5,3))["triangles"]==0,"dynamic source admitted")
	node.remove_meta("dynamic_pool")
	_check(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]==verts,"Source geometry mutated")
	world.free()
	report["cpu_oracle_executed"] = true
	report["cpu_oracle_checks"] = 12

func _ray_hits(vertices: PackedVector3Array,from: Vector3,direction: Vector3) -> bool:
	for index in range(0,vertices.size(),3):
		if Geometry3D.ray_intersects_triangle(from,direction,vertices[index],vertices[index+1],vertices[index+2]) != null: return true
	return false

func _check(condition: bool,message: String) -> void:
	if not condition: report["errors"].append("CPU oracle: "+message)

func _without_pixels(row: Dictionary) -> Dictionary:
	var copy := row.duplicate()
	copy.erase("pixels")
	return copy

func _pixel_diff(a: PackedByteArray,b: PackedByteArray) -> Dictionary:
	if a.size()!=b.size(): return {"different_bytes":-1,"max_delta":-1,"sizes":[a.size(),b.size()]}
	var count := 0
	var maximum := 0
	for index in a.size():
		if a[index]!=b[index]: count+=1; maximum=maxi(maximum,absi(int(a[index])-int(b[index])))
	return {"different_bytes":count,"max_delta":maximum}

func _sha(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()

func _mean(values: Array[float]) -> float:
	var total := 0.0
	for value in values: total += value
	return total/maxi(1,values.size())

func _v(value: Vector3) -> Array:
	return [value.x,value.y,value.z]

func _cleanup() -> void:
	if not frozen_nodes.is_empty(): _unfreeze_scene()
	if is_instance_valid(main): main.queue_free()
	await process_frame
	await process_frame

func _finish() -> void:
	DirAccess.make_dir_recursive_absolute(output.get_base_dir())
	var file := FileAccess.open(output,FileAccess.WRITE)
	if file == null:
		printerr("diagnose_environment_occlusion: cannot write "+output)
		quit(2)
		return
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("diagnose_environment_occlusion: %s diagnostic only; %s" % ["READY" if report["errors"].is_empty() else "FAIL",output])
	quit(0 if report["errors"].is_empty() else 1)

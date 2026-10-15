## CPU source/orientation/range oracle; renderer pixel proof is a separate GPU test.
extends SceneTree
const MODULE := preload("res://src/environment_occlusion.gd")
var checks := 0
var errors: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var source := MeshInstance3D.new()
	source.name = "environment-interior-oracle"
	source.set_meta("environment_interior_role","wall")
	var vertices := PackedVector3Array()
	for box: Rect2 in [Rect2(-2,0,1,3),Rect2(1,0,1,3),Rect2(-1,0,2,1),Rect2(-1,2,2,1)]:
		var a := Vector3(box.position.x,box.position.y,0)
		var b := Vector3(box.end.x,box.position.y,0)
		var c := Vector3(box.end.x,box.end.y,0)
		var d := Vector3(box.position.x,box.end.y,0)
		vertices.append_array(PackedVector3Array([a,c,b,a,d,c]))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	source.mesh = mesh
	source.position = Vector3(2,0,0)
	var material := ShaderMaterial.new()
	material.shader = load(Materials.PSX_SHADER)
	source.material_override = material
	world.add_child(source)
	var omni := OmniLight3D.new()
	omni.name = "unit-existing-omni"
	omni.position = Vector3(-2,2,3)
	omni.light_energy = .7
	omni.omni_range = 8.0
	omni.shadow_enabled = true
	world.add_child(omni)
	var spot := SpotLight3D.new()
	spot.name = "unit-existing-spot"
	spot.position = Vector3(2,3,2)
	spot.light_energy = .9
	spot.spot_range = 9.0
	spot.shadow_enabled = true
	world.add_child(spot)
	var sun := DirectionalLight3D.new()
	world.add_child(sun)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.global_position = Vector3(2,1.5,3)
	camera.make_current()
	var prior_flag := root.use_occlusion_culling
	root.use_occlusion_culling = false
	var controller: Variant = MODULE.prepare(root,world)
	_check(controller.report["sources"]==1,"Source cohort count")
	_check(controller.report["planes"]==1,"Coplanar panels were not grouped")
	_check(controller.report["triangles"]==8,"Panels changed triangle count")
	_check(controller.report["array_builds"]==1,"Plane arrays must be built once")
	_check(not controller.is_processing(),"Controller enabled before warm")
	_check(controller.report["light_sources"]==2 and controller.report["owned_light_flags"]==0,"Startup must cache only positional lights without setting flags")
	controller.set_enabled(true)
	controller.set_hq(false)
	controller.update()
	_check(controller.report["active_planes"]==0,"Retro startup occluder active")
	# Retro startup still caches source arrays; switching HQ needs no extraction.
	material.shader = load(Materials.HQ_OPAQUE_SHADER)
	controller.set_hq(true)
	controller.update()
	_check(controller.report["active_planes"]==1,"HQ switch did not admit cached plane")
	await _light_guard(controller,world,camera,omni,spot)
	var plane: OccluderInstance3D = controller.get_child(0)
	var shape := plane.occluder as ArrayOccluder3D
	var points := shape.get_vertices()
	var original_indices := shape.get_indices()
	for i in vertices.size(): _check(points[i]==source.global_transform*vertices[i],"Exact transformed vertex %d"%i)
	_check(not _ray(points,Vector3(2,1.5,3)),"Window gap was filled")
	_check(_ray(points,Vector3(.5,1.5,3)),"Solid panel removed")
	var door := PackedVector3Array()
	door.append_array(points.slice(0,12)); door.append_array(points.slice(18,24))
	_check(not _ray(door,Vector3(2,.5,3)),"Door gap was filled")
	_check(_ray(door,Vector3(2,2.5,3)),"Door lintel removed")
	camera.global_position.z = -3
	controller.update()
	_check(not plane.visible,"Backface remained an occluder after crossing")
	camera.global_position.z = 0
	controller.update()
	_check(not plane.visible,"Eye on plane kept occluder")
	camera.global_position.z = 3
	controller.update()
	_check(plane.visible,"Returning to front failed")
	var other_camera := Camera3D.new()
	world.add_child(other_camera)
	other_camera.global_position = Vector3(2,1.5,-3)
	other_camera.make_current()
	controller.update()
	_check(not plane.visible,"Controller used stale Player camera instead of current camera")
	other_camera.clear_current(false)
	controller.update()
	_check(not plane.visible and not root.use_occlusion_culling,"No current camera kept native occlusion")
	camera.make_current()
	controller.update()
	_check(plane.visible,"Returning from other current camera failed")
	other_camera.queue_free()
	source.visibility_range_end = 4
	source.visibility_range_end_margin = 0
	camera.global_position.z = 6
	controller.update()
	_check(not plane.visible,"Source outside range kept occluder")
	camera.global_position.z = 3
	controller.update()
	_check(plane.visible,"Source range return failed")
	source.layers = 0
	controller.update()
	_check(not plane.visible,"layers0 source kept occluder")
	source.layers = 1
	source.visible = false
	await process_frame
	controller.update()
	_check(not plane.visible,"Hidden source kept occluder")
	source.visible = true
	await process_frame
	controller.update()
	_check(plane.visible,"Visible source return failed")
	var transparent := ShaderMaterial.new()
	transparent.shader = load(Materials.HQ_OPAQUE_SHADER)
	transparent.set_shader_parameter("alpha_cut",.5)
	source.material_override = null
	source.set_surface_override_material(0,transparent)
	controller.update()
	_check(not plane.visible,"Alpha surface override kept occluder")
	source.set_surface_override_material(0,null)
	source.material_override = material
	controller.update()
	_check(plane.visible,"Opaque material return failed")
	material.set_shader_parameter("alpha_cut",.5)
	controller.update()
	_check(not plane.visible,"Same material alpha_cut uniform was not checked")
	material.set_shader_parameter("alpha_cut",0.0)
	material.set_shader_parameter("albedo",Color(1,1,1,.5))
	controller.update()
	_check(not plane.visible,"Same material albedo alpha uniform was not checked")
	material.set_shader_parameter("albedo",Color.WHITE)
	controller.update()
	_check(plane.visible,"Same material uniform restoration failed")
	source.set_meta("dynamic_pool",true)
	controller.update()
	_check(not plane.visible,"Dynamic source kept occluder")
	source.remove_meta("dynamic_pool")
	controller.update()
	controller.set_hq(false)
	_check(not plane.visible and not root.use_occlusion_culling,"Retro did not restore viewport")
	controller.set_hq(true)
	controller.update()
	controller.resync()
	_check(not plane.visible,"Retry/resync retained previous active plane")
	controller.update()
	_check(plane.visible,"Resync lost exact geometry cache")
	var visibility_changes: int = controller.report["visibility_changes"]
	var material_checks: int = controller.report["material_checks"]
	for i in 8: controller.update()
	_check(controller.report["visibility_changes"]==visibility_changes,"Unchanged inputs rewrote plane visibility")
	_check(controller.report["material_checks"]==material_checks,"Unchanged material policy rebuilt its cache")
	mesh.emit_changed()
	_check(not plane.visible and not root.use_occlusion_culling,"Mesh change callback did not fail closed immediately")
	controller.update()
	_check(not plane.visible and controller.report["retired_sources"]==1,"Changed source was re-admitted")
	_check(shape.get_vertices()==points and shape.get_indices()==original_indices,"Runtime rewrote native arrays")
	_check(mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]==vertices,"Controller modified source mesh")
	_check(controller.report["runtime_array_updates"]==0 and controller.report["array_builds"]==1,"Runtime rebuilt plane arrays")
	var summary: Dictionary = controller.stats()
	controller.dispose()
	root.use_occlusion_culling = prior_flag
	world.queue_free()
	await process_frame
	await process_frame
	await _deletion_guard(mesh,material)
	var output := "res://../output/environment-refresh/native-occlusion-production-cpu.json"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	var file := FileAccess.open(output,FileAccess.WRITE)
	file.store_string(JSON.stringify({"checks":checks,"errors":errors,"controller":summary,"gpu_verified":false},"\t"))
	file.close()
	for error: String in errors: printerr(error)
	print("test_environment_occlusion: %s (%d CPU assertions; GPU pixel synchronization pending)"%["PASS" if errors.is_empty() else "FAIL",checks])
	quit(0 if errors.is_empty() else 1)

func _deletion_guard(mesh: ArrayMesh,material: Material) -> void:
	var world := Node3D.new()
	root.add_child(world)
	var source := MeshInstance3D.new()
	source.set_meta("environment_interior_role","wall")
	source.mesh = mesh
	source.material_override = material
	world.add_child(source)
	var light := OmniLight3D.new()
	world.add_child(light)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0,1.5,3)
	camera.make_current()
	var prior_flag := root.use_occlusion_culling
	root.use_occlusion_culling = false
	var controller: Variant = MODULE.prepare(root,world)
	controller.set_hq(true)
	controller.set_enabled(true)
	controller.update()
	_check(controller.report["active_planes"]==1,"Deletion fixture did not start with a real active plane")
	var plane: OccluderInstance3D = controller.get_child(0)
	plane.free()
	_check(controller.report["active_planes"]==0 and controller.report["active_triangles"]==0,"Deleting own plane left active counters")
	_check(not root.use_occlusion_culling,"Deleting the final own plane left native viewport enabled")
	_check(controller.report["owned_light_flags"]==0,"Deleting the final plane retained positional light bypass")
	controller.update()
	_check(controller.report["active_planes"]==0 and controller.report["active_triangles"]==0,"Unchanged-state fast path readmitted a deleted plane")
	controller.dispose()
	var replacement: Variant = MODULE.prepare(root,world)
	replacement.set_hq(true)
	replacement.set_enabled(true)
	replacement.update()
	_check(replacement.report["owned_light_flags"]==1,"Dispose fixture did not start with an owned flag")
	replacement.dispose()
	_check(replacement.report["owned_light_flags"]==0,"Dispose retained an owned light flag")
	var late := SpotLight3D.new()
	world.add_child(late)
	_check(replacement.report["light_sources"]==0,"Disposed controller still received node_added")
	root.use_occlusion_culling = prior_flag
	world.queue_free()
	await process_frame
	await process_frame

func _light_guard(controller: Variant,world: Node3D,camera: Camera3D,omni: OmniLight3D,spot: SpotLight3D) -> void:
	var original := _light_snapshot(omni,spot)
	_check(controller.report["owned_light_flags"]==2,"Native HQ did not own positional light flags")
	var writes: int = controller.report["light_render_flag_mutations"]
	for i in 4: controller.update()
	_check(controller.report["light_render_flag_mutations"]==writes,"Unchanged native state rewrote light flags")
	var added := SpotLight3D.new()
	world.add_child(added)
	_check(controller.report["light_sources"]==3 and controller.report["owned_light_flags"]==3,"Later world light was not admitted before the next frame")
	var external := OmniLight3D.new()
	root.add_child(external)
	var directional := DirectionalLight3D.new()
	world.add_child(directional)
	var hand_view := SubViewport.new()
	world.add_child(hand_view)
	var hand_world := Node3D.new()
	hand_view.add_child(hand_world)
	var hand_light := OmniLight3D.new()
	hand_world.add_child(hand_light)
	_check(controller.report["light_sources"]==3 and controller.report["owned_light_flags"]==3,"Directional/external/other-viewport light entered the policy")
	camera.clear_current(false)
	controller.update()
	_check(controller.report["owned_light_flags"]==0,"Missing current camera retained owned light flags")
	camera.make_current()
	controller.update()
	_check(controller.report["owned_light_flags"]==3,"Current camera return did not restore positional policy")
	controller.set_hq(false)
	_check(controller.report["owned_light_flags"]==0,"Retro retained owned light flags")
	controller.set_hq(true)
	controller.update()
	_check(controller.report["owned_light_flags"]==3,"HQ return lost positional light cohort")
	controller.set_enabled(false)
	_check(controller.report["owned_light_flags"]==0,"OFF/cancel retained owned light flags")
	controller.set_enabled(true)
	controller.update()
	controller.resync()
	_check(controller.report["owned_light_flags"]==0,"State resync retained owned light flags")
	controller.update()
	_check(controller.report["owned_light_flags"]==3,"Resync failed to reuse cached light instances")
	controller.restore()
	_check(controller.report["owned_light_flags"]==0,"Explicit restore retained light flags")
	controller.update()
	world.remove_child(added)
	_check(controller.report["light_sources"]==2 and controller.report["owned_light_flags"]==2,"Light removal did not immediately release its flag")
	world.add_child(added)
	_check(controller.report["light_sources"]==3 and controller.report["owned_light_flags"]==3,"Light re-entry did not reuse its policy")
	added.free()
	_check(controller.report["light_sources"]==2 and controller.report["owned_light_flags"]==2,"Freed light left an owned flag")
	camera.position.z = -3
	controller.update()
	_check(controller.report["active_planes"]==0 and controller.report["owned_light_flags"]==0,"Inactive native plane set retained light flags")
	camera.position.z = 3
	controller.update()
	_check(controller.report["owned_light_flags"]==2,"Front-plane return failed to restore live lights")
	_check(_light_snapshot(omni,spot)==original,"Light policy changed transforms, visibility, energy, range, color, layers or shadows")
	_check(controller.report["light_policy_only"] and controller.report["source_mutations"]==0 and controller.report["physics_mutations"]==0,"Light render flag writes were not separated from geometry/physics mutations")
	external.queue_free()
	directional.queue_free()
	hand_view.queue_free()
	await process_frame

func _light_snapshot(omni: OmniLight3D,spot: SpotLight3D) -> Array:
	return [omni.global_transform,omni.visible,omni.light_energy,omni.light_color,omni.omni_range,
		omni.light_cull_mask,omni.shadow_enabled,spot.global_transform,spot.visible,spot.light_energy,
		spot.light_color,spot.spot_range,spot.light_cull_mask,spot.shadow_enabled]

func _ray(points: PackedVector3Array,eye: Vector3) -> bool:
	for i in range(0,points.size(),3):
		if Geometry3D.ray_intersects_triangle(eye,Vector3(0,0,-1),points[i],points[i+1],points[i+2])!=null: return true
	return false

func _check(condition: bool,message: String) -> void:
	checks += 1
	if not condition: errors.append(message)

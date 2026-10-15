## Проверяет реальные ресурсы и удаление соседних владельцев на общем меше.
extends SceneTree

const REGISTRY := preload("res://src/environment_registry.gd")
const LOD := preload("res://src/environment_lod.gd")
var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var data: Dictionary = REGISTRY.manifest()
	_check(data.get("houses", []).size() == 30, "реестр обязан содержать 30 жилых домов")
	_check(data.get("yards", []).size() == 30, "реестр обязан содержать 30 индивидуальных дворов")
	var ids: Dictionary = {}
	var paths: Dictionary = {}
	var sample := OS.get_cmdline_user_args().has("--environment-sample")
	var checked := 0
	var shadow_eligible := 0
	var installed := {"houses":0,"services":0,"yards":0}
	for category: String in ["houses", "services", "yards"]:
		for row: Dictionary in data.get(category, []):
			var id := String(row["id"])
			_check(not ids.has(id), "повтор владельца " + id)
			ids[id] = true
			_check(row["paths"].size() == 3, "нет трёх LOD " + id)
			for level in 3:
				var path := String(row["paths"][level])
				_check(not paths.has(path), "разные владельцы делят один GLB " + path)
				paths[path] = true
				if sample and not data.get("samples", []).has(id.trim_prefix("yard-")):
					continue
				_check(ResourceLoader.exists(path), "нет ресурса " + path)
				var imported_cache_size: int = Materials._imported_materials.size()
				var mesh: Mesh = REGISTRY._load_mesh(path)
				_check(mesh != null,"invalid or empty GLB " + path)
				if mesh == null:
					continue
				_check(Materials._imported_materials.size() == imported_cache_size,"environment embedded material keys remain cached " + path)
				checked += 1
				if level == 0:
					installed[category] += 1
					_test_ao_map(id)
				_check(mesh.get_surface_count() > 0 and not mesh.get_faces().is_empty(), "пустой GLB " + path)
				_check(mesh.get_surface_count() <= int(row["surfaces_max"]), "поверхности " + id)
				var triangles := 0
				for surface in mesh.get_surface_count():
					var arrays := mesh.surface_get_arrays(surface)
					var index: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
					triangles += index.size()/3 if not index.is_empty() else arrays[Mesh.ARRAY_VERTEX].size()/3
					_check(arrays[Mesh.ARRAY_TEX_UV2] != null and not arrays[Mesh.ARRAY_TEX_UV2].is_empty(), "AO без UV2 " + path)
					var material := mesh.surface_get_material(surface) as ShaderMaterial
					var params: Dictionary = material.get_meta("skin_hq_params",{})
					if params.has("albedo_tex"):
						_check(float(params.get("metallic_value",-1)) == 0.0,"paint/wood diffuse blocked by glTF metal factor " + path)
						_check(bool(params.get("use_vertex_color",false)),"authored linear COLOR ignored " + path)
					_check(bool(params.get("ao_on_uv2",false)),"actual imported AO uses UV1 " + path)
					var ao: Texture2D = params.get("ao_tex")
					_check(ao != null and ao.resource_path == "res://assets/tex/environment/%s-ao.png" % id,"AO not deduplicated " + path)
					for uv: Vector2 in arrays[Mesh.ARRAY_TEX_UV2]:
						_check(uv.x >= -.002 and uv.x <= 1.002 and uv.y >= -.002 and uv.y <= 1.002,"actual Godot UV2 out of range " + path)
				_check(triangles <= int(row["triangle_budgets"][level]), "треугольники " + path)
				if level == 1:
					for surface in mesh.get_surface_count(): Materials.set_material_quality(mesh.surface_get_material(surface),true)
					_check(LOD.opaque_shadow_eligible(mesh),"opaque HQ medium rejected " + id)
					shadow_eligible += 1 if LOD.opaque_shadow_eligible(mesh) else 0
					for surface in mesh.get_surface_count(): Materials.set_material_quality(mesh.surface_get_material(surface),false)
					_check(not LOD.opaque_shadow_eligible(mesh),"retro POSITION snapping accepted " + id)
	_test_owner_removal()
	_test_lod()
	_test_shadow_material_policy()
	_test_gables()
	_test_material_roundtrip()
	for failure: String in failures:
		printerr("test_environment_registry: " + failure)
	print("test_environment_registry: %s declared_houses=30 declared_yards=30 installed_houses=%d installed_yards=%d installed_services=%d resources=%d opaque_shadow_owners=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL",installed["houses"],installed["yards"],installed["services"],checked,shadow_eligible, failures.size()])
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _test_ao_map(id: String) -> void:
	var path := "res://assets/tex/environment/%s-ao.png" % id
	var ao := Image.load_from_file(ProjectSettings.globalize_path(path))
	_check(ao != null and not ao.is_empty(),"AO image missing " + id)
	if ao == null or ao.is_empty(): return
	_check(ao.get_width() == 1024 and ao.get_height() == 1024,"AO map exceeds common 1K contract " + id)
	var darkest := 1.0
	var lightest := 0.0
	for y in range(0,ao.get_height(),16):
		for x in range(0,ao.get_width(),16):
			var pixel := ao.get_pixel(x,y)
			darkest=minf(darkest,pixel.r)
			lightest=maxf(lightest,pixel.r)
	_check(darkest >= .34,"actual AO image contains black island borders " + id)
	_check(lightest >= .8,"actual AO image darkens the complete asset " + id)


func _test_owner_removal() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	# Один владелец имеет наружную и внутреннюю грани; третий треугольник соседний.
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0,0,0),Vector3(1,0,0),Vector3(0,1,0),
		Vector3(0,0,0.1),Vector3(0,1,0.1),Vector3(1,0,0.1),
		Vector3(3,0,0),Vector3(4,0,0),Vector3(3,1,0)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.FORWARD,Vector3.FORWARD,Vector3.FORWARD,
		Vector3.BACK,Vector3.BACK,Vector3.BACK,Vector3.FORWARD,Vector3.FORWARD,Vector3.FORWARD])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO,Vector2.RIGHT,Vector2.UP,
		Vector2.ZERO,Vector2.UP,Vector2.RIGHT,Vector2.ZERO,Vector2.RIGHT,Vector2.UP])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var source := MeshInstance3D.new()
	source.mesh = mesh
	source.set_meta("skin_parts",{"buildings/site/w-n1":[Vector2i(0,6)],"buildings/site/other":[Vector2i(6,3)]})
	world.add_child(source)
	var removed: int = REGISTRY._remove_owner(world,[source],{"id":"vitya","owner_keys":["buildings/site/w-n1"],
		"removal_mode":"exterior","wall_rows":[{"id":"w-n1"}]})
	_check(removed == 1,"удалена внутренняя грань или соседний владелец")
	var residual: MeshInstance3D = source.get_meta("environment_residual")
	_check(residual.mesh.get_faces().size() == 6,"остаток не сохранил два треугольника")
	_check(source.layers == 0,"прежняя наружная оболочка ещё отрисовывается")
	world.free()


func _test_lod() -> void:
	var instance: MeshInstance3D = LOD.new()
	instance.set("current_level",0)
	_check(int(instance.call("choose_level",15.0)) == 0,"LOD дрожит внутри гистерезиса near")
	_check(int(instance.call("choose_level",15.6)) == 1,"LOD near не переключается")
	instance.set("current_level",1)
	_check(int(instance.call("choose_level",13.0)) == 1,"обратный LOD дрожит")
	_check(int(instance.call("choose_level",12.4)) == 0,"LOD не вернулся к near")
	_check(int(instance.call("choose_level",33.6)) == 2,"LOD far не переключается")
	var camera := Camera3D.new()
	root.add_child(camera)
	root.add_child(instance)
	var meshes: Array[Mesh] = []
	for level in 3:
		meshes.append(REGISTRY._load_mesh("res://assets/models/environment/vitya-lod%d.glb" % level))
	instance.call("configure",meshes,camera)
	_check(instance.get_child_count() == 1,"LOD must have one private shadow helper")
	var shadow := instance.get_child(0) as MeshInstance3D
	_check(shadow != null and shadow.has_meta("static_shadow_proxy"),"inventory must exclude shadow helper")
	if shadow == null:
		instance.free();camera.free();return
	_check(shadow.mesh == meshes[1],"shadow helper duplicated or replaced the medium resource")
	_check(instance.mesh == meshes[0],"near visible geometry changed")
	_check(instance.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,"visible mesh still casts detailed shadows")
	_check(shadow.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,"helper adds visible geometry")
	instance.position = Vector3(3,1,-4)
	instance.rotation.y = .37
	instance.scale = Vector3(1.1,1,.9)
	_check(shadow.global_transform.is_equal_approx(instance.global_transform),"shadow helper does not inherit owner pose")
	instance.layers = 5
	for step: Array in [[15.0,0],[15.6,1],[13.0,1],[12.4,0],[33.6,2],[30.6,2],[30.4,1],[12.4,0]]:
		camera.global_position = instance.global_position + Vector3.BACK * float(step[0])
		instance.call("_process",0.0)
		var chosen: int = step[1]
		_check(int(instance.get("current_level")) == chosen,"actual camera LOD hysteresis failed at " + str(step[0]))
		_check(instance.mesh == meshes[chosen],"visible LOD resource changed unexpectedly")
		_check(shadow.visible == (chosen < 2),"far helper remains active or near/medium loses shadows")
		_check(shadow.mesh == meshes[1] and shadow.layers == 5,"shadow resource/layers do not follow owner")
		_check(instance.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,"LOD switch restored detailed shadows")
	_check(is_equal_approx(shadow.visibility_range_end,58.0),"shadow helper ignores the owner visibility range")
	instance.visible = false
	_check(not shadow.is_visible_in_tree(),"hidden owner still casts a helper shadow")
	instance.visible = true
	instance.layers = 0
	instance.call("_process",0.0)
	_check(shadow.layers == 0,"layer-hidden owner still casts a helper shadow")
	instance.visibility_range_begin = 1.0
	instance.visibility_range_end = 46.0
	instance.visibility_range_end_margin = 2.0
	instance.material_override = StandardMaterial3D.new()
	instance.material_overlay = StandardMaterial3D.new()
	instance.call("_process",0.0)
	_check(shadow.material_override == instance.material_override and shadow.material_overlay == instance.material_overlay,"owner material override/overlay are stale in shadow helper")
	_check(is_equal_approx(shadow.visibility_range_begin,1.0) and is_equal_approx(shadow.visibility_range_end,46.0) and is_equal_approx(shadow.visibility_range_end_margin,2.0),"owner range update did not reach shadow helper")
	instance.call("configure",meshes,camera)
	_check(instance.get_child_count() == 1 and shadow.mesh == meshes[1],"reconfigure duplicated the shadow helper")
	instance.free()
	camera.free()


func _test_gables() -> void:
	var row := {"id":"vitya","roof_rows":[{"x":[-6.0,2.6],"ridgeZ":12.9}],"wall_rows":[]}
	_check(REGISTRY._exterior_triangle(row,"buildings/site/ROOFS-0",Vector3(-6.05,7,12),Vector3.LEFT),"old outer west gable remains")
	_check(not REGISTRY._exterior_triangle(row,"buildings/site/ROOFS-0",Vector3(-5.95,7,12),Vector3.RIGHT),"inner west gable removed")
	_check(not REGISTRY._exterior_triangle(row,"buildings/site/ROOFS-0",Vector3(0,6.4,10),Vector3.DOWN),"ceiling underside removed")
	_check(REGISTRY._exterior_triangle(row,"buildings/site/HOUSE-shell",Vector3(3.2,4.4,6.52),Vector3.FORWARD),"old annex outward face remains")
	_check(not REGISTRY._exterior_triangle(row,"buildings/site/HOUSE-shell",Vector3(3.2,4.4,6.68),Vector3.BACK),"annex interior removed")
	var service := {"id":"site-shed","footprint":[4.8,8.8,9.8,14.2],"eave":2.42}
	_check(REGISTRY._exterior_triangle(service,"buildings/site/SLABS-23",Vector3(6,2.5,12),Vector3.UP),"old service roof top remains")
	_check(not REGISTRY._exterior_triangle(service,"buildings/site/SLABS-23",Vector3(6,2.4,12),Vector3.DOWN),"service ceiling removed")


func _test_shadow_material_policy() -> void:
	var mesh := ArrayMesh.new()
	var materials: Array[ShaderMaterial] = []
	for surface in 2:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(surface,0,0),Vector3(surface+.8,0,0),Vector3(surface,.8,0)])
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK,Vector3.BACK,Vector3.BACK])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO,Vector2.RIGHT,Vector2.UP])
		arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(.1,.2),Vector2(.3,.2),Vector2(.1,.4)])
		arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color(.2,.4,.6),Color(.3,.5,.7),Color(.4,.6,.8)])
		var material := ShaderMaterial.new()
		material.shader = load(Materials.HQ_SHADER)
		material.set_shader_parameter("alpha_cut",0.0)
		material.set_shader_parameter("albedo",Color(.8,.6,.4,1))
		materials.append(material)
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		mesh.surface_set_material(surface,material)
	var before: Array = []
	for surface in 2: before.append(mesh.surface_get_arrays(surface))
	var signature := var_to_bytes(before)
	var owner := LOD.new()
	root.add_child(owner)
	var meshes: Array[Mesh] = [mesh,mesh,mesh]
	owner.configure(meshes)
	var caster := owner.get_child(0) as MeshInstance3D
	var cheap := LOD.opaque_shadow_material()
	_check(caster.material_override == cheap and bool(caster.get_meta("environment_shadow_opaque",false)),"plain opaque HQ shadow did not select shared depth shader")
	_check(cheap.shader.code.contains("cull_back") and not cheap.shader.code.contains("sampler") and not cheap.shader.code.contains("discard") and not cheap.shader.code.contains("ALPHA"),"cheap depth shader changes alpha/cull or samples textures")
	_check(cheap.shader.code.contains("v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;") and cheap.shader.code.contains("VERTEX = VERTEX;"),"cheap shader can substitute GLES3 default/shadow_mesh geometry")
	_check(owner.get_active_material(0) == materials[0] and owner.levels[1] == mesh and caster.mesh.get_faces() == mesh.get_faces() and caster.mesh.get_aabb() == mesh.get_aabb(),"shadow policy changes visible material, original medium resource, triangle positions or bounds")
	materials[1].set_shader_parameter("alpha_cut",.4)
	owner.refresh_shadow_material_policy()
	_check(caster.material_override == null and not bool(caster.get_meta("environment_shadow_opaque",false)),"second alpha-cut surface accepted after explicit refresh")
	materials[1].set_shader_parameter("alpha_cut",0.0)
	materials[1].set_shader_parameter("albedo",Color(1,1,1,.8))
	owner.refresh_shadow_material_policy()
	_check(caster.material_override == null,"translucent second surface accepted")
	materials[1].set_shader_parameter("albedo",Color.WHITE)
	materials[1].next_pass = StandardMaterial3D.new()
	owner.refresh_shadow_material_policy()
	_check(caster.material_override == null,"multipass surface accepted")
	materials[1].next_pass = null
	materials[1].shader = load(Materials.HQ_ALPHA_SHADER)
	owner.refresh_shadow_material_policy()
	_check(caster.material_override == null,"mixed back/disabled culling accepted")
	materials[0].shader = load(Materials.HQ_ALPHA_SHADER)
	owner.refresh_shadow_material_policy()
	var disabled := LOD.opaque_shadow_material(BaseMaterial3D.CULL_DISABLED)
	_check(caster.material_override == disabled and disabled != cheap,"uniform double-sided HQ did not retain disabled culling")
	_check(disabled.shader.code.contains("cull_disabled") and not disabled.shader.code.contains("sampler") and disabled.get_meta("environment_shadow_cull") == BaseMaterial3D.CULL_DISABLED,"double-sided cheap material changes cull/texture")
	materials[0].shader = load(Materials.HQ_SHADER)
	var unknown := Shader.new()
	unknown.code = "shader_type spatial; render_mode cull_back; void vertex(){VERTEX.x+=.3;}"
	materials[1].shader = unknown
	owner.refresh_shadow_material_policy()
	_check(caster.material_override == null,"unknown/deformed shader accepted")
	materials[1].shader = load(Materials.HQ_SHADER)
	owner.set_surface_override_material(1,StandardMaterial3D.new())
	owner._sync_shadow_caster()
	_check(caster.material_override == null,"owner per-surface override accepted")
	owner.set_surface_override_material(1,null)
	owner.material_override = StandardMaterial3D.new()
	owner._sync_shadow_caster()
	_check(caster.material_override == owner.material_override,"owner custom override lost on fallback")
	owner.material_override = null
	owner.material_overlay = StandardMaterial3D.new()
	owner._sync_shadow_caster()
	_check(caster.material_override == null and caster.material_overlay == owner.material_overlay,"overlay fallback lost")
	owner.material_overlay = null
	owner.refresh_shadow_material_policy()
	_check(caster.material_override == cheap,"HQ policy did not recover after fallback")
	materials[1].shader = load(Materials.PSX_SHADER)
	owner.refresh_shadow_material_policy()
	_check(caster.material_override == null,"retro POSITION snapping optimized away")
	materials[1].shader = load(Materials.HQ_SHADER)
	owner.refresh_shadow_material_policy()
	_check(caster.material_override == cheap,"HQ-return policy stale")
	var refreshes: int = owner.get("_shadow_policy_refreshes")
	for frame in 120: owner._sync_shadow_caster()
	_check(owner.get("_shadow_policy_refreshes") == refreshes,"unchanged frames re-scan immutable shaders/uniforms")
	mesh.surface_set_material(1,StandardMaterial3D.new())
	owner._sync_shadow_caster()
	_check(caster.material_override == null,"changed medium surface reference was cached indefinitely")
	mesh.surface_set_material(1,materials[1])
	owner._sync_shadow_caster()
	_check(caster.material_override == cheap,"medium reference-change policy did not recover")
	_check(owner.get_active_material(1) == materials[1],"visible material identity changed")
	var after: Array = []
	for surface in 2: after.append(mesh.surface_get_arrays(surface))
	_check(signature == var_to_bytes(after),"shadow policy changed vertices/normals/winding/UV2/COLOR")
	owner.configure(meshes)
	_check(owner.get_child_count() == 1 and caster.material_override == cheap,"reconfigure duplicated helper/material")
	owner.free()


func _test_material_roundtrip() -> void:
	var world := Node3D.new()
	var hands := Node3D.new()
	root.add_child(world)
	root.add_child(hands)
	var instance: MeshInstance3D = LOD.new()
	var meshes: Array[Mesh] = []
	for level in 3:
		var mesh: Mesh = REGISTRY._load_mesh("res://assets/models/environment/vitya-lod%d.glb" % level)
		if mesh == null: world.free();hands.free();return
		meshes.append(mesh)
	world.add_child(instance)
	instance.call("configure",meshes)
	var shadow := instance.get_child(0) as MeshInstance3D
	var chain := RenderChain.new()
	chain.world_root=world
	chain.hand_root=hands
	chain.world_env=Environment.new()
	chain.set("_preset",RenderChain.PRESET_HQ)
	var texture_ids: Dictionary = {}
	for hq: bool in [true,false,true]:
		chain.call("_apply_scene_material_quality",hq)
		instance.call("refresh_shadow_material_policy")
		_check(shadow.mesh == meshes[1],"quality switch replaced the shared shadow mesh")
		_check(shadow.material_override == LOD.opaque_shadow_material(LOD.opaque_shadow_cull(meshes[1])) if hq else shadow.material_override == null,"shadow depth material policy missed HQ/retro toggle")
		if not hq:
			_check(shadow.get_active_material(0) == meshes[1].surface_get_material(0),"retro shadow material was cloned or became stale")
		for level in 3:
			for surface in meshes[level].get_surface_count():
				var material := meshes[level].surface_get_material(surface) as ShaderMaterial
				_check(material.shader.resource_path.contains("hq") == hq,"inactive LOD%d quality did not change" % level)
				if hq:
					_check(material.get_shader_parameter("ao_on_uv2") == true,"HQ roundtrip lost actual AO UV2")
					_check(float(material.get_shader_parameter("metallic_value")) == 0.0,"HQ roundtrip restored metallic=1")
					for field: String in ["albedo_tex","normal_tex","roughness_tex","ao_tex"]:
						var texture := material.get_shader_parameter(field) as Texture2D
						if texture != null:
							var key := str(surface)+field
							if texture_ids.has(key): _check(texture_ids[key] == texture.get_instance_id(),"LOD textures duplicated or replaced " + field)
							texture_ids[key]=texture.get_instance_id()
	chain.set_hq_atmosphere(Color(.1,.12,.15),1.0)
	_check(is_equal_approx(chain.world_env.background_energy_multiplier,RenderChain.HQ_SKY_ENERGY_NIGHT),"night sky state lost after HQ/retro/HQ")
	_check(chain.world_env.fog_light_color.is_equal_approx(Color(.1,.12,.15)),"night sky tint lost after HQ/retro/HQ")
	_check(texture_ids.size() == 4,"actual three LODs must use four shared maps")
	chain.free()
	world.free()
	hands.free()

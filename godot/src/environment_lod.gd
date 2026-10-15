## Видимый GLB меняет LOD; тень near/medium использует тот же средний ресурс.
class_name EnvironmentLod
extends MeshInstance3D

var levels: Array[Mesh] = []
var distances := Vector3(14.0, 32.0, 58.0)
var hysteresis := 1.5
var current_level := 0
var _camera: Camera3D
var _shadow_caster: MeshInstance3D
var _shadow_state: Array = []
var _shadow_material_state: Array = []
var _shadow_material: Material
var _shadow_medium: Mesh
var _shadow_material_dirty := true
var _shadow_policy_refreshes := 0
var _shadow_fast_hits := 0
var _shadow_synced_policy_refreshes := -1
static var _opaque_shadow_materials: Dictionary = {}
static var _hq_vertex_code := ""
static var _hq_vertex_safe := false
static var _shadow_surface_cache: Dictionary = {}
static var _profile_enabled := "--profile-environment-lod" in OS.get_cmdline_user_args()
static var _profile_process_usec := 0
static var _profile_shadow_builds := 0
static var _profile_shadow_build_usec := 0
static var _profile_shadow_max_usec := 0
static var _profile_shadow_last_source := ""
var _profile_last_process_usec := 0
var _profile_last_process_frame := -1
var _profile_level_switches := 0


func quality_meshes() -> Array[Mesh]:
	return levels


func configure(meshes: Array[Mesh], camera: Camera3D = null) -> void:
	if _shadow_medium != null and _shadow_medium.changed.is_connected(_shadow_mesh_changed):
		_shadow_medium.changed.disconnect(_shadow_mesh_changed)
	levels = meshes
	_camera = camera
	current_level = 0
	mesh = levels[0] if not levels.is_empty() else null
	visibility_range_end = distances.z
	visibility_range_end_margin = 0.0
	visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	set_meta("environment_lod", true)
	if not is_instance_valid(_shadow_caster):
		_shadow_caster = MeshInstance3D.new()
		_shadow_caster.name = "_environment_shadow_caster"
		_shadow_caster.set_meta("static_shadow_proxy", true)
		_shadow_caster.set_meta("environment_shadow_proxy", true)
		add_child(_shadow_caster)
	_shadow_caster.mesh = levels[1] if levels.size() == 3 else null
	_shadow_medium = _shadow_caster.mesh
	if _shadow_medium != null: _shadow_medium.changed.connect(_shadow_mesh_changed)
	_shadow_caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	_shadow_state.clear()
	_shadow_material_state.clear()
	_shadow_material_dirty = true
	_sync_shadow_caster()


func _sync_shadow_caster() -> void:
	if not is_instance_valid(_shadow_caster):
		return
	if _shadow_inputs_unchanged():
		_shadow_fast_hits += 1
		return
	# The imported surface parameters are immutable outside explicit refresh.
	# Unchanged frames only compare owner override references; no shader/uniform
	# lookups, geometry traversal, texture loads or material setters.
	if current_level < 2: _update_shadow_material_policy()
	var shadow_mesh: Mesh = levels[1] if levels.size() == 3 else null
	if current_level < 2 and _shadow_material != null:
		shadow_mesh = shadow_surface_mesh(shadow_mesh)
	var state: Array = [levels.size() == 3 and current_level < 2, layers,
		visibility_range_begin, visibility_range_begin_margin, visibility_range_end,
		visibility_range_end_margin, visibility_range_fade_mode, material_override, material_overlay,
		_shadow_material,shadow_mesh]
	_shadow_synced_policy_refreshes = _shadow_policy_refreshes
	if state == _shadow_state:
		return
	_shadow_state = state
	_shadow_caster.mesh = shadow_mesh
	_shadow_caster.visible = state[0]
	_shadow_caster.layers = layers
	_shadow_caster.visibility_range_begin = visibility_range_begin
	_shadow_caster.visibility_range_begin_margin = visibility_range_begin_margin
	_shadow_caster.visibility_range_end = visibility_range_end
	_shadow_caster.visibility_range_end_margin = visibility_range_end_margin
	_shadow_caster.visibility_range_fade_mode = visibility_range_fade_mode
	_shadow_caster.material_override = _shadow_material if _shadow_material != null else material_override
	_shadow_caster.material_overlay = material_overlay
	_shadow_caster.set_meta("environment_shadow_opaque",_shadow_material != null)
	_shadow_caster.set_meta("environment_shadow_surface_batch",shadow_mesh != null and shadow_mesh != _shadow_medium)


# Public owner properties may change directly, so compare every input rather
# than waiting for a timer. Avoid allocating two state arrays on steady frames.
func _shadow_inputs_unchanged() -> bool:
	if _shadow_state.size()!=11: return false
	var near := levels.size()==3 and current_level<2
	if _shadow_state[0]!=near or _shadow_state[1]!=layers \
			or _shadow_state[2]!=visibility_range_begin or _shadow_state[3]!=visibility_range_begin_margin \
			or _shadow_state[4]!=visibility_range_end or _shadow_state[5]!=visibility_range_end_margin \
			or _shadow_state[6]!=visibility_range_fade_mode or _shadow_state[7]!=material_override \
			or _shadow_state[8]!=material_overlay or _shadow_state[9]!=_shadow_material:
		return false
	var medium: Mesh=levels[1] if levels.size()==3 else null
	if not near: return _shadow_state[10]==medium
	if _shadow_material_dirty or _shadow_synced_policy_refreshes!=_shadow_policy_refreshes \
			or _shadow_material_state.size()<3 \
			or _shadow_material_state[0]!=material_override or _shadow_material_state[1]!=material_overlay \
			or _shadow_material_state[2]!=medium:
		return false
	var count := mesh.get_surface_count() if mesh!=null else 0
	if _shadow_material_state.size()!=count+3: return false
	for surface in count:
		if _shadow_material_state[surface+3]!=get_surface_override_material(surface): return false
	return true


## RenderChain calls this after its complete material quality sweep, including
## inactive levels. Retro's POSITION snapping must keep the original shader.
## Other callers changing a surface shader/uniform/next_pass must also refresh.
func refresh_shadow_material_policy() -> void:
	_update_shadow_material_policy(true)
	_sync_shadow_caster()


func _shadow_mesh_changed() -> void:
	_shadow_material_dirty = true


func _update_shadow_material_policy(force := false) -> void:
	var state: Array = [material_override,material_overlay]
	var medium: Mesh = levels[1] if levels.size() == 3 else null
	state.append(medium)
	if mesh != null:
		for surface in mesh.get_surface_count(): state.append(get_surface_override_material(surface))
	if not force and not _shadow_material_dirty and state == _shadow_material_state: return
	_shadow_material_state = state
	_shadow_material_dirty = false
	_shadow_policy_refreshes += 1
	_shadow_material = null
	if material_override != null or material_overlay != null or medium == null: return
	if mesh != null:
		for surface in mesh.get_surface_count():
			if get_surface_override_material(surface) != null: return
	var cull := opaque_shadow_cull(medium)
	if cull >= 0: _shadow_material = opaque_shadow_material(cull)


## A plain opaque depth shader keeps every medium vertex/index and normal bias.
## Do not accept alpha/glass, PSX POSITION snapping, unknown or modified shaders.
static func opaque_shadow_eligible(source: Mesh) -> bool:
	return opaque_shadow_cull(source) >= 0


## Every source surface must agree on its original front/back-face policy.
static func opaque_shadow_cull(source: Mesh) -> int:
	if source == null or source.get_surface_count() == 0: return -1
	var cull := -1
	for surface in source.get_surface_count():
		var material := source.surface_get_material(surface) as ShaderMaterial
		if material == null or material.next_pass != null or material.shader == null: return -1
		var surface_cull := -1
		if material.shader in [load(Materials.HQ_SHADER),load(Materials.HQ_OPAQUE_SHADER)]: surface_cull = BaseMaterial3D.CULL_BACK
		elif material.shader in [load(Materials.HQ_ALPHA_SHADER),load(Materials.HQ_OPAQUE_ALPHA_SHADER)]: surface_cull = BaseMaterial3D.CULL_DISABLED
		if surface_cull < 0 or not _undeformed_hq(material.shader): return -1
		if cull >= 0 and cull != surface_cull: return -1
		cull = surface_cull
		var cut: Variant = material.get_shader_parameter("alpha_cut")
		var albedo: Variant = material.get_shader_parameter("albedo")
		# Null means the known HQ shader's alpha_cut=0/albedo=white defaults.
		if cut != null and (not cut is float and not cut is int or float(cut) != 0.0): return -1
		if albedo != null and (not albedo is Color or (albedo as Color).a != 1.0): return -1
	return cull


static func _undeformed_hq(shader: Shader) -> bool:
	var code := shader.code.replace("\r", "")
	if code == _hq_vertex_code: return _hq_vertex_safe
	_hq_vertex_code = code
	_hq_vertex_safe = false
	if not code.contains("cull_back") and not code.contains("cull_disabled") or code.contains("cull_front"): return false
	if code.contains("world_vertex_coords") or code.contains("skip_vertex_transform") or code.contains("wireframe"): return false
	var transparency := RegEx.new()
	transparency.compile("\\b(ALPHA|DEPTH)\\s*(?:[+*/-]?=|\\+\\+|--)")
	if transparency.search(code) != null: return false
	var start := code.find("void vertex()")
	if start < 0: return false
	var opening := code.find("{",start)
	var end := opening+1
	var depth := 1
	while end < code.length() and depth > 0:
		if code[end] == "{": depth += 1
		elif code[end] == "}": depth -= 1
		end += 1
	if depth != 0: return false
	var vertex := code.substr(opening+1,end-opening-2)
	# This explicit no-op retains the original GLES cull/index path after
	# removing a disabled discard; it does not deform any source vertex.
	vertex = vertex.replace("\tVERTEX = VERTEX;\n","")
	var changed := RegEx.new()
	changed.compile("\\b(VERTEX|POSITION|NORMAL|TANGENT|BINORMAL)\\s*(?:\\.[xyzwrgba]+)?\\s*(?:[+*/-]?=|\\+\\+|--)")
	_hq_vertex_safe = changed.search(vertex) == null
	return _hq_vertex_safe


static func opaque_shadow_material(cull: int = BaseMaterial3D.CULL_BACK) -> ShaderMaterial:
	if not _opaque_shadow_materials.has(cull):
		var material := ShaderMaterial.new()
		material.resource_name = "environment-opaque-shadow-depth-%d" % cull
		var shader := Shader.new()
		var mode := "cull_disabled" if cull == BaseMaterial3D.CULL_DISABLED else "cull_back"
		# GLES3's shared default shadow material loses the source cull policy and
		# may use shadow_mesh. Keep the HQ vertex statements and an identity write
		# so uses_vertex remains true even if unused varyings are optimized away.
		shader.code = "shader_type spatial;\nrender_mode diffuse_lambert, specular_schlick_ggx, %s;\n" % mode \
			+ "varying vec2 v_psx_uv;\nvarying float v_psx_w;\nvarying vec3 v_world;\n" \
			+ "void vertex() {\n\tv_psx_w = 1.0;\n\tv_psx_uv = UV;\n\tv_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;\n\tVERTEX = VERTEX;\n}\n" \
			+ "void fragment() { ALBEDO = vec3(1.0); }\n"
		material.shader = shader
		material.set_meta("environment_shadow_opaque",true)
		material.set_meta("environment_shadow_cull",cull)
		_opaque_shadow_materials[cull] = material
	return _opaque_shadow_materials[cull]


## Called only after the owner selected its shared opaque depth material.
## Geometry remains in this caster's original local coordinates. The proven
## depth shader consumes POSITION/NORMAL/index only. Preserve entire compatible
## packed streams: decoding/re-encoding octahedral normals changes their bits.
## No weld, normalization, material writes or cross-owner grouping.
static func shadow_surface_mesh(source: Mesh) -> Mesh:
	if source == null: return null
	var id: int = source.get_instance_id()
	if _shadow_surface_cache.has(id):
		var cached: Dictionary = _shadow_surface_cache[id]
		if (cached["source"] as WeakRef).get_ref() == source:
			return cached["merged"] if cached["merged"] != null else source
		_shadow_surface_cache.erase(id)
	var invalidator: Callable = _invalidate_shadow_surface_cache.bind(id)
	if not source.changed.is_connected(invalidator): source.changed.connect(invalidator)
	var report: Dictionary = {"source_id":id,"source_surfaces":source.get_surface_count(),
		"merged_surfaces":source.get_surface_count(),"merged":false,"reason":"", "vertices":0,"triangles":0}
	if _profile_enabled: report["_started_usec"]=Time.get_ticks_usec()
	if not source is ArrayMesh or source.get_surface_count() < 2:
		return _remember_shadow_surface(source,null,report,"already single surface or unsupported mesh")
	var array_mesh: ArrayMesh = source as ArrayMesh
	if array_mesh.get_blend_shape_count() != 0:
		return _remember_shadow_surface(source,null,report,"blend shapes")
	var serialized: Array = array_mesh.get("_surfaces")
	if serialized.size() != source.get_surface_count():
		return _remember_shadow_surface(source,null,report,"serialized surface count")
	var format: int = array_mesh.surface_get_format(0)
	if (format & Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES) != 0:
		return _remember_shadow_surface(source,null,report,"compression depends on per-surface bounds/scales")
	var first: Array = source.surface_get_arrays(0)
	var indexed: bool = first[Mesh.ARRAY_INDEX] != null and not first[Mesh.ARRAY_INDEX].is_empty()
	var positions := PackedByteArray()
	var normals_tangents := PackedByteArray()
	var attributes := PackedByteArray()
	var rebased_indices := PackedInt32Array()
	var expected_positions := PackedVector3Array()
	var expected_normals := PackedVector3Array()
	var offset: int = 0
	for surface in source.get_surface_count():
		if array_mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES:
			return _remember_shadow_surface(source,null,report,"non-triangle primitive")
		var raw: Dictionary = serialized[surface]
		if int(raw["format"]) != format:
			return _remember_shadow_surface(source,null,report,"different packed source formats")
		if not raw.get("lods",[]).is_empty():
			return _remember_shadow_surface(source,null,report,"embedded native LODs")
		if not raw.get("skin_data",PackedByteArray()).is_empty() or not raw.get("blend_shape_data",PackedByteArray()).is_empty():
			return _remember_shadow_surface(source,null,report,"packed skin/blend deformation")
		var part: Array = source.surface_get_arrays(surface)
		var count: int = part[Mesh.ARRAY_VERTEX].size() if part[Mesh.ARRAY_VERTEX] != null else 0
		if count == 0 or not _shadow_slots_valid(part,count):
			return _remember_shadow_surface(source,null,report,"unsupported or malformed attribute arrays")
		var indices: PackedInt32Array = part[Mesh.ARRAY_INDEX] if part[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indexed != (not indices.is_empty()):
			return _remember_shadow_surface(source,null,report,"different source index layouts")
		if (indices.size() if not indices.is_empty() else count)%3 != 0:
			return _remember_shadow_surface(source,null,report,"incomplete triangles")
		for index: int in indices:
			if index < 0 or index >= count: return _remember_shadow_surface(source,null,report,"index out of range")
		if offset+count >= 65536:
			return _remember_shadow_surface(source,null,report,"combined index-width boundary")
		var pstride: int = RenderingServer.mesh_surface_get_format_vertex_stride(format,count)
		var nstride: int = RenderingServer.mesh_surface_get_format_normal_tangent_stride(format,count)
		var nstart: int = RenderingServer.mesh_surface_get_format_offset(format,count,Mesh.ARRAY_NORMAL)
		var astride: int = RenderingServer.mesh_surface_get_format_attribute_stride(format,count)
		var vb: PackedByteArray = raw["vertex_data"]
		var ab: PackedByteArray = raw.get("attribute_data",PackedByteArray())
		var ib: PackedByteArray = raw.get("index_data",PackedByteArray())
		if int(raw["vertex_count"]) != count or int(raw.get("index_count",0)) != indices.size() \
				or pstride != 12 or not (nstride in [4,8]) or nstart != count*pstride \
				or vb.size() != count*(pstride+nstride) or ab.size() != count*astride \
				or ib.size() != indices.size()*2:
			return _remember_shadow_surface(source,null,report,"unknown packed stream/index layout")
		for i in indices.size():
			if ib.decode_u16(i*2) != indices[i]:
				return _remember_shadow_surface(source,null,report,"packed source index witness")
			rebased_indices.append(offset+indices[i])
		positions.append_array(vb.slice(0,nstart))
		normals_tangents.append_array(vb.slice(nstart))
		attributes.append_array(ab)
		expected_positions.append_array(part[Mesh.ARRAY_VERTEX])
		expected_normals.append_array(part[Mesh.ARRAY_NORMAL])
		offset += count
		report["vertices"] += count
		report["triangles"] += (indices.size() if not indices.is_empty() else count)/3
	positions.append_array(normals_tangents)
	var index_bytes := PackedByteArray()
	index_bytes.resize(rebased_indices.size()*2)
	for i in rebased_indices.size(): index_bytes.encode_u16(i*2,rebased_indices[i])
	var combined: Dictionary = (serialized[0] as Dictionary).duplicate()
	combined["vertex_count"]=offset;combined["index_count"]=rebased_indices.size()
	combined["vertex_data"]=positions;combined["attribute_data"]=attributes
	combined["index_data"]=index_bytes;combined["aabb"]=source.get_aabb()
	var merged := ArrayMesh.new()
	merged.set("_surfaces",[combined])
	if merged.get_surface_count() != 1:
		return _remember_shadow_surface(source,null,report,"surface assembly failed")
	var packed: Dictionary = merged.get("_surfaces")[0]
	if int(packed["format"]) != format or packed["vertex_data"] != positions \
			or packed.get("attribute_data",PackedByteArray()) != attributes or packed.get("index_data",PackedByteArray()) != index_bytes:
		return _remember_shadow_surface(source,null,report,"packed stream roundtrip changed")
	var actual: Array = merged.surface_get_arrays(0)
	if var_to_bytes(actual[Mesh.ARRAY_VERTEX]) != var_to_bytes(expected_positions) \
			or var_to_bytes(actual[Mesh.ARRAY_NORMAL]) != var_to_bytes(expected_normals) \
			or (indexed and var_to_bytes(actual[Mesh.ARRAY_INDEX]) != var_to_bytes(rebased_indices)):
		return _remember_shadow_surface(source,null,report,"decoded POSITION/NORMAL/index changed")
	merged.custom_aabb=source.get_aabb()
	if merged.get_aabb() != source.get_aabb():
		return _remember_shadow_surface(source,null,report,"source bounds changed")
	merged.set_meta("environment_shadow_surface_batch",true)
	merged.set_meta("environment_shadow_source_id",id)
	merged.set_meta("environment_shadow_source_surfaces",source.get_surface_count())
	report["shadow_attributes"]=["POSITION","NORMAL","INDEX"]
	report["packed_attributes_preserved"]=true
	report["packed_format"]=format
	report["visible_attributes_unchanged"]=true
	return _remember_shadow_surface(source,merged,report,"")


static func _shadow_slots_valid(arrays: Array,count: int) -> bool:
	if not arrays[Mesh.ARRAY_VERTEX] is PackedVector3Array: return false
	if not arrays[Mesh.ARRAY_NORMAL] is PackedVector3Array or arrays[Mesh.ARRAY_NORMAL].size() != count: return false
	for slot: int in [Mesh.ARRAY_CUSTOM0,Mesh.ARRAY_CUSTOM1,Mesh.ARRAY_CUSTOM2,Mesh.ARRAY_CUSTOM3,Mesh.ARRAY_BONES,Mesh.ARRAY_WEIGHTS]:
		if arrays[slot] != null and not arrays[slot].is_empty(): return false
	return true


static func _remember_shadow_surface(source: Mesh,merged: ArrayMesh,report: Dictionary,reason: String) -> Mesh:
	if _profile_enabled and report.has("_started_usec"):
		var elapsed := Time.get_ticks_usec()-int(report["_started_usec"])
		report.erase("_started_usec")
		report["build_usec"]=elapsed
		_profile_shadow_builds += 1
		_profile_shadow_build_usec += elapsed
		_profile_shadow_max_usec = maxi(_profile_shadow_max_usec,elapsed)
		_profile_shadow_last_source = source.resource_path
	report["merged"]=merged != null;report["reason"]=reason
	if merged != null: report["merged_surfaces"]=1
	_shadow_surface_cache[source.get_instance_id()]={"source":weakref(source),"merged":merged,"report":report}
	return merged if merged != null else source


static func _invalidate_shadow_surface_cache(source_id: int) -> void:
	_shadow_surface_cache.erase(source_id)


static func shadow_surface_batch_report(source: Mesh) -> Dictionary:
	if source == null: return {"merged":false,"reason":"missing medium"}
	shadow_surface_mesh(source)
	return (_shadow_surface_cache[source.get_instance_id()]["report"] as Dictionary).duplicate(true)


func choose_level(distance: float) -> int:
	var chosen := current_level
	if chosen == 0 and distance > distances.x + hysteresis:
		chosen = 1
	elif chosen > 0 and distance < distances.x - hysteresis:
		chosen = 0
	if chosen == 1 and distance > distances.y + hysteresis:
		chosen = 2
	elif chosen == 2 and distance < distances.y - hysteresis:
		chosen = 1
	return chosen


func _camera_for_lod() -> Camera3D:
	# Cutscene owns another current camera; the configured camera is only a
	# fallback for fixtures and viewports without an active 3D camera.
	if is_inside_tree():
		var current := get_viewport().get_camera_3d()
		if is_instance_valid(current):
			return current
	return _camera if is_instance_valid(_camera) else null


func _process(_dt: float) -> void:
	var started := Time.get_ticks_usec() if _profile_enabled else 0
	_sync_shadow_caster()
	if levels.size() != 3:
		if _profile_enabled: _profile_finish_process(started)
		return
	var camera := _camera_for_lod()
	if camera == null:
		if _profile_enabled: _profile_finish_process(started)
		return
	var next := choose_level(camera.global_position.distance_to(global_position))
	if next != current_level:
		if _profile_enabled: _profile_level_switches += 1
		current_level = next
		mesh = levels[current_level]
		_sync_shadow_caster()
	if _profile_enabled: _profile_finish_process(started)


func _profile_finish_process(started: int) -> void:
	_profile_last_process_usec = Time.get_ticks_usec()-started
	_profile_last_process_frame = Engine.get_process_frames()
	_profile_process_usec += _profile_last_process_usec

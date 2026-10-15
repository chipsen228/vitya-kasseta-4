## Exact static visual occluders. Each oriented plane keeps its original holes.
## Build once after scene quality/finish, enable after WorldWarm. Geometry is read-only.
## Positional lights bypass native occlusion through an owned render flag only.
class_name EnvironmentOcclusion
extends Node

const HQ_PATHS := [Materials.HQ_SHADER,Materials.HQ_OPAQUE_SHADER,
	Materials.HQ_ALPHA_SHADER,Materials.HQ_OPAQUE_ALPHA_SHADER]
const MARKS := ["static_shadow_proxy","environment_shadow_proxy","skin_asset",
	"independent_visual","dynamic_pool","deformation"]
const FRONT_EPS := 0.000001

class CachedPlane:
	extends RefCounted
	var node: WeakRef
	var surface: int
	var axis: int
	var coordinate: float
	var sign_value: int
	var triangles: int
	var active := false
	var alive := true

class CachedSource:
	extends RefCounted
	var node: WeakRef
	var mesh: WeakRef
	var transform: Transform3D
	var retired := false
	var policy_dirty := true
	var materials: Array[Material] = []
	var policies := PackedInt32Array()
	var policy_stamps: Array = []
	var planes: Array[CachedPlane] = []
	var center: Vector3
	var path: String
	var retire_reason: String

class CachedLight:
	extends RefCounted
	var node: WeakRef
	var instance: RID
	var inside := true
	var owned_on := false

var _viewport: WeakRef
var _world: WeakRef
var _prior_flag := false
var _enabled := false
var _hq := false
var _disposed := false
var _sources: Array[CachedSource] = []
var _planes: Array[CachedPlane] = []
var _signals: Array[Dictionary] = []
var _walls: Dictionary = {}
var _frame_policy_stamps: Dictionary = {}
var _lights: Array[CachedLight] = []
var _light_ids: Dictionary = {}
var _light_policy_on := false
var report: Dictionary = {"sources":0,"planes":0,"triangles":0,"active_planes":0,
	"active_triangles":0,"cache_hits":0,"visibility_changes":0,"mesh_revisions":0,
	"retired_sources":0,"material_checks":0,"array_builds":0,"runtime_array_updates":0,
	"source_mutations":0,"physics_mutations":0,"updates":0,"resyncs":0,
	"prepare_usec":0,"update_usec":0,"max_update_usec":0,"errors":[],"plane_records":[],"source_records":[],
	"source_mutations_scope":"cached mesh geometry and source properties",
	"light_policy_only":true,"light_sources":0,"owned_light_flags":0,"light_render_flag_mutations":0,
	"light_default_ignore_occlusion":false,"light_default_assumption":"Pinned engine defaults false; this project has no other ignore-occlusion flag writers"}

static func prepare(viewport: Viewport,world: Node3D) -> EnvironmentOcclusion:
	var controller := EnvironmentOcclusion.new()
	controller.name = "EnvironmentOcclusion"
	world.add_child(controller)
	controller.configure(viewport,world)
	return controller

func configure(viewport: Viewport,world: Node3D) -> void:
	assert(_sources.is_empty() and _planes.is_empty(),"Configure once; use a new controller for a replacement scene")
	var start := Time.get_ticks_usec()
	_viewport = weakref(viewport)
	_world = weakref(world)
	_prior_flag = viewport.use_occlusion_culling
	process_priority = 1000
	set_process(false)
	for row: Dictionary in GameData.site()["WALLS"]:
		_walls["buildings/site/"+String(row.get("id","WALLS"))] = true
	for node: Node in SkinLayer._nodes(world):
		if node is OmniLight3D or node is SpotLight3D: _track_light(node)
		if not node is MeshInstance3D or not _static(node): continue
		var source := node as MeshInstance3D
		var original: Node = source
		while original != world and not String(original.name).begins_with("merged"):
			original = original.get_parent()
		var interior := source.has_meta("environment_interior_role") \
			and String(source.get_meta("environment_interior_role")) in ["floor","wall"]
		if not interior and original == world: continue
		if interior: original = source
		if not original is MeshInstance3D: continue
		_cache(source,original,interior)
	_watch(get_tree(),"node_added",Callable(self,"_node_added"))
	report["sources"] = _sources.size()
	report["planes"] = _planes.size()
	report["prepare_usec"] = Time.get_ticks_usec()-start

func _cache(node: MeshInstance3D,original: MeshInstance3D,interior: bool) -> void:
	var admitted: Dictionary = {}
	if original.has_meta("skin_parts") and original.mesh is ArrayMesh and original.mesh.get_surface_count()==1:
		var verts: PackedVector3Array = original.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		for owner: String in original.get_meta("skin_parts"):
			if not _walls.has(owner) and not owner.begins_with("buildings/site/SLABS-"): continue
			for span: Vector2i in original.get_meta("skin_parts")[owner]:
				for index in range(span.x,span.x+span.y,3):
					if index+2<verts.size(): admitted[_key(verts[index],verts[index+1],verts[index+2])] = owner
	var ground := false
	for key: String in ["grass","dirt","gravel"]:
		if String(original.name).contains("_"+key+"_") or String(original.name).contains(":"+key+":"): ground = true
	var groups: Dictionary = {}
	var mesh := node.mesh as ArrayMesh
	var fingerprints: Array = []
	for surface in mesh.get_surface_count():
		if mesh.surface_get_primitive_type(surface)!=Mesh.PRIMITIVE_TRIANGLES: continue
		var arrays := mesh.surface_get_arrays(surface)
		var deform := false
		for slot in [Mesh.ARRAY_BONES,Mesh.ARRAY_WEIGHTS,Mesh.ARRAY_CUSTOM0,Mesh.ARRAY_CUSTOM1,Mesh.ARRAY_CUSTOM2,Mesh.ARRAY_CUSTOM3]:
			if arrays[slot]!=null and not arrays[slot].is_empty(): deform = true
		if deform: continue
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
		if indices.is_empty():
			indices.resize(verts.size())
			for i in verts.size(): indices[i] = i
		if indices.size()%3!=0: continue
		fingerprints.append({"surface":surface,"vertex_sha256":_sha(verts.to_byte_array()),"index_sha256":_sha(indices.to_byte_array())})
		for i in range(0,indices.size(),3):
			if indices[i]<0 or indices[i+1]<0 or indices[i+2]<0 or indices[i]>=verts.size() or indices[i+1]>=verts.size() or indices[i+2]>=verts.size(): continue
			var a := verts[indices[i]]
			var b := verts[indices[i+1]]
			var c := verts[indices[i+2]]
			var owner := String(admitted.get(_key(a,b,c),""))
			a = node.global_transform*a; b = node.global_transform*b; c = node.global_transform*c
			var axis := _axis(a,b,c)
			if axis<0 or (owner.is_empty() and not interior and not (ground and axis==1)): continue
			var normal := (b-a).cross(c-a)
			if not a.is_finite() or not b.is_finite() or not c.is_finite() or normal.length_squared()<1e-12: continue
			var sign_value := 1 if normal[axis]>0.0 else -1
			var token := str(surface)+":"+str(axis)+":"+PackedFloat32Array([a[axis]]).to_byte_array().hex_encode()+":"+str(sign_value)
			if not groups.has(token): groups[token] = {"surface":surface,"axis":axis,"coordinate":a[axis],"sign":sign_value,"vertices":PackedVector3Array(),"owners":{}}
			var group: Dictionary = groups[token]
			var points: PackedVector3Array = group["vertices"]
			points.append_array(PackedVector3Array([a,b,c]))
			group["vertices"] = points
			if not owner.is_empty(): group["owners"][owner] = true
	if groups.is_empty(): return
	var source_index := _sources.size()
	var entry := CachedSource.new()
	entry.node = weakref(node)
	entry.mesh = weakref(mesh)
	entry.transform = node.global_transform
	entry.center = node.global_transform*mesh.get_aabb().get_center()
	entry.path = String(node.get_path())
	_sources.append(entry)
	var original_material_ids: Array = []
	for surface in mesh.get_surface_count():
		var material := node.get_active_material(surface)
		original_material_ids.append(material.get_instance_id() if material!=null else 0)
	report["source_records"].append({"source":entry.path,"source_mesh_id":mesh.get_instance_id(),
		"mesh_resource":mesh.resource_path,"original_material_ids":original_material_ids,
		"world_transform":_transform_record(node.global_transform),"source_arrays":fingerprints})
	_watch(mesh,"changed",Callable(self,"_mesh_changed").bind(source_index))
	for group: Dictionary in groups.values():
		var vertices: PackedVector3Array = group["vertices"]
		var indices := PackedInt32Array()
		indices.resize(vertices.size())
		for i in indices.size(): indices[i] = i
		var occluder := ArrayOccluder3D.new()
		occluder.set_arrays(vertices,indices)
		var native := OccluderInstance3D.new()
		native.name = "exact-opaque-plane-%04d" % _planes.size()
		native.visible = false
		native.occluder = occluder
		native.set_meta("environment_occlusion_plane",true)
		native.set_meta("environment_occlusion_source",entry.path)
		add_child(native)
		native.top_level = true
		native.global_transform = Transform3D.IDENTITY
		var plane_index := _planes.size()
		var plane := CachedPlane.new()
		plane.node = weakref(native)
		plane.surface = int(group["surface"])
		plane.axis = int(group["axis"])
		plane.coordinate = float(group["coordinate"])
		plane.sign_value = int(group["sign"])
		plane.triangles = vertices.size()/3
		_planes.append(plane)
		entry.planes.append(plane)
		_watch(native,"tree_exiting",Callable(self,"_plane_exiting").bind(plane_index))
		report["triangles"] += vertices.size()/3
		report["array_builds"] += 1
		report["plane_records"].append({"source":entry.path,"surface":group["surface"],
			"axis":group["axis"],"coordinate":group["coordinate"],"sign":group["sign"],"triangles":vertices.size()/3,
			"owners":group["owners"].keys(),"world_transform":_transform_record(node.global_transform),
			"vertex_sha256":_sha(vertices.to_byte_array()),"index_sha256":_sha(indices.to_byte_array())})
	_refresh_materials(source_index,node)

func set_enabled(active: bool) -> void:
	_enabled = active and not _disposed
	set_process(_enabled)
	if not _enabled: restore()

func set_hq(active: bool) -> void:
	_hq = active
	if not active: restore()

func _process(_dt: float) -> void:
	update()

func update() -> void:
	var start := Time.get_ticks_usec()
	var viewport := _viewport.get_ref() as Viewport if _viewport!=null else null
	var camera := viewport.get_camera_3d() if is_instance_valid(viewport) else null
	if not _enabled or not _hq or _disposed or camera==null:
		restore()
		return
	var eye := camera.global_position
	_frame_policy_stamps.clear()
	var active_planes := 0
	var active_triangles := 0
	for index in _sources.size():
		var entry: CachedSource = _sources[index]
		var node := entry.node.get_ref() as MeshInstance3D
		var valid := not entry.retired and is_instance_valid(node)
		if valid and (node.mesh!=entry.mesh.get_ref() or node.global_transform!=entry.transform):
			_retire(index,"mesh replacement or source transform changed")
			valid = false
		if valid:
			# Mesh identity/revision and exact transform above preserve the cached
			# ArrayMesh, blend-shape and positive-basis admission from configure.
			valid = _static_live(node) and (node.layers&camera.cull_mask)!=0 and _in_range(node,entry.center,eye)
			if valid:
				if entry.policy_dirty or not _materials_unchanged(entry,node): _refresh_materials(index,node)
				else: report["cache_hits"] += 1
		for plane: CachedPlane in entry.planes:
			var active := false
			if valid and plane.alive:
				var policy: int = entry.policies[plane.surface]
				active = policy == BaseMaterial3D.CULL_DISABLED or (policy == BaseMaterial3D.CULL_BACK \
					and (eye[plane.axis]-plane.coordinate)*plane.sign_value < -FRONT_EPS)
			_toggle(plane,active)
			if plane.active: active_planes += 1; active_triangles += plane.triangles
	viewport.use_occlusion_culling = active_planes>0 or _prior_flag
	_set_light_policy(active_planes>0)
	report["active_planes"] = active_planes
	report["active_triangles"] = active_triangles
	report["updates"] += 1
	report["update_usec"] = Time.get_ticks_usec()-start
	report["max_update_usec"] = maxi(int(report["max_update_usec"]),int(report["update_usec"]))

func _refresh_materials(index: int,node: MeshInstance3D) -> void:
	var entry: CachedSource = _sources[index]
	entry.materials.clear()
	entry.policies.clear()
	entry.policy_stamps.clear()
	for surface in node.mesh.get_surface_count():
		var material := node.get_active_material(surface)
		entry.materials.append(material)
		entry.policies.append(_opaque_cull(material))
		entry.policy_stamps.append(_policy_stamp(material))
		if material!=null:
			_watch(material,"changed",Callable(self,"_material_changed").bind(index))
			if material is ShaderMaterial and material.shader!=null:
				_watch(material.shader,"changed",Callable(self,"_material_changed").bind(index))
	entry.policy_dirty = false
	report["material_checks"] += 1

func _materials_unchanged(entry: CachedSource,node: MeshInstance3D) -> bool:
	for surface in entry.materials.size():
		var material := node.get_active_material(surface)
		if material!=entry.materials[surface] or _policy_stamp(material)!=entry.policy_stamps[surface]: return false
	return true

func _policy_stamp(material: Material) -> Array:
	if material==null: return []
	var id := material.get_instance_id()
	if _frame_policy_stamps.has(id): return _frame_policy_stamps[id]
	var signature: Array = [material.next_pass.get_instance_id() if material.next_pass!=null else 0]
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		var shader := shader_material.shader
		var cut: Variant = shader_material.get_shader_parameter("alpha_cut")
		var color: Variant = shader_material.get_shader_parameter("albedo")
		signature.append_array([shader.get_instance_id() if shader!=null else 0,
			shader.resource_path if shader!=null else "",typeof(cut),cut,
			typeof(color),(color as Color).a if color is Color else color])
	_frame_policy_stamps[id] = signature
	return signature

func _opaque_cull(material: Material) -> int:
	var shader_material := material as ShaderMaterial
	if shader_material==null or shader_material.next_pass!=null or shader_material.shader==null \
			or shader_material.shader.resource_path not in HQ_PATHS or not EnvironmentLod._undeformed_hq(shader_material.shader): return -1
	var cut: Variant = shader_material.get_shader_parameter("alpha_cut")
	var color: Variant = shader_material.get_shader_parameter("albedo")
	if cut!=null and (not cut is float and not cut is int or float(cut)!=0.0): return -1
	if color!=null and (not color is Color or (color as Color).a!=1.0): return -1
	return BaseMaterial3D.CULL_DISABLED if shader_material.shader.resource_path in [Materials.HQ_ALPHA_SHADER,Materials.HQ_OPAQUE_ALPHA_SHADER] else BaseMaterial3D.CULL_BACK

func _static(node: MeshInstance3D) -> bool:
	return node.mesh is ArrayMesh and (node.mesh as ArrayMesh).get_blend_shape_count()==0 \
		and node.global_basis.determinant()>.000001 and _static_live(node)

func _static_live(node: MeshInstance3D) -> bool:
	if node.get_script()!=null or node.layers==0 or not node.is_visible_in_tree() \
			or node.material_overlay!=null or node.get_node_or_null(node.skeleton) is Skeleton3D \
			or node.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY: return false
	for mark: String in MARKS:
		if node.has_meta(mark): return false
	return true

func _in_range(node: MeshInstance3D,center: Vector3,eye: Vector3) -> bool:
	if node.visibility_parent!=NodePath("") or node.visibility_range_fade_mode!=GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED: return false
	for point: Vector3 in [node.global_position,center]:
		var distance := eye.distance_to(point)
		if node.visibility_range_begin>0 and distance<=node.visibility_range_begin+node.visibility_range_begin_margin: return false
		if node.visibility_range_end>0 and distance>=node.visibility_range_end-node.visibility_range_end_margin: return false
	return true

func _mesh_changed(index: int) -> void:
	report["mesh_revisions"] += 1
	_retire(index,"source mesh.changed")

func _material_changed(index: int) -> void:
	_sources[index].policy_dirty = true
	_hide_source(index)

func _retire(index: int,reason: String) -> void:
	if not _sources[index].retired:
		_sources[index].retired = true
		report["retired_sources"] += 1
		_sources[index].retire_reason = reason
	_hide_source(index)

func _hide_source(index: int) -> void:
	for plane: CachedPlane in _sources[index].planes: _toggle(plane,false)
	_set_light_policy(false)
	var viewport := _viewport.get_ref() as Viewport if _viewport!=null else null
	if is_instance_valid(viewport): viewport.use_occlusion_culling = false

func _toggle(plane: CachedPlane,active: bool) -> void:
	if plane.active==active or not plane.alive: return
	var node := plane.node.get_ref() as OccluderInstance3D
	if not is_instance_valid(node):
		plane.active = false
		plane.alive = false
		return
	node.visible = active
	plane.active = active
	report["visibility_changes"] += 1

func _plane_exiting(index: int) -> void:
	var plane: CachedPlane = _planes[index]
	if plane.active:
		report["active_planes"] = maxi(0,int(report["active_planes"])-1)
		report["active_triangles"] = maxi(0,int(report["active_triangles"])-plane.triangles)
	_toggle(plane,false)
	plane.alive = false
	if int(report["active_planes"])==0:
		_set_light_policy(false)
		var viewport := _viewport.get_ref() as Viewport if _viewport!=null else null
		if is_instance_valid(viewport): viewport.use_occlusion_culling = _prior_flag

func restore() -> void:
	for plane: CachedPlane in _planes: _toggle(plane,false)
	_set_light_policy(false)
	var viewport := _viewport.get_ref() as Viewport if _viewport!=null else null
	if is_instance_valid(viewport): viewport.use_occlusion_culling = _prior_flag
	report["active_planes"] = 0
	report["active_triangles"] = 0

func _node_added(node: Node) -> void:
	if node is OmniLight3D or node is SpotLight3D: _track_light(node)

func _track_light(node: Node) -> void:
	if _disposed: return
	var world := _world.get_ref() as Node3D if _world!=null else null
	if not is_instance_valid(world) or not world.is_ancestor_of(node) or node.get_viewport()!=_viewport.get_ref(): return
	var id := node.get_instance_id()
	var entry: CachedLight
	if _light_ids.has(id):
		entry = _light_ids[id]
		if entry.inside: return
		entry.inside = true
	else:
		entry = CachedLight.new()
		entry.node = weakref(node)
		entry.instance = (node as Light3D).get_instance()
		_lights.append(entry)
		_light_ids[id] = entry
		_watch(node,"tree_exiting",Callable(self,"_light_exiting").bind(entry))
	report["light_sources"] += 1
	_toggle_light(entry,_light_policy_on)

func _set_light_policy(active: bool) -> void:
	if _light_policy_on==active: return
	_light_policy_on = active
	for entry: CachedLight in _lights:
		if entry.inside: _toggle_light(entry,active)

func _toggle_light(entry: CachedLight,active: bool) -> void:
	if entry.owned_on==active: return
	var light := entry.node.get_ref() as Light3D
	if not is_instance_valid(light) or not entry.instance.is_valid():
		if entry.owned_on: report["owned_light_flags"] -= 1
		entry.owned_on = false
		return
	# The pinned engine's generic instance flag accepts Light3D RIDs.
	# No public getter exists; default false and sole ownership are explicit.
	RenderingServer.instance_geometry_set_flag(entry.instance,RenderingServer.INSTANCE_FLAG_IGNORE_OCCLUSION_CULLING,active)
	report["light_render_flag_mutations"] += 1
	report["owned_light_flags"] += 1 if active else -1
	entry.owned_on = active

func _light_exiting(entry: CachedLight) -> void:
	if not entry.inside: return
	_toggle_light(entry,false)
	entry.inside = false
	report["light_sources"] -= 1

func resync(_state: GameState = null) -> void:
	restore()
	report["resyncs"] += 1
	for entry: CachedSource in _sources: entry.policy_dirty = true

func stats() -> Dictionary:
	var snapshot := report.duplicate(true)
	var viewport := _viewport.get_ref() as Viewport if _viewport!=null else null
	snapshot["enabled"] = _enabled
	snapshot["hq"] = _hq
	snapshot["native_enabled"] = viewport.use_occlusion_culling if is_instance_valid(viewport) else false
	return snapshot

func _watch(object: Object,signal_name: String,callback: Callable) -> void:
	if object.is_connected(signal_name,callback): return
	object.connect(signal_name,callback)
	_signals.append({"object":weakref(object),"signal":signal_name,"callback":callback})

func dispose() -> void:
	if _disposed: return
	set_enabled(false)
	_disposed = true
	for row: Dictionary in _signals:
		var object: Object = row["object"].get_ref()
		if is_instance_valid(object) and object.is_connected(row["signal"],row["callback"]): object.disconnect(row["signal"],row["callback"])
	_signals.clear()
	for plane: CachedPlane in _planes:
		var node := plane.node.get_ref() as OccluderInstance3D
		if is_instance_valid(node): node.queue_free()
	_planes.clear()
	_sources.clear()
	_lights.clear()
	_light_ids.clear()
	report["light_sources"] = 0

func _exit_tree() -> void:
	dispose()

func _axis(a: Vector3,b: Vector3,c: Vector3) -> int:
	for axis in 3:
		if a[axis]==b[axis] and a[axis]==c[axis]: return axis
	return -1

func _key(a: Vector3,b: Vector3,c: Vector3) -> String:
	return PackedVector3Array([a,b,c]).to_byte_array().hex_encode()

func _sha(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

func _transform_record(transform: Transform3D) -> Array:
	return [transform.basis.x.x,transform.basis.x.y,transform.basis.x.z,
		transform.basis.y.x,transform.basis.y.y,transform.basis.y.z,
		transform.basis.z.x,transform.basis.z.y,transform.basis.z.z,
		transform.origin.x,transform.origin.y,transform.origin.z]

## Immutable static surfaces share visible geometry with conservative native LOD.
extends RefCounted

const META := "environment_static_interiors"
const DETAIL := preload("res://src/environment_detail_ranges.gd")
const INTERIORS := preload("res://src/environment_interiors.gd")
const CELL := 6.0
const MAX_SPAN := 8.0
# Audited immutable Props.by_id roots. Their interaction roots and physics
# remain in place; only eligible render surfaces can join a static bucket.
const NAMED_STATIC := ["workbench", "coat-rack", "veranda-stand", "hall-stand", "stove", "fridge",
	"kitchen-cabinet", "kitchen-sink", "wall-unit", "tv-stand", "sofa", "kitchen-table", "wall-rug",
	"coffee-table", "aunt-bed", "aunt-wardrobe", "aunt-nightstand", "dresser", "aunt-mirror",
	"washstand", "landing-shelf", "vitya-bed", "vitya-desk", "tape-shelf", "sewing-machine",
	"storage-wardrobe", "nest-mattress", "junk-pile"]
const FLAGS := ["layers", "cast_shadow", "visibility_range_begin", "visibility_range_end",
	"visibility_range_begin_margin", "visibility_range_end_margin", "visibility_range_fade_mode",
	"lod_bias", "transparency", "sorting_offset", "sorting_use_aabb_center", "extra_cull_margin",
	"gi_mode", "ignore_occlusion_culling"]

class CallbackState extends RefCounted:
	var record: Dictionary
	func _init(value: Dictionary) -> void: record = value
	func invalidate() -> void:
		if not bool(record["retired"]): _fallback(record)
	func _fallback(value: Dictionary) -> void:
		if not bool(value["active"]): return
		value["active"] = false
		for proxy: Variant in value["proxies"]:
			if is_instance_valid(proxy): proxy.visible = false
		for witness: Dictionary in value["witnesses"]:
			var source: Variant = witness["source"]
			# An external mask belongs to its controller, even after invalidation.
			if not is_instance_valid(source): continue
			if source.get_meta("environment_static_batch_owner",0) == value["token"]:
				if source.layers == 0: source.layers = witness["flags"][0]
				source.remove_meta("environment_static_batch_owner")
				source.remove_meta("environment_static_batch_surfaces")

class Controller extends RefCounted:
	var world: Node3D
	var world_transform: Transform3D
	var records: Array[Dictionary] = []
	var connections: Array[Dictionary] = []
	var states: Array[CallbackState] = []
	var report := {"buckets":0, "sources":0, "before":0, "after":0, "saved":0,
		"triangles":0, "physics_mutations":0, "material_mutations":0, "rejected":{}, "details":[],
		"named_authorized":NAMED_STATIC.size(), "named_present":[], "named_candidates":[],
		"named_eligible":[], "named_admitted":[], "named_unmerged":[], "named_rejected":{}}
	var restored := false

	## Explicit guard for a caller that changes immutable geometry/pose/flags.
	## Ordinary quality changes mutate shared materials, so both views stay equal.
	func validate() -> int:
		var invalidated := 0
		# Native keys cache global source/proxy model-scale ratios. Relative
		# poses alone do not witness a changed nonuniform world basis.
		if not is_instance_valid(world) or world.global_transform != world_transform:
			for record: Dictionary in records:
				if not bool(record["active"]): continue
				states[record["callback_index"]].invalidate()
				invalidated += 1
			return invalidated
		for record: Dictionary in records:
			if not bool(record["active"]): continue
			for witness: Dictionary in record["witnesses"]:
				if not _unchanged(witness):
					states[record["callback_index"]].invalidate()
					invalidated += 1
					break
		return invalidated

	func _unchanged(witness: Dictionary) -> bool:
		var source: Variant = witness["source"]
		if not is_instance_valid(source) or not source.is_inside_tree() or not source.is_visible_in_tree(): return false
		if source.layers != 0 or source.mesh != witness["mesh"]: return false
		if world.global_transform.affine_inverse()*source.global_transform != witness["transform"]: return false
		for i in range(1, FLAGS.size()):
			if source.get(FLAGS[i]) != witness["flags"][i]: return false
		if source.material_overlay != null or source.custom_aabb != AABB(): return false
		if source.mesh.get_surface_count() != witness["materials"].size(): return false
		for i in source.mesh.get_surface_count():
			if source.get_active_material(i) != witness["materials"][i]: return false
		return true

	## Call before external skin replacement; never copy our temporary layers=0.
	func restore() -> void:
		if restored: return
		restored = true
		for record: Dictionary in records: record["retired"] = true
		for connection: Dictionary in connections:
			var source: Variant = connection["source"]
			if is_instance_valid(source) and source.is_connected(connection["signal"],connection["callable"]):
				source.disconnect(connection["signal"],connection["callable"])
		for record: Dictionary in records:
			states[record["callback_index"]]._fallback(record)
			for proxy: Variant in record["proxies"]:
				if is_instance_valid(proxy): proxy.free()
		if is_instance_valid(world) and world.get_meta(META,null) == self: world.remove_meta(META)
		connections.clear()
		records.clear()
		states.clear()


## After DetailRanges/final quality and before Retained/Inventory/shader warming.
static func prepare(world: Node3D, built: Dictionary, props: Props) -> Controller:
	if world.has_meta(META): return world.get_meta(META)
	var controller := Controller.new()
	controller.world = world
	controller.world_transform = world.global_transform
	world.set_meta(META,controller)
	if OS.get_cmdline_user_args().has("--environment=off"): return controller
	var holders: Array[Node3D] = []
	var named := props.by_id.values()
	var pooled := props.dynamic_pool.values()
	var dynamic: Dictionary = {}
	for definition: Dictionary in GameData.props().get("DYNAMIC_PROPS",[]): dynamic[String(definition["id"])] = true
	if is_instance_valid(props.root):
		for node: Node in props.root.get_children():
			if node is Node3D and not named.has(node) and not pooled.has(node) and not dynamic.has(String(node.name)):
				holders.append(node)
	var named_ids: Dictionary = {}
	for id: String in NAMED_STATIC:
		var node: Variant = props.by_id.get(id)
		if not is_instance_valid(node): continue
		controller.report["named_present"].append(id)
		if not node is Node3D or node.get_parent() != props.root or not node.is_inside_tree():
			controller.report["named_rejected"][id] = "not a live Props root"
			continue
		if pooled.has(node) or dynamic.has(id) or dynamic.has(String(node.name)):
			controller.report["named_rejected"][id] = "pooled or dynamic"
			continue
		if not holders.has(node): holders.append(node)
		if not named_ids.has(node): named_ids[node] = []
		named_ids[node].append(id)
		controller.report["named_candidates"].append(id)
	for id: String in DETAIL.HOME:
		var node: Variant = built.get("home",{}).get("nodes",{}).get(id)
		if is_instance_valid(node) and node is Node3D and not holders.has(node): holders.append(node)
	var buckets: Dictionary = {}
	var spatial: Dictionary = {}
	var rooms := INTERIORS._rooms()
	for holder: Node3D in holders:
		var candidate := _candidate(world,holder)
		if candidate.is_empty():
			controller.report["rejected"][String(holder.name)] = "runtime, hidden, nonopaque, skin, caster or unsupported state"
			for id: String in named_ids.get(holder,[]):
				controller.report["named_rejected"][id] = controller.report["rejected"][String(holder.name)]
			continue
		for id: String in named_ids.get(holder,[]): controller.report["named_eligible"].append(id)
		var bounds: AABB = candidate["bounds"]
		var bucket := ""
		for room: Dictionary in rooms:
			var b: Array = room["box"]
			var box := AABB(Vector3(b[0]-.03,float(room["floor"])-.1,b[2]-.03),
				Vector3(b[1]-b[0]+.06,float(room["height"])+.2,b[3]-b[2]+.06))
			if box.encloses(bounds): bucket = "room:"+String(room["id"]); break
		if bucket.is_empty():
			if _span(bounds) > MAX_SPAN: continue
			var center := bounds.get_center()
			var cell := "%d,%d,%d" % [floori(center.x/CELL),floori(center.y/CELL),floori(center.z/CELL)]
			if not spatial.has(cell): spatial[cell] = []
			var clusters: Array = spatial[cell]
			var cluster := -1
			for i in clusters.size():
				var union: AABB = clusters[i].merge(bounds)
				if _span(union) <= MAX_SPAN:
					cluster = i
					clusters[i] = union
					break
			if cluster < 0:
				cluster = clusters.size()
				clusters.append(bounds)
			bucket = "grid:"+cell+":"+str(cluster)
		if not buckets.has(bucket): buckets[bucket] = []
		buckets[bucket].append(candidate)
	for bucket: String in buckets: _build(controller,bucket,buckets[bucket])
	# Eligible holders with unique materials may create no batch at all. Do not
	# report them as installed or count the whitelist as measured savings.
	for id: String in controller.report["named_eligible"]:
		var path := String(world.get_path_to(props.by_id[id]))
		var admitted := false
		for detail: Dictionary in controller.report["details"]:
			if detail["holders"].has(path): admitted = true; break
		controller.report["named_admitted" if admitted else "named_unmerged"].append(id)
	return controller


static func _candidate(world: Node3D, holder: Node3D) -> Dictionary:
	if not holder.is_visible_in_tree(): return {}
	var nodes: Array[Node] = [holder]
	var meshes: Array[MeshInstance3D] = []
	var bounds := AABB()
	var index := 0
	while index < nodes.size():
		var node: Node = nodes[index]
		index += 1
		nodes.append_array(node.get_children())
		if node.get_script() != null or node is AnimationPlayer or node is AnimationTree or node is Skeleton3D: return {}
		for meta: String in ["independent_visual","deformation","skin_asset","skin_original_layers","skin_dynamic_children","environment_owner","environment_static_batch_surfaces"]:
			if node.has_meta(meta): return {}
		if node is Node3D and node.top_level: return {}
		if not node is MeshInstance3D: continue
		var source := node as MeshInstance3D
		if source.mesh == null: continue
		var relative := world.global_transform.affine_inverse()*source.global_transform
		if not _eligible(source,relative.basis): return {}
		var box: AABB = relative*source.get_aabb()
		bounds = box if meshes.is_empty() else bounds.merge(box)
		meshes.append(source)
	if meshes.is_empty(): return {}
	return {"holder":holder,"sources":meshes,"bounds":bounds}


static func _eligible(source: MeshInstance3D, relative_basis: Basis) -> bool:
	if source.layers != 1 or not source.is_visible_in_tree() or source.global_basis.determinant() <= .000001: return false
	if source.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF or source.skin != null: return false
	# Native LOD admits no custom source bounds or local margin.
	if source.extra_cull_margin != 0.0: return false
	if not is_finite(source.lod_bias) or source.lod_bias <= 0.0: return false
	if source.material_overlay != null or source.transparency != 0.0 or source.custom_aabb != AABB() or not source.visibility_parent.is_empty(): return false
	if source.visibility_range_begin != 0.0 or source.visibility_range_fade_mode != GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED: return false
	if not source.mesh is ArrayMesh and not source.mesh is PrimitiveMesh: return false
	# With casting OFF, a retained shadow_mesh never supplies visible geometry.
	# Always merge the base surface arrays and leave that resource untouched.
	if source.mesh is ArrayMesh and source.mesh.get_blend_shape_count() != 0: return false
	if source.mesh is ArrayMesh:
		var packed: Array = source.mesh.get("_surfaces")
		for surface: Dictionary in packed:
			var lods: Array = surface.get("lods",[])
			if lods.size()%2 != 0: return false
			for i in range(0,lods.size(),2):
				if not lods[i] is float and not lods[i] is int: return false
				if not is_finite(float(lods[i])) or float(lods[i]) <= 0.0 or not lods[i+1] is PackedByteArray: return false
	for surface in source.mesh.get_surface_count():
		if source.mesh is ArrayMesh and source.mesh.surface_get_primitive_type(surface) != Mesh.PRIMITIVE_TRIANGLES: return false
		var arrays := source.mesh.surface_get_arrays(surface)
		if arrays[Mesh.ARRAY_VERTEX] == null or arrays[Mesh.ARRAY_VERTEX].is_empty(): return false
		for slot in [Mesh.ARRAY_BONES,Mesh.ARRAY_WEIGHTS,Mesh.ARRAY_CUSTOM0,Mesh.ARRAY_CUSTOM1,Mesh.ARRAY_CUSTOM2,Mesh.ARRAY_CUSTOM3]:
			if arrays[slot] != null and arrays[slot].size() > 0: return false
		var material := source.get_active_material(surface)
		if not _opaque(material): return false
		# GLES3 applies its inverse-transpose to normal, tangent and binormal.
		# A nonconformal baked basis cannot preserve all three for built-ins.
		# The admitted HQ/PSX shaders derive their frame without TANGENT.
		if material is BaseMaterial3D and not relative_basis.is_conformal(): return false
	return source.mesh.get_surface_count() > 0


static func _opaque(material: Material) -> bool:
	if material == null or material.next_pass != null: return false
	if material is ShaderMaterial:
		if material.shader == null: return false
		var path: String = material.shader.resource_path
		if path not in [Materials.HQ_SHADER,Materials.HQ_OPAQUE_SHADER,Materials.HQ_ALPHA_SHADER,
				Materials.HQ_OPAQUE_ALPHA_SHADER,Materials.PSX_SHADER] or material.shader != load(path): return false
		if material.shader.code.contains("instance uniform"): return false
		var cut: Variant = material.get_shader_parameter("alpha_cut")
		var albedo: Variant = material.get_shader_parameter("albedo")
		var safe_cut: bool = cut == null or ((cut is float or cut is int) and is_finite(float(cut)) and float(cut) <= 0.0)
		return safe_cut and (not albedo is Color or albedo.a >= 1.0)
	if material is BaseMaterial3D:
		return material.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED and not material.no_depth_test \
			and material.billboard_mode == BaseMaterial3D.BILLBOARD_DISABLED and not material.grow \
			and not material.uv1_triplanar and not material.uv2_triplanar
	return false


static func _flags(source: MeshInstance3D) -> Array:
	var result: Array = []
	for name: String in FLAGS: result.append(source.get(name))
	return result


static func _format(arrays: Array) -> int:
	var result := 0
	for slot in arrays.size():
		if arrays[slot] != null and arrays[slot].size() > 0: result |= 1 << slot
	return result & ~(1 << Mesh.ARRAY_INDEX)


static func _span(bounds: AABB) -> float:
	return maxf(bounds.size.x,maxf(bounds.size.y,bounds.size.z))


static func _build(controller: Controller, bucket: String, candidates: Array) -> void:
	var world := controller.world
	var groups: Dictionary = {}
	var sources: Array[MeshInstance3D] = []
	var holders: Array = []
	var before := 0
	for candidate: Dictionary in candidates:
		holders.append(str(world.get_path_to(candidate["holder"])))
		for source: MeshInstance3D in candidate["sources"]:
			sources.append(source)
			for surface in source.mesh.get_surface_count():
				var material := source.get_active_material(surface)
				var arrays := source.mesh.surface_get_arrays(surface)
				var key := var_to_str([material.get_instance_id(),_flags(source),_format(arrays)])
				if not groups.has(key): groups[key] = []
				groups[key].append({"source":source,"surface":surface})
				before += 1
	# Singleton surfaces are included: layers=0 must never drop another surface.
	if before <= groups.size(): return
	var record := {"active":true,"retired":false,"witnesses":[],"proxies":[]}
	var callback := CallbackState.new(record)
	record["callback_index"] = controller.states.size()
	record["token"] = callback.get_instance_id()
	controller.states.append(callback)
	var mappings: Dictionary = {}
	var triangles := 0
	for key: String in groups:
		var pieces: Array = groups[key]
		var reference: MeshInstance3D = pieces[0]["source"]
		var proxy := MeshInstance3D.new()
		proxy.name = "static-interiors-"+bucket.replace(":","-")+"-%d" % record["proxies"].size()
		var bounds: AABB = world.global_transform.affine_inverse()*reference.global_transform*reference.get_aabb()
		for piece: Dictionary in pieces:
			var source: MeshInstance3D = piece["source"]
			bounds = bounds.merge(world.global_transform.affine_inverse()*source.global_transform*source.get_aabb())
		proxy.position = bounds.get_center()
		proxy.mesh = _merge(world,pieces,proxy.position)
		proxy.material_override = reference.get_active_material(pieces[0]["surface"])
		for flag: String in FLAGS: proxy.set(flag,reference.get(flag))
		# Each piece contributes the complete original mesh bounds, even when
		# this material group contains only one surface of that source.
		proxy.custom_aabb = AABB(bounds.position-proxy.position,bounds.size)
		proxy.extra_cull_margin = 0.0
		var center: Vector3 = proxy.position+proxy.custom_aabb.get_center()
		var padding := 0.0
		for piece: Dictionary in pieces:
			var source: MeshInstance3D = piece["source"]
			var source_center: Vector3 = world.global_transform.affine_inverse()*source.global_transform*source.get_aabb().get_center()
			padding = maxf(padding,(world.global_basis*(center-source_center)).length())
		if proxy.visibility_range_end > 0.0: proxy.visibility_range_end += padding
		proxy.set_meta("static_interior_batch",true)
		proxy.set_meta("environment_owner","static-interiors/"+bucket)
		proxy.set_meta("environment_source",holders.duplicate())
		proxy.set_meta("source_surface_count",pieces.size())
		proxy.set_meta("range_padding",padding)
		proxy.set_meta("native_lod_preserved",true)
		world.add_child(proxy)
		record["proxies"].append(proxy)
		if not _enclose_source_bounds(proxy,pieces):
			# Admission is atomic: no source has been masked or connected yet.
			for created: MeshInstance3D in record["proxies"]: created.free()
			record["retired"] = true
			controller.states.pop_back()
			controller.report["rejected"][bucket] = "effective proxy bounds do not enclose original bounds"
			return
		# Enclosure padding can move the float32 bounds center by one ULP.
		# Use the final effective center for native visibility-range padding.
		var actual_center := proxy.global_transform*proxy.custom_aabb.get_center()
		padding = 0.0
		for piece: Dictionary in pieces:
			var source: MeshInstance3D = piece["source"]
			padding = maxf(padding,actual_center.distance_to(source.global_transform*source.get_aabb().get_center()))
		if reference.visibility_range_end > 0.0:
			var range_end := reference.visibility_range_end+padding
			proxy.visibility_range_end = _float32(range_end)
			if proxy.visibility_range_end < range_end: proxy.visibility_range_end = _next_float32(proxy.visibility_range_end)
		proxy.set_meta("range_padding",padding)
		for piece: Dictionary in pieces:
			var source: MeshInstance3D = piece["source"]
			if not mappings.has(source): mappings[source] = {}
			mappings[source][piece["surface"]] = {"node":proxy,"surface":0}
		triangles += proxy.mesh.get_faces().size()/3
	var observed: Dictionary = {}
	for source: MeshInstance3D in sources:
		var materials: Array = []
		for surface in source.mesh.get_surface_count(): materials.append(source.get_active_material(surface))
		record["witnesses"].append({"source":source,"mesh":source.mesh,"materials":materials,
			"transform":world.global_transform.affine_inverse()*source.global_transform,"flags":_flags(source)})
		var cursor: Node = source
		while cursor != null:
			if not observed.has(cursor):
				observed[cursor] = true
				_connect(controller,cursor,"tree_exiting",callback.invalidate)
				if cursor is Node3D: _connect(controller,cursor,"visibility_changed",callback.invalidate)
			if cursor == world: break
			cursor = cursor.get_parent()
		if not observed.has(source.mesh):
			observed[source.mesh] = true
			_connect(controller,source.mesh,"changed",callback.invalidate)
	for source: MeshInstance3D in sources:
		source.set_meta("environment_static_batch_owner",record["token"])
		source.set_meta("environment_static_batch_surfaces",mappings[source])
		source.layers = 0
	controller.records.append(record)
	controller.report["buckets"] += 1
	controller.report["sources"] += sources.size()
	controller.report["before"] += before
	controller.report["after"] += groups.size()
	controller.report["saved"] += before-groups.size()
	controller.report["triangles"] += triangles
	controller.report["details"].append({"bucket":bucket,"holders":holders,"before":before,"after":groups.size(),"saved":before-groups.size(),"triangles":triangles})


static func _connect(controller: Controller, source: Object, signal_name: String, callable: Callable) -> void:
	source.connect(signal_name,callable)
	controller.connections.append({"source":source,"signal":signal_name,"callable":callable})


## Center subtraction/addition and world transforms round in float32. Test the
## actual renderer bounds after parenting, then grow outward until they contain
## every complete original bound. Failed enclosure keeps the original bucket.
static func _enclose_source_bounds(proxy: MeshInstance3D, pieces: Array) -> bool:
	var padding := maxf(.00001,_span(proxy.custom_aabb)*.000001)
	for attempt in 8:
		var effective: AABB = proxy.global_transform*proxy.custom_aabb
		var encloses := true
		for piece: Dictionary in pieces:
			var source: MeshInstance3D = piece["source"]
			if not effective.encloses(source.global_transform*source.get_aabb()): encloses = false; break
		if encloses: return true
		proxy.custom_aabb = proxy.custom_aabb.grow(padding)
		padding *= 2.0
	return false


static func _merge(world: Node3D, pieces: Array, center: Vector3) -> ArrayMesh:
	var first: Dictionary = pieces[0]
	var arrays: Array = first["source"].mesh.surface_get_arrays(first["surface"])
	for slot in arrays.size():
		if arrays[slot] != null: arrays[slot] = arrays[slot].duplicate(); arrays[slot].clear()
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array()
	var lod_sources: Array = []
	var keys: Array[float] = []
	var proxy_scale := _model_scale(world.global_basis)
	for piece: Dictionary in pieces:
		var source: MeshInstance3D = piece["source"]
		var part := source.mesh.surface_get_arrays(piece["surface"])
		var transform := world.global_transform.affine_inverse()*source.global_transform
		transform.origin -= center
		var normal_basis := transform.basis.inverse().transposed()
		var offset: int = arrays[Mesh.ARRAY_VERTEX].size()
		var base := PackedInt32Array()
		for vertex: Vector3 in part[Mesh.ARRAY_VERTEX]: arrays[Mesh.ARRAY_VERTEX].append(transform*vertex)
		if part[Mesh.ARRAY_NORMAL] != null:
			for normal: Vector3 in part[Mesh.ARRAY_NORMAL]: arrays[Mesh.ARRAY_NORMAL].append((normal_basis*normal).normalized())
		if part[Mesh.ARRAY_TANGENT] != null:
			for i in range(0,part[Mesh.ARRAY_TANGENT].size(),4):
				var tangent := (transform.basis*Vector3(part[Mesh.ARRAY_TANGENT][i],part[Mesh.ARRAY_TANGENT][i+1],part[Mesh.ARRAY_TANGENT][i+2])).normalized()
				arrays[Mesh.ARRAY_TANGENT].append_array(PackedFloat32Array([tangent.x,tangent.y,tangent.z,part[Mesh.ARRAY_TANGENT][i+3]]))
		for slot in [Mesh.ARRAY_COLOR,Mesh.ARRAY_TEX_UV,Mesh.ARRAY_TEX_UV2]:
			if part[slot] != null: arrays[slot].append_array(part[slot])
		if part[Mesh.ARRAY_INDEX] != null and not part[Mesh.ARRAY_INDEX].is_empty():
			for index: int in part[Mesh.ARRAY_INDEX]: base.append(offset+index)
		else:
			for index in part[Mesh.ARRAY_VERTEX].size(): base.append(offset+index)
		arrays[Mesh.ARRAY_INDEX].append_array(base)
		var lods := _native_lods(source.mesh,piece["surface"])
		var normalized: Array = []
		for lod: Dictionary in lods:
			var q := _normalized_key(float(lod["edge"]),_model_scale(source.global_basis),proxy_scale,source.lod_bias)
			var indices := PackedInt32Array()
			for index: int in lod["indices"]: indices.append(offset+index)
			normalized.append({"q":q,"indices":indices})
			if not keys.has(q): keys.append(q)
		lod_sources.append({"base":base,"lods":normalized})
	keys.sort()
	var combined: Dictionary = {}
	for q: float in keys:
		var indices := PackedInt32Array()
		for source: Dictionary in lod_sources:
			var selected: PackedInt32Array = source["base"]
			for lod: Dictionary in source["lods"]:
				if float(lod["q"]) > q: break
				selected = lod["indices"]
			indices.append_array(selected)
		combined[q] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],combined)
	return mesh


static func _model_scale(basis: Basis) -> float:
	var scale := basis.get_scale().abs()
	return maxf(scale.x,maxf(scale.y,scale.z))


## ArrayMesh/GLES3 store these values as float32. Round toward finer detail:
## the proxy scaled edge must never fall below the original scaled edge.
static func _normalized_key(edge: float, source_scale: float, proxy_scale: float, bias: float) -> float:
	var original := _float32(edge*_float32(source_scale*bias))
	var proxy_factor := _float32(proxy_scale*bias)
	var q := _float32(original/proxy_factor)
	if q < original/proxy_factor: q = _next_float32(q)
	while _float32(q*proxy_factor) < original: q = _next_float32(q)
	return q


static func _float32(value: float) -> float:
	return PackedFloat32Array([value])[0]


static func _next_float32(value: float) -> float:
	var bytes := PackedFloat32Array([value]).to_byte_array()
	bytes.encode_u32(0,bytes.decode_u32(0)+1)
	return bytes.decode_float(0)


static func _native_lods(mesh: Mesh, surface: int) -> Array:
	if not mesh is ArrayMesh: return []
	var serialized: Array = mesh.get("_surfaces")
	var raw: Dictionary = serialized[surface]
	var pairs: Array = raw.get("lods",[])
	if pairs.is_empty(): return []
	var base_count := int(raw.get("index_count",0))
	var index_bytes: PackedByteArray = raw.get("index_data",PackedByteArray())
	var stride: int = index_bytes.size()/base_count if base_count > 0 else (2 if int(raw["vertex_count"]) <= 65536 else 4)
	var result: Array = []
	for i in range(0,pairs.size(),2):
		var data: PackedByteArray = pairs[i+1]
		var indices := PackedInt32Array()
		for offset in range(0,data.size(),stride):
			indices.append(data.decode_u16(offset) if stride == 2 else data.decode_u32(offset))
		result.append({"edge":float(pairs[i]),"indices":indices})
	result.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return float(a["edge"]) < float(b["edge"]))
	return result

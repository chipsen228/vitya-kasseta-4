## Immutable WorldBuilder buckets, retained walls and authored interior surfaces.
class_name StaticShadowBatch
extends RefCounted

const META := "static_shadow_batch"
const MAX_GROUP_SPAN := 64.0
# Keep distant casters out of a nearby shadow map without changing their shape.
const SHADOW_CELL := 16.0
const DENSE_SHADOW_TRIANGLES := 4000
const DENSE_SHADOW_CELL := 6.0
const BASELINE_DENSE_SHADOW_CELL := 8.0
const OPAQUE_SHADERS := [Materials.PSX_SHADER, Materials.HQ_SHADER, Materials.HQ_OPAQUE_SHADER, Materials.GROUND_SHADER]

class CallbackState extends RefCounted:
	var record: Dictionary
	func _init(value: Dictionary) -> void:
		record = value
	func visibility_changed(source: MeshInstance3D) -> void:
		StaticShadowBatch._source_visibility_changed(record, source)
	func tree_exiting() -> void:
		StaticShadowBatch._invalidate(record)

static func diagnose(world_root: Node3D) -> Dictionary:
	return _diagnose(world_root, _groups(world_root))

static func _diagnose(world_root: Node3D, groups: Dictionary) -> Dictionary:
	var out := {"candidates": 0, "sources": 0, "proxies": 0, "saved": 0, "triangles": 0, "groups": []}
	for key: String in groups:
		var sources: Array = groups[key]
		out["candidates"] += sources.size()
		if sources.size() < 2:
			continue
		var names: Array = []
		for source: MeshInstance3D in sources:
			names.append(String(source.name))
			out["triangles"] += source.mesh.get_faces().size() / 3
		out["sources"] += sources.size()
		out["proxies"] += 1
		(out["groups"] as Array).append({"key": key, "sources": names, "bounds_position": str(_bounds(world_root, sources).position), "bounds_size": str(_bounds(world_root, sources).size)})
	out["saved"] = int(out["sources"]) - int(out["proxies"])
	return out

static func _groups(world_root: Node3D) -> Dictionary:
	var groups: Dictionary = {}
	for source: MeshInstance3D in _candidates(world_root):
		if not _eligible(source, world_root):
			continue
		var material := source.get_active_material(0) as ShaderMaterial
		var centre := _relative(world_root, source) * source.get_aabb().get_center()
		# Whole material buckets also use the legacy suffix 0.0 even when far
		# apart; the real centre prevents a single map-wide shadow AABB.
		var cell := Vector2i(int(floor((centre.x + WorldBuilder.CHUNK_ORIGIN_X) / WorldBuilder.CHUNK_CELL)),
			int(floor((centre.z + WorldBuilder.CHUNK_ORIGIN_Z) / WorldBuilder.CHUNK_CELL)))
		# Opaque material names and colours do not change the shadow pass.
		var key := var_to_str([cell, source.layers, _cull(material), source.visibility_range_begin, source.visibility_range_end,
			source.visibility_range_begin_margin, source.visibility_range_end_margin, source.visibility_range_fade_mode])
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(source)
	for key: String in groups.keys():
		var bounds := _bounds(world_root, groups[key])
		if bounds.size.x > MAX_GROUP_SPAN or bounds.size.z > MAX_GROUP_SPAN:
			groups.erase(key)
	return groups

static func _bounds(world_root: Node3D, sources: Array) -> AABB:
	var bounds: AABB = _relative(world_root, sources[0]) * sources[0].get_aabb()
	for i in range(1, sources.size()):
		bounds = bounds.merge(_relative(world_root, sources[i]) * sources[i].get_aabb())
	return bounds

static func _candidates(world_root: Node3D) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for child: Node in world_root.get_children():
		if not child is MeshInstance3D:
			continue
		var source := child as MeshInstance3D
		if source.has_meta("environment_interior") and source.has_meta("environment_interior_role"):
			result.append(source)
		elif String(source.name).begins_with("merged_") and source.get_script() == null:
			if source.has_meta("environment_residual"):
				# The original still owns its immutable mesh and hidden vertices.
				# Only its explicit retained child can contribute to the new batch.
				var residual: Variant = source.get_meta("environment_residual")
				if is_instance_valid(residual) and residual is MeshInstance3D and source.is_ancestor_of(residual):
					result.append(residual)
			else:
				result.append(source)
	return result

static func _relative(world_root: Node3D, source: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var cursor: Node = source
	while cursor != world_root and cursor != null:
		if cursor is Node3D:
			result = (cursor as Node3D).transform * result
		cursor = cursor.get_parent()
	return result

static func _visible_below_world(source: Node3D, world_root: Node3D) -> bool:
	var cursor: Node = source
	while cursor != world_root and cursor != null:
		if cursor is Node3D and not (cursor as Node3D).visible:
			return false
		cursor = cursor.get_parent()
	return cursor == world_root

static func _eligible(source: MeshInstance3D, world_root: Node3D, check_mode := true) -> bool:
	if source.layers == 0 or not _visible_below_world(source, world_root):
		return false
	if check_mode and source.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_ON:
		return false
	if source.get_script() != null or source.get_child_count() > 0 or source.skin != null:
		return false
	if source.material_overlay != null or source.transparency != 0.0 or source.custom_aabb != AABB():
		return false
	if source.extra_cull_margin != 0.0 or source.visibility_parent != NodePath():
		return false
	if source.has_meta("independent_visual") or source.has_meta("deformation"):
		return false
	var cursor: Node = source
	while cursor != world_root:
		if cursor == null or cursor.get_script() != null:
			return false
		if cursor is Node3D and (cursor as Node3D).top_level:
			return false
		for child: Node in cursor.get_children():
			if child is AnimationPlayer or child is AnimationTree:
				return false
		cursor = cursor.get_parent()
	# Mirrored instances need renderer winding reversal; leave them untouched.
	if _relative(world_root, source).basis.determinant() <= 0.000001:
		return false
	if not source.mesh is ArrayMesh:
		return false
	var mesh := source.mesh as ArrayMesh
	if mesh.get_surface_count() != 1 or mesh.get_blend_shape_count() != 0 or mesh.shadow_mesh != null:
		return false
	if mesh.surface_get_primitive_type(0) != Mesh.PRIMITIVE_TRIANGLES:
		return false
	var arrays := mesh.surface_get_arrays(0)
	if arrays[Mesh.ARRAY_NORMAL] == null or arrays[Mesh.ARRAY_NORMAL].size() != arrays[Mesh.ARRAY_VERTEX].size():
		return false
	for slot in [Mesh.ARRAY_BONES, Mesh.ARRAY_WEIGHTS, Mesh.ARRAY_CUSTOM0, Mesh.ARRAY_CUSTOM1, Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
		if arrays[slot] != null and arrays[slot].size() > 0:
			return false
	var material := source.get_active_material(0) as ShaderMaterial
	if material == null or material.shader == null or material.next_pass != null:
		return false
	if material.shader.resource_path not in OPAQUE_SHADERS:
		return false
	var alpha: Variant = material.get_shader_parameter("alpha_cut")
	if alpha != null and float(alpha) > 0.0:
		return false
	var albedo: Variant = material.get_shader_parameter("albedo")
	if albedo is Color and (albedo as Color).a < 1.0:
		return false
	return _cull(material) >= 0

static func _cull(material: ShaderMaterial) -> int:
	var code := material.shader.code
	if code.contains("cull_disabled"):
		return BaseMaterial3D.CULL_DISABLED
	if code.contains("cull_front"):
		return BaseMaterial3D.CULL_FRONT
	if code.contains("cull_back"):
		return BaseMaterial3D.CULL_BACK
	return -1
## Prepare disabled proxies once. RenderChain enables them after HQ materials.
static func prepare(world_root: Node3D) -> Dictionary:
	if world_root.has_meta(META):
		return stats(world_root)
	return _prepare(world_root, false)

## Call after owner masking and interior replacement, before the quality sweep.
static func rebuild(world_root: Node3D) -> Dictionary:
	var old: Dictionary = world_root.get_meta(META, {})
	var hq := bool(old.get("hq", false))
	for record: Dictionary in old.get("records", []):
		# Held/stale Callables must also become harmless after disconnection.
		record["retired"] = true
	for connection: Dictionary in old.get("connections", []):
		var source: Variant = connection["source"]
		if not is_instance_valid(source):
			continue
		if source.is_connected(connection["signal"], connection["callable"]):
			source.disconnect(connection["signal"], connection["callable"])
	for record: Dictionary in old.get("records", []):
		_restore(record)
		for proxy: Variant in record["proxies"]:
			if is_instance_valid(proxy):
				proxy.free()
	if world_root.has_meta(META):
		world_root.remove_meta(META)
	var info := _prepare(world_root, true)
	set_hq(world_root, hq)
	return info

static func _prepare(world_root: Node3D, late: bool) -> Dictionary:
	var groups := _groups(world_root)
	var info := _diagnose(world_root, groups)
	var state := {"hq": false, "records": [], "connections": [], "callback_states": [], "stats": info}
	world_root.set_meta(META, state)
	# Skip tiny source sets. Spatial partitions then trade some of this initial
	# call saving for tighter shadow culling; stats report the actual result.
	if not late and int(info["saved"]) < 50:
		return info
	_build(world_root, state, groups)
	return info

static func stats(world_root: Node3D) -> Dictionary:
	var state: Dictionary = world_root.get_meta(META, {})
	return state.get("stats", {})

static func records(world_root: Node3D) -> Array:
	var state: Dictionary = world_root.get_meta(META, {})
	return state.get("records", [])

static func _build(world_root: Node3D, state: Dictionary, groups: Dictionary) -> void:
	var materials: Dictionary = {}
	var proxy_count := 0
	var source_count := 0
	var triangle_count := 0
	var dense6_groups := 0
	var dense8_fallback_groups := 0
	var unprofitable_groups := 0
	for key: String in groups:
		var sources: Array = groups[key]
		if sources.size() < 2:
			continue
		var coarse := _shadow_coarse_chunks(world_root, sources)
		var dense_cell_size := DENSE_SHADOW_CELL
		var chunks := _refine_shadow_chunks(coarse, dense_cell_size)
		if chunks.size() >= sources.size():
			# The old 8m dense partition can still save calls when 6m cannot.
			# Reuse the exact coarse triangles; only the centroid grid changes.
			var baseline := _refine_shadow_chunks(coarse, BASELINE_DENSE_SHADOW_CELL)
			if baseline.size() >= sources.size():
				unprofitable_groups += 1
				continue
			chunks = baseline
			dense_cell_size = BASELINE_DENSE_SHADOW_CELL
			dense8_fallback_groups += 1
		if dense_cell_size == DENSE_SHADOW_CELL:
			for chunk: Dictionary in chunks:
				if float(chunk["cell_size"]) == DENSE_SHADOW_CELL:
					dense6_groups += 1
					break
		var modes: Array = []
		var meshes: Array = []
		var transforms: Array = []
		for part: MeshInstance3D in sources:
			modes.append(part.cast_shadow)
			meshes.append(part.mesh)
			transforms.append(_relative(world_root, part))
		var source: MeshInstance3D = sources[0]
		var cull := _cull(source.get_active_material(0) as ShaderMaterial)
		if not materials.has(cull):
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.cull_mode = cull
			materials[cull] = mat
		var proxies: Array[MeshInstance3D] = []
		for chunk: Dictionary in chunks:
			var cell: Vector2i = chunk["cell"]
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(chunk["v"])
			arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(chunk["n"])
			var mesh := ArrayMesh.new()
			# No vertex changes or compression: only whole triangles are partitioned.
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {}, 0)
			var proxy := MeshInstance3D.new()
			proxy.name = "static-shadow-%d-%d.%d-%dm" % [(state["records"] as Array).size(), cell.x, cell.y, int(chunk["cell_size"])]
			proxy.mesh = mesh
			proxy.material_override = materials[cull]
			proxy.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
			proxy.layers = source.layers
			var padding := _range_padding(world_root, sources, mesh.get_aabb().get_center())
			proxy.visibility_range_begin = maxf(0.0, source.visibility_range_begin - padding)
			proxy.visibility_range_end = source.visibility_range_end + padding if source.visibility_range_end > 0.0 else 0.0
			proxy.set_meta("shadow_range_padding", padding)
			proxy.set_meta("source_visibility_range_end", source.visibility_range_end)
			proxy.visibility_range_begin_margin = source.visibility_range_begin_margin
			proxy.visibility_range_end_margin = source.visibility_range_end_margin
			proxy.visibility_range_fade_mode = source.visibility_range_fade_mode
			proxy.visible = false
			proxy.set_meta("static_shadow_proxy", true)
			proxy.set_meta("shadow_sources", sources)
			proxy.set_meta("shadow_cell", cell)
			proxy.set_meta("shadow_cell_size", chunk["cell_size"])
			proxy.set_meta("shadow_dense_cell_size", dense_cell_size)
			world_root.add_child(proxy)
			proxies.append(proxy)
			proxy_count += 1
			triangle_count += arrays[Mesh.ARRAY_VERTEX].size() / 3
		# Invalidation is atomic for every partition of a source group. Restoring
		# one source while its other partitions remain active would double its shadow.
		var record := {"world": world_root, "proxies": proxies, "sources": sources, "modes": modes,
			"meshes": meshes, "transforms": transforms, "attributes": _attributes(source),
			"dense_cell_size": dense_cell_size, "disabled": false, "retired": false}
		(state["records"] as Array).append(record)
		# Callable hashing must not depend on a Dictionary that can be invalidated.
		var callback_state := CallbackState.new(record)
		(state["callback_states"] as Array).append(callback_state)
		for part: MeshInstance3D in sources:
			var visibility_callback := callback_state.visibility_changed.bind(part)
			var exit_callback := callback_state.tree_exiting
			part.visibility_changed.connect(visibility_callback)
			part.tree_exiting.connect(exit_callback)
			# Store outside the bound record to avoid a Callable/Dictionary cycle.
			(state["connections"] as Array).append({"source": part, "signal": &"visibility_changed", "callable": visibility_callback})
			(state["connections"] as Array).append({"source": part, "signal": &"tree_exiting", "callable": exit_callback})
		source_count += sources.size()
	state["stats"]["sources"] = source_count
	state["stats"]["proxies"] = proxy_count
	state["stats"]["triangles"] = triangle_count
	state["stats"]["saved"] = source_count - proxy_count
	state["stats"]["dense6_groups"] = dense6_groups
	state["stats"]["dense8_fallback_groups"] = dense8_fallback_groups
	state["stats"]["unprofitable_groups"] = unprofitable_groups


static func _shadow_chunks(world_root: Node3D, sources: Array) -> Array[Dictionary]:
	return _refine_shadow_chunks(_shadow_coarse_chunks(world_root, sources), DENSE_SHADOW_CELL)


static func _shadow_coarse_chunks(world_root: Node3D, sources: Array) -> Dictionary:
	var chunks: Dictionary = {}
	for source: MeshInstance3D in sources:
		var pose := _relative(world_root, source)
		var normal_basis := pose.basis.inverse().transposed()
		var arrays := source.mesh.surface_get_arrays(0)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else points.size()
		for first in range(0, count, 3):
			var tri: Array[Vector3] = []
			var centre := Vector3.ZERO
			for offset in 3:
				var index := indices[first + offset] if not indices.is_empty() else first + offset
				var point := pose * points[index]
				tri.append(point)
				centre += point
			centre /= 3.0
			var cell := Vector2i(floori((centre.x + WorldBuilder.CHUNK_ORIGIN_X) / SHADOW_CELL),
				floori((centre.z + WorldBuilder.CHUNK_ORIGIN_Z) / SHADOW_CELL))
			if not chunks.has(cell):
				chunks[cell] = {"v": [], "n": []}
			var chunk: Dictionary = chunks[cell]
			for offset in 3:
				var index := indices[first + offset] if not indices.is_empty() else first + offset
				(chunk["v"] as Array).append(tri[offset])
				(chunk["n"] as Array).append(normals[index] if pose.basis == Basis.IDENTITY else (normal_basis * normals[index]).normalized())
	return chunks


static func _refine_shadow_chunks(chunks: Dictionary, dense_cell_size := DENSE_SHADOW_CELL) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for cell: Vector2i in chunks:
		var chunk: Dictionary = chunks[cell]
		var vertices: Array = chunk["v"]
		if vertices.size() / 3 <= DENSE_SHADOW_TRIANGLES:
			chunk["cell"] = cell
			chunk["cell_size"] = SHADOW_CELL
			result.append(chunk)
			continue
		# A handful of dense house cells benefit from 6m culling. Refining only
		# these cells keeps the open-street draw-call budget unchanged elsewhere.
		var fine: Dictionary = {}
		for first in range(0, vertices.size(), 3):
			var centre: Vector3 = (vertices[first] + vertices[first + 1] + vertices[first + 2]) / 3.0
			var subcell := Vector2i(floori((centre.x + WorldBuilder.CHUNK_ORIGIN_X) / dense_cell_size),
				floori((centre.z + WorldBuilder.CHUNK_ORIGIN_Z) / dense_cell_size))
			if not fine.has(subcell):
				fine[subcell] = {"v": [], "n": [], "cell": subcell, "cell_size": dense_cell_size}
			var part: Dictionary = fine[subcell]
			for offset in 3:
				(part["v"] as Array).append(vertices[first + offset])
				(part["n"] as Array).append((chunk["n"] as Array)[first + offset])
		for part: Dictionary in fine.values():
			result.append(part)
	return result

static func set_hq(world_root: Node3D, enabled: bool) -> void:
	var state: Dictionary = world_root.get_meta(META, {})
	if state.is_empty():
		return
	state["hq"] = enabled
	for record: Dictionary in state["records"]:
		if not bool(record["disabled"]) and not _intact(record):
			_invalidate(record)
		var active := enabled and not bool(record["disabled"])
		for proxy: Variant in record["proxies"]:
			if is_instance_valid(proxy):
				proxy.visible = active
		var sources: Array = record["sources"]
		for i in sources.size():
			if is_instance_valid(sources[i]):
				_set_shadow_mode(sources[i], GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if active else int(record["modes"][i]))

static func _source_visibility_changed(record: Dictionary, source: MeshInstance3D) -> void:
	# World visibility affects proxies equally. A nested owner hide does not.
	if bool(record.get("retired", false)) or bool(record["disabled"]):
		return
	if _visible_below_world(source, record["world"]):
		return
	_invalidate(record)

static func _invalidate(record: Dictionary) -> void:
	if bool(record.get("retired", false)):
		return
	record["disabled"] = true
	for proxy: Variant in record["proxies"]:
		if is_instance_valid(proxy):
			proxy.visible = false
	_restore(record)

static func _restore(record: Dictionary) -> void:
	var sources: Array = record["sources"]
	for i in sources.size():
		if is_instance_valid(sources[i]):
			_set_shadow_mode(sources[i], int(record["modes"][i]))

static func _set_shadow_mode(source: MeshInstance3D, mode: int) -> void:
	source.cast_shadow = mode
	# Owner replacement leaves visible walls in a child of the hidden source.
	# It inherited OFF while the old proxy was active, so restore it as well.
	if source.has_meta("environment_residual"):
		var residual: MeshInstance3D = source.get_meta("environment_residual")
		if is_instance_valid(residual): residual.cast_shadow = mode

static func _attributes(source: MeshInstance3D) -> Array:
	return [source.layers, _cull(source.get_active_material(0) as ShaderMaterial),
		source.visibility_range_begin, source.visibility_range_end,
		source.visibility_range_begin_margin, source.visibility_range_end_margin, source.visibility_range_fade_mode]

static func _intact(record: Dictionary) -> bool:
	var world: Node3D = record["world"]
	var sources: Array = record["sources"]
	for i in sources.size():
		if not is_instance_valid(sources[i]):
			return false
		var source: MeshInstance3D = sources[i]
		if source.mesh != record["meshes"][i] or not _eligible(source, world, false):
			return false
		if _relative(world, source) != record["transforms"][i] or _attributes(source) != record["attributes"]:
			return false
	return true

static func _range_padding(world_root: Node3D, sources: Array, centre: Vector3) -> float:
	var basis := world_root.global_basis if world_root.is_inside_tree() else world_root.basis
	var padding := 0.0
	for source: MeshInstance3D in sources:
		var source_centre := _relative(world_root, source) * source.get_aabb().get_center()
		padding = maxf(padding, (basis * (source_centre - centre)).length())
	return padding

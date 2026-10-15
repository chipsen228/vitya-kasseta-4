## Три готовые геометрии в одном draw node. Дистанция измеряется в метрах.
class_name ForestLodMesh
extends MeshInstance3D

const SWITCH_DISTANCE := 20.0
const BACKGROUND_DISTANCE := 35.0
var near_mesh: ArrayMesh
var far_mesh: ArrayMesh
var background_mesh: ArrayMesh
var anchors: Dictionary = {}
var near_ranges: Dictionary = {}
var far_ranges: Dictionary = {}
var background_ranges: Dictionary = {}
var far_active := false
var far_ids: Dictionary = {}
var background_ids: Dictionary = {}
var _elapsed := 0.0
var _near_arrays: Array = []
var _far_arrays: Array = []
var _background_arrays: Array = []
var _mixed_cache: Dictionary = {}
var _mixed_order: Array[String] = []
const MIXED_CACHE_LIMIT := 2
var _input_cached := false
var _input_camera: Vector3
var _input_transform: Transform3D
var _input_anchors: Dictionary = {}
var _input_far_ids: Dictionary = {}
var _input_background_ids: Dictionary = {}
var _input_revision := 0
var _cached_revision := -1
var _camera_evaluations := 0
var _same_input_hits := 0
# Lifetime counters; timestamps are read only when a mixed mesh is built.
var _mixed_builds := 0
var _last_build_usec := 0
var _max_build_usec := 0
var _total_build_usec := 0

func configure(low: ArrayMesh, positions: Dictionary, high_parts: Dictionary, low_parts: Dictionary,
		background: ArrayMesh = null, background_parts: Dictionary = {}) -> void:
	_invalidate_camera_inputs()
	near_mesh = mesh
	far_mesh = low
	background_mesh = background if background != null else low
	anchors = positions.duplicate()
	near_ranges = high_parts.duplicate(true)
	far_ranges = low_parts.duplicate(true)
	background_ranges = background_parts.duplicate(true) if not background_parts.is_empty() else far_ranges.duplicate(true)
	far_ids.clear()
	background_ids.clear()
	far_active = false
	_near_arrays = near_mesh.surface_get_arrays(0)
	_far_arrays = far_mesh.surface_get_arrays(0)
	_background_arrays = background_mesh.surface_get_arrays(0)
	_mixed_cache.clear()
	_mixed_order.clear()
	_elapsed = float(absi(String(name).hash())%120)/1000.0
	custom_aabb = near_mesh.get_aabb().merge(far_mesh.get_aabb())
	set_meta("forest_lod", {"near_triangles": near_mesh.get_faces().size()/3,
		"far_triangles": far_mesh.get_faces().size()/3,"background_triangles": background_mesh.get_faces().size()/3,
		"distance_m": SWITCH_DISTANCE,"background_distance_m":BACKGROUND_DISTANCE})

func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.12 or layers == 0:
		return
	_elapsed = 0.0
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		update_for_camera(camera.global_position)

func update_for_camera(position_world: Vector3) -> void:
	if near_mesh == null or far_mesh == null or anchors.is_empty() or layers == 0:
		return
	var transform_now := global_transform
	# Public dictionaries can be edited directly. Keep independent snapshots and
	# compare their complete contents; no hash collision or movement tolerance.
	if _input_cached and _cached_revision == _input_revision \
			and position_world == _input_camera and transform_now == _input_transform \
			and anchors == _input_anchors and far_ids == _input_far_ids \
			and background_ids == _input_background_ids:
		_same_input_hits += 1
		return
	_camera_evaluations += 1
	var selected: Dictionary = {}
	var background_selected: Dictionary = {}
	for id: String in anchors:
		var anchor: Vector3 = anchors[id]
		var point := transform_now*anchor
		var distance := Vector2(point.x,point.z).distance_to(Vector2(position_world.x,position_world.z))
		if distance > SWITCH_DISTANCE+1.0 or (far_ids.has(id) and distance >= SWITCH_DISTANCE-1.0):
			selected[id] = true
		if distance > BACKGROUND_DISTANCE+1.0 or (background_ids.has(id) and distance >= BACKGROUND_DISTANCE-1.0):
			background_selected[id] = true
	if selected != far_ids or background_selected != background_ids:
		_select_geometry(selected,background_selected)
	_input_camera = position_world
	_input_transform = transform_now
	if anchors != _input_anchors: _input_anchors = anchors.duplicate()
	if far_ids != _input_far_ids: _input_far_ids = far_ids.duplicate()
	if background_ids != _input_background_ids: _input_background_ids = background_ids.duplicate()
	_cached_revision = _input_revision
	_input_cached = true

func select_far(on: bool) -> void:
	_invalidate_camera_inputs()
	if near_mesh == null or far_mesh == null:
		return
	var selected: Dictionary = {}
	if on:
		for id: String in anchors: selected[id] = true
	_select_geometry(selected)

func _select_geometry(selected: Dictionary,background_selected: Dictionary = {}) -> void:
	_invalidate_camera_inputs()
	far_ids = selected
	background_ids = background_selected
	far_active = far_ids.size() == anchors.size()
	set_meta("forest_lod_far_ids",far_ids.keys())
	set_meta("forest_lod_background_ids",background_ids.keys())
	if far_ids.is_empty():
		mesh = near_mesh
		return
	if background_ids.size()==anchors.size():
		mesh = background_mesh
		return
	if far_active and background_ids.is_empty():
		mesh = far_mesh
		return
	# Близкое дерево не удерживает соседние дальние экземпляры в high.
	# Готовые диапазоны собираются лишь при изменении набора, в тот же draw node.
	var mask := ""
	for id: String in anchors: mask += "2" if background_ids.has(id) else "1" if far_ids.has(id) else "0"
	if _mixed_cache.has(mask):
		mesh = _mixed_cache[mask]
		return
	var started := Time.get_ticks_usec()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	for id: String in anchors:
		var arrays: Array = _background_arrays if background_ids.has(id) else _far_arrays if far_ids.has(id) else _near_arrays
		var parts: Dictionary = background_ranges if background_ids.has(id) else far_ranges if far_ids.has(id) else near_ranges
		for span: Vector2i in parts[id]:
			vertices.append_array((arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).slice(span.x,span.x+span.y))
			normals.append_array((arrays[Mesh.ARRAY_NORMAL] as PackedVector3Array).slice(span.x,span.x+span.y))
			uvs.append_array((arrays[Mesh.ARRAY_TEX_UV] as PackedVector2Array).slice(span.x,span.x+span.y))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	var mixed := ArrayMesh.new()
	mixed.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	_mixed_cache[mask] = mixed
	_mixed_order.append(mask)
	while _mixed_order.size()>MIXED_CACHE_LIMIT:
		_mixed_cache.erase(_mixed_order.pop_front())
	mesh = mixed
	_mixed_builds += 1
	_last_build_usec = Time.get_ticks_usec()-started
	_total_build_usec += _last_build_usec
	_max_build_usec = maxi(_max_build_usec,_last_build_usec)

func _invalidate_camera_inputs() -> void:
	_input_revision += 1
	_input_cached = false

func prepare_skin() -> void:
	select_far(false)

## SkinLayer удаляет целые экземпляры деревьев; остаток получает тот же LOD.
func configure_residual(target: ForestLodMesh, hidden: Dictionary) -> void:
	var keep := PackedInt32Array()
	var positions: Dictionary = {}
	var low_parts: Dictionary = {}
	var high_parts: Dictionary = {}
	var remap: Dictionary = {}
	var next_index := 0
	for index in near_mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size():
		if not hidden.has(index):
			remap[index] = next_index
			next_index += 1
	for id: String in near_ranges:
		var remains := false
		for span: Vector2i in near_ranges[id]:
			for index in range(span.x,span.x+span.y):
				if not hidden.has(index):
					remains = true
		if not remains:
			continue
		positions[id] = anchors[id]
		var high_spans: Array = []
		for span: Vector2i in near_ranges[id]:
			var start_index := -1
			var count := 0
			for index in range(span.x,span.x+span.y):
				if not remap.has(index): continue
				if start_index < 0: start_index = int(remap[index])
				count += 1
			if count>0: high_spans.append(Vector2i(start_index,count))
		high_parts[id] = high_spans
		var start := keep.size()
		for span: Vector2i in far_ranges[id]:
			for index in range(span.x,span.x+span.y):
				keep.append(index)
		low_parts[id] = [Vector2i(start,keep.size()-start)]
	if keep.is_empty() or target.mesh == null:
		return
	var source_arrays := far_mesh.surface_get_arrays(0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	for channel in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL,Mesh.ARRAY_TEX_UV]:
		var original: Variant = source_arrays[channel]
		var selected: Variant = original.duplicate()
		selected.resize(keep.size())
		for i in keep.size():
			selected[i] = original[keep[i]]
		arrays[channel] = selected
	var low := ArrayMesh.new()
	low.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	var bg_data := _subset(background_mesh,background_ranges,positions)
	target.configure(low,positions,high_parts,low_parts,bg_data["mesh"],bg_data["ranges"])

static func _subset(source: ArrayMesh,ranges: Dictionary,ids: Dictionary) -> Dictionary:
	var original := source.surface_get_arrays(0)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var parts: Dictionary = {}
	for id: String in ids:
		var start := vertices.size()
		for span: Vector2i in ranges[id]:
			vertices.append_array((original[Mesh.ARRAY_VERTEX] as PackedVector3Array).slice(span.x,span.x+span.y))
			normals.append_array((original[Mesh.ARRAY_NORMAL] as PackedVector3Array).slice(span.x,span.x+span.y))
			uvs.append_array((original[Mesh.ARRAY_TEX_UV] as PackedVector2Array).slice(span.x,span.x+span.y))
		parts[id]=[Vector2i(start,vertices.size()-start)]
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX]=vertices
	arrays[Mesh.ARRAY_NORMAL]=normals
	arrays[Mesh.ARRAY_TEX_UV]=uvs
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return {"mesh":result,"ranges":parts}

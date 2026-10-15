# Скин меняет отрисовку после проверки габарита; коллизия остаётся у мира.
class_name SkinLayer
extends RefCounted

const PATH := "res://data/skin.json"
const CFG_KEY := "skin_enabled"
const CATEGORIES := ["props", "buildings", "scatter", "actors", "ground", "interiors"]
const FIT_TOL := 0.02
const EXTERNAL_ASSETS_ENABLED := false
static var current: SkinLayer = null
var enabled := false
var map: Dictionary = {}
var applied: Array[String] = []
var skipped: Dictionary = {}
var packed_cache: Dictionary = {}
var _mesh_cache: Dictionary = {}
var _material_cache: Dictionary = {}
var _done: Dictionary = {}


static func load_all() -> SkinLayer:
	if current != null:
		return current
	current = SkinLayer.new()
	if not EXTERNAL_ASSETS_ENABLED or not FileAccess.file_exists(PATH):
		return current
	var file := FileAccess.open(PATH, FileAccess.READ)
	if file == null:
		current.skipped[PATH] = "файл недоступен"
		return current
	var raw: Variant = JSON.parse_string(file.get_as_text())
	if raw is Dictionary:
		current._configure(raw)
		var wanted := true
		var config := ConfigFile.new()
		if config.load(Overlays.CFG) == OK:
			wanted = bool(config.get_value(Overlays.CFG_SECTION, CFG_KEY, true))
		for argument: String in OS.get_cmdline_user_args():
			if argument == "--skin=off":
				wanted = false
			elif argument == "--skin=on":
				wanted = true
		current.enabled = current.enabled and wanted
	else:
		current.skipped[PATH] = "ожидался JSON-объект"
	return current


func set_active(world: Node3D, active: bool, props: Props = null,
		mats: Materials = null) -> void:
	if active:
		enabled = true
		apply(world, props, mats)
	for node: Node in _nodes(world):
		if node.has_meta("skin_asset") and node is Node3D:
			(node as Node3D).visible = active
		if node is MeshInstance3D and node.has_meta("skin_original_layers"):
			(node as MeshInstance3D).layers = 0 if active else int(node.get_meta("skin_original_layers"))
			if node.has_meta("skin_residual"):
				var residual: MeshInstance3D = node.get_meta("skin_residual")
				if is_instance_valid(residual):
					residual.visible = active
		if node is MultiMeshInstance3D and node.has_meta("skin_original_multimesh"):
			var multi := node as MultiMeshInstance3D
			multi.multimesh = multi.get_meta("skin_replacement_multimesh") if active \
				else multi.get_meta("skin_original_multimesh")
	enabled = active


# Ресурсы теста остаются в памяти и не включают синтетический скин в игре.
static func from_config(config: Dictionary, resources: Dictionary = {}) -> SkinLayer:
	var layer := SkinLayer.new()
	layer.packed_cache = resources.duplicate()
	layer._configure(config)
	return layer


func _configure(config: Dictionary) -> void:
	enabled = bool(config.get("enabled", true))
	var assets: Variant = config.get("assets", {})
	if not assets is Dictionary:
		skipped["assets"] = "ожидался словарь ключ → описание"
		return
	for raw_key: Variant in assets:
		var key := String(raw_key)
		var parts := key.split("/")
		if parts.size() < 2 or not parts[0] in CATEGORIES:
			skipped[key] = "неизвестная категория"
			continue
		var category := String(parts[0])
		var expected := 3 if category in ["buildings", "interiors"] else 2
		if parts.size() != expected or parts.has(""):
			skipped[key] = "ключ не соответствует категории"
			continue
		if not assets[raw_key] is Dictionary:
			skipped[key] = "описание должно быть объектом"
			continue
		var value: Dictionary = assets[raw_key]
		if String(value.get("category", category)) != category:
			skipped[key] = "category расходится с префиксом ключа"
			continue
		map[key] = value.duplicate()


func entry(key: String) -> Dictionary:
	return map.get(key, {}) if enabled else {}


func apply(world: Node3D, props: Props = null, mats: Materials = null) -> int:
	if not enabled or map.is_empty():
		return 0
	var before := applied.size()
	if props != null:
		apply_props(props)
	if mats != null:
		for key: String in map:
			if key.begins_with("ground/") and not _done.has(key):
				if mats.apply_ground_skin(key.trim_prefix("ground/"), map[key]):
					applied.append(key)
					_done[key] = true
				else:
					skipped[key] = mats.ground_skin_error
	if world != null:
		apply_world(world)
	return applied.size() - before


func apply_props(props: Props) -> int:
	if not enabled or props == null:
		return 0
	var before := applied.size()
	var registry: Dictionary = {}
	for id: Variant in props.notes:
		var note: Dictionary = props.notes[id]
		var definition: Dictionary = note.get("def", {})
		var model_name := String(definition.get("m", definition.get("make", "")))
		var holder := props.get_prop(String(id))
		if holder != null:
			registry[holder] = _prop_key(model_name)

	# notes хранит только интерактивные id. У безымянных GLB исходная
	# shared Mesh-сигнатура надёжнее имени, которое Godot меняет при дублях.
	var signatures: Dictionary = {}
	for model_name: String in props._cache:
		var scene: Node3D = props._cache[model_name].get("scene")
		if scene == null:
			continue
		var meshes := _prop_mesh_ids(scene)
		if meshes.is_empty():
			continue
		meshes.sort()
		var signature := var_to_str(meshes)
		if not signatures.has(signature):
			signatures[signature] = []
		(signatures[signature] as Array).append(model_name)
	var definitions: Array = []
	var pdata := GameData.props()
	definitions.append_array(pdata.get("PROPS", []))
	definitions.append_array(pdata.get("DYNAMIC_PROPS", []))
	if props.root != null:
		for child: Node in props.root.get_children():
			if not child is Node3D or registry.has(child):
				continue
			var holder := child as Node3D
			var meshes := _prop_mesh_ids(holder)
			meshes.sort()
			var candidates: Array = signatures.get(var_to_str(meshes), [])
			var model_name := String(candidates[0]) if candidates.size() == 1 else \
				_prop_definition_name(holder, candidates, definitions)
			if not model_name.is_empty():
				registry[holder] = _prop_key(model_name)
			else:
				for candidate: String in candidates:
					var key := _prop_key(candidate)
					if not entry(key).is_empty():
						skipped[key] = "неоднозначный экземпляр props: " + String(holder.name)
	# Реестр снимаем до подмен: новые дочерние skin-меши не участвуют в поиске.
	for holder: Node3D in registry:
		var key: String = registry[holder]
		if not entry(key).is_empty():
			if key == "props/farm-windmill":
				var blades: Array[NodePath] = []
				for child: Node in _nodes(holder):
					var label := String(child.name).to_lower()
					if label == "storybladepivot" or (label.contains("blades") and label.contains("cylinder")):
						blades.append(holder.get_path_to(child))
				if not blades.is_empty():
					holder.set_meta("skin_dynamic_children", blades)
					holder.set_meta("skin_unavailable_reason",
						"лопасти мельницы вращаются отдельно и требуют собственного скина")
			apply_node(key, holder)
	return applied.size() - before


# Аудит называет процедурные модели props/make-<make>, а старые скины уже
# используют props/<m>. Точный ключ остаётся главным, алиас нужен лишь для make.
func _prop_key(model_name: String) -> String:
	var exact := "props/" + model_name
	if not entry(exact).is_empty():
		return exact
	var procedural := "props/make-" + model_name
	return procedural if not entry(procedural).is_empty() else exact


static func _prop_mesh_ids(node: Node) -> Array[int]:
	var ids: Array[int] = []
	if node.has_meta("skin_asset"):
		return ids
	if node is MeshInstance3D and node.mesh != null:
		ids.append(node.mesh.get_instance_id())
	for child: Node in node.get_children():
		ids.append_array(_prop_mesh_ids(child))
	return ids


static func _prop_definition_name(holder: Node3D, candidates: Array,
		definitions: Array) -> String:
	if candidates.has(String(holder.name)):
		return String(holder.name)
	var matches: Dictionary = {}
	for definition: Dictionary in definitions:
		if definition.has("id"):
			continue
		var model_name := String(definition.get("m", definition.get("make", "")))
		if not candidates.is_empty() and not candidates.has(model_name):
			continue
		# У процедурных applePile/paper нет shared mesh; их определяем по
		# исходному месту и повороту, не затрагивая декор вне props.root.
		if candidates.is_empty() and not definition.has("make"):
			continue
		var at: Array = definition.get("at", [])
		if at.size() != 3:
			continue
		var position := Vector3(float(at[0]), float(at[1]), float(at[2]))
		var basis := Props._euler_xyz(float(definition.get("rx", 0.0)),
			float(definition.get("ry", 0.0)), float(definition.get("rz", 0.0)))
		if holder.position.is_equal_approx(position) and holder.basis.is_equal_approx(basis):
			matches[model_name] = true
	return String(matches.keys()[0]) if matches.size() == 1 else ""


func apply_world(world: Node3D) -> int:
	if not enabled:
		return 0
	var before := applied.size()
	var groups: Dictionary = {}
	var batches: Dictionary = {}
	var trees: Dictionary = {}
	for node: Node in _nodes(world):
		if node is MeshInstance3D and node.has_meta("skin_tree_parts"):
			for instance_id: String in node.get_meta("skin_tree_parts"):
				var part: Dictionary = node.get_meta("skin_tree_parts")[instance_id]
				var key := String(part["key"])
				if entry(key).is_empty():
					continue
				if not trees.has(instance_id):
					trees[instance_id] = {"key": key, "sources": [], "ranges": {}, "transform": part["transform"]}
				trees[instance_id]["sources"].append(node)
				trees[instance_id]["ranges"][node] = part["ranges"]
		if node is MeshInstance3D and node.has_meta("skin_parts"):
			for key: String in node.get_meta("skin_parts"):
				if not entry(key).is_empty():
					if not batches.has(key):
						batches[key] = []
					batches[key].append(node)
		if node.has_meta("skin_unavailable_reason"):
			for key: Variant in node.get_meta("skin_keys", []):
				if not entry(String(key)).is_empty():
					skipped[String(key)] = String(node.get_meta("skin_unavailable_reason"))
		var key := String(node.get_meta("skin_key", ""))
		if entry(key).is_empty():
			continue
		if node is MultiMeshInstance3D and key.begins_with("scatter/"):
			apply_multimesh(key, node)
			continue
		if not node is Node3D or not key.get_slice("/", 0) in ["buildings", "interiors"]:
			continue
		var holder := node as Node3D
		if node.has_meta("skin_owner"):
			holder = node.get_node_or_null(NodePath(node.get_meta("skin_owner"))) as Node3D
		if holder == null:
			skipped[key] = "skin_owner не найден"
			continue
		var group_id := "%s@%s" % [key, holder.get_instance_id()]
		if not groups.has(group_id):
			groups[group_id] = {"key": key, "holder": holder, "sources": []}
		var sources: Array = groups[group_id]["sources"]
		for mi: MeshInstance3D in PropsSkin._meshes(node):
			if not sources.has(mi):
				sources.append(mi)
	for group: Dictionary in groups.values():
		apply_node(group["key"], group["holder"], group["sources"])
	for key: String in batches:
		_apply_batch(key, world, batches[key])
	for instance_id: String in trees:
		var tree: Dictionary = trees[instance_id]
		var transform: Transform3D = tree["transform"]
		_apply_batch(tree["key"], world, tree["sources"], tree["ranges"],
			"tree:" + instance_id, transform)
	return applied.size() - before


func apply_actor(who: String, fig: Node3D, rig: Dictionary = {}) -> Node3D:
	return apply_node("actors/" + who, fig, [], rig)


func apply_node(key: String, holder: Node3D, sources: Array = [], rig: Dictionary = {}) -> Node3D:
	var description := entry(key)
	var token := "%s@%s" % [key, holder.get_instance_id()]
	if description.is_empty() or _done.has(token):
		return null
	if holder.has_meta("skin_unavailable_reason"):
		skipped[key] = String(holder.get_meta("skin_unavailable_reason"))
		return null
	if sources.is_empty():
		sources = PropsSkin._meshes(holder)
	var model := _prepared_model(key, _bounds(holder, sources), description)
	if model == null:
		return null
	if key.begins_with("actors/"):
		if not description.get("bones", {}) is Dictionary:
			skipped[key] = "bones должен быть объектом"
			model.free()
			return null
		var driver := Actors.SkinBoneDriver.new()
		if not driver.configure(model, rig, description.get("bones", {})):
			skipped[key] = "таблица костей: " + str(driver.issues)
			driver.free()
			model.free()
			return null
		driver.free()
	var original: GeometryInstance3D = sources[0] if not sources.is_empty() else null
	for mi: MeshInstance3D in PropsSkin._meshes(model):
		if original != null:
			_copy_visibility(original, mi, description)
	# layers=0 скрывает собственную геометрию, сохраняя видимость детей,
	# когда сам MeshInstance служит владельцем новой модели.
	for mi: MeshInstance3D in sources:
		mi.set_meta("skin_original_layers", mi.layers)
		mi.layers = 0
	_attach(key, holder, model, token)
	return model


func _attach(key: String, holder: Node3D, model: Node3D, token: String) -> void:
	model.name = "skin" if holder.get_node_or_null("skin") == null else "skin_" + key.replace("/", "_")
	holder.add_child(model)
	model.set_meta("skin_asset", key)
	_done[token] = true
	applied.append(token)


func _prepared_model(key: String, target: AABB, description: Dictionary) -> Node3D:
	var model := _instantiate(key, description)
	if model == null:
		return null
	var reason := _fit(model, target, description)
	if not reason.is_empty():
		skipped[key] = reason
		model.free()
		return null
	_prepare_materials(model)
	return model


# В общих мешах постройки занимают диапазоны неиндексированных треугольников.
# Оригинал сохраняется целиком, остаток получает те же transform и материал.
func _apply_batch(key: String, holder: Node3D, sources: Array,
		part_ranges: Dictionary = {}, suffix := "batch", frame := Transform3D.IDENTITY) -> bool:
	var token := "%s@%s:%s" % [key, suffix, holder.get_instance_id()]
	if _done.has(token):
		return false
	var target := AABB()
	var first := true
	var selected: Dictionary = {}
	for mi: MeshInstance3D in sources:
		if mi is ForestLodMesh:
			(mi as ForestLodMesh).prepare_skin()
		var ranges: Array = part_ranges[mi] if part_ranges.has(mi) else mi.get_meta("skin_parts")[key]
		var indices := _range_indices(ranges)
		var part := _select_vertices(mi.mesh, indices)
		if part == null:
			skipped[key] = "skin_parts не соответствует поверхности 0"
			return false
		selected[mi] = indices
		var box := _vertices_aabb(part, frame.affine_inverse() * PropsSkin._rel(holder, mi))
		target = box if first else target.merge(box)
		first = false
	var description := entry(key)
	var model := _prepared_model(key, target, description)
	if model == null:
		return false
	model.transform = frame * model.transform
	for child: MeshInstance3D in PropsSkin._meshes(model):
		_copy_visibility(sources[0], child, description)
	for mi: MeshInstance3D in sources:
		var hidden: Dictionary = mi.get_meta("skin_hidden_vertices", {}).duplicate()
		for index: int in selected[mi]:
			hidden[index] = true
		var keep := PackedInt32Array()
		var arrays := mi.mesh.surface_get_arrays(0)
		for index in arrays[Mesh.ARRAY_VERTEX].size():
			if not hidden.has(index):
				keep.append(index)
		var residual: MeshInstance3D = mi.get_meta("skin_residual") if mi.has_meta("skin_residual") else null
		if residual == null:
			residual = ForestLodMesh.new() if mi is ForestLodMesh else MeshInstance3D.new()
			residual.name = "skin_residual"
			_copy_visibility(mi, residual, {})
			residual.material_override = mi.material_override
			residual.material_overlay = mi.material_overlay
			mi.add_child(residual)
			mi.set_meta("skin_residual", residual)
		residual.mesh = _select_vertices(mi.mesh, keep) if not keep.is_empty() else null
		if residual.mesh != null:
			residual.set_surface_override_material(0, mi.get_active_material(0))
			if mi is ForestLodMesh and residual is ForestLodMesh:
				(mi as ForestLodMesh).configure_residual(residual,hidden)
		mi.set_meta("skin_hidden_vertices", hidden)
		if not mi.has_meta("skin_original_layers"):
			mi.set_meta("skin_original_layers", mi.layers)
		mi.layers = 0
	_attach(key, holder, model, token)
	return true


static func _vertices_aabb(mesh: Mesh, transform: Transform3D) -> AABB:
	var result := AABB()
	var first := true
	for surface in mesh.get_surface_count():
		var vertices: PackedVector3Array = mesh.surface_get_arrays(surface)[Mesh.ARRAY_VERTEX]
		for vertex: Vector3 in vertices:
			var point := transform * vertex
			result = AABB(point, Vector3.ZERO) if first else result.expand(point)
			first = false
	return result


static func _range_indices(ranges: Array) -> PackedInt32Array:
	var result := PackedInt32Array()
	for span: Vector2i in ranges:
		for index in range(span.x, span.x + span.y):
			result.append(index)
	return result


static func _select_vertices(mesh: Mesh, indices: PackedInt32Array) -> ArrayMesh:
	if mesh == null or mesh.get_surface_count() != 1 or indices.is_empty() or indices.size() % 3 != 0:
		return null
	var arrays := mesh.surface_get_arrays(0)
	var total: int = arrays[Mesh.ARRAY_VERTEX].size()
	if arrays[Mesh.ARRAY_INDEX] != null and not arrays[Mesh.ARRAY_INDEX].is_empty():
		return null
	for index: int in indices:
		if index < 0 or index >= total:
			return null
	for slot in Mesh.ARRAY_MAX:
		var source: Variant = arrays[slot]
		if source == null or source.is_empty():
			continue
		var width: int = source.size() / total
		if width < 1 or width * total != source.size():
			return null
		var values: Variant = source.duplicate()
		values.resize(indices.size() * width)
		for i in indices.size():
			for component in width:
				values[i * width + component] = source[indices[i] * width + component]
		arrays[slot] = values
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	result.surface_set_material(0, mesh.surface_get_material(0))
	return result


func apply_multimesh(key: String, node: MultiMeshInstance3D) -> bool:
	var description := entry(key)
	var token := "%s@%s" % [key, node.get_instance_id()]
	if description.is_empty() or _done.has(token) or node.multimesh == null or node.multimesh.mesh == null:
		return false
	var group := _scatter_group(key, node)
	if group.is_empty():
		return false
	var explicit := description.has("pieces")
	var pieces: Variant = description.get("pieces")
	if explicit:
		if not pieces is Array or pieces.size() != group.size():
			skipped[key] = "pieces должен содержать %d описаний" % group.size()
			return false
		for piece: Variant in pieces:
			if not piece is Dictionary:
				skipped[key] = "элемент pieces должен быть объектом"
				return false
	elif group.size() > 1:
		var reason := _scatter_collapse_error(group)
		if not reason.is_empty():
			skipped[key] = reason
			return false

	var replacements: Array[Mesh] = []
	var descriptions: Array[Dictionary] = []
	if explicit:
		for index in group.size():
			var member: MultiMeshInstance3D = group[index]
			var part_description := description.merged(pieces[index], true)
			var replacement := _scatter_mesh(key, member.multimesh.mesh.get_aabb(), part_description)
			if replacement == null:
				return false
			replacements.append(replacement)
			descriptions.append(part_description)
	else:
		var target := AABB()
		var first := true
		for member: MultiMeshInstance3D in group:
			var local: Transform3D = member.get_meta("skin_piece_transform", Transform3D.IDENTITY)
			var box: AABB = local * member.multimesh.mesh.get_aabb()
			target = box if first else target.merge(box)
			first = false
		var primary_local: Transform3D = group[0].get_meta("skin_piece_transform", Transform3D.IDENTITY)
		if is_zero_approx(primary_local.basis.determinant()):
			skipped[key] = "вырожденный skin_piece_transform"
			return false
		var replacement := _scatter_mesh(key, target, description, primary_local.affine_inverse())
		if replacement == null:
			return false
		replacements.append(replacement)
		descriptions.append(description)
		for _index in range(1, group.size()):
			# Узлы и buffers остаются: полная модель уже находится в первой части.
			replacements.append(ArrayMesh.new())
			descriptions.append(description)

	# До этой точки группа не менялась: плохая поздняя часть не оставляет
	# половину исходного дерева и половину новой модели в одной раскладке.
	var prepared: Array[MultiMesh] = []
	for index in group.size():
		prepared.append(_scatter_duplicate(group[index].multimesh, replacements[index]))
	if not explicit and group.size() > 1:
		_scatter_custom_aabb(prepared[0], group)
	for index in group.size():
		var member: MultiMeshInstance3D = group[index]
		member.set_meta("skin_original_multimesh", member.multimesh)
		member.set_meta("skin_replacement_multimesh", prepared[index])
		member.multimesh = prepared[index]
		_apply_lod(member, descriptions[index])
		var member_token := "%s@%s" % [key, member.get_instance_id()]
		_done[member_token] = true
		applied.append(member_token)
	return true


func _scatter_group(key: String, node: MultiMeshInstance3D) -> Array[MultiMeshInstance3D]:
	var count := int(node.get_meta("skin_piece_count", 1))
	var members: Array[MultiMeshInstance3D] = []
	if count < 1:
		skipped[key] = "skin_piece_count должен быть положительным"
		return members
	if count == 1:
		members.append(node)
		return members
	var group_name := String(node.get_meta("skin_group", ""))
	if group_name.is_empty() or node.get_parent() == null:
		skipped[key] = "нет владельца или skin_group составного scatter"
		return members
	var by_index: Dictionary = {}
	for sibling: Node in node.get_parent().get_children():
		if not sibling is MultiMeshInstance3D or String(sibling.get_meta("skin_group", "")) != group_name:
			continue
		var member := sibling as MultiMeshInstance3D
		var index := int(member.get_meta("skin_piece_index", -1))
		if String(member.get_meta("skin_key", "")) != key \
			or int(member.get_meta("skin_piece_count", 1)) != count \
			or index < 0 or index >= count or by_index.has(index) \
			or member.multimesh == null or member.multimesh.mesh == null:
			skipped[key] = "неполная или противоречивая группа " + group_name
			return members
		if _done.has("%s@%s" % [key, member.get_instance_id()]):
			skipped[key] = "группа уже частично заменена: " + group_name
			return members
		by_index[index] = member
	if by_index.size() != count:
		skipped[key] = "группа %s: найдено %d из %d частей" % [group_name, by_index.size(), count]
		return members
	for index in count:
		members.append(by_index[index])
	return members


static func _scatter_collapse_error(group: Array[MultiMeshInstance3D]) -> String:
	var primary := group[0]
	var original := primary.multimesh
	if original.transform_format != MultiMesh.TRANSFORM_3D:
		return "составной scatter требует TRANSFORM_3D"
	var primary_local: Transform3D = primary.get_meta("skin_piece_transform", Transform3D.IDENTITY)
	if is_zero_approx(primary_local.basis.determinant()):
		return "вырожденный skin_piece_transform"
	var primary_inverse := primary_local.affine_inverse()
	for member: MultiMeshInstance3D in group:
		var mm := member.multimesh
		var local: Transform3D = member.get_meta("skin_piece_transform", Transform3D.IDENTITY)
		if is_zero_approx(local.basis.determinant()):
			return "вырожденный skin_piece_transform"
		if mm.transform_format != original.transform_format or mm.instance_count != original.instance_count \
			or mm.visible_instance_count != original.visible_instance_count \
			or mm.use_colors != original.use_colors or mm.use_custom_data != original.use_custom_data:
			return "части scatter имеют разные счётчики или instance channels; нужны explicit pieces"
		if not member.transform.is_equal_approx(primary.transform):
			return "части scatter имеют разные node transforms; нужны explicit pieces"
		for property: String in ["visible", "layers", "cast_shadow", "visibility_range_begin",
			"visibility_range_begin_margin", "visibility_range_end", "visibility_range_end_margin",
			"visibility_range_fade_mode", "extra_cull_margin", "ignore_occlusion_culling",
			"lod_bias", "material_override", "material_overlay", "transparency"]:
			if member.get(property) != primary.get(property):
				return "части scatter имеют разные %s; нужны explicit pieces" % property
		# У Dummy нет instance buffer, а get_instance_transform возвращает
		# identity. Проверка реальных данных доступна GPU-рендереру.
		if original.buffer.is_empty() and mm.buffer.is_empty():
			continue
		var inverse := local.affine_inverse()
		for index in mm.instance_count:
			var base := original.get_instance_transform(index) * primary_inverse
			var here := mm.get_instance_transform(index) * inverse
			if not here.is_equal_approx(base):
				return "части scatter имеют разные logical transforms; нужны explicit pieces"
			if mm.use_colors and not mm.get_instance_color(index).is_equal_approx(original.get_instance_color(index)):
				return "части scatter имеют разные instance colors; нужны explicit pieces"
			if mm.use_custom_data and not mm.get_instance_custom_data(index).is_equal_approx(original.get_instance_custom_data(index)):
				return "части scatter имеют разные instance custom data; нужны explicit pieces"
	return ""


func _scatter_mesh(key: String, target: AABB, description: Dictionary,
	post_transform := Transform3D.IDENTITY) -> Mesh:
	var cache_key := var_to_str(["scatter", description, target, post_transform])
	var cached: Mesh = _mesh_cache.get(cache_key)
	if cached != null:
		return cached
	var model := _prepared_model(key, target, description)
	if model == null:
		return null
	var merged := ArrayMesh.new()
	for mi: MeshInstance3D in PropsSkin._meshes(model):
		if mi.mesh == null:
			continue
		for surface in mi.mesh.get_surface_count():
			var st := SurfaceTool.new()
			st.append_from(mi.mesh, surface, post_transform * model.transform * PropsSkin._rel(model, mi))
			st.set_material(mi.get_active_material(surface))
			st.commit(merged)
	model.free()
	if merged.get_surface_count() == 0:
		skipped[key] = "в модели нет поверхностей"
		return null
	_mesh_cache[cache_key] = merged
	return merged


static func _scatter_duplicate(source: MultiMesh, replacement: Mesh) -> MultiMesh:
	# Resource.duplicate() восстанавливает buffer до цветов/custom data.
	# Порядок здесь сохраняет размер stride и данные всех каналов.
	var result := MultiMesh.new()
	result.transform_format = source.transform_format
	result.use_colors = source.use_colors
	result.use_custom_data = source.use_custom_data
	result.instance_count = source.instance_count
	result.visible_instance_count = source.visible_instance_count
	result.mesh = replacement
	result.custom_aabb = source.custom_aabb
	result.resource_name = source.resource_name
	result.resource_local_to_scene = source.resource_local_to_scene
	for property: Dictionary in source.get_property_list():
		if String(property["name"]) == "physics_interpolation_quality":
			result.set("physics_interpolation_quality", source.get("physics_interpolation_quality"))
	for name: StringName in source.get_meta_list():
		result.set_meta(name, source.get_meta(name))
	var buffer := source.buffer
	# Dummy-рендерер возвращает пустой buffer даже при instance_count > 0.
	if not buffer.is_empty():
		result.buffer = buffer
	return result


static func _scatter_custom_aabb(primary: MultiMesh, group: Array[MultiMeshInstance3D]) -> void:
	var manual := false
	for member: MultiMeshInstance3D in group:
		if member.multimesh.custom_aabb != AABB():
			manual = true
			break
	if not manual:
		return
	# Старый override мог охватывать лишь ствол. После объединения первая
	# часть должна отсекаться вместе с кроной и сохранять прежний запас.
	var bounds := AABB()
	var first := true
	for index in primary.instance_count:
		var box: AABB = primary.get_instance_transform(index) * primary.mesh.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	for member: MultiMeshInstance3D in group:
		var custom := member.multimesh.custom_aabb
		if custom != AABB():
			bounds = custom if first else bounds.merge(custom)
			first = false
	primary.custom_aabb = bounds


func _instantiate(key: String, description: Dictionary) -> Node3D:
	var path := String(description.get("path", ""))
	if path.is_empty():
		skipped[key] = "не задан path"
		return null
	if not packed_cache.has(path):
		if not ResourceLoader.exists(path):
			skipped[key] = "нет файла " + path
			return null
		packed_cache[path] = load(path) as PackedScene
	var packed: PackedScene = packed_cache[path] as PackedScene
	if packed == null:
		skipped[key] = "ресурс не PackedScene: " + path
		return null
	var raw := packed.instantiate()
	if not raw is Node3D:
		skipped[key] = "корень модели не Node3D"
		raw.free()
		return null
	for node: Node in _nodes(raw):
		if node is CollisionObject3D or node is CollisionShape3D or node is CollisionPolygon3D:
			skipped[key] = "модель содержит коллизию"
			raw.free()
			return null
	return raw as Node3D


static func _bounds(holder: Node3D, sources: Array) -> AABB:
	var result := AABB()
	var first := true
	for mi: MeshInstance3D in sources:
		if mi.mesh == null:
			continue
		var box: AABB = PropsSkin._rel(holder, mi) * mi.mesh.get_aabb()
		result = box if first else result.merge(box)
		first = false
	return result


static func _fit(model: Node3D, target: AABB, description: Dictionary) -> String:
	var own := PropsSkin.local_aabb(model)
	if target.size.length() < 0.0001 or own.size.length() < 0.0001:
		return "нулевой AABB"
	var fit := String(description.get("fit", "aabb"))
	if not fit in ["aabb", "none"]:
		return "fit должен быть aabb или none"
	model.rotate_y(float(description.get("ry", 0.0)))
	var rotated: AABB = model.transform * own
	if fit == "aabb":
		var k := INF
		for axis in 3:
			if rotated.size[axis] > 0.0001:
				k = minf(k, target.size[axis] / rotated.size[axis])
			elif target.size[axis] > 0.0001:
				return "плоская модель не заполняет исходный AABB"
		if not is_finite(k) or k <= 0.0:
			return "несовместимые размеры AABB"
		model.transform = model.transform.scaled(Vector3.ONE * k)
		var fitted: AABB = model.transform * own
		model.position += Vector3(target.get_center().x - fitted.get_center().x,
			target.position.y - fitted.position.y, target.get_center().z - fitted.get_center().z)
	var offset: Variant = description.get("offset", [0.0, 0.0, 0.0])
	if not offset is Array or offset.size() != 3:
		return "offset должен содержать три координаты"
	model.position += Vector3(float(offset[0]), float(offset[1]), float(offset[2]))
	var got: AABB = model.transform * own
	for axis in 3:
		var tolerance := maxf(target.size[axis] * FIT_TOL, 0.00001)
		if not is_finite(got.position[axis]) or not is_finite(got.size[axis]):
			return "нечисловой AABB"
		if absf(got.size[axis] - target.size[axis]) > tolerance \
			or got.position[axis] < target.position[axis] - tolerance \
			or got.end[axis] > target.end[axis] + tolerance:
			return "AABB расходится больше чем на 2%% по оси %d" % axis
	return ""


func _prepare_materials(model: Node3D) -> void:
	for mi: MeshInstance3D in PropsSkin._meshes(model):
		if mi.mesh == null:
			continue
		for surface in mi.mesh.get_surface_count():
			var original := mi.get_active_material(surface)
			var id := original.get_instance_id() if original != null else 0
			if not _material_cache.has(id):
				_material_cache[id] = Materials.convert_imported_material(original)
			mi.set_surface_override_material(surface, _material_cache[id])


static func _copy_visibility(source: GeometryInstance3D, target: GeometryInstance3D,
		description: Dictionary) -> void:
	target.layers = int(source.get_meta("skin_original_layers", source.layers))
	target.cast_shadow = source.cast_shadow
	target.visibility_range_begin = source.visibility_range_begin
	target.visibility_range_begin_margin = source.visibility_range_begin_margin
	target.visibility_range_end = source.visibility_range_end
	target.visibility_range_end_margin = source.visibility_range_end_margin
	target.visibility_range_fade_mode = source.visibility_range_fade_mode
	_apply_lod(target, description)


static func _apply_lod(target: GeometryInstance3D, description: Dictionary) -> void:
	var lod: Variant = description.get("lod")
	if lod is float or lod is int:
		target.visibility_range_end = maxf(0.0, float(lod))
	elif lod is Dictionary:
		target.visibility_range_end = maxf(0.0, float(lod.get("end", target.visibility_range_end)))
		target.visibility_range_end_margin = maxf(0.0, float(lod.get("margin", target.visibility_range_end_margin)))


static func _nodes(node: Node) -> Array:
	var result: Array = [node]
	for child: Node in node.get_children():
		result.append_array(_nodes(child))
	return result


func report() -> String:
	var result := "SkinLayer: выключен" if not enabled else "SkinLayer: применено %d, ключей %d" % [applied.size(), map.size()]
	for key: String in skipped:
		result += "\n  пропущен %s: %s" % [key, skipped[key]]
	if enabled:
		for key: String in map:
			var matched := false
			for target: String in applied:
				if target == key or target.begins_with(key + "@"):
					matched = true
					break
			if not matched and not skipped.has(key):
				result += "\n  не применён %s: нет подходящего владельца в текущем проходе" % key
	return result

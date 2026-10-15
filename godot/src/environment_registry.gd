## Видимые оболочки заменяются по владельцам. Физика остаётся у WorldBuilder.
class_name EnvironmentRegistry
extends RefCounted

const PATH := "res://assets/models/environment/manifest.json"
const SOURCE_SELECTION := preload("res://src/skin_layer.gd")
const LOD_SCRIPT := preload("res://src/environment_lod.gd")
static var _mesh_cache: Dictionary = {}
static var _manifest: Dictionary = {}
static var _shared_textures: Dictionary = {}


static func manifest() -> Dictionary:
	if _manifest.is_empty() and FileAccess.file_exists(PATH):
		var raw: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
		if raw is Dictionary:
			_manifest = raw
	return _manifest


static func active() -> bool:
	for argument: String in OS.get_cmdline_user_args():
		if argument == "--environment=off":
			return false
	return bool(manifest().get("enabled", false))


static func apply(world: Node3D, _built: Dictionary, _mats: Materials) -> Dictionary:
	var coverage := {"active": active(), "houses": [], "services": [], "yards": [],
		"removed_triangles": 0, "resources": [], "errors": [], "owner_removals": {}, "objects": [], "textures": []}
	if world.has_meta("environment_applied"):
		return world.get_meta("environment_coverage",coverage)
	if not coverage["active"]:
		return coverage
	var data := manifest()
	var sample := OS.get_cmdline_user_args().has("--environment-sample")
	coverage["sample_mode"] = sample
	coverage["declared_counts"] = {}
	for category: String in ["houses", "services", "yards"]:
		coverage["declared_counts"][category] = data.get(category,[]).size()
	var nodes := SOURCE_SELECTION._nodes(world)
	for category: String in ["houses", "services", "yards"]:
		for row: Dictionary in data.get(category, []):
			var id := String(row["id"])
			if sample and not data.get("samples", []).has(id.trim_prefix("yard-")):
				continue
			var meshes: Array[Mesh] = []
			for path: String in row["paths"]:
				var result := _load_mesh(path)
				if result == null:
					coverage["errors"].append("Отсутствует GLB: " + path)
					break
				meshes.append(result)
			if meshes.size() != 3:
				continue
			var removed := _remove_owner(world, nodes, row)
			coverage["removed_triangles"] += removed
			coverage["owner_removals"][id] = removed
			var instance: MeshInstance3D = LOD_SCRIPT.new()
			instance.name = "environment-" + id
			var at: Array = row["center"]
			instance.position = Vector3(float(at[0]), float(at[1]), float(at[2]))
			instance.set_meta("environment_owner", id)
			instance.set_meta("environment_resources", row["paths"])
			instance.set_meta("environment_source", row.get("owner_keys", []))
			world.add_child(instance)
			instance.call("configure", meshes)
			coverage[category].append(id)
			coverage["resources"].append_array(row["paths"])
			var bounds := meshes[0].get_aabb()
			coverage["objects"].append({"owner": id, "node": str(instance.get_path()), "resources": row["paths"],
				"position": row["center"], "bounds": {"min": [bounds.position.x+at[0],bounds.position.y+at[1],bounds.position.z+at[2]],
				"size": [bounds.size.x,bounds.size.y,bounds.size.z]}, "surfaces": meshes[0].get_surface_count(),
				"removed_source_triangles": removed, "controls": "render_hq; environment LOD 14/32/58; original doors/gates remain owners"})
	for path: String in _shared_textures:
		var texture: Texture2D = _shared_textures[path]
		coverage["textures"].append({"path": path, "instance_id": texture.get_instance_id(), "width": texture.get_width(), "height": texture.get_height()})
	coverage["unique_shared_textures"] = _shared_textures.size()
	coverage["installed_counts"] = {}
	for category: String in ["houses", "services", "yards"]:
		coverage["installed_counts"][category] = coverage[category].size()
	coverage["source_owner_removals"] = world.get_meta("environment_owner_removal_counts",{})
	coverage["render_texture_bytes"] = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
	var retained_script: GDScript = load("res://src/environment_retained.gd")
	coverage["retained_objects"] = retained_script.call("apply",world,_built,_mats)
	coverage["retained_count"] = coverage["retained_objects"].size()
	world.set_meta("environment_applied", true)
	world.set_meta("environment_coverage", coverage)
	for error: String in coverage["errors"]:
		push_error(error)
	return coverage


static func _load_mesh(path: String) -> Mesh:
	if _mesh_cache.has(path):
		return _mesh_cache[path]
	if not ResourceLoader.exists(path):
		return null
	var packed := load(path) as PackedScene
	if packed == null:
		return null
	var model := packed.instantiate() as Node3D
	if model == null:
		return null
	var builders: Dictionary = {}
	var converted_sources: Array[Material] = []
	for node: Node in SOURCE_SELECTION._nodes(model):
		if node is CollisionObject3D or node is CollisionShape3D or node is CollisionPolygon3D:
			model.free()
			return null
		if not node is MeshInstance3D:
			continue
		var mi := node as MeshInstance3D
		for surface in mi.mesh.get_surface_count():
			var source := mi.get_active_material(surface)
			var material := Materials.convert_imported_material(source)
			converted_sources.append(source)
			_share_textures(material, source, path)
			var key := material.get_instance_id()
			if not builders.has(key):
				var st := SurfaceTool.new()
				st.begin(Mesh.PRIMITIVE_TRIANGLES)
				st.set_material(material)
				builders[key] = st
			(builders[key] as SurfaceTool).append_from(mi.mesh, surface, PropsSkin._rel(model, mi))
	var mesh := ArrayMesh.new()
	for key: int in builders:
		(builders[key] as SurfaceTool).commit(mesh)
	model.free()
	# Materials caches by source object. Release these imported sources locally;
	# otherwise all embedded GLB textures remain alive beside the shared atlas.
	for source: Material in converted_sources:
		Materials._imported_materials.erase(source)
	if mesh.get_surface_count() == 0 or mesh.get_faces().is_empty():
		return null
	_mesh_cache[path] = mesh
	return mesh


static func _texture(path: String) -> Texture2D:
	if not _shared_textures.has(path) and ResourceLoader.exists(path):
		_shared_textures[path] = load(path) as Texture2D
	return _shared_textures.get(path)


static func _share_textures(material: Material, source: Material, model_path: String) -> void:
	if not material is ShaderMaterial or not source is BaseMaterial3D:
		return
	var imported := source as BaseMaterial3D
	var shader := material as ShaderMaterial
	var params: Dictionary = shader.get_meta("skin_hq_params", {}).duplicate()
	if imported.albedo_texture != null:
		for field: String in ["albedo", "normal", "roughness"]:
			var suffix: String = {"albedo": "diff", "normal": "nor_gl", "roughness": "orm"}[field]
			var texture := _texture("res://assets/tex/environment/trim-%s.png" % suffix)
			if texture != null:
				params[field+"_tex"] = texture
		params["use_normal"] = true
		params["use_roughness"] = true
		params["roughness_channel"] = Vector4(0,1,0,0)
		# glTF uses a factor of 1 for its ORM metal channel. The custom shader
		# does not read that channel; retaining the factor makes painted wood black.
		params["metallic_value"] = 0.0
		params["use_vertex_color"] = true
	var stem := model_path.get_file().get_basename()
	var id := stem.substr(0,stem.rfind("-lod"))
	var ao := _texture("res://assets/tex/environment/%s-ao.png" % id)
	if ao != null:
		params["ao_tex"] = ao
		params["use_ao"] = true
		params["ao_on_uv2"] = true
		params["ao_channel"] = Vector4(1,0,0,0)
	shader.set_meta("skin_hq_params", params)
	for field: String in params:
		shader.set_shader_parameter(field,params[field])


static func _remove_owner(world: Node3D, nodes: Array, row: Dictionary) -> int:
	var removed := 0
	var owner_counts: Dictionary = world.get_meta("environment_owner_removal_counts",{}).duplicate()
	for node: Node in nodes:
		if not node is MeshInstance3D or not node.has_meta("skin_parts"):
			continue
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.mesh.get_surface_count() != 1:
			continue
		var parts: Dictionary = mi.get_meta("skin_parts")
		var arrays := mi.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var hidden: Dictionary = mi.get_meta("environment_hidden_vertices", {}).duplicate()
		var before := hidden.size()
		for owner: String in row.get("owner_keys", []):
			if not parts.has(owner):
				continue
			if bool(row.get("preserve_glass", false)) and String(mi.name).contains("glass"):
				continue
			for span: Vector2i in parts[owner]:
				for offset in range(span.x, span.x + span.y, 3):
					var accepted := true
					if String(row.get("removal_mode", "")) == "exterior":
						var centroid := mi.transform * ((vertices[offset] + vertices[offset+1] + vertices[offset+2]) / 3.0)
						var normal := (mi.basis * normals[offset]).normalized()
						accepted = _exterior_triangle(row, owner, centroid, normal)
					if accepted:
						if not hidden.has(offset): owner_counts[owner] = int(owner_counts.get(owner,0))+1
						for i in 3:
							hidden[offset+i] = true
		if hidden.size() == before:
			continue
		removed += (hidden.size() - before) / 3
		var keep := PackedInt32Array()
		for index in vertices.size():
			if not hidden.has(index):
				keep.append(index)
		var residual: MeshInstance3D = mi.get_meta("environment_residual") if mi.has_meta("environment_residual") else null
		if residual == null:
			residual = MeshInstance3D.new()
			residual.name = "environment-residual"
			residual.layers = mi.layers
			residual.cast_shadow = mi.cast_shadow
			residual.visibility_range_end = mi.visibility_range_end
			residual.visibility_range_end_margin = mi.visibility_range_end_margin
			residual.material_override = mi.material_override
			mi.add_child(residual)
			mi.set_meta("environment_residual", residual)
		residual.mesh = SOURCE_SELECTION._select_vertices(mi.mesh, keep) if not keep.is_empty() else null
		mi.set_meta("environment_hidden_vertices", hidden)
		mi.set_meta("environment_original_layers", mi.layers)
		mi.layers = 0
	world.set_meta("environment_owner_removal_counts",owner_counts)
	return removed


static func _exterior_triangle(row: Dictionary, owner: String, point: Vector3, normal: Vector3) -> bool:
	if String(row["id"]) == "vitya":
		if owner.contains("HOUSE-shell"):
			if point.y >= 3.0 and point.x > 2.19:
				if (normal.x > 0.85 and absf(point.x-4.48)<0.03) or (normal.z < -0.85 and absf(point.z-6.52)<0.03) or (normal.z > 0.85 and absf(point.z-16.28)<0.03): return true
			if point.y >= 3.3 and point.z < 9.69 and normal.x < -0.85 and absf(point.x-2.12)<0.03: return true
			if point.y >= 5.9:
				if (normal.x < -0.85 and absf(point.x+5.26)<0.025) or (normal.x > 0.85 and absf(point.x-1.86)<0.025): return true
				if (normal.z < -0.85 and absf(point.z-9.74)<0.025) or (normal.z > 0.85 and absf(point.z-16.06)<0.025): return true
			if point.x >= -2.26 and point.x <= -0.94 and point.z >= 9.19 and point.z <= 9.87:
				if normal.y > 0.85 and point.y > 7.10: return true
				if point.y > 6.17 and ((normal.x < -0.85 and absf(point.x+2.15)<0.025) or (normal.x > 0.85 and absf(point.x+1.05)<0.025) or (normal.z < -0.85 and absf(point.z-9.32)<0.025)): return true
			return false
		if owner.contains("ROOFS-"):
			if normal.y > 0.05:
				return true
			var roof_index := int(owner.get_slice("ROOFS-", 1))
			var roofs: Array = row.get("roof_rows", [])
			if roof_index < roofs.size() and roofs[roof_index].has("ridgeZ"):
				var roof: Dictionary = roofs[roof_index]
				var xs: Array = roof["x"]
				return (normal.x < -0.85 and absf(point.x-float(xs[0])) < 0.12) or (normal.x > 0.85 and absf(point.x-float(xs[1])) < 0.12)
			return false
		if owner.contains("HOUSE-exterior-dressing") or owner.contains("HOUSE-eaves") or owner.contains("HOUSE-balcony") or owner.contains("HOUSE-belts"):
			return true
		for wall: Dictionary in row.get("wall_rows", []):
			if owner != "buildings/site/" + String(wall["id"]):
				continue
			var id := String(wall["id"])
			var direction := Vector3.FORWARD if id.begins_with("w-n") or id.ends_with("-n") else Vector3.BACK if id.begins_with("w-s") else Vector3.LEFT if id.begins_with("w-w") or id.ends_with("-w") else Vector3.RIGHT
			return normal.dot(direction) > 0.85
		return false
	var box: Array = row["footprint"]
	var eave := float(row["eave"])
	if owner.contains("SLABS-"):
		return normal.y > -0.05
	if normal.y > 0.15 and point.y > eave - 0.12 and point.y < float(row.get("ridge",eave))+0.18:
		return true
	if normal.x < -0.85 and absf(point.x-float(box[0])) < 0.16:
		return true
	if normal.x > 0.85 and absf(point.x-float(box[1])) < 0.16:
		return true
	if normal.z < -0.85 and absf(point.z-float(box[2])) < 0.16:
		return true
	return normal.z > 0.85 and absf(point.z-float(box[3])) < 0.16

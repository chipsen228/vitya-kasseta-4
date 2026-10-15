## Read-only record of the actual scene, including ground and vegetation chunks.
extends RefCounted

static func capture(world: Node3D) -> Dictionary:
	var records: Array[Dictionary] = []
	var empty_multimeshes := 0
	var pending: Array[Node] = [world]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		for child: Node in node.get_children(): pending.append(child)
		if not node is GeometryInstance3D: continue
		var geometry := node as GeometryInstance3D
		if geometry.layers == 0 or geometry.has_meta("static_shadow_proxy"): continue
		var mesh: Mesh = null
		var instances := 1
		if node is MeshInstance3D:
			mesh = node.mesh
			if node.has_method("quality_meshes"):
				var levels: Array = node.call("quality_meshes")
				if not levels.is_empty(): mesh = levels[0]
		elif node is MultiMeshInstance3D and node.multimesh != null:
			mesh = node.multimesh.mesh
			instances = node.multimesh.instance_count
			if node.multimesh.visible_instance_count >= 0:
				instances = mini(instances, node.multimesh.visible_instance_count)
			if instances == 0:
				empty_multimeshes += 1
				continue
		if mesh == null: continue
		var local_bounds: AABB = geometry.get_aabb()
		# Dummy rendering does not calculate MultiMesh bounds or retain transform
		# readback. Only an explicit resource AABB can supply bounds in that case.
		if node is MultiMeshInstance3D and local_bounds.size.length_squared() == 0.0:
			local_bounds = node.multimesh.custom_aabb
		if node.has_method("quality_meshes"): local_bounds = mesh.get_aabb()
		var bounds: AABB = world.global_transform.affine_inverse() * geometry.global_transform * local_bounds
		var materials: Array = []
		for surface in mesh.get_surface_count():
			var material: Material = geometry.material_override
			if material == null and node is MeshInstance3D: material = node.get_active_material(surface) if node.mesh == mesh else null
			if material == null: material = mesh.surface_get_material(surface)
			var record := {"surface":surface,"resource":"" if material == null else material.resource_path,
				"class":"" if material == null else material.get_class(),"textures":[]}
			if material is ShaderMaterial:
				record["shader"] = material.shader.resource_path
				for uniform: Dictionary in material.shader.get_shader_uniform_list():
					var value: Variant = material.get_shader_parameter(uniform["name"])
					if value is Texture2D: record["textures"].append({"uniform":uniform["name"],"resource":value.resource_path,"width":value.get_width(),"height":value.get_height()})
			materials.append(record)
		var owner: Variant = geometry.get_meta("environment_owner", str(geometry.get_path()))
		var sources: Array = geometry.get_meta("environment_source", [])
		if sources.is_empty() and geometry.has_meta("skin_parts"): sources = geometry.get_meta("skin_parts").keys()
		if geometry.name == "environment-residual" and geometry.get_parent().has_meta("skin_parts"):
			owner = str(geometry.get_parent().get_path())
			sources = geometry.get_parent().get_meta("skin_parts").keys()
		var shadow_resource := ""
		if geometry is EnvironmentLod and geometry.levels.size() == 3:
			shadow_resource = geometry.levels[1].resource_path
		records.append({"owner":owner,"node":str(geometry.get_path()),"source_owners":sources,
			"mesh_resource":mesh.resource_path,"mesh_class":mesh.get_class(),"instances":instances,
			"surfaces":mesh.get_surface_count(),"materials":materials,
			"bounds":{"min":[bounds.position.x,bounds.position.y,bounds.position.z],"size":[bounds.size.x,bounds.size.y,bounds.size.z]},
			"bounds_available":local_bounds.size.length_squared()>0.0,
			"currently_visible":geometry.is_visible_in_tree(),"cast_shadow":geometry.cast_shadow,
			"medium_shadow_resource":shadow_resource,
			"lod_controller":"" if geometry.get_script() == null else geometry.get_script().resource_path,
			"visibility_end":geometry.visibility_range_end,
			"physics_reference":"after/physics.json; generated visible meshes do not own collision",
			"camera_reference":"coverage-matrix-approved/captures.json and details-final/captures.json"})
	return {"stage":"after quality sweep and complete shader/world-view warmup","render_backend":DisplayServer.get_name(),"objects":records,"count":records.size(),"excluded_empty_multimeshes":empty_multimeshes,"mutations":0}

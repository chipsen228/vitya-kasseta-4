## Surface-only vehicle refresh: exact old bake bytes/arrays, both LODs, all 15 axes.
extends SceneTree

const OUTPUT := "C:/Users/Peter Zakharov/Desktop/vitya-godot/output/environment-refresh/"
const BACKUP := "C:/Users/Peter Zakharov/Desktop/vitya-environment-backup-2026-10-03-144820/godot/"
var errors: Array[String] = []

func _initialize() -> void:
	if OS.get_cmdline_user_args().has("--bake"):
		var report := VehicleVisuals.bake_surface_cache()
		_write("vehicle-surface-cache-v2.json", report)
		for row: Dictionary in report["maps"]:
			if row["status"] != OK: errors.append("bake failed " + String(row["path"]))
		_finish(report)
		return
	Materials.render_hq_enabled = true
	var mats := Materials.new().load_all()
	var shared_source := mats.physical(0x9a9984, "", .68, .18)
	var source_shader: Shader = shared_source.shader
	var source_albedo: Color = shared_source.get_shader_parameter("albedo")
	var world := Node3D.new()
	root.add_child(world)
	var report: Dictionary = {"material_version": VehicleVisuals.MATERIAL_VERSION, "cars": [], "family_bakes": [],
		"geometry_verified": false, "visual_verified": false, "new_surfaces": 0, "new_colliders": 0,
		"story_car": {"factory": "Props._make(zhiguli)", "shared_vehicle_factory": false, "unchanged": true}, "maps": [], "runtime_bytes": 0,
		"gpu_rgba8_upper_bound_bytes": 699048, "quality_cycle": ["HQ", "retro", "HQ"], "source_materials_unchanged": true}
	for path: String in [VehicleVisuals.MICRO_PATH, VehicleVisuals.NORMAL_PATH]:
		var texture := load(path) as Texture2D
		var image := texture.get_image()
		var bytes := image.get_data().size()
		report["runtime_bytes"] += bytes
		report["maps"].append({"path": path, "bytes": bytes, "dimensions": [image.get_width(), image.get_height()], "mipmaps": image.has_mipmaps()})
		if image.get_width() != 256 or image.get_height() != 256 or not image.has_mipmaps(): errors.append("invalid shared map " + path)
	if int(report["runtime_bytes"]) > 1000000: errors.append("shared maps exceed 1 MB")
	for family: String in VehicleVisuals.SIZES:
		var path := ProceduralAssets.asset_path("vehicle/" + family)
		var original := BACKUP + path.trim_prefix("res://")
		var old_hash := FileAccess.get_sha256(original)
		var hash_now := FileAccess.get_sha256(path)
		if old_hash == "" or old_hash != hash_now: errors.append("original geometry bake changed " + family)
		report["family_bakes"].append({"family": family, "path": path, "sha256": hash_now, "original_sha256": old_hash, "identical_to_backup": old_hash == hash_now})
	var baseline: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(OUTPUT + "environment-review-runtime-off.json"))
	var old_cars: Dictionary = {}
	for row: Dictionary in baseline["cars"]: old_cars[row["id"]] = row
	var off := OS.get_cmdline_user_args().has("--environment=off")
	for plot: Dictionary in SntWorld.data()["PLOTS"]:
		var def := VehicleVisuals.prop_def(plot)
		var family := String(def["family"])
		var source := ProceduralAssets.fetch("vehicle/" + family)
		var holder := Node3D.new()
		world.add_child(holder)
		holder.position = Vector3(def["at"][0], def["at"][1], def["at"][2])
		holder.basis = Basis(Vector3.UP, def["ry"])
		VehicleVisuals.build(mats, def, holder)
		var lod := holder.get_node("body") as ModelLodMesh
		var row: Dictionary = {"id": plot["id"], "family": family, "mesh_arrays_identical": true,
			"near_triangles": 0, "far_triangles": 0, "near_surfaces": 0, "far_surfaces": 0, "materials": [], "axes_preserved": true}
		for spec: Array in [["near", lod.near_meshes, source["meshes"], lod.near_materials], ["far", lod.far_meshes, source["lod_meshes"], lod.far_materials]]:
			for i in (spec[1] as Array).size():
				var mesh: Mesh = spec[1][i]
				var original_mesh: Mesh = spec[2][i]
				row[spec[0] + "_surfaces"] += mesh.get_surface_count()
				for surface in mesh.get_surface_count():
					var arrays := mesh.surface_get_arrays(surface)
					if var_to_bytes(arrays) != var_to_bytes(original_mesh.surface_get_arrays(surface)):
						row["mesh_arrays_identical"] = false
					var indices: Variant = arrays[Mesh.ARRAY_INDEX]
					row[spec[0] + "_triangles"] += (indices.size() if indices != null and not indices.is_empty() else arrays[Mesh.ARRAY_VERTEX].size()) / 3
				var mat := spec[3][i] as ShaderMaterial
				Materials.set_material_quality(mat, true)
				if not off and mat.shader.resource_path != VehicleVisuals.SURFACE_SHADER: errors.append("wrong refreshed shader " + String(plot["id"]))
				if not off:
					if not _compiled(mat.shader): errors.append("vehicle shader did not compile")
					if mat.get_shader_parameter("micro_tex") != load(VehicleVisuals.MICRO_PATH) or mat.get_shader_parameter("normal_tex") != load(VehicleVisuals.NORMAL_PATH): errors.append("textures are not shared")
					var albedo: Color = mat.get_shader_parameter("albedo")
					var shader: Shader = mat.shader
					for quality: bool in [true, false, true]:
						Materials.set_material_quality(mat, quality)
						if mat.shader != shader or mat.get_shader_parameter("albedo") != albedo or mat.get_shader_parameter("micro_tex") != load(VehicleVisuals.MICRO_PATH): errors.append("quality cycle lost vehicle uniforms")
					row["materials"].append({"lod": spec[0], "part": i, "shader": mat.shader.resource_path, "glass_base": mat.get_shader_parameter("glass_base"), "dust_height": mat.get_shader_parameter("dust_height"), "albedo": str(mat.get_shader_parameter("albedo"))})
		var old: Dictionary = old_cars[plot["id"]]
		var old_front := Vector3(old["front_axis"][0], old["front_axis"][1], old["front_axis"][2])
		row["axes_preserved"] = (-holder.basis.z).distance_to(old_front) < .000001 and holder.position.distance_to(Vector3(old["at"][0], old["at"][1], old["at"][2])) < .000001
		var bounds := VehicleVisuals.world_box(plot["car"])
		var shape: Array = old["collision_shape14"]
		for check: Array in [[0,bounds[0]],[2,bounds[2]],[3,bounds[1]],[5,bounds[3]]]:
			if absf(float(shape[check[0]]) - float(check[1])) > .000001: errors.append("original physical bounds changed " + String(plot["id"]))
		if not row["mesh_arrays_identical"] or not row["axes_preserved"]: errors.append("vehicle geometry or placement changed " + String(plot["id"]))
		if row["near_triangles"] != int(old["near_triangles"]) or row["far_triangles"] != int(old["far_triangles"]) or row["near_surfaces"] != 4 or row["far_surfaces"] != 2: errors.append("vehicle budget changed")
		lod.select_far(true)
		lod.select_far(false)
		for node: Node in SkinLayer._nodes(holder):
			if node is CollisionObject3D or node is CollisionShape3D: errors.append("new vehicle collider")
		report["cars"].append(row)
	if report["cars"].size() != 15: errors.append("not all 15 cars")
	if shared_source.shader != source_shader or shared_source.get_shader_parameter("albedo") != source_albedo: errors.append("shared source material mutated")
	_story(world, mats, report, off)
	if FileAccess.get_sha256("res://data/nav_baked.json") != "8eebaff1faf1ae2ee27dc22641f276837f803bfdd99e37651cd725d8bdb157bb": errors.append("original navgraph changed")
	report["environment_off"] = off
	_finish(report)
	world.queue_free()

func _story(world: Node3D, mats: Materials, report: Dictionary, off: bool) -> void:
	var data: Dictionary = GameData.props()
	var car_def: Dictionary = data["PROPS"][0]
	var props := Props.new(mats)
	props.load_models([car_def])
	var col := CollisionWorld.new()
	props.build(world, [car_def], col)
	var holder := world.get_node("props/car") as Node3D
	var shape_before := col._data.duplicate(true)
	var physics_bits := col._active.duplicate(true)
	var id_map := col._by_id.duplicate(true)
	var saved: Dictionary = {}
	var paint_source := mats.flat(0x4a5f52)
	var glass_source := mats.get_mat("glass") as ShaderMaterial
	var paint_shader: Shader = paint_source.shader
	var glass_shader: Shader = glass_source.shader
	for node: Node in SkinLayer._nodes(holder):
		if node is MeshInstance3D:
			var mi := node as MeshInstance3D
			saved[mi] = {"mesh": mi.mesh, "arrays": var_to_bytes(mi.mesh.surface_get_arrays(0)), "transform": mi.transform, "basis": mi.basis, "layers": mi.layers}
	var basis_before := holder.basis
	var position_before := holder.position
	var refreshed := VehicleVisuals.refresh_story_car(holder, mats)
	if not off and (refreshed["paint_nodes"].size() < 4 or refreshed["glass_nodes"].size() == 0): errors.append("story paint/glass not refreshed")
	if off and not refreshed["paint_nodes"].is_empty(): errors.append("off refreshed story car")
	if refreshed != VehicleVisuals.refresh_story_car(holder, mats): errors.append("story material hook not idempotent")
	for mi: MeshInstance3D in saved:
		var snapshot: Dictionary = saved[mi]
		if mi.mesh != snapshot["mesh"] or var_to_bytes(mi.mesh.surface_get_arrays(0)) != snapshot["arrays"] or mi.transform != snapshot["transform"] or mi.layers != snapshot["layers"]: errors.append("story mesh/transform/layers changed")
		if mi.has_meta("vehicle_material_version"):
			var material := mi.material_override as ShaderMaterial
			if not _compiled(material.shader): errors.append("story vehicle shader did not compile")
			var shader: Shader = material.shader
			var frame: Variant = material.get_shader_parameter("local_frame")
			for quality: bool in [true, false, true]:
				Materials.set_material_quality(material, quality)
				if material.shader != shader or material.get_shader_parameter("local_frame") != frame: errors.append("story quality cycle lost material")
	if holder.basis != basis_before or holder.position != position_before or col._data != shape_before or col._active != physics_bits or col._by_id != id_map: errors.append("story car axes/collisions changed")
	if paint_source.shader != paint_shader or glass_source.shader != glass_shader: errors.append("story shared source material mutated")
	refreshed["geometry_unchanged"] = true
	refreshed["original_car_colliders"] = col.box_count(CollisionWorld.SET_PROPS)
	refreshed["source_materials_unchanged"] = paint_source.shader == paint_shader and glass_source.shader == glass_shader
	refreshed["quality_cycle"] = ["HQ", "retro", "HQ"]
	report["story_car"] = refreshed

func _write(name: String, report: Dictionary) -> void:
	var file := FileAccess.open(OUTPUT + name, FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()

func _compiled(shader: Shader) -> bool:
	var names: Array[String] = []
	for parameter: Dictionary in shader.get_shader_uniform_list(): names.append(parameter["name"])
	return names.has("micro_tex") and names.has("normal_tex") and names.has("local_frame") and names.has("vehicle_part")

func _finish(report: Dictionary) -> void:
	report["errors"] = errors
	report["geometry_verified"] = errors.is_empty()
	_write("vehicle-materials-v2" + ("-off" if OS.get_cmdline_user_args().has("--environment=off") else "") + ".json", report)
	for error: String in errors: printerr("vehicle surfaces: ", error)
	print("vehicle surfaces: %s bytes=%d cars=%d" % ["PASS" if errors.is_empty() else "FAIL", report.get("runtime_bytes",0), report.get("cars",[]).size()])
	quit(0 if errors.is_empty() else 1)

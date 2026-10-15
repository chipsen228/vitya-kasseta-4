## Standalone GPU equivalence fixture. Run only with explicit --run-gpu.
## Uses genuine imported medium meshes; no Main, physics or production changes.
extends SceneTree

const REGISTRY := preload("res://src/environment_registry.gd")
const LOD := preload("res://src/environment_lod.gd")
const SIZE := 512
const PIXEL_MAX := 1.0 / 255.0
const PIXEL_MEAN := .01 / 255.0
const MIN_SHADOW_IOU := .90
const SHADOW_DELTA := 6.0 / 255.0

var output := "res://../output/environment-refresh/shadow-material-capture"
var owners: Array[String] = ["vitya", "p07", "site-shed", "yard-p07"]
var lights: Array[String] = ["directional", "omni", "spot"]
var failures: Array[String] = []
var records: Array[Dictionary] = []
var merged_records: Array[Dictionary] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--run-gpu") or DisplayServer.get_name() == "headless":
		printerr("test_environment_shadow_material_capture: requires a GPU window and --run-gpu")
		quit(2)
		return
	for arg: String in args:
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
		elif arg.begins_with("--owners="):
			owners.assign(arg.trim_prefix("--owners=").split(",", false))
		elif arg.begins_with("--lights="):
			lights.assign(arg.trim_prefix("--lights=").split(",", false))
	var absolute := ProjectSettings.globalize_path(output)
	_check(DirAccess.make_dir_recursive_absolute(absolute) == OK, "output directory")
	root.size = Vector2i(SIZE, SIZE)
	root.borderless = true
	for id: String in owners:
		var medium: Mesh = REGISTRY._load_mesh("res://assets/models/environment/%s-lod1.glb" % id)
		_check(medium != null, "missing genuine medium " + id)
		if medium == null: continue
		for surface in medium.get_surface_count():
			Materials.set_material_quality(medium.surface_get_material(surface), true)
		var cull := LOD.opaque_shadow_cull(medium)
		_check(cull >= 0, "not opaque HQ " + id)
		if cull < 0: continue
		var before := _signature(medium)
		for kind: String in lights:
			_check(kind in ["directional", "omni", "spot"], "unknown light " + kind)
			if not kind in ["directional", "omni", "spot"]: continue
			await _capture(id, kind, medium, cull, absolute)
		_check(_signature(medium) == before, "source arrays/material IDs changed " + id)
	var report := {
		"gpu_executed": true, "owners": owners, "lights": lights,
		"renderer": RenderingServer.get_video_adapter_name(),
		"tolerances": {"max_channel_error": PIXEL_MAX, "mean_channel_error": PIXEL_MEAN,
			"minimum_independent_floor_shadow_iou": MIN_SHADOW_IOU,
			"shadow_detection_channel_delta": SHADOW_DELTA},
		"oracle": "union of original triangles projected onto the receiver plane along the actual light rays; independent of shadow shader/depth buffers",
		"records": records, "merged_records": merged_records, "failures": failures,
	}
	var file := FileAccess.open(absolute.path_join("report.json"), FileAccess.WRITE)
	_check(file != null, "report file")
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	for failure: String in failures: printerr("test_environment_shadow_material_capture: " + failure)
	print("test_environment_shadow_material_capture: %s cases=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL", records.size(), failures.size()])
	quit(0 if failures.is_empty() else 1)


func _capture(id: String, kind: String, medium: Mesh, cull: int, absolute: String) -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(SIZE, SIZE)
	viewport.own_world_3d = true
	# Diagnostic precision, not a production-quality change: the independent
	# triangle oracle needs enough atlas texels to measure thin original props.
	viewport.positional_shadow_atlas_size = 4096
	viewport.set_positional_shadow_atlas_quadrant_subdiv(0, Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_1)
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)
	var scene := Node3D.new()
	viewport.add_child(scene)
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(.1, .1, .1)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color.WHITE
	environment.ambient_light_energy = .18
	environment.fog_enabled = false
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	scene.add_child(world_environment)
	var bounds := medium.get_aabb()
	var extent := maxf(bounds.size.x, bounds.size.z) * .5 + bounds.size.y * .65 + 2.0
	var caster := MeshInstance3D.new()
	caster.mesh = medium
	caster.position = Vector3(-bounds.get_center().x, .20 - bounds.position.y, -bounds.get_center().z)
	caster.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY
	scene.add_child(caster)
	var receiver := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2.ONE * extent * 2.0
	var white := StandardMaterial3D.new()
	white.albedo_color = Color.WHITE
	white.roughness = 1.0
	plane.material = white
	receiver.mesh = plane
	receiver.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scene.add_child(receiver)
	var camera := Camera3D.new()
	camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	camera.size = extent * 2.0
	camera.near = .05
	camera.far = extent * 10.0
	camera.position = Vector3(0, extent * 3.0, 0)
	scene.add_child(camera)
	camera.look_at(Vector3.ZERO, Vector3.FORWARD)
	camera.current = true
	var ray_direction := Vector3(1.0, -2.5, .8).normalized()
	var light_height := maxf(bounds.size.y * 2.0 + 4.0, extent * 1.5)
	var light_position := Vector3(light_height * .15, light_height, light_height * .12)
	var light: Light3D
	if kind == "directional":
		var directional := DirectionalLight3D.new()
		directional.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
		directional.directional_shadow_max_distance = extent * 8.0
		light = directional
	elif kind == "omni":
		var omni := OmniLight3D.new()
		omni.omni_range = extent * 8.0
		omni.omni_attenuation = .001
		light = omni
	else:
		var spot := SpotLight3D.new()
		spot.spot_range = extent * 8.0
		spot.spot_angle = 35.0
		spot.spot_attenuation = .001
		spot.spot_angle_attenuation = .001
		light = spot
	light.shadow_enabled = true
	light.shadow_bias = 0.0
	light.shadow_normal_bias = 0.0
	light.light_energy = 1.0
	light.position = light_position
	scene.add_child(light)
	light.look_at(light_position + ray_direction if kind == "directional" else Vector3.ZERO)
	var prefix := id + "-" + kind
	var original_materials: Array[int] = []
	for surface in medium.get_surface_count(): original_materials.append(medium.surface_get_material(surface).get_instance_id())
	var baseline := await _image(viewport)
	var baseline_again := await _image(viewport)
	var stability := _difference(baseline, baseline_again)
	_check(stability["max_channel_error"] == 0.0, prefix + " baseline is not deterministic")
	caster.material_override = LOD.opaque_shadow_material(cull)
	var optimized := await _image(viewport)
	_check(caster.mesh == medium, prefix + " optimized caster duplicated its mesh")
	_check(caster.material_override == LOD.opaque_shadow_material(cull), prefix + " shared depth override identity changed")
	caster.visible = false
	var no_caster := await _image(viewport)
	var difference := _difference(baseline, optimized)
	_check(float(difference["max_channel_error"]) <= PIXEL_MAX and float(difference["mean_channel_error"]) <= PIXEL_MEAN, prefix + " shadow pixels differ " + str(difference))
	# This oracle reads original indexed triangles, not the optimized material or
	# renderer's depth image. PCF boundaries get an explicit 10% IoU allowance.
	var oracle := _floor_projection(medium, caster.transform, camera, kind, ray_direction, light_position)
	var baseline_mask := _observed_shadow(no_caster, baseline)
	var optimized_mask := _observed_shadow(no_caster, optimized)
	var baseline_shape := _mask_iou(oracle, baseline_mask)
	var optimized_shape := _mask_iou(oracle, optimized_mask)
	_check(int(baseline_shape["reference_pixels"]) > 32 and int(baseline_shape["observed_pixels"]) > 32, prefix + " no measurable floor shadow")
	_check(float(baseline_shape["iou"]) >= MIN_SHADOW_IOU, prefix + " baseline differs from independent geometry oracle " + str(baseline_shape))
	_check(float(optimized_shape["iou"]) >= MIN_SHADOW_IOU, prefix + " optimized differs from independent geometry oracle " + str(optimized_shape))
	for pair: Array in [["original", baseline], ["optimized", optimized], ["no-caster", no_caster]]:
		_check((pair[1] as Image).save_png(absolute.path_join(prefix + "-" + String(pair[0]) + ".png")) == OK, prefix + " PNG")
	_check(_mask_image(oracle).save_png(absolute.path_join(prefix + "-geometry-oracle.png")) == OK, prefix + " oracle PNG")
	# Production directional lights use this bias. The comparison retains exactly
	# the same mesh/normals and light state, while the unbiased floor oracle above
	# is intentionally not used to judge a displaced, biased depth silhouette.
	light.shadow_bias = .09
	light.shadow_normal_bias = 2.4
	caster.visible = true
	caster.material_override = null
	var production_original := await _image(viewport)
	caster.material_override = LOD.opaque_shadow_material(cull)
	var production_optimized := await _image(viewport)
	var production_difference := _difference(production_original, production_optimized)
	_check(float(production_difference["max_channel_error"]) <= PIXEL_MAX and float(production_difference["mean_channel_error"]) <= PIXEL_MEAN, prefix + " production-bias shadow pixels differ " + str(production_difference))
	_check(production_original.save_png(absolute.path_join(prefix + "-production-original.png")) == OK, prefix + " production original PNG")
	_check(production_optimized.save_png(absolute.path_join(prefix + "-production-optimized.png")) == OK, prefix + " production optimized PNG")
	records.append({"owner": id, "light": kind, "mesh_rid": str(medium.get_rid()),
		"resource": "res://assets/models/environment/%s-lod1.glb" % id,
		"source_material_ids": original_materials, "cull": cull, "source_vertices": medium.get_faces().size(),
		"positional_shadow_atlas_size": viewport.positional_shadow_atlas_size,
		"light_position": [light_position.x,light_position.y,light_position.z],
		"spot_angle": 35.0 if kind == "spot" else null,
		"baseline_stability": stability, "pixel_difference": difference,
		"baseline_geometry_iou": baseline_shape, "optimized_geometry_iou": optimized_shape,
		"production_shadow_bias": .09, "production_shadow_normal_bias": 2.4,
		"production_bias_pixel_difference": production_difference})
	await _capture_merged_stage(id,kind,medium,cull,absolute,viewport,caster,light,oracle)
	viewport.queue_free()
	await process_frame


## Additional stage, after the original record has been finalized. Its source
## opaque-depth baseline isolates geometry assembly from material substitution.
func _capture_merged_stage(id: String,kind: String,medium: Mesh,cull: int,absolute: String,
		viewport: SubViewport,caster: MeshInstance3D,light: Light3D,oracle: PackedByteArray) -> void:
	var prefix: String=id+"-"+kind+"-merged"
	var before: PackedByteArray=_signature(medium)
	var merged: Mesh=LOD.shadow_surface_mesh(medium)
	var batch: Dictionary=LOD.shadow_surface_batch_report(medium)
	_check(merged.get_aabb() == medium.get_aabb(),prefix+" full AABB changed")
	_check(merged.get_faces() == medium.get_faces(),prefix+" original indexed triangles changed")
	_check(_merged_channel_oracle(merged) == _merged_channel_oracle(medium),prefix+" POSITION/NORMAL source oracle differs")
	light.shadow_bias=0.0;light.shadow_normal_bias=0.0
	caster.visible=true;caster.mesh=medium;caster.material_override=LOD.opaque_shadow_material(cull)
	var original: Image=await _image(viewport)
	var original_again: Image=await _image(viewport)
	var stability: Dictionary=_difference(original,original_again)
	_check(stability["max_channel_error"] == 0.0,prefix+" source baseline is not deterministic")
	caster.mesh=merged
	var image: Image=await _image(viewport)
	var image_again: Image=await _image(viewport)
	var merged_stability: Dictionary=_difference(image,image_again)
	_check(merged_stability["max_channel_error"] == 0.0,prefix+" merged baseline is not deterministic")
	var difference: Dictionary=_difference(original,image)
	_check(float(difference["max_channel_error"]) <= PIXEL_MAX and float(difference["mean_channel_error"]) <= PIXEL_MEAN,prefix+" shadow pixels differ "+str(difference))
	caster.visible=false
	var no_caster: Image=await _image(viewport)
	var shape: Dictionary=_mask_iou(oracle,_observed_shadow(no_caster,image))
	_check(int(shape["reference_pixels"]) > 32 and int(shape["observed_pixels"]) > 32,prefix+" no measurable floor shadow")
	_check(float(shape["iou"]) >= MIN_SHADOW_IOU,prefix+" differs from independent source geometry oracle "+str(shape))
	light.shadow_bias=.09;light.shadow_normal_bias=2.4
	caster.visible=true;caster.mesh=medium
	var biased_original: Image=await _image(viewport)
	caster.mesh=merged
	var biased_merged: Image=await _image(viewport)
	var biased_difference: Dictionary=_difference(biased_original,biased_merged)
	_check(float(biased_difference["max_channel_error"]) <= PIXEL_MAX and float(biased_difference["mean_channel_error"]) <= PIXEL_MEAN,prefix+" production-bias pixels differ "+str(biased_difference))
	for pair: Array in [["source",original],["single-surface",image],["production-source",biased_original],["production-single-surface",biased_merged]]:
		_check((pair[1] as Image).save_png(absolute.path_join(prefix+"-"+String(pair[0])+".png")) == OK,prefix+" PNG")
	_check(_signature(medium) == before,prefix+" source arrays/material IDs mutated")
	merged_records.append({"owner":id,"light":kind,"resource":"res://assets/models/environment/%s-lod1.glb" % id,
		"source_mesh_rid":str(medium.get_rid()),"merged_mesh_rid":str(merged.get_rid()),
		"source_surfaces":medium.get_surface_count(),"caster_surfaces":merged.get_surface_count(),"batch":batch,
		"baseline_stability":stability,"merged_stability":merged_stability,"pixel_difference":difference,
		"independent_geometry_iou":shape,"production_shadow_bias":.09,"production_shadow_normal_bias":2.4,
		"production_bias_pixel_difference":biased_difference,"source_witness_unchanged":_signature(medium) == before})
	caster.mesh=medium


func _merged_channel_oracle(mesh: Mesh) -> PackedByteArray:
	var witness: Array=[]
	for surface in mesh.get_surface_count():
		var arrays: Array=mesh.surface_get_arrays(surface)
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for index in arrays[Mesh.ARRAY_VERTEX].size(): indices.append(index)
		for index: int in indices:
			var vertex: Array=[]
			for slot: int in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL]:
				vertex.append(arrays[slot][index] if arrays[slot] != null and not arrays[slot].is_empty() else null)
			witness.append(vertex)
	return var_to_bytes(witness)


func _image(viewport: SubViewport) -> Image:
	for frame in 12: await process_frame
	await RenderingServer.frame_post_draw
	var image := viewport.get_texture().get_image()
	image.convert(Image.FORMAT_RGBA8)
	return image


func _signature(mesh: Mesh) -> PackedByteArray:
	var arrays: Array = []
	for surface in mesh.get_surface_count():
		arrays.append(mesh.surface_get_arrays(surface))
		arrays.append(mesh.surface_get_material(surface).get_instance_id())
		if mesh is ArrayMesh:
			var raw: Dictionary=mesh.get("_surfaces")[surface]
			arrays.append([raw["format"],raw["vertex_count"],raw.get("index_count",0),raw["vertex_data"],raw.get("attribute_data",PackedByteArray()),raw.get("index_data",PackedByteArray()),raw.get("lods",[])])
	return var_to_bytes(arrays)


func _difference(a: Image, b: Image) -> Dictionary:
	var bytes_a := a.get_data()
	var bytes_b := b.get_data()
	var maximum := 0
	var total := 0
	var changed := 0
	for offset in range(0, bytes_a.size(), 4):
		var pixel_changed := false
		for channel in 3:
			var delta := absi(int(bytes_a[offset + channel]) - int(bytes_b[offset + channel]))
			maximum = maxi(maximum, delta)
			total += delta
			pixel_changed = pixel_changed or delta > 0
		changed += 1 if pixel_changed else 0
	return {"max_channel_error": maximum / 255.0,
		"mean_channel_error": total / (float(a.get_width() * a.get_height() * 3) * 255.0), "changed_pixels": changed}


func _observed_shadow(reference: Image, shadow: Image) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(SIZE * SIZE)
	var a := reference.get_data()
	var b := shadow.get_data()
	for pixel in mask.size():
		var delta := 0
		for channel in 3: delta = maxi(delta, int(a[pixel * 4 + channel]) - int(b[pixel * 4 + channel]))
		mask[pixel] = 1 if delta / 255.0 >= SHADOW_DELTA else 0
	return mask


func _floor_projection(mesh: Mesh, pose: Transform3D, camera: Camera3D, kind: String,
		direction: Vector3, light_position: Vector3) -> PackedByteArray:
	var mask := PackedByteArray()
	mask.resize(SIZE * SIZE)
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var positions: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		var count := indices.size() if not indices.is_empty() else positions.size()
		for offset in range(0, count, 3):
			var screen: Array[Vector2] = []
			for corner in 3:
				var p: Vector3 = pose * positions[indices[offset + corner] if not indices.is_empty() else offset + corner]
				var hit := p - direction * (p.y / direction.y) if kind == "directional" else p + (p - light_position) * (p.y / (light_position.y - p.y))
				hit.y = 0.0
				screen.append(camera.unproject_position(hit))
			_raster_triangle(mask, screen[0], screen[1], screen[2])
	return mask


func _raster_triangle(mask: PackedByteArray, a: Vector2, b: Vector2, c: Vector2) -> void:
	var area := (b - a).cross(c - a)
	if absf(area) < .0001: return
	var x0 := clampi(int(floor(minf(a.x, minf(b.x, c.x)))), 0, SIZE - 1)
	var x1 := clampi(int(ceil(maxf(a.x, maxf(b.x, c.x)))), 0, SIZE - 1)
	var y0 := clampi(int(floor(minf(a.y, minf(b.y, c.y)))), 0, SIZE - 1)
	var y1 := clampi(int(ceil(maxf(a.y, maxf(b.y, c.y)))), 0, SIZE - 1)
	var sign_area := signf(area)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var p := Vector2(x + .5, y + .5)
			if sign_area * (b - a).cross(p - a) >= 0.0 and sign_area * (c - b).cross(p - b) >= 0.0 and sign_area * (a - c).cross(p - c) >= 0.0:
				mask[y * SIZE + x] = 1


func _mask_iou(reference: PackedByteArray, observed: PackedByteArray) -> Dictionary:
	var intersection := 0
	var union := 0
	var expected := 0
	var actual := 0
	for pixel in reference.size():
		expected += int(reference[pixel])
		actual += int(observed[pixel])
		intersection += 1 if reference[pixel] != 0 and observed[pixel] != 0 else 0
		union += 1 if reference[pixel] != 0 or observed[pixel] != 0 else 0
	return {"iou": float(intersection) / maxf(1.0, union), "reference_pixels": expected, "observed_pixels": actual}


func _mask_image(mask: PackedByteArray) -> Image:
	var image := Image.create(SIZE, SIZE, false, Image.FORMAT_RGB8)
	for y in SIZE:
		for x in SIZE: image.set_pixel(x, y, Color.WHITE if mask[y * SIZE + x] != 0 else Color.BLACK)
	return image


func _check(condition: bool, message: String) -> void:
	if not condition: failures.append(message)

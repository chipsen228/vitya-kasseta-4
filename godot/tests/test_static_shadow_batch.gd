extends SceneTree
const Batch = preload("res://src/static_shadow_batch.gd")
var errors: Array[String] = []
var _max_normal_delta := 0.0
var _external_visibility_events := 0

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	if OS.get_cmdline_user_args().has("--source-census"):
		await _source_census()
		return
	if not OS.get_cmdline_user_args().has("--diagnostic"):
		await _fixture()
		await _late_fixture()
		await _dense_partition_fixture()
		await _dense_fallback_fixture()
		await _single_exclusion_fixture()
		if OS.get_cmdline_user_args().has("--fixtures-only"):
			_finish()
			return
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	var built := WorldBuilder.build(world, mats, col)
	world.transform = Transform3D(Basis(Vector3.UP, 0.3), Vector3(7, 3, -2))
	var info := Batch.diagnose(world)
	var file := FileAccess.open(ProjectSettings.globalize_path("res://../output/graphics-refresh/static-shadow-diagnostic.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(info, "\t") + "\n")
	file.close()
	print("static_shadow_diagnostic: candidates=%d sources=%d proxies=%d saved=%d triangles=%d" %
		[info["candidates"], info["sources"], info["proxies"], info["saved"], info["triangles"]])
	if not OS.get_cmdline_user_args().has("--diagnostic"):
		var count_before := world.get_child_count()
		var dense_parts := 0
		Batch.prepare(world)
		info = Batch.stats(world)
		var original_sources: Dictionary = {}
		var total := 0
		for record: Dictionary in Batch.records(world):
			var sources: Array = record["sources"]
			var proxies: Array = record["proxies"]
			dense_parts += _check_partition_occupancy(sources, proxies, float(record["dense_cell_size"]))
			_precision(sources, proxies)
			_check(_triangles(sources, world.transform) == _triangles(proxies, world.transform),
				"actual triangle multiset or world transform changed")
			for source: MeshInstance3D in sources:
				original_sources[source.get_instance_id()] = true
			for proxy: MeshInstance3D in proxies:
				total += proxy.mesh.get_faces().size() / 3
				_check(proxy.get_parent() == world, "proxy escaped its world owner")
				var padding: float = proxy.get_meta("shadow_range_padding")
				for source: MeshInstance3D in sources:
					var sc := source.transform * source.get_aabb().get_center()
					var pc := proxy.get_aabb().get_center()
					_check((world.basis * (sc - pc)).length() <= padding + 0.00001,
						"proxy range may cull a still-visible source")
				_check(is_equal_approx(proxy.visibility_range_end, 56.0 + float(proxy.get_meta("shadow_range_padding"))) and proxy.visibility_range_end_margin == 8.0,
					"conservative bucket visibility range incorrect")
				_check_cells(proxy)
		_check(total == int(info["triangles"]), "shadow triangle budget changed")
		_check(dense_parts >= 2, "actual WorldBuilder did not exercise dense spatial refinement")
		print("static_shadow_dense_world: verified fine proxies=", dense_parts)
		var untouched: Array = []
		_capture_untouched(world, original_sources, untouched)
		Batch.set_hq(world, true)
		_check_modes(world, true)
		for entry: Array in untouched:
			_check((entry[0] as MeshInstance3D).cast_shadow == entry[1], "non-bucket or door cast mode changed")
		for owner: Node3D in (built["decor"] as Dictionary).values():
			_check(owner.get_parent() == world, "decor owner moved")
		Batch.set_hq(world, false)
		_check_modes(world, false)
		print("static_shadow_partition: sources=%d proxies=%d saved=%d triangles=%d" % [Batch.stats(world)["sources"], Batch.stats(world)["proxies"], Batch.stats(world)["saved"], Batch.stats(world)["triangles"]])
		var count_prepared := world.get_child_count()
		Batch.prepare(world)
		_check(world.get_child_count() == count_prepared, "prepare is not idempotent")
		_check(count_prepared >= count_before, "original world child removed")
		if OS.get_cmdline_user_args().has("--with-environment"):
			_environment_fixture(world, mats, built, col)
	world.free()
	_finish()

func _finish() -> void:
	if errors.is_empty():
		print("test_static_shadow_batch: PASS (late rebuild, retained/interior world triangles+area, normal packing max=", _max_normal_delta, ", HQ/retro, callback retirement, exclusions, visibility fallback, budget)")
		quit(0)
	else:
		for message: String in errors:
			printerr("FAIL test_static_shadow_batch: ", message)
		quit(1)

## CPU inventory only. Counts do not measure GPU passes, frustum or FPS.
func _source_census() -> void:
	var main: Node = load("res://src/main.tscn").instantiate()
	get_root().add_child(main)
	var started := Time.get_ticks_msec()
	while not bool(main.get("boot_ready")) and Time.get_ticks_msec()-started < 120000:
		await process_frame
	_check(bool(main.get("boot_ready")), "source census main boot timed out")
	if not bool(main.get("boot_ready")):
		main.queue_free()
		await process_frame
		_finish()
		return
	var renderer: RenderChain = main.get("render_chain")
	renderer.apply_preset("hq")
	await process_frame
	await process_frame
	main.set_process(false)
	var world: Node3D = renderer.world_root
	var props: Props = main.get("props")
	var built: Dictionary = main.get("built")
	var batched: Dictionary = {}
	for record: Dictionary in Batch.records(world):
		if bool(record["disabled"]):
			continue
		for source: MeshInstance3D in record["sources"]:
			if is_instance_valid(source) and source.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				batched[source.get_instance_id()] = true
	var owners: Dictionary = {}
	for category: String in ["home","village","yard","outskirts","snt","valya"]:
		for id: String in built.get(category,{}).get("nodes",{}):
			var owner: Variant = built[category]["nodes"][id]
			if is_instance_valid(owner) and owner is Node3D:
				owners[owner.get_instance_id()] = {"category":category,"id":id}
	for id: String in props.by_id:
		var owner: Node3D = props.by_id[id]
		owners[owner.get_instance_id()] = {"category":"props","id":id}
	var categories: Dictionary = {}
	var rows: Array = []
	var nodes: Array[Node] = [world]
	var index := 0
	while index < nodes.size():
		var node: Node = nodes[index]
		index += 1
		nodes.append_array(node.get_children())
		if not node is MeshInstance3D or (node as MeshInstance3D).mesh == null:
			continue
		var source := node as MeshInstance3D
		var owner := {"category":"other","id":""}
		var cursor: Node = source
		while cursor != world and cursor != null:
			if owners.has(cursor.get_instance_id()):
				owner = owners[cursor.get_instance_id()]
				break
			cursor = cursor.get_parent()
		if source.has_meta("static_shadow_proxy"):
			owner = {"category":"shadow-proxy","id":String(source.name)}
		elif source.has_meta("environment_owner"):
			owner = {"category":"environment-lod","id":String(source.get_meta("environment_owner"))}
		elif source.has_meta("environment_interior"):
			owner = {"category":"interiors","id":String(source.get_meta("environment_interior"))}
		elif source is ForestLodMesh:
			owner = {"category":"forest","id":String(source.name)}
		elif String(source.name).begins_with("merged_") or source.name == "environment-residual":
			owner = {"category":"world","id":String(source.name)}
		elif owner["category"] == "other" and props.root.is_ancestor_of(source):
			owner["category"] = "props-unidentified"
		var category: String = owner["category"]
		if not categories.has(category):
			categories[category] = {"meshes":0,"surfaces":0,"triangles":0,"off":0,"on":0,"shadows_only":0,"batched_sources":0,"batched_source_triangles":0,"visible_casters":0,"visible_caster_surfaces":0,"visible_caster_triangles":0}
		var totals: Dictionary = categories[category]
		var surfaces := source.mesh.get_surface_count()
		var triangles := source.mesh.get_faces().size()/3
		var visible := Batch._visible_below_world(source,world) and source.layers != 0
		var casts := source.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var shadow_batched := batched.has(source.get_instance_id())
		totals["meshes"] += 1
		totals["surfaces"] += surfaces
		totals["triangles"] += triangles
		var mode := "off" if not casts else "shadows_only" if source.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY else "on"
		totals[mode] += 1
		if shadow_batched:
			totals["batched_sources"] += 1
			totals["batched_source_triangles"] += triangles
		if visible and casts:
			totals["visible_casters"] += 1
			totals["visible_caster_surfaces"] += surfaces
			totals["visible_caster_triangles"] += triangles
		rows.append({"category":category,"owner":owner["id"],"path":str(world.get_path_to(source)),
			"surfaces":surfaces,"triangles":triangles,"cast_mode":mode,"shadow_batched":shadow_batched,"visible_tree_layers":visible,
			"script":source.get_script().resource_path if source.get_script() != null else "",
			"range":source.visibility_range_end,"dynamic_pool":props.dynamic_pool.has(owner["id"]),
			"independent":source.has_meta("independent_visual")})
	var report := {"cpu_inventory_only":true,"visibility_scope":"tree/layers only; no frustum, range or GPU-pass measurement",
		"categories":categories,"nodes":rows,"batch":Batch.stats(world)}
	report["verification_errors"] = errors.duplicate()
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			var path := argument.trim_prefix("--output=")
			var file := FileAccess.open(path,FileAccess.WRITE)
			_check(file != null,"cannot write source census report")
			if file != null:
				file.store_string(JSON.stringify(report,"\t")+"\n")
				file.close()
	for category: String in categories:
		print("static_shadow_census ",category,": ",JSON.stringify(categories[category]))
	main.queue_free()
	await process_frame
	for error: String in errors:
		printerr("FAIL shadow census: ",error)
	print("test_static_shadow_source_census: ","PASS" if errors.is_empty() else "FAIL")
	quit(0 if errors.is_empty() else 1)

func _fixture() -> void:
	var world := Node3D.new()
	world.name = "ShadowFixture"
	var material := ShaderMaterial.new()
	material.shader = load(Materials.HQ_SHADER)
	var first: MeshInstance3D = null
	for i in 56:
		var source := _source("merged:material%d:0.0" % i, material, Vector3(i * 0.02, 0, 15.5 if i < 28 else 16.5))
		world.add_child(source)
		if i == 0:
			first = source
	var excluded: Array[MeshInstance3D] = []
	var alpha := material.duplicate() as ShaderMaterial
	alpha.set_shader_parameter("alpha_cut", 0.4)
	excluded.append(_source("merged:cutout:0.0", alpha))
	var next_pass := material.duplicate() as ShaderMaterial
	next_pass.next_pass = StandardMaterial3D.new()
	excluded.append(_source("merged:nextpass:0.0", next_pass))
	var custom := _source("merged:custombounds:0.0", material)
	custom.custom_aabb = AABB(Vector3(-2, -2, -2), Vector3(4, 4, 4))
	excluded.append(custom)
	var shadow := _source("merged:customshadow:0.0", material)
	(shadow.mesh as ArrayMesh).shadow_mesh = (shadow.mesh as ArrayMesh).duplicate()
	excluded.append(shadow)
	var water := ShaderMaterial.new()
	water.shader = load("res://shaders/psx_water_hq.gdshader")
	excluded.append(_source("merged:water:0.0", water))
	var door := _source("door-leaf", material)
	excluded.append(door)
	var plane := _source("merged:plane:0.0", material)
	plane.mesh = QuadMesh.new()
	excluded.append(plane)
	for source: MeshInstance3D in excluded:
		world.add_child(source)
	get_root().add_child(world)
	await process_frame
	var info := Batch.prepare(world)
	_check(int(info["sources"]) == 56 and int(info["proxies"]) == 2 and int(info["saved"]) == 54, "fixture candidates/exclusions changed")
	_check(Batch.records(world).size() == 1, "fixture has wrong proxy count")
	var record: Dictionary = Batch.records(world)[0]
	_check((record["proxies"] as Array).size() >= 2, "fixture did not exercise a spatial split")
	_check(_triangles(record["sources"], world.transform) == _triangles(record["proxies"], world.transform), "fixture exact geometry mismatch")
	var source_mesh := first.mesh
	var source_pose := first.transform
	Batch.set_hq(world, true)
	_check_modes(world, true)
	for source: MeshInstance3D in excluded:
		_check(source.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "excluded alpha/door/custom mesh modified")
	_check(first.mesh == source_mesh and first.transform == source_pose and first.material_override == material, "source resources/pose replaced")
	world.visible = false
	await process_frame
	_check(not bool(record["disabled"]), "parent visibility invalidated an intact group")
	world.visible = true
	await process_frame
	Batch.set_hq(world, false)
	_check_modes(world, false)
	Batch.set_hq(world, true)
	var residual := MeshInstance3D.new()
	residual.mesh = first.mesh
	residual.cast_shadow = first.cast_shadow
	first.add_child(residual)
	first.set_meta("environment_residual",residual)
	first.layers = 0
	Batch.set_hq(world,true)
	_check(bool(record["disabled"]),"replaced exterior retained its old shadow proxy")
	_check(residual.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
		"visible residual walls lost shadows after exterior replacement")
	first.visible = false
	await process_frame
	_check(bool(record["disabled"]), "individual hide did not invalidate proxy")
	for proxy: MeshInstance3D in record["proxies"]:
		_check(not proxy.visible, "hidden source still casts through proxy")
	for source: MeshInstance3D in record["sources"]:
		_check(source.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "fallback did not restore source cast mode")
	first.visible = true
	Batch.set_hq(world, true)
	for proxy: MeshInstance3D in record["proxies"]:
		_check(not proxy.visible, "invalidated group silently re-enabled")
	world.free()

func _late_fixture() -> void:
	var world := Node3D.new()
	world.name = "LateShadowFixture"
	world.transform = Transform3D(Basis(Vector3.UP,.27), Vector3(7,3,-2))
	get_root().add_child(world)
	var material := ShaderMaterial.new()
	material.shader = load(Materials.HQ_SHADER)
	var originals: Array[MeshInstance3D] = []
	for i in 56:
		var coloured := material.duplicate() as ShaderMaterial
		coloured.set_shader_parameter("albedo", Color(.2+i*.005,.4,.5))
		var source := _source("merged:distinct_material_%d:0.0" % i, coloured, Vector3(i*.01,0,2))
		world.add_child(source)
		originals.append(source)
	var body := StaticBody3D.new()
	var collision := CollisionShape3D.new()
	collision.shape = BoxShape3D.new()
	body.add_child(collision)
	world.add_child(body)
	var native_shape := collision.shape
	var native_transform := collision.transform
	var first := originals[0]
	first.visibility_changed.connect(_outside_visibility_changed)
	await process_frame
	Batch.prepare(world)
	Batch.set_hq(world,true)
	var old_records := Batch.records(world).duplicate()
	var old_connections: Array = world.get_meta(Batch.META)["connections"].duplicate()
	var old_callback_states: Array = world.get_meta(Batch.META)["callback_states"].duplicate()
	_check(old_callback_states.size() == old_records.size(), "callback owners are not retained")
	_check(old_records.size() == 1, "opaque material names prevented grouping")
	var old_proxies: Array = []
	for record: Dictionary in old_records:
		old_proxies.append_array(record["proxies"])
	var unchanged: Array = []
	for source: MeshInstance3D in originals:
		unchanged.append([source, source.mesh, source.transform, source.material_override,
			var_to_bytes(source.mesh.surface_get_arrays(0))])
	var retained: Array[MeshInstance3D] = []
	for i in 2:
		var owner := originals[i]
		var residual := _source("environment-residual", owner.material_override, Vector3(.2,0,.3))
		residual.cast_shadow = owner.cast_shadow
		if i == 0:
			var nested := Node3D.new()
			nested.transform = Transform3D(Basis(Vector3.UP,.31).scaled(Vector3(1.2,.8,1.1)), Vector3(.6,.2,.4))
			owner.add_child(nested)
			nested.add_child(residual)
			residual.rotation.x = .15
		else:
			owner.add_child(residual)
		owner.set_meta("environment_residual",residual)
		owner.set_meta("environment_hidden_vertices",{0:true,1:true,2:true})
		owner.layers = 0
		retained.append(residual)
	for i in 8:
		var finish := _source("environment-interior-%d" % i, material, Vector3(.1*i,0,3))
		finish.set_meta("environment_interior","hero-room")
		finish.set_meta("environment_interior_role","baseboard" if i<4 else "wall")
		finish.layers = 2
		finish.visibility_range_end = 18.0 if i<4 else 28.0
		finish.visibility_range_end_margin = .7
		world.add_child(finish)
	var exclusions: Array[MeshInstance3D] = []
	var props := Node3D.new()
	props.name = "props"
	world.add_child(props)
	var furniture := _source("merged:not_immutable:0.0",material)
	props.add_child(furniture)
	exclusions.append(furniture)
	var animated := _source("merged:animated:0.0",material)
	animated.add_child(AnimationPlayer.new())
	world.add_child(animated)
	exclusions.append(animated)
	var deformation := _source("merged:deformation:0.0",material)
	deformation.set_meta("deformation",true)
	world.add_child(deformation)
	exclusions.append(deformation)
	var lod := ForestLodMesh.new()
	lod.name = "merged:lod:0.0"
	lod.mesh = first.mesh
	lod.material_override = material
	world.add_child(lod)
	exclusions.append(lod)
	var door := _source("story-door",material)
	world.add_child(door)
	exclusions.append(door)
	var foreign_proxy := _source("foreign-shadow",material)
	foreign_proxy.set_meta("static_shadow_proxy",true)
	world.add_child(foreign_proxy)
	exclusions.append(foreign_proxy)
	var info := Batch.rebuild(world)
	_check(int(info["sources"]) == 64, "late batch missed retained/interior sources or included old shells/props/LOD")
	_check(int(info["proxies"]) == 3 and int(info["saved"]) == 61, "late grouping changed layer/range separation")
	_check_modes(world,true)
	_check(is_instance_valid(foreign_proxy), "rebuild deleted another owner's proxy")
	for proxy: Variant in old_proxies:
		_check(not is_instance_valid(proxy), "old shadow proxy survived rebuild")
	for record: Dictionary in old_records:
		_check(bool(record["retired"]), "old record remains callable")
	for connection: Dictionary in old_connections:
		var connected: bool = connection["source"].is_connected(connection["signal"],connection["callable"])
		_check(not connected, "old owned callback remained connected")
		(connection["callable"] as Callable).call()
	_check_modes(world,true)
	_check(first.visibility_changed.is_connected(_outside_visibility_changed), "rebuild disconnected a foreign callback")
	first.visibility_changed.emit()
	_check(_external_visibility_events == 1, "foreign visibility callback stopped working")
	_check_modes(world,true)
	var triangle_total := 0
	for record: Dictionary in Batch.records(world):
		_precision(record["sources"],record["proxies"])
		_check(_triangles(record["sources"],world.transform) == _triangles(record["proxies"],world.transform), "late retained world triangle multiset changed")
		_check(is_equal_approx(_area(record["sources"],world.transform),_area(record["proxies"],world.transform)), "late retained world triangle area changed")
		for source: MeshInstance3D in record["sources"]:
			_check(source not in originals.slice(0,2) and source not in exclusions, "masked shell or interactive source batched")
		for proxy: MeshInstance3D in record["proxies"]:
			triangle_total += proxy.mesh.get_faces().size()/3
			var source: MeshInstance3D = record["sources"][0]
			_check(proxy.layers == source.layers, "late proxy layers differ")
			_check(proxy.visibility_range_end_margin == source.visibility_range_end_margin and proxy.visibility_range_fade_mode == source.visibility_range_fade_mode, "late proxy range margins/fade differ")
			_check((proxy.material_override as StandardMaterial3D).cull_mode == Batch._cull(source.get_active_material(0)), "late proxy culling differs")
	_check(triangle_total == 64, "masked old-shell triangles leaked into late batch")
	for entry: Array in unchanged:
		var source: MeshInstance3D = entry[0]
		_check(source.mesh == entry[1] and source.transform == entry[2] and source.material_override == entry[3] and var_to_bytes(source.mesh.surface_get_arrays(0)) == entry[4], "rebuild changed immutable mesh/material/UV/UV2/COLOR/transform")
	for source: MeshInstance3D in exclusions:
		_check(source.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "late batch changed prop/LOD/animation/door shadow mode")
	_check(collision.shape == native_shape and collision.transform == native_transform and not collision.disabled and body.get_parent() == world, "late batching changed native collision")
	for hq: bool in [false,true,false,true]:
		Materials.set_material_quality(material,hq)
		for original: MeshInstance3D in originals:
			Materials.set_material_quality(original.material_override,hq)
		Batch.set_hq(world,hq)
		_check_modes(world,hq)
	var child_count := world.get_child_count()
	var callbacks := originals[2].visibility_changed.get_connections().size()
	for repeat in 2:
		var current := Batch.records(world).duplicate()
		info = Batch.rebuild(world)
		_check(int(info["sources"]) == 64 and int(info["proxies"]) == 3 and world.get_child_count() == child_count, "repeat rebuild is not idempotent")
		_check(originals[2].visibility_changed.get_connections().size() == callbacks, "repeat rebuild accumulated callbacks")
		for record: Dictionary in current:
			Batch._invalidate(record)
		_check_modes(world,true)
	# A nested owner hide must retire root-level proxies, while a world hide must not.
	world.visible = false
	await process_frame
	for record: Dictionary in Batch.records(world):
		_check(not bool(record["disabled"]), "whole-world hide invalidated a late group")
	world.visible = true
	await process_frame
	var retained_record: Dictionary = {}
	for record: Dictionary in Batch.records(world):
		if retained[0] in record["sources"]:
			retained_record = record
	first.visible = false
	await process_frame
	_check(bool(retained_record.get("disabled",false)), "nested owner hide left proxy shadows active")
	for proxy: MeshInstance3D in retained_record.get("proxies",[]):
		_check(not proxy.visible, "hidden retained wall still has a proxy shadow")
	first.visible = true
	Batch.rebuild(world)
	_check_modes(world,true)
	var disappearing := originals[2]
	var owner_record: Dictionary = {}
	for record: Dictionary in Batch.records(world):
		if disappearing in record["sources"]:
			owner_record = record
	disappearing.free()
	_check(bool(owner_record.get("disabled",false)), "source tree exit did not invalidate its group")
	Batch.set_hq(world,false)
	Batch.rebuild(world)
	_check(int(Batch.stats(world)["sources"]) == 63, "rebuild retained a freed source")
	print("static_shadow_late: sources=64 proxies=3 saved=61; repeated rebuild, nested hide/tree exit, native collision PASS")
	world.free()

func _outside_visibility_changed() -> void:
	_external_visibility_events += 1

func _single_exclusion_fixture() -> void:
	var world := Node3D.new()
	get_root().add_child(world)
	var mat := ShaderMaterial.new()
	mat.shader = load(Materials.HQ_SHADER)
	mat.set_shader_parameter("base_tint",Vector4.ONE)
	var source := _spread_source("merged:large:0.0",mat,6000,40.0)
	world.add_child(source)
	var mesh := source.mesh
	var arrays := var_to_bytes(mesh.surface_get_arrays(0))
	var pose := source.transform
	Batch.prepare(world)
	_check(Batch.records(world).is_empty(), "early prepare partitioned a single source")
	var info := Batch.rebuild(world)
	_check(Batch.records(world).is_empty() and int(info["sources"]) == 0 and int(info["proxies"]) == 0,
		"late single source spent shadow calls without demonstrated culling benefit")
	for hq: bool in [true,false,true]:
		Batch.set_hq(world,hq)
		_check(source.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON, "excluded single source cast mode changed")
	_check(Batch.rebuild(world) == info, "single exclusion is not idempotent")
	_check(source.mesh == mesh and source.transform == pose and source.material_override == mat and var_to_bytes(mesh.surface_get_arrays(0)) == arrays,
		"excluded single source mesh/material/UV/UV2/COLOR changed")
	world.free()


## Nine occupied 6m cells share one dense 16m cell; the next 16m cell stays sparse.
## Counts are authored here, independently of the batch's chunk-building helpers.
func _dense_partition_fixture() -> void:
	var world := Node3D.new()
	world.name = "DenseShadowFixture"
	world.transform = Transform3D(Basis(Vector3.UP, 0.21), Vector3(3, 2, -4))
	var material := ShaderMaterial.new()
	material.shader = load(Materials.HQ_SHADER)
	var originals: Array[MeshInstance3D] = []
	var saved: Array = []
	for index in 64:
		var source := _authored_dense_source(index, material)
		world.add_child(source)
		originals.append(source)
		saved.append([source.mesh, source.transform, source.material_override,
			var_to_bytes(source.mesh.surface_get_arrays(0)), source.layers,
			source.get_meta("authored_dense_index")])
	get_root().add_child(world)
	await process_frame
	var oracle := _expected_partition_occupancy(originals)
	_check(Batch.SHADOW_CELL == 16.0 and Batch.DENSE_SHADOW_CELL == 6.0,
		"authored dense fixture requires the approved 16m/6m policy")
	_check(int(oracle["triangles"]) == 5120 and int(oracle["dense_parts"]) == 9 and oracle["cells"].size() == 10,
		"authored source occupancy is not nine dense cells plus one sparse cell")
	var info := Batch.prepare(world)
	_check(int(info["sources"]) == 64 and int(info["proxies"]) == 10 and int(info["saved"]) == 54 \
		and int(info["triangles"]) == 5120, "dense fixture did not refine the authored >4000-triangle cell")
	var records := Batch.records(world)
	_check(records.size() == 1, "dense fixture unexpectedly changed source grouping")
	if records.size() == 1:
		var record: Dictionary = records[0]
		var proxies: Array = record["proxies"]
		_check(float(record["dense_cell_size"]) == 6.0 and _check_partition_occupancy(originals, proxies, float(record["dense_cell_size"])) == 9,
			"profitable dense fixture lost its 6m policy/nine fine cells")
		_check(_triangles(originals, world.transform) == _triangles(proxies, world.transform),
			"dense refinement changed exact triangle positions/order/multiplicity")
		var source_area := _area(originals, world.transform)
		_check(absf(source_area - _area(proxies, world.transform)) <= source_area * 0.000001,
			"dense refinement changed total transformed triangle area")
		_precision(originals, proxies)
		for proxy: MeshInstance3D in proxies:
			_check_cells(proxy)
			_check(proxy.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3 == 512,
				"authored dense/sparse cell triangle multiplicity changed")
			_check(proxy.get_meta("shadow_sources") == originals and proxy.layers == 1 \
				and proxy.get_parent() == world, "dense proxy source ownership/layers/parent metadata changed")
		for hq: bool in [true, false, true]:
			Batch.set_hq(world, hq)
			_check_modes(world, hq)
		for index in originals.size():
			var source := originals[index]
			var prior: Array = saved[index]
			_check(source.mesh == prior[0] and source.transform == prior[1] and source.material_override == prior[2] \
				and var_to_bytes(source.mesh.surface_get_arrays(0)) == prior[3] and source.layers == prior[4] \
				and source.get_meta("authored_dense_index") == prior[5],
				"dense refinement altered source mesh/attributes/pose/material/layers/metadata")
		var child_count := world.get_child_count()
		_check(Batch.rebuild(world) == info and world.get_child_count() == child_count,
			"dense rebuild is not idempotent")
		originals[0].visible = false
		await process_frame
		_check_modes(world, false)
	print("static_shadow_dense_authored: triangles=5120 dense=4608/9cells sparse=512/1cell sources=64 proxies=10")
	world.free()


func _dense_fallback_fixture() -> void:
	for profitable: bool in [true, false]:
		var world := Node3D.new()
		world.name = "DenseFallbackFixture" if profitable else "DenseUnprofitableFixture"
		world.transform = Transform3D(Basis(Vector3.UP, -0.14), Vector3(-2, 1, 3))
		var material := ShaderMaterial.new()
		material.shader = load(Materials.HQ_SHADER)
		var source_count := 9 if profitable else 2
		var per_source := 720 if profitable else 2250
		var originals: Array[MeshInstance3D] = []
		var saved: Array = []
		for index in source_count:
			var source := _authored_dense_source(index, material, per_source, per_source)
			world.add_child(source)
			originals.append(source)
			saved.append([source.mesh, source.transform, source.material_override,
				var_to_bytes(source.mesh.surface_get_arrays(0)), source.get_meta("authored_dense_index")])
		get_root().add_child(world)
		await process_frame
		var six := _expected_partition_occupancy(originals, 6.0)
		var eight := _expected_partition_occupancy(originals, 8.0)
		_check(six["cells"].size() == 9 and eight["cells"].size() == 4,
			"fallback authored occupancy no longer proves nine 6m versus four 8m cells")
		var expected := _expected_dense_policy(originals)
		_check(float(expected["dense_cell_size"]) == (8.0 if profitable else 0.0),
			"independent fallback/no-saving decision disagrees with authored source count")
		var source_triangles := _triangles(originals, world.transform)
		var info := Batch.rebuild(world)
		var records := Batch.records(world)
		if profitable:
			_check(int(info["sources"]) == 9 and int(info["proxies"]) == 4 and int(info["saved"]) == 5 \
				and int(info["triangles"]) == 6480 and int(info["dense8_fallback_groups"]) == 1,
				"6m non-saving group did not use its profitable exact 8m fallback")
			_check(records.size() == 1, "fallback group was discarded or split into separate source owners")
			if records.size() == 1:
				var record: Dictionary = records[0]
				var proxies: Array = record["proxies"]
				_check(_check_partition_occupancy(originals, proxies, float(record["dense_cell_size"])) == 4,
					"fallback did not preserve the four independently expected 8m cells")
				_check(_triangles(proxies, world.transform) == source_triangles,
					"adaptive fallback changed exact triangle positions/order/multiplicity")
				var area := _area(originals, world.transform)
				_check(absf(_area(proxies, world.transform) - area) <= area * 0.000001,
					"adaptive fallback changed transformed area")
				_precision(originals, proxies)
				var multiplicities: Array[int] = []
				for proxy: MeshInstance3D in proxies:
					_check_cells(proxy)
					_check(float(proxy.get_meta("shadow_cell_size")) == 8.0 and float(proxy.get_meta("shadow_dense_cell_size")) == 8.0,
						"fallback chunk metadata claimed the requested 6m grid")
					multiplicities.append(int(proxy.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size() / 3))
				multiplicities.sort()
				_check(multiplicities == [720, 1440, 1440, 2880], "authored 8m fallback cell multiplicities changed")
		else:
			_check(records.is_empty() and int(info["sources"]) == 0 and int(info["proxies"]) == 0 \
				and int(info["saved"]) == 0 and int(info["unprofitable_groups"]) == 1,
				"both non-saving grids must preserve native sources without dummy proxies")
		for hq: bool in [true, false, true]:
			Batch.set_hq(world, hq)
			if profitable: _check_modes(world, hq)
			else:
				for source: MeshInstance3D in originals:
					_check(source.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_ON,
						"unprofitable source changed native shadow mode")
		for index in originals.size():
			var source := originals[index]
			var prior: Array = saved[index]
			_check(source.mesh == prior[0] and source.transform == prior[1] and source.material_override == prior[2] \
				and var_to_bytes(source.mesh.surface_get_arrays(0)) == prior[3] and source.get_meta("authored_dense_index") == prior[4],
				"adaptive fallback/exclusion changed source mesh/attributes/pose/material/metadata")
		_check(_triangles(originals, world.transform) == source_triangles, "fallback/exclusion changed original world triangles")
		var children := world.get_child_count()
		_check(Batch.rebuild(world) == info and world.get_child_count() == children, "adaptive choice changed on identical rebuild")
		print("static_shadow_dense_fallback: source_count=", source_count, " candidate6=9 candidate8=4 selected=", "8m" if profitable else "native",
			" triangles=", per_source * source_count)
		world.free()


func _authored_dense_source(index: int, material: Material, triangles := 80, dense_triangles := 72) -> MeshInstance3D:
	var source := _source("merged_dense_%02d" % index, material, Vector3(index * 0.002, 0, 0))
	source.scale = Vector3(1, 1.2, 1)
	source.set_meta("authored_dense_index", index)
	var base := source.mesh.surface_get_arrays(0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var colours := PackedColorArray()
	var indices := PackedInt32Array()
	for triangle in triangles:
		var offset := Vector3(10.5, 0.001 * (triangle % 7), 2.5)
		if triangle < dense_triangles:
			var square := triangle % 9
			offset.x = -14.5 + float(square % 3) * 6.0
			offset.z = 1.5 + float(floori(float(square) / 3.0)) * 6.0
		for corner in 3:
			indices.append(vertices.size())
			vertices.append((base[Mesh.ARRAY_VERTEX][corner] as Vector3) + offset)
			normals.append(base[Mesh.ARRAY_NORMAL][corner])
			uv.append(base[Mesh.ARRAY_TEX_UV][corner])
			uv2.append(base[Mesh.ARRAY_TEX_UV2][corner])
			colours.append(base[Mesh.ARRAY_COLOR][corner])
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = colours
	if index % 2 == 0: arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	source.mesh = mesh
	return source


## Source-array oracle: no production partition/group helper or proxy is consulted.
func _expected_partition_occupancy(sources: Array, dense_cell_size := Batch.DENSE_SHADOW_CELL) -> Dictionary:
	var coarse: Dictionary = {}
	var total := 0
	for source: MeshInstance3D in sources:
		var pose := _relative(source)
		var arrays := source.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else vertices.size()
		for first in range(0, count, 3):
			var a := pose * vertices[indices[first] if not indices.is_empty() else first]
			var b := pose * vertices[indices[first + 1] if not indices.is_empty() else first + 1]
			var c := pose * vertices[indices[first + 2] if not indices.is_empty() else first + 2]
			var center := (a + b + c) / 3.0
			var large := _occupancy_cell(center, Batch.SHADOW_CELL)
			var small := _occupancy_cell(center, dense_cell_size)
			if not coarse.has(large): coarse[large] = {"count": 0, "fine": {}}
			var row: Dictionary = coarse[large]
			row["count"] += 1
			row["fine"][small] = int(row["fine"].get(small, 0)) + 1
			total += 1
	var cells: Dictionary = {}
	var dense_parts := 0
	for large: Vector2i in coarse:
		var row: Dictionary = coarse[large]
		if int(row["count"]) > Batch.DENSE_SHADOW_TRIANGLES:
			for small: Vector2i in row["fine"]:
				cells[_occupancy_key(dense_cell_size, large, small)] = row["fine"][small]
				dense_parts += 1
		else:
			cells[_occupancy_key(Batch.SHADOW_CELL, large, large)] = row["count"]
	return {"cells": cells, "dense_parts": dense_parts, "triangles": total}


func _expected_dense_policy(sources: Array) -> Dictionary:
	var six := _expected_partition_occupancy(sources, 6.0)
	if six["cells"].size() < sources.size():
		six["dense_cell_size"] = 6.0
		return six
	var eight := _expected_partition_occupancy(sources, 8.0)
	eight["dense_cell_size"] = 8.0 if eight["cells"].size() < sources.size() else 0.0
	return eight


func _check_partition_occupancy(sources: Array, proxies: Array, assigned_size: float) -> int:
	var expected := _expected_dense_policy(sources)
	_check(assigned_size == float(expected["dense_cell_size"]) and assigned_size != 0.0,
		"assigned dense policy does not match independent source occupancy/call saving")
	var actual: Dictionary = {}
	var dense_parts := 0
	for proxy: MeshInstance3D in proxies:
		var arrays := proxy.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var size: float = proxy.get_meta("shadow_cell_size")
		_check(float(proxy.get_meta("shadow_dense_cell_size")) == assigned_size,
			"proxy and record assigned dense policies differ")
		var small: Vector2i = proxy.get_meta("shadow_cell")
		var coarse: Dictionary = {}
		for first in range(0, vertices.size(), 3):
			var center := (vertices[first] + vertices[first + 1] + vertices[first + 2]) / 3.0
			coarse[_occupancy_cell(center, Batch.SHADOW_CELL)] = true
			_check(_occupancy_cell(center, size) == small, "proxy metadata does not match actual centroid occupancy")
		_check(coarse.size() == 1, "one shadow proxy contains triangles from different coarse cells")
		if coarse.size() != 1: continue
		var key := _occupancy_key(size, coarse.keys()[0], small)
		_check(not actual.has(key), "duplicate proxy for one coarse/fine partition")
		actual[key] = int(vertices.size() / 3)
		if size in [6.0, 8.0]: dense_parts += 1
	_check(actual == expected["cells"], "proxy cell counts differ from independent source-centroid oracle")
	_check(dense_parts == int(expected["dense_parts"]), "source dense occupancy/proxy refinement count differs")
	return dense_parts


func _occupancy_cell(center: Vector3, size: float) -> Vector2i:
	return Vector2i(floori((center.x + WorldBuilder.CHUNK_ORIGIN_X) / size),
		floori((center.z + WorldBuilder.CHUNK_ORIGIN_Z) / size))


func _occupancy_key(size: float, large: Vector2i, small: Vector2i) -> String:
	# 6m cells can straddle 16m borders; their coarse parents must remain distinct.
	return var_to_str([size, large, small])

func _spread_source(label: String, material: Material, triangles: int, span: float) -> MeshInstance3D:
	var template := _source(label,material)
	var base := template.mesh.surface_get_arrays(0)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	var colours := PackedColorArray()
	for triangle in triangles:
		var offset := Vector3(-span*.5 if triangle < triangles/2 else span*.5,.001*(triangle%7),0)
		for i in 3:
			vertices.append((base[Mesh.ARRAY_VERTEX][i] as Vector3)+offset)
			normals.append(base[Mesh.ARRAY_NORMAL][i])
			uv.append(base[Mesh.ARRAY_TEX_UV][i])
			uv2.append(base[Mesh.ARRAY_TEX_UV2][i])
			colours.append(base[Mesh.ARRAY_COLOR][i])
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	arrays[Mesh.ARRAY_COLOR] = colours
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	template.mesh = mesh
	return template

func _environment_fixture(world: Node3D, mats: Materials, built: Dictionary, col: CollisionWorld) -> void:
	if not world.is_inside_tree():
		get_root().add_child(world)
	var registry := preload("res://src/environment_registry.gd").apply(world,built,mats)
	var interiors := preload("res://src/environment_interiors.gd").apply(world,mats,built)
	preload("res://src/environment_detail_ranges.gd").apply(world,built,Props.new(mats))
	_check((registry["errors"] as Array).is_empty() and (interiors["errors"] as Array).is_empty(), "actual registry/interior preparation failed")
	var collider_state := var_to_str([col._data,col._active,col._by_id])
	var original: Array = []
	for source: MeshInstance3D in Batch._candidates(world):
		if source.mesh != null:
			original.append([source,source.mesh,source.transform,source.material_override,
				var_to_bytes(source.mesh.surface_get_arrays(0))])
	var info := Batch.rebuild(world)
	_check(int(info["saved"]) > 0, "actual late replacement did not save any shadow calls")
	var residuals := 0
	var finishes := 0
	var sources: Array = []
	var proxies: Array = []
	for record: Dictionary in Batch.records(world):
		sources.append_array(record["sources"])
		proxies.append_array(record["proxies"])
		for source: MeshInstance3D in record["sources"]:
			_check(source.layers != 0 and not source.has_meta("environment_hidden_vertices"), "actual masked original entered late proxy")
			if source.has_meta("environment_interior"):
				finishes += 1
			elif source.get_parent() != world:
				residuals += 1
			_check(source.get_script() == null, "actual LOD/animated mesh entered late proxy")
	_check(residuals > 0 and finishes > 0, "actual late residuals or interior surfaces were omitted")
	_precision(sources,proxies)
	_check(_triangles(sources,world.transform) == _triangles(proxies,world.transform), "actual late world triangle multiset changed")
	_check(is_equal_approx(_area(sources,world.transform),_area(proxies,world.transform)), "actual late world triangle area changed")
	for entry: Array in original:
		var source: MeshInstance3D = entry[0]
		_check(source.mesh == entry[1] and source.transform == entry[2] and source.material_override == entry[3] and var_to_bytes(source.mesh.surface_get_arrays(0)) == entry[4], "actual late source mesh/material/UV/UV2/COLOR changed")
	for hq: bool in [true,false,true]:
		for source: MeshInstance3D in sources:
			Materials.set_material_quality(source.get_active_material(0),hq)
		Batch.set_hq(world,hq)
		_check_modes(world,hq)
	var count := world.get_child_count()
	var repeated := Batch.rebuild(world)
	_check(info == repeated and world.get_child_count() == count, "actual late rebuild is not idempotent")
	_check_modes(world,true)
	_check(var_to_str([col._data,col._active,col._by_id]) == collider_state, "actual late rebuild changed collision ledger")
	print("static_shadow_environment: sources=%d proxies=%d saved=%d triangles=%d residuals=%d interior_surfaces=%d sample=%s" %
		[info["sources"],info["proxies"],info["saved"],info["triangles"],residuals,finishes,registry.get("sample_mode",false)])

func _relative(source: Node3D) -> Transform3D:
	var result := Transform3D.IDENTITY
	var cursor := source
	while cursor.get_parent() is Node3D:
		result = cursor.transform * result
		cursor = cursor.get_parent() as Node3D
	return result

func _area(sources: Array, world_transform: Transform3D) -> float:
	# Inspect rendered surface arrays. Mesh.get_faces() derives a TriangleMesh
	# cache that may weld nearby vertices independently in each spatial chunk.
	var result := 0.0
	for source: MeshInstance3D in sources:
		var pose := world_transform * _relative(source)
		var arrays := source.mesh.surface_get_arrays(0)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else points.size()
		for first in range(0,count,3):
			var a := pose * points[indices[first] if not indices.is_empty() else first]
			var b := pose * points[indices[first+1] if not indices.is_empty() else first+1]
			var c := pose * points[indices[first+2] if not indices.is_empty() else first+2]
			result += (b-a).cross(c-a).length()*.5
	return result

func _source(label: String, material: Material, pos := Vector3.ZERO) -> MeshInstance3D:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3(0.3, 0, 0), Vector3(0, 0.4, 0.2)])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3(0, 0.4472136, -0.8944272), Vector3(0, 0.4472136, -0.8944272), Vector3(0, 0.4472136, -0.8944272)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.UP])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(.1,.2), Vector2(.3,.4), Vector2(.5,.6)])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color(.3,.4,.5), Color(.6,.7,.8), Color(.2,.1,.9)])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var source := MeshInstance3D.new()
	source.name = label
	source.mesh = mesh
	source.position = pos
	source.material_override = material
	source.visibility_range_end = 56.0
	source.visibility_range_end_margin = 8.0
	return source

func _triangles(sources: Array, world_transform: Transform3D) -> Array[String]:
	var result: Array[String] = []
	for source: MeshInstance3D in sources:
		var arrays := source.mesh.surface_get_arrays(0)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else points.size()
		for i in range(0, count, 3):
			var values := PackedVector3Array()
			for k in 3:
				var j := indices[i + k] if not indices.is_empty() else i + k
				values.append(world_transform * (_relative(source) * points[j]))
			result.append(var_to_bytes(values).hex_encode())
	result.sort()
	return result

func _capture_untouched(node: Node, grouped: Dictionary, result: Array) -> void:
	for child: Node in node.get_children():
		if child is MeshInstance3D and not grouped.has(child.get_instance_id()) and not child.has_meta("static_shadow_proxy"):
			result.append([child, (child as MeshInstance3D).cast_shadow])
		_capture_untouched(child, grouped, result)

func _check_modes(world: Node3D, hq: bool) -> void:
	for record: Dictionary in Batch.records(world):
		for proxy: MeshInstance3D in record["proxies"]:
			_check(proxy.visible == hq, "proxy quality visibility incorrect")
			_check(proxy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, "proxy is not shadows-only")
		for source: MeshInstance3D in record["sources"]:
			_check(source.cast_shadow == (GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if hq else GeometryInstance3D.SHADOW_CASTING_SETTING_ON), "source quality shadow mode incorrect")

func _check(condition: bool, message: String) -> void:
	if not condition and message not in errors:
		errors.append(message)
func _precision(sources: Array, proxies: Array) -> void:
	var expected: Dictionary = {}
	for source: MeshInstance3D in sources:
		var arrays := source.mesh.surface_get_arrays(0)
		var sv: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var sn: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var ix: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := ix.size() if not ix.is_empty() else sv.size()
		for i in count:
			var j := ix[i] if not ix.is_empty() else i
			var pose := _relative(source)
			var point := pose * sv[j]
			if not expected.has(point):
				expected[point] = []
			(expected[point] as Array).append(sn[j] if pose.basis == Basis.IDENTITY else (pose.basis.inverse().transposed() * sn[j]).normalized())
	for proxy: MeshInstance3D in proxies:
		var pv: PackedVector3Array = proxy.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
		var pn: PackedVector3Array = proxy.mesh.surface_get_arrays(0)[Mesh.ARRAY_NORMAL]
		for i in pv.size():
			_check(expected.has(pv[i]), "exact source/proxy vertex correspondence changed")
			if not expected.has(pv[i]):
				continue
			var normal_delta := INF
			for normal: Vector3 in expected[pv[i]]:
				normal_delta = minf(normal_delta, normal.distance_to(pn[i]))
			_max_normal_delta = maxf(_max_normal_delta, normal_delta)
			# Godot's octahedral normal re-encoding is lossy; vertices are exact.
			_check(normal_delta <= 0.0001, "copied normal exceeds 0.0001 packing tolerance")

func _check_cells(proxy: MeshInstance3D) -> void:
	var cell: Vector2i = proxy.get_meta("shadow_cell")
	var cell_size: float = proxy.get_meta("shadow_cell_size")
	_check(cell_size in [Batch.SHADOW_CELL, Batch.DENSE_SHADOW_CELL, Batch.BASELINE_DENSE_SHADOW_CELL], "unexpected shadow cell size")
	var vertices: PackedVector3Array = proxy.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	for first in range(0, vertices.size(), 3):
		var centre := (vertices[first] + vertices[first + 1] + vertices[first + 2]) / 3.0
		var actual := Vector2i(floori((centre.x + WorldBuilder.CHUNK_ORIGIN_X) / cell_size),
			floori((centre.z + WorldBuilder.CHUNK_ORIGIN_Z) / cell_size))
		_check(cell == actual, "shadow triangle escaped its spatial cell")

extends SceneTree

const BATCH := preload("res://src/environment_static_interiors.gd")
const ROOMS := preload("res://src/environment_interiors.gd")
var errors: Array[String] = []
var checks := 0
var actual_completed := false

func _initialize() -> void: _run.call_deferred()

func _run() -> void:
	if OS.get_cmdline_user_args().has("--light-native"):
		_native_lod_fixture()
		_native_world_guard_fixture()
		_native_bounds_fixture()
		for error: String in errors: printerr("native-candidate-light: "+error)
		print("native-candidate-light: %s (%d independent native buffer/boundary/camera checks)" % ["PASS" if errors.is_empty() else "FAIL",checks])
		quit(0 if errors.is_empty() else 1)
		return
	_geometry_fixture()
	_shadow_mesh_fixture()
	_admission_fixture()
	_named_fixture()
	_base_tbn_fixture()
	_double_sided_opaque_fixture()
	_spatial_fixture()
	_callback_fixture()
	_guard_fixture()
	_native_lod_fixture()
	_native_world_guard_fixture()
	_native_bounds_fixture()
	_native_stride_fixture()
	if OS.get_cmdline_user_args().has("--actual-main"):
		await _actual_main()
		_check(actual_completed,"actual protocol incomplete; SCRIPTERROR cannot count as PASS")
	for error: String in errors: printerr("test_environment_static_interiors: "+error)
	print("test_environment_static_interiors: %s (%d checks; geometry/UV2/COLOR, exact MaterialID, room/grid, all-surfaces, callbacks, ranges, quality, native physics)" % ["PASS" if errors.is_empty() else "FAIL",checks])
	quit(0 if errors.is_empty() else 1)

func _setup() -> Dictionary:
	var world := Node3D.new()
	root.add_child(world)
	var props := Props.new(Materials.new())
	props.root = Node3D.new()
	props.root.name = "props"
	world.add_child(props.root)
	return {"world":world,"props":props,"built":{"home":{"nodes":{}}}}

func _kitchen() -> Vector3:
	for room: Dictionary in ROOMS._rooms():
		if room["id"] == "kitchen":
			var b: Array = room["box"]
			return Vector3((b[0]+b[1])*.5,float(room["floor"])+.7,(b[2]+b[3])*.5)
	return Vector3.ZERO

func _material() -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = Color(.36,.24,.18)
	return material

func _hq_material() -> ShaderMaterial:
	var material := ShaderMaterial.new()
	material.shader = load(Materials.HQ_SHADER)
	material.set_shader_parameter("albedo",Color(.36,.24,.18))
	return material

func _mesh(materials: Array, width := .15) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for i in materials.size():
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(0,0,i*.02),Vector3(width,0,i*.02),Vector3(0,width,i*.02)])
		arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK,Vector3.BACK,Vector3.BACK])
		arrays[Mesh.ARRAY_TANGENT] = PackedFloat32Array([1,0,0,-1,1,0,0,1,1,0,0,-1])
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(.1,.2),Vector2(.7,.2),Vector2(.1,.9)])
		arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(.08,.13),Vector2(.27,.13),Vector2(.08,.4)])
		arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color(.2,.3,.4),Color(.4,.5,.6),Color(.6,.7,.8)])
		arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0,1,2])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		mesh.surface_set_material(i,materials[i])
	return mesh

func _holder(setup: Dictionary, label: String, materials: Array, position: Vector3) -> Node3D:
	var holder := Node3D.new()
	holder.name = label
	holder.position = position
	var mesh := MeshInstance3D.new()
	mesh.mesh = _mesh(materials)
	mesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mesh.visibility_range_end = 18.0
	mesh.visibility_range_end_margin = 1.0
	holder.add_child(mesh)
	setup["props"].root.add_child(holder)
	return holder

func _prepare(setup: Dictionary) -> BATCH.Controller:
	return BATCH.prepare(setup["world"],setup["built"],setup["props"])

func _sources(controller: BATCH.Controller) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for record: Dictionary in controller.records:
		for witness: Dictionary in record["witnesses"]: result.append(witness["source"])
	return result

func _proxies(controller: BATCH.Controller) -> Array[MeshInstance3D]:
	var result: Array[MeshInstance3D] = []
	for record: Dictionary in controller.records: result.append_array(record["proxies"])
	return result

func _geometry_fixture() -> void:
	var setup := _setup()
	var world: Node3D = setup["world"]
	world.transform = Transform3D(Basis(Vector3.UP,.27).scaled(Vector3(1.2,.9,1.1)),Vector3(7,3,-2))
	var common := _hq_material()
	var unique := _hq_material()
	unique.set_shader_parameter("roughness",.56)
	var clone := common.duplicate() as Material
	var a := _holder(setup,"fixture-a",[common,unique],_kitchen())
	var b := _holder(setup,"fixture-b",[common],_kitchen()+Vector3(.6,0,.2))
	var c := _holder(setup,"fixture-clone",[clone],_kitchen()+Vector3(-.5,0,-.2))
	a.rotation.y = .31
	a.scale = Vector3(.9,1.3,1.1)
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	body.add_child(shape)
	a.add_child(body)
	var sources: Array[MeshInstance3D] = [a.get_child(0),b.get_child(0),c.get_child(0)]
	var snapshot := _snapshot(sources)
	var controller := _prepare(setup)
	_check(controller.report["before"] == 4 and controller.report["after"] == 3 and controller.report["saved"] == 1,"all-surfaces or exact MaterialID accounting incorrect")
	_check(controller.report["sources"] == 3 and controller.report["triangles"] == 4,"source or triangle counts incorrect")
	_check(_prepare(setup) == controller,"prepare not idempotent")
	_check(body.get_parent() == a and shape.shape is BoxShape3D,"native physics moved or replaced")
	_check(controller.report["physics_mutations"] == 0 and controller.report["material_mutations"] == 0,"unexpected mutation report")
	_check(_geometry_equal(sources,_proxies(controller)),"world triangles, normals, UV/UV2/COLOR or MaterialID changed")
	var am: Dictionary = sources[0].get_meta("environment_static_batch_surfaces",{})
	var bm: Dictionary = sources[1].get_meta("environment_static_batch_surfaces",{})
	var cm: Dictionary = sources[2].get_meta("environment_static_batch_surfaces",{})
	_check(am.size() == 2 and am[0]["node"] == bm[0]["node"] and am[1]["node"] != am[0]["node"],"singleton surface lost or original mapping wrong")
	_check(cm[0]["node"] != am[0]["node"],"equivalent clone material was interned")
	for proxy: MeshInstance3D in _proxies(controller):
		_check(proxy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and proxy.get_child_count() == 0,"new proxy owns shadows, physics or gameplay")
		var pc := proxy.global_transform*proxy.custom_aabb.get_center()
		var padding: float = proxy.get_meta("range_padding")
		for source: MeshInstance3D in sources:
			for mapping: Dictionary in source.get_meta("environment_static_batch_surfaces",{}).values():
				if mapping["node"] == proxy:
					_check(pc.distance_to(source.global_transform*source.get_aabb().get_center()) <= padding+.00001,"range padding not conservative in world space")
		_check(is_equal_approx(proxy.visibility_range_end,18.0+padding) and proxy.visibility_range_begin == 0.0 and proxy.visibility_range_end_margin == 1.0,"native range or margin lost")
	_check(controller.validate() == 0,"unchanged fixture invalidated")
	_check(_snapshot(sources) == snapshot,"source geometry/material/UV data mutated")
	controller.restore()
	_check(controller.records.is_empty() and not world.has_meta(BATCH.META),"restore left records or world metadata")
	for source: MeshInstance3D in sources:
		_check(source.layers == 1 and not source.has_meta("environment_static_batch_surfaces"),"restore left original masked or mapping")
	_check(_snapshot(sources) == snapshot,"restore changed original mesh data")
	world.free()

func _admission_fixture() -> void:
	var setup := _setup()
	var material := _material()
	var a := _holder(setup,"safe-a",[material],_kitchen())
	var b := _holder(setup,"safe-b",[material],_kitchen()+Vector3(.2,0,0))
	var excluded: Array[Node3D] = []
	for label: String in ["named","pool","animation","skin","caster","hidden","mirror","range-begin","fade","metadata","transparent","margin"]:
		var holder := _holder(setup,label,[material],_kitchen()+Vector3(.4,0,0))
		var source := holder.get_child(0) as MeshInstance3D
		match label:
			"named": setup["props"].by_id["managed"] = holder
			"pool": setup["props"].dynamic_pool["pooled"] = holder
			"animation": holder.add_child(AnimationPlayer.new())
			"skin": source.skin = Skin.new()
			"caster": source.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			"hidden": holder.visible = false
			"mirror": holder.scale.x = -1.0
			"range-begin": source.visibility_range_begin = 2.0
			"fade": source.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
			"metadata": holder.set_meta("independent_visual",true)
			"transparent":
				var alpha := _material()
				alpha.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
				source.material_override = alpha
			"margin": source.extra_cull_margin = .1
		excluded.append(holder)
	var home := _holder(setup,"approved-home",[material],_kitchen()+Vector3(-.2,0,0))
	home.reparent(setup["world"],true)
	setup["built"]["home"]["nodes"]["kitchen-phone"] = home
	var door := _holder(setup,"managed-door",[material],_kitchen())
	door.reparent(setup["world"],true)
	setup["built"]["home"]["nodes"]["frontdoor"] = door
	var controller := _prepare(setup)
	_check(controller.report["before"] == 3 and controller.report["after"] == 1,"approved Home or anonymous cohort admission wrong")
	_check(a.get_child(0).layers == 0 and b.get_child(0).layers == 0 and home.get_child(0).layers == 0,"approved static source not masked")
	for holder: Node3D in excluded:
		_check(holder.get_child(0).layers == 1 and not holder.get_child(0).has_meta("environment_static_batch_surfaces"),"excluded owner batched: "+String(holder.name))
	_check(door.get_child(0).layers == 1,"managed Home door included")
	controller.restore()
	setup["world"].free()

func _base_tbn_fixture() -> void:
	var setup := _setup()
	var world: Node3D = setup["world"]
	world.basis = Basis.from_scale(Vector3(1.2,.9,1.1))
	var normalmap := _material()
	normalmap.normal_enabled = true
	var image := Image.create_empty(2,2,false,Image.FORMAT_RGB8)
	image.fill(Color(.7,.4,.9))
	normalmap.normal_texture = ImageTexture.create_from_image(image)
	var rejected: Array[Node3D] = []
	for label: String in ["normalmap-nonuniform-a","normalmap-nonuniform-b"]:
		var holder := _holder(setup,label,[normalmap],_kitchen())
		holder.scale = Vector3(2,1,.5)
		holder.rotation.y = .31
		rejected.append(holder)
	var relative := world.global_transform.affine_inverse()*rejected[0].global_transform
	var tangent := Vector3(1,1,0).normalized()
	_check(not relative.basis.is_conformal() and not (relative.basis*tangent).normalized().is_equal_approx((relative.basis.inverse().transposed()*tangent).normalized()),"TBN fixture does not distinguish GLES3 inverse-transpose from direct basis")
	var approved: Array[MeshInstance3D] = []
	for label: String in ["normalmap-conformal-a","normalmap-conformal-b"]:
		var holder := _holder(setup,label,[normalmap],_kitchen()+Vector3(.2,0,0))
		holder.scale = Vector3.ONE*1.3
		holder.rotation.y = .31
		approved.append(holder.get_child(0))
	var hq := _hq_material()
	for label: String in ["derivative-hq-a","derivative-hq-b"]:
		var holder := _holder(setup,label,[hq],_kitchen()+Vector3(.3,0,0))
		holder.scale = Vector3(2,1,.5)
		holder.rotation.y = .31
		approved.append(holder.get_child(0))
	var controller := _prepare(setup)
	_check(controller.report["before"] == 4 and controller.report["after"] == 2,"normalmapped nonconformal BaseMaterial admitted or conformal/HQ cohort rejected")
	for holder: Node3D in rejected: _check(holder.get_child(0).layers == 1,"nonconformal BaseMaterial normalmap source masked")
	for source: MeshInstance3D in approved: _check(source.layers == 0,"conformal BaseMaterial or nonuniform derivative HQ source not admitted")
	_check(_geometry_equal(approved,_proxies(controller)),"TBN admission changed approved geometry or attributes")
	controller.restore()
	world.free()

func _named_fixture() -> void:
	var setup := _setup()
	var world: Node3D = setup["world"]
	var props: Props = setup["props"]
	var common := _hq_material()
	var fridge := _holder(setup,"fridge",[common],_kitchen())
	var table := _holder(setup,"kitchen-table",[common],_kitchen()+Vector3(.4,0,0))
	fridge.rotation.y=.17;fridge.scale=Vector3(1.1,1.2,.9)
	props.by_id["fridge"]=fridge;props.by_id["kitchen-table"]=table
	props.notes["fridge"]={"def":{"id":"fridge"},"pos":fridge.position}
	props.notes["kitchen-table"]={"def":{"id":"kitchen-table"},"pos":table.position}
	var body := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	shape.shape=BoxShape3D.new();body.add_child(shape);fridge.add_child(body)
	var unapproved := _holder(setup,"grandma-trunk",[common],_kitchen()+Vector3(.3,0,0))
	props.by_id["grandma-trunk"]=unapproved
	var pooled := _holder(setup,"sofa",[common],_kitchen()+Vector3(.2,0,0))
	props.by_id["sofa"]=pooled;props.dynamic_pool["sofa"]=pooled
	var dynamic_id: String = GameData.props()["DYNAMIC_PROPS"][0]["id"]
	var dynamic := _holder(setup,dynamic_id,[common],_kitchen()+Vector3(.1,0,0))
	# An approved dictionary alias must not admit a DYNAMIC_PROPS root.
	props.by_id["stove"]=dynamic
	var runtime := _holder(setup,"coat-rack",[common],_kitchen()+Vector3(.1,0,.1))
	props.by_id["coat-rack"]=runtime;runtime.add_child(AnimationPlayer.new())
	var glass := _material();glass.transparency=BaseMaterial3D.TRANSPARENCY_ALPHA
	var wall_unit := _holder(setup,"wall-unit",[common,glass],_kitchen()+Vector3(.2,0,.1))
	props.by_id["wall-unit"]=wall_unit
	# A fully eligible isolated holder still yields no saving and stays native.
	var isolated := _holder(setup,"sewing-machine",[common],Vector3(103,.5,103))
	props.by_id["sewing-machine"]=isolated
	var sources: Array[MeshInstance3D]=[fridge.get_child(0),table.get_child(0)]
	var original := _snapshot(sources)
	var identities := _named_identity_snapshot(props)
	var physics := _physics_snapshot(world)
	var controller := _prepare(setup)
	_check(controller.report["named_authorized"]==28,"named whitelist count differs from approved contract")
	_check(controller.report["before"]==2 and controller.report["after"]==1 and controller.report["saved"]==1,"authorized named shared-material merge incorrect")
	_check(controller.report["named_present"].size()==7 and controller.report["named_candidates"].size()==5 and controller.report["named_eligible"].size()==3,"named candidate/eligibility census counts wrong")
	_check(controller.report["named_admitted"].size()==2 and controller.report["named_admitted"].has("fridge") and controller.report["named_admitted"].has("kitchen-table"),"named report counted uninstalled holders")
	_check(controller.report["named_unmerged"]==["sewing-machine"] and isolated.get_child(0).layers==1,"eligible singleton falsely reported installed or masked")
	_check(_geometry_equal(sources,_proxies(controller)) and _snapshot(sources)==original,"named merge changed world triangles, attributes or MaterialID")
	_check(props.get_prop("fridge")==fridge and props.get_prop("kitchen-table")==table and _named_identity_snapshot(props)==identities,"E-target lookup, named root ID, notes or pose changed")
	_check(body.get_parent()==fridge and _physics_snapshot(world)==physics,"named merge changed native physics or shape IDs")
	for holder: Node3D in [unapproved,pooled,dynamic,runtime,wall_unit]:
		_check(holder.get_child(0).layers==1 and not holder.get_child(0).has_meta("environment_static_batch_surfaces"),"unapproved, pooled, dynamic, runtime or partially transparent named root admitted: "+String(holder.name))
	_check(controller.report["named_rejected"].has("wall-unit") and wall_unit.get_child(0).mesh.get_surface_count()==2,"wall-unit transparent surface did not reject wholeholder")
	_check(controller.validate()==0,"unchanged named cohort invalidated")
	var proxy := _proxies(controller)[0]
	fridge.visible=false
	_check(not proxy.visible and sources[0].layers==1 and sources[1].layers==1,"named visibility callback failed atomic source restoration")
	_check(not fridge.visible and table.visible and props.get_prop("fridge")==fridge,"named callback changed story visibility or E-target root")
	fridge.visible=true
	_check(not proxy.visible and sources[0].layers==1,"invalidated named proxy revived")
	controller.restore()
	_check(_snapshot(sources)==original and _named_identity_snapshot(props)==identities and _physics_snapshot(world)==physics,"named restore changed original data, E-targets, pose or physics")
	world.free()

func _named_identity_snapshot(props: Props) -> PackedByteArray:
	var rows: Array=[]
	for id: String in BATCH.NAMED_STATIC:
		var holder: Node3D=props.get_prop(id)
		rows.append([id,holder.get_instance_id() if holder!=null else 0,
			holder.global_transform if holder!=null else Transform3D.IDENTITY,props.notes.get(id)])
	return var_to_bytes(rows)

func _shadow_mesh_fixture() -> void:
	var setup := _setup()
	var common := _material()
	var a := _holder(setup,"shadow-off-a",[common,common],_kitchen())
	var b := _holder(setup,"shadow-off-b",[common],_kitchen()+Vector3(.3,0,0))
	var caster := _holder(setup,"shadow-on",[common],_kitchen()+Vector3(.6,0,0))
	var source := a.get_child(0) as MeshInstance3D
	var shadow := _mesh([common],.45)
	var shadow_arrays := shadow.surface_get_arrays(0)
	shadow_arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([2,1,0])
	var shadow_fixture := ArrayMesh.new()
	shadow_fixture.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,shadow_arrays)
	shadow_fixture.surface_set_material(0,common)
	source.mesh.shadow_mesh = shadow_fixture
	caster.get_child(0).mesh.shadow_mesh = shadow_fixture
	caster.get_child(0).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var base_snapshot := _snapshot([source,b.get_child(0)])
	var shadow_snapshot := var_to_bytes(shadow_fixture.surface_get_arrays(0))
	var controller := _prepare(setup)
	_check(controller.report["before"] == 3 and controller.report["after"] == 1,"unused shadow mesh rejected or visible base surfaces lost")
	_check(source.layers == 0 and b.get_child(0).layers == 0,"shadow OFF sources not admitted")
	_check(caster.get_child(0).layers == 1 and not caster.get_child(0).has_meta("environment_static_batch_surfaces"),"shadow ON source admitted")
	_check(_geometry_equal([source,b.get_child(0)],_proxies(controller)),"shadow mesh replaced base positions/indices or attributes")
	var shadow_view := MeshInstance3D.new()
	shadow_view.mesh = shadow_fixture
	a.add_child(shadow_view)
	_check(not _geometry_equal([shadow_view,b.get_child(0)],_proxies(controller)),"base-vs-shadow fixture failed to distinguish different positions/indices")
	shadow_view.free()
	_check(source.mesh.shadow_mesh == shadow_fixture and caster.get_child(0).mesh.shadow_mesh == shadow_fixture,"source shadow_mesh identity changed")
	_check(var_to_bytes(shadow_fixture.surface_get_arrays(0)) == shadow_snapshot and _snapshot([source,b.get_child(0)]) == base_snapshot,"base or shadow buffer mutated")
	_check(controller.validate() == 0,"unchanged shadow OFF sources invalidated")
	controller.restore()
	_check(source.mesh.shadow_mesh == shadow_fixture and var_to_bytes(shadow_fixture.surface_get_arrays(0)) == shadow_snapshot,"restore changed retained shadow mesh")
	setup["world"].free()

func _spatial_fixture() -> void:
	var setup := _setup()
	var material := _material()
	var a := _holder(setup,"local-a",[material],Vector3(101,.5,101))
	var b := _holder(setup,"local-b",[material],Vector3(101.5,.5,101.5))
	var far := _holder(setup,"far",[material],Vector3(122,.5,122))
	var giant := _holder(setup,"giant",[material],Vector3(151,.5,151))
	giant.get_child(0).mesh = _mesh([material],9.0)
	var x := _holder(setup,"union-a",[material],Vector3(177.6,.5,180.1))
	var y := _holder(setup,"union-b",[material],Vector3(183.2,.5,180.1))
	x.get_child(0).mesh = _mesh([material],5.0)
	y.get_child(0).mesh = _mesh([material],5.0)
	var controller := _prepare(setup)
	_check(controller.report["before"] == 2 and controller.report["after"] == 1,"outside grid or union span guard incorrect")
	_check(a.get_child(0).layers == 0 and b.get_child(0).layers == 0,"nearby anonymous holders not batched")
	for holder: Node3D in [far,giant,x,y]: _check(holder.get_child(0).layers == 1,"far or >8m AABB merged")
	for proxy: MeshInstance3D in _proxies(controller): _check(BATCH._span(proxy.get_aabb()) <= BATCH.MAX_SPAN+.00001,"outside proxy exceeds bounded AABB")
	controller.restore()
	setup["world"].free()

func _callback_fixture() -> void:
	var setup := _setup()
	var material := _material()
	var a := _holder(setup,"a",[material],_kitchen())
	var b := _holder(setup,"b",[material],_kitchen()+Vector3(.2,0,0))
	var controller := _prepare(setup)
	var proxy := _proxies(controller)[0]
	a.visible = false
	_check(a.get_child(0).layers == 1 and b.get_child(0).layers == 1 and not proxy.visible,"holder visibility did not atomically restore native sources")
	_check(not a.visible and not a.get_child(0).is_visible_in_tree(),"story-hidden holder re-shown")
	a.visible = true
	_check(not proxy.visible and a.get_child(0).layers == 1,"invalidated proxy revived")
	controller.restore()
	controller = _prepare(setup)
	proxy = _proxies(controller)[0]
	b.free()
	_check(a.get_child(0).layers == 1 and not proxy.visible,"tree-exiting source left ghost geometry")
	controller.restore()
	var c := _holder(setup,"c",[material],_kitchen()+Vector3(.3,0,0))
	controller = _prepare(setup)
	var stale: BATCH.CallbackState = controller.states[0]
	controller.restore()
	var fresh := _prepare(setup)
	stale.invalidate()
	_check(a.get_child(0).layers == 0 and c.get_child(0).layers == 0 and _proxies(fresh)[0].visible,"retired callback changed a new batch")
	setup["props"].root.visible = false
	_check(a.get_child(0).layers == 1 and not _proxies(fresh)[0].visible and not a.is_visible_in_tree(),"parent visibility not guarded")
	fresh.restore()
	setup["world"].free()

func _double_sided_opaque_fixture() -> void:
	for path: String in [Materials.HQ_ALPHA_SHADER,Materials.HQ_OPAQUE_ALPHA_SHADER]:
		var setup := _setup()
		var material := ShaderMaterial.new()
		material.shader = load(path)
		material.set_shader_parameter("albedo",Color(.5,.4,.3,1))
		material.set_shader_parameter("alpha_cut",0.0)
		var a := _holder(setup,"a",[material],_kitchen())
		var b := _holder(setup,"b",[material],_kitchen()+Vector3(.2,0,0))
		var controller := _prepare(setup)
		_check(controller.report["saved"] == 1,"double-sided opaque sources rejected")
		_check(_geometry_equal(_sources(controller),_proxies(controller)),"double-sided opaque geometry/UV/material differs")
		_check(_proxies(controller)[0].material_override == material,"double-sided material identity/cull lost")
		controller.restore()
		material.set_shader_parameter("alpha_cut",.4)
		controller = _prepare(setup)
		_check(controller.report["saved"] == 0 and a.get_child(0).layers == 1 and b.get_child(0).layers == 1,"masked double-sided sources admitted")
		controller.restore()
		setup["world"].free()

func _guard_fixture() -> void:
	for mutation: String in ["pose","tiny-basis","layers","material","range","mesh-change","quality"]:
		var setup := _setup()
		var material := ShaderMaterial.new()
		material.shader = load(Materials.HQ_SHADER)
		material.set_shader_parameter("albedo",Color(.5,.4,.3))
		var a := _holder(setup,"a",[material],_kitchen())
		var b := _holder(setup,"b",[material],_kitchen()+Vector3(.2,0,0))
		var source := a.get_child(0) as MeshInstance3D
		var controller := _prepare(setup)
		var proxy := _proxies(controller)[0]
		match mutation:
			"pose": a.position.x += .01
			"tiny-basis": a.basis = Basis(Vector3.UP,.000001)
			"layers": source.layers = 8
			"material": source.material_override = _material()
			"range": source.visibility_range_end = 11.0
			"mesh-change": source.mesh.surface_set_material(0,_material())
			"quality":
				material.shader = load(Materials.PSX_SHADER)
				_check(proxy.material_override == material and controller.validate() == 0 and proxy.visible,"HQ->retro lost shared MaterialID or invalidated")
				material.shader = load(Materials.HQ_SHADER)
		if mutation == "quality":
			_check(controller.validate() == 0 and proxy.visible,"retro->HQ failed")
		else:
			controller.validate()
			_check(not proxy.visible and b.get_child(0).layers == 1,"changed source did not restore native bucket: "+mutation)
			_check(source.layers == (8 if mutation == "layers" else 1),"external layers or native restoration overwritten: "+mutation)
		controller.restore()
		setup["world"].free()

func _snapshot(sources: Array[MeshInstance3D]) -> PackedByteArray:
	var result: Array = []
	for source: MeshInstance3D in sources:
		var surfaces: Array = []
		for i in source.mesh.get_surface_count():
			var native: Array = source.mesh.get("_surfaces")[i].get("lods",[]) if source.mesh is ArrayMesh else []
			surfaces.append([source.mesh.surface_get_arrays(i),source.get_active_material(i).get_instance_id(),native])
		result.append([source.mesh.get_instance_id(),surfaces])
	return var_to_bytes(result)

func _triangles(sources: Array[MeshInstance3D]) -> Array:
	var result: Array = []
	for source: MeshInstance3D in sources:
		for surface in source.mesh.get_surface_count():
			var arrays := source.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
			if indices.is_empty():
				for i in vertices.size(): indices.append(i)
			for i in range(0,indices.size(),3):
				var triangle: Array = []
				for j in 3:
					var index := indices[i+j]
					var point := source.global_transform*vertices[index]
					var uv: Vector2 = arrays[Mesh.ARRAY_TEX_UV][index] if arrays[Mesh.ARRAY_TEX_UV] != null else Vector2.ZERO
					var uv2: Vector2 = arrays[Mesh.ARRAY_TEX_UV2][index] if arrays[Mesh.ARRAY_TEX_UV2] != null else Vector2.ZERO
					var color: Color = arrays[Mesh.ARRAY_COLOR][index] if arrays[Mesh.ARRAY_COLOR] != null else Color.WHITE
					var normal := Vector3.ZERO
					if arrays[Mesh.ARRAY_NORMAL] != null:
						normal = (source.global_basis.inverse().transposed()*arrays[Mesh.ARRAY_NORMAL][index]).normalized()
					var tangent := Vector4.ZERO
					if arrays[Mesh.ARRAY_TANGENT] != null and not arrays[Mesh.ARRAY_TANGENT].is_empty():
						var t: PackedFloat32Array = arrays[Mesh.ARRAY_TANGENT]
						var vector := (source.global_basis*Vector3(t[index*4],t[index*4+1],t[index*4+2])).normalized()
						tangent = Vector4(vector.x,vector.y,vector.z,t[index*4+3])
					triangle.append([point,uv,uv2,color,normal,tangent])
				result.append({"material":source.get_active_material(surface),"vertices":triangle})
	return result

func _geometry_equal(native: Array[MeshInstance3D], merged: Array[MeshInstance3D]) -> bool:
	var a := _triangles(native)
	var b := _triangles(merged)
	if a.size() != b.size(): return false
	var buckets: Dictionary = {}
	for i in b.size():
		var cell := _triangle_cell(b[i])
		var key := str(b[i]["material"].get_instance_id())+":"+str(cell)
		if not buckets.has(key): buckets[key] = []
		buckets[key].append(i)
	var used: Dictionary = {}
	for triangle: Dictionary in a:
		var matched := false
		var choices: Array = []
		var cell := _triangle_cell(triangle)
		for x in range(-1,2):
			for y in range(-1,2):
				for z in range(-1,2):
					var key := str(triangle["material"].get_instance_id())+":"+str(cell+Vector3i(x,y,z))
					choices.append_array(buckets.get(key,[]))
		for i: int in choices:
			if used.has(i) or triangle["material"] != b[i]["material"]: continue
			var same := true
			for vertex in 3:
				var x: Array = triangle["vertices"][vertex]
				var y: Array = b[i]["vertices"][vertex]
				var tangent_delta := Vector3(x[5].x-y[5].x,x[5].y-y[5].y,x[5].z-y[5].z)
				if x[0].distance_to(y[0]) > .00001 or x[1] != y[1] or x[2] != y[2] or x[3] != y[3] or x[4].distance_to(y[4]) > .0002 or tangent_delta.length() > .0002 or x[5].w != y[5].w:
					same = false
					break
			if same:
				used[i] = true
				matched = true
				break
		if not matched: return false
	return true

func _triangle_cell(triangle: Dictionary) -> Vector3i:
	var center: Vector3 = (triangle["vertices"][0][0]+triangle["vertices"][1][0]+triangle["vertices"][2][0])/3.0
	return Vector3i(floori(center.x/.25),floori(center.y/.25),floori(center.z/.25))

func _actual_main() -> void:
	var main: Node = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	var started := Time.get_ticks_msec()
	while not bool(main.get("boot_ready")) and Time.get_ticks_msec()-started < 120000: await process_frame
	_check(bool(main.get("boot_ready")),"actual main boot timed out")
	if not bool(main.get("boot_ready")): main.free(); return
	main.set_process(false)
	var renderer: RenderChain = main.get("render_chain")
	renderer.apply_preset("hq")
	var world := renderer.world_root
	var production: Variant = world.get_meta("environment_static_interiors",null)
	if production != null: production.restore()
	var saved_state: Variant = main.get("state").snapshot()
	var native_physics := _physics_snapshot(world)
	var props: Props = main.get("props")
	var named_identities := _named_identity_snapshot(props)
	var controller := BATCH.prepare(world,main.get("built"),main.get("props"))
	var sources := _sources(controller)
	var snapshot := _snapshot(sources)
	_check(controller.report["saved"] >= 50,"candidate cohort below approved bound50")
	_check(controller.report["named_present"].size()==28,"actual named whitelist roots missing")
	_check(controller.report["named_rejected"].has("wall-unit"),"actual transparent wall-unit was not rejected as a whole holder")
	_check(_named_identity_snapshot(props)==named_identities,"actual named IDs, E-target lookup, notes or pose changed")
	_check(_geometry_equal(sources,_proxies(controller)),"actual worldtri/normals/UV2/COLOR/MaterialID multiset changed")
	_check(controller.validate() == 0,"actual initial immutable cohort invalidated")
	var native_report := _actual_lod_protocol(controller)
	renderer.apply_preset("retro")
	_check(controller.validate() == 0,"actual retro quality invalidated")
	renderer.apply_preset("hq")
	_check(controller.validate() == 0,"actual HQ quality invalidated")
	_check(_snapshot(sources) == snapshot,"actual source geometry/material identity changed")
	_check(native_physics == _physics_snapshot(world),"actual native physics topology/pose/layers changed")
	_check(saved_state == main.get("state").snapshot(),"actual story/decor/checkpoint state drifted")
	_check(_named_identity_snapshot(props)==named_identities,"actual quality roundtrip changed named roots or E-target lookup")
	print("static-interiors actual: ",JSON.stringify(controller.report))
	print("native-candidate actual protocol: ",JSON.stringify(native_report))
	# Exercise a real native-containing bucket, then rebuild after owned restore.
	var callback_checked := false
	for record: Dictionary in controller.records:
		for witness: Dictionary in record["witnesses"]:
			var source: MeshInstance3D = witness["source"]
			var has_lod := false
			if source.mesh is ArrayMesh:
				for raw: Dictionary in source.mesh.get("_surfaces"):
					if not raw.get("lods",[]).is_empty(): has_lod = true
			if not has_lod: continue
			var visible_saved := source.visible
			source.visible = false
			_check(not bool(record["active"]) and not source.is_visible_in_tree(),"actual native source hide did not invalidate or re-showed source")
			for proxy: MeshInstance3D in record["proxies"]: _check(not proxy.visible,"actual native callback left proxy visible")
			for peer: Dictionary in record["witnesses"]:
				_check(peer["source"].layers == peer["flags"][0] and not peer["source"].has_meta("environment_static_batch_surfaces"),"actual native callback failed whole-bucket ownership restore")
			source.visible = visible_saved
			callback_checked = true
			break
		if callback_checked: break
	_check(callback_checked,"actual cohort lacked native callback witness")
	controller.restore()
	_check(_snapshot(sources) == snapshot and native_physics == _physics_snapshot(world),"actual final restore changed original data or physics")
	var fresh := BATCH.prepare(world,main.get("built"),main.get("props"))
	_check(fresh.report["saved"] >= 50 and fresh.validate() == 0,"actual repeated prepare not stable")
	fresh.restore()
	_check(saved_state == main.get("state").snapshot(),"actual callbacks/rebuild changed state")
	_check(_named_identity_snapshot(props)==named_identities,"actual restore/rebuild changed named IDs, notes or pose")
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--output="):
			var out := FileAccess.open(argument.trim_prefix("--output="),FileAccess.WRITE)
			if out != null:
				out.store_string(JSON.stringify({"batch":controller.report,"native_protocol":native_report,"errors":errors,"checks":checks,"gpu_measured":false},"\t")+"\n")
				out.close()
	actual_completed = true
	main.free()

func _physics_snapshot(world: Node3D) -> PackedByteArray:
	var result: Array = []
	var nodes: Array[Node] = [world]
	var cursor := 0
	while cursor < nodes.size():
		var node: Node = nodes[cursor]
		cursor += 1
		nodes.append_array(node.get_children())
		if node is CollisionObject3D:
			result.append([node.get_instance_id(),node.global_transform,node.collision_layer,node.collision_mask])
		elif node is CollisionShape3D:
			result.append([node.get_instance_id(),node.global_transform,node.disabled,0 if node.shape == null else node.shape.get_instance_id()])
	return var_to_bytes(result)

func _actual_definition(mesh: Mesh, surface: int) -> Dictionary:
	var arrays := mesh.surface_get_arrays(surface)
	var vertices: int = arrays[Mesh.ARRAY_VERTEX].size()
	var base: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if base.is_empty():
		for i in vertices: base.append(i)
	var levels: Dictionary = {}
	if mesh is ArrayMesh:
		var raw: Dictionary = mesh.get("_surfaces")[surface]
		var bytes: PackedByteArray = raw.get("index_data",PackedByteArray())
		var count: int = raw.get("index_count",0)
		var width: int = bytes.size()/count if count > 0 else (2 if vertices <= 65536 else 4)
		var pairs: Array = raw.get("lods",[])
		for pair in range(0,pairs.size(),2):
			var data: PackedByteArray = pairs[pair+1]
			var ids := PackedInt32Array()
			for offset in range(0,data.size(),width): ids.append(data.decode_u16(offset) if width == 2 else data.decode_u32(offset))
			levels[float(pairs[pair])] = ids
	return {"vertices":vertices,"base":base,"levels":levels}

func _actual_lod_protocol(controller: BATCH.Controller) -> Dictionary:
	var report := {"proxies":0,"native_sources":0,"native_surfaces":0,"source_lod_buffers":0,"proxy_lod_buffers":0,"camera_cases":0,"worst_near_triangles":0,"selected_triangles":[]}
	var native_sources: Dictionary = {}
	var cameras: Array = []
	for point: Dictionary in preload("res://tests/bench_render.gd").POINTS:
		cameras.append({"id":point["name"],"eye":point["pos"]+Vector3(0,Player.STAND_HEIGHT-Player.EYE_DROP,0)})
	var rng := RandomNumberGenerator.new()
	rng.seed = 79131
	for record: Dictionary in controller.records:
		for proxy: MeshInstance3D in record["proxies"]:
			var sources: Array[MeshInstance3D] = []
			var definitions: Array = []
			for witness: Dictionary in record["witnesses"]:
				var source: MeshInstance3D = witness["source"]
				var mapping: Dictionary = source.get_meta("environment_static_batch_surfaces",{})
				var selected: Array = []
				for surface in source.mesh.get_surface_count():
					if mapping.get(surface,{}).get("node") != proxy: continue
					var definition := _actual_definition(source.mesh,surface)
					selected.append(definition)
					if not definition["levels"].is_empty():
						native_sources[source] = true
						report["native_surfaces"] += 1
						report["source_lod_buffers"] += definition["levels"].size()
				if not selected.is_empty(): sources.append(source); definitions.append(selected)
			report["proxies"] += 1
			var levels := _proxy_levels(proxy.mesh)
			report["proxy_lod_buffers"] += levels.size()
			for level: Dictionary in levels:
				_check(level["indices"] == _expected_at_union_key(definitions,sources,proxy,level["q"]),"actual native combined key buffer differs from source oracle")
			for flag: String in BATCH.FLAGS:
				if flag in ["visibility_range_end","layers"]: continue
				_check(proxy.get(flag) == sources[0].get(flag),"actual native renderer flag differs: "+flag)
			_check(proxy.layers == 1 and proxy.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and proxy.extra_cull_margin == 0.0,"actual native render mask/shadow/margin incorrect")
			var center := proxy.global_transform*proxy.custom_aabb.get_center()
			for camera: Dictionary in cameras:
				_probe_selection(definitions,sources,proxy,camera["eye"],1.0,1.0,false)
				report["camera_cases"] += 1
			for i in 16:
				var direction := Vector3(rng.randf_range(-1,1),rng.randf_range(-1,1),rng.randf_range(-1,1)).normalized()
				_probe_selection(definitions,sources,proxy,center+direction*rng.randf_range(1,60),rng.randf_range(.001,1.5),rng.randf_range(.25,2.0),false)
				report["camera_cases"] += 1
			for orthographic: bool in [false,true]:
				for threshold: float in [0.0,.01,1.0]:
					_probe_selection(definitions,sources,proxy,center,threshold,1.0,orthographic)
					report["camera_cases"] += 1
			for level: Dictionary in levels:
				for delta: float in [-.000001,0.0,.000001]:
					var threshold := _oracle_screen(level["q"],_independent_scale(proxy),proxy.lod_bias,1.0,1.0)*(1.0+delta)
					_probe_selection(definitions,sources,proxy,center,threshold,1.0,true)
					report["camera_cases"] += 1
			report["worst_near_triangles"] += proxy.mesh.get_faces().size()/3
	report["native_sources"] = native_sources.size()
	return report

## These definitions are the independent oracle. They never call candidate
## native-buffer decoding, normalization or its selection implementation.
func _lod_surface(vertices: int, base: PackedInt32Array, levels: Dictionary) -> Dictionary:
	var native: Dictionary = {}
	for edge: float in levels: native[PackedFloat32Array([edge])[0]] = levels[edge]
	return {"vertices":vertices,"base":base,"levels":native}

func _lod_mesh(definitions: Array, material: Material, id_start := 0) -> ArrayMesh:
	var result := ArrayMesh.new()
	var identity := id_start
	for definition: Dictionary in definitions:
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		var v := PackedVector3Array()
		var n := PackedVector3Array()
		var t := PackedFloat32Array()
		var uv := PackedVector2Array()
		var uv2 := PackedVector2Array()
		var color := PackedColorArray()
		for i in int(definition["vertices"]):
			var tri := floori(float(i)/3.0)
			var point := Vector3(.06,0,0) if i%3 == 1 else (Vector3(0,.05,0) if i%3 == 2 else Vector3.ZERO)
			v.append(point+Vector3(float(tri%3)*.01,0,float(tri%5)*.04))
			n.append(Vector3.BACK)
			t.append_array(PackedFloat32Array([1,0,0,-1 if i%2 == 0 else 1]))
			uv.append(Vector2(identity,.25))
			uv2.append(Vector2(float(i%7)/8.0,float(i%11)/12.0))
			color.append(Color(float(i%5)/5.0,.4,.7))
			identity += 1
		arrays[Mesh.ARRAY_VERTEX] = v
		arrays[Mesh.ARRAY_NORMAL] = n
		arrays[Mesh.ARRAY_TANGENT] = t
		arrays[Mesh.ARRAY_TEX_UV] = uv
		arrays[Mesh.ARRAY_TEX_UV2] = uv2
		arrays[Mesh.ARRAY_COLOR] = color
		arrays[Mesh.ARRAY_INDEX] = definition["base"]
		result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],definition["levels"])
		result.surface_set_material(result.get_surface_count()-1,material)
	return result

func _independent_scale(node: Node3D) -> float:
	return maxf(node.global_basis.x.length(),maxf(node.global_basis.y.length(),node.global_basis.z.length()))

func _renderer_distance(bounds: AABB, camera: Vector3, orthographic: bool) -> float:
	if orthographic: return 1.0
	var minimum := bounds.position
	var maximum := bounds.end
	var closest := Vector3(clampf(camera.x,minimum.x,maximum.x),clampf(camera.y,minimum.y,maximum.y),clampf(camera.z,minimum.z,maximum.z))
	return camera.distance_to(closest)

func _oracle_screen(edge: float, scale: float, bias: float, distance: float, multiplier: float) -> float:
	var factor: float = PackedFloat32Array([scale*bias])[0]
	var numerator: float = PackedFloat32Array([edge*factor])[0]
	var denominator: float = PackedFloat32Array([distance*multiplier])[0]
	return PackedFloat32Array([numerator/denominator])[0]

func _oracle_key(edge: float, source: MeshInstance3D, proxy: MeshInstance3D) -> float:
	# Independent public float32 representation, without candidate helpers.
	var source_factor: float = PackedFloat32Array([_independent_scale(source)*source.lod_bias])[0]
	var target: float = PackedFloat32Array([edge*source_factor])[0]
	var proxy_factor: float = PackedFloat32Array([_independent_scale(proxy)*proxy.lod_bias])[0]
	var exact := target/proxy_factor
	var q: float = PackedFloat32Array([exact])[0]
	while q < exact or PackedFloat32Array([q*proxy_factor])[0] < target:
		var packed := PackedFloat32Array([q]).to_byte_array()
		var bits := packed.decode_u32(0)
		packed.encode_u32(0,bits+1)
		q = packed.decode_float(0)
	return q

func _source_selected(definition: Dictionary, source: MeshInstance3D, camera: Vector3, threshold: float, multiplier: float, orthographic: bool) -> PackedInt32Array:
	var edge := _source_edge(definition,source,camera,threshold,multiplier,orthographic)
	return definition["base"] if edge < 0.0 else definition["levels"][edge]

func _source_edge(definition: Dictionary, source: MeshInstance3D, camera: Vector3, threshold: float, multiplier: float, orthographic: bool) -> float:
	var selected := -1.0
	if threshold <= 0.0: return selected
	var distance := _renderer_distance(source.global_transform*source.mesh.get_aabb(),camera,orthographic)
	if distance <= 0.0: return selected
	var keys: Array = definition["levels"].keys()
	keys.sort()
	for edge: float in keys:
		# Official GLES3 predicate uses > to break; equality selects this LOD.
		if _oracle_screen(edge,_independent_scale(source),source.lod_bias,distance,multiplier) > PackedFloat32Array([threshold])[0]: break
		selected = edge
	return selected

func _proxy_levels(mesh: ArrayMesh) -> Array:
	var raw: Dictionary = mesh.get("_surfaces")[0]
	var pairs: Array = raw.get("lods",[])
	var index_count: int = raw["index_count"]
	var index_data: PackedByteArray = raw["index_data"]
	var stride: int = index_data.size()/index_count
	var result: Array = []
	for i in range(0,pairs.size(),2):
		var bytes: PackedByteArray = pairs[i+1]
		var indices := PackedInt32Array()
		for at in range(0,bytes.size(),stride):
			indices.append(bytes.decode_u16(at) if stride == 2 else bytes.decode_u32(at))
		result.append({"q":float(pairs[i]),"indices":indices,"stride":stride})
	result.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return float(a["q"]) < float(b["q"]))
	return result

func _selected_proxy(proxy: MeshInstance3D, camera: Vector3, threshold: float, multiplier: float, orthographic: bool) -> Dictionary:
	var indices: PackedInt32Array = proxy.mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX]
	var result := {"q":-1.0,"indices":indices}
	if threshold <= 0.0: return result
	var distance := _renderer_distance(proxy.global_transform*proxy.custom_aabb,camera,orthographic)
	if distance <= 0.0: return result
	for level: Dictionary in _proxy_levels(proxy.mesh):
		if _oracle_screen(float(level["q"]),_independent_scale(proxy),proxy.lod_bias,distance,multiplier) > PackedFloat32Array([threshold])[0]: break
		result = {"q":level["q"],"indices":level["indices"]}
	return result

func _expected_at_union_key(definitions: Array, sources: Array[MeshInstance3D], proxy: MeshInstance3D, q: float) -> PackedInt32Array:
	var indices := PackedInt32Array()
	var offset := 0
	for owner in sources.size():
		var source: MeshInstance3D = sources[owner]
		for definition: Dictionary in definitions[owner]:
			var selected: PackedInt32Array = definition["base"]
			var keys: Array = definition["levels"].keys()
			keys.sort()
			if q >= 0.0:
				for edge: float in keys:
					if _oracle_key(edge,source,proxy) > q: break
					selected = definition["levels"][edge]
			for index: int in selected: indices.append(offset+index)
			offset += int(definition["vertices"])
	return indices

func _probe_selection(definitions: Array, sources: Array[MeshInstance3D], proxy: MeshInstance3D, camera: Vector3, threshold: float, multiplier: float, orthographic: bool) -> void:
	var selected := _selected_proxy(proxy,camera,threshold,multiplier,orthographic)
	var expected := _expected_at_union_key(definitions,sources,proxy,selected["q"])
	_check(selected["indices"] == expected,"native union index buffer differs from independent expected source-level concatenation")
	var proxy_distance := _renderer_distance(proxy.global_transform*proxy.custom_aabb,camera,orthographic)
	var cursor := 0
	for owner in sources.size():
		var source: MeshInstance3D = sources[owner]
		var source_distance := _renderer_distance(source.global_transform*source.mesh.get_aabb(),camera,orthographic)
		_check((proxy.global_transform*proxy.custom_aabb).encloses(source.global_transform*source.mesh.get_aabb()),"effective float32 proxy bounds do not exactly enclose full source bounds")
		_check(proxy_distance <= source_distance,"proxy bounds distance exceeds original full source AABB distance")
		for definition: Dictionary in definitions[owner]:
			var own_selected := _source_selected(definition,source,camera,threshold,multiplier,orthographic)
			var own_edge := _source_edge(definition,source,camera,threshold,multiplier,orthographic)
			var merged_selected: PackedInt32Array = definition["base"]
			var merged_edge := -1.0
			var keys: Array = definition["levels"].keys()
			keys.sort()
			if selected["q"] >= 0.0:
				for edge: float in keys:
					if _oracle_key(edge,source,proxy) > float(selected["q"]): break
					merged_selected = definition["levels"][edge]
					merged_edge = edge
			_check(merged_edge <= own_edge,"merged native edge rank coarser than original source choice")
			_check(merged_selected.size() >= own_selected.size(),"merged LOD coarser than native source")
			# Float32 rounding may choose the immediately finer native level at
			# an exact boundary. It may never choose a coarser level.
			cursor += int(definition["vertices"])

func _native_lod_fixture() -> void:
	for bias: float in [.5,1.0,2.0]:
		var setup := _setup()
		var world: Node3D = setup["world"]
		world.transform = Transform3D(Basis(Vector3.UP,.23).scaled(Vector3(1.2,.9,1.1)),Vector3(7,3,-2))
		var material := _hq_material()
		var a := _holder(setup,"native-a",[material],_kitchen())
		var b := _holder(setup,"native-b",[material],_kitchen()+Vector3(.65,.1,.2))
		a.scale = Vector3(1.4,1.1,.8)
		a.rotation.y = .33
		b.scale = Vector3(.75,1.8,1.2)
		b.rotation.y = -.17
		var definitions: Array = [
			[_lod_surface(6,PackedInt32Array([0,1,2,3,4,5]),{.2:PackedInt32Array([0,1,2])}),
			_lod_surface(9,PackedInt32Array([0,1,2,3,4,5,6,7,8]),{.4:PackedInt32Array([0,1,2,3,4,5]),1.2:PackedInt32Array([0,1,2])})],
			[_lod_surface(3,PackedInt32Array([0,1,2]),{}),
			_lod_surface(15,PackedInt32Array([0,1,2,3,4,5,6,7,8,9,10,11,12,13,14]),{.1:PackedInt32Array([0,1,2,3,4,5,6,7,8,9,10,11]),.5:PackedInt32Array([0,1,2,3,4,5]),1.0:PackedInt32Array([0,1,2])})]]
		var sources: Array[MeshInstance3D] = [a.get_child(0),b.get_child(0)]
		for i in sources.size():
			sources[i].mesh = _lod_mesh(definitions[i],material,i*1000)
			sources[i].lod_bias = bias
		var snapshot := _snapshot(sources)
		var controller := _prepare(setup)
		_check(controller.report["before"] == 4 and controller.report["after"] == 1,"native+fallback/noLOD surfaces not combined")
		if _proxies(controller).is_empty(): controller.restore(); world.free(); continue
		var proxy := _proxies(controller)[0]
		_check(proxy.extra_cull_margin == 0.0 and proxy.custom_aabb.size != Vector3.ZERO,"proxy full custom AABB missing")
		_check(_geometry_equal(sources,[proxy]),"native near geometry/NORMAL/TANGENT/UV2/COLOR changed")
		var expected_keys: Array = []
		for owner in sources.size():
			for definition: Dictionary in definitions[owner]:
				for edge: float in definition["levels"]:
					var q: float = _oracle_key(edge,sources[owner],proxy)
					if not expected_keys.has(q): expected_keys.append(q)
		expected_keys.sort()
		var levels := _proxy_levels(proxy.mesh)
		_check(levels.size() == expected_keys.size(),"union normalized keys dropped or duplicated")
		for i in mini(levels.size(),expected_keys.size()):
			_check(is_equal_approx(float(levels[i]["q"]),float(expected_keys[i])),"normalized LOD scale key incorrect")
			_check(levels[i]["indices"] == _expected_at_union_key(definitions,sources,proxy,levels[i]["q"]),"direct expected merged index buffer mismatch")
		var center := proxy.global_transform*proxy.custom_aabb.get_center()
		# Deterministic camera paths and independent random cameras, 1..60m.
		var rng := RandomNumberGenerator.new()
		rng.seed = 71209
		for i in (16 if OS.get_cmdline_user_args().has("--light-native") else 128):
			var direction := Vector3(rng.randf_range(-1,1),rng.randf_range(-1,1),rng.randf_range(-1,1)).normalized()
			var camera := center+direction*rng.randf_range(1.0,60.0)
			_probe_selection(definitions,sources,proxy,camera,rng.randf_range(.002,2.0),rng.randf_range(.25,2.0),false)
		for i in range(0,61,5 if OS.get_cmdline_user_args().has("--light-native") else 1):
			_probe_selection(definitions,sources,proxy,center+Vector3(float(i),.3,2),.05,1.0,false)
		for ortho: bool in [false,true]:
			for threshold: float in [0.0,.02,.5,2.0]:
				_probe_selection(definitions,sources,proxy,center,threshold,1.0,ortho)
		# Edge equality and either side must use native >-break semantics.
		for level: Dictionary in levels:
			for epsilon: float in [-.000001,0.0,.000001]:
				var threshold := float(level["q"])*_independent_scale(proxy)*bias*(1.0+epsilon)
				_probe_selection(definitions,sources,proxy,center+Vector3(20,0,0),threshold,1.0,true)
		_check(controller.validate() == 0 and _snapshot(sources) == snapshot,"native source buffers/pose changed")
		controller.restore()
		_check(_snapshot(sources) == snapshot,"native restore changed source base/LOD buffers")
		world.free()

func _native_world_guard_fixture() -> void:
	var setup := _setup()
	var world: Node3D = setup["world"]
	world.basis = Basis.from_scale(Vector3(2,1,1))
	var material := _material()
	var definition := _lod_surface(6,PackedInt32Array([0,1,2,3,4,5]),{.2:PackedInt32Array([0,1,2])})
	var a := _holder(setup,"world-native-a",[material],_kitchen())
	var b := _holder(setup,"world-native-b",[material],_kitchen()+Vector3(.3,0,0))
	a.rotation.y = PI*.25
	b.rotation.y = PI*.25
	for holder: Node3D in [a,b]: holder.get_child(0).mesh = _lod_mesh([definition],material)
	# A second active bucket proves the world guard restores every group.
	var c := _holder(setup,"world-other-a",[material],Vector3(40,2,40))
	var d := _holder(setup,"world-other-b",[material],Vector3(40.3,2,40))
	var source := a.get_child(0) as MeshInstance3D
	var controller := _prepare(setup)
	_check(controller.records.size() == 2 and controller.validate() == 0,"world guard fixture lacks two unchanged active buckets")
	var old_proxy: MeshInstance3D = source.get_meta("environment_static_batch_surfaces")[0]["node"]
	var old_q: float = _proxy_levels(old_proxy.mesh)[0]["q"]
	var relative := world.global_transform.affine_inverse()*source.global_transform
	world.basis = Basis.IDENTITY
	_check(world.global_transform.affine_inverse()*source.global_transform == relative,"world scale mutation changed relative source pose; guard fixture invalid")
	_check(controller.validate() == controller.records.size(),"changed world basis did not atomically invalidate all groups")
	for record: Dictionary in controller.records:
		_check(not bool(record["active"]),"world transform guard left active group")
		for proxy: MeshInstance3D in record["proxies"]: _check(not proxy.visible,"world transform guard left active proxy")
	for holder: Node3D in [a,b,c,d]:
		var mesh := holder.get_child(0) as MeshInstance3D
		_check(mesh.layers == 1 and not mesh.has_meta("environment_static_batch_surfaces"),"world transform guard did not restore original layers/mapping")
	_check(controller.validate() == 0,"world transform guard invalidated an inactive bucket twice")
	controller.restore()
	var fresh := _prepare(setup)
	var proxy: MeshInstance3D = source.get_meta("environment_static_batch_surfaces")[0]["node"]
	var q: float = _proxy_levels(proxy.mesh)[0]["q"]
	_check(q != old_q and q == _oracle_key(.2,source,proxy),"fresh prepare reused stale world model-scale key")
	_check(fresh.validate() == 0 and _geometry_equal(_sources(fresh),_proxies(fresh)),"fresh world prepare changed near geometry or immutable state")
	_probe_selection([[definition],[definition]],[source,b.get_child(0)],proxy,Vector3(15,2,15),.19,1.0,true)
	fresh.restore()
	world.free()

func _native_bounds_fixture() -> void:
	for transformed: bool in [false,true]:
		var setup := _setup()
		var world: Node3D = setup["world"]
		if transformed:
			world.transform = Transform3D(Basis(Vector3.UP,.37).scaled(Vector3(2,.8,1.3)),Vector3(31.07,2.03,-45.07))
		var material := _material()
		var definition := _lod_surface(6,PackedInt32Array([0,1,2,3,4,5]),{.2:PackedInt32Array([0,1,2])})
		var sources: Array[MeshInstance3D] = []
		for label: String in ["ulp-a","ulp-b"]:
			var holder := _holder(setup,label,[material],Vector3.ZERO)
			var source := holder.get_child(0) as MeshInstance3D
			var mesh := _lod_mesh([definition],material)
			var arrays := mesh.surface_get_arrays(0)
			arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3(.07,0,.07),Vector3(4,0,.07),Vector3(.07,.15,.17),Vector3(.07,0,.07),Vector3(4,0,.07),Vector3(.07,.15,.17)])
			var replacement := ArrayMesh.new()
			replacement.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],{.2:PackedInt32Array([0,1,2])})
			replacement.surface_set_material(0,material)
			source.mesh = replacement
			sources.append(source)
		var controller := _prepare(setup)
		_check(controller.report["before"] == 2 and controller.report["after"] == 1,"ULP bounds fixture not grouped")
		if _proxies(controller).is_empty(): controller.restore(); world.free(); continue
		var proxy := _proxies(controller)[0]
		var original: AABB = sources[0].global_transform*sources[0].get_aabb()
		var effective: AABB = proxy.global_transform*proxy.custom_aabb
		_check(effective.encloses(original),"min .07/size3.93 effective proxy shrank an original AABB boundary")
		var center := original.get_center()
		for axis in 3:
			for side: float in [-1,1]:
				for offset: float in [0,.00000001,.000001,.00001,1.0]:
					var camera := center
					camera[axis] = (original.position[axis] if side < 0 else original.end[axis])+side*offset
					_probe_selection([[definition],[definition]],sources,proxy,camera,.2,1.0,false)
		controller.restore()
		world.free()

func _native_stride_fixture() -> void:
	var setup := _setup()
	var material := _material()
	var definition := _lod_surface(33000,PackedInt32Array([0,1,2,32769,32770,32771]),{.2:PackedInt32Array([32769,32770,32771])})
	var a := _holder(setup,"wide-indices-a",[material],_kitchen())
	var b := _holder(setup,"wide-indices-b",[material],_kitchen()+Vector3(.4,0,0))
	a.get_child(0).mesh = _lod_mesh([definition],material,0)
	b.get_child(0).mesh = _lod_mesh([definition],material,40000)
	var sources: Array[MeshInstance3D] = [a.get_child(0),b.get_child(0)]
	var snapshot := _snapshot(sources)
	var controller := _prepare(setup)
	_check(controller.report["before"] == 2 and controller.report["after"] == 1,"native stride fixture not grouped")
	if _proxies(controller).is_empty(): controller.restore(); setup["world"].free(); return
	var proxy := _proxies(controller)[0]
	var vertices: PackedVector3Array = proxy.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	_check(vertices.size() == 66000,"full source vertices not retained across uint16 boundary")
	var levels := _proxy_levels(proxy.mesh)
	_check(levels.size() == 1 and levels[0]["stride"] == 4,"merged >65536 LOD buffers did not use 32bit indices")
	if not levels.is_empty(): _check(levels[0]["indices"] == PackedInt32Array([32769,32770,32771,65769,65770,65771]),"native source uint16 to merged uint32 offset incorrect")
	_check(_geometry_equal(sources,[proxy]),"native coarse/near stride case changed geometry or attributes")
	_check(_snapshot(sources) == snapshot,"stride conversion changed source buffers")
	controller.restore()
	setup["world"].free()

func _check(condition: bool, message: String) -> void:
	checks += 1
	if not condition: errors.append(message)

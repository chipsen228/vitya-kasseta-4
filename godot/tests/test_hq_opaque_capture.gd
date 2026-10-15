## Actual Main GPU equivalence. Explicit --run-gpu; no benchmark claim.
## Main/child clocks are stopped. Untargeted built-in TIME is held in local shaders.
extends SceneTree

const MAX_ERROR := 1.0 / 255.0
const MEAN_ERROR := .01 / 255.0
const SIZE := Vector2i(1280,720)
const VIEWS := [
	{"id":"yard","at":Vector3(-.6,1.62,.408),"target":Vector3(-.6,3.7,11.4)},
	{"id":"second-line","at":Vector3(.3,1.62,-16.6),"target":Vector3(-6,2.021,-19)},
	{"id":"snt-gate","at":Vector3(36.8,1.65,-38.3),"target":Vector3(26.8,1.85,-38.3)},
	{"id":"snt-water","at":Vector3(-4,1.65,-53.8),"target":Vector3(-14,1.85,-53.8)},
	{"id":"drive-away","at":Vector3(7.6,1.65,-5.2),"target":Vector3(-2.28,1.35,-6.765)},
]

var output := "res://../output/environment-refresh/hq-opaque-proof"
var failures: Array[String] = []
var records: Array[Dictionary] = []
var target_materials: Array[Dictionary] = []
var held_time: Dictionary = {}
var parameter_changes: Array[Dictionary] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.has("--run-gpu") or DisplayServer.get_name()=="headless":
		printerr("test_hq_opaque_capture: requires a GPU window and --run-gpu")
		quit(2);return
	for arg: String in args:
		if arg.begins_with("--output="): output=arg.trim_prefix("--output=")
	output=ProjectSettings.globalize_path(output)
	_check(DirAccess.make_dir_recursive_absolute(output)==OK,"output directory")
	root.borderless=true;root.min_size=SIZE;root.size=SIZE
	_source_oracle()
	var main: Node=load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for frame in 3600:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		_check(false,"actual Main boot timeout");main.free();_finish({});return
	main.call("_start_game")
	var ui: Overlays=main.get("ui")
	for frame in 90:
		if ui.card.open: ui.advanceCard()
		await process_frame
	main.set("running",false)
	var player: Player=main.get("player")
	player.release_lock();ui.showHud(false)
	var chain: RenderChain=main.get("render_chain")
	chain.apply_preset("hq");chain.set_vhs_amount(0.0)
	main.get("weather").clear()
	(main.get("flashlight") as Flashlight).give()
	# Render targets keep updating, while scripts, physics and animation stop.
	for node: Node in _nodes(main): node.process_mode=Node.PROCESS_MODE_DISABLED
	for material: Material in _materials(main):
		if not material is ShaderMaterial or material.shader==null: continue
		var shader_material := material as ShaderMaterial
		var path := shader_material.shader.resource_path
		var base := "";var opaque := ""
		if path in [Materials.HQ_SHADER,Materials.HQ_OPAQUE_SHADER]:
			base=Materials.HQ_SHADER;opaque=Materials.HQ_OPAQUE_SHADER
		elif path in [Materials.HQ_ALPHA_SHADER,Materials.HQ_OPAQUE_ALPHA_SHADER]:
			base=Materials.HQ_ALPHA_SHADER;opaque=Materials.HQ_OPAQUE_ALPHA_SHADER
		if not base.is_empty():
			var cut: Variant=shader_material.get_shader_parameter("alpha_cut")
			if cut==null or ((cut is float or cut is int) and is_finite(float(cut)) and float(cut)<=0.0):
				target_materials.append({"material":shader_material,"id":shader_material.get_instance_id(),
					"base":base,"opaque":opaque,"cut":cut,"params":_parameters(shader_material),
					"hq_params":shader_material.get_meta("skin_hq_params",{}).duplicate()})
			else:
				_check(shader_material.shader==load(base),"actual nonzero/invalid cut uses opaque shader")
	_check(not target_materials.is_empty(),"no actual shared opaque HQ materials")
	_hold_time(main)
	var lights: LightRig=main.get("lights")
	var flash: Flashlight=main.get("flashlight")
	var camera:=chain.camera
	camera.fov=82.0
	for view: Dictionary in VIEWS:
		camera.global_position=view["at"];camera.look_at(view["target"])
		# Use the ordinary owner LOD controller once, then hold its geometry.
		for node: Node in _nodes(main):
			if node is EnvironmentLod: node.call("_process",0.0)
		for mode: String in ["day","night","night-flash"]:
			_set_lighting(lights,flash,camera,mode)
			var before:=_signature(main)
			_set_baseline()
			var baseline: Image=await _image(chain)
			var repeat: Image=await _image(chain)
			var stable:=_difference(baseline,repeat)
			_check(_within(stable),"unstable held baseline "+String(view["id"])+"/"+mode)
			_set_optimized()
			for row: Dictionary in target_materials:
				_assert_parameters(row,main,"opaque:"+String(view["id"])+"/"+mode)
			var optimized: Image=await _image(chain)
			var delta:=_difference(baseline,optimized)
			_check(_within(delta),"opaque pixels differ "+String(view["id"])+"/"+mode+" "+str(delta))
			_check(_signature(main)==before,"geometry/pose/material IDs changed "+String(view["id"])+"/"+mode)
			var prefix:=String(view["id"])+"-"+mode
			for row: Array in [["baseline",baseline],["repeat",repeat],["opaque",optimized]]:
				_check((row[1] as Image).save_png(output.path_join(prefix+"-"+String(row[0])+".png"))==OK,"PNG "+prefix)
			records.append({"view":view["id"],"mode":mode,"camera":str(view["at"]),"target":str(view["target"]),
				"stable":stable,"difference":delta,"stats":chain.stats()})
	_fallback_oracle(main)
	var before_roundtrip:=_signature(main)
	chain.apply_preset("retro")
	for row: Dictionary in target_materials:
		var material: ShaderMaterial=row["material"]
		_check(material.get_instance_id()==row["id"],"retro changed MaterialID")
		_check(material.shader.resource_path not in [row["base"],row["opaque"]],"retro retained HQ shader")
	chain.apply_preset("hq");chain.set_vhs_amount(0.0)
	_hold_time(main)
	# The quality preset resets atmosphere values. Restore the exact last case,
	# including settled light energies, before comparing its held image again.
	_set_lighting(lights,flash,camera,"night-flash")
	for row: Dictionary in target_materials:
		var material: ShaderMaterial=row["material"]
		_check(material.shader==load(row["opaque"]),"HQ roundtrip lost opaque routing")
		_assert_parameters(row,main,"HQ/retro/HQ")
	_check(_signature(main)==before_roundtrip,"HQ/retro/HQ changed geometry/pose/material IDs")
	var last_opaque: Image=await _image(chain)
	var expected:=Image.load_from_file(output.path_join("drive-away-night-flash-opaque.png"))
	var roundtrip:=_difference(expected,last_opaque)
	_check(_within(roundtrip),"HQ roundtrip pixels differ "+str(roundtrip))
	_check(last_opaque.save_png(output.path_join("drive-away-night-flash-roundtrip.png"))==OK,"roundtrip PNG")
	var summary:={"gpu_executed":true,"actual_main":true,"renderer":RenderingServer.get_video_adapter_name(),
		"buffer":chain.stats().get("buffer"),"target_materials":target_materials.size(),"roundtrip":roundtrip,
		"parameter_changes":parameter_changes,
		"clock_hold":"all Main node processing disabled; built-in TIME held at 0 in fixture-local untargeted shader resources",
		"lighting":"ordinary LightRig at night=.10/1.0; settled moon/ambient/lamp energies; night-flash beam energy=14",
		"acceptance":"image equivalence only; frame-time benchmark remains separate"}
	target_materials.clear();held_time.clear();main.free()
	await process_frame
	await process_frame
	_finish(summary)

func _set_lighting(lights: LightRig,flash: Flashlight,camera: Camera3D,mode: String) -> void:
	lights.restorePower();lights.powerOn=true
	lights.set_night_immediate(.10 if mode=="day" else 1.0)
	# dt=0 updates colours but cannot settle moon, ambient or lamp energies.
	# One isolated update reaches their ordinary equilibrium without running
	# Main's story clock or any node's process callback.
	lights.update(16.0,camera.global_position,"plot",true)
	flash.on=mode=="night-flash";flash.light.visible=flash.on
	flash.battery=100.0;flash.set("_flicker",0.0)
	var direction: Vector3=-camera.global_basis.z
	flash.set("_body",camera.global_position+camera.global_basis.x*.17-camera.global_basis.y*.13+direction*.18)
	flash.set("_aim",camera.global_position+direction*6.0)
	flash.update(2.0)
	_check(flash.light.light_energy>13.9 if flash.on else flash.light.light_energy<.001,"held flashlight energy")

func _source_oracle() -> void:
	var block:="\tif (alpha_cut > 0.0 && surface_color.a < alpha_cut) {\n\t\tdiscard;\n\t}\n"
	for pair: Array in [[Materials.HQ_SHADER,Materials.HQ_OPAQUE_SHADER],[Materials.HQ_ALPHA_SHADER,Materials.HQ_OPAQUE_ALPHA_SHADER]]:
		var base:=load(pair[0]) as Shader;var opaque:=load(pair[1]) as Shader
		_check(base!=null and opaque!=null,"missing shader pair "+str(pair))
		if base==null or opaque==null: continue
		var canonical:=base.code.replace("\r\n","\n")
		var variant:=opaque.code.replace("\r\n","\n").replace("\tVERTEX = VERTEX;\n","")
		_check(canonical.contains(block),"canonical discard oracle block missing")
		_check(variant==canonical.replace(block,""),"variant changed code beyond discard and literal identity vertex")

func _fallback_oracle(main: Node) -> void:
	for row: Dictionary in target_materials:
		var material: ShaderMaterial=row["material"]
		_assert_parameters(row,main,"before-positive-cut")
		material.set_shader_parameter("alpha_cut",.42);Materials.refresh_opaque_hq(material)
		_check(material.shader==load(row["base"]),"positive cut lost canonical discard")
		_check(material.get_instance_id()==row["id"],"fallback changed MaterialID")
		material.set_shader_parameter("alpha_cut",row["cut"]);Materials.refresh_opaque_hq(material)
		_check(material.shader==load(row["opaque"]),"zero cut did not restore opaque")
		_assert_parameters(row,main,"after-positive-cut-restore")

func _set_baseline() -> void:
	for row: Dictionary in target_materials: (row["material"] as ShaderMaterial).shader=load(row["base"])

func _set_optimized() -> void:
	for row: Dictionary in target_materials:
		var material: ShaderMaterial=row["material"]
		Materials.refresh_opaque_hq(material)
		_check(material.shader==load(row["opaque"]),"explicit opaque routing failed")

func _hold_time(main: Node) -> void:
	var regex:=RegEx.new();regex.compile("\\bTIME\\b")
	for material: Material in _materials(main):
		if not material is ShaderMaterial or material.shader==null: continue
		var mat:=material as ShaderMaterial
		if regex.search(mat.shader.code)==null: continue
		var held:=Shader.new();held.code=regex.sub(mat.shader.code,"0.0",true)
		held_time[mat]=held;mat.shader=held

func _materials(main: Node) -> Array[Material]:
	var seen: Dictionary={};var result: Array[Material]=[]
	for node: Node in _nodes(main):
		var meshes: Array=[]
		if node is MeshInstance3D:
			meshes=node.call("quality_meshes") if node.has_method("quality_meshes") else [node.mesh]
			for material: Material in [node.material_override,node.material_overlay]:
				if material!=null and not seen.has(material): seen[material]=true;result.append(material)
			if node.mesh!=null:
				for surface in node.mesh.get_surface_count():
					var material: Material=node.get_surface_override_material(surface)
					if material!=null and not seen.has(material): seen[material]=true;result.append(material)
		elif node is MultiMeshInstance3D and node.multimesh!=null:
			meshes=[node.multimesh.mesh]
			if node.material_override!=null and not seen.has(node.material_override): seen[node.material_override]=true;result.append(node.material_override)
		for mesh: Mesh in meshes:
			if mesh==null: continue
			for surface in mesh.get_surface_count():
				var material:=mesh.surface_get_material(surface)
				if material!=null and not seen.has(material): seen[material]=true;result.append(material)
	return result

func _signature(main: Node) -> String:
	var rows: Array=[]
	for node: Node in _nodes(main):
		if node is MeshInstance3D:
			rows.append([node.get_instance_id(),node.transform,_id(node.mesh),node.layers,node.visible,
				node.cast_shadow,_id(node.material_override),_id(node.material_overlay)])
			if node.mesh!=null:
				for surface in node.mesh.get_surface_count(): rows.append(_id(node.get_surface_override_material(surface)))
			var meshes: Array=node.call("quality_meshes") if node.has_method("quality_meshes") else [node.mesh]
			for mesh: Mesh in meshes:
				if mesh==null: continue
				for surface in mesh.get_surface_count():
					rows.append([mesh.get_instance_id(),mesh.surface_get_arrays(surface),_id(mesh.surface_get_material(surface))])
				if mesh is ArrayMesh:
					for packed: Dictionary in mesh.get("_surfaces"): rows.append(packed.get("lods",[]))
		elif node is MultiMeshInstance3D and node.multimesh!=null:
			rows.append([node.get_instance_id(),node.transform,_id(node.multimesh.mesh),node.multimesh.buffer,
				node.multimesh.custom_aabb,node.layers,node.visible,node.cast_shadow,_id(node.material_override)])
			if node.multimesh.mesh!=null:
				for surface in node.multimesh.mesh.get_surface_count():
					rows.append([node.multimesh.mesh.surface_get_arrays(surface),_id(node.multimesh.mesh.surface_get_material(surface))])
	var digest:=HashingContext.new();digest.start(HashingContext.HASH_SHA256);digest.update(var_to_bytes(rows))
	return digest.finish().hex_encode()

func _id(resource: Resource) -> int:
	return resource.get_instance_id() if resource!=null else 0

func _parameters(material: ShaderMaterial) -> Dictionary:
	var result: Dictionary={}
	for uniform: Dictionary in material.shader.get_shader_uniform_list():
		var name:=String(uniform["name"])
		result[name]=material.get_shader_parameter(name)
	return result

func _assert_parameters(row: Dictionary,main: Node,stage: String) -> void:
	var material: ShaderMaterial=row["material"]
	var expected: Dictionary=row["params"]
	var actual:=_parameters(material)
	if actual==expected: return
	var keys: Array=expected.keys()
	for key: Variant in actual:
		if not keys.has(key): keys.append(key)
	var changes: Array[Dictionary]=[]
	var before_meta: Dictionary=row["hq_params"]
	var after_meta: Dictionary=material.get_meta("skin_hq_params",{})
	for key: Variant in keys:
		var before: Variant=expected.get(key)
		var after: Variant=actual.get(key)
		if expected.has(key)==actual.has(key) and before==after and typeof(before)==typeof(after): continue
		changes.append({"key":String(key),"before":_describe_value(before),"after":_describe_value(after),
			"before_present":expected.has(key),"after_present":actual.has(key),
			"hq_meta_before":_describe_value(before_meta.get(key)),"hq_meta_after":_describe_value(after_meta.get(key))})
	var fact:={"stage":stage,"material_id":material.get_instance_id(),"resource_path":material.resource_path,
		"base":row["base"],"opaque":row["opaque"],"active_shader":material.shader.resource_path,
		"initial_cut":_describe_value(row["cut"]),"references":_material_references(main,material),"changes":changes}
	parameter_changes.append(fact)
	_check(false,"shared parameters/textures changed "+JSON.stringify(fact))

func _describe_value(value: Variant) -> Dictionary:
	var result:={"type":type_string(typeof(value))}
	if value is Resource:
		result.merge({"id":value.get_instance_id(),"class":value.get_class(),"path":value.resource_path})
	elif value is Color:
		result["value"]=[value.r,value.g,value.b,value.a]
	elif value is Vector2:
		result["value"]=[value.x,value.y]
	elif value is Vector3:
		result["value"]=[value.x,value.y,value.z]
	elif value is Vector4:
		result["value"]=[value.x,value.y,value.z,value.w]
	elif value==null or value is bool or value is int or value is float or value is String:
		result["value"]=value
	else:
		result["value"]=var_to_str(value)
	return result

func _material_references(main: Node,material: Material) -> Array[String]:
	var result: Array[String]=[]
	for node: Node in _nodes(main):
		var meshes: Array=[]
		var prefix:=String(main.get_path_to(node))
		if node is MeshInstance3D:
			if node.material_override==material: result.append(prefix+"@override")
			if node.material_overlay==material: result.append(prefix+"@overlay")
			if node.mesh!=null:
				for surface in node.mesh.get_surface_count():
					if node.get_surface_override_material(surface)==material: result.append(prefix+"@surface-override:"+str(surface))
			meshes=node.call("quality_meshes") if node.has_method("quality_meshes") else [node.mesh]
		elif node is MultiMeshInstance3D and node.multimesh!=null:
			if node.material_override==material: result.append(prefix+"@override")
			meshes=[node.multimesh.mesh]
		for level in meshes.size():
			var mesh: Mesh=meshes[level]
			if mesh==null: continue
			for surface in mesh.get_surface_count():
				if mesh.surface_get_material(surface)==material: result.append(prefix+"@mesh:"+str(level)+"/surface:"+str(surface))
	return result

func _image(chain: RenderChain) -> Image:
	for frame in 12: await process_frame
	await RenderingServer.frame_post_draw
	var image:=chain.post_view.get_texture().get_image()
	_check(image!=null and image.get_size()==SIZE,"actual image buffer")
	if image==null: return Image.new()
	image.convert(Image.FORMAT_RGBA8)
	return image

func _difference(a: Image,b: Image) -> Dictionary:
	if a==null or b==null or a.is_empty() or b.is_empty() or a.get_size()!=b.get_size(): return {"max":1.0,"mean":1.0,"changed_bytes":-1}
	var x:=a.get_data();var y:=b.get_data()
	if x==y: return {"max":0.0,"mean":0.0,"changed_bytes":0}
	var largest:=0;var total:=0;var changed:=0
	for i in x.size():
		var delta:=absi(int(x[i])-int(y[i]));largest=maxi(largest,delta);total+=delta
		if delta!=0: changed+=1
	return {"max":float(largest)/255.0,"mean":float(total)/float(x.size())/255.0,"changed_bytes":changed}

func _within(delta: Dictionary) -> bool:
	return float(delta["max"])<=MAX_ERROR and float(delta["mean"])<=MEAN_ERROR

func _nodes(node: Node) -> Array[Node]:
	var result: Array[Node]=[node]
	for child: Node in node.get_children(): result.append_array(_nodes(child))
	return result

func _check(ok: bool,message: String) -> void:
	if not ok: failures.append(message)

func _finish(summary: Dictionary) -> void:
	summary.merge({"records":records,"failures":failures,"passed":failures.is_empty(),
		"tolerances":{"max_channel_error":MAX_ERROR,"mean_channel_error":MEAN_ERROR}},true)
	var file:=FileAccess.open(output.path_join("report.json"),FileAccess.WRITE)
	if file!=null: file.store_string(JSON.stringify(summary,"\t"));file.close()
	else: _check(false,"report file")
	for failure: String in failures: printerr("test_hq_opaque_capture: "+failure)
	print("test_hq_opaque_capture: %s cases=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL",records.size(),failures.size()])
	quit(0 if failures.is_empty() else 1)

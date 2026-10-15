extends SceneTree

var errors: Array[String] = []
const BLOCK := "\tif (alpha_cut > 0.0 && surface_color.a < alpha_cut) {\n\t\tdiscard;\n\t}\n"

func _initialize() -> void:
	_run.call_deferred()

func _check(passed: bool, message: String) -> void:
	if not passed: errors.append(message)

func _run() -> void:
	for pair: Array in [[Materials.HQ_SHADER,Materials.HQ_OPAQUE_SHADER,Materials.PSX_SHADER],
			[Materials.HQ_ALPHA_SHADER,Materials.HQ_OPAQUE_ALPHA_SHADER,Materials.SKIN_ALPHA_SHADER]]:
		var canonical: Shader = load(pair[0])
		var opaque: Shader = load(pair[1])
		_check(canonical.code.replace("\r","").replace(BLOCK,"") == opaque.code.replace("\r","").replace("\tVERTEX = VERTEX;\n",""),"opaque variant changes code beyond disabled alpha test and identity vertex write")
		var mat := ShaderMaterial.new()
		mat.shader = load(pair[2])
		var id := mat.get_instance_id()
		mat.set_meta("skin_hq_params",{"alpha_cut":0.0,"roughness_value":.68,"albedo":Color(.2,.3,.4,1)})
		Materials.set_material_quality(mat,true)
		_check(mat.shader == opaque and mat.get_instance_id() == id,"opaque selection replaces material or keeps discard")
		_check(mat.get_shader_parameter("roughness_value") == .68,"opaque selection loses HQ parameters")
		for cut: float in [0.4,-0.1,0.0,INF,NAN]:
			mat.set_shader_parameter("alpha_cut",cut)
			Materials.refresh_opaque_hq(mat)
			_check(mat.shader == (opaque if is_finite(cut) and cut<=0 else canonical),"cut refresh loses mask or accepts nonfinite cut")
		mat.set_shader_parameter("alpha_cut",0.0)
		Materials.set_material_quality(mat,true)
		_check(mat.shader == opaque,"already HQ quality call does not refresh alpha state")
		Materials.set_material_quality(mat,false)
		_check(mat.shader == load(pair[2]),"retro shader identity lost")
		Materials.set_material_quality(mat,true)
		_check(mat.shader == opaque and mat.get_instance_id() == id,"HQ return loses shared material identity")
	var unknown := ShaderMaterial.new()
	unknown.shader = Shader.new()
	unknown.shader.code="shader_type spatial; void fragment(){ALBEDO=vec3(1.0);}"
	var original := unknown.shader
	Materials.refresh_opaque_hq(unknown)
	_check(unknown.shader == original,"unknown shader changed")
	for error: String in errors: printerr(error)
	print("test_hq_opaque: ","PASS" if errors.is_empty() else "FAIL", " (code equivalence; mask/nonfinite fallback; shared identity; quality roundtrip)")
	quit(0 if errors.is_empty() else 1)

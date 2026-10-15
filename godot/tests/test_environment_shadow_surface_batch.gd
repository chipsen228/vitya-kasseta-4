## Exact per-owner medium geometry; no Main, GPU or physics required.
extends SceneTree

const LOD = preload("res://src/environment_lod.gd")
const REGISTRY = preload("res://src/environment_registry.gd")
var failures: Array[String] = []
var checks := 0

func _initialize() -> void:
	_test_exact_and_flags()
	_test_policy_fallbacks()
	_test_geometry_rejections()
	_test_invalidation()
	var report: Dictionary={"owners":[],"surfaces_before":0,"surfaces_after":0,"triangles":0,"merged":0,"rejected":[]}
	Materials.render_hq_enabled=true
	for category: String in ["houses","services","yards"]:
		for row: Dictionary in REGISTRY.manifest().get(category,[]):
			var source: Mesh=REGISTRY._load_mesh(String(row["paths"][1]))
			_check(source != null,"missing actual medium "+String(row["id"]))
			if source == null: continue
			var before: PackedByteArray=_signature(source)
			var owner: EnvironmentLod=_owner(source)
			var caster: MeshInstance3D=owner.get_child(0)
			var batch: Dictionary=LOD.shadow_surface_batch_report(source)
			var after: Mesh=caster.mesh
			_check(before == _signature(source),"actual source arrays/material IDs changed "+String(row["id"]))
			_check(owner.mesh == source,"visible source replaced "+String(row["id"]))
			_check(after.get_aabb() == source.get_aabb(),"actual bounds changed "+String(row["id"]))
			_check(_triangle_oracle(after) == _triangle_oracle(source),"actual triangle/channel oracle changed "+String(row["id"]))
			_check(_packed_oracle(after) == _packed_oracle(source),"actual ordered raw streams changed "+String(row["id"]))
			if after != source:
				_check(after.get_surface_count() == 1 and caster.material_override != null,"actual merge without single opaque caster")
				report["merged"]+=1
			else:
				_check(not bool(batch["merged"]),"cached merge was not used by eligible owner "+String(row["id"]))
				if source.get_surface_count()>1: report["rejected"].append({"owner":row["id"],"reason":batch["reason"]})
			report["surfaces_before"]+=source.get_surface_count();report["surfaces_after"]+=after.get_surface_count()
			report["triangles"]+=source.get_faces().size()/3
			report["owners"].append({"id":row["id"],"source_surfaces":source.get_surface_count(),"caster_surfaces":after.get_surface_count(),"batch":batch})
			owner.free()
	_check(report["owners"].size() == 73,"actual full registry medium coverage incomplete")
	_check(report["surfaces_before"] == 97 and report["triangles"] == 100942,"actual immutable medium census changed")
	# The 24 optional merges are admitted only if the real decoded buffers stay
	# exact. Report format/roundtrip rejection rather than granting exceptions.
	_check(report["surfaces_after"] >= 73 and report["surfaces_after"] <= 97,"unexpected surface count")
	report["checks"]=checks;report["failures"]=failures;report["gpu_verified"]=false
	var path: String=ProjectSettings.globalize_path("res://").path_join("../output/environment-refresh/shadow-surface-batch-cpu.json").simplify_path()
	var file: FileAccess=FileAccess.open(path,FileAccess.WRITE)
	if file != null: file.store_string(JSON.stringify(report,"\t"));file.close()
	for message: String in failures: printerr(message)
	print("test_environment_shadow_surface_batch: ","PASS" if failures.is_empty() else "FAIL"," checks=",checks,
		" owners=",report["owners"].size()," surfaces=",report["surfaces_before"],"->",report["surfaces_after"]," merged=",report["merged"])
	call_deferred("quit",0 if failures.is_empty() else 1)

func _test_exact_and_flags() -> void:
	var source: ArrayMesh=_rich_mesh()
	var before: PackedByteArray=_signature(source)
	var owner: EnvironmentLod=_owner(source)
	var caster: MeshInstance3D=owner.get_child(0)
	_check(caster.mesh != source and caster.mesh.get_surface_count() == 1,"compatible two-surface fixture did not merge")
	_check(_triangle_oracle(caster.mesh) == _triangle_oracle(source),"indexed POSITION/NORMAL oracle differs")
	_check(_packed_oracle(caster.mesh) == _packed_oracle(source),"ordered position/normal/tangent/attribute packed bytes changed")
	_check(_signature(source) == before,"source buffers/material resources changed")
	_check(caster.mesh.get_aabb() == source.get_aabb(),"full original AABB changed")
	_check(owner.mesh == source and owner.get_child_count() == 1,"visible geometry or caster count changed")
	var other: EnvironmentLod=_owner(source)
	_check((other.get_child(0) as MeshInstance3D).mesh == caster.mesh,"same source did not reuse cached merged mesh")
	owner.transform=Transform3D(Basis(Vector3.UP,.37).scaled(Vector3(1.1,.9,1.2)),Vector3(2,3,4))
	var pose: Transform3D=owner.transform
	owner.layers=5;owner.visibility_range_begin=2;owner.visibility_range_end=51
	owner.visibility_range_begin_margin=.4;owner.visibility_range_end_margin=.8
	owner._sync_shadow_caster()
	_check(owner.transform == pose and caster.transform == Transform3D.IDENTITY,"batch changed positive basis/local pose")
	_check(caster.layers == 5 and caster.visibility_range_begin == 2 and caster.visibility_range_end == 51,"caster range/layers changed")
	_check(caster.visibility_range_begin_margin == owner.visibility_range_begin_margin and caster.visibility_range_end_margin == owner.visibility_range_end_margin,"caster range margins changed")
	_check(caster.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,"caster mode changed")
	owner.visible=false;owner._sync_shadow_caster()
	# SceneTree has not flushed visibility yet inside _initialize. Its actual
	# inherited visibility is the conjunction of the unchanged ancestor flags.
	_check(_hidden_by_ancestor(caster) and not owner.visible,"story-hidden owner became visible")
	owner.visible=true;owner.current_level=2;owner._sync_shadow_caster()
	_check(not caster.visible and caster.mesh == source,"far LOD caster visibility/source policy changed")
	owner.current_level=0;owner._sync_shadow_caster()
	_check(caster.visible and caster.mesh != source,"near caster did not recover cached merge")
	owner.free();other.free()
	var rich: ArrayMesh=_rich_mesh("unused-formats")
	var rich_before: PackedByteArray=_signature(rich)
	var rich_owner: EnvironmentLod=_owner(rich)
	var rich_caster: MeshInstance3D=rich_owner.get_child(0)
	_check(_signature(rich) == rich_before,"source TBN/UV/COLOR changed during packed assembly rejection")
	_check(_triangle_oracle(rich_caster.mesh) == _triangle_oracle(rich),"different unused formats changed POSITION/NORMAL")
	var rich_report: Dictionary=LOD.shadow_surface_batch_report(rich)
	_check(not rich_report["merged"] and rich_caster.mesh == rich and not String(rich_report["reason"]).is_empty(),"different packed formats were admitted or rejection has no reason")
	rich_owner.free()
	var tangents: ArrayMesh=_rich_mesh("common-tangents")
	var tangent_owner: EnvironmentLod=_owner(tangents)
	var tangent_caster: MeshInstance3D=tangent_owner.get_child(0)
	_check(tangent_caster.mesh != tangents,"compatible packed tangent fixture did not merge")
	_check(_packed_oracle(tangent_caster.mesh) == _packed_oracle(tangents),"packed normal/tangent encoding changed")
	_check(_triangle_oracle(tangent_caster.mesh) == _triangle_oracle(tangents),"decoded normal from tangent frame changed")
	tangent_owner.free()

func _test_policy_fallbacks() -> void:
	var source: ArrayMesh=_rich_mesh()
	var owner: EnvironmentLod=_owner(source)
	var caster: MeshInstance3D=owner.get_child(0)
	var material: ShaderMaterial=source.surface_get_material(1)
	material.set_shader_parameter("alpha_cut",.42);owner.refresh_shadow_material_policy()
	_check(caster.mesh == source and caster.material_override == null,"alpha fallback changed original medium")
	material.set_shader_parameter("alpha_cut",0.0)
	material.set_shader_parameter("albedo",Color(1,1,1,.5));owner.refresh_shadow_material_policy()
	_check(caster.mesh == source,"translucent fallback did not restore original")
	material.set_shader_parameter("albedo",Color.WHITE)
	material.next_pass=StandardMaterial3D.new();owner.refresh_shadow_material_policy()
	_check(caster.mesh == source,"multipass fallback did not restore original")
	material.next_pass=null
	var unknown: Shader=Shader.new()
	unknown.code="shader_type spatial;void vertex(){VERTEX.x+=.1;}"
	material.shader=unknown;owner.refresh_shadow_material_policy()
	_check(caster.mesh == source,"unknown/deforming fallback did not restore original")
	material.shader=load(Materials.HQ_SHADER);owner.refresh_shadow_material_policy()
	_check(caster.mesh != source,"known opaque policy did not recover")
	material.shader=load(Materials.HQ_ALPHA_SHADER);owner.refresh_shadow_material_policy()
	_check(caster.mesh == source and caster.material_override == null,"mixed source cull policies used merged geometry")
	material.shader=load(Materials.HQ_SHADER);owner.refresh_shadow_material_policy()
	owner.set_surface_override_material(1,StandardMaterial3D.new());owner._sync_shadow_caster()
	_check(caster.mesh == source,"per-surface override used merged geometry")
	owner.set_surface_override_material(1,null)
	owner.material_override=StandardMaterial3D.new();owner._sync_shadow_caster()
	_check(caster.mesh == source and caster.material_override == owner.material_override,"owner override fallback lost source/material")
	owner.material_override=null;owner.material_overlay=StandardMaterial3D.new();owner._sync_shadow_caster()
	_check(caster.mesh == source and caster.material_overlay == owner.material_overlay,"overlay fallback lost source/overlay")
	owner.material_overlay=null
	for surface in source.get_surface_count(): (source.surface_get_material(surface) as ShaderMaterial).shader=load(Materials.PSX_SHADER)
	owner.refresh_shadow_material_policy()
	_check(caster.mesh == source and caster.material_override == null,"retro did not use exact original medium")
	for surface in source.get_surface_count(): (source.surface_get_material(surface) as ShaderMaterial).shader=load(Materials.HQ_SHADER)
	owner.refresh_shadow_material_policy()
	_check(caster.mesh != source,"HQ-return did not recover merge")
	owner.free()

func _test_geometry_rejections() -> void:
	for kind: String in ["format","native-lods","bones","compressed"]:
		var source: ArrayMesh=_rich_mesh(kind)
		var owner: EnvironmentLod=_owner(source)
		var caster: MeshInstance3D=owner.get_child(0)
		_check(caster.mesh == source,"unsafe geometry admitted: "+kind)
		_check(not bool(LOD.shadow_surface_batch_report(source)["merged"]),"unsafe cache marked merged: "+kind)
		owner.free()
	var single: ArrayMesh=_rich_mesh("single")
	var owner: EnvironmentLod=_owner(single)
	_check((owner.get_child(0) as MeshInstance3D).mesh == single,"single surface needlessly duplicated")
	owner.free()

func _test_invalidation() -> void:
	var source: ArrayMesh=_rich_mesh()
	var owner: EnvironmentLod=_owner(source)
	var caster: MeshInstance3D=owner.get_child(0)
	var old: Mesh=caster.mesh
	var arrays: Array=[];var materials: Array=[]
	for surface in source.get_surface_count(): arrays.append(source.surface_get_arrays(surface));materials.append(source.surface_get_material(surface))
	var points: PackedVector3Array=arrays[0][Mesh.ARRAY_VERTEX]
	points[0]+=Vector3(.3125,0,0);arrays[0][Mesh.ARRAY_VERTEX]=points
	source.clear_surfaces()
	for i in arrays.size(): source.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays[i]);source.surface_set_material(i,materials[i])
	owner.refresh_shadow_material_policy()
	_check(caster.mesh != old and caster.mesh != source,"mesh.changed did not invalidate immutable geometry cache")
	_check(_triangle_oracle(caster.mesh) == _triangle_oracle(source),"rebuilt cache retained stale vertex/index/normal data")
	_check(_packed_oracle(caster.mesh) == _packed_oracle(source),"rebuilt cache retained stale packed bytes")
	_check(caster.mesh.get_aabb() == source.get_aabb(),"rebuilt bounds stale")
	var levels: Array[Mesh]=[source,source,source]
	owner.configure(levels)
	_check(owner.get_child_count() == 1 and _triangle_oracle((owner.get_child(0) as MeshInstance3D).mesh) == _triangle_oracle(source),"reconfigure duplicated caster or kept stale geometry")
	owner.free()

func _owner(source: Mesh) -> EnvironmentLod:
	var owner: EnvironmentLod=LOD.new()
	root.add_child(owner)
	var levels: Array[Mesh]=[source,source,source]
	owner.configure(levels)
	return owner

func _rich_mesh(kind := "") -> ArrayMesh:
	var mesh: ArrayMesh=ArrayMesh.new()
	for surface in (1 if kind == "single" else 2):
		var arrays: Array=[];arrays.resize(Mesh.ARRAY_MAX)
		var offset: float=float(surface)*2.125
		arrays[Mesh.ARRAY_VERTEX]=PackedVector3Array([Vector3(offset,0,0),Vector3(offset+1,0,0),Vector3(offset+1,1,.25),Vector3(offset,1,.25)])
		if not (kind == "format" and surface == 1): arrays[Mesh.ARRAY_NORMAL]=PackedVector3Array([Vector3.FORWARD,Vector3.FORWARD,Vector3.FORWARD,Vector3.FORWARD])
		if kind == "common-tangents" or kind == "unused-formats" and surface == 0: arrays[Mesh.ARRAY_TANGENT]=PackedFloat32Array([1,0,0,1,1,0,0,-1,1,0,0,1,1,0,0,-1])
		arrays[Mesh.ARRAY_COLOR]=PackedColorArray([Color(.1,.2,.3,1),Color(.8,.7,.6,1),Color(.2,.5,.4,1),Color(.9,.4,.1,1)])
		arrays[Mesh.ARRAY_TEX_UV]=PackedVector2Array([Vector2(.1,.2),Vector2(.7,.2),Vector2(.7,.8),Vector2(.1,.8)])
		if not (kind == "unused-formats" and surface == 1): arrays[Mesh.ARRAY_TEX_UV2]=PackedVector2Array([Vector2(.2,.1),Vector2(.8,.1),Vector2(.8,.7),Vector2(.2,.7)])
		arrays[Mesh.ARRAY_INDEX]=PackedInt32Array([0,1,2,0,2,3])
		if kind == "bones":
			arrays[Mesh.ARRAY_BONES]=PackedInt32Array([0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0])
			arrays[Mesh.ARRAY_WEIGHTS]=PackedFloat32Array([1,0,0,0,1,0,0,0,1,0,0,0,1,0,0,0])
		var lods: Dictionary={12.0:PackedInt32Array([0,1,2])} if kind == "native-lods" else {}
		var flags: int=Mesh.ARRAY_FLAG_COMPRESS_ATTRIBUTES if kind == "compressed" else 0
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays,[],lods,flags)
		var material: ShaderMaterial=ShaderMaterial.new()
		material.shader=load(Materials.HQ_SHADER)
		material.set_shader_parameter("albedo",Color.WHITE);material.set_shader_parameter("alpha_cut",0.0)
		mesh.surface_set_material(surface,material)
	return mesh

func _triangle_oracle(mesh: Mesh) -> PackedByteArray:
	var result: Array=[]
	for surface in mesh.get_surface_count():
		var arrays: Array=mesh.surface_get_arrays(surface)
		var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		if indices.is_empty():
			for i in arrays[Mesh.ARRAY_VERTEX].size(): indices.append(i)
		for index: int in indices:
			var vertex: Array=[]
			for slot: int in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL]:
				vertex.append(arrays[slot][index] if arrays[slot] != null and not arrays[slot].is_empty() else null)
			result.append(vertex)
	return var_to_bytes(result)

func _packed_oracle(mesh: Mesh) -> PackedByteArray:
	var triangles: Array=[]
	for raw: Dictionary in mesh.get("_surfaces"):
		var format: int=raw["format"]
		var count: int=raw["vertex_count"]
		var ps: int=RenderingServer.mesh_surface_get_format_vertex_stride(format,count)
		var ns: int=RenderingServer.mesh_surface_get_format_normal_tangent_stride(format,count)
		var no: int=RenderingServer.mesh_surface_get_format_offset(format,count,Mesh.ARRAY_NORMAL)
		var ats: int=RenderingServer.mesh_surface_get_format_attribute_stride(format,count)
		var vb: PackedByteArray=raw["vertex_data"]
		var ab: PackedByteArray=raw.get("attribute_data",PackedByteArray())
		var ib: PackedByteArray=raw.get("index_data",PackedByteArray())
		var ic: int=raw.get("index_count",0)
		var stride: int=ib.size()/ic if ic>0 else 0
		for i in (ic if ic>0 else count):
			var index: int=ib.decode_u16(i*stride) if stride == 2 else ib.decode_u32(i*stride) if stride == 4 else i
			triangles.append([vb.slice(index*ps,(index+1)*ps),vb.slice(no+index*ns,no+(index+1)*ns),ab.slice(index*ats,(index+1)*ats)])
	return var_to_bytes(triangles)

func _hidden_by_ancestor(node: Node) -> bool:
	var ancestor: Node=node
	while ancestor != null:
		if ancestor is Node3D and not (ancestor as Node3D).visible: return true
		ancestor=ancestor.get_parent()
	return false

func _signature(mesh: Mesh) -> PackedByteArray:
	var result: Array=[mesh.get_aabb(),mesh.resource_path]
	for surface in mesh.get_surface_count():
		var material: Material=mesh.surface_get_material(surface)
		result.append([mesh.surface_get_arrays(surface),material.get_instance_id() if material != null else 0,material.resource_path if material != null else ""])
		if mesh is ArrayMesh:
			var raw: Dictionary=mesh.get("_surfaces")[surface]
			result.append([raw["format"],raw["vertex_count"],raw.get("index_count",0),raw["vertex_data"],raw.get("attribute_data",PackedByteArray()),raw.get("index_data",PackedByteArray()),raw.get("lods",[])])
	return var_to_bytes(result)

func _check(ok: bool,message: String) -> void:
	checks+=1
	if not ok: failures.append(message)

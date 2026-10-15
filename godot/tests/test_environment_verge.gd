## Full current collision admission plus native MultiMesh resource identity.
extends SceneTree

const VERGE := preload("res://src/environment_verge.gd")
var errors: Array[String] = []
var checks := 0

func _initialize() -> void:
	Materials.render_hq_enabled=true
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	root.add_child(world)
	var built := WorldBuilder.build(world,mats,col)
	var definitions: Array = GameData.props().get("PROPS",[])
	var props := Props.new(mats).load_models(definitions).build(world,definitions,col)
	EverydayWorld.build(world,mats,col,built)
	var before := VERGE.physics_stamp(col)
	var before_counts: Array = []
	for set_id in CollisionWorld.SET_COUNT: before_counts.append(col.box_count(set_id))
	var asset_digests: Dictionary = {}
	for spec: Dictionary in VERGE.GROUPS:
		var key := String(spec["key"])
		asset_digests[key]=_asset_digest(ProceduralAssets.fetch(key))
	var report := VERGE.apply(world,col)
	_check(VERGE.physics_stamp(col)==before,"full 14-value collision shapes/activity changed")
	if OS.get_cmdline_user_args().has("--environment=off"):
		_check(not bool(report["active"]) and report["nodes"].is_empty(),"environment=off instantiated plants")
	else:
		_check(report["errors"].is_empty(),"admission errors "+str(report["errors"]))
		_check(report["instances"]==8 and report["surfaces"]==4,"authored clumps or surface count missing")
		_check(report["near_triangles"]==316 and report["far_triangles"]<=132 and report["far_source_available"]==132,"native near/far budget changed")
		var clear: Array=Scatter.data().get("CLEAR",[])
		var rooms: Array=RuralDressing.placement_registry()
		for row: Dictionary in report["placements"]:
			var at: Array=row["position"]
			var data: Dictionary=row["bounds"]
			var min_v: Array=data["min"];var size_v: Array=data["size"]
			var box:=AABB(Vector3(min_v[0],min_v[1],min_v[2]),Vector3(size_v[0],size_v[1],size_v[2]))
			_check(VERGE.admission_reason(col,box,clear,rooms,float(at[1])).is_empty(),"accepted bbox is not freshly clear "+str(at))
			var cap:=0.45 if row["domain"]=="dry-verge" else 0.70 if row["domain"]=="wet-shore" else 0.60
			_check(box.size.y<=cap+0.0001,"clump exceeds domain height cap")
		for group: Dictionary in report["groups"]:
			var node: MultiMeshInstance3D=report["nodes"][group["id"]]
			var mm:=node.multimesh
			_check(mm.instance_count==group["instances"],"live MultiMesh is empty or truncated")
			var buffer: PackedFloat32Array=node.get_meta("environment_written_buffer")
			_check(buffer.size()==mm.instance_count*12,"requested native transform buffer missing")
			_check(group["native_lod_records"]==VERGE.native_lod_records(mm.mesh),"LOD ledger differs from the actual bound mesh")
			_check(bool(group["native_lod"])==not group["native_lod_records"].is_empty(),"native LOD claim has no actual embedded buffers")
			_check(mm.mesh.resource_path==group["mesh_resource"] and mm.mesh.get_surface_count()==1,"source surface identity changed")
			_check(node.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,"plant cast shadows")
			_check(node.get_script()==null and not node.is_processing(),"passive native LOD became a controller")
			_check(node.visibility_range_end==group["range_end"],"near domain range changed")
			var actual:=AABB();var first:=true
			for i in mm.instance_count:
				# Read the exact requested float32 upload, not authored counts or
				# RendererDummy's identity Transform3D fallback. Root verifies GPU readback.
				var offset:=i*12
				var xf:=Transform3D(Basis(Vector3(buffer[offset],buffer[offset+4],buffer[offset+8]),
					Vector3(buffer[offset+1],buffer[offset+5],buffer[offset+9]),Vector3(buffer[offset+2],buffer[offset+6],buffer[offset+10])),
					Vector3(buffer[offset+3],buffer[offset+7],buffer[offset+11]))
				var box: AABB=node.transform*xf*mm.mesh.get_aabb()
				actual=box if first else actual.merge(box);first=false
			var declared: AABB=node.transform*mm.custom_aabb
			_check(actual.position.is_equal_approx(declared.position) and actual.size.is_equal_approx(declared.size),"custom AABB does not enclose requested float32 transforms")
		_check(VERGE.apply(world,col)==report,"repeated apply changed cohort")
	for key: String in asset_digests:
		_check(_asset_digest(ProceduralAssets.fetch(key))==asset_digests[key],"shared near/far geometry or material identity mutated "+key)
	_guard_fixtures()
	var saved:=report.duplicate(true)
	saved.erase("nodes");saved["geometry_verified"]=errors.is_empty();saved["visual_verified"]=false
	saved["checks"]=checks;saved["unit_errors"]=errors;saved["collision_counts"]=before_counts
	saved["test_context"]="fresh WorldBuilder + Props + EverydayWorld; no Main rendering, no GPU"
	saved["buffer_verification"]="CPU decoded requested float32 upload; RendererDummy readback unavailable; actual_gpu_buffer_verified=false"
	var path:=ProjectSettings.globalize_path("res://").path_join("../output/environment-refresh/near-vegetation-placement.json").simplify_path()
	var file:=FileAccess.open(path,FileAccess.WRITE)
	file.store_string(JSON.stringify(saved,"\t"));file.close()
	# Release fixture reports/caches before destroying their scene. Defer exit
	# until the initialization call has returned and local resource refs unwind.
	props.dispose();built.clear();(report["nodes"] as Dictionary).clear()
	world.remove_meta("environment_verge_report");world.free()
	for message: String in errors: printerr(message)
	print("test_environment_verge: ","PASS" if errors.is_empty() else "FAIL"," checks=",checks,
		" clumps=",report["instances"]," surfaces=",report["surfaces"]," near=",report["near_triangles"]," far=",report["far_triangles"])
	call_deferred("quit",0 if errors.is_empty() else 1)

func _guard_fixtures() -> void:
	var col:=CollisionWorld.new()
	var box:=AABB(Vector3(-10,0.04,-9),Vector3(1,0.4,1))
	_check(VERGE.admission_reason(col,box,[],[],0.0).is_empty(),"free microfixture rejected")
	# Thin solid inside the footprint: checking only the anchor/corners would miss it.
	col.add_box_d(CollisionWorld.SET_BLOCKERS,-9.75,0.10,-8.70,-9.55,0.35,-8.50,"fixture-solid")
	_check(VERGE.admission_reason(col,box,[],[],0.0)=="ALL_SOLID footprint","inside-footprint blocker missed")
	col.set_blocker_active("fixture-solid",false)
	_check(VERGE.admission_reason(col,box,[],[],0.0).is_empty(),"inactive collider still rejects")
	_check(VERGE.admission_reason(col,box,[[-9.3,-9.1,-8.7,-8.5]],[],0.0)=="CLEAR","bbox edge entering CLEAR missed")
	_check(VERGE.admission_reason(col,box,[],[{"rect":Rect2(-9.3,-8.7,0.2,0.2)}],0.0)=="building/yard/nav footprint","building footprint edge missed")
	var route_box:=AABB(Vector3(14.1,0.04,-24),Vector3(0.3,0.4,0.3))
	_check(VERGE.admission_reason(col,route_box,[],[],0.0)=="route footprint","central path full width missed")

func _asset_digest(asset: Dictionary) -> String:
	var data: Array=[]
	for field: String in ["meshes","lod_meshes"]:
		for mesh: ArrayMesh in asset[field]:
			for surface in mesh.get_surface_count():
				data.append(mesh.surface_get_arrays(surface))
				var material := mesh.surface_get_material(surface)
				data.append(material.get_instance_id() if material!=null else 0)
				data.append(mesh.get("_surfaces")[surface].get("lods",[]))
	return var_to_str(data).sha256_text()

func _check(ok: bool,message: String) -> void:
	checks+=1
	if not ok: errors.append(message)

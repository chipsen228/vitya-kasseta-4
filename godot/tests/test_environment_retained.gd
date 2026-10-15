## Материалы меряем после настоящего boot_finish, геометрию реестр только читает.
extends SceneTree

const RETAINED := preload("res://src/environment_retained.gd")
var failures: Array[String]=[]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_renderer_metadata()
	_batched_metadata()
	var main: Node=(load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for index in 4000:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		failures.append("main boot did not finish")
		_finish(main,[])
		return
	main.set("running",false)
	var chain: RenderChain=main.get("render_chain")
	var world: Node3D=chain.world_root
	var col: CollisionWorld=main.get("col")
	var built: Dictionary=main.get("built")
	var counts:=_counts(col)
	var before:=_scene_signature(world)
	var rows: Array[Dictionary]=RETAINED.apply(world,built,main.get("mats"))
	if counts!=_counts(col): failures.append("inventory changed collision sets")
	if before!=_scene_signature(world): failures.append("inventory changed meshes/nodes/transforms")
	if counts.slice(0,3)!=[311,4,83] or int(built["triangles"])!=3885: failures.append("base311/4/83/3885 changed")
	var owners: Dictionary={}
	var cars:=0
	var interiors:=0
	for row: Dictionary in rows:
		var owner:=String(row["owner"])
		if owners.has(owner): failures.append("duplicate owner "+owner)
		owners[owner]=row
		if not bool(row["present"]) or int(row["triangles"])<=0: failures.append("empty retained owner "+owner)
		if row["retention_reason"]!="reviewed-existing-detail": failures.append("wrong retention reason "+owner)
		if (row["resources"] as Array).is_empty(): failures.append("missing resources "+owner)
		if (row["materials"] as Array).is_empty(): failures.append("missing actual materials "+owner)
		if (row["nodes"] as Array).is_empty(): failures.append("missing actual nodes "+owner)
		if (row["camera_refs"] as Array).is_empty(): failures.append("missing camera refs "+owner)
		if not row.has("controls") or not row.has("detail_variant"): failures.append("missing detail/control refs "+owner)
		var bounds: Dictionary=row["bounds"]
		if bounds.get("min",[]).size()!=3 or bounds.get("size",[]).size()!=3: failures.append("missing bounds "+owner)
		for path: String in row["nodes"]:
			var mesh:=world.get_node_or_null(path) as MeshInstance3D
			if mesh==null: failures.append("stale node "+path)
			elif mesh.layers==0: failures.append("inventory references hidden source instead of actual residual "+path)
		if row["kind"]=="car":
			cars+=1
			if row["camera_refs"][0].get("source","")!="res://data/environment_views.json": failures.append("car has no authoritative camera ref "+owner)
			var id:=owner.get_slice("/",2)
			var holder:=world.get_node_or_null("props/snt-car-"+id)
			if holder==null or String(holder.get_meta("vehicle_family",""))!=row["detail_variant"]: failures.append("wrong car family "+owner)
		if row["kind"] in ["interior","interior-detail","interior-prop"]: interiors+=1
		if chain.render_preset()==RenderChain.PRESET_HQ:
			for material: Dictionary in row["materials"]:
				if material["shader"]==Materials.PSX_SHADER: failures.append("post-boot retained material still PSX "+owner)
	if cars!=15: failures.append("cars %d/15" % cars)
	if interiors<20: failures.append("interior owner coverage unexpectedly empty")
	for id: String in ["greenhouse","shower","stop","well","mill","cemetery","hens-cottage"]:
		if not owners.has("retained/public/"+id): failures.append("missing public site "+id)
	var coops:=0
	var farm:=0
	for owner: String in owners:
		if owner.begins_with("retained/public/farm-coop@"): coops+=1
		if owner.begins_with("retained/public/farm-"): farm+=1
	if coops!=2 or farm<5: failures.append("incomplete retained farm/coop coverage")
	var cemetery: Dictionary=owners.get("retained/public/cemetery",{})
	if cemetery.is_empty() or int(cemetery.get("triangles",0))<2000 \
			or float(cemetery["bounds"]["size"][0])<7.8 or float(cemetery["bounds"]["size"][2])<5.3 \
			or float(cemetery["bounds"]["size"][0])>8.3 or float(cemetery["bounds"]["size"][2])>5.8:
		failures.append("cemetery inventory omitted fence/crosses/pit geometry")
	# Ресурс существующих GLB должен остаться действительным после main HQ conversion.
	var mill: Dictionary=owners.get("retained/public/mill",{})
	if not mill.is_empty():
		var actual_hq:=0
		for material: Dictionary in mill["materials"]:
			if material["quality"]=="hq": actual_hq+=1
		print("retained main boot mill: triangles=",mill["triangles"]," HQ-materials=",actual_hq," preset=",chain.render_preset())
	var output: Dictionary={"preset":chain.render_preset(),"base":counts,"cars":cars,"interiors":interiors,"farm":farm,"objects":rows,"failures":failures}
	var file:=FileAccess.open("C:/Users/Peter Zakharov/Desktop/vitya-godot/output/environment-refresh/retained-main-boot.json",FileAccess.WRITE)
	if file!=null: file.store_string(JSON.stringify(output,"\t"));file.close()
	_finish(main,rows)


func _renderer_metadata() -> void:
	var source:=MeshInstance3D.new()
	var residual:=MeshInstance3D.new()
	source.mesh=BoxMesh.new()
	source.layers=0
	residual.mesh=BoxMesh.new()
	if RETAINED._renderer(source)!=null: failures.append("hidden source without residual became visible")
	source.set_meta("environment_residual",residual)
	if RETAINED._renderer(source)!=residual: failures.append("environment residual was omitted without optional skin metadata")
	residual.layers=0
	if RETAINED._renderer(source)!=null: failures.append("hidden residual became visible")
	source.remove_meta("environment_residual")
	source.set_meta("skin_residual",residual)
	residual.layers=1
	if RETAINED._renderer(source)!=residual: failures.append("skin residual was omitted without optional environment metadata")
	source.free()
	residual.free()


func _batched_metadata() -> void:
	var world:=Node3D.new()
	root.add_child(world)
	var source:=MeshInstance3D.new()
	source.position=Vector3(4,2,-3)
	source.layers=0
	var mesh:=ArrayMesh.new()
	var proxies: Array[MeshInstance3D]=[]
	var mapping: Dictionary={}
	for surface in 2:
		var arrays: Array=[]
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX]=PackedVector3Array([Vector3(surface*2,0,0),Vector3(surface*2+1,0,0),Vector3(surface*2,1,0)])
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		var proxy:=MeshInstance3D.new()
		proxy.mesh=BoxMesh.new()
		proxy.material_override=StandardMaterial3D.new()
		proxy.material_override.albedo_color=Color(.2+surface*.3,.3,.4)
		proxy.position=Vector3(100+surface*10,0,0)
		world.add_child(proxy)
		proxies.append(proxy)
		mapping[surface]={"node":proxy,"surface":0}
	source.mesh=mesh
	world.add_child(source)
	source.set_meta("environment_static_batch_owner",123)
	source.set_meta("environment_static_batch_surfaces",mapping)
	var row:=RETAINED._row("fixture","interior-prop","fixture","test")
	RETAINED._mesh_tree(world,source,row)
	RETAINED._finish(row)
	if int(row["triangles"])!=2 or row["materials"].size()!=2 or row["nodes"].size()!=2:
		failures.append("mapped multi-surface inventory omitted logical geometry or actual materials")
	if GameData.vec3(row["bounds"]["min"]).distance_to(Vector3(4,2,-3))>.0001 or GameData.vec3(row["bounds"]["size"]).distance_to(Vector3(3,1,0))>.0001:
		failures.append("mapped owner inherited whole shared proxy bounds")
	for surface in 2:
		if RETAINED._renderer(source,surface)!=proxies[surface]: failures.append("wrong per-surface actual proxy")
	mapping.erase(1)
	if RETAINED._renderer(source)!=null: failures.append("partial batch mapping accepted as full owner")
	mapping[1]={"node":proxies[1],"surface":0}
	proxies[1].layers=0
	if RETAINED._renderer(source)!=null: failures.append("hidden batch proxy accepted as displayed geometry")
	world.free()


func _counts(col: CollisionWorld) -> Array:
	return [col.box_count(CollisionWorld.SET_STATIC),col.box_count(CollisionWorld.SET_BLOCKERS),col.box_count(CollisionWorld.SET_PROPS),col.box_count(CollisionWorld.SET_OVERLAY)]


func _scene_signature(node: Node) -> Array:
	var result: Array=[]
	for child: Node in node.get_children():
		var value: Array=[child.get_instance_id(),String(child.name)]
		if child is Node3D: value.append((child as Node3D).transform)
		if child is MeshInstance3D: value.append((child as MeshInstance3D).mesh.get_instance_id() if (child as MeshInstance3D).mesh!=null else 0)
		value.append(_scene_signature(child))
		result.append(value)
	return result


func _finish(main: Node,rows: Array) -> void:
	for failure: String in failures: printerr("test_environment_retained: ",failure)
	print("test_environment_retained: %s owners=%d failures=%d" % ["PASS" if failures.is_empty() else "FAIL",rows.size(),failures.size()])
	main.queue_free()
	await process_frame
	await process_frame
	quit(0 if failures.is_empty() else 1)

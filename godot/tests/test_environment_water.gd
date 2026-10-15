## Winding/нормали/глубина и мокрая кромка без GPU и изменения физики.
extends SceneTree

var errors: Array[String]=[]

func _initialize() -> void:
	Materials.render_hq_enabled=true
	var mats:=Materials.new().load_all()
	var col:=CollisionWorld.new();var world:=Node3D.new();root.add_child(world)
	var built:=WorldBuilder.build(world,mats,col)
	var dirt_params: Dictionary=mats.get_mat("dirt").get_meta("skin_hq_params",{}).duplicate()
	var report: Dictionary={"surfaces":[],"geometry_verified":false,"visual_verified":false,"errors":[]}
	var before:=OS.get_cmdline_user_args().has("--capture-before")
	for id: String in ["story-lake","snt-lake"]:
		var water:=world.get_node(id+"-surface") as MeshInstance3D
		var data:=water.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array=data[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array=data[Mesh.ARRAY_NORMAL]
		var colors: PackedColorArray=data[Mesh.ARRAY_COLOR]
		var correct:=0;var reversed:=0;var degenerate:=0
		var low:=1.0;var high:=0.0
		var normal_deviation:=0.0
		for k in range(0,vertices.size(),3):
			var cross: Vector3=(vertices[k+1]-vertices[k]).cross(vertices[k+2]-vertices[k])
			if cross.length_squared()<.00000000001: degenerate+=1
			elif cross.dot(normals[k])<0.0: correct+=1
			else: reversed+=1
		for k in colors.size():
			low=minf(low,colors[k].r);high=maxf(high,colors[k].r)
			normal_deviation=maxf(normal_deviation,normals[k].distance_to(Vector3.UP))
			if colors[k].a!=1.0: errors.append(id+" water color has opacity")
		if normal_deviation>.001: errors.append(id+" water normal is not UP")
		var material:=water.material_override as ShaderMaterial
		Materials.set_material_quality(material,true)
		var texture:=material.get_shader_parameter("water_atlas") as Texture2D
		var wet:=world.get_node_or_null(id+"-wet-bank") as MeshInstance3D
		var wettris:=0
		if wet!=null:
			var wet_material:=wet.material_override as ShaderMaterial
			var wet_id:=wet_material.get_instance_id()
			for hq: bool in [true,false,true]:
				Materials.set_material_quality(wet_material,hq)
				if wet.material_override.get_instance_id()!=wet_id: errors.append(id+" wet material identity changed")
				if hq and (wet_material.get_shader_parameter("use_vertex_color")!=true or not is_equal_approx(float(wet_material.get_shader_parameter("roughness_value")),.65)):
					errors.append(id+" wet bank lost HQ overrides during quality roundtrip")
			if mats.get_mat("dirt").get_meta("skin_hq_params",{})!=dirt_params: errors.append(id+" wet bank changed shared dirt metadata")
			var wet_arrays:=wet.mesh.surface_get_arrays(0)
			var wet_vertices: PackedVector3Array=wet_arrays[Mesh.ARRAY_VERTEX]
			wettris=wet_vertices.size()/3
			for k in range(0,wet_vertices.size(),3):
				if (wet_vertices[k+1]-wet_vertices[k]).cross(wet_vertices[k+2]-wet_vertices[k]).y>=0: errors.append(id+" wet bank reversed")
		report["surfaces"].append({"id":id,"triangles":vertices.size()/3,"clockwise_up":correct,"reversed_up":reversed,
			"degenerate":degenerate,"depth_min":low,"depth_max":high,"normal_up":normal_deviation<.001,"normal_max_deviation":normal_deviation,"shader":material.shader.resource_path,
			"atlas_present":texture!=null,"atlas_size":[texture.get_width(),texture.get_height()] if texture!=null else [],
			"wet_bank_triangles":wettris,"water_surface_count":water.mesh.get_surface_count()})
		if not before:
			if reversed!=0 or correct==0: errors.append(id+" top water winding is not clockwise")
			if low>.001 or high<.95: errors.append(id+" has no shallow/deep vertex range")
			if wettris==0: errors.append(id+" wet bank absent")
			if texture==null: errors.append(id+" water atlas absent")
		if material.shader.resource_path!="res://shaders/environment_water.gdshader": errors.append(id+" quality sweep replaced custom water")
		if material.shader.code.contains("ALPHA") or not material.shader.code.contains("depth_draw_opaque"): errors.append(id+" water is not opaque depth-writing")
		if material.shader.code.contains("TIME"): errors.append(id+" shader bypasses pause-safe explicit clock")
	if col.box_count(CollisionWorld.SET_STATIC)!=311 or col.box_count(CollisionWorld.SET_BLOCKERS)!=4 or int(built["triangles"])!=3885: errors.append("base changed")
	if not before: _ground(world,report)
	report["errors"]=errors;report["geometry_verified"]=errors.is_empty() and not before
	var file:=FileAccess.open("C:/Users/Peter Zakharov/Desktop/vitya-godot/output/environment-refresh/water-winding-"+("before" if before else "after")+".json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	for error: String in errors: printerr("water: ",error)
	print("test_environment_water: ","CAPTURE" if before else "PASS" if errors.is_empty() else "FAIL",report["surfaces"])
	world.free();quit(0 if errors.is_empty() else 1)

func _ground(world: Node3D,report: Dictionary) -> void:
	var tested:=0;var soil:=0;var route_triangles: Array=[]
	for node: Node in world.get_children():
		if not node is MeshInstance3D or not String(node.name).contains("visual"): continue
		var mi:=node as MeshInstance3D
		if mi.mesh==null: continue
		var transform:=EnvironmentRetained._transform(world,mi)
		for surface in mi.mesh.get_surface_count():
			var arrays:=mi.mesh.surface_get_arrays(surface)
			var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array=arrays[Mesh.ARRAY_NORMAL]
			if normals.size()!=vertices.size(): continue
			for k in range(0,vertices.size(),3):
				var p:=transform*vertices[k];var q:=transform*vertices[k+1];var r:=transform*vertices[k+2]
				if absf(p.y-q.y)>.00002 or absf(p.y-r.y)>.00002: continue
				if not (is_equal_approx(p.y,.021) or is_equal_approx(p.y,.023) or is_equal_approx(p.y,.007)): continue
				if normals[k].y<.99: continue
				tested+=1
				if (q-p).cross(r-p).y>=0: errors.append("soil/route top reversed "+String(mi.name));return
				if is_equal_approx(p.y,.007): soil+=1
				if is_equal_approx(p.y,.021): route_triangles.append([Vector2(p.x,p.z),Vector2(q.x,q.z),Vector2(r.x,r.z)])
	var lines:=EnvironmentLandscape.route_lines();var coverage: Array=[]
	for route in lines.size():
		var hits:=0
		for span in lines[route].size()-1:
			var p: Vector2=(lines[route][span]+lines[route][span+1])*.5
			var found:=false
			for tri: Array in route_triangles:
				if Geometry2D.is_point_in_polygon(p,PackedVector2Array(tri)): found=true;break
			if found: hits+=1
			else: errors.append("route visual midpoint missing: %d/%d" % [route,span])
		coverage.append({"route":route,"segments":lines[route].size()-1,"covered":hits})
	if tested==0 or soil==0 or lines.size()!=7: errors.append("ground guard has no soil or seven routes")
	report["ground"]={"checked_top_triangles":tested,"soil_triangles":soil,"route_coverage":coverage}

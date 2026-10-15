## Новые public-детали не меняют физику, владельцев и ходовые/смотровые проёмы.
extends SceneTree

const PUBLIC := preload("res://src/environment_public.gd")
const RETAINED := preload("res://src/environment_retained.gd")
var failures: Array[String]=[]


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Materials.render_hq_enabled=true
	var mats:=Materials.new();mats.load_all()
	var col:=CollisionWorld.new()
	var world:=Node3D.new();root.add_child(world)
	var built:=WorldBuilder.build(world,mats,col)
	var props:=Props.new(mats);var data:=GameData.props()
	props.load_models(data["PROPS"]);props.build(world,data["PROPS"],col)
	var physics:=col._data.duplicate(true)
	var active:=col._active.duplicate(true)
	var original:=_snapshot(world)
	var nav:=FileAccess.get_sha256("res://data/nav_baked.json")
	var before:=RETAINED.apply(world,built,mats)
	var report: Dictionary=PUBLIC.apply(world,built,mats)
	if col._data!=physics or col._active!=active: failures.append("public layer changed exact14 physics or blocker state")
	if FileAccess.get_sha256("res://data/nav_baked.json")!=nav: failures.append("public layer changed navgraph")
	for node: Node in original:
		if _signature(node)!=original[node]: failures.append("original owner modified: "+String(node.name))
	if OS.get_cmdline_user_args().has("--environment=off"):
		if report["active"] or report["newtris"]!=0 or _snapshot(world).size()!=original.size(): failures.append("environment=off is not a no-op")
	else:
		_check(report["active"] and report["objects"].size()==7,"expected seven decorated public sites")
		_check(int(report["newtris"])>1000 and int(report["newtris"])<=8000,"construction triangle budget")
		_check(int(report["surfaces"])<=24,"construction surface budget")
		var after:=RETAINED.apply(world,built,mats)
		var prior: Dictionary={}
		var current: Dictionary={}
		for row: Dictionary in before: prior[row["owner"]]=int(row["triangles"])
		for row: Dictionary in after: current[row["owner"]]=int(row["triangles"])
		for row: Dictionary in report["objects"]:
			var id:=String(row["owner"]).get_slice("/",2)
			_check(int(current.get("retained/public/"+id,0))>int(prior.get("retained/public/"+id,0)),"retained inventory missed new "+id)
			_check(row["features"].size()>=3 and row["controlviews"].size()>0,"missing construction/view refs "+id)
			for path: String in row["nodes"]:
				var mi:=world.get_node(path) as MeshInstance3D
				_check(mi.mesh.get_surface_count()==1,"unbatched material surface "+path)
				_check(mi.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,"new public geometry casts shadows")
				_check(mi.has_meta("skin_parts") and not mi.get_meta("skin_parts").is_empty(),"new public geometry has no owner")
		var cottage: Dictionary=OutskirtsWorld.data()["HENS"]["coop"]
		var box: Array=cottage["box"]
		var d0:=float(box[1])-1.12;var d1:=float(box[1])-.04;var z:=float(box[3])
		for x: float in [d0+.18,(d0+d1)*.5,d1-.18]:
			for y: float in [.30,1.0,1.73]: _clear_ray(world,report,Vector3(x,y,z+.35),Vector3(x,y,z-.35),"cottage inherited door")
		for y: float in [.30,1.0,1.75]: _clear_ray(world,report,Vector3(-5.90,y,17.65),Vector3(-5.90,y,18.35),"greenhouse north entrance")
		_clear_ray(world,report,Vector3(-24.0,1.70,-9.0),Vector3(-24.0,.70,-9.0),"well hollow crib")
		for x: float in [-43.5,-42.6,-41.6]: _clear_ray(world,report,Vector3(x,1.75,-5.2),Vector3(x,1.75,-6.9),"stop open front")
		for y: float in [.30,1.0,1.73]: _clear_ray(world,report,Vector3(19.28,y,-25.95),Vector3(19.28,y,-26.50),"mill inherited door")
		for y: float in [.35,1.0,1.25]: _clear_ray(world,report,Vector3(40.05,y,-7.20),Vector3(40.05,y,-7.80),"cemetery inherited gate")
		var count:=_snapshot(world).size()
		var again:=PUBLIC.apply(world,built,mats)
		_check(count==_snapshot(world).size() and again["newtris"]==report["newtris"],"public apply duplicated geometry")
	_check(col.box_count(CollisionWorld.SET_STATIC)==311 and col.box_count(CollisionWorld.SET_BLOCKERS)==4 \
		and col.box_count(CollisionWorld.SET_PROPS)==83 and int(built["triangles"])==3885,"base311/4/83/3885")
	for error: String in report["errors"]: failures.append(error)
	report["test_failures"]=failures
	report["capture_stage"]="public geometry unit; main applies final material quality"
	var suffix: String="-off" if OS.get_cmdline_user_args().has("--environment=off") else ""
	var file:=FileAccess.open("C:/Users/Peter Zakharov/Desktop/vitya-godot/output/environment-refresh/public-construction-unit"+suffix+".json",FileAccess.WRITE)
	if file!=null: file.store_string(JSON.stringify(report,"\t"));file.close()
	props.dispose();world.free()
	for failure: String in failures: printerr("test_environment_public: ",failure)
	print("test_environment_public: %s sites=%d surfaces=%d newtris=%d" % ["PASS" if failures.is_empty() else "FAIL",report["objects"].size(),report["surfaces"],report["newtris"]])
	quit(0 if failures.is_empty() else 1)


func _check(condition: bool,message: String) -> void:
	if not condition: failures.append(message)


func _snapshot(node: Node) -> Dictionary:
	var out: Dictionary={node:_signature(node)}
	for child: Node in node.get_children(): out.merge(_snapshot(child))
	return out


func _signature(node: Node) -> Array:
	var out: Array=[String(node.name),node.get_parent().get_instance_id() if node.get_parent()!=null else 0]
	if node is Node3D: out.append((node as Node3D).transform)
	if node is MeshInstance3D:
		var mi:=node as MeshInstance3D
		out.append(mi.mesh.get_instance_id() if mi.mesh!=null else 0);out.append(mi.layers);out.append(mi.visible)
	return out


func _clear_ray(world: Node3D,report: Dictionary,a: Vector3,b: Vector3,label: String) -> void:
	for row: Dictionary in report["objects"]:
		for path: String in row["nodes"]:
			var mi:=world.get_node(path) as MeshInstance3D
			var transform:=RETAINED._transform(world,mi)
			var vertices: PackedVector3Array=mi.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
			for index in range(0,vertices.size(),3):
				if Geometry3D.segment_intersects_triangle(a,b,transform*vertices[index],transform*vertices[index+1],transform*vertices[index+2])!=null:
					failures.append(label+" blocked by new visual "+path)
					return

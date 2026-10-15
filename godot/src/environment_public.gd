## Строительные детали сохранённых общественных мест. Только видимые поверхности.
class_name EnvironmentPublic
extends RefCounted

const GEOMETRY := preload("res://src/detailed_props.gd")
const OWNERS := {
	"greenhouse":"buildings/site/greenhouse", "stop":"buildings/village/STOP",
	"well":"buildings/village/WELL", "mill":"buildings/outskirts/MILL",
	"hens-cottage":"buildings/outskirts/HENS-coop", "shower":"interiors/environment/public-shower",
	"cemetery":"buildings/village/GRAVEYARD",
}


static func apply(world: Node3D,built: Dictionary,mats: Materials) -> Dictionary:
	var report: Dictionary={"active":false,"objects":[],"newtris":0,"surfaces":0,"resources":[],"errors":[],"material_capture_stage":"apply-time; final material quality is recorded by EnvironmentRetained after main quality sweep"}
	if OS.get_cmdline_user_args().has("--environment=off"): return report
	if world.has_meta("environment_public_report"): return world.get_meta("environment_public_report")
	report["active"]=true
	for id: String in OWNERS:
		var parent:=world
		if id=="shower":
			parent=world.get_node_or_null("props/summer-shower") as Node3D
			if parent==null: report["errors"].append("summer-shower owner absent");continue
		var context: Dictionary={"id":id,"surfaces":{},"features":[],"parent":parent,"owner":OWNERS[id],"mats":mats}
		match id:
			"greenhouse": _greenhouse(context,GameData.site()["ROOMS"]["greenhouse"])
			"stop": _stop(context,VillageWorld.data()["STOP"])
			"well": _well(context,VillageWorld.data()["WELL"])
			"mill": _mill(context,OutskirtsWorld.data()["MILL"])
			"hens-cottage": _cottage(context,OutskirtsWorld.data()["HENS"]["coop"])
			"shower": _shower(context,_relative(world,parent).origin)
			"cemetery": _cemetery(context,VillageWorld.data()["GRAVEYARD"])
		var row:=_finish(world,context)
		report["objects"].append(row)
		report["newtris"]+=row["newtris"]
		report["surfaces"]+=row["surfaces"]
		for resource: String in row["resources"]:
			if not report["resources"].has(resource): report["resources"].append(resource)
	if int(report["newtris"])>8000 or int(report["surfaces"])>24: report["errors"].append("public construction budget exceeded")
	world.set_meta("environment_public_report",report)
	# Поздний EnvironmentRetained обходит реальные меши, включая эти owner ranges.
	built["public_environment"]=report
	return report


static func _greenhouse(c: Dictionary,d: Dictionary) -> void:
	var x0:=float(d["x"][0]);var x1:=float(d["x"][1])
	var z0:=float(d["z"][0]);var z1:=float(d["z"][1]);var h:=float(d["h"])
	for x: float in [x0-.025,x1+.025]:
		_box(c,"wetwood",Vector3(x,.13,(z0+z1)*.5),Vector3(.06,.20,z1-z0))
		_box(c,"metal",Vector3(x,h+.015,(z0+z1)*.5),Vector3(.045,.035,z1-z0+.08))
		for index in 7:
			var z:=lerpf(z0,z1,float(index)/6.0)
			_box(c,"metal",Vector3(x,.29,z),Vector3(.026,.11,.09))
			_bolt(c,Vector3(x+(.018 if x>x1 else -.018),.30,z),Vector3.RIGHT)
	_box(c,"wetwood",Vector3((x0+x1)*.5,.13,z1+.024),Vector3(x1-x0,.20,.06))
	# Северный вход занимает последний метр: обвязка заканчивается у прежней стены.
	_box(c,"wetwood",Vector3((x0+x1-1)*.5,.13,z0-.025),Vector3(x1-1-x0,.20,.06))
	for z: float in [z0,z1]:
		_box(c,"metal",Vector3((x0+x1)*.5,h+.016,z),Vector3(x1-x0,.038,.055))
		for x: float in [x0+.04,x1-.04]: _bolt(c,Vector3(x,h+.04,z),Vector3.UP)
	c["features"]=["wet lower timber belt; original north entrance gap","post straps and square-head fasteners","roof edge seals"]


static func _stop(c: Dictionary,d: Dictionary) -> void:
	var x0:=float(d["x"][0]);var x1:=float(d["x"][1])
	var z0:=float(d["z"][0]);var z1:=float(d["z"][1]);var e:=float(d["eave"]);var r:=float(d["ridge"])
	for z: float in [z0+.16,(z0+z1)*.5,z1-.08]:
		_box(c,"boards",Vector3((x0+x1)*.5,e-.045,z),Vector3(x1-x0-.20,.075,.075))
	for x: float in [x0+.22,x1-.22]:
		var side:=1.0 if x<(x0+x1)*.5 else -1.0
		_beam(c,"boards",Vector3(x,e-.08,z1-.06),Vector3(x+side*.42,e-.37,z1-.06),.065,.065)
		_box(c,"metal",Vector3(x,e-.09,z1+.015),Vector3(.15,.19,.025))
		for dy: float in [-.045,.045]: _bolt(c,Vector3(x,e-.09+dy,z1+.038),Vector3.BACK)
	for x: float in [x0-.23,x1+.23]:
		_beam(c,"tin",Vector3(x,r+.013,(z0+z1)*.5),Vector3(x,e+.02,z0-.24),.028,.075)
		_beam(c,"tin",Vector3(x,r+.013,(z0+z1)*.5),Vector3(x,e-.04,z1+.34),.028,.075)
	_box(c,"tin",Vector3((x0+x1)*.5,r+.028,(z0+z1)*.5),Vector3(x1-x0+.52,.035,.19))
	for x: float in [x0+.18,x1-.18]: _bolt(c,Vector3(x,r+.054,(z0+z1)*.5),Vector3.UP)
	_box(c,"tin",Vector3((x0+x1)*.5,e-.057,z1+.32),Vector3(x1-x0+.50,.035,.09))
	c["features"]=["three canopy purlins and edge knee braces","bolted front brackets","roof end flashing and ridge seam; schedule remains clear"]


static func _well(c: Dictionary,d: Dictionary) -> void:
	var x0:=float(d["crib"][0]);var x1:=float(d["crib"][1])
	var z0:=float(d["crib"][2]);var z1:=float(d["crib"][3]);var h:=float(d["cribH"]);var p:=float(d["postH"]);var r:=float(d["roof"])
	var x: float=(x0+x1)*.5;var z: float=(z0+z1)*.5
	for sx: float in [x0+.068,x1-.068]: _box(c,"boards",Vector3(sx,h+.022,z),Vector3(.135,.044,z1-z0))
	for sz: float in [z0+.068,z1-.068]: _box(c,"boards",Vector3(x,h+.022,sz),Vector3(x1-x0-.27,.044,.135))
	for sz: float in [z0+.07,z1-.07]:
		_box(c,"boards",Vector3(x,p+.04,sz),Vector3(x1-x0+.22,.08,.075))
		for side: float in [-1,1]: _beam(c,"boards",Vector3(x+side*.04,p-.18,sz),Vector3(x+side*.28,p+.025,sz),.045,.045)
		# Пластины охватывают опору; отверстие и вращающийся барабан остаются открыты.
		for side: float in [-1,1]:
			_box(c,"metal",Vector3(x+side*.10,p-.12,sz),Vector3(.028,.19,.023))
			for dy: float in [-.06,.06]: _bolt(c,Vector3(x+side*.10,p-.12+dy,sz+(.02 if sz>z else -.02)),Vector3.FORWARD)
	for sx: float in [x0-.02,x1+.02]:
		for sz: float in [z0+.17,z1-.17]:
			_box(c,"metal",Vector3(sx,.48,sz),Vector3(.028,.56,.07))
			_bolt(c,Vector3(sx+(.018 if sx>x else -.018),.70,sz),Vector3.RIGHT)
	_box(c,"tin",Vector3(x,r+.036,z),Vector3(x1-x0+.70,.034,.16))
	for sx: float in [x0-.16,x1+.16]: _bolt(c,Vector3(sx,r+.065,z),Vector3.UP)
	c["features"]=["open crib coping and timber header joints","bearing-side straps around original rotating drum","corner repair straps and ridge cap"]


static func _mill(c: Dictionary,d: Dictionary) -> void:
	var at:=GameData.vec3(d["at"]);var k:=float(d.get("scale",1.3))/.65;var half:=1.375*k
	var door:=at.x-.86*k;var front:=at.z+half
	for sx: float in [-1,1]:
		for sz: float in [-1,1]:
			_box(c,"boards",Vector3(at.x+sx*(half+.017),2.01,at.z+sz*(half+.017)),Vector3(.075,3.86,.075))
	for x: float in [door-.59,door+.59]: _box(c,"boards",Vector3(x,1.11,front+.025),Vector3(.078,2.22,.055))
	_box(c,"boards",Vector3(door,2.267,front+.025),Vector3(1.27,.075,.055))
	for z: float in [at.z-half-.023,at.z+half+.023]:
		if z<at.z: _box(c,"boards",Vector3(at.x,.18,z),Vector3(half*2,.15,.045))
		else:
			for span: Array in [[at.x-half,door-.55],[door+.55,at.x+half]]:
				_box(c,"boards",Vector3((float(span[0])+float(span[1]))*.5,.18,z),Vector3(float(span[1])-float(span[0]),.15,.045))
	for index in 4:
		_box(c,"boards",Vector3(at.x+.62+float(index)*.16,1.16,at.z-half-.046),Vector3(.145,.85,.027))
	for x: float in [at.x+.62,at.x+1.10]:
		for y: float in [.82,1.48]: _bolt(c,Vector3(x,y,at.z-half-.068),Vector3.FORWARD)
	c["features"]=["lower tower corner boards","door casing outside inherited opening","split base belt and north-side repair patch; windows and blades untouched"]


static func _cottage(c: Dictionary,d: Dictionary) -> void:
	var b: Array=d["box"];var x0:=float(b[0]);var x1:=float(b[1]);var z0:=float(b[2]);var z1:=float(b[3]);var h:=float(d["y"])
	var d0:=x1-1.12;var d1:=x1-.04
	for x: float in [x0-.027,x1+.027]: _box(c,"boards",Vector3(x,h*.5,z0-.024),Vector3(.068,h,.058))
	_box(c,"boards",Vector3(x0-.025,h*.5,z1+.025),Vector3(.066,h,.056))
	# Восточный угол стоит на боковой стене: у правого косяка всего четыре сантиметра.
	_box(c,"boards",Vector3(x1+.034,h*.5,z1-.10),Vector3(.055,h,.17))
	for x: float in [d0-.032,d1+.018]: _box(c,"trim",Vector3(x,.97,z1+.035),Vector3(.035,1.90,.048))
	_box(c,"trim",Vector3((d0+d1)*.5,1.967,z1+.035),Vector3(d1-d0+.085,.080,.048))
	_box(c,"boards",Vector3((d0+d1)*.5,.018,z1+.065),Vector3(d1-d0,.035,.16))
	_window(c,Vector3(x0+.67,1.23,z1+.021),.78,.78,Basis.IDENTITY)
	_window(c,Vector3((x0+x1)*.5,1.23,z0-.021),1.04,.80,Basis(Vector3.UP,PI))
	_window(c,Vector3(x1+.021,1.23,z0+.83),.90,.80,Basis(Vector3.UP,PI*.5))
	var zm: float=(z0+z1)*.5
	for x: float in [x0-.20,x1+.20]:
		_beam(c,"boards",Vector3(x,h+.73,zm),Vector3(x,h-.02,z0-.21),.060,.075)
		_beam(c,"boards",Vector3(x,h+.73,zm),Vector3(x,h-.02,z1+.21),.060,.075)
	_box(c,"metal",Vector3((x0+x1)*.5,h+.756,zm),Vector3(x1-x0+.42,.035,.15))
	for x: float in [x0+.11,x1-.11]: _bolt(c,Vector3(x,h+.78,zm),Vector3.UP)
	c["features"]=["corner boards and door casing outside 1.08x1.92 inherited opening","three recessed closed windows on existing opaque walls","gable rake boards and fastened ridge cap"]


static func _window(c: Dictionary,at: Vector3,w: float,h: float,basis: Basis) -> void:
	_box(c,"window",at+basis*Vector3(0,0,.017),Vector3(w,h,.018),basis)
	for x: float in [-w*.5-.035,w*.5+.035]: _box(c,"trim",at+basis*Vector3(x,0,.065),Vector3(.070,h+.14,.075),basis)
	for y: float in [-h*.5-.035,h*.5+.035]: _box(c,"trim",at+basis*Vector3(0,y,.065),Vector3(w,.070,.075),basis)
	_box(c,"boards",at+basis*Vector3(0,0,.034),Vector3(.034,h,.025),basis)
	_box(c,"boards",at+basis*Vector3(0,-h*.5-.079,.079),Vector3(w+.17,.040,.16),basis)
	for x: float in [-w*.5-.035,w*.5+.035]: _bolt(c,at+basis*Vector3(x,h*.30,.108),basis*Vector3.BACK)


static func _shower(c: Dictionary,at: Vector3) -> void:
	_box(c,"boards",at+Vector3(0,.025,-.62),Vector3(.90,.045,.20))
	_box(c,"metal",at+Vector3(.32,1.045,-.58),Vector3(.054,.25,.020))
	for y: float in [.94,1.15]:
		_tube(c,"metal",at+Vector3(.32,y,-.58),at+Vector3(.32,y,-.63),.013)
	_tube(c,"metal",at+Vector3(.32,.94,-.63),at+Vector3(.32,1.15,-.63),.013)
	for x: float in [-.40,.40]:
		_box(c,"metal",at+Vector3(x,1.93,-.569),Vector3(.10,.13,.027))
		_bolt(c,at+Vector3(x,1.94,-.594),Vector3.FORWARD)
	c["features"]=["timber threshold","stand-off pull handle on existing closed north door","bolted upper tie plates"]


static func _cemetery(c: Dictionary,d: Dictionary) -> void:
	var x0:=float(d["x"][0]);var x1:=float(d["x"][1]);var z0:=float(d["z"][0]);var z1:=float(d["z"][1]);var h:=float(d["fenceH"])
	for x: float in [float(d["gate"][0]),float(d["gate"][1])]:
		_box(c,"metal",Vector3(x,h+.427,z1-.01),Vector3(.16,.022,.16))
		for y: float in [.32,.79]:
			_box(c,"metal",Vector3(x,y,z1+.049),Vector3(.13,.12,.022))
			_bolt(c,Vector3(x,y,z1+.068),Vector3.BACK)
	_beam(c,"metal",Vector3(x0+4.15,.27,z0-.050),Vector3(x0+5.18,.88,z0-.050),.026,.018)
	for x: float in [x0+4.15,x0+5.18]: _bolt(c,Vector3(x,.27 if x<x0+4.5 else .88,z0-.069),Vector3.FORWARD)
	for x: float in [x0+1.36,x1-1.12]:
		_box(c,"boards",Vector3(x,.60,z1-.048),Vector3(.08,.65,.023))
		for y: float in [.32,.84]: _bolt(c,Vector3(x,y,z1-.072),Vector3.FORWARD)
	c["features"]=["gate-post caps within existing post width","north fence repair tie and bolted joints","two reused timber fence repairs; gate and grave story points remain clear"]


static func _surface(c: Dictionary,key: String) -> SurfaceTool:
	if not c["surfaces"].has(key):
		var surface:=SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		c["surfaces"][key]=surface
	return c["surfaces"][key]


static func _box(c: Dictionary,key: String,at: Vector3,size: Vector3,basis:=Basis.IDENTITY) -> void:
	var mesh:=BoxMesh.new();mesh.size=size
	GEOMETRY._append(_surface(c,key),mesh,Transform3D(basis,at))


static func _beam(c: Dictionary,key: String,a: Vector3,b: Vector3,width: float,depth: float) -> void:
	_box(c,key,(a+b)*.5,Vector3(width,a.distance_to(b),depth),Basis(Quaternion(Vector3.UP,(b-a).normalized())))


static func _tube(c: Dictionary,key: String,a: Vector3,b: Vector3,radius: float) -> void:
	GEOMETRY._tube(_surface(c,key),a,b,radius,radius,8)


static func _bolt(c: Dictionary,at: Vector3,normal: Vector3) -> void:
	_tube(c,"metal",at-normal*.007,at+normal*.007,.018)


static func _finish(world: Node3D,c: Dictionary) -> Dictionary:
	var parent: Node3D=c["parent"]
	var group:=Node3D.new();group.name="environment-public-"+String(c["id"])
	parent.add_child(group)
	var bounds:=AABB();var first:=true
	var row: Dictionary={"owner":"environment/public/"+String(c["id"]),"sourceowners":[c["owner"]],
		"source_kind":"original-procedural-construction-detail","resources":["res://src/environment_public.gd"],
		"features":c["features"],"newtris":0,"surfaces":0,"nodes":[],"materials":[],"bounds":{},"controlviews":_views(c)}
	var materials: Materials=c["mats"]
	for key: String in c["surfaces"]:
		var surface: SurfaceTool=c["surfaces"][key]
		var arrays:=surface.commit_to_arrays()
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var box:=AABB(vertices[0],Vector3.ZERO)
		for p: Vector3 in vertices: box=box.expand(p)
		bounds=box if first else bounds.merge(box);first=false
		var centre:=box.get_center()
		for index in vertices.size(): vertices[index]-=centre
		arrays[Mesh.ARRAY_VERTEX]=vertices
		var mesh:=ArrayMesh.new();mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
		var material: Material=materials.physical(0x35474f,"",.28) if key=="window" else materials.physical(0x4f5144,"res://assets/tex/retro-shedwood.webp",.86) if key=="wetwood" else materials.get_mat(key)
		var mi:=MeshInstance3D.new();mi.name="merged_"+key+"_public"
		mi.mesh=mesh;mi.material_override=material
		mi.transform=_relative(world,parent).affine_inverse()*Transform3D(Basis.IDENTITY,centre)
		mi.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end=56.0;mi.visibility_range_end_margin=8.0
		mi.set_meta("environment_public_owner",row["owner"])
		mi.set_meta("skin_parts",{c["owner"]:[Vector2i(0,vertices.size())]})
		group.add_child(mi)
		row["newtris"]+=vertices.size()/3;row["surfaces"]+=1
		row["nodes"].append(String(world.get_path_to(mi)))
		var descriptor: Dictionary={"key":key,"shader":"","textures":[]}
		if material is ShaderMaterial:
			var shader:=material as ShaderMaterial
			descriptor["shader"]=shader.shader.resource_path
			for uniform: Dictionary in shader.shader.get_shader_uniform_list():
				var texture: Variant=shader.get_shader_parameter(uniform["name"])
				if texture is Texture2D:
					var path: String=texture.resource_path
					descriptor["textures"].append(path)
					if not row["resources"].has(path): row["resources"].append(path)
		row["materials"].append(descriptor)
	row["bounds"]={"min":[bounds.position.x,bounds.position.y,bounds.position.z],"size":[bounds.size.x,bounds.size.y,bounds.size.z]}
	return row


static func _relative(world: Node3D,node: Node3D) -> Transform3D:
	var result:=node.transform;var parent:=node.get_parent()
	if node==world: return Transform3D.IDENTITY
	while parent!=null and parent!=world:
		if parent is Node3D: result=(parent as Node3D).transform*result
		parent=parent.get_parent()
	return result


static func _views(c: Dictionary) -> Array:
	var out: Array=[]
	if not FileAccess.file_exists("res://data/environment_views.json"): return out
	var parsed: Variant=JSON.parse_string(FileAccess.get_file_as_string("res://data/environment_views.json"))
	if not parsed is Dictionary: return out
	var alias: String="summer-shower" if c["id"]=="shower" else "cemetery" if c["id"]=="cemetery" else String(c["owner"])
	for view: Dictionary in parsed.get("views",[]):
		if view.get("owner","")==alias: out.append({"source":"res://data/environment_views.json","id":view["id"],"eye":view["at"],"look":view["target"]})
	return out

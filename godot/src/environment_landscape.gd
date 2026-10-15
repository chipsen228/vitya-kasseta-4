## Маршруты, дальняя опушка и низкий туман. Физический пол остаётся у районов.
class_name EnvironmentLandscape
extends RefCounted

const CENTRAL := [Vector2(15.2,-16.5), Vector2(15.2,-33.0),
	Vector2(13.0,-35.4), Vector2(13.0,-38.3), Vector2(12.2,-39.3)]
const EAST := [Vector2(37.95,-16.5), Vector2(37.95,-33.0), Vector2(37.95,-38.3)]
const SHORE := [Vector2(3.9,-42.2), Vector2(3.9,-49.7), Vector2(12.2,-49.7)]
const FOURTH := [Vector2(12.2,-54.7), Vector2(39.0,-54.7)]
const MAIN_SNT := [Vector2(12.2,-39.3),Vector2(12.2,-54.7),
	Vector2(-20.6,-54.7),Vector2(-20.6,-61.8),Vector2(3.4,-61.8)]
const SECOND_EAST := [Vector2(15.2,-16.5),Vector2(16.4,-18.1),
	Vector2(19.6,-18.1),Vector2(21.0,-16.5),Vector2(29.2,-16.5),
	Vector2(31.0,-16.2),Vector2(36.6,-16.2),Vector2(37.95,-16.5)]
const SECOND_WEST := [Vector2(-22.0,-16.5),Vector2(-21.6,-19.2),
	Vector2(-18.5,-19.2),Vector2(-17.7,-16.5),Vector2(-10.2,-16.5),
	Vector2(-8.7,-16.0),Vector2(2.2,-16.0),Vector2(3.4,-16.5),Vector2(15.2,-16.5)]
const ROUTE_WIDTHS := [2.4,2.0,1.4,2.0,2.4,2.0,2.0]
const FOG_SHADER := preload("res://shaders/environment_fog.gdshader")

static func route_lines() -> Array:
	return [CENTRAL,EAST,SHORE,FOURTH,MAIN_SNT,SECOND_EAST,SECOND_WEST]

static func route_footprints() -> Array:
	var out: Array = []
	var paths := route_lines()
	for route_index in paths.size():
		var path: Array = paths[route_index]
		for i in path.size()-1:
			var a: Vector2 = path[i]
			var c: Vector2 = path[i+1]
			out.append({"owner":"environment-route", "kind":"route",
				"rect":Rect2(Vector2(minf(a.x,c.x),minf(a.y,c.y)),
					Vector2(absf(a.x-c.x),absf(a.y-c.y))).grow(float(ROUTE_WIDTHS[route_index])*0.5)})
	return out

static func on_route(x: float, z: float, extra := 0.0) -> bool:
	var p := Vector2(x,z)
	var paths := route_lines()
	for route_index in paths.size():
		var path: Array = paths[route_index]
		for i in path.size()-1:
			if LakeVisuals._segment_distance(p,path[i],path[i+1]) < float(ROUTE_WIDTHS[route_index])*0.5+extra:
				return true
	return false

static func build(b: WorldBuilder) -> Dictionary:
	var clock_materials: Array = []
	for node: Node3D in b.decor.values():
		if node is MeshInstance3D and node.has_meta("environment_water"):
			clock_materials.append((node as MeshInstance3D).material_override)
	var far := _horizon(b)
	var fogs: Array = []
	# Короткие полосы среди опушек, вдали от дверей и сценарных целей.
	var rows := [[Vector3(-26,0.90,-32.5),15.0,1.9,0.14,0.067],
		[Vector3(-24,0.85,-27.5),13.0,1.8,-0.20,0.045],
		[Vector3(-8,0.90,-47.0),25.0,2.0,0.16,0.058],
		[Vector3(-9,1.05,-42.0),23.0,2.3,-0.13,0.073],
		[Vector3(-17.5,1.00,-57.5),11.0,2.2,0.24,0.061],
		[Vector3(-28,0.75,-30.3),12.0,1.6,-0.12,0.050]]
	for i in rows.size():
		var row: Array = rows[i]
		var mat := ShaderMaterial.new()
		mat.shader = FOG_SHADER
		mat.set_shader_parameter("density",float(row[4]))
		mat.set_shader_parameter("phase",float(i)*1.37)
		mat.set_shader_parameter("environment_time",0.0)
		var quad := QuadMesh.new()
		quad.size = Vector2(float(row[1]),float(row[2]))
		var node := MeshInstance3D.new()
		node.name = "environment-fog-%d" % i
		node.mesh = quad
		node.material_override = mat
		node.position = row[0]
		node.rotation.y = float(row[3])
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.set_meta("environment_fog",true)
		node.set_meta("depth_fade",true)
		node.set_meta("explicit_clock",true)
		b.decor[node.name] = node
		fogs.append(node)
		clock_materials.append(mat)
	_add_paths(b)
	_add_soil(b)
	return {"time":0.0,"materials":clock_materials,"fog_sheets":fogs,
		"far_draw_calls":far["surfaces"],"far_triangles":far["triangles"],
		"silhouettes":116,"terrain_mounds":12}

static func update(built: Dictionary, dt: float) -> void:
	var rural: Dictionary = built.get("rural",{})
	var landscape: Dictionary = rural.get("landscape",{})
	if landscape.is_empty() or dt <= 0.0:
		return
	landscape["time"] = float(landscape.get("time",0.0))+minf(dt,0.05)
	for mat: ShaderMaterial in landscape.get("materials",[]):
		mat.set_shader_parameter("environment_time",landscape["time"])

static func _add_paths(b: WorldBuilder) -> void:
	var paths := route_lines()
	for route_index in paths.size():
		var path: Array = paths[route_index]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in path.size()-1:
			var a: Vector2 = path[i]
			var c: Vector2 = path[i+1]
			var n := (c-a).normalized().orthogonal()*float(ROUTE_WIDTHS[route_index])*0.5
			_ground_quad(st,a-n,c-n,c+n,a+n,0.021,2.2)
		b.append_mesh("visual:dirt",st.commit())
		# Два следа обуви/колеи прерываются, чтобы тропа не стала ровным рельсом.
		var rut := SurfaceTool.new()
		rut.begin(Mesh.PRIMITIVE_TRIANGLES)
		for i in path.size()-1:
			var a: Vector2 = path[i]
			var c: Vector2 = path[i+1]
			var delta := c-a
			var count := maxi(1,int(delta.length()/1.1))
			var n := delta.normalized().orthogonal()
			for k in count:
				if k%4 == 3: continue
				for sign: float in [-1.0,1.0]:
					var p := a.lerp(c,float(k)/count)+n*0.26*sign
					var q := a.lerp(c,minf(1.0,(float(k)+0.73)/count))+n*0.26*sign
					_ground_quad(rut,p-n*0.08,q-n*0.08,q+n*0.08,p+n*0.08,0.023,1.4)
		b.append_mesh("visual:gravel",rut.commit())

static func _add_soil(b: WorldBuilder) -> void:
	var soils := {"dirt":SurfaceTool.new(),"gravel":SurfaceTool.new()}
	for st: SurfaceTool in soils.values(): st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for row: Array in [[-40.3,38.1,-33.9,-24.1],[-45.3,43.3,-71.3,-35.0]]:
		for i in 34:
			var seed := float(i)+absf(float(row[2]))*7.0
			var x := lerpf(float(row[0]),float(row[1]),0.5+0.46*sin(seed*2.317))
			var z := lerpf(float(row[2]),float(row[3]),0.5+0.44*cos(seed*1.719))
			if on_route(x,z,1.0) or b.col.point_hit(x,0.5,z,CollisionWorld.ALL_SOLID): continue
			var st: SurfaceTool = soils["gravel" if i%5 == 0 else "dirt"]
			var poly := PackedVector2Array()
			for k in 7:
				var angle := float(k)*TAU/7.0
				var radius := (1.0+0.23*sin(seed+float(k)*2.11))*(0.42 if i%5 == 0 else 1.65)
				poly.append(Vector2(x+cos(angle)*radius,z+sin(angle)*radius*0.66))
			var indices := Geometry2D.triangulate_polygon(poly)
			for k in range(0,indices.size(),3):
				_ground_triangle(st,poly[indices[k]],poly[indices[k+2]],poly[indices[k+1]],0.007,2.2)
	for key: String in soils:
		var mesh := (soils[key] as SurfaceTool).commit()
		if mesh != null: b.append_mesh("visual:"+key,mesh)

static func _ground_quad(st: SurfaceTool,a: Vector2,c: Vector2,d: Vector2,e: Vector2,y: float,scale: float) -> void:
	_ground_triangle(st,a,e,d,y,scale)
	_ground_triangle(st,a,d,c,y,scale)

static func _ground_triangle(st: SurfaceTool,a: Vector2,c: Vector2,d: Vector2,y: float,scale: float) -> void:
	var points := [a,c,d] if (c-a).cross(d-a)>0.0 else [a,d,c]
	for p: Vector2 in points:
		st.set_normal(Vector3.UP)
		st.set_uv(p/scale)
		st.add_vertex(Vector3(p.x,y,p.y))

static func _horizon(b: WorldBuilder) -> Dictionary:
	var earth := SurfaceTool.new()
	var forest := SurfaceTool.new()
	earth.begin(Mesh.PRIMITIVE_TRIANGLES)
	forest.begin(Mesh.PRIMITIVE_TRIANGLES)
	for rect: Rect2 in [Rect2(-100,-112,200,37),Rect2(-100,32,200,68),
		Rect2(-100,-75,40,107),Rect2(60,-75,40,107)]:
		_quad(earth,Vector3(rect.position.x,-0.33,rect.position.y),
			Vector3(rect.end.x,-0.33,rect.position.y),Vector3(rect.end.x,-0.33,rect.end.y),
			Vector3(rect.position.x,-0.33,rect.end.y),Color(0.30,0.34,0.26))
	for side in 2:
		for k in 6:
			_mound(earth,Vector3(-82 if side==0 else 82,-0.36,-83+float(k)*24),
				Vector3(19.0,2.1+float(k%3)*0.65,16.0),k+side*7)
	for side in 4:
		for k in 29:
			var t := float(k)/28.0
			var p := Vector3(lerpf(-90,90,t),0,-84 if side==0 else 45)
			if side>=2: p=Vector3(-65 if side==2 else 65,0,lerpf(-90,45,t))
			p+=Vector3(sin(float(k+side*19)*2.13),0,cos(float(k+side*13)*1.71))*2.4
			var seed := k+side*31
			var h := 6.5+3.1*(0.5+0.5*sin(float(seed)*1.71))
			_far_tree(forest,p,h,seed)
	for k in 12:
		var c := Vector3(-51+float(k)*9.3,3.2+float(k%2)*0.45,-79-float(k%3)*3)
		_quad(earth,c+Vector3(-3.2,0,-2.4),c+Vector3(3.2,0,-2.4),
			c+Vector3(3.2,1.3,0),c+Vector3(-3.2,1.3,0),Color(0.35,0.30,0.26))
		_quad(earth,c+Vector3(-3.2,1.3,0),c+Vector3(3.2,1.3,0),
			c+Vector3(3.2,0,2.4),c+Vector3(-3.2,0,2.4),Color(0.30,0.34,0.31))
	var mesh := earth.commit()
	var leaves := forest.commit()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,leaves.surface_get_arrays(0))
	var shader := Shader.new()
	shader.code="""shader_type spatial;
render_mode unshaded,cull_disabled;
global uniform vec3 psx_fog_color;
void fragment(){
	float fade=smoothstep(40.0,90.0,-VERTEX.z);
	ALBEDO=mix(COLOR.rgb*0.56+psx_fog_color*0.32,psx_fog_color,fade*0.88);
}"""
	var mat := ShaderMaterial.new()
	mat.shader=shader
	var node := Node3D.new()
	node.name="rural-horizon"
	var chunks := _horizon_chunks(mesh)
	for index in chunks.size():
		var chunk := MeshInstance3D.new()
		chunk.name="horizon-%d" % index
		chunk.mesh=chunks[index]
		chunk.material_override=mat
		chunk.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		chunk.set_meta("far_layer",true)
		chunk.set_meta("horizon_group",index)
		node.add_child(chunk)
	node.set_meta("far_layer",true)
	node.set_meta("silhouette_families",["pine","spruce","birch","broadleaf","dead"])
	node.set_meta("terrain_form","rounded-rings")
	node.set_meta("silhouette_count",116)
	node.set_meta("mound_count",12)
	node.set_meta("triangle_count",mesh.get_faces().size()/3)
	node.set_meta("draw_calls",chunks.size())
	b.decor[node.name]=node
	return {"triangles":mesh.get_faces().size()/3,"surfaces":chunks.size()}


## The original earth and forest share one opaque override material. Keep every
## complete triangle and its attributes; tighter AABBs provide ordinary culling.
static func _horizon_chunks(source: ArrayMesh) -> Array[ArrayMesh]:
	var groups: Array[Dictionary] = []
	var buffers: Array[Dictionary] = []
	var packed_surfaces: Array = source.get("_surfaces")
	for index in 6: groups.append({"v":[],"refs":[]})
	for surface in source.get_surface_count():
		var arrays := source.surface_get_arrays(surface)
		var points: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else points.size()
		var raw: Dictionary = packed_surfaces[surface].duplicate()
		var format: int = raw["format"]
		var vertex_count: int = raw["vertex_count"]
		raw["pstride"] = RenderingServer.mesh_surface_get_format_vertex_stride(format,vertex_count)
		raw["nstride"] = RenderingServer.mesh_surface_get_format_normal_tangent_stride(format,vertex_count)
		raw["nstart"] = RenderingServer.mesh_surface_get_format_offset(format,vertex_count,Mesh.ARRAY_NORMAL)
		raw["astride"] = RenderingServer.mesh_surface_get_format_attribute_stride(format,vertex_count)
		buffers.append(raw)
		for first in range(0,count,3):
			var ids := Vector3i(indices[first],indices[first+1],indices[first+2]) if not indices.is_empty() else Vector3i(first,first+1,first+2)
			var centre := (points[ids.x]+points[ids.y]+points[ids.z])/3.0
			var group := 0 if surface == 0 else _horizon_group(centre)
			for index: int in [ids.x,ids.y,ids.z]:
				(groups[group]["v"] as Array).append(points[index])
				(groups[group]["refs"] as Array).append(Vector2i(surface,index))
	var result: Array[ArrayMesh] = []
	for group: Dictionary in groups:
		var bounds := AABB(group["v"][0],Vector3.ZERO)
		for point: Vector3 in group["v"]: bounds = bounds.expand(point)
		result.append(_horizon_packed_mesh(group["refs"],buffers,bounds))
	return result


## Use ArrayMesh's serialized packed surface format. Decoding and repacking its
## octahedral normals/tangents would change bits even for an unchanged vertex.
static func _horizon_packed_mesh(refs: Array,buffers: Array[Dictionary],bounds: AABB) -> ArrayMesh:
	var positions := PackedByteArray()
	var normals_tangents := PackedByteArray()
	var attributes := PackedByteArray()
	for ref: Vector2i in refs:
		var raw: Dictionary = buffers[ref.x]
		assert(int(buffers[0]["format"]) == int(raw["format"]),"horizon vertex formats differ")
		var vertex_data: PackedByteArray = raw["vertex_data"]
		var attribute_data: PackedByteArray = raw["attribute_data"]
		var pstart: int = ref.y*int(raw["pstride"])
		var nstart: int = int(raw["nstart"])+ref.y*int(raw["nstride"])
		var astart: int = ref.y*int(raw["astride"])
		positions.append_array(vertex_data.slice(pstart,pstart+int(raw["pstride"])))
		normals_tangents.append_array(vertex_data.slice(nstart,nstart+int(raw["nstride"])))
		attributes.append_array(attribute_data.slice(astart,astart+int(raw["astride"])))
	positions.append_array(normals_tangents)
	var surface: Dictionary = buffers[0].duplicate()
	for key: String in ["pstride","nstride","nstart","astride"]: surface.erase(key)
	surface["vertex_count"] = refs.size()
	surface["vertex_data"] = positions
	surface["attribute_data"] = attributes
	surface["aabb"] = bounds
	surface["index_count"] = 0
	surface["index_data"] = PackedByteArray()
	var mesh := ArrayMesh.new()
	mesh.set("_surfaces",[surface])
	return mesh


static func _horizon_group(centre: Vector3) -> int:
	if centre.x < -54.0: return 1
	if centre.x > 54.0: return 2
	if centre.z < -50.0: return 5
	if centre.z > 0.0 and centre.x >= 0.0: return 4
	return 3

static func _mound(st: SurfaceTool,p: Vector3,size: Vector3,seed: int) -> void:
	var rings: Array = []
	for r in 3:
		var ring := PackedVector3Array()
		var radius: float = [1.0,0.72,0.28][r]
		for k in 10:
			var a := float(k)*TAU/10.0
			var wobble := 1.0+0.12*sin(float(seed*5+k)*1.91)
			ring.append(p+Vector3(cos(a)*size.x*radius*wobble,
				size.y*[0.0,0.63,0.97][r]+0.10*sin(float(k+seed)),sin(a)*size.z*radius*wobble))
		rings.append(ring)
	for r in 2:
		for k in 10:
			_quad(st,rings[r][k],rings[r][(k+1)%10],rings[r+1][(k+1)%10],rings[r+1][k],Color(0.27,0.32,0.24))
	for k in 10:
		_tri(st,rings[2][k],rings[2][(k+1)%10],p+Vector3(0,size.y,0),Color(0.31,0.35,0.27))

static func _far_tree(st: SurfaceTool,p: Vector3,h: float,seed: int) -> void:
	var kind := seed%6
	var bark := Color(0.39,0.42,0.37) if kind==2 else Color(0.19,0.22,0.18)
	var lean := Vector3(sin(float(seed)*1.73)*0.48,0,cos(float(seed)*1.31)*0.35)
	var top := p+Vector3(0,h,0)+lean
	_tube(st,p,top,0.11+0.028*float(seed%3),0.045,bark,5)
	if kind==5:
		for branch in 5:
			var a := float(branch)*2.31+float(seed)
			var start := p.lerp(top,0.28+float(branch)*0.11)
			var end := start+Vector3(cos(a),0.34,sin(a))*(1.2+float(branch%2)*0.60)
			_tube(st,start,end,0.09,0.025,bark,4)
			_tube(st,end,end+Vector3(0.15,0.7,-0.10),0.025,0.009,bark,3)
	elif kind<2:
		var color := Color(0.17,0.24,0.20) if kind==0 else Color(0.20,0.29,0.22)
		for tier in 4:
			var center := p.lerp(top,0.35+float(tier)*0.15)
			_ellipsoid(st,center,Vector3(2.0-float(tier)*0.34,h*0.18,1.65-float(tier)*0.26),color,seed+tier)
	else:
		var color := Color(0.29,0.35,0.23) if kind==2 else Color(0.19,0.27,0.20)
		for lobe in 3:
			var a := float(lobe)*TAU/3.0+float(seed)*0.18
			var center := p.lerp(top,0.62+float(lobe)*0.085)+Vector3(cos(a)*0.8,0,sin(a)*0.8)
			_tube(st,p.lerp(top,0.35),center,0.085,0.027,bark,4)
			_ellipsoid(st,center,Vector3(1.65+0.16*(seed%3),h*0.24,1.45),color,seed+lobe)

static func _ellipsoid(st: SurfaceTool,p: Vector3,size: Vector3,color: Color,seed: int) -> void:
	for band in 3:
		var a := -PI*0.5+float(band)*PI/3.0
		var c := -PI*0.5+float(band+1)*PI/3.0
		for k in 6:
			var u := float(k)*TAU/6.0
			var v := float(k+1)*TAU/6.0
			var shade := color*(0.87+0.05*float((k+seed)%4))
			_quad(st,p+Vector3(cos(u)*cos(a)*size.x,sin(a)*size.y,sin(u)*cos(a)*size.z),
				p+Vector3(cos(v)*cos(a)*size.x,sin(a)*size.y,sin(v)*cos(a)*size.z),
				p+Vector3(cos(v)*cos(c)*size.x,sin(c)*size.y,sin(v)*cos(c)*size.z),
				p+Vector3(cos(u)*cos(c)*size.x,sin(c)*size.y,sin(u)*cos(c)*size.z),shade)

static func _tube(st: SurfaceTool,a: Vector3,c: Vector3,r0: float,r1: float,color: Color,sides: int) -> void:
	var axis := (c-a).normalized()
	var right := axis.cross(Vector3.FORWARD).normalized()
	if right.length_squared()<0.01: right=axis.cross(Vector3.RIGHT).normalized()
	var front := axis.cross(right).normalized()
	for k in sides:
		var angle := float(k)*TAU/float(sides)
		var next := float(k+1)*TAU/float(sides)
		var u := right*cos(angle)+front*sin(angle)
		var v := right*cos(next)+front*sin(next)
		_quad(st,a+u*r0,a+v*r0,c+v*r1,c+u*r1,color)

static func _quad(st: SurfaceTool,a: Vector3,c: Vector3,d: Vector3,e: Vector3,color: Color) -> void:
	_tri(st,a,c,d,color)
	_tri(st,a,d,e,color)

static func _tri(st: SurfaceTool,a: Vector3,c: Vector3,d: Vector3,color: Color) -> void:
	var normal := (c-a).cross(d-a).normalized()
	if normal.length_squared()<0.01: return
	for p: Vector3 in [a,c,d]:
		st.set_normal(normal)
		st.set_color(color)
		st.set_uv(Vector2(p.x,p.z)*0.1)
		st.add_vertex(p)

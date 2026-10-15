class_name LakeVisuals
extends RefCounted

# Общая мягкая геометрия двух озёр. Форма всегда остаётся внутри переданного
# blocker-прямоугольника; сам blocker строители продолжают создавать как раньше.
const SHAPE := [
	Vector2(0.08, 0.25), Vector2(0.18, 0.07), Vector2(0.45, 0.02),
	Vector2(0.76, 0.08), Vector2(0.94, 0.27), Vector2(0.98, 0.58),
	Vector2(0.86, 0.88), Vector2(0.58, 0.98), Vector2(0.28, 0.93),
	Vector2(0.04, 0.70),
]
const WATER_ATLAS_V2 := "res://assets/atlases/waterway-psx-atlas-v2.png"
const HQ_WATER_SHADER := preload("res://shaders/environment_water.gdshader")

## Этот же union читают зеркало, берег и физические водные полосы.
static func waterway_polygons(outline: Variant, channels: Array = []) -> Array[PackedVector2Array]:
	var polygons: Array[PackedVector2Array] = []
	var sources: Array = [outline]
	sources.append_array(channels)
	for source: Variant in sources:
		var candidate := _points2(source)
		if candidate.size()<3: continue
		var merged := true
		while merged:
			merged=false
			for i in polygons.size():
				var union := Geometry2D.merge_polygons(polygons[i],candidate)
				if union.size()==1:
					candidate=union[0]
					polygons.remove_at(i)
					merged=true
					break
		polygons.append(candidate)
	return polygons


## Classify a world-space point against a waterway descriptor.  The descriptor
## accepts either add_waterway()'s return value ("outlines") or the compact
## JSON form used by outskirts.POND.water ("outline" + "shallow_edge").
## Deep water is geometry/collision policy; shallow is an explicit bank strip,
## so an unrelated rectangular grass zone can never mask water footsteps.
static func sample_water(point: Variant, waterway: Variant) -> String:
	if not (waterway is Dictionary):
		return "dry"
	var d: Dictionary = waterway
	var p := Vector2.ZERO
	if point is Vector3:
		p = Vector2(point.x, point.z)
	elif point is Vector2:
		p = point
	else:
		return "dry"
	var polygons: Array[PackedVector2Array] = []
	if d.get("outlines", null) is Array:
		for raw: Variant in d["outlines"]:
			var poly := _points2(raw)
			if poly.size() >= 3:
				polygons.append(poly)
	else:
		var poly := _points2(d.get("outline", []))
		if poly.size() >= 3:
			polygons.append(poly)
	var inside := false
	for poly: PackedVector2Array in polygons:
		if Geometry2D.is_point_in_polygon(p, poly):
			inside = true
			break
	if not inside:
		return "dry"
	var edge := _points2(d.get("shallow_edge", []))
	var width := float(d.get("shallow_width", 0.0))
	if edge.size() >= 2 and width > 0.0:
		for i in edge.size() - 1:
			if _segment_distance(p, edge[i], edge[i + 1]) <= width:
				return "shallow"
	return "deep"


static func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var den := ab.length_squared()
	if den <= 1e-9:
		return p.distance_to(a)
	var q := clampf((p - a).dot(ab) / den, 0.0, 1.0)
	return p.distance_to(a + ab * q)


static func add_lake(b: WorldBuilder, id: String, x0: float, x1: float,
		z0: float, z1: float, y: float) -> Dictionary:
	var outline := PackedVector2Array()
	for uv: Vector2 in SHAPE:
		outline.append(Vector2(lerpf(x0, x1, uv.x), lerpf(z0, z1, uv.y)))
	return add_waterway(b, id, outline, [], {"y": y, "kind": "legacy"})


## Arbitrary simple concave water polygon plus optional independently
## triangulated river arms. All surfaces are appended to existing buckets.
static func add_waterway(b: WorldBuilder, id: String, outline: Variant,
		channels: Array = [], variant: Variant = {}) -> Dictionary:
	var opts: Dictionary = variant if variant is Dictionary else {"kind": String(variant)}
	var y := float(opts.get("y", 0.02))
	var polygons := waterway_polygons(outline,channels)
	var all := PackedVector3Array()
	var triangle_count := 0
	var hq := Materials.render_hq_enabled
	var surface := SurfaceTool.new()
	var wet_bank: SurfaceTool=null
	if hq:
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		wet_bank=SurfaceTool.new();wet_bank.begin(Mesh.PRIMITIVE_TRIANGLES)
	for poly: PackedVector2Array in polygons:
		if poly.size() < 3:
			continue
		var indices := Geometry2D.triangulate_polygon(poly)
		if indices.is_empty():
			continue
		if hq:
			for i in range(0,indices.size(),3):
				_water_triangle(surface,poly,poly[indices[i]],poly[indices[i+1]],poly[indices[i+2]],y,0)
		else:
			b.append_mesh("water", _polygon(poly, y, indices, b.mats.get_mat("water"), false))
			triangle_count += indices.size() / 3
			var deep := _inset(poly, 0.72)
			var deep_indices := Geometry2D.triangulate_polygon(deep)
			if not deep_indices.is_empty():
				b.append_mesh("water", _polygon(deep, y + 0.0015, deep_indices,
					b.mats.get_mat("water"), true))
				triangle_count += deep_indices.size() / 3
			b.append_mesh("dirt", _ring2(poly, _inset(poly, 0.90),
				b.mats.get_mat("dirt"), y - 0.012))
		_dry_bank(b,poly,y,wet_bank)
		for p: Vector2 in poly:
			all.append(Vector3(p.x, y, p.y))
	if hq:
		var mat := ShaderMaterial.new()
		mat.shader=HQ_WATER_SHADER
		mat.set_shader_parameter("water_atlas",load(WATER_ATLAS_V2))
		mat.set_shader_parameter("environment_time",0.0)
		var water := MeshInstance3D.new()
		water.name=id+"-surface"
		water.mesh=surface.commit()
		water.material_override=mat
		water.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		water.set_meta("environment_water",true)
		water.set_meta("depth_write",true)
		water.set_meta("waterway_outlines",polygons)
		b.decor[water.name]=water
		triangle_count=water.mesh.get_faces().size()/3
		var wet_mesh:=wet_bank.commit()
		if wet_mesh!=null:
			var wet_material:=b.mats.get_mat("dirt").duplicate() as ShaderMaterial
			wet_material.set_shader_parameter("use_vertex_color",true)
			wet_material.set_shader_parameter("roughness_value",0.65)
			# The duplicate keeps dirt's quality metadata. Preserve the bank's
			# overrides across HQ -> retro -> HQ without changing shared dirt.
			var wet_params: Dictionary=wet_material.get_meta("skin_hq_params",{}).duplicate()
			wet_params["use_vertex_color"]=true
			wet_params["roughness_value"]=0.65
			wet_material.set_meta("skin_hq_params",wet_params)
			var edge:=MeshInstance3D.new();edge.name=id+"-wet-bank"
			edge.mesh=wet_mesh;edge.material_override=wet_material
			edge.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			edge.set_meta("environment_wet_bank",true);edge.set_meta("shared_water_contour",polygons)
			b.decor[edge.name]=edge
	var marker := Node3D.new()
	marker.name = id + "-waterway"
	marker.set_meta("point_count", all.size())
	marker.set_meta("polygon_count", polygons.size())
	marker.set_meta("triangle_count", triangle_count)
	marker.set_meta("concave", true)
	marker.set_meta("bucketed", not hq)
	marker.set_meta("single_surface", hq)
	marker.set_meta("depth_write", hq)
	marker.set_meta("waterway_outlines",polygons)
	marker.set_meta("source_polygon_count",1+channels.size())
	marker.set_meta("variant", String(opts.get("kind", "waterway")))
	marker.set_meta("texture_path", WATER_ATLAS_V2)
	marker.set_meta("layer_count", 1 if hq else 3)
	marker.set_meta("animated_samples", 2)
	marker.set_meta("max_displacement_m", 0.007)
	marker.set_meta("surface_y", y)
	b.decor[marker.name] = marker
	return {"id": id, "points": all, "outlines": polygons,
		"bounds": _bounds(polygons), "triangle_count": triangle_count}

static func _water_triangle(st: SurfaceTool,poly: PackedVector2Array,a: Vector2,c: Vector2,
		d: Vector2,y: float,level: int) -> void:
	if level<6 and maxf(a.distance_to(c),maxf(c.distance_to(d),d.distance_to(a)))>1.4:
		var ac := (a+c)*0.5
		var cd := (c+d)*0.5
		var da := (d+a)*0.5
		_water_triangle(st,poly,a,ac,da,y,level+1)
		_water_triangle(st,poly,ac,c,cd,y,level+1)
		_water_triangle(st,poly,da,cd,d,y,level+1)
		_water_triangle(st,poly,ac,cd,da,y,level+1)
		return
	# Godot front faces are clockwise: the geometric cross points against UP.
	var points: Array=[a,c,d] if (c-a).cross(d-a)>0.0 else [a,d,c]
	for p: Vector2 in points:
		var distance := INF
		for k in poly.size(): distance=minf(distance,_segment_distance(p,poly[k],poly[(k+1)%poly.size()]))
		st.set_color(Color(clampf(distance/1.7,0.0,1.0),0,0,1))
		st.set_normal(Vector3.UP)
		st.set_uv(p/8.0)
		st.add_vertex(Vector3(p.x,y,p.y))

static func _dry_bank(b: WorldBuilder,poly: PackedVector2Array,y: float,wet: SurfaceTool=null) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var roots := SurfaceTool.new()
	roots.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in poly.size():
		var a := poly[k]
		var c := poly[(k+1)%poly.size()]
		var normal := (c-a).normalized().orthogonal()
		var middle := (a+c)*0.5
		if Geometry2D.is_point_in_polygon(middle+normal*0.03,poly): normal=-normal
		_bank_quad(st,a,c,c+normal*0.42,a+normal*0.42,maxf(y+0.008,0.009),false)
		if wet!=null:
			_bank_quad(wet,a,c,c+normal*0.30,a+normal*0.30,maxf(y+0.009,0.010),true)
		if k%3==0 and not EnvironmentLandscape.on_route(middle.x,middle.y,0.45):
			var p := middle+normal*0.17
			var start := Vector3(p.x,0.10,p.y)
			var end := start+Vector3(normal.x*0.68,-0.06,normal.y*0.68)
			EnvironmentLandscape._tube(roots,start,end,0.055,0.015,Color.WHITE,5)
	b.append_mesh("visual:dirt",st.commit())
	var mesh := roots.commit()
	if mesh!=null: b.append_mesh("visual:log",mesh)

static func _bank_quad(st: SurfaceTool,a: Vector2,c: Vector2,d: Vector2,e: Vector2,y: float,wet: bool) -> void:
	for triangle: Array in [[a,c,d],[a,d,e]]:
		var p0: Vector2=triangle[0];var p1: Vector2=triangle[1];var p2: Vector2=triangle[2]
		var ordered: Array=[p0,p1,p2] if (p1-p0).cross(p2-p0)>0.0 else [p0,p2,p1]
		for p: Vector2 in ordered:
			var fade:=clampf(_segment_distance(p,a,c)/.30,0.0,1.0)
			st.set_color(Color(.27,.30,.25,1).lerp(Color.WHITE,fade) if wet else Color.WHITE)
			st.set_normal(Vector3.UP);st.set_uv(p/1.8);st.add_vertex(Vector3(p.x,y,p.y))

# Collision strips are inside the shared contour, with explicit dry cutouts.
static func add_water_blockers(b: WorldBuilder,out: Dictionary,id: String,water: Dictionary,
		dry: Array[Rect2]) -> Array:
	var ids: Array = []
	var bounds: Rect2 = water["bounds"]
	var polygons: Array = water["outlines"]
	var step := 0.22
	var count := ceili(bounds.size.y/step)
	for row in count:
		var z0 := bounds.position.y+float(row)*step
		var z1 := minf(z0+step,bounds.end.y)
		var z := (z0+z1)*0.5
		var spans := _water_spans(polygons,z)
		# Пересечение со срезами у обоих краёв гарантирует сухой берег снаружи.
		for sample: float in [z0+0.0001,z1-0.0001]:
			spans=_intersect_spans(spans,_water_spans(polygons,sample))
		for hole: Rect2 in dry:
			if z1>hole.position.y and z0<hole.end.y:
				spans=_subtract_span(spans,hole.position.x,hole.end.x)
		for span: Vector2 in spans:
			if span.y-span.x<0.015: continue
			var name := "%s-%03d" % [id,ids.size()]
			b.col.add_box_d(CollisionWorld.SET_OVERLAY,span.x,0,z0,span.y,1.6,z1,name)
			(out["boxes"] as Array).append(AABB(Vector3(span.x,0,z0),Vector3(span.y-span.x,1.6,z1-z0)))
			ids.append(name)
	return ids

static func _water_spans(polygons: Array,z: float) -> Array[Vector2]:
	var spans: Array[Vector2] = []
	for poly: PackedVector2Array in polygons:
		var hits: Array[float] = []
		for i in poly.size():
			var a := poly[i]
			var c := poly[(i+1)%poly.size()]
			if (a.y<=z and c.y>z) or (c.y<=z and a.y>z):
				hits.append(lerpf(a.x,c.x,(z-a.y)/(c.y-a.y)))
			hits.sort()
		for i in range(0,hits.size()-1,2): spans.append(Vector2(hits[i],hits[i+1]))
	return spans

static func _intersect_spans(a: Array[Vector2],c: Array[Vector2]) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for span: Vector2 in a:
		for other: Vector2 in c:
			var lo := maxf(span.x,other.x)
			var hi := minf(span.y,other.y)
			if hi>lo: out.append(Vector2(lo,hi))
	return out

static func _subtract_span(spans: Array[Vector2],x0: float,x1: float) -> Array[Vector2]:
	var out: Array[Vector2] = []
	for span: Vector2 in spans:
		if x1<=span.x or x0>=span.y:
			out.append(span)
			continue
		if x0>span.x: out.append(Vector2(span.x,x0))
		if x1<span.y: out.append(Vector2(x1,span.y))
	return out


static func _points2(raw: Variant) -> PackedVector2Array:
	var out := PackedVector2Array()
	if raw is PackedVector2Array:
		return raw
	if raw is PackedVector3Array:
		for p: Vector3 in raw:
			out.append(Vector2(p.x, p.z))
	elif raw is Array:
		for p: Variant in raw:
			if p is Vector2:
				out.append(p)
			elif p is Vector3:
				out.append(Vector2(p.x, p.z))
			elif p is Array and (p as Array).size() >= 2:
				out.append(Vector2(float(p[0]), float(p[1])))
	return out


static func _inset(poly: PackedVector2Array, amount: float) -> PackedVector2Array:
	var center := Vector2.ZERO
	for p: Vector2 in poly:
		center += p
	center /= float(poly.size())
	var inner := PackedVector2Array()
	for p: Vector2 in poly:
		inner.append(center + (p - center) * amount)
	return inner


static func _bounds(polygons: Array[PackedVector2Array]) -> Rect2:
	var first := true
	var out := Rect2()
	for poly: PackedVector2Array in polygons:
		for p: Vector2 in poly:
			if first:
				out = Rect2(p, Vector2.ZERO)
				first = false
			else:
				out = out.expand(p)
	return out


static func _polygon(points: PackedVector2Array, y: float, indices: PackedInt32Array,
		material: Material, deep := false) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	for p: Vector2 in points:
		verts.append(Vector3(p.x, y, p.y))
		normals.append(Vector3.UP)
		# +100 is a data bit outside every world-space UV. The water shader strips
		# it before sampling and uses it only to darken the depth layer.
		uv.append(Vector2(roundf(p.x * 4.0) / 32.0 + (100.0 if deep else 0.0),
			roundf(p.y * 4.0) / 32.0))
	return _mesh(verts, normals, uv, indices, material)


static func _ring2(outer: PackedVector2Array, inner: PackedVector2Array,
		material: Material, y: float) -> ArrayMesh:
	var o3 := PackedVector3Array()
	var i3 := PackedVector3Array()
	for p: Vector2 in outer:
		o3.append(Vector3(p.x, y, p.y))
	for p: Vector2 in inner:
		i3.append(Vector3(p.x, y + 0.002, p.y))
	return _ring(o3, i3, material, y)


static func boat_node(b: WorldBuilder, id: String, pos: Vector3, yaw := 0.0) -> Node3D:
	# Keep a named, non-rendering mesh mirror for interaction/acceptance geometry.  The
	# same resource is rendered once through the boards bucket below, so preserving
	# the semantic owner does not reintroduce a draw call.
	var n := MeshInstance3D.new()
	n.name = id
	n.position = pos
	n.rotation.y = yaw
	var mesh := _boat_mesh(b.mats.get_mat("boards"), b.mats.get_mat("dark"))
	n.mesh = mesh
	n.visible = false
	n.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var xf := Transform3D(Basis(Vector3.UP, yaw), pos)
	b.append_mesh("boards", mesh, xf)
	n.set_meta("triangle_count", 42)
	n.set_meta("bucketed", true)
	return n


static func _fan(points: PackedVector3Array, material: Material) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	var c := Vector3.ZERO
	for p: Vector3 in points:
		c += p
	c /= float(points.size())
	verts.append(c)
	normals.append(Vector3.UP)
	uv.append(Vector2(0.5, 0.5))
	for p: Vector3 in points:
		verts.append(p)
		normals.append(Vector3.UP)
		uv.append(Vector2(p.x * 0.08, p.z * 0.08))
	for i in points.size():
		indices.append_array([0, i + 1, (i + 1) % points.size() + 1])
	return _mesh(verts, normals, uv, indices, material)


static func _ring(outer: PackedVector3Array, inner: PackedVector3Array,
		material: Material, y: float) -> ArrayMesh:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	for i in outer.size():
		verts.append(Vector3(outer[i].x, y, outer[i].z))
		verts.append(Vector3(inner[i].x, y + 0.002, inner[i].z))
		normals.append_array([Vector3.UP, Vector3.UP])
		uv.append_array([Vector2(float(i), 0.0), Vector2(float(i), 1.0)])
	for i in outer.size():
		var j := (i + 1) % outer.size()
		indices.append_array([i * 2, j * 2, j * 2 + 1, i * 2, j * 2 + 1, i * 2 + 1])
	return _mesh(verts, normals, uv, indices, material)


static func _boat_mesh(wood: Material, dark: Material) -> ArrayMesh:
	# 8 сечений: днище и два борта с заострёнными концами, 42 треугольника.
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var uv := PackedVector2Array()
	var indices := PackedInt32Array()
	for i in 8:
		var q := float(i) / 7.0
		var z := lerpf(-1.6, 1.6, q)
		var width := 0.10 + 0.48 * sin(PI * q)
		verts.append_array([
			Vector3(-width, 0.30, z), Vector3(-width * 0.55, 0.04, z),
			Vector3(width * 0.55, 0.04, z), Vector3(width, 0.30, z)])
		normals.append_array([Vector3.LEFT, Vector3.UP, Vector3.UP, Vector3.RIGHT])
		uv.append_array([Vector2(q, 0), Vector2(q, .33), Vector2(q, .66), Vector2(q, 1)])
	for i in 7:
		var a := i * 4
		var c := (i + 1) * 4
		indices.append_array([a, c, c + 1, a, c + 1, a + 1])
		indices.append_array([a + 1, c + 1, c + 2, a + 1, c + 2, a + 2])
		indices.append_array([a + 2, c + 2, c + 3, a + 2, c + 3, a + 3])
	return _mesh(verts, normals, uv, indices, wood)


static func _mesh(verts: PackedVector3Array, normals: PackedVector3Array,
		uv: PackedVector2Array, indices: PackedInt32Array, material: Material) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, material)
	return mesh

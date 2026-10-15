## Парковые автомобили СНТ. Размеры служат и визуалу, и SET_OVERLAY.
class_name VehicleVisuals
extends RefCounted

const SIZES := {
	"sedan": Vector3(1.78, 1.50, 4.30),
	"wagon": Vector3(1.78, 1.57, 4.35),
	"uaz": Vector3(1.90, 1.98, 4.10),
}
static var _meshes: Dictionary = {}
const MATERIAL_VERSION := 2
const MICRO_PATH := "res://assets/generated/textures/vehicle-surface-v2-micro.res"
const NORMAL_PATH := "res://assets/generated/textures/vehicle-surface-v2-normal.res"
const SURFACE_SHADER := "res://shaders/environment_vehicle_hq.gdshader"
const GLASS_SHADER := "res://shaders/environment_vehicle_glass_hq.gdshader"
static var _surface_materials: Dictionary = {}
static var _surface_textures: Array[Texture2D] = []


static func dimensions(car: Dictionary) -> Vector3:
	return SIZES.get(String(car.get("family", "sedan")), SIZES["sedan"])


static func world_box(car: Dictionary) -> Array:
	var size := dimensions(car)
	var at: Array = car["at"]
	var yaw := float(car.get("ry", 0.0))
	var dx := (absf(cos(yaw)) * size.x + absf(sin(yaw)) * size.z) * 0.5
	var dz := (absf(sin(yaw)) * size.x + absf(cos(yaw)) * size.z) * 0.5
	return [float(at[0]) - dx, float(at[0]) + dx, float(at[2]) - dz, float(at[2]) + dz]


static func prop_def(plot: Dictionary) -> Dictionary:
	var car: Dictionary = plot["car"]
	var def := {"id": "snt-car-" + String(plot["id"]), "at": car["at"].duplicate(),
		"ry": float(car.get("ry", 0.0)), "col": false, "_snt": String(plot["id"])}
	def["make"] = "parkedVehicle"
	def["family"] = car["family"]
	def["paint"] = int(car.get("paint", 0x9a9984))
	return def


static func build(mats: Materials, def: Dictionary, holder: Node3D) -> void:
	var family := String(def.get("family", "sedan"))
	if not SIZES.has(family):
		family = "sedan"
	if not _meshes.has(family):
		var asset := ProceduralAssets.fetch("vehicle/" + family)
		if asset.is_empty():
			return
		_meshes[family] = asset
	var materials := [mats.physical(int(def.get("paint", 0x9a9984)), "", 0.68, 0.18),
		mats.physical(0x293239, "", 0.39), mats.physical(0x979787, "", 0.40, 0.55),
		mats.physical(0x764b3c, "", 0.76)]
	if not OS.get_cmdline_user_args().has("--environment=off"):
		for i in materials.size():
			var refreshed := surface_material(int(def.get("paint", 0x9a9984)), family, i)
			if refreshed != null:
				materials[i] = refreshed
	var asset: Dictionary = _meshes[family]
	var meshes: Array = asset["meshes"]
	var nodes: Array = []
	for i in meshes.size():
		var mi: MeshInstance3D = ModelLodMesh.new() if i == 0 else MeshInstance3D.new()
		mi.name = ["body", "windows-and-tyres", "chrome-and-lenses", "rear-lamps-and-wear"][i]
		mi.mesh = meshes[i]
		mi.material_override = materials[i]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mi)
		nodes.append(mi)
	if not (asset.get("lod_meshes", []) as Array).is_empty():
		(nodes[0] as ModelLodMesh).configure(nodes, asset["lod_meshes"], [materials[0], materials[1]], 16.0)
	holder.set_meta("vehicle_family", family)
	holder.set_meta("vehicle_dimensions", SIZES[family])
	holder.set_meta("vehicle_material_version", MATERIAL_VERSION if materials[0].has_meta("vehicle_material_version") else 1)


## Separate, versioned surface cache; the original geometry bake is never rewritten.
static func surface_material(paint: int, family: String, part: int) -> ShaderMaterial:
	var key := "%d/%s/%d" % [paint if part == 0 else 0, family, part]
	if _surface_materials.has(key):
		return _surface_materials[key] as ShaderMaterial
	if _surface_textures.is_empty():
		for path: String in [MICRO_PATH, NORMAL_PATH]:
			if not ResourceLoader.exists(path):
				push_error("Vehicle surface cache missing: " + path)
				return null
			_surface_textures.append(load(path) as Texture2D)
	var mat := ShaderMaterial.new()
	mat.shader = load(SURFACE_SHADER) as Shader
	mat.set_shader_parameter("albedo", GameData.color([paint, 0x293239, 0x979787, 0x764b3c][part]))
	mat.set_shader_parameter("vehicle_part", part)
	mat.set_shader_parameter("glass_base", 1.135 if family == "uaz" else .945)
	mat.set_shader_parameter("dust_height", .76 if family == "uaz" else .65)
	mat.set_shader_parameter("micro_tex", _surface_textures[0])
	mat.set_shader_parameter("normal_tex", _surface_textures[1])
	mat.set_meta("vehicle_material_version", MATERIAL_VERSION)
	mat.set_meta("vehicle_texture_license", "CC0-1.0; original deterministic procedural maps")
	_surface_materials[key] = mat
	return mat


## Called after Props.build by main. Only private paint/glass overrides change.
## Doors, wheels, skin visibility, source materials and every mesh array remain intact.
static func refresh_story_car(holder: Node3D, mats: Materials) -> Dictionary:
	var report := {"active": not OS.get_cmdline_user_args().has("--environment=off"), "paint_nodes": [], "glass_nodes": [], "new_surfaces": 0, "new_colliders": 0}
	if holder == null or not report["active"]:
		return report
	if holder.has_meta("vehicle_surface_refresh"):
		return holder.get_meta("vehicle_surface_refresh")
	var paint_source := mats.flat(0x4a5f52)
	var glass_source := mats.get_mat("glass")
	for node: Node in SkinLayer._nodes(holder):
		if not node is MeshInstance3D:
			continue
		var mi := node as MeshInstance3D
		if mi.mesh == null or mi.layers == 0 or mi.has_meta("vehicle_material_version"):
			continue
		var source := mi.get_active_material(0)
		var glass := source == glass_source
		if source != paint_source and not glass:
			continue
		var template := surface_material(0x4a5f52, "sedan", 1 if glass else 0)
		if template == null:
			continue
		var material := template.duplicate() as ShaderMaterial
		var frame := mi.transform
		var ancestor := mi.get_parent()
		while ancestor != null and ancestor != holder:
			if ancestor is Node3D:
				frame = (ancestor as Node3D).transform * frame
			ancestor = ancestor.get_parent()
		material.set_shader_parameter("local_frame", frame)
		if glass:
			material.shader = load(GLASS_SHADER) as Shader
			material.set_shader_parameter("glass_base", -100.0)
			material.set_shader_parameter("window_opacity", .38)
			material.render_priority = 1
		mi.material_override = material
		mi.set_meta("vehicle_material_version", MATERIAL_VERSION)
		report["glass_nodes" if glass else "paint_nodes"].append(String(holder.get_path_to(mi)))
	holder.set_meta("vehicle_surface_refresh", report)
	return report


## Offline CPU bake only, with its own seed. Two 256px shared maps including mipmaps.
static func bake_surface_cache() -> Dictionary:
	var micro := Image.create(256, 256, false, Image.FORMAT_RGBA8)
	var normal := Image.create(256, 256, false, Image.FORMAT_RGB8)
	var rng := RandomNumberGenerator.new()
	rng.seed = 19881003
	var grain := PackedFloat32Array()
	grain.resize(256 * 256)
	for y in 256:
		for x in 256:
			grain[y * 256 + x] = rng.randf()
	for y in 256:
		for x in 256:
			var n := grain[y * 256 + x]
			var broad := sin(float(x) * TAU / 256.0 * 7.0) * sin(float(y) * TAU / 256.0 * 5.0)
			var value := .91 + n * .075 + broad * .015
			micro.set_pixel(x, y, Color(value, value * .994, value * .982, .64 + n * .27))
			var dx := grain[y * 256 + ((x + 1) % 256)] - grain[y * 256 + ((x + 255) % 256)]
			var dy := grain[((y + 1) % 256) * 256 + x] - grain[((y + 255) % 256) * 256 + x]
			var mapped := Vector3(-dx * .22, -dy * .22, 1.0).normalized()
			normal.set_pixel(x, y, Color(mapped.x * .5 + .5, mapped.y * .5 + .5, mapped.z * .5 + .5))
	micro.generate_mipmaps()
	normal.generate_mipmaps()
	var result := {"version": MATERIAL_VERSION, "license": "CC0-1.0", "maps": [], "runtime_bytes": 0}
	for spec: Array in [[micro, MICRO_PATH], [normal, NORMAL_PATH]]:
		var image: Image = spec[0]
		var texture := ImageTexture.create_from_image(image)
		texture.set_meta("vehicle_material_version", MATERIAL_VERSION)
		texture.set_meta("license", "CC0-1.0")
		var status := ResourceSaver.save(texture, spec[1])
		result["maps"].append({"path": spec[1], "status": status, "bytes": image.get_data().size(), "width": 256, "height": 256})
		result["runtime_bytes"] += image.get_data().size()
	return result


static func generate(key: String) -> Dictionary:
	var family := key.trim_prefix("vehicle/")
	if not SIZES.has(family):
		return {}
	var meshes := _build_meshes(family)
	var bounds := AABB()
	for i in meshes.size():
		var mesh: ArrayMesh = meshes[i]
		mesh.surface_set_material(0, ProceduralAssets.material("rusted_metal"))
		bounds = bounds.merge(mesh.get_aabb()) if i > 0 else mesh.get_aabb()
	var far := _far_meshes(family)
	for mesh: ArrayMesh in far:
		mesh.surface_set_material(0, ProceduralAssets.material("rusted_metal"))
	return {"meshes": meshes, "lod_meshes": far, "bounds": bounds,
		"anchors": {"root": Transform3D.IDENTITY,
			"front": Transform3D(Basis.IDENTITY, Vector3(0, 0, -SIZES[family].z * 0.5))}}


static func _build_meshes(family: String) -> Array:
	var st: Array[SurfaceTool] = []
	for i in 4:
		var surface := SurfaceTool.new()
		surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.append(surface)
	var size: Vector3 = SIZES[family]
	var utility := family == "uaz"
	var wagon := family == "wagon"
	var w := size.x - 0.16
	var half := (size.z - 0.14) * 0.5
	var radius := 0.37 if utility else 0.315
	var arch := radius + 0.075
	var top := 1.12 if utility else 0.93
	var bottom := 0.43 if utility else 0.34
	var wheel_z := [-1.22 if utility else -1.30, 1.23 if utility else 1.31]
	# Прорези арок входят в контур боковины, колёса не прячутся в кубе кузова.
	var contour: Array[Vector2] = [Vector2(-half, bottom)]
	for z: float in wheel_z:
		contour.append(Vector2(z - arch, bottom))
		for j in 9:
			var angle := PI - float(j) * PI / 8.0
			contour.append(Vector2(z + cos(angle) * arch, maxf(bottom, radius + sin(angle) * arch)))
		contour.append(Vector2(z + arch, bottom))
	contour.append(Vector2(half, bottom))
	for side: float in [-1.0, 1.0]:
		var x := side * w * 0.5
		for i in range(contour.size() - 1):
			var a := contour[i]
			var b := contour[i + 1]
			if b.x - a.x < 0.0001:
				continue
			_quad(st[0], [Vector3(x, a.y, a.x), Vector3(x, b.y, b.x),
					Vector3(x - side * 0.025, top, b.x), Vector3(x - side * 0.025, top, a.x)], Vector3(side, 0, 0))
		for z: float in wheel_z:
			_cylinder(st[1], Vector3(side * (w * 0.5 - 0.02), radius, z), radius, 0.20, 10)
			_cylinder(st[2], Vector3(side * (w * 0.5 + 0.071), radius, z), radius * 0.57, 0.018, 8)
			_cylinder(st[1], Vector3(side * (w * 0.5 + 0.070), radius, z), radius * 0.18, 0.020, 8)
			for j in 8:
				var a := float(j) * PI / 8.0
				var b := float(j + 1) * PI / 8.0
				_quad(st[0], [Vector3(x + side * 0.025, radius + sin(a) * arch, z + cos(a) * arch),
					Vector3(x + side * 0.025, radius + sin(b) * arch, z + cos(b) * arch),
					Vector3(x + side * 0.025, radius + sin(b) * (arch + 0.045), z + cos(b) * (arch + 0.045)),
					Vector3(x + side * 0.025, radius + sin(a) * (arch + 0.045), z + cos(a) * (arch + 0.045))], Vector3(side, 0, 0))
	_bevel_box(st[0], Vector3(w - 0.05, 0.06, half * 2.0), Vector3(0, top - 0.03, 0))
	_box(st[1], Vector3(w * 0.74, 0.08, half * 1.85), Vector3(0, bottom + 0.02, 0))
	for end: float in [-1.0, 1.0]:
		_box(st[0], Vector3(w, top - bottom, 0.045), Vector3(0, (top + bottom) * 0.5, end * (half - 0.0225)))
		_box(st[2], Vector3(w + 0.06, 0.095, 0.10), Vector3(0, bottom + 0.07, end * (half + 0.02)))
		_box(st[1], Vector3(w * 0.52, 0.17, 0.015), Vector3(0, top - 0.19, end * (half + 0.006)))
		_box(st[2], Vector3(0.38, 0.09, 0.018), Vector3(0, bottom + 0.19, end * (half + 0.014)))
		for x: float in [-w * 0.36, w * 0.36]:
			_box(st[2 if end < 0 else 3], Vector3(0.22, 0.15, 0.024), Vector3(x, top - 0.18, end * (half + 0.02)))
	# Наклонные лобовое/заднее стекло, отдельная крыша и окрашенные стойки.
	var roof := size.y - 0.045
	var zf := -0.73 if utility else -0.87
	var zr := 1.77 if utility or wagon else 1.14
	var rf := zf + (0.16 if utility else 0.32)
	var rr := zr - (0.12 if utility or wagon else 0.31)
	var rw := w - (0.16 if utility else 0.27)
	var corners := [Vector3(-w * 0.5, top, zf), Vector3(w * 0.5, top, zf),
		Vector3(w * 0.5, top, zr), Vector3(-w * 0.5, top, zr),
		Vector3(-rw * 0.5, roof, rf), Vector3(rw * 0.5, roof, rf),
		Vector3(rw * 0.5, roof, rr), Vector3(-rw * 0.5, roof, rr)]
	_bevel_box(st[0], Vector3(rw, 0.035, rr - rf), Vector3(0, roof - 0.0175, (rf + rr) * 0.5))
	for face: Array in [[0, 1, 5, 4, Vector3.FORWARD], [2, 3, 7, 6, Vector3.BACK],
			[3, 0, 4, 7, Vector3.LEFT], [1, 2, 6, 5, Vector3.RIGHT]]:
		var points := [corners[face[0]], corners[face[1]], corners[face[2]], corners[face[3]]]
		var normal: Vector3 = face[4]
		_quad(st[0], points, normal)
		if absf(normal.x) > 0.5:
			# Две двери; у универсала и УАЗа добавлено багажное окно.
			var count := 3 if utility or wagon else 2
			for i in count:
				var a := float(i) / count + 0.035
				var b := float(i + 1) / count - 0.035
				var p0: Vector3 = points[0].lerp(points[1], a)
				var p1: Vector3 = points[0].lerp(points[1], b)
				var p2: Vector3 = points[3].lerp(points[2], b)
				var p3: Vector3 = points[3].lerp(points[2], a)
				_quad(st[1], [p0.lerp(p3, 0.13) + normal * 0.007, p1.lerp(p2, 0.13) + normal * 0.007,
					p2.lerp(p1, 0.14) + normal * 0.007, p3.lerp(p0, 0.14) + normal * 0.007], normal)
				_box(st[2], Vector3(0.020, 0.025, 0.15), Vector3(normal.x * (w * 0.5 + 0.013), top - 0.12, (p0.z + p1.z) * 0.5))
				# Узкие реальные дверные щели и поясной молдинг остаются в dark batch.
				var door_z := (p0.z + p1.z) * 0.5
				_box(st[1], Vector3(0.009, top - bottom - 0.16, 0.009), Vector3(normal.x * (w * 0.5 + 0.008), (top + bottom) * 0.5, p1.z))
				_box(st[2], Vector3(0.010, 0.012, absf(p1.z - p0.z)), Vector3(normal.x * (w * 0.5 + 0.013), top - 0.055, door_z))
			_box(st[3], Vector3(0.012, 0.042, 0.62), Vector3(normal.x * (w * 0.5 + 0.008), bottom + 0.065, 0.0))
			# Зеркала не выходят за SIZES/world_box: по ним идёт прежняя физика парковки.
			_box(st[1], Vector3(0.070, 0.075, 0.15), Vector3(normal.x * (size.x * 0.5 - 0.04), top + 0.10, zf + 0.25))
		else:
			var center: Vector3 = (points[0] + points[1] + points[2] + points[3]) * 0.25
			var glass: Array = []
			for point: Vector3 in points:
				glass.append(center.lerp(point, 0.86) + normal * 0.007)
			_quad(st[1], glass, normal)
			_box(st[2], Vector3(rw * 0.71, 0.014, 0.018), Vector3(0, top + 0.07, normal.z * 0.008 + (zf if normal.z < 0 else zr)))
	var out: Array = []
	for surface: SurfaceTool in st:
		out.append(surface.commit())
	return out


static func _far_meshes(family: String) -> Array:
	var body := SurfaceTool.new()
	var dark := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	dark.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size: Vector3 = SIZES[family]
	var utility := family == "uaz"
	var w := size.x - 0.16
	var half := (size.z - 0.14) * 0.5
	var radius := 0.37 if utility else 0.315
	var bottom := 0.43 if utility else 0.34
	var top := 1.12 if utility else 0.93
	var roof := size.y - 0.045
	var zf := -0.73 if utility else -0.87
	var zr := 1.77 if utility or family == "wagon" else 1.14
	var rf := zf + (0.16 if utility else 0.32)
	var rr := zr - (0.12 if utility or family == "wagon" else 0.31)
	var rw := w - (0.16 if utility else 0.27)
	# Четыре настоящих колеса и арки сохраняют силуэт; мелкие канты/ручки
	# занимают меньше пикселя на этой дистанции и не входят в дальний bake.
	var wheel_z := [-1.22 if utility else -1.30, 1.23 if utility else 1.31]
	var contour: Array[Vector2] = [Vector2(-half, bottom)]
	for z: float in wheel_z:
		contour.append(Vector2(z - radius - 0.075, bottom))
		for j in 5:
			var a := PI - float(j) * PI / 4.0
			contour.append(Vector2(z + cos(a) * (radius + 0.075), maxf(bottom, radius + sin(a) * (radius + 0.075))))
		contour.append(Vector2(z + radius + 0.075, bottom))
	contour.append(Vector2(half, bottom))
	for side: float in [-1.0, 1.0]:
		var x := side * w * 0.5
		for i in range(contour.size() - 1):
			var a := contour[i]
			var b := contour[i + 1]
			if b.x - a.x > 0.0001:
				_quad(body, [Vector3(x,a.y,a.x),Vector3(x,b.y,b.x),Vector3(x,top,b.x),Vector3(x,top,a.x)],Vector3(side,0,0))
		for z: float in wheel_z:
			_cylinder(dark,Vector3(side*(w*0.5-0.02),radius,z),radius,0.20,6)
	_box(body,Vector3(w-0.05,0.06,half*2),Vector3(0,top-0.03,0))
	for end: float in [-1.0,1.0]:
		_box(body,Vector3(w,top-bottom,0.045),Vector3(0,(top+bottom)*0.5,end*(half-0.0225)))
		_box(dark,Vector3(w+0.06,0.095,0.10),Vector3(0,bottom+0.07,end*(half+0.02)))
	var corners := [Vector3(-w*0.5,top,zf),Vector3(w*0.5,top,zf),
		Vector3(w*0.5,top,zr),Vector3(-w*0.5,top,zr),
		Vector3(-rw*0.5,roof,rf),Vector3(rw*0.5,roof,rf),
		Vector3(rw*0.5,roof,rr),Vector3(-rw*0.5,roof,rr)]
	_box(body,Vector3(rw,0.035,rr-rf),Vector3(0,roof-0.0175,(rf+rr)*0.5))
	for spec: Array in [[0,1,5,4,Vector3.FORWARD],[2,3,7,6,Vector3.BACK],
		[3,0,4,7,Vector3.LEFT],[1,2,6,5,Vector3.RIGHT]]:
		var points := [corners[spec[0]],corners[spec[1]],corners[spec[2]],corners[spec[3]]]
		var normal: Vector3 = spec[4]
		_quad(body,points,normal)
		var center: Vector3 = (points[0]+points[1]+points[2]+points[3])*0.25
		var glass: Array = []
		for point: Vector3 in points:
			glass.append(center.lerp(point,0.86)+normal*0.007)
		_quad(dark,glass,normal)
	return [body.commit(),dark.commit()]


static func _bevel_box(st: SurfaceTool, size: Vector3, at: Vector3) -> void:
	var helper: GDScript = load("res://src/detailed_props.gd")
	helper._append(st, helper.rounded_box(size), Transform3D(Basis.IDENTITY, at))


static func _box(st: SurfaceTool, size: Vector3, at: Vector3) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_append_primitive(st, mesh, Transform3D(Basis.IDENTITY, at))


static func _cylinder(st: SurfaceTool, at: Vector3, radius: float, width: float, segments: int) -> void:
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = width
	mesh.radial_segments = segments
	mesh.rings = 0
	_append_primitive(st, mesh, Transform3D(Basis(Vector3.FORWARD, PI * 0.5), at))


static func _append_primitive(st: SurfaceTool, mesh: PrimitiveMesh, transform: Transform3D) -> void:
	# Keep every surface non-indexed. append_from() imports primitive indices;
	# later raw polygon vertices would then exist in the AABB but never render.
	var arrays := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	var indices: Variant = arrays[Mesh.ARRAY_INDEX]
	var indexed: bool = indices is PackedInt32Array and not indices.is_empty()
	var count: int = indices.size() if indexed else vertices.size()
	for i in count:
		var vertex: int = int(indices[i]) if indexed else i
		st.set_normal((transform.basis * normals[vertex]).normalized())
		st.set_uv(uvs[vertex])
		st.add_vertex(transform * vertices[vertex])


static func _quad(st: SurfaceTool, points: Array, normal: Vector3) -> void:
	ObjectGeometry._polygon(st, points, normal)

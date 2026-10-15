## Общие модели реквизита. generate() вызывается только офлайн; build()
## загружает готовый ресурс, сохраняет holder/id/якорь и не создаёт коллизий.
class_name DetailedProps
extends RefCounted

const SUPPORTED := ["tvHorizon", "tvYunost", "rotaryPhone", "jarShelf", "workbench",
	"waterBarrel", "woodpile", "chair", "cup", "jar", "radio", "bench", "shovel"]


static func params(def: Dictionary) -> Dictionary:
	match String(def.get("make", "")):
		"jarShelf":
			return {"rows": int(def.get("rows", 3)), "per": int(def.get("per", 9))}
		"woodpile":
			return {"len": float(def.get("len", 3.0))}
	return {}


static func catalog() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for kind: String in SUPPORTED:
		var spec := {"key": "prop/" + kind, "params": params({"make": kind})}
		seen[ProceduralAssets.cache_id(spec["key"], spec["params"])] = true
		out.append(spec)
	var data := GameData.props()
	var defs: Array = data.get("PROPS", []).duplicate()
	defs.append_array(data.get("DYNAMIC_PROPS", []))
	for def: Dictionary in defs:
		var kind := String(def.get("make", ""))
		if not SUPPORTED.has(kind):
			continue
		var spec := {"key": "prop/" + kind, "params": params(def)}
		var id := ProceduralAssets.cache_id(spec["key"], spec["params"])
		if not seen.has(id):
			seen[id] = true
			out.append(spec)
	return out


static func build(mats: Materials, def: Dictionary, holder: Node3D) -> bool:
	var kind := String(def.get("make", ""))
	if not SUPPORTED.has(kind):
		return false
	var asset := ProceduralAssets.fetch("prop/" + kind, params(def))
	if asset.is_empty():
		return false
	var palette := _palette(kind, def)
	var meshes: Array = asset["meshes"]
	var nodes: Array = []
	for i in meshes.size():
		var slot := int(asset.get("material_slots", [0, 1, 2])[i])
		var mi: MeshInstance3D = ModelLodMesh.new() if i == 0 and kind in ["woodpile", "jarShelf"] else MeshInstance3D.new()
		mi.mesh = meshes[i]
		mi.name = "screen" if kind.begins_with("tv") and slot == 2 else "detail-%d" % slot
		var mat: Material
		if mats != null:
			mat = mats.physical(palette[slot], "wood" if slot == 0 and kind in
				["chair", "bench", "jarShelf", "workbench", "woodpile", "tvHorizon"] else "",
				0.86 if slot == 0 else 0.58, 0.20 if slot == 1 else 0.0)
		else:
			var fallback := ShaderMaterial.new()
			fallback.shader = load("res://shaders/psx.gdshader")
			fallback.set_shader_parameter("albedo", GameData.color(palette[slot]))
			mat = fallback
		mi.material_override = mat
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("rural_bucket", "boards" if slot == 0 and kind in
			["chair", "bench", "jarShelf", "workbench", "woodpile"] else "metal" if slot == 1 else "trim")
		if mi.name == "screen":
			mi.set_meta("independent_visual", true)
		holder.add_child(mi)
		nodes.append(mi)
	if kind in ["woodpile", "jarShelf"] and not (asset.get("lod_meshes", []) as Array).is_empty():
		var far_materials: Array = []
		for slot: int in asset["lod_material_slots"]:
			var near_index: int = (asset["material_slots"] as Array).find(slot)
			far_materials.append((nodes[near_index] as MeshInstance3D).material_override)
		(nodes[0] as ModelLodMesh).configure(nodes, asset["lod_meshes"], far_materials, 14.0 if kind == "woodpile" else 10.0)
	holder.set_meta("detailed_prop", kind)
	return true


static func _palette(kind: String, def: Dictionary) -> Array:
	match kind:
		"tvHorizon": return [0x9d876d, 0x363b39, 0x26322f]
		"tvYunost": return [0x666964, 0x999a8f, 0x26322f]
		"rotaryPhone": return [0x343834, 0xb3ad96, 0x242826]
		"jarShelf", "jar": return [0xc0ac8e, 0x9f9c87, 0x604247 if def.get("fill", "") == "berry" else 0x777057]
		"waterBarrel": return [0x56675e, 0x7b8077, 0x293d3d]
		"workbench": return [0xb8a58a, 0x626966, 0x303834]
		"woodpile": return [0x76604a, 0xbba487, 0x4e4c43]
		"shovel": return [0xb7a08a, 0x686e68, 0x303a35]
		"cup": return [0xbbb5a5, 0x666d64, 0x353e34]
		"radio": return [0x857a64, 0x2f3834, 0xb4ad8c]
	return [0xb4a085, 0x58615b, 0x3c463d]


static func generate(key: String, options: Dictionary = {}, _seed_value := 1988) -> Dictionary:
	var kind := key.trim_prefix("prop/")
	if not SUPPORTED.has(kind):
		return {}
	var st: Array[SurfaceTool] = []
	for i in 3:
		var part := SurfaceTool.new()
		part.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.append(part)
	match kind:
		"tvHorizon", "tvYunost":
			_tv(st, kind == "tvHorizon")
		"rotaryPhone":
			_box(st[0], Vector3(0.22, 0.09, 0.20), Vector3(0, 0.045, 0), true)
			_tube(st[1], Vector3(0, 0.09, 0.01), Vector3(0, 0.11, 0.01), 0.075, 0.069, 12)
			for i in 10:
				var a := TAU * float(i) / 10.0
				_tube(st[2], Vector3(cos(a) * 0.052, 0.11, 0.01 + sin(a) * 0.052),
					Vector3(cos(a) * 0.052, 0.112, 0.01 + sin(a) * 0.052), 0.010, 0.010, 6)
			_box(st[0], Vector3(0.18, 0.027, 0.035), Vector3(0, 0.139, -0.096), true)
			for side: float in [-1.0, 1.0]:
				_tube(st[0], Vector3(side * 0.082, 0.132, -0.08), Vector3(side * 0.095, 0.148, -0.123), 0.033, 0.029, 8)
				_box(st[0], Vector3(0.035, 0.027, 0.025), Vector3(side * 0.072, 0.108, -0.09))
			for i in 10:
				var at := Vector3(0.108, 0.025 + i * 0.006, -0.065 + sin(i * 1.7) * 0.014)
				_tube(st[0], at, at + Vector3(0, 0.006, 0.007), 0.003, 0.003, 4)
		"jarShelf":
			var rows := int(options.get("rows", 3))
			var per := int(options.get("per", 9))
			var width := per * 0.17 + 0.12
			for r in rows:
				_box(st[0], Vector3(width, 0.04, 0.34), Vector3(0, r * 0.52 + 0.02, 0))
				for i in per:
					_jar(st[2], st[1], Vector3(-width * 0.5 + 0.14 + i * 0.17,
						r * 0.52 + 0.04, float(i % 2) * 0.06 - 0.03))
			for side: float in [-1.0, 1.0]:
				_box(st[0], Vector3(0.06, rows * 0.52 + 0.04, 0.34), Vector3(side * width * 0.5, (rows * 0.52 + 0.04) * 0.5, 0))
		"jar":
			_jar(st[0], st[1], Vector3.ZERO)
		"cup":
			_profile(st[0], [0.0, 0.008, 0.09], [0.032, 0.040, 0.046], 10, false)
			_tube(st[2], Vector3(0, 0.07, 0), Vector3(0, 0.071, 0), 0.040, 0.040, 10)
			for i in 7:
				var a := -PI * 0.5 + float(i) * PI / 7.0
				var b := -PI * 0.5 + float(i + 1) * PI / 7.0
				_tube(st[0], Vector3(0.042 + cos(a) * 0.03, 0.045 + sin(a) * 0.03, 0),
					Vector3(0.042 + cos(b) * 0.03, 0.045 + sin(b) * 0.03, 0), 0.006, 0.006, 4)
		"chair", "bench":
			var bench := kind == "bench"
			var width := 1.50 if bench else 0.44
			for i in 3:
				_box(st[0], Vector3(width, 0.04, 0.13), Vector3(0, 0.46, -0.15 + i * 0.14), i == 0)
			for x: float in [-width * 0.40, width * 0.40]:
				for z: float in [-0.15, 0.15]:
					_box(st[1], Vector3(0.045, 0.44, 0.045), Vector3(x, 0.22, z))
				_box(st[1], Vector3(0.04, 0.37, 0.045), Vector3(x, 0.625, 0.16))
			for y: float in [0.61, 0.78]:
				_box(st[0], Vector3(width, 0.12, 0.035), Vector3(0, y, 0.18))
		"waterBarrel":
			_profile(st[0], [0.0, 0.08, 0.77, 0.86], [0.31, 0.34, 0.34, 0.33], 8, false)
			for y: float in [0.20, 0.62]:
				_profile(st[1], [y, y + 0.035], [0.345, 0.345], 8, false)
			_tube(st[2], Vector3(0, 0.802, 0), Vector3(0, 0.807, 0), 0.315, 0.315, 8)
		"workbench":
			for i in 4:
				_box(st[0], Vector3(1.85, 0.085, 0.146), Vector3(0, 0.8625, -0.235 + i * 0.157), i == 0)
			for x: float in [-0.82, 0.82]:
				for z: float in [-0.24, 0.24]:
					_box(st[0], Vector3(0.08, 0.82, 0.08), Vector3(x, 0.41, z))
			_box(st[0], Vector3(1.7, 0.04, 0.4), Vector3(0, 0.30, 0))
			_box(st[1], Vector3(0.16, 0.10, 0.20), Vector3(-0.70, 0.96, -0.16), true)
			for z: float in [-0.25, -0.06]:
				_box(st[1], Vector3(0.17, 0.04, 0.025), Vector3(-0.70, 1.04, z))
			_tube(st[1], Vector3(-0.70, 0.97, -0.15), Vector3(-0.70, 0.97, 0.035), 0.012, 0.012, 6)
			_tube(st[1], Vector3(-0.70, 0.91, 0.035), Vector3(-0.70, 1.03, 0.035), 0.008, 0.008, 6)
			_tube(st[0], Vector3(0.3, 0.916, -0.15), Vector3(0.62, 0.916, -0.15), 0.016, 0.019, 6)
			_box(st[1], Vector3(0.03, 0.055, 0.10), Vector3(0.61, 0.934, -0.15))
		"woodpile":
			var length := float(options.get("len", 3.0))
			var count := maxi(3, int(length / 0.18))
			for r in 5:
				for i in count - r / 2:
					var x := -length * 0.5 + 0.10 + i * 0.18 + float(r % 2) * 0.09
					var at := Vector3(x, 0.10 + r * 0.145, 0)
					_tube(st[0], at + Vector3(0, 0, -0.28), at + Vector3(0, 0, 0.28), 0.075, 0.069, 6)
					_tube(st[1], at + Vector3(0, 0, -0.282), at + Vector3(0, 0, -0.284), 0.067, 0.064, 6)
		"radio":
			_box(st[0], Vector3(0.30, 0.20, 0.10), Vector3(0, 0.1, 0), true)
			_box(st[1], Vector3(0.19, 0.125, 0.01), Vector3(-0.03, 0.09, -0.055))
			_box(st[2], Vector3(0.22, 0.025, 0.008), Vector3(-0.012, 0.17, -0.056))
			for i in 6:
				_box(st[0], Vector3(0.175, 0.004, 0.007), Vector3(-0.03, 0.04 + i * 0.019, -0.062))
			_tube(st[2], Vector3(0.114, 0.08, -0.060), Vector3(0.114, 0.08, -0.073), 0.021, 0.021, 8)
			_tube(st[2], Vector3(0.12, 0.20, 0), Vector3(0.045, 0.43, 0), 0.003, 0.002, 4)
		"shovel":
			_tube(st[0], Vector3(0, -0.59, 0), Vector3(0, 0.34, 0), 0.018, 0.017, 6)
			ObjectGeometry._extrude(st[1], [Vector2(-0.085, -0.55), Vector2(0.085, -0.55),
				Vector2(0.10, -0.72), Vector2(0.07, -0.80), Vector2(-0.07, -0.80), Vector2(-0.10, -0.72)], -0.012, 0.005)
			_box(st[1], Vector3(0.021, 0.18, 0.012), Vector3(0, -0.635, -0.014))
			for side: float in [-1.0, 1.0]:
				_tube(st[1], Vector3(0, 0.33, 0), Vector3(side * 0.056, 0.46, 0), 0.010, 0.010, 4)
			_tube(st[0], Vector3(-0.056, 0.46, 0), Vector3(0.056, 0.46, 0), 0.016, 0.016, 6)
	var meshes: Array = []
	var materials: Array = []
	var bounds := AABB()
	for i in st.size():
		var arrays := st[i].commit_to_arrays()
		if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
			continue
		var mesh := ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(0, ProceduralAssets.material("wood" if i == 0 else "rusted_metal"))
		bounds = bounds.merge(mesh.get_aabb()) if not meshes.is_empty() else mesh.get_aabb()
		meshes.append(mesh)
		materials.append(i)
	var far := _far_props(kind, options) if kind in ["woodpile", "jarShelf"] else []
	return {"meshes": meshes, "lod_meshes": far, "material_slots": materials,
		"lod_material_slots": [0, 1] if kind == "woodpile" else [0, 2],
		"bounds": bounds, "anchors": {"root": Transform3D.IDENTITY,
			"top": Transform3D(Basis.IDENTITY, Vector3(0, bounds.end.y, 0))}}


static func _far_props(kind: String, options: Dictionary) -> Array:
	var body := SurfaceTool.new()
	var detail := SurfaceTool.new()
	body.begin(Mesh.PRIMITIVE_TRIANGLES)
	detail.begin(Mesh.PRIMITIVE_TRIANGLES)
	if kind == "woodpile":
		var length := float(options.get("len", 3.0))
		var original_count := maxi(3, int(length / 0.18))
		var count := maxi(3, int(length / 0.32))
		var min_x := -length * 0.5 + 0.112
		var max_x := -length * 0.5 + 0.10 + (original_count - 1) * 0.18
		for row in 3:
			for i in count - row:
				var x := lerpf(min_x + row * 0.08, max_x - row * 0.10, float(i) / maxf(1, count - row - 1))
				var at := Vector3(x, 0.12 + row * 0.275, 0)
				_tube(body,at+Vector3(0,0,-0.28),at+Vector3(0,0,0.28),0.075,0.069,4)
				_tube(detail,at+Vector3(0,0,-0.282),at+Vector3(0,0,-0.284),0.067,0.064,4)
	else:
		var rows := int(options.get("rows", 3))
		var per := int(options.get("per", 9))
		var width := per * 0.17 + 0.12
		for row in rows:
			_box(body,Vector3(width,0.04,0.34),Vector3(0,row*0.52+0.02,0))
			for i in per:
				var at := Vector3(-width*0.5+0.14+i*0.17,row*0.52+0.04,float(i%2)*0.06-0.03)
				_tube(detail,at+Vector3(0,0.01,0),at+Vector3(0,0.205,0),0.049,0.059,4)
		for side: float in [-1.0,1.0]:
			_box(body,Vector3(0.06,rows*0.52+0.04,0.34),Vector3(side*width*0.5,(rows*0.52+0.04)*0.5,0))
	var meshes: Array = [body.commit(),detail.commit()]
	for mesh: ArrayMesh in meshes:
		mesh.surface_set_material(0,ProceduralAssets.material("wood"))
	return meshes


static func _tv(st: Array[SurfaceTool], big: bool) -> void:
	var scale := Vector3.ONE if big else Vector3(0.5484, 0.56, 0.6087)
	var offset := Vector3(0, 0.13 if big else 0.0, 0)
	_box(st[0], Vector3(0.62, 0.50, 0.46) * scale, Vector3(0, 0.25, 0) * scale + offset, true)
	_box(st[1], Vector3(0.48, 0.37, 0.025) * scale, Vector3(-0.033, 0.25, -0.228) * scale + offset, true)
	# Выпуклое стекло кинескопа остаётся отдельным именованным экраном.
	var screen := ObjectGeometry.bevel_box(Vector3(0.44, 0.34, 0.026) * scale, 0.015 * scale.x)
	_append(st[2], screen, Transform3D(Basis.IDENTITY, Vector3(-0.033, 0.25, -0.245) * scale + offset))
	for i in 3:
		_tube(st[1], Vector3(0.255, 0.32 - i * 0.07, -0.232) * scale + offset,
			Vector3(0.255, 0.32 - i * 0.07, -0.251) * scale + offset, 0.021 * scale.x, 0.020 * scale.x, 8)
	for i in 5:
		_box(st[1], Vector3(0.08, 0.005, 0.006) * scale, Vector3(0.255, 0.07 + i * 0.018, -0.234) * scale + offset)
	for x: float in [-0.23, 0.23]:
		_box(st[1], Vector3(0.05, 0.09, 0.31) * scale, Vector3(x, -0.045, 0) * scale + offset)
	if not big:
		for side: float in [-1.0, 1.0]:
			_tube(st[1], Vector3(side * 0.06, 0.28, 0.05), Vector3(side * 0.20, 0.60, 0.05), 0.0035, 0.002, 4)
	else:
		for i in 5:
			_box(st[1], Vector3(0.36, 0.007, 0.012), Vector3(0, 0.21 + i * 0.033, 0.232))


static func _jar(body: SurfaceTool, lid: SurfaceTool, at: Vector3) -> void:
	var mesh := _profile_mesh([0, 0.012, 0.14, 0.175, 0.19], [0.044, 0.055, 0.055, 0.042, 0.041], 7)
	_append(body, mesh, Transform3D(Basis.IDENTITY, at))
	_tube(lid, at + Vector3(0, 0.188, 0), at + Vector3(0, 0.204, 0), 0.046, 0.046, 7)


static func _profile_mesh(heights: Array, radii: Array, segments: int) -> ArrayMesh:
	var rings: Array = []
	var circle: Array[Vector2] = []
	for i in segments:
		circle.append(Vector2(cos(float(i) * TAU / segments), sin(float(i) * TAU / segments)))
	for r in heights.size():
		rings.append(ObjectGeometry._ring(circle, heights[r], radii[r], radii[r]))
	return ObjectGeometry._rings(rings)


static func _profile(st: SurfaceTool, heights: Array, radii: Array, segments: int, cap_top := true) -> void:
	var mesh := _profile_mesh(heights, radii, segments)
	if cap_top:
		_append(st, mesh)
		return
	var data := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = data[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = data[Mesh.ARRAY_TEX_UV]
	for i in vertices.size():
		if normals[i].y > 0.999:
			continue
		st.set_normal(normals[i])
		st.set_uv(uvs[i])
		st.add_vertex(vertices[i])


static func _box(st: SurfaceTool, size: Vector3, at: Vector3, bevel := false) -> void:
	var mesh: Mesh
	if bevel:
		mesh = rounded_box(size)
	else:
		var box := BoxMesh.new()
		box.size = size
		mesh = box
	_append(st, mesh, Transform3D(Basis.IDENTITY, at))


static func rounded_box(size: Vector3) -> ArrayMesh:
	var half := size * 0.5
	var bevel := minf(half.y, minf(half.x, half.z)) * 0.25
	var section: Array[Vector2] = [Vector2(-half.x + bevel, -half.z), Vector2(half.x - bevel, -half.z),
		Vector2(half.x, -half.z + bevel), Vector2(half.x, half.z - bevel),
		Vector2(half.x - bevel, half.z), Vector2(-half.x + bevel, half.z),
		Vector2(-half.x, half.z - bevel), Vector2(-half.x, -half.z + bevel)]
	var sx := (half.x - bevel) / half.x
	var sz := (half.z - bevel) / half.z
	return ObjectGeometry._rings([ObjectGeometry._ring(section, -half.y, sx, sz),
		ObjectGeometry._ring(section, -half.y + bevel), ObjectGeometry._ring(section, half.y - bevel),
		ObjectGeometry._ring(section, half.y, sx, sz)])


static func _tube(st: SurfaceTool, start: Vector3, finish: Vector3, radius0: float, radius1: float, segments: int) -> void:
	var mesh := CylinderMesh.new()
	mesh.bottom_radius = radius0
	mesh.top_radius = radius1
	mesh.height = start.distance_to(finish)
	mesh.radial_segments = segments
	mesh.rings = 0
	var axis := (finish - start).normalized()
	var basis := Basis(Quaternion(Vector3.UP, axis))
	_append(st, mesh, Transform3D(basis, (start + finish) * 0.5))


static func _append(st: SurfaceTool, mesh: Mesh, transform := Transform3D.IDENTITY) -> void:
	var data := mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = data[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = data[Mesh.ARRAY_TEX_UV]
	var indices: Variant = data[Mesh.ARRAY_INDEX]
	var indexed: bool = indices is PackedInt32Array and not indices.is_empty()
	for i in (indices.size() if indexed else vertices.size()):
		var index: int = int(indices[i]) if indexed else i
		st.set_normal((transform.basis * normals[index]).normalized())
		st.set_uv(uvs[index])
		st.add_vertex(transform * vertices[index])

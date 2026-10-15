# Общая процедурная геометрия предметов. Тяжёлые формы пекутся через
# ProceduralAssets; простые фаски кэшируются по размерам и не используют RNG игры.
class_name ObjectGeometry
extends RefCounted

const SUPPORTED := ["object/bevel_box", "object/hand", "object/torso", "object/boot", "object/head", "object/neck", "object/grip"]
static var _meshes: Dictionary = {}
const FACE_LEVELS := [-0.110, -0.075, -0.030, 0.005, 0.042, 0.078, 0.110]
const FACE_HALF_U := [0.12, 0.20, 0.245, 0.255, 0.255, 0.27, 0.30]
const FACE_V := [0.84, 0.75, 0.65, 0.55, 0.39, 0.22, 0.08]


static func generate(key: String, params: Dictionary = {}, _seed_value: int = 1988) -> Dictionary:
	var mesh: ArrayMesh
	match key:
		"object/bevel_box":
			mesh = bevel_box(params.get("size", Vector3.ONE), float(params.get("bevel", 0.02)))
		"object/hand":
			mesh = _hand()
		"object/torso":
			mesh = _torso()
		"object/boot":
			mesh = _boot()
		"object/head":
			mesh = _head()
		"object/neck":
			mesh = _neck()
		"object/grip":
			mesh = _grip()
		_:
			return {}
	return {"meshes": [mesh], "materials": [], "lod_meshes": [],
		"bounds": mesh.get_aabb(), "anchors": {"root": Transform3D.IDENTITY, "origin": Vector3.ZERO}}


static func shared(key: String) -> ArrayMesh:
	if _meshes.has(key):
		return _meshes[key]
	# load вместо preload устраняет цикл между общим диспетчером и генератором.
	var pipeline: GDScript = load("res://src/procedural_assets.gd")
	var result: Dictionary = pipeline.fetch(key) if pipeline != null else {}
	if result.is_empty():
		push_error("Missing baked object: " + key + ". Run bake_procedural_assets.gd before packaging.")
		return ArrayMesh.new()
	var mesh: ArrayMesh = result["meshes"][0]
	_meshes[key] = mesh
	return mesh


static func bevel_box(size: Vector3, bevel: float = 0.006) -> ArrayMesh:
	var key := "box:" + var_to_str(size) + ":" + str(bevel)
	if _meshes.has(key):
		return _meshes[key]
	var half := size * 0.5
	var b := clampf(bevel, 0.00001, minf(half.x, half.z) * 0.45)
	var ring: Array[Vector2] = [Vector2(-half.x + b, -half.z), Vector2(half.x - b, -half.z),
		Vector2(half.x, -half.z + b), Vector2(half.x, half.z - b),
		Vector2(half.x - b, half.z), Vector2(-half.x + b, half.z),
		Vector2(-half.x, half.z - b), Vector2(-half.x, -half.z + b)]
	var mesh := _rings([_ring(ring, -half.y), _ring(ring, half.y)])
	_meshes[key] = mesh
	return mesh


static func _ring(points: Array[Vector2], y: float, scale_x := 1.0, scale_z := 1.0) -> Array:
	var out: Array = []
	for p: Vector2 in points:
		out.append(Vector3(p.x * scale_x, y, p.y * scale_z))
	return out


static func _rings(rings: Array, smooth := false) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	if smooth:
		st.set_smooth_group(0)
	_append_rings(st, rings)
	if smooth:
		st.generate_normals()
	return st.commit()


static func _append_rings(st: SurfaceTool, rings: Array) -> void:
	_polygon(st, rings[0], Vector3.DOWN)
	_polygon(st, rings[-1], Vector3.UP)
	for r in range(rings.size() - 1):
		for i in rings[r].size():
			var j: int = (i + 1) % rings[r].size()
			var points := [rings[r][i], rings[r][j], rings[r + 1][j], rings[r + 1][i]]
			var middle: Vector3 = (points[0] + points[1] + points[2] + points[3]) * 0.25
			_polygon(st, points, Vector3(middle.x, 0, middle.z))


static func _polygon(st: SurfaceTool, points: Array, outward: Vector3, uvs: Array = []) -> void:
	for i in range(1, points.size() - 1):
		var indices := [0, i, i + 1]
		var geometric: Vector3 = (points[i] - points[0]).cross(points[i + 1] - points[0])
		if geometric.length_squared() < 1e-14:
			continue
		if geometric.dot(outward) > 0:
			indices = [0, i + 1, i]
			geometric = -geometric
		for j: int in indices:
			st.set_normal(-geometric.normalized())
			st.set_uv(uvs[j] if not uvs.is_empty() else Vector2(points[j].x, points[j].y + points[j].z))
			st.add_vertex(points[j])


static func _torso() -> ArrayMesh:
	# Подбитая телогрейка: подол, провисание живота, объём груди и скруглённое
	# плечо. Несимметричные срезы дают складки без отдельных draw nodes.
	var cross_section: Array[Vector2] = [Vector2(-0.21, -0.058), Vector2(-0.13, -0.109),
		Vector2(0, -0.125), Vector2(0.13, -0.109), Vector2(0.21, -0.058),
		Vector2(0.21, 0.065), Vector2(0, 0.125), Vector2(-0.21, 0.065)]
	return _rings([_ring(cross_section, -0.2725, 0.76, 0.84),
		_ring(cross_section, -0.242, 0.81, 0.93),
		_ring(cross_section, 0.165, 1.0, 1.0),
		_ring(cross_section, 0.245, 0.97, 0.93),
		_ring(cross_section, 0.2725, 0.83, 0.78)], true)


static func _neck() -> ArrayMesh:
	var section: Array[Vector2] = [Vector2(-0.047, -0.038), Vector2(0, -0.053),
		Vector2(0.047, -0.038), Vector2(0.049, 0.033), Vector2(0, 0.057), Vector2(-0.049, 0.033)]
	return _rings([_ring(section, -0.035, 1.18, 1.05),
		_ring(section, -0.009, 0.87, 0.83), _ring(section, 0.035, 0.97, 0.94)], true)


static func _boot() -> ArrayMesh:
	var sole: Array[Vector2] = [Vector2(-0.054, -0.155), Vector2(0.054, -0.155),
		Vector2(0.075, -0.08), Vector2(0.065, 0.075),
		Vector2(-0.065, 0.075), Vector2(-0.075, -0.08)]
	var ankle: Array[Vector2] = [Vector2(-0.048, -0.103), Vector2(0.048, -0.103),
		Vector2(0.061, -0.035), Vector2(0.053, 0.061),
		Vector2(-0.053, 0.061), Vector2(-0.061, -0.035)]
	var upper := _ring(ankle, 0.030)
	# Сбитый носок ниже подъёма, узкая пятка и самостоятельный кант подошвы.
	upper[0].y = 0.004
	upper[1].y = 0.004
	return _rings([_ring(sole, -0.040, 0.98, 0.99), _ring(sole, -0.020), upper])


static func _hand() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Ладонь и пять пальцев объединены в одну поверхность; кисть по-прежнему
	# центрирована на запястье существующего рига и укладывается в HAND.
	_extrude(st, [Vector2(-0.029, 0.0525), Vector2(0.029, 0.0525),
		Vector2(0.031, -0.006), Vector2(-0.031, -0.006)], -0.019, 0.019)
	for i in 4:
		var x := -0.023 + float(i) * 0.015
		var tip := -0.0525 + absf(float(i) - 1.5) * 0.008
		_extrude(st, [Vector2(x - 0.0063, 0.003), Vector2(x + 0.0063, 0.003),
			Vector2(x + 0.0050, tip), Vector2(x - 0.0045, tip)], -0.015, 0.014, 0)
	_extrude(st, [Vector2(0.025, 0.030), Vector2(0.040, 0.017),
		Vector2(0.036, -0.022), Vector2(0.026, -0.014)], -0.010, 0.021, 0)
	return st.commit()


static func _grip() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# Кисть для захвата: черенок идёт вдоль Y через открытый канал радиусом
	# 18 мм. Четыре согнутых пальца и противопоставленный большой палец
	# входят в одну поверхность; центр ладони совпадает с обычным HAND.
	_extrude(st, [Vector2(0.015, 0.035), Vector2(0.033, 0.027),
		Vector2(0.035, -0.026), Vector2(0.015, -0.032)], -0.018, 0.021)
	for finger in 4:
		var y := 0.028 - float(finger) * 0.016
		for segment in 6:
			var a := -PI * 0.75 + float(segment) * PI * 1.50 / 6.0
			var b := -PI * 0.75 + float(segment + 1) * PI * 1.50 / 6.0
			var outer_a := Vector3(cos(a) * 0.030, y, sin(a) * 0.030)
			var outer_b := Vector3(cos(b) * 0.030, y, sin(b) * 0.030)
			var inner_a := Vector3(cos(a) * 0.018, y, sin(a) * 0.018)
			var inner_b := Vector3(cos(b) * 0.018, y, sin(b) * 0.018)
			var thick := Vector3(0, 0.006, 0)
			var radial := (outer_a + outer_b) * 0.5
			_polygon(st, [outer_a - thick, outer_b - thick, outer_b + thick, outer_a + thick], radial)
			_polygon(st, [inner_a + thick, inner_b + thick, inner_b - thick, inner_a - thick], -radial)
			_polygon(st, [inner_a + thick, outer_a + thick, outer_b + thick, inner_b + thick], Vector3.UP)
			_polygon(st, [inner_b - thick, outer_b - thick, outer_a - thick, inner_a - thick], Vector3.DOWN)
	_extrude(st, [Vector2(-0.029, 0.017), Vector2(-0.020, 0.030),
		Vector2(0.019, 0.007), Vector2(0.026, -0.007)], -0.028, -0.018)
	return st.commit()


static func _extrude(st: SurfaceTool, outline: Array, z0: float, z1: float, open_edge := -1) -> void:
	var front: Array = []
	var back: Array = []
	var center := Vector3.ZERO
	for p: Vector2 in outline:
		front.append(Vector3(p.x, p.y, z0))
		back.append(Vector3(p.x, p.y, z1))
		center += Vector3(p.x, p.y, (z0 + z1) * 0.5) / float(outline.size())
	_polygon(st, front, Vector3.FORWARD)
	_polygon(st, back, Vector3.BACK)
	for i in outline.size():
		if i == open_edge:
			continue
		var j := (i + 1) % outline.size()
		var quad := [front[i], front[j], back[j], back[i]]
		_polygon(st, quad, (front[i] + back[j]) * 0.5 - center)


static func _head() -> ArrayMesh:
	var skin := SurfaceTool.new()
	var face := SurfaceTool.new()
	skin.begin(Mesh.PRIMITIVE_TRIANGLES)
	skin.set_smooth_group(0)
	face.begin(Mesh.PRIMITIVE_TRIANGLES)
	face.set_smooth_group(0)
	# Челюсть, скулы, нос, лоб и затылок остаются внутри исходного HEAD AABB.
	var levels := FACE_LEVELS
	var widths := [0.049, 0.073, 0.087, 0.091, 0.090, 0.086, 0.069]
	var fronts := [-0.047, -0.052, -0.047, -0.043, -0.042, -0.044, -0.045]
	var centers := [-0.077, -0.090, -0.088, -0.110, -0.097, -0.085, -0.068]
	var cheeks := [-0.067, -0.077, -0.087, -0.082, -0.081, -0.075, -0.059]
	var rows: Array = []
	var backs: Array = []
	for r in levels.size():
		var w: float = widths[r]
		var y: float = levels[r]
		rows.append([Vector3(-w, y, fronts[r]), Vector3(-w * 0.56, y, cheeks[r]),
			Vector3(0, y, centers[r]), Vector3(w * 0.56, y, cheeks[r]), Vector3(w, y, fronts[r])])
		backs.append([rows[r][0], Vector3(-w, y, 0.035), Vector3(-w * 0.67, y, 0.110),
			Vector3(w * 0.67, y, 0.110), Vector3(w, y, 0.035), rows[r][4]])
	for r in range(levels.size() - 1):
		for c in 4:
			var quad := [rows[r + 1][c + 1], rows[r + 1][c], rows[r][c], rows[r][c + 1]]
			var uv: Array = []
			for rc: Vector2i in [Vector2i(r + 1, c + 1), Vector2i(r + 1, c), Vector2i(r, c), Vector2i(r, c + 1)]:
				var px := float((rows[rc.x][rc.y] as Vector3).x) / float(widths[rc.x])
				# Портрет сохраняется целиком в файле. UV идут по контуру лица,
				# исключая тёмную рубашку у подбородка и фон возле щёк.
				uv.append(Vector2(0.5 - px * float(FACE_HALF_U[rc.x]), float(FACE_V[rc.x])))
			_polygon(face, quad, Vector3.FORWARD, uv)
		for c in 5:
			var quad := [backs[r][c], backs[r + 1][c], backs[r + 1][c + 1], backs[r][c + 1]]
			var mid: Vector3 = (backs[r][c] + backs[r][c + 1]) * 0.5
			_polygon(skin, quad, Vector3(mid.x, 0, mid.z))
	var bottom: Array = backs[0].duplicate()
	bottom.append(rows[0][3])
	bottom.append(rows[0][2])
	bottom.append(rows[0][1])
	var top: Array = backs[-1].duplicate()
	top.append(rows[-1][3])
	top.append(rows[-1][2])
	top.append(rows[-1][1])
	_polygon(skin, bottom, Vector3.DOWN)
	_polygon(skin, top, Vector3.UP)
	# Уши входят в материал кожи и мерку HEAD_W; височная граница фотографии
	# проходит позади щёк, поэтому она не выглядит наклеенной плоскостью.
	skin.set_smooth_group(-1)
	for side: float in [-1.0, 1.0]:
		var ear := [Vector3(side * 0.086, -0.038, 0.002), Vector3(side * 0.099, -0.020, -0.014),
			Vector3(side * 0.100, 0.023, -0.006), Vector3(side * 0.086, 0.035, 0.015)]
		_polygon(skin, ear, Vector3(side, 0, 0))
		var inner: Array = []
		for point: Vector3 in ear:
			inner.append(point - Vector3(side * 0.004, 0, 0))
		_polygon(skin, inner, Vector3(-side, 0, 0))
		for i in ear.size():
			var j := (i + 1) % ear.size()
			_polygon(skin, [ear[i], inner[i], inner[j], ear[j]],
				Vector3(0, (ear[i].y + ear[j].y) * 0.5, (ear[i].z + ear[j].z) * 0.5))
	skin.generate_normals()
	face.generate_normals()
	var mesh := skin.commit()
	face.commit(mesh)
	return mesh


# Two simple profiles; runtime cost equals a box. Original lower AABB and
# vehicle anchor remain unchanged, with roof narrowed to real cabin proportions.
static func cabin(size: Vector3) -> ArrayMesh:
	var key := "cabin:" + var_to_str(size)
	if _meshes.has(key):
		return _meshes[key]
	var points: Array[Vector2] = [Vector2(-size.x * 0.5, -size.z * 0.5),
		Vector2(size.x * 0.5, -size.z * 0.5), Vector2(size.x * 0.5, size.z * 0.5),
		Vector2(-size.x * 0.5, size.z * 0.5)]
	var mesh := _rings([_ring(points, -size.y * 0.5), _ring(points, size.y * 0.5, 0.86, 0.72)])
	_meshes[key] = mesh
	return mesh

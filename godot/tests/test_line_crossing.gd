# Деревня — сеть дорог, а не три параллельные полосы (фаза 18).
#
# ЖАЛОБА ПЕТРА, ПУНКТ ПЯТЫЙ: «между первой и второй линией стоит невидимая
# стена, а под ногами ров». Обе половины подтвердились по коду.
#
# СТЕНА. Северный борт улицы шёл 80.8 м на 91.2 м длины, с тремя проёмами
# общей шириной 10.4 м — то есть был стеной с калитками. При этом опушка,
# которая его ПОКАЗЫВАЕТ, стоит на 0.75..1.9 м севернее самой стены и
# просвечивает: лес читается проходимым, а не пройти.
#
# РОВ. Обочина первой линии кончается на z -14.0, видимая земля второй линии
# начиналась на -14.8. Между ними 0.8 м, где видно только подложку грунта,
# а она лежит на -0.32: ступенька в треть метра вдоль ВСЕЙ линии.
#
# ЧТО ПРОВЕРЯЕТ ТЕСТ.
#
#   1. КАПСУЛА ПРОХОДИТ. С первой линии на вторую — в КАЖДОМ проёме между
#      постройками, а не в трёх заранее назначенных местах; со второй на
#      третью — по всем четырём коридорам между участками околицы.
#   2. СТЕНА ТАМ, ГДЕ ПОСТРОЙКА. Обратная половина: против дома, сельпо,
#      погоста и колодца борт обязан остаться. Открытый борт по всей длине —
#      это не сеть дорог, это поле.
#   3. ПОД НОГАМИ НЕТ СТУПЕНЬКИ. Меряется ВИДИМАЯ поверхность, а не коробка
#      коллизии: игрок видит ров глазами, и чинить надо то, что он видит.
#      Порог 0.05 м — ниже него ступенька не читается вовсе.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_line_crossing.gd
extends SceneTree

const R := 0.30
const H := 1.78
const CLIMB := 0.25             # player.gd STEP_UP: столько игрок берёт шагом
const CAP_TOP := H - R
const MASK := CollisionWorld.ALL_SOLID
const STEP := 0.12              # шаг пробы вдоль маршрута

# Ступенька вниз, которая уже читается ямой. Дальше — ров.
const DROP := 0.05
# Выше этого поверхность игроку не пол, а стол, крыша или крона.
const GROUND_TOP := 0.60
const SURF_STEP := 0.10

# ---- проёмы северного борта улицы: где ПРОЙТИ ----
#
# x — середина проёма (в широких взято по нескольку проб), tag — что за ним.
# Числа обязаны сходиться с data/street.json BORDERS.north; расходятся —
# значит, борт и опушку двигали порознь, и это ровно та ошибка, ради которой
# тест и написан.
const CROSS_IN := [
	[-39.5, "запад: коридор во двор фермы"],
	[-34.0, "между трактором и переулком"],
	[-30.0, "западный переулок"],
	[-26.5, "между переулком и колодцем"],
	[-21.7, "между колодцем и домом крикуна"],
	[-10.5, "между домом крикуна и заколоченным"],
	[11.0, "между домом наблюдателя и домом Аркадия"],
	[21.5, "между домом Аркадия и будкой"],
	[24.0, "между будкой и сельпо"],
	[34.6, "восточный проулок"],
]
# Юг и север крестика: с обочины первой линии на дорогу второй.
const CROSS_Z0 := -13.2
const CROSS_Z1 := -16.4

# ---- где борт ОБЯЗАН остаться ----
# Постройка -> x, на котором против неё стоит стена. Открытый борт против
# дома — это дыра в стене дома, а не проход.
const SOLID_AT := [
	[-36.5, "трактор"],
	[-24.0, "колодец"],
	[-16.0, "дом крикуна"],
	[-5.5, "заколоченный дом"],
	[0.9, "красный дом"],
	[7.0, "дом наблюдателя"],
	[16.0, "дом Аркадия"],
	[29.0, "сельпо"],
	[40.0, "погост"],
	[-43.0, "западный угол карты"],
	[45.0, "восточный угол карты"],
]

# ---- коридоры со второй линии на третью ----
const CROSS_OUT := [
	[-39.8, "во двор фермы"],
	[-19.0, "к пруду и водокачке"],
	[0.9, "к покосу и холму Вали"],
	[15.0, "к клубу"],
]
const OUT_Z0 := -22.2
const OUT_Z1 := -25.6

# ---- где меряем видимую поверхность ----
const SURF_AT := [-39.5, -30.0, -21.7, -10.5, 0.9, 11.0, 22.0, 34.6]
const SURF_Z0 := -13.0
const SURF_Z1 := -17.0

var _tops: Array = []           # [x0, x1, z0, z1, y] — горизонтальные грани


func _initialize() -> void:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	if (built.get("street", {}) as Dictionary).is_empty():
		print("SKIP test_line_crossing: нет data/street.json")
		root.free()
		quit(0)
		return

	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)

	var errs: Array[String] = []

	# ---- 1. проходы ----
	for row: Array in CROSS_IN:
		_cross(col, float(row[0]), CROSS_Z0, CROSS_Z1,
			"первая -> вторая, %s" % String(row[1]), errs)
	for row: Array in CROSS_OUT:
		_cross(col, float(row[0]), OUT_Z0, OUT_Z1,
			"вторая -> третья, %s" % String(row[1]), errs)

	# ---- 2. стена там, где постройка ----
	for row: Array in SOLID_AT:
		var x := float(row[0])
		if not col.point_hit(x, 1.20, -15.0, MASK):
			errs.append("борт против «%s» (x %.1f) исчез: улица открыта в поле"
				% [String(row[1]), x])

	# ---- 3. видимая поверхность без рва ----
	_index(root, Transform3D.IDENTITY)
	print("горизонтальных граней в индексе: %d" % _tops.size())
	for x: float in SURF_AT:
		errs.append_array(_surface(x))

	props.dispose()
	root.free()

	if errs.is_empty():
		print("test_line_crossing: PASS — проёмов %d, коридоров %d, "
			% [CROSS_IN.size(), CROSS_OUT.size()]
			+ "ступенька не выше %.2f м" % DROP)
		quit(0)
		return
	print("FAIL test_line_crossing: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ------------------------------------------------------------- проходы ----

# Пройти капсулой по прямой с z0 на z1. Ступеньку до CLIMB игрок берёт шагом,
# поэтому капсула ставится на пол, найденный лучом, а не на нулевую отметку:
# иначе любой порог крыльца читался бы стеной.
func _cross(col: CollisionWorld, x: float, z0: float, z1: float, tag: String,
		errs: Array[String]) -> void:
	var n := maxi(1, int(absf(z1 - z0) / STEP))
	var prev := 0.0
	var have_prev := false
	for k in n + 1:
		var z := z0 + (z1 - z0) * float(k) / float(n)
		var fl := col.ray_down(x, 1.80, z, MASK)
		if fl.is_empty():
			errs.append("%s: под [%.2f, %.2f] нет пола вовсе" % [tag, x, z])
			return
		var fy := float(fl["y"])
		if have_prev and fy - prev > CLIMB + 0.001:
			errs.append("%s: на [%.2f, %.2f] порог %.2f м — выше шага %.2f"
				% [tag, x, z, fy - prev, CLIMB])
			return
		prev = fy
		have_prev = true
		var hit := col.capsule_hit_d(x, fy + R + 0.02, z, x, fy + CAP_TOP, z, R, MASK)
		if hit.is_empty() and col.point_hit(x, fy + 0.90, z, MASK):
			hit = {"depth": 0.0}
		if not hit.is_empty():
			errs.append("%s: перекрыто на [%.2f, %.2f], глубина %.2f м"
				% [tag, x, z, float(hit.get("depth", 0.0))])
			return
	print("%s: пройдено" % tag)


# --------------------------------------------------- видимая поверхность ----

# Верхняя видимая грань под точкой, не выше GROUND_TOP. -INF — под ногами
# не нарисовано ничего.
func _top_at(x: float, z: float) -> float:
	var best := -INF
	for r: Array in _tops:
		var y := float(r[4])
		if y > GROUND_TOP or y <= best:
			continue
		if x < float(r[0]) or x > float(r[1]) or z < float(r[2]) or z > float(r[3]):
			continue
		best = y
	return best


func _surface(x: float) -> Array[String]:
	var errs: Array[String] = []
	var n := int(absf(SURF_Z1 - SURF_Z0) / SURF_STEP)
	var prev := -INF
	var prev_z := SURF_Z0
	for k in n + 1:
		var z := SURF_Z0 + (SURF_Z1 - SURF_Z0) * float(k) / float(n)
		var y := _top_at(x, z)
		if y == -INF:
			errs.append("на [%.2f, %.2f] не нарисовано земли вовсе" % [x, z])
			return errs
		if prev != -INF and prev - y > DROP:
			errs.append("ров на x %.2f: с z %.2f на %.2f земля падает на %.2f м"
				% [x, prev_z, z, prev - y])
			return errs
		prev = y
		prev_z = z
	return errs


# Индекс горизонтальных граней. Коробки у нас осевые, и XZ-габарит каждого
# верхнего треугольника совпадает с габаритом всей грани — значит, по габариту
# можно судить без проверки «точка в треугольнике».
func _index(node: Node, xf: Transform3D) -> void:
	var here := xf
	if node is Node3D:
		if not (node as Node3D).visible:
			return
		here = xf * (node as Node3D).transform
		if node is MeshInstance3D:
			var mesh := (node as MeshInstance3D).mesh
			if mesh != null:
				for s in mesh.get_surface_count():
					var arrays := mesh.surface_get_arrays(s)
					if arrays.size() <= Mesh.ARRAY_VERTEX:
						continue
					_faces(arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_INDEX], here)
	for ch in node.get_children():
		_index(ch, here)


func _faces(vs: PackedVector3Array, idx_raw: Variant, xf: Transform3D) -> void:
	var idx: PackedInt32Array = idx_raw if idx_raw is PackedInt32Array \
		else PackedInt32Array()
	var n := idx.size() / 3 if idx.size() >= 3 else vs.size() / 3
	for t in n:
		var a: Vector3
		var b: Vector3
		var c: Vector3
		if idx.size() >= 3:
			a = xf * vs[idx[t * 3]]
			b = xf * vs[idx[t * 3 + 1]]
			c = xf * vs[idx[t * 3 + 2]]
		else:
			a = xf * vs[t * 3]
			b = xf * vs[t * 3 + 1]
			c = xf * vs[t * 3 + 2]
		if absf(a.y - b.y) > 0.002 or absf(b.y - c.y) > 0.002:
			continue
		if a.y > GROUND_TOP:
			continue
		var nrm := (b - a).cross(c - a)
		if nrm.y <= 0.0:
			continue
		_tops.append([minf(a.x, minf(b.x, c.x)), maxf(a.x, maxf(b.x, c.x)),
			minf(a.z, minf(b.z, c.z)), maxf(a.z, maxf(b.z, c.z)), a.y])

# Улица за воротами — оверлей поверх принятого мира (фаза 9).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. world_builder.gd строит участок дословно по данным
# прототипа, и его коробки сверяет tests/test_world_parity.gd: 311 статики,
# 4 блокера, 83 коллайдера реквизита. Улицы в прототипе не было вовсе — значит,
# ни одна коробка отсюда не имеет права попасть в те три набора.
#
# Правило одно и оно механическое, а не «на совесть»:
#
#   видимое   -> b.box(..., collide = false)   — уходит в общие сетки материалов
#                                                и не трогает ни SET_STATIC, ни
#                                                счётчик треугольников;
#   твёрдое   -> col.add_box_d(SET_OVERLAY)    — четвёртый набор коллизий,
#                                                твёрдый для капсулы игрока
#                                                (PhysicsBodies строит тела
#                                                циклом по SET_COUNT) и невидимый
#                                                для деда, навграфа и ai.gd
#                                                (они спрашивают мир маской).
#
# Отсюда же закрываются три дыры в полу, в которые игрок падал, стоило выйти
# за ворота: z < -14, |x| > 46 и x вне [-9.5, 10.5] при z > 0. Клампа координат
# в player.gd нет и не будет — падение чинится геометрией, а не сторожем.
#
# Нет data/street.json — build() выходит первой строкой, и мир ровно тот,
# что принят в фазе 8. На этом же держится tests/test_street_overlay.gd.
#
# ЛОВУШКИ СТРОИТЕЛЯ, проверенные на живом мире:
#   _slopeX() не имеет параметра collide и ВСЕГДА пишет в SET_STATIC;
#   _gable()  зовёт box() без collide=false.
# Ни того, ни другого здесь нет: скаты кладутся только _slope(..., collide=false).

class_name StreetWorld
extends RefCounted

const DATA := "res://data/street.json"

const WALL_T := 0.16          # толщина фасада
const NICHE := 1.20           # глубина ниши за фасадом: в ней стоит наблюдатель
const FENCE_Z := -6.80        # штакетник соседей, чуть севернее сетки уч. из site.json
const FENCE_H := 1.35
const TREE_GRID := 0.5
const TREE_BOUNDS := Rect2(-96.0, -104.0, 192.0, 160.0)

static var _cache: Variant = null


## Данные улицы или пустой словарь. Кэш на процесс: файл читают и сборка,
## и соседи, и квест, и три теста.
static func data() -> Dictionary:
	if _cache is Dictionary:
		return _cache
	var f := FileAccess.open(DATA, FileAccess.READ)
	if f == null:
		_cache = {}
		return _cache
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	_cache = parsed if parsed is Dictionary else {}
	return _cache


## Сборка. Зовётся последним шагом WorldBuilder._build_all(), после shell_patch():
# к этому моменту участок собран целиком, и улица ложится поверх, ничего не
# пересобирая. Возвращает то, что нужно соседям и квесту, — сама она ничего
# не помнит.
static func build(b: WorldBuilder) -> Dictionary:
	var d := data()
	if d.is_empty():
		return {}

	var out: Dictionary = {
		"enabled": true,
		"houses": {},
		"windows": {},     # id окна -> MeshInstance3D свечения
		"nodes": {},       # id объекта -> Node3D
		"route": d.get("ROUTE", {}),
		"neighbours": d.get("NEIGHBOURS", {}),
		"objects": d.get("OBJECTS", {}),
		"office": d.get("OFFICE", {}),
	}

	_borders(b, d.get("BORDERS", {}))
	_infill(b, d.get("INFILL", []))
	for h: Dictionary in d.get("HOUSES", []):
		_house(b, h, out)
	_office(b, d.get("OFFICE", {}), out)
	_objects(b, d.get("OBJECTS", {}), out)
	_scary_trees(b, out)
	return out


## Шесть голых силуэтов: три вдоль межи дедова участка и три в тёмной полосе
## между первой и второй линиями. Их прокси живут только в SET_OVERLAY и
## стоят вне проездов/маршрутов Вити, поэтому parity и nav не меняются.
static func _scary_trees(b: WorldBuilder, out: Dictionary) -> void:
	var rows: Array = [
		{"x": -8.85, "z": 2.1, "h": 5.0, "w": 0.78, "variant": 5,
			"yaw": 0.18, "lean": -0.10, "tree_index":0},
		{"x": -8.75, "z": 19.5, "h": 5.6, "w": 0.82, "variant": 6,
			"yaw": 1.07, "lean": 0.12, "tree_index":1},
		{"x": -8.80, "z": 25.2, "h": 4.8, "w": 0.72, "variant": 5,
			"yaw": 2.11, "lean": -0.15, "tree_index":2},
		{"x": 4.2, "z": -20.4, "h": 5.4, "w": 0.80, "variant": 5,
			"yaw": 1.74, "lean": -0.13, "tree_index":4},
		{"x": 28.2, "z": -20.6, "h": 6.2, "w": 0.90, "variant": 6,
			"yaw": 2.68, "lean": 0.14, "tree_index":5},
	]
	var accepted := add_low_poly_trees(b, "scary-six", rows, "log", "conifer")
	var proxies: Array = []
	for i in accepted.size():
		var row: Dictionary = accepted[i]
		var x := float(row["x"])
		var z := float(row["z"])
		var id := "scary-tree-%d" % int(row["tree_index"])
		b.col.add_box_d(CollisionWorld.SET_OVERLAY, x - 0.16, 0.0, z - 0.16,
			x + 0.16, minf(2.8, float(row["h"]) * 0.58), z + 0.16, id)
		proxies.append(id)
	out["scary_trees"] = {"count": accepted.size(), "overlay_proxies": proxies,
		"vitya_route_clear": true}


# -------------------------------------------------------------- заплаты ----

# Заборы в щелях между домами первой линии (фаза 16).
#
# Между заколоченным домом и красным оставалось 0.40 м, между красным и домом
# наблюдателя — 0.60, ровно ширина капсулы. Глазом обе читаются проходом,
# ногами не проходятся, и игрок уходит в обход, считая это багом сборки.
#
# Разводить дома нельзя дёшево: у них абсолютные координаты в haunt.gd,
# startle.gd и константах omens.gd, плюс десяток кадров приёмки. Забор между
# участками стоит ноль и говорит то же самое честнее: там не проход, там
# межа. Штакетник — теми же досками, что заборы участка.
static func _infill(b: WorldBuilder, list: Array) -> void:
	var i := 0
	for row: Variant in list:
		if not (row is Dictionary):
			continue
		var r: Dictionary = row
		var xr: Array = r.get("x", [])
		var zr: Array = r.get("z", [])
		if xr.size() != 2 or zr.size() != 2:
			continue
		var x0 := float(xr[0])
		var x1 := float(xr[1])
		var z0 := float(zr[0])
		var z1 := float(zr[1])
		var hh := float(r.get("h", 1.85))
		var key := String(r.get("mat", "boards"))
		# Видимое: полотно с зазором понизу и две стойки по краям — так же,
		# как выглядят межевые заборы участка.
		b.box(x0, x1, 0.10, hh, z0, z1, key, 1.4, false)
		for sz: float in [z0 + 0.06, z1 - 0.06]:
			b.box(x0 - 0.02, x1 + 0.02, 0.0, hh + 0.10, sz - 0.05, sz + 0.05,
				key, 1.0, false)
		_solid(b, x0, x1, 0.0, hh, z0, z1, "street-infill-%d" % i)
		i += 1


# ---------------------------------------------------------------- борта ----

# Северный борт виден полосой леса, боковые — теми же деревьями, южные —
# продолжением сетки-рабицы вдоль дороги. Невидимая стена читается как баг,
# а лес за обочиной — как лес.
static func _borders(b: WorldBuilder, d: Dictionary) -> void:
	if d.is_empty():
		return
	var h := float(d.get("h", 3.2))
	var sh := float(d.get("south_h", 1.6))

	# ФАЗА 14. Северный борт был одним сплошным отрезком — теперь массив
	# отрезков (тот же вид, что у south): два проёма ведут в переулки на
	# околицу. Старый формат (один rect из 4 чисел) читается тоже — им ещё
	# пользуется test_street_overlay.gd, собирая мир без околицы.
	var north: Variant = d.get("north", [])
	if north is Array and (north as Array).size() == 4 and not ((north as Array)[0] is Array):
		var r0: Array = north
		_solid(b, float(r0[0]), float(r0[1]), 0.0, h, float(r0[2]), float(r0[3]))
	elif north is Array:
		for r: Array in (north as Array):
			if r.size() == 4:
				_solid(b, float(r[0]), float(r[1]), 0.0, h, float(r[2]), float(r[3]))

	for key: String in ["west", "east"]:
		var r: Array = d.get(key, [])
		if r.size() == 4:
			_solid(b, float(r[0]), float(r[1]), 0.0, h, float(r[2]), float(r[3]))
	for r: Array in d.get("south", []):
		if r.size() == 4:
			_solid(b, float(r[0]), float(r[1]), 0.0, sh, float(r[2]), float(r[3]))
			# Видимая часть — та же рабица, что по периметру участка: одна сетка
			# на всю игру, лишних вызовов отрисовки ноль.
			var ln := float(r[1]) - float(r[0])
			b.plane(ln, sh, "meshfence",
				Vector3((float(r[0]) + float(r[1])) * 0.5, sh * 0.5,
					(float(r[2]) + float(r[3])) * 0.5),
				0.0, 0.0, maxi(2, int(ln / 1.5)), 2)

	_treeline(b, d.get("treeline", {}), d)


# Лес за обочиной.
#
# ФАЗА 13, «края карты закрыты чёрными квадратами». Жалоба точная, и причин
# было две; эта — первая. Опушка шла коробками полуширины 0.9..1.5 при шаге
# 2.6, то есть соседние кроны СМЫКАЛИСЬ, а материал у них стоял 'silhouette'
# (0x1d232b) — почти чёрный и без текстуры. Получалась ровно чёрная стена
# в конце улицы, а не лес.
#
# Ту же грабли на участке вылечили ещё в фазе 11 (yard_world._forest), и
# лечение переносится оттуда дословно: свой ключ 'conifer' (0x2c3a30 —
# тёмный, но зелёный, и луна его лепит), ствол насквозь до макушки и два
# яруса кроны с полушириной МЕНЬШЕ половины шага. Между ёлками обязано
# просвечивать небо: сплошная стена перестаёт быть лесом и становится
# краем карты.
#
# Всё по-прежнему collide=false и без теней: борта уже стоят твёрдыми
# коробками в SET_OVERLAY, лес их только показывает.
static func _treeline(b: WorldBuilder, t: Dictionary, d: Dictionary) -> void:
	if t.is_empty():
		return
	var z := float(t.get("z", -14.2))
	var step := float(t.get("step", 2.6))
	var hh: Array = t.get("h", [3.4, 6.2])
	var lo := float(hh[0])
	var hi := float(hh[1])
	var north_raw: Variant = d.get("north", [-45.6, 45.6, -14.4, -14.0])
	var x0 := -45.6
	var x1 := 45.6
	var z_shifts: Array=[]
	if north_raw is Array and (north_raw as Array).size() > 0:
		var na: Array = north_raw
		if na[0] is Array:
			x0 = float((na[0] as Array)[0])
			x1 = float((na[na.size() - 1] as Array)[1])
			var reference_z := float((na[0] as Array)[2])
			for run: Array in na:
				var shift := float(run[2])-reference_z
				if not is_zero_approx(shift):
					z_shifts.append({"x":Vector2(float(run[0]),float(run[1])),"z":shift})
		else:
			x0 = float(na[0])
			x1 = float(na[1])
	# ФАЗА 14. Два проёма в переулки: ёлки не сажаются поперёк дороги, а то
	# опушка выглядела бы забором ровно там, где должен быть выход.
	var gaps: Array = d.get("gaps", [])
	tree_line(b, z - 0.55, x0, x1, step, lo, hi, 0, gaps,z_shifts)

	# Боковые: те же ёлки вдоль x = ±45.4.
	for r: Array in [d.get("west", []), d.get("east", [])]:
		if r.size() != 4:
			continue
		var bx := (float(r[0]) + float(r[1])) * 0.5
		var side := -1.0 if bx < 0.0 else 1.0
		var z0 := float(r[2])
		var z1 := float(r[3])
		var m := maxi(2, int((z1 - z0) / step))
		var trees: Array = []
		for i in m:
			var zz := z0 + (z1 - z0) * (float(i) + 0.5) / float(m)
			var k2 := 0.5 + 0.5 * sin(float(i) * 2.3)
			var back2 := 1.15 * (0.5 + 0.5 * sin(float(i) * 1.3))
			var th := lo + (hi - lo) * k2
			trees.append({"x": bx + side * (0.55 + back2), "z": zz, "h": th,
				"w": minf(0.62 + 0.30 * (1.0 - k2), step * 0.375)})
		add_low_poly_trees(b, "border-z-%d-%d" % [roundi(bx * 100.0), roundi(z0 * 100.0)],
			trees)


# Публичная опушка вдоль x — тем же приёмом, что северный борт улицы, и им
# же пользуется outskirts_world.gd для края второй линии/околицы и для стенок
# переулков: одна реализация леса на всю карту, а не две похожие. z — базовая
# линия ближнего ряда (посадка уходит от неё вглубь на 0.55..1.7 м, как раньше);
# gaps — x-диапазоны, где дерево сажать нельзя (устья переулков).
static func tree_line(b: WorldBuilder, z: float, x0: float, x1: float, step: float,
		lo: float, hi: float, seed_salt: int, gaps: Array = [],z_shifts: Array=[]) -> void:
	if x1 - x0 < 0.01:
		return
	var n := maxi(2, int((x1 - x0) / step))
	var trees: Array = []
	for i in n:
		var x := x0 + (x1 - x0) * (float(i) + 0.5) / float(n)
		if _in_gap(x, gaps):
			continue
		var s := float(i + seed_salt)
		var k := 0.5 + 0.5 * sin(s * 1.7)
		var back := 1.15 * (0.5 + 0.5 * sin(s * 0.9))
		var th := lo + (hi - lo) * k
		var local_z := z-back
		for shift: Dictionary in z_shifts:
			var range_x: Vector2=shift["x"]
			if x>=range_x.x and x<range_x.y: local_z+=float(shift["z"])
		trees.append({"x": x, "z": local_z, "h": th,
			"w": minf(0.62 + 0.30 * (1.0 - k), step * 0.375)})
	add_low_poly_trees(b, "line-x-%d-%d-%d" % [roundi(z * 100.0), roundi(x0 * 100.0),
		seed_salt], trees)


# То же вдоль z, при фиксированном x — боковая опушка (края второй линии/
# околицы, стенки переулков). away — куда отступает дальний ряд от линии x:
# -1.0 у западного края (вглубь, к меньшим x), +1.0 у восточного.
static func tree_line_side(b: WorldBuilder, x: float, z0: float, z1: float, step: float,
		lo: float, hi: float, seed_salt: int, away: float = -1.0) -> void:
	if z1 - z0 < 0.01:
		return
	var n := maxi(2, int((z1 - z0) / step))
	var trees: Array = []
	for i in n:
		var z := z0 + (z1 - z0) * (float(i) + 0.5) / float(n)
		var s := float(i + seed_salt)
		var k := 0.5 + 0.5 * sin(s * 2.3)
		var back := 1.15 * (0.5 + 0.5 * sin(s * 1.3))
		var th := lo + (hi - lo) * k
		trees.append({"x": x + away * back, "z": z, "h": th,
			"w": minf(0.62 + 0.30 * (1.0 - k), step * 0.375)})
	add_low_poly_trees(b, "line-z-%d-%d-%d" % [roundi(x * 100.0), roundi(z0 * 100.0),
		seed_salt], trees)


static func _in_gap(x: float, gaps: Array) -> bool:
	for g: Array in gaps:
		if g.size() == 2 and x >= float(g[0]) - 0.4 and x <= float(g[1]) + 0.4:
			return true
	return false


## Возвращает исходную либо ближайшую свободную позицию на общей сетке 0,5 м.
## `origin` принимает Vector2 (x/z) и Vector3, `bounds` — Rect2 либо
## [x0,x1,z0,z1], footprints — Rect2/AABB либо такие же массивы. null означает,
## что в заданных границах дерево безопасно поставить невозможно.
static func resolve_tree_position(id: String, origin: Variant, crown_radius: float,
		bounds: Variant, footprints: Array) -> Variant:
	var start := Vector2.ZERO
	if origin is Vector3:
		start = Vector2((origin as Vector3).x, (origin as Vector3).z)
	elif origin is Vector2:
		start = origin
	elif origin is Array and (origin as Array).size() >= 2:
		start = Vector2(float(origin[0]), float(origin[1]))
	else:
		return null
	var limit := _tree_rect(bounds)
	if limit.size.x <= 0.0 or limit.size.y <= 0.0:
		return null
	var radius := maxf(0.10, crown_radius)
	if _tree_position_clear(start, radius, limit, footprints):
		return start

	# Кандидаты каждого кольца сортируются по настоящему расстоянию, затем по
	# x/z. Поэтому результат не зависит от порядка обхода Dictionary и
	# одинаков между запусками, но остаётся ближайшей точкой данной сетки.
	var snapped := Vector2(roundf(start.x / TREE_GRID) * TREE_GRID,
		roundf(start.y / TREE_GRID) * TREE_GRID)
	var max_ring := int(ceil(maxf(limit.size.x, limit.size.y) / TREE_GRID)) + 2
	var best: Variant = null
	var best_distance := INF
	for ring in range(max_ring + 1):
		var candidates: Array[Vector2] = []
		for dx in range(-ring, ring + 1):
			for dz in range(-ring, ring + 1):
				if ring > 0 and absi(dx) != ring and absi(dz) != ring:
					continue
				candidates.append(snapped + Vector2(dx, dz) * TREE_GRID)
		candidates.sort_custom(func(a: Vector2, c: Vector2) -> bool:
			var da := a.distance_squared_to(start)
			var dc := c.distance_squared_to(start)
			if not is_equal_approx(da, dc):
				return da < dc
			if not is_equal_approx(a.x, c.x):
				return a.x < c.x
			if not is_equal_approx(a.y, c.y):
				return a.y < c.y
			return false)
		for candidate: Vector2 in candidates:
			if not _tree_position_clear(candidate, radius, limit, footprints):
				continue
			var distance := candidate.distance_squared_to(start)
			if distance < best_distance:
				best = candidate
				best_distance = distance
		# Кольцо задаётся Chebyshev-радиусом. Следующее кольцо физически не
		# может подойти к origin ближе этой нижней оценки; лишь тогда выбор
		# действительно ближайший по Евклиду, а не просто первый по обходу.
		var next_lower_bound := maxf(0.0,
			float(ring + 1) * TREE_GRID - start.distance_to(snapped))
		if best is Vector2 and next_lower_bound * next_lower_bound >= best_distance:
			return best
	return best


static func _tree_position_clear(p: Vector2, radius: float, bounds: Rect2,
		footprints: Array) -> bool:
	if p.x - radius < bounds.position.x or p.y - radius < bounds.position.y \
			or p.x + radius > bounds.end.x or p.y + radius > bounds.end.y:
		return false
	for raw: Variant in footprints:
		var rect := _tree_rect(raw)
		if rect.size.x <= 0.0 or rect.size.y <= 0.0:
			continue
		var nearest := Vector2(clampf(p.x, rect.position.x, rect.end.x),
			clampf(p.y, rect.position.y, rect.end.y))
		var reserve := minf(radius, 0.80) if raw is Dictionary and raw.get("kind", "") == "nav" else radius
		if nearest.distance_squared_to(p) < reserve * reserve:
			return false
	return true


static func _tree_rect(value: Variant) -> Rect2:
	if value is Rect2:
		return (value as Rect2).abs()
	if value is AABB:
		var box: AABB = value
		return Rect2(Vector2(box.position.x, box.position.z),
			Vector2(box.size.x, box.size.z)).abs()
	if value is Dictionary:
		return _tree_rect((value as Dictionary).get("rect", []))
	if value is Array and (value as Array).size() >= 4:
		var a: Array = value
		var x0 := minf(float(a[0]), float(a[1]))
		var z0 := minf(float(a[2]), float(a[3]))
		return Rect2(Vector2(x0, z0),
			Vector2(absf(float(a[1]) - float(a[0])), absf(float(a[3]) - float(a[2]))))
	return Rect2()


## Единый набор недоступных пятен: дома, хозяйственные постройки, огород,
## поленница, ограды и сюжетные/навигационные проходы. Динамические дома
## первой/второй линий добавляются из тех же data-файлов, что строят мир.
static func tree_footprints() -> Array:
	var out: Array = RuralDressing.placement_registry()
	out.append_array(EnvironmentLandscape.route_footprints())
	out.append_array([
		Rect2(-5.72, 6.48, 10.24, 9.84),       # дом Вити
		Rect2(-9.05, 0.45, 3.40, 3.80),        # сарай-погреб
		Rect2(-8.60, 18.00, 3.20, 6.00),       # теплица
		Rect2(2.75, 21.15, 4.50, 5.50),        # баня
		Rect2(1.62, 22.90, 0.96, 2.70),        # поленница
		Rect2(-4.20, 17.40, 7.20, 10.50),      # огород
		Rect2(-9.65, 0.00, 0.30, 30.20),       # ограды участка
		Rect2(10.35, 0.00, 0.30, 30.20),
		Rect2(-9.65, 29.85, 20.30, 0.30),
		Rect2(2.20, -0.20, 1.80, 5.40),        # вход и дорожки участка
		Rect2(-3.75, 2.75, 7.65, 2.55),
		Rect2(6.30, 4.15, 1.00, 5.90),
		Rect2(8.75, 4.15, 0.90, 15.95),
		Rect2(4.55, 19.20, 5.10, 0.90),
		Rect2(4.55, 20.00, 0.90, 1.20),
		Rect2(-46.0, -6.80, 92.0, 6.55),       # улица и маршруты соседей
	])
	return out


# Общий low-poly лес: один мировой MultiMesh на шестигранные стволы и один на
# два конических яруса. Строители только складывают строки; WorldBuilder
# вызывает flush один раз перед material buckets. Поэтому число draw calls не
# зависит ни от количества деревьев, ни от количества опушек.
# `kind = orchard` сохраняет более низкую широкую крону яблонь.
static func add_low_poly_trees(b: WorldBuilder, id: String, trees: Array,
		trunk_mat := "log", foliage_mat := "conifer") -> Array:
	var local_index := 0
	var accepted: Array = []
	var footprints := tree_footprints()
	for tree: Variant in trees:
		if not (tree is Dictionary):
			continue
		var row := (tree as Dictionary).duplicate()
		row["source"] = id
		row["trunk_mat"] = trunk_mat
		row["foliage_mat"] = foliage_mat
		# A coprime stride keeps neighbouring silhouettes distinct. Yaw and lean
		# are also deterministic; no visible group receives an identical triple.
		var seed := absi(id.hash()) + local_index * 19
		row["variant"] = int(row.get("variant", (seed + local_index * 3) % 7))
		row["yaw"] = float(row.get("yaw", fmod(float(seed * 37), 360.0) * PI / 180.0))
		row["lean"] = float(row.get("lean", (-0.055 + 0.022 * float(seed % 6))))
		row["tree_index"] = int(row.get("tree_index", local_index))
		var canopy := float(row.get("w", 0.8)) * 1.15 + 0.45
		var resolved: Variant = Vector2(float(row.get("x", 0.0)), float(row.get("z", 0.0))) if row.get("placement_resolved", false) else resolve_tree_position("%s:%d" % [id, local_index],
			Vector2(float(row.get("x", 0.0)), float(row.get("z", 0.0))),
			canopy, TREE_BOUNDS, footprints)
		if not (resolved is Vector2):
			local_index += 1
			continue
		row["x"] = (resolved as Vector2).x
		row["z"] = (resolved as Vector2).y
		b.low_poly_tree_rows.append(row)
		accepted.append(row)
		local_index += 1
	return accepted


static func _canopy_hits_house(x: float, z: float, radius: float,
		footprints: Array[Rect2]) -> bool:
	for footprint: Rect2 in footprints:
		if footprint.grow(radius).has_point(Vector2(x, z)):
			return true
	return false


static func _append_footprint(out: Array, xr: Variant, zr: Variant) -> void:
	if xr is Array and zr is Array and (xr as Array).size() == 2 \
			and (zr as Array).size() == 2:
		out.append(Rect2(Vector2(float(xr[0]), float(zr[0])),
			Vector2(float(xr[1]) - float(xr[0]), float(zr[1]) - float(zr[0]))))


static func _collect_box_footprints(value: Variant, out: Array) -> void:
	if value is Dictionary:
		var d: Dictionary = value
		var box: Variant = d.get("box", null)
		if box is Array and (box as Array).size() == 4:
			out.append(Rect2(Vector2(float(box[0]), float(box[2])),
				Vector2(float(box[1]) - float(box[0]), float(box[3]) - float(box[2]))))
		for child: Variant in d.values():
			if child is Dictionary or child is Array:
				_collect_box_footprints(child, out)
	elif value is Array:
		for child: Variant in value:
			if child is Dictionary or child is Array:
				_collect_box_footprints(child, out)


static func flush_low_poly_trees(b: WorldBuilder) -> void:
	if b.low_poly_tree_rows.is_empty():
		return
	# Дисковый кэш даёт 7 лесных и 3 яблоневых варианта. WorldBuilder._finish()
	# объединяет их по четырём материалам и режет на прежние пространственные
	# группы; новые корни и ветви остаются декоративными.
	var parts: Array = []
	var low_parts: Array = []
	for variant in 7:
		parts.append(_tree_parts(variant, false))
		low_parts.append(ProceduralAssets.fetch("forest/tree",{"variant":variant})["lod_meshes"])
	var orchard_parts: Array = []
	var orchard_low_parts: Array = []
	for variant in 3:
		orchard_parts.append(_tree_parts(variant, true))
		orchard_low_parts.append(ProceduralAssets.fetch("forest/orchard",{"variant":variant})["lod_meshes"])
	for family: String in ["bark", "birch", "leaf", "pine"]:
		b.mats.map["proc-" + family] = ProceduralAssets.material(family)
	var orchard_count := 0
	for row: Dictionary in b.low_poly_tree_rows:
		var orchard := String(row.get("kind", "conifer")) == "orchard"
		if orchard:
			orchard_count += 1
		var h := float(row.get("h", 4.0))
		var w := float(row.get("w", 0.8))
		var variant := int(row.get("variant", 0)) % (3 if orchard else 7)
		var basis := Basis(Vector3.UP, float(row.get("yaw", 0.0)))
		basis = basis * Basis(Vector3.FORWARD, float(row.get("lean", 0.0)))
		basis = basis.scaled(Vector3(w, h, w))
		var xf := Transform3D(basis, Vector3(
			float(row.get("x", 0.0)), 0.0, float(row.get("z", 0.0))))
		var pair: Array = orchard_parts[variant] if orchard else parts[variant]
		var low_pair: Array = orchard_low_parts[variant] if orchard else low_parts[variant]
		var skin_tree := b.skin_tree_begin(row, xf)
		var bark := "bark" if orchard or variant < 2 or variant >= 5 else "birch"
		var foliage := "pine" if not orchard and variant < 2 else "leaf"
		var background: ArrayMesh = low_pair[0] if not orchard and variant >= 5 else _background_trunk(low_pair[0])
		b.append_tree_mesh("visual:proc-" + bark, pair[0], low_pair[0], xf, skin_tree["key"],background)
		if (pair[1] as ArrayMesh).get_surface_count() > 0:
			b.append_tree_mesh("visual:proc-" + foliage, pair[1], low_pair[1], xf, skin_tree["key"])
		b.skin_end(skin_tree)
	var marker := Node3D.new()
	marker.name = "low-poly-trees:bucketed"
	marker.set_meta("bucketed", true)
	marker.set_meta("tree_count", b.low_poly_tree_rows.size())
	marker.set_meta("instances", b.low_poly_tree_rows.duplicate(true))
	marker.set_meta("orchard_count", orchard_count)
	marker.set_meta("silhouette_variants", 7)
	marker.set_meta("orchard_variants", 3)
	marker.set_meta("radial_segments", 6)
	marker.set_meta("tiers", 4)
	marker.set_meta("real_branches", true)
	marker.set_meta("house_canopy_clearance", true)
	var scary_count := 0
	for row: Dictionary in b.low_poly_tree_rows:
		if row.get("source","") == "scary-six": scary_count += 1
	marker.set_meta("scary_tree_count", scary_count)
	marker.set_meta("casts_shadow", false)
	b.decor["trees:bucketed"] = marker
	b.low_poly_tree_rows.clear()

## За35м оставляем настоящие два участка ствола; крона и сухие ветви прежние.
## Это первые24треугольника baked low, без новой формы или перестановки вершин.
static var _background_trunks: Dictionary = {}
static func _background_trunk(source: ArrayMesh) -> ArrayMesh:
	var id := source.get_instance_id()
	if _background_trunks.has(id): return _background_trunks[id]
	var original := source.surface_get_arrays(0)
	var indexes: PackedInt32Array = original[Mesh.ARRAY_INDEX] if original[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	for channel in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL,Mesh.ARRAY_TEX_UV]:
		var selected: Variant = original[channel].duplicate()
		selected.resize(72)
		for index in 72:
			selected[index]=original[channel][indexes[index] if not indexes.is_empty() else index]
		arrays[channel]=selected
	var result := ArrayMesh.new()
	result.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	_background_trunks[id]=result
	return result


static func _tree_parts(variant: int, orchard: bool) -> Array:
	var key := "forest/orchard" if orchard else "forest/tree"
	var asset := ProceduralAssets.fetch(key, {"variant": variant})
	return asset.get("meshes", [ArrayMesh.new(), ArrayMesh.new()])


static func _add_limb(st: SurfaceTool, start: Vector3, finish: Vector3, radius: float) -> void:
	var delta := finish - start
	var limb := CylinderMesh.new()
	limb.top_radius = radius * 0.72
	limb.bottom_radius = radius
	limb.height = delta.length()
	limb.radial_segments = 6
	limb.rings = 1
	limb.cap_top = false
	limb.cap_bottom = false
	var basis := Basis().looking_at(delta.normalized(), Vector3.FORWARD).rotated(Vector3.RIGHT, PI * 0.5)
	# CylinderMesh grows along local Y; align it directly to the segment.
	basis.y = delta.normalized()
	basis.x = basis.y.cross(Vector3.FORWARD).normalized() if absf(basis.y.dot(Vector3.FORWARD)) < 0.95 \
		else basis.y.cross(Vector3.RIGHT).normalized()
	basis.z = basis.x.cross(basis.y).normalized()
	st.append_from(limb, 0, Transform3D(basis, (start + finish) * 0.5))


# ----------------------------------------------------------------- дома ----

# Дом без интерьера: коробка, двускатный силуэт крыши и южный фасад с проёмами.
# За фасадом — ниша глубиной NICHE: в ней стоит наблюдатель и в ней же светится
# панель тёплого окна. Без ниши фигура за стеклом упиралась бы носом в глухой
# объём в шестнадцати сантиметрах от рамы.
static func _house(b: WorldBuilder, h: Dictionary, out: Dictionary) -> void:
	var id := String(h.get("id", "house"))
	var skin_house := b.skin_begin("buildings", "street", String(h.get("id", "")), "HOUSES")
	var xr: Array = h["x"]
	var zr: Array = h["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var zn := float(zr[0])          # север, дальняя от дороги
	var zs := float(zr[1])          # юг, фасад
	var hh := float(h.get("h", 3.2))
	var ridge := float(h.get("ridge", 1.2))
	var wall_mat := String(h.get("wallMaterial", "neighbour"))
	var roof_mat := String(h.get("roofMaterial", "neighbourroof"))
	var trim_mat := String(h.get("trimMaterial", "trim"))

	# Твёрдый объём — один на дом, на весь след. Ниша не сквозная: внутрь дома
	# всё равно не войти, и обходить её коллизией нечем.
	#
	# ФАЗА 12: у дома с флагом hollow объёма и ниши здесь нет вовсе — его стены,
	# пол и потолок строит village_world._boarded(), потому что у него появился
	# интерьер. Снаружи при этом ничего не меняется: фасад с проёмами, крыша,
	# забор и крыльцо ниже по функции остаются на месте.
	var zb := zs - NICHE
	if not bool(h.get("hollow", false)):
		_solid(b, x0, x1, 0.0, hh, zn, zs)
		b.box(x0, x1, 0.0, hh, zn, zb, wall_mat, 3.0, false)
		b.box(x0, x0 + WALL_T, 0.0, hh, zb, zs, wall_mat, 2.0, false)
		b.box(x1 - WALL_T, x1, 0.0, hh, zb, zs, wall_mat, 2.0, false)
		b.box(x0, x1, hh - WALL_T, hh, zb, zs, wall_mat, 2.0, false)

	# Южный фасад с проёмами.
	var holes: Array = []
	for w: Dictionary in h.get("windows", []):
		var wx: Array = w["x"]
		var wy: Array = w["y"]
		holes.append({"a": float(wx[0]), "b": float(wx[1]),
			"y0": float(wy[0]), "y1": float(wy[1]), "w": w})
	var door: Array = h.get("door", [])
	if door.size() == 2:
		holes.append({"a": float(door[0]), "b": float(door[1]),
			"y0": 0.0, "y1": 2.05, "w": null})
	holes.sort_custom(func(p: Dictionary, q: Dictionary) -> bool:
		return float(p["a"]) < float(q["a"]))

	var cursor := x0
	for hole: Dictionary in holes:
		var a: float = hole["a"]
		var c: float = hole["b"]
		_facade(b, cursor, a, 0.0, hh, zs, wall_mat)
		_facade(b, a, c, float(hole["y1"]), hh, zs, wall_mat)
		if float(hole["y0"]) > 0.01:
			_facade(b, a, c, 0.0, float(hole["y0"]), zs, wall_mat)
		cursor = c
		_frame(b, a, c, float(hole["y0"]), float(hole["y1"]), zs, trim_mat)
		var w: Variant = hole["w"]
		if w is Dictionary:
			_window(b, id, a, c, float(hole["y0"]), float(hole["y1"]), zs, zb, w, out)
		elif not bool(h.get("doorOpen", false)):
			# Дверное полотно: тёмная доска в проёме, открывать её нечем.
			# doorOpen — фаза 12: у заколоченного дома доски с двери отодраны
			# изнутри, и полотна в проёме нет вовсе.
			b.box(a + 0.04, c - 0.04, 0.02, float(hole["y1"]) - 0.04,
				zs - WALL_T - 0.03, zs - WALL_T + 0.02, "dark", 1.0, false)
	_facade(b, cursor, x1, 0.0, hh, zs, wall_mat)

	# Двускатная крыша со свесами — как у соседских силуэтов прототипа.
	var zm := (zn + zs) * 0.5
	b._slope(x0 - 0.35, x1 + 0.35, zn - 0.35, zm, hh, hh + ridge, roof_mat, 0.16, false)
	b._slope(x0 - 0.35, x1 + 0.35, zm, zs + 0.35, hh + ridge, hh, roof_mat, 0.16, false)

	# Лёгкая внешняя оболочка: цоколь, угловые доски, водосток и труба.
	# Все детали попадают в существующие material buckets и не получают коллизий.
	b.box(x0 - 0.04, x1 + 0.04, 0.0, 0.28, zs - 0.05, zs + 0.05,
		"plinth", 1.2, false)
	for sx: float in [x0, x1]:
		b.box(sx - 0.055, sx + 0.055, 0.25, hh, zs - 0.04, zs + 0.055,
			trim_mat, 1.0, false)
	b.box(x0 - 0.22, x1 + 0.22, hh - 0.08, hh + 0.02, zs + 0.25, zs + 0.34,
		"metal", 0.0, false)
	b.box(x1 - 0.13, x1 - 0.04, 0.18, hh, zs + 0.25, zs + 0.34,
		"metal", 0.0, false)
	b.box(x0 + 0.48, x0 + 0.82, hh, hh + ridge + 0.65, zm - 0.24, zm + 0.24,
		"brick", 1.1, false)

	if bool(h.get("porch", false)) and door.size() == 2:
		var dc := (float(door[0]) + float(door[1])) * 0.5
		b.box(dc - 0.85, dc + 0.85, 0.0, 0.18, zs, zs + 0.95, "boards", 1.0, false)
		b.box(dc - 0.9, dc + 0.9, 2.15, 2.28, zs - 0.1, zs + 1.05, roof_mat, 1.0, false)

	b.skin_end(skin_house)
	_fence(b, h)
	(out["houses"] as Dictionary)[id] = {
		"x": [x0, x1], "z": [zn, zs], "h": hh, "niche": zb,
	}


static func _facade(b: WorldBuilder, a: float, c: float, y0: float, y1: float,
		zs: float, material := "neighbour") -> void:
	if c - a < 0.002 or y1 - y0 < 0.002:
		return
	b.box(a, c, y0, y1, zs - WALL_T, zs, material, 2.0, false)


# Обналичка проёма. Тонкая тёмная рамка: без неё окно читается дырой в коробке.
static func _frame(b: WorldBuilder, a: float, c: float, y0: float, y1: float,
		zs: float, material := "dark") -> void:
	var t := 0.06
	b.box(a - t, a, y0, y1 + t, zs - WALL_T - 0.02, zs + 0.02, material, 1.0, false)
	b.box(c, c + t, y0, y1 + t, zs - WALL_T - 0.02, zs + 0.02, material, 1.0, false)
	b.box(a - t, c + t, y1, y1 + t, zs - WALL_T - 0.02, zs + 0.02, material, 1.0, false)
	if y0 > 0.01:
		b.box(a - t, c + t, y0 - t, y0, zs - WALL_T - 0.02, zs + 0.02, material, 1.0, false)


# Окно. Тёмное — стекло в общей прозрачной куче участка. Горящее — стекло плюс
# панель свечения в глубине ниши: свет идёт ИЗ комнаты, а не лежит на раме,
# и фигура за стеклом получается силуэтом на светлом, как и должна.
static func _window(b: WorldBuilder, house: String, a: float, c: float,
		y0: float, y1: float, zs: float, zb: float, w: Dictionary,
		out: Dictionary) -> void:
	var cx := (a + c) * 0.5
	var cy := (y0 + y1) * 0.5
	b.plane(c - a, y1 - y0, "glass", Vector3(cx, cy, zs - WALL_T * 0.5), 0.0, 0.0, 2, 2)
	# Переплёт.
	b.box(a, c, cy - 0.018, cy + 0.018, zs - WALL_T * 0.5 - 0.02,
		zs - WALL_T * 0.5 + 0.02, "dark", 1.0, false)

	if bool(w.get("boards", false)):
		# Заколочено крест-накрест. Две доски поверх рамы.
		# Ключ decor'а включает координату окна: без неё два заколоченных окна
		# одного дома дают одинаковые ключи, второе затирает первое в словаре,
		# и первое остаётся вне дерева — Godot ругается утечкой на выходе.
		for s: float in [-1.0, 1.0]:
			var tag := "%s-%d-%d" % [house, int(roundf(cx * 10.0)), int(s)]
			var mid := MeshInstance3D.new()
			mid.name = "boards-" + tag
			var bm := BoxMesh.new()
			bm.size = Vector3(sqrt((c - a) * (c - a) + (y1 - y0) * (y1 - y0)) + 0.2, 0.11, 0.04)
			bm.material = b.mats.get_mat("boards")
			mid.mesh = bm
			mid.position = Vector3(cx, cy, zs + 0.03)
			mid.rotation = Vector3(0.0, 0.0, s * atan2(y1 - y0, c - a))
			mid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			b.decor["street-boards-" + tag] = mid
		return

	if not bool(w.get("lit", false)):
		return

	# Панель свечения. Своя нода: мировые сетки строителя держат материалы
	# по ключу палитры, а самосветящегося ключа в ней нет — и не надо, окон
	# всего два.
	var glow := MeshInstance3D.new()
	glow.name = "street-win-" + house
	var q := QuadMesh.new()
	q.size = Vector2((c - a) + 1.1, (y1 - y0) + 0.9)
	glow.mesh = q
	glow.material_override = b.mats.glow(int(w.get("color", 0xffd7a0)))
	glow.position = Vector3(cx, cy - 0.05, zb + 0.04)
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b.decor["street-win-" + house] = glow
	(out["windows"] as Dictionary)[house] = glow


# Штакетник вдоль дороги. Силуэт и без коллизии: перелезть через него всё равно
# некуда — за ним стоит твёрдый объём дома.
#
# ФАЗА 13, «забор местами проходит ровно через дверь дома». Жалоба точная,
# и баг был из двух половин:
#
#   1. Штакетины проём честно пропускали, а ДВЕ ПРОЖИЛИНЫ ниже клались одной
#      коробкой на весь пролёт x0..x1 и ни про какой gap не знали. Через дверь
#      шли именно они — две горизонтальные доски на высоте 0.35 и 1.15.
#   2. У домов с крыльцом (arkady, shouter) настил занимает z [-7.00, -6.05],
#      а забор стоит на FENCE_Z = -6.80, то есть ВНУТРИ настила. Проём в
#      ±0.35 от двери уже настила (±0.85) — и края крыльца упирались
#      в штакетник.
#
# FENCE_Z не двигаем: сдвиг на юг завёл бы забор в кольцо Аркадия
# (ROUTE, z [-6.2,-0.3]), а это уже сосед, идущий сквозь собственный забор.
# Вместо этого прожилины режутся по проёму, а сам проём у домов с крыльцом
# расширяется до ±0.95 — настил проходит в него целиком.
static func _fence(b: WorldBuilder, h: Dictionary) -> void:
	var f: Array = h.get("fence", [])
	if f.size() != 2:
		return
	var x0 := float(f[0])
	var x1 := float(f[1])
	var door: Array = h.get("door", [])
	var gap0 := 0.0
	var gap1 := -1.0
	if door.size() == 2:
		# Настил крыльца — это ±0.85 от середины двери (см. _house), плюс
		# десять сантиметров запаса, чтобы штакетина не стояла впритык к доске.
		var pad := 0.95 if bool(h.get("porch", false)) else 0.35
		gap0 = float(door[0]) - pad
		gap1 = float(door[1]) + pad
	var n := maxi(2, int((x1 - x0) / 0.22))
	for i in n + 1:
		var x := x0 + (x1 - x0) * float(i) / float(n)
		if x > gap0 and x < gap1:
			continue
		b.box(x - 0.035, x + 0.035, 0.0, FENCE_H, FENCE_Z - 0.03, FENCE_Z + 0.03,
			"silhouette", 1.0, false)
	for y: float in [0.35, FENCE_H - 0.2]:
		if gap1 <= gap0:
			b.box(x0, x1, y, y + 0.06, FENCE_Z - 0.02, FENCE_Z + 0.02,
				"silhouette", 3.0, false)
			continue
		b.box(x0, minf(gap0, x1), y, y + 0.06, FENCE_Z - 0.02, FENCE_Z + 0.02,
			"silhouette", 3.0, false)
		b.box(maxf(gap1, x0), x1, y, y + 0.06, FENCE_Z - 0.02, FENCE_Z + 0.02,
			"silhouette", 3.0, false)


# ------------------------------------------------------------- правление ----

# Само здание стоит в site.json (кирпич, проём в южной стене). Здесь только
# створка на замок: коробка в SET_OVERLAY с именем, полотно отдельной нодой.
static func _office(b: WorldBuilder, o: Dictionary, out: Dictionary) -> void:
	if o.is_empty():
		return
	var d: Dictionary = o.get("door", {})
	if d.is_empty():
		return
	var id := String(d.get("id", "door-office"))
	var x := float(d.get("x", -30.0))
	var z := float(d.get("z", -7.5))
	var w := float(d.get("w", 1.0))
	var hh := float(d.get("h", 2.1))
	var t := float(d.get("t", 0.06))

	b.col.add_box_d(CollisionWorld.SET_OVERLAY,
		x - w / 2.0, 0.0, z - t, x + w / 2.0, hh, z + t, id)

	var leaf := Node3D.new()
	leaf.name = id
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(w - 0.04, hh - 0.04, t * 1.6)
	bm.material = b.mats.get_mat("shedwood")
	mi.mesh = bm
	mi.position = Vector3(w / 2.0 - 0.02, hh / 2.0, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	leaf.add_child(mi)
	# Амбарный замок на пробое — то, за чем игрока и посылают в сарай.
	var lock := MeshInstance3D.new()
	var lm := BoxMesh.new()
	lm.size = Vector3(0.10, 0.13, 0.05)
	lm.material = b.mats.flat(0x7d8288, true)
	lock.mesh = lm
	lock.name = "lock"
	lock.position = Vector3(w - 0.14, hh * 0.52, -t)
	lock.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	leaf.add_child(lock)
	# Петля в начале полотна: створка открывается поворотом группы.
	leaf.position = Vector3(x - w / 2.0, 0.0, z)
	b.decor[id] = leaf
	(out["nodes"] as Dictionary)[id] = leaf
	(out["nodes"] as Dictionary)["office-lock"] = lock

	var skin_porch := b.skin_begin("buildings", "street", "", "OFFICE-porch")
	_office_porch(b, x, z, w, hh, out)
	b.skin_end(skin_porch)

	var cn: Array = o.get("canister", [])
	if cn.size() == 3:
		(out["nodes"] as Dictionary)["canister"] = _canister(b,
			Vector3(float(cn[0]), float(cn[1]), float(cn[2])), "canister")
	var lg: Array = o.get("log", [])
	if lg.size() == 3:
		(out["nodes"] as Dictionary)["duty-log"] = _paper(b,
			Vector3(float(lg[0]), float(lg[1]), float(lg[2])), "duty-log", 0.26, 0.34)


# Крыльцо правления (фаза 11). Дверь читалась глухой стеной, и это не вкусовщина,
# а сумма мелочей: тёмное полотно shedwood заподлицо в кирпиче, наличник
# материалом 'dark' (то есть ещё темнее), лампа 'office' внутри и выключена,
# порог 16 см без ступеньки, а подходит игрок с тридцати одного метра при
# тумане 32. Единственным маркером был замок 10x13 см.
#
# Лечится тем же, чем на любом настоящем правлении: две ступени, площадка,
# белый наличник, козырёк, светлая табличка и лампа над входом. Всё
# collide = false — кирпичная стена и порог уже стоят в паритетной статике.
static func _office_porch(b: WorldBuilder, x: float, z: float, w: float,
		hh: float, out: Dictionary) -> void:
	var d0 := x - w / 2.0
	var d1 := x + w / 2.0
	var face := z + 0.10          # наружная плоскость южной стены (t = 0.2)

	# Две ступени по 8 см: земля 0 -> 0.08 -> площадка 0.16, вровень с полом.
	b.box(d0 - 0.90, d1 + 0.90, 0.0, 0.08, face + 0.50, face + 0.92, "concrete", 1.2, false)
	b.box(d0 - 1.05, d1 + 1.05, 0.0, 0.16, face - 0.02, face + 0.52, "concrete", 1.2, false)

	# Белый наличник ПОВЕРХ тёмного: он глубже и шире, тёмная коробка целиком
	# оказывается внутри белой, и совпавших плоскостей не остаётся.
	var dp := 0.10 + 0.012 + 0.045
	b.box(d0 - 0.09, d0 + 0.008, 0.16, hh, z - dp, z + dp, "trim", 0.0, false)
	b.box(d1 - 0.008, d1 + 0.09, 0.16, hh, z - dp, z + dp, "trim", 0.0, false)
	b.box(d0 - 0.09, d1 + 0.09, hh, hh + 0.10, z - dp, z + dp, "trim", 0.0, false)

	# Табличка над проёмом. Что на ней написано, с тридцати метров не разобрать,
	# и не надо: важно, что над дверью что-то светлое висит.
	b.box(d0 - 0.34, d1 + 0.34, hh + 0.14, hh + 0.42, face - 0.01, face + 0.04,
		"trim", 1.0, false)

	# Козырёк с уклоном на юг и два кронштейна.
	b._slope(d0 - 0.75, d1 + 0.75, face - 0.05, face + 0.85, hh + 0.62, hh + 0.44,
		"roof", 0.10, false)
	# Кронштейны короткие и вжаты к стене: на полную глубину свеса они читались
	# двумя досками, торчащими из кирпича, а не подпорками.
	for s: float in [-0.60, 0.60]:
		b.box(x + s - 0.03, x + s + 0.03, hh + 0.34, hh + 0.62,
			face + 0.02, face + 0.40, "boards", 0.0, false)

	# Светильник над входом. Здесь только железо: кронштейн и отражатель.
	# Сама лампа заведена в lights.gd (`office-porch`) и горит с начала игры —
	# в этом и есть починка «дверь читается глухой стеной». Колбу рисует пул
	# ламп своим MultiMesh, поэтому второй самосветящейся сферы тут нет:
	# две колбы в одной точке дают тусклое двойное пятно, а не яркое одно.
	var lx := d1 + 0.55           # сбоку от проёма: над дверью уже табличка
	b.box(lx - 0.05, lx + 0.05, hh + 0.16, hh + 0.28, face + 0.02, face + 0.24,
		"metal", 1.0, false)
	var shade := MeshInstance3D.new()
	shade.name = "office-lamp-shade"
	var cm := CylinderMesh.new()
	cm.top_radius = 0.03
	cm.bottom_radius = 0.14
	cm.height = 0.11
	cm.radial_segments = 7
	cm.rings = 1
	cm.cap_bottom = false
	cm.material = b.mats.get_mat("metal")
	shade.mesh = cm
	shade.position = Vector3(lx, hh + 0.18, face + 0.20)
	shade.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b.decor["street-office-lamp"] = shade
	(out["nodes"] as Dictionary)["office-lamp"] = shade


# ------------------------------------------------------------- предметы ----

# Мелочь квеста строится примитивами прямо здесь: data/props.json принадлежит
# фазе 8 и не трогается, а класть три коробки ради корзины в чужой файл —
# это ещё один владелец у 83 коллайдеров паритета.
static func _objects(b: WorldBuilder, o: Dictionary, out: Dictionary) -> void:
	var nodes: Dictionary = out["nodes"]
	var at: Array = o.get("basket", [])
	if at.size() == 3:
		nodes["basket"] = _basket(b, Vector3(float(at[0]), float(at[1]), float(at[2])))
	at = o.get("note", [])
	if at.size() == 3:
		nodes["apple-note"] = _paper(b, Vector3(float(at[0]), float(at[1]), float(at[2])),
			"apple-note", 0.19, 0.25)
	at = o.get("bin", [])
	if at.size() == 3:
		nodes["bin"] = _bin(b, Vector3(float(at[0]), float(at[1]), float(at[2])))
	at = o.get("barrel", [])
	if at.size() == 3:
		nodes["fuel-barrel"] = _barrel(b, Vector3(float(at[0]), float(at[1]), float(at[2])))
	at = o.get("officeKey", [])
	if at.size() == 3:
		nodes["office-key"] = _key(b, Vector3(float(at[0]), float(at[1]), float(at[2])))


static func _holder(b: WorldBuilder, name: String, pos: Vector3) -> Node3D:
	var n := Node3D.new()
	n.name = "street-" + name
	n.position = pos
	b.decor["street-" + name] = n
	return n


static func _piece(parent: Node3D, mesh: Mesh, at: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _box_mesh(b: WorldBuilder, size: Vector3, key: String, exact_hex := -1) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	m.material = b.mats.flat(exact_hex, true) if exact_hex >= 0 else b.mats.get_mat(key)
	return m


static func _basket(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "basket", pos)
	_piece(n, _box_mesh(b, Vector3(0.40, 0.30, 0.40), "", 0x8a6a45), Vector3(0, 0.15, 0))
	_piece(n, _box_mesh(b, Vector3(0.44, 0.05, 0.44), "", 0x6d4c31), Vector3(0, 0.31, 0))
	# Яблоки горкой: восемь коробочек по кругу, чтобы горка не читалась решёткой.
	for i in 8:
		var a := float(i) * TAU / 8.0
		_piece(n, _box_mesh(b, Vector3(0.09, 0.09, 0.09), "", 0x54703f),
			Vector3(cos(a) * 0.11, 0.34 + 0.03 * sin(a * 2.0), sin(a) * 0.11),
			Vector3(0.0, a, 0.0))
	return n


static func _paper(b: WorldBuilder, pos: Vector3, name: String, w: float, l: float) -> Node3D:
	var n := _holder(b, name, pos)
	_piece(n, _box_mesh(b, Vector3(w, 0.006, l), "", 0xc9c3ac), Vector3(0, 0.003, 0),
		Vector3(0.0, 0.14, 0.0))
	return n


static func _bin(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "bin", pos)
	var body := CylinderMesh.new()
	body.top_radius = 0.30
	body.bottom_radius = 0.26
	body.height = 0.72
	body.radial_segments = 8
	body.rings = 1
	body.material = b.mats.flat(0x4e5459, true)
	_piece(n, body, Vector3(0, 0.36, 0))
	return n


static func _barrel(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "fuel-barrel", pos)
	var body := CylinderMesh.new()
	body.top_radius = 0.29
	body.bottom_radius = 0.29
	body.height = 0.86
	body.radial_segments = 9
	body.rings = 1
	body.material = b.mats.flat(0x54703f, true)
	_piece(n, body, Vector3(0, 0.43, 0))
	for y: float in [0.22, 0.64]:
		var ring := CylinderMesh.new()
		ring.top_radius = 0.305
		ring.bottom_radius = 0.305
		ring.height = 0.05
		ring.radial_segments = 9
		ring.rings = 1
		ring.material = b.mats.flat(0x3a3f43, true)
		_piece(n, ring, Vector3(0, y, 0))
	# Бочка стоит и мешает: её коробка идёт в оверлей, а не в реквизит.
	b.col.add_box_d(CollisionWorld.SET_OVERLAY,
		pos.x - 0.30, pos.y, pos.z - 0.30, pos.x + 0.30, pos.y + 0.88, pos.z + 0.30)
	return n


static func _canister(b: WorldBuilder, pos: Vector3, name: String) -> Node3D:
	var n := _holder(b, name, pos)
	_piece(n, _box_mesh(b, Vector3(0.32, 0.42, 0.17), "", 0x54703f), Vector3(0, 0.21, 0))
	_piece(n, _box_mesh(b, Vector3(0.09, 0.07, 0.09), "", 0x3a3f43), Vector3(0.10, 0.45, 0))
	_piece(n, _box_mesh(b, Vector3(0.04, 0.10, 0.14), "", 0x3a3f43), Vector3(-0.10, 0.47, 0))
	return n


static func _key(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "office-key", pos)
	_piece(n, _box_mesh(b, Vector3(0.015, 0.10, 0.015), "", 0x7d8288), Vector3(0, -0.05, 0))
	_piece(n, _box_mesh(b, Vector3(0.05, 0.05, 0.012), "", 0x7d8288), Vector3(0, 0.005, 0))
	_piece(n, _box_mesh(b, Vector3(0.03, 0.024, 0.012), "", 0x7d8288), Vector3(0.02, -0.09, 0))
	# Гвоздь, на котором он висит.
	_piece(n, _box_mesh(b, Vector3(0.012, 0.012, 0.06), "", 0x3a3f43), Vector3(0, 0.03, 0.03))
	return n


# --------------------------------------------------------------- служебное --

## Твёрдая коробка в четвёртый набор. Единственный способ, которым улица
## становится проходимой: SET_STATIC, SET_BLOCKERS и SET_PROPS отсюда не
## трогаются вовсе.
static func _solid(b: WorldBuilder, x0: float, x1: float, y0: float, y1: float,
		z0: float, z1: float, id := "") -> void:
	b.col.add_box_d(CollisionWorld.SET_OVERLAY,
		minf(x0, x1), minf(y0, y1), minf(z0, z1),
		maxf(x0, x1), maxf(y0, y1), maxf(z0, z1), id)


## Свободна ли точка для фигуры ростом 1.72. Спрашивают tests/test_street_route.gd
## и маршрут Аркадия: узел внутри коробки означает соседа, наполовину вросшего
## в собственный забор.
static func is_free(col: CollisionWorld, x: float, z: float, r := 0.34) -> bool:
	if col == null:
		return true
	var mask := CollisionWorld.MASK_STATIC | CollisionWorld.MASK_PROPS \
		| CollisionWorld.MASK_OVERLAY
	# Две проверки, и вторая не для красоты: капсула, утонувшая в сплошном
	# объёме дома целиком, ни одной грани не касается и capsule_hit возвращает
	# пустоту (см. шапку CollisionWorld.point_hit). По одной капсуле «свободно»
	# получалось бы ровно посреди чужой комнаты.
	for y: float in [r + 0.05, 0.95, 1.65]:
		if col.point_hit(x, y, z, mask):
			return false
	return col.capsule_hit_d(x, r + 0.05, z, x, 1.70, z, r, mask).is_empty()

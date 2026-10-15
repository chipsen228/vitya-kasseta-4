# Улица после деревни: полоса деда, кольцо Аркадия, пол и замурованные испуги
# (фаза 12).
#
# ЗАЧЕМ. Машинного стража у улицы не было вовсе. test_yard_nav_clear смотрит
# только на участок, а test_startle_points и test_haunt_points считают видимость
# маской STATIC|PROPS — стен сельпо и заколоченного дома, которые живут
# в четвёртом наборе, они не видят. Фаза 12 удваивает карту, и без этого теста
# три ошибки прошли бы молча:
#
# 1. Коробка в полосе, по которой ходит street_stalk.gd. Нав-графа у улицы нет,
#    и дед идёт по прямой z = -3.2, не спрашивая геометрию: постройка в полосе
#    означает деда, проходящего сквозь стену на глазах у игрока.
# 2. Коробка на кольце Аркадия (data/street.json ROUTE). Сосед ходит той же
#    линейной интерполяцией, и увидеть, что он врос в чужой забор, можно только
#    дойдя до его калитки.
# 3. Точка испуга внутри сельпо или заколоченного дома: фигура появляется
#    за стеной, флаг однократности сгорает, второй попытки не будет.
#
# Плюс пол на новых двадцати трёх метрах — тем же способом, что в
# test_street_floor, но по всей ширине полосы и с учётом четвёртого набора.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_street_clear.gd
extends SceneTree

const R := 0.30                  # радиус капсулы игрока
const FIG_R := 0.34              # радиус фигуры соседа (StreetWorld.is_free)
# Полоса деда. Числа из street_stalk.gd: LANE_Z и LANE_HALF. Своя копия здесь
# однажды разъехалась бы с той, по которой он реально ходит, поэтому берём их
# у самого модуля.
const LANE_MARGIN := 0.35        # запас на ширину фигуры
const ROUTE_MARGIN := 0.45
const SHOW := 8


func _initialize() -> void:
	var errs: Array[String] = []

	VillageWorld._cache = null
	StreetWorld._cache = null
	YardWorld._cache = null
	var w := _build()
	var built: Dictionary = w["built"]
	var village: Dictionary = built.get("village", {})
	if village.is_empty():
		print("test_street_clear: SKIP — нет data/village.json")
		_drop(w)
		quit(0)
		return

	var boxes: Array = village.get("boxes", [])
	if boxes.is_empty():
		errs.append("деревня не отдала ни одной твёрдой коробки — мерить нечего")

	# ---- 1. полоса деда ----
	# Он ходит по прямой z = LANE_Z от WEST_V до EAST_V (глава ДЕРЕВНЯ — самый
	# широкий его отрезок за игру) и геометрии не спрашивает вовсе.
	var z0 := StreetStalk.LANE_Z - StreetStalk.LANE_HALF - LANE_MARGIN
	var z1 := StreetStalk.LANE_Z + StreetStalk.LANE_HALF + LANE_MARGIN
	var lane_bad := 0
	for bx: AABB in boxes:
		if bx.position.z > z1 or bx.position.z + bx.size.z < z0:
			continue
		if bx.position.x > StreetStalk.EAST_V or bx.position.x + bx.size.x < StreetStalk.WEST_V:
			continue
		lane_bad += 1
		if lane_bad <= SHOW:
			errs.append("коробка деревни [%.1f..%.1f, %.1f..%.1f] лезет в полосу деда z [%.2f, %.2f]"
				% [bx.position.x, bx.position.x + bx.size.x,
					bx.position.z, bx.position.z + bx.size.z, z0, z1])
	if lane_bad > SHOW:
		errs.append("…и ещё %d таких коробок" % (lane_bad - SHOW))
	if lane_bad == 0:
		print("полоса деда z [%.2f, %.2f] на x [%.1f, %.1f]: чиста"
			% [z0, z1, StreetStalk.WEST_V, StreetStalk.EAST_V])

	# ---- 2. кольцо Аркадия ----
	var route: Array = (built.get("street", {}) as Dictionary).get("route", {}).get("points", [])
	var col: CollisionWorld = w["col"]
	var ring_bad := 0
	for i in route.size():
		var a: Array = route[i]
		var c: Array = route[(i + 1) % route.size()]
		var p0 := Vector2(float(a[0]), float(a[1]))
		var p1 := Vector2(float(c[0]), float(c[1]))
		var n := maxi(1, int(p0.distance_to(p1) / 0.25))
		for k in n + 1:
			var p := p0.lerp(p1, float(k) / float(n))
			var g := _gap_point(boxes, p.x, p.y)
			if g >= FIG_R + ROUTE_MARGIN:
				continue
			ring_bad += 1
			if ring_bad <= SHOW:
				errs.append("кольцо Аркадия проходит в %.2f м от деревни на [%.1f, %.1f]"
					% [g, p.x, p.y])
	if ring_bad == 0:
		print("кольцо Аркадия: %d узлов, ближе %.2f м к деревне не подходит"
			% [route.size(), FIG_R + ROUTE_MARGIN])

	# ---- 3. пол под всей новой полосой ----
	var mask := CollisionWorld.MASK_STATIC | CollisionWorld.MASK_PROPS \
		| CollisionWorld.MASK_OVERLAY
	var holes := 0
	var checked := 0
	var z := -13.5
	while z <= -0.5 + 1e-6:
		var x := -45.0
		while x <= 45.0 + 1e-6:
			if StreetWorld.is_free(col, x, z, R):
				checked += 1
				var hit := col.ray_down(x, 3.2, z, mask)
				if hit.is_empty() or float(hit["y"]) < -0.8 or float(hit["y"]) > 1.2:
					holes += 1
					if holes <= SHOW:
						errs.append("нет пола под (%.1f, %.1f)" % [x, z])
			x += 1.0
		z += 1.0
	if holes == 0:
		print("пол: %d свободных точек сетки, ни одной дыры" % checked)
	elif holes > SHOW:
		errs.append("…и ещё %d таких точек" % (holes - SHOW))

	# ---- 4. испуги внутри сельпо и заколоченного дома ----
	_walled_in(w, village, errs)

	_drop(w)

	if errs.is_empty():
		print("test_street_clear: PASS")
		quit(0)
		return
	print("FAIL test_street_clear: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# --------------------------------------------------------- замурованность ----

# Та же проверка, что в test_yard_nav_clear, и по той же причине: точка внутри
# постройки четвёртого набора проходит оба теста точек и оказывается за стеной.
func _walled_in(w: Dictionary, village: Dictionary, errs: Array[String]) -> void:
	var col: CollisionWorld = w["col"]
	var mask := CollisionWorld.MASK_STATIC | CollisionWorld.MASK_PROPS \
		| CollisionWorld.MASK_OVERLAY
	var foot: Array = _footprints(village)
	var checked := 0

	for p: Dictionary in Startle.POINTS:
		var at: Array = p.get("at", [])
		var pos: Array = p.get("pos", [])
		if at.size() != 3:
			continue
		var trigger_in := _in_foot(foot, float(at[0]), float(at[2]))
		var fig_in := pos.size() == 3 and _in_foot(foot, float(pos[0]), float(pos[2]))
		if not trigger_in and not fig_in:
			continue
		checked += 1
		if trigger_in and col.point_hit(float(at[0]), float(at[1]) + 0.95,
				float(at[2]), CollisionWorld.MASK_OVERLAY):
			errs.append("испуг «%s»: триггер стоит внутри стены" % String(p.get("id", "?")))
		if pos.size() != 3:
			continue
		if col.point_hit(float(pos[0]), float(pos[1]) + 0.95, float(pos[2]),
				CollisionWorld.MASK_OVERLAY):
			errs.append("испуг «%s»: фигура замурована в стене" % String(p.get("id", "?")))
			continue
		var eye := Vector3(float(at[0]), float(at[1]) + 1.62, float(at[2]))
		var head := Vector3(float(pos[0]), float(pos[1]) + 1.40, float(pos[2]))
		if String(p.get("kind", "")) != "sign" and not _clear(col, eye, head, mask):
			errs.append("испуг «%s» замурован: из триггера фигуру не видно "
				% String(p.get("id", "?")) + "сквозь стену четвёртого набора")

	var haunt := Haunt.new(null, null, col, 1)
	for p: Dictionary in haunt.points:
		var pos: Array = p.get("pos", [])
		if pos.size() != 3 or not _in_foot(foot, float(pos[0]), float(pos[2])):
			continue
		checked += 1
		if col.point_hit(float(pos[0]), float(pos[1]) + 1.40, float(pos[2]),
				CollisionWorld.MASK_OVERLAY):
			errs.append("мелькание «%s»: фигура замурована в стене" % String(p.get("id", "?")))
			continue
		var seen: Array = p.get("seen_from", [])
		if seen.size() != 3:
			errs.append("мелькание «%s» стоит внутри постройки без seen_from — "
				% String(p.get("id", "?")) + "проверить видимость нечем")
			continue
		var from := Vector3(float(seen[0]), float(seen[1]) + 1.62, float(seen[2]))
		var head2 := Vector3(float(pos[0]), float(pos[1]) + 1.58, float(pos[2]))
		if not _clear(col, from, head2, mask):
			errs.append("мелькание «%s» замуровано: из точки обзора его не видно"
				% String(p.get("id", "?")))
	print("точек страха внутри сельпо и заколоченного дома: %d" % checked)


## Габариты интерьеров деревни в плане. Погост и остановка сюда не входят:
## у них нет потолка, и «внутри» для них ничего не значит.
static func _footprints(village: Dictionary) -> Array:
	var out: Array = []
	for key: String in ["shop", "boarded"]:
		var d: Dictionary = village.get(key, {})
		if d.is_empty():
			continue
		var xr: Array = d.get("x", [])
		var zr: Array = d.get("z", [])
		if xr.size() == 2 and zr.size() == 2:
			out.append([float(xr[0]), float(xr[1]), float(zr[0]), float(zr[1])])
	return out


static func _in_foot(foot: Array, x: float, z: float) -> bool:
	for r: Array in foot:
		if x >= r[0] and x <= r[1] and z >= r[2] and z <= r[3]:
			return true
	return false


static func _clear(col: CollisionWorld, a: Vector3, b: Vector3, mask: int) -> bool:
	var d := b - a
	var ln := d.length()
	if ln < 0.001:
		return true
	var n := maxi(2, int(ceil(ln / 0.12)))
	for i in range(1, n):
		var p := a + d * (float(i) / float(n))
		if col.point_hit(p.x, p.y, p.z, mask):
			return false
	return true


## Расстояние в плане от точки до ближайшей коробки. Внутри коробки — ноль.
static func _gap_point(boxes: Array, x: float, z: float) -> float:
	var best := INF
	for bx: AABB in boxes:
		var dx := maxf(maxf(bx.position.x - x, x - (bx.position.x + bx.size.x)), 0.0)
		var dz := maxf(maxf(bx.position.z - z, z - (bx.position.z + bx.size.z)), 0.0)
		best = minf(best, sqrt(dx * dx + dz * dz))
	return best


func _build() -> Dictionary:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)
	return {"col": col, "root": root, "built": built, "props": props}


func _drop(w: Dictionary) -> void:
	(w["props"] as Props).dispose()
	(w["root"] as Node3D).free()

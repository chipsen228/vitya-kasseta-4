# Приёмка пола улицы: под каждой точкой, где может встать игрок, есть пол,
# а по краям стоят борта.
#
# До фазы 9 за воротами было три дыры, и игрок проваливался сквозь мир:
#   z < -14        — севернее обочины;
#   |x| > 46       — за концом грунтовки;
#   z > 0 при x вне [-9.5, 10.5] — сбоку от участка, где земли нет вовсе.
# Ни клампа координат, ни порога по y в player.gd нет и не будет: падение —
# это дырка в геометрии, и чинится она геометрией.
#
# Тест меряет ровно две вещи и обе машинно: сетка 1 м по всей улице (пол есть)
# и полоса по периметру (борт есть и он сплошной). Шаг сэмплов борта меньше
# диаметра капсулы игрока — иначе «сплошной» означало бы «с дырками ровно
# такого размера, чтобы в них пролезть».
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_street_floor.gd
extends SceneTree

const R := 0.30            # радиус капсулы игрока (player.gd RADIUS)
const STEP := 1.0          # шаг сетки пола
const EDGE_STEP := 0.4     # шаг проверки борта, меньше диаметра капсулы
const FLOOR_MASK := CollisionWorld.MASK_STATIC | CollisionWorld.MASK_PROPS \
	| CollisionWorld.MASK_OVERLAY

# Где игрок может оказаться. Границы взяты изнутри бортов на полметра:
# на самой линии борта капсула уже не стоит. Фаза 12 раздвинула улицу
# с ±34 до ±45.6 — сетка обязана ехать за бортами, иначе новые двадцать три
# метра проверяются нулём точек и «пол есть везде» становится «пол есть там,
# где мы посмотрели».
const X0 := -44.7
const X1 := 44.7
# ФАЗА 18. Сетка опущена с -13.5 до -14.6. Полоса z [-14.8, -14.0] не
# сэмплировалась ВООБЩЕ, и ров глубиной 0.32 м вдоль всей первой линии
# (жалоба Петра, пункт пятый) прожил в игре четыре фазы: пол там формально
# был — подложка грунта, — но на 32 см ниже обочины.
const Z0 := -14.6
const Z1 := -0.5

const SHOW := 8


func _initialize() -> void:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	if (built.get("street", {}) as Dictionary).is_empty():
		print("SKIP test_street_floor: нет data/street.json — улицы в сборке нет")
		root.free()
		quit(0)
		return

	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)

	var errs: Array[String] = []
	var holes: Array[String] = []
	var checked := 0
	var skipped := 0

	var z := Z0
	while z <= Z1 + 1e-6:
		var x := X0
		while x <= X1 + 1e-6:
			# Точки внутри дома, машины или бочки игроку недоступны — пол под
			# ними ничего не решает.
			if not StreetWorld.is_free(col, x, z, R):
				skipped += 1
				x += STEP
				continue
			checked += 1
			var hit := col.ray_down(x, 3.0, z, FLOOR_MASK)
			if hit.is_empty():
				holes.append("нет пола под (%.1f, %.1f)" % [x, z])
			elif float(hit["y"]) < -0.8 or float(hit["y"]) > 0.8:
				holes.append("пол под (%.1f, %.1f) на y = %.2f" % [x, z, float(hit["y"])])
			x += STEP
		z += STEP

	if holes.is_empty():
		print("пол: %d точек сетки, ни одной дыры (%d пропущено как занятые)"
			% [checked, skipped])
	else:
		for i in mini(holes.size(), SHOW):
			errs.append(holes[i])
		if holes.size() > SHOW:
			errs.append("...и ещё %d таких точек" % (holes.size() - SHOW))

	# Борта. По каждой линии капсула обязана во что-то упереться — иначе
	# в этом месте улица кончается обрывом.
	# Пробы идут по СРЕДНЕЙ ПЛОСКОСТИ борта, а не рядом с ним: капсула радиусом
	# 0.30 в стенке толщиной 0.40 гарантированно задевает грань, и «сплошной»
	# означает именно сплошной, а не «с дырками ровно под ширину игрока».
	var d := StreetWorld.data()
	var b: Dictionary = d.get("BORDERS", {})
	# ФАЗА 14: северный борт — уже не один сплошной rect, а массив отрезков
	# с двумя проёмами (переулки на околицу). Каждый отрезок обязан быть
	# сплошным сам по себе; дыры между отрезками — это и есть проёмы, их
	# сюда вносить незачем, они не баг.
	var north: Variant = b.get("north", [])
	var north_segs: Array = north if (north is Array and (north as Array).size() > 0
		and (north as Array)[0] is Array) else [north]
	for seg: Array in north_segs:
		if seg.size() != 4:
			continue
		errs.append_array(_edge_x(col, _mid(seg, 2, 3),
			float(seg[0]) + 1.0, float(seg[1]) - 1.0, "северный борт"))
	errs.append_array(_edge_z(col, _mid(b["west"], 0, 1),
		-13.4, -0.2, "западный борт"))
	errs.append_array(_edge_z(col, _mid(b["east"], 0, 1),
		-13.4, -0.2, "восточный борт"))
	for r: Array in b.get("south", []):
		errs.append_array(_edge_x(col, _mid(r, 2, 3),
			float(r[0]) + 0.5, float(r[1]) - 0.5, "южный борт"))

	props.dispose()
	root.free()

	if errs.is_empty():
		print("test_street_floor: PASS")
		quit(0)
		return
	print("FAIL test_street_floor: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


## Линия вдоль x: капсула у самой стенки обязана в неё упираться.
func _edge_x(col: CollisionWorld, z: float, x0: float, x1: float,
		tag: String) -> Array[String]:
	var out: Array[String] = []
	var gaps := 0
	var x := x0
	while x <= x1 + 1e-6:
		if not _blocked(col, x, z):
			gaps += 1
			if gaps <= 3:
				out.append("%s: дыра на x = %.1f" % [tag, x])
		x += EDGE_STEP
	if gaps > 3:
		out.append("%s: всего дыр %d" % [tag, gaps])
	if gaps == 0:
		print("%s: сплошной" % tag)
	return out


## То же вдоль z.
func _edge_z(col: CollisionWorld, x: float, z0: float, z1: float,
		tag: String) -> Array[String]:
	var out: Array[String] = []
	var gaps := 0
	var z := z0
	while z <= z1 + 1e-6:
		if not _blocked(col, x, z):
			gaps += 1
			if gaps <= 3:
				out.append("%s: дыра на z = %.1f" % [tag, z])
		z += EDGE_STEP
	if gaps > 3:
		out.append("%s: всего дыр %d" % [tag, gaps])
	if gaps == 0:
		print("%s: сплошной" % tag)
	return out


func _mid(r: Array, i: int, j: int) -> float:
	return (float(r[i]) + float(r[j])) * 0.5


# Проба точкой, а не капсулой. capsule_hit() к телу, в котором капсула утонула
# целиком, возвращает пустоту (см. CollisionWorld.point_hit), а борт толщиной
# 0.4 при радиусе игрока 0.3 — именно такой случай: обе грани дальше радиуса,
# и «сплошная стена» читалась бы как сплошная дыра.
func _blocked(col: CollisionWorld, x: float, z: float) -> bool:
	var mask := CollisionWorld.MASK_OVERLAY | CollisionWorld.MASK_STATIC
	for y: float in [0.35, 0.95, 1.45]:
		if col.point_hit(x, y, z, mask):
			return true
	return false

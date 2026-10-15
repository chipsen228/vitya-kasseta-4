# Приёмка маршрута Аркадия.
#
# Ходит он по кольцу с линейной интерполяцией, без навграфа и без ИИ: улица
# в nav.json стоит в banRooms, и слоя под неё нет вовсе. Значит, за проходимость
# маршрута отвечает не поиск пути, а этот тест — узел внутри коробки даёт
# соседа, наполовину вросшего в собственный забор, и увидеть это можно только
# глазами, дойдя до его калитки.
#
# Проверяется: кольцо замкнуто, точек хватает, каждый узел и каждая точка
# отрезка свободны для фигуры, и весь маршрут лежит в пределах улицы.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_street_route.gd
extends SceneTree

const R := 0.34            # радиус фигуры деда/соседа (ai.gd R = 0.32 плюс запас)
const SAMPLE := 0.5        # шаг проверки вдоль отрезка
const MIN_POINTS := 5
const SHOW := 8

# Пределы улицы: за ними стоят борта.
const X0 := -33.6
const X1 := 33.6
const Z0 := -13.6
const Z1 := -0.3


func _initialize() -> void:
	var d := StreetWorld.data()
	if d.is_empty():
		print("SKIP test_street_route: нет data/street.json")
		quit(0)
		return

	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	WorldBuilder.build(root, mats, col)
	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)

	var errs: Array[String] = []
	var route: Dictionary = d.get("ROUTE", {})
	var pts: Array = route.get("points", [])

	if pts.size() < MIN_POINTS:
		errs.append("в кольце %d точек — на маршрут не хватает" % pts.size())

	# Кольцо замкнуто по определению: последняя точка соединяется с первой.
	# Дублировать первую точку в конце нельзя — на ней фигура встанет намертво.
	if pts.size() >= 2:
		var a: Array = pts[0]
		var b: Array = pts[pts.size() - 1]
		if absf(float(a[0]) - float(b[0])) < 0.01 and absf(float(a[1]) - float(b[1])) < 0.01:
			errs.append("последняя точка совпадает с первой — кольцо и так "
				+ "замыкается, дубль даст остановку на месте")

	var bad: Array[String] = []
	for i in pts.size():
		var p: Array = pts[i]
		var x := float(p[0])
		var z := float(p[1])
		if x < X0 or x > X1 or z < Z0 or z > Z1:
			bad.append("узел %d (%.1f, %.1f) за пределами улицы" % [i, x, z])
			continue
		if not StreetWorld.is_free(col, x, z, R):
			bad.append("узел %d (%.1f, %.1f) внутри коробки" % [i, x, z])
		var hit := col.ray_down(x, 3.0, z,
			CollisionWorld.MASK_STATIC | CollisionWorld.MASK_OVERLAY)
		if hit.is_empty() or absf(float(hit["y"])) > 0.6:
			bad.append("узел %d (%.1f, %.1f): под ногами не земля" % [i, x, z])

	# Отрезки. Кольцо, поэтому последний идёт обратно в первую точку.
	for i in pts.size():
		var a: Array = pts[i]
		var b: Array = pts[(i + 1) % pts.size()]
		var ax := float(a[0])
		var az := float(a[1])
		var dx := float(b[0]) - ax
		var dz := float(b[1]) - az
		var ln := sqrt(dx * dx + dz * dz)
		if ln < 0.5:
			bad.append("отрезок %d короче полуметра — фигура встанет" % i)
			continue
		var n := maxi(1, int(ln / SAMPLE))
		for k in range(1, n):
			var q := float(k) / float(n)
			var x := ax + dx * q
			var z := az + dz * q
			if not StreetWorld.is_free(col, x, z, R):
				bad.append("отрезок %d упирается в коробку на (%.1f, %.1f)" % [i, x, z])
				break

	# Точка «дома» — с неё он выходит и на неё возвращается.
	var home: Array = route.get("home", [])
	if home.size() == 2 and not StreetWorld.is_free(col, float(home[0]), float(home[1]), R):
		bad.append("точка home (%.1f, %.1f) внутри коробки" % [float(home[0]), float(home[1])])

	for i in mini(bad.size(), SHOW):
		errs.append(bad[i])
	if bad.size() > SHOW:
		errs.append("...и ещё %d" % (bad.size() - SHOW))

	props.dispose()
	root.free()

	if errs.is_empty():
		print("test_street_route: PASS — кольцо из %d узлов чисто" % pts.size())
		quit(0)
		return
	print("FAIL test_street_route: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)

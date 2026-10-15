# Приёмка точек мелькания (haunt.gd::_make_points).
#
# Ловит ошибку, которую в игре отличить нельзя ни от чего: точка формально
# валидна, а практически мертва. Мелькание редкое по устройству — два-четыре
# за главу, — и «эта точка не сработала ни разу» выглядит точно так же, как
# «просто не выпало». Отсюда четыре машинные проверки:
#
#   · зона из zones существует в site.json;
#   · в своей зоне есть хоть одна позиция в рабочей вилке 4..24 м;
#   · точка ВИДНА: с нуля позиций — всегда провал; в просторной зоне — не
#     меньше VISIBLE_MIN.
#
# Чего тест НЕ требует. «Фигура помещается капсулой» — не инвариант этой
# механики, и половина принятых точек его не проходит намеренно: он стоит
# В ОКОННОМ ПРОЁМЕ, а мансардные ноги вообще утоплены на 25 см под пол, иначе
# лицо приходится в перемычку. Глубина погружения печатается справочно.
#
# Порог видимости в тесноте тоже не догма: балкон — это 22 позиции в вилке,
# и точка attic-n, ради которой балкон и нужен, видна ровно с двух. Поэтому
# VISIBLE_MIN спрашивается только с зон, где позиций хватает (SPACIOUS).
#
# Видимость считается тем же лучом, что и в рантайме (Threat.ray_static) и до
# той же высоты лица: haunt._aim целится в ноги + face_y, а не в ноги.
# Точки с see_through сквозь стекло и сетку луч не проверяет — в рантайме
# он их тоже не проверяет, и требовать от теста строгости, которой нет
# в игре, значит проверять другую игру.
#
# Прогон:
#   Godot…_console.exe --headless --path godot --script res://tests/test_haunt_points.gd
extends SceneTree

const R := 0.32                # капсула фигуры, как у деда
const FACE := 1.596            # высота лица над ногами (actors.gd meta face_y)
const HEAD_CLEAR := 1.5        # столько должно быть над ногами свободно
const GRID := 0.5              # шаг сетки позиций игрока внутри зоны
const EYE := 1.62              # глаза игрока над полом зоны
const VISIBLE_MIN := 12        # меньше — точка есть, а увидеть её негде
const SPACIOUS := 60           # с какой зоны спрашивать VISIBLE_MIN
const NEAR := 4.0              # ближе haunt не показывает
const FAR := 24.0              # дальше туман съедает

var _col: CollisionWorld = null


func _initialize() -> void:
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	_col = col
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)

	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)
	props.rebuild_collision(col)

	# Двери на время проверки открыты — та же договорённость, что у audit_reach
	# и test_nav_links: нас интересует створ, а не запертость.
	for b: Dictionary in built.get("blockers", []):
		col.set_blocker_active(String(b["id"]), false)

	var zones: Dictionary = {}
	for z: Dictionary in (GameData.site()["ZONES"] as Array):
		zones[String(z["id"])] = z

	var haunt := Haunt.new({}, null, col, 1)
	var fails := 0
	var seen: Dictionary = {}
	for p: Dictionary in haunt.points:
		fails += _check(p, zones, seen)

	props.dispose()
	root.free()
	if fails == 0:
		print("test_haunt_points: PASS (%d точек)" % haunt.points.size())
		quit(0)
	else:
		printerr("test_haunt_points: FAIL (%d расхождений)" % fails)
		quit(1)


func _check(p: Dictionary, zones: Dictionary, seen: Dictionary) -> int:
	var id := String(p["id"])
	var bad := 0
	if seen.has(id):
		printerr("%s: имя точки встречается дважды" % id)
		bad += 1
	seen[id] = true

	var pp: Array = p["pos"]
	var feet := Vector3(float(pp[0]), float(pp[1]), float(pp[2]))
	var face := feet + Vector3(0.0, FACE, 0.0)

	# 1. Насколько фигура утоплена в геометрию. Справочно, см. шапку.
	var hit := _col.capsule_hit_d(feet.x, feet.y + R + 0.02, feet.z,
		feet.x, feet.y + HEAD_CLEAR, feet.z, R,
		CollisionWorld.MASK_STATIC | CollisionWorld.MASK_PROPS)
	var deep := float(hit.get("depth", 0.0)) if not hit.is_empty() else 0.0

	# 2. Зоны существуют.
	var zs: Array = p["zones"]
	if zs.is_empty():
		printerr("%s: не объявлено ни одной зоны — точка не выпадет никогда" % id)
		bad += 1
	for z: Variant in zs:
		if not zones.has(String(z)):
			printerr("%s: зоны «%s» нет в site.json ZONES" % [id, String(z)])
			bad += 1

	# 3. Видимость с сетки.
	var vis := 0
	var tried := 0
	var best := INF
	for z: Variant in zs:
		var zone: Dictionary = zones.get(String(z), {})
		if zone.is_empty():
			continue
		var rect: Array = zone["rect"]
		var floor_y := _floor_of(zone)
		var x := float(rect[0]) + GRID * 0.5
		while x < float(rect[1]):
			var zz := float(rect[2]) + GRID * 0.5
			while zz < float(rect[3]):
				var eye := Vector3(x, floor_y + EYE, zz)
				var to := face - eye
				var d := to.length()
				if d >= NEAR and d <= FAR:
					tried += 1
					best = minf(best, d)
					if bool(p["see_through"]) or _clear(eye, to / d, d):
						vis += 1
				zz += GRID
			x += GRID
	if tried == 0:
		printerr("%s: в своей зоне нет ни одной позиции в вилке %.0f..%.0f м — "
			% [id, NEAR, FAR] + "точка либо вплотную, либо за туманом")
		bad += 1
	elif vis == 0:
		printerr("%s: не видна ни с одной из %d позиций своей зоны" % [id, tried])
		bad += 1
	elif tried >= SPACIOUS and vis < VISIBLE_MIN:
		printerr("%s: видна только с %d позиций из %d (нужно %d) — точка есть, "
			% [id, vis, tried, VISIBLE_MIN] + "а увидеть её негде")
		bad += 1
	print("%-18s %-10s видна с %4d из %4d позиций, ближайшая %.1f м%s"
		% [id, ",".join(_strings(zs)), vis, tried, best if best < INF else 0.0,
			"" if deep <= 0.0 else ", утоплена на %.2f м" % deep])
	return bad


## Луч до лица, ровно тот же, что в haunt._clear: только статика и допуск 0.2 м
## на то, что фигура стоит вплотную к проёму.
func _clear(from: Vector3, dir: Vector3, l: float) -> bool:
	var t := Threat.ray_static(_col, from.x, from.y, from.z, dir.x, dir.y, dir.z, l)
	return t == INF or t > l - 0.2


## Пол зоны: у зоны есть вилка по высоте, и низ её — это и есть пол,
## на котором стоит игрок.
func _floor_of(zone: Dictionary) -> float:
	var y: Array = zone["y"]
	return float(y[0])


func _strings(a: Array) -> PackedStringArray:
	var out := PackedStringArray()
	for v: Variant in a:
		out.append(String(v))
	return out

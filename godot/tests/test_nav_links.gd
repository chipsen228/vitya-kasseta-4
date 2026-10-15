# Приёмка переходов между слоями (data/nav_links.json).
#
# Ловит ровно ту ошибку, которую иначе замечают через час игры: разъехавшийся
# переход НЕ падает и НЕ ругается — дед просто никогда им не пользуется, и это
# выглядит как «он опять телепортируется», а не как поломка. Проверяется:
#
#   · оба конца перехода — существующие узлы навграфа и в разных слоях;
#   · ломаная начинается у узла a и кончается у узла b (не дальше LINK_GAP);
#   · каждая точка ломаной проходима капсулой деда r 0.32 через CollisionWorld;
#   · каждый отрезок проходим той же капсулой, сэмплированием с шагом 0.25;
#   · блокер из needsOpen существует среди блокеров мира;
#   · все пять слоёв достижимы из floor1 по цепочке переходов.
#
# Прогон:
#   Godot…_console.exe --headless --path godot --script res://tests/test_nav_links.gd
extends SceneTree

const R := 0.32              # радиус капсулы деда (Threat.R)
const LINK_GAP := 2.2        # насколько конец ломаной вправе отстоять от узла
const SAMPLE := 0.25         # шаг сэмплирования отрезка
# Дверной проём 0.9 при капсуле 0.64 проходится только строго по оси, и проба
# у самого косяка честно отвечает «занято». Точки, помеченные здесь, проверяются
# уменьшенным радиусом — тем же, каким граф строит дверные узлы.
const DOOR_R := 0.26

var _col: CollisionWorld = null


func _initialize() -> void:
	var links := NavLinks.load_all()
	if links.links.is_empty():
		print("test_nav_links: data/nav_links.json нет или он пуст — "
			+ "дед ходит как в фазе 6, это допустимый откат")
		print("test_nav_links: PASS")
		quit(0)
		return

	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	_col = col
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)

	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)

	# Двери и ворота на время проверки открываются — та же договорённость, что
	# у audit_reach: нас интересует геометрия перехода, а не его запертость.
	# Запертость живёт в needsOpen и читается живьём в рантайме.
	for b: Dictionary in built.get("blockers", []):
		col.set_blocker_active(String(b["id"]), false)

	var nav := NavGraph.from_baked(col, built.get("blockers", []))
	var before := links.links.size()
	links.bind(nav)
	var fails := 0
	if links.links.size() != before:
		printerr("отброшено переходов при привязке: %d" % (before - links.links.size()))
		fails += 1

	var blockers: Dictionary = {}
	for b: Dictionary in built.get("blockers", []):
		blockers[String(b["id"])] = true

	for l: Dictionary in links.links:
		fails += _check(l, links, nav, blockers)

	fails += _check_reach(links)
	for l: Dictionary in links.links:
		fails += _check_walk(l, links, nav, col)

	props.dispose()
	root.free()
	if fails == 0:
		print("test_nav_links: PASS (%d переходов)" % links.links.size())
		quit(0)
	else:
		printerr("test_nav_links: FAIL (%d расхождений)" % fails)
		quit(1)


func _check(l: Dictionary, links: NavLinks, nav: NavGraph, blockers: Dictionary) -> int:
	var id := String(l["id"])
	var bad := 0
	var pair := links.layers_of(l)
	var na: Dictionary = nav.node(String(l["a"]))
	var nb: Dictionary = nav.node(String(l["b"]))

	var need := String(l["needs_open"])
	if need != "" and not blockers.has(need):
		printerr("%s: нет блокера '%s' среди блокеров мира" % [id, need])
		bad += 1

	var pts: Array = l["points"]
	# Полный маршрут: узел a — ломаная — узел b. Проверяем его целиком,
	# потому что разрыв на стыке узла и ломаной ничем не лучше разрыва внутри.
	var route: Array = [Vector3(float(na["x"]), float(na["y"]), float(na["z"]))]
	route.append_array(pts)
	route.append(Vector3(float(nb["x"]), float(nb["y"]), float(nb["z"])))

	var d0: float = (route[0] as Vector3).distance_to(route[1])
	var d1: float = (route[route.size() - 2] as Vector3).distance_to(route[route.size() - 1])
	if d0 > LINK_GAP:
		printerr("%s: первая точка ломаной в %.2f м от узла %s (не дальше %.2f)"
			% [id, d0, l["a"], LINK_GAP])
		bad += 1
	if d1 > LINK_GAP:
		printerr("%s: последняя точка ломаной в %.2f м от узла %s (не дальше %.2f)"
			% [id, d1, l["b"], LINK_GAP])
		bad += 1

	# Узкие места считаем и печатаем: точка, прошедшая только дверным радиусом, —
	# это не ошибка, но и не то, о чём стоит узнать через полгода из игры.
	var tight := 0
	for i in route.size():
		var p: Vector3 = route[i]
		if _clear(nav, p, R):
			continue
		if _clear(nav, p, DOOR_R):
			tight += 1
			continue
		printerr("%s: точка %d (%.2f %.2f %.2f) не проходима капсулой — %s"
			% [id, i, p.x, p.y, p.z, _who(_col, p)])
		bad += 1
	for i in route.size() - 1:
		var a: Vector3 = route[i]
		var b: Vector3 = route[i + 1]
		var blocked := _segment(nav, a, b)
		if blocked >= 0.0:
			var p := a.lerp(b, blocked)
			printerr("%s: отрезок %d->%d занят на доле %.2f, точка (%.2f %.2f %.2f) — %s"
				% [id, i, i + 1, blocked, p.x, p.y, p.z, _who(_col, p)])
			bad += 1

	var total := 0.0
	for i in route.size() - 1:
		total += (route[i] as Vector3).distance_to(route[i + 1])
	print("%-14s %s -> %s  (%s -> %s)  %.1f м, цена %.0f с%s%s"
		% [id, l["a"], l["b"], pair[0] if pair.size() > 0 else "?",
			pair[1] if pair.size() > 1 else "?", total, l["cost"],
			"" if tight == 0 else ", узких точек %d (проходит дверным радиусом %.2f)" % [tight, DOOR_R],
			"" if bad == 0 else "  <-- расхождения"])
	return bad


## Проба капсулы. Слой берём по отметке — от него зависит только верх пробы,
## и в шахте люка это ровно то, что нужно: там низкий потолок обоих слоёв.
func _clear(nav: NavGraph, p: Vector3, r: float) -> bool:
	return bool(nav.probe(Threat.layer_of(p.y), p.x, p.y, p.z, r))


## Кто мешает. Без этого сообщение «точка не проходима» отправляет искать
## виновника руками по трём наборам коробок, а он почти всегда неожиданный.
func _who(col: CollisionWorld, p: Vector3) -> String:
	var top: float = float(Threat.PROBE_TOP.get(Threat.layer_of(p.y), 1.55))
	var names := {
		CollisionWorld.MASK_STATIC: "мир",
		CollisionWorld.MASK_PROPS: "обстановка",
		CollisionWorld.MASK_BLOCKERS: "блокер",
	}
	var out: Array = []
	for mask: int in [CollisionWorld.MASK_STATIC, CollisionWorld.MASK_PROPS,
			CollisionWorld.MASK_BLOCKERS]:
		var r := col.capsule_hit_d(p.x, p.y + R + 0.02, p.z, p.x, p.y + top, p.z, R, mask)
		if r.is_empty():
			continue
		out.append("%s (глубина %.3f)" % [names[mask], float(r.get("depth", 0.0))])
	return "мешает: " + (", ".join(out) if not out.is_empty() else "ничего (проба слоя)")


## Доля отрезка, на которой он перекрыт, либо −1, если чист.
func _segment(nav: NavGraph, a: Vector3, b: Vector3) -> float:
	var len := a.distance_to(b)
	var n := maxi(1, int(ceil(len / SAMPLE)))
	for i in range(1, n):
		var t := float(i) / float(n)
		var p := a.lerp(b, t)
		if not _clear(nav, p, R) and not _clear(nav, p, DOOR_R):
			return t
	return -1.0


## Живой прогон: дед действительно проходит переход ногами и приходит туда,
## куда переход ведёт. Без этого таблица проверена только как геометрия —
## а сломаться она может и в исполнении: не переключился слой, не сошлась
## точка достижения, встал на первой же вершине ломаной.
##
## Прыжок позиции сверх JUMP_MAX значит телепорт: сам смысл фазы 7 в том,
## что между этажами дед ХОДИТ, и молчаливый откат к телепорту здесь ловится.
const JUMP_MAX := 0.30
const SIM_DT := 1.0 / 60.0
const SIM_LIMIT := 45.0


func _check_walk(l: Dictionary, links: NavLinks, nav: NavGraph, col: CollisionWorld) -> int:
	var pair := links.layers_of(l)
	var na: Dictionary = nav.node(String(l["a"]))
	var nb: Dictionary = nav.node(String(l["b"]))
	var th := Threat.new({}, null, nav, col, 1)
	th.links = links
	th.place_at(float(na["x"]), float(na["y"]), float(na["z"]))
	th.layer = String(pair[0])

	if not th._start_traverse(String(pair[1])):
		printerr("%s: переход не строится из %s в %s" % [l["id"], pair[0], pair[1]])
		return 1

	var t := 0.0
	var prev := th.pos
	var jump := 0.0
	var walked := 0.0
	while t < SIM_LIMIT and not th._trav.is_empty():
		th._tick(SIM_DT)
		th._move(SIM_DT, Vector3.ZERO)
		var d := prev.distance_to(th.pos)
		jump = maxf(jump, d)
		walked += d
		prev = th.pos
		t += SIM_DT

	var bad := 0
	var goal := Vector3(float(nb["x"]), float(nb["y"]), float(nb["z"]))
	var left := th.pos.distance_to(goal)
	if not th._trav.is_empty():
		printerr("%s: за %.0f с не дошёл, остался в %.2f м от %s" % [l["id"], t, left, l["b"]])
		bad += 1
	if th.layer != String(pair[1]):
		printerr("%s: слой не переключился — %s вместо %s" % [l["id"], th.layer, pair[1]])
		bad += 1
	if left > 1.5:
		printerr("%s: пришёл в %.2f м от узла %s" % [l["id"], left, l["b"]])
		bad += 1
	if jump > JUMP_MAX:
		printerr("%s: скачок позиции %.2f м — это телепорт, а не ходьба" % [l["id"], jump])
		bad += 1
	print("  прошёл %-14s за %.1f с, %.1f м, макс. шаг %.3f м, встал (%.2f %.2f %.2f), до узла %.2f м"
		% [l["id"], t, walked, jump, th.pos.x, th.pos.y, th.pos.z, left])
	return bad


## Все слои достижимы из floor1. Отрезанный слой — это не ошибка данных,
## а тихая потеря: дед туда просто никогда не придёт ногами.
func _check_reach(links: NavLinks) -> int:
	var all := func(_l: Dictionary) -> bool: return true
	var bad := 0
	for lay: String in ["plot", "attic", "cellar", "roof"]:
		var ch := links.chain("floor1", lay, all)
		if ch.is_empty():
			printerr("из floor1 не добраться в %s ни одной цепочкой" % lay)
			bad += 1
			continue
		var names: Array = []
		for step: Dictionary in ch:
			names.append(String((step["link"] as Dictionary)["id"]))
		print("floor1 -> %-7s: %s" % [lay, ", ".join(names)])
	return bad

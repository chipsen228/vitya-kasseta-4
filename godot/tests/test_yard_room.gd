# Баня и погреб как помещения, а не как декорация (фаза 11).
#
# Три утверждения, и каждое ловит свою тихую ошибку.
#
# 1. ЗОНА ОДНА И ПОСЛЕ ВТОРОЙ СБОРКИ. YardWorld дописывает акустические зоны
#    прямо в site["ZONES"], а GameData кэширует site.json по ссылке на процесс.
#    Без гарда от повторной вставки второй прогон сборки (а его делают три
#    теста и сам редактор) удваивает зоны, и zone_at() начинает возвращать
#    копию — с виду ту же, но не ту, на которую ссылаются точки страха.
#
# 2. СКВОЗЬ СТЕНУ НЕЛЬЗЯ, В ДВЕРЬ МОЖНО. Постройки живут в четвёртом наборе,
#    и проверить их можно только явной маской. Забытая коробка стены читается
#    в игре как «баня без задней стенки» — и заметить это можно, только зайдя.
#
# 3. ПОЛ НА МЕСТЕ. Плита пола идёт в оверлей, а ray_down по умолчанию спрашивает
#    ALL, куда оверлей не входит. Ошибись тут — и игрок ходит по бане, утопая
#    в её полу по щиколотку, потому что стоит на земле.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_yard_room.gd
extends SceneTree

const R := 0.30              # радиус капсулы игрока
# Концы капсулы — ЦЕНТРЫ сфер, а не макушка и подошва: капсула от пола до
# 1.70 торчит вверх на 2.00 и упирается в перемычку двери там, где игрок
# проходит свободно. Рост 1.78 минус радиус и есть верхний конец.
const CAP_TOP := 1.78 - R


func _initialize() -> void:
	var errs: Array[String] = []

	YardWorld._cache = null
	StreetWorld._cache = null
	var w := _build()
	var yard: Dictionary = (w["built"] as Dictionary).get("yard", {})
	if yard.is_empty():
		print("test_yard_room: SKIP — нет data/yard.json")
		_drop(w)
		quit(0)
		return

	var col: CollisionWorld = w["col"]
	var banya: Dictionary = yard.get("banya", {})
	var shed: Dictionary = yard.get("shed", {})

	# ---- 1. зоны ----
	var zones: Array = GameData.site()["ZONES"]
	for id: String in ["banya", "cellar-shed"]:
		var n := 0
		for z: Dictionary in zones:
			if String(z.get("id", "")) == id:
				n += 1
		if n != 1:
			errs.append("зон «%s» в site.ZONES: %d, должна быть ровно одна" % [id, n])

	# ---- 2. стены и проёмы ----
	_room(col, banya, "баня", errs)
	_room(col, shed, "погреб", errs)

	# ---- 3. вторая сборка: зоны не удваиваются, счёт коробок тот же ----
	var before: int = col.box_count(CollisionWorld.SET_OVERLAY)
	_drop(w)
	var w2 := _build()
	var col2: CollisionWorld = w2["col"]
	var after: int = col2.box_count(CollisionWorld.SET_OVERLAY)
	if after != before:
		errs.append("вторая сборка дала %d коробок оверлея против %d" % [after, before])
	for id: String in ["banya", "cellar-shed"]:
		var n2 := 0
		for z: Dictionary in (GameData.site()["ZONES"] as Array):
			if String(z.get("id", "")) == id:
				n2 += 1
		if n2 != 1:
			errs.append("после второй сборки зон «%s»: %d" % [id, n2])
	# Зона обязана находиться по точке, а не просто лежать в списке.
	var zs: Array = GameData.site()["ZONES"]
	var inside := WorldBuilder.zone_at_in(zs, 5.0, 1.0, 24.60)
	if String(inside.get("id", "")) != "banya":
		errs.append("точка в парной попала в зону «%s», а не «banya»"
			% String(inside.get("id", "?")))
	var inside2 := WorldBuilder.zone_at_in(zs, -7.35, 1.0, 2.35)
	if String(inside2.get("id", "")) != "cellar-shed":
		errs.append("точка в погребе попала в зону «%s», а не «cellar-shed»"
			% String(inside2.get("id", "?")))
	_drop(w2)

	if errs.is_empty():
		print("test_yard_room: PASS")
		quit(0)
		return
	print("FAIL test_yard_room: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ------------------------------------------------------------- помещение ----

func _room(col: CollisionWorld, d: Dictionary, tag: String, errs: Array[String]) -> void:
	if d.is_empty():
		errs.append("%s: нет габаритов в built.yard" % tag)
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var t := float(d.get("wall", 0.16))
	var fl := float(d.get("floor", 0.10))
	var dr: Array = d["door"]
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	var mask := CollisionWorld.MASK_OVERLAY

	# Пол. Луч сверху вниз внутри помещения обязан лечь на плиту, а не на землю.
	var probe: Vector3 = _room_probe(d)
	var hit := col.ray_down(probe.x, fl + 1.6, probe.z, mask)
	if hit.is_empty():
		errs.append("%s: под ногами внутри нет пола вовсе" % tag)
	elif absf(float(hit["y"]) - fl) > 0.001:
		errs.append("%s: пол на %.3f, а должен быть на %.3f" % [tag, float(hit["y"]), fl])

	# Стены. Точка в середине толщины каждой стены обязана быть занята. Пробы
	# идут ТОЧКОЙ, а не капсулой, и это не лень: капсула радиуса 0.30 в стене
	# толщиной 0.18 получает от обеих граней встречные сдвиги, они гасят друг
	# друга, и сплошная стена читается как сплошная дыра (та же грабля, что
	# в test_street_floor).
	var mid_y := fl + 1.0
	var walls: Array = [
		["северная", Vector3((x0 + x1) / 2.0, mid_y, z0 + t / 2.0)],
		["южная", Vector3((x0 + x1) / 2.0, mid_y, z1 - t / 2.0)],
		["западная", Vector3(x0 + t / 2.0, mid_y, (z0 + z1) / 2.0)],
		["восточная", Vector3(x1 - t / 2.0, mid_y, (z0 + z1) / 2.0)],
	]
	# Простенки по обе стороны проёма: середина той стены, в которой дверь,
	# приходится ровно на дыру, и без этих двух точек стена с дверью
	# не проверялась бы вовсе.
	walls.append(["простенок до проёма", _door_point(d, d0 - 0.35, mid_y)])
	walls.append(["простенок после проёма", _door_point(d, d1 + 0.35, mid_y)])
	for row: Array in walls:
		var p: Vector3 = row[1]
		# Проём двери не стена: его исключаем по координате.
		if _is_doorway(d, p):
			continue
		if not col.point_hit(p.x, p.y, p.z, mask):
			errs.append("%s: %s стена дырявая на [%.2f, %.2f, %.2f]"
				% [tag, String(row[0]), p.x, p.y, p.z])

	# Проём: капсула игрока в дверях обязана пройти. Створка погреба на старте
	# закрыта — открываем её, иначе тест меряет замок, а не проём.
	var had := col.is_blocker_active("door-cellar-shed")
	col.set_blocker_active("door-cellar-shed", false)
	var door_pos: Vector3 = _door_point(d, (d0 + d1) / 2.0, 0.0)
	var free := col.capsule_hit_d(door_pos.x, fl + R + 0.02, door_pos.z,
		door_pos.x, fl + CAP_TOP, door_pos.z, R, mask)
	if not free.is_empty():
		errs.append("%s: в дверь не пройти — капсула упирается на %.2f м"
			% [tag, float(free.get("depth", 0.0))])
	col.set_blocker_active("door-cellar-shed", had)


## Куда светить лучом пола: середина дальней половины помещения, подальше
## от печи, верстака и полков.
static func _room_probe(d: Dictionary) -> Vector3:
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	if d.has("split"):
		# Баня: парная, между печью и полком.
		return Vector3(5.00, 0.0, 25.30)
	return Vector3((float(xr[0]) + float(xr[1])) / 2.0, 0.0,
		(float(zr[0]) + float(zr[1])) / 2.0)


## Дверь бани — в северной стене (проём по x), дверь погреба — в восточной
## (проём по z). Различаются по тому, какая из осей их держит.
static func _door_in_north(d: Dictionary) -> bool:
	return d.has("split")


static func _door_point(d: Dictionary, a: float, y: float) -> Vector3:
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var t := float(d.get("wall", 0.16))
	if _door_in_north(d):
		return Vector3(a, y, float(zr[0]) + t / 2.0)
	return Vector3(float(xr[1]) - t / 2.0, y, a)


static func _is_doorway(d: Dictionary, p: Vector3) -> bool:
	var dr: Array = d["door"]
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	if _door_in_north(d):
		return p.x > d0 and p.x < d1
	return p.z > d0 and p.z < d1


# ------------------------------------------------------------- служебное ----

func _build() -> Dictionary:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	return {"col": col, "root": root, "built": built}


func _drop(w: Dictionary) -> void:
	(w["root"] as Node3D).free()

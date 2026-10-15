# Сельпо и заколоченный дом как помещения, а не как декорация (фаза 12).
#
# Тест списан с test_yard_room.gd, и списан не из лени: у бани, погреба, сельпо
# и заколоченного дома одна и та же четвёрка тихих ошибок, и каждая замечается
# в игре не раньше, чем игрок дойдёт до двери.
#
# 1. ЗОНА ОДНА И ПОСЛЕ ВТОРОЙ СБОРКИ. VillageWorld дописывает акустические зоны
#    прямо в site["ZONES"], а GameData кэширует site.json по ссылке на процесс.
#    Без гарда от повторной вставки второй прогон сборки удваивает зоны,
#    и zone_at() начинает возвращать копию — с виду ту же, но не ту, на которую
#    ссылаются точки страха.
#
# 2. СКВОЗЬ СТЕНУ НЕЛЬЗЯ, В ДВЕРЬ МОЖНО. Постройки живут в четвёртом наборе,
#    и проверить их можно только явной маской.
#
# 3. ПОЛ НА МЕСТЕ. Плита пола идёт в оверлей, а ray_down по умолчанию спрашивает
#    ALL, куда оверлей не входит. Ошибись тут — и игрок проваливается сквозь
#    сельпо на грунт.
#
# 4. ВНУТРИ ЕСТЬ ГДЕ ХОДИТЬ. У сельпо прилавок перегораживает зал поперёк,
#    и проход между ним и западной стеной — единственная дорога к ящику
#    с запчастями, то есть к бегунку, то есть к выходу из главы. Тест проводит
#    капсулу этой дорогой целиком.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_village_room.gd
extends SceneTree

const R := 0.30              # радиус капсулы игрока
# Концы капсулы — ЦЕНТРЫ сфер, а не макушка и подошва: капсула «от пола до 1.70»
# торчит вверх на 2.00 и упирается в перемычку двери там, где игрок проходит
# свободно. Рост 1.78 минус радиус и есть верхний конец.
const CAP_TOP := 1.78 - R

# Дорога от порога сельпо к ящику с запчастями. Ломаная, а не прямая: прилавок
# стоит поперёк зала, и обходить его надо западным концом.
const SHOP_WALK := [
	Vector2(28.90, -7.30), Vector2(28.90, -8.45), Vector2(25.85, -8.45),
	Vector2(25.85, -10.80),
]
# И тот же проход по заколоченному дому: от порога к штативу у щели и дальше
# к лежанке.
const BOARDED_WALK := [
	Vector2(-5.50, -7.90), Vector2(-4.30, -8.40), Vector2(-3.62, -8.60),
	Vector2(-5.80, -9.80), Vector2(-6.60, -11.40),
]
# ФАЗА 13, красный дом. Дорога от порога мимо холодильника к детскому рисунку
# на западной стене — то есть к единственной улике, которая в этом доме есть.
# Холодильник стоит справа от двери и занимает x [0.6, 1.2]: обходить его
# надо западнее, и ровно это тест и проверяет.
const REDHOUSE_WALK := [
	Vector2(0.90, -7.95), Vector2(-0.10, -8.40), Vector2(-0.75, -10.20),
	Vector2(-0.75, -11.10),
]
# ФАЗА 14, красный дом внизу: дорога от порога к лестнице. Идёт восточнее
# холодильника, в полосе между ним и маршем, и упирается в первую ступень.
# Ошибись в ширине марша или в положении стола — и на второй этаж не попасть
# вовсе, а заметно это станет только с джойстиком в руках.
const REDHOUSE_STAIR_WALK := [
	Vector2(1.10, -7.95), Vector2(1.80, -8.30), Vector2(1.80, -9.60),
]
# ФАЗА 14, второй этаж: от площадки над лестницей мимо кровати к детскому
# столу у окна. Пол здесь — плита перекрытия (floor2), а не грунт, поэтому
# и высота капсулы отсчитывается от неё.
const REDHOUSE_UP_WALK := [
	Vector2(2.76, -12.10), Vector2(1.50, -11.80), Vector2(-0.40, -9.20),
	Vector2(-0.40, -8.80),
]


func _initialize() -> void:
	var errs: Array[String] = []

	VillageWorld._cache = null
	StreetWorld._cache = null
	YardWorld._cache = null
	var w := _build()
	var village: Dictionary = (w["built"] as Dictionary).get("village", {})
	if village.is_empty():
		print("test_village_room: SKIP — нет data/village.json")
		_drop(w)
		quit(0)
		return

	var col: CollisionWorld = w["col"]

	# ---- 1. зоны ----
	var zones: Array = GameData.site()["ZONES"]
	for id: String in ["shop", "boarded", "graveyard", "redhouse"]:
		var n := 0
		for z: Dictionary in zones:
			if String(z.get("id", "")) == id:
				n += 1
		if n != 1:
			errs.append("зон «%s» в site.ZONES: %d, должна быть ровно одна" % [id, n])

	# ---- 2/3. стены, проём, пол ----
	_room(col, village.get("shop", {}), "сельпо", Vector3(30.00, 0.0, -11.00), errs)
	_room(col, village.get("boarded", {}), "заколоченный",
		Vector3(-5.50, 0.0, -11.00), errs)
	# ФАЗА 13. Красный дом — третье помещение деревни и такое же четвёртонаборное,
	# как два первых: без явной маски его стен для всех проверок просто нет.
	_room(col, village.get("redhouse", {}), "красный дом",
		Vector3(0.00, 0.0, -11.00), errs)

	# ---- 4. внутри есть где ходить ----
	# Створка сельпо на старте заперта: в игре её открывают ключом от Аркадия.
	# Мерить проход при запертой двери значит мерить замок.
	if not col.is_blocker_active("door-shop"):
		errs.append("нет блокера door-shop — сельпо нечем запереть")
	col.set_blocker_active("door-shop", false)
	_walk(col, SHOP_WALK, float((village.get("shop", {}) as Dictionary).get("floor", 0.14)),
		"сельпо", errs)
	col.set_blocker_active("door-shop", true)
	# Заколоченный дом стоит заколоченным до главы ДЕРЕВНЯ: в УЛИЦЕ игрок
	# проходит мимо него дважды, и войти тогда нельзя.
	if not col.is_blocker_active("door-boarded"):
		errs.append("нет блокера door-boarded — в заколоченный дом можно войти "
			+ "с первой же главы")
	col.set_blocker_active("door-boarded", false)
	_walk(col, BOARDED_WALK,
		float((village.get("boarded", {}) as Dictionary).get("floor", 0.12)),
		"заколоченный", errs)
	col.set_blocker_active("door-boarded", true)
	# Красный дом стоит открытым с самого начала: доски с него никто не сдирал,
	# дверь просто не заперли — уезжали быстро. Блокера у него нет вовсе,
	# и проход меряется как есть.
	var rh: Dictionary = village.get("redhouse", {}) as Dictionary
	var rh_fl := float(rh.get("floor", 0.14))
	_walk(col, REDHOUSE_WALK, rh_fl, "красный дом", errs)
	_walk(col, REDHOUSE_STAIR_WALK, rh_fl, "красный дом, подход к лестнице", errs)
	# Второй этаж (фаза 14). Плита перекрытия — она же пол — лежит на floor2;
	# если её вырезали шире марша, капсула провалится не здесь, а в игре,
	# поэтому заодно проверяется, что под каждой точкой маршрута есть опора.
	var fl2 := float(rh.get("floor2", 0.0))
	if fl2 > 0.0:
		_walk(col, REDHOUSE_UP_WALK, fl2, "красный дом, второй этаж", errs)
		for pt: Vector2 in REDHOUSE_UP_WALK:
			var below := col.ray_down(pt.x, fl2 + 0.40, pt.y,
				CollisionWorld.MASK_OVERLAY)
			if below.is_empty() or absf(float(below.get("y", -99.0)) - fl2) > 0.05:
				errs.append("красный дом, второй этаж: под [%.2f, %.2f] нет пола"
					% [pt.x, pt.y])

	# ---- 5. вторая сборка: зоны не удваиваются, счёт коробок тот же ----
	var before: int = col.box_count(CollisionWorld.SET_OVERLAY)
	_drop(w)
	var w2 := _build()
	var col2: CollisionWorld = w2["col"]
	var after: int = col2.box_count(CollisionWorld.SET_OVERLAY)
	if after != before:
		errs.append("вторая сборка дала %d коробок оверлея против %d" % [after, before])
	var zs: Array = GameData.site()["ZONES"]
	for id: String in ["shop", "boarded", "graveyard", "redhouse"]:
		var n2 := 0
		for z: Dictionary in zs:
			if String(z.get("id", "")) == id:
				n2 += 1
		if n2 != 1:
			errs.append("после второй сборки зон «%s»: %d" % [id, n2])
	# Зона обязана находиться ПО ТОЧКЕ, а не просто лежать в списке.
	for row: Array in [[30.0, 1.0, -11.0, "shop"], [-5.5, 1.0, -11.0, "boarded"],
			[40.0, 1.0, -10.5, "graveyard"], [0.9, 1.0, -11.0, "redhouse"]]:
		var got := WorldBuilder.zone_at_in(zs, float(row[0]), float(row[1]), float(row[2]))
		if String(got.get("id", "")) != String(row[3]):
			errs.append("точка [%.1f, %.1f] попала в зону «%s», а не «%s»"
				% [float(row[0]), float(row[2]), String(got.get("id", "?")), String(row[3])])
	_drop(w2)

	if errs.is_empty():
		print("test_village_room: PASS")
		quit(0)
		return
	print("FAIL test_village_room: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ------------------------------------------------------------- помещение ----

func _room(col: CollisionWorld, d: Dictionary, tag: String, probe: Vector3,
		errs: Array[String]) -> void:
	if d.is_empty():
		errs.append("%s: нет габаритов в built.village" % tag)
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var t := float(d.get("wall", 0.18))
	var fl := float(d.get("floor", 0.12))
	var dr: Array = d["door"]
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	var mask := CollisionWorld.MASK_OVERLAY

	# Пол. Луч сверху вниз внутри помещения обязан лечь на плиту, а не на землю.
	var hit := col.ray_down(probe.x, fl + 1.8, probe.z, mask)
	if hit.is_empty():
		errs.append("%s: под ногами внутри нет пола вовсе" % tag)
	elif absf(float(hit["y"]) - fl) > 0.001:
		errs.append("%s: пол на %.3f, а должен быть на %.3f" % [tag, float(hit["y"]), fl])

	# Стены. Точка в середине толщины каждой стены обязана быть занята. Пробы
	# идут ТОЧКОЙ, а не капсулой, и это не лень: капсула радиуса 0.30 в стене
	# толщиной 0.20 получает от обеих граней встречные сдвиги, они гасят друг
	# друга, и сплошная стена читается как сплошная дыра (та же грабля, что
	# в test_street_floor).
	var mid_y := fl + 0.60
	var walls: Array = [
		["северная", Vector3((x0 + x1) / 2.0, mid_y, z0 + t / 2.0)],
		["западная", Vector3(x0 + t / 2.0, mid_y, (z0 + z1) / 2.0)],
		["восточная", Vector3(x1 - t / 2.0, mid_y, (z0 + z1) / 2.0)],
		["простенок до проёма", Vector3(d0 - 0.40, mid_y, z1 - t / 2.0)],
		["простенок после проёма", Vector3(d1 + 0.40, mid_y, z1 - t / 2.0)],
		["перемычка проёма", Vector3((d0 + d1) / 2.0,
			float(d.get("doorTop", 2.05)) + 0.14, z1 - t / 2.0)],
	]
	for row: Array in walls:
		var p: Vector3 = row[1]
		if not col.point_hit(p.x, p.y, p.z, mask):
			errs.append("%s: %s дырявая на [%.2f, %.2f, %.2f]"
				% [tag, String(row[0]), p.x, p.y, p.z])

	# Проём: капсула игрока в дверях обязана пройти. Обе створки на старте
	# заперты (сельпо на ключ, заколоченный дом на доски) — открываем их,
	# иначе тест меряет замок, а не проём.
	var had := col.is_blocker_active("door-shop")
	var had_b := col.is_blocker_active("door-boarded")
	col.set_blocker_active("door-shop", false)
	col.set_blocker_active("door-boarded", false)
	var cx := (d0 + d1) / 2.0
	var free := col.capsule_hit_d(cx, fl + R + 0.02, z1 - t / 2.0,
		cx, fl + CAP_TOP, z1 - t / 2.0, R, mask)
	if not free.is_empty():
		errs.append("%s: в дверь не пройти — капсула упирается на %.2f м"
			% [tag, float(free.get("depth", 0.0))])
	col.set_blocker_active("door-shop", had)
	col.set_blocker_active("door-boarded", had_b)


## Проводим капсулу по ломаной шагом 12 см. Ошибка, которую это ловит, в игре
## выглядит так: сельпо открылось, бегунок лежит в трёх метрах, и дойти до него
## нельзя, потому что прилавок встал в метре от стены.
func _walk(col: CollisionWorld, route: Array, fl: float, tag: String,
		errs: Array[String]) -> void:
	var mask := CollisionWorld.MASK_OVERLAY
	var stuck := 0
	var first := ""
	for i in route.size() - 1:
		var a: Vector2 = route[i]
		var c: Vector2 = route[i + 1]
		var seg := a.distance_to(c)
		var n := maxi(1, int(seg / 0.12))
		for k in n + 1:
			var p := a.lerp(c, float(k) / float(n))
			var hit := col.capsule_hit_d(p.x, fl + R + 0.02, p.y,
				p.x, fl + CAP_TOP, p.y, R, mask)
			if not hit.is_empty():
				stuck += 1
				if first == "":
					first = "[%.2f, %.2f] на %.2f м" % [p.x, p.y, float(hit.get("depth", 0.0))]
	if stuck > 0:
		errs.append("%s: проход перекрыт в %d точках, первая %s" % [tag, stuck, first])
	else:
		print("%s: проход внутри чист" % tag)


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

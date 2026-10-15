# Околица как место, куда можно прийти и откуда можно вернуться (фаза 14).
#
# Тест списан с test_village_room.gd, и списан по той же причине: у околицы
# ровно те же четыре тихие ошибки, что у сельпо, плюс две своих.
#
# 1. ЗОНЫ. OutskirtsWorld дописывает девять зон прямо в site["ZONES"], а
#    GameData кэширует site.json по ссылке на процесс. Без гарда второй прогон
#    сборки их удвоит, и zone_at() начнёт возвращать копию — с виду ту же.
#
# 2. ПОЛ. Плита околицы лежит в оверлее, а ray_down по умолчанию спрашивает
#    ALL, куда оверлей не входит. Ошибись тут — и игрок проваливается сквозь
#    всю новую карту на грунт улицы.
#
# 3. БОРТА. Периметр обязан быть сплошным, а два проёма в северном борте улицы —
#    наоборот, проходимыми. Тест проверяет и то, и другое: дыра в борте и
#    заваренный проём выглядят в логе одинаково молча.
#
# 4. ВНУТРЬ МОЖНО ВОЙТИ. Амбар, будка водокачки и клуб — не тумбы: в каждом
#    лежит то, ради чего игрок туда идёт (ключ, рубильник, проектор). Сплошная
#    коробка с моделью снаружи выглядит ровно так же, как помещение, и разница
#    обнаруживается за секунду до того, как игрок упрётся носом в стену.
#
# 5. ДО ПРЕДМЕТА ДОТЯНУТЬСЯ. Мало войти — надо ещё встать рядом. Тест ищет
#    место, где капсула свободна и стоит не дальше 1.4 м от предмета.
#
# 6. ЗАМОК РАБОТАЕТ В ОБЕ СТОРОНЫ. Дверь водокачки — переключаемая коробка
#    в SET_OVERLAY: заперта — не пройти, открыта — пройти. Односторонняя
#    проверка пропускает и вечно запертую дверь, и дверь-декорацию.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_outskirts_room.gd
extends SceneTree

const R := 0.30
const CAP_TOP := 1.78 - R
# ФАЗА 16: было MASK_OVERLAY. Маршруты проверялись по ОДНОМУ четвёртому
# набору, то есть сквозь дома первой линии, сквозь реквизит и сквозь блокеры:
# «проход чист» значило «нет стен околицы», а не «игрок пройдёт». Минимум пять
# контрольных точек при этом стояли внутри построек и об этом молчали.
const MASK := CollisionWorld.ALL_SOLID

# Девять зон околицы. Порядок тот же, что в data/outskirts.json.
const ZONE_IDS := [
	"outskirts", "farm", "barn-in", "pond", "pumphouse",
	"hen-yard", "club", "dump", "field",
]
# Точка внутри зоны -> id, который обязан по ней найтись. Зоны перекрываются
# (околица накрывает всё), поэтому проверяется не «зона есть», а «нашлась та».
const ZONE_POINTS := [
	[-36.5, 1.0, -29.5, "barn-in"],
	[-15.0, 1.0, -29.0, "pumphouse"],
	[9.50, 1.0, -29.0, "club"],
	[-23.0, 1.0, -29.0, "pond"],
	[-6.00, 1.0, -29.0, "hen-yard"],
	[22.0, 1.0, -29.0, "dump"],
	[33.0, 1.0, -29.0, "field"],
	[0.00, 1.0, -21.0, "outskirts"],
]
# Пол обязан быть везде, где игрок ходит: оба переулка, вторая линия и все
# семь участков.
# ФАЗА 16. Пять точек стояли ВНУТРИ соседских домов и молчали об этом: пока
# дома были призраками (collide=false), пол под ними был, и проверка проходила.
# Дома получили тело — точки переехали на дорогу перед ними и в проходы между.
const FLOOR_POINTS := [
	[-28.6, -16.0], [34.6, -16.0], [0.0, -21.0], [-36.0, -18.6], [30.0, -18.4],
	[-38.0, -25.2], [-23.0, -28.0], [-19.0, -27.6], [-6.0, -29.0],
	[15.0, -25.0], [22.0, -29.0], [33.0, -29.0],
]

# Дорога с центральной улицы на околицу западным переулком и дальше во двор
# фермы. Первая точка стоит ЮЖНЕЕ северного борта улицы: проверяется в том
# числе и то, что проём проёмом и остался.
# ФАЗА 16. Все четыре маршрута переложены: дома второй линии стали твёрдыми,
# и прежние точки прошивали их насквозь. Теперь маршрут идёт так, как пойдёт
# игрок, — в обход дома, а не сквозь него.
const WEST_LANE_WALK := [
	Vector2(-28.6, -13.2), Vector2(-28.6, -17.8), Vector2(-28.6, -16.2),
	Vector2(-39.8, -16.2), Vector2(-39.8, -25.2), Vector2(-36.3, -25.2),
]
# Восточный проулок — пеший, 2.4 м между глухой стеной сельпо и оградой погоста.
const EAST_LANE_WALK := [
	Vector2(34.6, -13.2), Vector2(34.6, -17.8), Vector2(34.6, -16.2),
	Vector2(30.0, -16.2),
]
# ФАЗА 16. Вторая линия из конца в конец: она перестала быть газоном с
# призраками и стала улицей, и главное про улицу — что по ней ПРОХОДЯТ
# насквозь. Коридор идёт между крыльцами домов и северным бортом улицы.
const SECOND_LINE_WALK := [
	Vector2(30.0, -16.2), Vector2(0.0, -16.2), Vector2(-20.0, -16.2),
	Vector2(-36.0, -16.2),
]
# Двор фермы -> ворота амбара -> гвоздь с ключом у третьего стойла. Заход в
# полутораметровый коридор между южной стеной амбара и домом участка 21.
const BARN_WALK := [
	Vector2(-36.3, -25.2), Vector2(-36.3, -27.0), Vector2(-36.3, -29.0),
	Vector2(-35.9, -29.4),
]
# Вторая линия -> в обход дома участка 20-A -> дверь будки водокачки.
# ФАЗА 18. Первая точка сдвинута с x -19.0 на -18.5: -19.0 лежит в зеркале
# пруда (вода до x -18.9), и сухой щели там 0.8 м. Пробы этого не ловили —
# вода не твёрдая, у неё нет ни коробки, ни пола, — но маршрут «в обход дома
# к водокачке» шёл по воде, то есть проверял не то, чем ходят.
const PUMP_WALK := [
	Vector2(-18.5, -26.0), Vector2(-18.5, -27.6), Vector2(-15.0, -27.6),
	Vector2(-15.0, -29.6),
]
# ФАЗА 18. Два сквозных проезда сквозь дома второй линии (жалоба Петра,
# пункт шестой). Маршрут идёт С ДОРОГИ второй линии на север, через тело
# дома, и упирается в то, ради чего проезд и прорезан: ворота амбара
# (x -36.3, FARM.barn.gate) и дверь водокачки (x -15.0, PUMP.door.x).
#
# ЗАЧЕМ ЭТИ ДВА МАРШРУТА ОТДЕЛЬНО. Проезд в доме «5» был прорезан и НИКУДА
# НЕ ВЁЛ: забор двора перед ним остался сплошным, калитка стояла в стороне,
# и капсула упиралась в штакетник на z -20.6. Глазами по кадру этого не
# видно — забор в тени, — а пробой видно сразу.
const BARN_PASS_WALK := [
	Vector2(-36.3, -18.0), Vector2(-36.3, -22.0), Vector2(-36.3, -26.4),
]
const PUMP_PASS_WALK := [
	Vector2(-15.0, -18.0), Vector2(-15.0, -22.0), Vector2(-15.0, -27.9),
]
# ФАЗА 17. Дорога от ворот к покосу и холму Вали через НОВЫЙ, третий проём
# в северном борте улицы (data/street.json BORDERS.north, x [10, 12]).
#
# Зачем он вообще. Борт шёл сплошной стеной x [-25.6, 33.4] — 59 м ровно
# поперёк оси Вали (круг камней x 0.60, полосы покоса x 0.9, холм x 0.90).
# Проёма было два, оба на краях карты: по прямой от ограды до первой полосы
# 12.9 м, ногами — 75 м в обход. Туда просто не ходили, и Пётр решил, что
# «деревья не пустили».
#
# Проём встаёт между домом наблюдателя (до x 10.0) и домом Аркадия (с 12.0),
# где заделки INFILL нет, и выводит прямо к калитке участка 19.
const GRAVE_WALK := [
	Vector2(11.0, -12.0), Vector2(11.0, -16.2), Vector2(0.9, -16.2),
	Vector2(0.9, -21.0), Vector2(0.9, -25.0), Vector2(0.9, -28.2),
]

# Мимо дома участка 19 с востока -> дверь клуба -> проектор в зале.
const CLUB_WALK := [
	Vector2(15.0, -22.0), Vector2(15.0, -26.3), Vector2(9.10, -26.3),
	Vector2(9.10, -28.0), Vector2(10.00, -27.8),
]


func _initialize() -> void:
	var errs: Array[String] = []
	var w := _build()
	var col: CollisionWorld = w["col"]
	var built: Dictionary = w["built"]
	var out: Dictionary = built.get("outskirts", {}) as Dictionary

	if out.is_empty() or not bool(out.get("enabled", false)):
		print("FAIL test_outskirts_room: OutskirtsWorld не собрался — нет data/outskirts.json?")
		_drop(w)
		quit(1)
		return

	# ---- 1. зоны ----
	var zs: Array = GameData.site().get("ZONES", [])
	for id: String in ZONE_IDS:
		var n := 0
		for z: Dictionary in zs:
			if String(z.get("id", "")) == id:
				n += 1
		if n != 1:
			errs.append("зон «%s» в site: %d, а должна быть одна" % [id, n])
	for row: Array in ZONE_POINTS:
		var got := WorldBuilder.zone_at_in(zs, float(row[0]), float(row[1]), float(row[2]))
		if String(got.get("id", "")) != String(row[3]):
			errs.append("точка [%.1f, %.1f] попала в зону «%s», а не «%s»"
				% [float(row[0]), float(row[2]), String(got.get("id", "?")), String(row[3])])

	# ---- 2. пол ----
	for p: Array in FLOOR_POINTS:
		var hit := col.ray_down(float(p[0]), 1.80, float(p[1]), MASK)
		if hit.is_empty():
			errs.append("под [%.1f, %.1f] нет пола вовсе" % [float(p[0]), float(p[1])])
		# Старый story-dock удалён: дальняя точка пруда теперь попадает
		# в blocker глубокой воды; остальные контрольные точки лежат на нуле.
		elif is_equal_approx(float(p[0]), -23.0) and is_equal_approx(float(p[1]), -28.0):
			if float(hit["y"]) < 1.50 or float(hit["y"]) > 1.60:
				errs.append("глубокая вода под [-23.0, -28.0] имеет неверную высоту %.3f"
					% float(hit["y"]))
		elif absf(float(hit["y"])) > 0.001:
			errs.append("пол под [%.1f, %.1f] на %.3f, а должен быть на нуле"
				% [float(p[0]), float(p[1]), float(hit["y"])])
	if col.is_blocker_active("story-dock"):
		errs.append("старый story-dock всё ещё существует в overlay")

	# ---- 3. борта сплошные ----
	# Проба ТОЧКОЙ, а не капсулой: капсула радиуса 0.30 в стене толщиной 0.20
	# получает от обеих граней встречные сдвиги, они гасят друг друга, и
	# сплошная стена читается как сплошная дыра (грабля из test_street_floor).
	var solids: Array = [
		["северный борт околицы", Vector3(0.0, 1.2, -34.6)],
		["западный борт околицы", Vector3(-41.2, 1.2, -25.0)],
		["восточный борт околицы", Vector3(39.2, 1.2, -25.0)],
		["западная стенка западного переулка", Vector3(-31.7, 1.2, -17.6)],
		["восточная стенка западного переулка", Vector3(-25.5, 1.2, -17.6)],
		["западная стенка восточного проулка", Vector3(33.3, 1.2, -17.6)],
		["восточная стенка восточного проулка", Vector3(35.9, 1.2, -17.6)],
		# ФАЗА 17. Края нового, третьего проёма. Проём вырезан из сплошного
		# отрезка, и ошибиться тут можно в обе стороны: не туда поставишь
		# границу — либо останется простенок в полметра, либо борт разъедется
		# на десяток метров и улица потечёт в поле.
		#
		# ФАЗА 18. Проёмов стало семь, и этот единственный сохранил свои
		# границы (x [10,12]) — остальные переразбиты. Кромки съехали с 9.4/12.6
		# на 8.8/12.6: западный отрезок теперь кончается на -9.0 и начинается
		# заново на 12.0, то есть западная проба переехала в соседний проём,
		# а восточная осталась на месте. Полная карта борта — в
		# tests/test_line_crossing.gd, здесь только края этого проёма.
		["северный борт улицы западнее третьего проёма", Vector3(8.8, 1.2, -15.0)],
		["северный борт улицы восточнее третьего проёма", Vector3(12.6, 1.2, -15.0)],
	]
	for row: Array in solids:
		var p2: Vector3 = row[1]
		if not col.point_hit(p2.x, p2.y, p2.z, MASK):
			errs.append("%s: в точке [%.1f, %.1f] дыра" % [String(row[0]), p2.x, p2.z])

	# ---- 3б. а середина проёма — дыра ----
	# Обратная половина той же проверки: заваренный проём выглядит в логе
	# ровно так же молча, как дыра в борте.
	for x: float in [10.4, 11.0, 11.6]:
		if col.point_hit(x, 1.2, -15.0, MASK):
			errs.append("третий проём заварен: в точке [%.1f, -15.0] твёрдо" % x)

	# ---- 4. проходы ----
	_walk(col, WEST_LANE_WALK, "западный переулок", errs)
	_walk(col, EAST_LANE_WALK, "восточный проулок", errs)
	_walk(col, SECOND_LINE_WALK, "вторая линия насквозь", errs)
	_walk(col, GRAVE_WALK, "третий проём -> покос -> холм", errs)
	_walk(col, BARN_WALK, "амбар", errs)
	_walk(col, CLUB_WALK, "клуб", errs)

	# ---- 5. водокачка: замок в обе стороны ----
	if not col.is_blocker_active("door-pump"):
		errs.append("нет блокера door-pump — водокачку нечем запереть")
	else:
		if not _blocked(col, PUMP_WALK):
			errs.append("водокачка заперта, а пройти внутрь всё равно можно")
		col.set_blocker_active("door-pump", false)
		_walk(col, PUMP_WALK, "водокачка (отперта)", errs)
		col.set_blocker_active("door-pump", true)

	# ---- 5б (фаза 18): проезды сквозь дома второй линии ----
	_walk(col, BARN_PASS_WALK, "проезд под домом 21 к воротам амбара", errs)
	_walk(col, PUMP_PASS_WALK, "проезд под домом 20 к двери водокачки", errs)

	# ---- 6. до предмета можно дотянуться ----
	var nodes: Dictionary = out.get("nodes", {}) as Dictionary
	col.set_blocker_active("door-pump", false)
	for id: String in ["farm-key", "pump-breaker"]:
		_reach(col, nodes, id, errs)
	col.set_blocker_active("door-pump", true)

	# ---- 7. вторая сборка ----
	var before: int = col.box_count(CollisionWorld.SET_OVERLAY)
	_drop(w)
	var w2 := _build()
	var col2: CollisionWorld = w2["col"]
	if col2.box_count(CollisionWorld.SET_OVERLAY) != before:
		errs.append("после второй сборки коробок в оверлее %d, а было %d"
			% [col2.box_count(CollisionWorld.SET_OVERLAY), before])
	var zs2: Array = GameData.site().get("ZONES", [])
	for id: String in ZONE_IDS:
		var n2 := 0
		for z: Dictionary in zs2:
			if String(z.get("id", "")) == id:
				n2 += 1
		if n2 != 1:
			errs.append("после второй сборки зон «%s»: %d" % [id, n2])
	_drop(w2)

	if errs.is_empty():
		print("test_outskirts_room: PASS")
		quit(0)
		return
	print("FAIL test_outskirts_room: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ------------------------------------------------------------- проходы ----

func _walk(col: CollisionWorld, route: Array, tag: String, errs: Array[String]) -> void:
	var stuck := 0
	var first := ""
	for i in route.size() - 1:
		var a: Vector2 = route[i]
		var c: Vector2 = route[i + 1]
		var n := maxi(1, int(a.distance_to(c) / 0.12))
		for k in n + 1:
			var p := a.lerp(c, float(k) / float(n))
			var hit := col.capsule_hit_d(p.x, R + 0.02, p.y, p.x, CAP_TOP, p.y, R, MASK)
			# ЦЕЛИКОМ ВНУТРИ коробки капсула не даёт удара вовсе: разрешение
			# идёт по граням, а ни одной грани отрезок не пересекает. Сплошной
			# амбар в этом месте читался бы как открытый двор, поэтому к
			# капсуле добавлена проба точкой — она про вложенность, а не про
			# пересечение.
			if hit.is_empty() and col.point_hit(p.x, 0.90, p.y, MASK):
				hit = {"depth": 0.0, "inside": true}
			if not hit.is_empty():
				stuck += 1
				if first == "":
					first = "[%.2f, %.2f] на %.2f м" % [p.x, p.y, float(hit.get("depth", 0.0))]
	if stuck > 0:
		errs.append("%s: проход перекрыт в %d точках, первая %s" % [tag, stuck, first])
	else:
		print("%s: проход чист" % tag)


func _blocked(col: CollisionWorld, route: Array) -> bool:
	for i in route.size() - 1:
		var a: Vector2 = route[i]
		var c: Vector2 = route[i + 1]
		var n := maxi(1, int(a.distance_to(c) / 0.12))
		for k in n + 1:
			var p := a.lerp(c, float(k) / float(n))
			if not col.capsule_hit_d(p.x, R + 0.02, p.y, p.x, CAP_TOP, p.y, R, MASK).is_empty():
				return true
			if col.point_hit(p.x, 0.90, p.y, MASK):
				return true
	return false


# Есть ли рядом с предметом место, где игрок помещается. Шестнадцать румбов
# на трёх расстояниях: ближе 0.55 м капсула вечно в самом предмете, дальше
# 1.4 м до него уже не дотянуться.
func _reach(col: CollisionWorld, nodes: Dictionary, id: String, errs: Array[String]) -> void:
	var n: Variant = nodes.get(id)
	if n == null:
		errs.append("узла «%s» нет вовсе" % id)
		return
	var at: Vector3 = (n as Node3D).position
	for ri in 3:
		var rad := 0.55 + 0.42 * float(ri)
		for ai in 16:
			var ang := TAU * float(ai) / 16.0
			var x := at.x + rad * cos(ang)
			var z := at.z + rad * sin(ang)
			if col.point_hit(x, 0.90, z, MASK):
				continue
			if col.capsule_hit_d(x, R + 0.02, z, x, CAP_TOP, z, R, MASK).is_empty():
				var fl := col.ray_down(x, 1.8, z, MASK)
				if not fl.is_empty() and absf(float(fl["y"])) < 0.30:
					print("%s: подойти можно (%.2f м)" % [id, rad])
					return
	errs.append("к «%s» [%.2f, %.2f] негде подойти: капсула не помещается "
		% [id, at.x, at.z] + "нигде в круге 1.4 м")


# ------------------------------------------------------------ служебное ----

func _build() -> Dictionary:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	return {"col": col, "root": root, "built": built}


func _drop(w: Dictionary) -> void:
	(w["root"] as Node3D).free()

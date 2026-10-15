# Проходимость карты ЧЕСТНО: заливка тем же телом и по тем же правилам, по
# которым ходит игрок (фаза 16).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ТЕСТ, КОГДА ЕСТЬ audit_reach.
#
# audit_reach — порт браузерного инструмента, и он сознательно заливает уровень
# по ТРЁМ паритетным наборам, без SET_OVERLAY (см. комментарий у _free там же).
# То есть он проходит сквозь стены бани, сельпо, клуба и амбара и подписывает
# проходимость там, где её нет. Плюс CLIMB у него 0.36 при пороге шага игрока
# 0.25: коробка высотой 0.30 для него ступенька, для игрока — стена.
#
# Здесь наоборот: маска ALL_SOLID (все четыре набора), CLIMB = Player.STEP_UP.
# Двери и ворота на время проверки открываются по id — включая створки, которые
# живут в оверлее и которых нет в built.blockers.
#
# ЧТО ИЩЕМ (три класса дефекта, каждый уже прожил по две фазы).
#
# 1. НЕДОСТИЖИМЫЕ КАРМАНЫ. Место с полом, где игрок помещается, но куда от
#    спавна не дойти. Так выглядит участок, обнесённый забором без калитки, и
#    так же выглядит проход, который перекрыли на 5 см.
# 2. ПРОСВЕТЫ УЖЕ 0.9 м. Капсула радиуса 0.30 в щель 0.40 не лезет, а глазом
#    щель читается проходом — игрок идёт в обход и считает это багом. Проверка:
#    помещается ли в клетке капсула радиуса 0.45.
# 3. КОРОБКИ С ВЕРХОМ В (0.25, 0.40]. Нога не заносится, а выглядит ступенькой:
#    берма ямы, грядка, куча шифера. Самый обидный класс — игрок видит, что
#    там пройти можно, и не проходит.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_reachable.gd
extends SceneTree

const R := 0.30              # радиус капсулы игрока (player.gd RADIUS)
const H := 1.78              # рост
const WIDE := 0.45           # половина «нормального» просвета 0.90 м
const STEP := 0.25           # шаг сетки заливки
const CLIMB := 0.25          # player.gd STEP_UP — ровно он, а не 0.36
const DROP := 1.40
const LIMIT := 900000        # предохранитель: карта фазы 16 втрое больше прежней
const SHOW := 24

const NO_FLOOR := -1.0e30
const DIRS := [[STEP, 0.0], [-STEP, 0.0], [0.0, STEP], [0.0, -STEP]]
const REACH := [1, 2]
const OFFS := [[0.0, 0.0], [0.6, 0.0], [-0.6, 0.0], [0.0, 0.6], [0.0, -0.6]]

# Рамка заливки. Расширена под СНТ фазы 16: район уходит на север до z = -62,
# за ним лес. Со старой рамкой (-35.4) всё новое отчиталось бы как «не
# достигнуто» — не потому, что туда не дойти, а потому, что дальше не смотрели.
const X0 := -64.0
const X1 := 64.0
const Z0 := -76.0
const Z1 := 32.0

# Створки, живущие в SET_OVERLAY под своим id: в built.blockers их нет,
# тумблер col.set_blocker_active обходит все четыре набора.
const OVERLAY_DOORS := ["door-shop", "door-boarded", "door-cellar-shed", "door-pump",
	"door-office"]

# Известные тесные места, признанные допустимыми. Прямоугольник по XZ + причина.
# Всё, что тесно ВНЕ этого списка, валит прогон.
#
# Правило приёма в список: место тесное по замыслу (проход между мебелью,
# лестничный марш, чердачный лаз), игрок в нём не застревает и обход у него
# есть. Улица, двор, огород и любой маршрут задания в список не принимаются.
const TIGHT_ALLOW := [
	# Дом игрока: комнаты обставлены, и проходы между тумбой и столом там
	# узкие по замыслу — так же, как в браузерном оригинале. Сама мебель —
	# паритетные коллайдеры реквизита (те самые 83), двигать их нечем.
	[-9.0, 9.0, 2.0, 17.0, "дом игрока: мебель, паритетные коллайдеры"],
	# Лестница и площадка мансарды: марш шириной 0.9 по site.json STAIRS.
	[-9.0, 9.0, 5.0, 12.0, "лестница и мансарда"],
	# Погреб — банки на стеллажах прототипа, там тесно по замыслу.
	[-9.5, 3.5, 3.0, 17.0, "погреб: паритетные стеллажи прототипа"],
	# ФЕРМА. Амбар, силос, навес, курятник и два прясла стоят в 11 x 9 м, и
	# между ними остаются карманы 0.6-0.8 м. Маршрута через них нет: во двор
	# входят с юга, ворота амбара тоже на юге, а это глухие тупики за
	# постройками. Развести их некуда — двор упирается в соседний участок.
	[-34.0, -29.0, -33.5, -24.5, "ферма: тупики между постройками"],
	# БАНЯ И СОРТИР. Просвет 0.75 м между срубом (x до 7.30 с цоколем) и
	# стеной туалета (x с 8.0). Стены туалета — site.json ROOMS/WALLS, то есть
	# паритетная статика: сдвинуть их значит переписать 311 коробок и эталон,
	# снять который нечем. 0.75 больше капсулы 0.60, игрок проходит.
	[6.9, 8.3, 20.0, 22.2, "баня и туалет: паритетные стены прототипа"],
	# СТОЛБ ЛЭП НАПРОТИВ ВОРОТ. 0.85 м между столбом (site.json POLES, z -0.9)
	# и забором участка. Оба паритетные: столб уходит в 311 через
	# world_builder.poles(), забор — через site.json FENCES. Прочие пять
	# столбов стоят у южного борта улицы, и там борт отодвинут (фаза 16).
	[8.4, 9.6, -1.6, 0.6, "столб у ворот: паритетные столб и забор"],
]

# Низкие коробки, признанные допустимыми: их верх попал в (0.25, 0.40], но
# перешагивать их и не надо — они стоят там, где игрок не ходит.
const LOW_ALLOW := [
	[-9.0, 9.0, 2.0, 14.0, "дом игрока: пороги и цоколь мебели"],
	# ПАРИТЕТ. Коллайдеры реквизита — те самые 83 коробки, которые сверяет
	# test_world_parity по parity/world_boxes.json, а через них считается
	# parity/probes.json. Изменить высоту грядки на 0.20 значит сдвинуть
	# мультимножество AABB и переписать эталон, снять который нечем: браузерный
	# прототип не перевыпускается. Грядки остаются такими, какими они в
	# оригинале и были, и это осознанная плата, а не просмотр.
	[-3.3, -1.9, 17.7, 23.5, "грядка запада: паритетный коллайдер прототипа"],
	[0.7, 2.1, 17.7, 23.5, "грядка востока: паритетный коллайдер прототипа"],
	[-8.0, -6.4, 18.5, 24.0, "грядка теплицы: паритетный коллайдер прототипа"],
	[1.2, 2.0, 14.8, 15.6, "тумба в сарае: паритетный коллайдер прототипа"],
	[-5.5, 4.3, 15.8, 16.2, "порожек огорода: паритетная статика прототипа"],
]

# Карманы, признанные допустимыми: место с полом, куда игрок не ходит и ходить
# не должен. Прямоугольник по XZ + причина.
const POCKET_ALLOW := [
	# Земля ЗА бортами улицы (street.json BORDERS.west/east лежат на |x| 45.2…45.6).
	# Подложка грунта уходит дальше борта, чтобы край карты не читался
	# чёрным провалом, — но выходить туда игроку и не полагается.
	[-64.0, -45.2, -76.0, 32.0, "за западным бортом улицы"],
	[45.2, 64.0, -76.0, 32.0, "за восточным бортом улицы"],
]

var _col: CollisionWorld
var _cx: PackedFloat64Array = PackedFloat64Array()
var _cz: PackedFloat64Array = PackedFloat64Array()
var _cy: PackedFloat64Array = PackedFloat64Array()
var _seen: Dictionary = {}


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()

	var mats := Materials.new()
	mats.load_all()
	_col = CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, _col)

	var pdata := GameData.props()
	var props := Props.new(mats)
	var all_defs: Array = []
	all_defs.append_array(pdata["PROPS"])
	all_defs.append_array(pdata["DYNAMIC_PROPS"])
	props.load_models(all_defs)
	props.build(root, pdata["PROPS"], _col)
	props.build_dynamic(pdata["DYNAMIC_PROPS"])
	props.rebuild_collision(_col)

	# Двери на время проверки открыты: нас интересует геометрия, а не запертость.
	# Состояние возвращается — навграф деда читает активность блокеров живьём.
	var saved: Dictionary = {}
	for b: Dictionary in built["blockers"]:
		var bid := String(b["id"])
		saved[bid] = _col.is_blocker_active(bid)
		_col.set_blocker_active(bid, false)
	for bid: String in OVERLAY_DOORS:
		saved[bid] = _col.is_blocker_active(bid)
		_col.set_blocker_active(bid, false)

	var limit_hit := _flood()
	var tight := _tight_spots()
	var low := _low_boxes()
	var pockets := _pockets()

	for bid: String in saved.keys():
		_col.set_blocker_active(bid, bool(saved[bid]))

	print("клеток залито: %d%s" % [_cx.size(), " (упёрлись в лимит)" if limit_hit else ""])
	_dump("тесные места (просвет < 0.90 м)", tight)
	_dump("низкие коробки, верх в (0.25, 0.40]", low)
	_dump("недостижимые карманы", pockets)
	print("время: %d мс" % (Time.get_ticks_msec() - t0))

	props.dispose()
	root.free()

	var bad := tight.size() + low.size() + pockets.size()
	if bad == 0 and not limit_hit:
		print("test_reachable: PASS")
		quit(0)
		return
	printerr("test_reachable: FAIL (тесных %d, низких %d, карманов %d%s)"
		% [tight.size(), low.size(), pockets.size(),
			", заливка упёрлась в лимит" if limit_hit else ""])
	quit(1)


func _dump(tag: String, rows: Array) -> void:
	print("%s: %d" % [tag, rows.size()])
	var shown := 0
	for r: String in rows:
		if shown >= SHOW:
			break
		shown += 1
		printerr("  · " + r)
	if rows.size() > SHOW:
		printerr("  … и ещё %d" % (rows.size() - SHOW))


# ------------------------------------------------------------- заливка ----

# Пол под точкой по ВСЕМ четырём наборам сразу: второй этаж, плита околицы и
# земля деревни живут в оверлее, и заливка по одной статике их не видит.
func _floor_at(x: float, z: float, from_y: float) -> float:
	var hit := _col.ray_down(x, from_y, z, CollisionWorld.ALL_SOLID)
	if hit.is_empty():
		return NO_FLOOR
	return float(hit["y"])


# Помещается ли капсула радиуса rad ногами на (x, z, feet_y).
func _fits(x: float, z: float, feet_y: float, rad: float) -> bool:
	var sy := feet_y + rad + 0.03
	var ey := feet_y + H - rad
	if ey <= sy:
		return false
	# ЦЕЛИКОМ ВНУТРИ коробки капсула не даёт удара вовсе: разрешение идёт по
	# граням, а ни одной грани отрезок не пересекает. Без этой пробы заливка
	# проходит сквозь стену толще 60 см и объявляет проходимым нутро сруба
	# (грабля из test_outskirts_room, там она уже поймана).
	if _col.point_hit(x, feet_y + 0.90, z, CollisionWorld.ALL_SOLID):
		return false
	for set_id: int in [CollisionWorld.MASK_STATIC, CollisionWorld.MASK_PROPS,
			CollisionWorld.MASK_BLOCKERS, CollisionWorld.MASK_OVERLAY]:
		var hit := _col.capsule_hit_d(x, sy, z, x, ey, z, rad, set_id)
		if hit.is_empty():
			continue
		# Пол под ногами капсулу тоже задевает — стену отличаем по наклону
		# нормали, ровно как audit_reach и оригинал.
		if float(hit["depth"]) > 0.06 and absf(float(hit["ny"])) < 0.5:
			return false
	return true


func _flood() -> bool:
	var site := GameData.site()
	var start: Array = site["SPAWN"]["start"]["pos"]
	var sx := float(start[0])
	var sy := float(start[1])
	var sz := float(start[2])

	var portals: Array = []
	for h: Dictionary in site["HATCHES"]:
		portals.append([h["top"], h["bottom"]])
		portals.append([h["bottom"], h["top"]])

	_cx = PackedFloat64Array()
	_cz = PackedFloat64Array()
	_cy = PackedFloat64Array()
	_seen = {}
	_cx.append(sx); _cz.append(sz); _cy.append(sy)
	_seen[_key(sx, sz, sy)] = true

	var head := 0
	var expanded := 0
	while head < _cx.size() and expanded < LIMIT:
		var x := _cx[head]
		var z := _cz[head]
		var y := _cy[head]
		head += 1
		expanded += 1

		for dd: Array in DIRS:
			var dx: float = dd[0]
			var dz: float = dd[1]
			for reach: int in REACH:
				var nx := _fix3(x + dx * reach)
				var nz := _fix3(z + dz * reach)
				if nx < X0 or nx > X1 or nz < Z0 or nz > Z1:
					break
				var fy := _floor_at(nx, nz, y + 0.55)
				if fy == NO_FLOOR:
					continue
				if fy - y > CLIMB or y - fy > DROP:
					break
				_push(nx, nz, fy)
				break

		for p: Array in portals:
			var fr: Array = p[0]
			var to: Array = p[1]
			if absf(float(fr[0]) - x) > 0.8 or absf(float(fr[2]) - z) > 0.8 \
					or absf(float(fr[1]) - y) > 1.0:
				continue
			for off: Array in OFFS:
				var tx := _fix3(_snap(float(to[0]) + float(off[0]), sx))
				var tz := _fix3(_snap(float(to[2]) + float(off[1]), sz))
				var fy2 := _floor_at(tx, tz, float(to[1]) + 0.55)
				if fy2 == NO_FLOOR or absf(fy2 - float(to[1])) > 0.4:
					continue
				_push(tx, tz, fy2)

	return expanded >= LIMIT


func _push(nx: float, nz: float, fy: float) -> void:
	var k := _key(nx, nz, fy)
	if _seen.has(k):
		return
	if not _fits(nx, nz, fy, R):
		return
	_seen[k] = true
	_cx.append(nx)
	_cz.append(nz)
	_cy.append(fy)


func _key(x: float, z: float, y: float) -> Vector3i:
	return Vector3i(_jround(x / STEP), _jround(z / STEP), _jround(y / 0.5))


func _snap(v: float, base: float) -> float:
	return base + _jround((v - base) / STEP) * STEP


func _jround(v: float) -> int:
	return int(floor(v + 0.5))


func _fix3(v: float) -> float:
	return snappedf(v, 0.001)


# ---------------------------------------------------------- три отчёта ----

# 1. Тесные места. Мерить «капсула 0.45 не лезет» нельзя: она не лезет и в
# полуметре от одной-единственной стены посреди открытой улицы, а это не щель.
# Щель — это ДВЕ преграды напротив друг друга, и мерить надо просвет между
# ними: от клетки шагаем в четыре стороны на уровне пояса до первой преграды и
# складываем встречные плечи. Открытая сторона (преграды нет в пределах SPAN)
# щелью не считается никогда.
const PROBE_Y := 0.90         # уровень пояса: там, где капсула шире всего
const PROBE_STEP := 0.05
const PROBE_SPAN := 1.60      # дальше не смотрим: просвет 3.2 м — уже улица
const GAP_MIN := 0.90         # ниже этого проход читается щелью


func _tight_spots() -> Array:
	var spots: Dictionary = {}
	for i in _cx.size():
		var x := _cx[i]
		var z := _cz[i]
		var y := _cy[i]
		# Дешёвый отсев: где помещается капсула 0.45, там просвет заведомо
		# не меньше 0.90 — маршировать незачем.
		if _fits(x, z, y, WIDE):
			continue
		if _in_rects(x, z, TIGHT_ALLOW):
			continue
		var gap := minf(_span(x, z, y, 1.0, 0.0), _span(x, z, y, 0.0, 1.0))
		if gap >= GAP_MIN:
			continue
		var k := Vector2i(_jround(x), _jround(z))
		if not spots.has(k) or gap < float((spots[k] as Array)[3]):
			spots[k] = [x, z, y, gap]
	var out: Array = []
	for k: Vector2i in spots.keys():
		var s: Array = spots[k]
		out.append("просвет %.2f м у [%.2f, %.2f] (пол %.2f)"
			% [float(s[3]), float(s[0]), float(s[1]), float(s[2])])
	out.sort()
	return out


# Просвет по одной оси: плечо в плюс плюс плечо в минус. Если хоть одно плечо
# упёрлось в SPAN не встретив преграды — сторона открыта, просвета нет.
func _span(x: float, z: float, y: float, ax: float, az: float) -> float:
	var py := y + PROBE_Y
	var total := 0.0
	for sgn: float in [1.0, -1.0]:
		var d := PROBE_STEP
		var hit := false
		while d <= PROBE_SPAN:
			if _col.point_hit(x + ax * sgn * d, py, z + az * sgn * d, CollisionWorld.ALL_SOLID):
				hit = true
				break
			d += PROBE_STEP
		if not hit:
			return 1e9
		total += d
	return total


# 2. Коробки, верх которых попал между порогом шага и «уже не ступенька».
# Смотрим только те, что стоят на земле (низ ниже 0.10) и попадают в рамку
# карты: перекрытие второго этажа с таким верхом ничего не значит.
func _low_boxes() -> Array:
	var out: Array = []
	var seen: Dictionary = {}
	for set_id in CollisionWorld.SET_COUNT:
		for i in _col.box_count(set_id):
			if not _col.is_box_active(set_id, i):
				continue
			var a := _col.box_aabb_d(set_id, i)
			var top: float = a[4]
			if top <= CLIMB + 0.001 or top > 0.40:
				continue
			if a[1] > 0.10:
				continue
			var cx: float = (a[0] + a[3]) * 0.5
			var cz: float = (a[2] + a[5]) * 0.5
			if cx < X0 or cx > X1 or cz < Z0 or cz > Z1:
				continue
			if _in_rects(cx, cz, LOW_ALLOW):
				continue
			# Коробка имеет значение только если рядом ходят: иначе это цоколь
			# постройки, о который игрок и не должен спотыкаться.
			if not _walked_near(cx, cz, 1.2):
				continue
			var k := "%.2f|%.2f|%.2f" % [cx, cz, top]
			if seen.has(k):
				continue
			seen[k] = true
			out.append("верх %.2f м у [%.2f, %.2f] (набор %d, %.2f x %.2f)"
				% [top, cx, cz, set_id, a[3] - a[0], a[5] - a[2]])
	out.sort()
	return out


# 3. Карманы: место с полом, где капсула помещается, но заливка туда не пришла.
# Ищем по редкой сетке в полметра и только на уровне земли — крыши, чердаки и
# нутро запаянных коробок карманами не считаются.
const POCKET_STEP := 0.5
const POCKET_MIN := 16          # клеток в пятне (4 м²): меньше — щель, не карман


func _pockets() -> Array:
	var walked: Dictionary = {}
	for i in _cx.size():
		walked[Vector2i(_jround(_cx[i] / POCKET_STEP), _jround(_cz[i] / POCKET_STEP))] = true

	var free_cells: Dictionary = {}
	var ix0 := _jround(X0 / POCKET_STEP)
	var ix1 := _jround(X1 / POCKET_STEP)
	var iz0 := _jround(Z0 / POCKET_STEP)
	var iz1 := _jround(Z1 / POCKET_STEP)
	for ix in range(ix0, ix1 + 1):
		for iz in range(iz0, iz1 + 1):
			var k := Vector2i(ix, iz)
			if walked.has(k):
				continue
			var x := ix * POCKET_STEP
			var z := iz * POCKET_STEP
			var fy := _floor_at(x, z, 2.4)
			# Пол выше порога шага над землёй — это ВЕРХ ПРЕПЯТСТВИЯ, а не
			# карман: крышка грядки, куча, поленница. Туда и не надо.
			if fy == NO_FLOOR or fy < -0.60 or fy > CLIMB:
				continue
			if not _fits(x, z, fy, R):
				continue
			if _in_rects(x, z, POCKET_ALLOW):
				continue
			free_cells[k] = Vector3(x, fy, z)

	# Склейка в пятна: обычная волна по четырём соседям.
	var out: Array = []
	var used: Dictionary = {}
	for k: Vector2i in free_cells.keys():
		if used.has(k):
			continue
		var queue: Array[Vector2i] = [k]
		used[k] = true
		var cells: Array[Vector2i] = []
		while not queue.is_empty():
			var c: Vector2i = queue.pop_back()
			cells.append(c)
			for d: Vector2i in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n := c + d
				if used.has(n) or not free_cells.has(n):
					continue
				used[n] = true
				queue.append(n)
		if cells.size() < POCKET_MIN:
			continue
		var p: Vector3 = free_cells[cells[0]]
		out.append("карман [%.2f, %.2f] (пол %.2f), клеток %d (%.1f м²)"
			% [p.x, p.z, p.y, cells.size(), cells.size() * POCKET_STEP * POCKET_STEP])
	out.sort()
	return out


# Ходил ли кто-то в метре от точки. Перебирать все залитые клетки на каждую
# коробку — это сотня миллионов сравнений; клетки один раз сводятся в решётку
# по метру, дальше смотрим девять ячеек вокруг.
func _walked_near(x: float, z: float, _rad: float) -> bool:
	if _walk_grid.is_empty():
		for i in _cx.size():
			_walk_grid[Vector2i(_jround(_cx[i]), _jround(_cz[i]))] = true
	var cx := _jround(x)
	var cz := _jround(z)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			if _walk_grid.has(Vector2i(cx + dx, cz + dz)):
				return true
	return false


var _walk_grid: Dictionary = {}


func _in_rects(x: float, z: float, rects: Array) -> bool:
	for r: Array in rects:
		if x >= float(r[0]) and x <= float(r[1]) and z >= float(r[2]) and z <= float(r[3]):
			return true
	return false

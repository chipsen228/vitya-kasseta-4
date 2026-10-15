# Аудит проходимости уровня: порт tools/audit-reach.js.
#
# Уровень заливается «водой» из точки старта тем же телом, каким ходит игрок
# (капсула 0.30 x 1.78), и по залитым клеткам считается, куда игрок дойдёт.
# Двери и ворота на время проверки открываются: нас интересует геометрия,
# а не запертость. Проверок две, обе как в оригинале:
#   · все ZONES посещены хотя бы одной клеткой;
#   · до каждой точки взаимодействия можно дотянуться с проходимой клетки —
#     в радиусе дескриптора и по прямой видимости (луч по статике мира).
#
# Связность навграфа и патруль деда сюда НЕ входят: это инварианты audit_nav.
# Навграф здесь не строится вовсе — оригинал заливает уровень капсулой, а не
# ходит по узлам, и лишняя выпечка графа только увеличила бы время прогона.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/audit_reach.gd

extends SceneTree

const R := 0.30              # радиус капсулы игрока
const H := 1.78              # рост
const EYE := 1.68            # глаза
const STEP := 0.25           # шаг сетки
# На сколько шагаем вверх за клетку. ФАЗА 16: было 0.36 — число из браузерного
# инструмента. Порог шага игрока в порту другой и лежит в player.gd:
# STEP_UP = 0.25. С 0.36 аудит перешагивал берму погоста (0.26), грядку (0.40)
# и кучу шифера (0.40) и подписывал проходимость там, где игрок упирается ногой.
const CLIMB := 0.25
const DROP := 1.40           # насколько готовы спрыгнуть
const LIMIT := 400000        # предохранитель заливки
const SHOW := 20             # сколько проблем печатать

# Пола нет — отдельным числом, чтобы не разводить NAN по сравнениям.
const NO_FLOOR := -1.0e30

const DIRS := [[STEP, 0.0], [-STEP, 0.0], [0.0, STEP], [0.0, -STEP]]
const REACH := [1, 2]
# Выход из люка: сам люк и четыре клетки вокруг — так же, как игрок
# ставит ногу на край проёма.
const OFFS := [[0.0, 0.0], [0.6, 0.0], [-0.6, 0.0], [0.0, 0.6], [0.0, -0.6]]

# Эти цели достигаются не стоящим на статическом полу телом Player, а камерой
# эксклюзивного runtime-эпизода. Сам вход в каждый переход (bathloft и нижняя
# лестница mill-ladder-lower) остаётся в обычном аудите и обязан быть достижим.
const RUNTIME_CAMERA_TARGETS := {
	"bathloft-cassette": true,
	"bathloft-exit": true,
	"mill-wheel": true,
	"mill-ladder-upper": true,
	"mill-journal": true,
	"mill-down-upper": true,
	"mill-down-lower": true,
}

var _col: CollisionWorld
var _zone_at: Callable

# Статика мира для луча видимости. Своего луча произвольного направления у
# CollisionWorld нет (только ray_down), поэтому коробки читаются напрямую:
# раскладка STRIDE описана в collision_world.gd (смещения 6..13 — ось, угол,
# центр, полуразмер). Публичный box_aabb_d() тут не годится: он отдаёт мировой
# AABB, а скаты крыши и пандусы лестниц повёрнуты, и их AABB закрыл бы обзор
# там, где в оригинале луч проходит между треугольниками ската.
var _sdata: PackedFloat64Array = PackedFloat64Array()
var _sact: PackedByteArray = PackedByteArray()

# Залитые клетки: x, z, y ног. Порядок — порядок обхода, как у seen.values().
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
	_zone_at = built["zone_at"]

	# Реквизит ставится как в main.js: сначала статика, потом невидимый
	# реквизит глав, потом общая пересборка коллизии. Пересборка обязательна:
	# коллайдеры динамических предметов в оригинале тоже лежат в props.octree.
	var pdata := GameData.props()
	var props := Props.new(mats)
	var all_defs: Array = []
	all_defs.append_array(pdata["PROPS"])
	all_defs.append_array(pdata["DYNAMIC_PROPS"])
	props.load_models(all_defs)
	props.build(root, pdata["PROPS"], _col)
	props.build_dynamic(pdata["DYNAMIC_PROPS"])
	props.rebuild_collision(_col)

	# Список целей собирается до заливки: registerObjects() тяжёлого ничего не
	# делает, зато при поломке в interact.gd прогон падает сразу, а не через
	# минуту заливки.
	var targets := _targets(props, built)

	# Двери и ворота на время проверки не в счёт — но состояние надо ВЕРНУТЬ:
	# навграф читает активность блокеров живьём, и сессия, где прогнали аудит,
	# иначе считает все двери открытыми.
	var saved: Dictionary = {}
	for b: Dictionary in built["blockers"]:
		var bid := String(b["id"])
		saved[bid] = _col.is_blocker_active(bid)
		_col.set_blocker_active(bid, false)
	# Двери четвёртого набора — те же двери. В built["blockers"] их нет: они
	# живут в SET_OVERLAY и гасятся по id тем же тумблером (он обходит все
	# четыре набора). Без этой пятёрки заливка упирается в запертую створку
	# и объявляет недостижимым всё, что за ней, — то есть сельпо, погреб,
	# заколоченный дом и водокачку.
	for bid: String in ["door-shop", "door-boarded", "door-cellar-shed",
			"door-pump"]:
		saved[bid] = _col.is_blocker_active(bid)
		_col.set_blocker_active(bid, false)

	_sdata = _col._data[CollisionWorld.SET_STATIC]
	_sact = _col._active[CollisionWorld.SET_STATIC]

	var res := _report(targets)

	for bid: String in saved.keys():
		_col.set_blocker_active(bid, bool(saved[bid]))

	var missing: Array = res["missingZones"]
	var unreachable: Array = res["unreachable"]
	var reached: Array = res["zones"]
	var limit_note := " (упёрлись в лимит)" if bool(res["limitHit"]) else ""
	var zones_line := ", ".join(PackedStringArray(reached))
	var missing_line := ", ".join(PackedStringArray(missing))
	if missing.is_empty():
		missing_line = "—"

	print("клеток: %d%s" % [_cx.size(), limit_note])
	print("зоны достигнуты: %s" % zones_line)
	print("зоны НЕ достигнуты: %s" % missing_line)
	print("недостижимо целей: %d из %d" % [unreachable.size(), targets.size()])
	var shown := 0
	for u: Dictionary in unreachable:
		if shown >= SHOW:
			break
		shown += 1
		var p: Vector3 = u["pos"]
		printerr("  · %s [%s] [%.2f, %.2f, %.2f] r=%s"
			% [u["id"], u["kind"], p.x, p.y, p.z, u["r"]])
	if unreachable.size() > SHOW:
		printerr("  … и ещё %d" % (unreachable.size() - SHOW))
	print("время: %d мс" % (Time.get_ticks_msec() - t0))

	props.dispose()
	root.free()

	if missing.is_empty() and unreachable.is_empty():
		print("audit_reach: PASS")
		quit(0)
	else:
		printerr("audit_reach: FAIL (зон без клеток %d, недостижимых целей %d)"
			% [missing.size(), unreachable.size()])
		quit(1)


# ---------- пробы ----------

# Первая поверхность под точкой. Только статика мира: реквизит полом не считается,
# в оригинале floorAt() ходит по app.world.octree.
func _floor_at(x: float, z: float, from_y: float) -> float:
	var hit := _col.ray_down(x, from_y, z, CollisionWorld.MASK_STATIC)
	# ФАЗА 14. Четвёртый набор — тоже пол. С фазы 11 всё, что строится поверх
	# принятого мира, обязано лежать в SET_OVERLAY: 311/4/83 иначе вырастет.
	# Пол бани, погреба, сельпо, второго этажа красного дома и вся земля
	# околицы — оттуда, и заливка по одной статике просто не находила под
	# ними опоры. Десять зон подряд «не достигнуты» — это был не отчёт
	# о дыре, это была слепота инструмента.
	if hit.is_empty():
		hit = _col.ray_down(x, from_y, z, CollisionWorld.MASK_OVERLAY)
	else:
		# Пол есть и в статике, и в оверлее — берём ВЕРХНИЙ: второй этаж
		# лежит над первым, и провалиться сквозь него игрок не может.
		var soft := _col.ray_down(x, from_y, z, CollisionWorld.MASK_OVERLAY)
		if not soft.is_empty() and float(soft["y"]) > float(hit["y"]):
			hit = soft
	if hit.is_empty():
		return NO_FLOOR
	return float(hit["y"])


# Помещается ли игрок ногами на (x, z, feet_y). Пол под ногами капсулу тоже
# «задевает» — стены отличаем по наклону нормали, как в оригинале.
func _free(x: float, z: float, feet_y: float) -> bool:
	var sy := feet_y + R + 0.03
	var ey := feet_y + H - R
	# Наборы опрашиваются по отдельности: это три октодерева оригинала.
	#
	# ЧЕТВЁРТОГО ЗДЕСЬ НЕТ, И ЭТО ЗНАЮТ. Заливка проходит сквозь стены бани,
	# сельпо, амбара и клуба — то есть отвечает на вопрос «есть ли до цели
	# пол», а не «можно ли до неё дойти». Проверено: включение MASK_OVERLAY
	# в эту строку немедленно отрезает правление, потому что вместе со
	# стенами становятся твёрдыми и створки, которых нет в built.blockers.
	# Разбирать это по одной двери — работа отдельной фазы, а настоящую
	# проходимость новых помещений и так меряют _walk()/_reach() в
	# test_outskirts_room.gd, test_village_room.gd и test_yard_room.gd:
	# там капсула идёт по маршруту, а не заливает объём.
	for mask: int in [CollisionWorld.MASK_STATIC, CollisionWorld.MASK_PROPS,
			CollisionWorld.MASK_BLOCKERS]:
		var hit := _col.capsule_hit_d(x, sy, z, x, ey, z, R, mask)
		if hit.is_empty():
			continue
		# Порог по наклону нормали: пол — это 1.0, стена — около нуля, а 0.5…0.8
		# даёт ребро низкой ступеньки, которую капсула переезжает.
		if float(hit["depth"]) > 0.06 and absf(float(hit["ny"])) < 0.5:
			return false
	return true


# Видна ли точка из глаз, или между ними стена, пол, перекрытие.
func _visible(ex: float, ey: float, ez: float, tx: float, ty: float, tz: float) -> bool:
	var dx := tx - ex
	var dy := ty - ey
	var dz := tz - ez
	var len_v := sqrt(dx * dx + dy * dy + dz * dz)
	if len_v <= 0.0:
		return true
	var t := _ray_static(ex, ey, ez, dx / len_v, dy / len_v, dz / len_v)
	return t < 0.0 or t > len_v - 0.15


# Луч по статике мира: расстояние до первой ЛИЦЕВОЙ грани или -1.
# Изнутри коробки луч ничего не находит (t_near < 0) — как backface culling
# у Octree.rayIntersect оригинала.
func _ray_static(ox: float, oy: float, oz: float, dx: float, dy: float, dz: float) -> float:
	var d := _sdata
	var stride := CollisionWorld.STRIDE
	var n := d.size() / stride
	var best := -1.0
	for i in n:
		if _sact[i] == 0:
			continue
		var o := i * stride
		var lx := ox - d[o + 8]
		var ly := oy - d[o + 9]
		var lz := oz - d[o + 10]
		var vx := dx
		var vy := dy
		var vz := dz
		var axis := int(d[o + 6])
		if axis != CollisionWorld.AXIS_NONE:
			var ang: float = d[o + 7]
			var ca := cos(ang)
			var sa := sin(ang)
			var lo := _to_local(axis, ca, sa, lx, ly, lz)
			var ld := _to_local(axis, ca, sa, vx, vy, vz)
			lx = lo[0]; ly = lo[1]; lz = lo[2]
			vx = ld[0]; vy = ld[1]; vz = ld[2]
		var t_near := -INF
		var t_far := INF
		var ok := true
		for a in 3:
			var oa := _comp(a, lx, ly, lz)
			var da := _comp(a, vx, vy, vz)
			var ha := _comp(a, d[o + 11], d[o + 12], d[o + 13])
			if absf(da) < 1e-12:
				if oa < -ha or oa > ha:
					ok = false
					break
				continue
			var inv := 1.0 / da
			var t1 := (-ha - oa) * inv
			var t2 := (ha - oa) * inv
			if t1 > t2:
				var tmp := t1
				t1 = t2
				t2 = tmp
			if t1 > t_near:
				t_near = t1
			if t2 < t_far:
				t_far = t2
			if t_near > t_far:
				ok = false
				break
		if not ok or t_near < 0.0 or t_near > t_far:
			continue
		if best < 0.0 or t_near < best:
			best = t_near
	return best


# Поворот мировых координат в оси коробки — та же арифметика, что в collision_world.gd.
func _to_local(axis: int, ca: float, sa: float, x: float, y: float, z: float) -> PackedFloat64Array:
	if axis == CollisionWorld.AXIS_X:
		return PackedFloat64Array([x, ca * y + sa * z, -sa * y + ca * z])
	if axis == CollisionWorld.AXIS_Y:
		return PackedFloat64Array([ca * x - sa * z, y, sa * x + ca * z])
	if axis == CollisionWorld.AXIS_Z:
		return PackedFloat64Array([ca * x + sa * y, -sa * x + ca * y, z])
	return PackedFloat64Array([x, y, z])


func _comp(a: int, x: float, y: float, z: float) -> float:
	if a == 0:
		return x
	if a == 1:
		return y
	return z


# ---------- заливка ----------

# Заливка проходимых клеток из точки старта. Люки работают как порталы.
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
				# ФАЗА 14 отодвинула северную границу с -16 на -35.4: мир
				# кончался за обочиной улицы, а теперь за ней два переулка,
				# вторая линия и семь участков околицы. Со старым числом
				# заливка упиралась в невидимую рамку на z = -16 и объявляла
				# «не достигнуты» девять зон подряд — не потому, что туда
				# не дойти, а потому, что дальше она не смотрела.
				# ФАЗА 16 отодвинула северную границу ещё раз: за околицей
				# встало СНТ, оно уходит до z = -62, за ним лес. Со старой
				# рамкой (-35.4) весь новый район отчитался бы как «не
				# достигнут» — не потому, что туда не дойти, а потому, что
				# дальше заливка не смотрела.
				if nx < -64.0 or nx > 64.0 or nz < -76.0 or nz > 32.0:
					break
				var fy := _floor_at(nx, nz, y + 0.55)
				# Клетки без пола перешагиваем: капсула шире шага сетки и щель в
				# двадцать сантиметров её не останавливает. Стену так не перейти —
				# её ловит _free() внутри _push().
				if fy == NO_FLOOR:
					continue
				if fy - y > CLIMB or y - fy > DROP:
					break
				_push(nx, nz, fy)
				break

		# Люк рядом — переносим на другую его сторону. Прямо под люком пола нет
		# (там дыра в перекрытии), поэтому вылезаем на ближайшую клетку вокруг.
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
	if not _free(nx, nz, fy):
		return
	_seen[k] = true
	_cx.append(nx)
	_cz.append(nz)
	_cy.append(fy)


# Ключ клетки: тот же, что в оригинале (шаг 0.25 по XZ, 0.5 по высоте).
func _key(x: float, z: float, y: float) -> Vector3i:
	return Vector3i(_jround(x / STEP), _jround(z / STEP), _jround(y / 0.5))


# Выход из люка приводится к той же решётке, по которой идёт заливка: иначе их
# становится две, и та фаза, что пришла первой, запирает вторую. На подходе к
# лестнице разница в пять сантиметров решает.
func _snap(v: float, base: float) -> float:
	return base + _jround((v - base) / STEP) * STEP


# Math.round из JS: половина округляется вверх, а не «от нуля».
func _jround(v: float) -> int:
	return int(floor(v + 0.5))


# Аналог (+v.toFixed(3)) оригинала: снимает дрейф сложения по сетке.
func _fix3(v: float) -> float:
	return snappedf(v, 0.001)


# ---------- отчёт ----------

func _report(targets: Array) -> Dictionary:
	var limit_hit := _flood()

	# Клетки по XZ: до цели можно дотянуться с любой высоты, где стоит игрок.
	var grid: Dictionary = {}
	for i in _cx.size():
		var k := Vector2i(_jround(_cx[i] / STEP), _jround(_cz[i] / STEP))
		var list: PackedFloat64Array = grid.get(k, PackedFloat64Array())
		list.append(_cy[i])
		grid[k] = list

	var zone_set: Dictionary = {}
	for i in _cx.size():
		var zn: Dictionary = _zone_at.call(_cx[i], _cy[i] + 0.9, _cz[i])
		if not zn.is_empty():
			zone_set[String(zn["id"])] = true

	var unreachable: Array = []
	for d: Dictionary in targets:
		if RUNTIME_CAMERA_TARGETS.has(String(d["id"])):
			continue
		var t: Vector3 = d["pos"]
		var rr := float(d["r"])
		var rad := minf(rr, 2.0)
		var ok := false
		var ix0 := _jround((t.x - rad) / STEP)
		var ix1 := _jround((t.x + rad) / STEP)
		var iz0 := _jround((t.z - rad) / STEP)
		var iz1 := _jround((t.z + rad) / STEP)
		for ix in range(ix0, ix1 + 1):
			if ok:
				break
			for iz in range(iz0, iz1 + 1):
				if ok:
					break
				var k := Vector2i(ix, iz)
				if not grid.has(k):
					continue
				var x := ix * STEP
				var z := iz * STEP
				for fy: float in grid[k]:
					var ey := fy + EYE
					var ddx := x - t.x
					var ddy := ey - t.y
					var ddz := z - t.z
					if sqrt(ddx * ddx + ddy * ddy + ddz * ddz) > rr:
						continue
					if not _visible(x, ey, z, t.x, t.y, t.z):
						continue
					ok = true
					break
		if not ok:
			unreachable.append(d)

	var zones: Array = zone_set.keys()
	zones.sort()
	var missing: Array = []
	for zn: Dictionary in GameData.site()["ZONES"]:
		var zid := String(zn["id"])
		if not zone_set.has(zid):
			missing.append(zid)

	return {
		"zones": zones,
		"missingZones": missing,
		"unreachable": unreachable,
		"limitHit": limit_hit,
	}


# ---------- цели ----------

# Список целей — тот же, что собирает игра: сюжетные дескрипторы registerObjects()
# плюс точки осмотра addLookTargets(). Оригинал читает живой app.interact.list,
# читаем и мы: ошибка в координате дескриптора обязана валить аудит, а не
# прятаться за копией таблицы, разъехавшейся с interact.gd.
#
# ctx при регистрации почти не нужен — он попадает внутрь лямбд prompt/onUse,
# а их аудит не зовёт: ему хватает id, kind, pos и радиуса. Условия when тоже
# не спрашиваются, как и в оригинале: цель, доступная лишь в своей главе,
# должна быть достижима геометрически в любой.
#
# Одно исключение — фаза 12. Точки деревни и кухни берут КООРДИНАТЫ из мира
# (built.village, built.home), и на пустом ctx их модули выходят первой строкой:
# два десятка новых целей просто не попадали в список, аудит их не мерил,
# а addLookTargets ругался «осмотр без точки» на осмотры, которые есть.
func _targets(props: Props, built: Dictionary) -> Array:
	var it := Interact.new()
	Interact.registerObjects(it, {"world": built})
	it.addLookTargets(props)
	return it.list

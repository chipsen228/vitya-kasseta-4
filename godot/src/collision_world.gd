# Свой мир коллизий: три набора коробок вместо трёх октодеревьев three.js.
#
# Почему не PhysicsServer. Оригинал считает пересечения капсулы с ТРЕУГОЛЬНИКАМИ
# через Octree.capsuleIntersect и складывает выталкивания подряд: попал в грань —
# сдвинул капсулу — проверяешь следующий треугольник. Итог одного вызова — сумма
# сдвигов, её длина и есть depth. Навграф деда (nav.js blocks) читает у этого
# результата и depth, и наклон нормали, поэтому «примерно так же» не годится:
# любая другая механика выталкивания меняет проходимость дома. Здесь та же
# арифметика, только вместо треугольников — шесть граней коробки в том же порядке,
# что их выдаёт BoxGeometry (+X, -X, +Y, -Y, +Z, -Z).
#
# Точность. Пробы навграфа попадают ровно на грани (сетка 0.5 м, стены кратны 0.1),
# и решение «касание или пересечение» упирается в последние биты double. Vector3 в
# Godot — float32, его 1e-7 здесь хватает, чтобы перевернуть вердикт, поэтому вся
# геометрия лежит в PackedFloat64Array, а счёт идёт в обычных float (double) —
# Vector3 остаётся только на границе API.

class_name CollisionWorld
extends RefCounted

enum { SET_STATIC, SET_BLOCKERS, SET_PROPS, SET_OVERLAY }

const MASK_STATIC := 1
const MASK_BLOCKERS := 2
const MASK_PROPS := 4
# Четвёртый набор (фаза 9). Улица за воротами стала твёрдой, а трогать первые
# три нельзя: их мультимножества сверяет tests/test_world_parity.gd (311/4/83),
# по ним же считается навграф деда и слепок статики в ai.gd. Поэтому у улицы
# свой набор — твёрдый для игрока (PhysicsBodies строит тела циклом по
# SET_COUNT) и невидимый для всех, кто спрашивает мир маской.
const MASK_OVERLAY := 8

# ALL — это по-прежнему ТРИ паритетных набора, и менять его нельзя: он стоит
# умолчанием у capsule_hit/ray_down, и с ним дед начал бы упираться в борта
# улицы, которых для него не существует. Кому нужен четвёртый — просит явно.
const ALL := 7
const ALL_SOLID := 15

const SET_COUNT := 4
const STRIDE := 14          # aabb(6) + ось(1) + угол(1) + центр(3) + полуразмер(3)
const CELL := 1.0           # шаг XZ-хэша, метр
const CELL_ORIGIN := 512    # смещение, чтобы ключ ячейки был неотрицательным
const CELL_SPAN := 4096
const HUGE_CELLS := 8192    # коробка шире этого — в общий список, не в сетку

const AXIS_NONE := 0
const AXIS_X := 1
const AXIS_Y := 2
const AXIS_Z := 3

# Порядок опроса наборов повторяет nav.js _clear(): мир, реквизит, блокеры.
# Оверлей стоит последним и при mask = ALL (7) не опрашивается вовсе — цикл
# отсекает его тем же `mask & (1 << set_id)`, что и остальные.
const QUERY_ORDER := [SET_STATIC, SET_PROPS, SET_BLOCKERS, SET_OVERLAY]

var _data: Array[PackedFloat64Array] = []
var _active: Array[PackedByteArray] = []
var _grid: Array[Dictionary] = []
var _huge: Array[PackedInt32Array] = []
var _dirty: Array[bool] = []
var _by_id: Array[Dictionary] = []
# Changes to any solid set invalidate cached pursuit graph edges.
var revision := 0

# Царапки, чтобы не плодить массивы в цикле проб.
var _hn_x := 0.0
var _hn_y := 0.0
var _hn_z := 0.0
var _hd := 0.0
var _p1x := 0.0
var _p1y := 0.0
var _p1z := 0.0
var _p2x := 0.0
var _p2y := 0.0
var _p2z := 0.0
var _cand: PackedInt32Array = PackedInt32Array()
# Последняя проба коснулась вырожденной конфигурации: капсула прошла ровно через
# ребро или ровно по плоскости грани. В оригинале такие точки решает шум double,
# поэтому тест проб помечает их отдельно.
var degenerate := false


func _init() -> void:
	for i in SET_COUNT:
		_data.append(PackedFloat64Array())
		_active.append(PackedByteArray())
		_grid.append({})
		_huge.append(PackedInt32Array())
		_dirty.append(true)
		_by_id.append({})


# ---------- наполнение ----------

func clear_set(set_id: int) -> void:
	revision += 1
	_data[set_id] = PackedFloat64Array()
	_active[set_id] = PackedByteArray()
	_grid[set_id] = {}
	_huge[set_id] = PackedInt32Array()
	_by_id[set_id] = {}
	_dirty[set_id] = true


func add_box(set_id: int, aabb: AABB) -> int:
	var e := aabb.end
	return add_box_d(set_id, aabb.position.x, aabb.position.y, aabb.position.z, e.x, e.y, e.z)


# Осевая коробка в двойной точности. id непустой — коробку можно гасить по имени.
func add_box_d(set_id: int, minx: float, miny: float, minz: float,
		maxx: float, maxy: float, maxz: float, id: String = "") -> int:
	var d: PackedFloat64Array = _data[set_id]
	var idx := d.size() / STRIDE
	d.append(minx); d.append(miny); d.append(minz)
	d.append(maxx); d.append(maxy); d.append(maxz)
	d.append(float(AXIS_NONE)); d.append(0.0)
	d.append((minx + maxx) * 0.5); d.append((miny + maxy) * 0.5); d.append((minz + maxz) * 0.5)
	d.append((maxx - minx) * 0.5); d.append((maxy - miny) * 0.5); d.append((maxz - minz) * 0.5)
	_data[set_id] = d
	_push_meta(set_id, idx, id)
	return idx


func add_rot_box(set_id: int, xform: Transform3D, half: Vector3) -> int:
	# Контрактный вход: поворот вокруг одной оси. Ось и угол достаём из кватерниона.
	var q := xform.basis.get_rotation_quaternion()
	var ang := q.get_angle()
	var ax := q.get_axis()
	var axis := AXIS_NONE
	if absf(ang) > 1e-9:
		var aax := absf(ax.x)
		var aay := absf(ax.y)
		var aaz := absf(ax.z)
		if aax >= aay and aax >= aaz:
			axis = AXIS_X
			ang = ang * signf(ax.x)
		elif aay >= aaz:
			axis = AXIS_Y
			ang = ang * signf(ax.y)
		else:
			axis = AXIS_Z
			ang = ang * signf(ax.z)
	var o := xform.origin
	return add_rot_box_d(set_id, o.x, o.y, o.z, half.x, half.y, half.z, axis, ang)


# Повёрнутая коробка: центр, полуразмеры в своих осях, ось и угол поворота.
func add_rot_box_d(set_id: int, cx: float, cy: float, cz: float,
		hx: float, hy: float, hz: float, axis: int, ang: float, id: String = "") -> int:
	var ca := absf(cos(ang))
	var sa := absf(sin(ang))
	var ex := hx
	var ey := hy
	var ez := hz
	match axis:
		AXIS_X:
			ey = ca * hy + sa * hz
			ez = sa * hy + ca * hz
		AXIS_Y:
			ex = ca * hx + sa * hz
			ez = sa * hx + ca * hz
		AXIS_Z:
			ex = ca * hx + sa * hy
			ey = sa * hx + ca * hy
	var d: PackedFloat64Array = _data[set_id]
	var idx := d.size() / STRIDE
	d.append(cx - ex); d.append(cy - ey); d.append(cz - ez)
	d.append(cx + ex); d.append(cy + ey); d.append(cz + ez)
	d.append(float(axis)); d.append(ang)
	d.append(cx); d.append(cy); d.append(cz)
	d.append(hx); d.append(hy); d.append(hz)
	_data[set_id] = d
	_push_meta(set_id, idx, id)
	return idx


func _push_meta(set_id: int, idx: int, id: String) -> void:
	revision += 1
	var a: PackedByteArray = _active[set_id]
	a.append(1)
	_active[set_id] = a
	if id != "":
		var m: Dictionary = _by_id[set_id]
		var list: PackedInt32Array = m.get(id, PackedInt32Array())
		list.append(idx)
		m[id] = list
	_dirty[set_id] = true


func box_count(set_id: int) -> int:
	return _data[set_id].size() / STRIDE


# Мировой AABB коробки — тестам приёмки, чтобы сверять с parity/world_boxes.json.
func box_aabb_d(set_id: int, idx: int) -> PackedFloat64Array:
	var d: PackedFloat64Array = _data[set_id]
	return d.slice(idx * STRIDE, idx * STRIDE + 6)


# Крючок lead для physics_bodies.gd: [ось, угол, центр xyz, полуразмеры xyz].
# Мирового AABB мало — скаты крыш и пандусы лестниц повёрнуты, и Jolt должен
# получить именно повёрнутый BoxShape3D, а не его объемлющую коробку.
func box_shape_d(set_id: int, idx: int) -> PackedFloat64Array:
	var d: PackedFloat64Array = _data[set_id]
	return d.slice(idx * STRIDE + 6, idx * STRIDE + STRIDE)


func is_box_active(set_id: int, idx: int) -> bool:
	return _active[set_id][idx] != 0


func set_blocker_active(id: String, active: bool) -> void:
	var changed := false
	var value := 1 if active else 0
	for set_id in SET_COUNT:
		var m: Dictionary = _by_id[set_id]
		if not m.has(id):
			continue
		var a: PackedByteArray = _active[set_id]
		for idx: int in m[id]:
			changed = changed or a[idx] != value
			a[idx] = value
		_active[set_id] = a
	if changed: revision += 1


func is_blocker_active(id: String) -> bool:
	for set_id in SET_COUNT:
		var m: Dictionary = _by_id[set_id]
		if m.has(id):
			var list: PackedInt32Array = m[id]
			if list.size() > 0:
				return _active[set_id][list[0]] != 0
	return false


# ---------- XZ-хэш ----------

func _rebuild_grid(set_id: int) -> void:
	var g: Dictionary = {}
	var huge := PackedInt32Array()
	var d: PackedFloat64Array = _data[set_id]
	var n := d.size() / STRIDE
	for i in n:
		var o := i * STRIDE
		var x0 := int(floor(d[o]))
		var z0 := int(floor(d[o + 2]))
		var x1 := int(floor(d[o + 3]))
		var z1 := int(floor(d[o + 5]))
		if (x1 - x0 + 1) * (z1 - z0 + 1) > HUGE_CELLS:
			huge.append(i)
			continue
		for cx in range(x0, x1 + 1):
			for cz in range(z0, z1 + 1):
				var key := (cx + CELL_ORIGIN) * CELL_SPAN + (cz + CELL_ORIGIN)
				var list: PackedInt32Array = g.get(key, PackedInt32Array())
				list.append(i)
				g[key] = list
	_grid[set_id] = g
	_huge[set_id] = huge
	_dirty[set_id] = false


# Кандидаты по XZ-следу капсулы. Повторы схлопываются после сортировки: одна
# коробка лежит в нескольких ячейках, а проверить её надо ровно раз — иначе
# выталкивание сложится дважды.
func _collect(set_id: int, x: float, z: float, r: float) -> void:
	if _dirty[set_id]:
		_rebuild_grid(set_id)
	_cand.clear()
	for i: int in _huge[set_id]:
		_cand.append(i)
	var g: Dictionary = _grid[set_id]
	var cx0 := int(floor(x - r))
	var cx1 := int(floor(x + r))
	var cz0 := int(floor(z - r))
	var cz1 := int(floor(z + r))
	for cx in range(cx0, cx1 + 1):
		for cz in range(cz0, cz1 + 1):
			var key := (cx + CELL_ORIGIN) * CELL_SPAN + (cz + CELL_ORIGIN)
			if not g.has(key):
				continue
			for i: int in g[key]:
				_cand.append(i)
	_cand.sort()
	var w := 0
	var prev := -1
	for k in _cand.size():
		var v := _cand[k]
		if v == prev:
			continue
		_cand[w] = v
		w += 1
		prev = v
	_cand.resize(w)


# ---------- капсула ----------

# Контрактный вход. Внутри всё равно считается в double — Vector3 только снаружи.
func capsule_hit(p0: Vector3, p1: Vector3, r: float, mask: int = ALL) -> Dictionary:
	return capsule_hit_d(p0.x, p0.y, p0.z, p1.x, p1.y, p1.z, r, mask)


# Пересечение капсулы с набором коробок. Один результат за вызов — сумма
# выталкиваний, как у Octree.capsuleIntersect: вызывающий крутит цикл до чистоты.
func capsule_hit_d(x0: float, y0: float, z0: float, x1: float, y1: float, z1: float,
		r: float, mask: int = ALL) -> Dictionary:
	degenerate = false
	var sx := x0
	var sy := y0
	var sz := z0
	var ex := x1
	var ey := y1
	var ez := z1
	var ax := 0.0
	var ay := 0.0
	var az := 0.0
	var hit := false
	for set_id: int in QUERY_ORDER:
		if (mask & (1 << set_id)) == 0:
			continue
		var d: PackedFloat64Array = _data[set_id]
		if d.is_empty():
			continue
		var act: PackedByteArray = _active[set_id]
		_collect(set_id, x0, z0, r)
		for i: int in _cand:
			if act[i] == 0:
				continue
			var o := i * STRIDE
			var loy := minf(sy, ey) - r
			var hiy := maxf(sy, ey) + r
			if d[o + 1] > hiy or d[o + 4] < loy:
				continue
			var lox := minf(sx, ex) - r
			var hix := maxf(sx, ex) + r
			if d[o] > hix or d[o + 3] < lox:
				continue
			var loz := minf(sz, ez) - r
			var hiz := maxf(sz, ez) + r
			if d[o + 2] > hiz or d[o + 5] < loz:
				continue
			var axis := int(d[o + 6])
			if axis == AXIS_NONE:
				for f in 6:
					if not _face_hit(d[o], d[o + 1], d[o + 2], d[o + 3], d[o + 4], d[o + 5],
							f, sx, sy, sz, ex, ey, ez, r):
						continue
					hit = true
					if _hd == 0.0:
						continue
					var dx := _hn_x * _hd
					var dy := _hn_y * _hd
					var dz := _hn_z * _hd
					sx += dx; sy += dy; sz += dz
					ex += dx; ey += dy; ez += dz
					ax += dx; ay += dy; az += dz
			else:
				var ang: float = d[o + 7]
				var ca := cos(ang)
				var sa := sin(ang)
				var lsx := sx - d[o + 8]
				var lsy := sy - d[o + 9]
				var lsz := sz - d[o + 10]
				var lex := ex - d[o + 8]
				var ley := ey - d[o + 9]
				var lez := ez - d[o + 10]
				var t0 := _to_local(axis, ca, sa, lsx, lsy, lsz)
				var t1 := _to_local(axis, ca, sa, lex, ley, lez)
				lsx = t0[0]; lsy = t0[1]; lsz = t0[2]
				lex = t1[0]; ley = t1[1]; lez = t1[2]
				var hx: float = d[o + 11]
				var hy: float = d[o + 12]
				var hz: float = d[o + 13]
				for f in 6:
					if not _face_hit(-hx, -hy, -hz, hx, hy, hz, f,
							lsx, lsy, lsz, lex, ley, lez, r):
						continue
					hit = true
					if _hd == 0.0:
						continue
					var lnx := _hn_x
					var lny := _hn_y
					var lnz := _hn_z
					var w := _to_world(axis, ca, sa, lnx, lny, lnz)
					lsx += lnx * _hd; lsy += lny * _hd; lsz += lnz * _hd
					lex += lnx * _hd; ley += lny * _hd; lez += lnz * _hd
					var dx := w[0] * _hd
					var dy := w[1] * _hd
					var dz := w[2] * _hd
					sx += dx; sy += dy; sz += dz
					ex += dx; ey += dy; ez += dz
					ax += dx; ay += dy; az += dz
	if not hit:
		return {}
	var depth := sqrt(ax * ax + ay * ay + az * az)
	if depth <= 0.0:
		return {"normal": Vector3.ZERO, "depth": 0.0, "ny": 0.0}
	var inv := 1.0 / depth
	return {
		"normal": Vector3(ax * inv, ay * inv, az * inv),
		"depth": depth,
		"ny": ay * inv,
	}


func _to_local(axis: int, ca: float, sa: float, x: float, y: float, z: float) -> PackedFloat64Array:
	match axis:
		AXIS_X:
			return PackedFloat64Array([x, ca * y + sa * z, -sa * y + ca * z])
		AXIS_Y:
			return PackedFloat64Array([ca * x - sa * z, y, sa * x + ca * z])
		AXIS_Z:
			return PackedFloat64Array([ca * x + sa * y, -sa * x + ca * y, z])
	return PackedFloat64Array([x, y, z])


func _to_world(axis: int, ca: float, sa: float, x: float, y: float, z: float) -> PackedFloat64Array:
	match axis:
		AXIS_X:
			return PackedFloat64Array([x, ca * y - sa * z, sa * y + ca * z])
		AXIS_Y:
			return PackedFloat64Array([ca * x + sa * z, y, -sa * x + ca * z])
		AXIS_Z:
			return PackedFloat64Array([ca * x - sa * y, sa * x + ca * y, z])
	return PackedFloat64Array([x, y, z])


# Порт triangleCapsuleIntersect на прямоугольную грань. Плоскость -> точка входа
# внутри прямоугольника -> иначе четыре ребра. Результат в царапках _hn_*/_hd.
func _face_hit(minx: float, miny: float, minz: float, maxx: float, maxy: float, maxz: float,
		face: int, sx: float, sy: float, sz: float, ex: float, ey: float, ez: float,
		r: float) -> bool:
	var ax := face >> 1              # 0:X 1:Y 2:Z — порядок граней BoxGeometry
	var pos := (face & 1) == 0       # +X, -X, +Y, -Y, +Z, -Z
	var pl := 0.0
	var sc := 0.0
	var ec := 0.0
	match ax:
		0:
			pl = maxx if pos else minx
			sc = sx
			ec = ex
		1:
			pl = maxy if pos else miny
			sc = sy
			ec = ey
		_:
			pl = maxz if pos else minz
			sc = sz
			ec = ez
	var d1 := 0.0
	var d2 := 0.0
	if pos:
		d1 = sc - pl - r
		d2 = ec - pl - r
	else:
		d1 = pl - sc - r
		d2 = pl - ec - r
	if (d1 > 0.0 and d2 > 0.0) or (d1 < -r and d2 < -r):
		return false
	var su := absf(d1) + absf(d2)
	var t := absf(d1) / su if su > 0.0 else 0.0
	var px := sx + (ex - sx) * t
	var py := sy + (ey - sy) * t
	var pz := sz + (ez - sz) * t
	# Оси прямоугольника: следующие две по кругу, как u/v в BoxGeometry.
	var u := (ax + 1) % 3
	var v := (ax + 2) % 3
	var pu := _axis_of(u, px, py, pz)
	var pv := _axis_of(v, px, py, pz)
	var umin := _axis_of(u, minx, miny, minz)
	var umax := _axis_of(u, maxx, maxy, maxz)
	var vmin := _axis_of(v, minx, miny, minz)
	var vmax := _axis_of(v, maxx, maxy, maxz)
	if absf(pu - umin) < 1e-9 or absf(pu - umax) < 1e-9 or absf(pv - vmin) < 1e-9 or absf(pv - vmax) < 1e-9:
		degenerate = true
	if su > 0.0 and pu >= umin and pu <= umax and pv >= vmin and pv <= vmax:
		_hn_x = 0.0
		_hn_y = 0.0
		_hn_z = 0.0
		var sgn := 1.0 if pos else -1.0
		if ax == 0:
			_hn_x = sgn
		elif ax == 1:
			_hn_y = sgn
		else:
			_hn_z = sgn
		_hd = absf(minf(d1, d2))
		if absf(_hd) < 1e-9:
			degenerate = true
		return true
	# Четыре ребра грани, обход по кругу. Координаты собираются на месте:
	# на сорока тысячах проб любой временный массив здесь стоит секунд.
	for k in 4:
		var au := umin if (k == 0 or k == 3) else umax
		var av := vmin if (k == 0 or k == 1) else vmax
		var k2 := (k + 1) % 4
		var bu := umin if (k2 == 0 or k2 == 3) else umax
		var bv := vmin if (k2 == 0 or k2 == 1) else vmax
		var e1x := 0.0
		var e1y := 0.0
		var e1z := 0.0
		var e2x := 0.0
		var e2y := 0.0
		var e2z := 0.0
		if ax == 0:
			e1x = pl
			e2x = pl
		elif ax == 1:
			e1y = pl
			e2y = pl
		else:
			e1z = pl
			e2z = pl
		if u == 0:
			e1x = au
			e2x = bu
		elif u == 1:
			e1y = au
			e2y = bu
		else:
			e1z = au
			e2z = bu
		if v == 0:
			e1x = av
			e2x = bv
		elif v == 1:
			e1y = av
			e2y = bv
		else:
			e1z = av
			e2z = bv
		_seg_seg(sx, sy, sz, ex, ey, ez, e1x, e1y, e1z, e2x, e2y, e2z)
		var dx := _p1x - _p2x
		var dy := _p1y - _p2y
		var dz := _p1z - _p2z
		var dsq := dx * dx + dy * dy + dz * dz
		if dsq >= r * r:
			continue
		var dist := sqrt(dsq)
		if dist == 0.0:
			# Ось капсулы прошла ровно по ребру: у оригинала тут нулевая нормаль,
			# то есть попадание есть, а выталкивания нет.
			degenerate = true
			_hn_x = 0.0
			_hn_y = 0.0
			_hn_z = 0.0
			_hd = r
			return true
		_hn_x = dx / dist
		_hn_y = dy / dist
		_hn_z = dz / dist
		_hd = r - dist
		if absf(_hd) < 1e-9:
			degenerate = true
		return true
	return false


func _axis_of(a: int, x: float, y: float, z: float) -> float:
	if a == 0:
		return x
	if a == 1:
		return y
	return z


# Ближайшие точки двух отрезков — порт lineToLineClosestPoints из Octree.js.
func _seg_seg(p1x: float, p1y: float, p1z: float, q1x: float, q1y: float, q1z: float,
		p2x: float, p2y: float, p2z: float, q2x: float, q2y: float, q2z: float) -> void:
	var rx := q1x - p1x
	var ry := q1y - p1y
	var rz := q1z - p1z
	var sx := q2x - p2x
	var sy := q2y - p2y
	var sz := q2z - p2z
	var wx := p2x - p1x
	var wy := p2y - p1y
	var wz := p2z - p1z
	var a := rx * sx + ry * sy + rz * sz
	var b := rx * rx + ry * ry + rz * rz
	var c := sx * sx + sy * sy + sz * sz
	var dd := sx * wx + sy * wy + sz * wz
	var e := rx * wx + ry * wy + rz * wz
	var div := b * c - a * a
	var t1 := 0.0
	var t2 := 0.0
	if absf(div) < 1e-10:
		var k1 := -dd / c
		var k2 := (a - dd) / c
		if absf(k1 - 0.5) < absf(k2 - 0.5):
			t1 = 0.0
			t2 = k1
		else:
			t1 = 1.0
			t2 = k2
	else:
		t1 = (dd * a + e * c) / div
		t2 = (t1 * a - dd) / c
	t2 = clampf(t2, 0.0, 1.0)
	t1 = clampf(t1, 0.0, 1.0)
	_p1x = p1x + rx * t1
	_p1y = p1y + ry * t1
	_p1z = p1z + rz * t1
	_p2x = p2x + sx * t2
	_p2y = p2y + sy * t2
	_p2z = p2z + sz * t2


# ---------- точка внутри тела ----------

# capsule_hit() отвечает на вопрос «куда вытолкнуть», и у него есть слепое пятно
# по построению: капсула, целиком утонувшая в большой коробке, не касается ни
# одной грани в пределах своего радиуса, и вызов возвращает пустоту. Для стен
# прототипа (12 см) такого случая не бывает вовсе, а для сплошных объёмов улицы
# (дом восемь на шесть) он основной — и «свободно ли здесь» по капсуле давало бы
# «да» ровно посреди чужого дома.
#
# Отсюда отдельный запрос: лежит ли точка внутри активной коробки набора.
# Пользуются им проверки расстановки — маршрут соседа и сетка пола.
func point_hit(x: float, y: float, z: float, mask: int = ALL) -> bool:
	for set_id: int in QUERY_ORDER:
		if (mask & (1 << set_id)) == 0:
			continue
		var d: PackedFloat64Array = _data[set_id]
		if d.is_empty():
			continue
		var act: PackedByteArray = _active[set_id]
		_collect(set_id, x, z, 0.0)
		for i: int in _cand:
			if act[i] == 0:
				continue
			var o := i * STRIDE
			if y < d[o + 1] or y > d[o + 4]:
				continue
			var axis := int(d[o + 6])
			if axis == AXIS_NONE:
				if x >= d[o] and x <= d[o + 3] and z >= d[o + 2] and z <= d[o + 5]:
					return true
				continue
			var ang: float = d[o + 7]
			var lp := _to_local(axis, cos(ang), sin(ang),
				x - d[o + 8], y - d[o + 9], z - d[o + 10])
			if absf(lp[0]) <= d[o + 11] and absf(lp[1]) <= d[o + 12] \
					and absf(lp[2]) <= d[o + 13]:
				return true
	return false


# ---------- луч вниз ----------

# Первая поверхность под точкой. Аналог Ray(0,-1,0) + octree.rayIntersect:
# задние грани не считаются, поэтому изнутри коробки луч ничего не находит.
func ray_down(x: float, from_y: float, z: float, mask: int = ALL) -> Dictionary:
	var best := INF
	var nx := 0.0
	var ny := 0.0
	var nz := 0.0
	for set_id: int in QUERY_ORDER:
		if (mask & (1 << set_id)) == 0:
			continue
		var d: PackedFloat64Array = _data[set_id]
		if d.is_empty():
			continue
		var act: PackedByteArray = _active[set_id]
		_collect(set_id, x, z, 0.0)
		for i: int in _cand:
			if act[i] == 0:
				continue
			var o := i * STRIDE
			if d[o + 1] > from_y:
				continue
			var axis := int(d[o + 6])
			var ox := x - d[o + 8]
			var oy := from_y - d[o + 9]
			var oz := z - d[o + 10]
			var dirx := 0.0
			var diry := -1.0
			var dirz := 0.0
			var hx: float = d[o + 11]
			var hy: float = d[o + 12]
			var hz: float = d[o + 13]
			if axis != AXIS_NONE:
				var ang: float = d[o + 7]
				var ca := cos(ang)
				var sa := sin(ang)
				var lo := _to_local(axis, ca, sa, ox, oy, oz)
				var ld := _to_local(axis, ca, sa, dirx, diry, dirz)
				ox = lo[0]; oy = lo[1]; oz = lo[2]
				dirx = ld[0]; diry = ld[1]; dirz = ld[2]
			var t_near := -INF
			var t_far := INF
			var face := -1
			var ok := true
			for a in 3:
				var oa := _axis_of(a, ox, oy, oz)
				var da := _axis_of(a, dirx, diry, dirz)
				var ha := _axis_of(a, hx, hy, hz)
				if absf(da) < 1e-12:
					if oa < -ha or oa > ha:
						ok = false
						break
					continue
				var inv := 1.0 / da
				var t1 := (-ha - oa) * inv
				var t2 := (ha - oa) * inv
				var sgn := -1.0
				if t1 > t2:
					var tmp := t1
					t1 = t2
					t2 = tmp
					sgn = 1.0
				if t1 > t_near:
					t_near = t1
					face = a * 2 + (0 if sgn > 0.0 else 1)
				if t2 < t_far:
					t_far = t2
				if t_near > t_far:
					ok = false
					break
			if not ok or t_near < 0.0 or t_near > t_far or t_near >= best:
				continue
			best = t_near
			var f := face >> 1
			var s := 1.0 if (face & 1) == 0 else -1.0
			var lnx := s if f == 0 else 0.0
			var lny := s if f == 1 else 0.0
			var lnz := s if f == 2 else 0.0
			if axis != AXIS_NONE:
				var ang2: float = d[o + 7]
				var w := _to_world(axis, cos(ang2), sin(ang2), lnx, lny, lnz)
				nx = w[0]; ny = w[1]; nz = w[2]
			else:
				nx = lnx; ny = lny; nz = lnz
	if best == INF:
		return {}
	return {"y": from_y - best, "normal": Vector3(nx, ny, nz)}

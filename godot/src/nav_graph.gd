# Навигационный граф деда. Порт src/game/nav.js 1:1.
#
# Ни одной координаты помещения здесь нет намеренно: комнаты растеризуются по
# ROOMS, проёмы берутся из WALLS[].holes, а всё, чего в site.json нет, лежит в
# data/nav.json. Ручная таблица маршрутов в оригинале протухла молча — точка
# оказалась внутри кладовки под лестницей, куда ногами не дойти, — и вся эта
# машинерия существует ради того, чтобы такое всплывало на приёмке, а не в игре.
#
# Чем подложка отличается от оригинала. Вместо трёх октодеревьев three.js —
# CollisionWorld с тремя наборами, и наборы опрашиваются ПО ОТДЕЛЬНОСТИ: оригинал
# зовёт capsuleIntersect у каждого дерева с чистой капсулой, а один вызов с общей
# маской складывал бы выталкивания мира и реквизита в одну сумму и врал по depth.
# Вся арифметика идёт в обычных float (double) через capsule_hit_d/ray_down:
# Vector3 в Godot — float32, и его 1e-7 переворачивает вердикт пробы у грани.
#
# Строится граф долго (десятки секунд headless на всех пробах и валидации рёбер),
# поэтому в игре он не строится: tests/bake_nav.gd печёт data/nav_baked.json,
# а рантайм зовёт load_baked() и получает граф мгновенно. Вес закрытой двери
# при этом всё равно читается живьём — через CollisionWorld.is_blocker_active.

class_name NavGraph
extends RefCounted

# Верх пробной капсулы над ногами, по слоям. Занятый объём — на радиус выше.
# roof 1.40, а не 1.10: затяжка под коньком даёт просвет 1.85, а при 1.10 проба
# доставала до 1.42 и двадцать восемь сантиметров головы не проверялись ничем.
const PROBE_TOP := {"floor1": 1.55, "attic": 1.55, "plot": 1.55, "cellar": 1.42, "roof": 1.40}

const CELL := 0.25        # шаг растеризации
const PAD := 0.30         # отступ от осевых линий стен
# Радиус пробы при построении. РОВНО тот же, что у деда: граф тоньше ходока
# выдаёт рёбра, по которым тот не пройдёт.
const BUILD_R := 0.32
const BRIDGE_MAX := 2     # сколько углов разрешено домостроить до двери
const MIN_AREA := 1.2     # м², меньше — не комната, а щель за мебелью
const SPLIT_SPAN := 4.2   # длинная сторона, после которой компонент даёт два узла
const EDGE_STEP := 0.18   # шаг сэмплирования коридора ребра
const DOOR_MIN_H := 1.75  # ниже — не дверь: дыра в w-nook высотой 1.4 отсекается ПО ДАННЫМ
const DOOR_COST := 1.35   # дверной узел дороже: в проёме не разойтись
const SHUT_COST := 4.0    # закрытая дверь: обходим, если обход не длиннее вчетверо
const TOUCH := 0.02       # касание в пределах точности — не пересечение
const STEP_UP := 0.20     # порог сарая 0.12, крышка погреба 0.14, ступенька 0.178
const FLOOR_TOL := 0.28   # насколько найденный пол вправе отличаться от отметки слоя
const PLOT_LINK := 9.0    # предел прямого ребра между узлами участка
const DOOR_LINK := 7.0    # предел ребра от дверного узла до комнатного
const REPAIR_TRIES := 16  # сколько альтернативных клеток пробуем при починке узла

# Пять точек проверки пола: центр и ±0.30 по осям. Центр первым — на нём
# отваливается большинство клеток над проёмом лестницы.
const FLOOR_PTS := [[0.0, 0.0], [0.30, 0.0], [-0.30, 0.0], [0.0, 0.30], [0.0, -0.30]]

const BAKED_PATH := "res://data/nav_baked.json"

var col: CollisionWorld
# [{id, box: AABB, active, node}] из WorldBuilder.build() — нужен только затем,
# чтобы дверной узел нашёл своё полотно по геометрии (id стены и id блокера
# не связаны ничем).
var blockers: Array = []
var warnings: Array = []
var build_ms := 0.0

var _nodes: Dictionary = {}        # id -> узел
var _layers: Dictionary = {}       # слой -> [узел]
var _patrol: Dictionary = {}       # слой -> кольцо обхода
var _dist_cache: Dictionary = {}   # 'a>b' -> длина пути, для 2-opt
var _meta: Dictionary = {}         # id -> служебное построения (grid/cells/dist/sides)
var _block_off := false

var _rooms: Dictionary = {}
var _walls: Array = []
var _ban_rects: Array = []
var _ban_walls: Array = []
var _ban_rooms: Array = []
var _plot_defs: Array = []
var _patrol_hint: Dictionary = {}
var _plot_ray_from := 1.90
var _layer_marks: Array = []

# Царапка соседей клетки: на сотнях тысяч вызовов свежий массив стоит секунд.
var _nb: PackedInt32Array = PackedInt32Array()


func _init(collision: CollisionWorld, blocker_list: Array = []) -> void:
	col = collision
	blockers = blocker_list
	var site := GameData.site()
	_rooms = site["ROOMS"]
	_walls = site["WALLS"]
	var y: Dictionary = site["Y"]
	_layer_marks = [
		["cellar", float(y["CELLAR"])],
		["plot", float(y["GROUND"])],
		["floor1", float(y["FLOOR1"])],
		["attic", float(y["ATTIC"])],
		["roof", float(y["ROOF"])],
	]
	var nav := GameData.nav()
	_ban_rects = nav["banRects"]
	_ban_walls = nav["banWalls"]
	_ban_rooms = nav["banRooms"]
	_plot_defs = nav["plotNodes"]
	_patrol_hint = nav["patrol"]
	_plot_ray_from = float(nav["PLOT_RAY_FROM"])


# Построить с нуля. blocker_list — из WorldBuilder.build()["blockers"].
static func build(collision: CollisionWorld, blocker_list: Array = []) -> NavGraph:
	var g := NavGraph.new(collision, blocker_list)
	g._build()
	return g


# Рантайм-путь: испечённый граф, а нет файла — строим (и это заметно по времени).
static func from_baked(collision: CollisionWorld, blocker_list: Array = [],
		file_path := BAKED_PATH) -> NavGraph:
	var g := NavGraph.new(collision, blocker_list)
	if not g.load_baked(file_path):
		g._build()
	return g


# ================= построение =================

func _build() -> void:
	var t0 := Time.get_ticks_usec()
	# Двери на время построения не в счёт: запертость — это вес ребра, а не
	# геометрия. У оригинала это делается снятием active со всех блокеров, что
	# ровно то же самое, что не опрашивать набор вовсе.
	var saved := _block_off
	_block_off = true

	var holes := _door_holes()
	var rooms := _rasterize(holes)
	_plot_nodes()
	var doors := _door_nodes(holes)
	_repair_room_nodes(doors)
	_edges(rooms, doors)
	_prune(doors)

	_block_off = saved
	_index()
	build_ms = float(Time.get_ticks_usec() - t0) / 1000.0


# Комнаты дома. Участок и улица растеризацией не описываются — см. data/nav.json.
func _rasterize(holes: Array) -> Array:
	var out: Array = []
	for key: String in _rooms.keys():
		if _ban_rooms.has(key):
			continue
		var r: Dictionary = _rooms[key]
		var layer := String(r["level"])
		if layer == "street" or layer == "plot":
			continue
		if not PROBE_TOP.has(layer):
			continue

		var g := _grid(key, r, layer)
		if g.is_empty():
			continue
		# Нумерация сквозная по комнате, а не по компоненту: у прихожей их два
		# (лестница режет её пополам), и одинаковый '#0' затирал бы узел узлом.
		var n := 0
		for cells: PackedInt32Array in _components(g):
			# Мелочь выбрасываем, кроме подхода к двери: полоса перед дверью
			# кладовой на мансарде — 1.19 м², по площади мусор, по смыслу —
			# единственный путь к стремянке и люку на чердак.
			if cells.size() * CELL * CELL < MIN_AREA and not _serves_door(g, cells, holes):
				continue
			var dist := _depth(g, cells)
			for made: Dictionary in _nodes_for(g, cells, dist, key, layer, float(r["y"]), n):
				n += 1
				_nodes[made["id"]] = made
				out.append(made)
	return out


func _grid(key: String, r: Dictionary, layer: String) -> Dictionary:
	var rx: Array = r["x"]
	var rz: Array = r["z"]
	var x0 := float(rx[0]) + PAD
	var x1 := float(rx[1]) - PAD
	var z0 := float(rz[0]) + PAD
	var z1 := float(rz[1]) - PAD
	if x1 < x0 or z1 < z0:
		return {}
	var nx := int(floor((x1 - x0) / CELL + 1e-6)) + 1
	var nz := int(floor((z1 - z0) / CELL + 1e-6)) + 1
	var free := PackedByteArray()
	free.resize(nx * nz)
	var top: float = PROBE_TOP[layer]
	var ry := float(r["y"])

	for i in nx:
		var x := x0 + i * CELL
		for j in nz:
			var z := z0 + j * CELL
			if _banned(layer, x, z):
				continue
			if not _clear(layer, x, ry, z, BUILD_R, top):
				continue
			if not _floor_under(x, ry, z):
				continue
			free[i * nz + j] = 1
	return {"key": key, "layer": layer, "y": ry, "x0": x0, "z0": z0,
		"nx": nx, "nz": nz, "free": free}


# Пол под клеткой. Без этой проверки узел площадки мансарды садится над
# Г-образным проёмом лестницы, где треугольников просто нет: луч уходит вниз
# и находит пол первого этажа на два с половиной метра ниже.
func _floor_under(x: float, y: float, z: float) -> bool:
	for p: Array in FLOOR_PTS:
		var h: Variant = _floor_at(x + float(p[0]), z + float(p[1]), y + 0.60)
		if h == null or absf(float(h) - y) > FLOOR_TOL:
			return false
	return true


# Только статика: у оригинала это world.octree, реквизит и двери полом не бывают.
func _floor_at(x: float, z: float, from_y: float) -> Variant:
	var hit := col.ray_down(x, from_y, z, CollisionWorld.MASK_STATIC)
	if hit.is_empty():
		return null
	var n: Vector3 = hit["normal"]
	if absf(n.y) < 0.5:
		return null                                  # грань стены, а не пол
	return float(hit["y"])


func _serves_door(g: Dictionary, cells: PackedInt32Array, holes: Array) -> bool:
	var layer := String(g["layer"])
	for h: Dictionary in holes:
		if String(h["layer"]) != layer:
			continue
		for c: int in cells:
			var dx := _cell_x(g, c) - float(h["x"])
			var dz := _cell_z(g, c) - float(h["z"])
			if dx * dx + dz * dz < 0.55 * 0.55:
				return true
	return false


func _banned(layer: String, x: float, z: float) -> bool:
	for b: Dictionary in _ban_rects:
		if String(b["layer"]) != layer:
			continue
		var bx: Array = b["x"]
		var bz: Array = b["z"]
		if x >= float(bx[0]) and x <= float(bx[1]) and z >= float(bz[0]) and z <= float(bz[1]):
			return true
	return false


# ---------- компоненты и узлы ----------

func _neighbours(g: Dictionary, c: int) -> PackedInt32Array:
	var nx: int = g["nx"]
	var nz: int = g["nz"]
	_nb.clear()
	var i := c / nz
	var j := c % nz
	if i > 0:
		_nb.append(c - nz)
	if i < nx - 1:
		_nb.append(c + nz)
	if j > 0:
		_nb.append(c - 1)
	if j < nz - 1:
		_nb.append(c + 1)
	return _nb


func _components(g: Dictionary) -> Array:
	var nx: int = g["nx"]
	var nz: int = g["nz"]
	var free: PackedByteArray = g["free"]
	var mark := PackedByteArray()
	mark.resize(nx * nz)
	var out: Array = []
	var stack := PackedInt32Array()
	for s in mark.size():
		if free[s] == 0 or mark[s] != 0:
			continue
		var cells := PackedInt32Array()
		mark[s] = 1
		stack.append(s)
		while stack.size() > 0:
			var c := stack[stack.size() - 1]
			stack.remove_at(stack.size() - 1)
			cells.append(c)
			for n: int in _neighbours(g, c):
				if free[n] != 0 and mark[n] == 0:
					mark[n] = 1
					stack.append(n)
		out.append(cells)
	return out


# Расстояние клетки до границы компонента, в клетках. Заливка от края внутрь.
func _depth(g: Dictionary, cells: PackedInt32Array) -> PackedInt32Array:
	var nx: int = g["nx"]
	var nz: int = g["nz"]
	var inside := PackedByteArray()
	inside.resize(nx * nz)
	for c: int in cells:
		inside[c] = 1
	var dist := PackedInt32Array()
	dist.resize(nx * nz)
	dist.fill(-1)
	var queue := PackedInt32Array()

	for c: int in cells:
		var i := c / nz
		var j := c % nz
		var edge := i == 0 or j == 0 or i == nx - 1 or j == nz - 1
		if not edge:
			for n: int in _neighbours(g, c):
				if inside[n] == 0:
					edge = true
					break
		if edge:
			dist[c] = 1
			queue.append(c)

	var h := 0
	while h < queue.size():
		var c := queue[h]
		for n: int in _neighbours(g, c):
			if inside[n] == 0 or dist[n] >= 0:
				continue
			dist[n] = dist[c] + 1
			queue.append(n)
		h += 1
	return dist


func _cell_x(g: Dictionary, c: int) -> float:
	var nz: int = g["nz"]
	return float(g["x0"]) + (c / nz) * CELL


func _cell_z(g: Dictionary, c: int) -> float:
	var nz: int = g["nz"]
	return float(g["z0"]) + (c % nz) * CELL


# Один узел или два. Комната длиной больше 4.2 м с одним узлом посередине
# читается как «дед не ходит по комнатам»: он топчется в центре зала и не
# подходит ни к окну, ни к дивану.
func _nodes_for(g: Dictionary, cells: PackedInt32Array, dist: PackedInt32Array,
		key: String, layer: String, y: float, from_n: int) -> Array:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	var sx := 0.0
	var sz := 0.0
	for c: int in cells:
		var x := _cell_x(g, c)
		var z := _cell_z(g, c)
		if x < min_x:
			min_x = x
		if x > max_x:
			max_x = x
		if z < min_z:
			min_z = z
		if z > max_z:
			max_z = z
		sx += x
		sz += z
	var span_x := max_x - min_x
	var span_z := max_z - min_z
	var cn := float(cells.size())

	var big_x := span_x > SPLIT_SPAN
	var big_z := span_z > SPLIT_SPAN
	if not big_x and not big_z:
		# Самая удалённая от стен клетка, при равной глубине — ближняя к центру масс.
		var c := _pick(g, cells, dist, sx / cn, sz / cn, INF)
		return [_room_node(g, c, cells, dist, key, layer, y, from_n)]

	# Длинная по одной оси комната режется пополам, длинная по обеим — на четверти.
	# Четверти нужны ради двух вещей. Патруль: подпол 9.0 × 8.6 с двумя узлами —
	# маятник на одном отрезке. Респаун: отбор ставит деда на самый дальний узел
	# слоя, и на чердаке с двумя узлами дальний оказывался в 2.2 м от игрока.
	var mid_x := (min_x + max_x) / 2.0
	var mid_z := (min_z + max_z) / 2.0
	var cols := 2 if big_x else 1
	var parts: Array = []
	for _i in cols * (2 if big_z else 1):
		parts.append(PackedInt32Array())
	for c: int in cells:
		var i := 1 if big_x and _cell_x(g, c) >= mid_x else 0
		if big_z and _cell_z(g, c) >= mid_z:
			i += cols
		var part: PackedInt32Array = parts[i]
		part.append(c)
		parts[i] = part

	var picks := PackedInt32Array()
	for part: PackedInt32Array in parts:
		if part.is_empty():
			continue
		var px := 0.0
		var pz := 0.0
		for c: int in part:
			px += _cell_x(g, c)
			pz += _cell_z(g, c)
		# Глубина ограничена пятью клетками: дальше от стены отходить незачем,
		# важнее не уехать из своего сектора к общей середине.
		var pn := float(part.size())
		var c2 := _pick(g, part, dist, px / pn, pz / pn, 5.0)
		# Соседние сектора умеют выбрать одну и ту же клетку: у балкона свободна
		# только полоса вдоль парапета. Два узла в одной точке дают ребро нулевой
		# длины, на котором патруль дёргается вместо шага. Ближе метра — один узел.
		var x := _cell_x(g, c2)
		var z := _cell_z(g, c2)
		var dup := false
		for p: int in picks:
			if _hypot(_cell_x(g, p) - x, _cell_z(g, p) - z) < 1.0:
				dup = true
				break
		if dup:
			continue
		picks.append(c2)
	if picks.is_empty():
		picks.append(_pick(g, cells, dist, sx / cn, sz / cn, INF))

	var out: Array = []
	for i in picks.size():
		out.append(_room_node(g, picks[i], cells, dist, key, layer, y, from_n + i))
	return out


func _room_node(g: Dictionary, c: int, cells: PackedInt32Array, dist: PackedInt32Array,
		key: String, layer: String, y: float, num: int) -> Dictionary:
	var out := {
		"id": layer + ":" + key + "#" + str(num),
		"layer": layer,
		"kind": "room",
		"x": _cell_x(g, c),
		"y": y,
		"z": _cell_z(g, c),
		"room": key,
		"wallId": null,
		"blockerId": null,
		"edges": [],
	}
	_meta[out["id"]] = {"grid": g, "cells": cells, "dist": dist}
	return out


func _pick(g: Dictionary, cells: PackedInt32Array, dist: PackedInt32Array,
		tx: float, tz: float, cap: float) -> int:
	var best := cells[0]
	var best_score := -INF
	for c: int in cells:
		var dv := 0 if dist[c] < 0 else dist[c]
		var d := minf(float(dv), cap)
		var dx := _cell_x(g, c) - tx
		var dz := _cell_z(g, c) - tz
		var score := d * 1e6 - _hypot(dx, dz)
		if score > best_score:
			best_score = score
			best = c
	return best


# ---------- участок ----------

func _plot_nodes() -> void:
	for p: Dictionary in _plot_defs:
		var at: Array = p["at"]
		var x := float(at[0])
		var z := float(at[1])
		var pid := String(p["id"])
		var fy: Variant = _floor_at(x, z, _plot_ray_from)
		if fy == null:
			_warn("узел участка «%s» [%s, %s]: под ним нет пола" % [pid, x, z])
			continue
		var y := float(fy)
		if not _clear("plot", x, y, z, BUILD_R, float(PROBE_TOP["plot"])):
			_warn("узел участка «%s» [%s, %s]: проба занята, точка выброшена" % [pid, x, z])
			continue
		var pnode := {
			"id": "plot:" + pid + "#0",
			"layer": "plot",
			"kind": "room",
			"x": x,
			"y": y,
			"z": z,
			"room": null,
			"wallId": null,
			"blockerId": null,
			"edges": [],
		}
		_nodes[pnode["id"]] = pnode


# ---------- двери ----------

# Дверной узел по данным, а не по списку имён: проём от пола (y0 = 0) высотой
# не меньше 1.75. Дыра в w-nook высотой 1.4 отсекается сама — значит в нишу
# с тайником дед не пойдёт никогда, и это переживёт любую правку site.json.
func _door_holes() -> Array:
	var out: Array = []
	for w: Dictionary in _walls:
		if not w.has("holes") or w["holes"] == null:
			continue
		if _ban_walls.has(String(w["id"])):
			continue
		var layer := _layer_of_y(float(w["y"]))
		if layer == "" or not PROBE_TOP.has(layer):
			continue
		var a: Array = w["a"]
		var b: Array = w["b"]
		var horiz := absf(float(b[0]) - float(a[0])) > absf(float(b[1]) - float(a[1]))

		for h: Dictionary in w["holes"]:
			var y0 := 0.0
			if h.has("y0") and h["y0"] != null:
				y0 = float(h["y0"])
			var y1 := float(w["h"])
			if h.has("y1") and h["y1"] != null:
				y1 = float(h["y1"])
			if y0 > 0.001 or y1 - y0 < DOOR_MIN_H:
				continue
			var ck := "x" if horiz else "z"
			if not h.has(ck) or h[ck] == null:
				continue
			var c := float(h[ck])
			var hx := c if horiz else float(a[0])
			var hz := float(a[1]) if horiz else c
			var hnx := 0.0 if horiz else 1.0
			var hnz := 1.0 if horiz else 0.0
			out.append({
				"layer": layer,
				"wall": String(w["id"]),
				"c": c,
				"x": hx,
				"z": hz,
				"y": float(w["y"]),
				"nx": hnx,
				"nz": hnz,
			})
	return out


func _door_nodes(holes: Array) -> Array:
	var out: Array = []
	for h: Dictionary in holes:
		var hx := float(h["x"])
		var hy := float(h["y"])
		var hz := float(h["z"])
		var layer := String(h["layer"])
		var nx := float(h["nx"])
		var nz := float(h["nz"])
		var dnode := {
			"id": layer + ":door:" + String(h["wall"]) + "@" + _fixed1(float(h["c"])),
			"layer": layer,
			"kind": "door",
			"x": hx,
			"y": hy,
			"z": hz,
			"room": null,
			"wallId": String(h["wall"]),
			"blockerId": _blocker_at(hx, hy, hz),
			"edges": [],
		}
		_meta[dnode["id"]] = {
			"nx": nx,
			"nz": nz,
			"rooms": [
				_room_at(layer, hx - nx * 0.35, hz - nz * 0.35),
				_room_at(layer, hx + nx * 0.35, hz + nz * 0.35),
			],
			"sides": {},
		}
		_nodes[dnode["id"]] = dnode
		out.append(dnode)
	return out


func _room_at(layer: String, x: float, z: float) -> Variant:
	if _banned(layer, x, z):
		return null
	for key: String in _rooms.keys():
		if _ban_rooms.has(key):
			continue
		var r: Dictionary = _rooms[key]
		if String(r["level"]) != layer:
			continue
		var rx: Array = r["x"]
		var rz: Array = r["z"]
		if x >= float(rx[0]) and x <= float(rx[1]) and z >= float(rz[0]) and z <= float(rz[1]):
			return key
	return null


# Блокер двери ищется по геометрии: коробка полотна уже в мировых координатах,
# и узел проёма обязан попадать внутрь неё. Совпадение по id тут не годится —
# id блокера ('door-front') и id стены ('w-n1') не связаны ничем.
func _blocker_at(x: float, y: float, z: float) -> Variant:
	for b: Dictionary in blockers:
		var box: AABB = b["box"]
		var mn := box.position
		var mx := box.end
		if x < mn.x - 0.35 or x > mx.x + 0.35:
			continue
		if z < mn.z - 0.35 or z > mx.z + 0.35:
			continue
		if y < mn.y - 0.4 or y > mx.y:
			continue
		return String(b["id"])
	return null


# ---------- починка комнатных узлов ----------

# Узел в самой просторной клетке нередко не видит дверь по прямой: проём
# умывальной 0.70 при капсуле 0.60 проходится только строго по оси. Ребра нет —
# узел вылетает прополкой, и комната пропадает из графа целиком. Поэтому узел
# двигаем: перебираем клетки того же компонента от просторных к тесным и берём
# первую, из которой дверь видна.
func _repair_room_nodes(doors: Array) -> void:
	var by_room: Dictionary = {}
	for d: Dictionary in doors:
		var rooms: Array = _meta[d["id"]]["rooms"]
		for key: Variant in rooms:
			if key == null:
				continue
			var list: Array = by_room.get(key, [])
			list.append(d)
			by_room[key] = list

	for rn: Dictionary in _nodes.values():
		if String(rn["kind"]) != "room" or rn["room"] == null:
			continue
		var meta: Dictionary = _meta.get(rn["id"], {})
		if not meta.has("cells"):
			continue
		var list: Array = by_room.get(rn["room"], [])
		if list.is_empty():
			continue

		var nx0 := float(rn["x"])
		var nz0 := float(rn["z"])
		var order: Array = []
		for k in list.size():
			order.append(k)
		order.sort_custom(_cmp_door_dist.bind(list, nx0, nz0))
		var near: Array = []
		for k in mini(3, order.size()):
			near.append(list[order[k]])

		var layer := String(rn["layer"])
		var ny := float(rn["y"])
		var best_seen := _seen_doors(layer, nx0, ny, nz0, near)
		if best_seen >= near.size():
			continue

		var g: Dictionary = meta["grid"]
		var cells: PackedInt32Array = meta["cells"]
		var dist: PackedInt32Array = meta["dist"]
		# Кандидаты от просторных клеток к тесным, при равной глубине — ближе
		# к исходной точке: узел не должен уезжать в угол ради лишней двери.
		var cand: Array = []
		for k in cells.size():
			cand.append(k)
		cand.sort_custom(_cmp_repair.bind(cells, dist, g, nx0, nz0))
		for k in mini(cand.size(), REPAIR_TRIES):
			var c: int = cells[cand[k]]
			var x := _cell_x(g, c)
			var z := _cell_z(g, c)
			var s := _seen_doors(layer, x, ny, z, near)
			if s <= best_seen:
				continue
			best_seen = s
			rn["x"] = x
			rn["z"] = z
			if s >= near.size():
				break


func _seen_doors(layer: String, x: float, y: float, z: float, near: Array) -> int:
	var k := 0
	for d: Dictionary in near:
		if _link_ok(layer, x, y, z, d, String(d["wallId"])):
			k += 1
	return k


func _cmp_door_dist(a: int, b: int, list: Array, x: float, z: float) -> bool:
	var da := _hypot(float(list[a]["x"]) - x, float(list[a]["z"]) - z)
	var db := _hypot(float(list[b]["x"]) - x, float(list[b]["z"]) - z)
	if da != db:
		return da < db
	return a < b                                   # Array#sort в JS стабильна


func _cmp_repair(a: int, b: int, cells: PackedInt32Array, dist: PackedInt32Array,
		g: Dictionary, x: float, z: float) -> bool:
	var ca := cells[a]
	var cb := cells[b]
	var da := 0 if dist[ca] < 0 else dist[ca]
	var db := 0 if dist[cb] < 0 else dist[cb]
	if da != db:
		return db < da
	var ha := _hypot(_cell_x(g, ca) - x, _cell_z(g, ca) - z)
	var hb := _hypot(_cell_x(g, cb) - x, _cell_z(g, cb) - z)
	if ha != hb:
		return ha < hb
	return a < b


# Сэмплирование идёт ОТ цели к точке, а не наоборот: узкое место — это проём,
# и на нём проверка должна отваливаться первым же шагом. При переборе клеток
# в починке узла разница между «первый шаг» и «двадцатый» — это вся её цена.
func _link_ok(layer: String, ax: float, ay: float, az: float,
		target: Dictionary, except_wall: String) -> bool:
	var tx := float(target["x"])
	var tz := float(target["z"])
	if _crosses_wall(layer, ax, az, tx, tz, except_wall):
		return false
	return _seg_clear(layer, tx, float(target["y"]), tz, ax, ay, az, BUILD_R, true)


# ---------- рёбра ----------

func _edges(rooms: Array, doors: Array) -> void:
	# Два узла одной комнаты: между собой напрямую.
	var by_room: Dictionary = {}
	for n: Dictionary in rooms:
		var list: Array = by_room.get(n["room"], [])
		list.append(n)
		by_room[n["room"]] = list
	for list: Array in by_room.values():
		for i in list.size():
			for j in range(i + 1, list.size()):
				var a: Dictionary = list[i]
				var b: Dictionary = list[j]
				if _link_ok(String(a["layer"]), float(a["x"]), float(a["y"]), float(a["z"]), b, ""):
					_connect(a, b, false)

	# Участок: любые два узла ближе 9 м, если отрезок прошёл сэмплирование и не
	# пересёк стену. Стена с проёмом пересечением считается тоже — в сарай ходят
	# через дверной узел, иначе закрытая дверь ничего не стоит.
	var plot: Array = []
	for n: Dictionary in _nodes.values():
		if String(n["layer"]) == "plot" and String(n["kind"]) == "room":
			plot.append(n)
	for i in plot.size():
		for j in range(i + 1, plot.size()):
			var a: Dictionary = plot[i]
			var b: Dictionary = plot[j]
			if _hypot(float(a["x"]) - float(b["x"]), float(a["z"]) - float(b["z"])) > PLOT_LINK:
				continue
			if _link_ok("plot", float(a["x"]), float(a["y"]), float(a["z"]), b, ""):
				_connect(a, b, false)

	# Дверь ↔ комнатные узлы по обе стороны её стены.
	for d: Dictionary in doors:
		var dm: Dictionary = _meta[d["id"]]
		var d_layer := String(d["layer"])
		var d_wall := String(d["wallId"])
		var dx := float(d["x"])
		var dz := float(d["z"])
		var d_rooms: Array = dm["rooms"]
		var cand: Array = []
		for n: Dictionary in _nodes.values():
			if String(n["kind"]) != "room" or String(n["layer"]) != d_layer:
				continue
			if _hypot(float(n["x"]) - dx, float(n["z"]) - dz) > DOOR_LINK:
				continue
			if n["room"] == null:
				cand.append(n)                       # участок: комнат нет
			elif d_rooms.has(n["room"]):
				cand.append(n)
		var reached: Dictionary = {}
		for n: Dictionary in cand:
			if not _link_ok(d_layer, float(n["x"]), float(n["y"]), float(n["z"]), d, d_wall):
				continue
			_connect(d, n, true)
			var side := (float(n["x"]) - dx) * float(dm["nx"]) + (float(n["z"]) - dz) * float(dm["nz"])
			var sides: Dictionary = dm["sides"]
			var sign_ := -1 if side < 0.0 else 1
			sides[sign_] = true
			if n["room"] != null:
				reached[n["room"]] = true
		# Комната, из узла которой дверь не видно ни одним прямым отрезком, —
		# не тупик, а поворот. Ведём к ней ломаную по клеткам.
		for key: Variant in d_rooms:
			if key == null or reached.has(key):
				continue
			_bridge_door(d, String(key), cand)


# Мост от комнатного узла к двери ломаной по клеткам компонента.
#
# Прямого отрезка хватает почти везде, но не в Г-образной комнате. Площадка
# мансарды: проём лестницы вырезает из неё угол, и от единственного узла ни
# дверь в комнату деда, ни дверь кладовой не видны — обе за поворотом, в коридоре
# 0.81 м. Прополка снимала обе двери как односторонние, следом вылетали и сами
# комнаты: дед не мог дойти до половины третьего акта.
func _bridge_door(d: Dictionary, key: String, cand: Array) -> void:
	var dx := float(d["x"])
	var dz := float(d["z"])
	var d_layer := String(d["layer"])
	var d_wall := String(d["wallId"])
	var src: Dictionary = {}
	var best_d := INF
	for n: Dictionary in cand:
		if n["room"] == null or String(n["room"]) != key:
			continue
		var meta_n: Dictionary = _meta.get(n["id"], {})
		if not meta_n.has("cells"):
			continue
		var dd := _hypot(float(n["x"]) - dx, float(n["z"]) - dz)
		if dd < best_d:
			best_d = dd
			src = n
	if src.is_empty():
		return

	var meta: Dictionary = _meta[src["id"]]
	var g: Dictionary = meta["grid"]
	var cells: PackedInt32Array = meta["cells"]
	var from_y := float(src["y"])
	var cell_set: Dictionary = {}
	for c: int in cells:
		cell_set[c] = true

	# Клетка, из которой дверь видна и до которой при этом ближе всего.
	var goal := -1
	var goal_d := INF
	for c: int in cells:
		var x := _cell_x(g, c)
		var z := _cell_z(g, c)
		var dd := _hypot(x - dx, z - dz)
		if dd >= goal_d or dd > DOOR_LINK:
			continue
		if not _link_ok(d_layer, x, from_y, z, d, d_wall):
			continue
		goal_d = dd
		goal = c
	if goal < 0:
		return

	var start := _cell_of(g, cell_set, float(src["x"]), float(src["z"]))
	if start < 0 or start == goal:
		return

	# Заливка от двери к узлу: восстановленный путь сразу идёт в нужную сторону.
	var prev: Dictionary = {}
	prev[goal] = -1
	var queue := PackedInt32Array([goal])
	var h := 0
	while h < queue.size() and not prev.has(start):
		for n: int in _neighbours(g, queue[h]):
			if not cell_set.has(n) or prev.has(n):
				continue
			prev[n] = queue[h]
			queue.append(n)
		h += 1
	if not prev.has(start):
		return

	var line: Array = []
	var c2 := start
	while c2 >= 0:
		line.append([_cell_x(g, c2), _cell_z(g, c2)])
		c2 = prev[c2]

	# Натяжение: из текущей точки шагаем как можно дальше по прямой.
	var pts: Array = []
	var ax := float(src["x"])
	var az := float(src["z"])
	var i := 0
	while i < line.size() - 1 and pts.size() < BRIDGE_MAX:
		var j := i
		for k in range(line.size() - 1, i, -1):
			var lp: Array = line[k]
			if _crosses_wall(d_layer, ax, az, float(lp[0]), float(lp[1]), ""):
				continue
			if not _seg_clear(d_layer, ax, from_y, az, float(lp[0]), from_y, float(lp[1]), BUILD_R, true):
				continue
			j = k
			break
		if j == i:
			return                                   # ни до одной клетки не дотянулись
		var lj: Array = line[j]
		ax = float(lj[0])
		az = float(lj[1])
		i = j
		if _crosses_wall(d_layer, ax, az, dx, dz, d_wall) \
				or not _seg_clear(d_layer, dx, float(d["y"]), dz, ax, from_y, az, BUILD_R, true):
			pts.append([ax, az])
			continue
		pts.append([ax, az])
		break
	if pts.is_empty():
		return

	var tail := src
	for k in pts.size():
		var p: Array = pts[k]
		var bridge := {
			"id": d_layer + ":" + key + "^" + d_wall + "@" + str(k + 1),
			"layer": d_layer,
			"kind": "room",
			"x": float(p[0]),
			"y": from_y,
			"z": float(p[1]),
			"room": key,
			"wallId": null,
			"blockerId": null,
			"edges": [],
		}
		_nodes[bridge["id"]] = bridge
		_connect(tail, bridge, false)
		tail = bridge
	if not _link_ok(d_layer, float(tail["x"]), float(tail["y"]), float(tail["z"]), d, d_wall):
		return
	_connect(d, tail, true)
	var dm: Dictionary = _meta[d["id"]]
	var side := (float(tail["x"]) - dx) * float(dm["nx"]) + (float(tail["z"]) - dz) * float(dm["nz"])
	var sides: Dictionary = dm["sides"]
	var sign_ := -1 if side < 0.0 else 1
	sides[sign_] = true


func _cell_of(g: Dictionary, cell_set: Dictionary, x: float, z: float) -> int:
	var nx: int = g["nx"]
	var nz: int = g["nz"]
	var i := int(floor((x - float(g["x0"])) / CELL + 0.5))
	var j := int(floor((z - float(g["z0"])) / CELL + 0.5))
	if i < 0 or i >= nx or j < 0 or j >= nz:
		return -1
	var c := i * nz + j
	return c if cell_set.has(c) else -1


func _connect(a: Dictionary, b: Dictionary, door: bool) -> void:
	var len_ := _hypot(float(a["x"]) - float(b["x"]), float(a["z"]) - float(b["z"]))
	var ae: Array = a["edges"]
	var be: Array = b["edges"]
	if not _has_edge(ae, String(b["id"])):
		ae.append({"to": String(b["id"]), "len": len_, "door": door})
	if not _has_edge(be, String(a["id"])):
		be.append({"to": String(a["id"]), "len": len_, "door": door})


func _has_edge(edges: Array, to: String) -> bool:
	for e: Dictionary in edges:
		if String(e["to"]) == to:
			return true
	return false


# Отрезок пересёк осевую линию стены — ребра нет. Стены сплошные везде, кроме
# проёмов, а проём проходится только через свой дверной узел: без этого правила
# прямое ребро в обход двери обнуляет её вес, и дед ходит сквозь запертое.
func _crosses_wall(layer: String, ax: float, az: float, bx: float, bz: float,
		except_id: String) -> bool:
	for w: Dictionary in _walls:
		if String(w["id"]) == except_id:
			continue
		if _layer_of_y(float(w["y"])) != layer:
			continue
		var a: Array = w["a"]
		var b: Array = w["b"]
		if _crosses(ax, az, bx, bz, float(a[0]), float(a[1]), float(b[0]), float(b[1])):
			return true
	return false


# Коридор ребра: капсула на каждом шаге и пол под ней.
#
# Пол проверяется по той же причине, что и в клетке, только цена ошибки выше.
# Проба смотрит вверх и вбок, а над проёмом лестницы на мансарде и над люком
# на чердаке пусто во все стороны: ребро между половинами площадки прошло бы
# пробу целиком, и дед пошёл бы по воздуху над лестницей.
func _seg_clear(layer: String, ax: float, ay: float, az: float,
		bx: float, by: float, bz: float, r: float, need_floor := true) -> bool:
	var length := _hypot(bx - ax, bz - az)
	var n := maxi(1, int(ceil(length / EDGE_STEP)))
	var top: float = PROBE_TOP[layer] if PROBE_TOP.has(layer) else float(PROBE_TOP["floor1"])
	for i in n + 1:
		var t := float(i) / float(n)
		var x := ax + (bx - ax) * t
		var y := ay + (by - ay) * t
		var z := az + (bz - az) * t
		if not _clear(layer, x, y, z, r, top):
			return false
		if need_floor and not _floor_under(x, y, z):
			return false
	return true


# ---------- прополка ----------

func _prune(doors: Array) -> void:
	# Дверь без двух сторон убираем. «Меньше двух рёбер» тут мало: у двери
	# кладовки западная сторона запрещена прямоугольником, зато восточная —
	# прихожая с двумя узлами, и по счёту рёбер дверь выживала бы.
	for d: Dictionary in doors:
		var dm: Dictionary = _meta.get(d["id"], {})
		var sides: Dictionary = dm.get("sides", {})
		var edges: Array = d["edges"]
		if edges.size() >= 2 and sides.size() >= 2:
			continue
		_drop(d)
	for n: Dictionary in _nodes.values():
		var edges2: Array = n["edges"]
		if String(n["kind"]) == "room" and edges2.is_empty():
			_drop(n)


func _drop(gone: Dictionary) -> void:
	var id := String(gone["id"])
	var edges: Array = gone["edges"]
	for e: Dictionary in edges:
		if not _nodes.has(e["to"]):
			continue
		var other: Dictionary = _nodes[e["to"]]
		var kept: Array = []
		for x: Dictionary in other["edges"]:
			if String(x["to"]) != id:
				kept.append(x)
		other["edges"] = kept
	edges.clear()
	_nodes.erase(id)


func _index() -> void:
	_layers.clear()
	for n: Dictionary in _nodes.values():
		var l := String(n["layer"])
		var list: Array = _layers.get(l, [])
		list.append(n)
		_layers[l] = list
	for l: String in _layers.keys():
		var list: Array = _layers[l]
		list.sort_custom(_cmp_node_id)
	_meta.clear()


func _cmp_node_id(a: Dictionary, b: Dictionary) -> bool:
	return String(a["id"]) < String(b["id"])


func _warn(text: String) -> void:
	warnings.append(text)


# ================= проба =================

# Свободно ли в точке: все три набора, верх пробы по слою.
func probe(layer: String, x: float, y: float, z: float, r := 0.32) -> bool:
	var top := float(PROBE_TOP[layer]) if PROBE_TOP.has(layer) else float(PROBE_TOP["floor1"])
	return _clear(layer, x, y, z, r, top)


# Проходим ли коридор между двумя узлами (узлы — словари или их id). Блокеры
# по умолчанию не в счёт: граф строился с открытыми дверями, запертость живёт
# в весе ребра, и проверять коридор с закрытой дверью значит проверять не то,
# что построено.
func edge_clear(a: Variant, b: Variant, r := BUILD_R, use_blockers := false) -> bool:
	var na: Variant = _as_node(a)
	var nb: Variant = _as_node(b)
	if na == null or nb == null:
		return false
	var off := _block_off
	_block_off = not use_blockers
	var res := _seg_clear(String(na["layer"]), float(na["x"]), float(na["y"]), float(na["z"]),
		float(nb["x"]), float(nb["y"]), float(nb["z"]), r, true)
	_block_off = off
	return res


func _clear(layer: String, x: float, y: float, z: float, r: float, top: float) -> bool:
	var sy := y + r + 0.02
	var ey := y + top
	if ey < sy + 0.001:
		ey = sy + 0.001
	if _blocks(CollisionWorld.MASK_STATIC, x, sy, z, ey, r):
		return false
	if _blocks(CollisionWorld.MASK_PROPS, x, sy, z, ey, r):
		return false
	if not _block_off and _blocks(CollisionWorld.MASK_BLOCKERS, x, sy, z, ey, r):
		return false
	return true


# Одно попадание капсулы в набор: мешает ли оно.
#
# Пол под ногами капсулу задевает всегда (порог сарая, крышка погреба, кромка
# ступени), и мелкое попадание снизу — это шаг, а не стена. Попадание СВЕРХУ
# не прощаем никогда: ради него и заведён PROBE_TOP.
func _blocks(mask: int, x: float, sy: float, z: float, ey: float, r: float) -> bool:
	var hit := col.capsule_hit_d(x, sy, z, x, ey, z, r, mask)
	if hit.is_empty():
		return false
	var depth: float = hit["depth"]
	if depth <= TOUCH:
		return false
	if float(hit["ny"]) > 0.5 and depth <= STEP_UP:
		return false
	return true


# ================= запросы =================

func layer_list() -> Array:
	var out := _layers.keys()
	out.sort()
	return out


func nodes(layer: String) -> Array:
	return _layers.get(layer, [])


func node(id: String) -> Variant:
	return _nodes.get(id, null)


func _as_node(v: Variant) -> Variant:
	if v is Dictionary:
		return v
	if v is String:
		return _nodes.get(v, null)
	return null


# opts: {max_dist: float, kind: String, exclude: Dictionary(id -> true)}
func nearest(layer: String, pos: Vector3, opts: Dictionary = {}) -> Variant:
	var max_dist := float(opts.get("max_dist", INF))
	var kind := String(opts.get("kind", ""))
	var skip: Dictionary = opts.get("exclude", {})
	var best: Variant = null
	var best_d := INF
	for n: Dictionary in nodes(layer):
		if kind != "" and String(n["kind"]) != kind:
			continue
		if skip.has(n["id"]):
			continue
		var d := _hypot(float(n["x"]) - pos.x, float(n["z"]) - pos.z)
		if d > max_dist or d >= best_d:
			continue
		best_d = d
		best = n
	return best


func door_open(n: Variant) -> bool:
	if n == null or String(n["kind"]) != "door":
		return true
	var bid: Variant = n["blockerId"]
	if bid == null or String(bid) == "":
		return true                                  # проём без полотна открыт всегда
	return not col.is_blocker_active(String(bid))


# Вес ребра для A*: длина × наценка за проём × наценка за запертость.
func weight(a: Dictionary, b: Dictionary, edge: Dictionary) -> float:
	var k := 1.0
	if bool(edge["door"]):
		k *= DOOR_COST
		var door: Dictionary = a if String(a["kind"]) == "door" else b
		if not door_open(door):
			k *= SHUT_COST
	return float(edge["len"]) * k


# A* с евклидовой эвристикой по XZ. Открытый список — линейный скан: при двадцати
# узлах на слой куча дороже в аллокациях, чем весь поиск.
# Пустой массив = пути нет (у оригинала — null).
func path(from_id: String, to_id: String) -> Array:
	if not _nodes.has(from_id) or not _nodes.has(to_id):
		return []
	if from_id == to_id:
		return [_nodes[from_id]]
	var to_node: Dictionary = _nodes[to_id]

	var open: Array = [from_id]
	var g: Dictionary = {from_id: 0.0}
	var f: Dictionary = {from_id: _h(_nodes[from_id], to_node)}
	var came: Dictionary = {}
	var closed: Dictionary = {}

	while not open.is_empty():
		var bi := 0
		var bf := float(f[open[0]])
		for i in range(1, open.size()):
			var v := float(f[open[i]])
			if v < bf:
				bf = v
				bi = i
		var id := String(open[bi])
		open.remove_at(bi)
		if id == to_id:
			var out: Array = [to_node]
			var cur := to_id
			while came.has(cur):
				cur = String(came[cur])
				out.insert(0, _nodes[cur])
			return out
		closed[id] = true
		if not _nodes.has(id):
			continue
		var n: Dictionary = _nodes[id]
		for e: Dictionary in n["edges"]:
			var to := String(e["to"])
			if closed.has(to):
				continue
			if not _nodes.has(to):
				continue
			var nb: Dictionary = _nodes[to]
			var cost := float(g[id]) + weight(n, nb, e)
			if g.has(to) and cost >= float(g[to]):
				continue
			came[to] = id
			g[to] = cost
			f[to] = cost + _h(nb, to_node)
			if not open.has(to):
				open.append(to)
	return []


func path_between(a: Variant, b: Variant) -> Array:
	var na: Variant = _as_node(a)
	var nb: Variant = _as_node(b)
	if na == null or nb == null:
		return []
	return path(String(na["id"]), String(nb["id"]))


func path_to(layer: String, x0: float, z0: float, x1: float, z1: float) -> Array:
	var a: Variant = nearest(layer, Vector3(x0, 0.0, z0))
	var b: Variant = nearest(layer, Vector3(x1, 0.0, z1))
	if a == null or b == null:
		return []
	return path(String(a["id"]), String(b["id"]))


func path_length(p: Array) -> float:
	if p.size() < 2:
		return 0.0
	var s := 0.0
	for i in range(1, p.size()):
		s += _hypot(float(p[i]["x"]) - float(p[i - 1]["x"]),
			float(p[i]["z"]) - float(p[i - 1]["z"]))
	return s


func _h(a: Dictionary, b: Dictionary) -> float:
	return _hypot(float(a["x"]) - float(b["x"]), float(a["z"]) - float(b["z"]))


# ---------- патруль ----------

# Кольцо обхода слоя. Детерминированное: randf() тут нельзя — маршрут, каждый
# раз новый, читается как подмена сцены, ровно как и хлам на чердаке.
func patrol(layer: String) -> Array:
	if _patrol.has(layer):
		return _patrol[layer]
	var rooms: Array = []
	for n: Dictionary in nodes(layer):
		if String(n["kind"]) == "room":
			rooms.append(n)
	var ring: Array = []

	var hint: Array = _patrol_hint.get(layer, [])
	if not hint.is_empty() and not rooms.is_empty():
		var used: Dictionary = {}
		for key: String in hint:
			for n: Dictionary in rooms:
				if used.has(n["id"]) or _key_of(n) != key:
					continue
				ring.append(n)
				used[n["id"]] = true
		for n: Dictionary in rooms:
			if not used.has(n["id"]):
				ring.append(n)
				used[n["id"]] = true
		if not _ring_ok(ring):
			ring = []
	if ring.is_empty():
		ring = _ring(rooms)

	_patrol[layer] = ring
	return ring


# Ключ узла: 'hall' у комнатного, 'gate' у участкового, 'door:w-hall-e@11.0' у дверного.
func _key_of(n: Dictionary) -> String:
	var rest := String(n["id"]).substr(String(n["layer"]).length() + 1)
	var hash_at := rest.rfind("#")
	return rest if hash_at < 0 else rest.substr(0, hash_at)


func _ring_ok(ring: Array) -> bool:
	if ring.size() < 2:
		return ring.size() == 1
	for i in ring.size():
		var a: Dictionary = ring[i]
		var b: Dictionary = ring[(i + 1) % ring.size()]
		if path(String(a["id"]), String(b["id"])).is_empty():
			return false
	return true


# Обход ближайшего соседа по графу плюс 2-opt. Стартовый узел — первый по id.
func _ring(rooms: Array) -> Array:
	if rooms.size() < 3:
		return rooms.duplicate()

	var left: Array = rooms.slice(1)
	var ring: Array = [rooms[0]]
	while not left.is_empty():
		var cur: Dictionary = ring[ring.size() - 1]
		var bi := 0
		var bd := INF
		for i in left.size():
			var d := _ring_cost(cur, left[i])
			if d < bd:
				bd = d
				bi = i
		ring.append(left[bi])
		left.remove_at(bi)

	var best := _ring_total(ring)
	for sweep in 40:
		var moved := false
		var i := 1
		while i < ring.size() - 1 and not moved:
			for j in range(i + 1, ring.size()):
				var mid: Array = ring.slice(i, j + 1)
				mid.reverse()
				var test: Array = ring.slice(0, i)
				test.append_array(mid)
				test.append_array(ring.slice(j + 1))
				var t := _ring_total(test)
				if t < best - 1e-6:
					ring = test
					best = t
					moved = true
					break
			i += 1
		if not moved:
			break
	return ring


func _ring_cost(a: Dictionary, b: Dictionary) -> float:
	var key := String(a["id"]) + ">" + String(b["id"])
	if _dist_cache.has(key):
		return float(_dist_cache[key])
	var p := path(String(a["id"]), String(b["id"]))
	var v := path_length(p) if not p.is_empty() else _h(a, b) * 100.0
	_dist_cache[key] = v
	_dist_cache[String(b["id"]) + ">" + String(a["id"])] = v
	return v


func _ring_total(r: Array) -> float:
	var s := 0.0
	for i in r.size():
		s += _ring_cost(r[i], r[(i + 1) % r.size()])
	return s


# ---------- сводка ----------

func stats() -> Dictionary:
	var out: Dictionary = {}
	for layer: String in layer_list():
		var list: Array = nodes(layer)
		var parent: Dictionary = {}
		for n: Dictionary in list:
			parent[n["id"]] = n["id"]
		var edges := 0
		var doors := 0
		for n: Dictionary in list:
			if String(n["kind"]) == "door":
				doors += 1
			for e: Dictionary in n["edges"]:
				edges += 1
				if not parent.has(e["to"]):
					continue
				var ra := _find(parent, String(n["id"]))
				var rb := _find(parent, String(e["to"]))
				if ra != rb:
					parent[ra] = rb
		var roots: Dictionary = {}
		for n: Dictionary in list:
			roots[_find(parent, String(n["id"]))] = true
		out[layer] = {
			"nodes": list.size(),
			"doors": doors,
			"edges": edges / 2.0,
			"components": roots.size(),
		}
	return out


func _find(parent: Dictionary, a: String) -> String:
	while String(parent[a]) != a:
		parent[a] = parent[String(parent[a])]
		a = String(parent[a])
	return a


# ================= выпечка и загрузка =================

func to_dict() -> Dictionary:
	var out_nodes: Array = []
	for layer: String in layer_list():
		for n: Dictionary in nodes(layer):
			var edges: Array = []
			for e: Dictionary in n["edges"]:
				edges.append({
					"to": String(e["to"]),
					"len": _r5(float(e["len"])),
					"door": bool(e["door"]),
				})
			out_nodes.append({
				"id": String(n["id"]),
				"layer": String(n["layer"]),
				"kind": String(n["kind"]),
				"x": _r5(float(n["x"])),
				"y": _r5(float(n["y"])),
				"z": _r5(float(n["z"])),
				"room": n["room"],
				"wallId": n["wallId"],
				"blockerId": n["blockerId"],
				"edges": edges,
			})
	return {"layers": layer_list(), "nodes": out_nodes}


func save_baked(file_path := BAKED_PATH) -> bool:
	var f := FileAccess.open(file_path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify(to_dict(), " ", false))
	f.close()
	return true


func load_baked(file_path := BAKED_PATH) -> bool:
	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return false
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return false
	return from_dict(parsed)


func from_dict(d: Dictionary) -> bool:
	_nodes.clear()
	_layers.clear()
	_patrol.clear()
	_dist_cache.clear()
	_meta.clear()
	var raw: Array = d.get("nodes", [])
	for r: Dictionary in raw:
		var edges: Array = []
		for e: Dictionary in r.get("edges", []):
			edges.append({
				"to": String(e["to"]),
				"len": float(e["len"]),
				"door": bool(e["door"]),
			})
		var n := {
			"id": String(r["id"]),
			"layer": String(r["layer"]),
			"kind": String(r["kind"]),
			"x": float(r["x"]),
			"y": float(r["y"]),
			"z": float(r["z"]),
			"room": r.get("room", null),
			"wallId": r.get("wallId", null),
			"blockerId": r.get("blockerId", null),
			"edges": edges,
		}
		_nodes[n["id"]] = n
	_index()
	return not _nodes.is_empty()


# ================= мелочь =================

# Пересечение отрезков строго внутри обоих: концы, лежащие на линии, не в счёт —
# дверной узел стоит ровно на осевой линии своей стены.
static func _crosses(ax: float, az: float, bx: float, bz: float,
		px: float, pz: float, qx: float, qz: float) -> bool:
	var e := 1e-4
	var d1 := (qx - px) * (az - pz) - (qz - pz) * (ax - px)
	var d2 := (qx - px) * (bz - pz) - (qz - pz) * (bx - px)
	var d3 := (bx - ax) * (pz - az) - (bz - az) * (px - ax)
	var d4 := (bx - ax) * (qz - az) - (bz - az) * (qx - ax)
	return d1 * d2 < -e and d3 * d4 < -e


func _layer_of_y(y: float) -> String:
	for m: Array in _layer_marks:
		if absf(y - float(m[1])) < 0.06:
			return String(m[0])
	return ""


# Math.hypot из V8 дословно: масштабирование на максимум и компенсация Кэхэна.
# sqrt(dx*dx+dz*dz) отличается от него последним битом, а от последнего бита
# зависят выбор клетки в _pick и слипание двух узлов в один при ровно 1.0 м.
static func _hypot(x: float, y: float) -> float:
	var ax := absf(x)
	var ay := absf(y)
	var m := maxf(ax, ay)
	if m == 0.0:
		m = 1.0
	var n1 := ax / m
	var n2 := ay / m
	var sum := 0.0
	var comp := 0.0
	var summand := n1 * n1 - comp
	var prelim := sum + summand
	comp = (prelim - sum) - summand
	sum = prelim
	summand = n2 * n2 - comp
	prelim = sum + summand
	comp = (prelim - sum) - summand
	sum = prelim
	return sqrt(sum) * m


# Math.round у JS — это floor(v + 0.5), а не «половина от нуля».
static func _r5(v: float) -> float:
	return floor(v * 1e5 + 0.5) / 1e5


# Number.toFixed(1): у printf округление к чётному, но на координатах проёмов
# (кратны 0.1) обе схемы дают одно и то же.
static func _fixed1(v: float) -> String:
	var s := "%.1f" % v
	return "0.0" if s == "-0.0" else s

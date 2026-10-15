# У каждой точки Interact есть ЧТО-ТО, во что игрок целится (фаза 16).
#
# ЗАЧЕМ. Кран у бани был зарегистрирован верно: правильные координаты, живое
# условие, приоритет никто не перебивал, физически игрок к точке проходил.
# У крана не было ни одного полигона. Ни yard_world._banya(), ни
# visual_dressing.json, ни один коммит не строили там ни трубы, ни вентиля.
# Точка висела в воздухе в пяти сантиметрах от глухой стены сруба, и
# smoke_water при этом был зелёный — его хелпер присваивает interact.target
# напрямую по id и Interact.find() не зовёт ни разу.
#
# Тест проверяет две вещи, которых не проверял никто.
#
# (а) ГЕОМЕТРИЯ ЕСТЬ. В радиусе 0.5 м от точки лежит хоть какой-то полигон —
#     в слитых сетках WorldBuilder, в узлах Props/decor или в MultiMesh
#     раскладки. Точка без геометрии — это подсказка, которая появляется на
#     пустом месте, и найти её можно только случайно.
#
# (б) НА НЕЁ МОЖНО НАЦЕЛИТЬСЯ. С проходимой позиции внутри радиуса и конуса
#     Interact.find(camera, state) возвращает ИМЕННО ЭТОТ id. Не «какую-то
#     точку», а эту: осмотр соседнего предмета с подписью «осмотреть» вместо
#     «набрать воду» — это ровно то, во что упёрся игрок.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_points_visible.gd
extends SceneTree

const R := 0.30
const H := 1.78
const EYE := 1.68
const NEAR := 0.50           # в каком радиусе от точки ищем полигоны
const CELL := 0.5            # шаг хэша вершин
const RINGS := [0.55, 0.75, 1.00, 1.30, 1.70, 2.10, 2.50]
const ANGLES := 24
# Пол под позицией подхода ищем с нескольких высот: точка может лежать в
# погребе, на чердаке или на стене, и луч из одной высоты находит то плиту
# над головой, то стол под рукой, а не пол, на котором игрок стоит.
const FLOOR_PROBES := [0.55, 1.95, 0.15]
# Соперник, стоящий ВПЛОТНУЮ, — это тот же предмет со вторым дескриптором
# (капот и машина, створка и цепь, крыльцо и дверь, ватник и ключ в кармане).
# В игре их разводит when — каждый живёт на своём шаге; здесь when соперников
# оставлен нарочно, и спор между ними ничего не значит. Полтора метра — это
# «то же место», а не «другой предмет»: дальше начинается настоящая ошибка,
# вроде подписи «осмотреть» вместо «набрать воду».
const RIVAL_SAME := 1.60
# Сколько раз зовём find() на точку. Он перебирает все дескрипторы и стреляет
# до пяти лучей — из сотни позиций подряд это часы прогона, а первые шесть
# позиций уже отобраны по видимости.
const AIM_TRIES := 14
const SHOW := 30

# Створки в оверлее — те же, что в test_reachable: на время проверки открыты.
const OVERLAY_DOORS := ["door-shop", "door-boarded", "door-cellar-shed", "door-pump"]

# Точки, у которых геометрии нет ПО ЗАМЫСЛУ, и это не дефект.
# id -> причина. Список ведётся руками: каждая строка здесь — обещание, что
# игрок целится во что-то другое, а не в воздух.
const NO_GEOMETRY_OK := {
	# Разговор с идущим соседом: точка едет за фигурой, фигура — actors.gd,
	# а не геометрия мира.
	"arkady-talk": "точка едет за фигурой соседа",
	"valya-talk": "точка едет за фигурой бабки",
	# Осмотры МЕСТА, а не предмета. Точка нарочно висит на высоте глаз над
	# землёй, о которой речь: следы на полу погреба, полоса грядки, дорога
	# из деревни. Геометрия под ними есть, просто дальше полуметра.
	"cellar-tracks": "следы на полу погреба: точка на высоте глаз над полом",
	"garden-row-2": "полоса грядки: точка над землёй, а не на ней",
	"village-road": "дорога из деревни: осмотр места, а не предмета",
}

# Точки, на которые нельзя нацелиться и это верно: они срабатывают не взглядом
# (люки, зоны, триггеры прохода).
const NO_AIM_OK := {
	# Осмотр самой лестницы: точка сидит ВНУТРИ марша, между ступенью и
	# косоуром, и луч видимости упирается в него с любой стороны. Игрок при
	# этом целится не в точку, а в марш, и попадает.
	"stairs": "точка внутри марша: осмотр места, а не предмета",
	# Эти три дескриптора доступны только из временных позиций камеры: тело
	# Player остаётся у лестницы, пока runtime-контроллер двигает камеру по
	# чердаку или по верхней площадке мельницы. Статический обход мира таких
	# позиций намеренно не моделирует.
	"bathloft-cassette": "кассета берётся камерой из runtime-режима ползания",
	"bathloft-exit": "лаз доступен камерой из runtime-режима ползания",
	"mill-journal": "журнал доступен после runtime-перехода на верхнюю площадку",
	"mill-down-lower": "спуск доступен из runtime-позиции на нижней площадке",
}

var _grid: Dictionary = {}


func _initialize() -> void:
	_run()


func _run() -> void:
	# Кадр ожидания до всего: корень SceneTree в _initialize() ещё не в дереве,
	# а камере это нужно — find() читает global_transform.
	await process_frame
	var t0 := Time.get_ticks_msec()
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var world_root := Node3D.new()
	var built := WorldBuilder.build(world_root, mats, col)

	var pdata := GameData.props()
	var props := Props.new(mats)
	var all_defs: Array = []
	all_defs.append_array(pdata["PROPS"])
	all_defs.append_array(pdata["DYNAMIC_PROPS"])
	props.load_models(all_defs)
	props.build(world_root, pdata["PROPS"], col)
	props.build_dynamic(pdata["DYNAMIC_PROPS"])
	props.rebuild_collision(col)

	for bid: String in OVERLAY_DOORS:
		col.set_blocker_active(bid, false)
	for b: Dictionary in built["blockers"]:
		col.set_blocker_active(String(b["id"]), false)

	_index(world_root, Transform3D.IDENTITY)
	print("индекс геометрии: %d ячеек, %d мс" % [_grid.size(), Time.get_ticks_msec() - t0])

	var it := Interact.new()
	Interact.registerObjects(it, {"world": built})
	it.addLookTargets(props)
	it.occluder = col

	# Состояние-«поздняя игра»: глава последняя из state.gd CHAPTERS (значит
	# atLeast пускает всех), флагов нет. Это самое разрешительное состояние из
	# реальных, и именно в нём соперничество точек за прицел максимально — как
	# у игрока, который пришёл на место и ещё ничего там не сделал.
	var state := GameState.new()
	state.chapter = GameState.CHAPTERS[GameState.CHAPTERS.size() - 1]

	# Камера обязана жить В ДЕРЕВЕ: find() читает global_transform, а он у
	# узла вне дерева не считается вовсе. Мир при этом в дерево не идёт —
	# рисовать его незачем.
	var cam := Camera3D.new()
	root.add_child(cam)

	var no_geom: Array = []
	var no_aim: Array = []
	var checked := 0
	for d: Dictionary in it.list:
		var id := String(d["id"])
		checked += 1
		if not NO_GEOMETRY_OK.has(id) and not _has_geometry(d["pos"]):
			no_geom.append("«%s» [%.2f, %.2f, %.2f]: в 0.5 м ни одного полигона"
				% [id, (d["pos"] as Vector3).x, (d["pos"] as Vector3).y,
					(d["pos"] as Vector3).z])
		if NO_AIM_OK.has(id):
			continue
		var got := _aim(it, col, cam, d, state)
		if String(got.get("id", "")) != id:
			no_aim.append("«%s» [%.2f, %.2f, %.2f]: %s"
				% [id, (d["pos"] as Vector3).x, (d["pos"] as Vector3).y,
					(d["pos"] as Vector3).z, String(got.get("why", "?"))])

	print("точек проверено: %d" % checked)
	_dump("без геометрии", no_geom)
	_dump("не наводится", no_aim)
	print("время: %d мс" % (Time.get_ticks_msec() - t0))

	props.dispose()
	world_root.free()

	if no_geom.is_empty() and no_aim.is_empty():
		print("test_points_visible: PASS")
		quit(0)
		return
	printerr("test_points_visible: FAIL (без геометрии %d, не наводится %d)"
		% [no_geom.size(), no_aim.size()])
	quit(1)


func _dump(tag: String, rows: Array) -> void:
	print("%s: %d" % [tag, rows.size()])
	rows.sort()
	var shown := 0
	for r: String in rows:
		if shown >= SHOW:
			break
		shown += 1
		printerr("  · " + r)
	if rows.size() > SHOW:
		printerr("  … и ещё %d" % (rows.size() - SHOW))


# ---------------------------------------------------- индекс геометрии ----

# Обход дерева со СВОИМ накоплением трансформа: узлы собраны, но в SceneTree
# не добавлены, и global_transform у них не считается.
func _index(node: Node, xf: Transform3D) -> void:
	var here := xf
	if node is Node3D:
		here = xf * (node as Node3D).transform
		if node is MultiMeshInstance3D:
			var mm := (node as MultiMeshInstance3D).multimesh
			if mm != null and mm.mesh != null:
				var ab := mm.mesh.get_aabb()
				for i in mm.instance_count:
					var t := here * mm.get_instance_transform(i)
					_put(t * ab.get_center())
					for c in 8:
						_put(t * ab.get_endpoint(c))
		elif node is MeshInstance3D:
			var mesh := (node as MeshInstance3D).mesh
			if mesh != null:
				for s in mesh.get_surface_count():
					var arrays := mesh.surface_get_arrays(s)
					if arrays.size() <= Mesh.ARRAY_VERTEX:
						continue
					var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
					var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] \
						if arrays[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
					_faces(vs, idx, here)
	for ch in node.get_children():
		_index(ch, here)


# Треугольники, а не вершины. У BoxMesh вершины только по углам, и панель
# машины размером 4 x 1.4 м не даёт НИ ОДНОЙ вершины ближе метра к своей
# середине: индекс по вершинам объявлял бы «геометрии нет» ровно там, где
# игрок упирается в борт. Крупные треугольники дробятся до шага сетки.
func _faces(vs: PackedVector3Array, idx: PackedInt32Array, xf: Transform3D) -> void:
	var n := idx.size() / 3 if idx.size() >= 3 else vs.size() / 3
	for t in n:
		var a: Vector3
		var b: Vector3
		var c: Vector3
		if idx.size() >= 3:
			a = xf * vs[idx[t * 3]]
			b = xf * vs[idx[t * 3 + 1]]
			c = xf * vs[idx[t * 3 + 2]]
		else:
			a = xf * vs[t * 3]
			b = xf * vs[t * 3 + 1]
			c = xf * vs[t * 3 + 2]
		_tri(a, b, c, 0)


func _tri(a: Vector3, b: Vector3, c: Vector3, depth: int) -> void:
	_put(a)
	_put(b)
	_put(c)
	if depth >= 5:
		return
	var big := maxf(maxf(a.distance_to(b), b.distance_to(c)), c.distance_to(a))
	if big <= CELL * 0.8:
		return
	var ab := (a + b) * 0.5
	var bc := (b + c) * 0.5
	var ca := (c + a) * 0.5
	_tri(a, ab, ca, depth + 1)
	_tri(ab, b, bc, depth + 1)
	_tri(ca, bc, c, depth + 1)
	_tri(ab, bc, ca, depth + 1)


func _put(p: Vector3) -> void:
	_grid[Vector3i(int(floor(p.x / CELL)), int(floor(p.y / CELL)),
		int(floor(p.z / CELL)))] = true


# Геометрия рядом ЛИБО точка внутри чего-то. Второе — не поблажка: точка
# «машина» стоит в середине салона, «сортир» и «комната Вити» — в середине
# помещения, и до ближайшей панели там метр с лишним. Замкнутость проверяется
# лучами по шести осям: пять попаданий из шести значит «внутри», и это ровно
# та геометрия, в которую игрок и целится.
const ENCLOSE_SPAN := 4.0
const ENCLOSE_HITS := 5


func _has_geometry(pos: Vector3) -> bool:
	var r := int(ceil(NEAR / CELL))
	var c := Vector3i(int(floor(pos.x / CELL)), int(floor(pos.y / CELL)),
		int(floor(pos.z / CELL)))
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dz in range(-r, r + 1):
				if _grid.has(c + Vector3i(dx, dy, dz)):
					return true
	var hits := 0
	for dir: Vector3 in [Vector3.RIGHT, Vector3.LEFT, Vector3.UP, Vector3.DOWN,
			Vector3.FORWARD, Vector3.BACK]:
		var t := CELL
		while t <= ENCLOSE_SPAN:
			var p := pos + dir * t
			if _grid.has(Vector3i(int(floor(p.x / CELL)), int(floor(p.y / CELL)),
					int(floor(p.z / CELL)))):
				hits += 1
				break
			t += CELL
	return hits >= ENCLOSE_HITS


# ------------------------------------------------------------- прицел ----

# Обходим точку по кольцам и пробуем навестись. Возвращает {"id", "why"}.
func _aim(it: Interact, col: CollisionWorld, cam: Camera3D, d: Dictionary,
		state: GameState) -> Dictionary:
	var id := String(d["id"])
	var pos: Vector3 = d["pos"]
	var rr := float(d["r"])
	# Условие точки на время прицеливания снимается: тест про геометрию и
	# видимость, а не про то, на каком шаге сюжета точка живёт. У соперников
	# when остаётся — иначе проверка перестала бы быть про соперничество.
	var saved: Variant = d.get("when", null)
	d.erase("when")

	# Сначала СОБИРАЕМ позиции подхода — дешёвыми пробами (пол, капсула, луч
	# видимости), и только потом зовём find() из нескольких лучших. find()
	# перебирает все две с половиной сотни дескрипторов и стреляет до пяти
	# лучей: звать его из каждой из сотни точек — это часы прогона.
	var lit_stands: Array[Vector3] = []
	var dark_stands: Array[Vector3] = []
	for rad: float in RINGS:
		if rad > rr:
			break
		# На кольцо берём не больше трёх позиций. Иначе весь лимит попыток
		# съедает ближайшее кольцо — а именно с него хуже всего видно то, что
		# лежит на земле: угол слишком крутой.
		var on_ring := 0
		for ai in ANGLES:
			var ang := TAU * float(ai) / float(ANGLES)
			var x := pos.x + rad * cos(ang)
			var z := pos.z + rad * sin(ang)
			var floors: Array[float] = []
			for up: float in FLOOR_PROBES:
				var fl := col.ray_down(x, pos.y + up, z, CollisionWorld.ALL_SOLID)
				if fl.is_empty():
					continue
				var fy := float(fl["y"])
				var dup := false
				for f: float in floors:
					if absf(f - fy) < 0.05:
						dup = true
						break
				if not dup:
					floors.append(fy)
			for fy: float in floors:
				if not _free(col, x, z, fy):
					continue
				var eye := Vector3(x, fy + EYE, z)
				var v := pos - eye
				var ln := v.length()
				if ln > rr or ln < 0.05:
					continue
				# Точки, откуда предмет ВИДНО, пробуем первыми: с них find()
				# и обязан его вернуть.
				if it.visible(eye, pos):
					if on_ring >= 3:
						continue
					on_ring += 1
					lit_stands.append(eye)
				else:
					dark_stands.append(eye)

	var stands: Array[Vector3] = []
	stands.append_array(lit_stands)
	stands.append_array(dark_stands)
	var rival := ""
	var tried := 0
	for eye: Vector3 in stands:
		if tried >= AIM_TRIES:
			break
		tried += 1
		var v := pos - eye
		cam.transform = Transform3D(Basis.looking_at(v.normalized(), Vector3.UP), eye)
		var got: Variant = it.find(cam, state)
		if got != null and String((got as Dictionary)["id"]) == id:
			if saved != null:
				d["when"] = saved
			return {"id": id}
		if got == null:
			continue
		var gd: Dictionary = got
		# Соперник вплотную — это тот же предмет вторым дескриптором; в игре
		# их разводит when, и спорить им не о чем.
		if (gd["pos"] as Vector3).distance_to(pos) <= RIVAL_SAME:
			if saved != null:
				d["when"] = saved
			return {"id": id}
		if rival == "":
			rival = String(gd["id"])

	if saved != null:
		d["when"] = saved
	if stands.is_empty():
		return {"id": "", "why": "негде встать в радиусе %.2f м" % rr}
	if lit_stands.is_empty():
		return {"id": "", "why": "стоять есть где, но точка заслонена отовсюду"}
	if rival != "":
		return {"id": "", "why": "прицел уводит на «%s»" % rival}
	return {"id": "", "why": "видно ниоткуда: конус, дальность или заслон"}


func _free(col: CollisionWorld, x: float, z: float, fy: float) -> bool:
	if col.point_hit(x, fy + 0.90, z, CollisionWorld.ALL_SOLID):
		return false
	var hit := col.capsule_hit_d(x, fy + R + 0.03, z, x, fy + H - R, z, R,
		CollisionWorld.ALL_SOLID)
	if hit.is_empty():
		return true
	return float(hit["depth"]) <= 0.06 or absf(float(hit["ny"])) >= 0.5

# У точки Interact есть СВОЙ видимый предмет, а не чужой рядом (фаза 18).
#
# ЗАЧЕМ ПОВЕРХ test_points_visible. Тот спрашивает «есть ли в полуметре хоть
# какой-то полигон» — и на этот вопрос лопата у холма Вали отвечает «да»:
# в сорока сантиметрах от неё лежит НАСЫПЬ. Лопаты при этом нет в мире вовсе,
# ключ GRAVE.shovel не читается ни одной строкой valya_world.gd, и точка
# «взять лопату» висит в пустом воздухе на высоте 0.45. Игрок ищет глазами
# предмет, которого не существует, — ровно то же, что было с краном бани
# в фазе 16 и с сумкой на веранде в фазе 17.
#
# ЧТО ДЕЛАЕТ ЭТОТ ТЕСТ ИНАЧЕ. Индекс геометрии хранит ИМЯ УЗЛА-ВЛАДЕЛЬЦА:
# слитую сетку WorldBuilder («merged:<ведро>:…»), узел decor («valya-…»,
# «outskirts-…»), холдер пропа. Дальше сверяется таблица «id точки ->
# ожидаемый источник»: мало, чтобы рядом были полигоны, — они должны быть
# ТЕ САМЫЕ.
#
# Таблица ведётся руками и нарочно короткая: каждая строка — обещание, что
# у этого предмета есть тело, а не соседнее. Точки, которых в таблице нет,
# проверяет test_points_visible.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_point_targets.gd
extends SceneTree

# Радиус щедрый — и это не поблажка: спрашиваем не «есть ли что-нибудь», а
# «есть ли ИМЕННО ЭТО». Полметра не хватало бы сети на кольях, у которой
# точка тяги стоит в стороне от полотна, но соседний куст радиус не спасает:
# у куста другой владелец.
const NEAR := 0.80
const CELL := 0.4

# id точки -> [имя владельца (префикс), что это].
const EXPECT := {
	"grave-shovel": ["valya-grave-shovel", "лопата у насыпи"],
	"grave-dig": ["valya-grave-mound", "сама насыпь"],
	"shed-locker": ["valya-shed-locker", "шкаф с инструментом"],
	"lake-boat": ["valya-lake-boat", "лодка на берегу"],
	"lake-net": ["valya-lake-net", "колья с сетью"],
	"farm-sign": ["valya-farm-sign", "доска указателя"],
	"farm-key": ["outskirts-farm-key", "гвоздь с ключом"],
	# Сумка на веранде. Тела у неё не было ни одного полигона: точка стояла
	# над крышкой тумбы, и игрок целился в тумбу.
	#
	# Имя владельца — merged_visual_fabric, через подчёркивания. WorldBuilder
	# зовёт сетку "merged:visual:fabric:0.0" (_finish), но Godot чистит имя
	# узла от двоеточий и точек, и в дереве она лежит уже как
	# merged_visual_fabric_0_0. Сверять надо с тем, что в дереве.
	"final-bag": ["merged_visual_fabric", "сумка на тумбе веранды"],
}

var _grid: Dictionary = {}      # ячейка -> { имя владельца: true }


func _initialize() -> void:
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

	_index(world_root, Transform3D.IDENTITY, "")
	print("индекс: %d ячеек" % _grid.size())

	var it := Interact.new()
	Interact.registerObjects(it, {"world": built})
	it.addLookTargets(props)

	var errs: Array[String] = []
	var seen: Dictionary = {}
	for d: Dictionary in it.list:
		var id := String(d["id"])
		if not EXPECT.has(id):
			continue
		seen[id] = true
		var row: Array = EXPECT[id]
		var owner := String(row[0])
		var pos: Vector3 = d["pos"]
		if not _owner_near(pos, owner):
			errs.append("«%s» [%.2f, %.2f, %.2f]: в %.2f м нет ни одного "
				% [id, pos.x, pos.y, pos.z, NEAR]
				+ "полигона «%s» (%s) — целиться не во что"
				% [owner, String(row[1])])
	for id: String in EXPECT:
		if not seen.has(id):
			errs.append("точки «%s» нет в списке Interact — таблица устарела" % id)

	props.dispose()
	world_root.free()

	if errs.is_empty():
		print("test_point_targets: PASS — %d точек со своим телом" % seen.size())
		quit(0)
		return
	print("FAIL test_point_targets: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


func _owner_near(pos: Vector3, owner: String) -> bool:
	var r := int(ceil(NEAR / CELL))
	var c := _cell(pos)
	for dx in range(-r, r + 1):
		for dy in range(-r, r + 1):
			for dz in range(-r, r + 1):
				var got: Variant = _grid.get(c + Vector3i(dx, dy, dz))
				if not (got is Dictionary):
					continue
				for name: String in (got as Dictionary):
					if name.begins_with(owner):
						return true
	return false


# --------------------------------------------------------------- индекс ----

# Владелец — узел верхнего уровня: прямой ребёнок world_root либо холдер
# внутри узла «props». Ниже этого уровня имена служебные («piece», «mi»),
# и различать по ним нечего.
func _index(node: Node, xf: Transform3D, owner: String) -> void:
	var here := xf
	if node is Node3D:
		here = xf * (node as Node3D).transform
		if owner != "" and node is MeshInstance3D:
			var mesh := (node as MeshInstance3D).mesh
			if mesh != null:
				_mesh(mesh, here, owner)
		elif owner != "" and node is MultiMeshInstance3D:
			var mm := (node as MultiMeshInstance3D).multimesh
			if mm != null and mm.mesh != null:
				var ab := mm.mesh.get_aabb()
				for i in mm.instance_count:
					var t := here * mm.get_instance_transform(i)
					_put(t * ab.get_center(), owner)
					for k in 8:
						_put(t * ab.get_endpoint(k), owner)
	for ch in node.get_children():
		var o := owner
		if owner == "" or node.name == "props":
			o = String(ch.name)
		_index(ch, here, o)


func _mesh(mesh: Mesh, xf: Transform3D, owner: String) -> void:
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		if arrays.size() <= Mesh.ARRAY_VERTEX:
			continue
		var vs: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] \
			if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
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
			_tri(a, b, c, owner, 0)


func _tri(a: Vector3, b: Vector3, c: Vector3, owner: String, depth: int) -> void:
	_put(a, owner)
	_put(b, owner)
	_put(c, owner)
	if depth >= 4:
		return
	var big := maxf(maxf(a.distance_to(b), b.distance_to(c)), c.distance_to(a))
	if big <= CELL * 0.8:
		return
	var ab := (a + b) * 0.5
	var bc := (b + c) * 0.5
	var ca := (c + a) * 0.5
	_tri(a, ab, ca, owner, depth + 1)
	_tri(ab, b, bc, owner, depth + 1)
	_tri(ca, bc, c, owner, depth + 1)
	_tri(ab, bc, ca, owner, depth + 1)


func _cell(p: Vector3) -> Vector3i:
	return Vector3i(int(floor(p.x / CELL)), int(floor(p.y / CELL)),
		int(floor(p.z / CELL)))


func _put(p: Vector3, owner: String) -> void:
	var k := _cell(p)
	var got: Variant = _grid.get(k)
	if got is Dictionary:
		(got as Dictionary)[owner] = true
		return
	_grid[k] = {owner: true}

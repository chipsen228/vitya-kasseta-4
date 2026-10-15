# Мелочь внутри дома и сарая — оверлей поверх принятого мира (фаза 12).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. Тот же довод, что у street_world.gd и yard_world.gd,
# и он машинный: коробки world_builder.gd сверяет tests/test_world_parity.gd
# (311 статики, 4 блокера, 83 коллайдера реквизита, 3885 треугольников),
# а data/props.json заморожен с фазы 8. Тёрке, миске и переехавшему телефону
# места в тех наборах нет — значит, они живут сбоку.
#
# ОТЛИЧИЕ ОТ ДВУХ СТАРШИХ ОВЕРЛЕЕВ, И ОНО ГЛАВНОЕ. Улица и участок кладут
# твёрдое в SET_OVERLAY. Здесь твёрдого нет ВОВСЕ, и это не экономия:
# четвёртый набор невидим для навграфа и для ai.gd, а граф дома испечён
# и заморожен (data/nav_baked.json). Одна твёрдая коробка на кухне — и дед
# ходит сквозь тумбу, а поймать это нечем: test_yard_nav_clear смотрит только
# на участок. Поэтому всё новое лежит НА уже существующих поверхностях
# реквизита, ничего не перегораживая: out["boxes"] здесь всегда пуст, и это
# утверждение, а не побочный эффект.
#
# ТЕЛЕФОН. Пётр: «телефон убрать из раковины и поставить на ту тумбу, где
# записка». Он и правда в раковине: props.json ставит phone-main на y = 1.12
# в точке (-1.555, 12.19), а замер меша мойки даёт там дно чаши 0.962 —
# аппарат висит в воздухе посреди раковины. props.json править нельзя, зато
# прятать узел на рантайме он не запрещает: старый гасится, новый строится
# здесь примитивами.
#
# Нет data/home.json — build() выходит первой строкой, и кухня ровно та,
# что принята в фазе 11.

class_name HomeWorld
extends RefCounted

const DATA := "res://data/home.json"

static var _cache: Variant = null


## Данные или пустой словарь. Кэш на процесс: файл читают и сборка, и тесты.
static func data() -> Dictionary:
	if _cache is Dictionary:
		return _cache
	var f := FileAccess.open(DATA, FileAccess.READ)
	if f == null:
		_cache = {}
		return _cache
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	_cache = parsed if parsed is Dictionary else {}
	return _cache


## Сборка. Зовётся из WorldBuilder._build_all() следом за YardWorld.build():
## к этому моменту дом, улица и участок собраны, и обвес ложится поверх.
static func build(b: WorldBuilder) -> Dictionary:
	var d := data()
	if d.is_empty():
		return {}

	var out: Dictionary = {
		"enabled": true,
		# Пустой массив здесь — не заглушка, а утверждение: внутри дома
		# твёрдой геометрии этот модуль не выпускает. См. шапку файла.
		"boxes": [],
		"nodes": {},
		"kitchen": d.get("KITCHEN", {}),
	}

	_kitchen(b, d.get("KITCHEN", {}), out)
	_kettle(b, d.get("KETTLE", {}), out)
	_windows(b, d.get("WINDOWS", {}), out)
	_tonya_room(b, d.get("TONYA_ROOM", {}), out)
	_loft(b, d.get("LOFT", {}), out)
	_shed(b, d.get("SHED", {}), out)
	return out


# ---------------------------------------------------------------- кухня ----

static func _kitchen(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var nodes: Dictionary = out["nodes"]
	nodes["kitchen-phone"] = _phone(b, _at(d, "phone", Vector3(-1.58, 1.29, 9.93)))
	nodes["kitchen-phone-numbers"] = _paper(b, "kitchen-phone-numbers",
		_at(d, "numbers", Vector3(-1.32, 1.292, 9.90)), 0.13, 0.16)
	nodes["kitchen-grater"] = _grater(b, "kitchen-grater",
		_at(d, "grater", Vector3(-1.10, 1.29, 10.48)), false)
	nodes["kitchen-bowl"] = _bowl(b, _at(d, "bowl", Vector3(-1.05, 1.29, 10.02)))
	# Та же тёрка, но в чаше мойки и плашмя. Второй узел, а не переезд первого:
	# знак «кухню перевернули» показывает обе сразу — пустое место на тумбе
	# и тёрку в раковине, — и держать это одним узлом значит помнить поворот.
	nodes["kitchen-grater-sink"] = _grater(b, "kitchen-grater-sink",
		_at(d, "graterSink", Vector3(-1.39, 0.975, 12.05)), true)
	nodes["kitchen-sugar"] = _sugar(b, d)


# Аппарат: корпус, трубка на рычагах и диск. Проводу здесь взяться неоткуда —
# розетка осталась у мойки, и шнур поэтому идёт по задней кромке тумбы.
static func _phone(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "kitchen-phone", pos)
	_piece(n, _box_mesh(b, Vector3(0.23, 0.075, 0.19), "", 0x1c1e21), Vector3(0, 0.037, 0))
	# Диск: восьмигранный цилиндр лежит на корпусе.
	var dial := CylinderMesh.new()
	dial.top_radius = 0.065
	dial.bottom_radius = 0.065
	dial.height = 0.014
	dial.radial_segments = 10
	dial.rings = 1
	dial.material = b.mats.flat(0x6f767c, true)
	_piece(n, dial, Vector3(0.0, 0.082, 0.03))
	# Рычаги и трубка поперёк корпуса.
	for s: float in [-0.075, 0.075]:
		_piece(n, _box_mesh(b, Vector3(0.03, 0.03, 0.05), "", 0x3a3f43),
			Vector3(s, 0.09, -0.055))
	_piece(n, _box_mesh(b, Vector3(0.20, 0.045, 0.055), "", 0x1c1e21),
		Vector3(0.0, 0.125, -0.055))
	for s: float in [-0.08, 0.08]:
		_piece(n, _box_mesh(b, Vector3(0.045, 0.055, 0.075), "", 0x1c1e21),
			Vector3(s, 0.125, -0.055))
	# Шнур к стене: одна доска-полоска по задней кромке, без провисания.
	_piece(n, _box_mesh(b, Vector3(0.012, 0.012, 0.26), "", 0x2b2f33),
		Vector3(-0.09, 0.006, -0.20))
	return n


# --------------------------------------------------------- комната Тони ----

## Бывшая комната Тони за w-sealed. Вся видимая геометрия декоративная;
## только четыре предмета крупной мебели получают точные локальные объёмы в
## SET_OVERLAY. Они стоят вдоль стен и не занимают проём x 0.175..1.025,
## z=13.8 или проход от него к западной стороне кровати.
static func _tonya_room(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var nodes: Dictionary = out["nodes"]
	var bed_at := _at(d, "bed", Vector3(-1.20, 3.30, 15.18))
	var bed := _holder(b, "tonya-bed", bed_at)
	# Узкая железная кровать: рама, четыре стойки и аккуратно заправленное бельё.
	_piece(bed, _box_mesh(b, Vector3(1.02, 0.10, 1.72), "", 0x4e5459),
		Vector3(0, 0.30, 0))
	for x: float in [-0.47, 0.47]:
		for z: float in [-0.80, 0.80]:
			_piece(bed, _box_mesh(b, Vector3(0.045, 0.72, 0.045), "", 0x6f767c),
				Vector3(x, 0.36, z))
	_piece(bed, _box_mesh(b, Vector3(0.92, 0.17, 1.62), "", 0x827b6b),
		Vector3(0, 0.43, 0))
	_piece(bed, _box_mesh(b, Vector3(0.94, 0.035, 1.35), "", 0xb0a897),
		Vector3(0, 0.53, 0.10))
	_piece(bed, _box_mesh(b, Vector3(0.54, 0.11, 0.30), "", 0xc0b8a5),
		Vector3(0, 0.55, -0.62))
	# Человеческая вмятина не нарушает аккуратный силуэт покрывала.
	var dent := SphereMesh.new()
	dent.radius = 0.22
	dent.height = 0.055
	dent.radial_segments = 10
	dent.rings = 3
	dent.material = b.mats.flat(0x6b655a, true)
	_piece(bed, dent, Vector3(0.08, 0.558, 0.18))
	# Красная нить связывает три гвоздя на изголовье; четвёртый конец уходит
	# вниз к раме. Сегменты детерминированы и собраны без Line3D.
	var thread_points := [Vector3(-0.34, 0.93, -0.82), Vector3(0.0, 1.04, -0.82),
		Vector3(0.35, 0.90, -0.82), Vector3(0.47, 0.36, -0.80)]
	for p: Vector3 in thread_points.slice(0, 3):
		_piece(bed, _box_mesh(b, Vector3(0.025, 0.025, 0.06), "", 0x3a3f43), p)
	for i in thread_points.size() - 1:
		_segment(b, bed, thread_points[i], thread_points[i + 1], 0.012, 0x8b302c)
	# Разорванный соляной круг виден у открытой стороны из-под рамы.
	for i in 14:
		if i in [2, 3, 9]:
			continue
		var a := float(i) * TAU / 14.0
		_piece(bed, _box_mesh(b, Vector3(0.13, 0.008, 0.035), "", 0xd0c9b3),
			Vector3(cos(a) * 0.52, 0.008, sin(a) * 0.66), Vector3(0, -a, 0))
	nodes["tonya-bed"] = bed
	_solid_local(b, out, bed_at, Vector3(1.08, 0.82, 1.78), "tonya-bed")

	var ns_at := _at(d, "nightstand", Vector3(-0.28, 3.30, 15.72))
	var ns := _holder(b, "tonya-nightstand", ns_at)
	_piece(ns, _box_mesh(b, Vector3(0.46, 0.62, 0.40), "", 0x66472f),
		Vector3(0, 0.31, 0))
	for y: float in [0.22, 0.44]:
		_piece(ns, _box_mesh(b, Vector3(0.34, 0.018, 0.018), "", 0x8b9095),
			Vector3(0, y, -0.205))
	# Очки, лекарства, платок и сложенное бельё — нормальный порядок вещей,
	# оставленный так, будто хозяйка вернётся вечером.
	for x: float in [-0.075, 0.075]:
		var lens := TorusMesh.new()
		lens.inner_radius = 0.035
		lens.outer_radius = 0.044
		lens.rings = 8
		lens.ring_segments = 4
		lens.material = b.mats.flat(0x3a3f43, true)
		_piece(ns, lens, Vector3(x, 0.642, -0.04), Vector3(PI / 2.0, 0, 0))
	_piece(ns, _box_mesh(b, Vector3(0.17, 0.01, 0.012), "", 0x3a3f43),
		Vector3(0, 0.642, -0.04))
	for i in 3:
		var bottle := CylinderMesh.new()
		bottle.top_radius = 0.025 + i * 0.004
		bottle.bottom_radius = bottle.top_radius
		bottle.height = 0.08 + i * 0.02
		bottle.radial_segments = 7
		bottle.material = b.mats.flat(0x7c684d if i != 1 else 0x6f765d, true)
		_piece(ns, bottle, Vector3(-0.14 + i * 0.08, 0.66 + bottle.height / 2.0, 0.10))
	_piece(ns, _box_mesh(b, Vector3(0.24, 0.018, 0.19), "", 0x8a554e),
		Vector3(0.10, 0.641, 0.02), Vector3(0, 0.24, 0))
	nodes["tonya-nightstand"] = ns
	_solid_local(b, out, ns_at, Vector3(0.48, 0.64, 0.42), "tonya-nightstand")

	var chest_at := _at(d, "chest", Vector3(1.58, 3.30, 15.72))
	var chest := _holder(b, "tonya-chest", chest_at)
	_piece(chest, _box_mesh(b, Vector3(0.88, 0.48, 0.55), "", 0x5d4029),
		Vector3(0, 0.24, 0))
	_piece(chest, _box_mesh(b, Vector3(0.90, 0.08, 0.57), "", 0x7a5938),
		Vector3(0, 0.52, 0))
	_piece(chest, _box_mesh(b, Vector3(0.10, 0.14, 0.025), "", 0x8b9095),
		Vector3(0, 0.30, -0.29))
	for i in 3:
		_piece(chest, _box_mesh(b, Vector3(0.62 - i * 0.05, 0.055, 0.32), "",
			0xb4ad9c if i != 1 else 0x83766a), Vector3(0, 0.58 + i * 0.05, 0))
	nodes["tonya-chest"] = chest
	_solid_local(b, out, chest_at, Vector3(0.92, 0.70, 0.59), "tonya-chest")

	var chair_at := _at(d, "chair", Vector3(1.43, 3.30, 14.63))
	var chair := _holder(b, "tonya-chair", chair_at)
	_piece(chair, _box_mesh(b, Vector3(0.46, 0.08, 0.44), "", 0x6a4a30),
		Vector3(0, 0.48, 0))
	for x: float in [-0.19, 0.19]:
		for z: float in [-0.17, 0.17]:
			_piece(chair, _box_mesh(b, Vector3(0.045, 0.48, 0.045), "", 0x5d4029),
				Vector3(x, 0.24, z))
	_piece(chair, _box_mesh(b, Vector3(0.46, 0.64, 0.06), "", 0x6a4a30),
		Vector3(0, 0.82, 0.19))
	nodes["tonya-chair"] = chair
	_solid_local(b, out, chair_at, Vector3(0.50, 1.15, 0.48), "tonya-chair")

	# Эмалированный таз у сундука.
	var basin_at := _at(d, "basin", Vector3(0.82, 3.30, 15.80))
	var basin := _holder(b, "tonya-basin", basin_at)
	var bowl := CylinderMesh.new()
	bowl.top_radius = 0.28
	bowl.bottom_radius = 0.20
	bowl.height = 0.12
	bowl.radial_segments = 12
	bowl.material = b.mats.flat(0xb6b2a3, true)
	_piece(basin, bowl, Vector3(0, 0.06, 0))
	var rim := TorusMesh.new()
	rim.inner_radius = 0.27
	rim.outer_radius = 0.29
	rim.rings = 12
	rim.ring_segments = 5
	rim.material = b.mats.flat(0x4e6170, true)
	_piece(basin, rim, Vector3(0, 0.12, 0))
	nodes["tonya-basin"] = basin

	# Перевёрнутое семейное фото лежит на тумбе оборотом вверх.
	var photo_at := _at(d, "photo", Vector3(-0.28, 3.94, 15.70))
	var photo := _holder(b, "tonya-photo", photo_at)
	_piece(photo, _box_mesh(b, Vector3(0.28, 0.018, 0.21), "", 0x5b3f28),
		Vector3.ZERO, Vector3(0, 0.18, 0))
	_piece(photo, _box_mesh(b, Vector3(0.24, 0.005, 0.17), "", 0xc9c3ac),
		Vector3(0, 0.012, 0), Vector3(0, 0.18, 0))
	nodes["tonya-photo"] = photo


static func _solid_local(b: WorldBuilder, out: Dictionary, center: Vector3,
		size: Vector3, id: String) -> void:
	b.col.add_box_d(CollisionWorld.SET_OVERLAY, center.x - size.x * 0.5, center.y,
		center.z - size.z * 0.5, center.x + size.x * 0.5, center.y + size.y,
		center.z + size.z * 0.5, id)
	(out["boxes"] as Array).append(AABB(center - Vector3(size.x * 0.5, 0.0, size.z * 0.5),
		size))


static func _segment(b: WorldBuilder, parent: Node3D, a: Vector3, z: Vector3,
		thickness: float, hex: int) -> void:
	var delta := z - a
	var length := delta.length()
	if length < 0.001:
		return
	var mi := _piece(parent, _box_mesh(b, Vector3(thickness, thickness, length), "", hex),
		(a + z) * 0.5)
	mi.look_at_from_position(mi.position, z, Vector3.UP)


# Эмалированная миска. Внутри — горка натёртого: отдельный ребёнок, потому
# что после блэкаута миска обязана оказаться ПУСТОЙ и вылизанной, а сама
# миска при этом стоит на месте.
static func _bowl(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "kitchen-bowl", pos)
	var body := CylinderMesh.new()
	body.top_radius = 0.135
	body.bottom_radius = 0.085
	body.height = 0.085
	body.radial_segments = 10
	body.rings = 1
	body.material = b.mats.flat(0xc9c3ac, true)
	_piece(n, body, Vector3(0, 0.043, 0))
	var rim := TorusMesh.new()
	rim.inner_radius = 0.128
	rim.outer_radius = 0.142
	rim.rings = 10
	rim.ring_segments = 5
	rim.material = b.mats.flat(0x4e5459, true)
	_piece(n, rim, Vector3(0, 0.085, 0))
	# Горка натёртых яблок с сахаром. Невидима до того, как игрок натрёт.
	var heap := MeshInstance3D.new()
	heap.name = "heap"
	var hm := CylinderMesh.new()
	hm.top_radius = 0.02
	hm.bottom_radius = 0.115
	hm.height = 0.055
	hm.radial_segments = 10
	hm.rings = 1
	hm.material = b.mats.flat(0xa38a63, true)
	heap.mesh = hm
	heap.position = Vector3(0, 0.062, 0)
	heap.visible = false
	heap.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.add_child(heap)
	return n


# Тёрка: четырёхгранная жестянка с ручкой. flat = лежит плашмя (в мойке).
static func _grater(b: WorldBuilder, id: String, pos: Vector3, flat: bool) -> Node3D:
	var n := _holder(b, id, pos)
	var rot := Vector3(PI * 0.5, 0.32, 0.0) if flat else Vector3.ZERO
	n.rotation = rot
	_piece(n, _box_mesh(b, Vector3(0.085, 0.215, 0.062), "", 0x8b9095), Vector3(0, 0.108, 0))
	_piece(n, _box_mesh(b, Vector3(0.095, 0.012, 0.072), "", 0x6f767c), Vector3(0, 0.215, 0))
	_piece(n, _box_mesh(b, Vector3(0.035, 0.048, 0.012), "", 0x6f767c), Vector3(0, 0.248, 0))
	return n


# Дорожка рассыпанного сахара. Одна нода со всеми пятнами: показывать и прятать
# их надо разом, а по одному — это полсотни лишних вызовов отрисовки.
# Ломаная идёт через настоящие проёмы, а не сквозь стены: кухня -> веранда
# -> крышка люка. Маршрут лежит в data/home.json и сверяется тестом.
static func _sugar(b: WorldBuilder, d: Dictionary) -> Node3D:
	var n := _holder(b, "kitchen-sugar", Vector3.ZERO, false)
	var route: Array = d.get("sugar", [])
	if route.size() < 2:
		return n
	var y := float(d.get("sugarY", 0.462))
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.16, 0.004, 0.11)
	mesh.material = b.mats.flat(0xc9c3ac, true)
	var step := 0.30
	var carry := 0.0
	var k := 0
	for i in route.size() - 1:
		var a: Array = route[i]
		var c: Array = route[i + 1]
		var p0 := Vector2(float(a[0]), float(a[1]))
		var p1 := Vector2(float(c[0]), float(c[1]))
		var seg := p0.distance_to(p1)
		if seg < 1e-4:
			continue
		var dir := (p1 - p0) / seg
		var nrm := Vector2(-dir.y, dir.x)
		var t := carry
		while t < seg:
			# Смещение поперёк идёт синусом, а не случайно: сборка мира обязана
			# быть повторяемой, иначе два запуска дают разные картинки.
			var off := 0.085 * sin(float(k) * 2.3)
			var p := p0 + dir * t + nrm * off
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.position = Vector3(p.x, y + 0.002 * float(k % 3), p.y)
			mi.rotation = Vector3(0.0, atan2(dir.x, dir.y) + off, 0.0)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			n.add_child(mi)
			k += 1
			t += step
		carry = t - seg
	return n


# ---------------------------------------------------------------- чайник ----

# Чайник на плите — заряженное прерывание, а не украшение. Игрок ставит его
# в главе СВЕТ и уходит наверх; свистит он в МАНСАРДЕ, когда игрок один
# на чердаке. Скачок — это прерывание цикла на пике нагрузки, и весь фокус
# в том, что запустил его сам игрок сорок минут назад.
static func _kettle(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var n := _holder(b, "kitchen-kettle", _at(d, "at", Vector3(0.34, 1.34, 9.97)), false)
	var body := CylinderMesh.new()
	body.top_radius = 0.085
	body.bottom_radius = 0.105
	body.height = 0.19
	body.radial_segments = 10
	body.rings = 1
	body.material = b.mats.flat(0xa8aeb3, true)
	_piece(n, body, Vector3(0, 0.095, 0))
	_piece(n, _box_mesh(b, Vector3(0.055, 0.05, 0.055), "", 0x1c1e21), Vector3(0, 0.21, 0))
	# Носик и ручка дугой.
	_piece(n, _box_mesh(b, Vector3(0.13, 0.035, 0.035), "", 0xa8aeb3),
		Vector3(0.115, 0.13, 0), Vector3(0.0, 0.0, 0.35))
	_piece(n, _box_mesh(b, Vector3(0.02, 0.13, 0.02), "", 0x1c1e21), Vector3(-0.09, 0.19, 0))
	_piece(n, _box_mesh(b, Vector3(0.02, 0.13, 0.02), "", 0x1c1e21), Vector3(0.06, 0.19, 0))
	_piece(n, _box_mesh(b, Vector3(0.17, 0.022, 0.022), "", 0x1c1e21), Vector3(-0.015, 0.25, 0))
	(out["nodes"] as Dictionary)["kitchen-kettle"] = n


# ----------------------------------------------------------------- окна ----

# Три форточки в наружных стенах первого этажа. Открыты с начала игры и
# закрываются по одной: рутина, ради которой игрок обойдёт весь этаж.
# Третья уже закрыта, и рама у неё изнутри мокрая — на это он и наткнётся.
#
# ФАЗА 13, «на лестнице висит кусок стекла». Створка hall стояла в проёме
# w-w1 на z = 10.90 — ровно посреди нижнего марша, — и, отвёрнутая внутрь
# на 0.96 рад, вылезала из стены в лестницу. Читалась она при этом не
# створкой, а отдельным куском стекла, и вот почему: проём уже закрыт
# сплошной плоскостью стекла из world_builder._frame_hole(), обвязки у
# полотна не было ВООБЩЕ (одна планка сверху), и глазу не за что зацепиться,
# чтобы понять, где рама.
#
# Лечится двумя правками, и обе здесь. Первая — данные: форточка переезжает
# на третий проём той же стены (data/home.json, z 13.60, за площадкой).
# Вторая — эта функция: обвязка кладётся со ВСЕХ четырёх сторон, и угол
# раскрытия берётся из данных ("open"), а не зашит числом.
## Насколько створка утоплена в комнату относительно плоскости стекла (ф. 15).
const INSET := 0.06


## Проёмы, в которых стоит форточка. Ключ — "линия|середина" с двумя знаками
## после запятой: ровно те два числа, по которым проём узнаёт world_builder,
## и не зависящие от того, как называется стена. Нужны ему для одного —
## не класть в такой проём сплошную плоскость стекла (см. _frame_hole).
static func window_holes() -> Dictionary:
	var out: Dictionary = {}
	var d := data()
	if d.is_empty():
		return out
	var w: Dictionary = d.get("WINDOWS", {})
	for row: Variant in w.get("list", []):
		if not (row is Dictionary):
			continue
		var r: Dictionary = row
		out["%.2f|%.2f" % [float(r.get("line", 0.0)), float(r.get("at", 0.0))]] = true
	return out


static func _windows(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var w := float(d.get("w", 0.46))
	var h := float(d.get("h", 0.40))
	var nodes: Dictionary = out["nodes"]
	for row: Variant in d.get("list", []):
		if not (row is Dictionary):
			continue
		var r: Dictionary = row
		var id := "window-" + String(r.get("id", "?"))
		var line := float(r.get("line", 0.0))
		var at := float(r.get("at", 0.0))
		var y := float(r.get("y", 1.72))
		var inward := float(r.get("inward", 1.0))
		var horiz := String(r.get("axis", "x")) == "x"   # стена идёт по z
		# Полотно уходит вглубь комнаты на INSET. Раньше оно стояло ровно
		# в плоскости стекла и прошивало его насквозь: с одной стороны кадра
		# створка была перед стеклом, с другой — за ним, и глаз читал не
		# форточку, а дырку. Знак берётся из inward — той же цифры, которой
		# задан поворот: у западной стены внутрь это +x, у южной −z.
		var pos := Vector3(line + inward * INSET, y, at) if horiz \
			else Vector3(at, y, line + inward * INSET)
		var n := _holder(b, id, pos)
		# Петля у одной кромки: створка открывается поворотом ГРУППЫ, поэтому
		# полотно смещено на полширины от начала координат ноды.
		var leaf := Node3D.new()
		leaf.name = "leaf"
		var mi := MeshInstance3D.new()
		var bm := BoxMesh.new()
		bm.size = Vector3(0.035, h, w) if horiz else Vector3(w, h, 0.035)
		mi.mesh = bm
		mi.material_override = b.mats.get_mat("glass")
		mi.position = Vector3(0, 0, w / 2.0) if horiz else Vector3(w / 2.0, 0, 0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		leaf.add_child(mi)
		# Обвязка по всем четырём сторонам полотна. Раньше стояла одна планка
		# сверху, и открытая створка читалась куском стекла, висящим само по
		# себе, — тем самым, который Пётр увидел на лестнице. Рамка по кругу
		# стоит четыре коробки и решает это целиком: даже когда стекло в тумане
		# не читается вовсе, видно, где полотно и куда оно отвёрнуто.
		var bar := 0.03
		var jamb := 0.05
		var trim := b.mats.flat(0xd8d2c2, true)
		var frames: Array = []
		if horiz:
			frames = [
				[Vector3(jamb, bar, w), Vector3(0, h / 2.0 - bar / 2.0, 0)],
				[Vector3(jamb, bar, w), Vector3(0, -h / 2.0 + bar / 2.0, 0)],
				[Vector3(jamb, h, bar), Vector3(0, 0, -w / 2.0 + bar / 2.0)],
				[Vector3(jamb, h, bar), Vector3(0, 0, w / 2.0 - bar / 2.0)],
			]
		else:
			frames = [
				[Vector3(w, bar, jamb), Vector3(0, h / 2.0 - bar / 2.0, 0)],
				[Vector3(w, bar, jamb), Vector3(0, -h / 2.0 + bar / 2.0, 0)],
				[Vector3(bar, h, jamb), Vector3(-w / 2.0 + bar / 2.0, 0, 0)],
				[Vector3(bar, h, jamb), Vector3(w / 2.0 - bar / 2.0, 0, 0)],
			]
		for bar_row: Array in frames:
			var fr := MeshInstance3D.new()
			var fm := BoxMesh.new()
			fm.size = bar_row[0]
			fr.mesh = fm
			fr.material_override = trim
			fr.position = mi.position + (bar_row[1] as Vector3)
			fr.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			leaf.add_child(fr)
		leaf.position = Vector3(0, 0, -w / 2.0) if horiz else Vector3(-w / 2.0, 0, 0)
		# Открыта: створка отвёрнута внутрь комнаты. Угол из данных — у форточки
		# в коридоре он меньше, ей там некуда раскрываться на полные 55 градусов.
		leaf.rotation.y = inward * float(r.get("open", 0.96))
		n.add_child(leaf)
		nodes[id] = n


# ---------------------------------------------------------------- чердак ----

# То, что дед снёс наверх девятого августа, отняв у соседа (DIARY). Тетрадь
# наблюдений уже лежит здесь с фазы 8; фаза 12 добавляет рядом две вещи,
# которые эту тетрадь объясняют: след от штатива в пыли и кассету с этикеткой
# чужим почерком. Первый крючок на Ковригина, и он ничего не говорит вслух.
static func _loft(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var nodes: Dictionary = out["nodes"]

	var al := _at(d, "album", Vector3(-1.90, 5.90, 13.05))
	var album := _holder(b, "attic-album", al)
	_piece(album, _box_mesh(b, Vector3(0.30, 0.075, 0.38), "", 0x4a3524),
		Vector3(0, 0.038, 0), Vector3(0.0, 0.18, 0.0))
	_piece(album, _box_mesh(b, Vector3(0.27, 0.05, 0.35), "", 0xc9c3ac),
		Vector3(0.006, 0.038, 0.004), Vector3(0.0, 0.18, 0.0))
	# Завязки.
	_piece(album, _box_mesh(b, Vector3(0.33, 0.008, 0.03), "", 0x8a5540),
		Vector3(0, 0.078, 0.06), Vector3(0.0, 0.18, 0.0))
	nodes["attic-album"] = album

	var tm := _at(d, "tripodMark", Vector3(-2.92, 5.90, 12.80))
	var mark := _holder(b, "tripod-mark", tm)
	# Три вмятины треугольником: в пыли остаётся ровно это.
	for i in 3:
		var a := float(i) * TAU / 3.0 + 0.4
		_piece(mark, _box_mesh(b, Vector3(0.075, 0.004, 0.075), "", 0x2b2f33),
			Vector3(cos(a) * 0.19, 0.002, sin(a) * 0.19), Vector3(0.0, a, 0.0))
	# И кассета с этикеткой не дедовым почерком.
	_piece(mark, _box_mesh(b, Vector3(0.19, 0.028, 0.11), "", 0x1c1e21),
		Vector3(0.26, 0.014, -0.10), Vector3(0.0, 0.22, 0.0))
	_piece(mark, _box_mesh(b, Vector3(0.14, 0.004, 0.055), "", 0xc9c3ac),
		Vector3(0.26, 0.029, -0.10), Vector3(0.0, 0.22, 0.0))
	nodes["tripod-mark"] = mark

	# ФАЗА 13. Резиновая кукла с лицом старухи — просьба Петра, и она нарочно
	# сидит в стороне от всего, что здесь что-то значит. Задания у неё нет,
	# события нет, стингера нет: игрок посветит фонарём в северо-западный угол
	# и увидит, что оттуда на него смотрят. Дальше он решает сам.
	var dl := _at(d, "doll", Vector3(-4.10, 5.90, 10.85))
	var doll := _holder(b, "loft-doll", dl)
	doll.rotation.y = 0.62
	# Сидит, привалившись к стропилу: ноги вперёд, руки вдоль тела.
	_piece(doll, _box_mesh(b, Vector3(0.20, 0.34, 0.15), "", 0xc9c3ac), Vector3(0, 0.30, 0))
	_piece(doll, _box_mesh(b, Vector3(0.13, 0.09, 0.36), "", 0xc9c3ac),
		Vector3(0, 0.075, 0.20))
	for s: float in [-0.13, 0.13]:
		_piece(doll, _box_mesh(b, Vector3(0.06, 0.28, 0.06), "", 0xc9c3ac),
			Vector3(s, 0.30, 0.03))
	# Голова взрослого размера на детском теле — это и есть вся неправильность.
	_piece(doll, _box_mesh(b, Vector3(0.22, 0.25, 0.20), "", 0xb6ae9a), Vector3(0, 0.60, 0))
	_piece(doll, _box_mesh(b, Vector3(0.24, 0.13, 0.21), "", 0x8b9095),
		Vector3(0, 0.68, -0.005))
	for s: float in [-0.05, 0.05]:
		_piece(doll, _box_mesh(b, Vector3(0.035, 0.02, 0.01), "", 0x1c1e21),
			Vector3(s, 0.60, 0.101))
	nodes["loft-doll"] = doll


# ----------------------------------------------------------------- сарай ----

# Вещи, которые Серёжа занёс в дом первой же минутой игры («Всё. Больше ничего
# не забыл»), лежат аккуратным рядком на верстаке в сарае. Ни фигуры, ни звука,
# ни стингера: страшно ровно то, что их кто-то принёс и разложил по порядку.
static func _shed(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var at := _at(d, "row", Vector3(7.46, 1.03, 11.52))
	var step := float(d.get("step", 0.145))
	var n := _holder(b, "shed-things", at, false)
	var z := 0.0
	# Пять вещей и все узнаваемые: очки, бумажник, ключи от квартиры,
	# пачка сигарет, зажигалка. Всё это игрок оставил в доме.
	_piece(n, _box_mesh(b, Vector3(0.055, 0.018, 0.13), "", 0x1c1e21), Vector3(0, 0.009, z))
	_piece(n, _box_mesh(b, Vector3(0.045, 0.012, 0.045), "", 0x3d4b52),
		Vector3(0.035, 0.012, z - 0.045), Vector3(0.0, 0.0, 0.0))
	z += step
	_piece(n, _box_mesh(b, Vector3(0.095, 0.022, 0.115), "", 0x5d4530), Vector3(0, 0.011, z))
	z += step
	for i in 3:
		_piece(n, _box_mesh(b, Vector3(0.012, 0.006, 0.055), "", 0x8b9095),
			Vector3(-0.02 + i * 0.02, 0.004, z), Vector3(0.0, 0.14 * float(i - 1), 0.0))
	_piece(n, _box_mesh(b, Vector3(0.03, 0.008, 0.03), "", 0x6f767c), Vector3(0.0, 0.005, z + 0.04))
	z += step
	_piece(n, _box_mesh(b, Vector3(0.055, 0.024, 0.085), "", 0x9c6a3a), Vector3(0, 0.012, z))
	z += step
	_piece(n, _box_mesh(b, Vector3(0.024, 0.014, 0.055), "", 0x54703f), Vector3(0, 0.008, z))
	(out["nodes"] as Dictionary)["shed-things"] = n


# ------------------------------------------------------------- служебное ----

static func _holder(b: WorldBuilder, id: String, pos: Vector3, shown := true) -> Node3D:
	var n := Node3D.new()
	n.name = "home-" + id
	n.position = pos
	n.visible = shown
	b.decor["home-" + id] = n
	return n


static func _piece(parent: Node3D, mesh: Mesh, at: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _box_mesh(b: WorldBuilder, size: Vector3, key: String, exact_hex := -1) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	m.material = b.mats.flat(exact_hex, true) if exact_hex >= 0 else b.mats.get_mat(key)
	return m


static func _paper(b: WorldBuilder, id: String, pos: Vector3, w: float, l: float) -> Node3D:
	var n := _holder(b, id, pos)
	_piece(n, _box_mesh(b, Vector3(w, 0.005, l), "", 0xc9c3ac), Vector3(0, 0.0025, 0),
		Vector3(0.0, 0.11, 0.0))
	return n


static func _at(d: Dictionary, key: String, def: Vector3) -> Vector3:
	var a: Array = d.get(key, [])
	if a.size() != 3:
		return def
	return Vector3(float(a[0]), float(a[1]), float(a[2]))

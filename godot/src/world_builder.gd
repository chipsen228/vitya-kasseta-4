# Генератор геометрии участка — порт src/world/build.js.
#
# Всё, что можно, сливается в одну сетку на материал: иначе на семьдесят стен и
# полтора десятка построек уходит триста draw calls. Развёртка считается по мировым
# координатам (worldUv), поэтому доски идут через всю стену, а не начинаются заново
# на каждом куске у дверного проёма.
#
# Коллизии уезжают в CollisionWorld двумя наборами: статика мира и блокеры
# (запертые двери и створки ворот). Порядок и числа вызовов box/clip/slab/... —
# дословно из оригинала: их сверяет tests/test_world_parity.gd по мультимножеству
# AABB из parity/world_boxes.json.

class_name WorldBuilder
extends RefCounted

const VISUAL_DRESSING := preload("res://src/visual_dressing.gd")
const RURAL_DRESSING := preload("res://src/rural_dressing.gd")

# Стены чердака стоят выше ската и торчали сквозь кровлю наружу — от ворот дом
# читался лесенкой из плоских коробок, а не домом. Коробки коллизий у них
# обязаны остаться прежними (их сверяет test_world_parity), поэтому в общий
# проход они идут collide_only, а видимую часть заново кладёт _attic_patch()
# уже подрезанной по скату. Тем же способом подрезается потолок чердака.
const CLIP_WALLS := ["w-n3", "w-s3", "w-w3", "w-e3"]
const CLIP_SLAB_Y := 7.85

var mats: Materials
var col: CollisionWorld
var site: Dictionary

# Проёмы, в которые не идёт плоскость стекла: там стоит форточка (ф. 15).
var _no_glass: Dictionary = {}

var buckets: Dictionary = {}       # ключ материала -> {v, n, uv}
var _skin_ranges: Dictionary = {}
var _skin_parts_info: Dictionary = {}
var _skin_tree_info: Dictionary = {}
var _forest_lows: Dictionary = {}
var blockers: Array = []           # [{id, box: AABB, active, node}]
var decor: Dictionary = {}         # id -> Node3D (двери, створки)
var low_poly_tree_rows: Array = [] # общий отложенный MultiMesh леса
# Улица за воротами (фаза 9). Пусто — файла data/street.json нет, и мир ровно
# тот, что принят в фазе 8.
var street: Dictionary = {}
# Участок с фотографии (фаза 11): баня, погреб, дорожки, заборы, лес. Пусто —
# файла data/yard.json нет, и участок ровно тот, что принят в раунде 10.
var yard: Dictionary = {}
# Деревня (фаза 12): остановка, колодец, будка, погост, сельпо и заколоченный
# дом изнутри. Пусто — нет data/village.json, и улица ровно та, что принята
# в фазе 11.
var village: Dictionary = {}
# Мелочь внутри дома и сарая (фаза 12). Пусто — нет data/home.json.
var home: Dictionary = {}
# Околица (фаза 14): переулки, вторая линия, семь участков. Пусто — нет
# data/outskirts.json.
var outskirts: Dictionary = {}
# СНТ за околицей (фаза 16): проезды, участки, озеро, лес. Пусто — нет
# data/snt.json, и мир ровно тот, что принят в блоке 4.
var snt: Dictionary = {}

# Зелень MultiMesh'ем (фаза 14): {"nodes","layout","instances","surfaces"}.
# Пуст, если нет data/scatter.json.
# Линия бабки Вали (фаза 15). Пусто — нет data/valya.json, и мир ровно тот,
# что принят в части 1.
var valya: Dictionary = {}

# Визуальная обстановка поверх готовых локаций. Пусто — файла нет или схема
# невалидна; на коллизии, навигацию, интерактив и сохранения слой не влияет.
var visual_dressing: Dictionary = {}

var scatter: Dictionary = {}
# «Треугольники» finish() оригинала — это position.count/3 ИНДЕКСИРОВАННОЙ
# геометрии, то есть вершины/3, а не настоящие треугольники (у бокса 24 вершины
# и 12 треугольников). Копим вершины, чтобы boot-лог сошёлся с браузерным 3885.
var collide_verts := 0
var _extra_scale: Dictionary = {"meshfence": Materials.FENCE_SCALE}


# ---------- точка входа ----------

static func build(world_root: Node3D, materials: Materials, world_col: CollisionWorld) -> Dictionary:
	var b := WorldBuilder.new()
	b.mats = materials
	b.col = world_col
	b.site = GameData.site()
	RURAL_DRESSING._placement_cache.clear()
	b._build_all()
	var rural: Dictionary = RURAL_DRESSING.build(b)
	StreetWorld.flush_low_poly_trees(b)
	# Строго до _finish: семантическая геометрия попадает в существующие
	# material-bucket machinery; visual:-prefix isolates culling and shadows,
	# бумага и патина при этом остаются ровно в двух своих ArrayMesh.
	b.visual_dressing = VISUAL_DRESSING.build(b)
	var visual_batch: Dictionary = preload("res://src/static_visual_batch.gd").build(b.decor)
	b._finish(world_root)
	var shadow_batch: Dictionary = preload("res://src/static_shadow_batch.gd").prepare(world_root)
	var zones: Array = b.site["ZONES"]
	var zone_at := func(x: float, y: float, z: float) -> Dictionary:
		return WorldBuilder.zone_at_in(zones, x, y, z)
	return {
		"blockers": b.blockers,
		"decor": b.decor,
		"visual_batch": visual_batch,
		"shadow_batch": shadow_batch,
		"zone_at": zone_at,
		"triangles": int(b.collide_verts / 3.0),
		"street": b.street,
		"yard": b.yard,
		"village": b.village,
		"home": b.home,
		"outskirts": b.outskirts,
		"snt": b.snt,
		"valya": b.valya,
		"scatter": b.scatter,
		"visual_dressing": b.visual_dressing,
		"rural": rural,
	}


# Зона по точке: перебор с конца, как в zoneAt() оригинала.
static func zone_at_in(zones: Array, x: float, y: float, z: float) -> Dictionary:
	for i in range(zones.size() - 1, -1, -1):
		var zn: Dictionary = zones[i]
		var r: Array = zn["rect"]
		var yy: Array = zn["y"]
		if x >= r[0] and x <= r[1] and z >= r[2] and z <= r[3] and y >= yy[0] and y <= yy[1]:
			return zn
	return zones[0]


func _build_all() -> void:
	var Y: Dictionary = site["Y"]
	var rooms: Dictionary = site["ROOMS"]
	ground()
	poles()
	neighbours()
	var slab_index := 0
	for s: Dictionary in site["SLABS"]:
		var slab_mark := skin_begin("buildings", "site", "SLABS-%d" % slab_index)
		slab(s["r"], s["y"], s["t"], s["mat"], float(s.get("seg", 0.0)),
			is_equal_approx(float(s["y"]), CLIP_SLAB_Y))
		skin_end(slab_mark)
		slab_index += 1
	# Проёмы с форточкой — до стен: в них не идёт плоскость стекла (ф. 15).
	# HomeWorld кэширует свой файл на процесс, так что спросить его раньше,
	# чем он соберётся, ничего не стоит; нет файла — словарь пуст, и окна
	# ровно те, что были.
	_no_glass = HomeWorld.window_holes()
	for w: Dictionary in site["WALLS"]:
		var skin_wall := skin_begin("buildings", "site", String(w.get("id", "")), "WALLS")
		wall(w)
		skin_end(skin_wall)
	var skin_roof_index := 0
	for r: Dictionary in site["ROOFS"]:
		var skin_roof := skin_begin("buildings", "site", String(r.get("id", "")), "ROOFS-%d" % skin_roof_index)
		roof(r)
		skin_end(skin_roof)
		skin_roof_index += 1
	for s: Dictionary in site["STAIRS"]:
		var skin_stairs := skin_begin("buildings", "site", String(s.get("id", "")), "STAIRS")
		stairs(s)
		skin_end(skin_stairs)
	for r: Dictionary in site["RAILS"]:
		rail(r)
	for f: Dictionary in site["FENCES"]:
		fence(f)

	# Двери с полотном: входная в дом и дверь сарая — обе в проёмах из site.js.
	door_leaf("door-front", -2.3, 6.6, 0.9, 2.05, float(Y["FLOOR1"]), "x", "siding", true)
	door_leaf("door-shed", 6.8, 10.0, 1.0, 1.95, float(Y["GROUND"]), "x", "shedwood", false)

	# Теплица: каркас и мутные стёкла.
	var gh: Dictionary = rooms["greenhouse"]
	var skin_greenhouse := skin_begin("buildings", "site", String(gh.get("id", "")), "greenhouse")
	var gx: Array = gh["x"]
	var gz: Array = gh["z"]
	var ghh := float(gh["h"])
	for i in 7:
		var z: float = gz[0] + (gz[1] - gz[0]) * i / 6.0
		box(gx[0], gx[0] + 0.06, 0, ghh, z - 0.03, z + 0.03, "metal", 1.5)
		box(gx[1] - 0.06, gx[1], 0, ghh, z - 0.03, z + 0.03, "metal", 1.5)
	box(gx[0], gx[1], ghh - 0.06, ghh, gz[0], gz[1], "glass", 2, false)
	box(gx[0], gx[0] + 0.03, 0, ghh, gz[0], gz[1], "glass", 2)
	box(gx[1] - 0.03, gx[1], 0, ghh, gz[0], gz[1], "glass", 2)
	box(gx[0], gx[1], 0, ghh, gz[1] - 0.03, gz[1], "glass", 2)
	box(gx[0], gx[1] - 1.0, 0, ghh, gz[0], gz[0] + 0.03, "glass", 2)
	skin_end(skin_greenhouse)

	# Крышка погреба на второй тропе.
	box(-7.7, -6.3, 0.0, 0.14, 15.0, 16.4, "boards", 0.8)

	# Оболочка дома — последним шагом и ВСЯ без коллизий.
	var skin_shell := skin_begin("buildings", "site", "", "HOUSE-shell")
	shell_patch()
	skin_end(skin_shell)

	# Улица за воротами (фаза 9) — поверх готового участка. Видимое идёт в те же
	# сетки материалов, твёрдое — в четвёртый набор коллизий (SET_OVERLAY).
	# Ни одна коробка отсюда не попадает в 311/4/83, и это проверяет
	# tests/test_street_overlay.gd, собирая мир с файлом улицы и без него.
	street = StreetWorld.build(self)

	# Участок с фотографии (фаза 11) — тем же способом и по тому же правилу:
	# видимое collide = false, твёрдое в SET_OVERLAY. Ставится ПОСЛЕ улицы,
	# потому что читает site["WALLS"] уже собранного дома (наличники) и не
	# должен зависеть от того, есть ли data/street.json.
	yard = YardWorld.build(self)

	# Деревня (фаза 12): остановка, колодец, будка, погост, сельпо
	# и заколоченный дом изнутри. Правило то же, что у улицы и участка.
	village = VillageWorld.build(self)

	# Околица (фаза 14): переулки со второй линией уводят с центральной улицы
	# на семь участков за деревней. Строится ПОСЛЕ village — читает те же
	# BORDERS.gaps, что street уже разобрал, и ни от чего village не зависит.
	# Правило то же: видимое collide=false, твёрдое в SET_OVERLAY.
	outskirts = OutskirtsWorld.build(self)

	# СНТ за околицей (фаза 16): три проезда, два поворота, тупик, шестнадцать
	# участков, озеро и лес. Строится ПОСЛЕ околицы — упирается в её северный
	# борт и въезжает через проём в нём — и ДО зелени по той же причине, что
	# и линия Вали: Scatter щупает уже собранный мир.
	snt = SntWorld.build(self)

	# Линия бабки Вали (фаза 15): камни у ограды, полосы травы на второй линии,
	# тропа, холм в деревьях, лодка и сеть на озере. Строится ПОСЛЕ околицы —
	# читает те же координаты второй линии — и ДО зелени: Scatter обязан
	# увидеть тропу уже стоящей, иначе куст вырастет посреди неё.
	valya = ValyaWorld.build(self)

	# Зелень по всей карте (фаза 14). ПОСЛЕДНЯЯ из построек: раскладка щупает
	# уже собранный мир пробой точкой и садится только туда, где пусто, —
	# значит, всё твёрдое к этому моменту обязано стоять. Коллизии не
	# добавляет ни одной коробки: трава не твёрдая, и паритет её не видит.
	scatter = Scatter.build(self)

	# Мелочь внутри дома и сарая (фаза 12): тёрка, миска, переехавший телефон,
	# вещи на верстаке. Здесь твёрдого нет вовсе — нав-граф дома испечён
	# и заморожен, и коробка в четвёртом наборе означала бы деда, идущего
	# сквозь тумбу. См. шапку home_world.gd.
	home = HomeWorld.build(self)


# ---------- утилиты геометрии ----------

# Сохраняем происхождение вершин отдельно от геометрии и разбиения по клеткам.
func skin_begin(category: String, zone: String, id: String, fallback := "") -> Dictionary:
	var chosen := id if not id.is_empty() else fallback
	var key := "%s/%s/%s" % [category, zone, chosen]
	var starts: Dictionary = {}
	for material: String in buckets:
		starts[material] = (buckets[material]["v"] as Array).size()
	_skin_parts_info[key] = {"id": chosen, "needs_id": id.is_empty()}
	return {"key": key, "starts": starts}


# Ствол и листва уже слиты в бакеты: сохраняем исходный экземпляр в мете,
# чтобы скин мог заменить его, не затронув соседние деревья в том же чанке.
func skin_tree_begin(source: Dictionary, xf: Transform3D) -> Dictionary:
	var kind := String(source.get("kind", "conifer"))
	var id := "%s:%d" % [String(source.get("source", "trees")), int(source.get("tree_index", 0))]
	var mark := skin_begin("scatter", "tree_instances", id)
	_skin_tree_info[mark["key"]] = {
		"id": id, "key": "scatter/" + kind, "transform": xf,
		"variant": int(source.get("variant", 0)) % (3 if kind == "orchard" else 7),
		"orchard": kind == "orchard",
	}
	return mark


func skin_end(mark: Dictionary) -> void:
	var starts: Dictionary = mark["starts"]
	for material: String in buckets:
		var first := int(starts.get(material, 0))
		var finish := (buckets[material]["v"] as Array).size()
		if finish <= first:
			continue
		if not _skin_ranges.has(material):
			_skin_ranges[material] = []
		(_skin_ranges[material] as Array).append({
			"first": first, "end": finish, "key": mark["key"],
		})


# Квесты продолжают двигать прежнего владельца и обращаться к его детям.
static func skin_tag(owner: Node3D, category: String, zone: String, id := "") -> void:
	var chosen := id if not id.is_empty() else String(owner.name)
	owner.set_meta("skin_key", "%s/%s/%s" % [category, zone, chosen])
	owner.set_meta("skin_id", chosen)
	owner.set_meta("skin_needs_id", id.is_empty())
	owner.set_meta("skin_owner", NodePath("."))


# Эти состояния меняют отдельные дети; монолитный GLB не повторит
# поворот петли или появление улики, даже если имя владельца сохранено.
static func _skin_dynamic_children(owner: Node3D) -> void:
	var paths: Array[NodePath] = []
	var label := String(owner.name)
	if label == "home-kitchen-bowl":
		paths = [NodePath("heap")]
	elif label.begins_with("home-window-"):
		paths = [NodePath("leaf")]
	elif label == "gate":
		paths = [NodePath("LeftHinge"), NodePath("RightHinge")]
	elif label == "wicket":
		paths = [NodePath("WicketHinge")]
	elif label == "yard-spray-barrel":
		paths = [NodePath("mix")]
	elif label.begins_with("banya-win-"):
		paths = [NodePath("print"), NodePath("story-writing")]
	var present: Array[NodePath] = []
	for path: NodePath in paths:
		if owner.get_node_or_null(path) != null:
			present.append(path)
	if not present.is_empty():
		owner.set_meta("skin_dynamic_children", present)
		owner.set_meta("skin_unavailable_reason",
			"динамические дочерние части требуют отдельного скина: " + str(present))


static func _skin_tag_children(node: Node, owner: Node3D) -> void:
	for child: Node in node.get_children():
		if child.has_meta("skin_key"):
			continue
		if child is MeshInstance3D:
			child.set_meta("skin_key", owner.get_meta("skin_key"))
			child.set_meta("skin_id", owner.get_meta("skin_id"))
			child.set_meta("skin_needs_id", owner.get_meta("skin_needs_id"))
			child.set_meta("skin_owner", child.get_path_to(owner))
		_skin_tag_children(child, owner)


static func seg_count(size: float, seg: float) -> int:
	var s := seg if seg > 0.0 else 1.6
	return maxi(1, mini(12, int(floor(absf(size) / s + 0.5))))


# Копилка на материал. Обычный Array, а не Packed: Packed копируется при каждой
# записи через словарь, и на паре тысяч вызовов это десятки миллионов лишних
# копирований вершин. В Packed переводим один раз, при сборке сетки.
func _bucket(key: String) -> Dictionary:
	if not buckets.has(key):
		buckets[key] = {"v": [], "n": [], "uv": []}
	return buckets[key]


func _scale_for(key: String) -> float:
	if _extra_scale.has(key):
		return _extra_scale[key]
	var material_key := key.trim_prefix("visual:") if key.begins_with("visual:") else key
	return mats.scale(material_key)


# Мировая развёртка: доминантная нормаль решает, какая пара осей идёт в UV.
static func world_uv(p: Vector3, n: Vector3, sc: float) -> Vector2:
	var nx := absf(n.x)
	var ny := absf(n.y)
	var nz := absf(n.z)
	if ny >= nx and ny >= nz:
		return Vector2(p.x / sc, p.z / sc)
	if nx >= nz:
		return Vector2(p.z / sc, p.y / sc)
	return Vector2(p.x / sc, p.y / sc)


# Сетка четырёхугольников: угол + два ребра. В Godot лицевая сторона намотана
# по часовой стрелке, поэтому порядок вершин переворачивается, если du x dv
# смотрит против нормали.
func _quad_grid(key: String, o: Vector3, du: Vector3, dv: Vector3, n: Vector3,
		su: int, sv: int, sc: float) -> void:
	var b := _bucket(key)
	var vs: Array = b["v"]
	var ns: Array = b["n"]
	var uvs: Array = b["uv"]
	var flip := du.cross(dv).dot(n) < 0.0
	for i in su:
		for j in sv:
			var u0 := float(i) / su
			var u1 := float(i + 1) / su
			var v0 := float(j) / sv
			var v1 := float(j + 1) / sv
			var p00 := o + du * u0 + dv * v0
			var p10 := o + du * u1 + dv * v0
			var p11 := o + du * u1 + dv * v1
			var p01 := o + du * u0 + dv * v1
			var tri: Array = [p00, p10, p11, p00, p11, p01] if flip \
				else [p00, p11, p10, p00, p01, p11]
			for p: Vector3 in tri:
				vs.append(p)
				ns.append(n)
				uvs.append(world_uv(p, n, sc))


# Видимая коробка с сегментацией, как BoxGeometry(w,h,d,sx,sy,sz).
func _emit_box(key: String, ax: float, ay: float, az: float, bx: float, by: float, bz: float,
		sx: int, sy: int, sz: int) -> void:
	var sc := _scale_for(key)
	var o := Vector3(ax, ay, az)
	var w := bx - ax
	var h := by - ay
	var d := bz - az
	_quad_grid(key, Vector3(bx, ay, az), Vector3(0, 0, d), Vector3(0, h, 0), Vector3(1, 0, 0), sz, sy, sc)
	_quad_grid(key, Vector3(ax, ay, bz), Vector3(0, 0, -d), Vector3(0, h, 0), Vector3(-1, 0, 0), sz, sy, sc)
	_quad_grid(key, Vector3(ax, by, az), Vector3(w, 0, 0), Vector3(0, 0, d), Vector3(0, 1, 0), sx, sz, sc)
	_quad_grid(key, Vector3(ax, ay, bz), Vector3(w, 0, 0), Vector3(0, 0, -d), Vector3(0, -1, 0), sx, sz, sc)
	_quad_grid(key, Vector3(bx, ay, bz), Vector3(-w, 0, 0), Vector3(0, h, 0), Vector3(0, 0, 1), sx, sy, sc)
	_quad_grid(key, o, Vector3(w, 0, 0), Vector3(0, h, 0), Vector3(0, 0, -1), sx, sy, sc)


# Повёрнутая коробка: центр, полуразмеры, ось и угол. Стропила, скаты, пандусы.
func _emit_rot_box(key: String, c: Vector3, half: Vector3, basis: Basis,
		sx: int, sy: int, sz: int) -> void:
	var sc := _scale_for(key)
	var ex := basis.x * half.x
	var ey := basis.y * half.y
	var ez := basis.z * half.z
	var nx := basis.x.normalized()
	var ny := basis.y.normalized()
	var nz := basis.z.normalized()
	_quad_grid(key, c + ex - ey - ez, ez * 2.0, ey * 2.0, nx, sz, sy, sc)
	_quad_grid(key, c - ex - ey + ez, ez * -2.0, ey * 2.0, -nx, sz, sy, sc)
	_quad_grid(key, c - ex + ey - ez, ex * 2.0, ez * 2.0, ny, sx, sz, sc)
	_quad_grid(key, c - ex - ey + ez, ex * 2.0, ez * -2.0, -ny, sx, sz, sc)
	_quad_grid(key, c + ex - ey + ez, ex * -2.0, ey * 2.0, nz, sx, sy, sc)
	_quad_grid(key, c - ex - ey - ez, ex * 2.0, ey * 2.0, -nz, sx, sy, sc)


# ---------- примитивы строителя ----------

# Плоскость в мировых координатах — стекло, сетка, силуэт.
func plane(w: float, h: float, key: String, pos: Vector3, rot_y := 0.0, rot_x := 0.0,
		seg_w := 2, seg_h := 2) -> void:
	var basis := Basis()
	if rot_x != 0.0:
		basis = Basis(Vector3(1, 0, 0), rot_x)
	if rot_y != 0.0:
		basis = Basis(Vector3(0, 1, 0), rot_y) * basis
	var du := basis.x * w
	var dv := basis.y * h
	var n := basis.z
	_quad_grid(key, pos - du * 0.5 - dv * 0.5, du, dv, n, seg_w, seg_h, _scale_for(key))


# Произвольная процедурная сетка в существующий material bucket. Индексы
# разворачиваются здесь, чтобы озёра и лодки проходили тем же чанкингом и
# culling, что стены, вместо отдельных draw calls.
func append_mesh(key: String, mesh: ArrayMesh, xf := Transform3D.IDENTITY) -> void:
	var bucket := _bucket(key)
	var out_v: Array = bucket["v"]
	var out_n: Array = bucket["n"]
	var out_uv: Array = bucket["uv"]
	var normal_basis := xf.basis.inverse().transposed()
	for surface in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(surface)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
		var count := indices.size() if not indices.is_empty() else verts.size()
		for i in count:
			var vi := indices[i] if not indices.is_empty() else i
			out_v.append(xf * verts[vi])
			out_n.append((normal_basis * normals[vi]).normalized()
				if vi < normals.size() else Vector3.UP)
			out_uv.append(uvs[vi] if vi < uvs.size() else Vector2.ZERO)

func append_tree_mesh(key: String, high: ArrayMesh, low: ArrayMesh,
		xf: Transform3D, owner: String, background: ArrayMesh = null) -> void:
	append_mesh(key,high,xf)
	if not _forest_lows.has(key):
		_forest_lows[key] = {}
	_forest_lows[key][owner] = {"mesh": low, "background": background if background != null else low, "transform": xf}

func _forest_low_group(key: String, group: Dictionary, centre: Vector3, background := false) -> Dictionary:
	var data := {"v": [], "n": [], "uv": [], "anchors": {}, "near_parts": {}, "far_parts": {}}
	for owner: String in group["skin_parts"]:
		if not _forest_lows.get(key,{}).has(owner):
			continue
		var item: Dictionary = _forest_lows[key][owner]
		var id := String(_skin_tree_info[owner]["id"])
		var xf: Transform3D = item["transform"]
		var low: ArrayMesh = item["background"] if background else item["mesh"]
		var normal_basis := xf.basis.inverse().transposed()
		var start := (data["v"] as Array).size()
		for surface in low.get_surface_count():
			var arrays := low.surface_get_arrays(surface)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
			var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
			var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX] is PackedInt32Array else PackedInt32Array()
			var count := indices.size() if not indices.is_empty() else vertices.size()
			for index in count:
				var vi := indices[index] if not indices.is_empty() else index
				(data["v"] as Array).append(xf*vertices[vi]-centre)
				(data["n"] as Array).append((normal_basis*normals[vi]).normalized())
				(data["uv"] as Array).append(uv[vi])
		data["anchors"][id] = xf.origin-centre
		data["near_parts"][id] = group["skin_parts"][owner]
		data["far_parts"][id] = [Vector2i(start,(data["v"] as Array).size()-start)]
	return data

static func _forest_mesh(data: Dictionary) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array(data["v"])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(data["n"])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(data["uv"])
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,arrays)
	return mesh


# Прямоугольный объём. Границы задаются парами, порядок неважен.
func box(x0: float, x1: float, y0: float, y1: float, z0: float, z1: float, key: String,
		seg := 0.0, collide := true, collide_only := false) -> void:
	var ax := minf(x0, x1)
	var bx := maxf(x0, x1)
	var ay := minf(y0, y1)
	var by := maxf(y0, y1)
	var az := minf(z0, z1)
	var bz := maxf(z0, z1)
	var w := bx - ax
	var h := by - ay
	var d := bz - az
	if w <= 0.0005 or h <= 0.0005 or d <= 0.0005:
		return
	var sx := seg_count(w, seg)
	var sy := seg_count(h, seg)
	var sz := seg_count(d, seg)
	if not collide_only:
		_emit_box(key, ax, ay, az, bx, by, bz, sx, sy, sz)
	if collide:
		col.add_box_d(CollisionWorld.SET_STATIC, ax, ay, az, bx, by, bz)
		collide_verts += 2 * ((sx + 1) * (sy + 1) + (sy + 1) * (sz + 1) + (sx + 1) * (sz + 1))


func slab(rect: Array, y: float, t: float, key: String, seg: float,
		collide_only := false) -> void:
	box(rect[0], rect[1], y - t, y, rect[2], rect[3], key, seg, true, collide_only)


# ---------- стены с проёмами ----------

func wall(def: Dictionary) -> void:
	var a: Array = def["a"]
	var b: Array = def["b"]
	var ax := float(a[0])
	var az := float(a[1])
	var bx := float(b[0])
	var bz := float(b[1])
	var horiz := absf(bx - ax) > absf(bz - az)
	var t := float(def.get("t", 0.0))
	if t == 0.0:
		t = 0.12
	var y0 := float(def["y"])
	var y1 := y0 + float(def["h"])
	var key: String = def["mat"]
	# Видимую часть этих стен кладёт _attic_patch() подрезанной по скату.
	var hidden := CLIP_WALLS.has(String(def.get("id", "")))

	var holes: Array = []
	for hh: Dictionary in def.get("holes", []):
		var c: float = float(hh["x"]) if horiz else float(hh["z"])
		var hy0 := float(hh.get("y0", 0.0))
		var hy1 := float(hh["y1"]) if hh.has("y1") and hh["y1"] != null else float(def["h"])
		holes.append({
			"c": c, "w": float(hh["w"]),
			"y0": y0 + hy0, "y1": y0 + hy1,
			"kind": "window" if hy0 > 0.01 else "door",
		})
	holes.sort_custom(func(p, q): return p["c"] < q["c"])

	var start: float = ax if horiz else az
	var end: float = bx if horiz else bz
	var cursor := minf(start, end)
	var stop := maxf(start, end)
	for hole: Dictionary in holes:
		var h0: float = hole["c"] - hole["w"] / 2.0
		var h1: float = hole["c"] + hole["w"] / 2.0
		_wall_put(horiz, ax, az, t, key, cursor, h0, y0, y1, hidden)
		_wall_put(horiz, ax, az, t, key, h0, h1, hole["y1"], y1, hidden)
		if hole["y0"] > y0 + 0.005:
			_wall_put(horiz, ax, az, t, key, h0, h1, y0, hole["y0"], hidden)
		cursor = h1
		_frame_hole(def, horiz, hole, t)
	_wall_put(horiz, ax, az, t, key, cursor, stop, y0, y1, hidden)


func _wall_put(horiz: bool, ax: float, az: float, t: float, key: String,
		c0: float, c1: float, yy0: float, yy1: float, collide_only := false) -> void:
	if c1 - c0 < 0.002 or yy1 - yy0 < 0.002:
		return
	if horiz:
		box(c0, c1, yy0, yy1, az - t / 2.0, az + t / 2.0, key, 0.0, true, collide_only)
	else:
		box(ax - t / 2.0, ax + t / 2.0, yy0, yy1, c0, c1, key, 0.0, true, collide_only)


# Обналичка, стекло и переплёт окна. Всё это только видимое: в коллизию не идёт.
func _frame_hole(def: Dictionary, horiz: bool, hole: Dictionary, t: float) -> void:
	var a: Array = def["a"]
	var line: float = float(a[1]) if horiz else float(a[0])
	var c0: float = hole["c"] - hole["w"] / 2.0
	var c1: float = hole["c"] + hole["w"] / 2.0
	var fr := 0.05
	var hy0: float = hole["y0"]
	var hy1: float = hole["y1"]

	_frame(horiz, line, t, c0 - fr, c0, hy0, hy1 + fr)
	_frame(horiz, line, t, c1, c1 + fr, hy0, hy1 + fr)
	_frame(horiz, line, t, c0 - fr, c1 + fr, hy1, hy1 + fr)

	if hole["kind"] != "window":
		return
	# Стекло идёт в общую прозрачную кучу: шестнадцать окон — один draw call.
	#
	# ФАЗА 15. Кроме тех трёх проёмов, где стоит форточка: там сплошная
	# плоскость стекла и полотно створки компланарны, и вместе они читаются
	# не окном, а вторым куском рамы поперёк первого. Створка со своей
	# обвязкой стекло и заменяет — она и есть стекло этого проёма.
	if _no_glass.has("%.2f|%.2f" % [line, hole["c"]]):
		return
	var w := c1 - c0
	var hh := hy1 - hy0
	if horiz:
		plane(w, hh, "glass", Vector3((c0 + c1) / 2.0, (hy0 + hy1) / 2.0, line), 0.0, 0.0, 2, 2)
	else:
		plane(w, hh, "glass", Vector3(line, (hy0 + hy1) / 2.0, (c0 + c1) / 2.0), PI / 2.0, 0.0, 2, 2)
	var bar := 0.035
	var my := (hy0 + hy1) / 2.0
	if horiz:
		box(c0, c1, my - bar / 2.0, my + bar / 2.0, line - 0.02, line + 0.02, "dark", 1, false)
		box((c0 + c1) / 2.0 - bar / 2.0, (c0 + c1) / 2.0 + bar / 2.0, hy0, hy1,
			line - 0.02, line + 0.02, "dark", 1, false)
	else:
		box(line - 0.02, line + 0.02, my - bar / 2.0, my + bar / 2.0, c0, c1, "dark", 1, false)
		box(line - 0.02, line + 0.02, hy0, hy1,
			(c0 + c1) / 2.0 - bar / 2.0, (c0 + c1) / 2.0 + bar / 2.0, "dark", 1, false)


func _frame(horiz: bool, line: float, t: float, a0: float, a1: float, b0: float, b1: float) -> void:
	if horiz:
		box(a0, a1, b0, b1, line - t / 2.0 - 0.012, line + t / 2.0 + 0.012, "dark", 1, false)
	else:
		box(line - t / 2.0 - 0.012, line + t / 2.0 + 0.012, b0, b1, a0, a1, "dark", 1, false)


# ---------- дверное полотно ----------

# Дверь, которую можно запереть. Живёт отдельной нодой (её поворачивают главы),
# а её блокирующая коробка — в наборе SET_BLOCKERS.
func door_leaf(id: String, x: float, z: float, w: float, h: float, y: float,
		axis: String, key: String, locked: bool) -> Node3D:
	var t := 0.055
	var group := Node3D.new()
	group.name = id
	var sc := _scale_for(key)
	var mesh := MeshInstance3D.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lw := w if axis == "x" else t
	var ld := t if axis == "x" else w
	var ox := w / 2.0 if axis == "x" else 0.0
	var oz := 0.0 if axis == "x" else w / 2.0
	var sx := 3 if axis == "x" else 1
	var sz := 1 if axis == "x" else 3
	_surface_box(st, Vector3(ox - lw / 2.0, h / 2.0 - h / 2.0, oz - ld / 2.0),
		Vector3(lw, h, ld), sx, 5, sz, sc)
	mesh.mesh = st.commit()
	mesh.material_override = mats.get_mat(key)
	group.add_child(mesh)

	var knob := MeshInstance3D.new()
	var sphere := SphereMesh.new()
	sphere.radius = 0.032
	sphere.height = 0.064
	sphere.radial_segments = 6
	sphere.rings = 5
	knob.mesh = sphere
	knob.material_override = mats.get_mat("metal")
	knob.position = Vector3(w - 0.11 if axis == "x" else 0.05, h * 0.52,
		0.05 if axis == "x" else w - 0.11)
	group.add_child(knob)

	# Петля в начале полотна, чтобы дверь открывалась поворотом группы.
	group.position = Vector3(x - w / 2.0 if axis == "x" else x, y, z if axis == "x" else z - w / 2.0)
	skin_tag(group, "buildings", "site", id)
	group.set_meta("id", id)
	group.set_meta("open", false)
	group.set_meta("locked", locked)
	group.set_meta("axis", axis)
	group.set_meta("w", w)
	group.set_meta("h", h)
	group.set_meta("swing", 0.0)
	group.set_meta("target", 0.0)
	decor[id] = group

	var bw := w if axis == "x" else t + 0.02
	var bd := t + 0.02 if axis == "x" else w
	var bx0 := x - bw / 2.0
	var bz0 := z - bd / 2.0
	col.add_box_d(CollisionWorld.SET_BLOCKERS, bx0, y, bz0, bx0 + bw, y + h, bz0 + bd, id)
	blockers.append({
		"id": id,
		"box": AABB(Vector3(bx0, y, bz0), Vector3(bw, h, bd)),
		"active": true,
		"node": group,
	})
	return group


# Коробка прямо в SurfaceTool: для decor'а, который не сливается в общую сетку.
func _surface_box(st: SurfaceTool, o: Vector3, size: Vector3, sx: int, sy: int, sz: int,
		sc: float) -> void:
	var faces := [
		[Vector3(o.x + size.x, o.y, o.z), Vector3(0, 0, size.z), Vector3(0, size.y, 0), Vector3(1, 0, 0), sz, sy],
		[Vector3(o.x, o.y, o.z + size.z), Vector3(0, 0, -size.z), Vector3(0, size.y, 0), Vector3(-1, 0, 0), sz, sy],
		[Vector3(o.x, o.y + size.y, o.z), Vector3(size.x, 0, 0), Vector3(0, 0, size.z), Vector3(0, 1, 0), sx, sz],
		[Vector3(o.x, o.y, o.z + size.z), Vector3(size.x, 0, 0), Vector3(0, 0, -size.z), Vector3(0, -1, 0), sx, sz],
		[Vector3(o.x + size.x, o.y, o.z + size.z), Vector3(-size.x, 0, 0), Vector3(0, size.y, 0), Vector3(0, 0, 1), sx, sy],
		[o, Vector3(size.x, 0, 0), Vector3(0, size.y, 0), Vector3(0, 0, -1), sx, sy],
	]
	for f: Array in faces:
		var org: Vector3 = f[0]
		var du: Vector3 = f[1]
		var dv: Vector3 = f[2]
		var n: Vector3 = f[3]
		var su: int = f[4]
		var sv: int = f[5]
		var flip := du.cross(dv).dot(n) < 0.0
		for i in su:
			for j in sv:
				var p00 := org + du * (float(i) / su) + dv * (float(j) / sv)
				var p10 := org + du * (float(i + 1) / su) + dv * (float(j) / sv)
				var p11 := org + du * (float(i + 1) / su) + dv * (float(j + 1) / sv)
				var p01 := org + du * (float(i) / su) + dv * (float(j + 1) / sv)
				var tri: Array = [p00, p10, p11, p00, p11, p01] if flip \
					else [p00, p11, p10, p00, p01, p11]
				for p: Vector3 in tri:
					st.set_normal(n)
					st.set_uv(world_uv(p, n, sc))
					st.add_vertex(p)


# ---------- лестницы ----------

func stairs(def: Dictionary) -> void:
	var Y: Dictionary = site["Y"]
	if def.has("landing") and def["landing"] != null:
		var l: Array = def["landing"]
		var y: float = def["y"]
		box(l[0], l[1], y - 0.16, y, l[2], l[3], def["mat"], 0.8)
		# Юго-восточный угол площадки ни на чём не лежит — стойка до пола.
		# collide: false обязателен: лестница проходится по невидимому пандусу.
		box(l[1] - 0.095, l[1] - 0.005, Y["FLOOR1"], y - 0.16, l[3] - 0.095, l[3] - 0.005,
			def["mat"], 1.2, false)
		return

	var fr: Array = def["from"]
	var sx := float(fr[0])
	var sy := float(fr[1])
	var sz := float(fr[2])
	var dr: Array = def["dir"]
	var dx := float(dr[0])
	var dz := float(dr[1])
	var steps := int(def["steps"])
	var rise := float(def["rise"])
	var run := float(def["run"])
	var width := float(def["width"])
	var key: String = def["mat"]
	var half_w := width / 2.0

	for i in steps:
		var y := sy + (i + 1) * rise
		var cx := sx + dx * (i * run + run / 2.0)
		var cz := sz + dz * (i * run + run / 2.0)
		var ex := run / 2.0 if dx != 0.0 else half_w
		var ez := run / 2.0 if dz != 0.0 else half_w
		box(cx - ex, cx + ex, y - 0.05, y, cz - ez, cz + ez, key, 0.5, false)
		var bx := sx + dx * (i * run)
		var bz := sz + dz * (i * run)
		box(bx if dx != 0.0 else bx - half_w, bx + 0.045 if dx != 0.0 else bx + half_w,
			y - rise, y - 0.05,
			bz if dz != 0.0 else bz - half_w, bz + 0.045 if dz != 0.0 else bz + half_w,
			key, 0.5, false)

	# Невидимый пандус: капсула едет по нему и не спотыкается о рёбра ступеней.
	var run_len := steps * run
	var rise_len := steps * rise
	var angle := atan2(rise_len, run_len)
	var HALF_T := 0.21
	var extra := 0.5
	var diag := sqrt(run_len * run_len + rise_len * rise_len) + extra
	var hx := (diag if dx != 0.0 else width) / 2.0
	var hz := (diag if dz != 0.0 else width) / 2.0
	var back := (extra / 2.0) * cos(angle)
	var cx2 := sx + dx * (run_len / 2.0 - back)
	var cy2 := sy + rise_len / 2.0 - (extra / 2.0) * sin(angle) - HALF_T / cos(angle)
	var cz2 := sz + dz * (run_len / 2.0 - back)
	if dz != 0.0:
		col.add_rot_box_d(CollisionWorld.SET_STATIC, cx2, cy2, cz2, hx, HALF_T, hz,
			CollisionWorld.AXIS_X, -angle * dz)
	else:
		col.add_rot_box_d(CollisionWorld.SET_STATIC, cx2, cy2, cz2, hx, HALF_T, hz,
			CollisionWorld.AXIS_Z, angle * dx)
	collide_verts += 2 * (7 * 2 + 2 * 7 + 7 * 7)  # BoxGeometry(…, 6, 1, 6)

	# Тетива идёт ПО СТУПЕНЯМ, посегментно: сплошная доска читалась как глухая
	# перегородка поперёк прихожей и ныряла на полметра ниже пола.
	var STR_T := 0.06
	var STR_D := 0.32
	var LAP := 0.01
	if steps <= 3:
		return
	for s: float in [-1.0, 1.0]:
		var off := s * half_w
		if float(def.get("wallSide", 0.0)) == s:
			# У стены тетива не нужна: там наклонный плинтус от лицевой плоскости.
			var inward := 1.0 if off < 0.0 else -1.0
			var c0 := off + inward * 0.03
			var c1 := off + inward * 0.06
			for i in steps:
				var y := sy + (i + 1) * rise
				var y0 := maxf(sy, y - 0.18)
				var a0 := i * run
				var a1 := a0 + run + LAP
				if dz != 0.0:
					box(sx + c0, sx + c1, y0, y, sz + dz * a0, sz + dz * a1, key, 0.6, false)
				else:
					box(sx + dx * a0, sx + dx * a1, y0, y, sz + c0, sz + c1, key, 0.6, false)
			continue
		for i in steps:
			var y := sy + (i + 1) * rise
			var y0 := maxf(sy, y - STR_D)
			var a0 := i * run
			var a1 := a0 + run + LAP
			if dz != 0.0:
				var gx := sx + off
				box(gx - STR_T / 2.0, gx + STR_T / 2.0, y0, y, sz + dz * a0, sz + dz * a1, key, 0.6, false)
			else:
				var gz := sz + off
				box(sx + dx * a0, sx + dx * a1, y0, y, gz - STR_T / 2.0, gz + STR_T / 2.0, key, 0.6, false)
		# Ньюэлы вдвинуты на полсечения внутрь марша: осью на кромке они наполовину
		# торчали в прихожую, а на площадке ньюэлы двух маршей влезали друг в друга.
		_newel(def, off, 0.05, sx, sy, sz, dx, dz, run, rise, STR_D, key)
		_newel(def, off, run_len - 0.05, sx, sy, sz, dx, dz, run, rise, STR_D, key)


func _newel(def: Dictionary, off: float, a: float, sx: float, sy: float, sz: float,
		dx: float, dz: float, run: float, rise: float, str_d: float, key: String) -> void:
	var line := sy + (a / run) * rise
	var c := off + (0.05 if off < 0.0 else -0.05)
	var gx: float = sx + c if dz != 0.0 else sx + dx * a
	var gz: float = sz + dz * a if dz != 0.0 else sz + c
	box(gx - 0.05, gx + 0.05, maxf(sy, line - str_d), line + 0.95 + 0.08,
		gz - 0.05, gz + 0.05, key, 0.8, false)


func rail(def: Dictionary) -> void:
	var t := 0.045
	var a: Array = def["a"]
	var b: Array = def["b"]
	var ax := float(a[0])
	var az := float(a[1])
	var bx := float(b[0])
	var bz := float(b[1])
	var y0 := float(def["y0"])
	var y1 := float(def["y1"])
	var h := float(def["h"])
	var horiz := absf(bx - ax) > absf(bz - az)
	var ln: float = absf(bx - ax) if horiz else absf(bz - az)
	# Шаг балясин 0.28: при 0.75 перила читались как штакетник у грядки.
	var n := maxi(2, int(floor(ln / 0.28 + 0.5)))
	for i in n + 1:
		var q := float(i) / n
		var x := ax + (bx - ax) * q
		var z := az + (bz - az) * q
		var base := y0 + (y1 - y0) * q
		box(x - t / 2.0, x + t / 2.0, base, base + h, z - t / 2.0, z + t / 2.0, "boards", 1, false)

	# Поручень — один наклонный брус на весь марш: ступенчатая лесенка из коробок
	# давала пилу вдоль всей лестницы.
	var dxr := bx - ax
	var dzr := bz - az
	var dyr := y1 - y0
	var diag := sqrt((dxr if horiz else dzr) * (dxr if horiz else dzr) + dyr * dyr)
	var ns := seg_count(diag, 1.2)
	var basis: Basis
	if horiz:
		basis = Basis(Vector3(0, 0, 1), atan2(dyr, dxr))
	else:
		basis = Basis(Vector3(1, 0, 0), -atan2(dyr, dzr))
	var c := Vector3((ax + bx) / 2.0, (y0 + y1) / 2.0 + h + 0.025, (az + bz) / 2.0)
	var half := Vector3(diag / 2.0, 0.025, 0.035) if horiz else Vector3(0.035, 0.025, diag / 2.0)
	_emit_rot_box("boards", c, half, basis, ns if horiz else 1, 1, 1 if horiz else ns)

	# Коллизия поручня осталась прежней до миллиметра: те же ступенчатые коробки
	# с шагом 0.75, только невидимые. Капсула трётся о них боком на каждом марше.
	var nc := maxi(2, int(floor(ln / 0.75 + 0.5)))
	for i in nc:
		var q0 := float(i) / nc
		var q1 := float(i + 1) / nc
		var x0 := ax + (bx - ax) * q0
		var x1 := ax + (bx - ax) * q1
		var z0 := az + (bz - az) * q0
		var z1 := az + (bz - az) * q1
		var ry0 := y0 + (y1 - y0) * q0 + h
		var ry1 := y0 + (y1 - y0) * q1 + h
		var lo := minf(ry0, ry1)
		var hi := maxf(ry0, ry1) + 0.06
		if horiz:
			box(x0, x1, lo, hi, az - 0.04, az + 0.04, "boards", 1.2, true, true)
		else:
			box(ax - 0.04, ax + 0.04, lo, hi, z0, z1, "boards", 1.2, true, true)


# ---------- крыши ----------

func roof(def: Dictionary) -> void:
	var xr: Array = def["x"]
	var zr: Array = def["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var t := 0.12
	var key: String = def["mat"]
	if def.has("ridgeZ") and def["ridgeZ"] != null:
		var rz := float(def["ridgeZ"])
		var eave := float(def["eaveY"])
		var ridge := float(def["ridgeY"])
		_slope(x0, x1, z0, rz, eave, ridge, key, t)
		_slope(x0, x1, rz, z1, ridge, eave, key, t)
		_gable(x0, z0, rz, z1, eave, ridge, key)
		_gable(x1, z0, rz, z1, eave, ridge, key)
	elif def.get("along", "") == "z":
		_slope(x0, x1, z0, z1, float(def["slopeTo"][1]), float(def["slopeFrom"][1]), key, t)
	else:
		_slopeX(float(def["slopeFrom"][0]), float(def["slopeTo"][0]), z0, z1,
			float(def["slopeFrom"][1]), float(def["slopeTo"][1]), key, t)


func _slope(x0: float, x1: float, z0: float, z1: float, ya: float, yb: float,
		key: String, t: float, collide := true) -> void:
	var dz := z1 - z0
	var dy := yb - ya
	var ln := sqrt(dz * dz + dy * dy)
	var angle := atan2(dy, dz)
	var c := Vector3((x0 + x1) / 2.0, (ya + yb) / 2.0, (z0 + z1) / 2.0)
	var half := Vector3((x1 - x0) / 2.0, t / 2.0, ln / 2.0)
	var sx := seg_count(x1 - x0, 2)
	var sz := seg_count(ln, 2)
	_emit_rot_box(key, c, half, Basis(Vector3(1, 0, 0), -angle), sx, 1, sz)
	if not collide:
		return
	col.add_rot_box_d(CollisionWorld.SET_STATIC, c.x, c.y, c.z, half.x, half.y, half.z,
		CollisionWorld.AXIS_X, -angle)
	collide_verts += 2 * ((sx + 1) * 2 + 2 * (sz + 1) + (sx + 1) * (sz + 1))


func _slopeX(x0: float, x1: float, z0: float, z1: float, ya: float, yb: float,
		key: String, t: float) -> void:
	var dx := x1 - x0
	var dy := yb - ya
	var ln := sqrt(dx * dx + dy * dy)
	var angle := atan2(dy, dx)
	var c := Vector3((x0 + x1) / 2.0, (ya + yb) / 2.0, (z0 + z1) / 2.0)
	var half := Vector3(ln / 2.0, t / 2.0, (z1 - z0) / 2.0)
	var sx := seg_count(ln, 2)
	var sz := seg_count(z1 - z0, 2)
	_emit_rot_box(key, c, half, Basis(Vector3(0, 0, 1), angle), sx, 1, sz)
	col.add_rot_box_d(CollisionWorld.SET_STATIC, c.x, c.y, c.z, half.x, half.y, half.z,
		CollisionWorld.AXIS_Z, angle)
	collide_verts += 2 * ((sx + 1) * 2 + 2 * (sz + 1) + (sx + 1) * (sz + 1))


func _gable(x: float, z0: float, zr: float, z1: float, y_eave: float, y_ridge: float,
		key: String) -> void:
	var t := 0.1
	var steps := 6
	for i in steps:
		var q0 := float(i) / steps
		var q1 := float(i + 1) / steps
		var y0 := y_eave + (y_ridge - y_eave) * q0
		var y1 := y_eave + (y_ridge - y_eave) * q1
		var za := z0 + (zr - z0) * q1
		var zb := z1 - (z1 - zr) * q1
		box(x - t / 2.0, x + t / 2.0, y0, y1, za, zb, key, 1.5)


# ---------- забор ----------

func fence(def: Dictionary) -> void:
	var a: Array = def["a"]
	var b: Array = def["b"]
	var ax := float(a[0])
	var az := float(a[1])
	var bx := float(b[0])
	var bz := float(b[1])
	var ln := sqrt((bx - ax) * (bx - ax) + (bz - az) * (bz - az))
	if ln < 0.01:
		return
	var ux := (bx - ax) / ln
	var uz := (bz - az) / ln
	var posts := maxi(1, int(floor(ln / 2.4 + 0.5)))
	var h := float(def["h"])
	for i in posts + 1:
		var q := float(i) / posts
		var x := ax + (bx - ax) * q
		var z := az + (bz - az) * q
		box(x - 0.05, x + 0.05, 0, h + 0.12, z - 0.05, z + 0.05, "metal", 1)

	var rot := atan2(ux, uz) + PI / 2.0
	var kind: String = def.get("kind", "mesh")
	if kind == "gate" or kind == "wicket":
		# Створки двигаются вокруг крайних столбов. Раньше один MeshInstance
		# стоял pivot'ом в центре пролёта: при rotation.y полотно вращалось как
		# вертушка, оба края уходили со своих петель. Корневая нода теперь лишь
		# контейнер; blocker и его закрытая AABB ниже остаются прежними.
		var id: String = def["id"]
		var node := Node3D.new()
		node.name = id
		skin_tag(node, "buildings", "site", id)
		node.set_meta("id", id)
		node.set_meta("open", false)
		node.set_meta("home", 0.0)
		node.set_meta("hinged", true)
		node.set_meta("kind", kind)
		var leaf_yaw := atan2(-uz, ux)
		var leaf_len := ln * 0.5 if kind == "gate" else ln
		var hinge_rows: Array = []
		if kind == "gate":
			hinge_rows = [
				["LeftHinge", Vector3(ax, h * 0.5, az), leaf_len * 0.5],
				["RightHinge", Vector3(bx, h * 0.5, bz), -leaf_len * 0.5],
			]
		else:
			# Калитка висит на внешнем правом столбе участка и открывается внутрь.
			hinge_rows = [["WicketHinge", Vector3(bx, h * 0.5, bz), -leaf_len * 0.5]]
		for row: Array in hinge_rows:
			var hinge := Node3D.new()
			hinge.name = String(row[0])
			hinge.position = row[1]
			hinge.rotation.y = leaf_yaw
			hinge.set_meta("home", leaf_yaw)
			var leaf := MeshInstance3D.new()
			leaf.name = "Leaf"
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			_surface_plane(st, leaf_len, h,
				maxi(2, int(floor(leaf_len + 0.5))), 3, Materials.FENCE_SCALE)
			leaf.mesh = st.commit()
			leaf.material_override = mats.mesh_fence()
			leaf.position.x = float(row[2])
			hinge.add_child(leaf)
			node.add_child(hinge)
		decor[id] = node

		var bw := absf(bx - ax) + 0.08
		var bd := absf(bz - az) + 0.08
		var cx := (ax + bx) / 2.0
		var cz := (az + bz) / 2.0
		col.add_box_d(CollisionWorld.SET_BLOCKERS, cx - bw / 2.0, 0.0, cz - bd / 2.0,
			cx + bw / 2.0, h, cz + bd / 2.0, id)
		blockers.append({
			"id": id,
			"box": AABB(Vector3(cx - bw / 2.0, 0.0, cz - bd / 2.0), Vector3(bw, h, bd)),
			"active": true,
			"node": node,
		})
		return

	# Сетка-рабица: пролёты сливаются в одну сетку.
	plane(ln, h, "meshfence", Vector3((ax + bx) / 2.0, h / 2.0, (az + bz) / 2.0), rot, 0.0,
		maxi(2, int(floor(ln / 1.5 + 0.5))), 2)

	# Коллизия — тонкая коробка: сквозь забор ходить нельзя.
	var w := maxf(0.1, absf(bx - ax))
	var d := maxf(0.1, absf(bz - az))
	var mx := (ax + bx) / 2.0
	var mz := (az + bz) / 2.0
	col.add_box_d(CollisionWorld.SET_STATIC, mx - w / 2.0, 0.0, mz - d / 2.0,
		mx + w / 2.0, h, mz + d / 2.0)
	collide_verts += 24  # несегментированный бокс: 24 вершины


func _surface_plane(st: SurfaceTool, w: float, h: float, su: int, sv: int, sc: float) -> void:
	var o := Vector3(-w / 2.0, -h / 2.0, 0.0)
	var du := Vector3(w, 0, 0)
	var dv := Vector3(0, h, 0)
	var n := Vector3(0, 0, 1)
	for i in su:
		for j in sv:
			var p00 := o + du * (float(i) / su) + dv * (float(j) / sv)
			var p10 := o + du * (float(i + 1) / su) + dv * (float(j) / sv)
			var p11 := o + du * (float(i + 1) / su) + dv * (float(j + 1) / sv)
			var p01 := o + du * (float(i) / su) + dv * (float(j + 1) / sv)
			for p: Vector3 in [p00, p11, p10, p00, p01, p11]:
				st.set_normal(n)
				st.set_uv(Vector2(p.x / sc, p.y / sc))
				st.add_vertex(p)


# ---------- окружение ----------

func ground() -> void:
	var Y: Dictionary = site["Y"]
	# Под домом земли нет: иначе настил травы прошёл бы сквозь подпол.
	var hx0 := -5.72
	var hx1 := 4.52
	var hz0 := 6.48
	var hz1 := 16.32
	box(-9.5, 10.5, -0.35, 0, 0, hz0, "grass", 2.6)
	box(-9.5, 10.5, -0.35, 0, hz1, 30, "grass", 2.6)
	box(-9.5, hx0, -0.35, 0, hz0, hz1, "grass", 2.6)
	box(hx1, 10.5, -0.35, 0, hz0, hz1, "grass", 2.6)

	# Забирка по периметру: дом стоит на столбиках, без цоколя под ним видно подпол.
	box(hx0, hx1, -0.1, Y["FLOOR1"], hz0, hz0 + 0.12, "brick", 2)
	box(hx0, hx1, -0.1, Y["FLOOR1"], hz1 - 0.12, hz1, "brick", 2)
	box(hx0, hx0 + 0.12, -0.1, Y["FLOOR1"], hz0, hz1, "brick", 2)
	box(hx1 - 0.12, hx1, -0.1, Y["FLOOR1"], hz0, hz1, "brick", 2)

	box(-46, 46, -0.35, 0, -6.4, 0, "gravel", 3.2)
	# Обочина за дорогой: без неё шаг на север с грунтовки ронял игрока сквозь мир.
	box(-46, 46, -0.35, 0, -14, -6.4, "grass", 3.8)
	# Подложка грунта разрезана по контуру дома: цельная плита шла сквозь подпол.
	box(-60, 60, -0.5, -0.32, -60, hz0, "dirt", 8, false)
	box(-60, 60, -0.5, -0.32, hz1, 60, "dirt", 8, false)
	box(-60, hx0, -0.5, -0.32, hz0, hz1, "dirt", 8, false)
	box(hx1, 60, -0.5, -0.32, hz0, hz1, "dirt", 8, false)

	# Дорожка от калитки к крыльцу и вторая, вытоптанная, в обход к погребу.
	box(2.4, 3.6, 0.0, 0.03, 0.2, 3.0, "gravel", 1.2, false)
	box(-3.4, 3.6, 0.0, 0.03, 3.0, 4.2, "gravel", 1.6, false)
	box(-3.4, -1.2, 0.0, 0.03, 4.2, 5.0, "gravel", 1.2, false)
	box(-8.4, -6.0, 0.0, 0.025, 4.0, 16.4, "dirt", 2.2, false)
	box(-6.0, -1.2, 0.0, 0.025, 3.6, 4.6, "dirt", 2.2, false)

	# Four crosswise garden sections.  The two long prototype parity colliders
	# are defined elsewhere and remain untouched; these beds are visual only.
	for i in 4:
		var z := 17.4 + i * 2.1
		box(-4.2, 3.0, 0.0, 0.16, z, z + 1.1, "dirt", 1.6, false)


func poles() -> void:
	for p: Array in site["POLES"]:
		var x := float(p[0])
		var z := float(p[1])
		box(x - 0.09, x + 0.09, 0, 6.4, z - 0.09, z + 0.09, "metal", 2)
		box(x - 0.6, x + 0.6, 6.0, 6.1, z - 0.05, z + 0.05, "metal", 1, false)
		# провода — две тонкие линии до следующего столба
		box(x, x + 22, 5.95, 6.0, z - 0.02, z + 0.02, "dark", 6, false)
		box(x, x + 22, 5.78, 5.83, z + 0.16, z + 0.2, "dark", 6, false)


# Девять соседских домов прототипа.
#
# ФАЗА 13, вторая половина жалобы «края карты закрыты чёрными квадратами».
# Первая половина — опушка улицы (street_world._treeline), эта — вот здесь:
# каждый сосед был ПЛОСКИМ параллелепипедом материала 'silhouette' (0x1d232b,
# почти чёрный и без текстуры) плюс два ската тем же тоном. Ни фронтона, ни
# двери, ни окна. От восточного забора участка ближайший такой куб стоит
# в 2.25 метра — и в кадре это ровно чёрный квадрат, закрывающий полнеба.
#
# Лечится без единой новой коллизии. Меняются ключи материалов (кубы и скаты
# остаются теми же коробками до последнего знака — их сверяет
# test_world_parity), и сверху ложится обвес, который весь идёт collide=false:
# фронтоны, тёмный проём двери и одно-два тускло-жёлтых окна. Дальше по улице
# кто-то живёт — вот и всё, что это должно сказать.
#
# ФАСАД у дома тот, которым он повёрнут к игроку, а не «всегда южный»:
# соседи по бокам участка (z > 0) смотрят на x = 0, соседи через дорогу
# (z < 0) — на север, к самой дороге. Окно, нарисованное на глухом торце,
# хуже, чем его отсутствие.
# Номера соседских домов, которым вторая линия строит лицо сама (фаза 16).
# Пусто, если нет data/outskirts.json — тогда мир ровно тот, что был.
var _second_line_faces: Dictionary = {}


func _second_line_index() -> void:
	var d := OutskirtsWorld.data()
	var sl: Dictionary = d.get("SECOND_LINE", {})
	for key: String in (sl.get("houses", {}) as Dictionary).keys():
		if key.is_valid_int():
			_second_line_faces[key.to_int()] = true


func neighbours() -> void:
	_second_line_index()
	var win := SurfaceTool.new()
	win.begin(Mesh.PRIMITIVE_TRIANGLES)
	var lit := 0
	var skin_window_parts: Dictionary = {}
	var fence_runs: Dictionary = {}
	var idx := 0
	for n: Dictionary in site["NEIGHBOURS"]:
		var houses: Array = n["houses"]
		for hs: Array in houses:
			var x := float(hs[0])
			var z := float(hs[1])
			var w := float(hs[2])
			var d := float(hs[3])
			var h := float(hs[4])
			# ФАЗА 16. Пять домов второй линии перестают быть силуэтом: тело,
			# лицо, крыльцо и забор им строит OutskirtsWorld._second_line(),
			# и там же они становятся твёрдыми. Здесь для них остаются ТОЛЬКО
			# СКАТЫ — они уходят в паритетные 311 и потому неприкосновенны,
			# а всё остальное рисуется заново и по-другому.
			var rebuilt: bool = _second_line_faces.has(idx)
			var skin_zone := "outskirts" if rebuilt else "site"
			var skin_fallback := ("SECOND_LINE-" if rebuilt else "NEIGHBOURS-") + str(idx)
			var skin_id := ""
			if rebuilt:
				var second_line: Dictionary = OutskirtsWorld.data().get("SECOND_LINE", {})
				var cfg: Dictionary = (second_line.get("houses", {}) as Dictionary).get(str(idx), {})
				skin_id = String(cfg.get("id", ""))
			var skin_neighbour := skin_begin("buildings", skin_zone, skin_id, skin_fallback)
			if not rebuilt:
				box(x - w / 2.0, x + w / 2.0, 0, h, z - d / 2.0, z + d / 2.0, RURAL_DRESSING.wall_material(RURAL_DRESSING.family(idx)), 3, false)
			# двускатный силуэт крыши: два ската
			_slope(x - w / 2.0 - 0.3, x + w / 2.0 + 0.3, z - d / 2.0 - 0.3, z, h, h + 1.3, "neighbourroof", 0.14)
			_slope(x - w / 2.0 - 0.3, x + w / 2.0 + 0.3, z, z + d / 2.0 + 0.3, h + 1.3, h, "neighbourroof", 0.14)
			if not rebuilt:
				_neighbour_gable(x - w / 2.0, z, d, h, RURAL_DRESSING.wall_material(RURAL_DRESSING.family(idx)))
				_neighbour_gable(x + w / 2.0, z, d, h, RURAL_DRESSING.wall_material(RURAL_DRESSING.family(idx)))
				var lit_before := lit
				lit += _neighbour_face(win, x, z, w, d, h, idx)
				if lit > lit_before:
					# _neighbour_pane кладёт четыре треугольника на окно.
					skin_window_parts[skin_neighbour["key"]] = [Vector2i(lit_before * 12, (lit - lit_before) * 12)]
			skin_end(skin_neighbour)
			idx += 1
		# Просветы между досками позволяют читать двор с дороги.
		var plot: Array = n["plot"]
		var north: bool = float(houses[0][1]) > 0.0
		var fence_key := "%s:%s:%s" % [plot[0], plot[1], north]
		if not fence_runs.has(fence_key):
			_neighbour_fence(float(plot[0]), float(plot[1]), 0.23 if north else -6.57, idx)
			fence_runs[fence_key] = true
	if lit > 0:
		# Все горящие окна деревни — ОДНОЙ сеткой и одним материалом: девять
		# отдельных нод дали бы девять вызовов отрисовки на украшение, которое
		# игрок видит с тридцати метров сквозь туман.
		var mi := MeshInstance3D.new()
		mi.name = "neighbour-windows"
		mi.mesh = win.commit()
		mi.material_override = mats.glow(0x9a7c4a)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var skin_ids: Dictionary = {}
		var skin_needs: Dictionary = {}
		for skin_key: String in skin_window_parts:
			skin_ids[skin_key] = _skin_parts_info[skin_key]["id"]
			skin_needs[skin_key] = _skin_parts_info[skin_key]["needs_id"]
		mi.set_meta("skin_parts", skin_window_parts)
		mi.set_meta("skin_part_ids", skin_ids)
		mi.set_meta("skin_part_needs_id", skin_needs)
		mi.set_meta("skin_owner", NodePath(".."))
		decor["neighbour-windows"] = mi


func _neighbour_fence(x0: float, x1: float, z: float, index: int) -> void:
	var metal := index % 3 == 0
	var key := "metal" if metal else ("boards" if index % 2 == 0 else "shedwood")
	var height := 1.20 if metal else 1.35
	var sections := maxi(1, ceili((x1 - x0) / 2.2))
	for section in range(sections + 1):
		var x := lerpf(x0, x1, float(section) / float(sections))
		box(x - 0.045, x + 0.045, 0, height + 0.08, z - 0.045, z + 0.045, key, 0.0, false)
	for y: float in [0.35, 0.98]:
		box(x0, x1, y, y + 0.055, z - 0.04, z + 0.04, key, 0.0, false)
	var pitch := 0.16 if metal else 0.20
	var width := 0.018 if metal else 0.11
	for board in ceili((x1 - x0) / pitch):
		var x := x0 + 0.09 + float(board) * pitch
		if x + width > x1:
			continue
		var top := height - (0.025 if board % 7 == 0 else 0.0)
		box(x, x + width, 0.12, top, z - 0.018, z + 0.018, key, 0.0, false)


# Фронтон соседского дома: ступенчатая заливка треугольника под коньком.
# Тот же приём, что у _gable(), но ВСЁ collide = false — фронтоны в паритетной
# статике не значатся, и появиться там не имеют права.
func _neighbour_gable(x: float, z: float, d: float, h: float, material := "neighbour") -> void:
	var steps := 5
	var t := 0.12
	for i in steps:
		var q0 := float(i) / steps
		var q1 := float(i + 1) / steps
		var za := (z - d / 2.0) + (d / 2.0) * q1
		var zb := (z + d / 2.0) - (d / 2.0) * q1
		box(x - t / 2.0, x + t / 2.0, h + 1.3 * q0, h + 1.3 * q1, za, zb,
			material, 1.5, false)


# Фасад: проём двери и одно-два окна на той стене, которой дом повёрнут
# к игроку. Возвращает число горящих окон, добавленных в общую сетку.
func _neighbour_face(win: SurfaceTool, x: float, z: float, w: float, d: float,
		h: float, idx: int) -> int:
	# Куда смотрит: соседи через дорогу — на север, боковые — на x = 0.
	var to_north := z < 0.0
	var sgn := 1.0 if to_north else (-1.0 if x > 0.0 else 1.0)
	# Плоскость фасада, направление наружу и ширина по «горизонтали» стены.
	var face := (z + d / 2.0) if to_north else (x + sgn * w / 2.0)
	var dir := 1.0 if to_north else sgn
	var span := w if to_north else d
	var ctr := x if to_north else z
	var out := 0.05                          # насколько накладка выступает из стены

	# Проём двери: тёмная ниша, сдвинутая от центра — по центру двери не ставят.
	# Ключ 'silhouette' (0x1d232b), а не 'dark' (0x33383c): второй СВЕТЛЕЕ стены
	# соседа, и на снимке приёмки проём читался светлой панелью, а не дырой.
	# Заодно он идёт в уже существующую сетку — новых вызовов отрисовки ноль.
	var dw := 0.95
	var dc := ctr + span * 0.18
	_neighbour_patch(to_north, dir, face, out, dc - dw / 2.0, dc + dw / 2.0, 0.0, 2.05,
		"silhouette")
	# Козырёк над ней: одна доска, но именно она превращает стену в дом.
	_neighbour_patch(to_north, dir, face, out + 0.16, dc - dw / 2.0 - 0.25,
		dc + dw / 2.0 + 0.25, 2.05, 2.20, "neighbourroof")

	# Окна. Второе — только если фасад достаточно широк, чтобы оно не легло
	# на дверь: «по одному-двум» здесь считается геометрией, а не на глаз.
	var n := 2 if span > 5.4 else 1
	var y0 := h * 0.42
	var y1 := y0 + 1.0
	# Горит примерно в каждом втором доме и всегда ровно одно окно: деревня
	# спит, а не празднует. Выбор по индексу, а не по randf — сборка мира
	# обязана быть повторяемой, иначе два запуска дают разные картинки.
	var glow_at := 0 if (idx % 2) == 0 else -1
	var lit := 0
	for i in n:
		var cx := ctr - span * (0.30 if i == 0 else 0.06)
		_neighbour_patch(to_north, dir, face, out, cx - 0.55, cx + 0.55, y0, y1, "dark")
		if i != glow_at:
			continue
		_neighbour_pane(win, to_north, face + (out + 0.02) * dir,
			cx - 0.44, cx + 0.44, y0 + 0.09, y1 - 0.09)
		lit += 1
	return lit


# Накладка на фасад соседа. Тонкая коробка поверх стены, всегда collide = false.
# dir — направление наружу по оси фасада: без него накладка у дома, стоящего
# восточнее нуля, уезжала бы ВНУТРЬ объёма и не была бы видна вовсе.
func _neighbour_patch(to_north: bool, dir: float, face: float, out: float,
		a0: float, a1: float, y0: float, y1: float, key: String) -> void:
	var lo := face - 0.02 * dir
	var hi := face + out * dir
	if to_north:
		box(a0, a1, y0, y1, minf(lo, hi), maxf(lo, hi), key, 1.2, false)
	else:
		box(minf(lo, hi), maxf(lo, hi), y0, y1, a0, a1, key, 1.2, false)


# Стекло горящего окна: один квад в общую самосветящуюся сетку.
func _neighbour_pane(st: SurfaceTool, to_north: bool, plane_at: float,
		a0: float, a1: float, y0: float, y1: float) -> void:
	var p: Array = []
	if to_north:
		p = [Vector3(a0, y0, plane_at), Vector3(a1, y0, plane_at),
			Vector3(a1, y1, plane_at), Vector3(a0, y1, plane_at)]
	else:
		p = [Vector3(plane_at, y0, a0), Vector3(plane_at, y0, a1),
			Vector3(plane_at, y1, a1), Vector3(plane_at, y1, a0)]
	# Квад кладётся ОБЕИМИ намотками, и это не перестраховка. Материал
	# mats.glow() — общий StandardMaterial3D с отсечением задних граней
	# по умолчанию, а он же светит окнами улицы; выключать у него cull
	# значило бы трогать чужие окна ради своих. Четыре треугольника вместо
	# двух на девять окон — это тридцать шесть треугольников на всю деревню,
	# и они дешевле, чем окно, которое не видно ровно с той стороны,
	# с которой на него смотрят.
	var nrm := Vector3(0, 0, 1) if to_north else Vector3(1, 0, 0)
	for tri: Array in [[0, 2, 1], [0, 3, 2], [0, 1, 2], [0, 2, 3]]:
		for k: int in tri:
			st.set_normal(nrm)
			st.set_uv(Vector2(0, 0))
			st.add_vertex(p[k])


# ---------- оболочка дома (фаза 7) ----------
#
# Дом собирался из данных прототипа по слоям, и между слоями остались щели.
# Пётр увидел их с первого прохода: «половина дома, часть не закрыта, на улицу
# видно». Щели настоящие, а не проблема отсечения:
#
#   3.00…3.30  — стены первого этажа кончаются на 3.0, перекрытие мансарды
#                начинается на 3.1. Сквозная десятисантиметровая прорезь
#                ПО ВСЕМУ ПЕРИМЕТРУ, и в неё с улицы видно комнаты;
#   5.65…5.90  — то же этажом выше, между стенами мансарды и полом чердака;
#   3.00…4.27  — восточная пристройка открыта полосой по всей длине,
#                торцов у её ската нет вовсе;
#   0.32/0.12  — потолок мансарды не доходит до стен по периметру;
#   выше ската — стены и потолок чердака торчали сквозь кровлю наружу;
#   балкон     — дверь с площадки выводила на площадку без козырька.
#
# ВСЯ геометрия здесь идёт collide = false. Это не осторожность, а условие:
# невидимая для коллизий коробка не попадает в SET_STATIC и не увеличивает
# collide_verts, поэтому parity/world_boxes.json (311/4/83), parity/probes.json,
# навграф и счётчик треугольников 3885 остаются нетронутыми до последнего знака.

const SHELL_EPS := 0.004      # на сколько заслонка заходит под плиту кровли
const SHELL_STEP := 0.2       # длина дольки при подрезке по скату


## Заплатка оболочки. Зовётся последней в _build_all().
func shell_patch() -> void:
	_ceiling_gaps()
	_mansard_ceiling()
	_annex_patch()
	_attic_patch()
	var eaves_mark := skin_begin("buildings", "site", "HOUSE-eaves")
	_eaves_patch()
	skin_end(eaves_mark)
	var balcony_mark := skin_begin("buildings", "site", "HOUSE-balcony")
	_balcony_patch()
	skin_end(balcony_mark)


# ---------- кровля как функция координаты ----------

# Скаты берутся из ROOFS, а не переписываются сюда числами: подвинут кровлю —
# заплатка поедет вместе с ней, а не разъедется молча.

func _roof_def(kind: String) -> Dictionary:
	for r: Dictionary in site["ROOFS"]:
		if kind == "tent" and r.get("ridgeZ") != null:
			return r
		if kind == "annex" and r.get("ridgeZ") == null and r.get("along", "") != "z":
			return r
	return {}


## Середина плиты двускатной крыши дома по z.
func _tent_y(z: float) -> float:
	var r := _roof_def("tent")
	var zr: Array = r["z"]
	var rz := float(r["ridgeZ"])
	var eave := float(r["eaveY"])
	var ridge := float(r["ridgeY"])
	if z <= rz:
		return eave + (z - float(zr[0])) / (rz - float(zr[0])) * (ridge - eave)
	return ridge - (z - rz) / (float(zr[1]) - rz) * (ridge - eave)


## Вертикальная полутолщина плиты: 0.06 меряется поперёк ската, а нам нужно
## по вертикали, иначе заслонка сядет мимо.
func _tent_half(z: float) -> float:
	var r := _roof_def("tent")
	var zr: Array = r["z"]
	var rz := float(r["ridgeZ"])
	var run: float = (rz - float(zr[0])) if z <= rz else (float(zr[1]) - rz)
	var rise := float(r["ridgeY"]) - float(r["eaveY"])
	return 0.06 / cos(atan2(rise, maxf(0.001, run)))


func _annex_y(x: float) -> float:
	var r := _roof_def("annex")
	var f: Array = r["slopeFrom"]
	var t: Array = r["slopeTo"]
	return float(f[1]) + (x - float(f[0])) / (float(t[0]) - float(f[0])) \
		* (float(t[1]) - float(f[1]))


func _annex_half() -> float:
	var r := _roof_def("annex")
	var f: Array = r["slopeFrom"]
	var t: Array = r["slopeTo"]
	return 0.06 / cos(atan2(float(t[1]) - float(f[1]), float(t[0]) - float(f[0])))


## Потолок заслонки на куске [a0, a1]: выше НИЗА плиты (иначе останется щель)
## и ниже её ВЕРХА (иначе заслонка вылезет наружу сквозь кровлю). Куски делаются
## короткими именно ради того, чтобы этот зазор в 14 см существовал.
func _cap(a0: float, a1: float, top: float, tent: bool) -> float:
	var samples: Array = [a0, a1]
	if tent:
		var rz := float(_roof_def("tent")["ridgeZ"])
		if rz > a0 and rz < a1:
			samples.append(rz)
	var lo := -INF
	var hi := INF
	for a: float in samples:
		var c: float = _tent_y(a) if tent else _annex_y(a)
		var h: float = _tent_half(a) if tent else _annex_half()
		lo = maxf(lo, c - h)
		hi = minf(hi, c + h)
	if lo >= top:
		return top          # стена и так целиком под кровлей — резать нечего
	var cap := lo + SHELL_EPS
	if cap > hi:
		cap = maxf(lo, hi)  # кусок вышел длинноват: жмёмся к низу плиты
	return minf(top, cap)


# ---------- щели над стенами ----------

# Перекрытие каждого этажа начинается на 10 см выше, чем кончается стена под ним.
# Снаружи это сквозная прорезь по периметру, изнутри — светящаяся полоса над
# каждой перегородкой. Закрывается по данным WALLS: чем бы стена ни была, если
# её верх совпал с известным уровнем — над ней встаёт полоса до плиты.
const CEILING_LEVELS := [
	{"top": 3.0, "to": 3.1, "outer": 3.3},      # первый этаж -> перекрытие мансарды
	{"top": 5.65, "to": 5.74, "outer": 5.9},    # мансарда -> пол чердака
]
const OUTER_WALLS := ["w-n1", "w-s1", "w-w1", "w-e1", "w-n2", "w-s2", "w-w2", "w-e2"]


func _ceiling_gaps() -> void:
	for w: Dictionary in site["WALLS"]:
		var id := String(w.get("id", ""))
		# Наружные стены закрываются сплошным поясом ниже: у них полоса идёт
		# до самого верха перекрытия, и углы обязаны перекрываться внахлёст.
		if OUTER_WALLS.has(id):
			continue
		var top := float(w["y"]) + float(w["h"])
		for lv: Dictionary in CEILING_LEVELS:
			if not is_equal_approx(top, float(lv["top"])):
				continue
			var a: Array = w["a"]
			var b: Array = w["b"]
			var t := float(w.get("t", 0.12))
			var horiz := absf(float(b[0]) - float(a[0])) > absf(float(b[1]) - float(a[1]))
			var lo := float(lv["top"])
			var hi := float(lv["to"])
			if horiz:
				box(float(a[0]), float(b[0]), lo, hi,
					float(a[1]) - t / 2.0, float(a[1]) + t / 2.0, w["mat"], 0.0, false)
			else:
				box(float(a[0]) - t / 2.0, float(a[0]) + t / 2.0, lo, hi,
					float(a[1]), float(b[1]), w["mat"], 0.0, false)

	# Наружный пояс: по кругу и внахлёст в углах, иначе на стыках остаются
	# восьмисантиметровые дырки ровно там, где их виднее всего.
	var belts_mark := skin_begin("buildings", "site", "HOUSE-belts")
	_belt(-5.68, 4.48, 6.52, 16.28, 3.0, 3.3, "siding")     # первый этаж
	_belt(-5.68, 2.28, 9.52, 16.28, 5.65, 5.9, "siding")    # мансарда
	skin_end(belts_mark)


## Замкнутый пояс по периметру прямоугольника: четыре полосы толщиной 0.16.
func _belt(x0: float, x1: float, z0: float, z1: float, y0: float, y1: float,
		key: String) -> void:
	var t := 0.16
	box(x0, x1, y0, y1, z0, z0 + t, key, 0.0, false)
	box(x0, x1, y0, y1, z1 - t, z1, key, 0.0, false)
	box(x0, x0 + t, y0, y1, z0, z1, key, 0.0, false)
	box(x1 - t, x1, y0, y1, z0, z1, key, 0.0, false)


# ---------- потолок мансарды ----------

# Пол чердака (он же потолок мансарды) лежит на x −5.2…1.8, z 9.8…16, а стены
# мансарды стоят по x −5.6…2.2, z 9.6…16.2. Полосы в 32 и 12 см по периметру
# оставались открытыми: из комнаты деда видно вверх, в чердачный объём.
func _mansard_ceiling() -> void:
	var y1 := 5.9
	var y0 := y1 - 0.16
	box(-5.6, -5.2, y0, y1, 9.6, 16.2, "boards", 1.4, false)
	box(1.8, 2.2, y0, y1, 9.6, 16.2, "boards", 1.4, false)
	box(-5.2, 1.8, y0, y1, 9.6, 9.8, "boards", 1.4, false)
	box(-5.2, 1.8, y0, y1, 16.0, 16.2, "boards", 1.4, false)


# ---------- восточная пристройка ----------

# Пристройка накрыта односкатной кровлей с 6.8 на x = 2.2 до 3.8 на x = 4.9,
# а восточная стена дома кончается на 3.0. Между ними была открытая полоса
# по всей длине дома, торцов у ската не было вовсе, и с балкона под скат
# смотрели насквозь.
func _annex_patch() -> void:
	var xw := 2.2      # пристройка примыкает к дому здесь
	var xe := 4.4      # восточная стена дома
	var zn := 6.6
	var zs := 16.2
	var attic := float(site["Y"]["ATTIC"])

	# Восточная стена: от верха стены первого этажа до кровли. Толщина стены
	# режется на дольки — скат идёт поперёк неё и за 16 см успевает упасть на 18.
	_wall_to_annex_roof(xe - 0.08, xe + 0.08, 3.0, zn - 0.08, zs + 0.08)

	# Торцы ската: север и юг. Здесь скат идёт ВДОЛЬ стены, поэтому дольки
	# нарезаются по всей длине от дома до карниза.
	_wall_to_annex_roof(xw, xe + 0.08, attic, zn - 0.08, zn + 0.08)
	_wall_to_annex_roof(xw, xe + 0.08, attic, zs - 0.08, zs + 0.08)

	# Западная стенка чердачного объёма пристройки на участке балкона: выше
	# 9.6 её роль играет w-e2, а на z 6.6…9.6 не было ничего — с балкона
	# смотрели прямо под скат пристройки и дальше на улицу.
	box(xw - 0.08, xw + 0.08, attic, _annex_y(xw) + _annex_half(), zn - 0.08, 9.68,
		"siding", 0.0, false)


## Заслонка от y0 до кровли пристройки, нарезанная по x поперёк ската.
func _wall_to_annex_roof(x0: float, x1: float, y0: float, z0: float, z1: float) -> void:
	var n := maxi(1, int(ceil((x1 - x0) / SHELL_STEP)))
	for i in n:
		var xa := x0 + (x1 - x0) * i / float(n)
		var xb := x0 + (x1 - x0) * (i + 1) / float(n)
		var top := _cap(xa, xb, 99.0, false)
		if top - y0 < 0.002:
			continue
		box(xa, xb, y0, top, z0, z1, "siding", 0.0, false)


# ---------- чердак ----------

# Стены чердака (5.9…7.75) выше конька только в середине дома: у карнизов
# кровля идёт на 6.8, и метровая полоса стены торчала сквозь неё наружу.
# От ворот дом читался лесенкой из плоских коробок. Здесь эти стены и потолок
# чердака кладутся заново, подрезанные по скату; их коллизия ушла в общий
# проход нетронутой (collide_only в wall/slab).
func _attic_patch() -> void:
	var y0 := float(site["Y"]["ROOF"])         # 5.9
	var top := y0 + float(site["H"]["ROOF"])   # 7.75
	var t := 0.12
	var xw := -5.2
	var xe := 1.8
	var zn := 9.8
	var zs := 16.0

	# Северная и южная стены: скат поперёк них почти не меняется, хватает
	# одного потолка на всю длину. В северной — окно, вокруг него встаёт
	# слуховое окно (ниже), поэтому её середина остаётся высокой.
	var cap_n := _cap(zn - t / 2.0, zn + t / 2.0, top, true)
	var cap_s := _cap(zs - t / 2.0, zs + t / 2.0, top, true)
	var dorm0 := -2.15
	var dorm1 := -1.05
	box(xw, dorm0, y0, cap_n, zn - t / 2.0, zn + t / 2.0, "siding", 0.0, false)
	box(dorm1, xe, y0, cap_n, zn - t / 2.0, zn + t / 2.0, "siding", 0.0, false)
	box(xw, xe, y0, cap_s, zs - t / 2.0, zs + t / 2.0, "siding", 0.0, false)

	# Западная и восточная: вдоль них кровля поднимается к коньку и опускается
	# обратно, поэтому потолок считается на каждой дольке отдельно.
	_wall_to_tent(xw - t / 2.0, xw + t / 2.0, y0, top, zn, zs)
	_wall_to_tent(xe - t / 2.0, xe + t / 2.0, y0, top, zn, zs)

	# Потолок чердака: у карнизов он выше кровли и торчал плоской плитой
	# наружу. Там, где скат ниже, его просто нет — и это правильно: под самой
	# кровлей потолку взяться неоткуда.
	var cy0 := CLIP_SLAB_Y - 0.1
	var n := maxi(1, int(ceil((zs - zn) / SHELL_STEP)))
	for i in n:
		var za := zn + (zs - zn) * i / float(n)
		var zb := zn + (zs - zn) * (i + 1) / float(n)
		var cap := _cap(za, zb, CLIP_SLAB_Y, true)
		if cap - cy0 < 0.002:
			continue
		box(xw, xe, cy0, cap, za, zb, "boards", 1.4, false)

	_dormer(dorm0, dorm1, zn, t, y0, cap_n)


## Заслонка от y0 до двускатной кровли, нарезанная по z вдоль ската.
func _wall_to_tent(x0: float, x1: float, y0: float, top: float,
		z0: float, z1: float) -> void:
	var n := maxi(1, int(ceil((z1 - z0) / SHELL_STEP)))
	for i in n:
		var za := z0 + (z1 - z0) * i / float(n)
		var zb := z0 + (z1 - z0) * (i + 1) / float(n)
		var cap := _cap(za, zb, top, true)
		if cap - y0 < 0.002:
			continue
		box(x0, x1, y0, cap, za, zb, "siding", 0.0, false)


# Слуховое окно. Окно чердака сидит на 6.4…7.0, а кровля проходит на 6.77 —
# после подрезки стены оно оказалось бы наполовину срезанным. Вместо этого
# вокруг него встаёт нормальное слуховое окно: две щеки, козырёк и кусок стены
# до 7.1, который окну и служит задником.
func _dormer(x0: float, x1: float, z: float, t: float, y0: float, cap: float) -> void:
	var top := 7.1
	var face := z - t / 2.0
	var out := face - 0.42        # насколько окно выступает из ската на север

	# Задняя стенка: то, во что вставлено само окно. Проём 6.4…7.0 оставляем.
	box(x0, x1, y0, 6.4, face, z + t / 2.0, "siding", 0.0, false)
	box(x0, x1, 7.0, top, face, z + t / 2.0, "siding", 0.0, false)

	# Щёки. Низ уводим под кровлю, чтобы между ними и скатом не осталось щели.
	var cheek := 0.1
	box(x0, x0 + cheek, cap - 0.5, top, out, z + t / 2.0, "siding", 0.0, false)
	box(x1 - cheek, x1, cap - 0.5, top, out, z + t / 2.0, "siding", 0.0, false)

	# Козырёк с небольшим уклоном на север и свесами по краям.
	_slope(x0 - 0.1, x1 + 0.1, out - 0.12, z + t / 2.0, top + 0.02, top + 0.16,
		"roof", 0.1, false)


# ---------- карниз ----------

# Кровля лежит на x −6…2.6, z 9.2…16.6, а стены мансарды — по x −5.6…2.2,
# z 9.6…16.2. Между верхом стены и низом кровли по всему периметру был воздух:
# снизу это читалось как тёмная щель под свесом, а с торцов — как дыра
# в подкровельное пространство.
func _eaves_patch() -> void:
	var r := _roof_def("tent")
	var xr: Array = r["x"]
	var zr: Array = r["z"]
	var x0 := float(xr[0]) - 0.05
	var x1 := float(xr[1]) + 0.05
	var z0 := float(zr[0]) - 0.06
	var z1 := float(zr[1]) + 0.06
	var base := 5.9
	var eave := float(r["eaveY"])

	# Фриз: от верха стены мансарды до нижней кромки ската.
	box(x0, x1, base, eave + 0.01, z0, z0 + 0.12, "siding", 0.0, false)
	box(x0, x1, base, eave + 0.01, z1 - 0.12, z1, "siding", 0.0, false)
	box(x0, x0 + 0.1, base, eave + 0.01, z0, z1, "siding", 0.0, false)
	# Восточный фриз ниже: над ним проходит скат пристройки, и полная высота
	# вылезла бы сквозь него наружу.
	box(x1 - 0.1, x1, base, minf(eave + 0.01, _annex_y(x1) - _annex_half()), z0, z1,
		"siding", 0.0, false)

	# Подшивка свеса: полоса между стеной мансарды и фризом, снизу.
	var sy1 := base
	var sy0 := base - 0.06
	box(x0, x1, sy0, sy1, z0, 9.68, "siding", 0.0, false)
	box(x0, x1, sy0, sy1, 16.12, z1, "siding", 0.0, false)
	box(x0, -5.52, sy0, sy1, 9.68, 16.12, "siding", 0.0, false)
	box(2.12, x1, sy0, sy1, 9.68, 16.12, "siding", 0.0, false)


# ---------- балкон ----------

# Дверь с площадки лестницы (проём в w-n2 на x = −3.9) выводила на площадку
# без крыши и с парапетом по пояс — читалось это не как балкон, а как дыра
# в доме. Балкон остаётся балконом (главы цепляются за ROOMS.balcony как
# за outdoor), но теперь у него есть козырёк над дверью и парапет повыше.
func _balcony_patch() -> void:
	var y := float(site["Y"]["ATTIC"])     # 3.3
	var rail := y + 1.0                    # верх w-balcony-*
	var rise := 0.15

	# Парапет с 1.0 до 1.15.
	box(-5.68, 1.05, rail, rail + rise, 6.52, 6.68, "siding", 0.0, false)
	box(-5.68, -5.52, rail, rail + rise, 6.52, 9.6, "siding", 0.0, false)
	box(0.95, 1.05, rail, rail + rise, 6.52, 9.6, "siding", 0.0, false)
	# Уступ восточнее балконной стенки парапета не имел вовсе.
	box(1.0, 2.28, y, rail + rise, 6.52, 6.68, "siding", 0.0, false)

	# Козырёк над дверью с площадки. Идёт продолжением карниза, а не отдельной
	# полкой: свес и так выходит на 46 см, и вторая крыша под ним читалась бы
	# как стол посреди балкона. Высоту держит верх проёма (5.35) — козырёк
	# ниже него перекрывал бы саму дверь.
	var dx := -3.9
	_slope(dx - 0.95, dx + 0.95, 8.3, 9.14, 5.66, 5.84, "roof", 0.12, false)
	# Кронштейны под козырьком: без них он висит в воздухе.
	for s: float in [-0.86, 0.86]:
		box(dx + s - 0.04, dx + s + 0.04, 5.5, 5.68, 8.45, 9.6, "boards", 0.0, false)


# ---------- сборка ----------

# ФАЗА 16. Нарезка слитых сеток по клеткам — ДО того, как построен хоть один
# новый дом.
#
# Раньше _finish() сливал всю карту в ~19 сеток на материал, без единой
# пространственной нарезки. Такая сетка габаритом во всю карту В КАДРЕ ВСЕГДА:
# один меш «boards» тянулся от кухни игрока до поля, его AABB не отсекается
# фрустумом никогда, и все его треугольники уходили в GPU каждый кадр — даже
# во дворе, откуда не видно ни доски околицы. Правка была описана как
# известная и отложенная (CONTRACTS.md); при карте втрое откладывать её
# значит гарантировать лаги.
#
# Клетка 24 м — компромисс, который меряется: меньше клетка — больше вызовов
# отрисовки (каждый кусок это свой draw call), больше — сетка опять едет в
# кадр целиком. Дальность 56 м выбрана не «на глаз»: туман кончается на 32 м
# (site.json FOG.far), полудиагональ клетки 17 м, 32 + 17 = 49, и ещё семь
# метров запаса, чтобы кусок не гас у игрока на глазах.
const CHUNK_CELL := 32.0
const CHUNK_VIS_END := 56.0
# Сетка сдвинута по X на полклетки НЕ для красоты: без сдвига граница клеток
# проходит по x = 0, то есть ровно посередине дома игрока, и весь двор —
# самая тяжёлая точка карты — разваливается на две клетки, удваивая себе
# число вызовов отрисовки. Со сдвигом дом, баня, огород и погреб лежат в одной.
const CHUNK_ORIGIN_X := 16.0
const CHUNK_ORIGIN_Z := 0.0
# Кусок мельче этого в клетку не режется: у материала, который весь помещается
# в одну клетку, нарезка отнимает вызовы отрисовки и не даёт ничего взамен.
const CHUNK_MIN_SPAN := 32.0

func _finish(world_root: Node3D) -> void:
	for key: String in buckets.keys():
		var b: Dictionary = buckets[key]
		var vs: Array = b["v"]
		if vs.is_empty():
			continue
		var ns: Array = b["n"]
		var uvs: Array = b["uv"]

		var visual_only := key.begins_with("visual:")
		var material_key := key.trim_prefix("visual:") if visual_only else key
		var mat: Material = mats.mesh_fence() if material_key == "meshfence" \
			else mats.get_mat(material_key)
		# Плитка дорожек лежит в шести сантиметрах над землёй и тень от себя
		# отбрасывала полосой по всему двору — там, где земля и так в тени.
		# ФАЗА 13: соседские дома переехали с 'silhouette' на свои два ключа —
		# и обязаны остаться в этом же списке. Тени от девяти коробок в тридцати
		# метрах не видит никто, а карту теней они едят наравне с домом игрока.
		var casts := key != "grass" and key != "gravel" and key != "silhouette" \
			and key != "walkway" and key != "neighbour" and key != "neighbourroof" \
			and key != "conifer"
		if visual_only:
			casts = false

		# Треугольник кладётся в клетку по ПЕРВОЙ вершине: считать центроид на
		# двухстах тысячах треугольников дороже, чем стоит точность границы.
		# Габарит куска всё равно считается по настоящим вершинам, поэтому
		# фрустум режет верно; центр нужен только дальности видимости.
		# Материал, который весь помещается в клетку, оставляем одной сеткой.
		var span_lo := Vector3(INF, INF, INF)
		var span_hi := Vector3(-INF, -INF, -INF)
		for p: Vector3 in vs:
			span_lo = span_lo.min(p)
			span_hi = span_hi.max(p)
		var whole := (span_hi.x - span_lo.x) <= CHUNK_MIN_SPAN \
			and (span_hi.z - span_lo.z) <= CHUNK_MIN_SPAN

		var groups: Dictionary = {}
		var skin_ranges: Array = _skin_ranges.get(key, [])
		skin_ranges.sort_custom(func(a: Dictionary, z: Dictionary) -> bool:
			return int(a["first"]) < int(z["first"]))
		var skin_cursor := 0
		var tri_n := vs.size() / 3
		for t in tri_n:
			var o := t * 3
			while skin_cursor < skin_ranges.size() and int(skin_ranges[skin_cursor]["end"]) <= o:
				skin_cursor += 1
			var skin_key := ""
			if skin_cursor < skin_ranges.size() and int(skin_ranges[skin_cursor]["first"]) <= o:
				skin_key = String(skin_ranges[skin_cursor]["key"])
			var p: Vector3 = vs[o]
			# Дерево целиком принадлежит клетке своего якоря в обоих LOD.
			if _forest_lows.has(key) and _skin_tree_info.has(skin_key):
				p = (_skin_tree_info[skin_key]["transform"] as Transform3D).origin
			var ck := Vector2i.ZERO if whole else Vector2i(
				int(floor((p.x + CHUNK_ORIGIN_X) / CHUNK_CELL)),
				int(floor((p.z + CHUNK_ORIGIN_Z) / CHUNK_CELL)))
			var g: Dictionary = groups.get(ck, {})
			if g.is_empty():
				g = {"v": [], "n": [], "uv": [], "skin_parts": {}}
				groups[ck] = g
			var gv: Array = g["v"]
			var gn: Array = g["n"]
			var gu: Array = g["uv"]
			if not skin_key.is_empty():
				var parts: Dictionary = g["skin_parts"]
				if not parts.has(skin_key):
					parts[skin_key] = []
				var spans: Array = parts[skin_key]
				var first := gv.size()
				if not spans.is_empty() and (spans[-1] as Vector2i).x + (spans[-1] as Vector2i).y == first:
					spans[-1] = (spans[-1] as Vector2i) + Vector2i(0, 3)
				else:
					spans.append(Vector2i(first, 3))
			for i in 3:
				gv.append(vs[o + i])
				gn.append(ns[o + i])
				gu.append(uvs[o + i])

		for ck: Vector2i in groups.keys():
			var g: Dictionary = groups[ck]
			var gv: Array = g["v"]
			var lo := Vector3(INF, INF, INF)
			var hi := Vector3(-INF, -INF, -INF)
			for p: Vector3 in gv:
				lo = lo.min(p)
				hi = hi.max(p)
			var centre := (lo + hi) * 0.5
			var local := PackedVector3Array()
			local.resize(gv.size())
			for i in gv.size():
				local[i] = (gv[i] as Vector3) - centre
			var arrays := []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = local
			arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array(g["n"])
			arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(g["uv"])
			var mesh := ArrayMesh.new()
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			var mi: MeshInstance3D = ForestLodMesh.new() if _forest_lows.has(key) else MeshInstance3D.new()
			mi.name = "merged:%s:%d.%d" % [key, ck.x, ck.y]
			mi.mesh = mesh
			mi.position = centre
			mi.material_override = mat
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts \
				else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.visibility_range_end = CHUNK_VIS_END
			mi.visibility_range_end_margin = 8.0
			mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
			if mi is ForestLodMesh:
				var low_data := _forest_low_group(key,g,centre)
				var background_data := _forest_low_group(key,g,centre,true)
				(mi as ForestLodMesh).configure(_forest_mesh(low_data),low_data["anchors"],low_data["near_parts"],low_data["far_parts"],
					_forest_mesh(background_data),background_data["far_parts"])
			var skin_parts: Dictionary = {}
			var skin_trees: Dictionary = {}
			var skin_ids: Dictionary = {}
			var skin_needs: Dictionary = {}
			for part_key: String in g["skin_parts"]:
				if _skin_tree_info.has(part_key):
					var tree_info: Dictionary = _skin_tree_info[part_key].duplicate()
					tree_info["ranges"] = g["skin_parts"][part_key]
					skin_trees[tree_info["id"]] = tree_info
				else:
					skin_parts[part_key] = g["skin_parts"][part_key]
					skin_ids[part_key] = _skin_parts_info[part_key]["id"]
					skin_needs[part_key] = _skin_parts_info[part_key]["needs_id"]
			if not skin_parts.is_empty():
				mi.set_meta("skin_parts", skin_parts)
				mi.set_meta("skin_part_ids", skin_ids)
				mi.set_meta("skin_part_needs_id", skin_needs)
			if not skin_trees.is_empty():
				mi.set_meta("skin_tree_parts", skin_trees)
			if not skin_parts.is_empty() or not skin_trees.is_empty():
				mi.set_meta("skin_owner", NodePath(".."))
			world_root.add_child(mi)
	for id: String in decor.keys():
		world_root.add_child(decor[id])
		var item: Node3D = decor[id]
		if not item.has_meta("skin_key"):
			for zone: String in ["home", "yard", "street", "village", "outskirts", "snt", "valya"]:
				if id.begins_with(zone + "-"):
					skin_tag(item, "interiors", zone)
					break
		if item.has_meta("skin_key"):
			_skin_dynamic_children(item)
			_skin_tag_children(item, item)
	for id: String in (scatter.get("nodes", {}) as Dictionary).keys():
		world_root.add_child((scatter["nodes"] as Dictionary)[id])

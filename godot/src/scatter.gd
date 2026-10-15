# Зелень по всей карте одним draw call на тип (фаза 14).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ. Props ничего не сливает: каждая модель — свой
# MeshInstance3D и свой draw call. Пётр просил засадить ассетами всю карту,
# а карта после околицы выросла вдвое; в лоб это тысяча инстансов и тысяча
# вызовов отрисовки, и упрётся сцена не в GPU, а в GDScript. MultiMesh рисует
# любое число копий одной сеткой, поэтому четырнадцать видов травы стоят
# столько же, сколько четырнадцать кустов.
#
# ЧТО ЗДЕСЬ НЕЛЬЗЯ. Ни одной коробки в коллизию: трава не твёрдая, а паритет
# 311/4/83 держится на том, что новая геометрия в наборы не попадает вовсе.
# Модуль только читает мир — b.col.point_hit() — и ставит инстансы туда,
# где пусто.
#
# ДЕТЕРМИНИЗМ. Раскладка обязана собираться побайтово одинаково: по ней
# снимаются кадры, ею же считаются draw calls, и «в этот раз куст вырос
# в дверях» — не то, что хочется искать глазами. Поэтому ни одного randf():
# всё те же sin()-джиттеры, что в street_world.tree_line().
#
# ПРАВИЛА РАСКЛАДКИ (их сторожит tests/test_scatter.gd):
#   - ни одного инстанса внутри твёрдого — проба точкой по ALL_SOLID;
#   - ни одного в полосах CLEAR: дорога, полоса деда z [-5.5, -0.9], кольцо
#     Аркадия z [-6.2, -0.3], подходы к дверям и воротам;
#   - ни одного за пределами объявленных площадок AREAS;
#   - между соседями одного вида — не ближе gap;
#   - при повторной сборке раскладка та же до последнего бита.

class_name Scatter
extends RefCounted

const DATA := "res://data/scatter.json"
const MODEL_DIR := "res://assets/models/"

# Дальность видимости куска и сторона клетки нарезки (фаза 15). 45 м — за
# кромкой тумана (FOG.far 32) плюс полудиагональ клетки 11.3 м: весь кусок
# успевает раствориться до отсечения, а то, что дальше, не видно и без него.
# Клетка 16 м: меньше — узлов больше, чем экономии; больше — площадка
# «околица» шириной 79 м опять едет в кадр целиком.
const VIS_END := 45.0
const VIS_FADE := 6.0
const CELL := 16.0

# Высота пробы по плите пола первого этажа (site.json Y: CELLAR_TOP 0.35,
# FLOOR1 0.45) — ровно её середина.
const FLOOR_PROBE := 0.40

# Кэш файла на процесс — тем же приёмом, что OutskirtsWorld._cache. null
# означает «ещё не читали», {} — «файла нет, модуль выключен».
static var _cache: Variant = null


static func data() -> Dictionary:
	if _cache == null:
		if not FileAccess.file_exists(DATA):
			_cache = {}
		else:
			var txt := FileAccess.get_file_as_string(DATA)
			var got: Variant = JSON.parse_string(txt)
			_cache = got if got is Dictionary else {}
	return _cache


# ---------------------------------------------------------------- сборка ----

# Возвращает {"nodes": {id -> MultiMeshInstance3D}, "layout": {kind -> Array},
# "instances": int, "surfaces": int}. Узлы в мир добавляет _finish()
# WorldBuilder'а — тем же циклом, что decor.
static func build(b: WorldBuilder) -> Dictionary:
	var d := data()
	var out := {"nodes": {}, "layout": {}, "instances": 0, "surfaces": 0,
		"collision_proxies": []}
	if d.is_empty():
		return out
	var kinds: Array = d.get("KINDS", [])
	if kinds.is_empty():
		return out

	var nodes: Dictionary = out["nodes"]
	var layouts: Dictionary = out["layout"]
	var total := 0
	var surfaces := 0
	var proxy_pending: Array = []
	for k: Dictionary in kinds:
		var name := String(k.get("m", ""))
		if name == "":
			continue
		# wash — общий тон вида: множитель поверх исходной текстуры. У
		# Quaternius листва курортно-зелёная, и без него она в кадре 1988 года
		# светится. Значение по умолчанию берётся из WASH файла; вид может
		# объявить своё (камень гасится иначе, чем крона).
		var pieces := _pieces(name, int(k.get("wash", d.get("WASH", 0xffffff))))
		if pieces.is_empty():
			push_warning("scatter: модель не загрузилась — " + name)
			continue
		var bnd := _bounds(pieces)
		var height: float = maxf(0.0001, bnd.y - bnd.x)
		var rows := layout(b, d, k)
		layouts[name] = rows
		if rows.is_empty():
			continue
		if k.get("collision", null) is Dictionary:
			proxy_pending.append([k, name, rows])
		total += rows.size() / 5
		var casts: bool = bool(k.get("shadow", false))
		# ФАЗА 15. Раскладка режется на куски, и каждый кусок становится своим
		# узлом. Один MultiMesh на весь вид дешевле по числу узлов, но его
		# габарит накрывает карту от x -45 до 45: он в кадре ВСЕГДА, отсекать
		# его нечем, и все его треугольники уходят в GPU на каждом кадре — даже
		# во дворе, где ни одного куста околицы не видно.
		var chunks := _chunks(rows, _areas(d, k))
		for key: String in chunks.keys():
			var chunk: Dictionary = chunks[key]
			var idx: PackedInt32Array = chunk["rows"]
			var c: Vector3 = chunk["center"]
			for pi in pieces.size():
				var piece: Dictionary = pieces[pi]
				var mm := MultiMesh.new()
				mm.transform_format = MultiMesh.TRANSFORM_3D
				mm.mesh = piece["mesh"]
				mm.instance_count = idx.size()
				var local: Transform3D = piece["xf"]
				for i in idx.size():
					var o: int = idx[i] * 5
					var sc := float(rows[o + 4]) / height
					var xf := Transform3D.IDENTITY
					xf = xf.rotated(Vector3.UP, float(rows[o + 3]))
					xf = xf.scaled(Vector3(sc, sc, sc))
					# Начало координат у Quaternius не всегда в подошве: низ
					# габарита вычитается, иначе половина кустов висит в воздухе,
					# а половина уходит в землю по макушку.
					#
					# Координаты — ОТНОСИТЕЛЬНО центра куска: габарит MultiMesh
					# считается по инстансам, и только так он выходит размером
					# с кусок, а не с карту.
					xf.origin = Vector3(float(rows[o]) - c.x,
						float(rows[o + 1]) - bnd.x * sc - c.y, float(rows[o + 2]) - c.z)
					mm.set_instance_transform(i, xf * local)
				var mi := MultiMeshInstance3D.new()
				mi.name = "scatter-%s-%s-%d" % [name, key, pi]
				mi.multimesh = mm
				mi.position = c
				# Один вид содержит несколько исходных сеток. Скин-слою нужны
				# их связь и local, уже включённый в неизменяемые инстансы.
				mi.set_meta("skin_key", "scatter/" + name)
				mi.set_meta("skin_group", "scatter-%s-%s" % [name, key])
				mi.set_meta("skin_piece_index", pi)
				mi.set_meta("skin_piece_count", pieces.size())
				mi.set_meta("skin_piece_transform", local)
				# Дальше 50 м куст не рисуется вовсе. Это не обрезка картинки:
				# туман кончается на 32 м (site.json FOG), за ним не видно
				# ничего. Считается дальность от начала координат узла — ради
				# этого кусок и получил собственный центр.
				mi.visibility_range_end = VIS_END
				mi.visibility_range_end_margin = VIS_FADE
				mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
				# Тень от травы не видит никто, а карту теней она ест наравне
				# с домом: по умолчанию выключено, дереву можно вернуть флагом.
				mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if casts \
					else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				nodes[mi.name] = mi
				surfaces += 1
	# Прокси ставятся после ВСЕЙ раскладки: иначе ранний proxy сам стал бы
	# "твёрдым" для поздних видов и менял бы детерминированный visual layout.
	for pending: Array in proxy_pending:
		_add_collision_proxies(b, d, pending[0], String(pending[1]), pending[2],
			out["collision_proxies"])
	out["instances"] = total
	out["surfaces"] = surfaces
	return out


# Опциональная физическая читаемость крупных объектов. Конфигурация вида:
# `"collision": {"size": [0.5, 2.4, 0.5], "max": 8}`. Прокси добавляются
# только раскладке, уже прошедшей CLEAR/room/solid-фильтры, и живут исключительно
# в SET_OVERLAY, поэтому базовые 311/4/83 и 3885 треугольников неизменны.
static func _add_collision_proxies(b: WorldBuilder, data_cfg: Dictionary,
		kind: Dictionary, model: String, rows: Array, out: Array) -> void:
	var cfg: Variant = kind.get("collision", null)
	if not (cfg is Dictionary):
		return
	var sz: Array = (cfg as Dictionary).get("size", [])
	if sz.size() != 3:
		return
	var sx := maxf(0.08, float(sz[0]))
	var sy := maxf(0.08, float(sz[1]))
	var szv := maxf(0.08, float(sz[2]))
	var wanted := int((cfg as Dictionary).get("max", rows.size() / 5))
	var clear: Array = data_cfg.get("CLEAR", [])
	var rooms := rooms_of(b)
	var accepted := 0
	for i in rows.size() / 5:
		if accepted >= wanted:
			break
		var o := i * 5
		var x := float(rows[o])
		var y := float(rows[o + 1])
		var z := float(rows[o + 2])
		# Полный proxy-AABB с запасом капсулы, а не только его origin, обязан
		# миновать проверяемые маршруты и помещения. Ручные `at` проходят этот
		# фильтр тоже — layout намеренно не фильтрует визуальный реквизит.
		if _rects_touch(x, z, sx * 0.5 + 0.30, szv * 0.5 + 0.30, clear):
			continue
		if _rects_touch(x, z, sx * 0.5 + 0.30, szv * 0.5 + 0.30, rooms):
			continue
		if b.col.point_hit(x, y + sy * 0.5, z, CollisionWorld.ALL_SOLID):
			continue
		var id := "scatter-proxy-%s-%d" % [model, i]
		b.col.add_box_d(CollisionWorld.SET_OVERLAY, x - sx * 0.5, y, z - szv * 0.5,
			x + sx * 0.5, y + sy, z + szv * 0.5, id)
		out.append({"id": id, "model": model,
			"box": [x - sx * 0.5, x + sx * 0.5, y, y + sy,
				z - szv * 0.5, z + szv * 0.5]})
		accepted += 1


static func _rects_touch(x: float, z: float, hx: float, hz: float,
		rects: Array) -> bool:
	for r: Array in rects:
		if r.size() >= 4 and x + hx >= float(r[0]) and x - hx <= float(r[1]) \
				and z + hz >= float(r[2]) and z - hz <= float(r[3]):
			return true
	return false




# Раскладка одного вида: плоский массив по пять чисел на инстанс —
# x, y, z, поворот вокруг Y, ЦЕЛЕВАЯ ВЫСОТА в метрах. Высота, а не масштаб:
# у Quaternius и Kenney разный калибр, и «полтора метра» читается, а
# «множитель 0.37» — нет.
static func layout(b: WorldBuilder, d: Dictionary, k: Dictionary) -> Array:
	var rows: Array = []

	# Экземпляры, поставленные РУКАМИ: бидоны у амбара, кувшинки на воде,
	# камыш по берегу. Формат тот же, что у раскладки, — [x, y, z, yaw, h].
	#
	# Зачем они здесь, а не в data/props.json, где стоит весь прочий реквизит.
	# Props ничего не сливает: каждая банка — свой MeshInstance3D и свой
	# draw call, и сорок банок по околице стоили бы шестидесяти вызовов на
	# точку, с которой видно всю новую карту (замерено: 220 -> 353 у колодца).
	# Здесь весь вид — один MultiMesh, сколько бы банок в нём ни лежало.
	# Место при этом остаётся выбранным, а не выпавшим: гора хлама у забора
	# и одна банка посреди двора говорят разное.
	#
	# Идут ПЕРВЫМИ и засчитываются в раскладку: случайные кусты обходят их
	# по gap, а не прорастают сквозь.
	for at: Variant in k.get("at", []):
		if not (at is Array) or (at as Array).size() < 5:
			continue
		var a: Array = at
		if EnvironmentLandscape.on_route(float(a[0]),float(a[2]),0.20):
			continue
		rows.append_array([float(a[0]), float(a[1]), float(a[2]),
			float(a[3]), float(a[4])])

	var areas := _areas(d, k)
	if areas.is_empty():
		return rows
	var total_area := 0.0
	var acc: Array = []
	for r: Array in areas:
		total_area += absf(float(r[1]) - float(r[0])) * absf(float(r[3]) - float(r[2]))
		acc.append(total_area)
	if total_area <= 0.0:
		return rows

	var clear: Array = d.get("CLEAR", [])
	var want := int(k.get("count", 40))
	var gap := float(k.get("gap", 0.9))
	var hr: Array = k.get("h", [1.0, 1.4])
	var h0 := float(hr[0])
	var h1 := float(hr[1])
	var salt := float(k.get("salt", 1.0))
	var yoff := float(k.get("y", 0.0))

	var rooms := rooms_of(b)

	var placed := 0
	var i := 0
	var limit := want * 14
	while placed < want and i < limit:
		var s := float(i) * 1.0 + salt * 97.0
		i += 1
		var u := 0.5 + 0.5 * sin(s * 12.9898)
		var v := 0.5 + 0.5 * sin(s * 78.2330)
		var w := 0.5 + 0.5 * sin(s * 43.7585)
		# Площадка по накопленной площади: большие полосы получают больше
		# кустов, и «густо на околице, редко на обочине» выходит само.
		var pick := u * total_area
		var ai := 0
		while ai < acc.size() - 1 and pick > float(acc[ai]):
			ai += 1
		var r: Array = areas[ai]
		var x := float(r[0]) + (float(r[1]) - float(r[0])) * v
		var z := float(r[2]) + (float(r[3]) - float(r[2])) * w
		if EnvironmentLandscape.on_route(x,z,0.20):
			continue
		if _in_rects(x, z, clear):
			continue
		# Внутрь помещения — нельзя, и это НЕ то же самое, что «внутрь
		# твёрдого». Куст, выпавший в комнату, стоит в воздухе между полом
		# и потолком, и обе старые пробы его пропускали: снизу пусто, сверху
		# пусто. Так и вырос куст с цветами на половицах — площадка yard-edge
		# накрывает дом Вити целиком.
		if _in_rects(x, z, rooms):
			continue
		# Внутрь стен, построек и заборов — нельзя. Три пробы: по щиколотку,
		# по плите пола и по грудь. Средняя не лишняя: плита первого этажа
		# лежит на 0.35..0.45, то есть ровно между старыми двумя, и куст
		# садился на сорок пять сантиметров ниже половиц.
		if b.col.point_hit(x, 0.25, z, CollisionWorld.ALL_SOLID):
			continue
		if b.col.point_hit(x, FLOOR_PROBE, z, CollisionWorld.ALL_SOLID):
			continue
		if b.col.point_hit(x, 1.20, z, CollisionWorld.ALL_SOLID):
			continue
		if _too_close(rows, x, z, gap):
			continue
		var yaw := TAU * (0.5 + 0.5 * sin(s * 2.3170))
		var hh := h0 + (h1 - h0) * (0.5 + 0.5 * sin(s * 5.1130))
		rows.append_array([x, yoff, z, yaw, hh])
		placed += 1
	return rows


# Прямоугольники ПОМЕЩЕНИЙ, куда зелени нельзя. Два источника, и оба живые:
#   - site.json ROOMS с высотой (h > 0): комнаты дома, сарай, туалет, теплица,
#     правление. Двор и улица тоже лежат в ROOMS, но с h = 0 — они и есть
#     то место, ради которого весь модуль;
#   - ZONES с реверберацией НЕ "outdoor": баня, погреб, амбар, клуб, сельпо.
#     К моменту сборки зелени овердеи уже дописали туда свои — Scatter
#     собирается последним из построек, и это ровно то, на чём он стоит.
static func rooms_of(b: WorldBuilder) -> Array:
	var out: Array = []
	var site: Dictionary = b.site
	var all_rooms: Dictionary = site.get("ROOMS", {})
	for key: String in all_rooms.keys():
		var r: Dictionary = all_rooms[key]
		if float(r.get("h", 0.0)) <= 0.01:
			continue
		var rx: Array = r["x"]
		var rz: Array = r["z"]
		out.append([float(rx[0]), float(rx[1]), float(rz[0]), float(rz[1])])
	for zn: Variant in site.get("ZONES", []):
		if not (zn is Dictionary):
			continue
		var z: Dictionary = zn
		if String(z.get("reverb", "outdoor")) == "outdoor":
			continue
		var rect: Array = z.get("rect", [])
		if rect.size() < 4:
			continue
		out.append([float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3])])
	return out


# Нарезка раскладки на куски: площадка, а внутри неё — клетка CELL на CELL.
# Ключ куска идёт в имя узла, чтобы в дереве сцены было видно, что где стоит.
# Экземпляр, не попавший ни в одну площадку (поставленный руками через "at"),
# уходит в кусок "at" своей клетки — габарит от этого не страдает.
#
# Возвращает {ключ -> {"rows": PackedInt32Array индексов, "center": Vector3}}.
# Центр — середина габарита куска по X/Z: относительно него и кладутся
# инстансы, и от него же считается дальность видимости.
static func _chunks(rows: Array, areas: Array) -> Dictionary:
	var out: Dictionary = {}
	var n := rows.size() / 5
	for i in n:
		var x := float(rows[i * 5])
		var z := float(rows[i * 5 + 2])
		var ai := -1
		for a in areas.size():
			var r: Array = areas[a]
			if x >= float(r[0]) and x <= float(r[1]) and z >= float(r[2]) and z <= float(r[3]):
				ai = a
				break
		var cx := int(floor(x / CELL))
		var cz := int(floor(z / CELL))
		var key := "%s.%d.%d" % ["at" if ai < 0 else str(ai), cx, cz]
		if not out.has(key):
			out[key] = {"rows": PackedInt32Array(), "x0": x, "x1": x, "z0": z, "z1": z}
		var ch: Dictionary = out[key]
		(ch["rows"] as PackedInt32Array).append(i)
		ch["x0"] = minf(float(ch["x0"]), x)
		ch["x1"] = maxf(float(ch["x1"]), x)
		ch["z0"] = minf(float(ch["z0"]), z)
		ch["z1"] = maxf(float(ch["z1"]), z)
	for key: String in out.keys():
		var ch: Dictionary = out[key]
		ch["center"] = Vector3((float(ch["x0"]) + float(ch["x1"])) * 0.5, 0.0,
			(float(ch["z0"]) + float(ch["z1"])) * 0.5)
	return out


static func _areas(d: Dictionary, k: Dictionary) -> Array:
	var all: Dictionary = d.get("AREAS", {})
	var out: Array = []
	for key: String in k.get("areas", []):
		for r: Array in all.get(key, []):
			out.append(r)
	return out


static func _in_rects(x: float, z: float, rects: Array) -> bool:
	for r: Array in rects:
		if x >= float(r[0]) and x <= float(r[1]) and z >= float(r[2]) and z <= float(r[3]):
			return true
	return false


static func _too_close(rows: Array, x: float, z: float, gap: float) -> bool:
	if gap <= 0.0:
		return false
	var g2 := gap * gap
	var n := rows.size() / 5
	for i in n:
		var dx := float(rows[i * 5]) - x
		var dz := float(rows[i * 5 + 2]) - z
		if dx * dx + dz * dz < g2:
			return true
	return false


# ---------------------------------------------------------------- модели ----

static var _models: Dictionary = {}
static var _mats: Dictionary = {}


# Куски модели: свой Mesh на каждый MeshInstance3D плюс его локальная матрица.
# Один MultiMesh на кусок, а не один на модель: у дерева кора и листва —
# разные сетки с разными материалами, а MultiMesh материал берёт из самой
# сетки. Два draw call на дерево вместо трёхсот — та же победа.
static func _pieces(name: String, _wash := 0xffffff) -> Array:
	# Placement and IDs come from the original layout; only the baked mesh changes.
	# Colours are authored by the local generator, so the old imported-model wash
	# must not multiply them a second time.
	if _models.has(name):
		return _models[name]
	var asset := ProceduralAssets.fetch("scatter/" + name)
	var out: Array = []
	for mesh: ArrayMesh in asset.get("meshes", []):
		if mesh.get_surface_count() > 0:
			out.append({"mesh": mesh, "xf": Transform3D.IDENTITY})
	_models[name] = out
	return out

static func _collect(node: Node, xf: Transform3D, out: Array, wash: int) -> void:
	var here := xf
	if node is Node3D:
		here = xf * (node as Node3D).transform
	if node is MeshInstance3D:
		var mesh: Mesh = (node as MeshInstance3D).mesh
		if mesh != null:
			_skin(mesh, wash)
			out.append({"mesh": mesh, "xf": here})
	for c in node.get_children():
		_collect(c, here, out, wash)


# Тот же перекрас, что Props._prepare(): unlit-палитра Kenney и Quaternius
# уезжает в дачную, и всё уходит под psx.gdshader. Материал ставится
# НА САМУ СЕТКУ, потому что MultiMeshInstance3D перекрывает материалом сразу
# все поверхности разом — кора и листва слились бы в один цвет.
## Перекраска в общий тон. wash — множитель, которым гасится ИСХОДНАЯ
## текстура вида.
##
## Зачем он вообще нужен. psx.gdshader считает ALBEDO = albedo * texture(),
## и Props для текстурированной поверхности ставит albedo белым: у Kenney
## текстуры и так в дачной гамме, белый их не трогает. У Quaternius Nature
## гамма другая — листва там курортно-зелёная, а цветы малиновые, и в кадре
## 1988 года они светятся, как накладка из другой игры. Палитрой по имени
## материала это не лечится: имя есть, а цвета в материале нет, весь цвет
## в текстуре. Лечится множителем — он и есть wash.
static func _skin(mesh: Mesh, wash: int) -> void:
	var am := mesh as ArrayMesh
	if am == null:
		return
	for si in am.get_surface_count():
		var src := am.surface_get_material(si)
		var key := "s:x"
		var tint := 0x6f7a5a
		var tex: Texture2D = null
		if src != null:
			key = "s:" + src.resource_name
			if Props.KENNEY_PALETTE.has(src.resource_name):
				tint = Props.KENNEY_PALETTE[src.resource_name]
			elif src is BaseMaterial3D:
				var c: Color = (src as BaseMaterial3D).albedo_color
				tint = (int(c.r8) << 16) | (int(c.g8) << 8) | int(c.b8)
			if src is BaseMaterial3D:
				tex = (src as BaseMaterial3D).albedo_texture
		if tex != null:
			key += ":tex:%06x" % wash
		if not _mats.has(key):
			var m := ShaderMaterial.new()
			m.shader = load(Materials.PSX_SHADER) as Shader
			m.set_shader_parameter("albedo",
				GameData.color(wash if tex != null else tint))
			if tex != null:
				m.set_shader_parameter("albedo_tex", tex)
			_mats[key] = m
		am.surface_set_material(si, _mats[key])


# Габарит модели по вертикали: x — подошва, y — макушка. По разнице целевая
# высота из данных переводится в масштаб, по подошве инстанс садится на землю.
static func _bounds(pieces: Array) -> Vector2:
	var lo := INF
	var hi := -INF
	for p: Dictionary in pieces:
		var a: AABB = (p["mesh"] as Mesh).get_aabb()
		var xf: Transform3D = p["xf"]
		for i in 8:
			var c := Vector3(
				a.position.x if (i & 1) == 0 else a.position.x + a.size.x,
				a.position.y if (i & 2) == 0 else a.position.y + a.size.y,
				a.position.z if (i & 4) == 0 else a.position.z + a.size.z)
			var y := (xf * c).y
			lo = minf(lo, y)
			hi = maxf(hi, y)
	if lo == INF:
		return Vector2(0.0, 1.0)
	return Vector2(lo, hi)

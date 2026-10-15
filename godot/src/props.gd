# Реквизит — порт src/world/props.js.
#
# Две половины. Первая — модели Kenney (CC0): они unlit и в мультяшной палитре,
# поэтому при загрузке материалы подменяются по имени на дачную палитру, иначе
# яркая пластмасса светилась бы в тёмном доме сама по себе. Kenney авторил
# примерно в половину натуральной величины — отсюда масштаб x2 по умолчанию.
# Вторая — всё, чего в CC0 нет: ВМ-12, «стенка», «Бирюса», печка с баллоном,
# дисковый телефон, будка, ряды банок, «Шестёрка». Собирается из коробок и
# цилиндров: под PSX-фильтром разница с импортированной моделью не читается.
#
# Коллизия своя: коробка-заместитель на предмет, отдельный набор SET_PROPS —
# так шкаф можно двигать сюжетом, не перестраивая мир. Габарит снимается ровно
# так же, как Box3.setFromObject в three: локальный AABB каждого меша прогоняется
# через его мировую матрицу и объединяется (НЕ по вершинам). Коробка ставится по
# середине этого габарита, а не по точке at: у моделей Kenney начало координат —
# угол габаритной коробки, и коллизия, посаженная на at, уезжала от предмета
# на полразмера.

class_name Props
extends RefCounted

const MODEL_DIR := "res://assets/models/"

# Материалы Kenney по именам -> дачная палитра.
const KENNEY_PALETTE := {
	"wood": 0x8a6a45,
	"woodDark": 0x5d472f,
	"metal": 0x8b9095,
	"metalDark": 0x4e5459,
	"metalMedium": 0x6f767c,
	"metalLight": 0xa4abb0,
	"glass": 0x93a9b4,
	"carpet": 0x8a6553,
	"carpetWhite": 0xb6ae9a,
	"carpetBlue": 0x5c6d80,
	"carpetDarker": 0x64483c,
	"lamp": 0xf0dfae,
	"plant": 0x54703f,
	"fur": 0x7d6a52,
	"_defaultMat": 0x8f8677,
	# ФАЗА 14. Шесть ключей, ровно по бюджету фазы, и ни одним больше — а
	# просилось шестнадцать. Причина, по которой десять не нужны: у Quaternius
	# палитра И ТАК выцветшая (DarkRed #7c3a32, Brown #824e36, RoofBlack
	# #4f4f4f), и подменять её собственной значило бы красить крашеное.
	# Подтянуты только те четыре, что вылезали из кадра 1988 года, — два
	# красных амбарных и два светлых, которыми Quaternius рисует наличники
	# и жесть. Белый #d1d1d1 на ночной улице читался неоном.
	"DarkRed": 0x6b3630,
	"LightRed": 0x7d453a,
	"White": 0xb9b2a0,
	"Grey": 0x878c8f,
	# Кувшинки Kenney (ok-lily) нарисованы бирюзовыми: #70e6d6 в чёрной воде
	# пожарного пруда светится, как индикатор. Оба листа — в цвет ряски.
	"leafsGreen": 0x55703f,
	"leafsDark": 0x3f5730,
}

# Модели, которые Kenney нарисовал не в половину, а иначе.
const MODEL_SCALE := {
	"bedSingle": 1.05, "bedDouble": 1.05,
	"rugRectangle": 1.35, "rugDoormat": 1.9,
	"trashcan": 0.62,
	"tree": 3.6, "tree-tall": 3.6, "tree-autumn": 3.6,
	"patch-grass": 1.0, "rock-flat": 1.0,
	"column-thin": 1.0, "gutter-vertical": 1.0,
	"loungeSofa": 2.1, "cabinetTelevision": 1.7,
	# ФАЗА 14. Quaternius авторил в натуральную величину, а не в половину:
	# множитель по умолчанию (2.0) сделал бы из амбара пятнадцатиметровый.
	# Единица — значит «s из props.json и есть настоящий масштаб».
	"farm-barn": 1.0, "farm-bigbarn": 1.0, "farm-coop": 1.0,
	"farm-fence": 1.0, "farm-fence2": 1.0, "farm-openbarn": 1.0,
	"farm-silo": 1.0, "farm-silohouse": 1.0, "farm-smallbarn": 1.0,
	"farm-windmill": 1.0,
	# ФАЗА 16, советские машины (OpenGameArt, madmedicsoft, CC0). Автор
	# моделировал не в метрах: «копейка» приезжает длиной 132 единицы, «бобик»
	# 54, «буханка» 41. Числа ниже — метр за единицу по НАСТОЯЩЕЙ длине машины
	# (ВАЗ-2101 4.07 м, УАЗ-469 4.03, УАЗ-452 4.36), чтобы s в props.json
	# оставалась единицей и означала «как в жизни».
	"sv-vaz2101-yellow": 0.0308, "sv-vaz2101-grey": 0.0308,
	"sv-vaz2105-green": 0.0308, "sv-vaz2106-blue": 0.0308,
	"sv-vaz2106-red": 0.0308,
	"sv-uaz469": 0.0746, "sv-uaz452": 0.1063, "sv-uaz452-grey": 0.1063,
}

# ФАЗА 15. Кто из реквизита имеет право отбрасывать тень.
#
# До фазы 15 флаг не задавался ни разу, а по умолчанию в Godot он ON: все 193
# предмета и 14 построек Quaternius уходили в теневой атлас луны — каждый
# лишним проходом сверх основного, и ещё раз на второй сплит. Во дворе, где
# в кадре один дом, это давало 2325 draw call.
#
# Тень оставлена тем, у кого она ЧИТАЕТСЯ как силуэт: «Шестёрка» у ворот,
# будка, поленница, летний душ, бочка, стремянка и велосипед у стены. Всё
# остальное — мелочь в доме и на полках: её тень или падает в стену вплотную,
# или не попадает в кадр вовсе.
#
# Список по id из data/props.json. Предмет без id (дерево, столб, забор
# Quaternius) тени не отбрасывает: их силуэт и так держит туман.
# ФАЗА 16. Тон модели — множитель поверх её собственной текстуры.
#
# ЗАЧЕМ ОН ЗДЕСЬ, А НЕ ТОЛЬКО В SCATTER. _prepare() для поверхности С ТЕКСТУРОЙ
# ставил albedo белым, и текстурированная модель приезжала в кадр 1988 года в
# своей исходной курортной гамме. Пока таких моделей было ноль, это никого не
# трогало; в фазе 16 приехал пак советских машин, у которых весь цвет в
# пиксель-арт текстуре, и жёлтая «копейка» засветила бы полдвора. Механизм
# слово в слово тот же, что в scatter.gd::_skin — он там уже принят.
#
# Имени в этом словаре нет — модель идёт как раньше, белым множителем.
const PROP_WASH := {
	# Машины: краска восемьдесят восьмого года, выгоревшая и пыльная.
	# Гасится сильнее зелени — металл в сумерках холоднее травы.
	"sv-vaz2101-yellow": 0xa79f8a, "sv-vaz2101-grey": 0xa8aca8,
	"sv-vaz2105-green": 0x9aa694, "sv-vaz2106-blue": 0x97a3ac,
	"sv-vaz2106-red": 0xab9188,
	"sv-uaz469": 0x9ba38f, "sv-uaz452": 0x9ea695, "sv-uaz452-grey": 0xa5a9a5,
	# Ретро-урбан Kenney: бетон и жесть, но чистые. Тот же тон, что у зелени
	# околицы, чтобы они не выпадали из общего кадра.
	"ru-light": 0xa9ada6, "ru-bench": 0xb0a68c, "ru-pallet": 0xb3a586,
	"ru-planks": 0xb3a586, "ru-dumpster": 0x9fa79c, "ru-shrub": 0x9aa886,
}

# Дальше этого предмет не рисуется вовсе (фаза 16). 48 м — с полуторным
# запасом за кромку тумана (32 м): раньше, чем предмет пропадёт, он полностью
# растворится в нём. Считается расстояние до начала координат узла, поэтому
# запас нужен и на габарит самой крупной постройки.
const VIS_END := 48.0
const VIS_FADE := 6.0

const SHADOW_PROPS := {
	"car": true, "doghouse": true, "woodpile": true, "summer-shower": true,
	"water-barrel": true, "stepladder": true, "bicycle": true, "compost": true,
}


var mats: Materials
var root: Node3D = null
var by_id: Dictionary = {}          # id -> Node3D
var colliders: Array = []           # [{cx,cy,cz,hx,hy,hz,yaw}] в порядке спавна
var notes: Dictionary = {}          # id -> {def, pos} — якоря для интеракта (фаза 2)
var dynamic_pool: Dictionary = {}   # id -> Node3D, спрятаны до своей главы

var _cache: Dictionary = {}         # имя модели -> {scene, foot_y, scale}
var _kenney_mats: Dictionary = {}


func _init(materials: Materials) -> void:
	mats = materials


# ---------- загрузка моделей ----------

# Грузим только те модели, которые действительно встречаются в данных.
func load_models(list: Array) -> Props:
	var names: Dictionary = {}
	for p: Dictionary in list:
		if p.has("m"):
			names[p["m"]] = true
	for name: String in names.keys():
		var path := MODEL_DIR + name + ".glb"
		if not ResourceLoader.exists(path):
			push_warning("модель не загрузилась: " + name)
			continue
		var packed := load(path) as PackedScene
		if packed == null:
			push_warning("модель не загрузилась: " + name)
			continue
		var scene := packed.instantiate() as Node3D
		_prepare(scene, name)
		# Элементы снимаются при масштабе 1: масштаб модели домножается в spawn().
		_cache[name] = {
			"scene": scene,
			"scale": float(MODEL_SCALE.get(name, 2.0)),
			"elems": _mesh_elements(scene, Transform3D.IDENTITY),
		}
	return self


func _prepare(node: Node3D, name: String) -> void:
	var wash := int(PROP_WASH.get(name, 0xffffff))
	for mi: MeshInstance3D in _all_meshes(node):
		var mesh := mi.mesh
		if mesh == null:
			continue
		for si in mesh.get_surface_count():
			var src := mesh.surface_get_material(si)
			var key := "k:x"
			var tint := 0x9a8f7d
			var tex: Texture2D = null
			if src != null:
				key = "k:" + src.resource_name
				if KENNEY_PALETTE.has(src.resource_name):
					tint = KENNEY_PALETTE[src.resource_name]
				elif src is BaseMaterial3D:
					var c: Color = (src as BaseMaterial3D).albedo_color
					tint = (int(c.r8) << 16) | (int(c.g8) << 8) | int(c.b8)
				if src is BaseMaterial3D:
					tex = (src as BaseMaterial3D).albedo_texture
			# Ключ кэша обязан помнить и тон: одну и ту же текстуру два вида
			# гасят по-разному, и без тона второй забрал бы материал первого.
			if tex != null:
				var texture_id := tex.resource_path if not tex.resource_path.is_empty() else str(tex.get_instance_id())
				key += ":tex:" + texture_id + ":%06x" % wash
			else:
				key += ":flat:%06x" % tint
			if not _kenney_mats.has(key):
				var m := ShaderMaterial.new()
				m.shader = load(Materials.PSX_SHADER) as Shader
				m.set_shader_parameter("albedo", GameData.color(wash if tex != null else tint))
				if tex != null:
					m.set_shader_parameter("albedo_tex", tex)
				_kenney_mats[key] = m
			mi.set_surface_override_material(si, _kenney_mats[key])


func _all_meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_all_meshes(c))
	return out


# Элементы габарита так же, как Box3.setFromObject: локальный AABB КАЖДОГО меша
# и его матрица, без прохода по вершинам. Складывать AABB промежуточно нельзя:
# у повёрнутой детали (лист бумаги на верстаке) двойное обрамление раздувает
# коробку на два сантиметра, и коллайдер перестаёт совпадать с эталоном.
# Формат элемента: 6 чисел AABB + 9 чисел матрицы 3x3 (по строкам) + 3 сдвига.
func _mesh_elements(node: Node, xf: Transform3D) -> Array:
	var out: Array = []
	var here := xf
	if node is Node3D:
		here = xf * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var a: AABB = (node as MeshInstance3D).mesh.get_aabb()
		var b := here.basis
		out.append(PackedFloat64Array([
			a.position.x, a.position.y, a.position.z,
			a.position.x + a.size.x, a.position.y + a.size.y, a.position.z + a.size.z,
			b.x.x, b.y.x, b.z.x,
			b.x.y, b.y.y, b.z.y,
			b.x.z, b.y.z, b.z.z,
			here.origin.x, here.origin.y, here.origin.z,
		]))
	for c in node.get_children():
		out.append_array(_mesh_elements(c, here))
	return out


# Элемент в мировых осях: восемь углов через свою матрицу, потом через матрицу
# holder'а. Одно обрамление на элемент, как в three.
func _world_aabb(elems: Array, ax: float, ay: float, az: float,
		rx: float, ry: float, rz: float) -> PackedFloat64Array:
	var out := PackedFloat64Array([INF, INF, INF, -INF, -INF, -INF])
	if elems.is_empty():
		return PackedFloat64Array([ax, ay, az, ax, ay, az])
	var hm := _euler_matrix(rx, ry, rz)
	for e: PackedFloat64Array in elems:
		for i in 8:
			var cx: float = e[0] if (i & 1) == 0 else e[3]
			var cy: float = e[1] if (i & 2) == 0 else e[4]
			var cz: float = e[2] if (i & 4) == 0 else e[5]
			var vx := e[6] * cx + e[7] * cy + e[8] * cz + e[15]
			var vy := e[9] * cx + e[10] * cy + e[11] * cz + e[16]
			var vz := e[12] * cx + e[13] * cy + e[14] * cz + e[17]
			var wx := hm[0] * vx + hm[1] * vy + hm[2] * vz + ax
			var wy := hm[3] * vx + hm[4] * vy + hm[5] * vz + ay
			var wz := hm[6] * vx + hm[7] * vy + hm[8] * vz + az
			out[0] = minf(out[0], wx); out[3] = maxf(out[3], wx)
			out[1] = minf(out[1], wy); out[4] = maxf(out[4], wy)
			out[2] = minf(out[2], wz); out[5] = maxf(out[5], wz)
	return out


# Тот же габарит без поворота holder'а — им ищется опора модели (footY).
func _elems_min_y(elems: Array, scale: float) -> float:
	var lo := INF
	for e: PackedFloat64Array in elems:
		for i in 8:
			var cx: float = e[0] if (i & 1) == 0 else e[3]
			var cy: float = e[1] if (i & 2) == 0 else e[4]
			var cz: float = e[2] if (i & 4) == 0 else e[5]
			lo = minf(lo, (e[9] * cx + e[10] * cy + e[11] * cz + e[16]) * scale)
	return lo


# ---------- сборка ----------

func build(world_root: Node3D, list: Array, col: CollisionWorld) -> Props:
	root = Node3D.new()
	root.name = "props"
	world_root.add_child(root)
	for def: Dictionary in list:
		spawn(def)
	rebuild_collision(col)
	return self


# Ставит скрытые предметы глав: их показывает show_dynamic(id).
func build_dynamic(list: Array) -> void:
	for def: Dictionary in list:
		var h := spawn(def)
		if h == null:
			continue
		h.visible = false
		if def.has("id"):
			dynamic_pool[def["id"]] = h


func show_dynamic(id: String, visible_now := true) -> void:
	if dynamic_pool.has(id):
		(dynamic_pool[id] as Node3D).visible = visible_now


func get_prop(id: String) -> Node3D:
	return by_id.get(id, null)


# Образцы моделей живут вне дерева — освободить их иначе некому.
func dispose() -> void:
	for name: String in _cache.keys():
		var scene: Node3D = _cache[name]["scene"]
		if is_instance_valid(scene):
			scene.free()
	_cache.clear()


# Строит один предмет по дескриптору.
func spawn(def: Dictionary) -> Node3D:
	var holder := Node3D.new()
	var at: Array = def["at"]
	var ax := float(at[0])
	var ay := float(at[1])
	var az := float(at[2])
	# Старые GLB-деревья проходят тот же clearance resolver, что процедурные
	# опушки и яблони. Явные координаты остаются якорем и двигаются только при
	# реальном конфликте кроны с постройкой/оградой/проходом.
	var model_name := String(def.get("m", ""))
	if model_name in ["tree", "tree-tall", "tree-autumn"] and def.get("col", null) is bool and def["col"] == false:
		var crown := 1.15 * float(def.get("s", 1.0))
		var resolved: Variant = StreetWorld.resolve_tree_position(
			String(def.get("id", model_name)) + "@%.2f,%.2f" % [ax, az],
			Vector2(ax, az), crown, StreetWorld.TREE_BOUNDS,
			StreetWorld.tree_footprints())
		if not (resolved is Vector2):
			holder.free()
			return null
		ax = (resolved as Vector2).x
		az = (resolved as Vector2).y
	var ry := float(def.get("ry", 0.0))
	var rx := float(def.get("rx", 0.0))
	var rz := float(def.get("rz", 0.0))
	holder.name = String(def.get("id", def.get("m", def.get("make", "prop"))))
	holder.position = Vector3(ax, ay, az)
	holder.basis = _euler_xyz(rx, ry, rz)

	# Элементы габарита в осях holder'а — из них потом мировой AABB.
	var elems: Array = []
	if String(def.get("make", "")) == "parkedVehicle":
		# Эти машины твёрдые только в SET_OVERLAY, который строит SntWorld.
		VehicleVisuals.build(mats, def, holder)
	elif def.has("m"):
		var name: String = def["m"]
		if not _cache.has(name):
			holder.free()
			return null
		var entry: Dictionary = _cache[name]
		var s := float(def.get("s", 1.0))
		var ms := float(entry["scale"])
		var src: Array = entry["elems"]
		var node := (entry["scene"] as Node3D).duplicate() as Node3D
		var total := ms * s
		node.scale = Vector3(total, total, total)
		# Опора модели приводится к нулю по Y, чтобы предмет ставился «на пол».
		var foot_y := _elems_min_y(src, ms)
		node.position = Vector3(0.0, -foot_y * s, 0.0)
		node = _baked_vegetation_visual(name, node)
		holder.add_child(node)
		for e: PackedFloat64Array in src:
			var c := e.duplicate()
			for k in range(6, 15):
				c[k] = c[k] * total
			c[15] = c[15] * total
			c[16] = c[16] * total - foot_y * s
			c[17] = c[17] * total
			elems.append(c)
	elif def.has("make"):
		var parts := _make(String(def["make"]), def)
		if parts.is_empty():
			holder.free()
			return null
		elems = _parts_elements(parts)
		if not preload("res://src/detailed_props.gd").build(mats, def, holder):
			_decorate_visuals(String(def["make"]), parts)
			_parts_to_nodes(parts, holder)
	else:
		holder.free()
		return null

	# Тень — только по белому списку (см. SHADOW_PROPS). Ставится до add_child:
	# после него узел уже в дереве, и лишний обход стоил бы столько же.
	#
	# ФАЗА 16. Тем же обходом ставится ДАЛЬНОСТЬ ВИДИМОСТИ. У реквизита её не
	# было вовсе: каждый из ста восьмидесяти шести предметов уходил в GPU
	# отдельным вызовом отрисовки, как только попадал во фрустум, — а фрустум
	# не знает про стены. С въезда в СНТ, где между камерой и околицей стоит
	# борт высотой 3.2 м, кадр честно рисовал всю околицу насквозь: 851 вызов
	# при бюджете 450. Отсечения по перекрытию в Compatibility нет, и спорить
	# с этим нечем — зато туман кончается на 32 м (site.json FOG.far), и всё,
	# что дальше, не видно и так.
	var casts: bool = SHADOW_PROPS.has(String(def.get("id", "")))
	for mi: MeshInstance3D in _all_meshes(holder):
		if not casts:
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.visibility_range_end = VIS_END
		mi.visibility_range_end_margin = VIS_FADE
		mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED

	if root != null:
		root.add_child(holder)
	if def.has("id"):
		by_id[def["id"]] = holder
		notes[def["id"]] = {"def": def, "pos": Vector3(ax, ay, az)}

	if def.get("col", null) is bool and def["col"] == false:
		return holder

	# Мировой AABB: каждый элемент через свою матрицу и матрицу holder'а.
	var world := _world_aabb(elems, ax, ay, az, rx, ry, rz)
	var cx := (world[0] + world[3]) * 0.5
	var cz := (world[2] + world[5]) * 0.5
	var w := 0.0
	var h := 0.0
	var d := 0.0
	var cy := 0.0
	var spin := true
	var col_def: Variant = def.get("col", null)
	if col_def is Array:
		w = float(col_def[0])
		h = float(col_def[1])
		d = float(col_def[2])
		cy = ay + h / 2.0
	else:
		w = world[3] - world[0]
		h = world[4] - world[1]
		d = world[5] - world[2]
		cy = (world[1] + world[4]) * 0.5
		spin = false
		# Коврики и бумажки не мешают.
		if w * d < 0.02 or h < 0.14:
			return holder
	colliders.append({
		"cx": cx, "cy": cy, "cz": cz,
		"hx": maxf(0.12, w) / 2.0, "hy": maxf(0.12, h) / 2.0, "hz": maxf(0.12, d) / 2.0,
		"yaw": ry if spin else 0.0,
	})
	return holder


func rebuild_collision(col: CollisionWorld) -> void:
	col.clear_set(CollisionWorld.SET_PROPS)
	for c: Dictionary in colliders:
		var yaw: float = c["yaw"]
		if yaw == 0.0:
			col.add_box_d(CollisionWorld.SET_PROPS,
				c["cx"] - c["hx"], c["cy"] - c["hy"], c["cz"] - c["hz"],
				c["cx"] + c["hx"], c["cy"] + c["hy"], c["cz"] + c["hz"])
		else:
			col.add_rot_box_d(CollisionWorld.SET_PROPS, c["cx"], c["cy"], c["cz"],
				c["hx"], c["hy"], c["hz"], CollisionWorld.AXIS_Y, yaw)


# ---------- геометрия деталей ----------

# Порядок эйлеров three по умолчанию XYZ: R = Rx * Ry * Rz.
static func _euler_xyz(rx: float, ry: float, rz: float) -> Basis:
	var b := Basis()
	if rz != 0.0:
		b = Basis(Vector3(0, 0, 1), rz)
	if ry != 0.0:
		b = Basis(Vector3(0, 1, 0), ry) * b
	if rx != 0.0:
		b = Basis(Vector3(1, 0, 0), rx) * b
	return b


static func _euler_matrix(rx: float, ry: float, rz: float) -> PackedFloat64Array:
	var a := cos(rx)
	var b := sin(rx)
	var c := cos(ry)
	var d := sin(ry)
	var e := cos(rz)
	var f := sin(rz)
	var ae := a * e
	var af := a * f
	var be := b * e
	var bf := b * f
	return PackedFloat64Array([
		c * e, -c * f, d,
		af + be * d, ae - bf * d, -b * c,
		bf - ae * d, be + af * d, a * c,
	])


# Элементы габарита сборной детали: по одному на меш, как в three. У InstancedMesh
# габарит считается по экземплярам, а сам он в габарит группы входит одной коробкой.
func _parts_elements(parts: Array) -> Array:
	var out: Array = []
	for p: Dictionary in parts:
		var la: PackedFloat64Array = _part_local_aabb(p)
		var sx: float = p.get("sx", 1.0)
		var sy: float = p.get("sy", 1.0)
		var sz: float = p.get("sz", 1.0)
		var inst: Array = p.get("inst", [])
		if inst.is_empty():
			var m := _euler_matrix(p.get("rx", 0.0), p.get("ry", 0.0), p.get("rz", 0.0))
			out.append(PackedFloat64Array([
				la[0] * sx, la[1] * sy, la[2] * sz, la[3] * sx, la[4] * sy, la[5] * sz,
				m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8],
				p["x"], p["y"], p["z"],
			]))
			continue
		var lo := PackedFloat64Array([INF, INF, INF, -INF, -INF, -INF])
		for t: Dictionary in inst:
			var im := _euler_matrix(t.get("rx", 0.0), t.get("ry", 0.0), t.get("rz", 0.0))
			for i in 8:
				var px: float = la[0] if (i & 1) == 0 else la[3]
				var py: float = la[1] if (i & 2) == 0 else la[4]
				var pz: float = la[2] if (i & 4) == 0 else la[5]
				var wx: float = im[0] * px + im[1] * py + im[2] * pz + t["x"]
				var wy: float = im[3] * px + im[4] * py + im[5] * pz + t["y"]
				var wz: float = im[6] * px + im[7] * py + im[8] * pz + t["z"]
				lo[0] = minf(lo[0], wx); lo[3] = maxf(lo[3], wx)
				lo[1] = minf(lo[1], wy); lo[4] = maxf(lo[4], wy)
				lo[2] = minf(lo[2], wz); lo[5] = maxf(lo[5], wz)
		out.append(PackedFloat64Array([
			lo[0], lo[1], lo[2], lo[3], lo[4], lo[5],
			1.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0, 0.0, 1.0,
			p["x"], p["y"], p["z"],
		]))
	return out


# Локальный AABB примитива — по формулам генераторов three, а не по мешу Godot:
# у цилиндра с нечётным числом сегментов габарит несимметричен, и это видно
# в координате коллайдера.
func _part_local_aabb(p: Dictionary) -> PackedFloat64Array:
	var kind: String = p["kind"]
	match kind:
		"box":
			var w: float = p["w"] * 0.5
			var h: float = p["h"] * 0.5
			var d: float = p["d"] * 0.5
			return PackedFloat64Array([-w, -h, -d, w, h, d])
		"cyl":
			var r: float = p["r"]
			var hh: float = p["h"] * 0.5
			var seg: int = p["seg"]
			var smin := 0.0
			var smax := 0.0
			var cmin := 0.0
			var cmax := 0.0
			for i in seg + 1:
				var th := TAU * i / float(seg)
				smin = minf(smin, sin(th)); smax = maxf(smax, sin(th))
				cmin = minf(cmin, cos(th)); cmax = maxf(cmax, cos(th))
			return PackedFloat64Array([r * smin, -hh, r * cmin, r * smax, hh, r * cmax])
		"ico":
			var k: float = p["r"] * 0.8506508083520399
			return PackedFloat64Array([-k, -k, -k, k, k, k])
		"sph":
			var r2: float = p["r"]
			return PackedFloat64Array([-r2, -r2, -r2, r2, r2, r2])
		"torus":
			var rad: float = p["r"]
			var tube: float = p["t"]
			var rs: int = p["rs"]
			var ts: int = p["ts"]
			var mn := PackedFloat64Array([INF, INF, INF])
			var mx := PackedFloat64Array([-INF, -INF, -INF])
			for i in rs + 1:
				for j in ts + 1:
					var ia := TAU * i / float(rs)
					var ja := TAU * j / float(ts)
					var vx := (rad + tube * cos(ia)) * cos(ja)
					var vy := (rad + tube * cos(ia)) * sin(ja)
					var vz := tube * sin(ia)
					mn[0] = minf(mn[0], vx); mx[0] = maxf(mx[0], vx)
					mn[1] = minf(mn[1], vy); mx[1] = maxf(mx[1], vy)
					mn[2] = minf(mn[2], vz); mx[2] = maxf(mx[2], vz)
			return PackedFloat64Array([mn[0], mn[1], mn[2], mx[0], mx[1], mx[2]])
		"plane":
			var pw: float = p["w"] * 0.5
			var ph: float = p["h"] * 0.5
			return PackedFloat64Array([-pw, -ph, 0.0, pw, ph, 0.0])
	return PackedFloat64Array([0, 0, 0, 0, 0, 0])


func _parts_to_nodes(parts: Array, holder: Node3D) -> void:
	for p: Dictionary in parts:
		var mesh := _part_mesh(p)
		if mesh == null:
			continue
		var inst: Array = p.get("inst", [])
		if inst.is_empty():
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = p["mat"]
			mi.position = Vector3(p["x"], p["y"], p["z"])
			mi.basis = _euler_xyz(p.get("rx", 0.0), p.get("ry", 0.0), p.get("rz", 0.0)) \
				.scaled(Vector3(p.get("sx", 1.0), p.get("sy", 1.0), p.get("sz", 1.0)))
			if p.has("name"):
				mi.name = p["name"]
				mi.set_meta("independent_visual", true)
				if String(p["name"]).begins_with("wheel-"):
					mi.set_meta("rest_basis", mi.basis)
			if p.has("pivot"):
				var pivot := Node3D.new()
				pivot.name = String(p["name"])
				pivot.position = p["pivot"]
				mi.name = "panel"
				mi.position -= pivot.position
				pivot.add_child(mi)
				holder.add_child(pivot)
			else:
				holder.add_child(mi)
			continue
		# Полтораста банок и поленница — один MultiMesh, а не полтораста нод.
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = mesh
		mm.instance_count = inst.size()
		for i in inst.size():
			var t: Dictionary = inst[i]
			var xf := Transform3D(_euler_xyz(t.get("rx", 0.0), t.get("ry", 0.0), t.get("rz", 0.0)),
				Vector3(t["x"], t["y"], t["z"]))
			mm.set_instance_transform(i, xf)
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		mmi.material_override = p["mat"]
		mmi.position = Vector3(p["x"], p["y"], p["z"])
		holder.add_child(mmi)
	_merge_static_parts(holder)


func _part_mesh(p: Dictionary) -> Mesh:
	if p.get("visual_cabin", false):
		return ObjectGeometry.cabin(Vector3(p["w"], p["h"], p["d"]))
	match String(p["kind"]):
		"box":
			var size := Vector3(p["w"], p["h"], p["d"])
			if minf(size.x, minf(size.y, size.z)) >= 0.04:
				return ObjectGeometry.bevel_box(size, minf(0.018, minf(size.x, size.z) * 0.08))
			var bm := BoxMesh.new()
			bm.size = size
			return bm
		"cyl":
			var cm := CylinderMesh.new()
			cm.top_radius = p["r"]
			cm.bottom_radius = p.get("r2", p["r"])
			cm.height = p["h"]
			cm.radial_segments = maxi(3, int(p["seg"]))
			cm.rings = 1
			return cm
		"ico":
			var im := SphereMesh.new()
			im.radius = p["r"]
			im.height = p["r"] * 2.0
			im.radial_segments = 6
			im.rings = 3
			return im
		"sph":
			var sm := SphereMesh.new()
			sm.radius = p["r"]
			sm.height = p["r"] * 2.0
			sm.radial_segments = int(p.get("seg", 8))
			sm.rings = int(p.get("rings", 5))
			return sm
		"torus":
			var tm := TorusMesh.new()
			tm.inner_radius = p["r"] - p["t"]
			tm.outer_radius = p["r"] + p["t"]
			tm.rings = int(p["ts"])
			tm.ring_segments = int(p["rs"])
			return tm
		"plane":
			var qm := QuadMesh.new()
			qm.size = Vector2(p["w"], p["h"])
			return qm
	return null


# box(w,h,d,mat,x,y,z) оригинала: деталь стоит НА отметке y, отсюда +h/2.
func _box(w: float, h: float, d: float, mat: Material, x := 0.0, y := 0.0, z := 0.0) -> Dictionary:
	return {"kind": "box", "w": w, "h": h, "d": d, "mat": mat, "x": x, "y": y + h / 2.0, "z": z}


func _cyl(r: float, h: float, mat: Material, x := 0.0, y := 0.0, z := 0.0, seg := 8) -> Dictionary:
	return {"kind": "cyl", "r": r, "h": h, "seg": seg, "mat": mat, "x": x, "y": y + h / 2.0, "z": z}


# ---------- детерминированный ГПСЧ ----------

# Одна и та же куча после перезагрузки: Math.random() здесь нельзя — игрок
# проходит участок по десять раз, и хлам, каждый раз лежащий иначе, читается
# как подмена сцены. mulberry32 с той же арифметикой, что в JS (32 бита).
class Rng extends RefCounted:
	var s := 0

	func _init(key: String) -> void:
		var acc := 0
		for i in key.length():
			acc = (acc + key.unicode_at(i) * (i + 1)) & 0xFFFFFFFF
		s = acc

	static func imul(a: int, b: int) -> int:
		var al := a & 0xFFFF
		var ah := (a >> 16) & 0xFFFF
		return ((al * b) + (((ah * b) & 0xFFFF) << 16)) & 0xFFFFFFFF

	func next() -> float:
		s = (s + 0x6d2b79f5) & 0xFFFFFFFF
		var t := s
		t = imul(t ^ (t >> 15), t | 1)
		t = (t ^ (t + imul(t ^ (t >> 7), t | 61))) & 0xFFFFFFFF
		return float((t ^ (t >> 14)) & 0xFFFFFFFF) / 4294967296.0


# ---------- сборщики ----------

func _make(name: String, def: Dictionary) -> Array:
	var M := mats
	match name:
		"vm12":
			var body := M.flat(0x9aa0a4)
			var dark := M.flat(0x2c2f31)
			var out: Array = [_box(0.44, 0.10, 0.34, body)]
			out.append(_box(0.26, 0.022, 0.02, dark, 0, 0.062, -0.17))
			var led := _box(0.09, 0.028, 0.015, M.glow(0x3a4a2c), 0.15, 0.055, -0.172)
			led["name"] = "led"
			out.append(led)
			for i in 5:
				out.append(_box(0.028, 0.016, 0.012, dark, -0.16 + i * 0.04, 0.028, -0.173))
			out.append(_box(0.40, 0.008, 0.30, dark, 0, -0.008, 0))
			return out
		"tvHorizon":
			var wood := M.flat(0x6b4b30)
			var dark2 := M.flat(0x1b1e20)
			var out2: Array = [_box(0.62, 0.50, 0.46, wood)]
			var screen := _box(0.44, 0.34, 0.02, M.flat(0x23282b, true), 0, 0.08, -0.235)
			screen["name"] = "screen"
			out2.append(screen)
			for i in 3:
				out2.append(_cyl(0.022, 0.02, dark2, 0.255, 0.32 - i * 0.07, -0.23, 6))
			out2.append(_box(0.58, 0.03, 0.40, dark2, 0, -0.03, 0))
			for f: Array in [[-0.24, -0.16], [0.24, -0.16], [-0.24, 0.16], [0.24, 0.16]]:
				out2.append(_cyl(0.018, 0.10, dark2, f[0], -0.13, f[1], 5))
			for p: Dictionary in out2:
				p["y"] = p["y"] + 0.13
			return out2
		"tvYunost":
			var body3 := M.flat(0x54585a)
			var out3: Array = [_box(0.34, 0.28, 0.28, body3)]
			var scr := _box(0.24, 0.18, 0.02, M.flat(0x1e2224, true), 0, 0.05, -0.145)
			scr["name"] = "screen"
			out3.append(scr)
			var ant := M.flat(0x9aa0a4)
			var a1 := _cyl(0.006, 0.42, ant, -0.06, 0.28, 0.05, 4)
			a1["rz"] = 0.5
			var a2 := _cyl(0.006, 0.42, ant, 0.06, 0.28, 0.05, 4)
			a2["rz"] = -0.5
			out3.append(a1)
			out3.append(a2)
			return out3
		"wallUnit":
			# Число секций — параметр: трёхсекционная не влезает в простенок 2.40 м.
			var wood4 := M.flat(0x6d4c31)
			var dark4 := M.flat(0x3a2a1c)
			var n4 := int(def.get("sections", 3))
			var out4: Array = []
			for i in n4:
				var x := (i - (n4 - 1) / 2.0) * 0.9
				out4.append(_box(0.86, 1.90, 0.44, wood4, x, 0, 0))
				out4.append(_box(0.80, 0.02, 0.40, dark4, x, 0.92, 0))
				out4.append(_box(0.80, 0.02, 0.40, dark4, x, 1.34, 0))
				if n4 < 3 or i != int(floor(n4 / 2.0)):
					out4.append(_box(0.80, 0.86, 0.02, M.get_mat("glass"), x, 0.98, -0.215))
				out4.append(_box(0.80, 0.60, 0.02, wood4, x, 0.14, -0.22))
				out4.append(_cyl(0.016, 0.05, M.flat(0x8b9095), x + 0.3, 0.44, -0.24, 6))
			return out4
		"gasStove":
			var white := M.flat(0xb3ada0)
			var dark5 := M.flat(0x33383a)
			var out5: Array = [_box(0.56, 0.85, 0.55, white), _box(0.54, 0.03, 0.52, dark5, 0, 0.85, 0)]
			for f: Array in [[-0.13, -0.12], [0.13, -0.12], [-0.13, 0.13], [0.13, 0.13]]:
				out5.append(_cyl(0.055, 0.02, M.flat(0x4a4f52), f[0], 0.87, f[1], 7))
			out5.append(_box(0.44, 0.30, 0.02, dark5, 0, 0.28, -0.28))
			for i in 4:
				out5.append(_cyl(0.022, 0.03, dark5, -0.21 + i * 0.14, 0.70, -0.29, 6))
			out5.append(_cyl(0.15, 0.62, M.flat(0x8c5a3a), 0.46, 0, 0.05, 8))
			out5.append(_cyl(0.03, 0.09, M.flat(0x8b9095), 0.46, 0.62, 0.05, 6))
			return out5
		"fridgeBiryusa":
			var white6 := M.flat(0xbdb7a8)
			return [
				_box(0.58, 1.45, 0.60, white6),
				_box(0.56, 0.02, 0.02, M.flat(0x8b9095), 0, 1.02, -0.30),
				_box(0.04, 0.34, 0.03, M.flat(0x8b9095), 0.22, 0.62, -0.31),
				_box(0.04, 0.20, 0.03, M.flat(0x8b9095), 0.22, 1.16, -0.31),
				_box(0.54, 0.02, 0.56, M.flat(0x6b6558), 0, -0.02, 0),
			]
		"wallRug":
			var w7 := float(def.get("w", 2.0))
			var h7 := float(def.get("h", 1.5))
			return [
				_box(w7, h7, 0.035, M.get_mat("carpet"), 0, -h7 / 2.0, 0),
				_box(w7 + 0.04, 0.04, 0.045, M.flat(0x53372c), 0, -0.02, 0),
			]
		"doghouse":
			var wood8 := M.get_mat("shedwood")
			var out8: Array = [
				_box(0.86, 0.70, 0.96, wood8),
				_box(0.36, 0.44, 0.04, M.flat(0x14100c), 0, 0.06, -0.50),
			]
			var r1 := _box(0.52, 0.05, 1.02, M.get_mat("roof"), -0.22, 0.70, 0)
			r1["rz"] = 0.5
			var r2 := _box(0.52, 0.05, 1.02, M.get_mat("roof"), 0.22, 0.70, 0)
			r2["rz"] = -0.5
			out8.append(r1)
			out8.append(r2)
			out8.append(_cyl(0.13, 0.07, M.flat(0x7c4a35), 0.75, 0, 0.30, 9))
			out8.append(_cyl(0.115, 0.012, M.flat(0x2c3a40), 0.75, 0.055, 0.30, 9))
			for i in 14:
				var a := i / 14.0 * TAU
				out8.append(_cyl(0.018, 0.03, M.flat(0x6b7075),
					0.66 + cos(a) * 0.19, 0.01, -0.15 + sin(a) * 0.19, 5))
			return out8
		"jarShelf":
			# Один цвет банок на полку: третий материал утроил бы её draw calls.
			var rows := int(def.get("rows", 3))
			var per := int(def.get("per", 9))
			var wood9 := M.get_mat("boards")
			var len9 := per * 0.17 + 0.12
			var out9: Array = []
			for r in rows:
				out9.append(_box(len9, 0.04, 0.34, wood9, 0, r * 0.52, 0))
			out9.append(_box(0.06, rows * 0.52 + 0.04, 0.34, wood9, -len9 / 2.0, 0, 0))
			out9.append(_box(0.06, rows * 0.52 + 0.04, 0.34, wood9, len9 / 2.0, 0, 0))
			var fill := 0x6a2b33 if String(def.get("fill", "")) == "berry" else 0x87764f
			var jars: Array = []
			var lids: Array = []
			for r in rows:
				for i in per:
					var jx := -len9 / 2.0 + 0.14 + i * 0.17
					var jy := r * 0.52 + 0.135
					var jz := (i % 2) * 0.06 - 0.03
					jars.append({"x": jx, "y": jy, "z": jz})
					lids.append({"x": jx, "y": jy + 0.10, "z": jz})
			out9.append({"kind": "cyl", "r": 0.055, "r2": 0.05, "h": 0.19, "seg": 7,
				"mat": M.flat(fill), "x": 0.0, "y": 0.0, "z": 0.0, "inst": jars})
			out9.append({"kind": "cyl", "r": 0.056, "h": 0.014, "seg": 7,
				"mat": M.flat(0x9aa0a4), "x": 0.0, "y": 0.0, "z": 0.0, "inst": lids})
			return out9
		"washstand":
			var out10: Array = [
				_box(0.36, 0.42, 0.24, M.flat(0x9aa0a4), 0, 1.05, 0),
				_cyl(0.018, 0.09, M.flat(0x8b9095), 0, 0.98, 0.03, 6),
				_cyl(0.16, 0.28, M.flat(0x7d8489), 0, 0.0, 0.02, 9),
				_box(0.34, 0.46, 0.03, M.flat(0x9fb0b6), 0, 1.52, 0.11),
				_box(0.40, 0.03, 0.16, M.get_mat("boards"), 0, 1.47, 0.02),
				_cyl(0.045, 0.10, M.flat(0xa8a293), 0.13, 1.50, 0.02, 7),
			]
			var tones10 := [0x3f6f8a, 0x8a3f4f, 0x6f8a3f]
			for i in 3:
				var b10 := _cyl(0.008, 0.17, M.flat(tones10[i]), 0.11 + i * 0.02, 1.54, 0.02, 4)
				b10["rz"] = (i - 1) * 0.16
				out10.append(b10)
			return out10
		"tinBox":
			return [
				_cyl(0.055, 0.13, M.flat(0x9c6a3a), 0, 0, 0, 9),
				_cyl(0.058, 0.016, M.flat(0x7d5228), 0, 0.13, 0, 9),
			]
		"stepladder":
			var wood11 := M.get_mat("boards")
			var out11: Array = []
			for s in [-1.0, 1.0]:
				var leg := _box(0.05, 1.75, 0.05, wood11, s * 0.22, 0, s * 0.12)
				leg["rx"] = -s * 0.13
				out11.append(leg)
			for i in 5:
				out11.append(_box(0.50, 0.035, 0.10, wood11, 0, 0.22 + i * 0.30, -0.10 + i * 0.03))
			return out11
		"rotaryPhone":
			var body12 := M.flat(0x2f3335)
			var out12: Array = [
				_box(0.22, 0.09, 0.20, body12),
				_cyl(0.075, 0.02, M.flat(0xb9b3a4), 0, 0.09, 0.01, 12),
			]
			for i in 10:
				var a12 := i / 10.0 * TAU
				out12.append(_cyl(0.011, 0.006, M.flat(0x1d2022),
					cos(a12) * 0.052, 0.108, 0.01 + sin(a12) * 0.052, 6))
			out12.append(_box(0.20, 0.05, 0.06, body12, 0, 0.10, -0.10))
			out12.append(_box(0.05, 0.04, 0.06, body12, -0.09, 0.13, -0.10))
			out12.append(_box(0.05, 0.04, 0.06, body12, 0.09, 0.13, -0.10))
			return out12
		"fusebox":
			var out13: Array = [
				_box(0.30, 0.40, 0.13, M.flat(0x8d8676)),
				_box(0.26, 0.34, 0.02, M.flat(0x2f3335), 0, 0.03, -0.07),
			]
			var n13 := int(def.get("plugs", 2))
			for i in n13:
				out13.append(_cyl(0.032, 0.05, M.flat(0x9c6a3a), -0.06 + i * 0.12, 0.26, -0.085, 8))
			out13.append(_box(0.16, 0.12, 0.02, M.glow(0x8fa8b4, 0.7), 0, 0.05, -0.075))
			return out13
		"wallClock":
			var out14: Array = [
				_box(0.24, 0.46, 0.12, M.flat(0x5d4028)),
				_cyl(0.09, 0.02, M.flat(0xd8d2c0), 0, 0.34, -0.062, 12),
				_box(0.012, 0.07, 0.01, M.flat(0x22242a), 0, 0.35, -0.075),
			]
			var pend := _box(0.05, 0.05, 0.01, M.flat(0xb59a48), 0, 0.08, -0.062)
			pend["name"] = "pendulum"
			out14.append(pend)
			return out14
		"wardrobe":
			var w15 := float(def.get("w", 1.05))
			var wood15 := M.flat(int(def.get("tone", 0x6a4a30)))
			return [
				_box(w15, 1.95, 0.58, wood15),
				_box(w15 / 2.0 - 0.02, 1.86, 0.02, M.flat(0x54381f), -w15 / 4.0, 0.05, -0.30),
				_box(w15 / 2.0 - 0.02, 1.86, 0.02, M.flat(0x54381f), w15 / 4.0, 0.05, -0.30),
				_cyl(0.014, 0.10, M.flat(0x8b9095), -0.04, 1.05, -0.31, 6),
				_cyl(0.014, 0.10, M.flat(0x8b9095), 0.04, 1.05, -0.31, 6),
			]
		"trunk":
			var out16: Array = [_box(0.92, 0.50, 0.52, M.flat(0x6d4c31))]
			# Крышка — полуцилиндр лёжа; габарит тот же, что у полного.
			var lid := {"kind": "cyl", "r": 0.26, "h": 0.92, "seg": 10,
				"mat": M.flat(0x5b3f28), "x": 0.0, "y": 0.50, "z": 0.0, "rz": PI / 2.0}
			out16.append(lid)
			for x in [-0.30, 0.30]:
				out16.append(_box(0.05, 0.54, 0.54, M.flat(0x7d8489), x, 0, 0))
			return out16
		"sewingMachine":
			return [
				_box(0.86, 0.72, 0.44, M.flat(0x5b3f28)),
				_box(0.44, 0.10, 0.18, M.flat(0x24272a), 0, 0.72, 0),
				_box(0.10, 0.22, 0.16, M.flat(0x24272a), -0.15, 0.82, 0),
				_cyl(0.07, 0.02, M.flat(0x8b9095), 0.18, 0.83, 0, 9),
			]
		"zhiguli":
			var paint := M.flat(0x4a5f52)
			var dark18 := M.flat(0x1a1c1e)
			var glass18 := M.get_mat("glass")
			var out18: Array = [
				_box(1.62, 0.62, 4.05, paint, 0, 0.42, 0),
				_box(1.52, 0.52, 2.10, paint, 0, 1.02, 0.10),
				_box(1.44, 0.40, 0.03, glass18, 0, 1.10, -0.94),
				_box(1.44, 0.36, 0.03, glass18, 0, 1.10, 1.16),
				_box(0.03, 0.34, 1.90, glass18, -0.75, 1.12, 0.12),
				_box(0.03, 0.34, 1.90, glass18, 0.75, 1.12, 0.12),
				_box(1.58, 0.14, 0.10, dark18, 0, 0.36, -2.02),
				_box(1.58, 0.14, 0.10, dark18, 0, 0.36, 2.02),
			]
			for f: Array in [[-0.72, -1.32], [0.72, -1.32], [-0.72, 1.36], [0.72, 1.36]]:
				var wheel := {"kind": "cyl", "r": 0.31, "h": 0.19, "seg": 10, "mat": dark18,
					"x": f[0], "y": 0.31, "z": f[1], "rz": PI / 2.0}
				out18.append(wheel)
			for x in [-0.55, 0.55]:
				out18.append(_box(0.26, 0.14, 0.04, M.glow(0xd8d2b8, 0.9), x, 0.62, -2.03))
				out18.append(_box(0.24, 0.12, 0.04, M.flat(0x8a3a30), x, 0.60, 2.03))
			return out18
		"summerShower":
			var wood19 := M.get_mat("shedwood")
			var out19: Array = []
			for f: Array in [[-0.5, -0.5], [0.5, -0.5], [-0.5, 0.5], [0.5, 0.5]]:
				out19.append(_box(0.08, 2.10, 0.08, wood19, f[0], 0, f[1]))
			out19.append(_box(1.10, 1.60, 0.05, wood19, 0, 0.20, 0.52))
			out19.append(_box(0.05, 1.60, 1.10, wood19, -0.52, 0.20, 0))
			out19.append(_box(0.05, 1.60, 1.10, wood19, 0.52, 0.20, 0))
			out19.append(_box(1.16, 0.30, 1.16, M.flat(0x3d4b52), 0, 2.10, 0))
			return out19
		"waterBarrel":
			return [
				_cyl(0.34, 0.86, M.flat(0x4d5a52), 0, 0, 0, 12),
				_cyl(0.345, 0.04, M.flat(0x6f767c), 0, 0.20, 0, 12),
				_cyl(0.345, 0.04, M.flat(0x6f767c), 0, 0.62, 0, 12),
				_cyl(0.31, 0.02, M.flat(0x22303a), 0, 0.80, 0, 12),
			]
		"woodpile":
			var len21 := float(def.get("len", 3.0))
			var rows21 := 6
			var per21 := int(floor(len21 / 0.13))
			var inst21: Array = []
			for r in rows21:
				for i in per21:
					inst21.append({
						"x": -len21 / 2.0 + 0.07 + i * 0.13,
						"y": 0.06 + r * 0.115,
						"z": ((r + i) % 2) * 0.02,
						"rz": PI / 2.0,
					})
			return [{"kind": "cyl", "r": 0.06, "r2": 0.055, "h": 0.36, "seg": 6,
				"mat": M.flat(0x7a6142), "x": 0.0, "y": 0.0, "z": 0.0, "inst": inst21}]
		"applePile":
			var n22 := int(def.get("count", 26))
			var r22 := float(def.get("r", 0.45))
			var rnd22 := Rng.new(String(def.get("id", def.get("make", "applePile"))))
			# One basket is one draw call.  The holder and its id stay exactly where
			# they were, so dynamic visibility and interactions still address the
			# same node; only the apples below it are instanced together.
			var heap: Array = []
			for i in n22:
				var a22 := rnd22.next() * TAU
				var d22 := r22 * sqrt(rnd22.next())
				var px := cos(a22) * d22
				var py := 0.03 + rnd22.next() * 0.07
				var pz := sin(a22) * d22
				var ex := rnd22.next() * 6.283
				var ey := rnd22.next() * 6.283
				var ez := rnd22.next() * 6.283
				var t22 := {"x": px, "y": py, "z": pz, "rx": ex, "ry": ey, "rz": ez}
				heap.append(t22)
			return [{"kind": "ico", "r": 0.035, "mat": M.flat(0x76513b),
				"x": 0.0, "y": 0.0, "z": 0.0, "inst": heap}]
		"junkPile":
			# Раскладка от зерна: после перезагрузки куча ляжет так же.
			var h23 := float(def.get("h", 0.6))
			var r23 := float(def.get("r", 0.5))
			var rnd23 := Rng.new(String(def.get("id", def.get("make", "junkPile"))))
			var tones23 := [0x6d4c31, 0x8a6a45, 0x5d4530, 0x7f7663, 0x6f767c]
			var n23 := 8 + int(floor(rnd23.next() * 5))
			var out23: Array = []
			for i in n23:
				var t23 := float(i) / n23
				var a23 := rnd23.next() * TAU
				var d23 := r23 * (1.0 - t23 * 0.7) * (0.2 + 0.8 * rnd23.next())
				var x23 := cos(a23) * d23
				var z23 := sin(a23) * d23
				var y23 := t23 * (h23 - 0.14)
				var mat23 := M.flat(tones23[int(rnd23.next() * tones23.size())])
				var kind23 := rnd23.next()
				var piece: Dictionary
				if kind23 < 0.45:
					piece = _box(0.16 + rnd23.next() * 0.24, 0.09 + rnd23.next() * 0.13,
						0.13 + rnd23.next() * 0.22, mat23, x23, y23, z23)
				elif kind23 < 0.75:
					piece = _box(0.10 + rnd23.next() * 0.06, 0.03,
						0.7 + rnd23.next() * 0.5, mat23, x23, y23, z23)
				else:
					piece = _cyl(0.05 + rnd23.next() * 0.06, 0.10 + rnd23.next() * 0.16,
						mat23, x23, y23, z23, 8)
				piece["ry"] = rnd23.next() * PI
				piece["rz"] = (rnd23.next() - 0.5) * 0.4
				out23.append(piece)
			var bucket := _cyl(0.14, 0.30, M.flat(0x6f767c), -r23 * 0.6, 0, r23 * 0.4, 10)
			bucket["rz"] = PI / 2.0
			out23.append(bucket)
			return out23
		"gardenBed":
			var w24 := float(def.get("w", 1.1))
			var l24 := float(def.get("len", 4.0))
			var out24: Array = [
				# The explicit collider in props.json remains 1.2 x 0.4 x 5.6.
				# These extra longitudinal boards only make that old solid read as a
				# deliberately raised bed instead of a dirt cuboid.
				_box(w24, 0.26, l24, M.get_mat("dirt")),
				_box(w24 + 0.06, 0.05, 0.06, M.get_mat("boards"), 0, 0.20, -l24 / 2.0),
				_box(w24 + 0.06, 0.05, 0.06, M.get_mat("boards"), 0, 0.20, l24 / 2.0),
				_box(0.06, 0.13, l24, M.get_mat("boards"), -w24 / 2.0, 0.13, 0),
				_box(0.06, 0.13, l24, M.get_mat("boards"), w24 / 2.0, 0.13, 0),
			]
			var n24 := int(floor(l24 / 0.55))
			for i in n24:
				var z24 := -l24 / 2.0 + 0.3 + i * 0.55
				out24.append(_cyl(0.012, 0.95, M.get_mat("boards"), 0, 0.22, z24, 4))
				out24.append({"kind": "ico", "r": 0.20, "mat": M.flat(0x4c6435),
					"x": 0.0, "y": 0.52, "z": z24, "sy": 1.5})
			return out24
		"workbench":
			var wood25 := M.get_mat("boards")
			var out25: Array = [_box(1.85, 0.09, 0.62, wood25, 0, 0.82, 0)]
			for f: Array in [[-0.82, -0.24], [0.82, -0.24], [-0.82, 0.24], [0.82, 0.24]]:
				out25.append(_box(0.08, 0.82, 0.08, wood25, f[0], 0, f[1]))
			out25.append(_box(1.70, 0.04, 0.40, wood25, 0, 0.28, 0))
			out25.append(_box(0.16, 0.14, 0.22, M.flat(0x5d6469), -0.70, 0.91, -0.16))
			return out25
		"calendar":
			var out26: Array = [
				_box(0.30, 0.42, 0.012, M.flat(0xc9c1a8)),
				_box(0.30, 0.09, 0.014, M.flat(0x8a4a3a), 0, 0.33, 0),
			]
			for r in 4:
				for c in 7:
					if r * 7 + c > 11:
						continue
					out26.append(_box(0.022, 0.022, 0.004, M.flat(0x36383c),
						-0.115 + c * 0.038, 0.24 - r * 0.06, -0.008))
			return out26
		"photoFrame":
			var w27 := float(def.get("w", 0.24))
			var h27 := float(def.get("h", 0.18))
			return [
				_box(w27, h27, 0.02, M.flat(0x5b3f28)),
				_box(w27 - 0.04, h27 - 0.04, 0.024, M.flat(int(def.get("tone", 0x9a9078))), 0, 0.02, -0.003),
			]
		"picture":
			var w28 := float(def.get("w", 0.5))
			var h28 := float(def.get("h", 0.4))
			var canvas := {"kind": "plane", "w": w28 - 0.05, "h": h28 - 0.05,
				"mat": M.picture(String(def.get("pic", ""))),
				"x": 0.0, "y": h28 / 2.0, "z": -0.018, "ry": PI}
			return [_box(w28, h28, 0.03, M.flat(int(def.get("frame", 0x5b3f28)))), canvas]
		"paper":
			var p29 := _box(float(def.get("w", 0.21)), 0.004, float(def.get("len", 0.28)),
				M.flat(0xc9c3ac))
			p29["ry"] = float(def.get("tilt", 0.12))
			return [p29]
		"tape":
			return [
				_box(0.188, 0.025, 0.104, M.flat(0x23262a)),
				_box(0.150, 0.004, 0.062, M.flat(int(def.get("label", 0xc7c0a6))), 0, 0.025, -0.012),
			]
		"bicycle":
			var frame := M.flat(0x6a3b34)
			var dark31 := M.flat(0x1d2022)
			var out31: Array = []
			for z in [-0.52, 0.52]:
				out31.append({"kind": "torus", "r": 0.32, "t": 0.028, "rs": 5, "ts": 12,
					"mat": dark31, "x": 0.0, "y": 0.32, "z": z, "ry": PI / 2.0})
			var bar := _cyl(0.018, 0.95, frame, 0, 0.55, 0, 5)
			bar["rx"] = PI / 2.0
			out31.append(bar)
			out31.append(_box(0.08, 0.05, 0.20, M.flat(0x2b2724), 0, 0.82, 0.28))
			out31.append(_cyl(0.016, 0.34, frame, 0, 0.55, 0.30, 5))
			var fork := _cyl(0.016, 0.52, frame, 0, 0.42, -0.46, 5)
			fork["rx"] = 0.2
			out31.append(fork)
			var hb := _cyl(0.014, 0.44, frame, 0, 0.92, -0.50, 5)
			hb["rz"] = PI / 2.0
			out31.append(hb)
			return out31
		"camcorder":
			return [
				_box(0.14, 0.13, 0.26, M.flat(0x2a2d30)),
				_cyl(0.045, 0.08, M.flat(0x1a1c1e), 0, 0.065, -0.16, 9),
				_box(0.10, 0.08, 0.10, M.flat(0x35383b), -0.09, 0.055, 0.02),
				_box(0.03, 0.02, 0.02, M.glow(0xc8503c), 0, 0.115, -0.10),
			]
		"flashlightProp":
			# Двадцать сантиметров в длину — это фонарь, а не термос.
			var body33 := {"kind": "cyl", "r": 0.024, "h": 0.17, "seg": 8,
				"mat": M.flat(0x4e5459), "x": 0.015, "y": 0.035, "z": 0.0, "rz": PI / 2.0}
			var head33 := {"kind": "cyl", "r": 0.035, "h": 0.05, "seg": 9,
				"mat": M.flat(0x6f767c), "x": -0.085, "y": 0.035, "z": 0.0, "rz": PI / 2.0}
			var lens33 := {"kind": "plane", "w": 0.064, "h": 0.064,
				"mat": M.glow(0xfff0cc, 0.9), "x": -0.111, "y": 0.035, "z": 0.0, "ry": -PI / 2.0}
			return [body33, head33, lens33]
		"carKeys":
			# Связка висит на отдельной доске дальней стены подпола. Красная
			# бирка крупнее самих ключей и первой ловит луч фонаря.
			var metal34 := M.flat(0x9aa0a4)
			var out34: Array = [
				_box(0.48, 0.42, 0.035, M.flat(0x5d472f)),
				_cyl(0.012, 0.085, M.flat(0x3a3f43), 0, 0.26, -0.045, 7),
				_box(0.018, 0.17, 0.018, metal34, -0.05, 0.10, -0.055),
				_box(0.018, 0.14, 0.018, metal34, 0.03, 0.12, -0.055),
				_box(0.065, 0.065, 0.014, metal34, -0.05, 0.25, -0.055),
				_box(0.060, 0.060, 0.014, metal34, 0.03, 0.25, -0.055),
				_box(0.16, 0.10, 0.012, M.flat(0xa23f35), 0.09, 0.09, -0.060),
			]
			return out34
		"growthMarks":
			# Последняя отметка — сегодняшним числом, чужой рукой.
			var ink := M.flat(0x3a352c)
			var marks := [1.18, 1.27, 1.35, 1.44, 1.52, 1.53]
			var out35: Array = []
			for i in marks.size():
				var mm35: Material = M.flat(0x2b2b30) if i == marks.size() - 1 else ink
				out35.append(_box(0.09, 0.008, 0.006, mm35, 0, marks[i], 0))
			return out35
		"hatchLid":
			var w35 := float(def.get("w", 0.9))
			var d35 := float(def.get("len", 0.95))
			return [
				_box(w35, 0.05, d35, M.get_mat("boards")),
				_cyl(0.045, 0.012, M.flat(0x7d8489), 0, 0.05, d35 / 2.0 - 0.14, 9),
			]
		"nailStack":
			var out36: Array = []
			for i in 9:
				var n36 := _cyl(0.004, 0.07, M.flat(0x8b9095), 0, i * 0.009, 0, 4)
				n36["rz"] = PI / 2.0
				n36["ry"] = i * 0.12
				out36.append(n36)
			return out36
		"boots":
			var out37: Array = []
			for x in [-0.09, 0.09]:
				out37.append(_box(0.11, 0.09, 0.28, M.flat(0x3a2f26), x, 0, 0))
				out37.append(_box(0.11, 0.13, 0.10, M.flat(0x33291f), x, 0.09, 0.08))
			return out37
		"nightstand":
			return [
				_box(0.44, 0.62, 0.38, M.flat(0x6a4a30)),
				_box(0.38, 0.02, 0.02, M.flat(0x8b9095), 0, 0.40, -0.19),
				_box(0.38, 0.02, 0.02, M.flat(0x8b9095), 0, 0.18, -0.19),
			]
		"neatMattress":
			# Застелен по-больничному, углы подоткнуты.
			return [
				_box(0.86, 0.16, 1.92, M.flat(0x7f7663)),
				_box(0.88, 0.03, 1.60, M.flat(0xa8a091), 0, 0.16, 0.12),
				_box(0.50, 0.10, 0.30, M.flat(0xb0a897), 0, 0.16, -0.78),
			]
		"gateNote":
			return [_box(0.22, 0.16, 0.008, M.flat(0xc5bfa6))]
	push_warning("нет сборщика: " + name)
	return []

# Коллизию уже рассчитали по исходной сборке. Декор принадлежит тому же
# владельцу, поэтому pickup, retry и сюжетная видимость работают вместе.
func _decorate_visuals(kind: String, parts: Array) -> void:
	var metal := mats.flat(0x7d8489)
	var dark := mats.flat(0x2c2f31)
	match kind:
		"summerShower":
			for part: Dictionary in parts:
				if part.get("kind","") != "box":
					continue
				if is_equal_approx(float(part.get("h",0.0)),2.10):
					part["y"] = 1.05
				elif is_equal_approx(float(part.get("h",0.0)),1.60):
					part["y"] = 1.02
			# Передняя створка и верхняя обвязка держат бак над стенками.
			parts.append(_box(0.86,1.70,0.045,mats.get_mat("shedwood"),0,1.0,-0.525))
			for z: float in [-0.52,0.52]:
				parts.append(_box(1.10,0.09,0.08,mats.get_mat("boards"),0,1.96,z))
			parts.append(_box(0.04,0.12,0.035,metal,0.32,1.04,-0.56))
		"vm12":
			for x in [-0.18, -0.10, -0.02, 0.06, 0.14]:
				parts.append(_box(0.035, 0.001, 0.12, dark, x, 0.10, 0.04))
			for x in [-0.20, 0.20]:
				parts.append(_box(0.009, 0.009, 0.003, metal, x, 0.075, -0.175))
		"tvHorizon", "tvYunost":
			for part: Dictionary in parts:
				if part["kind"] == "cyl" and absf(float(part.get("z", 0))) > 0.20:
					part["rx"] = PI / 2.0
			if kind == "tvHorizon":
				for row in 5:
					parts.append(_box(0.075, 0.005, 0.003, dark, 0.255, 0.15 + row * 0.018, -0.232))
		"gasStove":
			for part: Dictionary in parts:
				if part["kind"] == "cyl" and float(part.get("z", 0)) < -0.26:
					part["rx"] = PI / 2.0
			parts.append(_box(0.38, 0.020, 0.018, metal, 0, 0.59, -0.278))
			for x in [-0.13, 0.13]:
				parts.append(_box(0.012, 0.014, 0.42, dark, x, 0.874, 0.0))
			for z in [-0.12, 0.13]:
				parts.append(_box(0.44, 0.014, 0.012, dark, 0, 0.874, z))
		"fridgeBiryusa":
			parts.append(_box(0.48, 0.004, 0.008, dark, 0, 1.018, -0.300))
			for y in [0.25, 1.20]:
				parts.append(_box(0.014, 0.055, 0.010, metal, -0.274, y, -0.299))
		"rotaryPhone":
			parts.append(_box(0.030, 0.012, 0.021, dark, 0, 0.111, 0.01))
			for i in 5:
				var segment := _cyl(0.004, 0.023, dark, 0.095, 0.030 + i * 0.014, -0.030 + sin(i * 0.8) * 0.035, 5)
				segment["rx"] = PI / 2.0
				parts.append(segment)
		"wallClock":
			for part: Dictionary in parts:
				if part["kind"] == "cyl":
					part["rx"] = PI / 2.0
		"hatchLid":
			var base: Dictionary = parts[0]
			for x in [-float(base["w"]) * 0.33, float(base["w"]) * 0.33]:
				parts.append(_box(0.045, 0.004, 0.12, metal, x, 0.049, -float(base["d"]) * 0.42))
		"zhiguli":
			parts[0]["sx"] = 0.982
			parts[1]["visual_cabin"] = true
			parts[2]["rx"] = 0.516
			parts[2]["z"] = -0.801
			parts[2]["w"] = 1.35
			parts[3]["rx"] = -0.516
			parts[3]["z"] = 0.995
			parts[3]["w"] = 1.35
			for side in [4, 5]:
				parts[side]["d"] = 1.42
				parts[side]["x"] *= 0.952
				parts[side]["rz"] = -0.202 if side == 4 else 0.202
			var index := 0
			for part: Dictionary in parts:
				if part["kind"] == "cyl" and is_equal_approx(float(part["r"]), 0.31):
					part["name"] = "wheel-%d" % index
					index += 1
			for side in [-1.0, 1.0]:
				var x: float = side * 0.799
				for door in 2:
					var z := -0.39 if door == 0 else 0.59
					var panel := _box(0.008, 0.39, 0.89, parts[0]["mat"], x, 0.63, z)
					panel["name"] = "door-%s-%d" % ["left" if side < 0 else "right", door]
					panel["pivot"] = Vector3(x, 0.825, z - 0.445)
					parts.append(panel)
			for end in [-1.0, 1.0]:
				var lid := _box(1.55, 0.008, 0.82, parts[0]["mat"], 0, 1.037, end * 1.57)
				lid["name"] = "hood" if end < 0 else "trunk-lid"
				lid["pivot"] = Vector3(0, 1.041, end * 1.16)
				parts.append(lid)
			for x in [-0.805, 0.805]:
				for z in [-0.41, 0.57]:
					parts.append(_box(0.008, 0.022, 0.14, metal, x, 0.91, z))
				parts.append(_box(0.008, 0.33, 0.035, dark, x * 0.934, 1.12, 0.12))
				parts.append(_box(0.008, 0.45, 0.014, dark, x, 0.56, 0.12))
			parts.append(_box(0.58, 0.16, 0.012, dark, 0, 0.62, -2.029))
			for y in [0.65, 0.71, 0.77]:
				parts.append(_box(0.56, 0.008, 0.014, metal, 0, y, -2.030))
			parts.append(_box(0.36, 0.09, 0.015, mats.flat(0xbdb8a4), 0, 0.46, -2.040))


func _merge_static_parts(holder: Node3D) -> void:
	var groups: Dictionary = {}
	for child: Node in holder.get_children():
		if not child is MeshInstance3D or child.has_meta("independent_visual"):
			continue
		var mi := child as MeshInstance3D
		# Photos._canvas находит отдельный холст по типу меша.
		if mi.mesh is QuadMesh or mi.mesh is PlaneMesh:
			continue
		var mat := mi.material_override
		var key := mat.get_instance_id()
		if not groups.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[key] = {"st": st, "mat": mat}
		(groups[key]["st"] as SurfaceTool).append_from(mi.mesh, 0, mi.transform)
		holder.remove_child(mi)
		mi.free()
	for key: int in groups:
		var mi := MeshInstance3D.new()
		mi.name = "static-material-%d" % holder.get_child_count()
		mi.mesh = (groups[key]["st"] as SurfaceTool).commit()
		mi.material_override = groups[key]["mat"]
		holder.add_child(mi)


func update_car_wheels(car_node: Node3D, travel: float) -> void:
	if car_node == null:
		return
	for i in 4:
		var wheel := car_node.get_node_or_null("wheel-%d" % i) as Node3D
		if wheel != null:
			var rest: Basis = wheel.get_meta("rest_basis", Basis.IDENTITY)
			wheel.basis = rest * Basis(Vector3.UP, travel / 0.31)


func _baked_vegetation_visual(model_name: String, original: Node3D) -> Node3D:
	var keys := {
		"tree": "nat-pine-a", "tree-tall": "nat-pine-a", "tree-autumn": "nat-tree-a",
		"grass": "nat-grass", "patch-grass": "nat-grass", "grass-large": "nat-grass-tall",
	}
	if not keys.has(model_name):
		return original
	var asset := ProceduralAssets.fetch("scatter/" + String(keys[model_name]))
	if asset.is_empty():
		return original
	# Сохраняем старые anchor, опору и высоту. _cache.elems остаётся оригинальным
	# и только он задаёт коллизию; новые листья не добавляют препятствий.
	var target := original.transform * PropsSkin.local_aabb(original)
	var bounds: AABB = asset["bounds"]
	var uniform_scale := target.size.y / maxf(0.0001, bounds.size.y)
	var visual_scale := Vector3.ONE * uniform_scale
	var visual_position := Vector3(target.get_center().x, target.position.y - bounds.position.y * uniform_scale,
		target.get_center().z)
	if model_name in ["grass", "patch-grass", "grass-large"] and target.size.y <= 0.01:
		# Ground patches have an almost zero source height. Fit their original
		# footprint and keep the replacement blades below the player's knee.
		visual_scale.x = target.size.x / maxf(0.0001, bounds.size.x)
		visual_scale.z = target.size.z / maxf(0.0001, bounds.size.z)
		var blade_height := minf(0.38, bounds.size.y * minf(visual_scale.x,visual_scale.z))
		visual_scale.y = blade_height / maxf(0.0001,bounds.size.y)
		visual_position = Vector3(target.get_center().x - bounds.get_center().x * visual_scale.x,
			target.position.y - bounds.position.y * visual_scale.y,
			target.get_center().z - bounds.get_center().z * visual_scale.z)
	var visual := Node3D.new()
	visual.name = "procedural-" + model_name
	visual.scale = visual_scale
	visual.position = visual_position
	visual.set_meta("procedural_key", "scatter/" + String(keys[model_name]))
	for mesh: ArrayMesh in asset["meshes"]:
		if mesh.get_surface_count() == 0:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		visual.add_child(mi)
	original.free()
	return visual

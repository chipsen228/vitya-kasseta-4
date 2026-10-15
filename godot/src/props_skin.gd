# Скин-оверлей реквизита: подмена процедурной сборки готовой моделью.
#
# ЗАЧЕМ. Восемь самых заметных вещей на участке — «Шестёрка», ВМ-12, «Бирюса»,
# печка с баллоном, «стенка», телевизор, будка, сам дед — собраны из коробок
# и цилиндров (props.gd::_make): мебель Kenney их не покрывает, потому что это
# советские вещи, а не IKEA. Под PSX-фильтром коробки читаются терпимо, но
# «Шестёрка» во дворе — первое, что видно от ворот, и она читается коробкой.
#
# КАК УСТРОЕНО. Оверлей, а не замена: после props.build() процедурные дети
# прячутся, а на их место встаёт GLB, вписанный в ТОТ ЖЕ габарит, который уже
# посчитан в props.colliders. Массив коллайдеров не трогается ни разу — поэтому
# test_world_parity (83 коробки реквизита) остаётся зелёным по построению,
# а не по счастливой случайности.
#
# Материалы модели прогоняются через psx.gdshader — тот же приём, что и с
# мебелью Kenney (props.gd::_prepare). Без этого сгенерированная вещь висит
# фотореалистичным пятном среди низкополигональной мебели: она не снапится
# по вершинам, не получает аффинных UV и не тонет в общем тумане.
#
# ОТКАТ. Нет data/props_skin.json — apply() не делает ничего, и игра выглядит
# ровно как до фазы 7. Нет файла конкретной модели — пропускается только она.
# То же правило, по которому живут звук фаз 5–6 и переходы nav_links.
class_name PropsSkin
extends RefCounted

const PATH := "res://data/props_skin.json"
const MODEL_DIR := "res://assets/models/"
const PSX_SHADER := "res://shaders/psx.gdshader"

# id предмета -> {file, scale, yaw, lift, fit}
var map: Dictionary = {}
var applied: Array = []          # какие id реально подменены
var skipped: Dictionary = {}     # id -> почему пропущен

var _psx: Shader = null


static func load_all() -> PropsSkin:
	var s := PropsSkin.new()
	# Штатный профиль целиком процедурный. API архива оставлен для инструментов,
	# но наличие старого props_skin.json не включает внешние подмены само.
	return s


func _read() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	var raw: Variant = (parsed as Dictionary).get("SKIN", {})
	if not (raw is Dictionary):
		return
	for id: Variant in (raw as Dictionary):
		var d: Variant = (raw as Dictionary)[id]
		if not (d is Dictionary):
			continue
		var e: Dictionary = d
		map[String(id)] = {
			"file": String(e.get("file", "")),
			# Доводка на глаз поверх автоматической вписки: модель может быть
			# нарисована с полями или лежать боком.
			"scale": float(e.get("scale", 1.0)),
			"yaw": float(e.get("yaw", 0.0)),
			"lift": float(e.get("lift", 0.0)),
			# "box" — вписать в габарит целиком, "floor" — только по опоре
			# и ширине, высоту оставить свою (для вещей выше своей коробки).
			"fit": String(e.get("fit", "box")),
		}


## Надеть скины. Зовётся ОДИН раз, после props.build() и props.build_dynamic().
## Возвращает, сколько предметов подменено.
func apply(props: Props) -> int:
	if map.is_empty() or props == null:
		return 0
	_psx = load(PSX_SHADER) as Shader
	for id: String in map.keys():
		var e: Dictionary = map[id]
		var holder: Node3D = props.get_prop(id)
		if holder == null:
			skipped[id] = "нет такого предмета в PROPS"
			continue
		var path := MODEL_DIR + String(e["file"])
		if String(e["file"]) == "" or not ResourceLoader.exists(path):
			skipped[id] = "нет файла " + path
			continue
		var packed: PackedScene = load(path) as PackedScene
		if packed == null:
			skipped[id] = "не грузится " + path
			continue
		var box := local_aabb(holder)
		if box.size.length() < 1e-3:
			skipped[id] = "у процедурной сборки нулевой габарит"
			continue

		var model := packed.instantiate() as Node3D
		if model == null:
			skipped[id] = "в GLB нет Node3D"
			continue
		# Процедурные дети остаются в дереве, но невидимы: их габарит —
		# единственный источник правды о том, куда вписывать модель, и он
		# понадобится снова, если скин однажды снимут на ходу.
		for ch: Node in holder.get_children():
			if ch is GeometryInstance3D or ch is Node3D:
				(ch as Node3D).visible = false
		model.name = "skin"
		holder.add_child(model)
		_fit(model, box, e)
		_psx_materials(model)
		applied.append(id)
	return applied.size()


## Габарит видимых детей ноды в её собственных осях. Ровно тот же принцип,
## что у props.gd: объединяются мировые AABB мешей, а не вершины.
static func local_aabb(node: Node3D) -> AABB:
	var out := AABB()
	var first := true
	for mi: MeshInstance3D in _meshes(node):
		if mi.mesh == null:
			continue
		var b := mi.mesh.get_aabb()
		var xf := node.global_transform.affine_inverse() * mi.global_transform \
			if node.is_inside_tree() else _rel(node, mi)
		var world := xf * b
		if first:
			out = world
			first = false
		else:
			out = out.merge(world)
	return out


# Относительная матрица без дерева: тестам мир собирают вне SceneTree,
# и global_transform там врёт.
static func _rel(from: Node3D, to: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var n: Node = to
	while n != null and n != from:
		if n is Node3D:
			xf = (n as Node3D).transform * xf
		n = n.get_parent()
	return xf


static func _meshes(node: Node) -> Array:
	var out: Array = []
	if node is MeshInstance3D:
		out.append(node)
	for ch: Node in node.get_children():
		out.append_array(_meshes(ch))
	return out


# Вписка. Модель ставится по опоре (низ габарита), центруется по X/Z и
# масштабируется так, чтобы влезть целиком, не растягиваясь: коэффициент один
# на все три оси, иначе «Шестёрка» станет то плоской, то вытянутой.
func _fit(model: Node3D, box: AABB, e: Dictionary) -> void:
	model.rotation = Vector3(0.0, float(e["yaw"]), 0.0)
	var own := local_aabb(model)
	if own.size.x < 1e-4 or own.size.y < 1e-4 or own.size.z < 1e-4:
		return
	var k := minf(box.size.x / own.size.x, box.size.z / own.size.z)
	if String(e["fit"]) == "box":
		k = minf(k, box.size.y / own.size.y)
	k *= float(e["scale"])
	model.scale = Vector3(k, k, k)

	# Центр по горизонтали и опора по вертикали считаются уже с учётом
	# поворота и масштаба: own снят до них.
	var fitted := model.transform * own
	var target_c := box.get_center()
	model.position = Vector3(
		model.position.x + target_c.x - fitted.get_center().x,
		model.position.y + box.position.y - fitted.position.y + float(e["lift"]),
		model.position.z + target_c.z - fitted.get_center().z)


# Материалы модели -> psx.gdshader. Цвет и карта берутся у исходного материала,
# всё остальное (металличность, блики, нормали) выбрасывается: в игре нет
# ни одной поверхности, которая бы их показывала.
func _psx_materials(model: Node3D) -> void:
	for mi: MeshInstance3D in _meshes(model):
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		var mesh := mi.mesh
		if mesh == null:
			continue
		for i in mesh.get_surface_count():
			var src := mi.get_active_material(i)
			var m := ShaderMaterial.new()
			m.shader = _psx
			var col := Color(1, 1, 1)
			if src is BaseMaterial3D:
				var b := src as BaseMaterial3D
				col = b.albedo_color
				if b.albedo_texture != null:
					m.set_shader_parameter("albedo_tex", b.albedo_texture)
			m.set_shader_parameter("albedo", col)
			mi.set_surface_override_material(i, m)


func report() -> String:
	if map.is_empty():
		return "скинов нет (data/props_skin.json отсутствует)"
	var out := "скинов надето %d из %d" % [applied.size(), map.size()]
	for id: String in skipped.keys():
		out += "\n  пропущен %s: %s" % [id, skipped[id]]
	return out

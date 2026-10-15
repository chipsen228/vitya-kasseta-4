# Конвертер OBJ + PNG -> GLB (фаза 16). Разовый инструмент, не тест.
#
# ЗАЧЕМ. Пак советских машин с OpenGameArt (madmedicsoft, CC0) раздаётся в OBJ
# с отдельным альбедо-PNG, а весь конвейер порта работает с .glb: и
# props.gd::load_models, и scatter.gd::_pieces грузят MODEL_DIR + имя + ".glb".
# Blender на машине сборки не стоит, а тащить его ради девяти моделей по сотне
# треугольников — дороже, чем написать конвертер: у Godot свой экспортёр glTF
# (GLTFDocument), и он умеет ровно то, что нужно.
#
# ЧТО ДЕЛАЕТ. Читает OBJ руками (v / vt / vn / f, полигоны бьются веером),
# собирает ArrayMesh, вешает StandardMaterial3D с текстурой в режиме NEAREST
# (это пиксель-арт: билинейная фильтрация превращает его в мыло) и пишет GLB
# c встроенной текстурой.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/obj_to_glb.gd
extends SceneTree

const SRC := "res://assets-src/p16/soviet/"
const DST := "res://assets/models/"

# obj -> [[имя на выходе, файл текстуры], ...]. Префикс sv- = soviet vehicles. Одна геометрия, разные
# альбедо: у «классики» семь окрасок на одной сетке в 92 грани.
const JOBS := [
	["vaz/vaz_klassika.obj", [
		["sv-vaz2101-yellow", "vaz/vaz2101_albedo_yellow.png"],
		["sv-vaz2101-grey", "vaz/vaz2101_albedo_grey.png"],
		["sv-vaz2105-green", "vaz/vaz2105_albedo_green.png"],
		["sv-vaz2106-blue", "vaz/vaz2106_albedo_blue.png"],
		["sv-vaz2106-red", "vaz/vaz2106_albedo_red.png"],
	]],
	["bobik/bobik.obj", [
		["sv-uaz469", "bobik/bobik_albedo.png"],
	]],
	["buhanka/buhanka.obj", [
		["sv-uaz452", "buhanka/buhanka_albedo.png"],
		["sv-uaz452-grey", "buhanka/buhanka_grey_albedo.png"],
	]],
]


func _initialize() -> void:
	var made := 0
	var bad := 0
	for job: Array in JOBS:
		var mesh := _read_obj(SRC + String(job[0]))
		if mesh == null:
			printerr("не прочитался OBJ: " + String(job[0]))
			bad += 1
			continue
		for row: Array in job[1]:
			var out_name := String(row[0])
			var tex_path := SRC + String(row[1])
			var tex := _load_texture(tex_path)
			if tex == null:
				printerr("нет текстуры: " + tex_path)
				bad += 1
				continue
			if _write_glb(mesh, tex, out_name):
				made += 1
				print("готово: %s.glb (%d поверхностей)" % [out_name, mesh.get_surface_count()])
			else:
				bad += 1
	print("obj_to_glb: собрано %d, ошибок %d" % [made, bad])
	quit(1 if bad > 0 else 0)


# ---------------------------------------------------------------- чтение ----

func _read_obj(path: String) -> ArrayMesh:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return null
	var vs: PackedVector3Array = PackedVector3Array()
	var uvs: PackedVector2Array = PackedVector2Array()
	var ns: PackedVector3Array = PackedVector3Array()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var faces := 0
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line.is_empty() or line.begins_with("#"):
			continue
		var parts := line.split(" ", false)
		var tag := parts[0]
		if tag == "v" and parts.size() >= 4:
			vs.append(Vector3(float(parts[1]), float(parts[2]), float(parts[3])))
		elif tag == "vt" and parts.size() >= 3:
			# В OBJ начало текстурных координат внизу, в Godot — вверху.
			uvs.append(Vector2(float(parts[1]), 1.0 - float(parts[2])))
		elif tag == "vn" and parts.size() >= 4:
			ns.append(Vector3(float(parts[1]), float(parts[2]), float(parts[3])))
		elif tag == "f" and parts.size() >= 4:
			# Полигон бьётся веером от первой вершины — у этих моделей грани
			# плоские и выпуклые, веера хватает.
			for i in range(2, parts.size() - 1):
				for idx: String in [parts[1], parts[i], parts[i + 1]]:
					_emit_vertex(st, idx, vs, uvs, ns)
				faces += 1
	f.close()
	if faces == 0:
		return null
	if ns.is_empty():
		st.generate_normals()
	st.index()
	return st.commit()


func _emit_vertex(st: SurfaceTool, token: String, vs: PackedVector3Array,
		uvs: PackedVector2Array, ns: PackedVector3Array) -> void:
	var bits := token.split("/")
	var vi := int(bits[0])
	var ti := int(bits[1]) if bits.size() > 1 and bits[1] != "" else 0
	var ni := int(bits[2]) if bits.size() > 2 and bits[2] != "" else 0
	# Индексы в OBJ с единицы; отрицательные считаются с конца.
	if ti != 0 and not uvs.is_empty():
		st.set_uv(uvs[(ti - 1) if ti > 0 else (uvs.size() + ti)])
	if ni != 0 and not ns.is_empty():
		st.set_normal(ns[(ni - 1) if ni > 0 else (ns.size() + ni)])
	st.add_vertex(vs[(vi - 1) if vi > 0 else (vs.size() + vi)])


func _load_texture(path: String) -> ImageTexture:
	var img := Image.new()
	var abs_path := ProjectSettings.globalize_path(path)
	if img.load(abs_path) != OK:
		return null
	return ImageTexture.create_from_image(img)


# ---------------------------------------------------------------- запись ----

func _write_glb(mesh: ArrayMesh, tex: ImageTexture, out_name: String) -> bool:
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = tex
	# Пиксель-арт: сглаживание превращает его в мыло, а именно ради этой
	# зернистости пак и выбран — она ложится в кадр 1988 года сама.
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.metallic = 0.0
	mat.roughness = 1.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_DISABLED

	var copy := ArrayMesh.new()
	for s in mesh.get_surface_count():
		copy.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, mesh.surface_get_arrays(s))
		copy.surface_set_material(s, mat)

	var root := Node3D.new()
	root.name = out_name
	var mi := MeshInstance3D.new()
	mi.name = out_name + "-mesh"
	mi.mesh = copy
	root.add_child(mi)
	mi.owner = root

	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_scene(root, state) != OK:
		root.free()
		return false
	var ok := doc.write_to_filesystem(state, ProjectSettings.globalize_path(DST + out_name + ".glb"))
	root.free()
	return ok == OK

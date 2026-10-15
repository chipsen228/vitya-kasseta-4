# Фотографии из ТЗ — три рамки в доме и крупный план (фаза 9).
#
# ТЗ прямо запрещает перерисовывать снимки: они игровые ассеты как есть.
# tools/gen_photos.py вынимает их из DOCX и делает ровно две вещи — кроп
# и размер. Подписи под ними тоже из ТЗ, дословно.
#
# ЦЕПОЧКА ОДНА И ТА ЖЕ, что у четырёх картин прототипа, и повторяется один
# в один: файл в assets/pictures/ -> ключ в Materials.PICTURES -> проп
# make: "picture" -> строка в LOOKS -> точка Interact. Единственное, чего
# у картин прототипа нет, — крупный план: ui.openPhoto() поверх готового
# _screen/_panel в overlays.gd.
#
# ЛОВУШКА, стоившая часа в фазе 7: без `--headless --import` materials.picture()
# молча отдаёт серую доску. Ни ошибки, ни предупреждения — просто картина без
# картины.
#
# ВТОРОЙ ВИТОК. Возвращаясь в дом после улицы, игрок находит рамки на своих
# местах, но не со своими снимками: три фотографии меняются местами. Второго
# комплекта текстур это не требует вовсе (и не требует генерации, которой
# у нас нет), а работает ровно на том же — «я это уже видел, но не так».

class_name Photos
extends RefCounted

# Куда повесить. Стены выбраны по data/site.json WALLS: у каждой проверено,
# что в этом месте нет ни проёма, ни окна, ни чужого пропа.
#
#   pic  — ключ Materials.PICTURES
#   at   — где висит центр рамы
#   ry   — поворот. Лицевая сторона рамы — локальный −Z (см. props._make
#          "picture"): ry = 0 смотрит на север, PI — на юг, PI/2 — на запад.
const FRAMES := [
	{
		"id": "photo-grandson", "pic": "grandson",
		# Восточная стена общей комнаты, между дверью и окном (окно на z = 14.4).
		"at": [4.32, 1.60, 13.20], "ry": PI / 2.0, "w": 0.44, "h": 0.33,
	},
	{
		"id": "photo-tonya", "pic": "tonya",
		# Дальняя комната, восточная стена между окнами (8.4 и 11.2).
		"at": [4.32, 1.62, 9.80], "ry": PI / 2.0, "w": 0.34, "h": 0.45,
	},
	{
		"id": "photo-nephew", "pic": "nephew",
		# Дальняя комната, северная стена между окном (x = 2.7) и углом.
		# Западную стену прихожей пришлось отдать: там по всей длине идёт
		# лестничный марш, и рама висела бы над ступенями — до неё нельзя
		# дотянуться ниоткуда (это и поймал tests/audit_reach.gd).
		"at": [3.70, 1.62, 6.72], "ry": PI, "w": 0.30, "h": 0.40,
	},
]

const TEX_DIR := "res://assets/pictures/"
const TEX := {
	"grandson": "photo-grandson.webp",
	"tonya": "photo-tonya.webp",
	"nephew": "photo-nephew.webp",
}


## Пропы для общей сборки. Все три с "col": false — 83 коллайдера паритета
## не двигаются по построению (props.spawn выходит до записи коробки).
static func extra_props() -> Array:
	var out: Array = []
	for f: Dictionary in FRAMES:
		out.append({
			"id": f["id"],
			"make": "picture",
			"at": f["at"],
			"ry": f["ry"],
			"pic": f["pic"],
			"w": f["w"],
			"h": f["h"],
			"col": false,
		})
	return out


## Точки взаимодействия. Явный дескриптор, а не осмотр из LOOKS: осмотр ставит
## точку на 0.7 м выше пропа, то есть под потолок над рамой, — та же грабля,
## из-за которой четыре картины прототипа прибиты координатами в extra_looks.
static func register(I: Interact, _c: Dictionary) -> void:
	var t := GameData.texts()
	var looks: Dictionary = t["LOOKS"]
	var caps: Dictionary = t.get("PHOTOS", {})
	for f: Dictionary in FRAMES:
		var id := String(f["id"])
		var at: Array = f["at"]
		var line := String(looks.get(id, ""))
		var caption := String(caps.get(id, ""))
		var tex_path := TEX_DIR + String(TEX.get(String(f["pic"]), ""))
		var on_use := func(c: Dictionary) -> void:
			var s: GameState = c["state"]
			s.looked[id] = true
			var tex: Texture2D = null
			if ResourceLoader.exists(tex_path):
				tex = load(tex_path) as Texture2D
			if tex == null:
				# Без импорта снимка нет — сцена не пропадает, остаётся реплика.
				c["ui"].say(line if line != "" else caption, 4.4)
				Interact._emit(c, "look", id)
				return
			c["controls"].enabled = false
			c["controls"].release_lock()
			c["ui"].openPhoto(tex, caption, id, func() -> void:
				Interact._emit(c, "photo-closed", id))
			Interact._emit(c, "look", id)
		I.add({
			"id": id,
			"pos": Vector3(float(at[0]), float(at[1]), float(at[2])),
			"r": 2.0, "cone": 0.5, "priority": 3,
			"prompt": "рассмотреть",
			"onUse": on_use,
		})


## Второй виток: три снимка меняются рамами по кругу. Один вызов на кадр входа
## в дом, дальше ничего не тикает.
static func shuffle(props: Props, mats: Materials) -> int:
	if props == null or mats == null:
		return 0
	var n := FRAMES.size()
	var done := 0
	for i in n:
		var id := String(FRAMES[i]["id"])
		var pic := String(FRAMES[(i + 1) % n]["pic"])
		var canvas := _canvas(props.get_prop(id))
		if canvas == null:
			continue
		canvas.material_override = mats.picture(pic)
		done += 1
	return done


## Полотно рамы. Проп собран из двух частей — коробка рамы и плоскость холста;
## холст ищем по классу меша, а не по индексу: индекс поедет от первой же
## правки props._make("picture"), и подмена молча уйдёт в раму.
static func _canvas(holder: Node3D) -> MeshInstance3D:
	if holder == null:
		return null
	for ch: Node in holder.get_children():
		if not (ch is MeshInstance3D):
			continue
		var mi := ch as MeshInstance3D
		if mi.mesh is PlaneMesh or mi.mesh is QuadMesh:
			return mi
	return null

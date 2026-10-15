# Фигуры на сцене — порт src/game/actors.js. Человек в игре один, хозяин дачи,
# но моделей две.
#
# Вторая нужна из-за порядка кадра, а не из-за сюжета. Threat.update каждый кадр
# переписывает позицию своей фигуры, а в состоянии 'absent' каждый кадр её
# прячет. Поставь двойника на ту же модель — и он погаснет в том же кадре, до
# отрисовки: мелькание в окне просто не покажется ни разу.
#
# Контракт владения, третьего владельца нет:
#   'threat' — ai.gd, позиция и видимость каждый кадр;
#   'echo'   — haunt.gd, короткие постановочные появления.
#
# Обе фигуры лепятся по одной мерке и с одним лицом: это один и тот же человек,
# и игрок не должен считать двойника за кого-то ещё.
#
# Лицо живёт не отдельной плоскостью, а второй поверхностью на самом меше
# головы: плоскость на фиксированном z уезжала с головы, как только шея
# поворачивалась, — а шея тут поворачивается всегда, сутулость сделана
# поворотом. Если текстура не загрузилась, голова собирается ОДНИМ материалом,
# безликой болванкой: в темноте это читается как силуэт, и лучше так, чем
# чёрный квадрат на голове.

class_name Actors
extends RefCounted

const FACE_TEX := "res://assets/face/vitya-v2.webp"
const PSX_SHADER := "res://shaders/psx.gdshader"

# Ключи фигур. Порядок не важен, важна закрытость списка: незнакомый ключ
# раньше молча доставался до чужой модели.
#
# Фаза 9: три соседа. Они не ИИ и не угроза — ходит только Аркадий, и ходит
# по кольцу из data/street.json; крикун и наблюдатель стоят. Мерка у всех одна
# (лепить второй скелет ради двух прохожих дороже, чем польза), а различают их
# лицо и одежда — set_face()/dress() ниже. Владельцы фигур:
#   'threat'  — ai.gd, позиция и видимость каждый кадр;
#   'echo'    — haunt.gd, короткие постановочные появления;
#   соседи    — neighbours.gd, целиком и только он.
# Фаза 15: Валя из красного дома. Мерка та же, различают её лицо
# и одежда — как всех соседей фазы 9.
const KEYS := ["threat", "echo", "arkady", "shouter", "watcher", "valya"]

# Кого лепить с общим кроем деда, а кого — соседом. Разница ровно в двух вещах:
# у соседей нет сутулости деда в позе покоя (они не старики) и своя одежда.
const NEIGHBOUR_KEYS := ["arkady", "shouter", "watcher", "valya"]

# ---------------------------------------------------------------- мерка ----
#
# Дед Витя, семьдесят восемь лет. Рост 1.72, а не 1.78: к этому возрасту уходит
# пять-семь сантиметров, и рост вровень с игроком (1.78) читался как зеркало —
# фигура переставала быть чужой.
#
# Доли от роста, по которым разложены коробки:
#   голова 0.220 (0.128 H, то есть 7.8 голов — стариковская пропорция)
#   шея    0.070
#   торс   0.545 (0.317 H, от таза до плеч)
#   таз    0.885 (0.515 H) — точка вращения бедра
#   бедро 0.415 + голень 0.400 + сапог 0.070 = 0.885, сходится с тазом.
#
# Плечи 0.42, а не 0.50. Оси рук на ±0.240, рука шириной 0.105 — полный размах
# 0.585 при капсуле деда 0.640 (ai.gd, R = 0.32). Мерка считается по РАДИУСУ ОТ
# ОСИ, а не по размаху: крен таза ROLL сносит корпус вбок, и в ходьбе рукав
# уходит на 0.020 дальше, чем в покое. При ±0.240 худший кадр даёт 0.3126,
# запас семь миллиметров. Прежние ±0.30 давали 0.72 — шире капсулы на восемь
# сантиметров, и руки лезли в косяки.
const H := 1.72

const HIP_Y := 0.885         # высота таза = длина ноги от пола
const TORSO_H := 0.545       # таз -> плечи
const NECK_H := 0.070
const HEAD_H := 0.220
const HEAD_W := 0.200
const HEAD_D := 0.220        # череп глубже, чем шире, — так и у человека
const THIGH := 0.415
const SHIN := 0.400
const BOOT := 0.070

const SHOULDERS := 0.42      # ширина торса = ширина плеч
const SHOULDER_Y := 0.470    # сустав плеча ниже верха торса, как акромион
const ARM_X := 0.240         # ось руки: снаружи торса, впритык
const ARM_W := 0.105
const UPPER_ARM := 0.285
const HAND := 0.105
const FOREARM := 0.350       # предплечье + кисть одним куском
const SLEEVE := FOREARM - HAND
const HIP_X := 0.088         # половина расстояния между бёдрами

# Кончики пальцев: 0.885 + 0.470 − 0.285 − 0.350 = 0.720. Середина бедра —
# 0.678. Руки висят там, где и должны.

# Сутулость — поворотом, а не укорочением. Корпус завален на 0.16 рад в точке
# таза, шея контр-вращается на 0.10 (дед горбится и при этом задирает
# подбородок — иначе он смотрит в землю и лица не видно вовсе).
#
# Знак отрицательный, потому что перёд фигуры — это локальный −Z: face() ставит
# rotation.y = atan2(...) + PI, то есть на цель разворачивается именно −Z. Точка
# выше сустава при rotation.x = −a уходит в −Z, то есть вперёд. По той же
# причине бедро вперёд — это ПЛЮС, локоть сгибается в ПЛЮС, а колено — в МИНУС.
const STOOP := 0.16
const NECK_UP := 0.10

# Просвет подпола 1.90 и чердака 1.85. В покое верх кепки замерен на 1.729,
# с добавкой сутулости +0.22 (её даёт ai.gd через opts.stoop) — на 1.704.

# ---------- цикл ходьбы ----------
# Фаза считается от ПРОЙДЕННОГО РАССТОЯНИЯ, не от абсолютного времени. Прежняя
# качалка от часов крутилась и когда он стоял на месте: ноги «шли», фигура не
# двигалась.
#
# Шаг 0.76 м, поэтому phase = (dist / 0.76) * PI: полный цикл 2*PI = два шага.
# Бедро идёт по косинусу, и ноль фазы — это касание пяткой: колено при
# 0.62*max(0, −sin(phase + 0.55)) в этот момент прямое, гнётся к отталкиванию
# и максимально согнуто в переносе (пик на 66 % цикла, у человека 70–75 %).
const STRIDE := 0.76
const BLEND_TAU := 0.18      # за сколько секунд походка набирает силу
const A_HIP := 0.52
const A_KNEE := 0.62
const A_FOOT_ROLL := 0.20    # перекат опорной стопы от пятки к носку
const KNEE_LEAD := 0.55      # сдвиг колена относительно бедра
const KNEE_REST := 0.06      # в покое колени НИКОГДА не в замок: прямые ноги = манекен
const A_SHOULDER := 0.34
const ARM_BIAS := 0.10       # руки чуть вперёд — стариковская посадка плеч
const ELBOW_MID := 0.30
const A_ELBOW := 0.20
const ELBOW_REST := 0.10     # та же причина, что у KNEE_REST
const ARM_TUCK := 0.05       # мах рукой внутрь, к телогрейке, и НИКОГДА наружу:
                             # наружу он растил бы радиус за пределы 0.32.
const BOB := 0.021           # просадка таза, дважды за цикл
const ROLL := 0.035          # крен таза на опорную ногу
const TWIST := 0.11          # противоход плеч тазу
const HEAD_TAU := 0.22       # постоянная доворота головы
const HEAD_MAX := PI / 3.0   # голова отворачивается от корпуса не больше 60°
const BREATH_HZ := 0.18      # единственное, что осталось от абсолютного времени:
                             # замершее дыхание читается как зависший кадр
const BREATH_ROT := 0.010
const BREATH_BOB := 0.0035
const TELEPORT := 0.60       # скачок больше — это перенос на этаж, а не шаг

# Переминание (фаза 7). Стоящий дед был стоп-кадром: за вычетом дыхания фигура
# не двигалась ни на миллиметр все 1.2–2.6 секунды дневки, и это читалось как
# «поставили и забыли». Теперь он перекладывает вес с ноги на ногу и водит
# головой по сторонам. Амплитуды намеренно мелкие: это признак живого,
# а не отдельная анимация, и на 540 строках буфера крупнее и не нужно.
const SWAY_HZ := 0.21        # период около пяти секунд — вес перекладывают редко
const SWAY_ROLL := 0.030     # крен таза на опорную ногу
const SWAY_SHIFT := 0.017    # и сам перенос веса вбок, м
const SWAY_TAU := 0.55       # за сколько переминание набирает и теряет силу
const SCAN_HZ := 0.13        # голова оглядывается ещё медленнее
const SCAN_YAW := 0.34       # и не дальше 20° — дальше поворачиваются корпусом

# Задел под LOD. На 12 м фигура занимает около 24 пикселей, и щель между ногами
# там ровно один пиксель — две ноги можно слить в один меш. Гистерезис 1.5 м,
# иначе на границе меш мигает каждый кадр. Переключение не включено; структура
# (legs как массив суставов) под него уже разложена.
const LOD_FAR := 12.0
const LOD_HYST := 1.5

# Тона взяты из палитры мира (materials.gd): телогрейка и рабочие штаны, в луче
# фонаря они не должны выделяться из общей грязи участка. Цвет берём ТОЧНЫЙ
# (flat(..., true)): snapToPalette притянул бы кожу и сапог к соседнему тону,
# а у оригинала фигура шла мимо палитры реквизита.
const COAT := 0x4a5f52
const TROUSERS := 0x3d4b52
const SKIN := 0x73695f
const HAIR := 0x2b2f33
const BOOT_C := 0x22262a

# Силуэты используют тот же риг и мерку, но читаются уже по пропорциям, а не
# только по цвету одежды. height меняет лишь вертикальную мерку; остальные
# коэффициенты не затрагивают position/скорость/тайминги владельцев фигур.
const PROFILES := {
	"threat": {"height": 1.0, "torso": 0.96, "limb": 0.96, "shoulder": 1.0, "stoop": 1.0, "cap": true},
	"echo": {"height": 1.0, "torso": 0.96, "limb": 0.96, "shoulder": 1.0, "stoop": 1.0, "cap": true},
	"arkady": {"height": 1.0, "torso": 1.18, "limb": 1.10, "shoulder": 1.08, "stoop": 0.22},
	"shouter": {"height": 1.0, "torso": 1.22, "limb": 1.08, "shoulder": 1.18, "stoop": 0.30},
	"watcher": {"height": 1.0, "torso": 0.78, "limb": 0.82, "shoulder": 0.86, "stoop": 0.30},
	"valya": {"height": 0.88, "torso": 0.92, "limb": 0.90, "shoulder": 0.92, "stoop": 0.25, "skirt": true, "scarf": true},
}

# Обрезка UV грани лица. Текстура 128x128 квадратная, грань 0.200 x 0.220 — без
# среза лицо растягивалось бы по вертикали. Срез по V возвращает пропорцию,
# а срез по U убирает пустые поля по краям картинки.
const FACE_U0 := 0.200
const FACE_U1 := 0.800
const FACE_V0 := 0.160
const FACE_V1 := 0.920

var root: Node3D = null
var mats: Materials = null
var face_tex: Texture2D = null
var built := false

var figures: Dictionary = {}      # who -> Node3D
var _rigs: Dictionary = {}        # who -> {body, chest, neck, legs, arms, head, anim}
var _kit: Dictionary = {}         # общие меши и материалы на обе фигуры
var _psx: Shader = null
var _warned: Dictionary = {}
var _actions: Dictionary = {}
const ACTIONS := ["run", "stop", "shovel_windup", "shovel_impact", "shovel"]
const ACTION_TIMING := {"run": 0.62, "stop": 0.28, "shovel_windup": 0.65,
	"shovel_impact": 0.30, "shovel": 0.95, "contact": 0.72}


# root — куда класть фигуры (world_root цепочки рендера); mats — палитра фазы 1.
# Дерево сцены сам класс не трогает: всё уходит детьми в переданный root.
func _init(root_in: Node3D, mats_in: Materials = null) -> void:
	root = root_in
	mats = mats_in


# Аналог await actors.load() оригинала: в Godot текстура грузится синхронно,
# ждать нечего. Идемпотентно — второй вызов ничего не делает.
func build() -> Actors:
	if built:
		return self
	built = true
	_psx = load(PSX_SHADER) as Shader
	face_tex = _load_face()
	_make_kit()
	for who: String in KEYS:
		var f := _make_figure(who)
		f.name = "actor-" + who
		f.visible = false
		if root != null:
			root.add_child(f)
		figures[who] = f
		# Все шесть фигур используют исходный процедурный риг. Внешние скины
		# сохранены в архиве и не подменяют анимируемые части игры.
	return self


# ---------------------------------------------------------- модель фигуры --
#
# Ветка «модель» рядом с процедурной (фаза 7). Дед собран из тринадцати коробок,
# и вблизи это видно; готовая модель вписывается в ТУ ЖЕ мерку и прячет коробки,
# не трогая ни рига, ни походки, ни меты face_y, за которую целится haunt.gd.
#
# Развилка по анимациям. Если в GLB приехал AnimationPlayer — модель годится
# обоим: походку крутит он, а сутулость, доворот головы и переминание остаются
# кодом поверх. Если анимаций нет, модель достаётся ТОЛЬКО двойнику: он по
# замыслу всегда стоит неподвижно (haunt.gd — «он стоит»), и походку ему
# намеренно не крутят. Сам дед в этом случае остаётся процедурным — детальная
# фигура, которая скользит по полу не сгибая ног, хуже честных коробок.
#
# Нет файла — не происходит ничего, и фигуры ровно те же, что в фазе 6.
const MODEL_PATH := "res://assets/models/vitya.glb"
const MODEL_HEIGHT := H          # к какому росту приводить модель

var model_used: Dictionary = {}  # who -> как именно ("анимации" / "статика")


func _skin_figure(who: String, fig: Node3D) -> void:
	var skin := SkinLayer.load_all()
	var cfg := skin.entry("actors/" + who)
	if not cfg.is_empty():
		var model := skin.apply_actor(who, fig, _rigs.get(who, {}))
		if model != null:
			var driver := SkinBoneDriver.new()
			if driver.configure(model, _rigs.get(who, {}), cfg.get("bones", {})):
				driver.name = "skin-bone-driver"
				fig.add_child(driver)
				model_used[who] = "кости"
			else:
				driver.free()
		# Явный ключ владеет выбором модели, включая отказ по габариту.
		return
	# Модель — это ДЕД. Надеть её на соседей значило бы поставить на улице трёх
	# одинаковых стариков: игрок обязан отличать соседа от угрозы с первого
	# взгляда, и различает он их именно фигурой.
	if NEIGHBOUR_KEYS.has(who):
		return
	if not ResourceLoader.exists(MODEL_PATH):
		return
	var packed: PackedScene = load(MODEL_PATH) as PackedScene
	if packed == null:
		return
	var node := packed.instantiate() as Node3D
	if node == null:
		return
	var player := _find_anim(node)
	if player == null and who != "echo":
		# Без анимаций модель годится только неподвижному двойнику.
		node.free()
		return

	# Приводим к росту фигуры и ставим ногами в ноль — та же посадка, что
	# у процедурной сборки.
	var box := PropsSkin.local_aabb(node)
	if box.size.y > 1e-3:
		var k := MODEL_HEIGHT / box.size.y
		node.scale = Vector3(k, k, k)
		var fitted := node.transform * box
		node.position = Vector3(-fitted.get_center().x, -fitted.position.y,
			-fitted.get_center().z)
	node.name = "model"
	fig.add_child(node)
	_psx_model(node)

	# Коробки остаются в дереве, но невидимы: мерка фигуры и мета face_y
	# считаются по ним, и выкидывать их — значит терять точку прицела.
	for ch: Node in fig.get_children():
		if ch != node and ch is Node3D:
			(ch as Node3D).visible = false
	model_used[who] = "анимации" if player != null else "статика"


# Суставы остаются источником позы: постановочные сцены пишут в них тем же API,
# что и походка. Драйвер добавляется только после успешной подмены модели.
class SkinBoneDriver extends Node:
	var skeleton: Skeleton3D = null
	var bindings: Array[Dictionary] = []
	var issues: PackedStringArray = []


	func configure(model: Node3D, rig: Dictionary, bones: Dictionary) -> bool:
		bindings.clear()
		issues.clear()
		skeleton = find_skeleton(model)
		if skeleton == null:
			issues.append("нет Skeleton3D")
			return false
		if bones.is_empty():
			issues.append("пустая таблица bones")
			return false
		var used: Dictionary = {}
		for limb: String in bones:
			var source := joint(rig, limb)
			var spec: Variant = bones[limb]
			if not (spec is String or spec is Dictionary):
				issues.append("%s: ожидается имя кости или {bone: имя}" % limb)
				continue
			var bone_name := String(spec.get("bone", "")) if spec is Dictionary else String(spec)
			var index := skeleton.find_bone(bone_name)
			if source == null or index < 0 or used.has(index):
				issues.append("%s -> %s: нет сустава/кости или кость уже занята" % [limb, bone_name])
				continue
			used[index] = true
			var rest := skeleton.get_bone_rest(index)
			var position_basis := Basis.IDENTITY
			var parent := skeleton.get_bone_parent(index)
			if parent >= 0:
				position_basis = skeleton.get_bone_global_rest(parent).basis.inverse()
			# Просадку таза переводим из метров фигуры в пространство рига GLB:
			# fit модели может иметь масштаб, отличный от единицы.
			var owner_node := model.get_parent()
			var skel_xf := relative_transform(skeleton, owner_node)
			var source_xf := relative_transform(source.get_parent(), owner_node)
			position_basis = position_basis * skel_xf.basis.inverse() * source_xf.basis
			bindings.append({"joint": source, "bone": index,
				"rest_rotation": rest.basis.orthonormalized().get_rotation_quaternion(),
				"rest_position": rest.origin, "source_position": source.position,
				"position_basis": position_basis, "position": limb == "body"})
		if not issues.is_empty():
			return false
		sync_pose()
		return not bindings.is_empty()


	func sync_pose() -> void:
		if not is_instance_valid(skeleton):
			return
		for binding: Dictionary in bindings:
			var source: Node3D = binding["joint"]
			if not is_instance_valid(source):
				continue
			var index: int = binding["bone"]
			# Присваиваем от rest, чтобы повторный вызов не накапливал поворот.
			var rest_rotation: Quaternion = binding["rest_rotation"]
			skeleton.set_bone_pose_rotation(index, (rest_rotation * source.quaternion).normalized())
			if bool(binding["position"]):
				var delta := source.position - Vector3(binding["source_position"])
				var position_basis: Basis = binding["position_basis"]
				skeleton.set_bone_pose_position(index,
					Vector3(binding["rest_position"]) + position_basis * delta)


	func _enter_tree() -> void:
		# main обновляет походку в _process; кадр рендера берёт уже эту позу.
		# _process нужен также Dummy-рендереру headless-проверок.
		process_priority = 1000
		if not RenderingServer.frame_pre_draw.is_connected(sync_pose):
			RenderingServer.frame_pre_draw.connect(sync_pose)


	func _exit_tree() -> void:
		if RenderingServer.frame_pre_draw.is_connected(sync_pose):
			RenderingServer.frame_pre_draw.disconnect(sync_pose)


	func _process(_dt: float) -> void:
		sync_pose()


	static func find_skeleton(node: Node) -> Skeleton3D:
		if node is Skeleton3D:
			return node as Skeleton3D
		for child: Node in node.get_children():
			var found := find_skeleton(child)
			if found != null:
				return found
		return null


	static func joint(rig: Dictionary, limb: String) -> Node3D:
		var value: Variant = rig
		for part: String in limb.replace(".", "/").split("/", false):
			if value is Dictionary:
				value = value.get(part)
			elif value is Array and part.is_valid_int():
				var index := int(part)
				value = value[index] if index >= 0 and index < value.size() else null
			else:
				return null
		return value as Node3D


	static func relative_transform(node: Node, ancestor: Node) -> Transform3D:
		var result := Transform3D.IDENTITY
		var current := node
		while current != null and current != ancestor:
			if current is Node3D:
				result = (current as Node3D).transform * result
			current = current.get_parent()
		return result


func _find_anim(node: Node) -> AnimationPlayer:
	if node is AnimationPlayer:
		return node
	for ch: Node in node.get_children():
		var p := _find_anim(ch)
		if p != null:
			return p
	return null


# Материалы модели через psx.gdshader — иначе сгенерированная фигура висит
# фотореалистичным пятном среди низкополигональной обстановки: не снапится
# по вершинам, не получает аффинных UV и не тонет в общем тумане.
func _psx_model(node: Node3D) -> void:
	for mi: MeshInstance3D in PropsSkin._meshes(node):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var src := mi.get_active_material(i)
			var m := ShaderMaterial.new()
			m.shader = _psx
			var c := Color(1, 1, 1)
			if src is BaseMaterial3D:
				var b := src as BaseMaterial3D
				c = b.albedo_color
				if b.albedo_texture != null:
					m.set_shader_parameter("albedo_tex", b.albedo_texture)
			m.set_shader_parameter("albedo", c)
			mi.set_surface_override_material(i, m)


# Лицо: 128x128, magFilter/minFilter Nearest и БЕЗ мипов (mipmaps/generate=false
# в .import). Линейная фильтрация без мипов на текстуре, отрисованной в десять
# пикселей, даёт мерцание на каждом кадре — лицо «кипит» ровно тогда, когда его
# разглядывают издали. Нет файла — фигура собирается безликой, это не ошибка.
func _load_face() -> Texture2D:
	if not ResourceLoader.exists(FACE_TEX):
		return null
	return load(FACE_TEX) as Texture2D


# -------------------------------------------------------------- геометрия --

# Материалы и геометрии на обе фигуры разом. Раньше сборка лепила свой комплект
# каждой — шесть лишних компиляций шейдера на загрузке.
func _make_kit() -> void:
	var m_coat := mats.physical(COAT, "fabric", 0.96) if mats != null else _flat(COAT)
	var m_legs := _flat(TROUSERS)
	var m_skin := _flat(SKIN)
	var m_neck := _flat(0x514035)
	# Боковина получает лишь слабый заполняющий свет; фотографию и её UV
	# не меняем. Отдельный экземпляр не затрагивает кисти других профилей.
	var m_head_skin := m_skin.duplicate() as ShaderMaterial
	var head_params: Dictionary = m_head_skin.get_meta("skin_hq_params", {}).duplicate()
	head_params["emission_color"] = Color(0.065, 0.042, 0.028)
	m_head_skin.set_meta("skin_hq_params", head_params)
	m_head_skin.set_shader_parameter("emission_color", head_params["emission_color"])
	var m_hair := _flat(0x4b4c46)
	var m_boot := mats.physical(BOOT_C, "", 0.97) if mats != null else _flat(BOOT_C)

	# Лицо ОБЯЗАНО идти через psx-шейдер. Прежнее было единственным материалом
	# в игре без него — без снапа вершин и без аффинной развёртки голова
	# не дрожала вместе с остальной картинкой и выглядела вклеенной.
	var m_face: Material = null
	if face_tex != null:
		m_face = _psx_mat(0xffffff, face_tex)

	_kit["hips"] = _frustum(0.29, 0.34, 0.26, 0.22, 0.24, m_legs)
	_kit["torso"] = _object_part("object/torso", m_coat)
	_kit["thigh"] = _cylinder(0.078, 0.060, THIGH, 6, m_legs)
	_kit["shin"] = _cylinder(0.068, 0.052, SHIN, 6, m_legs)
	_kit["boot"] = _object_part("object/boot", m_boot)
	_kit["upper_arm"] = _shoulder_mesh(m_coat)
	_kit["forearm"] = _cylinder(0.048, 0.038, SLEEVE, 6, m_coat)
	_kit["hand"] = _object_part("object/hand", m_skin)

	_kit["neck"] = _object_part("object/neck", m_neck)
	_kit["cap"] = _cap_mesh(m_hair)
	_kit["skirt"] = _frustum(0.38, 0.27, 0.37, 0.30, 0.23, m_coat)
	_kit["scarf"] = _scarf_mesh(m_hair)
	var head := _object_part("object/head", m_head_skin)
	head.surface_set_material(1, m_face if m_face != null else m_skin)
	_kit["head"] = head


func _object_part(key: String, mat: Material) -> ArrayMesh:
	# Материалы индивидуальны для комплекта, геометрия берётся из bake-кэша.
	var mesh := ObjectGeometry.shared(key).duplicate() as ArrayMesh
	mesh.surface_set_material(0, mat)
	return mesh


# Материал под плоский цвет. exact = true: фигура в оригинале не проходила через
# snapToPalette, и притягивать кожу к ближайшему тону реквизита нельзя.
func _flat(hex: int) -> Material:
	if mats != null:
		return mats.flat(hex, true)
	return _psx_mat(hex, null)


# Тот же psx-материал, что лепит materials.gd, но с произвольной текстурой:
# публичного «psx с картинкой» в Materials нет, а лицу он нужен.
func _psx_mat(hex: int, tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _psx
	m.set_shader_parameter("albedo", GameData.color(hex))
	if tex != null:
		m.set_shader_parameter("albedo_tex", tex)
	return m


func _cylinder(top_r: float, bottom_r: float, h: float, seg: int, mat: Material) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top_r
	c.bottom_radius = bottom_r
	c.height = h
	c.radial_segments = seg
	# Линейный конус не требует промежуточного кольца: силуэт и нормали те же.
	c.rings = 0
	c.material = mat
	return c

func _frustum(top_w: float, bottom_w: float, h: float, top_d: float,
		bottom_d: float, mat: Material) -> ArrayMesh:
	var y0 := -h / 2.0
	var y1 := h / 2.0
	var top := [Vector3(-top_w / 2.0, y1, -top_d / 2.0), Vector3(top_w / 2.0, y1, -top_d / 2.0),
		Vector3(top_w / 2.0, y1, top_d / 2.0), Vector3(-top_w / 2.0, y1, top_d / 2.0)]
	var bot := [Vector3(-bottom_w / 2.0, y0, -bottom_d / 2.0), Vector3(bottom_w / 2.0, y0, -bottom_d / 2.0),
		Vector3(bottom_w / 2.0, y0, bottom_d / 2.0), Vector3(-bottom_w / 2.0, y0, bottom_d / 2.0)]
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_raw_quad(st, [top[0], top[1], top[2], top[3]])
	_raw_quad(st, [bot[3], bot[2], bot[1], bot[0]])
	for i in 4:
		var j := (i + 1) % 4
		_raw_quad(st, [bot[i], bot[j], top[j], top[i]])
	st.generate_normals()
	var am := st.commit() as ArrayMesh
	am.surface_set_material(0, mat)
	return am


func _boot_mesh(mat: Material) -> ArrayMesh:
	# Клин: пятка выше и уже, носок длиннее по локальному −Z.
	var top := [Vector3(-0.065, 0.030, 0.075), Vector3(0.065, 0.030, 0.075),
		Vector3(0.075, 0.018, -0.155), Vector3(-0.075, 0.018, -0.155)]
	var bot := [Vector3(-0.065, -0.040, 0.075), Vector3(0.065, -0.040, 0.075),
		Vector3(0.075, -0.040, -0.155), Vector3(-0.075, -0.040, -0.155)]
	return _closed_wedge(top, bot, mat)


func _cap_mesh(mat: Material) -> ArrayMesh:
	# Плоский тканевый купол, узкая посадка и козырёк. Кольцо вместо
	# коробчатого тулья; число треугольников остаётся в бюджете фигуры.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var ring: Array = []
	for i in 8:
		var angle := TAU * float(i) / 8.0
		ring.append(Vector3(cos(angle) * 0.105, -0.026, sin(angle) * 0.110))
	var crown := Vector3(0, 0.028, 0.012)
	for i in 8:
		var j := (i + 1) % 8
		# Godot clockwise. Smooth crown normals keep the broad lit patch.
		for p: Vector3 in [crown, ring[i], ring[j]]:
			st.set_normal(Vector3(p.x * 3.2, 1.0, (p.z - 0.012) * 3.2).normalized())
			st.set_uv(Vector2(p.x * 4.0 + 0.5, p.z * 4.0 + 0.5))
			st.add_vertex(p)
	# Низ кепки закрывает череп; скрытые треугольники здесь не нужны.
	var am := st.commit()
	am.surface_set_material(0, mat)
	var visor := SurfaceTool.new()
	visor.begin(Mesh.PRIMITIVE_TRIANGLES)
	ObjectGeometry._polygon(visor, [Vector3(-0.082, -0.025, -0.080), Vector3(0.082, -0.025, -0.080),
		Vector3(0.067, -0.037, -0.155), Vector3(-0.067, -0.037, -0.155)], Vector3.UP)
	visor.commit(am)
	am.surface_set_material(1, mat)
	return am


func _shoulder_mesh(mat: Material) -> ArrayMesh:
	var ring: Array[Vector2] = []
	for i in 6:
		var a := TAU * float(i) / 6.0
		ring.append(Vector2(cos(a), sin(a)))
	var mesh := ObjectGeometry._rings([
		ObjectGeometry._ring(ring, -UPPER_ARM * 0.5, 0.043, 0.043),
		ObjectGeometry._ring(ring, UPPER_ARM * 0.5 - 0.070, ARM_W * 0.5, ARM_W * 0.5),
		ObjectGeometry._ring(ring, UPPER_ARM * 0.5 + 0.055, 0.025, 0.025)], true)
	mesh.surface_set_material(0, mat)
	return mesh


func _scarf_mesh(mat: Material) -> ArrayMesh:
	var top := [Vector3(-0.115, 0.100, 0.090), Vector3(0.115, 0.100, 0.090),
		Vector3(0.105, 0.100, -0.085), Vector3(-0.105, 0.100, -0.085)]
	var bot := [Vector3(-0.145, -0.145, 0.105), Vector3(0.145, -0.145, 0.105),
		Vector3(0.095, -0.075, -0.095), Vector3(-0.095, -0.075, -0.095)]
	return _closed_wedge(top, bot, mat)


func _closed_wedge(top: Array, bot: Array, mat: Material) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_raw_quad(st, [top[0], top[1], top[2], top[3]])
	_raw_quad(st, [bot[3], bot[2], bot[1], bot[0]])
	for i in 4:
		var j := (i + 1) % 4
		_raw_quad(st, [bot[i], bot[j], top[j], top[i]])
	st.generate_normals()
	var am := st.commit() as ArrayMesh
	am.surface_set_material(0, mat)
	return am


func _raw_quad(st: SurfaceTool, q: Array) -> void:
	for i: int in [0, 1, 2, 0, 2, 3]:
		st.set_uv(Vector2(1.0 if i == 1 or i == 2 else 0.0, 1.0 if i >= 2 else 0.0))
		st.add_vertex(q[i])


# Кубическая голова с плоской фотографией на фронтальной грани. Кожа занимает
# пять остальных граней, а лицо остаётся второй поверхностью того же ArrayMesh:
# set_face() меняет материал без отдельного MeshInstance и draw node.
func _head_mesh(skin_mat: Material, face_mat: Material) -> ArrayMesh:
	var hw := HEAD_W / 2.0
	var hh := HEAD_H / 2.0
	var hd := HEAD_D / 2.0
	var plain := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
	var am := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_head_quad(st, [Vector3(hw, hh, hd), Vector3(hw, hh, -hd),
		Vector3(hw, -hh, -hd), Vector3(hw, -hh, hd)], Vector3.RIGHT, plain)
	_head_quad(st, [Vector3(-hw, hh, -hd), Vector3(-hw, hh, hd),
		Vector3(-hw, -hh, hd), Vector3(-hw, -hh, -hd)], Vector3.LEFT, plain)
	_head_quad(st, [Vector3(-hw, hh, -hd), Vector3(hw, hh, -hd),
		Vector3(hw, hh, hd), Vector3(-hw, hh, hd)], Vector3.UP, plain)
	_head_quad(st, [Vector3(-hw, -hh, hd), Vector3(hw, -hh, hd),
		Vector3(hw, -hh, -hd), Vector3(-hw, -hh, -hd)], Vector3.DOWN, plain)
	_head_quad(st, [Vector3(hw, -hh, hd), Vector3(-hw, -hh, hd),
		Vector3(-hw, hh, hd), Vector3(hw, hh, hd)], Vector3.BACK, plain)

	# Перед фигуры — локальный -Z. U развёрнут так, чтобы фотография читалась
	# нормально с фронта; Godot V растёт вниз, поэтому crop перевёрнут по V.
	var front := [Vector3(hw, hh, -hd), Vector3(-hw, hh, -hd),
		Vector3(-hw, -hh, -hd), Vector3(hw, -hh, -hd)]
	var face_uv := [
		Vector2(FACE_U0, 1.0 - FACE_V1),
		Vector2(FACE_U1, 1.0 - FACE_V1),
		Vector2(FACE_U1, 1.0 - FACE_V0),
		Vector2(FACE_U0, 1.0 - FACE_V0),
	]

	if face_mat == null:
		_head_quad(st, front, Vector3.FORWARD, plain)
		st.commit(am)
		am.surface_set_material(0, skin_mat)
		return am

	st.commit(am)
	am.surface_set_material(0, skin_mat)

	var st2 := SurfaceTool.new()
	st2.begin(Mesh.PRIMITIVE_TRIANGLES)
	_head_quad(st2, front, Vector3.FORWARD, face_uv)
	st2.commit(am)
	am.surface_set_material(1, face_mat)
	return am


# Четырёхугольник. Углы перечислены ПО ЧАСОВОЙ стрелке со стороны нормали:
# в Godot лицевая сторона намотана по часовой, у three.js — против, поэтому
# порядок обхода граней при переносе переворачивается.
func _head_quad(st: SurfaceTool, q: Array, n: Vector3, uv: Array) -> void:
	for i: int in [0, 1, 2, 0, 2, 3]:
		st.set_normal(n)
		st.set_uv(uv[i])
		st.add_vertex(q[i])


# Сборка фигуры с настоящими суставами.
#
#   figure                    ноги фигуры, rotation.y = курс
#   └ body       y 0.885      таз: просадка, крен, поворот
#     ├ hips
#     ├ leg0/leg1 x ∓0.088    бедро rotation.x
#     │ └ knee    y −0.415    колено -> голень+сапог
#     └ chest                 корпус: rotation.x = сутулость, rotation.y = противоход
#       ├ torso
#       ├ arm0/arm1 x ∓0.240 y 0.470   плечо rotation.x/z
#       │ └ elbow  y −0.285             локоть -> предплечье+кисть
#       └ neck     y 0.545              шея rotation.x/y -> голова + кепка
#
# Поза покоя выставляется прямо здесь, а не в walk_anim: двойника 'echo' никто
# не анимирует, он должен стоять сутулым и с чуть согнутыми коленями с первого
# же кадра.
func _make_figure(who: String) -> Node3D:
	var g := Node3D.new()
	var profile: Dictionary = PROFILES.get(who, {})
	var height_scale := float(profile.get("height", 1.0))
	g.scale = Vector3(1.0, height_scale, 1.0)
	g.set_meta("profile", who)

	var body := _joint()
	body.position.y = HIP_Y
	g.add_child(body)

	var hips := _mesh(_part("hips"), true)
	hips.name = "hips-frustum"
	hips.scale.x = float(profile.get("torso", 1.0))
	body.add_child(hips)

	var legs: Array = []
	var leg_parts: Array = [hips]
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var hip := _joint()
		hip.position.x = side * HIP_X
		body.add_child(hip)
		var thigh := _mesh(_part("thigh"), false)
		thigh.name = "thigh-taper-%d" % i
		thigh.position.y = -THIGH / 2.0
		thigh.scale.x = float(profile.get("limb", 1.0))
		thigh.scale.z = float(profile.get("limb", 1.0))
		hip.add_child(thigh)
		leg_parts.append(thigh)

		var knee := _joint()
		knee.position.y = -THIGH
		knee.rotation = Vector3(-KNEE_REST, 0.0, 0.0)
		hip.add_child(knee)
		var shin := _mesh(_part("shin"), false)
		shin.name = "shin-taper-%d" % i
		shin.position.y = -SHIN / 2.0
		shin.scale.x = float(profile.get("limb", 1.0))
		shin.scale.z = float(profile.get("limb", 1.0))
		knee.add_child(shin)
		leg_parts.append(shin)

		var ankle := _joint()
		ankle.name = "ankle-roll-%d" % i
		ankle.position.y = -SHIN
		knee.add_child(ankle)
		var boot := _mesh(_part("boot"), false)
		boot.name = "boot-wedge-%d" % i
		boot.position = Vector3(0.0, -BOOT / 2.0 + 0.009, 0.0)
		boot.scale.x = float(profile.get("limb", 1.0))
		ankle.add_child(boot)

		legs.append({"hip": hip, "knee": knee, "ankle": ankle, "side": side})

	var chest := _joint()
	chest.rotation = Vector3(-STOOP, 0.0, 0.0)
	body.add_child(chest)

	var torso := _mesh(_part("torso"), true)
	torso.name = "torso-frustum"
	torso.position.y = TORSO_H / 2.0
	torso.scale.x = float(profile.get("torso", 1.0))
	chest.add_child(torso)

	var arms: Array = []
	var coat_parts: Array = [torso]
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		var shoulder := _joint()
		shoulder.position = Vector3(side * ARM_X * float(profile.get("shoulder", 1.0)), SHOULDER_Y, 0.0)
		shoulder.rotation = Vector3(ARM_BIAS, 0.0, 0.0)
		chest.add_child(shoulder)
		var upper := _mesh(_part("upper_arm"), false)
		upper.name = "upper-arm-taper-%d" % i
		upper.position.y = -UPPER_ARM / 2.0
		upper.position.x = -side * 0.015
		upper.scale.x = float(profile.get("limb", 1.0))
		upper.scale.z = float(profile.get("limb", 1.0))
		shoulder.add_child(upper)
		coat_parts.append(upper)

		var elbow := _joint()
		elbow.position.y = -UPPER_ARM
		elbow.rotation = Vector3(ELBOW_REST, 0.0, 0.0)
		shoulder.add_child(elbow)
		var forearm := _mesh(_part("forearm"), false)
		forearm.name = "forearm-taper-%d" % i
		forearm.position.y = -SLEEVE / 2.0
		forearm.scale.x = float(profile.get("limb", 1.0))
		forearm.scale.z = float(profile.get("limb", 1.0))
		elbow.add_child(forearm)
		coat_parts.append(forearm)

		var wrist := _joint()
		wrist.position.y = -SLEEVE
		elbow.add_child(wrist)
		var hand := _mesh(_part("hand"), false)
		hand.name = "hand-%d" % i
		hand.position.y = -HAND / 2.0
		hand.scale.x = float(profile.get("limb", 1.0)) * (-1.0 if i == 1 else 1.0)
		hand.scale.z = float(profile.get("limb", 1.0))
		wrist.add_child(hand)

		arms.append({"shoulder": shoulder, "elbow": elbow, "wrist": wrist, "hand": hand, "side": side})

	var neck := _joint()
	neck.position.y = TORSO_H
	neck.rotation = Vector3(NECK_UP, 0.0, 0.0)
	chest.add_child(neck)
	var neck_mesh := _mesh(_part("neck"), false)
	neck_mesh.position.y = NECK_H / 2.0
	neck.add_child(neck_mesh)

	var head := _mesh(_part("head"), false)
	head.position.y = NECK_H + HEAD_H / 2.0
	neck.add_child(head)

	# Козырёк выдвинут на 0.030 вперёд и накрывает лоб: без него кепка читается
	# как коробка, а с ним — как кепка, даже когда лица не разобрать.
	var cap := _mesh(_part("cap"), false)
	cap.name = "cap"
	cap.position = Vector3(0.0, head.position.y + 0.085, -0.015)
	cap.visible = bool(profile.get("cap", false))
	neck.add_child(cap)
	var headwear: Array = [cap]

	if bool(profile.get("skirt", false)):
		var skirt := _mesh(_part("skirt"), false)
		skirt.name = "profile-skirt"
		skirt.position.y = -0.105
		body.add_child(skirt)
		coat_parts.append(skirt)
	if bool(profile.get("scarf", false)):
		var scarf := _mesh(_part("scarf"), false)
		scarf.name = "profile-headscarf"
		scarf.position.y = head.position.y
		neck.add_child(scarf)
		headwear.append(scarf)

	# Высота центра лица над ногами — считается из собранной фигуры в позе
	# покоя, а не задаётся числом: сутулость наклоняет шею, и любая правка мерки
	# сдвигает лицо. haunt.gd целится по этой мете; прежняя константа 1.731 била
	# в кепку, выше верхнего края текстуры лица.
	var t: Transform3D = body.transform * chest.transform * neck.transform * head.transform
	var fc: Vector3 = t * Vector3(0.0, 0.0, -HEAD_D / 2.0)
	g.set_meta("face_y", fc.y * height_scale)
	g.set_meta("height", H * height_scale)
	g.set_meta("triangle_budget", 700)

	_rigs[who] = {
		"body": body, "chest": chest, "neck": neck, "head": head, "cap": cap,
		"headwear": headwear,
		"legs": legs, "arms": arms,
		# Одежда: по этим спискам set_surface_override_material красит фигуру
		# в свои тона. Собираем при сборке, а не ищем обходом дерева — обход
		# по имени узла разъехался бы с первой же правкой мерки.
		"coat": coat_parts, "trousers": leg_parts,
		"anim": {"t": 0.0, "dist": 0.0, "blend": 0.0, "head_yaw": 0.0,
			"px": 0.0, "pz": 0.0, "seen": false},
	}
	# Сосед не старик: сутулость деда с него снимается прямо здесь, в позе покоя.
	# walk_anim() пересчитает её сам, но двойники и наблюдатель стоят неподвижно
	# и до walk_anim() не доходят вовсе.
	if NEIGHBOUR_KEYS.has(who):
		var upright := float(profile.get("stoop", 0.35))
		chest.rotation = Vector3(-STOOP * upright, 0.0, 0.0)
		neck.rotation = Vector3(NECK_UP * upright, 0.0, 0.0)
	return g


# Общий меш из комплекта. Обе фигуры лепятся по одной мерке, поэтому геометрия
# и материалы у них одни и те же ресурсы: два комплекта = шесть лишних
# компиляций шейдера на загрузке.
func _part(key: String) -> Mesh:
	var m: Mesh = _kit[key]
	return m


# Сустав. Порядок эйлеров у three.js по умолчанию XYZ, у Godot — YXZ; корпус и
# шея крутятся сразу по X и Y, и на них разница видна, поэтому порядок ставим
# явно всем суставам разом.
func _joint() -> Node3D:
	var n := Node3D.new()
	n.rotation_order = EULER_ORDER_XYZ
	return n


# Тени только с торса и таза. Остальные одиннадцать мешей рисуют в карту теней
# силуэт, который и так почти целиком накрыт торсом: двенадцать вызовов за
# разницу, которой в кадре нет.
func _mesh(m: Mesh, shadow: bool) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	if not shadow:
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


# ------------------------------------------------------------------ мелочь --

func _wrap_pi(v: float) -> float:
	var r := v
	while r > PI:
		r -= 2.0 * PI
	while r < -PI:
		r += 2.0 * PI
	return r


# Резолвер ключа. Ругается ровно один раз на ключ: place/face/walk_anim зовут его
# каждый кадр, и без словаря отруганных лог залило бы за секунду. Но и молчать
# нельзя — молчание как раз и прятало подмену актёра.
func _fig(who: String) -> Node3D:
	# Забытый build() — это не пустой лог, а фигура, которой в игре просто нет:
	# ai.gd и haunt.gd молча пропускают отсутствующего актёра. Досбор по первому
	# обращению стоит один флаг и снимает целый класс тихих поломок склейки.
	if not built and root != null:
		build()
	if figures.has(who):
		var g: Node3D = figures[who]
		return g
	# До build() фигур нет вовсе: это не ошибка ключа, ругаться не за что.
	if not KEYS.has(who) and not _warned.has(who):
		_warned[who] = true
		push_warning("actors: нет актёра '%s'; есть только threat и echo" % who)
	return null


func _rig(who: String) -> Dictionary:
	if _rigs.has(who):
		var r: Dictionary = _rigs[who]
		return r
	return {}


# Число из opts: ai.gd кладёт туда честные float'ы, но постановочные вызовы
# оригинала обходились и без ключа.
func _num(opts: Dictionary, key: String, def: float) -> float:
	if not opts.has(key):
		return def
	var v: Variant = opts[key]
	if v is float or v is int:
		return float(v)
	return def


# ------------------------------------------------------------------- API ----

# Node3D фигуры или null. Нужен haunt.gd (двойника он ставит сам) и ai.gd
# (курс фигуры он читает у неё же).
func get_actor(who: String) -> Node3D:
	return _fig(who)


func figure(who: String) -> Node3D:
	return _fig(who)


# --------------------------------------------------------------- соседи ----
#
# Лицо и одежда фигуры. Мерка, скелет и походка при этом общие: второй скелет
# ради двух прохожих стоил бы шести лишних компиляций шейдера на загрузке,
# а различают людей в кадре не пропорции, а лицо и цвет телогрейки.

## Своё лицо на фигуру. Ставится ПОВЕРХ общего меша головы, отдельным
## override'ом на поверхность 1 — той самой передней грани, которую _head_mesh()
## отдаёт под текстуру. Нет файла или нет лица у самого меша (assets/face/
## vitya.webp не приехал, голова собралась одной болванкой) — фигура остаётся
## безликой, и это не ошибка: в темноте она читается силуэтом.
func set_face(who: String, tex_path: String) -> bool:
	var r := _rig(who)
	if r.is_empty() or not r.has("head"):
		return false
	var head: MeshInstance3D = r["head"]
	if head.mesh == null or head.mesh.get_surface_count() < 2:
		return false
	if not ResourceLoader.exists(tex_path):
		return false
	var tex := load(tex_path) as Texture2D
	if tex == null:
		return false
	var key := "face:" + tex_path
	if not _kit.has(key):
		_kit[key] = _psx_mat(0xffffff, tex)
	head.set_surface_override_material(1, _kit[key])
	return true


## Одежда. Куртка, штаны и шапка — тремя точными цветами (exact = true):
## притягивать их к палитре реквизита нельзя, фигура и у оригинала шла мимо неё.
func dress(who: String, coat: int, trousers: int, cap_c := -1) -> void:
	var r := _rig(who)
	if r.is_empty():
		return
	var m_coat := _flat(coat)
	var m_legs := _flat(trousers)
	for mi: MeshInstance3D in r.get("coat", []):
		mi.set_surface_override_material(0, m_coat)
	for mi: MeshInstance3D in r.get("trousers", []):
		mi.set_surface_override_material(0, m_legs)
	if cap_c >= 0:
		var head_mat := _flat(cap_c)
		for item: MeshInstance3D in r.get("headwear", []):
			for surface in item.mesh.get_surface_count():
				item.set_surface_override_material(surface, head_mat)


## Голова фигуры в мировых координатах. Нужна соседям: наблюдателя меняют
## только тогда, когда его лица нет в кадре, а «в кадре» считается по лицу,
## а не по ногам.
func face_point(who: String) -> Vector3:
	var a := _fig(who)
	if a == null:
		return Vector3.ZERO
	return a.global_position + Vector3(0.0, float(a.get_meta("face_y", 1.6)), 0.0)


func place(who: String, x: float, y: float, z: float, yaw := 0.0) -> void:
	var a := _fig(who)
	if a == null:
		return
	a.position = Vector3(x, y, z)
	a.rotation = Vector3(0.0, yaw, 0.0)


func show(who: String, on := true) -> void:
	var a := _fig(who)
	if a != null:
		a.visible = on


# show занят у Node/CanvasItem, поэтому ai.gd и haunt.gd зовут фигуру этим
# именем — держим оба, чтобы склейка не зависела от того, кто как вспомнил.
func show_actor(who: String, on := true) -> void:
	show(who, on)


func set_shown(who: String, on := true) -> void:
	show(who, on)


# МГНОВЕННЫЙ доворот. Не удалять и не заменять на face_to: постановочным сценам
# (chapters.gd, haunt.gd) фигуру нужно поставить уже повёрнутой — они выставляют
# её на один кадр, доворачиваться ей негде.
func face(who: String, x: float, z: float) -> void:
	var a := _fig(who)
	if a == null:
		return
	a.rotation = Vector3(0.0, atan2(x - a.position.x, z - a.position.z) + PI, 0.0)


# Плавный доворот, rate радиан в секунду. Обычная ходьба — 3.2, в дверях и на
# развороте зовущий поднимает до 6.0: там фигура должна успеть повернуться
# за полшага, иначе идёт боком.
func face_to(who: String, x: float, z: float, dt: float, rate := 3.2) -> void:
	var a := _fig(who)
	if a == null:
		return
	var want := atan2(x - a.position.x, z - a.position.z) + PI
	var diff := _wrap_pi(want - a.rotation.y)
	var step := maxf(0.0, rate) * maxf(0.0, dt)
	var ry := a.rotation.y
	ry += diff if absf(diff) <= step else signf(diff) * step
	a.rotation = Vector3(0.0, ry, 0.0)


func faceTo(who: String, x: float, z: float, dt: float, rate := 3.2) -> void:
	face_to(who, x, z, dt, rate)


# Походка. opts = { speed, moving, stoop, lookAt/look_at }:
#   speed  — м/с, для веса походки;
#   moving — идёт ли (упёрся в стену — не идёт);
#   stoop  — добавка сутулости в радианах: 0 обычно, +0.22 в подполе и на
#            чердаке, где он не выпрямляется под балками;
#   lookAt — [x, z], куда наводить голову; null — не наводить (во время форы
#            после поимки голову на игрока не наводят).
#
# Второй аргумент — dt. Если кто-то по старой памяти передаст абсолютное время,
# оно упрётся в потолок 0.1 c — походка не сломается, только мгновенно наберёт
# вес.
func walk_anim(who: String, dt: float, opts: Dictionary = {}) -> void:
	var a := _fig(who)
	if a == null or not a.visible:
		return
	var r := _rig(who)
	if r.is_empty():
		return
	var an: Dictionary = r["anim"]
	# Постановочная поза владеет суставами целиком. Place/face и видимость
	# остаются у режиссёра, walk_anim не перетирает захват в следующем кадре.
	if _actions.has(who):
		an["px"] = a.position.x
		an["pz"] = a.position.z
		an["seen"] = false
		return

	var d := clampf(dt, 0.0, 0.1)

	# Расстояние берём по смещению самой фигуры: ai.gd двигает её через place(),
	# и это единственная правда о том, шёл он или упирался в стену. speed*dt
	# нужен только в первом кадре после появления и в сценах, где фигуру
	# двигают мимо place().
	var step := 0.0
	if bool(an["seen"]):
		var sx: float = a.position.x - float(an["px"])
		var sz: float = a.position.z - float(an["pz"])
		step = sqrt(sx * sx + sz * sz)
		if step > TELEPORT:
			step = 0.0   # перенос на этаж игрока — не шаг
	an["seen"] = true
	an["px"] = a.position.x
	an["pz"] = a.position.z

	# speed без ключа — считаем по смещению: ровно ветка `opts.speed !== undefined`
	# оригинала, постановочные сцены двигают фигуру мимо speed.
	var has_speed: bool = opts.has("speed") and (opts["speed"] is float or opts["speed"] is int)
	var sp := 0.0
	if has_speed:
		sp = absf(_num(opts, "speed", 0.0))
	elif d > 0.0:
		sp = step / d

	var mv: Variant = opts.get("moving", null)
	var mv_false := (mv is bool) and not bool(mv)
	if step == 0.0 and sp > 0.05 and not mv_false:
		step = sp * d

	an["dist"] = float(an["dist"]) + step
	an["t"] = float(an["t"]) + d

	var goes := true
	if mv != null:
		goes = bool(mv)
	goes = goes and sp > 0.05
	var target := 1.0 if goes else 0.0
	an["blend"] = float(an["blend"]) + (target - float(an["blend"])) * (1.0 - exp(-d / BLEND_TAU))
	var b: float = an["blend"]

	var ph: float = (float(an["dist"]) / STRIDE) * PI
	var c := cos(ph)
	var breath := sin(float(an["t"]) * PI * 2.0 * BREATH_HZ)

	# Таз. ПРИСВАИВАНИЕ, а не +=. Прежняя строка копила смещение кадр за кадром,
	# и фигура за минуту уползала вверх.
	# Переминание. Своя шкала, а не 1 − blend: походка гаснет за 0.18 с, а вес
	# на другую ногу перекладывают неспешно, и мгновенный переход между ними
	# читался бы как рывок в момент остановки.
	var idle_want := clampf(_num(opts, "idle", 0.0), 0.0, 1.0) * (1.0 - b)
	an["idle"] = float(an.get("idle", 0.0)) \
		+ (idle_want - float(an.get("idle", 0.0))) * (1.0 - exp(-d / SWAY_TAU))
	var sw: float = an["idle"]
	var sway := sin(float(an["t"]) * TAU * SWAY_HZ)

	var body: Node3D = r["body"]
	var bob := -BOB * b * (0.5 + 0.5 * cos(2.0 * ph)) + breath * BREATH_BOB
	body.position = Vector3(SWAY_SHIFT * sw * sway, HIP_Y + bob, 0.0)
	body.rotation = Vector3(0.0, -TWIST * c * b, -ROLL * sin(ph) * b - SWAY_ROLL * sw * sway)

	# Корпус. Противоход вдвое от таза, чтобы в мире плечи ушли ровно на TWIST
	# против него: −T + 2T = +T.
	var stoop := _num(opts, "stoop", 0.0)
	var profile: Dictionary = PROFILES.get(who, {})
	var base_stoop := STOOP * float(profile.get("stoop", 1.0))
	var chest: Node3D = r["chest"]
	chest.rotation = Vector3(-(base_stoop + stoop) + breath * BREATH_ROT, 2.0 * TWIST * c * b, 0.0)

	var legs: Array = r["legs"]
	for i in 2:
		# Правая нога отстаёт на полцикла — отсюда сдвиг фазы на PI.
		var p := ph + float(i) * PI
		var leg: Dictionary = legs[i]
		var hip: Node3D = leg["hip"]
		var knee: Node3D = leg["knee"]
		var ankle: Node3D = leg["ankle"]
		hip.rotation = Vector3(A_HIP * cos(p) * b, 0.0, 0.0)
		# Колено гнётся только назад: max(0, ...) не даёт ноге переломиться.
		knee.rotation = Vector3(-(KNEE_REST + b * A_KNEE * maxf(0.0, -sin(p + KNEE_LEAD))), 0.0, 0.0)
		# При касании носок приподнят, затем стопа мягко прокатывается вперёд.
		# Сустав визуальный: положение фигуры и физическое тело не меняются.
		ankle.rotation = Vector3(A_FOOT_ROLL * b * sin(p - 0.35), 0.0, 0.0)

	var arms: Array = r["arms"]
	for i in 2:
		# Рука ходит в противофазе своей ноге: тот же p, но с минусом.
		var p := ph + float(i) * PI
		var arm: Dictionary = arms[i]
		var shoulder: Node3D = arm["shoulder"]
		var elbow: Node3D = arm["elbow"]
		var side: float = arm["side"]
		shoulder.rotation = Vector3(
			ARM_BIAS - A_SHOULDER * cos(p) * b,
			0.0,
			-side * ARM_TUCK * b * (0.5 + 0.5 * cos(p)))
		elbow.rotation = Vector3(ELBOW_REST + b * (ELBOW_MID - ELBOW_REST - A_ELBOW * cos(p)), 0.0, 0.0)

	# Голова. Отставание головы от корпуса — самый дешёвый признак живого:
	# корпус уже развернулся на новую цель, а голова ещё догоняет. Наводка
	# ограничена шестьюдесятью градусами — дальше человек поворачивается всем
	# корпусом.
	var want := 0.0
	var look := _look_at(opts)
	if look != Vector2.INF:
		var aim := atan2(look.x - a.position.x, look.y - a.position.z) + PI
		want = _wrap_pi(aim - a.rotation.y)
		if want > HEAD_MAX:
			want = HEAD_MAX
		elif want < -HEAD_MAX:
			want = -HEAD_MAX
	elif sw > 0.01:
		# Стоит и никого не высматривает — значит, оглядывается. Не в такт
		# переминанию: две синусоиды одного периода склеились бы в один
		# заводной мах.
		want = SCAN_YAW * sw * sin(float(an["t"]) * TAU * SCAN_HZ + 1.1)
	an["head_yaw"] = float(an["head_yaw"]) + (want - float(an["head_yaw"])) * (1.0 - exp(-d / HEAD_TAU))

	# Голова компенсирует противоход на 0.8: полная компенсация делает шею
	# жёсткой, остаток в 20 % и читается как естественное покачивание.
	var neck: Node3D = r["neck"]
	# Пригибаясь в подполе, он всё равно смотрит вперёд: шея выбирает 0.6
	# добавочной сутулости, иначе в кадре остаётся одна кепка.
	neck.rotation = Vector3(
		NECK_UP + stoop * 0.6 - breath * BREATH_ROT * 0.6,
		float(an["head_yaw"]) - 0.8 * TWIST * c * b,
		0.0)


func walkAnim(who: String, dt: float, opts: Dictionary = {}) -> void:
	walk_anim(who, dt, opts)


## t — секунды от начала текущего этапа; выборка детерминированна, без Tween.
## Переход между этапами сохраняет исходную позу для единственного end_action.
func begin_action(who: String, action: String) -> bool:
	if not ACTIONS.has(action) or _fig(who) == null:
		return false
	var rig := _rig(who)
	if not _actions.has(who):
		var poses: Array = []
		for joint: Node3D in _action_joints(rig):
			poses.append({"joint": joint, "transform": joint.transform})
		var hands: Array = []
		for arm: Dictionary in rig["arms"]:
			var hand: MeshInstance3D = arm["hand"]
			hands.append({"node": hand, "mesh": hand.mesh, "position": hand.position})
		_actions[who] = {"action": action, "poses": poses, "hands": hands, "prop": null}
	_actions[who]["action"] = action
	return true


func _action_joints(rig: Dictionary) -> Array:
	var joints: Array = [rig["body"], rig["chest"], rig["neck"]]
	for leg: Dictionary in rig["legs"]:
		joints.append_array([leg["hip"], leg["knee"], leg["ankle"]])
	for arm: Dictionary in rig["arms"]:
		joints.append_array([arm["shoulder"], arm["elbow"], arm["wrist"]])
	return joints


func sample_action(who: String, action: String, t: float) -> bool:
	if not is_finite(t) or not begin_action(who, action):
		return false
	var rig := _rig(who)
	var body: Node3D = rig["body"]
	var chest: Node3D = rig["chest"]
	var neck: Node3D = rig["neck"]
	var ph := maxf(t, 0.0) * TAU / float(ACTION_TIMING["run"])
	if action == "run":
		_actions[who]["run_phase"] = ph
	elif action == "stop":
		ph = float(_actions[who].get("run_phase", 0.0))
	var running := action == "run" or action == "stop"
	var weight := 1.0 if action == "run" else 1.0 - smoothstep(0.0, 0.28, maxf(t, 0.0))
	if not running:
		weight = 0.0
	body.position = Vector3(0, HIP_Y - 0.027 * weight * (0.5 + 0.5 * cos(2.0 * ph)), 0)
	body.rotation = Vector3(0, -0.07 * cos(ph) * weight, -0.018 * sin(ph) * weight)
	chest.rotation = Vector3(-STOOP - 0.18 * weight, 0.14 * cos(ph) * weight, 0)
	neck.rotation = Vector3(NECK_UP + 0.14 * weight, -0.05 * cos(ph) * weight, 0)
	for i in 2:
		var p := ph + float(i) * PI
		var leg: Dictionary = rig["legs"][i]
		(leg["hip"] as Node3D).rotation = Vector3(0.79 * cos(p) * weight, 0, 0)
		(leg["knee"] as Node3D).rotation = Vector3(-KNEE_REST - 1.04 * maxf(0, -sin(p + 0.35)) * weight, 0, 0)
		(leg["ankle"] as Node3D).rotation = Vector3(0.27 * sin(p - 0.4) * weight, 0, 0)
		var arm: Dictionary = rig["arms"][i]
		(arm["shoulder"] as Node3D).rotation = Vector3(ARM_BIAS - 0.55 * cos(p) * weight,
			0, -float(arm["side"]) * 0.08 * weight)
		(arm["elbow"] as Node3D).rotation = Vector3(ELBOW_REST + (0.85 - 0.13 * cos(p)) * weight, 0, 0)
		(arm["wrist"] as Node3D).rotation = Vector3.ZERO
	var state: Dictionary = _actions[who]
	if running:
		var old_prop: Variant = state.get("prop")
		if is_instance_valid(old_prop):
			(old_prop as Node3D).visible = false
		_restore_action_hands(state)
		return true
	var progress := clampf(maxf(t, 0.0) / (0.65 if action == "shovel_windup" else 0.30), 0, 1)
	var angle: float
	if action == "shovel_windup":
		angle = lerpf(-0.25, -2.25, smoothstep(0.0, 1.0, progress))
	elif action == "shovel_impact":
		angle = lerpf(-2.25, 0.48, smoothstep(0.0, 0.70, progress))
	else:
		angle = lerpf(-0.25, -2.25, smoothstep(0.0, 0.65, t)) if t <= 0.65 \
			else lerpf(-2.25, 0.48, smoothstep(0.65, 0.86, t))
	var impact := clampf((angle + 2.25) / 2.73, 0, 1) if action != "shovel_windup" else 0.0
	chest.rotation = Vector3(lerpf(-0.12, -0.38, impact), 0.06 * (1.0 - impact), 0)
	neck.rotation = Vector3(0.12 + impact * 0.16, 0, 0)
	body.position.y = HIP_Y - impact * 0.035
	for leg: Dictionary in rig["legs"]:
		(leg["knee"] as Node3D).rotation.x = -KNEE_REST - 0.13 * impact
		(leg["hip"] as Node3D).rotation.x = 0.07 * impact
	var prop := attach_prop(who, "shovel")
	if prop == null:
		return false
	prop.visible = true
	prop.position = Vector3(0.025, 0.36 + (1.0 - impact) * 0.065, -0.29)
	prop.rotation = Vector3(angle, 0, -0.13)
	for i in 2:
		var grip := prop.transform * Vector3(0, 0.10 if i == 0 else -0.105, 0)
		_pose_grip(rig["arms"][i], grip, prop.basis)
	return true


## Один визуальный реквизит, который живёт только до end_action; инвентарь
## игрока и физика сцены сюда не входят.
func attach_prop(who: String, kind: String = "shovel") -> Node3D:
	if kind != "shovel" or not _actions.has(who):
		return null
	var state: Dictionary = _actions[who]
	if is_instance_valid(state.get("prop")):
		_set_action_hands(who)
		return state["prop"] as Node3D
	var prop := Node3D.new()
	prop.name = "action-shovel"
	prop.set_meta("action_prop", true)
	var helper: GDScript = load("res://src/detailed_props.gd")
	if not helper.build(mats, {"make": "shovel"}, prop):
		prop.free()
		return null
	(_rig(who)["chest"] as Node3D).add_child(prop)
	state["prop"] = prop
	_set_action_hands(who)
	return prop


func _pose_grip(arm: Dictionary, target: Vector3, grip_basis: Basis) -> void:
	var shoulder: Node3D = arm["shoulder"]
	var elbow: Node3D = arm["elbow"]
	var wrist: Node3D = arm["wrist"]
	var hand: MeshInstance3D = arm["hand"]
	var delta := target - grip_basis * hand.position - shoulder.position
	var distance := clampf(delta.length(), 0.025, UPPER_ARM + SLEEVE - 0.001)
	var axis := delta.normalized()
	var bend := Vector3(-float(arm["side"]), -0.15, 0.1)
	bend = (bend - axis * bend.dot(axis)).normalized()
	var along := (UPPER_ARM * UPPER_ARM - SLEEVE * SLEEVE + distance * distance) / (2.0 * distance)
	var height := sqrt(maxf(0, UPPER_ARM * UPPER_ARM - along * along))
	var hinge := axis * along + bend * height
	shoulder.basis = Basis(Quaternion(Vector3.DOWN, hinge.normalized()))
	var forearm := shoulder.basis.inverse() * (axis * distance - hinge).normalized()
	elbow.basis = Basis(Quaternion(Vector3.DOWN, forearm))
	wrist.basis = (shoulder.basis * elbow.basis).inverse() * grip_basis


func _set_action_hands(who: String) -> void:
	if not _kit.has("grip"):
		var asset := ProceduralAssets.fetch("object/grip")
		if asset.is_empty():
			return
		var mesh := (asset["meshes"][0] as ArrayMesh).duplicate() as ArrayMesh
		mesh.surface_set_material(0, _flat(SKIN))
		_kit["grip"] = mesh
	for arm: Dictionary in _rig(who)["arms"]:
		var hand: MeshInstance3D = arm["hand"]
		hand.mesh = _kit["grip"]
		hand.position = Vector3.ZERO


func _restore_action_hands(state: Dictionary) -> void:
	for hand: Dictionary in state["hands"]:
		if is_instance_valid(hand["node"]):
			var mi: MeshInstance3D = hand["node"]
			mi.mesh = hand["mesh"]
			mi.position = hand["position"]


func end_action(who: String) -> void:
	if not _actions.has(who):
		return
	var state: Dictionary = _actions[who]
	_restore_action_hands(state)
	for pose: Dictionary in state["poses"]:
		if is_instance_valid(pose["joint"]):
			(pose["joint"] as Node3D).transform = pose["transform"]
	var prop: Variant = state.get("prop")
	if is_instance_valid(prop):
		(prop as Node3D).free()
	_actions.erase(who)
	var anim: Dictionary = _rig(who)["anim"]
	anim["seen"] = false
	anim["blend"] = 0.0


# Цель взгляда приходит обоими написаниями: ai.gd кладёт в словарь и lookAt
# (как в оригинале), и look_at. Vector2.INF — «не наводить», это дешевле, чем
# таскать Variant через всю формулу.
func _look_at(opts: Dictionary) -> Vector2:
	var v: Variant = opts.get("lookAt", null)
	if v == null:
		v = opts.get("look_at", null)
	if v == null:
		return Vector2.INF
	if v is Vector2:
		var p: Vector2 = v
		return p
	if v is Array:
		var arr: Array = v
		if arr.size() >= 2:
			return Vector2(float(arr[0]), float(arr[1]))
	return Vector2.INF

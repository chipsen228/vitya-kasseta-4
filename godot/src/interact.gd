# Реестр интерактивных объектов (порт game/interact.js).
#
# В старой версии каждый новый предмет стоил пяти правок в разных местах:
# координаты в POS, ветка в target(), ветка в interact(), ветка в отрисовке,
# запись в marker(). На семидесяти предметах это неотлаживаемо.
#
# Здесь предмет — это один дескриптор:
#
#   {id, pos, r, cone, prompt, when, onUse, look}
#
# а поиск цели, подсказка и применение обслуживают весь список одним циклом.
#
# Отличия от JS вынужденные и мелкие: pos лежит Vector3 (в оригинале массив из
# трёх чисел), а prompt/when/onUse — Callable. Имена полей дескриптора и методов
# оставлены как в оригинале: по ним пишется main.gd (promptFor, find, use, list,
# target, kind, priority).

class_name Interact
extends RefCounted
static var _runtime_ctx: Dictionary = {}

# Точки осмотра, которых нет среди предметов: части дома, тропы, сама тишина.
# Таблица зависит от Y из data/site.json, поэтому собирается в _init(), а не константой.
var extra_looks: Dictionary = {}

var list: Array = []
var target: Variant = null

# Ссылка на ctx. Заводится в registerObjects и нужна ровно одному делу:
# керосинке фазы 11, которую игрок носит с собой. Её лампа обязана ехать
# за ним покадрово, а единственный метод реестра, который зовут каждый кадр, —
# это find().
var ctx_ref: Dictionary = {}

# Кандидаты кадра. Член, а не локальная переменная: find() зовётся каждый кадр,
# и свежий массив на каждый — шестьдесят выделений в секунду впустую.
var _found: Array = []

# Мир коллизий вместо октодерева three.js: им проверяется, не закрыт ли предмет
# стеной или перекрытием. Присваивается снаружи как в оригинале
# (`interact.occluder = col`).
var occluder: CollisionWorld = null


func _init() -> void:
	var y: Dictionary = GameData.site()["Y"]
	var F1 := float(y["FLOOR1"])
	var F2 := float(y["ATTIC"])
	var FC := float(y["CELLAR"])
	extra_looks = {
		"gate": Vector3(0, 0.9, 0.1),
		"wicket": Vector3(3.0, 0.8, 0.1),
		"porch": Vector3(-2.3, 0.6, 5.6),
		"path": Vector3(-6.6, 0.2, 7.4),
		"front-door": Vector3(-2.3, 1.2, 6.45),
		"veranda": Vector3(-3.2, 1.2, 8.2),
		"stairs": Vector3(-5.0, 0.9, 10.1),
		"wire": Vector3(-5.3, F1 + 2.2, 14.2),
		"plate": Vector3(0.62, F1 + 0.9, 11.7),
		"shed": Vector3(6.8, 1.3, 10.6),
		"shed-light": Vector3(6.8, 2.0, 11.4),
		"cellar-cover": Vector3(-7.0, 0.3, 15.7),
		"greenhouse": Vector3(-7.0, 1.0, 21.0),
		"garden": Vector3(0.0, 0.4, 20.6),
		"privy": Vector3(8.6, 1.2, 21.0),
		"street": Vector3(0, 1.4, -3.0),
		"office": Vector3(-30, 1.4, -8.0),
		# Улица за воротами (фаза 9). Точки осмотра прибиты к фасадам домов
		# из data/street.json: сами дома пропами не являются и своей точки
		# осмотра дать не могут.
		"watcher-window": Vector3(5.60, 1.75, -7.30),
		"boarded-house": Vector3(-5.50, 1.60, -7.20),
		"shouter-house": Vector3(-16.00, 1.50, -6.60),
		"arkady-gate": Vector3(15.90, 1.30, -6.60),
		# Мансардная комната деда. Ключ 'vitya' исторический: на нём же висят лампа,
		# выключатель и кровать, переименовывать его дороже, чем помнить про него.
		"vitya-room": Vector3(0.2, F2 + 1.2, 11.6),
		"sealed-door": Vector3(0.6, F2 + 1.1, 13.75),
		"balcony": Vector3(-2.4, F2 + 1.2, 7.0),
		"roof-hatch": Vector3(-4.15, F2 + 2.2, 14.35),
		"cellar-jars": Vector3(-4.5, FC + 0.9, 12.0),
		"mobile": Vector3(1.4, F2 + 0.35, 12.5),
		"dog-bowl": Vector3(6.3, 0.15, 6.6),
		# Картины. Реквизит с этими id висит в props.js, и add_look_targets нашёл бы
		# его сам, но точку осмотра он ставит на 0.7 м выше предмета — то есть под
		# потолок, над рамой. Прибиваем к центрам рам, координаты те же, что у реквизита.
		"pic-vatnik": Vector3(3.70, F1 + 1.24, 12.47),
		"pic-prorub": Vector3(2.25, F1 + 1.395, 16.10),
		"pic-lake-1": Vector3(-1.865, F1 + 1.395, 12.30),
		"pic-lake-2": Vector3(1.065, F1 + 1.395, 9.40),
		# ФАЗА 14. Три осмотра, у которых нет и не будет своего пропа: яблоня
		# растёт из yard.json ORCHARD (это геометрия, а не предмет), бочка
		# у грядок — коробка в SET_OVERLAY, амбар околицы — стены. Без этих
		# трёх строк add_look_targets честно ругался «осмотр без точки».
		"garden-barrel-empty": Vector3(-4.90, 0.90, 19.40),
		# ФАЗА 16, СНТ. Четыре осмотра на весь район — и ни одного задания:
		# обязательная линия сюжета не меняется, здесь только то, что можно
		# найти. Все четыре стоят на геометрии, которую строит snt_world.gd,
		# и это проверяет tests/test_points_visible.gd.
		"snt-sign": Vector3(36.80, 3.70, -34.55),
		"snt-lake": Vector3(-4.00, 0.60, -50.10),
		"snt-booth": Vector3(7.10, 1.30, -70.60),
		"snt-woodshed": Vector3(-15.30, 1.20, -38.80),
	}


func add(def: Dictionary) -> Interact:
	var d: Dictionary = {"r": 2.0, "cone": 0.45, "key": "E", "kind": "use", "priority": 0}
	d.merge(def, true)
	list.append(d)
	return self


# Осмотры: сначала по предметам, у которых есть реплика, потом точки из extra_looks.
#
# Ключ LOOKS без точки и без предмета молча пропадает — ни ошибки, ни
# предупреждения, просто ненаписанная реплика. Поэтому о нём предупреждаем:
# четыре такие строки жили в текстах и не показывались ни разу.
func addLookTargets(props: Props) -> Interact:
	var t := GameData.texts()
	var looks: Dictionary = t["LOOKS"]
	var prompts: Dictionary = t["PROMPTS"]
	for id: String in looks.keys():
		# The orchard creates stable apple-tree-i interactions together with each
		# accepted tree.  LOOKS keeps only their shared text, not a fourth point.
		if id == "apple-tree":
			continue
		# Явный дескриптор с тем же id важнее осмотра — и проверяется ПЕРВЫМ.
		# Прежний порядок ругался «осмотр без точки» на каждую строку LOOKS,
		# у которой есть свой дескриптор и нет пропа: с фазы 9 таких семь
		# (корзина, канистра, журнал, бочка...), и предупреждение о настоящей
		# ненаписанной точке утонуло бы среди них.
		var taken := false
		for d: Dictionary in list:
			if d["id"] == id:
				taken = true
				break
		if taken:
			continue
		var pos: Vector3 = Vector3.ZERO
		var holder: Node3D = null
		if extra_looks.has(id):
			pos = extra_looks[id]
		else:
			holder = props.get_prop(id)
			if holder == null or not props.notes.has(id):
				push_warning("осмотр без точки: " + id)
				continue
			var anchor: Vector3 = props.notes[id]["pos"]
			pos = Vector3(anchor.x, anchor.y + 0.7, anchor.z)
		var def: Dictionary = {
			"id": id,
			"pos": pos,
			"r": 2.4,
			"cone": 0.55,
			"kind": "look",
			"prompt": prompts["look"],
			"priority": -1,
		}
		# Динамический реквизит расставлен с загрузки, но до своей главы невидим,
		# а точка осмотра о видимости ничего не знает. Из-за этого ботинки у щитка
		# осматривались в третьей главе — на пустом полу и за три главы до того,
		# как они там появятся. Осмотр живёт ровно столько, сколько сам предмет.
		if holder != null and props.dynamic_pool.has(id):
			var vis := func(_s) -> bool:
				return holder.visible
			def["when"] = vis
		var line: String = looks[id]
		var on_use := func(c: Dictionary) -> void:
			c["state"].looked[id] = true
			c["ui"].say(line, 4.2)
			_emit(c, "look", id)
		def["onUse"] = on_use
		add(def)
	return self


# Виден ли предмет из точки глаз, или между ними стена, пол, перекрытие.
#
# Семантика та же, что у Threat.ray_static (набор статики, изнутри коробки
# пусто, как у ray_down): своя копия плит здесь однажды разъехалась бы с той,
# по которой охотится дед. Слепок коробок берётся у него же — Threat.static_boxes.
#
# ЧТО ИЗМЕНИЛОСЬ В ФАЗЕ 9 И ЗАЧЕМ. find() стреляет до пяти лучей в кадр,
# и каждый шёл линейным перебором ВСЕХ 311 коробок: ~1555 проверок плит
# на GDScript каждый кадр, 1.2 мс замером bench_frame.gd. Две правки, обе
# на этой стороне (ai.gd неприкосновенен — по нему считается охота):
#
#   1. Отсев по объемлющей коробке отрезка ДО проверки плит. Шесть сравнений
#      против шести делений: предмет и стена в разных концах дома отбрасываются
#      сразу, а таких пар подавляющее большинство.
#   2. Кэш видимости. Заслонить предмет может только геометрия мира, а она
#      не двигается: результат зависит ТОЛЬКО от точки глаз и точки предмета.
#      Значит, пока камера стоит на месте, второй раз считать нечего.
#      Сдвинулась дальше VIS_MOVE — кэш сбрасывается целиком.
const VIS_MOVE := 0.25          # на сколько может сместиться глаз без пересчёта
const VIS_POINT := 0.15         # и сама точка предмета (она едет у соседа)

var _vis: Dictionary = {}       # id -> [видно, позиция предмета]
var _vis_eye := Vector3(1e9, 1e9, 1e9)


func visible(from: Vector3, pos: Vector3, mask: int = CollisionWorld.MASK_STATIC,
		ignore_blocker := "") -> bool:
	if occluder == null:
		return true
	var v := pos - from
	var ln := v.length()
	if ln < 0.05 and mask == CollisionWorld.MASK_STATIC:
		return true
	var dir := v / ln if ln > 1e-9 else Vector3.UP
	var hit := _ray_static(occluder, from, dir, ln) if mask == CollisionWorld.MASK_STATIC \
		else _ray_solid(occluder, from, dir, ln, mask, ignore_blocker)
	if mask == CollisionWorld.MASK_STATIC: return hit == INF or hit > ln - 0.2
	return hit == INF or (hit > 0.0 and hit > ln - 0.002)


## Кэшированный вариант. Ключ — id дескриптора; позиция хранится рядом, потому
## что точка «заговорить» едет за идущим соседом и старый ответ для неё врал бы.
func _visible_cached(id: String, from: Vector3, pos: Vector3, mask: int = CollisionWorld.MASK_STATIC,
		ignore_blocker := "") -> bool:
	# Створки и блокеры меняют активность без перемещения камеры. Проверка
	# бытового действия не использует кэш неподвижной статики.
	if mask != CollisionWorld.MASK_STATIC: return visible(from, pos, mask, ignore_blocker)
	var e: Variant = _vis.get(id, null)
	if e is Array:
		var row: Array = e
		if (row[1] as Vector3).distance_squared_to(pos) <= VIS_POINT * VIS_POINT:
			return bool(row[0])
	var got := visible(from, pos)
	_vis[id] = [got, pos]
	return got


static func _ray_solid(cw: CollisionWorld, from: Vector3, dir: Vector3,
		max_len: float, mask: int, ignore_blocker := "") -> float:
	var best := INF
	var end := from + dir * max_len
	var low := from.min(end)
	var high := from.max(end)
	var data_sets: Array = cw.get("_data")
	var active_sets: Array = cw.get("_active")
	for set_id in CollisionWorld.QUERY_ORDER:
		if (mask & (1 << set_id)) == 0: continue
		var data: PackedFloat64Array = data_sets[set_id]
		var active: PackedByteArray = active_sets[set_id]
		var ignored := PackedInt32Array()
		if not ignore_blocker.is_empty(): ignored = cw._by_id[set_id].get(ignore_blocker, ignored)
		for index in active.size():
			if active[index] == 0: continue
			var o := index * CollisionWorld.STRIDE
			if data[o] > high.x or data[o + 3] < low.x \
					or data[o + 1] > high.y or data[o + 4] < low.y \
					or data[o + 2] > high.z or data[o + 5] < low.z: continue
			if ignored.has(index): continue
			var basis := Basis.IDENTITY
			match int(data[o + 6]):
				CollisionWorld.AXIS_X: basis = Basis(Vector3.RIGHT, -data[o + 7])
				CollisionWorld.AXIS_Y: basis = Basis(Vector3.UP, -data[o + 7])
				CollisionWorld.AXIS_Z: basis = Basis(Vector3.BACK, -data[o + 7])
			var origin := basis * (from - Vector3(data[o + 8], data[o + 9], data[o + 10]))
			var direction := basis * dir
			var near := -INF
			var far := INF
			for axis in 3:
				var half: float = data[o + 11 + axis]
				if absf(direction[axis]) < 1e-10:
					if absf(origin[axis]) > half:
						near = INF
						break
				else:
					var a := (-half - origin[axis]) / direction[axis]
					var b := (half - origin[axis]) / direction[axis]
					near = maxf(near, minf(a, b))
					far = minf(far, maxf(a, b))
			if far >= 0.0 and near <= far and near <= max_len: best = minf(best, maxf(near, 0.0))
	return best


# Луч по статике с отсевом по объемлющей коробке отрезка. Слепок коробок —
# тот же, что у деда (Threat.static_boxes), поэтому расхождению взяться неоткуда.
static func _ray_static(cw: CollisionWorld, from: Vector3, dir: Vector3,
		max_len: float) -> float:
	var boxes := Threat.static_boxes(cw)
	var to := from + dir * max_len
	var lox := minf(from.x, to.x)
	var hix := maxf(from.x, to.x)
	var loy := minf(from.y, to.y)
	var hiy := maxf(from.y, to.y)
	var loz := minf(from.z, to.z)
	var hiz := maxf(from.z, to.z)

	var best := INF
	var n := boxes.size() / 6
	for i in n:
		var o := i * 6
		# Шесть сравнений вместо шести делений. Отбрасывает подавляющее
		# большинство коробок дома, не трогая ни одной, которая могла бы попасть.
		if boxes[o] > hix or boxes[o + 3] < lox:
			continue
		if boxes[o + 1] > hiy or boxes[o + 4] < loy:
			continue
		if boxes[o + 2] > hiz or boxes[o + 5] < loz:
			continue
		var t_near := -INF
		var t_far := INF
		var ok := true
		for a in 3:
			var org := from.x
			var d := dir.x
			if a == 1:
				org = from.y
				d = dir.y
			elif a == 2:
				org = from.z
				d = dir.z
			var lo: float = boxes[o + a]
			var hi: float = boxes[o + 3 + a]
			if absf(d) < 1e-12:
				if org < lo or org > hi:
					ok = false
					break
				continue
			var inv := 1.0 / d
			var t1 := (lo - org) * inv
			var t2 := (hi - org) * inv
			if t1 > t2:
				var tmp := t1
				t1 = t2
				t2 = tmp
			if t1 > t_near:
				t_near = t1
			if t2 < t_far:
				t_far = t2
			if t_near > t_far:
				ok = false
				break
		if not ok or t_near < 0.0 or t_near > t_far:
			continue
		if t_near > max_len or t_near >= best:
			continue
		best = t_near
	return best


# Ближайший объект в конусе взгляда. Явные дескрипторы бьют осмотры.
#
# Кандидаты проверяются на видимость по убыванию оценки: без этого с мансарды
# «осматривались» банки на чердаке сквозь перекрытие, а подсказка люка при этом
# не показывалась — цель есть, значит люка как бы нет.
func find(camera: Camera3D, state: GameState) -> Variant:
	_lantern_tick(state)
	# getWorldDirection() оригинала — минус Z камеры в мировых осях.
	var fwd := (-camera.global_transform.basis.z).normalized()
	var eye := camera.global_position
	# Глаз сдвинулся заметно — прежние ответы о видимости больше не годятся.
	# Поворот головы кэш не сбрасывает: заслоняет предмет геометрия между
	# глазом и предметом, а она от поворота не меняется.
	if eye.distance_squared_to(_vis_eye) > VIS_MOVE * VIS_MOVE:
		_vis_eye = eye
		_vis.clear()

	# Массив переиспользуется: своя копия на каждый кадр — это 60 выделений
	# в секунду на ровном месте.
	_found.clear()
	var order := 0
	for d: Dictionary in list:
		order += 1
		var recovery: Variant = ctx_ref.get("capture")
		if recovery != null and not recovery.allows(String(d.get("id", ""))):
			continue
		if d.has("when") and not bool((d["when"] as Callable).call(state)):
			continue
		_bound_position(d)
		var v: Vector3 = (d["pos"] as Vector3) - eye
		var dist := v.length()
		if dist > float(d["r"]):
			continue
		var dot := (v / (dist if dist > 0.0 else 1.0)).dot(fwd)
		if dot < 1.0 - float(d["cone"]):
			continue
		# Ближе и точнее — лучше; явный дескриптор получает фору.
		_found.append({
			"d": d,
			"score": dot * 2.0 - dist * 0.35 + float(d["priority"]) * 3.0,
			"order": order,
		})

	_found.sort_custom(_by_score)
	var best: Variant = null
	for i in mini(_found.size(), 5):
		var cand: Dictionary = _found[i]
		var def: Dictionary = cand["d"]
		if not _visible_cached(String(def["id"]), eye, def["pos"], int(def.get("los_mask", CollisionWorld.MASK_STATIC)),
				String(def.get("los_ignore_blocker", ""))):
			continue
		best = def
		break
	target = best
	return best


## Керосинка едет за игроком (фаза 11). Отдельного источника ей не нужно:
## она занимает слот того же пула ламп, а при блэкауте домовые лампы погашены
## и оба слота свободны. Пока лампа не зажжена, ничего не делаем — двигать
## выключенный источник значит гонять MultiMesh впустую.
func _lantern_tick(state: GameState) -> void:
	if ctx_ref.is_empty() or state == null or not state.has("lantern-lit"):
		return
	var l: Variant = ctx_ref.get("lights")
	var ctrl: Variant = ctx_ref.get("controls")
	if l == null or ctrl == null or not l.has_method("move_lamp"):
		return
	var f: Vector3 = ctrl.feet()
	l.move_lamp("lantern", Vector3(f.x, f.y + 1.12, f.z))


func promptFor(d: Variant, state: GameState) -> Variant:
	if d == null:
		return null
	var def: Dictionary = d
	var p: Variant = def.get("prompt", null)
	if p is Callable:
		p = (p as Callable).call(state)
	if p == null or String(p) == "":
		return GameData.texts()["PROMPTS"]["look"]
	return p


func use(c: Dictionary) -> bool:
	var d: Variant = target
	if d == null:
		return false
	var def: Dictionary = d
	var recovery: Variant = c.get("capture")
	if recovery != null and not recovery.allows(String(def.get("id", ""))):
		return false
	if def.has("when") and not bool((def["when"] as Callable).call(c["state"])):
		return false
	_bound_position(def)
	if int(def.get("los_mask", CollisionWorld.MASK_STATIC)) != CollisionWorld.MASK_STATIC:
		var renderer: Variant = c.get("renderer")
		if renderer != null and renderer.camera != null \
				and not visible(renderer.camera.global_position, def["pos"], int(def["los_mask"]),
					String(def.get("los_ignore_blocker", ""))):
			return false
	if def.has("onUse"):
		(def["onUse"] as Callable).call(c)
		var director: Variant = c.get("horror")
		if director != null: director.action(String(def.get("id", "")))
	return true


# ---------- служебное ----------

## Предмет остаётся целью и после переноса его модели генератором окружения.
## Вне SceneTree global_position недоступен: тесты собирают мир до его вставки.
static func _bound_position(def: Dictionary) -> Vector3:
	var node: Variant = def.get("target_node")
	if is_instance_valid(node) and node is Node3D:
		if node.is_inside_tree():
			def["pos"] = node.global_position
		else:
			var at: Vector3 = node.position
			var parent: Node = node.get_parent()
			while parent is Node3D:
				at = (parent as Node3D).transform * at
				parent = parent.get_parent()
			def["pos"] = at
	return def["pos"]


# Сортировка стабильная: у JS Array.sort она по стандарту стабильна, а
# sort_custom нет, и на равных оценках цель прыгала бы между кадрами.
func _by_score(a: Dictionary, b: Dictionary) -> bool:
	if a["score"] == b["score"]:
		return int(a["order"]) < int(b["order"])
	return float(a["score"]) > float(b["score"])


static func _emit(c: Dictionary, event: String, payload: Variant = null) -> void:
	var f: Variant = c.get("emit")
	if f is Callable:
		(f as Callable).call(event, payload)


static func _ctx_call(c: Dictionary, name: String, args: Array = []) -> Variant:
	var f: Variant = c.get(name)
	if f is Callable:
		return (f as Callable).callv(args)
	return null


# setTimeout оригинала. Таймер дерева, а не свой цикл: главам и предметам
# нечего обновлять покадрово, и заводить им update() ради двух задержек дорого.
static func _after(seconds: float, cb: Callable) -> void:
	var director: Variant = _runtime_ctx.get("horror")
	if director != null:
		director.after(seconds, cb)
		return
	var loop := Engine.get_main_loop()
	if seconds > 0.0 and loop is SceneTree:
		(loop as SceneTree).create_timer(seconds).timeout.connect(cb)
	else:
		cb.call()


# ------------------------------------------------------------------
# Сюжетные объекты. Порядок — по главам, а не по комнатам:
# так видно, что игрок может сделать в каждый момент.
# ------------------------------------------------------------------

static func registerObjects(I: Interact, c: Dictionary) -> Interact:
	_runtime_ctx = c
	# Ссылка на ctx нужна одному-единственному делу — керосинке, которую игрок
	# носит с собой: её лампу надо двигать покадрово, а единственный метод
	# реестра, который зовут каждый кадр, это find().
	I.ctx_ref = c
	_register_arrive(I, c)
	_register_light(I, c)
	_register_switches(I, c)
	_register_loft(I, c)
	_register_final(I, c)
	_register_street(I, c)
	_register_yard(I, c)
	_register_plot13(I, c)
	_register_home(I, c)
	_register_village(I, c)
	_register_outskirts(I, c)
	_register_snt(I, c)
	_register_valya(I, c)
	return I


# ---------- УЧАСТОК: баня и погреб (фаза 11) ----------
#
# Четыре задания на готовых механизмах: точка Interact -> флаг -> _emit ->
# строка в задаче главы. Голосом они не озвучиваются — на счету ElevenLabs
# около 1700 кредитов, и новые ключи TASKS/BEATS/LOOKS озвучки не требуют.
#
# Предметы стоят на местах с загрузки и невидимы до своего шага, ровно как
# уличные объекты фазы 9. Нет data/yard.json — узлов нет, точки живут, но их
# `when` не проходит: без построек им не за что зацепиться.
static func _register_yard(I: Interact, c: Dictionary) -> void:
	var t := GameData.texts()
	var prompts: Dictionary = t["PROMPTS"]
	var beats: Dictionary = t["BEATS"]
	var looks: Dictionary = t["LOOKS"]

	# --- Q1. Баня, первый заход ---
	var banya_when := func(s: GameState) -> bool:
		return s.atLeast("loft")
	I.add({
		"id": "banya-outside",
		"pos": Vector3(5.00, 1.45, 20.90), "r": 2.60, "cone": 0.45, "priority": 2,
		"prompt": prompts["look"],
		"when": banya_when,
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if not s.has("banya-smoke"):
				s.set_flag("banya-smoke")
				cc["ui"].say(String(beats.get("banyaSmoke", "")), 4.4)
				_emit(cc, "banya-smoke")
			else:
				cc["ui"].say(String(looks.get("banya-outside", "")), 3.4),
	})

	I.add({
		"id": "banya-stove",
		"pos": Vector3(3.52, 1.10, 24.02), "r": 1.70, "cone": 0.50, "priority": 3,
		"prompt": prompts["look"],
		"when": banya_when,
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if s.has("banya-second"):
				cc["ui"].say(String(beats.get("polokWarm", "")), 3.6)
				return
			if not s.has("banya-stove"):
				s.set_flag("banya-stove")
				s.set_flag("banya-seen")
				cc["audio"].heartbeat(2, 96)
			cc["ui"].say(String(beats.get("banyaStove", "")), 4.0)
			_emit(cc, "banya-stove"),
	})

	I.add({
		"id": "banya-clothes",
		"pos": Vector3(3.23, 0.68, 22.35), "r": 1.60, "cone": 0.50, "priority": 3,
		"prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			return s.atLeast("loft") and not s.has("banya-clothes"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("banya-clothes")
			s.set_flag("banya-seen")
			cc["ui"].say(String(beats.get("banyaClothes", "")), 4.2)
			_emit(cc, "banya-clothes"),
	})

	var key_node := _yard_node(c, "cellar-shed-key")
	var key_target := {"pos": Vector3(5.67, 1.54, 21.38), "target_node": key_node}
	var key_pos := _bound_position(key_target)
	I.add({
		"id": "banya-key-inspect", "pos": key_pos, "target_node": key_node,
		"r": 1.55, "cone": 0.50, "priority": 3, "kind": "look",
		"los_mask": CollisionWorld.ALL_SOLID, "prompt": "осмотреть ключ",
		"when": func(s: GameState) -> bool:
			return s.atLeast("loft") and not s.has("banya-written") \
				and not s.hasItem("cellar-shed-key"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			var line := "На бирке — «погреб». Сначала растоплю баню: дрова у поленницы."
			if s.has("banya-hot"):
				line = "На запотевшем окне проступили буквы. Прочитаю, прежде чем брать ключ."
			elif s.has("damper-shut"):
				line = "Ключ от погреба. Баня ещё греется. Вернусь к окну, когда выступит пар."
			elif s.has("banya-fired"):
				line = "На бирке — «погреб». Надо прикрыть заслонку у печи, иначе баня не прогреется."
			cc["ui"].say(line, 4.2),
	})
	I.add({
		"id": "banya-key", "pos": key_pos, "target_node": key_node,
		# До чтения окна осмотр уступает ему; после чтения подбор получает приоритет.
		"r": 1.55, "cone": 0.50, "priority": 6,
		"los_mask": CollisionWorld.ALL_SOLID,
		"prompt": prompts["take"],
		"when": func(s: GameState) -> bool:
			return s.has("banya-written") and not s.hasItem("cellar-shed-key"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.give("cellar-shed-key")
			s.set_flag("banya-seen")
			_yard_show(cc, "cellar-shed-key", false)
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Ключ с биркой «погреб»")
			cc["ui"].say(String(beats.get("banyaKey", "")), 4.0)
			_emit(cc, "banya-key"),
	})

	# --- Q2. Погреб ---
	#
	# Дверь закрывается за игроком САМА, и открывается со второго раза. Первый
	# отказ — один из двух полнокадровых ударов фазы: третьего инструмент
	# не выдерживает, на четвёртом применении за игру он перестаёт работать
	# вовсе.
	var shed_prompt := func(s: GameState) -> String:
		if s.has("cellar-shed-open") and not s.has("shed-door-shut"):
			return prompts["look"]
		return prompts["open"] if s.hasItem("cellar-shed-key") else prompts["locked"]
	var shed_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if s.has("shed-door-shut"):
			# Заело. Ровно один раз — и с ударом.
			s.set_flag("shed-door-shut", false)
			s.set_flag("shed-door-stuck")
			cc["audio"].sfx("door-close")
			cc["ui"].say(String(beats.get("shedShut", "")), 3.6)
			_hit_full(cc)
			return
		if s.has("cellar-shed-open"):
			# ФАЗА 17, ТУПИК. Дверь, которую заело, обязана открыться СО ВТОРОГО
			# РАЗА — ровно так, как обещает комментарий выше. Кода на это не
			# было ни строчки: ветка говорила описание двери и выходила, а
			# блокер 'door-cellar-shed' оставался активным. Игрок, взявший
			# керосинку, запирался в погребе НАВСЕГДА: выхода нет, [R] работает
			# только с экрана провала, отладочный прыжок — только из
			# командной строки.
			#
			# tests/test_reachable.gd к этому слеп по построению: он гасит все
			# блокеры разом перед заливкой. Сторожит tests/smoke_plot.gd.
			var col: Variant = cc.get("col")
			if col != null and bool(col.is_blocker_active("door-cellar-shed")):
				_yard_door(cc, true)
				cc["audio"].door(true)
				cc["ui"].say(String(beats.get("shedOpen", "")), 3.0)
				return
			cc["ui"].say(String(looks.get("cellar-shed-door", "")), 3.4)
			return
		if not s.hasItem("cellar-shed-key"):
			cc["ui"].say(String(beats.get("shedLocked", "")), 3.4)
			return
		s.set_flag("cellar-shed-open")
		_yard_door(cc, true)
		cc["audio"].door(true)
		cc["ui"].say(String(beats.get("shedOpen", "")), 3.6)
		_emit(cc, "cellar-shed-open")
	I.add({
		"id": "cellar-shed-door",
		"pos": Vector3(-5.55, 1.05, 2.30), "r": 2.20, "priority": 4,
		"prompt": shed_prompt,
		"when": func(s: GameState) -> bool:
			return s.atLeast("loft"),
		"onUse": shed_use,
	})

	I.add({
		"id": "shed-jars",
		"pos": Vector3(-8.60, 0.95, 1.30), "r": 1.80, "cone": 0.50, "priority": 2,
		"prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			return s.has("cellar-shed-open"),
		"onUse": func(cc: Dictionary) -> void:
			cc["ui"].say(String(looks.get("shed-jars", "")), 3.4),
	})
	I.add({
		"id": "shed-rope",
		"pos": Vector3(-7.35, 1.35, 2.35), "r": 1.80, "cone": 0.50, "priority": 2,
		"prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			return s.has("cellar-shed-open"),
		"onUse": func(cc: Dictionary) -> void:
			cc["ui"].say(String(looks.get("shed-rope", "")), 3.4),
	})

	I.add({
		"id": "shed-lantern",
		"pos": Vector3(-8.61, 1.08, 3.62), "r": 1.60, "cone": 0.45, "priority": 4,
		"prompt": prompts["take"],
		"when": func(s: GameState) -> bool:
			return s.has("cellar-shed-open") and not s.hasItem("lantern"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.give("lantern")
			_yard_show(cc, "cellar-shed-lantern", false)
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Керосиновая лампа")
			cc["ui"].say(String(beats.get("lanternTaken", "")), 3.6)
			_emit(cc, "lantern")
			# Дверь закрывается, пока игрок стоит к ней спиной. Беззвучно:
			# услышанный хлопок объяснил бы её, а необъяснённая она и работает.
			_after(2.2, func() -> void:
				var st: GameState = cc["state"]
				if st.has("shed-door-seen"):
					return
				st.set_flag("shed-door-seen")
				st.set_flag("shed-door-shut")
				_yard_door(cc, false)),
	})

	# --- Q4. Керосинка зажигается от каменки, на втором заходе в баню ---
	I.add({
		"id": "lantern-light",
		"pos": Vector3(3.52, 1.34, 23.80), "r": 1.70, "cone": 0.50, "priority": 5,
		"prompt": "зажечь лампу",
		"when": func(s: GameState) -> bool:
			return s.hasItem("lantern") and not s.has("lantern-lit"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("lantern-lit")
			var l: Variant = cc["lights"]
			if l != null:
				l.setLamp("lantern", true)
			cc["audio"].sfx("lamp-on")
			cc["ui"].say(String(beats.get("lanternLit", "")), 3.4)
			_emit(cc, "lantern-lit"),
	})

	# --- Q3. Мокрые следы. Только осмотр, без предмета ---
	I.add({
		"id": "wet-steps",
		"pos": Vector3(-2.30, 0.22, 4.20), "r": 2.20, "cone": 0.55, "priority": 3,
		"prompt": prompts["look"],
		# ФАЗА 13: следов нет, если баню никто не топил. Осмотр несуществующих
		# следов был бы худшим, что может случиться с этой сценой.
		"when": func(s: GameState) -> bool:
			return s.has("blackout") and s.has("banya-fired") and not s.has("wet-steps"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("wet-steps")
			cc["audio"].heartbeat(3, 100)
			cc["ui"].say(String(beats.get("wetSteps", "")), 4.6)
			_emit(cc, "wet-steps"),
	})

	# Выключатель бани. Строка в общей таблице выключателей не годится:
	# у бани нет своего щитка, и «щёлкает вхолостую» здесь читалось бы враньём.
	I.add({
		"id": "sw-banya",
		"pos": Vector3(4.72, 1.47, 21.40), "r": 1.50, "cone": 0.50, "priority": 1,
		"prompt": func(_s) -> String:
			return prompts["switchOff"] if bool(c["lights"].isOn("banya")) \
				else prompts["switchOn"],
		"when": banya_when,
		"onUse": func(cc: Dictionary) -> void:
			var l: Variant = cc["lights"]
			if l == null:
				return
			if not bool(l.powerOn):
				cc["audio"].sfx("switch-dead")
				cc["ui"].say("Щёлкает вхолостую. Света нет.", 2.6)
				return
			var on := bool(l.toggleLamp("banya"))
			cc["audio"].click()
			if on:
				cc["audio"].sfx("lamp-on")
			_emit(cc, "switch", {"lamp": "banya", "on": on}),
	})


# ---------- УЧАСТОК: баня, яблони, клопы (фаза 13) ----------
#
# Три задания на трёх разных главах, и порядок не декоративный:
#
#   СВЕТ     banya   — дрова из поленницы -> каменка. Рутина, и ровно из неё
#                      растёт всё остальное: МОКРЫЕ СЛЕДЫ от бани к крыльцу,
#                      построенные ещё в фазе 11, до сих пор включались просто
#                      так. Теперь их включает игрок сам — вымылся в бане не он.
#   ПЛЁНКИ   apples  — обтрясти три яблони. Просьба Петра, и она же строчка
#                      из записки на кухне: «× яблоки собрать».
#   ТЕМНОТА  bugs    — Витя орёт с огорода, что мраморный клоп сожрал всё.
#                      Опрыскиватель (предбанник) -> яд (погреб) -> бочка ->
#                      три грядки. На ТРЕТЬЕЙ земля идёт полосой — та же
#                      полоса, что в кассете «ОГОРОД», и это первый из двух
#                      полнокадровых ударов фазы.
#
# Ни одна ступень не запирает главу: все три необязательны, и все три
# появляются в строке задачи только после того, как игрок сам их начал.
# Головоломка, не связанная с историей, ломает страх — поэтому здесь нет
# ни одной головоломки, а есть три бытовых поручения, каждое из которых
# кончается тем, чего игрок не заказывал.
static func _register_plot13(I: Interact, c: Dictionary) -> void:
	var t := GameData.texts()
	var prompts: Dictionary = t["PROMPTS"]
	var beats: Dictionary = t["BEATS"]
	var looks: Dictionary = t["LOOKS"]
	var yard: Dictionary = YardWorld.data()
	var garden: Dictionary = yard.get("GARDEN", {})
	var orchard: Dictionary = yard.get("ORCHARD", {})

	_plot_banya(I, prompts, beats, looks, garden)
	_plot_apples(I, prompts, beats, looks, orchard)
	_plot_bugs(I, prompts, beats, looks, garden)


# --- СВЕТ: истопить баню -----------------------------------------------------

static func _plot_banya(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary, garden: Dictionary) -> void:
	var wd: Array = garden.get("wood", [1.62, 2.58, 22.90, 25.60])
	var wx := (float(wd[0]) + float(wd[1])) / 2.0
	var wz := (float(wd[2]) + float(wd[3])) / 2.0

	I.add({
		"id": "woodpile",
		"pos": Vector3(wx + 0.70, 0.85, wz), "r": 2.20, "cone": 0.50, "priority": 3,
		"prompt": func(s: GameState) -> String:
			return prompts["look"] if s.hasItem("firewood") else prompts["take"],
		"when": func(s: GameState) -> bool:
			return s.atLeast("light") and not s.has("banya-fired"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if s.hasItem("firewood"):
				cc["ui"].say(String(looks.get("woodpile", "")), 3.4)
				return
			s.give("firewood")
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Охапка дров")
			cc["ui"].say(String(beats.get("woodTaken", "")), 3.2)
			_emit(cc, "firewood"),
	})

	# Каменка. Своя точка, а не ветка в banya-stove: тот осмотр принадлежит
	# фазе 11 и говорит про золу, которой «два дня». Смешивать «топлю сам»
	# и «топил кто-то до меня» в одной точке значит стереть и то, и другое.
	I.add({
		"id": "banya-fire",
		"pos": Vector3(3.52, 0.95, 24.30), "r": 1.80, "cone": 0.50, "priority": 5,
		"prompt": "затопить каменку",
		"when": func(s: GameState) -> bool:
			return s.atLeast("light") and not s.has("banya-fired"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if not s.hasItem("firewood"):
				cc["ui"].say(String(beats.get("banyaNoWood", "")), 3.4)
				return
			s.set_flag("banya-fired")
			s.set_flag("banya-seen")
			cc["audio"].sfx("lamp-on")
			cc["ui"].say(String(beats.get("banyaFired", "")), 3.6)
			_emit(cc, "banya-fired"),
	})

	# ПОЛНОКАДРОВЫЙ УДАР №1 ФАЗЫ. Запотевшее окно бани, и на полке кто-то
	# сидит. Стоит на ТЕМНОТЕ и только после того, как баню истопил сам игрок:
	# бить по окну холодной бани нечем — стекло не потеет.
	I.add({
		"id": "banya-window",
		"pos": Vector3(2.60, 1.50, 22.30), "r": 2.00, "cone": 0.50, "priority": 5,
		"prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			# Once the plot steam is ready this optional first look is replaced by
			# outskirts_quest's banya-steam descriptor at the same pane.
			return s.has("banya-fired") and s.atLeast("dark") and not s.has("banya-hot"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if s.has("banya-fogged"):
				cc["ui"].say(String(looks.get("banya-window", "")), 3.2)
				return
			s.set_flag("banya-fogged")
			cc["ui"].say(String(beats.get("banyaFogged", "")), 4.4)
			_dark_vitya_line(cc, "plot-3")
			_hit_full(cc)
			_emit(cc, "banya-fogged"),
	})


# --- ПЛЁНКИ: обтрясти яблони -------------------------------------------------

static func _plot_apples(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary, orchard: Dictionary) -> void:
	var trees: Array = orchard.get("trees", [])
	var resolved := YardWorld.resolved_orchard(orchard)
	for i in trees.size():
		if not resolved.has(i):
			continue
		var tree: Dictionary = resolved[i]
		var id := "apple-tree-%d" % i
		var flag := "apple-picked-%d" % i
		I.add({
			"id": id,
			"pos": Vector3(float(tree["x"]), 1.30, float(tree["z"])), "r": 2.40, "cone": 0.50,
			"priority": 2,
			"prompt": func(s: GameState) -> String:
				return prompts["look"] if s.has(flag) else "обтрясти",
			"when": func(s: GameState) -> bool:
				return s.atLeast("light"),
			"onUse": func(cc: Dictionary) -> void:
				var s: GameState = cc["state"]
				if s.has(flag):
					cc["ui"].say(String(looks.get("apple-tree", "")), 3.2)
					return
				s.set_flag(flag)
				_yard_show(cc, "apples-%d" % i, false)
				cc["audio"].creak(0.28)
				if _apples_picked(s) >= 3:
					s.set_flag("apples-done")
					cc["ui"].say(String(beats.get("applesDone", "")), 3.6)
				else:
					cc["ui"].say(String(beats.get("applePicked", "")), 2.8)
				_emit(cc, "apple-picked", id),
		})


## Сколько яблонь уже обтрясли. Дубль условия живёт в chapters.gd — там оно
## решает, снимать ли строку задачи, здесь — говорить ли «хватит».
static func _apples_picked(s: GameState) -> int:
	var n := 0
	for i in 4:
		if s.has("apple-picked-%d" % i):
			n += 1
	return n


# --- ТЕМНОТА: клопы ----------------------------------------------------------

static func _plot_bugs(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary, garden: Dictionary) -> void:
	I.add({
		"id": "sprayer",
		"pos": _v3(garden, "sprayer", Vector3(3.23, 0.52, 22.40)) + Vector3(0, 0.24, 0),
		"r": 1.70, "cone": 0.50, "priority": 4,
		"prompt": prompts["take"],
		"when": func(s: GameState) -> bool:
			return s.has("bugs-heard") and not s.hasItem("sprayer"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.give("sprayer")
			_yard_show(cc, "sprayer", false)
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Опрыскиватель")
			cc["ui"].say(String(beats.get("sprayerTaken", "")), 3.6)
			_emit(cc, "sprayer"),
	})

	I.add({
		"id": "poison",
		"pos": _v3(garden, "poison", Vector3(-8.59, 1.36, 2.71)) + Vector3(0.10, 0.14, 0),
		"r": 1.70, "cone": 0.50, "priority": 4,
		"prompt": prompts["take"],
		"when": func(s: GameState) -> bool:
			return s.has("bugs-heard") and s.has("cellar-shed-open") \
				and not s.hasItem("poison"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.give("poison")
			_yard_show(cc, "poison", false)
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Бутыль с ядом")
			cc["ui"].say(String(beats.get("poisonTaken", "")), 3.6)
			_emit(cc, "poison"),
	})

	var bp := _v3(garden, "barrel", Vector3(-4.90, 0.0, 19.40))
	I.add({
		"id": "spray-barrel",
		"pos": bp + Vector3(0, 0.95, 0), "r": 2.00, "cone": 0.50, "priority": 4,
		"prompt": func(s: GameState) -> String:
			return prompts["look"] if s.has("spray-mixed") else "развести",
		# ФАЗА 15. К главе ДЕРЕВНЯ эта точка ГАСНЕТ, и её место занимает
		# осмотр 'garden-barrel-empty' из LOOKS — тот самый, флаг которого
		# до фазы 17 открывал всю околицу (гейт chapters._watering_started;
		# с фазы 17 полив обязателен, и гейта нет).
		#
		# До фазы 15 они стояли одна в другой: осмотр приходит из
		# addLookTargets() с приоритетом −1, бочка — с 4, и в кольце шириной
		# 40 см бочка выигрывала ВСЕГДА. Игрок видел ту же реплику, флага
		# не получал, и вход в цепочку полива был закрыт наглухо. Отдавать
		# точку целиком дешевле, чем держать две копии одной реплики: строка
		# у них и так одна и та же.
		"when": func(s: GameState) -> bool:
			return s.has("bugs-heard") and not s.atLeast("village"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if s.has("spray-mixed"):
				cc["ui"].say(String(looks.get("spray-barrel", "")), 3.0)
				return
			if not (s.hasItem("poison") and s.hasItem("sprayer")):
				cc["ui"].say(String(beats.get("mixNoParts", "")), 3.4)
				return
			s.set_flag("spray-mixed")
			_yard_mix(cc, true)
			cc["audio"].sfx("item-take")
			cc["ui"].say(String(beats.get("mixed", "")), 3.4)
			_dark_vitya_line(cc, "plot-2")
			_emit(cc, "spray-mixed"),
	})

	var rows: Array = garden.get("rows", [])
	for i in rows.size():
		var row: Variant = rows[i]
		if not (row is Array) or (row as Array).size() != 3:
			continue
		var a: Array = row
		var flag := "sprayed-%d" % i
		var last := i == rows.size() - 1
		I.add({
			"id": "garden-row-%d" % i,
			"pos": Vector3(float(a[0]), float(a[1]) + 1.05, float(a[2])),
			"r": 2.20, "cone": 0.50, "priority": 3,
			"prompt": "опрыскать",
			# ФАЗА 17. Потолок по главе — тот же, что у бочки строкой выше
			# (spray-barrel, 'not s.atLeast("village")'), и по той же причине,
			# только цена другая. У последней грядки стоит полнокадровый удар,
			# а гейта главы у точки не было вовсе: в ДЕРЕВНЮ он переезжал
			# четвёртым, поверх трёх обязательных. Сторожит
			# tests/test_scares_budget.gd, раздел «протечка».
			"when": func(s: GameState) -> bool:
				return s.has("spray-mixed") and not s.has(flag) \
					and not s.atLeast("village"),
			"onUse": func(cc: Dictionary) -> void:
				var s: GameState = cc["state"]
				s.set_flag(flag)
				cc["audio"].sfx("item-take")
				if not _rows_done(s, rows.size()):
					cc["ui"].say(String(beats.get("sprayed", "")), 2.2)
					_emit(cc, "sprayed", flag)
					return
				s.set_flag("bugs-done")
				cc["ui"].say(String(beats.get("sprayedAll", "")), 3.4)
				_emit(cc, "bugs-done")
				if not last:
					return
				# ПОЛНОКАДРОВЫЙ УДАР №2 ФАЗЫ. Земля идёт полосой из-под третьей
				# грядки — той же полосой, что на кассете «ОГОРОД» уходит к бане.
				# Ставится на последнюю грядку, а не на случайную: игрок к этой
				# минуте уже посмотрел кассету и знает, чем это кончилось.
				_after(1.4, func() -> void:
					cc["ui"].say(String(beats.get("bugsEarth", "")), 4.2)
					_hit_full(cc)
					_emit(cc, "bugs-earth")),
		})

	# Гэги-осмотры. Ни флага, ни события: они существуют, чтобы игрок
	# посмеялся, — и ровно поэтому не готов к тому, что будет через минуту.
	var gags := [
		["sorrel-bald", _v3(garden, "bald", Vector3(-3.20, 0.02, 22.60)) + Vector3(0, 0.55, 0), 2.4],
		["garden-bug", _v3(garden, "bug", Vector3(-1.80, 0.34, 24.90)) + Vector3(0, 0.30, 0), 1.6],
		["loft-doll", Vector3(-4.10, 6.30, 10.85), 2.2],
	]
	for row: Array in gags:
		var id: String = row[0]
		var line := String(looks.get(id, ""))
		if line == "":
			continue
		I.add({
			"id": id,
			"pos": row[1], "r": float(row[2]), "cone": 0.55, "kind": "look",
			"priority": 1,
			"prompt": prompts["look"],
			"when": func(s: GameState) -> bool:
				return s.atLeast("light"),
			"onUse": func(cc: Dictionary) -> void:
				(cc["state"] as GameState).looked[id] = true
				cc["ui"].say(line, 4.2)
				_emit(cc, "look", id),
		})


static func _rows_done(s: GameState, n: int) -> bool:
	for i in n:
		if not s.has("sprayed-%d" % i):
			return false
	return true


## Раствор в бочке. Отдельный ребёнок узла: бочка стоит с загрузки, а налитое
## в ней обязано появиться ровно в ту минуту, когда игрок его развёл.
static func _yard_mix(c: Dictionary, on: bool) -> void:
	var n := _yard_node(c, "spray-barrel")
	if n == null:
		return
	var mix := n.get_node_or_null("mix")
	if mix is Node3D:
		(mix as Node3D).visible = on


## Реплика деда с участка. ЕДИНСТВЕННОЕ место в этом файле, где вообще
## зовётся его голос, — и имя у него начинается с `_dark` не для красоты:
## tests/test_voice_manifest._check_vitya_timing() читает исходники из VITYA_SRC
## как ТЕКСТ и требует разрешённого префикса у функции, в которой стоит вызов.
##
## Правило за этим одно — «до 23:40 ни одного акцента», — и здесь оно вдобавок
## проверяется на рантайме: глава сверяется явно, а не подразумевается именем.
## Наврать самому себе именем функции таким образом нельзя.
##
## В имени обёртки нарочно НЕТ подстроки «say_vitya»: иначе сторож считал бы
## каждый её вызов вызовом голоса и ругался на функции заданий, в которых
## никакого голоса нет.
static func _dark_vitya_line(c: Dictionary, name: String) -> void:
	var s: GameState = c["state"]
	if not s.atLeast("dark"):
		return
	var v: Variant = c.get("voice")
	if v == null:
		return
	v.say_vitya_key(name, 11.0, 0.0)


static func _v3(d: Dictionary, key: String, def: Vector3) -> Vector3:
	var a: Array = d.get(key, [])
	if a.size() != 3:
		return def
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


# ------------------------------------------------------ откат видимости -----
#
# ФАЗА 18. Подбор гасит холдер предмета, а GameState.restore() откатывает
# только флаги и инвентарь: видимость узлов в снимок не входит и входить
# не может — снимок это JSON, а холдеры это узлы сцены.
#
# Пока чекпоинт стоял один на главу, расхождения не было видно: откат уходил
# в точку, где ещё ничего не взято. Задачный чекпоинт фазы 18 делает его
# правилом — любой предмет, взятый ПОСЛЕ последней смены задачи, после [R]
# исчезал и из мира, и из рук, то есть переставал существовать.
#
# Обе таблицы читаются от СОСТОЯНИЯ («видно тогда, когда не взято»), а не от
# события. Поэтому они одинаково чинят и откат назад, и повтор вперёд, и не
# зависят от того, сколько раз игрок умер между.

## Пропсы дома: id холдера в props.json → предмет инвентаря, который его гасит.
const RESYNC_PROPS := {
	"trunk-flashlight": "flashlight",
	"tape-1": "tape-1",
	"tape-2": "tape-2",
	"tape-3": "tape-3",
	"tape-5": "tape-5",
	"stepladder": "ladder",
}

## Узлы участка (world.yard.nodes) — тем же способом.
const RESYNC_YARD := {
	"cellar-shed-key": "cellar-shed-key",
	"cellar-shed-lantern": "lantern",
	"sprayer": "sprayer",
	"poison": "poison",
}


## Вернуть в мир то, что подбор погасил, а откат не вернул. Зовётся из
## Chapters.retry() сразу после state.restore() и строго ДО go(): модули глав
## досматривают свои узлы в enter()/resync() и обязаны видеть уже откатанные флаги.
static func resync_world(c: Dictionary) -> void:
	var sv: Variant = c.get("state")
	if not (sv is GameState):
		return
	var s: GameState = sv
	var props: Variant = c.get("props")
	if props != null:
		for id: String in RESYNC_PROPS:
			var n: Variant = props.get_prop(id)
			if n is Node3D:
				(n as Node3D).visible = not s.hasItem(String(RESYNC_PROPS[id]))
	for id: String in RESYNC_YARD:
		_yard_show(c, id, not s.hasItem(String(RESYNC_YARD[id])))
	# Яблоки гасятся не предметом, а флагом на дерево: их три, и каждое своё.
	# Число берётся из data/yard.json, а не из константы: сад там и живёт.
	var orchard: Dictionary = (YardWorld.data() as Dictionary).get("ORCHARD", {})
	var trees: Array = orchard.get("trees", [])
	for i in trees.size():
		_yard_show(c, "apples-%d" % i, not s.has("apple-picked-%d" % i))
	# Дальше — модули глав: у каждого свой словарь узлов, чужому коду
	# недоступный. Метод необязателен, отсутствие — не ошибка.
	for key: String in ["village", "outskirts", "valya", "snt", "everyday"]:
		var m: Variant = c.get(key)
		if m != null and m.has_method("resync"):
			m.call("resync", s)


## Показать или спрятать предмет участка. Нет data/yard.json — тихо ничего.
static func _yard_show(c: Dictionary, id: String, on: bool) -> void:
	var n := _yard_node(c, id)
	if n != null:
		n.visible = on


static func _yard_node(c: Dictionary, id: String) -> Node3D:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return null
	var yard: Dictionary = (w as Dictionary).get("yard", {})
	var n: Variant = (yard.get("nodes", {}) as Dictionary).get(id)
	return n if n is Node3D else null


## Створка погреба: поворот полотна плюс гашение коробки в четвёртом наборе.
## Своего блокера в built.blockers у неё нет — она живёт в SET_OVERLAY.
static func _yard_door(c: Dictionary, open: bool) -> void:
	var col: Variant = c.get("col")
	if col != null:
		col.set_blocker_active("door-cellar-shed", not open)
	var ph: Variant = c.get("physics")
	if ph != null:
		ph.sync()
	var leaf := _yard_node(c, "cellar-shed-door")
	if leaf != null:
		leaf.rotation.y = -1.45 if open else 0.0


## Полнокадровый удар. Ровно два таких на всю фазу: заевшая дверь погреба
## и второй заход в баню. Выключенные резкие эффекты его не отменяют —
## остаётся удар без лица, та же развилка, что у chapters._hit().
static func _hit_full(c: Dictionary) -> void:
	var director: Variant = c.get("horror")
	if director == null: return
	var s: GameState = c["state"]
	var id := "tin-local-return"
	var sound := "horror-tin"
	if s.has("banya-steam") or s.has("banya-written") or s.has("banya-second"):
		id = "bath-wall-return"
		sound = "horror-window-hit"
	elif s.has("pit-behind"):
		id = "pit-local-movement"
		sound = "horror-wet-steps"
	director.context(id, sound)

# ---------- УЛИЦА и фотографии (фаза 9) ----------
#
# Точки живут в своих модулях: улица — в street_quest.gd, рамки — в photos.gd.
# Здесь только вызов, чтобы порядок регистрации остался один на всю игру:
# явные дескрипторы обязаны попасть в список ДО addLookTargets(), иначе осмотр
# из LOOKS займёт их id и заберёт [E] себе.
static func _register_street(I: Interact, c: Dictionary) -> void:
	Photos.register(I, c)
	var q: Variant = c.get("street")
	if q != null:
		q.register(I)


# ---------- ДЕРЕВНЯ (фаза 12) ----------
#
# VillageQuest заводится ЗДЕСЬ, а не в main.gd: тот принадлежит lead и в этой
# фазе не правится. Всё, что модулю нужно, к этому моменту в ctx уже лежит —
# мир (built.village), состояние, свет, физика и дед на линии.
# Тик у него один и идёт из Chapters.update().
static func _register_village(I: Interact, c: Dictionary) -> void:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return
	var village: Dictionary = (w as Dictionary).get("village", {})
	if village.is_empty():
		return
	var q := VillageQuest.new(c, village)
	c["village"] = q
	q.register(I)


# ---------- ОКОЛИЦА: полив (фаза 14) ----------
#
# OutskirtsQuest заводится ЗДЕСЬ, тем же контрактом, что VillageQuest выше:
# мир (built.outskirts) собран заранее, у модуля свой register(I) и своего
# тика ему не нужно — все задержки идут через Interact._after().
static func _register_outskirts(I: Interact, c: Dictionary) -> void:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return
	var outskirts: Dictionary = (w as Dictionary).get("outskirts", {})
	if outskirts.is_empty():
		return
	var q := OutskirtsQuest.new(c, outskirts)
	c["outskirts"] = q
	q.register(I)


# ---------- ЛИНИЯ ВАЛИ (фаза 15) ----------
#
# ValyaQuest заводится тем же контрактом, что VillageQuest и OutskirtsQuest:
# мир (built.valya) собран заранее, у модуля свой register(I), своего тика
# ему не нужно — все задержки идут через Interact._after().
static func _register_snt(I: Interact, c: Dictionary) -> void:
	var world: Variant = c.get("world")
	if not (world is Dictionary):
		return
	var snt: Dictionary = world.get("snt", {})
	if snt.is_empty():
		return
	var quest := SntQuest.new(c, snt)
	c["snt"] = quest
	quest.register(I)


static func _register_valya(I: Interact, c: Dictionary) -> void:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return
	var valya: Dictionary = (w as Dictionary).get("valya", {})
	if valya.is_empty():
		return
	var q := ValyaQuest.new(c, valya)
	c["valya"] = q
	q.register(I)


# ---------- КУХНЯ И САРАЙ (фаза 12) ----------
#
# Три просьбы Петра, все в одном месте: тёрка на кухне, яблоки натереть
# с сахаром и попробовать, телефон убрать из раковины.
#
# ТЕЛЕФОН. props.json заморожен с фазы 8, но прятать узел на рантайме он
# не запрещает: старый аппарат и листок с номерами гасятся, новые стоят
# на тумбе рядом с запиской (home_world.gd). Точка «позвонить» переезжает
# следом — она и раньше из props.json не выводилась, а бралась числом.
#
# ЯБЛОКИ. Цепочка удлиняется на два шага и уводит игрока с крыльца на кухню
# и обратно к воротам: он проходит дом ещё раз ровно в ту минуту, когда дом
# уже перестал быть безопасным. Приём не выдуман — это первый эпизод Fears
# to Fathom целиком: достать, приготовить, съесть, выбросить.
static func _register_home(I: Interact, c: Dictionary) -> void:
	var t := GameData.texts()
	var prompts: Dictionary = t["PROMPTS"]
	var beats: Dictionary = t["BEATS"]
	var looks: Dictionary = t["LOOKS"]

	# Старые узлы гасятся здесь, а не в HomeWorld: props.build() к моменту
	# сборки мира ещё не отработал, а к моменту registerObjects — уже.
	var props: Variant = c.get("props")
	if props != null and not _home(c).is_empty():
		for id: String in ["phone-main", "phone-numbers"]:
			var n: Variant = props.get_prop(id)
			if n is Node3D:
				(n as Node3D).visible = false

	# --- бывшая комната Тони: перевёрнутая семейная фотография ---
	# Единственный стук хранится в уже сохраняемом state.looked. Нового
	# сюжетного флага нет: повторный осмотр остаётся обычным коротким LOOK.
	I.add({
		"id": "tonya-photo",
		"pos": Vector3(-0.28, 4.02, 15.70), "r": 1.9, "cone": 0.55,
		"kind": "look", "priority": 3,
		"prompt": prompts["look"],
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if not s.looked.has("tonya-photo"):
				s.looked["tonya-photo"] = true
				var audio: Variant = cc.get("audio")
				if audio != null:
					if not bool(audio.sfx("wall-knock")):
						audio.knock(1, 0.18)
				cc["ui"].say(String(beats.get("tonyaPhotoKnock", "")), 4.4)
				_emit(cc, "look", "tonya-photo")
				return
			cc["ui"].say(String(looks.get("tonya-photo", "")), 3.2),
	})

	# --- тёрка: натереть яблоки с сахаром ---
	var grate_when := func(s: GameState) -> bool:
		return s.hasItem("apple-basket") and not s.has("apples-grated")
	var grate_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.set_flag("apples-grated")
		# Звук тёрки — новый оверлейный sfx на существующем рецепте. Нет
		# оверлея — скрип: тереть по жести в тишине всё равно чем-то надо.
		var a: Variant = cc["audio"]
		if a != null and not bool(a.sfx("grater")):
			a.creak(0.45)
			a.after(1.2, func() -> void: a.creak(0.4))
		_home_show(cc, "kitchen-bowl", true)
		_home_heap(cc, true)
		cc["ui"].say(String(beats.get("applesGrated", "")), 3.6)
		_emit(cc, "apples-grated")
	I.add({
		"id": "kitchen-grater",
		"pos": Vector3(-1.10, 1.42, 10.44), "r": 1.7, "cone": 0.5, "priority": 3,
		"prompt": "натереть с сахаром",
		"when": grate_when,
		"onUse": grate_use,
	})

	# --- миска: попробовать ---
	var taste_when := func(s: GameState) -> bool:
		return s.has("apples-grated") and not s.has("apples-tasted")
	var taste_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.set_flag("apples-tasted")
		_home_heap(cc, false)
		cc["ui"].say(String(beats.get("applesTaste", "")), 3.4)
		_emit(cc, "apples-tasted")
	I.add({
		"id": "kitchen-bowl",
		"pos": Vector3(-1.05, 1.40, 10.02), "r": 1.7, "cone": 0.5, "priority": 3,
		"prompt": "попробовать",
		"when": taste_when,
		"onUse": taste_use,
	})

	# --- кухня после блэкаута ---
	# Только осмотр и ни одного стингера: игрок либо замечает сам, либо
	# не замечает вовсе. Порча безопасного места сильнее любого удара —
	# он тут яблоки тёр сорок минут назад.
	var wreck_when := func(s: GameState) -> bool:
		return s.has("kitchen-wrecked")
	I.add({
		"id": "kitchen-wrecked",
		"pos": Vector3(-1.30, 1.40, 11.30), "r": 2.2, "cone": 0.55, "kind": "look",
		"priority": 1,
		"prompt": prompts["look"],
		"when": wreck_when,
		"onUse": func(cc: Dictionary) -> void:
			(cc["state"] as GameState).looked["kitchen-wrecked"] = true
			cc["ui"].say(String(looks.get("kitchen-wrecked", "")), 4.6)
			_emit(cc, "look", "kitchen-wrecked"),
	})

	# --- СВЕТ: три окна первого этажа ---
	#
	# Рутина, и в этом весь смысл: игрок обходит этаж, закрывает окна и запоминает
	# дом безопасным. Третье уже закрыто, и рама у него изнутри мокрая — единственная
	# строка всей главы, которая не объясняет себя.
	# ФАЗА 13: форточка hall уехала с середины лестничного марша (z 10.90) на
	# третий проём той же стены, за площадку. Точка использования едет следом —
	# иначе игрок закрывал бы окно, стоя на ступеньках спиной к нему.
	var win_rows := [
		["window-hall", Vector3(-5.40, 1.72, 13.60), 1.0],
		["window-living", Vector3(1.20, 1.72, 16.02), -1.0],
		["window-aunt", Vector3(4.22, 1.72, 8.40), -1.0],
	]
	for row: Array in win_rows:
		var wid: String = row[0]
		var wet := wid == "window-aunt"
		var win_when := func(s: GameState) -> bool:
			return s.has("power-on") and not s.has(wid)
		var win_use := func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag(wid)
			_home_close_window(cc, wid)
			if not wet:
				cc["audio"].creak(0.35)
			cc["ui"].say(String(beats.get("windowWet" if wet else "windowShut", "")),
				3.8 if wet else 2.2)
			if _windows_done(s):
				cc["ui"].say(String(beats.get("windowsDone", "")), 3.2)
			_emit(cc, "window-shut", wid)
		I.add({
			"id": wid,
			"pos": row[1], "r": 1.9, "cone": 0.5, "priority": 2,
			"prompt": prompts["close"],
			"when": win_when,
			"onUse": win_use,
		})

	# --- СВЕТ: чайник на плите ---
	var kettle_when := func(s: GameState) -> bool:
		return s.has("power-on") and not s.has("kettle-on")
	var kettle_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.set_flag("kettle-on")
		_home_show(cc, "kitchen-kettle", true)
		cc["audio"].click()
		cc["ui"].say(String(beats.get("kettleOn", "")), 3.2)
		_emit(cc, "kettle-on")
	I.add({
		"id": "kitchen-kettle",
		"pos": Vector3(0.34, 1.52, 9.97), "r": 1.8, "cone": 0.5, "priority": 2,
		"prompt": "поставить чайник",
		"when": kettle_when,
		"onUse": kettle_use,
	})

	# --- МАНСАРДА: альбом на чердаке ---
	#
	# Ведёт на погост, но говорит об этом только одной фотографией: на снимке
	# пятьдесят девятого года лицо второго соскоблено ногтем. Кто это, игрок
	# поймёт в деревне, у могилы, — или не поймёт вовсе.
	var album_txt: Dictionary = GameData.texts().get("ALBUM", {})
	var album_when := func(s: GameState) -> bool:
		return s.atLeast("loft")
	var album_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		cc["ui"].setReaderTitle(String(album_txt.get("title", "")))
		cc["ui"].openReader(album_txt.get("title", ""), album_txt.get("pages", []),
			func() -> void:
				if s.has("album-seen"):
					return
				s.set_flag("album-seen")
				cc["ui"].say(String(beats.get("albumFace", "")), 4.6)
				_emit(cc, "album-seen"))
		if not s.has("album-found"):
			s.set_flag("album-found")
			cc["ui"].say(String(beats.get("albumFound", "")), 2.6)
	I.add({
		"id": "attic-album",
		"pos": Vector3(-1.90, 6.02, 13.05), "r": 2.2, "cone": 0.6, "priority": 3,
		"prompt": prompts["read"],
		"when": album_when,
		"onUse": album_use,
	})

	# --- ПЛЁНКИ: чей штатив стоял у тетради ---
	var mark_when := func(s: GameState) -> bool:
		return s.atLeast("tapes")
	# Два захода, и второй закрывает ступень задачи: сперва игрок видит вмятины
	# в пыли, потом читает этикетку на кассете и понимает, чей это был штатив.
	# Одним нажатием этого не сделать — «чужой почерк» надо ещё разобрать.
	var mark_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if not s.has("tripod-mark"):
			s.set_flag("tripod-mark")
			cc["ui"].say(String(beats.get("tripodMark", "")), 4.2)
			_emit(cc, "tripod-mark")
			return
		if not s.has("camera-known"):
			s.set_flag("camera-known")
			_emit(cc, "camera-known")
		cc["ui"].say(String(beats.get("alienLabel", "")), 3.8)
	I.add({
		"id": "tripod-mark",
		"pos": Vector3(-2.92, 6.00, 12.80), "r": 2.2, "cone": 0.6, "priority": 3,
		"prompt": prompts["look"],
		"when": mark_when,
		"onUse": mark_use,
	})

	# --- сарай: вещи на верстаке (глава ТЕМНОТА) ---
	var things_when := func(s: GameState) -> bool:
		return s.atLeast("dark") and s.has("blackout")
	var things_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.looked["shed-things"] = true
		if not s.has("shed-things"):
			s.set_flag("shed-things")
			cc["ui"].say(String(beats.get("shedThings", "")), 5.0)
			cc["audio"].heartbeat(3, 100)
			_emit(cc, "shed-things")
			return
		cc["ui"].say(String(looks.get("shed-things", "")), 3.8)
	I.add({
		"id": "shed-things",
		"pos": Vector3(7.46, 1.32, 11.80), "r": 2.0, "cone": 0.5, "priority": 2,
		"prompt": prompts["look"],
		"when": things_when,
		"onUse": things_use,
	})


## Мелочь дома или пустой словарь. Нет data/home.json — тихо ничего.
static func _home(c: Dictionary) -> Dictionary:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return {}
	return (w as Dictionary).get("home", {})


static func _home_node(c: Dictionary, id: String) -> Node3D:
	var n: Variant = (_home(c).get("nodes", {}) as Dictionary).get(id)
	return n if n is Node3D else null


static func _home_show(c: Dictionary, id: String, on: bool) -> void:
	var n := _home_node(c, id)
	if n != null:
		n.visible = on


## Все три окна первого этажа закрыты?
static func _windows_done(s: GameState) -> bool:
	return s.has("window-hall") and s.has("window-living") and s.has("window-aunt")


## Закрыть форточку: створка встаёт в плоскость стены. Нет data/home.json —
## тихо ничего, и задание работает одними флагами.
static func _home_close_window(c: Dictionary, id: String) -> void:
	var n := _home_node(c, id)
	if n == null:
		return
	var leaf := n.get_node_or_null("leaf")
	if leaf is Node3D:
		(leaf as Node3D).rotation.y = 0.0


## Горка натёртого в миске. Отдельным ребёнком, потому что после блэкаута
## миска обязана стоять на месте и быть пустой.
static func _home_heap(c: Dictionary, on: bool) -> void:
	var n := _home_node(c, "kitchen-bowl")
	if n == null:
		return
	var heap := n.get_node_or_null("heap")
	if heap is Node3D:
		(heap as Node3D).visible = on


## Порча кухни. Зовётся из chapters._blackout(): тёрка переезжает в раковину,
## миска пустеет, сахар рассыпан дорожкой от тумбы к люку подпола.
static func wreck_kitchen(c: Dictionary) -> void:
	if _home(c).is_empty():
		return
	var s: GameState = c["state"]
	s.set_flag("kitchen-wrecked")
	_home_show(c, "kitchen-grater", false)
	_home_show(c, "kitchen-grater-sink", true)
	_home_show(c, "kitchen-sugar", true)
	_home_heap(c, false)


# ---------- ПРИЕЗД ----------

static func _register_arrive(I: Interact, _c: Dictionary) -> void:
	var t := GameData.texts()
	var prompts: Dictionary = t["PROMPTS"]
	var beats: Dictionary = t["BEATS"]
	var looks: Dictionary = t["LOOKS"]

	var gate_prompt := func(s: GameState) -> String:
		if s.atLeast("gate") and not s.hasItem("chain-key") and not s.has("gate-open"):
			return prompts["locked"]
		return prompts["close"] if s.has("gate-open") else "снять цепь"
	var gate_when := func(_s) -> bool:
		return true
	var gate_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		# ФАЗА 17. Цепь не снимается ДО СУМКИ, и это не украшение порядка.
		# Погоня стартует ровно по снятой цепи (chapters._gate_gate ->
		# 'gate-chase', 4.4 с), а монолог у крыльца морозит игрока на
		# семнадцать секунд (FINAL_AT_GATE). Снявший цепь раньше сумки
		# попадается гарантированно: он стоит и слушает, пока к нему идут.
		if s.atLeast("gate") and not s.has("gate-open") and not s.has("bag-packed"):
			c["ui"].say(String(t["TASKS"].get("bagTapes", "")), 3.6)
			return
		# Замок на воротах в финале не свой: его накинули снаружи. Ключ от него
		# лежит в тайнике — тот самый 'chain-key', который до фазы 9 выдавался
		# и не читался нигде.
		if s.atLeast("gate") and not s.has("gate-open") and not s.hasItem("chain-key"):
			c["ui"].say("Амбарный замок. Ключ от него был в тайнике, в подполе.", 4.4)
			return
		var open := not s.has("gate-open")
		s.set_flag("gate-open", open)
		_ctx_call(c, "setGate", [open])
		# В финале цепь на воротах уже не своя: её накинули снаружи, пока Сергей
		# был в доме. Реплика одна на прохождение и только в последней главе.
		if open and s.atLeast("gate") and not s.has("chain-final-said"):
			s.set_flag("chain-final-said")
			c["ui"].say(beats["chainFinal"], 4.0)
		else:
			c["ui"].say(beats["chainOff"] if open else "Накинул обратно.", 3.4)
		_emit(c, "gate", open)
	I.add({
		"id": "gate-chain",
		"pos": Vector3(0, 1.0, 0.05), "r": 2.2, "priority": 2,
		"prompt": gate_prompt,
		"when": gate_when,
		"onUse": gate_use,
	})

	var trunk_prompt := func(s: GameState) -> String:
		if not s.hasItem("flashlight"):
			return "открыть багажник"
		return prompts["look"] if s.has("bags-2") else "взять из багажника"
	var trunk_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		# Крышка багажника — одно событие на все три захода в него.
		c["audio"].sfx("trunk-open")
		# Фонарь выдаётся здесь, и больше нигде. Раньше Flashlight.give() не звали
		# вообще: фонарь был недостижим, а задача главы ТЕМНОТА висела до конца
		# прохождения. Поэтому он идёт первым, до всякой возни с сумками.
		if not s.hasItem("flashlight"):
			s.give("flashlight")
			c["flashlight"].give()
			c["ui"].toast("Фонарь")
			c["ui"].say("Фонарь с рыбалки так и катается в багажнике. Сегодня пригодится.", 3.6)
			var holder: Node3D = c["props"].get_prop("trunk-flashlight")
			if holder != null:
				holder.visible = false
			_emit(c, "flashlight")
			return
		if not s.has("bags-1"):
			s.set_flag("bags-1")
			s.give("bag")
			c["ui"].toast("Сумка с продуктами")
			c["ui"].say("Сумка. За пакетом ещё вернусь.", 3.2)
		elif not s.has("bags-2"):
			s.set_flag("bags-2")
			s.give("parcel")
			c["ui"].toast("Пакет")
			c["ui"].say(beats["bagsIn"], 3.0)
			_emit(c, "bags-done")
		else:
			c["ui"].say("Пусто. Всё вынес.", 2.4)
	I.add({
		"id": "car-trunk",
		# Точка стоит у настоящей кормы. Машина брошена поперёк дороги, её коллайдер
		# занимает x от -1.0 до 3.2, и прежняя точка [1.1, 0.9, -1.2] висела
		# у середины борта: игрок открывал багажник, стоя у водительской двери.
		"pos": Vector3(2.60, 1.05, -1.95), "r": 2.2, "priority": 2,
		"prompt": trunk_prompt,
		"onUse": trunk_use,
	})

	var shed_prompt := func(s: GameState) -> String:
		return prompts["close"] if s.has("shed-open") else prompts["open"]
	var shed_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		var open := not s.has("shed-open")
		s.set_flag("shed-open", open)
		_ctx_call(c, "setDoor", ["door-shed", open])
		c["ui"].say("Дверь сарая скрипнула." if open else "Прикрыл.", 2.6)
		_emit(c, "shed-door", open)
	I.add({
		"id": "shed-door",
		"pos": Vector3(6.8, 1.0, 9.92), "r": 2.0, "priority": 2,
		"prompt": shed_prompt,
		"onUse": shed_use,
	})

	var tin_prompt := func(s: GameState) -> String:
		return prompts["look"] if s.hasItem("key") else prompts["take"]
	var tin_when := func(s: GameState) -> bool:
		return s.has("shed-open")
	var tin_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		if s.hasItem("key"):
			c["ui"].say(looks["tin-box"], 4.0)
			return
		c["audio"].sfx("tin-open")
		s.give("key")
		s.set_flag("key-found")
		c["ui"].toast("Ключ с биркой «дом»")
		c["ui"].say(looks["tin-box"], 4.4)
		_emit(c, "key")
	I.add({
		"id": "tin-box",
		"pos": Vector3(7.62, 1.05, 11.2), "r": 1.6, "priority": 3,
		"prompt": tin_prompt,
		"when": tin_when,
		"onUse": tin_use,
	})

	var door_prompt := func(s: GameState) -> String:
		if s.has("house-open"):
			return prompts["close"]
		return prompts["open"] if s.hasItem("key") else prompts["locked"]
	var door_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		if not s.hasItem("key"):
			c["ui"].say("Заперто на два оборота. Ключ был в сарае, в жестянке.", 4.2)
			_emit(c, "door-locked")
			return
		var open := not s.has("house-open")
		s.set_flag("house-open", open)
		_ctx_call(c, "setDoor", ["door-front", open])
		if open and not s.has("entered"):
			s.set_flag("entered")
			c["ui"].say(beats["doorOpen"], 3.4)
			_emit(c, "house-open")
	I.add({
		"id": "front-door-use",
		"pos": Vector3(-2.3, 1.1, 6.55), "r": 2.0, "priority": 3,
		"prompt": door_prompt,
		"onUse": door_use,
	})


# ---------- СВЕТ ----------

static func _register_light(I: Interact, _c: Dictionary) -> void:
	var t := GameData.texts()
	var y: Dictionary = GameData.site()["Y"]
	var F1 := float(y["FLOOR1"])
	var prompts: Dictionary = t["PROMPTS"]
	var beats: Dictionary = t["BEATS"]
	var looks: Dictionary = t["LOOKS"]
	var note: Dictionary = t["NOTE_MOTHER"]

	var breaker_prompt := func(s: GameState) -> String:
		return prompts["look"] if s.has("breaker-on") else "поднять автомат"
	var breaker_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		if s.has("breaker-on"):
			c["ui"].say(looks["outdoor-fusebox"], 3.8)
			return
		s.set_flag("breaker-on")
		c["ui"].say(beats["breakerOn"], 3.4)
		c["audio"].click()
		_emit(c, "breaker")
	I.add({
		"id": "outdoor-fusebox",
		"pos": Vector3(-0.75, 1.55, 6.42), "r": 1.8, "priority": 3,
		"prompt": breaker_prompt,
		"onUse": breaker_use,
	})

	var fuse_prompt := func(s: GameState) -> String:
		return prompts["look"] if s.has("power-on") else "вкрутить пробку"
	var fuse_when := func(s: GameState) -> bool:
		return s.has("entered")
	var fuse_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		if s.has("power-on"):
			c["ui"].say(looks["fusebox"], 3.8)
			return
		if not s.has("breaker-on"):
			c["ui"].say("Пробка на месте, а света нет. Значит, вводный автомат снаружи.", 4.6)
			_emit(c, "need-breaker")
			return
		s.set_flag("power-on")
		c["lights"].powerOn = true
		for id: String in ["veranda", "hall", "kitchen", "closet"]:
			c["lights"].setLamp(id, true)
		c["ui"].say(beats["fuseIn"], 3.0)
		c["audio"].click()
		_emit(c, "power")
	I.add({
		"id": "fusebox",
		"pos": Vector3(-5.32, F1 + 1.35, 14.2), "r": 1.7, "priority": 3,
		"prompt": fuse_prompt,
		"when": fuse_when,
		"onUse": fuse_use,
	})

	var note_when := func(s: GameState) -> bool:
		return s.has("entered")
	var note_use := func(c: Dictionary) -> void:
		c["ui"].setReaderTitle(note["title"])
		var done := func() -> void:
			var s: GameState = c["state"]
			if not s.has("note-read"):
				s.set_flag("note-read")
				c["ui"].say(beats["noteRead"], 3.4)
				_emit(c, "note-read")
		c["ui"].openReader(note["title"], note["body"], done)
	I.add({
		"id": "note-mother",
		# Записка лежит на столешнице кухонного шкафа: стола на кухне больше нет,
		# он перекрывал арку в зал и уехал в зал целиком.
		"pos": Vector3(-1.30, F1 + 0.95, 10.20), "r": 1.6, "priority": 3,
		"prompt": prompts["read"],
		"when": note_when,
		"onUse": note_use,
	})

	var fridge_prompt := func(s: GameState) -> String:
		return prompts["look"] if s.has("groceries") else "разложить продукты"
	var fridge_when := func(s: GameState) -> bool:
		return s.has("entered")
	var fridge_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		if s.has("groceries"):
			c["ui"].say(looks["plate"], 4.2)
			return
		if not s.hasItem("bag"):
			c["ui"].say("Пусто в руках. Сумка в машине.", 3.0)
			return
		s.set_flag("groceries")
		c["audio"].sfx("fridge-stock")
		c["ui"].say(looks["plate"], 4.6)
		_emit(c, "groceries")
	I.add({
		"id": "fridge-use",
		"pos": Vector3(0.62, F1 + 0.9, 11.6), "r": 1.8, "priority": 3,
		"prompt": fridge_prompt,
		"when": fridge_when,
		"onUse": fridge_use,
	})

	var phone_when := func(s: GameState) -> bool:
		return s.has("entered")
	var phone_use := func(c: Dictionary) -> void:
		_ctx_call(c, "openPhone", ["main"])
	I.add({
		"id": "phone-main",
		# ФАЗА 12: аппарат переехал из РАКОВИНЫ на тумбу, где лежит записка.
		# Фаза 8 опустила его с 1.5 на 1.12 «на столешницу», но замер меша
		# мойки говорит другое: на (-1.555, 12.19) там дно чаши, 0.962, —
		# то есть телефон всё это время висел в воздухе посреди раковины,
		# и Пётр это увидел. Новый аппарат строит home_world.gd на крышке
		# kitchen-cabinet (рабочая плоскость 1.29), старый прячется
		# в _register_home(). Точка едет за аппаратом: она и раньше
		# из props.json не выводилась, а бралась числом.
		"pos": Vector3(-1.45, F1 + 0.97, 9.98), "r": 1.7, "priority": 3,
		"prompt": prompts["call"],
		"when": phone_when,
		"onUse": phone_use,
	})

	var par_prompt := func(s: GameState) -> String:
		return prompts["call"] if s.atLeast("dark") else prompts["look"]
	var par_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		if s.atLeast("dark"):
			_ctx_call(c, "openPhone", ["parallel"])
		else:
			c["ui"].say(looks["phone-parallel"], 3.6)
	I.add({
		"id": "phone-parallel",
		# Аппарат стоит на столике у южной стены веранды, на 0.769 — крышке столика.
		"pos": Vector3(-1.60, F1 + 0.85, 9.20), "r": 1.6, "priority": 2,
		"prompt": par_prompt,
		"onUse": par_use,
	})


# ---------- выключатели по комнатам ----------

static func _register_switches(I: Interact, c: Dictionary) -> void:
	var t := GameData.texts()
	var y: Dictionary = GameData.site()["Y"]
	var F1 := float(y["FLOOR1"])
	var F2 := float(y["ATTIC"])
	var FC := float(y["CELLAR"])
	var prompts: Dictionary = t["PROMPTS"]

	var switches := [
		["sw-veranda", "veranda", Vector3(-4.35, F1 + 1.35, 9.5)],
		["sw-hall", "hall", Vector3(-1.95, F1 + 1.35, 10.6)],
		["sw-kitchen", "kitchen", Vector3(-1.6, F1 + 1.35, 9.75)],
		["sw-living", "living", Vector3(-1.6, F1 + 1.35, 12.55)],
		["sw-aunt", "aunt", Vector3(1.15, F1 + 1.35, 11.1)],
		["sw-wash", "wash", Vector3(-2.0, F1 + 1.35, 15.15)],
		["sw-closet", "closet", Vector3(-4.55, F1 + 1.35, 14.0)],
		["sw-landing", "landing", Vector3(-1.95, F2 + 1.35, 12.6)],
		["sw-vitya", "vitya", Vector3(-1.6, F2 + 1.35, 12.6)],
		["sw-storage", "storage", Vector3(-2.5, F2 + 1.35, 13.95)],
		["sw-shed", "shed", Vector3(7.55, 1.35, 10.22)],
		["sw-cellar", "cellar", Vector3(-4.2, FC + 1.5, 8.9)],
		["sw-porch", "porch", Vector3(-1.5, F1 + 1.35, 6.42)],
	]
	for row: Array in switches:
		var id: String = row[0]
		var lamp: String = row[1]
		var pos: Vector3 = row[2]
		var prompt := func(_s) -> String:
			return prompts["switchOff"] if bool(c["lights"].isOn(lamp)) else prompts["switchOn"]
		var on_use := func(cc: Dictionary) -> void:
			if not bool(cc["lights"].powerOn) and lamp != "shed":
				# «Щёлкает вхолостую» до фазы 5 было только написано словами.
				# Без оверлея сцена остаётся немой, как в принятой версии.
				cc["audio"].sfx("switch-dead")
				cc["ui"].say("Щёлкает вхолостую. Света нет.", 2.6)
				return
			var on := bool(cc["lights"].toggleLamp(lamp))
			cc["audio"].click()
			# Накал разгорается не мгновенно — щелчок и дребезг это два события.
			if on:
				cc["audio"].sfx("lamp-on")
			_emit(cc, "switch", {"lamp": lamp, "on": on})
		I.add({
			"id": id, "pos": pos, "r": 1.5, "cone": 0.5, "priority": 1,
			"prompt": prompt,
			"onUse": on_use,
		})


# ---------- МАНСАРДА ----------

static func _register_loft(I: Interact, _c: Dictionary) -> void:
	var t := GameData.texts()
	var y: Dictionary = GameData.site()["Y"]
	var F1 := float(y["FLOOR1"])
	var F2 := float(y["ATTIC"])
	var F3 := float(y["ROOF"])
	var prompts: Dictionary = t["PROMPTS"]
	var looks: Dictionary = t["LOOKS"]
	var diary: Dictionary = t["DIARY"]
	var sms: Dictionary = t["SMS"]
	var notebook: Dictionary = t["WATCH_NOTEBOOK"]

	var diary_when := func(s: GameState) -> bool:
		return s.atLeast("loft")
	var diary_use := func(c: Dictionary) -> void:
		c["ui"].setReaderTitle(diary["title"])
		var done := func() -> void:
			var s: GameState = c["state"]
			if not s.has("diary-read"):
				s.set_flag("diary-read")
				_emit(c, "diary-read")
		c["ui"].openReader(diary["title"], diary["pages"], done)
	I.add({
		"id": "diary",
		# Стол деда сдвинут от перегородки; тетрадь лежит на его дальнем краю.
		"pos": Vector3(-1.35, F2 + 0.84, 10.10), "r": 1.6, "priority": 3,
		"prompt": prompts["read"],
		"when": diary_when,
		"onUse": diary_use,
	})

	var mobile_prompt := func(s: GameState) -> String:
		return prompts["read"] if s.hasItem("mobile") else "заглянуть под матрас"
	var mobile_when := func(s: GameState) -> bool:
		return s.atLeast("loft")
	var mobile_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		if not s.hasItem("mobile"):
			s.give("mobile")
			c["audio"].sfx("mattress")
			c["ui"].toast("Мамин «Сименс»")
			c["ui"].say(looks["mobile"], 4.2)
			_emit(c, "mobile")
		var pages: Array = []
		for item: Array in sms["items"]:
			pages.append(String(item[0]) + "\n\n" + String(item[1]))
		c["ui"].setReaderTitle(sms["title"])
		var done := func() -> void:
			_emit(c, "sms-read")
		c["ui"].openReader(sms["title"], pages, done)
	I.add({
		"id": "mobile",
		"pos": Vector3(1.6, F2 + 0.4, 12.0), "r": 1.7, "priority": 3,
		"prompt": mobile_prompt,
		"when": mobile_when,
		"onUse": mobile_use,
	})

	# Шаг 0.18 по X — это ширина корешка кассеты; координаты те же, что у пропов
	# в data/props.json. Полка уехала из северной стены, кассеты уехали с ней.
	var tape_pos := {"1": 0.55, "2": 0.73, "3": 0.91, "5": 1.09}
	for n: String in ["1", "2", "3", "5"]:
		var when := func(s: GameState) -> bool:
			return s.atLeast("loft") and not s.hasItem("tape-" + n)
		var on_use := func(c: Dictionary) -> void:
			c["state"].give("tape-" + n)
			c["audio"].sfx("item-take")
			c["ui"].toast("Кассета " + n)
			var holder: Node3D = c["props"].get_prop("tape-" + n)
			if holder != null:
				holder.visible = false
			_emit(c, "tape-taken", n)
		I.add({
			"id": "tape-" + n,
			"pos": Vector3(float(tape_pos[n]), F2 + 1.18, 9.95),
			"r": 1.5, "cone": 0.30, "priority": 3,
			"prompt": prompts["take"],
			"when": when,
			"onUse": on_use,
		})

	var nb_when := func(s: GameState) -> bool:
		return s.atLeast("tapes")
	var nb_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		# Явный дескриптор забирает id у осмотра, и реплика LOOKS осталась бы
		# ненаписанной. Говорим её сами — как у жестянки, щитка и телефона.
		if not s.looked.has("watch-notebook"):
			s.looked["watch-notebook"] = true
			c["ui"].say(looks["watch-notebook"], 3.6)
		c["ui"].setReaderTitle(notebook["title"])
		var done := func() -> void:
			if not s.has("notebook-read"):
				s.set_flag("notebook-read")
				_emit(c, "notebook-read")
		c["ui"].openReader(notebook["title"], notebook["pages"], done)
	I.add({
		"id": "watch-notebook",
		# Тетрадь лежит на полу: от глаз до неё уже 1.58 м по вертикали,
		# с радиусом 1.6 до неё было не дотянуться, стоя вплотную.
		"pos": Vector3(-2.45, F3 + 0.1, 13.05), "r": 2.4, "cone": 0.6, "priority": 3,
		"prompt": prompts["read"],
		"when": nb_when,
		"onUse": nb_use,
	})

	var ladder_when := func(s: GameState) -> bool:
		return s.atLeast("tapes") and not s.hasItem("ladder")
	var ladder_use := func(c: Dictionary) -> void:
		c["state"].give("ladder")
		c["audio"].sfx("ladder-take")
		c["ui"].toast("Стремянка")
		c["ui"].say("Тяжёлая. Ничего, донесу.", 3.0)
		var holder: Node3D = c["props"].get_prop("stepladder")
		if holder != null:
			holder.visible = false
		_emit(c, "ladder-taken")
	I.add({
		"id": "stepladder-take",
		"pos": Vector3(-5.15, F1 + 0.8, 14.75), "r": 1.8, "priority": 3,
		"prompt": prompts["take"],
		"when": ladder_when,
		"onUse": ladder_use,
	})

	var vm12_prompt := func(s: GameState) -> String:
		return prompts["watch"] if s.inventory.size() > 0 else prompts["look"]
	var vm12_when := func(s: GameState) -> bool:
		return s.atLeast("loft")
	var vm12_use := func(c: Dictionary) -> void:
		_ctx_call(c, "openTapeMenu")
	I.add({
		"id": "vm12-use",
		"pos": Vector3(2.75, F1 + 0.62, 15.7), "r": 1.8, "priority": 3,
		"prompt": vm12_prompt,
		"when": vm12_when,
		"onUse": vm12_use,
	})


# ---------- ФИНАЛ ----------

static func _register_final(I: Interact, _c: Dictionary) -> void:
	var t := GameData.texts()
	var y: Dictionary = GameData.site()["Y"]
	var F2 := float(y["ATTIC"])
	var F3 := float(y["ROOF"])
	var FC := float(y["CELLAR"])
	var beats: Dictionary = t["BEATS"]

	# Тайник в нише подпола, за банками: ключ от амбарного замка на воротах
	# и последняя кассета. Всё, что дед отнял, он снёс наверх, а это спрятал вниз —
	# значит, знал, что за этим придут.
	#
	# Точка стоит у западного края ниши, за третьей полкой с банками — там же,
	# куда его отправляет дневник («в подпол, за банки, третий ряд слева»).
	# На прежнем месте [3.0, 13.9] она стояла вплотную к укрытию 'hide-cellar'
	# (0.9 м, тот же приоритет) и перехватывала у него E прямо в проёме ниши.
	var stash_when := func(s: GameState) -> bool:
		return s.atLeast("dark") and not s.has("stash-found") and s.recovery.is_empty()
	var stash_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		s.set_flag("stash-found")
		s.give("chain-key")
		# Кассету мог отдать чердак — тогда в тайнике остаётся только ключ.
		var tape := not s.hasItem("tape-x")
		if tape:
			s.give("tape-x")
		s.evidence = true
		# Банки: три стеклянных всплеска вразнобой, готового звука под них нет.
		for i in 3:
			var splash := func() -> void:
				c["audio"].noise({
					"dur": 0.13, "gain": 0.09,
					"freq": 2900.0 + randf() * 1500.0, "q": 6.0,
				})
			_after(i * 0.09, splash)
		c["ui"].toast("Ключ от замка и кассета без этикетки" if tape else "Ключ от замка")
		c["ui"].say("Ниша за банками. Вот куда он всё убрал.", 4.2)
		_emit(c, "stash")
	I.add({
		"id": "cellar-stash",
		"pos": Vector3(0.60, FC + 0.9, 15.20), "r": 1.8, "priority": 3,
		# Подсказка одна: после 'stash-found' дескриптор снимается условием when,
		# и второй вариант надписи показывать уже некому.
		"prompt": "разобрать банки",
		"when": stash_when,
		"onUse": stash_use,
	})

	# Сумка на веранде (фаза 15). Последний шаг сюжета — В ДОМЕ, а не у ворот:
	# до фазы 15 глава ВОРОТА начиналась там же, где игрок чинил машину, то
	# есть уже снаружи, и весь финал состоял из одного нажатия. Теперь он
	# идёт за кассетами в дом и выходит на крыльцо под грозу — и только
	# оттуда к воротам.
	#
	# Стол веранды: props.json 'veranda-stand' at [-1.1, 0.45, 9.15]. Три с
	# половиной метра от входной двери, мимо не пройти.
	var bag_when := func(s: GameState) -> bool:
		return s.atLeast("gate") and not s.has("bag-packed")
	var bag_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		if s.has("bag-packed"):
			return
		s.set_flag("bag-packed")
		c["audio"].sfx("item-take")
		c["ui"].toast("Сумка")
		c["ui"].say(String(t["BEATS"].get("bagged", "")), 3.6)
		_emit(c, "bagged")
	I.add({
		"id": "final-bag",
		# ФАЗА 17, НАЙДЕНО ЖИВЬЁМ. Точка стояла на y 1.02 — то есть ВНУТРИ
		# тумбы: её крышка лежит на 1.22, и двадцать сантиметров точка была
		# утоплена в дерево. Видимой модели у сумки нет вовсе, наводиться
		# игроку не на что, и он ищет глазами предмет, которого в мире нет.
		# Прицел при этом упирается в крышку, то есть точка не бралась и
		# сверху. Теперь она НАД крышкой, а конус расширен до 0.62: это
		# последний обязательный шаг сюжета, и промахнуться мимо него
		# игрок не должен.
		"pos": Vector3(-1.10, 1.34, 9.15), "r": 2.2, "cone": 0.62, "priority": 5,
		"prompt": "сложить кассеты в сумку",
		"when": bag_when,
		"onUse": bag_use,
	})

	# Уехать раньше времени было можно с первой же минуты после блэкаута: ни
	# ключа, ни бензина, ни ворот игра не спрашивала, и вся ночь схлопывалась
	# в «дошёл до машины». Теперь замков ЧЕТЫРЕ, и каждый ОБЪЯСНЯЕТ СЕБЯ вслух:
	# запертая без слов дверь читается как баг, а не как задача.
	var drive_when := func(s: GameState) -> bool:
		# ФАЗА 15. Четвёртый замок, и он же единственный, который до фазы 15
		# не спрашивался вовсе: ЗАКРЫТЫЕ ВОРОТА. Уехать можно было, ни разу
		# к ним не подойдя, — то есть мимо единственной сцены, где деда видно
		# вплотную.
		#
		# Спрашивается ТОЛЬКО в последней главе, и это не осторожность:
		# до неё цепь снята с первой минуты и флага может не быть вовсе
		# (игрок вошёл в калитку, а не в ворота), а «уехал раньше времени»
		# в ТЕМНОТЕ и ДЕРЕВНЕ — законная концовка, и запирать её нечем.
		if s.atLeast("gate"):
			return s.has("gate-open")
		return s.atLeast("street")
	# Полторы секунды между ключом и стартёром: карточки концовки накрывают
	# экран сразу, и сказанное одновременно с ними никто не успевает прочесть.
	var drive_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		if not s.recovery.is_empty() or s.chapter == "end": return
		if s.has("starter-on"): return
		# ФАЗА 17. Страховка первым блоком: сюда можно попасть со старого
		# сохранения, после [R] и отладочным прыжком мимо village_quest.fixed(),
		# где стоит настоящий замок главы ДЕРЕВНЯ. Каждое условие отвечает
		# ГОТОВОЙ строкой задачи и выходит.
		#
		# Точку при этом НЕ гасим (drive_when не трогаем) сознательно:
		# погашенная точка не может ничего сказать, а здесь нужен именно голос.
		if s.atLeast("gate"):
			var tasks: Dictionary = t["TASKS"]
			if not s.has("bag-packed"):
				c["ui"].say(String(tasks.get("bagTapes", "")), 3.6)
				return
			if not s.has("water-done"):
				c["ui"].say(String(tasks.get("waterRows", "")), 3.6)
				return
			if not s.has("valya-gone"):
				# ФАЗА 18. Сюда доходят только с ненайденной последней
				# ступенью линии Вали, а на ней Вали у ограды уже нет:
				# valyaAgain на этом месте отправляла к тому, кого в мире
				# не осталось. См. chapters._valya_task.
				c["ui"].say(String(tasks.get("valyaEmpty", "")), 3.6)
				return
			if not s.has("kovrigin-letter") and not s.has("boarded-tapes"):
				c["ui"].say(String(tasks.get("boarded", "")), 3.6)
				return
		# Замок первый: пустой бак. Стартёр крутит, мотор не схватывает.
		if not s.has("tank-full"):
			if not bool(c["audio"].sfx("car-fail")):
				c["audio"].sfx("car-start")
			c["ui"].say(beats["carDead"], 4.0)
			_emit(c, "car-dead")
			return
		# Замок второй: ключи. Их дед снёс в подпол, вместе со всем остальным.
		if not s.hasItem("car-key"):
			c["audio"].click()
			c["ui"].say(beats["carNoKey"], 4.0)
			_emit(c, "car-nokey")
			return
		# ФАЗА 15. Со второго раза. Первый оборот стартёра не схватывает,
		# потом полторы секунды тишины — и только тогда мотор. Эти секунды
		# и есть весь финал: дед в них идёт, и слышно только его.
		#
		# До главы ВОРОТА всё как было: там отъезд — это «уехал раньше
		# времени», и растягивать его незачем.
		var s2: GameState = c["state"]
		c["drive_attempt_id"] = int(c.get("drive_attempt_id", 0)) + 1
		var attempt := int(c["drive_attempt_id"])
		var director: Variant = c.get("horror")
		var capture: Variant = c.get("capture")
		var capture_stamp := int(capture.generation) if capture != null else -1
		var horror_stamp := int(director.generation) if director != null else -1
		var origin_chapter := s.chapter
		var valid_attempt := func() -> bool:
			return int(c.get("drive_attempt_id", 0)) == attempt and s.chapter == origin_chapter \
				and s.chapter != "end" and s.recovery.is_empty() and s.has("starter-on") \
				and (capture == null or int(capture.generation) == capture_stamp) \
				and (director == null or int(director.generation) == horror_stamp)
		if not s2.atLeast("gate"):
			s.set_flag("starter-on")
			c["audio"].sfx("car-start")
			c["ui"].say(beats["ignition"], 3.0)
			_after(1.5, func() -> void:
				if valid_attempt.call(): _emit(c, "drive"))
			return
		# ФАЗА 17. Стартёр крутится ОДИН РАЗ за прохождение. Два оборота
		# растянуты на 2.6 с, игрок в это время читает субтитр и жмёт [E]
		# ещё раз — а раньше второе нажатие заводило вторую пару оборотов
		# поверх первой и второй emit("drive") поверх уже идущей катсцены.
		if s.has("starter-on"):
			return
		s.set_flag("starter-on")
		if not bool(c["audio"].sfx("car-fail")):
			c["audio"].sfx("car-start")
		c["ui"].say(beats["ignition"], 2.6)
		# Обе отложенные лямбды сверяют главу. За эти 2.6 с игрока могут
		# догнать: поимка кончает игру, а таймер продолжает крутиться и
		# доставляет «ехать» поверх титров.
		_after(1.5, func() -> void:
			if not valid_attempt.call():
				return
			c["ui"].say(beats["ignitionAgain"], 2.0)
			c["audio"].sfx("car-start")
			_after(1.1, func() -> void:
				if not valid_attempt.call():
					return
				_emit(c, "drive")))
	I.add({
		"id": "car-drive",
		"pos": Vector3(1.1, 1.0, -3.6), "r": 2.4, "priority": 4,
		"prompt": "сесть в машину",
		"when": drive_when,
		"onUse": drive_use,
	})

	# Три укрытия с одинаковыми правилами: закрой за собой, не свети, не зови,
	# жди условный звук. Правила игрок услышал заранее, по телефону, поэтому игра
	# их не объясняет заново.
	#
	# Таблица одна на игру — та же, по которой дед решает, куда игрок мог деться
	# (Threat.hides(), порт HIDES из game/ai.js). Две точки, а не одна: pos — куда
	# смотрит дескриптор, feet — куда встают ноги; высоту глаз считает player сам.
	for h: Dictionary in Threat.hides():
		var label: String = h["label"]
		var fa: Array = h["feet"]
		var feet := Vector3(float(fa[0]), float(fa[1]), float(fa[2]))
		var hide_prompt := func(s: GameState) -> String:
			return "выйти" if s.hidden else label
		var hide_when := func(s: GameState) -> bool:
			return s.atLeast("dark")
		var hide_use := func(c: Dictionary) -> void:
			var s: GameState = c["state"]
			if s.hidden:
				s.hidden = false
				c["controls"].enabled = true
				c["controls"].frozen = false
				c["audio"].sfx("hide-leave")
				c["ui"].say("Тихо. Пока тихо.", 2.6)
				return
			s.hidden = true
			# Ставим по точке ног. Высоту глаз считает controls сам, и вычитать рост
			# из данных нельзя: так игрок уезжал на полметра ниже пола.
			c["controls"].place(feet.x, feet.y, feet.z, c["controls"].yaw)
			c["controls"].frozen = true
			c["audio"].creak(0.7)
			c["ui"].say("Закрыл за собой. Не светить. Не звать.", 4.0)
			c["audio"].heartbeat(5, 92)
			# Дыхание в укрытии идёт после стука сердца: сначала колотится,
			# потом человек начинает себя сдерживать.
			c["audio"].after(1.2, func() -> void: c["audio"].sfx("breath-hide"))
		var pa: Array = h["pos"]
		I.add({
			"id": h["id"],
			"pos": Vector3(float(pa[0]), float(pa[1]) + 0.9, float(pa[2])),
			"r": 1.9, "priority": 3,
			"prompt": hide_prompt,
			"when": hide_when,
			"onUse": hide_use,
		})

	# Секретная концовка «ТИХО»: после кассеты без этикетки подняться на чердак
	# ещё раз, найти его спящим, спуститься, закрыть люк и придавить сундуком.
	#
	# С действием самого люка развели не радиусом, а конусом. Уронить радиус
	# до 0.9 нельзя: дескриптор висит на 1.28 м ниже глаз, и до него тогда
	# не дотянуться вообще. С узким конусом подсказка «придавить люк сундуком»
	# появляется, только когда игрок смотрит вниз, себе под ноги; глядя вперёд,
	# он получает обычную подсказку люка.
	var seal_when := func(s: GameState) -> bool:
		return s.has("saw-him-sleeping") and not s.has("hatch-sealed")
	var seal_use := func(c: Dictionary) -> void:
		var s: GameState = c["state"]
		s.set_flag("hatch-sealed")
		s.threatState = "absent"
		c["audio"].knock(2, 0.5)
		c["audio"].creak(1.4)
		c["ui"].say("Сундук пошёл по полу тяжело. Но пошёл.", 4.4)
		_emit(c, "sealed")
	I.add({
		"id": "seal-hatch",
		"pos": Vector3(-4.15, F2 + 0.9, 14.35), "r": 1.15, "cone": 0.35, "priority": 4,
		"prompt": "придавить люк сундуком",
		"when": seal_when,
		"onUse": seal_use,
	})

	var sleep_when := func(s: GameState) -> bool:
		return s.atLeast("dark") and s.tapesWatched.has("x") and not s.has("saw-him-sleeping")
	var sleep_use := func(c: Dictionary) -> void:
		c["state"].set_flag("saw-him-sleeping")
		c["ui"].say("Дед. Спит лицом к стене, руки под щекой. Как маленький.", 4.6)
		c["audio"].heartbeat(4, 88)
	I.add({
		"id": "sleeping-man",
		"pos": Vector3(-3.2, F3 + 0.5, 12.2), "r": 2.2, "priority": 4,
		"prompt": "посмотреть",
		"when": sleep_when,
		"onUse": sleep_use,
	})

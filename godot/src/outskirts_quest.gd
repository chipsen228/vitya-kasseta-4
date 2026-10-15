# Околица — задания фазы 14. Полив (главная цепочка, единственная причина
# идти на околицу по делу) и четыре коротких дела по одному на место:
# теплица, чердак бани, клуб, куриный двор.
#
# Тот же контракт, что village_quest.gd/street_quest.gd: точки — здесь,
# постройки — в outskirts_world.gd, посадка модели — в data/props.json.
# Замок цепочки один явный: пустая бочка -> кран сипит -> ключ с фермы
# -> замок водокачки -> рубильник -> кран даёт воду -> лейка -> четыре грядки.
# Каждое звено объясняет себя вслух (то же правило фазы 9).
#
# ГОЛОС ДЕДА. tests/test_voice_manifest.gd читает этот файл как текст и
# требует, чтобы `say_vitya` звался только из функции с разрешённым
# префиксом. Здесь это `_village_line` — по образцу interact.gd::_dark_vitya_line,
# и по той же причине в её имени нет подстроки `say_vitya`.

class_name OutskirtsQuest
extends RefCounted

## Сколько греется баня после закрытой заслонки, секунд (фаза 15).
const BANYA_WARM := 150.0
const MILL_CENTER := Vector3(21.0, 0.0, -29.0)
const MILL_FACTOR := 2.0
const MILL_LOWER_Y := 4.10
const MILL_UPPER_Y := 8.30

var c: Dictionary = {}
var outskirts: Dictionary = {}
var nodes: Dictionary = {}
var _banya_timer_generation := 0
var _banya_timer_director_generation := -1
var _banya_timer_queued := false
var _bathloft_generation := 0
var _bathloft_phase := "ground"
var _bathloft_return: Dictionary = {}
var _bathloft_tween: Tween = null
var _bathloft_pos := Vector3(6.55, 2.50, 23.90)
var _bathloft_distance := 0.0
var _bathloft_next_creak := 0.72
var _bathloft_events: Dictionary = {}
var _bathloft_after_take := 0.0
var _mill_level := "ground"
var _mill_generation := 0
var _mill_tween: Tween = null
var _mill_blade_pivot: Node3D = null
var _mill_blade_rest := 0.0

const BATHLOFT_SPEED := 0.48
const BATHLOFT_START_YAW := 2.10
const BATHLOFT_START_PITCH := -0.28
const BATHLOFT_MIN := Vector2(3.82, 22.02)
const BATHLOFT_MAX := Vector2(6.62, 25.78)
const BATHLOFT_BLOCKERS := [
	Rect2(4.82, 22.00, 0.60, 1.72),
	Rect2(5.08, 24.42, 0.78, 1.36),
]


func _init(ctx: Dictionary, outskirts_data: Dictionary) -> void:
	c = ctx
	outskirts = outskirts_data
	nodes = outskirts.get("nodes", {})


func register(I: Interact) -> void:
	var t := GameData.texts()
	var prompts: Dictionary = t["PROMPTS"]
	var beats: Dictionary = t["BEATS"]
	var looks: Dictionary = t["LOOKS"]

	_register_barrel(I, prompts, beats, looks)
	_register_leyka(I, prompts, beats)
	_register_tap(I, prompts, beats)
	_register_farm(I, prompts, beats, looks)
	_register_pump(I, prompts, beats)
	_register_rows(I, prompts, beats)
	_register_seedlings(I, prompts, beats, looks)
	_register_banya(I, prompts, beats, looks)
	_register_bathloft(I, prompts, beats)
	_bind_mill_blades()
	_register_mill(I, prompts, beats)
	_register_club(I, prompts, looks)
	_register_hens(I, prompts, looks)


# --------------------------------------------------------------- бочка ----

## Бочка у грядок — тот же узел, что держит спрей фазы 13 (interact.gd,
## id "spray-barrel"): к главе ДЕРЕВНЯ раствор давно вылит, и бочка стоит
## пустая, на дне ил и дохлые осы. Отдельной точки здесь нет: полив бочки
## водой из бани делает interact.gd прямо в её onUse, веткой по главе —
## описание см. там же.
func _register_barrel(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary) -> void:
	pass


# --------------------------------------------------------------- лейка ----

## Полка с инструментом в сарае Серёжи (site.json ROOMS.shed, x [5,8.6]
## z [10,14]) — рядом с верстаком, на который смотрит "shed-things"
## (interact.gd, глава ТЕМНОТА). Здесь новый предмет фазы 14.
func _register_leyka(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	# ФАЗА 17. Потолок 'village-done' стоит у ВСЕХ точек цепочки полива, и он
	# не про сюжет, а про погоню. Глава ДЕРЕВНЯ кончается флагом 'village-done'
	# (chapters._village_done), дальше идут ВОРОТА: гроза, снятая цепь, дед на
	# линии и четыре метра до машины. «Набрать воду» и «полить грядку» посреди
	# этого — не задача, а нажимаемая кнопка, и она отбирает [E] у того, что
	# в эту минуту действительно нужно.
	var when := func(s: GameState) -> bool:
		return s.atLeast("village") and not s.hasItem("leyka") \
			and not s.has("village-done")
	# ФАЗА 16. Точка была захардкожена на (6.90, 1.05, 12.50), а данные
	# (outskirts.json SHED_TOOL.can) говорили (6.6, 1.05, 11.6) — расхождение
	# 0.95 м, и секцию не читал ни один .gd. Захардкоженная точка встала так,
	# что подойти к ней было негде: капсула не помещалась нигде в радиусе.
	I.add({
		"id": "shed-leyka", "pos": _v3({}, "can", Vector3(6.60, 1.05, 11.60), "SHED_TOOL"),
		"r": 1.80, "cone": 0.55,
		"priority": 4, "prompt": prompts["take"],
		"when": when,
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.give("leyka")
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Лейка")
			cc["ui"].say(String(beats.get("leykaFound", "")), 3.2)
			_emit(cc, "leyka"),
	})


# ---------------------------------------------------------------- кран ----

func _register_tap(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	var tap := _v3(_yard(), "tap", Vector3(7.30, 0.65, 22.40), "banya")
	var tap_when := func(s: GameState) -> bool:
		return s.atLeast("village") and not s.has("village-done")
	var tap_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if not s.has("pump-on"):
			cc["ui"].say(String(beats.get("tapDry", "")), 3.2)
			return
		if s.has("leyka-filled"):
			cc["ui"].say(String(beats.get("tapAgain", "")), 2.6)
			return
		if not s.hasItem("leyka"):
			cc["ui"].say(String(beats.get("tapNoCan", "")), 3.0)
			return
		s.set_flag("leyka-filled")
		cc["audio"].sfx("item-take")
		cc["ui"].say(String(beats.get("tapFilled", "")), 3.4)
		_emit(cc, "leyka-filled")
	# Подпись — «набрать воду», а не общее «осмотреть»: у грядок ровно так же
	# сделано «полить». Игрок, наведшийся на кран со «осмотреть», уходит
	# искать другой кран — тот, который наливает.
	I.add({
		"id": "banya-tap", "pos": tap, "r": 1.90, "cone": 0.5, "priority": 4,
		"prompt": "набрать воду", "when": tap_when, "onUse": tap_use,
	})


# ---------------------------------------------------------------- ферма ----

func _register_farm(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary) -> void:
	var key_when := func(s: GameState) -> bool:
		return s.atLeast("village") and not s.hasItem("farm-key") \
			and not s.has("village-done")
	var key_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.give("farm-key")
		_show("farm-key", false)
		cc["audio"].sfx("item-take")
		cc["ui"].toast("Ключ от водокачки")
		cc["ui"].say(String(beats.get("farmKeyFound", "")), 3.6)
		_emit(cc, "farm-key")
		# ФАЗА 17. Был полнокадровый удар. Стал испуг по месту — точка
		# 'barn-stall' стоит ровно здесь, в полутора метрах от гвоздя:
		# фигура за перегородками, в третьем стойле, досок ей по грудь.
		#
		# ПОЧЕМУ ПОНИЖЕН. До фазы 17 полив был добровольным, и до этого ключа
		# доходил не каждый. Теперь он обязателен, и на один маршрут главы
		# встали бы четыре полных кадра при потолке два (см.
		# tests/test_scares_budget.gd): scare.gd держит три перепада яркости
		# за 1.15 с, четвёртый запрещён порогом WCAG 2.3.1.
		#
		# Момент при этом не пропал: та же секунда, та же фигура, то же
		# место. Бонусом удар уходит под бюджет главы и общий кулдаун
		# 18 с — у _hit_full нет ни того, ни другого.
		_after(0.9, func() -> void:
			var st: Variant = cc.get("startle")
			if st != null and st.has_method("force"):
				st.force("barn-stall"))
	I.add({
		"id": "farm-key", "pos": _v3({}, "key", Vector3(-35.2, 1.15, -29.4), "FARM"),
		"r": 1.90, "cone": 0.5, "priority": 5,
		"prompt": prompts["take"], "when": key_when, "onUse": key_use,
	})

	var barn_line := String(looks.get("farm-barn", ""))
	if barn_line != "":
		I.add({
			# ФАЗА 18. Точка переехала с (-36.50, 1.40, -28.00) на перегородку
			# второго стойла. Старая висела в воздухе посреди амбара: ближайшим
			# полигоном к ней была СЛУЧАЙНАЯ травинка от Scatter, и стоило
			# раскладке сдвинуться на одну позицию (новые полосы CLEAR фазы 18),
			# как точка осталась вовсе без тела — tests/test_points_visible.gd
			# поймал это немедленно. Теперь она на том, о чём и говорит:
			# «Стойла целы, скотины нет» (FARM.barn.stalls, h 1.25).
			"id": "farm-barn", "pos": Vector3(-35.10, 1.30, -29.40),
			"r": 3.20, "cone": 0.55, "kind": "look", "priority": 1,
			"prompt": prompts["look"],
			"when": func(s: GameState) -> bool: return s.atLeast("village"),
			"onUse": func(cc: Dictionary) -> void:
				(cc["state"] as GameState).looked["farm-barn"] = true
				cc["ui"].say(barn_line, 3.6)
				_emit(cc, "look", "farm-barn"),
		})


# ------------------------------------------------------------ водокачка ----

func _register_pump(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	var door_when := func(s: GameState) -> bool:
		return s.atLeast("village") and not s.has("pump-open") \
			and not s.has("village-done")
	var door_prompt := func(s: GameState) -> String:
		return prompts["open"] if s.hasItem("farm-key") else prompts["locked"]
	var door_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if not s.hasItem("farm-key"):
			cc["ui"].say(String(beats.get("pumpLocked", "")), 3.4)
			_emit(cc, "pump-locked")
			return
		s.set_flag("pump-open")
		var col: Variant = cc.get("col")
		if col != null:
			col.set_blocker_active("door-pump", false)
		var ph: Variant = cc.get("physics")
		if ph != null:
			ph.sync()
		var leaf: Variant = nodes.get("door-pump")
		if leaf is Node3D:
			(leaf as Node3D).rotation.y = -1.35
		cc["audio"].door(true)
		cc["ui"].say(String(beats.get("pumpOpen", "")), 3.4)
		_emit(cc, "pump-open")
	I.add({
		"id": "door-pump", "pos": Vector3(-15.0, 1.05, -28.05), "r": 2.10, "priority": 4,
		"prompt": door_prompt, "when": door_when, "onUse": door_use,
	})

	var brk_when := func(s: GameState) -> bool:
		return s.has("pump-open") and not s.has("pump-on") \
			and not s.has("village-done")
	var brk_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.set_flag("pump-on")
		cc["audio"].sfx("breaker")
		var dr: Variant = cc.get("dread")
		if dr != null:
			dr.force("hum-rise")
		# Лампа будки — единственное подтверждение, что рубильник сработал:
		# гудеть насос начинает через паузу, а свет даёт ответ сразу.
		var lt: Variant = cc.get("lights")
		if lt != null:
			lt.setLamp("pump", true)
		cc["ui"].say(String(beats.get("pumpOn", "")), 3.6)
		_village_line(cc, "phase14-1")
		_emit(cc, "pump-on")
	I.add({
		# Запасное значение — ровно то же, что в данных: разошедшийся на
		# полметра фолбэк молчит, пока не пропадёт секция, и стреляет тогда,
		# когда разбираться уже некогда.
		"id": "pump-breaker", "pos": _v3({}, "breaker", Vector3(-15.0, 1.25, -30.05), "PUMP"),
		"r": 1.70, "cone": 0.55, "priority": 4,
		"prompt": prompts["use"], "when": brk_when, "onUse": brk_use,
	})


# ---------------------------------------------------------------- грядки ----

## Четыре визуальные секции из world_builder.ground(): x [-4.2,3.0],
## z = 17.4 + i*2.1. Числа те же, что в геометрии — здесь только точки
## интеракта поверх готового пола.
func _register_rows(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	for i in 4:
		var z := 17.4 + float(i) * 2.1
		var last := i == 3
		var flag := "watered-%d" % i
		I.add({
			"id": "water-row-%d" % i,
			"pos": Vector3(-0.6, 0.16, z + 0.55), "r": 2.30, "cone": 0.5, "priority": 3,
			"prompt": "полить",
			"when": func(s: GameState) -> bool:
				return s.hasItem("leyka") and s.has("leyka-filled") \
					and not s.has("water-done") and not s.has(flag) \
					and not s.has("village-done"),
			"onUse": func(cc: Dictionary) -> void:
				var s: GameState = cc["state"]
				s.set_flag(flag)
				_show_yard("wet-row-%d" % i, true)
				cc["audio"].sfx("item-take")
				if last:
					# Тихо, без полного кадра: вода уходит мгновенно, будто
					# под грядкой пусто — тот же «крот», что в кассете «ОГОРОД».
					cc["ui"].say(String(beats.get("waterGone", "")), 4.0)
					_emit(cc, "water-gone")
				else:
					cc["ui"].say(String(beats.get("watered", "")), 2.2)
					_emit(cc, "watered", flag)
				if _rows_watered(s):
					s.set_flag("water-done")
					_emit(cc, "water-done"),
		})


func _rows_watered(s: GameState) -> bool:
	if s.has("water-done"):
		return true
	for i in 4:
		if not s.has("watered-%d" % i):
			return false
	return true


# --------------------------------------------------------------- теплица ----

func _register_seedlings(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary) -> void:
	var vent_when := func(s: GameState) -> bool:
		return s.atLeast("village") and not s.has("vent-shut")
	I.add({
		"id": "greenhouse-vent", "pos": Vector3(2.0, 2.30, 21.5), "r": 1.60, "priority": 4,
		"prompt": "закрыть форточку",
		"when": vent_when,
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("vent-shut")
			cc["audio"].creak(0.35)
			cc["ui"].say(String(beats.get("ventShut", "")), 2.8)
			_emit(cc, "vent-shut"),
	})

	var water_when := func(s: GameState) -> bool:
		return s.hasItem("leyka") and s.has("leyka-filled") and not s.has("seedlings-done")
	I.add({
		# Радиус 2.5, а не полтора: рассада стоит в глубине теплицы, за стеллажом,
		# и подойти к ней вплотную негде — ближайшая клетка, с которой её видно,
		# в двух с лишним метрах (замерено tests/audit_reach.gd). Точка на
		# высоте 1.0: с 0.20 луч видимости упирался в тот же стеллаж.
		"id": "greenhouse-seedlings", "pos": Vector3(-7.0, 1.00, 21.0), "r": 2.50, "priority": 3,
		"prompt": "полить рассаду",
		"when": water_when,
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("seedlings-done")
			cc["audio"].sfx("item-take")
			cc["ui"].say(String(beats.get("seedlingsWatered", "")), 3.2)
			_emit(cc, "seedlings-done"),
	})

	var print_line := String(looks.get("greenhouse-print", ""))
	if print_line != "":
		I.add({
			"id": "greenhouse-print",
			"pos": _v3({}, "print", Vector3(-8.55, 1.35, 21.0), "GREENHOUSE_NIGHT"),
			"r": 1.40, "cone": 0.55, "kind": "look", "priority": 2,
			"prompt": prompts["look"],
			"when": func(s: GameState) -> bool: return s.has("vent-shut"),
			"onUse": func(cc: Dictionary) -> void:
				(cc["state"] as GameState).looked["greenhouse-print"] = true
				cc["ui"].say(print_line, 4.0)
				_emit(cc, "look", "greenhouse-print"),
		})


# --------------------------------------------------------------- чердак ----

## Баня, вторая половина (фаза 15). Первая — фаза 13: дрова из поленницы
## в каменку. Здесь то, что за этим следует и чего до фазы 15 не было:
## заслонка, время и то, что за это время в парилке завелось.
##
## ПОЧЕМУ ЧЕРЕЗ ВРЕМЯ, А НЕ СРАЗУ. «Протопи» — единственное задание игры,
## которое нельзя выполнить одним нажатием: баня греется, и пока она греется,
## игрок обязан заняться чем-то другим. Полтора десятка минут в этом месте
## главы у него и так есть — камни, покос, полив, — и задание ложится в них,
## не отнимая ни минуты сверх.
func _register_banya(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary) -> void:
	# Заслонка. Топка без неё — это дым в предбанник и холодная парилка,
	# и Витя об этом писал в дневнике (DIARY, «заслонку до половины»).
	I.add({
		"id": "banya-damper",
		"pos": Vector3(3.52, 1.35, 24.30), "r": 1.70, "cone": 0.50, "priority": 5,
		"prompt": "прикрыть заслонку",
		"when": func(s: GameState) -> bool:
			return s.has("banya-fired") and not s.has("damper-shut"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("damper-shut")
			cc["audio"].sfx("switch-dead")
			cc["ui"].say(String(beats.get("damperShut", "")), 4.2)
			_emit(cc, "damper-shut")
			# Полтора десятка минут на всё остальное. Возвращаться незачем
			# раньше: до BANYA_WARM парилка ровно та же, что была.
			_schedule_banya_heat(cc, beats),
	})

	# Запотевшее стекло изнутри. Надпись сделана ПАЛЬЦЕМ ИЗНУТРИ, то есть
	# кем-то, кто был в закрытой парилке, пока грелось.
	#
	# Испуг здесь НЕ полнокадровый: полнокадровых на часть ровно два, и оба
	# расписаны за холмом и за оградой. Здесь — хлопок двери предбанника
	# за спиной, то есть между игроком и выходом.
	I.add({
		"id": "banya-steam",
		"pos": Vector3(2.95, 1.50, 22.30), "r": 1.90, "cone": 0.50, "priority": 5,
		"prompt": func(s: GameState) -> String:
			return prompts["look"] if s.has("banya-written") else "прочитать",
		"when": func(s: GameState) -> bool:
			return s.has("banya-hot"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if s.has("banya-written"):
				cc["ui"].say(String(looks.get("banya-steam", "")), 3.4)
				return
			s.set_flag("banya-written")
			s.evidence = true
			# ФАЗА 18. Надпись — «НЕ ХОДИ НА ОЗЕРО» — ставит lake-told.
			# До сих пор озеро открывал ровно один источник: вторая реплика
			# Вали. Линия озера была связана с её внуком только в замысле,
			# а в игре доходила до игрока одним путём или не доходила вовсе.
			# Теперь входов два, и второй — тот, кто сидел в парилке.
			s.set_flag("lake-told")
			cc["ui"].say(String(beats.get("banyaWritten", "")), 5.0)
			_emit(cc, "banya-written")
			# Дверь предбанника. Секунда на то, чтобы игрок дочитал надпись
			# и перестал следить за спиной, — та же задержка, что у тетради
			# в детской.
			Interact._after(1.0, func() -> void:
				cc["audio"].sfx("door-close", 1.0)
				cc["renderer"].set_tracking(0.55)
				Interact._after(0.7, func() -> void:
					cc["renderer"].set_tracking(0.0))),
	})


func _register_bathloft(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	# The first E only climbs.  The persisted evidence flag belongs to the
	# cassette on the beam and cannot be set before the second E in the attic.
	var when := func(s: GameState) -> bool:
		return s.atLeast("village") and s.has("banya-written") \
			and s.has("lantern-lit") \
			and not s.has("bathloft-found") and _bathloft_phase == "ground"
	I.add({
		"id": "bathloft", "pos": Vector3(7.42, 1.90, 23.90), "r": 1.70, "cone": 0.55,
		"priority": 3, "prompt": "подняться по приставной лестнице на чердак бани",
		"when": when,
		"onUse": func(cc: Dictionary) -> void:
			_begin_bathloft_ascent(cc),
	})

	I.add({
		"id": "bathloft-cassette",
		"pos": Vector3(3.95, 2.82, 25.30), "r": 0.90, "cone": 0.55,
		"priority": 6, "prompt": "снять кассету с балки",
		"when": func(s: GameState) -> bool:
			return _bathloft_phase == "loft" and not s.has("bathloft-found"),
		"onUse": func(cc: Dictionary) -> void:
			_take_bathloft_cassette(cc, beats),
	})

	I.add({
		"id": "bathloft-exit", "pos": Vector3(6.48, 2.78, 23.90),
		"r": 0.90, "cone": 0.70, "priority": 5,
		"prompt": "спуститься по лестнице",
		"when": func(_s: GameState) -> bool:
			return _bathloft_phase == "loft" or _bathloft_phase == "inspecting",
		"onUse": func(cc: Dictionary) -> void:
			_begin_bathloft_descent(_bathloft_generation, cc),
	})


func _begin_bathloft_ascent(cc: Dictionary) -> void:
	if _bathloft_phase != "ground":
		return
	var ctrl: Variant = cc.get("controls")
	if ctrl == null or not ctrl.has_method("feet"):
		return
	var camera: Variant = ctrl.get("camera")
	if not (camera is Camera3D) or not (ctrl is Node):
		return
	_bathloft_generation += 1
	var generation := _bathloft_generation
	_bathloft_phase = "ascending"
	_bathloft_return = {
		"feet": ctrl.feet(), "yaw": float(ctrl.get("yaw")),
		"pitch": float(ctrl.get("pitch")), "enabled": bool(ctrl.get("enabled")),
		"frozen": bool(ctrl.get("frozen")),
		"camera": (camera as Camera3D).global_transform,
	}
	ctrl.set("frozen", true)
	ctrl.set("enabled", false)
	var audio: Variant = cc.get("audio")
	if audio != null and audio.has_method("creak"):
		audio.creak(0.65)
	var target := Transform3D(
		Basis.from_euler(Vector3(BATHLOFT_START_PITCH, BATHLOFT_START_YAW, 0.0),
			EULER_ORDER_YXZ),
		Vector3(6.55, 2.50, 23.90))
	_start_bathloft_tween(cc, (camera as Camera3D).global_transform, target,
		2.45, generation, Callable(self, "_finish_bathloft_ascent"))


func _finish_bathloft_ascent(generation: int, cc: Dictionary) -> void:
	if not _bathloft_callback_valid(generation, cc, "ascending"):
		return
	_bathloft_tween = null
	_bathloft_phase = "loft"
	var ctrl: Variant = cc.get("controls")
	if ctrl != null:
		# Keep Player mouse-look active, but leave its body frozen at the ladder.
		# The diagonal heading exposes the S-shaped crawl route instead of looking
		# edge-on through the bath ceiling boards at the hatch.
		ctrl.set("yaw", BATHLOFT_START_YAW)
		ctrl.set("yaw_target", BATHLOFT_START_YAW)
		ctrl.set("pitch", BATHLOFT_START_PITCH)
		ctrl.set("pitch_target", BATHLOFT_START_PITCH)
		ctrl.set("enabled", true)
		ctrl.set("frozen", true)
	_bathloft_pos = (cc["controls"].get("camera") as Camera3D).global_position
	_bathloft_distance = 0.0
	_bathloft_next_creak = 0.72
	_bathloft_events.clear()
	_bathloft_after_take = 0.0
	var audio: Variant = cc.get("audio")
	if audio != null and audio.has_method("tape_bed"):
		audio.tape_bed(true)
	_show_yard("bathloft-tape", true)
	var ui: Variant = cc.get("ui")
	if ui != null:
		ui.say("Под самой кровлей. Кассета лежит на пыльной балке.", 2.4)


func _take_bathloft_cassette(cc: Dictionary, beats: Dictionary) -> void:
	if _bathloft_phase != "loft":
		return
	var st: Variant = cc.get("state")
	if not (st is GameState) or st.has("bathloft-found"):
		return
	_bathloft_phase = "inspecting"
	_show_yard("bathloft-tape", false)
	st.set_flag("bathloft-found")
	st.evidence = true
	var audio: Variant = cc.get("audio")
	if audio != null and audio.has_method("sfx"):
		audio.sfx("item-take")
	var ui: Variant = cc.get("ui")
	if ui != null:
		ui.say(String(beats.get("bathloftFound", "")), 4.0)
	# The warning belongs to taking the cassette itself. Play it immediately so
	# a retry during the following inspection/descent cannot swallow the only
	# occurrence; the phase guard above prevents a second call.
	_village_line(cc, "phase14-3")
	_bathloft_after_take = 0.01
	if ui != null:
		ui.toast("Вернуться к лазу и спуститься")


func _begin_bathloft_descent(generation: int, cc: Dictionary) -> void:
	if generation != _bathloft_generation \
			or (_bathloft_phase != "loft" and _bathloft_phase != "inspecting"):
		return
	var ctrl: Variant = cc.get("controls")
	if ctrl == null:
		_cancel_bathloft(true)
		return
	var camera: Variant = ctrl.get("camera")
	if not (camera is Camera3D):
		_cancel_bathloft(true)
		return
	_bathloft_phase = "descending"
	ctrl.set("enabled", false)
	_stop_bathloft_bed(cc)
	var audio: Variant = cc.get("audio")
	if audio != null and audio.has_method("creak"):
		audio.creak(0.45)
	var end: Transform3D = _bathloft_return.get("camera", (camera as Camera3D).global_transform)
	_start_bathloft_tween(cc, (camera as Camera3D).global_transform, end,
		2.15, generation, Callable(self, "_finish_bathloft_descent"))


func _finish_bathloft_descent(generation: int, cc: Dictionary) -> void:
	if not _bathloft_callback_valid(generation, cc, "descending"):
		return
	_bathloft_tween = null
	_restore_bathloft_control(cc)
	_bathloft_phase = "ground"
	_bathloft_return.clear()
	# Only now is the camera back at the ladder and ordinary input restored; the
	# next HUD objective must not replace the attic action midway through it.
	_emit(cc, "bathloft-found")


func _start_bathloft_tween(cc: Dictionary, from: Transform3D, to: Transform3D,
		duration: float, generation: int, done: Callable) -> void:
	var ctrl: Variant = cc.get("controls")
	if not (ctrl is Node):
		return
	if _bathloft_tween != null:
		_bathloft_tween.kill()
	_bathloft_tween = (ctrl as Node).create_tween()
	_bathloft_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	_bathloft_tween.tween_method(
		func(weight: float) -> void:
			_bathloft_camera_frame(weight, generation, cc, from, to),
		0.0, 1.0, duration)
	_bathloft_tween.tween_callback(func() -> void:
		done.call(generation, cc))


func _bathloft_camera_frame(weight: float, generation: int, cc: Dictionary,
		from: Transform3D, to: Transform3D) -> void:
	if generation != _bathloft_generation:
		return
	var st: Variant = cc.get("state")
	if not (st is GameState) or st.chapter != "village":
		_cancel_bathloft(true)
		return
	var ctrl: Variant = cc.get("controls")
	if ctrl == null:
		return
	var camera: Variant = ctrl.get("camera")
	if not (camera is Camera3D):
		return
	var frame := from.interpolate_with(to, weight)
	(camera as Camera3D).global_transform = frame
	var lights: Variant = cc.get("lights")
	if lights != null and lights.has_method("move_lamp"):
		lights.move_lamp("lantern", frame.origin + Vector3(0.12, -0.30, 0.0))


func _bathloft_callback_valid(generation: int, cc: Dictionary,
		phase: String) -> bool:
	if generation != _bathloft_generation or _bathloft_phase != phase:
		return false
	var st: Variant = cc.get("state")
	if not (st is GameState) or st.chapter != "village":
		_cancel_bathloft(true)
		return false
	return true


func _restore_bathloft_control(cc: Dictionary) -> void:
	if _bathloft_return.is_empty():
		return
	var ctrl: Variant = cc.get("controls")
	if ctrl == null:
		return
	var feet: Vector3 = _bathloft_return.get("feet", Vector3(8.05, 0.0, 23.90))
	var yaw := float(_bathloft_return.get("yaw", PI / 2.0))
	if ctrl.has_method("place"):
		ctrl.place(feet.x, feet.y, feet.z, yaw)
	ctrl.set("pitch", float(_bathloft_return.get("pitch", 0.0)))
	ctrl.set("pitch_target", float(_bathloft_return.get("pitch", 0.0)))
	ctrl.set("frozen", bool(_bathloft_return.get("frozen", false)))
	ctrl.set("enabled", bool(_bathloft_return.get("enabled", true)))
	var camera: Variant = ctrl.get("camera")
	if camera is Camera3D:
		(camera as Camera3D).global_transform = _bathloft_return.get(
			"camera", (camera as Camera3D).global_transform)
	var lights: Variant = cc.get("lights")
	if lights != null and lights.has_method("move_lamp"):
		lights.move_lamp("lantern", feet + Vector3(0.0, 1.12, 0.0))


func _cancel_bathloft(restore_control: bool) -> void:
	_bathloft_generation += 1
	if _bathloft_tween != null:
		_bathloft_tween.kill()
		_bathloft_tween = null
	if restore_control:
		_restore_bathloft_control(c)
	_stop_bathloft_bed(c)
	_bathloft_phase = "ground"
	_bathloft_return.clear()
	_show_yard("bathloft-tape", false)


func exclusive_runtime() -> bool:
	return _bathloft_phase in ["ascending", "loft", "inspecting", "descending"]


## Player keeps mouse-look alive while its body stays beside the ladder. This
## controller runs after Player.update and replaces only the camera position.
func update(dt: float) -> void:
	if _mill_blade_pivot == null or not is_instance_valid(_mill_blade_pivot):
		_bind_mill_blades()
	var s: Variant = c.get("state")
	if _mill_blade_pivot != null and is_instance_valid(_mill_blade_pivot) \
			and s is GameState and not (s as GameState).has("mill-braked"):
		_mill_blade_pivot.rotation.z += dt * 0.36
	if _bathloft_phase != "loft" and _bathloft_phase != "inspecting":
		return
	var ctrl: Variant = c.get("controls")
	if ctrl == null:
		_cancel_bathloft(true)
		return
	var camera: Variant = ctrl.get("camera")
	if not (camera is Camera3D):
		_cancel_bathloft(true)
		return
	var fwd := (1 if Input.is_action_pressed("move_forward") else 0) \
		- (1 if Input.is_action_pressed("move_back") else 0)
	var side := (1 if Input.is_action_pressed("move_right") else 0) \
		- (1 if Input.is_action_pressed("move_left") else 0)
	var yaw := float(ctrl.get("yaw"))
	var wish := Vector2(-sin(yaw) * fwd + cos(yaw) * side,
		-cos(yaw) * fwd - sin(yaw) * side)
	if wish.length_squared() > 1.0:
		wish = wish.normalized()
	var before := _bathloft_pos
	var candidate := Vector2(before.x, before.z) + wish * BATHLOFT_SPEED * dt
	candidate.x = clampf(candidate.x, BATHLOFT_MIN.x, BATHLOFT_MAX.x)
	candidate.y = clampf(candidate.y, BATHLOFT_MIN.y, BATHLOFT_MAX.y)
	if not _bathloft_blocked(candidate):
		_bathloft_pos.x = candidate.x
		_bathloft_pos.z = candidate.y
	var moved := Vector2(_bathloft_pos.x - before.x, _bathloft_pos.z - before.z).length()
	_bathloft_distance += moved
	if _bathloft_distance >= _bathloft_next_creak:
		_bathloft_next_creak += 0.82
		var audio: Variant = c.get("audio")
		if audio != null and audio.has_method("creak"):
			audio.creak(0.42)
	_bathloft_scares(dt)
	var crawl_bob := sin(_bathloft_distance * 12.0) * minf(1.0, moved / maxf(dt, 0.001)) * 0.006
	var basis := Basis.from_euler(Vector3(float(ctrl.get("pitch")), yaw,
		sin(_bathloft_distance * 6.0) * 0.004), EULER_ORDER_YXZ)
	(camera as Camera3D).global_transform = Transform3D(basis,
		_bathloft_pos + Vector3(0.0, crawl_bob, 0.0))
	var lights: Variant = c.get("lights")
	if lights != null and lights.has_method("move_lamp"):
		lights.move_lamp("lantern", _bathloft_pos + Vector3(0.12, -0.12, 0.0))


func _bathloft_blocked(p: Vector2) -> bool:
	for blocker: Rect2 in BATHLOFT_BLOCKERS:
		if blocker.grow(0.18).has_point(p):
			return true
	return false


func _bathloft_scares(dt: float) -> void:
	var horror: Variant = c.get("horror")
	if horror != null:
		horror.thresholds.update_bathloft(dt, _bathloft_pos, _bathloft_phase)


func _stop_bathloft_bed(cc: Dictionary) -> void:
	var audio: Variant = cc.get("audio")
	if audio != null and audio.has_method("tape_bed"):
		audio.tape_bed(false)


# ------------------------------------------------------- старая мельница ----

## Сюжет мельницы сохраняет только три факта. Высота игрока, переходы камеры,
## звук шагов и текущий угол лопастей намеренно остаются состоянием попытки.
func _register_mill(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	I.add({
		"id": "mill-base", "pos": _mill_pos(Vector3(-0.86, 0.92, 1.32)),
		"r": 1.75, "cone": 0.45, "priority": 6, "prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			return s.chapter == "village" and s.has("bathloft-found") \
				and not s.has("mill-seen") and _mill_level == "ground",
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("mill-seen")
			var ui: Variant = cc.get("ui")
			if ui != null: ui.say(String(beats.get("millSeen", "")), 4.0)
			_mill_steps(cc, 4)
			_emit(cc, "mill-seen"),
	})

	I.add({
		"id": "mill-ladder-lower", "pos": _mill_pos(Vector3(-0.86, 0.86, 1.32)),
		"r": 1.35, "cone": 0.48, "priority": 5, "prompt": prompts["climb"],
		"when": func(s: GameState) -> bool:
			return s.chapter == "village" and s.has("mill-seen") \
				and not s.has("mill-clue") and _mill_level == "ground",
		"onUse": func(cc: Dictionary) -> void:
			_begin_mill_transition(cc, "lower"),
	})

	I.add({
		"id": "mill-wheel", "pos": _mill_pos(Vector3(-0.92, 2.83, 0.10)),
		"r": 1.90, "cone": 0.46, "priority": 7,
		"prompt": "затормозить лопасти ручным колесом",
		"when": func(s: GameState) -> bool:
			return s.chapter == "village" and _mill_level == "lower" \
				and not s.has("mill-braked"),
		"onUse": func(cc: Dictionary) -> void:
			_brake_mill(cc, beats),
	})

	I.add({
		"id": "mill-ladder-upper", "pos": _mill_pos(Vector3(0.68, 3.02, 1.05)),
		"r": 1.80, "cone": 0.46, "priority": 6, "prompt": prompts["climb"],
		"when": func(s: GameState) -> bool:
			return s.chapter == "village" and s.has("mill-braked") \
				and not s.has("mill-clue") and _mill_level == "lower",
		"onUse": func(cc: Dictionary) -> void:
			_begin_mill_transition(cc, "upper"),
	})

	I.add({
		"id": "mill-journal", "pos": _mill_pos(Vector3(0.42, 4.34, -0.34)),
		"r": 1.10, "cone": 0.52, "priority": 8, "prompt": prompts["read"],
		"when": func(s: GameState) -> bool:
			return s.chapter == "village" and _mill_level == "upper" \
				and s.has("mill-braked") and not s.has("mill-clue"),
		"onUse": func(cc: Dictionary) -> void:
			_open_mill_journal(cc, beats),
	})

	# Оба спуска ручные. Это оставляет площадки настоящим игровым местом, а не
	# однонаправленной кат-сценой, и даёт уйти до чтения журнала.
	I.add({
		"id": "mill-down-upper", "pos": _mill_pos(Vector3(0.68, 4.34, 1.05)),
		"r": 1.12, "cone": 0.52, "priority": 5, "prompt": "спуститься ниже",
		"when": func(s: GameState) -> bool:
			return s.chapter == "village" and _mill_level == "upper",
		"onUse": func(cc: Dictionary) -> void:
			_begin_mill_transition(cc, "lower"),
	})
	I.add({
		"id": "mill-down-lower", "pos": _mill_pos(Vector3(-0.86, 2.30, 1.32)),
		"r": 1.12, "cone": 0.52, "priority": 5, "prompt": "спуститься на землю",
		"when": func(s: GameState) -> bool:
			return s.chapter == "village" and _mill_level == "lower",
		"onUse": func(cc: Dictionary) -> void:
			_begin_mill_transition(cc, "ground"),
	})


func _mill_pos(original_offset: Vector3) -> Vector3:
	# Все точки берутся от одного сохранённого центра; коэффициент относится
	# только к геометрии и не создаёт нового состояния сохранения.
	return MILL_CENTER + original_offset * MILL_FACTOR


func _bind_mill_blades() -> void:
	if _mill_blade_pivot != null and is_instance_valid(_mill_blade_pivot):
		return
	var props: Variant = c.get("props")
	if props == null or not props.has_method("get_prop"):
		return
	var holder: Variant = props.get_prop("old-windmill")
	if not (holder is Node3D):
		return
	var blade := _find_mill_blade(holder as Node)
	if not (blade is Node3D):
		return
	var parent := (blade as Node3D).get_parent()
	if not (parent is Node3D):
		return
	var pivot := Node3D.new()
	pivot.name = "StoryBladePivot"
	# Центр снят с исходного farm-windmill.glb. Pivot живёт под тем же
	# масштабированным родителем, поэтому отдельный пересчёт 0.65 не нужен.
	pivot.position = Vector3(0.014, 7.404, 1.506)
	(parent as Node3D).add_child(pivot)
	(blade as Node3D).reparent(pivot, true)
	_mill_blade_pivot = pivot
	_mill_blade_rest = -PI * 0.25


func _find_mill_blade(root: Node) -> Node3D:
	for child: Node in root.get_children():
		if child is Node3D:
			var low := String(child.name).to_lower()
			if String(child.name) == "TowerWindmill_Blades_Cylinder.006" \
					or (low.contains("blades") and low.contains("cylinder")):
				return child as Node3D
		var nested := _find_mill_blade(child)
		if nested != null:
			return nested
	return null


func _brake_mill(cc: Dictionary, beats: Dictionary) -> void:
	var s: Variant = cc.get("state")
	if not (s is GameState) or s.has("mill-braked") or _mill_level != "lower":
		return
	s.set_flag("mill-braked")
	_set_mill_braked(true, cc)
	var wheel: Variant = nodes.get("mill-wheel")
	if wheel is Node3D:
		(wheel as Node3D).rotation.z -= 0.72
	var audio: Variant = cc.get("audio")
	if audio != null and audio.has_method("creak"):
		audio.creak(0.82)
	var ui: Variant = cc.get("ui")
	if ui != null:
		ui.say(String(beats.get("millBraked", "")), 3.8)
	# Хоррор-правило: источник шагов не был лопастями — после тормоза они
	# продолжаются с площадки над игроком.
	_mill_steps(cc, 3)
	_emit(cc, "mill-braked")


func _set_mill_braked(on: bool, cc: Dictionary) -> void:
	_bind_mill_blades()
	if on and _mill_blade_pivot != null and is_instance_valid(_mill_blade_pivot):
		_mill_blade_pivot.rotation.z = _mill_blade_rest
	var col: Variant = cc.get("col")
	if col != null and col.has_method("set_blocker_active"):
		col.set_blocker_active("mill-upper-blade", not on)
	var physics: Variant = cc.get("physics")
	if physics != null and physics.has_method("sync"):
		physics.sync()


func _begin_mill_transition(cc: Dictionary, target_level: String) -> void:
	if _mill_level == "transition" or target_level not in ["ground", "lower", "upper"]:
		return
	var ctrl: Variant = cc.get("controls")
	if not (ctrl is Node) or not ctrl.has_method("feet"):
		return
	var camera: Variant = ctrl.get("camera")
	if not (camera is Camera3D):
		return
	var from_level := _mill_level
	var feet := _mill_feet(target_level, from_level)
	var yaw := 0.0 if target_level == "upper" else PI
	var target := Transform3D(
		Basis.from_euler(Vector3(-0.06, yaw, 0.0), EULER_ORDER_YXZ),
		feet + Vector3(0.0, 1.58, 0.0))
	_mill_generation += 1
	var generation := _mill_generation
	_mill_level = "transition"
	ctrl.set("enabled", false)
	ctrl.set("frozen", true)
	var audio: Variant = cc.get("audio")
	if audio != null and audio.has_method("creak"):
		audio.creak(0.54)
	if _mill_tween != null:
		_mill_tween.kill()
	_mill_tween = (ctrl as Node).create_tween()
	_mill_tween.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	var start := (camera as Camera3D).global_transform
	_mill_tween.tween_method(func(weight: float) -> void:
		if generation == _mill_generation and camera is Camera3D:
			(camera as Camera3D).global_transform = start.interpolate_with(target, weight),
		0.0, 1.0, 1.65)
	_mill_tween.tween_callback(func() -> void:
		_finish_mill_transition(generation, cc, target_level, feet, yaw))


func _mill_feet(target_level: String, from_level: String) -> Vector3:
	match target_level:
		"upper": return _mill_pos(Vector3(0.68, 4.15, 0.77))
		"lower":
			return _mill_pos(Vector3(0.34, 2.05, 0.80)) if from_level == "upper" \
				else _mill_pos(Vector3(-0.86, 2.05, 0.82))
		_: return _mill_pos(Vector3(-0.86, 0.0, 1.44))


func _finish_mill_transition(generation: int, cc: Dictionary,
		target_level: String, feet: Vector3, yaw: float) -> void:
	if generation != _mill_generation or _mill_level != "transition":
		return
	var s: Variant = cc.get("state")
	if not (s is GameState) or s.chapter != "village":
		_cancel_mill_transition(true)
		return
	_mill_tween = null
	var ctrl: Variant = cc.get("controls")
	if ctrl != null:
		if ctrl.has_method("place"):
			ctrl.place(feet.x, feet.y, feet.z, yaw)
		ctrl.set("pitch", -0.06)
		ctrl.set("pitch_target", -0.06)
		ctrl.set("frozen", false)
		ctrl.set("enabled", true)
	_mill_level = target_level
	if target_level == "lower" and not s.has("mill-braked"):
		_mill_steps(cc, 4)
	elif target_level == "upper":
		_mill_steps(cc, 2)
	_emit(cc, "mill-level", target_level)


func _cancel_mill_transition(restore_control: bool) -> void:
	_mill_generation += 1
	if _mill_tween != null:
		_mill_tween.kill()
		_mill_tween = null
	if restore_control:
		var ctrl: Variant = c.get("controls")
		if ctrl != null:
			ctrl.set("frozen", false)
			ctrl.set("enabled", true)
	_mill_level = "ground"


func _open_mill_journal(cc: Dictionary, beats: Dictionary) -> void:
	var s: Variant = cc.get("state")
	if not (s is GameState) or s.has("mill-clue") or _mill_level != "upper":
		return
	var ui: Variant = cc.get("ui")
	if ui == null or not ui.has_method("openReader"):
		_finish_mill_clue(cc, beats)
		return
	var pages := [
		"ИЮЛЬ. Наблюдения с верхней площадки.\n\n"
			+ "08:10 — женщина у воды, одна. 12:40 — двое с сетью. "
			+ "19:15 — мальчик на дальнем берегу. Витя отмечал каждого, "
			+ "кто выходил к озеру, и куда тот потом сворачивал.",
		"Последняя страница исписана другим, твёрдым карандашом:\n\n"
			+ "НЕ ПОДНИМАЙСЯ, КОГДА ЛОПАСТИ ИДУТ БЕЗ ВЕТРА.\n\n"
			+ "Ниже — даты и знак старой мельницы. Под последней датой: «Продолжение в журнале обходов правления СНТ. Береговой сигнальный пост, четвёртая линия. Проверить, кто отвечал Ковригину». Правление стоит за околицей, у третьей линии.",
	]
	if ui.has_method("setReaderTitle"):
		ui.setReaderTitle("ЖУРНАЛ НАБЛЮДЕНИЙ")
	ui.openReader("ЖУРНАЛ НАБЛЮДЕНИЙ", pages, func() -> void:
		_finish_mill_clue(cc, beats))


func _finish_mill_clue(cc: Dictionary, beats: Dictionary) -> void:
	var s: Variant = cc.get("state")
	if not (s is GameState) or s.has("mill-clue"):
		return
	s.set_flag("mill-clue")
	s.set_flag("lake-told")
	s.evidence = true
	_show("mill-journal", false)
	# На верхней площадке висел не человек, а ватник. После чтения нет уже и
	# его; ответ приходит снизу, от лестницы, которой игрок должен спуститься.
	_show("mill-coat", false)
	var audio: Variant = cc.get("audio")
	if audio != null and audio.has_method("sfx"):
		audio.sfx("item-take")
	_mill_steps(cc, 4)
	var ui: Variant = cc.get("ui")
	if ui != null:
		ui.say(String(beats.get("millClue", "")), 4.2)
	_emit(cc, "mill-clue")


func _mill_steps(cc: Dictionary, count: int) -> void:
	var audio: Variant = cc.get("audio")
	if audio != null and audio.has_method("steps_above"):
		audio.steps_above(count)


## Chapters asks this controller because the two platform heights are runtime
## state and deliberately do not belong in save JSON.
func mill_task(s: GameState) -> Variant:
	if not s.has("bathloft-found") or s.has("mill-clue"):
		return null
	var tasks: Dictionary = GameData.texts()["TASKS"]
	if not s.has("mill-seen"):
		return tasks["millReach"]
	if _mill_level == "ground" or _mill_level == "transition":
		return tasks["millLower"]
	if not s.has("mill-braked"):
		return tasks["millBrake"]
	if _mill_level == "lower":
		return tasks["millTop"]
	return tasks["millJournal"]


# ------------------------------------------------------------------ клуб ----

func _register_club(I: Interact, prompts: Dictionary, looks: Dictionary) -> void:
	# Координаты читаются из data/outskirts.json, а не пишутся здесь числом:
	# зал клуба в этой же фазе стал помещением, афиша уехала наружу, слева
	# от двери, а проектор — от стены внутрь. Захардкоженная точка пережила
	# бы переезд молча и осталась бы висеть в стене.
	var rows := [
		["club-poster", _v3({}, "poster", Vector3(8.10, 1.55, -26.33), "CLUB"), 2.10],
		["club-projector", _v3({}, "projector", Vector3(10.30, 0.85, -27.20), "CLUB"), 1.90],
	]
	for row: Array in rows:
		var id: String = row[0]
		var line := String(looks.get(id, ""))
		if line == "":
			continue
		I.add({
			"id": id, "pos": row[1], "r": float(row[2]), "cone": 0.55, "kind": "look",
			"priority": 2, "prompt": prompts["look"],
			"when": func(s: GameState) -> bool: return s.atLeast("village"),
			"onUse": func(cc: Dictionary) -> void:
				(cc["state"] as GameState).looked[id] = true
				cc["ui"].say(line, 4.0)
				_emit(cc, "look", id),
		})


# ---------------------------------------------------------------- куры ----

func _register_hens(I: Interact, prompts: Dictionary, looks: Dictionary) -> void:
	var line := String(looks.get("hens-trail", ""))
	if line == "":
		return
	I.add({
		"id": "hens-trail", "pos": Vector3(-4.0, 0.0, -25.9), "r": 2.20, "cone": 0.55,
		"kind": "look", "priority": 2, "prompt": prompts["look"],
		"when": func(s: GameState) -> bool: return s.atLeast("village"),
		"onUse": func(cc: Dictionary) -> void:
			(cc["state"] as GameState).looked["hens-trail"] = true
			cc["ui"].say(line, 4.0)
			_emit(cc, "look", "hens-trail"),
	})


# ------------------------------------------------------------- служебное ----

## Сценарная реплика деда, вызванная только из этой функции — префикс имени
## разрешён test_voice_manifest.gd::VITYA_OK_PREFIX. В имени нарочно нет
## подстроки `say_vitya`: иначе сторож принял бы за вызов голоса каждую
## функцию заданий, которая её зовёт.
## ФАЗА 18. Досмотр видимости после отката (Interact.resync_world). У околицы
## гаснет ровно один узел — ключ от водокачки с гвоздя в третьем стойле.
func resync(s: GameState) -> void:
	# The camera climb is deliberately runtime-only.  Retry never resumes in
	# mid-air: invalidate callbacks, restore the gameplay camera and hide the
	# beam cassette before rebuilding visibility from persisted flags.
	_cancel_bathloft(true)
	_cancel_mill_transition(true)
	_set_mill_braked(s.has("mill-braked"), c)
	# go() ещё отменит старые часы. Возобновление идёт после него через
	# resume_pending_timers(), иначе новый нагрев попадёт под ту же отмену.
	_banya_timer_generation += 1
	_banya_timer_queued = false
	_show("farm-key", not s.hasItem("farm-key"))
	for i in 4:
		_show_yard("wet-row-%d" % i, s.has("water-done") or s.has("watered-%d" % i))
	_show_banya_writing(s.has("banya-hot"))
	_show_yard("bathloft-tape", false)
	_show("mill-journal", not s.has("mill-clue"))
	_show("mill-coat", not s.has("mill-clue"))


## Вызывать после последнего HorrorDirector.invalidate() при входе в главу
## и после возвращения из поимки. Незавершённый нагрев получает полные 150 с.
func resume_pending_timers() -> void:
	var s: Variant = c.get("state")
	if not (s is GameState) or s.chapter != "village" \
			or not s.has("damper-shut") or s.has("banya-hot"):
		return
	_schedule_banya_heat(c, GameData.texts()["BEATS"])


func _schedule_banya_heat(cc: Dictionary, beats: Dictionary) -> void:
	var director: Variant = cc.get("horror")
	var stamp := int(director.generation) if director != null else -1
	if _banya_timer_queued and _banya_timer_director_generation == stamp:
		return
	_banya_timer_generation += 1
	_banya_timer_director_generation = stamp
	_banya_timer_queued = true
	var generation := _banya_timer_generation
	var complete := func() -> void:
		if director != null and int(director.generation) != stamp:
			return
		_complete_banya_heat(generation, cc, beats)
	if director != null:
		director.after(BANYA_WARM, complete)
	else:
		Interact._after(BANYA_WARM, complete)


func _complete_banya_heat(generation: int, cc: Dictionary,
		beats: Dictionary) -> void:
	if generation != _banya_timer_generation:
		return
	_banya_timer_queued = false
	var st: Variant = cc.get("state")
	if not (st is GameState) or not st.has("damper-shut") \
			or st.has("banya-hot") or st.chapter != "village":
		return
	st.set_flag("banya-hot")
	_show_banya_writing(true)
	var ui: Variant = cc.get("ui")
	if ui != null:
		ui.say(String(beats.get("banyaHot", "")), 3.6)
	_emit(cc, "banya-hot")


func _village_line(c2: Dictionary, name: String) -> void:
	var v: Variant = c2.get("voice")
	if v == null:
		return
	v.say_vitya_key(name, 11.0, 0.0)


func _show(id: String, on: bool) -> void:
	var n: Variant = nodes.get(id)
	if n is Node3D:
		(n as Node3D).visible = on


func _show_yard(id: String, on: bool) -> void:
	var yard_nodes: Dictionary = _yard().get("nodes", {})
	var n: Variant = yard_nodes.get(id)
	if n is Node3D:
		(n as Node3D).visible = on


func _show_banya_writing(on: bool) -> void:
	var yard_nodes: Dictionary = _yard().get("nodes", {})
	var pane: Variant = yard_nodes.get("banya-win-w")
	if not (pane is Node3D):
		return
	var writing := (pane as Node3D).get_node_or_null("story-writing")
	if writing is Node3D:
		(writing as Node3D).visible = on


func _yard() -> Dictionary:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return {}
	return ((w as Dictionary).get("yard", {}) as Dictionary)


## Координата из уже собранного мира (yard/outskirts) с запасным значением —
## тот же приём, что village_world._at(): нет данных, точка не переезжает
## в (0,0,0), а остаётся там, где её видел дизайнер в комментарии.
##
## ФАЗА 16. Первый параметр назывался _unused и им и был: функция ВСЕГДА
## лезла в OutskirtsWorld.data(), а секции BANYA там нет вовсе. Значит,
## yard.json BANYA.tap не влиял ни на что, и правка координаты крана в данных
## не изменила бы ни сантиметра — числа совпали случайно. Теперь переданный
## словарь читается первым; ключ секции ищется и как есть, и в нижнем
## регистре (WorldBuilder кладёт секции участка под "banya", "shed").
func _v3(from: Dictionary, key: String, def: Vector3, section: String = "") -> Vector3:
	var sect: Dictionary = from
	if section != "" and not from.is_empty():
		var got: Variant = from.get(section, from.get(section.to_lower(), null))
		sect = got if got is Dictionary else {}
	var a: Array = sect.get(key, [])
	if a.size() == 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	# Переданного словаря не хватило — та же секция в данных околицы.
	var d := OutskirtsWorld.data()
	var sect2: Dictionary = d.get(section, {}) if section != "" else d
	var a2: Array = sect2.get(key, [])
	if a2.size() == 3:
		return Vector3(float(a2[0]), float(a2[1]), float(a2[2]))
	return def


func _emit(cc: Dictionary, event: String, payload: Variant = null) -> void:
	var f: Variant = cc.get("emit")
	if f is Callable:
		(f as Callable).call(event, payload)


func _after(sec: float, fn: Callable) -> void:
	Interact._after(sec, fn)

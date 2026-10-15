# Глава ДЕРЕВНЯ: шесть шагов и всё, что для них нужно (фаза 12).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. Тот же довод, что у street_quest.gd: chapters.gd — это
# расписание (карточка, вход, задача, таблица реакций), предметы дома живут
# в interact.gd, а между ними остаётся десяток точек, которые не тянут ни на то,
# ни на другое. Капот, письмо, ключ, ящик с запчастями, телефон в сельпо,
# штатив, могила. Их и держит этот модуль.
#
# ЖАЛОБА, РАДИ КОТОРОЙ ГЛАВА И НАПИСАНА, звучала так: «после спуска в подвал
# взял ключи и уехал». Второго акта в игре не было вовсе. Теперь машина
# не заводится, потому что из трамблёра вынут бегунок, и вынул его человек.
#
#   V1  капот: бегунка нет
#   V2  Аркадий: свет горит, дверь приоткрыта, телевизор работает, никого.
#       На столе письмо в правление, на гвозде ключ от сельпо
#   V3  сельпо: ящик с запчастями -> бегунок; журнал прихода; телефон на стене
#   V4  заколоченный дом (по желанию): штатив у щели, лежанка, чужие кассеты
#   V5  погост (по желанию): могила жены деда и рядом вторая, вырытая
#   V6  вернуться и поставить бегунок
#
# ЗАМОК ГЛАВЫ ОДИН — бегунок. Четвёртый и пятый шаги добровольные, но вместе
# они дают четвёртую концовку «ПИСЬМО»: игрок, который дошёл и до письма,
# и до кассет, знает всю человеческую половину истории, а не половину половины.
#
# ПРАВИЛО ЗАМКОВ ТО ЖЕ, ЧТО В ФАЗЕ 9: каждый замок объясняет себя вслух.
# Пустой трамблёр, запертая дверь сельпо и ключ у Аркадия проговариваются
# репликами — запертая без слов дверь читается как баг, а не как задача.

class_name VillageQuest
extends RefCounted

# На сколько надо отойти от вырытой ямы, чтобы получить в спину.
const PIT_AWAY := 4.2
const PIT_DELAY := 0.9

var c: Dictionary = {}
var village: Dictionary = {}
var nodes: Dictionary = {}
var stalk: Variant = null

var _pit := Vector3.ZERO
var _pit_armed := false
var _pit_wait := 0.0


func _init(ctx: Dictionary, village_data: Dictionary) -> void:
	c = ctx
	village = village_data
	nodes = village.get("nodes", {})
	stalk = ctx.get("stalk")
	var pt: Array = (village.get("graveyard", {}) as Dictionary).get("pit", [])
	if pt.size() == 4:
		_pit = Vector3((float(pt[0]) + float(pt[1])) / 2.0, 0.0,
			(float(pt[2]) + float(pt[3])) / 2.0)
	# Всё, что появляется по ходу главы, стоит на местах с загрузки и невидимо
	# до своего шага — ровно как уличные объекты фазы 9.
	for id: String in ["kovrigin-letter", "shop-key", "shop-rotor", "arkady-tv-glow",
			"car-hood-open"]:
		_show(id, false)
	# ФАЗА 13. Половина расписания и монтировка лежат на местах с загрузки —
	# их не «выдают», их находят. Поднятое ведро и свёрток появляются только
	# после того, как ворот пошёл.
	for id: String in ["well-raised", "well-bundle"]:
		_show(id, false)


# ---------------------------------------------------------------- шаги ------

## Вход в главу. Идемпотентен: [R] проходит через него же, и всё, что уже
## сделано, обязано остаться сделанным.
func enter() -> void:
	var s: GameState = c["state"]
	# Дверь Аркадия приоткрыта, телевизор работает. Свет у него горел и раньше
	# (data/street.json, окно с lit), теперь к нему добавляется дверь.
	var leaf: Variant = nodes.get("arkady-door")
	if leaf is Node3D:
		(leaf as Node3D).rotation.y = -0.62
	_show("arkady-tv-glow", true)
	_show("kovrigin-letter", not s.has("kovrigin-letter"))
	_show("shop-key", not s.hasItem("shop-key"))
	_show("shop-rotor", s.has("shop-open") and not s.hasItem("distributor"))
	_show("car-hood-open", s.has("distributor-gone") and not s.has("distributor-in"))
	_open_shop(s.has("shop-open"))
	# Доски с двери заколоченного дома отодраны — изнутри, и не сегодня.
	# До этой минуты дом стоял закрытым: в УЛИЦЕ игрок проходил мимо него
	# дважды, и войти было нельзя.
	_unboard()
	# Свет в сельпо горит с той минуты, как его открыли, — и после [R] тоже.
	var lights: Variant = c.get("lights")
	if lights != null and s.has("shop-open"):
		lights.setLamp("shop-in", true)
	# Холодильник в красном доме горит всю главу и мимо рубильника: дачники
	# платили за свет отдельно, и блэкаут на дедовом участке до них не достаёт.
	# Это единственный работающий прибор на линии, и по нему дом и находят.
	if lights != null:
		lights.setLamp("redhouse", true)
	# Дед выходит на линию и ходит по ней до сельпо. Полоса та же, отрезок
	# втрое длиннее, скорость меньше: см. street_stalk.gd WEST_V/WALK_V.
	#
	# ФАЗА 18. Гейт был по 'distributor-in' — по флагу, который ставится в
	# САМОМ КОНЦЕ главы, и до фазы 17 это было верно: между сельпо и машиной
	# оставался один шаг. Теперь их пятнадцать, и дед ходил по всей деревне
	# всю ночь. Уходит он с линии по 'distributor' — то есть когда игрок
	# взял бегунок и вышел из сельпо (chapters._village_rotor); флаг предмета
	# тут и спрашивается, чтобы [R] посреди главы не выводил его заново.
	if stalk != null and not s.hasItem("distributor"):
		stalk.begin(true)


## V6. Бегунок на месте — глава кончилась.
##
## ФАЗА 17. Здесь стоит ВТОРОЙ и последний замок главы. До него их было ровно
## два на всю вторую половину игры: этот флаг без единой проверки и цепь на
## воротах. Всё остальное — полив, линия Вали, улики, погост, колодец, красный
## дом, СНТ — построено, озвучено, покрыто тестами и НЕОБЯЗАТЕЛЬНО. Сходил в
## сельпо, поставил бегунок, завёл машину — титры.
##
## Отказ говорит вслух (chapters._village_unfinished) и говорит текущую строку
## задачи: игрок с бегунком в руке слышит, чего именно не хватает.
func fixed() -> void:
	var s: GameState = c["state"]
	if s.has("distributor-in"):
		return
	if not Chapters.village_chores_done(s):
		_emit("village-unfinished")
		return
	s.set_flag("distributor-in")
	if stalk != null:
		stalk.finish()
	# Капот захлопнут. Дальше машина заводится, и открытая крышка в кадре
	# у ворот была бы враньём.
	_show("car-hood-open", false)
	_say("distributorIn", 3.0)
	_emit("distributor-in")


# ---------------------------------------------------------------- кадр ------

# Единственное, что здесь считается покадрово, — второй полнокадровый удар
# фазы. Он ставится НЕ по нажатию [E] и не по входу в зону, а по тому, что
# игрок ОТОШЁЛ от ямы: удар в спину на выходе читается как то, что случилось
# само, а удар по клавише — как реакция игры на игрока.
func update(dt: float) -> void:
	if not _pit_armed:
		return
	var s: GameState = c["state"]
	if s.has("pit-behind"):
		_pit_armed = false
		return
	if _feet().distance_to(_pit) < PIT_AWAY:
		return
	_pit_wait -= dt
	if _pit_wait > 0.0:
		return
	_pit_armed = false
	s.set_flag("pit-behind")
	Interact._hit_full(c)


# ------------------------------------------------------------ дескрипторы ---

## Точки деревни. Зовётся один раз, из Interact.registerObjects.
func register(I: Interact) -> void:
	var t := GameData.texts()
	var prompts: Dictionary = t["PROMPTS"]
	var looks: Dictionary = t["LOOKS"]
	var beats: Dictionary = t["BEATS"]

	_register_car(I, prompts, beats)
	_register_arkady(I, t, prompts, beats, looks)
	_register_shop(I, t, prompts, beats, looks)
	_register_boarded(I, prompts, beats, looks)
	_register_graveyard(I, prompts, beats, looks)
	_register_places(I, prompts, looks)
	_register_line13(I, prompts, beats, looks)


# --- V1/V6: капот -----------------------------------------------------------

func _register_car(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	var hood_when := func(s: GameState) -> bool:
		return s.atLeast("village") and not s.has("distributor-in")
	var hood_prompt := func(s: GameState) -> String:
		if not s.has("distributor-gone"):
			return "открыть капот"
		if s.hasItem("distributor"):
			return "поставить бегунок"
		return prompts["look"]
	var hood_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if not s.has("distributor-gone"):
			s.set_flag("distributor-gone")
			cc["audio"].creak(0.6)
			_show("car-hood-open", true)
			cc["ui"].say(String(beats.get("hoodOpen", "")), 4.2)
			_emit("hood")
			return
		if s.hasItem("distributor"):
			cc["audio"].sfx("item-take")
			fixed()
			return
		cc["ui"].say(String(beats.get("hoodNothing", "")), 3.0)
	I.add({
		"id": "car-hood",
		# Капот со стороны решётки: машина стоит носом на север,
		# x [-1.0, 3.2] z [-3.6, -1.8] (см. street.json ROUTE).
		"pos": Vector3(1.10, 1.05, -3.35), "r": 2.2, "priority": 5,
		"prompt": hood_prompt,
		"when": hood_when,
		"onUse": hood_use,
	})


# --- V2: Аркадий ------------------------------------------------------------

func _register_arkady(I: Interact, t: Dictionary, prompts: Dictionary,
		beats: Dictionary, looks: Dictionary) -> void:
	var ark: Dictionary = village.get("arkady", {})
	var letter_txt: Dictionary = t.get("KOVRIGIN_LETTER", {})

	var door_when := func(s: GameState) -> bool:
		return s.atLeast("village")
	var door_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if not s.has("arkady-empty"):
			s.set_flag("arkady-empty")
			cc["ui"].say(String(beats.get("arkadyOpen", "")), 4.6)
			_emit("arkady-empty")
			return
		cc["ui"].say(String(looks.get("arkady-tv", "")), 3.4)
	I.add({
		"id": "arkady-door",
		"pos": Vector3(15.90, 1.25, -7.02), "r": 2.6, "cone": 0.5, "priority": 4,
		"prompt": prompts["look"],
		"when": door_when,
		"onUse": door_use,
	})

	var lt := _at(ark, "letter", Vector3(15.72, 0.96, -7.55))
	var letter_when := func(s: GameState) -> bool:
		return s.atLeast("village") and (s.chapter != "village" or s.has("snt-returned")) and not s.has("kovrigin-letter")
	var letter_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		cc["ui"].setReaderTitle(String(letter_txt.get("title", "")))
		cc["ui"].openReader(letter_txt.get("title", ""), letter_txt.get("pages", []),
			func() -> void:
				if s.has("kovrigin-letter"):
					return
				s.set_flag("kovrigin-letter")
				# Письмо — улика того же веса, что журнал дежурств и кассеты.
				s.evidence = true
				_show("kovrigin-letter", false)
				cc["ui"].say(String(beats.get("letterFound", "")), 4.0)
				_village_line("village-1")
				_emit("kovrigin-letter"))
	I.add({
		"id": "kovrigin-letter",
		"pos": Vector3(lt.x, lt.y + 0.14, lt.z), "r": 2.2, "cone": 0.55, "priority": 4,
		"prompt": prompts["read"],
		"when": letter_when,
		"onUse": letter_use,
	})

	var kk := _at(ark, "key", Vector3(16.28, 1.36, -7.30))
	var key_when := func(s: GameState) -> bool:
		return s.atLeast("village") and not s.hasItem("shop-key")
	var key_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.give("shop-key")
		_show("shop-key", false)
		cc["audio"].sfx("item-take")
		cc["ui"].toast("Ключ с биркой «сельпо»")
		cc["ui"].say(String(beats.get("shopKeyFound", "")), 3.6)
		_emit("shop-key")
	I.add({
		"id": "shop-key",
		"pos": kk, "r": 2.2, "cone": 0.5, "priority": 4,
		"prompt": prompts["take"],
		"when": key_when,
		"onUse": key_use,
	})


# --- V3: сельпо -------------------------------------------------------------

func _register_shop(I: Interact, t: Dictionary, prompts: Dictionary,
		beats: Dictionary, looks: Dictionary) -> void:
	var shop: Dictionary = village.get("shop", {})
	var dr: Array = shop.get("door", [28.4, 29.4])
	var dx := (float(dr[0]) + float(dr[1])) / 2.0
	var z1 := float((shop.get("z", [-13.2, -7.2]) as Array)[1])
	var log_txt: Dictionary = t.get("SHOP_LOG", {})

	var door_when := func(s: GameState) -> bool:
		return s.atLeast("village")
	var door_prompt := func(s: GameState) -> String:
		if s.has("shop-open"):
			return prompts["look"]
		return prompts["open"] if s.hasItem("shop-key") else prompts["locked"]
	var door_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if s.has("shop-open"):
			cc["ui"].say(String(beats.get("shopOpen", "")), 3.0)
			return
		if not s.hasItem("shop-key"):
			# Замок объясняет себя вслух: без этого запертая дверь читается
			# как баг, а не как задача.
			cc["ui"].say(String(beats.get("shopNoKey", "")), 3.6)
			_emit("shop-locked")
			return
		s.set_flag("shop-open")
		_open_shop(true)
		cc["audio"].door(true)
		cc["ui"].say(String(beats.get("shopOpen", "")), 3.6)
		_show("shop-rotor", true)
		cc["lights"].setLamp("shop-in", true)
		_emit("shop-open")
	I.add({
		"id": "shop-door",
		"pos": Vector3(dx, 1.15, z1 + 0.10), "r": 2.4, "priority": 4,
		"prompt": door_prompt,
		"when": door_when,
		"onUse": door_use,
	})

	var crate_when := func(s: GameState) -> bool:
		return s.has("shop-open") and not s.hasItem("distributor")
	var crate_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.give("distributor")
		_show("shop-rotor", false)
		cc["audio"].sfx("item-take")
		cc["ui"].toast("Бегунок трамблёра")
		cc["ui"].say(String(beats.get("rotorFound", "")), 3.4)
		_emit("distributor")
	var crate: Array = shop.get("crate", [25.4, 26.5, -12.3, -11.2, 0.58])
	I.add({
		"id": "shop-crate",
		"pos": Vector3((float(crate[0]) + float(crate[1])) / 2.0,
			0.14 + float(crate[4]) + 0.30, (float(crate[2]) + float(crate[3])) / 2.0),
		"r": 2.0, "priority": 3,
		"prompt": prompts["take"],
		"when": crate_when,
		"onUse": crate_use,
	})

	var lg: Array = shop.get("ledger", [30.3, -9.25])
	var log_when := func(s: GameState) -> bool:
		return s.has("shop-open")
	var log_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		cc["ui"].setReaderTitle(String(log_txt.get("title", "")))
		cc["ui"].openReader(log_txt.get("title", ""), log_txt.get("pages", []),
			func() -> void:
				if s.has("shop-ledger"):
					return
				s.set_flag("shop-ledger")
				_emit("shop-ledger"))
	I.add({
		"id": "shop-ledger",
		"pos": Vector3(float(lg[0]), 1.20, float(lg[1])), "r": 1.8, "cone": 0.55,
		"priority": 3,
		"prompt": prompts["read"],
		"when": log_when,
		"onUse": log_use,
	})

	var ph: Array = shop.get("phone", [25.28, 1.42, -10.40])
	var phone_when := func(s: GameState) -> bool:
		return s.has("shop-open") and not s.has("shop-called")
	var phone_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.set_flag("shop-called")
		var calls: Dictionary = (cc["texts"] as Dictionary).get("CALLS", {})
		var call: Dictionary = calls.get("shop", {})
		var lines: Array = call.get("lines", [])
		if lines.is_empty():
			cc["ui"].say(String(beats.get("shopPhoneDial", "")), 3.0)
			_emit("shop-called")
			return
		cc["audio"].phone_bed(true)
		_ctx_call("playDialogue", [lines, func() -> void:
			cc["audio"].phone_bed(false)
			cc["ui"].say(String(beats.get("shopPhoneAnswer", "")), 3.6)
			_emit("shop-called")])
	I.add({
		"id": "shop-phone",
		"pos": Vector3(float(ph[0]) + 0.22, float(ph[1]), float(ph[2])),
		"r": 1.9, "cone": 0.5, "priority": 4,
		"prompt": prompts["call"],
		"when": phone_when,
		"onUse": phone_use,
	})


# --- V4: заколоченный дом ---------------------------------------------------

func _register_boarded(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary) -> void:
	var bd: Dictionary = village.get("boarded", {})
	var dr: Array = bd.get("door", [-6.0, -5.0])
	var dx := (float(dr[0]) + float(dr[1])) / 2.0
	var z1 := float((bd.get("z", [-13.0, -7.5]) as Array)[1])

	var door_when := func(s: GameState) -> bool:
		return s.atLeast("village")
	var door_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if not s.has("boarded-in"):
			s.set_flag("boarded-in")
			cc["ui"].say(String(beats.get("boardedIn", "")), 4.4)
			_emit("boarded-in")
			return
		cc["ui"].say(String(beats.get("boardedLived", "")), 4.0)
	I.add({
		"id": "boarded-door",
		"pos": Vector3(dx, 1.20, z1 + 0.12), "r": 2.4, "priority": 3,
		"prompt": prompts["look"],
		"when": door_when,
		"onUse": door_use,
	})

	# ПОЛНОКАДРОВЫЙ УДАР №1. Игрок наклоняется к щели у штатива — с той
	# стороны смотрят. Больше двух таких на фазу нельзя: инструмент теряет
	# силу, а на четвёртом применении за игру перестаёт работать вовсе.
	var tp: Array = bd.get("tripod", [-3.62, -8.05])
	var tri_when := func(s: GameState) -> bool:
		return s.atLeast("village")
	var tri_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if s.has("tripod-seen"):
			cc["ui"].say(String(looks.get("boarded-tripod", "")), 3.4)
			return
		s.set_flag("tripod-seen")
		cc["ui"].say(String(beats.get("tripodSeen", "")), 4.2)
		_emit("tripod-seen")
		Interact._after(1.6, func() -> void: Interact._hit_full(cc))
	I.add({
		"id": "boarded-tripod",
		"pos": Vector3(float(tp[0]), 1.35, float(tp[1])), "r": 1.9, "cone": 0.5,
		"priority": 4,
		"prompt": prompts["look"],
		"when": tri_when,
		"onUse": tri_use,
	})

	var tps: Array = bd.get("tapes", [-4.55, -11.60])
	# ФАЗА 17. Условие было по ПРЕДМЕТУ 'kovrigin-tapes', и это гасило точку
	# насмерть: тот же предмет выдаёт холм Вали (valya_quest, 'grave-dig'),
	# а линия Вали стала обязательной. Раскопал холм — и кассеты в
	# заколоченном доме взять уже нельзя, точка молча исчезла. Плюс замок
	# улики (chapters.village_chores_done) на предмете закрывался бы сам
	# собой, линией Вали, — то есть не закрывал бы ничего.
	#
	# Теперь у этой находки свой флаг, и он значит ровно то, что написано:
	# кассеты взяты ЗДЕСЬ.
	var tapes_when := func(s: GameState) -> bool:
		return s.atLeast("village") and not s.has("boarded-tapes")
	var tapes_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.give("kovrigin-tapes")
		s.set_flag("boarded-tapes")
		s.evidence = true
		cc["audio"].sfx("item-take")
		cc["ui"].toast("Кассеты. Девять штук")
		cc["ui"].say(String(beats.get("tapesSeen", "")), 4.4)
		_village_line("village-2")
		_emit("kovrigin-tapes")
	I.add({
		"id": "boarded-tapes",
		"pos": Vector3(float(tps[0]), 0.62, float(tps[1])), "r": 1.9, "cone": 0.5,
		"priority": 4,
		"prompt": prompts["take"],
		"when": tapes_when,
		"onUse": tapes_use,
	})


# --- V5: погост -------------------------------------------------------------

func _register_graveyard(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary) -> void:
	var gy: Dictionary = village.get("graveyard", {})
	var wife: Array = gy.get("wife", [39.7, -10.4])

	var wife_when := func(s: GameState) -> bool:
		return s.atLeast("village")
	var wife_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if s.has("grave-wife"):
			cc["ui"].say(String(looks.get("grave-wife", "")), 3.4)
			return
		s.set_flag("grave-wife")
		cc["ui"].say(String(beats.get("graveWife", "")), 4.4)
		_village_line("village-3")
		_emit("grave-wife")
	I.add({
		"id": "grave-wife",
		"pos": Vector3(float(wife[0]), 1.05, float(wife[1])), "r": 2.2, "cone": 0.5,
		"priority": 3,
		"prompt": prompts["look"],
		"when": wife_when,
		"onUse": wife_use,
	})

	var pit_when := func(s: GameState) -> bool:
		return s.atLeast("village")
	var pit_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if s.has("grave-seen"):
			cc["ui"].say(String(looks.get("grave-pit", "")), 3.4)
			return
		s.set_flag("grave-seen")
		cc["ui"].say(String(beats.get("gravePit", "")), 4.6)
		_village_line("village-4")
		# Удар не сейчас, а когда отойдёт: см. update().
		_pit_armed = true
		_pit_wait = PIT_DELAY
		_emit("grave-seen")
	I.add({
		"id": "grave-pit",
		"pos": Vector3(_pit.x, 0.95, _pit.z + 0.52), "r": 2.4, "cone": 0.5,
		"priority": 3,
		"prompt": prompts["look"],
		"when": pit_when,
		"onUse": pit_use,
	})


# --- места без шага: осмотры ------------------------------------------------

# Остановка, трактор, колодец, колонка, будка. Ни одного флага и ни одного
# события: это места, а не задания, и осмотр у них ровно один — строка LOOKS.
func _register_places(I: Interact, prompts: Dictionary, looks: Dictionary) -> void:
	var stop: Dictionary = village.get("stop", {})
	var well: Dictionary = village.get("well", {})
	var places := [
		["stop-schedule", Vector3(-42.60, 1.52, -7.30), 2.4],
		["tractor", Vector3(-36.50, 1.40, -10.30), 3.4],
		["well", Vector3(-24.00, 1.05, -9.00), 2.6],
		["well-column", Vector3(-21.90, 1.05, -7.85), 2.2],
		["booth", Vector3(22.55, 1.50, -8.42), 2.6],
		["boarded-bunk", Vector3(-7.80, 0.80, -9.80), 2.4],
		["boarded-cans", Vector3(-6.60, 0.55, -12.40), 2.2],
		["shop-scales", Vector3(27.20, 1.25, -9.25), 2.0],
		# Телевизор Аркадия виден только в приоткрытую дверь, поэтому радиус
		# считается от порога, а не от самого прибора.
		["arkady-tv", Vector3(17.40, 1.15, -7.90), 2.9],
		# Дорога на восток, за сельпо. Единственный осмотр фазы, который
		# ничего не показывает: там туман и больше ничего.
		["village-road", Vector3(35.00, 1.50, -5.60), 3.2],
	]
	var when := func(s: GameState) -> bool:
		return s.atLeast("street")
	for row: Array in places:
		var id: String = row[0]
		var line := String(looks.get(id, ""))
		if line == "":
			continue
		I.add({
			"id": id,
			"pos": row[1], "r": float(row[2]), "cone": 0.55, "kind": "look",
			"priority": -1,
			"prompt": prompts["look"],
			"when": when,
			"onUse": func(cc: Dictionary) -> void:
				(cc["state"] as GameState).looked[id] = true
				cc["ui"].say(line, 3.8)
				_emit("look", id),
		})


# --- ЛИНИЯ (фаза 13): расписание, монтировка, колодец, красный дом ----------
#
# Остановка, трактор и колодец стоят с фазы 12, но были только осмотрами:
# игрок доходил до них, читал строку и уходил. Здесь они достраиваются до
# заданий и связываются в одну короткую цепочку — расписание, монтировка,
# ворот, — а красный дом висит рядом четвёртым, необязательным.
#
# ЦЕПОЧКА КОРОТКАЯ НАРОЧНО. Головоломка, не связанная с историей, ломает
# страх вернее любой ошибки в постановке: игрок переключается с «что здесь
# происходит» на «что тут во что вставляется», и обратно уже не возвращается.
# Поэтому связка здесь ровно одна — монтировка из кабины открывает ворот, —
# и каждая её ступень цепляется за то, что игрок уже знает: девятое августа
# он слышал у Ковригина по телефону и читал в журнале сельпо.
func _register_line13(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary) -> void:
	var stop: Dictionary = village.get("stop", {})
	var tr: Dictionary = village.get("tractor", {})
	var well: Dictionary = village.get("well", {})
	var rh: Dictionary = village.get("redhouse", {})

	# --- расписание на остановке ---
	var half := _at(stop, "half", Vector3(-43.20, 0.16, -7.12))
	I.add({
		"id": "stop-half",
		"pos": half + Vector3(0, 0.22, 0), "r": 2.00, "cone": 0.55, "priority": 3,
		"prompt": prompts["take"],
		"when": func(s: GameState) -> bool:
			return s.atLeast("street") and not s.has("schedule-half"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("schedule-half")
			_show("stop-half", false)
			cc["audio"].sfx("item-take")
			cc["ui"].say(String(beats.get("scheduleHalf", "")), 3.4)
			_emit("schedule-half"),
	})

	var sign: Array = stop.get("sign", [-43.40, -42.00, 1.20, 1.85])
	I.add({
		"id": "stop-schedule-fix",
		"pos": Vector3((float(sign[0]) + float(sign[1])) / 2.0,
			(float(sign[2]) + float(sign[3])) / 2.0, -7.30),
		"r": 2.20, "cone": 0.50, "priority": 4,
		"prompt": "сложить расписание",
		"when": func(s: GameState) -> bool:
			return s.has("schedule-half") and not s.has("schedule-done"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("schedule-done")
			# Улика того же веса, что письмо и журнал: дата сходится в третий раз.
			s.evidence = true
			cc["ui"].say(String(beats.get("scheduleDone", "")), 4.6)
			_village_line("village2-1")
			_emit("schedule-done"),
	})

	# --- монтировка в кабине трактора ---
	var cb := _at(tr, "crowbar", Vector3(-36.30, 1.72, -9.80))
	I.add({
		"id": "crowbar",
		"pos": cb, "r": 2.40, "cone": 0.50, "priority": 4,
		"prompt": prompts["take"],
		"when": func(s: GameState) -> bool:
			return s.atLeast("street") and not s.hasItem("crowbar"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.give("crowbar")
			_show("crowbar", false)
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Монтировка")
			cc["ui"].say(String(beats.get("crowbarTaken", "")), 4.0)
			_village_line("village2-2")
			_emit("crowbar"),
	})
	I.add({
		"id": "tractor-cabin",
		"pos": _at(tr, "kit", Vector3(-36.72, 1.62, -10.25)), "r": 2.20, "cone": 0.50,
		"kind": "look", "priority": 1,
		"prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			return s.atLeast("street"),
		"onUse": func(cc: Dictionary) -> void:
			(cc["state"] as GameState).looked["tractor-cabin"] = true
			cc["ui"].say(String(looks.get("tractor-cabin", "")), 4.0)
			_emit("look", "tractor-cabin"),
	})

	# --- ворот колодца ---
	var handle := _at(well, "handle", Vector3(-23.30, 1.42, -9.00))
	I.add({
		"id": "well-winch",
		"pos": handle, "r": 2.20, "cone": 0.50, "priority": 4,
		"prompt": func(s: GameState) -> String:
			return prompts["stuck"] if not s.has("well-freed") else "поднять ведро",
		"when": func(s: GameState) -> bool:
			return s.atLeast("street") and not s.has("well-raised"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if not s.has("well-freed"):
				if not s.hasItem("crowbar"):
					cc["ui"].say(String(beats.get("wellStuck", "")), 3.4)
					return
				s.set_flag("well-freed")
				cc["audio"].creak(0.7)
				cc["ui"].say(String(beats.get("wellFreed", "")), 2.8)
				_emit("well-freed")
				return
			s.set_flag("well-raised")
			_show("well-raised", true)
			_show("well-bundle", true)
			cc["audio"].creak(0.5)
			cc["ui"].say(String(beats.get("wellBundle", "")), 4.0)
			_village_line("village2-3")
			_emit("well-raised"),
	})
	I.add({
		"id": "well-bundle",
		"pos": _at(well, "bundle", Vector3(-24.00, 1.18, -9.00)) + Vector3(0, 0.16, 0),
		"r": 1.90, "cone": 0.50, "priority": 5,
		"prompt": prompts["open"],
		"when": func(s: GameState) -> bool:
			return s.has("well-raised") and not s.hasItem("well-bundle"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.give("well-bundle")
			s.evidence = true
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Кассета из колодца")
			cc["ui"].say(String(beats.get("wellOpened", "")), 4.4)
			_village_line("village2-5")
			_emit("well-bundle"),
	})

	# --- красный дом ---
	var rdr: Array = rh.get("door", [0.4, 1.4])
	var rz1 := float((rh.get("z", [-13.0, -7.5]) as Array)[1])
	I.add({
		"id": "redhouse-door",
		"pos": Vector3((float(rdr[0]) + float(rdr[1])) / 2.0, 1.20, rz1 + 0.12),
		"r": 2.40, "priority": 3,
		"prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			return s.atLeast("village"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if not s.has("redhouse-in"):
				s.set_flag("redhouse-in")
				cc["ui"].say(String(beats.get("redhouseIn", "")), 4.0)
				_village_line("village2-4")
				_emit("redhouse-in")
				return
			cc["ui"].say(String(beats.get("redhouseGone", "")), 4.0),
	})

	var rh_looks := [
		["redhouse-fridge", _rect_mid(rh, "fridge", Vector3(0.90, 1.30, -9.25)), 2.20],
		["redhouse-plastic", _rect_mid(rh, "sofa", Vector3(-0.32, 0.95, -12.10)), 2.40],
		["redhouse-drawing", _at(rh, "drawing", Vector3(-1.33, 1.55, -10.70))
			+ Vector3(0.30, 0.0, 0.0), 1.90],
	]
	for row: Array in rh_looks:
		var id: String = row[0]
		var line := String(looks.get(id, ""))
		if line == "":
			continue
		I.add({
			"id": id,
			"pos": row[1], "r": float(row[2]), "cone": 0.55, "kind": "look",
			"priority": 2,
			"prompt": prompts["look"],
			"when": func(s: GameState) -> bool:
				return s.atLeast("village"),
			"onUse": func(cc: Dictionary) -> void:
				var s: GameState = cc["state"]
				s.looked[id] = true
				# Рисунок — улика: человек у забора нарисован выше дома,
				# и рисовал его ребёнок, который тут жил этим летом.
				if id == "redhouse-drawing":
					s.evidence = true
				cc["ui"].say(line, 4.4)
				_emit("look", id),
		})

	_register_redhouse_up(I, prompts, beats, looks, rh)


## Второй этаж красного дома (фаза 14). Одна улика и один гэг, и ровно на
## улике стоит СКРИМЕР №2 — второй и последний полнокадровый на всю фазу
## (scare.gd держит три перепада яркости за 1.15 с, четвёртый запрещён
## порогом WCAG 2.3.1, поэтому третьего Scare.play здесь быть не может).
##
## Игрушка на подоконнике повёрнута к Витиным воротам. Тетрадь лежит на
## детском столе у того же окна: тот, кто её писал, сидел здесь и смотрел
## через дорогу — туда, где игрок ночует.
func _register_redhouse_up(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary, rh: Dictionary) -> void:
	var fl2 := float(rh.get("floor2", 0.0))
	if fl2 <= 0.0:
		return
	var desk: Array = rh.get("desk", [])
	var toy: Array = rh.get("toy", [])

	if desk.size() == 2:
		var dpos := Vector3(float(desk[0]), fl2 + 0.78, float(desk[1]))
		I.add({
			"id": "redhouse-desk-item",
			"pos": dpos, "r": 1.60, "cone": 0.55, "priority": 5,
			"prompt": prompts["take"],
			"when": func(s: GameState) -> bool:
				return s.atLeast("village") and not s.has("redhouse-notebook"),
			"onUse": func(cc: Dictionary) -> void:
				var s: GameState = cc["state"]
				# ФАЗА 18. Ящик стола заперт, и отпирает его ключ Вали.
				# До сих пор 'redhouse-key' ВЫДАВАЛСЯ (valya_quest, третий
				# разговор) и не читался никем: единственный предмет игры,
				# который ничего не открывал. Ход не удлиняется ни на шаг —
				# ключ приходит ровно тем разговором, после которого задача
				# и отправляет на второй этаж. Отказ говорит вслух: молча
				# запертая точка читается багом, а не задачей.
				if not s.hasItem("redhouse-key"):
					cc["ui"].say(String(beats.get("redhouseDeskLocked", "")), 3.8)
					return
				s.set_flag("redhouse-notebook")
				s.evidence = true
				_hide_node("redhouse-desk-item")
				cc["audio"].sfx("paper-open")
				cc["ui"].toast("Тетрадь в клеточку")
				cc["ui"].say(String(beats.get("redhouseNotebook", "")), 4.6)
				_village_line("phase14-4")
				# Тот, кто стоял у окна, оказывается за спиной. Секунда на то,
				# чтобы игрок опустил глаза в тетрадь и перестал следить за
				# комнатой, — и фигура на площадке лестницы.
				#
				# ФАЗА 17. Был полнокадровый удар. Стал мягкий: тетрадь
				# втянулась в ОБЯЗАТЕЛЬНЫЙ маршрут главы (valya-gone требует
				# 'redhouse-notebook'), и полных кадров на нём стало бы четыре
				# при потолке два. Фигуру ставит глава — chapters._village_notebook;
				# здесь остаётся только событие.
				_emit("redhouse-notebook"),
		})

	var bed: Array = rh.get("bed", [])
	if bed.size() == 2:
		var bline := String(looks.get("redhouse-bed", ""))
		if bline != "":
			I.add({
				"id": "redhouse-bed",
				"pos": Vector3(float(bed[0]), fl2 + 0.60, float(bed[1])),
				"r": 1.80, "cone": 0.55, "kind": "look", "priority": 2,
				"prompt": prompts["look"],
				"when": func(s: GameState) -> bool:
					return s.atLeast("village"),
				"onUse": func(cc: Dictionary) -> void:
					(cc["state"] as GameState).looked["redhouse-bed"] = true
					cc["ui"].say(bline, 4.0)
					_emit("look", "redhouse-bed"),
			})

	if toy.size() == 3:
		var tline := String(looks.get("redhouse-toy", ""))
		if tline != "":
			I.add({
				"id": "redhouse-toy",
				"pos": Vector3(float(toy[0]), float(toy[1]) + 0.10, float(toy[2])),
				"r": 1.40, "cone": 0.55, "kind": "look", "priority": 2,
				"prompt": prompts["look"],
				"when": func(s: GameState) -> bool:
					return s.atLeast("village"),
				"onUse": func(cc: Dictionary) -> void:
					(cc["state"] as GameState).looked["redhouse-toy"] = true
					cc["ui"].say(tline, 4.2)
					_emit("look", "redhouse-toy"),
			})


## ФАЗА 18. Досмотр видимости после отката (Interact.resync_world).
##
## enter() чинит большую часть сам — он идемпотентен с фазы 13 и проходит
## через [R] же. Здесь остаётся то, что он не трогал: подобранное с земли
## и поднятое воротом. Всё от состояния, а не от события.
func resync(s: GameState) -> void:
	_show("stop-half", not s.has("schedule-half"))
	_show("crowbar", not s.hasItem("crowbar"))
	# Ворот. Ведро и свёрток появляются вместе и только после того,
	# как ворот пошёл; свёрток из кадра не гаснет и после того, как его взяли, —
	# в колодце остаётся тряпка, в которую он был замотан.
	var raised := s.has("well-raised")
	_show("well-raised", raised)
	_show("well-bundle", raised)
	# Тетрадь с детского стола лежит в словаре узлов деревни, а не в nodes:
	# красный дом собирается отдельным проходом (village_world._redhouse).
	_show_node("redhouse-desk-item", not s.has("redhouse-notebook"))


## Спрятать узел деревни: улику с детского стола после того, как её взяли.
func _hide_node(id: String) -> void:
	_show_node(id, false)


func _show_node(id: String, on: bool) -> void:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return
	var village: Dictionary = (w as Dictionary).get("village", {})
	var n: Variant = (village.get("nodes", {}) as Dictionary).get(id)
	if n is Node3D:
		(n as Node3D).visible = on


static func _rect_mid(d: Dictionary, key: String, def: Vector3) -> Vector3:
	var a: Array = d.get(key, [])
	if a.size() != 4:
		return def
	return Vector3((float(a[0]) + float(a[1])) / 2.0, def.y,
		(float(a[2]) + float(a[3])) / 2.0)


# ------------------------------------------------------------- служебное ----

## Снять доски с двери заколоченного дома: полотно прячется, коробка в четвёртом
## наборе гасится. Идемпотентно — [R] проходит через enter() же.
func _unboard() -> void:
	var col: Variant = c.get("col")
	if col != null:
		col.set_blocker_active("door-boarded", false)
	var ph: Variant = c.get("physics")
	if ph != null:
		ph.sync()
	_show("door-boarded", false)


## Створка сельпо. Своего блокера в built.blockers у неё нет: коробка живёт
## в четвёртом наборе коллизий, и гасить её нужно там же.
func _open_shop(open: bool) -> void:
	var col: Variant = c.get("col")
	if col != null:
		col.set_blocker_active("door-shop", not open)
	var ph: Variant = c.get("physics")
	if ph != null:
		ph.sync()
	var leaf: Variant = nodes.get("door-shop")
	if leaf is Node3D:
		(leaf as Node3D).rotation.y = -1.45 if open else 0.0


## Сценарная реплика деда из темноты. Есть озвучка — голосом, нет — тихо
## ничего: строки этих реплик живут в data/voice_lines.json, а не в texts.json,
## и субтитра без голоса у них нет намеренно (правило фазы 5).
func _village_line(name: String) -> void:
	var v: Variant = c.get("voice")
	if v == null:
		return
	v.say_vitya_key(name, 11.0, 0.0)


func _show(id: String, on: bool) -> void:
	var n: Variant = nodes.get(id)
	if n is Node3D:
		(n as Node3D).visible = on


func _say(beat: String, seconds: float) -> void:
	var beats: Dictionary = (c.get("texts", {}) as Dictionary).get("BEATS", {})
	var text := String(beats.get(beat, ""))
	var ui: Variant = c.get("ui")
	if text != "" and ui != null:
		ui.say(text, seconds)


func _at(d: Dictionary, key: String, def: Vector3) -> Vector3:
	var a: Array = d.get(key, [])
	if a.size() != 3:
		return def
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _feet() -> Vector3:
	var ctrl: Variant = c.get("controls")
	return Vector3.ZERO if ctrl == null else ctrl.feet()


func _emit(event: String, payload: Variant = null) -> void:
	var f: Variant = c.get("emit")
	if f is Callable:
		(f as Callable).call(event, payload)


func _ctx_call(name: String, args: Array = []) -> Variant:
	var f: Variant = c.get(name)
	if f is Callable:
		return (f as Callable).callv(args)
	return null

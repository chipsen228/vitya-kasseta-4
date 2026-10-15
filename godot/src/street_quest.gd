# Глава УЛИЦА: десять шагов и всё, что для них нужно (фаза 9).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. chapters.gd — это расписание: карточка, вход, задача,
# таблица реакций. Предметы живут в interact.gd, фигуры — в neighbours.gd.
# Между ними остаётся десяток точек, которые не тянут ни на то, ни на другое:
# корзина, канистра, замок правления, бочка. Их и держит этот модуль, и он же
# показывает и прячет уличные объекты, построенные street_world.gd.
#
# ПОРЯДОК ШАГОВ ДЕРЖИТ ОДНО ПРАВИЛО. Гэг ставится ровно туда, где по законам
# жанра ждут удар, и сразу за гэгом идёт настоящий испуг: корзина гнилых яблок
# с запиской «САМЫЕ ВКУСНЫЕ ЯБЛОКИ ДЛЯ ВАС» — гэг, четыре секунды после броска —
# скример. Разряди напряжение и не добери его обратно — и вся глава станет
# комедией.
#
#   S1  стук в дверь, корзина на крыльце
#   S2  корзину выбросить -> скример №1
#   S3  машина не заводится: бак сухой
#   S4  крикун у своего забора (neighbours.gd, по дистанции)
#   S5  Аркадий на дороге: солярка в правлении, ключ в сарае
#   S6  ключ от правления — в своём сарае, на гвозде
#   S7  дом напротив: горит окно, за стеклом стоят (neighbours.gd)
#   S8  правление: канистра пустая, журнал дежурств — улика
#   S9  Аркадий у калитки: бочка у столба. По дороге — дед посреди улицы
#   S10 набрать топлива, залить бак. Ключи от машины дед унёс вниз
#
# УДЕРЖАНИЕ [E]. Единственное действие игры, которое не делается одним нажатием.
# Дескриптор бочки на onUse не наливает ничего — он только начинает; наливает
# update(), пока клавиша держится и цель под прицелом. Отпустил — счётчик
# обнуляется, и это видно в самой подсказке.

class_name StreetQuest
extends RefCounted

const POUR_TIME := 3.0        # сколько держать [E] у бочки
const SCARE_AFTER := 4.0      # пауза между броском корзины и скримером
const OLD_MAN_DIST := 6.0     # на каком подходе к бочке он выходит на линию

var c: Dictionary = {}
var street: Dictionary = {}
var nb: Neighbours = null
var stalk: StreetStalk = null
var nodes: Dictionary = {}

var _pour := 0.0
var _pouring := false
var _arkady_point: Dictionary = {}
var _barrel := Vector3.ZERO


func _init(ctx: Dictionary, street_data: Dictionary, neighbours: Neighbours,
		stalker: StreetStalk = null) -> void:
	c = ctx
	street = street_data
	nb = neighbours
	stalk = stalker
	nodes = street.get("nodes", {})
	var at: Array = (street.get("objects", {}) as Dictionary).get("barrel", [])
	if at.size() == 3:
		_barrel = Vector3(float(at[0]), float(at[1]), float(at[2]))
	# Уличные объекты стоят на местах с загрузки и невидимы до своего шага —
	# ровно как динамический реквизит глав в props.gd.
	for id: String in ["basket", "apple-note", "canister", "duty-log", "office-key"]:
		_show(id, false)
	var props: Variant = c.get("props")
	if props != null:
		var keys: Variant = props.get_prop("car-keys")
		if keys is Node3D:
			(keys as Node3D).visible = not (c["state"] as GameState).hasItem("car-key")


# ---------------------------------------------------------------- шаги ------

## S1. Стучат: три удара, пауза, ещё два. За дверью никого.
func knock() -> void:
	# Возврат по [R] проходит через вход в главу, а тот заводит таймер стука
	# заново. Стучать второй раз некому: корзина уже выброшена, и она бы просто
	# появилась на крыльце опять.
	var st: GameState = c["state"]
	if st.has("apples-there"):
		return
	var audio: Variant = c.get("audio")
	if audio != null and not bool(audio.sfx("door-knock")):
		audio.knock(3, 0.22)
		audio.after(1.1, func() -> void: audio.knock(2, 0.22))
	var beats := _beats()
	_say(String(beats.get("knockThree", "")), 3.2)
	_show("basket", true)
	_show("apple-note", true)
	_flag("apples-there")


## S2. Корзину выбросили. Через четыре секунды — скример.
func toss() -> void:
	_show("basket", false)
	_show("apple-note", false)
	var s: GameState = c["state"]
	s.set_flag("apples-tossed")
	_say(String(_beats().get("applesTossed", "")), 2.8)


## Скример №1. Выключенные резкие эффекты его не отменяют: удар остаётся,
## лицо не показывается — ровно та же развилка, что у chapters._hit().
func scream() -> void:
	var director: Variant = c.get("horror")
	if director != null:
		director.context("street-car-return", "horror-door")

## S9. Дед выходит на линию. Дальше он не декорация: ходит по середине гравийки
## и смотрит вдоль неё, а вся дорога к бочке и обратно проходится по краю.
## Правило игрок услышал десятью минутами раньше, от Аркадия: «по середине
## тебя видно».
func old_man() -> void:
	var s: GameState = c["state"]
	if s.has("street-old-man"):
		return
	s.set_flag("street-old-man")
	# Точка возврата ставится ЗДЕСЬ, а не в начале главы. Отсюда начинается
	# единственный отрезок УЛИЦЫ, на котором можно проиграть, а откат по [R]
	# на двадцать минут назад — не сложность, а наказание за интерес.
	# Флаг выставлен ДО снимка: после отката дед обязан выйти снова.
	s.checkpoint = s.snapshot()
	_say(String(_beats().get("oldManOnRoad", "")), 3.2)
	Interact._after(3.4, func() -> void:
		_say(String(_beats().get("oldManHint", "")), 3.6))
	var audio: Variant = c.get("audio")
	if audio != null:
		audio.heartbeat(4, 96)
	if stalk != null:
		stalk.begin()
	_emit("street-figure")


# ---------------------------------------------------------------- кадр ------

func update(dt: float) -> void:
	# Точка «заговорить» едет за Аркадием: дескриптор держит ссылку на СЛОВАРЬ,
	# и меняем мы поле pos прямо в нём, а не пересоздаём дескриптор.
	if nb != null and not _arkady_point.is_empty():
		var p := nb.arkady_pos()
		_arkady_point["pos"] = Vector3(p.x, 1.35, p.z)

	_pour_tick(dt)
	_old_man_tick()


## Пауза, чтение, поимка и откат отменяют незавершённое удержание.
func cancel_runtime() -> void:
	_pouring = false
	_pour = 0.0


# Наливаем, пока клавиша держится И прицел на бочке. Любое из двух отпустил —
# счётчик обнуляется: подсказка показывает проценты, и обнуление видно.
func _pour_tick(dt: float) -> void:
	if not _pouring:
		return
	var s: GameState = c["state"]
	if s.has("fuel") or not s.has("arkady-2") or not s.hasItem("canister"):
		cancel_runtime()
		return
	var it: Variant = c.get("interact")
	var on_target := it != null and it.target is Dictionary \
		and String((it.target as Dictionary).get("id", "")) == "fuel-barrel"
	if not on_target or not Input.is_action_pressed("interact"):
		cancel_runtime()
		return
	_pour += maxf(0.0, dt)
	if _pour < POUR_TIME:
		return
	cancel_runtime()
	s.set_flag("fuel")
	var audio: Variant = c.get("audio")
	if audio != null and not bool(audio.sfx("canister-pour")):
		audio.noise({"dur": 0.9, "gain": 0.10, "freq": 900.0, "q": 1.4})
	_say(String(_beats().get("fuelPoured", "")), 3.0)
	_emit("fuel")


func _old_man_tick() -> void:
	var s: GameState = c["state"]
	if s.has("street-old-man") or not s.has("arkady-2") or _barrel == Vector3.ZERO:
		return
	if _feet().distance_to(_barrel) > OLD_MAN_DIST + 8.0:
		return
	old_man()


# ------------------------------------------------------------ дескрипторы ---

## Точки улицы. Зовётся один раз, из Interact.registerObjects.
func register(I: Interact) -> void:
	var t := GameData.texts()
	var prompts: Dictionary = t["PROMPTS"]
	var looks: Dictionary = t["LOOKS"]
	var beats: Dictionary = t["BEATS"]
	var note: Dictionary = t.get("APPLE_NOTE", {})
	var objs: Dictionary = street.get("objects", {})

	# --- S1/S2: корзина и записка ---
	var basket_at := _at(objs, "basket", Vector3(-3.05, 0.45, 5.80))
	var basket_when := func(s: GameState) -> bool:
		return s.has("apples-there") and not s.hasItem("apple-basket") \
			and not s.has("apples-tossed")
	var basket_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.give("apple-basket")
		_show("basket", false)
		# Записка остаётся на крыльце до броска: корзину игрок обычно хватает
		# первой, и вместе с ней исчезала единственная строчка, ради которой
		# весь гэг и ставился.
		cc["audio"].sfx("item-take")
		cc["ui"].toast("Корзина гнилых яблок")
		cc["ui"].say(String(beats.get("applesFound", "")), 3.4)
		_emit("apples-taken")
	I.add({
		"id": "apple-basket",
		"pos": Vector3(basket_at.x, basket_at.y + 0.35, basket_at.z),
		"r": 1.8, "priority": 3,
		"prompt": prompts["take"],
		"when": basket_when,
		"onUse": basket_use,
	})

	var note_at := _at(objs, "note", Vector3(-2.72, 0.45, 5.62))
	var note_when := func(s: GameState) -> bool:
		return s.has("apples-there") and not s.has("apples-tossed")
	var note_use := func(cc: Dictionary) -> void:
		cc["ui"].setReaderTitle(String(note.get("title", "")))
		cc["ui"].openReader(note.get("title", ""), [String(note.get("body", ""))],
			func() -> void:
				var s: GameState = cc["state"]
				if not s.has("apples-note"):
					s.set_flag("apples-note")
					cc["ui"].say(String(beats.get("applesNote", "")), 3.4))
	I.add({
		"id": "apple-note",
		"pos": Vector3(note_at.x, note_at.y + 0.18, note_at.z),
		"r": 1.5, "cone": 0.55, "priority": 3,
		"prompt": prompts["read"],
		"when": note_when,
		"onUse": note_use,
	})

	# ФАЗА 12: между «взял» и «выбросил» встали два шага — натереть с сахаром
	# и попробовать (interact.gd::_register_home). Ведро поэтому ждёт
	# 'apples-tasted', а не одну корзину на руках: без этого игрок выбрасывал
	# бы яблоки, не заходя на кухню, и вся цепочка Петра осталась бы мимо.
	var bin_at := _at(objs, "bin", Vector3(4.30, 0.0, 0.95))
	var bin_when := func(s: GameState) -> bool:
		return s.hasItem("apple-basket") and not s.has("apples-tossed")
	var bin_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		# Замок объясняет себя вслух — правило фазы 9, и здесь оно тем более
		# в силе: молча не сработавшее ведро читается как поломка.
		if not s.has("apples-tasted"):
			cc["ui"].say(String(beats.get("applesNoGrater", "")), 3.4)
			return
		var audio: Variant = cc["audio"]
		if audio != null and not bool(audio.sfx("basket-drop")):
			audio.knock(1, 0.0)
			audio.creak(0.5)
		toss()
		_emit("apples-tossed")
	I.add({
		"id": "apple-bin",
		"pos": Vector3(bin_at.x, bin_at.y + 0.75, bin_at.z),
		"r": 2.0, "priority": 3,
		"prompt": "выбросить корзину",
		"when": bin_when,
		"onUse": bin_use,
	})

	# --- S5/S9: разговоры с Аркадием ---
	var talk_when := func(s: GameState) -> bool:
		if nb == null or not nb.arkady_here():
			return false
		if not s.has("arkady-1"):
			return true
		return s.has("canister-taken") and not s.has("arkady-2")
	var talk_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		var dlg: Dictionary = (cc["texts"] as Dictionary).get("STREET_DIALOGUES", {})
		var first := not s.has("arkady-1")
		var lines: Array = dlg.get("first" if first else "second", [])
		if lines.is_empty():
			return
		nb.arkady_state = "talk"
		_ctx_call("playDialogue", [lines, func() -> void:
			nb.arkady_state = "home" if not first else "route"
			if first:
				s.set_flag("arkady-1")
				_emit("arkady-1")
			else:
				s.set_flag("arkady-2")
				_emit("arkady-2")])
	_arkady_point = {
		"id": "arkady-talk",
		"pos": Vector3(15.6, 1.35, -6.2),
		"r": 2.6, "cone": 0.5, "priority": 4,
		"prompt": prompts["talk"],
		"when": talk_when,
		"onUse": talk_use,
	}
	I.add(_arkady_point)
	# И держать надо ТОТ словарь, который лёг в список. add() не кладёт наш:
	# он заводит свой, с умолчаниями r/cone/priority, и мержит наш в него.
	# Пока мы двигали копию, точка «заговорить» стояла там, где её создали, —
	# у калитки. Первый разговор поэтому и открывался единственный раз за главу:
	# когда Аркадий на своём кругу проходил мимо собственной калитки.
	_arkady_point = I.list[I.list.size() - 1]

	# --- S6: ключ от правления, в своём сарае на гвозде ---
	var key_at := _at(objs, "officeKey", Vector3(7.70, 1.52, 12.30))
	var key_when := func(s: GameState) -> bool:
		return s.has("arkady-1") and not s.hasItem("office-key")
	var key_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.give("office-key")
		_show("office-key", false)
		cc["audio"].sfx("item-take")
		cc["ui"].toast("Ключ с биркой «правл.»")
		cc["ui"].say(String(beats.get("officeKeyFound", "")), 3.6)
		_emit("office-key")
	I.add({
		"id": "office-key",
		"pos": key_at, "r": 1.6, "cone": 0.45, "priority": 3,
		"prompt": prompts["take"],
		"when": key_when,
		"onUse": key_use,
	})

	# --- S8: правление ---
	var office: Dictionary = street.get("office", {})
	var door: Dictionary = office.get("door", {})
	var door_at := Vector3(float(door.get("x", -30.0)), 1.15, float(door.get("z", -7.5)))
	var door_prompt := func(s: GameState) -> String:
		if s.has("office-open"):
			return prompts["look"]
		return prompts["open"] if s.hasItem("office-key") else prompts["locked"]
	var door_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if s.has("office-open"):
			cc["ui"].say(String(looks.get("office", "")), 3.6)
			return
		if not s.hasItem("office-key"):
			cc["ui"].say(String(beats.get("officeLocked", "")), 3.6)
			_emit("office-locked")
			return
		s.set_flag("office-open")
		_open_office(true)
		cc["audio"].door(true)
		cc["ui"].say(String(beats.get("officeOpen", "")), 3.4)
		_show("canister", true)
		_show("duty-log", true)
		cc["lights"].setLamp("office", true)
		_emit("office-open")
	# Точка живёт с первой главы: дескрипторы регистрируются один раз на игру.
	# До УЛИЦЫ она выдавала реплику про амбарный замок игроку, который в этой
	# части посёлка ещё ни разу не был и про правление не слышал.
	var door_when := func(s: GameState) -> bool:
		return s.atLeast("street")
	I.add({
		"id": "office-door",
		"pos": door_at, "r": 2.2, "priority": 3,
		"prompt": door_prompt,
		"when": door_when,
		"onUse": door_use,
	})

	var can_at := _at(office, "canister", Vector3(-31.4, 0.16, -11.6))
	var can_when := func(s: GameState) -> bool:
		return s.has("office-open") and not s.has("canister-taken")
	var can_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.set_flag("canister-taken")
		s.give("canister")
		_show("canister", false)
		cc["audio"].sfx("item-take")
		cc["ui"].toast("Канистра. Пустая")
		cc["ui"].say(String(beats.get("canisterEmpty", "")), 3.6)
		_emit("canister")
	I.add({
		"id": "canister-empty",
		"pos": Vector3(can_at.x, can_at.y + 0.35, can_at.z),
		"r": 1.7, "priority": 3,
		"prompt": prompts["take"],
		"when": can_when,
		"onUse": can_use,
	})

	var log_at := _at(office, "log", Vector3(-28.2, 0.16, -11.9))
	var log_when := func(s: GameState) -> bool:
		return s.has("office-open")
	var log_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if not s.has("duty-log"):
			s.set_flag("duty-log")
			# Улика: журнал поднимает концовку до «УТРА» так же, как кассеты.
			s.evidence = true
			cc["ui"].say(String(beats.get("dutyLog", "")), 5.0)
			_emit("duty-log")
		else:
			cc["ui"].say(String(looks.get("duty-log", "")), 3.4)
	I.add({
		"id": "duty-log",
		"pos": Vector3(log_at.x, log_at.y + 0.25, log_at.z),
		"r": 1.7, "cone": 0.55, "priority": 3,
		"prompt": prompts["read"],
		"when": log_when,
		"onUse": log_use,
	})

	# --- S10: бочка ---
	#
	# ЗАМОК, КОТОРОГО ЗДЕСЬ НЕ БЫЛО. Бочка была открыта всегда (`return true`
	# без единого условия), а канистру берут в правлении — то есть игрок заливал
	# бак по дороге ОБРАТНО, ещё не поговорив с Аркадием второй раз. Вместе
	# со вторым разговором пропускалась вся сцена S9: дед на дорогу не выходил
	# (он ждёт флага 'arkady-2'), чекпойнт середины главы не ставился, строка
	# задачи зависала. Это был единственный разрыв в цепочке замков главы,
	# и цепочка теперь сплошная:
	#   arkady-1 → office-key → office-open → canister-taken → arkady-2
	#            → fuel → tank-full
	#
	# Сама точка при этом остаётся живой: запертая без слов бочка читается как
	# баг, а не как задача. Отказ говорит вслух, чем именно он вызван.
	var barrel_when := func(s: GameState) -> bool:
		return s.has("arkady-2")
	var barrel_prompt := func(s: GameState) -> String:
		if s.has("fuel"):
			return "канистра наполнена"
		if not barrel_when.call(s):
			return "спросить Аркадия о топливе"
		if not s.hasItem("canister"):
			return "нужна пустая канистра"
		if _pouring:
			return "держать · канистра %d %%" % int(clampf(_pour / POUR_TIME, 0.0, 1.0) * 100.0)
		return "держать 3 с · наполнить канистру"
	var barrel_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		if s.has("fuel"):
			cc["ui"].say(String(looks.get("fuel-barrel", "")), 3.0)
			return
		if not barrel_when.call(s):
			cc["ui"].say(String(beats.get("barrelNotMine", "")), 3.4)
			return
		if not s.hasItem("canister"):
			cc["ui"].say("Полная. А перелить не во что.", 3.2)
			return
		# Слот рук не запирает сюжетное действие. Канистра выбирается здесь,
		# даже если к бочке игрок подошёл с фонариком.
		var held: Variant = cc.get("heldItems")
		if held != null:
			held.sync(s)
			held.equip("canister")
		if _pouring:
			return
		_pouring = true
		_pour = 0.0
	I.add({
		"id": "fuel-barrel",
		"pos": Vector3(_barrel.x, _barrel.y + 0.9, _barrel.z),
		# Перед бочкой стоит столб. До горловины надо доставать с обочины
		# сбоку от него, сохраняя место для капсулы игрока.
		"r": 2.2, "priority": 3,
		"prompt": barrel_prompt,
		"onUse": barrel_use,
	})

	# --- S10: залить бак. Отдельная точка у машины, приоритетом выше «сесть» ---
	var fill_when := func(s: GameState) -> bool:
		return s.has("fuel") and not s.has("tank-full")
	var fill_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.set_flag("tank-full")
		var audio: Variant = cc["audio"]
		if audio != null and not bool(audio.sfx("canister-pour")):
			audio.noise({"dur": 1.1, "gain": 0.09, "freq": 700.0, "q": 1.2})
		cc["ui"].say(String(beats.get("tankFilled", "")), 3.2)
		_emit("tank-full")
	I.add({
		"id": "car-fill",
		"pos": Vector3(1.55, 0.95, -1.10), "r": 2.2, "priority": 5,
		"prompt": "залить бак",
		"when": fill_when,
		"onUse": fill_use,
	})

	# --- УЛИЦА: постучать к соседям (фаза 12) ---
	#
	# Улица перестаёт быть коридором ровно тогда, когда в неё можно постучать.
	# Три двери, никто не открывает, и на третьей за окном шевелится занавеска —
	# то есть дома всё-таки есть кто-то. Никаких флагов дальше по цепочке это
	# не двигает: ступень добровольная и заканчивается ничем, как и должна.
	var doors := [
		["knock-shouter", Vector3(-16.00, 1.25, -6.90)],
		["knock-boarded", Vector3(-5.50, 1.25, -7.40)],
		["knock-watcher", Vector3(8.10, 1.25, -7.40)],
	]
	for row: Array in doors:
		var kid: String = row[0]
		var knock_when := func(s: GameState) -> bool:
			return s.atLeast("street") and not s.has(kid)
		var knock_use := func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag(kid)
			var audio: Variant = cc["audio"]
			if audio != null and not bool(audio.sfx("door-knock")):
				audio.knock(3, 0.24)
			var n := 0
			for k: Array in doors:
				if s.has(String(k[0])):
					n += 1
			if n < 3:
				_say(String(beats.get("knockNobody", "")), 2.8)
				return
			s.set_flag("knocked-around")
			_say(String(beats.get("knockNobody", "")), 2.6)
			# Занавеска шевелится ПОСЛЕ реплики и у окна наблюдателя: он
			# единственный, кто дома, и единственный, кто не открыл.
			Interact._after(3.0, func() -> void:
				_say(String(beats.get("curtainMoved", "")), 3.6)
				if nb != null and nb.has_method("watcher_pulse"):
					nb.watcher_pulse())
			_emit("knocked-around")
		I.add({
			"id": kid,
			"pos": row[1], "r": 2.2, "cone": 0.5, "priority": 2,
			"prompt": "постучать",
			"when": knock_when,
			"onUse": knock_use,
		})

	# --- ключи от машины: рядом с тайником, глава ТЕМНОТА ---
	var keys_when := func(s: GameState) -> bool:
		return s.atLeast("dark") and not s.hasItem("car-key")
	var keys_use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		s.give("car-key")
		var props: Variant = cc.get("props")
		if props != null:
			var model: Variant = props.get_prop("car-keys")
			if model is Node3D:
				(model as Node3D).visible = false
		cc["audio"].sfx("item-take")
		cc["ui"].toast("Ключи от машины")
		cc["ui"].say("Ключи. На отдельной доске у дальней стены. Красная бирка — чтобы не потерять.", 4.2)
		_emit("car-key")
	I.add({
		"id": "car-keys",
		# Дальняя стена подпола; радиус достаёт до видимой доски, не до тайника.
		"pos": Vector3(3.0, -0.65, 14.70), "r": 1.8, "priority": 3,
		"prompt": prompts["take"],
		"when": keys_when,
		"onUse": keys_use,
	})


# ------------------------------------------------------------- служебное ----

## Створка правления. Своего блокера в built.blockers у неё нет: коробка живёт
## в четвёртом наборе коллизий, и гасить её нужно там же.
func _open_office(open: bool) -> void:
	var col: Variant = c.get("col")
	if col != null:
		col.set_blocker_active("door-office", not open)
	var ph: Variant = c.get("physics")
	if ph != null:
		ph.sync()
	var leaf: Variant = nodes.get("door-office")
	if leaf is Node3D:
		(leaf as Node3D).rotation.y = -1.5 if open else 0.0


func _show(id: String, on: bool) -> void:
	var n: Variant = nodes.get(id)
	if n is Node3D:
		(n as Node3D).visible = on


func _at(d: Dictionary, key: String, def: Vector3) -> Vector3:
	var a: Array = d.get(key, [])
	if a.size() != 3:
		return def
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


func _beats() -> Dictionary:
	return (c.get("texts", {}) as Dictionary).get("BEATS", {})


func _say(text: String, seconds: float) -> void:
	if text == "":
		return
	var ui: Variant = c.get("ui")
	if ui != null:
		ui.say(text, seconds)


func _flag(name: String) -> void:
	var s: GameState = c["state"]
	s.set_flag(name)


func _feet() -> Vector3:
	var ctrl: Variant = c.get("controls")
	return Vector3.ZERO if ctrl == null else ctrl.feet()


func _scares_on() -> bool:
	var f: Variant = c.get("scaresOn")
	return true if not (f is Callable) else bool((f as Callable).call())


func _emit(event: String, payload: Variant = null) -> void:
	var f: Variant = c.get("emit")
	if f is Callable:
		(f as Callable).call(event, payload)


func _ctx_call(name: String, args: Array = []) -> Variant:
	var f: Variant = c.get(name)
	if f is Callable:
		return (f as Callable).callv(args)
	return null

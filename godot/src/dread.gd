# Хоррор-слой. Редкие события, которых никто не делал: во дворе опрокинулось
# ведро, в соседней комнате скрипнула половица, на веранде само включилось радио.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ. Звуки эти обязаны быть редкими, и редкость — не
# свойство звука, а свойство расписания. Разложи их по местам вызова (interact,
# chapters, ai) — и каждое место будет считать свою частоту правильной, а игрок
# услышит их все подряд. Здесь один планировщик и один бюджет на главу.
#
# ЧЕТЫРЕ ПРАВИЛА, И НИ ОДНО ИЗ НИХ НЕ ПОЖЕЛАНИЕ.
#
# 1. У каждого события своя глава, с которой оно доступно (поле min).
#    Фаза 8: единый гейт «только с ТЕМНОТЫ» снят — он оставлял модулю окно
#    в одну главу из восьми, и первые пять часов игры дом не звучал вовсе,
#    а значит, к ночи не от чего было отклоняться. Правило темпа «до 23:40
#    ни одного акцента» никуда не делось, оно теперь в таблице: акценты
#    (whisper-close, breath-behind, sting-soft) стоят с min = dark, и это
#    сторожит tests/test_dread.gd.
# 2. Молчим, когда дед ближе двенадцати метров и когда он гонится ближе
#    двадцати пяти. Критерий тот же, что у haunt.gd::_threat_near, и по той же
#    причине: своя тревога у сцены уже есть, второй слой поверх неё её
#    размывает, а не усиливает. Прежний гейт по состоянию 'hunt' выключал
#    модуль во ВСЕЙ главе ВОРОТА, где он нужнее всего.
# 3. Шесть секунд тишины после любого стингера. Событие сразу за скримером
#    читается как часть скримера, то есть пропадает.
# 4. Уличное — мимо реверба комнаты. Позиционного звука в проекте нет вовсе
#    (AudioStreamPlayer3D не используется нигде), поэтому «во дворе» делается
#    тем, что есть: шина Dry и пониженный гейн, когда игрок в доме.
#
# Планировщик списан с haunt.gd (TRY_EVERY/TRY_CHANCE/budget/global_cd
# и пер-именные кулдауны): там он уже написан и уже отыгран в прототипе.
#
# Звука может не быть вовсе: без godot/audio/sfx/ audio.sfx() возвращает false,
# и модуль тихо не делает ничего — игра звучит как принятая версия фазы 4.
class_name GameDread
extends Node

# Как часто вообще проверяются условия и с какой вероятностью пробуем.
const TRY_EVERY := 1.0
const TRY_CHANCE := 0.5

# Глобальный кулдаун после сработки и тишина в начале главы / после [R].
const GLOBAL_CD_MIN := 45.0
const GLOBAL_CD_MAX := 90.0
const START_CD := 30.0

# До «ТЕМНОТЫ» кулдаун вдвое длиннее (90–180 с). В первых главах игрок занят
# задачами, и событие раз в сорок пять секунд читается саундтреком, а не
# аномалией; редкость — это не громкость, а расписание.
const EARLY_CD_K := 1.5

# Сколько событий за главу. Верхний предел важнее нижнего: при кулдауне
# 45–90 с «ТЕМНОТА» физически вмещает больше, чем нужно, и без бюджета
# редкое перестаёт быть редким к середине ночи.
#
# Фаза 8: бюджет стал табличным. Итог за прохождение — 18–25 событий против
# прежних 5–8, и две трети из них по-прежнему после 23:40.
const BUDGET := {
	"prologue": [0, 0],
	"arrive": [1, 2],
	# Фаза 11: верхняя граница первых трёх домашних глав поднята на единицу —
	# в первой половине ночи было слишком тихо.
	"light": [2, 4],
	"loft": [3, 5],
	"tapes": [3, 5],
	# УЛИЦА идёт двадцать с лишним минут и почти вся под открытым небом —
	# бюджет тут самый большой в игре до ТЕМНОТЫ. Играть будет в основном
	# двор ("yard"): "house" за воротами не проходит отбор по построению,
	# и это правильно — звук не должен врать о том, где игрок.
	"street": [4, 6],
	"dark": [6, 9],
	# ДЕРЕВНЯ (фаза 12): девяносто метров под открытым небом и ни одного окна
	# на всей линии. Играть здесь будет двор ("yard") и «вплотную» ("close");
	# "house" за воротами не проходит отбор по построению, и это правильно —
	# звук не должен врать о том, где игрок.
	"village": [5, 7],
	"gate": [2, 3],
	"end": [0, 0],
}
# На сколько событий за главу двигает бюджет одна ступень темпа (фаза 15).
const PACE_STEP := 2

const BUDGET_MIN := 7
const BUDGET_MAX := 10

# Дед рядом — молчим. То же число, что в haunt.gd::THREAT_NEAR.
const THREAT_NEAR := 12.0
# И в погоне — на большем радиусе: бегущий за спиной сам себе событие.
const HUNT_NEAR := 25.0

# Тишина после стингера.
const AFTER_STING := 6.0

# Уличное событие, когда игрок в доме: слышно, но через стену.
const YARD_INDOOR_GAIN := 0.45

# Стингеров в игре три источника, и все три оставляют след в состоянии: скример
# поимки поднимает failCount, оба сценарных джампскейра ставят флаг. Ловим след,
# а не сам звук: аудио-слой подписок не принимает, а звать dread из chapters.gd
# значит завести второго владельца темпа.
const STING_FLAGS: Array[String] = ["hatch-slam", "gate-scare"]

# Таблица событий. Каждое имя ОБЯЗАНО существовать в оверлее sfx или
# в запечённом манифесте — это сторожит tests/test_dread.gd.
#
#   where — "yard"  улица: шина Dry всегда, тише, когда игрок в доме;
#           "house" дом: не играется, пока игрок на улице (иначе звук врёт
#                   о том, где он, — а врать про это нельзя);
#           "close" вплотную: где угодно и с ревербом своей зоны.
#   min   — с какой главы событие доступно (фаза 8). Порядок глав держит
#           state.CHAPTERS, сверку с ним делает tests/test_dread.gd.
#   i     — интенсивность для шкалы напряжения: 1 бытовое, 2 заметное,
#           3 акцент. Окна и потолок — в tension.gd.
#   cd    — собственный кулдаун имени, секунд.
#   once  — ровно один раз за прохождение, через флаг состояния.
#   w     — вес при выборе среди доступных.
#   not_level — не играть, когда игрок на этом уровне (снизу вверх не слышно).
#
# Раскладка по главам не «чтобы было раньше», а чтобы к ТЕМНОТЕ у игрока была
# базовая линия: двор, который звучит сам. Ворона и далёкий вой с приезда —
# это она и есть; без неё в темноте не от чего отклоняться.
const EVENTS := [
	# ---------- двор ----------
	# Ведро — то самое, с чего начался разговор: громко, один раз за ночь,
	# и объяснить его нечем.
	{"id": "yard-bucket", "where": "yard", "min": "tapes", "i": 2, "cd": 0.0,
		"once": true, "w": 3},
	{"id": "yard-metal-drag", "where": "yard", "min": "loft", "i": 2, "cd": 0.0,
		"once": true, "w": 2},
	{"id": "yard-gate-far", "where": "yard", "min": "light", "i": 1, "cd": 240.0, "w": 3},
	{"id": "yard-dog-howl", "where": "yard", "min": "arrive", "i": 1, "cd": 300.0, "w": 3},
	{"id": "yard-crow", "where": "yard", "min": "arrive", "i": 1, "cd": 240.0, "w": 2},
	# ФАЗА 12. Два события на девяносто метров деревни, и оба на УЖЕ
	# существующих звуках. Новых wav фаза не заводит намеренно: остаток счёта
	# ElevenLabs (1692 кредита) целиком отдан шестнадцати репликам, а «редкий
	# страшный звук», которого нет в манифесте, просто никогда не звучит —
	# и отличить это от «не выпало» на слух нельзя (ради этого и написан
	# tests/test_dread.gd).
	#
	# Цепь — колодезная: ворот стоит на западном конце линии, и звенеть ему
	# ночью нечем. Тот же wav, что у ворот участка, поэтому знак 'gate-chain'
	# после себя глушит и это событие (omens._hush).
	{"id": "chain", "where": "yard", "min": "village", "i": 2, "cd": 200.0, "w": 3},
	# Стук в дверь где-то на линии. Игрок только что обошёл три двери сам,
	# и ему не открыли ни в одну.
	{"id": "door-knock", "where": "yard", "min": "village", "i": 2, "cd": 260.0, "w": 2},
	# ФАЗА 13. Холодильник в красном доме — единственный работающий прибор
	# на всей линии, и компрессор у него включается сам. Звук взят готовый
	# и не случайный: 'tape-hum' — это тот самый «гул холодильника снизу»
	# с плёнки без этикетки. Игрок слышал его на кассете час назад, а теперь
	# слышит вживую, в чужом пустом доме напротив своих ворот. Один раз
	# за прохождение: второй превратил бы это в фон.
	{"id": "tape-hum", "where": "yard", "min": "village", "i": 1, "cd": 0.0,
		"once": true, "w": 2},

	# ---------- дом ----------
	{"id": "floor-creak-far", "where": "house", "min": "loft", "i": 1, "cd": 150.0, "w": 4},
	{"id": "house-groan", "where": "house", "min": "light", "i": 1, "cd": 200.0, "w": 3},
	{"id": "door-far", "where": "house", "min": "loft", "i": 1, "cd": 200.0, "w": 3},
	{"id": "bed-creak", "where": "house", "min": "tapes", "i": 2, "cd": 240.0, "w": 2,
		"not_level": "attic"},
	{"id": "glass-tap", "where": "house", "min": "tapes", "i": 2, "cd": 300.0, "w": 2},
	# Фаза 11. Банки в подполе — единственное, что в этом доме стоит рядами,
	# и звенеть им незачем. С чердака этого не слышно: not_level отсекает.
	{"id": "jar-glass", "where": "house", "min": "tapes", "i": 2, "cd": 280.0, "w": 3,
		"not_level": "roof"},
	# Радио на веранде оставляла Тоня (texts.json), телевизор на мансарде
	# работает (tapes.json). Оба — один раз: включившийся сам прибор нельзя
	# услышать дважды и остаться при том же ужасе.
	{"id": "radio-veranda", "where": "house", "min": "light", "i": 2, "cd": 0.0,
		"once": true, "w": 2},
	{"id": "tv-attic", "where": "house", "min": "loft", "i": 2, "cd": 0.0,
		"once": true, "w": 2, "not_level": "attic"},

	# ---------- вплотную ----------
	# Все три — акценты, и все три с «ТЕМНОТЫ»: правило «до 23:40 ни одного
	# акцента» живёт ровно здесь.
	{"id": "whisper-close", "where": "close", "min": "dark", "i": 3, "cd": 360.0, "w": 1},
	{"id": "breath-behind", "where": "close", "min": "dark", "i": 3, "cd": 360.0, "w": 1},
	{"id": "hum-rise", "where": "close", "min": "tapes", "i": 2, "cd": 300.0, "w": 2},
	{"id": "sting-soft", "where": "close", "min": "dark", "i": 3, "cd": 180.0, "w": 3},

	# ---------- фаза 14: околица ----------
	# Четыре события, и снова ни одного нового wav — по той же причине, что
	# в фазе 12, только причина теперь другая: потолок счёта поднят на две
	# тысячи кредитов ПОД ОЗВУЧКУ, и тратить их на звук, который выпадает
	# раз в пять минут, значит снять реплику деда. Все четыре имени уже
	# лежат в оверлее и в запечённом, и «pump-hum» из плана — это hum-rise
	# двумя строками выше: рубильник зовёт его принудительно (outskirts_quest).
	#
	# Все четыре — where "yard": околица под открытым небом, а "house"
	# отсекается по outdoors и здесь не сработал бы вовсе.
	#
	# Состав за полем. В деревне его не слышно — там дома; на околице
	# слышно, и это единственное на карте доказательство, что где-то есть
	# ещё мир.
	{"id": "train", "where": "yard", "min": "village", "i": 1, "cd": 320.0, "w": 3},
	# Шаги по лестнице. У игрока над головой чужой пол ровно в одном месте
	# на всю карту — на втором этаже красного дома. Один раз за прохождение:
	# второй превратил бы это в фон.
	{"id": "tape-stairs", "where": "yard", "min": "village", "i": 2, "cd": 0.0,
		"once": true, "w": 2},
	# Бормотание где-то на линии. Не слова — интонация: кто-то договаривает
	# фразу и замолкает.
	{"id": "mumble", "where": "yard", "min": "village", "i": 2, "cd": 300.0, "w": 2},
	# В амбаре что-то упало. Скотины там нет с весны, ронять нечему.
	{"id": "basket-drop", "where": "yard", "min": "village", "i": 2, "cd": 280.0, "w": 2},
]

# Префикс флага «уже было». Свой, чтобы не столкнуться с сюжетными флагами.
const ONCE_PREFIX := "dread-"

var c: Variant = null
var rng := RandomNumberGenerator.new()

var chapter: Variant = null
var shown := 0
var budget := BUDGET_MIN
# Ступень темпа: >0 — тише, <0 — шумнее (фаза 15, см. ease()).
var pace := 0
var try_in := TRY_EVERY
var global_cd := START_CD
var sting_quiet := 0.0
var cooldowns: Dictionary = {}      # имя -> сколько секунд ещё нельзя
var last := ""                      # что сыграло последним

var _fails := -1
var _flags: Dictionary = {}
# Истёкшие имена кулдаунов этого кадра. Член, а не локальный массив: см.
# _tick_cooldowns().
var _cd_dead: Array[String] = []


## Кулдауны на кадр. Обходится СЛОВАРЬ, а не его keys(): keys() выделяет новый
## массив каждый кадр, и таких мест было три — здесь, в haunt.gd и в omens.gd.
## Стирать во время обхода нельзя, поэтому истёкшие копятся в переиспользуемый
## массив и убираются после.
func _tick_cooldowns(dt: float) -> void:
	if cooldowns.is_empty():
		return
	_cd_dead.clear()
	for id: String in cooldowns:
		var left: float = float(cooldowns[id]) - dt
		if left <= 0.0:
			_cd_dead.append(id)
		else:
			cooldowns[id] = left
	for id: String in _cd_dead:
		cooldowns.erase(id)


func _init(ctx: Variant = null, rng_seed: int = 0) -> void:
	c = ctx
	rng.seed = rng_seed


# Звать каждый кадр, пока игра идёт.
func update(dt: float) -> void:
	var st: Variant = _cx("state")
	if st == null:
		return

	_watch_stingers(st)
	sting_quiet = maxf(0.0, sting_quiet - dt)
	global_cd -= dt
	_tick_cooldowns(dt)

	# Пролог — единственная отсечка, которая осталась общей: там игрок сидит
	# в кабинете следователя, и дачных звуков в нём быть не может.
	if not bool(st.atLeast("arrive")):
		return

	var cur := String(st.get("chapter"))
	if chapter == null or cur != String(chapter):
		chapter = cur
		shown = 0
		var b: Array = BUDGET.get(cur, [BUDGET_MIN, BUDGET_MAX])
		budget = maxi(1, rng.randi_range(int(b[0]), int(b[1])) - PACE_STEP * pace)

	if sting_quiet > 0.0:
		return
	if _threat_near():
		return
	# Из укрытия события не читаются как «где-то в доме»: игрок сидит в шкафу
	# и слышать может что угодно, но проверить не может ничего.
	if bool(st.get("hidden")):
		return

	try_in -= dt
	if try_in > 0.0:
		return
	try_in = TRY_EVERY

	if global_cd > 0.0 or shown >= budget:
		return
	if rng.randf() > TRY_CHANCE:
		return
	_fire(st)


## Сдвинуть темп тревог на ступень (фаза 15). Плюс — тише, минус — шумнее.
##
## Зовут отсюда ровно два места, и оба сюжетные: круг из камней у ограды Вали
## сложен (тише) и не сложен к финалу (шумнее). Это не выключатель страха:
## меняется бюджет событий на главу и ближайший общий кулдаун, то есть
## насколько часто дом подаёт голос. Игрок это слышит, а не читает.
##
## pace переживает смену главы — иначе ступень действовала бы одну главу
## и пропадала на переходе, ровно там, где она и нужна.
func ease(steps := 1) -> void:
	if steps == 0:
		return
	pace += steps
	budget = maxi(1, budget - PACE_STEP * steps)
	if steps > 0:
		global_cd = maxf(global_cd, GLOBAL_CD_MIN * 0.5 * float(steps))
	else:
		global_cd = minf(global_cd, GLOBAL_CD_MIN * 0.25)


## Занять имя на своё время. Нужен оменам (omens.gd): они играют те же звуки
## своими поводами, и без этого дом дважды подряд скрипел бы одной половицей.
func force_cooldown(id: String, sec: float) -> void:
	if sec <= 0.0:
		return
	cooldowns[id] = maxf(float(cooldowns.get(id, 0.0)), sec)


# При [R]: снять кулдауны и вернуть тишину начала главы.
func reset() -> void:
	cooldowns.clear()
	shown = 0
	var b: Array = BUDGET.get(String(chapter) if chapter != null else "dark",
		[BUDGET_MIN, BUDGET_MAX])
	budget = maxi(1, rng.randi_range(int(b[0]), int(b[1])) - PACE_STEP * pace)
	try_in = TRY_EVERY
	global_cd = START_CD
	sting_quiet = 0.0
	last = ""
	# Флаги «уже было» НЕ сбрасываются: они живут в состоянии игры и снимаются
	# вместе с ним. Иначе смерть у ворот возвращала бы ведро на второй заход,
	# и «один раз за прохождение» превратилось бы в «раз на попытку».


# Отладка: сыграть событие по имени немедленно, мимо всех условий.
func force(id: String) -> bool:
	for e: Dictionary in EVENTS:
		if String(e["id"]) == id:
			_play(e)
			return true
	var names := PackedStringArray()
	for e: Dictionary in EVENTS:
		names.append(String(e["id"]))
	push_warning("dread: нет события «%s»; есть %s" % [id, ", ".join(names)])
	return false


# Одна строка для экрана F3.
func debug_line() -> String:
	return "тревога %s   кд %dс   %d/%d за главу" % [
		("—" if last == "" else last), roundi(maxf(0.0, global_cd)), shown, budget]


# ---------- внутреннее ----------

func _fire(st: Variant) -> void:
	var outdoors := _outdoors()
	var level := _level()
	var ten: Variant = _cx("tension")
	var pool: Array = []
	var total := 0
	for e: Dictionary in EVENTS:
		var id := String(e["id"])
		if cooldowns.has(id):
			continue
		if id == last:
			continue
		if not bool(st.atLeast(String(e.get("min", "dark")))):
			continue
		if bool(e.get("once", false)) and bool(st.has(ONCE_PREFIX + id)):
			continue
		var where := String(e["where"])
		if where == "house" and outdoors:
			continue
		if String(e.get("not_level", "")) == level:
			continue
		# Шкала напряжения решает последней: своё окно есть у каждой
		# интенсивности, и на пике не проходит ничто. Нет шкалы в ctx —
		# модуль работает ровно как в фазе 7.
		if ten != null and not bool(ten.allows(int(e.get("i", 1)))):
			continue
		var w := int(e.get("w", 1))
		total += w
		pool.append([e, total])
	if pool.is_empty():
		return

	var roll := rng.randi_range(1, total)
	var played: Dictionary = {}
	for row: Array in pool:
		if roll <= int(row[1]):
			played = row[0] as Dictionary
			_play(played)
			break

	shown += 1
	if ten != null and not played.is_empty():
		ten.spent(int(played.get("i", 1)))
	var k := 1.0 if bool(st.atLeast("dark")) else EARLY_CD_K
	global_cd = (GLOBAL_CD_MIN + rng.randf() * (GLOBAL_CD_MAX - GLOBAL_CD_MIN)) * k


func _play(e: Dictionary) -> void:
	var a: Variant = _cx("audio")
	if a == null:
		return
	var id := String(e["id"])
	var where := String(e["where"])
	var gain := 1.0
	var bus := &""
	if where == "yard":
		# Улица идёт мимо реверба комнаты всегда: ведро во дворе, отражённое
		# стенами кухни, звучит так, будто оно на кухне.
		bus = &"Dry"
		if not _outdoors():
			gain = YARD_INDOOR_GAIN
	if not bool(a.sfx(id, gain, bus)):
		# Оверлея нет — звука нет. Ни кулдауна, ни бюджета за это не берём:
		# иначе на сборке без godot/audio/sfx/ модуль «расстрелял» бы бюджет
		# главы в тишину.
		return
	last = id
	if bool(e.get("once", false)):
		var st: Variant = _cx("state")
		if st != null:
			st.set_flag(ONCE_PREFIX + id)
	var cd := float(e.get("cd", 0.0))
	if cd > 0.0:
		cooldowns[id] = cd


# След стингера в состоянии. failCount растёт на скримере поимки, флаги
# ставятся обоими сценарными джампскейрами.
func _watch_stingers(st: Variant) -> void:
	var fails := int(st.get("failCount"))
	if _fails < 0:
		_fails = fails
	elif fails != _fails:
		_fails = fails
		sting_quiet = AFTER_STING
	for f in STING_FLAGS:
		var on := bool(st.has(f))
		if on and not bool(_flags.get(f, false)):
			sting_quiet = AFTER_STING
		_flags[f] = on


# Настоящий дед рядом с камерой? Позицию берём у самой угрозы, а не у фигуры:
# фигура едет за pos с доворотом и на кадр отстаёт. Тот же критерий, что
# в haunt.gd, но без пирамиды видимости: звук слышно и за спиной.
func _threat_near() -> bool:
	var tv: Variant = _cx("threat")
	if not (tv is Threat):
		return false
	var t: Threat = tv
	if not t.is_active():
		return false
	var p: Variant = _cx("controls")
	if p == null:
		return false
	var feet: Vector3 = p.feet()
	var d := feet.distance_to(t.pos)
	# Погоня — тот же критерий, но на большем радиусе. Прежняя проверка
	# по состоянию 'hunt' выключала модуль на всю главу, даже когда дед
	# гонится за шумом в другом конце участка.
	if _state_str(_cx("state")) == "hunt":
		return d < HUNT_NEAR
	return d < THREAT_NEAR


# На улице ли игрок. Критерий тот же, которым main.gd переключает уровень
# уличного слоя: реверб зоны.
func _outdoors() -> bool:
	return String(_zone().get("reverb", "outdoor")) == "outdoor"


func _level() -> String:
	return String(_zone().get("level", ""))


func _zone() -> Dictionary:
	var p: Variant = _cx("controls")
	var w: Variant = _cx("world")
	if p == null or not (w is Dictionary):
		return {}
	var d: Dictionary = w
	var f: Variant = d.get("zone_at", null)
	if not (f is Callable):
		return {}
	var cb: Callable = f
	var feet: Vector3 = p.feet()
	var z: Variant = cb.call(feet.x, feet.y, feet.z)
	return z if z is Dictionary else {}


# Имя поля — как в state.gd и в оригинале: threatState.
func _state_str(st: Variant) -> String:
	if st == null:
		return "absent"
	var v: Variant = st.get("threatState")
	return "absent" if v == null else String(v)


func _cx(key: String) -> Variant:
	if c is Dictionary:
		var d: Dictionary = c
		return d.get(key, null)
	if c == null:
		return null
	return c.get(key)

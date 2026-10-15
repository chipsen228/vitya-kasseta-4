# Угроза. Порт game/ai.js один-в-один: дед Витя, семьдесят восемь лет, живёт
# на этой даче круглый год.
#
# Четыре состояния: absent (главы 1-4, только следы), patrol (ходит по дому
# и участку, реагирует на свет в окнах, на крик и на бег), hunt (ищет по
# последнему шуму), caught (догнал). Между этажами он не ходит: при смене этажа
# игроком телепортируется на правдоподобную точку через шесть-десять секунд —
# страшнее честного патфайндинга, потому что он не «идёт следом», он просто
# оказывается там же, где ты, и ты не видел как.
#
# ПОЧЕМУ ОН НЕ БЕГАЕТ. Максимум (погоня плюс шум) — 1.392 м/с против 1.55
# у идущего игрока. Напряжение делается не скоростью: он не устаёт, срезает
# через комнаты по графу и СЛЫШИТ БЕГ — раз в 0.35 с получает точную позицию.
#
# Что портировано и что нет. Ходьба идёт по навграфу (nav_graph.gd), пробы —
# только через CollisionWorld.capsule_hit_d по семантике nav.js (_clear+blocks).
# Фигуру и походку делает actors.gd (фаза 3): здесь только позиция, курс
# и вызовы place/face_to/walk_anim.
#
# Двойник ('echo') — не наш: им распоряжается haunt.gd. Владелец фигуры
# 'threat' — только этот файл, каждый кадр.
class_name Threat
extends RefCounted

# ---------------------------------------------------------------- мерка ----

const R := 0.32              # радиус капсулы деда; фигура уже её на 9 мм (actors)
const TOUCH := 0.02          # касание в пределах точности — не пересечение (nav.js)
const STEP_UP := 0.20        # порог сарая 0.12, крышка погреба 0.14, ступень 0.178
const FLOOR_TOL := 0.35      # насколько найденный пол вправе отличаться от отметки ног
const PROBE_AHEAD := 0.05    # на столько щупаем вперёд и столько идём без новой пробы
const Y_RATE := 1.2          # м/с, с какой ноги переезжают на отметку следующего узла
const STOOP_LOW := 0.22      # добавка сутулости под балками подпола и чердака

# Верх пробной капсулы по слоям — тот же словарь, что в nav.js: в подполе
# просвет 1.90, и полная проба 1.55 не оставляла там ни одной свободной точки.
const PROBE_TOP := {"floor1": 1.55, "attic": 1.55, "plot": 1.55, "cellar": 1.42, "roof": 1.40}

# Скорости. Ходьба игрока 1.55, бег 3.05, присед 0.80.
#   патруль 0.780, патруль на шум 0.920, погоня 1.180, погоня на шум 1.392 —
#   максимум, запас до ходьбы 0.158 м/с. Приседающий игрок медленнее
#   охотящегося деда в 1.74 раза: присед — способ спрятаться, а не убежать.
#
# ФАЗА 7. Погоня была безнадёжной: максимум 1.392 против 1.55 у ИДУЩЕГО игрока,
# то есть отойти от деда можно было шагом, не оглядываясь. Теперь максимум
# 1.42 * 1.08 = 1.5336 — на 1.6 сантиметра в секунду ниже шага. Он догоняет
# того, кто замешкался, стоит или пятится, и не догоняет того, кто идёт;
# бегущий (3.05) уходит от него всегда. SPEED_PATROL не трогается: его число
# продублировано в tests/audit_nav.gd.
const SPEED_PATROL := 0.78
const SPEED_HUNT := 1.42

# ФИНАЛЬНАЯ ПОГОНЯ (фаза 15). Шаг игрока — 1.55 м/с, здесь 1.46: догоняет
# только на ошибке. Ровнее было бы 1.55, но тогда исход не зависит от игрока
# вовсе, а медленнее 1.4 — и погоня перестаёт быть погоней.
const SPEED_FINAL := 1.46
const FINAL_DIST := 12.0     # с какого расстояния он стартует
const FINAL_SIDE := 0.9      # сколько секунд держится обход после упора
const NOISE_BOOST := 1.08

# Разгон и торможение. Раньше скорость подставлялась в шаг мгновенно: дед
# трогался с места на полном ходу и вставал как вкопанный — отсюда «ходит
# роботизировано». 2.4 м/с² — это полсекунды до патрульных 0.78; тормозит
# он быстрее, чем разгоняется, как и всякий, кто идёт осторожно.
# Походка в actors.gd считает фазу по пройденному пути, поэтому разгон сам
# по себе даёт правильное «первый шаг короче».
const ACCEL := 2.4
const DECEL := 3.6

# ------------------------------------------------------------ следование ----

const REACH_DOOR := 0.28     # радиус достижения дверного узла: в проёме не разойтись
const REACH_ROOM := 0.55     # и комнатного
const REACH_LINK := 0.22     # и точки ломаной перехода — там 0.55 съел бы всю площадку

# Переходы между слоями (фаза 7). Пока он идёт по ломаной, обычные пробы
# выключены: ломаную проверил tests/test_nav_links.gd на сборке, а проба в шахте
# люка честно отвечает «занято» — она смотрит вверх и вбок, а он падает на два
# метра вниз. Отсюда же и предохранитель: не дошёл за TRAV_LIMIT — переход
# бросается, и слои снова разводит телепорт.
const TRAV_LIMIT := 26.0
const TRAV_COOL := 8.0       # после брошенного перехода следующий не сразу
const REACH_PASS := 0.60     # насколько прощаем перелёт узла, если он уже за спиной
const TURN_RATE := 3.2       # рад/с: при 1.18 м/с радиус поворота 0.37 — в проём 0.9 влезает
const TURN_FAST := 6.0       # в дверях и на развороте больше 137°
const TURN_HARD := 2.391     # те самые 137° в радианах
# С фазы 7 оба числа — ПОТОЛКИ, а не постоянные. Линейный доворот rate*dt
# начинается и обрывается мгновенно: голова фигуры дёргалась на каждом узле
# пути. Теперь угловая скорость сама разгоняется до потолка и гасится по мере
# приближения к курсу — то же ease-in-out, что у живой шеи.
const TURN_ACCEL := 9.0      # рад/с² разгона доворота
const TURN_EASE := 4.2       # во сколько раз остаток угла больше нужной скорости
const TURN_MIN := 0.25       # ниже этого доворот не сходится за разумное время
const CUT_EVERY := 0.2       # как часто пробуем срезать угол
const CUT_MAX := 4.0         # длиннее — не срез, а новый путь
const CUT_STEP := 0.45       # шаг сэмплирования коридора среза
const CUT_TRIES := 3         # попыток на отрезок: иначе срез стоит дороже ходьбы
const CUT_BLOCK := 3.0       # на сколько детектор застревания выключает срезание
const DOOR_REACH := 1.0      # с какого расстояния он берётся за ручку
const DOOR_WAIT := 0.85      # и сколько стоит, пока полотно поворачивается
const REPATH_CHASE := 0.75   # перестроение пути в погоне
const GOAL_DRIFT := 1.5      # либо раньше, если цель уехала дальше этого
const IDLE_MIN := 1.2
const IDLE_MAX := 2.6        # дневка на комнатном узле
const STEP_DIST := 0.76      # шаг деда, тот же STRIDE, что у походки в actors
const LOOK_NEAR := 9.0       # ближе этого он наводит голову на игрока

# ------------------------------------------------------------ застревание ----

const SAMPLE_DT := 0.25      # отсчёт позиции
const HIST := 8              # кольцо из восьми: окно ровно 2 с
const STUCK_NEED := [0.35, 0.45, 0.50, 0.50]   # сколько надо пройти за окно на ступени
const SIDE_MIX := 0.35       # боковая составляющая от скорости на первой ступени
const SIDE_TIME := 1.5
const ESCAPE_FAR := 6.0      # третья ступень: телепорт не ближе этого к игроку

# --------------------------------------------------------------- респаун ----

const MIN_STRAIGHT := 4.5    # не появляться в упор
const LOOK_DOT := 0.45       # косинус, за которым точка считается «в поле зрения»
# Метрика ПО ГРАФУ, а не по прямой: дом 10 x 9.6 м, из кухни по прямой максимум
# 5.4 м, и порог «не ближе 9 м» по прямой невыполним физически. roof 3.0
# и cellar 4.0 — потому что оба помещения дают ровно по два узла, и пороги
# 6.0/8.0 там не выполнимы ни при каком расположении.
const MIN_PATH := {"plot": 16.0, "floor1": 9.0, "attic": 7.0, "roof": 3.0, "cellar": 4.0}
const GRACE := 4.5           # фора после поимки: не ловит, не охотится, не слышит
const GRACE_STEPS := 1.2     # на этой отметке слышно, что он встал и пошёл
const MUTE := 12.0           # и молчит вдвое дольше
const CATCH_DIST := 1.15
const RUN_HEAR_EVERY := 0.35 # как часто бегущий игрок отдаёт позицию

# Где он стоит до первой главы с угрозой. Та же точка, что и в chapters.
const START_X := -3.0
const START_Z := 15.4

# ----------------------------------------------------------------- поля ----

var c: Variant = null            # ctx из main.gd (Dictionary либо объект)
var actors: Variant = null
var nav: NavGraph = null         # граф фазы 2; null — дед остаётся стоять
var col: CollisionWorld = null
var rng := RandomNumberGenerator.new()

# Позиция держится в double: Vector3 в Годо — float32, и проба у самой грани
# от такого округления переворачивается (грабля фазы 1, см. CONTRACTS).
var _px := 0.0
var _py := 0.0
var _pz := 0.0

# Наружу отдаём тем же полем, что в оригинале.
var pos: Vector3:
	get:
		return Vector3(_px, _py, _pz)
	set(value):
		_px = value.x
		_py = value.y
		_pz = value.z

var layer := "floor1"
var goal := Vector3.ZERO
var speed_scale := 1.0

var noise: Variant = null        # Vector3 либо null
var noise_timer := 0.0
var relocate_in := 8.0
var line_timer := 12.0
var run_in := 0.0

# Фора после поимки — два поля, а не пятое значение threatState: оно протекло бы
# в снимок состояния, в haunt и в отладочный экран.
var grace := 0.0
var mute := 0.0

# Путь и следование по нему.
var path: Array = []
var path_at := 0
var chasing := false

# Финальная погоня: прямая линия к игроку мимо навграфа (фаза 15). Ставится
# главой ВОРОТА в момент, когда цепь снята, и живёт до конца прохождения.
var final_mode := false
var _final_side := 0.0
var _final_sign := 1.0
# Какими наборами коллизий ищется пол под ногами. По умолчанию — только
# статикой, как было: улица, деревня и околица лежат в четвёртом наборе,
# и дед на них не ступал ни разу за игру. В погоне пол берётся и оттуда:
# без этого он остаётся заперт на участке, а бежать надо по дороге.
var _floor_mask := CollisionWorld.MASK_STATIC
var repath_in := 0.0
var patrol_at := 0
var idle := 0.0
var door_wait := 0.0
var leg_x := 0.0
var leg_z := 0.0
var cut_in := CUT_EVERY
var cut_off := 0.0
var cut_tries := 0
var walked := 0.0
# Инерция (фаза 7). Скорость и угловая скорость держатся между кадрами:
# без них дед трогается и встаёт мгновенно, а поворачивает с постоянной
# угловой — три признака заводной игрушки разом.
var _speed_now := 0.0
var _turn_vel := 0.0
# Идущий переход между слоями: шаг цепочки NavLinks либо пустой словарь.
var links: NavLinks = null
var _trav: Dictionary = {}
var _trav_time := 0.0
var _trav_cool := 0.0

# Детектор застревания.
var _hist := PackedFloat64Array()
var _hist_at := 0
var _hist_n := 0
var _sample_in := SAMPLE_DT
var _stage := 0
var _stuck_wait := 0.0
var _side_timer := 0.0
var _side_sign := 1.0

# Кредит хода: сколько метров можно пройти до следующей пробы и по какому курсу.
var _credit := 0.0
var _cred_x := 0.0
var _cred_z := 0.0
var _dirty := true               # «он мог оказаться в стене» — включает депенетрацию

# Текущая путевая точка. Поля вместо объекта: на шестидесяти кадрах в секунду
# это единственное место, где иначе капал бы мусор.
var _wp_has := false
var _wp_x := 0.0
var _wp_y := 0.0
var _wp_z := 0.0
var _wp_kind := "point"
var _wp_node: Variant = null

var _lines: Array = []

# Три имени из оригинала, которые склейка зовёт как есть: threat.active
# (haunt.js и отладочный экран), threat.speedScale (ctx.slowThreat) и
# threat.hardReset()/placeAt() (main.js, chapters.js). Держим оба написания —
# снаружи главы и main.gd пишутся по main.js, внутри всё snake_case.
var active: bool:
	get:
		return is_active()

var speedScale: float:
	get:
		return speed_scale
	set(value):
		speed_scale = value


# ---------------------------------------------------------------- слои ----

static var _marks_cache: Dictionary = {}

static func _marks() -> Dictionary:
	if _marks_cache.is_empty():
		var y: Dictionary = GameData.site()["Y"]
		_marks_cache = {
			"F1": float(y["FLOOR1"]), "F2": float(y["ATTIC"]), "F3": float(y["ROOF"]),
			"FC": float(y["CELLAR"]), "G": float(y["GROUND"]),
		}
	return _marks_cache


# Слой по отметке ног. Статический, потому что то же деление нужно главам:
# дублировать пороги в chapters значит однажды развести их между собой.
static func layer_of(y: float) -> String:
	var m := _marks()
	if y < float(m["G"]) - 0.6:
		return "cellar"
	if y < float(m["F1"]) - 0.2:
		return "plot"
	if y < float(m["F2"]) - 0.4:
		return "floor1"
	if y < float(m["F3"]) - 0.4:
		return "attic"
	return "roof"


static var _hides_cache: Array = []

# Укрытия. Правила у всех трёх одинаковые: закрыть за собой, не светить,
# не звать, ждать условный звук. Две точки, а не одна: pos — куда смотрит
# дескриптор взаимодействия, feet — куда встают ноги (высоту глаз считает
# player сам, дублировать её в данных нельзя). hide-wardrobe стоит на z 14.42,
# а не 14.35 по шкафу, — иначе капсула задевает перегородку кладовой.
static func hides() -> Array:
	if _hides_cache.is_empty():
		var m := _marks()
		var fc: float = m["FC"]
		var f2: float = m["F2"]
		_hides_cache = [
			{
				"id": "hide-cellar", "pos": [3.0, fc, 14.8],
				"label": "спрятаться за банки", "feet": [3.00, fc, 14.80]
			},
			{
				"id": "hide-wardrobe", "pos": [-5.0, f2, 14.35],
				"label": "залезть в шкаф", "feet": [-5.00, f2, 14.42]
			},
			{
				"id": "hide-privy", "pos": [8.6, 0.1, 21.0],
				"label": "закрыться на крючок", "feet": [8.60, 0.10, 21.00]
			},
		]
	return _hides_cache


# Имя места для узла. У комнатных оно в room, у участковых его нет вовсе —
# там ключ берётся из id ('plot:shed#0' -> 'shed'), ровно как в keyOf() графа.
static func _place_of(n: Dictionary) -> String:
	var room: Variant = n.get("room", null)
	if room != null and String(room) != "":
		return String(room)
	var id := String(n.get("id", ""))
	var lay := String(n.get("layer", ""))
	var rest := id.substr(lay.length() + 1)
	var at := rest.rfind("#")
	return rest if at < 0 else rest.substr(0, at)


# --------------------------------------------------------------- запуск ----

# ctx — контекст main.gd; actors_in — actors.gd; nav_in — nav_graph.gd;
# col_in — CollisionWorld. Последние два берутся из ctx, если не переданы.
# rng_seed фиксирует рандом: аудит патруля обязан повторяться до кадра.
func _init(ctx: Variant, actors_in: Variant, nav_in: Variant = null,
		col_in: Variant = null, rng_seed: int = 0) -> void:
	c = ctx
	actors = actors_in
	var nv: Variant = nav_in if nav_in != null else _cx("nav")
	if nv is NavGraph:
		nav = nv
	var cw: Variant = col_in if col_in != null else _cx("col")
	if cw is CollisionWorld:
		col = cw
	rng.seed = rng_seed

	var m := _marks()
	_px = START_X
	_py = float(m["F2"])
	_pz = START_Z
	layer = layer_of(_py)
	goal = Vector3(_px, _py, _pz)
	leg_x = _px
	leg_z = _pz
	_hist.resize(HIST * 2)

	var texts := GameData.texts()
	_lines = texts.get("THREAT_LINES", [])

	if nav == null:
		push_warning("ai: навграфа нет, дед останется стоять")


func is_active() -> bool:
	var s := _threat_state()
	return s == "patrol" or s == "hunt"


# Услышать шум. Во время форы он глухой — на то она и фора.
func hear(p: Vector3, strength: float = 1.0) -> void:
	if grace > 0.0:
		return
	noise = Vector3(p.x, p.y, p.z)
	noise_timer = 6.0 * strength
	if _threat_state() == "patrol":
		relocate_in = minf(relocate_in, 2.5)


# ================= кадр =================

func update(dt: float) -> void:
	var st: Variant = _cx("state")
	if not is_active():
		_actor_show(false)
		return

	var player: Variant = _cx("controls")
	if player == null:
		return
	var feet: Vector3 = player.feet()
	var player_layer := layer_of(feet.y)

	_tick(dt)
	_listen(dt, feet, st, player)
	_floors(dt, feet, player_layer)

	var moving := false
	if final_mode:
		# Ни плана, ни детектора застревания: в погоне нет ни узлов, чтобы
		# перестраивать путь, ни права выдернуть деда телепортом — игрок
		# смотрит на него в упор.
		moving = _chase(dt, feet)
	elif nav != null:
		_plan(dt, feet, player_layer, st)
		moving = _move(dt, feet)
		# На ломаной перехода детектор застревания молчит: лестница и шахта люка
		# для него — сплошное «стоит в стене», и он выдернул бы деда телепортом
		# ровно посреди марша. Страховкой там служит TRAV_LIMIT.
		if _trav.is_empty():
			_stuck(dt, feet)

	_render(dt, feet, moving, player_layer)
	_voice(dt, feet)
	_catch(st, feet)


func _tick(dt: float) -> void:
	if noise_timer > 0.0:
		noise_timer -= dt
		if noise_timer <= 0.0:
			noise = null
	if grace > 0.0:
		var was := grace
		grace -= dt
		# Конец форы озвучен бытово, без стингера: сначала шаги над головой —
		# «встал и пошёл, но неизвестно где», — а потом возвращается голос.
		# Возвращение голоса и есть сигнал.
		if was > GRACE_STEPS and grace <= GRACE_STEPS:
			_audio_call("steps_above", [2])
		if grace <= 0.0:
			grace = 0.0
			line_timer = minf(line_timer, 2.5)
	if mute > 0.0:
		mute = maxf(0.0, mute - dt)
	if idle > 0.0:
		idle -= dt
	if door_wait > 0.0:
		door_wait -= dt
	# Пока он стоит, скорость гасится здесь: _move в эти кадры выходит первой же
	# строкой и погасить её некому. Без этого следующий шаг начинался бы с той
	# скорости, на которой дед встал две секунды назад.
	if idle > 0.0 or door_wait > 0.0:
		_speed_now = move_toward(_speed_now, 0.0, DECEL * dt)
	if cut_off > 0.0:
		cut_off -= dt
	if _side_timer > 0.0:
		_side_timer -= dt
	if _trav_cool > 0.0:
		_trav_cool -= dt
	if not _trav.is_empty():
		_trav_time -= dt
		if _trav_time <= 0.0:
			_abort_traverse()


func _speed() -> float:
	var base := SPEED_HUNT if _threat_state() == "hunt" else SPEED_PATROL
	return base * speed_scale * (NOISE_BOOST if noise != null else 1.0)


func _listen(dt: float, feet: Vector3, st: Variant, player: Variant) -> void:
	if grace > 0.0:
		return

	# Фонарь в темноте — тоже шум. Он идёт на свет, об этом предупредили заранее.
	var flash: Variant = _cx("flashlight")
	if flash != null and bool(flash.on) and _at_least(st, "dark"):
		var d := _dist_to(feet)
		if d < 14.0 and rng.randf() < dt * 0.6:
			hear(feet, 0.8)

	# Бег. Пока он бежит, дед раз в 0.35 с получает точную позицию, силой тем
	# большей, чем ближе: 1.2 − d/22, но не слабее 0.35 и не сильнее 1.0.
	# На двадцати метрах это 0.35, вплотную — 1.0. Бег перестал быть бесплатным.
	run_in -= dt
	if bool(player.running) and _at_least(st, "dark") and run_in <= 0.0:
		run_in = RUN_HEAR_EVERY
		var d2 := _dist_to(feet)
		hear(feet, maxf(0.35, minf(1.0, 1.2 - d2 / 22.0)))


# Смена этажа. Раньше здесь был только телепорт: раз в 6–10 секунд дед
# оказывался на этаже игрока, и это читалось как «он не ходит, он возникает».
# Теперь первым делом пробуется цепочка переходов — лестница, крыльцо, люки, —
# и телепорт остаётся тем, чем должен был быть с самого начала: запасным
# выходом на случай, когда цепочки нет (игрок на крыше без стремянки),
# когда она не строится или когда дед на ней застрял.
func _floors(dt: float, feet: Vector3, player_layer: String) -> void:
	relocate_in -= dt
	if grace > 0.0:
		return
	if not _trav.is_empty():
		return
	if player_layer == layer:
		return
	if _trav_cool <= 0.0 and _start_traverse(player_layer):
		return
	if relocate_in > 0.0:
		return
	relocate_in = 6.0 + rng.randf() * 4.0
	_relocate(player_layer, feet)


# ================= переходы между слоями =================

## Взять первый шаг цепочки переходов до нужного слоя и построить под него путь:
## обычный A* до ближнего конца перехода, затем ломаная, затем дальний узел.
## Дальше по нему идёт тот же _move, что и всегда, — переход отличается только
## тем, что на его точках выключены пробы и срезание углов.
func _start_traverse(target_layer: String) -> bool:
	if links == null or nav == null:
		return false
	var chain := links.chain(layer, target_layer, _link_usable)
	if chain.is_empty():
		return false
	var step: Dictionary = chain[0]
	var from_node: Variant = nav.node(String(step["node_from"]))
	var to_node: Variant = nav.node(String(step["node_to"]))
	if from_node == null or to_node == null:
		return false

	var p := nav.path_to(layer, _px, _pz, float(from_node["x"]), float(from_node["z"]))
	if p.is_empty():
		return false
	var link: Dictionary = step["link"]
	var pts: Array = links.points(link, bool(step["forward"]))
	for i in pts.size():
		var pt: Vector3 = pts[i]
		p.append({
			"id": "link:%s#%d" % [link["id"], i], "kind": "link",
			"x": pt.x, "y": pt.y, "z": pt.z,
		})
	p.append(to_node)
	_set_path(p)
	chasing = false
	_trav = step
	_trav_time = TRAV_LIMIT
	return true


## Можно ли брать переход прямо сейчас. Запертость читается живьём у блокера,
## а не по флагу главы: входную дверь дед не отпирает сам — он идёт через неё
## только тогда, когда её уже открыли.
func _link_usable(l: Dictionary) -> bool:
	var need := String(l.get("needs_open", ""))
	if need == "":
		return true
	if col == null:
		return false
	return not col.is_blocker_active(need)


func _abort_traverse() -> void:
	if _trav.is_empty():
		return
	_trav = {}
	_trav_cool = TRAV_COOL
	_clear_path()
	_dirty = true


## Слой переключается ровно тогда, когда пройдена последняя точка ломаной:
## до неё он ещё на старом этаже, после — уже на новом, и A* обязан считать
## по новому. Заодно снимается сам переход, когда путь целиком пройден.
func _traverse_after_step() -> void:
	if _trav.is_empty():
		return
	var more := false
	for i in range(maxi(path_at, 0), path.size()):
		if String((path[i] as Dictionary).get("kind", "")) == "link":
			more = true
			break
	if not more and layer != String(_trav["to"]):
		layer = String(_trav["to"])
		# Позиция приехала мимо проб — один раз выдавимся из геометрии, если
		# ломаная поставила его вплотную к косяку.
		_dirty = true
	if path.is_empty() or path_at >= path.size():
		_trav = {}


# ================= цель и путь =================

# Кого он сейчас догоняет и по какому пути. Перестроение: в патруле — только
# по достижении конца пути, в погоне — раз в 0.75 с либо когда цель уехала
# дальше полутора метров. Прежний код искал цель каждый кадр и при упоре в стену
# брал новую случайную — отсюда «дёргается на месте».
func _plan(dt: float, feet: Vector3, player_layer: String, st: Variant) -> void:
	if door_wait > 0.0 or idle > 0.0:
		return
	# Переход не перепланируется на полдороге: сойти с лестницы посреди марша,
	# потому что игрок шевельнулся, — это ровно та дёрганость, от которой уходим.
	if not _trav.is_empty():
		return

	var chase := grace <= 0.0 and (noise != null
		or (_state_str(st) == "hunt" and player_layer == layer))

	if chase:
		var n: Vector3 = noise if noise != null else feet
		var gx := n.x
		var gz := n.z
		var gy := n.y
		repath_in -= dt
		var drift := sqrt((gx - goal.x) * (gx - goal.x) + (gz - goal.z) * (gz - goal.z))
		if path.is_empty() or repath_in <= 0.0 or drift > GOAL_DRIFT:
			repath_in = REPATH_CHASE
			goal = Vector3(gx, gy, gz)
			_repath(gx, gz)
		chasing = true
		return

	chasing = false
	if path.is_empty() or path_at >= path.size():
		_next_patrol()


# Путь до точки. Не нашёлся — прежний не выбрасываем: в погоне лучше идти
# по старому пути, чем встать посреди комнаты, пока граф думает.
func _repath(gx: float, gz: float) -> bool:
	if nav == null:
		return false
	var p := nav.path_to(layer, _px, _pz, gx, gz)
	if p.is_empty():
		return false
	_set_path(p)
	return true


func _set_path(p: Array) -> void:
	path = p
	path_at = 0
	leg_x = _px
	leg_z = _pz
	cut_tries = 0
	# Первый узел пути — ближайший к нему самому, и стоя между двумя узлами он
	# чаще всего уже за спиной: идти к нему значит развернуться и вернуться.
	# Пропускаем, если крюк через него длиннее прямой к следующему. Дверные узлы
	# не пропускаем никогда: створ 0.70 при капсуле 0.64 проходится только по оси.
	if p.size() > 1:
		var n0: Dictionary = p[0]
		var n1: Dictionary = p[1]
		if String(n0.get("kind", "room")) != "door":
			var d0 := _hyp(float(n0["x"]) - _px, float(n0["z"]) - _pz)
			var d1 := _hyp(float(n1["x"]) - _px, float(n1["z"]) - _pz)
			var seg := _hyp(float(n1["x"]) - float(n0["x"]), float(n1["z"]) - float(n0["z"]))
			if d0 < 2.0 and d0 + seg > d1 + 0.30:
				path_at = 1


func _clear_path() -> void:
	path = []
	path_at = 0
	chasing = false
	repath_in = 0.0
	cut_tries = 0
	leg_x = _px
	leg_z = _pz


# Следующая точка кольца. Кольцо детерминированное и считается графом один раз
# на слой, так что «маршрут» у него один и тот же всю игру — как у человека,
# который тридцать лет обходит один и тот же дом.
func _next_patrol() -> void:
	var ring := _patrol_ring(layer)
	if ring.is_empty():
		idle = IDLE_MIN
		return
	var from := _nearest(layer, _px, _pz, "")
	if from.is_empty():
		idle = IDLE_MIN
		return

	for _k in ring.size():
		patrol_at = (patrol_at + 1) % ring.size()
		var node: Dictionary = ring[patrol_at]
		# Оригинал сравнивает узлы по ссылке; здесь они словари, и надёжнее id —
		# он уникален по построению графа.
		if String(node["id"]) == String(from["id"]):
			continue
		var p := _path(from, node)
		if not p.is_empty():
			_set_path(p)
			return
	# Кольцо не разрешилось: компоненты слоя не связаны между собой. Стоим,
	# а не мечемся — мечущийся дед читается как поломка, стоящий как пауза.
	idle = IDLE_MIN


# Ближайшая по счёту точка кольца: после телепорта обход продолжается отсюда.
func _sync_patrol() -> void:
	var ring := _patrol_ring(layer) if nav != null else []
	var bi := 0
	var bd := INF
	for i in ring.size():
		var n: Dictionary = ring[i]
		var d := _hyp(float(n["x"]) - _px, float(n["z"]) - _pz)
		if d < bd:
			bd = d
			bi = i
	patrol_at = bi


func _waypoint() -> void:
	if path_at >= 0 and path_at < path.size():
		var n: Dictionary = path[path_at]
		_wp_has = true
		_wp_x = float(n["x"])
		_wp_y = float(n["y"])
		_wp_z = float(n["z"])
		_wp_kind = String(n.get("kind", "room"))
		_wp_node = n
		return
	if chasing:
		_wp_has = true
		_wp_x = goal.x
		_wp_y = goal.y
		_wp_z = goal.z
		_wp_kind = "point"
		_wp_node = null
		return
	_wp_has = false
	_wp_node = null


# Дошёл ли. Радиус мал (0.28 в проёме, 0.55 в комнате), и одного его мало:
# скольжение вдоль стены уводит в сторону, узел остаётся позади в тридцати
# сантиметрах мимо радиуса, и дед нарезает вокруг него круги. Поэтому вторая
# проверка — проекция на отрезок: если он уже за плоскостью узла, узел взят.
func _reached() -> bool:
	# Точку ломаной берём в трёх измерениях и вплотную: на площадке лестницы
	# соседние точки стоят в полуметре, и радиус комнаты съел бы их разом
	# вместе с поворотом.
	if _wp_kind == "link":
		return Vector3(_wp_x - _px, _wp_y - _py, _wp_z - _pz).length() <= REACH_LINK
	var rad := REACH_DOOR if _wp_kind == "door" else REACH_ROOM
	var d := _hyp(_wp_x - _px, _wp_z - _pz)
	if d <= rad:
		return true
	var ax := _wp_x - leg_x
	var az := _wp_z - leg_z
	var seg2 := ax * ax + az * az
	if seg2 < 1e-4:
		return true
	var t := ((_px - leg_x) * ax + (_pz - leg_z) * az) / seg2
	return t >= 1.0 and d <= rad + REACH_PASS


func _advance() -> void:
	leg_x = _wp_x
	leg_z = _wp_z
	cut_tries = 0
	if path_at >= 0 and path_at < path.size():
		path_at += 1
		if path_at >= path.size() and not chasing:
			# Дневка: постоял на месте, посмотрел. Детектор застревания её не
			# считает застреванием — она ставит moving = false явным образом.
			path = []
			path_at = 0
			idle = IDLE_MIN + rng.randf() * (IDLE_MAX - IDLE_MIN)
		return
	# Дошёл до самой точки шума и ничего там не нашёл: шум снимается,
	# дальше по кольцу.
	if noise != null:
		noise = null
		noise_timer = 0.0


# Срезание угла: раз в 0.2 с, максимум на один узел за раз и не больше трёх
# попыток на отрезок (иначе сэмплирование коридора стоит дороже самой ходьбы).
# Через дверные узлы не срезается никогда — ни от двери, ни к двери: створ 0.70
# при капсуле 0.64 проходится только строго по оси, а подход по диагонали
# кончается упором в косяк.
func _cut(dt: float) -> void:
	cut_in -= dt
	if cut_off > 0.0 or cut_in > 0.0:
		return
	cut_in = CUT_EVERY
	if cut_tries >= CUT_TRIES:
		return

	if path_at + 1 >= path.size():
		return
	var a: Dictionary = path[path_at]
	var b: Dictionary = path[path_at + 1]
	if String(a.get("kind", "room")) == "door" or String(b.get("kind", "room")) == "door":
		return
	if _hyp(float(b["x"]) - _px, float(b["z"]) - _pz) > CUT_MAX:
		return

	cut_tries += 1
	if not _corridor(float(b["x"]), float(b["z"])):
		return
	path_at += 1
	leg_x = _px
	leg_z = _pz


# Коридор среза. Пол проверяется вместе с пробой (см. _free): над проёмом
# лестницы на мансарде и над люком на чердаке пусто во все стороны, и срез
# через эту дыру прошёл бы капсулой целиком — дед пошёл бы по воздуху.
func _corridor(x1: float, z1: float) -> bool:
	var dx := x1 - _px
	var dz := z1 - _pz
	var l := _hyp(dx, dz)
	var n := maxi(1, int(ceil(l / CUT_STEP)))
	for i in range(1, n + 1):
		var t := float(i) / float(n)
		if not _free(_px + dx * t, _py, _pz + dz * t):
			return false
	return true


# ================= движение =================

func _move(dt: float, feet: Vector3) -> bool:
	if door_wait > 0.0 or idle > 0.0:
		return false
	# Срезание углов на ломаной перехода выключено намертво: срез через марш
	# лестницы — это срез сквозь перекрытие.
	if _trav.is_empty():
		_cut(dt)
	_waypoint()
	if not _wp_has:
		_speed_now = move_toward(_speed_now, 0.0, DECEL * dt)
		return false

	# Дверь. При планировании закрытая дверь дорожает вчетверо (вес ребра),
	# а не исчезает: обойти можно, если обход не длиннее. При исполнении —
	# берётся за ручку за метр, зовёт set_door один раз (второго не будет:
	# после открытия _door_open вернёт true) и стоит 0.85 с. Скрип и поворот
	# полотна делает сам ctx.setDoor. Закрывать за собой — не в этой итерации.
	if _wp_kind == "door" and _wp_node != null:
		var dn: Dictionary = _wp_node
		var bid := _blocker_id(dn)
		if bid != "" and not _door_open(dn):
			if _hyp(_wp_x - _px, _wp_z - _pz) < DOOR_REACH:
				_cx_call("setDoor", [bid, true])
				door_wait = DOOR_WAIT
				return false

	# Разгон к цели, а не подстановка. Тормозим у самого узла только если это
	# конец пути: на промежуточных узлах человек не притормаживает, он их
	# проходит.
	var want := _speed()
	if path_at >= path.size() - 1 and _hyp(_wp_x - _px, _wp_z - _pz) < 0.6:
		want = minf(want, SPEED_PATROL * 0.5)
	_speed_now = move_toward(_speed_now, want, (ACCEL if want > _speed_now else DECEL) * dt)
	var speed := _speed_now

	# Ломаная перехода идёт в трёх измерениях и без проб: по ней он спускается
	# в подпол и поднимается на чердак, а такого спуска ни одна проба «свободно
	# ли впереди» не одобрит — она смотрит вбок, а он идёт вниз.
	if _wp_kind == "link":
		var d3 := Vector3(_wp_x - _px, _wp_y - _py, _wp_z - _pz)
		var l3 := d3.length()
		if l3 > 1e-5:
			var go := minf(speed * dt, l3)
			var u := d3 / l3
			_px += u.x * go
			_py += u.y * go
			_pz += u.z * go
			_steps(_hyp(u.x * go, u.z * go), feet)
		if _reached():
			_advance()
			_traverse_after_step()
		return speed > 0.02

	var dx := _wp_x - _px
	var dz := _wp_z - _pz
	var dist := _hyp(dx, dz)
	if dist > 1e-4:
		dx /= dist
		dz /= dist
	else:
		dx = 0.0
		dz = 0.0

	# Боковая составляющая первой ступени детектора: строго перпендикулярно курсу.
	var vx := dx * speed
	var vz := dz * speed
	if _side_timer > 0.0:
		vx += -dz * speed * SIDE_MIX * _side_sign
		vz += dx * speed * SIDE_MIX * _side_sign

	var res := "BLOCKED"
	var v := _hyp(vx, vz)
	if v > 1e-4:
		var go := minf(v * dt, maxf(dist, 0.02))
		var px := _px
		var pz := _pz
		res = _step((vx / v) * go, (vz / v) * go)
		_steps(_hyp(_px - px, _pz - pz), feet)

	# Ноги переезжают на отметку следующего УЗЛА плавно. На участке узлы стоят
	# на разной высоте: земля 0.00, пол туалета 0.10, порог сарая 0.12 —
	# мгновенная посадка читалась бы как подскок на входе в сарай. По сырой
	# точке погони высоту не берём никогда: игрок на лестнице отдаёт свои
	# полтора метра, и дед поехал бы за ним вверх по воздуху.
	if _wp_node != null:
		var nd: Dictionary = _wp_node
		var dy := float(nd["y"]) - _py
		var lim := Y_RATE * dt
		_py += maxf(-lim, minf(lim, dy))

	if _reached():
		_advance()
		_traverse_after_step()
	return res == "MOVED" or res == "SLID"


# Шаги. Отсчёт по пройденному пути, а не по таймеру: упёршийся в шкаф дед
# больше не топает на месте, а шагает он ровно тем же шагом 0.76 м, каким
# считает фазу походка в actors.
func _steps(gone: float, feet: Vector3) -> void:
	walked += gone
	if walked < STEP_DIST:
		return
	walked = 0.0
	var near := _dist_to(feet)
	if near >= 12.0:
		return
	if absf(_py - feet.y) > 1.2:
		_audio_call("steps_above", [1])
	else:
		_audio_call("step", ["wood", false, true])


# Один шаг. Возвращает, что с ним случилось:
#   'PUSHED'  — стоял в стене после кривого телепорта, выдавлен наружу;
#   'MOVED'   — прошёл прямо;
#   'SLID'    — упёрся и поехал вдоль стены;
#   'BLOCKED' — не сдвинулся.
# BLOCKED НЕ меняет цель: упор кормит только детектор застревания. Порядок
# обязателен — депенетрация, шаг прямо, проекция шага на плоскость стены.
# Пол от стены отличаем тем же порогом |normal.y| < 0.5, что и audit-reach.
func _step(dx: float, dz: float) -> String:
	var y := _py

	# Депенетрация. В обычном кадре не выполняется вовсе: флаг ставит только
	# тот, кто двинул деда мимо шага — телепорт, респаун, глава.
	if _dirty:
		_dirty = false
		_credit = 0.0
		if not _free(_px, y, _pz):
			var hit := _hit(_px, y, _pz)
			if not hit.is_empty():
				var nrm: Vector3 = hit["normal"]
				var n := _hyp(nrm.x, nrm.z)
				if n > 1e-4:
					var push: float = float(hit["depth"]) + 0.02
					var qx := _px + (nrm.x / n) * push
					var qz := _pz + (nrm.z / n) * push
					if _free(qx, y, qz):
						_px = qx
						_pz = qz
						return "PUSHED"

	var l := _hyp(dx, dz)
	if l < 1e-6:
		return "MOVED"
	var ux := dx / l
	var uz := dz / l

	# Кредит хода: последняя проба смотрела на PROBE_AHEAD вперёд по этому же
	# курсу, и пока он не выбран, щупать нечего. Курс сменился больше чем
	# на 11° (косинус 0.98) — кредит недействителен.
	if _credit >= l and ux * _cred_x + uz * _cred_z > 0.98:
		_credit -= l
		_px += dx
		_pz += dz
		return "MOVED"

	var ax := _px + ux * (l + PROBE_AHEAD)
	var az := _pz + uz * (l + PROBE_AHEAD)
	if _free(ax, y, az):
		_px += dx
		_pz += dz
		_credit = PROBE_AHEAD
		_cred_x = ux
		_cred_z = uz
		return "MOVED"
	_credit = 0.0

	# Скольжение: из шага вычитается его составляющая по нормали стены.
	var hit2 := _hit(ax, y, az)
	if not hit2.is_empty():
		var nrm2: Vector3 = hit2["normal"]
		if absf(nrm2.y) < 0.5:
			var n2 := _hyp(nrm2.x, nrm2.z)
			if n2 > 1e-4:
				var nx := nrm2.x / n2
				var nz := nrm2.z / n2
				var into := dx * nx + dz * nz
				var sx := dx - nx * into
				var sz := dz - nz * into
				var sl := _hyp(sx, sz)
				if sl > 1e-4:
					var kx := sx / sl
					var kz := sz / sl
					if _free(_px + kx * (sl + PROBE_AHEAD), y, _pz + kz * (sl + PROBE_AHEAD)):
						_px += sx
						_pz += sz
						return "SLID"
	return "BLOCKED"


# Свободно ли. Проба идёт по ТРЁМ наборам (мир, обстановка, запертые двери) —
# этим занимается nav.probe, у него же верх капсулы по слоям.
#
# Пол проверяется отдельным лучом: проба смотрит вверх и вбок, а над проёмом
# лестницы пусто во все стороны, и без луча он уходил бы туда пешком.
func _free(x: float, y: float, z: float) -> bool:
	if nav == null:
		return true
	if not bool(nav.probe(layer, x, y, z, R)):
		return false
	return _floor_ok(x, y, z)


func _floor_ok(x: float, y: float, z: float) -> bool:
	if col == null:
		return true
	var hit := col.ray_down(x, y + 0.60, z, _floor_mask)
	if hit.is_empty():
		return false
	var nrm: Vector3 = hit["normal"]
	if absf(nrm.y) < 0.5:                       # грань стены, а не пол
		return false
	return absf(float(hit["y"]) - y) <= FLOOR_TOL


# Во что упёрлись: нормаль и глубина самого сильного попадания. Пороги те же,
# что в nav.js: касание глубже 0.02 мешает, попадание СНИЗУ глубиной до 0.20
# не мешает (порог сарая 0.12, крышка погреба 0.14, кромка ступени 0.178).
#
# Блокеры тут не смотрим намеренно. Запертость видит _free через nav.probe,
# а скользить вдоль закрытой двери ему негде: дверной узел он открывает
# за метр до себя, и до полотна дело не доходит.
func _hit(x: float, y: float, z: float) -> Dictionary:
	if col == null:
		return {}
	var top: float = PROBE_TOP.get(layer, PROBE_TOP["floor1"])
	var sy := y + R + 0.02
	var ey := y + top
	if ey < sy + 0.001:
		ey = sy + 0.001

	var worst: Dictionary = {}
	for mask: int in ([CollisionWorld.ALL_SOLID] if final_mode else [CollisionWorld.MASK_STATIC, CollisionWorld.MASK_PROPS]):
		var r := col.capsule_hit_d(x, sy, z, x, ey, z, R, mask)
		if r.is_empty():
			continue
		var depth: float = r["depth"]
		if depth <= TOUCH:
			continue
		if float(r["ny"]) > 0.5 and depth <= STEP_UP:
			continue
		if worst.is_empty() or depth > float(worst["depth"]):
			worst = r
	return worst


# Виден ли отрезок насквозь. Только статика: стёкол и силуэтов в ней нет.
func _visible(fx: float, fy: float, fz: float, tx: float, ty: float, tz: float) -> bool:
	if col == null:
		return true
	var dx := tx - fx
	var dy := ty - fy
	var dz := tz - fz
	var l := sqrt(dx * dx + dy * dy + dz * dz)
	if l < 1e-4:
		return true
	var t := ray_static(col, fx, fy, fz, dx / l, dy / l, dz / l, l)
	return t == INF or t > l - 0.15


# ================= застревание =================

# Кольцо из восьми отсчётов позиции через 0.25 с — окно ровно 2 с. Меряется
# смещение от самого старого отсчёта до текущего: и упор в стену, и круги
# вокруг проскочённого узла дают одинаково мало.
#
# Эскалация в три ступени, каждая следующая дороже предыдущей. Проверка после
# срабатывания откладывается на _stuck_wait, а кольцо за это время успевает
# перезаписаться целиком (8 x 0.25 = 2 с) — то есть третья ступень смотрит
# на движение уже после того, как отработала вторая.
func _stuck(dt: float, feet: Vector3) -> void:
	# Дневка, ожидание двери и фора — это не застревание, а стояние по делу.
	if idle > 0.0 or door_wait > 0.0 or grace > 0.0:
		_stuck_reset()
		return

	_stuck_wait -= dt
	_sample_in -= dt
	if _sample_in > 0.0:
		return
	_sample_in = SAMPLE_DT

	var i := _hist_at
	_hist[i * 2] = _px
	_hist[i * 2 + 1] = _pz
	_hist_at = (i + 1) % HIST
	if _hist_n < HIST:
		_hist_n += 1
		return
	if _stuck_wait > 0.0:
		return

	# Самый старый отсчёт — тот, который перезапишется следующим.
	var o := _hist_at
	var moved := _hyp(_px - _hist[o * 2], _pz - _hist[o * 2 + 1])
	if moved >= float(STUCK_NEED[_stage]):
		_stage = 0
		return

	_stage += 1
	if _stage == 1:
		# Первая ступень дешёвая: выключить срезание (чаще всего именно срез
		# и завёл в угол), перестроить путь и полторы секунды поджимать вбок.
		cut_off = CUT_BLOCK
		_side_timer = SIDE_TIME
		_side_sign = _free_side()
		_repath_now()
		_stuck_wait = 2.0
		return
	if _stage == 2:
		# Вторая: сбросить шум. Погоня за шумом, донёсшимся из-за стены, — самая
		# частая причина упора: цель по прямой в двух метрах, а идти к ней вокруг
		# дома. Дальше цель — ближайший дверной узел, из проёма выход есть всегда.
		noise = null
		noise_timer = 0.0
		_to_door()
		_stuck_wait = 3.0
		return
	# Третья: он больше не выберется сам.
	_escape(feet)
	_stage = 0
	_stuck_wait = 3.0
	_hist_n = 0


func _stuck_reset() -> void:
	_hist_n = 0
	_hist_at = 0
	_sample_in = SAMPLE_DT
	_stage = 0
	_stuck_wait = 0.0


# С какой стороны есть место. Две пробы, и только в момент застревания.
func _free_side() -> float:
	_waypoint()
	var dx := 0.0
	var dz := 1.0
	if _wp_has:
		var d := _hyp(_wp_x - _px, _wp_z - _pz)
		if d > 1e-3:
			dx = (_wp_x - _px) / d
			dz = (_wp_z - _pz) / d
	var off := 0.5
	if _free(_px - dz * off, _py, _pz + dx * off):
		return 1.0
	if _free(_px + dz * off, _py, _pz - dx * off):
		return -1.0
	return 1.0 if rng.randf() < 0.5 else -1.0


func _repath_now() -> void:
	if chasing:
		_repath(goal.x, goal.z)
	else:
		_clear_path()
		_next_patrol()
	repath_in = REPATH_CHASE


func _to_door() -> bool:
	var from := _nearest(layer, _px, _pz, "")
	var door := _nearest(layer, _px, _pz, "door")
	if from.is_empty() or door.is_empty():
		return false
	var p := _path(from, door)
	if p.is_empty():
		return false
	_set_path(p)
	# Держим эту цель две секунды: иначе следующее же перестроение погони
	# вернёт его в тот же угол, из которого он не вышел.
	repath_in = 2.0
	return true


# Последняя ступень: перенос на ближайший ВАЛИДНЫЙ узел дальше шести метров
# от игрока и вне его поля зрения. Слышно, что он куда-то ушёл, — и всё.
func _escape(feet: Vector3) -> bool:
	var player: Variant = _cx("controls")
	var yaw := float(player.yaw) if player != null else 0.0
	var fx := -sin(yaw)
	var fz := -cos(yaw)
	var best: Dictionary = {}
	var best_d := INF

	for n: Dictionary in _nodes(layer):
		if String(n.get("kind", "room")) != "room":
			continue
		var nx := float(n["x"])
		var ny := float(n["y"])
		var nz := float(n["z"])
		var far := _hyp(nx - feet.x, nz - feet.z)
		if far < ESCAPE_FAR:
			continue
		if not bool(nav.probe(layer, nx, ny, nz, R)):
			continue
		var dot := ((nx - feet.x) * fx + (nz - feet.z) * fz) / far
		if dot >= LOOK_DOT and _visible(feet.x, feet.y + 1.60, feet.z, nx, ny + 1.20, nz):
			continue
		var d := _hyp(nx - _px, nz - _pz)
		if d < best_d:
			best_d = d
			best = n
	if best.is_empty():
		if _debug():
			push_warning("ai: дед застрял и вылезти некуда %s" % [pos])
		return false

	if _debug():
		push_warning("ai: дед застрял на %s -> перенесён в %s" % [pos, best.get("id", "")])
	_teleport(float(best["x"]), float(best["y"]), float(best["z"]))
	_audio_call("steps_above", [2])
	return true


# Общая часть всех переносов: позиция, слой, путь, кольцо, депенетрация.
func _teleport(x: float, y: float, z: float) -> void:
	_px = x
	_py = y
	_pz = z
	layer = layer_of(y)
	_dirty = true
	_credit = 0.0
	walked = 0.0
	idle = 0.0
	door_wait = 0.0
	_side_timer = 0.0
	cut_off = 0.0
	# Любой перенос отменяет идущий переход: ломаная привязана к геометрии,
	# и продолжать её с другого этажа значит идти по воздуху.
	_trav = {}
	_speed_now = 0.0
	_turn_vel = 0.0
	_clear_path()
	_stuck_reset()
	_sync_patrol()


# ================= перенос на этаж игрока и респаун =================

# Отбор точки появления. Общий для переноса на этаж и для респауна после
# поимки, разница только в множителе порога пути.
#
# Отсевы жёсткие: проба пуста, по прямой не ближе 4.5 м, ДЛИНА ПУТИ ПО ГРАФУ
# не меньше MIN_PATH, другая комната, вне поля зрения. Пустой результат
# ослабляется строго по порядку — сначала «другая комната», потом MIN_PATH
# на 30 %, потом взгляд. И только если не осталось ни одного узла с пустой
# пробой, берётся самый дальний по прямой: первый попавшийся без проверок
# не берётся никогда, ровно из-за него дед и оказывался запертым в кладовке.
func _pick_spawn(feet: Vector3, yaw: float, lay: String, path_scale: float) -> Dictionary:
	if nav == null:
		return {}
	var list: Array = []
	for n: Dictionary in _nodes(lay):
		if String(n.get("kind", "room")) == "room":
			list.append(n)
	if list.is_empty():
		return {}

	# Откуда мерить путь — от комнатного узла, а не от любого: ближайшим
	# к игроку легко оказывается дверной, а у него имени комнаты нет вовсе,
	# и отсев «другая комната» тогда не отсеивает ничего.
	var here := _nearest(lay, feet.x, feet.z, "room")
	if here.is_empty():
		here = _nearest(lay, feet.x, feet.z, "")
	var home_place := _place_of(here) if not here.is_empty() else ""
	var base: float = MIN_PATH.get(lay, MIN_PATH["floor1"])
	var need := base * path_scale
	var fx := -sin(yaw)
	var fz := -cos(yaw)

	var cand: Array = []
	for n: Dictionary in list:
		var nx := float(n["x"])
		var ny := float(n["y"])
		var nz := float(n["z"])
		if not bool(nav.probe(lay, nx, ny, nz, R)):
			continue
		var straight := _hyp(nx - feet.x, nz - feet.z)
		var plen := straight
		if not here.is_empty():
			var p := _path(here, n)
			if p.is_empty():
				continue                    # до узла нет пути — там ему делать нечего
			plen = _path_length(p)
		var dot := 1.0
		if straight > 0.01:
			dot = ((nx - feet.x) * fx + (nz - feet.z) * fz) / straight
		var seen := dot >= LOOK_DOT and _visible(
			feet.x, feet.y + 1.60, feet.z, nx, ny + 1.20, nz)
		cand.append({
			"n": n, "straight": straight, "len": plen,
			"seen": seen, "place": _place_of(n)
		})
	if cand.is_empty():
		return {}

	for level in 3:
		var min_path := need * (1.0 if level < 1 else 0.7)
		var best: Dictionary = {}
		var best_score := -INF
		for cc: Dictionary in cand:
			var straight: float = cc["straight"]
			if straight < MIN_STRAIGHT:
				continue
			if level < 1 and home_place != "" and String(cc["place"]) == home_place:
				continue
			var plen: float = cc["len"]
			if plen < min_path:
				continue
			if level < 2 and bool(cc["seen"]):
				continue
			# Премируем узлы, до которых далеко ИДТИ при небольшой прямой: это
			# и есть «за углом, а не в другом конце участка».
			var score: float = plen + 2.0 * (plen / maxf(straight, 0.5))
			if score > best_score:
				best_score = score
				best = cc["n"]
		if not best.is_empty():
			return best

	var far: Dictionary = {}
	var far_d := -1.0
	for cc: Dictionary in cand:
		var straight: float = cc["straight"]
		if straight > far_d:
			far_d = straight
			far = cc["n"]
	return far


# Перенос на этаж игрока: за угол, вне поля зрения, без объяснений.
func _relocate(player_layer: String, player_pos: Vector3) -> void:
	if nav == null:
		return
	var player: Variant = _cx("controls")
	var yaw := float(player.yaw) if player != null else 0.0
	# Порог пути мягче респаунного: это не развод после поимки, а смена этажа,
	# и слишком строгий отбор оставлял бы его наверху всю главу.
	var node := _pick_spawn(player_pos, yaw, player_layer, 0.6)
	if node.is_empty():
		return
	_teleport(float(node["x"]), float(node["y"]), float(node["z"]))
	# Слышно, что он тут: шаг и скрип половицы.
	_audio_call("steps_above", [2])


# Респаун после поимки. Ставится на слой ИГРОКА и получает фору: 4.5 секунды
# он не ловит, не охотится, не слышит и не телепортируется, двенадцать — молчит.
# 4.5 с ходьбы — это семь метров поверх пути не меньше девяти: до контакта
# не меньше шестнадцати метров и двух поворотов.
func respawn(player_feet: Vector3, player_yaw: Variant = null) -> void:
	var yaw := 0.0
	if player_yaw == null:
		var player: Variant = _cx("controls")
		yaw = float(player.yaw) if player != null else 0.0
	else:
		yaw = float(player_yaw)
	var lay := layer_of(player_feet.y)
	var node: Dictionary = _pick_spawn(player_feet, yaw, lay, 1.0) if nav != null else {}

	if not node.is_empty():
		_teleport(float(node["x"]), float(node["y"]), float(node["z"]))
	else:
		# Ни одного узла с пустой пробой на слое игрока: остаёмся где стояли,
		# но путь и таймеры всё равно сбрасываем — иначе он побежит по старому.
		_teleport(_px, _py, _pz)
		if _debug():
			push_warning("ai: респаун не нашёл ни одной точки на слое %s" % lay)

	noise = null
	noise_timer = 0.0
	grace = GRACE
	mute = MUTE
	relocate_in = 6.0 + rng.randf() * 2.0
	line_timer = 12.0
	run_in = 0.0


# Развод после [R]. Без него откат возвращает игрока в начало главы, а деда
# оставляет там, где он его взял: в «ВОРОТАХ» это вплотную, и следующая поимка
# случается в том же кадре, в котором игрок возродился, — глава запирается
# насмерть.
#
# speed_scale не трогаем намеренно: замедление на десять процентов после трёх
# провалов должно переживать откат, иначе оно не наступит никогда.
func reset(player_feet: Vector3) -> void:
	var player: Variant = _cx("controls")
	var yaw := float(player.yaw) if player != null else 0.0
	respawn(player_feet, yaw)


# Полный сброс: новая игра и кнопка «Начать заново». Без него второе
# прохождение начиналось с дедом на скорости 0.9, стоящим там, где его
# бросило прошлое.
func hard_reset() -> void:
	end_final()
	speed_scale = 1.0
	noise = null
	noise_timer = 0.0
	grace = 0.0
	mute = 0.0
	relocate_in = 8.0
	line_timer = 12.0
	run_in = 0.0
	patrol_at = 0
	var m := _marks()
	_teleport(START_X, float(m["F2"]), START_Z)
	_actor_show(false)


func hardReset() -> void:
	hard_reset()


# «Поставить деда сюда». Главы двигали фигуру через actors.place('threat', ...),
# то есть АКТЁРА, а не деда: update переписывал позицию в том же кадре,
# и постановка была чисто декоративной.
func place_at(x: float, y: float, z: float) -> void:
	_teleport(x, y, z)
	_actor_place(x, y, z, 0.0)


# chapters.gd зовёт постановку именем оригинала — держим оба написания,
# чтобы склейка не зависела от того, кто как вспомнил.
func placeAt(x: float, y: float, z: float) -> void:
	place_at(x, y, z)


# ================= фигура, голос, поимка =================

func _render(dt: float, feet: Vector3, moving: bool, player_layer: String) -> void:
	var g := _actor_fig()
	# Курс отдаём тот, что уже есть у фигуры. place() без четвёртого аргумента
	# ставит его в ноль — фигура каждый кадр смотрела бы на север, а face_to
	# доворачивал бы её от нуля на 3.2 * dt и никуда не доворачивал.
	_actor_place(_px, _py, _pz, g.rotation.y if g != null else 0.0)
	_actor_show(true)

	_waypoint()
	if _wp_has:
		_actor_face_to(_wp_x, _wp_z, dt, _turn_rate(g, dt))
	else:
		_turn_vel = move_toward(_turn_vel, 0.0, TURN_ACCEL * dt)

	# Сутулость под балками. Просвет подпола 1.90, чердака 1.85: в покое верх
	# кепки на 1.729, с добавкой 0.22 — на 1.704. Мансарда с её 2.35 полная,
	# там он выпрямляется.
	var stoop := STOOP_LOW if (layer == "cellar" or layer == "roof") else 0.0
	var near := player_layer == layer and _hyp(feet.x - _px, feet.z - _pz) < LOOK_NEAR

	var look: Variant = null
	# Во время форы голову на игрока не наводим: он его пока не ищет.
	if grace <= 0.0 and near:
		look = [feet.x, feet.z]
	# lookAt продублирован как look_at: словарь читает actors.gd (фаза 3), а он
	# портируется с оригинала — пусть найдёт ключ под любым написанием.
	# Скорость отдаём НАСТОЯЩУЮ, с инерцией: походка считает по ней длину шага,
	# и на разгоне шаги обязаны быть короче. idle — «стоит и переминается»:
	# дневка и ожидание двери перестают быть стоп-кадром, оставаясь при этом
	# ровно той же длины, так что audit_nav их не замечает.
	_actor_walk(dt, {
		"speed": _speed_now if moving else 0.0,
		"moving": moving,
		"idle": 1.0 if (idle > 0.0 or door_wait > 0.0 or not moving) else 0.0,
		"stoop": stoop,
		"lookAt": look,
		"look_at": look,
	})


# Рулёжка. 3.2 рад/с при 1.18 м/с — радиус поворота 0.37 м, в проём 0.9
# вписывается с запасом. 6.0 в дверях и на развороте больше 137°: там фигура
# обязана успеть повернуться за полшага, иначе она идёт боком.
#
# С фазы 7 это потолки, а не постоянные: угловая скорость разгоняется к потолку
# и гасится по остатку угла. Голова перестаёт дёргаться на каждом узле пути —
# именно эта дёрганность и читалась как «заводной».
func _turn_rate(g: Node3D, dt: float) -> float:
	var cap := TURN_FAST if _wp_kind == "door" else TURN_RATE
	var diff := PI
	if g != null:
		var want := atan2(_wp_x - _px, _wp_z - _pz) + PI
		diff = want - g.rotation.y
		while diff > PI:
			diff -= 2.0 * PI
		while diff < -PI:
			diff += 2.0 * PI
		diff = absf(diff)
		if diff > TURN_HARD:
			cap = TURN_FAST
	# Чем меньше осталось довернуть, тем медленнее: без этого фигура доезжает
	# до курса на полной угловой и встаёт как отрубленная.
	var target := minf(cap, diff * TURN_EASE)
	_turn_vel = move_toward(_turn_vel, target, TURN_ACCEL * dt)
	return maxf(_turn_vel, TURN_MIN)


# Реплики из темноты. Он зовёт игрока по имени и тем же ритмом, каким Сергей
# звал его самого с участка. Это страшнее, чем если бы он звал кого-то
# постороннего: значит, он знает, кто в доме.
func _voice(dt: float, feet: Vector3) -> void:
	line_timer -= dt
	if line_timer > 0.0:
		return
	# Пока он молчит после поимки, реплику не жжём впустую, а откладываем ровно
	# до конца молчания: возвращение голоса и есть сигнал «фора кончилась».
	if mute > 0.0:
		line_timer = mute
		return

	# Темп задаёт озвучка: с ней дед бормочет раз в 5–7 секунд (voice.next_gap),
	# без неё интервал ровно прежний — фаза 4 звучит как принята. Правило отката
	# держится здесь и только здесь: одна ветка на два мира.
	var voice: Variant = _cx("voice")
	var voiced := voice != null and bool(voice.enabled)
	line_timer = voice.next_gap() if voiced else (22.0 + rng.randf() * 26.0)
	var near := _dist_to(feet)
	if near >= 16.0:
		return
	if _lines.is_empty():
		return
	# Записанный голос (фаза 5) сам выбирает реплику и сам ставит субтитр:
	# разведи их по двум местам — рано или поздно они разъедутся.
	if voiced:
		if bool(voice.say_vitya(near, absf(_py - feet.y))):
			return
		# Уступил телефону или кассете. Реплику не теряем и пробуем снова через
		# шесть секунд — при темпе фазы 6 это тот же слот, но число оставлено
		# явным: оно страхует и на случай, если темп когда-нибудь замедлят.
		line_timer = 6.0
		return

	var line := String(_lines[rng.randi_range(0, _lines.size() - 1)])
	_audio_call("mumble", [1.3])
	var ui: Variant = _cx("ui")
	if ui != null:
		ui.say(line, 3.6)


func _catch(st: Variant, feet: Vector3) -> void:
	if st == null:
		return
	if bool(st.get("hidden")) or grace > 0.0:
		return
	var d := _dist_to(feet)
	if d >= CATCH_DIST or absf(_py - feet.y) > 1.2:
		return
	# Луч на высоте груди и ТОЛЬКО здесь, при d < 1.15, — то есть почти никогда.
	# Закрывает поимку сквозь перегородку ниши, сквозь дверь умывальной
	# и вообще сквозь любую стену.
	if not _visible(_px, _py + 1.20, _pz, feet.x, feet.y + 1.20, feet.z):
		return
	# Синхронный обработчик может уже запустить перенос и владение фигурой.
	# Источник снимаем до emit, и после него состояние больше не меняем.
	var context: Variant = c
	if context is Dictionary:
		context["catch_source"] = {"actor": "threat", "pos": Vector3(_px, _py, _pz)}
		context["catch_previous_threat"] = String(st.get("threatState"))
	st.set("threatState", "absent")
	_cx_call("emit", ["caught"])


# ================= финальная погоня (фаза 15) =================
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ РЕЖИМ. Весь остальной ai.gd ходит по навграфу, а граф
# кончается на границе участка: улицы в нём нет вовсе (она оверлей фазы 9),
# поэтому дед физически не мог выйти за ворота — и финал, в котором он гонится
# до машины, был невозможен не по замыслу, а по устройству. Здесь он идёт
# ПРЯМО на игрока и обходит то, во что упёрся, пробой — тем же _step(),
# которым ходит везде, только цель ему даёт не путь, а сам игрок.
#
# ЧТО ОСТАЁТСЯ ОБЩИМ. Поимка (_catch), голос (_voice), шаги (_steps)
# и отрисовка (_render) — всё то же самое. Режим меняет ровно способ выбирать,
# куда сделать следующий шаг.

## Начать погоню. away_from — точка, ОТ которой отсчитывается сторона: дед
## встаёт с противоположной от неё стороны игрока, чтобы не оказаться между
## игроком и машиной. Возвращает, удалось ли найти свободное место.
func begin_final(player_feet: Vector3, away_from: Vector3, distance := FINAL_DIST) -> bool:
	var dx := player_feet.x - away_from.x
	var dz := player_feet.z - away_from.z
	var l := _hyp(dx, dz)
	if l < 1e-4:
		dx = 0.0
		dz = 1.0
	else:
		dx /= l
		dz /= l

	_floor_mask = CollisionWorld.MASK_STATIC | CollisionWorld.MASK_OVERLAY
	# Веер: сначала точно за спиной, потом всё шире и ближе. Перебор
	# детерминированный — погоня обязана начинаться одинаково.
	#
	# ЛУЧ ОБЯЗАТЕЛЕН, И ЭТО ГЛАВНОЕ В ОТБОРЕ. Точка «двенадцать метров за
	# спиной» от ворот приходится ровно на середину дома: место свободное
	# (там комната), но между ним и игроком стена, и дед всю погоню тёрся бы
	# об неё, оставаясь на месте. Луч отсекает такие точки целиком, и заодно
	# отвечает на вопрос, откуда он появится: оттуда, откуда его будет видно.
	var found := false
	var fallback := Vector3.ZERO
	var has_fallback := false
	for ring: float in [1.0, 0.85, 0.7, 0.55]:
		var d: float = distance * ring
		for turn: float in [0.0, 0.35, -0.35, 0.7, -0.7, 1.15, -1.15, 1.6, -1.6,
				2.1, -2.1]:
			var c := cos(turn)
			var sn := sin(turn)
			var x := player_feet.x + (dx * c - dz * sn) * d
			var z := player_feet.z + (dx * sn + dz * c) * d
			var y := _ground_at(x, z, player_feet.y)
			if not _free(x, y, z):
				continue
			if not has_fallback:
				fallback = Vector3(x, y, z)
				has_fallback = true
			if not _visible(x, y + 1.20, z,
					player_feet.x, player_feet.y + 1.20, player_feet.z):
				continue
			_teleport(x, y, z)
			found = true
			break
		if found:
			break
	# Ни одной точки с прямой видимостью не нашлось — берём первую свободную.
	# Это хуже (он выйдет из-за угла), но лучше, чем не выйти вовсе.
	if not found and has_fallback:
		_teleport(fallback.x, fallback.y, fallback.z)
		found = true
	if not found:
		_floor_mask = CollisionWorld.MASK_STATIC
		push_warning("ai: погоне негде начаться — свободной точки в %.1f м нет" % distance)
		return false

	final_mode = true
	chasing = true
	grace = 0.0
	mute = 0.0
	idle = 0.0
	door_wait = 0.0
	_final_side = 0.0
	return true


## Выйти из режима: концовка, титры, откат по [R].
func end_final() -> void:
	final_mode = false
	chasing = false
	_final_side = 0.0
	_floor_mask = CollisionWorld.MASK_STATIC


## Отметка земли под точкой. Узлов графа здесь нет, брать высоту неоткуда,
## кроме луча; не нашёл — остаётся та, что была.
func _ground_at(x: float, z: float, fallback: float) -> float:
	if col == null:
		return fallback
	var hit := col.ray_down(x, fallback + 1.6, z, _floor_mask)
	return fallback if hit.is_empty() else float(hit["y"])


func _chase(dt: float, feet: Vector3) -> bool:
	# Цель — сам игрок, каждый кадр. path пуст намеренно: _waypoint() в этом
	# случае отдаёт goal, и фигура доворачивается на игрока тем же кодом,
	# которым доворачивается на узел пути.
	goal = Vector3(feet.x, feet.y, feet.z)
	path = []
	path_at = 0
	_waypoint()

	var want := SPEED_FINAL * speed_scale
	_speed_now = move_toward(_speed_now, want,
		(ACCEL if want > _speed_now else DECEL) * dt)
	var speed := _speed_now

	var dx := feet.x - _px
	var dz := feet.z - _pz
	var dist := _hyp(dx, dz)
	if dist < 1e-4:
		return false
	dx /= dist
	dz /= dist

	# Обход. _step() сам скользит вдоль стены; когда и скольжение не проходит,
	# добавляется поперечная составляющая — та же первая ступень, которой
	# обходит препятствие патруль, только здесь она включается сразу и держится
	# FINAL_SIDE секунд: за это время угол дома успевает кончиться.
	var vx := dx * speed
	var vz := dz * speed
	if _final_side > 0.0:
		_final_side -= dt
		vx += -dz * speed * SIDE_MIX * _final_sign
		vz += dx * speed * SIDE_MIX * _final_sign

	var res := "BLOCKED"
	var v := _hyp(vx, vz)
	if v > 1e-4:
		var go := minf(v * dt, maxf(dist, 0.02))
		var px := _px
		var pz := _pz
		res = _step((vx / v) * go, (vz / v) * go)
		_steps(_hyp(_px - px, _pz - pz), feet)
	if res == "BLOCKED" and _final_side <= 0.0:
		_final_side = FINAL_SIDE
		_final_sign = _free_side()

	# Ноги едут на землю под собой, а не на отметку узла: узлов здесь нет.
	var gy := _ground_at(_px, _pz, _py)
	var lim := Y_RATE * dt
	_py += maxf(-lim, minf(lim, gy - _py))
	layer = layer_of(_py)
	return res == "MOVED" or res == "SLID"


# ================= навграф: тонкая обёртка =================

# nav_graph отдаёт узлы словарями и сам умеет всё, что звал оригинал:
# nearest/pathTo/pathLength/doorOpen. Здесь только переходники — на случай,
# когда графа нет вовсе (тогда дед стоит, а не падает).
func _nodes(lay: String) -> Array:
	return nav.nodes(lay) if nav != null else []


# nearest графа принимает Vector3 и словарь опций; kind == "" значит «любой».
func _nearest(lay: String, x: float, z: float, kind: String) -> Dictionary:
	if nav == null:
		return {}
	var opts: Dictionary = {}
	if kind != "":
		opts["kind"] = kind
	var n: Variant = nav.nearest(lay, Vector3(x, 0.0, z), opts)
	if not (n is Dictionary):
		return {}
	var found: Dictionary = n
	return found


func _path(a: Dictionary, b: Dictionary) -> Array:
	if nav == null or a.is_empty() or b.is_empty():
		return []
	return nav.path_between(a, b)


func _patrol_ring(lay: String) -> Array:
	return nav.patrol(lay) if nav != null else []


func _path_length(p: Array) -> float:
	return nav.path_length(p) if nav != null else 0.0


func _blocker_id(n: Dictionary) -> String:
	var v: Variant = n.get("blockerId", null)
	return "" if v == null else String(v)


# Открыта ли дверь узла. Проём без полотна открыт всегда; запертость живёт
# в активности блокера, а не в графе, — читается живьём.
func _door_open(n: Dictionary) -> bool:
	if String(n.get("kind", "room")) != "door":
		return true
	if nav != null:
		return nav.door_open(n)
	var bid := _blocker_id(n)
	if bid == "" or col == null:
		return true
	return not col.is_blocker_active(bid)


# ================= утилиты =================

# Плоский слепок статики: шесть чисел на коробку. box_aabb_d() отдаёт новый
# PackedFloat64Array на каждую из трёхсот коробок, а лучом стреляют и дед,
# и двойник, и interact — каждый кадр. Набор статики строится один раз
# на загрузке, поэтому слепок снимается один раз на мир и лежит в кэше;
# сверка по числу коробок ловит пересборку (в тестах миров несколько).
static var _boxes_cache: Dictionary = {}

static func static_boxes(cw: CollisionWorld) -> PackedFloat64Array:
	if cw == null:
		return PackedFloat64Array()
	var key := cw.get_instance_id()
	var count := cw.box_count(CollisionWorld.SET_STATIC)
	var got: Variant = _boxes_cache.get(key, null)
	if got is PackedFloat64Array:
		var cached: PackedFloat64Array = got
		if cached.size() == count * 6:
			return cached
	var out := PackedFloat64Array()
	out.resize(count * 6)
	for i in count:
		var b := cw.box_aabb_d(CollisionWorld.SET_STATIC, i)
		if b.size() < 6:
			continue
		for k in 6:
			out[i * 6 + k] = b[k]
	_boxes_cache[key] = out
	return out


# Луч по статике. CollisionWorld умеет только ray_down, а «видно ли насквозь»
# нужно в произвольном направлении: считаем плитами по коробкам набора.
# Изнутри коробки пусто (t_near < 0 отбрасывается) — та же семантика,
# что у ray_down и у октодерева с backfaceCulling. INF = не попали ни во что.
static func ray_boxes(boxes: PackedFloat64Array, ox: float, oy: float, oz: float,
		dx: float, dy: float, dz: float, max_len: float) -> float:
	var best := INF
	var n := boxes.size() / 6
	for i in n:
		var o := i * 6
		var t_near := -INF
		var t_far := INF
		var ok := true
		for a in 3:
			var org := ox
			var dir := dx
			if a == 1:
				org = oy
				dir = dy
			elif a == 2:
				org = oz
				dir = dz
			var lo: float = boxes[o + a]
			var hi: float = boxes[o + 3 + a]
			if absf(dir) < 1e-12:
				if org < lo or org > hi:
					ok = false
					break
				continue
			var inv := 1.0 / dir
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


# Тем же лучом «видно ли» пользуется interact.gd — имя и сигнатура публичные.
static func ray_static(cw: CollisionWorld, ox: float, oy: float, oz: float,
		dx: float, dy: float, dz: float, max_len: float) -> float:
	return ray_boxes(static_boxes(cw), ox, oy, oz, dx, dy, dz, max_len)


func _hyp(a: float, b: float) -> float:
	return sqrt(a * a + b * b)


func _dist_to(p: Vector3) -> float:
	var dx := _px - p.x
	var dy := _py - p.y
	var dz := _pz - p.z
	return sqrt(dx * dx + dy * dy + dz * dz)


func _cx(key: String) -> Variant:
	if c is Dictionary:
		var d: Dictionary = c
		return d.get(key, null)
	if c == null:
		return null
	return c.get(key)


func _cx_call(key: String, args: Array) -> void:
	var f: Variant = _cx(key)
	if not (f is Callable):
		return
	var cb: Callable = f
	if cb.is_valid():
		cb.callv(args)


func _audio_call(method: String, args: Array) -> void:
	var a: Variant = _cx("audio")
	if a != null and a.has_method(method):
		a.callv(method, args)


func _threat_state() -> String:
	return _state_str(_cx("state"))


# Имена полей состояния — как в оригинале (state.gd их не переименовывал):
# threatState, atLeast. Разводить их со state.gd нельзя ни на одну букву.
func _state_str(st: Variant) -> String:
	if st == null:
		return "absent"
	var v: Variant = st.get("threatState")
	return "absent" if v == null else String(v)


func _at_least(st: Variant, chapter: String) -> bool:
	if st == null:
		return false
	return bool(st.atLeast(chapter))


func _debug() -> bool:
	var d: Variant = _cx("debug")
	return d != null and bool(d)


# ---------- актёр ----------
# Имена place/face_to/walk_anim берём из оригинала. get и show в GDScript заняты
# Object/Node3D, поэтому у actors.gd они называются иначе — ищем по нескольким
# именам, чтобы ai.gd не падал, пока фаза 3 не приехала.

func _actor_fig() -> Node3D:
	if actors == null:
		return null
	for m: String in ["get_actor", "figure", "get_figure"]:
		if actors.has_method(m):
			var g: Variant = actors.call(m, "threat")
			return g as Node3D
	return null


func _actor_show(on: bool) -> void:
	if actors == null:
		return
	if actors.has_method("show_actor"):
		actors.show_actor("threat", on)
	elif actors.has_method("set_shown"):
		actors.set_shown("threat", on)


func _actor_place(x: float, y: float, z: float, yaw: float) -> void:
	if actors != null and actors.has_method("place"):
		actors.place("threat", x, y, z, yaw)


func _actor_face_to(x: float, z: float, dt: float, rate: float) -> void:
	if actors == null:
		return
	for m: String in ["face_to", "faceTo"]:
		if actors.has_method(m):
			actors.call(m, "threat", x, z, dt, rate)
			return


func _actor_walk(dt: float, opts: Dictionary) -> void:
	if actors == null:
		return
	for m: String in ["walk_anim", "walkAnim"]:
		if actors.has_method(m):
			actors.call(m, "threat", dt, opts)
			return

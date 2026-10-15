# Дед на линии: ходит, смотрит, замечает и идёт (раунд 10).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ai.gd. Настоящая охота живёт в ai.gd, считается
# по нав-графу и заморожена вместе с ним: улицы в графе нет и не будет
# (nav.json держит street в banRooms, слоёв пять и уличного среди них нет).
# Здесь другое — сорок метров прямой дороги, на которой обходить нечего.
# Полсотни строк своей логики честнее, чем попытка завести улицу в граф.
#
# ПРАВИЛО СЦЕНЫ ГОВОРИТ САМ АРКАДИЙ, за десять минут до этого:
#
#     — Иди уже. Только обочиной иди, не серединой.
#     — А это тут при чём.
#     — По середине тебя видно.
#
# Это и есть вся механика. Он идёт по середине гравийки и смотрит вдоль неё,
# поводя головой. Кто идёт краем — у забора или под самыми домами — тот в тумане
# и его не видно. Кто пошёл серединой — тот в полосе, и дальше зависит только
# от того, попал он в конус взгляда или нет.
#
# ПОЧЕМУ ОН СТАЛ ХОДИТЬ. Прежде он выходил один раз, вставал на (-6.4, 0, -3.2)
# и стоял там до конца главы. Постановочная фигура пугает ровно один раз, и
# после первого «а, он не двигается» дорога к бочке становится пустым коридором.
# Ходящий и смотрящий превращает те же сорок метров в единственный отрезок игры,
# который надо ПРОЙТИ, а не пробежать.
#
# ЧЕГО ЗДЕСЬ НЕТ. Он не открывает двери, не заходит на участок, не ищет игрока
# по дому и не помнит, где тот прятался: у него нет ни графа, ни памяти. Потерял
# из виду — вернулся на середину и пошёл дальше. Дистанция и конус, больше ничего.

class_name StreetStalk
extends RefCounted

# Полоса, по которой он ходит. z середины гравийки: сама гравийка z [-6.4, 0],
# трава-обочина дальше -6.4, забор участка ближе 0.
const LANE_Z := -3.2
const LANE_HALF := 2.30           # шире этого от середины — уже край, и не видно
const WEST := -11.0               # разворот у заколоченного дома
const EAST := 3.0                 # разворот у своих ворот

# ГЛАВА ДЕРЕВНЯ (фаза 12). Отрезок тот же по правилам и втрое длиннее: от
# колодца до сельпо. Числа не «побольше», а по делу — за них держится
# tests/test_street_clear.gd, который требует, чтобы в полосе на этом
# промежутке не стояло ни одной коробки деревни.
const WEST_V := -30.0
const EAST_V := 26.0

const WALK := 0.95
const HUNT := 2.35                # игрок идёт 1.55 и бежит 3.05: уйти можно бегом
# В деревне он медленнее, и это не поблажка. На сорока метрах УЛИЦЫ игрок
# видит его целиком и решает один раз; на пятидесяти шести от колодца до сельпо
# та же скорость означала бы, что решать приходится непрерывно и всю дорогу,
# а это уже не страх, а бег с препятствиями.
const WALK_V := 0.72
const HUNT_V := 2.05
const TURN := 2.6
const PAUSE := 1.4                # стоит и смотрит на развороте

# Взгляд. Он поводит головой, а не идёт с застывшим лицом: SWEEP — половина
# размаха в радианах, SWEEP_RATE — как быстро.
const SWEEP := 0.62
const SWEEP_RATE := 0.55
const VIEW_COS := 0.42            # ~65 градусов полураствора

const SEE_FAR := 15.0
const SEE_LAMP := 1.45            # фонарь в лицо — видит настолько дальше
const NOSE := 2.6                 # в упор видит всегда, хоть краем, хоть как
const LOSE := 3.0                 # столько не видит — и возвращается на линию
const CATCH := 1.15
# Высота груди: отсюда стреляет луч видимости и сюда же целится.
const CHEST := 1.35
# Разница высот, после которой игрок для него в другой комнате: второй этаж
# красного дома, подпол, чердак. Полметра — это ступенька крыльца, а не этаж.
const SAME_FLOOR := 0.55

var c: Dictionary = {}
var state := "off"                # off | walk | hunt | gone

var _pos := Vector2(EAST, LANE_Z)
var _dir := -1.0                  # -1 на запад, +1 на восток
var _yaw := PI * 0.5
var _sweep := 0.0
var _wait := 0.0
var _lost := 0.0
var _caught := false
# Широкий отрезок главы ДЕРЕВНЯ. Поле, а не отдельный класс: правила сцены
# от него не меняются вовсе, меняются два числа и границы разворота.
var _wide := false
var _rng := RandomNumberGenerator.new()
# Габариты всех четырёх наборов коллизий одним массивом, для луча видимости.
# Пересобирается, только если число коробок изменилось (см. _solid_boxes).
var _boxes := PackedFloat64Array()


func _init(ctx: Dictionary, rng_seed := 0) -> void:
	c = ctx
	_rng.seed = rng_seed


## Вывести его на линию. Идемпотентно ПО МЕСТУ, но не по видимости: второй
## вызов ничего не переставляет — [R] после поимки проходит через
## _street_enter, и там он зовётся заново, — а вот фигуру показывает заново.
##
## ФАЗА 18. Раньше повторный вызов выходил первой строкой молча, и это было
## неправдой: [R] идёт через СИНХРОННЫЙ resetThreat (chapters.retry), а
## enter() главы отложен карточкой (chapters.go), то есть между ними успевает
## пройти haunt.reset() с безусловным actors.show('echo', false). Дед
## оставался на линии, ловил и был невидим.
## wide — широкий отрезок главы ДЕРЕВНЯ.
func begin(wide := false) -> void:
	if active():
		_show()
		return
	state = "walk"
	_wide = wide
	_caught = false
	_lost = 0.0
	_wait = 0.0
	# Он всегда встаёт между игроком и бочкой: выйти западнее игрока значит
	# отдать ему всю дорогу, а восточнее — запереть его на участке.
	var feet := _feet()
	_pos = Vector2(clampf(feet.x - 7.0, _west(), _east()), LANE_Z)
	_dir = -1.0
	_yaw = _dir_yaw()
	# ПОРЯДОК ЗДЕСЬ — ЭТО ВЕСЬ БАГ ФАЗЫ 17. Двойника занимаем ДО того, как
	# показать: holdEcho идёт в main._ctx_hold_echo -> startle.clear() ->
	# startle._hide() -> actors.show('echo', false), и при обратном порядке
	# фигура гасла в том же кадре, в котором создана. Комментарий в main.gd
	# требует ровно этого («Вызывать ДО actors.show('echo', true)»), а
	# street_stalk его нарушал с раунда 10.
	_hold(600.0)
	_show()


## Убрать его с линии. Зовётся, когда бак залит: дальше улица пустая.
func finish() -> void:
	if state == "off" or state == "gone":
		state = "gone"
		return
	state = "gone"
	# Поимка или другая постановка могла уже забрать того же двойника.
	# Завершение патруля освобождает только его собственную сцену.
	var director: Variant = c.get("horror")
	if director != null and String(director.owner) not in ["", "stalk"]:
		return
	var actors: Variant = c.get("actors")
	if actors != null:
		actors.show("echo", false)
	_hold(0.0)


func active() -> bool:
	return state == "walk" or state == "hunt"


## Где он сейчас. Спрашивают тесты и отладка.
func pos() -> Vector3:
	return Vector3(_pos.x, 0.0, _pos.y)


# ---------------------------------------------------------------- кадр ------

func update(dt: float) -> void:
	if not active():
		return
	var feet := _feet()
	var sees := _sees(feet)

	if state == "walk":
		if sees:
			_spot()
		else:
			_walk(dt)
	else:
		# Потеря считается по времени, а не по кадру: шаг за столб, за который
		# его не видно полкадра, не должен обрывать погоню.
		_lost = 0.0 if sees else _lost + dt
		if _lost >= LOSE:
			_give_up()
		else:
			_hunt(dt, feet)

	if not active():
		return
	_apply(dt, feet)


# ---------- патруль ----------

func _walk(dt: float) -> void:
	_sweep = fmod(_sweep + dt * SWEEP_RATE, TAU)
	if _wait > 0.0:
		_wait -= dt
		return
	_pos.x += _dir * (WALK_V if _wide else WALK) * dt
	if _pos.x <= _west() or _pos.x >= _east():
		_pos.x = clampf(_pos.x, _west(), _east())
		_dir = -_dir
		_wait = PAUSE
	_pos.y = LANE_Z


func _west() -> float:
	return WEST_V if _wide else WEST


func _east() -> float:
	return EAST_V if _wide else EAST


# ---------- погоня ----------

func _spot() -> void:
	state = "hunt"
	_lost = 0.0
	_say("oldManSpotted", 2.6)
	var audio: Variant = c.get("audio")
	if audio != null:
		audio.heartbeat(6, 104)
	_emit("street-spotted")


func _give_up() -> void:
	state = "walk"
	_lost = 0.0
	_wait = PAUSE
	_say("oldManLost", 2.4)
	_emit("street-lost")


func _hunt(dt: float, feet: Vector3) -> void:
	var to := Vector2(feet.x, feet.z) - _pos
	var ln := to.length()
	if ln <= CATCH:
		_catch()
		return
	var speed := HUNT_V if _wide else HUNT
	var step := to / maxf(ln, 0.001) * minf(ln, speed * dt)
	# ФАЗА 18. Он больше не проходит сквозь заборы. На сорока метрах УЛИЦЫ
	# это было незаметно — там на линии пусто, — а в деревне отрезок втрое
	# длиннее и поперёк него стоят ограды участков, ворота погоста и стена
	# сельпо. Дед шёл сквозь них по прямой, и уйти от него было нельзя
	# никуда, кроме как вдоль.
	#
	# Графа у него нет и не будет (см. шапку файла), поэтому обход самый
	# простой из честных: не пускает прямо — пробуем порознь по осям.
	# Не вышло и так — стоит на месте, а LOSE обрывает погоню сам.
	_pos = _slide(step)
	_sweep = 0.0


## Куда он сможет шагнуть из текущей точки. Порядок проб: прямо, потом по x,
## потом по z — тот же, что у скольжения игрока вдоль стены.
func _slide(step: Vector2) -> Vector2:
	if _free(_pos + step):
		return _pos + step
	var only_x := Vector2(_pos.x + step.x, _pos.y)
	if absf(step.x) > 0.001 and _free(only_x):
		return only_x
	var only_z := Vector2(_pos.x, _pos.y + step.y)
	if absf(step.y) > 0.001 and _free(only_z):
		return only_z
	return _pos


## Помещается ли он в точке. Проба точкой на высоте пояса, а не капсулой:
## фигуре не нужно честное разрешение столкновений, ей нужен ответ «стена
## или нет», и точка на 0.9 отвечает на него за одну итерацию.
func _free(at: Vector2) -> bool:
	var cw: Variant = c.get("col")
	if not (cw is CollisionWorld):
		return true
	return not (cw as CollisionWorld).point_hit(at.x, 0.90, at.y,
		CollisionWorld.ALL_SOLID)


func _catch() -> void:
	if _caught:
		return
	_caught = true
	c["catch_source"] = {"actor": "echo", "pos": Vector3(_pos.x, 0.0, _pos.y)}
	var game_state: Variant = c.get("state")
	c["catch_previous_threat"] = game_state.threatState if game_state is GameState else "absent"
	state = "gone"
	var actors: Variant = c.get("actors")
	if actors != null:
		actors.show("echo", false)
	# Дальше всё делает глава: скример, карточка провала и [R]. Точка возврата
	# стоит не в начале УЛИЦЫ, а в минуте отсюда — её ставит street_quest,
	# когда он выходит на линию.
	_emit("street-caught")


# ---------- фигура ----------

## Поставить фигуру на линию и показать. Отдельным методом, потому что зовётся
## из трёх мест: begin(), повторный begin() и каждый кадр _apply().
func _show() -> void:
	var actors: Variant = c.get("actors")
	if actors == null:
		return
	actors.place("echo", _pos.x, 0.0, _pos.y, _yaw + PI)
	actors.show("echo", true)


func _apply(dt: float, feet: Vector3) -> void:
	var actors: Variant = c.get("actors")
	if actors == null:
		return
	# ВЛАДЕНИЕ ВОЗВРАЩАЕТСЯ САМО. Ключ 'echo' общий на всю игру, и любой
	# чужой _hide() гасит фигуру по праву — haunt.reset() делает это
	# безусловно и обязан. Пока дед на линии, он забирает её обратно каждый
	# кадр: это дешевле и надёжнее, чем перечислять всех, кто может погасить.
	actors.show("echo", true)
	var want := _dir_yaw() + (sin(_sweep) * SWEEP if state == "walk" else 0.0)
	if state == "hunt":
		var to := Vector2(feet.x, feet.z) - _pos
		if to.length() > 0.05:
			want = atan2(to.x, to.y)
	_yaw = _turn(_yaw, want, TURN * dt)
	actors.place("echo", _pos.x, 0.0, _pos.y, _yaw + PI)
	# speed не передаём: walk_anim выводит фазу шага из фактического смещения,
	# и рывок сам по себе выглядит как ускорившийся шаг.
	actors.walk_anim("echo", dt, {"idle": 1.0 if _wait > 0.0 else 0.0})


# ---------- взгляд ----------

# Видит ли он игрока. Правило сцены прежнее — по краю не видно вовсе, хоть
# в упор смотри, — но к нему добавлены две поправки фазы 18.
#
# ЭТАЖ. Игрок на втором этаже красного дома, в подполе или на чердаке — не
# «на линии»: между ними перекрытие. Дед стоит на земле, и всё, что дальше
# полуметра по высоте, для него другая комната.
#
# СТЕНА. Луч по ALL_SOLID — иначе NOSE 2.6 «в упор видит всегда» ловил
# игрока СКВОЗЬ стену сельпо и сквозь ограду погоста: расстояние-то два
# метра. Луч стреляет в грудь, а не в ноги: ноги за штакетником прячутся у
# кого угодно.
func _sees(feet: Vector3) -> bool:
	if absf(feet.y) > SAME_FLOOR:
		return false
	var flat := Vector2(feet.x, feet.z)
	var d := flat.distance_to(_pos)
	if d > NOSE:
		var far := SEE_FAR * (SEE_LAMP if _lamp_on() else 1.0)
		if d > far:
			return false
		if absf(feet.z - LANE_Z) > LANE_HALF:
			return false
		var dir := Vector2(sin(_yaw), cos(_yaw))
		if dir.dot((flat - _pos) / d) <= VIEW_COS:
			return false
	return _clear(feet)


## Не упирается ли взгляд в стену. Нет мира коллизий в ctx (так собран
## tests/test_street_stalk.gd) — считаем, что не упирается: правило сцены
## проверяется без мира, и заводить мир ради него незачем.
func _clear(feet: Vector3) -> bool:
	var cw: Variant = c.get("col")
	if not (cw is CollisionWorld):
		return true
	var from := Vector3(_pos.x, CHEST, _pos.y)
	var to := Vector3(feet.x, feet.y + CHEST, feet.z)
	var v := to - from
	var ln := v.length()
	if ln < 0.05:
		return true
	var t := Threat.ray_boxes(_solid_boxes(cw as CollisionWorld),
		from.x, from.y, from.z, v.x / ln, v.y / ln, v.z / ln, ln)
	return t == INF or t > ln - 0.25


## Габариты ВСЕХ четырёх наборов одним массивом. Threat.static_boxes отдаёт
## только первый — с ним луч не увидел бы ни бортов улицы, ни оград деревни,
## ни стен околицы, то есть всего, что здесь и заслоняет. Считается один раз
## на главу: геометрия за это время не меняется, а створки дверей на сорока
## метрах открытой дороги ничего не решают.
func _solid_boxes(cw: CollisionWorld) -> PackedFloat64Array:
	var total := 0
	for set_id in CollisionWorld.SET_COUNT:
		total += cw.box_count(set_id)
	if _boxes.size() == total * 6:
		return _boxes
	_boxes = PackedFloat64Array()
	_boxes.resize(total * 6)
	var at := 0
	for set_id in CollisionWorld.SET_COUNT:
		for i in cw.box_count(set_id):
			var b := cw.box_aabb_d(set_id, i)
			if b.size() < 6:
				at += 6
				continue
			for k in 6:
				_boxes[at + k] = b[k]
			at += 6
	return _boxes


func _lamp_on() -> bool:
	var fl: Variant = c.get("flashlight")
	return fl != null and bool(fl.on)


# Угол ВЗГЛЯДА, а не поворот модели: направление здесь всюду (sin, cos) в осях
# (x, z), как у atan2(dx, dz). Модель развёрнута лицом на -Z, поэтому в
# actors.place уходит _yaw + PI — и только там.
func _dir_yaw() -> float:
	return PI * 0.5 * _dir


static func _turn(from: float, to: float, step: float) -> float:
	var d := fposmod(to - from + PI, TAU) - PI
	return from + clampf(d, -step, step)


# ------------------------------------------------------------- служебное ----

func _feet() -> Vector3:
	var ctrl: Variant = c.get("controls")
	return Vector3.ZERO if ctrl == null else ctrl.feet()


func _say(beat: String, seconds: float) -> void:
	var beats: Dictionary = (c.get("texts", {}) as Dictionary).get("BEATS", {})
	var text := String(beats.get(beat, ""))
	var ui: Variant = c.get("ui")
	if text != "" and ui != null:
		ui.say(text, seconds)


func _hold(seconds: float) -> void:
	var director: Variant = c.get("horror")
	if seconds <= 0.0 and director != null and String(director.owner) != "stalk":
		return
	var f: Variant = c.get("holdEcho")
	if f is Callable:
		(f as Callable).call(seconds, "stalk")


func _emit(event: String, payload: Variant = null) -> void:
	var f: Variant = c.get("emit")
	if f is Callable:
		(f as Callable).call(event, payload)

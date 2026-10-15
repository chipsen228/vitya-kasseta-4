# Директор страха: шкала давления (фаза 8).
#
# ЗАЧЕМ. До неё каждый пугающий модуль решал за себя: dread — по кулдауну,
# haunt — по бюджету главы, chapters — по секундомеру. Ни один из них не знал,
# что происходит в эту секунду с игроком, поэтому шёпот за спиной приходил
# ровно с той же вероятностью, когда дед в другом конце участка, и когда он
# в соседней комнате. Кривая напряжения при этом получалась плоской.
#
# ЧТО ЭТО. Одно число 0..1 и правила, кому и когда в него можно стрелять.
# Практика взята не из воздуха: L4D-«директор» размещает события по текущему
# состоянию игрока и гонит фазы «нарастание — пик — выдох — покой»; Alien:
# Isolation меряет давление и при переполнении УВОДИТ угрозу, иначе давление
# превращается в раздражение. Оба вывода здесь машинные, а не пожелания:
# потолок CEIL и принудительная разрядка ниже.
#
# ЧЕГО ОНА НЕ ДЕЛАЕТ. Не играет звуков, не двигает деда (кроме разрядки),
# не трогает картинку. Это арбитр: модули спрашивают allows() и сообщают
# spent(). Нет tension в ctx — каждый модуль работает ровно как в фазе 7.
#
# ЕДИНИЦЫ. pressure() — мгновенное давление обстановки, value() — оно же,
# сглаженное по времени (то, что игрок успел почувствовать). Разгон и спад
# разной длины: страх набирается быстрее, чем отпускает.
class_name Tension
extends RefCounted

# Постоянные времени экспоненциального сглаживания, секунды.
# Рост успевает к моменту, когда дед действительно подошёл; спад укладывается
# внутрь кулдауна dread (45–90 с) и не толкается с ним.
const TAU_UP := 6.0
const TAU_DOWN := 22.0

# Окна интенсивностей. Ключ — «насколько громкое событие»:
#   1 — бытовой звук (dread), скрип половицы;
#   2 — мелькание фигуры, беззвучное изменение за спиной;
#   3 — акцент: шёпот вплотную, дыхание, мигание фонаря.
# Значение — [нижняя граница шкалы, верхняя]. Верхняя не менее важна нижней:
# громкое событие на пике не добавляет ничего, кроме шума.
const WINDOWS := {
	1: [0.00, 0.55],
	2: [0.20, 0.70],
	3: [0.45, 0.80],
}

# Потолок. Выше него не проходит НИЧЕГО: это и есть «директор не добивает».
const CEIL := 0.80

# Тишина после события своей интенсивности, секунды. Событие сразу за событием
# читается как одно длинное, то есть пропадает.
#
# ФАЗА 11: пропускная способность поднята. Жалоба Петра была «в первой половине
# тихо», и виноваты были не точки, а арбитр — на прежних числах он физически
# не пропускал больше того, что игрок успел увидеть. Точки при этом остаются
# на местах, и откат ровно один и обратимый: вернуть эти шесть чисел обратно.
const QUIET := {1: 5.0, 2: 8.0, 3: 12.0}

# Пик — это событие интенсивности 3 либо любое событие при шкале выше 0.7.
const COOL := 30.0            # покой после пика: в это время не проходит ничто
const PEAK_CD := 105.0        # и следующий пик не раньше, чем через это

# Принудительная разрядка. Шкала выше потолка непрерывно RELEASE_AFTER секунд —
# значит игрок сидит в углу и ждёт, а не играет. Тогда: тишина RELEASE_QUIET,
# шкала падает до RELEASE_TO (не в ноль — он не забыл, что было), и деда уводит
# шумом на дальнюю точку.
const RELEASE_AFTER := 12.0
const RELEASE_QUIET := 14.0
const RELEASE_TO := 0.45

# Куда уводить. Точки дальние и разнесённые по участку: hear() ставит шум,
# ai сам ищет ближайший узел графа. Совпадают с местами, где двойник уже
# появлялся (haunt), поэтому «он ушёл туда» читается, а не выглядит телепортом.
const DECOYS := [
	Vector3(1.40, 0.00, 26.60),      # глубина огорода
	Vector3(-4.60, 0.00, 28.40),     # дальний забор
	Vector3(-7.00, 0.10, 21.00),     # теплица
	Vector3(0.00, 0.00, -1.20),      # ворота
	Vector3(7.60, 0.00, 4.20),       # восточный угол двора
]

# Вклады в давление. Сумма весов 1.35 — специально больше единицы: разом все
# условия не сходятся никогда, а по отдельности каждое должно дотягивать шкалу
# до своего окна.
const W_NEAR := 0.45          # дед близко
const W_DARK := 0.20          # темно и нечем светить
const W_TIGHT := 0.15         # теснота: подпол, чердак
const W_OPEN := 0.10          # открытое место ночью
const W_HIDDEN := 0.25        # сидит в укрытии, а он ходит
const W_RUN := 0.10           # бежит

# Дальность, с которой дед начинает давить, и на которой давит полностью.
const NEAR_FAR := 18.0
const NEAR_FULL := 4.0
const HUNT_K := 1.35          # в погоне тот же метр весит больше

# Теснота по уровню зоны. Улица не давит вовсе — там есть куда бежать.
const TIGHT := {
	"cellar": 1.0, "roof": 1.0, "attic": 0.5, "floor1": 0.25,
	"plot": 0.0, "street": 0.0,
}

var c: Variant = null
var rng := RandomNumberGenerator.new()

var _value := 0.0
var _pressure := 0.0
var _quiet := 0.0             # тишина после события
var _cool := 0.0              # покой после пика
var _peak_cd := 0.0           # между пиками
var _over := 0.0              # сколько секунд подряд шкала выше потолка
var _released := 0.0          # когда последний раз уводили деда, для F3
var _spent := 0               # событий за прохождение, для F3


func _init(ctx: Variant = null, rng_seed: int = 0) -> void:
	c = ctx
	rng.seed = rng_seed


## Звать каждый кадр, пока игра идёт, между threat и haunt: шкала обязана
## видеть позицию деда этого кадра, а haunt и dread — уже готовую шкалу.
func update(dt: float) -> void:
	_pressure = _measure()
	var tau := TAU_UP if _pressure > _value else TAU_DOWN
	# Экспоненциальное приближение, устойчивое к любому dt: при dt >> tau
	# коэффициент стремится к единице, а не улетает за неё.
	_value += (_pressure - _value) * (1.0 - exp(-dt / maxf(0.01, tau)))
	_value = clampf(_value, 0.0, 1.0)

	_quiet = maxf(0.0, _quiet - dt)
	_cool = maxf(0.0, _cool - dt)
	_peak_cd = maxf(0.0, _peak_cd - dt)

	if _value > CEIL:
		_over += dt
		if _over >= RELEASE_AFTER:
			_release()
	else:
		_over = 0.0


## Сглаженная шкала — то, что игрок успел почувствовать.
func value() -> float:
	return _value


## Мгновенное давление обстановки.
func pressure() -> float:
	return _pressure


## Грубый уровень для отладки и для веток в других модулях: 0 — покой,
## 1 — тревожно, 2 — плохо, 3 — вплотную.
func level() -> int:
	if _value < 0.25:
		return 0
	if _value < 0.50:
		return 1
	if _value < CEIL:
		return 2
	return 3


## Можно ли сейчас сыграть событие такой интенсивности.
func allows(intensity: int) -> bool:
	if _quiet > 0.0 or _cool > 0.0:
		return false
	if _value >= CEIL:
		return false
	var w: Array = WINDOWS.get(clampi(intensity, 1, 3), WINDOWS[1])
	if _value < float(w[0]) or _value > float(w[1]):
		return false
	if intensity >= 3 and _peak_cd > 0.0:
		return false
	return true


## Сообщить, что событие сыграно. Считает тишину, покой и подталкивает шкалу:
## событие само по себе — давление, иначе цепочка «сыграли — шкала не выросла —
## сыграли опять» шла бы сплошняком.
func spent(intensity: int) -> void:
	var i := clampi(intensity, 1, 3)
	_spent += 1
	_quiet = maxf(_quiet, float(QUIET.get(i, 6.0)))
	_value = clampf(_value + 0.06 * float(i), 0.0, 1.0)
	if i >= 3 or _value > 0.70:
		_cool = COOL
		_peak_cd = PEAK_CD


## Сколько секунд ещё тишина. Ноль — можно.
func quiet_left() -> float:
	return maxf(_quiet, _cool)


## При [R] и при смене главы через checkpoint: шкала — свойство сцены,
## а не прохождения, и переживать смерть она не должна.
func reset() -> void:
	_value = 0.0
	_pressure = 0.0
	_quiet = 0.0
	_cool = 0.0
	_peak_cd = 0.0
	_over = 0.0


## Одна строка для экрана F3.
func debug_line() -> String:
	return "давл %.2f  шкала %.2f  ур.%d  тихо %dс  пик %dс  событий %d" % [
		_pressure, _value, level(), roundi(quiet_left()), roundi(_peak_cd), _spent]


# ---------- внутреннее ----------

## Давление обстановки прямо сейчас. Всё берётся из того, что уже есть
## в состоянии: своих таймеров и своей памяти у измерителя нет.
func _measure() -> float:
	var st: Variant = _cx("state")
	if st == null:
		return 0.0
	var p: Variant = _cx("controls")
	if p == null:
		return 0.0
	var feet: Vector3 = p.feet()

	var v := 0.0

	# --- дед рядом ---
	var tv: Variant = _cx("threat")
	var hunting := false
	if tv is Threat and (tv as Threat).is_active():
		var t: Threat = tv
		hunting = String(st.get("threatState")) == "hunt"
		var d := feet.distance_to(t.pos)
		var k := clampf((NEAR_FAR - d) / (NEAR_FAR - NEAR_FULL), 0.0, 1.0)
		v += k * W_NEAR * (HUNT_K if hunting else 1.0)

	# --- темнота, которой нечем светить ---
	var night := 0.0
	var lv: Variant = _cx("lights")
	if lv != null:
		night = clampf(float(lv.get("night")), 0.0, 1.0)
	var lit := 0.0
	var fv: Variant = _cx("flashlight")
	if fv != null and bool(fv.get("on")) and float(fv.get("battery")) > 1.0:
		lit = 1.0
	v += night * (1.0 - 0.6 * lit) * W_DARK

	# --- теснота и открытость ---
	var zone := _zone(feet)
	var level_id := String(zone.get("level", ""))
	v += float(TIGHT.get(level_id, 0.0)) * W_TIGHT
	if String(zone.get("reverb", "")) == "outdoor":
		v += night * W_OPEN

	# --- укрытие и бег ---
	if bool(st.get("hidden")) and tv is Threat and (tv as Threat).is_active():
		v += W_HIDDEN
	if bool(p.get("running")):
		v += W_RUN

	return clampf(v, 0.0, 1.0)


## Принудительная разрядка: тишина, шкала вниз и увести деда шумом на самую
## дальнюю от игрока точку-приманку. Это не милосердие, а темп: после
## четырнадцати секунд пустоты следующий скрип стоит дороже любого стингера.
func _release() -> void:
	_over = 0.0
	_quiet = maxf(_quiet, RELEASE_QUIET)
	_value = minf(_value, RELEASE_TO)
	_released += 1.0

	var tv: Variant = _cx("threat")
	if not (tv is Threat):
		return
	var p: Variant = _cx("controls")
	if p == null:
		return
	var feet: Vector3 = p.feet()
	var best := DECOYS[0]
	var best_d := -1.0
	for d: Vector3 in DECOYS:
		var dist := feet.distance_to(d)
		if dist > best_d:
			best_d = dist
			best = d
	# hear() в патруле роняет relocate_in до 2.5 — он реально уходит, а не
	# «теряет интерес». В погоне это тоже шум, но там его перебьёт зрение,
	# и это правильно: из погони выводит игрок, а не директор.
	(tv as Threat).hear(best, 1.0)


func _zone(feet: Vector3) -> Dictionary:
	var w: Variant = _cx("world")
	if not (w is Dictionary):
		return {}
	var d: Dictionary = w
	var f: Variant = d.get("zone_at", null)
	if not (f is Callable):
		return {}
	var cb: Callable = f
	var z: Variant = cb.call(feet.x, feet.y, feet.z)
	return z if z is Dictionary else {}


func _cx(key: String) -> Variant:
	if c is Dictionary:
		var d: Dictionary = c
		return d.get(key, null)
	if c == null:
		return null
	return c.get(key)

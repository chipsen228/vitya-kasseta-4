# Сценарная камера (фаза 16).
#
# ЗАЧЕМ. До этой фазы игра кончалась так: нажал «ехать» — и сразу карточки
# титров. Сергей уезжал за кадром, Витя из финала пропадал вовсе. Механики для
# сценарного кадра в проекте не было ни строчки: всё остальное — фигуры,
# машина как двигаемая нода, стартёр, плёночный трекинг — уже есть и здесь
# только переиспользуется.
#
# МОДУЛЬ ДЕРЖИТСЯ МАЛЕНЬКИМ НАМЕРЕННО. Он умеет ровно две вещи: вести время
# и держать свою камеру. Что двигается в кадре — не его дело: это решает
# покадровый колбэк, который передаёт вызывающий. Так у сцены отъезда нет ни
# одной строчки внутри модуля, и следующая сцена не будет её ломать.
#
# КАМЕРА. На время сцены заводится СВОЯ Camera3D с current = true. С
# player._apply_camera() не воюем: он продолжает писать в свою камеру вхолостую,
# а по выходе current возвращается ей. Ни одной правки в player.gd.
#
# ПРОПУСК. Обязателен и без оговорок: на втором прохождении десять секунд без
# управления читаются зависанием, а не сценой.

class_name Cutscene
extends RefCounted

## Предохранитель. Сцена, которая не кончилась сама, кончается здесь: игрок
## не должен залипнуть в кадре, из которого нет выхода.
const MAX_LEN := 10.0

## Окно нечувствительности к пропуску, секунд (фаза 17).
##
## Сцену запускает НАЖАТИЕ. Игрок жмёт [E] на машине, стартёр крутит два
## оборота с паузой — 2.6 с, — в эти секунды он читает субтитр и жмёт [E]
## ещё раз, потому что ничего не произошло. Раньше это второе нажатие гасило
## катсцену в первом же её кадре: между «нажал ехать» и титрами снова не
## происходило ничего. Ровно это Пётр и увидел — «отъезд толком не показали».
##
## Полторы секунды — не «подождите». За них успевает пройти первый кадр:
## фары разгораются и ложатся на дорогу. Дальше пропуск работает как работал.
const SKIP_AFTER := 1.4

var playing := false

var _t := 0.0
var _len := 0.0
var _tick: Callable = Callable()
var _done: Callable = Callable()
var _cam: Camera3D = null
var _prev: Camera3D = null
var _root: Node3D = null
var _shots: Array = []
var paused := false


## Запустить сцену. shots — список кадров [{pos: Vector3, look_at: Vector3,
## sec: float}]: камера стоит в кадре ровно sec секунд и переключается на
## следующий. tick(t) зовётся каждый кадр с временем ОТ НАЧАЛА сцены —
## им двигают машину и фигуру. done() — по окончании или по пропуску.
func play(root: Node3D, prev_cam: Camera3D, shots: Array, length: float,
		tick: Callable, done: Callable) -> bool:
	if playing or root == null or shots.is_empty():
		return false
	_root = root
	_prev = prev_cam
	_tick = tick
	_done = done
	_len = minf(maxf(length, 0.1), MAX_LEN)
	_t = 0.0

	_cam = Camera3D.new()
	_cam.name = "cutscene-camera"
	# Те же параметры, что у камеры игрока: сцена снята тем же объективом,
	# иначе переход читается сменой оптики, а не сменой кадра.
	if prev_cam != null:
		_cam.fov = prev_cam.fov
		_cam.near = prev_cam.near
		_cam.far = prev_cam.far
	_shots = shots
	root.add_child(_cam)
	_apply_shot(0.0)
	_cam.current = true
	playing = true
	if _tick.is_valid():
		_tick.call(0.0)
	return true


## Сколько сцена идёт. Спрашивает tests/shots.gd, чтобы снять кадр РОВНО
## на середине отъезда, а не «через сколько-то кадров».
func time() -> float:
	return _t


func update(dt: float) -> void:
	if not playing or paused:
		return
	_t += dt
	if _tick.is_valid():
		_tick.call(_t)
	_apply_shot(_t)
	if _t >= _len:
		_finish()


## Пропуск любой клавишей или мышью. Колбэк done() зовётся ровно один раз —
## и в конце, и по пропуску: иначе на пропуске игра осталась бы без титров.
##
## Первые SKIP_AFTER секунд не пропускаются: сцену запускает то же нажатие,
## которым игрок завёл машину, и оно доезжало сюда. Возвращает, случился ли
## пропуск, — вызывающий обязан ПРОГЛОТИТЬ клавишу в любом случае, иначе она
## провалится в интеракт и в паузу поверх кадра.
func skip() -> bool:
	if not playing or paused or _t < SKIP_AFTER:
		return false
	# Пропуск доводит анимацию до того же результата, включая удар и падение.
	_t = _len
	if _tick.is_valid(): _tick.call(_t)
	_apply_shot(_t)
	_finish()
	return true


func _finish() -> void:
	playing = false
	var cb := _done
	_done = Callable()
	_tick = Callable()
	if _cam != null:
		_cam.current = false
		if _prev != null:
			_prev.current = true
		if _root != null and is_instance_valid(_cam):
			_root.remove_child(_cam)
		_cam.queue_free()
		_cam = null
	_prev = null
	_root = null
	_shots = []
	if cb.is_valid():
		cb.call()


func cancel() -> void:
	_finish()
	paused = false


func _apply_shot(t: float) -> void:
	if _cam == null or _shots.is_empty():
		return
	var acc := 0.0
	var shot_start := 0.0
	var use: Dictionary = _shots[_shots.size() - 1]
	for s: Dictionary in _shots:
		acc += float(s.get("sec", 1.0))
		if t < acc:
			use = s
			break
		shot_start = acc
	var pos: Vector3 = use.get("pos", Vector3.ZERO)
	var at: Vector3 = use.get("look_at", pos + Vector3.FORWARD)
	var sec := maxf(0.001, float(use.get("sec", 1.0)))
	var q := clampf((t - shot_start) / sec, 0.0, 1.0)
	q = q * q * (3.0 - 2.0 * q)
	if use.has("pos_to"):
		pos = pos.lerp(use["pos_to"], q)
	if use.has("look_at_to"):
		at = at.lerp(use["look_at_to"], q)
	var dir := at - pos
	if dir.length_squared() < 1e-6:
		dir = Vector3.FORWARD
	_cam.transform = Transform3D(Basis.looking_at(dir.normalized(), Vector3.UP), pos)
	var roll := lerpf(float(use.get("roll", 0.0)), float(use.get("roll_to", use.get("roll", 0.0))), q)
	_cam.rotate_object_local(Vector3.FORWARD, roll)

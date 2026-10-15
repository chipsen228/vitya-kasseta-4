# Деда на линии ВИДНО (фаза 18).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ТЕСТ, КОГДА ЕСТЬ test_street_stalk. Тот собирает контекст
# БЕЗ actors и БЕЗ holdEcho — и потому слеп ровно к тому, на что Пётр
# пожаловался живьём: «уличного деда не видно никогда, а ловит он исправно».
# Вся логика «видит -> догоняет -> ловит» у него работала, а фигура гасла
# в том же кадре, в котором её создали: begin() показывал двойника и сразу
# после этого звал _hold(), тот шёл в main._ctx_hold_echo -> startle.clear()
# -> startle._hide() -> actors.show('echo', false). Безусловно, даже когда
# у startle ничего не идёт.
#
# ПРОВЕРЯЕМ ЧЕТЫРЕ УТВЕРЖДЕНИЯ, И ВСЕ ЧЕТЫРЕ ПРО ВИДИМОСТЬ:
#
#   1. После begin() фигура видима — то есть порядок вызовов внутри begin()
#      правильный: сначала занять двойника, потом показать.
#   2. startle.clear() при пустом startle её не гасит: чужой модуль не
#      трогает то, чем не владеет.
#   3. haunt.reset() её гасит (ключ 'echo' общий, и это его право), но
#      следующий же кадр stalk'а возвращает владение — _apply() показывает
#      фигуру, пока active().
#   4. finish() её гасит и оставляет погашенной.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_stalk_figure.gd
extends SceneTree


## Заглушка фигур: помнит только видимость и последнюю позицию 'echo'.
class FakeActors extends RefCounted:
	var shown: Dictionary = {}
	var at: Dictionary = {}
	func show(who: String, on := true) -> void:
		shown[who] = on
	func show_actor(who: String, on := true) -> void:
		shown[who] = on
	func place(who: String, x: float, y: float, z: float, _yaw := 0.0) -> void:
		at[who] = Vector3(x, y, z)
	func face(_who: String, _x: float, _z: float) -> void:
		pass
	func walk_anim(_who: String, _dt: float, _opts: Dictionary = {}) -> void:
		pass
	func visible_of(who: String) -> bool:
		return bool(shown.get(who, false))


class Feet extends RefCounted:
	var p := Vector3.ZERO
	func feet() -> Vector3:
		return p


var _actors: FakeActors = null
var _startle: Startle = null
var _haunt: Haunt = null


func _initialize() -> void:
	var errs: Array[String] = []
	errs.append_array(_visible_after_begin())
	errs.append_array(_startle_clear_keeps())
	errs.append_array(_haunt_reset_returns())
	errs.append_array(_finish_hides())

	if errs.is_empty():
		print("PASS test_stalk_figure: фигура видима на линии и гаснет только "
			+ "по finish()")
		quit(0)
		return
	print("FAIL test_stalk_figure: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# 1. Вышел на линию — значит, его видно.
func _visible_after_begin() -> Array[String]:
	var errs: Array[String] = []
	var st := _stalk()
	if not _actors.visible_of("echo"):
		errs.append("после begin(true) фигура погашена: _hold() гасит её "
			+ "ПОСЛЕ actors.show — порядок в begin() обратный")
	if not st.active():
		errs.append("после begin(true) дед не на линии: %s" % st.state)
	return errs


# 2. Чужой clear() при пустом startle фигуру не трогает.
func _startle_clear_keeps() -> Array[String]:
	var errs: Array[String] = []
	var st := _stalk()
	_startle.clear()
	if not _actors.visible_of("echo"):
		errs.append("startle.clear() погасил фигуру, ничем не владея")
	st.update(0.1)
	if not _actors.visible_of("echo"):
		errs.append("после clear() и кадра фигура так и не вернулась")
	return errs


# 3. haunt.reset() гасит по праву — кадр stalk'а обязан вернуть владение.
func _haunt_reset_returns() -> Array[String]:
	var errs: Array[String] = []
	var st := _stalk()
	_haunt.reset()
	st.update(0.1)
	if not _actors.visible_of("echo"):
		errs.append("после haunt.reset() фигура не вернулась: _apply() "
			+ "не показывает её каждый кадр")
	return errs


# 4. Ушёл с линии — погас и остался погашенным.
func _finish_hides() -> Array[String]:
	var errs: Array[String] = []
	var st := _stalk()
	st.finish()
	if _actors.visible_of("echo"):
		errs.append("после finish() фигура осталась на дороге")
	st.update(0.1)
	if _actors.visible_of("echo"):
		errs.append("после finish() фигура вернулась на следующем кадре")
	return errs


# Контекст с ЖИВЫМИ startle и haunt: holdEcho повторяет main._ctx_hold_echo
# дословно, иначе тест проверял бы не ту цепочку, которая и сломалась.
func _stalk() -> StreetStalk:
	_actors = FakeActors.new()
	var feet := Feet.new()
	var state := GameState.new()
	state.chapter = "village"
	var ctx: Dictionary = {
		"controls": feet,
		"state": state,
		"actors": _actors,
		"texts": {},
		"emit": func(_e: String, _p: Variant = null) -> void: pass,
	}
	_startle = Startle.new(ctx, _actors, null)
	_haunt = Haunt.new(ctx, _actors, null, 1)
	ctx["startle"] = _startle
	ctx["haunt"] = _haunt
	ctx["holdEcho"] = func(seconds: float, _owner := "mandatory") -> void:
		_haunt.hold(seconds)
		_startle.clear()
	var st := StreetStalk.new(ctx, 1)
	feet.p = Vector3.ZERO
	st.begin(true)
	return st

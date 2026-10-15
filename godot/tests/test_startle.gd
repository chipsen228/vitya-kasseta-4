# Испуги по местам: пять правил механики — машинно (раунд 10).
#
# Точки проверяет test_startle_points (там геометрия: видно/не видно, стоит/висит).
# Здесь другое — поведение модуля, и каждое из пяти утверждений уже однажды
# ломало похожие механики в этом проекте:
#
#   1. Переход зоны СЧИТАЕТСЯ. «Вышел из сарая» — это не координата, а смена
#      зоны, и без неё точка срабатывала бы на входе тоже.
#   2. Однократность держится флагом состояния, а не кулдауном: сняв кулдаун,
#      второй раз выстрелить нельзя.
#   3. Пришёл не из той зоны — точки нет вовсе.
#   4. Пока по улице ходит дед (stalk.active), двойник занят, и фигуру
#      не ставит никто. Двое одинаковых в кадре — старая беда haunt.gd.
#   5. Знак (sign) живёт без фигуры и без actors: у него только звук.
#
# Мир не строится: у модуля нет ни графа, ни коллизий — ему хватает позиции
# игрока, зоны и камеры. Луч видимости при col == null всегда чист, поэтому
# видимостью здесь управляет только поворот камеры, и это ровно то, что нужно
# проверять на этом уровне.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_startle.gd
extends SceneTree


class Feet extends RefCounted:
	var p := Vector3.ZERO
	func feet() -> Vector3:
		return p


class Rig extends RefCounted:
	var camera: Camera3D = null


class Stalk extends RefCounted:
	var on := false
	func active() -> bool:
		return on


class FakeActors extends RefCounted:
	var shown := false
	var at := Vector3.ZERO
	var places := 0
	func place(_who: String, x: float, y: float, z: float, _yaw := 0.0) -> void:
		at = Vector3(x, y, z)
		places += 1
	func face(_who: String, _x: float, _z: float) -> void:
		pass
	func show(_who: String, on := true) -> void:
		shown = on
	func figure(_who: String) -> Node3D:
		return null
	func walk_anim(_who: String, _dt: float, _opts: Dictionary) -> void:
		pass


var _cam: Camera3D = null
var _holds := 0.0
var _done := false


# Работа идёт в _process, а не в _initialize, и это не стилистика: в момент
# _initialize корня сцены ещё НЕТ (get_root() пуст), узел вне дерева, и любое
# обращение к global_transform камеры отдаёт единичную матрицу с руганью
# в консоль. Проверка видимости при этом «работает» — и врёт.
func _process(_dt: float) -> bool:
	if _done:
		return true
	_done = true
	_run()
	return true


func _run() -> void:
	_cam = Camera3D.new()
	get_root().add_child(_cam)

	var errs: Array[String] = []
	errs.append_array(_shed_exit_fires())
	errs.append_array(_only_once())
	errs.append_array(_wrong_side_is_silent())
	errs.append_array(_stalker_blocks_figure())
	errs.append_array(_sign_needs_no_figure())

	_cam.queue_free()
	if errs.is_empty():
		print("PASS test_startle: %d точек, кулдаун %.0f с, бюджет ТЕМНОТЫ %d"
			% [Startle.POINTS.size(), Startle.GLOBAL_CD,
				int(Startle.BUDGET.get("dark", 0))])
		quit(0)
		return
	print("FAIL test_startle: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# 1. Вышел из сарая — получил силуэт в лицо.
func _shed_exit_fires() -> Array[String]:
	var errs: Array[String] = []
	var s := _make("arrive")
	var st: Startle = s[0]
	var fake: FakeActors = s[3]
	_walk_out(s)
	if st._live != "shed-out":
		errs.append("выход из сарая не сработал: идёт «%s»" % st._live)
		return errs
	if not fake.shown:
		errs.append("испуг идёт, а фигура не показана")
	if not bool((s[1] as GameState).has("startle-shed-out")):
		errs.append("флаг «уже было» не поставлен — точка выстрелит второй раз")
	if _holds <= 0.0:
		errs.append("двойник не занят: holdEcho не позван, haunt уведёт фигуру")
	# И гаснет сам, без посторонней помощи.
	for _i in 20:
		st.update(0.05)
	if st._live != "" or fake.shown:
		errs.append("удар не погас за секунду: «%s», фигура %s"
			% [st._live, "видна" if fake.shown else "скрыта"])
	return errs


# 2. Второй раз — тишина, и не из-за кулдауна: его снимаем руками.
func _only_once() -> Array[String]:
	var errs: Array[String] = []
	var s := _make("arrive")
	var st: Startle = s[0]
	var state: GameState = s[1]
	var before := state.snapshot()
	_walk_out(s)
	for _i in 20:
		st.update(0.05)
	st.cool = 0.0
	st.shown = 0
	_walk_out(s)
	if st._live != "":
		errs.append("точка сработала второй раз: «%s»" % st._live)
	state.restore(before)
	st.reset()
	_walk_out(s)
	if st._live != "" or not state.horror_seen.has("startle/shed-out"):
		errs.append("откат контрольной точки вернул уже показанный испуг")
	state.reset()
	if not state.horror_seen.is_empty():
		errs.append("новая игра не очистила историю испугов")
	return errs


# 3. Тот же триггер, но игрок пришёл с участка, а не из сарая.
func _wrong_side_is_silent() -> Array[String]:
	var errs: Array[String] = []
	var s := _make("arrive")
	var st: Startle = s[0]
	var feet: Feet = s[2]
	st.cool = 0.0
	# Сначала он на участке, потом входит в круг триггера — но с той же
	# стороны, то есть из «plot», а не из сарая.
	_zone_is(s, "privy")
	feet.p = Vector3(8.6, 0.0, 21.0)
	st.update(0.3)
	_zone_is(s, "plot")
	feet.p = Vector3(6.8, 0.0, 9.3)
	_look_at(feet.p, Vector3(6.9, 0.0, 6.9))
	st.update(0.3)
	if st._live == "shed-out":
		errs.append("сработало при входе не из сарая — переход зоны не считается")
	return errs


# 4. Дед ходит по улице — двойник занят им.
func _stalker_blocks_figure() -> Array[String]:
	var errs: Array[String] = []
	var s := _make("street")
	var st: Startle = s[0]
	var stalk: Stalk = s[4]
	stalk.on = true
	st.cool = 0.0
	var feet: Feet = s[2]
	_zone_is(s, "plot")
	feet.p = Vector3(0.0, 0.0, 2.0)
	st.update(0.3)
	_zone_is(s, "street")
	feet.p = Vector3(0.0, 0.0, -1.0)
	_look_at(feet.p, Vector3(-4.2, 0.0, -1.6))
	st.update(0.3)
	if st._live != "":
		errs.append("двойник отдан испугу, пока дед на линии: «%s»" % st._live)
	# А без деда та же точка обязана сыграть — иначе проверка ничего не значит.
	stalk.on = false
	st.update(0.3)
	if st._live != "gate-out":
		errs.append("тест бесполезен: без деда точка тоже молчит («%s»)" % st._live)
	return errs


# 5. Знак играет без фигуры вовсе — actors ему не нужен.
func _sign_needs_no_figure() -> Array[String]:
	var errs: Array[String] = []
	var s := _make("dark", false)
	var st: Startle = s[0]
	var feet: Feet = s[2]
	st.cool = 0.0
	feet.p = Vector3(-5.05, 1.10, 10.80)
	st.update(0.3)
	if not bool((s[1] as GameState).has("startle-stairs-down")):
		errs.append("знак на лестнице не сыграл без actors")
	if st._live != "":
		errs.append("знак остался висеть как активный испуг: «%s»" % st._live)
	return errs


# ---------- обвязка ----------

# Возвращает [Startle, GameState, Feet, FakeActors, Stalk].
func _make(chapter: String, with_actors := true) -> Array:
	_holds = 0.0
	var st := GameState.new().reset()
	st.chapter = chapter
	var feet := Feet.new()
	var fake := FakeActors.new()
	var stalk := Stalk.new()
	var rig := Rig.new()
	rig.camera = _cam
	var zone := {"id": ""}
	var ctx := {
		"state": st,
		"controls": feet,
		"renderer": rig,
		"actors": fake if with_actors else null,
		"stalk": stalk,
		"world": {"zone_at": func(_x: float, _y: float, _z: float) -> Dictionary:
			return zone},
		"holdEcho": func(sec: float) -> void: _holds = sec,
		"scaresOn": func() -> bool: return true,
	}
	var s := Startle.new(ctx, fake if with_actors else null, null)
	s.cool = 0.0
	return [s, st, feet, fake, stalk, zone]


func _zone_is(s: Array, id: String) -> void:
	(s[5] as Dictionary)["id"] = id


# Игрок в сарае, потом шаг за порог — и смотрит туда, куда пойдёт.
func _walk_out(s: Array) -> void:
	var st: Startle = s[0]
	var feet: Feet = s[2]
	st.cool = 0.0
	_zone_is(s, "shed")
	feet.p = Vector3(6.8, 0.0, 12.0)
	st.update(0.3)
	_zone_is(s, "plot")
	feet.p = Vector3(6.8, 0.0, 9.3)
	_look_at(feet.p, Vector3(6.9, 0.0, 6.9))
	st.update(0.3)


# Камера в глазах игрока, взглядом на точку: конус — единственное, что здесь
# решает видимость (col не передан, луч всегда чист).
func _look_at(from: Vector3, to: Vector3) -> void:
	_cam.global_position = from + Vector3(0.0, 1.62, 0.0)
	_cam.look_at(to + Vector3(0.0, 1.596, 0.0), Vector3.UP)
	_cam.force_update_transform()

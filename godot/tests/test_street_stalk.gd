# Дед на линии: правило «по краю не видно» — машинно (раунд 10).
#
# Правило игрок слышит от Аркадия за десять минут до того, как оно ему
# понадобится, и в этом вся ценность: если оно перестанет работать, игрок
# не поймёт, что сломалось, — он решит, что его обманули. Поэтому проверяем
# не «дед существует», а ровно четыре утверждения, из которых состоит сцена:
#
#   1. Игрок краем, в упор к полосе и прямо в конусе — НЕ замечен.
#   2. Тот же игрок серединой — замечен, и дед пошёл.
#   3. Пошёл и дошёл: событие поимки уходит в главу.
#   4. Ушёл краем — дед отстал и вернулся на середину.
#
# Мир для этого не нужен: у деда на улице нет ни графа, ни коллизий, ему
# хватает controls.feet(). Подставляем заглушку и гоняем чистую логику.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_street_stalk.gd
extends SceneTree


class Feet extends RefCounted:
	var p := Vector3.ZERO
	func feet() -> Vector3:
		return p


var _events: Array[String] = []


func _initialize() -> void:
	var errs: Array[String] = []
	errs.append_array(_edge_is_safe())
	errs.append_array(_middle_is_seen())
	errs.append_array(_catch_reaches_chapter())
	errs.append_array(_edge_breaks_chase())

	if errs.is_empty():
		print("PASS test_street_stalk: полоса %.2f м, догоняет %.2f м/с, "
			% [StreetStalk.LANE_HALF, StreetStalk.HUNT]
			+ "теряет за %.1f с" % StreetStalk.LOSE)
		quit(0)
		return
	print("FAIL test_street_stalk: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# 1. Обочина. Игрок стоит вплотную к полосе — но за её краем, и прямо перед ним.
func _edge_is_safe() -> Array[String]:
	var errs: Array[String] = []
	var s := _stalk()
	var feet: Feet = s[1]
	var st: StreetStalk = s[0]
	# На полметра дальше края полосы, в восьми метрах впереди по ходу — то есть
	# в самом центре конуса. Единственное, что его спасает, — что он краем.
	feet.p = Vector3(st.pos().x - 8.0,
		0.0, StreetStalk.LANE_Z - StreetStalk.LANE_HALF - 0.5)
	for _i in 20:
		st.update(0.1)
	if st.state != "walk":
		errs.append("обочина не спасла: дед перешёл в %s" % st.state)
	if _events.has("street-spotted"):
		errs.append("обочина не спасла: пришло street-spotted")
	# И проверка самой проверки: спасла обочина, а не то, что дед не дошёл.
	# Утыкание в игрока с пяти шагов ловит любого, кто бы где ни стоял.
	var gap := Vector2(feet.p.x, feet.p.z).distance_to(
		Vector2(st.pos().x, st.pos().z))
	if gap <= StreetStalk.NOSE:
		errs.append("тест бесполезен: дед подошёл на %.2f м, ближе «в упор»" % gap)
	return errs


# 2. Середина. Тот же игрок, то же расстояние — только на полосе.
func _middle_is_seen() -> Array[String]:
	var errs: Array[String] = []
	var s := _stalk()
	var feet: Feet = s[1]
	var st: StreetStalk = s[0]
	feet.p = Vector3(st.pos().x - 8.0, 0.0, StreetStalk.LANE_Z)
	# Один кадр: замечает он мгновенно, а не «через несколько секунд». Больше
	# кадров тут дали бы ему подойти вплотную и заметить в упор — то есть
	# проверить не то.
	st.update(0.1)
	if st.state != "hunt":
		errs.append("середина сошла с рук: дед остался в %s" % st.state)
	if not _events.has("street-spotted"):
		errs.append("дед пошёл, а событие street-spotted не ушло")
	return errs


# 3. Поимка доходит до главы. Игрок стоит столбом посреди дороги.
func _catch_reaches_chapter() -> Array[String]:
	var errs: Array[String] = []
	var s := _stalk()
	var feet: Feet = s[1]
	var st: StreetStalk = s[0]
	feet.p = Vector3(st.pos().x - 6.0, 0.0, StreetStalk.LANE_Z)
	for _i in 200:
		st.update(0.05)
		if _events.has("street-caught"):
			break
	if not _events.has("street-caught"):
		errs.append("дед не дошёл до стоящего игрока за десять секунд")
	if st.active():
		errs.append("после поимки дед остался на линии: %s" % st.state)
	return errs


# 4. Уход краем обрывает погоню — но не сразу: шаг за столб не должен спасать.
func _edge_breaks_chase() -> Array[String]:
	var errs: Array[String] = []
	var s := _stalk()
	var feet: Feet = s[1]
	var st: StreetStalk = s[0]
	feet.p = Vector3(st.pos().x - 6.0, 0.0, StreetStalk.LANE_Z)
	for _i in 40:
		st.update(0.1)
		if st.state == "hunt":
			break
	if st.state != "hunt":
		errs.append("погоня не началась — проверять нечего")
		return errs
	# Убегаем далеко и краем: за пределы конуса, полосы и «в упор».
	feet.p = Vector3(st.pos().x - 20.0, 0.0, StreetStalk.LANE_Z - 6.0)
	var half := int(StreetStalk.LOSE / 0.1) - 4
	for _i in half:
		st.update(0.1)
	if st.state != "hunt":
		errs.append("дед бросил погоню раньше срока: %.1f с мало" % StreetStalk.LOSE)
	for _i in 20:
		st.update(0.1)
	if st.state != "walk":
		errs.append("дед не вернулся на линию, остался в %s" % st.state)
	if not _events.has("street-lost"):
		errs.append("дед отстал, а событие street-lost не ушло")
	return errs


func _stalk() -> Array:
	_events.clear()
	var feet := Feet.new()
	var ctx := {
		"controls": feet,
		"texts": {},
		"emit": func(e: String, _p: Variant = null) -> void: _events.append(e),
	}
	var st := StreetStalk.new(ctx, 1)
	# begin() ставит его в семи метрах западнее игрока и разворачивает на запад;
	# ставим игрока в начало координат, чтобы точка была предсказуема.
	feet.p = Vector3.ZERO
	st.begin()
	return [st, feet]

# Приёмка четвёртого набора коллизий: улица за воротами не имеет права
# сдвинуть паритет.
#
# Мир собирается ДВАЖДЫ — с data/street.json и без него, — и оба раза три
# набора прототипа обязаны дать ровно 311/4/83. Проверка нужна именно такая,
# а не «посмотреть счётчик один раз»: ошибка здесь тихая. Одна забытая
# collide=true в street_world.gd добавит коробку в SET_STATIC, паритет
# разъедется на единицу, навграф деда посчитается по другому дому,
# и заметить это можно будет только по тому, что дед перестал ходить
# в комнату, в которую ходил.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_street_overlay.gd
extends SceneTree

const WANT_STATIC := 311
const WANT_BLOCKERS := 4
const WANT_PROPS := 83


func _initialize() -> void:
	var errs: Array[String] = []

	# 1. Мир БЕЗ улицы. Кэш street_world.gd подменяется пустым словарём — ровно
	# то же, что удалить data/street.json.
	StreetWorld._cache = {}
	# ФАЗА 16. СНТ строится поверх околицы и в обоих прогонах одинаков —
	# его коробки учитывает _other_boxes вместе с участком и деревней.
	var off := _build()
	_counts("без улицы", off["col"], errs)
	# С фазы 11 в четвёртом наборе живёт не только улица: участок (баня, погреб,
	# створка погреба) кладёт туда же, а с фазы 12 ещё и деревня. Поэтому
	# «пусто» стало «ровно столько, сколько построили соседи» — инвариант тот же,
	# счёт другой.
	var yard_off := _other_boxes(off)
	if off["col"].box_count(CollisionWorld.SET_OVERLAY) != yard_off:
		errs.append("без улицы в оверлее %d коробок, а участок и деревня построили %d"
			% [off["col"].box_count(CollisionWorld.SET_OVERLAY), yard_off])
	if not (off["built"]["street"] as Dictionary).is_empty():
		errs.append("без файла StreetWorld.build() всё равно что-то построил")
	_drop(off)

	# 2. Мир С улицей. Те же три числа плюс непустой четвёртый набор.
	StreetWorld._cache = null
	var on := _build()
	var col: CollisionWorld = on["col"]
	_counts("с улицей", col, errs)
	var overlay := col.box_count(CollisionWorld.SET_OVERLAY)
	var yard_on := _other_boxes(on)
	if overlay - yard_on <= 0:
		errs.append("data/street.json есть, а в оверлее ни одной уличной коробки — "
			+ "улица собралась без твёрдой геометрии")
	else:
		print("оверлей: %d коробок (улица %d, участок и деревня %d)"
			% [overlay, overlay - yard_on, yard_on])

	var street: Dictionary = on["built"]["street"]
	if street.is_empty():
		errs.append("built.street пуст — сборка улицы не вернула ничего")
	else:
		for key: String in ["houses", "route", "nodes", "objects", "office"]:
			if not street.has(key):
				errs.append("built.street без ключа «%s»" % key)
		var houses: Dictionary = street.get("houses", {})
		if houses.size() < 3:
			errs.append("домов на улице %d — план просил три-четыре" % houses.size())

	# 3. Створка правления — по имени: за неё держится весь замок из сарая.
	if not col.is_blocker_active("door-office"):
		errs.append("нет блокера door-office — правление нечем запереть")
	col.set_blocker_active("door-office", false)
	if col.is_blocker_active("door-office"):
		errs.append("door-office не гасится через set_blocker_active")
	col.set_blocker_active("door-office", true)

	# 4. Оверлей невидим для тех, кто спрашивает мир маской ALL. Иначе дед
	# начнёт упираться в борта улицы, которых для него не существует.
	if CollisionWorld.ALL & CollisionWorld.MASK_OVERLAY != 0:
		errs.append("CollisionWorld.ALL включает оверлей — навграф и ai.gd "
			+ "увидят улицу")
	_drop(on)

	if errs.is_empty():
		print("test_street_overlay: PASS")
		quit(0)
		return
	print("FAIL test_street_overlay: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


func _counts(tag: String, col: CollisionWorld, errs: Array[String]) -> void:
	var got := [
		col.box_count(CollisionWorld.SET_STATIC),
		col.box_count(CollisionWorld.SET_BLOCKERS),
		col.box_count(CollisionWorld.SET_PROPS),
	]
	var want := [WANT_STATIC, WANT_BLOCKERS, WANT_PROPS]
	var names := ["статика", "блокеры", "реквизит"]
	for i in 3:
		if int(got[i]) != int(want[i]):
			errs.append("%s: %s %d, эталон %d" % [tag, names[i], int(got[i]), int(want[i])])
	if int(got[0]) == WANT_STATIC and int(got[1]) == WANT_BLOCKERS and int(got[2]) == WANT_PROPS:
		print("%s: %d/%d/%d — сходится" % [tag, int(got[0]), int(got[1]), int(got[2])])


func _build() -> Dictionary:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)
	return {"col": col, "root": root, "built": built, "props": props}


## Сколько коробок четвёртого набора построили НЕ улица, а её соседи по
## оверлею: участок (фаза 11), деревня (фаза 12) и околица (фаза 14). Нет
## их файлов данных — ноль, и тест читается ровно как до фазы 11.
## Околица (outskirts) не зависит от data/street.json вовсе — свой файл,
## своя проверка _cache — и строится в обоих прогонах этого теста одинаково,
## поэтому её коробки идут сюда же, а не в «уличную» разницу.
## ФАЗА 19: сюда же входят принятые scatter collision-proxy — они также не
## принадлежат улице и детерминированно строятся в обоих прогонах.
func _other_boxes(w: Dictionary) -> int:
	var built: Dictionary = w["built"]
	var n := 0
	for key: String in ["yard", "village", "home", "outskirts", "snt"]:
		var d: Dictionary = built.get(key, {})
		n += (d.get("boxes", []) as Array).size()
	n += (((built.get("scatter", {}) as Dictionary).get("collision_proxies", [])) as Array).size()
	return n


func _drop(w: Dictionary) -> void:
	(w["props"] as Props).dispose()
	(w["root"] as Node3D).free()

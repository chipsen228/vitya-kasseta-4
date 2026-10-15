# Приёмка четвёртого набора коллизий: участок с фотографии не имеет права
# сдвинуть паритет (фаза 11).
#
# Мир собирается ТРИЖДЫ: без data/yard.json, с ним, и вместе с улицей. Все три
# раза три набора прототипа обязаны дать ровно 311/4/83, а треугольников
# collide-геометрии — 3885. Проверка нужна именно такая, а не «посмотреть
# счётчик один раз»: ошибка здесь тихая. Забытый девятый аргумент у _slope,
# один вызов _gable() вместо _gable_soft() — и коробки уезжают в SET_STATIC,
# навграф деда считается по другому участку, и заметить это можно будет только
# по тому, что дед перестал ходить туда, куда ходил.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_yard_overlay.gd
extends SceneTree

const WANT_STATIC := 311
const WANT_BLOCKERS := 4
const WANT_PROPS := 83
const WANT_TRIANGLES := 3885


func _initialize() -> void:
	var errs: Array[String] = []

	# 1. Мир БЕЗ участка, БЕЗ улицы и БЕЗ деревни. Кэш модулей подменяется
	# пустым словарём — ровно то же, что удалить их файлы данных.
	YardWorld._cache = {}
	StreetWorld._cache = {}
	VillageWorld._cache = {}
	HomeWorld._cache = {}
	OutskirtsWorld._cache = {}
	SntWorld._cache = {}
	var bare := _build()
	_counts("голый", bare, errs)
	var bare_proxies := _proxy_count(bare)
	if bare["col"].box_count(CollisionWorld.SET_OVERLAY) != bare_proxies:
		errs.append("без yard.json и street.json в оверлее %d коробок, scatter-proxy насчитал %d"
			% [bare["col"].box_count(CollisionWorld.SET_OVERLAY), bare_proxies])
	if not (bare["built"]["yard"] as Dictionary).is_empty():
		errs.append("без файла YardWorld.build() всё равно что-то построил")
	_drop(bare)

	# 2. Мир С участком, но без улицы и деревни: весь оверлей принадлежит участку.
	YardWorld._cache = null
	StreetWorld._cache = {}
	VillageWorld._cache = {}
	HomeWorld._cache = {}
	OutskirtsWorld._cache = {}
	SntWorld._cache = {}
	var yard_only := _build()
	_counts("участок", yard_only, errs)
	var yard: Dictionary = yard_only["built"]["yard"]
	if yard.is_empty():
		errs.append("built.yard пуст — сборка участка не вернула ничего")
	else:
		for key: String in ["boxes", "nodes", "banya", "shed"]:
			if not yard.has(key):
				errs.append("built.yard без ключа «%s»" % key)
	var boxes: Array = yard.get("boxes", [])
	var overlay: int = yard_only["col"].box_count(CollisionWorld.SET_OVERLAY)
	if boxes.is_empty():
		errs.append("участок не отдал ни одной твёрдой коробки — сквозь баню "
			+ "и погреб можно пройти насквозь")
	var yard_proxies := _proxy_count(yard_only)
	if overlay != boxes.size() + yard_proxies:
		errs.append("в оверлее %d коробок, out.boxes и scatter-proxy насчитали %d — "
			% [overlay, boxes.size() + yard_proxies]
			+ "test_yard_nav_clear меряет зазор не по всей геометрии")
	else:
		print("участок: %d коробок в оверлее" % overlay)
	# Створка погреба гасится по имени: за неё держится задание с ключом.
	if not yard_only["col"].is_blocker_active("door-cellar-shed"):
		errs.append("нет блокера door-cellar-shed — погреб нечем запереть")
	yard_only["col"].set_blocker_active("door-cellar-shed", false)
	if yard_only["col"].is_blocker_active("door-cellar-shed"):
		errs.append("door-cellar-shed не гасится через set_blocker_active")
	yard_only["col"].set_blocker_active("door-cellar-shed", true)
	_drop(yard_only)

	# 3. Мир целиком: участок, улица и деревня вместе. Числа те же.
	YardWorld._cache = null
	StreetWorld._cache = null
	VillageWorld._cache = null
	HomeWorld._cache = null
	OutskirtsWorld._cache = null
	SntWorld._cache = null
	var full := _build()
	_counts("участок+улица+деревня", full, errs)
	var full_yard: Array = (full["built"]["yard"] as Dictionary).get("boxes", [])
	var full_village: Array = (full["built"]["village"] as Dictionary).get("boxes", [])
	var full_overlay: int = full["col"].box_count(CollisionWorld.SET_OVERLAY)
	if full_overlay <= full_yard.size() + full_village.size():
		errs.append("вместе с улицей в оверлее %d коробок при %d участковых и %d деревенских — "
			% [full_overlay, full_yard.size(), full_village.size()] + "улица потерялась")
	if full_village.is_empty():
		errs.append("деревня не отдала ни одной твёрдой коробки — сквозь сельпо "
			+ "и заколоченный дом можно пройти насквозь")
	# Единственные домашние overlay-коробки — четыре предмета мебели Тони.
	# Её пространство отсутствует в site.ROOMS и потому не входит в граф деда.
	var full_home: Array = (full["built"]["home"] as Dictionary).get("boxes", [])
	if full_home.size() != 4:
		errs.append("home_world.gd выпустил %d коробок мебели Тони вместо четырёх"
			% full_home.size())
	_assert_tonya_outside_nav(errs)
	# Оверлей невидим для тех, кто спрашивает мир маской ALL. Иначе дед начнёт
	# упираться в стены бани, которых для него не существует.
	if CollisionWorld.ALL & CollisionWorld.MASK_OVERLAY != 0:
		errs.append("CollisionWorld.ALL включает оверлей — навграф и ai.gd "
			+ "увидят баню и погреб")
	_drop(full)

	if errs.is_empty():
		print("test_yard_overlay: PASS")
		quit(0)
		return
	print("FAIL test_yard_overlay: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


func _assert_tonya_outside_nav(errs: Array[String]) -> void:
	var p := Vector2(0.60, 15.20)
	for key: String in GameData.site()["ROOMS"].keys():
		var room: Dictionary = GameData.site()["ROOMS"][key]
		if String(room.get("level", "")) != "attic":
			continue
		var x: Array = room["x"]
		var z: Array = room["z"]
		if p.x >= float(x[0]) and p.x <= float(x[1]) \
				and p.y >= float(z[0]) and p.y <= float(z[1]):
			errs.append("комната Тони попала в навигационную ROOMS.%s" % key)


func _counts(tag: String, w: Dictionary, errs: Array[String]) -> void:
	var col: CollisionWorld = w["col"]
	var got := [
		col.box_count(CollisionWorld.SET_STATIC),
		col.box_count(CollisionWorld.SET_BLOCKERS),
		col.box_count(CollisionWorld.SET_PROPS),
	]
	var want := [WANT_STATIC, WANT_BLOCKERS, WANT_PROPS]
	var names := ["статика", "блокеры", "реквизит"]
	var ok := true
	for i in 3:
		if int(got[i]) != int(want[i]):
			errs.append("%s: %s %d, эталон %d" % [tag, names[i], int(got[i]), int(want[i])])
			ok = false
	var tri := int((w["built"] as Dictionary)["triangles"])
	if tri != WANT_TRIANGLES:
		errs.append("%s: треугольников %d, эталон %d" % [tag, tri, WANT_TRIANGLES])
		ok = false
	if ok:
		print("%s: %d/%d/%d, треугольников %d — сходится"
			% [tag, int(got[0]), int(got[1]), int(got[2]), tri])


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


func _drop(w: Dictionary) -> void:
	(w["props"] as Props).dispose()
	(w["root"] as Node3D).free()


func _proxy_count(w: Dictionary) -> int:
	var scatter: Dictionary = (w["built"] as Dictionary).get("scatter", {})
	return (scatter.get("collision_proxies", []) as Array).size()

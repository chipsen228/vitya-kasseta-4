# Приёмка четвёртого набора коллизий: деревня не имеет права сдвинуть паритет
# (фаза 12).
#
# Мир собирается ЧЕТЫРЕ раза: голый, только с деревней, деревня плюс улица,
# и всё вместе с участком. Все четыре раза три набора прототипа обязаны дать
# ровно 311/4/83, а треугольников collide-геометрии — 3885.
#
# Проверка нужна именно такая, а не «посмотреть счётчик один раз»: ошибка здесь
# тихая. Забытый девятый аргумент у _slope, один вызов _gable() вместо
# _gable_soft() — и коробки уезжают в SET_STATIC, навграф деда считается
# по другому дому, и заметить это можно будет только по тому, что дед перестал
# ходить туда, куда ходил.
#
# HomeWorld выпускает ровно четыре локальные коробки мебели комнаты Тони.
# Комнаты нет в site.ROOMS, поэтому она намеренно не входит в граф деда;
# кухня и остальные посещаемые им помещения остаются без нового overlay.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_village_overlay.gd
extends SceneTree

const WANT_STATIC := 311
const WANT_BLOCKERS := 4
const WANT_PROPS := 83
const WANT_TRIANGLES := 3885


func _initialize() -> void:
	var errs: Array[String] = []

	# 1. Голый мир: ни улицы, ни участка, ни деревни, ни домашней мелочи,
	# ни околицы (фаза 14).
	_caches({}, {}, {}, {}, {})
	var bare := _build()
	_counts("голый", bare, errs)
	var bare_proxies := _proxy_count(bare)
	if bare["col"].box_count(CollisionWorld.SET_OVERLAY) != bare_proxies:
		errs.append("без файлов мира в оверлее %d коробок, scatter-proxy насчитал %d"
			% [bare["col"].box_count(CollisionWorld.SET_OVERLAY), bare_proxies])
	if not (bare["built"]["village"] as Dictionary).is_empty():
		errs.append("без файла VillageWorld.build() всё равно что-то построил")
	if not (bare["built"]["home"] as Dictionary).is_empty():
		errs.append("без файла HomeWorld.build() всё равно что-то построил")
	_drop(bare)

	# 2. Только деревня: весь оверлей принадлежит ей. Околица ещё {} — иначе
	# её 15 коробок попали бы в этот счёт и он разошёлся бы с out.boxes.
	_caches({}, {}, null, {}, {})
	var only := _build()
	_counts("деревня", only, errs)
	var village: Dictionary = only["built"]["village"]
	if village.is_empty():
		errs.append("built.village пуст — сборка деревни не вернула ничего")
	else:
		for key: String in ["boxes", "nodes", "shop", "boarded", "graveyard", "stop"]:
			if not village.has(key):
				errs.append("built.village без ключа «%s»" % key)
	var boxes: Array = village.get("boxes", [])
	var overlay: int = only["col"].box_count(CollisionWorld.SET_OVERLAY)
	if boxes.is_empty():
		errs.append("деревня не отдала ни одной твёрдой коробки — сквозь сельпо "
			+ "и заколоченный дом можно пройти насквозь")
	var only_proxies := _proxy_count(only)
	if overlay != boxes.size() + only_proxies:
		errs.append("в оверлее %d коробок, out.boxes и scatter-proxy насчитали %d — "
			% [overlay, boxes.size() + only_proxies]
			+ "test_street_clear меряет полосу деда не по всей геометрии")
	else:
		print("деревня: %d коробок в оверлее" % overlay)
	_drop(only)

	# 3. Деревня и улица вместе. Заколоченный дом отдал свой сплошной объём
	# деревне (street.json house.hollow) — значит, уличных коробок стало
	# на одну меньше, а не больше.
	_caches({}, null, null, {}, {})
	var with_street := _build()
	_counts("деревня+улица", with_street, errs)
	var street: Dictionary = with_street["built"]["street"]
	if street.is_empty():
		errs.append("built.street пуст при живом data/street.json")
	var v2: Array = (with_street["built"]["village"] as Dictionary).get("boxes", [])
	var o2: int = with_street["col"].box_count(CollisionWorld.SET_OVERLAY)
	if o2 <= v2.size():
		errs.append("вместе с улицей в оверлее %d коробок при %d деревенских — "
			% [o2, v2.size()] + "улица потерялась")
	_drop(with_street)

	# 4. Мир целиком.
	_caches(null, null, null, null, null)
	var full := _build()
	_counts("всё вместе", full, errs)
	var home: Dictionary = full["built"]["home"]
	if home.is_empty():
		errs.append("built.home пуст при живом data/home.json")
	elif (home.get("boxes", []) as Array).size() != 4:
		errs.append("home_world.gd выпустил %d коробок мебели Тони вместо четырёх"
			% (home.get("boxes", []) as Array).size())
	_assert_tonya_outside_nav(errs)
	# Оверлей невидим для тех, кто спрашивает мир маской ALL.
	if CollisionWorld.ALL & CollisionWorld.MASK_OVERLAY != 0:
		errs.append("CollisionWorld.ALL включает оверлей — навграф и ai.gd "
			+ "увидят деревню")
	# Узлы, за которые держится глава ДЕРЕВНЯ. Нет узла — точка Interact
	# зарегистрируется, отработает и не покажет ничего: ошибка молчит.
	var nodes: Dictionary = (full["built"]["village"] as Dictionary).get("nodes", {})
	for id: String in ["kovrigin-letter", "shop-key", "shop-rotor", "shop-ledger",
			"boarded-tripod", "boarded-tapes", "grave-wife", "grave-pit",
			"arkady-door", "stop-schedule", "well", "booth", "tractor"]:
		if not nodes.has(id):
			errs.append("built.village.nodes без узла «%s»" % id)
	var hnodes: Dictionary = (full["built"]["home"] as Dictionary).get("nodes", {})
	for id: String in ["kitchen-phone", "kitchen-grater", "kitchen-bowl",
			"kitchen-grater-sink", "kitchen-sugar", "shed-things"]:
		if not hnodes.has(id):
			errs.append("built.home.nodes без узла «%s»" % id)
	_drop(full)

	if errs.is_empty():
		print("test_village_overlay: PASS")
		quit(0)
		return
	print("FAIL test_village_overlay: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


## Подмена кэшей шести оверлеев. {} — «файла нет», null — «читать с диска».
##
## ФАЗА 16. Шестой — СНТ, и он гасится ВМЕСТЕ с околицей: он стоит поверх неё,
## въезжает через проём в её борте и без неё смысла не имеет. Своего параметра
## ему не заводим по той же причине, по какой у него нет своей строки в
## сценарии: включать СНТ без околицы незачем.
func _caches(yard: Variant, street: Variant, village: Variant, home: Variant,
		outskirts: Variant = {}) -> void:
	YardWorld._cache = yard
	StreetWorld._cache = street
	VillageWorld._cache = village
	HomeWorld._cache = home
	OutskirtsWorld._cache = outskirts
	SntWorld._cache = outskirts


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

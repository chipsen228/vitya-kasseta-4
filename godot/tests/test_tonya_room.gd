extends SceneTree


class FakeUi extends RefCounted:
	var lines: Array[String] = []

	func say(line: String, _seconds: float) -> void:
		lines.append(line)


class FakeAudio extends RefCounted:
	var knocks := 0

	func sfx(_id: String) -> bool:
		return false

	func knock(_count: int, _gap: float) -> void:
		knocks += 1


func _initialize() -> void:
	var errs: Array[String] = []
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var b := WorldBuilder.new()
	b.mats = mats
	b.col = col
	b.site = GameData.site()
	var home := HomeWorld.build(b)
	var nodes: Dictionary = home.get("nodes", {})

	for id: String in ["tonya-bed", "tonya-nightstand", "tonya-chest",
		"tonya-chair", "tonya-basin", "tonya-photo"]:
		if not nodes.has(id) or not (nodes[id] is Node3D):
			errs.append("нет узла комнаты Тони: " + id)
	for id: String in ["tonya-bed", "tonya-nightstand", "tonya-chest", "tonya-chair"]:
		if not col.is_blocker_active(id):
			errs.append("нет локальной overlay-коллизии: " + id)
	if col.box_count(CollisionWorld.SET_OVERLAY) != 4:
		errs.append("комната должна добавлять ровно четыре overlay-объёма")

	# Центр проёма и путь в глубину комнаты обязаны принимать капсулу игрока.
	for p: Vector2 in [Vector2(0.60, 13.92), Vector2(0.60, 14.35),
		Vector2(0.55, 15.05)]:
		var hit := col.capsule_hit_d(p.x, 3.62, p.y, p.x, 4.78, p.y, 0.28,
			CollisionWorld.MASK_OVERLAY)
		if not hit.is_empty():
			errs.append("мебель перекрыла проход комнаты в %s" % p)

	var photo: Node3D = nodes.get("tonya-photo")
	if photo == null or photo.get_child_count() < 2:
		errs.append("перевёрнутая фотография не имеет рамки и оборота")
	var bed: Node3D = nodes.get("tonya-bed")
	if bed == null or bed.get_child_count() < 20:
		errs.append("кровать потеряла бельё, нить, вмятину или соляной круг")

	var texts := GameData.texts()
	if not String((texts.get("LOOKS", {}) as Dictionary).get("sealed-door", "")).contains("Тони"):
		errs.append("описание входа не называет комнату Тони")
	if not (texts.get("LOOKS", {}) as Dictionary).has("tonya-photo"):
		errs.append("нет повторного описания фотографии")
	if not (texts.get("BEATS", {}) as Dictionary).has("tonyaPhotoKnock"):
		errs.append("нет отдельной реплики первого стука")

	# Проверяем именно существующий looked-контракт, а не новый save-флаг.
	var interact := Interact.new()
	Interact._register_home(interact, {"world": {"home": {"nodes": {}}}})
	var photo_def: Dictionary = {}
	for def: Dictionary in interact.list:
		if String(def.get("id", "")) == "tonya-photo":
			photo_def = def
			break
	if photo_def.is_empty():
		errs.append("интеракция фотографии не зарегистрирована")
	else:
		var state := GameState.new()
		var ui := FakeUi.new()
		var audio := FakeAudio.new()
		var ctx := {"state": state, "ui": ui, "audio": audio}
		(photo_def["onUse"] as Callable).call(ctx)
		(photo_def["onUse"] as Callable).call(ctx)
		if not state.looked.has("tonya-photo"):
			errs.append("первый осмотр не записан в state.looked")
		if audio.knocks != 1:
			errs.append("стук фотографии должен звучать ровно один раз")
		if ui.lines.size() != 2 or ui.lines[0] == ui.lines[1]:
			errs.append("повторный осмотр не переключился на короткое описание")

	var props := Props.new(mats)
	var key_parts: Array = props.call("_make", "carKeys", {})
	if key_parts.size() < 7:
		errs.append("связка автомобильных ключей не собрана")
	var vd := VillageWorld.data()
	var kk: Array = (vd.get("ARKADY", {}) as Dictionary).get("key", [])
	if kk != [16.48, 1.38, -6.88]:
		errs.append("ключ сельпо не на наружной правой стойке")
	var valya := ValyaWorld.data()
	var sh: Array = (valya.get("GRAVE", {}) as Dictionary).get("shovel", [])
	if sh != [1.70, 0.0, -28.45]:
		errs.append("лопата не следует за новой точкой у насыпи")

	for n: Variant in nodes.values():
		if n is Node:
			(n as Node).free()
	if errs.is_empty():
		print("test_tonya_room: PASS")
		quit(0)
		return
	print("FAIL test_tonya_room: расхождений ", errs.size())
	for e: String in errs:
		print("  - ", e)
	quit(1)

# Приёмка скин-оверлея реквизита (data/props_skin.json).
#
# Главное, что здесь проверяется, — что скин НЕ трогает коллизии. Массив
# props.colliders снимается дважды, с оверлеем и без, и сравнивается до
# миллиметра: именно по нему test_world_parity считает свои 83 коробки
# реквизита, и молчаливый сдвиг хотя бы одной означал бы, что мир разъехался
# с эталоном из-за косметики.
#
# Плюс: каждый id из карты существует среди PROPS, файл модели на месте,
# модель после вписки лежит в габарите процедурной сборки.
#
# Нет data/props_skin.json — тест зелёный и говорит об этом вслух: это
# штатный откат, при котором игра выглядит как до фазы 7.
#
# Прогон:
#   Godot…_console.exe --headless --path godot --script res://tests/test_props_skin.gd
extends SceneTree

const TOL := 1e-6
const FIT_TOL := 0.06        # насколько модель вправе вылезти из габарита, м


func _initialize() -> void:
	var skin := PropsSkin.load_all()
	if skin.map.is_empty():
		print("test_props_skin: data/props_skin.json нет — реквизит процедурный, "
			+ "как в фазе 6. Это штатный откат.")
		print("test_props_skin: PASS")
		quit(0)
		return

	var pdata := GameData.props()
	var list: Array = pdata["PROPS"]
	var known: Dictionary = {}
	for p: Variant in list:
		if p is Dictionary and (p as Dictionary).has("id"):
			known[String((p as Dictionary)["id"])] = true
	for p: Variant in pdata.get("DYNAMIC_PROPS", []):
		if p is Dictionary and (p as Dictionary).has("id"):
			known[String((p as Dictionary)["id"])] = true

	var fails := 0
	for id: String in skin.map.keys():
		var e: Dictionary = skin.map[id]
		if not known.has(id):
			printerr("%s: такого предмета нет ни в PROPS, ни в DYNAMIC_PROPS" % id)
			fails += 1
		var path := PropsSkin.MODEL_DIR + String(e["file"])
		if not ResourceLoader.exists(path):
			printerr("%s: нет файла модели %s" % [id, path])
			fails += 1

	# Два прогона мира: без скина и с ним.
	var plain := _run(list, null)
	var skinned := _run(list, skin)

	var a: Array = plain["colliders"]
	var b: Array = skinned["colliders"]
	if a.size() != b.size():
		printerr("коллайдеров стало %d вместо %d" % [b.size(), a.size()])
		fails += 1
	else:
		var moved := 0
		for i in a.size():
			var x: Dictionary = a[i]
			var y: Dictionary = b[i]
			for k: String in ["cx", "cy", "cz", "hx", "hy", "hz", "yaw"]:
				if absf(float(x[k]) - float(y[k])) > TOL:
					moved += 1
					if moved <= 5:
						printerr("коллайдер #%d: %s %.6f вместо %.6f"
							% [i, k, float(y[k]), float(x[k])])
					break
		if moved > 0:
			printerr("скин сдвинул %d коллайдеров из %d — так нельзя" % [moved, a.size()])
			fails += 1
		else:
			print("коллайдеры: %d коробок совпали (допуск %.7f)" % [a.size(), TOL])

	print(skin.report())
	fails += int(skinned["fit_fails"])

	if fails == 0:
		print("test_props_skin: PASS")
		quit(0)
	else:
		printerr("test_props_skin: FAIL (%d расхождений)" % fails)
		quit(1)


func _run(list: Array, skin: Variant) -> Dictionary:
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	WorldBuilder.build(root, mats, col)
	var props := Props.new(mats)
	props.load_models(list)
	props.build(root, list, col)

	var fit_fails := 0
	if skin != null:
		# Габариты снимаем ДО того, как процедурные дети спрячутся: после
		# оверлея сравнивать будет уже не с чем.
		var before: Dictionary = {}
		for id: String in (skin as PropsSkin).map.keys():
			var h: Node3D = props.get_prop(id)
			if h != null:
				before[id] = PropsSkin.local_aabb(h)
		(skin as PropsSkin).apply(props)
		for id: String in (skin as PropsSkin).applied:
			var h: Node3D = props.get_prop(id)
			var model: Node3D = h.get_node_or_null("skin") as Node3D
			if model == null:
				continue
			var want: AABB = before[id]
			var got := model.transform * PropsSkin.local_aabb(model)
			var over := maxf(
				maxf(want.position.x - got.position.x, want.position.z - got.position.z),
				maxf(got.end.x - want.end.x, got.end.z - want.end.z))
			if over > FIT_TOL:
				printerr("%s: модель вылезает из габарита на %.3f м (допуск %.2f)"
					% [id, over, FIT_TOL])
				fit_fails += 1

	var out: Array = []
	for c: Dictionary in props.colliders:
		out.append(c.duplicate())
	props.dispose()
	root.free()
	return {"colliders": out, "fit_fails": fit_fails}

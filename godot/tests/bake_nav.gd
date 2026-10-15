# Выпечка навграфа деда: мир + реквизит + NavGraph.build → data/nav_baked.json.
#
# Зачем отдельный шаг. Построение графа — это растеризация всех комнат пробой
# капсулой и валидация каждого ребра сэмплированием с шагом 0.18: в браузере
# оригинал делал это за доли секунды на октодеревьях, в GDScript та же работа
# стоит десятки секунд. Загрузку игры этим тормозить нельзя, поэтому граф печётся
# заранее, а рантайм зовёт NavGraph.from_baked() и получает готовые узлы.
#
# Запертость дверей в файл не попадает намеренно: граф строится с открытыми
# дверями (запертость — это вес ребра, а не геометрия), и во время игры вес
# считается живьём через CollisionWorld.is_blocker_active. Поэтому перепекать
# файл после поворота ключа не нужно — только после правки site.json/props.json,
# world_builder.gd, props.gd или самого nav_graph.gd.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/bake_nav.gd

extends SceneTree


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()

	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)
	# DYNAMIC_PROPS сюда не идут по той же причине, что и в test_probes.gd:
	# на старте они скрыты и коллайдеров не дают, а эталон снят со старта.
	var world_ms := Time.get_ticks_msec() - t0
	print("мир: статики %d, блокеров %d, реквизита %d (%d мс)"
		% [col.box_count(CollisionWorld.SET_STATIC),
		col.box_count(CollisionWorld.SET_BLOCKERS),
		col.box_count(CollisionWorld.SET_PROPS), world_ms])

	var blockers: Array = built["blockers"]
	var nav := NavGraph.build(col, blockers)

	for w: String in nav.warnings:
		printerr("предупреждение построения: %s" % w)

	var layers: Array = nav.layer_list()
	var total_nodes := 0
	var total_edges := 0
	var stats := nav.stats()
	print("по слоям:")
	for layer: String in layers:
		var s: Dictionary = stats[layer]
		var list: Array = nav.nodes(layer)
		var directed := 0
		for n: Dictionary in list:
			var edges: Array = n["edges"]
			directed += edges.size()
		total_nodes += list.size()
		total_edges += directed
		print("  %-7s узлов %3d, из них дверей %2d, рёбер %5.1f, компонентов %d"
			% [layer, int(s["nodes"]), int(s["doors"]), float(s["edges"]), int(s["components"])])
	print("итого: слоёв %d, узлов %d, рёбер (направленных) %d — эталон 5 / 61 / 156"
		% [layers.size(), total_nodes, total_edges])
	print("граф собран за %.0f мс" % nav.build_ms)

	var ok := nav.save_baked()
	props.dispose()
	root.free()

	if not ok:
		printerr("не записался %s" % NavGraph.BAKED_PATH)
		quit(1)
		return
	if total_nodes == 0:
		printerr("граф пуст — печь нечего")
		quit(1)
		return
	print("записан %s, всего %d мс" % [NavGraph.BAKED_PATH, Time.get_ticks_msec() - t0])
	print("bake_nav: OK")
	quit(0)

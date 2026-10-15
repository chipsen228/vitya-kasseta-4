extends SceneTree


func _initialize() -> void:
	var errs: Array[String] = []
	_test_resolver(errs)
	_test_intentional_moves(errs)
	_test_orchard_pairs(errs)
	_test_single_story_sign(errs)
	if errs.is_empty():
		print("test_tree_clearance: PASS")
		quit(0)
		return
	print("FAIL test_tree_clearance: расхождений ", errs.size())
	for err: String in errs:
		print("  - ", err)
	quit(1)


func _test_resolver(errs: Array[String]) -> void:
	var blocked := [Rect2(-0.20, -0.20, 0.40, 0.40)]
	var a: Variant = StreetWorld.resolve_tree_position("stable", Vector2.ZERO, 0.10,
		Rect2(-2.0, -2.0, 4.0, 4.0), blocked)
	var b: Variant = StreetWorld.resolve_tree_position("stable", Vector2.ZERO, 0.10,
		Rect2(-2.0, -2.0, 4.0, 4.0), blocked)
	if not (a is Vector2) or a != b:
		errs.append("resolve_tree_position недетерминирован или отказал при свободной сетке")
	elif not is_equal_approx((a as Vector2).x, -0.5) \
			or not is_equal_approx((a as Vector2).y, 0.0):
		errs.append("resolver выбрал не ближайшую устойчивую точку: %s" % [a])
	var denied: Variant = StreetWorld.resolve_tree_position("denied", Vector2.ZERO, 0.4,
		Rect2(-0.3, -0.3, 0.6, 0.6), [])
	if denied != null:
		errs.append("resolver не вернул отказ, когда крона не помещается в bounds")


func _test_intentional_moves(errs: Array[String]) -> void:
	var expected := [Vector2(-19.5, -16.5), Vector2(18.0, -16.5),
		Vector2(-14.0, 34.0), Vector2(-10.0, 35.0),
		Vector2(10.0, 34.0), Vector2(14.0, 35.0)]
	var found: Array[Vector2] = []
	for prop: Dictionary in GameData.props().get("PROPS", []):
		if String(prop.get("m", "")) not in ["tree", "tree-tall"]:
			continue
		var at: Array = prop.get("at", [])
		if at.size() == 3:
			found.append(Vector2(float(at[0]), float(at[2])))
	for pos: Vector2 in expected:
		if not found.has(pos):
			errs.append("нет намеренно перенесённого дерева в %s" % [pos])


func _test_orchard_pairs(errs: Array[String]) -> void:
	var orchard: Dictionary = YardWorld.data().get("ORCHARD", {})
	var rows: Array = orchard.get("trees", [])
	var resolved := YardWorld.resolved_orchard(orchard)
	if resolved.size() != rows.size():
		errs.append("яблони приняты не атомарно: строк %d, пар %d" %
			[rows.size(), resolved.size()])
	for i in rows.size():
		if not resolved.has(i):
			errs.append("потерян исходный индекс apple-tree-%d/apples-%d" % [i, i])
	var moved: Array = rows[2] if rows.size() > 2 else []
	if moved.size() != 3 or Vector2(float(moved[0]), float(moved[1])) != Vector2(8.8, 28.3):
		errs.append("конфликтная яблоня #2 не перенесена в восточный угол")


func _test_single_story_sign(errs: Array[String]) -> void:
	var alley_ok := 0
	for prop: Dictionary in GameData.props().get("PROPS", []):
		var at: Array = prop.get("at", [])
		if String(prop.get("m", "")) == "ok-sign" and at.size() == 3 \
				and absf(float(at[0]) + 25.9) < 0.01:
			alley_ok += 1
	if alley_ok != 0:
		errs.append("старый ok-sign у переулка всё ещё создаётся")
	var sign: Dictionary = ValyaWorld.data().get("SIGN", {})
	if sign.is_empty():
		errs.append("единственный сюжетный farm-sign отсутствует")

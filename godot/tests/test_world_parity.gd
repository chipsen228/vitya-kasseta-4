# Приёмка мира: коробки коллизий против parity/world_boxes.json.
#
# Сверяются три набора — статика, блокеры, коллайдеры реквизита: сначала счётчики,
# потом мультимножества AABB (сортировка по компонентам, допуск 1e-3 на элемент).
# Повёрнутые коробки (пандусы лестниц, скаты крыш) сверяются своим мировым AABB —
# в эталоне снят именно он, computeBoundingBox() повёрнутой геометрии.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_world_parity.gd

extends SceneTree

const TOL := 1e-3
const SHOW := 10


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

	var ref := _read_json("res://parity/world_boxes.json")
	if ref.is_empty():
		printerr("нет parity/world_boxes.json")
		quit(1)
		return

	var fails := 0
	fails += _check_count("collide", col.box_count(CollisionWorld.SET_STATIC), int(ref["collideCount"]))
	fails += _check_count("blockers", col.box_count(CollisionWorld.SET_BLOCKERS), int(ref["blockerCount"]))
	fails += _check_count("propColliders", col.box_count(CollisionWorld.SET_PROPS), int(ref["propColliderCount"]))

	fails += _check_set("collide", col, CollisionWorld.SET_STATIC, ref["collide"])
	var blocker_boxes: Array = []
	for b: Dictionary in ref["blockers"]:
		blocker_boxes.append(b["box"])
	fails += _check_set("blockers", col, CollisionWorld.SET_BLOCKERS, blocker_boxes)
	fails += _check_set("propColliders", col, CollisionWorld.SET_PROPS, ref["propColliders"])

	# Имена блокеров: по ним главы запирают двери и ворота.
	for b: Dictionary in ref["blockers"]:
		if not col.is_blocker_active(String(b["id"])):
			printerr("нет блокера с id %s" % b["id"])
			fails += 1

	print("треугольников в collide-геометрии: %d (эталон 3885)" % int(built["triangles"]))
	print("время: %d мс" % (Time.get_ticks_msec() - t0))
	props.dispose()
	root.free()
	if fails == 0:
		print("test_world_parity: PASS")
		quit(0)
	else:
		printerr("test_world_parity: FAIL (%d расхождений)" % fails)
		quit(1)


func _check_count(name: String, got: int, want: int) -> int:
	if got == want:
		print("%s: %d — сходится" % [name, got])
		return 0
	printerr("%s: получено %d, эталон %d" % [name, got, want])
	return 1


func _check_set(name: String, col: CollisionWorld, set_id: int, want_raw: Array) -> int:
	var got: Array = []
	for i in col.box_count(set_id):
		got.append(col.box_aabb_d(set_id, i))
	var want: Array = []
	for a: Array in want_raw:
		want.append(PackedFloat64Array([
			float(a[0]), float(a[1]), float(a[2]), float(a[3]), float(a[4]), float(a[5])
		]))
	got.sort_custom(_cmp_box)
	want.sort_custom(_cmp_box)
	var n := mini(got.size(), want.size())
	var bad := 0
	for i in n:
		var g: PackedFloat64Array = got[i]
		var w: PackedFloat64Array = want[i]
		var diff := 0.0
		for k in 6:
			diff = maxf(diff, absf(g[k] - w[k]))
		if diff <= TOL:
			continue
		bad += 1
		if bad <= SHOW:
			printerr("%s #%d: получено %s, эталон %s (расхождение %.5f)"
				% [name, i, _fmt(g), _fmt(w), diff])
	if got.size() != want.size():
		bad += absi(got.size() - want.size())
	if bad == 0:
		print("%s: %d коробок сошлись" % [name, n])
	else:
		printerr("%s: %d расхождений из %d" % [name, bad, want.size()])
	return bad


func _cmp_box(a: PackedFloat64Array, b: PackedFloat64Array) -> bool:
	for k in 6:
		if absf(a[k] - b[k]) > 1e-9:
			return a[k] < b[k]
	return false


func _fmt(a: PackedFloat64Array) -> String:
	return "[%.4f %.4f %.4f %.4f %.4f %.4f]" % [a[0], a[1], a[2], a[3], a[4], a[5]]


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}

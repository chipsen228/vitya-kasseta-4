# Приёмка четвёртого набора коллизий у СНТ (фаза 16).
#
# Пишется ДО сборки района — по тому же правилу, по которому в фазе 0 пишутся
# сторожа: район втрое больше всего, что строилось до него, и одна забытая
# collide = true в snt_world.gd добавит коробку в SET_STATIC. Паритет
# разъедется на единицу, навграф деда посчитается по другому дому, и заметить
# это можно будет только по тому, что дед перестал ходить в комнату, в которую
# ходил.
#
# Мир собирается ДВАЖДЫ — с data/snt.json и без него, — и оба раза три набора
# прототипа обязаны дать ровно 311/4/83 и 3885 треугольников.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_snt_overlay.gd
extends SceneTree

const WANT_STATIC := 311
const WANT_BLOCKERS := 4
const WANT_PROPS := 83
const WANT_TRIS := 3885


func _initialize() -> void:
	var errs: Array[String] = []

	# 1. Мир БЕЗ СНТ. Кэш подменяется пустым словарём — ровно то же, что
	# удалить data/snt.json.
	SntWorld._cache = {}
	var off := _build()
	_counts("без СНТ", off, errs)
	var overlay_off: int = (off["col"] as CollisionWorld).box_count(CollisionWorld.SET_OVERLAY)
	if not ((off["built"] as Dictionary).get("snt", {}) as Dictionary).is_empty():
		errs.append("без файла SntWorld.build() всё равно что-то построил")
	_drop(off)

	# 2. Мир С СНТ. Те же четыре числа плюс выросший четвёртый набор.
	SntWorld._cache = null
	var on := _build()
	_counts("с СНТ", on, errs)
	var col: CollisionWorld = on["col"]
	var overlay_on := col.box_count(CollisionWorld.SET_OVERLAY)
	var snt: Dictionary = (on["built"] as Dictionary).get("snt", {}) as Dictionary
	if snt.is_empty():
		errs.append("built.snt пуст — сборка района не вернула ничего")
	elif overlay_on <= overlay_off:
		errs.append("data/snt.json есть, а в оверлее не прибавилось ни коробки: "
			+ "район собрался без твёрдой геометрии")
	else:
		print("оверлей: %d коробок (СНТ %d, остальные %d)"
			% [overlay_on, overlay_on - overlay_off, overlay_off])
		for key: String in ["enabled", "boxes", "nodes", "roads", "plots"]:
			if not snt.has(key):
				errs.append("built.snt без ключа «%s»" % key)
	_drop(on)

	if errs.is_empty():
		print("test_snt_overlay: PASS")
		quit(0)
		return
	print("FAIL test_snt_overlay: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


func _counts(tag: String, w: Dictionary, errs: Array[String]) -> void:
	var col: CollisionWorld = w["col"]
	var got := [
		["collide", col.box_count(CollisionWorld.SET_STATIC), WANT_STATIC],
		["blockers", col.box_count(CollisionWorld.SET_BLOCKERS), WANT_BLOCKERS],
		["propColliders", col.box_count(CollisionWorld.SET_PROPS), WANT_PROPS],
	]
	for row: Array in got:
		if int(row[1]) != int(row[2]):
			errs.append("%s: %s = %d, а эталон %d" % [tag, row[0], int(row[1]), int(row[2])])
	var tris := int((w["built"] as Dictionary)["triangles"])
	if tris != WANT_TRIS:
		errs.append("%s: треугольников %d, а эталон %d" % [tag, tris, WANT_TRIS])


func _build() -> Dictionary:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	# Реквизит — как в test_world_parity: без него SET_PROPS пуст и проверка
	# 83 ничего не значит.
	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)
	return {"col": col, "root": root, "built": built, "props": props}


func _drop(w: Dictionary) -> void:
	(w["props"] as Props).dispose()
	(w["root"] as Node3D).free()

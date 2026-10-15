# Зазор между новыми постройками и навграфом деда (фаза 11).
#
# ЗАЧЕМ. SET_OVERLAY невидим для nav_graph.gd и для ai.gd: они спрашивают мир
# маской, а CollisionWorld.ALL четвёртый набор не включает. Значит, дед пройдёт
# сквозь баню и погреб насквозь — и ни один существующий тест этого не поймает,
# потому что для всех них мира там просто нет. Единственная защита — держать
# постройки в стороне от узлов и рёбер слоя plot, и это надо мерить, а не
# помнить.
#
# Меряется по built.yard.boxes, а не по числам из yard.json: коробку добавят
# в код, а файл забудут — и зазор окажется непроверенным ровно там, где он
# и разъехался.
#
# Вторая проверка — против ловушки, спрятанной в тестах точек страха.
# test_startle_points и test_haunt_points считают видимость лучом только по
# статике и реквизиту (MASK_STATIC | MASK_PROPS), а стены бани и погреба живут
# в четвёртом наборе. Точка внутри бани проходит те тесты и оказывается
# замурованной в игре: фигура появляется за стеной, флаг однократности
# сгорает, второй попытки не будет.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_yard_nav_clear.gd
extends SceneTree

const NAV_BAKED := "res://data/nav_baked.json"
const LAYER := "plot"
const MIN_GAP := 0.60        # ближе этого узел или ребро к постройке не подходит
const EDGE_STEP := 0.05      # шаг развёртки ребра
const SHOW := 8


func _initialize() -> void:
	var errs: Array[String] = []

	YardWorld._cache = null
	StreetWorld._cache = null
	var w := _build()
	var yard: Dictionary = (w["built"] as Dictionary).get("yard", {})
	if yard.is_empty():
		print("test_yard_nav_clear: SKIP — нет data/yard.json, участок не построен")
		_drop(w)
		quit(0)
		return

	var boxes: Array = yard.get("boxes", [])
	if boxes.is_empty():
		errs.append("участок не отдал ни одной твёрдой коробки — мерить нечего")

	var nodes := _plot_nodes()
	if nodes.is_empty():
		errs.append("в %s нет узлов слоя «%s» — навграф перепечён не тем"
			% [NAV_BAKED, LAYER])

	# 1. Узлы.
	var worst := INF
	var worst_id := ""
	var bad := 0
	for id: String in nodes.keys():
		var n: Dictionary = nodes[id]
		var g := _gap_point(boxes, float(n["x"]), float(n["z"]))
		if g < worst:
			worst = g
			worst_id = id
		if g < MIN_GAP:
			bad += 1
			if bad <= SHOW:
				errs.append("узел %s в %.2f м от постройки (нужно %.2f)"
					% [id, g, MIN_GAP])

	# 2. Рёбра. Развёртка шагом EDGE_STEP: аналитика «отрезок против коробки»
	# здесь ничего не выигрывает, а ошибиться в ней можно молча.
	var seen: Dictionary = {}
	var bad_edges := 0
	for id: String in nodes.keys():
		var n: Dictionary = nodes[id]
		for e: Dictionary in n.get("edges", []):
			var to := String(e["to"])
			if not nodes.has(to):
				continue
			var key: String = id + "|" + to if id < to else to + "|" + id
			if seen.has(key):
				continue
			seen[key] = true
			var m: Dictionary = nodes[to]
			var g := _gap_segment(boxes, float(n["x"]), float(n["z"]),
				float(m["x"]), float(m["z"]))
			if g < worst:
				worst = g
				worst_id = key
			if g < MIN_GAP:
				bad_edges += 1
				if bad_edges <= SHOW:
					errs.append("ребро %s подходит к постройке на %.2f м (нужно %.2f)"
						% [key, g, MIN_GAP])

	print("узлов слоя %s: %d, рёбер: %d" % [LAYER, nodes.size(), seen.size()])
	print("самое тесное место: %s, %.2f м" % [worst_id, worst])
	if bad > SHOW:
		errs.append("…и ещё %d узлов ближе %.2f м" % [bad - SHOW, MIN_GAP])
	if bad_edges > SHOW:
		errs.append("…и ещё %d рёбер ближе %.2f м" % [bad_edges - SHOW, MIN_GAP])

	# 3. Точки страха внутри новых построек: луч ДО них должен быть чист с учётом
	# четвёртого набора, иначе фигуру ставят за стеной, а тесты точек этого
	# не видят.
	_walled_in(w, boxes, errs)

	_drop(w)

	if errs.is_empty():
		print("test_yard_nav_clear: PASS")
		quit(0)
		return
	print("FAIL test_yard_nav_clear: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ---------------------------------------------------------------- зазоры ----

## Расстояние в плане от точки до ближайшей коробки. Внутри коробки — ноль.
static func _gap_point(boxes: Array, x: float, z: float) -> float:
	var best := INF
	for bx: AABB in boxes:
		var dx := maxf(maxf(bx.position.x - x, x - (bx.position.x + bx.size.x)), 0.0)
		var dz := maxf(maxf(bx.position.z - z, z - (bx.position.z + bx.size.z)), 0.0)
		best = minf(best, sqrt(dx * dx + dz * dz))
	return best


static func _gap_segment(boxes: Array, x0: float, z0: float, x1: float, z1: float) -> float:
	var ln := sqrt((x1 - x0) * (x1 - x0) + (z1 - z0) * (z1 - z0))
	var n := maxi(1, int(ceil(ln / EDGE_STEP)))
	var best := INF
	for i in n + 1:
		var q := float(i) / float(n)
		best = minf(best, _gap_point(boxes, x0 + (x1 - x0) * q, z0 + (z1 - z0) * q))
	return best


# --------------------------------------------------------- замурованность ----

# Точки страха, попавшие ВНУТРЬ новой постройки, проверяются лучом с маской,
# включающей MASK_OVERLAY: из триггера до фигуры должно быть видно. Точки вне
# построек не трогаем — за них отвечают test_startle_points и test_haunt_points.
func _walled_in(w: Dictionary, boxes: Array, errs: Array[String]) -> void:
	var col: CollisionWorld = w["col"]
	var mask := CollisionWorld.MASK_STATIC | CollisionWorld.MASK_PROPS \
		| CollisionWorld.MASK_OVERLAY
	var yard: Dictionary = (w["built"] as Dictionary).get("yard", {})
	var foot: Array = _footprints(yard)
	var checked := 0

	for p: Dictionary in Startle.POINTS:
		var at: Array = p.get("at", [])
		var pos: Array = p.get("pos", [])
		if at.size() != 3:
			continue
		var trigger_in := _in_foot(foot, float(at[0]), float(at[2]))
		var fig_in := pos.size() == 3 and _in_foot(foot, float(pos[0]), float(pos[2]))
		if not trigger_in and not fig_in:
			continue
		checked += 1
		if trigger_in and col.point_hit(float(at[0]), float(at[1]) + 0.95,
				float(at[2]), CollisionWorld.MASK_OVERLAY):
			errs.append("испуг «%s»: триггер стоит внутри стены" % String(p.get("id", "?")))
		if pos.size() != 3:
			continue
		if col.point_hit(float(pos[0]), float(pos[1]) + 0.95, float(pos[2]),
				CollisionWorld.MASK_OVERLAY):
			errs.append("испуг «%s»: фигура замурована в стене" % String(p.get("id", "?")))
			continue
		var eye := Vector3(float(at[0]), float(at[1]) + 1.62, float(at[2]))
		var head := Vector3(float(pos[0]), float(pos[1]) + 1.40, float(pos[2]))
		if String(p.get("kind", "")) != "sign" and not _clear(col, eye, head, mask):
			errs.append("испуг «%s» замурован: из триггера фигуру не видно "
				% String(p.get("id", "?")) + "сквозь стену четвёртого набора")

	# У haunt точек своей позиции обзора в контракте нет — в новых точках она
	# дописана полем seen_from ровно ради этой проверки. Точка без него внутри
	# постройки проверяется только на «не в стене».
	var haunt := Haunt.new(null, null, col, 1)
	for p: Dictionary in haunt.points:
		var pos: Array = p.get("pos", [])
		if pos.size() != 3 or not _in_foot(foot, float(pos[0]), float(pos[2])):
			continue
		checked += 1
		if col.point_hit(float(pos[0]), float(pos[1]) + 1.40, float(pos[2]),
				CollisionWorld.MASK_OVERLAY):
			errs.append("мелькание «%s»: фигура замурована в стене" % String(p.get("id", "?")))
			continue
		var seen: Array = p.get("seen_from", [])
		if seen.size() != 3:
			errs.append("мелькание «%s» стоит внутри постройки без seen_from — "
				% String(p.get("id", "?")) + "проверить видимость нечем")
			continue
		var from := Vector3(float(seen[0]), float(seen[1]) + 1.62, float(seen[2]))
		var head2 := Vector3(float(pos[0]), float(pos[1]) + 1.58, float(pos[2]))
		if not _clear(col, from, head2, mask):
			errs.append("мелькание «%s» замуровано: из точки обзора его не видно"
				% String(p.get("id", "?")))
	print("точек страха внутри новых построек: %d" % checked)


## Габариты новых построек в плане. Не коробки стен, а весь след: точка внутри
## бани может стоять в полуметре от любой стены и всё равно быть внутри.
static func _footprints(yard: Dictionary) -> Array:
	var out: Array = []
	for key: String in ["banya", "shed"]:
		var d: Dictionary = yard.get(key, {})
		if d.is_empty():
			continue
		var xr: Array = d.get("x", [])
		var zr: Array = d.get("z", [])
		if xr.size() == 2 and zr.size() == 2:
			out.append([float(xr[0]), float(xr[1]), float(zr[0]), float(zr[1])])
	return out


static func _in_foot(foot: Array, x: float, z: float) -> bool:
	for r: Array in foot:
		if x >= r[0] and x <= r[1] and z >= r[2] and z <= r[3]:
			return true
	return false


static func _clear(col: CollisionWorld, a: Vector3, b: Vector3, mask: int) -> bool:
	var d := b - a
	var ln := d.length()
	if ln < 0.001:
		return true
	var n := maxi(2, int(ceil(ln / 0.12)))
	for i in range(1, n):
		var p := a + d * (float(i) / float(n))
		if col.point_hit(p.x, p.y, p.z, mask):
			return false
	return true


# ------------------------------------------------------------- служебное ----

func _plot_nodes() -> Dictionary:
	var out: Dictionary = {}
	var f := FileAccess.open(NAV_BAKED, FileAccess.READ)
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return out
	for n: Dictionary in (parsed as Dictionary).get("nodes", []):
		if String(n.get("layer", "")) == LAYER:
			out[String(n["id"])] = n
	return out


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

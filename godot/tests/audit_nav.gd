# Приёмка навигации деда: порт tools/audit-nav.js + сверка с эталоном браузера.
#
# Сначала сверяется испечённый граф с parity/nav_graph.json: счётчики слоёв,
# узлов и рёбер, потом мультимножество узлов по (layer, kind, x, z) с допуском
# 1e-3 и рёбра парами узлов. Расхождения печатаются с координатами. Часть клеток
# растеризации ложится ровно на грань коробки, и вердикт пробы там решают
# последние биты double и порядок треугольников в октодереве оригинала (та же
# природа, что у «вырожденных» клеток в test_probes.gd) — узел тесной комнаты
# от такого флипа съезжает ровно на одну клетку 0.25. Каждый случай разобран
# глазами и внесён ПОИМЁННО в EXPLAINED_SHIFTS / EXPLAINED_LOST_EDGES; слепого
# бюджета нет, любое новое расхождение — FAIL.
#
# Дальше — пять вопросов audit-nav.js, на каждый ответ числом:
#   · компонентов связности по слою. Ровно один: два компонента значит, что
#     половина этажа для деда не существует;
#   · узлы, не прошедшие пробу. Ноль: узел в стене — точка, из которой нет шага;
#   · рёбра с непроходимым коридором. Ноль: ребро — обещание пройти по прямой,
#     и ИИ идёт по нему буквально;
#   · комнаты без узлов. Ровно те, что выводятся из data/nav.json (banRooms плюс
#     banRects с полем place), а не список руками: список протухнет молча;
#   · 600 секунд патруля на слой при dt = 1/30. Виртуальный дед идёт по кольцу
#     patrol() с радиусами достижения и скоростью ai.js, на каждом шаге пробуется
#     его капсула. Застревание — меньше 0.35 м за две секунды. Ноль срабатываний.
#
# Радиус пробы здесь 0.32 — тот, которым ходит дед. Отдельно помечается, что
# отваливается только от него и проходит при 0.30: два сантиметра решают на
# проёмах 0.70 м, и чинится это по-разному.
#
# Двери на время проверки снимаются (граф строился с открытыми) и ОБЯЗАТЕЛЬНО
# возвращаются в конце: снятый блокер — это открытая настежь входная дверь.
#
# Прогон (перед ним — tests/bake_nav.gd, иначе граф соберётся здесь же и это
# добавит десятки секунд):
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/audit_nav.gd
# То же самое, но с построением графа с нуля (проверить, что испечённое свежее):
#   ... --script res://tests/audit_nav.gd -- --fresh

extends SceneTree

const R := 0.32              # радиус капсулы деда
const R_THIN := 0.30         # им различаем «тесно деду» и «занято вообще»
const DT := 1.0 / 30.0
const SIM_SECONDS := 600.0
const SPEED := 0.78          # м/с на патруле
const REACH_DOOR := 0.28     # радиус достижения дверного узла
const REACH_ROOM := 0.55     # радиус достижения комнатного узла
const STUCK_WINDOW := 2.0    # окно детектора застревания, с
const STUCK_DIST := 0.35     # меньше этого за окно — застрял
const SHOW := 10             # сколько проблем печатать поимённо
const PARITY_TOL := 1e-3
# Поимённо объяснённые расхождения с эталоном. Растеризация пробует клетки 0.25
# капсулой r 0.32, и лезвийный флип на границе (test_probes: 37/39690, среди них
# floor1 и plot при обоих радиусах) сдвигает узел тесной комнаты ровно на одну
# клетку: у подпола это граница banRect-ниши за банками, у прихожей — кромки
# дверных проёмов. Инварианты при сдвиге целы (проба узла, коридоры рёбер,
# связность, патруль — проверяются ниже). Ключ — id эталонного узла, значение —
# куда он съехал у нас (x, z). Любой НЕ перечисленный сдвиг — FAIL.
const EXPLAINED_SHIFTS := {
	"cellar:cellar#1": Vector2(0.65, 10.10),   # эталон [0.40, 9.85]: +1 клетка по x и z
	"cellar:cellar#2": Vector2(-2.85, 13.85),  # эталон [-3.10, 13.60]: +1 клетка по x и z
	"floor1:hall#1": Vector2(-3.05, 13.65),    # эталон [-3.05, 13.90]: −1 клетка по z
}
# Рёбра, пропавшие следствием сдвига узла: из новой позиции кратчайший коридор
# не проходит edge_clear. Связность слоя цела — это отдельно проверяет
# _invariants по компонентам.
const EXPLAINED_LOST_EDGES := ["cellar:cellar#2|cellar:cellar#3"]

var _col: CollisionWorld
var _nav: NavGraph


func _initialize() -> void:
	var t0 := Time.get_ticks_msec()

	var mats := Materials.new()
	mats.load_all()
	_col = CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, _col)
	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], _col)

	var blockers: Array = built["blockers"]
	# По умолчанию проверяется ровно тот файл, который поедет в игру. Ключ
	# «-- --fresh» заставляет собрать граф с нуля: так видно, что испечённое
	# не протухло и не подложено руками.
	var fresh := OS.get_cmdline_user_args().has("--fresh") or OS.get_cmdline_args().has("--fresh")
	var baked := FileAccess.file_exists(NavGraph.BAKED_PATH)
	if fresh or not baked:
		_nav = NavGraph.build(_col, blockers)
		if baked:
			print("граф: собран с нуля по ключу --fresh за %.0f мс" % _nav.build_ms)
		else:
			print("граф: %s нет, собран на месте за %.0f мс" % [NavGraph.BAKED_PATH, _nav.build_ms])
	else:
		_nav = NavGraph.from_baked(_col, blockers)
		print("граф: испечённый %s" % NavGraph.BAKED_PATH)
	for w: String in _nav.warnings:
		print("предупреждение построения: %s" % w)

	# Двери снимаем на всё время проверки — граф строился с открытыми.
	var saved := PackedByteArray()
	for b: Dictionary in blockers:
		var bid := String(b["id"])
		saved.append(1 if _col.is_blocker_active(bid) else 0)
		_col.set_blocker_active(bid, false)

	var fails := 0
	fails += _parity_check()
	fails += _invariants()

	# Возврат обязателен: снятый блокер — это открытая настежь входная дверь
	# и ворота на всю оставшуюся сессию (известная грабля audit-reach.js).
	for i in blockers.size():
		var b2: Dictionary = blockers[i]
		_col.set_blocker_active(String(b2["id"]), saved[i] != 0)

	props.dispose()
	root.free()

	print("проверка заняла %.1f с" % ((Time.get_ticks_msec() - t0) / 1000.0))
	if fails == 0:
		print("audit_nav: PASS")
		quit(0)
	else:
		printerr("audit_nav: FAIL (%d расхождений)" % fails)
		quit(1)


# ------------------------------------------------------------------
# 1. Сверка с эталоном браузера
# ------------------------------------------------------------------

func _parity_check() -> int:
	var ref := _read_json("res://parity/nav_graph.json")
	if ref.is_empty():
		printerr("нет parity/nav_graph.json — сверять не с чем")
		return 1

	var fails := 0
	var got_layers: Array = _nav.layer_list()
	var ref_layers: Array = ref.get("layers", [])
	if ", ".join(PackedStringArray(got_layers)) != ", ".join(PackedStringArray(ref_layers)):
		printerr("слои: получено [%s], эталон [%s]"
			% [", ".join(PackedStringArray(got_layers)), ", ".join(PackedStringArray(ref_layers))])
		fails += 1

	var ref_nodes: Array = ref.get("nodes", [])
	var got_nodes: Array = []
	for layer: String in got_layers:
		for n: Dictionary in _nav.nodes(layer):
			got_nodes.append(n)

	# Счётчики по слоям — первое, что расходится, если поехала растеризация.
	var got_cnt := _count_by_layer(got_nodes)
	var ref_cnt := _count_by_layer(ref_nodes)
	var seen_layers: Dictionary = {}
	for l: String in got_cnt.keys():
		seen_layers[l] = true
	for l: String in ref_cnt.keys():
		seen_layers[l] = true
	var keys: Array = seen_layers.keys()
	keys.sort()
	for l: String in keys:
		var g: Array = got_cnt.get(l, [0, 0])
		var w: Array = ref_cnt.get(l, [0, 0])
		var mark := ""
		if int(g[0]) != int(w[0]) or int(g[1]) != int(w[1]):
			mark = "   ← расходится"
		print("  %-7s узлов %3d (эталон %3d), рёбер %3d (эталон %3d)%s"
			% [l, int(g[0]), int(w[0]), int(g[1]), int(w[1]), mark])

	# Мультимножество узлов: пары ищутся жадно по (layer, kind, x, z).
	var used := PackedByteArray()
	used.resize(got_nodes.size())
	var missing: Array = []
	for rn: Dictionary in ref_nodes:
		var found := -1
		for i in got_nodes.size():
			if used[i] != 0:
				continue
			var g: Dictionary = got_nodes[i]
			if String(g["layer"]) != String(rn["layer"]) or String(g["kind"]) != String(rn["kind"]):
				continue
			if absf(float(g["x"]) - float(rn["x"])) > PARITY_TOL:
				continue
			if absf(float(g["z"]) - float(rn["z"])) > PARITY_TOL:
				continue
			found = i
			break
		if found < 0:
			missing.append(rn)
		else:
			used[found] = 1
	var extra: Array = []
	for i in got_nodes.size():
		if used[i] == 0:
			extra.append(got_nodes[i])

	# Схлопывание поимённо объяснённых сдвигов: пара «нет у нас» + «лишний»
	# с тем же id и заранее разобранными координатами — один известный случай.
	var shift_notes: Array = []
	var mi := 0
	while mi < missing.size():
		var mn: Dictionary = missing[mi]
		var mid := String(mn["id"])
		var hit := -1
		if EXPLAINED_SHIFTS.has(mid):
			var want: Vector2 = EXPLAINED_SHIFTS[mid]
			for j in extra.size():
				var en: Dictionary = extra[j]
				if String(en["id"]) == mid \
						and absf(float(en["x"]) - want.x) <= PARITY_TOL \
						and absf(float(en["z"]) - want.y) <= PARITY_TOL:
					hit = j
					break
		if hit >= 0:
			shift_notes.append("  · объяснённый сдвиг %s %s → [%.2f, %.2f], лезвийная клетка"
				% [mid, _at(mn), float(extra[hit]["x"]), float(extra[hit]["z"])])
			missing.remove_at(mi)
			extra.remove_at(hit)
		else:
			mi += 1

	var node_diff := missing.size() + extra.size()
	print("узлов: %d, эталон %d; объяснённых сдвигов %d; нет у нас %d, лишних %d"
		% [got_nodes.size(), ref_nodes.size(), shift_notes.size(), missing.size(), extra.size()])
	for note: String in shift_notes:
		print(note)
	for i in mini(SHOW, missing.size()):
		var m: Dictionary = missing[i]
		printerr("  · нет узла эталона %s %s" % [String(m["id"]), _at(m)])
	for i in mini(SHOW, extra.size()):
		var e: Dictionary = extra[i]
		printerr("  · лишний узел %s %s" % [String(e["id"]), _at(e)])
	fails += node_diff

	# Рёбра — парами узлов. Пара берётся по id: id узла собирается из комнаты
	# и номера, и если он поехал, поедут и все рёбра — это видно сразу.
	var got_pairs := _pairs(got_nodes)
	var ref_pairs := _pairs(ref_nodes)
	var ref_by_id: Dictionary = {}
	for rn: Dictionary in ref_nodes:
		ref_by_id[String(rn["id"])] = rn
	var lost: Array = []
	for key: String in ref_pairs.keys():
		if not got_pairs.has(key):
			lost.append(key)
	var added: Array = []
	for key: String in got_pairs.keys():
		if not ref_pairs.has(key):
			added.append(key)
	lost.sort()
	added.sort()
	var lost_explained := 0
	var li := 0
	while li < lost.size():
		if EXPLAINED_LOST_EDGES.has(String(lost[li])):
			print("  · объяснённая потеря ребра %s — следствие сдвига узла"
				% _pair_text(String(lost[li]), ref_by_id))
			lost.remove_at(li)
			lost_explained += 1
		else:
			li += 1
	var edge_diff := lost.size() + added.size()
	print("рёбер (ненаправленных): %d, эталон %d; объяснённых потерь %d; нет у нас %d, лишних %d"
		% [got_pairs.size(), ref_pairs.size(), lost_explained, lost.size(), added.size()])
	for i in mini(SHOW, lost.size()):
		printerr("  · нет ребра эталона %s" % _pair_text(String(lost[i]), ref_by_id))
	for i in mini(SHOW, added.size()):
		printerr("  · лишнее ребро %s" % _pair_text(String(added[i]), ref_by_id))
	fails += edge_diff

	if fails == 0 and shift_notes.is_empty() and lost_explained == 0:
		print("сверка с эталоном: сошлось всё")
	elif fails == 0:
		print("сверка с эталоном: сошлось, не считая %d поимённо объяснённых сдвигов и %d потерь рёбер"
			% [shift_notes.size(), lost_explained])
	return fails


func _count_by_layer(list: Array) -> Dictionary:
	var out: Dictionary = {}
	for n: Dictionary in list:
		var l := String(n["layer"])
		var v: Array = out.get(l, [0, 0])
		var edges: Array = n["edges"]
		v[0] = int(v[0]) + 1
		v[1] = int(v[1]) + edges.size()
		out[l] = v
	return out


# Ненаправленные пары id: 'a|b', где a < b.
func _pairs(list: Array) -> Dictionary:
	var out: Dictionary = {}
	for n: Dictionary in list:
		var a := String(n["id"])
		for e: Dictionary in n["edges"]:
			out[_pair_key(a, String(e["to"]))] = true
	return out


func _pair_key(a: String, b: String) -> String:
	if a < b:
		return a + "|" + b
	return b + "|" + a


func _pair_text(key: String, ref_by_id: Dictionary) -> String:
	var parts := key.split("|")
	var out: Array = []
	for p: String in parts:
		var n: Variant = _nav.node(p)
		if n == null:
			n = ref_by_id.get(p, null)
		out.append(p + (" " + _at(n) if n != null else " [узла нет]"))
	return " ↔ ".join(PackedStringArray(out))


# ------------------------------------------------------------------
# 2. Инварианты audit-nav.js
# ------------------------------------------------------------------

func _invariants() -> int:
	var fails := 0
	var stats := _nav.stats()

	print("по слоям:")
	var multi: Array = []
	for layer: String in _nav.layer_list():
		var s: Dictionary = stats[layer]
		var comp := int(s["components"])
		if comp != 1:
			multi.append(layer)
		print("  %-7s узлов %3d, из них дверей %2d, рёбер %5.1f, компонентов %d%s"
			% [layer, int(s["nodes"]), int(s["doors"]), float(s["edges"]), comp,
			"" if comp == 1 else "   ← должен быть 1"])
	if not multi.is_empty():
		printerr("слои с разрывом: %s — половина слоя для деда не существует"
			% ", ".join(PackedStringArray(multi)))
		for layer: String in multi:
			for n: Dictionary in _nav.nodes(layer):
				var edges: Array = n["edges"]
				if edges.is_empty():
					printerr("  · без рёбер: %s %s" % [String(n["id"]), _at(n)])
		fails += multi.size()

	# Узлы.
	var bad_nodes: Array = []
	for layer: String in _nav.layer_list():
		for n: Dictionary in _nav.nodes(layer):
			var x := float(n["x"])
			var y := float(n["y"])
			var z := float(n["z"])
			if _nav.probe(layer, x, y, z, R):
				continue
			bad_nodes.append({"node": n, "thin": _nav.probe(layer, x, y, z, R_THIN)})
	print("узлов не прошли пробу: %d" % bad_nodes.size())
	for i in mini(SHOW, bad_nodes.size()):
		var b: Dictionary = bad_nodes[i]
		var n: Dictionary = b["node"]
		printerr("  · %s %s%s" % [String(n["id"]), _at(n),
			"  [свободно при 0.30, тесно при 0.32]" if bool(b["thin"]) else ""])
	fails += bad_nodes.size()

	# Рёбра.
	var bad_edges: Array = []
	var seen: Dictionary = {}
	for layer: String in _nav.layer_list():
		for a: Dictionary in _nav.nodes(layer):
			var aid := String(a["id"])
			for e: Dictionary in a["edges"]:
				var to := String(e["to"])
				var key := _pair_key(aid, to)
				if seen.has(key):
					continue
				seen[key] = true
				var b: Variant = _nav.node(to)
				if b == null:
					bad_edges.append({"a": a, "b": null, "thin": false})
					continue
				if _nav.edge_clear(a, b, R):
					continue
				bad_edges.append({"a": a, "b": b, "thin": _nav.edge_clear(a, b, R_THIN)})
	print("рёбер с непроходимым коридором: %d" % bad_edges.size())
	for i in mini(SHOW, bad_edges.size()):
		var be: Dictionary = bad_edges[i]
		var a: Dictionary = be["a"]
		if be["b"] == null:
			printerr("  · %s → узла нет" % String(a["id"]))
			continue
		var bn: Dictionary = be["b"]
		printerr("  · %s %s → %s %s%s" % [String(a["id"]), _at(a), String(bn["id"]), _at(bn),
			"  [проходимо при 0.30, тесно при 0.32]" if bool(be["thin"]) else ""])
	fails += bad_edges.size()

	# Комнаты без узлов.
	var empty := _empty_rooms()
	var target := _target_empty()
	var got_ids: Array = []
	for e: Dictionary in empty:
		got_ids.append(String(e["id"]))
	got_ids.sort()
	target.sort()
	var empty_ok := ", ".join(PackedStringArray(got_ids)) == ", ".join(PackedStringArray(target))
	print("мест без узлов: %d%s" % [empty.size(),
		" — как и задумано" if empty_ok else " — цель: " + ", ".join(PackedStringArray(target))])
	for e: Dictionary in empty:
		var why := String(e["why"])
		print("  · %s (%s, слой %s)%s" % [String(e["id"]), String(e["name"]), String(e["layer"]),
			" — " + why if why != "" else "   ← лишнее, туда дед не пойдёт"])
	if not empty_ok:
		fails += 1

	# Патруль.
	print("патруль %d с на слой, dt = %.4f, скорость %s м/с, радиусы %s / %s:"
		% [int(SIM_SECONDS), DT, SPEED, REACH_ROOM, REACH_DOOR])
	var stuck_total := 0
	var gaps_total := 0
	for layer: String in _nav.layer_list():
		var s := _simulate(layer)
		var stuck: Array = s["stuck"]
		var gaps: Array = s["gaps"]
		var blocked: Array = s["blocked"]
		stuck_total += stuck.size()
		gaps_total += gaps.size()
		print("  %-7s кольцо %2d узлов, путь %3d точек, кругов %3d, застреваний %d%s"
			% [layer, int(s["nodes"]), int(s["path"]), int(s["laps"]), stuck.size(),
			"   ← смотреть глазами" if not stuck.is_empty() else ""])
		for g: String in gaps:
			printerr("    · пути нет: %s" % g)
		for k: Dictionary in stuck:
			printerr("    · застрял на %d-й с в [%.2f, %.2f, %.2f], шёл к %s, прошёл %.2f м за %.1f с"
				% [int(k["at"]), float(k["x"]), float(k["y"]), float(k["z"]), String(k["to"]),
				float(k["walked"]), STUCK_WINDOW])
		for i in mini(4, blocked.size()):
			var bl: Dictionary = blocked[i]
			printerr("    · проба занята в [%.2f, %.2f, %.2f], шёл к %s"
				% [float(bl["x"]), float(bl["y"]), float(bl["z"]), String(bl["to"])])
	fails += stuck_total + gaps_total
	return fails


# Что законно остаётся без узлов — выводится из data/nav.json, а не списком
# руками: список протухнет ровно так же, как протухла таблица ROUTES.
func _target_empty() -> Array:
	var nav_data := GameData.nav()
	var out: Array = []
	for key: String in nav_data["banRooms"]:
		out.append(key)
	for b: Dictionary in nav_data["banRects"]:
		if b.has("place"):
			out.append(String(b["id"]))
	return out


# Комната покрыта, если хоть один узел её слоя стоит внутри прямоугольника.
# Сарай, туалет и теплица лежат внутри участка и проверяются отдельно от него:
# узел посреди двора сарай не покрывает.
func _empty_rooms() -> Array:
	var rooms: Dictionary = GameData.site()["ROOMS"]
	var nav_data := GameData.nav()
	var ban_rooms: Array = nav_data["banRooms"]
	var out: Array = []
	for key: String in rooms.keys():
		var r: Dictionary = rooms[key]
		var rx: Array = r["x"]
		var rz: Array = r["z"]
		var covered := false
		for n: Dictionary in _nav.nodes(String(r["level"])):
			var x := float(n["x"])
			var z := float(n["z"])
			if x < float(rx[0]) or x > float(rx[1]) or z < float(rz[0]) or z > float(rz[1]):
				continue
			covered = true
			break
		if covered:
			continue
		out.append({
			"id": key,
			"name": String(r.get("name", "?")),
			"layer": String(r["level"]),
			"why": "banRooms" if ban_rooms.has(key) else "",
		})
	for b: Dictionary in nav_data["banRects"]:
		if not b.has("place"):
			continue                                 # карман под лестницей помещением не считается
		out.append({
			"id": String(b["id"]),
			"name": String(b["place"]),
			"layer": String(b["layer"]),
			"why": "banRects",
		})
	return out


# ------------------------------------------------------------------
# 3. Симуляция патруля
# ------------------------------------------------------------------

# Кольцо patrol() разворачивается в последовательность узлов по рёбрам: между
# соседями кольца дед идёт не по прямой, а путём A*, как и будет в ai.gd.
func _waypoints(ring: Array) -> Dictionary:
	var out: Array = []
	var gaps: Array = []
	for i in ring.size():
		var a: Dictionary = ring[i]
		var b: Dictionary = ring[(i + 1) % ring.size()]
		if ring.size() == 1:
			out.append(a)
			break
		var p: Array = _nav.path(String(a["id"]), String(b["id"]))
		if p.is_empty():
			gaps.append(String(a["id"]) + " → " + String(b["id"]))
			continue
		for n: Dictionary in p:
			if out.is_empty() or String(out[out.size() - 1]["id"]) != String(n["id"]):
				out.append(n)
	while out.size() > 1 and String(out[0]["id"]) == String(out[out.size() - 1]["id"]):
		out.remove_at(out.size() - 1)
	return {"out": out, "gaps": gaps}


func _simulate(layer: String) -> Dictionary:
	var ring: Array = _nav.patrol(layer)
	var stuck: Array = []
	var blocked: Array = []
	var res := {"layer": layer, "nodes": ring.size(), "laps": 0, "path": 0,
		"stuck": stuck, "blocked": blocked, "gaps": []}
	if ring.is_empty():
		return res

	var wpres := _waypoints(ring)
	var wp: Array = wpres["out"]
	res["gaps"] = wpres["gaps"]
	res["path"] = wp.size()
	if wp.size() < 2:
		return res

	var k := 1
	var prev: Dictionary = wp[0]
	var px := float(prev["x"])
	var py := float(prev["y"])
	var pz := float(prev["z"])
	var seg_len := maxf(0.001, _hyp(float(wp[1]["x"]) - px, float(wp[1]["z"]) - pz))
	var window := 0.0
	var walked := 0.0
	var laps := 0
	var frames := int(round(SIM_SECONDS / DT))

	for f in frames:
		var target: Dictionary = wp[k]
		var tx := float(target["x"])
		var tz := float(target["z"])
		var reach := REACH_DOOR if String(target["kind"]) == "door" else REACH_ROOM
		var d := _hyp(tx - px, tz - pz)

		# Узел засчитывается по радиусу И по проекции — ровно как в ai.gd. Одного
		# радиуса мало: в дверь 0.9 м ведёт полоса свободного шириной с капсулу,
		# и ходок, засчитавший дверной узел за 0.25 м до него, дальше идёт уже не
		# через проём, а в наличник рядом. Проекция требует пройти узел, а не
		# приблизиться к нему; ближе 0.12 засчитываем и без неё, иначе на точном
		# попадании в узел цикл не двинется.
		var dirx := tx - float(prev["x"])
		var dirz := tz - float(prev["z"])
		var passed := (px - tx) * dirx + (pz - tz) * dirz >= 0.0
		if d <= reach and (passed or d <= 0.12):
			prev = target
			k = (k + 1) % wp.size()
			if k == 1:
				laps += 1
			seg_len = maxf(0.001, _hyp(float(wp[k]["x"]) - float(prev["x"]),
				float(wp[k]["z"]) - float(prev["z"])))
			continue

		var step := SPEED * DT
		var x0 := px
		var z0 := pz
		var nx := px + (tx - px) / d * step
		var nz := pz + (tz - pz) / d * step
		# Высота идёт линейно по отрезку — так же, как её берёт валидация рёбер:
		# порог сарая 0.12 и цоколь теплицы 0.10 иначе дают ложное «занято».
		var t := clampf(1.0 - d / seg_len, 0.0, 1.0)
		var ny := float(prev["y"]) + (float(target["y"]) - float(prev["y"])) * t

		# Шаг с тем же скольжением, что и у деда (MOVED → SLID → BLOCKED). Без
		# него симуляция врёт в худшую сторону: радиус достижения узла 0.55
		# позволяет срезать угол, и следующий отрезок идёт уже не по ребру графа,
		# а параллельно ему со сдвигом до полуметра. Скольжение по осям, а не по
		# нормали: нормаль живёт внутри набора коробок, а результат тот же.
		var moved := false
		if _nav.probe(layer, nx, ny, nz, R):
			px = nx
			py = ny
			pz = nz
			moved = true
		elif _nav.probe(layer, nx, ny, pz, R):
			px = nx
			py = ny
			moved = true
		elif _nav.probe(layer, px, ny, nz, R):
			py = ny
			pz = nz
			moved = true
		if moved:
			walked += _hyp(px - x0, pz - z0)
		elif blocked.size() < 12:
			blocked.append({"x": nx, "y": ny, "z": nz, "to": String(target["id"])})

		window += DT
		if window >= STUCK_WINDOW:
			if walked < STUCK_DIST and stuck.size() < 12:
				stuck.append({"x": px, "y": py, "z": pz, "to": String(target["id"]),
					"walked": walked, "at": int(round(f * DT))})
			window = 0.0
			walked = 0.0

	res["laps"] = laps
	return res


# ------------------------------------------------------------------
# мелочь
# ------------------------------------------------------------------

# Тот же hypot, что в графе: на ничьих в 1e-16 расходятся выбор клетки и
# засчитывание узла, а тут сравнения идут ровно с теми же числами.
func _hyp(x: float, y: float) -> float:
	return NavGraph._hypot(x, y)


func _at(n: Variant) -> String:
	return "[%.2f, %.2f, %.2f]" % [float(n["x"]), float(n["y"]), float(n["z"])]


func _read_json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}

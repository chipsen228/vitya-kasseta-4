extends SceneTree

const BOOT_FRAMES := 600
var errors: Array[String] = []
var _main: Node
var c: Dictionary
var state: GameState
var pursuit: SntPursuit
var chapters: Chapters
var director: HorrorDirector
var capture: CaptureRecovery


func _initialize() -> void:
	_run()


func _run() -> void:
	_main = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	for frame in BOOT_FRAMES:
		if _main.get("chapters") != null: break
		await process_frame
	if _main.get("chapters") == null:
		printerr("FAIL test_snt_pursuit: boot")
		quit(1)
		return
	_main.call("_start_game")
	for frame in 40:
		var ui: Overlays = _main.get("ui")
		if ui.card.open: ui.advanceCard()
		await process_frame
	_main.set_process(false)
	_main.get("player").set_physics_process(false)
	c = _main.get("ctx")
	state = c["state"]
	pursuit = c["pursuit"]
	chapters = c["chapters"]
	director = c["horror"]
	capture = c["capture"]
	c["scaresOn"] = func() -> bool: return false
	_seed()
	var graph: Dictionary = pursuit.graph
	var points: Array = graph["points"]
	_check((graph["exits"] as Array).size() == 2, "у графа не два выхода")
	_check(float(graph.get("path_width", 0.0)) >= 1.4, "лесная тропа уже 1.4 метра")
	_check(float(graph.get("max_step", INF)) <= 0.2, "ступень маршрута выше 0.2 метра")
	var collision_additions: Array = c["world"]["snt"].get("collision_additions", [])
	_check(not collision_additions.is_empty(), "нет явного перечня новых коллизий")
	for item: Dictionary in collision_additions:
		_check(int(item.get("set", -1)) == CollisionWorld.SET_OVERLAY,
			"новая коллизия изменила паритетный набор: " + String(item.get("id", "")))
	for edge: Array in graph["edges"]:
		var a: Vector3 = points[int(edge[0])]
		var b: Vector3 = points[int(edge[1])]
		_check(director.trajectory_clear(a, b), "непроходимо ребро %s: %s -> %s" % [edge, a, b])
	pursuit.position = graph["spawn"]
	for destination: Vector3 in graph["exits"]:
		var route := pursuit.route_to(destination)
		_check(not route.is_empty(), "Обходчик не строит маршрут к выходу " + str(destination))
		var from: Vector3 = graph["spawn"]
		for to: Vector3 in route:
			_check(director.trajectory_clear(from, to), "route_to пересёк препятствие")
			from = to
	_test_all_solid(points)
	_test_route_cache(points)

	# The west exit cannot be claimed from the village side without entering the forest.
	_seed()
	_place(graph["exits"][0])
	_begin()
	pursuit.update(SntPursuit.WARNING_SECONDS)
	pursuit.update(0.01)
	_check(not state.has("snt-pursuit-escaped"), "западный выход засчитан без посещения леса")
	# A short reverse entry from the village is not a northern traversal.
	_place(Vector3(-47.0, 0.0, -54.5))
	pursuit.update(0.05)
	_check(not pursuit.forest_entered, "reverse west entry bypassed northern forest")
	_place(graph["exits"][0])
	pursuit.update(0.05)
	_check(not state.has("snt-pursuit-escaped"), "two steps past x=-46 completed forest escape")
	pursuit.cancel()

	# Walk the connected northern path, including both forest junctions, in small steps.
	_seed()
	_place(pursuit.retry_anchor())
	_begin()
	_test_pause("warning")
	pursuit.update(SntPursuit.WARNING_SECONDS)
	_check(pursuit.phase == "chase", "после предупреждения не началось преследование")
	_check(not state.horror_seen.has("snt-lebedev-face"), "выключенные испуги израсходовали лицо")
	_test_pause("chase")
	var first := _nearest(points, pursuit.retry_anchor())
	var north := _nearest(points, Vector3(-12, 0, -78))
	var west := _nearest(points, graph["exits"][0])
	var forest := _graph_path(first, north)
	var rest := _graph_path(north, west)
	if not rest.is_empty(): rest.pop_front()
	forest.append_array(rest)
	_check(not forest.is_empty(), "нет связной северной тропы к западному выходу")
	_walk(forest)
	_check(state.has("snt-pursuit-escaped") and not pursuit.active(), "лесной маршрут не завершил побег")
	_check(not state.has("snt-returned"), "побег преждевременно завершил разговор с Семёном")
	_check(state.threatState == "patrol", "побег не восстановил обычную угрозу")
	_check(is_equal_approx(c["haunt"].global_cd, 23.0), "побег не восстановил отсрочку случайных испугов")
	_check(state.horror_seen.has("test-once"), "побег потерял однократную историю")
	_check(not pursuit.begin(), "успешная погоня запустилась повторно")

	# The old south entrance remains a complete alternative escape.
	_seed()
	_place(points[1])
	_begin()
	pursuit.update(SntPursuit.WARNING_SECONDS)
	_walk(_graph_path(1, _nearest(points, graph["exits"][1])))
	_check(state.has("snt-pursuit-escaped") and not pursuit.active(), "прежний въезд не завершил побег")
	_check(state.threatState == "patrol", "южный выход не восстановил угрозу")

	# A real collision with the pursuer uses the external capture and its own retry anchor.
	_seed()
	state.recovery_completed_count = 2
	_place(pursuit.retry_anchor())
	_begin()
	pursuit.update(SntPursuit.WARNING_SECONDS)
	state.horror_seen["snt-lebedev-face"] = true
	state.horror_seen["test-after-checkpoint"] = true
	var completed_before := state.recovery_completed_count
	var fails_before := state.failCount
	var feet: Vector3 = c["controls"].feet()
	pursuit.position = feet + Vector3(0.45, 0, 0)
	pursuit.update(0.01)
	_check(capture.phase == "external-hit" and capture.active(), "Обходчик не включил внешний профиль поимки")
	_check(state.recovery.get("kind", "") == "snt" and not bool(state.recovery.get("terminal", true)), "поимка получила прежний/терминальный профиль")
	_check(not c["controls"].enabled and state.failCount == fails_before + 1, "поимка не остановила управление или потеряла счётчик")
	_check(capture._light == null and capture._fixture == null and capture.phase != "cellar", "внешняя поимка построила прежний погреб")
	_test_pause("capture")
	capture.update_external(2.89)
	_check(capture.active() and state.chapter == "village", "внешняя поимка закончилась раньше 2.9 секунды")
	capture.update_external(0.02)
	_check(not capture.active() and state.recovery.is_empty(), "retry оставил активную внешнюю поимку")
	_check(c["controls"].feet().distance_to(pursuit.retry_anchor()) < 0.03, "retry не вернул к подготовленному входу")
	_check(state.chapter == "village" and (state.ending == null or state.ending == ""), "Обходчик запустил концовку")
	_check(state.recovery_completed_count == completed_before, "Обходчик изменил счётчик прежнего погреба")
	_check(state.horror_seen.has("test-after-checkpoint") and state.horror_seen.has("snt-lebedev-face"), "retry повторит однократный испуг")
	var attempts_before := pursuit.attempts
	c["snt"].update(0.01)
	_check(pursuit.active() and pursuit.attempts == attempts_before + 1, "неудавшийся побег не запустился повторно")
	_check(not pursuit.forest_entered, "retry сохранил пройденный лес прошлой попытки")
	pursuit.cancel()

	# Repath every 0.6 s must keep forward progress around consecutive corners.
	_seed()
	var distant := Vector3(-40.0, 0.0, -53.8)
	_place(distant)
	_begin()
	pursuit.update(SntPursuit.WARNING_SECONDS)
	var original := pursuit.position
	var start_distance := original.distance_to(distant)
	var best_distance := start_distance
	var last_direction := Vector3.ZERO
	var turns := 0
	for step in 2400:
		var before := pursuit.position
		pursuit.update(0.05)
		var move := pursuit.position - before
		best_distance = minf(best_distance, pursuit.position.distance_to(distant))
		if move.length() > 0.02:
			_check(director.trajectory_clear(before, pursuit.position), "????? ???????? ?????? ?????? ?????")
			var direction := move.normalized()
			if last_direction != Vector3.ZERO and last_direction.dot(direction) < 0.6: turns += 1
			last_direction = direction
		if capture.active(): break
	_check(start_distance - best_distance > 40.0, "???????? ???????/?????????? ????? ?????????????? ????????")
	_check(turns >= 2, "???? ???????? ????????????? ?? ?????? ????????? ?????")
	_check(capture.active() or best_distance < 2.0, "???????? ?? ?????? ??????????? ???? ?? 120 ??????")
	capture.cancel()
	pursuit.cancel()

	# Legacy completed saves skip the new chase; new game clears only playthrough history.
	_seed()
	state.set_flag("snt-returned")
	state.flags.erase("snt-return-inspected")
	c["snt"].resync(state)
	_check(not pursuit.begin() and not c["snt"].episode.pending_pursuit, "старый завершённый обход перезапустил погоню")
	_check(SntQuest.task_for(state) == null, "старый завершённый обход получил новую задачу")
	state.reset()
	Interact.resync_world(c)
	director.invalidate("reset")
	_check(state.horror_seen.is_empty() and not pursuit.active(), "новая игра не сбросила историю и погоню")
	for message: String in errors: printerr("FAIL test_snt_pursuit: ", message)
	if errors.is_empty():
		print("test_snt_pursuit: PASS (graph edges, all solid sets, forest/south exits, pause, external capture, retry, one-shot history, legacy saves)")
	quit(0 if errors.is_empty() else 1)


func _seed() -> void:
	pursuit.cancel()
	capture.cancel()
	state.reset()
	state.chapter = "village"
	state.give("shop-key")
	state.give("distributor")
	for flag: String in ["distributor-gone", "water-done", "damper-shut", "banya-hot", "banya-written", "bathloft-found", "mill-clue", "snt-watch-read", "snt-yard-seen", "snt-booth-used"]:
		state.set_flag(flag)
	for flag: String in SntEpisode.PROGRESS:
		if not ["snt-pursuit-started", "snt-pursuit-escaped"].has(flag): state.set_flag(flag)
	chapters.go("village", true)
	state.threatState = "patrol"
	c["haunt"].global_cd = 23.0
	state.horror_seen["test-once"] = true
	director.cooldown = 0.0
	chapters.pushTask(true)


func _begin() -> void:
	_check(pursuit.begin(), "готовая погоня не началась")
	_check(state.threatState == "patrol" and director.exclusive() and not bool(_main.call("_runtime_free")), "погоня не приостановила обычную угрозу/испуги")
	_check(state.has("snt-pursuit-started"), "начало погони не сохранило отдельный флаг")


func _test_pause(stage: String) -> void:
	_main.call("_set_paused", true)
	var before := [pursuit.elapsed, pursuit.position, capture._external_time]
	for frame in 5: _main.call("_process", 0.05)
	_check(before == [pursuit.elapsed, pursuit.position, capture._external_time], "пауза не остановила " + stage)
	_main.call("_set_paused", false)


func _test_all_solid(points: Array) -> void:
	var col: CollisionWorld = c["col"]
	var a: Vector3 = points[12]
	var b: Vector3 = points[13]
	var middle := a.lerp(b, 0.5)
	_check(pursuit._clear(a, b), "контрольный лесной отрезок закрыт до добавления препятствия")
	for set_id: int in [CollisionWorld.SET_STATIC, CollisionWorld.SET_BLOCKERS, CollisionWorld.SET_PROPS, CollisionWorld.SET_OVERLAY]:
		var id := "test-pursuit-solid-%d" % set_id
		col.add_box_d(set_id, middle.x - 1.4, -0.02, middle.z - 0.12, middle.x + 1.4, 2.2, middle.z + 0.12, id)
		_check(not pursuit._clear(a, b), "погоня прошла через набор коллизий %d" % set_id)
		pursuit.position = a
		var route := pursuit.route_to(b)
		var from := a
		for to: Vector3 in route:
			_check(director.trajectory_clear(from, to), "обход препятствия режет твёрдый набор %d" % set_id)
			from = to
		col.set_blocker_active(id, false)
		_check(pursuit._clear(a, b), "открытое препятствие осталось в навигации")


func _test_route_cache(points: Array) -> void:
	var col: CollisionWorld = c["col"]
	# Use real clear northern trail edges as a bridge graph. A small permanent
	# blocker removes the direct shortcut, so every open/closed query must use
	# the graph cache. A disconnected bridge must return no route, and reopening
	# must restore it; an alternate full-village path cannot mask stale cache.
	var route_points: Array[Vector3] = [points[13],points[14],points[15],points[16]]
	var origin: Vector3 = route_points[0]
	var destination: Vector3 = route_points[3]
	var diagonal := origin.lerp(destination,0.5)
	var diagonal_id := "test-route-cache-diagonal"
	col.add_box_d(CollisionWorld.SET_OVERLAY,diagonal.x-0.12,-0.02,diagonal.z-0.12,
		diagonal.x+0.12,2.2,diagonal.z+0.12,diagonal_id)
	_check(not director.trajectory_clear(origin,destination), "cache fixture left direct shortcut open")
	var local_graph := {"points":route_points,"edges":[[0,1],[1,2],[2,3]]}
	var probe := SntPursuit.new(c,{"pursuit_graph":local_graph})
	probe.position = origin
	for edge: Array in local_graph["edges"]:
		_check(director.trajectory_clear(route_points[int(edge[0])],route_points[int(edge[1])]),
			"cache fixture obstructed an intended graph edge")
	var midpoint: Vector3 = route_points[0].lerp(route_points[1],0.5)
	for set_id: int in [CollisionWorld.SET_STATIC,CollisionWorld.SET_BLOCKERS,CollisionWorld.SET_PROPS,CollisionWorld.SET_OVERLAY]:
		var id := "test-route-cache-solid-%d" % set_id
		_check_cached_route(probe,origin,destination,true,"warm %d" % set_id)
		_check_cached_route(probe,origin,destination,true,"repeated warm %d" % set_id)
		col.add_box_d(set_id,midpoint.x-0.12,-0.02,midpoint.z-1.4,
			midpoint.x+0.12,2.2,midpoint.z+1.4,id)
		_check(not director.trajectory_clear(route_points[0],route_points[1]), "new solid did not block cached edge %d" % set_id)
		_check_cached_route(probe,origin,destination,false,"added %d" % set_id)
		col.set_blocker_active(id,false)
		_check_cached_route(probe,origin,destination,true,"deactivated %d" % set_id)
		col.set_blocker_active(id,true)
		_check_cached_route(probe,origin,destination,false,"reactivated %d" % set_id)
		col.set_blocker_active(id,false)
		_check_cached_route(probe,origin,destination,true,"reopened %d" % set_id)
	col.set_blocker_active(diagonal_id,false)

func _check_cached_route(probe: SntPursuit, origin: Vector3, destination: Vector3,
		expected_open: bool, label: String) -> void:
	var route := probe.route_to(destination)
	_check(not route.is_empty() if expected_open else route.is_empty(), "route cache connectivity wrong after " + label)
	var from := origin
	for to: Vector3 in route:
		_check(director.trajectory_clear(from,to), "route cache crosses ALL_SOLID after " + label)
		from = to
	if expected_open and not route.is_empty():
		_check(route.back().distance_to(destination) < 0.01, "route cache stops short after " + label)

func _nearest(points: Array, at: Vector3) -> int:
	var best := 0
	for i in points.size():
		if (points[i] as Vector3).distance_squared_to(at) < (points[best] as Vector3).distance_squared_to(at): best = i
	return best


func _graph_path(start: int, goal: int) -> Array[int]:
	var pending: Array[int] = [start]
	var previous := {start: -1}
	while not pending.is_empty():
		var here: int = pending.pop_front()
		if here == goal: break
		for edge: Array in pursuit.graph["edges"]:
			var next := int(edge[1]) if int(edge[0]) == here else int(edge[0]) if int(edge[1]) == here else -1
			if next >= 0 and not previous.has(next):
				previous[next] = here
				pending.append(next)
	var result: Array[int] = []
	if not previous.has(goal): return result
	var at := goal
	while at >= 0:
		result.push_front(at)
		at = int(previous[at])
	return result


func _walk(path: Array[int]) -> void:
	if path.is_empty(): return
	var points: Array = pursuit.graph["points"]
	var from: Vector3 = points[path[0]]
	_place(from)
	for index: int in path.slice(1):
		var to: Vector3 = points[index]
		_check(director.trajectory_clear(from, to), "маршрут игрока пересёк стену")
		var steps := maxi(1, ceili(from.distance_to(to) / 0.45))
		for step in range(1, steps + 1):
			_place(from.lerp(to, float(step) / steps))
			pursuit.update(0.04)
			if capture.active():
				_check(false, "Обходчик поймал игрока на подготовленном тестовом маршруте")
				return
		from = to


func _place(at: Vector3) -> void:
	c["controls"].place(at.x, at.y, at.z, 0.0)


func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

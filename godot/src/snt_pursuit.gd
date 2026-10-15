class_name SntPursuit
extends RefCounted

const SPEED := 2.25
const WARNING_SECONDS := 5.0
const CATCH_RADIUS := 0.88
var c: Dictionary
var graph: Dictionary
var phase := "idle"
var elapsed := 0.0
var position := Vector3.ZERO
var _path: Array[Vector3] = []
var _repath := 0.0
var _step_left := 0.0
var _saved_threat := "absent"
var _saved_haunt_cd := 0.0
var attempts := 0
var forest_entered := false
var _edge_cache: Dictionary = {}
var _cache_revision := -1
var _cache_points: Array[Vector3] = []
var _warm_cursor := 0

func _init(context: Dictionary, world: Dictionary) -> void:
	c = context
	graph = world.get("pursuit_graph", {})

func active() -> bool:
	return phase != "idle"

func exclusive_runtime() -> bool:
	return active()

func retry_anchor() -> Vector3:
	return _vector(graph.get("retry", Vector3(7.1, 0, -66.5)))

func begin() -> bool:
	var s: GameState = c["state"]
	if active() or s.chapter != "village" or s.has("snt-pursuit-escaped") or s.has("snt-returned"):
		return false
	if graph.is_empty(): return false
	var capture: Variant = c.get("capture")
	var cut: Variant = c.get("cutscene")
	var phone: Variant = c.get("phone")
	if (capture != null and capture.active()) or (cut != null and cut.playing) \
			or (phone != null and phone.talking) or c["ui"].busy: return false
	_saved_threat = s.threatState
	var director: Variant = c.get("horror")
	if director != null: director.hold(WARNING_SECONDS, "pursuit")
	var haunt: Variant = c.get("haunt")
	if haunt != null:
		_saved_haunt_cd = haunt.global_cd
		haunt.hold(120.0)
	var startle: Variant = c.get("startle")
	if startle != null: startle.clear()
	var stalk: Variant = c.get("stalk")
	if stalk != null: stalk.finish()
	var actors: Variant = c.get("actors")
	if actors != null: actors.show("threat", false)
	position = _vector(graph.get("spawn", Vector3(19, 0, -42.3)))
	elapsed = 0.0
	_repath = 0.0
	_step_left = 0.0
	_path.clear()
	phase = "warning"
	forest_entered = false
	attempts += 1
	s.set_flag("snt-pursuit-started")
	c["emit"].call("snt-pursuit-started")
	c["ui"].say("Во дворе кто-то есть. Уходи к служебной будке и лесной тропе. Прежний въезд тоже открыт.", 5.0)
	_show_return_face()
	return true

func update(dt: float) -> void:
	if not active(): return
	var s: GameState = c["state"]
	if s.chapter != "village":
		cancel()
		return
	elapsed += dt
	_warm_edges()
	if phase == "warning":
		if elapsed < WARNING_SECONDS: return
		_hide_face()
		phase = "chase"
		_set_actor(true)
		return
	var ctrl: Player = c["controls"]
	var feet := ctrl.feet()
	forest_entered = forest_entered or feet.z < -73.0
	for raw: Variant in graph.get("exits", []):
		var exit := _vector(raw)
		if exit.x < 0.0 and not forest_entered: continue
		if feet.distance_to(exit) < 2.0 and _clear(feet, exit):
			_escape()
			return
	_repath -= dt
	if _repath <= 0.0:
		_repath = 0.6
		_path = route_to(feet)
	if not _path.is_empty():
		var next: Vector3 = _path[0]
		var delta := next - position
		var step := minf(delta.length(), SPEED * dt)
		if step > 0.001:
			var candidate := position + delta.normalized() * step
			if _clear(position, candidate): position = candidate
		if position.distance_to(next) < 0.15: _path.pop_front()
	_set_actor(true)
	_step_left -= dt
	if _step_left <= 0.0:
		_step_left = 0.48
		if _scares_on(): c["audio"].spatial_sfx("horror-run-gravel", position, 0.32, 22.0, "pursuit", 2)
	if position.distance_to(feet) <= CATCH_RADIUS and _clear(position, feet):
		var capture: Variant = c.get("capture")
		if capture != null and capture.begin_external("Обходчик", retry_anchor()):
			_restore_runtime()
			phase = "idle"
			_path.clear()

func route_to(target: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	# Long shortcuts sample hundreds of floor/capsule probes; use the local
	# graph for those trips and keep direct steering for nearby targets.
	if position.distance_squared_to(target) <= 100.0 and _clear(position, target):
		out.append(target)
		return out
	var points := _points()
	_ensure_edge_cache(points)
	var start := _nearest_visible(position, points)
	var goal := _nearest_visible(target, points)
	if start < 0 or goal < 0: return out
	var distances: Dictionary = {start: 0.0}
	var previous: Dictionary = {}
	var pending: Array = [start]
	var visited: Dictionary = {}
	while not pending.is_empty():
		var best: int = pending[0]
		for i: int in pending:
			if float(distances[i]) < float(distances[best]): best = i
		pending.erase(best)
		if best == goal: break
		if visited.has(best): continue
		visited[best] = true
		for edge: Array in graph.get("edges", []):
			var other := int(edge[1]) if int(edge[0]) == best else int(edge[0]) if int(edge[1]) == best else -1
			if other < 0 or visited.has(other) or not _edge_clear(best, other, points): continue
			var cost := float(distances[best]) + points[best].distance_to(points[other])
			if cost < float(distances.get(other, INF)):
				distances[other] = cost
				previous[other] = best
				if not pending.has(other): pending.append(other)
	if not distances.has(goal): return out
	var trail: Array[int] = [goal]
	var at := goal
	while previous.has(at):
		at = int(previous[at])
		trail.push_front(at)
	if trail.size() > 1 and _clear(position, points[trail[1]]): trail.pop_front()
	for index: int in trail: out.append(points[index])
	out.append(target)
	return out

func _nearest_visible(at: Vector3, points: Array[Vector3]) -> int:
	var indices: Array[int] = []
	for i in points.size(): indices.append(i)
	indices.sort_custom(func(a: int, b: int) -> bool:
		return at.distance_squared_to(points[a]) < at.distance_squared_to(points[b]))
	for i: int in indices:
		if _clear(at, points[i]): return i
	return -1

func _points() -> Array[Vector3]:
	var points: Array[Vector3] = []
	for raw: Variant in graph.get("points", []): points.append(_vector(raw))
	return points

func _ensure_edge_cache(points: Array[Vector3]) -> void:
	var col: CollisionWorld = c.get("col")
	var revision := col.revision if col != null else 0
	if revision == _cache_revision and points == _cache_points: return
	_cache_revision = revision
	_cache_points.assign(points)
	_edge_cache.clear()
	_warm_cursor = 0

func _edge_clear(a: int, b: int, points: Array[Vector3]) -> bool:
	var key := Vector2i(mini(a, b), maxi(a, b))
	if not _edge_cache.has(key): _edge_cache[key] = _clear(points[a], points[b])
	return bool(_edge_cache[key])

func _warm_edges() -> void:
	var points := _points()
	_ensure_edge_cache(points)
	var edges: Array = graph.get("edges", [])
	# Prepare one fixed edge per frame during the five-second warning.
	# Moving steps still check ALL_SOLID, even when the graph is cached.
	if _warm_cursor < edges.size():
		var edge: Array = edges[_warm_cursor]
		_edge_clear(int(edge[0]), int(edge[1]), points)
		_warm_cursor += 1

func _clear(a: Vector3, b: Vector3) -> bool:
	var director: Variant = c.get("horror")
	return director != null and director.trajectory_clear(a, b)

func _escape() -> void:
	var s: GameState = c["state"]
	s.set_flag("snt-pursuit-escaped")
	cancel()
	c["emit"].call("snt-pursuit-escaped")
	c["ui"].say("Здесь шагов больше нет. Семён у мастерской. Нужно сказать ему, что обходчик вернулся.", 5.0)

func cancel() -> void:
	var was_active := active()
	phase = "idle"
	_path.clear()
	_set_actor(false)
	_hide_face()
	var audio: Variant = c.get("audio")
	if audio != null: audio.stop_spatial_owner("pursuit")
	if was_active:
		_restore_runtime()

func _restore_runtime() -> void:
	(c["state"] as GameState).threatState = _saved_threat
	var haunt: Variant = c.get("haunt")
	if haunt != null: haunt.global_cd = _saved_haunt_cd
	var director: Variant = c.get("horror")
	if director != null and director.owner == "pursuit":
		director.hold_left = 0.0
		director.owner = ""

func resync() -> void:
	cancel()

func _set_actor(on: bool) -> void:
	var actors: Variant = c.get("episodeActors")
	if actors == null: return
	actors.show("walker", on)
	if not on: return
	actors.place("walker", position.x, position.y, position.z, 0.0)
	var feet: Vector3 = c["controls"].feet()
	actors.face("walker", feet.x, feet.z)
	actors.sample_action("walker", "chase", elapsed)

func _show_return_face() -> void:
	var s: GameState = c["state"]
	var director: Variant = c.get("horror")
	var actors: Variant = c.get("episodeActors")
	if not _scares_on() or s.horror_seen.has("snt-lebedev-face") or director == null or actors == null: return
	if director.cooldown > 0.0: return
	var at := Vector3(20.35, 1.58, -42.97)
	var feet: Vector3 = c["controls"].feet()
	if feet.distance_to(at) > 4.0: return
	var camera: Camera3D = c["renderer"].camera
	if not c["interact"].visible(camera.global_position, at, CollisionWorld.ALL_SOLID): return
	actors.place("window_face", at.x, at.y, at.z, 0.0)
	actors.face("window_face", feet.x, feet.z)
	actors.begin_action("window_face", "peek")
	actors.show("window_face", true)
	s.horror_seen["snt-lebedev-face"] = true
	director.cooldown = HorrorDirector.STRONG_COOLDOWN
	c["audio"].spatial_sfx("horror-window-hit", at, 0.30, 12.0, "pursuit", 2)

func _hide_face() -> void:
	var actors: Variant = c.get("episodeActors")
	if actors != null: actors.show("window_face", false)

func _scares_on() -> bool:
	var cb: Variant = c.get("scaresOn")
	return not cb is Callable or bool(cb.call())

static func _vector(value: Variant) -> Vector3:
	if value is Vector3: return value
	if value is Array and value.size() >= 3: return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return Vector3.ZERO

# Общая очередь постановок и часов. Камеру берёт только настоящая поимка.
class_name HorrorDirector
extends RefCounted

const STRONG_COOLDOWN := 75.0
const EVENTS := [
	{"id": "light-call-radio", "chapter": "light", "need": [], "events": ["call"], "sound": "radio-veranda", "motion": "sound"},
	{"id": "light-lid-return", "chapter": "light", "need": ["power-on"], "events": ["power"], "sound": "horror-tin", "motion": "sound"},
	{"id": "loft-barn-pass", "chapter": "loft", "need": ["diary-read"], "events": ["diary-read"], "sound": "horror-run-wood", "motion": "pass"},
	{"id": "tapes-attic-return", "chapter": "tapes", "need": ["notebook-read"], "events": ["watch-tape", "notebook-read"], "sound": "horror-attic-creak", "motion": "sound"},
	{"id": "street-car-pass", "chapter": "street", "need": ["car-dead"], "events": ["car-dead"], "sound": "horror-run-gravel", "motion": "pass"},
	{"id": "street-office-exit", "chapter": "street", "need": ["duty-log"], "events": ["duty-log"], "sound": "horror-run-gravel", "motion": "pass"},
	{"id": "blackout-cellar-return", "chapter": "dark", "need": ["stash-found"], "events": ["stash"], "sound": "horror-cloth", "motion": "pass"},
	{"id": "village-shop-exit", "chapter": "village", "need": ["shop-open"], "events": ["shop-open", "distributor"], "sound": "horror-run-gravel", "motion": "pass"},
	{"id": "farm-pump-pass", "chapter": "village", "need": ["well-raised"], "events": ["well-raised"], "sound": "horror-wet-steps", "motion": "pass"},
	{"id": "bath-wall-return", "chapter": "village", "need": ["banya-written"], "events": ["banya-written", "bath-wall"], "sound": "horror-window-hit", "motion": "sound"},
	{"id": "mill-steps-return", "chapter": "village", "need": ["mill-clue"], "events": ["mill-clue", "mill-steps"], "sound": "horror-run-wood", "motion": "sound"},
	{"id": "letter-local-pass", "chapter": "village", "need": ["kovrigin-letter"], "events": ["kovrigin-letter"], "sound": "horror-cloth", "motion": "pass"},
	{"id": "valya-mound-return", "chapter": "village", "need": ["grave-dug"], "events": ["grave-dug", "valya-gone"], "sound": "horror-wet-steps", "motion": "pass"},
]

var c: Dictionary
var generation := 0
var cooldown := 0.0
var hold_left := 0.0
var owner := ""
var _armed: Dictionary = {}
var _timers: Array = []
var _live: Dictionary = {}
var _time := 0.0
var _chapter := ""
var _ambient_id := ""
var thresholds: RefCounted

func _init(context: Dictionary) -> void:
	c = context
	thresholds = preload("res://src/threshold_scares.gd").new(c, self)

func exclusive() -> bool:
	var recovery: Variant = c.get("capture")
	if recovery != null and recovery.active(): return true
	return hold_left > 0.0 or not _live.is_empty() or thresholds.active() or external_exclusive()

func external_exclusive() -> bool:
	for key: String in ["snt", "outskirts", "pursuit"]:
		var runtime: Variant = c.get(key)
		if runtime != null and runtime.has_method("exclusive_runtime") and bool(runtime.exclusive_runtime()):
			return true
	return false

func random_allowed() -> bool:
	return not exclusive() and cooldown <= 0.0 and _scares_on() and not thresholds.reserved_near()

func hold(seconds: float, claim := "mandatory") -> void:
	if not _live.is_empty(): _end_live()
	if thresholds.active(): thresholds._end()
	hold_left = maxf(hold_left, seconds)
	owner = claim
	if claim == "ambient": cooldown = STRONG_COOLDOWN

func after(seconds: float, cb: Callable) -> void:
	_timers.append({"left": maxf(seconds, 0.0), "cb": cb, "generation": generation})


func ambient_started(kind: String, seconds := 0.0) -> void:
	cooldown = STRONG_COOLDOWN
	if seconds > 0.0:
		hold_left = maxf(hold_left, seconds)
		owner = kind

func invalidate(reason := "reset") -> void:
	generation += 1
	if reason == "reset": cooldown = 0.0
	_timers.clear()
	_armed.clear()
	_end_live()
	thresholds.invalidate()
	hold_left = 0.0
	owner = reason if reason == "capture" else ""
	c["drive_attempt_id"] = int(c.get("drive_attempt_id", 0)) + 1
	var s: Variant = c.get("state")
	if s != null: s.set_flag("starter-on", false)
	_stop_ambient()

func observe(event: String, _payload: Variant = null) -> void:
	var s: GameState = c["state"]
	if s.chapter == "end" or _feet() == Vector3.INF: return
	for e: Dictionary in EVENTS:
		if String(e["chapter"]) == s.chapter and (e["events"] as Array).has(event):
			_arm(e)

func action(id: String) -> void:
	# Нестандартный предмет получает собственную постановку после отхода.
	if ["banya-wall", "mill-steps", "farm-pump", "kovrigin-letter"].has(id):
		observe(id)

func context(id := "local-noise", sound := "horror-window-hit", source_at := Vector3.INF) -> void:
	var s: GameState = c["state"]
	var e := {"id": id, "chapter": s.chapter, "need": [], "events": [],
		"sound": sound, "motion": "sound"}
	if source_at.is_finite(): e["sound_at"] = source_at
	_arm(e)

func _arm(e: Dictionary) -> void:
	var s: GameState = c["state"]
	var id := String(e["id"])
	if ThresholdScares.RETIRED_DIRECTOR.has(id): return
	if s.horror_seen.has(id) or _armed.has(id): return
	var rec: Variant = c.get("capture")
	if rec != null and rec.active(): return
	_armed[id] = {"event": e.duplicate(true), "at": _feet(), "zone": _zone_id(), "age": 0.0}

func update(dt: float, blocked := false) -> void:
	var s: GameState = c["state"]
	if s.chapter != _chapter:
		_chapter = s.chapter
		_armed.clear()
		thresholds.invalidate()
	# Часы отложенных действий стоят под паузой, ридером и меню.
	if blocked:
		thresholds.update(0.0, true)
		return
	if s.chapter == "end":
		thresholds.update(0.0, true)
		_stop_ambient()
		return
	_update_ambient()
	var stamp := generation
	for i in range(_timers.size() - 1, -1, -1):
		if i >= _timers.size(): continue
		var tm: Dictionary = _timers[i]
		tm["left"] = float(tm["left"]) - dt
		if float(tm["left"]) <= 0.0:
			_timers.remove_at(i)
			if int(tm["generation"]) == generation and (tm["cb"] as Callable).is_valid():
				(tm["cb"] as Callable).call()
			if stamp != generation: return
	cooldown = maxf(0.0, cooldown - dt)
	hold_left = maxf(0.0, hold_left - dt)
	if hold_left == 0.0 and ["mandatory", "ambient", "haunt"].has(owner): owner = ""
	var rec: Variant = c.get("capture")
	if rec != null and rec.active():
		thresholds.update(dt, true)
		return
	if external_exclusive():
		if not _live.is_empty(): _end_live()
		# The loft owns its camera route and delegates its one threshold to us.
		var loft_owned: bool = thresholds.active() and bool(thresholds.live.get("camera_route", false))
		for key: String in ["snt", "pursuit"]:
			var runtime: Variant = c.get(key)
			if runtime != null and runtime.has_method("exclusive_runtime") and runtime.exclusive_runtime(): loft_owned = false
		thresholds.update(dt, not loft_owned)
		return
	thresholds.update(dt, hold_left > 0.0 or not _live.is_empty())
	if thresholds.active(): return
	if not _live.is_empty():
		_tick_live(dt)
		return
	if hold_left > 0.0 or s.chapter == "end": return
	for e: Dictionary in EVENTS:
		if String(e["chapter"]) != s.chapter: continue
		var all_need := not (e["need"] as Array).is_empty()
		for flag: String in e["need"]:
			if not s.has(flag): all_need = false
		if all_need: _arm(e)
	for id: String in _armed.keys():
		var armed: Dictionary = _armed[id]
		armed["age"] = float(armed["age"]) + dt
		if String(armed["event"]["chapter"]) != s.chapter:
			_armed.erase(id)
			continue
		# Действие уже завершено; игрок отошёл, закрыл чтение и сменил место.
		if cooldown > 0.0 or float(armed["age"]) < 2.0 or _feet().distance_to(armed["at"]) < 4.0:
			continue
		if ["street-office-exit", "village-shop-exit", "blackout-cellar-return", "loft-barn-pass", "tapes-attic-return"].has(id) \
			and String(armed.get("zone", "")) != "" and _zone_id() == String(armed["zone"]):
			continue
		if not _scares_on():
			_armed.erase(id)
			continue
		if _begin_live(armed["event"]):
			_armed.erase(id)
			break

func _begin_live(e: Dictionary) -> bool:
	var stalk: Variant = c.get("stalk")
	if stalk != null and stalk.active(): return false
	var threat: Variant = c.get("threat")
	if threat != null and threat.is_active():
		var pos := Vector3(float(threat.get("_px")), float(threat.get("_py")), float(threat.get("_pz")))
		if pos.distance_to(_feet()) < 12.0: return false
	var feet := _feet()
	var cam: Camera3D = _camera()
	if cam == null: return false
	var fwd := -cam.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	var side := Vector3(-fwd.z, 0.0, fwd.x)
	var from := feet + fwd * 5.0 - side * 3.2
	var to := feet + fwd * 5.0 + side * 3.2
	var sound_at: Vector3 = e.get("sound_at", from)
	if cam.global_position.distance_to(sound_at) > 14.0: return false
	if String(e["motion"]) == "pass" and not trajectory_clear(from, to):
		# Один шум за твёрдой стеной не создаёт проходящего сквозь неё человека.
		return false
	_time = 0.0
	_live = {"event": e, "from": from, "to": to, "length": 1.3}
	owner = "context"
	cooldown = 8.0 if String(e["motion"]) == "sound" and String(e["sound"]) in ["radio-veranda", "horror-tin", "horror-attic-creak"] else STRONG_COOLDOWN
	var haunt: Variant = c.get("haunt")
	if haunt != null: haunt.hold(4.4)
	var startle: Variant = c.get("startle")
	if startle != null: startle.clear()
	var actors: Variant = c.get("actors")
	if String(e["motion"]) == "pass" and actors != null:
		actors.place("echo", from.x, from.y, from.z, 0.0)
		actors.face("echo", to.x, to.z)
		actors.show("echo", true)
		if actors.has_method("begin_action"): actors.begin_action("echo", "run")
	var heard := _spatial(String(e["sound"]), sound_at, 0.55)
	if not heard and (String(e["motion"]) != "pass" or actors == null):
		_end_live()
		cooldown = 0.0
		return false
	(c["state"] as GameState).horror_seen[String(e["id"])] = true
	return true

func _tick_live(dt: float) -> void:
	_time += dt
	var e: Dictionary = _live["event"]
	if String(e["motion"]) == "pass":
		var a: Variant = c.get("actors")
		if a != null:
			var from: Vector3 = _live["from"]
			var to: Vector3 = _live["to"]
			var p := from.lerp(to, clampf(_time / 1.3, 0.0, 1.0))
			a.place("echo", p.x, p.y, p.z, 0.0)
			a.face("echo", to.x, to.z)
			if a.has_method("sample_action"): a.sample_action("echo", "run", _time)
	if _time >= float(_live["length"]): _end_live()

func _end_live() -> void:
	if not _live.is_empty() and String(_live["event"]["motion"]) == "pass":
		var a: Variant = c.get("actors")
		if a != null:
			if a.has_method("end_action"): a.end_action("echo")
			a.show("echo", false)
	_live = {}
	if owner == "context": owner = ""

func trajectory_clear(from: Vector3, to: Vector3) -> bool:
	var col: CollisionWorld = c.get("col")
	if col == null: return true
	if absf(from.y - to.y) > 0.3: return false
	var count := maxi(1, int(ceil(from.distance_to(to) / 0.15)))
	for i in count + 1:
		var p := from.lerp(to, float(i) / count)
		if col.point_hit(p.x, p.y + 0.85, p.z, CollisionWorld.ALL_SOLID): return false
		var hit := col.capsule_hit(p + Vector3(0, 0.34, 0), p + Vector3(0, 1.37, 0), 0.32, CollisionWorld.ALL_SOLID)
		if not hit.is_empty() and float(hit.get("depth", 0.0)) > 0.02:
			return false
		var floor_hit := col.ray_down(p.x, p.y + 0.55, p.z, CollisionWorld.ALL_SOLID)
		if floor_hit.is_empty() or absf(float(floor_hit.get("y", p.y + 10.0)) - p.y) > 0.35:
			return false
	return true

func _spatial(id: String, at: Vector3, gain: float) -> bool:
	var a: Variant = c.get("audio")
	if a == null: return false
	return a.has_method("spatial_sfx") and bool(a.spatial_sfx(id, at, gain, 14.0))

func _scares_on() -> bool:
	var cb: Variant = c.get("scaresOn")
	return cb == null or bool(cb.call())

func _feet() -> Vector3:
	var ctrl: Variant = c.get("controls")
	return ctrl.feet() if ctrl != null else Vector3.INF

func _camera() -> Camera3D:
	var chain: Variant = c.get("renderer")
	return chain.camera if chain != null else null


func _update_ambient() -> void:
	var world: Dictionary = c.get("world", {})
	var at: Variant = world.get("zone_at")
	if not at is Callable: return
	var feet := _feet()
	var zone: Dictionary = at.call(feet.x, feet.y, feet.z)
	var id := String(zone.get("id", ""))
	var level := String(zone.get("level", ""))
	var wanted := ""
	if level == "cellar": wanted = "horror-amb-cellar"
	elif ["floor1", "attic", "roof"].has(level): wanted = "horror-amb-house"
	elif id.contains("shore") or id.contains("lake") or id == "pond": wanted = "horror-amb-shore"
	elif id.contains("forest") or id.contains("woods") or id == "field" or id == "outskirts": wanted = "horror-amb-forest"
	if wanted == _ambient_id:
		var moving_audio: Variant = c.get("audio")
		if wanted != "" and moving_audio != null and moving_audio.has_method("spatial_loop"):
			moving_audio.spatial_loop(wanted, feet, true, 0.12, 18.0)
		return
	_stop_ambient()
	var audio: Variant = c.get("audio")
	if wanted != "" and audio != null and audio.has_method("spatial_loop"):
		if bool(audio.spatial_loop(wanted, feet, true, 0.12, 18.0)):
			_ambient_id = wanted


func _stop_ambient() -> void:
	var audio: Variant = c.get("audio")
	if _ambient_id != "" and audio != null and audio.has_method("spatial_loop"):
		audio.spatial_loop(_ambient_id, Vector3.ZERO, false, 0.0, 18.0)
	_ambient_id = ""


func _zone_id() -> String:
	var world: Dictionary = c.get("world", {})
	var cb: Variant = world.get("zone_at")
	if not cb is Callable: return ""
	var feet := _feet()
	var zone: Dictionary = cb.call(feet.x, feet.y, feet.z)
	return String(zone.get("id", ""))

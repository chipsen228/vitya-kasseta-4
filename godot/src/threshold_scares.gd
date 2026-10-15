class_name ThresholdScares
extends RefCounted

# A threshold is a directed plane in world space, never a delayed radius check.
# `from`/`to` are feet for walkers and the centre of the face for window props.
const EVENTS := [
	{"id":"startle/stairs-up", "min":"light", "at":Vector3(-2.90,3.12,12.68), "normal":Vector3.RIGHT,
		"half_width":0.65, "dy":0.5, "from":Vector3(2.38,4.58,11.80), "to":Vector3(2.38,4.58,11.80),
		"face":true, "sound":"snt-window-breath", "second":"horror-window-hit", "gain":0.85, "duration":1.45, "look_grace":1.2},
	{"id":"startle/kitchen-first", "aliases":["startle/hall-first","startle/veranda-back"], "min":"light",
		"at":Vector3(-2.30,0.45,6.55), "normal":Vector3.FORWARD, "half_width":0.7, "dy":0.6,
		"from":Vector3(-4.10,0,4.10), "to":Vector3(-0.30,0,4.10),
		"sound":"horror-run-wood", "duration":0.8},
	{"id":"blackout-cellar-return", "aliases":["startle/cellar-tin"], "min":"dark", "need":["stash-found"],
		"at":Vector3(-4.05,-0.45,8.50), "normal":Vector3.UP, "half_width":1.2, "dy":1.2,
		"from":Vector3(-3.60,2.65,8.50), "to":Vector3(-3.60,2.65,8.50), "sound_only":true,
		"sound":"horror-run-wood", "second":"snt-cellar-latch", "duration":1.4},
	{"id":"startle/shed-out", "aliases":["loft-barn-pass","startle/shed-in"], "min":"arrive",
		"at":Vector3(6.80,0,9.60), "normal":Vector3.FORWARD, "half_width":0.8, "dy":0.5,
		"from":Vector3(5.20,0,9.05), "to":Vector3(8.45,0,9.05),
		"sound":"horror-cloth", "duration":1.1},
	{"id":"village-shop-exit", "aliases":["startle/shop-out"], "min":"village", "need":["shop-open"],
		"at":Vector3(28.90,0,-6.65), "normal":Vector3.BACK, "half_width":0.8, "dy":0.7,
		"from":Vector3(27.50,0.8,-6.60), "to":Vector3(27.50,0.8,-6.60), "sound_only":true,
		"sound":"snt-panel", "second":"horror-run-gravel", "duration":1.25},
	{"id":"bath-wall-return", "aliases":["startle/banya-out"], "min":"village", "need":["banya-written"],
		"at":Vector3(5.0,0.12,21.15), "normal":Vector3.FORWARD, "half_width":0.65, "dy":0.5,
		"from":Vector3(2.50,1.5,22.3), "to":Vector3(2.50,1.5,22.3), "face":true,
		"sound":"snt-wet-porch", "duration":0.85},
	{"id":"startle/banya-ladder", "min":"village", "camera_route":true,
		"at":Vector3(6.20,2.50,23.90), "normal":Vector3.LEFT, "half_width":0.85, "dy":0.3,
		"from":Vector3(4.75,2.66,24.15), "to":Vector3(4.75,2.66,24.15), "face":true,
		"sound":"horror-attic-creak", "second":"snt-beam", "duration":0.75},
	{"id":"mill-steps-return", "min":"village", "need":["mill-braked"],
		"at":Vector3(22.10,8.30,-27.46), "normal":Vector3.LEFT, "half_width":0.9, "dy":0.5,
		"from":Vector3(19.95,9.66,-29.45), "to":Vector3(19.95,9.66,-29.45), "face":true,
		"sound":"snt-mill-touch", "duration":0.6},
	{"id":"snt-nina-porch", "min":"village", "need":["snt-watch-read"],
		"at":Vector3(27.5,0,-41.5), "normal":Vector3.FORWARD, "half_width":1.1, "dy":0.6,
		"from":Vector3(26.5,0,-42.0), "to":Vector3(28.5,0,-42.0),
		"sound":"snt-shutter", "duration":0.8},
	{"id":"snt-semyon-workshop", "min":"village", "need":["snt-nina-greenhouse"],
		"at":Vector3(-26,0,-50.25), "normal":Vector3.BACK, "half_width":1.0, "dy":0.6,
		"from":Vector3(-25.4,0.4,-49), "to":Vector3(-25.4,0.4,-49), "sound_only":true,
		"sound":"snt-bucket", "second":"horror-cloth", "duration":1.3},
	{"id":"snt-zuev-window", "min":"village", "need":["snt-radio-heard"],
		"at":Vector3(7.1,0,-58.3), "normal":Vector3.FORWARD, "half_width":1.2, "dy":0.6,
		"from":Vector3(7.1,1.6,-59.25), "to":Vector3(7.1,1.6,-59.25), "face":true,
		"sound":"snt-window-breath", "duration":0.6},
	{"id":"snt-forest-crossing", "min":"village", "need":["snt-booth-used"],
		"at":Vector3(7.1,0,-72.0), "normal":Vector3.FORWARD, "half_width":1.0, "dy":0.6,
		"from":Vector3(6.2,0,-74.0), "to":Vector3(8.1,0,-74.0),
		"sound":"snt-forest-steps", "duration":0.8},
	{"id":"house-entry-shadow", "min":"arrive",
		"at":Vector3(-2.3,0.45,7.0), "normal":Vector3.BACK, "half_width":0.85, "dy":0.6,
		"from":Vector3(-2.3,0.45,8.65), "to":Vector3(-2.3,0.45,8.65), "action":"peek",
		"sound":"horror-door", "second":"horror-cloth", "gain":0.85, "duration":1.5, "look_grace":1.2},
	{"id":"house-roof-shadow", "aliases":["startle/roof-in"], "min":"loft",
		"at":Vector3(-3.2,5.9,13.8), "normal":Vector3.BACK, "half_width":1.5, "dy":0.45,
		"from":Vector3(-4.15,7.10,15.05), "to":Vector3(-4.15,7.10,15.05), "face":true,
		"sound":"horror-run-wood", "second":"snt-beam", "gain":0.9, "duration":1.6, "look_grace":1.2},
]

const RETIRED_DIRECTOR := ["loft-barn-pass", "blackout-cellar-return", "village-shop-exit", "bath-wall-return", "mill-steps-return"]
const RETIRED_STARTLE := ["stairs-up", "kitchen-first", "hall-first", "veranda-back", "shed-out", "shed-in", "shop-out", "banya-out", "banya-ladder", "cellar-tin", "roof-in"]
const MAX_STEP := 3.0
var c: Dictionary
var _director_ref: WeakRef
var director: Variant:
	get: return _director_ref.get_ref()
	set(value): _director_ref = weakref(value)
var previous := Vector3.INF
var loft_previous := Vector3.INF
var live: Dictionary = {}
var elapsed := 0.0
var anchors: Dictionary = {}
var _markers: Node3D
var _actor: Variant
var _actor_id := ""
var _prop_rest: Dictionary = {}
var _event_cache: Dictionary = {}
var _look_pending: Dictionary = {}
var _look_left := 0.0

func _init(context: Dictionary, owner: Variant) -> void:
	c = context
	director = owner

func active() -> bool:
	return not live.is_empty()

func invalidate() -> void:
	_end()
	_look_pending = {}
	for node: Node3D in _prop_rest:
		if is_instance_valid(node): node.transform = _prop_rest[node]
	_prop_rest.clear()
	_event_cache.clear()
	previous = Vector3.INF
	loft_previous = Vector3.INF

func sync_position() -> void:
	previous = _feet()

func update(dt: float, blocked: bool) -> void:
	var feet := _feet()
	var old := previous
	previous = feet
	if blocked or not _scares_on() or _speech_active():
		_look_pending = {}
		_end()
		return
	if active():
		_tick(dt)
		return
	if not _look_pending.is_empty():
		_look_left -= dt
		var e := _look_pending
		var at: Vector3 = e["at"]
		var n: Vector3 = e["normal"]
		var offset := feet - at
		var local := offset.dot(n) >= 0.0 and offset.dot(n) <= 1.8 \
			and absf(offset.y) <= float(e["dy"]) \
			and absf(offset.dot(Vector3(-n.z,0,n.x))) <= float(e["half_width"])
		if _look_left <= 0.0 or not local or not _eligible(e) or not _can_start():
			_look_pending = {}
		elif _begin(e):
			_look_pending = {}
			return
	if old.is_finite() and old.distance_squared_to(feet) < 0.00000001: return
	if not _can_start(): return
	for raw: Dictionary in EVENTS:
		if bool(raw.get("camera_route", false)): continue
		var e := event(raw)
		if _eligible(e) and crossed(e, old, feet):
			if _begin(e): return
			if float(e.get("look_grace",0.0)) > 0.0 and geometry_clear(e):
				_look_pending = e
				_look_left = float(e["look_grace"])
				return

# The bath loft moves its own camera while the body stays beside the ladder.
# Its controller owns this one call; the normal update still tracks the body.
func update_bathloft(dt: float, eye: Vector3, phase: String) -> void:
	var old := loft_previous
	loft_previous = eye if phase == "loft" else Vector3.INF
	if phase != "loft" or not _scares_on() or active() or not _can_start(true): return
	var e := event(EVENTS[6])
	if _eligible(e) and crossed(e, old, eye): _begin(e)

func event(raw: Dictionary) -> Dictionary:
	if _event_cache.has(raw["id"]): return _event_cache[raw["id"]]
	var e := raw.duplicate(true)
	var world: Dictionary = c.get("world", {})
	var snt: Dictionary = world.get("snt", {})
	var overrides: Dictionary = snt.get("scare_anchors", {})
	if overrides.has(e["id"]): e.merge(overrides[e["id"]], true)
	_event_cache[e["id"]] = e
	return e

static func crossed(e: Dictionary, old: Vector3, now: Vector3) -> bool:
	if not old.is_finite() or not now.is_finite() or old.distance_to(now) > MAX_STEP: return false
	var at: Vector3 = e["at"]
	var normal: Vector3 = e["normal"]
	var before := (old - at).dot(normal)
	var after := (now - at).dot(normal)
	if before >= 0.0 or after < 0.0 or after - before < 0.00001: return false
	var hit := old.lerp(now, -before / (after - before)) - at
	if absf(normal.y) > 0.5:
		return Vector2(hit.x, hit.z).length() <= float(e["half_width"])
	var side := Vector3(-normal.z, 0, normal.x)
	return absf(hit.dot(side)) <= float(e["half_width"]) and absf(hit.y) <= float(e["dy"])

func _eligible(e: Dictionary) -> bool:
	var s: GameState = c["state"]
	if s.chapter == "end" or s.hidden or not s.atLeast(String(e["min"])): return false
	for id: String in [e["id"]] + e.get("aliases", []):
		if s.horror_seen.has(id): return false
		if id.begins_with("startle/") and s.has("startle-" + id.trim_prefix("startle/")): return false
	for flag: String in e.get("need", []):
		if not s.has(flag): return false
	return true

func _can_start(bathloft := false) -> bool:
	if director.cooldown > 0.0 or director.hold_left > 0.0 or not director._live.is_empty(): return false
	for key: String in ["capture", "pursuit", "stalk"]:
		var other: Variant = c.get(key)
		if other != null and other.has_method("active") and bool(other.active()): return false
	for key: String in ["snt", "outskirts", "pursuit"]:
		if bathloft and key == "outskirts": continue
		var other: Variant = c.get(key)
		if other != null and other.has_method("exclusive_runtime") and bool(other.exclusive_runtime()): return false
	if _speech_active(): return false
	var threat: Variant = c.get("threat")
	if threat is Threat and threat.is_active() and threat.pos.distance_to(_feet()) < 12.0: return false
	return true

func _speech_active() -> bool:
	var voice: Variant = c.get("voice")
	if voice != null and voice.has_method("dialogue_active") and bool(voice.dialogue_active()): return true
	var ui: Variant = c.get("ui")
	return ui is Overlays and ui.busy


func reserved_near() -> bool:
	var feet := _feet()
	if not feet.is_finite(): return false
	for raw: Dictionary in EVENTS:
		if bool(raw.get("camera_route", false)): continue
		var e := event(raw)
		if _eligible(e) and feet.distance_squared_to(e["at"]) < 16.0: return true
	return false

func _begin(e: Dictionary) -> bool:
	var from: Vector3 = e["from"]
	var to: Vector3 = e["to"]
	var face := bool(e.get("face", false))
	var visual := not bool(e.get("sound_only", false))
	if visual and not geometry_clear(e): return false
	var cam := _camera()
	if visual and (cam == null or not visible_from(cam.global_position, from, face)):
		return false
	var in_view := visual and cam.is_position_in_frustum(from + (Vector3.ZERO if face else Vector3(0,1.45,0)))
	if visual and not in_view: return false
	_actor = c.get("episodeActors")
	_actor_id = "window_face" if face else "walker"
	if _actor == null:
		_actor = c.get("actors") if not face else null
		_actor_id = "echo"
	var shown := visual and _actor != null
	# Acquire the old shared figure before showing; clearing afterward hides it.
	if shown:
		var haunt: Variant = c.get("haunt")
		if haunt != null: haunt.hold(float(e["duration"]) + 2.0)
		var startle: Variant = c.get("startle")
		if startle != null: startle.clear()
		_actor.place(_actor_id, from.x, from.y, from.z, 0.0)
		var target := _feet() if face or from.distance_squared_to(to) < 0.0001 else to
		_actor.face(_actor_id, target.x, target.z)
		_actor.show(_actor_id, true)
		if _actor.has_method("begin_action"): _actor.begin_action(_actor_id, String(e.get("action", "peek" if face else "run")))
	var heard := _sound(String(e["sound"]), e.get("sound_at", from), float(e.get("gain", 0.6)))
	if not heard and not (shown and in_view):
		if shown:
			if _actor.has_method("end_action"): _actor.end_action(_actor_id)
			_actor.show(_actor_id, false)
		_actor = null
		_actor_id = ""
		return false
	var s: GameState = c["state"]
	for id: String in [e["id"]] + e.get("aliases", []):
		s.horror_seen[id] = true
	live = e.duplicate()
	live["shown"] = shown
	var prop: Variant = e.get("prop_node")
	if prop is Node3D and is_instance_valid(prop):
		if not _prop_rest.has(prop): _prop_rest[prop] = prop.transform
		live["prop_rest"] = _prop_rest[prop]
	elapsed = 0.0
	director.cooldown = 75.0
	director.owner = "threshold"
	_make_markers(e)
	return true

func _tick(dt: float) -> void:
	# Doors and gates may change while a figure is crossing their opening.
	if bool(live.get("shown", false)) and not geometry_clear(live):
		_end()
		return
	elapsed += dt
	var prop: Variant = live.get("prop_node")
	if prop is Node3D and is_instance_valid(prop) and live.has("prop_rest"):
		var rest: Transform3D = live["prop_rest"]
		var weight := clampf(elapsed / 0.38,0,1)
		if String(live.get("prop_kind","")) == "bucket":
			prop.transform = rest
			prop.position.y -= float(live.get("prop_drop",0.35)) * weight * weight
			prop.rotate_z(weight * 0.95)
		else:
			prop.transform = rest
			prop.rotate_y(sin(weight*PI) * 1.1)
	if bool(live.get("shown", false)) and _actor != null:
		var from: Vector3 = live["from"]
		var p := from.lerp(live["to"], clampf(elapsed / float(live["duration"]), 0, 1))
		_actor.place(_actor_id, p.x, p.y, p.z, 0.0)
		var target := _feet() if bool(live.get("face", false)) or Vector3(live["from"]).distance_squared_to(live["to"]) < 0.0001 else Vector3(live["to"])
		_actor.face(_actor_id, target.x, target.z)
		if _actor.has_method("sample_action"):
			_actor.sample_action(_actor_id, String(live.get("action", "peek" if bool(live.get("face", false)) else "run")), elapsed)
	if elapsed >= 0.42 and live.has("second"):
		_sound(String(live["second"]), live.get("sound_at", live["from"]), float(live.get("gain", 0.6)) * 0.8)
		live.erase("second")
	if elapsed >= float(live["duration"]): _end(false)

func _end(stop_sound := true) -> void:
	if stop_sound:
		var prop: Variant = live.get("prop_node")
		if prop is Node3D and is_instance_valid(prop) and live.has("prop_rest"):
			prop.transform = live["prop_rest"]
	if bool(live.get("shown", false)) and _actor != null:
		if _actor.has_method("end_action"): _actor.end_action(_actor_id)
		_actor.show(_actor_id, false)
	if stop_sound:
		var a: Variant = c.get("audio")
		if a != null and a.has_method("stop_spatial_owner"): a.stop_spatial_owner("threshold")
	live.clear()
	_actor = null
	_actor_id = ""
	if director.owner == "threshold": director.owner = ""

func geometry_clear(e: Dictionary) -> bool:
	if bool(e.get("sound_only", false)): return true
	if not bool(e.get("face", false)): return director.trajectory_clear(e["from"], e["to"])
	var col: CollisionWorld = c.get("col")
	if col == null: return true
	var p: Vector3 = e["from"]
	if col.point_hit(p.x,p.y,p.z,CollisionWorld.ALL_SOLID): return false
	var hit := col.capsule_hit(p - Vector3(0,0.06,0),p + Vector3(0,0.06,0),0.105,CollisionWorld.ALL_SOLID)
	return hit.is_empty() or float(hit.get("depth",0.0)) < 0.015

func visible_from(eye: Vector3, at: Vector3, face: bool) -> bool:
	var col: CollisionWorld = c.get("col")
	if col == null: return true
	var target := at + (Vector3.ZERO if face else Vector3(0,1.45,0))
	var d := target - eye
	if d.length() < 0.01: return false
	var hit := Interact._ray_solid(col, eye, d.normalized(), d.length(), CollisionWorld.ALL_SOLID)
	return hit == INF or (hit > 0.0 and hit > d.length() - 0.002)

func _sound(id: String, at: Vector3, gain: float) -> bool:
	var a: Variant = c.get("audio")
	if a == null or not a.has_method("spatial_sfx"): return false
	if _camera() != null and _camera().global_position.distance_to(at) > 18.0: return false
	if a is GameAudio: return bool(a.spatial_sfx(id, at, gain, 20.0, "threshold", 2))
	return bool(a.spatial_sfx(id, at, gain, 20.0))

func _make_markers(e: Dictionary) -> void:
	if anchors.has(e["id"]): return
	var renderer: Variant = c.get("renderer")
	if renderer == null or not is_instance_valid(renderer.world_root): return
	if not is_instance_valid(_markers):
		_markers = Node3D.new()
		_markers.name = "ThresholdScareAnchors"
		renderer.world_root.add_child(_markers)
	var group := Node3D.new()
	group.name = String(e["id"]).replace("/", "_")
	_markers.add_child(group)
	for key: String in ["at", "from", "to"]:
		var marker := Marker3D.new()
		marker.name = key
		group.add_child(marker)
		marker.global_position = e[key]
	anchors[e["id"]] = group

func _scares_on() -> bool:
	var cb: Variant = c.get("scaresOn")
	return cb == null or bool(cb.call())

func _feet() -> Vector3:
	var ctrl: Variant = c.get("controls")
	return ctrl.feet() if ctrl != null else Vector3.INF

func _camera() -> Camera3D:
	var renderer: Variant = c.get("renderer")
	return renderer.camera if renderer != null else null

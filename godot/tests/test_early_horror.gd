# Первые испуги при обычном взгляде вперёд и позднем повороте головы.
# Проверяет реальные Camera3D.frustum и ThresholdScares.update без GPU/мира.
extends SceneTree

const EARLY := ["house-entry-shadow", "house-roof-shadow"]
const EYE_HEIGHT := Player.STAND_HEIGHT - Player.EYE_DROP

class Controls extends RefCounted:
	var p := Vector3.ZERO
	func feet() -> Vector3: return p

class Renderer extends RefCounted:
	var camera: Camera3D
	var world_root: Node3D

class Sounds extends RefCounted:
	var played: Array[String] = []
	func spatial_sfx(id: String, _at: Vector3, _gain: float, _distance: float) -> bool:
		played.append(id)
		return true
	func stop_spatial_owner(_id: String) -> void: pass

class Figures extends RefCounted:
	var shown := false
	var faced := Vector2.INF
	func place(_id: String, _x: float, _y: float, _z: float, _yaw := 0.0) -> void: pass
	func face(_id: String, x: float, z: float) -> void: faced = Vector2(x,z)
	func show(_id: String, on: bool) -> void: shown = on
	func begin_action(_id: String, _action: String) -> void: pass
	func sample_action(_id: String, _action: String, _time: float) -> void: pass
	func end_action(_id: String) -> void: pass

var errors: Array[String] = []
var context: Dictionary
var state := GameState.new()
var controls := Controls.new()
var renderer := Renderer.new()
var sounds := Sounds.new()
var figures := Figures.new()
var director: HorrorDirector
var threshold: ThresholdScares
var checked := 0


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(640, 360)
	viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	root.add_child(viewport)
	renderer.world_root = Node3D.new()
	viewport.add_child(renderer.world_root)
	renderer.camera = Camera3D.new()
	renderer.camera.fov = 70.0
	renderer.camera.keep_aspect = Camera3D.KEEP_HEIGHT
	renderer.world_root.add_child(renderer.camera)
	context = {"state": state, "controls": controls, "renderer": renderer,
		"audio": sounds, "episodeActors": figures}
	director = HorrorDirector.new(context)
	context["horror"] = director
	threshold = director.thresholds
	for id: String in EARLY:
		var e := _definition(id)
		_check(not e.is_empty(), "missing early event " + id)
		if e.is_empty(): continue
		_natural_gaze(e)
		_late_look(e)
		_cancel_pending(e, "leave")
		_cancel_pending(e, "backtrack")
		_cancel_pending(e, "pause")
		_cancel_pending(e, "expiry")
	director.invalidate()
	context.clear()
	viewport.free()
	for error: String in errors: printerr("FAIL test_early_horror: ", error)
	print("test_early_horror: %s — %d checks, natural FOV70, late look, leave/backtrack/pause/expiry" % ["PASS" if errors.is_empty() else "FAIL", checked])
	quit(0 if errors.is_empty() else 1)


func _definition(id: String) -> Dictionary:
	for e: Dictionary in ThresholdScares.EVENTS:
		if String(e["id"]) == id: return e
	return {}


func _reset(e: Dictionary) -> void:
	director.invalidate()
	state.reset()
	state.chapter = String(e["min"])
	sounds.played.clear()
	figures.shown = false


func _step(e: Dictionary, offset: float, forward := true, dt := 0.05, blocked := false) -> void:
	var direction: Vector3 = e["normal"]
	controls.p = Vector3(e["at"]) + direction * offset
	renderer.camera.position = controls.p + Vector3(0.0, EYE_HEIGHT, 0.0)
	# Смотрим вдоль пути на уровне глаз; координаты актёра не используются.
	renderer.camera.look_at(renderer.camera.position + direction * (1.0 if forward else -1.0), Vector3.UP)
	threshold.update(dt, blocked)


func _natural_gaze(e: Dictionary) -> void:
	_reset(e)
	var id := String(e["id"])
	_step(e, -0.25)
	_check(not state.horror_seen.has(id), id + ": approach consumed the event")
	_step(e, 0.20)
	_check(threshold.active() and state.horror_seen.has(id) and figures.shown,
		id + ": normal forward gaze missed the scare")
	_check(sounds.played == [String(e["sound"])], id + ": first sound missing")
	_check(figures.faced.is_equal_approx(Vector2(controls.p.x,controls.p.z)),id + ": stationary scare faced away from the player")
	threshold.update(0.45, false)
	_check(figures.faced.is_equal_approx(Vector2(controls.p.x,controls.p.z)),id + ": stationary scare turned away during playback")
	_check(sounds.played.has(String(e["second"])), id + ": second sound missing")
	threshold.update(2.0, false)
	_check(not threshold.active() and not figures.shown, id + ": actor remained after the scare")
	var count := sounds.played.size()
	director.cooldown = 0.0
	_step(e, -0.25)
	_step(e, 0.20)
	_check(sounds.played.size() == count, id + ": scare replayed after another crossing")


func _pending(e: Dictionary) -> void:
	_reset(e)
	_step(e, -0.25, false)
	_step(e, 0.20, false)
	var id := String(e["id"])
	_check(not threshold.active() and not state.horror_seen.has(id) and sounds.played.is_empty(),
		id + ": crossing while looking away consumed the event")
	_check(String(threshold._look_pending.get("id", "")) == id, id + ": no pending look grace")


func _late_look(e: Dictionary) -> void:
	_pending(e)
	var id := String(e["id"])
	_step(e, 0.20, false, 0.60)
	_step(e, 0.20, false, 0.45)
	_check(not state.horror_seen.has(id), id + ": waiting while looking away consumed the event")
	_step(e, 0.20, true, 0.05)
	_check(threshold.active() and state.horror_seen.has(id) and figures.shown,
		id + ": a turn after 1.10 seconds did not play the event")
	_check(threshold._look_pending.is_empty(), id + ": pending remained after successful playback")


func _cancel_pending(e: Dictionary, why: String) -> void:
	_pending(e)
	var id := String(e["id"])
	match why:
		"leave": _step(e, 2.05, false)
		"backtrack": _step(e, -0.25, false)
		"pause": _step(e, 0.20, false, 0.05, true)
		"expiry":
			for _tick in 13: _step(e, 0.20, false, 0.10)
	_check(threshold._look_pending.is_empty(), id + ": " + why + " did not clear grace")
	_check(not state.horror_seen.has(id) and sounds.played.is_empty() and not figures.shown,
		id + ": " + why + " consumed an unseen scare")
	var offset := -0.25 if why == "backtrack" else (2.05 if why == "leave" else 0.20)
	_step(e, offset)
	_check(not threshold.active() and not state.horror_seen.has(id), id + ": " + why + " fired later without crossing")
	_step(e, -0.25)
	_step(e, 0.20)
	_check(threshold.active() and state.horror_seen.has(id), id + ": " + why + " prevented a fresh crossing")


func _check(ok: bool, message: String) -> void:
	checked += 1
	if not ok: errors.append(message)

class_name EverydayInteractions
extends RefCounted

const RADIO_OWNER := "decor-p09-radio"
const RADIO_SECONDS := 4.0
const RADIO_COOLDOWN := 8.0

var c: Dictionary
var world: Dictionary
var definitions: Dictionary = {}
var animations: Dictionary = {}
var radio_remaining := 0.0
var radio_cooldown := 0.0
var _generation := 0
var _chapter := ""


func _init(context: Dictionary, built: Dictionary) -> void:
	c = context
	world = built
	for d: Dictionary in built.get("definitions", []):
		definitions[String(d["id"])] = d
	var s: Variant = c.get("state")
	if s is GameState: resync(s)


func register(interact: Interact) -> void:
	for id: String in definitions:
		var d: Dictionary = definitions[id]
		var target := {"id": id, "pos": d["point"], "r": 2.2, "cone": 0.52,
			"priority": -0.75, "los_mask": CollisionWorld.ALL_SOLID,
			"prompt": func(s: GameState) -> String: return _prompt(d, s),
			"when": func(s: GameState) -> bool:
				return _available(s) and not animations.has(id) \
					and (String(d["kind"]) != "radio" or radio_remaining > 0.0 or radio_cooldown <= 0.0),
			"onUse": func(_ctx: Dictionary) -> void: use(id)}
		if String(d["kind"]) == "gate": target["los_ignore_blocker"] = d["blocker"]
		interact.add(target)


func _available(s: GameState) -> bool:
	var capture: Variant = c.get("capture")
	if s.chapter == "end" or s.hidden or (capture != null and capture.active()): return false
	var cutscene: Variant = c.get("cutscene")
	if cutscene != null and cutscene.playing: return false
	for key: String in ["snt", "outskirts"]:
		var quest: Variant = c.get(key)
		if quest != null and quest.has_method("exclusive_runtime") and quest.exclusive_runtime(): return false
	var horror: Variant = c.get("horror")
	return horror == null or not horror.exclusive()


func _prompt(d: Dictionary, s: GameState) -> String:
	match String(d["kind"]):
		"gate": return "прикрыть калитку" if s.has(d["flag"]) else "открыть калитку"
		"cabinet": return "закрыть шкафчик" if s.has(d["flag"]) else "открыть шкафчик"
		"barrel": return "закрыть крышку бочки" if s.has(d["flag"]) else "поднять крышку бочки"
		"pump": return "качнуть ручку насоса"
		"radio": return "выключить приёмник" if radio_remaining > 0.0 else "включить приёмник"
	return "прочитать объявления"


func use(id: String) -> bool:
	if not definitions.has(id) or animations.has(id): return false
	var s: GameState = c["state"]
	if s.chapter != _chapter: resync(s)
	if not _available(s): return false
	var d: Dictionary = definitions[id]
	var kind := String(d["kind"])
	if kind == "notice":
		var generation := _generation
		var chapter := s.chapter
		c["ui"].setReaderTitle(d["title"])
		c["ui"].openReader(d["title"], d["pages"], func() -> void:
			if generation == _generation and s.chapter == chapter and _available(s):
				s.set_flag(d["flag"]))
		return true
	if kind == "radio":
		if radio_remaining > 0.0:
			_stop_radio()
			return true
		if radio_cooldown > 0.0: return false
		var audio: Variant = c.get("audio")
		if audio != null:
			audio.spatial_sfx("radio-veranda", d["point"], 0.35, 15.0, RADIO_OWNER)
		radio_remaining = RADIO_SECONDS
		radio_cooldown = RADIO_COOLDOWN
		(d["moving"] as Node3D).rotation.z = 0.75
		return true
	var open := not s.has(d["flag"])
	if kind == "gate" and not open and not _arc_clear(d, float(d["angle"]), 0.0):
		_say("Калитка заденет тебя. Отойди от створки.")
		return false
	animations[id] = {"elapsed": 0.0, "open": open,
		"from": _moving_angle(d), "to": float(d.get("angle", 0.0)) if open else 0.0}
	if kind == "gate": _block(d, false)
	var audio: Variant = c.get("audio")
	if audio != null:
		var sound := "horror-tin" if kind == "barrel" else "click" if kind == "pump" else "horror-door"
		audio.spatial_sfx(sound, d["point"], 0.30, 9.0)
	return true


func update(dt: float) -> void:
	var s: GameState = c["state"]
	if s.chapter != _chapter:
		resync(s)
		return
	if not _available(s):
		cancel_runtime()
		return
	radio_cooldown = maxf(0.0, radio_cooldown - dt)
	if radio_remaining > 0.0:
		radio_remaining = maxf(0.0, radio_remaining - dt)
		if radio_remaining <= 0.0:
			_stop_radio()
	for id: String in animations.keys():
		var d: Dictionary = definitions[id]
		var a: Dictionary = animations[id]
		if String(d["kind"]) == "gate" and not bool(a["open"]) \
				and not _arc_clear(d, _moving_angle(d), 0.0):
			animations.erase(id)
			_apply_stable(d, s)
			_say("Створка упирается. Отойди от калитки.")
			continue
		a["elapsed"] = float(a["elapsed"]) + dt
		var t := clampf(float(a["elapsed"]) / float(d["seconds"]), 0.0, 1.0)
		if String(d["kind"]) == "pump":
			(d["moving"] as Node3D).rotation.z = sin(t * TAU) * 0.48
		else:
			_set_angle(d, lerpf(float(a["from"]), float(a["to"]), t * t * (3.0 - 2.0 * t)))
		if t >= 1.0:
			if String(d["kind"]) != "pump": s.set_flag(d["flag"], bool(a["open"]))
			animations.erase(id)
			_apply_stable(d, s)
			if String(d["kind"]) == "gate" and not bool(a["open"]):
				var audio: Variant = c.get("audio")
				if audio != null: audio.spatial_sfx("horror-latch", d["point"], 0.24, 8.0)


func cancel_runtime(preserve_player := true) -> void:
	_generation += 1
	var s: Variant = c.get("state")
	if preserve_player and s is GameState:
		for id: String in animations:
			var d: Dictionary = definitions[id]
			if String(d["kind"]) == "gate" and bool(animations[id]["open"]) \
					and not _arc_clear(d, _moving_angle(d), 0.0):
				# Отмена не возвращает закрытую створку на вошедшего в проём игрока.
				s.set_flag(d["flag"], true)
	animations.clear()
	radio_cooldown = 0.0
	_stop_radio()
	if s is GameState:
		for d: Dictionary in definitions.values(): _apply_stable(d, s)


func resync(s: GameState) -> void:
	# Restore выполняется перед синхронным переносом игрока к checkpoint.
	cancel_runtime(false)
	_chapter = s.chapter
	for d: Dictionary in definitions.values(): _apply_stable(d, s)


func _stop_radio() -> void:
	radio_remaining = 0.0
	var audio: Variant = c.get("audio")
	if audio != null and audio.has_method("stop_spatial_owner"):
		audio.stop_spatial_owner(RADIO_OWNER)
	if definitions.has(RADIO_OWNER):
		(definitions[RADIO_OWNER]["moving"] as Node3D).rotation.z = 0.0


func _apply_stable(d: Dictionary, s: GameState) -> void:
	match String(d["kind"]):
		"gate", "cabinet", "barrel":
			var open := s.has(d["flag"])
			_set_angle(d, float(d["angle"]) if open else 0.0)
			if d.has("blocker"): _block(d, not open)
		"pump":
			(d["moving"] as Node3D).rotation.z = 0.0


func _block(d: Dictionary, active: bool) -> void:
	var col: CollisionWorld = c.get("col")
	if col == null or col.is_blocker_active(d["blocker"]) == active: return
	col.set_blocker_active(d["blocker"], active)
	var physics: Variant = c.get("physics")
	if physics != null: physics.sync()


func _moving_angle(d: Dictionary) -> float:
	var moving: Node3D = d["moving"]
	return moving.rotation.x if String(d.get("axis", "y")) == "x" else moving.rotation.y


func _set_angle(d: Dictionary, angle: float) -> void:
	var moving: Node3D = d["moving"]
	if String(d.get("axis", "y")) == "x": moving.rotation.x = angle
	else: moving.rotation.y = angle


func _arc_clear(d: Dictionary, from: float, to: float) -> bool:
	var controls: Variant = c.get("controls")
	if controls == null: return true
	var feet: Vector3 = controls.feet()
	var hinge: Vector3 = d["hinge"]
	var height := float(controls.get("height")) if controls is Player else Player.STAND_HEIGHT
	if feet.y > hinge.y + float(d["height"]) + 0.02 or feet.y + height < hinge.y: return true
	var point := Vector2(feet.x - hinge.x, feet.z - hinge.z)
	var width := float(d["width"])
	# 0.09 покрывает толщину створки и промежутки между пробами дуги.
	var radius := Player.RADIUS + 0.09
	for sample in 41:
		var angle := lerpf(from, to, float(sample) / 40.0)
		var tip := Vector2(cos(angle), -sin(angle)) * width
		var along := clampf(point.dot(tip) / tip.length_squared(), 0.0, 1.0)
		if point.distance_squared_to(tip * along) <= radius * radius: return false
	return true


func _say(text: String) -> void:
	var ui: Variant = c.get("ui")
	if ui != null: ui.say(text, 2.5)

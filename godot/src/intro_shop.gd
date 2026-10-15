# Приезд к сельпо перед первой главой. Флаги вступления отделены от позднего
# квеста с ключом и бегунком; retry продолжает текущий шаг у магазина.
extends RefCounted

const CAR_AT := Vector3(29.8, 0.0, -3.2)
const PLAYER_AT := Vector3(28.9, 0.0, -5.5)
const NEIGHBOUR_AT := Vector3(31.7, 0.0, -6.1)
const BLOCKER := "intro-shop-car"
const DRIVE_SECONDS := 5.5

var c: Dictionary
var data: Dictionary
var active := false
var _attempt := 0
var _done: Callable
var _car: Node3D
var _car_transform := Transform3D.IDENTITY
var _light_snapshot: Variant = null
var _blocker_added := false
var _dialogue_pending := false
var _arrival_light: OmniLight3D
var _car_collider: Dictionary = {}
var _car_collider_origin := Vector3.ZERO


func _init(context: Dictionary) -> void:
	c = context
	data = JSON.parse_string(FileAccess.get_file_as_string("res://data/intro_shop.json"))


func register() -> void:
	var interact: Variant = c.get("interact")
	if interact == null: return
	interact.add({
		"id": "intro-shop-door", "pos": Vector3(28.9, 1.2, -7.05),
		"r": 2.6, "priority": 8,
		"prompt": func(_s: GameState) -> String: return "постучать в дверь сельпо",
		"when": func(s: GameState) -> bool: return _available(s) and not s.has("intro-shop-checked"),
		"onUse": func(_ctx: Dictionary) -> void: check_door(),
	})
	interact.add({
		"id": "intro-shop-talk", "pos": NEIGHBOUR_AT + Vector3.UP * 1.35,
		"r": 3.0, "priority": 8,
		"prompt": func(_s: GameState) -> String: return "поговорить с Аркадием",
		"when": func(s: GameState) -> bool: return _available(s) and s.has("intro-shop-checked") and not s.has("intro-shop-talked"),
		"onUse": func(_ctx: Dictionary) -> void: talk(),
	})
	interact.add({
		"id": "intro-shop-leave", "pos": CAR_AT + Vector3(0.0, 0.9, -0.75),
		"r": 2.5, "priority": 8,
		"prompt": func(_s: GameState) -> String: return "ехать к дому Вити",
		"when": func(s: GameState) -> bool: return _available(s) and s.has("intro-shop-talked"),
		"onUse": func(_ctx: Dictionary) -> void: leave(),
	})
	var renderer: Variant = c.get("renderer")
	if renderer != null and renderer.world_root != null:
		_sign(renderer.world_root, "intro-shop-sign", "СЕЛЬПО", Vector3(28.9, 2.42, -7.08), 0.008)
		_sign(renderer.world_root, "intro-shop-notice", "ЗАКРЫТО\nс 09.08", Vector3(28.9, 1.56, -7.07), 0.0025)


func _sign(parent: Node3D, id: String, text: String, at: Vector3, pixel: float) -> void:
	if parent.has_node(NodePath(id)): return
	var label := Label3D.new()
	label.name = id
	label.text = text
	label.font = Overlays.tracked_font(1)
	label.font_size = 42
	label.pixel_size = pixel
	label.modulate = Color(0.66, 0.63, 0.53)
	label.outline_size = 2
	label.position = at
	label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	label.visibility_range_end = 35.0
	parent.add_child(label)


func _available(s: GameState) -> bool:
	return active and s.chapter == "prologue" and s.has("intro-shop-arrived")


func task(s: GameState) -> Variant:
	if not s.has("intro-shop-arrived"): return null
	if not s.has("intro-shop-checked"): return data["tasks"]["door"]
	if not s.has("intro-shop-talked"): return data["tasks"]["talk"]
	return data["tasks"]["leave"]


func enter(on_done: Callable) -> void:
	cancel()
	active = true
	_done = on_done
	var token := _attempt
	var s: GameState = c["state"]
	var controls: Variant = c["controls"]
	controls.place(PLAYER_AT.x, PLAYER_AT.y, PLAYER_AT.z, 0.0)
	controls.pitch = 0.0
	controls.pitch_target = 0.0
	var lights: Variant = c.get("lights")
	if lights != null:
		if _light_snapshot == null or not s.has("intro-shop-arrived"):
			_light_snapshot = lights.snapshot()
		if lights.has_method("set_story_night"):
			lights.set_story_night(float(LightRig.STORY_NIGHT["arrival"]))
		lights.set_off_grid("shop-win", true)
		lights.setLamp("shop-win", true)
	c["audio"].start_outdoors()
	var neighbours: Variant = c.get("neighbours")
	if neighbours != null: neighbours.set_arkady("off")
	var actors: Variant = c.get("actors")
	if actors != null:
		actors.place("arkady", NEIGHBOUR_AT.x, NEIGHBOUR_AT.y, NEIGHBOUR_AT.z, 0.0)
		actors.face("arkady", PLAYER_AT.x, PLAYER_AT.z)
		actors.show("arkady", true)
	var props: Variant = c.get("props")
	_car = props.get_prop("car") if props != null else null
	if _car != null:
		_car_transform = _car.transform
		_move_car_collider(props, CAR_AT - _car.position)
		_car.position = CAR_AT
	if _car_collider.is_empty(): _set_car_blocker(true)
	var ready := func() -> void:
		if not active or token != _attempt or s.chapter != "prologue": return
		_clear_arrival_light()
		if _car != null: _car.position = CAR_AT
		controls.enabled = true
		controls.request_lock()
		s.set_flag("intro-shop-arrived")
		c["chapters"].pushTask()
		c["ui"].setChapterTag("СЕЛЬПО · ПРИЕЗД")
		if not s.has("intro-shop-checked"):
			c["ui"].say(data["arrival"], 4.0)
	var cut: Variant = c.get("cutscene")
	var renderer: Variant = c.get("renderer")
	if s.has("intro-shop-arrived") or cut == null or renderer == null or _car == null:
		ready.call()
		return
	controls.enabled = false
	# Основной световой пул замирает вместе с миром на время катсцены.
	# Один источник без теней освещает подъезжающую машину до первого игрового кадра.
	_arrival_light = OmniLight3D.new()
	_arrival_light.name = "intro-arrival-light"
	_arrival_light.position = Vector3(30.0, 2.3, -5.2)
	_arrival_light.light_color = Color(0.92, 0.77, 0.51)
	_arrival_light.light_energy = 1.8
	_arrival_light.omni_range = 12.0
	_arrival_light.shadow_enabled = false
	renderer.world_root.add_child(_arrival_light)
	c["audio"].sfx("car-start")
	var shots := [{
		"pos": Vector3(25.6, 1.6, -5.4), "look_at": Vector3(33.7, 0.85, -3.2),
		"look_at_to": CAR_AT + Vector3.UP * 0.8, "sec": 3.7,
	}, {
		"pos": Vector3(28.9, 1.6, -5.5), "look_at": Vector3(28.9, 1.45, -7.1),
		"sec": 1.8,
	}]
	var tick := func(t: float) -> void:
		if active and token == _attempt and _car != null:
			var q := clampf(t / 3.7, 0.0, 1.0)
			_car.position = Vector3(38.5, CAR_AT.y, CAR_AT.z).lerp(CAR_AT, 1.0 - pow(1.0 - q, 2.0))
	if not cut.play(renderer.world_root, controls.camera, shots, DRIVE_SECONDS, tick, ready):
		ready.call()


func check_door() -> void:
	var s: GameState = c["state"]
	if not _available(s) or s.has("intro-shop-checked"): return
	s.set_flag("intro-shop-checked")
	c["audio"].knock(2, 0.26)
	c["ui"].say(data["closed"], 4.5)
	c["chapters"].pushTask()


func talk() -> void:
	var s: GameState = c["state"]
	if not _available(s) or not s.has("intro-shop-checked") or s.has("intro-shop-talked") or _dialogue_pending:
		return
	_dialogue_pending = true
	var token := _attempt
	var finish := func() -> void:
		if not active or token != _attempt or s.chapter != "prologue": return
		_dialogue_pending = false
		s.set_flag("intro-shop-talked")
		c["chapters"].pushTask()
	var play: Variant = c.get("playDialogue")
	if play is Callable:
		play.call(data["dialogue"], finish)
	else:
		finish.call()


func leave() -> void:
	var s: GameState = c["state"]
	if not _available(s) or not s.has("intro-shop-talked"): return
	s.set_flag("intro-shop-done")
	var done := _done
	cancel()
	if done.is_valid(): done.call()


func cancel() -> void:
	_attempt += 1
	_dialogue_pending = false
	_done = Callable()
	if not active: return
	active = false
	_clear_arrival_light()
	if is_instance_valid(_car): _car.transform = _car_transform
	_car = null
	if not _car_collider.is_empty():
		_car_collider["cx"] = _car_collider_origin.x
		_car_collider["cy"] = _car_collider_origin.y
		_car_collider["cz"] = _car_collider_origin.z
		c["props"].rebuild_collision(c["col"])
		_car_collider = {}
	_set_car_blocker(false)
	var actors: Variant = c.get("actors")
	if actors != null: actors.show("arkady", false)
	if _light_snapshot != null:
		c["lights"].restore(_light_snapshot)


func _clear_arrival_light() -> void:
	if is_instance_valid(_arrival_light):
		_arrival_light.get_parent().remove_child(_arrival_light)
		_arrival_light.queue_free()
	_arrival_light = null


func _move_car_collider(props: Variant, offset: Vector3) -> void:
	# Props хранит формы отдельно от узлов. Переносим и форму, иначе у дома
	# остаётся невидимая машина, а в припаркованную у магазина можно войти.
	var col: Variant = c.get("col")
	var shapes: Variant = props.get("colliders")
	if col == null or not shapes is Array: return
	var matches: Array[Dictionary] = []
	for shape: Dictionary in shapes:
		var center := Vector3(shape["cx"], shape["cy"], shape["cz"])
		if Vector2(center.x, center.z).distance_to(Vector2(_car.position.x, _car.position.z)) < 0.15 \
				and is_equal_approx(float(shape["hx"]), 0.9) and is_equal_approx(float(shape["hz"]), 2.1):
			matches.append(shape)
	if matches.size() != 1: return
	_car_collider = matches[0]
	_car_collider_origin = Vector3(_car_collider["cx"], _car_collider["cy"], _car_collider["cz"])
	var at := _car_collider_origin + offset
	_car_collider["cx"] = at.x
	_car_collider["cy"] = at.y
	_car_collider["cz"] = at.z
	props.rebuild_collision(col)
	var physics: Variant = c.get("physics")
	if physics != null: physics.sync()


func _set_car_blocker(on: bool) -> void:
	var col: Variant = c.get("col")
	if col == null: return
	if on and not _blocker_added:
		col.add_box_d(CollisionWorld.SET_OVERLAY,
			CAR_AT.x - 2.15, CAR_AT.y, CAR_AT.z - 0.85,
			CAR_AT.x + 2.15, CAR_AT.y + 1.4, CAR_AT.z + 0.85, BLOCKER)
		_blocker_added = true
	col.set_blocker_active(BLOCKER, on)
	var physics: Variant = c.get("physics")
	if physics != null: physics.sync()

# Предметы в руках. Выбор существует только в runtime: GameState остаётся
# источником владения и сюжетной готовности, а формат снимка не меняется.
class_name HeldItems
extends Node

signal selection_changed(id: String, label: String)

const EMPTY := "empty"
const FLASHLIGHT := "flashlight"
const MODEL_POS := Vector3(0.19, -0.18, -0.43)
const MAX_ACTIVE_DRAWS := 12
const MAX_ACTIVE_TRIANGLES := 1000

const SLOT_ORDER: Array[String] = [
	EMPTY, FLASHLIGHT, "lantern", "bag", "firewood", "apple-basket", "poison",
	"sprayer", "canister", "leyka", "scythe", "tool-shovel", "distributor",
	"crowbar",
]

const LABELS := {
	EMPTY: "ПУСТЫЕ РУКИ",
	FLASHLIGHT: "ФОНАРИК",
	"lantern": "КЕРОСИНКА",
	"bag": "СУМКА С ПРОДУКТАМИ",
	"firewood": "ДРОВА",
	"apple-basket": "КОРЗИНА ЯБЛОК",
	"poison": "ЯД",
	"sprayer": "ОПРЫСКИВАТЕЛЬ",
	"canister": "КАНИСТРА",
	"leyka": "ЛЕЙКА",
	"scythe": "КОСА",
	"tool-shovel": "ЛОПАТА",
	"distributor": "РАСПРЕДЕЛИТЕЛЬ",
	"crowbar": "ЛОМ",
}

# Событие приходит после изменения флага. Модель можно кратко показать даже
# когда предмет этим же флагом уже выведен из доступных слотов.
const STORY_ITEMS := {
	"groceries": "bag",
	"banya-fired": "firewood",
	"apples-tossed": "apple-basket",
	"spray-mixed": "poison",
	"bugs-done": "sprayer",
	"tank-full": "canister",
	"water-done": "leyka",
	"seedlings-done": "leyka",
	"mow-done": "scythe",
	"grave-dug": "tool-shovel",
	"bed-dug": "tool-shovel",
	"distributor-in": "distributor",
	"well-freed": "crowbar",
}

var chain: RenderChain = null
var flashlight: Flashlight = null
var _models: Dictionary = {}
var _materials: Dictionary = {}
var _available: Array[String] = [EMPTY]
var _selected := EMPTY
var _known_available: Dictionary = {}
var _synced := false
var _state_ref: GameState = null
var _state_revision := -1
var _story_id := ""
var _story_timer := 0.0
var _action_timer := 0.0
var _sway := Vector2.ZERO
var _pulse := 0.0
var _psx: Shader = null
var _cinematic_hidden := false


func configure(render_chain: RenderChain, light: Flashlight) -> void:
	chain = render_chain
	flashlight = light
	_psx = load("res://shaders/psx.gdshader")
	if chain == null or chain.hand_root == null:
		push_error("HeldItems.configure: RenderChain ещё не собран")
		return
	_build_models()
	_register_input_actions()
	_refresh_visible()


func sync(state: GameState) -> void:
	if state == null:
		return
	if _synced and state == _state_ref and state.runtime_revision == _state_revision:
		return
	_state_ref = state
	_state_revision = state.runtime_revision
	var next := _available_for(state)
	var next_set: Dictionary = {}
	for id: String in next:
		next_set[id] = true

	if not _synced:
		_available = next
		_known_available = next_set
		_synced = true
		if not _available.has(_selected):
			_select(_fallback(), false)
		else:
			_refresh_visible()
		return

	var newest := ""
	for id: String in next:
		if id != EMPTY and not _known_available.has(id):
			newest = id
	_available = next
	_known_available = next_set
	if newest != "":
		_select(newest, true)
	elif not _available.has(_selected):
		_select(_fallback(), false)
	elif _selected != FLASHLIGHT and flashlight != null and flashlight.on:
		# restore() может вернуть включённый луч после отката состояния. Луч не
		# должен жить отдельно от выбранного фонаря.
		flashlight.on = false
		_refresh_visible()


func cycle(delta: int) -> void:
	if delta == 0 or _available.is_empty():
		return
	var at := _available.find(_selected)
	if at < 0:
		at = 0
	var step := 1 if delta > 0 else -1
	var next := posmod(at + step, _available.size())
	_select(_available[next], true)


func equip(id: String) -> bool:
	if not _available.has(id):
		return false
	_select(id, true)
	return true


func selected_id() -> String:
	return _selected


func selected_label() -> String:
	return String(LABELS.get(_selected, _selected.to_upper()))


## Temporarily hide every first-person prop without changing selection or
## inventory. Cutscenes must be able to restore the exact pre-scene state.
func set_cinematic_hidden(on: bool) -> void:
	_cinematic_hidden = on
	_refresh_visible()


func update(dt: float, player: Variant) -> void:
	if _story_timer > 0.0:
		_story_timer = maxf(0.0, _story_timer - dt)
		_action_timer = maxf(0.0, _action_timer - dt)
		if _story_timer <= 0.0:
			_story_id = ""
			_refresh_visible()
	_pulse = maxf(0.0, _pulse - dt)

	var active := _active_id()
	if active == EMPTY or active == FLASHLIGHT or not _models.has(active):
		return
	var root: Node3D = _models[active]
	if player == null:
		root.position = MODEL_POS
		root.rotation = Vector3.ZERO
		return

	var yaw := float(player.get("yaw"))
	var yaw_target := float(player.get("yaw_target"))
	var pitch := float(player.get("pitch"))
	var pitch_target := float(player.get("pitch_target"))
	var target := Vector2(
		clampf((yaw_target - yaw) * 2.2, -0.07, 0.07),
		clampf((pitch_target - pitch) * 2.2, -0.07, 0.07))
	var k := 1.0 - exp(-dt * 8.0)
	_sway += (target - _sway) * k
	var bob := float(player.get("bob_amount"))
	var phase := float(player.get("bob_phase"))
	var raise := sin(clampf(_pulse / 0.28, 0.0, 1.0) * PI) * 0.025
	root.position = MODEL_POS + Vector3(
		-_sway.x + sin(phase) * 0.011 * bob,
		-_sway.y + absf(sin(phase)) * 0.013 * bob - raise,
		0.0)
	root.rotation = Vector3(_sway.y, 0.08, -_sway.x * 1.5 + sin(phase) * 0.025 * bob)

	if _action_timer > 0.0:
		var t := 1.0 - _action_timer / 0.72
		var hit := sin(clampf(t, 0.0, 1.0) * PI)
		if active == "leyka" or active == "canister":
			root.rotation.x -= hit * 0.72
		elif active == "sprayer":
			root.position.y += sin(t * TAU * 3.0) * 0.018
		elif active in ["scythe", "tool-shovel", "crowbar"]:
			root.rotation.z += hit * 0.82


func clear_runtime() -> void:
	_cinematic_hidden = false
	_selected = EMPTY
	_available = [EMPTY]
	_known_available = {}
	_synced = false
	_state_ref = null
	_state_revision = -1
	_story_id = ""
	_story_timer = 0.0
	_action_timer = 0.0
	_sway = Vector2.ZERO
	_pulse = 0.0
	_refresh_visible()
	selection_changed.emit(_selected, selected_label())


func show_story_event(event: String) -> void:
	var id := String(STORY_ITEMS.get(event, ""))
	if id == "":
		if event.begins_with("watered-"):
			id = "leyka"
		elif event.begins_with("sprayed-"):
			id = "sprayer"
	if id == "" or not _models.has(id):
		return
	_story_id = id
	_story_timer = 0.78
	_action_timer = 0.72
	_refresh_visible()


func active_budget() -> Dictionary:
	var active := _active_id()
	var root: Node = null
	if active == FLASHLIGHT and flashlight != null:
		root = flashlight.model
	elif _models.has(active):
		root = _models[active]
	var draws := 0
	var triangles := 0
	if root != null:
		var pending: Array[Node] = [root]
		while not pending.is_empty():
			var n: Node = pending.pop_back()
			if n is MeshInstance3D:
				var mesh := (n as MeshInstance3D).mesh
				if mesh != null:
					draws += mesh.get_surface_count()
					triangles += mesh.get_faces().size() / 3
			elif n is MultiMeshInstance3D:
				var mm := (n as MultiMeshInstance3D).multimesh
				if mm != null and mm.mesh != null:
					draws += mm.mesh.get_surface_count()
					triangles += mm.mesh.get_faces().size() / 3 * mm.instance_count
			for child: Node in n.get_children():
				pending.append(child)
	return {"draw_calls": draws, "triangles": triangles,
		"within_budget": draws <= MAX_ACTIVE_DRAWS and triangles <= MAX_ACTIVE_TRIANGLES}


func _available_for(state: GameState) -> Array[String]:
	var out: Array[String] = [EMPTY]
	if state.hasItem("flashlight"):
		out.append(FLASHLIGHT)
	if state.hasItem("lantern"):
		out.append("lantern")
	if state.hasItem("bag") and not state.has("groceries"):
		out.append("bag")
	if state.hasItem("firewood") and not state.has("banya-fired"):
		out.append("firewood")
	if state.hasItem("apple-basket") and not state.has("apples-tossed"):
		out.append("apple-basket")
	if state.hasItem("poison") and not state.has("spray-mixed"):
		out.append("poison")
	if state.hasItem("sprayer") and not state.has("bugs-done"):
		out.append("sprayer")
	if state.hasItem("canister") and not state.has("tank-full"):
		out.append("canister")
	if state.hasItem("leyka") and not (state.has("water-done") and state.has("seedlings-done")):
		out.append("leyka")
	if state.hasItem("scythe") and not state.has("mow-done"):
		out.append("scythe")
	if state.hasItem("tool-shovel") and not (state.has("grave-dug") and state.has("bed-dug")):
		out.append("tool-shovel")
	if state.hasItem("distributor") and not state.has("distributor-in"):
		out.append("distributor")
	if state.hasItem("crowbar") and not state.has("well-freed"):
		out.append("crowbar")
	return out


func _fallback() -> String:
	if _available.has(FLASHLIGHT):
		return FLASHLIGHT
	for id: String in _available:
		if id != EMPTY:
			return id
	return EMPTY


func _select(id: String, animate: bool) -> void:
	if id == _selected:
		_story_id = ""
		_story_timer = 0.0
		_action_timer = 0.0
		_refresh_visible()
		return
	if _selected == FLASHLIGHT and id != FLASHLIGHT and flashlight != null:
		flashlight.on = false
	_selected = id
	_story_id = ""
	_story_timer = 0.0
	_action_timer = 0.0
	if animate:
		_pulse = 0.28
	_refresh_visible()
	selection_changed.emit(_selected, selected_label())


func _active_id() -> String:
	return _story_id if _story_timer > 0.0 else _selected


func _refresh_visible() -> void:
	var active := _active_id()
	for id: String in _models:
		(_models[id] as Node3D).visible = not _cinematic_hidden and id == active
	if flashlight != null:
		flashlight.set_viewmodel_selected(not _cinematic_hidden and active == FLASHLIGHT)
	if chain != null:
		chain.set_hands_visible(not _cinematic_hidden and active != EMPTY)


func _register_input_actions() -> void:
	_register_wheel_action("equip_prev", MOUSE_BUTTON_WHEEL_UP)
	_register_wheel_action("equip_next", MOUSE_BUTTON_WHEEL_DOWN)


func _register_wheel_action(action: StringName, button: MouseButton) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	for event: InputEvent in InputMap.action_get_events(action):
		if event is InputEventMouseButton and (event as InputEventMouseButton).button_index == button:
			return
	var wheel := InputEventMouseButton.new()
	wheel.button_index = button
	InputMap.action_add_event(action, wheel)


# ------------------------------------------------------------ геометрия ---

func _build_models() -> void:
	_models["lantern"] = _lantern()
	_models["bag"] = _bag()
	_models["firewood"] = _firewood()
	_models["apple-basket"] = _apple_basket()
	_models["poison"] = _poison()
	_models["sprayer"] = _sprayer()
	_models["canister"] = _canister()
	_models["leyka"] = _watering_can()
	_models["scythe"] = _scythe()
	_models["tool-shovel"] = _shovel()
	_models["distributor"] = _distributor()
	_models["crowbar"] = _crowbar()
	for id: String in _models:
		var model: Node3D = _models[id]
		_merge_static_parts(model)
		model.name = "Held-" + id
		model.position = MODEL_POS
		model.visible = false
		chain.hand_root.add_child(model)


func _root_with_hand() -> Node3D:
	var root := Node3D.new()
	_part(root, ObjectGeometry.shared("object/hand"), 0x8d6a55,
		Vector3(0.035, -0.050, 0.075), Vector3(PI / 2.0 + 0.12, 0.0, -0.16), "кисть")
	_part(root, _box(Vector3(0.076, 0.060, 0.050)), 0x39434b,
		Vector3(0.040, -0.060, 0.125), Vector3.ZERO, "манжета")
	return root


func _lantern() -> Node3D:
	var n := _root_with_hand()
	_part(n, _cylinder(0.055, 0.050, 0.115), 0x6e5b35, Vector3(0, 0.015, 0), Vector3.ZERO, "бак")
	_part(n, _cylinder(0.042, 0.050, 0.080), 0xd4b866, Vector3(0, 0.110, 0), Vector3.ZERO, "стекло")
	_part(n, _cylinder(0.026, 0.040, 0.035), 0x343638, Vector3(0, 0.168, 0), Vector3.ZERO, "крышка")
	_part(n, _box(Vector3(0.012, 0.150, 0.012)), 0x343638, Vector3(-0.070, 0.135, 0), Vector3(0, 0, -0.20), "дужка-л")
	_part(n, _box(Vector3(0.012, 0.150, 0.012)), 0x343638, Vector3(0.070, 0.135, 0), Vector3(0, 0, 0.20), "дужка-п")
	_part(n, _box(Vector3(0.120, 0.012, 0.012)), 0x343638, Vector3(0, 0.210, 0), Vector3.ZERO, "ручка")
	return n


func _bag() -> Node3D:
	var n := _root_with_hand()
	_part(n, _box(Vector3(0.230, 0.190, 0.115)), 0x6f6048, Vector3(-0.035, 0.035, 0), Vector3(0, 0.06, 0.03), "сумка")
	_part(n, _box(Vector3(0.220, 0.030, 0.105)), 0x8b795a, Vector3(-0.035, 0.135, 0), Vector3(0, 0.06, 0.03), "клапан")
	_part(n, _box(Vector3(0.018, 0.130, 0.018)), 0x4a3f31, Vector3(-0.110, 0.205, 0), Vector3(0, 0, -0.18), "ручка-л")
	_part(n, _box(Vector3(0.018, 0.130, 0.018)), 0x4a3f31, Vector3(0.040, 0.205, 0), Vector3(0, 0, 0.18), "ручка-п")
	_part(n, _box(Vector3(0.145, 0.018, 0.018)), 0x4a3f31, Vector3(-0.035, 0.265, 0), Vector3.ZERO, "ручка")
	return n


func _firewood() -> Node3D:
	var n := _root_with_hand()
	for i in 3:
		_part(n, _cylinder(0.035, 0.040, 0.34), 0x58412b,
			Vector3(-0.070 + i * 0.070, 0.065 + absf(i - 1) * 0.025, 0),
			Vector3(0, 0, PI / 2.0 + (i - 1) * 0.05), "полено-%d" % i)
	_part(n, _box(Vector3(0.055, 0.230, 0.018)), 0x33281e, Vector3(0, 0.065, 0), Vector3(0, 0, PI / 2.0), "перевязь")
	return n


func _apple_basket() -> Node3D:
	var n := _root_with_hand()
	_part(n, _cylinder(0.105, 0.085, 0.115), 0x8b6538, Vector3(-0.020, 0.030, 0), Vector3.ZERO, "корзина")
	_part(n, _box(Vector3(0.014, 0.160, 0.014)), 0x5d4127, Vector3(-0.115, 0.135, 0), Vector3(0, 0, -0.28), "дужка-л")
	_part(n, _box(Vector3(0.014, 0.160, 0.014)), 0x5d4127, Vector3(0.075, 0.135, 0), Vector3(0, 0, 0.28), "дужка-п")
	_part(n, _box(Vector3(0.165, 0.014, 0.014)), 0x5d4127, Vector3(-0.020, 0.200, 0), Vector3.ZERO, "ручка")
	var apples := MultiMeshInstance3D.new()
	apples.name = "яблоки"
	apples.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.instance_count = 5
	mm.mesh = _sphere(0.042)
	for i in 5:
		var x := -0.075 + float(i % 3) * 0.070
		var z := -0.025 + float(i / 3) * 0.055
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, Vector3(x, 0.105, z)))
	apples.multimesh = mm
	apples.material_override = _material(0x922f24)
	n.add_child(apples)
	return n


func _poison() -> Node3D:
	var n := _root_with_hand()
	_part(n, _cylinder(0.055, 0.060, 0.170), 0x5a6841, Vector3(0, 0.045, 0), Vector3.ZERO, "бутыль")
	_part(n, _cylinder(0.024, 0.036, 0.050), 0x4a5737, Vector3(0, 0.155, 0), Vector3.ZERO, "горло")
	_part(n, _cylinder(0.029, 0.029, 0.026), 0x252a22, Vector3(0, 0.193, 0), Vector3.ZERO, "пробка")
	_part(n, _box(Vector3(0.088, 0.060, 0.006)), 0xd2c8a2, Vector3(0, 0.055, -0.059), Vector3.ZERO, "этикетка")
	return n


func _sprayer() -> Node3D:
	var n := _root_with_hand()
	_part(n, _cylinder(0.085, 0.080, 0.210), 0x70805b, Vector3(-0.020, 0.045, 0), Vector3.ZERO, "бак")
	_part(n, _cylinder(0.030, 0.045, 0.050), 0x3c4434, Vector3(-0.020, 0.178, 0), Vector3.ZERO, "крышка")
	_part(n, _cylinder(0.012, 0.012, 0.180), 0x343638, Vector3(0.080, 0.135, 0), Vector3(0, 0, -0.12), "насос")
	_part(n, _box(Vector3(0.090, 0.018, 0.018)), 0x343638, Vector3(0.075, 0.235, 0), Vector3.ZERO, "рукоять")
	_part(n, _cylinder(0.010, 0.010, 0.260), 0x343638, Vector3(-0.130, 0.050, -0.015), Vector3(0, 0, PI / 2.0), "штанга")
	_part(n, _cylinder(0.018, 0.008, 0.055), 0x625d4d, Vector3(-0.285, 0.050, -0.015), Vector3(0, 0, PI / 2.0), "форсунка")
	return n


func _canister() -> Node3D:
	var n := _root_with_hand()
	_part(n, _box(Vector3(0.210, 0.260, 0.095)), 0x59644f, Vector3(-0.035, 0.065, 0), Vector3(0, 0.05, 0.02), "канистра")
	_part(n, _box(Vector3(0.095, 0.045, 0.055)), 0x2f382e, Vector3(-0.035, 0.215, 0), Vector3(0, 0.05, 0), "ручка")
	_part(n, _box(Vector3(0.055, 0.070, 0.035)), 0x171b18, Vector3(-0.035, 0.215, -0.012), Vector3(0, 0.05, 0), "проём")
	_part(n, _cylinder(0.030, 0.030, 0.036), 0x30362f, Vector3(0.070, 0.215, 0), Vector3(0, 0, -0.25), "крышка")
	_part(n, _box(Vector3(0.160, 0.020, 0.010)), 0x77826a, Vector3(-0.035, 0.065, -0.052), Vector3(0, 0, 0.55), "штамп")
	_part(n, _box(Vector3(0.160, 0.012, 0.010)), 0x77826a, Vector3(-0.035, 0.065, -0.052), Vector3(0, 0, -0.55), "штамп-п")
	return n


func _watering_can() -> Node3D:
	var n := _root_with_hand()
	_part(n, _cylinder(0.090, 0.095, 0.170), 0x6f817c, Vector3(-0.020, 0.045, 0), Vector3.ZERO, "лейка")
	_part(n, _cylinder(0.026, 0.055, 0.210), 0x657872, Vector3(-0.155, 0.105, 0), Vector3(0, 0, -PI / 3.0), "носик")
	_part(n, _cylinder(0.055, 0.028, 0.045), 0x778984, Vector3(-0.250, 0.160, 0), Vector3(0, 0, -PI / 3.0), "рассекатель")
	_part(n, _box(Vector3(0.014, 0.165, 0.014)), 0x465651, Vector3(0.085, 0.145, 0), Vector3(0, 0, 0.28), "дужка-п")
	_part(n, _box(Vector3(0.014, 0.165, 0.014)), 0x465651, Vector3(-0.020, 0.215, 0), Vector3(0, 0, -0.70), "дужка-л")
	return n


func _scythe() -> Node3D:
	var n := _root_with_hand()
	_part(n, _cylinder(0.014, 0.018, 0.58), 0x69513a, Vector3(-0.045, 0.080, 0), Vector3(0, 0, -0.34), "косовище")
	_part(n, _cylinder(0.012, 0.014, 0.140), 0x69513a, Vector3(0.015, 0.130, -0.010), Vector3(0, 0, PI / 2.0), "рукоять")
	_part(n, _box(Vector3(0.330, 0.025, 0.012)), 0x8a8f89, Vector3(-0.155, -0.190, 0), Vector3(0, 0, -0.18), "лезвие")
	return n


func _shovel() -> Node3D:
	var n := _root_with_hand()
	_part(n, _cylinder(0.015, 0.020, 0.55), 0x70563b, Vector3(-0.010, 0.060, 0), Vector3(0, 0, -0.18), "черенок")
	_part(n, _box(Vector3(0.145, 0.190, 0.018)), 0x747b78, Vector3(-0.075, -0.245, 0), Vector3(0, 0, -0.18), "штыковая-часть")
	_part(n, _box(Vector3(0.100, 0.018, 0.018)), 0x70563b, Vector3(0.040, 0.340, 0), Vector3(0, 0, -0.18), "ручка")
	_part(n, _box(Vector3(0.018, 0.090, 0.018)), 0x70563b, Vector3(-0.005, 0.300, 0), Vector3(0, 0, -0.18), "стойка")
	return n


func _distributor() -> Node3D:
	var n := _root_with_hand()
	_part(n, _cylinder(0.070, 0.065, 0.105), 0x363a38, Vector3(-0.010, 0.055, 0), Vector3.ZERO, "корпус")
	_part(n, _cylinder(0.078, 0.078, 0.045), 0x6f412e, Vector3(-0.010, 0.130, 0), Vector3.ZERO, "крышка")
	_part(n, _cylinder(0.018, 0.018, 0.150), 0x777b74, Vector3(-0.010, -0.070, 0), Vector3.ZERO, "вал")
	for i in 4:
		var a := TAU * float(i) / 4.0
		_part(n, _cylinder(0.010, 0.012, 0.070), 0x242625,
			Vector3(-0.010 + cos(a) * 0.055, 0.185, sin(a) * 0.055),
			Vector3(0.18 * sin(a), 0, -0.18 * cos(a)), "контакт-%d" % i)
	return n


func _crowbar() -> Node3D:
	var n := _root_with_hand()
	_part(n, _cylinder(0.014, 0.017, 0.58), 0x6c3b32, Vector3(-0.020, 0.040, 0), Vector3(0, 0, -0.30), "лом")
	_part(n, _cylinder(0.014, 0.014, 0.135), 0x6c3b32, Vector3(-0.115, -0.220, 0), Vector3(0, 0, PI / 2.0 - 0.30), "крюк")
	_part(n, _box(Vector3(0.095, 0.028, 0.018)), 0x81483c, Vector3(0.080, 0.315, 0), Vector3(0, 0, -0.30), "лапа")
	return n


func _part(parent: Node3D, mesh: Mesh, color: int, pos: Vector3,
		rot: Vector3, title: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = title
	mi.mesh = mesh
	mi.material_override = _material(color)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.position = pos
	mi.rotation_order = EULER_ORDER_XYZ
	mi.rotation = rot
	parent.add_child(mi)
	return mi


func _material(hex: int) -> ShaderMaterial:
	if _materials.has(hex):
		return _materials[hex]
	var m := ShaderMaterial.new()
	m.shader = _psx
	m.set_shader_parameter("albedo", GameData.color(hex))
	m.set_shader_parameter("psx_cookie", 0.0)
	_materials[hex] = m
	return m


func _box(size: Vector3) -> ArrayMesh:
	return ObjectGeometry.bevel_box(size, minf(size.x, size.z) * 0.10)


func _merge_static_parts(model: Node3D) -> void:
	# Все детали движутся вместе с прежним Held-root. Склейка не затрагивает
	# MultiMesh яблок и отдельную HandView/сюжетную видимость.
	var groups: Dictionary = {}
	for child: Node in model.get_children():
		if not child is MeshInstance3D:
			continue
		var mi := child as MeshInstance3D
		var mat := mi.material_override
		var key := mat.get_instance_id()
		if not groups.has(key):
			var st := SurfaceTool.new()
			st.begin(Mesh.PRIMITIVE_TRIANGLES)
			groups[key] = {"st": st, "mat": mat, "parts": []}
		var entry: Dictionary = groups[key]
		(entry["st"] as SurfaceTool).append_from(mi.mesh, 0, mi.transform)
		(entry["parts"] as Array).append(String(mi.name))
		model.remove_child(mi)
		mi.free()
	for key: int in groups:
		var entry: Dictionary = groups[key]
		var mi := MeshInstance3D.new()
		mi.name = "assembled-%d" % model.get_child_count()
		mi.mesh = (entry["st"] as SurfaceTool).commit()
		mi.material_override = entry["mat"]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		mi.set_meta("parts", entry["parts"])
		model.add_child(mi)


func _cylinder(top: float, bottom: float, height: float) -> CylinderMesh:
	var mesh := CylinderMesh.new()
	mesh.top_radius = top
	mesh.bottom_radius = bottom
	mesh.height = height
	mesh.radial_segments = 8
	mesh.rings = 1
	return mesh


func _sphere(radius: float) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 8
	mesh.rings = 4
	return mesh

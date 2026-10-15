## Нативные модели эпизода. Ноль внешних ассетов, коллизий и новых материалов мира.
## Origin: стопы; window_face — центр лица. Все фигуры смотрят вдоль -Z.
class_name SntEpisodeActors
extends RefCounted

const KEYS := ["nina", "semyon", "walker", "window_face"]
var root: Node3D
var mats: Materials
var figures: Dictionary = {}
var rigs: Dictionary = {}
var actions: Dictionary = {}
var clock := 0.0

func _init(parent: Node3D, materials: Materials = null) -> void:
	root = parent
	mats = materials

func build() -> SntEpisodeActors:
	for who: String in KEYS:
		var node := Node3D.new()
		node.name = "episode-" + who
		root.add_child(node)
		figures[who] = node
		if who == "window_face":
			var head := _head(node, Vector3.ZERO, true, false)
			var hand := _joint(node, "peeking-hand", Vector3(0.20, -0.04, -0.03))
			var skin := _material(Color("8f8b76"))
			_oval(hand, Vector3.ZERO, Vector3(0.08, 0.11, 0.055), skin)
			for finger in 4:
				_oval(hand, Vector3(-0.032 + finger * 0.021, 0.068, -0.015), Vector3(0.016, 0.072, 0.019), skin)
			_oval(hand, Vector3(-0.053, 0.015, -0.012), Vector3(0.023, 0.058, 0.025), skin)
			hand.visible = false
			rigs[who] = {"head": head, "hand": hand}
		else:
			_person(who, node)
		_merge_joints(node)
		node.visible = false
	place("nina", 27.5, 0.20, -42.4, PI)
	place("semyon", -28.5, 0.0, -49.25, 0.0)
	return self

func _merge_joints(node: Node3D) -> void:
	for child: Node in node.get_children():
		if child is Node3D and not child is MeshInstance3D:
			_merge_joints(child)
	StaticVisualBatch.merge_owner(node)

func _material(color: Color) -> StandardMaterial3D:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	return mat

func _piece(parent: Node3D, mesh: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var node := MeshInstance3D.new()
	node.mesh = mesh
	node.material_override = material
	node.position = at
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end = 42.0
	parent.add_child(node)
	return node

func _box(parent: Node3D, at: Vector3, size: Vector3, material: Material) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	_piece(parent, mesh, at, material)

func _oval(parent: Node3D, at: Vector3, size: Vector3, material: Material) -> void:
	var mesh := SphereMesh.new()
	mesh.radius = 0.5
	mesh.height = 1.0
	mesh.radial_segments = 10
	mesh.rings = 5
	_piece(parent, mesh, at, material).scale = size

func _joint(parent: Node3D, name_: String, at: Vector3) -> Node3D:
	var node := Node3D.new()
	node.name = name_
	node.position = at
	parent.add_child(node)
	return node

func _head(parent: Node3D, at: Vector3, strange: bool, scarf: bool) -> Node3D:
	var head := _joint(parent, "head", at)
	var skin := _material(Color("8f8b76") if strange else Color("a08a73"))
	var dark := _material(Color("252927"))
	_oval(head, Vector3.ZERO, Vector3(0.20, 0.265, 0.225), skin)
	_oval(head, Vector3(0.0, 0.070, 0.025), Vector3(0.215, 0.18, 0.22), _material(Color("494b45")))
	for side: float in [-1.0, 1.0]:
		_oval(head, Vector3(side * 0.045, 0.018, -0.099), Vector3(0.047, 0.030 if strange else 0.020, 0.022), dark)
		_box(head, Vector3(side * 0.047, 0.044, -0.097), Vector3(0.062, 0.010, 0.021), dark)
		_oval(head, Vector3(side * 0.100, -0.005, 0.0), Vector3(0.035, 0.065, 0.044), skin)
	_oval(head, Vector3(0.0, -0.012, -0.119), Vector3(0.040, 0.063, 0.049), skin)
	_box(head, Vector3(0.0, -0.070, -0.101), Vector3(0.064, 0.008, 0.016), dark)
	if scarf:
		var cloth := _material(Color("726c83"))
		_oval(head, Vector3(0.0, 0.078, 0.038), Vector3(0.238, 0.193, 0.255), cloth)
		_oval(head, Vector3(0.0, -0.120, 0.055), Vector3(0.245, 0.105, 0.160), cloth)
	return head

func _person(who: String, node: Node3D) -> void:
	var walker := who == "walker"
	var nina := who == "nina"
	var cloth := _material(Color("36443d") if walker else (Color("766c67") if nina else Color("526168")))
	var trousers := _material(Color("343839"))
	var skin := _material(Color("8f8b76") if walker else Color("a08a73"))
	var boots := _material(Color("222722"))
	var body := _joint(node, "body", Vector3(0, 0.88, 0))
	var torso := _joint(body, "torso", Vector3.ZERO)
	_oval(torso, Vector3(0, 0.24, 0), Vector3(0.43, 0.58, 0.25), cloth)
	if walker:
		_oval(torso, Vector3(0, -0.12, 0.02), Vector3(0.45, 0.44, 0.27), cloth)
		_box(torso, Vector3(0.08, 0.28, -0.13), Vector3(0.09, 0.035, 0.012), _material(Color("8d9079")))
	elif nina:
		_oval(torso, Vector3(0, -0.13, 0), Vector3(0.45, 0.50, 0.28), cloth)
		_box(torso, Vector3(0, 0.10, -0.133), Vector3(0.25, 0.48, 0.018), _material(Color("a6a18a")))
	else:
		_box(torso, Vector3(0, 0.19, -0.136), Vector3(0.28, 0.48, 0.020), _material(Color("716a53")))
	var head := _head(torso, Vector3(0, 0.68, -0.012), walker, nina)
	var arms: Array[Node3D] = []
	var legs: Array[Node3D] = []
	for side: float in [-1.0, 1.0]:
		var arm := _joint(torso, "arm", Vector3(side * 0.244, 0.44, 0))
		_oval(arm, Vector3(0, -0.22, 0), Vector3(0.108, 0.48, 0.13), cloth)
		_oval(arm, Vector3(0, -0.49, -0.012), Vector3(0.085, 0.16, 0.09), skin)
		arms.append(arm)
		var leg := _joint(body, "leg", Vector3(side * 0.095, 0, 0))
		_oval(leg, Vector3(0, -0.39, 0), Vector3(0.145, 0.80, 0.16), trousers)
		_box(leg, Vector3(0, -0.82, -0.044), Vector3(0.154, 0.12, 0.26), boots)
		legs.append(leg)
	if walker:
		torso.rotation.x = -0.14
		head.rotation.z = 0.11
	if nina: node.scale.y = 0.95
	rigs[who] = {"body": body, "torso": torso, "head": head, "arms": arms, "legs": legs}

func figure(who: String) -> Node3D:
	return figures.get(who)

func place(who: String, x: float, y: float, z: float, yaw := 0.0) -> void:
	var node := figure(who)
	if node == null: return
	node.position = Vector3(x, y, z)
	node.rotation.y = yaw

func face(who: String, x: float, z: float) -> void:
	var node := figure(who)
	if node != null: node.rotation.y = atan2(x - node.position.x, z - node.position.z) + PI

func show(who: String, visible: bool) -> void:
	var node := figure(who)
	if node != null: node.visible = visible

func begin_action(who: String, action: String) -> bool:
	if not figures.has(who): return false
	actions[who] = action
	return sample_action(who, action, 0.0)

func sample_action(who: String, action: String, t: float) -> bool:
	if not rigs.has(who): return false
	var r: Dictionary = rigs[who]
	if who == "window_face":
		(r["hand"] as Node3D).visible = action.contains("peek")
		(r["head"] as Node3D).rotation.z = sin(t * 2.0) * 0.05 if action.contains("peek") else 0.0
		return true
	var torso: Node3D = r["torso"]
	var head: Node3D = r["head"]
	var arms: Array = r["arms"]
	var legs: Array = r["legs"]
	var moving := action.contains("run") or action.contains("chase") or action == "walk"
	var pulse := sin(t * 12.0) if moving else 0.0
	for i in 2:
		var side := -1.0 if i == 0 else 1.0
		(legs[i] as Node3D).rotation.x = pulse * side * 0.50
		(arms[i] as Node3D).rotation = Vector3(-pulse * side * 0.50, 0, side * 0.035)
	torso.rotation.x = -0.20 if moving else (-0.14 if who == "walker" else 0.0)
	head.rotation = Vector3(0.08 if moving else 0.0, 0.0, 0.11 if who == "walker" else 0.0)
	if action.contains("capture") or action.contains("grab"):
		for arm: Node3D in arms: arm.rotation.x = lerpf(0.2, 1.45, clampf(t, 0, 1))
	elif action.contains("peek") or action.contains("window"):
		torso.rotation.z = 0.17
		head.rotation.z = -0.14
	elif action == "talk":
		(arms[0] as Node3D).rotation.x = 0.26 + sin(t * 1.7) * 0.06
		head.rotation.x = sin(t * 1.8) * 0.035
	return true

func end_action(who: String) -> void:
	actions.erase(who)
	if who == "window_face":
		(rigs[who]["head"] as Node3D).rotation = Vector3.ZERO
		(rigs[who]["hand"] as Node3D).visible = false
	if rigs.has(who) and who != "window_face":
		(rigs[who]["torso"] as Node3D).rotation = Vector3.ZERO
		sample_action(who, "idle", 0.0)

func sync_story(s: GameState) -> void:
	var available := s.chapter in ["street", "dark", "village"]
	show("nina", available)
	show("semyon", available)
	if s.has("snt-nina-met"):
		place("nina", 30.3, 0.0, -46.8, PI)
	else:
		place("nina", 27.5, 0.20, -42.4, PI)

func update(dt: float) -> void:
	clock += maxf(dt, 0.0)
	for who: String in ["nina", "semyon"]:
		if not figure(who).visible: continue
		if not actions.has(who): sample_action(who, "talk", clock)

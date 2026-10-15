extends SceneTree

const RANGES := preload("res://src/environment_detail_ranges.gd")
const INTERIORS := preload("res://src/environment_interiors.gd")
var errors: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var room: Dictionary
	for candidate: Dictionary in INTERIORS._rooms():
		if candidate["id"] == "kitchen": room = candidate
	var box: Array = room["box"]
	var position := Vector3((box[0]+box[1])*.5,float(room["floor"])+.4,(box[2]+box[3])*.5)
	var indoor := _holder(world,"indoor",position)
	var outdoor := _holder(world,"outdoor",Vector3(63,.4,31))
	var dynamic := _holder(world,"dynamic",position)
	var generated_dynamic := _holder(world,"generated-dynamic",position)
	var anonymous := _holder(world,"anonymous-static-cabinet",position)
	var animated := _holder(world,"anonymous-animation",position)
	animated.add_child(AnimationPlayer.new())
	var independent := _holder(world,"anonymous-independent",position)
	independent.get_child(0).set_meta("independent_visual",true)
	var skinned := _holder(world,"anonymous-skinned",position)
	skinned.get_child(0).skin = Skin.new()
	var home := _holder(world,"home-kitchen-bowl",position)
	var door := _holder(world,"managed-door",position)
	var props := Props.new(Materials.new())
	props.root = Node3D.new()
	world.add_child(props.root)
	for holder: Node3D in [indoor,outdoor,dynamic,generated_dynamic,anonymous,animated,independent,skinned]:
		holder.reparent(props.root)
	props.by_id = {"fixture-indoor":indoor,"fixture-outdoor":outdoor}
	var dynamic_id := String(GameData.props()["DYNAMIC_PROPS"][0]["id"])
	props.by_id[dynamic_id] = dynamic
	props.by_id["omen-jar-shelf"] = generated_dynamic
	props.dynamic_pool["omen-jar-shelf"] = generated_dynamic
	var built := {"home":{"nodes":{"kitchen-bowl":home,"frontdoor":door}}}
	var original_mesh: Mesh = indoor.get_child(0).mesh
	var original_faces := original_mesh.get_faces()
	var original_pose := indoor.transform
	var report := RANGES.apply(world,built,props)
	_check(indoor.get_child(0).visibility_range_end == 18.0,"static room furniture not limited")
	_check(home.get_child(0).visibility_range_end == 18.0,"approved home detail not limited")
	_check(outdoor.get_child(0).visibility_range_end == 48.0,"outdoor prop range changed")
	_check(dynamic.get_child(0).visibility_range_end == 48.0,"dynamic prop range changed")
	_check(generated_dynamic.get_child(0).visibility_range_end == 48.0,"generated dynamic prop range changed")
	_check(anonymous.get_child(0).visibility_range_end == 18.0,"anonymous room furniture not limited")
	_check(animated.get_child(0).visibility_range_end == 48.0,"animated anonymous range changed")
	_check(independent.get_child(0).visibility_range_end == 48.0,"independent anonymous range changed")
	_check(skinned.get_child(0).visibility_range_end == 48.0,"skinned anonymous range changed")
	_check(door.get_child(0).visibility_range_end == 48.0,"managed door range changed")
	_check(indoor.get_child(0).mesh == original_mesh and original_mesh.get_faces() == original_faces,"mesh changed")
	_check(indoor.transform == original_pose and indoor.visible,"pose or visibility changed")
	_check(report["physics_mutations"] == 0 and report["material_mutations"] == 0,"unexpected mutations")
	_check(RANGES.apply(world,built,props) == report,"application not idempotent")
	world.free()
	for error: String in errors: printerr("test_environment_detail_ranges: "+error)
	print("test_environment_detail_ranges: ","PASS" if errors.is_empty() else "FAIL")
	quit(0 if errors.is_empty() else 1)

func _holder(world: Node3D, name: String, position: Vector3) -> Node3D:
	var holder := Node3D.new()
	holder.name = name
	holder.position = position
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = Vector3(.1,.1,.1)
	instance.mesh = mesh
	instance.visibility_range_end = 48.0
	holder.add_child(instance)
	world.add_child(holder)
	return holder

func _check(condition: bool, message: String) -> void:
	if not condition: errors.append(message)

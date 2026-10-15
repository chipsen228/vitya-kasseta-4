extends SceneTree

const INVENTORY := preload("res://src/environment_inventory.gd")
var failures: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	var empty := _multimesh(world,"empty",0)
	var limited := _multimesh(world,"limited",3)
	limited.multimesh.visible_instance_count = 2
	var derived := _multimesh(world,"derived",2)
	derived.multimesh.custom_aabb = AABB()
	derived.position = Vector3(5,1,-5)
	var disabled := _multimesh(world,"disabled",2)
	disabled.multimesh.visible_instance_count = 0
	var masked := _multimesh(world,"masked",4)
	masked.layers = 0
	var shadow := _multimesh(world,"shadow",1)
	shadow.set_meta("static_shadow_proxy",true)
	var report := INVENTORY.capture(world)
	_check(int(report["count"]) == 2,"empty, disabled, masked and shadow nodes must be absent")
	_check(int(report["excluded_empty_multimeshes"]) == 2,"empty exclusion count differs")
	for row: Dictionary in report["objects"]:
		_check(int(row["instances"]) == 2,"live visible instance limit differs")
		if row["node"] == str(derived.get_path()):
			if DisplayServer.get_name() == "headless":
				_check(not bool(row["bounds_available"]),"dummy renderer readback was presented as verified bounds")
			else:
				_check(GameData.vec3(row["bounds"]["min"]).is_equal_approx(Vector3(4.5,.5,-5.5)),"derived world minimum differs")
				_check(GameData.vec3(row["bounds"]["size"]).is_equal_approx(Vector3(2,1,1)),"derived transform union differs")
		else:
			_check(bool(row["bounds_available"]) and GameData.vec3(row["bounds"]["size"]).length_squared() > 0,"explicit resource bounds absent")
	_check(empty.multimesh.instance_count == 0 and limited.multimesh.instance_count == 3,"inventory mutated resources")
	_check(disabled.multimesh.visible_instance_count == 0 and masked.layers == 0,"inventory mutated visibility")
	world.free()
	for failure: String in failures: printerr("test_environment_inventory: ",failure)
	print("test_environment_inventory: ","PASS" if failures.is_empty() else "FAIL")
	quit(0 if failures.is_empty() else 1)

func _multimesh(world: Node3D,id: String,count: int) -> MultiMeshInstance3D:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = BoxMesh.new()
	multimesh.instance_count = count
	for i in count: multimesh.set_instance_transform(i,Transform3D(Basis.IDENTITY,Vector3(i,0,0)))
	multimesh.custom_aabb = AABB(Vector3(-.5,-.5,-.5),Vector3(maxi(1,count),1,1))
	var node := MultiMeshInstance3D.new()
	node.name = id
	node.multimesh = multimesh
	world.add_child(node)
	return node

func _check(condition: bool,message: String) -> void:
	if not condition: failures.append(message)

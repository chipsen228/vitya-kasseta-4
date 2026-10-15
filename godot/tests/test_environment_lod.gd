## Current cutscene camera controls visible LOD and its private medium caster.
extends SceneTree

const LOD := preload("res://src/environment_lod.gd")
const REGISTRY := preload("res://src/environment_registry.gd")
const CUT := preload("res://src/cutscene.gd")
var failures: Array[String] = []
var checks := 0


func _initialize() -> void:
	call_deferred("_run")


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: failures.append(message)


func _level(owner: LOD, meshes: Array[Mesh], expected: int, stage: String) -> void:
	owner._process(0.0)
	_check(owner.current_level == expected, stage + ": wrong current-camera distance")
	_check(owner.mesh == meshes[expected], stage + ": wrong visible imported resource")
	var caster := owner.get_child(0) as MeshInstance3D
	_check(caster.visible == (expected < 2), stage + ": medium shadow lifetime differs from visible LOD")
	_check(owner.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,
		stage + ": visible detailed geometry casts shadows")
	_check(caster.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY,
		stage + ": private caster adds visible geometry")
	_check(caster.mesh.get_faces() == meshes[1].get_faces(),
		stage + ": private caster changed medium triangle positions")


func _run() -> void:
	var meshes: Array[Mesh] = []
	for level in 3:
		var mesh: Mesh = REGISTRY._load_mesh("res://assets/models/environment/vitya-lod%d.glb" % level)
		_check(mesh != null, "missing actual imported hero LOD%d" % level)
		if mesh != null: meshes.append(mesh)
	if meshes.size() != 3:
		_finish()
		return
	var original_faces: Array = []
	for mesh: Mesh in meshes: original_faces.append(mesh.get_faces())
	var world := Node3D.new()
	root.add_child(world)
	var player_camera := Camera3D.new()
	world.add_child(player_camera)
	player_camera.position = Vector3(0, 0, 5)
	player_camera.make_current()
	var owner := LOD.new()
	world.add_child(owner)
	owner.set_process(false)
	owner.configure(meshes, player_camera)
	_level(owner, meshes, 0, "player near")
	var cut := CUT.new()
	var done_count := [0]
	var shots: Array = [
		{"pos": Vector3(0, 0, 40), "look_at": Vector3.ZERO, "sec": 1.0},
		{"pos": Vector3(0, 0, 20), "look_at": Vector3.ZERO, "sec": 1.0},
		{"pos": Vector3(0, 0, 6), "look_at": Vector3.ZERO, "sec": 1.0},
	]
	_check(cut.play(world, player_camera, shots, 3.0, Callable(),
		func() -> void: done_count[0] += 1), "actual Cutscene did not start")
	_check(world.get_viewport().get_camera_3d() != player_camera,
		"Cutscene did not own the viewport current camera")
	_level(owner, meshes, 2, "cut far, inactive player near")
	player_camera.position = Vector3(0, 0, 40)
	cut.update(1.1)
	_level(owner, meshes, 1, "cut medium, inactive player far")
	cut.update(1.0)
	_level(owner, meshes, 0, "cut near, inactive player far")
	cut.update(1.0)
	_check(not cut.playing and done_count[0] == 1, "Cutscene completion changed")
	_check(world.get_viewport().get_camera_3d() == player_camera,
		"Cutscene did not restore the player current camera")
	_level(owner, meshes, 2, "restored player far")
	_check(owner.get_child_count() == 1, "current-camera switches duplicated caster")
	_check(owner.distances == Vector3(14, 32, 58) and owner.hysteresis == 1.5,
		"camera fix changes distance or hysteresis policy")
	for level in 3:
		_check(meshes[level].get_faces() == original_faces[level], "camera fix mutates imported LOD%d" % level)

	# No active camera in this separate viewport: retain configured-camera API.
	var empty_view := SubViewport.new()
	root.add_child(empty_view)
	world.remove_child(owner)
	empty_view.add_child(owner)
	_check(empty_view.get_camera_3d() == null, "fallback viewport unexpectedly has a current camera")
	player_camera.position = Vector3(0, 0, 5)
	_level(owner, meshes, 0, "no-current-viewport configured near")
	player_camera.position = Vector3(0, 0, 40)
	_level(owner, meshes, 2, "no-current-viewport configured far")
	empty_view.remove_child(owner)
	_check(owner._camera_for_lod() == player_camera, "outside-tree fixture loses configured camera")
	player_camera.free()
	_check(owner._camera_for_lod() == null, "freed fallback camera remains selected")
	owner.free()
	empty_view.free()
	world.free()
	cut = null
	meshes.clear()
	await process_frame
	_finish()


func _finish() -> void:
	for failure: String in failures: printerr("FAIL test_environment_lod: ", failure)
	print("test_environment_lod: %s checks=%d (actual Cutscene current-camera switch, imported LOD/caster, fallback)" % [
		"PASS" if failures.is_empty() else "FAIL", checks])
	quit(0 if failures.is_empty() else 1)

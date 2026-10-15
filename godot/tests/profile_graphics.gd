# Оконная диагностика одного ракурса. Бюджеты и production-настройки не меняет.
# Запускать отдельно от остальных GPU-замеров, без --headless.
# TIME_PROCESS/PHYSICS_PROCESS — CPU monitors, не аппаратные GPU timestamps.
extends SceneTree

const BOOT_FRAMES := 900
const WARMUP_FRAMES := 60
const SAMPLE_FRAMES := 180
const YARD_POS := Vector3(0.0, 0.0, -1.2)
const YARD_YAW := PI
const YARD_PITCH := -0.04
const YARD_NIGHT := 0.10
const VARIANTS := [
	"current", "shadow1024", "shadow20m1024",
	"shadowdisabled", "normalsdisabled", "restorecurrent",
]

var _main: Node
var _player: Player
var _lights: LightRig
var _chain: RenderChain
var _state: GameState
var _chapters: Chapters
var _threat: Variant
var _moon: DirectionalLight3D
var _normals: Array[Dictionary] = []
var _seen_materials: Dictionary = {}
var _original_shadow := true
var _original_distance := 28.0
var _original_atlas := LightRig.MOON_SHADOW_SIZE
var _active_atlas := LightRig.MOON_SHADOW_SIZE
var _original_vsync: DisplayServer.VSyncMode = DisplayServer.VSYNC_ENABLED
var _original_max_fps := 0
var _original_frozen := false
var _original_speed_scale := 1.0
var _captured := false


func _initialize() -> void:
	_run()


func _run() -> void:
	if DisplayServer.get_name() == "headless":
		printerr("profile_graphics: requires a window and real GPU")
		quit(2)
		return
	_original_vsync = DisplayServer.window_get_vsync_mode()
	_original_max_fps = Engine.max_fps
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	_main = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(_main)
	for _i in BOOT_FRAMES:
		if bool(_main.get("boot_ready")) and _main.get("chapters") != null:
			break
		await process_frame
	if not bool(_main.get("boot_ready")) or _main.get("chapters") == null:
		_finish(1, "boot timeout")
		return

	_main.call("_start_game")
	_chapters = _main.get("chapters")
	_chapters.timers.clear()
	var ui: Overlays = _main.get("ui")
	for _i in 90:
		if ui.card.open:
			ui.advanceCard()
		_chapters.timers.clear()
		await process_frame
	if ui.card.open or ui.busy:
		_finish(1, "intro UI is still busy")
		return

	_player = _main.get("player")
	_lights = _main.get("lights")
	_chain = _main.get("render_chain")
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--render=") and not _chain.apply_preset(arg.trim_prefix("--render=")):
			_finish(2, "unknown render preset")
			return
	_state = _main.get("state")
	_threat = _main.get("threat")
	_moon = _lights.moon
	if _moon == null:
		_finish(1, "moon is missing")
		return
	_original_shadow = _moon.shadow_enabled
	_original_distance = _moon.directional_shadow_max_distance
	_original_frozen = _player.frozen
	if _threat != null:
		_original_speed_scale = float(_threat.speedScale)
	_collect_materials(_main)
	_captured = true
	_player.release_lock()
	_player.frozen = true
	_lights.powerOn = true
	for id: String in _lights.state:
		_lights.setLamp(id, false)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	var normal_count := 0
	for entry: Dictionary in _normals:
		if entry["value"] != null and bool(entry["value"]):
			normal_count += 1
	print("profile_graphics: yard=%s yaw=%.4f pitch=%.4f night=%.2f; warmup=%d samples=%d; window=%s buffer=%s renderer=%s; moon=%d/%.1fm normals=%d/%d" % [
		YARD_POS, YARD_YAW, YARD_PITCH, YARD_NIGHT, WARMUP_FRAMES, SAMPLE_FRAMES,
		DisplayServer.window_get_size(), _chain.stats().get("buffer", "?"), _chain.render_preset(),
		_original_atlas, _original_distance, normal_count, _normals.size(),
	])
	if normal_count == 0:
		print("profile_graphics: normalsdisabled is a no-op; no enabled normal maps in active materials")
	var results: Array[Dictionary] = []
	for variant: String in VARIANTS:
		_restore_graphics()
		_prepare_scene()
		match variant:
			"shadow1024":
				_set_atlas(1024)
			"shadow20m1024":
				_set_atlas(1024)
				_moon.directional_shadow_max_distance = 20.0
			"shadowdisabled":
				_moon.shadow_enabled = false
			"normalsdisabled":
				_set_normals_disabled()
		for _i in WARMUP_FRAMES:
			_hold_scene()
			await process_frame
		var result: Dictionary = await _sample(variant)
		results.append(result)
		_restore_graphics()
		if not _graphics_restored():
			_finish(1, "restore failed after " + variant)
			return
		_print_result(result)
	print("PROFILE_GRAPHICS_JSON=" + JSON.stringify({
		"kind": "runtime_diagnostic", "point": "yard", "warmup_frames": WARMUP_FRAMES,
		"sample_frames": SAMPLE_FRAMES, "normal_materials_enabled": normal_count,
		"cpu_monitors_are_not_gpu_timestamps": true, "restored": true, "results": results,
	}))
	_finish(0)


func _prepare_scene() -> void:
	_player.place(YARD_POS.x, YARD_POS.y, YARD_POS.z, YARD_YAW)
	_player.pitch = YARD_PITCH
	_player.pitch_target = YARD_PITCH
	_hold_scene()


func _hold_scene() -> void:
	# Main сохраняет обычный игровой цикл, включая коллизии и update систем.
	# 22-секундный callback фигуры и ход часов не должны менять сцену между пробами.
	_chapters.timers.clear()
	_state.threatState = "absent"
	_state.chapterTime = 0.0
	if _threat != null:
		_threat.speedScale = 0.0
	_lights.set_night_immediate(YARD_NIGHT)


func _sample(variant: String) -> Dictionary:
	var frames: Array[float] = []
	var process_ms: Array[float] = []
	var physics_ms: Array[float] = []
	var calls: Array[float] = []
	var tris: Array[float] = []
	for _i in SAMPLE_FRAMES:
		_hold_scene()
		var started := Time.get_ticks_usec()
		await process_frame
		frames.append(float(Time.get_ticks_usec() - started) / 1000.0)
		process_ms.append(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
		physics_ms.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
		var stats: Dictionary = _chain.stats()
		calls.append(float(stats["calls"]))
		tris.append(float(stats["tris"]))
	var wall: Dictionary = _distribution(frames)
	return {
		"variant": variant, "frames": SAMPLE_FRAMES, "atlas": _active_atlas,
		"moon_shadows": _moon.shadow_enabled, "moon_distance": _moon.directional_shadow_max_distance,
		"normal_maps_disabled": variant == "normalsdisabled",
		"median_fps": 1000.0 / maxf(float(wall["median"]), 0.001), "frame_ms": wall,
		"process_ms": _distribution(process_ms), "physics_ms": _distribution(physics_ms),
		"calls": _distribution(calls), "tris": _distribution(tris),
	}


func _distribution(values: Array[float]) -> Dictionary:
	var ordered: Array[float] = values.duplicate()
	ordered.sort()
	var count := ordered.size()
	var middle := floori(float(count) * 0.5)
	var median: float = ordered[middle]
	if count % 2 == 0:
		median = (ordered[middle - 1] + ordered[middle]) * 0.5
	return {"median": median, "p95": ordered[mini(count - 1, ceili(count * 0.95) - 1)],
		"min": ordered[0], "max": ordered[-1]}


func _print_result(result: Dictionary) -> void:
	print("profile_graphics: %s medianFPS=%.2f" % [result["variant"], result["median_fps"]])
	for metric: String in ["frame_ms", "process_ms", "physics_ms", "calls", "tris"]:
		var sample: Dictionary = result[metric]
		print("  %s median=%.3f p95=%.3f max=%.3f" % [metric, sample["median"], sample["p95"], sample["max"]])


func _collect_materials(node: Node) -> void:
	if node is MeshInstance3D:
		var instance := node as MeshInstance3D
		_collect_material(instance.material_overlay)
		_collect_material(instance.material_override)
		if instance.mesh != null:
			for surface in instance.mesh.get_surface_count():
				_collect_material(instance.get_active_material(surface))
	elif node is MultiMeshInstance3D:
		var instance := node as MultiMeshInstance3D
		_collect_material(instance.material_overlay)
		_collect_material(instance.material_override)
		if instance.multimesh != null and instance.multimesh.mesh != null and instance.material_override == null:
			for surface in instance.multimesh.mesh.get_surface_count():
				_collect_material(instance.multimesh.mesh.surface_get_material(surface))
	for child: Node in node.get_children():
		_collect_materials(child)


func _collect_material(material: Material) -> void:
	if material == null or _seen_materials.has(material.get_instance_id()):
		return
	_seen_materials[material.get_instance_id()] = true
	if material is ShaderMaterial:
		var shader_material := material as ShaderMaterial
		if shader_material.shader != null:
			for uniform: Dictionary in shader_material.shader.get_shader_uniform_list():
				if String(uniform.get("name", "")) == "use_normal":
					_normals.append({"material": material, "shader": true,
						"value": shader_material.get_shader_parameter("use_normal")})
					break
	elif material is BaseMaterial3D:
		_normals.append({"material": material, "shader": false,
			"value": (material as BaseMaterial3D).normal_enabled})
	_collect_material(material.next_pass)


func _set_normals_disabled() -> void:
	for entry: Dictionary in _normals:
		if bool(entry["shader"]):
			(entry["material"] as ShaderMaterial).set_shader_parameter("use_normal", false)
		else:
			(entry["material"] as BaseMaterial3D).normal_enabled = false


func _set_atlas(size: int) -> void:
	if _active_atlas != size:
		RenderingServer.directional_shadow_atlas_set_size(size, true)
		_active_atlas = size


func _restore_graphics() -> void:
	if not _captured:
		return
	_set_atlas(_original_atlas)
	_moon.shadow_enabled = _original_shadow
	_moon.directional_shadow_max_distance = _original_distance
	for entry: Dictionary in _normals:
		if bool(entry["shader"]):
			(entry["material"] as ShaderMaterial).set_shader_parameter("use_normal", entry["value"])
		else:
			(entry["material"] as BaseMaterial3D).normal_enabled = bool(entry["value"])


func _graphics_restored() -> bool:
	if _active_atlas != _original_atlas or _moon.shadow_enabled != _original_shadow \
			or not is_equal_approx(_moon.directional_shadow_max_distance, _original_distance):
		return false
	for entry: Dictionary in _normals:
		var value: Variant = (entry["material"] as ShaderMaterial).get_shader_parameter("use_normal") \
			if bool(entry["shader"]) else (entry["material"] as BaseMaterial3D).normal_enabled
		if value != entry["value"]:
			return false
	return true


func _finish(code: int, reason: String = "") -> void:
	_restore_graphics()
	if _captured:
		_player.frozen = _original_frozen
		if _threat != null:
			_threat.speedScale = _original_speed_scale
	DisplayServer.window_set_vsync_mode(_original_vsync)
	Engine.max_fps = _original_max_fps
	if not reason.is_empty():
		printerr("profile_graphics: FAIL " + reason)
	if is_instance_valid(_main):
		_main.queue_free()
	quit(code)

## Diagnostic toggles only; these states never enter production or acceptance runs.
extends SceneTree
const BENCH := preload("res://tests/bench_render.gd")
var main: Node
var rows: Array = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1280,720)
	root.min_size = root.size
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	main = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for i in 5000:
		if main.get("boot_ready"): break
		await process_frame
	main.call("_start_game")
	for i in 90:
		if main.get("ui").card.open: main.get("ui").advanceCard()
		await process_frame
	var chain: RenderChain = main.get("render_chain")
	chain.apply_preset("hq")
	var lights: LightRig = main.get("lights")
	var player: Player = main.get("player")
	player.release_lock()
	main.get("threat").speedScale = 0.0
	var groups: Dictionary = {"models":[],"world":[],"forest":[],"props":[],"interiors":[],"other":[]}
	var nodes: Array[Node] = [chain.world_root]
	var index := 0
	while index < nodes.size():
		var node: Node = nodes[index]
		nodes.append_array(node.get_children())
		index += 1
		if not node is GeometryInstance3D or node.has_meta("static_shadow_proxy"): continue
		var kind := "other"
		if node is EnvironmentLod: kind = "models"
		elif node.has_meta("environment_interior"): kind = "interiors"
		elif node.get_script() == load("res://src/forest_lod_mesh.gd"): kind = "forest"
		elif String(node.name).begins_with("merged_") or node.name == "environment-residual": kind = "world"
		else:
			for holder: Node in main.get("props").by_id.values():
				if holder.is_ancestor_of(node):
					kind = "props"
					break
		groups[kind].append(node)
	for point: Dictionary in BENCH.POINTS:
		if point["name"] not in ["yard","snt-gate","gap-to-second-line"]: continue
		player.place(point["pos"].x,point["pos"].y,point["pos"].z,point["yaw"])
		player.pitch = point["pitch"]
		player.pitch_target = point["pitch"]
		lights.set_night_immediate(point["night"])
		for i in 120: await process_frame
		await _measure(point["name"],"normal")
		main.set_process(false)
		await _measure(point["name"],"main-process-off")
		lights.moon.shadow_enabled = false
		await _measure(point["name"],"moon-shadows-off")
		lights.moon.shadow_enabled = true
		for kind: String in groups:
			var layers: Array = []
			for node: GeometryInstance3D in groups[kind]:
				layers.append(node.layers)
				node.layers = 0
			await _measure(point["name"],kind+"-layers-off")
			for i in groups[kind].size(): groups[kind][i].layers = layers[i]
		main.set_process(true)
	var file := FileAccess.open("res://../output/environment-refresh/render-diagnostics.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"diagnostic_only":true,"results":rows},"\t"))
	print("diagnose_environment_render: PASS diagnostic states only")
	quit()

func _measure(point: String, change: String) -> void:
	for i in 20: await process_frame
	var frames: Array[float] = []
	var cpu: Array[float] = []
	var physics: Array[float] = []
	for i in 100:
		var start := Time.get_ticks_usec()
		await process_frame
		frames.append((Time.get_ticks_usec()-start)/1000.0)
		cpu.append(Performance.get_monitor(Performance.TIME_PROCESS)*1000.0)
		physics.append(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)*1000.0)
	frames.sort()
	cpu.sort()
	physics.sort()
	var stats: Dictionary = main.get("render_chain").stats()
	var row := {"point":point,"change":change,"median_ms":frames[50],"p95_ms":frames[94],"stats":stats,
		"cpu_process_median_ms":cpu[50],"cpu_process_p95_ms":cpu[94],"cpu_physics_median_ms":physics[50],"cpu_physics_p95_ms":physics[94]}
	rows.append(row)
	print(JSON.stringify(row))

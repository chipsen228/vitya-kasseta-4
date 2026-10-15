## Diagnostic source/pass census. Never used as an acceptance measurement.
extends SceneTree

const CENSUS := preload("res://tests/profile_visible_geometry.gd")
var main: Node
var report: Array = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	root.size = Vector2i(1280,720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	main = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for i in 3000:
		if main.get("boot_ready"): break
		await process_frame
	main.get("render_chain").apply_preset("hq")
	main.set("running",false)
	var chain: RenderChain = main.get("render_chain")
	var camera := chain.camera
	var lights: LightRig = main.get("lights")
	var flashlight: Flashlight = main.get("flashlight")
	var groups: Dictionary = {"models":[],"model-shadows":[],"world":[],"world-shadows":[],"forest":[],"props":[],"interiors":[],"other":[]}
	for node: Node in SkinLayer._nodes(chain.world_root):
		if not node is GeometryInstance3D: continue
		var kind := "other"
		if node.has_meta("environment_shadow_proxy"): kind = "model-shadows"
		elif node.has_meta("static_shadow_proxy"): kind = "world-shadows"
		elif node is EnvironmentLod: kind = "models"
		elif node.get_script() == load("res://src/forest_lod_mesh.gd"): kind = "forest"
		elif node.has_meta("environment_interior"): kind = "interiors"
		elif String(node.name).begins_with("merged_") or node.name == "environment-residual": kind = "world"
		else:
			for holder: Node in main.get("props").by_id.values():
				if holder.is_ancestor_of(node): kind = "props"; break
		groups[kind].append(node)
	for point: Dictionary in [
		{"id":"cellar-transfer","pos":Vector3(-3,.13,10.5),"yaw":0.0,"pitch":0.0},
		{"id":"cellar-crouch","pos":Vector3(-3,-.55,10.5),"yaw":0.0,"pitch":0.0},
		{"id":"route-peak","pos":Vector3(-.068,1.68,1.93),"yaw":.2835,"pitch":sin(22.7466*.9)*.12},
		{"id":"capture-start","pos":Vector3(0,1.68,2),"yaw":0.0,"pitch":0.0},
		{"id":"departure-third","pos":Vector3(-2,1.5,-6.5),"look_at":Vector3(-2.5,.9,-2.7)},
	]:
		camera.global_position = point["pos"]
		if point.has("look_at"): camera.look_at(point["look_at"])
		else: camera.rotation = Vector3(point["pitch"],point["yaw"],0)
		lights.powerOn = true
		for id: String in lights.state:
			lights.setLamp(id,id in ["porch","hall","kitchen","landing","vitya"])
		lights.set_night_immediate(.8)
		lights.update(1.0,camera.global_position,"plot",true)
		flashlight.on = true
		flashlight.light.visible = true
		flashlight.set("_body",camera.global_position)
		flashlight.set("_aim",camera.global_position-camera.global_basis.z*6.0)
		flashlight.update(0.0)
		for i in 90: await process_frame
		await _record(point["id"],"normal")
		var collector := CENSUS.new()
		var rows: Array[Dictionary] = []
		collector._collect(chain.world_root,camera,rows)
		rows = rows.filter(func(row: Dictionary)->bool:
			var geometry: GeometryInstance3D = root.get_node(row["path"])
			return geometry.layers != 0)
		rows.sort_custom(func(a: Dictionary,b: Dictionary)->bool:return a["tris"]>b["tris"])
		report.append({"point":point["id"],"source_census":rows})
		collector.free()
		main.set_process(false)
		for nodes: Array in groups.values():
			for node: Node in nodes: node.set_process(false)
		for kind: String in groups:
			var layers: Array=[]
			for node: GeometryInstance3D in groups[kind]: layers.append(node.layers); node.layers=0
			await _record(point["id"],kind+"-off")
			for i in groups[kind].size(): groups[kind][i].layers=layers[i]
		lights.moon.shadow_enabled=false
		await _record(point["id"],"moon-shadow-off")
		lights.moon.shadow_enabled=true
		flashlight.light.shadow_enabled=false
		await _record(point["id"],"flash-shadow-off")
		flashlight.light.shadow_enabled=true
		for nodes: Array in groups.values():
			for node: Node in nodes: if node.get_script()!=null: node.set_process(true)
		main.set_process(true)
	var out := "res://../output/environment-refresh/route-geometry-census-cellar.json"
	FileAccess.open(out,FileAccess.WRITE).store_string(JSON.stringify({"diagnostic_only":true,"rows":report},"\t"))
	print("diagnose_environment_route_geometry: PASS diagnostic only")
	main.queue_free()
	await process_frame
	quit()

func _record(point: String,change: String) -> void:
	for i in 8: await process_frame
	var row := {"point":point,"change":change,"stats":main.get("render_chain").stats()}
	report.append(row)
	print(JSON.stringify(row))

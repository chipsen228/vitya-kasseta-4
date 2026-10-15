extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var path := ""
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): path = arg.trim_prefix("--output=")
	if path.is_empty():
		printerr("capture_environment_contract: FAIL missing --output")
		quit(1)
		return
	var main: Node = load("res://src/main.tscn").instantiate()
	root.add_child(main)
	for i in 2400:
		if main.get("boot_ready"): break
		await process_frame
	if not main.get("boot_ready"):
		printerr("capture_environment_contract: FAIL boot timeout")
		quit(1)
		return
	main.set_process(false)
	var col: CollisionWorld = main.get("col")
	var sets: Array = []
	for set_id in CollisionWorld.SET_COUNT:
		var names: Dictionary = {}
		for id: String in col._by_id[set_id]:
			for index: int in col._by_id[set_id][id]: names[index] = id
		var shapes: Array = []
		for i in col.box_count(set_id):
			shapes.append({"id": names.get(i,""), "shape": Array(col._data[set_id].slice(i*CollisionWorld.STRIDE,(i+1)*CollisionWorld.STRIDE)), "active": bool(col._active[set_id][i])})
		sets.append(shapes)
	var interactions: Array = []
	for item: Dictionary in (main.get("interact") as Interact).list:
		var p: Vector3 = item.get("pos", Vector3.ZERO)
		interactions.append({"id":item.get("id",""),"pos":[p.x,p.y,p.z],"radius":item.get("r",0.0)})
	var snapshot := {"sets":sets,"interactions":interactions,"navigation":(main.get("nav") as NavGraph).stats()}
	var file := FileAccess.open(path,FileAccess.WRITE)
	if file == null:
		printerr("capture_environment_contract: FAIL output",path)
		quit(1)
		return
	file.store_string(JSON.stringify(snapshot,"\t"))
	file.close()
	print("capture_environment_contract: PASS ",path)
	quit(0)

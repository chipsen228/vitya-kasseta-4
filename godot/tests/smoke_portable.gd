# Cold-import package check, using only the bundled engine and local resources.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var main := (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	var frames := 0
	while not bool(main.get("boot_ready")) and frames < 3600:
		await process_frame
		frames += 1
	if not bool(main.get("boot_ready")):
		printerr("smoke_portable: FAIL boot timeout")
		quit(1)
		return
	var ui: Overlays = main.get("ui")
	if bool(ui.get("_load").visible) or not bool(ui.get("_start").visible):
		printerr("smoke_portable: FAIL startup UI")
		quit(1)
		return
	main.call("_start_game")
	for i in 120:
		if ui.card.open:
			ui.advanceCard()
		await process_frame
	if not bool(main.get("running")) or bool(ui.get("_start").visible):
		printerr("smoke_portable: FAIL start did not enter game")
		quit(1)
		return
	print("smoke_portable: PASS local cold boot, material warmup and gameplay entry")
	main.queue_free()
	await process_frame
	await process_frame
	quit(0)

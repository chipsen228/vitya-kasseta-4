## Diagnostic comparison only. Production/acceptance bench keeps LightRig defaults.
extends "res://tests/bench_render.gd"

func _print_setup(main: Node, stage: String) -> void:
	if stage == "measurement-start":
		RenderingServer.directional_shadow_atlas_set_size(1024,true)
		print("bench_shadow_atlas: DIAGNOSTIC 1024 atlas, no production acceptance")
	super._print_setup(main,stage)

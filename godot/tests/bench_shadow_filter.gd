## Diagnostic comparison only; no changed setting is saved to the game.
extends "res://tests/bench_render.gd"

func _print_setup(main: Node, stage: String) -> void:
	if stage == "measurement-start":
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_VERY_LOW)
		print("bench_shadow_filter: DIAGNOSTIC lower soft-shadow sampling")
	super._print_setup(main,stage)

func _print_result(name: String, samples: Array[float], stats: Dictionary, strict: bool) -> int:
	var result := super._print_result(name,samples,stats,strict)
	print("bench_shadow_filter: PASS completed diagnostic sample ",name)
	return result

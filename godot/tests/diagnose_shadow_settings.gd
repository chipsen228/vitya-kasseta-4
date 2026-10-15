extends SceneTree
func _initialize() -> void:
	for key: String in ["rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality",
		"rendering/lights_and_shadows/positional_shadow/soft_shadow_filter_quality"]:
		print(key,"=",ProjectSettings.get_setting(key,"unset"))
	for key: String in ClassDB.class_get_integer_constant_list("RenderingServer"):
		if "SHADOW_QUALITY" in key: print(key,"=",ClassDB.class_get_integer_constant("RenderingServer",key))
	quit()

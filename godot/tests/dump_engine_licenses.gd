# Export notices from the actual bundled binary, without a network dependency.
extends SceneTree

func _initialize() -> void:
	var output := "res://../tools/engine-notices"
	for arg: String in OS.get_cmdline_user_args():
		if arg.begins_with("--output="): output = arg.trim_prefix("--output=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(output))
	var license := FileAccess.open(output.path_join("GODOT_LICENSE.txt"),FileAccess.WRITE)
	license.store_string(Engine.get_license_text())
	license.close()
	var third_party := FileAccess.open(output.path_join("THIRD_PARTY_NOTICES.json"),FileAccess.WRITE)
	third_party.store_string(JSON.stringify({"engine":Engine.get_version_info(),
		"copyright":Engine.get_copyright_info(),"licenses":Engine.get_license_info(),
		"source":"Engine.get_license_text/get_copyright_info/get_license_info; actual distributed binary",
		"documentation":"https://godotengine.org/license/"},"\t"))
	third_party.close()
	print("dump_engine_licenses: PASS ",Engine.get_version_info()["string"])
	quit()

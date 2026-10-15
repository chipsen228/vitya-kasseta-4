# Зональный свет: закрытая комната не занимает пул лампами за стеной,
# переносная керосинка проходит между зонами, дальности остаются бюджетными.
extends SceneTree


func _initialize() -> void:
	var errs: Array[String] = []
	var rig := LightRig.new()
	rig.build()
	root.add_child(rig)
	rig.powerOn = true
	var near := 1.0
	for lamp: Dictionary in rig.lamps:
		rig.state[String(lamp["id"])] = false
		if ["banya", "shop-in", "stop", "lantern"].has(String(lamp["id"])):
			lamp["pos"] = Vector3(near, 1.0, 0.0)
			near += 1.0
			rig.state[String(lamp["id"])] = true

	rig.update(1.0, Vector3.ZERO, "banya", false)
	var indoor_ids := _picked_ids(rig)
	var indoor_hemi := float(rig.get("_hemi_energy"))
	var indoor_moon := float(rig.get("_moon_energy"))
	if indoor_ids != ["banya", "lantern"]:
		errs.append("баня получила лампы %s вместо [banya, lantern]" % [indoor_ids])

	rig.update(1.0, Vector3.ZERO, "street", true)
	var outdoor_ids := _picked_ids(rig)
	if float(rig.get("_hemi_energy")) <= indoor_hemi or float(rig.get("_moon_energy")) <= indoor_moon:
		errs.append("ambient/луна снаружи не стали сильнее, чем в помещении")
	if not outdoor_ids.has("shop-in") or not outdoor_ids.has("stop"):
		errs.append("снаружи выбор по расстоянию не видит соседние лампы: %s" % [outdoor_ids])

	var ranges := {
		"room": LightRig._lamp_range({"zone": "floor1"}),
		"shop": LightRig._lamp_range({"zone": "shop"}),
		"small": LightRig._lamp_range({"zone": "banya"}),
		"outdoor": LightRig._lamp_range({"zone": "street"}),
		"lantern": LightRig._lamp_range({"zone": "plot", "portable": true}),
	}
	var expected := {"room": 7.5, "shop": 7.5, "small": 6.0, "outdoor": 9.0, "lantern": 6.5}
	for key: String in expected:
		if not is_equal_approx(float(ranges[key]), float(expected[key])):
			errs.append("дальность %s = %.2f, ожидалось %.2f" % [key, ranges[key], expected[key]])

	if rig.pool.size() != 2:
		errs.append("пул содержит %d источников вместо двух" % rig.pool.size())
	for light: OmniLight3D in rig.pool:
		if light.shadow_enabled:
			errs.append("у лампы пула неожиданно включена тень")

	rig.free()
	if errs.is_empty():
		print("test_zone_lights: PASS")
		quit(0)
		return
	print("test_zone_lights: FAIL (%d)" % errs.size())
	for e: String in errs:
		print("  - ", e)
	quit(1)


func _picked_ids(rig: LightRig) -> Array[String]:
	var out: Array[String] = []
	for row: Dictionary in rig.get("_lit"):
		out.append(String((row["lamp"] as Dictionary)["id"]))
	return out

# Сюжетная ночь: канонические монотонные ступени, плавный показ и точный
# snapshot/restore без полей в GameState.
extends SceneTree


func _initialize() -> void:
	var errs: Array[String] = []
	_check_clock(errs)
	_check_targets(errs)
	_check_clock_curve(errs)
	_check_transition_and_snapshot(errs)
	_check_zone_invariant(errs)
	_check_presets(errs)
	_check_story_wiring(errs)

	if errs.is_empty():
		print("test_light_transition: PASS")
		quit(0)
		return
	print("test_light_transition: FAIL (%d)" % errs.size())
	for e: String in errs:
		print("  - ", e)
	quit(1)


func _check_clock(errs: Array[String]) -> void:
	var state := GameState.new()
	state.chapter = "prologue"
	state.chapterTime = 0.0
	if not is_equal_approx(state.clock_seconds(), 20 * 3600 + 41 * 60):
		errs.append("prologue clock starts before 20:41")
	state.chapter = "village"
	state.chapterTime = 0.0
	if not is_equal_approx(state.clock_seconds(), 24 * 3600 + 20 * 60):
		errs.append("clock_seconds wrapped after midnight")
	if state.timecode() != "00:20:00":
		errs.append("timecode did not wrap continuous clock: %s" % state.timecode())
	state.chapterTime = 60.0
	if not is_equal_approx(state.clock_seconds(), 24 * 3600 + 23 * 60):
		errs.append("clock_seconds does not advance at RATE")


func _check_targets(errs: Array[String]) -> void:
	var names := ["arrival", "lights-on", "power-restored", "loft", "tapes",
		"street", "blackout", "village", "gate"]
	var expected := [0.0, 0.12, 0.24, 0.42, 0.58, 0.72, 0.86, 0.95, 1.0]
	var previous := -1.0
	for i in names.size():
		var value := float(LightRig.STORY_NIGHT.get(names[i], -1.0))
		var expected_value := float(expected[i])
		if not is_equal_approx(value, expected_value):
			errs.append("ступень %s = %.2f вместо %.2f" % [names[i], value, expected_value])
		if value < previous:
			errs.append("ступени ночи не монотонны на %s" % names[i])
		previous = value


func _check_clock_curve(errs: Array[String]) -> void:
	var previous := -1.0
	for point: Array in LightRig.CLOCK_NIGHT:
		var seconds := float(point[0])
		var expected := float(point[1])
		var value := LightRig.night_at_clock(seconds)
		if not is_equal_approx(value, expected):
			errs.append("clock night point %.0f = %.4f instead of %.4f" \
				% [seconds, value, expected])
		if value < previous:
			errs.append("clock night curve regressed at %.0f" % seconds)
		previous = value
	var a: Array = LightRig.CLOCK_NIGHT[2]
	var b: Array = LightRig.CLOCK_NIGHT[3]
	var midpoint := (float(a[0]) + float(b[0])) * 0.5
	var expected_midpoint := (float(a[1]) + float(b[1])) * 0.5
	if not is_equal_approx(LightRig.night_at_clock(midpoint), expected_midpoint):
		errs.append("clock night curve is not linear between key times")
	if not is_equal_approx(LightRig.night_at_clock(26 * 3600), 1.0):
		errs.append("clock night curve does not clamp after last key time")


func _check_transition_and_snapshot(errs: Array[String]) -> void:
	var rig := LightRig.new()
	rig.build()
	root.add_child(rig)
	rig.set_story_night(1.0)
	var previous := float(rig.get("_display_night"))
	for _i in 10:
		rig.update(1.0, Vector3.ZERO, "street", true)
		var shown := float(rig.get("_display_night"))
		if shown <= previous or shown >= 1.0:
			errs.append("переход ночи перестал быть плавным/монотонным: %.4f -> %.4f" % [previous, shown])
			break
		previous = shown
	if absf(previous - 0.99) > 0.0001:
		errs.append("10-second exponential transition = %.6f instead of about 0.99" % previous)

	var snap := rig.snapshot()
	if not snap.has("night") or not snap.has("displayNight"):
		errs.append("snapshot не содержит target/display night")
	rig.set_night_immediate(0.0)
	rig.restore(snap)
	if not is_equal_approx(rig.night, 1.0) \
			or not is_equal_approx(float(rig.get("_display_night")), previous):
		errs.append("restore не вернул target/display night")
	# Постоянно меняющаяся часовая цель не перезапускает движение: каждый кадр
	# остаётся темнее предыдущего и приближается к новой цели.
	rig.set_night_immediate(0.0)
	previous = 0.0
	for i in 20:
		rig.night = 0.0
		rig.set_clock_seconds(20 * 3600 + 41 * 60 + (i + 1) * 600.0)
		rig.update(0.1, Vector3.ZERO, "street", true)
		var shown := float(rig.get("_display_night"))
		if shown <= previous:
			errs.append("changing clock target froze/regressed the transition")
			break
		previous = shown

	# Позднее событие не имеет права вернуть более светлую сюжетную ступень.
	rig.set_story_night(1.0)
	rig.set_story_night(0.42)
	if not is_equal_approx(rig.night, 1.0):
		errs.append("set_story_night разрешил регресс сюжетной цели")
	# Старые снимки загружаются без повторного затемнения.
	rig.restore({"night": 0.42, "nightFrom": 0.1, "nightElapsed": 4.0})
	if not is_equal_approx(float(rig.get("_display_night")), 0.42):
		errs.append("legacy snapshot не синхронизировал display night")
	rig.free()


func _check_zone_invariant(errs: Array[String]) -> void:
	var rig := LightRig.new()
	rig.build()
	root.add_child(rig)
	rig.set_night_immediate(1.0)
	rig.update(10.0, Vector3.ZERO, "street", true)
	var outdoor_hemi := float(rig.get("_hemi_energy"))
	var outdoor_moon := float(rig.get("_moon_energy"))
	rig.update(10.0, Vector3.ZERO, "floor1", false)
	var indoor_hemi := float(rig.get("_hemi_energy"))
	var indoor_moon := float(rig.get("_moon_energy"))
	if indoor_hemi >= outdoor_hemi or indoor_moon >= outdoor_moon:
		errs.append("indoor ambient/moon не слабее outdoor")
	rig.free()


func _check_presets(errs: Array[String]) -> void:
	var dusk: Dictionary = LightRig.SKY["dusk"]
	var night: Dictionary = LightRig.SKY["night"]
	if float(dusk["hemi"]) <= 2.8 or float(dusk["fogFar"]) <= 64.0:
		errs.append("dusk не стал светлее и дальнобойнее исходного пресета")
	if float(night["hemi"]) <= 0.9 or float(night["fogFar"]) <= 32.0:
		errs.append("night не поднял ambient/fogFar относительно глухой ночи")


func _check_story_wiring(errs: Array[String]) -> void:
	var chapters := FileAccess.get_file_as_string("res://src/chapters.gd")
	for stage: String in LightRig.STORY_NIGHT.keys():
		var call := "_story_night(c, \"%s\")" % stage
		if not chapters.contains(call):
			errs.append("chapters.gd does not wire story-light stage %s" % stage)
	if chapters.contains(".night ="):
		errs.append("chapters.gd still bypasses monotonic set_story_night")
	var shots := FileAccess.get_file_as_string("res://tests/shots.gd")
	var bench := FileAccess.get_file_as_string("res://tests/bench_render.gd")
	if not shots.contains("set_night_immediate") or not bench.contains("set_night_immediate"):
		errs.append("render probes do not apply the requested night target immediately")

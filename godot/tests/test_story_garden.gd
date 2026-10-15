extends SceneTree


func _initialize() -> void:
	var errors: Array[String] = []
	var state := GameState.new()
	var quest := OutskirtsQuest.new({"state": state}, {})

	for i in 4:
		state.set_flag("watered-%d" % i)
	if not quest._rows_watered(state):
		errors.append("watered-0..3 do not complete the four-row chain")
	state.reset()
	state.set_flag("watered-4")
	if quest._rows_watered(state):
		errors.append("legacy watered-4 still contributes to completion")
	state.set_flag("water-done")
	if not quest._rows_watered(state):
		errors.append("legacy water-done is not immediately complete")

	# A callback captured before resync must never heat the restored attempt,
	# even if the player has already closed its damper again.
	state.reset()
	state.chapter = "village"
	state.set_flag("damper-shut")
	var ctx := {"state": state}
	quest = OutskirtsQuest.new(ctx, {})
	quest._schedule_banya_heat(ctx, {})
	var stale_generation: int = quest._banya_timer_generation
	quest.resync(state)
	quest._complete_banya_heat(stale_generation, ctx, {})
	if state.has("banya-hot"):
		errors.append("stale pre-retry banya callback set banya-hot")
	quest._complete_banya_heat(quest._banya_timer_generation, ctx, {})
	if not state.has("banya-hot"):
		errors.append("current banya timer cannot set persisted banya-hot")

	# Garden flags remain ordinary strings; recovery adds three backward-compatible fields.
	state.set_flag("garden-dug-0")
	state.set_flag("garden-skeleton")
	var parsed: Dictionary = JSON.parse_string(state.snapshot())
	var keys := parsed.keys()
	keys.sort()
	var expected := ["callsMade", "chapter", "chapterTime", "evidence", "failCount",
		"flags", "horror_seen", "inventory", "looked", "recovery",
		"recovery_completed_count", "tapesWatched", "task", "threatState"]
	expected.sort()
	if keys != expected:
		errors.append("snapshot JSON schema changed: %s" % [keys])

	var legacy := parsed.duplicate(true)
	for field: String in ["horror_seen", "recovery", "recovery_completed_count"]: legacy.erase(field)
	var restored := GameState.new()
	restored.restore(JSON.stringify(legacy))
	if not restored.has("garden-dug-0") or not restored.recovery.is_empty() or restored.recovery_completed_count != 0:
		errors.append("legacy garden snapshot no longer restores with recovery defaults")

	if errors.is_empty():
		print("test_story_garden: PASS (four rows, legacy flags, retry-safe heat, save schema)")
		quit(0)
		return
	for error: String in errors:
		printerr("FAIL test_story_garden: ", error)
	quit(1)

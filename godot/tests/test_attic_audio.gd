extends SceneTree

class Audio extends GameAudio:
	var shots: Array = []
	var knocks := 0
	var hits := 0
	var available := true
	func spatial_sfx(id: String, at: Vector3, gain := 1.0, radius := 32.0, owner := "", priority := 0) -> bool:
		shots.append([id, at, gain, radius, owner, priority])
		return available
	func knock(_times := 1, _spacing := 0.18) -> void: knocks += 1
	func stinger(_power := 1.0) -> void: hits += 1

class LegacyAudio extends RefCounted:
	var knocks := 0
	func knock(_times := 1) -> void: knocks += 1
	func stinger(_power := 1.0) -> void: pass

class Flash extends RefCounted:
	func shake(_value: float) -> void: pass

class Lights extends RefCounted:
	var blackout_seconds := 0.0
	func blackout(seconds: float) -> void: blackout_seconds = seconds
	func setLamp(_id: String, _on: bool) -> void: pass

class UI extends RefCounted:
	func say(_text: String, _seconds: float) -> void: pass

class PropsStub extends RefCounted:
	func show_dynamic(_id: String) -> void: pass

class Renderer extends RefCounted:
	func set_tracking(_value: float) -> void: pass

class Controls extends RefCounted:
	func feet() -> Vector3: return Vector3(0.0, 5.9, 12.0)

class Voice extends RefCounted:
	var speaking := false
	func dialogue_active() -> bool: return speaking

class Director extends RefCounted:
	var cooldown := 0.0
	var busy := false
	var sources: Array = []
	func exclusive() -> bool: return busy
	func context(id: String, sound: String, at := Vector3.INF) -> void: sources.append([id, sound, at])

var errors: Array[String] = []


func _initialize() -> void:
	var state := GameState.new()
	state.chapter = "tapes"
	var audio := Audio.new()
	var lights := Lights.new()
	var voice := Voice.new()
	var director := Director.new()
	var c := {"state": state, "audio": audio, "lights": lights, "flashlight": Flash.new(),
		"ui": UI.new(), "props": PropsStub.new(), "renderer": Renderer.new(),
		"controls": Controls.new(), "voice": voice,
		"scaresOn": func() -> bool: return true,
		"world": {"zone_at": func(_x: float, _y: float, _z: float) -> Dictionary: return {"level": "roof"}}}
	var chapters := Chapters.new(c)
	c["horror"] = director
	chapters._tapes_notebook_read(c, null)
	_check(audio.shots.size() == 1 and audio.shots[0] == ["horror-latch", Vector3(-4.15, 5.9, 14.35), 0.9, 12.0, "warning", 3], "latch must play at actual hatch with warning ownership")
	_check(audio.knocks == 0 and audio.hits == 1, "successful spatial latch replaces knock and preserves existing hit")
	_check(state.hasItem("tape-x") and lights.blackout_seconds == 9.0, "existing blackout and tape reward remain")
	_check(chapters.timers.size() == 2 and chapters.timers[1]["event"] == "hatch-steps" and chapters.timers[1]["t"] == 4.0, "steps wait until latch and initial line finish")
	chapters._tapes_notebook_read(c, null)
	_check(audio.shots.size() == 1 and audio.hits == 1 and chapters.timers.size() == 2, "same notebook cannot replay beat")
	voice.speaking = true
	chapters._tapes_hatch_steps(c, null)
	_check(audio.shots.size() == 1, "steps must not overlap speech")
	voice.speaking = false
	director.cooldown = 12.0
	chapters._tapes_hatch_steps(c, null)
	_check(audio.shots.size() == 1, "recent scare suppresses extra steps")
	director.cooldown = 0.0
	director.busy = true
	chapters._tapes_hatch_steps(c, null)
	_check(audio.shots.size() == 1, "exclusive scene suppresses extra steps")
	director.busy = false
	chapters._tapes_hatch_steps(c, null)
	_check(audio.shots.size() == 2 and audio.shots[1] == ["horror-run-wood", Vector3(-1.1, 7.8, 13.2), 0.58, 12.0, "warning", 1], "quiet follow-up comes from beams")
	state.chapter = "street"
	chapters._tapes_hatch_steps(c, null)
	_check(audio.shots.size() == 2, "follow-up cannot follow player into next chapter")
	state.chapter = "tapes"
	state.set_flag("hatch-slam", false)
	chapters.timers.clear()
	c["scaresOn"] = func() -> bool: return false
	chapters._tapes_notebook_read(c, null)
	_check(audio.shots.size() == 2 and audio.knocks == 1 and chapters.timers.size() == 1, "disabled scares use knock and omit steps")
	c["scaresOn"] = func() -> bool: return true
	state.set_flag("hatch-slam", false)
	audio.available = false
	chapters._tapes_notebook_read(c, null)
	_check(audio.knocks == 2, "missing sample falls back to knock")
	var legacy := LegacyAudio.new()
	c["audio"] = legacy
	state.set_flag("hatch-slam", false)
	chapters._tapes_notebook_read(c, null)
	_check(legacy.knocks == 1, "audio without spatial API retains working knock")
	state.chapter = "loft"
	chapters._above_head(c, null)
	_check(director.sources.is_empty(), "loft cue does not arm from roof or other room")
	c["world"]["zone_at"] = func(_x: float, _y: float, _z: float) -> Dictionary: return {"level": "attic", "id": "balcony"}
	chapters._above_head(c, null)
	_check(director.sources.is_empty(), "loft cue does not arm outdoors on balcony")
	c["world"]["zone_at"] = func(_x: float, _y: float, _z: float) -> Dictionary: return {"level": "attic", "id": "loft"}
	chapters._above_head(c, null)
	_check(director.sources == [["loft-attic-return", "horror-attic-creak", Vector3(-1.1, 7.8, 13.2)]], "loft cue uses actual beams as its source")
	state.chapter = "street"
	chapters._above_head(c, null)
	_check(director.sources.size() == 1, "loft cue does not arm after leaving chapter")
	if errors.is_empty(): print("test_attic_audio: PASS (source, priority, once, dialogue/cooldown gates, soft fallback)")
	for error: String in errors: printerr(error)
	c.clear()
	chapters.ctx.clear()
	audio.free()
	quit(0 if errors.is_empty() else 1)


func _check(ok: bool, message: String) -> void:
	if not ok: errors.append(message)

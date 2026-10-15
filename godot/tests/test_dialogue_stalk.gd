# Диалог в сельпо до бегунка: настоящий Phone должен вернуть тики патруля.
# Main не добавляется в дерево, поэтому загрузка мира и GPU не запускаются.
extends SceneTree

const Main = preload("res://src/main.gd")

class Feet extends RefCounted:
	var at := Vector3(28.0, 0.0, -10.5)
	func feet() -> Vector3: return at

class Figures extends RefCounted:
	var shown := false
	var ended := 0
	func place(_id: String, _x: float, _y: float, _z: float, _yaw := 0.0) -> void: pass
	func show(_id: String, on: bool) -> void: shown = on
	func show_actor(_id: String, on: bool) -> void: shown = on
	func end_action(_id: String) -> void: ended += 1
	func walk_anim(_id: String, _dt: float, _options: Dictionary) -> void: pass

class Sounds extends RefCounted:
	var stopped: Array[String] = []
	func stop_spatial_owner(id: String) -> void: stopped.append(id)

var errors: Array[String] = []
var checks := 0
var completed := 0
var main := Main.new()
var state := GameState.new()
var feet := Feet.new()
var figures := Figures.new()
var sounds := Sounds.new()
var context: Dictionary = {}
var director: HorrorDirector
var stalker: StreetStalk


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	state.chapter = "village"
	context = {"state": state, "controls": feet, "actors": figures,
		"audio": sounds, "texts": {}, "holdEcho": main._ctx_hold_echo}
	director = HorrorDirector.new(context)
	context["horror"] = director
	stalker = StreetStalk.new(context, 1)
	context["stalk"] = stalker
	main.state = state
	main.player = Player.new()
	main.phone = Phone.new(null, root)
	main.ui = Overlays.new()
	main.horror = director
	main.haunt = Haunt.new(context, figures, null, 1)
	main.stalk = stalker
	main.running = true
	main.ctx = context
	_patrol_dialogue()
	_mandatory_hold()
	_context_visual()
	_threshold_visual()
	_haunt_visual()
	main._cancel_dialogue_runtime()
	director.invalidate()
	context.clear()
	main.player.free()
	main.ui.free()
	main.free()
	for error: String in errors: printerr("FAIL test_dialogue_stalk: ", error)
	print("test_dialogue_stalk: %s — %d checks, shop call, patrol ticks/finish, visual interruption" % ["PASS" if errors.is_empty() else "FAIL", checks])
	quit(0 if errors.is_empty() else 1)


func _patrol_dialogue() -> void:
	stalker.begin(true)
	_check(director.owner == "stalk" and director.hold_left == 600.0,
		"патруль не установил исходный hold")
	_check(main._street_runtime_free(), "патруль заблокирован до разговора")
	var hold_before := director.hold_left
	var haunt_before := main.haunt.global_cd
	var lines: Array = GameData.texts()["CALLS"]["shop"]["lines"]
	_check(not lines.is_empty(), "нет реального разговора по телефону сельпо")
	main._ctx_play_dialogue(lines, func() -> void: completed += 1)
	_check(main.phone.talking and main.player.frozen, "разговор не начался")
	_check(not main._street_runtime_free(), "патруль продолжил ходить во время разговора")
	_check(director.owner == "stalk" and director.hold_left == hold_before,
		"разговор потерял владельца или срок hold патруля")
	_check(main.haunt.global_cd == haunt_before and figures.shown,
		"разговор забрал фигуру патруля или изменил его резерв Haunt")
	_finish_dialogue()
	_check(completed == 1 and not main.player.frozen, "разговор не завершился один раз")
	_check(main._street_runtime_free(), "после разговора осталась блокировка на 600 секунд")
	var before := stalker.pos()
	for _i in 20:
		if main._street_runtime_free(): stalker.update(0.1)
	_check(stalker.pos().distance_to(before) > 0.1, "патруль не пошёл после разговора")
	stalker.finish()
	_check(director.owner == "" and is_zero_approx(director.hold_left),
		"finish после разговора оставил чужой hold")
	_check(main.haunt.global_cd <= HorrorDirector.STRONG_COOLDOWN and not figures.shown,
		"finish после разговора не освободил фигуру/Haunt")


func _mandatory_hold() -> void:
	director.hold(13.0, "mandatory")
	main._ctx_play_dialogue([["note", "Реплика постановочной сцены."]])
	_check(director.owner == "mandatory" and director.hold_left == 13.0,
		"разговор сбросил владельца действующей постановки")
	_finish_dialogue()
	director.invalidate()


func _context_visual() -> void:
	director._live = {"event": {"motion": "pass"}}
	director.owner = "context"
	director.cooldown = HorrorDirector.STRONG_COOLDOWN
	state.horror_seen["dialogue-context"] = true
	figures.shown = true
	var ended_before := figures.ended
	main._ctx_play_dialogue([["note", "Звонок прерывает мелькнувшую фигуру."]])
	_check(director._live.is_empty() and not figures.shown and figures.ended == ended_before + 1,
		"разговор оставил активную фигуру контекстного испуга")
	_check(director.owner == "" and director.cooldown == HorrorDirector.STRONG_COOLDOWN,
		"прерывание context изменило сильный cooldown или оставило владельца")
	_check(state.horror_seen.has("dialogue-context"), "прерванный испуг можно повторить")
	_finish_dialogue()


func _threshold_visual() -> void:
	var threshold: ThresholdScares = director.thresholds
	threshold.live = {"shown": true}
	threshold._actor = figures
	threshold._actor_id = "echo"
	director.owner = "threshold"
	figures.shown = true
	sounds.stopped.clear()
	main._ctx_play_dialogue([["note", "Звонок прерывает фигуру у двери."]])
	_check(not threshold.active() and not figures.shown and director.owner == "",
		"разговор оставил фигуру или владельца threshold")
	_check(sounds.stopped == ["threshold"], "звук прерванного threshold остался играть")
	_check(director.cooldown == HorrorDirector.STRONG_COOLDOWN,
		"прерывание threshold сократило cooldown")
	_finish_dialogue()


func _haunt_visual() -> void:
	main.haunt.point = {"id": "dialogue-haunt"}
	main.haunt.global_cd = 123.0
	figures.shown = true
	main._ctx_play_dialogue([["note", "Звонок прерывает фигуру в окне."]])
	_check(main.haunt.point == null and not figures.shown,
		"разговор оставил действующее появление Haunt")
	_check(main.haunt.global_cd == 123.0, "прерывание Haunt изменило его cooldown")
	_finish_dialogue()


func _finish_dialogue() -> void:
	for _i in 100:
		if not main.phone.talking: break
		main.phone.skipLine()
	_check(not main.phone.talking, "телефон не завершил реплики")


func _check(ok: bool, message: String) -> void:
	checks += 1
	if not ok: errors.append(message)

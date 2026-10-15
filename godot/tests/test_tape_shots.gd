# Приёмка кадров кассет (data/tape_shots.json + tape_player.gd).
#
# Прогоняет скрипт каждой плёнки через ту же логику монтажа, что в игре, и
# печатает карту «реплика → кадр». По ней соответствие картинки разговору
# проверяется глазами, не запуская игру, — а машинно проверяется вот что:
#
#   · у каждой реплики есть кадр (или сцена процедурная, как face-photo);
#   · внутри одной плёнки кадр не повторяется — ради этого всё и делалось;
#   · src каждого кадра существует на диске;
#   · классификация речь/ремарка совпадает с манифестом озвучки: у реплики
#     с ch == "narrator" _is_speech() обязан вернуть false. Это ловит расхождение
#     дубля с gen_voice._is_remark — иначе ремарка молча поедет цветом прямой
#     речи, и игрок будет ждать голос, которого нет;
#   · скримеров (кадров с "flash": true) не больше FLASH_MAX на все плёнки.
#     Правило фазы 13, и оно не вкусовщина: инструмент, которым бьют часто,
#     перестаёт бить, а заметить это можно только пройдя все пять кассет
#     подряд — то есть никогда.
#
# ФАЗА 13. Плёнки берутся из GameData.tapes(), то есть УЖЕ с наложенным
# оверлеем data/tapes_ext.json. Сам оверлей и его окна — предмет
# tests/test_tape_ext.gd; здесь он виден просто как ещё одна кассета.
#
# Оверлея может не быть: тогда визуальный ряд ровно как принят в фазе 4,
# и тест говорит, что пропустил.
#
# Прогон:
#   Godot…_console.exe --headless --path godot --script res://tests/test_tape_shots.gd
extends SceneTree

const OVERLAY := "res://data/tape_shots.json"
const VOICE := "res://audio/voice/voice_manifest.json"

# Потолок скримеров на все пять плёнок (фаза 13). Число не круглое и не
# случайное: по одному на кассету было бы ритмом, а ритм перестаёт пугать
# со второго раза. Четыре на пять — это «не в каждой».
const FLASH_MAX := 4


func _initialize() -> void:
	var f := FileAccess.open(OVERLAY, FileAccess.READ)
	if f == null:
		print("SKIP test_tape_shots: нет ", OVERLAY, " — кадры как в фазе 4")
		quit(0)
		return
	var ov: Dictionary = JSON.parse_string(f.get_as_text())
	var shots: Dictionary = (GameData.shots()["SHOTS"] as Dictionary).duplicate()
	for id in (ov.get("SHOTS", {}) as Dictionary):
		shots[String(id)] = (ov["SHOTS"] as Dictionary)[id]
	var reels: Dictionary = ov.get("TAPE_SCENE_SHOTS", {})
	var act_shots: Dictionary = ov.get("ACT_SHOTS", {})

	var errs: Array[String] = []
	var narrator := _narrator_lines()
	var tapes: Dictionary = GameData.tapes()["TAPES"]
	var frames := 0

	for id: Variant in (GameData.tapes()["TAPE_ORDER"] as Array):
		var tid := String(id)
		var tape: Dictionary = tapes[tid]
		print("\n=== кассета %s · %s" % [tid, String(tape.get("label", ""))])
		frames += _walk(tid, tape, reels, act_shots, shots, narrator, errs)

	# Каждый кадр оверлея должен лежать на диске: пустой src — это чёрный
	# прямоугольник в самый нужный момент плёнки.
	var flashes: Array[String] = []
	for id in (ov.get("SHOTS", {}) as Dictionary):
		var def: Dictionary = shots[String(id)]
		var src := String(def.get("src", ""))
		if src == "" or not FileAccess.file_exists("res://" + src):
			errs.append("%s: файла %s нет на диске" % [String(id), src])
		if bool(def.get("flash", false)):
			flashes.append(String(id))
	if flashes.size() > FLASH_MAX:
		errs.append("скримеров %d при потолке %d: %s — инструмент, которым бьют "
			% [flashes.size(), FLASH_MAX, ", ".join(flashes)] + "часто, перестаёт бить")

	if errs.is_empty():
		print("\nPASS test_tape_shots: кадров в оверлее %d, реплик с кадром %d, "
			% [(ov.get("SHOTS", {}) as Dictionary).size(), frames]
			+ "скримеров %d из %d" % [flashes.size(), FLASH_MAX])
		quit(0)
		return
	print("\nFAIL test_tape_shots: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


## Один проход по скрипту кассеты той же логикой, что в tape_player:
## scene ставит плёнку и её позицию, sub/end двигают на кадр, act держит свой.
func _walk(tid: String, tape: Dictionary, reels: Dictionary, act_shots: Dictionary,
		shots: Dictionary, narrator: Dictionary, errs: Array[String]) -> int:
	var scene := "dark"
	var at: Dictionary = {}          # сцена -> позиция плёнки
	var fresh := false
	var act_until := -1.0
	var act_frame := ""
	var used: Dictionary = {}        # кадр -> реплика, на которой он уже был
	var n := 0

	for row: Array in (tape.get("script", []) as Array):
		var t := float(row[0])
		var kind := String(row[1])
		var payload: Variant = row[2] if row.size() > 2 else null
		match kind:
			"scene":
				scene = String(payload)
				act_until = -1.0
				act_frame = ""
				fresh = reels.has(tid + ":" + scene) and not at.has(scene)
			"act":
				var p: Array = payload
				var key := scene + ":" + String(p[0])
				if act_shots.has(key):
					act_frame = String(act_shots[key])
					act_until = t + float(p[3])
					print("   act  %5.1f  %-14s %s" % [t, String(p[0]), act_frame])
			"sub", "end":
				var text := String(payload)
				var reel: Array = reels.get(tid + ":" + scene, [])
				var frame := ""
				if t < act_until:
					frame = act_frame
				elif reel.is_empty():
					frame = "(процедурная сцена)"
				else:
					var i := int(at.get(scene, 0))
					if fresh:
						fresh = false
					elif i + 1 < reel.size():
						i += 1
					at[scene] = i
					frame = String(reel[i])
					if not shots.has(frame):
						errs.append("%s/%s: кадра «%s» нет в SHOTS" % [tid, scene, frame])
					if used.has(frame):
						errs.append("%s: кадр «%s» дважды за плёнку (реплики «%s» и «%s»)"
							% [tid, frame, String(used[frame]).substr(0, 28),
								text.substr(0, 28)])
					used[frame] = text
					n += 1
				# Речь или ремарка — и совпадает ли это с манифестом озвучки.
				var speech := TapePlayer._is_speech(text)
				if text != "" and narrator.has(text) and speech:
					errs.append("%s: «%s» озвучена нарратором, а _is_speech() "
						% [tid, text.substr(0, 34)] + "считает её прямой речью")
				print("   %-4s %5.1f  %-14s %s%s"
					% [kind, t, frame, "— " if speech else "· ", text.substr(0, 46)])
			"shot":
				if not reels.has(tid + ":" + scene):
					print("   shot %5.1f  %s" % [t, String(payload)])
	return n


## Тексты, которые в манифесте озвучки идут каналом нарратора. Манифеста может
## не быть — тогда сверять не с чем, и проверка тихо пропускается.
func _narrator_lines() -> Dictionary:
	var out: Dictionary = {}
	var f := FileAccess.open(VOICE, FileAccess.READ)
	if f == null:
		return out
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return out
	var lines: Variant = (parsed as Dictionary).get("lines", {})
	if not (lines is Dictionary):
		return out
	for key in (lines as Dictionary):
		var row: Variant = (lines as Dictionary)[key]
		if not (row is Dictionary):
			continue
		var d: Dictionary = row
		if String(d.get("ch", d.get("who", ""))) == "narrator":
			out[String(d.get("text", ""))] = true
	return out

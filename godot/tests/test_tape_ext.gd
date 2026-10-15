# Оверлей кассет: data/tapes_ext.json ↔ GameData.tapes() ↔ окна озвучки.
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ТЕСТ. data/tapes.json заморожен: тексты его реплик держат
# sha1 файлов озвучки, времена событий держат окна tape_windows. Новая плёнка
# приходит оверлеем, и у этого способа есть ровно три тихие поломки, каждая
# из которых в игре выглядит не как ошибка, а как «так и было».
#
# 1. ОВЕРЛЕЙ НЕ ДОЕХАЛ. GameData.tapes() кэширует слитый словарь; ошибись
#    в слиянии — и меню кассет покажет старую плёнку 2, а игрок посмотрит
#    её и не поймёт, почему в задании сад, а на плёнке собака.
# 2. ЗАМЕНА ВМЕСТО СЛИЯНИЯ. Оверлей обязан заменять кассету ЦЕЛИКОМ и не
#    трогать остальные четыре. Слияние по полю дало бы плёнку из нового
#    label и старого script — то есть тихую кашу.
# 3. ОКНА РАЗЪЕХАЛИСЬ. tools/gen_voice.py считает окно реплики от следующего
#    события sub/end, а плеер режет субтитр ровно там же. Читай генератор
#    только tapes.json — реплики новой плёнки остались бы вовсе без окон,
#    и первая же длинная оборвалась бы на смене кадра. Здесь окно
#    пересчитывается ТОЙ ЖЕ формулой и сверяется с манифестом.
#
# Файла может не быть: тогда плёнки ровно те, что приняты в фазе 8, и тест
# говорит, что пропустил.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_tape_ext.gd
extends SceneTree

const EXT := "res://data/tapes_ext.json"
const BASE := "res://data/tapes.json"
const OVERLAY := "res://data/tape_shots.json"
const MANIFEST := "res://audio/voice/voice_manifest.json"

# Тот же зазор, что в gen_voice._window(): реплика, кончающаяся ровно в момент
# смены субтитра, слышится обрубленной даже когда формально уложилась.
const GAP := 0.15


func _initialize() -> void:
	var ext := _json(EXT)
	if ext.is_empty():
		print("SKIP test_tape_ext: нет ", EXT, " — плёнки как в фазе 8")
		quit(0)
		return

	var errs: Array[String] = []
	var base := _json(BASE)
	var merged: Dictionary = GameData.tapes()
	var base_tapes: Dictionary = base.get("TAPES", {})
	var ext_tapes: Dictionary = ext.get("TAPES", {})
	var got: Dictionary = merged.get("TAPES", {})

	if ext_tapes.is_empty():
		errs.append("в оверлее нет ни одной кассеты — файл есть, а смысла нет")

	# 1. Оверлей доехал, и доехал ЦЕЛИКОМ.
	for id: Variant in ext_tapes:
		var tid := String(id)
		if not got.has(tid):
			errs.append("кассеты «%s» нет в GameData.tapes() — оверлей не слился" % tid)
			continue
		var want: Dictionary = ext_tapes[tid]
		var have: Dictionary = got[tid]
		for key: Variant in want:
			if String(key).begins_with("_"):
				continue
			if JSON.stringify(have.get(key)) != JSON.stringify(want[key]):
				errs.append("кассета %s: поле «%s» не то, что в оверлее" % [tid, String(key)])
		# Замена, а не слияние: ни одного поля старой плёнки не осталось.
		if base_tapes.has(tid):
			for key: Variant in (base_tapes[tid] as Dictionary):
				if String(key).begins_with("_") or want.has(key):
					continue
				if have.has(key):
					errs.append("кассета %s: поле «%s» осталось от старой плёнки — "
						% [tid, String(key)] + "оверлей слился по полю, а не целиком")

	# 2. Остальные кассеты не тронуты ни на знак.
	for id: Variant in base_tapes:
		var tid2 := String(id)
		if ext_tapes.has(tid2):
			continue
		if JSON.stringify(got.get(tid2)) != JSON.stringify(base_tapes[tid2]):
			errs.append("кассета %s изменилась, хотя оверлей её не трогает" % tid2)
	for id: Variant in (merged.get("TAPE_ORDER", []) as Array):
		if not got.has(String(id)):
			errs.append("в TAPE_ORDER есть «%s», а самой кассеты нет" % String(id))

	# 3. У каждой сцены новой плёнки своя плёнка кадров, и её хватает
	#    на все реплики этой сцены.
	var reels: Dictionary = _json(OVERLAY).get("TAPE_SCENE_SHOTS", {})
	for id: Variant in ext_tapes:
		errs.append_array(_reels(String(id), got[String(id)], reels))

	# 4. Окна: пересчитываем формулой gen_voice и сверяем с манифестом.
	errs.append_array(_windows(ext_tapes, got))

	if errs.is_empty():
		print("PASS test_tape_ext: кассет в оверлее %d, всего плёнок %d"
			% [ext_tapes.size(), got.size()])
		quit(0)
		return
	print("FAIL test_tape_ext: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


## Кадров на сцену хватает на все её реплики. Считаем тем же проходом, что
## tape_player: scene ставит плёнку, sub/end двигают её на кадр.
func _reels(tid: String, tape: Dictionary, reels: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var scene := "dark"
	var need: Dictionary = {}
	for row: Array in (tape.get("script", []) as Array):
		var kind := String(row[1])
		if kind == "scene":
			scene = String(row[2])
		elif kind == "sub" or kind == "end":
			need[scene] = int(need.get(scene, 0)) + 1
	for sc: Variant in need:
		var key := tid + ":" + String(sc)
		var reel: Variant = reels.get(key, null)
		if not (reel is Array):
			out.append("сцена «%s» без плёнки кадров — реплики пойдут по процедурной"
				% key)
			continue
		if (reel as Array).size() < int(need[sc]):
			out.append("сцена «%s»: кадров %d на %d реплик — последние повторятся"
				% [key, (reel as Array).size(), int(need[sc])])
	return out


## Окно каждой озвученной реплики новой плёнки сходится с манифестом.
##
## Формула ровно та же, что в tools/gen_voice._window(): границей считается
## следующий sub/end, а не любое событие, потому что scene и shot меняют
## ракурс и субтитр не трогают.
func _windows(ext_tapes: Dictionary, got: Dictionary) -> Array[String]:
	var out: Array[String] = []
	var m := _json(MANIFEST)
	if m.is_empty():
		print("test_tape_ext: манифеста озвучки нет — окна сверять не с чем")
		return out
	var lines: Dictionary = m.get("lines", {})
	var windows: Dictionary = m.get("tape_windows", {})

	for id: Variant in ext_tapes:
		var tid := String(id)
		var tape: Dictionary = got[tid]
		var events: Array = tape.get("script", [])
		var dur := float(tape.get("duration", 0.0))
		var per: Dictionary = windows.get(tid, {})
		var seen := 0
		for i in events.size():
			var ev: Array = events[i]
			var kind := String(ev[1])
			if kind != "sub" and kind != "end":
				continue
			var text := String(ev[2])
			var key := GameVoice.line_key("tape:" + tid, text)
			if not lines.has(key):
				continue          # ремарка без голоса — так и задумано
			seen += 1
			var want := _window_of(events, i, float(ev[0]), dur, kind)
			if not per.has(key):
				out.append("кассета %s: реплика «%s» озвучена, а окна у неё нет"
					% [tid, text.substr(0, 30)])
				continue
			if absf(float(per[key]) - want) > 0.01:
				out.append("кассета %s: окно «%s» в манифесте %.2f, а по раскадровке %.2f"
					% [tid, text.substr(0, 26), float(per[key]), want])
			var got_s := float((lines[key] as Dictionary).get("s", 0.0))
			if got_s > want + 0.001:
				out.append("кассета %s: реплика %.2f с не влезает в окно %.2f с — «%s»"
					% [tid, got_s, want, text.substr(0, 30)])
		if seen == 0:
			out.append("кассета %s: ни одной озвученной реплики — плёнка немая" % tid)
	return out


static func _window_of(events: Array, i: int, t0: float, dur: float,
		kind: String) -> float:
	if kind == "end":
		return maxf(1.0, dur + 3.0 - t0 - GAP)
	for j in range(i + 1, events.size()):
		var e: Array = events[j]
		var k := String(e[1])
		if k != "sub" and k != "end":
			continue
		var nxt := float(e[0])
		if nxt > t0:
			return maxf(0.4, nxt - t0 - GAP)
	return maxf(1.0, dur - t0 - GAP)


func _json(path: String) -> Dictionary:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	return parsed if parsed is Dictionary else {}

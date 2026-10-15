# Приёмка озвучки: godot/audio/voice/voice_manifest.json ↔ реплики игры.
#
# Самая ценная проверка здесь — окна кассет. Время событий плёнки жёстко связано
# с картинкой: реплика длиннее окна оборвётся ровно на смене субтитра, и увидеть
# это можно только при полном просмотре пяти лент подряд. Всё остальное —
# проверки того же рода: ошибка не роняет игру, она просто делает её тише
# или беззвучнее в одном месте, и вылезает через час прохождения.
#
# Озвучки может не быть: папку удалили или "enabled": false. Это штатная
# конфигурация — тест проходит и говорит, что пропустил.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_voice_manifest.gd
extends SceneTree

const VOICE := "res://audio/voice/"
const MANIFEST := VOICE + "voice_manifest.json"

# Длина файла против манифеста, и допуск здесь НЕСИММЕТРИЧНЫЙ.
#
# Короче манифеста файл быть не может вовсе: это обрезка, и реплика замолчит
# на полуслове, а субтитр досидит своё. Полсотни миллисекунд — предел, за
# которым пауза в phone.gd начинает наезжать на следующую строку.
#
# Длиннее — может, и это не дефект. Godot отдаёт длину Ogg по границе страницы
# потока, а не по последнему сэмплу: замерено 15 файлов из 112, все длиннее трёх
# секунд, расхождение до 0.089 с и всегда в плюс. Ловить этим тестом кодировщик
# незачем — тем более что окна кассет ниже сверяются по РЕАЛЬНОЙ длине потока,
# и там разница уже учтена.
const LEN_SHORT_EPS := 0.05
const LEN_PAGE_EPS := 0.12

# Правило темпа chapters.gd: до 23:40 (главы dark) ни одного акцента — значит
# и ни одного слова деда. Реплику разрешено звать только отсюда.
const VITYA_OK_PREFIX := ["_dark", "_gate", "_village"]

# Файлы, где голос деда вообще разрешено звать. Фаза 12 вынесла часть сцен
# в village_quest.gd — если бы список остался из одного chapters.gd, правило
# темпа перестало бы что-либо охранять ровно в новой главе.
#
# ФАЗА 13 добавляет третий: задания участка (клопы, баня) живут в interact.gd,
# и без него сторож снова перестал бы что-либо охранять ровно там, где
# появилось новое. Функция-обёртка там называется _dark_say_vitya и, кроме
# правильного имени, сверяет главу на рантайме: наврать самому себе именем
# функции нельзя.
# ФАЗА 14 добавляет четвёртый: outskirts_quest.gd (околица, полив) — своя
# обёртка _village_line по тому же образцу.
const VITYA_SRC := ["res://src/chapters.gd", "res://src/village_quest.gd",
	"res://src/interact.gd", "res://src/outskirts_quest.gd"]

# Реплики, для которых записи нет НАМЕРЕННО. Пусто — значит озвучено всё.
const SKIP := {}


func _initialize() -> void:
	var f := FileAccess.open(MANIFEST, FileAccess.READ)
	if f == null:
		print("SKIP test_voice_manifest: озвучки нет — игра идёт субтитрами")
		quit(0)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		print("FAIL: voice_manifest.json не разобран как объект")
		quit(1)
		return
	var m: Dictionary = parsed
	if not bool(m.get("enabled", true)):
		print("SKIP test_voice_manifest: озвучка выключена флагом enabled")
		quit(0)
		return

	var errs: Array[String] = []
	var lines: Dictionary = m.get("lines", {})
	var sets: Dictionary = m.get("sets", {})
	var windows: Dictionary = m.get("tape_windows", {})
	# Реальная длина потока по ключу — её и сверяем с окнами кассет: в кадр
	# попадает то, что играет, а не то, что записано в манифесте.
	var real: Dictionary = {}

	if lines.is_empty():
		errs.append("в манифесте ни одной реплики")

	# 1. Файл на месте, грузится, и его длина совпадает с манифестом.
	for key in lines:
		var e: Dictionary = lines[key]
		var rel := String(e.get("f", ""))
		var path := VOICE + rel
		if rel == "":
			errs.append(String(key) + ": нет имени файла")
			continue
		if not FileAccess.file_exists(path):
			errs.append("нет файла: " + rel)
			continue
		if not ResourceLoader.exists(path):
			errs.append(rel + " не импортирован — прогнать --headless --import")
			continue
		var s := ResourceLoader.load(path) as AudioStream
		if s == null:
			errs.append(rel + " грузится не как AudioStream")
			continue
		var want := float(e.get("s", -1.0))
		var got := s.get_length()
		real[key] = got
		if want <= 0.0:
			errs.append(rel + ": в манифесте нет длительности")
		elif want - got > LEN_SHORT_EPS:
			errs.append("%s: в манифесте %.3f с, а в файле всего %.3f — обрезан"
				% [rel, want, got])
		elif got - want > LEN_PAGE_EPS:
			errs.append("%s: в файле %.3f с при %.3f в манифесте — это уже не "
				% [rel, got, want] + "граница страницы Ogg, а другой файл")

		# Реплика на петле — это заедающая пластинка. Импорт обязан быть без неё.
		var imp := path + ".import"
		if FileAccess.file_exists(imp):
			var txt := FileAccess.open(imp, FileAccess.READ).get_as_text()
			if txt.find("loop=true") >= 0:
				errs.append(rel + " импортирован с loop=true")

		# 2. Ключ считается ТЕМИ ЖЕ двумя функциями, что и в генераторе.
		# Разойдись они на один пробел — манифест перестанет находиться целиком,
		# и вся озвучка молча замолчит.
		var recomputed := GameVoice.line_key(String(e.get("w", "")), String(e.get("t", "")))
		if recomputed != String(key):
			errs.append("ключ %s не сходится с sha1(%s|%s) = %s — norm_text в "
				% [key, e.get("w", ""), String(e.get("t", "")).substr(0, 24), recomputed]
				+ "voice.gd и el_common.py разъехались")

	# 3. ОКНА КАССЕТ. Реплика обязана уложиться до следующего субтитра.
	# Меряем по загруженному потоку, а не по числу в манифесте: на смену кадра
	# наезжает то, что звучит, и разница между ними доходит до 0.09 с.
	for tape_id in windows:
		var per: Dictionary = windows[tape_id]
		for key in per:
			if not lines.has(key):
				errs.append("кассета %s: окно на ключ %s, которого нет в манифесте"
					% [tape_id, key])
				continue
			var got := float(real.get(key, (lines[key] as Dictionary).get("s", 0.0)))
			var win := float(per[key])
			if got > win + 0.001:
				errs.append("кассета %s: реплика %.2f с не влезает в окно %.2f с — «%s»"
					% [tape_id, got, win,
					String((lines[key] as Dictionary).get("t", "")).substr(0, 40)])

	# 4. Каждая реплика игры либо озвучена, либо стоит в SKIP с причиной.
	# С фазы 6 сюда входят и реплики Сергея в звонках (who == "me").
	# Пробная партия неполна по определению — с неё полноты не требуем,
	# но всё остальное (длины, окна, ключи) сверяем и на ней.
	var trial := bool(m.get("trial", false))
	if trial:
		print("test_voice_manifest: манифест помечен как пробная партия — "
			+ "полнота не проверяется")
	else:
		var texts := GameData.texts()
		for call_id in (texts.get("CALLS", {}) as Dictionary):
			var call: Dictionary = (texts["CALLS"] as Dictionary)[call_id]
			for row: Array in call.get("lines", []):
				# Обе стороны разговора, а не только трубка: с фазы 6 Сергей
				# в звонках звучит голосом, и пропущенная его реплика выглядит
				# ровно как раньше — субтитр поверх бубнежа, то есть незаметно.
				var who := String(row[0])
				if who != "them" and who != "me":
					continue
				_need(lines, who, String(row[1]), "звонок " + String(call_id), errs)
		for line in (texts.get("THREAT_LINES", []) as Array):
			_need(lines, "vitya", String(line), "THREAT_LINES", errs)
		_need(lines, "vitya", String(texts.get("THREAT_AT_GATE", "")),
			"THREAT_AT_GATE", errs)
		# Валя живёт вне CALLS, поэтому прежняя проверка полноты не замечала,
		# если одна из её сюжетных реплик исчезала из manifest. Проверяем только
		# её строки: ответы Сергея принадлежат голосу sergey и не должны попасть
		# под точечную переозвучку бабки.
		for dialogue_id in (texts.get("VALYA_DIALOGUES", {}) as Dictionary):
			var rows: Array = (texts["VALYA_DIALOGUES"] as Dictionary)[dialogue_id]
			for row: Array in rows:
				if String(row[0]) != "valya":
					continue
				var spoken := String(row[1])
				_need(lines, "valya", spoken, "Валя " + String(dialogue_id), errs)
				var key := GameVoice.line_key("valya", spoken)
				if not lines.has(key):
					continue
				var entry: Dictionary = lines[key]
				if String(entry.get("v", "")) != "valya":
					errs.append("Валя %s: ключ %s записан голосом %s"
						% [dialogue_id, key, entry.get("v", "")])
				if String(entry.get("ch", "")) != "neighbour":
					errs.append("Валя %s: ключ %s попал в канал %s вместо neighbour"
						% [dialogue_id, key, entry.get("ch", "")])

	# 5. Ни одного слова деда раньше главы ТЕМНОТА. Машинная проверка правила
	# «до 23:40 ни одного акцента»: смотрим, из каких функций глав вообще
	# зовётся голос.
	errs.append_array(_check_vitya_timing())

	# 6. Наборы ссылаются на существующие ключи.
	for set_name in sets:
		for key in (sets[set_name] as Array):
			if not lines.has(key):
				errs.append("набор %s ссылается на пропавший ключ %s"
					% [String(set_name), String(key)])

	if errs.is_empty():
		print("PASS test_voice_manifest: реплик %d, наборов %d, кассет с окнами %d"
			% [lines.size(), sets.size(), windows.size()])
		quit(0)
		return

	print("FAIL test_voice_manifest: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


func _need(lines: Dictionary, who: String, text: String, where: String,
		errs: Array[String]) -> void:
	if text.strip_edges() == "":
		return
	var key := GameVoice.line_key(who, text)
	if lines.has(key) or SKIP.has(key):
		return
	errs.append("%s: реплика без записи и без причины в SKIP — «%s»"
		% [where, text.substr(0, 46)])


# Читаем исходник глав как текст: единственный способ поймать «дед заговорил
# в главе МАНСАРДА» раньше, чем это услышит игрок.
func _check_vitya_timing() -> Array[String]:
	var errs: Array[String] = []
	for path in VITYA_SRC:
		var f := FileAccess.open(String(path), FileAccess.READ)
		if f == null:
			errs.append("нет %s — проверить темп нечем" % path)
			continue
		var fn := ""
		for raw in f.get_as_text().split("\n"):
			var line := String(raw)
			# И `func`, и `static func`: до фазы 13 сторож знал только первый,
			# а задания участка живут в interact.gd, где ВСЁ статическое.
			# Сторож, не видящий половину синтаксиса, охраняет ровно ту
			# половину, в которую никто не пишет.
			if line.begins_with("func "):
				fn = line.substr(5, maxi(0, line.find("(") - 5))
			elif line.begins_with("static func "):
				fn = line.substr(12, maxi(0, line.find("(") - 12))
			# Комментарий, в котором упомянут say_vitya, — это комментарий,
			# а не вызов. Без этой строки правило ловит собственную документацию.
			if line.strip_edges().begins_with("#"):
				continue
			if line.find("say_vitya") < 0:
				continue
			var ok := false
			for p in VITYA_OK_PREFIX:
				if fn.begins_with(String(p)):
					ok = true
					break
			if not ok:
				errs.append("голос деда зовётся из %s() — до главы ТЕМНОТА он "
					% fn + "существует только следами")
	return errs

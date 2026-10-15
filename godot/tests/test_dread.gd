# Приёмка хоррор-слоя: таблица dread.gd ↔ звуки, которые в игре реально есть.
#
# Ловит ровно одну ошибку, зато ту, которую иначе замечают через час игры:
# имя в таблице разошлось с именем в генераторе. Событие при этом не падает
# и не ругается — audio.sfx() возвращает false, dread идёт дальше, и «редкий
# страшный звук» просто никогда не звучит. Отличить это от «просто не выпало»
# на слух нельзя вовсе: событий и должно быть семь-десять за ночь.
#
# Заодно проверяются три тембра скримера (scare.gd::STINGERS) — та же болезнь
# и то же молчаливое падение на запечённый.
#
# Оверлея может не быть: папку godot/audio/sfx/ удалили или "enabled": false.
# Это штатная конфигурация — игра звучит запечённым, dread молчит целиком,
# и тест говорит, что пропустил.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_dread.gd
extends SceneTree

const BAKED := "res://audio/baked/manifest.json"
const OVERRIDE := "res://audio/sfx/sfx_override.json"

# Что вообще бывает в поле where. Опечатка здесь означает событие, которое
# никогда не пройдёт отбор, — и снова тихо.
const WHERE_OK := ["yard", "house", "close"]


func _initialize() -> void:
	var errs: Array[String] = []
	var known := {}

	var bf := FileAccess.open(BAKED, FileAccess.READ)
	if bf == null:
		print("FAIL: нет ", BAKED, " — прогнать py tools/bake_audio.py")
		quit(1)
		return
	var bm: Dictionary = JSON.parse_string(bf.get_as_text())
	for name in (bm.get("one_shots", {}) as Dictionary):
		known[String(name)] = "запечённый"

	var of := FileAccess.open(OVERRIDE, FileAccess.READ)
	if of == null:
		print("SKIP test_dread: оверлея нет — хоррор-слой молчит, это штатно")
		quit(0)
		return
	var parsed: Variant = JSON.parse_string(of.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		print("FAIL: sfx_override.json не разобран как объект")
		quit(1)
		return
	var d: Dictionary = parsed
	if not bool(d.get("enabled", true)):
		print("SKIP test_dread: оверлей выключен флагом enabled")
		quit(0)
		return
	for name in (d.get("extra", {}) as Dictionary):
		known[String(name)] = "оверлей"

	# 1. Каждое имя таблицы существует, и существует как one-shot: луп через
	# audio.sfx() не проигрывается вовсе — он уходит в loop() и остаётся висеть.
	var seen := {}
	var levels := _zone_levels()
	for e: Dictionary in GameDread.EVENTS:
		var id := String(e.get("id", ""))
		if id == "":
			errs.append("в таблице есть событие без id")
			continue
		if seen.has(id):
			errs.append("имя %s в таблице дважды" % id)
		seen[id] = true
		if not known.has(id):
			errs.append("%s: имени нет ни в оверлее, ни в запечённом — событие "
				% id + "молча никогда не прозвучит")
		if not WHERE_OK.has(String(e.get("where", ""))):
			errs.append("%s: where = «%s», а бывает только %s"
				% [id, e.get("where", ""), ", ".join(WHERE_OK)])
		if int(e.get("w", 0)) <= 0:
			errs.append("%s: вес %d — событие не выпадет никогда"
				% [id, int(e.get("w", 0))])
		if float(e.get("cd", 0.0)) <= 0.0 and not bool(e.get("once", false)):
			errs.append("%s: ни своего кулдауна, ни «один раз за прохождение» — "
				% id + "событие пойдёт подряд, как только отпустит глобальный")
		var lvl := String(e.get("not_level", ""))
		if lvl != "" and not levels.has(lvl):
			errs.append("%s: not_level «%s» — такого уровня нет в site.json ZONES"
				% [id, lvl])
		# Фаза 8: у события своя глава вместо общего гейта «только с ТЕМНОТЫ».
		# Опечатка в имени главы означала бы событие, которое либо доступно
		# с пролога, либо не доступно никогда, — и то и другое молча.
		var mn := String(e.get("min", ""))
		if mn == "":
			errs.append("%s: нет поля min — с какой главы событие доступно" % id)
		elif not GameState.CHAPTERS.has(mn):
			errs.append("%s: min = «%s», а глав всего %s"
				% [id, mn, ", ".join(GameState.CHAPTERS)])
		elif mn == "prologue":
			errs.append("%s: min = prologue — в кабинете следователя дачных "
				% id + "звуков быть не может")
		var inten := int(e.get("i", 0))
		if inten < 1 or inten > 3:
			errs.append("%s: интенсивность %d, а окна в tension.gd есть только "
				% [id, inten] + "для 1, 2 и 3")
		# Правило темпа «до 23:40 ни одного акцента» — машинно, а не на слово.
		if inten >= 3 and GameState.CHAPTERS.find(mn) < GameState.CHAPTERS.find("dark"):
			errs.append("%s: акцент (i=3) доступен с главы «%s» — правило "
				% [id, mn] + "«до 23:40 ни одного акцента» сломано")

	# 1б. Бюджеты по главам: у каждой главы своя вилка, и она осмысленна.
	var total_min := 0
	var total_max := 0
	for ch: String in GameState.CHAPTERS:
		if not GameDread.BUDGET.has(ch):
			errs.append("бюджета на главу «%s» нет — она пойдёт по запасной вилке" % ch)
			continue
		var b: Array = GameDread.BUDGET[ch]
		if int(b[0]) > int(b[1]):
			errs.append("бюджет главы «%s»: %d..%d, нижняя граница выше верхней"
				% [ch, int(b[0]), int(b[1])])
		total_min += int(b[0])
		total_max += int(b[1])
	if total_max < 12:
		errs.append("суммарный бюджет за прохождение %d..%d — модуль снова "
			% [total_min, total_max] + "почти не слышен")

	# 1в. В каждой главе, начиная с той, где модуль работает, должно быть
	# ЧТО играть: бюджет без доступных событий — это тишина с видом бюджета.
	for ch: String in GameState.CHAPTERS:
		var b: Array = GameDread.BUDGET.get(ch, [0, 0])
		if int(b[1]) <= 0:
			continue
		var n := 0
		for e: Dictionary in GameDread.EVENTS:
			if GameState.CHAPTERS.find(String(e.get("min", "dark"))) \
					<= GameState.CHAPTERS.find(ch):
				n += 1
		if n < int(b[1]):
			errs.append("глава «%s»: бюджет до %d событий, а доступно всего %d"
				% [ch, int(b[1]), n])

	# 2. Три тембра скримера. Первый обязан быть запечённым: на сборке без
	# оверлея скример уходит на него, и другого запасного у него нет.
	for i in Scare.STINGERS.size():
		var name := String(Scare.STINGERS[i])
		if not known.has(name):
			errs.append("скример: тембра %s нет ни в оверлее, ни в запечённом" % name)
		elif i == 0 and String(known[name]) != "запечённый":
			errs.append("скример: первый тембр %s не запечённый — на сборке без "
				% name + "оверлея удара не будет вовсе")

	if errs.is_empty():
		var per := PackedStringArray()
		for ch: String in GameState.CHAPTERS:
			var b: Array = GameDread.BUDGET.get(ch, [0, 0])
			if int(b[1]) > 0:
				per.append("%s %d-%d" % [ch, int(b[0]), int(b[1])])
		print("PASS test_dread: событий %d, тембров скримера %d, бюджет %d..%d за "
			% [GameDread.EVENTS.size(), Scare.STINGERS.size(), total_min, total_max]
			+ "прохождение (" + ", ".join(per) + ")")
		quit(0)
		return

	print("FAIL test_dread: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# Уровни зон из site.json — по ним dread решает, слышно ли снизу вверх.
func _zone_levels() -> Dictionary:
	var out := {}
	for z: Dictionary in (GameData.site()["ZONES"] as Array):
		out[String(z.get("level", ""))] = true
	return out

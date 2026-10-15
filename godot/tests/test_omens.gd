# Приёмка знаков (omens.gd + data/omens.json).
#
# Ловит ту же болезнь, что test_dread, только злее: знак, который не случится
# никогда, отличить в игре нельзя вовсе — четыре из четырнадцати вообще без
# звука, и «не сработал» выглядит ровно как «я не оглянулся». Поэтому машинно:
#
#   · id из файла существует в коде (иначе строка молча выброшена при загрузке);
#   · каждый id кода покрыт строкой файла — знак без расписания мёртв;
#   · min — реальная глава, и не пролог;
#   · интенсивность 1..3 (окна шкалы напряжения), вес > 0, кулдаун либо свой,
#     либо once — иначе знак пойдёт подряд, как только отпустит глобальный;
#   · правило темпа то же, что у dread: акцент (i = 3) не раньше «ТЕМНОТЫ»;
#   · бюджет каждой главы осмыслен, и в главе есть что играть;
#   · два предмета знака 13 идут без коллайдера — иначе поедет паритет 83.
#
# Файла может не быть или enabled = false: это штатная конфигурация отката,
# и тест говорит, что пропустил.
#
# Прогон:
#   Godot…_console.exe --headless --path godot --script res://tests/test_omens.gd
extends SceneTree


func _initialize() -> void:
	var f := FileAccess.open(Omens.FILE, FileAccess.READ)
	if f == null:
		print("SKIP test_omens: нет ", Omens.FILE, " — знаков нет, это штатно")
		quit(0)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		print("FAIL test_omens: omens.json не разобран как объект")
		quit(1)
		return
	var d: Dictionary = parsed
	if not bool(d.get("enabled", true)):
		print("SKIP test_omens: знаки выключены флагом enabled")
		quit(0)
		return

	var errs: Array[String] = []
	var seen := {}
	var rows: Array = d.get("events", [])
	for row: Variant in rows:
		if not (row is Dictionary):
			errs.append("в events есть строка, которая не объект")
			continue
		var e: Dictionary = row
		var id := String(e.get("id", ""))
		if not Omens.IDS.has(id):
			errs.append("«%s»: такого знака нет в omens.gd — строка будет "
				% id + "выброшена при загрузке")
			continue
		if seen.has(id):
			errs.append("%s: строка встречается дважды" % id)
		seen[id] = true

		var mn := String(e.get("min", ""))
		if not GameState.CHAPTERS.has(mn):
			errs.append("%s: min = «%s», а глав всего %s"
				% [id, mn, ", ".join(GameState.CHAPTERS)])
		elif mn == "prologue":
			errs.append("%s: min = prologue — в кабинете следователя дачных "
				% id + "знаков быть не может")

		var i := int(e.get("i", 0))
		if i < 1 or i > 3:
			errs.append("%s: интенсивность %d, а окна в tension.gd есть только "
				% [id, i] + "для 1, 2 и 3")
		elif i >= 3 and GameState.CHAPTERS.has(mn) \
				and GameState.CHAPTERS.find(mn) < GameState.CHAPTERS.find("dark"):
			errs.append("%s: акцент (i=3) доступен с главы «%s» — правило "
				% [id, mn] + "«до 23:40 ни одного акцента» сломано")

		if int(e.get("w", 0)) <= 0:
			errs.append("%s: вес %d — знак не выпадет никогда" % [id, int(e.get("w", 0))])
		if float(e.get("cd", 0.0)) <= 0.0 and not bool(e.get("once", false)):
			errs.append("%s: ни своего кулдауна, ни «один раз за прохождение»" % id)

	for id: String in Omens.IDS:
		if not seen.has(id):
			errs.append("%s: знак написан в коде, но расписания у него нет — "
				% id + "он не случится никогда")

	# Бюджеты: у каждой главы своя вилка, и на неё хватает доступных знаков.
	var total_min := 0
	var total_max := 0
	for ch: String in GameState.CHAPTERS:
		if not Omens.BUDGET.has(ch):
			errs.append("бюджета на главу «%s» нет" % ch)
			continue
		var b: Array = Omens.BUDGET[ch]
		if int(b[0]) > int(b[1]):
			errs.append("бюджет главы «%s»: %d..%d, нижняя граница выше верхней"
				% [ch, int(b[0]), int(b[1])])
		total_min += int(b[0])
		total_max += int(b[1])
		if int(b[1]) <= 0:
			continue
		var n := 0
		for row2: Variant in rows:
			if not (row2 is Dictionary):
				continue
			var mn2 := String((row2 as Dictionary).get("min", "dark"))
			if GameState.CHAPTERS.has(mn2) \
					and GameState.CHAPTERS.find(mn2) <= GameState.CHAPTERS.find(ch):
				n += 1
		if n < int(b[1]):
			errs.append("глава «%s»: бюджет до %d знаков, а доступно всего %d"
				% [ch, int(b[1]), n])

	# Предметы знака «банка переехала»: без коллайдера, иначе поедет паритет.
	var om := Omens.new(null, 1)
	var extra := om.extra_props()
	if extra.size() != 2:
		errs.append("extra_props() отдаёт %d предметов вместо двух" % extra.size())
	for p: Dictionary in extra:
		if p.get("col", true) != false:
			errs.append("%s: предмет знака с коллайдером — 83 коробки паритета "
				% String(p.get("id", "?")) + "сдвинутся")
		if not bool(p.get("dyn", false)):
			errs.append("%s: предмет знака не dyn — он будет виден с начала игры"
				% String(p.get("id", "?")))

	if errs.is_empty():
		print("PASS test_omens: знаков %d, бюджет %d..%d за прохождение, "
			% [rows.size(), total_min, total_max] + "предметов знака %d" % extra.size())
		quit(0)
		return
	print("FAIL test_omens: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)

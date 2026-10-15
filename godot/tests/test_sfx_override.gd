# Приёмка оверлея эффектов: godot/audio/sfx/sfx_override.json ↔ запечённый
# манифест. Смысл теста — не «файлы на месте», а «оверлей не подменил игре микс
# и не завёл звуков, которых в audio.js не было».
#
# Оверлея может не быть: папку удалили или "enabled": false — это штатная
# конфигурация, игра тогда звучит ровно как принятая версия фазы 4. Тест в этом
# случае проходит и говорит, что пропустил.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_sfx_override.gd
extends SceneTree

const BAKED := "res://audio/baked/"
const SFX := "res://audio/sfx/"

# Стингер длиннее двух секунд наезжает на карточку провала, а шаг длиннее 0.2 с
# превращается в топот. Тридцать процентов — весь запас, который у них есть.
const LEN_LIMIT := 1.30

# Гейн запечённого — исходная амплитуда рецепта audio.js. Разойдётся хоть на
# процент — поедет весь тихий микс игры, и заметить это можно только на слух.
const GAIN_EPS := 1e-9


func _initialize() -> void:
	var errs: Array[String] = []

	var bf := FileAccess.open(BAKED + "manifest.json", FileAccess.READ)
	if bf == null:
		print("FAIL: нет ", BAKED, "manifest.json — прогнать py tools/bake_audio.py")
		quit(1)
		return
	var bm: Dictionary = JSON.parse_string(bf.get_as_text())
	var baked_shots: Dictionary = bm.get("one_shots", {})
	var baked_loops: Dictionary = bm.get("loops", {})
	var baked_gains: Dictionary = bm.get("gains", {})
	var baked_secs: Dictionary = bm.get("seconds", {})

	var of := FileAccess.open(SFX + "sfx_override.json", FileAccess.READ)
	if of == null:
		print("SKIP test_sfx_override: оверлея нет — игра звучит запечённым")
		quit(0)
		return
	var parsed: Variant = JSON.parse_string(of.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		print("FAIL: sfx_override.json не разобран как объект")
		quit(1)
		return
	var d: Dictionary = parsed
	if not bool(d.get("enabled", true)):
		print("SKIP test_sfx_override: оверлей выключен флагом enabled")
		quit(0)
		return

	var over: Dictionary = d.get("override", {})
	var extra: Dictionary = d.get("extra", {})
	var files := 0

	# 1. override — строгое подмножество запечённых one-shot'ов.
	for snd in over:
		var name := String(snd)
		if not baked_shots.has(name):
			errs.append("override '" + name + "' нет среди запечённых — это extra")
			continue
		var e: Dictionary = over[snd]
		files += _check_files(e, name, errs)

		var g := float(e.get("gain", -1.0))
		var bg := float(baked_gains.get(name, 0.0))
		if absf(g - bg) > GAIN_EPS:
			errs.append("%s: gain %.10f, у запечённого %.10f — микс поедет"
				% [name, g, bg])

		var s := float(e.get("seconds", 0.0))
		var bs := float(baked_secs.get(name, 0.0))
		if s <= 0.0:
			errs.append(name + ": нет seconds")
		elif bs > 0.0 and s > bs * LEN_LIMIT:
			errs.append("%s: %.3f с при запечённых %.3f — длиннее чем на %d%%"
				% [name, s, bs, int((LEN_LIMIT - 1.0) * 100.0)])

		var need: int = (baked_shots[name] as Array).size()
		var got: int = (e.get("files", []) as Array).size()
		if got < mini(need, 1):
			errs.append("%s: вариаций %d, у запечённого %d" % [name, got, need])

	# 2. extra — с запечённым не пересекается ни одним именем.
	for snd in extra:
		var name := String(snd)
		if baked_shots.has(name) or baked_loops.has(name):
			errs.append("extra '" + name + "' занято запечённым — секции обязаны "
				+ "не пересекаться")
			continue
		if over.has(snd):
			errs.append("'" + name + "' лежит и в override, и в extra")
			continue
		var e: Dictionary = extra[snd]
		files += _check_files(e, name, errs)
		if float(e.get("gain", 0.0)) <= 0.0:
			errs.append(name + ": нет gain — audio.gd не выставит громкость")
		if float(e.get("seconds", 0.0)) <= 0.0:
			errs.append(name + ": нет seconds")

	if errs.is_empty():
		print("PASS test_sfx_override: замен %d, новых %d, файлов %d"
			% [over.size(), extra.size(), files])
		quit(0)
		return

	print("FAIL test_sfx_override: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


func _check_files(entry: Dictionary, name: String, errs: Array[String]) -> int:
	var list: Array = entry.get("files", [])
	if list.is_empty():
		errs.append(name + ": пустой список файлов")
		return 0
	var n := 0
	for fn in list:
		n += 1
		var path := SFX + String(fn)
		if not FileAccess.file_exists(path):
			errs.append("нет файла: " + String(fn))
		elif not ResourceLoader.exists(path):
			errs.append(String(fn) + " не импортирован — прогнать --headless --import")
		elif ResourceLoader.load(path) as AudioStream == null:
			errs.append(String(fn) + " грузится не как AudioStream")
	return n

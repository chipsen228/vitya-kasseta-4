# Приёмка запечённого звука: godot/audio/baked/manifest.json ↔ список звуков
# из src/engine/audio.js. Смысл теста — не «файлы на месте», а «ни один звук
# оригинала не потерялся по дороге»: пропавший рецепт в игре не падает, он
# просто молчит, и заметить это можно только на слух через час игры.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_audio_manifest.gd
extends SceneTree

const BAKED := "res://audio/baked/"

# Эталон — выписан из src/engine/audio.js вручную, метод за методом.
# Значение — минимум вариаций: столько мест, где в оригинале стоял Math.random
# внутри рецепта (одинаковый звук подряд слышно сразу).
const EXPECTED_SHOTS := {
	# step(surface, run, crouch): switch по grass/gravel/dirt/concrete/доски
	"step-wood": 3,
	"step-grass": 3,
	"step-gravel": 3,
	"step-dirt": 3,
	"step-concrete": 3,
	"step-water": 4,
	"water-enter": 1,
	"water-exit": 1,
	# creak(strength): вызовы игры дают 0.5 / 1.0 / 1.4 — три ступени силы
	"creak-soft": 2,
	"creak-mid": 2,
	"creak-hard": 2,
	# knock(times, spacing) — один удар, счёт и интервал рантаймовые
	"knock": 1,
	# door(open) — вместе со щелчком язычка на 620 мс
	"door-open": 1,
	"door-close": 1,
	# chain() — шесть звеньев с разбросом внутри события
	"chain": 2,
	# click() — интерфейс и выключатель
	"click": 1,
	# stinger(power) — джампскейр
	"stinger": 1,
	# tapeClick() — соленоид лентопротяжки
	"tape-click": 1,
	# clockChime(times) — один удар часов
	"chime": 1,
	# heartbeat(times, bpm) — один удар из двух толчков
	"heartbeat": 1,
	# stepsAbove(count) — шаг наверху вместе со скрипом
	"steps-above": 2,
	# dogFar() — один лай
	"dog": 2,
	# distantTrain() — электричка с гудком на 2.6 с
	"train": 1,
	# mumble(seconds) — постель бубнежа, огибающую ставит audio.gd
	"mumble": 2,
	# rewind(seconds) — длина внутри рецепта: 0.7 и 1.6 из глав, 0.8 из
	# кассеты, 1.2 — значение по умолчанию
	"rewind-07": 1,
	"rewind-08": 1,
	"rewind-12": 1,
	"rewind-16": 1,
	# noise() из вызывающих модулей: банки в тайнике (interact.js:559),
	# удар скримера (scare.js:92), порча плёнки (tape.js:207) и склейка
	# камкордера (tape.js:280)
	"jar-glass": 2,
	"scare-hit": 1,
	"tape-fx": 1,
	"tape-cut": 1
}

# Лупы: startHum(), startOutdoors(), tapeBed(on), phoneBed(on).
const EXPECTED_LOOPS := ["hum", "crickets", "tape-bed", "phone-bed"]

# Короче секунды петля слышна как цикл, а не как фон.
const MIN_LOOP_SECONDS := 1.0


func _initialize() -> void:
	var errs: Array[String] = []

	var f := FileAccess.open(BAKED + "manifest.json", FileAccess.READ)
	if f == null:
		print("FAIL: нет ", BAKED, "manifest.json — прогнать py tools/bake_audio.py")
		quit(1)
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		print("FAIL: манифест звука не разобран как объект")
		quit(1)
		return

	var m: Dictionary = parsed
	var shots: Dictionary = m.get("one_shots", {})
	var loops: Dictionary = m.get("loops", {})
	var gains: Dictionary = m.get("gains", {})
	var seconds: Dictionary = m.get("seconds", {})

	var sr := int(m.get("sample_rate", 0))
	if sr != 44100:
		errs.append("sample_rate = %d, ждали 44100" % sr)

	var files_seen := 0

	# 1. Всё, что синтезировал audio.js, лежит в манифесте и на диске.
	for snd in EXPECTED_SHOTS:
		if not shots.has(snd):
			errs.append("нет one-shot: " + String(snd))
			continue
		var list: Array = shots[snd]
		var need: int = EXPECTED_SHOTS[snd]
		if list.size() < need:
			errs.append("%s: вариаций %d, минимум %d" % [snd, list.size(), need])
		for fn in list:
			files_seen += 1
			if not FileAccess.file_exists(BAKED + String(fn)):
				errs.append("нет файла: " + String(fn))
		if float(gains.get(snd, 0.0)) <= 0.0:
			errs.append("нет gains для " + String(snd) + " — audio.gd не выставит громкость")

	for snd in EXPECTED_LOOPS:
		if not loops.has(snd):
			errs.append("нет лупа: " + String(snd))
			continue
		files_seen += 1
		if not FileAccess.file_exists(BAKED + String(loops[snd])):
			errs.append("нет файла лупа: " + String(loops[snd]))
		if float(gains.get(snd, 0.0)) <= 0.0:
			errs.append("нет gains для лупа " + String(snd))
		if float(seconds.get(snd, 0.0)) < MIN_LOOP_SECONDS:
			errs.append("луп %s короче %.1f с" % [snd, MIN_LOOP_SECONDS])

	# 2. Лишнего в манифесте тоже нет: имя мимо эталона — это либо опечатка
	# в bake_audio.py, либо звук, которого в оригинале не было.
	for snd in shots:
		if not EXPECTED_SHOTS.has(snd):
			errs.append("лишний one-shot: " + String(snd))
	for snd in loops:
		if not EXPECTED_LOOPS.has(String(snd)):
			errs.append("лишний луп: " + String(snd))

	if errs.is_empty():
		print("PASS test_audio_manifest: one-shot %d имён, лупов %d, файлов %d, %d Гц"
			% [EXPECTED_SHOTS.size(), EXPECTED_LOOPS.size(), files_seen, sr])
		quit(0)
		return

	print("FAIL test_audio_manifest: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)

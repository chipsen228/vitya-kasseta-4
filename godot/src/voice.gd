# Голос. Дед, телефон, кассеты, нарратор и единственная озвученная реплика
# Сергея — крик по [Q].
#
# ПОЧЕМУ ОТДЕЛЬНЫЙ МОДУЛЬ, А НЕ audio.play()
#
# Две причины, и обе слышны сразу.
# 1. Пул на шестнадцать голосов вытесняет самый старый (audio.gd::_take_voice).
#    Реплика деда живёт три секунды, шаги — сотые доли; первой из пула вылетит
#    именно она, оборвавшись на полуслове.
# 2. На каждый one-shot надет AudioStreamRandomizer с random_pitch = 1.06.
#    Полутон вверх-вниз на шагах — жизнь, на 78-летнем голосе — смена возраста
#    от фразы к фразе.
# Поэтому здесь пять своих AudioStreamPlayer, по одному на канал, и питч у них
# ровно 1.0. НИКОГДА не звать голос через audio.play() — вернётся и то и другое.
#
# КЛЮЧ РЕПЛИКИ — НЕ ИНДЕКС
#
# sha1(кто + "|" + нормализованный текст)[:12]. Правка текста в texts.json просто
# не найдёт файл, и игра тихо откатится на нынешний mumble. Индекс же сдвинул бы
# всю озвучку на строку: голос под чужим субтитром замечают не сразу и не все.
# norm_text/line_key повторены в tools/el_common.py символ в символ — правишь
# здесь, правь и там (сверку делает tests/test_voice_manifest.gd).
#
# ДАЛЬНОСТЬ ДЕЛАЕТ ГРОМКОСТЬ (переписано в фазе 6)
#
# Было: ffmpeg печёт «уже глуховатый» мастер, шина Voice режет полосу под
# расстояние. На живом прохождении это дало ровно один результат — дед звучал
# как из телефонной трубки, потому что оба слоя резали одно и то же и на
# рабочих 8–20 метрах сходились в 150–3200 Гц.
#
# Стало: мастер сухой и без окраски, а расстояние читается по уровню. Полосу
# шина всё ещё двигает, но верх не опускается ниже 5.5 кГц — слова остаются
# разборчивыми на любой дистанции. Фильтры ставятся ОДИН РАЗ на старте реплики:
# покадровая подстройка на идущем деде слышна как свип.
class_name GameVoice
extends Node

const VOICE_DIR := "res://audio/voice/"
const MANIFEST := VOICE_DIR + "voice_manifest.json"

# Каналы. PLAYER пятый и отдельный: крик звучит поверх всего, что в этот момент
# играет, и глушить его нечем — это сам игрок.
#
# SELF шестой (фаза 6) — Сергей в телефонном разговоре. Он не в трубке: трубка
# принадлежит собеседнику, а сам он стоит в комнате. Отдельный канал, а не
# CH_PHONE, по двум причинам: у него своя обработка (широкая полоса против
# 300–3400) и он обязан играть, не обрывая реплику мамы, — иначе на быстром [E]
# два голоса разом окажутся на одном плеере.
const CH_VITYA := "vitya"
const CH_PHONE := "phone"
const CH_TAPE := "tape"
const CH_NARRATOR := "narrator"
const CH_PLAYER := "player"
const CH_SELF := "self"

# СОСЕД седьмой (фаза 9). Аркадий на улице стоит в двух шагах от игрока,
# под открытым небом, — ни телефонной полосы CH_PHONE, ни ленты CH_TAPE на нём
# быть не может. Голос тот же самый, что в трубке и за кадром кассет (это
# и есть смысл: игрок обязан узнать соседа раньше, чем разберёт слова),
# а вот обработка своя — сухая и широкая.
const CH_NEIGHBOUR := "neighbour"
const CHANNELS: Array[String] = [CH_VITYA, CH_PHONE, CH_TAPE, CH_NARRATOR,
	CH_PLAYER, CH_SELF, CH_NEIGHBOUR]

# Приоритет субтитра. Наоборот к звуку: телефон и кассета важнее деда, дед
# важнее монолога Сергея. Без этого случайный взгляд на предмет посреди реплики
# деда подменял бы субтитр — осмотры срабатывают постоянно.
const PRIO_MONOLOGUE := 0
const PRIO_VITYA := 1
const PRIO_LINE := 2

# Ближе этого дед говорит поверх телефона и кассеты (они уходят на -9 дБ);
# дальше — реплику не получает вовсе, и ai.gd перезаводит таймер на 6 секунд,
# чтобы она не пропала на минуту.
const VITYA_OVERRIDE_DIST := 6.0
const DUCK_DB := -9.0
const DUCK_TAU := 0.12

# Ступени дальности: [метры, highpass, lowpass, дБ]. Между ступенями не
# интерполируем — на слух это те же четыре плана, а свипа не даёт.
#
# ДАЛЬНОСТЬ ДЕЛАЕТ ГРОМКОСТЬ, А НЕ ПОЛОСА (фаза 6). Прежние ступени на десяти
# метрах давали 150–3200 Гц — буквально телефонный диапазон, а дед почти всё
# время в 8–20 метрах, то есть игрок почти всегда слышал именно телефон.
# Нижняя граница полосы теперь не опускается ниже 5.5 кГц: слова остаются
# разборчивыми на любом расстоянии, а «далеко» читается по уровню.
const DIST_STEPS := [
	[6.0, 20.0, 20000.0, 0.0],
	[10.0, 60.0, 11000.0, -3.0],
	[14.0, 80.0, 8000.0, -6.0],
	[18.0, 100.0, 5500.0, -9.0],
]

# Через перекрытие (дед этажом выше или в подполе). Величина уже считается
# в ai.gd тем же порогом 1.2.
#
# 0.75, а не 0.45: втрое срезанная полоса превращала деда этажом выше в звук
# из бочки. Перекрытие глушит и слегка заваливает верх — этого достаточно.
const FLOOR_DY := 1.2
const FLOOR_CUT := 0.75
const FLOOR_DB := -3.0

# Сколько секунд после поимки дед говорит из набора «caught».
const CAUGHT_WINDOW := 90.0

# Гэг: дед ревнует умершую жену к силачам из телевизора. Только в патруле —
# шутка во время охоты убивает напряжение, а вблизи и после поимки у него другой
# голос. Ветка живёт на слотах ПОЛНЫХ фраз, а их фаза 6 оставила примерно один
# на двадцать секунд, — то есть частота шутки почти не сдвинулась и её по-
# прежнему держит GAG_GAP: раз в четыре с лишним минуты, две-три за ночь.
# Набора нет в манифесте — ветка не срабатывает, и всё идёт как без неё.
const GAG_CHANCE := 0.12
const GAG_GAP := 240.0

# Сколько последних реплик набора не повторять. На маленьком наборе — три,
# на большом — треть: при темпе фазы 6 набор из двадцати двух бормотаний
# прокручивается за пару минут, и трёх запретов там не слышно вовсе.
const NO_REPEAT := 3

# ТЕМП РЕЧИ (фаза 6). Пётр прошёл игру и сказал: на большом участке дед просто
# молчит. Интервал 22–48 с из ai.gd заменён на 5–7 с, и держит его не длина
# наборов, а состав: две трети слотов забирают бормотания в два-три слова.
# На слух это старик, бормочущий сам с собой, а не диктор с расписанием;
# полная фраза от этого звучит реже и потому весомее.
const GAP_MIN := 5.0
const GAP_MAX := 7.0

# Доля бормотаний и минимальный разрыв между двумя полными фразами. Без второго
# числа случайность выдаёт полные фразы подряд, и весь смысл пропорции пропадает.
# Фаза 8: было 0.66. Две трети слотов уходили двадцати двум бормотаниям
# в два слова, и на слух дед был однотипен не от бедности наборов, а от этой
# пропорции. Половина — и полная фраза слышна вдвое чаще, ничего не генерируя.
const MUTTER_SHARE := 0.50
const FULL_GAP := 20.0

# Слом тона: не чаще раза в две минуты, и от трёх процентов в покое до трети
# на пике шкалы напряжения (tension.gd). Гейт тот же по смыслу, что у гэга:
# редкое перестаёт работать, как только становится ожидаемым.
const WRONG_GAP := 120.0
const WRONG_MIN := 0.03
const WRONG_MAX := 0.32

var enabled := false
var audio: GameAudio = null
var ui: Variant = null
var state: Variant = null

var _lines: Dictionary = {}          # ключ -> {f, s, ch, w, t}
var _sets: Dictionary = {}           # имя набора -> [ключи]
var _named: Dictionary = {}          # имя сценарной реплики -> ключ
var _players: Dictionary = {}        # канал -> AudioStreamPlayer
var _pending_channels: Dictionary = {} # Новый поток ждёт снятия паузы.
var _paused := false
var _base_db: Dictionary = {}        # канал -> уровень без дакинга
var _duck: Dictionary = {}           # канал -> текущее приглушение, дБ
var _duck_target: Dictionary = {}
var _recent: Dictionary = {}         # имя набора -> [последние ключи]
var _unduck_at := 0.0
# Шкала давления (фаза 8). Ставит main.gd после сборки мира; null — модуля
# нет, и слом тона выпадает по нижней вероятности.
var tension: Variant = null

var _caught_at := -1e9
var _gag_at := -1e9
var _wrong_at := -1e9
var _full_at := -1e9              # когда в последний раз звучала полная фраза
var _clock := 0.0
var _warned := false


func _init(game_audio: GameAudio = null) -> void:
	audio = game_audio


func _ready() -> void:
	# Узел следит за отложенным запуском AudioServer и во время паузы.
	# Игровые часы и огибающие стоят до set_paused(false).
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_players()
	_load_manifest()


func _build_players() -> void:
	for ch in CHANNELS:
		var p := AudioStreamPlayer.new()
		p.name = "Voice_" + ch
		# Дед — на шину Voice (её полосу двигает дальность). Остальные на Dry:
		# телефон и кассета рождаются в трубке и в динамике телевизора,
		# отражаться им негде — там же живут phone-bed и tape-bed.
		p.bus = GameAudio.BUS_VOICE if ch == CH_VITYA else &"Dry"
		p.pitch_scale = 1.0
		add_child(p)
		_players[ch] = p
		p.stream_paused = _paused
		_base_db[ch] = 0.0
		_duck[ch] = 0.0
		_duck_target[ch] = 0.0


func _load_manifest() -> void:
	var f := FileAccess.open(MANIFEST, FileAccess.READ)
	if f == null:
		# Штатный случай: озвучки в сборке нет. Игра звучит ровно как принятая
		# версия фазы 4 — ни одна точка вызова этого не замечает.
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("voice_manifest.json не разобран как объект — озвучка выключена")
		return
	var d: Dictionary = parsed
	if not bool(d.get("enabled", true)):
		return
	_lines = d.get("lines", {})
	_sets = d.get("sets", {})
	_named = d.get("named", {})
	enabled = not _lines.is_empty()


# ------------------------------------------------------------------ ключ ---

## Нормализация текста для ключа. Повторена в tools/el_common.py::norm_text.
static func norm_text(s: String) -> String:
	# Неразрывный пробел в texts.json встречается (приехал из вёрстки прототипа)
	# и от обычного на глаз неотличим.
	var t := s.replace(" ", " ").replace("\n", " ").replace("\r", " ").replace("\t", " ")
	while t.find("  ") >= 0:
		t = t.replace("  ", " ")
	t = t.strip_edges()
	# Ровно как ^[—–-]+\s* в питоне: снимаем ВЕСЬ ведущий пробег тире разом,
	# а не по одному — иначе «— — текст» разошлось бы с генератором.
	var i := 0
	while i < t.length() and (t[i] == "—" or t[i] == "–" or t[i] == "-"):
		i += 1
	t = t.substr(i).strip_edges()
	return t.to_lower()


## Ключ реплики. Повторён в tools/el_common.py::line_key.
static func line_key(who: String, text: String) -> String:
	return (who + "|" + norm_text(text)).sha1_text().substr(0, 12)


# ------------------------------------------------------------- публичное ---

func set_paused(on: bool) -> void:
	_paused = on
	for ch: String in _players:
		var p: AudioStreamPlayer = _players[ch]
		if not is_instance_valid(p): continue
		p.stream_paused = on
		if not on and _pending_channels.has(ch):
			_pending_channels.erase(ch)
			p.play()
			p.stream_paused = false


## Реплика телефонного разговора. Возвращает длительность файла или -1.0, если
## записи нет — тогда вызывающий оставляет свою прежнюю формулу.
func play_dialogue_line(who: String, text: String, _fallback_seconds := 0.0) -> float:
	if audio != null: audio.stop_spatial_owner("dialogue:spatial")
	return _play_key(line_key(who, text), CH_PHONE)


## Голос закреплён у жителя или приёмника; пауза и громкость общие с миром.
func play_spatial_dialogue_line(who: String, text: String, at: Vector3,
		_fallback_seconds := 0.0, distance := 24.0) -> float:
	if not enabled or audio == null: return -1.0
	var entry: Dictionary = _lines.get(line_key(who, text), {})
	if entry.is_empty(): return -1.0
	var stream := _stream(String(entry.get("f", "")))
	if stream == null: return -1.0
	stop_dialogue()
	if not audio.spatial_stream(stream, at, 1.0, distance, "dialogue:spatial", 4): return -1.0
	return float(entry.get("s", stream.get_length()))


## Крик соседа из набора. Возвращает текст сыгранной реплики — субтитр обязан
## быть тем же, что прозвучало, а выбор делается здесь: набор помнит последние
## выданные ключи, и второй заход за той же строчкой не даст.
##
## Пустая строка означает «записи нет» (сборка без озвучки либо набор пуст),
## и тогда вызывающий сам решает, что показать: молчаливый субтитр лучше,
## чем крик без крика.
func say_shout(set_name: String) -> String:
	if not enabled:
		return ""
	var key := _pick(set_name)
	if key == "":
		return ""
	var e: Variant = _lines.get(key, null)
	if not (e is Dictionary):
		return ""
	if _play_key(key, CH_NEIGHBOUR) <= 0.0:
		return ""
	return String((e as Dictionary).get("t", ""))


## Реплика кассеты. Канал берётся из манифеста: закадр соседа звучит из динамика
## телевизора, а ремарка — нарратором, широкой полосой и тише всего остального.
func play_tape_line(tape_id: String, text: String) -> float:
	return _play_key(line_key("tape:" + tape_id, text), CH_TAPE)


## Дед говорит сам. Набор выбирается по состоянию и расстоянию, текст уходит
## в субтитр отсюда же — иначе голос и надпись разъедутся.
## false = записи нет либо реплика уступила телефону/кассете.
func say_vitya(dist: float, dy: float) -> bool:
	if not enabled:
		return false
	var busy := dialogue_active() or tape_active()
	if busy and dist > VITYA_OVERRIDE_DIST:
		return false
	# Бормотание пробуем первым, но набор угадывается только один раз: _vitya_set
	# не чистая функция — она отмечает выданный гэг, и второй её вызов на том же
	# слоте отодвинул бы шутку впустую.
	var mutter := _want_mutter()
	var key := ""
	if mutter:
		key = _pick("vitya-mutter")
	if key == "":
		mutter = false
		key = _pick(_vitya_set(dist))
	if key == "":
		return false
	if not mutter:
		_full_at = _clock
	return _say_vitya(key, dist, dy, busy, mutter)


## Сколько секунд до следующей реплики. Спрашивает ai.gd; без озвучки он берёт
## свои прежние 22–48 и звучит ровно как принятая фаза 4.
func next_gap() -> float:
	return GAP_MIN + randf() * (GAP_MAX - GAP_MIN)


## Сценарная реплика деда по имени из манифеста ("threat-0", "at-gate").
## Такую пропускать нельзя — она часть сцены, а не фон.
func say_vitya_key(name: String, dist: float, dy: float) -> bool:
	if not enabled or not _named.has(name):
		return false
	# Сценарная реплика — полная по определению, и разрыв между полными она
	# обязана отсчитывать наравне с остальными: иначе сразу за сценой у ворот
	# дед выдал бы вторую полную фразу.
	_full_at = _clock
	return _say_vitya(String(_named[name]), dist, dy, false)


## Крик по [Q]. Единственная реплика Сергея, которая звучит: она диегетическая,
## её слышит дед. Во дворе — с отражками от забора, в доме — без них.
func shout(outdoor: bool) -> float:
	if not enabled:
		return -1.0
	var key := _pick("shout-outdoor" if outdoor else "shout-indoor")
	if key == "":
		return -1.0
	return _play_key(key, CH_PLAYER)


func stop_dialogue() -> void:
	if audio != null: audio.stop_spatial_owner("dialogue:spatial")
	_stop(CH_PHONE)
	_stop(CH_SELF)
	_stop(CH_NEIGHBOUR)


func stop_tape() -> void:
	_stop(CH_TAPE)
	_stop(CH_NARRATOR)


func stop_all() -> void:
	if audio != null: audio.stop_spatial_owner("dialogue:spatial")
	for ch in CHANNELS:
		_stop(ch)
	_unduck_now()


## Идёт ли телефонный разговор — обе стороны разом. Без CH_SELF арбитр
## «дед перебивает телефон» не видел бы, что говорит Сергей, и дед заговорил бы
## поверх собственной реплики игрока.
func dialogue_active() -> bool:
	return _playing(CH_PHONE) or _playing(CH_SELF) or _playing(CH_NEIGHBOUR) \
		or (audio != null and audio.spatial_owner_active("dialogue:spatial"))


func tape_active() -> bool:
	return _playing(CH_TAPE) or _playing(CH_NARRATOR)


func vitya_active() -> bool:
	return _playing(CH_VITYA)


func seconds_of(key: String) -> float:
	var e: Variant = _lines.get(key, null)
	return float((e as Dictionary)["s"]) if e is Dictionary else -1.0


func text_of(key: String) -> String:
	var e: Variant = _lines.get(key, null)
	return String((e as Dictionary).get("t", "")) if e is Dictionary else ""


func has_line(key: String) -> bool:
	return _lines.has(key)


## Поимка. После неё дед девяносто секунд говорит другое — не «стой», а
## «опять ушёл. как отец».
func mark_caught() -> void:
	_caught_at = _clock


# --------------------------------------------------------------- нутрянка ---

func _vitya_set(dist: float) -> String:
	if _clock - _caught_at < CAUGHT_WINDOW and _has_set("vitya-caught"):
		return "vitya-caught"
	if dist <= VITYA_OVERRIDE_DIST and _has_set("vitya-near"):
		return "vitya-near"
	var st := ""
	if state != null:
		var v: Variant = state.get("threatState")
		st = "" if v == null else String(v)
	if st == "hunt" and _has_set("vitya-hunt"):
		return "vitya-hunt"
	# Гэг — до выбора патруля, но за четырьмя замками. Условия проверяются
	# заново, а не наследуются от веток выше: те возвращают управление только
	# когда свой набор есть в манифесте, а без него охота и «вблизи» провалились
	# бы сюда и дед пошутил бы ровно там, где шутить нельзя.
	if _has_set("vitya-gag") and st != "hunt" and dist > VITYA_OVERRIDE_DIST \
			and _clock - _caught_at >= CAUGHT_WINDOW \
			and _clock - _gag_at >= GAG_GAP and randf() < GAG_CHANCE:
		# Отметка ставится здесь, а не после проигрывания: даже сорвавшаяся
		# попытка должна отодвинуть следующую, иначе на пропавшем файле гэги
		# посыплются подряд.
		_gag_at = _clock
		return "vitya-gag"
	# Слом тона (фаза 8). Вероятность растёт со шкалой напряжения: дед говорит
	# то, чего знать не может, на подъёме — там, где игрок и так насторожён,
	# и оговорка попадает в уже готовое ухо. В покое почти не выпадает.
	if _has_set("vitya-wrong") and st != "hunt" and dist > VITYA_OVERRIDE_DIST 			and _clock - _caught_at >= CAUGHT_WINDOW 			and _clock - _wrong_at >= WRONG_GAP 			and randf() < WRONG_MIN + (WRONG_MAX - WRONG_MIN) * _tension():
		_wrong_at = _clock
		return "vitya-wrong"
	# Патруль тянет из двух наборов: девять реплик прототипа — канон, терять их
	# нельзя, но одних их на ночь не хватает.
	if _has_set("vitya-patrol") and _has_set("vitya-threat"):
		return "vitya-patrol" if randf() < 0.6 else "vitya-threat"
	if _has_set("vitya-patrol"):
		return "vitya-patrol"
	return "vitya-threat"


## Шкала напряжения, если она есть. Нет её — слом тона идёт по нижней
## вероятности, ровно как любая другая редкая реплика.
func _tension() -> float:
	if tension == null:
		return 0.0
	return clampf(float(tension.value()), 0.0, 1.0)


func _has_set(name: String) -> bool:
	var a: Variant = _sets.get(name, null)
	return a is Array and not (a as Array).is_empty()


# Бормотать или говорить фразу. Набора нет — работает как фаза 5, одни фразы.
func _want_mutter() -> bool:
	if not _has_set("vitya-mutter"):
		return false
	# Полная фраза не идёт следом за полной раньше двадцати секунд: между ними
	# обязано быть бормотание. Иначе при слоте в шесть секунд случайность выдаёт
	# две-три фразы подряд, и дед снова звучит как объявление на вокзале.
	if _clock - _full_at < FULL_GAP:
		return true
	return randf() < MUTTER_SHARE


func _pick(set_name: String) -> String:
	var a: Variant = _sets.get(set_name, null)
	if not (a is Array) or (a as Array).is_empty():
		return ""
	var list: Array = a
	var recent: Array = _recent.get(set_name, [])
	var free: Array = []
	for k in list:
		if not recent.has(k):
			free.append(k)
	if free.is_empty():
		free = list
		recent = []
	var key := String(free[randi() % free.size()])
	recent.append(key)
	while recent.size() > mini(maxi(NO_REPEAT, list.size() / 3), list.size() - 1):
		recent.pop_front()
	_recent[set_name] = recent
	return key


func _say_vitya(key: String, dist: float, dy: float, duck: bool,
		mutter := false) -> bool:
	var e: Variant = _lines.get(key, null)
	if not (e is Dictionary):
		return false
	var entry: Dictionary = e

	var row := _dist_row(dist)
	var hp := float(row[1])
	var lp := float(row[2])
	var db := float(row[3])
	if absf(dy) > FLOOR_DY:
		# Сквозь перекрытие: та же полоса, сдвинутая вниз, и ещё тише.
		hp *= FLOOR_CUT
		lp *= FLOOR_CUT
		db += FLOOR_DB
	if audio != null:
		audio.set_voice_distance(hp, lp)

	var seconds := _start(CH_VITYA, entry, db)
	if seconds < 0.0:
		return false
	if duck:
		_duck_lines(seconds + 0.3)
	# Бормотание идёт субтитром монолога, а не деда. При слоте в шесть секунд
	# приоритет деда стирал бы описание каждого осмотренного предмета быстрее,
	# чем его успевают дочитать, — а осмотры срабатывают постоянно.
	_subtitle(String(entry.get("t", "")), seconds + 0.4,
		PRIO_MONOLOGUE if mutter else PRIO_VITYA)
	return true


static func _dist_row(dist: float) -> Array:
	for row: Array in DIST_STEPS:
		if dist <= float(row[0]):
			return row
	return DIST_STEPS[DIST_STEPS.size() - 1]


func _play_key(key: String, fallback_channel: String) -> float:
	if not enabled:
		return -1.0
	var e: Variant = _lines.get(key, null)
	if not (e is Dictionary):
		return -1.0
	var entry: Dictionary = e
	var ch := String(entry.get("ch", fallback_channel))
	if not _players.has(ch):
		ch = fallback_channel
	return _start(ch, entry, 0.0)


func _start(channel: String, entry: Dictionary, db: float) -> float:
	var p: AudioStreamPlayer = _players.get(channel)
	if p == null:
		return -1.0
	var s := _stream(String(entry.get("f", "")))
	if s == null:
		return -1.0
	p.stop()
	p.stream = s
	p.pitch_scale = 1.0
	_base_db[channel] = db
	p.volume_db = db + float(_duck.get(channel, 0.0))
	p.stream_paused = _paused
	if _paused:
		# play() может начать поток после текущего кадра. Под паузой
		# оставляем его подготовленным, не отправляя запуск AudioServer.
		_pending_channels[channel] = true
	else:
		_pending_channels.erase(channel)
		p.play()
		p.stream_paused = false
	return float(entry.get("s", s.get_length()))


func _stream(rel: String) -> AudioStream:
	if rel == "":
		return null
	var path := VOICE_DIR + rel
	if not ResourceLoader.exists(path):
		if not _warned:
			_warned = true
			push_warning("озвучка не импортирована: " + path
				+ " — прогнать Godot --headless --import")
		return null
	return ResourceLoader.load(path) as AudioStream


func _playing(channel: String) -> bool:
	var p: AudioStreamPlayer = _players.get(channel)
	return p != null and (p.playing or _pending_channels.has(channel))


func _stop(channel: String) -> void:
	_pending_channels.erase(channel)
	var p: AudioStreamPlayer = _players.get(channel)
	if p != null:
		p.stop()
		p.stream_paused = _paused


func _duck_lines(seconds: float) -> void:
	for ch in [CH_PHONE, CH_TAPE, CH_NARRATOR, CH_SELF, CH_NEIGHBOUR]:
		_duck_target[ch] = DUCK_DB
	_unduck_at = _clock + maxf(0.3, seconds)


func _unduck_now() -> void:
	for ch in CHANNELS:
		_duck_target[ch] = 0.0
	_unduck_at = 0.0


func _subtitle(text: String, seconds: float, prio: int) -> void:
	if ui == null or text == "":
		return
	ui.say(text, seconds, prio)


func _process(delta: float) -> void:
	# Повторная синхронизация ловит play(), поставленный в очередь перед ESC.
	for p: AudioStreamPlayer in _players.values():
		if is_instance_valid(p) and p.stream_paused != _paused:
			p.stream_paused = _paused
	if _paused: return
	_clock += delta
	if _unduck_at > 0.0 and _clock >= _unduck_at:
		_unduck_now()
	for ch in CHANNELS:
		var cur := float(_duck[ch])
		var tgt := float(_duck_target[ch])
		if absf(cur - tgt) < 0.05:
			if cur != tgt:
				_duck[ch] = tgt
				_apply_db(ch)
			continue
		_duck[ch] = cur + (tgt - cur) * (1.0 - exp(-delta / DUCK_TAU))
		_apply_db(ch)


func _apply_db(channel: String) -> void:
	var p: AudioStreamPlayer = _players.get(channel)
	if p != null:
		p.volume_db = float(_base_db[channel]) + float(_duck[channel])

# Звук. Порт src/engine/audio.js.
#
# В браузере каждый звук собирался графом WebAudio в момент вызова. Держать
# такой граф в Godot нечем, поэтому все рецепты посчитаны заранее
# (tools/bake_audio.py -> audio/baked/*.wav + manifest.json), а здесь остались
# только те решения, которые в оригинале принимались в рантайме: какая вариация,
# какой гейн, через какую шину и с какой задержкой (setTimeout — это _after).
#
# Исключение — tone() и noise(): их зовут с произвольными параметрами прямо из
# глав, меню и кассеты, запечь такое нечем. Они синтезируются на месте через
# AudioStreamGenerator; звуки короткие, буфер один, это дёшево.
#
# Уровни (0.055 у гула, 0.10 у шагов, 0.028 у сверчков) — числа из audio.js
# дословно. Файл нормирован по пику, поэтому громкость воспроизведения всегда
# «уровень из audio.js × manifest.gains[имя]»: произведение и есть та амплитуда,
# которую выдавал браузер.
#
# Реверб. В оригинале четыре пресета сворачивались ConvolverNode, зона
# переключалась кроссфейдом двух свёрток за 0.4 с. Свёртки в Godot нет —
# её место занял AudioEffectReverb на двух шинах (ReverbA/ReverbB), room_size
# и damping считаются из тех же чисел (seconds/decay/damp), которыми в оригинале
# рисовался импульс. Это честная замена по смыслу, не копия.
extends Node
class_name GameAudio

const BAKED := "res://audio/baked/"

# Слой поверх запечённого (фаза 5). Папки нет — игра звучит ровно как принятая
# версия фазы 4, ни одной ветки кода это не ломает.
const SFX := "res://audio/sfx/"

# «Пул на шестнадцать голосов, случайный питч ±6%» — комментарий audio.js.
const VOICES := 16
const GEN_VOICES := 4
const SPATIAL_VOICES := 8 # Six one-shots and two reserved ambience channels.
const SPATIAL_LOOP_VOICES := 2
const PITCH := 1.06
const SR := 44100.0

# Уровни лупов и бубнежа — выходные гейны из audio.js.
const HUM_LEVEL := 0.055
const CRICKETS_LEVEL := 0.028
const TAPE_LEVEL := 0.10
const PHONE_LEVEL := 0.026
const MUMBLE_LEVEL := 0.05

# ZONES из audio.js дословно: seconds/decay — длина и наклон импульса,
# damp — срез ФНЧ, wet — уровень мокрого тракта.
const ZONES := {
	"outdoor": {"seconds": 0.35, "decay": 5.0, "wet": 0.06, "damp": 1400.0},
	"veranda": {"seconds": 0.55, "decay": 3.4, "wet": 0.16, "damp": 2600.0},
	"room": {"seconds": 0.75, "decay": 2.6, "wet": 0.20, "damp": 3200.0},
	"small": {"seconds": 0.45, "decay": 3.8, "wet": 0.26, "damp": 3800.0},
	"shed": {"seconds": 0.9, "decay": 2.2, "wet": 0.24, "damp": 2000.0},
	"greenhouse": {"seconds": 0.8, "decay": 2.4, "wet": 0.22, "damp": 4200.0},
	"roofspace": {"seconds": 0.6, "decay": 3.0, "wet": 0.18, "damp": 1800.0},
	"cellar": {"seconds": 1.5, "decay": 1.6, "wet": 0.34, "damp": 900.0}
}

# rewind(seconds) — длину питчем не подделать, запечены четыре, что зовёт игра.
const REWIND := {"rewind-07": 0.7, "rewind-08": 0.8, "rewind-12": 1.2, "rewind-16": 1.6}

# Скрип: дословный creak(strength) тянул бы файл на каждую силу, поэтому
# запечены три ступени, а разницу добирает гейн (амплитуда в рецепте линейна
# по strength, длительность — нет; ошибка длины до 0.06 с на слух не читается).
const BUS_VOICE := &"Voice"

const CREAK_SOFT := 0.5
const CREAK_MID := 1.0
const CREAK_HARD := 1.4

var armed := false
var volume := 0.8
var zone := "outdoor"
var muted := false

var _manifest: Dictionary = {}
var _gains: Dictionary = {}
var _shots: Dictionary = {}          # имя -> AudioStreamRandomizer
var _pool: Array[AudioStreamPlayer] = []
var _next := 0
var _spatial_pool: Array[AudioStreamPlayer3D] = []
var _spatial_owners: Array[String] = []
var _spatial_priorities: Array[int] = []
var _spatial_next := 0
var _spatial_paused := false
var _spatial_dialogue_paused := false
var _spatial_loop_streams: Dictionary = {}
var _spatial_loop_names := ["", ""]
var _spatial_loop_targets := [0.0, 0.0]
var _loop_players: Dictionary = {}   # имя -> AudioStreamPlayer
var _loop_on: Dictionary = {}
var _fades: Array = []               # {p, cur, target, tau, stop}
var _timers: Array = []              # [осталось, Callable]
var _gen: Array = []                 # {p, data, at, end}
var _gen_next := 0
var _outdoor := 1.0
var _warned := false

var _extra_loops: Dictionary = {}    # имя -> файл в SFX (лупы оверлея)
var _voice_hp: AudioEffectHighPassFilter = null
var _voice_lp: AudioEffectLowPassFilter = null

var _bus_rev: Array[StringName] = [&"ReverbA", &"ReverbB"]
var _rev: Array = [null, null]
var _active := 0
var _wet := [0.0, 0.0]
var _wet_target := [0.0, 0.0]
var _wet_tau := 0.1333
var _zone_set := false

var _master := 0.8
var _master_tau := 0.05


func _ready() -> void:
	# Пауза не должна замораживать расписание: в оригинале setTimeout тикал
	# и на паузе, а тишину делал mute().
	process_mode = Node.PROCESS_MODE_ALWAYS
	_setup_buses()
	_load_manifest()
	_load_sfx_override()
	_build_voices()
	_master = volume
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(volume, 0.0001)))
	set_zone(zone, 0.0)
	armed = true


# ---------------------------------------------------------------- шины ---

func _setup_buses() -> void:
	for i in 2:
		var idx := AudioServer.get_bus_index(_bus_rev[i])
		if idx < 0:
			idx = _make_bus(String(_bus_rev[i]), true)
		var fx: AudioEffect = null
		if AudioServer.get_bus_effect_count(idx) > 0:
			fx = AudioServer.get_bus_effect(idx, 0)
		if not (fx is AudioEffectReverb):
			fx = AudioEffectReverb.new()
			AudioServer.add_bus_effect(idx, fx, 0)
		var rev := fx as AudioEffectReverb
		# Сухой сигнал обе шины пропускают без изменений, а кроссфейд зоны
		# трогает только wet — это и есть wetA/wetB оригинала. Гасить громкость
		# самой шины нельзя: вместе с хвостом обрезался бы сухой звук, который
		# начался до смены зоны (стингер в дверном проёме — обычное дело).
		rev.dry = 1.0
		rev.wet = 0.0
		_rev[i] = rev
	if AudioServer.get_bus_index(&"Dry") < 0:
		_make_bus("Dry", false)
	_setup_voice_bus()


# Шина голоса деда. Дальность делает она, а не три запечённых файла: расстояние
# меняется непрерывно, а файлов было бы три ступени. Фильтры ставятся ОДИН РАЗ
# в момент старта реплики (voice.gd) — покадровая подстройка на движущемся деде
# слышна как свип.
func _setup_voice_bus() -> void:
	var idx := AudioServer.get_bus_index(BUS_VOICE)
	if idx < 0:
		AudioServer.add_bus()
		idx = AudioServer.bus_count - 1
		AudioServer.set_bus_name(idx, String(BUS_VOICE))
	# Send — на активную реверб-шину зоны, иначе дед в подполе звучал бы
	# с ревербом улицы (перевешивание живёт в set_zone).
	AudioServer.set_bus_send(idx, _shot_bus())
	while AudioServer.get_bus_effect_count(idx) > 0:
		AudioServer.remove_bus_effect(idx, 0)
	_voice_hp = AudioEffectHighPassFilter.new()
	_voice_hp.cutoff_hz = 90.0
	AudioServer.add_bus_effect(idx, _voice_hp, 0)
	_voice_lp = AudioEffectLowPassFilter.new()
	_voice_lp.cutoff_hz = 6500.0
	AudioServer.add_bus_effect(idx, _voice_lp, 1)


func _make_bus(bus_name: String, with_reverb: bool) -> int:
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, &"Master")
	if with_reverb:
		AudioServer.add_bus_effect(idx, AudioEffectReverb.new(), 0)
	return idx


func _shot_bus() -> StringName:
	return _bus_rev[_active]


## Шина, на которой сейчас звучат one-shot'ы. Нужна voice.gd: голос ходит
## своими плеерами мимо пула, но зона у него та же, что у всей игры.
func shot_bus() -> StringName:
	return _shot_bus()


## Полоса голоса деда под расстояние. Таблица ступеней — в voice.gd, здесь
## только исполнение: второй руки у AudioServer быть не должно.
func set_voice_distance(highpass_hz: float, lowpass_hz: float) -> void:
	if _voice_hp != null:
		_voice_hp.cutoff_hz = clampf(highpass_hz, 20.0, 2000.0)
	if _voice_lp != null:
		_voice_lp.cutoff_hz = clampf(lowpass_hz, 300.0, 20000.0)


## Есть ли такое имя среди one-shot'ов (запечённых или добавленных оверлеем).
func has_shot(snd: String) -> bool:
	return _shots.has(snd)


# Время спада импульса оригинала: амплитуда шла как (1 - i/len)^decay,
# до −60 дБ она доживает за seconds * (1 - 10^(-3/decay)). Эту длину и
# раскладываем в шкалу Freeverb: 0.25 с — «нет комнаты», 1.5 с — подпол.
static func _room_size_of(preset: Dictionary) -> float:
	var s := float(preset["seconds"])
	var d := maxf(0.1, float(preset["decay"]))
	var t60 := s * (1.0 - pow(10.0, -3.0 / d))
	return clampf((t60 - 0.25) / 1.25, 0.0, 1.0)


# damp — частота среза ФНЧ, которым глушился импульс: чем выше, тем звонче.
# У Freeverb шкала обратная, отсюда единица минус.
static func _damping_of(preset: Dictionary) -> float:
	return clampf(1.0 - float(preset["damp"]) / 5000.0, 0.0, 1.0)


func set_zone(reverb_id: String, fade := 0.4) -> void:
	if zone == reverb_id and _zone_set:
		return
	zone = reverb_id
	_zone_set = true
	var preset: Dictionary = ZONES.get(reverb_id, ZONES["room"])
	var to := 1 - _active
	var rev := _rev[to] as AudioEffectReverb
	if rev != null:
		# Параметры ставим шине, у которой wet ещё ноль: смена room_size
		# на звучащем ревербе слышна как рывок.
		rev.room_size = _room_size_of(preset)
		rev.damping = _damping_of(preset)
		rev.dry = 1.0
		rev.predelay_msec = 20.0
	_wet_target[to] = float(preset["wet"])
	_wet_target[_active] = 0.0
	_wet_tau = maxf(0.02, fade / 3.0)
	_active = to
	if fade <= 0.0:
		_wet[0] = _wet_target[0]
		_wet[1] = _wet_target[1]
		_push_wet()
	# Гул холодильника переезжает на новую шину сразу: сухой тракт у обеих
	# одинаков, щелчка нет, а хвост старой зоны спокойно догорает.
	if _loop_players.has("hum"):
		(_loop_players["hum"] as AudioStreamPlayer).bus = _shot_bus()
	# Голос деда переезжает вместе с гулом: без этого он остался бы навсегда
	# в реверберации той зоны, в которой игрок начал игру.
	var vi := AudioServer.get_bus_index(BUS_VOICE)
	if vi >= 0:
		AudioServer.set_bus_send(vi, _shot_bus())


func _push_wet() -> void:
	for i in 2:
		var rev := _rev[i] as AudioEffectReverb
		if rev != null:
			rev.wet = _wet[i]


# ------------------------------------------------------------- манифест ---

func _load_manifest() -> void:
	var f := FileAccess.open(BAKED + "manifest.json", FileAccess.READ)
	if f == null:
		push_error("нет " + BAKED + "manifest.json — прогнать py tools/bake_audio.py")
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_error("манифест звука не разобран как объект")
		return
	_manifest = parsed
	_gains = _manifest.get("gains", {})
	var shots: Dictionary = _manifest.get("one_shots", {})
	for snd in shots:
		var files: Array = shots[snd]
		var rnd := AudioStreamRandomizer.new()
		# NO_REPEATS: два одинаковых шага подряд слышно сразу, это и было
		# причиной печь по четыре вариации на поверхность.
		rnd.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS
		rnd.random_pitch = PITCH
		rnd.random_volume_offset_db = 0.0
		for fn in files:
			var s := _load_stream(BAKED + String(fn))
			if s != null:
				rnd.add_stream(-1, s)
		if rnd.streams_count > 0:
			_shots[String(snd)] = rnd


# Оверлей записанного поверх запечённого. Не перезапись: audio/baked/ остаётся
# нетронутым, test_audio_manifest сторожит паритет с audio.js и не знает про эту
# папку вовсе. Секции разные по смыслу и не пересекаются:
#   override — имя УЖЕ есть в запечённом: пересобираем вариации, гейн приходит
#              оттуда же (в файле он продублирован, чтобы тест мог сверить);
#   extra    — имени в запечённом НЕТ: новый звук со своим гейном, подобранным
#              вручную — опорного значения у него нет.
# Выключается "enabled": false или удалением папки: без неё игра звучит ровно
# как принятая версия фазы 4.
func _load_sfx_override() -> void:
	var f := FileAccess.open(SFX + "sfx_override.json", FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("sfx_override.json не разобран как объект — оверлей пропущен")
		return
	var d: Dictionary = parsed
	if not bool(d.get("enabled", true)):
		return

	var over: Dictionary = d.get("override", {})
	for snd in over:
		var name := String(snd)
		if not _shots.has(name):
			# Имя из override обязано быть запечённым. Если его нет — оверлей
			# разъехался с манифестом, и молча заводить новый звук нельзя:
			# так в игру попадёт то, чего не было в audio.js.
			push_warning("sfx_override: '" + name + "' нет среди запечённых — пропуск")
			continue
		var rnd := _randomizer_of(over[snd])
		if rnd != null:
			_shots[name] = rnd
			_gains[name] = float((over[snd] as Dictionary).get("gain", _gain_of(name)))

	var extra: Dictionary = d.get("extra", {})
	for snd in extra:
		var name := String(snd)
		if _shots.has(name) or (_manifest.get("loops", {}) as Dictionary).has(name):
			push_warning("sfx_override: extra '" + name + "' занято запечённым — пропуск")
			continue
		var e: Dictionary = extra[snd]
		var gain := float(e.get("gain", 0.0))
		if gain <= 0.0:
			push_warning("sfx_override: у extra '" + name + "' нет gain — пропуск")
			continue
		var files: Array = e.get("files", [])
		if bool(e.get("loop", false)):
			if files.is_empty():
				continue
			_extra_loops[name] = String(files[0])
			_gains[name] = gain
			if name.begins_with("horror-amb-"):
				var loop_stream := _load_stream(SFX + String(files[0])) as AudioStreamWAV
				if loop_stream != null:
					var ready_loop := loop_stream.duplicate() as AudioStreamWAV
					ready_loop.loop_mode = AudioStreamWAV.LOOP_FORWARD
					ready_loop.loop_begin = 0
					ready_loop.loop_end = roundi(ready_loop.get_length() * ready_loop.mix_rate)
					_spatial_loop_streams[name] = ready_loop
			continue
		var rnd := _randomizer_of(e)
		if rnd != null:
			_shots[name] = rnd
			_gains[name] = gain


func _randomizer_of(entry: Variant) -> AudioStreamRandomizer:
	if typeof(entry) != TYPE_DICTIONARY:
		return null
	var files: Array = (entry as Dictionary).get("files", [])
	var rnd := AudioStreamRandomizer.new()
	rnd.playback_mode = AudioStreamRandomizer.PLAYBACK_RANDOM_NO_REPEATS
	rnd.random_pitch = PITCH
	rnd.random_volume_offset_db = 0.0
	for fn in files:
		var s := _load_stream(SFX + String(fn))
		if s != null:
			rnd.add_stream(-1, s)
	return rnd if rnd.streams_count > 0 else null


func _load_stream(path: String) -> AudioStream:
	if not ResourceLoader.exists(path):
		if not _warned:
			_warned = true
			push_warning("звук не импортирован: " + path + " — прогнать Godot --headless --import")
		return null
	return ResourceLoader.load(path) as AudioStream


func _gain_of(snd: String) -> float:
	return float(_gains.get(snd, 1.0))


# --------------------------------------------------------------- голоса ---

func _build_voices() -> void:
	for i in SPATIAL_VOICES:
		var spatial := AudioStreamPlayer3D.new()
		spatial.name = "LocalSound%d" % i
		spatial.bus = &"Dry"
		spatial.unit_size = 8.0
		spatial.max_distance = 32.0
		add_child(spatial)
		_spatial_pool.append(spatial)
		_spatial_owners.append("")
		_spatial_priorities.append(0)
	for i in VOICES:
		var p := AudioStreamPlayer.new()
		p.bus = _shot_bus()
		add_child(p)
		_pool.append(p)
	for i in GEN_VOICES:
		var p := AudioStreamPlayer.new()
		var g := AudioStreamGenerator.new()
		g.mix_rate = SR
		g.buffer_length = 0.25
		p.stream = g
		add_child(p)
		_gen.append({"p": p, "data": PackedVector2Array(), "at": 0, "end": 0.0})


func _take_voice() -> AudioStreamPlayer:
	if _pool.is_empty():
		return null
	for i in _pool.size():
		var p: AudioStreamPlayer = _pool[_next]
		_next = (_next + 1) % _pool.size()
		if not p.playing:
			_drop_fade(p)
			return p
	# Все шестнадцать заняты — забираем самый старый по кругу.
	var q: AudioStreamPlayer = _pool[_next]
	_next = (_next + 1) % _pool.size()
	_drop_fade(q)
	q.stop()
	return q


func _play_one(snd: String, gain := 1.0, bus := &"") -> AudioStreamPlayer:
	if not _shots.has(snd):
		return null
	var p := _take_voice()
	if p == null:
		return null
	p.stream = _shots[snd]
	p.bus = _shot_bus() if bus == &"" else bus
	p.pitch_scale = 1.0
	p.volume_db = linear_to_db(clampf(gain * _gain_of(snd), 0.00001, 4.0))
	p.play()
	return p


func _loop_player(snd: String) -> AudioStreamPlayer:
	if _loop_players.has(snd):
		return _loop_players[snd]
	var loops: Dictionary = _manifest.get("loops", {})
	var path := ""
	if loops.has(snd):
		path = BAKED + String(loops[snd])
	elif _extra_loops.has(snd):
		path = SFX + String(_extra_loops[snd])
	else:
		return null
	var s := _load_stream(path)
	var w := s as AudioStreamWAV
	if w == null:
		return null
	# Импортёр петлю не ставит (в файле нет чанка smpl), а сшиты файлы уже
	# при запекании — петля идёт по всей длине.
	w.loop_mode = AudioStreamWAV.LOOP_FORWARD
	w.loop_begin = 0
	w.loop_end = int(round(w.get_length() * float(w.mix_rate)))
	var p := AudioStreamPlayer.new()
	p.stream = w
	p.bus = &"Dry"
	p.volume_db = linear_to_db(0.0001)
	add_child(p)
	_loop_players[snd] = p
	return p


# ---------------------------------------------------------- огибающие ---

func _fade_to(p: AudioStreamPlayer, target: float, tau: float, stop_after := -1.0) -> void:
	for f in _fades:
		if f["p"] == p:
			f["target"] = target
			f["tau"] = tau
			f["stop"] = stop_after
			return
	_fades.append({"p": p, "cur": db_to_linear(p.volume_db), "target": target,
		"tau": tau, "stop": stop_after})


func _drop_fade(p: AudioStreamPlayer) -> void:
	for i in range(_fades.size() - 1, -1, -1):
		if _fades[i]["p"] == p:
			_fades.remove_at(i)


## Отложенный вызов по расписанию звука. Тот же setTimeout оригинала: идёт и на
## паузе, потому что тишину делает mute(), а не остановка часов.
func after(seconds: float, cb: Callable) -> void:
	_after(seconds, cb)


func _after(seconds: float, cb: Callable) -> void:
	if seconds <= 0.0:
		cb.call()
		return
	_timers.append([seconds, cb])


# ------------------------------------------------------------ громкость ---

func arm() -> bool:
	# В браузере это был обязательный resume() из жеста. В Godot контекст живой
	# всегда, метод оставлен ради вызовов из main.js и как признак готовности.
	return armed


func set_volume(v: float) -> void:
	volume = v
	_master_tau = 0.05


func mute(on: bool) -> void:
	muted = on
	_master_tau = 0.08


func suspend_all() -> void:
	mute(true)


func resume_all() -> void:
	mute(false)


# ------------------------------------------------------- готовые звуки ---

func click() -> void:
	_play_one("click")


func step(surface := "wood", run := false, crouch := false) -> void:
	var g := (0.05 if crouch else (0.16 if run else 0.10)) * (0.85 + randf() * 0.3)
	var key := "step-wood"
	match surface:
		"grass":
			key = "step-grass"
		"gravel":
			key = "step-gravel"
		"dirt":
			key = "step-dirt"
		"concrete":
			key = "step-concrete"
		"water":
			key = "step-water"
	_play_one(key, g)
	# Половица скрипит под каждым шестым шагом по доскам — отдельным вызовом,
	# иначе шестая часть шагов звучала бы одним и тем же файлом.
	if key == "step-wood" and randf() < 0.16:
		creak(0.5)


func creak(strength := 1.0) -> void:
	var key := "creak-mid"
	var bucket := CREAK_MID
	if strength <= 0.75:
		key = "creak-soft"
		bucket = CREAK_SOFT
	elif strength >= 1.2:
		key = "creak-hard"
		bucket = CREAK_HARD
	_play_one(key, strength / bucket)


func knock(times := 1, spacing := 0.18) -> void:
	for i in times:
		var cb := func() -> void: _play_one("knock")
		_after(i * spacing, cb)


func door(open := true) -> void:
	# Щелчок язычка через 620 мс запечён в тот же файл: это одно событие.
	_play_one("door-open" if open else "door-close")


func chain() -> void:
	_play_one("chain")


func stinger(power := 1.0) -> void:
	_play_one("stinger", power)


func rewind(seconds := 1.2) -> void:
	var best := "rewind-12"
	var bd := 1e9
	for k in REWIND:
		var d: float = absf(float(REWIND[k]) - seconds)
		if d < bd:
			bd = d
			best = String(k)
	_play_one(best)


func tape_click() -> void:
	_play_one("tape-click")


func clock_chime(times := 1) -> void:
	for i in times:
		var cb := func() -> void: _play_one("chime")
		_after(i * 1.4, cb)


func heartbeat(times := 4, bpm := 96.0) -> void:
	var gap := 60.0 / bpm
	for i in times:
		var cb := func() -> void: _play_one("heartbeat")
		_after(i * gap, cb)


func steps_above(count := 4) -> void:
	# Шаги наверху. Не HRTF: в оригинале элевацию всё равно не читали.
	for i in count:
		var cb := func() -> void: _play_one("steps-above")
		_after(i * (0.480 + randf() * 0.160), cb)


func dog_far() -> void:
	var n := 2 + int(randf() * 3.0)
	for i in n:
		var cb := func() -> void: _play_one("dog")
		_after(i * 0.3, cb)


func distant_train() -> void:
	# Гудок через 2.6 с — часть того же файла.
	_play_one("train")


func mumble(seconds := 1.4) -> void:
	# Голос из темноты: слов не разобрать, полоса 300–3400. Постель запечена
	# трёхсекундной, огибающая — здесь: длительность приходит из диалогов.
	var p := _play_one("mumble", 0.0001)
	if p == null:
		return
	_fade_to(p, MUMBLE_LEVEL * _gain_of("mumble"), 0.12)
	var cb := func() -> void:
		if is_instance_valid(p) and p.playing:
			_fade_to(p, 0.0, 0.15, 0.3 * seconds + 0.4)
	_after(seconds * 0.7, cb)


# ----------------------------------------------------------------- лупы ---

func _start_loop(snd: String, bus: StringName, level: float, tau: float) -> void:
	if _loop_on.get(snd, false):
		return
	var p := _loop_player(snd)
	if p == null:
		return
	_loop_on[snd] = true
	p.bus = bus
	if not p.playing:
		p.volume_db = linear_to_db(0.0001)
		p.play()
	_fade_to(p, level * _gain_of(snd), tau)


func _stop_loop(snd: String, tau: float, stop_after: float) -> void:
	if not _loop_on.get(snd, false):
		return
	_loop_on[snd] = false
	var p: AudioStreamPlayer = _loop_players.get(snd)
	if p == null:
		return
	_fade_to(p, 0.0, tau, stop_after)


# Гул холодильника. Самый важный звук игры: он обрывается в 23:40.
func start_hum() -> void:
	_start_loop("hum", _shot_bus(), HUM_LEVEL, 1.2)


func stop_hum(fade := 0.05) -> void:
	# Останов позже спада: setTargetAtTime доходит до нуля асимптотически.
	_stop_loop("hum", fade, fade * 6.0 + 0.2)


# Сверчки идут прямо в master мимо реверба — как в оригинале.
func start_outdoors() -> void:
	_start_loop("crickets", &"Dry", CRICKETS_LEVEL * _outdoor, 2.0)


func set_outdoor_level(v: float) -> void:
	_outdoor = v
	if _loop_on.get("crickets", false):
		var p: AudioStreamPlayer = _loop_players.get("crickets")
		if p != null:
			_fade_to(p, CRICKETS_LEVEL * v * _gain_of("crickets"), 0.6)


# Постель просмотра кассеты: шипение ленты и сетевой фон 50 Гц. Мимо реверба:
# звук рождается в динамике телевизора, отражаться ему негде.
func tape_bed(on: bool) -> void:
	if on:
		_start_loop("tape-bed", &"Dry", TAPE_LEVEL, 0.35)
	else:
		# 0.25 с: обрыв в ноль даёт щелчок, секунда слышится как «ещё крутится».
		_stop_loop("tape-bed", 0.25, 1.6)


func phone_bed(on: bool) -> void:
	if on:
		_start_loop("phone-bed", &"Dry", PHONE_LEVEL, 0.2)
	else:
		_stop_loop("phone-bed", 0.12, 0.9)


func loop(snd: String, on: bool) -> void:
	match snd:
		"hum":
			if on: start_hum()
			else: stop_hum()
		"crickets", "outdoors":
			if on: start_outdoors()
			else: _stop_loop("crickets", 0.6, 4.0)
		"tape-bed", "tape":
			tape_bed(on)
		"phone-bed", "phone":
			phone_bed(on)
		_:
			# Лупы оверлея (дыхание пустого дома под тишину главы ТЕМНОТА).
			# Заходят и выходят медленно: этот звук не должен иметь начала.
			if _extra_loops.has(snd):
				if on:
					_start_loop(snd, &"Dry", 1.0, 2.5)
				else:
					_stop_loop(snd, 1.2, 7.0)
			else:
				push_warning("audio.loop: неизвестный луп " + snd)


## Звук из оверлея. Отдельно от play(): play() пишет предупреждение на
## неизвестное имя, а здесь отсутствие файла — штатный случай (папки sfx нет —
## игра звучит как принятая версия фазы 4). Возвращает, прозвучало ли.
func sfx(snd: String, gain := 1.0, bus := &"") -> bool:
	if not _shots.has(snd):
		return false
	return _play_one(snd, gain, bus) != null


# Шесть местных источников и два отдельных фоновых канала.
# Отдельная пауза сохраняет позицию воспроизведения под меню и ридером.
# Пользовательская громкость по-прежнему действует через Master.
func spatial_sfx(snd: String, at: Vector3, gain := 1.0, distance := 32.0, owner := "", priority := 0) -> bool:
	if not _shots.has(snd): return false
	return spatial_stream(_shots[snd], at, gain * _gain_of(snd), distance, owner, priority)


func spatial_stream(stream: AudioStream, at: Vector3, gain := 1.0, distance := 32.0, owner := "", priority := 0) -> bool:
	if stream == null or _spatial_pool.is_empty():
		return false
	var voice: AudioStreamPlayer3D = null
	var shot_count := _spatial_pool.size() - SPATIAL_LOOP_VOICES
	for offset in shot_count:
		var index := SPATIAL_LOOP_VOICES + ((_spatial_next + offset) % shot_count)
		if is_instance_valid(_spatial_pool[index]) and not _spatial_pool[index].playing:
			voice = _spatial_pool[index]
			_spatial_next = (index - SPATIAL_LOOP_VOICES + 1) % shot_count
			break
	if voice == null:
		var lowest := priority + 1
		var selected := -1
		for offset in shot_count:
			var index := SPATIAL_LOOP_VOICES + ((_spatial_next + offset) % shot_count)
			if _spatial_priorities[index] < lowest:
				lowest = _spatial_priorities[index]
				selected = index
		if selected < 0: return false
		voice = _spatial_pool[selected]
		_spatial_next = (selected - SPATIAL_LOOP_VOICES + 1) % shot_count
	if not is_instance_valid(voice):
		return false
	voice.stop()
	# Владение относится к текущему запуску голоса. Повторное использование
	# слота стирает прежнего владельца, чтобы его stop не погасил чужой звук.
	_spatial_owners[_spatial_pool.find(voice)] = owner
	_spatial_priorities[_spatial_pool.find(voice)] = priority
	voice.stream = stream
	voice.pitch_scale = 1.0
	voice.global_position = at
	voice.max_distance = maxf(1.0, distance)
	voice.volume_db = linear_to_db(clampf(gain, 0.00001, 4.0))
	voice.play()
	voice.stream_paused = _spatial_dialogue_paused if owner == "dialogue:spatial" else _spatial_paused
	return true


func spatial_owner_active(owner: String) -> bool:
	if owner.is_empty(): return false
	for index in _spatial_owners.size():
		if _spatial_owners[index] == owner and is_instance_valid(_spatial_pool[index]) and _spatial_pool[index].playing:
			return true
	return false


func stop_spatial_owner(owner: String) -> void:
	if owner.is_empty(): return
	for index in _spatial_owners.size():
		if _spatial_owners[index] == owner:
			if is_instance_valid(_spatial_pool[index]): _spatial_pool[index].stop()
			_spatial_owners[index] = ""
			_spatial_priorities[index] = 0


## Два голоса из общего пула отведены под местную атмосферу.
## Потоки подготовлены при загрузке; смена зоны не читает файл с диска.
func spatial_loop(snd: String, at: Vector3, on: bool, gain := 1.0, distance := 24.0) -> bool:
	var slot := _spatial_loop_names.find(snd)
	if not on:
		if slot >= 0:
			_spatial_loop_targets[slot] = 0.0
		return slot >= 0
	if not _spatial_loop_streams.has(snd) or _spatial_pool.size() < SPATIAL_LOOP_VOICES:
		return false
	if slot < 0:
		slot = _spatial_loop_names.find("")
		if slot < 0:
			return false
		_spatial_loop_names[slot] = snd
		var start := _spatial_pool[slot]
		start.stream = _spatial_loop_streams[snd]
		start.volume_db = -80.0
		start.play()
		start.stream_paused = _spatial_paused
	var voice := _spatial_pool[slot]
	voice.global_position = at
	voice.max_distance = maxf(1.0, distance)
	_spatial_loop_targets[slot] = clampf(gain * _gain_of(snd), 0.0, 1.0)
	return true


func _tick_spatial_loops(delta: float) -> void:
	if _spatial_paused:
		return
	for slot in SPATIAL_LOOP_VOICES:
		if _spatial_loop_names[slot] == "" or slot >= _spatial_pool.size():
			continue
		var voice := _spatial_pool[slot]
		var target := float(_spatial_loop_targets[slot])
		var current := db_to_linear(voice.volume_db)
		current = lerpf(current, target, 1.0 - exp(-delta / 0.65))
		voice.volume_db = linear_to_db(maxf(0.00001, current))
		if target <= 0.0 and current < 0.0001:
			voice.stop()
			_spatial_loop_names[slot] = ""


func bind_spatial_world(world_root: Node3D) -> void:
	if not is_instance_valid(world_root):
		return
	for voice: AudioStreamPlayer3D in _spatial_pool:
		if is_instance_valid(voice) and voice.get_parent() != world_root:
			voice.reparent(world_root)


func set_spatial_paused(paused: bool, pause_dialogue := true) -> void:
	_spatial_paused = paused
	_spatial_dialogue_paused = paused and pause_dialogue
	# AudioStreamPlayer3D запускает поток на физическом тике. Первый play()
	# может завершиться после смены паузы, поэтому сверяем каждый голос.
	for index in _spatial_pool.size():
		var voice := _spatial_pool[index]
		var wanted := _spatial_dialogue_paused if _spatial_owners[index] == "dialogue:spatial" else paused
		if is_instance_valid(voice) and voice.stream_paused != wanted:
			voice.stream_paused = wanted


func clear_spatial() -> void:
	for voice: AudioStreamPlayer3D in _spatial_pool:
		if is_instance_valid(voice):
			voice.stop()
	_spatial_next = 0
	_spatial_owners.fill("")
	_spatial_priorities.fill(0)
	_spatial_loop_names = ["", ""]
	_spatial_loop_targets = [0.0, 0.0]


func play(snd: String, gain := 1.0) -> void:
	if _shots.has(snd):
		_play_one(snd, gain)
	elif (_manifest.get("loops", {}) as Dictionary).has(snd) or _extra_loops.has(snd):
		loop(snd, true)
	else:
		push_warning("audio.play: неизвестный звук " + snd)


# -------------------------------------------------- рантайм-синтез ---
# tone() и noise() — единственное, что не запечено: параметры приходят живьём.
# Формулы те же, что в bake_audio.py, только считаются по одному сэмплу.

func tone(params: Dictionary) -> void:
	var freq := maxf(1.0, float(params.get("freq", 220.0)))
	var to_v: Variant = params.get("to", null)
	var dur := float(params.get("dur", 0.3))
	var gain := float(params.get("gain", 0.12))
	var kind := String(params.get("type", "sine"))
	var attack := float(params.get("attack", 0.005))
	var n := int((dur + 0.05) * SR)
	if n <= 0:
		return
	var data := PackedVector2Array()
	data.resize(n)
	var tgt := freq
	if to_v != null:
		tgt = maxf(20.0, float(to_v))

	# ФАЗА 9: цикл переписан на инкременты. Он крутился 28 тысяч раз В ОДНОМ
	# КАДРЕ и держал в себе три трансцендентные функции и сравнение строк
	# на сэмпл — замер дал 120 мс на один вызов, то есть семь потерянных кадров
	# ровно там, где звучит склейка кассеты.
	#
	# Ничего не «упрощено на слух»: и рампа частоты, и огибающая — это
	# ГЕОМЕТРИЧЕСКИЕ ПРОГРЕССИИ по номеру сэмпла (a^(i/N) = (a^(1/N))^i),
	# поэтому pow на каждом шаге заменяется одним умножением на постоянный
	# множитель. Разница с прежней формулой — накопление float на 28 тысячах
	# шагов, порядка 1e-12 относительной, то есть ноль.
	var w := _wave_kind(kind)
	var ir := maxf(1.0, dur * 0.85 * SR)          # сэмплов на рампу частоты
	var kf := pow(tgt / freq, 1.0 / ir) if to_v != null else 1.0
	var f := freq
	var step := TAU / SR

	var g := maxf(2e-4, gain)
	var e0 := 1e-4
	var a := clampf(attack, 1e-4, dur * 0.9)
	var ia := maxf(1.0, a * SR)                   # сэмплов на атаку
	var idec := maxf(1.0, maxf(dur - a, 1e-4) * SR)
	var k_up := pow(g / e0, 1.0 / ia)
	var k_dn := pow(e0 / g, 1.0 / idec)
	var env := e0

	var phase := 0.0
	for i in n:
		phase += step * f
		var s := 0.0
		match w:
			0:
				s = sin(phase)
			1:
				s = 1.0 if fposmod(phase, TAU) < PI else -1.0
			2:
				s = 2.0 * (fposmod(phase, TAU) / TAU) - 1.0
			_:
				s = 4.0 * absf(fposmod(phase, TAU) / TAU - 0.5) - 1.0
		var v := s * env
		data[i] = Vector2(v, v)
		# Следующий сэмпл: обе прогрессии шагают одним умножением.
		if float(i + 1) <= ir:
			f *= kf
		else:
			f = tgt
		if float(i + 1) <= ia:
			env = minf(g, env * k_up)
		else:
			env = maxf(e0, env * k_dn)
	_gen_play(data, dur + 0.05)


# Форма волны числом, а не строкой: сравнение String в цикле на 28 тысяч
# итераций стоит больше самой волны.
static func _wave_kind(kind: String) -> int:
	if kind == "square":
		return 1
	if kind == "sawtooth":
		return 2
	if kind == "triangle":
		return 3
	return 0


func noise(params: Dictionary) -> void:
	var dur := float(params.get("dur", 0.2))
	var gain := float(params.get("gain", 0.2))
	var kind := String(params.get("type", "bandpass"))
	var freq := float(params.get("freq", 900.0))
	var q := float(params.get("q", 1.2))
	var sweep := float(params.get("sweep", 0.0))
	var attack := float(params.get("attack", 0.004))
	var n := int((dur + 0.05) * SR)
	if n <= 0:
		return
	var data := PackedVector2Array()
	data.resize(n)
	var end_f := freq
	if sweep != 0.0:
		end_f = maxf(60.0, freq + sweep)
	var c := _biquad(kind, freq, q)
	var z1 := 0.0
	var z2 := 0.0

	# Огибающая — инкрементом, по той же причине и той же арифметике, что
	# в tone() выше: pow на каждом сэмпле стоил здесь тридцати миллисекунд
	# на один всплеск, а всплесков у банок в тайнике три подряд.
	var g := maxf(2e-4, gain)
	var e0 := 1e-4
	var a := clampf(attack, 1e-4, dur * 0.9)
	var ia := maxf(1.0, a * SR)
	var idec := maxf(1.0, maxf(dur - a, 1e-4) * SR)
	var k_up := pow(g / e0, 1.0 / ia)
	var k_dn := pow(e0 / g, 1.0 / idec)
	var env := e0

	# Коэффициенты фильтра читаются как обычные float, а не через индексацию
	# PackedFloat64Array на каждом сэмпле.
	var c0: float = c[0]
	var c1: float = c[1]
	var c2: float = c[2]
	var c3: float = c[3]
	var c4: float = c[4]
	for i in n:
		# Коэффициенты пересчитываются блоками по 64 сэмпла — так же поблочно
		# их обновлял WebAudio, поэтому свипы звучат одинаково.
		if sweep != 0.0 and i % 64 == 0:
			c = _biquad(kind, lerpf(freq, end_f, clampf(float(i) / SR / dur, 0.0, 1.0)), q)
			c0 = c[0]; c1 = c[1]; c2 = c[2]; c3 = c[3]; c4 = c[4]
		var x := randf() * 2.0 - 1.0
		var y := c0 * x + z1
		z1 = c1 * x - c3 * y + z2
		z2 = c2 * x - c4 * y
		var v := y * env
		data[i] = Vector2(v, v)
		if float(i + 1) <= ia:
			env = minf(g, env * k_up)
		else:
			env = maxf(e0, env * k_dn)
	_gen_play(data, dur + 0.05)


# Наивные формы вместо суммы гармоник: у самого длинного рантайм-тона (крик
# из main.js, 0.75 с) алиасинг слышен как лёгкая грязь, а полтораста гармоник
# на сэмпл стоили бы кадра. Всё, что звучит на переднем плане, запечено.
static func _wave(kind: String, phase: float) -> float:
	if kind == "sine":
		return sin(phase)
	var x := fposmod(phase, TAU) / TAU
	if kind == "square":
		return 1.0 if x < 0.5 else -1.0
	if kind == "sawtooth":
		return 2.0 * x - 1.0
	if kind == "triangle":
		return 4.0 * absf(x - 0.5) - 1.0
	return sin(phase)


# Огибающая audio.js: 1e-4 → gain за attack → обратно к 1e-4 к dur, обе ветки
# экспоненциальные. «Дно» 1e-4 — оттуда же, звук не обрывается в ноль.
static func _env(t: float, attack: float, dur: float, gain: float) -> float:
	var g := maxf(2e-4, gain)
	var e := 1e-4
	var a := clampf(attack, 1e-4, dur * 0.9)
	if t <= a:
		return e * pow(g / e, clampf(t / a, 0.0, 1.0))
	return g * pow(e / g, clampf((t - a) / maxf(dur - a, 1e-4), 0.0, 1.0))


# RBJ-биквад в нормировке WebAudio: у lowpass/highpass Q задан в децибелах,
# у bandpass — обычная добротность. Пакованный массив, а не обычный: из него
# читаются float, а не Variant, иначе тип в цикле фильтра не выводится.
static func _biquad(ftype: String, f0: float, q: float) -> PackedFloat64Array:
	var f := clampf(f0, 10.0, SR * 0.49)
	var w0 := TAU * f / SR
	var cw := cos(w0)
	var sw := sin(w0)
	var qq := q
	if ftype == "lowpass" or ftype == "highpass":
		qq = pow(10.0, q / 20.0)
	var alpha := sw / (2.0 * maxf(qq, 1e-4))
	var b0 := alpha
	var b1 := 0.0
	var b2 := -alpha
	if ftype == "lowpass":
		b0 = (1.0 - cw) * 0.5
		b1 = 1.0 - cw
		b2 = (1.0 - cw) * 0.5
	elif ftype == "highpass":
		b0 = (1.0 + cw) * 0.5
		b1 = -(1.0 + cw)
		b2 = (1.0 + cw) * 0.5
	var a0 := 1.0 + alpha
	return PackedFloat64Array([b0 / a0, b1 / a0, b2 / a0, (-2.0 * cw) / a0, (1.0 - alpha) / a0])


func _gen_play(data: PackedVector2Array, seconds: float) -> void:
	if _gen.is_empty():
		return
	var v: Dictionary = _gen[_gen_next]
	_gen_next = (_gen_next + 1) % _gen.size()
	var p: AudioStreamPlayer = v["p"]
	p.stop()
	p.bus = _shot_bus()
	p.volume_db = 0.0
	p.play()
	v["data"] = data
	v["at"] = 0
	v["end"] = seconds + 0.2
	_push_gen(v)


func _push_gen(v: Dictionary) -> void:
	var data: PackedVector2Array = v["data"]
	if data.is_empty():
		return
	var p: AudioStreamPlayer = v["p"]
	var pb := p.get_stream_playback() as AudioStreamGeneratorPlayback
	if pb == null:
		v["data"] = PackedVector2Array()
		return
	var at: int = v["at"]
	var n := mini(pb.get_frames_available(), data.size() - at)
	if n > 0:
		pb.push_buffer(data.slice(at, at + n))
		at += n
		v["at"] = at
	if at >= data.size():
		v["data"] = PackedVector2Array()
		v["at"] = 0


# ------------------------------------------------------------------ тик ---

func _process(delta: float) -> void:
	_tick_spatial_loops(delta)
	_tick_master(delta)
	_tick_wet(delta)
	_tick_timers(delta)
	_tick_fades(delta)
	for v in _gen:
		_push_gen(v)
		if float(v["end"]) > 0.0:
			v["end"] = float(v["end"]) - delta
			if float(v["end"]) <= 0.0:
				(v["p"] as AudioStreamPlayer).stop()


func _tick_master(delta: float) -> void:
	var target := 0.0 if muted else volume
	if absf(_master - target) < 0.0002:
		if _master != target:
			_master = target
			AudioServer.set_bus_volume_db(0, linear_to_db(maxf(_master, 0.0001)))
		return
	_master += (target - _master) * (1.0 - exp(-delta / _master_tau))
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(_master, 0.0001)))


func _tick_wet(delta: float) -> void:
	var moved := false
	for i in 2:
		var d: float = float(_wet_target[i]) - float(_wet[i])
		if absf(d) > 0.0002:
			_wet[i] = float(_wet[i]) + d * (1.0 - exp(-delta / _wet_tau))
			moved = true
		elif _wet[i] != _wet_target[i]:
			_wet[i] = _wet_target[i]
			moved = true
	if moved:
		_push_wet()


func _tick_timers(delta: float) -> void:
	# Идём с конца: обработчик может добавить новый таймер, и он не должен
	# сработать в этом же кадре.
	for i in range(_timers.size() - 1, -1, -1):
		var e: Array = _timers[i]
		e[0] = float(e[0]) - delta
		if float(e[0]) <= 0.0:
			_timers.remove_at(i)
			var cb: Callable = e[1]
			if cb.is_valid():
				cb.call()


func _tick_fades(delta: float) -> void:
	for i in range(_fades.size() - 1, -1, -1):
		var f: Dictionary = _fades[i]
		var p: AudioStreamPlayer = f["p"]
		if not is_instance_valid(p):
			_fades.remove_at(i)
			continue
		var cur: float = float(f["cur"])
		cur += (float(f["target"]) - cur) * (1.0 - exp(-delta / maxf(0.01, float(f["tau"]))))
		f["cur"] = cur
		p.volume_db = linear_to_db(maxf(cur, 0.00001))
		var stop: float = float(f["stop"])
		if stop > 0.0:
			stop -= delta
			f["stop"] = stop
			if stop <= 0.0:
				p.stop()
				_fades.remove_at(i)

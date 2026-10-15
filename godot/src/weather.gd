# Погода: дождь и гроза (фаза 15).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ МОДУЛЬ И ПОЧЕМУ ОН ТАКОЙ ТОНКИЙ. Партиклов в проекте нет,
# и заводить их ради дождя незачем: экранный слой уже считается в буфере
# 982x540, а капли, посчитанные там, проходят через скан-линии, зерно
# и виньетку — то есть выглядят снятыми на ту же плёнку, что двор. Всё,
# что делает этот файл, — держит три числа и раздаёт их тем, у кого они
# рисуются: uniform "rain" композита, энергия луны и звук.
#
# ЧТО ЗДЕСЬ НЕЛЬЗЯ. Синтезировать звук на лету. audio.tone стоит 10 мс
# в одном кадре (tests/bench_frame.gd), и раскат грома, посчитанный
# на месте, — это гарантированный рывок ровно в тот момент, когда игрок
# бежит к машине. Дождь и гром берутся готовыми файлами через audio.loop
# и audio.sfx; нет файлов — модуль работает молча, и это штатный откат.
#
# ПОМЕЩЕНИЕ. Полосы в кадре гасятся до INDOOR_MIX, а не в ноль: дождь видно
# в окно, слышно по крыше, и полная тишина в доме читалась бы как «дождь
# кончился». Решает не геометрия, а реверберация зоны — тот же признак,
# по которому main.gd переключает шину звука.

class_name Weather
extends RefCounted

## Сколько дождя остаётся в помещении и как быстро он набирает силу.
const INDOOR_MIX := 0.16
const RISE := 0.55            # долей силы в секунду при усилении
const FALL := 0.30            # и при затихании — дождь стихает медленнее
const FLASH_HOLD := 0.06      # сколько держится вспышка, секунд
const FLASH_FALL := 2.6       # и с какой скоростью гаснет

var chain: RenderChain = null
var lights: LightRig = null
var audio: GameAudio = null

var rain_target := 0.0        # сколько дождя просит сюжет, 0..1
var _rain := 0.0              # сколько его в кадре сейчас
var _looping := false
var _flash := 0.0             # добавка к энергии луны
var _hold := 0.0
var _thunder_in := 0.0        # через сколько секунд раскат после вспышки


func _init(render_chain: RenderChain = null, light_rig: LightRig = null,
		game_audio: GameAudio = null) -> void:
	chain = render_chain
	lights = light_rig
	audio = game_audio


## Сколько лить. 0 — сухо, 1 — стена воды. Ставится главой и живёт до отмены.
func set_rain(v: float) -> void:
	rain_target = clampf(v, 0.0, 1.0)


func rain_now() -> float:
	return _rain


## Разряд: вспышка и раскат следом. Задержка между ними не украшение —
## по ней читается расстояние до грозы, и «сверкнуло и сразу грохнуло»
## означает «над головой». delay в секундах.
func storm(strength := 1.0, delay := 1.1) -> void:
	_flash = maxf(_flash, clampf(strength, 0.0, 1.5))
	_hold = FLASH_HOLD
	_thunder_in = maxf(0.05, delay)


## Всё выключить разом: конец главы, откат, титры.
func clear() -> void:
	rain_target = 0.0
	_rain = 0.0
	_flash = 0.0
	_hold = 0.0
	_thunder_in = 0.0
	if chain != null:
		chain.set_vhs(&"rain", 0.0)
	if _looping and audio != null:
		audio.loop("rain", false)
	_looping = false


func update(dt: float, outdoor: bool) -> void:
	# Сила дождя в кадре: цель, приглушённая помещением. Ползёт, а не
	# прыгает, — иначе на пороге дома кадр щёлкает.
	var want := rain_target * (1.0 if outdoor else INDOOR_MIX)
	var rate := RISE if want > _rain else FALL
	_rain = move_toward(_rain, want, rate * dt)
	if chain != null:
		chain.set_vhs(&"rain", _rain)

	# Луп дождя заводится один раз и по самому факту дождя, а не по силе:
	# громкость шины уже правит main.gd по той же зоне, что и реверберацию.
	if audio != null:
		var on := rain_target > 0.01
		if on != _looping:
			_looping = on
			audio.loop("rain", on)

	# Вспышка: держится мгновение и гаснет. Прибавка идёт ПОВЕРХ того, что
	# посчитал lights.update() в этом же кадре, поэтому порядок в main.gd
	# обязателен — сначала свет, потом погода.
	if _hold > 0.0:
		_hold -= dt
	elif _flash > 0.0:
		_flash = maxf(0.0, _flash - FLASH_FALL * dt)
	if lights != null and lights.moon != null and _flash > 0.0:
		lights.moon.light_energy += _flash

	if _thunder_in > 0.0:
		_thunder_in -= dt
		if _thunder_in <= 0.0:
			_thunder_in = 0.0
			if audio != null:
				audio.sfx("thunder")

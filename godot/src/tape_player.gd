# Плеер кассет. Порт src/ui/tape.js.
#
# Кадр собирается на поле 320x240 и уходит НЕ на экран, а в композит: кассета
# идёт тем же шейдером, что и игра, — бочка кинескопа, аберрация, скан-линии,
# зерно, виньетка, fade и трекинг достаются даром. Раньше (в браузере до
# переписывания) оверлей .tape лежал поверх шейдера, и запись двадцатилетней
# давности выглядела чище самого дома — задом наперёд.
#
# На поле живёт то, что шейдеру мира не поручить: монтажные склейки, движение
# камеры внутри кадра, wow/flutter, выпадения ленты, продольные царапины
# и экранное меню камкордера. Меню записано НА ленту, поэтому оно внутри кадра
# и получает все артефакты наравне с картинкой; надписи видеомагнитофона
# («▶ PLAY», счётчик, субтитр, подсказка клавиши) — это уже сам аппарат,
# они живут отдельным слоем поверх composite и к записи отношения не имеют.
#
# ЦЕПОЧКА ВЬЮПОРТОВ. В браузере было две канвы: чистый кадр и видимая.
# Здесь их три этажа, потому что попиксельные эффекты считает шейдер, а он
# обязан читать уже собранный кадр:
#
#   CleanView (320x240)  — чистый кадр: фотография либо процедурная сцена.
#     -> BlitView (320x240) — 24 полосы wow/flutter (материал снимает цвет
#        в ночном режиме), поверх меню камкордера, царапины, выпадения, трекинг.
#       -> TapeView (RenderChain) — TextureRect с tape_fx.gdshader: зерно,
#          строчки, сдвиг полосы головок, виньетка; поверх — чернота и шум
#          самой полосы головок.
#
# Вне просмотра оба своих вьюпорта стоят в UPDATE_DISABLED (третий гасит
# RenderChain.end_tape_mode): игрок может не найти ни одной кассеты за всю
# игру, и платить за это кадрами в секунду он не должен.
#
# Растровые кадры (assets/tape/*.webp) грузятся лениво и по одному. Файла нет —
# сцена рисуется процедурно теми же SCENES, что были до кадров: тридцать WebP
# не должны становиться условием запуска.
#
# Игра запоминает, досмотрел ли игрок до конца: остановленная на середине
# кассета не засчитывается.
#
# RefCounted, а не Node: у Node занято имя show(), а у оригинала плеер —
# обычный объект, который main.js держит полем.

class_name TapePlayer
extends RefCounted

const W := 320.0
const H := 240.0
const TAPE_SIZE := Vector2i(320, 240)

# Строк перекоммутации головок у нижней кромки.
const HEAD := 8.0

# Слой надписей аппарата. Ниже скримера (4) и выше кадра (-1): лицо при поимке
# не должно оказаться под субтитром кассеты.
const LAYER := 3

# Размеры и цвета HUD видеомагнитофона — из style.css (.tape__hud, .tape__sub,
# .tape__hint). Корневой кегль браузера 16px, поэтому rem пересчитаны в пиксели;
# растяжения окна в проекте нет, так что пиксель CSS равен пикселю окна.
const HUD_SIZE := 14        # 0.86rem
const HUD_TRACK := 3        # letter-spacing 0.2em
const SUB_SIZE := 16        # 1rem
const HINT_SIZE := 11       # 0.7rem
const HINT_TRACK := 2
const HUD_INK := Color(233.0 / 255.0, 228.0 / 255.0, 212.0 / 255.0)
const SUB_INK := Color(244.0 / 255.0, 239.0 / 255.0, 226.0 / 255.0)
const HINT_INK := Color(141.0 / 255.0, 136.0 / 255.0, 123.0 / 255.0)

# Фаза 8. Ремарка — описание кадра, и голоса у неё больше нет
# (gen_voice.TAPE_REMARKS_VOICED). Приглушённый цвет говорит об этом с первой
# плёнки: прямую речь озвучивают, скобки читают глазами.
const REMARK_INK := Color(0.72, 0.70, 0.64)

var audio: GameAudio = null
var renderer: RenderChain = null
var voice: GameVoice = null

# Поля состояния — как в оригинале: их читает main.gd (open) и по ним же
# сверяется порядок событий.
var open := false
var tape: Dictionary = {}
var tapeId := ""
var t := 0.0
var sub := ""
var code := ""
var scene := "dark"
var acts: Array = []
var fx := 0.0
var finished := false
var gl := false

# Монтаж: список кадров текущей сцены, номер текущего и время последней склейки.
var reel: Array = []
var reelAt := 0
var cutAt := 0.0

var scratches: Array = []
var clock0 := 0.0
var counter0 := 0.0

var _on_done := Callable()
var _cursor := 0
var _wow := 1.1              # амплитуда wow/flutter текущего кадра, её берёт и меню
var _track0 := 0.0
var _mode_text := "▶ PLAY"

# --- перемотка (фаза 13) ---
#
# Пётр: «кассету нельзя промотать — либо скипнуть, либо ускорить». Ввод плеер
# читает ОПРОСОМ, прямо здесь, и это не лень, а единственный способ ничего не
# сломать: main.gd на время кассеты глушит весь остальной ввод одним `return`
# (`if tape_player.open: ... return`), и добавлять туда ветки значит трогать
# файл, который в этой фазе не трогается вовсе. Input.is_action_pressed()
# спрашивает состояние клавиатуры напрямую и про этот `return` не знает.
#
# Обратной перемотки НЕТ, и это не забывчивость. Курсор `_cursor` односторонний
# по построению: он идёт по отсортированному списку событий в один проход, а
# вместе с ним живут `_reel_at`, `reelAt` и `_act_until`. Откат назад означал бы
# сброс всей этой пятёрки и пересчёт плёнки с нуля — то есть отдельную машину
# ради того, чего никто не просил.
const FF_RUN := 5.0           # Shift — «посмотреть быстрее»
const FF_FAST := 12.0         # → — «долистать»
const FF_BURST := 0.30        # Space/Enter — за сколько секунд дойти до конца

var _ff := false              # идёт ускоренный ход: голос и звуки ленты молчат
var _ff_burst := 0.0          # остаток броска «в конец»
var _mode_ff := ""            # что показывать вместо «▶ PLAY», пока мотаем
# Кассету ВЫБИРАЮТ той же клавишей, которой мотают в конец (main.gd: меню
# кассет — это phone.show(), и pick() висит на interact/advance). Нажатие
# держится весь кадр, а play() случается внутри него — без этой защёлки
# выбранная пробелом кассета домотала бы себя до конца, не начавшись.
var _ff_armed := false

# Скример на плёнке: сколько кадров лицо ещё держится на полной яркости.
var _flash := 0

var _tapes: Dictionary = {}
var _shots: Dictionary = {}
var _scene_shots: Dictionary = {}

# Фаза 8, оверлей tape_shots.json: плёнка КАССЕТЫ (кадр на реплику) и кадры
# событий act. Файла нет — оба словаря пустые, и плеер работает ровно как
# в фазе 4: плёнка сцены по таймеру, фигуры прямоугольниками.
var _tape_scene_shots: Dictionary = {}
var _act_shots: Dictionary = {}

# Плёнка этой кассеты: сцена -> сколько кадров с неё уже сошло. Позиция живёт
# всю кассету, а не сцену: в кассете «x» коридор идёт дважды, и второй проход
# обязан продолжить плёнку, а не начать её заново.
var _reel_at: Dictionary = {}
# Кадр сцены только что встал и ещё не отработал ни одной реплики: первая
# реплика показывается на нём, а не на следующем.
var _reel_fresh := false
# До этого времени кадр держит событие act. Реплики внутри окна текст меняют,
# картинку — нет: рука, входящая в кадр, и есть та реплика.
var _act_until := -1.0

# Кадр запрашивается в момент, когда до него дошла плёнка, а результат
# кэшируется навсегда: Texture2D — готов, null — не загрузился и больше не пробуем.
var _shot_images: Dictionary = {}

var _built := false
var _hud_parent: Node = null
var _clean_view: SubViewport = null
var _blit_view: SubViewport = null
var _clean: TapeDraw = null
var _strips: TapeDraw = null
var _osd: TapeDraw = null
var _head: TapeDraw = null
var _fx_rect: TextureRect = null
var _mono_mat: ShaderMaterial = null
var _fx_mat: ShaderMaterial = null

var _layer: CanvasLayer = null
var _lbl_mode: Label = null
var _lbl_code: Label = null
var _lbl_sub: Label = null
var _lbl_hint: Label = null
var _font_osd: Font = null
var _font_hud: Font = null
var _font_sub: Font = null
var _font_hint: Font = null


func _init(game_audio: GameAudio = null, chain: RenderChain = null, parent: Node = null) -> void:
	audio = game_audio
	renderer = chain
	_hud_parent = parent
	var tapes := GameData.tapes()
	_tapes = tapes.get("TAPES", {})
	var shots := GameData.shots()
	_shots = shots.get("SHOTS", {})
	_scene_shots = shots.get("SCENE_SHOTS", {})
	_load_overlay()


## Подключить движок после конструктора: main.gd собирает плеер до того,
## как становится ясно, чем он будет рисовать.
func attach(chain: RenderChain) -> void:
	renderer = chain


# Голос кассеты (фаза 5): закадр соседа и ремарки нарратора. Записи нет —
# плёнка идёт субтитрами, ровно как в принятой версии фазы 4.
#
# Заодно ремарка ведёт звук: то, что до фазы 5 было только написано словами
# («лает не переставая», «внизу хлопает дверь в сенях»), теперь слышно.
# Совпадение по куску текста, а не по секунде: время принадлежит tapes.json,
# и правка раскадровки не должна разъезжаться со звуком.
## Оверлей кадров кассет (фаза 8). Нет файла — визуальный ряд ровно как принят.
const OVERLAY := "res://data/tape_shots.json"

## Сколько секунд тишины считается долгой паузой. Внутри сцены самый большой
## разрыв между репликами — девять секунд (кассета 3, «дышит в воротник»),
## поэтому монтаж по репликам таймер не перебивает.
const CUT_MIN := 12.0

const SUB_SFX := {
	"лает не переставая": "tape-dog",
	"собака поднимает голову": "tape-dog",
	"хлопает дверь в сенях": "tape-door-slam",
	"шаги по лестнице": "tape-stairs",
	"гул холодильника": "tape-hum",
	"дышит в воротник": "tape-breath",
	"снимающий дышит": "tape-breath",
}


## Прямая речь против ремарки. Дубль gen_voice._is_remark, и разъехаться им
## нельзя: тогда ремарка молча поедет цветом речи, а игрок будет ждать голос,
## которого нет. Расхождение ловит машинно tests/test_tape_shots.gd — сверкой
## с каналом реплики в манифесте озвучки.
##
## Шёпот отдельным случаем не по прихоти: на плёнке 3 весь закадр Аркадия
## шёпотом и без тире, по одному тире он целиком уехал бы в ремарки.
static func _is_speech(text: String) -> bool:
	var s := text.strip_edges(true, false)
	if s.begins_with("(шёпот)"):
		return true
	return s.begins_with("—") or s.begins_with("–")


func _speak(text: String) -> void:
	if text == "":
		return
	# На перемотке молчат оба канала — и голос, и звук ремарки. Бросок «в конец»
	# проходит десяток реплик за треть секунды: без этого он даёт залп собак,
	# дверей и шагов разом. Субтитр при этом идёт, и именно по нему мотают.
	if _ff:
		return
	if voice != null:
		voice.play_tape_line(tapeId, text)
	if audio == null:
		return
	var low := text.to_lower()
	for frag: String in SUB_SFX:
		if low.find(frag) >= 0:
			# Мимо реверба: звук родился в динамике телевизора, отражаться
			# ему негде — там же играет tape-bed.
			audio.sfx(String(SUB_SFX[frag]), 1.0, &"Dry")
			break


## Куда вешать надписи аппарата. Отдельно от движка: слой надписей — обычный
## UI поверх composite, а не часть цепочки кадра.
func attach_hud(parent: Node) -> void:
	_hud_parent = parent

# ------------------------------------------------------------- управление ---

func play(id: String, on_done := Callable()) -> bool:
	if not _tapes.has(id):
		return false
	tape = _tapes[id]
	tapeId = id
	t = 0.0
	_cursor = 0
	sub = ""
	code = ""
	acts = []
	fx = 1.2
	finished = false
	_on_done = on_done
	open = true
	_mode_text = "▶ PLAY"
	_ff = false
	_ff_burst = 0.0
	_mode_ff = ""
	_ff_armed = false
	_flash = 0

	_reel_at.clear()
	_reel_fresh = false
	_act_until = -1.0

	scratches = _scratches_for(id)
	clock0 = _parse_clock(tape.get("clock", null))
	counter0 = _parse_clock(tape.get("counter", null))
	_set_scene("dark")

	_ensure_nodes()
	_set_views(true)
	if _layer != null:
		_layer.visible = true

	gl = renderer != null
	if gl:
		renderer.begin_tape_mode()
		# Трекинг общий с миром: запоминаем чужое значение и вернём его на выходе.
		var tr: Variant = renderer.get_vhs(&"tracking")
		_track0 = float(tr) if (tr is float or tr is int) else 0.0
		# Снос цветности сильнее на затёртых кассетах: static — их износ.
		renderer.set_chroma_smear(0.30 + _wear() * 0.5)
		# Тонкую полосу перекоммутации даёт шейдер композита, грубую рисуем сами.
		renderer.set_head_switch(0.22)

	if audio != null:
		audio.rewind(0.8)
		audio.tape_click()
		audio.tape_bed(true)
	# Хвост прошлой плёнки: перемотка началась, а прошлая реплика ещё говорит.
	if voice != null:
		voice.stop_tape()

	# Первый кадр собираем сразу: вьюпорт, включённый пустым, успел бы
	# показать чёрный прямоугольник поверх начала записи.
	_frame()
	return true


func stop(watched := false) -> void:
	if not open:
		return
	open = false
	_ff = false
	_ff_burst = 0.0
	_mode_ff = ""
	if _layer != null:
		_layer.visible = false

	if audio != null:
		audio.tape_bed(false)
		audio.tape_click()
	# Закрыл кассету — Аркадий не должен договаривать в пустой кухне.
	if voice != null:
		voice.stop_tape()

	if gl and renderer != null:
		# Оба uniform'а обязаны вернуться в ноль: при нуле мир не должен
		# измениться ни на пиксель.
		renderer.set_chroma_smear(0.0)
		renderer.set_head_switch(0.0)
		renderer.set_tracking(_track0)
		renderer.end_tape_mode()
	gl = false
	_set_views(false)

	var cb := _on_done
	_on_done = Callable()
	if cb.is_valid():
		cb.call(tapeId, watched or finished)


func update(dt: float) -> void:
	if not open:
		return
	t += _rewind(dt)

	# Записи отсортированы по времени: курсор идёт по списку в один проход
	# и назад не возвращается.
	var events: Array = tape.get("script", [])
	while _cursor < events.size() and float((events[_cursor] as Array)[0]) <= t:
		var ev: Array = events[_cursor]
		_cursor += 1
		var kind := String(ev[1])
		var payload: Variant = ev[2]
		match kind:
			"sub":
				sub = String(payload)
				_speak(sub)
				_line_cut()
			"scene":
				_set_scene(String(payload))
			"shot":
				# Своя плёнка у кассеты главнее: она расписана по репликам,
				# и кадр из tapes.json посреди неё сбил бы счёт.
				if _tape_reel().is_empty():
					_set_shot(String(payload))
			"code":
				code = String(payload)
			"fx":
				fx = float(payload)
				if audio != null:
					audio.noise({"dur": 0.35, "gain": 0.08, "freq": 3200, "q": 0.6, "sweep": -2400})
			"act":
				var p: Array = payload
				# Есть кадр под это событие — фигуру не рисуем вовсе: две
				# коробки поверх настоящего кадра и есть то, из-за чего
				# «анимации» читались браком записи.
				if not _act_cut(String(p[0]), float(p[3])):
					acts.append({
						"who": String(p[0]),
						"from": float(p[1]),
						"to": float(p[2]),
						"dur": float(p[3]),
						"t0": t,
					})
			"end":
				sub = String(payload)
				_speak(sub)
				_line_cut()
				finished = true
				_mode_text = "■ STOP"

	_advance_reel()
	if fx > 0.0:
		fx = maxf(0.0, fx - dt * 1.6)

	if gl and renderer != null:
		# Сбой плёнки ведёт и цветность, и строчную синхронизацию — оба сразу,
		# иначе он читается как «шум поверх», а не как порча записи.
		renderer.set_chroma_smear(minf(1.0, 0.30 + _wear() * 0.5 + fx * 0.45))
		renderer.set_head_switch(minf(1.0, 0.22 + fx * 0.3))
		renderer.set_tracking(minf(1.0, _track0 + fx * 0.7))

	if t > float(tape.get("duration", 0.0)) + 3.0:
		stop(true)
		return

	_frame()


## Сколько времени ленты сошло за этот кадр. Обычный ход — ровно dt; Shift —
## впятеро; → — вдвенадцатеро; Space/Enter — остаток плёнки за FF_BURST секунд.
##
## Бросок «в конец» кончается тем же местом, что и обычный просмотр: время
## переваливает за duration + 3, update() зовёт stop(true), и кассета
## ЗАСЧИТЫВАЕТСЯ. Остановка на E — по-прежнему stop(false) и не засчитана.
## Разница между «домотал» и «выключил» этим и держится.
func _rewind(dt: float) -> float:
	if not _ff_armed:
		# Ждём, пока клавишу выбора отпустят: см. _ff_armed.
		if not Input.is_action_pressed("advance"):
			_ff_armed = true
	elif _ff_burst <= 0.0 and Input.is_action_just_pressed("advance"):
		_ff_burst = FF_BURST
	if _ff_burst > 0.0:
		_set_ff(true)
		_mode_ff = "▶▶▶▶"
		var left := float(tape.get("duration", 0.0)) + 3.02 - t
		# Доля остатка, которую съедаем в этом кадре. Когда броску осталось
		# меньше кадра, доля равна единице и плёнка доходит до конца ровно
		# тогда, когда гаснет надпись.
		var k := 1.0 if dt >= _ff_burst else dt / _ff_burst
		_ff_burst = maxf(0.0, _ff_burst - dt)
		return maxf(dt, left * k)

	var rate := 1.0
	if Input.is_action_pressed("ui_page_right"):
		rate = FF_FAST
		_mode_ff = "▶▶▶"
	elif Input.is_action_pressed("run"):
		rate = FF_RUN
		_mode_ff = "▶▶"
	else:
		_mode_ff = ""
	_set_ff(rate > 1.0)
	return dt * rate


## Вход и выход из ускоренного хода. На входе обрываем реплику, которая уже
## говорит: на пятикратной скорости голос отстаёт от субтитра через две реплики
## и превращается в кашу. Субтитры при этом идут — по ним и мотают.
func _set_ff(on: bool) -> void:
	if on == _ff:
		return
	_ff = on
	if on and voice != null:
		voice.stop_tape()

# ------------------------------------------------------------------ монтаж ---

func _set_scene(name: String) -> void:
	scene = name
	_act_until = -1.0
	var own := _tape_reel(name)
	if not own.is_empty():
		# Плёнка кассеты: позиция продолжается с того места, где сцену
		# оставили, и первая реплика идёт на уже показанном кадре.
		reel = own
		reelAt = clampi(int(_reel_at.get(name, 0)), 0, own.size() - 1)
		# «Свежий» кадр бывает только при ПЕРВОМ входе в сцену: тогда её первая
		# реплика идёт на кадре, который уже стоит. Возврат в сцену обязан
		# двинуть плёнку — иначе кадр, на котором её оставили, встал бы дважды.
		_reel_fresh = not _reel_at.has(name)
		cutAt = t
		_warm()
		return
	var list: Variant = _scene_shots.get(name, null)
	reel = list if list is Array else []
	reelAt = 0
	_reel_fresh = false
	cutAt = t
	_warm()


func _set_shot(id: String) -> void:
	var shot: Dictionary = _shot_def(id)
	if shot.is_empty():
		return
	scene = String(shot.get("scene", scene))
	var list: Variant = _scene_shots.get(scene, null)
	var i := -1
	if list is Array:
		i = (list as Array).find(id)
	# Кадр вне плёнки своей сцены крутим в одиночку: склеек не будет,
	# но и на чужую сцену плеер не перескочит.
	if i >= 0:
		reel = list
		reelAt = i
	else:
		reel = [id]
		reelAt = 0
	cutAt = t
	_warm()


## Кадр на реплику (фаза 8). Пока у кассеты есть своя плёнка, монтаж ведут
## реплики, а не секундомер: кадр меняется ровно там, где меняется разговор.
func _line_cut() -> void:
	if _tape_reel().is_empty():
		return
	if t < _act_until:
		return                      # кадр держит act
	if _reel_fresh:
		_reel_fresh = false         # первая реплика сцены идёт на её первом кадре
		cutAt = t
		_reel_at[scene] = reelAt
		return
	if reelAt + 1 < reel.size():
		reelAt += 1
		_cut()
	cutAt = t
	_reel_at[scene] = reelAt


## Кадр вместо двух прямоугольников. Собака, поднимающая голову в объектив,
## человек вдоль стены и рука, поправляющая одеяло, — три самых сильных момента
## плёнок, и рисовать их коробками было тем же, чем описывать словами.
func _act_cut(who: String, dur: float) -> bool:
	var id := String(_act_shots.get(scene + ":" + who, ""))
	if id == "" or _shot_def(id).is_empty():
		return false
	reel = [id]
	reelAt = 0
	_reel_fresh = false
	_act_until = t + dur
	cutAt = t
	_cut()
	_warm()
	return true


## Плёнка кассеты для сцены. Пустой массив — её нет, и всё идёт как раньше.
func _tape_reel(name := "") -> Array:
	var key := tapeId + ":" + (scene if name == "" else name)
	var v: Variant = _tape_scene_shots.get(key, null)
	return v if v is Array else []


func _load_overlay() -> void:
	var f := FileAccess.open(OVERLAY, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		push_warning("tape_shots.json не разобран как объект — кадры кассет как в фазе 4")
		return
	var d: Dictionary = parsed
	var extra: Dictionary = d.get("SHOTS", {})
	for id in extra:
		_shots[String(id)] = extra[id]
	var scenes: Dictionary = d.get("SCENE_SHOTS", {})
	for sc in scenes:
		_scene_shots[String(sc)] = scenes[sc]
	_tape_scene_shots = d.get("TAPE_SCENE_SHOTS", {})
	_act_shots = d.get("ACT_SHOTS", {})


## Склейка по dur. Цикл со счётчиком, а не if: после лага кадра время могло
## уйти на несколько кадров вперёд, и без цикла плёнка залипла бы на одном
## кадре до конца сцены.
func _advance_reel() -> void:
	if reel.size() < 2:
		return
	if t < _act_until:
		return
	# На плёнке кассеты секундомер оставлен ровно на долгие паузы: самый большой
	# разрыв между репликами внутри сцены — девять секунд, и раньше CUT_MIN
	# таймер в монтаж по репликам не вмешивается.
	var own := not _tape_reel().is_empty()
	var guard := 8
	while guard > 0:
		guard -= 1
		var shot: Dictionary = _shot_def(String(reel[reelAt]))
		var dur := 4.0
		if not shot.is_empty():
			dur = float(shot.get("dur", 4.0))
			if dur == 0.0:
				dur = 4.0
		if own:
			dur = maxf(dur, CUT_MIN)
		if t - cutAt < dur:
			break
		cutAt += dur
		reelAt = (reelAt + 1) % reel.size()
		_cut()


## Склейка на камкордере — не переход, а обрыв записи: головка на кадр теряет
## синхронизацию и щёлкает. 0.3 заметно, но не сбивает с чтения субтитра;
## единица — это уже событие 'fx', порча плёнки.
func _cut() -> void:
	# ФАЗА 13, скример на плёнке. Кадр с полем "flash": true в tape_shots.json
	# приходит не склейкой, а ударом: стингер и три кадра лица на полной
	# яркости, без сепии и без сбоя ленты, — а дальше плёнка идёт как шла.
	# Скримеров четыре на все пять кассет, и это потолок: инструмент, которым
	# бьют часто, перестаёт бить. Данные плёнок (tapes.json / tapes_ext.json)
	# про скримеры не знают вовсе — это свойство КАДРА, а не события.
	if bool(_shot_def(_shot_id()).get("flash", false)):
		_flash = 3
		fx = 0.0
		if audio != null:
			audio.stinger(1.0)
		_warm()
		return
	fx = maxf(fx, 0.3)
	# На броске «в конец» склеек проходит десяток за кадр — щелчок по каждой
	# из них складывается в один треск. Под Shift и → щёлкать можно и нужно:
	# это и есть звук перемотки.
	if audio != null and _ff_burst <= 0.0:
		audio.noise({"dur": 0.07, "gain": 0.05, "freq": 2600, "q": 1.4, "sweep": -1400})
	_warm()


## Заранее попросить текущий кадр и следующий за ним: склейка не должна
## попадать на момент, когда файл ещё не прочитан с диска.
func _warm() -> void:
	if reel.is_empty():
		return
	_shot_image(String(reel[reelAt]))
	if reel.size() > 1:
		_shot_image(String(reel[(reelAt + 1) % reel.size()]))


func _shot_id() -> String:
	return String(reel[reelAt]) if not reel.is_empty() else ""


func _shot_def(id: String) -> Dictionary:
	if id.is_empty():
		return {}
	return _shots.get(id, {})


func _shot_image(id: String) -> Texture2D:
	if _shot_images.has(id):
		return _shot_images[id]
	var def := _shot_def(id)
	if def.is_empty():
		_shot_images[id] = null
		return null
	var path := "res://" + String(def.get("src", ""))
	var tex: Texture2D = null
	if ResourceLoader.exists(path):
		var res: Variant = load(path)
		if res is Texture2D:
			tex = res
	_shot_images[id] = tex
	return tex

# -------------------------------------------------------------- показания ---

func _timecode() -> String:
	var s := int(t)
	return "0:" + _pad2(int(s / 60)) + ":" + _pad2(s % 60)


## Часы съёмки. Идут от clock кассеты в реальном времени просмотра.
func _clock() -> String:
	if not tape.has("date"):
		return "--:--:--"
	var s := int(clock0 + t)
	return _pad2(int(s / 3600) % 24) + ":" + _pad2(int(s / 60) % 60) + ":" + _pad2(s % 60)


## Счётчик ленты. Он не сбрасывается между записями, поэтому у каждой кассеты
## своя стартовая цифра — по ней видно, что до этого на плёнке уже что-то было.
func _counter() -> String:
	var s := int(counter0 + t)
	return str(int(s / 3600)) + ":" + _pad2(int(s / 60) % 60) + ":" + _pad2(s % 60)


func _pad2(n: int) -> String:
	return ("0" + str(n)) if n < 10 else str(n)


## Износ ленты. `(this.tape.static || 0.25)` оригинала: нуля у износа не бывает,
## ноль означает «в данных не написано».
func _wear() -> float:
	var v := float(tape.get("static", 0.0))
	return v if v != 0.0 else 0.25


## Движение камеры внутри кадра. Амплитуда крошечная: снимают с рук, упирая
## локти в забор, а не с крана. Масштаб нигде не опускается ниже 1.04: этот
## запас съедают панорама и дрожание рук, иначе по краю кадра проступает чернота.
## Возвращает (zoom, px, py).
func _move_of(move: String, q: float) -> Vector3:
	var zoom := 1.04
	var px := 0.0
	var py := 0.0
	if move == "push-in":
		zoom = 1.04 + 0.06 * q
	elif move == "pan-left":
		zoom = 1.08
		px = (q - 0.5) * 14.0
	elif move == "pan-right":
		zoom = 1.08
		px = (0.5 - q) * 14.0
	elif move == "tilt-down":
		zoom = 1.09
		py = (0.5 - q) * 12.0
	# Даже на «hold» кадр дышит: штатива у него нет ни на одной кассете.
	px += sin(t * 0.9) * 1.6
	py += cos(t * 0.7) * 1.2
	return Vector3(zoom, px, py)


## Положение продольных царапин выводится из номера кассеты: одна и та же
## кассета всегда протёрта в одних и тех же местах. FNV-1a — потому что нужен
## разброс, а не криптография. Арифметика 32-битная, как Math.imul в оригинале.
func _scratches_for(id: String) -> Array:
	var h := 2166136261
	for i in id.length():
		h = (h ^ id.unicode_at(i)) & 0xFFFFFFFF
		h = (h * 16777619) & 0xFFFFFFFF
	var out: Array = []
	var count := 1 + ((h >> 7) & 1)
	for i in count:
		h = ((h ^ (i + 1)) * 16777619) & 0xFFFFFFFF
		out.append({
			"x": float(12 + ((h >> 9) % (int(W) - 24))),
			# 0.05–0.12: царапину должно быть видно на светлом кадре
			# и не видно на тёмном.
			"a": snappedf(0.05 + float((h >> 3) % 7) * 0.012, 0.001),
		})
	return out


func _parse_clock(v: Variant) -> float:
	if not (v is String):
		return 0.0
	var parts := String(v).split(":")
	var p: Array = []
	for x in parts:
		p.append(int(x))
	while p.size() < 3:
		p.insert(0, 0)
	return float(int(p[0]) * 3600 + int(p[1]) * 60 + int(p[2]))

# ----------------------------------------------------------------- кадр ---

## Порт _draw(): дрожание камеры, раскладка состояния по узлам и uniform'ам.
## Рисуют сами узлы в своём _draw(), поэтому случайные величины кадра
## (дрожание, выпадения, шум головок) считаются здесь и один раз.
func _frame() -> void:
	if not _built:
		return

	var shake := float(tape.get("shake", 0.0)) * 2.2 + fx * 5.0
	var shake_x := (randf() - 0.5) * shake
	var shake_y := (randf() - 0.5) * shake * 0.6

	var id := _shot_id()
	var shot := _shot_def(id)
	var tex: Texture2D = null
	if not id.is_empty():
		tex = _shot_image(id)

	# --- чистый кадр ---
	# На скримере сепия кассеты снимается: лицо обязано ударить белым, а не
	# приехать в общей янтарной дымке вместе с яблоками и половицами.
	# _wash() в TapeDraw красит кадр этим цветом на 10 %, и белый там —
	# это «не красить вовсе».
	var wash := Color.html(String(tape.get("tint", "#a09a86")))
	if _flash > 0:
		_flash -= 1
		wash = Color(1.0, 1.0, 1.0)
		fx = 0.0

	_clean.t = t
	_clean.tint = wash
	_clean.scene = scene
	_clean.shot_tex = tex
	_clean.acts = acts
	_clean.queue_redraw()

	# --- полосы ---
	var dur := 1.0
	var q := 0.0
	var move := "hold"
	if not shot.is_empty():
		dur = maxf(0.1, float(shot.get("dur", 4.0)))
		q = minf(1.0, (t - cutAt) / dur)
		move = String(shot.get("move", "hold"))
	var mv := _move_of(move, q)

	# Амплитуда разъезда строк: её же берёт меню камкордера.
	_wow = 1.1 + float(tape.get("shake", 0.0)) * 0.9 + fx * 2.6

	_strips.t = t
	_strips.wow_amp = _wow
	_strips.source = _clean_view.get_texture()
	_strips.zoom = mv.x
	_strips.move_px = mv.y
	_strips.move_py = mv.z
	_strips.shake_x = shake_x
	_strips.shake_y = shake_y
	_strips.queue_redraw()

	# Ночной режим камеры: у кассеты целиком либо у одного кадра.
	var mono := bool(tape.get("mono", false)) or bool(shot.get("mono", false))
	_mono_mat.set_shader_parameter("mono", 1.0 if mono else 0.0)

	# --- меню и артефакты ленты ---
	_osd.t = t
	_osd.wow_amp = _wow
	_osd.rec = fmod(t, 1.0) < 0.62
	_osd.counter = _counter()
	_osd.clock = _clock()
	_osd.date = String(tape.get("date", "--.--.----"))
	_osd.scratches = scratches
	_osd.drops = _dropouts()
	# Полоса трекинга ползёт вверх.
	_osd.band_y = H - fmod(t * 42.0, H + 60.0)
	_osd.queue_redraw()

	# --- плёнка ---
	# Сдвиг полосы головок гуляет от 1 до 5 пикселей: он привязан к натяжению
	# ленты, а оно не постоянно.
	var shift := 3.0 + sin(t * 7.3) * 2.0 + fx * 5.0
	_fx_mat.set_shader_parameter("seed", randf() * 1024.0)
	_fx_mat.set_shader_parameter("noise_amount", 0.055 + _wear() * 0.14 + fx * 0.42)
	_fx_mat.set_shader_parameter("head_shift", shift)

	_head.t = t
	_head.head_shift = shift
	_head.head_lines = _head_lines()
	_head.queue_redraw()

	_sync_hud()


## Выпадения ленты: осыпавшийся оксид не даёт сигнала, и головка пишет белый
## штрих в несколько строк. На целой кассете это раз в пару секунд, на сбое —
## сплошняком.
func _dropouts() -> Array:
	var n := 0
	if fx > 0.4:
		n = 5
	elif randf() < 0.20 + _wear() * 0.28:
		n = 1 + int(randf() * 2.0)
	var out: Array = []
	for _i in n:
		out.append({
			"light": randf() < 0.72,
			"x": randf() * W,
			"y": randf() * H,
			"w": 8.0 + randf() * 34.0,
			"h": 1.0 + randf() * 2.0,
		})
	return out


func _head_lines() -> Array:
	var out: Array = []
	for _i in 5:
		out.append({
			"light": randf() < 0.5,
			"x": randf() * W,
			"y": randf() * HEAD,
			"w": 6.0 + randf() * 40.0,
		})
	return out

# ------------------------------------------------------------------ узлы ---

## Цепочка вьюпортов строится при первом play(): игрок может не найти ни одной
## кассеты за всю игру, и платить за неё он тогда не должен вовсе.
func _ensure_nodes() -> void:
	if _built or renderer == null:
		return
	var host := renderer.tape_viewport()
	if host == null:
		return

	_ensure_fonts()

	var sh := load("res://shaders/tape_fx.gdshader") as Shader
	_mono_mat = ShaderMaterial.new()
	_mono_mat.shader = sh
	_mono_mat.set_shader_parameter("fx_pass", 0.0)
	_mono_mat.set_shader_parameter("mono", 0.0)
	_fx_mat = ShaderMaterial.new()
	_fx_mat.shader = sh
	_fx_mat.set_shader_parameter("fx_pass", 1.0)
	_fx_mat.set_shader_parameter("tape_size", Vector2(W, H))
	_fx_mat.set_shader_parameter("head_rows", HEAD)

	# Порядок в дереве важен вдвойне: и вьюпорты, и обычные узлы Godot рисует
	# в порядке добавления, а собранный кадр обязан идти после источников.
	_blit_view = _make_view("TapeBlit")
	host.add_child(_blit_view)

	_clean_view = _make_view("TapeClean")
	_blit_view.add_child(_clean_view)

	_clean = TapeDraw.new()
	_clean.name = "CleanFrame"
	_clean.role = TapeDraw.ROLE_CLEAN
	# Кадры лежат ровно 320x240, а лицо соседа 128x128 растягивается: канва
	# сглаживала обе картинки, значит и здесь фильтрация линейная.
	_clean.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_clean_view.add_child(_clean)

	_strips = TapeDraw.new()
	_strips.name = "Strips"
	_strips.role = TapeDraw.ROLE_STRIPS
	_strips.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_strips.material = _mono_mat
	_blit_view.add_child(_strips)

	_osd = TapeDraw.new()
	_osd.name = "Osd"
	_osd.role = TapeDraw.ROLE_OSD
	_osd.font = _font_osd
	_blit_view.add_child(_osd)

	_fx_rect = TextureRect.new()
	_fx_rect.name = "TapeFilm"
	_fx_rect.texture = _blit_view.get_texture()
	_fx_rect.material = _fx_mat
	_fx_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_fx_rect.stretch_mode = TextureRect.STRETCH_SCALE
	_fx_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_fx_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_fx_rect.position = Vector2.ZERO
	_fx_rect.size = Vector2(W, H)
	host.add_child(_fx_rect)

	_head = TapeDraw.new()
	_head.name = "HeadSwitch"
	_head.role = TapeDraw.ROLE_HEAD
	host.add_child(_head)

	_build_hud()
	_built = true


func _make_view(view_name: String) -> SubViewport:
	var v := SubViewport.new()
	v.name = view_name
	v.size = TAPE_SIZE
	v.transparent_bg = false
	v.render_target_update_mode = SubViewport.UPDATE_DISABLED
	v.gui_disable_input = true
	# 2D-этаж: трёхмерного прохода тут нет и быть не должно.
	v.set(&"disable_3d", true)
	return v


func _set_views(on: bool) -> void:
	var mode := SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if _clean_view != null:
		_clean_view.render_target_update_mode = mode
	if _blit_view != null:
		_blit_view.render_target_update_mode = mode

# ---------------------------------------------------- надписи аппарата ---

## Шрифт меню и надписей: PT Mono. Латиница и кириллица в оригинале лежат
## двумя подмножествами, поэтому вторая цепляется запасной — как unicode-range
## в @font-face. Символы «▶» и «■» не входят ни в одно из них и приезжают
## из системного шрифта, ровно как в браузере из его цепочки fallback.
func _mono_font(base: Font, extra: Font, track: int) -> Font:
	var f := FontVariation.new()
	f.base_font = base
	if extra != null:
		var fb: Array[Font] = [extra]
		f.fallbacks = fb
	if track != 0:
		f.spacing_glyph = track
	return f


func _ensure_fonts() -> void:
	if _font_osd != null:
		return
	var latin := load("res://assets/fonts/pt-mono-latin-400.woff2") as Font
	var cyr := load("res://assets/fonts/pt-mono-cyrillic-400.woff2") as Font
	# Меню камкордера набрано цифрами и латиницей, субтитры и подсказка —
	# кириллицей: у каждого свой основной шрифт, второй идёт запасным.
	_font_osd = _mono_font(latin, cyr, 0)
	_font_hud = _mono_font(latin, cyr, HUD_TRACK)
	_font_sub = _mono_font(cyr, latin, 0)
	_font_hint = _mono_font(cyr, latin, HINT_TRACK)


func _build_hud() -> void:
	var parent: Node = _hud_parent
	if parent == null:
		parent = renderer
	if parent == null:
		return

	_layer = CanvasLayer.new()
	_layer.name = "TapeHud"
	_layer.layer = LAYER
	_layer.visible = false
	parent.add_child(_layer)

	_lbl_mode = _make_label(_font_hud, HUD_SIZE, HUD_INK, HORIZONTAL_ALIGNMENT_RIGHT)
	_lbl_code = _make_label(_font_hud, HUD_SIZE, HUD_INK, HORIZONTAL_ALIGNMENT_LEFT)
	_lbl_sub = _make_label(_font_sub, SUB_SIZE, SUB_INK, HORIZONTAL_ALIGNMENT_CENTER)
	_lbl_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_lbl_sub.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	# Подсказка клавиши — от игры, не от аппарата: она у нижней кромки ЭКРАНА.
	_lbl_hint = _make_label(_font_hint, HINT_SIZE, HINT_INK, HORIZONTAL_ALIGNMENT_CENTER)
	_lbl_hint.text = "[E] стоп · [Shift] перемотка · [Space] в конец"
	_layer.add_child(_lbl_mode)
	_layer.add_child(_lbl_code)
	_layer.add_child(_lbl_sub)
	_layer.add_child(_lbl_hint)


func _make_label(font: Font, size: int, ink: Color, align: int) -> Label:
	var ls := LabelSettings.new()
	ls.font = font
	ls.font_size = size
	ls.font_color = ink
	ls.shadow_color = Color(0.0, 0.0, 0.0, 0.95)
	ls.shadow_offset = Vector2(0.0, 2.0)
	ls.shadow_size = 3
	var l := Label.new()
	l.label_settings = ls
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## Раскладка HUD считается каждый кадр от текущего размера окна: полоса
## пиллярбокса меняется вместе с формой окна, а надписи обязаны сидеть в ней,
## не наезжая на кадр (padding из .tape__hud).
func _sync_hud() -> void:
	if _layer == null:
		return
	var vp := _layer.get_viewport()
	if vp == null:
		return
	var win := vp.get_visible_rect().size
	if win.x <= 0.0 or win.y <= 0.0:
		return

	# Половина кадра 4:3 в долях буфера — её же режет композит, поэтому
	# геометрия HUD и геометрия картинки не могут разъехаться.
	var half := Vector2(0.5, 0.5)
	var hv: Variant = renderer.get_vhs(&"tape_half") if renderer != null else null
	if hv is Vector2:
		half = hv
	var frame_w := 2.0 * half.x * win.x
	var frame_h := 2.0 * half.y * win.y
	var pillar := (win.x - frame_w) * 0.5
	var letter := (win.y - frame_h) * 0.5

	var ch := _font_hud.get_string_size("0", HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_SIZE).x
	var line := _font_hud.get_height(HUD_SIZE)
	# 10ch: длиннее «0:04:20» надписи не бывает.
	var pad := maxf(0.014 * win.x, pillar - 10.0 * ch - 0.007 * win.x)
	var top := letter + 0.022 * win.y

	# Индикатор перемотки главнее «▶ PLAY» и «■ STOP»: пока мотают, аппарат
	# показывает ровно то, что с ним делают.
	_lbl_mode.text = _mode_ff if _mode_ff != "" else _mode_text
	_lbl_mode.position = Vector2(pad, top)
	_lbl_mode.size = Vector2(10.0 * ch, line)

	_lbl_code.text = code if not code.is_empty() else _timecode()
	_lbl_code.position = Vector2(win.x - pad - 10.0 * ch, top)
	_lbl_code.size = Vector2(10.0 * ch, line)

	var sub_w := minf(0.8 * win.x, frame_w - 0.10 * win.x)
	var sub_h := _font_sub.get_height(SUB_SIZE) * 3.0
	var sub_bottom := win.y - (letter + 0.07 * win.y)
	_lbl_sub.text = sub
	# Цвет решается тут, а не на событии: субтитр приходит и из 'sub', и из 'end',
	# и оба пути обязаны красить одинаково.
	_lbl_sub.label_settings.font_color = SUB_INK if _is_speech(sub) else REMARK_INK
	_lbl_sub.position = Vector2((win.x - sub_w) * 0.5, sub_bottom - sub_h)
	_lbl_sub.size = Vector2(sub_w, sub_h)

	var hint_h := _font_hint.get_height(HINT_SIZE)
	_lbl_hint.position = Vector2(0.0, win.y - 0.03 * win.y - hint_h)
	_lbl_hint.size = Vector2(win.x, hint_h)

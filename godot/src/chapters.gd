# Главы и биты (порт game/chapters.js).
#
# Повествование данными: у главы есть карточка, вход, вычисляемая задача
# и таблица реакций на события. Задача не хранится в отдельной машине состояний,
# а считается из флагов — иначе рассинхрон после перезапуска главы неизбежен.
#
# Правило темпа: до 23:40 ни одного музыкального акцента. Все аномалии первых
# пятнадцати минут проходят без реакции интерфейса, и игрок может их пропустить.
#
# Оригинал держит главы объектным литералом с методами; здесь на их месте
# обычные методы класса, а в таблице лежат ссылки на них (Callable). Многострочные
# лямбды внутри словарного литерала парсер GDScript читает неохотно, и цена
# ошибки — вся приёмка фазы.

class_name Chapters
extends RefCounted

# Что Сергей говорит себе, вернувшись на крыльцо после поимки. Литерал стоит
# здесь, а не в texts.json: тот файл принадлежит другому владельцу, а строка
# нужна ровно там, где звучит. Она же объясняет перенос: его не «убили»
# и не «откатили» — его довели до дома и оставили.
const BROUGHT_BACK := "Он довёл до крыльца и ушёл. Ничего не сказал."

# Повтор подсказки про тайник. Первая реплика звучит один раз, в темноте,
# и забывается: жалоба была «спустился в подпол и не понял, что там брать».
# Дальше считаем время, проведённое ИМЕННО в подполе, шагами по CELLAR_TICK —
# наверху счётчик стоит, иначе подсказка догонит игрока в прихожей.
# Три повтора и всё: четвёртый читается как то, что игра сама себя не слышит.
# Каждый следующий короче и глуше предыдущего — это Сергей вспоминает вслух,
# а не интерфейс объясняет задачу.
# Во сколько раз тише сюжетный удар при выключенных резких эффектах (фаза 8).
const SOFT_K := 0.34

const CELLAR_TICK := 5.0    # как часто проверяем, где игрок
const CELLAR_WAIT := 60.0   # и сколько он должен пробыть внизу до следующей реплики

## Через сколько молчания ДЕРЕВНЯ повторит текущую задачу вслух (фаза 18).
## Девяносто секунд — это дольше любого перехода по карте: от ворот до
## погоста 88 м, до фермы 74. Кто идёт по делу, напоминания не услышит.
const VILLAGE_REMIND := 90.0

# Сколько игрок должен пробыть В ДОМЕ, прежде чем хлопнет автомат (фаза 11).
# Не ноль: щелчок в момент шага через порог читается как срабатывание двери,
# а не как то, что дом остался без света. Две с половиной секунды — это ровно
# столько, чтобы успеть сделать три шага и остановиться.
const BLACKOUT_WAIT := 2.6
# Уровни зон, которые считаются «в доме». Балкон исключён по имени: уровень
# у него attic, а стоит игрок под открытым небом.
const HOUSE_LEVELS := ["floor1", "attic", "roof", "cellar"]
const STASH_AGAIN := [
	["Третий ряд слева. Считать от лестницы.", 4.0],
	["Банки. За банками должно быть.", 3.4],
	["...третий ряд.", 2.8],
]

var ctx: Dictionary = {}
var timers: Array = []
var current: Dictionary = {}
# Свет и фонарь живут не в state и в его снимок не попадают, поэтому
# контрольная точка держит их отдельно. Смотри go() и retry().
var _light_snap: Variant = null
var _flash_snap: Variant = null
## Строка задачи на прошлом тике напоминания (фаза 18): по ней и видно,
## стоит игрок на месте или движется.
var _remind_last := ""
var _defs: Dictionary = {}

var _t: Dictionary = {}
var _cards: Dictionary = {}
var _tasks: Dictionary = {}
var _beats: Dictionary = {}
var _respawn: Dictionary = {}
var _ground := 0.0
var _attic := 0.0
# Сколько секунд игрок непрерывно находится в доме в главе ТЕМНОТА. Считается
# только до блэкаута, дальше не нужен никому.
var _dark_inside := 0.0
var _recovery_resume: Dictionary = {}
var _intro_shop: RefCounted


func _init(context: Dictionary) -> void:
	ctx = context
	_t = GameData.texts()
	_cards = _t["CHAPTER_CARDS"]
	_tasks = _t["TASKS"]
	_beats = _t["BEATS"]
	var site := GameData.site()
	_respawn = (site["RESPAWN"] as Dictionary).duplicate(true)
	# УЛИЦА (фаза 9). data/site.json — конвертированные данные прототипа и
	# не правится, а точка возврата главе всё равно нужна: ловить игрока здесь
	# некому, но [R] обязан работать в любой главе, а не в тех, где угроза.
	# Крыльцо — та же точка, что у ТЕМНОТЫ и ВОРОТ.
	if not _respawn.has("street"):
		_respawn["street"] = {"at": [-2.3, 0.45, 5.9], "yaw": PI}
	# ДЕРЕВНЯ (фаза 12) — тем же способом и по той же причине. Крыльцо:
	# на нём же кончаются ТЕМНОТА и ВОРОТА, и после поимки на линии игрок
	# обязан оказаться на своём участке, а не там, где его взяли.
	if not _respawn.has("village"):
		_respawn["village"] = {"at": [-2.3, 0.45, 5.9], "yaw": PI}
	_ground = float(site["Y"]["GROUND"])
	_attic = float(site["Y"]["ATTIC"])
	_defs = {
		"prologue": {
			"enter": _prologue_enter,
			"task": _prologue_task,
			"on": {},
		},
		"arrive": {
			"card": _cards["arrive"],
			"enter": _arrive_enter,
			"task": _arrive_task,
			"on": {
				"figure": _arrive_figure,
				"figure-gone": _arrive_figure_gone,
				"called": _arrive_called,
				"house-open": _arrive_house_open,
				"door-locked": _arrive_door_locked,
			},
		},
		"light": {
			"card": _cards["light"],
			"enter": _light_enter,
			"task": _light_task,
			"on": {
				"power": _light_power,
				"chime": _light_chime,
				"call": _light_call,
				"window-figure": _light_window_figure,
				"radio-self": _radio_self,
				"kitchen-lid": _kitchen_lid,
				"figure-gone": _figure_gone,
			},
		},
		"loft": {
			"card": _cards["loft"],
			"enter": _loft_enter,
			"task": _loft_task,
			"on": {
				"stair-creak": _loft_stair_creak,
				"above-head": _above_head,
				"kettle-whistle": _kettle_whistle,
				"figure-gone": _figure_gone,
				"shed-light": _loft_shed_light,
				"switch": _loft_switch,
				"look": _loft_look,
				"diary-read": _loft_diary_read,
				"tape-taken": _loft_tape_taken,
				"watch-tape": _loft_watch_tape,
			},
		},
		"tapes": {
			"card": _cards["tapes"],
			"enter": _tapes_enter,
			"task": _tapes_task,
			"on": {
				"ladder-taken": _tapes_ladder_taken,
				"roof-entered": _tapes_roof_entered,
				"notebook-read": _tapes_notebook_read,
				"hatch-calm": _tapes_hatch_calm,
				"hatch-steps": _tapes_hatch_steps,
				"tape-shadow": _tape_shadow,
				"watch-tape": _tapes_watch_tape,
			},
		},
		"street": {
			"card": _cards["street"],
			"enter": _street_enter,
			"task": _street_task,
			"on": {
				"knock": _street_knock,
				"apples-tossed": _street_tossed,
				"street-scare": _street_scare,
				"car-dead": _street_car_dead,
				"arkady-1": _street_arkady1,
				"office-key": _street_office_key,
				"office-open": _street_office_open,
				"duty-log": _street_duty_log,
				"arkady-2": _street_arkady2,
				"fuel": _street_fuel,
				"tank-full": _street_tank_full,
				"car-nokey": _street_car_nokey,
				"drive": _dark_drive,
				"to-dark": _street_to_dark,
				"look": _street_look,
				"figure-gone": _figure_gone,
				"street-caught": _street_caught,
			},
		},
		"dark": {
			"card": _cards["dark"],
			"enter": _dark_enter,
			"task": _dark_task,
			"on": {
				"look": _dark_look,
				"bugs-shout": _dark_bugs_shout,
				"voice": _dark_voice,
				"stash-hint": _dark_stash_hint,
				"stash-again": _dark_stash_again,
				"stash": _dark_stash,
				"car-key": _dark_car_key,
				"drive": _dark_drive,
				"sealed": _sealed,
				"brought-back": _brought_back,
				"caught": _dark_caught,
			},
		},
		"village": {
			"card": _cards["village"],
			"enter": _village_enter,
			"task": _village_task,
			"on": {
				"hood": _village_hood,
				"arkady-empty": _village_arkady,
				"shop-locked": _village_shop_locked,
				"shop-open": _village_shop_open,
				"distributor": _village_rotor,
				"village-unfinished": _village_unfinished,
				# ФАЗА 18: напоминание по простою, см. _village_remind.
				"village-remind": _village_remind,
				"snt-returned": _village_resume_repaired,
				"kovrigin-letter": _village_letter,
				"kovrigin-tapes": _village_tapes,
				"grave-seen": _village_grave,
				"distributor-in": _village_done,
				"to-gate": _village_to_gate,
				"street-caught": _village_caught,
				# ФАЗА 18. Участковый дед в ДЕРЕВНЕ ловил ВХОЛОСТУЮ: ai.gd
				# доводит поимку до emit('caught'), у ТЕМНОТЫ и ВОРОТ ключ
				# есть, а у ДЕРЕВНИ его не было — глава событие не слышала,
				# и дед просто исчезал. Ключ тот же, что у ТЕМНОТЫ: игрока
				# возвращает к дому, и это правильно.
				"caught": _village_house_caught,
				"look": _village_look,
				"figure-gone": _figure_gone,
				"village-thunder": _village_thunder,
				# ФАЗА 18. Здесь стояли семь мёртвых строк — 'valya-seen',
				# 'valya-1', 'valya-2', 'valya-3', 'stones-done', 'mow-done',
				# 'grave-dug', и все семь вели в _village_push, то есть в один
				# вызов pushTask(). А emit() зовёт pushTask() БЕЗУСЛОВНО, после
				# любого события и независимо от таблицы (см. конец emit()).
				# Семь записей не делали ничего и обещали, что делают.
				"redhouse-notebook": _village_notebook,
			},
		},
		"gate": {
			"card": _cards["gate"],
			"enter": _gate_enter,
			"task": _gate_task,
			"on": {
				"bagged": _gate_bagged,
				"porch-storm": _gate_storm,
				"gate": _gate_gate,
				"gate-calm": _gate_calm,
				"gate-chase": _gate_chase,
				"sealed": _sealed,
				"brought-back": _brought_back,
				"car-nokey": _gate_car_nokey,
				"car-key": _gate_car_key,
				"drive": _gate_drive,
				"caught": _gate_caught,
			},
		},
	}
	_intro_shop = preload("res://src/intro_shop.gd").new(ctx)
	_intro_shop.register()


## Створка ворот стоит на z = 0 (site.json FENCES, id "gate"): по знаку
## разницы и решается, с какой стороны от неё двойник (фаза 15).
const GATE_Z := 0.0

## Свет по деревне гасится поимённо на крыльце. Часть источников входит
## в lights.gd OFF_GRID, поэтому домашний блэкаут их не выключает.
## Три лампы СНТ сетевые: при блэкауте они уже погашены. Здесь снимаем
## и их флаги, чтобы последующее восстановление сети не вернуло свет.
## Поле cord относится только к геометрии подвеса и не задаёт питание.
## ФАЗА 17: плюс второй столб второй линии. Пропусти его в этом списке —
## и в финальном кадре погасшей деревни останется гореть одна лампа ровно
## против ворот, то есть на самом видном месте.
const VILLAGE_LAMPS := ["office-porch", "stop", "booth", "shop-win", "redhouse",
	"lane-pole", "lane-pole-2", "barn", "pump", "hen-yard", "club-win",
	"redhouse-up", "barn-gate", "pump-lane", "snt-gate", "snt-lane", "snt-booth"]


# ------------------------------------------------------------------ движок ---

func start() -> void:
	go("prologue")


## ФАЗА 18. Тихий вход (silent) — для retry(). Карточка главы на нём не
## всплывает и чекпоинт не переснимается: игрок не входит в главу заново,
## он возвращается на свою задачу внутри неё. До фазы 18 обоего не замечали,
## потому что чекпоинт стоял ровно на входе, и «переснять» значило «оставить
## как было»; с задачным чекпоинтом повторный снимок стирал бы ровно ту
## ступень, ради которой [R] и нажимают.
func go(name: String, silent := false) -> void:
	_intro_shop.cancel()
	var pursuit: Variant = ctx.get("pursuit")
	if pursuit != null: pursuit.cancel()
	_recovery_resume = {}
	var director: Variant = ctx.get("horror")
	if director != null: director.invalidate("chapter")
	_ctx_call("cancelDialogue")
	var recovery: Variant = ctx.get("capture")
	if recovery != null: recovery.cancel()
	var cut: Variant = ctx.get("cutscene")
	if cut != null and cut.playing: cut.cancel()
	var s: GameState = ctx["state"]
	s.chapter = name
	var snt: Variant = ctx.get("snt")
	if snt != null:
		snt.resync(s)
	s.chapterTime = 0.0
	timers.clear()
	current = _defs.get(name, {})
	var outskirts: Variant = ctx.get("outskirts")
	if outskirts != null and outskirts.has_method("resume_pending_timers"):
		outskirts.resume_pending_timers()
	if current.is_empty():
		return

	var show := func() -> void:
		if current.has("enter"):
			(current["enter"] as Callable).call(ctx)
		if not silent:
			s.checkpoint = s.snapshot()
			_light_snap = ctx["lights"].snapshot()
			_flash_snap = ctx["flashlight"].snapshot()
		pushTask()
		ctx["ui"].setChapterTag(current.get("card", ""))

	if current.has("card") and not silent:
		ctx["audio"].rewind(0.7)
		ctx["ui"].showCards([current["card"]], show, 2.6)
	else:
		show.call()


func end(which: String) -> void:
	_intro_shop.cancel()
	var pursuit: Variant = ctx.get("pursuit")
	if pursuit != null: pursuit.cancel()
	var director: Variant = ctx.get("horror")
	if director != null: director.invalidate("end")
	_ctx_call("cancelDialogue")
	var recovery: Variant = ctx.get("capture")
	if recovery != null: recovery.cancel()
	var cut: Variant = ctx.get("cutscene")
	if cut != null and cut.playing: cut.cancel()
	var s: GameState = ctx["state"]
	s.chapter = "end"
	var snt: Variant = ctx.get("snt")
	if snt != null:
		snt.cancel_runtime()
	s.ending = which
	# ФАЗА 17. Таймеры главы гасятся вместе с ней. Отложенные события живут
	# в timers и продолжали срабатывать после титров: 'gate-chase' поднимал
	# погоню за игроком, которого уже нет, а отложенный 'drive' крутил
	# катсцену отъезда поверх карточки поимки.
	timers.clear()
	# Дождь и погоня кончаются вместе с игрой: uniform композита живёт
	# в шейдере, а не в главе, и без этого он шёл бы поверх титров.
	var w: Variant = ctx.get("weather")
	if w != null:
		w.clear()
	var th: Variant = ctx.get("threat")
	if th != null and bool(th.get("final_mode")):
		th.end_final()
	var e: Dictionary = _t["ENDINGS"][which]
	ctx["controls"].enabled = false
	ctx["audio"].stop_hum(0.4)
	var done := func() -> void:
		_ctx_call("onFinished", [which])
	ctx["ui"].showCards(e["pages"], done, 0)


# Поимка. Сначала лицо, и только потом карточка: экран провала сразу после
# стингера читается как техническое сообщение, а не как то, что с игроком
# сейчас произошло. Скример зовём защищённо — его выключают в настройках,
# и текстура лица может не загрузиться.
func fail(kind: String) -> void:
	var recovery: Variant = ctx.get("capture")
	if recovery != null:
		recovery.begin(kind)
		return
	var s: GameState = ctx["state"]
	s.failCount += 1
	ctx["controls"].enabled = false
	var fails: Dictionary = _t["FAILS"]
	ctx["ui"].showFail(fails.get(kind, fails["dark"]))


func retry() -> void:
	_intro_shop.cancel()
	var anchor: Variant = ctx.get("external_retry_anchor")
	ctx.erase("external_retry_anchor")
	var director: Variant = ctx.get("horror")
	if director != null: director.invalidate("retry")
	_ctx_call("cancelDialogue")
	var recovery: Variant = ctx.get("capture")
	if recovery != null: recovery.cancel()
	var cut: Variant = ctx.get("cutscene")
	if cut != null: cut.cancel()
	var s: GameState = ctx["state"]
	var snap: Variant = s.checkpoint
	var fails: int = s.failCount     # счётчик провалов переживает откат:
	ctx["ui"].hideFail()             # иначе «он стал медленнее» не наступит никогда
	if snap != null and String(snap) != "":
		s.restore(String(snap))
	s.failCount = fails
	s.checkpoint = snap
	# ФАЗА 18. Снимок — это JSON с флагами и инвентарём; видимости узлов
	# в нём нет и быть не может. Пока чекпоинт стоял один на главу, откат
	# уходил туда, где ещё ничего не взято, и расхождения не было видно.
	# Задачный чекпоинт делает его правилом: предмет, взятый после последней
	# смены задачи, пропадал и из мира, и из рук. Строго ДО go(): модули глав
	# в enter() досматривают свои узлы сами и должны видеть уже откатанные флаги.
	Interact.resync_world(ctx)
	# Свет и фонарь откатываем вместе с флагами. Без этого [R] возвращал
	# в главу, где дом уже погашен, а батарея высажена прошлой попыткой:
	# к третьему разу играть было нечем.
	if _light_snap != null:
		ctx["lights"].restore(_light_snap)
	if _flash_snap != null:
		ctx["flashlight"].restore(_flash_snap)
	# После третьего провала он незаметно медленнее на десять процентов.
	if s.failCount >= 3:
		_ctx_call("slowThreat", [0.9])
	go(s.chapter, true)

	# Игрока возвращают на крыльцо — там, где он его отпустил. Раньше [R]
	# не переносил игрока ВООБЩЕ: он возрождался в той же точке, где его взяли,
	# в полутора метрах от деда, и вся фора уходила на то, чтобы разойтись.
	# Таблица RESPAWN покрывает только 'dark' и 'gate': в первых главах угрозы
	# нет, и телепорт после провала там был бы новым правилом на пустом месте.
	#
	# Строго ДО resetThreat(): дед разводится относительно controls.feet(),
	# и если переставить игрока после, его разведут с точкой поимки — то есть
	# ровно туда, куда игрок сейчас не вернётся.
	var pursuit: Variant = ctx.get("pursuit")
	if not anchor is Vector3 and s.chapter == "village" and s.has("snt-return-inspected") \
			and not s.has("snt-pursuit-escaped") and not s.has("snt-returned") and pursuit != null:
		anchor = pursuit.retry_anchor()
	if anchor is Vector3:
		ctx["controls"].place(anchor.x, anchor.y, anchor.z, 0.0)
	elif _respawn.has(s.chapter):
		var back: Dictionary = _respawn[s.chapter]
		var at: Array = back["at"]
		ctx["controls"].place(float(at[0]), float(at[1]), float(at[2]), float(back["yaw"]))
		timer("brought-back", 0.8)

	# Погоня фазы 15 откат не переживает: она начинается по снятой цепи,
	# а [R] возвращает в главу до неё.
	var th: Variant = ctx.get("threat")
	if th != null and bool(th.get("final_mode")):
		th.end_final()
	# Развести его с игроком после входа в главу. В «ВОРОТАХ» он остаётся стоять
	# там же, где поймал, — вплотную, — и ловит снова в том же кадре.
	# Он же выдаёт фору: respawn() ставит grace и mute.
	_ctx_call("resetThreat")
	ctx["controls"].enabled = true


## Точка возрождения главы или пустой словарь. Читают её двое: retry() выше —
## напрямую по таблице, и отладочный прыжок main._debug_jump() — через это.
func respawn_of(chapter: String) -> Dictionary:
	return _respawn.get(chapter, {})


func timer(event: String, seconds: float, payload: Variant = null) -> void:
	timers.append({"event": event, "t": seconds, "payload": payload})


# Задача уходит в интерфейс всегда, включая пустую: setTask(null) гасит
# и постоянную строку, и вспышку. Под старым `if (t)` строка от прошлой главы
# доживала до первой непустой задачи следующей — в прологе и в финале
# это выглядело как невыполненная цель.
##
## ФАЗА 18, ЖАЛОБА ПЕТРА ПУНКТ ТРЕТИЙ. Здесь же снимается контрольная точка.
## Это единственное место во всём проекте, где присваивается state.task, —
## значит, единственное, где видно, что игрок продвинулся на ступень. До сих
## пор чекпоинт снимали в трёх местах на всю игру (вход в главу, хлопок
## автомата в ТЕМНОТЕ, начало опасного отрезка УЛИЦЫ), и в выросшей до двух
## десятков ступеней ДЕРЕВНЕ он был один — на входе: любая поимка стирала
## полчаса.
##
## Снимок берётся ПОСЛЕ присваивания task: строка задачи входит в snapshot(),
## и снятый раньше чекпоинт вернул бы игрока на предыдущую ступень.
func pushTask(force_checkpoint := false) -> void:
	if current.is_empty() or not current.has("task"):
		return
	var s: GameState = ctx["state"]
	var t: Variant = (current["task"] as Callable).call(s)
	ctx["ui"].setTask(t)
	# Сравнение Variant'ами, а не через String(): task в начале главы null,
	# и String(null) в GDScript — ошибка времени выполнения, а не пустая строка.
	var moved: bool = t != null and str(t) != "" and t != s.task
	s.task = t
	if moved or force_checkpoint:
		# Свет и фонарь идут в снимок вместе с флагами по той же причине,
		# что и в retry(): к третьей попытке иначе нечем играть.
		s.checkpoint = s.snapshot()
		_light_snap = ctx["lights"].snapshot()
		_flash_snap = ctx["flashlight"].snapshot()


func emit(event: String, payload: Variant = null) -> void:
	var recovery: Variant = ctx.get("capture")
	if recovery != null and recovery.active(): return
	if not current.is_empty() and current.has("on"):
		var on: Dictionary = current["on"]
		if on.has(event):
			(on[event] as Callable).call(ctx, payload)
	# Ранний обход возможен до полива: HUD ещё показывает прежнюю задачу.
	# Его четыре перехода всё равно сохраняют сюжет, свет и фонарь вместе.
	var s: GameState = ctx["state"]
	var snt_progress := s.chapter == "village" and SntQuest.FLAGS.has(event) and s.has(event)
	if recovery == null or not recovery.active(): pushTask(snt_progress)


func update(dt: float) -> void:
	_resume_recovery_threat()
	for i in range(timers.size() - 1, -1, -1):
		# ФАЗА 18. Сверка границ. Событие таймера может увести в другую главу
		# (_village_done -> go("gate")), а go() чистит timers ЦЕЛИКОМ — и
		# следующий шаг цикла лез в пустой массив. Ошибка ждала в коде с фазы
		# 12 и не всплывала, пока в ДЕРЕВНЕ был ровно один таймер: со вторым
		# ('village-remind', напоминание по простою) она вылезла первым же
		# прогоном smoke_village.
		if i >= timers.size():
			continue
		var tm: Dictionary = timers[i]
		tm["t"] = float(tm["t"]) - dt
		if float(tm["t"]) <= 0.0:
			timers.remove_at(i)
			emit(String(tm["event"]), tm["payload"])
	_dark_tick(dt)
	# Глава ДЕРЕВНЯ (фаза 12) тикает отсюда, а не из main.gd: тот принадлежит
	# lead и в этой фазе не правится. Место при этом ровно то, что нужно —
	# update() глав зовётся уже под frozen-гейтом, то есть постановка не идёт
	# под паузой, ридером и карточкой.
	var vq: Variant = ctx.get("village")
	if vq != null and String((ctx["state"] as GameState).chapter) == "village":
		vq.update(dt)


# Ожидание блэкаута. Свет гаснет не по секундомеру главы, а по тому, где стоит
# игрок: страшнее, когда гаснет в доме, а не на улице у машины.
func _dark_tick(dt: float) -> void:
	var s: GameState = ctx["state"]
	if s.chapter != "dark":
		return
	if s.has("blackout"):
		_banya_second(s)
		return
	if not _in_house():
		_dark_inside = 0.0
		return
	_dark_inside += dt
	if _dark_inside >= BLACKOUT_WAIT:
		_blackout(ctx, false)


# ВТОРОЙ ЗАХОД В БАНЮ. Один из двух полнокадровых ударов фазы, и второй
# из них — заевшая дверь погреба. Больше нельзя: инструмент теряет силу,
# а на четвёртом применении за игру перестаёт работать вовсе.
#
# Ставится по входу в зону, а не точкой [E]: удар по нажатию клавиши читается
# как реакция игры на игрока, а не как то, что происходит само.
func _banya_second(s: GameState) -> void:
	if s.has("banya-second"):
		return
	var zn := _zone_now()
	if String(zn.get("id", "")) != "banya":
		return
	s.set_flag("banya-second")
	ctx["ui"].say(_beats["banyaSecond"], 4.0)
	Interact._hit_full(ctx)
	# Ковш качается сам — знак ставится следом, чтобы игроку было куда
	# посмотреть после удара.
	var om: Variant = ctx.get("omens")
	if om != null and om.has_method("force"):
		_after(2.6, func() -> void: om.force("ladle-sway"))


func _in_house() -> bool:
	var zn := _zone_now()
	if String(zn.get("id", "")) == "balcony":
		return false
	return HOUSE_LEVELS.has(String(zn.get("level", "")))


## Зона под ногами игрока или пустой словарь.
func _zone_now() -> Dictionary:
	var ctrl: Variant = ctx.get("controls")
	if ctrl == null:
		return {}
	var world: Variant = ctx.get("world")
	if not (world is Dictionary):
		return {}
	var at: Variant = (world as Dictionary).get("zone_at")
	if not (at is Callable):
		return {}
	var f: Vector3 = ctrl.feet()
	return (at as Callable).call(f.x, f.y, f.z)


## Показать или спрятать мелочь дома и сарая. Нет data/home.json — тихо ничего.
func _home_show(c: Dictionary, id: String, on: bool) -> void:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return
	var home: Dictionary = (w as Dictionary).get("home", {})
	var n: Variant = (home.get("nodes", {}) as Dictionary).get(id)
	if n is Node3D:
		(n as Node3D).visible = on


## Показать или спрятать предмет участка. Нет data/yard.json — тихо ничего.
func _yard_show(c: Dictionary, id: String, on: bool) -> void:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return
	var yard: Dictionary = (w as Dictionary).get("yard", {})
	var n: Variant = (yard.get("nodes", {}) as Dictionary).get(id)
	if n is Node3D:
		(n as Node3D).visible = on


# ТОЧКА НЕВОЗВРАТА. Гаснет свет и одновременно замолкает холодильник, который
# гудел девятнадцать минут. Ни музыки, ни крика. Только тишина.
#
# Хлопок автомата — единственный акцент этой секунды и единственный, который
# правило «до 23:40 ни одного акцента» разрешает: он диегетический, свет гаснет
# вместе с ним.
#
# quiet = true — это откат по [R]: мир надо привести в то же состояние, но без
# хлопка, реплики и стингера. Иначе каждая смерть начиналась бы с концерта.
func _blackout(c: Dictionary, quiet: bool) -> void:
	var s: GameState = c["state"]
	_story_night(c, "blackout")
	c["lights"].blackout()
	c["audio"].stop_hum(0.05)
	c["audio"].set_outdoor_level(0.35)
	# На место замолчавшего холодильника встаёт дыхание пустого дома: девятнадцать
	# минут гула ушли, и абсолютная тишина читается как выключенный звук.
	c["audio"].loop("house-dark", true)
	s.set_flag("blackout")
	s.threatState = "patrol"
	_dark_inside = 0.0
	# В окне бани горит свет, который игрок выключал час назад, и рубильник
	# ему теперь не указ. Объяснить это нечем — в этом и дело.
	var l: Variant = c["lights"]
	if l != null and l.has_method("set_off_grid"):
		l.set_off_grid("banya", true)
		l.setLamp("banya", true)
	# Мокрые следы от бани к крыльцу. Появляются вместе с темнотой, а не
	# заранее: до неё игрок прошёл бы по ним и не заметил.
	#
	# ФАЗА 13. И появляются они ТОЛЬКО ЕСЛИ БАНЮ ИСТОПИЛ САМ ИГРОК. Раньше
	# следы включались просто так, и это была самая дорогая мелочь фазы 11,
	# работавшая вхолостую: мокрые следы из холодной бани не значат ничего,
	# потому что мыться в ней было негде. Теперь игрок сам натаскал дров, сам
	# растопил каменку — и через две главы находит на своей дорожке чужие
	# босые следы оттуда. Не топил — следов нет, и это честно.
	if s.has("banya-fired"):
		_yard_show(c, "wet-steps", true)
	# Витя с огорода. Полторы минуты спустя, когда игрок уже внутри и занят
	# щитком: «клоп сожрал всё, надо травить». Единственная ступень фазы,
	# которую игроку ЗАДАЮТ вслух, — и задаёт её тот, от кого он прячется.
	if not s.has("bugs-heard"):
		timer("bugs-shout", 92.0)
	# И две перемены внутри (фаза 12). Обе молча, обе только на осмотр:
	# кухня, где игрок сорок минут назад тёр яблоки, встречает его тёркой
	# в раковине и дорожкой сахара к люку; на верстаке в сарае аккуратным
	# рядком разложены его собственные вещи, которые он оставил в доме.
	# Порча безопасного места работает сильнее любого удара, а удара тут нет.
	Interact.wreck_kitchen(c)
	_home_show(c, "shed-things", true)
	# «Он зовёт по имени» обязана прозвучать за прохождение хотя бы раз, значит
	# таймер заводится и на откате — но только если реплика ещё не звучала.
	if not s.has("voice-heard"):
		timer("voice", 60.0)
	if quiet:
		pushTask()
		return
	c["audio"].sfx("breaker")
	c["ui"].say(_beats["silenceFall"], 5.0)
	# Контрольная точка переснимается ЗДЕСЬ, а не на входе в главу: снимок входа
	# застал бы игрока на улице, в горящем доме, и [R] после первой же поимки
	# заставлял бы заново идти к крыльцу ради того же хлопка.
	s.checkpoint = s.snapshot()
	_light_snap = c["lights"].snapshot()
	_flash_snap = c["flashlight"].snapshot()
	pushTask()


# ----------------------------------------------------------------- ПРОЛОГ ---

func _prologue_enter(c: Dictionary) -> void:
	var s: GameState = c["state"]
	if s.has("intro-cards-seen"):
		_intro_shop.enter(func() -> void: go("arrive"))
		return
	c["audio"].rewind(1.6)
	c["renderer"].set_tracking(0.9)
	var done := func() -> void:
		if s.chapter != "prologue": return
		c["renderer"].set_tracking(0.0)
		s.set_flag("intro-cards-seen")
		_intro_shop.enter(func() -> void: go("arrive"))
	c["ui"].showCards(_t["INTRO_CARDS"], done)


func _prologue_task(s: GameState) -> Variant:
	return _intro_shop.task(s)


func _task_none(_s: GameState) -> Variant:
	return null


# ----------------------------------------------------------------- ПРИЕЗД ---

func _arrive_enter(c: Dictionary) -> void:
	# z -1.35, а не -1.9: коробка «жигулей» занимает z от -3.6 до -1.8, и точка
	# -1.9 была внутри неё. Капсулу выталкивало вверх, и Сергей начинал игру
	# стоя на крыше собственной машины, в полутора метрах над землёй.
	c["controls"].place(0.2, _ground, -1.35, PI)
	# place() наклон взгляда больше не сбрасывает: на переходах через люк
	# от этого камеру рывком выпрямляло. Здесь начало игры, и выпрямить
	# её надо явно — иначе Сергей выходит из машины глядя в землю.
	c["controls"].pitch = 0.0
	c["controls"].pitch_target = 0.0
	_story_night(c, "arrival")
	c["audio"].start_outdoors()
	c["ui"].say(_beats["arrived"], 4.0)
	timer("figure", 22.0)


func _arrive_task(s: GameState) -> Variant:
	if not s.has("gate-open"):
		return _tasks["chain"]
	if not s.has("bags-2"):
		return _tasks["trunk"]
	if not s.has("called"):
		return _tasks["call"]
	if not s.hasItem("key"):
		return _tasks["key"]
	if not s.has("entered"):
		return _tasks["door"]
	return _tasks["door"]


# Силуэт у калитки в первую минуту. Сергей окликает его как деда и ответа
# не получает, а через три секунды силуэта нет. Это и был дед, но узнать его
# не дают — одна несостоявшаяся встреча в начале оправдывает всю дальнейшую
# двусмысленность.
#
# Постановка идёт на двойнике 'echo', а не на 'threat'. Фигурой 'threat' каждый
# кадр распоряжается Threat.update, и в этой главе threatState равен 'absent':
# show('threat', true) гасился бы в том же кадре, до отрисовки. Силуэт не
# появлялся ни разу, и Сергей окликал пустоту.
func _arrive_figure(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("figure-seen"):
		return
	s.set_flag("figure-seen")
	_ctx_call("holdEcho", [6.0])
	c["actors"].place("echo", 3.0, _ground, 1.6, PI)
	c["actors"].show("echo", true)
	c["ui"].say(_beats["figureAtGate"], 3.2)
	timer("figure-gone", 3.4)


func _arrive_figure_gone(c: Dictionary, _p: Variant) -> void:
	c["actors"].show("echo", false)
	c["ui"].say(_beats["figureGone"], 3.6)


func _arrive_called(c: Dictionary, _p: Variant) -> void:
	c["state"].set_flag("called")
	c["ui"].say(_beats["noAnswer"], 3.6)
	c["audio"].dog_far()


func _arrive_house_open(_c: Dictionary, _p: Variant) -> void:
	go("light")


func _arrive_door_locked(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if not s.has("hint-shed"):
		s.set_flag("hint-shed")
		pushTask()


# ------------------------------------------------------------------- СВЕТ ---

func _light_enter(c: Dictionary) -> void:
	_story_night(c, "lights-on")
	timer("chime", 150.0)
	timer("window-figure", 190.0)
	# Фаза 11. Между 190-й секундой и концом главы не происходило ничего вовсе,
	# а глава идёт минут двенадцать. Две постановки на разнесённых минутах.
	timer("radio-self", 262.0)
	timer("kitchen-lid", 352.0)


func _light_task(s: GameState) -> Variant:
	if not s.has("breaker-on"):
		return _tasks["breaker"]
	if not s.has("power-on"):
		return _tasks["fuse"]
	if not s.has("note-read"):
		return _tasks["note"]
	if not s.has("groceries"):
		return _tasks["groceries"]
	if not s.callsMade.has("hospital"):
		return _tasks["hospital"]
	if not s.callsMade.has("neighbour"):
		return _tasks["neighbour"]
	# Две необязательные ступени фазы 12. Появляются, только если игрок САМ
	# начал: закрыл первое окно или поставил чайник. Не начал — задача его
	# туда и не погонит, а рутина остаётся рутиной, а не поручением.
	if s.has("window-hall") or s.has("window-living") or s.has("window-aunt"):
		if not _windows_all(s):
			return _tasks["windows"]
	if not s.has("kettle-on") and _windows_all(s):
		return _tasks["kettle"]
	return _tasks["loft"]


## Все три форточки закрыты? Дубль того же условия живёт в interact.gd —
## там оно решает, говорить ли «все три», здесь — снимать ли строку задачи.
static func _windows_all(s: GameState) -> bool:
	return s.has("window-hall") and s.has("window-living") and s.has("window-aunt")


func _light_power(c: Dictionary, _p: Variant) -> void:
	# Холодильник загудел. Он будет гудеть девятнадцать минут реального
	# времени и замолчит в точке невозврата — это самый сильный звук игры.
	c["audio"].start_hum()
	c["state"].set_flag("hum-on")
	c["ui"].say(_beats["fridgeHum"], 3.0)
	_story_night(c, "power-restored")


func _light_chime(c: Dictionary, _p: Variant) -> void:
	if c["state"].has("power-on"):
		c["audio"].clock_chime(1)


func _light_call(c: Dictionary, p: Variant) -> void:
	var s: GameState = c["state"]
	var which := String(p)
	s.callsMade[which] = true
	if which == "neighbour":
		c["ui"].say(_beats["neighbourCalled"], 5.0)
		s.set_flag("knows-vitya-missing")
	if s.callsMade.has("hospital") and s.callsMade.has("neighbour"):
		go("loft")


# --------------------------------------------------------------- МАНСАРДА ---

func _loft_enter(c: Dictionary) -> void:
	_story_night(c, "loft")
	c["state"].set_flag("loft-open")
	timer("stair-creak", 95.0)
	timer("shed-light", 240.0)
	timer("above-head", 244.0)
	# ФАЗА 12. Чайник, поставленный игроком в прошлой главе, свистит СЕЙЧАС —
	# когда игрок наверху и один. Скачок — это прерывание цикла на пике
	# нагрузки, и весь фокус в том, что запустил его сам игрок.
	timer("kettle-whistle", 172.0)
	# Баня открывается как место именно здесь: до МАНСАРДЫ у игрока нет ни
	# повода туда идти, ни фонаря, чтобы что-то в ней разглядеть.
	_yard_show(c, "banya-clothes", true)
	_yard_show(c, "cellar-shed-key", not (c["state"] as GameState).hasItem("cellar-shed-key"))


func _loft_task(s: GameState) -> Variant:
	if not s.has("diary-read"):
		return _tasks["diary"]
	if not s.hasItem("mobile"):
		return _tasks["mobile"]
	var tapes := 0
	for n: String in ["1", "2", "3", "5"]:
		if s.hasItem("tape-" + n):
			tapes += 1
	if tapes < 4:
		return _tasks["tapes"]
	if not s.has("balcony-seen"):
		return _tasks["balcony"]
	if s.has("shed-light-on") and not s.has("shed-light-off"):
		return _tasks["shed"]
	# И третья такая же (фаза 12): альбом появляется в задаче, только если
	# игрок его уже нашёл. Ведёт он на погост, но говорит об этом одной
	# соскобленной фотографией — то есть не говорит вовсе.
	if s.has("album-found") and not s.has("album-seen"):
		return _tasks["album"]
	return _tasks["watch"]


# Игрок стоит внизу, и наверху скрипит третья ступенька. Один раз, коротко.
#
# Фаза 8: если лестница сейчас в конусе взгляда — НА скрипе, а не после него,
# на середине нижнего марша стоит фигура. Восемь десятых секунды, без своего
# звука: скрип уже прозвучал, и он же становится её объяснением. Отличие
# «испуга» от обычного мелькания haunt ровно одно и оно дешёвое — фигура
# ставится туда, куда игрок смотрит, а не за границу взгляда.
func _loft_stair_creak(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("stair-creak"):
		return
	s.set_flag("stair-creak")
	c["audio"].creak(1.2)
	c["ui"].say(_beats["stairCreak"], 3.0)
	# Середина нижнего марша: site.json STAIRS main-lower, ступень 4.5 из 9.
	if _scares_on(c) and _in_view(c, Vector3(-5.05, 1.25, 10.97), 0.55, 14.0):
		_soft_scare(c, Vector3(-5.05, 1.25, 10.97), 0.8)


# Мягкий испуг: фигура в конусе взгляда на доли секунды и без единого
# полнокадрового перепада. Прецедент принят в фазе 4 (_gate_gate), здесь он
# идёт ещё тише — ни стингера, ни тряски.
func _soft_scare(c: Dictionary, at: Vector3, seconds: float) -> void:
	_ctx_call("holdEcho", [seconds + 1.2])
	c["actors"].place("echo", at.x, at.y, at.z, 0.0)
	var feet: Vector3 = c["controls"].feet()
	c["actors"].face("echo", feet.x, feet.z)
	c["actors"].show("echo", true)
	timer("figure-gone", seconds)


# Фигура снаружи северного окна веранды, лицом внутрь. Девять десятых секунды,
# без звука и без реплики: игра о ней не сообщает вовсе, и пропустить её можно
# целиком — в этом и смысл. Точка та же, что у haunt::win-n-veranda, значит
# проверена tests/test_haunt_points.gd.
func _light_window_figure(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("window-figure") or not _scares_on(c):
		return
	s.set_flag("window-figure")
	_soft_scare(c, Vector3(-4.30, _ground, 6.24), 0.9)


# Общий конец обоих мягких испугов и силуэта у калитки.
func _figure_gone(c: Dictionary, _p: Variant) -> void:
	c["actors"].show("echo", false)


## Смотрит ли игрок сейчас в эту точку. cos — половина конуса, far — дальше
## фигура читается пятном и пугать перестаёт.
func _in_view(c: Dictionary, p: Vector3, cos_lim: float, far: float) -> bool:
	var r: Variant = c.get("renderer")
	if r == null:
		return false
	var cam: Variant = r.camera
	if not (cam is Camera3D):
		return false
	var eye: Vector3 = (cam as Camera3D).global_position
	var to := p - eye
	var d := to.length()
	if d < 1.5 or d > far:
		return false
	return (-(cam as Camera3D).global_transform.basis.z).normalized().dot(to / d) > cos_lim


## Сила сюжетного удара под галочку. Выключенные резкие эффекты режут стингер
## и тряску втрое: событие остаётся — крышка правда падает, выход правда
## пропадает, — но бьёт оно уже не по игроку. Убирать сами события нельзя,
## на них держится сюжет.
func _hit(c: Dictionary, power: float, shake_amount: float) -> void:
	var k := 1.0 if _scares_on(c) else SOFT_K
	c["audio"].stinger(power * k)
	c["flashlight"].shake(shake_amount * k)


## Галочка «Скримеры и резкие эффекты». Нет модуля в ctx — считаем включённой:
## так вела себя игра до фазы 8.
func _scares_on(c: Dictionary) -> bool:
	var f: Variant = c.get("scaresOn")
	return true if not (f is Callable) else bool((f as Callable).call())


# В сарае загорается свет. Игрок выключал его сам сорок минут назад.
func _loft_shed_light(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("shed-light-on"):
		return
	s.set_flag("shed-light-on")
	c["lights"].setLamp("shed", true)
	# Дребезг накала слышно со двора: лампа зажглась сама, и это единственное,
	# чем сцена себя выдаёт.
	c["audio"].sfx("lamp-on")


func _loft_switch(c: Dictionary, p: Variant) -> void:
	var d: Dictionary = p
	var s: GameState = c["state"]
	if String(d["lamp"]) == "shed" and not bool(d["on"]) and s.has("shed-light-on"):
		s.set_flag("shed-light-off")
		c["ui"].say(_beats["shedReturned"], 5.0)
		s.set_flag("tin-returned")


func _loft_look(c: Dictionary, p: Variant) -> void:
	var id := String(p)
	var s: GameState = c["state"]
	if id == "balcony" or id == "shed-light":
		s.set_flag("balcony-seen")
		if s.has("shed-light-on") and not s.has("shed-light-off"):
			c["ui"].say(_beats["shedLightSeen"], 4.4)


func _loft_tape_taken(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	var n := 0
	for k: String in ["1", "2", "3", "5"]:
		if s.hasItem("tape-" + k):
			n += 1
	if n == 4:
		pushTask()


# Фаза 9: выход из МАНСАРДЫ стоит дороже. Была одна любая кассета — стало две
# и дневник. Причина простая и меряется секундомером: на одной кассете глава
# кончалась через восемь минут после входа, и весь дом оставался неосмотренным.
const LOFT_TAPES := 2


func _loft_watch_tape(c: Dictionary, _p: Variant) -> void:
	_loft_try_exit(c, true)


func _loft_diary_read(c: Dictionary, _p: Variant) -> void:
	_loft_try_exit(c, false)


## Оба условия проверяются с обеих сторон: дневник читают и до кассет, и после,
## и глава обязана кончиться в тот момент, когда сошлось последнее, — а не
## только на событии кассеты.
func _loft_try_exit(c: Dictionary, from_tape: bool) -> void:
	var s: GameState = c["state"]
	if s.tapesWatched.size() < LOFT_TAPES:
		return
	if not s.has("diary-read"):
		# Реплика, а не молчание: иначе игрок смотрит третью кассету, четвёртую
		# и не понимает, чего от него ещё хотят.
		if from_tape:
			c["ui"].say("Кассеты посмотрел. Надо ещё раз в его тетрадь.", 4.0)
		return
	go("tapes")


# ----------------------------------------------------------------- ПЛЁНКИ ---

func _tapes_enter(c: Dictionary) -> void:
	_story_night(c, "tapes")
	c["state"].set_flag("roof-available")
	timer("tape-shadow", 45.0)


func _tapes_task(s: GameState) -> Variant:
	if not s.tapesWatched.has("3"):
		return _tasks["watch"]
	if not s.tapesWatched.has("5"):
		return _tasks["watch"]
	if not s.hasItem("ladder"):
		return _tasks["ladder"]
	if not s.has("roof-entered"):
		return _tasks["roof"]
	if not s.has("notebook-read"):
		return _tasks["roof"]
	if not s.hasItem("tape-x"):
		return _tasks["roof"]
	# Тоже необязательная: ключ от погреба надо было сперва найти в бане.
	if s.hasItem("cellar-shed-key") and not s.has("cellar-shed-open"):
		return _tasks["cellarShed"]
	# И след от штатива у тетради (фаза 12) — первый крючок на Ковригина.
	# Появляется, только если игрок сам заметил вмятины в пыли.
	if s.has("tripod-mark") and not s.has("camera-known"):
		return _tasks["camera"]
	# Яблони (фаза 13). Тем же правилом, что окна и баня: появляется, только
	# если игрок обтряс первую сам. Строчка «× яблоки собрать» лежит в записке
	# на кухне с первой главы, и это задание — она.
	if Interact._apples_picked(s) > 0 and not s.has("apples-done"):
		return _tasks["orchard"]
	if not s.tapesWatched.has("x"):
		return _tasks["lastTape"]
	return _tasks["lastTape"]


# Стремянка из кладовки сразу встаёт под люком: отдельной переноски нет,
# а без этого игрок с «взятой» стремянкой видит у люка пустое место
# и не понимает, чем ему подниматься.
func _tapes_ladder_taken(c: Dictionary, _p: Variant) -> void:
	c["props"].show_dynamic("ladder-at-hatch")


func _tapes_roof_entered(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("roof-entered"):
		return
	s.set_flag("roof-entered")
	c["lights"].setLamp("roofspace", true)


# ДЖАМПСКЕЙР №1. Игрок берёт тетрадь, и за спиной падает крышка люка,
# отрезая свет снизу. Лица нет: пугает звук и потеря выхода.
func _tapes_notebook_read(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("hatch-slam"):
		return
	s.set_flag("hatch-slam")
	_hit(c, 1.0, 1.6)
	if not _scares_on(c) or not _attic_warning(c, "horror-latch", Vector3(-4.15, 5.9, 14.35), 0.9, 3):
		c["audio"].knock(1)
	c["lights"].blackout(9)
	c["lights"].setLamp("roofspace", false)
	c["renderer"].set_tracking(1)
	c["ui"].say(_beats["hatchSlam"], 2.0)
	timer("hatch-calm", 9.0)
	if _scares_on(c): timer("hatch-steps", 4.0)
	s.give("tape-x")
	c["props"].show_dynamic("unlabelled-tape")


func _attic_warning(c: Dictionary, sound: String, at: Vector3, gain: float, priority: int) -> bool:
	var audio: Variant = c.get("audio")
	if audio == null or not audio.has_method("spatial_sfx"): return false
	if audio is GameAudio:
		return bool(audio.spatial_sfx(sound, at, gain, 12.0, "warning", priority))
	return bool(audio.spatial_sfx(sound, at, gain, 12.0))


func _tapes_hatch_steps(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.chapter != "tapes" or not s.has("hatch-slam") or not _scares_on(c): return
	# Продолжение того же хлопка после затихания защёлки. Разговор, новая
	# постановка или уход с чердака отменяют его, не откладывая испуг вдогонку.
	var phone: Variant = c.get("phone")
	if phone != null and bool(phone.talking): return
	var voice: Variant = c.get("voice")
	if voice != null:
		for method: String in ["dialogue_active", "tape_active", "vitya_active"]:
			if voice.has_method(method) and bool(voice.call(method)): return
	var director: Variant = c.get("horror")
	if director != null and (director.exclusive() or float(director.cooldown) > 0.0): return
	var zone := _zone_now()
	if not ["attic", "roof"].has(String(zone.get("level", ""))): return
	_attic_warning(c, "horror-run-wood", Vector3(-1.1, 7.8, 13.2), 0.58, 1)


func _tapes_hatch_calm(c: Dictionary, _p: Variant) -> void:
	c["renderer"].set_tracking(0)
	c["lights"].restorePower()
	c["ui"].say("Крышка. Просто крышка люка.", 3.4)


# Фаза 9: кассеты `x` мало. Плёнка без этикетки — это ответ, а до ответа игрок
# обязан увидеть хотя бы одну «соседскую» ленту целиком: без них поворот
# не читается вовсе, а посмотреть их можно было и не начиная.
func _tapes_watch_tape(c: Dictionary, p: Variant) -> void:
	if String(p) != "x":
		return
	var s: GameState = c["state"]
	if not (s.tapesWatched.has("3") or s.tapesWatched.has("5")):
		c["ui"].say("Ничего не понял. Надо смотреть по порядку — третью или пятую.", 4.6)
		return
	go("street")


# ------------------------------------------------------------------ УЛИЦА ---
#
# Самая длинная глава игры и единственная, где на экране есть кто-то, кроме
# деда. Соседи не опасны: они атмосфера и подсказка. Дед на улицу не выходит
# ИИ (nav.json держит street в banRooms, и слоя под неё в графе нет) — он
# появляется здесь тремя постановочными фигурами на двойнике 'echo',
# и ни одна из них не говорит: до 23:40 в игре нет ни одного его слова,
# и это правило сторожит tests/test_voice_manifest.gd.

func _street_enter(c: Dictionary) -> void:
	var s: GameState = c["state"]
	s.set_flag("street-open")
	_story_night(c, "street")
	# Соседи выходят на улицу вместе с главой, не раньше: Аркадий на кольцо,
	# наблюдатель — в своё окно.
	var nb: Variant = c.get("neighbours")
	if nb != null:
		# Сюда же попадает возврат по [R] после поимки на линии, а он бывает
		# посреди главы. Соседи обязаны встать по ФЛАГАМ, а не по началу:
		# иначе Аркадий, с которым уже поговорили дважды, снова уходил на круг.
		var where := "route"
		if s.has("street-done"):
			where = "off"
		elif s.has("office-open"):
			where = "home"
		nb.set_arkady(where)
		nb.set_watcher(true)
	# И дед возвращается на линию, если игрок был пойман уже после его выхода:
	# точку возврата ставит street_quest.old_man(), и флаг в ней уже стоит.
	var stalk: Variant = c.get("stalk")
	if stalk != null and s.has("street-old-man") and not s.has("tank-full"):
		stalk.begin()
	# Стук — первое, что случается. Шесть секунд после карточки: игрок успевает
	# понять, что кассета кончилась, и не успевает пойти по своим делам.
	timer("knock", 6.0)


func _street_task(s: GameState) -> Variant:
	# ФАЗА 12: между «взял корзину» и «выбросил» встали два шага — натереть
	# с сахаром и попробовать. Каждый ведёт к ЖИВОЙ точке: это то самое
	# правило, на котором в фазе 9 споткнулась канистра.
	if not s.hasItem("apple-basket"):
		return _tasks["apples"]
	if not s.has("apples-grated"):
		return _tasks["grate"]
	if not s.has("apples-tasted"):
		return _tasks["taste"]
	if not s.has("apples-tossed"):
		return _tasks["apples"]
	if not s.has("car-dead"):
		return _tasks["carTry"]
	if not s.has("arkady-1"):
		return _tasks["arkadyFirst"]
	if not s.hasItem("office-key"):
		return _tasks["officeKey"]
	if not s.has("office-open"):
		return _tasks["office"]
	# Канистра — не украшение сцены, а замок: второй разговор Аркадия открывается
	# только с ней на руках (street_quest.talk_when). Без этой строки задача звала
	# к Аркадию, а точка «заговорить» молчала, и глава вставала намертво.
	if not s.has("canister-taken"):
		return _tasks["canister"]
	if not s.has("arkady-2"):
		return _tasks["arkadySecond"]
	if not s.has("fuel"):
		return _tasks["fuel"]
	# Необязательная ступень фазы 12: обход дверей появляется, только если игрок
	# постучал хотя бы в одну сам. Линия перестаёт быть коридором.
	if _knocked_some(s) and not s.has("knocked-around"):
		return _tasks["knockAround"]
	return _tasks["fillTank"]


static func _knocked_some(s: GameState) -> bool:
	return s.has("knock-shouter") or s.has("knock-boarded") or s.has("knock-watcher")


func _street_knock(c: Dictionary, _p: Variant) -> void:
	var q: Variant = c.get("street")
	if q != null:
		q.knock()


# Гэг отыгран — теперь удар. Четыре секунды: ровно столько, чтобы игрок успел
# выдохнуть и решить, что сцена кончилась.
func _street_tossed(_c: Dictionary, _p: Variant) -> void:
	timer("street-scare", 4.0)


func _street_scare(c: Dictionary, _p: Variant) -> void:
	var q: Variant = c.get("street")
	if q != null:
		q.scream()


func _street_car_dead(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("car-dead"):
		return
	s.set_flag("car-dead")
	c["ui"].say(_beats["carDead"], 4.0)


func _street_arkady1(c: Dictionary, _p: Variant) -> void:
	# Он ушёл дальше по дороге и продолжает свой круг. Второй раз игрок найдёт
	# его у калитки — там, где он уже никуда не пойдёт.
	var nb: Variant = c.get("neighbours")
	if nb != null:
		nb.set_arkady("route")


func _street_office_key(_c: Dictionary, _p: Variant) -> void:
	pass


func _street_office_open(c: Dictionary, _p: Variant) -> void:
	# Правление открылось — Аркадий встаёт у своей калитки и ждёт.
	var nb: Variant = c.get("neighbours")
	if nb != null:
		nb.set_arkady("home")


func _street_duty_log(c: Dictionary, _p: Variant) -> void:
	# Улика на руках. Дальше её судьбу решают концовки, ровно как с кассетами.
	c["state"].evidence = true


func _street_arkady2(c: Dictionary, _p: Variant) -> void:
	var nb: Variant = c.get("neighbours")
	if nb != null:
		nb.set_arkady("home")


func _street_fuel(_c: Dictionary, _p: Variant) -> void:
	pass


func _street_tank_full(c: Dictionary, _p: Variant) -> void:
	c["ui"].say(_tasks["fillTank"], 2.4)
	# Бак залит — линия пустеет. Держать его на дороге до самой машины значит
	# отнять у игрока последние двадцать метров: бежать уже некуда и незачем.
	var stalk: Variant = c.get("stalk")
	if stalk != null:
		stalk.finish()


# Поимка на линии. Та же машина, что в доме: сначала лицо, потом карточка,
# дальше [R]. Разница одна — точку возврата поставил street_quest в минуте
# отсюда, а не в начале главы, и откатывается только дорога к бочке.
func _street_caught(_c: Dictionary, _p: Variant) -> void:
	fail("street")


# Бак полон, мотор схватывает — и глохнет: замок зажигания пустой. Отсюда
# и начинается ТЕМНОТА: ключи внизу, а внизу его дом.
func _street_car_nokey(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("street-done"):
		return
	s.set_flag("street-done")
	c["ui"].say(_beats["carNoKey"], 4.0)
	# Соседи уходят: с этой минуты на улице никого, кроме него.
	var nb: Variant = c.get("neighbours")
	if nb != null:
		nb.set_arkady("off")
		nb.set_watcher(false)
	timer("to-dark", 4.2)


func _street_to_dark(_c: Dictionary, _p: Variant) -> void:
	go("dark")


func _street_look(c: Dictionary, p: Variant) -> void:
	var id := String(p)
	var s: GameState = c["state"]
	if id == "watcher-window" and not s.has("watcher-seen"):
		s.set_flag("watcher-seen")
		c["ui"].say(_beats["watcherWindow"], 4.0)


# ---------------------------------------------------------------- ТЕМНОТА ---
# Глава начинается на улице, у заглохшей машины, и первые полминуты игрок просто
# идёт домой. Точка невозврата — не вход в главу, а вход в ДОМ: см. _blackout().

func _dark_enter(c: Dictionary) -> void:
	# СВЕТ ГАСНЕТ НЕ ЗДЕСЬ. До фазы 11 блэкаут был первой строкой входа в главу,
	# а игрок в этот момент стоял на улице, у машины: самый сильный момент игры
	# приходился на пустое место. Теперь вход только заряжает сцену, а гасит
	# свет _blackout() — через BLACKOUT_WAIT секунд после того, как игрок вошёл
	# в дом. Ждёт этого _dark_tick() в общем update().
	var s: GameState = c["state"]
	# Ставим ДЕДА, а не актёра. actors.place('threat', ...) двигал фигуру,
	# и Threat.update возвращал её на свою this.pos в следующем же кадре:
	# строка была чисто декоративной, а глава начиналась с деда там, где
	# его бросил прошлый заход.
	#
	# На [R] эта строка отрабатывает ПОСЛЕ respawn'а из retry(): enter()
	# у главы с карточкой отложен до её конца. Так и надо — постановка главы
	# сильнее случайного узла, а расходятся они всё равно на два этажа:
	# игрок на крыльце, он в комнате деда. Фору respawn() при этом не сбивает,
	# grace живёт своим таймером.
	c["threat"].place_at(-3.0, _attic, 15.4)
	c["props"].show_dynamic("boots-by-fusebox")
	_second_lap(c)
	_dark_inside = 0.0
	# Откат по [R] возвращает в состояние ПОСЛЕ блэкаута — иначе игрока каждый
	# раз выбрасывало бы на крыльцо в горящий дом и заставляло входить заново
	# ради того же хлопка. Флаг переживает restore(), значит и решение тоже.
	if s.has("blackout"):
		_blackout(c, true)


# ВТОРОЙ ВИТОК (фаза 9). Игрок возвращается в дом после двадцати минут на улице,
# и дом уже не тот. Ни одного нового механизма: три подмены материала, две двери
# и один звук.
#
# Молча — принципиально. Ни стингера, ни реплики на сами перемены: игрок должен
# заметить их сам или не заметить вовсе. Единственная строка — общая, «что-то
# не так», и она не говорит, что именно.
func _second_lap(c: Dictionary) -> void:
	var s: GameState = c["state"]
	if s.has("second-lap"):
		return
	s.set_flag("second-lap")

	# Фотографии в рамах поменялись местами. Один вызов, три материала.
	var props: Variant = c.get("props")
	var mats: Variant = c.get("mats")
	if props != null and mats != null:
		Photos.shuffle(props, mats)

	# Две двери, которые игрок закрывал, открыты. Тихо: в этом вся их сила —
	# он не слышал момента, он видит результат.
	_ctx_call("setDoor", ["door-front", true, true])
	_ctx_call("setDoor", ["door-shed", true, true])
	s.set_flag("house-open")
	s.set_flag("shed-open")

	# Магнитофон крутит пустую плёнку сам. Через полминуты после входа —
	# не сразу: сразу это читается как часть карточки главы.
	var audio: Variant = c.get("audio")
	if audio != null:
		_after(28.0, func() -> void:
			if not bool(audio.sfx("tape-hum")):
				audio.click())

	c["ui"].say(_beats["backHome"], 4.2)


func _dark_task(s: GameState) -> Variant:
	# Пока свет горит, задача одна: дойти до дома. Строка TASKS.secondLap лежала
	# в текстах с прототипа и не показывалась ни разу за прохождение.
	if not s.has("blackout"):
		return _tasks["secondLap"]
	if not s.has("saw-boots"):
		return _tasks["toFusebox"]
	# До подсказки игрок знает только, что искать надо внизу, после неё —
	# где именно. Иначе строка задачи пересказывает дневник за него.
	if not s.has("stash-found"):
		return _tasks["stash"] if s.has("stash-hint") else _tasks["cellar"]
	# Тайник вскрыт, а ключей от машины нет — и это ТУПИК, если о нём молчать:
	# Пётр забрал ключ от ворот, снял цепь, сел в машину и упёрся в реплику
	# без задачи. Ключи лежат отдельной точкой в нише подпола, в двух шагах
	# от тайника, и с этой минуты задача ведёт ровно туда.
	if not s.hasItem("car-key"):
		return _tasks["keysDown"]
	# Ступень фазы 12: сарай. Стоит ПОСЛЕ ключей и ПЕРЕД «дойти до машины» —
	# то есть в ту минуту, когда игрок уже собрался уезжать. Ни предмета, ни
	# ключа там нет; там на верстаке аккуратным рядком лежат его собственные
	# вещи, которые он оставил в доме. Главу это не запирает: выход из неё
	# держат события 'stash' и 'car-key', а не строка задачи.
	if s.has("blackout") and not s.looked.has("shed-things"):
		return _tasks["shedThings"]
	# Клопы (фаза 13). Витя орёт с огорода, что мраморный клоп сожрал урожай
	# и его надо потравить, — и это единственная ступень фазы, которую игроку
	# ЗАДАЮТ вслух. Она необязательна: главу держат события 'stash' и 'car-key',
	# а не строка задачи. Порядок ступеней — порядок вещей: опрыскиватель,
	# яд, бочка, грядки.
	if s.has("bugs-heard") and not s.has("bugs-done"):
		if not s.hasItem("sprayer"):
			return _tasks["bugsSprayer"]
		if not s.hasItem("poison"):
			return _tasks["bugsPoison"]
		if not s.has("spray-mixed"):
			return _tasks["bugsMix"]
		return _tasks["bugsSpray"]
	return _tasks["lead"]


func _dark_look(c: Dictionary, p: Variant) -> void:
	if String(p) == "boots-by-fusebox":
		c["state"].set_flag("saw-boots")
		c["audio"].heartbeat(3, 104)


# КЛОПЫ (фаза 13). Витя орёт с огорода — из темноты, издалека, не показываясь.
# Он не угрожает и не зовёт по имени: он требует потравить мраморного клопа,
# который сожрал ему весь урожай. Смешно ровно до той секунды, пока не дойдёт,
# что кричит это человек, который сейчас ходит по дому в двадцати метрах.
#
# Реплика диегетическая и звучит из точки: середина огорода, x -0.6 z 22.2.
# Нет записи — субтитра нет тоже, ровно как у остальных реплик деда (правило
# фазы 5): бубнёж без слов и строка задачи говорят достаточно.
func _dark_bugs_shout(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("bugs-heard"):
		return
	s.set_flag("bugs-heard")
	var voice: Variant = c.get("voice")
	if voice == null or not bool(voice.say_vitya_key("plot-1", 22.0, 0.0)):
		c["audio"].mumble(1.4)
	pushTask()


# Из темноты он зовёт по имени — тем же ритмом, каким Сергей звал его самого
# с участка час назад.
func _dark_voice(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("voice-heard"):
		return
	s.set_flag("voice-heard")
	# Сценарная реплика, а не фон: «он зовёт по имени» обязана прозвучать.
	# Деда в этот момент на карте может не быть вовсе, поэтому расстояние
	# задано вручную — средний план, слова ещё разбираются.
	var voice: Variant = c.get("voice")
	if voice == null or not bool(voice.say_vitya_key("threat-0", 9.0, 0.0)):
		c["audio"].mumble(1.6)
		c["ui"].say(_t["THREAT_LINES"][0], 4.0)
	timer("stash-hint", 25.0)


# Подсказка про подпол, если игрок не связал дневник с банками сам.
# Стука в стену нет: внизу никого, стучать некому.
func _dark_stash_hint(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("stash-found"):
		return
	s.set_flag("stash-hint")
	c["ui"].say("В тетради было про подпол. За банки, третий ряд слева.", 4.4)
	timer("stash-again", CELLAR_TICK, {"left": CELLAR_WAIT, "n": 0})


# Тот же текст другими словами — но только пока игрок внизу и только
# если тайник ещё не вскрыт. Слой берём тем же порогом, по которому ходит дед
# (layerOf в game/ai.js): своя копия порогов здесь однажды разъехалась бы.
func _dark_stash_again(c: Dictionary, p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("stash-found"):
		return
	var d: Dictionary = p
	var in_cellar := Threat.layer_of(c["controls"].feet().y) == "cellar"
	var left := float(d["left"]) - (CELLAR_TICK if in_cellar else 0.0)
	var n := int(d["n"])
	if left > 0.0:
		timer("stash-again", CELLAR_TICK, {"left": left, "n": n})
		return
	if n >= STASH_AGAIN.size():
		return
	var line: Array = STASH_AGAIN[n]
	c["ui"].say(line[0], line[1])
	if n + 1 < STASH_AGAIN.size():
		timer("stash-again", CELLAR_TICK, {"left": CELLAR_WAIT, "n": n + 1})


# Тайник вскрыт: ключ от замка на воротах и кассета, которую дед снял сам.
# С этой минуты он не обходит участок, а ищет.
#
# ГЛАВА НЕ ОТПУСКАЕТ БЕЗ КЛЮЧЕЙ ОТ МАШИНЫ. Ключей в подполе два, и обязательным
# был только один: вскрытие тайника было единственным выходом из ТЕМНОТЫ,
# а ключи от машины лежали отдельной точкой и ни на что не влияли. Игрок снимал
# цепь, садился в машину, получал реплику «замок зажигания пустой» — и всё:
# обработчика 'car-nokey' в главе ВОРОТА не было, задача продолжала требовать
# «завести машину», и выхода игра не подсказывала. Теперь замок стоит здесь,
# в двух шагах от точки с ключами, а не в тридцати метрах от неё.
func _dark_stash(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	s.set_flag("stash-found")
	# Улики на руках решают, чем кончится игра, — отсюда и до самых ворот.
	s.evidence = true
	if not s.hasItem("car-key"):
		c["ui"].say(_beats["keysAlsoHere"], 4.4)
		return
	_to_gate(c)


# Ключи от машины взяты. Если тайник уже вскрыт — это и есть выход из главы.
func _dark_car_key(c: Dictionary, _p: Variant) -> void:
	if not (c["state"] as GameState).has("stash-found"):
		return
	_to_gate(c)


# Выход из ТЕМНОТЫ. До фазы 12 отсюда шли прямо в ВОРОТА, и вся вторая
# половина игры была «взял ключи и уехал». Теперь между ними стоит ДЕРЕВНЯ:
# ключи на руках, а машина не поедет — из трамблёра вынут бегунок.
func _to_gate(c: Dictionary) -> void:
	var s: GameState = c["state"]
	s.threatState = "hunt"
	var done := func() -> void:
		go("village")
	c["ui"].showCards([_t["RULES_CARD"]], done)


# Уехать без улик можно в любой момент. Игра не мешает и не предупреждает.
func _dark_drive(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.chapter == "end" or s.has("drive-played"): return
	s.set_flag("drive-played")
	# ФАЗА 16. Второй вход в ту же концовку — и катсцена отъезда обязана идти
	# и здесь. Уехать из главы ТЕМНОТА можно ровно так же, как из ВОРОТ, и
	# финал, который в одной главе показывают, а в другой нет, — это не
	# решение, а забытая ветка.
	_drive_away(c, _ending_of(c["state"]))


func _sealed(c: Dictionary, _p: Variant) -> void:
	c["ui"].say("Наверху тихо. Совсем тихо.", 4.0)


# Реплику ставит retry() таймером, а не говорит сразу: карточка главы
# в этот момент ещё на экране и прячет весь HUD вместе с субтитром.
func _brought_back(c: Dictionary, _p: Variant) -> void:
	c["ui"].say(BROUGHT_BACK, 4.4)


func _dark_caught(_c: Dictionary, _p: Variant) -> void:
	fail("dark")


# ---------------------------------------------------------------- ДЕРЕВНЯ ---
#
# Главная жалоба Петра после шестого прохождения: «после спуска в подвал взял
# ключи и уехал». Второго акта не существовало. Здесь он и стоит — между
# ТЕМНОТОЙ и ВОРОТАМИ, ровно в ту минуту, когда игрок уже собрался домой.
#
# Замок один — бегунок трамблёра. Заколоченный дом и погост добровольные:
# пройти главу, не заходя ни туда, ни туда, обязано быть можно, и это первое,
# что проверяет smoke_village.gd.
#
# ДВОЙНОЕ ДНО. Слой «живых людей» не выдуман — он написан в концовках ещё
# в прототипе: «Ковригин на комиссию не пришёл. Прислал письмо на трёх листах,
# его никто не читал вслух». Кассеты 1 и 5 сняты им, из заколоченного дома
# напротив. Слой «потустороннего» — то, чем это кажется Сергею ночью, пока
# он письмо не нашёл. Оба слоя настоящие, и переключается игрок сам.

func _village_enter(c: Dictionary) -> void:
	var s: GameState = c["state"]
	s.threatState = "patrol"
	# Свет по-прежнему выключен: блэкаут держится с ТЕМНОТЫ. Единственный свой
	# источник — керосинка из фазы 11, у которой наконец появилась работа.
	_story_night(c, "village")
	var vq: Variant = c.get("village")
	if vq != null:
		vq.enter()
	# Соседи с улицы ушли ещё в конце УЛИЦЫ (_street_car_nokey), и обратно
	# их никто не звал: на линии не осталось никого, кроме деда и Аркадия,
	# которого нет дома.
	if not s.has("village-said"):
		s.set_flag("village-said")
		c["ui"].say(_beats["villageStart"], 4.4)
	# ФАЗА 15. Гроза заходит ЗА ГЛАВУ до финала, а не сваливается на крыльцо
	# готовой: сначала морось и один раскат далеко, за околицей. К воротам
	# она уже над головой (см. _gate_storm), и по этому слышно, сколько
	# времени прошло, — часов в интерфейсе нет.
	var w: Variant = c.get("weather")
	if w != null:
		w.set_rain(0.22)
		timer("village-thunder", 26.0)
	# ФАЗА 18. Напоминание по простою. Строка задачи висит в углу кадра
	# 12-м кеглем и на неё можно не смотреть полчаса; в главе, выросшей до
	# двух десятков ступеней, это и значит «застрял». Приём не новый — так
	# сделана единственная подсказка игры про тайник (_dark_stash_hint);
	# здесь таймер перезаводит сам себя и говорит ТЕКУЩУЮ строку задачи,
	# а не заранее написанный текст.
	timer("village-remind", VILLAGE_REMIND)
	_village_resume_repaired(c, null)


## Строка задачи ДЕРЕВНИ. Она же — порядок ночи: каскад выдаёт ступени по
## одной, и другой карты у игрока нет.
##
## ФАЗА 17. Отсюда убрана одна строка, и она прятала половину главы:
##
##     if s.hasItem("distributor"): return _tasks["backToCar"]
##
## Она стояла ВТОРОЙ, выше полива и выше линии Вали. Взял бегунок в сельпо —
## строка задачи в тот же кадр переключалась на машину, и всё, что ниже,
## переставало существовать. При этом просьба деда про огород звучит ВСЛУХ
## ровно на открытии сельпо (_village_shop_open -> BEATS.waterAsked), то есть
## игра говорила одно, а вела в другое. Ровно это Пётр и увидел: сходил в
## сельпо, поставил бегунок, завёл машину — титры.
##
## Теперь порядок такой, каким его и писали: капот -> Аркадий -> сельпо ->
## полив -> улика -> линия Вали -> добровольные ступени -> и только потом
## машина. Замок главы переехал в village_quest.fixed() и считается по
## village_chores_done().
func _village_task(s: GameState) -> Variant:
	if not s.has("distributor-gone"):
		return _tasks["hood"]
	if not s.hasItem("shop-key"):
		return _tasks["askArkady"]
	# Ступень держится до БЕГУНКА, а не до открытой двери: в сельпо игрок идёт
	# за деталью, и «сельпо в восточном конце линии» обязано стоять в строке,
	# пока деталь не в кармане.
	if not s.hasItem("distributor"):
		return _tasks["shop"]
	# ФАЗА 15. Полив стоит ВЫШЕ необязательных веток фазы 13, и это не
	# перестановка ради порядка.
	#
	# Было так: строка про ферму — единственная во всей игре, которая вообще
	# НАЗЫВАЕТ ферму словами, — стояла седьмой в очереди, и до неё очередь
	# доходила ровно никогда: выше шесть ранних return. Плюс вход в цепочку
	# требовал флага, который не ставился (см. interact.gd, spray-barrel).
	# Итог, который Пётр и увидел: околица построена, достижима, пятнадцать
	# точек зарегистрированы — и не существует, потому что игра о ней молчит.
	#
	# Теперь ступень идёт в основной линии: сходил в сельпо — Сергей вспомнил
	# просьбу деда, и строка про ферму появляется в первые минуты главы.
	#
	# ФАЗА 17. Гейта _watering_started здесь больше нет, и он не потерялся —
	# он умер. Гейт спрашивал «начал ли игрок цепочку сам», и первым его
	# условием было shop-open; после перестановки выше сельпо уже открыто
	# ВСЕГДА, когда сюда доходит очередь. Плюс полив стал обязательным, и
	# ждать, пока игрок сам заглянет в бочку, больше нечего.
	if not s.has("water-done"):
		if not s.hasItem("farm-key") and not s.has("pump-open"):
			return _tasks["farmKey"]
		if not s.has("pump-open"):
			return _tasks["pumpDoor"]
		if not s.has("pump-on"):
			return _tasks["pumpBreaker"]
		if not s.hasItem("leyka"):
			return _tasks["leyka"]
		if not s.has("leyka-filled"):
			return _tasks["tapWater"]
		return _tasks["waterRows"]
	# The fourth row sends the player here by recalling Vitya's note.  Heating
	# starts only after watering, so the disappearing water is the cause rather
	# than an unrelated errand encountered on the way.
	if not s.has("damper-shut"):
		if not s.has("banya-fired"):
			return _tasks["banyaStoke"] if s.hasItem("firewood") \
				else _tasks["banyaFire"]
		return _tasks["banyaDamper"]
	# ФАЗА 18. БАНЯ, ВТОРАЯ ПОЛОВИНА, И ПОГРЕБ. Шесть ступеней, и ни одной
	# новой постройки: всё это стоит в игре с фаз 11-15 и было необязательным.
	# Погреб — тот самый «красный дом рядом с домом» из жалобы Петра: он в
	# 2.2 м от северо-западного угла дома, задание у него есть, а открыть
	# было нечем, потому что ключ висит в бане, куда игра не звала.
	#
	# Цепь идёт ровно так, как она построена: пар -> надпись изнутри ->
	# ключ с гвоздя -> погреб -> керосинка -> чердак бани.
	if not s.has("banya-written"):
		if s.has("banya-hot"):
			return _tasks["banyaSteam"]
		# While the plot timer runs, keep another live lead on the HUD.  The
		# callback will push banyaSteam when the room reaches temperature.
		if not s.has("kovrigin-letter") and not s.has("boarded-tapes"):
			return _tasks["boarded"]
		if not s.has("snt-returned") and not s.has("valya-1"):
			return _tasks["banyaWait"]
		var waiting_valya: Variant = _valya_task(s)
		return waiting_valya if waiting_valya != null else _tasks["banyaWait"]
	# Четыре ступени между надписью и чердаком существуют ровно затем, чтобы
	# на чердак попасть, и потому висят под одним условием. Игрок мог пройти
	# их в любом порядке и без подсказки — ключ, погреб и керосинка открыты
	# с фаз 11-13, — и спрашивать их после того, как кассета уже в руках,
	# значило бы гнать его по кругу за предметами, которые ему не нужны.
	if not s.has("bathloft-found"):
		if not s.hasItem("cellar-shed-key"):
			return _tasks["banyaKey"]
		if not s.has("cellar-shed-open"):
			return _tasks["cellarShed"]
		if not s.hasItem("lantern"):
			return _tasks["cellarLantern"]
		# Керосинку надо ЗАЖЕЧЬ: на чердаке бани темно, и это единственное
		# применение предмета, который до фазы 18 не открывал ничего.
		if not s.has("lantern-lit"):
			return _tasks["lanternLight"]
		return _tasks["bathloft"]
	# Знак на торце кассеты ведёт во вторую обязательную локацию. Высота
	# площадки — runtime-only, поэтому точную промежуточную строку возвращает
	# OutskirtsQuest; старый save без нового контроллера всё равно получает
	# безопасную первую задачу.
	if not s.has("mill-clue"):
		var outskirts_runtime: Variant = ctx.get("outskirts")
		if outskirts_runtime != null and outskirts_runtime.has_method("mill_task"):
			var mill_now: Variant = outskirts_runtime.mill_task(s)
			if mill_now != null:
				return mill_now
		return _tasks["millReach"]
	# Журнал мельницы открывает последний обход перед прежней цепочкой улики.
	# Старые village-снимки сохраняют прежние флаги, но получают эту ступень.
	var snt_task: Variant = SntQuest.task_for(s)
	if snt_task != null:
		return snt_task
	# ФАЗА 17. Улика. Одна из двух, и любая: письмо в правление у Аркадия или
	# кассеты из заколоченного дома. Кто заглянул к Аркадию на стол, получил
	# письмо даром и этой строки не увидит вовсе.
	#
	# Считается по ФЛАГУ 'boarded-tapes', а не по предмету 'kovrigin-tapes':
	# тот же предмет выдаёт холм Вали (valya_quest, 'grave-dig'), и по предмету
	# замок закрывала бы сама линия Вали — то есть не закрывал бы никто.
	if not s.has("kovrigin-letter") and not s.has("boarded-tapes"):
		return _tasks["boarded"]
	# ФАЗА 15. Линия Вали. Идёт СРАЗУ ЗА поливом и уликой.
	#
	# ФАЗА 17: стала обязательной, и гейт «пока игрок сам не подошёл к ограде»
	# снят внутри _valya_task. Задача обязана вести к ограде сама — иначе
	# главу запирает шаг, о котором игра не сказала ни слова.
	var vq: Variant = _valya_task(s)
	if vq != null:
		return vq
	# Три необязательные ступени фазы 13 и все по тому же правилу, что баня
	# и яблони: строка появляется, только когда игрок сам начал. Ни одна
	# из них главу не запирает.
	if s.has("schedule-half") and not s.has("schedule-done"):
		return _tasks["schedule"]
	if s.looked.has("tractor-cabin") and not s.hasItem("crowbar"):
		return _tasks["crowbar"]
	if s.hasItem("crowbar") and not s.has("well-freed"):
		return _tasks["well"]
	if s.has("well-freed") and not s.has("well-raised"):
		return _tasks["wellBucket"]
	if s.has("redhouse-in") and not s.looked.has("redhouse-drawing"):
		return _tasks["redhouse"]
	if s.has("vent-shut") and not s.has("seedlings-done"):
		return _tasks["seedlings"]
	return _tasks["backToCar"]


## Строка задачи линии Вали или null. Порядок ровно тот, в котором линия
## и проходится: увидел -> поговорил -> камни -> вернулся -> покос -> холм
## -> вернулся -> наверх. Каждый шаг называет СЛЕДУЮЩЕЕ МЕСТО, а не действие:
## «скосить траву» без «за домами, на второй линии» отправило бы игрока
## косить свой огород.
func _valya_task(s: GameState) -> Variant:
	# ФАЗА 17. Гейта 'shop-open'/'valya-seen' здесь больше нет. Правило «у главы
	# одна основная линия за раз» осталось и стоит выше: каскад пускает сюда
	# только после сельпо, полива и улики. А вот второе условие — 'valya-seen',
	# то есть «игрок сам подошёл к ограде и увидел, что там кто-то стоит», —
	# с ОБЯЗАТЕЛЬНОЙ линией не живёт: главу запирал бы шаг, о котором игра
	# молчит, пока игрок случайно не пройдёт мимо нужного забора.
	if not s.has("valya-1"):
		return _tasks["valyaTalk"]
	if not s.has("stones-done"):
		return _tasks["valyaStones"]
	if not s.has("valya-2"):
		return _tasks["valyaAgain"]
	# ФАЗА 18. Коса получила свою ступень. Раньше «скосить траву» стояло без
	# предусловия, а коса лежит в ЗАПЕРТОМ шкафу в сарае, и ключ от него —
	# от Вали: игрок доходил до второй линии, упирался в траву в пояс и
	# возвращался ни с чем.
	if not s.hasItem("scythe") and not s.has("mow-done"):
		return _tasks["valyaScythe"]
	if not s.has("mow-done"):
		return _tasks["valyaMow"]
	if not s.has("grave-dug"):
		return _tasks["valyaGrave"]
	if not s.has("valya-3"):
		return _tasks["valyaAgain"]
	if not s.has("redhouse-notebook"):
		return _tasks["valyaUp"]
	# ФАЗА 18. Здесь Вали у ограды УЖЕ НЕТ, и строка valyaAgain на этом шаге
	# была прямой ложью: она отправляла к тому, кого в мире не осталось.
	if not s.has("valya-gone"):
		return _tasks["valyaEmpty"]
	return null


## Сделано ли в деревне то, ради чего Сергей сюда ехал и ради чего его тут
## держали (фаза 17). Это и есть замок главы — единственный, кроме бегунка.
##
## ТРИ ВЕЩИ, И НИ ОДНА НЕ ВЫДУМАНА ПОД ЗАМОК.
##   water-done — вся цепочка полива. О ней дед просит ВСЛУХ, на открытии
##                сельпо, и до фазы 17 просьбу можно было не выполнять вовсе:
##                строка задачи переключалась на машину раньше, чем игрок
##                выходил из сельпо.
##   улика      — письмо в правление ИЛИ кассеты из заколоченного дома. Любая:
##                узнать, ради чего тебя тут держали, можно с двух концов.
##                По ФЛАГУ 'boarded-tapes', а не по предмету 'kovrigin-tapes':
##                тот же предмет выдаёт холм Вали, и по предмету замок
##                закрывала бы сама линия Вали — то есть никто.
##   valya-gone — вся линия Вали, семь шагов. Она кончается пустой оградой
##                и переложенными камнями, и без неё ночь остаётся списком
##                поручений.
##
## Отказ говорит вслух и говорит ТЕКУЩУЮ СТРОКУ ЗАДАЧИ (_village_unfinished):
## молчаливое «нет» у заведённой машины читается поломкой, а не задачей.
##
## ФАЗА 18, РЕШЕНИЕ ПЕТРА. Плюс две: baня и погреб. Формула фазы 17
## расширяется осознанно, и вот чем это оправдано — обе постройки СТОЯТ
## в игре с фаз 11 и 13, обе озвучены, у обеих есть задания, и обе были
## необязательны настолько, что ни одна строка задачи в них не вела.
##   banya-written  — надпись на запотевшем стекле изнутри. Её сделал тот,
##                    кто сидел в закрытой парилке, пока она грелась, и
##                    она же второй раз называет озеро (см. lake-told).
##   bathloft-found — кассета на балке чердака бани. Её достают керосинкой
##                    из погреба: единственное применение предмета, который
##                    до этой фазы не открывал ничего.
##   mill-clue      — журнал наблюдений на верхней площадке старой мельницы.
##                    Его знак виден на торце кассеты; лопасть верхней лестницы
##                    сначала нужно убрать ручным колесом.
## Все три — улики, ставят s.evidence и продолжают ту же ночную линию.
static func village_chores_done(s: GameState) -> bool:
	if not s.has("water-done"):
		return false
	if not s.has("valya-gone"):
		return false
	if not s.has("banya-written"):
		return false
	if not s.has("bathloft-found"):
		return false
	if not s.has("mill-clue"):
		return false
	if not s.has("snt-returned"):
		return false
	return s.has("kovrigin-letter") or s.has("boarded-tapes")


## ФАЗА 17. Здесь стоял _watering_started — «начал ли игрок цепочку полива».
## Он спрашивал, заглянул ли игрок в пустую бочку, нашёл ли ключ на ферме,
## открыл ли водокачку, взял ли лейку, — и пускал строку про ферму, только
## если да. Правило было верное для добровольной ветки: у главы одна основная
## линия за раз, и поручение из ниоткуда читается багом.
##
## Полив стал ОБЯЗАТЕЛЬНЫМ, и ждать, пока игрок начнёт сам, больше нечего:
## первым его условием было shop-open, а после перестановки каскада сельпо
## к этому месту открыто всегда. Функция удалена целиком, а не оставлена
## мёртвой: неиспользуемый гейт следующая фаза прочтёт как рабочий.


func _village_hood(c: Dictionary, _p: Variant) -> void:
	# Первая же реплика объясняет замок вслух: пустой трамблёр без слов
	# читается как сломанная игра.
	_after(2.2, func() -> void:
		c["ui"].say(_beats["carDeadAgain"], 3.4))
	_village_voice(c, "village-0")


func _village_arkady(c: Dictionary, _p: Variant) -> void:
	# Дошёл до Аркадия — теперь понятно, куда идти дальше, и понятно это
	# из вещей на столе, а не из строки задачи.
	var s: GameState = c["state"]
	if not s.has("arkady-hint"):
		s.set_flag("arkady-hint")
		# ФАЗА 17. Через .get(), и это не перестраховка: строки 'noOneHome'
		# в data/texts.json НЕ БЫЛО ВОВСЕ, а обращение по ключу роняет
		# обработчик — на первом же визите к Аркадию, то есть на второй
		# минуте главы. Строка добавлена, но читать её жёстко всё равно
		# нельзя: тексты — данные, и сборка без них обязана идти.
		var line := String(_beats.get("noOneHome", ""))
		if line == "":
			return
		_after(3.4, func() -> void:
			c["ui"].say(line, 3.2))


func _village_shop_locked(_c: Dictionary, _p: Variant) -> void:
	pass


func _village_shop_open(c: Dictionary, _p: Variant) -> void:
	# Сельпо открылось — уличная лампа над витриной гаснет вместе с внутренней
	# только в конце главы; здесь она просто зажигается.
	var l: Variant = c.get("lights")
	if l != null:
		l.set_off_grid("shop-in", true)
		l.set_off_grid("shop-win", true)
		l.setLamp("shop-win", true)
	# ФАЗА 15. И здесь же вслух — просьба деда про огород. Задача про ферму
	# встаёт в этот же момент (_watering_started), и без реплики она читалась
	# бы как поручение из ниоткуда: игрок минуту назад искал бегунок.
	var s: GameState = c["state"]
	if not s.has("water-asked"):
		s.set_flag("water-asked")
		_after(2.0, func() -> void:
			c["ui"].say(_beats["waterAsked"], 4.4))


## Бегунок в кармане. Раньше здесь говорилось «вернуться к машине» — и это
## была правда ровно до фазы 17: замок главы был один, бегунок, и других дел
## у Сергея не оставалось.
##
## Теперь дела остались, и жёсткая строка про машину была бы тем же враньём,
## из-за которого игра кончалась через минуту после сельпо. Говорится ТЕКУЩАЯ
## строка задачи — та же, что стоит в интерфейсе.
func _village_rotor(c: Dictionary, _p: Variant) -> void:
	c["ui"].say(String(_village_task(c["state"] as GameState)), 2.6)
	# ФАЗА 18. И здесь же дед уходит с линии. Раньше его убирал только
	# village_quest по флагу 'distributor-in' — то есть в самом конце главы,
	# а фаза 17 отодвинула этот конец на пятнадцать ступеней. Отрезок деда
	# WEST_V -30 .. EAST_V 26 кончается ровно у сельпо (зона shop x [25,33]),
	# и Пётр видел ровно это: «вышел из сельпо, а он тут» — всю главу, до
	# самой машины.
	#
	# Бегунок в кармане — линия пустеет. Тот же довод, что у УЛИЦЫ на
	# 'tank-full': держать его на дороге дальше значит отнять у игрока всю
	# оставшуюся ночь, а бежать уже некуда и незачем.
	var stalk: Variant = c.get("stalk")
	if stalk != null:
		stalk.finish()


## Капот с бегунком в руках, но в деревне не сделано то, ради чего сюда ехали.
## Отказ ОБЯЗАН быть вслух и обязан называть, чего не хватает: молчаливое
## «нет» у машины, к которой игрок принёс нужную деталь, читается поломкой.
##
## Строка берётся из того же каскада, что и задача в интерфейсе, — второй
## копии списка дел в игре нет и не будет. Прецедент — _village_rotor выше.
func _village_unfinished(c: Dictionary, _p: Variant) -> void:
	c["ui"].say(String(_village_task(c["state"] as GameState)), 3.6)


## ФАЗА 18. Тик напоминания. Перезаводит себя сам и молчит, пока игрок
## занят — то есть пока строка задачи МЕНЯЕТСЯ. Говорит только тогда, когда
## она не менялась целый период: это и есть «застрял», и ровно это Пётр
## описал словами «я не понимал, что делать дальше».
##
## Молчит на карточках и во время поимки: там свои реплики, и наложить на
## них третью значит потерять все три.
func _village_remind(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.chapter != "village":
		return
	timer("village-remind", VILLAGE_REMIND)
	var t: Variant = _village_task(s)
	if t == null or str(t) == "":
		return
	if str(t) != _remind_last:
		# Задача сменилась за последний период — игрок движется, не мешаем.
		_remind_last = str(t)
		return
	if bool(c["ui"].card.open) or not bool(c["controls"].enabled):
		return
	c["ui"].say(str(t), 4.0)


func _village_letter(c: Dictionary, _p: Variant) -> void:
	# Улика того же веса, что кассеты и журнал: письмо поднимает концовку.
	c["state"].evidence = true


func _village_tapes(c: Dictionary, _p: Variant) -> void:
	c["state"].evidence = true


func _village_grave(c: Dictionary, _p: Variant) -> void:
	pass


func _village_look(c: Dictionary, p: Variant) -> void:
	var id := String(p)
	var s: GameState = c["state"]
	if id == "stop-schedule" and not s.has("stop-seen"):
		s.set_flag("stop-seen")


## Дальний раскат. Задержка большая и вспышка слабая: гроза за околицей,
## и знать о ней игрок должен по звуку, а не по кадру.
func _village_thunder(c: Dictionary, _p: Variant) -> void:
	var w: Variant = c.get("weather")
	if w != null:
		w.storm(0.35, 3.4)


## Тетрадь взята со второго этажа красного дома. Строку задачи толкаем, как
## и на остальных шагах линии Вали, — и следом ставим фигуру.
##
## ФАЗА 17. Раньше здесь бил полный кадр (village_quest._register_redhouse_up).
## Тетрадь стала обязательной — valya-gone без неё не наступает, — и на
## маршруте главы полных кадров вышло бы четыре при потолке два. Точка
## 'redhouse-stair' стоит ровно там, куда игрок сейчас и пойдёт: верхняя
## площадка, он спиной к маршу, фигура между ним и единственным окном.
## Момент тот же, перепад яркости другой.
func _village_notebook(c: Dictionary, _p: Variant) -> void:
	pushTask()
	var st: Variant = c.get("startle")
	if st == null or not st.has_method("force"):
		return
	_after(0.9, func() -> void:
		st.force("redhouse-stair"))


func _village_caught(_c: Dictionary, _p: Variant) -> void:
	fail("street")


## Поимка УЧАСТКОВЫМ дедом, тем самым, что ходит по дому и участку. Он в
## ДЕРЕВНЕ живой (threatState = 'patrol'), доходит до игрока и до фазы 18
## после этого молча исчезал: события 'caught' у главы не было. Карточка
## и точка возврата те же, что у ТЕМНОТЫ, — крыльцо своего дома.
func _village_house_caught(_c: Dictionary, _p: Variant) -> void:
	fail("dark")


# Бегунок на месте. Дальше — ВОРОТА, и цепь на них снова накинута.
func _village_done(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.has("village-done"):
		return
	s.set_flag("village-done")
	_village_voice(c, "village-5")
	c["audio"].sfx("car-fail", 0.7)
	timer("to-gate", 3.6)


# Старый village-снимок мог уже содержать установленный бегунок.
# После нового обхода возвращаем переход к воротам, сохраняя флаги.
func _village_resume_repaired(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.chapter != "village" or not s.has("distributor-in") or not village_chores_done(s):
		return
	s.set_flag("village-done")
	for pending: Dictionary in timers:
		if String(pending.get("event", "")) == "to-gate":
			return
	timer("to-gate", 3.6)


func _village_to_gate(_c: Dictionary, _p: Variant) -> void:
	go("gate")


## Сценарная реплика деда из темноты. Только голосом: строки живут
## в data/voice_lines.json, субтитра без записи у них нет намеренно —
## то же правило, по которому молчит `dread` на сборке без озвучки.
##
## Имя функции начинается с `_village` не случайно: tests/test_voice_manifest.gd
## пускает say_vitya только из функций с префиксом из VITYA_OK_PREFIX, и это
## машинная защита правила «до 23:40 ни одного слова деда».
func _village_voice(c: Dictionary, name: String) -> void:
	var v: Variant = c.get("voice")
	if v != null:
		v.say_vitya_key(name, 12.0, 0.0)


# ----------------------------------------------------------------- ВОРОТА ---

func _gate_enter(c: Dictionary) -> void:
	var s: GameState = c["state"]
	_story_night(c, "gate")
	s.threatState = "hunt"
	s.set_flag("final")
	# Цепь на воротах снова накинута. Сергей снял её в первую минуту игры
	# и больше не трогал, флаг 'gate-open' дожил до финала — из-за этого
	# задача сразу становилась «уехать», а сцена у створки (единственный
	# момент, где деда видно вплотную) не запускалась ни разу за прохождение.
	s.set_flag("gate-open", false)
	_ctx_call("setGate", [false])
	# ФАЗА 17. И тут же — калитка. Она стояла ТВЁРДОЙ всю игру:
	# world_builder.gd ставит ей active = true, а set_blocker_active("wicket", …)
	# не звался нигде ни разу. Глава при этом начинается СНАРУЖИ участка, у
	# капота, первой строкой снова запирает ворота — и первой же задачей
	# отправляет в дом за кассетами. Порядок был принудительно обратный
	# объявленному, и пройти его было нечем.
	#
	# Строка про калитку написана давно и не показывалась ни разу:
	# LOOKS.wicket — «Калитка не заперта. Она тут отродясь не запиралась».
	# Сторожит tests/test_gate_room.gd.
	_ctx_call("setWicket", [true, true])
	# ФАЗА 15. Глава начинается НА КРЫЛЬЦЕ и первым делом отправляет в дом:
	# монолог у ворот («кассеты в сумке, сумка на плече») переехал туда, где
	# он перестал быть неправдой, — на момент, когда сумка действительно
	# собрана. Здесь остаётся только дождь: он заходит тихо, а гроза
	# и погасшая деревня — уже после сумки, на выходе.
	var w: Variant = c.get("weather")
	if w != null:
		# ФАЗА 18. Поимка у ворот перестала быть концом игры, а значит,
		# в эту строку теперь заходят и после [R]. Гроза приходит событием
		# 'porch-storm' по таймеру главы, и второй раз оно не придёт: сумка
		# уже собрана. Без этой развилки откат возвращал в тихий дождь
		# при погашенной деревне — то есть в кадр, которого в игре нет.
		if s.has("bag-packed"):
			w.set_rain(0.9)
			w.storm(1.25, 0.9)
		else:
			w.set_rain(0.45)


func _gate_task(s: GameState) -> Variant:
	# ФАЗА 15. Первым шагом — в дом за кассетами. Раньше глава начиналась
	# сразу с цепи, и всё, что игрок нашёл за ночь, оставалось лежать там,
	# где он это нашёл.
	if not s.has("bag-packed"):
		return _tasks["bagTapes"]
	if not s.has("gate-open"):
		# Ключ от амбарного замка — из тайника. Строка TASKS.chainKey жила
		# в текстах с прототипа и не показывалась ни разу за прохождение.
		return _tasks["chainAgain"] if s.hasItem("chain-key") else _tasks["chainKey"]
	# Третий слой защиты от тупика: сюда можно попасть со старого сохранения
	# или после [R], снятого до того, как ТЕМНОТА стала спрашивать ключи.
	# Задача обязана вести к живой точке, а «завести машину» без ключей ведёт
	# к реплике и обратно.
	if not s.hasItem("car-key"):
		return _tasks["keysDown"]
	return _tasks["drive"]


# ДЖАМПСКЕЙР №3. Игрок наклоняется снять цепь — по ту сторону створки
# вплотную стоит он. Не хватает и не бежит. Четыре секунды паузы.
#
# Сцена идёт на двойнике: в этой главе threatState = 'hunt', и позицию фигуры
# 'threat' Threat.update переписывает каждый кадр по своей цели. Поставленный
# вплотную к створке дед улетал к патрулю в следующем же кадре, оставляя
# от сцены один стингер.
func _gate_gate(c: Dictionary, p: Variant) -> void:
	var s: GameState = c["state"]
	if not bool(p) or s.has("gate-scare"):
		return
	s.set_flag("gate-scare")
	_ctx_call("holdEcho", [7.0])
	var feet: Vector3 = c["controls"].feet()
	# ФАЗА 15. Двойник встаёт ПО ТУ СТОРОНУ створки от игрока, а не всегда
	# со стороны улицы. Раньше он стоял на z -0.9 намертво: сцена собиралась
	# для главы, которая начиналась у машины, то есть снаружи. Теперь игрок
	# приходит из дома, и дед в старой точке оказывался у него за спиной,
	# в трёх метрах, — то есть сцены не было вовсе.
	var side := -0.9 if feet.z > GATE_Z else 0.9
	c["actors"].place("echo", 0.2, _ground, side, 0.0)
	c["actors"].show("echo", true)
	c["actors"].face("echo", feet.x, feet.z)
	_hit(c, 0.8, 1.4)
	c["renderer"].set_tracking(0.7)
	var line := func() -> void:
		c["ui"].say(_t["THREAT_AT_GATE"], 4.0)
	_after(1.4, line)
	timer("gate-calm", 4.2)
	# И сразу за сценой — погоня. Не мгновенно: пока двойник стоит у створки,
	# настоящий дед стартовал бы у игрока на глазах, и их было бы двое.
	timer("gate-chase", 4.4)


func _gate_calm(c: Dictionary, _p: Variant) -> void:
	c["renderer"].set_tracking(0)
	c["actors"].show("echo", false)


# Сел в машину без ключей. У главы УЛИЦА обработчик этого события был,
# у ВОРОТ — нет, и реплика проходила впустую: игрок слышал «замок зажигания
# пустой» и не получал ни задачи, ни направления. Здесь оно и говорится вслух.
func _gate_car_nokey(c: Dictionary, _p: Variant) -> void:
	c["ui"].say(_beats["keysStillDown"], 4.6)


# И наоборот: ключи найдены уже в финале — сказать, что дорога открыта.
func _gate_car_key(c: Dictionary, _p: Variant) -> void:
	c["ui"].say(_beats["keysFound"], 3.2)


func _gate_drive(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	# ФАЗА 17. Два гарда, и оба про одно: «ехать» приходит ОТЛОЖЕННО, через
	# 2.6 с после нажатия, и за эти секунды игра могла кончиться.
	#
	# chapter == "end" — игрока догнали, титры уже идут. Отложенный emit
	# крутил бы катсцену отъезда поверх карточки поимки: машина уезжает после
	# того, как его поймали.
	#
	# 'drive-played' — второй заход по любой другой причине ([R], отладка,
	# двойное событие). Концовка обязана случиться ровно один раз.
	if s.chapter == "end" or s.has("drive-played"):
		return
	s.set_flag("drive-played")
	# «ТИХО» бьёт остальные концовки: это награда за то, что игрок нашёл его
	# спящим и не побежал. Улики после запертого чердака уже не решают ничего —
	# Сергей уходит пешком и без них.
	if s.has("hatch-sealed"):
		end("quiet")
		return
	_drive_away(c, _ending_of(s))


# ---------- катсцена отъезда (фаза 16) ----------

## Длина сцены и раскадровка. Секунды считаются от начала.
##
## ФАЗА 17. Кадр был ОДИН и неподвижный на все девять секунд, и этого мало:
## в нём машина уезжала с семи метров, то есть уменьшалась в тумане, а Витя
## стоял точкой у края. «Отъезд толком не показали» — жалоба точная.
## Теперь три кадра, и каждый показывает своё: сперва то, что машина ЖИВА,
## потом то, что она УХОДИТ, потом того, кто ОСТАЁТСЯ.
const DRIVE_LEN := 10.0
const DRIVE_START := 2.3
const DRIVE_STOP_CHASE := 8.2

## Раскадровка. Сумма "sec" обязана равняться DRIVE_LEN — сторожит
## tests/smoke_final.gd, и не из аккуратности: кадр, который короче своей
## доли, оставляет последние секунды сцены на камере из ниоткуда.
const DRIVE_SHOTS := [
	{
		# Rear quarter: starter, headlamps and the first exhaust clouds.
		"pos": Vector3(4.35, 1.08, -5.20),
		"look_at": Vector3(1.15, 0.62, -2.72),
		"pos_to": Vector3(4.05, 1.12, -5.02),
		"look_at_to": Vector3(0.65, 0.68, -2.72),
		"sec": 2.3,
	},
	{
		# Wide shot: Vitya runs and nearly reaches the rear door.
		"pos": Vector3(5.50, 1.50, -6.00),
		"look_at": Vector3(1.00, 0.90, -2.70),
		"pos_to": Vector3(0.00, 1.50, -6.00),
		"look_at_to": Vector3(-2.50, 0.90, -2.70),
		"sec": 2.8,
	},
	{
		# Side tracking shot: the car's acceleration opens the gap.
		"pos": Vector3(-2.00, 1.50, -6.50),
		"look_at": Vector3(-2.50, 0.90, -2.70),
		"pos_to": Vector3(-14.00, 1.50, -6.50),
		"look_at_to": Vector3(-14.00, 0.90, -2.70),
		"sec": 3.1,
	},
	{
		# Vitya slows, stops and watches the tail-lights disappear.
		"pos": Vector3(-7.00, 1.45, -6.50),
		"look_at": Vector3(-16.00, 0.90, -2.70),
		"pos_to": Vector3(-7.00, 1.45, -6.50),
		"look_at_to": Vector3(-20.00, 0.90, -2.70),
		"sec": 1.8,
	},
]

## Концовки, на которых катсцена НЕ играется.
## quiet — Сергей уходит пешком, машины в кадре нет.
## caught — его догнали, уезжать некому.
const NO_DRIVE := {"quiet": true, "caught": true}


## Между «нажал ехать» и титрами не происходило НИЧЕГО: отъезда не видно, Витя
## из финала пропадал. Здесь встаёт кадр с кассеты — та же VHS-цепочка, лёгкий
## трекинг на входе. Это не разрыв стиля, а его завершение: вся игра и есть плёнка.
##
## Нового кода — только модуль камеры. Фигура, машина как двигаемая нода,
## стартёр и трекинг уже работают в других местах и здесь переиспользуются.
func _drive_away(c: Dictionary, which: String) -> void:
	var director: Variant = c.get("horror")
	var scene_generation := int(director.generation) if director != null else -1
	var cut: Variant = c.get("cutscene")
	var chain: Variant = c.get("renderer")
	var props: Variant = c.get("props")
	if cut == null or chain == null or NO_DRIVE.has(which):
		end(which)
		return

	var car: Variant = props.get_prop("car") if props != null else null
	var root: Node3D = chain.world_root
	if car == null or root == null:
		end(which)
		return

	# Управление отбирается сразу: сцена началась, и игрок в ней зритель.
	c["controls"].enabled = false
	var held: Variant = c.get("heldItems")
	var flashlight: Variant = c.get("flashlight")
	if held != null and held.has_method("set_cinematic_hidden"):
		held.set_cinematic_hidden(true)
	if flashlight != null and flashlight.has_method("set_cinematic_suppressed"):
		flashlight.set_cinematic_suppressed(true)

	var car_node: Node3D = car
	var car_from: Vector3 = car_node.position

	# Витя у калитки. Не в центре кадра, а с краю: первые секунды его почти
	# не замечаешь, и в этом вся сцена.
	var actors: Variant = c.get("actors")
	var threat_was_visible := false
	if actors != null:
		var threat_actor: Variant = actors.get_actor("threat")
		if threat_actor is Node3D:
			threat_was_visible = (threat_actor as Node3D).visible
		actors.show("threat", false)
	# Стоит СНАРУЖИ калитки, на дороге: изнутри участка его закрыл бы
	# собственный забор, и весь финал свёлся бы к пустой улице.
	#
	# БРОНЬ ПЕРВОЙ СТРОКОЙ, и это не порядок ради порядка. holdEcho зовёт
	# startle.clear(), а тот гасит фигуру. Поставленный до брони двойник
	# исчезает в той же строке, в которой его показали, — ровно та же грабля,
	# из-за которой в _gate_gate бронь тоже стоит первой.
	if actors != null:
		_ctx_call("holdEcho", [DRIVE_LEN + 2.0])
		actors.place("echo", 0.35, _ground, -1.10, PI)
		actors.show("echo", true)
		actors.face("echo", car_from.x, car_from.z)
	var echo_node: Node3D = actors.get_actor("echo") if actors != null else null
	var echo_pos := echo_node.position if echo_node != null else Vector3(0.35, _ground, -1.10)

	# Фары: две точки без теней. Тень от фар — это карта теней на пустую
	# дорогу, а видно её ровно ноль.
	#
	# КУДА ЕДЕТ. По улице на ЗАПАД. Улица идёт вдоль X (борта в street.json:
	# север z -15, юг z 0.2, запад x -45.6, восток x 45.6), и «на север» её
	# не проехать вовсе — там борт в четырёх метрах от машины. На западе
	# остановка, с которой девятого августа ушёл последний рейс, и правление:
	# туда он и уезжает.
	var beams: Array[OmniLight3D] = []
	var beam_cones: Array[MeshInstance3D] = []
	var beam_halos: Array[MeshInstance3D] = []
	var beam_pools: Array[MeshInstance3D] = []
	for side: float in [-0.62, 0.62]:
		var l := OmniLight3D.new()
		l.light_energy = 0.0
		l.omni_range = 11.0
		l.light_color = GameData.color(0xf3e6bd)
		l.shadow_enabled = false
		l.position = car_from + Vector3(-2.05, 0.62, side)
		root.add_child(l)
		beams.append(l)
		var cone := LightCone.make_headlight("drive-headlight-cone")
		root.add_child(cone)
		LightCone.aim(cone, l.position, l.position + Vector3(-11.0, -0.75, 0.0))
		beam_cones.append(cone)
		var halo := LightCone.make_headlight_halo("drive-headlight-halo")
		root.add_child(halo)
		beam_halos.append(halo)
		var pool_spot := LightCone.make_headlight_pool("drive-headlight-pool")
		root.add_child(pool_spot)
		beam_pools.append(pool_spot)
	# A dim, shadowless fill keeps the running silhouette readable against the
	# unlit western street. It follows only the staged double and is scene-owned.
	var chase_fill := OmniLight3D.new()
	chase_fill.name = "drive-chase-fill"
	chase_fill.light_energy = 0.75
	chase_fill.omni_range = 5.0
	chase_fill.light_color = GameData.color(0xb8c49c)
	chase_fill.shadow_enabled = false
	chase_fill.position = echo_pos + Vector3(0.0, 1.45, -1.20)
	root.add_child(chase_fill)

	chain.set_tracking(0.65)
	c["audio"].sfx("car-start")

	# Six cheap, translucent exhaust puffs. They are scene-owned and never cast
	# shadows or enter physics; every cleanup path frees them.
	var exhaust: Array[MeshInstance3D] = []
	for i in 6:
		var puff := MeshInstance3D.new()
		puff.name = "drive-exhaust-%d" % i
		var sphere := SphereMesh.new()
		sphere.radius = 0.18
		sphere.height = 0.30
		sphere.radial_segments = 8
		sphere.rings = 4
		var smoke := StandardMaterial3D.new()
		smoke.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		smoke.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		smoke.albedo_color = Color(0.48, 0.49, 0.48, 0.0)
		sphere.material = smoke
		puff.mesh = sphere
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(puff)
		exhaust.append(puff)
	# Lambdas capture scalar locals by value. Mutable scene state therefore
	# lives in one referenced dictionary: otherwise the pursuer restarts from
	# x=0.35 and the engine sample restarts on every frame.
	var drive_runtime := {
		"sound_played": false,
		"last_t": 0.0,
		"echo_pos": echo_pos,
	}

	var tick := func(t: float) -> void:
		# 0.0-2.3 — starter, lamps and exhaust; then 40 m quadratic travel.
		var lit := clampf(t / DRIVE_START, 0.0, 1.0)
		var q := clampf((t - DRIVE_START) / (DRIVE_LEN - DRIVE_START), 0.0, 1.0)
		if t >= DRIVE_START and not bool(drive_runtime["sound_played"]):
			drive_runtime["sound_played"] = true
			c["audio"].sfx("car-drive-v2")
		var travel := 40.0 * q * q
		car_node.position = car_from + Vector3(-travel, 0.0, 0.0)
		(c["props"] as Props).update_car_wheels(car_node, travel)
		for i in beams.size():
			var l: OmniLight3D = beams[i]
			l.light_energy = 2.6 * lit
			l.position = car_node.position + Vector3(-2.05, 0.62, -0.62 + 1.24 * float(i))
			var cone: MeshInstance3D = beam_cones[i]
			LightCone.aim(cone, l.position, l.position + Vector3(-11.0, -0.75, 0.0))
			cone.visible = chain.render_preset() == RenderChain.PRESET_HQ and lit > 0.02
			var halo: MeshInstance3D = beam_halos[i]
			halo.visible = cone.visible
			if halo.visible:
				LightCone.update_halo(halo, l.position, chain.camera.global_position, lit)
			var pool_spot: MeshInstance3D = beam_pools[i]
			pool_spot.visible = cone.visible
			if pool_spot.visible:
				LightCone.place_pool(pool_spot, Vector3(l.position.x - 5.0,
					_ground + LightCone.POOL_Y_OFFSET, l.position.z),
					LightCone.HEADLIGHT_POOL_STRENGTH * lit)
		if not beam_cones.is_empty():
			var headlight_material := beam_cones[0].material_override as ShaderMaterial
			headlight_material.set_shader_parameter("brightness",
				LightCone.HEADLIGHT_BRIGHTNESS * lit)
		# The staged double chases the point one metre behind the rear bumper,
		# capped at 3 m/s. At 8.2 s he decelerates and remains looking west.
		if actors != null and echo_node != null:
			var running := t >= DRIVE_START and t < DRIVE_STOP_CHASE
			var staged_pos: Vector3 = drive_runtime["echo_pos"]
			if running:
				var target_x := car_node.position.x + 3.05
				var chase_dt := minf(0.05,
					maxf(t - float(drive_runtime["last_t"]), 0.0))
				staged_pos.x = move_toward(staged_pos.x, target_x, 3.0 * chase_dt)
				drive_runtime["last_t"] = t
				drive_runtime["echo_pos"] = staged_pos
				actors.place("echo", staged_pos.x, _ground, car_from.z + 0.10, PI / 2.0)
			actors.face("echo", car_node.position.x, car_node.position.z)
			if actors.has_method("sample_action"):
				actors.sample_action("echo", "run" if running else "stop", maxf(0.0, t - (DRIVE_START if running else DRIVE_STOP_CHASE)))
			else:
				actors.walk_anim("echo", 0.05, {"speed": 3.0 if running else 0.0, "moving": running})
			chase_fill.light_energy = lerpf(0.75, 1.30, lit)
			chase_fill.position = Vector3(staged_pos.x, _ground + 1.45,
				car_from.z - 1.10)
		for i in exhaust.size():
			var puff: MeshInstance3D = exhaust[i]
			var age := fposmod(t - float(i) * 0.31, 1.86)
			var active := t > float(i) * 0.16
			puff.visible = active
			# Tailpipe sits on the far side from the tracking cameras. The smoke
			# still trails the rear bumper but no longer masks the pursuer.
			puff.position = car_node.position + Vector3(2.20 + age * 0.42,
				0.32 + age * 0.12, 0.55 + 0.10 * sin(float(i) * 2.1))
			puff.scale = Vector3.ONE * (0.55 + age * 0.62)
			var mat := puff.mesh.surface_get_material(0) as StandardMaterial3D
			mat.albedo_color.a = (sin(PI * age / 1.86) * 0.24) if active else 0.0
		# Трекинг гаснет за первые полторы секунды — плёнка «поймала» кадр.
		chain.set_tracking(maxf(0.0, 0.65 * (1.0 - t / DRIVE_START)))

	var done := func() -> void:
		chain.set_tracking(0.0)
		if held != null and held.has_method("set_cinematic_hidden"):
			held.set_cinematic_hidden(false)
		if flashlight != null and flashlight.has_method("set_cinematic_suppressed"):
			flashlight.set_cinematic_suppressed(false)
		for l: OmniLight3D in beams:
			if is_instance_valid(l):
				l.queue_free()
		for cone: MeshInstance3D in beam_cones:
			if is_instance_valid(cone):
				cone.queue_free()
		for halo: MeshInstance3D in beam_halos:
			if is_instance_valid(halo):
				halo.queue_free()
		for pool_spot: MeshInstance3D in beam_pools:
			if is_instance_valid(pool_spot):
				pool_spot.queue_free()
		if is_instance_valid(chase_fill):
			chase_fill.queue_free()
		if actors != null:
			if actors.has_method("end_action"): actors.end_action("echo")
			actors.show("echo", false)
			actors.show("threat", threat_was_visible)
		for puff: MeshInstance3D in exhaust:
			if is_instance_valid(puff):
				puff.queue_free()
		car_node.position = car_from
		(c["props"] as Props).update_car_wheels(car_node, 0.0)
		if director == null or int(director.generation) == scene_generation:
			end(which)

	if not bool(cut.play(root, chain.camera, DRIVE_SHOTS, DRIVE_LEN, tick, done)):
		done.call()


## Какая концовка при живом отъезде. «ПИСЬМО» (фаза 12) требует ОБЕИХ половин
## человеческой истории: письма в правление и кассет из заколоченного дома.
## Одно письмо — это чужая жалоба, одни кассеты — это чужая слежка; вместе
## они складываются в то, что случилось на самом деле, и только тогда Сергей
## умеет объяснить это на посту ГАИ.
func _ending_of(s: GameState) -> String:
	if s.has("kovrigin-letter") and s.hasItem("kovrigin-tapes"):
		return "kovrigin"
	return "morning" if s.evidence else "alone"


## Сумка собрана. Отсюда и идёт монолог перед воротами: он говорит ровно
## то, что теперь правда, — кассеты в сумке, ключ в кармане. Гроза заходит
## следом, с таким расчётом, чтобы первый разряд пришёлся на дверь.
func _gate_bagged(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if not s.has("final-said"):
		s.set_flag("final-said")
		_ctx_call("playWalkDialogue", [_t["FINAL_AT_GATE"], null])
	timer("porch-storm", 2.4)


## Крыльцо. Гроза и погасшая деревня — один и тот же кадр: света нет нигде,
## кроме вспышек, и по ним видно, что улица пустая.
func _gate_storm(c: Dictionary, _p: Variant) -> void:
	var w: Variant = c.get("weather")
	if w != null:
		w.set_rain(0.9)
		w.storm(1.25, 0.9)
	var lights: Variant = c.get("lights")
	if lights != null:
		for id: String in VILLAGE_LAMPS:
			lights.setLamp(id, false)
	c["ui"].say(_beats["porchStorm"], 4.0)


## Погоня. Начинается РОВНО в момент, когда цепь снята: раньше деду некуда
## идти (ворота заперты), позже — незачем.
##
## Точка старта отсчитывается от машины: дед встаёт с противоположной от неё
## стороны игрока, то есть между игроком и домом, а не между игроком и целью.
## Двенадцать метров при разнице скоростей 0.09 м/с — это восемь секунд форы,
## и ровно столько занимают три движения: дойти, сесть, провернуть дважды.
func _gate_chase(c: Dictionary, _p: Variant) -> void:
	var th: Variant = c.get("threat")
	if th == null:
		return
	var feet: Vector3 = c["controls"].feet()
	var site := GameData.site()
	var car: Array = (site["SPAWN"] as Dictionary).get("car", [0.9, 0.0, -3.4])
	th.begin_final(feet, Vector3(float(car[0]), float(car[1]), float(car[2])))


## Догнал.
##
## ФАЗА 18, ЖАЛОБА ПЕТРА ПУНКТ ТРЕТИЙ, ВТОРАЯ ПОЛОВИНА. Раньше здесь стоял
## end("caught") — то есть концовка, стартовый экран и state.reset(). Поимка
## на последних двадцати метрах игры отбрасывала не в начало главы, а в начало
## ИГРЫ, и ключ FAILS["gate"] («КОНЕЦ КАССЕТЫ», texts.json) был написан
## и недостижим. Теперь первые две поимки — обычный провал с откатом на
## чекпоинт и возвратом на крыльцо (RESPAWN["gate"] в site.json есть), и
## только с третьей игра кончается тем, что его отвели в дом.
##
## Счётчик s.failCount откат переживает (retry() восстанавливает его поверх
## снимка), поэтому три — это именно три поимки, а не три с последнего [R].
##
## Скример перед карточками — тот же порядок, что у fail(): сначала лицо,
## потом текст, иначе карточка читается техническим сообщением.
func _gate_caught(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.chapter == "end": return
	var th: Variant = c.get("threat")
	if th != null: th.end_final()
	if s.failCount < 2:
		fail("gate")
		return
	var recovery: Variant = c.get("capture")
	if recovery != null:
		recovery.begin("gate", true)
	else:
		end("caught")


# -------------------------------- постановки первой половины ночи (фаза 11) --
#
# Четыре сухих окна, в которых за прохождение не случалось НИЧЕГО: СВЕТ после
# 190-й секунды, МАНСАРДА после 240-й и всё время просмотра кассет. Ставятся
# они таймером главы, а не отдаются dread'у: тот выбирает случайно, и «в этой
# главе тихо» повторялось бы через раз.

# Радио на веранде включается само. Прибор не выдуман: его оставляла Тоня
# (texts.json), и dread уже умеет его звук — берём готовое событие, чтобы
# не завести второй источник того же wav и не услышать радио дважды за ночь.
func _radio_self(c: Dictionary, _p: Variant) -> void:
	var director: Variant = c.get("horror")
	if director != null:
		director.context("light-call-radio", "radio-veranda")
		return
	var dr: Variant = c.get("dread")
	if dr != null and dr.has_method("force"):
		dr.force("radio-veranda")
		return
	c["audio"].sfx("radio-veranda")


# На кухне падает крышка. Ни реплики, ни задачи: звук в соседней комнате
# и всё. Идёт мимо реверба зоны игрока — он может быть на мансарде.
func _kitchen_lid(c: Dictionary, _p: Variant) -> void:
	var director: Variant = c.get("horror")
	if director != null:
		director.context("light-lid-return", "horror-tin")
		return
	var a: Variant = c["audio"]
	if not bool(a.sfx("basket-drop", 0.8)):
		a.knock(1, 0.0)
	var dr: Variant = c.get("dread")
	if dr != null and dr.has_method("force_cooldown"):
		dr.force_cooldown("basket-drop", 240.0)


# ЧАЙНИК (фаза 12). Он свистит только у того, кто его поставил, и только
# когда тот наверху: удар «сам себе устроил» сильнее любого случайного.
# Не поставил — таймер перезаводится один раз и молчит: сцена ждёт, а не
# сгорает впустую и не звучит на пустой плите.
func _kettle_whistle(c: Dictionary, p: Variant) -> void:
	var s: GameState = c["state"]
	var tries := int(p) if p != null else 0
	if not s.has("kettle-on"):
		if tries < 1:
			timer("kettle-whistle", 90.0, 1)
		return
	if s.has("kettle-heard"):
		return
	s.set_flag("kettle-heard")
	var a: Variant = c["audio"]
	# Свист — новый оверлейный sfx. Нет оверлея — тон: чайник обязан звучать
	# на любой сборке, иначе сцена просто не случается.
	if a != null and not bool(a.sfx("kettle", 0.9)):
		a.tone({"dur": 2.4, "gain": 0.07, "freq": 1850.0, "to": 2050.0})
	c["ui"].say(_beats["kettleWhistle"], 3.6)
	var dr: Variant = c.get("dread")
	if dr != null and dr.has_method("force_cooldown"):
		dr.force_cooldown("house-groan", 120.0)


# Шаги по чердаку прямо над головой. Мансарда — единственное место в доме,
# где над потолком есть кто-то ещё, и это первый раз, когда игра говорит
# об этом вслух.
func _above_head(c: Dictionary, _p: Variant) -> void:
	var s: GameState = c["state"]
	if s.chapter != "loft" or not _scares_on(c): return
	var zone := _zone_now()
	if String(zone.get("level", "")) != "attic" or String(zone.get("id", "")) == "balcony": return
	var source := Vector3(-1.1, 7.8, 13.2)
	var controls: Variant = c.get("controls")
	if controls == null or (controls.feet() as Vector3).distance_to(source) > 12.0: return
	var director: Variant = c.get("horror")
	if director != null:
		director.context("loft-attic-return", "horror-attic-creak", source)
		return
	c["audio"].steps_above(4)
	var dr: Variant = c.get("dread")
	if dr != null and dr.has_method("force_cooldown"):
		dr.force_cooldown("floor-creak-far", 180.0)


# Тень пересекает экран, пока идёт кассета. Кассета — единственные минуты игры,
# когда игрок смотрит НЕ в мир, и до фазы 11 они были абсолютно безопасны.
# Если кассета сейчас не идёт, таймер перезаводится: постановка ждёт своего
# момента, а не сгорает в пустоту.
func _tape_shadow(c: Dictionary, p: Variant) -> void:
	var r: Variant = c.get("renderer")
	if r == null:
		return
	var tries := int(p) if p != null else 0
	if not bool(r.is_tape_mode()):
		if tries < 12:
			timer("tape-shadow", 30.0, tries + 1)
		return
	r.set_tracking(0.85)
	var a: Variant = c["audio"]
	if a != null:
		a.sfx("tape-breath", 0.55)
	_after(0.55, func() -> void: r.set_tracking(0.0))


# -------------------------------------------------------------- служебное ---

func _ctx_call(name: String, args: Array = []) -> Variant:
	var f: Variant = ctx.get(name)
	if f is Callable:
		return (f as Callable).callv(args)
	return null


func _story_night(c: Dictionary, stage: String) -> void:
	var rig: Variant = c.get("lights")
	if rig == null or not rig.has_method("set_story_night"):
		return
	if not LightRig.STORY_NIGHT.has(stage):
		push_warning("unknown story night stage: " + stage)
		return
	rig.call("set_story_night", float(LightRig.STORY_NIGHT[stage]))


# setTimeout оригинала: одна отложенная реплика у ворот. Через свои таймеры её
# не пустить — те эмитят событие главы и пересчитывают задачу, а тут нужна
# ровно реплика.
func _after(seconds: float, cb: Callable) -> void:
	var director: Variant = ctx.get("horror")
	if director != null:
		director.after(seconds, cb)
		return
	var loop := Engine.get_main_loop()
	if seconds > 0.0 and loop is SceneTree:
		(loop as SceneTree).create_timer(seconds).timeout.connect(cb)
	else:
		cb.call()


func resume_after_recovery(checkpoint: Dictionary) -> void:
	# Сохранённое выполнение задачи уже в текущем state. enter() не вызываем.
	var s: GameState = ctx["state"]
	var outskirts: Variant = ctx.get("outskirts")
	if outskirts != null and outskirts.has_method("resume_pending_timers"):
		outskirts.resume_pending_timers()
	current = _defs.get(s.chapter, {})
	timers = timers.filter(func(tm: Dictionary) -> bool:
		return not ["gate-chase", "gate-calm", "figure-gone"].has(String(tm.get("event", ""))))
	_recovery_resume = checkpoint.duplicate(true)
	s.task = checkpoint.get("task")
	ctx["ui"].setTask(s.task)
	ctx["actors"].show("echo", false)
	if bool(checkpoint.get("gate_chase", false)):
		s.threatState = "absent"
	else:
		_ctx_call("resetThreat")
		s.threatState = String(checkpoint.get("threat", "patrol"))
		var stalk: Variant = ctx.get("stalk")
		if String(checkpoint.get("kind", "")) == "street" and stalk != null:
			stalk.begin(s.chapter == "village")
		_recovery_resume = {}


func _resume_recovery_threat() -> void:
	if _recovery_resume.is_empty(): return
	var s: GameState = ctx["state"]
	if not bool(_recovery_resume.get("gate_chase", false)):
		_recovery_resume = {}
		return
	# Подпол и дом не принадлежат маршруту финальной погони. Начинаем снаружи.
	if _in_house(): return
	var th: Variant = ctx.get("threat")
	if th == null: return
	var feet: Vector3 = ctx["controls"].feet()
	if absf(feet.y) > 0.8 or feet.x < -45.6 or feet.x > 45.6 or feet.z < -15.0 or feet.z > 30.0:
		return
	var car: Array = GameData.site()["SPAWN"].get("car", [0.9, 0.0, -3.4])
	var away := Vector3(float(car[0]), float(car[1]), float(car[2]))
	if not bool(th.begin_final(feet, away)):
		# Если большой веер зажат оградой, пробуем короткий на той же улице.
		if not bool(th.begin_final(feet, away, 5.0)): return
	# begin_final сам обнуляет grace; выставлять её можно только после него.
	s.threatState = "hunt"
	th.grace = 8.0
	th.mute = 8.0
	_recovery_resume = {}

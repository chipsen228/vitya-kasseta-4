# Знаки. Четырнадцать событий, которых в прототипе не было ни одного.
#
# ЧЕМ ЭТО НЕ dread.gd. Тот играет звук: дом скрипнул, во дворе упало ведро.
# Здесь МЕНЯЕТСЯ МИР — гаснет горящая лампа, открывается прикрытая дверь,
# исчезает предмет, часы бьют тринадцать. Четыре события (shed-open, front-ajar,
# boots-gone, jar-moved) вообще не издают звука: игрок не видит момента, он
# видит результат. Это самая сильная форма из всех, что есть в игре, и
# одновременно главный риск: на сарай можно ни разу не оглянуться.
#
# Отсюда правило, которое стоит в _can(): «изменение за спиной» разрешается
# ТОЛЬКО тогда, когда цель сейчас вне конуса взгляда, но рядом. Событие,
# случившееся в другом конце участка, не изменение — оно просто не существует.
#
# ЧТО В КОДЕ, А ЧТО В ФАЙЛЕ. Логика каждого события — здесь, поимённо: подмена
# предмета и тринадцатый удар часов не сводятся к общей строчке таблицы.
# В godot/data/omens.json — только расписание: с какой главы (min), какой
# интенсивности (i, окно шкалы напряжения), свой кулдаун (cd), вес (w) и «один
# раз за прохождение» (once). Файла нет или enabled = false — update() выходит
# первой строкой, и игра идёт ровно как в фазе 7.
#
# Планировщик тот же, что у dread.gd и haunt.gd: TRY_EVERY/TRY_CHANCE, бюджет
# на главу, глобальный кулдаун, пер-именные кулдауны. Кулдаун здесь вдвое
# длиннее звукового: подменять мир чаще, чем раз в две минуты, значит превращать
# аномалию в механику.
#
# Со шкалой напряжения: перед сработкой tension.allows(i), после — spent(i).
# Нет шкалы в ctx — работает по своим кулдаунам.
class_name Omens
extends RefCounted

const FILE := "res://data/omens.json"

const TRY_EVERY := 1.0
const TRY_CHANCE := 0.4

const GLOBAL_CD_MIN := 100.0
const GLOBAL_CD_MAX := 190.0
const START_CD := 45.0

# Бюджет на главу. Итог за прохождение — 8..14 знаков, вдвое реже звуковых
# событий dread: то, что меняет мир, обязано быть реже того, что его озвучивает.
const BUDGET := {
	"prologue": [0, 0],
	"arrive": [0, 1],
	# Фаза 11: +1 к верхней границе — вслед за поднятой пропускной способностью
	# арбитра (tension.gd) и бюджетами dread.
	"light": [1, 3],
	"loft": [2, 4],
	"tapes": [2, 4],
	# УЛИЦА: знаков мало и все они домашние — за воротами менять нечего,
	# а вернувшийся в дом игрок должен найти перемены разом, а не по одной.
	# Фаза 12: на улице появилось три знака своих (велосипед, лампа остановки,
	# свет за досками), и все три — про повторный проход. Улицу за игру
	# проходят шесть раз, и на каждом меняется ровно одна деталь.
	"street": [2, 3],
	"dark": [3, 4],
	"village": [2, 3],
	"gate": [0, 1],
	"end": [0, 0],
}

# Молчим ровно по тем же критериям, что dread: дед рядом — своя тревога у сцены
# уже есть, и второй слой её размывает.
const THREAT_NEAR := 12.0
const HUNT_NEAR := 25.0

# «За спиной» — вне конуса взгляда и не дальше этого. Дальше игрок изменения
# не заметит вовсе, и знак пропадёт впустую.
const BEHIND_COS := 0.35        # dot(взгляд, направление) выше — считается «видит»
const BEHIND_FAR := 26.0
const BEHIND_NEAR := 1.2        # вплотную не подменяем: заметит боковым зрением

const ONCE_PREFIX := "omen-"

# Всё, что модуль умеет. Имя, которого здесь нет, в omens.json — опечатка,
# и её ловит tests/test_omens.gd: иначе событие молча не случится никогда.
const IDS: Array[String] = [
	"frame-slip", "gate-chain", "lamp-out", "steps-above", "porch-on",
	"shed-open", "thirteen", "head-switch", "knock-below", "front-ajar",
	"torch-dip", "boots-gone", "jar-moved", "breath-behind",
	# Фаза 11, оба в бане.
	"ladle-sway", "banya-print",
	# Фаза 12: три на улице (повторный проход) и три в деревне.
	"bike-appear", "stop-lamp", "boarded-glow",
	"well-bucket", "pit-plate", "booth-dark",
	# Фаза 13: вилы на газоне у бани.
	"garden-forks",
	# Фаза 14: свет на втором этаже, свет в клубе, форточка теплицы.
	"upstairs-dark", "club-dark", "vent-open",
]

# Знаки-«изменения за спиной»: те, у которых есть точка в мире и которые
# требуют, чтобы игрок туда сейчас не смотрел.
const BEHIND: Dictionary = {
	"lamp-out": true, "porch-on": true, "shed-open": true,
	"front-ajar": true, "boots-gone": true, "jar-moved": true,
	"banya-print": true,
	# Фаза 12. Все шесть — изменения в мире, и все шесть требуют, чтобы игрок
	# в эту секунду туда не смотрел: перемена, увиденная в момент перемены,
	# читается как поп-ин, а не как ужас. Тот же вывод, что у лица наблюдателя
	# в фазе 9 и у отпечатка на стекле бани в фазе 11.
	"bike-appear": true, "stop-lamp": true, "boarded-glow": true,
	"well-bucket": true, "pit-plate": true, "booth-dark": true,
	# Фаза 13 — и здесь «за спиной» держит всю силу знака: вилы, воткнутые
	# в газон на глазах у игрока, это фокус, а вилы, которых секунду назад
	# не было, — это последний кадр кассеты «ОГОРОД», случившийся наяву.
	"garden-forks": true,
	# Фаза 14. Гаснущее окно — знак ровно до тех пор, пока игрок не видел,
	# как оно гасло: увиденное превращается в лампочку, которую выключили.
	# Форточка теплицы в BEHIND не входит намеренно — см. _can ниже.
	"upstairs-dark": true, "club-dark": true,
}

# Точки шести знаков фазы 12. Числа те же, что в data/village.json: знак
# обязан менять то, что построено, а не то, что рядом.
const BIKE_AT := Vector3(-11.20, 0.00, -6.60)
const STOP_LAMP_AT := Vector3(-42.60, 2.16, -6.60)
const BOARDED_GLOW_AT := Vector3(-5.50, 1.60, -7.50)
const WELL_BUCKET_AT := Vector3(-22.90, 0.00, -8.10)
const PIT_PLATE_AT := Vector3(41.35, 0.60, -7.78)
const BOOTH_AT := Vector3(22.55, 1.50, -8.42)

# Фаза 13. Газон между огородом и баней — то самое место, на котором кончается
# кассета «ОГОРОД»: ровный газон и воткнутые вилы. Точка продублирована
# с data/yard.json намеренно, по тому же правилу, что у ковша: нет участка —
# знак просто не сложится.
const FORKS_AT := Vector3(1.20, 0.00, 20.20)

# Ковш висит на гвозде у печи, окошко парной — в восточной стене. Числа
# продублированы с data/yard.json намеренно: знак обязан работать и тогда,
# когда участка нет вовсе, — тогда он просто не сложится.
const LADLE_AT := Vector3(4.21, 1.46, 23.70)
const PRINT_AT := Vector3(7.16, 1.52, 24.95)

# Фаза 14. Окно второго этажа красного дома и окно клуба — точки ламп из
# lights.gd::_lamp_table(), продублированные здесь по тому же правилу, что
# ковш и вилы: знак обязан гасить то, что горит, а не то, что рядом.
const UPSTAIRS_AT := Vector3(0.44, 4.30, -10.25)
const CLUB_WIN_AT := Vector3(9.10, 2.60, -29.40)

# Зерно и полоса головок возвращаются к значениям юниформ vhs_compose.gdshader.
const GRAIN_BASE := 0.075

# Две банки под знак 13. Обе без коллайдера, поэтому паритет 311/4/83 не может
# шелохнуться по построению: props.gd выходит до записи коробки.
const JAR_FROM := "omen-jar-shelf"
const JAR_TO := "omen-jar-hatch"

var c: Variant = null
var rng := RandomNumberGenerator.new()

var enabled := false
var events: Array = []

var chapter: Variant = null
var shown := 0
var budget := 0
var try_in := TRY_EVERY
var global_cd := START_CD
var cooldowns: Dictionary = {}
var _cd_dead: Array[String] = []   # истёкшие имена кадра, см. update()
var last := ""

var _timers: Array = []          # отложенные хвосты: [осталось, Callable]
var _staged := false             # банка на своём месте уже выставлена


func _init(ctx: Variant = null, rng_seed: int = 0) -> void:
	c = ctx
	rng.seed = rng_seed
	_load()


## Предметы, которых нет в props.json: их существование — часть механики
# знака, а не обстановки. main.gd отдаёт их в props.build_dynamic() вместе
# с DYNAMIC_PROPS, и до сработки они невидимы, как «сапог у щитка».
func extra_props() -> Array:
	if not enabled:
		return []
	return [
		# Банка стоит у дальней стены подпола — там, где игрок её и увидит,
		# спускаясь за тайником.
		{"id": JAR_FROM, "dyn": true, "m": "bottle-large",
			"at": [-3.60, -1.55, 11.00], "s": 1.6, "col": false},
		# И оказывается ровно под крышкой люка, по которой игрок сюда пришёл.
		{"id": JAR_TO, "dyn": true, "m": "bottle-large",
			"at": [-4.45, -1.55, 8.62], "s": 1.6, "col": false},
	]


func update(dt: float) -> void:
	if not enabled:
		return
	_tick_timers(dt)

	var st: Variant = _cx("state")
	if st == null:
		return

	global_cd -= dt
	# Обход СЛОВАРЯ, а не keys(): тот выделяет новый массив каждый кадр.
	# Стирать во время обхода нельзя — истёкшие копятся в переиспользуемый
	# массив и убираются после него.
	if not cooldowns.is_empty():
		_cd_dead.clear()
		for id: String in cooldowns:
			var left: float = float(cooldowns[id]) - dt
			if left <= 0.0:
				_cd_dead.append(id)
			else:
				cooldowns[id] = left
		for id: String in _cd_dead:
			cooldowns.erase(id)

	if not bool(st.atLeast("arrive")):
		return

	var cur := String(st.get("chapter"))
	if chapter == null or cur != String(chapter):
		chapter = cur
		shown = 0
		var b: Array = BUDGET.get(cur, [0, 1])
		budget = rng.randi_range(int(b[0]), int(b[1]))

	# Банка выставляется на своё место заранее и молча: знак «переехала»
	# читается только у того, кто видел, где она стояла.
	if not _staged and bool(st.atLeast("tapes")):
		_staged = true
		var pr: Variant = _cx("props")
		if pr != null:
			pr.show_dynamic(JAR_FROM, true)

	if _threat_near():
		return
	if bool(st.get("hidden")):
		return

	try_in -= dt
	if try_in > 0.0:
		return
	try_in = TRY_EVERY

	if global_cd > 0.0 or shown >= budget:
		return
	if rng.randf() > TRY_CHANCE:
		return
	_fire(st)


# При [R]: кулдауны и бюджет главы заново, отложенные хвосты снять, чтобы
# трекинг не «отпустило» через полсекунды после возврата.
func reset() -> void:
	cooldowns.clear()
	_timers.clear()
	shown = 0
	var b: Array = BUDGET.get(String(chapter) if chapter != null else "dark", [0, 1])
	budget = rng.randi_range(int(b[0]), int(b[1]))
	try_in = TRY_EVERY
	global_cd = START_CD
	last = ""
	# Флаги «уже было» живут в состоянии игры и снимаются вместе с ним:
	# иначе «один раз за прохождение» стало бы «раз на попытку».


# Отладка: знак по имени немедленно, мимо всех условий.
func force(id: String) -> bool:
	for e: Dictionary in events:
		if String(e["id"]) == id:
			_play(e)
			return true
	push_warning("omens: нет знака «%s»; есть %s" % [id, ", ".join(IDS)])
	return false


func debug_line() -> String:
	if not enabled:
		return "знаки —"
	return "знак %s   кд %dс   %d/%d за главу" % [
		("—" if last == "" else last), roundi(maxf(0.0, global_cd)), shown, budget]


# ---------- внутреннее ----------

func _load() -> void:
	var f := FileAccess.open(FILE, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		push_warning("omens: %s не разобран как объект — знаки выключены" % FILE)
		return
	var d: Dictionary = parsed
	if not bool(d.get("enabled", true)):
		return
	var list: Variant = d.get("events", [])
	if not (list is Array):
		return
	for row: Variant in (list as Array):
		if not (row is Dictionary):
			continue
		var e: Dictionary = row
		var id := String(e.get("id", ""))
		if not IDS.has(id):
			push_warning("omens: знака «%s» нет в коде — строка пропущена" % id)
			continue
		events.append(e)
	enabled = not events.is_empty()


func _fire(st: Variant) -> void:
	var ten: Variant = _cx("tension")
	var pool: Array = []
	var total := 0
	for e: Dictionary in events:
		var id := String(e["id"])
		if cooldowns.has(id) or id == last:
			continue
		if not bool(st.atLeast(String(e.get("min", "dark")))):
			continue
		if bool(e.get("once", false)) and bool(st.has(ONCE_PREFIX + id)):
			continue
		if not _can(id, st):
			continue
		# Галочка «Скримеры и резкие эффекты» режет акценты и мигание фонаря.
		# Атмосферные знаки остаются: гаснущая лампа — не нападение, и убирать
		# её значит убирать игру.
		if not _scares_on() and (int(e.get("i", 1)) >= 3 or id == "torch-dip"):
			continue
		if ten != null and not bool(ten.allows(int(e.get("i", 1)))):
			continue
		var w := int(e.get("w", 1))
		total += w
		pool.append([e, total])
	if pool.is_empty():
		return

	var roll := rng.randi_range(1, total)
	var played: Dictionary = {}
	for row: Array in pool:
		if roll <= int(row[1]):
			played = row[0] as Dictionary
			break
	if played.is_empty():
		return
	if not _play(played):
		# Условие ушло между отбором и сработкой (игрок повернулся) — ни бюджета,
		# ни кулдауна за это не берём.
		return

	shown += 1
	if ten != null:
		ten.spent(int(played.get("i", 1)))
	global_cd = GLOBAL_CD_MIN + rng.randf() * (GLOBAL_CD_MAX - GLOBAL_CD_MIN)


func _play(e: Dictionary) -> bool:
	var id := String(e["id"])
	if not _do(id):
		return false
	last = id
	if bool(e.get("once", false)):
		var st: Variant = _cx("state")
		if st != null:
			st.set_flag(ONCE_PREFIX + id)
	var cd := float(e.get("cd", 0.0))
	if cd > 0.0:
		cooldowns[id] = cd
	return true


## Условия, при которых знак вообще имеет смысл. Возвращает false — знак
## просто не попадает в отбор этого раза.
func _can(id: String, st: Variant) -> bool:
	match id:
		"frame-slip", "head-switch":
			return _cx("renderer") != null
		"gate-chain":
			return true
		"lamp-out":
			return not _lamp_behind().is_empty()
		"steps-above":
			# Шаги над головой имеют смысл только там, где над головой есть этаж.
			return not _outdoors() and ["floor1", "cellar"].has(_level())
		"porch-on":
			var l: Variant = _cx("lights")
			if l == null or not bool(l.powerOn) or bool(l.isOn("porch")):
				return false
			return _behind(Vector3(-2.30, 2.67, 6.30))
		"shed-open":
			# «Ту, которую игрок закрыл»: он там был (ключ найден), дверь сейчас
			# прикрыта, и на сарай он сейчас не смотрит.
			if not bool(st.has("key-found")) or bool(st.has("shed-open")):
				return false
			return _outdoors() and _behind(Vector3(6.80, 1.00, 9.92))
		"thirteen":
			return not _outdoors() and _level() != "roof"
		"knock-below":
			return _level() == "floor1"
		"front-ajar":
			if bool(st.has("house-open")):
				return false
			return _behind(Vector3(-2.30, 1.00, 7.35))
		"torch-dip":
			var fl: Variant = _cx("flashlight")
			return fl != null and bool(fl.on)
		"boots-gone":
			var pr: Variant = _cx("props")
			if pr == null:
				return false
			var n: Node3D = pr.get_prop("boots-by-fusebox")
			if n == null or not n.visible:
				return false
			return _behind(Vector3(-4.75, 0.45, 13.60))
		"jar-moved":
			var pr2: Variant = _cx("props")
			if pr2 == null or not _staged:
				return false
			var j: Node3D = pr2.get_prop(JAR_FROM)
			if j == null or not j.visible:
				return false
			# Обе точки за спиной: подмена, увиденная краем глаза, читается
			# как ошибка рендера, а не как знак.
			return _behind(Vector3(-3.60, -1.55, 11.00)) \
				and _behind(Vector3(-4.45, -1.55, 8.62))
		"breath-behind":
			return not _outdoors()
		"ladle-sway":
			# Только пока игрок в бане и ковш ЕСТЬ. Знак не «за спиной»:
			# качающийся ковш и должен попасть в кадр — иначе он не случился.
			return _in_banya() and _yard_node("banya-ladle") != null
		"banya-print":
			# А вот отпечаток — наоборот, строго вне кадра: проступившая
			# на глазах ладонь читается как поп-ин текстуры, а не как ужас.
			var pane := _yard_node("banya-win-e")
			if pane == null or not _in_banya():
				return false
			if bool(pane.get_meta("printed", false)):
				return false
			return _behind(PRINT_AT)

		# ---------- фаза 12: улица на повторном проходе ----------
		# Улицу за игру проходят шесть раз, и на каждом проходе меняется ровно
		# одна деталь. Больше одной — и это уже не паранойя, а фокус с картами.
		"bike-appear":
			var bk := _village_node("street-bike")
			if bk == null or bk.visible:
				return false
			return _outdoors() and _behind(BIKE_AT)
		"stop-lamp":
			var l2: Variant = _cx("lights")
			if l2 == null or not bool(l2.isOn("stop")):
				return false
			return _outdoors() and _behind(STOP_LAMP_AT)
		"boarded-glow":
			# Только пока дом ещё заколочен: после того как игрок в него вошёл,
			# свет за досками перестаёт быть загадкой и становится ошибкой.
			if bool(st.has("boarded-in")):
				return false
			var g := _village_node("boarded-glow")
			if g == null or g.visible:
				return false
			return _outdoors() and _behind(BOARDED_GLOW_AT)

		# ---------- фаза 12: деревня ----------
		"well-bucket":
			var bu := _village_node("well-bucket")
			if bu == null or bu.has_meta("moved"):
				return false
			return _outdoors() and _behind(WELL_BUCKET_AT)
		"pit-plate":
			# Табличка развернулась лицом к игроку. Только после того, как он
			# яму нашёл: развернувшаяся табличка, которую он ещё не читал, —
			# это просто табличка.
			if not bool(st.has("grave-seen")):
				return false
			var pl := _village_node("grave-pit")
			if pl == null or pl.has_meta("turned"):
				return false
			return _behind(PIT_PLATE_AT)
		"booth-dark":
			var l3: Variant = _cx("lights")
			if l3 == null or not bool(l3.isOn("booth")):
				return false
			return _outdoors() and _behind(BOOTH_AT)

		# ---------- фаза 13 ----------
		"garden-forks":
			# Только после того, как игрок посмотрел кассету «ОГОРОД». До неё
			# вилы на газоне — это вилы на газоне; после неё это последний кадр
			# плёнки, случившийся у него во дворе.
			if not bool((st.get("tapesWatched") as Dictionary).has("2")):
				return false
			var fk := _yard_node("forks")
			if fk == null or fk.visible:
				return false
			return _outdoors() and _behind(FORKS_AT)

		# ---------- фаза 14 ----------
		"upstairs-dark":
			# Гасить есть что только пока горит, и только если игрок уже был
			# наверху: тёмное окно дома, в котором он не был, ничего не
			# значит — он не знает, что там кто-то жёг свет.
			var l4: Variant = _cx("lights")
			if l4 == null or not bool(l4.isOn("redhouse-up")):
				return false
			if not bool(st.has("redhouse-in")):
				return false
			return _outdoors() and _behind(UPSTAIRS_AT)
		"club-dark":
			var l5: Variant = _cx("lights")
			if l5 == null or not bool(l5.isOn("club-win")):
				return false
			return _outdoors() and _behind(CLUB_WIN_AT)
		"vent-open":
			# Форточку игрок закрыл сам, своими руками, и слышал щеколду.
			# В BEHIND этот знак не входит: смысл его в том, что заметить
			# перемену можно ТОЛЬКО вернувшись, — а вернуться в теплицу
			# незачем, пока рассада полита. Поэтому условие обратное
			# остальным: сработать он имеет право, лишь когда игрок отсюда
			# ушёл, и ждёт его молча.
			if not bool(st.has("vent-shut")):
				return false
			return String(_zone().get("id", "")) != "greenhouse"
	return false


## Сам знак. false — не сложилось (нет модуля, оверлей без звука): бюджет
## за это не тратится.
func _do(id: String) -> bool:
	var a: Variant = _cx("audio")
	var r: Variant = _cx("renderer")
	var l: Variant = _cx("lights")
	match id:
		"frame-slip":
			# Кадр повело на треть секунды — и отпустило. Ровно та ручка,
			# которой кассеты показывают «плёнку ведёт», только в мире.
			if r == null:
				return false
			r.set_tracking(0.55)
			_after(0.35, func() -> void: r.set_tracking(0.0))
			return true
		"gate-chain":
			if a == null:
				return false
			a.chain()
			_hush("yard-gate-far", 240.0)
			return true
		"lamp-out":
			var lamp := _lamp_behind()
			if lamp == "" or l == null:
				return false
			l.setLamp(lamp, false)
			return true
		"steps-above":
			if a == null:
				return false
			a.steps_above(3)
			_hush("floor-creak-far", 150.0)
			return true
		"porch-on":
			if l == null:
				return false
			l.setLamp("porch", true)
			return true
		"shed-open":
			var sd: Variant = _cx("setDoor")
			if not (sd is Callable):
				return false
			(sd as Callable).call("door-shed", true, true)
			return true
		"thirteen":
			if a == null:
				return false
			# Тринадцать. Двенадцать — это полночь, а тринадцать — это уже не часы.
			a.clock_chime(13)
			return true
		"head-switch":
			if r == null:
				return false
			r.set_head_switch(1.0)
			r.set_chroma_smear(0.6)
			_after(0.5, func() -> void:
				r.set_head_switch(0.0)
				r.set_chroma_smear(0.0))
			return true
		"knock-below":
			if a == null:
				return false
			a.knock(2, 0.42)
			return true
		"front-ajar":
			var sd2: Variant = _cx("setDoor")
			if not (sd2 is Callable):
				return false
			# Беззвучно: вся сила знака в том, что игра о нём не сообщает.
			(sd2 as Callable).call("door-front", true, true)
			return true
		"torch-dip":
			var fl: Variant = _cx("flashlight")
			if fl == null:
				return false
			fl.flicker(0.6)
			if r != null:
				r.set_grain(GRAIN_BASE * 2.2)
				_after(0.9, func() -> void: r.set_grain(GRAIN_BASE))
			return true
		"boots-gone":
			var pr: Variant = _cx("props")
			if pr == null:
				return false
			pr.show_dynamic("boots-by-fusebox", false)
			return true
		"jar-moved":
			var pr2: Variant = _cx("props")
			if pr2 == null:
				return false
			pr2.show_dynamic(JAR_FROM, false)
			pr2.show_dynamic(JAR_TO, true)
			return true
		"breath-behind":
			if a == null or not bool(a.sfx("breath-behind")):
				return false
			var fl2: Variant = _cx("flashlight")
			if fl2 != null:
				fl2.shake(0.5)
			# Тот же wav есть у dread — иначе дыхание за спиной случилось бы
			# дважды подряд, и второй раз уже смешно.
			_hush("breath-behind", 360.0)
			return true
		"ladle-sway":
			var ladle := _yard_node("banya-ladle")
			if ladle == null:
				return false
			# Пять шагов затухающего маятника. Твина здесь нет намеренно:
			# отложенные хвосты уже есть в модуле, а Tween на статичной ноде
			# пришлось бы держать живым между знаками.
			var base := ladle.rotation.z
			for i in 5:
				var k := 0.20 * pow(0.62, float(i))
				var sgn := 1.0 if i % 2 == 0 else -1.0
				_after(0.35 * float(i), func() -> void:
					ladle.rotation.z = base + k * sgn)
			_after(0.35 * 5.0, func() -> void: ladle.rotation.z = base)
			if a != null:
				a.creak(0.35)
			return true
		"banya-print":
			var pane2 := _yard_node("banya-win-e")
			if pane2 == null:
				return false
			var print_node: Node3D = pane2.get_node_or_null("print")
			if print_node == null:
				return false
			print_node.visible = true
			pane2.set_meta("printed", true)
			return true

		# ---------- фаза 12 ----------
		"bike-appear":
			var bk := _village_node("street-bike")
			if bk == null:
				return false
			bk.visible = true
			return true
		"stop-lamp":
			if l == null:
				return false
			l.setLamp("stop", false)
			return true
		"boarded-glow":
			# Полсекунды света за досками — и всё. Ни звука, ни реплики:
			# игрок либо заметил, либо нет, и второго раза не будет.
			var g2 := _village_node("boarded-glow")
			if g2 == null:
				return false
			g2.visible = true
			_after(0.55, func() -> void: g2.visible = false)
			return true
		"well-bucket":
			var bu2 := _village_node("well-bucket")
			if bu2 == null:
				return false
			# Ведро переехало на два метра к дороге, и цепь при этом на месте.
			bu2.position = Vector3(-22.10, 0.0, -7.20)
			bu2.set_meta("moved", true)
			if a != null:
				a.sfx("yard-bucket", 0.45)
			return true
		"pit-plate":
			var pl2 := _village_node("grave-pit")
			if pl2 == null:
				return false
			pl2.rotation.y = PI
			pl2.set_meta("turned", true)
			return true
		"booth-dark":
			if l == null:
				return false
			l.setLamp("booth", false)
			return true

		# ---------- фаза 13 ----------
		"garden-forks":
			var fk2 := _yard_node("forks")
			if fk2 == null:
				return false
			# Беззвучно. Вся сила знака в том, что игра о нём не сообщает:
			# вилы либо заметят, либо нет, и второго раза не будет.
			fk2.visible = true
			return true

		# ---------- фаза 14 ----------
		"upstairs-dark":
			if l == null:
				return false
			l.setLamp("redhouse-up", false)
			return true
		"club-dark":
			if l == null:
				return false
			l.setLamp("club-win", false)
			return true
		"vent-open":
			# Флаг снимается — и точка «закрыть форточку» возвращается сама,
			# вместе с подсказкой. Беззвучно и без всякой геометрии: щеколда
			# откинута, а объявить об этом некому.
			var st2: Variant = _cx("state")
			if st2 == null:
				return false
			st2.set_flag("vent-shut", false)
			return true
	return false


## Узел деревни (фаза 12) или null. Нет data/village.json — знака просто нет,
## и бюджет за него не тратится.
func _village_node(id: String) -> Node3D:
	var w: Variant = _cx("world")
	if not (w is Dictionary):
		return null
	var village: Dictionary = (w as Dictionary).get("village", {})
	var n: Variant = (village.get("nodes", {}) as Dictionary).get(id)
	return n if n is Node3D else null


## Нода участка по имени. Пусто — нет data/yard.json, и знак просто
## не складывается: бюджет за это не тратится.
func _yard_node(id: String) -> Node3D:
	var w: Variant = _cx("world")
	if not (w is Dictionary):
		return null
	var yard: Dictionary = (w as Dictionary).get("yard", {})
	var n: Variant = (yard.get("nodes", {}) as Dictionary).get(id)
	return n if n is Node3D else null


func _in_banya() -> bool:
	return String(_zone().get("id", "")) == "banya"


## Включены ли резкие эффекты (галочка на паузе). Нет ключа в ctx — включены.
func _scares_on() -> bool:
	var f: Variant = _cx("scaresOn")
	return true if not (f is Callable) else bool((f as Callable).call())


## Занять имя события в dread: знаки играют те же wav своими поводами.
func _hush(id: String, sec: float) -> void:
	var d: Variant = _cx("dread")
	if d != null:
		d.force_cooldown(id, sec)


## Горящая лампа за спиной, ближайшая. Пустая строка — такой нет.
func _lamp_behind() -> String:
	var l: Variant = _cx("lights")
	if l == null or not bool(l.powerOn):
		return ""
	var best := ""
	var best_d := INF
	for lamp: Dictionary in (l.lamps as Array):
		var id := String(lamp["id"])
		if id == "office" or not bool(l.isOn(id)):
			continue
		var p: Vector3 = lamp["pos"]
		if not _behind(p):
			continue
		var d := _feet().distance_to(p)
		if d < best_d:
			best_d = d
			best = id
	return best


## Точка сейчас вне конуса взгляда, но рядом. Стены не проверяются намеренно:
## лампа за стеной — тоже «за спиной», и гаснет она честно.
func _behind(p: Vector3) -> bool:
	var cam := _camera()
	if cam == null:
		return false
	var eye := cam.global_position
	var to := p - eye
	var d := to.length()
	if d < BEHIND_NEAR or d > BEHIND_FAR:
		return false
	var fwd := -cam.global_transform.basis.z
	return fwd.normalized().dot(to / d) < BEHIND_COS


func _after(sec: float, fn: Callable) -> void:
	_timers.append([sec, fn])


func _tick_timers(dt: float) -> void:
	if _timers.is_empty():
		return
	var keep: Array = []
	for t: Array in _timers:
		var left: float = float(t[0]) - dt
		if left <= 0.0:
			(t[1] as Callable).call()
		else:
			keep.append([left, t[1]])
	_timers = keep


func _threat_near() -> bool:
	var tv: Variant = _cx("threat")
	if not (tv is Threat):
		return false
	var t: Threat = tv
	if not t.is_active():
		return false
	var d := _feet().distance_to(t.pos)
	var st: Variant = _cx("state")
	var s := "absent" if st == null else String(st.get("threatState"))
	return d < (HUNT_NEAR if s == "hunt" else THREAT_NEAR)


func _feet() -> Vector3:
	var p: Variant = _cx("controls")
	return Vector3.ZERO if p == null else (p.feet() as Vector3)


func _camera() -> Camera3D:
	var r: Variant = _cx("renderer")
	if r == null:
		return null
	var cam: Variant = r.camera
	return cam if cam is Camera3D else null


func _outdoors() -> bool:
	return String(_zone().get("reverb", "outdoor")) == "outdoor"


func _level() -> String:
	return String(_zone().get("level", ""))


func _zone() -> Dictionary:
	var p: Variant = _cx("controls")
	var w: Variant = _cx("world")
	if p == null or not (w is Dictionary):
		return {}
	var f: Variant = (w as Dictionary).get("zone_at", null)
	if not (f is Callable):
		return {}
	var feet: Vector3 = p.feet()
	var z: Variant = (f as Callable).call(feet.x, feet.y, feet.z)
	return z if z is Dictionary else {}


func _cx(key: String) -> Variant:
	if c is Dictionary:
		return (c as Dictionary).get(key, null)
	if c == null:
		return null
	return c.get(key)

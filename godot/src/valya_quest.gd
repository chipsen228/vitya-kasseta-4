# Линия бабки Вали (фаза 15, часть 2).
#
# Одна линия связывает всё, о чём просил Пётр: живого человека напротив,
# камни, покос, кладбище за домами, огород, баню и озеро. Порядок жёсткий,
# и каждый шаг открывает следующий:
#
#   встреча 1 у ограды  -> ключ от шкафа в сарае
#   камни в круг        -> ночь становится тише (dread на ступень вниз)
#   встреча 2           -> про внука, утонувшего в озере (и озеро открывается)
#   коса -> три полосы  -> тропа, которую трава прятала
#   холм и коробка      -> лопата; событие срабатывает при отходе
#   встреча 3           -> ключ от её дома, улика в детской наверху
#   возвращение         -> её нет, камни переставлены; короткое событие в мире
#
# Контекстные события передаются HorrorDirector: общий интервал, однократность
# и владение актёром исключают наложение на обязательные сцены и поимку.
#
# ГОЛОС. Реплики Вали живут в texts.json VALYA_DIALOGUES и звучат тем же
# путём, что уличные разговоры фазы 9: playDialogue -> phone.playLines ->
# voice.play_dialogue_line(говорящий, текст). Отдельного вызова здесь нет
# и быть не должно — иначе строка прозвучала бы дважды.
#
# НЕ в CALLS: test_voice_manifest проверяет полноту только для CALLS,
# THREAT_LINES и THREAT_AT_GATE, и класть их туда значило бы завалить
# приёмку на первой же неозвученной строке. Нет записи — идёт субтитр,
# и это штатный откат, а не поломка.
#
# Нет data/valya.json — register() выходит первой строкой.

class_name ValyaQuest
extends RefCounted

## Насколько отойти от разрытого холма, чтобы получить в спину.
const GRAVE_AWAY := 5.0

var c: Dictionary = {}
var d: Dictionary = {}
var nodes: Dictionary = {}

var _seq: Array = []          # какие камни уже легли в круг, по индексам


func _init(ctx: Dictionary, world: Dictionary) -> void:
	c = ctx
	d = ValyaWorld.data()
	nodes = world.get("nodes", {})
	# Всё, что появляется по ходу, стоит на местах с загрузки и невидимо
	# до своего шага — тем же контрактом, что уличные объекты фазы 9.
	var hidden := ["scythe", "mow-path", "grave-pit"]
	for i in 4:
		hidden.append("garden-dug-%d" % i)
	for id: String in hidden:
		_show(id, false)
	_show("grave-mound", true)


func register(I: Interact) -> void:
	if d.is_empty():
		return
	var t := GameData.texts()
	var prompts: Dictionary = t["PROMPTS"]
	var beats: Dictionary = t["BEATS"]
	var looks: Dictionary = t["LOOKS"]

	_register_talk(I, prompts)
	_register_stones(I, prompts, beats)
	_register_locker(I, prompts, beats)
	_register_mow(I, beats)
	_register_grave(I, prompts, beats, looks)
	_register_bed(I, beats)
	_register_lake(I, prompts, beats, looks)
	_register_house(I, prompts, beats)
	_register_sign(I, prompts, looks)


# ------------------------------------------------------------- разговоры ----

## Три встречи и одно возвращение в пустоту. Точка одна: у её ограды.
## Какой разговор — решает состояние, а не отдельная точка на каждый:
## пять точек в одном метре друг от друга перехватывали бы [E] по очереди.
func _register_talk(I: Interact, prompts: Dictionary) -> void:
	var v: Dictionary = d.get("VALYA", {})
	var at: Array = v.get("at", [3.45, 0.0, -6.85])
	var pos := Vector3(float(at[0]), 1.35, float(at[2]))

	var when := func(s: GameState) -> bool:
		if not s.atLeast("village"):
			return false
		return _talk_key(s) != ""
	var use := func(cc: Dictionary) -> void:
		var s: GameState = cc["state"]
		var key := _talk_key(s)
		if key == "":
			return
		var dlg: Dictionary = (cc["texts"] as Dictionary).get("VALYA_DIALOGUES", {})
		var lines: Array = dlg.get(key, [])
		if lines.is_empty():
			return
		_ctx_call("playDialogue", [lines, func() -> void:
			_after_talk(cc, key)])
	I.add({
		"id": "valya-talk",
		"pos": pos, "r": 3.0, "cone": 0.5, "priority": 4,
		"prompt": prompts["talk"],
		"when": when,
		"onUse": use,
	})


## Какой разговор идёт сейчас. Пустая строка — говорить не о чем.
func _talk_key(s: GameState) -> String:
	if s.chapter == "village" and not s.has("snt-returned") and not s.has("valya-1"):
		return ""
	if not s.has("valya-1"):
		return "first"
	if s.has("stones-done") and not s.has("valya-2"):
		return "second"
	if s.has("grave-dug") and not s.has("valya-3"):
		return "third"
	return ""


func _after_talk(cc: Dictionary, key: String) -> void:
	var s: GameState = cc["state"]
	var beats: Dictionary = (cc["texts"] as Dictionary)["BEATS"]
	match key:
		"first":
			s.set_flag("valya-1")
			s.give("valya-key")
			cc["ui"].toast("Ключ от шкафа в сарае")
			_emit("valya-1")
		"second":
			s.set_flag("valya-2")
			# Озеро с этой минуты — место, а не декорация: сеть можно тянуть.
			s.set_flag("lake-told")
			cc["ui"].say(String(beats.get("valyaLake", "")), 4.2)
			_emit("valya-2")
		"third":
			s.set_flag("valya-3")
			s.give("redhouse-key")
			# ФАЗА 18. Жестянку унесли — у ямы её больше нет.
			_show("grave-tin", false)
			cc["ui"].toast("Ключ от красного дома")
			_emit("valya-3")


# ----------------------------------------------------------------- камни ----

## Пять камней в круг, и порядок читается по зарубкам. Подсказка — на обороте
## афиши в клубе; без неё порядок не угадать, и это нарочно: клуб перестаёт
## быть комнатой, в которую заходят один раз.
func _register_stones(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	var st: Dictionary = d.get("STONES", {})
	var row: Array = st.get("row", [])
	var order: Array = st.get("order", [])
	var circle: Array = st.get("circle", [0.6, -5.95])
	var rad := float(st.get("radius", 0.62))

	for i in row.size():
		var p: Array = row[i]
		var idx := i
		I.add({
			"id": "valya-stone-%d" % i,
			"pos": Vector3(float(p[0]), 0.35, float(p[1])),
			"r": 1.5, "cone": 0.45, "priority": 4,
			"prompt": "переложить камень",
			"when": func(s: GameState) -> bool:
				return s.has("valya-1") and not s.has("stones-done") \
					and not _placed(idx),
			"onUse": func(cc: Dictionary) -> void:
				_put_stone(cc, idx, order, circle, rad, beats),
		})

	# Афиша клуба. Точка осмотра на той же стене, где висит сама афиша:
	# сторона с расписанием сеансов уже осмотрена в фазе 14, эта — оборот.
	I.add({
		"id": "club-poster-back",
		"pos": Vector3(8.10, 1.35, -26.33),
		"r": 2.0, "cone": 0.5, "priority": 3,
		"prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			return s.has("valya-1") and not s.has("stones-done"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("stones-hint")
			s.looked["club-poster-back"] = true
			cc["ui"].say(String(beats.get("stonesHint", "")), 5.0),
	})


## ФАЗА 18. Досмотр видимости после отката (Interact.resync_world).
##
## Линия Вали — единственная, где откат обязан чинить не только видимость.
## Круг из камней живёт в _seq, то есть в памяти модуля, а не в снимке
## состояния: снимок это JSON с флагами. Не рассыпь его здесь — после [R]
## камни остались бы лежать в круге при снятом флаге 'stones-done',
## и головоломку стало бы нечем начать.
func resync(s: GameState) -> void:
	_show("scythe", s.has("locker-open") and not s.hasItem("scythe"))
	var strips: Array = (d.get("MOW", {}) as Dictionary).get("strips", [])
	for i in strips.size():
		_show("mow-%d" % i, not s.has("mown-%d" % i))
	_show("mow-path", s.has("mow-done"))
	_show("grave-shovel", s.has("mow-done") and not s.hasItem("tool-shovel"))
	_show("grave-mound", not s.has("grave-dug"))
	_show("grave-pit", s.has("grave-dug"))
	# Жестянка стоит у ямы, пока её не унесли к Вале (флаг valya-3).
	_show("grave-tin", s.has("grave-dug") and not s.has("valya-3"))
	for i in 4:
		_show("garden-dug-%d" % i, s.has("bed-dug") or s.has("garden-dug-%d" % i))
	_show("lake-duckweed", not s.has("net-pulled"))
	if not s.has("stones-done") and not _seq.is_empty():
		_reset_stones(c)


func _placed(i: int) -> bool:
	return _seq.has(i)


func _put_stone(cc: Dictionary, i: int, order: Array, circle: Array,
		rad: float, beats: Dictionary) -> void:
	var s: GameState = cc["state"]
	var want: int = int(order[_seq.size()]) if _seq.size() < order.size() else -1
	if i != want:
		# Ошибся — круг рассыпается целиком. Не «этот не подходит»: смысл
		# в том, что порядок надо ЗНАТЬ, а не подбирать по одному.
		_reset_stones(cc)
		cc["audio"].sfx("basket-drop")
		cc["ui"].say(String(beats.get("stonesWrong", "")), 3.6)
		return
	var n: Variant = nodes.get("stone-%d" % i)
	if n is Node3D:
		var a := TAU * float(_seq.size()) / 5.0
		(n as Node3D).position = Vector3(float(circle[0]) + sin(a) * rad, 0.0,
			float(circle[1]) + cos(a) * rad)
	_seq.append(i)
	cc["audio"].sfx("basket-drop", 0.6)
	if _seq.size() < order.size():
		# ФАЗА 18. Первый камень говорит СЧЁТЧИК И ПРАВИЛО, остальные — «Лёг».
		# Точка valya-stone-4 лежит в 0.95 м от Вали с тем же приоритетом, и
		# после реплики valya-1 точка разговора гаснет: нажатие «на Валю»
		# кладёт камень. Голое «Лёг.» на этом месте читалось ответом Вали,
		# а не началом головоломки, и Пётр там и застревал.
		var line := "stonesOne" if _seq.size() == 1 else "stonesNext"
		cc["ui"].say(String(beats.get(line, "")), 3.0 if _seq.size() == 1 else 2.4)
		return
	s.set_flag("stones-done")
	cc["ui"].say(String(beats.get("stonesDone", "")), 4.4)
	# Ночь становится тише на ступень. Не «страх выключился»: dread просто
	# перестаёт лезть так часто, и это слышно, а не читается в интерфейсе.
	var dr: Variant = c.get("dread")
	if dr != null and dr.has_method("ease"):
		dr.call("ease", 1)
	_emit("stones-done")


func _reset_stones(cc: Dictionary) -> void:
	var st: Dictionary = d.get("STONES", {})
	var row: Array = st.get("row", [])
	for i in _seq:
		var n: Variant = nodes.get("stone-%d" % int(i))
		if n is Node3D and int(i) < row.size():
			var p: Array = row[int(i)]
			(n as Node3D).position = Vector3(float(p[0]), 0.0, float(p[1]))
	_seq.clear()


# ----------------------------------------------------------------- сарай ----

## Шкаф в сарае. Заперт амбарным замком, ключ — от Вали: Витя запирал шкаф
## от неё же, и коса в нём её собственная.
func _register_locker(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	var sp: Array = (d.get("SCYTHE", {}) as Dictionary).get("locker",
		[6.9, 1.05, 13.55])
	I.add({
		"id": "shed-locker",
		"pos": Vector3(float(sp[0]), float(sp[1]), float(sp[2])),
		"r": 1.9, "cone": 0.5, "priority": 4,
		"prompt": func(s: GameState) -> String:
			return prompts["take"] if s.has("locker-open") else "открыть шкаф",
		"when": func(s: GameState) -> bool:
			return s.atLeast("village") and not s.hasItem("scythe"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if not s.has("locker-open"):
				if not s.hasItem("valya-key"):
					cc["ui"].say(String(beats.get("lockerLocked", "")), 4.0)
					return
				s.set_flag("locker-open")
				cc["audio"].sfx("door-open")
				cc["ui"].say(String(beats.get("lockerOpen", "")), 4.0)
				_show("scythe", true)
				return
			s.give("scythe")
			_show("scythe", false)
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Коса")
			cc["ui"].say(String(beats.get("scytheTaken", "")), 3.4)
			_emit("scythe"),
	})


# ----------------------------------------------------------------- покос ----

## Три полосы. Каждая гасится насовсем; после третьей проступает тропа.
func _register_mow(I: Interact, beats: Dictionary) -> void:
	var strips: Array = (d.get("MOW", {}) as Dictionary).get("strips", [])
	for i in strips.size():
		var r: Array = strips[i]
		var idx := i
		var flag := "mown-%d" % i
		I.add({
			"id": "mow-%d" % i,
			"pos": Vector3((float(r[0]) + float(r[1])) / 2.0, 0.6,
				(float(r[2]) + float(r[3])) / 2.0),
			"r": 2.6, "cone": 0.55, "priority": 3,
			"prompt": "скосить",
			"when": func(s: GameState) -> bool:
				return not s.has(flag),
			"onUse": func(cc: Dictionary) -> void:
				var s: GameState = cc["state"]
				if not s.hasItem("scythe"):
					cc["ui"].say(String(beats.get("mowNoScythe", "")), 3.6)
					return
				s.set_flag(flag)
				_show("mow-%d" % idx, false)
				cc["audio"].sfx("cloth-run")
				if not _mown_all(s, strips.size()):
					cc["ui"].say(String(beats.get("mowOne", "")), 2.6)
					_emit("mown", flag)
					return
				s.set_flag("mow-done")
				_show("mow-path", true)
				cc["ui"].say(String(beats.get("mowDone", "")), 4.6)
				_emit("mow-done"),
		})


func _mown_all(s: GameState, n: int) -> bool:
	for i in n:
		if not s.has("mown-%d" % i):
			return false
	return true


# ------------------------------------------------------------------ холм ----

## Свежий холм в деревьях. Копается лопатой, лежащей тут же, — то есть тем,
## чем его и насыпали.
##
## ПОЛНОКАДРОВЫЙ УДАР №1 ЧАСТИ 2. Бьёт не по факту раскопки, а по тому, что
## в коробке: кассета и детский сапог. Один на всю линию до самого её конца.
func _register_grave(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary) -> void:
	var g: Dictionary = d.get("GRAVE", {})
	var sh: Array = g.get("shovel", [1.70, 0.0, -28.45])
	I.add({
		"id": "grave-shovel",
		"pos": Vector3(float(sh[0]), 0.45, float(sh[2])),
		"r": 1.8, "cone": 0.5, "priority": 4,
		"prompt": prompts["take"],
		"when": func(s: GameState) -> bool:
			return s.has("mow-done") and not s.hasItem("tool-shovel"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.give("tool-shovel")
			# ФАЗА 18. Лопата гаснет, как коса: у неё наконец есть что гасить.
			_show("grave-shovel", false)
			cc["audio"].sfx("item-take")
			cc["ui"].toast("Лопата")
			cc["ui"].say(String(beats.get("shovelTaken", "")), 3.6)
			_emit("shovel"),
	})

	var dg: Array = g.get("dig", [0.9, 0.34, -28.2])
	I.add({
		"id": "grave-dig",
		"pos": Vector3(float(dg[0]), float(dg[1]) + 0.4, float(dg[2])),
		"r": 2.2, "cone": 0.5, "priority": 5,
		"prompt": func(s: GameState) -> String:
			return prompts["look"] if s.has("grave-dug") else "раскопать",
		"when": func(s: GameState) -> bool:
			return s.has("mow-done"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if s.has("grave-dug"):
				cc["ui"].say(String(looks.get("grave-mound", "")), 3.6)
				return
			if not s.hasItem("tool-shovel"):
				cc["ui"].say(String(beats.get("graveNoShovel", "")), 3.6)
				return
			s.set_flag("grave-dug")
			s.give("kovrigin-tapes")
			s.evidence = true
			_show("grave-mound", false)
			_show("grave-pit", true)
			# ФАЗА 18. Жестянка встаёт у ямы. Она главная улика второй
			# половины ночи, и до этой фазы её не было видно ни секунды.
			_show("grave-tin", true)
			cc["audio"].sfx("tin-open")
			cc["ui"].toast("Жестяная коробка: кассета и детский сапог")
			cc["ui"].say(String(beats.get("graveOpened", "")), 5.0)
			_hit_full(cc)
			# ФАЗА 18. Вторым сообщением — куда идти. Реплика graveOpened идёт
			# пять секунд и кончается полнокадровым ударом; после него игрок
			# стоит в темноте у разрытого холма с кассетой в руках и без
			# единого слова о том, что дальше. Строка задачи в углу экрана
			# 11-м кеглем этого не держит — Пётр на этом месте и застревал.
			_after(6.2, func() -> void:
				var ui: Variant = c.get("ui")
				if ui != null:
					ui.say(String(beats.get("graveWhereNext", "")), 4.4))
			_emit("grave-dug"),
	})


# ---------------------------------------------------------------- грядка ----

## Four independent optional digs. The aggregate legacy flag is only set after
## all four; an old save which already has it is handled by resync above.
func _register_bed(I: Interact, beats: Dictionary) -> void:
	var lines := [
		"Картошка. Клубни почти на поверхности.",
		"Лук. Луковицы целы, только корни почернели.",
		"Кочаны и оборванные корни. Землю недавно рыхлили.",
		String(beats.get("bedOpened", "")),
	]
	for i in 4:
		var flag := "garden-dug-%d" % i
		I.add({
			"id": "garden-bed-%d" % i,
			"pos": Vector3(-0.60, 0.55, 17.95 + float(i) * 2.1),
			"r": 2.4, "cone": 0.55, "priority": 4,
			"prompt": "раскопать грядку",
			"when": func(s: GameState) -> bool:
				return s.hasItem("tool-shovel") and not s.has("bed-dug") \
					and not s.has(flag),
			"onUse": func(cc: Dictionary) -> void:
				var s: GameState = cc["state"]
				s.set_flag(flag)
				_show(flag, true)
				if i == 3:
					s.set_flag("garden-skeleton")
					s.evidence = true
					cc["audio"].sfx("jar-glass")
					cc["ui"].toast("Старая банка с кассетами")
				else:
					cc["audio"].sfx("item-take")
				cc["ui"].say(String(lines[i]), 4.2 if i < 3 else 5.0)
				if _garden_all_dug(s):
					s.set_flag("bed-dug")
				_emit("garden-dug", i),
		})


func _garden_all_dug(s: GameState) -> bool:
	for i in 4:
		if not s.has("garden-dug-%d" % i):
			return false
	return true


# ----------------------------------------------------------------- озеро ----

## Сеть на кольях. Тянется руками, и в ней второй сапог — пара к тому,
## что лежал в жестянке под холмом.
func _register_lake(I: Interact, prompts: Dictionary, beats: Dictionary,
		looks: Dictionary) -> void:
	var lk: Dictionary = d.get("LAKE", {})
	var pl: Array = lk.get("pull", [-21.6, 0.55, -30.3])
	I.add({
		"id": "lake-net",
		"pos": Vector3(float(pl[0]), float(pl[1]), float(pl[2])),
		"r": 2.6, "cone": 0.55, "priority": 4,
		"prompt": func(s: GameState) -> String:
			return prompts["look"] if s.has("net-pulled") else "вытащить сеть",
		"when": func(s: GameState) -> bool:
			return s.has("lake-told"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			if s.has("net-pulled"):
				cc["ui"].say(String(looks.get("lake-net", "")), 3.4)
				return
			s.set_flag("net-pulled")
			s.evidence = true
			cc["audio"].sfx("yard-metal-drag")
			cc["ui"].toast("Второй сапог")
			cc["ui"].say(String(beats.get("netPulled", "")), 5.0)
			# Ряска расходится сама, и под ней стоят. Без полного кадра:
			# полнокадровых на часть ровно два, и оба уже расписаны.
			_show("lake-duckweed", false)
			var hp: Array = lk.get("haunt", [-21.3, 0.1, -31.9])
			_after(1.8, func() -> void:
				var h: Variant = c.get("haunt")
				if h != null and h.has_method("show_at"):
					h.call("show_at", Vector3(float(hp[0]), float(hp[1]),
						float(hp[2])), 2.6)
				else:
					_ctx_call("holdEcho", [3.0])
					var actors: Variant = c.get("actors")
					if actors != null:
						actors.place("echo", float(hp[0]), float(hp[1]),
							float(hp[2]), 0.0)
						actors.show("echo", true)
						_after(2.6, func() -> void:
							actors.show("echo", false))
				cc["audio"].sfx("sting-soft"))
			_emit("net-pulled"),
	})

	var bt: Array = lk.get("boat", [])
	if bt.size() == 3:
		I.add({
			"id": "lake-boat",
			"pos": Vector3(float(bt[0]), 0.55, float(bt[2])),
			"r": 2.2, "cone": 0.5, "priority": 2,
			"kind": "look",
			"prompt": prompts["look"],
			"when": func(s: GameState) -> bool:
				return s.atLeast("village"),
			"onUse": func(cc: Dictionary) -> void:
				cc["state"].looked["lake-boat"] = true
				cc["ui"].say(String(looks.get("lake-boat", "")), 4.0),
		})


# ------------------------------------------------------------ красный дом ----

## Возвращение к ограде, когда Вали там уже нет.
##
## ПОЛНОКАДРОВЫЙ УДАР №2 ЧАСТИ 2 и последний. Бьёт не фигура — бьют камни:
## круг разложен заново, и разложен не так, как его сложил игрок.
func _register_house(I: Interact, prompts: Dictionary, beats: Dictionary) -> void:
	var v: Dictionary = d.get("VALYA", {})
	var at: Array = v.get("at", [3.45, 0.0, -6.85])
	I.add({
		"id": "valya-gone",
		"pos": Vector3(float(at[0]), 1.35, float(at[2])),
		"r": 3.2, "cone": 0.55, "priority": 4,
		"prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			# Только после того, как игрок побывал наверху: до этого ему
			# незачем возвращаться, и пустая ограда ничего не значит.
			# Улика наверху — тетрадь с детского стола (village_quest,
			# 'redhouse-notebook', фаза 14). До неё возвращаться незачем,
			# и пустая ограда не значит ничего.
			return s.has("redhouse-notebook") and s.has("valya-3") \
				and not s.has("valya-gone"),
		"onUse": func(cc: Dictionary) -> void:
			var s: GameState = cc["state"]
			s.set_flag("valya-gone")
			_scatter_stones()
			cc["ui"].say(String(beats.get("valyaGone", "")), 5.0)
			_hit_full(cc)
			_emit("valya-gone"),
	})


## Камни переложены заново — в линию, поперёк круга. Кто это сделал, игра
## не говорит, и говорить не собирается.
func _scatter_stones() -> void:
	var st: Dictionary = d.get("STONES", {})
	var c0: Array = st.get("circle", [0.6, -5.95])
	for i in 5:
		var n: Variant = nodes.get("stone-%d" % i)
		if n is Node3D:
			(n as Node3D).position = Vector3(float(c0[0]) - 1.0 + 0.5 * float(i),
				0.0, float(c0[1]))


# ------------------------------------------------------------- указатель ----

## Доска у переулка. Осмотр, а не задание: он просто НАЗЫВАЕТ место словом.
## До фазы 15 ферму не называла ни одна строка, которую игрок реально видел,
## и «сходи на ферму» приходило ниоткуда.
func _register_sign(I: Interact, prompts: Dictionary, looks: Dictionary) -> void:
	var sg: Dictionary = d.get("SIGN", {})
	if sg.is_empty():
		return
	var at: Array = sg.get("at", [-25.9, 0.0, -13.6])
	I.add({
		"id": "farm-sign",
		"pos": Vector3(float(at[0]), float(sg.get("h", 1.85)) - 0.22, float(at[2])),
		"r": 2.4, "cone": 0.55, "kind": "look", "priority": 2,
		"prompt": prompts["look"],
		"when": func(s: GameState) -> bool:
			return s.atLeast("village"),
		"onUse": func(cc: Dictionary) -> void:
			(cc["state"] as GameState).looked["farm-sign"] = true
			cc["ui"].say(String(looks.get("farm-sign", "")), 3.6)
			_emit("look", "farm-sign"),
	})


# ------------------------------------------------------------- служебное ----

func _show(id: String, on: bool) -> void:
	var n: Variant = nodes.get(id)
	if n is Node3D:
		(n as Node3D).visible = on


func _emit(event: String, payload: Variant = null) -> void:
	var f: Variant = c.get("emit")
	if f is Callable:
		(f as Callable).call(event, payload)


func _ctx_call(name: String, args: Array = []) -> void:
	var f: Variant = c.get(name)
	if f is Callable:
		(f as Callable).callv(args)


## Полнокадровый удар. Через ctx.scare — его выключают в настройках, и
## текстура лица может не загрузиться; звать напрямую нельзя.
func _hit_full(cc: Dictionary) -> void:
	var director: Variant = cc.get("horror")
	if director == null: return
	var s: GameState = cc["state"]
	director.context("valya-stones-return" if s.has("valya-gone") else "valya-mound-return", "horror-wet-steps")

func _after(seconds: float, cb: Callable) -> void:
	var director: Variant = c.get("horror")
	if director != null:
		director.after(seconds, cb)
		return
	var loop := Engine.get_main_loop()
	if seconds > 0.0 and loop is SceneTree:
		(loop as SceneTree).create_timer(seconds).timeout.connect(cb)
	else:
		cb.call()

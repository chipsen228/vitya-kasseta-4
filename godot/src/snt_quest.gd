class_name SntQuest
extends RefCounted

# «Последний обход». Флаги хранят результат, время сцены живёт только здесь.
# Ни один таймер движка не переживает retry, новую игру или выход из главы.
const FLAGS := ["snt-watch-read", "snt-yard-seen", "snt-booth-used", "snt-returned"] + SntEpisode.PROGRESS
const SCENE_SECONDS := 9.0
const WATCH_PAGES := [
	"ПРАВЛЕНИЕ СНТ «ВОСХОД»\nЖурнал береговых обходов. Июль.\n\n"
		+ "Обходить от мостков до сигнального поста вдвоём. На обратном пути проверить спасательный круг на участке № 1, третья линия. Круг оставлять на наружной стене: у воды своего больше нет.\n\n"
		+ "У кого вечерний обход, тот забирает из дровяника плащ, фонарь и мерную рейку. Возвращать сухими. Рейку не переставлять: по ней сверяют воду у мостков.",
	"На полях другая рука:\n\n"
		+ "Ковригин приходил после закрытия. Просил соединить с районом. Сказал: у берега опять слышит человека, но светить туда нельзя, пока кто-нибудь не придёт с ним. Телефон дважды соединял, ответа не было.\n\n"
		+ "Оставил номер на промокшем клочке. Цифры расплылись. Под записью чужое замечание: «Он звонил со своей дачи. Сюда не заходил». Ни даты, ни подписи.",
	"ПОСЛЕДНИЙ ОБХОД\n\n"
		+ "Начат от мостков в 00:10. Круг на третьей линии проверен. На четвёртую пошёл один: напарник задержался у воды. У служебной будки подать два коротких сигнала, дождаться ответа правления.\n\n"
		+ "Если ответа нет, вернуться к первому участку. Калитку прикрыть, круг повесить снаружи. Хозяева должны видеть с дороги, что обход закончен.\n\n"
		+ "В графе «вернулся» карандаш продавил бумагу, но ничего не написал.",
	"На внутренней стороне обложки схема двух проездов.\n\n"
		+ "ТРЕТЬЯ ЛИНИЯ: первый участок у поворота, круг на стене. ЧЕТВЁРТАЯ ЛИНИЯ: по дороге вдоль северного берега, дальше за поворотом служебная будка.\n\n"
		+ "Сигнал ручной, индукторный. Два оборота рукоятки. Питание товарищества ему не нужно. Ответный звонок находится здесь, над столом.\n\n"
		+ "Снизу мелко приписано: «Если ответят уже после твоего ухода, обратно не звони». Последние слова кто-то пытался стереть резинкой.",
]
const YARD_PAGES := [
	"Круг выгорел до розового. Верёвку недавно перевязали: светлый узел на потемневшем канате. Под ним на стене четыре короткие черты карандашом и одна длинная.\n\n"
		+ "На деревянной бирке: «ОБХОД. № 1. Отметиться у сигнала на четвёртой линии». Бирка висит на новом гвозде. У старого отверстия древесина сухая, у нового темнеет.",
	"На скамье стоит эмалированная кружка, рядом раскрытая пачка спичек. Два сапога отпечатались в рыхлой земле у калитки; обратных следов отсюда не видно.\n\n"
		+ "Из окна тянется бельевая верёвка. На ней сохнет одна рукавица, пальцами вверх. Сергей задевает калитку плечом. Та скрипит, но в доме никто не шевелится.\n\n"
		+ "С обратной стороны бирки стрелка к озеру и номер служебного поста. Четвёртая линия идёт по дальнему берегу.",
]
const RETURN_PAGES := [
	"Калитка распахнута. Спасательный круг лежит у крыльца, аккуратно, верёвкой к двери. Светлый узел тот же.\n\n"
		+ "От дороги тянутся мокрые следы. Они обходят скамью, пересекают сухую полосу под навесом и кончаются перед первой ступенью. На самой ступени воды нет.\n\n"
		+ "Кружку повернули ручкой к дому. Рукавица на верёвке больше не висит. За стеклом видны только штора и край стола.",
	"На бирке появилась поперечная черта: теперь она перечёркивает все пять отметок. Под ней мокрым карандашом выведено: «Обход закончен».\n\n"
		+ "Сергей не трогает ни круг, ни дверь. В правлении кто-то ответил на сигнал. Или звонок ещё работал, когда он уходил.\n\n"
		+ "В журнале было имя Ковригина. Остальное придётся искать в его доме и в письме, которое он оставил.",
]

var c: Dictionary
var nodes: Dictionary
var points: Dictionary
var _generation := 0
var _scene_time := -1.0
var _reply_played := false
var _echo_owned := false
var _echo_shown := false
var _ambient_time := 12.0
var _ambient_index := 0
var episode: SntEpisode


func _init(context: Dictionary, world: Dictionary) -> void:
	c = context
	nodes = world.get("nodes", {})
	points = world.get("quest", {})
	episode = SntEpisode.new(c, self)


func register(interact: Interact) -> void:
	episode.register(interact)
	_add(interact, "snt-watch-log", "watch_log", Vector3(4.35, 0.8, -38.65),
		"прочитать журнал обходов", _watch)
	_add(interact, "snt-yard", "yard_inspect", Vector3(20.35, 1.4, -42.96),
		"осмотреть круг и отметку обхода", _yard,
		func(s: GameState) -> bool:
			return _available(s) and not s.has("snt-booth-used"))
	_add(interact, "snt-signal", "signal", Vector3(6.12, 1.3, -69.1),
		"повернуть рукоятку сигнала", _signal)
	_add(interact, "snt-return", "return_inspect", Vector3(19.15, 0.3, -42.30),
		"осмотреть мокрые следы", _returned,
		func(s: GameState) -> bool:
			return _available(s) and s.has("snt-booth-used") and s.has("snt-radio-heard") and s.has("snt-nina-greenhouse") and not exclusive_runtime())
	_add(interact, "snt-watermarks", "water_marks", Vector3(-1.4, 0.55, -40.63),
		"сверить отметки воды", _watermarks)
	_add(interact, "snt-last-round", "last_round", Vector3(-15.2, 1.1, -39.05),
		"осмотреть вещи обходчика", _last_round)
	# Геометрические проверки регистрируют точки без игрового состояния.
	var state: Variant = c.get("state")
	if state is GameState:
		resync(state)


func _add(interact: Interact, id: String, anchor: String, fallback: Vector3,
		prompt: String, use: Callable, when: Callable = Callable()) -> void:
	var available := when
	if not available.is_valid():
		available = func(s: GameState) -> bool:
			return _available(s)
	interact.add({"id": id, "pos": _point(anchor, fallback), "r": 2.5,
		"cone": 0.58, "priority": 5, "los_mask": CollisionWorld.ALL_SOLID,
		"prompt": prompt, "when": available, "onUse": use})


static func task_for(s: GameState) -> Variant:
	if s.chapter != "village" or not s.has("mill-clue") or s.has("snt-returned"):
		return null
	return SntEpisode.task_for(s)


func _available(s: GameState) -> bool:
	var pursuit: Variant = c.get("pursuit")
	return s.atLeast("street") and not s.atLeast("gate") and not exclusive_runtime() \
		and (pursuit == null or not pursuit.active())


func _active() -> bool:
	var s: GameState = c["state"]
	return s.chapter == "village" and s.has("mill-clue")


func _watch(_ctx: Dictionary) -> void:
	if not _available(c["state"]):
		return
	if not _active():
		_say("Журнал обходов. Между листами песок; на обложке знак мельницы. Пока непонятно, что здесь искать.")
		return
	var pages := WATCH_PAGES.duplicate()
	pages.append("СОСТАВ ДЕЖУРСТВА\n\nНина Крылова, участок № 2, третья линия: бывшая фельдшер, хранит старые записи о ночных вызовах. Семён Рябов, участок № 10, четвёртая линия: мастерская и ручной насос. Леонид Зуев, участок № 9: последний дежурный. У его фамилии нет времени возвращения.\n\nКовригин: «Проверьте дальние линии. Нина видела, кто шёл от первого участка. Если у Зуева пусто, ищите Семёна. Приёмник оставьте на четвёртой отметке».\n\nПорядок: Крыловы → круг у Лебедевых → мастерская Рябова → приёмник Зуева → ручной сигнал у северной будки. На служебной тропе есть второй выход к западному проезду.")
	_read("ПОСЛЕДНИЙ ОБХОД", pages, "snt-watch-read", "")


func _yard(_ctx: Dictionary) -> void:
	if not _available(c["state"]):
		return
	var s: GameState = c["state"]
	if s.has("snt-booth-used"):
		_returned(c)
		return
	if not _active() or not s.has("snt-watch-read"):
		_say("Спасательный круг, кружка на скамье. Калитку оставили приоткрытой. На стене отметки карандашом.")
		return
	if not s.has("snt-nina-greenhouse") and not s.has("snt-yard-seen"):
		_say("Отметки и круг у Лебедевых. Нина Крылова, со второго участка, знает, кто проверял их ночью.")
		return
	_read("ЛЕБЕДЕВЫ · УЧАСТОК № 1", YARD_PAGES, "snt-yard-seen", "snt-watch-read")


func _signal(_ctx: Dictionary) -> void:
	if not _available(c["state"]):
		return
	var s: GameState = c["state"]
	if not _active() or not s.has("snt-yard-seen") or not s.has("snt-radio-heard"):
		_say("Ручной сигнал работает без электричества. Сначала нужно проверить приёмник Зуева по записи журнала и вернуться с ответом Семёна.")
		return
	if s.has("snt-booth-used"):
		_say("Рукоятка больше не идёт. Надо вернуться к кругу, как написано в журнале.")
		return
	s.set_flag("snt-booth-used")
	_apply_world(s)
	_emit("snt-booth-used")
	_scene_time = 0.0
	_reply_played = false
	_echo_shown = false
	_call("holdEcho", [SCENE_SECONDS + 2.0])
	_spatial("chime", _point("signal", Vector3(6.12, 1.3, -69.1)), 0.9, 18.0)
	_say("Два оборота. Теперь должен ответить звонок в правлении.")


func _returned(_ctx: Dictionary) -> void:
	var s: GameState = c["state"]
	if _active() and s.has("snt-booth-used") and s.has("snt-radio-heard") and s.has("snt-nina-greenhouse") and not exclusive_runtime():
		if s.has("snt-returned"):
			_say("Семён отметил возвращение. Обход закончен.")
		elif s.has("snt-pursuit-escaped"):
			_say("Круг остался у двери. Нужно рассказать Семёну и закончить обход.")
		elif not s.has("snt-return-inspected"):
			_read("ЛЕБЕДЕВЫ · ВОЗВРАЩЕНИЕ", RETURN_PAGES.slice(0, 1), "snt-return-inspected", "snt-booth-used")
		else:
			episode.pending_pursuit = true


func _watermarks(_ctx: Dictionary) -> void:
	if not _available(c["state"]):
		return
	(c["state"] as GameState).looked["snt-watermarks"] = true
	_read("У МОСТКОВ", ["На свае зарубки с датами. Июньская выше воды на ладонь, июльская почти у самых досок. Свежая черта проходит ещё выше.\n\nПод мостками застряла мерная рейка. На ней те же числа, но в обратном порядке. Кто-то отметил уровень с двух сторон, стоя по колено в воде. Последней даты нет."], "", "")


func _last_round(_ctx: Dictionary) -> void:
	if not _available(c["state"]):
		return
	(c["state"] as GameState).looked["snt-last-round"] = true
	_read("ВЕЩИ В ДРОВЯНИКЕ", ["Между поленьями сложен брезентовый плащ. Под ним фонарь с треснувшим стеклом и сухая рукавица. На вешалке пустой крючок с надписью «обход».\n\nВ кармане плаща квитанция на ремонт берегового звонка. Фамилию заказчика оторвали вместе с краем бумаги. На обороте карандашом: «Провод целый. Проверять со стороны правления»."], "", "")


func _read(title: String, pages: Array, flag: String, prerequisite: String) -> void:
	var generation := _generation
	var revision: int = (c["state"] as GameState).runtime_revision
	var done := func() -> void:
		var s: GameState = c["state"]
		if generation != _generation or revision != s.runtime_revision or flag == "" \
				or not _active() or s.has(flag):
			return
		if prerequisite != "" and not s.has(prerequisite):
			return
		s.set_flag(flag)
		_apply_world(s)
		_emit(flag)
		if flag == "snt-return-inspected": episode.pending_pursuit = true
	c["ui"].setReaderTitle(title)
	c["ui"].openReader(title, pages, done)


func update(dt: float) -> void:
	var s: GameState = c["state"]
	if s.chapter != "village":
		if exclusive_runtime():
			cancel_runtime()
		return
	episode.update(dt)
	if not exclusive_runtime():
		_ambient(dt)
		return
	_scene_time += maxf(0.0, dt)
	var handle := _node("snt-signal-handle")
	if handle != null:
		handle.rotation.z = TAU * 2.0 * minf(_scene_time / 1.4, 1.0)
	if _scene_time >= 2.0 and not _reply_played:
		_reply_played = true
		_spatial("chime", _point("office_echo", Vector3(4.35, 1.4, -38.65)), 1.8, 60.0)
		_say("Звонят из правления. Я только что оттуда.")
	if _scene_time >= 3.4 and not _echo_shown:
		_echo_shown = true
	if _scene_time >= 7.0:
		_hide_echo()
	if _scene_time >= SCENE_SECONDS:
		_scene_time = -1.0
		if handle != null:
			handle.rotation.z = 0.0


func exclusive_runtime() -> bool:
	return _scene_time >= 0.0


func cancel_runtime() -> void:
	if episode != null: episode.cancel()
	_generation += 1
	_scene_time = -1.0
	_reply_played = false
	_echo_shown = false
	_ambient_time = 12.0
	_ambient_index = 0
	_hide_echo()
	var handle := _node("snt-signal-handle")
	if handle != null:
		handle.rotation.z = 0.0
	var audio: Variant = c.get("audio")
	if audio != null and audio.has_method("clear_spatial"):
		audio.clear_spatial()


func resync(s: GameState) -> void:
	cancel_runtime()
	_apply_world(s)


func _apply_world(s: GameState) -> void:
	if episode != null: episode.resync(s)
	var changed := s.has("snt-booth-used")
	var gate := _node("snt-p01-gate")
	if gate != null:
		gate.rotation.y = float(points.get("gate_open" if changed else "gate_closed", -2.2 if changed else -1.05))
	var ring := _node("snt-p01-ring")
	if ring != null:
		ring.position = _point("ring_return" if changed else "ring_initial",
			Vector3(19.48, 0.28, -42.65) if changed else Vector3(20.35, 1.36, -42.96))
		ring.rotation = _point("ring_return_rotation" if changed else "ring_initial_rotation",
			Vector3.ZERO if changed else Vector3(PI / 2.0, 0, 0))
	var traces := _node("snt-p01-traces")
	if traces != null:
		traces.visible = changed
	for id: String in ["snt-p01-first-tracks", "snt-p01-glove"]:
		var original := _node(id)
		if original != null:
			original.visible = not changed
	var cross := _node("snt-p01-tag-cross")
	if cross != null:
		cross.visible = changed
	var mug := _node("snt-p01-mug")
	if mug != null:
		mug.rotation.y = PI if changed else 0.0



func _show_echo() -> void:
	var scares: Variant = c.get("scaresOn")
	if scares is Callable and not bool(scares.call()): return
	var actors: Variant = c.get("actors")
	if actors == null:
		return
	# holdEcho гасит чужую фигуру, поэтому вызывается до place/show.
	_call("holdEcho", [SCENE_SECONDS + 2.0])
	var at := _point("silhouette", Vector3(8.07, 0.0, -70.1))
	actors.place("echo", at.x, at.y, at.z, 0.0)
	var controls: Variant = c.get("controls")
	if controls != null:
		var feet: Vector3 = controls.feet()
		actors.face("echo", feet.x, feet.z)
	actors.show("echo", true)
	_echo_owned = true
	if not (scares is Callable) or bool((scares as Callable).call()):
		_spatial("stinger-2", at, 0.55, 22.0)


func _hide_echo() -> void:
	if _echo_owned:
		var actors: Variant = c.get("actors")
		if actors != null:
			actors.show("echo", false)
	_echo_owned = false


func _ambient(dt: float) -> void:
	var controls: Variant = c.get("controls")
	if controls == null:
		return
	var feet: Vector3 = controls.feet()
	if feet.z > -34.4 or feet.z < -74.0 or feet.x < -46.0 or feet.x > 44.0:
		return
	_ambient_time -= dt
	if _ambient_time > 0.0:
		return
	_ambient_time = 18.0 + float(_ambient_index % 3) * 4.0
	var sounds := ["creak-soft", "step-water", "dog"]
	var anchors := [Vector3(20.35, 1.0, -43.0), Vector3(-2.0, 0.0, -42.0), Vector3(-27.0, 1.0, -57.0)]
	_spatial(sounds[_ambient_index % 3], anchors[_ambient_index % 3], 0.5, 28.0)
	_ambient_index += 1


func _point(key: String, fallback: Vector3) -> Vector3:
	var value: Variant = points.get(key, fallback)
	if value is Vector3:
		return value
	if value is Array and value.size() >= 3:
		return Vector3(float(value[0]), float(value[1]), float(value[2]))
	return fallback


func _node(id: String) -> Node3D:
	var value: Variant = nodes.get(id)
	return value if value is Node3D else null


func _spatial(sound: String, at: Vector3, gain: float, distance: float) -> void:
	var audio: Variant = c.get("audio")
	if audio != null and audio.has_method("spatial_sfx"):
		audio.spatial_sfx(sound, at, gain, distance)


func _say(line: String) -> void:
	c["ui"].say(line, 4.8)


func _emit(event: String) -> void:
	_call("emit", [event])


func _call(key: String, args: Array) -> void:
	var callback: Variant = c.get(key)
	if callback is Callable:
		(callback as Callable).callv(args)

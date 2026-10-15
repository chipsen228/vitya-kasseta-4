class_name SntEpisode
extends RefCounted

const PROGRESS := ["snt-nina-met", "snt-nina-greenhouse", "snt-semyon-met",
	"snt-pump-found", "snt-pump-fixed", "snt-filter-read", "snt-route-known",
	"snt-radio-set", "snt-radio-heard", "snt-return-inspected",
	"snt-pursuit-started", "snt-pursuit-escaped"]
const SEMYON_PHRASE := "Если услышишь меня у воды, не отвечай. Я туда больше не хожу."
const DATA := "res://data/snt_episode.json"
static var _data: Dictionary = {}
var c: Dictionary
var quest: SntQuest
var pending_pursuit := false
var _pump_time := 0.0
var _knock_left := 0.0

func _init(context: Dictionary, owner: SntQuest) -> void:
	c = context
	quest = owner

static func data() -> Dictionary:
	if _data.is_empty():
		var f := FileAccess.open(DATA, FileAccess.READ)
		if f != null:
			var parsed: Variant = JSON.parse_string(f.get_as_text())
			if parsed is Dictionary: _data = parsed
	return _data

static func task_for(s: GameState) -> Variant:
	if not s.has("snt-watch-read"): return GameData.texts()["TASKS"]["sntWatch"]
	if not s.has("snt-nina-met"): return "Найти Нину Крылову: участок № 2, третья линия."
	if not s.has("snt-nina-greenhouse"): return "Поговорить с Ниной у теплицы за домом Крыловых."
	if not s.has("snt-yard-seen"): return "Осмотреть круг и следы у Лебедевых: участок № 1."
	if not s.has("snt-semyon-met"): return "Найти Семёна Рябова в мастерской: участок № 10, четвёртая линия."
	if not s.has("snt-pump-found"): return "Найти источник стука в мастерской Рябова."
	if not s.has("snt-pump-fixed"): return "Закрепить рукоять ручного насоса деревянным клином."
	if not s.has("snt-filter-read"): return "Открыть фильтр насоса и осмотреть мокрую ткань."
	if not s.has("snt-route-known"): return "Спросить Семёна о бирке обходчика и служебной тропе."
	if not s.has("snt-radio-set"): return "Настроить приёмник у Зуевых по журналу: участок № 9, отметка 4."
	if not s.has("snt-radio-heard"): return "Прослушать приёмник у Зуевых."
	if not s.has("snt-booth-used"): return GameData.texts()["TASKS"]["sntSignal"]
	if not s.has("snt-return-inspected"): return "Вернуться к Лебедевым и проверить мокрые следы."
	if not s.has("snt-pursuit-escaped"): return "Уйти от Обходчика: лесная тропа у будки или прежний въезд в СНТ."
	return "Вернуться к Семёну Рябову и закончить обход."

func register(i: Interact) -> void:
	_add(i, "snt-nina-talk", "nina", Vector3(27.5, 1.25, -42.0), "поговорить с Ниной Крыловой",
		func() -> void: _conversation("nina_first", "snt-nina-met", "snt-watch-read"))
	_add(i, "snt-nina-greenhouse", "nina_greenhouse", Vector3(30.3, 1.25, -46.8), "спросить Нину о ночных обходах",
		func() -> void: _conversation("nina_greenhouse", "snt-nina-greenhouse", "snt-nina-met"), "snt-nina-met")
	_add(i, "snt-semyon-talk", "semyon", Vector3(-28.5, 1.2, -49.25), "поговорить с Семёном Рябовым", _semyon)
	_add(i, "snt-pump-source", "pump", Vector3(-26.15, 1.03, -49.0), "найти источник стука",
		func() -> void: _find_pump(), "", "snt-pump-found")
	_add(i, "snt-pump-fix", "pump", Vector3(-26.15, 1.03, -49.0), "закрепить рукоять насоса",
		func() -> void: _fix_pump(), "snt-pump-found", "snt-pump-fixed")
	_add(i, "snt-pump-filter", "pump_filter", Vector3(-26.0, 0.55, -49.0), "открыть фильтр насоса",
		func() -> void: _filter(), "snt-pump-fixed", "snt-filter-read")
	_add(i, "snt-radio-tune", "radio", Vector3(7.1, 0.7, -58.86), "настроить приёмник: отметка 4",
		func() -> void: _tune(), "snt-route-known", "snt-radio-set")
	_add(i, "snt-radio-listen", "radio", Vector3(7.1, 0.7, -58.86), "прослушать приёмник",
		func() -> void: _conversation("radio", "snt-radio-heard", "snt-radio-set"), "snt-radio-set", "snt-radio-heard")
	_add(i, "snt-route-map", "semyon", Vector3(-28.5, 1.2, -49.25), "показать Семёну бирку обходчика",
		func() -> void: _conversation("route", "snt-route-known", "snt-filter-read"), "snt-filter-read", "snt-route-known")

func _add(i: Interact, id: String, anchor: String, fallback: Vector3, prompt: String,
		use: Callable, need := "", done := "") -> void:
	i.add({"id": id, "pos": quest._point(anchor, fallback), "r": 2.1, "cone": 0.55,
		"priority": 5, "los_mask": CollisionWorld.ALL_SOLID, "prompt": prompt,
		"when": func(s: GameState) -> bool:
			if id == "snt-semyon-talk" and s.has("snt-filter-read") and not s.has("snt-route-known") and not s.has("snt-pursuit-escaped"): return false
			if id == "snt-nina-talk" and s.has("snt-nina-met"): return false
			return quest._available(s) and (need == "" or s.has(need)) and (done == "" or not s.has(done)),
		"onUse": func(_ctx: Dictionary) -> void: use.call()})

func _conversation(key: String, flag: String, prerequisite: String) -> void:
	var s: GameState = c["state"]
	if not quest._active() or (prerequisite != "" and not s.has(prerequisite)):
		quest._say("Сначала нужно разобраться с журналом обходов в правлении.")
		return
	if s.has(flag):
		quest._say(String(data().get("repeat", {}).get(key, "Мы уже это обсудили. Следующая отметка есть в журнале.")))
		return
	var generation := quest._generation
	var revision := s.runtime_revision
	var rows: Array = data().get("dialogues", {}).get(key, [])
	var done := func() -> void:
		if generation != quest._generation or revision != s.runtime_revision or not quest._active(): return
		if prerequisite != "" and not s.has(prerequisite): return
		_complete(flag)
	var play: Variant = c.get("playDialogue")
	if play is Callable and not rows.is_empty():
		play.call(rows, done)
	else:
		quest._read("ПОСЛЕДНИЙ ОБХОД", ["Разговор завершён."], flag, prerequisite)

func _complete(flag: String) -> void:
	var s: GameState = c["state"]
	if s.has(flag): return
	s.set_flag(flag)
	quest._apply_world(s)
	quest._emit(flag)

func _semyon() -> void:
	var s: GameState = c["state"]
	if s.has("snt-pursuit-escaped"):
		_conversation("finish", "snt-returned", "snt-pursuit-escaped")
	elif s.has("snt-filter-read"):
		_conversation("route", "snt-route-known", "snt-filter-read")
	else:
		_conversation("semyon_first", "snt-semyon-met", "snt-yard-seen")

func _find_pump() -> void:
	if not quest._active() or not (c["state"] as GameState).has("snt-semyon-met"):
		quest._say("Стук идёт от ручного насоса. Стоит спросить хозяина мастерской.")
		return
	_complete("snt-pump-found")
	quest._say("Рукоять движется сама. Между стойкой и рычагом есть место для клина.")

func _fix_pump() -> void:
	_complete("snt-pump-fixed")
	quest._spatial("snt-pump-stop", quest._point("pump", Vector3(-26, 0.95, -49)), 0.30, 9.0)
	quest._say("Клин держит рукоять. Стук прекратился. Теперь можно открыть фильтр.")

func _filter() -> void:
	quest._read("ФИЛЬТР РУЧНОГО НАСОСА", [
		"Под крышкой намотана мокрая ткань. На ней нет ржавчины, хотя сетка почти рассыпалась. Пальцы оставляют на ткани след, который сразу заполняется водой.\n\nВ складке металлическая бирка: «ЗУЕВ Л. П. ОБХОД № 4». В журнале у этой фамилии пустая графа возвращения. Сергей оставляет бирку на крышке и зовёт Семёна."], "snt-filter-read", "snt-pump-fixed")

func _tune() -> void:
	var everyday: Variant = c.get("everyday")
	if everyday != null: everyday._stop_radio()
	var defs: Dictionary = everyday.definitions if everyday != null else {}
	if defs.has("decor-p09-radio"):
		(defs["decor-p09-radio"]["moving"] as Node3D).rotation.z = 1.05
	_complete("snt-radio-set")
	quest._spatial("radio-veranda", quest._point("radio", Vector3(7.1, 0.7, -58.86)), 0.25, 12.0)
	quest._say("Четвёртая отметка на шкале. Помехи стихли. В приёмнике чей-то голос.")

func update(dt: float) -> void:
	var s: GameState = c["state"]
	if not quest._active() or s.has("snt-returned"): return
	var ctrl: Variant = c.get("controls")
	var pump := _pump_handle()
	if pump != null and s.has("snt-semyon-met") and not s.has("snt-pump-fixed"):
		_pump_time += dt
		pump.rotation.z = sin(_pump_time * 2.9) * 0.25
		_knock_left -= dt
		if _knock_left <= 0.0 and ctrl != null and ctrl.feet().distance_to(pump.global_position) < 8.0:
			_knock_left = 2.7
			quest._spatial("snt-pump-knock", pump.global_position, 0.3, 10.0)
	if pending_pursuit and not quest.exclusive_runtime():
		var pursuit: Variant = c.get("pursuit")
		if pursuit != null and pursuit.begin(): pending_pursuit = false

func resync(s: GameState) -> void:
	pending_pursuit = s.chapter == "village" and s.has("snt-return-inspected") and not s.has("snt-pursuit-escaped") and not s.has("snt-returned")
	var pump := _pump_handle()
	if pump != null: pump.rotation.z = 0.0
	var wedge := quest._node("snt-pump-wedge")
	if wedge != null: wedge.visible = s.has("snt-pump-fixed")
	var cloth := quest._node("snt-pump-cloth")
	if cloth != null: cloth.visible = s.has("snt-filter-read")
	var actors: Variant = c.get("episodeActors")
	if actors != null and actors.has_method("sync_story"): actors.sync_story(s)
	var col: CollisionWorld = c.get("col")
	var gate := quest._node("snt-forest-gate")
	if gate != null: gate.rotation.y = -PI / 2.0 if s.has("snt-booth-used") else 0.0
	if col != null:
		col.set_blocker_active("snt-forest-gate", not s.has("snt-booth-used"))
		var physics: Variant = c.get("physics")
		if physics != null: physics.sync()

func cancel() -> void:
	pending_pursuit = false
	_knock_left = 0.0

func _pump_handle() -> Node3D:
	var everyday: Dictionary = (c.get("world", {}) as Dictionary).get("everyday", {})
	var owner: Variant = (everyday.get("nodes", {}) as Dictionary).get("decor-p10-pump")
	return owner.get_node_or_null("handle") if owner is Node3D else quest._node("snt-pump-handle")

# Соседи на улице — три фигуры и ни одного нового механизма (фаза 9).
#
# ПОЧЕМУ ОНИ НЕ ИИ. Дед на улицу выйти не может и не сможет: nav.json держит
# street, office и privy в banRooms, а nav_graph._rasterize выбрасывает всё
# с level == "street"/"plot" — слоёв в графе пять, и уличного среди них нет.
# Завести улицу в граф значит перепечь nav_baked.json, а он принят и заморожен.
# Соседям граф и не нужен: они не преследуют, не обходят препятствия и не ищут
# игрока. Аркадий ходит по кольцу из data/street.json с линейной интерполяцией,
# крикун и наблюдатель стоят.
#
# ЧТО ЗДЕСЬ ГОТОВОЕ, А ЧТО НОВОЕ. Готовое: Actors.place/face/show/walk_anim
# (фаза шагов считается из пройденного расстояния, контроллер не нужен),
# ctx.playDialogue поверх Phone.playLines (перемотка по [E], заморозка игрока,
# субтитры). Новое здесь — только расписание: кто где стоит, когда говорит
# и когда меняется лицо.
#
# ТРИ ПРАВИЛА, КОТОРЫЕ ДЕРЖАТ СЦЕНУ:
#
# 1. Соседи не опасны. Ни один из них не ловит игрока и не мешает ему ходить —
#    у них нет физического тела вовсе. Единственная угроза в игре остаётся одна,
#    и появление второй размыло бы её.
# 2. Лицо наблюдателя меняется ТОЛЬКО вне кадра. Подмена, замеченная в момент
#    смены, читается как поп-ин текстуры, а не как ужас: пугает не переход,
#    а то, что игрок отвернулся и вернулся к другому лицу.
# 3. Свет в окне наблюдателя идёт МИМО пула ламп (lights.gd POOL_SIZE = 2).
#    Займи он слот пула — окно за тридцать метров погасило бы лампу в комнате,
#    в которой игрок стоит.

class_name Neighbours
extends RefCounted

# Кто есть кто. Ключи те же, что в Actors.KEYS и в data/street.json.
const ARKADY := "arkady"
const SHOUTER := "shouter"
const WATCHER := "watcher"

# Одежда. Дед в телогрейке 0x4a5f52 и рабочих штанах 0x3d4b52 — соседи одеты
# иначе, и это единственное, чем их различают на десяти метрах в тумане.
const DRESS := {
	ARKADY: [0x5d4530, 0x2b2f33, 0x3a3f43],       # брезентовая куртка, тёмные штаны
	SHOUTER: [0x93a9b4, 0x4e5459, 0x8b9095],      # застиранная майка, треники
	WATCHER: [0x9c9482, 0x3a3f43, 0x2b2f33],      # светлая рубаха — он в доме
	VALYA: [0x4a4139, 0x2f2b26, 0x6a6154],        # тёмная кофта, юбка, платок
}

# Фаза 15. Валя стоит у своей ограды и доворачивается на игрока — тем же
# приёмом, что наблюдатель в окне, только без подмены лица: у неё оно одно,
# и в этом вся разница между «за тобой следят» и «на тебя смотрят».
const VALYA := "valya"

# Аркадий. Ходит медленно, у поворотных точек стоит.
const WALK_SPEED := 0.72
const TURN_RATE := 2.2
const NODE_EPS := 0.25
const PAUSE_MIN := 1.6
const PAUSE_MAX := 4.2
const TALK_DIST := 3.2            # ближе этого он останавливается сам

# Крикун у забора. Появляется по дистанции, орёт и уходит в дом. Кулдаун
# в полторы минуты давал его ровно дважды за главу — он был не жителем линии,
# а сценкой; сорок секунд превращают его в того, мимо кого ходишь.
const BARK_DIST := 7.0
const BARK_COOL := 42.0
const BARK_HOLD := 2.6

# Крикун в окне. Орёт при подходе и повторяет, пока игрок не ушёл. Пауза
# случайная из полосы: ровные полминуты читаются как заевшая пластинка,
# а не как живой сосед, которому надоело.
const YELL_DIST := 11.0
const YELL_GAP_MIN := 20.0
const YELL_GAP_MAX := 30.0
const YELL_PULSE := 0.45          # на столько секунд окно вздрагивает светом

# Наблюдатель. Лицо меняется не чаще, чем раз в SWAP_GAP, и только когда его
# нет в кадре: cos половины конуса 0.55 — примерно 57°, то есть с запасом
# за края экрана.
const VIEW_COS := 0.55
const VIEW_FAR := 30.0
const SWAP_GAP := 9.0
const TURN_SLOW := 0.30           # доворот к игроку, рад/с, и только вне кадра

var c: Dictionary = {}
var actors: Actors = null
var street: Dictionary = {}
var enabled := false

# Аркадий
var arkady_state := "off"         # off | route | home | talk
var _route: Array = []
var _node := 0
var _pos := Vector2.ZERO
var _wait := 0.0
var _home := Vector2.ZERO
var _speed := WALK_SPEED

# Крикун
var _bark_cool := 0.0
var _bark_hold := 0.0
var _barked := 0

# Наблюдатель
var _watch_on := false
var _watch_face := 0
var _watch_gap := 0.0
var _watch_faces: Array = []
var _watch_at := Vector3.ZERO
var _watch_look := Vector2.ZERO
var _lamp: OmniLight3D = null
# Валя (фаза 15). Позиция и курс из данных, всё остальное — состояние.
var _valya_at := Vector3.ZERO
var _valya_yaw := 0.0
var _valya_near := 15.0
var _valya_turn := 0.55
var _valya_on := false

var _yell_cool := 0.0
var _yelled := 0
var _pulse := 0.0

var _rng := RandomNumberGenerator.new()


func _init(ctx: Dictionary, street_data: Dictionary, rng_seed := 0) -> void:
	c = ctx
	street = street_data
	_rng.seed = rng_seed
	actors = c.get("actors")


## Расставить фигуры. Идемпотентно; без data/street.json не делает ничего.
func build(world_root: Node3D) -> Neighbours:
	if enabled or actors == null or street.is_empty():
		return self
	var defs: Dictionary = street.get("neighbours", {})
	if defs.is_empty():
		return self
	enabled = true

	for who: String in [ARKADY, SHOUTER, WATCHER, VALYA]:
		var d: Dictionary = defs.get(who, {})
		var dress: Array = DRESS[who]
		actors.dress(who, int(dress[0]), int(dress[1]), int(dress[2]))
		var face := String(d.get("face", ""))
		if face != "":
			actors.set_face(who, face)
		actors.show(who, false)

	var vl: Dictionary = defs.get(VALYA, {})
	var vat: Array = vl.get("at", [])
	if vat.size() == 3:
		_valya_at = Vector3(float(vat[0]), float(vat[1]), float(vat[2]))
		_valya_yaw = float(vl.get("yaw", PI))
		_valya_near = float(vl.get("near", 15.0))
		_valya_turn = float(vl.get("turn", 0.55))
		actors.place(VALYA, _valya_at.x, _valya_at.y, _valya_at.z, _valya_yaw)

	var route: Dictionary = street.get("route", {})
	_route = route.get("points", [])
	_speed = float(route.get("speed", WALK_SPEED))
	var home: Array = route.get("home", [])
	if home.size() == 2:
		_home = Vector2(float(home[0]), float(home[1]))
	if not _route.is_empty():
		var p: Array = _route[0]
		_pos = Vector2(float(p[0]), float(p[1]))

	# Крикун стоит у своего забора с самого начала, но невидим до сработки.
	var sh: Dictionary = defs.get(SHOUTER, {})
	var sat: Array = sh.get("at", [])
	if sat.size() == 3:
		actors.place(SHOUTER, float(sat[0]), float(sat[1]), float(sat[2]),
			float(sh.get("yaw", 0.0)))

	# Наблюдатель: точка в окне, два лица и своя лампа мимо пула.
	var w: Dictionary = defs.get(WATCHER, {})
	var wat: Array = w.get("at", [])
	if wat.size() == 3:
		_watch_at = Vector3(float(wat[0]), float(wat[1]), float(wat[2]))
	var look: Array = w.get("look", [])
	_watch_look = Vector2(float(look[0]), float(look[1])) if look.size() == 2 \
		else Vector2(_watch_at.x, _watch_at.z + 4.0)
	_watch_faces = [String(w.get("face", "")), String(w.get("face2", ""))]
	_build_lamp(world_root, w.get("light", {}))
	return self


func _build_lamp(world_root: Node3D, d: Dictionary) -> void:
	if d.is_empty() or world_root == null:
		return
	var at: Array = d.get("pos", [])
	if at.size() != 3:
		return
	_lamp = OmniLight3D.new()
	_lamp.name = "WatcherWindow"
	_lamp.light_color = GameData.color(int(d.get("color", 0xf3d8a8)))
	_lamp.light_energy = 0.0
	_lamp.omni_range = float(d.get("range", 6.0))
	_lamp.omni_attenuation = 1.6
	_lamp.shadow_enabled = false
	_lamp.visible = false
	_lamp.position = Vector3(float(at[0]), float(at[1]), float(at[2]))
	world_root.add_child(_lamp)
	_lamp.set_meta("power", float(d.get("power", 5.0)))


# ------------------------------------------------------------- управление ---

## Аркадий на улице. "route" — ходит по кольцу, "home" — стоит у своей калитки,
## "off" — его нет вовсе.
func set_arkady(state: String) -> void:
	if not enabled:
		return
	arkady_state = state
	if state == "off":
		actors.show(ARKADY, false)
		return
	if state == "home" and _home != Vector2.ZERO:
		_pos = _home
		actors.place(ARKADY, _pos.x, 0.0, _pos.y, 0.0)
		actors.face(ARKADY, _pos.x, _pos.y + 4.0)
	actors.show(ARKADY, true)


## Где он сейчас. Спрашивает квест: точка «заговорить» едет за ним покадрово.
func arkady_pos() -> Vector3:
	return Vector3(_pos.x, 0.0, _pos.y)


func arkady_here() -> bool:
	return enabled and arkady_state != "off"


## Наблюдатель в окне: фигура плюс своя лампа.
func set_watcher(on: bool) -> void:
	if not enabled:
		return
	_watch_on = on
	actors.show(WATCHER, on)
	if on:
		actors.place(WATCHER, _watch_at.x, _watch_at.y, _watch_at.z, 0.0)
		actors.face(WATCHER, _watch_look.x, _watch_look.y)
		_watch_face = 0
		_apply_face()
	if _lamp != null:
		_lamp.visible = on
		_lamp.light_energy = float(_lamp.get_meta("power", 5.0)) if on else 0.0


func watcher_point() -> Vector3:
	return _watch_at


## Сколько раз крикун уже орал. Квест по этому решает, показывать ли задачу.
func barks() -> int:
	return _barked


# ---------------------------------------------------------------- кадр ------

func update(dt: float) -> void:
	if not enabled:
		return
	_arkady(dt)
	_shouter(dt)
	_watcher(dt)
	_valya(dt)


# ---------- Валя (фаза 15) ----------

## Она стоит. Всё, что она делает, — медленно доворачивается на подошедшего
## и смотрит, пока он не уйдёт. Не крикун (тот появляется и исчезает) и не
## наблюдатель (тот отворачивается, как только на него посмотрят): Валя
## поворачивается ИМЕННО когда на неё смотрят, и в этом вся разница между
## «за тобой следят» и «на тебя смотрят».
##
## Появляется в главе ДЕРЕВНЯ и уходит, когда её линия кончилась (флаг
## 'valya-gone' ставит valya_quest). Возвращать её потом некому и незачем.
func _valya(dt: float) -> void:
	if _valya_at == Vector3.ZERO:
		return
	var st: Variant = c.get("state")
	var on := st != null and bool(st.atLeast("village")) \
		and not bool(st.has("valya-gone"))
	if on != _valya_on:
		_valya_on = on
		actors.show(VALYA, on)
		if on:
			actors.place(VALYA, _valya_at.x, _valya_at.y, _valya_at.z, _valya_yaw)
	if not on:
		return
	var feet := _feet()
	var d := Vector2(feet.x - _valya_at.x, feet.z - _valya_at.z).length()
	# Первый раз, когда игрок подошёл на восемь метров. Строка задачи про неё
	# встаёт отсюда: сама по себе фигура у ограды — не задание, а человек,
	# и «поговорить» игра предлагает только после того, как он её УВИДЕЛ.
	if d < 8.0 and st != null and not bool(st.has("valya-seen")):
		st.set_flag("valya-seen")
		var em: Variant = c.get("emit")
		if em is Callable:
			(em as Callable).call("valya-seen", null)
	if d < _valya_near:
		actors.face_to(VALYA, feet.x, feet.z, dt, _valya_turn)
	actors.walk_anim(VALYA, dt, {"speed": 0.0, "moving": false, "idle": 1.0,
		"lookAt": [feet.x, feet.z] if d < _valya_near else null})


# ---------- Аркадий ----------

func _arkady(dt: float) -> void:
	if arkady_state == "off":
		return
	var feet := _feet()

	if arkady_state == "talk" or arkady_state == "home":
		actors.place(ARKADY, _pos.x, 0.0, _pos.y, actors.get_actor(ARKADY).rotation.y)
		actors.face_to(ARKADY, feet.x, feet.z, dt, TURN_RATE)
		actors.walk_anim(ARKADY, dt, {"speed": 0.0, "moving": false, "idle": 1.0,
			"lookAt": [feet.x, feet.z]})
		return

	if _route.size() < 2:
		return

	# Игрок подошёл вплотную — сосед останавливается сам. Разговаривать с идущим
	# мимо человеком нельзя: он уходит ровно в тот момент, когда его окликают.
	var near := Vector2(feet.x, feet.z).distance_to(_pos) < TALK_DIST
	if near or _wait > 0.0:
		_wait = maxf(0.0, _wait - dt)
		actors.place(ARKADY, _pos.x, 0.0, _pos.y, actors.get_actor(ARKADY).rotation.y)
		if near:
			actors.face_to(ARKADY, feet.x, feet.z, dt, TURN_RATE)
		actors.walk_anim(ARKADY, dt, {"speed": 0.0, "moving": false, "idle": 1.0,
			"lookAt": [feet.x, feet.z] if near else null})
		return

	var target: Array = _route[_node]
	var to := Vector2(float(target[0]), float(target[1])) - _pos
	var ln := to.length()
	if ln <= NODE_EPS:
		_node = (_node + 1) % _route.size()
		_wait = _rng.randf_range(PAUSE_MIN, PAUSE_MAX)
		return
	var step := minf(ln, _speed * dt)
	_pos += to / ln * step
	actors.place(ARKADY, _pos.x, 0.0, _pos.y, actors.get_actor(ARKADY).rotation.y)
	actors.face_to(ARKADY, float(target[0]), float(target[1]), dt, TURN_RATE)
	# speed не передаём: walk_anim считает шаги по фактическому смещению фигуры,
	# и это единственная правда о том, шёл он или стоял.
	actors.walk_anim(ARKADY, dt, {"idle": 0.0})


# ---------- крикун ----------

# Барк, а не диалог: одна реплика по дистанции, без меню и без ответа. Игрок
# на неё не отвечает и ответить не может — в этом и суть, сосед его не слушает.
func _shouter(dt: float) -> void:
	if _bark_cool > 0.0:
		_bark_cool -= dt
	if _bark_hold > 0.0:
		_bark_hold -= dt
		if _bark_hold <= 0.0:
			actors.show(SHOUTER, false)
		return
	if _bark_cool > 0.0:
		return

	var st: Variant = c.get("state")
	if st == null or not bool(st.atLeast("street")):
		return
	var defs: Dictionary = street.get("neighbours", {})
	var d: Dictionary = defs.get(SHOUTER, {})
	var at: Array = d.get("at", [])
	if at.size() != 3:
		return
	var p := Vector3(float(at[0]), float(at[1]), float(at[2]))
	var feet := _feet()
	if feet.distance_to(p) > float(d.get("trigger", BARK_DIST)):
		return

	_bark_cool = float(d.get("cooldown", BARK_COOL))
	_bark_hold = BARK_HOLD
	_barked += 1
	actors.show(SHOUTER, true)
	actors.face(SHOUTER, feet.x, feet.z)

	var beats: Dictionary = (c.get("texts", {}) as Dictionary).get("BEATS", {})
	_shout("shout-fence", String(beats.get("shouterBark", "")))
	# Дёрнуть кадр, но мягко: это гэг соседа, а не скример.
	var fl: Variant = c.get("flashlight")
	if fl != null:
		fl.shake(0.6 if _scares_on() else 0.2)
	_emit("shouter", _barked)


# Крик соседа. Голос выбирает реплику сам и возвращает ту, которую сыграл, —
# субтитр обязан совпасть со звуком до буквы, а не быть «примерно тем же».
#
# ПОЧЕМУ НЕ SFX. До этого крик шёл через audio.sfx("scream-far"): файл сделан
# моделью звуковых эффектов, и она наговорила на него по-английски. В русской
# деревне это слышно сразу и портит всю сцену, поэтому крики теперь обычные
# реплики с обычным ключом, только на своём канале и со своей обработкой.
func _shout(set_name: String, fallback: String) -> String:
	var v: Variant = c.get("voice")
	var said := "" if v == null else String(v.say_shout(set_name))
	if said == "":
		# Сборки без озвучки крик не теряют: остаётся субтитр, скрип и хлопок.
		said = fallback
		var audio: Variant = c.get("audio")
		if audio != null:
			audio.creak(1.4)
			audio.knock(1)
	var ui: Variant = c.get("ui")
	if ui != null and said != "":
		ui.say(said, 3.0, GameVoice.PRIO_LINE)
	return said


# ---------- наблюдатель ----------

func _watcher(dt: float) -> void:
	if not _watch_on:
		return
	_yell(dt)
	_watch_gap = maxf(0.0, _watch_gap - dt)
	var seen := _in_view(actors.face_point(WATCHER))
	if seen:
		return
	# Вне кадра ему можно всё: и довернуться к игроку, и стать другим.
	var feet := _feet()
	actors.face_to(WATCHER, feet.x, feet.z, dt, TURN_SLOW)
	if _watch_gap > 0.0 or _watch_faces.size() < 2:
		return
	if String(_watch_faces[1]) == "":
		return
	_watch_gap = SWAP_GAP
	_watch_face = 1 - _watch_face
	_apply_face()


## Занавеска шевельнулась (фаза 12). Тот же вздрог света, что на крике,
## и без единого слова: игрок постучал в три двери, никто не открыл, а в этом
## окне кто-то подошёл к стеклу и отошёл. Зовёт street_quest после третьего
## стука.
func watcher_pulse() -> void:
	if not enabled or not _watch_on:
		return
	_pulse = YELL_PULSE


# Крик из окна. Он в доме, за стеклом, и на подошедшего орёт столько раз,
# сколько тот стоит рядом, — это единственный житель линии, который вообще
# замечает игрока. Смену лица крик не отменяет и не назначает: пугает не то,
# что сосед орёт, а то, что орущий сосед между двумя криками стал другим.
func _yell(dt: float) -> void:
	if _pulse > 0.0:
		_pulse = maxf(0.0, _pulse - dt)
		if _lamp != null:
			var base := float(_lamp.get_meta("power", 5.0))
			# Вздрогнуло и вернулось: он подошёл к самому стеклу и заслонил лампу.
			_lamp.light_energy = base * (0.35 + 0.65 * (1.0 - _pulse / YELL_PULSE))
	if _yell_cool > 0.0:
		_yell_cool -= dt
		return
	var feet := _feet()
	if Vector2(feet.x, feet.z).distance_to(Vector2(_watch_at.x, _watch_at.z)) > YELL_DIST:
		return
	_yell_cool = _rng.randf_range(YELL_GAP_MIN, YELL_GAP_MAX)
	_yelled += 1
	_pulse = YELL_PULSE
	var beats: Dictionary = (c.get("texts", {}) as Dictionary).get("BEATS", {})
	_shout("shout-window", String(beats.get("shouterBark", "")))
	_emit("watcher-yell", _yelled)


## Сколько раз орал тот, что в окне. Спрашивают тесты — по игре это видно
## только на слух.
func yells() -> int:
	return _yelled


func _apply_face() -> void:
	if _watch_faces.size() < 2:
		return
	var path := String(_watch_faces[_watch_face])
	if path != "":
		actors.set_face(WATCHER, path)


# --------------------------------------------------------------- служебное --

## Смотрит ли игрок сюда. Та же формула, что у chapters._in_view: своя копия
## порога однажды разъехалась бы с той, по которой ставятся мягкие испуги.
func _in_view(p: Vector3) -> bool:
	var r: Variant = c.get("renderer")
	if r == null:
		return false
	var cam: Variant = r.camera
	if not (cam is Camera3D):
		return false
	var eye: Vector3 = (cam as Camera3D).global_position
	var to := p - eye
	var d := to.length()
	if d > VIEW_FAR:
		return false
	if d < 0.001:
		return true
	return (-(cam as Camera3D).global_transform.basis.z).normalized().dot(to / d) > VIEW_COS


func _feet() -> Vector3:
	var ctrl: Variant = c.get("controls")
	return Vector3.ZERO if ctrl == null else ctrl.feet()


func _scares_on() -> bool:
	var f: Variant = c.get("scaresOn")
	return true if not (f is Callable) else bool((f as Callable).call())


func _emit(event: String, payload: Variant = null) -> void:
	var f: Variant = c.get("emit")
	if f is Callable:
		(f as Callable).call(event, payload)

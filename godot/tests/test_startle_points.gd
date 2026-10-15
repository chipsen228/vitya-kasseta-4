# Приёмка испугов по местам (startle.gd::POINTS).
#
# Испуг по месту ломается тише всех прочих механик. Он однократный: если точка
# сработала в стену, игрок не увидел НИЧЕГО и не узнает, что что-то было —
# в отличие от мелькания, которое просто выпадет в другой раз. Флаг при этом
# уже поставлен, и вторая попытка не придёт никогда. Поэтому здесь проверяется
# ровно то, чего в игре не видно:
#
#   · имена не повторяются, вид известен, у pass есть вторая точка;
#   · глава из min существует в GameState.CHAPTERS, зона из from — в site.json;
#   · имя звука существует среди запечённых и оверлейных: опечатка в sfx
#     превращает удар в тишину, и это не отличить от «звук не приехал»;
#   · триггер стоит там, где игрок физически помещается, — иначе точка мертва;
#   · фигура стоит на твёрдом, а не висит в воздухе;
#   · и главное: с позиций ТРИГГЕРА фигуру ВИДНО. У flash и pass это условие
#     срабатывания (луч перекрыт — момент не играет вовсе), поэтому с них
#     спрашивается большинство позиций; window ставится наоборот, пока игрок
#     не смотрит, и ему довольно одной позиции — но не нуля.
#
# Двери на время проверки открыты, как в test_haunt_points и audit_reach:
# нас интересует створ, а не запертость.
#
# Прогон:
#   Godot…_console.exe --headless --path godot --script res://tests/test_startle_points.gd
extends SceneTree

const FACE := 1.596            # высота лица над ногами (actors.gd meta face_y)
const EYE := 1.62              # глаза игрока над полом
const R := 0.32                # капсула фигуры и игрока
const HEAD_CLEAR := 1.40
const GRID := 0.30             # шаг сетки позиций внутри триггера
const HARD_SHARE := 0.5        # flash/pass: доля позиций, с которых обязано быть видно
const KINDS := ["flash", "window", "pass", "sign"]

var _col: CollisionWorld = null
var _sounds: Dictionary = {}


func _initialize() -> void:
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	_col = col
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)

	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)
	props.rebuild_collision(col)
	for b: Dictionary in built.get("blockers", []):
		col.set_blocker_active(String(b["id"]), false)

	_load_sounds()
	var zones: Dictionary = {}
	for z: Dictionary in (GameData.site()["ZONES"] as Array):
		zones[String(z["id"])] = true

	var fails := 0
	var seen: Dictionary = {}
	for p: Dictionary in Startle.POINTS:
		fails += _check(p, zones, seen)

	props.dispose()
	root.free()
	if fails == 0:
		print("test_startle_points: PASS (%d точек)" % Startle.POINTS.size())
		quit(0)
	else:
		printerr("test_startle_points: FAIL (%d расхождений)" % fails)
		quit(1)


func _check(p: Dictionary, zones: Dictionary, seen: Dictionary) -> int:
	var id := String(p["id"])
	var bad := 0
	if seen.has(id):
		printerr("%s: имя точки встречается дважды" % id)
		bad += 1
	seen[id] = true

	var kind := String(p.get("kind", "flash"))
	if not KINDS.has(kind):
		printerr("%s: неизвестный вид «%s»" % [id, kind])
		bad += 1
	if kind == "pass" and not p.has("to"):
		printerr("%s: у прохода нет второй точки «to» — идти некуда" % id)
		bad += 1
	if not GameState.CHAPTERS.has(String(p.get("min", "arrive"))):
		printerr("%s: главы «%s» нет в GameState.CHAPTERS" % [id, String(p.get("min", ""))])
		bad += 1
	var from := String(p.get("from", ""))
	if from != "" and not zones.has(from):
		printerr("%s: зоны «%s» нет в site.json ZONES — переход не поймается" % [id, from])
		bad += 1
	var snd := String(p.get("sfx", ""))
	if snd != "" and not _sounds.has(snd):
		printerr("%s: звука «%s» нет ни среди запечённых, ни в audio/sfx" % [id, snd])
		bad += 1

	# Триггер: игрок туда помещается?
	var at: Array = p["at"]
	var feet := Vector3(float(at[0]), float(at[1]), float(at[2]))
	var stuck := _depth(feet)
	if stuck > 0.35:
		printerr("%s: триггер утоплен в геометрию на %.2f м — стоять там негде"
			% [id, stuck])
		bad += 1

	if kind == "sign":
		print("%-16s %-7s знак, звук %s" % [id, kind, snd if snd != "" else "—"])
		return bad

	var pp: Array = p["pos"]
	var fig := Vector3(float(pp[0]), float(pp[1]), float(pp[2]))
	# У прохода целимся в СЕРЕДИНУ пути. Он и должен быть виден: створ фигура
	# пересекает там, а на краях отрезка её честно закрывает стена.
	var aim := fig
	if kind == "pass" and p.has("to"):
		var t: Array = p["to"]
		aim = fig.lerp(Vector3(float(t[0]), float(t[1]), float(t[2])), 0.5)
	var face := aim + Vector3(0.0, FACE, 0.0)

	# Фигура на твёрдом? Луч вниз от щиколотки: висящая в воздухе фигура —
	# это опечатка в y, и в игре она читается как левитация. Марши из этой
	# проверки выпадают: ступеней в статике нет вовсе (замерено — под маршем
	# сразу пол первого этажа), поэтому лестничные точки сверяются с профилем
	# самой лестницы из site.json, и сверяются строже: там ловится промах
	# по высоте ступени, которого луч не увидел бы.
	#
	# ФАЗА 14. К статике добавлен четвёртый набор, и это не послабление, а
	# исправление: с фазы 11 пол под ногами далеко не всегда статика. Пол
	# бани, погреба, сельпо, второго этажа красного дома и вся земля околицы
	# лежат в SET_OVERLAY — иначе выросло бы 311/4/83. Проверяя только
	# статику, тест объявлял бы левитацией любую фигуру севернее z = -24,
	# то есть весь мир этой фазы, и одновременно пропускал бы настоящую
	# опечатку в y — потому что «пола нет» стало бы нормой.
	var down := Threat.ray_static(_col, fig.x, fig.y + 0.25, fig.z,
		0.0, -1.0, 0.0, 0.9)
	if down == INF:
		var soft := _col.ray_down(fig.x, fig.y + 0.25, fig.z, CollisionWorld.MASK_OVERLAY)
		if not soft.is_empty() and fig.y + 0.25 - float(soft.get("y", -99.0)) <= 0.9:
			down = fig.y + 0.25 - float(soft["y"])
	if down == INF and not _on_stairs(fig):
		printerr("%s: под ногами фигуры (%.2f, %.2f, %.2f) нет ни пола на 0.9 м, "
			% [id, fig.x, fig.y, fig.z] + "ни ступени ни одного марша")
		bad += 1

	# Видимость с сетки. Обычно смотрим с самого триггера, но у window бывает
	# иначе: фигура ставится, ПОКА ИГРОК ЕЁ НЕ ВИДИТ, — «зашёл, а коридор уже
	# занят». Такой точке триггер стоит по эту сторону стены, и место, откуда
	# на неё посмотрят, объявляется отдельно полем seen_from.
	var r := float(p.get("r", 1.2))
	var eye_at := feet
	if p.has("seen_from"):
		var sf: Array = p["seen_from"]
		eye_at = Vector3(float(sf[0]), float(sf[1]), float(sf[2]))
		r = 0.9
	var see_through := bool(p.get("see_through", false))
	var vis := 0
	var tried := 0
	var near := INF
	var far := 0.0
	var x := eye_at.x - r
	while x <= eye_at.x + r:
		var z := eye_at.z - r
		while z <= eye_at.z + r:
			if Vector2(x - eye_at.x, z - eye_at.z).length() <= r:
				var eye := Vector3(x, eye_at.y + EYE, z)
				var to := face - eye
				var d := to.length()
				if d > 0.5:
					tried += 1
					near = minf(near, d)
					far = maxf(far, d)
					if see_through or _clear(eye, to / d, d):
						vis += 1
			z += GRID
		x += GRID

	if tried == 0:
		printerr("%s: сетка триггера пуста — радиус %.2f слишком мал" % [id, r])
		bad += 1
	elif vis == 0:
		printerr("%s: фигуру не видно ни с одной из %d позиций триггера" % [id, tried])
		bad += 1
	elif (kind == "flash" or kind == "pass") \
			and float(vis) / float(tried) < HARD_SHARE:
		printerr("%s: удар виден только с %d позиций из %d — с остальных он "
			% [id, vis, tried] + "уйдёт в стену и точка сгорит впустую")
		bad += 1

	print("%-16s %-7s видно с %3d из %3d, %.1f..%.1f м%s"
		% [id, kind, vis, tried, near if near < INF else 0.0, far,
			"" if stuck <= 0.0 else ", триггер задет на %.2f м" % stuck])
	return bad


## Стоит ли фигура на ступени объявленного марша. Проверяется не «попала
## в коробку», а ПРОФИЛЬ: высота ступени под этой точкой считается из from,
## dir, run и rise, и промах больше 0.20 м — ошибка. Марш без from (площадка)
## пропускается: у неё своя горизонтальная плита, и её ловит обычный луч.
func _on_stairs(fig: Vector3) -> bool:
	for s: Dictionary in (GameData.site()["STAIRS"] as Array):
		if not s.has("from"):
			continue
		var f: Array = s["from"]
		var d: Array = s["dir"]
		var run := float(s["run"])
		var rise := float(s["rise"])
		var half := float(s.get("width", 1.0)) * 0.5
		var along := (fig.z - float(f[2])) * float(d[1]) + (fig.x - float(f[0])) * float(d[0])
		var side := (fig.x - float(f[0])) * float(d[1]) - (fig.z - float(f[2])) * float(d[0])
		if along < 0.0 or along > run * float(s["steps"]) or absf(side) > half:
			continue
		if absf(fig.y - (float(f[1]) + along / run * rise)) <= 0.20:
			return true
	return false


## Насколько капсула игрока задевает мир в точке триггера.
func _depth(feet: Vector3) -> float:
	var hit := _col.capsule_hit_d(feet.x, feet.y + R + 0.02, feet.z,
		feet.x, feet.y + HEAD_CLEAR, feet.z, R,
		CollisionWorld.MASK_STATIC | CollisionWorld.MASK_PROPS)
	return 0.0 if hit.is_empty() else float(hit.get("depth", 0.0))


func _clear(from: Vector3, dir: Vector3, l: float) -> bool:
	var t := Threat.ray_static(_col, from.x, from.y, from.z, dir.x, dir.y, dir.z, l)
	return t == INF or t > l - 0.2


## Имена звуков, которые игра действительно умеет сыграть: запечённые
## one_shots плюс всё, что лежит оверлеем в audio/sfx. Варианты одного звука
## лежат файлами «имя-1.wav»…«имя-4.wav» — числовой хвост снимается.
func _load_sounds() -> void:
	var f := FileAccess.open("res://audio/baked/manifest.json", FileAccess.READ)
	if f != null:
		var j: Variant = JSON.parse_string(f.get_as_text())
		if j is Dictionary:
			for k: String in ((j as Dictionary).get("one_shots", {}) as Dictionary):
				_sounds[k] = true
	var dir := DirAccess.open("res://audio/sfx")
	if dir == null:
		return
	for name: String in dir.get_files():
		if not name.ends_with(".wav"):
			continue
		var base := name.substr(0, name.length() - 4)
		_sounds[base] = true
		var cut := base.rfind("-")
		if cut > 0 and base.substr(cut + 1).is_valid_int():
			_sounds[base.substr(0, cut)] = true

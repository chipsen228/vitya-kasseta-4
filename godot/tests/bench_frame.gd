# Замер кадра по частям (фаза 9). Счётчика времени в тестах не было вовсе:
# «подтормаживает» проверялось глазами, а глаза не отличают тридцать
# миллисекунд на луче от тридцати на синтезе звука.
#
# ЧТО МЕРЯЕТСЯ И ПОЧЕМУ ИМЕННО ЭТО.
#
# 1. Луч по статике. Interact.find() стреляет до пяти лучей в кадр, каждый —
#    линейный перебор всех 311 коробок мира. Пространственный индекс у
#    CollisionWorld есть, а у луча его нет: это ~1555 проверок плит на GDScript
#    каждый кадр, и ни одна из них не нужна, когда предмет и стена в разных
#    концах дома.
# 2. Сам поиск цели: 135 дескрипторов, сортировка и до пяти проверок видимости.
# 3. Синтез звука. audio.tone/noise крутят до 35 280 итераций с pow/sin
#    В ОДНОМ КАДРЕ. Это не «медленно вообще», это одиночный провал — ровно тот
#    рывок, который чувствуется на склейке кассеты.
#
# Числа печатаются в миллисекундах на вызов и на кадр. Тест НИЧЕГО НЕ ВАЛИТ
# по умолчанию: это измеритель, а не приёмка. Порог включается флагом --strict,
# чтобы будущая правка не вернула кадр обратно втихую.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/bench_frame.gd
extends SceneTree

const RAYS := 10000
const FINDS := 5000
const TONES := 40

# Потолки для --strict. Взяты с запасом в полтора раза от замера на машине
# разработки: тест обязан ловить регресс в разы, а не дрожание планировщика.
const LIMIT_RAY_US := 60.0        # микросекунд на один луч
const LIMIT_FIND_US := 900.0      # микросекунд на один find()
const LIMIT_TONE_MS := 6.0        # миллисекунд на один синтез


func _initialize() -> void:
	_run()


# Дерево нужно по-настоящему: Camera3D без него отдаёт единичный
# global_transform и ругается на каждый кадр, а Interact.find() меряется
# именно по камере. Отсюда await первого кадра — как в smoke_boot.gd.
func _run() -> void:
	var strict := OS.get_cmdline_user_args().has("--strict")

	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	self.root.add_child(root)
	await process_frame
	var built := WorldBuilder.build(root, mats, col)
	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(root, pdata["PROPS"], col)
	props.build_dynamic(pdata.get("DYNAMIC_PROPS", []))
	props.rebuild_collision(col)

	print("мир: статика %d, реквизит %d, оверлей %d"
		% [col.box_count(CollisionWorld.SET_STATIC),
			col.box_count(CollisionWorld.SET_PROPS),
			col.box_count(CollisionWorld.SET_OVERLAY)])

	var fails := 0
	fails += _bench_ray(col, strict)
	fails += _bench_find(root, col, props, built, strict)
	fails += _bench_tone(strict)

	props.dispose()
	root.queue_free()
	if fails == 0:
		print("bench_frame: готово")
		quit(0)
		return
	printerr("bench_frame: FAIL (%d порогов превышено)" % fails)
	quit(1)


# ---------- луч по статике ----------

# Точки берутся по всему дому детерминированно (шаг по простому числу), а не
# случайно: два прогона обязаны мерить одно и то же, иначе «стало быстрее»
# нельзя отличить от «повезло с выборкой».
func _bench_ray(col: CollisionWorld, strict: bool) -> int:
	var boxes := Threat.static_boxes(col)

	# Луч деда — как есть, без отсева. Мерится ради сравнения: ai.gd
	# неприкосновенен, и его число здесь — точка отсчёта, а не цель.
	var t0 := Time.get_ticks_usec()
	var sink := 0.0
	for i in RAYS:
		var a := float(i) * 0.61803398875
		var r := Threat.ray_boxes(boxes,
			-5.0 + fmod(a * 9.0, 9.0), 0.45 + fmod(a * 1.3, 1.6), 7.0 + fmod(a * 8.0, 8.0),
			cos(a * 6.2831), -0.1, sin(a * 6.2831), 6.0)
		if r < INF:
			sink += r
	var us := float(Time.get_ticks_usec() - t0)
	var per := us / float(RAYS)
	print("луч ai.gd (без отсева): %.1f мкс/вызов (%d коробок, сумма %.1f)"
		% [per, boxes.size() / 6, sink])

	# Луч interact.gd — с отсевом по объемлющей коробке отрезка. Именно он
	# стреляет до пяти раз в кадр.
	#
	# Суммы двух замеров НЕ обязаны совпадать и не совпадают: ai.gd принимает
	# направление как есть (t выходит в единицах этого вектора), а interact.gd
	# нормированное — как его и даёт visible(). Сравнивать здесь надо время,
	# а не сумму; сама сумма печатается, чтобы компилятор не выкинул цикл.
	t0 = Time.get_ticks_usec()
	var sink2 := 0.0
	for i in RAYS:
		var a := float(i) * 0.61803398875
		var from := Vector3(-5.0 + fmod(a * 9.0, 9.0), 0.45 + fmod(a * 1.3, 1.6),
			7.0 + fmod(a * 8.0, 8.0))
		var dir := Vector3(cos(a * 6.2831), -0.1, sin(a * 6.2831)).normalized()
		var r := Interact._ray_static(col, from, dir, 6.0)
		if r < INF:
			sink2 += r
	var us2 := float(Time.get_ticks_usec() - t0)
	var per2 := us2 / float(RAYS)
	print("луч interact.gd (с отсевом): %.1f мкс/вызов (сумма %.1f)" % [per2, sink2])
	# Пять лучей в кадр — столько их и стреляет Interact.find() в худшем случае.
	print("            -> %.2f мс на кадр при пяти лучах" % (per2 * 5.0 / 1000.0))
	if strict and per2 > LIMIT_RAY_US:
		printerr("  порог %.1f мкс превышен" % LIMIT_RAY_US)
		return 1
	return 0


# ---------- поиск цели ----------

func _bench_find(root: Node3D, col: CollisionWorld, props: Props,
		built: Dictionary, strict: bool) -> int:
	var it := Interact.new()
	it.occluder = col
	# Мир в ctx — ради точек фазы 12: их координаты живут в built.village
	# и built.home, и на пустом ctx замер шёл бы по укороченному списку.
	Interact.registerObjects(it, {"world": built})
	it.addLookTargets(props)

	var cam := Camera3D.new()
	root.add_child(cam)
	var st := GameState.new()
	st.chapter = "dark"

	var t0 := Time.get_ticks_usec()
	for i in FINDS:
		var a := float(i) * 0.61803398875
		# Камера ходит по дому и крутится: кэш видимости обязан мериться
		# в движении, иначе он покажет ноль там, где в игре его нет.
		cam.position = Vector3(-4.0 + fmod(a * 8.0, 8.0), 1.6 + fmod(a * 0.7, 1.4),
			7.0 + fmod(a * 9.0, 9.0))
		cam.rotation = Vector3(0.0, fmod(a * 6.0, TAU), 0.0)
		it.find(cam, st)
	var us := float(Time.get_ticks_usec() - t0)
	var per := us / float(FINDS)
	print("Interact.find: %.1f мкс/вызов (%d точек) -> %.2f мс на кадр"
		% [per, it.list.size(), per / 1000.0])
	cam.queue_free()
	if strict and per > LIMIT_FIND_US:
		printerr("  порог %.1f мкс превышен" % LIMIT_FIND_US)
		return 1
	return 0


# ---------- синтез звука ----------

# GameAudio — Node и без дерева не заводится; шину звука в headless создавать
# незачем, меряем ровно генерацию буфера.
func _bench_tone(strict: bool) -> int:
	var audio := GameAudio.new()
	root.add_child(audio)
	var t0 := Time.get_ticks_usec()
	for i in TONES:
		audio.tone({"freq": 220.0 + i, "to": 140.0, "dur": 0.6,
			"gain": 0.0, "type": "sawtooth", "attack": 0.05})
	var us := float(Time.get_ticks_usec() - t0)
	var per := us / float(TONES) / 1000.0
	print("audio.tone: %.2f мс на вызов (в кадре — весь целиком)" % per)
	audio.queue_free()
	if strict and per > LIMIT_TONE_MS:
		printerr("  порог %.1f мс превышен" % LIMIT_TONE_MS)
		return 1
	return 0

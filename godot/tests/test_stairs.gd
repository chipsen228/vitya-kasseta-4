# Приёмка лестницы: игрок ходит по маршам сам, а результат меряется в метрах.
#
# Пётр сказал «заходить на лестницу неудобно» — здесь это перестаёт быть
# ощущением. Собирается настоящий мир (те же коробки CollisionWorld, что у
# паритета), в него ставится настоящий Player, ему зажимается клавиша вперёд,
# и через N секунд смотрим, куда он приехал по высоте.
#
# Ловится ровно то, что чинит фаза 7:
#   · вход на марш сбоку — раньше кромка борта пандуса читалась движком как
#     стена (нормаль 67.2° при floor_max_angle 65°), и игрок в неё упирался;
#   · выход на площадку и на мансарду — рабочая грань пандуса обрывается
#     на 7.6 см ниже, и без шага вверх капсула вставала в кромку.
#
# Мир строится напрямую, без main.tscn: главы, дед и хоррор-слой на лестнице
# только мешали бы, а нужен здесь один игрок и одна геометрия.
#
# Прогон: Godot…_console.exe --headless --path godot --script res://tests/test_stairs.gd
extends SceneTree

const DT := 1.0 / 60.0
const SETTLE := 20             # кадров «встать на пол» перед стартом
# Куда обязан доставать заход сбоку. 10.10 — это борт пандуса в 23 см,
# то есть ровно шаг вверх STEP_UP за вычетом запаса на скруглении капсулы.
const BAND_MIN := 10.10

# from — куда ставим ноги, yaw — куда смотрим (в эту же сторону идём вперёд).
# want — что обязано случиться с высотой ног к концу отрезка.
const ROUTES := [
	{
		"name": "низ марша в лоб",
		"from": [-5.05, 0.45, 9.72], "yaw": PI, "sec": 6.0,
		"want": "up", "y": 2.00,
	},
	{
		"name": "вход на марш сбоку, с востока",
		"from": [-4.15, 0.45, 9.95], "yaw": PI * 0.5, "sec": 2.5,
		"want": "up", "y": 0.60,
	},
	{
		"name": "вход на марш сбоку, от прихожей наискось",
		"from": [-4.30, 0.45, 9.80], "yaw": PI * 0.72, "sec": 4.0,
		"want": "up", "y": 0.75,
	},
	{
		"name": "верхний марш на мансарду",
		"from": [-5.00, 2.06, 12.68], "yaw": PI * 1.5, "sec": 6.0,
		"want": "up", "y": 3.24,
	},
	{
		"name": "спуск с мансарды спиной вперёд",
		"from": [-2.40, 3.30, 12.68], "yaw": PI * 0.5, "sec": 6.0,
		"want": "down", "y": 2.20,
	},
	{
		# Внизу марш упирается в стену веранды (z = 9.6): капсула радиусом 0.30
		# встаёт на 9.95, ещё на пандусе. Это не дефект, а планировка — сойти
		# с марша можно вбок, что и проверяет следующий отрезок.
		"name": "спуск нижнего марша",
		"from": [-5.05, 2.05, 12.30], "yaw": 0.0, "sec": 6.0,
		"want": "down", "y": 0.70,
	},
	{
		"name": "сойти с марша в прихожую",
		"from": [-5.05, 0.64, 9.95], "yaw": PI * 1.5, "sec": 3.0,
		"want": "down", "y": 0.50,
	},
]


func _initialize() -> void:
	_run()


func _run() -> void:
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	world.name = "World"
	root.add_child(world)
	WorldBuilder.build(world, mats, col)

	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(world, pdata["PROPS"], col)

	var physics := PhysicsBodies.new()
	physics.name = "PhysicsBodies"
	world.add_child(physics)
	physics.build(col)

	var player := Player.new()
	player.name = "Player"
	world.add_child(player)
	player.enabled = true

	# Телам нужен кадр, чтобы приехать в физический сервер: без него первый же
	# test_move отвечает «пусто» и игрок валится сквозь дом.
	for i in 4:
		await process_frame

	var band := await _entry_band(player)
	print("полоса захода на марш сбоку: до z = %.2f (борт пандуса %.2f м над полом)"
		% [band, (band - 9.75) * 0.178125 / 0.27])
	var fails := 0
	if band < BAND_MIN:
		printerr("заход сбоку работает только до z = %.2f, надо хотя бы %.2f" % [band, BAND_MIN])
		fails += 1

	for r: Dictionary in ROUTES:
		var res := await _walk(player, r)
		var ok: bool = (res["y1"] >= float(r["y"])) if r["want"] == "up" \
			else (res["y1"] <= float(r["y"]))
		var mark := "ok  " if ok else "ПЛОХО"
		var e: Vector3 = res["end"]
		print("%s %-38s %.2f -> %.2f (надо %s %.2f), путь %.2f м, встал %.2f %.2f %.2f"
			% [mark, r["name"], res["y0"], res["y1"], r["want"], float(r["y"]), res["dist"],
				e.x, e.y, e.z])
		if not ok:
			fails += 1

	props.dispose()
	if fails == 0:
		print("test_stairs: PASS")
		quit(0)
	else:
		printerr("test_stairs: FAIL (%d маршрутов из %d)" % [fails, ROUTES.size()])
		quit(1)


## Докуда по маршу можно зайти сбоку. Пандус — единственный коллайдер лестницы,
## и с востока его борт растёт от нуля вверх; выше какой-то отметки на него уже
## не встать. Эта отметка и есть «удобно ли заходить», выраженная числом.
##
## До фазы 7 граница стояла на z = 10.01 (борт 17 см): дальше капсула касалась
## верхнего ребра борта, движок считал нормаль 67.2° стеной при пороге 65°,
## и игрок скользил вдоль марша вместо того, чтобы на него встать.
func _entry_band(player: Player) -> float:
	var best := 0.0
	var map := ""
	var z := 9.75
	while z < 10.76:
		var r := {"from": [-4.20, 0.45, z], "yaw": PI * 0.5, "sec": 1.6}
		var res := await _walk(player, r)
		var gain: float = res["y1"] - res["y0"]
		if gain > 0.05:
			best = z
		map += "%.2f:%+.2f  " % [z, gain]
		z += 0.05
	print("подъём по z: ", map)
	return best


func _walk(player: Player, r: Dictionary) -> Dictionary:
	var f: Array = r["from"]
	player.place(float(f[0]), float(f[1]), float(f[2]), float(r["yaw"]))
	Input.action_release("move_forward")
	# Дать капсуле встать на пол: place() обнуляет опору, и первый кадр всегда
	# уходит в падение.
	for i in SETTLE:
		player.update(DT)
	var start := player.feet()

	Input.action_press("move_forward")
	var steps := int(float(r["sec"]) / DT)
	var dist := 0.0
	var prev := player.feet()
	for i in steps:
		player.update(DT)
		var now := player.feet()
		dist += Vector2(now.x - prev.x, now.z - prev.z).length()
		prev = now
		# Кадр движка нужен изредка: move_and_slide работает сразу, а вот
		# запросы формы кэшируются на кадр.
		if (i % 6) == 0:
			await process_frame
	Input.action_release("move_forward")

	var end := player.feet()
	return {"y0": start.y, "y1": end.y, "dist": dist, "end": end}

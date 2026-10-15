# Метрика ряби в темноте (lead, фаза 8).
#
# Не тест: ничего не проверяет и всегда возвращает 0. Это измерительный
# инструмент к пункту «в темноте с фонарём рябит» — ровно такой же, каким
# в фазе 7 подбиралась экспозиция. Мерить глазами тут нельзя: ACES тогда
# повёл себя противоположно ожиданию, и рябь ведёт себя так же.
#
# Что меряем: средний модуль разности двух ПОДРЯД идущих кадров в тёмной
# области. Рябь по определению временная — если картинка стоит, разность
# ноль. Тёмная область берётся по яркости первого кадра пары (порог DARK),
# потому что весь спор идёт про тени, а не про пятно фонаря.
#
# Печатается три числа на точку: средний |Δ| по тёмному (×1000 кодов из 255),
# доля пикселей с |Δ| больше кода и средняя яркость тёмной области — последнее
# чтобы отличить «рябь ушла» от «картинка стала чёрной».
#
# Запуск (ОКОННЫЙ, без --headless — в Compatibility без окна SubViewport'ы
# не рисуются вовсе):
#   Godot…_console.exe --path godot --resolution 1920x1080 \
#       --script res://tests/ripple.gd ++ <папка для PNG или "" >
extends SceneTree

const BOOT_FRAMES := 900
const SETTLE_FRAMES := 30
const PAIRS := 12              # сколько пар кадров усреднить на точку
const DARK := 0.34             # порог «это тень», в долях от 1.0

# Четыре ночные точки с фонарём. Двор, комната первого этажа, лестничный
# проём и подпол: разные материалы, разная дальность и разный угол падения
# луча — акне теней вылезает не везде одинаково.
const POINTS := [
	{"name": "н1-двор-у-сарая", "pos": [4.6, 0.0, 6.2], "yaw": PI * 1.15, "pitch": -0.06},
	{"name": "н2-кухня", "pos": [-0.4, 0.45, 11.4], "yaw": PI, "pitch": -0.02},
	{"name": "н3-лестничный-проём", "pos": [-3.9, 0.45, 10.4], "yaw": PI * 1.5, "pitch": 0.06},
	{"name": "н4-подпол", "pos": [-3.0, -1.55, 10.5], "yaw": PI, "pitch": 0.0},
]


func _initialize() -> void:
	_run()


func _run() -> void:
	var extra := OS.get_cmdline_user_args()
	var out := ""
	if extra.size() > 0 and String(extra[0]) != "":
		out = ProjectSettings.globalize_path(String(extra[0])) \
			if String(extra[0]).begins_with("res://") else String(extra[0])
		DirAccess.make_dir_recursive_absolute(out)

	var scene: PackedScene = load("res://src/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)

	var waited := 0
	while main.get("chapters") == null and waited < BOOT_FRAMES:
		await process_frame
		waited += 1
	if main.get("chapters") == null:
		printerr("ripple: боут не завершился за %d кадров" % BOOT_FRAMES)
		quit(1)
		return

	var ui: Overlays = main.get("ui")
	var player: Player = main.get("player")
	var lights: LightRig = main.get("lights")
	var chain: RenderChain = main.get("render_chain")
	var flash: Flashlight = main.get("flashlight")

	main.call("_start_game")
	for i in 90:
		if ui.card.open:
			ui.advanceCard()
		await process_frame
	player.release_lock()
	var threat: Variant = main.get("threat")
	if threat != null:
		threat.speedScale = 0.0

	# Ночь, весь свет выключен, фонарь в руке и горит: ровно та ситуация,
	# в которой Пётр видит рябь.
	lights.powerOn = false
	lights.night = 1.0
	for id: String in lights.state.keys():
		lights.setLamp(id, false)
	flash.give()
	flash.on = true
	flash.battery = 100.0

	var total := 0.0
	for p: Dictionary in POINTS:
		var at: Array = p["pos"]
		for i in SETTLE_FRAMES:
			player.place(float(at[0]), float(at[1]), float(at[2]), float(p["yaw"]))
			player.pitch = float(p["pitch"])
			player.pitch_target = float(p["pitch"])
			flash.battery = 100.0
			await process_frame

		var sum_d := 0.0
		var sum_l := 0.0
		var hot := 0.0
		var n := 0.0
		var prev: Image = null
		var shot: Image = null
		for k in PAIRS * 2:
			await process_frame
			await RenderingServer.frame_post_draw
			var img: Image = chain.post_view.get_texture().get_image()
			if img == null:
				continue
			if shot == null:
				shot = img
			if prev != null:
				var r := _diff(prev, img)
				sum_d += float(r["sum"])
				sum_l += float(r["lum"])
				hot += float(r["hot"])
				n += float(r["n"])
			prev = img

		if n > 0.0:
			print("%s: |Δ| %.2f кода из 255, шумных пикселей %.1f %%, яркость тени %.1f"
				% [p["name"], sum_d / n * 255.0, hot / n * 100.0, sum_l / n * 255.0])
			total += sum_d / n * 255.0
		else:
			print("%s: кадров не получено" % p["name"])
		if out != "" and shot != null:
			shot.save_png(out.path_join("%s.png" % p["name"]))

	print("ripple: средняя рябь по четырём точкам %.2f кода из 255" % (total / POINTS.size()))
	quit(0)


## Разность пары кадров по тёмным пикселям первого из них.
func _diff(a: Image, b: Image) -> Dictionary:
	var w := a.get_width()
	var h := a.get_height()
	var sum := 0.0
	var lum_sum := 0.0
	var hot := 0.0
	var n := 0.0
	# Шаг 2 по обеим осям: 130 тысяч пикселей на кадр в GDScript — это секунды.
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var ca := a.get_pixel(x, y)
			var la := ca.r * 0.299 + ca.g * 0.587 + ca.b * 0.114
			if la < DARK:
				var cb := b.get_pixel(x, y)
				var d := (absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)) / 3.0
				sum += d
				lum_sum += la
				if d > 1.0 / 255.0:
					hot += 1.0
				n += 1.0
			x += 2
		y += 2
	return {"sum": sum, "lum": lum_sum, "hot": hot, "n": n}

# Адаптивный UI: безопасные поля, ограничения ширины и перенос сетки
# проверяются без рендера на основных форматах и на низком окне.
extends SceneTree

const SIZES := [
	Vector2(1280, 720), Vector2(1920, 1080), Vector2(1024, 768),
	Vector2(2560, 1080), Vector2(640, 360),
]


func _initialize() -> void:
	_run()


func _run() -> void:
	var errs: Array[String] = []
	var ui := Overlays.new()
	root.add_child(ui)
	await process_frame
	var ui_root: Control = ui.get("_root")
	var image := Image.create(800, 600, false, Image.FORMAT_RGBA8)
	ui.openPhoto(ImageTexture.create_from_image(image), "Подпись к фотографии")
	ui.setReaderTitle("ДНЕВНИК")
	ui.openReader("", "Длинная страница\n".repeat(36))

	for size: Vector2 in SIZES:
		ui_root.size = size
		ui.call("_layout")
		_check_size(ui, size, errs)

	ui.closePhoto()
	ui.closeReader()
	ui.free()
	if errs.is_empty():
		print("test_adaptive_ui: PASS")
		quit(0)
		return
	print("test_adaptive_ui: FAIL (%d)" % errs.size())
	for e: String in errs:
		print("  - ", e)
	quit(1)


func _check_size(ui: Overlays, size: Vector2, errs: Array[String]) -> void:
	var safe := Vector2(maxf(1.0, size.x - 48.0), maxf(1.0, size.y - 48.0))
	for key: String in ["_pause_scroll", "_reader_scroll", "_photo_scroll"]:
		var scroll: ScrollContainer = ui.get(key)
		if not scroll.position.is_equal_approx(Vector2(24, 24)) or not scroll.size.is_equal_approx(safe):
			errs.append("%s при %s: rect %s %s, ожидался safe rect" %
				[key, size, scroll.position, scroll.size])

	var paper: PanelContainer = ui.get("_paper")
	var pause_card: VBoxContainer = ui.get("_pause_card")
	var caption: Label = ui.get("_photo_caption")
	for row: Array in [["paper", paper.custom_minimum_size.x],
			["pause", pause_card.custom_minimum_size.x], ["caption", caption.custom_minimum_size.x]]:
		if float(row[1]) > safe.x + 0.01:
			errs.append("%s шире safe area при %s: %.1f > %.1f" % [row[0], size, row[1], safe.x])

	var grid: GridContainer = ui.get("_start_grid")
	var want_cols := 1 if safe.x < 520.0 else (2 if safe.x < 660.0 else 3)
	if grid.columns != want_cols:
		errs.append("сетка при %s имеет %d колонок вместо %d" % [size, grid.columns, want_cols])

	var photo_rect: TextureRect = ui.get("_photo_rect")
	if photo_rect.custom_minimum_size.x > safe.x - 28.0 + 0.01:
		errs.append("фото не ужалось при %s: %.1f" % [size, photo_rect.custom_minimum_size.x])
	if size == Vector2(640, 360):
		for row: Array in [["pause", (ui.get("_pause_card") as Control).get_combined_minimum_size().y],
				["reader", (ui.get("_paper") as Control).get_combined_minimum_size().y],
				["photo", (ui.get("_photo_col") as Control).get_combined_minimum_size().y]]:
			if float(row[1]) <= safe.y:
				errs.append("%s не создаёт прокручиваемое содержимое на низком экране" % row[0])

	var held: Control = ui.get("_held_readout")
	var held_rect := Rect2(held.position, held.size)
	var safe_rect := Rect2(Vector2(24, 24), safe)
	if not safe_rect.encloses(held_rect):
		errs.append("held-item подпись вышла из safe area при %s: %s" % [size, held_rect])

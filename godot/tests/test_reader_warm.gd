# CPU проверяет настоящий Overlays и восстановление; GPU-прогрев доказывает draw backend.
extends SceneTree

class FakeAudio extends GameAudio:
	var calls := 0
	func sfx(_sound: String, _gain := 1.0, _bus := &"") -> bool:
		calls += 1
		return true

var errors: Array[String] = []
var checks := 0
var callback_calls := 0
var observed_warm_frames := 0
var completed := false

func _initialize() -> void:
	create_timer(20.0).timeout.connect(func() -> void:
		if not completed:
			printerr("test_reader_warm: FAIL (regression aborted or timed out)")
			quit(1))
	_run.call_deferred()

func _run() -> void:
	var ui := Overlays.new()
	root.add_child(ui)
	var audio := FakeAudio.new()
	ui.audio = audio
	var callback := func() -> void: callback_calls += 1
	ui.reader.open = true
	ui.reader.title = "Сохранённый заголовок"
	ui.reader.pages = ["первая сохранённая страница", "вторая сохранённая страница"]
	ui.reader.index = 1
	ui.reader.onClose = callback
	ui._reader_title.text = "Независимый видимый заголовок"
	ui._reader_body.text = "Сохранённая длинная строка бумаги для проверки прокрутки.\n".repeat(90)
	ui._reader_page.text = "7 / 9"
	ui._reader_screen.visible = true
	ui._reader_screen.z_index = 29
	ui._load.visible = false
	ui._load.z_index = 17
	ui._load.get_node("Back").color = Color(0.2, 0.3, 0.4, 0.42)
	ui._paper.custom_minimum_size = Vector2(613, 157)
	ui._tape_mode = true
	ui._hud_on = true
	ui._hud.visible = false
	ui._pause.visible = true
	ui._start.visible = false
	for _i in 8: await process_frame
	ui._reader_scroll.scroll_vertical = 137
	await process_frame
	await process_frame
	var before := _snapshot(ui)
	await process_frame
	await process_frame
	_check(_snapshot(ui) == before, "fixture was not stable before warming")
	var observer := func() -> void:
		if not ui._reader_warming: return
		observed_warm_frames += 1
		_check(ui._load.visible and ui._load.z_index > ui._reader_screen.z_index, "paper was not covered by raised Load")
		_check((ui._load.get_node("Back") as ColorRect).color.a == 1.0, "warm Load background was translucent")
		_check(ui.reader.title == "Сохранённый заголовок" and ui.reader.index == 1 and ui.reader.onClose == callback,
			"warming changed live ReaderState/callback")
		_check(callback_calls == 0 and audio.calls == 0, "warming invoked callback or paper audio")
	process_frame.connect(observer)
	var definitions := {
		"decor-snt-entry-notice": {"kind": "notice", "title": "СНТ «ВОСХОД»", "pages": ["Проезд оставлять свободным. Калитки за собой прикрывать."]},
		"decor-board-notice": {"kind": "notice", "title": "ПРАВЛЕНИЕ", "pages": ["Правление СНТ\n\nРемонт настила. Председатель. 11.08.2003"]},
		"decor-club-notice": {"kind": "notice", "title": "КЛУБ", "pages": ["Объявление\n\nМешки складывать у въезда. Ключ сдавать в правление."]},
		"decor-gate-p02": {"kind": "gate", "title": "НЕ РИСОВАТЬ", "pages": ["не записка"]}}
	var proof: Dictionary = await ui.warm_reader_pages(definitions)
	_check(_snapshot(ui) == before, "first warm did not preserve non-default visible/logical Reader and modes")
	await process_frame
	await process_frame
	if _snapshot(ui) != before: _layout_diff(before, _snapshot(ui))
	_check(_snapshot(ui) == before, "restored Reader layout drifted on subsequent frames")
	_check(proof["state_restored"] and proof["reader_unchanged"] and proof["mode_unchanged"] and proof["errors"].is_empty(), "restoration proof failed")
	_check(proof["pages"].size() == 3, "notices were omitted or non-notice was warmed")
	_check(proof["pages"][0]["id"] == "decor-board-notice" and proof["pages"][1]["id"] == "decor-club-notice" \
		and proof["pages"][2]["id"] == "decor-snt-entry-notice", "source ID ordering/provenance mismatch")
	for row: Dictionary in proof["pages"]:
		var source: Dictionary = definitions[row["id"]]
		_check(row["title_sha256"] == String(source["title"]).sha256_text() and row["body_sha256"] == String(source["pages"][0]).sha256_text(), "source text hashes mismatch")
		_check(row["page_sha256"] == "".sha256_text(), "single-page reader unexpectedly displayed page indicator")
	var headless := DisplayServer.get_name() == "headless"
	_check(proof["disabled"] == headless and proof["enabled"] != headless, "headless/GPU proof classification incorrect")
	_check(proof["draw_frames"] == (0 if headless else 9) and proof["process_frames"] == (9 if headless else 0), "three real frames per page not recorded")
	_check(proof["paper_texture_rid"] != 0, "existing paper texture absent from proof")
	for i in 3:
		_check(proof["fonts_before"][i]["font_id"] == proof["fonts_after"][i]["font_id"] \
			and proof["fonts_after"][i]["size"] == [12, 15, 11][i], "warming substituted existing Reader font/size")
	var second: Dictionary = await ui.warm_reader_pages({"two-pages": {"kind": "notice", "title": "Листалка", "pages": ["α первая", "β вторая"]}})
	_check(_snapshot(ui) == before and second["state_restored"], "repeat warm changed saved state/layout")
	_check(second["pages"].size() == 2 and second["pages"][0]["index"] == 0 and second["pages"][1]["index"] == 1, "multi-page input was not rendered completely")
	_check(second["pages"][0]["page_sha256"] == "1 / 2   [← →]".sha256_text() \
		and second["pages"][1]["page_sha256"] == "2 / 2   [← →]".sha256_text(), "arrows/page glyph provenance mismatch")
	process_frame.disconnect(observer)
	_check(callback_calls == 0 and audio.calls == 0 and observed_warm_frames >= 15, "warm silently skipped setters or produced side effects")
	ui.reader.open = false
	ui._reader_screen.visible = false
	var closed_before := _snapshot(ui)
	var empty: Dictionary = await ui.warm_reader_pages({})
	_check(_snapshot(ui) == closed_before and empty["state_restored"] and empty["pages"].is_empty(), "empty input or closed Reader changed state")
	root.remove_child(ui)
	var detached: Dictionary = await ui.warm_reader_pages(definitions)
	_check(detached["disabled"] and not detached["enabled"] and detached["reason"] == "detached" and detached["draw_frames"] == 0, "detached warm claimed render work")
	ui.free()
	audio.free()
	completed = true
	_check(completed and checks >= 30, "warm regression aborted before meaningful assertions")
	for error: String in errors: printerr("test_reader_warm: ", error)
	print("test_reader_warm: ", "PASS" if errors.is_empty() else "FAIL", " checks=", checks,
		" (", "CPU restoration only; no GPU draw claim" if headless else "actual draw frames", ")")
	quit(0 if errors.is_empty() else 1)

func _snapshot(ui: Overlays) -> Dictionary:
	var controls: Array[Dictionary] = []
	_controls(ui._reader_screen, controls)
	return {"open": ui.reader.open, "title": ui.reader.title, "pages": ui.reader.pages.duplicate(true),
		"index": ui.reader.index, "callback": ui.reader.onClose, "busy": ui.busy,
		"labels": [ui._reader_title.text, ui._reader_body.text, ui._reader_page.text],
		"reader_visible": ui._reader_screen.visible, "load_visible": ui._load.visible,
		"reader_z": ui._reader_screen.z_index, "load_z": ui._load.z_index,
		"load_color": (ui._load.get_node("Back") as ColorRect).color,
		"scroll": Vector2i(ui._reader_scroll.scroll_horizontal, ui._reader_scroll.scroll_vertical),
		"tape": ui._tape_mode, "hud_on": ui._hud_on, "hud_visible": ui._hud.visible,
		"pause": ui._pause.visible, "start": ui._start.visible, "controls": controls}

func _controls(node: Node, out: Array[Dictionary]) -> void:
	if node is Control:
		var control := node as Control
		out.append({"id": control.get_instance_id(), "position": control.position, "size": control.size,
			"minimum": control.custom_minimum_size, "visible": control.visible, "z": control.z_index})
	for child: Node in node.get_children(): _controls(child, out)

func _check(passed: bool, message: String) -> void:
	checks += 1
	if not passed: errors.append(message)

func _layout_diff(before: Dictionary, after: Dictionary) -> void:
	for i in before["controls"].size():
		if before["controls"][i] != after["controls"][i]:
			printerr("test_reader_warm layout changed ", i, " before=", before["controls"][i], " after=", after["controls"][i])

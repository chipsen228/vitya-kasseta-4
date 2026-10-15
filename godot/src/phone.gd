# Дисковый телефон и просмотр диалогов. Порт src/ui/phone.js.
#
# Разговор идёт субтитрами поверх треска снятой трубки: голосов в CC0 нет,
# и это к лучшему — «уезжайте» страшнее, когда слов не разобрать.
#
# Тот же плеер обслуживает финал у ворот: строки идут по времени,
# [E] листает быстрее.
#
# RefCounted, а не CanvasLayer: у слоя занято имя show(), а меню в оригинале
# показывается именно им. Свой слой объект создаёт сам и вешает на переданный
# узел — main.gd остаётся владельцем дерева.
class_name Phone
extends RefCounted

# Выше HUD и карточек (слой оверлеев), ниже скримера.
const LAYER := 2

# Ремарки «02» — единственная сцена телефона, где нет ни одного слова. Звук тут
# и есть содержание: гудка нет, в трубке кто-то дышит, трубку кладут первыми.
# Совпадение по куску строки, а не по индексу: строки принадлежат texts.json,
# и правка порядка не должна переставлять звуки.
const NOTE_SFX := {
	"в трубке кто-то дышит": "breath-line",
	"трубку кладут первым": "line-connect",
	"кладёт трубку первым": "line-connect",
}

const INK := Color(0.847, 0.824, 0.761)        # #d8d2c2
const INK_DIM := Color(0.553, 0.533, 0.482)    # #8d887b
const AMBER := Color(0.910, 0.765, 0.478)      # #e8c37a

var audio: GameAudio = null

# Голос в трубке (фаза 5). null или отсутствие записи — прежний бубнёж
# с длительностью по формуле.
var voice: GameVoice = null
var spatial_dialogue_source := Callable()

var open := false
var sel := 0
var options: Array = []
var onPick := Callable()

var dialogue: Array = []
var dlgIndex := 0
var dlgTimer := 0.0
var onDialogueEnd := Callable()
var subtitleSink := Callable()

var _talking := false

var _layer: CanvasLayer = null
var _root: Control = null
var _list: VBoxContainer = null


func _init(game_audio: GameAudio = null, parent: Node = null) -> void:
	audio = game_audio
	_build()
	if parent != null:
		attach(parent)


## Куда повесить слой телефона. Отдельным вызовом — main.gd создаёт телефон
## раньше, чем у него появляется корень сцены.
func attach(parent: Node) -> void:
	if _layer.get_parent() == parent:
		return
	if _layer.get_parent() != null:
		_layer.get_parent().remove_child(_layer)
	parent.add_child(_layer)


func _build() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "PhoneLayer"
	_layer.layer = LAYER

	_root = Control.new()
	_root.name = "Phone"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = Overlays.ui_theme()
	_root.visible = false
	_layer.add_child(_root)

	var dim := ColorRect.new()
	dim.name = "Dim"
	dim.color = Color(0.012, 0.016, 0.020, 0.86)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(dim)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)

	var body := PanelContainer.new()
	body.name = "Body"
	body.custom_minimum_size = Vector2(420, 0)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.071, 0.075, 0.078, 0.96)
	sb.border_color = Color(0.847, 0.824, 0.761, 0.2)
	sb.set_border_width_all(1)
	sb.content_margin_left = 35
	sb.content_margin_right = 35
	sb.content_margin_top = 32
	sb.content_margin_bottom = 32
	body.add_theme_stylebox_override("panel", sb)
	center.add_child(body)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	body.add_child(col)

	var label := Label.new()
	label.text = "НАБРАТЬ НОМЕР"
	label.add_theme_font_override("font", Overlays.tracked_font(3))
	label.add_theme_font_size_override("font_size", 12)
	label.add_theme_color_override("font_color", INK_DIM)
	col.add_child(label)

	var gap1 := Control.new()
	gap1.custom_minimum_size = Vector2(0, 19)
	col.add_child(gap1)

	_list = VBoxContainer.new()
	_list.name = "List"
	_list.add_theme_constant_override("separation", 0)
	col.add_child(_list)

	var gap2 := Control.new()
	gap2.custom_minimum_size = Vector2(0, 26)
	col.add_child(gap2)

	var hint := Label.new()
	hint.text = "[↑ ↓] выбор · [E] набрать · [ESC] положить трубку"
	hint.add_theme_font_override("font", Overlays.tracked_font(1))
	hint.add_theme_font_size_override("font_size", 11)
	hint.add_theme_color_override("font_color", Color(0.553, 0.533, 0.482, 0.75))
	col.add_child(hint)


# ---------- меню набора ----------

func show(opts: Array, on_pick: Variant = null) -> void:
	options = opts
	onPick = Callable()
	if on_pick is Callable:
		onPick = on_pick
	sel = 0
	open = true
	_root.visible = true
	_render()
	if audio != null:
		audio.phone_bed(true)


func hide() -> void:
	open = false
	_root.visible = false
	if audio != null:
		audio.phone_bed(false)


func _render() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	for i in options.size():
		var o: Dictionary = options[i]
		var picked := i == sel
		var done := bool(o.get("done", false))

		var item := PanelContainer.new()
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.910, 0.765, 0.478, 0.07) if picked else Color(0, 0, 0, 0)
		sb.border_width_left = 2
		sb.border_color = AMBER if picked else Color(0, 0, 0, 0)
		sb.content_margin_left = 13
		sb.content_margin_right = 13
		sb.content_margin_top = 10
		sb.content_margin_bottom = 10
		item.add_theme_stylebox_override("panel", sb)

		# RichTextLabel ради зачёркивания: у Label его нет, а «уже звонил»
		# в меню отличается именно им.
		var text := RichTextLabel.new()
		text.bbcode_enabled = true
		text.fit_content = true
		text.scroll_active = false
		text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		text.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var label := String(o.get("label", ""))
		text.text = ("[s]" + label + "[/s]") if done else label
		text.add_theme_font_override("normal_font", Overlays.tracked_font(1))
		text.add_theme_font_size_override("normal_font_size", 14)
		text.add_theme_color_override("default_color", Color(0.949, 0.925, 0.867) if picked else INK_DIM)
		if done:
			text.modulate.a = 0.45
		item.add_child(text)
		_list.add_child(item)


func move(d: int) -> void:
	if not open or options.is_empty():
		return
	sel = (sel + d + options.size()) % options.size()
	_render()
	if audio != null:
		audio.click()


func pick() -> void:
	if not open:
		return
	var o: Variant = options[sel] if sel < options.size() else null
	hide()
	if onPick.is_valid():
		onPick.call(o)


# ---------- проигрывание реплик ----------

## lines: [[кто, текст], ...]. Показываются по одной с паузой по длине.
## sink принимает (текст, секунды) или (текст, секунды, кто) — оба варианта живут.
func playLines(lines: Array, sink: Variant = null, on_end: Variant = null) -> void:
	dialogue = lines.duplicate()
	dlgIndex = -1
	dlgTimer = 0.0
	_talking = true
	subtitleSink = Callable()
	if sink is Callable:
		subtitleSink = sink
	onDialogueEnd = Callable()
	if on_end is Callable:
		onDialogueEnd = on_end
	_nextLine()


func _nextLine() -> void:
	# [E] листает субтитр быстрее, чем договорит реплика. Без обрыва пропущенная
	# строка продолжала бы звучать под следующей — два голоса разом в трубке.
	if voice != null:
		voice.stop_dialogue()
	dlgIndex += 1
	if not _talking or dlgIndex >= dialogue.size():
		dialogue = []
		_talking = false
		if audio != null:
			audio.phone_bed(false)
		var cb := onDialogueEnd
		onDialogueEnd = Callable()
		if cb.is_valid():
			cb.call()
		return

	var line: Array = dialogue[dlgIndex]
	var who := String(line[0])
	var text := String(line[1])
	var seconds := maxf(1.6, minf(6.5, float(text.length()) * 0.055 + 1.1))
	var voiced := false
	if voice != null and who != "pause" and who != "note" and text != "":
		var at := Vector3.INF
		if spatial_dialogue_source.is_valid(): at = spatial_dialogue_source.call(who)
		var spoken := voice.play_spatial_dialogue_line(who, text, at, seconds) if at.is_finite() else voice.play_dialogue_line(who, text, seconds)
		if spoken > 0.0:
			# Длительность — из реального файла, а не из формулы: та упирается
			# в потолок 6.5 с, а длинные реплики мамы идут 9–11 секунд, и по
			# формуле следующая строка заговорила бы поверх предыдущей.
			seconds = spoken + 0.35
			voiced = true
	dlgTimer = 1.4 if who == "pause" else seconds
	if subtitleSink.is_valid():
		if subtitleSink.get_argument_count() >= 3:
			subtitleSink.call(text, seconds + 0.4, who)
		else:
			subtitleSink.call(text, seconds + 0.4)
	if not voiced and who != "pause" and who != "note" and text != "" and audio != null:
		audio.mumble(minf(2.2, seconds * 0.6))
	elif who == "note" and audio != null:
		var low := text.to_lower()
		for frag: String in NOTE_SFX:
			if low.find(frag) >= 0:
				audio.sfx(String(NOTE_SFX[frag]))
				break


func skipLine() -> void:
	if _talking:
		_nextLine()


var talking: bool:
	get:
		return _talking


func update(dt: float) -> void:
	if not _talking:
		return
	dlgTimer -= dt
	if dlgTimer <= 0.0:
		_nextLine()


# Набор номера: три звонка на домашнем аппарате.
#
# Подпись берётся из CALLS, а не пишется здесь заново: иначе в меню
# останется один абонент, а в трубке заговорит другой.
func callOptions(state: GameState) -> Array:
	var calls: Dictionary = GameData.texts()["CALLS"]
	var line := func(id: String, number: String) -> Dictionary:
		var entry: Dictionary = calls.get(id, {})
		var title := String(entry.get("title", id))
		return {
			"id": id,
			"label": (title + " — " + number) if number != "" else title,
			"done": state.callsMade.has(id),
		}
	return [
		line.call("hospital", "4-17-02"),
		line.call("neighbour", "4-09-88"),
		line.call("militia", ""),
		{"id": "cancel", "label": "положить трубку", "done": false},
	]


func scriptFor(id: String) -> Variant:
	var calls: Dictionary = GameData.texts()["CALLS"]
	var c: Variant = calls.get(id, null)
	if c is Dictionary:
		var entry: Dictionary = c
		return entry.get("lines", null)
	return null

# Весь интерфейс. Порт src/ui/overlays.js вместе с разметкой index.html
# и палитрой style.css.
#
# Канвасного HUD нет и здесь: экраны, HUD и ридер — обычные Control-ноды,
# собранные кодом. Ни одной .tscn: бинарные сцены не читаются в диффах,
# а собирать три экрана руками в редакторе дороже, чем описать их здесь.
#
# Задача живёт в двух видах. Вспышка по центру сверху гаснет через шесть
# секунд — она про смену цели. Постоянная строка у правой кромки висит,
# пока задача не выполнена: без неё в подполе было непонятно, что брать
# и где. Квестлога всё равно нет: повтор вспышки по Tab.
#
# СЛОИ. Экран игры — TextureRect на CanvasLayer −1 (render_chain.gd), поэтому
# оверлеи живут на слое 1, телефон на 2, отладка на 3, скример на 4 — тот же
# порядок, что z-index в style.css. Плёночный слой .film сюда НЕ переехал:
# скан-линии, виньетку и зерно делает vhs_compose.gdshader.
#
# ИМЕНА. Методы camelCase — их зовут порты interact.gd и chapters.gd дословно
# из JS. Внутренняя кухня (сборка, раскладка) — обычный snake_case.
class_name Overlays
extends CanvasLayer

# ---------- палитра style.css ----------

const INK := Color(0.847, 0.824, 0.761)          # --ink      #d8d2c2
const INK_DIM := Color(0.553, 0.533, 0.482)      # --ink-dim  #8d887b
const AMBER := Color(0.910, 0.765, 0.478)        # --amber    #e8c37a
const ALARM := Color(0.851, 0.541, 0.463)        # --alarm    #d98a76
const REC_DOT := Color(0.784, 0.314, 0.235)      # #c8503c
const SCREEN_BG := Color(0.016, 0.020, 0.024, 0.93)
const CARD_INK := Color(0.937, 0.914, 0.863)     # #efe9dc
const SUB_INK := Color(0.949, 0.925, 0.878)      # #f2ece0
const OBJ_INK := Color(0.941, 0.906, 0.824)      # #f0e7d2
const PANEL_BG := Color(0.016, 0.020, 0.024, 0.62)
const PANEL_BG_SOLID := Color(0.016, 0.020, 0.024, 0.70)
const PAPER_INK := Color(0.149, 0.133, 0.106)    # #26221b
const PAPER_DIM := Color(0.416, 0.384, 0.322)    # #6a6252

const FONT_CYR := "res://assets/fonts/pt-mono-cyrillic-400.woff2"
const FONT_LAT := "res://assets/fonts/pt-mono-latin-400.woff2"

# 1rem браузера = 16 px. Кегли ниже — те же доли rem, что в style.css.
const REM := 16.0
const SAFE_MARGIN := 24.0

const LAYER := 1
const DEBUG_LAYER := 3

# ---------- разделяемые ресурсы ----------

static var _base_font: Font = null
static var _theme_cache: Theme = null
static var _tracked: Dictionary = {}


## PT Mono: кириллический файл основной, латинский — запасной (в нём цифры
## таймкода и латиница подсказок). Два подмножества как в @font-face style.css.
static func base_font() -> Font:
	if _base_font != null:
		return _base_font
	var cyr := _load_font(FONT_CYR)
	var lat := _load_font(FONT_LAT)
	if cyr != null:
		if lat != null:
			var fb: Array[Font] = [lat]
			cyr.fallbacks = fb
		_base_font = cyr
	elif lat != null:
		_base_font = lat
	else:
		push_warning("overlays: шрифты PT Mono не найдены, интерфейс пойдёт системным")
		_base_font = SystemFont.new()
	return _base_font


static func _load_font(path: String) -> Font:
	if not ResourceLoader.exists(path):
		return null
	var r: Variant = load(path)
	return r as Font


## letter-spacing из CSS: у Godot это межглифовый отступ в пикселях, поэтому
## значение считается заранее (кегль × доля em) и кэшируется по нему.
static func tracked_font(spacing: int) -> Font:
	if spacing <= 0:
		return base_font()
	if _tracked.has(spacing):
		return _tracked[spacing]
	var v := FontVariation.new()
	v.base_font = base_font()
	v.spacing_glyph = spacing
	_tracked[spacing] = v
	return v


static func ui_theme() -> Theme:
	if _theme_cache != null:
		return _theme_cache
	var t := Theme.new()
	t.default_font = base_font()
	t.default_font_size = 13
	_theme_cache = t
	return t


# ---------- настройки картинки (фаза 7) ----------

# Тот же файл и та же секция, где живёт галочка скримеров (scare.gd): одна
# настройка игры — один конфиг, иначе они начнут расходиться при переустановке.
const CFG := "user://vitya.cfg"
const CFG_SECTION := "vitya"
const KEY_BRIGHT := "brightness"
const KEY_SHARP := "sharpness"

# Вилка ползунка яркости вокруг заводских 0.62. Ниже 0.45 двор уходит в чернильную
# кашу, выше 1.15 возвращается ровно тот пересвет, ради которого всё затевалось.
const BRIGHT_MIN := 0.45
const BRIGHT_MAX := 1.15

# Высота буфера кадра. «Ретро» — как было в браузере и до фазы 7; «средняя» —
# ровно половина 1080p, то есть целочисленный апскейл; «чёткая» — для тех,
# кому дрожь рёбер важнее крупного пикселя.
# «Целочисленная» (фаза 8) — не четвёртая высота, а правило: буфер = окно / N.
# Дробный апскейл (окно 1055 строк на буфер 540 — это 1.954) бьёт периодические
# узоры кадра об экранную сетку и даёт муар; здесь его нет ценой каймы
# в несколько пикселей. Маркер −1 разбирает RenderChain.SHARPNESS_INTEGER.
const SHARPNESS := [
	{"label": "ретро", "h": 360},
	{"label": "средняя", "h": 540},
	{"label": "чёткая", "h": 720},
	{"label": "целочисленная", "h": RenderChain.SHARPNESS_INTEGER},
]


## Сохранённая яркость. Нечитаемый конфиг молча отдаёт заводскую — тот же
## принцип, что у скримеров.
static func read_brightness() -> float:
	var cfg := ConfigFile.new()
	if cfg.load(CFG) != OK:
		return RenderChain.TONEMAP_EXPOSURE
	return clampf(float(cfg.get_value(CFG_SECTION, KEY_BRIGHT, RenderChain.TONEMAP_EXPOSURE)),
		BRIGHT_MIN, BRIGHT_MAX)


## Сохранённый номер чёткости. При первом запуске его нет, и тогда решает окно:
## берётся половина его высоты (это и есть целочисленный апскейл 2x) и к ней
## подбирается ближайший пресет. Ровное сравнение «>= 540» тут не годится:
## клиентская область окна 1920x1080 — это 1055 строк, половина 527, и порог
## отправил бы честный Full HD в «ретро».
static func read_sharpness(window_height: int) -> int:
	var want := clampi(int(window_height / 2), 360, 540)
	var fallback := 0 if absi(360 - want) <= absi(540 - want) else 1
	var cfg := ConfigFile.new()
	if cfg.load(CFG) != OK:
		return fallback
	return clampi(int(cfg.get_value(CFG_SECTION, KEY_SHARP, fallback)), 0, SHARPNESS.size() - 1)


static func sharpness_height(idx: int) -> int:
	return int(SHARPNESS[clampi(idx, 0, SHARPNESS.size() - 1)]["h"])


static func _write_cfg(key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	cfg.set_value(CFG_SECTION, key, value)
	cfg.save(CFG)


# ---------- сигналы кнопок и настроек ----------

signal start_pressed
signal resume_pressed
signal restart_pressed
signal fullscreen_pressed
signal sens_changed(value: float)
signal smooth_changed(value: float)
signal volume_changed(value: float)
signal invert_changed(on: bool)
signal scares_changed(on: bool)
signal brightness_changed(value: float)
signal sharpness_changed(height: int)


class CardState extends RefCounted:
	var open := false
	var queue: Array = []
	var onDone := Callable()
	var auto := 0.0
	var timer := 0.0


class ReaderState extends RefCounted:
	var open := false
	var pages: Array = []
	var index := 0
	var onClose := Callable()
	var title := ""


# Крупный план фотографии (фаза 9). Отдельно от ридера, а не страницей в нём:
# у ридера бумажный фон, ширина колонки под текст и листалка страниц — снимок
# в этой рамке читается как записка с картинкой, а не как фотография в руках.
class PhotoState extends RefCounted:
	var open := false
	var onClose := Callable()
	var id := ""


var card := CardState.new()
var reader := ReaderState.new()
var photo := PhotoState.new()

# Скример живёт отдельным модулем и рисует себя сам; сюда main.gd кладёт
# только «идёт или нет», чтобы busy закрывал ввод. Знать про Scare
# оверлеям незачем — иначе две системы начнут делить один флаг.
var scareOpen := false

var _objTimer := 0.0
var _subTimer := 0.0
var _subPrio := 0

# Звук ридера (фаза 5). Ставит main.gd; null — записок листают молча, как
# в принятой версии фазы 4.
var audio: GameAudio = null
var _toastTimer := 0.0
var _lastTask: Variant = null
var _clock := 0.0
var _cross := 1.0
var _hud_on := false
var _tape_mode := false

# ---------- узлы ----------

var _root: Control = null
var _hud: Control = null
var _top: HBoxContainer = null
var _rec_dot: ColorRect = null
var _clock_label: Label = null
var _chapter_tag: Label = null
var _task_line: Label = null
var _objective: Label = null
var _crosshair: Panel = null
var _cross_box: StyleBoxFlat = null
var _prompt_row: HBoxContainer = null
var _prompt: PanelContainer = null
var _prompt_key: Label = null
var _prompt_text: Label = null
var _subtitle: Label = null
var _toast_row: HBoxContainer = null
var _toast_label: Label = null
var _battery: HBoxContainer = null
var _battery_text: Label = null
var _held_readout: VBoxContainer = null
var _held_name: Label = null
var _held_controls: Label = null
var _lock_row: HBoxContainer = null

var _load: Control = null
var _load_title: Label = null
var _bar_bg: ColorRect = null
var _bar_fill: ColorRect = null
var _load_label: Label = null

var _start: Control = null
var _start_eyebrow: Label = null
var _start_scroll: ScrollContainer = null
var _start_col: VBoxContainer = null
var _start_titles: Array = []
var _start_title_wrap: Control = null
var _start_grid: GridContainer = null

var _pause: Control = null
var _pause_scroll: ScrollContainer = null
var _pause_holder: CenterContainer = null
var _pause_card: VBoxContainer = null
var _sens: HSlider = null
var _sens_out: Label = null
var _smooth: HSlider = null
var _smooth_out: Label = null
var _vol: HSlider = null
var _vol_out: Label = null
var _invert: CheckBox = null
var _scares: CheckBox = null
var _bright: HSlider = null
var _bright_out: Label = null
var _sharp: Button = null
var _sharp_idx := 1

var _cards: Control = null
var _card_text: Label = null
var _card_hint: Label = null

var _fail: Control = null
var _fail_text: Label = null
var _fail_hint: Label = null

var _reader_screen: Control = null
var _reader_title: Label = null
var _reader_body: Label = null
var _reader_page: Label = null
var _reader_scroll: ScrollContainer = null
var _reader_holder: CenterContainer = null
var _paper: PanelContainer = null
var _reader_warming := false

var _photo_screen: Control = null
var _photo_scroll: ScrollContainer = null
var _photo_holder: CenterContainer = null
var _photo_col: VBoxContainer = null
var _photo_frame: PanelContainer = null
var _photo_rect: TextureRect = null
var _photo_caption: Label = null

var _debug_layer: CanvasLayer = null
var _debug: PanelContainer = null
var _debug_text: Label = null


func _init() -> void:
	name = "Overlays"
	layer = LAYER
	_build()


func _ready() -> void:
	_layout()


# ============================================================== сборка ===

func _build() -> void:
	_root = Control.new()
	_root.name = "UI"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = ui_theme()
	add_child(_root)
	_root.resized.connect(_layout)

	_build_hud()
	_build_load()
	_build_start()
	_build_pause()
	_build_cards()
	_build_fail()
	_build_reader()
	_build_photo()
	_build_debug()


func _label(text: String, size: int, color: Color, spacing := 0,
		align := HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", tracked_font(spacing))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = align
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# text-shadow из CSS: тень + мягкий ореол под ней.
func _shadow(l: Label, alpha := 0.9, dy := 2, blur := 6) -> void:
	l.add_theme_color_override("font_shadow_color", Color(0, 0, 0, alpha))
	l.add_theme_constant_override("shadow_offset_x", 0)
	l.add_theme_constant_override("shadow_offset_y", dy)
	l.add_theme_constant_override("shadow_outline_size", blur)


func _gap(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


func _screen(nm: String, bg: Color, blocking := false) -> Control:
	var s := Control.new()
	s.name = nm
	s.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	s.mouse_filter = Control.MOUSE_FILTER_STOP if blocking else Control.MOUSE_FILTER_IGNORE
	s.visible = false
	var back := ColorRect.new()
	back.name = "Back"
	back.color = bg
	back.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	s.add_child(back)
	_root.add_child(s)
	return s


func _center(parent: Control) -> CenterContainer:
	var c := CenterContainer.new()
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(c)
	return c


# Клавиша в рамке — <kbd> из style.css.
func _kbd(text: String) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0)
	sb.border_color = Color(0.847, 0.824, 0.761, 0.45)
	sb.set_border_width_all(1)
	sb.content_margin_left = 6
	sb.content_margin_right = 6
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := _label(text, 12, AMBER, 0, HORIZONTAL_ALIGNMENT_CENTER)
	l.custom_minimum_size = Vector2(20, 0)
	p.add_child(l)
	return p


func _panel(bg: Color, pad_x: int, pad_y: int) -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.content_margin_left = pad_x
	sb.content_margin_right = pad_x
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	p.add_theme_stylebox_override("panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return p


# ---------- HUD ----------

func _build_hud() -> void:
	_hud = Control.new()
	_hud.name = "Hud"
	_hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.visible = false
	_root.add_child(_hud)

	# Верхняя строка: REC, таймкод и колонка «глава + задача» у правой кромки.
	_top = HBoxContainer.new()
	_top.name = "Top"
	_top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top.alignment = BoxContainer.ALIGNMENT_BEGIN
	_top.add_theme_constant_override("separation", 22)
	_hud.add_child(_top)

	var rec := HBoxContainer.new()
	rec.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rec.add_theme_constant_override("separation", 8)
	_rec_dot = ColorRect.new()
	_rec_dot.color = REC_DOT
	_rec_dot.custom_minimum_size = Vector2(9, 9)
	_rec_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_rec_dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rec.add_child(_rec_dot)
	var rec_label := _label("REC", 12, ALARM, 2)
	_shadow(rec_label, 0.9, 1, 3)
	rec.add_child(rec_label)
	_top.add_child(rec)

	_clock_label = _label("20:41:00", 12, Color(0.847, 0.824, 0.761, 0.72), 2)
	_shadow(_clock_label, 0.9, 1, 3)
	_top.add_child(_clock_label)

	_top.add_child(_spacer())

	# Тег главы и постоянная строка задачи стоят одной колонкой у правой
	# кромки: задача читается как приписка к главе, а не как второй HUD.
	var aside := VBoxContainer.new()
	aside.mouse_filter = Control.MOUSE_FILTER_IGNORE
	aside.add_theme_constant_override("separation", 8)
	aside.size_flags_horizontal = Control.SIZE_SHRINK_END
	_top.add_child(aside)

	_chapter_tag = _label("", 12, AMBER, 3, HORIZONTAL_ALIGNMENT_RIGHT)
	_shadow(_chapter_tag, 0.9, 1, 3)
	aside.add_child(_chapter_tag)

	# Кегль на два шага мельче вспышки и цвет приглушён — иначе строка
	# спорит с прицелом и подсказкой [E] в центре кадра.
	#
	# ФАЗА 18. Было 11 и 0.55. Это единственный навигатор игры: он один
	# отвечает на «а что сейчас делать», и в ДЕРЕВНЕ, выросшей до двух
	# десятков ступеней, читать его приходится постоянно. 0.55 в углу кадра
	# на тёмном фоне — на грани различимости, и Пётр его попросту не видел.
	# 12 и 0.8: заметнее прежнего и всё ещё тише прицела.
	_task_line = _label("", 12, Color(0.847, 0.824, 0.761, 0.8), 1, HORIZONTAL_ALIGNMENT_RIGHT)
	_task_line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_task_line.custom_minimum_size = Vector2(360, 0)
	_task_line.visible = false
	_shadow(_task_line, 0.95, 1, 3)
	aside.add_child(_task_line)

	_objective = _label("", 15, OBJ_INK, 2, HORIZONTAL_ALIGNMENT_CENTER)
	_objective.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_objective.visible = false
	_shadow(_objective, 0.95, 2, 6)
	_hud.add_child(_objective)

	_crosshair = Panel.new()
	_cross_box = StyleBoxFlat.new()
	_cross_box.bg_color = Color(0.902, 0.886, 0.839, 0.5)
	_cross_box.set_corner_radius_all(2)
	_crosshair.add_theme_stylebox_override("panel", _cross_box)
	_crosshair.custom_minimum_size = Vector2(3, 3)
	_crosshair.size = Vector2(3, 3)
	_crosshair.pivot_offset = Vector2(1.5, 1.5)
	_crosshair.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_crosshair)

	_prompt_row = HBoxContainer.new()
	_prompt_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_prompt_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_prompt_row)

	_prompt = _panel(PANEL_BG, 14, 5)
	_prompt.visible = false
	_prompt_row.add_child(_prompt)
	var prow := HBoxContainer.new()
	prow.add_theme_constant_override("separation", 10)
	prow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.add_child(prow)
	var kbd := _kbd("E")
	_prompt_key = kbd.get_child(0) as Label
	prow.add_child(kbd)
	_prompt_text = _label("", 12, INK, 1)
	prow.add_child(_prompt_text)

	_subtitle = _label("", 15, SUB_INK, 0, HORIZONTAL_ALIGNMENT_CENTER)
	_subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_subtitle.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_subtitle.add_theme_constant_override("line_spacing", 6)
	_subtitle.visible = false
	_shadow(_subtitle, 0.95, 2, 8)
	_hud.add_child(_subtitle)

	_toast_row = HBoxContainer.new()
	_toast_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_toast_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_row.visible = false
	_hud.add_child(_toast_row)
	var toast_panel := PanelContainer.new()
	var tsb := StyleBoxFlat.new()
	tsb.bg_color = PANEL_BG_SOLID
	tsb.border_width_left = 2
	tsb.border_color = AMBER
	tsb.content_margin_left = 16
	tsb.content_margin_right = 16
	tsb.content_margin_top = 6
	tsb.content_margin_bottom = 6
	toast_panel.add_theme_stylebox_override("panel", tsb)
	toast_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast_row.add_child(toast_panel)
	_toast_label = _label("", 13, Color(0.933, 0.898, 0.816), 1)
	toast_panel.add_child(_toast_label)

	_battery = HBoxContainer.new()
	_battery.add_theme_constant_override("separation", 9)
	_battery.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_battery.visible = false
	_hud.add_child(_battery)
	_battery.add_child(_kbd("F"))
	_battery_text = _label("ФОНАРЬ 100%", 12, Color(0.847, 0.824, 0.761, 0.65), 2)
	_battery.add_child(_battery_text)

	# Выбор предмета — мировое действие, поэтому строка живёт в обычном HUD
	# и автоматически исчезает вместе с ним на кассете и блокирующих экранах.
	_held_readout = VBoxContainer.new()
	_held_readout.name = "HeldItem"
	_held_readout.alignment = BoxContainer.ALIGNMENT_END
	_held_readout.add_theme_constant_override("separation", 3)
	_held_readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_held_readout)
	_held_name = _label("ПУСТЫЕ РУКИ", 12, Color(0.847, 0.824, 0.761, 0.78), 2,
		HORIZONTAL_ALIGNMENT_RIGHT)
	_shadow(_held_name, 0.9, 1, 3)
	_held_readout.add_child(_held_name)
	_held_controls = _label("КОЛЕСО — ПРЕДМЕТ · F — ФОНАРЬ", 10,
		Color(0.847, 0.824, 0.761, 0.48), 1, HORIZONTAL_ALIGNMENT_RIGHT)
	_shadow(_held_controls, 0.8, 1, 2)
	_held_readout.add_child(_held_controls)

	_lock_row = HBoxContainer.new()
	_lock_row.alignment = BoxContainer.ALIGNMENT_CENTER
	_lock_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_lock_row)
	var lock_panel := _panel(PANEL_BG_SOLID, 18, 6)
	_lock_row.add_child(lock_panel)
	lock_panel.add_child(_label("КЛИК — управление мышью", 12, INK_DIM, 2))


# ---------- экран загрузки ----------

func _build_load() -> void:
	_load = _screen("LoadScreen", SCREEN_BG)
	_load.visible = true

	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(520, 0)
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_center(_load).add_child(col)

	col.add_child(_label("воспроизведение · SP · 180 min", 12, INK_DIM, 3,
		HORIZONTAL_ALIGNMENT_CENTER))
	col.add_child(_gap(10))

	_load_title = _label("ПЕРЕМОТКА", 29, INK, 12, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_load_title)
	col.add_child(_gap(30))

	_bar_bg = ColorRect.new()
	_bar_bg.color = Color(0.847, 0.824, 0.761, 0.14)
	_bar_bg.custom_minimum_size = Vector2(0, 3)
	_bar_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(_bar_bg)

	_bar_fill = ColorRect.new()
	_bar_fill.color = AMBER
	_bar_fill.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	_bar_fill.anchor_right = 0.0
	_bar_fill.offset_left = 0.0
	_bar_fill.offset_right = 0.0
	_bar_fill.offset_top = 0.0
	_bar_fill.offset_bottom = 0.0
	_bar_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar_bg.add_child(_bar_fill)

	col.add_child(_gap(16))
	_load_label = _label("инициализация", 12, INK_DIM, 2, HORIZONTAL_ALIGNMENT_CENTER)
	col.add_child(_load_label)


# ---------- экран старта ----------

func _build_start() -> void:
	_start = _screen("StartScreen", SCREEN_BG, true)

	_start_scroll = ScrollContainer.new()
	_start_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_start_scroll.custom_minimum_size = Vector2(680, 400)
	_center(_start).add_child(_start_scroll)

	_start_col = VBoxContainer.new()
	_start_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_col.add_theme_constant_override("separation", 0)
	_start_scroll.add_child(_start_col)

	_start_eyebrow = _label("запись 04 · август 2003", 12, INK_DIM, 3)
	_start_col.add_child(_start_eyebrow)
	_start_col.add_child(_gap(10))

	# Хроматическая кайма заголовка: красная и голубая копии по ±2 px.
	# В CSS это два text-shadow, у Label тень одна — кладём три слоя.
	_start_title_wrap = Control.new()
	_start_title_wrap.custom_minimum_size = Vector2(0, 62)
	_start_title_wrap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_start_col.add_child(_start_title_wrap)
	_start_titles = []
	var fringes := [
		[2.0, Color(0.784, 0.235, 0.157, 0.45)],
		[-2.0, Color(0.157, 0.549, 0.745, 0.35)],
		[0.0, INK],
	]
	for f: Array in fringes:
		var dx: float = f[0]
		var tint: Color = f[1]
		var t := _label("ВИТЯ. КАССЕТА №4", 50, tint, 6)
		t.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		t.offset_left = dx
		t.offset_right = dx
		t.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_start_title_wrap.add_child(t)
		_start_titles.append(t)

	var lead := _label("Дачное товарищество «Ольховка». Будний вечер, конец августа.",
		14, INK_DIM)
	lead.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_start_col.add_child(lead)
	_start_col.add_child(_gap(26))

	# Врезка с полосой слева.
	var note_row := HBoxContainer.new()
	note_row.add_theme_constant_override("separation", 18)
	_start_col.add_child(note_row)
	var stripe := ColorRect.new()
	stripe.color = Color(0.910, 0.765, 0.478, 0.4)
	stripe.custom_minimum_size = Vector2(2, 0)
	stripe.size_flags_vertical = Control.SIZE_EXPAND_FILL
	note_row.add_child(stripe)
	var note_col := VBoxContainer.new()
	note_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	note_col.add_theme_constant_override("separation", 11)
	note_row.add_child(note_col)
	var p1 := _label("Витя две недели звонил и говорил, что на участке кто-то бывает."
		+ " Я отмахивался. Двенадцатого августа он не позвонил.", 14, INK)
	p1.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	p1.add_theme_constant_override("line_spacing", 8)
	note_col.add_child(p1)
	var p2 := _label("Наушники. Не торопитесь. Игра идёт около получаса.", 14, AMBER)
	p2.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note_col.add_child(p2)
	_start_col.add_child(_gap(29))

	var start_btn := _button("ВОСПРОИЗВЕДЕНИЕ", 16, 5, 17)
	var on_start := func() -> void:
		start_pressed.emit()
	start_btn.pressed.connect(on_start)
	_start_col.add_child(start_btn)
	_start_col.add_child(_label("нажмите, чтобы войти", 10, INK_DIM, 2,
		HORIZONTAL_ALIGNMENT_CENTER))
	_start_col.add_child(_gap(29))

	_start_grid = GridContainer.new()
	_start_grid.columns = 3
	_start_grid.add_theme_constant_override("h_separation", 22)
	_start_grid.add_theme_constant_override("v_separation", 8)
	_start_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_start_col.add_child(_start_grid)
	var keys := [
		["W A S D", "идти"], ["МЫШЬ", "осмотреться"], ["SHIFT", "бежать"],
		["C", "пригнуться"], ["E", "взаимодействие"], ["F", "фонарь"],
		["Q", "позвать"], ["TAB", "задача · телефон"], ["ESC", "пауза"],
	]
	for k: Array in keys:
		var cell := HBoxContainer.new()
		cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell.add_child(_label(String(k[0]), 12, AMBER, 1))
		cell.add_child(_spacer())
		cell.add_child(_label(String(k[1]), 12, INK_DIM))
		_start_grid.add_child(cell)

	_start_col.add_child(_gap(26))
	_start_col.add_child(_label("Вымышленная история. Игра работает локально, без интернета.",
		11, Color(0.553, 0.533, 0.482, 0.7)))


func _button(text: String, size: int, spacing: int, pad_y: int, quiet := false) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", tracked_font(spacing))
	b.add_theme_font_size_override("font_size", size)
	b.add_theme_color_override("font_color", INK_DIM if quiet else INK)
	b.add_theme_color_override("font_hover_color", INK)
	b.add_theme_color_override("font_pressed_color", AMBER)
	b.add_theme_color_override("font_focus_color", INK)
	var border := Color(0.847, 0.824, 0.761, 0.16 if quiet else 0.35)
	b.add_theme_stylebox_override("normal", _button_box(Color(0, 0, 0, 0), border, pad_y))
	b.add_theme_stylebox_override("hover", _button_box(Color(0.910, 0.765, 0.478, 0.08), AMBER, pad_y))
	b.add_theme_stylebox_override("pressed", _button_box(Color(0.910, 0.765, 0.478, 0.14), AMBER, pad_y))
	b.add_theme_stylebox_override("focus", _button_box(Color(0, 0, 0, 0), AMBER, pad_y))
	b.add_theme_stylebox_override("disabled", _button_box(Color(0, 0, 0, 0), border, pad_y))
	return b


func _button_box(bg: Color, border: Color, pad_y: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.content_margin_left = 19
	sb.content_margin_right = 19
	sb.content_margin_top = pad_y
	sb.content_margin_bottom = pad_y
	return sb


# ---------- экран паузы ----------

func _build_pause() -> void:
	_pause = _screen("PauseScreen", SCREEN_BG, true)
	_pause_scroll = ScrollContainer.new()
	_pause_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_pause.add_child(_pause_scroll)
	_pause_holder = CenterContainer.new()
	_pause_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_pause_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_pause_scroll.add_child(_pause_holder)

	_pause_card = VBoxContainer.new()
	_pause_card.custom_minimum_size = Vector2(420, 0)
	_pause_card.add_theme_constant_override("separation", 0)
	_pause_holder.add_child(_pause_card)

	_pause_card.add_child(_label("воспроизведение приостановлено", 12, INK_DIM, 3,
		HORIZONTAL_ALIGNMENT_CENTER))
	_pause_card.add_child(_gap(10))
	_pause_card.add_child(_label("ПАУЗА", 26, INK, 10, HORIZONTAL_ALIGNMENT_CENTER))
	_pause_card.add_child(_gap(24))

	var sens_pack := _slider_row(_pause_card, "Чувствительность мыши", 0.25, 2.5, 0.05, 0.8)
	_sens = sens_pack[0]
	_sens_out = sens_pack[1]
	_sens_out.text = "0.80"
	var on_sens := func(v: float) -> void:
		_sens_out.text = "%.2f" % v
		sens_changed.emit(v)
	_sens.value_changed.connect(on_sens)

	var smooth_pack := _slider_row(_pause_card, "Плавность обзора", 0.0, 1.0, 0.05, 0.45)
	_smooth = smooth_pack[0]
	_smooth_out = smooth_pack[1]
	_smooth_out.text = "45%"
	var on_smooth := func(v: float) -> void:
		_smooth_out.text = "%d%%" % int(round(v * 100.0))
		smooth_changed.emit(v)
	_smooth.value_changed.connect(on_smooth)

	# Яркость и чёткость. Последнее слово о том, «тот ли это вечер», — за глазами
	# игрока и его монитором, а не за цифрой в render_chain.gd: на одной панели
	# сумерки читаются как сумерки, на другой — как чернота.
	var bright_pack := _slider_row(_pause_card, "Яркость", BRIGHT_MIN, BRIGHT_MAX, 0.01,
		RenderChain.TONEMAP_EXPOSURE)
	_bright = bright_pack[0]
	_bright_out = bright_pack[1]
	_bright_out.text = "%.2f" % RenderChain.TONEMAP_EXPOSURE
	var on_bright := func(v: float) -> void:
		_bright_out.text = "%.2f" % v
		_write_cfg(KEY_BRIGHT, v)
		brightness_changed.emit(v)
	_bright.value_changed.connect(on_bright)

	_sharp = _choice_row(_pause_card, "Чёткость")
	var on_sharp := func() -> void:
		_sharp_idx = (_sharp_idx + 1) % SHARPNESS.size()
		_sharp.text = String(SHARPNESS[_sharp_idx]["label"])
		_write_cfg(KEY_SHARP, _sharp_idx)
		sharpness_changed.emit(int(SHARPNESS[_sharp_idx]["h"]))
	_sharp.pressed.connect(on_sharp)

	var vol_pack := _slider_row(_pause_card, "Громкость", 0.0, 1.0, 0.05, 0.8)
	_vol = vol_pack[0]
	_vol_out = vol_pack[1]
	_vol_out.text = "80%"
	var on_vol := func(v: float) -> void:
		_vol_out.text = "%d%%" % int(round(v * 100.0))
		volume_changed.emit(v)
	_vol.value_changed.connect(on_vol)

	_invert = _check_row(_pause_card, "Инверсия по вертикали", false)
	var on_invert := func(on: bool) -> void:
		invert_changed.emit(on)
	_invert.toggled.connect(on_invert)

	# Фаза 8: подпись честная. Галочка гасит не только фотографию лица —
	# белый удар скримера, физический удар при поимке, силу двух сюжетных
	# джампскейров, оба мягких испуга, мигание фонаря и знаки-акценты.
	_scares = _check_row(_pause_card, "Скримеры и резкие эффекты", true)
	var on_scares := func(on: bool) -> void:
		scares_changed.emit(on)
	_scares.toggled.connect(on_scares)

	_pause_card.add_child(_gap(12))
	var resume := _button("ПРОДОЛЖИТЬ", 13, 4, 14)
	var on_resume := func() -> void:
		resume_pressed.emit()
	resume.pressed.connect(on_resume)
	_pause_card.add_child(resume)
	_pause_card.add_child(_gap(9))

	var fs := _button("ВЕСЬ ЭКРАН", 13, 4, 14, true)
	var on_fs := func() -> void:
		fullscreen_pressed.emit()
	fs.pressed.connect(on_fs)
	_pause_card.add_child(fs)
	_pause_card.add_child(_gap(9))

	var restart := _button("НАЧАТЬ ЗАНОВО", 13, 4, 14, true)
	var on_restart := func() -> void:
		restart_pressed.emit()
	restart.pressed.connect(on_restart)
	_pause_card.add_child(restart)


func _slider_row(col: VBoxContainer, title: String, lo: float, hi: float,
		step: float, value: float) -> Array:
	var row := HBoxContainer.new()
	col.add_child(row)
	row.add_child(_label(title, 12, INK_DIM, 1))
	row.add_child(_spacer())
	var out := _label("", 12, AMBER, 0, HORIZONTAL_ALIGNMENT_RIGHT)
	row.add_child(out)
	col.add_child(_gap(6))
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(0, 16)
	col.add_child(s)
	col.add_child(_gap(18))
	return [s, out]


## Ряд с перебором вариантов по нажатию. Список из трёх пунктов не стоит
## OptionButton со своим выпадающим списком поверх паузы: на четыре строки
## интерфейса он тащит целую тему, а перебор по кругу читается сразу.
func _choice_row(col: VBoxContainer, title: String) -> Button:
	var row := HBoxContainer.new()
	col.add_child(row)
	row.add_child(_label(title, 12, INK_DIM, 1))
	row.add_child(_spacer())
	var b := Button.new()
	b.flat = true
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_color_override("font_color", AMBER)
	b.add_theme_font_size_override("font_size", 12)
	row.add_child(b)
	col.add_child(_gap(18))
	return b


func _check_row(col: VBoxContainer, title: String, on: bool) -> CheckBox:
	var row := HBoxContainer.new()
	col.add_child(row)
	row.add_child(_label(title, 12, INK_DIM, 1))
	row.add_child(_spacer())
	var cb := CheckBox.new()
	cb.button_pressed = on
	row.add_child(cb)
	col.add_child(_gap(18))
	return cb


# ---------- карточки глав и экран провала ----------

func _build_cards() -> void:
	_cards = _screen("CardScreen", Color(0, 0, 0, 1))
	_card_text = _label("", 18, CARD_INK, 1, HORIZONTAL_ALIGNMENT_CENTER)
	_card_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card_text.custom_minimum_size = Vector2(760, 0)
	_card_text.add_theme_constant_override("line_spacing", 18)
	_center(_cards).add_child(_card_text)

	_card_hint = _label("[ПРОБЕЛ] дальше", 11, INK_DIM, 3, HORIZONTAL_ALIGNMENT_CENTER)
	_cards.add_child(_card_hint)


func _build_fail() -> void:
	_fail = _screen("FailScreen", Color(0, 0, 0, 1))
	_fail_text = _label("", 18, CARD_INK, 1, HORIZONTAL_ALIGNMENT_CENTER)
	_fail_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_fail_text.custom_minimum_size = Vector2(760, 0)
	_fail_text.add_theme_constant_override("line_spacing", 18)
	_center(_fail).add_child(_fail_text)

	_fail_hint = _label("[R] отмотать назад", 11, INK_DIM, 3, HORIZONTAL_ALIGNMENT_CENTER)
	_fail.add_child(_fail_hint)


# ---------- ридер записок ----------

## Рисует настоящую бумагу и глифы под загрузкой, не открывая сюжетный ридер.
## Headless проверяет восстановление интерфейса, но не заявляет прогрев GPU.
func warm_reader_pages(definitions: Dictionary) -> Dictionary:
	var headless := DisplayServer.get_name() == "headless"
	var proof := {"enabled": not headless, "disabled": headless, "reason": "headless" if headless else "",
		"pages": [], "draw_frames": 0, "process_frames": 0, "state_restored": false,
		"reader_unchanged": false, "mode_unchanged": false, "fonts_before": [], "fonts_after": [], "errors": []}
	if not is_inside_tree() or _reader_warming:
		proof["enabled"] = false
		proof["disabled"] = true
		proof["reason"] = "detached" if not is_inside_tree() else "already warming"
		return proof
	_reader_warming = true
	var logical := _reader_warm_state()
	var texts := [_reader_title.text, _reader_body.text, _reader_page.text]
	var reader_visible := _reader_screen.visible
	var load_visible := _load.visible
	var load_z := _load.z_index
	var reader_z := _reader_screen.z_index
	var back := _load.get_node("Back") as ColorRect
	var back_color := back.color
	var scroll := Vector2i(_reader_scroll.scroll_horizontal, _reader_scroll.scroll_vertical)
	var layout: Array[Dictionary] = []
	_reader_warm_layout(_reader_screen, layout)
	proof["fonts_before"] = _reader_warm_fonts()
	var style := _paper.get_theme_stylebox("panel") as StyleBoxTexture
	proof["paper_texture_rid"] = style.texture.get_rid().get_id() if style != null and style.texture != null else 0
	# LoadScreen обычно имеет alpha=.93 и расположен раньше Reader в дереве.
	back.color = Color(back_color.r, back_color.g, back_color.b, 1.0)
	_load.z_index = 4095
	_reader_screen.z_index = mini(reader_z, 4094)
	_load.visible = true
	_reader_screen.visible = true
	var ids := definitions.keys()
	ids.sort()
	for id: Variant in ids:
		var definition: Variant = definitions[id]
		if not definition is Dictionary or String(definition.get("kind", "")) != "notice":
			continue
		var pages: Variant = definition.get("pages", [])
		var source: Array = pages if pages is Array else [String(pages)]
		if source.is_empty(): source = [""]
		for index in source.size():
			var title := String(definition.get("title", ""))
			var body := String(source[index])
			var page := "%d / %d   [← →]" % [index + 1, source.size()] if source.size() > 1 else ""
			_reader_title.text = title
			_reader_body.text = body
			_reader_page.text = page
			_reader_scroll.scroll_horizontal = 0
			_reader_scroll.scroll_vertical = 0
			for _frame in 3:
				if headless:
					await get_tree().process_frame
					proof["process_frames"] += 1
				else:
					await RenderingServer.frame_post_draw
					proof["draw_frames"] += 1
			proof["pages"].append({"id": String(id), "index": index, "title_sha256": title.sha256_text(),
				"body_sha256": body.sha256_text(), "page_sha256": page.sha256_text(),
				"draw_frames": 0 if headless else 3, "process_frames": 3 if headless else 0})
	proof["fonts_after"] = _reader_warm_fonts()
	_reader_title.text = texts[0]
	_reader_body.text = texts[1]
	_reader_page.text = texts[2]
	_reader_screen.visible = reader_visible
	# Даём контейнерам закончить отложенную раскладку возвращённого текста.
	await get_tree().process_frame
	await get_tree().process_frame
	for row: Dictionary in layout:
		var control: Control = row["node"]
		control.custom_minimum_size = row["minimum"]
		control.position = row["position"]
		control.size = row["size"]
	_reader_scroll.scroll_horizontal = scroll.x
	_reader_scroll.scroll_vertical = scroll.y
	_load.z_index = load_z
	_reader_screen.z_index = reader_z
	back.color = back_color
	_load.visible = load_visible
	proof["reader_unchanged"] = _reader_warm_state() == logical
	proof["mode_unchanged"] = bool(proof["reader_unchanged"])
	var restored: bool = _reader_title.text == texts[0] and _reader_body.text == texts[1] and _reader_page.text == texts[2] \
		and _reader_screen.visible == reader_visible and _load.visible == load_visible \
		and _load.z_index == load_z and _reader_screen.z_index == reader_z and back.color == back_color \
		and _reader_scroll.scroll_horizontal == scroll.x and _reader_scroll.scroll_vertical == scroll.y
	for row: Dictionary in layout:
		var control: Control = row["node"]
		restored = restored and control.custom_minimum_size == row["minimum"] \
			and control.position == row["position"] and control.size == row["size"]
	proof["state_restored"] = restored and bool(proof["reader_unchanged"])
	if not proof["state_restored"]: proof["errors"].append("Reader prewarm did not restore its UI state")
	_reader_warming = false
	return proof


func _reader_warm_state() -> Dictionary:
	return {"open": reader.open, "pages": reader.pages.duplicate(true), "index": reader.index,
		"onClose": reader.onClose, "title": reader.title, "busy": busy, "tape": _tape_mode,
		"hud_on": _hud_on, "hud_visible": _hud.visible, "pause": _pause.visible,
		"start": _start.visible, "card": card.open, "fail": failOpen, "scare": scareOpen, "photo": photo.open}


func _reader_warm_layout(node: Node, rows: Array[Dictionary]) -> void:
	if node is Control:
		var control := node as Control
		rows.append({"node": control, "position": control.position, "size": control.size,
			"minimum": control.custom_minimum_size})
	for child: Node in node.get_children(): _reader_warm_layout(child, rows)


func _reader_warm_fonts() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var text_server := TextServerManager.get_primary_interface()
	for label: Label in [_reader_title, _reader_body, _reader_page]:
		var font := label.get_theme_font("font")
		var size := label.get_theme_font_size("font_size")
		var rids: Array[int] = []
		var texture_count := 0
		for font_rid: RID in font.get_rids():
			rids.append(font_rid.get_id())
			if text_server.has_method("font_get_texture_count"):
				texture_count += int(text_server.call("font_get_texture_count", font_rid, Vector2i(size, 0)))
		out.append({"font_id": font.get_instance_id(), "size": size, "rids": rids, "texture_count": texture_count})
	return out

func _build_reader() -> void:
	_reader_screen = _screen("Reader", Color(0.012, 0.016, 0.020, 0.86))
	_reader_scroll = ScrollContainer.new()
	_reader_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_reader_screen.add_child(_reader_scroll)
	_reader_holder = CenterContainer.new()
	_reader_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reader_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_reader_scroll.add_child(_reader_holder)

	_paper = PanelContainer.new()
	_paper.custom_minimum_size = Vector2(560, 0)
	_paper.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_paper.add_theme_stylebox_override("panel", _paper_box())
	_reader_holder.add_child(_paper)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_paper.add_child(col)

	_reader_title = _label("", 12, PAPER_DIM, 4)
	col.add_child(_reader_title)
	col.add_child(_gap(19))

	_reader_body = _label("", 15, PAPER_INK)
	_reader_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_reader_body.custom_minimum_size = Vector2(476, 0)
	_reader_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_reader_body.add_theme_constant_override("line_spacing", 13)
	col.add_child(_reader_body)

	col.add_child(_gap(32))
	var foot := HBoxContainer.new()
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(foot)
	_reader_page = _label("", 11, PAPER_DIM, 2)
	foot.add_child(_reader_page)
	foot.add_child(_spacer())
	foot.add_child(_label("[E] убрать", 11, PAPER_DIM, 2))


# Бумага записки: тот же градиент 168°, что в style.css.
func _paper_box() -> StyleBox:
	var g := Gradient.new()
	g.set_offset(0, 0.0)
	g.set_color(0, Color(0.851, 0.812, 0.714))
	g.set_offset(1, 1.0)
	g.set_color(1, Color(0.741, 0.694, 0.596))
	g.add_point(0.55, Color(0.784, 0.741, 0.635))
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 64
	t.height = 256
	t.fill_from = Vector2(0.0, 0.0)
	t.fill_to = Vector2(0.21, 1.0)
	var sb := StyleBoxTexture.new()
	sb.texture = t
	sb.content_margin_left = 42
	sb.content_margin_right = 42
	sb.content_margin_top = 38
	sb.content_margin_bottom = 38
	return sb


# ---------- крупный план фотографии ----------

# Снимок в руках: карточка с полями, под ней подпись деда. Ни листалки,
# ни бумажного фона — фотография не записка.
func _build_photo() -> void:
	_photo_screen = _screen("Photo", Color(0.008, 0.010, 0.014, 0.90))
	_photo_scroll = ScrollContainer.new()
	_photo_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_photo_screen.add_child(_photo_scroll)
	_photo_holder = CenterContainer.new()
	_photo_holder.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_photo_holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_photo_scroll.add_child(_photo_holder)

	_photo_col = VBoxContainer.new()
	_photo_col.add_theme_constant_override("separation", 0)
	_photo_col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_photo_holder.add_child(_photo_col)

	# Поля вокруг снимка — те самые белые поля дешёвой печати 90-х.
	_photo_frame = _panel(Color(0.847, 0.824, 0.761, 0.96), 14, 14)
	_photo_frame.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_photo_col.add_child(_photo_frame)

	_photo_rect = TextureRect.new()
	_photo_rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_photo_rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	# NEAREST намеренно: снимок обязан жить по тем же правилам, что весь кадр,
	# и билинейное сглаживание на нём выдало бы, что это не часть игры.
	_photo_rect.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_photo_rect.custom_minimum_size = Vector2(420, 420)
	_photo_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_photo_frame.add_child(_photo_rect)

	_photo_col.add_child(_gap(22))
	_photo_caption = _label("", 14, INK, 2, HORIZONTAL_ALIGNMENT_CENTER)
	_photo_caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_photo_caption.custom_minimum_size = Vector2(560, 0)
	_photo_col.add_child(_photo_caption)
	_photo_col.add_child(_gap(18))
	_photo_col.add_child(_label("[E] убрать", 11, INK_DIM, 2, HORIZONTAL_ALIGNMENT_CENTER))


func _build_debug() -> void:
	_debug_layer = CanvasLayer.new()
	_debug_layer.name = "DebugLayer"
	_debug_layer.layer = DEBUG_LAYER
	add_child(_debug_layer)

	var holder := Control.new()
	holder.name = "DebugRoot"
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	holder.theme = ui_theme()
	_debug_layer.add_child(holder)

	_debug = _panel(Color(0, 0, 0, 0.72), 16, 11)
	_debug.visible = false
	holder.add_child(_debug)
	_debug_text = _label("", 11, Color(0.612, 0.878, 0.612))
	_debug_text.add_theme_constant_override("line_spacing", 4)
	_debug.add_child(_debug_text)


# ============================================================ раскладка ===

# vh/vw из style.css считаются здесь: у Godot таких единиц нет, а половина
# HUD прибита именно к процентам экрана.
func _layout() -> void:
	var vs := _root.size
	if vs.x <= 0.0 or vs.y <= 0.0:
		return
	var vw := vs.x / 100.0
	var vh := vs.y / 100.0

	_place(_top, 2.4 * vw, 2.2 * vh, vs.x - 4.8 * vw)
	_place(_objective, 0.0, 8.0 * vh, vs.x)
	_crosshair.position = vs * 0.5 - Vector2(1.5, 1.5)
	_place(_prompt_row, 0.0, vs.y * 0.5 + 34.0, vs.x)
	_place(_lock_row, 0.0, vs.y * 0.5 + 70.0, vs.x)

	var sub_w := minf(760.0, 86.0 * vw)
	_place(_subtitle, (vs.x - sub_w) * 0.5, vs.y - 13.0 * vh - 96.0, sub_w, 96.0)
	_place(_toast_row, 0.0, vs.y - 24.0 * vh - 32.0, vs.x)
	_place(_battery, 2.4 * vw, vs.y - 3.0 * vh - 22.0)
	var held_w := minf(360.0, maxf(230.0, vs.x * 0.34))
	_held_readout.custom_minimum_size = Vector2(held_w, 0)
	var held_h := _held_readout.get_combined_minimum_size().y
	_place(_held_readout, vs.x - maxf(SAFE_MARGIN, 2.4 * vw) - held_w,
		vs.y - maxf(SAFE_MARGIN, 3.0 * vh) - held_h, held_w)

	_place(_card_hint, 0.0, vs.y - 8.0 * vh - 18.0, vs.x)
	_place(_fail_hint, 0.0, vs.y - 8.0 * vh - 18.0, vs.x)

	_task_line.custom_minimum_size = Vector2(minf(400.0, 40.0 * vw), 0)

	# clamp() из style.css.
	_load_title.add_theme_font_size_override("font_size",
		int(clampf(4.0 * vw, 1.4 * REM, 2.2 * REM)))

	var title_size := int(clampf(6.0 * vw, 1.7 * REM, 3.1 * REM))
	for t: Label in _start_titles:
		t.add_theme_font_size_override("font_size", title_size)
	_start_title_wrap.custom_minimum_size = Vector2(0, float(title_size) * 1.3)

	var card_size := int(clampf(2.2 * vw, 0.85 * REM, 1.15 * REM))
	var safe_w := maxf(1.0, vs.x - SAFE_MARGIN * 2.0)
	var safe_h := maxf(1.0, vs.y - SAFE_MARGIN * 2.0)
	var card_w := minf(760.0, safe_w)
	for l: Label in [_card_text, _fail_text]:
		l.add_theme_font_size_override("font_size", card_size)
		l.add_theme_constant_override("line_spacing", card_size)
		l.custom_minimum_size = Vector2(card_w, 0)

	# Карточка старта скроллится: девять строк управления не влезают в 720p.
	var start_w := minf(680.0, safe_w)
	_start_col.custom_minimum_size = Vector2(start_w, 0)
	_start_scroll.custom_minimum_size = Vector2(start_w,
		minf(safe_h, _start_col.get_combined_minimum_size().y))
	_start_grid.columns = 1 if start_w < 520.0 else (2 if start_w < 660.0 else 3)

	_place(_pause_scroll, SAFE_MARGIN, SAFE_MARGIN, safe_w, safe_h)
	_pause_holder.custom_minimum_size = Vector2.ZERO
	_pause_card.custom_minimum_size = Vector2(minf(420.0, safe_w), 0)

	_place(_reader_scroll, SAFE_MARGIN, SAFE_MARGIN, safe_w, safe_h)
	_reader_holder.custom_minimum_size = Vector2.ZERO
	var paper_w := minf(560.0, safe_w)
	_paper.custom_minimum_size = Vector2(paper_w, 0)
	_reader_body.custom_minimum_size = Vector2(maxf(1.0, paper_w - 84.0), 0)

	_place(_photo_scroll, SAFE_MARGIN, SAFE_MARGIN, safe_w, safe_h)
	_photo_holder.custom_minimum_size = Vector2.ZERO
	_photo_caption.custom_minimum_size = Vector2(minf(560.0, safe_w), 0)
	_layout_photo(safe_w)

	_place_debug()


func _place_debug() -> void:
	if _debug == null or _root == null:
		return
	var vs := _root.size
	if vs.x <= 0.0:
		return
	var m := _debug.get_combined_minimum_size()
	_debug.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_debug.size = m
	_debug.position = Vector2(vs.x - vs.x * 0.01 - m.x, vs.y * 0.01)


# Абсолютное позиционирование: Control вне контейнера сам не растёт,
# поэтому нулевая ширина/высота означает «по минимальному размеру».
func _place(c: Control, x: float, y: float, w := 0.0, h := 0.0) -> void:
	c.set_anchors_preset(Control.PRESET_TOP_LEFT)
	var m := c.get_combined_minimum_size()
	var sw := m.x
	var sh := m.y
	if w > 0.0:
		sw = w
	if h > 0.0:
		sh = h
	c.position = Vector2(x, y)
	c.size = Vector2(sw, sh)


# ========================================================== строка задачи ===

# Chapters.pushTask() зовёт это после КАЖДОГО события, а не только на смену
# цели: задача выводится из флагов и пересчитывается на каждом осмотре.
# Раньше от этого вспышка перезапускалась тем же текстом и мигала на ровном
# месте. Сравниваем с прошлым текстом: постоянную строку обновляем всегда,
# вспышку трогаем, только если формулировка правда другая.
func setTask(text: Variant) -> void:
	if text == null or String(text) == "":
		clearTask()
		return
	var s := String(text)
	var changed := true
	if _lastTask != null:
		changed = s != String(_lastTask)
	_lastTask = s
	_task_line.visible = true
	_task_line.text = s
	if changed:
		showTask()


## Вспышка по центру: смена цели и повтор по Tab.
func showTask() -> void:
	if _lastTask == null:
		return
	_objective.visible = true
	_objective.modulate.a = 1.0
	_objective.text = String(_lastTask)
	_objTimer = 6.0


# Задач больше нет (пролог, финал, перезапуск). Гасим и строку, и вспышку:
# висящая строка от прошлого прохождения читается как невыполненная цель.
func clearTask() -> void:
	_lastTask = null
	_objTimer = 0.0
	_objective.visible = false
	_task_line.visible = false
	_task_line.text = ""


## HUD игры на время кассеты: прицел, REC и таймкод относятся к тому,
## что снаружи телевизора, и поверх записи читаются как часть записи.
func setTapeMode(on: bool) -> void:
	_tape_mode = on
	_sync_hud()


# ---------- субтитр и всплывающая строка ----------

## prio — кто кого перебивает в строке субтитра (фаза 5). Порядок обратен звуку:
## телефон и кассета (2) важнее деда (1), дед важнее внутреннего монолога (0).
## Без гарда случайный взгляд на предмет посреди реплики деда подменял бы
## субтитр — осмотры срабатывают постоянно, а реплика идёт три секунды.
## Все прежние вызовы обходятся без третьего аргумента и работают как раньше.
func say(text: String, seconds := 4.0, prio := 0) -> void:
	if _subTimer > 0.0 and prio < _subPrio:
		return
	_subPrio = prio
	_subtitle.visible = true
	_subtitle.modulate.a = 1.0
	_subtitle.text = text
	_subTimer = seconds


func toast(text: String, seconds := 3.0) -> void:
	_toast_row.visible = true
	_toast_row.modulate.a = 1.0
	_toast_label.text = text
	_toastTimer = seconds


# ---------- подсказка взаимодействия ----------

func setPrompt(key: Variant, text: Variant) -> void:
	if text == null or String(text) == "":
		_prompt.visible = false
		return
	_prompt.visible = true
	_prompt_key.text = String(key) if key != null else "E"
	_prompt_text.text = String(text)


func setClock(text: String) -> void:
	_clock_label.text = text


func setChapterTag(text: Variant) -> void:
	_chapter_tag.text = String(text) if text != null else ""


# ---------- полноэкранные карточки ----------

## Показывает список карточек по одной. Пробел — дальше.
func showCards(pages: Array, on_done: Variant = null, auto_seconds := 0.0) -> void:
	card.queue = pages.duplicate()
	card.onDone = Callable()
	if on_done is Callable:
		card.onDone = on_done
	card.auto = auto_seconds
	card.open = true
	_cards.visible = true
	_sync_hud()
	_nextCard()


func _nextCard() -> void:
	if card.queue.is_empty():
		card.open = false
		_cards.visible = false
		_sync_hud()
		var cb := card.onDone
		card.onDone = Callable()
		if cb.is_valid():
			cb.call()
		return
	_card_text.text = String(card.queue.pop_front())
	_card_hint.visible = card.auto <= 0.0
	card.timer = card.auto


func advanceCard() -> void:
	if card.open:
		_nextCard()


# ---------- экран провала ----------

func showFail(text: String) -> void:
	_fail_text.text = text
	_fail.visible = true
	_sync_hud()


func hideFail() -> void:
	_fail.visible = false
	_sync_hud()


var failOpen: bool:
	get:
		return _fail != null and _fail.visible


# ---------- чтение записок и дневника ----------

# Заголовок берётся не из аргумента, а из reader.title — так было в оригинале,
# и вызывающие (interact.gd) везде зовут setReaderTitle() ПЕРЕД openReader().
# Порядок менять нельзя: иначе записка покажется под чужим заголовком.
func openReader(_title: Variant, pages: Variant, on_close: Variant = null) -> void:
	reader.open = true
	if pages is Array:
		var src: Array = pages
		reader.pages = src.duplicate()
	else:
		reader.pages = [String(pages)]
	reader.index = 0
	reader.onClose = Callable()
	if on_close is Callable:
		reader.onClose = on_close
	_reader_screen.visible = true
	_renderReader()
	if audio != null:
		audio.sfx("paper-open")


func _renderReader() -> void:
	var n := reader.pages.size()
	_reader_title.text = reader.title
	_reader_body.text = String(reader.pages[reader.index]) if n > 0 else ""
	_reader_page.text = ("%d / %d   [← →]" % [reader.index + 1, n]) if n > 1 else ""


func setReaderTitle(t: Variant) -> void:
	reader.title = String(t) if t != null else ""
	if reader.open:
		_reader_title.text = reader.title


func pageReader(dir: int) -> void:
	if not reader.open or reader.pages.size() < 2:
		return
	var was := reader.index
	reader.index = maxi(0, mini(reader.pages.size() - 1, reader.index + dir))
	_renderReader()
	# На крайней странице индекс не двигается — шелестеть там нечем.
	if audio != null and reader.index != was:
		audio.sfx("paper-page")


func closeReader() -> void:
	if not reader.open:
		return
	reader.open = false
	_reader_screen.visible = false
	var cb := reader.onClose
	reader.onClose = Callable()
	if cb.is_valid():
		cb.call()


# ---------- фотография в руках ----------

## Показать снимок крупно. Размер карточки считается от пропорции текстуры:
## горизонтальная фотография в вертикальной рамке смотрится обрезанной, даже
## когда сама не обрезана.
func openPhoto(tex: Texture2D, caption: String, id := "",
		on_close: Variant = null) -> void:
	if tex == null:
		return
	photo.open = true
	photo.id = id
	photo.onClose = Callable()
	if on_close is Callable:
		photo.onClose = on_close
	_photo_rect.texture = tex
	_photo_caption.text = caption
	_photo_screen.visible = true
	_layout()
	if audio != null:
		audio.sfx("paper-open")


func _layout_photo(safe_w: float) -> void:
	if _photo_rect == null or _photo_rect.texture == null:
		return
	var s := _photo_rect.texture.get_size()
	var long_side := minf(460.0, maxf(1.0, safe_w - 28.0))
	if s.x >= s.y and s.y > 0.0:
		_photo_rect.custom_minimum_size = Vector2(long_side, long_side * s.y / s.x)
	elif s.x > 0.0:
		_photo_rect.custom_minimum_size = Vector2(long_side * s.x / s.y, long_side)
	_photo_rect.size = _photo_rect.custom_minimum_size


func closePhoto() -> void:
	if not photo.open:
		return
	photo.open = false
	_photo_screen.visible = false
	_photo_rect.texture = null
	var cb := photo.onClose
	photo.onClose = Callable()
	if cb.is_valid():
		cb.call()


var busy: bool:
	get:
		return reader.open or card.open or failOpen or scareOpen or photo.open


# ---------- экраны загрузки, старта и паузы ----------

## Порт progress() из main.js: доля 0..1 и подпись под полосой.
func setProgress(p: float, label := "") -> void:
	_bar_fill.anchor_right = clampf(p, 0.0, 1.0)
	_bar_fill.offset_right = 0.0
	if label != "":
		_load_label.text = label


func showLoadScreen(on: bool) -> void:
	_load.visible = on


func showStartScreen(on: bool, eyebrow := "") -> void:
	_start.visible = on
	if eyebrow != "":
		_start_eyebrow.text = eyebrow


func showPauseScreen(on: bool) -> void:
	# На паузе HUD уходит совсем: экран паузы кроет его непрозрачностью 0.93,
	# и сквозь меню проступала мигающая точка REC.
	_pause.visible = on
	_sync_hud()


func showHud(on: bool) -> void:
	_hud_on = on
	_sync_hud()


func _sync_hud() -> void:
	_hud.visible = _hud_on and not _tape_mode and not _pause.visible \
		and not card.open and not failOpen


# ---------- батарея, подсказка захвата мыши, отладка ----------

func setBattery(owned: bool, battery: float) -> void:
	_battery.visible = owned
	if owned:
		_battery_text.text = "ФОНАРЬ %d%%" % int(ceil(battery))


func setHeldItem(label: String) -> void:
	if _held_name != null and _held_name.text != label:
		_held_name.text = label


func setLockHint(on: bool) -> void:
	_lock_row.visible = on


func setDebug(text: String) -> void:
	_debug_text.text = text
	_place_debug()


func showDebug(on: bool) -> void:
	_debug.visible = on
	if on:
		_place_debug()


# ---------- настройки паузы ----------

## Значения ползунков без выброса сигналов: main.gd синхронизирует меню
## с тем, что уже стоит в модулях (громкость, скримеры из конфига).
func setSettings(values: Dictionary) -> void:
	if values.has("sens"):
		_sens.set_value_no_signal(float(values["sens"]))
		_sens_out.text = "%.2f" % _sens.value
	if values.has("smooth"):
		_smooth.set_value_no_signal(float(values["smooth"]))
		_smooth_out.text = "%d%%" % int(round(_smooth.value * 100.0))
	if values.has("volume"):
		_vol.set_value_no_signal(float(values["volume"]))
		_vol_out.text = "%d%%" % int(round(_vol.value * 100.0))
	if values.has("invert"):
		_invert.set_pressed_no_signal(bool(values["invert"]))
	if values.has("scares"):
		_scares.set_pressed_no_signal(bool(values["scares"]))
	if values.has("brightness"):
		_bright.set_value_no_signal(clampf(float(values["brightness"]), BRIGHT_MIN, BRIGHT_MAX))
		_bright_out.text = "%.2f" % _bright.value
	if values.has("sharpness"):
		_sharp_idx = clampi(int(values["sharpness"]), 0, SHARPNESS.size() - 1)
		_sharp.text = String(SHARPNESS[_sharp_idx]["label"])


func settings() -> Dictionary:
	return {
		"sens": _sens.value,
		"smooth": _smooth.value,
		"volume": _vol.value,
		"invert": _invert.button_pressed,
		"scares": _scares.button_pressed,
		"brightness": _bright.value,
		"sharpness": _sharp_idx,
	}


# ============================================================ покадровое ===

func update(dt: float) -> void:
	_clock += dt

	# REC: 0–55% периода горит, дальше почти гаснет (blink 1.6s steps(1)).
	_rec_dot.modulate.a = 1.0 if fmod(_clock, 1.6) < 0.88 else 0.15
	# Подсказка карточки дышит (pulse 2.4s ease-in-out).
	var pulse := 0.35 + 0.55 * (1.0 - cos(TAU * _clock / 2.4)) * 0.5
	_card_hint.modulate.a = pulse
	_fail_hint.modulate.a = pulse

	if _objTimer > 0.0:
		_objTimer -= dt
		_objective.modulate.a = clampf(_objTimer / 0.6, 0.0, 1.0)
		if _objTimer <= 0.0:
			_objective.visible = false
	if _subTimer > 0.0:
		_subTimer -= dt
		_subtitle.modulate.a = clampf(_subTimer / 0.35, 0.0, 1.0)
		if _subTimer <= 0.0:
			# Приоритет сбрасывается вместе с таймером, иначе он залипает
			# на двойке и субтитры пропадают до конца прохождения.
			_subPrio = 0
			_subtitle.visible = false
	if _toastTimer > 0.0:
		_toastTimer -= dt
		_toast_row.modulate.a = clampf(_toastTimer / 0.4, 0.0, 1.0)
		if _toastTimer <= 0.0:
			_toast_row.visible = false

	if card.open and card.auto > 0.0:
		card.timer -= dt
		if card.timer <= 0.0:
			_nextCard()

	# Прицел разбухает и светлеет на цели — transition 0.12s из style.css.
	var want := 2.1 if _prompt.visible else 1.0
	_cross += (want - _cross) * (1.0 - exp(-dt * 12.0))
	_crosshair.scale = Vector2(_cross, _cross)
	_cross_box.bg_color = Color(0.902, 0.886, 0.839, 0.5).lerp(
		Color(0.941, 0.886, 0.745, 0.92), clampf((_cross - 1.0) / 1.1, 0.0, 1.0))

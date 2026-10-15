# Кисть кассеты. Порт отрисовки из src/ui/tape.js: процедурные сцены (SCENES),
# растровые кадры, фигуры (drawActor), перенос кадра полосами (_blit),
# экранное меню камкордера (_osd) и те артефакты плёнки, которые в оригинале
# рисовались прямоугольниками (_artifacts, _headSwitch).
#
# Один класс на четыре роли, потому что все четыре — это один и тот же кадр
# 320x240 на разных этажах цепочки вьюпортов (кто в каком, собирает
# tape_player.gd):
#
#   ROLE_CLEAN  — чистый кадр: фотография либо процедурная сцена плюс фигуры.
#   ROLE_STRIPS — 24 горизонтальные полосы чистого кадра со сдвигом (wow/flutter).
#   ROLE_OSD    — меню камкордера, царапины, выпадения, полоса трекинга.
#   ROLE_HEAD   — чернота и шум в полосе перекоммутации головок; идёт поверх
#                 шейдера плёнки, потому что шейдер эту полосу и сдвигает.
#
# Состояние узел не считает, а получает: tape_player.gd раскладывает поля
# перед queue_redraw(). Так формулы кадра остались в одном месте (плеер),
# а здесь — только рисование, и обе стороны проверяются компилятором.
#
# Канва и Godot расходятся в трёх мелочах, и все три учтены:
#   — градиенты канвы интерполируются в premultiplied-alpha, Godot — в прямой.
#     Разница видна только на переходе «в прозрачность», поэтому у прозрачных
#     стопов RGB взят от соседнего стопа, а не чёрный, как в CSS-записи;
#   — createRadialGradient с внутренним радиусом r0 задаётся смещением стопов:
#     GradientTexture2D умеет один радиус, поэтому o' = (r0 + o*(r1-r0)) / r1;
#   — canvas сглаживает дробные края прямоугольников, Godot нет. На 320x240
#     под зерном и строчками разница не читается, а лишний проход стоил бы
#     больше самой картинки.

class_name TapeDraw
extends Node2D

enum { ROLE_CLEAN, ROLE_STRIPS, ROLE_OSD, ROLE_HEAD }

const W := 320.0
const H := 240.0

# Полос wow/flutter на кадр — комментарий оригинала: 24 — предел, за которым
# разъезд строк уже не читается, а вызовов отрисовки вдвое больше.
const STRIPS := 24

# Строк перекоммутации головок у нижней кромки: подпись формата VHS.
const HEAD := 8.0

# Меню камкордера набрано 11px PT Mono — как в оригинале.
const OSD_SIZE := 11

# Лицо соседа: единственное место во всей игре, где его видно.
const FACE_PATH := "res://assets/face/arkady.webp"

const OSD_INK := Color(236.0 / 255.0, 232.0 / 255.0, 218.0 / 255.0, 0.92)
const OSD_SHADOW := Color(0.0, 0.0, 0.0, 0.85)
const OSD_REC := Color(212.0 / 255.0, 74.0 / 255.0, 58.0 / 255.0, 0.95)

var role := ROLE_CLEAN

# --- общее ---
var t := 0.0
var wow_amp := 1.1

# --- ROLE_CLEAN ---
var tint := Color(0.627451, 0.603922, 0.525490)  # '#a09a86' по умолчанию
var scene := "dark"
var shot_tex: Texture2D = null
var acts: Array = []

# --- ROLE_STRIPS ---
var source: Texture2D = null
var zoom := 1.04
var move_px := 0.0
var move_py := 0.0
var shake_x := 0.0
var shake_y := 0.0

# --- ROLE_OSD ---
var font: Font = null
var counter := ""
var clock := ""
var date := ""
var rec := false
var scratches: Array = []
var drops: Array = []
var band_y := -100.0

# --- ROLE_HEAD ---
var head_shift := 3.0
var head_lines: Array = []

# Градиенты канвы: цвета и стопы не меняются, поэтому текстура строится один раз.
var _grads: Dictionary = {}

# Лицо соседа. Грузится лениво и один раз: до кассет оно не нужно, а если
# файла нет — сцена рисует ту же голову прямоугольниками и кассета не ломается.
var _face_tex: Texture2D = null
var _face_tried := false


func _draw() -> void:
	match role:
		ROLE_CLEAN:
			_draw_clean()
		ROLE_STRIPS:
			_draw_strips()
		ROLE_OSD:
			_draw_osd()
		ROLE_HEAD:
			_draw_head()

# ---------------------------------------------------------------- кадр ---

## Чистый кадр: фотография либо процедурная сцена, поверх — фигуры.
func _draw_clean() -> void:
	if shot_tex != null:
		draw_texture_rect(shot_tex, Rect2(0.0, 0.0, W, H), false)
		# Фотография и процедурная сцена должны сидеть в одной палитре: склейка
		# между ними на несгенерированном кадре иначе бьёт по глазам.
		_wash(tint, 0.10)
	else:
		_fill(0.0, 0.0, W, H, _hex("#0a0a09"))
		_scene(scene)

	for a in acts:
		var dur: float = maxf(0.0001, float(a["dur"]))
		var q: float = minf(1.0, (t - float(a["t0"])) / dur)
		if q >= 1.0:
			continue
		var from: float = float(a["from"])
		var to: float = float(a["to"])
		_actor(String(a["who"]), from + (to - from) * q)

# -------------------------------------------------------------- полосы ---

## Перенос чистого кадра на видимую канву: движение камеры плюс wow/flutter.
##
## Лента идёт неровно, и строки внутри кадра разъезжаются по горизонтали.
## Полосы нарезаем по строкам НАЗНАЧЕНИЯ и обратным пересчётом берём исходный
## прямоугольник — тогда между полосами не остаётся щелей при любом масштабе.
func _draw_strips() -> void:
	_fill(0.0, 0.0, W, H, Color.BLACK)
	if source == null:
		return

	var dw := W * zoom
	var dh := H * zoom
	var dx := (W - dw) * 0.5 + move_px + shake_x
	var dy := (H - dh) * 0.5 + move_py + shake_y

	for i in STRIPS:
		var y0 := roundf(float(i) * H / float(STRIPS))
		var y1 := roundf(float(i + 1) * H / float(STRIPS))
		var sy0 := maxf(0.0, ((y0 - dy) / dh) * H)
		var sy1 := minf(H, ((y1 - dy) / dh) * H)
		if sy1 - sy0 < 0.01:
			continue
		var wow := sin(y0 * 0.06 + t * 3.0) * wow_amp
		draw_texture_rect_region(
			source,
			Rect2(dx + wow, dy + (sy0 / H) * dh, dw, ((sy1 - sy0) / H) * dh),
			Rect2(0.0, sy0, W, sy1 - sy0))

# ----------------------------------------------------------------- меню ---

## Экранное меню камкордера: дата, часы, счётчик ленты, REC, скорость.
## Плюс артефакты, которые в оригинале рисовались прямоугольниками:
## царапины, выпадения ленты и полоса трекинга.
func _draw_osd() -> void:
	# Меню камера подмешала в сигнал ДО того, как он лёг на ленту, поэтому
	# на воспроизведении оно ведёт вместе со строками кадра — тот же wow,
	# что и у картинки, но без наезда: наезд был на объективе, а меню
	# рисовалось после него.
	var top := _wow(14.0)
	if rec:
		draw_circle(Vector2(20.0 + top, 17.0), 4.0, OSD_REC)
	_text("REC", 29.0 + top, 12.0, false)
	_text("SP", W - 14.0 + top, 12.0, true)
	_text(counter, W - 14.0 + _wow(26.0), 26.0, true)
	_text(clock, W - 14.0 + _wow(H - 42.0), H - 42.0, true)
	_text(date, W - 14.0 + _wow(H - 28.0), H - 28.0, true)

	# Продольные царапины: лента протёрта в одних и тех же местах и на одной
	# кассете с кадра на кадр не переезжает.
	for s in scratches:
		var x: float = float(s["x"])
		_fill(x, 0.0, 1.0, H, Color(226.0 / 255.0, 222.0 / 255.0, 208.0 / 255.0, float(s["a"])))
		_fill(x + 1.0, 0.0, 1.0, H, Color(0.0, 0.0, 0.0, 0.26))

	# Выпадения ленты: осыпавшийся оксид не даёт сигнала, и головка пишет
	# белый штрих в несколько строк.
	for d in drops:
		var c := Color(238.0 / 255.0, 236.0 / 255.0, 226.0 / 255.0, 0.75)
		if not bool(d["light"]):
			c = Color(0.0, 0.0, 0.0, 0.55)
		_fill(float(d["x"]), float(d["y"]), float(d["w"]), float(d["h"]), c)

	# Полоса трекинга ползёт вверх.
	_fill(0.0, band_y, W, 14.0, Color(220.0 / 255.0, 220.0 / 255.0, 210.0 / 255.0, 0.10))
	_fill(0.0, band_y + 14.0, W, 4.0, Color(0.0, 0.0, 0.0, 0.30))


func _wow(y: float) -> float:
	return sin(y * 0.06 + t * 3.0) * wow_amp


## Тень в один пиксель: на светлом кадре белые буквы иначе тонут. У канвы
## shadowBlur остался нулём, поэтому это ровно смещённая копия, а не размытие.
func _text(s: String, x: float, y_top: float, right: bool) -> void:
	if font == null or s.is_empty():
		return
	var px := x
	if right:
		px -= font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, OSD_SIZE).x
	# textBaseline = 'top' у канвы: y — верх строки, а draw_string ставит базовую.
	var y := y_top + font.get_ascent(OSD_SIZE)
	draw_string(font, Vector2(px + 1.0, y + 1.0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, OSD_SIZE, OSD_SHADOW)
	draw_string(font, Vector2(px, y), s, HORIZONTAL_ALIGNMENT_LEFT, -1, OSD_SIZE, OSD_INK)

# -------------------------------------------------------------- головки ---

## Перекоммутация головок, часть поверх шейдера: сам сдвиг нижних строк делает
## tape_fx.gdshader, здесь — чернота на непокрытой сдвигом кромке, строчный шум
## и шов между полем и полосой, по которому её и опознают.
func _draw_head() -> void:
	var y := H - HEAD
	_fill(0.0, y, head_shift, HEAD, Color(0.0, 0.0, 0.0, 0.75))
	for l in head_lines:
		var c := Color(226.0 / 255.0, 224.0 / 255.0, 214.0 / 255.0, 0.35)
		if not bool(l["light"]):
			c = Color(0.0, 0.0, 0.0, 0.45)
		_fill(float(l["x"]), y + float(l["y"]), float(l["w"]), 1.0, c)
	_fill(0.0, y - 1.0, W, 1.0, Color(0.0, 0.0, 0.0, 0.5))

# ------------------------------------------------------------- примитивы ---

func _fill(x: float, y: float, w: float, h: float, c: Color) -> void:
	draw_rect(Rect2(x, y, w, h), c)


func _hex(s: String) -> Color:
	return Color.html(s)


func _rgba(r: float, g: float, b: float, a: float) -> Color:
	return Color(r / 255.0, g / 255.0, b / 255.0, a)


func _poly(points: PackedVector2Array, c: Color) -> void:
	draw_colored_polygon(points, c)


## Эллипс канвы: у Godot есть только круг, поэтому считаем многоугольник.
func _ellipse(cx: float, cy: float, rx: float, ry: float, c: Color) -> void:
	var pts := PackedVector2Array()
	for i in 32:
		var a := TAU * float(i) / 32.0
		pts.append(Vector2(cx + cos(a) * rx, cy + sin(a) * ry))
	draw_colored_polygon(pts, c)


func _wash(c: Color, a: float) -> void:
	_fill(0.0, 0.0, W, H, Color(c.r, c.g, c.b, a))


## Вертикальный (или горизонтальный) градиент канвы. Заливка идёт в тот же
## прямоугольник, в котором он объявлен, поэтому текстуре хватает одной строки.
func _linear_grad(key: String, offsets: PackedFloat32Array, colors: PackedColorArray, horizontal: bool) -> GradientTexture2D:
	if _grads.has(key):
		return _grads[key]
	var g := Gradient.new()
	g.offsets = offsets
	g.colors = colors
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_LINEAR
	if horizontal:
		tex.width = 256
		tex.height = 1
		tex.fill_from = Vector2(0.0, 0.0)
		tex.fill_to = Vector2(1.0, 0.0)
	else:
		tex.width = 1
		tex.height = 256
		tex.fill_from = Vector2(0.0, 0.0)
		tex.fill_to = Vector2(0.0, 1.0)
	_grads[key] = tex
	return tex


## Радиальный градиент канвы с внутренним радиусом. GradientTexture2D знает
## только один радиус, поэтому внутренний уезжает в смещения стопов, а рисуется
## текстура квадратом со стороной 2*r1 — за ним последний стоп всё равно
## прозрачный, и заливать весь кадр незачем.
func _radial_grad(key: String, offsets: PackedFloat32Array, colors: PackedColorArray, r0: float, r1: float) -> GradientTexture2D:
	if _grads.has(key):
		return _grads[key]
	var mapped := PackedFloat32Array()
	for o in offsets:
		mapped.append((r0 + o * (r1 - r0)) / r1)
	var g := Gradient.new()
	g.offsets = mapped
	g.colors = colors
	var tex := GradientTexture2D.new()
	tex.gradient = g
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.width = 128
	tex.height = 128
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 1.0)
	_grads[key] = tex
	return tex


func _draw_radial(tex: GradientTexture2D, cx: float, cy: float, r1: float, tone := Color.WHITE) -> void:
	draw_texture_rect(tex, Rect2(cx - r1, cy - r1, r1 * 2.0, r1 * 2.0), false, tone)

# ---------------------------------------------------------------- фигуры ---

# Фаза 8: это откат. Пока в tape_shots.json есть кадр под событие act
# («<сцена>:<кто>»), плеер фигуру сюда не отдаёт вовсе — в кадре стоит
# настоящая собака, поднимающая голову в объектив. Без оверлея всё как было.
func _actor(who: String, x: float) -> void:
	var px := W * x
	if who == "man":
		var c := _hex("#050607")
		_fill(px - 16.0, H * 0.20, 32.0, H * 0.66, c)
		_fill(px - 10.0, H * 0.13, 20.0, H * 0.09, c)
	elif who == "dog":
		var c := _hex("#1b1a16")
		_fill(px - 20.0, H * 0.70, 40.0, 16.0, c)
		_fill(px + 12.0, H * 0.66, 14.0, 12.0, c)
	elif who == "hand":
		var c := _hex("#6a5344")
		_fill(px - 8.0, H * 0.36, 60.0, 16.0, c)
		_fill(px + 44.0, H * 0.34, 22.0, 22.0, c)

# ---------------------------------------------------------------- сцены ---
# Процедурные сцены. Откат на случай, если кадров нет: те же места, набранные
# прямоугольниками. Домашняя съёмка 1986–2003 в темноте и правда выглядит
# размытым пятном, так что откат читается записью, а не заглушкой.
# Сцены dark и face-photo кадров не имеют вовсе — они рисуются всегда.

func _scene(id: String) -> void:
	match id:
		"kitchen":
			_scene_kitchen()
		"face-photo":
			_scene_face()
		"yard":
			_scene_yard()
		"behind-shed":
			_scene_behind_shed()
		"doorway":
			_scene_doorway()
		"fridge-open":
			_scene_fridge()
		"loft":
			_scene_loft()
		"loft-tv":
			_scene_loft_tv()
		"rafters":
			_scene_rafters()
		"bedroom":
			_scene_bedroom()
		"corridor":
			_scene_corridor()
		"vitya-sleeping":
			_scene_vitya()
		_:
			_scene_dark()


## Доски забора в переднем плане. Снимают из-за него: край кадра всегда
## перекрыт, и это первое, по чему видно, что смотришь чужими глазами.
func _slats(a: float) -> void:
	var c := _rgba(8.0, 8.0, 7.0, a)
	_fill(0.0, 0.0, W * 0.09, H, c)
	_fill(W * 0.93, 0.0, W * 0.07, H, c)
	_fill(W * 0.16 + sin(t * 0.4) * 1.5, 0.0, 5.0, H, _rgba(8.0, 8.0, 7.0, a * 0.7))


## Темнота и луч фонаря. Фонарь в той же руке, что камера, поэтому пятно
## гуляет; в луче стоит пыль — больше в такой темноте не видно ничего.
func _scene_dark() -> void:
	_fill(0.0, 0.0, W, H, _hex("#0b0b0a"))
	var cx := W * 0.5 + sin(t * 0.8) * 42.0
	var cy := H * 0.55 + cos(t * 0.62) * 16.0
	var beam := _radial_grad("beam",
		PackedFloat32Array([0.0, 0.55, 1.0]),
		PackedColorArray([
			_rgba(206.0, 200.0, 176.0, 0.30),
			_rgba(160.0, 156.0, 138.0, 0.10),
			_rgba(160.0, 156.0, 138.0, 0.0)]),
		6.0, 96.0)
	_draw_radial(beam, cx, cy, 96.0)
	var dust := _rgba(220.0, 214.0, 190.0, 0.22)
	for i in 14:
		var a := float(i) * 1.7 + t * 0.6
		_fill(cx + cos(a) * (18.0 + float(i) * 5.0), cy + sin(a * 1.3) * (12.0 + float(i) * 3.0), 1.0, 1.0, dust)


## Кухня. Кадр служит и первой кассете (снято с улицы, лампа бьёт в объектив),
## и кассете без этикетки, где по кухне идут изнутри: в обоих случаях в кадре
## окно, стол и человек за ним.
func _scene_kitchen() -> void:
	_fill(0.0, 0.0, W, H, _hex("#1a1813"))
	_fill(0.0, H * 0.74, W, H * 0.26, _hex("#221f18"))
	_fill(W * 0.06, H * 0.10, W * 0.88, H * 0.66, _hex("#2d2921"))
	_fill(W * 0.14, H * 0.18, W * 0.70, H * 0.46, _hex("#6b5c3c"))

	# Тюль: свет через него садится к краям окна.
	var sheer := _linear_grad("sheer",
		PackedFloat32Array([0.0, 1.0]),
		PackedColorArray([_rgba(255.0, 240.0, 198.0, 0.42), _rgba(120.0, 104.0, 70.0, 0.30)]),
		false)
	draw_texture_rect(sheer, Rect2(W * 0.14, H * 0.18, W * 0.70, H * 0.46), false)

	# Переплёт и отлив.
	var frame := _hex("#171410")
	_fill(W * 0.485, H * 0.18, 4.0, H * 0.46, frame)
	_fill(W * 0.14, H * 0.36, W * 0.70, 3.0, frame)
	_fill(W * 0.12, H * 0.63, W * 0.74, 5.0, _hex("#3a3428"))

	# Он за столом. Двигается ровно настолько, чтобы кадр читался живым.
	var bob := sin(t * 1.4) * 1.5
	var man := _hex("#12100c")
	_fill(W * 0.30, H * 0.30 + bob, W * 0.13, H * 0.30, man)
	_fill(W * 0.315, H * 0.245 + bob, W * 0.10, H * 0.07, man)

	var glow := _radial_grad("kitchen-glow",
		PackedFloat32Array([0.0, 1.0]),
		PackedColorArray([_rgba(255.0, 248.0, 220.0, 0.95), _rgba(255.0, 240.0, 200.0, 0.0)]),
		3.0, 78.0)
	_draw_radial(glow, W * 0.63, H * 0.26, 78.0)

	_wash(tint, 0.14)


## Кадр, на котором сосед разворачивает камеру на себя. Дрожание — не украшение:
## камеру он держит на вытянутой руке, и кадр обязан гулять.
func _scene_face() -> void:
	_load_face()
	_fill(0.0, 0.0, W, H, _hex("#171410"))
	if _face_tex != null:
		var s := 1.0 + sin(t * 0.7) * 0.03
		var side := H * 0.92 * s
		draw_texture_rect(_face_tex, Rect2(
			(W - side) * 0.5 + sin(t * 2.3) * 2.5,
			(H - side) * 0.5 + cos(t * 1.7) * 2.0,
			side, side), false)
	else:
		_fill(W * 0.34, H * 0.22, W * 0.32, H * 0.46, _hex("#8a6a52"))
		_fill(W * 0.32, H * 0.18, W * 0.36, H * 0.11, _hex("#3a2c22"))
		var eye := _hex("#1a1410")
		_fill(W * 0.40, H * 0.38, W * 0.06, H * 0.03, eye)
		_fill(W * 0.54, H * 0.38, W * 0.06, H * 0.03, eye)
	_wash(tint, 0.22)


func _load_face() -> void:
	if _face_tried:
		return
	_face_tried = true
	if not ResourceLoader.exists(FACE_PATH):
		return
	var res: Variant = load(FACE_PATH)
	if res is Texture2D:
		_face_tex = res


## Двор в полдень, снято между досок забора.
func _scene_yard() -> void:
	var sky := _linear_grad("yard-sky",
		PackedFloat32Array([0.0, 1.0]),
		PackedColorArray([_rgba(150.0, 163.0, 132.0, 1.0), _rgba(112.0, 126.0, 96.0, 1.0)]),
		false)
	draw_texture_rect(sky, Rect2(0.0, 0.0, W, H * 0.46), false)

	# Полоса леса за участком.
	var forest := _hex("#3f4c31")
	for i in 16:
		_fill(float(i) * 21.0 - 6.0, H * 0.30 + float((i * 37) % 11), 22.0, H * 0.18, forest)

	_fill(0.0, H * 0.45, W, H * 0.55, _hex("#54603c"))

	# Сарай со скатом и приоткрытой дверью.
	_fill(W * 0.60, H * 0.20, W * 0.32, H * 0.34, _hex("#4a4335"))
	_fill(W * 0.58, H * 0.17, W * 0.36, H * 0.05, _hex("#39332a"))
	_fill(W * 0.70, H * 0.32, W * 0.09, H * 0.22, _hex("#241f18"))

	# Тропа к сараю: по ней ходят, и трава там вытоптана.
	_poly(PackedVector2Array([
		Vector2(W * 0.72, H * 0.54),
		Vector2(W * 0.80, H * 0.54),
		Vector2(W * 0.52, H),
		Vector2(W * 0.24, H)]), _rgba(120.0, 110.0, 84.0, 0.45))

	var grass := _hex("#3d4a30")
	for i in 46:
		var x := float((i * 37) % int(W))
		var y := H * 0.52 + float((i * 53) % 90)
		_fill(x + sin(t * 1.1 + float(i)) * 1.2, y, 2.0, 6.0 + float(i % 4) * 3.0, grass)

	_slats(0.34)
	_wash(tint, 0.12)


## За сараем: стена вплотную слева, бурьян по пояс, крышка погреба.
func _scene_behind_shed() -> void:
	_fill(0.0, 0.0, W, H, _hex("#3b4630"))
	_fill(0.0, 0.0, W, H * 0.34, _hex("#4e5a3a"))

	_fill(0.0, 0.0, W * 0.44, H, _hex("#2b271e"))
	var seam := Color(0.0, 0.0, 0.0, 0.35)
	var x := 0.0
	while x < W * 0.44:
		_fill(x, 0.0, 2.0, H, seam)
		x += 14.0

	_fill(W * 0.48, H * 0.62, W * 0.34, H * 0.16, _hex("#5a5240"))
	_fill(W * 0.46, H * 0.59, W * 0.38, 4.0, _hex("#6a6248"))
	_fill(W * 0.62, H * 0.64, W * 0.06, 3.0, _hex("#231f18"))

	# Земля у крышки свежая: там рыли.
	_ellipse(W * 0.66, H * 0.80, 42.0, 13.0, _rgba(96.0, 82.0, 58.0, 0.55))

	var weeds := _hex("#2f3a24")
	for i in 34:
		var wx := W * 0.44 + fmod(float(i * 29), W * 0.56)
		var h := 14.0 + float(i % 5) * 7.0
		_fill(wx + sin(t * 0.9 + float(i)) * 1.6, H - h - float((i * 17) % 40), 2.0, h, weeds)

	_wash(tint, 0.14)


## Камера стоит снаружи на подоконнике: в кадре проём кухонной двери
## и косой отблеск стекла, через которое снимают.
func _scene_doorway() -> void:
	_fill(0.0, 0.0, W, H, _hex("#0e100e"))
	_fill(W * 0.28, H * 0.14, W * 0.36, H * 0.74, _hex("#1b1e1a"))
	_fill(W * 0.31, H * 0.17, W * 0.30, H * 0.68, _hex("#080908"))

	var spill := _linear_grad("doorway-spill",
		PackedFloat32Array([0.0, 1.0]),
		PackedColorArray([_rgba(122.0, 118.0, 96.0, 0.30), _rgba(122.0, 118.0, 96.0, 0.0)]),
		false)
	draw_texture_rect(spill, Rect2(W * 0.24, H * 0.80, W * 0.44, H * 0.20), false)

	_fill(0.0, H * 0.84, W, H * 0.16, _hex("#1c1f1b"))

	# Отблеск стекла, через которое снимают: globalAlpha 0.07 у канвы.
	_poly(PackedVector2Array([
		Vector2(-20.0, H * 0.72),
		Vector2(W * 0.52, -20.0),
		Vector2(W * 0.74, -20.0),
		Vector2(W * 0.16, H)]), Color(207.0 / 255.0, 214.0 / 255.0, 204.0 / 255.0, 0.07))

	_wash(tint, 0.08)


## Открытый холодильник — единственный свет в доме в три часа ночи.
## Внутри всё вымыто и стоит рядами, и это хуже, чем беспорядок.
func _scene_fridge() -> void:
	_fill(0.0, 0.0, W, H, _hex("#0b0c0b"))

	var wedge := _linear_grad("fridge-wedge",
		PackedFloat32Array([0.0, 1.0]),
		PackedColorArray([_rgba(232.0, 238.0, 222.0, 0.88), _rgba(150.0, 160.0, 142.0, 0.04)]),
		true)
	draw_texture_rect(wedge, Rect2(W * 0.32, H * 0.14, W * 0.42, H * 0.72), false)

	var shelf := _rgba(40.0, 44.0, 38.0, 0.55)
	for i in 4:
		_fill(W * 0.33, H * (0.24 + float(i) * 0.15), W * 0.20, 3.0, shelf)
	var jars := _rgba(30.0, 34.0, 28.0, 0.5)
	for i in 6:
		_fill(W * (0.345 + float(i % 3) * 0.06), H * (0.20 + float(i / 3) * 0.30), 9.0, H * 0.04, jars)

	var lean := sin(t * 0.9) * 2.0
	var man := _hex("#06070a")
	_fill(W * 0.36 + lean, H * 0.20, W * 0.19, H * 0.66, man)
	_fill(W * 0.40 + lean, H * 0.12, W * 0.11, H * 0.09, man)
	# Рука ходит ко рту: он ест стоя, не отходя от дверцы.
	_fill(W * 0.53 + lean, H * 0.34 + sin(t * 2.6) * 4.0, W * 0.06, H * 0.05, man)

	_fill(0.0, H * 0.86, W, H * 0.14, _hex("#0d0f0d"))
	_wash(tint, 0.08)


## Чердак. Полоса из слухового окна — единственный свет, в ней стоит пыль.
func _scene_loft() -> void:
	_fill(0.0, 0.0, W, H, _hex("#0b0c0b"))

	_poly(PackedVector2Array([
		Vector2(W * 0.66, 0.0),
		Vector2(W * 0.88, 0.0),
		Vector2(W * 0.64, H),
		Vector2(W * 0.38, H)]), _rgba(196.0, 204.0, 192.0, 0.20))

	var dust := _rgba(214.0, 218.0, 206.0, 0.30)
	for i in 20:
		var q := fmod(float(i) * 0.137 + t * 0.03, 1.0)
		_fill(W * (0.42 + q * 0.42) + sin(t * 0.7 + float(i)) * 3.0, fmod(float(i) * 61.0 + t * 9.0, H), 1.0, 1.0, dust)

	var beam := _hex("#231f19")
	for i in 5:
		_fill(W * (0.08 + float(i) * 0.20), 0.0, 7.0, H, beam)
	_fill(0.0, H * 0.06, W, 5.0, _rgba(20.0, 18.0, 14.0, 0.7))

	# Матрас с подушкой и стопка коробок.
	_fill(W * 0.14, H * 0.66, W * 0.36, H * 0.14, _hex("#2a2620"))
	_fill(W * 0.16, H * 0.62, W * 0.30, H * 0.05, _rgba(58.0, 53.0, 44.0, 0.9))
	_fill(W * 0.04, H * 0.52, W * 0.11, H * 0.16, _hex("#312b22"))
	_fill(W * 0.05, H * 0.44, W * 0.09, H * 0.09, _hex("#3a332a"))

	_wash(tint, 0.10)


## Тот же чердак, но с работающим телевизором. Антенны нет: на экране снег,
## и он тут единственный источник света.
func _scene_loft_tv() -> void:
	_scene_loft()

	_fill(W * 0.54, H * 0.42, W * 0.26, H * 0.24, _hex("#1e2226"))
	var on := 0.42 + absf(sin(t * 6.1)) * 0.35
	_fill(W * 0.555, H * 0.445, W * 0.20, H * 0.16, _rgba(196.0, 212.0, 228.0, on))
	var scan := _rgba(30.0, 36.0, 40.0, 0.5)
	var y := H * 0.445
	while y < H * 0.605:
		_fill(W * 0.555, y, W * 0.20, 1.0, scan)
		y += 3.0

	# Отсвет телевизора: альфа ведёт яркость экрана, поэтому она в модуляции,
	# а не в самом градиенте — иначе текстуру пришлось бы печь каждый кадр.
	var cast := _radial_grad("loft-cast",
		PackedFloat32Array([0.0, 1.0]),
		PackedColorArray([_rgba(150.0, 172.0, 190.0, 1.0), _rgba(150.0, 172.0, 190.0, 0.0)]),
		6.0, 70.0)
	_draw_radial(cast, W * 0.66, H * 0.53, 70.0, Color(1.0, 1.0, 1.0, 0.16 * on))

	# Щётки зубные, штук десять, и вымытые банки в ряд.
	var brush := _hex("#8f8874")
	for i in 10:
		_fill(W * 0.22 + float(i) * 3.4, H * 0.54 - float(i % 3), 2.0, 13.0, brush)
	_fill(W * 0.21, H * 0.60, 38.0, H * 0.06, _rgba(150.0, 160.0, 150.0, 0.35))
	var jar := _rgba(168.0, 178.0, 166.0, 0.30)
	for i in 5:
		_fill(W * 0.84, H * (0.40 + float(i) * 0.09), 11.0, H * 0.07, jar)


## Камера упала и лежит объективом в стропила. Сходящиеся балки — не приём,
## а всё, что она с пола видит.
func _scene_rafters() -> void:
	_fill(0.0, 0.0, W, H, _hex("#0a0b0a"))

	var big := _hex("#2e2a22")
	for i in range(-2, 6):
		draw_line(Vector2(W * 0.5, H * 0.08), Vector2(float(i) * 70.0 - 40.0, H), big, 7.0)
	var small := _hex("#221f19")
	for i in range(1, 4):
		draw_line(Vector2(0.0, H * (0.18 + float(i) * 0.22)), Vector2(W, H * (0.10 + float(i) * 0.24)), small, 4.0)

	# Свет сквозь щели в кровле.
	var slit := _rgba(200.0, 206.0, 190.0, 0.22)
	for i in 7:
		_fill(W * (0.12 + float(i) * 0.13), H * (0.02 + float(i % 3) * 0.05), 2.0, 10.0 + float(i % 4) * 6.0, slit)

	# Пол внизу кадра и он не горизонтален: камера лежит косо.
	_poly(PackedVector2Array([
		Vector2(0.0, H * 0.86),
		Vector2(W, H * 0.72),
		Vector2(W, H),
		Vector2(0.0, H)]), _rgba(6.0, 7.0, 6.0, 0.85))

	_wash(tint, 0.06)


## Спальня. Кровать застелена, углы подоткнуты — в этом весь кадр.
func _scene_bedroom() -> void:
	_fill(0.0, 0.0, W, H, _hex("#0f100f"))

	# Обои в полоску: единственное, что читается на стене в такой темноте.
	var stripe := _rgba(38.0, 40.0, 36.0, 0.6)
	var x := 0.0
	while x < W:
		_fill(x, 0.0, 4.0, H * 0.62, stripe)
		x += 11.0

	_fill(W * 0.70, H * 0.10, W * 0.22, H * 0.30, _rgba(120.0, 132.0, 124.0, 0.16))
	_fill(W * 0.805, H * 0.10, 3.0, H * 0.30, _hex("#141614"))

	_fill(W * 0.12, H * 0.54, W * 0.74, H * 0.32, _hex("#1a1c1a"))
	_fill(W * 0.16, H * 0.48, W * 0.66, H * 0.09, _hex("#242724"))
	_fill(W * 0.28, H * 0.43, W * 0.17, H * 0.07, _hex("#2c2f2c"))
	_fill(W * 0.16, H * 0.62, W * 0.66, 2.0, Color(0.0, 0.0, 0.0, 0.35))
	_fill(W * 0.10, H * 0.82, W * 0.80, H * 0.05, _hex("#101210"))

	_wash(tint, 0.05)


## Коридор: стены сходятся, половицы сходятся туда же, в конце свет из кухни.
## По половицам и понятно, что камеру несут, а не поставили.
func _scene_corridor() -> void:
	_fill(0.0, 0.0, W, H, _hex("#090a09"))

	var far := _radial_grad("corridor-far",
		PackedFloat32Array([0.0, 1.0]),
		PackedColorArray([_rgba(176.0, 168.0, 132.0, 0.42), _rgba(176.0, 168.0, 132.0, 0.0)]),
		4.0, 84.0)
	_draw_radial(far, W * 0.5, H * 0.5, 84.0)
	_fill(W * 0.44, H * 0.36, W * 0.12, H * 0.30, _rgba(196.0, 186.0, 146.0, 0.30))

	_poly(PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(W * 0.34, H * 0.26),
		Vector2(W * 0.34, H * 0.76),
		Vector2(0.0, H)]), _hex("#151714"))
	_poly(PackedVector2Array([
		Vector2(W, 0.0),
		Vector2(W * 0.66, H * 0.26),
		Vector2(W * 0.66, H * 0.76),
		Vector2(W, H)]), _hex("#131513"))

	var board := _rgba(52.0, 48.0, 40.0, 0.75)
	for i in 5:
		draw_line(
			Vector2(W * (0.36 + float(i) * 0.07), H * 0.74),
			Vector2(W * (-0.3 + float(i) * 0.65), H), board, 1.0)

	_poly(PackedVector2Array([
		Vector2(0.0, 0.0),
		Vector2(W, 0.0),
		Vector2(W * 0.66, H * 0.26),
		Vector2(W * 0.34, H * 0.26)]), _rgba(4.0, 5.0, 4.0, 0.6))

	_wash(tint, 0.05)


## Витя спит. Одеяло поднимается и опускается — вся разница между этим
## кадром и кадром пустой кровати в том, дышит оно или нет.
func _scene_vitya() -> void:
	_fill(0.0, 0.0, W, H, _hex("#0c0d0c"))
	var stripe := _rgba(36.0, 38.0, 34.0, 0.6)
	var x := 0.0
	while x < W:
		_fill(x, 0.0, 4.0, H * 0.50, stripe)
		x += 11.0

	var breath := sin(t * 0.9) * 2.2
	_fill(W * 0.08, H * 0.56 - breath * 0.5, W * 0.84, H * 0.32 + breath * 0.5, _hex("#1e211e"))
	_fill(W * 0.14, H * 0.50 - breath, W * 0.70, H * 0.09 + breath, _hex("#2a2d29"))
	_fill(W * 0.22, H * 0.42, W * 0.24, H * 0.05, _hex("#3a3f3a"))
	_fill(W * 0.27, H * 0.44, W * 0.12, H * 0.09, _hex("#4a4038"))
	_fill(W * 0.30, H * 0.47, W * 0.06, H * 0.02, Color(0.0, 0.0, 0.0, 0.45))

	_wash(tint, 0.05)

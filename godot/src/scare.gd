# Скример при поимке. Порт src/ui/scare.js.
#
# Кадр рисуется в поле 320×240 по тем же правилам, что плёнка в tape.js:
# шум по пикселям, строчки через три, ползущая полоса трекинга, виньетка
# кинескопа. Иначе фотография поверх PSX-кадра читается вставкой из другой
# игры — лицо надо сначала прогнать через видеомагнитофон.
#
# ЗАПРЕТ, а не пожелание. За 1.15 с ровно три полнокадровых перепада:
# белый удар → лицо → чёрный хвост. Это ≈2.6 вспышки в секунду, ниже порога
# WCAG 2.3.1 (три вспышки в секунду). Нельзя добавлять четвёртый перепад,
# чередовать чаще, инвертировать цвет и заливать кадр красным: любое из
# этого выводит за порог, и «усиленный» скример выкидывает из игры часть
# игроков — тех, кому от него станет физически плохо. Чернота в хвосте
# меняется только зерном, яркость не поднимается, поэтому хвост остаётся
# одним перепадом, а не тремя.
#
# Выключатель «Скримеры» гасит саму фотографию; звук и трекинг остаются,
# чтобы поимка всё равно читалась. Отсутствующий файл лица работает так же:
# скример не ломается, просто идёт без лица.
#
# ЧЕМ ОТЛИЧАЕТСЯ ОТ ОРИГИНАЛА. Попиксельные проходы (зерно, строчки, полоса,
# виньетка) в JS шли циклом по ImageData — в GDScript это 76 800 итераций
# на кадр, то есть гарантированный провал fps ровно там, где он всего заметнее.
# Те же формулы уехали в canvas_item-шейдер; порядок наложения сохранён
# дословно: фон → лицо → зерно → строчки → полоса → выпадения → виньетка.
#
# RefCounted, а не Node: у CanvasLayer занято имя show(), а у оригинала
# скример — обычный объект, который main.js держит полем.
class_name Scare
extends RefCounted

const W := 320.0
const H := 240.0

# Ключ настройки. Префикс общий с остальным сохранением игры.
const KEY := "scares"
const CFG := "user://vitya.cfg"
const CFG_SECTION := "vitya"

# Границы фаз в секундах от начала.
const T_HIT := 0.06    # белый удар
const T_FACE := 0.95   # лицо с наездом
const T_END := 1.15    # конец: три чёрных кадра позади

# Пять кадров одного лица (раунд 10). Один кадр на всю игру запоминался
# к третьей поимке целиком, и дальше скример работал только звуком: игрок
# знал, что сейчас будет, до кадра. Пять — это уже не «та самая картинка»,
# а «он», и узнавание идёт не по пикселям, а по человеку.
#
# ЛИЦО ОДНО И ТО ЖЕ ВЕЗДЕ. Кадры сделаны из его собственной фотографии
# (tools/gen_scares.py, генерация со ссылкой на исходник), а не по описанию:
# пять разных стариков превратили бы деда в галерею незнакомцев. Файл, которого
# нет, молча пропускается — сборка без части кадров работает как раньше.
const FACE_PATHS: Array[String] = [
	"res://assets/face/vitya-scare-v2.webp",
	"res://assets/face/vitya-scare-2-v2.webp",
	"res://assets/face/vitya-scare-3-v2.webp",
	"res://assets/face/vitya-scare-4-v2.webp",
	"res://assets/face/vitya-scare-5-v2.webp",
]

# Три тембра удара, по кругу и без повтора подряд. Визуал при этом не меняется
# ни на кадр: T_HIT/T_FACE/T_END и три фазы шейдера остаются как были — запрет
# на четвёртый перепад яркости к звуку отношения не имеет.
#
# Гейн у всех трёх один и тот же (gen_sfx.py берёт его у запечённого стингера),
# поэтому чередование слышно как «другой удар», а не как «этот громче».
# Первый в списке — запечённый: на сборке без оверлея sfx() вернёт false
# на двух остальных, и скример уйдёт на audio.stinger(), как в фазе 5.
const STINGERS: Array[String] = ["stinger", "stinger-2", "stinger-3"]

# Слой выше плеера, чтения и телефона: лицо не должно оказаться под чем-то,
# что забыли закрыть.
const LAYER := 4

const SHADER_SRC := """
shader_type canvas_item;

uniform sampler2D face_tex : filter_nearest, repeat_disable;
uniform vec2 face_px = vec2(1.0, 1.0);
uniform float has_face = 0.0;
uniform float phase = 0.0;   // 0 — удар, 1 — лицо, 2 — хвост
uniform float k = 0.0;       // прогресс внутри фазы, 0..1
uniform float t = 0.0;       // секунды от начала скримера
uniform vec2 jitter = vec2(0.0, 0.0);
uniform vec4 drop0 = vec4(-9.0, 0.0, 0.0, 0.0);
uniform vec4 drop1 = vec4(-9.0, 0.0, 0.0, 0.0);
uniform vec4 drop2 = vec4(-9.0, 0.0, 0.0, 0.0);
uniform vec4 drop3 = vec4(-9.0, 0.0, 0.0, 0.0);
uniform vec4 drop4 = vec4(-9.0, 0.0, 0.0, 0.0);

const vec2 FRAME = vec2(320.0, 240.0);

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

// x — верх полосы, y — высота, z — яркость (0 чёрная, 1 белая), w — альфа.
vec3 dropout(vec3 c, vec4 d, float y) {
	if (y >= d.x && y < d.x + d.y) return mix(c, vec3(d.z), d.w);
	return c;
}

void fragment() {
	vec2 px = UV * FRAME;
	vec3 col;

	if (phase < 0.5) {
		// Пересвет головки, а не чистый белый: так удар не выпадает из палитры.
		col = vec3(0.949, 0.937, 0.894);
	} else if (phase < 1.5) {
		col = vec3(0.039, 0.039, 0.035);
		if (has_face > 0.5) {
			// Наезд 1.00 → 1.14 и дрожание ±3 пикселя: камеру держат в руках.
			float zoom = 1.0 + 0.14 * k;
			float s = max(FRAME.x / face_px.x, FRAME.y / face_px.y) * zoom;
			vec2 sz = face_px * s;
			vec2 org = (FRAME - sz) * 0.5 + jitter;
			vec2 fuv = (px - org) / sz;
			if (fuv.x >= 0.0 && fuv.x <= 1.0 && fuv.y >= 0.0 && fuv.y <= 1.0) {
				col = texture(face_tex, fuv).rgb;
			}
		}
		// Первые кадры почти зашумлены — плёнка «наводится» на лицо, а не наоборот.
		float amount = 0.34 - 0.18 * k;
		col += vec3((hash(px + vec2(t * 91.7, t * 57.3)) - 0.5) * amount);
		// Строчки через три.
		if (mod(floor(px.y), 3.0) < 1.0) col = mix(col, vec3(0.0), 0.22);
		// Полоса ползёт вверх втрое быстрее, чем на кассете: лента идёт вразнос.
		float band = FRAME.y - mod(t * 300.0, FRAME.y + 60.0);
		if (px.y >= band && px.y < band + 14.0) col = mix(col, vec3(0.863, 0.863, 0.824), 0.10);
		if (px.y >= band + 14.0 && px.y < band + 18.0) col = mix(col, vec3(0.0), 0.30);
		// Выпадение строк, как на срыве трекинга в плеере.
		col = dropout(col, drop0, px.y);
		col = dropout(col, drop1, px.y);
		col = dropout(col, drop2, px.y);
		col = dropout(col, drop3, px.y);
		col = dropout(col, drop4, px.y);
		// Виньетка кинескопа: прозрачная до 0.28H, к 0.86H — чёрная на 0.72.
		float q = clamp((distance(px, FRAME * 0.5) - FRAME.y * 0.28)
			/ (FRAME.y * 0.86 - FRAME.y * 0.28), 0.0, 1.0);
		col = mix(col, vec3(0.0), q * 0.72);
	} else {
		// Три чёрных кадра, чередующихся через один: пустой, с зерном, пустой.
		// Зерно поднимает яркость на единицы кода — перепадом это не считается.
		col = vec3(0.0);
		if (mod(min(2.0, floor(k * 3.0)), 2.0) >= 1.0) {
			col += vec3(hash(px + vec2(t * 33.1, t * 77.9)) * (18.0 / 255.0));
		}
	}

	COLOR = vec4(col, 1.0);
}
"""

var audio: GameAudio = null
var img: Texture2D = null

var t := 0.0

var _on_done := Callable()
var _open := false
var _enabled := true

var _layer: CanvasLayer = null
var _root: Control = null
var _frame: ColorRect = null
var _mat: ShaderMaterial = null
var _sting_left: Array[String] = []
var _faces: Array[Texture2D] = []
var _face_left: Array[Texture2D] = []


func _init(game_audio: GameAudio = null, parent: Node = null) -> void:
	audio = game_audio
	_enabled = _read_flag()
	_build()
	if parent != null:
		attach(parent)


## Куда повесить слой скримера. Отдельным вызовом — чтобы main.gd мог создать
## скример раньше, чем у него появится корень сцены.
func attach(parent: Node) -> void:
	if _layer.get_parent() == parent:
		return
	if _layer.get_parent() != null:
		_layer.get_parent().remove_child(_layer)
	parent.add_child(_layer)


func _build() -> void:
	_layer = CanvasLayer.new()
	_layer.name = "ScareLayer"
	_layer.layer = LAYER

	_root = Control.new()
	_root.name = "Scare"
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.visible = false
	_layer.add_child(_root)

	# Под кадром чернота: кадр 4:3 растянут «по большей стороне» и края экрана
	# он закрывает не всегда — на очень широком окне снизу и сверху пусто.
	var bg := ColorRect.new()
	bg.name = "Black"
	bg.color = Color(0, 0, 0, 1)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(bg)

	var sh := Shader.new()
	sh.code = SHADER_SRC
	_mat = ShaderMaterial.new()
	_mat.shader = sh

	_frame = ColorRect.new()
	_frame.name = "Frame"
	_frame.color = Color(0, 0, 0, 1)
	_frame.material = _mat
	_frame.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_frame)

	_root.resized.connect(_fit)
	_fit()


## Кадр вписан «по большей стороне» (object-fit: cover оригинала): лицо не должно
## получить поля, лучше подрезать края.
func _fit() -> void:
	var vs := _root.size
	if vs.x <= 0.0 or vs.y <= 0.0:
		return
	var s := maxf(vs.x / W, vs.y / H)
	var w := W * s
	var h := H * s
	_frame.position = Vector2((vs.x - w) * 0.5, (vs.y - h) * 0.5)
	_frame.size = Vector2(w, h)


## Лица грузятся один раз, все сразу: подгружать кадр в момент поимки значит
## ставить load() ровно в тот кадр, где нельзя терять ни миллисекунды.
## Провал не фатален — играем без фотографии. Имя не load(): так называется
## встроенная функция GDScript.
func load_face() -> bool:
	_faces.clear()
	for path in FACE_PATHS:
		if not ResourceLoader.exists(path):
			continue
		var res: Variant = load(path)
		if res is Texture2D:
			_faces.append(res)
	if _faces.is_empty():
		return false
	_set_face(_faces[0])
	return true


func _set_face(tex: Texture2D) -> void:
	img = tex
	_mat.set_shader_parameter("face_tex", img)
	_mat.set_shader_parameter("face_px", Vector2(img.get_width(), img.get_height()))


# Тот же мешок без повторов, что у тембров удара, и по той же причине: строгая
# очерёдность к третьей поимке читается как ритм.
func _next_face() -> void:
	if _faces.size() < 2:
		return
	if _face_left.is_empty():
		_face_left = _faces.duplicate()
	var i := randi() % _face_left.size()
	_set_face(_face_left[i])
	_face_left.remove_at(i)


var open: bool:
	get:
		return _open


var enabled: bool:
	get:
		return _enabled
	set(v):
		_enabled = v
		_write_flag(v)


# Запускает скример. Возвращает false, если новый не начался, — но колбэк
# при этом не теряется НИКОГДА.
#
# Раньше повторный вызов поверх идущего скримера выходил голым return false,
# и вместе с ним пропадал onDone, а в нём showFail. Тогда controls.enabled
# оставался false, [R] не принималась, а threatState навсегда застревал
# в 'absent': игра запиралась насмерть, и это был второй путь к жалобе
# «деда больше нет».
#
# Колбэк ставим в очередь на _finish, а не зовём немедленно: карточка провала,
# показанная поверх идущего лица, съедает ту самую фазу, ради которой скример
# и существует. Фазы, их тайминги и запрет на четвёртый перепад яркости
# очередь не трогает — она отрабатывает после T_END, когда кадр уже чёрный.
func play(on_done: Variant = null) -> bool:
	var cb := Callable()
	if on_done is Callable:
		cb = on_done
	if _open:
		if cb.is_valid():
			var prev := _on_done
			if not prev.is_valid():
				_on_done = cb
				return false
			var chained := func() -> void:
				prev.call()
				cb.call()
			_on_done = chained
		return false
	t = 0.0
	_on_done = cb
	_open = true
	_root.visible = true
	# Кадр выбирается ДО первой отрисовки: смена текстуры внутри показа была бы
	# видна как подмена, а тут она случается на чёрном.
	_next_face()
	_paint()
	if audio != null:
		# Тембр удара — один из трёх. Оверлея нет — sfx() вернёт false на
		# двух новых именах, и скример уйдёт на запечённый, как в фазе 5.
		if not bool(audio.sfx(_next_stinger(), 1.0)):
			audio.stinger(1.0)
		audio.noise({"dur": 0.5, "gain": 0.12, "freq": 4200.0, "q": 0.6, "sweep": -3200.0, "attack": 0.002})
	return true


# Круг без повтора: пока в мешке есть невыпавшие тембры, берём из них,
# кончились — насыпаем заново. Не индекс по кругу: строгая очерёдность
# к третьей поимке читается как ритм, и удар перестаёт быть неожиданным.
func _next_stinger() -> String:
	if _sting_left.is_empty():
		_sting_left = STINGERS.duplicate()
	var i := randi() % _sting_left.size()
	var name := _sting_left[i]
	_sting_left.remove_at(i)
	return name


func update(dt: float) -> void:
	if not _open:
		return
	t += dt
	if t >= T_END:
		_finish()
		return
	_paint()


func _finish() -> void:
	_open = false
	_root.visible = false
	var cb := _on_done
	_on_done = Callable()
	if cb.is_valid():
		cb.call()


func _paint() -> void:
	_mat.set_shader_parameter("t", t)
	if t < T_HIT:
		if not _enabled:
			# Выключенные резкие эффекты: белого удара нет вовсе. Кадр уходит
			# в тёмное сразу и там остаётся — перепад яркости за весь скример
			# ровно один вместо трёх, то есть строго безопаснее принятого.
			_mat.set_shader_parameter("phase", 1.0)
			_mat.set_shader_parameter("k", 0.0)
			_mat.set_shader_parameter("has_face", 0.0)
			return
		_mat.set_shader_parameter("phase", 0.0)
		_mat.set_shader_parameter("k", 0.0)
		return
	if t < T_FACE:
		var k := (t - T_HIT) / (T_FACE - T_HIT)
		_mat.set_shader_parameter("phase", 1.0)
		_mat.set_shader_parameter("k", k)
		# Фотографию гасит выключатель «Скримеры», всё остальное остаётся.
		_mat.set_shader_parameter("has_face", 1.0 if (img != null and _enabled) else 0.0)
		_mat.set_shader_parameter("jitter", Vector2((randf() - 0.5) * 6.0, (randf() - 0.5) * 6.0))
		for i in 5:
			var white := randf() < 0.5
			_mat.set_shader_parameter("drop%d" % i, Vector4(
				randf() * H,
				1.0 + randf() * 4.0,
				1.0 if white else 0.0,
				0.25 if white else 0.5))
		return
	_mat.set_shader_parameter("phase", 2.0)
	_mat.set_shader_parameter("k", (t - T_FACE) / (T_END - T_FACE))


# ---------- настройка ----------

# Приватный режим Safari ронял localStorage на чтении; здесь тот же принцип —
# нечитаемый конфиг молча считается «включено».
static func _read_flag() -> bool:
	var cfg := ConfigFile.new()
	if cfg.load(CFG) != OK:
		return true
	return bool(cfg.get_value(CFG_SECTION, KEY, true))


static func _write_flag(v: bool) -> void:
	var cfg := ConfigFile.new()
	cfg.load(CFG)
	cfg.set_value(CFG_SECTION, KEY, v)
	cfg.save(CFG)

# Рендер-цепочка. Порт src/engine/renderer.js.
#
# Главный рычаг производительности тот же, что в браузере: кадр рисуется в буфер
# высотой 360 пикселей и растягивается на экран ближайшим соседом. Ширина буфера
# считается по соотношению сторон окна, чтобы картинку не сплющивало.
#
# Что в Godot устроено иначе, чем в EffectComposer:
#   — мир и руки идут в ДВА SubViewport'а вместо двух RenderPass в один буфер,
#     потому что рукам нужен свой мир (own_world_3d) и свой свет. Склейка
#     mix(world, hand.rgb, hand.a) переехала в vhs_compose.gdshader;
#   — VHS считается в третьем SubViewport (PostView) того же размера, что буфер,
#     и только его результат TextureRect тянет на всё окно. Если считать VHS
#     сразу на экране, скан-линии окажутся по пикселям монитора, а не буфера;
#   — кассета не подменяет сцену мирового прохода, а включает ветку в шейдере:
#     tape_mode + пиллярбокс 4:3. Кадр приезжает из TapeView (320x240), который
#     рисует tape_player.
#
# Все входы шейдера — явные ViewportTexture: hint_screen_texture в canvas_item
# отдаёт экран окна целиком, а нам нужны конкретные вьюпорты.
class_name RenderChain
extends Node

signal skin_enabled_changed(enabled: bool)

# Высота буфера. Раньше была намертво 360 — на 1080p это апскейл 3x, и любая
# мелкая деталь превращалась в кашу ещё до VHS. Теперь по умолчанию это половина
# высоты окна, то есть целочисленный 2x, а клампы держат пиксель крупным
# (ниже 360 — мыло, выше 540 — уже не PSX). Меню чёткости ставит явную высоту
# поверх этого правила: 360 / 540 / 720.
const BUFFER_H_MIN := 360
const BUFFER_H_MAX := 540
const SHARPNESS_STEPS := [360, 540, 720]
const PRESET_RETRO := "retro"
const PRESET_HQ := "hq"
const HQ_BUFFER_HEIGHT := 720
const RENDER_CFG_KEY := "render_preset"
const VHS_CFG_KEY := "vhs_amount"
const VHS_DEFAULT := 0.30
const VHS_STEPS := [0.0, 0.30, 0.65, 1.0]

# Фаза 8. «Целочисленная» чёткость: буфер = окно / N, где N — наименьшее целое,
# при котором высота укладывается в потолок. Тогда апскейл ровно N, а не 1.954,
# и периодические узоры кадра — плитка дизера 4 px, скан-линии и гребёнка по 2 px —
# не бьются об экранную сетку в муар. Цена — до N-1 пикселя чёрной каймы,
# которую ловит уже сама PRESET_FULL_RECT: в этом режиме экран ставится вручную.
const SHARPNESS_INTEGER := -1
# Ширина ограничена теми же долями высоты, что и раньше (480/360 и 960/360):
# при 4:3 буфер ровно 4:3, и пиллярбокс кассеты ложится без обрезки.
const BUFFER_W_MIN_K := 4.0 / 3.0
const BUFFER_W_MAX_K := 8.0 / 3.0
const TAPE_SIZE := Vector2i(320, 240)

# Тонмаппинг. LINEAR не сворачивает света вовсе: всё, что ярче единицы, ложится
# плоским белым, и вечер во дворе выглядел пересвеченным полднем. ACES съедает
# верх диапазона и возвращает сумеркам объём.
# 0.62 — не «на глаз», а по замеру. ACES поднимает средние тона: на 0.88 двор
# выходил СВЕТЛЕЕ, чем был на LINEAR (средняя яркость кадра от ворот 95 против
# 82), хотя энергия света уже убавлена. На 0.62 средняя падает до 77, а верхние
# проценты, наоборот, растут — это и есть вернувшийся контраст вместо плоского
# пересвета. Последнее слово всё равно за глазами Петра: в паузе есть ползунок.
const TONEMAP_EXPOSURE := 0.62
const TONEMAP_WHITE := 2.0
const ADJUST_CONTRAST := 1.12
const ADJUST_SATURATION := 0.90
const HQ_ADJUST_CONTRAST := 1.06
const HQ_ADJUST_SATURATION := 0.94
const HQ_FOG_DENSITY_DUSK := 0.032
const HQ_FOG_DENSITY_NIGHT := 0.052
const HQ_SKY_ENERGY_DUSK := 0.62
const HQ_SKY_ENERGY_NIGHT := 0.47

# scene.background оригинала.
const WORLD_BG := 0x121a26
const WORLD_SKY := "res://assets/tex/late-evening-sky.webp"
const WORLD_SKY_SIZE := Vector2i(512, 256)
const WORLD_SKY_PIXEL_BUDGET := 512 * 256

# Свет сцены рук из renderer.js: без него фонарь в руке — чёрное пятно,
# хотя он-то как раз светит.
const HAND_AMBIENT := 0x9aa8bb
const HAND_AMBIENT_ENERGY := 1.4
const HAND_KEY := 0xffe2b0
const HAND_KEY_ENERGY := 1.4
const HAND_KEY_RANGE := 3.0
const HAND_KEY_DECAY := 1.4
const HAND_KEY_POS := Vector3(0.45, 0.35, 0.5)
const HAND_FILL := 0xbfd0e0
const HAND_FILL_ENERGY := 0.55
const HAND_FILL_POS := Vector3(-0.6, 0.4, 0.8)

# FOG из data/site.json (ночной пресет lights.js): туда же смотрит psx.gdshader.
const FOG_COLOR := 0x141b26
const FOG_NEAR := 7.0
const FOG_FAR := 32.0

var world_root: Node3D
var hand_root: Node3D
var camera: Camera3D
var hand_camera: Camera3D

var world_view: SubViewport
var hand_view: SubViewport
var tape_view: SubViewport
var post_view: SubViewport

# Отдаём наружу: сумерки -> ночь ведёт LightRig, а фон и ambient живут здесь.
var world_env: Environment
var hand_env: Environment
var screen: TextureRect

var _post_rect: ColorRect
var _post_mat: ShaderMaterial
var _tape_bg: ColorRect
var _tape_mode := false
# Есть ли что рисовать во вьюпорте рук. Ставит held_items.gd; см.
# set_hands_visible().
var _hands_on := false
var _time := 0.0
var _size := Vector2i(int(BUFFER_H_MIN * BUFFER_W_MIN_K), BUFFER_H_MIN)
# 0 — высоту буфера считаем от окна; иначе явный выбор из меню чёткости.
var _sharpness := 0
var _preset := PRESET_RETRO
var _preset_button: Button
var _vhs_button: Button
var _vhs_amount := VHS_DEFAULT
var _skin_button: Button
var _preset_ui: WeakRef
var _skin_enabled := true
var _saved_sky: Sky
var _saved_background_mode := Environment.BG_COLOR
var _saved_background_energy := 1.0
var _saved_fog_enabled := false
static var _shader_global_values: Dictionary = {}


static func set_shader_global(key: StringName, value: Variant) -> void:
	_shader_global_values[key] = value
	RenderingServer.global_shader_parameter_set(key, value)


static func get_shader_global(key: StringName) -> Variant:
	if _shader_global_values.has(key):
		return _shader_global_values[key]
	var configured: Variant = ProjectSettings.get_setting("shader_globals/" + String(key), {})
	return configured.get("value") if configured is Dictionary else null

# ---------- глобальные uniform'ы psx.gdshader ----------

## Объявить глобальные uniform'ы, если их нет в project.godot.
## Шейдер с необъявленным global uniform не компилируется вовсе, поэтому вызов
## идёт до сборки мира — из _init() цепочки и фонаря.
static func register_shader_globals() -> void:
	# Наличие проверяется по ProjectSettings, не по RenderingServer:
	# global_shader_parameter_get_list в оконном GLES3-рантайме editor-only
	# и на каждый вызов сыпал ERROR, а add уже объявленного — ещё по одному.
	var have := PackedStringArray()
	for n in ["psx_fog_color", "psx_fog_near", "psx_fog_far",
			"flashlight_proj", "flashlight_pos", "flashlight_on", "flashlight_cookie"]:
		if ProjectSettings.has_setting("shader_globals/" + n):
			have.append(n)

	if not have.has("psx_fog_color"):
		RenderingServer.global_shader_parameter_add(
			"psx_fog_color", RenderingServer.GLOBAL_VAR_TYPE_VEC3, _linear3(FOG_COLOR))
	if not have.has("psx_fog_near"):
		RenderingServer.global_shader_parameter_add(
			"psx_fog_near", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, FOG_NEAR)
	if not have.has("psx_fog_far"):
		RenderingServer.global_shader_parameter_add(
			"psx_fog_far", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, FOG_FAR)
	if not have.has("flashlight_proj"):
		RenderingServer.global_shader_parameter_add(
			"flashlight_proj", RenderingServer.GLOBAL_VAR_TYPE_MAT4, Projection())
	if not have.has("flashlight_pos"):
		RenderingServer.global_shader_parameter_add(
			"flashlight_pos", RenderingServer.GLOBAL_VAR_TYPE_VEC3, Vector3.ZERO)
	if not have.has("flashlight_on"):
		RenderingServer.global_shader_parameter_add(
			"flashlight_on", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	if not have.has("flashlight_cookie"):
		RenderingServer.global_shader_parameter_add(
			"flashlight_cookie", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, null)
	# Значения ставим всегда, а не только при объявлении: если те же имена окажутся
	# в [shader_globals] project.godot с другими числами, туман и cookie молча
	# разъедутся с данными. Живой пресет неба всё равно перепишет туман сверху.
	set_shader_global("psx_fog_color", _linear3(FOG_COLOR))
	set_shader_global("psx_fog_near", FOG_NEAR)
	set_shader_global("psx_fog_far", FOG_FAR)
	# load() кэширует, повторный вызов ничего не стоит.
	set_shader_global(
		"flashlight_cookie", load("res://assets/generated/textures/flashlight-cookie.res")
		if ResourceLoader.exists("res://assets/generated/textures/flashlight-cookie.res")
		else load("res://parity/cookie.png"))


## Цвет тумана уезжает в шейдер линейным: 3D в Godot считается в линейном свете.
static func _linear3(hex: int) -> Vector3:
	var c := GameData.color(hex).srgb_to_linear()
	return Vector3(c.r, c.g, c.b)

# ---------- сборка ----------

func _init() -> void:
	register_shader_globals()


func _ready() -> void:
	_build()
	get_tree().root.size_changed.connect(_apply_size)
	_apply_size()


func _build() -> void:
	# --- мир ---
	world_view = SubViewport.new()
	world_view.name = "WorldView"
	world_view.own_world_3d = true
	world_view.transparent_bg = false
	world_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	world_view.msaa_3d = Viewport.MSAA_DISABLED
	world_view.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	world_view.use_debanding = false
	# gui_disable_input тут НЕ ставим: он же глушит push_input, а через него
	# в этот вьюпорт приезжает ввод игрока (см. _input ниже).
	# У оригинала shadow.mapSize = 768x768 на фонарь. В Godot размер теневой карты
	# задаёт атлас вьюпорта: атлас 1024 с неразделённым нулевым квадрантом даёт
	# 512 на самый важный источник (это и есть фонарь), остальным — мелочь.
	#
	# ФАЗА 15. Было 2048. В буфере 982x540, растянутом ближайшим соседом и
	# засыпанном зерном, разницы между 1024 и 512 на кромке тени не видно
	# вовсе, а атлас перестраивается каждый кадр, пока фонарь движется.
	world_view.positional_shadow_atlas_size = 1024
	world_view.positional_shadow_atlas_quad_0 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_1
	world_view.positional_shadow_atlas_quad_1 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_4
	world_view.positional_shadow_atlas_quad_2 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_16
	world_view.positional_shadow_atlas_quad_3 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_16
	add_child(world_view)

	world_env = Environment.new()
	world_env.background_mode = Environment.BG_COLOR
	world_env.background_color = GameData.color(WORLD_BG)
	# Свет сцены ставит LightRig; ambient держим цветом, чтобы полусферу
	# оригинала было куда положить.
	world_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	world_env.ambient_light_color = Color.BLACK
	world_env.ambient_light_energy = 1.0
	# Туман свой, в psx.gdshader: средовой его бы удвоил.
	world_env.fog_enabled = false
	world_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	world_env.tonemap_exposure = TONEMAP_EXPOSURE
	world_env.tonemap_white = TONEMAP_WHITE
	world_env.glow_enabled = false
	# Единственный пост, который Compatibility считает честно (в отличие от SSIL
	# и объёмного тумана): контраст возвращает вечеру глубину, которую съедает
	# полусферный ambient, а лёгкая десатурация уводит картинку от «мультика».
	world_env.adjustment_enabled = true
	world_env.adjustment_contrast = ADJUST_CONTRAST
	world_env.adjustment_saturation = ADJUST_SATURATION
	world_env.adjustment_brightness = 1.0
	# Низкоконтрастное облачное небо — только если Compatibility и маленький
	# ресурс проходят дешёвую проверку. Любая ошибка оставляет прежний BG_COLOR.
	try_set_panorama(WORLD_SKY)
	var world_we := WorldEnvironment.new()
	world_we.name = "WorldEnvironment"
	world_we.environment = world_env
	world_view.add_child(world_we)

	world_root = Node3D.new()
	world_root.name = "World"
	world_view.add_child(world_root)

	camera = Camera3D.new()
	camera.name = "Camera"
	camera.keep_aspect = Camera3D.KEEP_HEIGHT  # three.js меряет FOV по вертикали
	camera.fov = 70.0
	camera.near = 0.08
	camera.far = 90.0
	world_view.add_child(camera)
	camera.make_current()

	# --- руки ---
	# Отдельная камера с узким FOV — прямое лекарство от «фонаря на пол-экрана»:
	# при мировом FOV 70 и viewmodel-FOV 45 модель физически не может расползтись.
	hand_view = SubViewport.new()
	hand_view.name = "HandView"
	hand_view.own_world_3d = true
	hand_view.transparent_bg = true
	# Вьюпорт рук рисуется В ПОЛНЫЙ РАЗМЕР БУФЕРА, и рисовался он всегда —
	# включая всю первую половину игры, когда фонаря в руках нет вовсе:
	# пустой прозрачный кадр в те же сотни тысяч пикселей, каждый кадр.
	# Режим переключает HeldItems по выбранному предмету.
	hand_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	hand_view.msaa_3d = Viewport.MSAA_DISABLED
	hand_view.screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	hand_view.use_debanding = false
	hand_view.gui_disable_input = true
	add_child(hand_view)

	hand_env = Environment.new()
	# Прозрачный фон вьюпорта переживает только сплошную заливку с нулевой альфой:
	# небо или canvas на его месте вернули бы непрозрачный кадр.
	hand_env.background_mode = Environment.BG_COLOR
	hand_env.background_color = Color(0.0, 0.0, 0.0, 0.0)
	hand_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	hand_env.ambient_light_color = GameData.color(HAND_AMBIENT)
	hand_env.ambient_light_energy = HAND_AMBIENT_ENERGY
	hand_env.fog_enabled = false
	# Тот же тонмаппинг, что у мира: иначе фонарь в руке остаётся в старой
	# яркости и висит светлым пятном на притушенном кадре. Adjustments сюда
	# намеренно НЕ идут — вьюпорт прозрачный, а пост по альфе в Compatibility
	# ведёт себя по-разному от драйвера к драйверу.
	hand_env.tonemap_mode = Environment.TONE_MAPPER_ACES
	hand_env.tonemap_exposure = TONEMAP_EXPOSURE
	hand_env.tonemap_white = TONEMAP_WHITE
	hand_env.glow_enabled = false
	hand_env.adjustment_enabled = false
	var hand_we := WorldEnvironment.new()
	hand_we.name = "HandEnvironment"
	hand_we.environment = hand_env
	hand_view.add_child(hand_we)

	hand_root = Node3D.new()
	hand_root.name = "Hands"
	hand_view.add_child(hand_root)

	var key := OmniLight3D.new()
	key.name = "HandKey"
	key.light_color = GameData.color(HAND_KEY)
	key.light_energy = HAND_KEY_ENERGY
	key.omni_range = HAND_KEY_RANGE
	key.omni_attenuation = HAND_KEY_DECAY
	key.shadow_enabled = false
	key.position = HAND_KEY_POS
	hand_root.add_child(key)

	var fill := DirectionalLight3D.new()
	fill.name = "HandFill"
	fill.light_color = GameData.color(HAND_FILL)
	fill.light_energy = HAND_FILL_ENERGY
	fill.shadow_enabled = false
	hand_root.add_child(fill)
	# У three.js направленный свет светит из своей позиции в начало координат.
	fill.look_at_from_position(HAND_FILL_POS, Vector3.ZERO, Vector3.UP)

	hand_camera = Camera3D.new()
	hand_camera.name = "HandCamera"
	hand_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	hand_camera.fov = 45.0
	hand_camera.near = 0.01
	hand_camera.far = 5.0
	hand_view.add_child(hand_camera)
	hand_camera.make_current()

	# --- кассета ---
	# Обычно выключен: игрок может не найти ни одной кассеты за всю игру,
	# а это лишний вьюпорт в кадре.
	tape_view = SubViewport.new()
	tape_view.name = "TapeView"
	tape_view.size = TAPE_SIZE
	tape_view.transparent_bg = true
	tape_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	tape_view.gui_disable_input = true
	tape_view.set(&"disable_3d", true)
	add_child(tape_view)

	# Чернота под кадром плеера: своего цвета очистки у 2D-вьюпорта нет,
	# а прозрачные поля пропустили бы мир под кассетой.
	_tape_bg = ColorRect.new()
	_tape_bg.name = "TapeBackground"
	_tape_bg.color = Color.BLACK
	_tape_bg.position = Vector2.ZERO
	_tape_bg.size = Vector2(TAPE_SIZE)
	_tape_bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tape_view.add_child(_tape_bg)

	# --- пост ---
	# Добавляется последним: Godot рисует вложенные вьюпорты в порядке дерева,
	# и композит обязан идти после источников, иначе он отстанет на кадр.
	post_view = SubViewport.new()
	post_view.name = "PostView"
	post_view.transparent_bg = false
	post_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	post_view.gui_disable_input = true
	post_view.set(&"disable_3d", true)
	add_child(post_view)

	_post_mat = ShaderMaterial.new()
	_post_mat.shader = load("res://shaders/vhs_compose.gdshader")
	_post_mat.set_shader_parameter("world_tex", world_view.get_texture())
	_post_mat.set_shader_parameter("hand_tex", hand_view.get_texture())
	_post_mat.set_shader_parameter("tape_tex", tape_view.get_texture())
	_post_mat.set_shader_parameter("tape_mode", 0.0)
	_post_mat.set_shader_parameter("hand_mix", 0.0)
	_post_mat.set_shader_parameter("fade", 1.0)
	_post_mat.set_shader_parameter("time", 0.0)

	_post_rect = ColorRect.new()
	_post_rect.name = "Compose"
	_post_rect.material = _post_mat
	_post_rect.position = Vector2.ZERO
	_post_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	post_view.add_child(_post_rect)

	# --- экран ---
	# Слой ниже нуля: интерфейс (overlays) ложится поверх без всяких z_index.
	var layer := CanvasLayer.new()
	layer.name = "ScreenLayer"
	layer.layer = -1
	add_child(layer)

	screen = TextureRect.new()
	screen.name = "Screen"
	screen.texture = post_view.get_texture()
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	layer.add_child(screen)


func _input(event: InputEvent) -> void:
	# SubViewport вне SubViewportContainer событий сам не получает: ни _input,
	# ни _unhandled_input у игрока внутри WorldView не сработали бы. Пробрасываем
	# как есть — трансформировать координаты некуда, вьюпорт на экране не лежит.
	if world_view != null:
		world_view.push_input(event, true)

# ---------- размер буфера ----------

## Высота буфера: явный выбор из меню либо половина высоты окна. Половина —
## это целочисленный апскейл 2x, при котором пиксель остаётся ровным квадратом,
## а не размазывается неровной дробью по строкам монитора.
func buffer_height() -> int:
	if _preset == PRESET_HQ:
		return maxi(1, mini(HQ_BUFFER_HEIGHT, get_tree().root.size.y))
	if _sharpness > 0:
		return _sharpness
	var win := get_tree().root.size
	if _sharpness == SHARPNESS_INTEGER and _preset != PRESET_HQ:
		return int(win.y / integer_scale())
	return clampi(int(win.y / 2), BUFFER_H_MIN, BUFFER_H_MAX)


## Кратность целочисленного режима. Наименьшее N, при котором окно, делённое
## на N, влезает в потолок высоты буфера: 1080 -> 2, 1440 -> 3, 2160 -> 4.
func integer_scale() -> int:
	var win := get_tree().root.size
	var n := maxi(1, ceili(float(win.y) / float(BUFFER_H_MAX)))
	# В маленьком окне следующая кратность роняет буфер ниже «ретро» — тогда
	# лучше шаг назад: пиксель крупнее потолка честнее, чем каша мельче пола.
	if n > 1 and int(win.y / n) < BUFFER_H_MIN:
		n -= 1
	return n


## Ширина буфера по форме окна. Формула из renderer.js.bufferSize() дословно,
## включая округление до чётного: нечётная ширина ведёт скан-линии и гребёнку.
func buffer_size() -> Vector2i:
	var win := get_tree().root.size
	var h := buffer_height()
	if _preset == PRESET_HQ:
		var factor := minf(1.0, minf(1280.0 / maxf(1.0, win.x), 720.0 / maxf(1.0, win.y)))
		return Vector2i(maxi(2, int(win.x * factor / 2.0) * 2), maxi(2, int(win.y * factor / 2.0) * 2))
	if _sharpness == SHARPNESS_INTEGER and _preset != PRESET_HQ:
		# Ширина по той же кратности, что и высота: иначе пиксель перестанет
		# быть квадратом, а весь смысл режима в том, что он квадрат.
		var n := integer_scale()
		return Vector2i(int(win.x / n / 2) * 2, h)
	var aspect := clampf(float(win.x) / maxf(1.0, float(win.y)), 0.8, 2.6)
	var w := int(round(h * aspect / 2.0)) * 2
	w = clampi(w, int(h * BUFFER_W_MIN_K / 2.0) * 2, int(h * BUFFER_W_MAX_K / 2.0) * 2)
	return Vector2i(w, h)


## Меню чёткости: 0 — считать от окна, иначе высота буфера в пикселях.
func set_sharpness(h: int) -> void:
	if _sharpness == h:
		return
	_sharpness = h
	_apply_size()


func sharpness() -> int:
	return _sharpness


## Ползунок «Яркость». Пишет прямо в экспозицию тонмаппинга — того самого,
## ради которого LINEAR и менялся на ACES.
func set_exposure(v: float) -> void:
	var e := clampf(v, 0.4, 2.0)
	world_env.tonemap_exposure = e
	hand_env.tonemap_exposure = e


func exposure() -> float:
	return world_env.tonemap_exposure


func _apply_size() -> void:
	var s := buffer_size()
	if s != _size or world_view.size != s:
		_size = s
		world_view.size = s
		hand_view.size = s
		post_view.size = s
		_post_rect.size = Vector2(s)
		_post_mat.set_shader_parameter("resolution", Vector2(s))
	_fit_screen()
	# Пропорция пиллярбокса считается от буфера, а буфер мог измениться.
	_fit_tape()


## Куда лечь готовому кадру. Во всех режимах, кроме целочисленного, — на всё
## окно, как было. В целочисленном — ровно buffer * N по центру: остаток
## (меньше N пикселей по каждой оси) остаётся чёрной каймой, и это дешевле,
## чем дробный апскейл, ради которого режим и заведён.
func _fit_screen() -> void:
	if screen == null:
		return
	if _sharpness != SHARPNESS_INTEGER or _preset == PRESET_HQ:
		screen.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		return
	var win := get_tree().root.size
	var n := integer_scale()
	var shown := Vector2(_size * n)
	screen.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	screen.position = ((Vector2(win) - shown) * 0.5).floor()
	screen.size = shown

# ---------- кадр ----------

## Зовётся раз в кадр из main.gd вместо renderer.render(dt): время эффектов
## идёт по игровым секундам, а не по TIME движка, иначе пауза его не остановит.
func render(dt: float) -> void:
	_time += dt
	_post_mat.set_shader_parameter("time", _time)


## 0 — чёрный кадр, 1 — обычный. Используется при переходах между слоями.
func set_fade(v: float) -> void:
	_post_mat.set_shader_parameter("fade", v)


func get_fade() -> float:
	return float(_post_mat.get_shader_parameter("fade"))


## Прямой доступ к uniform'у композита. Имена — snake_case из vhs_compose.gdshader.
func set_vhs(param: StringName, v: Variant) -> void:
	_post_mat.set_shader_parameter(param, v)


func get_vhs(param: StringName) -> Variant:
	return _post_mat.get_shader_parameter(param)


## Дрожание трекинга: 0 в покое, до 1 в моменты, когда плёнку «ведёт».
func set_tracking(v: float) -> void:
	_post_mat.set_shader_parameter("tracking", v)


func set_grain(v: float) -> void:
	_post_mat.set_shader_parameter("grain", v)


## Горизонтальный снос цветности. 0 — мир как был, до 1 — затёртая кассета.
func set_chroma_smear(v: float) -> void:
	_post_mat.set_shader_parameter("chroma_smear", v)


## Полоса перекоммутации головок у нижней кромки. 0 — её нет вовсе.
func set_head_switch(v: float) -> void:
	_post_mat.set_shader_parameter("head_switch", v)


## Фон мира: lights.js ведёт его от сумерек к ночи.
func set_background(c: Color) -> void:
	world_env.background_color = c


## Цвет фона следует игровым часам; FOG во всех материалах получает globals LightRig.
func set_hq_atmosphere(fog_color: Color, night: float) -> void:
	if _preset != PRESET_HQ or world_env == null:
		return
	var n := clampf(night, 0.0, 1.0)
	world_env.fog_enabled = false
	world_env.fog_light_color = fog_color
	world_env.fog_density = lerpf(HQ_FOG_DENSITY_DUSK, HQ_FOG_DENSITY_NIGHT, n)
	world_env.fog_light_energy = lerpf(0.60, 1.05, n)
	world_env.fog_sky_affect = lerpf(0.14, 0.18, n)
	world_env.background_energy_multiplier = lerpf(HQ_SKY_ENERGY_DUSK,
		HQ_SKY_ENERGY_NIGHT, n)


## Подключить статичную панораму, не отдавая ей ambient. Проверка намеренно
## консервативна: проект принят на Compatibility, а ресурс больше 512x256
## нарушил бы бюджет ради фона, который почти целиком съедает туман.
func try_set_panorama(path: String) -> bool:
	disable_panorama()
	var renderer := String(ProjectSettings.get_setting(
		"rendering/renderer/rendering_method", "gl_compatibility"))
	if renderer != "gl_compatibility" or not ResourceLoader.exists(path):
		return false
	var tex := load(path) as Texture2D
	if tex == null:
		return false
	var size := Vector2i(tex.get_width(), tex.get_height())
	if size != WORLD_SKY_SIZE or size.x * size.y > WORLD_SKY_PIXEL_BUDGET:
		return false
	var material := PanoramaSkyMaterial.new()
	material.panorama = tex
	var sky := Sky.new()
	sky.sky_material = material
	world_env.sky = sky
	world_env.background_mode = Environment.BG_SKY
	# LightRig продолжает писать цвет/энергию ambient напрямую.
	world_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	return true


func disable_panorama() -> void:
	if world_env == null:
		return
	world_env.background_mode = Environment.BG_COLOR
	world_env.sky = null


func panorama_enabled() -> bool:
	return world_env != null and world_env.background_mode == Environment.BG_SKY

# ---------- пресет «Чёткость+» ----------

func render_preset() -> String:
	return _preset


## CLI не пишет настройки: сравнительные снимки не меняют выбор игрока.
func apply_render_args(args: PackedStringArray = []) -> bool:
	if args.is_empty():
		args = OS.get_cmdline_user_args()
	for argument: String in args:
		if argument.begins_with("--vhs="):
			var amount := argument.trim_prefix("--vhs=")
			if not amount.is_valid_float():
				return false
			set_vhs_amount(amount.to_float())
		if argument.begins_with("--render="):
			if not apply_preset(argument.trim_prefix("--render=")):
				push_warning("Неизвестный пресет рендера: " + argument)
				return false
	return true


func apply_preset(value: String) -> bool:
	var wanted := value.strip_edges().to_lower()
	var target := PRESET_RETRO
	var height := _sharpness
	match wanted:
		"hq", "clarity+", "чёткость+", "четкость+":
			target = PRESET_HQ
		"retro", "default", "ретро":
			pass
		"360":
			height = 360
		"540", "средняя":
			height = 540
		"720", "чёткая", "четкая":
			height = 720
		"integer", "целочисленная":
			height = SHARPNESS_INTEGER
		_:
			return false
	_sharpness = height
	if target == _preset:
		_apply_vhs_amount()
		_apply_size()
		_update_preset_button()
		return true
	_preset = target
	var hq := _preset == PRESET_HQ
	Materials.render_hq_enabled = hq
	screen.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR if hq else CanvasItem.TEXTURE_FILTER_NEAREST
	_swap_compose_shader(hq)
	if hq:
		_saved_sky = world_env.sky
		_saved_background_mode = world_env.background_mode
		_saved_background_energy = world_env.background_energy_multiplier
		_saved_fog_enabled = world_env.fog_enabled
		world_env.fog_enabled = false
		world_env.fog_density = HQ_FOG_DENSITY_DUSK
		world_env.fog_light_color = world_env.background_color
		world_env.fog_light_energy = 0.55
		world_env.fog_sky_affect = 0.14
		world_env.background_energy_multiplier = HQ_SKY_ENERGY_DUSK
		world_env.adjustment_contrast = HQ_ADJUST_CONTRAST
		world_env.adjustment_saturation = HQ_ADJUST_SATURATION
	else:
		world_env.fog_enabled = _saved_fog_enabled
		world_env.sky = _saved_sky
		world_env.background_mode = _saved_background_mode
		world_env.background_energy_multiplier = _saved_background_energy
		world_env.adjustment_contrast = ADJUST_CONTRAST
		world_env.adjustment_saturation = ADJUST_SATURATION
	_apply_scene_material_quality(hq)
	_apply_size()
	_update_preset_button()
	return true


func _swap_compose_shader(hq: bool) -> void:
	var parameters: Dictionary = {}
	for uniform: Dictionary in _post_mat.shader.get_shader_uniform_list():
		var name: StringName = uniform["name"]
		var value: Variant = _post_mat.get_shader_parameter(name)
		if value != null:
			parameters[name] = value
	_post_mat.shader = load("res://shaders/vhs_compose_hq.gdshader" if hq
		else "res://shaders/vhs_compose.gdshader") as Shader
	for name: StringName in parameters:
		_post_mat.set_shader_parameter(name, parameters[name])
	_apply_vhs_amount()


func vhs_amount() -> float:
	return _vhs_amount


## Сила постоянной фактуры хранится отдельно от трекинга сюжетных сцен.
func set_vhs_amount(value: float) -> void:
	_vhs_amount = clampf(value, 0.0, 1.0) if is_finite(value) else VHS_DEFAULT
	_apply_vhs_amount()
	_update_vhs_button()


func _apply_vhs_amount() -> void:
	if _post_mat == null:
		return
	_post_mat.set_shader_parameter("effect_strength", _vhs_amount)
	_post_mat.set_shader_parameter("grain_strength", minf(1.0, _vhs_amount * 1.17))
	_post_mat.set_shader_parameter("quantization_strength", _vhs_amount if _preset == PRESET_RETRO else 0.0)
	_post_mat.set_shader_parameter("comb_strength", _vhs_amount if _preset == PRESET_RETRO else 0.0)


func _toggle_vhs_amount() -> void:
	var next := 0.0
	for step: float in VHS_STEPS:
		if step > _vhs_amount + 0.01:
			next = step
			break
	set_vhs_amount(next)
	var config := ConfigFile.new()
	var error := config.load(Overlays.CFG)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("VHS применён, но настройки не прочитаны: %s" % error)
		return
	config.set_value(Overlays.CFG_SECTION, VHS_CFG_KEY, _vhs_amount)
	error = config.save(Overlays.CFG)
	if error != OK:
		push_warning("Не удалось сохранить VHS: %s" % error)


func _update_vhs_button() -> void:
	if is_instance_valid(_vhs_button):
		_vhs_button.text = "VHS: выкл." if _vhs_amount < 0.01 else "VHS: %d%%" % roundi(_vhs_amount * 100.0)


func _apply_scene_material_quality(hq: bool) -> void:
	var pending: Array[Node] = [world_root, hand_root]
	var seen: Dictionary = {}
	var shadow_owners: Array[Node] = []
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		for child: Node in node.get_children():
			pending.append(child)
		if not node is GeometryInstance3D:
			continue
		var geometry := node as GeometryInstance3D
		if node is EnvironmentLod and node.has_method("refresh_shadow_material_policy"):
			shadow_owners.append(node)
		var materials: Array[Material] = [geometry.material_override, geometry.material_overlay]
		if node is MeshInstance3D:
			var instance := node as MeshInstance3D
			if instance.mesh != null:
				for index in instance.mesh.get_surface_count():
					materials.append(instance.get_active_material(index))
					materials.append(instance.mesh.surface_get_material(index))
			if node.has_method("quality_meshes"):
				var levels: Array = node.call("quality_meshes")
				for level: Mesh in levels:
					for index in level.get_surface_count():
						materials.append(level.surface_get_material(index))
		elif node is MultiMeshInstance3D:
			var multi := node as MultiMeshInstance3D
			if multi.multimesh != null and multi.multimesh.mesh != null:
				var mesh := multi.multimesh.mesh
				for index in mesh.get_surface_count():
					materials.append(mesh.surface_get_material(index))
		for material: Material in materials:
			if material == null or seen.has(material.get_instance_id()):
				continue
			seen[material.get_instance_id()] = true
			Materials.set_material_quality(material, hq)
	for owner: Node in shadow_owners:
		owner.call("refresh_shadow_material_policy")
	preload("res://src/static_shadow_batch.gd").set_hq(world_root, hq)
	var occlusion := world_root.get_node_or_null("EnvironmentOcclusion")
	if occlusion != null:
		occlusion.set_hq(hq)


## Нет файла или формат не подходит: прежнее небо остаётся без изменений.
func try_set_hq_panorama(path: String) -> bool:
	if world_env == null or not ResourceLoader.exists(path):
		return false
	var texture := load(path) as Texture2D
	if texture == null or texture.get_width() != 2048 or texture.get_height() != 1024:
		return false
	var material := PanoramaSkyMaterial.new()
	material.panorama = texture
	var sky := Sky.new()
	sky.sky_material = material
	world_env.sky = sky
	world_env.background_mode = Environment.BG_SKY
	world_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	return true


## Добавляем выбор рядом с чёткостью, сохраняя старые индексы настроек Overlays.
## Так старые конфиги и сохранения продолжают означать те же 360/540/720.
func bind_settings_ui(ui: Overlays) -> void:
	if ui == null or is_instance_valid(_preset_button):
		return
	var sharp := ui.get("_sharp") as Button
	if sharp == null:
		return
	_preset_ui = weakref(ui)
	_preset_button = Button.new()
	_preset_button.name = "RenderPreset"
	_preset_button.flat = true
	_preset_button.focus_mode = Control.FOCUS_NONE
	_preset_button.add_theme_color_override("font_color", Overlays.AMBER)
	_preset_button.add_theme_font_size_override("font_size", 12)
	_preset_button.custom_minimum_size = Vector2(126.0, 0.0)
	_preset_button.tooltip_text = "Чёткая картинка до 1280×720"
	sharp.get_parent().add_child(_preset_button)
	_preset_button.pressed.connect(_toggle_render_preset)
	_vhs_button = Button.new()
	_vhs_button.name = "VhsAmount"
	_vhs_button.flat = true
	_vhs_button.focus_mode = Control.FOCUS_NONE
	_vhs_button.add_theme_color_override("font_color", Overlays.AMBER)
	_vhs_button.add_theme_font_size_override("font_size", 12)
	_vhs_button.custom_minimum_size = Vector2(94.0, 0.0)
	_vhs_button.tooltip_text = "Зерно и цвет кассеты: выкл. / мягкий / средний / сильный"
	sharp.get_parent().add_child(_vhs_button)
	_vhs_button.pressed.connect(_toggle_vhs_amount)
	var config := ConfigFile.new()
	var configured_preset := PRESET_HQ
	if config.load(Overlays.CFG) == OK:
		configured_preset = String(config.get_value(Overlays.CFG_SECTION, RENDER_CFG_KEY, PRESET_HQ))
		set_vhs_amount(float(config.get_value(Overlays.CFG_SECTION, VHS_CFG_KEY, VHS_DEFAULT)))
	apply_preset(configured_preset)
	_skin_enabled = false
	_update_preset_button()
	_update_vhs_button()
	_update_skin_button()


func _toggle_render_preset() -> void:
	apply_preset(PRESET_RETRO if _preset == PRESET_HQ else PRESET_HQ)
	var config := ConfigFile.new()
	var error := config.load(Overlays.CFG)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("Пресет применён, но файл настроек не прочитан: %s" % error)
		return
	config.set_value(Overlays.CFG_SECTION, RENDER_CFG_KEY, _preset)
	error = config.save(Overlays.CFG)
	if error != OK:
		push_warning("Не удалось сохранить пресет рендера: %s" % error)


func _toggle_skin() -> void:
	_skin_enabled = not _skin_enabled
	_update_skin_button()
	skin_enabled_changed.emit(_skin_enabled)
	var config := ConfigFile.new()
	var error := config.load(Overlays.CFG)
	if error != OK and error != ERR_FILE_NOT_FOUND:
		push_warning("Скин переключён, но файл настроек не прочитан: %s" % error)
		return
	config.set_value(Overlays.CFG_SECTION, SkinLayer.CFG_KEY, _skin_enabled)
	error = config.save(Overlays.CFG)
	if error != OK:
		push_warning("Не удалось сохранить настройку скина: %s" % error)


func _update_skin_button() -> void:
	if is_instance_valid(_skin_button):
		_skin_button.text = "HQ-скин: ON" if _skin_enabled else "HQ-скин: OFF"


func _update_preset_button() -> void:
	if not is_instance_valid(_preset_button):
		return
	_preset_button.text = "Чёткая картинка" if _preset == PRESET_HQ else "Ретро-вид"
	if _preset_ui != null:
		var ui := _preset_ui.get_ref() as Overlays
		if ui != null:
			var sharp := ui.get("_sharp") as Button
			if sharp != null:
				sharp.disabled = _preset == PRESET_HQ


# ---------- режим кассеты ----------

func tape_viewport() -> SubViewport:
	return tape_view


func is_tape_mode() -> bool:
	return _tape_mode


## Пустить кадр кассеты через композит. Мир и руки на это время не считаются:
## их всё равно не видно, а это два кадра 3D на каждый кадр записи.
func begin_tape_mode() -> void:
	if _tape_mode:
		return
	_tape_mode = true
	world_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	hand_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	tape_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_post_mat.set_shader_parameter("tape_mode", 1.0)
	_fit_tape()


func end_tape_mode() -> void:
	if not _tape_mode:
		return
	_tape_mode = false
	tape_view.render_target_update_mode = SubViewport.UPDATE_DISABLED
	world_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	# Руки возвращаются в том состоянии, в котором были до кассеты: пустой
	# вьюпорт после просмотра включать обратно незачем.
	hand_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if _hands_on \
		else SubViewport.UPDATE_DISABLED
	_post_mat.set_shader_parameter("tape_mode", 0.0)


## Есть ли что рисовать во вьюпорте рук. Единственный вызывающий — HeldItems:
## кассета временно подавляет вьюпорт, но не забывает выбранный предмет.
func set_hands_visible(on: bool) -> void:
	# UPDATE_DISABLED не очищает ViewportTexture: он замораживает последний
	# кадр. Гейт меняется до любых early-return, чтобы кат-сцена погасила руки
	# в тот же кадр и не унаследовала старую текстуру фонаря.
	_post_mat.set_shader_parameter("hand_mix", 1.0 if on else 0.0)
	if on == _hands_on:
		return
	_hands_on = on
	if _tape_mode:
		return
	hand_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on \
		else SubViewport.UPDATE_DISABLED


## Пиллярбокс: кадр 4:3 в буфере 16:9. Кадр тянем по высоте буфера, ширину
## считаем от неё, по бокам остаётся чернота. Высота буфера всегда 360, поэтому
## кадр всегда ложится ровно в 480x360 — увеличение 1.5x при любой форме окна,
## от 800x600 (полосы 0 px) до 3440x1440 (полосы по 190 px). Буфер уже 4:3
## не бывает (минимум 480x360 — это ровно 4:3), но ветку по ширине держим:
## BUFFER_MIN_W однажды поменяют, и обрежется кадр.
func _fit_tape() -> void:
	var a := float(_size.x) / float(_size.y)
	var half := Vector2(0.5, 0.5)
	if a >= 4.0 / 3.0:
		half = Vector2((4.0 / 3.0) / a * 0.5, 0.5)
	else:
		half = Vector2(0.5, 0.375 * a)
	_post_mat.set_shader_parameter("tape_half", half)

# ---------- отладка ----------

func stats() -> Dictionary:
	return {
		"calls": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME),
		"tris": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME),
		"objects": RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_OBJECTS_IN_FRAME),
		"buffer": "%dx%d" % [_size.x, _size.y],
	}

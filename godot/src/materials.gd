# Палитра поверхностей — порт src/world/materials.js.
#
# Текстуры не рисуются заново: процедурные canvas'ы сняты с живой игры пиксель в
# пиксель в parity/tex_*.png (какие именно — в parity/parity_meta.json), остальные
# лежат файлами в assets/tex. Ключи, scale (метры на повтор) и цвета — дословно
# из DEFS оригинала.
#
# Фильтрация: NEAREST на увеличении и мипмапы на уменьшении. В Godot это свойство
# сэмплера, а не текстуры, поэтому оно записано хинтом в шейдере.

class_name Materials
extends RefCounted

const TEX_DIR := "res://assets/tex/"
const PIC_DIR := "res://assets/pictures/"
const ATLAS_DIR := "res://assets/atlases/"
const PARITY_DIR := "res://parity/"
const PSX_SHADER := "res://shaders/psx.gdshader"
const HQ_SHADER := "res://shaders/psx_hq.gdshader"
const GROUND_SHADER := "res://shaders/psx_ground.gdshader"
const SKIN_ALPHA_SHADER := "res://shaders/psx_skin_alpha.gdshader"
const HQ_ALPHA_SHADER := "res://shaders/psx_hq_alpha.gdshader"
const HQ_OPAQUE_SHADER := "res://shaders/psx_hq_opaque.gdshader"
const HQ_OPAQUE_ALPHA_SHADER := "res://shaders/psx_hq_alpha_opaque.gdshader"
const HQ_GLASS_SHADER := "res://shaders/psx_hq_glass.gdshader"

static var render_hq_enabled := false
static var _imported_materials: Dictionary = {}

# DEFS из materials.js: gen -> откуда взять текстуру, color, scale, прозрачность.
# file != "" — текстура из assets/tex, иначе снятый canvas parity/tex_<key>.png.
# parity != "" — снятый canvas ЧУЖОГО ключа: шейдер умеет только умножение
# (psx.gdshader:78), и одна и та же доска под разным цветом даёт разный материал.
#
# Визуальный проход «грязный ретро-реализм»: каждый ключ описывает одну
# физическую поверхность. Спокойный albedo несёт материал, а общий wash/VHS —
# цвет времени и носителя; запечённого шума в новых текстурах нет.
const DEFS := {
	"boards": {"color": 0xffffff, "scale": 1.6, "file": "retro-floorboards.webp"},
	"plank": {"color": 0xffffff, "scale": 2.0, "file": "retro-wallpaper.webp"},
	# Красная вагонка. Шаг доски 12 см — отсюда scale 0.95 вместо 1.8: на прежнем
	# доска шла в четверть метра и дом читался щитовым.
	"siding": {"color": 0xffffff, "scale": 0.95, "file": "retro-red-siding.webp"},
	"shedwood": {"color": 0xffffff, "scale": 1.4, "file": "retro-shedwood.webp"},
	"brick": {"color": 0xffffff, "scale": 2.2, "file": "retro-sooted-brick.webp"},
	"concrete": {"color": 0xffffff, "scale": 2.4, "file": "retro-concrete-slabs.webp"},
	"whitewash": {"color": 0xffffff, "scale": 2.0, "file": "retro-whitewash.webp"},
	"dirt": {"color": 0xffffff, "scale": 2.2, "file": ""},
	"grass": {"color": 0xffffff, "scale": 3.0, "file": "retro-august-grass.webp"},
	"gravel": {"color": 0xffffff, "scale": 2.6, "file": ""},
	# Синяя металлокровля. Побочно синеют крыши сарая, туалета и правления —
	# так и на настоящей даче: железо на всё покупали разом.
	"roof": {"color": 0xffffff, "scale": 1.6, "file": "retro-blue-roof.webp"},
	"linoleum": {"color": 0xffffff, "scale": 2.4, "file": "retro-linoleum.webp"},
	"tile": {"color": 0xffffff, "scale": 1.2, "file": "Tiles107.webp"},
	"carpet": {"color": 0xffffff, "scale": 1.6, "file": "Carpet016.webp"},
	"glass": {"color": 0xffffff, "scale": 1.2, "file": "", "opacity": 0.34},
	"metal": {"color": 0x7d8288, "scale": 1.0, "file": "", "notex": true},
	"dark": {"color": 0x33383c, "scale": 1.0, "file": "", "notex": true},
	"paint": {"color": 0x93a08e, "scale": 1.0, "file": "", "notex": true},
	"fabric": {"color": 0x8d7b62, "scale": 1.0, "file": "", "notex": true},
	"silhouette": {"color": 0x1d232b, "scale": 1.0, "file": "", "notex": true},
	# Сруб бани: венец 27.5 см при scale 2.2 и восьми брёвнах на повтор доски.
	"log": {"color": 0xffffff, "scale": 2.2, "file": "retro-log.webp"},
	# Плитка дорожек, 30 см. Швы идут по мировой сетке, поэтому дорожка от
	# калитки и дорожка у бани стыкуются без подрезки.
	"walkway": {"color": 0xffffff, "scale": 2.4, "file": "retro-concrete-slabs.webp"},
	"plinth": {"color": 0xb6ae9a, "scale": 1.1, "file": "retro-whitewash.webp"},
	"trim": {"color": 0xd8d2c2, "scale": 1.0, "file": "", "notex": true},
	# Коричневый профнастил по боковым заборам. Волна 13 см — доска сарая,
	# сжатая вдвое и приглушённая отдельным тоном.
	"profile": {"color": 0xa88d78, "scale": 1.7, "file": "retro-shedwood.webp"},
	# Хвоя леса за задним забором. Свой ключ, а не 'silhouette': тот 0x1d232b
	# и в сумерках сливается с небом в чёрную стену — от бани полнеба
	# становилось дырой. Тон почти такой же тёмный, но зелёный, и луна его
	# лепит: лес читается лесом, а не пустотой.
	"conifer": {"color": 0x2c3a30, "scale": 1.0, "file": "", "notex": true},
	# ФАЗА 12 — деревня. Два ключа, и оба нужны ровно потому, что «взять
	# похожий» здесь означает «взять чужой»:
	# 'tin' — светлая оцинковка навеса остановки и домика над колодцем. От
	# 'metal' (0x7d8288) она отличается тем, что видна ночью: жесть ловит луну,
	# а тёмный металл на фоне тумана пропадает вместе с навесом.
	"tin": {"color": 0xa7b0b4, "scale": 1.2, "file": "", "notex": true},
	# 'counter' — отдельная вытертая зелёная краска прилавка сельпо: общая
	# половица здесь давала слишком крупный рисунок и неоновый оттенок.
	"counter": {"color": 0xffffff, "scale": 1.3, "file": "retro-green-counter.webp"},
	# Дальний дом получает приглушённую обшивку вместо чёрного прямоугольника;
	# наличники и окна добавляет visual_dressing в том же merged bucket.
	"neighbour": {"color": 0xffffff, "scale": 1.0, "file": "retro-neighbour-siding.webp"},
	# Кровля соседей темнее стен ровно настолько, чтобы конёк читался линией.
	# Отдельный ключ, а не оттенок: скаты кладёт _slope с collide=true, они
	# сидят в паритетной статике, и трогать у них можно только ключ материала.
	"neighbourroof": {"color": 0x6f7780, "scale": 1.6, "file": "retro-blue-roof.webp"},
	# Семантические фасады улицы/второй линии. Геометрические builders читают
	# эти ключи из данных: стиль больше не зашит в общий `neighbour`.
	"siding-red-old": {"color": 0x6b3630, "scale": 1.05,
		"file": "retro-neighbour-siding.webp"},
	"siding-grey-old": {"color": 0x77766f, "scale": 1.10,
		"file": "retro-neighbour-siding.webp"},
	"siding-ochre": {"color": 0x9a805f, "scale": 1.0,
		"file": "retro-neighbour-siding.webp"},
	"roof-rust": {"color": 0x76594d, "scale": 1.55, "file": "retro-blue-roof.webp"},
	"roof-grey": {"color": 0x666b6c, "scale": 1.55, "file": "retro-blue-roof.webp"},
	# ФАЗА 14 — околица. Зеркальная гладь пожарного пруда и вода в бочке
	# у грядок: один ключ на оба, тон темнее стекла и с той же прозрачностью.
	"water": {"color": 0x6f8990, "scale": 1.0,
		"file": "waterway-psx-atlas-v2.png", "dir": ATLAS_DIR, "opacity": 0.62},
	# Бумага и патина всего мира объединяются ровно в два atlas buckets.
	"dressing-paper-atlas": {"color": 0xffffff, "scale": 1.0,
		"file": "paper-atlas.webp", "dir": ATLAS_DIR},
	"dressing-patina-atlas": {"color": 0xffffff, "scale": 1.0,
		"file": "patina-atlas.png", "dir": ATLAS_DIR, "opacity": 1.0,
		"cut": 0.42, "double_sided": true},
}

# В HQ эти поверхности держат широкий влажный блик. Значения остаются далеко
# от зеркала и не требуют SSR; ретро-шейдер параметр шероховатости не читает.
const HQ_GROUND_ROUGHNESS := {
	"grass": 0.92,
	"dirt": 0.93,
	"gravel": 0.87,
}

# Офлайн-текстуры GDScript. Фотографии, документы и кассеты используют прежние ресурсы.
const PROCEDURAL_SURFACES := {
	"boards": ["boards", 0xffffff], "plank": ["wallpaper", 0xffffff],
	"siding": ["wood", 0xa85d4d], "shedwood": ["wood", 0x988771],
	"brick": ["brick", 0xffffff], "concrete": ["concrete", 0xffffff],
	"whitewash": ["whitewash", 0xffffff], "dirt": ["soil", 0xffffff],
	"grass": ["grass", 0xffffff], "gravel": ["gravel", 0xffffff],
	"roof": ["roof", 0xb9cadc], "linoleum": ["linoleum", 0xffffff],
	"walkway": ["concrete", 0xffffff], "plinth": ["whitewash", 0xc9c2ad],
	"profile": ["roof", 0xbdb2a1], "neighbour": ["wood", 0xb9b3a0],
	"neighbourroof": ["roof", 0xffffff], "counter": ["wood", 0x82a487],
	"siding-red-old": ["wood", 0xa06a5b], "siding-grey-old": ["wood", 0xb7b8ad],
	"siding-ochre": ["wood", 0xc6a56f], "roof-rust": ["rusted_metal", 0xffffff],
	"roof-grey": ["roof", 0xe0e1de],
}

const PICTURES := {
	"vatnik": "vatnik-v2.webp",
	"prorub": "prorub-v2.webp",
	"lake-1": "lake-1-v2.webp",
	"lake-2": "lake-2-v2.webp",
	# Фаза 9: три снимка из ТЗ. Файлы делает tools/gen_photos.py из DOCX —
	# кроп и размер, без перерисовки, как ТЗ и требует.
	"grandson": "photo-grandson.webp",
	"tonya": "photo-tonya.webp",
	"nephew": "photo-nephew.webp",
}

# Палитра реквизита: восемнадцать тонов на весь дом — бюджет draw calls, а не бедность.
const PALETTE := [
	0x1c1e21, 0x2b2f33, 0x3a3f43, 0x4e5459, 0x6f767c, 0x8b9095, 0xa8aeb3,
	0x4a3524, 0x5d4530, 0x6d4c31, 0x8a6a45, 0xa38a63,
	0x7f7663, 0x9c9482, 0xb6ae9a, 0xc9c3ac,
	0x54703f, 0x8a5540, 0x9c6a3a, 0x3d4b52, 0x93a9b4, 0x4a5f52,
]

# Забор из build.js: 45 см на клетку, alphaTest 0.42, двусторонняя плоскость.
# Фаза 11: рабица стала чёрным штакетником вдоль улицы — одной текстурой и одним
# тоном, без единой новой коробки. fence() рисует весь периметр через
# plane(..., "meshfence"), коллизия уже стоит в SET_STATIC, и створки ворот
# с калиткой едут следом за той же текстурой. Файла нет — прежняя рабица.
const FENCE_SCALE := 0.45
const FENCE_TINT := 0x2b2f33
const FENCE_ALPHA_CUT := 0.42
const FENCE_TEX := "picket.png"

var map: Dictionary = {}          # ключ -> Material
var pics: Dictionary = {}         # ключ картины -> Material
var ready := false
var ground_skin_error := ""

var _psx: Shader = null
var _alpha_shader: Shader = null
var _water_shader: Shader = null
var _flat_cache: Dictionary = {}
var _glow_cache: Dictionary = {}
var _scale: Dictionary = {}
var _fence_mat: Material = null


func load_all() -> Materials:
	_psx = load(PSX_SHADER) as Shader
	for key: String in DEFS.keys():
		var def: Dictionary = DEFS[key]
		var tex: Texture2D = null
		if not def.get("notex", false):
			if def["file"] != "":
				tex = _try_load(String(def.get("dir", TEX_DIR)) + String(def["file"]))
			if tex == null and String(def.get("parity", "")) != "":
				tex = _try_load(PARITY_DIR + "tex_" + String(def["parity"]) + ".png")
			if tex == null:
				tex = _try_load(PARITY_DIR + "tex_" + key + ".png")
		var surface_color := int(def["color"])
		if PROCEDURAL_SURFACES.has(key):
			var surface: Array = PROCEDURAL_SURFACES[key]
			var baked := _try_load("res://assets/generated/textures/" + String(surface[0]) + ".res")
			if baked != null:
				tex = baked
				surface_color = int(surface[1])
		var mat: Material
		if key == "water":
			mat = _make_water(tex)
		elif def.has("opacity"):
			mat = _make_alpha(surface_color, tex, float(def["opacity"]),
				float(def.get("cut", 0.0)), bool(def.get("double_sided", false)))
		else:
			mat = _make_psx(surface_color, tex)
		var hq_params := {}
		if key in ["metal", "tin", "glass"]:
			hq_params["roughness_value"] = 0.38 if key != "glass" else 0.18
		if PROCEDURAL_SURFACES.has(key):
			var family := String(PROCEDURAL_SURFACES[key][0])
			var normal_map := _try_load("res://assets/generated/textures/" + family + "-normal.res")
			if normal_map != null:
				hq_params["normal_tex"] = normal_map
				hq_params["use_normal"] = true
				hq_params["normal_strength"] = 0.45
		if HQ_GROUND_ROUGHNESS.has(key):
			hq_params["roughness_value"] = float(HQ_GROUND_ROUGHNESS[key])
		for field: String in ["normal", "roughness", "ao"]:
			var filename := String(def.get(field + "_file", ""))
			if filename.is_empty():
				continue
			var detail := _try_load(TEX_DIR + filename)
			if detail != null:
				hq_params[field + "_tex"] = detail
				hq_params["use_" + field] = true
		if not hq_params.is_empty() and mat is ShaderMaterial:
			(mat as ShaderMaterial).set_meta("skin_hq_params", hq_params)
			if render_hq_enabled:
				for parameter: String in hq_params:
					(mat as ShaderMaterial).set_shader_parameter(parameter, hq_params[parameter])
		map[key] = mat
		_scale[key] = float(def["scale"])
	for key: String in PICTURES.keys():
		var tex := _try_load(PIC_DIR + String(PICTURES[key]))
		if tex != null:
			pics[key] = _make_psx(0xffffff, tex)
		else:
			# Файла нет — игра всё равно должна запуститься, на стене будет серая доска.
			pics[key] = flat(0x7f7663)
	ready = true
	return self


func _try_load(path: String) -> Texture2D:
	if not ResourceLoader.exists(path):
		return null
	return load(path) as Texture2D


func _make_psx(color: int, tex: Texture2D) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _psx
	if render_hq_enabled:
		set_material_quality(m, true)
	m.set_shader_parameter("albedo", GameData.color(color))
	if tex != null:
		m.set_shader_parameter("albedo_tex", tex)
	return m


# Прозрачные поверхности (стекло, рабица) — тот же PSX-вид, но с альфой.
# Отдельный шейдер, потому что psx.gdshader непрозрачный; когда R заведёт
# shaders/psx_alpha.gdshader, это место схлопнется в один load().
func _make_alpha(color: int, tex: Texture2D, opacity: float, cut: float, double_sided: bool) -> ShaderMaterial:
	if _alpha_shader == null:
		_alpha_shader = Shader.new()
		_alpha_shader.code = _ALPHA_CODE
	var m := ShaderMaterial.new()
	m.shader = _alpha_shader
	var c := GameData.color(color)
	c.a = opacity
	m.set_shader_parameter("albedo", c)
	m.set_shader_parameter("alpha_cut", cut)
	m.set_shader_parameter("double_sided", 1.0 if double_sided else 0.0)
	if tex != null:
		m.set_shader_parameter("albedo_tex", tex)
	m.render_priority = 1
	if render_hq_enabled:
		set_material_quality(m, true)
	return m


## Дешёвая вода без отражений и преломления: две медленные выборки одного
## PSX-атласа, квантованные UV и вертикальный ход меньше сантиметра.
func _make_water(tex: Texture2D) -> ShaderMaterial:
	if _water_shader == null:
		_water_shader = Shader.new()
		_water_shader.code = _WATER_CODE
	var m := ShaderMaterial.new()
	m.shader = _water_shader
	if tex != null:
		m.set_shader_parameter("water_atlas", tex)
	m.render_priority = 1
	if render_hq_enabled:
		set_material_quality(m, true)
	return m


const _WATER_CODE := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled, blend_mix, depth_draw_opaque, cull_disabled;

uniform sampler2D water_atlas : source_color, filter_nearest_mipmap, repeat_enable;
varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float a = sin((world_pos.x + world_pos.z) * 1.45 + TIME * 0.19);
	float b = sin((world_pos.x - world_pos.z) * 0.91 - TIME * 0.13);
	VERTEX.y += (a + b) * 0.0035;
}

void fragment() {
	float deep_layer = step(50.0, UV.x);
	vec2 raw_uv = UV - vec2(deep_layer * 100.0, 0.0);
	vec2 q = floor(raw_uv * 64.0) / 64.0;
	vec2 uv_a = fract(q * 0.21 + vec2(TIME * 0.0022, TIME * 0.0011));
	vec2 uv_b = fract(q * 0.17 + vec2(-TIME * 0.0013, TIME * 0.0018));
	vec3 a = texture(water_atlas, uv_a).rgb;
	vec3 b = texture(water_atlas, uv_b).rgb;
	vec3 atlas_mix = mix(a, b, 0.43);
	vec3 depth = vec3(0.090, 0.140, 0.130);
	vec3 shallow = mix(depth, atlas_mix * vec3(0.58, 0.70, 0.64), 0.68);
	ALBEDO = mix(shallow, depth * 0.78, deep_layer * 0.42);
	ROUGHNESS = 1.0;
	ALPHA = 0.76;
}
"""


const _ALPHA_CODE := """
shader_type spatial;
render_mode diffuse_lambert, specular_disabled, blend_mix, depth_draw_opaque, cull_disabled;

uniform vec2 psx_snap = vec2(192.0, 144.0);
uniform float psx_affine = 1.0;
uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap_anisotropic, repeat_enable;
uniform float alpha_cut = 0.0;
uniform float double_sided = 0.0;
/* Туман тот же, что у psx.gdshader, и по тем же глобальным uniform'ам. Раньше
   здесь стояли числа ночного пресета намертво: в сумерках рабица тонула в дымке,
   которой вокруг неё ещё не было, а после правки fogFar ночью торчала бы
   за стеной тумана. Глобальные объявлены в project.godot, так что шейдер
   собирается и в headless-тестах, где RenderChain не создаётся. */
global uniform vec3 psx_fog_color;
global uniform float psx_fog_near;
global uniform float psx_fog_far;

varying vec2 v_psx_uv;
varying float v_psx_w;

void vertex() {
	vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float w = max(0.0001, clip.w);
	vec2 ndc = clip.xy / w;
	ndc = floor(ndc * psx_snap + 0.5) / psx_snap;
	clip.x = ndc.x * w;
	clip.y = ndc.y * w;
	POSITION = clip;
	v_psx_w = mix(1.0, clip.w, psx_affine);
	v_psx_uv = UV * v_psx_w;
}

void fragment() {
	vec2 uv = v_psx_uv / max(0.0001, v_psx_w);
	vec4 t = texture(albedo_tex, uv);
	ALBEDO = albedo.rgb * t.rgb;
	float a = albedo.a * t.a;
	if (alpha_cut > 0.0 && a < alpha_cut) {
		discard;
	}
	ALPHA = a;
	FOG = vec4(psx_fog_color, smoothstep(psx_fog_near, psx_fog_far, -VERTEX.z));
}

void light() {
	float d = dot(NORMAL, LIGHT);
	if (double_sided > 0.5) {
		d = abs(d);
	}
	DIFFUSE_LIGHT += clamp(d, 0.0, 1.0) * ATTENUATION * LIGHT_COLOR / PI;
}
"""


# ---------- скин земли и импортированных материалов ----------

## Меняем общий ресурс: плоскости уже могут хранить ссылку на него после build().
## Сначала проверяем все карты, чтобы битая запись не оставила половину замены.
func apply_ground_skin(key: String, entry: Dictionary) -> bool:
	ground_skin_error = ""
	var material_key := key.trim_prefix("ground/")
	if not map.has(material_key) or not map[material_key] is ShaderMaterial:
		ground_skin_error = "неизвестный материал земли: " + material_key
		return false
	if not entry.has("albedo"):
		ground_skin_error = "нужна карта albedo"
		return false
	var params: Dictionary = {"use_normal": false, "use_roughness": false, "use_ao": false}
	for field: String in ["albedo", "normal", "roughness", "ao"]:
		if not entry.has(field):
			continue
		var value: Variant = entry[field]
		if field == "roughness" and (value is float or value is int):
			params["roughness_value"] = clampf(float(value), 0.0, 1.0)
			continue
		var texture: Texture2D = _skin_texture(value)
		if texture == null:
			ground_skin_error = "не удалось загрузить карту " + field
			return false
		params[field + "_tex"] = texture
		if field != "albedo":
			params["use_" + field] = true
	params["albedo"] = Color.WHITE
	params["roughness_value"] = clampf(float(entry.get("roughness_value",
		params.get("roughness_value", 0.9))), 0.0, 1.0)
	params["normal_strength"] = clampf(float(entry.get("normal_strength", 1.0)), 0.0, 4.0)
	var uv: Variant = entry.get("uv_scale", [1.0, 1.0])
	if not uv is Array or uv.size() != 2 or float(uv[0]) <= 0.0 or float(uv[1]) <= 0.0:
		ground_skin_error = "uv_scale должен содержать два положительных числа"
		return false
	params["uv_scale"] = Vector2(float(uv[0]), float(uv[1]))
	var mat: ShaderMaterial = map[material_key]
	mat.shader = load(GROUND_SHADER) as Shader
	if mat.has_meta("skin_retro_shader"):
		mat.remove_meta("skin_retro_shader")
	mat.set_meta("skin_hq_params", params)
	for parameter: String in params:
		mat.set_shader_parameter(parameter, params[parameter])
	if render_hq_enabled:
		set_material_quality(mat, true)
	return true


static func _skin_texture(value: Variant) -> Texture2D:
	if value is Texture2D:
		return value as Texture2D
	if value is String and String(value).begins_with("res://") and ResourceLoader.exists(value):
		return load(value) as Texture2D
	return null


## Карты храним рядом с ретро-материалом: смена пресета не требует нового GLB.
static func convert_imported_material(source: Material, hq := false) -> Material:
	if _imported_materials.has(source):
		var cached: Material = _imported_materials[source]
		set_material_quality(cached, hq or render_hq_enabled)
		return cached
	if source is ShaderMaterial:
		var copied := source.duplicate() as ShaderMaterial
		set_material_quality(copied, hq or render_hq_enabled)
		_imported_materials[source] = copied
		return copied
	var mat := ShaderMaterial.new()
	mat.shader = load(PSX_SHADER) as Shader
	var params: Dictionary = {"albedo": Color.WHITE}
	if source is BaseMaterial3D:
		var base := source as BaseMaterial3D
		params["albedo"] = base.albedo_color
		params["use_vertex_color"] = base.vertex_color_use_as_albedo
		params["roughness_value"] = base.roughness
		params["metallic_value"] = base.metallic
		params["uv_scale"] = Vector2(base.uv1_scale.x, base.uv1_scale.y)
		params["uv_offset"] = Vector2(base.uv1_offset.x, base.uv1_offset.y)
		if base.albedo_texture != null:
			params["albedo_tex"] = base.albedo_texture
		if base.normal_enabled and base.normal_texture != null:
			params["normal_tex"] = base.normal_texture
			params["use_normal"] = true
			params["normal_strength"] = base.normal_scale
		if base.roughness_texture != null:
			params["roughness_tex"] = base.roughness_texture
			params["use_roughness"] = true
			params["roughness_channel"] = _texture_channel(base.roughness_texture_channel)
		if base.ao_enabled and base.ao_texture != null:
			params["ao_tex"] = base.ao_texture
			params["use_ao"] = true
			params["ao_on_uv2"] = base.ao_on_uv2
			params["ao_uv2_scale"] = Vector2(base.uv2_scale.x, base.uv2_scale.y)
			params["ao_uv2_offset"] = Vector2(base.uv2_offset.x, base.uv2_offset.y)
			params["ao_channel"] = _texture_channel(base.ao_texture_channel)
		if base.emission_enabled:
			params["emission_color"] = base.emission * base.emission_energy_multiplier
		if base.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
			mat.shader = load(SKIN_ALPHA_SHADER) as Shader
			params["alpha_cut"] = base.alpha_scissor_threshold if base.transparency == BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR else 0.42
		if base.cull_mode == BaseMaterial3D.CULL_DISABLED:
			mat.shader = load(SKIN_ALPHA_SHADER) as Shader
			params["double_sided"] = 1.0
	mat.set_meta("skin_hq_params", params)
	for parameter: String in params:
		mat.set_shader_parameter(parameter, params[parameter])
	if hq or render_hq_enabled:
		set_material_quality(mat, true)
	_imported_materials[source] = mat
	return mat


static func _texture_channel(channel: int) -> Vector4:
	match channel:
		BaseMaterial3D.TEXTURE_CHANNEL_GREEN:
			return Vector4(0.0, 1.0, 0.0, 0.0)
		BaseMaterial3D.TEXTURE_CHANNEL_BLUE:
			return Vector4(0.0, 0.0, 1.0, 0.0)
		BaseMaterial3D.TEXTURE_CHANNEL_ALPHA:
			return Vector4(0.0, 0.0, 0.0, 1.0)
		BaseMaterial3D.TEXTURE_CHANNEL_GRAYSCALE:
			return Vector4(0.333333, 0.333333, 0.333333, 0.0)
	return Vector4(1.0, 0.0, 0.0, 0.0)


## Ресурс материала остаётся тем же: merged buckets и MultiMesh сохраняют ссылки.
static func set_material_quality(material: Material, hq: bool) -> void:
	if not material is ShaderMaterial:
		return
	var mat := material as ShaderMaterial
	if mat.shader == null:
		return
	if not hq:
		if mat.has_meta("skin_retro_shader"):
			mat.shader = mat.get_meta("skin_retro_shader") as Shader
			mat.remove_meta("skin_retro_shader")
		return
	if mat.has_meta("skin_retro_shader"):
		refresh_opaque_hq(mat)
		return
	if mat.shader.resource_path in [HQ_SHADER,HQ_ALPHA_SHADER,HQ_OPAQUE_SHADER,HQ_OPAQUE_ALPHA_SHADER]:
		refresh_opaque_hq(mat)
		return
	var path := mat.shader.resource_path
	var legacy_alpha := mat.shader.code == _ALPHA_CODE
	var legacy_water := mat.shader.code == _WATER_CODE
	if path not in [PSX_SHADER, GROUND_SHADER, SKIN_ALPHA_SHADER] and not legacy_alpha and not legacy_water:
		return
	mat.set_meta("skin_retro_shader", mat.shader)
	var shader_path := HQ_SHADER
	if legacy_water:
		shader_path = "res://shaders/psx_water_hq.gdshader"
	elif legacy_alpha:
		shader_path = HQ_GLASS_SHADER
	elif path == SKIN_ALPHA_SHADER:
		shader_path = HQ_ALPHA_SHADER
	mat.shader = load(shader_path) as Shader
	var params: Dictionary = mat.get_meta("skin_hq_params", {})
	for parameter: String in params:
		mat.set_shader_parameter(parameter, params[parameter])
	refresh_opaque_hq(mat)


## Call after an explicit alpha_cut edit, or use set_material_quality again.
## ShaderMaterial parameter writes do not emit Resource.changed at runtime.
static func refresh_opaque_hq(mat: ShaderMaterial) -> void:
	if mat == null or mat.shader == null: return
	var path := mat.shader.resource_path
	var base := ""
	var opaque := ""
	if path in [HQ_SHADER,HQ_OPAQUE_SHADER]:
		base = HQ_SHADER
		opaque = HQ_OPAQUE_SHADER
	elif path in [HQ_ALPHA_SHADER,HQ_OPAQUE_ALPHA_SHADER]:
		base = HQ_ALPHA_SHADER
		opaque = HQ_OPAQUE_ALPHA_SHADER
	else: return
	var cut: Variant = mat.get_shader_parameter("alpha_cut")
	var safe: bool = cut == null or ((cut is float or cut is int) and is_finite(float(cut)) and float(cut) <= 0.0)
	var selected := opaque if safe else base
	if path != selected: mat.shader = load(selected) as Shader


# ---------- запросы ----------

func get_mat(key: String) -> Material:
	if map.has(key):
		return map[key]
	return map.get("concrete", null)


# Метров на один повтор текстуры — строителю для расчёта мировых UV.
func scale(key: String) -> float:
	if key == "meshfence":
		return FENCE_SCALE
	return float(_scale.get(key, 1.0))


# Материал картины по ключу PICTURES: один материал на ключ, две одинаковые
# картины на разных стенах сольются в одну сетку.
func picture(key: String) -> Material:
	if pics.has(key):
		return pics[key]
	return flat(0x7f7663)


# Материал под простой цвет. Цвет притягивается к ближайшему тону палитры:
# полсотни почти одинаковых коричневых — это полсотни лишних draw call,
# а под PSX-квантованием разницы между 0x6b4b30 и 0x6a4a30 всё равно нет.
func flat(color: int, exact := false) -> Material:
	var snapped := color if exact or render_hq_enabled else snap_to_palette(color)
	var k := "flat:%d" % snapped
	if _flat_cache.has(k):
		return _flat_cache[k]
	var m := _make_psx(snapped, null)
	_flat_cache[k] = m
	return m


## Материальная поверхность небольшого реквизита и одежды. Карты уже лежат
## в bake-кэше; roughness/metallic сохраняются при переключении HQ.
func physical(color: int, texture_family := "", roughness := 0.85, metallic := 0.0) -> Material:
	var key := "physical:%d:%s:%.3f:%.3f" % [color, texture_family, roughness, metallic]
	if _flat_cache.has(key):
		return _flat_cache[key]
	var texture: Texture2D = null
	if texture_family != "":
		var path := ProceduralAssets.texture_path(texture_family)
		if ResourceLoader.exists(path):
			texture = load(path) as Texture2D
	var material := _make_psx(color, texture)
	var params: Dictionary = material.get_meta("skin_hq_params", {})
	params["roughness_value"] = clampf(roughness, 0, 1)
	params["metallic_value"] = clampf(metallic, 0, 1)
	material.set_meta("skin_hq_params", params)
	for parameter: String in params:
		material.set_shader_parameter(parameter, params[parameter])
	_flat_cache[key] = material
	return material


# Самосветящийся материал: лампочки, экраны, окна чужих домов.
func glow(color: int, opacity := 1.0) -> Material:
	var k := "glow:%d:%f" % [color, opacity]
	if _glow_cache.has(k):
		return _glow_cache[k]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	var c := GameData.color(color)
	if opacity < 1.0:
		c.a = opacity
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.albedo_color = c
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	_glow_cache[k] = m
	return m


# Забор: сперва штакетник фазы 11 (assets/tex/picket.png), при его отсутствии —
# снятая рабица прототипа. Мипмапы у обоих выключены навсегда: alpha-test 0.42
# на уменьшении растворяет и сетку, и просветы между штакетинами.
func mesh_fence() -> Material:
	if _fence_mat != null:
		return _fence_mat
	var tex := _try_load(TEX_DIR + FENCE_TEX)
	if tex == null:
		tex = _try_load(PARITY_DIR + "meshfence.png")
	_fence_mat = _make_alpha(FENCE_TINT, tex, 1.0, FENCE_ALPHA_CUT, true)
	return _fence_mat


# ---------- прогрев шейдеров ----------

# В Compatibility убершейдеров нет: шейдер компилируется в момент, когда его
# материал впервые попадает в кадр. Отсюда документированный фриз Godot —
# на первом же показе нового материала, то есть ровно там, где игра этого
# меньше всего хочет. У нас таких мест два: первый выход за ворота (каркасы
# улицы) и первое включение фонаря.
#
# Лечение штатное: показать все материалы разом, пока экран занят карточками.
# Квадики размером в сантиметр стоят вплотную к камере, живут несколько кадров
# и удаляются — в кадре их не видно, а компиляция уже прошла.
func warm_up(root: Node3D, at: Vector3, scene: Node = null) -> Node3D:
	if root == null:
		return null
	var holder := Node3D.new()
	holder.name = "ShaderWarmUp"
	holder.position = at
	var seen: Dictionary = {}
	var list: Array = []
	list.append_array(map.values())
	list.append_array(pics.values())
	list.append_array(_flat_cache.values())
	list.append_array(_glow_cache.values())
	list.append(mesh_fence())
	if scene != null:
		_collect_warm_materials(scene, list)
	var shaders: Dictionary = {}
	var i := 0
	for m: Material in list:
		if m == null or seen.has(m.get_instance_id()):
			continue
		seen[m.get_instance_id()] = true
		var q := QuadMesh.new()
		q.size = Vector2(0.003, 0.003)
		var mi := MeshInstance3D.new()
		mi.mesh = q
		mi.material_override = m
		# Компактная сетка: даже последний материал остаётся внутри фрустума.
		mi.position = Vector3(-0.10 + 0.006 * (i % 32), -0.08 + 0.006 * (i / 32), -0.30)
		holder.add_child(mi)
		i += 1
		# Instancing собирает отдельный вариант GLES-шейдера.
		var shader_key: int = m.shader.get_instance_id() if m is ShaderMaterial and m.shader != null else m.get_instance_id()
		if not shaders.has(shader_key):
			shaders[shader_key] = true
			var mm := MultiMesh.new()
			mm.transform_format = MultiMesh.TRANSFORM_3D
			mm.mesh = q
			mm.instance_count = 1
			mm.set_instance_transform(0, Transform3D(Basis.IDENTITY, mi.position + Vector3(0, 0.002, 0)))
			var instanced := MultiMeshInstance3D.new()
			instanced.multimesh = mm
			instanced.material_override = m
			holder.add_child(instanced)
	var omni := OmniLight3D.new()
	omni.name = "WarmOmni"
	omni.position = Vector3(0, 0, -0.15)
	omni.omni_range = 1.0
	omni.visible = false
	holder.add_child(omni)
	var spot := SpotLight3D.new()
	spot.name = "WarmSpot"
	spot.spot_range = 1.0
	spot.spot_angle = 50.0
	spot.shadow_enabled = true
	spot.visible = false
	holder.add_child(spot)
	root.add_child(holder)
	return holder


func _collect_warm_materials(node: Node, out: Array) -> void:
	var mesh: Mesh = null
	var override: Material = null
	if node is MeshInstance3D:
		mesh = node.mesh
		override = node.material_override
	elif node is MultiMeshInstance3D:
		mesh = node.multimesh.mesh if node.multimesh != null else null
		override = node.material_override
	if mesh != null:
		if override != null:
			out.append(override)
		else:
			for surface in mesh.get_surface_count():
				out.append(node.get_active_material(surface) if node is MeshInstance3D else mesh.surface_get_material(surface))
	if node.has_method("quality_meshes"):
		var levels: Array = node.call("quality_meshes")
		for level: Mesh in levels:
			for surface in level.get_surface_count():
				out.append(level.surface_get_material(surface))
	for child: Node in node.get_children():
		_collect_warm_materials(child, out)


func snap_to_palette(hex: int) -> int:
	var r := (hex >> 16) & 255
	var g := (hex >> 8) & 255
	var b := hex & 255
	var best: int = PALETTE[0]
	var best_d := INF
	for p: int in PALETTE:
		var dr := ((p >> 16) & 255) - r
		var dg := ((p >> 8) & 255) - g
		var db := (p & 255) - b
		var d := dr * dr * 0.3 + dg * dg * 0.59 + db * db * 0.11
		if d < best_d:
			best_d = d
			best = p
	return best

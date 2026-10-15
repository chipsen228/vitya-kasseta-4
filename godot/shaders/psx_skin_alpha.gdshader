/* PSX-вид не ассетами, а шейдером. Порт src/engine/psx.js (VERT_MAIN, FRAG_MAP)
   плюс туман THREE.Fog из build.js и cookie фонаря из flashlight.js.

   Три вещи, которые делают картинку «первой плойкой»:
   1) вершины снапаются в сетку низкого разрешения прямо в clip-space — отсюда дрожание рёбер;
   2) UV интерполируются аффинно, без перспективной коррекции — отсюда «плывущие» текстуры;
   3) цвет квантуется с упорядоченным дизерингом 4x4 — отсюда рябь на градиентах.

   Пункт 3 в порту живёт не здесь, а в vhs_compose.gdshader: в оригинале он стоял
   последней строкой фрагмента материала, а в Godot после light() дописать в цвет
   нечего. Пиксели те же — буфер мира и буфер композита одного размера.

   Cookie фонаря сэмплится вручную: light_projector в Compatibility не работает.
   Матрица проектора, позиция фонаря и «горит/не горит» приезжают глобальными
   uniform'ами из flashlight.gd — иначе их пришлось бы дублировать в каждый материал. */

shader_type spatial;
/* fog_disabled НЕ ставим намеренно: с ним движок выкидывает ветку тумана целиком
   вместе с нашей записью в FOG. Свой туман пишем в FOG, средовой в Environment выключен. */
render_mode diffuse_lambert, specular_disabled, cull_disabled;

/* Сетка снапа. У оригинала было 160x120 под буфер высотой 360; буфер вырос
   до 540, и та же сетка стала давать заметно более крупную дрожь, чем в браузере.
   192x144 — те же 1.2x, что и по высоте буфера: на глаз рёбра дрожат как прежде. */
uniform vec2 psx_snap = vec2(192.0, 144.0);
uniform float psx_affine = 1.0;

/* Аналог MeshLambertMaterial({ color, map }): цвет умножается на текстуру.
   Незаданный sampler2D Godot подставляет белым — материалам без карты
   (плоские стены, крашеные доски) отдельная заглушка не нужна. */
uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform bool use_vertex_color = false;
/* Анизотропия к мипмапам: пол, гравий и дорожка почти всегда под скользящим
   углом, и без неё дальний конец коридора уходит в ровную кашу. */
uniform sampler2D albedo_tex : source_color, filter_nearest_mipmap_anisotropic, repeat_enable;

/* 0 для вьюмодели фонаря. Она живёт в своём мире со своим светом, а глобальные
   uniform'ы проектора общие на проект: без этого переключателя рука рисковала бы
   поймать cookie от собственной подсветки. */
uniform float psx_cookie = 1.0;
// Карты HQ-ассетов имеют общую UV-развёртку; нормали экспортируют в OpenGL.
uniform vec2 uv_scale = vec2(1.0);
uniform vec2 uv_offset = vec2(0.0);
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D roughness_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D ao_tex : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform bool use_normal = false;
uniform bool use_roughness = false;
uniform bool use_ao = false;
uniform bool ao_on_uv2 = false;
uniform vec2 ao_uv2_scale = vec2(1.0);
uniform vec2 ao_uv2_offset = vec2(0.0);
uniform float normal_strength = 1.0;
uniform float roughness_value = 0.9;
uniform float metallic_value = 0.0;
uniform vec4 roughness_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 ao_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float alpha_cut = 0.0;
uniform float double_sided = 0.0;

// THREE.Fog(FOG.color, FOG.near, FOG.far) из data/site.json. Глобальные —
// потому что свет (сумерки -> ночь) ведёт туман, а материалов полтора десятка.
global uniform vec3 psx_fog_color;
global uniform float psx_fog_near;
global uniform float psx_fog_far;

// Проектор фонаря: мир -> клип-пространство конуса, из него UV cookie-текстуры.
global uniform mat4 flashlight_proj;
global uniform sampler2D flashlight_cookie;
global uniform vec3 flashlight_pos;
global uniform float flashlight_on;

varying vec2 v_psx_uv;
varying float v_psx_w;
varying vec3 v_world;

void vertex() {
	// Снап вершины в сетку низкого разрешения. Делаем в NDC, потом возвращаем в clip.
	// z не трогаем: у Godot обратная глубина, правка z ломает отсечение.
	vec4 clip = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	float w = max(0.0001, clip.w);
	vec2 ndc = clip.xy / w;
	ndc = floor(ndc * psx_snap + 0.5) / psx_snap;
	clip.x = ndc.x * w;
	clip.y = ndc.y * w;
	POSITION = clip;

	// uv * w в вершине + деление на интерполированный w во фрагменте = аффинная развёртка.
	v_psx_w = mix(1.0, clip.w, psx_affine);
	v_psx_uv = UV * v_psx_w;

	// Позиция в мире нужна только проектору фонаря в light().
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = v_psx_uv / max(0.0001, v_psx_w);
	vec4 surface_color = texture(albedo_tex, uv * uv_scale + uv_offset) * albedo;
	if (use_vertex_color) { surface_color *= COLOR; }
	if (alpha_cut > 0.0 && surface_color.a < alpha_cut) {
		discard;
	}
	ALBEDO = surface_color.rgb;
	ROUGHNESS = roughness_value;
	METALLIC = metallic_value;
	EMISSION = emission_color;
	if (use_normal) {
		NORMAL_MAP = texture(normal_tex, uv * uv_scale + uv_offset).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
	}
	if (use_roughness) {
		ROUGHNESS *= dot(texture(roughness_tex, uv * uv_scale + uv_offset), roughness_channel);
	}
	if (use_ao) {
		vec2 ao_uv = ao_on_uv2 ? UV2 * ao_uv2_scale + ao_uv2_offset : uv * uv_scale + uv_offset;
		AO = dot(texture(ao_tex, ao_uv), ao_channel);
		AO_LIGHT_AFFECT = 0.35;
	}

	// THREE.Fog линейный: fogFactor = smoothstep(near, far, -mvPosition.z).
	// VERTEX во фрагменте — координата во вьюспейсе, вперёд у камеры это -Z.
	FOG = vec4(psx_fog_color, smoothstep(psx_fog_near, psx_fog_far, -VERTEX.z));
}

/* Множитель cookie для того единственного источника, который стоит в позиции фонаря.
   Лампы и луна проходят мимо: направление «фрагмент -> источник» у них не совпадает
   с направлением «фрагмент -> фонарь», а других способов отличить источник
   внутри light() нет.

   Мировая позиция приходит параметром, а не читается из varying: varying
   за пределами vertex/fragment/light — территория, на которую парсер Godot
   реагирует по-разному от версии к версии. */
float flashlight_cookie_at(vec3 world_pos, vec3 light_dir_world) {
	vec3 to_frag = world_pos - flashlight_pos;
	float dist = length(to_frag);
	if (dist < 0.0001) {
		return 1.0;
	}
	/* «Это фонарь?» — плавно, а не решением да/нет.

	   Фаза 8. Порог был жёсткий (dot < 0.999 -> чужой источник, cookie мимо),
	   и на близких расстояниях он врал: позиция фрагмента интерполированная,
	   а вершины снапнуты в сетку 192x144, направления расходятся на доли
	   градуса — фрагмент молча терял cookie и получал полную яркость. Отсюда
	   часть «ряби» у стен вплотную. Полоса 0.9955..0.9990 — это примерно
	   5.4..2.6 градуса: чужой источник в неё не попадает (лампы и луна стоят
	   на десятки градусов в стороне), а собственный дребезг снапа — попадает. */
	float mine = smoothstep(0.9955, 0.9990, dot(light_dir_world, -to_frag / dist));
	if (mine <= 0.0) {
		return 1.0;
	}
	vec4 c = flashlight_proj * vec4(world_pos, 1.0);
	if (c.w <= 0.0) {
		return mix(1.0, 0.0, mine);
	}
	vec2 cuv = (c.xy / c.w) * 0.5 + 0.5;
	if (cuv.x < 0.0 || cuv.x > 1.0 || cuv.y < 0.0 || cuv.y > 1.0) {
		return mix(1.0, 0.0, mine);
	}
	// V у текстуры Godot растёт вниз, у проекции — вверх.
	return mix(1.0, texture(flashlight_cookie, vec2(cuv.x, 1.0 - cuv.y)).r, mine);
}

void light() {
	float cookie = 1.0;
	if (psx_cookie > 0.5 && flashlight_on > 0.5) {
		cookie = flashlight_cookie_at(v_world, normalize((INV_VIEW_MATRIX * vec4(LIGHT, 0.0)).xyz));
	}
	// Ламберт: тот же BRDF, что у MeshLambertMaterial (диффуз / PI).
	DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * LIGHT_COLOR * cookie / PI;
}

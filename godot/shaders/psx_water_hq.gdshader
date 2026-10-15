shader_type spatial;
// Единый линейный FOG. Environment fog выключен.
render_mode diffuse_lambert, specular_schlick_ggx, cull_disabled;

// Снап выключен; UV интерполируются с перспективной коррекцией.

/* Аналог MeshLambertMaterial({ color, map }): цвет умножается на текстуру.
   Незаданный sampler2D Godot подставляет белым — материалам без карты
   (плоские стены, крашеные доски) отдельная заглушка не нужна. */
uniform vec4 albedo : source_color = vec4(1.0, 1.0, 1.0, 1.0);
/* Анизотропия к мипмапам: пол, гравий и дорожка почти всегда под скользящим
   углом, и без неё дальний конец коридора уходит в ровную кашу. */
uniform sampler2D water_atlas : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;

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
uniform float normal_strength = 1.0;
uniform float roughness_value = 0.9;
uniform float metallic_value = 0.0;
uniform vec4 roughness_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec4 ao_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform vec3 emission_color : source_color = vec3(0.0);
uniform float alpha_cut = 0.0;
uniform float double_sided = 0.0;


// Проектор фонаря: мир -> клип-пространство конуса, из него UV cookie-текстуры.
global uniform vec3 psx_fog_color;
global uniform float psx_fog_near;
global uniform float psx_fog_far;
global uniform mat4 flashlight_proj;
global uniform sampler2D flashlight_cookie;
global uniform vec3 flashlight_pos;
global uniform float flashlight_on;

varying vec2 v_psx_uv;
varying float v_psx_w;
varying vec3 v_world;

void vertex() {
	v_psx_w = 1.0;
	v_psx_uv = UV;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 uv = v_psx_uv / max(0.0001, v_psx_w);
	float deep_layer = step(50.0, uv.x);
	vec2 raw_uv = uv - vec2(deep_layer * 100.0, 0.0);
	vec3 a = texture(water_atlas, fract(raw_uv * 0.21 + vec2(TIME * 0.0022, TIME * 0.0011))).rgb;
	vec3 b = texture(water_atlas, fract(raw_uv * 0.17 + vec2(-TIME * 0.0013, TIME * 0.0018))).rgb;
	vec3 depth = vec3(0.090, 0.140, 0.130);
	vec3 shallow = mix(depth, mix(a, b, 0.43) * vec3(0.58, 0.70, 0.64), 0.68);
	vec4 surface_color = vec4(mix(shallow, depth * 0.78, deep_layer * 0.42), 0.76);
	if (alpha_cut > 0.0 && surface_color.a < alpha_cut) {
		discard;
	}
	ALBEDO = surface_color.rgb;
	FOG = vec4(psx_fog_color, smoothstep(psx_fog_near, psx_fog_far, -VERTEX.z) * psx_cookie);
	ALPHA = surface_color.a;
	ROUGHNESS = 0.52;
	METALLIC = metallic_value;
	EMISSION = emission_color;
	if (use_normal) {
		// Мировые ArrayMesh не требуют отдельного tangent-буфера.
		vec3 mapped = texture(normal_tex, uv * uv_scale + uv_offset).rgb * 2.0 - 1.0;
		mapped.xy *= normal_strength;
		vec3 dp1 = dFdx(VERTEX);
		vec3 dp2 = dFdy(VERTEX);
		vec2 duv1 = dFdx(uv * uv_scale);
		vec2 duv2 = dFdy(uv * uv_scale);
		vec3 a = cross(dp2, NORMAL);
		vec3 b = cross(NORMAL, dp1);
		vec3 t = a * duv1.x + b * duv2.x;
		vec3 bitangent = a * duv1.y + b * duv2.y;
		float k = inversesqrt(max(max(dot(t, t), dot(bitangent, bitangent)), 0.00000001));
		NORMAL = normalize(mat3(t * k, bitangent * k, NORMAL) * mapped);
	}
	if (use_roughness) {
		ROUGHNESS *= dot(texture(roughness_tex, uv * uv_scale + uv_offset), roughness_channel);
	}
	if (use_ao) {
		AO = dot(texture(ao_tex, uv * uv_scale + uv_offset), ao_channel);
		AO_LIGHT_AFFECT = 0.35;
	}


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
	// Мягкий угловой порог сохраняет cookie на границе конуса.
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
	return mix(1.0, texture(flashlight_cookie, vec2(cuv.x, 1.0 - cuv.y)).r * min(1.0, dist / 1.8), mine);
}

void light() {
	float cookie = 1.0;
	if (!LIGHT_IS_DIRECTIONAL && psx_cookie > 0.5 && flashlight_on > 0.5) {
		cookie = flashlight_cookie_at(v_world, normalize((INV_VIEW_MATRIX * vec4(LIGHT, 0.0)).xyz));
	}
	// Ламберт: тот же BRDF, что у MeshLambertMaterial (диффуз / PI).
	float ndl = dot(NORMAL, LIGHT);
	if (double_sided > 0.5) {
		ndl = abs(ndl);
	}
	float no_l = max(ndl, 0.0);
	DIFFUSE_LIGHT += no_l * ATTENUATION * LIGHT_COLOR * cookie * (1.0 - METALLIC) / PI;
	// GGX сохраняет различие мокрой дороги и сухой земли, включая cookie фонаря.
	if (ROUGHNESS < 0.86) {
		vec3 halfway = normalize(LIGHT + VIEW);
		float no_v = max(dot(NORMAL, VIEW), 0.001);
		float no_h = max(dot(NORMAL, halfway), 0.0);
		float vo_h = max(dot(VIEW, halfway), 0.0);
		float a = max(ROUGHNESS * ROUGHNESS, 0.045);
		float a2 = a * a;
		float denom = no_h * no_h * (a2 - 1.0) + 1.0;
		float distribution = a2 / (PI * denom * denom);
		float k = (ROUGHNESS + 1.0) * (ROUGHNESS + 1.0) / 8.0;
		float geometry = no_v / (no_v * (1.0 - k) + k);
		geometry *= no_l / max(no_l * (1.0 - k) + k, 0.001);
		vec3 f0 = mix(vec3(0.04), ALBEDO, METALLIC);
		vec3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vo_h, 5.0);
		SPECULAR_LIGHT += distribution * geometry * fresnel * no_l
			* ATTENUATION * LIGHT_COLOR * cookie / max(4.0 * no_v * no_l, 0.001);
	}

}

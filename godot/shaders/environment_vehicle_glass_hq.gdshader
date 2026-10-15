shader_type spatial;
render_mode diffuse_lambert, specular_schlick_ggx, cull_disabled, blend_mix, depth_prepass_alpha;

uniform vec4 albedo : source_color = vec4(1.0);
uniform float window_opacity = 0.38;
uniform int vehicle_part = 0;
uniform float glass_base = 0.945;
uniform float dust_height = 0.65;
uniform mat4 local_frame = mat4(1.0);
uniform sampler2D micro_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
global uniform vec3 psx_fog_color;
global uniform float psx_fog_near;
global uniform float psx_fog_far;
global uniform mat4 flashlight_proj;
global uniform sampler2D flashlight_cookie;
global uniform vec3 flashlight_pos;
global uniform float flashlight_on;
varying vec3 local_position;
varying vec3 local_normal;
varying vec3 v_world;

void vertex() {
	local_position = (local_frame * vec4(VERTEX, 1.0)).xyz;
	local_normal = (local_frame * vec4(NORMAL, 0.0)).xyz;
	v_world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// Projection stays attached to the unchanged local body in both LODs.
	vec3 axis = abs(local_normal);
	vec2 uv = axis.x > max(axis.y, axis.z) ? local_position.zy :
		(axis.y > axis.z ? local_position.xz : local_position.xy);
	uv *= 2.5;
	vec4 micro = texture(micro_tex, uv);
	float patch = texture(micro_tex, uv * 0.13 + vec2(0.37, 0.11)).a;
	float dust = (1.0 - smoothstep(0.30, dust_height, local_position.y)) * (0.26 + patch * 0.22);
	vec3 paint = albedo.rgb * mix(vec3(1.0), micro.rgb, 0.34);
	vec3 dust_color = vec3(0.19, 0.155, 0.11);
	ALBEDO = mix(paint, dust_color, dust);
	ROUGHNESS = 0.42 + micro.a * 0.16 + dust * 0.33;
	METALLIC = 0.22 * (1.0 - dust);
	SPECULAR = 0.65;
	float strength = 0.10;
	if (vehicle_part == 1) {
		// Wheels, door seams and window planes share the original dark batch.
		float glass = step(glass_base, local_position.y);
		ALBEDO = mix(vec3(0.026, 0.028, 0.026) * micro.rgb, vec3(0.047, 0.076, 0.084), glass);
		ALBEDO = mix(ALBEDO, dust_color, dust * (1.0 - glass));
		ROUGHNESS = mix(0.88, 0.14 + micro.a * 0.035, glass);
		METALLIC = 0.0;
		SPECULAR = mix(0.25, 0.85, glass);
		// Closed cars retain the original opaque cabin. Sky radiance supplies reflections.
		EMISSION = vec3(0.013, 0.021, 0.026) * pow(1.0 - max(dot(NORMAL, VIEW), 0.0), 3.0) * glass;
		strength = mix(0.20, 0.015, glass);
	} else if (vehicle_part == 2) {
		ALBEDO = mix(albedo.rgb * micro.rgb, dust_color, dust * 0.55);
		ROUGHNESS = 0.26 + micro.a * 0.13 + dust * 0.3;
		METALLIC = 0.72 * (1.0 - dust);
		SPECULAR = 0.75;
		strength = 0.07;
	} else if (vehicle_part == 3) {
		ALBEDO = mix(albedo.rgb * micro.rgb, dust_color, dust * 0.7);
		ROUGHNESS = 0.72 + dust * 0.18;
		METALLIC = 0.08;
	}
	vec3 mapped = texture(normal_tex, uv).rgb * 2.0 - 1.0;
	mapped.xy *= strength;
	vec3 dp1 = dFdx(VERTEX);
	vec3 dp2 = dFdy(VERTEX);
	vec2 duv1 = dFdx(uv);
	vec2 duv2 = dFdy(uv);
	vec3 tangent = cross(dp2, NORMAL) * duv1.x + cross(NORMAL, dp1) * duv2.x;
	vec3 bitangent = cross(dp2, NORMAL) * duv1.y + cross(NORMAL, dp1) * duv2.y;
	float k = inversesqrt(max(max(dot(tangent, tangent), dot(bitangent, bitangent)), 0.00000001));
	NORMAL = normalize(mat3(tangent * k, bitangent * k, NORMAL) * mapped);
	ALPHA = window_opacity;
	FOG = vec4(psx_fog_color, smoothstep(psx_fog_near, psx_fog_far, -VERTEX.z));
}

float cookie_at(vec3 direction_world) {
	vec3 offset = v_world - flashlight_pos;
	float distance = length(offset);
	if (distance < 0.0001) { return 1.0; }
	float mine = smoothstep(0.9955, 0.9990, dot(direction_world, -offset / distance));
	if (mine <= 0.0) { return 1.0; }
	vec4 projected = flashlight_proj * vec4(v_world, 1.0);
	if (projected.w <= 0.0) { return mix(1.0, 0.0, mine); }
	vec2 uv = projected.xy / projected.w * 0.5 + 0.5;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) { return mix(1.0, 0.0, mine); }
	return mix(1.0, texture(flashlight_cookie, vec2(uv.x, 1.0 - uv.y)).r * min(1.0, distance / 1.8), mine);
}

void light() {
	float cookie = 1.0;
	if (!LIGHT_IS_DIRECTIONAL && flashlight_on > 0.5) {
		cookie = cookie_at(normalize((INV_VIEW_MATRIX * vec4(LIGHT, 0.0)).xyz));
	}
	float no_l = max(dot(NORMAL, LIGHT), 0.0);
	DIFFUSE_LIGHT += no_l * ATTENUATION * LIGHT_COLOR * cookie * (1.0 - METALLIC) / PI;
	vec3 halfway = normalize(LIGHT + VIEW);
	float no_v = max(dot(NORMAL, VIEW), 0.001);
	float no_h = max(dot(NORMAL, halfway), 0.0);
	float vo_h = max(dot(VIEW, halfway), 0.0);
	float a = max(ROUGHNESS * ROUGHNESS, 0.045);
	float a2 = a * a;
	float denominator = no_h * no_h * (a2 - 1.0) + 1.0;
	float distribution = a2 / (PI * denominator * denominator);
	float k = (ROUGHNESS + 1.0) * (ROUGHNESS + 1.0) / 8.0;
	float geometry = no_v / (no_v * (1.0 - k) + k);
	geometry *= no_l / max(no_l * (1.0 - k) + k, 0.001);
	vec3 f0 = mix(vec3(0.04), ALBEDO, METALLIC);
	vec3 fresnel = f0 + (1.0 - f0) * pow(1.0 - vo_h, 5.0);
	SPECULAR_LIGHT += distribution * geometry * fresnel * no_l * ATTENUATION * LIGHT_COLOR * cookie / max(4.0 * no_v * no_l, 0.001);
}

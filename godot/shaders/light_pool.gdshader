shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

global uniform float psx_fog_near;
global uniform float psx_fog_far;

uniform vec4 pool_color : source_color = vec4(1.0, 0.72, 0.36, 1.0);
instance uniform float pool_strength = 0.2;

void fragment() {
	float radius = length((UV - vec2(0.5)) * 2.0);
	float wide = 1.0 - smoothstep(0.12, 1.0, radius);
	float core = 1.0 - smoothstep(0.0, 0.32, radius);
	float alpha = (wide * wide * 0.48 + core * 0.52) * pool_strength * pool_color.a;
	ALBEDO = pool_color.rgb;
	ALPHA = alpha * (1.0 - smoothstep(psx_fog_near, psx_fog_far, -VERTEX.z));
}

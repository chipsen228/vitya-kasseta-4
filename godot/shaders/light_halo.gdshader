shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

global uniform float psx_fog_near;
global uniform float psx_fog_far;

uniform vec4 halo_color : source_color = vec4(1.0, 0.72, 0.36, 1.0);
instance uniform float halo_size = 0.5;
instance uniform float halo_strength = 0.3;

void vertex() {
	vec3 center = MODEL_MATRIX[3].xyz;
	vec3 right = INV_VIEW_MATRIX[0].xyz;
	vec3 up = INV_VIEW_MATRIX[1].xyz;
	vec3 world = center + (right * VERTEX.x + up * VERTEX.y) * halo_size;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}

void fragment() {
	float radius = length((UV - vec2(0.5)) * 2.0);
	float mist = 1.0 - smoothstep(0.08, 1.0, radius);
	float core = 1.0 - smoothstep(0.0, 0.24, radius);
	float alpha = (mist * mist * 0.72 + core * 0.28) * halo_strength * halo_color.a;
	ALBEDO = halo_color.rgb;
	ALPHA = alpha * (1.0 - smoothstep(psx_fog_near, psx_fog_far, -VERTEX.z));
}

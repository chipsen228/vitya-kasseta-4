shader_type spatial;
render_mode unshaded, cull_back, shadows_disabled;

global uniform vec3 psx_fog_color;
global uniform float psx_fog_near;
global uniform float psx_fog_far;

void fragment() {
	ALBEDO = COLOR.rgb;
	float mist = smoothstep(psx_fog_near, psx_fog_far, -VERTEX.z);
	FOG = vec4(psx_fog_color, max(mist, 1.0 - COLOR.a));
}

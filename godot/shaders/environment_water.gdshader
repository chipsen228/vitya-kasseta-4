shader_type spatial;
// Одно непрозрачное зеркало: вода пишет глубину до мягкого тумана.
render_mode diffuse_lambert,specular_schlick_ggx,cull_back,depth_draw_opaque;
global uniform vec3 psx_fog_color;
global uniform float psx_fog_near;
global uniform float psx_fog_far;
uniform sampler2D water_atlas : source_color,filter_linear_mipmap_anisotropic,repeat_enable;
uniform float environment_time=0.0;
varying vec3 world_pos;
void vertex(){
	world_pos=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz;
	VERTEX.y+=0.002*sin((world_pos.x+world_pos.z)*1.3+environment_time*0.18);
}
void fragment(){
	vec2 drift=vec2(environment_time*0.0019,environment_time*0.0013);
	vec3 a=texture(water_atlas,UV*0.21+drift).rgb;
	vec3 b=texture(water_atlas,UV*0.17+vec2(-drift.y,drift.x)).rgb;
	float depth=clamp(COLOR.r,0.0,1.0);
	float ripple=0.5+0.5*sin(world_pos.x*1.27-world_pos.z*0.91+environment_time*0.15);
	vec3 shallow=vec3(0.20,0.255,0.185)+mix(a,b,0.43)*0.11;
	vec3 deep=vec3(0.075,0.13,0.12)+mix(a,b,0.43)*0.085;
	ALBEDO=mix(shallow,deep,smoothstep(0.0,1.0,depth))+ripple*0.007;
	ROUGHNESS=mix(0.62,0.24,depth);
	SPECULAR=0.80;
	// NORMAL is view-space; the slow wave slope is authored in world-space.
	vec3 wave_normal=normalize(vec3(-cos(world_pos.x*1.7+environment_time*0.18)*0.027,
		1.0,-sin(world_pos.z*1.4-environment_time*0.12)*0.027));
	NORMAL=normalize((VIEW_MATRIX*vec4(wave_normal,0.0)).xyz);
	float grazing=pow(1.0-clamp(dot(NORMAL,normalize(VIEW)),0.0,1.0),5.0);
	// GGX uses the scene sky radiance and actual lights. A small atmospheric
	// fill follows the current fog/sky palette, including the dark night preset.
	EMISSION=psx_fog_color*(0.025+grazing*0.055);
	FOG=vec4(psx_fog_color,smoothstep(psx_fog_near,psx_fog_far,-VERTEX.z));
}

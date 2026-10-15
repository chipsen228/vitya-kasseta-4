shader_type spatial;
render_mode unshaded,cull_disabled,depth_draw_never,shadows_disabled;
global uniform vec3 psx_fog_color;
uniform sampler2D depth_texture : hint_depth_texture,repeat_disable,filter_nearest;
uniform float environment_time=0.0;
uniform float phase=0.0;
uniform float density=0.06;
varying vec3 world_pos;
void vertex(){ world_pos=(MODEL_MATRIX*vec4(VERTEX,1.0)).xyz; }
void fragment(){
	float raw=texture(depth_texture,SCREEN_UV).r;
#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc=vec3(SCREEN_UV*2.0-1.0,raw*2.0-1.0);
#else
	vec3 ndc=vec3(SCREEN_UV*2.0-1.0,raw);
#endif
	vec4 scene=INV_PROJECTION_MATRIX*vec4(ndc,1.0);
	float scene_depth=-scene.z/max(scene.w,0.000001);
	float distance_to_camera=length(VERTEX);
	float contact=smoothstep(0.0,1.4,scene_depth+VERTEX.z);
	float edge=smoothstep(0.0,0.22,UV.x)*smoothstep(0.0,0.22,1.0-UV.x);
	edge*=smoothstep(0.0,0.24,UV.y)*smoothstep(0.0,0.28,1.0-UV.y);
	float drift=environment_time*0.033;
	float cloud=0.62+0.18*sin(world_pos.x*0.23+drift+phase)*cos(world_pos.z*0.19-drift);
	float near_fade=smoothstep(3.0,8.0,distance_to_camera);
	float far_fade=1.0-smoothstep(42.0,66.0,distance_to_camera);
	ALBEDO=psx_fog_color*vec3(0.88,0.94,0.90);
	ALPHA=density*edge*cloud*contact*near_fade*far_fade;
}

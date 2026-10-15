shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;

global uniform float psx_fog_near;
global uniform float psx_fog_far;

uniform vec4 beam_color : source_color = vec4(1.0, 0.72, 0.36, 1.0);
uniform float beam_length = 5.4;
uniform float brightness = 0.1;
instance uniform float beam_strength = 1.0;
uniform float edge_softness = 0.58;
uniform float intersection_softness = 0.42;
uniform sampler2D depth_texture : hint_depth_texture, repeat_disable, filter_nearest;

varying float axial;

void vertex() {
	axial = clamp(-VERTEX.z / max(beam_length, 0.001), 0.0, 1.0);
}

void fragment() {
	float raw_depth = textureLod(depth_texture, SCREEN_UV, 0.0).r;
	#if CURRENT_RENDERER == RENDERER_COMPATIBILITY
	vec3 ndc = vec3(SCREEN_UV, raw_depth) * 2.0 - 1.0;
	#else
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, raw_depth);
	#endif
	vec4 scene_view = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	float scene_depth = -scene_view.z / max(scene_view.w, 0.00001);
	float cone_depth = -VERTEX.z;
	float intersection = mix(0.30, 1.0, clamp((scene_depth - cone_depth) /
		max(intersection_softness, 0.001), 0.0, 1.0));

	// Силуэт поверхности исчезает при скользящем взгляде, а дальний срез
	// растворяется до пересечения с землёй вместо жёсткого кольца.
	float facing = abs(dot(normalize(NORMAL), normalize(VIEW)));
	float angular = mix(0.18, 1.0, smoothstep(0.02, edge_softness, facing));
	float length_fade = 1.0 - smoothstep(0.48, 1.0, axial);
	float alpha = angular * length_fade * intersection * beam_color.a;

	ALBEDO = beam_color.rgb * brightness * beam_strength;
	ALPHA = alpha * (1.0 - smoothstep(psx_fog_near, psx_fog_far, -VERTEX.z));
}

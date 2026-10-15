## CPU fixture checks geometry fit and exact state restoration, not shader draws.
extends SceneTree
const WARM := preload("res://src/label_warmup.gd")
var errors: Array[String]=[]

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var chain := RenderChain.new()
	root.add_child(chain)
	chain.world_view=SubViewport.new()
	chain.world_view.size=Vector2i(1280,720)
	chain.add_child(chain.world_view)
	chain.world_root=Node3D.new()
	chain.world_view.add_child(chain.world_root)
	chain.camera=Camera3D.new()
	chain.world_root.add_child(chain.camera)
	chain.camera.current=true
	var label_ := Label3D.new()
	label_.text="4-я линия\nК Рябовым"
	label_.font_size=30
	label_.pixel_size=.0039
	label_.outline_size=2
	label_.shaded=true
	label_.visible=false
	label_.layers=5
	label_.position=Vector3(12,1.15,-76.8)
	label_.visibility_range_begin=2
	label_.visibility_range_end=20
	label_.visibility_range_begin_margin=.4
	label_.visibility_range_end_margin=.6
	chain.world_root.add_child(label_)
	var lamps: Array[OmniLight3D]=[]
	for i in 3:
		var lamp := OmniLight3D.new()
		lamp.layers=1<<i
		lamp.visible=i==1
		lamp.light_energy=.25+i
		chain.world_root.add_child(lamp)
		lamps.append(lamp)
	var spot := SpotLight3D.new()
	spot.layers=2
	spot.light_cull_mask=3
	spot.visible=false
	spot.light_energy=.5
	chain.world_root.add_child(spot)
	var moon := DirectionalLight3D.new()
	moon.light_energy=0
	moon.visible=false
	chain.world_root.add_child(moon)
	for i in 2: await process_frame
	var before := [label_.transform,label_.text,label_.font_size,label_.pixel_size,label_.outline_size,label_.shaded,label_.billboard,label_.alpha_cut]
	var ranges_before := [label_.visibility_range_begin_margin,label_.visibility_range_end_margin]
	var fit := WARM._fit(chain.camera,label_,13,28)
	var bounds := label_.get_aabb()
	if bounds.size.x<=0 or bounds.size.y<=0: errors.append("fixture glyph bounds empty")
	var fitted_width := (fit.basis*Vector3(bounds.size.x,0,0)).length()
	if fitted_width<.04: errors.append("warm text remains too small to cover glyph and outline pixels")
	var report := await WARM.warm(chain,lamps,spot)
	if not report.restored or not report.lights_restored: errors.append("warm state not restored")
	if before!=[label_.transform,label_.text,label_.font_size,label_.pixel_size,label_.outline_size,label_.shaded,label_.billboard,label_.alpha_cut]: errors.append("source text/font/flags/transform changed")
	if label_.visible or label_.layers!=5 or [label_.visibility_range_begin_margin,label_.visibility_range_end_margin]!=ranges_before: errors.append("source visibility/ranges changed")
	if moon.visible or moon.light_energy!=0 or moon.layers!=1: errors.append("directional light not restored")
	if spot.visible or spot.layers!=2 or spot.light_cull_mask!=3 or spot.light_energy!=.5: errors.append("spot state not restored")
	if report.draws.size()!=8: errors.append("light variants missing")
	for draw: Dictionary in report.draws:
		if not draw.spot_in_camera: errors.append("spot filtered out by warm camera layer")
	for error_: String in errors: printerr(error_)
	print("test_label_warmup: ","PASS" if errors.is_empty() else "FAIL"," (CPU fit/restore only)")
	chain.queue_free()
	await process_frame
	quit(0 if errors.is_empty() else 1)

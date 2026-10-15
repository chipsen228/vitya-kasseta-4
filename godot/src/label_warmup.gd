## Draw real glyph and outline surfaces before gameplay; material quads omit Label3D.
extends RefCounted

static func warm(chain: RenderChain, lamps: Array[OmniLight3D], spot: SpotLight3D) -> Dictionary:
	var camera := chain.camera
	var mask := camera.cull_mask
	var bit := 1 << 19
	var records: Array = []
	for node: Node in SkinLayer._nodes(chain.world_root):
		if node is Label3D or node is Sprite3D:
			records.append({"node":node,"transform":node.transform,"visible":node.visible,
				"layers":node.layers,"begin":node.visibility_range_begin,"end":node.visibility_range_end,
				"begin_margin":node.visibility_range_begin_margin,"end_margin":node.visibility_range_end_margin,
				"text":node.text if node is Label3D else "","shaded":node.shaded if node is Label3D else false,
				"outline":node.outline_size if node is Label3D else 0})
	var light_saved: Array = []
	var warm_lights: Array = lamps + [spot]
	for node: Node in SkinLayer._nodes(chain.world_root):
		if node is DirectionalLight3D and not node in warm_lights: warm_lights.append(node)
	for light: Light3D in warm_lights:
		light_saved.append({"node":light,"transform":light.transform,"visible":light.visible,"layers":light.layers,
			"energy":light.light_energy,"mask":light.light_cull_mask,"shadow":light.shadow_enabled})
		# Camera visibility and the light's recipient mask are separate filters.
		light.layers |= bit
		light.light_cull_mask |= bit
		if light is DirectionalLight3D:
			light.visible = true
			light.light_energy = maxf(light.light_energy,0.15)
	camera.cull_mask = bit
	for i in records.size():
		var node: GeometryInstance3D = records[i]["node"]
		node.layers = bit
		node.visible = true
		node.visibility_range_begin = 0
		node.visibility_range_end = 0
		node.visibility_range_begin_margin = 0
		node.visibility_range_end_margin = 0
		node.global_transform = _fit(camera,node,i,records.size())
	for i in lamps.size():
		lamps[i].light_energy = 14.0
		lamps[i].global_position = camera.global_position - camera.global_basis.z * 0.1
	spot.light_cull_mask |= bit
	spot.global_transform = camera.global_transform
	spot.shadow_enabled = true
	var draws: Array = []
	for on: bool in [false,true]:
		spot.visible = on
		spot.light_energy = 14.0 if on else 0.0
		for count in 4:
			for i in lamps.size(): lamps[i].visible = i < count
			for frame in 3: await chain.get_tree().process_frame
			if DisplayServer.get_name()!="headless": await RenderingServer.frame_post_draw
			draws.append({"spot":spot.is_visible_in_tree() and spot.light_energy > 0,
				"spot_in_camera":(spot.layers & camera.cull_mask)!=0,"omni":count,
				"labels":records.size(),"draw":_world_draw(chain.world_view)})
	for item: Dictionary in records:
		var node: GeometryInstance3D = item["node"]
		node.transform = item["transform"]
		node.visible = item["visible"]
		node.layers = item["layers"]
		node.visibility_range_begin = item["begin"]
		node.visibility_range_end = item["end"]
		node.visibility_range_begin_margin = item["begin_margin"]
		node.visibility_range_end_margin = item["end_margin"]
	camera.cull_mask = mask
	for item: Dictionary in light_saved:
		var light: Light3D = item["node"]
		light.transform = item["transform"]
		light.visible = item["visible"]
		light.layers = item["layers"]
		light.light_energy = item["energy"]
		light.light_cull_mask = item["mask"]
		light.shadow_enabled = item["shadow"]
	var restored := camera.cull_mask == mask
	var lights_restored := true
	for item: Dictionary in light_saved:
		var light: Light3D = item["node"]
		lights_restored = lights_restored and light.transform==item["transform"] and light.visible==item["visible"] \
			and light.layers==item["layers"] and light.light_energy==item["energy"] \
			and light.light_cull_mask==item["mask"] and light.shadow_enabled==item["shadow"]
	var labels: Array = []
	for item: Dictionary in records:
		var node: GeometryInstance3D = item["node"]
		restored = restored and node.transform == item["transform"] and node.layers == item["layers"] \
			and node.visible == item["visible"] and node.visibility_range_begin == item["begin"] \
			and node.visibility_range_end == item["end"] \
			and node.visibility_range_begin_margin==item["begin_margin"] and node.visibility_range_end_margin==item["end_margin"]
		labels.append({"path":String(node.get_path()),"text":item["text"],"shaded":item["shaded"],"outline":item["outline"]})
	return {"restored":restored and lights_restored,"lights_restored":lights_restored,"count":records.size(),"labels":labels,"draws":draws,"isolated_layer":bit,"gpu":DisplayServer.get_name()!="headless"}

static func _fit(camera: Camera3D,node: GeometryInstance3D,index: int,count: int) -> Transform3D:
	var size := camera.get_viewport().get_visible_rect().size
	var columns := maxi(1,ceili(sqrt(float(count)*size.x/maxf(size.y,1.0))))
	var rows := maxi(1,ceili(float(count)/columns))
	var cell := size*0.8/Vector2(columns,rows)
	var pixel := size*0.1+Vector2(float(index%columns)+0.5,float(index/columns)+0.5)*cell
	var depth := maxf(0.45,camera.near+0.05)
	var center := camera.project_position(pixel,depth)
	var width := center.distance_to(camera.project_position(pixel+Vector2(cell.x*0.40,0),depth))*2.0
	var height := center.distance_to(camera.project_position(pixel+Vector2(0,cell.y*0.40),depth))*2.0
	var bounds := node.get_aabb()
	var fit := minf(width/maxf(bounds.size.x,0.001),height/maxf(bounds.size.y,0.001))
	var basis := camera.global_basis.orthonormalized().scaled(Vector3.ONE*fit)
	return Transform3D(basis,center-basis*bounds.get_center())

static func _world_draw(view: SubViewport) -> Dictionary:
	var rid := view.get_viewport_rid()
	return {"calls":RenderingServer.viewport_get_render_info(rid,RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"tris":RenderingServer.viewport_get_render_info(rid,RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)}

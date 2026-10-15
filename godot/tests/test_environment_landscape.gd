## Общий водный контур и ходовые полосы проверяются реальными solid probes.
extends SceneTree

var errors: Array[String] = []

func _initialize() -> void:
	Materials.render_hq_enabled=true
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	var built := WorldBuilder.build(world,mats,col)
	var props := Props.new(mats)
	var pdata := GameData.props()
	props.load_models(pdata["PROPS"])
	props.build(world,pdata["PROPS"],col)
	_check_extra_owners(world)
	if col.box_count(CollisionWorld.SET_STATIC)!=311 or col.box_count(CollisionWorld.SET_BLOCKERS)!=4 \
			or col.box_count(CollisionWorld.SET_PROPS)!=83 or int(built["triangles"])!=3885:
		errors.append("base parity changed: %d/%d/%d/%d" % [col.box_count(CollisionWorld.SET_STATIC),col.box_count(CollisionWorld.SET_BLOCKERS),col.box_count(CollisionWorld.SET_PROPS),int(built["triangles"])])
	var snt: Dictionary = built["snt"]
	var water: Dictionary = snt["waterway"]
	for poly: PackedVector2Array in water["outlines"]:
		for p: Vector2 in poly:
			if p.x>3.20001: errors.append("SNT water extends east of x3.2")
	for id: String in ["story-lake","snt-lake"]:
		var surface := world.get_node_or_null(id+"-surface") as MeshInstance3D
		if surface==null or surface.mesh==null:
			errors.append(id+": HQ surface absent")
			continue
		if surface.mesh.get_surface_count()!=1: errors.append(id+": more than one water surface")
		var material := surface.material_override as ShaderMaterial
		if material==null or material.shader.resource_path!="res://shaders/environment_water.gdshader":
			errors.append(id+": expected opaque depth-writing water shader")
		elif material.shader.code.contains("ALPHA") or not material.shader.code.contains("depth_draw_opaque"):
			errors.append(id+": water returned to transparent/depthless render path")
		if surface.cast_shadow!=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			errors.append(id+": water casts shadow")
	for sample: Array in [[Vector2(-0.45,-45.3),false],[Vector2(-2.15,-44.4),true],
		[Vector2(-0.45,-46.1),true],[Vector2(-17.7,-54.0),false],[Vector2(-17.3,-58.1),true],
		[Vector2(-17.7,-58.1),false],
		[Vector2(3.9,-45.0),false],[Vector2(3.9,-49.7),false]]:
		var p: Vector2 = sample[0]
		if col.point_hit(p.x,0.8,p.y,CollisionWorld.ALL_SOLID)!=bool(sample[1]):
			errors.append("water/shore collision at "+str(p))
	var routes := EnvironmentLandscape.route_lines()
	for index in routes.size():
		var radius := 0.55 if index==2 else 0.60
		_check_path(col,routes[index],radius,"route-%d" % index)
		_check_width(col,routes[index],float(EnvironmentLandscape.ROUTE_WIDTHS[index]),"route-%d" % index)
	# На северном проёме свободны и центр, и края капсулы игрока.
	_check_path(col,[Vector2(13.0,-33.6),Vector2(13.0,-35.0)],0.60,"central north opening")
	_check_path(col,[Vector2(4.1,-14.15),Vector2(9.9,-14.15)],0.60,"watcher rear 1.30m")
	# Общий берег даёт за неизменённым дровяником полноценную сухую полосу.
	var woodshed_shore := [Vector2(-17.0,-41.3),Vector2(-13.6,-41.3)]
	_check_path(col,woodshed_shore,0.65,"woodshed dry shore")
	_check_width(col,woodshed_shore,1.4,"woodshed dry shore")
	var shore_gap:=INF
	for water_id: String in snt["water_blockers"]:
		for box_index: int in col._by_id[CollisionWorld.SET_OVERLAY][water_id]:
			var box:=col.box_aabb_d(CollisionWorld.SET_OVERLAY,box_index)
			if box[3]>-17.0 and box[0]<-13.6 and box[5]<-40.6:
				shore_gap=minf(shore_gap,-40.6-box[5])
	if shore_gap<1.4: errors.append("woodshed shore real blocker gap below1.4: "+str(shore_gap))
	print("woodshed dry shore min blocker gap: ",shore_gap)
	var landscape: Dictionary = built["rural"]["landscape"]
	print("SNT water blockers: ",(snt["water_blockers"] as Array).size())
	if (landscape["fog_sheets"] as Array).size()!=6: errors.append("expected six fog sheets")
	for node: MeshInstance3D in landscape["fog_sheets"]:
		if node.cast_shadow!=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			errors.append(node.name+": fog casts shadow")
		var material := node.material_override as ShaderMaterial
		if material.shader.code.contains("TIME") or not material.shader.code.contains("hint_depth_texture"):
			errors.append(node.name+": fog lacks pause-safe clock or depth fade")
	EnvironmentLandscape.update(built,0.04)
	for mat: ShaderMaterial in landscape["materials"]:
		if not is_equal_approx(float(mat.get_shader_parameter("environment_time")),0.04):
			errors.append("environment material clock not updated")
	EnvironmentLandscape.update(built,0.0)
	if not is_equal_approx(float(landscape["time"]),0.04): errors.append("zero delta advanced clock")
	var marker := world.find_child("low-poly-trees*",true,false)
	var found: Dictionary = {}
	if marker==null: errors.append("tree marker absent")
	for row: Dictionary in marker.get_meta("instances",[]) if marker!=null else []:
		if row.get("source","")=="scary-six": found[int(row["tree_index"])]=row
	if found.keys().size()!=5 or found.has(3): errors.append("removed scary tree index3 retained")
	for index in [4,5]:
		var expected := Vector2(4.2,-20.4) if index==4 else Vector2(28.2,-20.6)
		if not found.has(index) or not Vector2(found[index]["x"],found[index]["z"]).is_equal_approx(expected):
			errors.append("scary-tree-%d not at requested position" % index)
	# Полосы растений проверяем по фактическим layout, включая ручные экземпляры.
	for key: String in built["scatter"]["layout"]:
		var rows: Array = built["scatter"]["layout"][key]
		for i in rows.size()/5:
			if EnvironmentLandscape.on_route(float(rows[i*5]),float(rows[i*5+2]),0.20):
				errors.append("scatter on route: "+key)
				break
	props.dispose()
	world.free()
	Materials.render_hq_enabled=false
	for error: String in errors: printerr("FAIL environment_landscape: ",error)
	print("test_environment_landscape: %s routes=%d fog=6" % ["PASS" if errors.is_empty() else "FAIL",routes.size()])
	quit(0 if errors.is_empty() else 1)

func _check_extra_owners(world: Node3D) -> void:
	var vertices: Dictionary = {}
	for node: Node in world.get_children():
		if not node is MeshInstance3D: continue
		var parts: Dictionary = node.get_meta("skin_parts",{})
		for key: String in parts:
			for span: Vector2i in parts[key]:
				vertices[key] = int(vertices.get(key,0)) + span.y
	var checked := 0
	for plot: Dictionary in SntWorld.data()["PLOTS"]:
		var id := String(plot["id"])
		for extra: Dictionary in plot.get("extras",[]):
			var kind := String(extra["k"])
			var key := "interiors/environment/extra-" + id + "-" + kind
			if (id=="p07" and kind=="barrel") or (id=="p09" and kind=="bench"):
				if vertices.has(key): errors.append("reserved extra tagged for replacement: "+key)
				continue
			checked += 1
			if int(vertices.get(key,0))<=0: errors.append("missing raw/detailed extra owner: "+key)
			if vertices.has("interiors/snt/"+id+"-"+kind): errors.append("extra still has legacy owner: "+key)
	if checked!=28: errors.append("expected 28 replaceable SNT extras")
	if int(vertices.get("interiors/snt/p09-bench",0))<=0: errors.append("reserved p09 radio bench was removed")

func _check_path(col: CollisionWorld,path: Array,radius: float,label: String) -> void:
	for i in path.size()-1:
		var a: Vector2 = path[i]
		var c: Vector2 = path[i+1]
		var count := maxi(1,ceili(a.distance_to(c)/0.15))
		for step in count+1:
			var p := a.lerp(c,float(step)/count)
			var hit := col.capsule_hit(Vector3(p.x,radius+0.035,p.y),
				Vector3(p.x,Player.STAND_HEIGHT-radius+0.035,p.y),radius,CollisionWorld.ALL_SOLID)
			if not hit.is_empty() or col.point_hit(p.x,0.80,p.y,CollisionWorld.ALL_SOLID):
				errors.append(label+": blocked r="+str(radius)+" at "+str(p)+" "+str(hit))
				return
			var floor_hit := col.ray_down(p.x,0.60,p.y,CollisionWorld.ALL_SOLID)
			if floor_hit.is_empty():
				errors.append(label+": no floor at "+str(p))
				return

func _check_width(col: CollisionWorld,path: Array,width: float,label: String) -> void:
	for i in path.size()-1:
		var a: Vector2=path[i]
		var c: Vector2=path[i+1]
		var direction := (c-a).normalized()
		var side := Vector2(-direction.y,direction.x)
		var count := maxi(1,ceili(a.distance_to(c)/0.20))
		for step in count+1:
			var centre := a.lerp(c,float(step)/count)
			for sign_value: float in [-1.0,1.0]:
				var p := centre+side*sign_value*(width*0.5-Player.RADIUS)
				var hit := col.capsule_hit(Vector3(p.x,Player.RADIUS+0.035,p.y),
					Vector3(p.x,Player.STAND_HEIGHT-Player.RADIUS+0.035,p.y),Player.RADIUS,CollisionWorld.ALL_SOLID)
				if not hit.is_empty() and float(hit.get("depth",0.0))>0.002:
					errors.append(label+": required width="+str(width)+" blocked at "+str(p)+" "+str(hit))
					var ids: Array=col.get("_by_id")
					for set_id in CollisionWorld.SET_COUNT:
						for id: String in ids[set_id]:
							for box_id: int in ids[set_id][id]:
								var box := col.box_aabb_d(set_id,box_id)
								if box[4]<0.10 or box[1]>Player.STAND_HEIGHT: continue
								if Rect2(box[0],box[2],box[3]-box[0],box[5]-box[2]).grow(Player.RADIUS).has_point(p):
									printerr("width candidate ",id," ",box)
					return

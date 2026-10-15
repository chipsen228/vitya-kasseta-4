extends SceneTree

var errors: Array[String] = []

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var b := WorldBuilder.new()
	b.mats = Materials.new().load_all()
	b.col = CollisionWorld.new()
	b.site = GameData.site()
	var expected: Dictionary = {}
	var counts := {"waterBarrel":0,"bench":0}
	for plot: Dictionary in SntWorld.data()["PLOTS"]:
		for extra: Dictionary in plot.get("extras",[]):
			var kind: String = {"barrel":"waterBarrel","bench":"bench"}.get(String(extra.get("k","")),"")
			if kind.is_empty(): continue
			var at: Array = extra["at"]
			var position := Vector3(float(at[0]),0,float(at[1]))
			if not SntWorld._detailed_extra(b,kind,String(plot["id"])+kind,position):
				errors.append("не построена готовая модель "+kind)
			counts[kind]+=1
			var holder := Node3D.new()
			DetailedProps.build(b.mats,{"make":kind},holder)
			for child: MeshInstance3D in holder.get_children():
				var key := String(child.get_meta("rural_bucket","boards"))
				if kind=="waterBarrel": key="water" if child.name=="detail-2" else "metal"
				expected[key]=int(expected.get(key,0))+child.mesh.get_faces().size()/3
			holder.free()
	# Обычная деревянная стена продолжает отбрасывать тень.
	SntWorld._shell(b,-1,1,0,2,-1,1,"boards",0.0)
	var world := Node3D.new()
	root.add_child(world)
	b._finish(world)
	await process_frame
	var actual: Dictionary = {}
	var board_shadows := false
	for child: Node in world.get_children():
		if not child is MeshInstance3D: continue
		var mi := child as MeshInstance3D
		if String(mi.name).begins_with("merged_boards_"):
			board_shadows=mi.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if not String(mi.name).begins_with("merged_visual_"): continue
		var key := String(mi.name).split("_")[2]
		if mi.cast_shadow!=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
			errors.append("тень вернулась в "+String(mi.name))
		if mi.material_override!=b.mats.get_mat(key):
			errors.append("изменился материал "+String(mi.name))
		actual[key]=int(actual.get(key,0))+mi.mesh.get_faces().size()/3
	if actual!=expected: errors.append("потеряна видимая геометрия %s != %s" % [actual,expected])
	if counts!={"waterBarrel":9,"bench":5}: errors.append("не проверены реальные9бочек/5скамеек: "+str(counts))
	if not board_shadows: errors.append("обычная деревянная стена потеряла тень")
	if b.col.box_count(CollisionWorld.SET_OVERLAY)!=0: errors.append("детали добавили коллизии")
	print("rural prop visible triangles: ",actual,"; count: ",counts)
	for message: String in errors: printerr("test_rural_prop_shadows: ",message)
	print("test_rural_prop_shadows: ","PASS" if errors.is_empty() else "FAIL")
	world.queue_free()
	await process_frame
	quit(0 if errors.is_empty() else 1)

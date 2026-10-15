extends SceneTree

var errors: Array[String] = []

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	root.add_child(world)
	var built := WorldBuilder.build(world, mats, col)
	built["everyday"] = EverydayWorld.build(world,mats,col,built)
	var pdata := GameData.props()
	var props := Props.new(mats)
	props.load_models(pdata["PROPS"])
	props.build(world, pdata["PROPS"], col)
	preload("res://src/environment_verge.gd").apply(world,col)
	var snt: Dictionary = built["snt"]
	var graph: Dictionary = snt["pursuit_graph"]
	_check(col.box_count(CollisionWorld.SET_STATIC) == 311, "static parity")
	_check(col.box_count(CollisionWorld.SET_BLOCKERS) == 4, "blocker parity")
	_check(col.box_count(CollisionWorld.SET_PROPS) == 83, "props parity")
	_check(int(built["triangles"]) == 3885, "triangle parity")
	_check(col.is_blocker_active("snt-forest-gate"), "forest gate initially closed")
	_check(col.point_hit(9.6, 0.9, -72.04, CollisionWorld.ALL_SOLID), "closed gate obstructs passage")
	col.set_blocker_active("snt-forest-gate", false)
	var points: Array = graph["points"]
	for edge: Array in graph["edges"]:
		var a: Vector3 = points[edge[0]]
		var z: Vector3 = points[edge[1]]
		var steps := ceili(a.distance_to(z) / 0.18)
		for step in steps + 1:
			var p := a.lerp(z, float(step) / maxf(steps, 1))
			if not _clear(col, p):
				errors.append("graph edge %s blocked at %s: %s" % [edge, p, _blockers(col, p)])
				break
			var floor_hit := col.ray_down(p.x, p.y + 0.30, p.z, CollisionWorld.ALL_SOLID)
			if floor_hit.is_empty():
				errors.append("missing ground at %s" % p)
				break
			if absf(float(floor_hit["y"]) - p.y) > 0.2:
				errors.append("step exceeds 0.2m at %s" % p)
				break
			if int(edge[0]) >= 9 and int(edge[0]) <= 22:
				var sideways := (z-a).normalized().cross(Vector3.UP) * 0.40
				if not _clear(col,p+sideways) or not _clear(col,p-sideways):
					errors.append("forest clear width below 1.4m at %s" % p)
					break
	for p: Vector3 in [SntEpisodeWorld.NINA,SntEpisodeWorld.GREENHOUSE,SntEpisodeWorld.SEMYON,graph["retry"]]:
		_check(_clear(col,p), "resident/retry capsule at %s: %s" % [p,_blockers(col,p)])
	for p: Dictionary in snt["plots"]:
		_check(not String(p.get("residents", "")).is_empty(), "resident name " + String(p["id"]))
	for addition: Dictionary in snt["collision_additions"]:
		_check(int(addition["set"]) == CollisionWorld.SET_OVERLAY, "addition set " + String(addition["id"]))
	var background: Dictionary = snt.get("forest_background",{})
	_check(int(background.get("trees",0))==113, "three staggered forest background rows")
	_check(int(background.get("shrubs",0))==62, "forest understory closes ground edge")
	_check(int(background.get("physics_delta",-1))==0, "forest background remains decorative")
	_check(int(background.get("triangles",999999))<=16000, "complete forest background exceeds 16k triangles")
	_check(int(background.get("surfaces",999999))<=40, "forest material batching exceeds 40 surfaces")
	print("forest background: ",JSON.stringify(background))
	var actors := SntEpisodeActors.new(world,mats).build()
	for who: String in SntEpisodeActors.KEYS:
		_check(actors.figure(who) != null, "model " + who)
		for action: String in ["talk","peek","run","chase","capture"]:
			_check(actors.begin_action(who,action), "pose " + who + " " + action)
			actors.sample_action(who,action,0.6)
			actors.end_action(who)
	var state := GameState.new()
	for chapter: String in ["street","dark","village"]:
		state.chapter = chapter
		actors.sync_story(state)
		_check(actors.figure("nina").visible and actors.figure("semyon").visible, "residents visible for early visit in " + chapter)
	state.chapter = "end"
	actors.sync_story(state)
	_check(not actors.figure("nina").visible and not actors.figure("semyon").visible, "residents hidden after ending")
	state.chapter = "village"
	actors.sync_story(state)
	_check(actors.figure("nina").visible, "Nina present")
	state.set_flag("snt-nina-met")
	actors.sync_story(state)
	_check(actors.figure("nina").position == SntEpisodeWorld.GREENHOUSE, "Nina greenhouse stage")
	print("test_snt_episode_geometry: %s edges=%d additions=%d models=%d" % ["PASS" if errors.is_empty() else "FAIL",graph["edges"].size(),snt["collision_additions"].size(),SntEpisodeActors.KEYS.size()])
	for error in errors: printerr("FAIL ",error)
	props.dispose()
	world.free()
	quit(0 if errors.is_empty() else 1)

func _clear(col: CollisionWorld, p: Vector3) -> bool:
	if col.point_hit(p.x,p.y+0.85,p.z,CollisionWorld.ALL_SOLID): return false
	var hit := col.capsule_hit(p+Vector3(0,0.34,0),p+Vector3(0,1.37,0),0.32,CollisionWorld.ALL_SOLID)
	return hit.is_empty() or float(hit.get("depth",0.0)) <= 0.02

func _blockers(col: CollisionWorld, p: Vector3) -> Array:
	var ids: Array = []
	var body := AABB(p+Vector3(-0.31,0.21,-0.31),Vector3(0.62,1.56,0.62))
	for set_id in CollisionWorld.SET_COUNT:
		for id: String in col._by_id[set_id]:
			for idx: int in col._by_id[set_id][id]:
				if not col.is_box_active(set_id,idx): continue
				var box := col.box_aabb_d(set_id,idx)
				if AABB(Vector3(box[0],box[1],box[2]),Vector3(box[3]-box[0],box[4]-box[1],box[5]-box[2])).intersects(body): ids.append(id)
	return ids

func _check(ok: bool, label: String) -> void:
	if not ok: errors.append(label)

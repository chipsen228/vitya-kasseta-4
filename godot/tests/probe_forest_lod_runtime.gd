## Temporary read-only runtime geometry probe; does not modify production sources.
extends SceneTree

func _initialize() -> void:
	_run.call_deferred()

func _assemble(tree: ForestLodMesh, packed: bool) -> Array:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var data := {Mesh.ARRAY_VERTEX: [],Mesh.ARRAY_NORMAL: [],Mesh.ARRAY_TEX_UV: []}
	for id: String in tree.anchors:
		var source: Array = tree._background_arrays if tree.background_ids.has(id) else tree._far_arrays if tree.far_ids.has(id) else tree._near_arrays
		var parts: Dictionary = tree.background_ranges if tree.background_ids.has(id) else tree.far_ranges if tree.far_ids.has(id) else tree.near_ranges
		for span: Vector2i in parts[id]:
			if packed:
				vertices.append_array((source[Mesh.ARRAY_VERTEX] as PackedVector3Array).slice(span.x,span.x+span.y))
				normals.append_array((source[Mesh.ARRAY_NORMAL] as PackedVector3Array).slice(span.x,span.x+span.y))
				uvs.append_array((source[Mesh.ARRAY_TEX_UV] as PackedVector2Array).slice(span.x,span.x+span.y))
			else:
				for channel: int in data:
					(data[channel] as Array).append_array(source[channel].slice(span.x,span.x+span.y))
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices if packed else PackedVector3Array(data[Mesh.ARRAY_VERTEX])
	arrays[Mesh.ARRAY_NORMAL] = normals if packed else PackedVector3Array(data[Mesh.ARRAY_NORMAL])
	arrays[Mesh.ARRAY_TEX_UV] = uvs if packed else PackedVector2Array(data[Mesh.ARRAY_TEX_UV])
	return arrays

func _run() -> void:
	var world := Node3D.new()
	root.add_child(world)
	WorldBuilder.build(world,Materials.new().load_all(),CollisionWorld.new())
	var trees: Array[ForestLodMesh] = []
	var chunks: Array = []
	for child: Node in world.get_children():
		if not child is ForestLodMesh: continue
		var tree := child as ForestLodMesh
		tree.set_process(false)
		trees.append(tree)
		var spans := 0
		for id: String in tree.anchors: spans += tree.near_ranges[id].size()
		chunks.append({"name":str(tree.name),"anchors":tree.anchors.size(),"spans":spans,
			"near_vertices":tree._near_arrays[Mesh.ARRAY_VERTEX].size(),"far_vertices":tree._far_arrays[Mesh.ARRAY_VERTEX].size(),
			"background_vertices":tree._background_arrays[Mesh.ARRAY_VERTEX].size()})
	var route: Array[Vector3] = []
	for i in 13: route.append(Vector3(-6.0-float(i)*.5,1.68,-78))
	for i in 8: route.append(Vector3(-12,1.68,-78.5-float(i)*.5))
	for i in 12: route.append(Vector3(-12.5-float(i)*.5,1.68,-82))
	var rows: Array = []
	var build_rows: Array = []
	var mismatches := 0
	for position_world: Vector3 in route:
		var elapsed := 0
		var misses := 0
		var changed: Array = []
		for tree: ForestLodMesh in trees:
			var before := tree._mixed_order.duplicate()
			var start := Time.get_ticks_usec()
			tree.update_for_camera(position_world)
			var update_us := Time.get_ticks_usec()-start
			elapsed += update_us
			if before == tree._mixed_order: continue
			misses += 1
			changed.append(str(tree.name))
			var old_us := 0
			var packed_us := 0
			var upload_us := 0
			for repeat in 3:
				start = Time.get_ticks_usec()
				var old := _assemble(tree,false)
				old_us += Time.get_ticks_usec()-start
				start = Time.get_ticks_usec()
				var packed := _assemble(tree,true)
				packed_us += Time.get_ticks_usec()-start
				for channel: int in [Mesh.ARRAY_VERTEX,Mesh.ARRAY_NORMAL,Mesh.ARRAY_TEX_UV]:
					if old[channel] != packed[channel]: mismatches += 1
				start = Time.get_ticks_usec()
				var candidate := ArrayMesh.new()
				candidate.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,packed)
				upload_us += Time.get_ticks_usec()-start
			build_rows.append({"name":str(tree.name),"point":[position_world.x,position_world.z],"anchors":tree.anchors.size(),
				"vertices":tree.mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size(),"runtime_us":update_us,
				"variant_assembly_us":old_us/3.0,"packed_assembly_us":packed_us/3.0,"mesh_create_us":upload_us/3.0})
		rows.append({"point":[position_world.x,position_world.z],"update_total_us":elapsed,"cache_misses":misses,"changed":changed})
	chunks.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return int(a.anchors)>int(b.anchors))
	rows.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return int(a.update_total_us)>int(b.update_total_us))
	build_rows.sort_custom(func(a: Dictionary,b: Dictionary) -> bool: return float(a.runtime_us)>float(b.runtime_us))
	var report := {"renderer":DisplayServer.get_name(),"chunks":chunks,"route":rows,"builds":build_rows,"mismatches":mismatches}
	var file := FileAccess.open("res://../output/episode/probe-forest-lod-runtime.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"))
	file.close()
	print("forest runtime probe chunks=",chunks.size()," mismatches=",mismatches," builds=",build_rows.size())
	print("largest chunks: ",JSON.stringify(chunks.slice(0,8)))
	print("slowest updates: ",JSON.stringify(rows.slice(0,8)))
	print("slowest builds: ",JSON.stringify(build_rows.slice(0,8)))
	world.free()
	quit(0 if mismatches==0 else 1)

## Boundary fences keep their original vertices when a neighbouring yard is replaced.
extends SceneTree

var errors: Array[String]=[]

func _initialize() -> void:
	Materials.render_hq_enabled=true
	var mats:=Materials.new().load_all();var world:=Node3D.new();root.add_child(world)
	var col:=CollisionWorld.new();var built:=WorldBuilder.build(world,mats,col)
	var physics:=var_to_str([col._data,col._active,col._by_id])
	var nodes:=SkinLayer._nodes(world)
	var rows: Array=[]
	for index in 4:
		var owner:="fences/environment/yard-neighbour-%02d" % index
		var triangles:=0;var surviving:=0
		for node: Node in nodes:
			if not node is MeshInstance3D or not node.has_meta("skin_parts"): continue
			var parts: Dictionary=node.get_meta("skin_parts")
			for span: Vector2i in parts.get(owner,[]): triangles+=span.y/3
		# The two 7m rails retain the source grid subdivisions; five posts stay single boxes.
		if triangles!=132: errors.append(owner+" original 2 rails/5 posts omitted")
		var removed:=EnvironmentRegistry._remove_owner(world,nodes,{"id":"yard-neighbour-%02d" % index,
			"owner_keys":["interiors/environment/yard-neighbour-%02d" % index],"removal_mode":"whole"})
		for node: Node in nodes:
			if not node is MeshInstance3D or not node.has_meta("skin_parts"): continue
			var parts: Dictionary=node.get_meta("skin_parts")
			var hidden: Dictionary=node.get_meta("environment_hidden_vertices",{})
			for span: Vector2i in parts.get(owner,[]):
				for vertex in range(span.x,span.x+span.y,3):
					if not hidden.has(vertex): surviving+=1
		if surviving!=triangles or removed<=0: errors.append(owner+" did not survive real yard owner removal")
		rows.append({"owner":owner,"source_triangles":triangles,"surviving_triangles":surviving,"yard_removed_triangles":removed})
	if physics!=var_to_str([col._data,col._active,col._by_id]): errors.append("fence owner removal changed physics")
	if col.box_count(CollisionWorld.SET_STATIC)!=311 or col.box_count(CollisionWorld.SET_BLOCKERS)!=4 or int(built["triangles"])!=3885: errors.append("base changed")
	var file:=FileAccess.open("C:/Users/Peter Zakharov/Desktop/vitya-godot/output/environment-refresh/yard-boundary-guard.json",FileAccess.WRITE)
	file.store_string(JSON.stringify({"fences":rows,"physics_unchanged":physics==var_to_str([col._data,col._active,col._by_id]),"errors":errors},"\t"));file.close()
	for error: String in errors: printerr("boundary: ",error)
	print("test_environment_yard_boundary: ","PASS" if errors.is_empty() else "FAIL",rows)
	world.free();quit(0 if errors.is_empty() else 1)

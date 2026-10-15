## Small interior details belong to the house's near view, not the distant street.
extends RefCounted

const INTERIORS := preload("res://src/environment_interiors.gd")
const HOME := ["kitchen-grater", "kitchen-bowl", "kitchen-grater-sink", "tonya-bed",
	"tonya-nightstand", "tonya-chest", "tonya-chair", "tonya-basin", "kitchen-phone",
	"kitchen-phone-numbers", "tonya-photo", "attic-album", "tripod-mark", "loft-doll"]
const VILLAGE := ["boarded-bunk", "boarded-cans", "boarded-tripod", "boarded-tapes",
	"redhouse-drawing", "redhouse-toy", "arkady-tv", "shop-crate", "shop-scales",
	"shop-ledger", "shop-phone", "boarded-slit", "redhouse-fridge"]

static func apply(world: Node3D, built: Dictionary, props: Props) -> Dictionary:
	if world.has_meta("environment_detail_ranges"):
		return world.get_meta("environment_detail_ranges")
	var report := {"active":not OS.get_cmdline_user_args().has("--environment=off"),
		"nodes":[],"physics_mutations":0,"material_mutations":0}
	if not report["active"]: return report
	for category: String in ["home","village"]:
		var owners: Dictionary = built.get(category,{}).get("nodes",{})
		for id: String in HOME if category == "home" else VILLAGE:
			var holder: Node3D = owners.get(id)
			if holder != null: _limit_tree(holder,18.0,report)
	var rooms := INTERIORS._rooms()
	var dynamic: Dictionary = {}
	for def: Dictionary in GameData.props().get("DYNAMIC_PROPS",[]): dynamic[String(def["id"])] = true
	var holders: Array[Node3D] = []
	var named: Dictionary = {}
	for id: String in props.by_id:
		named[props.by_id[id]] = true
		if dynamic.has(id) or props.dynamic_pool.has(id): continue
		holders.append(props.by_id[id])
	# Imported cabinets and chairs often have no interaction ID. They are still
	# ordinary static room furniture; keep all runtime-owned objects excluded.
	if is_instance_valid(props.root):
		for holder: Node in props.root.get_children():
			if not holder is Node3D or named.has(holder) or holder.get_script() != null: continue
			if props.dynamic_pool.values().has(holder): continue
			var animated := false
			for node: Node in _nodes(holder):
				if node is AnimationPlayer or node is AnimationTree or node is Skeleton3D \
						or node.get_script() != null or node.has_meta("independent_visual") \
						or (node is MeshInstance3D and node.skin != null):
					animated = true
					break
			if not animated: holders.append(holder)
	for holder: Node3D in holders:
		var bounds := _bounds(world,holder)
		if bounds.size == Vector3.ZERO: continue
		for room: Dictionary in rooms:
			var box: Array = room["box"]
			var floor_y := float(room["floor"])
			var room_bounds := AABB(Vector3(box[0]-.03,floor_y-.10,box[2]-.03),
				Vector3(box[1]-box[0]+.06,float(room["height"])+.20,box[3]-box[2]+.06))
			if room_bounds.encloses(bounds):
				_limit_tree(holder,18.0,report)
				break
	for child: Node in world.get_children():
		if child is MeshInstance3D and child.has_meta("environment_interior_role"):
			var role := String(child.get_meta("environment_interior_role"))
			_limit(child,16.0 if role == "baseboard" else 18.0 if role == "frame" else 28.0,report)
	world.set_meta("environment_detail_ranges",report)
	return report

static func _limit_tree(holder: Node3D, distance: float, report: Dictionary) -> void:
	for node: Node in _nodes(holder):
		if node is MeshInstance3D: _limit(node,distance,report)

static func _limit(mesh: MeshInstance3D, distance: float, report: Dictionary) -> void:
	if mesh.visibility_range_end > 0.0 and mesh.visibility_range_end <= distance: return
	var previous := mesh.visibility_range_end
	mesh.visibility_range_end = distance
	mesh.visibility_range_end_margin = 1.0
	mesh.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	report["nodes"].append({"node":str(mesh.get_path()),"before":previous,"after":distance})

static func _bounds(world: Node3D, holder: Node3D) -> AABB:
	var bounds := AABB()
	var first := true
	for node: Node in _nodes(holder):
		if not node is MeshInstance3D or node.mesh == null: continue
		var transform: Transform3D = world.global_transform.affine_inverse()*node.global_transform
		var box: AABB = transform*node.get_aabb()
		bounds = box if first else bounds.merge(box)
		first = false
	return bounds

static func _nodes(holder: Node) -> Array[Node]:
	var result: Array[Node] = [holder]
	var index := 0
	while index < result.size():
		result.append_array(result[index].get_children())
		index += 1
	return result

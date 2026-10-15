## Eight authored clumps. Call after the complete Props/dynamic collision build.
## Baked geometry/materials/native LOD indices remain shared and untouched.
class_name EnvironmentVerge
extends RefCounted

const ASSETS := preload("res://src/procedural_assets.gd")
const GROUPS := [
	{"id":"dry","domain":"dry-verge","key":"scatter/nat-grass","range":18.0,
		"near":30,"far":15,"points":[Vector3(-9.0,0.28,-7.2),Vector3(-8.2,0.36,-7.2),Vector3(-7.4,0.30,-7.2)]},
	{"id":"wet","domain":"wet-shore","key":"scatter/nat-grass-tall","range":24.0,
		"near":30,"far":15,"points":[Vector3(-21.25,0.42,-44.5),Vector3(-21.2,0.55,-45.2),Vector3(-21.15,0.48,-45.9)]},
	{"id":"forest-fern","domain":"mixed-forest-edge","key":"scatter/nat-fern","range":18.0,
		"near":100,"far":30,"points":[Vector3(-37.5,0.42,-34.1)]},
	{"id":"forest-bush","domain":"mixed-forest-edge","key":"scatter/nat-bush","range":18.0,
		"near":36,"far":12,"points":[Vector3(-36.6,0.50,-34.1)]},
]
const OFFSETS := [Vector2.ZERO,Vector2(0,0.20),Vector2(0,0.40),Vector2(0,-0.20),Vector2(0,-0.40),
	Vector2(0.25,0),Vector2(-0.25,0),Vector2(0.25,0.20),Vector2(-0.25,0.20),Vector2(0.25,0.40),Vector2(-0.25,0.40)]
const CLEARANCE := 0.20
const SOLID_MARGIN := 0.05

static func apply(world: Node3D,col: CollisionWorld) -> Dictionary:
	var report := {"active":false,"nodes":{},"groups":[],"placements":[],"rejections":[],"resources":[],
		"instances":0,"surfaces":0,"near_triangles":0,"far_triangles":0,"far_source_available":0,"errors":[],
		"physics_delta":0,"native_lod":true,"visual_verified":false,"actual_gpu_buffer_verified":false,
		"material_stage":"shared baked materials; final HQ quality sweep is owned by Main"}
	if OS.get_cmdline_user_args().has("--environment=off"): return report
	if world.has_meta("environment_verge_report"): return world.get_meta("environment_verge_report")
	if col.box_count(CollisionWorld.SET_PROPS)==0:
		report["errors"].append("EnvironmentVerge requires final ALL_SOLID including Props before admission")
		return report
	var before := physics_stamp(col)
	var clear: Array = Scatter.data().get("CLEAR",[])
	var rooms: Array = RuralDressing.placement_registry()
	for spec: Dictionary in GROUPS:
		_add_group(world,col,spec,clear,rooms,report)
	report["active"]=true
	report["physics_delta"]=0 if physics_stamp(col)==before else 1
	if int(report["instances"])!=8 or int(report["surfaces"])!=4:
		report["errors"].append("authored pilot requires eight accepted clumps and four surfaces")
	if int(report["near_triangles"])>316 or int(report["far_triangles"])>132:
		report["errors"].append("pilot geometry exceeded fixed 316/132 triangle cap")
	world.set_meta("environment_verge_report",report)
	return report

static func _add_group(world: Node3D,col: CollisionWorld,spec: Dictionary,
		clear: Array,rooms: Array,report: Dictionary) -> void:
	var key := String(spec["key"])
	var asset := ASSETS.fetch(key)
	if asset.is_empty(): report["errors"].append("missing baked "+key);return
	var meshes: Array = asset["meshes"]
	var mesh: ArrayMesh = null
	for piece: ArrayMesh in meshes:
		if piece.get_surface_count()>0:
			if mesh!=null: report["errors"].append("pilot needs one source surface "+key);return
			mesh=piece
	if mesh==null or mesh.get_surface_count()!=1: report["errors"].append("invalid source mesh "+key);return
	var far_tris := 0
	for piece: ArrayMesh in asset["lod_meshes"]: far_tris+=ASSETS.triangles(piece)
	var near_tris := ASSETS.triangles(mesh)
	if near_tris!=int(spec["near"]) or far_tris!=int(spec["far"]):
		report["errors"].append("baked geometry budget changed "+key);return
	var native_lods := native_lod_records(mesh)
	var runtime_far := 0
	if not native_lods.is_empty():
		for lod: Dictionary in native_lods:
			if int(lod["index_count"])!=far_tris*3:
				report["errors"].append("embedded native LOD indices differ from source far "+key);return
		runtime_far=far_tris
	var transforms: Array[Transform3D] = []
	var accepted_rows: Array = []
	var bounds := mesh.get_aabb()
	for point: Vector3 in spec["points"]:
		var preferred := Vector2(point.x,point.z)
		var scale_value := point.y/maxf(bounds.size.y,0.0001)
		var basis := Basis(Vector3.UP,float(transforms.size())*0.73).scaled(Vector3.ONE*scale_value)
		var found := false
		for offset: Vector2 in OFFSETS:
			var at := preferred+offset
			var floor_hit := col.ray_down(at.x,1.60,at.y,CollisionWorld.ALL_SOLID)
			if floor_hit.is_empty() or (floor_hit["normal"] as Vector3).y<0.95:
				report["rejections"].append({"domain":spec["domain"],"preferred":[preferred.x,preferred.y],"candidate":[at.x,at.y],"reason":"no flat support"});continue
			var floor_y := float(floor_hit["y"])
			var xf := Transform3D(basis,Vector3(at.x,floor_y+0.012-bounds.position.y*scale_value,at.y))
			var box: AABB = xf*bounds
			var reason := admission_reason(col,box,clear,rooms,floor_y)
			if not reason.is_empty():
				report["rejections"].append({"domain":spec["domain"],"preferred":[preferred.x,preferred.y],"candidate":[at.x,at.y],"reason":reason});continue
			transforms.append(xf)
			accepted_rows.append({"domain":spec["domain"],"owner":"vegetation/"+String(spec["domain"]),
				"preferred":[preferred.x,preferred.y],"position":[at.x,floor_y,at.y],"height":point.y,
				"offset":[offset.x,offset.y],"bounds":_box_record(box),"all_solid":true,"off_routes":true,"clear_admitted":true})
			found=true;break
		if not found: report["errors"].append("no finite safe placement "+String(spec["domain"])+" "+str(preferred))
	if transforms.is_empty(): return
	var world_bounds: AABB = transforms[0]*bounds
	for xf: Transform3D in transforms: world_bounds=world_bounds.merge(xf*bounds)
	var centre := world_bounds.get_center()
	var mm := MultiMesh.new()
	mm.transform_format=MultiMesh.TRANSFORM_3D;mm.mesh=mesh;mm.instance_count=transforms.size()
	var buffer := PackedFloat32Array()
	var intended: Array = []
	for i in transforms.size():
		var local_xf := transforms[i]
		local_xf.origin-=centre
		var encoded := _encode_transform(local_xf)
		buffer.append_array(encoded)
		intended.append(Array(encoded))
	mm.buffer=buffer
	mm.custom_aabb=AABB(world_bounds.position-centre,world_bounds.size)
	var node := MultiMeshInstance3D.new()
	node.name="environment-verge-"+String(spec["id"]);node.position=centre;node.multimesh=mm
	node.cast_shadow=GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	node.visibility_range_end=float(spec["range"]);node.visibility_range_end_margin=2.0
	node.visibility_range_fade_mode=GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	node.set_meta("environment_owner","vegetation/"+String(spec["domain"]))
	node.set_meta("environment_source",[ASSETS.asset_path(key)]);node.set_meta("environment_domain",spec["domain"])
	# RendererDummy cannot read buffers back; retain the exact requested float32
	# upload for the CPU fixture, while GPU acceptance reads the live MultiMesh.
	node.set_meta("environment_written_buffer",buffer)
	world.add_child(node)
	(report["nodes"] as Dictionary)[String(spec["id"])]=node
	(report["placements"] as Array).append_array(accepted_rows)
	var source_path := ASSETS.asset_path(key)
	var resource_row := {"key":key,"path":source_path,"sha256":FileAccess.get_sha256(source_path),
		"license":"CC0 original project procedural geometry/textures",
		"origin":"res://src/procedural_assets.gd _plants; generated manifest source GDScript / Godot only",
		"generator_sha256":FileAccess.get_sha256("res://src/procedural_assets.gd"),"textures":[]}
	var mat := mesh.surface_get_material(0) as ShaderMaterial
	if mat!=null:
		var texture := mat.get_shader_parameter("albedo_tex") as Texture2D
		if texture!=null:
			(resource_row["textures"] as Array).append({"path":texture.resource_path,"sha256":FileAccess.get_sha256(texture.resource_path),"size":[texture.get_width(),texture.get_height()]})
	(report["resources"] as Array).append(resource_row)
	(report["groups"] as Array).append({"id":spec["id"],"domain":spec["domain"],"node":String(node.name),
		"mesh_resource":mesh.resource_path,"source_key":key,"instances":transforms.size(),"surfaces":1,
		"near_triangles":near_tris*transforms.size(),"far_triangles":runtime_far*transforms.size(),
		"far_source_available":far_tris*transforms.size(),"native_lod_records":native_lods,
		"intended_transforms":intended,"node_position":[centre.x,centre.y,centre.z],
		"bounds":_box_record(world_bounds),"native_lod":not native_lods.is_empty(),"range_end":spec["range"],"shadows":false})
	report["instances"]=int(report["instances"])+transforms.size()
	report["surfaces"]=int(report["surfaces"])+1
	report["near_triangles"]=int(report["near_triangles"])+near_tris*transforms.size()
	report["far_triangles"]=int(report["far_triangles"])+runtime_far*transforms.size()
	report["far_source_available"]=int(report["far_source_available"])+far_tris*transforms.size()
	report["native_lod"]=bool(report["native_lod"]) and not native_lods.is_empty()

static func _encode_transform(xf: Transform3D) -> PackedFloat32Array:
	return PackedFloat32Array([xf.basis.x.x,xf.basis.y.x,xf.basis.z.x,xf.origin.x,
		xf.basis.x.y,xf.basis.y.y,xf.basis.z.y,xf.origin.y,
		xf.basis.x.z,xf.basis.y.z,xf.basis.z.z,xf.origin.z])

static func native_lod_records(mesh: ArrayMesh) -> Array:
	var surfaces: Array=mesh.get("_surfaces")
	var result: Array=[]
	for surface: Dictionary in surfaces:
		var pairs: Array=surface.get("lods",[])
		var base_count:=int(surface.get("index_count",0))
		var base: PackedByteArray=surface.get("index_data",PackedByteArray())
		var stride: int=base.size()/base_count if base_count>0 else (2 if int(surface["vertex_count"])<=65536 else 4)
		for i in range(0,pairs.size(),2):
			var bytes: PackedByteArray=pairs[i+1]
			var digest := HashingContext.new()
			digest.start(HashingContext.HASH_SHA256);digest.update(bytes)
			result.append({"edge":float(pairs[i]),"bytes":bytes.size(),"index_stride":stride,
				"index_count":bytes.size()/stride,"sha256":digest.finish().hex_encode()})
	return result

static func admission_reason(col: CollisionWorld,box: AABB,clear: Array,rooms: Array,floor_y: float) -> String:
	var rect := Rect2(Vector2(box.position.x,box.position.z),Vector2(box.size.x,box.size.z))
	var protected := rect.grow(CLEARANCE)
	for route: Dictionary in EnvironmentLandscape.route_footprints():
		if protected.intersects(route["rect"],true): return "route footprint"
	for row: Array in clear:
		if row.size()>=4 and protected.intersects(Rect2(float(row[0]),float(row[2]),float(row[1])-float(row[0]),float(row[3])-float(row[2])),true): return "CLEAR"
	for room: Dictionary in rooms:
		if protected.intersects(room["rect"],true): return "building/yard/nav footprint"
	var guarded := rect.grow(SOLID_MARGIN)
	for set_id in CollisionWorld.SET_COUNT:
		for i in col.box_count(set_id):
			if not col.is_box_active(set_id,i): continue
			var shape := col.box_aabb_d(set_id,i)
			# The selected ground is support. Everything above it must stay clear;
			# box_aabb encloses rotated solids, making rejection conservative.
			if float(shape[4])<=floor_y+0.020 or float(shape[1])>box.end.y+0.05: continue
			if guarded.intersects(Rect2(float(shape[0]),float(shape[2]),float(shape[3])-float(shape[0]),float(shape[5])-float(shape[2])),true): return "ALL_SOLID footprint"
	return ""

static func physics_stamp(col: CollisionWorld) -> String:
	var text := ""
	for set_id in CollisionWorld.SET_COUNT:
		for i in col.box_count(set_id): text+=var_to_str(col.box_aabb_d(set_id,i))+var_to_str(col.box_shape_d(set_id,i))+str(col.is_box_active(set_id,i))
	return text.sha256_text()

static func _box_record(box: AABB) -> Dictionary:
	return {"min":[box.position.x,box.position.y,box.position.z],"size":[box.size.x,box.size.y,box.size.z]}

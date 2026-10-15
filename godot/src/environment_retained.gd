## Фактические сохранённые меши. Реестр не меняет сцену и коллизии.
class_name EnvironmentRetained
extends RefCounted

const PUBLIC_SITES := {
	"greenhouse": ["buildings/site/greenhouse"],
	"stop": ["buildings/village/STOP"],
	"well": ["buildings/village/WELL"],
	"mill": ["buildings/outskirts/MILL"],
	"hens-cottage": ["buildings/outskirts/HENS-coop"],
}
const SITE_CAMERAS := {
	"greenhouse": [[-7.0,1.65,16.0],[-7.0,1.2,21.0]],
	"shower": [[7.6,1.65,15.4],[7.6,1.3,17.4]],
	"stop": [[-42.6,1.65,-4.5],[-42.6,1.3,-6.8]],
	"well": [[-24.0,1.65,-6.9],[-24.0,1.2,-9.0]],
	"mill": [[21.0,1.65,-21.0],[21.0,5.0,-29.0]],
	"cemetery": [[40.05,1.65,-5.8],[40.05,1.0,-10.0]],
	"hens-cottage": [[-7.72,1.65,-22.3],[-7.72,1.25,-25.8]],
}


static func apply(world: Node3D, built: Dictionary, _mats: Materials) -> Array[Dictionary]:
	var rows: Array[Dictionary] = []
	var nodes := _nodes(world)
	var sources := _source_owners(world,nodes)
	var props_root:=world.get_node_or_null("props")
	for id: String in PUBLIC_SITES:
		var row := _row("retained/public/"+id,"public-site",id,"procedural-merged")
		for key: String in PUBLIC_SITES[id]:
			if sources.has(key): _merge(row,sources[key])
		row["source_owners"]=PUBLIC_SITES[id].duplicate()
		row["resources"].append("res://src/world_builder.gd" if id=="greenhouse" else "res://src/outskirts_world.gd" if id in ["mill","hens-cottage"] else "res://src/village_world.gd")
		if id=="greenhouse": _named(world,nodes,"greenhouse-bed",row)
		elif id=="mill": _named(world,nodes,"old-windmill",row)
		elif id=="well":
			for key: String in ["village-well-drum","village-well-bucket","village-well-raised","village-well-column","village-well-bundle"]: _named(world,nodes,key,row)
		row["camera_refs"]=[{"eye":SITE_CAMERAS[id][0],"look":SITE_CAMERAS[id][1]}]
		_finish(row)
		rows.append(row)
	if props_root!=null:
		for def: Dictionary in GameData.props().get("PROPS",[]):
			var at:=GameData.vec3(def["at"])
			var room:=_room_at(at)
			if room.is_empty(): continue
			var id:=String(def.get("id",def.get("m",def.get("make","prop"))))
			var row:=_row("retained/interior-prop/"+id+"@%.2f,%.2f,%.2f" % [at.x,at.y,at.z],"interior-prop",String(def.get("m",def.get("make",""))),"existing-interior-prop")
			for holder: Node3D in props_root.get_children():
				if holder.position.is_equal_approx(at): _mesh_tree(world,holder,row);break
			if def.has("m"): row["resources"].append("res://assets/models/"+String(def["m"])+".glb")
			else: row["resources"].append("res://src/props.gd")
			row["room"]=room
			_finish(row)
			if row["present"]: rows.append(row)
	var shower := _row("retained/public/shower","public-site","summerShower","procedural-detailed")
	_named(world,nodes,"summer-shower",shower)
	shower["resources"].append("res://src/detailed_props.gd")
	shower["camera_refs"]=[{"eye":SITE_CAMERAS["shower"][0],"look":SITE_CAMERAS["shower"][1]}]
	_finish(shower)
	rows.append(shower)
	var cemetery := _row("retained/public/cemetery","public-site","nine-crosses-pit-flowers","procedural-spatial-selection")
	var grave: Dictionary=VillageWorld.data().get("GRAVEYARD",{})
	if not grave.is_empty():
		var x: Array=grave["x"]
		var z: Array=grave["z"]
		_spatial(world,nodes,Rect2(float(x[0])-.1,float(z[0])-.1,float(x[1])-float(x[0])+.2,float(z[1])-float(z[0])+.2),-.7,1.5,
			["metal","boards","concrete","dirt","dark"],cemetery)
		cemetery["detail_count"]=(grave.get("graves",[]) as Array).size()
	for key: String in ["village-grave-wife","village-grave-pit"]: _named(world,nodes,key,cemetery)
	cemetery["resources"].append("res://src/village_world.gd")
	cemetery["camera_refs"]=[{"eye":SITE_CAMERAS["cemetery"][0],"look":SITE_CAMERAS["cemetery"][1]}]
	_finish(cemetery)
	rows.append(cemetery)
	if props_root!=null:
		for def: Dictionary in GameData.props().get("PROPS",[]):
			var model:=String(def.get("m",""))
			if not model.begins_with("farm-"): continue
			if def.get("id","")=="old-windmill": continue
			var at:=GameData.vec3(def["at"])
			var row:=_row("retained/public/"+model+"@%.2f,%.2f" % [at.x,at.z],"public-site",model,"existing-glb")
			for holder: Node3D in props_root.get_children():
				if holder.position.is_equal_approx(at): _mesh_tree(world,holder,row);break
			row["resources"].append("res://assets/models/"+model+".glb")
			row["collision_source"]="OutskirtsWorld original SET_OVERLAY"
			_finish(row)
			rows.append(row)
	for plot: Dictionary in SntWorld.data().get("PLOTS",[]):
		var car: Dictionary=plot.get("car",{})
		if car.is_empty(): continue
		var id:=String(plot["id"])
		var row:=_row("retained/car/"+id,"car",String(car.get("family","sedan")),"procedural-vehicle")
		_named(world,nodes,"snt-car-"+id,row)
		row["resources"].append("res://src/vehicle_visuals.gd")
		row["collision_source"]="SntWorld original SET_OVERLAY "+id+"-car"
		row["controls"]["lod"]="ModelLodMesh near/far 16m; Props visibility 48m"
		_finish(row)
		rows.append(row)
	# После exterior removal эти диапазоны содержат только оставшиеся исходные грани.
	for category: String in ["houses","services"]:
		for descriptor: Dictionary in EnvironmentRegistry.manifest().get(category,[]):
			if descriptor.get("removal_mode","")!="exterior": continue
			var row:=_row("retained/interior/"+String(descriptor["id"]),"interior",String(descriptor["id"]),"original-building-surfaces")
			for key: String in descriptor.get("owner_keys",[]):
				if sources.has(key): _merge(row,sources[key])
			row["source_owners"]=descriptor.get("owner_keys",[]).duplicate()
			row["resources"].append("res://src/world_builder.gd")
			row["selection"]="non-hidden original owner triangles; exterior faces may remain when environment is off"
			_finish(row)
			if row["present"]: rows.append(row)
	for zone: String in ["home","yard","village","outskirts","snt"]:
		var section: Dictionary=built.get(zone,{})
		for id: String in section.get("nodes",{}):
			var holder: Variant=section["nodes"][id]
			if not holder is Node3D or not is_instance_valid(holder): continue
			var row:=_row("retained/detail/"+zone+"/"+id,"interior-detail",id,"original-gameplay-owner")
			_mesh_tree(world,holder,row)
			row["controls"]["gameplay_owner"]=zone+"/"+id
			row["resources"].append("res://src/"+zone+"_world.gd")
			_finish(row)
			if row["present"]: rows.append(row)
	var views: Dictionary={}
	if FileAccess.file_exists("res://data/environment_views.json"):
		var parsed: Variant=JSON.parse_string(FileAccess.get_file_as_string("res://data/environment_views.json"))
		if parsed is Dictionary: views=parsed
	for row: Dictionary in rows: _camera_refs(row,views.get("views",[]))
	return rows


static func _row(owner: String,kind: String,variant: String,source: String) -> Dictionary:
	return {"owner":owner,"kind":kind,"source_kind":source,"retention_reason":"reviewed-existing-detail",
		"detail_variant":variant,"resources":[],"materials":[],"nodes":[],"bounds":{"min":[],"size":[]},
		"triangles":0,"surfaces":0,"present":false,"capture_quality":"hq" if Materials.render_hq_enabled else "retro",
		"camera_refs":[],"controls":{"render":"RenderChain render_hq","geometry":"original owner; read-only inventory"},
		"_min":[],"_max":[]}


static func _source_owners(world: Node3D,nodes: Array[Node]) -> Dictionary:
	var out: Dictionary={}
	for node: Node in nodes:
		if not node is MeshInstance3D or not node.has_meta("skin_parts"): continue
		var mi:=node as MeshInstance3D
		if mi.mesh==null or mi.mesh.get_surface_count()!=1: continue
		if _renderer(mi)==null: continue
		var arrays:=mi.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var hidden: Dictionary=mi.get_meta("environment_hidden_vertices",{}).duplicate()
		hidden.merge(mi.get_meta("skin_hidden_vertices",{}))
		var transform:=_transform(world,mi)
		var parts: Dictionary=mi.get_meta("skin_parts")
		for key: String in parts:
			if not key.begins_with("buildings/"): continue
			if not out.has(key): out[key]=_row(key,"source-owner",key,"merged-owner")
			var row: Dictionary=out[key]
			var before:=int(row["triangles"])
			for span: Vector2i in parts[key]:
				for index in range(span.x,span.x+span.y,3):
					if hidden.has(index): continue
					row["triangles"]+=1
					for offset in 3: _point(row,transform*vertices[index+offset])
			if int(row["triangles"])>before: _mesh_info(world,mi,0,row)
	return out


static func _named(world: Node3D,nodes: Array[Node],name: String,row: Dictionary) -> void:
	for node: Node in nodes:
		if node is Node3D and String(node.name)==name:
			_mesh_tree(world,node,row)
			return


static func _mesh_tree(world: Node3D,node: Node,row: Dictionary) -> void:
	if node!=world and not world.is_ancestor_of(node): return
	if node is MeshInstance3D:
		var mi:=node as MeshInstance3D
		if mi.mesh!=null and (mi.layers!=0 or _batched_surfaces_valid(mi)):
			var transform:=_transform(world,mi)
			var bounds:=mi.mesh.get_aabb()
			for index in 8:
				_point(row,transform*(bounds.position+Vector3(bounds.size.x if (index&1)!=0 else 0.0,bounds.size.y if (index&2)!=0 else 0.0,bounds.size.z if (index&4)!=0 else 0.0)))
			for surface in mi.mesh.get_surface_count():
				var arrays:=mi.mesh.surface_get_arrays(surface)
				var indices: PackedInt32Array=arrays[Mesh.ARRAY_INDEX] if arrays[Mesh.ARRAY_INDEX]!=null else PackedInt32Array()
				row["triangles"]+=indices.size()/3 if not indices.is_empty() else arrays[Mesh.ARRAY_VERTEX].size()/3
				_mesh_info(world,mi,surface,row)
	for child: Node in node.get_children(): _mesh_tree(world,child,row)


static func _mesh_info(world: Node3D,mi: MeshInstance3D,surface: int,row: Dictionary) -> void:
	var actual:=_renderer(mi,surface)
	if actual==null: return
	if not mi.mesh.resource_path.is_empty() and not row["resources"].has(mi.mesh.resource_path): row["resources"].append(mi.mesh.resource_path)
	if actual!=mi and mi.has_meta("environment_static_batch_surfaces"):
		surface=int(mi.get_meta("environment_static_batch_surfaces")[surface]["surface"])
	mi=actual
	var path:=String(world.get_path_to(mi))
	if not row["nodes"].has(path):
		row["nodes"].append(path)
		row["surfaces"]+=mi.mesh.get_surface_count()
		if not row["controls"].has("visibility"): row["controls"]["visibility"]=[]
		row["controls"]["visibility"].append({"node":path,"visible":mi.is_visible_in_tree(),"layers":mi.layers,
			"range_begin":mi.visibility_range_begin,"range_end":mi.visibility_range_end,"shadows":mi.cast_shadow})
	if not mi.mesh.resource_path.is_empty() and not row["resources"].has(mi.mesh.resource_path): row["resources"].append(mi.mesh.resource_path)
	var material:=mi.get_active_material(surface)
	if material==null: return
	var descriptor: Dictionary={"instance_id":material.get_instance_id(),"resource":material.resource_path,"shader":"","textures":{},"quality":"standard-pbr"}
	if material is ShaderMaterial:
		var shader:=material as ShaderMaterial
		if shader.shader!=null:
			descriptor["shader"]=shader.shader.resource_path
			descriptor["quality"]="hq" if String(descriptor["shader"]).contains("psx_hq") else "custom" if String(descriptor["shader"])!=Materials.PSX_SHADER else "retro"
			for uniform: Dictionary in shader.shader.get_shader_uniform_list():
				var value: Variant=shader.get_shader_parameter(uniform["name"])
				if value is Texture2D: descriptor["textures"][uniform["name"]]=(value as Texture2D).resource_path
	elif material is BaseMaterial3D:
		var base:=material as BaseMaterial3D
		if base.albedo_texture!=null: descriptor["textures"]["albedo"]=base.albedo_texture.resource_path
	for existing: Dictionary in row["materials"]:
		if existing["instance_id"]==descriptor["instance_id"]: return
	row["materials"].append(descriptor)


static func _spatial(world: Node3D,nodes: Array[Node],rect: Rect2,y0: float,y1: float,keys: Array,row: Dictionary) -> void:
	row["selection"]="original merged triangles fully inside cemetery region; source has no owner tag"
	for node: Node in nodes:
		if not node is MeshInstance3D: continue
		var mi:=node as MeshInstance3D
		var selected:=false
		for key: String in keys:
			if String(mi.name).begins_with("merged_"+key+"_") or String(mi.name).begins_with("merged:"+key+":"): selected=true
		if mi.mesh==null or not selected: continue
		if _renderer(mi)==null: continue
		var arrays:=mi.mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array=arrays[Mesh.ARRAY_VERTEX]
		var transform:=_transform(world,mi)
		var hidden: Dictionary=mi.get_meta("environment_hidden_vertices",{}).duplicate()
		hidden.merge(mi.get_meta("skin_hidden_vertices",{}))
		var before:=int(row["triangles"])
		for index in range(0,vertices.size(),3):
			if hidden.has(index): continue
			var centre:=transform*((vertices[index]+vertices[index+1]+vertices[index+2])/3.0)
			if centre.y<y0 or centre.y>y1 or not rect.has_point(Vector2(centre.x,centre.z)): continue
			var inside:=true
			for offset in 3:
				var point:=transform*vertices[index+offset]
				if point.y<y0 or point.y>y1 or not rect.has_point(Vector2(point.x,point.z)): inside=false
			if not inside: continue
			row["triangles"]+=1
			for offset in 3: _point(row,transform*vertices[index+offset])
		if int(row["triangles"])>before: _mesh_info(world,mi,0,row)


static func _point(row: Dictionary,p: Vector3) -> void:
	if row["_min"].is_empty(): row["_min"]=[p.x,p.y,p.z];row["_max"]=[p.x,p.y,p.z];return
	for index in 3:
		row["_min"][index]=minf(float(row["_min"][index]),p[index])
		row["_max"][index]=maxf(float(row["_max"][index]),p[index])


static func _batched_surfaces_valid(mi: MeshInstance3D) -> bool:
	if mi.mesh==null or not mi.has_meta("environment_static_batch_owner"): return false
	var mapping: Dictionary=mi.get_meta("environment_static_batch_surfaces",{})
	if mapping.size()!=mi.mesh.get_surface_count(): return false
	for surface in mi.mesh.get_surface_count():
		var entry: Dictionary=mapping.get(surface,{})
		var candidate: Variant=entry.get("node")
		if not is_instance_valid(candidate) or not candidate is MeshInstance3D: return false
		if candidate.mesh==null or candidate.layers==0 or not candidate.is_visible_in_tree(): return false
		var actual:=int(entry.get("surface",-1))
		if actual<0 or actual>=candidate.mesh.get_surface_count(): return false
	return true


static func _renderer(mi: MeshInstance3D,surface: int=0) -> MeshInstance3D:
	if mi.mesh!=null and mi.layers!=0: return mi
	if _batched_surfaces_valid(mi): return mi.get_meta("environment_static_batch_surfaces")[surface]["node"]
	for key: String in ["environment_residual","skin_residual"]:
		if not mi.has_meta(key): continue
		var candidate: Variant=mi.get_meta(key)
		if is_instance_valid(candidate) and candidate is MeshInstance3D and candidate.mesh!=null and candidate.layers!=0: return candidate
	return null


static func _merge(row: Dictionary,source: Dictionary) -> void:
	row["triangles"]+=int(source["triangles"])
	row["surfaces"]+=int(source["surfaces"])
	if not source["_min"].is_empty():
		_point(row,GameData.vec3(source["_min"]))
		_point(row,GameData.vec3(source["_max"]))
	for field: String in ["nodes","resources","materials"]:
		for value: Variant in source[field]:
			if not row[field].has(value): row[field].append(value)


static func _finish(row: Dictionary) -> void:
	row["present"]=int(row["triangles"])>0 and not row["_min"].is_empty()
	if row["present"]:
		var low:=GameData.vec3(row["_min"])
		var high:=GameData.vec3(row["_max"])
		var size:=high-low
		row["bounds"]={"min":row["_min"].duplicate(),"size":[size.x,size.y,size.z]}
		if row["camera_refs"].is_empty(): row["camera_refs"]=[{"eye":[(low.x+high.x)*.5,low.y+1.65,high.z+1.2],"look":[(low.x+high.x)*.5,(low.y+high.y)*.5,(low.z+high.z)*.5]}]
	row.erase("_min")
	row.erase("_max")
	var qualities: Dictionary={}
	for material: Dictionary in row["materials"]: qualities[material["quality"]]=true
	row["capture_quality"]="mixed" if qualities.has("retro") and qualities.size()>1 else "retro" if qualities.has("retro") else "hq" if qualities.has("hq") else "standard-pbr" if qualities.has("standard-pbr") else "custom"


static func _room_at(at: Vector3) -> String:
	var rooms: Dictionary=GameData.site()["ROOMS"]
	for id: String in rooms:
		var room: Dictionary=rooms[id]
		if room.get("zone","") in ["outdoor","greenhouse"] or float(room.get("h",0))<=0: continue
		var x: Array=room["x"]
		var z: Array=room["z"]
		var y:=float(room.get("y",0))
		if at.x>=float(x[0]) and at.x<=float(x[1]) and at.z>=float(z[0]) and at.z<=float(z[1]) and at.y>=y-.15 and at.y<=y+float(room["h"]): return id
	return ""


static func _camera_refs(row: Dictionary,views: Array) -> void:
	var aliases: Array=row.get("source_owners",[]).duplicate()
	var owner:=String(row["owner"])
	if row["kind"]=="car": aliases.append("snt-car-"+owner.get_slice("/",2))
	elif owner=="retained/public/shower": aliases.append("summer-shower")
	elif owner=="retained/public/mill": aliases.append("old-windmill")
	elif owner=="retained/public/cemetery": aliases.append("cemetery")
	elif String(row["detail_variant"]).begins_with("farm-"): aliases.append(row["detail_variant"])
	if row.has("room"): aliases.append(row["room"])
	var candidates: Array[Dictionary]=[]
	for view: Dictionary in views:
		if aliases.has(view.get("owner",view["id"])): candidates.append(view)
	if candidates.is_empty(): return
	if candidates.size()>1 and not row["bounds"]["min"].is_empty():
		var centre:=GameData.vec3(row["bounds"]["min"])+GameData.vec3(row["bounds"]["size"])*.5
		var closest: Dictionary=candidates[0]
		for view: Dictionary in candidates:
			if GameData.vec3(view["target"]).distance_squared_to(centre)<GameData.vec3(closest["target"]).distance_squared_to(centre): closest=view
		candidates=[closest]
	row["camera_refs"]=[]
	for view: Dictionary in candidates:
		row["camera_refs"].append({"source":"res://data/environment_views.json","id":view["id"],"eye":view["at"],"look":view["target"],"view":view["view"]})


static func _transform(world: Node3D,node: Node3D) -> Transform3D:
	var result:=node.transform
	var parent:=node.get_parent()
	while parent!=null and parent!=world:
		if parent is Node3D: result=(parent as Node3D).transform*result
		parent=parent.get_parent()
	return result


static func _nodes(node: Node) -> Array[Node]:
	var out: Array[Node]=[node]
	for child: Node in node.get_children(): out.append_array(_nodes(child))
	return out

## Отделка уже существующих поверхностей. Проёмы и сюжетный реквизит живут у мира.
class_name EnvironmentInteriors
extends RefCounted

const SELECT := preload("res://src/skin_layer.gd")
const WALL_KEYS := ["siding", "siding-ochre", "siding-red-old", "siding-grey-old",
	"plank", "boards", "whitewash", "shedwood", "concrete", "brick"]
const PROFILES := {
	"veranda": ["shedwood", "boards", 0xc9bda3],
	"kitchen": ["whitewash", "linoleum", 0xe3dac6],
	"hall": ["plank", "boards", 0xd1c8b1],
	"wash": ["whitewash", "ceramic", 0xd9d4c5],
	"aunt": ["plank", "boards", 0xdcccb5],
	"living": ["plank", "boards", 0xcdcbb9],
	"landing": ["shedwood", "boards", 0xbcb09a],
	"vitya": ["plank", "boards", 0xc8c9b4],
	"storage": ["shedwood", "boards", 0xb8ad97],
	"tonya": ["plank", "boards", 0xd8cbbd],
	"roofspace": ["shedwood", "boards", 0xb8aa90],
	"cellar": ["concrete", "dirt", 0xc0bcb0],
	"shed": ["shedwood", "concrete", 0xc0ae91],
	"privy": ["shedwood", "boards", 0xc4b396],
	"arkady": ["plank", "boards", 0xd8c3a1],
	"redhouse": ["whitewash", "boards", 0xe1d8c6],
	"redhouse-up": ["plank", "boards", 0xd2c7b6],
	"boarded": ["shedwood", "boards", 0xb5a78d],
}
const ROUGHNESS := {"ceramic": .52, "linoleum": .66, "boards": .80, "plank": .92,
	"whitewash": .93, "shedwood": .86, "concrete": .94, "dirt": .97}


static func apply(world: Node3D, mats: Materials, _built: Dictionary) -> Dictionary:
	if world.has_meta("environment_interiors"):
		return world.get_meta("environment_interiors")
	var report := {"active": true, "rooms": [], "moved_triangles": 0,
		"replacement_triangles": 0, "decor_triangles": 0, "nodes": 0, "errors": [],
		"moved_area": 0.0, "replacement_area": 0.0, "retained_area": 0.0,
		"texture_origin": "Existing ProceduralAssets textures; ceramic is original deterministic Image code",
		"visual_verified": false, "physics_mutations": 0}
	if OS.get_cmdline_user_args().has("--environment=off"):
		report["active"] = false
		return report
	var rooms := _rooms()
	var materials: Dictionary = {}
	var groups: Dictionary = {}
	for node: Node in SELECT._nodes(world):
		if not node is MeshInstance3D or not node.has_meta("skin_parts"):
			continue
		var source := node as MeshInstance3D
		if source.mesh == null or source.mesh.get_surface_count() != 1:
			continue
		var key := _material_key(source.get_active_material(0), mats)
		if not key in WALL_KEYS and key not in ["dark", "trim", "linoleum", "tile", "dirt"]:
			continue
		_move_faces(world, source, key, rooms, mats, materials, groups, report)
	_baseboards(rooms, mats, materials, groups, report)
	for token: String in groups:
		var group: Dictionary = groups[token]
		var st: SurfaceTool = group["tool"]
		var mesh := st.commit()
		if mesh == null:
			continue
		var instance := MeshInstance3D.new()
		instance.name = "environment-interior-" + token.replace(":", "-")
		instance.mesh = mesh
		instance.material_override = group["material"]
		instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		instance.visibility_range_end = 58.0
		instance.set_meta("environment_interior", group["room"])
		instance.set_meta("environment_interior_role", group["role"])
		world.add_child(instance)
		report["nodes"] += 1
	for room: Dictionary in rooms:
		var id: String = room["id"]
		var components: Array = []
		var count := 0
		for group: Dictionary in groups.values():
			if group["room"] == id:
				components.append(group["role"])
				count += int(group["triangles"])
		var view := _view(room)
		report["rooms"].append({"id": id, "wall": PROFILES[id][0], "floor": PROFILES[id][1],
			"components": components, "triangles": count, "bounds": room["box"],
			"view": view, "retained": "doors, windows, glass, lights, props, story traces",
			"note": room.get("note", ""),
			"status": "prepared" if count > 0 else "existing surfaces retained"})
	world.set_meta("environment_interiors", report)
	return report


static func _rooms() -> Array:
	var rooms: Array = []
	var data: Dictionary = GameData.site()["ROOMS"]
	for id: String in PROFILES:
		if not data.has(id):
			continue
		var r: Dictionary = data[id]
		var floor_y := .12 if id == "shed" else (.10 if id == "privy" else float(r["y"]))
		rooms.append({"id": id, "box": [r["x"][0],r["x"][1],r["z"][0],r["z"][1]],
			"floor": floor_y, "height": float(r["h"]), "owners": ["buildings/site/"], "wall": 0.0})
	# Эта комната уже построена HomeWorld за w-sealed; нового помещения здесь нет.
	rooms.append({"id": "tonya", "box": [-1.8,2.2,13.8,16.2], "floor": 3.3,
		"height": 2.35, "owners": ["buildings/site/"], "wall": 0.0})
	var village: Dictionary = VillageWorld.data()
	for id: String in ["redhouse", "boarded"]:
		var r: Dictionary = village.get(id.to_upper(), {})
		if r.is_empty():
			continue
		var box: Array = [r["x"][0],r["x"][1],r["z"][0],r["z"][1]]
		rooms.append({"id": id, "box": box, "floor": float(r["floor"]),
			"height": float(r["ceil"][0])-float(r["floor"]), "wall": float(r["wall"]),
			"owners": ["buildings/village/"+id.to_upper()],
			"note": "Existing metal stove, boarded door and traces retained" if id == "boarded" else "Existing fridge, drawing and stair opening retained"})
		if r.has("floor2"):
			rooms.append({"id": "redhouse-up", "box": box, "floor": float(r["floor2"]),
				"height": float(r["eave2"])-float(r["floor2"]), "wall": float(r["wall"]),
				"owners": ["buildings/village/REDHOUSE"]})
	# У Аркадия построены сени перед глухой частью дома, а не ещё один жилой зал.
	rooms.append({"id": "arkady", "box": [15.0,18.5,-8.2,-7.0], "floor": 0.0,
		"height": 2.45, "wall": .18, "owners": [],
		"note": "Existing vestibule furniture uses natural boards; no independent inner wall or floor surfaces to replace"})
	return rooms


static func _material_key(material: Material, mats: Materials) -> String:
	for key: String in mats.map:
		if mats.map[key] == material:
			return key
	return ""


static func _material(mats: Materials, key: String, tint: int, cache: Dictionary) -> Material:
	var token := "%s-%d" % [key,tint]
	if cache.has(token):
		return cache[token]
	var source: Material = mats.get_mat("tile" if key == "ceramic" else key)
	var material := source.duplicate() as ShaderMaterial
	if material == null:
		return source
	var params: Dictionary = material.get_meta("skin_hq_params", {}).duplicate()
	params["albedo"] = GameData.color(tint)
	params["roughness_value"] = float(ROUGHNESS.get(key,.88))
	if key == "ceramic":
		if not cache.has("ceramic-texture"):
			cache["ceramic-texture"] = _ceramic_texture()
		params["albedo_tex"] = cache["ceramic-texture"]
		params["use_normal"] = false
		params["use_roughness"] = false
		params["use_ao"] = false
	material.set_meta("skin_hq_params", params)
	for field: String in params:
		material.set_shader_parameter(field,params[field])
	cache[token] = material
	return material


static func _ceramic_texture() -> ImageTexture:
	var image := Image.create(128,128,false,Image.FORMAT_RGB8)
	for y in 128:
		for x in 128:
			var seam := x % 8 == 0 or y % 8 == 0
			var tile := Vector2i(x/8,y/8)
			var wear := float(posmod(tile.x*17+tile.y*29,9))*0.004
			image.set_pixel(x,y,Color(0.50,0.48,0.43) if seam else Color(0.88-wear,0.85-wear,0.78-wear))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


static func _owner_allowed(owner: String, room: Dictionary) -> bool:
	for prefix: String in room["owners"]:
		if owner.begins_with(prefix):
			if prefix == "buildings/site/":
				return owner.begins_with("buildings/site/w-") or owner.contains("SLABS-") \
					or owner.begins_with("buildings/site/shed-") or owner.begins_with("buildings/site/privy-") \
					or owner == "buildings/site/HOUSE-shell"
			return true
	return false


static func _role(room: Dictionary, owner: String, p: Vector3, n: Vector3, key: String) -> String:
	if not _owner_allowed(owner,room):
		return ""
	var floor_y: float = room["floor"]
	if n.y > 0.85 and absf(p.y-floor_y) < 0.035:
		return "floor"
	if absf(n.y) > 0.1 or not key in WALL_KEYS + ["dark", "trim"]:
		return ""
	if p.y < floor_y+.10 or p.y > floor_y+float(room["height"])+.02:
		return ""
	var q := p+n*.075
	var b: Array = room["box"]
	if q.x <= b[0]+.005 or q.x >= b[1]-.005 or q.z <= b[2]+.005 or q.z >= b[3]-.005:
		return ""
	if owner == "buildings/site/HOUSE-shell":
		var edge := minf(minf(absf(p.x-float(b[0])),absf(p.x-float(b[1]))),
			minf(absf(p.z-float(b[2])),absf(p.z-float(b[3]))))
		if edge > .095: return ""
	if float(room["wall"]) > 0.0:
		var t: float = room["wall"]
		var near := minf(minf(absf(p.x-(float(b[0])+t)),absf(p.x-(float(b[1])-t))),
			minf(absf(p.z-(float(b[2])+t)),absf(p.z-(float(b[3])-t))))
		if near > .045:
			return ""
	return "frame" if key in ["dark", "trim"] else "wall"


# Полигон сохраняет мировую позицию и интерполированный исходный UV.
static func _clip(poly: Array, axis: int, line: float, inside_positive: bool) -> Array:
	var out: Array = []
	if poly.is_empty():
		return out
	var a: Dictionary = poly[-1]
	var da: float = a["p"][axis]-line
	var ain := da >= 0.0 if inside_positive else da <= 0.0
	for b: Dictionary in poly:
		var db: float = b["p"][axis]-line
		var bin := db >= 0.0 if inside_positive else db <= 0.0
		if ain != bin:
			var t := da/(da-db)
			var point := {"p": (a["p"] as Vector3).lerp(b["p"],t), "uv": (a["uv"] as Vector2).lerp(b["uv"],t)}
			if a.has("uv2"): point["uv2"] = (a["uv2"] as Vector2).lerp(b["uv2"],t)
			if a.has("color"): point["color"] = (a["color"] as Color).lerp(b["color"],t)
			if a.has("tangent"):
				var ta: Plane = a["tangent"]
				var tb: Plane = b["tangent"]
				point["tangent"] = Plane(ta.normal.lerp(tb.normal,t).normalized(),ta.d)
			out.append(point)
		if bin:
			out.append(b)
		a = b
		da = db
		ain = bin
	return out


static func _cut(poly: Array, room: Dictionary) -> Dictionary:
	var b: Array = room["box"]
	var planes := [[0,b[0],true],[0,b[1],false],[2,b[2],true],[2,b[3],false],
		[1,float(room["floor"])-.04,true],[1,float(room["floor"])+float(room["height"])+.02,false]]
	var inside: Array = poly
	var outside: Array = []
	for plane: Array in planes:
		var low := INF
		var high := -INF
		for point: Dictionary in inside:
			var distance: float = point["p"][int(plane[0])]-float(plane[1])
			if not bool(plane[2]): distance = -distance
			low = minf(low,distance)
			high = maxf(high,distance)
		# Грань на плоскости принадлежит комнате один раз.
		if low >= -.000001:
			continue
		if high <= -.000001:
			outside.append(inside)
			inside = []
			break
		var off := _clip(inside,int(plane[0]),float(plane[1]),not bool(plane[2]))
		if _area(off) > .0000001:
			outside.append(off)
		inside = _clip(inside,int(plane[0]),float(plane[1]),bool(plane[2]))
		if inside.size() < 3:
			break
	return {"inside": inside, "outside": outside}


static func _area(poly: Array) -> float:
	var area := 0.0
	for i in range(1,poly.size()-1):
		area += ((poly[i]["p"] as Vector3)-(poly[0]["p"] as Vector3)).cross(
			(poly[i+1]["p"] as Vector3)-(poly[0]["p"] as Vector3)).length()*.5
	return area


static func _add(groups: Dictionary, token: String, room: String, role: String, material: Material,
		poly: Array, normal: Vector3) -> int:
	if _area(poly) < .0000001:
		return 0
	if not groups.has(token):
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		st.set_material(material)
		groups[token] = {"tool": st, "material": material, "room": room, "role": role, "triangles": 0}
	var group: Dictionary = groups[token]
	var st: SurfaceTool = group["tool"]
	var count := 0
	for i in range(1,poly.size()-1):
		if _area([poly[0],poly[i],poly[i+1]]) < .0000001:
			continue
		for point: Dictionary in [poly[0],poly[i],poly[i+1]]:
			st.set_normal(normal)
			st.set_uv(point["uv"])
			if point.has("uv2"): st.set_uv2(point["uv2"])
			if point.has("color"): st.set_color(point["color"])
			if point.has("tangent"): st.set_tangent(point["tangent"])
			st.add_vertex(point["p"])
		count += 1
	group["triangles"] += count
	return count


static func _move_faces(world: Node3D, source: MeshInstance3D, key: String, rooms: Array,
		mats: Materials, cache: Dictionary, groups: Dictionary, report: Dictionary) -> void:
	var arrays := source.mesh.surface_get_arrays(0)
	if arrays[Mesh.ARRAY_INDEX] != null and not arrays[Mesh.ARRAY_INDEX].is_empty():
		return
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var uvs: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
	if norms.size() != verts.size() or uvs.size() != verts.size():
		report["errors"].append("Unsupported source arrays: "+String(source.name))
		return
	var hidden: Dictionary = source.get_meta("environment_hidden_vertices", {}).duplicate()
	var before := hidden.size()
	var transform := PropsSkin._rel(world,source)
	var parts: Dictionary = source.get_meta("skin_parts")
	for owner: String in parts:
		var matching_rooms: Array = []
		for room: Dictionary in rooms:
			if _owner_allowed(owner,room): matching_rooms.append(room)
		if matching_rooms.is_empty(): continue
		for span: Vector2i in parts[owner]:
			for offset in range(span.x,span.x+span.y,3):
				if hidden.has(offset):
					continue
				var normal := (transform.basis*norms[offset]).normalized()
				var poly: Array = []
				for i in 3:
					var point := {"p": transform*verts[offset+i], "uv": uvs[offset+i]}
					var index: int = offset+i
					var uv2: Variant = arrays[Mesh.ARRAY_TEX_UV2]
					var colors: Variant = arrays[Mesh.ARRAY_COLOR]
					var tangents: Variant = arrays[Mesh.ARRAY_TANGENT]
					if uv2 != null and uv2.size() == verts.size(): point["uv2"] = uv2[index]
					if colors != null and colors.size() == verts.size(): point["color"] = colors[index]
					if tangents != null and tangents.size() == verts.size()*4:
						var tangent := (transform.basis*Vector3(tangents[index*4],tangents[index*4+1],tangents[index*4+2])).normalized()
						point["tangent"] = Plane(tangent,tangents[index*4+3])
					poly.append(point)
				var remaining: Array = [poly]
				var changed := false
				for room: Dictionary in matching_rooms:
					var rest: Array = []
					for piece: Array in remaining:
						var cut := _cut(piece,room)
						var patch: Array = cut["inside"]
						if _area(patch) < .0000001:
							rest.append(piece)
							continue
						var centre := Vector3.ZERO
						for point: Dictionary in patch:
							centre += point["p"]
						centre /= patch.size()
						var role := _role(room,owner,centre,normal,key)
						if role.is_empty():
							rest.append(piece)
							continue
						var id: String = room["id"]
						var material_key: String = PROFILES[id][1] if role == "floor" else PROFILES[id][0]
						if role == "frame": material_key = "boards"
						var tint := 0xffffff if role == "floor" else int(PROFILES[id][2])
						var material := _material(mats,material_key,tint,cache)
						report["replacement_triangles"] += _add(groups,id+":"+role,id,role,material,patch,normal)
						report["replacement_area"] += _area(patch)
						rest.append_array(cut["outside"])
						changed = true
					remaining = rest
				if not changed:
					continue
				for piece: Array in remaining:
					_add(groups,"retained:"+str(source.get_instance_id()),"retained","source remainder",source.get_active_material(0),piece,normal)
					report["retained_area"] += _area(piece)
				for i in 3:
					hidden[offset+i] = true
				report["moved_triangles"] += 1
				report["moved_area"] += _area(poly)
	if hidden.size() == before:
		return
	var keep := PackedInt32Array()
	for index in verts.size():
		if not hidden.has(index):
			keep.append(index)
	var residual: MeshInstance3D = source.get_meta("environment_residual") if source.has_meta("environment_residual") else null
	if residual == null:
		residual = MeshInstance3D.new()
		residual.name = "environment-residual"
		residual.material_override = source.material_override
		residual.cast_shadow = source.cast_shadow
		residual.visibility_range_end = source.visibility_range_end
		residual.visibility_range_end_margin = source.visibility_range_end_margin
		residual.layers = source.layers
		source.add_child(residual)
		source.set_meta("environment_residual",residual)
	residual.mesh = SELECT._select_vertices(source.mesh,keep) if not keep.is_empty() else null
	source.set_meta("environment_hidden_vertices",hidden)
	if not source.has_meta("environment_original_layers"):
		source.set_meta("environment_original_layers",source.layers)
	source.layers = 0


static func _baseboards(rooms: Array, mats: Materials, cache: Dictionary, groups: Dictionary, report: Dictionary) -> void:
	for wall: Dictionary in GameData.site()["WALLS"]:
		var a: Array = wall["a"]
		var b: Array = wall["b"]
		var axis := 2 if a[1] == b[1] else 0
		var along := 0 if axis == 2 else 2
		var lo := minf(float(a[0] if along == 0 else a[1]),float(b[0] if along == 0 else b[1]))
		var hi := maxf(float(a[0] if along == 0 else a[1]),float(b[0] if along == 0 else b[1]))
		var spans: Array = [[lo,hi]]
		for hole: Dictionary in wall.get("holes", []):
			if float(hole.get("y0",0)) > .01:
				continue
			var centre := float(hole["x"] if along == 0 else hole["z"])
			var width := float(hole["w"])+.06
			var next: Array = []
			for span: Array in spans:
				if centre-width/2 > span[0]:next.append([span[0],minf(span[1],centre-width/2)])
				if centre+width/2 < span[1]:next.append([maxf(span[0],centre+width/2),span[1]])
			spans = next
		for sign_side: float in [-1.0,1.0]:
			var normal := Vector3.ZERO
			normal[axis] = sign_side
			var line := float(a[1] if axis == 2 else a[0])+sign_side*(float(wall["t"])/2+.003)
			var y := float(wall["y"])+.025
			for span: Array in spans:
				if float(span[1])-float(span[0]) < .02:
					continue
				var points: Array = []
				for corner: Vector2 in [Vector2(span[0],y),Vector2(span[1],y),Vector2(span[1],y+.06),Vector2(span[0],y+.06)]:
					var p := Vector3(line,corner.y,corner.x) if axis == 0 else Vector3(corner.x,corner.y,line)
					points.append({"p": p, "uv": Vector2(corner.x/1.6,corner.y/1.6)})
				if (axis == 0 and sign_side > 0) or (axis == 2 and sign_side < 0):points.reverse()
				for room: Dictionary in rooms:
					var patch: Array = _cut(points,room)["inside"]
					if _area(patch) < .0000001:continue
					var p := Vector3.ZERO
					for point: Dictionary in patch: p += point["p"]
					p = p/patch.size()+normal*.025
					var rb: Array = room["box"]
					if absf(float(room["floor"])-float(wall["y"])) > .03 or p.x <= rb[0] or p.x >= rb[1] or p.z <= rb[2] or p.z >= rb[3]:continue
					var id: String = room["id"]
					report["decor_triangles"] += _add(groups,id+":baseboard",id,"baseboard",_material(mats,"boards",0xc6b496,cache),patch,normal)


static func _view(room: Dictionary) -> Dictionary:
	var b: Array = room["box"]
	return {"eye": [(float(b[0])+float(b[1]))/2,float(room["floor"])+1.62,(float(b[2])+float(b[3]))/2],
		"target": [float(b[0])+.2,float(room["floor"])+1.2,float(b[2])+.25], "modes": ["neutral","game","night"]}

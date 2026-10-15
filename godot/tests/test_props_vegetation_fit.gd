## Real flat patch replacements retain their source footprint and collision cache.
extends SceneTree

var errors: Array[String] = []
var checks := 0

func _initialize() -> void:
	var definitions: Array = []
	for definition: Dictionary in GameData.props().get("PROPS",[]):
		if String(definition.get("m","")) in ["patch-grass","grass","grass-large"]:
			definitions.append(definition)
	var props := Props.new(Materials.new().load_all()).load_models(definitions)
	var collisions_before := var_to_str(props.colliders)
	var cache_before: Dictionary = {}
	for key: String in props._cache:
		cache_before[key] = {"scene":props._cache[key]["scene"],
			"elems":var_to_str(props._cache[key]["elems"])}
	var baked := ProceduralAssets.fetch("scatter/nat-grass")
	var baked_before := _mesh_signature(baked["meshes"])
	var flat_count := 0
	var regular_count := 0
	for definition: Dictionary in definitions:
		var name := String(definition["m"])
		_check(props._cache.has(name),"missing source model "+name)
		if not props._cache.has(name): continue
		var entry: Dictionary = props._cache[name]
		var source := (entry["scene"] as Node3D).duplicate() as Node3D
		var scale_value := float(entry["scale"]) * float(definition.get("s",1.0))
		source.scale = Vector3.ONE * scale_value
		source.position.y = -props._elems_min_y(entry["elems"],float(entry["scale"])) * float(definition.get("s",1.0))
		var source_box: AABB = source.transform * PropsSkin.local_aabb(source)
		source.free()
		var owner := props.spawn(definition)
		_check(owner != null,"cannot spawn "+name)
		if owner == null: continue
		var at: Array = definition["at"]
		_check(owner.position.is_equal_approx(Vector3(float(at[0]),float(at[1]),float(at[2]))),"holder anchor moved "+name)
		var box := PropsSkin.local_aabb(owner)
		_check(absf(box.position.y-source_box.position.y)<0.0001,"ground support moved "+name)
		if source_box.size.y<=0.01:
			flat_count += 1
			_check(box.size.y>=0.12 and box.size.y<=0.3801,"flat patch still microscopic or too tall")
			_check(absf(box.size.x-source_box.size.x)<0.0001 and absf(box.size.z-source_box.size.z)<0.0001,"flat patch footprint changed")
			_check(absf(box.get_center().x-source_box.get_center().x)<0.0001 and absf(box.get_center().z-source_box.get_center().z)<0.0001,"flat patch horizontal anchor moved")
			var meshes := props._all_meshes(owner)
			_check(meshes.size()==1 and meshes[0].mesh==baked["meshes"][0],"flat patch geometry resource was regenerated")
		else:
			regular_count += 1
			_check(absf(box.size.y-source_box.size.y)<0.0001,"regular grass height changed")
		for mesh: MeshInstance3D in props._all_meshes(owner):
			_check(mesh.cast_shadow==GeometryInstance3D.SHADOW_CASTING_SETTING_OFF,"grass started casting shadows")
			_check(mesh.visibility_range_end==Props.VIS_END,"grass range changed")
		owner.free()
	_check(flat_count==2 and regular_count==4,"expected two real flat patches and four regular grass models")
	_check(var_to_str(props.colliders)==collisions_before,"visual fit introduced or changed collision")
	_check(_mesh_signature(baked["meshes"])==baked_before,"shared baked mesh arrays or material identity changed")
	for key: String in cache_before:
		_check(props._cache[key]["scene"]==cache_before[key]["scene"],"original collision model was replaced "+key)
		_check(var_to_str(props._cache[key]["elems"])==cache_before[key]["elems"],"original collision elements changed "+key)
	props.dispose()
	for message: String in errors: printerr(message)
	print("test_props_vegetation_fit: ","PASS" if errors.is_empty() else "FAIL",
		" checks=",checks," flat=",flat_count," regular=",regular_count)
	quit(0 if errors.is_empty() else 1)

func _mesh_signature(meshes: Array) -> String:
	var signature := ""
	for mesh: ArrayMesh in meshes:
		for surface in mesh.get_surface_count():
			signature += var_to_str(mesh.surface_get_arrays(surface))
			signature += str(mesh.surface_get_material(surface).get_instance_id())
	return signature.sha256_text()

func _check(ok: bool,message: String) -> void:
	checks += 1
	if not ok: errors.append(message)

# Geometry contract: deterministic meshes, original bounds, owner visibility,
# and wheel animation without moving collision or the vehicle anchor.
extends SceneTree

const Geo = preload("res://src/object_geometry.gd")
var errors: Array[String] = []


func _initialize() -> void:
	for key: String in Geo.SUPPORTED:
		_check(not ProceduralAssets.fetch(key).is_empty(), key + " missing baked asset")
		var first := Geo.generate(key)
		var second := Geo.generate(key)
		var a: ArrayMesh = first["meshes"][0]
		var b: ArrayMesh = second["meshes"][0]
		_check(a.get_surface_count() == b.get_surface_count(), key + " surface count")
		_check(a.get_faces().size() > 0, key + " empty mesh")
		_check(a.get_faces() == b.get_faces(), key + " nondeterministic vertices")
		_check(first["bounds"] == a.get_aabb(), key + " bounds metadata")
		for surface in a.get_surface_count():
			var data := a.surface_get_arrays(surface)
			var vertices: PackedVector3Array = data[Mesh.ARRAY_VERTEX]
			var normals: PackedVector3Array = data[Mesh.ARRAY_NORMAL]
			_check(vertices.size() == normals.size(), key + " missing normals")
			for t in range(0, vertices.size(), 3):
				var cross := (vertices[t + 1] - vertices[t]).cross(vertices[t + 2] - vertices[t])
				_check(cross.length_squared() > 1e-14 and cross.dot(normals[t]) < -1e-10,
					key + " reversed or degenerate face " + str(t))
	var hand: ArrayMesh = Geo.generate("object/hand")["meshes"][0]
	_check(hand.get_aabb().size.y <= Actors.HAND + 0.0001, "hand exceeds original length")
	_check(hand.get_aabb().size.x <= 0.082, "hand exceeds original diameter")
	var boot: ArrayMesh = Geo.generate("object/boot")["meshes"][0]
	_check(boot.get_aabb().position.y >= -0.0401 and boot.get_aabb().end.y <= 0.0301,
		"boot changed ankle ground clearance")
	var box := Geo.bevel_box(Vector3(1.2, 0.8, 0.6), 0.02)
	_check(box.get_aabb().size.is_equal_approx(Vector3(1.2, 0.8, 0.6)), "bevel changed prop extents")
	_check(box == Geo.bevel_box(Vector3(1.2, 0.8, 0.6), 0.02), "simple mesh cache missed")

	var mats := Materials.new().load_all()
	var props := Props.new(mats)
	# Unrelated GLBs can both call their material 'colormap'. Texture identity
	# must be part of the cache key, including generated in-memory textures.
	var converted: Array[ShaderMaterial] = []
	for color: Color in [Color.RED, Color.GREEN]:
		var fixture := MeshInstance3D.new()
		var source := StandardMaterial3D.new()
		source.resource_name = "colormap"
		var texture_image := Image.create(2, 2, false, Image.FORMAT_RGBA8)
		texture_image.fill(color)
		var texture := ImageTexture.create_from_image(texture_image)
		source.albedo_texture = texture
		var primitive := BoxMesh.new()
		primitive.material = source
		fixture.mesh = primitive
		props._prepare(fixture, "fixture")
		var result := fixture.get_active_material(0) as ShaderMaterial
		_check(result.get_shader_parameter("albedo_tex") == texture, "GLB colormap cache substituted another texture")
		converted.append(result)
		fixture.free()
	_check(converted[0] != converted[1], "unrelated GLB colormaps share cached material")
	var def := {"id": "car", "make": "zhiguli", "at": [0.0, 0.0, 0.0]}
	var car := props.spawn(def)
	_check(car != null and props.get_prop("car") == car, "car owner/id changed")
	var collision := props.colliders.duplicate(true)
	var rest := car.transform
	var wheels: Array[Transform3D] = []
	for i in 4:
		var wheel := car.get_node_or_null("wheel-%d" % i) as Node3D
		_check(wheel != null, "missing independent wheel " + str(i))
		if wheel != null:
			wheels.append(wheel.transform)
	for name: String in ["door-left-0", "door-left-1", "door-right-0", "door-right-1", "hood", "trunk-lid"]:
		var hinge := car.get_node_or_null(name) as Node3D
		_check(hinge != null and hinge.get_child_count() == 1, "missing vehicle hinge " + name)
		if hinge != null:
			var before := hinge.position
			hinge.rotate_y(0.2)
			_check(hinge.position == before, "vehicle hinge shifted anchor " + name)
			hinge.rotation = Vector3.ZERO
	props.update_car_wheels(car, 0.48)
	_check(car.transform.is_equal_approx(rest), "wheel roll moved car anchor")
	_check(props.colliders == collision, "wheel roll changed collision")
	for i in wheels.size():
		var wheel := car.get_node("wheel-%d" % i) as Node3D
		_check(wheel.position.is_equal_approx(wheels[i].origin), "wheel pivot moved")
		_check(not wheel.basis.is_equal_approx(wheels[i].basis), "wheel did not roll")
		_check(wheel.basis.y.is_equal_approx(wheels[i].basis.y), "wheel axle tilted")
	props.update_car_wheels(car, 0.0)
	for i in wheels.size():
		_check((car.get_node("wheel-%d" % i) as Node3D).transform.is_equal_approx(wheels[i]), "wheel cleanup not restored")
	# Named animated/emissive surfaces must survive material batching.
	for row: Array in [["tvHorizon", "screen"], ["tvYunost", "screen"], ["vm12", "led"], ["wallClock", "pendulum"]]:
		var owner := props.spawn({"id": "fixture-" + row[0], "make": row[0], "at": [2.0, 0.0, 0.0]})
		var part := owner.get_node_or_null(row[1]) as MeshInstance3D
		_check(part != null, "batching destroyed " + row[0] + "/" + row[1])
		if part != null:
			_check(part.has_meta("independent_visual"), "named part merged into static geometry")
			var replacement := StandardMaterial3D.new()
			part.material_override = replacement
			for other: Node in owner.get_children():
				if other is MeshInstance3D and other != part:
					_check((other as MeshInstance3D).material_override != replacement, "screen/led override leaked into housing")
		owner.free()
	# Story photos retain their independent QuadMesh canvas. The second visit
	# changes all three images while frames, transforms and collision stay put.
	var photo_owners: Array[Node3D] = []
	var photo_transforms: Array[Transform3D] = []
	var photo_frames: Array[Material] = []
	var photo_collision := props.colliders.duplicate(true)
	for definition: Dictionary in Photos.extra_props():
		var photo := props.spawn(definition)
		photo_owners.append(photo)
		photo_transforms.append(photo.transform)
		var canvas := Photos._canvas(photo)
		_check(canvas != null, "photo canvas lost its QuadMesh type")
		for child: Node in photo.get_children():
			if child is MeshInstance3D and child != canvas:
				photo_frames.append((child as MeshInstance3D).material_override)
	_check(Photos.shuffle(props, mats) == 3, "Photos.shuffle must update all three story photos")
	for i in photo_owners.size():
		var photo := photo_owners[i]
		var canvas := Photos._canvas(photo)
		_check(photo.transform.is_equal_approx(photo_transforms[i]), "photo shuffle moved frame")
		if canvas != null:
			var expected_pic := String(Photos.FRAMES[(i + 1) % Photos.FRAMES.size()]["pic"])
			_check(canvas.material_override == mats.picture(expected_pic), "photo shuffle assigned wrong image")
		for child: Node in photo.get_children():
			if child is MeshInstance3D and child != canvas:
				_check(photo_frames.has((child as MeshInstance3D).material_override), "photo shuffle repainted frame")
		photo.free()
	_check(props.colliders == photo_collision, "photo shuffle changed collision")
	# Every active procedural family still builds under its original id.
	var seen: Dictionary = {}
	var data := GameData.props()
	var defs: Array = data["PROPS"].duplicate()
	defs.append_array(data.get("DYNAMIC_PROPS", []))
	for definition: Dictionary in defs:
		if not definition.has("make") or seen.has(definition["make"]):
			continue
		seen[definition["make"]] = true
		var owner := props.spawn(definition)
		_check(owner != null, "missing family " + String(definition["make"]))
		if owner != null:
			if definition.has("id"):
				_check(props.get_prop(String(definition["id"])) == owner, "prop id changed")
			_check(not owner is CollisionObject3D, "decor created physics")
			owner.free()
	print("active procedural families: ", seen.size())
	car.free()
	props.dispose()
	if errors.is_empty():
		print("test_object_geometry: PASS (5 generators, winding, cache, bounds, car owner/collision/wheel pivots)")
	else:
		for message in errors:
			printerr(message)
		print("test_object_geometry: FAIL ", errors.size())
	quit(0 if errors.is_empty() else 1)


func _check(ok: bool, message: String) -> void:
	if not ok:
		errors.append(message)

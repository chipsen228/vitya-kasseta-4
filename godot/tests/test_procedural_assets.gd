extends SceneTree

const Assets = preload("res://src/procedural_assets.gd")

func _initialize() -> void:
	var errors: Array[String] = []
	var asset_count := 0
	for spec: Dictionary in Assets.catalog():
		var key := String(spec["key"])
		var baked := Assets.fetch(key, spec["params"])
		if baked.is_empty():
			errors.append("missing baked " + key)
			continue
		asset_count += 1
		var total := 0
		var lod_total := 0
		for mesh: ArrayMesh in baked.get("meshes", []):
			total += Assets.triangles(mesh)
			for surface in mesh.get_surface_count():
				var arrays := mesh.surface_get_arrays(surface)
				var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
				for vertex: Vector3 in vertices:
					if not vertex.is_finite():
						errors.append("non-finite geometry " + key)
						break
				if not key.begins_with("object/") and mesh.surface_get_material(surface) == null:
					errors.append("missing common-light material " + key)
		for mesh: ArrayMesh in baked.get("lod_meshes", []):
			lod_total += Assets.triangles(mesh)
		if total <= 0:
			errors.append("empty baked " + key)
		if lod_total > total:
			errors.append("LOD costs more than near geometry " + key)
		if key.begins_with("scatter/"):
			var budget := int(Assets.SCATTER_BUDGETS[key.trim_prefix("scatter/")])
			if total > budget:
				errors.append("original triangle budget exceeded " + key)
		var bounds: AABB = baked.get("bounds", AABB())
		if bounds.size.length() <= 0:
			errors.append("missing bounds " + key)
		if not (baked.get("anchors", {}) as Dictionary).has("root"):
			errors.append("missing root anchor " + key)
		var again := Assets.fetch(key, spec["params"])
		if (again["meshes"] as Array)[0] != (baked["meshes"] as Array)[0]:
			errors.append("resource not shared " + key)
	_check_determinism(errors)
	for family: String in Assets.TEXTURES:
		var texture := load(Assets.texture_path(family)) as Texture2D
		if texture == null or not texture.get_image().has_mipmaps():
			errors.append("texture lacks mipmaps " + family)
	for family: String in Assets.NORMAL_TEXTURES:
		var texture := load(Assets.texture_path(family + "-normal")) as Texture2D
		if texture == null or not texture.get_image().has_mipmaps():
			errors.append("normal map lacks mipmaps " + family)
			continue
		var image := texture.get_image()
		for y in range(0, image.get_height(), 16):
			for x in range(0, image.get_width(), 16):
				var c := image.get_pixel(x, y)
				var n := Vector3(c.r, c.g, c.b) * 2.0 - Vector3.ONE
				if absf(n.length() - 1.0) > 0.015 or n.z < 0.80:
					errors.append("normal map has invalid direction " + family)
	_check_cookie(errors)
	if errors.is_empty():
		print("test_procedural_assets: PASS (%d baked assets, %d textures + 5 normals, isolated RNG, stable cache, triangle budgets)"
			% [asset_count, Assets.TEXTURES.size()])
		quit(0)
	else:
		for error: String in errors:
			printerr("FAIL test_procedural_assets: ", error)
		quit(1)


func _check_determinism(errors: Array[String]) -> void:
	if Assets.cache_id("forest/tree", {"a": 1, "b": 2}) != Assets.cache_id("forest/tree", {"b": 2, "a": 1}):
		errors.append("dictionary ordering changes cache identity")
	if Assets.cache_id("forest/tree", {}, 1) == Assets.cache_id("forest/tree", {}, 2):
		errors.append("seed is omitted from cache identity")
	seed(710)
	var expected := randf()
	seed(710)
	var first := Assets.generate("forest/tree", {"variant": 2}, 25)
	if randf() != expected:
		errors.append("generation advanced global/story RNG")
	var second := Assets.generate("forest/tree", {"variant": 2}, 25)
	for i in (first["meshes"] as Array).size():
		var a: ArrayMesh = first["meshes"][i]
		var b: ArrayMesh = second["meshes"][i]
		if a.get_surface_count() != b.get_surface_count():
			errors.append("surface count is nondeterministic")
			continue
		for surface in a.get_surface_count():
			if a.surface_get_arrays(surface) != b.surface_get_arrays(surface):
				errors.append("same seed produced different vertices/UV/indices")


func _check_cookie(errors: Array[String]) -> void:
	var texture := load(Assets.texture_path("flashlight-cookie")) as Texture2D
	var image := texture.get_image()
	var previous := 1.01
	for x in range(64, 128):
		var energy := image.get_pixel(x, 64).r
		if energy > previous + 0.005:
			errors.append("cookie has an increasing ring")
			break
		previous = energy
	if image.get_pixel(64, 64).r < 0.98 or image.get_pixel(127, 64).r > 0.01:
		errors.append("cookie center/edge energy is wrong")

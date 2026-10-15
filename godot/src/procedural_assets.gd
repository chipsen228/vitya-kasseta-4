## Local, deterministic asset bakery. Gameplay only calls fetch()/material().
## Missing disk resources are an error: expensive geometry is never rebuilt in play.
class_name ProceduralAssets
extends RefCounted

const VERSION := 1
const ROOT := "res://assets/generated/"
const SEED := 1988
const TEXTURES := ["wood", "boards", "brick", "concrete", "whitewash", "roof",
	"wallpaper", "linoleum", "bark", "birch", "leaf", "pine", "soil", "grass",
	"gravel", "rusted_metal", "hay", "flashlight-cookie", "fabric"]
const NORMAL_TEXTURES := ["wood", "boards", "brick", "roof", "concrete"]
const SCATTER_BUDGETS := {"nat-grass": 155, "nat-grass-tall": 326, "nat-fern": 288,
	"nat-plant-big": 112, "nat-bush": 900, "nat-pebble": 136, "nat-rock-a": 244,
	"nat-tree-a": 3505, "nat-pine-a": 3947, "nat-deadtree-a": 5702,
	"ok-stump": 56, "ok-haybale": 180, "ok-barrel-rust": 412, "ok-can": 156,
	"ok-logstack": 184, "ok-fence-broken": 320, "ok-fence-simple": 64,
	"ok-lily": 52, "ok-rocks": 364, "ok-pumpkin": 120, "nat-twisted": 9564}
static var _assets: Dictionary = {}
static var _materials: Dictionary = {}


static func cache_id(key: String, params: Dictionary = {}, seed_value: int = SEED) -> String:
	return ("%d|%s|%d|%s" % [VERSION, key, seed_value,
		var_to_str(_canonical(params))]).sha256_text().substr(0, 20)


static func _canonical(value: Variant) -> Variant:
	if value is Dictionary:
		var result: Dictionary = {}
		var keys: Array = value.keys()
		keys.sort()
		for key: Variant in keys:
			result[key] = _canonical(value[key])
		return result
	if value is Array:
		var result: Array = []
		for item: Variant in value:
			result.append(_canonical(item))
		return result
	return value


static func asset_path(key: String, params: Dictionary = {}, seed_value: int = SEED) -> String:
	return ROOT + key.replace("/", "-") + "-" + cache_id(key, params, seed_value) + ".res"


static func texture_path(family: String) -> String:
	return ROOT + "textures/" + family + ".res"


static func fetch(key: String, params: Dictionary = {}, seed_value: int = SEED) -> Dictionary:
	var path := asset_path(key, params, seed_value)
	if _assets.has(path):
		return _assets[path]
	if not ResourceLoader.exists(path):
		push_error("Procedural asset is not baked: " + path)
		return {}
	var resource := load(path) as Resource
	var result: Dictionary = resource.get_meta("asset", {})
	if int(result.get("version", -1)) != VERSION or result.get("key", "") != key:
		push_error("Procedural asset cache mismatch: " + path)
		return {}
	_assets[path] = result
	return result


static func material(family: String) -> Material:
	if not _materials.has(family):
		var path := ROOT + "materials/" + family + ".tres"
		if not ResourceLoader.exists(path):
			push_error("Procedural material is not baked: " + path)
			return null
		_materials[family] = load(path)
	return _materials[family]


static func catalog() -> Array:
	var out: Array = []
	for key: String in SCATTER_BUDGETS:
		out.append({"key": "scatter/" + key, "params": {}})
	for variant in 7:
		out.append({"key": "forest/tree", "params": {"variant": variant}})
	for variant in 3:
		out.append({"key": "forest/orchard", "params": {"variant": variant}})
	for key: String in ["hand", "torso", "boot", "bevel_box", "head", "neck", "grip"]:
		out.append({"key": "object/" + key, "params": {}})
	for family: String in VehicleVisuals.SIZES:
		out.append({"key": "vehicle/" + family, "params": {}})
	var props_generator: GDScript = load("res://src/detailed_props.gd")
	out.append_array(props_generator.catalog())
	return out


## Offline only. Each call owns its RNG and leaves the story random stream alone.
static func generate(key: String, params: Dictionary = {}, seed_value: int = SEED) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value + int(key.hash()) + int(params.get("variant", 0)) * 7919
	var result: Dictionary = {}
	if key.begins_with("object/"):
		var generator: GDScript = load("res://src/object_geometry.gd")
		result = generator.generate(key, params, seed_value)
	elif key.begins_with("prop/"):
		var generator: GDScript = load("res://src/detailed_props.gd")
		result = generator.generate(key, params, seed_value)
	elif key.begins_with("vehicle/"):
		result = VehicleVisuals.generate(key)
	else:
		var near := _geometry(key, params, rng, false)
		rng.seed = seed_value + int(key.hash()) + int(params.get("variant", 0)) * 7919
		var far := _geometry(key, params, rng, true)
		var meshes: Array = []
		var bounds := AABB()
		var has_bounds := false
		for i in (near["meshes"] as Array).size():
			var high: ArrayMesh = near["meshes"][i]
			var low: ArrayMesh = far["meshes"][i]
			var combined := _with_lod(high, low)
			if combined.get_surface_count() > 0:
				combined.surface_set_material(0, material(near["material_keys"][i]))
				bounds = bounds.merge(high.get_aabb()) if has_bounds else high.get_aabb()
				has_bounds = true
			meshes.append(combined)
		result = {"meshes": meshes, "lod_meshes": far["meshes"],
			"material_keys": near["material_keys"], "bounds": bounds,
			"anchors": {"root": Transform3D.IDENTITY,
				"top": Transform3D(Basis(), Vector3(0, bounds.end.y, 0))}}
	result["key"] = key
	result["version"] = VERSION
	result["seed"] = seed_value
	result["params"] = params.duplicate(true)
	result["materials"] = []
	for mesh: ArrayMesh in result.get("meshes", []):
		for surface in mesh.get_surface_count():
			(result["materials"] as Array).append(mesh.surface_get_material(surface))
	return result


static func bake(key: String, params: Dictionary = {}, seed_value: int = SEED) -> Error:
	var resource := Resource.new()
	var asset := generate(key, params, seed_value)
	if asset.is_empty() or (asset.get("meshes", []) as Array).is_empty():
		return ERR_INVALID_DATA
	resource.set_meta("asset", asset)
	return ResourceSaver.save(resource, asset_path(key, params, seed_value), ResourceSaver.FLAG_COMPRESS)


static func _surface() -> SurfaceTool:
	var out := SurfaceTool.new()
	out.begin(Mesh.PRIMITIVE_TRIANGLES)
	return out


static func _finish(st: SurfaceTool) -> ArrayMesh:
	var arrays := st.commit_to_arrays()
	if arrays.is_empty() or arrays[Mesh.ARRAY_VERTEX] == null \
			or (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).is_empty():
		return ArrayMesh.new()
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _geometry(key: String, params: Dictionary, rng: RandomNumberGenerator, low: bool) -> Dictionary:
	var body := _surface()
	var detail := _surface()
	var family := "wood"
	var detail_family := "leaf"
	var name := key.trim_prefix("scatter/")
	if key.begins_with("forest/") or name in ["nat-tree-a", "nat-pine-a", "nat-deadtree-a", "nat-twisted"]:
		var variant := int(params.get("variant", 0))
		var orchard := key == "forest/orchard"
		var pine := (key == "forest/tree" and variant < 2) or name == "nat-pine-a"
		var dry := (key == "forest/tree" and variant >= 5) or name in ["nat-deadtree-a", "nat-twisted"]
		family = "bark" if pine or orchard or dry else "birch"
		detail_family = "pine" if pine else "leaf"
		_tree(body, detail, rng, pine, dry, orchard, key.begins_with("forest/"), low)
	elif name in ["nat-grass", "nat-grass-tall", "nat-fern", "nat-plant-big", "nat-bush"]:
		family = "grass" if name.begins_with("nat-grass") else "leaf"
		_plants(body, rng, name, low)
	elif name in ["nat-pebble", "nat-rock-a", "ok-rocks"]:
		family = "gravel"
		for i in (3 if name == "ok-rocks" and not low else 1):
			_rock(body, rng, Vector3(i * 0.46 - (0.46 if name == "ok-rocks" else 0.0), 0.23, 0),
				Vector3(0.58, 0.42, 0.46), 6 if low else 8)
	elif name == "ok-stump":
		family = "bark"
		_tube(body, Vector3(0, 0.03, 0), Vector3(0.04, 0.62, 0), 0.36, 0.29, 6, true)
		for i in (1 if low else 3):
			var angle := float(i) * TAU / 3.0
			_tube(body, Vector3(cos(angle) * 0.57, 0.01, sin(angle) * 0.57),
				Vector3(0, 0.25, 0), 0.01, 0.11, 4)
	elif name == "ok-haybale":
		family = "hay"
		_box(body, Vector3(0, 0.35, 0), Vector3(1.25, 0.7, 0.7))
		if not low:
			for x: float in [-0.37, 0.37]:
				_box(body, Vector3(x, 0.35, 0), Vector3(0.035, 0.715, 0.715))
	elif name in ["ok-barrel-rust", "ok-can"]:
		family = "rusted_metal"
		var radius := 0.33 if name == "ok-barrel-rust" else 0.30
		_tube(body, Vector3.ZERO, Vector3(0, 1, 0), radius, radius * 0.97, 8 if low else 12, true)
		if not low:
			for y: float in [0.08, 0.90]:
				_tube(body, Vector3(0, y, 0), Vector3(0, y + 0.045, 0), radius * 1.04, radius * 1.04, 12)
	elif name == "ok-logstack":
		family = "bark"
		for i in (2 if low else 5):
			var x := float(i % 3) * 0.35 - 0.35 + (0.16 if i >= 3 else 0.0)
			var y := 0.18 + float(i / 3) * 0.31
			_tube(body, Vector3(x, y, -0.7), Vector3(x, y, 0.7), 0.17, 0.16, 8, true)
	elif name in ["ok-fence-broken", "ok-fence-simple"]:
		family = "wood"
		for x: float in [-0.72, 0.72]:
			_box(body, Vector3(x, 0.5, 0), Vector3(0.11, 1.0, 0.11))
		for y: float in [0.34, 0.78]:
			_box(body, Vector3(0, y, 0.03), Vector3(1.56, 0.10, 0.08))
	elif name == "ok-lily":
		family = "leaf"
		for i in (4 if low else 8):
			var angle := float(i) * TAU / 9.0
			var p := Vector3(cos(angle), 0.015 * sin(angle * 2.0), sin(angle)) * 0.42
			var q := Vector3(cos(angle + TAU / 9.0), 0.012, sin(angle + TAU / 9.0)) * 0.42
			_triangle(body, Vector3(0, 0.02, 0), q, p, Vector3.UP)
	elif name == "ok-pumpkin":
		family = "hay"
		_rock(body, rng, Vector3(0, 0.40, 0), Vector3(0.56, 0.42, 0.53), 8)
		_tube(body, Vector3(0, 0.71, 0), Vector3(0.035, 0.91, 0), 0.05, 0.02, 4)
	else:
		push_error("Unknown procedural key: " + key)
	return {"meshes": [_finish(body), _finish(detail)], "material_keys": [family, detail_family]}


static func _tree(wood: SurfaceTool, leaf: SurfaceTool, rng: RandomNumberGenerator,
		pine: bool, dry: bool, orchard: bool, forest: bool, low: bool) -> void:
	var width := 1.0 if forest else 0.37
	var fork := Vector3(rng.randf_range(-0.05, 0.05) * width, 0.40, 0.025 * width)
	var top := Vector3(fork.x * 1.8, 0.82 if orchard else 1.0, -fork.z)
	_tube(wood, Vector3.ZERO, fork, 0.115 * width, 0.071 * width, 6)
	_tube(wood, fork, top, 0.071 * width, 0.010 * width, 6)
	for i in (1 if low else 2):
		var angle := float(i) * 2.9 + 0.5
		_tube(wood, Vector3(cos(angle) * width * 0.30, 0.006, sin(angle) * width * 0.30),
			Vector3(0, 0.11, 0), 0.012 * width, 0.080 * width, 3)
	var count := (3 if low else 4) if pine else (4 if low else 7)
	if dry:
		count = 3 if low else 5
	elif not forest and not low:
		count += 3
	for i in count:
		var angle := float(i) * 2.39996 + rng.randf_range(-0.16, 0.16)
		var y := 0.34 + float(i) / float(count) * (0.32 if orchard else 0.39)
		var reach := (0.86 - y * 0.49) if pine else rng.randf_range(0.53, 0.77)
		var start := Vector3(fork.x, y, 0)
		var end := Vector3(cos(angle) * width * reach, y + (0.06 if pine else 0.17),
			sin(angle) * width * reach)
		if pine or dry:
			_tube(wood, start, end, 0.035 * width, 0.008 * width, 6)
		else:
			var middle := start.lerp(end, 0.55) - Vector3(0, 0.035, 0)
			_tube(wood, start, middle, (0.050 if orchard else 0.033) * width, 0.022 * width, 5)
			_tube(wood, middle, end, 0.022 * width, 0.005 * width, 5)
		if dry:
			if i % 2 == 0:
				_tube(wood, end, end + Vector3(cos(angle + 0.7) * width * 0.19, 0.13,
					sin(angle + 0.7) * width * 0.19), 0.017 * width, 0.004 * width, 6)
		elif pine:
			# Three crossed branch sprays form a complete tier around the trunk.
			# The needle atlas carries many small needles, not one oversized twig.
			var span := (1.88 - y * 1.50) * width
			for j in (2 if low else 3):
				var az := float(j) * PI / 3.0 + angle * 0.18
				_card(leaf, Vector3(fork.x, y + 0.10, 0),
					Vector3(cos(az) * span, 0, sin(az) * span), Vector3(0, 0.30, 0))
		else:
			var center := end * Vector3(0.69, 1.0, 0.69)
			var span := (1.40 if orchard else 1.26) * width
			var vertical := 0.32 if orchard else 0.28
			for j in (2 if low else 3):
				var az := angle + float(j) * PI / 3.0
				_card(leaf, center, Vector3(cos(az) * span, 0, sin(az) * span),
					Vector3(-sin(az) * span * 0.12, vertical, cos(az) * span * 0.12))
	if not dry:
		var center := Vector3(top.x, 0.82 if orchard else 0.88, top.z)
		for j in (1 if low else 3):
			var angle := float(j) * PI / 3.0
			var span := (0.66 if pine else 0.86) * width
			_card(leaf, center, Vector3(cos(angle) * span, 0, sin(angle) * span), Vector3(0, 0.24, 0))

static func _plants(st: SurfaceTool, rng: RandomNumberGenerator, name: String, low: bool) -> void:
	var count := 5 if low else 10
	if name == "nat-bush":
		count = 6 if low else 18
	for i in count:
		var az := float(i) * 2.39996
		var height := rng.randf_range(0.60, 1.0)
		var spread := 0.23 if name.begins_with("nat-grass") else 0.5
		var root := Vector3(cos(az) * spread * 0.35, 0, sin(az) * spread * 0.35)
		var tip := Vector3(cos(az) * spread, height, sin(az) * spread)
		var across := Vector3(-sin(az), 0, cos(az))
		if name.begins_with("nat-grass"):
			var width := 0.025 if name == "nat-grass-tall" else 0.045
			var mid := root.lerp(tip, 0.65)
			_card(st, root.lerp(mid, 0.5), across * width, mid - root)
			_triangle(st, mid - across * width * 0.5, tip, mid + across * width * 0.5,
				across.cross(tip - root).normalized())
		elif name == "nat-fern":
			for k in (3 if low else 5):
				var t := 0.2 + 0.14 * float(k)
				var pos := root.lerp(tip, t)
				_card(st, pos, across * (0.31 * (1.0 - t)), Vector3(0, 0.12, 0))
		else:
			var p := root.lerp(tip, 0.55)
			_card(st, p, across * (0.43 if name == "nat-bush" else 0.29),
				Vector3(cos(az) * 0.22, height * 0.68, sin(az) * 0.22))


static func _box(st: SurfaceTool, position: Vector3, size: Vector3) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	st.append_from(mesh, 0, Transform3D(Basis(), position))


static func _tube(st: SurfaceTool, a: Vector3, b: Vector3, radius: float,
		end_radius: float, sides: int, caps: bool = false) -> void:
	var direction := (b - a).normalized()
	var axis := Vector3.FORWARD if absf(direction.dot(Vector3.FORWARD)) < 0.95 else Vector3.RIGHT
	var x := direction.cross(axis).normalized()
	var basis := Basis(x, direction, x.cross(direction).normalized())
	var cylinder := CylinderMesh.new()
	cylinder.bottom_radius = radius
	cylinder.top_radius = end_radius
	cylinder.height = a.distance_to(b)
	cylinder.radial_segments = sides
	cylinder.rings = 0
	cylinder.cap_top = caps
	cylinder.cap_bottom = caps
	st.append_from(cylinder, 0, Transform3D(basis, (a + b) * 0.5))


static func _rock(st: SurfaceTool, rng: RandomNumberGenerator, center: Vector3,
		size: Vector3, segments: int) -> void:
	var sphere := SphereMesh.new()
	sphere.radius = 1.0
	sphere.height = 2.0
	sphere.radial_segments = segments
	sphere.rings = 2
	var xf := Transform3D(Basis(Vector3.UP, rng.randf_range(0, TAU)).scaled(size), center)
	st.append_from(sphere, 0, xf)


static func _card(st: SurfaceTool, center: Vector3, du: Vector3, dv: Vector3) -> void:
	var n := du.cross(dv).normalized()
	var a := center - du * 0.5 - dv * 0.5
	var b := a + du
	var c := b + dv
	var d := a + dv
	var points := [a, c, b, a, d, c]
	var uv := [Vector2(0, 1), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1), Vector2(0, 0), Vector2(1, 0)]
	for i in 6:
		st.set_normal(n)
		st.set_uv(uv[i])
		st.add_vertex(points[i])


static func _triangle(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	for p: Vector3 in [a, b, c]:
		st.set_normal(normal)
		st.set_uv(Vector2(p.x, p.z))
		st.add_vertex(p)


## Both LOD vertex sets live in one surface; Godot switches indices on the GPU.
static func _with_lod(high: ArrayMesh, low: ArrayMesh) -> ArrayMesh:
	if high.get_surface_count() == 0 or low.get_surface_count() == 0:
		return high
	var arrays := high.surface_get_arrays(0)
	var low_arrays := low.surface_get_arrays(0)
	var offset: int = (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	var indices := PackedInt32Array()
	if arrays[Mesh.ARRAY_INDEX] != null:
		indices = arrays[Mesh.ARRAY_INDEX]
	if indices.is_empty():
		indices = PackedInt32Array(range(offset))
	var low_indices := PackedInt32Array()
	if low_arrays[Mesh.ARRAY_INDEX] != null:
		low_indices = low_arrays[Mesh.ARRAY_INDEX]
	if low_indices.is_empty():
		low_indices = PackedInt32Array(range((low_arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()))
	if low_indices.size() >= indices.size():
		return high
	for i in low_indices.size():
		low_indices[i] += offset
	for channel: int in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TEX_UV]:
		arrays[channel].append_array(low_arrays[channel])
	# Primitive meshes may carry tangents; only the common channels are required.
	arrays[Mesh.ARRAY_TANGENT] = null
	arrays[Mesh.ARRAY_INDEX] = indices
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], {12.0: low_indices})
	return mesh


static func triangles(mesh: ArrayMesh) -> int:
	var total := 0
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		var index := PackedInt32Array()
		if arrays[Mesh.ARRAY_INDEX] != null:
			index = arrays[Mesh.ARRAY_INDEX]
		total += (index.size() if not index.is_empty() else
			(arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
	return total


## CPU texture creation is only used by tools/bake_procedural.gd.
static func bake_textures(families: Array = []) -> Error:
	DirAccess.make_dir_recursive_absolute(ROOT + "textures")
	DirAccess.make_dir_recursive_absolute(ROOT + "materials")
	for family: String in (TEXTURES if families.is_empty() else families):
		var size := 128 if family == "flashlight-cookie" else 256
		var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
		var noise := FastNoiseLite.new()
		noise.seed = SEED + int(family.hash())
		noise.frequency = 0.05
		for y in size:
			for x in size:
				image.set_pixel(x, y, _pixel(family, x, y, size, noise))
		image.generate_mipmaps()
		var texture := ImageTexture.create_from_image(image)
		var err := ResourceSaver.save(texture, texture_path(family), ResourceSaver.FLAG_COMPRESS)
		if err != OK:
			return err
		texture.take_over_path(texture_path(family))
		if family in NORMAL_TEXTURES:
			var normal := Image.create(size, size, false, Image.FORMAT_RGB8)
			for ny in size:
				for nx in size:
					var dx := image.get_pixel((nx + 1) % size, ny).get_luminance() \
						- image.get_pixel((nx + size - 1) % size, ny).get_luminance()
					var dy := image.get_pixel(nx, (ny + 1) % size).get_luminance() \
						- image.get_pixel(nx, (ny + size - 1) % size).get_luminance()
					var n := Vector3(-dx * 2.1, dy * 2.1, 1).normalized()
					normal.set_pixel(nx, ny, Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5))
			normal.generate_mipmaps()
			err = ResourceSaver.save(ImageTexture.create_from_image(normal),
				texture_path(family + "-normal"), ResourceSaver.FLAG_COMPRESS)
			if err != OK:
				return err
		var mat := ShaderMaterial.new()
		var alpha := family in ["leaf", "pine", "grass"]
		mat.shader = load("res://shaders/psx_skin_alpha.gdshader" if alpha else "res://shaders/psx.gdshader")
		mat.set_shader_parameter("albedo_tex", texture)
		mat.set_shader_parameter("albedo", Color.WHITE)
		if alpha:
			mat.set_shader_parameter("alpha_cut", 0.40)
			mat.set_shader_parameter("double_sided", 1.0)
		err = ResourceSaver.save(mat, ROOT + "materials/" + family + ".tres")
		if err != OK:
			return err
		_materials[family] = mat
	return OK


static func _pixel(family: String, x: int, y: int, size: int, noise: FastNoiseLite) -> Color:
	var u := float(x) / float(size)
	var v := float(y) / float(size)
	var fine := noise.get_noise_2d(x * 3.0, y * 3.0)
	var broad := noise.get_noise_2d(x * 0.23, y * 0.23)
	var detail := fine * 0.065 + broad * 0.11
	var base := Color(0.58, 0.54, 0.46)
	match family:
		"flashlight-cookie":
			var r := Vector2(u - 0.5, v - 0.5).length() * 2.0
			var energy := (1.0 - smoothstep(0.10, 1.0, r)) * (0.90 + 0.10 * exp(-r * r * 6.0))
			return Color(energy, energy, energy, 1.0)
		"wood", "boards":
			var slat := fposmod(u * 6.0, 1.0)
			var grain := sin(u * 570.0 + broad * 7.0 + sin(v * 14.0) * 1.5) * 0.022
			base = Color(0.64, 0.58, 0.47) if family == "boards" else Color(0.72, 0.70, 0.65)
			detail += grain - (0.19 if slat < 0.020 else 0.0)
			detail += 0.040 if slat > 0.025 and slat < 0.044 else 0.0
		"bark":
			base = Color(0.33, 0.28, 0.22)
			detail += sin(u * 150.0 + broad * 9.0) * 0.060
		"birch":
			base = Color(0.78, 0.78, 0.71)
			var band := sin(v * 119.0 + sin(u * 17.0) * 1.8)
			if band > 0.91 and sin(u * 41.0 + floor(v * 17.0)) > -0.1:
				detail -= 0.56
		"leaf", "pine":
			return _foliage_pixel(family, u, v, fine)
		"grass":
			base = Color(0.34, 0.38, 0.23)
			detail += sin(u * 420.0 + broad * 13.0 + v * 7.0) * 0.032
		"soil":
			base = Color(0.32, 0.28, 0.23)
		"gravel":
			base = Color(0.45, 0.45, 0.39)
			detail += absf(noise.get_noise_2d(x * 1.4, y * 1.4)) * 0.15
		"brick":
			base = Color(0.48, 0.29, 0.21)
			var course := floorf(v * 8.0)
			if fposmod(v * 8.0, 1.0) < 0.065 or fposmod(u * 4.0 + fmod(course, 2.0) * 0.5, 1.0) < 0.030:
				base = Color(0.50, 0.48, 0.43)
		"concrete", "whitewash":
			base = Color(0.57, 0.58, 0.54) if family == "concrete" else Color(0.78, 0.77, 0.70)
			if family == "concrete" and (u < 0.009 or v < 0.009):
				detail -= 0.17
		"roof":
			base = Color(0.42, 0.48, 0.52)
			detail += sin(u * TAU * 10.0) * 0.055
		"wallpaper":
			base = Color(0.67, 0.65, 0.55)
			detail += sin(u * TAU * 8.0) * sin(v * TAU * 12.0) * 0.033
		"linoleum":
			base = Color(0.47, 0.43, 0.32)
			detail += 0.04 * sin(u * 45.0 + v * 18.0)
		"rusted_metal":
			base = Color(0.39, 0.43, 0.43)
			if broad > 0.12:
				base = Color(0.43, 0.25, 0.14)
		"hay":
			base = Color(0.61, 0.52, 0.29)
			detail += sin(v * 340.0 + broad * 6.0) * 0.055
		"fabric":
			base = Color(0.84, 0.83, 0.81)
			detail = sin(u * TAU * 96.0) * sin(v * TAU * 96.0) * 0.030 + broad * 0.018
			# Потёртые швы и простёжка, без baked VHS шума.
			if fposmod(u * 8.0, 1.0) < 0.028:
				detail -= 0.085
	return Color(clampf(base.r + detail, 0.01, 1), clampf(base.g + detail, 0.01, 1),
		clampf(base.b + detail, 0.01, 1), 1)


# Each card is a crown cluster with dozens of separate leaf silhouettes.
# The small jittered cells avoid a central stalk and repeated giant leaf pairs.
static func _foliage_pixel(family: String, u: float, v: float, fine: float) -> Color:
	var pine := family == "pine"
	var grid := 15.0 if pine else 11.0
	var col := floori(u * grid)
	var row := floori(v * grid)
	var envelope := Vector2((u - 0.5) / 0.50, (v - 0.50) / 0.49)
	var edge := 1.0 + sin(atan2(envelope.y, envelope.x) * 9.0) * 0.10
	if envelope.length() > edge or (pine and absf(u - 0.5) > 0.09 + v * 0.43):
		return Color(0.24, 0.32, 0.17, 0)
	for cy in range(row - 1, row + 2):
		for cx in range(col - 1, col + 2):
			var h := _leaf_hash(cx, cy, 1)
			if h < 0.055:
				continue
			var center := (Vector2(cx, cy) + Vector2(0.25 + h * 0.5,
				0.20 + _leaf_hash(cx, cy, 2) * 0.60)) / grid
			var delta := Vector2(u, v) - center
			var angle := _leaf_hash(cx, cy, 3) * TAU
			var p := Vector2(delta.x * cos(angle) - delta.y * sin(angle),
				delta.x * sin(angle) + delta.y * cos(angle))
			var sx := (0.024 if pine else 0.031) * (0.82 + h * 0.36)
			var sy := (0.061 if pine else 0.047) * (0.85 + h * 0.40)
			var d := pow(p.x / sx, 2.0) + pow(p.y / sy, 2.0)
			if d < 1.0:
				var shade := h * 0.115 + fine * 0.022 - d * 0.024
				var vein := 0.025 if absf(p.x) < 0.0025 else 0.0
				return Color(0.19 + shade + vein, 0.29 + shade + vein,
					0.12 + shade * 0.58, 1.0) if not pine else Color(
						0.12 + shade, 0.23 + shade, 0.15 + shade * 0.70, 1.0)
	return Color(0.24, 0.32, 0.17, 0)


static func _leaf_hash(x: int, y: int, salt: int) -> float:
	return fposmod(sin(float(x * 127 + y * 311 + salt * 97)) * 43758.5453, 1.0)

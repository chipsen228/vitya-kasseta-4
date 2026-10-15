extends SceneTree

const VD = preload("res://src/visual_dressing.gd")
const REQUIRED_ZONES := ["hall", "kitchen", "attic", "banya", "shop", "club",
	"redhouse", "barn-in", "pumphouse"]
const FORBIDDEN := ["id", "interaction", "interaction_id", "collider", "collision", "collide"]


class FakeBuilder:
	extends RefCounted
	var buckets: Dictionary = {}
	var box_calls: Array = []
	var plane_calls: Array = []

	func box(x0: float, x1: float, y0: float, y1: float, z0: float, z1: float,
			key: String, segment := 0.0, collide := true, collide_only := false) -> void:
		box_calls.append([x0, x1, y0, y1, z0, z1, key, segment, collide, collide_only])
		_bucket(key)

	func plane(w: float, h: float, key: String, pos: Vector3, rot_y := 0.0,
			rot_x := 0.0, seg_w := 2, seg_h := 2) -> void:
		plane_calls.append([w, h, key, pos, rot_y, rot_x, seg_w, seg_h])
		_bucket(key)

	func _bucket(key: String) -> Dictionary:
		if not buckets.has(key):
			buckets[key] = {"v": [], "n": [], "uv": []}
		return buckets[key]


func _initialize() -> void:
	var errors: Array[String] = []
	var source: Dictionary = VD.data()
	if source.is_empty():
		errors.append("data/visual_dressing.json is missing or invalid")
	if int(source.get("version", 0)) != 1:
		errors.append("schema version must be 1")
	_find_forbidden(source, "root", errors)
	_check_zones(source, errors)
	_check_atlases(source, errors)

	var fake := FakeBuilder.new()
	var result: Dictionary = VD.build_data(fake, source)
	if not bool(result.get("enabled", false)):
		errors.append("valid dressing did not build")
	if int(result.get("colliders", -1)) != 0:
		errors.append("dressing reported colliders")
	for call: Array in fake.box_calls:
		if bool(call[8]) or bool(call[9]):
			errors.append("box was emitted with collision")
		if not String(call[6]).begins_with(VD.BUCKET_PREFIX):
			errors.append("box is not isolated in a visual-only bucket")
	for call: Array in fake.plane_calls:
		if not String(call[2]).begins_with(VD.BUCKET_PREFIX):
			errors.append("plane is not isolated in a visual-only bucket")
	var atlas_buckets := 0
	for key: String in fake.buckets:
		if not key.begins_with(VD.BUCKET_PREFIX):
			errors.append("dressing leaked into base bucket %s" % key)
		if key == VD.BUCKET_PREFIX + "dressing-paper-atlas" \
				or key == VD.BUCKET_PREFIX + "dressing-patina-atlas":
			atlas_buckets += 1
	if atlas_buckets != 2:
		errors.append("paper/patina must occupy exactly two material buckets, got %d" % atlas_buckets)

	var empty_result: Dictionary = VD.build_data(FakeBuilder.new(), {})
	if bool(empty_result.get("enabled", true)):
		errors.append("missing data must be a silent no-op")

	if errors.is_empty():
		print("test_visual_dressing: PASS (%d boxes, %d planes, %d atlas quads, %d clusters)"
			% [result["boxes"], result["planes"], result["atlas_quads"], result["clusters"]])
		quit(0)
	else:
		for error: String in errors:
			printerr("FAIL test_visual_dressing: ", error)
		quit(1)


func _find_forbidden(value: Variant, path: String, errors: Array[String]) -> void:
	if value is Dictionary:
		for key: Variant in value:
			var name := String(key)
			if name.to_lower() in FORBIDDEN:
				errors.append("forbidden gameplay/collision field %s.%s" % [path, name])
			_find_forbidden(value[key], path + "." + name, errors)
	elif value is Array:
		for i in (value as Array).size():
			_find_forbidden(value[i], "%s[%d]" % [path, i], errors)


func _check_zones(source: Dictionary, errors: Array[String]) -> void:
	var clusters: Dictionary = {}
	for section: String in ["boxes", "planes", "atlas_quads"]:
		for raw: Variant in source.get(section, []):
			if not raw is Dictionary:
				continue
			var d: Dictionary = raw
			var zone := String(d.get("zone", ""))
			var cluster := String(d.get("cluster", ""))
			if zone.is_empty() or cluster.is_empty():
				errors.append("%s entry lacks zone/cluster" % section)
				continue
			if not clusters.has(zone):
				clusters[zone] = {}
			(clusters[zone] as Dictionary)[cluster] = true
	for zone: String in REQUIRED_ZONES:
		var count := (clusters.get(zone, {}) as Dictionary).size()
		if count < 3 or count > 6:
			errors.append("zone %s must have 3..6 readable clusters, got %d" % [zone, count])


func _check_atlases(source: Dictionary, errors: Array[String]) -> void:
	var atlases: Dictionary = source.get("atlases", {})
	if atlases.size() != 2 or not atlases.has("paper") or not atlases.has("patina"):
		errors.append("schema must declare paper and patina atlases only")
	var patina: Dictionary = atlases.get("patina", {})
	var material: Dictionary = Materials.DEFS.get("dressing-patina-atlas", {})
	if material.is_empty() or not is_equal_approx(float(material.get("cut", -1.0)),
			float(patina.get("alpha_cut", -2.0))):
		errors.append("patina schema alpha_cut must match its material")
	var occupied: Dictionary = {}
	for raw: Variant in source.get("atlas_quads", []):
		if not raw is Dictionary:
			errors.append("atlas quad is not an object")
			continue
		var d: Dictionary = raw
		var atlas := String(d.get("atlas", ""))
		if not atlases.has(atlas):
			errors.append("atlas quad references an unknown atlas")
		if not VD._valid_atlas_quad(d):
			errors.append("atlas quad is malformed or outside 512x512")
			continue
		var uv: Array = d["uv"]
		var rect := Rect2(float(uv[0]), float(uv[1]), float(uv[2]), float(uv[3]))
		if not occupied.has(atlas):
			occupied[atlas] = []
		for previous: Dictionary in occupied[atlas]:
			var other: Rect2 = previous["rect"]
			if rect.position.x < other.end.x and rect.end.x > other.position.x \
					and rect.position.y < other.end.y and rect.end.y > other.position.y:
				errors.append("atlas regions overlap: %s and %s" % [
					String(previous["cluster"]), String(d.get("cluster", ""))])
		(occupied[atlas] as Array).append({
			"cluster": String(d.get("cluster", "")), "rect": rect})

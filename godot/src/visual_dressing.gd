## Visual-only dressing loaded from data/visual_dressing.json.
##
## The module only appends vertices to WorldBuilder material buckets. It never
## calls CollisionWorld, creates interaction ids, or adds gameplay nodes.
## Semantic boxes and planes use the existing bucket machinery under a
## visual-only prefix. This keeps the base world's large merged AABBs and
## shadow passes unchanged; paper and patina still use one bucket each.
class_name VisualDressing
extends RefCounted

const DATA := "res://data/visual_dressing.json"
const ATLAS_SIZE := 512.0
const BUCKET_PREFIX := "visual:"

static var _cache: Variant = null


static func data() -> Dictionary:
	if _cache != null:
		return _cache
	if not FileAccess.file_exists(DATA):
		_cache = {}
		return _cache
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(DATA))
	_cache = parsed if parsed is Dictionary else {}
	return _cache


## Called after procedural worlds and before WorldBuilder._finish().
## Missing or malformed data deliberately leaves the old world untouched.
static func build(builder) -> Dictionary:
	return build_data(builder, data())


## Public for the schema test; runtime callers should use build(builder).
static func build_data(builder, source: Dictionary) -> Dictionary:
	var out := {
		"enabled": false,
		"boxes": 0,
		"planes": 0,
		"atlas_quads": 0,
		"clusters": 0,
		"colliders": 0,
	}
	if source.is_empty() or int(source.get("version", 0)) != 1:
		return out
	var clusters: Dictionary = {}
	for raw: Variant in source.get("boxes", []):
		if not raw is Dictionary:
			continue
		var d: Dictionary = raw
		if not _valid_vec(d.get("position"), 3) or not _valid_size(d.get("size"), 3):
			continue
		var p := _vec3(d["position"])
		var s := _vec3(d["size"])
		var material := String(d.get("material", ""))
		if material.is_empty():
			continue
		builder.box(p.x - s.x * 0.5, p.x + s.x * 0.5,
			p.y - s.y * 0.5, p.y + s.y * 0.5,
			p.z - s.z * 0.5, p.z + s.z * 0.5,
			BUCKET_PREFIX + material, float(d.get("segment", 0.0)), false)
		out["boxes"] += 1
		clusters[String(d.get("cluster", ""))] = true
	for raw: Variant in source.get("planes", []):
		if not raw is Dictionary:
			continue
		var d: Dictionary = raw
		if not _valid_vec(d.get("position"), 3) or not _valid_size(d.get("size"), 2):
			continue
		var material := String(d.get("material", ""))
		if material.is_empty():
			continue
		var p := _vec3(d["position"])
		var s: Array = d["size"]
		var r: Array = d.get("rotation", [0.0, 0.0])
		builder.plane(float(s[0]), float(s[1]), BUCKET_PREFIX + material, p,
			float(r[0]) if r.size() > 0 else 0.0,
			float(r[1]) if r.size() > 1 else 0.0, 1, 1)
		out["planes"] += 1
		clusters[String(d.get("cluster", ""))] = true
	var atlases: Dictionary = source.get("atlases", {})
	for raw: Variant in source.get("atlas_quads", []):
		if not raw is Dictionary:
			continue
		var d: Dictionary = raw
		var atlas := String(d.get("atlas", ""))
		var atlas_def: Dictionary = atlases.get(atlas, {})
		if atlas_def.is_empty() or not _valid_atlas_quad(d):
			continue
		_emit_atlas_quad(builder,
			BUCKET_PREFIX + String(atlas_def.get("material", atlas)), d)
		out["atlas_quads"] += 1
		clusters[String(d.get("cluster", ""))] = true
	clusters.erase("")
	out["clusters"] = clusters.size()
	out["enabled"] = out["boxes"] + out["planes"] + out["atlas_quads"] > 0
	return out


static func _emit_atlas_quad(builder, key: String, d: Dictionary) -> void:
	var p := _vec3(d["position"])
	var size: Array = d["size"]
	var r: Array = d.get("rotation", [0.0, 0.0])
	var basis := Basis()
	if r.size() > 1 and float(r[1]) != 0.0:
		basis = Basis(Vector3.RIGHT, float(r[1]))
	if r.size() > 0 and float(r[0]) != 0.0:
		basis = Basis(Vector3.UP, float(r[0])) * basis
	var du := basis.x * float(size[0])
	var dv := basis.y * float(size[1])
	var normal := basis.z
	var o := p - du * 0.5 - dv * 0.5
	var points := [o, o + du + dv, o + du, o, o + dv, o + du + dv]
	if du.cross(dv).dot(normal) < 0.0:
		points = [o, o + du, o + du + dv, o, o + du + dv, o + dv]
	var uv: Array = d["uv"]
	var u0 := float(uv[0]) / ATLAS_SIZE
	var v0 := float(uv[1]) / ATLAS_SIZE
	var u1 := float(uv[0] + uv[2]) / ATLAS_SIZE
	var v1 := float(uv[1] + uv[3]) / ATLAS_SIZE
	var tex := [Vector2(u0, v0), Vector2(u1, v1), Vector2(u1, v0),
		Vector2(u0, v0), Vector2(u0, v1), Vector2(u1, v1)]
	if du.cross(dv).dot(normal) < 0.0:
		tex = [Vector2(u0, v0), Vector2(u1, v0), Vector2(u1, v1),
			Vector2(u0, v0), Vector2(u1, v1), Vector2(u0, v1)]
	var bucket: Dictionary = builder._bucket(key)
	for i in 6:
		bucket["v"].append(points[i])
		bucket["n"].append(normal)
		bucket["uv"].append(tex[i])


static func _valid_atlas_quad(d: Dictionary) -> bool:
	if not _valid_vec(d.get("position"), 3) or not _valid_size(d.get("size"), 2):
		return false
	if not _valid_vec(d.get("uv"), 4):
		return false
	var uv: Array = d["uv"]
	return float(uv[0]) >= 0.0 and float(uv[1]) >= 0.0 \
		and float(uv[2]) > 0.0 and float(uv[3]) > 0.0 \
		and float(uv[0] + uv[2]) <= ATLAS_SIZE \
		and float(uv[1] + uv[3]) <= ATLAS_SIZE


static func _valid_vec(value: Variant, length: int) -> bool:
	if not value is Array or (value as Array).size() != length:
		return false
	for n: Variant in value:
		if not (n is int or n is float):
			return false
	return true


static func _valid_size(value: Variant, length: int) -> bool:
	if not _valid_vec(value, length):
		return false
	for n: Variant in value:
		if float(n) <= 0.0:
			return false
	return true


static func _vec3(value: Array) -> Vector3:
	return Vector3(float(value[0]), float(value[1]), float(value[2]))

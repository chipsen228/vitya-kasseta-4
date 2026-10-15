## Batches decorative pieces inside audited gameplay owners. No recursive flatten.
class_name StaticVisualBatch
extends RefCounted

const OWNERS := [
	"home-kitchen-phone", "home-kitchen-bowl", "home-kitchen-sugar", "home-kitchen-kettle",
	"home-tonya-bed", "home-tonya-nightstand", "home-tonya-chest", "home-tonya-chair",
	"home-tonya-basin", "home-attic-album", "home-tripod-mark",
	"home-loft-doll", "home-shed-things",
	"yard-bathloft-interior", "yard-bathloft-tape", "yard-spray-barrel", "yard-sprayer",
	"yard-poison", "yard-sorrel-bald", "yard-forks", "yard-garden-bug",
	"yard-cellar-shed-jars", "yard-cellar-shed-rope", "yard-cellar-shed-lantern",
	"yard-banya-clothes", "yard-banya-ladle", "yard-cellar-shed-key",
	"village-redhouse-toy", "village-crowbar", "village-tractor-kit", "village-well-bundle",
	"village-car-hood-open", "village-street-bike", "village-well-bucket",
	"village-shop-scales", "village-shop-phone", "village-shop-rotor", "village-shop-key",
	"village-arkady-tv", "village-boarded-bunk", "village-boarded-tripod", "village-boarded-cans",
	"village-boarded-tapes", "village-grave-wife", "village-grave-pit",
]


static func build(decor: Dictionary) -> Dictionary:
	var stats := {"owners": 0, "before": 0, "after": 0, "saved": 0}
	for key: String in decor:
		var owner := decor[key] as Node3D
		if owner == null:
			continue
		if String(owner.name) in OWNERS:
			_accumulate(stats, merge_owner(owner))
		elif String(owner.name).begins_with("home-window-"):
			# The existing leaf remains the hinge. Only its four anonymous frame
			# strips are combined; the glass and the gameplay owner stay separate.
			var leaf := owner.get_node_or_null("leaf") as Node3D
			if leaf != null:
				_accumulate(stats, merge_owner(leaf))
	return stats


static func _accumulate(stats: Dictionary, result: Dictionary) -> void:
	for key: String in ["before", "after", "saved"]:
		stats[key] += result[key]
	if int(result["saved"]) > 0:
		stats["owners"] += 1


## Public for contract tests. The caller must approve the gameplay owner first.
static func merge_owner(owner: Node3D) -> Dictionary:
	var groups: Dictionary = {}
	var stats := {"before": 0, "after": 0, "saved": 0}
	for child: Node in owner.get_children():
		if not child is MeshInstance3D:
			continue
		var mi := child as MeshInstance3D
		if not _anonymous(mi) or not mi.visible or mi.has_meta("independent_visual"):
			continue
		if mi.get_child_count() > 0 or mi.get_script() != null or mi.mesh == null or mi.mesh.get_surface_count() != 1:
			continue
		if mi.mesh is QuadMesh or mi.mesh is PlaneMesh:
			continue
		if mi.material_overlay != null or mi.transform.basis.determinant() <= 0.0:
			continue
		if mi.custom_aabb != AABB() or (mi.mesh is ArrayMesh and (mi.mesh as ArrayMesh).get_blend_shape_count() > 0):
			continue
		var mat := mi.get_active_material(0)
		if mat == null or _blended(mat):
			continue
		var key := var_to_str([mat.get_instance_id(),
			mi.layers, mi.cast_shadow, mi.visibility_range_begin, mi.visibility_range_end,
			mi.visibility_range_begin_margin, mi.visibility_range_end_margin,
			mi.visibility_range_fade_mode, mi.lod_bias, mi.transparency, mi.sorting_offset])
		if not groups.has(key):
			groups[key] = []
		(groups[key] as Array).append(mi)
	for key: String in groups:
		var pieces: Array = groups[key]
		if pieces.size() < 2:
			continue
		var source: MeshInstance3D = pieces[0]
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		for piece: MeshInstance3D in pieces:
			st.append_from(piece.mesh, 0, piece.transform)
		var merged := MeshInstance3D.new()
		merged.name = "static-visual-%d" % owner.get_child_count()
		merged.mesh = st.commit()
		merged.material_override = source.get_active_material(0)
		merged.layers = source.layers
		merged.cast_shadow = source.cast_shadow
		merged.visibility_range_begin = source.visibility_range_begin
		merged.visibility_range_end = source.visibility_range_end
		merged.visibility_range_begin_margin = source.visibility_range_begin_margin
		merged.visibility_range_end_margin = source.visibility_range_end_margin
		merged.visibility_range_fade_mode = source.visibility_range_fade_mode
		merged.lod_bias = source.lod_bias
		merged.transparency = source.transparency
		merged.sorting_offset = source.sorting_offset
		merged.set_meta("static_visual_batch", true)
		merged.set_meta("source_pieces", pieces.size())
		for piece: MeshInstance3D in pieces:
			owner.remove_child(piece)
			piece.free()
		owner.add_child(merged)
		stats["before"] += pieces.size()
		stats["after"] += 1
	stats["saved"] = int(stats["before"]) - int(stats["after"])
	if int(stats["saved"]) > 0:
		owner.set_meta("static_visual_batch", stats)
	return stats


static func _anonymous(node: Node) -> bool:
	var label := String(node.name)
	return label == "MeshInstance3D" or label.begins_with("@MeshInstance3D@")


static func _blended(mat: Material) -> bool:
	if mat is BaseMaterial3D:
		return (mat as BaseMaterial3D).transparency in [BaseMaterial3D.TRANSPARENCY_ALPHA,
			BaseMaterial3D.TRANSPARENCY_ALPHA_DEPTH_PRE_PASS]
	if mat is ShaderMaterial:
		var shader := (mat as ShaderMaterial).shader
		if shader != null:
			# Custom cutout shaders discard pixels and never write ALPHA. Preserve
			# blended glass/water as separate instances so sorting is unchanged.
			return shader.code.contains("ALPHA =") or shader.code.contains("ALPHA=")
	return false

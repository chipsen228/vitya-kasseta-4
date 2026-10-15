## Один из существующих material nodes управляет готовыми дальними сетками.
## Новых draw nodes нет; ближние meshes/materials и игровой holder сохраняются.
class_name ModelLodMesh
extends MeshInstance3D

var pieces: Array = []
var near_meshes: Array = []
var near_materials: Array = []
var far_meshes: Array = []
var far_materials: Array = []
var switch_distance := 16.0
var far_active := false
var _elapsed := 0.0


func configure(nodes: Array, meshes: Array, materials: Array, distance: float) -> void:
	pieces = nodes
	far_meshes = meshes
	far_materials = materials
	switch_distance = distance
	for piece: MeshInstance3D in pieces:
		near_meshes.append(piece.mesh)
		near_materials.append(piece.material_override)
	set_meta("independent_visual", true)


func _process(delta: float) -> void:
	_elapsed += delta
	if _elapsed < 0.12:
		return
	_elapsed = 0.0
	var camera := get_viewport().get_camera_3d()
	if camera == null or pieces.is_empty():
		return
	var distance := global_position.distance_to(camera.global_position)
	if distance > switch_distance + 1.0 and not far_active:
		select_far(true)
	elif distance < switch_distance - 1.0 and far_active:
		select_far(false)


func select_far(on: bool) -> void:
	if pieces.is_empty() or on == far_active:
		return
	far_active = on
	var meshes := far_meshes if on else near_meshes
	var materials := far_materials if on else near_materials
	for i in pieces.size():
		var piece: MeshInstance3D = pieces[i]
		piece.visible = i < meshes.size()
		if i < meshes.size():
			piece.mesh = meshes[i]
			piece.material_override = materials[i]
			Materials.set_material_quality(materials[i], Materials.render_hq_enabled)

## Small CPU-only regression suite; reuses exact packed geometry witnesses.
extends "res://tests/test_environment_shadow_surface_batch.gd"

func _initialize() -> void:
	_test_exact_and_flags()
	_test_policy_fallbacks()
	_test_geometry_rejections()
	_test_invalidation()
	_test_fast_owner_inputs()
	for message: String in failures: printerr(message)
	print("test_environment_lod_fast_state: ","PASS" if failures.is_empty() else "FAIL"," checks=",checks)
	call_deferred("quit",0 if failures.is_empty() else 1)

func _test_fast_owner_inputs() -> void:
	var source := _rich_mesh()
	var owner := _owner(source)
	var caster := owner.get_child(0) as MeshInstance3D
	var before := _signature(source)
	var fast := owner._shadow_fast_hits
	var mesh_id := caster.mesh.get_instance_id()
	for frame in 120: owner._sync_shadow_caster()
	_check(owner._shadow_fast_hits==fast+120,"steady frames did not use allocation-free guard")
	_check(caster.mesh.get_instance_id()==mesh_id and _signature(source)==before,"fast guard changed geometry")
	for key: String in ["layers","visibility_range_begin","visibility_range_begin_margin","visibility_range_end","visibility_range_end_margin","visibility_range_fade_mode"]:
		var value: Variant=5 if key=="layers" else GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF if key=="visibility_range_fade_mode" else 2.5
		owner.set(key,value)
		owner._sync_shadow_caster()
		_check(caster.get(key)==owner.get(key),"direct owner edit lost: "+key)
	owner.current_level=2
	owner._sync_shadow_caster()
	_check(not caster.visible and caster.mesh==source,"far caster change suppressed")
	fast=owner._shadow_fast_hits
	for frame in 20: owner._sync_shadow_caster()
	_check(owner._shadow_fast_hits==fast+20,"far steady frames still allocate state")
	# Invalidation while far must still be applied on the first near frame.
	var material := source.surface_get_material(1)
	source.surface_set_material(1,StandardMaterial3D.new())
	owner.current_level=0
	owner._sync_shadow_caster()
	_check(caster.visible and caster.mesh==source and caster.material_override==null,"far invalidation lost on near return")
	source.surface_set_material(1,material)
	owner.refresh_shadow_material_policy()
	_check(caster.material_override!=null and caster.mesh!=source,"explicit refresh suppressed cached policy rebuild")
	owner.free()

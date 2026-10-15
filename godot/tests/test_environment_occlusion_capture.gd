## Actual Main native occlusion pixel QA. GPU execution belongs to the caller.
## --script res://tests/test_environment_occlusion_capture.gd -- --run-gpu
##   --render=hq --output=C:/.../occlusion-proof
## Raw WorldView; OFF repeat, first ON/camera-snap and settled ON must be exact.
## No FPS claim. No production source, visible geometry or physics is rewritten.
## --headless --script res://tests/test_environment_occlusion_capture.gd -- --cpu-helpers
extends SceneTree

const SIZE := Vector2i(1280, 720)
const MIRROR_IMAGE_STAGES := ["prepared", "prep-snap-a", "prep-snap-b", "noop-a", "noop-b", "first", "settled", "snap"]
const STATIC_VIEWS := [
	{"id":"route-peak", "eye":Vector3(-.0650889575,1.68,1.933727622),
		"yaw":.280756237, "pitch":sin(22.740736*.9)*.12, "zone":"plot", "outdoor":true},
	{"id":"cellar-transfer", "eye":Vector3(-3,.1300000548,10.5),
		"yaw":0.0, "pitch":0.0, "zone":"cellar", "outdoor":false},
	{"id":"roof", "eye":Vector3(5.5,8.2,5.5), "target":Vector3(-1.7,7.3,12.9), "zone":"plot", "outdoor":true},
	{"id":"balcony", "eye":Vector3(-3.6,4.98,7.8), "target":Vector3(-3.6,4.9,11.0), "zone":"attic", "outdoor":true},
	{"id":"veranda-door", "eye":Vector3(-.4,2.13,8.8), "target":Vector3(-.4,2.13,11.5), "zone":"veranda", "outdoor":false},
	{"id":"hall-kitchen-door-cutscene", "eye":Vector3(-2.7,2.13,11.2), "target":Vector3(.6,2.13,11.2),
		"zone":"floor1", "outdoor":false, "cutscene":true},
	{"id":"attic-door", "eye":Vector3(-2.5,4.98,11.2), "target":Vector3(.5,4.98,11.2), "zone":"attic", "outdoor":false},
	{"id":"kitchen-window", "eye":Vector3(-.2,1.8,5.6), "target":Vector3(-.2,1.8,11.2), "zone":"plot", "outdoor":true},
	{"id":"hall-window", "eye":Vector3(-6.8,1.9,10.9), "target":Vector3(-3.5,1.9,10.9), "zone":"plot", "outdoor":true},
	{"id":"aunt-window", "eye":Vector3(5.8,1.9,8.4), "target":Vector3(2.4,1.9,8.4), "zone":"plot", "outdoor":true},
]

var output := "res://../output/environment-refresh/occlusion-capture-proof"
var main: Node
var chain: RenderChain
var controller: Node
var failures: Array[String] = []
var records: Array[Dictionary] = []
var time_overrides: Array[Dictionary] = []
var tracked_meshes: Dictionary = {}
var plane_stamp := ""
var physics_stamp := ""
var native_planes := 0
var native_triangles := 0
var completed := false
var hq_reference: Image


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var args := OS.get_cmdline_user_args()
	if args.has("--cpu-helpers"):
		_cpu_helpers()
		return
	if not args.has("--run-gpu") or DisplayServer.get_name() == "headless":
		printerr("test_environment_occlusion_capture: requires real GPU and --run-gpu")
		quit(2)
		return
	for i in args.size():
		if args[i].begins_with("--output="): output = args[i].trim_prefix("--output=")
		elif args[i] == "--output" and i + 1 < args.size(): output = args[i + 1]
	output = ProjectSettings.globalize_path(output)
	if DirAccess.make_dir_recursive_absolute(output) != OK:
		failures.append("Cannot create output directory: " + output)
		_finish()
		return
	root.min_size = SIZE
	root.size = SIZE
	main = (load("res://src/main.tscn") as PackedScene).instantiate()
	root.add_child(main)
	for _frame in 3600:
		if bool(main.get("boot_ready")): break
		await process_frame
	if not bool(main.get("boot_ready")):
		failures.append("actual Main boot incomplete")
		await _cleanup()
		_finish()
		return
	chain = main.get("render_chain")
	controller = main.get("environment_occlusion")
	if not is_instance_valid(controller):
		failures.append("Main.environment_occlusion missing; no fixture substitute is permitted")
		await _cleanup()
		_finish()
		return
	_check(RenderingServer.get_current_rendering_method() == "gl_compatibility", "requires actual Compatibility renderer")
	chain.apply_preset("hq")
	chain.set_vhs_amount(0.0)
	main.set("running", false)
	for node: Node in _nodes(main): node.process_mode = Node.PROCESS_MODE_DISABLED
	chain.world_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_check(chain.world_view.size == SIZE, "actual raw WorldView dimensions differ from 1280x720")
	_check(controller.has_method("set_enabled") and controller.has_method("update") and controller.has_method("stats"), "controller API incomplete")
	controller.call("set_enabled", false)
	controller.call("update")
	_check(not chain.world_view.use_occlusion_culling, "OFF did not restore native viewport flag")
	_native_setup_oracle()
	plane_stamp = _plane_signature()
	physics_stamp = _physics_signature()
	_hold_time()
	var views: Array[Dictionary] = []
	views.assign(STATIC_VIEWS)
	_append_range_views(views)
	_check(views.size() == 16, "static/range camera coverage must contain 16 views")
	# Keep the quality roundtrip adjacent at the same camera/LOD history. Forest
	# hysteresis legitimately differs after travelling through the other views.
	await _view_pair(views[0], "hq")
	_check(_plane_signature() == plane_stamp, "ArrayOccluder resources/arrays/transforms changed after initial HQ view")
	_check(_physics_signature() == physics_stamp, "physics ledger/native shapes changed after initial HQ view")
	_release_time()
	chain.apply_preset("retro")
	chain.set_vhs_amount(0.0)
	controller.call("set_enabled", true)
	controller.call("update")
	var retro: Dictionary = controller.call("stats")
	_check(not bool(retro.get("hq", true)) and not bool(retro.get("native_enabled", true)) \
		and int(retro.get("active_planes", -1)) == 0, "ordinary HQ-to-retro quality sweep did not disable native occlusion")
	_hold_time()
	await _view_pair(STATIC_VIEWS[0], "retro")
	_release_time()
	chain.apply_preset("hq")
	chain.set_vhs_amount(0.0)
	controller.call("set_enabled", true)
	controller.call("update")
	_check(bool((controller.call("stats") as Dictionary).get("hq", false)), "ordinary retro-to-HQ quality sweep did not restore controller HQ policy")
	_hold_time()
	await _view_pair(STATIC_VIEWS[0], "hq-return")
	_check(_plane_signature() == plane_stamp, "HQ/retro/HQ changed immutable native ArrayOccluder arrays")
	_check(_physics_signature() == physics_stamp, "HQ/retro/HQ changed native physics/state")
	for view_index in range(1, views.size()):
		var view: Dictionary = views[view_index]
		await _view_pair(view, "hq")
		_check(_plane_signature() == plane_stamp, "ArrayOccluder resources/arrays/transforms changed after " + String(view["id"]))
		_check(_physics_signature() == physics_stamp, "physics ledger/native shapes changed after " + String(view["id"]))
	_verify_tracked_meshes()
	var final: Dictionary = controller.call("stats")
	_check(int(final.get("runtime_array_updates", -1)) == 0 and int(final.get("array_builds", 0)) == native_planes, "native cache was rebuilt during camera/quality changes")
	_check(int(final.get("retired_sources", -1)) == 0 and int(final.get("source_mutations", -1)) == 0 \
		and int(final.get("physics_mutations", -1)) == 0, "immutable source cohort retired or mutated")
	_check(final.get("errors", ["missing"]).is_empty(), "native controller reports errors")
	_check(records.size() == 18, "GPU pair completion sentinel: expected 18 executed view/preset cases")
	completed = true
	await _cleanup()
	_finish(final)


func _append_range_views(views: Array[Dictionary]) -> void:
	var hero: EnvironmentLod
	for node: Node in _nodes(chain.world_root):
		if node is EnvironmentLod and String(node.name) == "environment-vitya": hero = node; break
	_check(hero != null, "actual Vitya EnvironmentLod missing for range boundary proof")
	if hero == null: return
	var direction := Vector3(0, .08, -1).normalized()
	# Test both hysteresis exit sides of nominal 14/32, and renderer end 58.
	# No threshold is changed or level forced by the fixture.
	for boundary in 3:
		var nominal: float = hero.distances[boundary]
		var margin: float = hero.hysteresis if boundary < 2 else hero.visibility_range_end_margin
		for side in [-1, 1]:
			var distance := nominal + float(side) * (margin + .15)
			views.append({"id":"range-%d-%s" % [int(nominal), "inner" if side < 0 else "outer"],
				"eye":hero.global_position + direction * distance, "target":hero.global_position + Vector3(0,3.5,0),
				"zone":"plot", "outdoor":true, "nominal":nominal, "margin":margin, "distance":distance,
				"owner":String(hero.get_path())})


func _view_pair(view: Dictionary, preset: String) -> void:
	controller.call("set_enabled", false)
	var camera := _set_camera(view)
	if camera == null: return
	_set_lighting(camera, view)
	# These ordinary controllers settle their own current-camera decisions before
	# the pair. They stay frozen throughout OFF/ON and immediate snap captures.
	for _pass in 2:
		for node: Node in _nodes(main):
			if node is EnvironmentLod: node.call("_process", 0.0)
			elif node is ForestLodMesh: node.update_for_camera(camera.global_position)
			elif node is ModelLodMesh: node.call("_process", .2)
	for _frame in 8: await process_frame
	await RenderingServer.frame_post_draw
	_register_meshes()
	var source_before := _source_signature()
	var runtime_before := _runtime_snapshot()
	var stage_guards: Array[Dictionary] = []
	var off_a := await _settled_image()
	var off_b := await _settled_image()
	var stable := _difference(off_a, off_b)
	_check(_exact(stable), "OFF/OFF unstable: " + preset + "/" + String(view["id"]) + " " + str(stable))
	var off_stats: Dictionary = controller.call("stats")
	_check(not chain.world_view.use_occlusion_culling and int(off_stats.get("active_planes", -1)) == 0, "OFF retained own native occluders")
	var alternate_pose := Transform3D(Basis.from_euler(Vector3(.1, PI, 0)),
		Vector3(-3,.13,10.5) if view["id"] == "route-peak" else camera.global_position + Vector3(4,2,-4))
	# Returning a camera can change shadow-atlas coverage even with native OFF.
	# All three runs execute the same preparation, draws and local restoration;
	# the final requested native flag is their only different input. Prove that
	# the complete OFF history repeats before comparing its corresponding stages.
	# FADE_DISABLED ranges retain per-viewport hysteresis from the previous view.
	# One complete, unmeasured OFF run initializes that history through the same
	# A-to-B route. Its pixels remain diagnostics; no measured stage is dropped.
	var priming_sequence := await _mirrored_sequence(false, camera, alternate_pose, runtime_before, stage_guards, "off-prime")
	var off_sequence_a := await _mirrored_sequence(false, camera, alternate_pose, runtime_before, stage_guards, "off-sequence-a")
	var off_sequence_b := await _mirrored_sequence(false, camera, alternate_pose, runtime_before, stage_guards, "off-sequence-b")
	var off_sequence_repeat := _sequence_differences(off_sequence_a, off_sequence_b)
	for stage: String in MIRROR_IMAGE_STAGES:
		_check(_exact(off_sequence_repeat[stage]), "OFF mirrored history unstable at " + stage + ": " + preset + "/" + String(view["id"]) + " " + str(off_sequence_repeat[stage]))
	var off_snap_a: Image = off_sequence_b["prep-snap-a"]
	var off_snap_b: Image = off_sequence_b["prep-snap-b"]
	var off_snap_repeat := _difference(off_snap_a, off_snap_b)
	_check(_exact(off_snap_repeat), "OFF snap repeat unstable: " + preset + "/" + String(view["id"]) + " " + str(off_snap_repeat))
	var off_noop_a: Image = off_sequence_b["noop-a"]
	var off_noop_b: Image = off_sequence_b["noop-b"]
	var off_noop_repeat := _difference(off_noop_a, off_noop_b)
	_check(_exact(off_noop_repeat), "OFF enable/update no-op repeat unstable: " + preset + "/" + String(view["id"]) + " " + str(off_noop_repeat))
	var on_sequence := await _mirrored_sequence(true, camera, alternate_pose, runtime_before, stage_guards, "on-sequence")
	var matched_deltas := _sequence_differences(off_sequence_b, on_sequence)
	for stage: String in ["prepared", "prep-snap-a", "prep-snap-b", "noop-a", "noop-b"]:
		_check(_exact(matched_deltas[stage]), "ON preparation differs while native OFF at " + stage + ": " + preset + "/" + String(view["id"]) + " " + str(matched_deltas[stage]))
	var first_on: Image = on_sequence["first"]
	var first_delta: Dictionary = matched_deltas["first"]
	_check(_exact(first_delta), "first ON render differs: " + preset + "/" + String(view["id"]) + " " + str(first_delta))
	# Retain the immediate toggle comparison independently of history matching;
	# a one-channel first-draw change must remain a failure, including hall-window.
	var immediate_toggle := _difference(on_sequence["noop-b"], first_on)
	_check(_exact(immediate_toggle), "immediate ON toggle differs from its preceding OFF draw: " + preset + "/" + String(view["id"]) + " " + str(immediate_toggle))
	var on: Image = on_sequence["settled"]
	var on_delta: Dictionary = matched_deltas["settled"]
	_check(_exact(on_delta), "settled ON differs: " + preset + "/" + String(view["id"]) + " " + str(on_delta))
	var on_stats: Dictionary = controller.call("stats")
	var live := _live_plane_count()
	_check(live == int(on_stats.get("active_planes", -1)), "actual native visibility differs from controller stats")
	if preset != "retro":
		_check(live > 0 and chain.world_view.use_occlusion_culling, "HQ ON is a no-op without active native planes: " + String(view["id"]))
	else:
		_check(live == 0 and not chain.world_view.use_occlusion_culling, "Retro enabled native occlusion")
	var snap: Image = on_sequence["snap"]
	var snap_delta: Dictionary = matched_deltas["snap"]
	_check(_exact(snap_delta), "first snap/current-camera render differs: " + preset + "/" + String(view["id"]) + " " + str(snap_delta))
	_check(chain.world_view.get_camera_3d() == camera, "configured player camera stole actual current-camera ownership")
	var source_equal := source_before == _source_signature()
	var runtime_after := _runtime_snapshot()
	var runtime_equal := _snapshot_sha(runtime_before) == _snapshot_sha(runtime_after)
	_check(source_equal, "source geometry/arrays/LOD/material/light/visibility changed within pair: " + String(view["id"]))
	_check(runtime_equal, "player/story/cutscene state changed within pair: " + String(view["id"]))
	var id := preset + "-" + String(view["id"])
	for row: Array in [["off-a",off_a], ["off-b",off_b], ["off-snap-a",off_snap_a], ["off-snap-b",off_snap_b],
			["off-noop-a",off_noop_a], ["off-noop-b",off_noop_b], ["on-first",first_on], ["on",on], ["snap-first",snap]]:
		_check((row[1] as Image).save_png(output.path_join(id + "-" + String(row[0]) + ".png")) == OK, "PNG write: " + id)
	for sequence: Array in [["off-prime",priming_sequence], ["off-sequence-a",off_sequence_a], ["off-sequence-b",off_sequence_b], ["on-sequence",on_sequence]]:
		for stage: String in MIRROR_IMAGE_STAGES:
			_check((sequence[1][stage] as Image).save_png(output.path_join(id + "-" + String(sequence[0]) + "-" + stage + ".png")) == OK, "mirrored PNG write: " + id)
	if preset == "hq" and view["id"] == "route-peak": hq_reference = off_a
	var roundtrip: Dictionary = {}
	if preset == "hq-return":
		roundtrip = _difference(hq_reference, off_a)
		_check(_exact(roundtrip), "HQ/retro/HQ raw pixels failed restoration: " + str(roundtrip))
	records.append({"id":view["id"], "preset":preset, "camera_id":camera.get_instance_id(), "eye":_vector(camera.global_position),
		"buffer":_vector2i(chain.world_view.size),
		"basis":str(camera.global_basis), "cutscene_camera":camera != chain.camera, "nominal":view.get("nominal"),
		"range_margin":view.get("margin"), "owner_distance":view.get("distance"), "owner":view.get("owner"),
		"off_repeat":stable, "on_first":first_delta, "on":on_delta, "snap_first":snap_delta, "hq_roundtrip":roundtrip,
		"off_snap_repeat":off_snap_repeat, "off_noop_repeat":off_noop_repeat,
		"off_sequence_repeat":off_sequence_repeat, "matched_history_deltas":matched_deltas, "immediate_toggle":immediate_toggle,
		"priming_vs_initial_off":_priming_differences(off_a, priming_sequence),
		"priming_vs_measured_off":_sequence_differences(priming_sequence,off_sequence_a),
		"fixture_cache_resets":[priming_sequence["atlas_reset"],off_sequence_a["atlas_reset"],off_sequence_b["atlas_reset"],on_sequence["atlas_reset"]],
		"off_snap_vs_settled":_difference(off_a, off_snap_b), "off_noop_vs_settled":_difference(off_a, off_noop_b),
		"on_first_vs_settled":_difference(off_a, first_on), "on_snap_vs_settled":_difference(off_a, snap),
		"off_sequence_settled_vs_original":_difference(off_a, off_sequence_b["settled"]),
		"off_sequence_snap_vs_original":_difference(off_a, off_sequence_b["snap"]), "on_settled_vs_original":_difference(off_a, on),
		"runtime_changes":_snapshot_diff(runtime_before, runtime_after), "stage_guards":stage_guards,
		"active_native_planes":live, "controller":on_stats, "source_guard":source_equal, "runtime_guard":runtime_equal,
		"visible_lod":_lod_signature(), "world_render":_world_render_info()})
	controller.call("set_enabled", false)
	if bool(view.get("cutscene", false)): (main.get("cutscene") as Cutscene).cancel()


func _mirrored_sequence(enabled: bool, camera: Camera3D, alternate_pose: Transform3D,
		runtime_before: Dictionary, guards: Array[Dictionary], prefix: String) -> Dictionary:
	var images: Dictionary = {}
	controller.call("set_enabled", false)
	controller.call("update")
	images["atlas_reset"] = await _reset_positional_shadow_cache(runtime_before, guards, prefix)
	images["prepared"] = await _settled_image()
	_guard_stage(guards, prefix + "-prepared", runtime_before)
	for stage: String in ["prep-snap-a", "prep-snap-b"]:
		images[stage] = await _camera_snap(camera, alternate_pose)
		_guard_stage(guards, prefix + "-" + stage, runtime_before)
	for stage: String in ["noop-a", "noop-b"]:
		controller.call("set_enabled", false)
		controller.call("update")
		images[stage] = await _first_image()
		_guard_stage(guards, prefix + "-" + stage, runtime_before)
	controller.call("set_enabled", enabled)
	controller.call("update")
	images["first"] = await _first_image()
	_guard_stage(guards, prefix + "-first", runtime_before)
	images["settled"] = await _settled_image()
	_guard_stage(guards, prefix + "-settled", runtime_before)
	images["snap"] = await _camera_snap(camera, alternate_pose)
	_guard_stage(guards, prefix + "-snap", runtime_before)
	return images


func _reset_positional_shadow_cache(runtime_before: Dictionary, guards: Array[Dictionary], prefix: String) -> Dictionary:
	# Fixture-only cache isolation, not a render-quality change. The pinned
	# GLES3 LightStorage::shadow_atlas_set_size frees textures/FBOs/shadow entries
	# and light-owner links when the size changes. Restoring the same size/bits
	# causes fresh owner allocation/redraw; quadrant subdivisions remain intact.
	_guard_stage(guards, prefix + "-before-cache-reset", runtime_before)
	var before := _atlas_settings(chain.world_view)
	var source_before := _source_signature()
	var start_frame := Engine.get_frames_drawn()
	_check(int(before["size"]) > 0, "fixture cache reset requires the original nonzero positional shadow atlas")
	_check(not chain.world_view.use_occlusion_culling, "cache reset must begin with native occlusion OFF")
	chain.world_view.positional_shadow_atlas_size = 0
	for _draw in 2: await RenderingServer.frame_post_draw
	var cleared := _atlas_settings(chain.world_view)
	var zero_expected := runtime_before.duplicate(true)
	zero_expected["positional_shadow_atlas"] = before.duplicate(true)
	zero_expected["positional_shadow_atlas"]["size"] = 0
	_guard_stage(guards, prefix + "-cache-zero", zero_expected)
	_check(cleared == zero_expected["positional_shadow_atlas"], "cache-zero changed atlas depth format or quadrant subdivisions")
	var cleared_frame := Engine.get_frames_drawn()
	_restore_atlas_size(chain.world_view, before)
	var after := _atlas_settings(chain.world_view)
	var settings_equal := after == before
	var source_equal := source_before == _source_signature()
	_check(settings_equal, "cache reset did not restore the original positional atlas configuration")
	_check(source_equal, "cache reset changed source geometry/material/light properties")
	_guard_stage(guards, prefix + "-cache-restored", runtime_before)
	return {"fixture_only":true, "api":"SubViewport.positional_shadow_atlas_size", "zero_post_draws":2,
		"before":before, "zero":cleared, "restored":after, "settings_guard":settings_equal,
		"source_guard":source_equal, "start_frame":start_frame, "cleared_frame":cleared_frame,
		"scope":"positional atlas texture/FBO/owner cache only; light transforms, energy, shadow settings and native source geometry unchanged"}


func _atlas_settings(viewport: Viewport) -> Dictionary:
	return {"size":viewport.positional_shadow_atlas_size, "16_bits":viewport.positional_shadow_atlas_16_bits,
		"quadrants":[viewport.positional_shadow_atlas_quad_0,viewport.positional_shadow_atlas_quad_1,
			viewport.positional_shadow_atlas_quad_2,viewport.positional_shadow_atlas_quad_3]}


func _restore_atlas_size(viewport: Viewport, saved: Dictionary) -> void:
	viewport.positional_shadow_atlas_16_bits = bool(saved["16_bits"])
	viewport.positional_shadow_atlas_size = int(saved["size"])


func _sequence_differences(reference: Dictionary, candidate: Dictionary) -> Dictionary:
	var deltas: Dictionary = {}
	for stage: String in MIRROR_IMAGE_STAGES:
		deltas[stage] = _difference(reference.get(stage), candidate.get(stage))
	return deltas


func _priming_differences(initial: Image, priming: Dictionary) -> Dictionary:
	var deltas: Dictionary = {}
	for stage: String in MIRROR_IMAGE_STAGES:
		deltas[stage] = _difference(initial, priming.get(stage))
	return deltas


func _camera_snap(camera: Camera3D, alternate_pose: Transform3D) -> Image:
	var local_pose := camera.transform
	var alternate := chain.camera
	var alternate_local := alternate.transform
	alternate.make_current()
	alternate.global_transform = alternate_pose
	controller.call("update")
	await _first_image()
	_restore_camera_local(camera, local_pose)
	if alternate != camera: alternate.transform = alternate_local
	controller.call("update")
	# This is the first render after the return. No LOD/light/actor update or
	# settling draw is inserted on either OFF or ON path.
	return await _first_image()


func _restore_camera_local(camera: Camera3D, saved: Transform3D) -> void:
	# Restoring a global getter through the global setter may perform another
	# inverse-parent multiplication. Keep the original local float32 pose.
	camera.transform = saved
	camera.make_current()


func _guard_stage(rows: Array[Dictionary], stage: String, expected: Dictionary) -> void:
	var actual := _runtime_snapshot()
	var same := _snapshot_sha(expected) == _snapshot_sha(actual)
	rows.append({"stage":stage, "runtime_guard":same, "changes":_snapshot_diff(expected, actual),
		"world_render":_world_render_info()})
	_check(same, "runtime state changed at " + stage + ": " + str(_snapshot_diff(expected, actual)))


func _set_camera(view: Dictionary) -> Camera3D:
	var camera := chain.camera
	var basis := Basis.from_euler(Vector3(float(view.get("pitch", 0)), float(view.get("yaw", 0)), 0))
	var pose := Transform3D(basis, view["eye"])
	if view.has("target"): pose = Transform3D(Basis.looking_at((view["target"] - view["eye"]).normalized(), Vector3.UP), view["eye"])
	if bool(view.get("cutscene", false)):
		var cut: Cutscene = main.get("cutscene")
		var shots := [{"pos":view["eye"], "look_at":view["target"], "sec":30.0}]
		if not cut.play(chain.world_root, chain.camera, shots, 30.0, Callable(), Callable()):
			_check(false, "actual Cutscene camera could not start")
			return null
		camera = cut.get("_cam")
		_check(camera != chain.camera and chain.world_view.get_camera_3d() == camera, "Cutscene did not own actual WorldView camera")
	camera.global_transform = pose
	camera.make_current()
	return camera


func _set_lighting(camera: Camera3D, view: Dictionary) -> void:
	var lights: LightRig = main.get("lights")
	lights.powerOn = true
	for id: String in lights.state: lights.setLamp(id, id in ["porch", "hall", "kitchen", "landing", "vitya"])
	lights.set_night_immediate(.8)
	lights.update(16.0, camera.global_position, String(view["zone"]), bool(view["outdoor"]))
	var flash: Flashlight = main.get("flashlight")
	flash.on = true
	flash.light.visible = true
	flash.set("_flicker", 0.0)
	flash.set("_body", camera.global_position)
	flash.set("_aim", camera.global_position - camera.global_basis.z * 6.0)
	flash.update(2.0)


func _native_setup_oracle() -> void:
	var stats: Dictionary = controller.call("stats")
	for child: Node in controller.get_children():
		if not child is OccluderInstance3D: continue
		var native := child as OccluderInstance3D
		_check(native.has_meta("environment_occlusion_plane") and native.has_meta("environment_occlusion_source"), "native plane lacks actual source metadata")
		_check(native.occluder is ArrayOccluder3D, "native plane uses an unrelated occluder shape")
		if not native.occluder is ArrayOccluder3D: continue
		var vertices := native.occluder.get_vertices()
		var indices := native.occluder.get_indices()
		_check(vertices.size() > 0 and indices.size() > 0 and indices.size() % 3 == 0, "empty/invalid actual ArrayOccluder")
		for vertex: Vector3 in vertices: _check(vertex.is_finite(), "nonfinite native occluder vertex")
		for index: int in indices: _check(index >= 0 and index < vertices.size(), "out-of-bounds native occluder index")
		native_planes += 1
		native_triangles += indices.size() / 3
	_check(native_planes > 0 and native_triangles > 0 and int(stats.get("sources", 0)) > 0, "no actual production native cohort")
	_check(native_planes == int(stats.get("planes", -1)) and native_triangles == int(stats.get("triangles", -1)), "actual native arrays differ from reported plane/triangle counts")


func _live_plane_count() -> int:
	var count := 0
	for node: Node in controller.get_children():
		if node is OccluderInstance3D and node.is_visible_in_tree(): count += 1
	return count


func _plane_signature() -> String:
	var rows: Array = []
	for node: Node in controller.get_children():
		if not node is OccluderInstance3D: continue
		rows.append([node.get_instance_id(), _id(node.occluder), node.global_transform, node.top_level,
			node.occluder.get_vertices(), node.occluder.get_indices(), node.get_meta("environment_occlusion_source")])
	return _sha(var_to_bytes(rows))


func _register_meshes() -> void:
	for node: Node in _nodes(main):
		var meshes: Array = []
		if node is MeshInstance3D:
			meshes = node.call("quality_meshes") if node.has_method("quality_meshes") else [node.mesh]
			if node is ForestLodMesh: meshes.append_array([node.near_mesh, node.far_mesh, node.background_mesh])
			elif node is ModelLodMesh: meshes.append_array(node.near_meshes); meshes.append_array(node.far_meshes)
		elif node is MultiMeshInstance3D and node.multimesh != null: meshes = [node.multimesh.mesh]
		for mesh: Mesh in meshes:
			if mesh == null or tracked_meshes.has(mesh.get_instance_id()): continue
			tracked_meshes[mesh.get_instance_id()] = {"mesh":mesh, "sha":_mesh_signature(mesh)}
			if mesh is ArrayMesh and mesh.shadow_mesh != null and not tracked_meshes.has(mesh.shadow_mesh.get_instance_id()):
				tracked_meshes[mesh.shadow_mesh.get_instance_id()] = {"mesh":mesh.shadow_mesh, "sha":_mesh_signature(mesh.shadow_mesh)}


func _mesh_signature(mesh: Mesh) -> String:
	var arrays: Array = []
	for surface in mesh.get_surface_count():
		arrays.append([_mesh_primitive(mesh, surface), mesh.surface_get_arrays(surface), _id(mesh.surface_get_material(surface))])
	if mesh is ArrayMesh:
		arrays.append(["shadow_mesh_id", _id(mesh.shadow_mesh)])
		for packed: Dictionary in mesh.get("_surfaces"):
			arrays.append([packed.get("format"), packed.get("vertex_data"), packed.get("attribute_data"),
				packed.get("skin_data"), packed.get("index_data"), packed.get("lods"), packed.get("aabb")])
	return _sha(var_to_bytes(arrays))


func _mesh_primitive(mesh: Mesh, surface: int) -> int:
	if mesh is ArrayMesh: return mesh.surface_get_primitive_type(surface)
	# PrimitiveMesh emits indexed triangle surfaces; it has no ArrayMesh method.
	if mesh is PrimitiveMesh: return Mesh.PRIMITIVE_TRIANGLES
	var packed := RenderingServer.mesh_get_surface(mesh.get_rid(), surface)
	_check(packed.has("primitive"), "renderer primitive unavailable for " + mesh.get_class())
	return int(packed.get("primitive", -1))


func _cpu_helpers() -> void:
	var checks := 0
	for primitive: PrimitiveMesh in [SphereMesh.new(), BoxMesh.new(), QuadMesh.new(),
			CapsuleMesh.new(), CylinderMesh.new(), PlaneMesh.new()]:
		_check(primitive.get_surface_count() == 1, primitive.get_class() + " surface count")
		_check(_mesh_primitive(primitive, 0) == Mesh.PRIMITIVE_TRIANGLES, primitive.get_class() + " primitive")
		var arrays := primitive.surface_get_arrays(0)
		_check(arrays[Mesh.ARRAY_VERTEX].size() > 0 and arrays[Mesh.ARRAY_INDEX].size() % 3 == 0,
			primitive.get_class() + " actual triangle arrays")
		var signature := _mesh_signature(primitive)
		_check(signature.length() == 64 and signature == _mesh_signature(primitive), primitive.get_class() + " stable source signature")
		checks += 4
	var triangle := ArrayMesh.new()
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arrays[Mesh.ARRAY_NORMAL] = PackedVector3Array([Vector3.BACK, Vector3.BACK, Vector3.BACK])
	arrays[Mesh.ARRAY_TANGENT] = PackedFloat32Array([1,0,0,1, 1,0,0,1, 1,0,0,1])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.DOWN])
	arrays[Mesh.ARRAY_TEX_UV2] = PackedVector2Array([Vector2(.1,.1), Vector2(.8,.1), Vector2(.1,.8)])
	arrays[Mesh.ARRAY_COLOR] = PackedColorArray([Color.RED, Color.GREEN, Color.BLUE])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0,1,2])
	triangle.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var before := _mesh_signature(triangle)
	_check(_mesh_primitive(triangle, 0) == Mesh.PRIMITIVE_TRIANGLES and before == _mesh_signature(triangle), "ArrayMesh stable triangle signature")
	for slot in [Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL, Mesh.ARRAY_TANGENT, Mesh.ARRAY_TEX_UV,
			Mesh.ARRAY_TEX_UV2, Mesh.ARRAY_COLOR, Mesh.ARRAY_INDEX]:
		var changed := arrays.duplicate(true)
		match slot:
			Mesh.ARRAY_VERTEX, Mesh.ARRAY_NORMAL: changed[slot][0] += Vector3(.1,.2,.3)
			Mesh.ARRAY_TANGENT: changed[slot][3] = -1.0
			Mesh.ARRAY_TEX_UV, Mesh.ARRAY_TEX_UV2: changed[slot][0] += Vector2(.03,.04)
			Mesh.ARRAY_COLOR: changed[slot][0] = Color.WHITE
			Mesh.ARRAY_INDEX: changed[slot] = PackedInt32Array([0,2,1])
		var mutated := ArrayMesh.new()
		mutated.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, changed)
		_check(_mesh_signature(mutated) != before, "signature misses source array slot " + str(slot))
		checks += 1
	var line := ArrayMesh.new()
	var line_arrays: Array = []
	line_arrays.resize(Mesh.ARRAY_MAX)
	line_arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT])
	line.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, line_arrays)
	_check(_mesh_primitive(line, 0) == Mesh.PRIMITIVE_LINES, "ArrayMesh lines are not rewritten as triangles")
	var material := StandardMaterial3D.new()
	triangle.surface_set_material(0, material)
	_check(_mesh_signature(triangle) != before, "surface Material ID is absent from signature")
	var material_stamp := _mesh_signature(triangle)
	triangle.shadow_mesh = line
	_check(_mesh_signature(triangle) != material_stamp, "shadow mesh resource ID is absent from signature")
	checks += 4
	# Exercise the complete source helper on actual native nodes, not just its
	# static parser. This fixture has no Main/world build or viewport rendering.
	main = Node3D.new()
	root.add_child(main)
	var body := MeshInstance3D.new()
	body.mesh = BoxMesh.new()
	body.material_override = material
	main.add_child(body)
	var sphere := MeshInstance3D.new()
	sphere.mesh = SphereMesh.new()
	main.add_child(sphere)
	var quad := MeshInstance3D.new()
	quad.mesh = QuadMesh.new()
	main.add_child(quad)
	var source_stamp := _source_signature()
	_check(source_stamp.length() == 64 and source_stamp == _source_signature(), "full native GeometryInstance/material snapshot is stable")
	body.layers = 2
	_check(source_stamp != _source_signature(), "source snapshot misses native render layers")
	body.layers = 1
	material.albedo_color = Color(.2,.3,.4,1)
	_check(source_stamp != _source_signature(), "source snapshot misses BaseMaterial3D parameter mutation")
	_register_meshes()
	_verify_tracked_meshes()
	_check(tracked_meshes.size() == 3, "all native PrimitiveMesh source instances were registered")
	checks += 4
	tracked_meshes.clear()
	main.free()
	main = null
	var camera_view := SubViewport.new()
	camera_view.size = Vector2i(960,540)
	root.add_child(camera_view)
	var camera_parent := Node3D.new()
	camera_parent.transform = Transform3D(Basis.from_euler(Vector3(.3,-.7,.1)).scaled(Vector3(1.1,.7,1.4)), Vector3(4.3,.7,-2.2))
	camera_view.add_child(camera_parent)
	var cpu_camera := Camera3D.new()
	camera_parent.add_child(cpu_camera)
	var other_camera := Camera3D.new()
	camera_view.add_child(other_camera)
	for basis: Basis in [Basis.from_euler(Vector3(sin(22.740736*.9)*.12,.280756237,0)),
			Basis.looking_at(Vector3.BACK), Basis.looking_at(Vector3(1,.2,-3).normalized())]:
		cpu_camera.transform = Transform3D(basis, Vector3(.0650889575,1.68,1.933727622))
		cpu_camera.make_current()
		var saved := cpu_camera.transform
		var camera_before := {"local":cpu_camera.transform, "global":cpu_camera.global_transform}
		other_camera.make_current()
		cpu_camera.global_transform = Transform3D(Basis.from_euler(Vector3(.1,PI,0)), Vector3(-3,.13,10.5))
		_restore_camera_local(cpu_camera, saved)
		var camera_after := {"local":cpu_camera.transform, "global":cpu_camera.global_transform}
		_check(_snapshot_sha(camera_before) == _snapshot_sha(camera_after), "local camera restore changed exact float32 local/global pose")
		_check(camera_view.get_camera_3d() == cpu_camera, "local camera restore did not restore actual current Camera3D")
		_check(_snapshot_diff(camera_before, camera_after).is_empty(), "equal local restore produced runtime field differences")
		checks += 3
	var diff := _snapshot_diff({"pose":cpu_camera.transform, "revision":4}, {"pose":Transform3D.IDENTITY, "revision":5})
	_check(diff.size() == 2 and diff[0]["field"] == "pose" and diff[1]["field"] == "revision"
		and diff[0]["before"].has("serialized_hex"), "runtime field diagnostics omit changed pose/revision facts")
	checks += 1
	for dimensions: Vector2i in [Vector2i(640,360), Vector2i(960,540), Vector2i(1280,720)]:
		var image := Image.create(dimensions.x, dimensions.y, false, Image.FORMAT_RGBA8)
		_check(_image_has_size(image, dimensions), "ordinary preset dimensions falsely rejected: " + str(dimensions))
		_check(not _image_has_size(image, dimensions + Vector2i(1,0)), "wrong viewport dimensions falsely accepted")
		checks += 2
	# A camera snap may alter a stable OFF shadow atlas. Its post-history images
	# are valid references even when the older image differs; a one-byte change
	# in any corresponding first/settled/snap stage still fails exact-zero.
	var stale := Image.create(4,4,false,Image.FORMAT_RGBA8)
	stale.fill(Color(1,0,0,1))
	var references: Dictionary = {}
	for stage_index in MIRROR_IMAGE_STAGES.size():
		var image := Image.create(4,4,false,Image.FORMAT_RGBA8)
		image.fill(Color(float(20 + stage_index) / 255.0, .2, .3, 1))
		references[MIRROR_IMAGE_STAGES[stage_index]] = image
	var repeated := _sequence_differences(references, references.duplicate())
	var prime_deltas := _priming_differences(stale, references)
	for stage: String in MIRROR_IMAGE_STAGES:
		_check(_exact(repeated[stage]), "matching post-history image falsely rejected at " + stage)
		_check(not _exact(prime_deltas[stage]), "priming diagnostics concealed initial-to-common-history drift at " + stage)
		checks += 2
	_check(not _exact(_difference(stale, references["settled"])), "CPU drift fixture does not distinguish the stale pre-history image")
	checks += 1
	for stage: String in ["first", "settled", "snap"]:
		var changed := references.duplicate()
		var image := (references[stage] as Image).duplicate() as Image
		var pixel := image.get_pixel(0,0)
		pixel.r += 1.0 / 255.0
		image.set_pixel(0,0,pixel)
		changed[stage] = image
		var delta: Dictionary = _sequence_differences(references, changed)[stage]
		_check(not _exact(delta) and delta["changed_bytes"] == 1, "one-byte error was hidden by post-history stage matching at " + stage)
		checks += 1
	var missing := references.duplicate()
	missing.erase("settled")
	_check(not _exact(_sequence_differences(references, missing)["settled"]), "missing matched settled image falsely accepted")
	checks += 1
	# Exercise the real viewport setters/settings under Dummy without Main or
	# rendering. This proves API/config restoration, not GPU cache/pixel proof.
	for depth16: bool in [true,false]:
		camera_view.positional_shadow_atlas_size = 1024
		camera_view.positional_shadow_atlas_16_bits = depth16
		camera_view.positional_shadow_atlas_quad_0 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_1
		camera_view.positional_shadow_atlas_quad_1 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_4
		camera_view.positional_shadow_atlas_quad_2 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_16
		camera_view.positional_shadow_atlas_quad_3 = Viewport.SHADOW_ATLAS_QUADRANT_SUBDIV_16
		var saved := _atlas_settings(camera_view)
		camera_view.positional_shadow_atlas_size = 0
		var zero := _atlas_settings(camera_view)
		_check(zero["size"] == 0 and zero["16_bits"] == depth16 and zero["quadrants"] == saved["quadrants"],
			"actual viewport zero-size setter changed depth/quadrant configuration")
		_restore_atlas_size(camera_view, saved)
		_check(_atlas_settings(camera_view) == saved, "actual positional atlas size/bits were not restored exactly")
		checks += 2
	camera_view.free()
	for failure: String in failures: printerr("occlusion capture helpers: ", failure)
	print("occlusion capture helpers: ", "PASS" if failures.is_empty() else "FAIL", " checks=", checks,
		" Mesh types=Sphere/Box/Quad/Capsule/Cylinder/Plane/ArrayMesh; local camera pose/current viewport/field diagnostics/dynamic dimensions/matched-stage stale-baseline and one-byte rejection/actual atlas setters+16-bit restoration; Main not instantiated; GPU cache proof not executed")
	quit(0 if failures.is_empty() else 1)


func _verify_tracked_meshes() -> void:
	for row: Dictionary in tracked_meshes.values():
		_check(_mesh_signature(row["mesh"]) == row["sha"], "source vertex/normal/tangent/UV/UV2/COLOR/indices/nativeLOD/material IDs changed")


func _source_signature() -> String:
	var rows: Array = []
	var meshes: Dictionary = {}
	for node: Node in _nodes(main):
		if not node is GeometryInstance3D: continue
		rows.append([node.get_instance_id(), node.global_transform, node.visible, node.layers, node.cast_shadow,
			_id(node.material_override), _id(node.material_overlay), node.extra_cull_margin, node.lod_bias,
			node.transparency, node.ignore_occlusion_culling, node.visibility_range_begin, node.visibility_range_end,
			node.visibility_range_begin_margin, node.visibility_range_end_margin, node.visibility_range_fade_mode, node.visibility_parent])
		if node is MeshInstance3D:
			rows.append([_id(node.mesh), node.custom_aabb])
			if node.mesh != null:
				for surface in node.mesh.get_surface_count(): rows.append(_id(node.get_surface_override_material(surface)))
			var levels: Array = node.call("quality_meshes") if node.has_method("quality_meshes") else [node.mesh]
			for mesh: Mesh in levels:
				if mesh != null: meshes[mesh.get_instance_id()] = mesh
		elif node is MultiMeshInstance3D and node.multimesh != null:
			rows.append([_id(node.multimesh), _id(node.multimesh.mesh), node.multimesh.buffer,
				node.multimesh.custom_aabb, node.multimesh.instance_count, node.multimesh.visible_instance_count])
			if node.multimesh.mesh != null: meshes[node.multimesh.mesh.get_instance_id()] = node.multimesh.mesh
	for mesh: Mesh in meshes.values(): rows.append([_id(mesh), _mesh_signature(mesh)])
	for material: Material in _materials():
		var parameters: Dictionary = {}
		if material is ShaderMaterial and material.shader != null:
			for uniform: Dictionary in material.shader.get_shader_uniform_list():
				parameters[uniform["name"]] = material.get_shader_parameter(uniform["name"])
		elif material is BaseMaterial3D:
			for property: Dictionary in material.get_property_list():
				if int(property["usage"]) & PROPERTY_USAGE_STORAGE:
					parameters[property["name"]] = material.get(property["name"])
		rows.append([_id(material), _id(material.next_pass), _id(material.shader) if material is ShaderMaterial else 0, parameters])
	for node: Node in _nodes(main):
		if node is Light3D: rows.append([node.get_instance_id(), node.global_transform, node.visible, node.light_energy, node.light_color, node.shadow_enabled])
	return _sha(var_to_bytes(rows))


func _runtime_snapshot() -> Dictionary:
	var player: Player = main.get("player")
	var state: GameState = main.get("state")
	var cut: Cutscene = main.get("cutscene")
	var camera := chain.world_view.get_camera_3d()
	return {"state":state.snapshot(), "revision":state.runtime_revision, "checkpoint":state.checkpoint,
		"player_transform":player.transform, "player_velocity":player.velocity,
		"player_yaw":player.yaw, "player_pitch":player.pitch, "player_yaw_target":player.yaw_target,
		"player_pitch_target":player.pitch_target, "player_enabled":player.enabled,
		"player_height":player.height, "player_height_target":player.height_target,
		"chapter_timers":main.get("chapters").timers.duplicate(true),
		"cutscene_playing":cut.playing, "cutscene_paused":cut.paused, "cutscene_time":cut.time(),
		"current_camera_id":_id(camera), "current_camera_local":camera.transform,
		"current_camera_global":camera.global_transform, "configured_camera_local":chain.camera.transform,
		"configured_camera_global":chain.camera.global_transform, "world_buffer":chain.world_view.size,
		"positional_shadow_atlas":_atlas_settings(chain.world_view)}


func _snapshot_sha(snapshot: Dictionary) -> String:
	return _sha(var_to_bytes(snapshot))


func _snapshot_diff(before: Dictionary, after: Dictionary) -> Array:
	var changes: Array = []
	var keys: Array = before.keys()
	for key: Variant in after:
		if not keys.has(key): keys.append(key)
	for key: Variant in keys:
		var a: Variant = before.get(key)
		var b: Variant = after.get(key)
		if var_to_bytes(a) != var_to_bytes(b):
			changes.append({"field":String(key), "value_equal":a == b, "serialized_equal":false,
				"before":_describe(a), "after":_describe(b)})
	return changes


func _describe(value: Variant) -> Variant:
	if value is Transform3D:
		var columns: Array = [_vector(value.basis.x), _vector(value.basis.y), _vector(value.basis.z)]
		return {"origin":_vector(value.origin), "basis_columns":columns,
			"serialized_hex":var_to_bytes(value).hex_encode()}
	if value is Vector3: return _vector(value)
	if value is Vector2i: return _vector2i(value)
	return value


func _physics_signature() -> String:
	var collision: CollisionWorld = main.get("col")
	var rows: Array = [collision.get("_data"), collision.get("_active")]
	for node: Node in _nodes(main):
		if node is CollisionObject3D:
			rows.append([node.get_instance_id(), node.global_transform, node.collision_layer, node.collision_mask])
		elif node is CollisionShape3D and node.shape != null:
			var properties: Dictionary = {}
			for property: Dictionary in node.shape.get_property_list():
				if int(property["usage"]) & PROPERTY_USAGE_STORAGE: properties[property["name"]] = node.shape.get(property["name"])
			rows.append([node.get_instance_id(), node.global_transform, node.disabled, _id(node.shape), properties])
	return _sha(var_to_bytes(rows))


func _lod_signature() -> Array:
	var rows: Array = []
	for node: Node in _nodes(main):
		if node is EnvironmentLod: rows.append({"node":String(node.get_path()), "level":node.current_level, "mesh_id":_id(node.mesh)})
	return rows


func _materials() -> Array[Material]:
	var seen: Dictionary = {}
	var result: Array[Material] = []
	for node: Node in _nodes(main):
		var meshes: Array = []
		var candidates: Array = []
		if node is MeshInstance3D:
			meshes = node.call("quality_meshes") if node.has_method("quality_meshes") else [node.mesh]
			candidates = [node.material_override, node.material_overlay]
			if node is ForestLodMesh: meshes.append_array([node.near_mesh, node.far_mesh, node.background_mesh])
			elif node is ModelLodMesh:
				meshes.append_array(node.near_meshes); meshes.append_array(node.far_meshes)
				candidates.append_array(node.near_materials); candidates.append_array(node.far_materials)
			if node.mesh != null:
				for surface in node.mesh.get_surface_count(): candidates.append(node.get_surface_override_material(surface))
		elif node is MultiMeshInstance3D and node.multimesh != null:
			meshes = [node.multimesh.mesh]
			candidates = [node.material_override, node.material_overlay]
		for mesh: Mesh in meshes:
			if mesh == null: continue
			for surface in mesh.get_surface_count(): candidates.append(mesh.surface_get_material(surface))
		for material: Material in candidates:
			if material != null and not seen.has(material): seen[material] = true; result.append(material)
	return result


func _hold_time() -> void:
	var regex := RegEx.new()
	regex.compile("\\bTIME\\b")
	var shared: Dictionary = {}
	for material: Material in _materials():
		if not material is ShaderMaterial or material.shader == null or regex.search(material.shader.code) == null: continue
		var shader: Shader = material.shader
		if not shared.has(shader):
			var held := Shader.new()
			held.code = regex.sub(shader.code, "0.0", true)
			shared[shader] = held
		time_overrides.append({"material":material, "shader":shader})
		material.shader = shared[shader]


func _release_time() -> void:
	for row: Dictionary in time_overrides: (row["material"] as ShaderMaterial).shader = row["shader"]
	time_overrides.clear()


func _first_image() -> Image:
	await RenderingServer.frame_post_draw
	var image := chain.world_view.get_texture().get_image()
	var expected := chain.world_view.size
	_check(expected == chain.buffer_size(), "actual WorldView does not match ordinary preset buffer size")
	_check(_image_has_size(image, expected), "actual raw WorldView image missing/wrong dimensions: expected " + str(expected))
	if image == null: return Image.new()
	image.convert(Image.FORMAT_RGBA8)
	return image


func _image_has_size(image: Image, expected: Vector2i) -> bool:
	return image != null and not image.is_empty() and image.get_size() == expected


func _settled_image() -> Image:
	for _frame in 8: await process_frame
	return await _first_image()


func _difference(a: Image, b: Image) -> Dictionary:
	if a == null or b == null or a.is_empty() or b.is_empty() or a.get_size() != b.get_size():
		return {"max":1.0, "mean":1.0, "changed_bytes":-1}
	var x := a.get_data()
	var y := b.get_data()
	if x == y: return {"max":0.0, "mean":0.0, "changed_bytes":0}
	var largest := 0
	var total := 0
	var changed := 0
	for i in x.size():
		var delta := absi(int(x[i]) - int(y[i]))
		largest = maxi(largest, delta)
		total += delta
		if delta != 0: changed += 1
	return {"max":float(largest) / 255.0, "mean":float(total) / float(x.size()) / 255.0, "changed_bytes":changed}


func _exact(delta: Dictionary) -> bool:
	return delta.get("changed_bytes", -1) == 0 and delta.get("max", 1.0) == 0.0 and delta.get("mean", 1.0) == 0.0


func _world_render_info() -> Dictionary:
	var viewport := chain.world_view.get_viewport_rid()
	return {"calls":RenderingServer.viewport_get_render_info(viewport, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"triangles":RenderingServer.viewport_get_render_info(viewport, RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE,
		RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)}


func _nodes(node: Node) -> Array[Node]:
	var result: Array[Node] = [node]
	for child: Node in node.get_children(): result.append_array(_nodes(child))
	return result


func _id(object: Object) -> int:
	return object.get_instance_id() if object != null else 0


func _sha(bytes: PackedByteArray) -> String:
	var hash := HashingContext.new()
	hash.start(HashingContext.HASH_SHA256)
	hash.update(bytes)
	return hash.finish().hex_encode()


func _vector(value: Vector3) -> Array:
	return [value.x, value.y, value.z]


func _vector2i(value: Vector2i) -> Array:
	return [value.x, value.y]


func _check(ok: bool, message: String) -> void:
	if not ok: failures.append(message)


func _cleanup() -> void:
	_release_time()
	tracked_meshes.clear()
	hq_reference = null
	if is_instance_valid(controller):
		controller.call("dispose")
		_check(not chain.world_view.use_occlusion_culling, "dispose failed to restore native viewport flag")
		controller = null
	if is_instance_valid(main): main.free()
	main = null
	chain = null
	await process_frame
	await process_frame


func _finish(stats: Dictionary = {}) -> void:
	if not completed: failures.append("GPU completion sentinel missing")
	var file := FileAccess.open(output.path_join("report.json"), FileAccess.WRITE)
	if file == null: failures.append("cannot write report.json")
	var summary := {"test":"test_environment_occlusion_capture", "actual_main":true, "gpu_executed":completed,
		"renderer":RenderingServer.get_current_rendering_method(), "device":RenderingServer.get_video_adapter_name(),
		"initial_hq_buffer":[SIZE.x,SIZE.y], "buffer_policy":"ordinary per-preset WorldView dimensions, recorded per case",
		"native_planes":native_planes, "native_triangles":native_triangles,
		"completed_cases":records.size(), "expected_cases":18, "records":records, "controller":stats,
		"plane_arrays_sha256":plane_stamp, "physics_sha256":physics_stamp, "passed":failures.is_empty(), "failures":failures,
		"tolerances":{"max_channel_error":0.0, "mean_channel_error":0.0, "changed_bytes":0},
		"clock_hold":"Main and child processing disabled; only ordinary LOD controllers settled explicitly before each pair; builtin TIME held at 0 in copied fixture-local shaders",
		"camera_proof":"first render after enable, opposite-side snap and actual Cutscene/player current-camera switch compared to matching OFF reference",
		"first_frame_controls":"one complete OFF-only priming sequence initializes existing renderer range history; then two complete measured OFF sequences must repeat at every stage including prepared; ON uses the identical OFF preparation/settle8/two snaps/two no-ops and corresponding first/settled/snap references; immediate toggle remains exact-zero; initial and priming pixels remain diagnostics",
		"cache_isolation":"fixture-only before every mirrored sequence: native OFF, original positional atlas size to 0, two real post-draws, restore exact size/16-bit/quadrants, then the identical settle8/camera history; production quality/settings unchanged",
		"scope":"raw WorldView pixel equivalence; FPS/route acceptance and shutdown resource cleanliness remain separate"}
	if file != null: file.store_string(JSON.stringify(summary, "\t")); file.close()
	for failure: String in failures: printerr("test_environment_occlusion_capture: ", failure)
	print("test_environment_occlusion_capture: ", "PASS" if failures.is_empty() else "FAIL", " cases=", records.size(), " failures=", failures.size())
	quit(0 if failures.is_empty() else 1)

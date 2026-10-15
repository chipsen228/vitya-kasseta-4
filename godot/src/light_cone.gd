# Дешёвый объёмный луч для Compatibility. Геометрия одна на профиль,
# материал один на профиль; владельцы двигают только MeshInstance3D.
class_name LightCone
extends RefCounted

const SHADER_PATH := "res://shaders/light_cone.gdshader"
const HALO_SHADER_PATH := "res://shaders/light_halo.gdshader"
const POOL_SHADER_PATH := "res://shaders/light_pool.gdshader"

# Все художественные параметры лучей собраны здесь. 0xffbd72 соответствует
# примерно 2500 K и оставляет лампам тёплый остров на холодном фоне.
const LAMP_IDS := [
	"porch", "office-porch", "stop", "booth", "lane-pole", "lane-pole-2",
	"barn-gate", "pump-lane", "snt-gate", "snt-lane", "snt-booth",
]
const LAMP_COLOR := 0xffbd72
const LAMP_LENGTH := 5.4
const LAMP_ANGLE := 23.0
const LAMP_BRIGHTNESS := 0.22

const FLASHLIGHT_COLOR := 0xffe0ad
const FLASHLIGHT_LENGTH := 10.0
const FLASHLIGHT_ANGLE := 17.0
const FLASHLIGHT_BRIGHTNESS := 0.018

const HEADLIGHT_COLOR := 0xffd59a
const HEADLIGHT_LENGTH := 11.0
const HEADLIGHT_ANGLE := 10.0
const HEADLIGHT_BRIGHTNESS := 0.22

const EDGE_SOFTNESS := 0.58
const INTERSECTION_SOFTNESS := 0.42
const SEGMENTS := 16

# Ореол растёт в мировых метрах с расстоянием, но теряет энергию. Так дальний
# фонарь остаётся точкой маршрута в тумане, а лампа у лица не закрывает кадр.
const HALO_DISTANCE_NEAR := 2.0
const HALO_DISTANCE_FAR := 42.0
const HALO_SIZE_NEAR := 0.46
const HALO_SIZE_FAR := 2.10
const HALO_STRENGTH_NEAR := 0.52
const HALO_STRENGTH_FAR := 0.20
const HALO_MIN_VISIBLE_DISTANCE := 0.65

# Пятно лежит поверх земли и не участвует в освещении/тенях. Фактический
# рельеф продолжает освещать OmniLight3D, quad добавляет мягкий яркий центр.
const LAMP_POOL_SIZE := Vector2(4.2, 4.2)
const LAMP_POOL_STRENGTH := 0.34
const HEADLIGHT_POOL_SIZE := Vector2(5.6, 1.7)
const HEADLIGHT_POOL_STRENGTH := 0.20
const POOL_Y_OFFSET := 0.018

static var _mesh_cache: Dictionary = {}
static var _material_cache: Dictionary = {}
static var _quad_cache: Dictionary = {}
static var _halo_material_cache: Dictionary = {}
static var _pool_material_cache: Dictionary = {}


static func make_lamp(node_name: String) -> MeshInstance3D:
	return _make(node_name, "lamp", LAMP_COLOR, LAMP_LENGTH, LAMP_ANGLE,
		LAMP_BRIGHTNESS)


static func make_flashlight(node_name: String) -> MeshInstance3D:
	return _make(node_name, "flashlight", FLASHLIGHT_COLOR, FLASHLIGHT_LENGTH,
		FLASHLIGHT_ANGLE, FLASHLIGHT_BRIGHTNESS)


static func make_headlight(node_name: String) -> MeshInstance3D:
	return _make(node_name, "headlight", HEADLIGHT_COLOR, HEADLIGHT_LENGTH,
		HEADLIGHT_ANGLE, HEADLIGHT_BRIGHTNESS)


static func make_lamp_halo(node_name: String) -> MeshInstance3D:
	return _make_halo(node_name, "lamp", LAMP_COLOR)


static func make_flashlight_halo(node_name: String) -> MeshInstance3D:
	return _make_halo(node_name, "flashlight", FLASHLIGHT_COLOR)


static func make_headlight_halo(node_name: String) -> MeshInstance3D:
	return _make_halo(node_name, "headlight", HEADLIGHT_COLOR)


static func make_lamp_pool(node_name: String) -> MeshInstance3D:
	return _make_pool(node_name, "lamp", LAMP_COLOR, LAMP_POOL_SIZE,
		LAMP_POOL_STRENGTH)


static func make_headlight_pool(node_name: String) -> MeshInstance3D:
	return _make_pool(node_name, "headlight", HEADLIGHT_COLOR, HEADLIGHT_POOL_SIZE,
		HEADLIGHT_POOL_STRENGTH)


static func update_halo(halo: MeshInstance3D, origin: Vector3, camera_pos: Vector3,
		intensity := 1.0) -> void:
	var distance := origin.distance_to(camera_pos)
	halo.position = origin
	halo.set_instance_shader_parameter("halo_size",
		halo_size_at_distance(distance))
	halo.set_instance_shader_parameter("halo_strength",
		halo_strength_at_distance(distance) * clampf(intensity, 0.0, 1.0))


static func halo_size_at_distance(distance: float) -> float:
	var t := clampf((distance - HALO_DISTANCE_NEAR) /
		(HALO_DISTANCE_FAR - HALO_DISTANCE_NEAR), 0.0, 1.0)
	return lerpf(HALO_SIZE_NEAR, HALO_SIZE_FAR, t)


static func halo_strength_at_distance(distance: float) -> float:
	var t := clampf((distance - HALO_DISTANCE_NEAR) /
		(HALO_DISTANCE_FAR - HALO_DISTANCE_NEAR), 0.0, 1.0)
	return lerpf(HALO_STRENGTH_NEAR, HALO_STRENGTH_FAR, t)


static func place_pool(pool: MeshInstance3D, center: Vector3, intensity := 1.0) -> void:
	pool.position = center
	pool.set_instance_shader_parameter("pool_strength", clampf(intensity, 0.0, 1.0))


static func aim(cone: Node3D, origin: Vector3, target: Vector3) -> void:
	var direction := target - origin
	if direction.length_squared() < 0.000001:
		cone.position = origin
		return
	var up := Vector3.UP
	if absf(direction.normalized().y) > 0.999:
		up = Vector3.FORWARD
	cone.look_at_from_position(origin, target, up)


static func _make(node_name: String, profile: String, color_hex: int, length: float,
		angle: float, brightness: float) -> MeshInstance3D:
	var cone := MeshInstance3D.new()
	cone.name = node_name
	cone.mesh = _mesh(profile, length, angle)
	cone.material_override = _material(profile, color_hex, length, brightness)
	cone.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	cone.extra_cull_margin = 0.25
	cone.visible = false
	return cone


static func _mesh(profile: String, length: float, angle: float) -> ArrayMesh:
	if _mesh_cache.has(profile):
		return _mesh_cache[profile] as ArrayMesh
	var radius := tan(deg_to_rad(angle)) * length
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in SEGMENTS:
		var a0 := TAU * float(i) / float(SEGMENTS)
		var a1 := TAU * float(i + 1) / float(SEGMENTS)
		var p0 := Vector3(cos(a0) * radius, sin(a0) * radius, -length)
		var p1 := Vector3(cos(a1) * radius, sin(a1) * radius, -length)
		st.set_uv(Vector2(0.5, 0.0))
		st.add_vertex(Vector3.ZERO)
		st.set_uv(Vector2(float(i) / float(SEGMENTS), 1.0))
		st.add_vertex(p0)
		st.set_uv(Vector2(float(i + 1) / float(SEGMENTS), 1.0))
		st.add_vertex(p1)
	st.generate_normals()
	var mesh := st.commit()
	_mesh_cache[profile] = mesh
	return mesh


static func _material(profile: String, color_hex: int, length: float,
		brightness: float) -> ShaderMaterial:
	if _material_cache.has(profile):
		return _material_cache[profile] as ShaderMaterial
	var material := ShaderMaterial.new()
	material.shader = load(SHADER_PATH) as Shader
	material.set_shader_parameter("beam_color", GameData.color(color_hex))
	material.set_shader_parameter("beam_length", length)
	material.set_shader_parameter("brightness", brightness)
	material.set_shader_parameter("edge_softness", EDGE_SOFTNESS)
	material.set_shader_parameter("intersection_softness", INTERSECTION_SOFTNESS)
	material.render_priority = 1
	_material_cache[profile] = material
	return material


static func _make_halo(node_name: String, profile: String, color_hex: int) -> MeshInstance3D:
	var halo := MeshInstance3D.new()
	halo.name = node_name
	halo.mesh = _quad("halo")
	halo.material_override = _halo_material(profile, color_hex)
	halo.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	halo.extra_cull_margin = HALO_SIZE_FAR
	halo.visible = false
	return halo


static func _make_pool(node_name: String, profile: String, color_hex: int,
		size: Vector2, strength: float) -> MeshInstance3D:
	var pool := MeshInstance3D.new()
	pool.name = node_name
	pool.mesh = _quad("pool")
	pool.material_override = _pool_material(profile, color_hex)
	pool.rotation.x = -PI / 2.0
	pool.scale = Vector3(size.x, size.y, 1.0)
	pool.set_instance_shader_parameter("pool_strength", strength)
	pool.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pool.extra_cull_margin = maxf(size.x, size.y)
	pool.visible = false
	return pool


static func _quad(key: String) -> QuadMesh:
	if _quad_cache.has(key):
		return _quad_cache[key] as QuadMesh
	var quad := QuadMesh.new()
	quad.size = Vector2.ONE
	_quad_cache[key] = quad
	return quad


static func _halo_material(profile: String, color_hex: int) -> ShaderMaterial:
	if _halo_material_cache.has(profile):
		return _halo_material_cache[profile] as ShaderMaterial
	var material := ShaderMaterial.new()
	material.shader = load(HALO_SHADER_PATH) as Shader
	material.set_shader_parameter("halo_color", GameData.color(color_hex))
	material.render_priority = 2
	_halo_material_cache[profile] = material
	return material


static func _pool_material(profile: String, color_hex: int) -> ShaderMaterial:
	if _pool_material_cache.has(profile):
		return _pool_material_cache[profile] as ShaderMaterial
	var material := ShaderMaterial.new()
	material.shader = load(POOL_SHADER_PATH) as Shader
	material.set_shader_parameter("pool_color", GameData.color(color_hex))
	material.render_priority = 0
	_pool_material_cache[profile] = material
	return material

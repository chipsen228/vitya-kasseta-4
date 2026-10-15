# Фонарь. Порт src/engine/flashlight.js. Две отдельные вещи, которые нельзя путать:
#
#   1. Источник света — ребёнок мира, а не камеры. Корпус догоняет камеру
#      с коэффициентом 20, цель луча — с коэффициентом 9. Это отставание и читается
#      как «фонарь в руке», а не «прожектор, приклеенный ко лбу».
#
#   2. Модель фонаря живёт в отдельном мире (HandView) и рисуется камерой с FOV 45
#      поверх мирового прохода с FOV 70. Из-за разницы FOV модель физически
#      не может занять пол-экрана — ровно та болезнь, которой страдала прежняя сборка.
#
# Cookie конуса в Compatibility штатным light_projector не берётся, поэтому его
# сэмплит вручную psx.gdshader, а матрицу проектора, позицию и «горит/не горит»
# сюда же кладёт этот файл — глобальными uniform'ами.
class_name Flashlight
extends Node

const BEAM_COLOR := 0xffe6bf
const BEAM_RANGE := 18.0
const BEAM_ANGLE := 17.0          # градусы, полуугол конуса — как angle в three.js
const BEAM_PENUMBRA := 0.55
const BEAM_DECAY := 1.35
const DRAIN := 0.062              # процентов в секунду; на полную игру хватает с запасом

# В three.js bias вычитается из глубины, поэтому там он отрицательный;
# у Godot знак противоположный, переносим модуль.
#
# Фаза 8. Перенесённые из прототипа 0.0016 / 0.022 давали то самое «рябит
# в темноте с фонарём»: psx.gdshader снапает вершины в сетку 192×144, теневой
# проход расходится с основным, и акне ползёт вместе с инерционным корпусом
# фонаря. Луне по той же причине понадобились 0.09 / 2.4 (lights.gd:61-62);
# у фонаря дальность 18 м против 55, отсюда числа меньше — подобраны замером
# ряби (tests/ripple.gd), а не на глаз.
const SHADOW_BIAS := 0.018
const SHADOW_NORMAL_BIAS := 0.32

# Единственная ручка на случай, если яркость Godot разойдётся с candela three.js:
# формула intensity ниже перенесена дословно, крутить надо здесь.
const ENERGY_SCALE := 1.0

# 0.20 вправо, 0.17 вниз, 0.40 от камеры — примерно 18% ширины кадра при FOV 45.
const MODEL_POS := Vector3(0.20, -0.17, -0.40)

var chain: RenderChain = null

var on := false
var owned := false
var battery := 100.0

var light: SpotLight3D = null
var cone: MeshInstance3D = null
var halo: MeshInstance3D = null
var model: Node3D = null

var _body := Vector3(0, 1.5, 0)
var _aim := Vector3(0, 1.5, -1)
var _flicker := 0.0
var _shake := 0.0
var _visual_rng := RandomNumberGenerator.new()
var _sway := Vector2.ZERO
var _sway_target := Vector2.ZERO
# Состояние прошлого кадра: тень, проектор и матрица конуса. Всё три — команды
# рендер-серверу, и писать их каждый кадр одинаковыми незачем.
var _shadow_on := false
var _proj_on := false
var _proj_cone: Variant = null
var _model_base := MODEL_POS
var _glass_mat: StandardMaterial3D = null
var _psx: Shader = null
# Видимость модели определяет HeldItems. Луч и выбранная вьюмодель — разные
# состояния: фонарик можно держать выключенным.
var _viewmodel_selected := false
var _cinematic_suppressed := false


func _init(render_chain: RenderChain = null) -> void:
	# Глобальные uniform'ы должны существовать до компиляции psx.gdshader.
	RenderChain.register_shader_globals()
	chain = render_chain
	_visual_rng.seed = 198804


func _ready() -> void:
	if chain != null and light == null:
		build(chain)


func build(render_chain: RenderChain) -> void:
	chain = render_chain
	# Цепочка собирает вьюпорты в своём _ready(): фонарь обязан появиться позже неё.
	if chain == null or chain.world_root == null or chain.hand_root == null:
		push_error("Flashlight.build: RenderChain ещё не в дереве — добавить её раньше фонаря")
		return
	_psx = load("res://shaders/psx.gdshader")

	light = SpotLight3D.new()
	light.name = "FlashlightBeam"
	light.light_color = GameData.color(BEAM_COLOR)
	light.light_energy = 0.0
	light.spot_range = BEAM_RANGE
	light.spot_angle = BEAM_ANGLE
	light.spot_angle_attenuation = BEAM_PENUMBRA
	light.spot_attenuation = BEAM_DECAY
	light.shadow_enabled = true
	light.shadow_bias = SHADOW_BIAS
	light.shadow_normal_bias = SHADOW_NORMAL_BIAS
	light.position = _body
	chain.world_root.add_child(light)
	cone = LightCone.make_flashlight("FlashlightCone")
	chain.world_root.add_child(cone)
	halo = LightCone.make_flashlight_halo("FlashlightHalo")
	chain.world_root.add_child(halo)

	model = _build_model()
	model.visible = false
	chain.hand_root.add_child(model)


# ---------- вьюмодель ----------

# Примитивы и цифры перенесены из _buildModel() один в один: под этим фильтром
# фонарь — это восемь цилиндров и коробок, и переделывать их не во что.
func _build_model() -> Node3D:
	var g := Node3D.new()
	g.name = "FlashlightModel"

	var body_mat := _psx_mat(0x2b2f33)
	var ring_mat := _psx_mat(0x6d6a5f)
	var skin := _psx_mat(0x8d6a55)

	_glass_mat = StandardMaterial3D.new()
	_glass_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_glass_mat.albedo_color = Color(GameData.color(0xfff0cc), 0.85)

	var tube := _mesh(_cylinder(0.019, 0.021, 0.155, 8), body_mat)
	tube.rotation.x = PI / 2.0 - 0.16
	tube.position = Vector3(0, 0, 0.02)
	g.add_child(tube)

	var head := _mesh(_cylinder(0.032, 0.021, 0.048, 8), ring_mat)
	head.rotation.x = PI / 2.0 - 0.16
	head.position = Vector3(0, 0.016, -0.078)
	g.add_child(head)

	var glass := _mesh(_disc(0.029, 8), _glass_mat)
	glass.rotation.x = -0.16
	glass.position = Vector3(0, 0.020, -0.100)
	g.add_child(glass)

	var grip := _mesh(_cylinder(0.023, 0.023, 0.05, 8), _psx_mat(0x1d1f21))
	grip.rotation.x = PI / 2.0 - 0.16
	grip.position = Vector3(0, -0.006, 0.062)
	g.add_child(grip)

	# Запечённая кисть сохраняет отдельные пальцы и большой палец.
	var palm := _mesh(ObjectGeometry.shared("object/hand"), skin)
	palm.position = Vector3(0.008, -0.020, 0.075)
	# Порядок эйлеров у three.js по умолчанию XYZ, у Godot — YXZ. Для рук
	# с двумя ненулевыми осями разница видна, поэтому ставим порядок явно.
	palm.rotation_order = EULER_ORDER_XYZ
	palm.rotation = Vector3(PI * 0.5 + 0.14, 0, -0.12)
	palm.scale = Vector3(0.9, 0.9, 0.9)
	g.add_child(palm)


	var cuff := _mesh(ObjectGeometry.bevel_box(Vector3(0.068, 0.055, 0.045), 0.005), _psx_mat(0x3a4148))
	cuff.position = Vector3(0.012, -0.022, 0.128)
	g.add_child(cuff)

	g.rotation_order = EULER_ORDER_XYZ
	g.position = MODEL_POS
	g.rotation = Vector3(0.0, 0.10, 0.0)
	return g


func _psx_mat(hex: int) -> ShaderMaterial:
	var m := ShaderMaterial.new()
	m.shader = _psx
	m.set_shader_parameter("albedo", GameData.color(hex))
	# Рука светится своим светом в своём мире: cookie мирового фонаря ей ни к чему.
	m.set_shader_parameter("psx_cookie", 0.0)
	return m


func _mesh(m: Mesh, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = m
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return mi


func _cylinder(top_r: float, bottom_r: float, h: float, seg: int) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = top_r
	c.bottom_radius = bottom_r
	c.height = h
	c.radial_segments = seg
	c.rings = 1
	return c


func _box(x: float, y: float, z: float) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = Vector3(x, y, z)
	return b


# Аналог THREE.CircleGeometry: восьмиугольник в плоскости XY лицом к +Z.
# Готового «диска» в Godot нет, а PlaneMesh — квадрат.
func _disc(r: float, seg: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		st.set_normal(Vector3(0, 0, 1))
		st.set_uv(Vector2(0.5, 0.5))
		st.add_vertex(Vector3.ZERO)
		st.set_normal(Vector3(0, 0, 1))
		st.set_uv(Vector2(0.5 + 0.5 * cos(a0), 0.5 - 0.5 * sin(a0)))
		st.add_vertex(Vector3(r * cos(a0), r * sin(a0), 0.0))
		st.set_normal(Vector3(0, 0, 1))
		st.set_uv(Vector2(0.5 + 0.5 * cos(a1), 0.5 - 0.5 * sin(a1)))
		st.add_vertex(Vector3(r * cos(a1), r * sin(a1), 0.0))
	return st.commit()

# ---------- поведение ----------

func toggle() -> bool:
	if not owned:
		return false
	if not on and battery <= 0.0:
		return false
	on = not on
	return true


func give() -> void:
	owned = true


func set_viewmodel_selected(selected: bool) -> void:
	_viewmodel_selected = selected
	if model != null:
		model.visible = owned and selected and not _cinematic_suppressed


## Suppress both beam and viewmodel for a cinematic. This deliberately leaves
## `on`, `owned`, battery and the held-item selection untouched.
func set_cinematic_suppressed(suppressed: bool) -> void:
	_cinematic_suppressed = suppressed
	if model != null:
		model.visible = owned and _viewmodel_selected and not suppressed
	# The cinematic freezes update(), so render state must change here.
	# Hiding the light also suspends its shadow pass without invalidating
	# the shadow_enabled cache or changing the player's battery/on state.
	if light != null:
		light.visible = not suppressed
		_push_projector()
	if suppressed:
		if cone != null:
			cone.visible = false
		if halo != null:
			halo.visible = false


## Короткое мигание — используется, когда луч попадает во что-то важное.
func flicker(seconds := 0.35) -> void:
	_flicker = maxf(_flicker, seconds)


## Встряска модели: испуг, падение крышки люка, удар.
func shake(amount := 1.0) -> void:
	_shake = maxf(_shake, amount)


func update(dt: float, player = null) -> void:
	if light == null:
		return

	if on and not _cinematic_suppressed:
		battery = maxf(0.0, battery - dt * DRAIN)
		if battery <= 0.0:
			on = false

	var cam := chain.camera
	var dir := -cam.global_transform.basis.z  # getWorldDirection()

	# Корпус догоняет камеру, цель — медленнее корпуса. Отсюда «рука отстаёт».
	var k_body := 1.0 - exp(-dt * 20.0)
	var k_aim := 1.0 - exp(-dt * 9.0)

	var cam_pos := cam.global_position
	var right := cam.global_transform.basis.x
	var up := cam.global_transform.basis.y
	var emitter := cam_pos + right * 0.17 - up * 0.13 + dir * 0.18
	var hold_x := emitter.x
	var hold_y := emitter.y
	var hold_z := emitter.z
	_body.x += (hold_x - _body.x) * k_body
	_body.y += (hold_y - _body.y) * k_body
	_body.z += (hold_z - _body.z) * k_body

	var aim_x := cam_pos.x + dir.x * 6.0
	var aim_y := cam_pos.y + dir.y * 6.0
	var aim_z := cam_pos.z + dir.z * 6.0
	_aim.x += (aim_x - _aim.x) * k_aim
	_aim.y += (aim_y - _aim.y) * k_aim
	_aim.z += (aim_z - _aim.z) * k_aim
	_look(_body, _aim)

	# Яркость: разряд плюс редкое подмигивание контакта.
	var intensity := 0.0
	if on:
		var charge := 0.42 + 0.58 * minf(1.0, battery / 55.0)
		var wobble := 1.0
		var now := float(Time.get_ticks_msec())
		if _flicker > 0.0:
			_flicker -= dt
			wobble = 0.25 + 0.75 * absf(sin(now * 0.06))
		elif battery < 22.0:
			wobble = 0.75 + 0.25 * sin(now * 0.008)
		intensity = 14.0 * charge * wobble * ENERGY_SCALE
	light.light_energy += (intensity - light.light_energy) * (1.0 - exp(-dt * 26.0))
	# Запись shadow_enabled уходит в RenderingServer ВСЕГДА, даже когда значение
	# то же самое. Отсечка по равенству снимает шестьдесят команд серверу
	# в секунду за кадры, в которых фонарь просто горит.
	var want_shadow := light.light_energy > 0.4
	if want_shadow != _shadow_on:
		_shadow_on = want_shadow
		light.shadow_enabled = want_shadow
	if cone != null:
		cone.global_transform = light.global_transform
		cone.visible = chain.render_preset() == RenderChain.PRESET_HQ and want_shadow \
			and not _cinematic_suppressed
		var cone_material := cone.material_override as ShaderMaterial
		cone_material.set_shader_parameter("brightness", LightCone.FLASHLIGHT_BRIGHTNESS
			* clampf(light.light_energy / (14.0 * ENERGY_SCALE), 0.0, 1.0))
	if halo != null:
		var halo_intensity := clampf(light.light_energy / (14.0 * ENERGY_SCALE), 0.0, 1.0)
		var halo_distance := _body.distance_to(cam_pos)
		halo.visible = chain.render_preset() == RenderChain.PRESET_HQ and want_shadow \
			and not _cinematic_suppressed and halo_distance >= LightCone.HALO_MIN_VISIBLE_DISTANCE
		if halo.visible:
			LightCone.update_halo(halo, _body, cam_pos, halo_intensity)

	_push_projector()

	# Модель в руках. То же правило: видимость меша дёргает сервер сцены,
	# и писать её каждый кадр незачем.
	var want_model := owned and _viewmodel_selected and not _cinematic_suppressed
	if want_model != model.visible:
		model.visible = want_model
	if _glass_mat != null and want_model:
		_glass_mat.albedo_color = Color(_glass_mat.albedo_color, 0.85 if on else 0.1)

	if model.visible and player != null:
		_sway_target = Vector2(
			clampf((player.yaw_target - player.yaw) * 2.4, -0.06, 0.06),
			clampf((player.pitch_target - player.pitch) * 2.4, -0.06, 0.06))
		var k_sway := 1.0 - exp(-dt * 9.0)
		_sway.x += (_sway_target.x - _sway.x) * k_sway
		_sway.y += (_sway_target.y - _sway.y) * k_sway

		var bob: float = player.bob_amount
		var ph: float = player.bob_phase
		_shake = maxf(0.0, _shake - dt * 3.2)
		var sh := _shake * 0.03

		model.position = Vector3(
			_model_base.x - _sway.x + sin(ph) * 0.010 * bob + (_visual_rng.randf() - 0.5) * sh,
			_model_base.y - _sway.y + absf(sin(ph)) * 0.012 * bob + (_visual_rng.randf() - 0.5) * sh,
			_model_base.z)
		model.rotation = Vector3(
			_sway.y * 1.2,
			model.rotation.y,
			-_sway.x * 1.6 + sin(ph) * 0.02 * bob)


## У SpotLight3D нет объекта-цели: направление задаёт собственный поворот.
## Взгляд вертикально вверх/вниз для look_at вырожден — там берём другую опору.
func _look(from: Vector3, to: Vector3) -> void:
	var d := to - from
	if d.length_squared() < 1e-8:
		light.global_position = from
		return
	var up := Vector3.UP
	if absf(d.normalized().y) > 0.999:
		up = Vector3.FORWARD
	light.look_at_from_position(from, to, up)


## Матрица «мир -> клип конуса» для ручной выборки cookie в psx.gdshader.
## near/far на UV не влияют (x/w от них не зависит), берём рабочие.
func _push_projector() -> void:
	var lit := on and not _cinematic_suppressed and light.light_energy > 0.4
	if lit != _proj_on:
		_proj_on = lit
		RenderChain.set_shader_global("flashlight_on", 1.0 if lit else 0.0)
	if not lit:
		return
	# Матрица проекции конуса зависит только от констант BEAM_ANGLE/BEAM_RANGE,
	# и считать её заново каждый кадр незачем: меняется в ней только вторая
	# половина — обратное преобразование фонаря.
	if _proj_cone == null:
		_proj_cone = Projection.create_perspective(BEAM_ANGLE * 2.0, 1.0, 0.05, BEAM_RANGE)
	RenderChain.set_shader_global(
		"flashlight_proj",
		(_proj_cone as Projection) * Projection(light.global_transform.affine_inverse()))
	RenderChain.set_shader_global("flashlight_pos", light.global_position)


func snapshot() -> Dictionary:
	return {"on": on, "owned": owned, "battery": battery}


func restore(s: Dictionary) -> void:
	on = s.get("on", false)
	owned = s.get("owned", false)
	battery = s.get("battery", 100.0)

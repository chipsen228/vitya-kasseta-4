# Контроллер игрока от первого лица — порт src/engine/controls.js.
#
# Дословно перенесены: все константы, экспоненциальные сглаживания через
# exp(-dt/tau) (иначе поворот и разгон зависят от частоты кадров), проекция
# скорости в плоскость пола вместе с прижимом, покачивание по пройденному пути,
# стамина и порядок действий внутри кадра — он важен: и «на полу», и нормаль
# пола берутся от ПРОШЛОГО кадра, как в оригинале.
#
# Чего в порте нет намеренно: защит браузерного pointer lock (MOUSE_JUMP_MAX,
# LOCK_SETTLE, unadjustedMovement). Они лечили выбросы movementX, которые выдаёт
# сам браузер при перезахвате курсора и смене окна; MOUSE_MODE_CAPTURED отдаёт
# дельты устройства и таких выбросов не даёт.
#
# Столкновения отданы move_and_slide (Jolt) вместо пяти подшагов с октодеревом:
# подшаги страховали от проскока сквозь ступеньку, а у Godot движение и так
# свипованное. Формулы разгона, скорости и прижима — прежние.
class_name Player
extends CharacterBody3D

const STAND_HEIGHT := 1.78
const CROUCH_HEIGHT := 1.24
const RADIUS := 0.30
const EYE_DROP := 0.10          # глаза ниже макушки

const SPEED_WALK := 1.55
const SPEED_CROUCH := 0.80
const SPEED_RUN := 3.05

const ACCEL_K := 14.0           # 90% скорости за 0.16 с
const DECEL_K := 11.0
const GRAVITY := 22.0           # «игровая» тяжесть отзывчивее честных 9.81
# Прижим к полу: ровно стоящая капсула иначе перестаёт касаться геометрии и
# флаг «на полу» мигает через кадр. Больше 0.5 нельзя — на пандусе лестницы
# капсулу вдавливает в ступени и выталкивает по нормали назад.
const GROUND_STICK := 0.35

const STEP_LENGTH := 0.78       # метров на шаг
const MOUSE_BASE := 0.0022      # рад/пиксель
const PITCH_LIMIT := 85.0 * PI / 180.0

# Сглаживание взгляда. 0 — сырой ввод, 1 — максимально мягко; в секундах это
# от 6 до 70 мс постоянной времени. Меньше 6 мс смысла не имеет: мышь
# опрашивается чаще кадра, и разное число сэмплов на кадр даёт микродрожь.
const LOOK_TAU_MIN := 0.006
const LOOK_TAU_MAX := 0.070
const LOOK_SMOOTH_DEFAULT := 0.45

const STAMINA_MAX := 6.5
const STAMINA_REGEN := 2.2

# Порог «это пол» для собранных за кадр касаний и он же cos(floor_max_angle):
# два разных порога развели бы «на полу» и «скользим по стене».
#
# 65° -> 68° (фаза 7). Число не круглое и не на глаз: на кромке борта пандуса
# лестницы нормаль даёт 67.2°, то есть по правилам движка это была стена,
# и войти на марш сбоку не получалось — не хватало 2.3 сантиметра. Скаты крыш
# положе (30° у дома, 48° у пристройки) и были проходимы и до правки, так что
# новых мест, куда игрок «залезет, куда не должен», это не открывает.
const FLOOR_NORMAL_MIN := 0.3746          # cos(68°)
const FLOOR_MAX_ANGLE := 68.0 * PI / 180.0
const FLOOR_SNAP := 0.35

# Шаг вверх без прыжка. 0.25 — не выдумка: ровно из этого числа (STEP 0.25,
# CLIMB 0.36) исходит tests/audit_reach.gd, когда заливает уровень и решает,
# куда игрок дойдёт. До фазы 7 аудит проверял способность, которой в рантайме
# не было ни строчки: прыжка в input map нет вовсе, а move_and_slide сам
# на ступеньку не поднимает.
const STEP_UP := 0.25
const STEP_PROBE := 0.08                  # минимальная проба вперёд, м
const STEP_MIN := 0.005                   # ниже этого подъём не стоит кадра

# Маски: бит 1 — мир (статика, блокеры, реквизит), бит 2 — сам игрок.
const MASK_WORLD := 1
const LAYER_PLAYER := 2

# Проба на разгиб приподнята над подошвой. У оригинала пробная капсула стояла
# ровно на ногах, и касание пола отсекалось нулевой глубиной пересечения; у
# физического запроса такой поблажки нет — пол попал бы в пробу и запер игрока
# в приседе навсегда. Первые два сантиметра и так заняты текущей капсулой.
const STAND_PROBE_LIFT := 0.02

signal step(run: bool, crouch: bool)
signal land

# --- настройки (крутит меню) ---
var sensitivity := 0.8
var invert_y := false
var look_smooth := LOOK_SMOOTH_DEFAULT

# --- состояние, которое читают другие модули ---
var enabled := false            # выключен — кадр не считается вовсе
var frozen := false             # ноги связаны сюжетом: взгляд есть, ходьбы нет
var speed_scale := 1.0
var yaw := 0.0
var pitch := 0.0
var yaw_target := 0.0
var pitch_target := 0.0
var on_floor := false
var crouching := false
var running := false
var stamina := STAMINA_MAX
var height := STAND_HEIGHT
var height_target := STAND_HEIGHT
var travelled := 0.0
var bob_amount := 0.0
var bob_phase := 0.0

# Камера живёт в render_chain и в иерархию игрока не входит: её кладёт сюда
# lead после сборки цепочки рендера.
var camera: Camera3D = null

var _floor_n := Vector3.UP
var _last_step_phase := 0
var _shape: CollisionShape3D = null
var _capsule: CapsuleShape3D = null
var _stand_probe: ShapeCast3D = null


func _init() -> void:
	# Ноги — в начале координат ноды: place() и feet() тогда работают с той же
	# точкой, что и данные прототипа (SPAWN, HATCHES, укрытия — все по ногам).
	motion_mode = CharacterBody3D.MOTION_MODE_GROUNDED
	up_direction = Vector3.UP
	floor_max_angle = FLOOR_MAX_ANGLE
	floor_snap_length = FLOOR_SNAP
	floor_constant_speed = true
	collision_layer = LAYER_PLAYER
	collision_mask = MASK_WORLD

	_capsule = CapsuleShape3D.new()
	_capsule.radius = RADIUS
	_capsule.height = STAND_HEIGHT
	_shape = CollisionShape3D.new()
	_shape.name = "Body"
	_shape.shape = _capsule
	_shape.position = Vector3(0.0, STAND_HEIGHT * 0.5, 0.0)

	# Разгиб проверяем полной стоячей капсулой на текущем месте ног — так же,
	# как оригинал клонировал капсулу и поднимал ей конец до STAND_HEIGHT.
	# target_position нулевой: это проба «есть ли место», а не трасса. Свип
	# снизу вверх тут не годится — он стартует внутри пола и упирается в него
	# на нулевой доле пути, то есть отвечает «занято» всегда.
	var probe_shape := CapsuleShape3D.new()
	probe_shape.radius = RADIUS
	probe_shape.height = STAND_HEIGHT - STAND_PROBE_LIFT
	_stand_probe = ShapeCast3D.new()
	_stand_probe.name = "StandProbe"
	_stand_probe.shape = probe_shape
	_stand_probe.position = Vector3(0.0, (STAND_HEIGHT + STAND_PROBE_LIFT) * 0.5, 0.0)
	_stand_probe.target_position = Vector3.ZERO
	_stand_probe.collide_with_areas = false
	_stand_probe.collide_with_bodies = true
	_stand_probe.exclude_parent = true
	_stand_probe.enabled = false     # дёргаем руками, только когда встаём


func _ready() -> void:
	# Повторное добавление в дерево не должно плодить вторую капсулу.
	if _shape.get_parent() == null:
		add_child(_shape)
	if _stand_probe.get_parent() == null:
		add_child(_stand_probe)
	_stand_probe.collision_mask = collision_mask
	# Кадр гонит main.gd, чтобы порядок модулей совпадал с оригиналом.
	set_physics_process(false)
	set_process(false)
	_apply_height()


## Слои мира могут поехать при сборке сцены — тело и проба обязаны видеть одно
## и то же, иначе игрок встанет сквозь потолок.
func set_world_mask(mask: int) -> void:
	collision_mask = mask
	if _stand_probe != null:
		_stand_probe.collision_mask = mask


# ---------- ввод ----------

func _input(event: InputEvent) -> void:
	if not enabled:
		return
	if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		return
	if event is InputEventMouseMotion:
		var m := event as InputEventMouseMotion
		var s := MOUSE_BASE * sensitivity
		yaw_target -= m.relative.x * s
		pitch_target += (m.relative.y if invert_y else -m.relative.y) * s
		pitch_target = clampf(pitch_target, -PITCH_LIMIT, PITCH_LIMIT)


## Захват мыши. Цель приравниваем к текущему углу: иначе накопленное за паузу
## разворачивает камеру рывком в первый же кадр после возврата.
func request_lock() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		return
	yaw_target = yaw
	pitch_target = pitch
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func release_lock() -> void:
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func is_locked() -> bool:
	return Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


# ---------- размещение ----------

## Поставить игрока: ноги в (x, y, z), взгляд по азимуту yaw.
func place(x: float, y: float, z: float, new_yaw: float = 0.0) -> void:
	var p := Vector3(x, y, z)
	# До входа в дерево глобальной системы координат ещё нет, а ставить игрока
	# лид может до add_child — тогда пишем в локальную (родитель у мира единичный).
	if is_inside_tree():
		global_position = p
	else:
		position = p
	velocity = Vector3.ZERO
	yaw = new_yaw
	yaw_target = new_yaw
	# Pitch намеренно не трогаем: в люк смотрят вниз, и выпрямление по горизонту
	# на переходе читается как рывок камеры, которого игрок не просил.
	# Опору обнуляем: с флагом от прошлого кадра первый кадр на новом месте
	# уходит в прижим к полу вместо тяготения — капсула визуально проваливается.
	on_floor = false
	_floor_n = Vector3.UP
	travelled = 0.0
	bob_amount = 0.0
	_last_step_phase = 0
	# Переходы через люк держат update() выключенным до конца fade-up.
	# Новое место должно показываться сразу, независимо от управления.
	if camera != null and is_inside_tree() and camera.is_inside_tree():
		_apply_camera()


## Ноги игрока в мировых координатах.
func feet() -> Vector3:
	return global_position if is_inside_tree() else position


## Точка глаз без покачивания — тем, кому нужна голова, а не подошва.
func eyes() -> Vector3:
	return feet() + Vector3(0.0, height - EYE_DROP, 0.0)


func forward() -> Vector3:
	return Vector3(-sin(yaw) * cos(pitch), sin(pitch), -cos(yaw) * cos(pitch))


# ---------- кадр ----------

func update(dt: float) -> void:
	if not enabled:
		return

	# Сглаживание взгляда. Ловушка, из-за которой оно раньше не работало:
	# tau 0.018 при кадре 16.6 мс даёт коэффициент 0.6 — камера догоняет цель
	# за полтора кадра, то есть фильтра фактически нет. Через exp(-dt/tau)
	# результат не зависит от fps: на 30 и на 144 поворот ощущается одинаково.
	var tau := LOOK_TAU_MIN + (LOOK_TAU_MAX - LOOK_TAU_MIN) * look_smooth
	var k_look := 1.0 - exp(-dt / tau)
	yaw += (yaw_target - yaw) * k_look
	pitch += (pitch_target - pitch) * k_look

	var want_crouch := Input.is_action_pressed("crouch")
	height_target = CROUCH_HEIGHT if want_crouch else STAND_HEIGHT

	# Разгибаться можно только если сверху есть место.
	if height_target > height and _stand_probe.is_inside_tree():
		_stand_probe.force_shapecast_update()
		if _stand_probe.is_colliding():
			height_target = height
	height += (height_target - height) * (1.0 - exp(-dt / 0.09))
	crouching = height < (STAND_HEIGHT + CROUCH_HEIGHT) / 2.0
	_apply_height()

	var fwd := (1 if Input.is_action_pressed("move_forward") else 0) - (1 if Input.is_action_pressed("move_back") else 0)
	var side := (1 if Input.is_action_pressed("move_right") else 0) - (1 if Input.is_action_pressed("move_left") else 0)
	if frozen:
		fwd = 0
		side = 0

	var want_run := Input.is_action_pressed("run") and fwd > 0 and not crouching and stamina > 0.2
	running = want_run
	if want_run:
		stamina = maxf(0.0, stamina - dt)
	else:
		stamina = minf(STAMINA_MAX, stamina + dt * STAMINA_REGEN)

	var speed := SPEED_CROUCH if crouching else (SPEED_RUN if want_run else SPEED_WALK)
	speed *= speed_scale

	# Целевая скорость в горизонтальной плоскости.
	var mag := sqrt(float(fwd * fwd + side * side))
	if mag == 0.0:
		mag = 1.0
	var cs := cos(yaw)
	var sn := sin(yaw)
	var wish_x := (-sn * fwd + cs * side) / mag * speed
	var wish_z := (-cs * fwd - sn * side) / mag * speed

	var moving := fwd != 0 or side != 0
	var k_move := 1.0 - exp(-dt * (ACCEL_K if moving else DECEL_K))
	var v := velocity
	v.x += (wish_x - v.x) * k_move
	v.z += (wish_z - v.z) * k_move

	if on_floor:
		# Скорость кладётся в плоскость пола. Без этого на лестнице игрок
		# половину кадра втыкается в пандус и выталкивается по нормали назад —
		# подъём идёт втрое медленнее ходьбы и ощущается как болото.
		var n := _floor_n
		var slope := 0.0
		if n.y > 0.05 and n.y < 0.999:
			slope = -(v.x * n.x + v.z * n.z) / n.y
			slope = clampf(slope, -6.0, 6.0)
		v.y = slope - GROUND_STICK
	else:
		v.y -= GRAVITY * dt
	velocity = v

	var was_floor := on_floor
	var fall_speed := v.y
	var pos_before := global_position

	_step_up(dt)
	_slide(dt)

	# Пол считаем за весь кадр, а не за подшаг: из нескольких опор берём самую
	# наклонную — оригинал так же оставлял наименьший normal.y.
	var hits := 0
	var best := Vector3.UP
	for i in get_slide_collision_count():
		var c := get_slide_collision(i)
		var cn := c.get_normal()
		if cn.y > FLOOR_NORMAL_MIN:
			hits += 1
			if hits == 1 or cn.y < best.y:
				best = cn
	on_floor = is_on_floor()
	if not on_floor:
		_floor_n = Vector3.UP
	elif hits > 0:
		_floor_n = best
	else:
		# Опора нашлась одним прижимом (snap), своих касаний в списке нет.
		_floor_n = get_floor_normal()
		if _floor_n.length_squared() < 0.5:
			_floor_n = Vector3.UP

	if on_floor and not was_floor and fall_speed < -3.0:
		land.emit()

	# Путь берём по факту смещения: скольжение вдоль стены и подъём по пандусу
	# уже учтены движком, а упёршийся в стену игрок не должен «идти» на месте.
	var moved := global_position - pos_before
	travelled += Vector2(moved.x, moved.z).length()

	# Покачивание по расстоянию, а не по времени: остановился — затухает,
	# а не застывает в случайной фазе.
	var speed_now := Vector2(velocity.x, velocity.z).length()
	var target_bob := minf(1.0, speed_now / SPEED_WALK) * (0.5 if crouching else 1.0)
	bob_amount += (target_bob - bob_amount) * (1.0 - exp(-dt * 6.0))
	bob_phase = travelled / STEP_LENGTH * PI

	if on_floor and speed_now > 0.35:
		var step_index := int(floor(bob_phase / PI))
		if step_index != _last_step_phase:
			_last_step_phase = step_index
			step.emit(running, crouching)
	else:
		_last_step_phase = int(floor(bob_phase / PI))

	_apply_camera()


# ---------- внутреннее ----------

## Шаг на ступеньку. Порядок проб тот же, каким человек нащупывает ногой:
## упёрлись ли во что-то впереди — стена ли это — свободно ли на 25 см выше —
## есть ли там под ногой опора. Только после всех четырёх капсула поднимается,
## и ровно на высоту находки, а не на полные 25 см: подъём на всю высоту
## с последующим прижимом читается как подскок на каждом пороге.
##
## Заодно снимает уступ 7.6 см на выходе обоих маршей лестницы: рабочая грань
## пандуса обрывается ниже площадки, и без шага вверх выход упирался в кромку.
func _step_up(dt: float) -> void:
	if not on_floor or frozen:
		return
	var hv := Vector3(velocity.x, 0.0, velocity.z)
	var speed := hv.length()
	if speed < 0.05:
		return
	var ahead := hv / speed * maxf(speed * dt, STEP_PROBE)

	var hit := KinematicCollision3D.new()
	if not test_move(global_transform, ahead, hit):
		return
	# Пол и потолок нас не касаются: на пандус капсула въезжает сама.
	if absf(hit.get_normal().y) > FLOOR_NORMAL_MIN:
		return

	var up := Vector3.UP * STEP_UP
	if test_move(global_transform, up):
		return
	var lifted := global_transform.translated(up)
	if test_move(lifted, ahead):
		return

	# Опора под поднятой ногой. Нет опоры — впереди не ступенька, а обрыв,
	# и подниматься над ним значило бы шагнуть по воздуху.
	var probe := STEP_UP + 0.02
	var land := KinematicCollision3D.new()
	if not test_move(lifted.translated(ahead), Vector3.DOWN * probe, land):
		return
	if land.get_normal().y < FLOOR_NORMAL_MIN:
		return

	var lift := STEP_UP - land.get_travel().length() + 0.02
	if lift < STEP_MIN:
		return
	global_position.y += minf(lift, STEP_UP)


# move_and_slide берёт шаг времени у движка сам, а главный цикл режет свой dt
# до 50 мс (иначе после просадки игрок улетает на полкомнаты за кадр). Разводим
# это масштабом скорости: смещение выходит ровно на наш dt, а направление после
# скольжения сохраняется — делим обратно тот же вектор.
func _slide(dt: float) -> void:
	var engine_dt := get_process_delta_time()
	if Engine.is_in_physics_frame():
		engine_dt = get_physics_process_delta_time()
	var q := 1.0
	if engine_dt > 1e-6:
		q = dt / engine_dt
	if q > 0.999 and q < 1.001:
		move_and_slide()
		return
	if q < 1e-4:
		q = 1e-4
	velocity *= q
	move_and_slide()
	velocity /= q


func _apply_height() -> void:
	# Перезапись формы дёргает физический сервер, а хвост экспоненты меняет рост
	# на микроны — сравнение отсекает эти кадры.
	if is_equal_approx(_capsule.height, height):
		return
	_capsule.height = height
	_shape.position = Vector3(0.0, height * 0.5, 0.0)


func _apply_camera() -> void:
	if camera == null:
		return
	# Покачивание намеренно слабое: на 360 строках вертикальный ход в три
	# сантиметра рвёт скан-линии и читается как дрожание камеры.
	var bob_y := sin(bob_phase * 2.0) * 0.017 * bob_amount
	var bob_x := sin(bob_phase) * 0.014 * bob_amount
	var roll := sin(bob_phase) * 0.006 * bob_amount

	var feet_pos := feet()
	var eye_y := feet_pos.y + height - EYE_DROP + bob_y
	var right := Vector3(cos(yaw), 0.0, -sin(yaw))
	var eye := Vector3(feet_pos.x + right.x * bob_x, eye_y, feet_pos.z + right.z * bob_x)

	# rotateY → rotateX → rotateZ оригинала — это и есть порядок YXZ.
	camera.global_transform = Transform3D(
		Basis.from_euler(Vector3(pitch, yaw, roll), EULER_ORDER_YXZ),
		eye
	)

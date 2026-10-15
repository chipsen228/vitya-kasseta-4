# Свет. Порт src/world/lights.js.
#
# Источников ровно столько, сколько нужно, и ни одним больше:
#
#   ambient     — ночное небо (в three.js это была полусфера);
#   луна        — направленный, без тени;
#   две лампы   — пул, который переезжает в ближайшие включённые комнаты;
#   фонарь      — единственный, кто отбрасывает тень (живёт в flashlight.gd).
#
# Лампочки на потолке — это меши, а не источники: горящая лампа далеко от игрока
# должна быть видна (свет в сарае с балкона — сюжетный крючок), но освещать
# ничего не обязана.
#
# ЧЕМ ОТЛИЧАЕТСЯ ОТ ОРИГИНАЛА. У Godot нет HemisphereLight: небо и земля
# смешиваются пополам в ambient_light Environment'а. Разницу видно только
# на потолках (в three.js они брали цвет земли, здесь — среднее), стены
# и пол светятся так же, потому что у них dot(N, up) ≈ 0.
#
# Туман в Godot ведут глобальные uniform'ы psx.gdshader (render_chain.gd их
# объявляет), фон — chain.set_background(). Пресет неба переписывает оба
# каждый кадр: это и есть шкала `night`.
class_name LightRig
extends Node3D

# Единственная ручка на случай, если яркость Godot разойдётся с candela three.js.
# Значения ниже перенесены 1:1 — той же договорённости держится flashlight.gd.
const ENERGY_SCALE := 1.0

# Приезд назначен на 20:41 конца августа — это не ночь, а поздние сумерки:
# солнце ушло минут сорок назад, небо ещё держит свет. К мансарде (21:50)
# темнеет по-настоящему. Отсюда шкала `night` 0..1, по которой едут небо,
# луна и туман.
#
# ЧИСЛА ЯРКОСТИ РАЗОШЛИСЬ С ОРИГИНАЛОМ НАМЕРЕННО (фаза 7). В браузере ambient
# 4.2 и луна без тени давали ровный «полдень в синих тонах»: свет приходил
# со всех сторон разом, теней не было вовсе, и объём держался только на текстурах.
# После перехода на ACES стало видно, насколько это пересвет. Полусфера убавлена
# почти в полтора раза, луна — на четверть, и включена её тень: теперь дом кладёт
# тень на участок, а забор даёт полосы поперёк двора. Это и есть вечер.
const SKY := {
	"dusk": {
		"hemiSky": 0x657ea2, "hemiGround": 0x342c1d, "hemi": 3.05,
		"moonColor": 0xddd0ba, "moon": 2.35,
		"fog": 0x3b4858, "fogNear": 10.0, "fogFar": 70.0, "bg": 0x334253,
	},
	"night": {
		"hemiSky": 0x3a5275, "hemiGround": 0x1d1912, "hemi": 1.15,
		"moonColor": 0xafc3e0, "moon": 1.5,
		"fog": 0x192332, "fogNear": 8.0, "fogFar": 42.0, "bg": 0x172233,
	},
}

# Отдельная шкала «Чёткость+». Ретро продолжает брать SKY байт в байт;
# холодный фон, короткий туман и приглушённый ambient принадлежат только HQ.
const HQ_SKY := {
	"dusk": {
		"hemiSky": 0x657b94, "hemiGround": 0x403b30, "hemi": 2.75,
		"moonColor": 0xdfceb5, "moon": 1.85,
		"fog": 0x3b4858, "fogNear": 14.0, "fogFar": 70.0, "bg": 0x334253,
	},
	"night": {
		"hemiSky": 0x73869d, "hemiGround": 0x49453e, "hemi": 1.8,
		"moonColor": 0xafc3df, "moon": 1.15,
		"fog": 0x192332, "fogNear": 10.0, "fogFar": 42.0, "bg": 0x172233,
	},
}

# Сюжет поднимает только целевую ступень. Имена живут здесь, чтобы главы,
# smoke-тесты и render-пробы не заводили три расходящиеся шкалы времени суток.
const STORY_NIGHT := {
	"arrival": 0.00,
	"lights-on": 0.12,
	"power-restored": 0.24,
	"loft": 0.42,
	"tapes": 0.58,
	"street": 0.72,
	"blackout": 0.86,
	"village": 0.95,
	"gate": 1.00,
}

# Непрерывная шкала по времени на плёнке. Значения после полуночи намеренно
# больше 86400; GameState.clock_seconds() не обнуляет сутки.
const CLOCK_NIGHT := [
	[20 * 3600 + 41 * 60, 0.00],
	[21 * 3600 + 5 * 60, 0.12],
	[21 * 3600 + 50 * 60, 0.42],
	[22 * 3600 + 30 * 60, 0.58],
	[22 * 3600 + 50 * 60, 0.72],
	[23 * 3600 + 40 * 60, 0.86],
	[24 * 3600 + 20 * 60, 0.95],
	[25 * 3600 + 50 * 60, 1.00],
]

# Тень луны. Дальность режется под участок: за 28 м от игрока стоят только
# силуэты соседних домов, и тратить на них разрешение карты незачем.
# Смещения крупные не от лени: psx.gdshader снапает вершины в грубую сетку,
# и геометрия в теневом проходе оказывается сдвинутой относительно основного —
# при аккуратных 0.02 весь двор идёт полосами акне.
#
# ФАЗА 15. Было 55 м и два сплита — то есть каждый предмет в радиусе 55 м
# рисовался в теневой атлас ДВАЖДЫ сверх основного прохода. Именно это и
# держало 2325 draw call во дворе, где в кадре один дом. 28 м оставляют тень
# там, ради чего её включали (крыльцо, забор, «Шестёрка»), а дальше её всё
# равно съедает туман: FOG.far — 32 м, и за ним не видно ни тени, ни предмета.
const MOON_SHADOW_SIZE := 2048
const MOON_SHADOW_MAX_DIST := 28.0
const MOON_SHADOW_BIAS := 0.09
const MOON_SHADOW_NORMAL_BIAS := 2.4
const MOON_SHADOW_BLUR := 1.2

const IN_HEMI := 0.30      # внутри дома небо почти отключается,
const IN_MOON := 0.20      # иначе стены светятся сквозь крышу

# Лампы вне сети: горят без общего питания и переживают блэкаут (фаза 11).
# Светильники мимо общего рубильника. Керосинка — потому что она керосинка,
# и в этом вся её ценность на остаток ночи.
#
# ФАЗА 14: шесть светильников околицы и второго этажа. Не послабление, а
# электрика: линия за вторую линию идёт от водокачки, а не от дедова счётчика,
# и гасить её домашним рубильником нечем. Без этого списка isOn() резал бы их
# по powerOn — то есть по прибору, до которого от них полтора километра
# провода и ни одного общего предохранителя.
const OFF_GRID := ["lantern",
	"lane-pole", "lane-pole-2", "barn", "pump", "hen-yard", "club-win",
	"redhouse-up",
	# ФАЗА 18: две наружные лампы у новых проездов второй линии. Та же
	# электрика, что у остальной околицы, — линия от водокачки.
	"barn-gate", "pump-lane"]

const POOL_SIZE := 2
const RANGE_ROOM := 7.5
const RANGE_SMALL := 6.0
const RANGE_OUTDOOR := 9.0
const RANGE_LANTERN := 6.5
const OUTDOOR_LAMP_ZONES := ["street", "outskirts", "plot", "porch", "hen-yard", "snt"]
const SMALL_LAMP_ZONES := [
	"banya", "boarded", "barn-in", "pumphouse", "club", "shed", "privy",
	"cellar", "roofspace",
]
const POOL_DECAY := 1.6            # three.js PointLight decay
const POOL_PICK := 16.0            # дальше этого лампа пул не занимает
const CONE_PICK := 42.0            # дальше конус уже растворён ночным туманом
const POOL_TAU := 12.0             # разгон яркости пула
const SKY_TAU := 3.0               # переход «в доме / на улице»
const NIGHT_FOLLOW_TAU := 2.1715 # 1 - exp(-10 / tau) ~= 0.99

const BULB_OFF := 0x2b2723
const BULB_RADIUS := 0.048
const FIXTURE_COLOR := 0xbdb5a2
const MOON_POS := Vector3(-22, 26, -14)

# ---------- состояние ----------

var night := 0.0                   # сюжетная цель: 0 — сумерки, 1 — ночь
var powerOn := false               # общее питание дома

var lamps: Array = []
var state: Dictionary = {}         # id -> включён ли выключатель

var moon: DirectionalLight3D = null
var pool: Array[OmniLight3D] = []
var bulbs: MultiMeshInstance3D = null
var fixtures: MeshInstance3D = null
var cones: Dictionary = {}         # id -> дешёвый меш-конус, только для HQ
var halos: Dictionary = {}         # id -> обращённый к камере ореол, только для HQ
var light_pools: Dictionary = {}   # id -> мягкое пятно на земле, только для HQ

var chain: RenderChain = null
var mats: Materials = null

var _blackout := 0.0
# Лампы, выведенные из-под общего рубильника по ходу игры (фаза 11).
var _off_grid: Dictionary = {}
var _bulb_lit: Array = []
var _hemi_energy := 0.0
var _moon_energy := 0.0
# Отображаемая ночь отделена от сюжетной цели: все параметры неба проходят
# один и тот же детерминированный десятисекундный переход.
var _display_night := 0.0
var _clock_night := 0.0
var _env: Environment = null
var _y_attic := 3.3
var _y_ground := 0.0
var _built := false
# Кандидаты пула этого кадра. Член, а не локальная переменная — см. update().
var _lit: Array = []
var _last_hq := false


## Компаратор ламп по дистанции. Метод, а не лямбда в месте вызова: лямбда
## создаётся заново на каждом кадре.
static func _by_dist(a: Dictionary, b: Dictionary) -> bool:
	return float(a["d"]) < float(b["d"])


func _init(render_chain: RenderChain = null, materials: Materials = null) -> void:
	chain = render_chain
	mats = materials
	# Таблица и флажки ламп нужны раньше дерева: chapters.gd снимает snapshot()
	# в go(), а go() случается в том же кадре, что и сборка мира.
	lamps = _lamp_table()
	LampFixtures.apply(lamps)
	for lamp: Dictionary in lamps:
		state[lamp["id"]] = bool(lamp["on"])
		_bulb_lit.append(false)
	var y: Dictionary = GameData.site()["Y"]
	_y_attic = float(y["ATTIC"])
	_y_ground = float(y["GROUND"])
	_hemi_energy = float(SKY["dusk"]["hemi"]) * ENERGY_SCALE
	_moon_energy = float(SKY["dusk"]["moon"]) * ENERGY_SCALE


func _ready() -> void:
	if not _built:
		build()


## Собирает источники и светильники. Зовётся из _ready(), но вынесена наружу:
## main.gd может добавить риг в мир до того, как цепочка отдаст Environment.
func build() -> void:
	if _built:
		return
	_built = true
	name = "LightRig"

	if chain != null:
		_env = chain.world_env
	if _env != null:
		# Иначе ambient берётся из фона (BG_COLOR) и шкала неба ни на что не влияет.
		_env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
		_env.ambient_light_color = GameData.color(int(SKY["dusk"]["hemiSky"])).lerp(
			GameData.color(int(SKY["dusk"]["hemiGround"])), 0.5)
		_env.ambient_light_energy = _hemi_energy

	moon = DirectionalLight3D.new()
	moon.name = "Moon"
	moon.light_color = GameData.color(int(SKY["dusk"]["moonColor"]))
	moon.light_energy = _moon_energy
	# Тень у луны — главный источник атмосферы во дворе. Один ортогональный
	# сплит на 28 м: всё, ради чего тень включали, стоит ближе, а второй сплит
	# стоил ровно вдвое дороже первого и накрывал ту даль, которую держит туман.
	moon.shadow_enabled = true
	moon.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	moon.directional_shadow_max_distance = MOON_SHADOW_MAX_DIST
	moon.shadow_bias = MOON_SHADOW_BIAS
	moon.shadow_normal_bias = MOON_SHADOW_NORMAL_BIAS
	moon.shadow_blur = MOON_SHADOW_BLUR
	# Размер карты направленной тени — свойство рендер-сервера, а не источника,
	# и в ProjectSettings оно читается только на старте. 2048 хватает на участок
	# и не роняет Compatibility на встроенной видеокарте.
	RenderingServer.directional_shadow_atlas_set_size(MOON_SHADOW_SIZE, true)
	# Луна светит из MOON_POS в начало координат: у Godot направленный свет
	# смотрит вдоль своего -Z, поэтому базис строим явно.
	moon.transform = Transform3D(Basis.looking_at(-MOON_POS, Vector3.UP), MOON_POS)
	add_child(moon)

	# Пул комнатных ламп: два источника на весь дом.
	for i in POOL_SIZE:
		var l := OmniLight3D.new()
		l.name = "Lamp%d" % i
		l.light_color = GameData.color(0xffd9a8)
		l.light_energy = 0.0
		l.omni_range = RANGE_ROOM
		l.omni_attenuation = POOL_DECAY
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		pool.append(l)

	_build_fixtures()
	_build_light_cones()


func _build_light_cones() -> void:
	for lamp: Dictionary in lamps:
		var id := String(lamp["id"])
		if not LightCone.LAMP_IDS.has(id):
			continue
		var cone := LightCone.make_lamp("Cone-" + id)
		var p: Vector3 = lamp["pos"]
		LightCone.aim(cone, p - Vector3(0.0, 0.04, 0.0), p + Vector3.DOWN)
		add_child(cone)
		cones[id] = cone
		var halo := LightCone.make_lamp_halo("Halo-" + id)
		halo.position = p
		add_child(halo)
		halos[id] = halo
		var pool_spot := LightCone.make_lamp_pool("Pool-" + id)
		var floor_y := float((lamp.get("fixture", {}) as Dictionary).get("floor_y", _y_ground))
		if id == "porch":
			floor_y = float(GameData.site()["Y"]["FLOOR1"])
		elif id == "stop":
			# Площадка выше грунта: иначе depth test прячет пятно под бетоном.
			var stop_data: Dictionary = VillageWorld.data().get("STOP", {})
			floor_y = float(stop_data.get("floor", 0.10))
		LightCone.place_pool(pool_spot,
			Vector3(p.x, floor_y + LightCone.POOL_Y_OFFSET, p.z),
			LightCone.LAMP_POOL_STRENGTH)
		add_child(pool_spot)
		light_pools[id] = pool_spot


# Шестнадцать светильников — это два draw call, а не сорок восемь:
# абажуры и шнуры сливаются в одну сетку, колбы живут в MultiMesh
# с покрасовым цветом. Колба нужна не ради света, а ради вида: свет в сарае,
# который игрок сам выключал, должен быть виден с балкона за сорок метров.
func _build_fixtures() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for lamp: Dictionary in lamps:
		var p: Vector3 = lamp["pos"]
		if lamp.has("fixture"):
			LampFixtures.append(st, lamp)
			any = true
		if bool(lamp["shade"]):
			var shade := CylinderMesh.new()
			shade.top_radius = 0.0
			shade.bottom_radius = 0.155
			shade.height = 0.14
			shade.radial_segments = 7
			shade.rings = 1
			shade.cap_top = false
			shade.cap_bottom = false
			var at := Vector3(p.x, p.y + 0.09, p.z)
			st.append_from(shade, 0, Transform3D(Basis.IDENTITY, at))
			# Абажур открыт снизу, и в оригинале он был DoubleSide. Годовский psx
			# режет заднюю грань, поэтому конус кладём вторым проходом зеркально:
			# отражение по X переворачивает обход треугольников, и внутренняя
			# сторона перестаёт быть дырой.
			st.append_from(shade, 0, Transform3D(Basis.IDENTITY.scaled(Vector3(-1, 1, 1)), at))
			any = true
		# У переносной лампы шнура нет по определению, и приварить его к потолку
		# значит протянуть провод через весь участок следом за керосинкой.
		# Наружный светильник над дверью висит на кронштейне — шнур ему тоже
		# не нужен, у него своя железка в street_world.
		if bool(lamp.get("portable", false)) or not bool(lamp.get("cord", true)):
			continue
		var cord := CylinderMesh.new()
		cord.top_radius = 0.006
		cord.bottom_radius = 0.006
		cord.height = 0.3
		cord.radial_segments = 4
		cord.rings = 1
		st.append_from(cord, 0, Transform3D(Basis.IDENTITY, Vector3(p.x, p.y + 0.26, p.z)))
		any = true

	if any:
		fixtures = MeshInstance3D.new()
		fixtures.name = "Fixtures"
		fixtures.mesh = st.commit()
		# Через materials.gd — иначе абажур останется без тумана и повиснет
		# ярким пятном там, где стена за ним давно съедена дымкой.
		if mats != null:
			fixtures.material_override = mats.flat(FIXTURE_COLOR)
		else:
			var m := StandardMaterial3D.new()
			m.albedo_color = GameData.color(FIXTURE_COLOR)
			fixtures.material_override = m
		fixtures.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(fixtures)

	var bulb := SphereMesh.new()
	bulb.radius = BULB_RADIUS
	bulb.height = BULB_RADIUS * 2.0
	bulb.radial_segments = 6
	bulb.rings = 5

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = bulb
	mm.instance_count = lamps.size()
	var off := GameData.color(BULB_OFF)
	for i in lamps.size():
		var p: Vector3 = lamps[i]["pos"]
		mm.set_instance_transform(i, Transform3D(Basis.IDENTITY, p))
		mm.set_instance_color(i, off)

	# Колба следует тому же туману, что корпус; дальний огонёк не висит в пустоте.
	var bm := ShaderMaterial.new()
	bm.shader = load("res://shaders/light_bulb.gdshader") as Shader

	bulbs = MultiMeshInstance3D.new()
	bulbs.name = "Bulbs"
	bulbs.multimesh = mm
	bulbs.material_override = bm
	bulbs.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(bulbs)


# ---------- выключатели ----------

## Включить/выключить лампу в комнате. Работает только если есть общее питание.
func setLamp(id: String, on: bool) -> bool:
	if not state.has(id):
		return false
	state[id] = on
	return true


func toggleLamp(id: String) -> bool:
	setLamp(id, not bool(state.get(id, false)))
	return bool(state.get(id, false))


func isOn(id: String) -> bool:
	# Керосинка не в сети и блэкаут ей не указ — в этом вся её ценность
	# на остаток ночи. Список именной, а не флаг «горит без питания»: ламп
	# такого рода в игре ровно одна, и заводить под неё правило значит
	# однажды случайно погасить ею весь дом.
	if OFF_GRID.has(id) or _off_grid.has(id):
		return bool(state.get(id, false))
	return powerOn and bool(state.get(id, false)) and _blackout <= 0.0


## Вывести лампу из-под общего рубильника или вернуть обратно. Нужна ровно
## одному месту: после блэкаута в окне бани горит свет, который игрок сам
## выключал, и объяснить его нечем — в этом и дело. Флаг живёт в снимке
## света, поэтому откат по [R] его не теряет.
func set_off_grid(id: String, on: bool) -> void:
	if on:
		_off_grid[id] = true
	else:
		_off_grid.erase(id)


## Переставить лампу. Нужна ровно керосинке: её носит игрок, и позиция
## обновляется покадрово. Двигаем и источник, и колбу — иначе огонёк остаётся
## там, где лампу нашли.
func move_lamp(id: String, pos: Vector3) -> void:
	for i in lamps.size():
		if String(lamps[i]["id"]) != id:
			continue
		(lamps[i] as Dictionary)["pos"] = pos
		if bulbs != null:
			bulbs.multimesh.set_instance_transform(i, Transform3D(Basis.IDENTITY, pos))
		if cones.has(id):
			var cone := cones[id] as MeshInstance3D
			LightCone.aim(cone, pos - Vector3(0.0, 0.04, 0.0), pos + Vector3.DOWN)
		if halos.has(id):
			(halos[id] as Node3D).position = pos
		if light_pools.has(id):
			var spot := light_pools[id] as Node3D
			spot.position = Vector3(pos.x, spot.position.y, pos.z)
		return


## Погасить всё разом: точка невозврата в 23:40.
func blackout(seconds := 1e9) -> void:
	_blackout = seconds


func restorePower() -> void:
	_blackout = 0.0


## Поднять сюжетную цель, не позволяя позднему callback сделать вечер светлее.
## Restore меняет поля напрямую: откат главы обязан уметь вернуться назад.
func set_story_night(target: float) -> void:
	night = maxf(clampf(night, 0.0, 1.0), clampf(target, 0.0, 1.0))


## Передаётся из GameState каждый активный игровой кадр. Сюжетный night остаётся
## нижним пределом, поэтому ни часы, ни поздний callback не осветляют сцену.
func set_clock_seconds(seconds: float) -> void:
	_clock_night = night_at_clock(seconds)


static func night_at_clock(seconds: float) -> float:
	if seconds <= float(CLOCK_NIGHT[0][0]):
		return float(CLOCK_NIGHT[0][1])
	for i in range(1, CLOCK_NIGHT.size()):
		var right: Array = CLOCK_NIGHT[i]
		if seconds <= float(right[0]):
			var left: Array = CLOCK_NIGHT[i - 1]
			var t := inverse_lerp(float(left[0]), float(right[0]), seconds)
			return lerpf(float(left[1]), float(right[1]), t)
	return float(CLOCK_NIGHT[-1][1])


## Для изолированных render-проб: игровой код пользуется set_story_night().
func set_night_immediate(value: float) -> void:
	night = clampf(value, 0.0, 1.0)
	_clock_night = night
	_display_night = night


# ---------- покадровое ----------

func update(dt: float, camera_pos: Vector3, zone_id: String, outdoor: bool) -> void:
	if _blackout > 0.0:
		_blackout -= dt
	var hq := chain != null and chain.render_preset() == RenderChain.PRESET_HQ

	# Ближайшие включённые лампы забирают пул. Массив и компаратор —
	# переиспользуемые: свежая лямбда в sort_custom на каждом кадре стоила
	# шестидесяти выделений Callable в секунду ни за что.
	_lit.clear()
	for lamp: Dictionary in lamps:
		if not isOn(String(lamp["id"])):
			continue
		# За закрытой дверью два реальных источника принадлежат только текущему
		# помещению. Исключение — переносная керосинка: она должна светить там,
		# куда её принесли, независимо от исходной зоны в таблице.
		if not outdoor and String(lamp.get("zone", "")) != zone_id \
				and not bool(lamp.get("portable", false)):
			continue
		var lp: Vector3 = lamp["pos"]
		var d := lp.distance_to(camera_pos)
		if d < POOL_PICK:
			_lit.append({"lamp": lamp, "d": d})
	var lit := _lit
	lit.sort_custom(_by_dist)

	var kp := 1.0 - exp(-dt * POOL_TAU)
	for i in pool.size():
		var l := pool[i]
		if i < lit.size():
			var pick: Dictionary = lit[i]
			var lamp: Dictionary = pick["lamp"]
			var p: Vector3 = lamp["pos"]
			l.position = Vector3(p.x, p.y - 0.05, p.z)
			l.light_color = _lamp_color(lamp, hq)
			l.omni_range = _lamp_range(lamp)
			l.visible = true
			l.light_energy += (float(lamp["power"]) * ENERGY_SCALE - l.light_energy) * kp
		else:
			l.light_energy += (0.0 - l.light_energy) * kp
			if l.light_energy < 0.02:
				l.visible = false

	# Крепление, колба и эффекты используют один anchor. Цвет корпуса и колбы
	# растворяется в psx-тумане; прозрачные эффекты дополнительно имеют fade.
	if bulbs != null:
		var mm := bulbs.multimesh
		for i in lamps.size():
			var lamp: Dictionary = lamps[i]
			var on := isOn(String(lamp["id"]))
			var tint := _lamp_color(lamp, hq) if on else GameData.color(BULB_OFF)
			if lamp.has("fixture"):
				tint.a = _fixture_fade((lamp["pos"] as Vector3).distance_to(camera_pos))
			mm.set_instance_color(i, tint)
			_bulb_lit[i] = on
	_last_hq = hq
	for id: String in cones:
		var cone := cones[id] as MeshInstance3D
		var lamp := _lamp_by_id(id)
		var source: Vector3 = lamp.get("pos", Vector3.ZERO)
		var distance := source.distance_to(camera_pos)
		var fade := _fixture_fade(distance)
		var active := hq and not lamp.is_empty() and isOn(id) and fade > 0.001
		cone.visible = active
		cone.set_instance_shader_parameter("beam_strength", fade)
		var halo := halos.get(id) as MeshInstance3D
		if halo != null:
			halo.visible = active and distance >= LightCone.HALO_MIN_VISIBLE_DISTANCE
			if halo.visible:
				LightCone.update_halo(halo, source, camera_pos, fade)
		var pool_spot := light_pools.get(id) as MeshInstance3D
		if pool_spot != null:
			pool_spot.visible = active
			pool_spot.set_instance_shader_parameter("pool_strength", LightCone.LAMP_POOL_STRENGTH * fade)

	# Небо между сумерками и ночью. Цель может смениться посреди предыдущего
	# перехода; новый путь всегда начинается с уже показанного кадра.
	_advance_night(dt)
	var n := _display_night
	var profile: Dictionary = HQ_SKY if hq else SKY
	var d0: Dictionary = profile["dusk"]
	var g: Dictionary = profile["night"]
	var sky_c := GameData.color(int(d0["hemiSky"])).lerp(GameData.color(int(g["hemiSky"])), n)
	var ground_c := GameData.color(int(d0["hemiGround"])).lerp(GameData.color(int(g["hemiGround"])), n)
	var moon_c := GameData.color(int(d0["moonColor"])).lerp(GameData.color(int(g["moonColor"])), n)
	var fog_c := GameData.color(int(d0["fog"])).lerp(GameData.color(int(g["fog"])), n)
	var bg_c := GameData.color(int(d0["bg"])).lerp(GameData.color(int(g["bg"])), n)

	if _env != null:
		_env.ambient_light_color = sky_c.lerp(ground_c, 0.5)
	if moon != null:
		moon.light_color = moon_c

	# Туман считает psx.gdshader — цвет ему нужен линейным.
	var fl := fog_c.srgb_to_linear()
	RenderChain.set_shader_global("psx_fog_color", Vector3(fl.r, fl.g, fl.b))
	RenderChain.set_shader_global(
		"psx_fog_near", lerpf(float(d0["fogNear"]), float(g["fogNear"]), n))
	RenderChain.set_shader_global(
		"psx_fog_far", lerpf(float(d0["fogFar"]), float(g["fogFar"]), n))
	if chain != null:
		chain.set_background(bg_c)
		chain.set_hq_atmosphere(fog_c, n)

	# В любом закрытом помещении луна почти не участвует — иначе стены
	# светятся сквозь крышу. Источник истины тот же zone_at, что у звука,
	# погоды и игрового состояния; координатный прямоугольник знал только дом.
	var indoors := not outdoor
	var out_hemi := lerpf(float(d0["hemi"]), float(g["hemi"]), n)
	var out_moon := lerpf(float(d0["moon"]), float(g["moon"]), n)
	var target_hemi := (IN_HEMI + out_hemi * 0.06) if indoors else out_hemi
	var target_moon := (IN_MOON + out_moon * 0.05) if indoors else out_moon
	var ks := 1.0 - exp(-dt * SKY_TAU)
	_hemi_energy += (target_hemi * ENERGY_SCALE - _hemi_energy) * ks
	_moon_energy += (target_moon * ENERGY_SCALE - _moon_energy) * ks
	if _env != null:
		_env.ambient_light_energy = _hemi_energy
	if moon != null:
		moon.light_energy = _moon_energy


func _advance_night(dt: float) -> void:
	var target := maxf(clampf(night, 0.0, 1.0), _clock_night)
	var k := 1.0 - exp(-maxf(dt, 0.0) / NIGHT_FOLLOW_TAU)
	_display_night += (target - _display_night) * k


static func _fixture_fade(distance: float) -> float:
	return 1.0 - smoothstep(CONE_PICK - 8.0, CONE_PICK, distance)


static func _lamp_range(lamp: Dictionary) -> float:
	if bool(lamp.get("portable", false)):
		return RANGE_LANTERN
	var z := String(lamp.get("zone", ""))
	if OUTDOOR_LAMP_ZONES.has(z):
		return RANGE_OUTDOOR
	if SMALL_LAMP_ZONES.has(z):
		return RANGE_SMALL
	return RANGE_ROOM


static func _lamp_color(lamp: Dictionary, hq: bool) -> Color:
	if hq and LightCone.LAMP_IDS.has(String(lamp["id"])):
		return GameData.color(LightCone.LAMP_COLOR)
	return GameData.color(int(lamp["color"]))


func _lamp_by_id(id: String) -> Dictionary:
	for lamp: Dictionary in lamps:
		if String(lamp["id"]) == id:
			return lamp
	return {}


# ---------- откат главы ----------

# Chapters.go() снимает снимок, retry() возвращает. Внутри всё, что мутирует:
# питание, флажки ламп, отключка и обе шкалы ночи. В оригинале `night` в снимок
# не входила (её заново ставит enter главы), здесь она добавлена — иначе откат
# главы, которая ночь не трогает, оставлял бы небо от следующей.
func snapshot() -> Dictionary:
	return {"power": powerOn, "lamps": state.duplicate(), "blackout": _blackout,
		"night": night, "displayNight": _display_night,
		"offGrid": _off_grid.duplicate()}


func restore(s: Dictionary) -> void:
	powerOn = bool(s.get("power", false))
	_blackout = float(s.get("blackout", 0.0))
	night = clampf(float(s.get("night", night)), 0.0, 1.0)
	# Старый снимок содержит только night: показываем его сразу, а не повторяем
	# уже когда-то проигранное затемнение после загрузки.
	_display_night = clampf(float(s.get("displayNight", night)), 0.0, 1.0)
	_clock_night = 0.0
	# nightFrom/nightElapsed из прежнего формата намеренно принимаются и
	# игнорируются: Dictionary не требует схемы, а экспоненциальному переходу
	# достаточно текущего displayNight.
	var og: Variant = s.get("offGrid", null)
	if og is Dictionary:
		_off_grid = (og as Dictionary).duplicate()
	var saved: Variant = s.get("lamps", {})
	if saved is Dictionary:
		var d: Dictionary = saved
		for k: Variant in d:
			state[String(k)] = bool(d[k])
	elif saved is Array:
		# Формат оригинала — список пар [id, on]. На случай чужого снимка.
		var rows: Array = saved
		for row: Variant in rows:
			if row is Array:
				var pair: Array = row
				if pair.size() >= 2:
					state[String(pair[0])] = bool(pair[1])


# ---------- таблица ламп ----------

static func _lamp_table() -> Array:
	var y: Dictionary = GameData.site()["Y"]
	var f1 := float(y["FLOOR1"])
	var at := float(y["ATTIC"])
	var rf := float(y["ROOF"])
	var ce := float(y["CELLAR"])
	return [
		{"id": "porch", "pos": Vector3(-2.3, f1 + 2.22, 6.30), "zone": "porch", "color": 0xffd9a0, "power": 9.0, "on": false, "shade": false},
		{"id": "veranda", "pos": Vector3(-2.30, f1 + 2.10, 8.30), "zone": "veranda", "color": 0xffd7a4, "power": 11.0, "on": false, "shade": true},
		{"id": "kitchen", "pos": Vector3(-0.40, f1 + 2.12, 11.00), "zone": "floor1", "color": 0xffe0b0, "power": 13.0, "on": false, "shade": true},
		{"id": "hall", "pos": Vector3(-3.40, f1 + 2.12, 11.30), "zone": "floor1", "color": 0xffd6a0, "power": 10.0, "on": false, "shade": true},
		{"id": "wash", "pos": Vector3(-3.50, f1 + 2.16, 15.60), "zone": "floor1", "color": 0xffe6c0, "power": 7.0, "on": false, "shade": true},
		{"id": "aunt", "pos": Vector3(2.70, f1 + 2.12, 9.40), "zone": "aunt", "color": 0xffd4a0, "power": 11.0, "on": false, "shade": true},
		{"id": "living", "pos": Vector3(1.20, f1 + 2.12, 14.20), "zone": "floor1", "color": 0xffdcae, "power": 14.0, "on": false, "shade": true},
		{"id": "closet", "pos": Vector3(-5.00, f1 + 2.10, 14.20), "zone": "floor1", "color": 0xffe2b8, "power": 6.0, "on": false, "shade": false},

		{"id": "landing", "pos": Vector3(-3.60, at + 1.95, 11.40), "zone": "attic", "color": 0xffd8a6, "power": 10.0, "on": false, "shade": true},
		{"id": "vitya", "pos": Vector3(0.20, at + 1.95, 11.60), "zone": "attic", "color": 0xffe0b4, "power": 11.0, "on": false, "shade": true},
		{"id": "storage", "pos": Vector3(-3.60, at + 1.95, 15.00), "zone": "attic", "color": 0xffd2a0, "power": 8.0, "on": false, "shade": true},

		{"id": "roofspace", "pos": Vector3(-2.00, rf + 1.45, 12.50), "zone": "roofspace", "color": 0xc9d8e6, "power": 6.0, "on": false, "shade": false},
		{"id": "cellar", "pos": Vector3(-2.00, ce + 1.72, 11.00), "zone": "cellar", "color": 0xffd08a, "power": 7.0, "on": false, "shade": false},

		{"id": "shed", "pos": Vector3(6.80, 2.08, 12.00), "zone": "shed", "color": 0xffd090, "power": 8.0, "on": false, "shade": false},
		{"id": "privy", "pos": Vector3(8.60, 1.90, 21.00), "zone": "privy", "color": 0xffe0b0, "power": 4.0, "on": false, "shade": false},
		{"id": "office", "pos": Vector3(-30.0, 2.55, -10.0), "zone": "office", "color": 0xcfe0ff, "power": 6.0, "on": false, "shade": false},

		# Светильник над входом в правление (фаза 11). Горит с самого начала
		# и своего выключателя не имеет: он и есть починка «дверь читается
		# глухой стеной». Тридцать один метр при fogFar 32 съедает и белый
		# наличник, и козырёк, а тёплое пятно над дверью видно от калитки
		# Аркадия. Слот пула он не отнимает: до дома отсюда тридцать метров,
		# а POOL_PICK — шестнадцать.
		{"id": "office-porch", "pos": Vector3(-28.95, 2.20, -7.20), "zone": "street", "color": 0xffd9a0, "power": 7.0, "on": true, "shade": false, "cord": false},

		# Фаза 11. Баня — двадцать метров от дома, то есть дальше POOL_PICK (16):
		# слот пула она у комнатной лампы не отнимет, и своего источника мимо
		# пула ей не нужно (у окна наблюдателя причина была другая — оно горело
		# постоянно и за тридцать метров). Керосинка ездит за игроком: её
		# позицию обновляет interact.gd покадрово, поэтому здесь она в нуле.
		{"id": "banya", "pos": Vector3(5.0, 1.92, 24.6), "zone": "banya", "color": 0xffcf92, "power": 8.0, "on": false, "shade": false},
		{"id": "lantern", "pos": Vector3(0.0, -40.0, 0.0), "zone": "plot", "color": 0xffbe72, "power": 6.5, "on": false, "shade": false, "portable": true},

		# ФАЗА 12 — деревня. Четыре лампы, и ни одна не отнимает слот пула:
		# POOL_PICK шестнадцать метров, а ближайшая из них стоит в двадцати
		# одном от дома. Мигающая лампа остановки и гудящая будки — не
		# украшение: они единственное, что светится на своих двадцати метрах,
		# и по ним игрок понимает, что дошёл.
		{"id": "stop", "pos": Vector3(-42.60, 2.16, -6.60), "zone": "street", "color": 0xcfe0ff, "power": 5.0, "on": true, "shade": false, "cord": false},
		{"id": "booth", "pos": Vector3(22.55, 2.42, -8.35), "zone": "street", "color": 0xffd9a0, "power": 4.5, "on": true, "shade": false, "cord": false},
		# Сельпо: одна снаружи над витриной, одна в зале. Обе зажигаются,
		# когда игрок открыл дверь, и обе идут мимо рубильника — до фазы 12
		# ни один источник за воротами от блэкаута и не зависел.
		{"id": "shop-win", "pos": Vector3(29.90, 2.30, -7.05), "zone": "street", "color": 0xffd9a0, "power": 5.5, "on": false, "shade": false, "cord": false},
		{"id": "shop-in", "pos": Vector3(29.00, 2.44, -10.60), "zone": "shop", "color": 0xffe0b0, "power": 9.0, "on": false, "shade": true},

		# ФАЗА 13 — красный дом напротив ворот. Одна лампа, и она не лампа:
		# это свет из открытого холодильника, единственного работающего
		# прибора на всей линии. Цвет холодный и мощность маленькая — он не
		# освещает комнату, он её обозначает. Горит с начала главы ДЕРЕВНЯ
		# и мимо рубильника: дачники платили за свет отдельным счётчиком,
		# и блэкаут на дедовом участке до него не дотягивается.
		{"id": "redhouse", "pos": Vector3(0.90, 1.32, -9.20), "zone": "redhouse", "color": 0xd8ecff, "power": 4.0, "on": false, "shade": false, "cord": false},

		# ФАЗА 14 — околица и второй этаж. Шесть светильников, и ни одного
		# нового источника: пул как был из двух OmniLight3D, так и остался,
		# а update() каждый кадр отдаёт его двум ближайшим к КАМЕРЕ горящим
		# лампам ближе POOL_PICK. Шесть записей в таблице — это шесть мест,
		# где свет может оказаться, а не шесть светящих одновременно; на
		# околице все домашние лампы всё равно за сотню метров. Все шесть
		# горят мимо рубильника: линия на околицу идёт от водокачки, а не
		# от дедова счётчика.
		#
		# Столб переулка — единственный свет между улицей и второй линией.
		# Пока он не найден глазами, выезда с дороги как будто нет.
		{"id": "lane-pole", "pos": Vector3(-28.60, 3.10, -16.20), "zone": "outskirts", "color": 0xcfe0ff, "power": 5.5, "on": true, "shade": false, "cord": false},
		# ФАЗА 17. Второй столб, на второй линии против оси Вали. На 78 м
		# дороги и всю околицу был ОДИН источник — тот, что выше, — и до оси
		# покоса от него 29.5 м. Маршрут к покосу и холму стал обязательным,
		# а ночью он не читался даже открытым: игрок выходил в новый проём
		# и не видел, что дорога идёт дальше.
		{"id": "lane-pole-2", "pos": Vector3(0.90, 3.10, -16.20), "zone": "outskirts", "color": 0xcfe0ff, "power": 5.5, "on": true, "shade": false, "cord": false},
		# Лампочка в воротах амбара: горит с самого начала, и в её пятне
		# стоит фигура скримера №1. Свет тут работает на испуг, а не против.
		{"id": "barn", "pos": Vector3(-36.30, 2.90, -27.60), "zone": "barn-in", "color": 0xffcf92, "power": 6.0, "on": true, "shade": false, "cord": false},
		# Водокачка. Зажигается вместе с насосом — это и есть подтверждение,
		# что рубильник сработал: гудит и светится одновременно.
		{"id": "pump", "pos": Vector3(-15.00, 2.55, -29.10), "zone": "pumphouse", "color": 0xffe0b0, "power": 7.0, "on": false, "shade": false, "cord": false},
		# Куриный двор — единственное обжитое место на околице: бельё висит,
		# лампа горит, кур нет.
		{"id": "hen-yard", "pos": Vector3(-7.20, 2.20, -26.60), "zone": "hen-yard", "color": 0xffd090, "power": 5.0, "on": true, "shade": false, "cord": false},
		# Окно клуба светится изнутри, хотя окна заколочены и внутри никого.
		{"id": "club-win", "pos": Vector3(9.10, 2.60, -29.40), "zone": "club", "color": 0xd8ecff, "power": 4.5, "on": true, "shade": false, "cord": false},
		# Второй этаж красного дома. Гаснет знаком (omens): игрок видит окно
		# с улицы, отворачивается — и в следующий раз оно тёмное.
		{"id": "redhouse-up", "pos": Vector3(0.44, 4.30, -10.25), "zone": "redhouse-up", "color": 0xffd9a0, "power": 3.5, "on": true, "shade": false, "cord": false},

		# ФАЗА 18 — два наружных светильника у двух новых проездов.
		# Жалоба Петра, пункт шестой, вторая её половина: амбар и водокачку
		# не только закрывали дома, но и ночью там было чёрное пятно. Лампа
		# barn стоит на 1.6 м ВНУТРИ ворот и в зоне barn-in, то есть с радиусом
		# 6.0 (SMALL_LAMP_ZONES) — снаружи от неё не остаётся ничего, а
		# ближайший столб в 11 м. Эти две — снаружи, в зоне outskirts, то есть
		# RANGE_OUTDOOR 9.0, и обе мимо рубильника, как вся линия за околицей.
		#
		# Над воротами амбара, ровно в створе проезда сквозь дом участка 21
		# (x -36.30 — та же ось, что у FARM.barn.gate и лампы barn внутри).
		# Пятно ложится на фасад амбара, и подворотня получает то, ради чего
		# прорезана: за ней ВИДНО, куда она ведёт.
		{"id": "barn-gate", "pos": Vector3(-36.30, 3.20, -25.60), "zone": "outskirts", "color": 0xffd9a0, "power": 5.5, "on": true, "shade": false, "cord": false},
		# У поворота в обход водокачки. Проезд сквозь дом участка 20 узкий
		# (1.0 м) и без света читался бы тенью между окон, а не проходом.
		{"id": "pump-lane", "pos": Vector3(-18.50, 3.10, -24.60), "zone": "outskirts", "color": 0xcfe0ff, "power": 5.0, "on": true, "shade": false, "cord": false},

		# ФАЗА 16 — СНТ за околицей. Три лампы на весь район, и ни одного
		# нового источника: пул как был из двух OmniLight3D, так и остался.
		# Три места, а не три светящих сразу: до соседней от каждой больше
		# двадцати метров, а POOL_PICK шестнадцать.
		#
		# Лампа над въездным створом: пока её не увидели, въезда как будто нет —
		# та же работа, что у столба переулка на околице.
		{"id": "snt-gate", "pos": Vector3(36.80, 3.30, -35.00), "zone": "snt", "color": 0xcfe0ff, "power": 5.5, "on": true, "shade": false, "cord": false},
		# Фонарь у поворота к воде: единственный свет на всём втором проезде.
		{"id": "snt-lane", "pos": Vector3(12.20, 3.10, -47.00), "zone": "snt", "color": 0xffd9a0, "power": 5.0, "on": true, "shade": false, "cord": false},
		# Трансформаторная будка в тупике: гудит и светится. По ней и понимают,
		# что дальше дороги нет.
		{"id": "snt-booth", "pos": Vector3(7.10, 2.30, -70.60), "zone": "snt-booth", "color": 0xffe0b0, "power": 4.5, "on": true, "shade": false, "cord": false},
	]

# Деревня за воротами — оверлей поверх принятой улицы (фаза 12).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ, А НЕ ПРАВКА street_world.gd. Довод у него тот же, что
# у yard_world.gd, и он машинный: у улицы нет возврата боксов. Зазоры до полосы
# деда и до кольца Аркадия меряет tests/test_street_clear.gd по out["boxes"] —
# значит, модуль обязан их отдавать, а street_world.gd их не копит и переучивать
# его ради этого дороже, чем завести соседа.
#
# Правило то же и оно механическое:
#
#   видимое  -> _shell()      = b.box(..., collide = false)
#   твёрдое  -> _solid()      = col.add_box_d(SET_OVERLAY) + копилка AABB
#   скат     -> _slope_soft() = b._slope(..., collide = false)
#   фронтон  -> _gable_soft() = свой, ступеньками через _shell()
#
# Прямых вызовов b.box/slab/wall/fence/stairs/rail/roof/_slopeX/_gable здесь нет
# ни одного: _slopeX() не имеет параметра collide и ВСЕГДА пишет в SET_STATIC,
# а _gable() зовёт box() без collide = false. Один такой вызов — и паритет
# 311/4/83 поедет, а заметить это можно будет только по тому, что дед перестал
# ходить туда, куда ходил.
#
# ПЛАТА, НАЗВАННАЯ ВСЛУХ, И ЧЕМ ОНА ЗАКРЫТА. SET_OVERLAY невидим для навграфа
# и для ai.gd. На улице узлов графа нет вовсе (nav.json banRooms), поэтому деду
# здесь ходить нечем — зато по прямой ходит street_stalk.gd, а по кольцу гуляет
# Аркадий, и ни один из них геометрии не спрашивает. Отсюда единственный жёсткий
# запрет фазы: НИ ОДНА коробка отсюда не лежит в полосе z [-5.5, -0.9] и в кольце
# z [-6.2, -0.3]. Сторожит tests/test_street_clear.gd, и до фазы 12 сторожа
# у улицы не было вовсе.
#
# УГЛЫ. Как в бане: торцевые стены идут на всю длину, боковые — только между
# ними. Две коробки одного материала с совпавшей гранью дают дрожащий шов,
# и увидеть его можно только в игре, зато сразу.
#
# Нет data/village.json — build() выходит первой строкой, и улица ровно та,
# что принята в фазе 11.

class_name VillageWorld
extends RefCounted

const DATA := "res://data/village.json"

static var _cache: Variant = null


## Данные деревни или пустой словарь. Кэш на процесс: файл читают и сборка,
## и квест, и три теста.
static func data() -> Dictionary:
	if _cache is Dictionary:
		return _cache
	var f := FileAccess.open(DATA, FileAccess.READ)
	if f == null:
		_cache = {}
		return _cache
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	_cache = parsed if parsed is Dictionary else {}
	return _cache


## Сборка. Зовётся из WorldBuilder._build_all() за YardWorld.build(): к этому
## моменту и участок, и улица собраны целиком, и деревня ложится поверх.
static func build(b: WorldBuilder) -> Dictionary:
	var d := data()
	if d.is_empty():
		return {}

	var out: Dictionary = {
		"enabled": true,
		"boxes": [],       # AABB всей твёрдой геометрии — для test_street_clear
		"nodes": {},       # id -> Node3D (квестовые предметы и створки)
		"shop": d.get("SHOP", {}),
		"boarded": d.get("BOARDED", {}),
		"graveyard": d.get("GRAVEYARD", {}),
		"stop": d.get("STOP", {}),
		"arkady": d.get("ARKADY", {}),
		"tractor": d.get("TRACTOR", {}),
		"well": d.get("WELL", {}),
		"redhouse": d.get("REDHOUSE", {}),
	}

	var skin_stop := b.skin_begin("buildings", "village", String((d.get("STOP", {}) as Dictionary).get("id", "")), "STOP")
	_stop(b, d.get("STOP", {}), out)
	b.skin_end(skin_stop)
	_tractor(b, d.get("TRACTOR", {}), out)
	var skin_well := b.skin_begin("buildings", "village", String((d.get("WELL", {}) as Dictionary).get("id", "")), "WELL")
	_well(b, d.get("WELL", {}), out)
	b.skin_end(skin_well)
	var skin_booth := b.skin_begin("buildings", "village", String((d.get("BOOTH", {}) as Dictionary).get("id", "")), "BOOTH")
	_booth(b, d.get("BOOTH", {}), out)
	b.skin_end(skin_booth)
	var skin_shop := b.skin_begin("buildings", "village", String((d.get("SHOP", {}) as Dictionary).get("id", "")), "SHOP")
	_shop(b, d.get("SHOP", {}), out)
	b.skin_end(skin_shop)
	var skin_boarded := b.skin_begin("buildings", "village", String((d.get("BOARDED", {}) as Dictionary).get("id", "")), "BOARDED")
	_boarded(b, d.get("BOARDED", {}), out)
	b.skin_end(skin_boarded)
	_graveyard(b, d.get("GRAVEYARD", {}), out)
	var skin_arkady := b.skin_begin("buildings", "village", String((d.get("ARKADY", {}) as Dictionary).get("id", "")), "ARKADY")
	_arkady(b, d.get("ARKADY", {}), out)
	b.skin_end(skin_arkady)
	var skin_redhouse := b.skin_begin("buildings", "village", String((d.get("REDHOUSE", {}) as Dictionary).get("id", "")), "REDHOUSE")
	_redhouse(b, d.get("REDHOUSE", {}), out)
	b.skin_end(skin_redhouse)
	_quest13(b, d, out)
	_hood(b, out)
	_omens(b, out)
	_zones(d.get("ZONES", []))
	return out


# ------------------------------------------------------------ красный дом ----

# ФАЗА 13. Третий интерьер деревни, и самый пустой из трёх.
#
# Снаружи дом строит street_world.gd (data/street.json, house 'redhouse'
# с флагами hollow и doorOpen) — ровно тем же механизмом, что заколоченный:
# фасад с проёмами, крыша, забор и крыльцо оттуда, объём и нутро отсюда.
#
# ЧТО ЗДЕСЬ ЕСТЬ И ЧЕГО НЕТ. Есть свежая краска, диван и кресло в заводской
# плёнке, нераспакованные коробки, стол на двоих и работающий холодильник —
# единственный ток на всей линии. Нет ни одной вещи, которую взяли бы с собой,
# уезжая нормально: ни чемодана, ни следов сборов. Люди купили дом весной
# и ушли из него в августе за час, и дом об этом молчит.
#
# Улика — детский рисунок на стене: дом, забор, ночь и человек у забора.
# Человек нарисован выше дома.
static func _redhouse(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var t := float(d.get("wall", 0.18))
	var fl := float(d.get("floor", 0.14))
	var eave := float(d.get("eave", 3.10))
	var dr: Array = d["door"]
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	var dtop := float(d.get("doorTop", 2.05))
	var cr: Array = d.get("ceil", [2.50, 2.64])
	var c0 := float(cr[0])
	var c1 := float(cr[1])

	# --- твёрдое: коробка с проёмом в южной стене ---
	_solid(b, out, x0, x1, 0.0, fl, z0, z1)
	_solid(b, out, x0, x1, fl, eave, z0, z0 + t)
	_solid(b, out, x0, x0 + t, fl, eave, z0 + t, z1 - t)
	_solid(b, out, x1 - t, x1, fl, eave, z0 + t, z1 - t)
	_solid(b, out, x0 + t, d0, fl, eave, z1 - t, z1)
	_solid(b, out, d1, x1 - t, fl, eave, z1 - t, z1)
	_solid(b, out, d0, d1, dtop, eave, z1 - t, z1)

	# ФАЗА 14. Потолок первого этажа — он же пол второго — раньше был одной
	# плитой на весь след; теперь в ней вырезан проём лестничного марша, и
	# вырезан он РОВНО НАД МАРШЕМ: x [stair_x0, stair_x1], z [stairTop, z1-t].
	# Марш идёт вдоль ВОСТОЧНОЙ стены, а не западной, и это не вкусовщина:
	# вдоль западной проложена дорога фазы 13 от порога к детскому рисунку
	# (tests/test_village_room.gd, REDHOUSE_WALK), и лестница её перекрывала.
	var stair_top := float(d.get("stairTop", z0 + t))
	var stair_x1 := x1 - t
	var stair_x0 := stair_x1 - 0.92
	_solid(b, out, x0 + t, stair_x0, c0, c1, z0 + t, z1 - t)
	_solid(b, out, stair_x0, stair_x1, c0, c1, z0 + t, stair_top)

	# --- видимое: только внутренние плоскости, фасад уже стоит ---
	# Пол новый, некрашеный: доска светлая и без единого следа.
	_shell(b, x0 + t, x1 - t, fl - 0.02, fl + 0.006, z0 + t, z1 - t, "boards", 1.3)
	_shell(b, x0 + t, stair_x0, c0, c1, z0 + t, z1 - t, "boards", 1.5)
	_shell(b, stair_x0, stair_x1, c0, c1, z0 + t, stair_top, "boards", 1.2)
	# Обои, а не голая доска: этот дом успели отделать, и в этом всё отличие
	# от заколоченного.
	_shell(b, x0 + t - 0.02, x1 - t + 0.02, fl, c0, z0 + t, z0 + t + 0.02, "plank", 0.0)
	_shell(b, x0 + t, x0 + t + 0.02, fl, c0, z0 + t, z1 - t, "plank", 0.0)
	_shell(b, x1 - t - 0.02, x1 - t, fl, c0, z0 + t, z1 - t, "plank", 0.0)
	_shell(b, x0 + t, d0, fl, c0, z1 - t - 0.02, z1 - t, "plank", 0.0)
	_shell(b, d1, x1 - t, fl, c0, z1 - t - 0.02, z1 - t, "plank", 0.0)
	_case(b, d0, d1, fl, dtop, z1)

	var nodes: Dictionary = out["nodes"]

	# Холодильник. Дверца приоткрыта, и из щели идёт холодный свет — сама
	# лампа заведена в lights.gd ('redhouse'), здесь только железо и щель.
	var fr: Array = d.get("fridge", [])
	if fr.size() == 4:
		var fx0 := float(fr[0])
		var fx1 := float(fr[1])
		var fz0 := float(fr[2])
		var fz1 := float(fr[3])
		_shell(b, fx0, fx1, fl, fl + 1.42, fz0, fz1, "metal", 0.0)
		_solid(b, out, fx0, fx1, fl, fl + 1.42, fz0, fz1)
		var glow := MeshInstance3D.new()
		glow.name = "village-redhouse-glow"
		var q := QuadMesh.new()
		q.size = Vector2(0.10, 1.10)
		glow.mesh = q
		glow.material_override = b.mats.glow(0xd8ecff)
		glow.position = Vector3(fx1 + 0.012, fl + 0.78, (fz0 + fz1) / 2.0)
		glow.rotation = Vector3(0.0, PI / 2.0, 0.0)
		glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		b.decor["village-redhouse-glow"] = glow
		nodes["redhouse-fridge"] = glow

	# Диван и кресло в заводской плёнке. Плёнку не снимали ни разу — это
	# и есть вся мысль дома, и она не проговаривается вслух ни строчкой.
	var sf: Array = d.get("sofa", [])
	if sf.size() == 4:
		var sx0 := float(sf[0])
		var sx1 := float(sf[1])
		var sz0 := float(sf[2])
		var sz1 := float(sf[3])
		_shell(b, sx0, sx1, fl, fl + 0.42, sz0, sz1, "fabric", 1.0)
		_shell(b, sx0, sx1, fl + 0.42, fl + 0.86, sz0, sz0 + 0.22, "fabric", 1.0)
		_solid(b, out, sx0, sx1, fl, fl + 0.86, sz0, sz1)
		# Плёнка: та же коробка на сантиметр больше, стеклянным материалом.
		_shell(b, sx0 - 0.02, sx1 + 0.02, fl, fl + 0.88, sz0 - 0.02, sz1 + 0.02,
			"glass", 1.0)
		nodes["redhouse-plastic"] = _holder(b, "redhouse-plastic",
			Vector3((sx0 + sx1) / 2.0, fl + 0.9, (sz0 + sz1) / 2.0))

	# Коробки, которые так и не распаковали.
	var bx: Array = d.get("boxes", [])
	if bx.size() == 2:
		var cx := float(bx[0])
		var cz := float(bx[1])
		for i in 3:
			var w := 0.42 + 0.06 * float(i % 2)
			_shell(b, cx - w, cx + w, fl + float(i) * 0.36, fl + float(i) * 0.36 + 0.34,
				cz - w, cz + w, "boards", 0.0)
		_solid(b, out, cx - 0.5, cx + 0.5, fl, fl + 1.08, cz - 0.5, cz + 0.5)

	# Стол на двоих. Накрыт и не убран — но и не тронут.
	var tb: Array = d.get("table", [])
	if tb.size() == 2:
		var tx := float(tb[0])
		var tz := float(tb[1])
		_shell(b, tx - 0.55, tx + 0.55, fl + 0.70, fl + 0.76, tz - 0.38, tz + 0.38,
			"boards", 1.0)
		for s: float in [-0.48, 0.48]:
			for q2: float in [-0.30, 0.30]:
				_shell(b, tx + s - 0.03, tx + s + 0.03, fl, fl + 0.70,
					tz + q2 - 0.03, tz + q2 + 0.03, "boards", 0.0)
		_solid(b, out, tx - 0.55, tx + 0.55, fl, fl + 0.76, tz - 0.38, tz + 0.38)

	# Детский рисунок на западной стене. Человек у забора нарисован выше дома —
	# и это единственное, что дом о себе говорит.
	var dw: Array = d.get("drawing", [])
	if dw.size() == 3:
		var draw := _holder(b, "redhouse-drawing",
			Vector3(float(dw[0]), float(dw[1]), float(dw[2])))
		_piece(draw, _box_mesh(b, Vector3(0.012, 0.30, 0.22), "", 0xc9c3ac), Vector3.ZERO)
		# Дом, забор, и над ними фигура во весь лист.
		_piece(draw, _box_mesh(b, Vector3(0.004, 0.07, 0.09), "", 0x8a5540),
			Vector3(0.008, -0.06, 0.05))
		for k in 5:
			_piece(draw, _box_mesh(b, Vector3(0.004, 0.05, 0.008), "", 0x3a3f43),
				Vector3(0.008, -0.09, -0.02 - float(k) * 0.018))
		_piece(draw, _box_mesh(b, Vector3(0.004, 0.20, 0.014), "", 0x1c1e21),
			Vector3(0.008, 0.03, -0.062))
		nodes["redhouse-drawing"] = draw

	_redhouse_upstairs(b, d, out, x0, x1, z0, z1, t, c0, c1,
		stair_top, stair_x0, stair_x1)


# Второй этаж красного дома (фаза 14). Лестница вдоль востока поднимается
# в проём, который выше уже вырезан в потолке первого этажа; наверху —
# спальня и детская, обе тесные, обе обжитые на скорую руку.
#
# ЛЕСТНИЦА. Двенадцать ступеней-коробок нарастающей высоты: перепад каждой
# 0.22 м — меньше STEP_UP игрока (player.gd, 0.25), капсула поднимается
# сама, отдельного пандуса не нужно. Марш идёт вдоль ВОСТОЧНОЙ стены, от
# двери (z1-t) на север до stairTop (-11.56); коробки первого этажа стоят
# севернее -11.70, то есть марша не касаются. Обеденный стол ради марша
# сдвинут на запад — см. комментарий в data/village.json.
static func _redhouse_upstairs(b: WorldBuilder, d: Dictionary, out: Dictionary,
		x0: float, x1: float, z0: float, z1: float, t: float,
		c0: float, c1: float, stair_top: float,
		stair_x0: float, stair_x1: float) -> void:
	var eave2 := float(d.get("eave2", 0.0))
	if eave2 <= c1:
		return
	var nodes: Dictionary = out["nodes"]
	var door_z := z1 - t
	var steps := 12
	var run := (door_z - stair_top) / float(steps)
	var rise := (c1 - 0.0) / float(steps)  # от пола первого этажа до плиты
	for i in steps:
		var top_y := (float(i) + 1.0) * rise
		var za := door_z - (float(i) + 1.0) * run
		var zb := door_z - float(i) * run
		_solid(b, out, stair_x0, stair_x1, 0.0, top_y, za, zb, "redhouse-stair-%d" % i)
		_shell(b, stair_x0, stair_x1, top_y - 0.03, top_y, za, zb, "boards", 0.6)

	# --- стены второго этажа ---
	var y0 := c1
	var y1 := eave2
	_solid(b, out, x0, x1, y0, y1, z0, z0 + t)                 # север
	_solid(b, out, x0, x0 + t, y0, y1, z0 + t, z1 - t)          # запад
	_solid(b, out, x1 - t, x1, y0, y1, z0 + t, z1 - t)          # восток

	# Южная стена с двумя окнами (второй ряд из street.json): семь кусков —
	# три full-height простенка и по два коротких над/под каждым окном.
	var wins: Array = d.get("windows2", [[-0.9, 0.1], [2.0, 3.0]])
	var wy: Array = d.get("windowY2", [3.6, 4.6])
	var wy0 := float(wy[0])
	var wy1 := float(wy[1])
	if wins.size() == 2:
		var w1: Array = wins[0]
		var w2: Array = wins[1]
		var w1a := float(w1[0])
		var w1b := float(w1[1])
		var w2a := float(w2[0])
		var w2b := float(w2[1])
		_solid(b, out, x0 + t, w1a, y0, y1, z1 - t, z1)
		_solid(b, out, w1b, w2a, y0, y1, z1 - t, z1)
		_solid(b, out, w2b, x1 - t, y0, y1, z1 - t, z1)
		_solid(b, out, w1a, w1b, y0, wy0, z1 - t, z1)
		_solid(b, out, w2a, w2b, y0, wy0, z1 - t, z1)
		_solid(b, out, w1a, w1b, wy1, y1, z1 - t, z1)
		_solid(b, out, w2a, w2b, wy1, y1, z1 - t, z1)

		# Южная стена ИЗНУТРИ. Её здесь не было, и на снимке приёмки она
		# читалась чёрным провалом во всю ширину комнаты: обои шли по трём
		# глухим стенам, а четвёртая — та самая, в которой окна и к которой
		# повёрнута игрушка, — оставалась голой коробкой без единой грани,
		# смотрящей внутрь. Семь кусков, ровно по семи твёрдым выше.
		var s_in := z1 - t
		_shell(b, x0 + t, w1a, y0, y1, s_in, s_in + 0.02, "plank", 0.0)
		_shell(b, w1b, w2a, y0, y1, s_in, s_in + 0.02, "plank", 0.0)
		_shell(b, w2b, x1 - t, y0, y1, s_in, s_in + 0.02, "plank", 0.0)
		_shell(b, w1a, w1b, y0, wy0, s_in, s_in + 0.02, "plank", 0.0)
		_shell(b, w2a, w2b, y0, wy0, s_in, s_in + 0.02, "plank", 0.0)
		_shell(b, w1a, w1b, wy1, y1, s_in, s_in + 0.02, "plank", 0.0)
		_shell(b, w2a, w2b, wy1, y1, s_in, s_in + 0.02, "plank", 0.0)

	# Видимое: обои по трём глухим стенам, тем же ключом, что первый этаж.
	_shell(b, x0 + 0.02, x0 + t + 0.02, y0, y1, z0 + t, z1 - t, "plank", 0.0)
	_shell(b, x1 - t - 0.02, x1 - 0.02, y0, y1, z0 + t, z1 - t, "plank", 0.0)
	_shell(b, x0 + t - 0.02, x1 - t + 0.02, y0, y1, z0 + t - 0.02, z0 + t, "plank", 0.0)
	_shell(b, x0 + t, x1 - t, y1 - 0.02, y1, z0 + t, z1 - t, "boards", 1.2)

	# --- спальня: кровать у северной стены ---
	var bed: Array = d.get("bed", [])
	if bed.size() == 2:
		var bx := float(bed[0])
		var bz := float(bed[1])
		_shell(b, bx - 0.55, bx + 0.55, c1, c1 + 0.32, bz - 0.95, bz + 0.95, "fabric", 1.0)
		_shell(b, bx - 0.55, bx + 0.55, c1 + 0.32, c1 + 0.58, bz - 0.95, bz - 0.65, "carpetWhite", 0.0)
		_solid(b, out, bx - 0.55, bx + 0.55, c1, c1 + 0.58, bz - 0.95, bz + 0.95)

	# --- детская: стол у окна ---
	var desk: Array = d.get("desk", [])
	if desk.size() == 2:
		var dx := float(desk[0])
		var dz := float(desk[1])
		_shell(b, dx - 0.42, dx + 0.42, c1 + 0.62, c1 + 0.68, dz - 0.26, dz + 0.26, "boards", 0.8)
		_solid(b, out, dx - 0.42, dx + 0.42, c1, c1 + 0.68, dz - 0.26, dz + 0.26)
		# Улика на столе — держит СКРИМЕР №2 фазы. Отдельный узел без
		# коллизии: точку интеракта заводит village_quest.gd.
		nodes["redhouse-desk-item"] = _holder(b, "redhouse-desk-item",
			Vector3(dx, c1 + 0.70, dz))

	# Игрушка на подоконнике южного окна, повёрнутая к Витиному дому: окна
	# второго этажа смотрят через дорогу прямо на его калитку. Гэг-осмотр,
	# без коллизии.
	var toy: Array = d.get("toy", [])
	if toy.size() == 3:
		var tp := Vector3(float(toy[0]), float(toy[1]), float(toy[2]))
		var n := _holder(b, "redhouse-toy", tp)
		_piece(n, _box_mesh(b, Vector3(0.05, 0.09, 0.05), "", 0xc9c3ac), Vector3.ZERO)
		_piece(n, _box_mesh(b, Vector3(0.06, 0.02, 0.06), "", 0x8a5540), Vector3(0, -0.055, 0))
		nodes["redhouse-toy"] = n


# ------------------------------------------------- мелочь заданий (фаза 13) --

# Три предмета, которые превращают остановку, трактор и колодец из осмотров
# в цепочку: половина расписания под скамьёй, монтировка в кабине, свёрток
# в ведре. Ни одного нового механизма — бумажка, железка и узел, который
# появляется, когда ворот пошёл.
static func _quest13(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var nodes: Dictionary = out["nodes"]

	var stop: Dictionary = d.get("STOP", {})
	var hf: Array = stop.get("half", [])
	if hf.size() == 3:
		nodes["stop-half"] = _paper(b, "stop-half",
			Vector3(float(hf[0]), float(hf[1]), float(hf[2])), 0.22, 0.16)

	var tr: Dictionary = d.get("TRACTOR", {})
	var cb: Array = tr.get("crowbar", [])
	if cb.size() == 3:
		var bar := _holder(b, "crowbar",
			Vector3(float(cb[0]), float(cb[1]), float(cb[2])))
		_piece(bar, _box_mesh(b, Vector3(0.9, 0.035, 0.035), "", 0x4e5459),
			Vector3.ZERO, Vector3(0.0, 0.4, 0.06))
		_piece(bar, _box_mesh(b, Vector3(0.12, 0.05, 0.035), "", 0x4e5459),
			Vector3(0.41, 0.02, 0.17), Vector3(0.0, 0.4, 0.55))
		nodes["crowbar"] = bar
	var kt: Array = tr.get("kit", [])
	if kt.size() == 3:
		var kit := _holder(b, "tractor-kit",
			Vector3(float(kt[0]), float(kt[1]), float(kt[2])))
		# Куртка сложена вчетверо, термос закручен и стоит рядом.
		_piece(kit, _box_mesh(b, Vector3(0.34, 0.11, 0.26), "", 0x3d4b52), Vector3.ZERO)
		var flask := CylinderMesh.new()
		flask.top_radius = 0.045
		flask.bottom_radius = 0.05
		flask.height = 0.26
		flask.radial_segments = 8
		flask.rings = 1
		flask.material = b.mats.flat(0x8b9095, true)
		_piece(kit, flask, Vector3(0.26, 0.07, -0.02))
		nodes["tractor-kit"] = kit

	var well: Dictionary = d.get("WELL", {})
	var rs: Array = well.get("raised", [])
	if rs.size() == 3:
		nodes["well-raised"] = _bucket(b,
			Vector3(float(rs[0]), float(rs[1]), float(rs[2])))
		(nodes["well-raised"] as Node3D).visible = false
	var bd: Array = well.get("bundle", [])
	if bd.size() == 3:
		var bun := _holder(b, "well-bundle",
			Vector3(float(bd[0]), float(bd[1]), float(bd[2])), false)
		_piece(bun, _box_mesh(b, Vector3(0.22, 0.13, 0.16), "", 0xb6ae9a), Vector3.ZERO)
		for k in 3:
			_piece(bun, _box_mesh(b, Vector3(0.235, 0.012, 0.012), "", 0x5d4530),
				Vector3(0.0, 0.0, -0.05 + float(k) * 0.05))
		nodes["well-bundle"] = bun


# Открытый капот «Шестёрки». Без него первый шаг главы не виден глазами:
# игрок жмёт [E] «открыть капот», слышит скрип, читает строку — и машина
# в кадре остаётся ровно той же. Отсюда и узел.
#
# Проп car (props.json, заморожен) стоит в (1.1, 0, -2.7) и повёрнут на 90°,
# поэтому длина у него идёт по МИРОВОМУ x: кузов x [-0.92, 3.12], ширина
# z [-3.51, -1.89], крышка на y = 0.73. Нос — на западе, у x = -0.92; петли
# капота, стало быть, у основания лобового, x = 0.15.
#
# Коллизии нет вообще: узел стоит в полосе StreetStalk (z [-5.5, -0.9]),
# и любая коробка здесь перегородила бы деду дорогу — см. test_street_clear.
static func _hood(b: WorldBuilder, out: Dictionary) -> void:
	var n := _holder(b, "car-hood-open", Vector3(0.15, 0.73, -2.70), false)
	var paint := 0x2f4f52
	# Крышка поднята на 55°: угол отрицательный, потому что поворот вокруг
	# мировой z уводит -x вверх только в эту сторону.
	var a := -0.96
	_piece(n, _box_mesh(b, Vector3(1.05, 0.05, 1.45), "", paint),
		Vector3(-0.525 * cos(a), -0.525 * sin(a), 0.0), Vector3(0.0, 0.0, a))
	# Упор капота — тонкий прут от кузова к поднятой крышке.
	_piece(n, _box_mesh(b, Vector3(0.022, 0.62, 0.022), "", 0x8a8f92),
		Vector3(-0.30, 0.31, 0.44), Vector3(0.0, 0.0, 0.22))
	# Подкапотное: тёмный проём на крышке кузова и мотор в нём. Проём —
	# плоскость, а не вырез: кузов у пропа сплошной, и дырку в нём не сделать.
	_piece(n, _box_mesh(b, Vector3(1.00, 0.02, 1.34), "", 0x101215),
		Vector3(-0.52, 0.006, 0.0))
	_piece(n, _box_mesh(b, Vector3(0.62, 0.20, 0.86), "", 0x2a2d30),
		Vector3(-0.52, 0.10, 0.0))
	_piece(n, _box_mesh(b, Vector3(0.30, 0.10, 0.24), "", 0x3a3d40),
		Vector3(-0.30, 0.22, -0.22))
	# Пустое гнездо трамблёра. Ради этой дырки существует вся глава,
	# поэтому она светлее всего остального под капотом.
	var seat := CylinderMesh.new()
	seat.top_radius = 0.062
	seat.bottom_radius = 0.062
	seat.height = 0.05
	seat.radial_segments = 10
	seat.rings = 1
	seat.material = b.mats.flat(0x0a0b0c, true)
	_piece(n, seat, Vector3(-0.30, 0.26, 0.24))
	(out["nodes"] as Dictionary)["car-hood-open"] = n


# Два предмета, которые существуют только ради знаков (omens.gd, фаза 12):
# велосипед, которого у забора не было, и свет, который на секунду появляется
# за досками заколоченного окна. Оба невидимы с загрузки и оба БЕЗ коллизии —
# знак не имеет права запереть игроку дорогу.
static func _omens(b: WorldBuilder, out: Dictionary) -> void:
	var nodes: Dictionary = out["nodes"]

	var bike := _holder(b, "street-bike", Vector3(-11.20, 0.0, -6.60), false)
	bike.rotation.y = 0.42
	for s: float in [-0.52, 0.52]:
		var wh := TorusMesh.new()
		wh.inner_radius = 0.26
		wh.outer_radius = 0.33
		wh.rings = 12
		wh.ring_segments = 4
		wh.material = b.mats.flat(0x1c1e21, true)
		_piece(bike, wh, Vector3(0, 0.33, s), Vector3(PI * 0.5, 0.0, 0.0))
	_piece(bike, _box_mesh(b, Vector3(0.05, 0.05, 1.02), "", 0x3d4b52), Vector3(0, 0.56, 0))
	_piece(bike, _box_mesh(b, Vector3(0.045, 0.42, 0.045), "", 0x3d4b52),
		Vector3(0, 0.66, -0.44), Vector3(0.22, 0.0, 0.0))
	_piece(bike, _box_mesh(b, Vector3(0.05, 0.05, 0.44), "", 0x1c1e21), Vector3(0, 0.92, -0.50))
	_piece(bike, _box_mesh(b, Vector3(0.12, 0.06, 0.26), "", 0x4a3524), Vector3(0, 0.80, 0.18))
	nodes["street-bike"] = bike

	var glow := MeshInstance3D.new()
	glow.name = "village-boarded-glow"
	var q := QuadMesh.new()
	q.size = Vector2(3.4, 1.5)
	glow.mesh = q
	glow.material_override = b.mats.glow(0xffd7a0, 0.55)
	# Внутри дома, у самой южной стены: свет идёт ИЗ комнаты и виден только
	# в просветы между досками — ровно как горящее окно за нишей фасада.
	glow.position = Vector3(-5.50, 1.60, -7.78)
	glow.visible = false
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b.decor["village-boarded-glow"] = glow
	nodes["boarded-glow"] = glow


# ------------------------------------------------------------- примитивы ----

## Видимое. collide зашит в false: это не забывчивость вызывающего, а условие
## паритета, и способа написать иначе здесь нет.
static func _shell(b: WorldBuilder, x0: float, x1: float, y0: float, y1: float,
		z0: float, z1: float, key: String, seg := 0.0) -> void:
	b.box(x0, x1, y0, y1, z0, z1, key, seg, false)


## Твёрдое — только в четвёртый набор. Попутно копит AABB: по нему
## test_street_clear меряет полосу деда, кольцо Аркадия и пол под ногами.
static func _solid(b: WorldBuilder, out: Dictionary, x0: float, x1: float,
		y0: float, y1: float, z0: float, z1: float, id := "") -> void:
	var ax := minf(x0, x1)
	var ay := minf(y0, y1)
	var az := minf(z0, z1)
	var bx := maxf(x0, x1)
	var by := maxf(y0, y1)
	var bz := maxf(z0, z1)
	if bx - ax < 0.0005 or by - ay < 0.0005 or bz - az < 0.0005:
		return
	b.col.add_box_d(CollisionWorld.SET_OVERLAY, ax, ay, az, bx, by, bz, id)
	(out["boxes"] as Array).append(AABB(Vector3(ax, ay, az),
		Vector3(bx - ax, by - ay, bz - az)))


## Скат с явным девятым аргументом. Обёртка нужна ровно ради него: у _slope()
## collide по умолчанию true, и забытый аргумент виден только в диффе.
static func _slope_soft(b: WorldBuilder, x0: float, x1: float, z0: float, z1: float,
		ya: float, yb: float, key: String, t: float) -> void:
	b._slope(x0, x1, z0, z1, ya, yb, key, t, false)


## Свой фронтон. WorldBuilder._gable() зовёт box() без collide = false и уходит
## в SET_STATIC целиком — брать его нельзя.
static func _gable_soft(b: WorldBuilder, x: float, z0: float, zr: float, z1: float,
		y_eave: float, y_ridge: float, key: String, t := 0.12) -> void:
	var steps := 6
	for i in steps:
		var q0 := float(i) / steps
		var q1 := float(i + 1) / steps
		var y0 := y_eave + (y_ridge - y_eave) * q0
		var y1 := y_eave + (y_ridge - y_eave) * q1
		var za := z0 + (zr - z0) * q1
		var zb := z1 - (z1 - zr) * q1
		_shell(b, x - t / 2.0, x + t / 2.0, y0, y1, za, zb, key, 1.5)


# ------------------------------------------------------- автобусная остановка --

# Западный конец линии. Навес открыт на юг, к дороге; на задней стенке —
# расписание, из которого видно, что рейс отменён с девятого августа. Это тот же
# день, что последняя запись в журнале сельпо: деревня встала не сегодня ночью.
static func _stop(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var t := float(d.get("wall", 0.14))
	var fl := float(d.get("floor", 0.10))
	var eave := float(d.get("eave", 2.30))
	var ridge := float(d.get("ridge", 2.62))

	# --- твёрдое: пол, задняя стенка, две боковины, кровля ---
	_solid(b, out, x0, x1, 0.0, fl, z0, z1)
	_solid(b, out, x0, x1, fl, eave, z0, z0 + t)
	_solid(b, out, x0, x0 + t, fl, eave, z0 + t, z1)
	_solid(b, out, x1 - t, x1, fl, eave, z0 + t, z1)
	_solid(b, out, x0, x1, eave, eave + 0.10, z0, z1)

	# --- видимое ---
	_shell(b, x0 - 0.10, x1 + 0.10, 0.0, fl, z0 - 0.10, z1 + 0.10, "concrete", 1.4)
	_shell(b, x0, x1, fl, eave, z0, z0 + t, "profile", 0.0)
	_shell(b, x0, x0 + t, fl, eave, z0 + t, z1, "profile", 0.0)
	_shell(b, x1 - t, x1, fl, eave, z0 + t, z1, "profile", 0.0)
	# Навес — жесть, а не синее железо: остановку крыли не тем, чем дома.
	_slope_soft(b, x0 - 0.28, x1 + 0.28, z0 - 0.24, (z0 + z1) / 2.0, ridge, eave, "tin", 0.09)
	_slope_soft(b, x0 - 0.28, x1 + 0.28, (z0 + z1) / 2.0, z1 + 0.34, eave, eave - 0.06,
		"tin", 0.09)
	# Стойки под передней кромкой навеса: без них козырёк висит сам по себе.
	for s: float in [x0 + 0.22, x1 - 0.22]:
		_shell(b, s - 0.05, s + 0.05, fl, eave, z1 - 0.10, z1, "metal", 1.2)

	# Скамья.
	var bn: Array = d.get("bench", [])
	if bn.size() == 5:
		var by := float(bn[4])
		_shell(b, float(bn[0]), float(bn[1]), by, by + 0.05, float(bn[2]), float(bn[3]),
			"boards", 0.9)
		for s: float in [float(bn[0]) + 0.24, float(bn[1]) - 0.24]:
			_shell(b, s - 0.05, s + 0.05, fl, by, float(bn[2]) + 0.06, float(bn[3]) - 0.06,
				"metal", 1.0)
		_solid(b, out, float(bn[0]), float(bn[1]), fl, by + 0.05,
			float(bn[2]), float(bn[3]))

	# Расписание на задней стенке. Что на нём написано, читает точка осмотра.
	var sg: Array = d.get("sign", [])
	if sg.size() == 4:
		_shell(b, float(sg[0]), float(sg[1]), float(sg[2]), float(sg[3]),
			z0 + t, z0 + t + 0.02, "trim", 0.0)
		_shell(b, float(sg[0]) - 0.04, float(sg[1]) + 0.04, float(sg[3]),
			float(sg[3]) + 0.05, z0 + t, z0 + t + 0.03, "dark", 0.0)

	(out["nodes"] as Dictionary)["stop-schedule"] = _holder(b, "stop-schedule",
		Vector3((x0 + x1) / 2.0, 1.5, z0 + t + 0.05))


# --------------------------------------------------------------- трактор ----

# Остов в бурьяне. Передних колёс нет, кабина без стёкол — от ворот видно только
# силуэт, и он единственный на улице, у которого нет ни окна, ни двери.
static func _tractor(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var cx := (float(xr[0]) + float(xr[1])) / 2.0
	var cz := (float(zr[0]) + float(zr[1])) / 2.0
	var r := float(d.get("wheel", 0.78))
	var cab: Array = d.get("cab", [1.55, 2.55])

	# Корпус и капот.
	_solid(b, out, cx - 0.55, cx + 0.55, 0.30, 1.45, cz - 1.30, cz + 0.60)
	_shell(b, cx - 0.55, cx + 0.55, 0.30, 1.45, cz - 1.30, cz + 0.60, "metal", 1.6)
	_shell(b, cx - 0.42, cx + 0.42, 1.45, 1.62, cz - 1.20, cz - 0.10, "dark", 1.2)
	# Кабина: четыре стойки и крыша, стёкол нет.
	for sx: float in [cx - 0.52, cx + 0.52]:
		for sz: float in [cz + 0.10, cz + 0.55]:
			_shell(b, sx - 0.05, sx + 0.05, float(cab[0]), float(cab[1]),
				sz - 0.05, sz + 0.05, "metal", 1.0)
	_shell(b, cx - 0.60, cx + 0.60, float(cab[1]), float(cab[1]) + 0.09,
		cz + 0.02, cz + 0.66, "tin", 1.0)
	_solid(b, out, cx - 0.58, cx + 0.58, 1.45, float(cab[1]), cz + 0.05, cz + 0.62)
	# Задние колёса — единственное, что от него осталось целым.
	#
	# ФАЗА 16. Твёрдость колёс была ДВУМЯ отдельными коробками по бокам
	# корпуса, и между корпусом (до cx ± 0.55) и колесом (от cx ± 0.64)
	# оставались две щели по 9 см. Капсула радиуса 0.30 в них не лезет, но
	# упирается в них носом — игрок видит проход и не проходит. Теперь колёса
	# и ось между ними — одна коробка на всю ширину трактора.
	for sx: float in [cx - 0.80, cx + 0.80]:
		var w := CylinderMesh.new()
		w.top_radius = r
		w.bottom_radius = r
		w.height = 0.30
		w.radial_segments = 12
		w.rings = 1
		w.material = b.mats.flat(0x1c1e21, true)
		var mi := MeshInstance3D.new()
		mi.mesh = w
		mi.position = Vector3(sx, r, cz + 0.42)
		mi.rotation = Vector3(0.0, 0.0, PI * 0.5)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		b.decor["village-tractor-wheel-%d" % int(roundf(sx * 10.0))] = mi
	_solid(b, out, cx - 0.96, cx + 0.96, 0.0, r * 2.0, cz + 0.42 - r, cz + 0.42 + r)
	# Передняя ось лежит на земле: машину разули на месте.
	_shell(b, cx - 0.70, cx + 0.70, 0.0, 0.14, cz - 1.85, cz - 1.60, "metal", 1.0)
	(out["nodes"] as Dictionary)["tractor"] = _holder(b, "tractor",
		Vector3(cx, 1.2, cz - 1.6))


# --------------------------------------------------------------- колодец ----

static func _well(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var cr: Array = d.get("crib", [])
	if cr.size() != 4:
		return
	var x0 := float(cr[0])
	var x1 := float(cr[1])
	var z0 := float(cr[2])
	var z1 := float(cr[3])
	var h := float(d.get("cribH", 0.95))
	var post := float(d.get("postH", 2.05))
	var roof := float(d.get("roof", 2.55))
	var t := 0.14

	# Сруб: четыре стенки, а не куб. В колодец надо смотреть, и если он сплошной,
	# это читается как ящик, а не как колодец.
	_solid(b, out, x0, x1, 0.0, h, z0, z0 + t)
	_solid(b, out, x0, x1, 0.0, h, z1 - t, z1)
	_solid(b, out, x0, x0 + t, 0.0, h, z0 + t, z1 - t)
	_solid(b, out, x1 - t, x1, 0.0, h, z0 + t, z1 - t)
	_shell(b, x0, x1, 0.0, h, z0, z0 + t, "log", 0.9)
	_shell(b, x0, x1, 0.0, h, z1 - t, z1, "log", 0.9)
	_shell(b, x0, x0 + t, 0.0, h, z0 + t, z1 - t, "log", 0.9)
	_shell(b, x1 - t, x1, 0.0, h, z0 + t, z1 - t, "log", 0.9)
	# Дно — тёмный квадрат в полуметре: без него в срубе видно траву.
	_shell(b, x0 + t, x1 - t, -0.52, -0.50, z0 + t, z1 - t, "dark", 0.0)

	# Стойки, ворот и ручка.
	var cx := (x0 + x1) / 2.0
	var cz := (z0 + z1) / 2.0
	for sz: float in [z0 + t / 2.0, z1 - t / 2.0]:
		_shell(b, cx - 0.06, cx + 0.06, h, post, sz - 0.06, sz + 0.06, "boards", 1.2)
	var drum := CylinderMesh.new()
	drum.top_radius = 0.11
	drum.bottom_radius = 0.11
	drum.height = z1 - z0 - t
	drum.radial_segments = 8
	drum.rings = 1
	drum.material = b.mats.get_mat("boards")
	var dm := MeshInstance3D.new()
	dm.mesh = drum
	dm.position = Vector3(cx, post - 0.12, cz)
	dm.rotation = Vector3(PI * 0.5, 0.0, 0.0)
	dm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	b.decor["village-well-drum"] = dm
	_shell(b, cx - 0.05, cx + 0.05, post - 0.12, post + 0.16, z1 - t / 2.0,
		z1 - t / 2.0 + 0.06, "metal", 0.0)
	_shell(b, cx - 0.05, cx + 0.28, post + 0.10, post + 0.16, z1 - t / 2.0 + 0.06,
		z1 - t / 2.0 + 0.12, "metal", 0.0)
	# Цепь: она и есть звук колодца.
	_shell(b, cx - 0.02, cx + 0.02, h - 0.18, post - 0.16, cz - 0.02, cz + 0.02, "metal", 0.4)

	# Домик над колодцем.
	_slope_soft(b, x0 - 0.34, x1 + 0.34, z0 - 0.34, cz, roof, post + 0.05, "tin", 0.08)
	_slope_soft(b, x0 - 0.34, x1 + 0.34, cz, z1 + 0.34, post + 0.05, roof, "tin", 0.08)
	_gable_soft(b, x0 + 0.04, z0, cz, z1, post + 0.05, roof, "boards")
	_gable_soft(b, x1 - 0.04, z0, cz, z1, post + 0.05, roof, "boards")

	var nodes: Dictionary = out["nodes"]
	var bk: Array = d.get("bucket", [])
	if bk.size() == 3:
		nodes["well-bucket"] = _bucket(b,
			Vector3(float(bk[0]), float(bk[1]), float(bk[2])))
	# Водоразборная колонка в стороне: чугунная тумба с рычагом.
	var cl: Array = d.get("column", [])
	if cl.size() == 2:
		var px := float(cl[0])
		var pz := float(cl[1])
		_shell(b, px - 0.14, px + 0.14, 0.0, 0.14, pz - 0.14, pz + 0.14, "concrete", 0.0)
		_shell(b, px - 0.09, px + 0.09, 0.14, 1.02, pz - 0.09, pz + 0.09, "metal", 1.0)
		_shell(b, px - 0.06, px + 0.24, 0.86, 0.94, pz - 0.05, pz + 0.05, "metal", 0.0)
		_shell(b, px - 0.05, px + 0.05, 1.02, 1.30, pz - 0.05, pz + 0.22, "metal", 0.0)
		_solid(b, out, px - 0.14, px + 0.14, 0.0, 1.30, pz - 0.14, pz + 0.14)
		nodes["well-column"] = _holder(b, "well-column", Vector3(px, 1.05, pz))
	nodes["well"] = _holder(b, "well", Vector3(cx, h, cz))


# ------------------------------------------------- трансформаторная будка ----

static func _booth(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var h := float(d.get("h", 2.70))
	var dr: Array = d.get("door", [x0 + 0.6, x1 - 0.6])
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	var dtop := float(d.get("doorTop", 2.05))

	# Кирпичный куб целиком твёрдый: внутрь трансформаторной не заходят.
	_solid(b, out, x0, x1, 0.0, h, z0, z1)
	_shell(b, x0, x1, 0.0, h, z0, z1, "brick", 2.0)
	_shell(b, x0 - 0.12, x1 + 0.12, h, h + 0.12, z0 - 0.12, z1 + 0.12, "concrete", 1.2)
	# Железная дверь и знак на ней.
	_shell(b, d0, d1, 0.06, dtop, z1 - 0.02, z1 + 0.05, "metal", 1.2)
	var cx := (d0 + d1) / 2.0
	_shell(b, cx - 0.13, cx + 0.13, 1.32, 1.66, z1 + 0.05, z1 + 0.07, "trim", 0.0)
	# Три фарфоровых изолятора на крыше: по ним будка и опознаётся.
	for i in 3:
		var ix := x0 + (x1 - x0) * (float(i) + 1.0) / 4.0
		_shell(b, ix - 0.05, ix + 0.05, h + 0.12, h + 0.46, (z0 + z1) / 2.0 - 0.05,
			(z0 + z1) / 2.0 + 0.05, "trim", 0.0)
	(out["nodes"] as Dictionary)["booth"] = _holder(b, "booth", Vector3(cx, 1.5, z1 + 0.10))


# ----------------------------------------------------------------- сельпо ----

# Первый из двух интерьеров фазы. Строится по правилам бани, они же — список
# ловушек: проём вырезается и в коллизии тоже, торцевые стены идут на всю
# длину, потолок обязателен (без него ray_down не находит пол и игрок
# проваливается), проходимость проёма меряется центрами сфер капсулы.
static func _shop(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])          # север, глухая стена
	var z1 := float(zr[1])          # юг, фасад с дверью и витриной
	var t := float(d.get("wall", 0.20))
	var fl := float(d.get("floor", 0.14))
	var eave := float(d.get("eave", 2.85))
	var ridge := float(d.get("ridge", 3.70))
	var rz := float(d.get("ridgeZ", (z0 + z1) / 2.0))
	var dr: Array = d["door"]
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	var dtop := float(d.get("doorTop", 2.05))
	var wn: Array = d["win"]
	var w0 := float(wn[0])
	var w1 := float(wn[1])
	var wy0 := float(wn[2])
	var wy1 := float(wn[3])
	var cr: Array = d.get("ceil", [2.55, 2.70])
	var c0 := float(cr[0])
	var c1 := float(cr[1])

	# --- твёрдое ---
	_solid(b, out, x0, x1, 0.0, fl, z0, z1)                       # пол
	_solid(b, out, x0, x1, fl, eave, z0, z0 + t)                  # север
	_solid(b, out, x0, x0 + t, fl, eave, z0 + t, z1 - t)          # запад
	_solid(b, out, x1 - t, x1, fl, eave, z0 + t, z1 - t)          # восток
	_south_solid(b, out, x0, x1, fl, eave, z1 - t, z1, d0, d1, dtop, w0, w1, wy0, wy1)
	_solid(b, out, x0 + t, x1 - t, c0, c1, z0 + t, z1 - t)        # потолок

	# --- видимое ---
	_shell(b, x0 - 0.08, x1 + 0.08, 0.0, fl, z0 - 0.08, z1 + 0.08, "plinth", 1.1)
	_shell(b, x0, x1, fl, eave, z0, z0 + t, "siding", 0.0)
	_shell(b, x0, x0 + t, fl, eave, z0 + t, z1 - t, "siding", 0.0)
	_shell(b, x1 - t, x1, fl, eave, z0 + t, z1 - t, "siding", 0.0)
	_south_skin(b, x0, x1, fl, eave, z1 - t, z1, d0, d1, dtop, w0, w1, wy0, wy1, "siding")
	_shell(b, x0 + t, x1 - t, c0, c1, z0 + t, z1 - t, "boards", 1.6)
	_shell(b, x0 + t, x1 - t, fl - 0.02, fl + 0.006, z0 + t, z1 - t, "boards", 1.3)
	# Внутренняя обшивка зала. Без неё сельпо изнутри красное: _shell красит
	# коробку стены со всех шести сторон разом, и наружная вагонка приходит
	# внутрь как есть. Зал от этого читался сараем, а не магазином.
	_shell(b, x0 + t, x1 - t, fl, c0, z0 + t, z0 + t + 0.02, "whitewash", 1.0)
	_shell(b, x0 + t, x0 + t + 0.02, fl, c0, z0 + t, z1 - t, "whitewash", 1.0)
	_shell(b, x1 - t - 0.02, x1 - t, fl, c0, z0 + t, z1 - t, "whitewash", 1.0)
	_south_skin(b, x0 + t, x1 - t, fl, c0, z1 - t - 0.02, z1 - t,
		d0, d1, dtop, w0, w1, wy0, wy1, "whitewash")

	# Белая обналичка двери и витрины — та же, что на окнах дома.
	_case(b, d0, d1, fl, dtop, z1)
	_case(b, w0, w1, wy0, wy1, z1)
	# Стекло витрины и переплёт.
	b.plane(w1 - w0, wy1 - wy0, "glass",
		Vector3((w0 + w1) / 2.0, (wy0 + wy1) / 2.0, z1 - t / 2.0), 0.0, 0.0, 3, 2)
	_shell(b, (w0 + w1) / 2.0 - 0.02, (w0 + w1) / 2.0 + 0.02, wy0, wy1,
		z1 - t / 2.0 - 0.02, z1 - t / 2.0 + 0.02, "dark", 1.0)
	# Вывеска над дверью. Что на ней написано, с двадцати метров не разобрать,
	# и не надо: важно, что над дверью висит светлая доска.
	_shell(b, d0 - 1.10, d1 + 1.10, dtop + 0.20, dtop + 0.62, z1 - 0.02, z1 + 0.04,
		"trim", 1.0)
	# Крыльцо: две ступени и площадка вровень с полом.
	_shell(b, d0 - 0.80, d1 + 0.80, 0.0, 0.07, z1 + 0.42, z1 + 0.86, "concrete", 1.2)
	_shell(b, d0 - 0.95, d1 + 0.95, 0.0, fl, z1 - 0.02, z1 + 0.44, "concrete", 1.2)

	# Створка на врезном замке. Своего блокера в built.blockers у неё нет:
	# коробка живёт в четвёртом наборе под своим именем, и гасить её нужно там же
	# (col.set_blocker_active), ровно как створку правления.
	var leaf := Node3D.new()
	leaf.name = "door-shop"
	var lm := MeshInstance3D.new()
	var lb := BoxMesh.new()
	lb.size = Vector3(d1 - d0 - 0.04, dtop - fl - 0.04, 0.06)
	lb.material = b.mats.get_mat("counter")
	lm.mesh = lb
	lm.position = Vector3((d1 - d0) / 2.0 - 0.02, (dtop - fl) / 2.0, 0.0)
	lm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	leaf.add_child(lm)
	var plate := MeshInstance3D.new()
	plate.name = "lock"
	var pm := BoxMesh.new()
	pm.size = Vector3(0.09, 0.16, 0.05)
	pm.material = b.mats.flat(0x7d8288, true)
	plate.mesh = pm
	plate.position = Vector3(d1 - d0 - 0.13, (dtop - fl) * 0.50, 0.03)
	plate.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	leaf.add_child(plate)
	leaf.position = Vector3(d0, fl, z1 - 0.06)
	b.decor["village-door-shop"] = leaf
	(out["nodes"] as Dictionary)["door-shop"] = leaf
	_solid(b, out, d0, d1, fl, dtop, z1 - 0.10, z1 - 0.02, "door-shop")

	# Кровля.
	_slope_soft(b, x0 - 0.34, x1 + 0.34, z0 - 0.34, rz, eave, ridge, "roof", 0.12)
	_slope_soft(b, x0 - 0.34, x1 + 0.34, rz, z1 + 0.34, ridge, eave, "roof", 0.12)
	_gable_soft(b, x0 + 0.06, z0, rz, z1, eave, ridge, "siding")
	_gable_soft(b, x1 - 0.06, z0, rz, z1, eave, ridge, "siding")

	# --- начинка ---
	var nodes: Dictionary = out["nodes"]
	var cn: Array = d.get("counter", [])
	if cn.size() == 5:
		var cy := float(cn[4])
		_shell(b, float(cn[0]), float(cn[1]), fl, cy, float(cn[2]), float(cn[3]),
			"counter", 1.3)
		_shell(b, float(cn[0]) - 0.04, float(cn[1]) + 0.04, cy, cy + 0.05,
			float(cn[2]) - 0.04, float(cn[3]) + 0.04, "boards", 1.0)
		_solid(b, out, float(cn[0]), float(cn[1]), fl, cy + 0.05,
			float(cn[2]), float(cn[3]))
	var sh: Array = d.get("shelves", [])
	if sh.size() == 4:
		for i in 3:
			var y := fl + 0.62 + float(i) * 0.60
			_shell(b, float(sh[0]), float(sh[1]), y, y + 0.05, float(sh[2]), float(sh[3]),
				"boards", 1.4)
		_solid(b, out, float(sh[0]), float(sh[1]), fl, fl + 2.00,
			float(sh[2]), float(sh[3]))
		# Товар на полках: пустые коробки и банки — сельпо стоит с августа.
		for i in 11:
			var bx := float(sh[0]) + 0.42 + float(i) * 0.62
			var row := i % 3
			_shell(b, bx, bx + 0.30, fl + 0.67 + float(row) * 0.60,
				fl + 0.67 + float(row) * 0.60 + 0.26,
				float(sh[2]) + 0.06, float(sh[3]) - 0.06, "shedwood", 0.0)
	var cx2: Array = d.get("crate", [])
	if cx2.size() == 5:
		nodes["shop-crate"] = _crate(b, "shop-crate",
			Vector3(float(cx2[0]), fl, float(cx2[2])),
			float(cx2[1]) - float(cx2[0]), float(cx2[4]), float(cx2[3]) - float(cx2[2]))
		_solid(b, out, float(cx2[0]), float(cx2[1]), fl, fl + float(cx2[4]),
			float(cx2[2]), float(cx2[3]))
	var sc: Array = d.get("scales", [])
	if sc.size() == 2:
		nodes["shop-scales"] = _scales(b, Vector3(float(sc[0]), 1.05, float(sc[1])))
	var lg: Array = d.get("ledger", [])
	if lg.size() == 2:
		nodes["shop-ledger"] = _paper(b, "shop-ledger",
			Vector3(float(lg[0]), 1.055, float(lg[1])), 0.28, 0.36)
	var ph: Array = d.get("phone", [])
	if ph.size() == 3:
		nodes["shop-phone"] = _wall_phone(b,
			Vector3(float(ph[0]), float(ph[1]), float(ph[2])))
	# Бегунок трамблёра лежит в ящике с запчастями и виден, только когда игрок
	# сам туда полез: узел стоит на месте с загрузки и невидим до своего шага.
	nodes["shop-rotor"] = _rotor(b, Vector3(float(cx2[0]) + 0.55 if cx2.size() == 5 else 26.0,
		fl + float(cx2[4]) + 0.02 if cx2.size() == 5 else 0.7,
		(float(cx2[2]) + float(cx2[3])) / 2.0 if cx2.size() == 5 else -11.7))


# --------------------------------------------------------- заколоченный дом --

# Второй интерьер. Доски на двери отодраны ИЗНУТРИ — свежие сколы, и это первое,
# что игрок здесь видит. Внутри печка-буржуйка, чужая лежанка, консервные банки
# и штатив у щели в южной стене, направленный точно на участок Вити.
static func _boarded(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var t := float(d.get("wall", 0.18))
	var fl := float(d.get("floor", 0.12))
	var eave := float(d.get("eave", 3.00))
	var dr: Array = d["door"]
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	var dtop := float(d.get("doorTop", 2.05))
	var cr: Array = d.get("ceil", [2.40, 2.52])
	var c0 := float(cr[0])
	var c1 := float(cr[1])

	# --- твёрдое: коробка с проёмом в южной стене ---
	_solid(b, out, x0, x1, 0.0, fl, z0, z1)
	_solid(b, out, x0, x1, fl, eave, z0, z0 + t)
	_solid(b, out, x0, x0 + t, fl, eave, z0 + t, z1 - t)
	_solid(b, out, x1 - t, x1, fl, eave, z0 + t, z1 - t)
	_solid(b, out, x0 + t, d0, fl, eave, z1 - t, z1)
	_solid(b, out, d1, x1 - t, fl, eave, z1 - t, z1)
	_solid(b, out, d0, d1, dtop, eave, z1 - t, z1)
	_solid(b, out, x0 + t, x1 - t, c0, c1, z0 + t, z1 - t)

	# --- видимое: снаружи фасад уже нарисован street_world.gd, здесь только
	# внутренние плоскости и то, что видно в проём ---
	_shell(b, x0 + t, x1 - t, fl - 0.02, fl + 0.006, z0 + t, z1 - t, "boards", 1.3)
	_shell(b, x0 + t, x1 - t, c0, c1, z0 + t, z1 - t, "boards", 1.5)
	_shell(b, x0 + t - 0.02, x1 - t + 0.02, fl, c0, z0 + t, z0 + t + 0.02, "plank", 0.0)
	_shell(b, x0 + t, x0 + t + 0.02, fl, c0, z0 + t, z1 - t, "plank", 0.0)
	_shell(b, x1 - t - 0.02, x1 - t, fl, c0, z0 + t, z1 - t, "plank", 0.0)
	_shell(b, x0 + t, d0, fl, c0, z1 - t - 0.02, z1 - t, "plank", 0.0)
	_shell(b, d1, x1 - t, fl, c0, z1 - t - 0.02, z1 - t, "plank", 0.0)
	# Обналичка проёма и отодранные доски рядом с ним. Сколы свежие — их
	# читает точка осмотра, а видно их и так: доски сложены изнутри, а не снаружи.
	_case(b, d0, d1, fl, dtop, z1)
	for i in 3:
		_shell(b, d0 + 0.10 + float(i) * 0.05, d0 + 0.24 + float(i) * 0.05,
			fl + 0.02 + float(i) * 0.06, fl + 0.08 + float(i) * 0.06,
			z1 - t - 0.95 + float(i) * 0.07, z1 - t - 0.10 + float(i) * 0.07,
			"boards", 0.0)

	# ЗАКОЛОЧЕННАЯ СТВОРКА. До главы ДЕРЕВНЯ дом обязан оставаться закрытым:
	# в УЛИЦЕ игрок проходит мимо него дважды, и если тогда в него уже можно
	# войти, вся сцена с отодранными изнутри досками пропадает вместе с домом.
	# Полотно — своей нодой (её гасят), коробка — своим именем в четвёртом
	# наборе (её гасят там же). Обе снимаются разом в village_quest.enter().
	var leaf := Node3D.new()
	leaf.name = "door-boarded"
	var lm := MeshInstance3D.new()
	var lb := BoxMesh.new()
	lb.size = Vector3(d1 - d0 - 0.04, dtop - fl - 0.04, 0.05)
	lb.material = b.mats.get_mat("dark")
	lm.mesh = lb
	lm.position = Vector3(0, (dtop - fl) / 2.0, 0)
	lm.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	leaf.add_child(lm)
	# Крест-накрест, как на окнах этого дома.
	for s: float in [-1.0, 1.0]:
		var brd := MeshInstance3D.new()
		var bmm := BoxMesh.new()
		var dw := d1 - d0
		var dh := dtop - fl
		bmm.size = Vector3(sqrt(dw * dw + dh * dh) + 0.18, 0.12, 0.04)
		bmm.material = b.mats.get_mat("boards")
		brd.mesh = bmm
		brd.position = Vector3(0, (dtop - fl) / 2.0, 0.05)
		brd.rotation = Vector3(0.0, 0.0, s * atan2(dh, dw))
		brd.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		leaf.add_child(brd)
	leaf.position = Vector3((d0 + d1) / 2.0, fl, z1 + 0.03)
	b.decor["village-door-boarded"] = leaf
	(out["nodes"] as Dictionary)["door-boarded"] = leaf
	_solid(b, out, d0, d1, fl, dtop, z1 - 0.02, z1 + 0.08, "door-boarded")

	# Щель между досками южной стены. Твёрдого в ней нет: она и так внутри
	# простенка, а вырезать её в коллизии значило бы сделать в доме дыру
	# шириной с ладонь, в которую упирался бы игрок.
	#
	# И она СВЕТИТСЯ, а не темнеет. Первый заход рисовал её тёмной доской
	# на тёмной стене — на снимке 53 щели не было вовсе, а вся сцена с
	# Ковригиным держится на том, что в неё видно улицу. Теперь сквозь неё
	# идёт уличный свет: узкая светлая полоса на стене, видная только изнутри.
	var sl: Array = d.get("slit", [])
	if sl.size() == 4:
		var slit := _holder(b, "boarded-slit",
			Vector3((float(sl[0]) + float(sl[1])) / 2.0,
				(float(sl[2]) + float(sl[3])) / 2.0, z1 - t - 0.012))
		var sm := BoxMesh.new()
		sm.size = Vector3(float(sl[1]) - float(sl[0]), float(sl[3]) - float(sl[2]), 0.02)
		sm.material = b.mats.glow(0x8fa2b6, 0.62)
		_piece(slit, sm, Vector3.ZERO)
		# Косяк вокруг: доска сверху и снизу, чтобы полоса читалась щелью
		# между досками, а не окном.
		for s: float in [-1.0, 1.0]:
			_piece(slit, _box_mesh(b, Vector3(float(sl[1]) - float(sl[0]) + 0.22,
				0.09, 0.05), "", 0x2a2419),
				Vector3(0.0, s * ((float(sl[3]) - float(sl[2])) / 2.0 + 0.045), 0.01))
		(out["nodes"] as Dictionary)["boarded-slit"] = slit

	# --- начинка ---
	var nodes: Dictionary = out["nodes"]
	var st: Array = d.get("stove", [])
	if st.size() == 5:
		_stove(b, out, st, fl, c1)
	var bn: Array = d.get("bunk", [])
	if bn.size() == 5:
		var by := fl + float(bn[4])
		_shell(b, float(bn[0]), float(bn[1]), fl + 0.12, by, float(bn[2]), float(bn[3]),
			"boards", 1.0)
		_solid(b, out, float(bn[0]), float(bn[1]), fl, by, float(bn[2]), float(bn[3]))
		nodes["boarded-bunk"] = _bedroll(b,
			Vector3((float(bn[0]) + float(bn[1])) / 2.0, by,
				(float(bn[2]) + float(bn[3])) / 2.0),
			float(bn[1]) - float(bn[0]) - 0.30, float(bn[3]) - float(bn[2]) - 0.30)
	var tp: Array = d.get("tripod", [])
	if tp.size() == 2:
		nodes["boarded-tripod"] = _tripod(b, Vector3(float(tp[0]), fl, float(tp[1])),
			float(sl[2]) if sl.size() == 4 else 1.30)
	var cn: Array = d.get("cans", [])
	if cn.size() == 2:
		nodes["boarded-cans"] = _cans(b, Vector3(float(cn[0]), fl, float(cn[1])))
	var tps: Array = d.get("tapes", [])
	if tps.size() == 2:
		nodes["boarded-tapes"] = _tape_stack(b, Vector3(float(tps[0]), fl, float(tps[1])))


# ----------------------------------------------------------------- погост ----

static func _graveyard(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var fh := float(d.get("fenceH", 0.95))
	var gt: Array = d.get("gate", [(x0 + x1) / 2.0 - 0.55, (x0 + x1) / 2.0 + 0.55])
	var g0 := float(gt[0])
	var g1 := float(gt[1])

	# Ограда: тонкая, но твёрдая — иначе на погост входят сквозь неё, и калитка
	# перестаёт быть калиткой.
	_fence_run(b, out, x0, x1, z0, z0 + 0.08, fh, true)
	_fence_run(b, out, x0, g0, z1 - 0.08, z1, fh, true)
	_fence_run(b, out, g1, x1, z1 - 0.08, z1, fh, true)
	_fence_run(b, out, x0, x0 + 0.08, z0 + 0.08, z1 - 0.08, fh, false)
	_fence_run(b, out, x1 - 0.08, x1, z0 + 0.08, z1 - 0.08, fh, false)
	# Столбы калитки повыше остальной ограды: издали видно, куда идти.
	for s: float in [g0, g1]:
		_shell(b, s - 0.09, s + 0.09, 0.0, fh + 0.42, z1 - 0.10, z1 + 0.08, "metal", 1.0)
		_solid(b, out, s - 0.09, s + 0.09, 0.0, fh + 0.42, z1 - 0.10, z1 + 0.08)

	# Кресты. Девять — по числу могил в data/village.json.
	var wife: Array = d.get("wife", [])
	var nodes: Dictionary = out["nodes"]
	for g: Array in d.get("graves", []):
		if g.size() != 2:
			continue
		var gx := float(g[0])
		var gz := float(g[1])
		var is_wife := wife.size() == 2 and absf(gx - float(wife[0])) < 0.01 \
			and absf(gz - float(wife[1])) < 0.01
		_cross(b, gx, gz, is_wife)
		# Холмик.
		_shell(b, gx - 0.42, gx + 0.42, 0.0, 0.16, gz + 0.10, gz + 1.65, "dirt", 1.2)
	if wife.size() == 2:
		nodes["grave-wife"] = _flowers(b, Vector3(float(wife[0]), 0.16, float(wife[1]) + 0.42))

	# Вырытая яма с готовой табличкой. Яму в грунте не вырезать — он лежит
	# в паритетной статике, — поэтому она сделана бермой по кругу и тёмным
	# дном на полметра ниже. С двух метров читается ровно как яма, а больше
	# к ней никто и не подходит.
	var pt: Array = d.get("pit", [])
	if pt.size() == 4:
		var p0 := float(pt[0])
		var p1 := float(pt[1])
		var q0 := float(pt[2])
		var q1 := float(pt[3])
		# Дно ямы лежит на -0.62, но газон погоста — сплошная плоскость улицы,
		# и дырки в ней нет: со стороны яма читалась только земляным бортиком.
		# Поэтому сверху ещё и чёрное пятно вровень с травой — ночью оно и есть
		# «вырыто», а дно остаётся на месте для тех, кто подойдёт вплотную.
		_shell(b, p0, p1, -0.62, -0.60, q0, q1, "dark", 0.0)
		_shell(b, p0, p1, 0.004, 0.014, q0, q1, "dark", 0.0)
		# ФАЗА 16. Берма была 0.26 — на сантиметр выше порога шага игрока
		# (player.gd STEP_UP 0.25). Нога не заносится, а глазом это ровно
		# земляной валик, через который переступают. Хуже того, западный край
		# бермы заходил в створ калитки погоста (GRAVEYARD.gate x [39.5, 40.6])
		# и сужал его до 0.81 м: игрок упирался в невидимое на самом входе.
		# 0.20 — валик остаётся валиком и переступается, створ снова целый.
		#
		# ФАЗА 17, ПРЕДУПРЕЖДЕНИЕ СЛЕДУЮЩЕМУ. Берму НЕ ТРОГАТЬ. Западный край
		# и сейчас оставляет в створе калитки погоста ровно 0.81 м, и проход
		# держится только на том, что 0.20 < Player.STEP_UP (0.25): нога
		# заносится, и игрок идёт ПОВЕРХ валика, а не мимо него. Подними её
		# обратно хоть на пять сантиметров — и вход в погост закроется
		# невидимой стеной, а test_reachable покажет это как тесное место,
		# то есть как чужой дефект.

		for r: Array in [[p0 - 0.34, p0, q0 - 0.34, q1 + 0.34],
				[p1, p1 + 0.34, q0 - 0.34, q1 + 0.34],
				[p0, p1, q0 - 0.34, q0], [p0, p1, q1, q1 + 0.34]]:
			_shell(b, float(r[0]), float(r[1]), 0.0, 0.20, float(r[2]), float(r[3]),
				"dirt", 1.0)
			_solid(b, out, float(r[0]), float(r[1]), 0.0, 0.20, float(r[2]), float(r[3]))
		# Отвал земли сбоку и лопата, воткнутая в него.
		_shell(b, p1 + 0.40, p1 + 1.30, 0.0, 0.52, q0, q1, "dirt", 1.1)
		_shell(b, p1 + 0.80, p1 + 0.86, 0.45, 1.42, (q0 + q1) / 2.0 - 0.03,
			(q0 + q1) / 2.0 + 0.03, "boards", 0.0)
		_shell(b, p1 + 0.72, p1 + 0.94, 0.30, 0.52, (q0 + q1) / 2.0 - 0.02,
			(q0 + q1) / 2.0 + 0.02, "metal", 0.0)
		nodes["grave-pit"] = _plate(b, Vector3((p0 + p1) / 2.0, 0.0, q1 + 0.52))


# --------------------------------------------------------------- Аркадий ----

# Свет горит, дверь приоткрыта, телевизор работает, никого. Внутрь не войти:
# дом остаётся сплошным объёмом street_world.gd, и всё, что нужно игроку,
# лежит в сенях — в полутора шагах от порога, за приоткрытой створкой.
static func _arkady(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var lf: Array = d.get("leaf", [])
	if lf.size() != 2:
		return
	var l0 := float(lf[0])
	var l1 := float(lf[1])
	var zs := -7.0                       # южный фасад дома Аркадия (street.json)
	var nodes: Dictionary = out["nodes"]

	# Створка на петле у западной кромки проёма. Приоткрыта с самого начала
	# главы — её угол ставит village_quest.gd.
	var leaf := Node3D.new()
	leaf.name = "arkady-door"
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(l1 - l0 - 0.04, 2.00, 0.05)
	bm.material = b.mats.get_mat("shedwood")
	mi.mesh = mi.mesh
	mi.mesh = bm
	mi.position = Vector3((l1 - l0) / 2.0 - 0.02, 1.02, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	leaf.add_child(mi)
	leaf.position = Vector3(l0, 0.02, zs - 0.10)
	b.decor["village-arkady-door"] = leaf
	nodes["arkady-door"] = leaf

	# Сени: стол с письмом, ключ на гвозде, телевизор и его отсвет на стене.
	var tb: Array = d.get("table", [])
	if tb.size() == 2:
		var tx := float(tb[0])
		var tz := float(tb[1])
		_shell(b, tx - 0.44, tx + 0.44, 0.72, 0.78, tz - 0.34, tz + 0.34, "boards", 1.0)
		for sx: float in [tx - 0.38, tx + 0.38]:
			for sz: float in [tz - 0.28, tz + 0.28]:
				_shell(b, sx - 0.03, sx + 0.03, 0.0, 0.72, sz - 0.03, sz + 0.03,
					"boards", 0.0)
	var lt: Array = d.get("letter", [])
	if lt.size() == 3:
		nodes["kovrigin-letter"] = _paper(b, "kovrigin-letter",
			Vector3(float(lt[0]), float(lt[1]), float(lt[2])), 0.21, 0.29)
	var kk: Array = d.get("key", [])
	if kk.size() == 3:
		nodes["shop-key"] = _nail_key(b, Vector3(float(kk[0]), float(kk[1]), float(kk[2])))
	var tv: Array = d.get("tv", [])
	if tv.size() == 3:
		nodes["arkady-tv"] = _tv(b, Vector3(float(tv[0]), float(tv[1]), float(tv[2])))
	var gl: Array = d.get("glow", [])
	if gl.size() == 3:
		var q := QuadMesh.new()
		q.size = Vector2(1.9, 1.4)
		var glow := MeshInstance3D.new()
		glow.name = "village-arkady-tv-glow"
		glow.mesh = q
		glow.material_override = b.mats.glow(0x9fc4e8, 0.42)
		glow.position = Vector3(float(gl[0]), float(gl[1]), float(gl[2]))
		glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		b.decor["village-arkady-tv-glow"] = glow
		nodes["arkady-tv-glow"] = glow


# ------------------------------------------------------- стены с проёмами ----

## Южная стена сельпо: дверь и витрина вырезаны И В КОЛЛИЗИИ ТОЖЕ. Сплошная
## стена с нарисованной дверью читается как обман ровно в тот момент, когда
## игрок подходит вплотную, — а это и есть момент, ради которого сельпо стоит.
static func _south_solid(b: WorldBuilder, out: Dictionary, x0: float, x1: float,
		y0: float, y1: float, za: float, zb: float,
		d0: float, d1: float, dtop: float,
		w0: float, w1: float, wy0: float, wy1: float) -> void:
	var cut: Array = _spans(x0, x1, d0, d1, w0, w1)
	for r: Array in cut:
		_solid(b, out, float(r[0]), float(r[1]), y0, y1, za, zb)
	_solid(b, out, d0, d1, dtop, y1, za, zb)
	_solid(b, out, w0, w1, y0, wy0, za, zb)
	_solid(b, out, w0, w1, wy1, y1, za, zb)


static func _south_skin(b: WorldBuilder, x0: float, x1: float, y0: float, y1: float,
		za: float, zb: float, d0: float, d1: float, dtop: float,
		w0: float, w1: float, wy0: float, wy1: float, key: String) -> void:
	for r: Array in _spans(x0, x1, d0, d1, w0, w1):
		_shell(b, float(r[0]), float(r[1]), y0, y1, za, zb, key, 0.0)
	_shell(b, d0, d1, dtop, y1, za, zb, key, 0.0)
	_shell(b, w0, w1, y0, wy0, za, zb, key, 0.0)
	_shell(b, w0, w1, wy1, y1, za, zb, key, 0.0)


## Простенки между двумя проёмами: [x0..d0], [d1..w0], [w1..x1]. Проёмы обязаны
## идти по возрастанию x — так они и лежат в data/village.json.
static func _spans(x0: float, x1: float, d0: float, d1: float,
		w0: float, w1: float) -> Array:
	var a := minf(d0, w0)
	var a1 := d1 if d0 < w0 else w1
	var c := maxf(d0, w0)
	var c1 := w1 if d0 < w0 else d1
	return [[x0, a], [a1, c], [c1, x1]]


## Белая обналичка проёма — та же, что на окнах дома (yard_world._casing).
static func _case(b: WorldBuilder, a: float, c: float, y0: float, y1: float,
		zs: float) -> void:
	var w := 0.09
	_shell(b, a - w, a + 0.01, y0, y1 + w, zs - 0.03, zs + 0.06, "trim", 0.0)
	_shell(b, c - 0.01, c + w, y0, y1 + w, zs - 0.03, zs + 0.06, "trim", 0.0)
	_shell(b, a - w, c + w, y1, y1 + w, zs - 0.03, zs + 0.06, "trim", 0.0)


## Прогон ограды: цоколь, две горизонтали и прутья. horiz = вдоль x.
static func _fence_run(b: WorldBuilder, out: Dictionary, x0: float, x1: float,
		z0: float, z1: float, h: float, horiz: bool) -> void:
	if x1 - x0 < 0.05 or z1 - z0 < 0.01:
		return
	_solid(b, out, x0, x1, 0.0, h, z0, z1)
	_shell(b, x0, x1, 0.0, 0.16, z0 - 0.03, z1 + 0.03, "concrete", 1.2)
	for y: float in [h - 0.06, h * 0.52]:
		_shell(b, x0, x1, y, y + 0.05, z0, z1, "metal", 2.4)
	var span := (x1 - x0) if horiz else (z1 - z0)
	var n := maxi(2, int(span / 0.28))
	for i in n + 1:
		var q := float(i) / float(n)
		if horiz:
			var px := x0 + (x1 - x0) * q
			_shell(b, px - 0.016, px + 0.016, 0.14, h, z0, z1, "metal", 0.0)
		else:
			var pz := z0 + (z1 - z0) * q
			_shell(b, x0, x1, 0.14, h, pz - 0.016, pz + 0.016, "metal", 0.0)


# --------------------------------------------------------------- предметы ----

static func _holder(b: WorldBuilder, id: String, pos: Vector3, shown := true) -> Node3D:
	var n := Node3D.new()
	n.name = "village-" + id
	n.position = pos
	n.visible = shown
	b.decor["village-" + id] = n
	return n


static func _piece(parent: Node3D, mesh: Mesh, at: Vector3, rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.rotation = rot
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _box_mesh(b: WorldBuilder, size: Vector3, key: String, exact_hex := -1) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	m.material = b.mats.flat(exact_hex, true) if exact_hex >= 0 else b.mats.get_mat(key)
	return m


static func _paper(b: WorldBuilder, id: String, pos: Vector3, w: float, l: float) -> Node3D:
	var n := _holder(b, id, pos)
	# Письмо на трёх листах — три листа и есть, слегка вразнобой.
	for i in 3:
		_piece(n, _box_mesh(b, Vector3(w, 0.004, l), "", 0xc9c3ac),
			Vector3(0.012 * float(i), 0.004 * float(i), 0.014 * float(i)),
			Vector3(0.0, 0.09 * float(i - 1), 0.0))
	return n


static func _bucket(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "well-bucket", pos)
	var body := CylinderMesh.new()
	body.top_radius = 0.16
	body.bottom_radius = 0.13
	body.height = 0.28
	body.radial_segments = 9
	body.rings = 1
	body.material = b.mats.flat(0x6f767c, true)
	_piece(n, body, Vector3(0, 0.14, 0))
	_piece(n, _box_mesh(b, Vector3(0.32, 0.02, 0.02), "", 0x3a3f43), Vector3(0, 0.30, 0))
	return n


static func _crate(b: WorldBuilder, id: String, pos: Vector3, w: float, h: float,
		l: float) -> Node3D:
	var n := _holder(b, id, pos)
	_piece(n, _box_mesh(b, Vector3(w, h, l), "shedwood"), Vector3(w / 2.0, h / 2.0, l / 2.0))
	for y: float in [h * 0.22, h * 0.78]:
		_piece(n, _box_mesh(b, Vector3(w + 0.02, 0.045, l + 0.02), "", 0x4e5459),
			Vector3(w / 2.0, y, l / 2.0))
	return n


static func _scales(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "shop-scales", pos)
	_piece(n, _box_mesh(b, Vector3(0.34, 0.09, 0.26), "", 0x8b9095), Vector3(0, 0.045, 0))
	_piece(n, _box_mesh(b, Vector3(0.30, 0.012, 0.22), "", 0xa8aeb3), Vector3(0, 0.096, 0))
	_piece(n, _box_mesh(b, Vector3(0.22, 0.20, 0.05), "", 0xc9c3ac), Vector3(0, 0.19, -0.09))
	return n


static func _wall_phone(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "shop-phone", pos)
	_piece(n, _box_mesh(b, Vector3(0.07, 0.34, 0.22), "", 0x1c1e21), Vector3(0.035, 0, 0))
	_piece(n, _box_mesh(b, Vector3(0.06, 0.05, 0.19), "", 0x1c1e21), Vector3(0.10, 0.11, 0))
	_piece(n, _box_mesh(b, Vector3(0.05, 0.055, 0.05), "", 0x6f767c), Vector3(0.09, -0.06, 0))
	_piece(n, _box_mesh(b, Vector3(0.012, 0.26, 0.012), "", 0x3a3f43), Vector3(0.08, -0.24, 0))
	return n


# Бегунок трамблёра. Тот, которого нет под капотом.
static func _rotor(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "shop-rotor", pos, false)
	var body := CylinderMesh.new()
	body.top_radius = 0.045
	body.bottom_radius = 0.05
	body.height = 0.055
	body.radial_segments = 8
	body.rings = 1
	body.material = b.mats.flat(0x1c1e21, true)
	_piece(n, body, Vector3(0, 0.028, 0))
	_piece(n, _box_mesh(b, Vector3(0.10, 0.014, 0.026), "", 0x8b9095), Vector3(0.03, 0.062, 0))
	return n


static func _nail_key(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "shop-key", pos)
	# Наружная правая стойка смотрит на подход с улицы, а не ребром в проём.
	n.rotation.y = PI / 2.0
	_piece(n, _box_mesh(b, Vector3(0.014, 0.10, 0.014), "", 0x7d8288), Vector3(0, -0.055, 0))
	_piece(n, _box_mesh(b, Vector3(0.014, 0.05, 0.05), "", 0x7d8288), Vector3(0, 0.005, 0))
	_piece(n, _box_mesh(b, Vector3(0.014, 0.024, 0.03), "", 0x7d8288), Vector3(0, -0.095, 0.022))
	_piece(n, _box_mesh(b, Vector3(0.05, 0.012, 0.012), "", 0x3a3f43), Vector3(-0.02, 0.035, 0))
	# Бирка: «сельпо», и почерк тот же, что в журнале прихода.
	_piece(n, _box_mesh(b, Vector3(0.012, 0.10, 0.075), "", 0x8a6a45),
		Vector3(0.018, -0.04, 0.045))
	return n


static func _tv(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "arkady-tv", pos)
	_piece(n, _box_mesh(b, Vector3(0.62, 0.52, 0.50), "", 0x5d4530), Vector3(0, 0, 0))
	_piece(n, _box_mesh(b, Vector3(0.46, 0.36, 0.03), "", 0x93a9b4), Vector3(0, 0.02, 0.26))
	for s: float in [-0.22, 0.22]:
		_piece(n, _box_mesh(b, Vector3(0.05, 0.30, 0.05), "", 0x3a3f43), Vector3(s, -0.41, 0))
	return n


# Печка-буржуйка с трубой в потолок. Тёплая — её тепло и есть доказательство,
# что здесь живут.
static func _stove(b: WorldBuilder, out: Dictionary, st: Array, fl: float,
		ceil_y: float) -> void:
	var x0 := float(st[0])
	var x1 := float(st[1])
	var z0 := float(st[2])
	var z1 := float(st[3])
	var h := float(st[4])
	_solid(b, out, x0, x1, fl, fl + h, z0, z1)
	_shell(b, x0, x1, fl + 0.14, fl + h, z0, z1, "metal", 1.0)
	for sx: float in [x0 + 0.08, x1 - 0.08]:
		for sz: float in [z0 + 0.08, z1 - 0.08]:
			_shell(b, sx - 0.03, sx + 0.03, fl, fl + 0.14, sz - 0.03, sz + 0.03, "metal", 0.0)
	# Дверца топки и труба.
	_shell(b, x0 + 0.10, x1 - 0.10, fl + 0.26, fl + 0.52, z1 - 0.02, z1 + 0.03, "dark", 0.0)
	var cx := (x0 + x1) / 2.0
	_shell(b, cx - 0.07, cx + 0.07, fl + h, ceil_y, (z0 + z1) / 2.0 - 0.07,
		(z0 + z1) / 2.0 + 0.07, "metal", 1.4)


static func _bedroll(b: WorldBuilder, pos: Vector3, w: float, l: float) -> Node3D:
	var n := _holder(b, "boarded-bunk", pos)
	_piece(n, _box_mesh(b, Vector3(w, 0.16, l), "", 0x3d4b52), Vector3(0, 0.08, 0))
	_piece(n, _box_mesh(b, Vector3(w * 0.7, 0.13, l * 0.28), "", 0xc9c3ac),
		Vector3(0, 0.14, -l * 0.32), Vector3(0.0, 0.14, 0.0))
	# Скомканное одеяло: спали здесь, и не одну ночь.
	_piece(n, _box_mesh(b, Vector3(w * 0.82, 0.11, l * 0.42), "", 0x4a5f52),
		Vector3(0.02, 0.20, l * 0.16), Vector3(0.0, -0.09, 0.0))
	return n


# Штатив у щели. Головка направлена ТОЧНО в щель: то, что видно с той стороны,
# и есть весь смысл этого дома.
static func _tripod(b: WorldBuilder, pos: Vector3, aim_y: float) -> Node3D:
	var n := _holder(b, "boarded-tripod", pos)
	var head := aim_y - pos.y
	for i in 3:
		var a := float(i) * TAU / 3.0 + 0.4
		_piece(n, _box_mesh(b, Vector3(0.028, head, 0.028), "", 0x3a3f43),
			Vector3(cos(a) * 0.16, head / 2.0, sin(a) * 0.16),
			Vector3(sin(a) * 0.20, 0.0, -cos(a) * 0.20))
	_piece(n, _box_mesh(b, Vector3(0.11, 0.06, 0.11), "", 0x1c1e21), Vector3(0, head + 0.03, 0))
	# Камеры на штативе нет: её вернули. Осталась площадка и барашек.
	_piece(n, _box_mesh(b, Vector3(0.07, 0.03, 0.07), "", 0x6f767c), Vector3(0, head + 0.075, 0))
	_piece(n, _box_mesh(b, Vector3(0.02, 0.02, 0.09), "", 0x6f767c), Vector3(0.05, head + 0.03, 0))
	return n


static func _cans(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "boarded-cans", pos)
	for row in 4:
		var per := 4 - row
		for i in per:
			var can := CylinderMesh.new()
			can.top_radius = 0.052
			can.bottom_radius = 0.052
			can.height = 0.105
			can.radial_segments = 8
			can.rings = 1
			can.material = b.mats.flat(0x8b9095 if (row + i) % 2 == 0 else 0x9c6a3a, true)
			_piece(n, can, Vector3((float(i) - float(per - 1) / 2.0) * 0.115,
				0.052 + float(row) * 0.107, 0.0))
	return n


# Стопка кассет с этикетками чужим почерком. Ни одна из них не та, что игрок
# смотрел на мансарде: у тех этикетки печатные.
static func _tape_stack(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "boarded-tapes", pos)
	_piece(n, _box_mesh(b, Vector3(0.44, 0.36, 0.40), "shedwood"), Vector3(0, 0.18, 0))
	for i in 6:
		_piece(n, _box_mesh(b, Vector3(0.19, 0.028, 0.11), "", 0x1c1e21),
			Vector3(0.012 * float(i % 3), 0.375 + float(i) * 0.030, 0.01 * float(i % 2)),
			Vector3(0.0, 0.05 * float(i % 3 - 1), 0.0))
		_piece(n, _box_mesh(b, Vector3(0.14, 0.004, 0.055), "", 0xc9c3ac),
			Vector3(0.012 * float(i % 3), 0.390 + float(i) * 0.030, 0.01 * float(i % 2)),
			Vector3(0.0, 0.05 * float(i % 3 - 1), 0.0))
	return n


static func _cross(b: WorldBuilder, x: float, z: float, wife: bool) -> void:
	var h := 1.32 if not wife else 1.46
	var key := "boards" if not wife else "metal"
	_shell(b, x - 0.055, x + 0.055, 0.0, h, z - 0.055, z + 0.055, key, 1.0)
	_shell(b, x - 0.30, x + 0.30, h * 0.68, h * 0.68 + 0.10, z - 0.045, z + 0.045, key, 0.0)


static func _flowers(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "grave-wife", pos)
	var jar := CylinderMesh.new()
	jar.top_radius = 0.06
	jar.bottom_radius = 0.055
	jar.height = 0.18
	jar.radial_segments = 8
	jar.rings = 1
	jar.material = b.mats.flat(0x93a9b4, true)
	_piece(n, jar, Vector3(0, 0.09, 0))
	for i in 5:
		var a := float(i) * TAU / 5.0
		_piece(n, _box_mesh(b, Vector3(0.02, 0.24, 0.02), "", 0x4a5f52),
			Vector3(cos(a) * 0.03, 0.28, sin(a) * 0.03),
			Vector3(sin(a) * 0.22, 0.0, -cos(a) * 0.22))
		_piece(n, _box_mesh(b, Vector3(0.06, 0.05, 0.06), "", 0x8a5540),
			Vector3(cos(a) * 0.08, 0.40, sin(a) * 0.08))
	return n


# Табличка, приготовленная заранее. Что на ней написано, читает точка осмотра.
static func _plate(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "grave-pit", pos)
	_piece(n, _box_mesh(b, Vector3(0.05, 0.92, 0.05), "", 0x6f767c), Vector3(0, 0.46, 0))
	_piece(n, _box_mesh(b, Vector3(0.52, 0.30, 0.03), "", 0xa8aeb3), Vector3(0, 0.86, 0.02))
	return n


# ----------------------------------------------------------------- зоны ----

# Акустические зоны сельпо, заколоченного дома и погоста. Гард обязателен:
# GameData кэширует site.json по ссылке, а мир собирают три теста подряд —
# без гарда зон стало бы девять, и zone_at() возвращал бы вторую копию.
static func _zones(list: Array) -> void:
	if list.is_empty():
		return
	var zones: Array = GameData.site()["ZONES"]
	for zn: Variant in list:
		if not (zn is Dictionary):
			continue
		var id := String((zn as Dictionary).get("id", ""))
		var found := false
		for existing: Dictionary in zones:
			if String(existing.get("id", "")) == id:
				found = true
				break
		if not found:
			zones.append((zn as Dictionary).duplicate(true))

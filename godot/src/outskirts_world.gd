# Околица — фаза 14. Сеть переулков и семь участков за деревней, поверх
# принятого мира тем же правилом, что улица/участок/деревня:
#
#   видимое   -> b.box(..., collide = false) / b.plane(...)
#   твёрдое   -> col.add_box_d(SET_OVERLAY)
#
# Ни одна коробка отсюда не попадает в 311/4/83 — как и всё, что построено
# street_world.gd/yard_world.gd/village_world.gd. Постройки Quaternius
# (амбар, силос, курятник, ветряк, навес клуба) — не геометрия этого файла:
# их модели стоят в data/props.json с "col": false, а здесь только
# коробка-заместитель под ними в SET_OVERLAY, которая и держит твёрдость.
#
# ГРАНИЦЫ. Вся новая карта лежит севернее z = -14, то есть не касается ни
# полосы деда (z [-5.5,-0.9]), ни кольца Аркадия (z [-6.2,-0.3]) — этого
# не нужно проверять по месту, достаточно того, что z1 каждой зоны ≤ -14.
#
# Прогон-приёмка: tests/test_outskirts_room.gd — написан ДО этой сборки.

class_name OutskirtsWorld
extends RefCounted

const DATA := "res://data/outskirts.json"

static var _cache: Variant = null


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


static func build(b: WorldBuilder) -> Dictionary:
	var d := data()
	if d.is_empty():
		return {}

	var out: Dictionary = {
		"enabled": true,
		"boxes": [],        # AABB твёрдой геометрии — тем же контрактом, что village.boxes
		"nodes": {},         # id -> Node3D
		"lanes": d.get("LANES", {}),
		"second_line": d.get("SECOND_LINE", {}),
		"plots": d.get("PLOTS", {}),
		"farm": d.get("FARM", {}),
		"pond": d.get("POND", {}),
		"pump": d.get("PUMP", {}),
		"hens": d.get("HENS", {}),
		"club": d.get("CLUB", {}),
	}

	_ground(b, d, out)
	_second_line(b, d, out)
	_borders(b, d, out)
	_farm(b, d, out)
	_pond(b, d, out)
	var skin_pump := b.skin_begin("buildings", "outskirts", String((d.get("PUMP", {}) as Dictionary).get("id", "")), "PUMP")
	_pump(b, d, out)
	b.skin_end(skin_pump)
	_hens(b, d, out)
	var skin_club := b.skin_begin("buildings", "outskirts", String((d.get("CLUB", {}) as Dictionary).get("id", "")), "CLUB")
	_club(b, d, out)
	b.skin_end(skin_club)
	_dump(b, d, out)
	var skin_mill := b.skin_begin("buildings", "outskirts", String((d.get("MILL", {}) as Dictionary).get("id", "")), "MILL")
	_mill(b, d, out)
	b.skin_end(skin_mill)
	_field(b, d, out)
	_fences(b, d, out)
	_zones(d.get("ZONES", []))
	return out


# ---------------------------------------------------------------- земля ----

static func _ground(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var lanes: Dictionary = d.get("LANES", {})
	var w: Dictionary = lanes.get("west", {})
	var e: Dictionary = lanes.get("east", {})
	if w.size() > 0:
		var wx: Array = w["x"]
		var wz: Array = w["z"]
		_shell(b, float(wx[0]), float(wx[1]), -0.03, 0.0, float(wz[0]), float(wz[1]),
			String(w.get("mat", "gravel")), 1.4)
	if e.size() > 0:
		var ex: Array = e["x"]
		var ez: Array = e["z"]
		_shell(b, float(ex[0]), float(ex[1]), -0.03, 0.0, float(ez[0]), float(ez[1]),
			String(e.get("mat", "dirt")), 1.2)

	var sl: Dictionary = d.get("SECOND_LINE", {})
	if sl.size() > 0:
		var sx: Array = sl["x"]
		var sz: Array = sl["z"]
		_shell(b, float(sx[0]), float(sx[1]), -0.03, 0.0, float(sz[0]), float(sz[1]),
			String(sl.get("mat", "dirt")), 3.2)

	var outer: Dictionary = d.get("OUTER", {})
	if outer.size() > 0:
		var ox: Array = outer["x"]
		var oz: Array = outer["z"]
		_shell(b, float(ox[0]), float(ox[1]), -0.03, 0.0, float(oz[0]), float(oz[1]),
			"grass", 4.0)

	# Подложка грунта под всем новым куском, разом — без неё край карты снова
	# читался бы чёрным провалом, как до фазы 13.
	if outer.size() > 0:
		var ox2: Array = outer["x"]
		var oz2: Array = outer["z"]
		_shell(b, float(ox2[0]) - 8.0, float(ox2[1]) + 8.0, -0.5, -0.32,
			float(oz2[0]) - 8.0, float(oz2[1]), "dirt", 10.0)
	if sl.size() > 0:
		var sx2: Array = sl["x"]
		var sz2: Array = sl["z"]
		_shell(b, float(sx2[0]) - 6.0, float(sx2[1]) + 6.0, -0.5, -0.32,
			float(sz2[0]), float(sz2[1]) + 4.0, "dirt", 10.0)

	# Твёрдая плита под всей ходовой землёй сразу — одна коробка на весь кусок,
	# а не семь: игрок не должен проваливаться в стыке между участками.
	#
	#
	# ФАЗА 18. Плиту пробовали довести до бортов улицы (+-45.6) — ради двух
	# углов карты, x (39.4, 45.2) и (-45.2, -41.4) севернее z -13.8, где пола
	# нет вовсе. Откачено, и вот почему. Попасть туда нельзя: борта околицы
	# стоят на -41.4 и 39.4 и идут с z -34.4 до -14.0, а северный борт улицы
	# против этих углов остался глухим (data/street.json BORDERS._phase18_corners) —
	# и упирается в борта околицы встык, без щели. Пол южнее -14.6 на всей
	# ширине есть, это заново промерено сеткой (tests/test_street_floor.gd,
	# Z0 опущен до -14.6). А вот залитая плита сделала бы из обоих углов
	# по недостижимому карману в 65 и 102 м² — tests/test_reachable.gd ловит
	# их немедленно, и правильно ловит: пол, на который нельзя ступить,
	# это не починка дыры, а вторая дыра.
	_solid(b, out, -41.4, 39.4, -0.20, 0.0, -34.6, -13.8, "outskirts-floor")


# --------------------------------------------------------- вторая линия ----

# Пять домов второй линии получают тело и лицо (фаза 16).
#
# ЧТО БЫЛО. Собственных построек у второй линии не было НИ ОДНОЙ. То, что
# игрок принимал за дома, — пять «соседских домов прототипа» из
# site.json NEIGHBOURS, которые лежат в этой полосе с самого порта. У них
# тело рисуется box(..., collide = false), а твёрдые — только скаты крыш, и
# те над головой. Игрок проходил сквозь дом и выходил с другой стороны.
# Это не приём ради паритета, а наследство: collide=false ставился, когда дома
# были фоном ЗА КРАЕМ карты, а фаза 14 постелила вторую линию ровно поверх них.
#
# ЧЕГО ДЕЛАТЬ НЕЛЬЗЯ. Двигать дом. Тело у него collide=false и потому
# свободно, а вот ДЕСЯТЬ ЕГО СКАТОВ уходят в паритетные 311 через
# WorldBuilder._slope(), у которого collide по умолчанию true. Сдвинуть дом
# значит сдвинуть скат, то есть переписать parity/world_boxes.json — эталон,
# снятый с браузерного прототипа, перевыпустить который нечем.
#
# ЧТО ДЕЛАЕМ ВМЕСТО. Тело — можно. Южная стена уезжает вглубь на глубину
# крыльца, и свес кровли, который висел над стеной, становится НАВЕСОМ НАД
# КРЫЛЬЦОМ. Дом при этом стоит там же, скат не шевелится, а перед дверью
# появляется полтора метра, которых на второй линии не хватало всем.
#
# Координаты дома НЕ дублируются в data: читаются из site.json NEIGHBOURS тем
# же счётчиком idx, что в world_builder.neighbours(). В outskirts.json лежит
# только то, чего в site.json нет, — крыльцо, проёмы, линия забора.
static func _second_line(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var sl: Dictionary = d.get("SECOND_LINE", {})
	var conf: Dictionary = sl.get("houses", {})
	if conf.is_empty():
		return
	var idx := 0
	for n: Dictionary in GameData.site()["NEIGHBOURS"]:
		for hs: Array in n["houses"]:
			var key := str(idx)
			idx += 1
			if not conf.has(key):
				continue
			var skin_house := b.skin_begin("buildings", "outskirts", String((conf[key] as Dictionary).get("id", "")), "SECOND_LINE-" + key)
			_second_line_house(b, out, conf[key], float(hs[0]), float(hs[1]),
				float(hs[2]), float(hs[3]), float(hs[4]), key)
			b.skin_end(skin_house)


const SL_WALL := 0.22        # толщина стены
const SL_PLINTH := 0.32      # цоколь
const SL_DOOR_TOP := 2.05
const SL_WIN := [1.25, 2.00] # низ и верх окна
const SL_FENCE_H := 1.10
## Верх сквозного проезда (фаза 18). 2.45 — высота ворот сарая, не арки:
## подворотня должна читаться проёмом в доме, а не дырой во всю стену.
const SL_PASS_TOP := 2.45


static func _second_line_house(b: WorldBuilder, out: Dictionary, cfg: Dictionary,
		x: float, z: float, w: float, dep: float, h: float, key: String) -> void:
	var porch := float(cfg.get("porch", 1.2))
	var x0 := x - w / 2.0
	var x1 := x + w / 2.0
	var z0 := z - dep / 2.0
	var z1 := z + dep / 2.0 - porch      # южная стена ушла под свес
	# Два фасада дают различимый ритм линии, но не заводят по draw call на
	# каждый оттенок. Красная/обычная вагонка остаются на основной улице.
	var wall_mat := String(cfg.get("wallMaterial",
		RuralDressing.wall_material(RuralDressing.family(int(key)))))
	var trim_mat := String(cfg.get("trimMaterial", "trim"))

	# --- сквозной проезд под крышей (фаза 18) ---
	#
	# Жалоба Петра, пункт шестой: два дома второй линии закрывают амбар и
	# водокачку, коридоры между ними 1.5 и 1.2 м. Убрать дома нельзя — их скаты
	# паритетные (см. шапку выше), сдвинуть или понизить тоже нельзя, x/z/h идут
	# прямо в _slope(). Поэтому режется тело: две секции стены вместо одной,
	# между ними проём до SL_PASS_TOP, над ним стена продолжается.
	#
	# Створы взяты у того, что за домом: ворота амбара и дверь водокачки, буква
	# в букву из этого же файла. Проезд, который не совпадает со створом, дал бы
	# вид на глухую стену — то есть ничего не дал бы.
	var pr: Array = cfg.get("pass", [])
	var pg0 := clampf(float(pr[0]), x0, x1) if pr.size() == 2 else 0.0
	var pg1 := clampf(float(pr[1]), x0, x1) if pr.size() == 2 else 0.0
	var cut := pr.size() == 2 and pg1 - pg0 > 0.3

	# --- тело ---
	if cut:
		for sec: Array in [[x0, pg0], [pg1, x1]]:
			_second_line_shell(b, cfg, float(sec[0]), float(sec[1]), z0, z1, h, wall_mat)
			_shell(b, float(sec[0]) - 0.06, float(sec[1]) + 0.06, 0.0, SL_PLINTH,
				z0 - 0.06, z1 + 0.06, "plinth", 1.2)
			_solid(b, out, float(sec[0]), float(sec[1]), 0.0, h, z0, z1,
				"sl-house-%s-%d" % [key, int(float(sec[0]) * 10.0)])
		# Перемычка: стена над проездом. И её коробка — чтобы на неё нельзя
		# было забраться с крыльца соседней секции.
		_shell(b, pg0, pg1, SL_PASS_TOP, h, z0, z1, wall_mat, 3.0)
		_solid(b, out, pg0, pg1, SL_PASS_TOP, h, z0, z1, "sl-house-" + key + "-top")
		# Пол проезда: та же утоптанная земля, что на дорожке от калитки.
		# Без неё под домом остаётся трава, и проезд читается проломом.
		_shell(b, pg0, pg1, 0.001, 0.012, z0 - 0.3, z1 + 0.3, "dirt", 1.2)
		# Подворотня: массивные стойки/балка, створки, колея и адресная доска.
		# Это только оболочка — ширина и твёрдые секции проезда не меняются.
		for sx: float in [pg0, pg1]:
			_shell(b, sx - 0.10, sx + 0.10, 0.0, SL_PASS_TOP,
				z1 - 0.20, z1 + 0.20, "boards", 1.0)
			var inward := 1.0 if sx == pg0 else -1.0
			_shell(b, sx + inward * 0.02, sx + inward * 0.25, 0.12, 1.72,
				z1 + 0.08, z1 + 0.14, "shedwood", 1.2)
		_shell(b, pg0 - 0.12, pg1 + 0.12, SL_PASS_TOP - 0.15, SL_PASS_TOP + 0.08,
			z1 - 0.22, z1 + 0.22, "boards", 1.0)
		for tx: float in [pg0 + (pg1 - pg0) * 0.28, pg0 + (pg1 - pg0) * 0.72]:
			_shell(b, tx - 0.10, tx + 0.10, 0.012, 0.025,
				z0 - 1.0, z1 + 1.0, "dirt", 1.0)
		_shell(b, pg1 + 0.16, pg1 + 0.52, 1.56, 1.83,
			z1 + 0.12, z1 + 0.17, "tin", 0.0)
	else:
		_second_line_shell(b, cfg, x0, x1, z0, z1, h, wall_mat)
		_shell(b, x0 - 0.06, x1 + 0.06, 0.0, SL_PLINTH, z0 - 0.06, z1 + 0.06,
			"plinth", 1.2)
		_solid(b, out, x0, x1, 0.0, h, z0, z1, "sl-house-" + key)

	# --- фронтоны под скатом: он остался на месте, а тело уехало ---
	var rz0 := z - dep / 2.0 - 0.3
	var rz1 := z + dep / 2.0 + 0.3
	for sx: float in [x0, x1]:
		_gable_soft(b, sx, rz0, z, rz1, h, h + 1.3, wall_mat)

	# --- лицо: ниша двери, два окна с наличниками ---
	var dr: Array = cfg.get("door", [])
	if dr.size() == 2:
		var d0 := float(dr[0])
		var d1 := float(dr[1])
		# Ниша: проём, вырезанный в стене, а не нарисованный на ней. Глубина
		# 0.14 — ровно столько, чтобы в сумерках читалась тень, а не пятно.
		_shell(b, d0, d1, SL_PLINTH, SL_DOOR_TOP, z1 - 0.19, z1 - 0.15, "dark", 0.0)
		_shell(b, d0 + 0.04, d1 - 0.04, SL_PLINTH, SL_DOOR_TOP - 0.04,
			z1 - 0.11, z1 - 0.05, "shedwood", 1.2)
		_trim_frame(b, d0, d1, SL_PLINTH, SL_DOOR_TOP, z1, trim_mat)
	for win: Variant in cfg.get("wins", []):
		if not (win is Array) or (win as Array).size() != 2:
			continue
		var wx: Array = win
		var a := float(wx[0])
		var c := float(wx[1])
		_shell(b, a, c, float(SL_WIN[0]), float(SL_WIN[1]), z1 - 0.19, z1 - 0.15,
			"dark", 0.0)
		# Занавеска: светлая полоса в верхней трети. Свет в окне на второй
		# линии не горит ни у кого — дома пустые, и это должно быть видно.
		_shell(b, a + 0.05, c - 0.05, float(SL_WIN[1]) - 0.34, float(SL_WIN[1]) - 0.06,
			z1 - 0.09, z1 - 0.06, "fabric", 0.8)
		_trim_frame(b, a, c, float(SL_WIN[0]), float(SL_WIN[1]), z1, trim_mat)
		_shell(b, a + 0.025, c - 0.025, float(SL_WIN[0]) + 0.025,
			float(SL_WIN[1]) - 0.025, z1 - 0.045, z1 - 0.035, "glass", 0.0)
		var mid := (a + c) * 0.5
		_shell(b, mid - 0.022, mid + 0.022, float(SL_WIN[0]), float(SL_WIN[1]),
			z1 - 0.045, z1 + 0.025, trim_mat, 0.0)
		_shell(b, a - 0.11, c + 0.11, float(SL_WIN[0]) - 0.06,
			float(SL_WIN[0]), z1 - 0.10, z1 + 0.13, "tin", 0.0)
	out.get_or_add("facades", {})[key] = {"front": z1, "x": [x0,x1],
		"door": cfg.get("door", []), "windows": cfg.get("wins", [])}

	# --- крыльцо под свесом кровли ---
	if dr.size() == 2 and porch > 0.3:
		# ФАЗА 18. Свес крыльца зажимается границами СВОЕЙ секции стены.
		# Без этого у дома с проездом крыльцо и стойка навеса вылезали
		# в устье проезда: свес 0.55 м с каждой стороны, а от двери до
		# кромки проёма остаётся меньше.
		#
		# Сторона выбирается по СЕРЕДИНЕ двери, а не по её кромкам. Кромками
		# было — и стоило проезду расшириться на 0.3 м, как дверь заехала
		# в него краем, обе проверки провалились разом, зажим сорвался
		# на габарит всего дома, и пол крыльца лёг поперёк проезда.
		# Середина всегда лежит с одной стороны, и зажим всегда срабатывает.
		var mid := (float(dr[0]) + float(dr[1])) * 0.5
		var sec0 := pg1 if cut and mid > pg1 else x0
		var sec1 := pg0 if cut and mid < pg0 else x1
		var px0 := maxf(float(dr[0]) - 0.55, sec0)
		var px1 := minf(float(dr[1]) + 0.55, sec1)
		var pz1 := z1 + porch
		# Пол крыльца ниже порога шага: на него всходят, а не упираются.
		_shell(b, px0, px1, 0.0, 0.22, z1, pz1, "boards", 1.0)
		_solid(b, out, px0, px1, 0.0, 0.22, z1, pz1, "sl-porch-" + key)
		# Ступень.
		_shell(b, px0 + 0.16, px1 - 0.16, 0.0, 0.11, pz1, pz1 + 0.28, "boards", 0.8)
		# Стойки навеса: держат тот самый свес, который тут и оказался.
		for sx: float in [px0 + 0.08, px1 - 0.08]:
			_shell(b, sx - 0.05, sx + 0.05, 0.22, h, pz1 - 0.12, pz1 - 0.02,
				"boards", 1.4)

	# --- забор с калиткой ---
	var fz := float(cfg.get("fence", 0.0))
	if fz != 0.0:
		var wk: Array = cfg.get("wicket", [])
		var g0 := float(wk[0]) if wk.size() == 2 else 0.0
		var g1 := float(wk[1]) if wk.size() == 2 else 0.0
		# Границы забора по x можно задать явно: у крайнего дома второй линии
		# забор упирался бы в устье восточного проулка и запирал его.
		var fxr: Array = cfg.get("fx", [])
		var fx0 := float(fxr[0]) if fxr.size() == 2 else x0 - 0.6
		var fx1 := float(fxr[1]) if fxr.size() == 2 else x1 + 0.6
		for seg: Array in ([[fx0, g0], [g1, fx1]] if wk.size() == 2 else [[fx0, fx1]]):
			var a := float(seg[0])
			var c := float(seg[1])
			if c - a < 0.05:
				continue
			_shell(b, a, c, 0.14, SL_FENCE_H, fz - 0.04, fz + 0.04, "boards", 1.6)
			_solid(b, out, a, c, 0.0, SL_FENCE_H, fz - 0.05, fz + 0.05,
				"sl-fence-" + key + "-%d" % int(a * 10.0))
			# Прожилины: две горизонтали, по которым штакетник и набивают.
			for hy: float in [0.42, 0.92]:
				_shell(b, a, c, hy, hy + 0.07, fz - 0.055, fz - 0.035, "boards", 1.6)
		# Столбы: по краям и по бокам калитки.
		var posts: Array = [fx0, fx1]
		if wk.size() == 2:
			posts.append_array([g0, g1])
		for sx: float in posts:
			_shell(b, sx - 0.06, sx + 0.06, 0.0, SL_FENCE_H + 0.14,
				fz - 0.07, fz + 0.07, "boards", 1.0)
		# Дорожка от калитки к крыльцу — та же вытоптанная земля, что у крана.
		# ФАЗА 18. У дома с проездом она ведёт не к крыльцу, а НАСКВОЗЬ: от
		# калитки под дом и дальше во двор фермы. Это и объясняет проезд глазом —
		# в подворотню ездили, а не жили в ней.
		if wk.size() == 2 and dr.size() == 2:
			var mx := (g0 + g1) * 0.5
			var to_z := (z0 - 0.3) if cut else (z1 + porch + 0.3)
			_shell(b, mx - 0.42, mx + 0.42, 0.001, 0.012, minf(fz, to_z),
				maxf(fz, to_z), "dirt", 1.2)


# Наличник вокруг проёма: две стойки и перемычка, той же белой доской, что
# на доме игрока. Без него окно читается дыркой, а не окном.
static func _second_line_shell(b: WorldBuilder, cfg: Dictionary, x0: float,
		x1: float, z0: float, z1: float, h: float, key: String) -> void:
	# Задняя грань объёма отступает за дверное полотно и оконные откосы.
	_shell(b, x0, x1, SL_PLINTH, h, z0, z1 - 0.24, key, 0.0)
	var openings: Array = []
	var door: Array = cfg.get("door", [])
	if door.size() == 2:
		openings.append([float(door[0]),float(door[1]),SL_PLINTH,SL_DOOR_TOP])
	for win: Array in cfg.get("wins", []):
		if win.size() == 2:
			openings.append([float(win[0]),float(win[1]),float(SL_WIN[0]),float(SL_WIN[1])])
	openings.sort_custom(func(a: Array,c: Array)->bool: return float(a[0])<float(c[0]))
	var cursor := x0
	for hole: Array in openings:
		var a := maxf(x0,float(hole[0]))
		var c := minf(x1,float(hole[1]))
		if c-a < 0.01:
			continue
		if a>cursor:
			_shell(b,cursor,a,SL_PLINTH,h,z1-0.24,z1,key,0.0)
		if float(hole[2]) > SL_PLINTH:
			_shell(b,a,c,SL_PLINTH,float(hole[2]),z1-0.24,z1,key,0.0)
		_shell(b,a,c,float(hole[3]),h,z1-0.24,z1,key,0.0)
		_shell(b,a-0.025,a,float(hole[2]),float(hole[3]),z1-0.14,z1,"boards",0.0)
		_shell(b,c,c+0.025,float(hole[2]),float(hole[3]),z1-0.14,z1,"boards",0.0)
		cursor=c
	if cursor<x1:
		_shell(b,cursor,x1,SL_PLINTH,h,z1-0.24,z1,key,0.0)

static func _trim_frame(b: WorldBuilder, a: float, c: float, y0: float, y1: float,
		face_z: float, material := "trim") -> void:
	_shell(b, a - 0.09, a + 0.01, y0, y1 + 0.09, face_z - 0.03, face_z + 0.02, material, 0.0)
	_shell(b, c - 0.01, c + 0.09, y0, y1 + 0.09, face_z - 0.03, face_z + 0.02, material, 0.0)
	_shell(b, a - 0.09, c + 0.09, y1, y1 + 0.09, face_z - 0.03, face_z + 0.02, material, 0.0)


# ---------------------------------------------------------------- борта ----

static func _borders(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var lanes: Dictionary = d.get("LANES", {})
	for key: String in ["west", "east"]:
		var lane: Dictionary = lanes.get(key, {})
		if lane.is_empty():
			continue
		var lx: Array = lane["x"]
		var lz: Array = lane["z"]
		var t := float(lane.get("wallT", 0.20))
		var x0 := float(lx[0])
		var x1 := float(lx[1])
		var z0 := float(lz[0])
		var z1 := float(lz[1])
		# ФАЗА 16. Стенки переулка кончаются НЕ у самой улицы, а на wallEnd.
		# Раньше они шли во всю его длину, и вторая линия, ставшая улицей,
		# оказывалась перегорожена ими насквозь: игрок выходил из переулка и
		# упирался в его же стенку, потому что дорога второй линии идёт
		# ПОПЕРЁК него. Последние два метра переулок открыт в обе стороны —
		# это и есть перекрёсток.
		var wall_end := float(lane.get("wallEnd", z1))
		_solid(b, out, x0 - t, x0, 0.0, 3.0, z0, wall_end, "lane-" + key + "-w")
		_solid(b, out, x1, x1 + t, 0.0, 3.0, z0, wall_end, "lane-" + key + "-e")
		StreetWorld.tree_line_side(b, x0 - t - 0.3, z0, wall_end, 1.4, 3.0, 5.2, 401, -1.0)
		StreetWorld.tree_line_side(b, x1 + t + 0.3, z0, wall_end, 1.4, 3.0, 5.2, 402, 1.0)

	var outer: Dictionary = d.get("OUTER", {})
	if outer.is_empty():
		return
	var ox: Array = outer["x"]
	var oz: Array = outer["z"]
	var t2 := float(outer.get("t", 0.4))
	var h2 := float(outer.get("h", 3.2))
	var x0 := float(ox[0])
	var x1 := float(ox[1])
	var z0 := float(oz[0])          # -34.4, самый север
	var z1 := float(oz[1])          # -24.0, юг куска (стык со второй линией)

	# ФАЗА 16. Северный борт стал отрезками с проёмом: через него въезд в СНТ.
	# Проём стоит там, где уже нарисована тропа в лес (FIELD.trail): до этой
	# фазы она никуда не вела, и это единственное место карты, где игрок УЖЕ
	# пробовал пройти дальше. Нет секции gaps — борт сплошной, как был.
	var gaps: Array = outer.get("gaps", [])
	var runs: Array = [[x0, x1]]
	for g: Variant in gaps:
		if not (g is Array) or (g as Array).size() != 2:
			continue
		var ga: Array = g
		var cut: Array = []
		for seg: Array in runs:
			var a := float(seg[0])
			var c := float(seg[1])
			var g0 := float(ga[0])
			var g1 := float(ga[1])
			if g1 <= a or g0 >= c:
				cut.append(seg)
				continue
			if g0 > a:
				cut.append([a, g0])
			if g1 < c:
				cut.append([g1, c])
		runs = cut
	var i2 := 0
	for seg: Array in runs:
		_solid(b, out, float(seg[0]), float(seg[1]), 0.0, h2, z0 - t2, z0,
			"outskirts-north-%d" % i2)
		i2 += 1
	_solid(b, out, x0 - t2, x0, 0.0, h2, z0, -14.0, "outskirts-west")
	_solid(b, out, x1, x1 + t2, 0.0, h2, z0, -14.0, "outskirts-east")

	# Опушка по всему периметру: тот же приём, что у улицы (лес, а не стена).
	# В проёме её тоже нет — иначе въезд закрыт ёлками.
	for seg: Array in runs:
		StreetWorld.tree_line(b, z0 - t2 - 0.55, float(seg[0]), float(seg[1]),
			2.6, 3.4, 6.2, 501)
	StreetWorld.tree_line_side(b, x0 - t2 - 0.55, z0, -14.0, 2.6, 3.4, 6.2, 502, -1.0)
	StreetWorld.tree_line_side(b, x1 + t2 + 0.55, z0, -14.0, 2.6, 3.4, 6.2, 503, 1.0)


# ------------------------------------------------------------------ ферма ----

static func _farm(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var f: Dictionary = d.get("FARM", {})
	if f.is_empty():
		return
	var nodes: Dictionary = out["nodes"]

	var skin_barn := b.skin_begin("buildings", "outskirts", String((f.get("barn", {}) as Dictionary).get("id", "")), "FARM-barn")
	_barn(b, f.get("barn", {}), out)
	b.skin_end(skin_barn)

	for key: String in ["shed", "silo", "coop"]:
		var m: Dictionary = f.get(key, {})
		if m.is_empty():
			continue
		var mb: Array = m["box"]
		_solid(b, out, float(mb[0]), float(mb[1]), 0.0, float(m.get("y", 2.0)),
			float(mb[2]), float(mb[3]), "farm-" + key)

	# Ключ на гвозде у третьего стойла. Прячется, когда игрок его снял —
	# outskirts_quest.gd переключает видимость по флагу.
	var kp: Array = f.get("key", [])
	if kp.size() == 3:
		nodes["farm-key"] = _nail(b, Vector3(float(kp[0]), float(kp[1]), float(kp[2])))


# Амбар. Единственная постройка околицы, у которой есть и внутренность,
# и ворота во всю стену: скример №1 работает силуэтом В ПРОЁМЕ, а проём
# шириной в дверь силуэта не держит — он его прячет.
static func _barn(b: WorldBuilder, bn: Dictionary, out: Dictionary) -> void:
	if bn.is_empty():
		return
	var bx: Array = bn["x"]
	var bz: Array = bn["z"]
	var x0 := float(bx[0])
	var x1 := float(bx[1])
	var z0 := float(bz[0])
	var z1 := float(bz[1])
	var eave := float(bn.get("y", 3.6))
	var ridge := float(bn.get("ridge", 5.2))
	var t := float(bn.get("wall", 0.25))
	var g: Array = bn.get("gate", [x0 + 2.4, x1 - 2.4])
	var g0 := float(g[0])
	var g1 := float(g[1])
	var gtop := float(bn.get("gateTop", 3.0))
	_hollow(b, out, x0, x1, eave, z0, z1, t, g0, g1, gtop, "farm-barn")

	# Видимое: тёс снаружи и изнутри, земляной пол, стропила под коньком.
	var cz := (z0 + z1) / 2.0
	_shell(b, x0, x1, 0.0, eave, z0, z0 + t, "siding", 1.4)
	_shell(b, x0, x0 + t, 0.0, eave, z0 + t, z1 - t, "siding", 1.4)
	_shell(b, x1 - t, x1, 0.0, eave, z0 + t, z1 - t, "siding", 1.4)
	_shell(b, x0, g0, 0.0, eave, z1 - t, z1, "siding", 1.4)
	_shell(b, g1, x1, 0.0, eave, z1 - t, z1, "siding", 1.4)
	_shell(b, g0, g1, gtop, eave, z1 - t, z1, "siding", 1.4)
	_shell(b, x0 + t, x1 - t, 0.002, 0.03, z0 + t, z1 - t, "dirt", 1.6)
	_slope_soft(b, x0 - 0.34, x1 + 0.34, z0 - 0.34, cz, eave, ridge, "roof", 0.14)
	_slope_soft(b, x0 - 0.34, x1 + 0.34, cz, z1 + 0.34, ridge, eave, "roof", 0.14)
	_gable_soft(b, x0 + 0.06, z0, cz, z1, eave, ridge, "siding")
	_gable_soft(b, x1 - 0.06, z0, cz, z1, eave, ridge, "siding")
	for i in 4:
		var zb := z0 + t + (z1 - z0 - 2.0 * t) * (float(i) + 0.5) / 4.0
		_shell(b, x0 + t, x1 - t, eave - 0.16, eave - 0.04, zb - 0.07, zb + 0.07,
			"boards", 0.9)

	# Стойла. Перегородки только у восточной стены: западная половина остаётся
	# пустой, и в ней стоит фигура из ворот — ей нужно место, где её видно
	# целиком, а не по частям между досок.
	var st: Dictionary = bn.get("stalls", {})
	if st.is_empty():
		return
	var sx: Array = st["x"]
	var sz: Array = st["z"]
	var sh := float(st.get("h", 1.25))
	var stt := float(st.get("t", 0.12))
	for zv: float in sz:
		_solid(b, out, float(sx[0]), float(sx[1]), 0.0, sh, zv - stt / 2.0, zv + stt / 2.0)
		_shell(b, float(sx[0]), float(sx[1]), 0.0, sh, zv - stt / 2.0, zv + stt / 2.0,
			"boards", 1.1)


static func _nail(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "farm-key", pos)
	_piece(n, _box_mesh(b, Vector3(0.014, 0.10, 0.014), "", 0x7d8288), Vector3(0, -0.055, 0))
	_piece(n, _box_mesh(b, Vector3(0.05, 0.012, 0.012), "", 0x3a3f43), Vector3(-0.02, 0.03, 0))
	_piece(n, _box_mesh(b, Vector3(0.014, 0.05, 0.05), "", 0x6f767c), Vector3(0, 0.005, 0))
	return n


# ------------------------------------------------------------------- пруд ----

static func _pond(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var p: Dictionary = d.get("POND", {})
	if p.is_empty():
		return
	var w: Dictionary = p.get("water", {})
	if w.size() > 0:
		var wx: Array = w["x"]
		var wz: Array = w["z"]
		var wy := float(w.get("y", -0.06))
		var outline: Array = w.get("outline", [])
		if outline.size() >= 3:
			LakeVisuals.add_waterway(b, "story-lake", outline, [],
				{"y": wy, "kind": "valya-story-pond"})
		else:
			LakeVisuals.add_lake(b, "story-lake", float(wx[0]), float(wx[1]),
				float(wz[0]), float(wz[1]), wy)
	# Глубина блокируется независимо от удалённого настила. Коробки покрывают
	# внутреннее зеркало, но оставляют у восточного берега 0.7--0.9 м воды,
	# куда можно зайти к сети. Сухой маршрут к водокачке по x=-18.5 свободен.
	for deep: Array in [
		[-28.95, -20.55, -33.70, -31.55],
		[-29.35, -20.35, -31.55, -27.65],
		[-26.15, -20.35, -27.65, -24.15],
		[-29.00, -20.35, -34.85, -33.70],
	]:
		_solid(b, out, float(deep[0]), float(deep[1]), 0.0, 1.55,
			float(deep[2]), float(deep[3]), "story-water-deep-%d" % out["boxes"].size())

	# Корни, ил, затопленные колья и береговые камни идут в существующие
	# material buckets: ни одной самостоятельной отрисовки на предмет.
	for root_row: Array in [
		[-26.6, -27.4, 0.85, 0.10], [-25.9, -34.0, 1.10, -0.22],
		[-20.4, -25.0, 0.72, 0.34], [-20.7, -34.4, 0.92, -0.18],
	]:
		var rx := float(root_row[0])
		var rz := float(root_row[1])
		var len := float(root_row[2])
		var turn := float(root_row[3])
		b._slope(rx - len * 0.5, rx + len * 0.5, rz - 0.055, rz + 0.055,
			0.04, 0.18 + turn * 0.12, "log", 0.0, false)
	for stone: Vector2 in [Vector2(-26.4, -30.1), Vector2(-24.9, -24.2),
			Vector2(-20.5, -24.7), Vector2(-20.1, -32.7)]:
		_shell(b, stone.x - 0.24, stone.x + 0.24, 0.0, 0.16,
			stone.y - 0.18, stone.y + 0.18, "gravel", 0.6)
	for stump: Vector2 in [Vector2(-27.8, -25.4), Vector2(-28.4, -33.1)]:
		_shell(b, stump.x - 0.25, stump.x + 0.25, 0.0, 0.28,
			stump.y - 0.22, stump.y + 0.22, "log", 0.6)
	# A little shore rubbish, kept west of the lake-to-pump walking corridor.
	_shell(b, -27.15, -26.72, 0.035, 0.075, -24.55, -24.34, "tin", 0.0)
	_shell(b, -29.25, -28.64, 0.025, 0.065, -31.86, -31.71, "boards", 0.0)
	for stake: Vector2 in [Vector2(-24.8, -32.8), Vector2(-20.0, -33.6),
			Vector2(-19.7, -26.1)]:
		_shell(b, stake.x - 0.045, stake.x + 0.045, -0.08, 0.55,
			stake.y - 0.045, stake.y + 0.045, "log", 0.5)
	for reed: Variant in p.get("reeds", []):
		if reed is Array and (reed as Array).size() >= 3:
			_pond_reed(b, float(reed[0]), float(reed[2]))
	var marker: Variant = b.decor.get("story-lake-waterway")
	if marker is Node3D:
		marker.set_meta("reed_group_count", (p.get("reeds", []) as Array).size())
		marker.set_meta("deep_blocker_count", 4)


static func _pond_reed(b: WorldBuilder, x: float, z: float) -> void:
	for i in 4:
		var off := -0.24 + float(i) * 0.16
		_shell(b, x + off - 0.018, x + off + 0.018, 0.0,
			0.66 + 0.12 * float(i % 3), z - 0.018, z + 0.018, "grass", 0.8)


# --------------------------------------------------------------- водокачка ----

static func _pump(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var p: Dictionary = d.get("PUMP", {})
	if p.is_empty():
		return
	var nodes: Dictionary = out["nodes"]
	var base: Dictionary = p.get("base", {})
	if base.is_empty():
		return
	var bx: Array = base["x"]
	var bz: Array = base["z"]
	var x0 := float(bx[0])
	var x1 := float(bx[1])
	var z0 := float(bz[0])
	var z1 := float(bz[1])
	var h := float(base.get("y", 3.0))
	var t := float(base.get("wall", 0.30))

	# Дверь на замке: полотно рисуем, твёрдость — переключаемая, тем же
	# приёмом, что door-cellar-shed и door-shop (id в SET_OVERLAY, тумблер
	# через col.set_blocker_active). Проём в стене при этом вырезан
	# по-настоящему: сними замок — и пройдёшь.
	var dr: Dictionary = p.get("door", {})
	var dx: Array = dr.get("x", [(x0 + x1) / 2.0 - 0.35, (x0 + x1) / 2.0 + 0.35])
	var dyr: Array = dr.get("y", [0.0, 1.95])
	var d0 := float(dx[0])
	var d1 := float(dx[1])
	var dtop := float(dyr[1])
	_hollow(b, out, x0, x1, h, z0, z1, t, d0, d1, dtop, "pump-base")
	_solid(b, out, d0, d1, float(dyr[0]), dtop, z1 - t, z1, "door-pump")

	# Кирпич снаружи, побелка внутри, бетонный пол и плоская кровля, на
	# которой стоит башня.
	_shell(b, x0, x1, 0.0, h, z0, z0 + t, "brick", 1.6)
	_shell(b, x0, x0 + t, 0.0, h, z0 + t, z1 - t, "brick", 1.6)
	_shell(b, x1 - t, x1, 0.0, h, z0 + t, z1 - t, "brick", 1.6)
	_shell(b, x0, d0, 0.0, h, z1 - t, z1, "brick", 1.6)
	_shell(b, d1, x1, 0.0, h, z1 - t, z1, "brick", 1.6)
	_shell(b, d0, d1, dtop, h, z1 - t, z1, "brick", 1.6)
	_shell(b, x0 + t, x1 - t, 0.002, 0.04, z0 + t, z1 - t, "concrete", 1.8)
	_shell(b, x0 - 0.14, x1 + 0.14, h - 0.10, h, z0 - 0.14, z1 + 0.14, "concrete", 1.4)

	var leaf := _holder(b, "door-pump", Vector3((d0 + d1) * 0.5, float(dyr[0]), z1 - t / 2.0))
	_piece(leaf, _box_mesh(b, Vector3(d1 - d0 - 0.06, dtop - float(dyr[0]), 0.05),
		"shedwood"), Vector3(0, (dtop - float(dyr[0])) * 0.5, 0))
	nodes["door-pump"] = leaf

	# Сам насос: чугунная тумба у северной стены. Гудит она, а не башня —
	# dread-точка pump-hum стоит здесь же.
	var pm: Array = p.get("pump", [])
	if pm.size() == 5:
		_solid(b, out, float(pm[0]), float(pm[1]), 0.0, float(pm[4]),
			float(pm[2]), float(pm[3]))
		_shell(b, float(pm[0]), float(pm[1]), 0.0, float(pm[4]),
			float(pm[2]), float(pm[3]), "metal", 0.0)

	var brk: Array = p.get("breaker", [])
	if brk.size() == 3:
		nodes["pump-breaker"] = _breaker(b, Vector3(float(brk[0]), float(brk[1]), float(brk[2])))

	# Водонапорная башня вместо условного ветряка. Основание, дверь и все
	# сюжетные точки остаются прежними; над кровлей только новая мягкая оболочка.
	var tower := _holder(b, "water-tower", Vector3((x0 + x1) * 0.5, h, (z0 + z1) * 0.5))
	for sx: float in [-0.92, 0.92]:
		for sz: float in [-0.72, 0.72]:
			_piece(tower, _box_mesh(b, Vector3(0.12, 2.55, 0.12), "metal"),
				Vector3(sx, 1.28, sz))
	# Два ряда раскосов читаются с дороги, но не получают физических тел.
	for sy: float in [0.72, 1.62]:
		_piece(tower, _box_mesh(b, Vector3(2.10, 0.09, 0.09), "metal"),
			Vector3(0.0, sy, -0.72), Vector3(0.0, 0.0, 0.48 if sy < 1.0 else -0.48))
		_piece(tower, _box_mesh(b, Vector3(2.10, 0.09, 0.09), "metal"),
			Vector3(0.0, sy, 0.72), Vector3(0.0, 0.0, -0.48 if sy < 1.0 else 0.48))
	_piece(tower, _cylinder_mesh(b, 1.18, 1.52, "metal", 10), Vector3(0.0, 2.82, 0.0))
	_piece(tower, _cylinder_mesh(b, 0.14, 3.05, "metal", 8), Vector3(0.0, 1.48, 0.0))
	# Вентиль на южной стороне бака: ось и две рукояти.
	_piece(tower, _cylinder_mesh(b, 0.10, 0.44, "metal", 8),
		Vector3(0.0, 2.55, 1.00), Vector3(PI * 0.5, 0.0, 0.0))
	_piece(tower, _box_mesh(b, Vector3(0.68, 0.07, 0.07), "metal"),
		Vector3(0.0, 2.55, 1.23))
	_piece(tower, _box_mesh(b, Vector3(0.07, 0.68, 0.07), "metal"),
		Vector3(0.0, 2.55, 1.23))
	nodes["water-tower"] = tower


static func _breaker(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "pump-breaker", pos)
	_piece(n, _box_mesh(b, Vector3(0.12, 0.18, 0.05), "", 0x2b2f33), Vector3.ZERO)
	_piece(n, _box_mesh(b, Vector3(0.03, 0.09, 0.02), "", 0xc9c3ac), Vector3(0, 0.02, 0.035))
	return n


# ---------------------------------------------------------------- куры -----

static func _hens(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var h: Dictionary = d.get("HENS", {})
	if h.is_empty():
		return
	for key: String in ["coop2"]:
		var coop: Dictionary = h.get(key, {})
		if coop.is_empty():
			continue
		var cb: Array = coop["box"]
		_solid(b, out, float(cb[0]), float(cb[1]), 0.0, float(coop.get("y", 1.6)),
			float(cb[2]), float(cb[3]), "hens-" + key)
	# На footprint прежнего farm-smallbarn — открытый пустой дачный дом.
	# Исходный GLB остаётся в assets, а его экземпляр убран из props.json.
	var cottage: Dictionary = h.get("coop", {})
	if not cottage.is_empty():
		var skin_cottage := b.skin_begin("buildings", "outskirts", String(cottage.get("id", "")), "HENS-coop")
		var cb: Array = cottage["box"]
		var x0 := float(cb[0])
		var x1 := float(cb[1])
		var z0 := float(cb[2])
		var z1 := float(cb[3])
		var y1 := float(cottage.get("y", 2.08))
		var wt := 0.16
		# Проём прижат к восточной половине фасада: перед серединой footprint
		# лежит край старого крыльца второй линии, а здесь остаётся чистый створ.
		var d0 := x1 - 1.12
		var d1 := x1 - 0.04
		_hollow(b, out, x0, x1, y1, z0, z1, wt, d0, d1,
			1.92, "empty-cottage")
		_shell(b, x0, x1, 0.0, y1, z0, z0 + wt, "siding-grey-old", 1.2)
		_shell(b, x0, x0 + wt, 0.0, y1, z0, z1, "siding-grey-old", 1.2)
		_shell(b, x1 - wt, x1, 0.0, y1, z0, z1, "siding-grey-old", 1.2)
		_shell(b, x0, d0, 0.0, y1, z1 - wt, z1, "siding-grey-old", 1.2)
		_shell(b, d1, x1, 0.0, y1, z1 - wt, z1, "siding-grey-old", 1.2)
		_shell(b, d0, d1, 1.92, y1, z1 - wt, z1,
			"siding-grey-old", 1.2)
		var zm := (z0 + z1) * 0.5
		_slope_soft(b, x0 - 0.20, x1 + 0.20, z0 - 0.20, zm,
			y1, y1 + 0.72, "roof-rust", 0.10)
		_slope_soft(b, x0 - 0.20, x1 + 0.20, zm, z1 + 0.20,
			y1 + 0.72, y1, "roof-rust", 0.10)
		# Неблокирующая обстановка: кровать, табурет, печь и пустая полка.
		_shell(b, x0 + 0.25, x0 + 0.90, 0.12, 0.40, z0 + 0.24, z0 + 1.38,
			"fabric", 1.0)
		_shell(b, x1 - 0.66, x1 - 0.30, 0.0, 0.42, z0 + 0.34, z0 + 0.70,
			"boards", 1.0)
		_shell(b, x0 + 0.28, x0 + 0.68, 0.0, 0.76, z1 - 0.72, z1 - 0.30,
			"metal", 0.0)
		for sy: float in [0.58, 1.04, 1.50]:
			_shell(b, x1 - 0.48, x1 - 0.24, sy, sy + 0.06, z0 + 0.24, z0 + 1.10,
				"boards", 1.0)
		out["empty_house"] = {"x": [x0, x1], "z": [z0, z1],
			"door": [d0, d1], "face": "south"}
		b.skin_end(skin_cottage)
	# Бельё на верёвке, повешенное недавно, — хотя двор пустой. Гэг стоит
	# на виду у входа во двор, чтобы его нельзя было не заметить.
	var ln: Dictionary = h.get("line", {})
	if ln.size() > 0:
		var lx: Array = ln["x"]
		var ly := float(ln.get("y", 1.55))
		var lz := float(ln.get("z", -26.4))
		_shell(b, float(lx[0]) - 1.6, float(lx[1]) + 1.6, ly, ly + 0.02,
			lz - 0.01, lz + 0.01, "metal", 0.0)
		for k in 3:
			var cx := float(lx[0]) - 0.9 + 1.05 * float(k)
			_shell(b, cx - 0.24, cx + 0.24, ly - 0.62 - 0.08 * float(k), ly,
				lz - 0.02, lz + 0.02, "fabric", 0.9)
		for sx: float in [float(lx[0]) - 1.6, float(lx[1]) + 1.6]:
			_shell(b, sx - 0.05, sx + 0.05, 0.0, ly + 0.08, lz - 0.05, lz + 0.05,
				"boards", 1.0)
	var g: Dictionary = h.get("garden", {})
	if g.size() > 0:
		var gx: Array = g["x"]
		var gz: Array = g["z"]
		_shell(b, float(gx[0]), float(gx[1]), 0.001, 0.03, float(gz[0]), float(gz[1]),
			"dirt", 1.2)
	# Полоса примятой травы к пруду — просто более тёмный след того же
	# материала, что грядка-«крот»: визуальная рифма, без новой геометрии.
	var trail: Array = h.get("trail", [])
	if trail.size() == 2:
		var a: Array = trail[0]
		var bb: Array = trail[1]
		var mx := (float(a[0]) + float(bb[0])) * 0.5
		var mz := (float(a[2]) + float(bb[2])) * 0.5
		_shell(b, mx - 0.5, mx + 0.5, 0.001, 0.02, mz - 2.2, mz + 2.2, "dirt", 1.0)


# ----------------------------------------------------------------- клуб ----

static func _club(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var c: Dictionary = d.get("CLUB", {})
	if c.is_empty():
		return
	var hl: Dictionary = c.get("hall", {})
	if hl.is_empty():
		return
	var hx: Array = hl["x"]
	var hz: Array = hl["z"]
	var x0 := float(hx[0])
	var x1 := float(hx[1])
	var z0 := float(hz[0])
	var z1 := float(hz[1])
	var eave := float(hl.get("y", 4.4))
	var ridge := float(hl.get("ridge", 6.0))
	var t := float(hl.get("wall", 0.24))
	var dr: Array = hl.get("door", [(x0 + x1) / 2.0 - 0.5, (x0 + x1) / 2.0 + 0.5])
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	var dtop := float(hl.get("doorTop", 2.10))
	_hollow(b, out, x0, x1, eave, z0, z1, t, d0, d1, dtop, "club-hall")

	var cz := (z0 + z1) / 2.0
	_shell(b, x0, x1, 0.0, eave, z0, z0 + t, "siding", 1.3)
	_shell(b, x0, x0 + t, 0.0, eave, z0 + t, z1 - t, "siding", 1.3)
	_shell(b, x1 - t, x1, 0.0, eave, z0 + t, z1 - t, "siding", 1.3)
	_shell(b, x0, d0, 0.0, eave, z1 - t, z1, "siding", 1.3)
	_shell(b, d1, x1, 0.0, eave, z1 - t, z1, "siding", 1.3)
	_shell(b, d0, d1, dtop, eave, z1 - t, z1, "siding", 1.3)
	_shell(b, x0 + t, x1 - t, 0.002, 0.04, z0 + t, z1 - t, "boards", 1.7)
	_slope_soft(b, x0 - 0.32, x1 + 0.32, z0 - 0.32, cz, eave, ridge, "tin", 0.10)
	_slope_soft(b, x0 - 0.32, x1 + 0.32, cz, z1 + 0.32, ridge, eave, "tin", 0.10)
	_gable_soft(b, x0 + 0.06, z0, cz, z1, eave, ridge, "siding")
	_gable_soft(b, x1 - 0.06, z0, cz, z1, eave, ridge, "siding")

	# Забитые окна: стекла нет, вместо него крест-накрест доски. Проёма
	# в твёрдой стене не режем — окна заколочены, в них не лазают.
	var wins: Array = hl.get("windows", [])
	var wy: Array = hl.get("winY", [1.30, 2.30])
	for wn: Array in wins:
		var wa := float(wn[0])
		var wb := float(wn[1])
		_shell(b, wa, wb, float(wy[0]), float(wy[1]), z1 - t - 0.01, z1 - t + 0.01,
			"dark", 0.0)
		for k in 2:
			var yy := float(wy[0]) + (float(wy[1]) - float(wy[0])) * (0.32 + 0.36 * float(k))
			_shell(b, wa - 0.06, wb + 0.06, yy - 0.05, yy + 0.05,
				z1 - 0.03, z1 + 0.03, "boards", 0.6)


# ---------------------------------------------------------------- свалка ----

## Бочки, шифер и банки — модели из data/props.json. Остов «Запорожца»
## собран здесь коробками, и это не лень наоборот: готового ЗАЗ-968 в CC0
## нет, а узнаётся он ровно двумя деталями — покатой кормой и «ушами»
## воздухозаборников по бокам. Модель-заместитель этого не даёт, коробки дают.
static func _dump(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var dm: Dictionary = d.get("DUMP", {})
	var cp: Array = dm.get("car", [])
	if cp.size() != 3:
		return
	var cx := float(cp[0])
	var cz := float(cp[2])
	# Кузов осел на брюхо: колёс нет, поэтому низ кузова лежит на земле.
	_shell(b, cx - 0.79, cx + 0.79, 0.16, 0.78, cz - 1.87, cz + 1.87, "paint", 1.1)
	_shell(b, cx - 0.70, cx + 0.70, 0.78, 1.26, cz - 0.75, cz + 0.95, "paint", 0.9)
	# Стёкол нет — в проёмах темнота, и это самая дешёвая правда о брошенном.
	_shell(b, cx - 0.62, cx + 0.62, 0.86, 1.20, cz - 0.78, cz - 0.72, "dark", 0.0)
	_shell(b, cx - 0.62, cx + 0.62, 0.86, 1.20, cz + 0.92, cz + 0.98, "dark", 0.0)
	# «Уши» воздухозаборников — двигатель у ЗАЗа сзади, и это его подпись.
	for sx: float in [-1.0, 1.0]:
		_shell(b, cx + sx * 0.79, cx + sx * 0.88, 0.80, 1.14,
			cz + 0.34, cz + 0.86, "paint", 0.0)
	_shell(b, cx - 0.66, cx + 0.66, 0.10, 0.18, cz - 2.02, cz - 1.86, "metal", 0.0)
	_shell(b, cx - 0.20, cx + 0.20, 0.42, 0.58, cz - 1.94, cz - 1.88, "metal", 0.0)
	_solid(b, out, cx - 0.88, cx + 0.88, 0.0, 1.26, cz - 2.02, cz + 1.90, "dump-car")

	# Три бочки разнесены вокруг нового шестиметрового footprint мельницы.
	# Раньше координаты лежали только в data и не получали ни видимого тела,
	# ни overlay: после увеличения здания это читалось пустой свалкой.
	var barrel_i := 0
	for row: Variant in dm.get("barrels", []):
		if not (row is Array) or (row as Array).size() != 3:
			continue
		var bp := Vector3(float(row[0]), float(row[1]), float(row[2]))
		var barrel := _holder(b, "dump-barrel-%d" % barrel_i, bp)
		_piece(barrel, _cylinder_mesh(b, 0.38, 0.92, "metal", 10),
			Vector3(0.0, 0.46, 0.0), Vector3(0.0, float(barrel_i) * 0.37, 0.0))
		# Обручи остаются тонкими и светлее корпуса, иначе под VHS цилиндр
		# читается бетонной тумбой.
		for yy: float in [0.13, 0.79]:
			_piece(barrel, _cylinder_mesh(b, 0.395, 0.055, "tin", 10),
				Vector3(0.0, yy, 0.0))
		(out["nodes"] as Dictionary)["dump-barrel-%d" % barrel_i] = barrel
		barrel_i += 1

	var sh: Array = dm.get("shifer", [])
	if sh.size() == 3:
		# Гора шифера: три плиты внахлёст, поверх них — модели из props.json.
		for k in 3:
			var q := float(k)
			_shell(b, float(sh[0]) - 0.62 + 0.12 * q, float(sh[0]) + 0.62 - 0.10 * q,
				0.02 + 0.09 * q, 0.10 + 0.09 * q,
				float(sh[2]) - 0.52 + 0.08 * q, float(sh[2]) + 0.52 - 0.08 * q,
				"tin", 1.4)
		# ФАЗА 16. Верх коллизии был 0.40 при видимом верхе кучи 0.28: нога не
		# заносится (порог шага 0.25), а глазом куча читается ступенькой, на
		# которую вот-вот встанешь. 0.24 — ниже порога шага, и куча ведёт себя
		# ровно так, как выглядит: на неё наступают.
		_solid(b, out, float(sh[0]) - 0.66, float(sh[0]) + 0.66, 0.0, 0.24,
			float(sh[2]) - 0.56, float(sh[2]) + 0.56, "dump-shifer")


# --------------------------------------------------------- старая мельница ----

## Модель farm-windmill ставится отдельно через props.json. Здесь только тот
## overlay, который действительно держит игрока: замкнутые стены с дверным
## проёмом, две площадки, перила и две лестницы. Он не затрагивает базовый
## collision parity.
static func _mill(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var cfg: Dictionary = d.get("MILL", {})
	var a: Array = cfg.get("at", [21.0, 0.0, -29.0])
	if a.size() != 3:
		return
	var x := float(a[0])
	var z := float(a[2])
	var lower_y := float(cfg.get("lowerY", 4.10))
	var upper_y := float(cfg.get("upperY", 8.30))
	var nodes: Dictionary = out["nodes"]
	var k := float(cfg.get("scale", 1.30)) / 0.65

	# Тело здания. Южный фасад (+Z) разрезан вокруг прежней точки входа,
	# пересчитанной от единого центра. Остальные три стороны сплошные: GLB
	# больше нельзя пройти насквозь ни на земле, ни между площадками.
	var wall_hx := 1.375 * k
	var wall_hz := 1.375 * k
	var wall_t := 0.12
	var door_x := x - 0.86 * k
	var door_half := 0.55
	var door_top := 2.22
	_shell(b, x - wall_hx, x + wall_hx, 0.0, lower_y,
		z - wall_hz, z - wall_hz + wall_t, "boards", 1.3)
	_solid(b, out, x - wall_hx, x + wall_hx, 0.0, lower_y,
		z - wall_hz, z - wall_hz + wall_t, "mill-wall-back")
	for wx: float in [x - wall_hx, x + wall_hx - wall_t]:
		_shell(b, wx, wx + wall_t, 0.0, lower_y,
			z - wall_hz + wall_t, z + wall_hz, "boards", 1.3)
		_solid(b, out, wx, wx + wall_t, 0.0, lower_y,
			z - wall_hz + wall_t, z + wall_hz, "mill-wall-side")
	for sec: Array in [[x - wall_hx, door_x - door_half],
			[door_x + door_half, x + wall_hx]]:
		_shell(b, float(sec[0]), float(sec[1]), 0.0, lower_y,
			z + wall_hz - wall_t, z + wall_hz, "boards", 1.3)
		_solid(b, out, float(sec[0]), float(sec[1]), 0.0, lower_y,
			z + wall_hz - wall_t, z + wall_hz, "mill-wall-front")
	_shell(b, door_x - door_half, door_x + door_half, door_top, lower_y,
		z + wall_hz - wall_t, z + wall_hz, "boards", 1.3)
	_solid(b, out, door_x - door_half, door_x + door_half, door_top, lower_y,
		z + wall_hz - wall_t, z + wall_hz, "mill-door-lintel")

	# За штатными оконными рамами модели стоят непрозрачные тёмные плоскости:
	# они закрывают просвет сквозь башню, но не добавляют новых препятствий.
	for win_x: float in [x - 0.55 * k, x + 0.55 * k]:
		_shell(b, win_x - 0.34, win_x + 0.34, 2.58, 3.36,
			z + wall_hz - wall_t - 0.012, z + wall_hz - wall_t + 0.012,
			"dark", 0.0)
	for side: float in [-1.0, 1.0]:
		_shell(b, x + side * (wall_hx - wall_t) - 0.012,
			x + side * (wall_hx - wall_t) + 0.012, lower_y + 1.25,
			lower_y + 2.20, z - 0.38, z + 0.38, "dark", 0.0)

	# Четыре ноги оставляют проход вокруг основания и совпадают с силуэтом GLB.
	for sx: float in [-0.72 * k, 0.72 * k]:
		for sz: float in [-0.62 * k, 0.62 * k]:
			_shell(b, x + sx - 0.07, x + sx + 0.07, 0.0, upper_y + 0.55,
				z + sz - 0.07, z + sz + 0.07, "metal", 0.0)
			_solid(b, out, x + sx - 0.07, x + sx + 0.07, 0.0, upper_y + 0.55,
				z + sz - 0.07, z + sz + 0.07, "mill-leg")

	# Настилы имеют физическую толщину; южная кромка оставлена для выходов
	# лестниц, остальные кромки защищены узкими перилами.
	for row: Array in [[lower_y, 1.58 * k, 1.18 * k],
			[upper_y, 1.28 * k, 0.96 * k]]:
		var yy := float(row[0])
		var hx := float(row[1])
		var hz := float(row[2])
		_shell(b, x - hx, x + hx, yy - 0.10, yy, z - hz, z + hz, "boards", 0.8)
		_solid(b, out, x - hx, x + hx, yy - 0.10, yy, z - hz, z + hz,
			"mill-platform")
		for rx: float in [-hx, hx]:
			_shell(b, x + rx - 0.035, x + rx + 0.035, yy + 0.84, yy + 0.91,
				z - hz, z + hz, "metal", 0.0)
			var post_count := maxi(2, int(ceil((hz * 2.0) / 1.10)))
			for pi in post_count + 1:
				var pz := lerpf(z - hz, z + hz, float(pi) / float(post_count))
				_shell(b, x + rx - 0.035, x + rx + 0.035, yy, yy + 0.88,
					pz - 0.035, pz + 0.035, "metal", 0.0)
			_solid(b, out, x + rx - 0.045, x + rx + 0.045, yy, yy + 0.92,
				z - hz, z + hz, "mill-rail")
		_shell(b, x - hx, x + hx, yy + 0.84, yy + 0.91,
			z - hz - 0.035, z - hz + 0.035, "metal", 0.0)
		var rear_posts := maxi(2, int(ceil((hx * 2.0) / 1.10)))
		for pi in rear_posts + 1:
			var px := lerpf(x - hx, x + hx, float(pi) / float(rear_posts))
			_shell(b, px - 0.035, px + 0.035, yy, yy + 0.88,
				z - hz - 0.035, z - hz + 0.035, "metal", 0.0)
		_solid(b, out, x - hx, x + hx, yy, yy + 0.92,
			z - hz - 0.045, z - hz + 0.045, "mill-rail")

	# Две приставные лестницы. Подъём выполняет короткий переход камеры, но
	# видимые тетивы и ступени совпадают с точками входа/выхода.
	_mill_ladder(b, x - 0.86 * k, z + 1.32 * k, 0.0, lower_y)
	_mill_ladder(b, x + 0.68 * k, z + 1.05 * k, lower_y, upper_y)
	# До тормоза крыло физически перекрывает верхний вход. После mill-braked
	# OutskirtsQuest гасит эту именованную overlay-коробку и синхронизирует Jolt.
	_solid(b, out, x + 0.27 * k, x + 1.12 * k,
		lower_y + 0.90 * k, lower_y + 1.13 * k,
		z + 0.88 * k, z + 1.18 * k, "mill-upper-blade")

	# Ручное колесо, журнал и человекообразный ватник — отдельные узлы, потому
	# что квест вращает/скрывает их без перестройки material buckets.
	var wheel := _holder(b, "mill-wheel", Vector3(x - 0.92 * k,
		lower_y + 0.78 * k, z + 0.10 * k))
	_piece(wheel, _cylinder_mesh(b, 0.34, 0.07, "metal", 10), Vector3.ZERO,
		Vector3(PI * 0.5, 0.0, 0.0))
	nodes["mill-wheel"] = wheel
	var journal := _holder(b, "mill-journal", Vector3(x + 0.42 * k,
		upper_y + 0.08 * k, z - 0.34 * k))
	_piece(journal, _box_mesh(b, Vector3(0.36, 0.07, 0.48), "fabric"), Vector3.ZERO,
		Vector3(0.0, 0.28, 0.0))
	nodes["mill-journal"] = journal
	var coat := _holder(b, "mill-coat", Vector3(x - 0.54 * k, upper_y, z - 0.25 * k))
	_piece(coat, _box_mesh(b, Vector3(0.58, 1.02, 0.20), "fabric"), Vector3(0, 0.67, 0))
	_piece(coat, _box_mesh(b, Vector3(1.08, 0.20, 0.18), "fabric"), Vector3(0, 0.96, 0))
	_piece(coat, _cylinder_mesh(b, 0.15, 0.24, "dark", 8), Vector3(0, 1.34, 0))
	nodes["mill-coat"] = coat


static func _mill_ladder(b: WorldBuilder, x: float, z: float,
		y0: float, y1: float) -> void:
	for sx: float in [-0.28, 0.28]:
		_shell(b, x + sx - 0.035, x + sx + 0.035, y0, y1 + 0.12,
			z - 0.035, z + 0.035, "metal", 0.0)
	var count := maxi(4, int(ceil((y1 - y0) / 0.28)))
	for i in count + 1:
		var yy := lerpf(y0 + 0.12, y1 - 0.08, float(i) / float(count))
		_shell(b, x - 0.31, x + 0.31, yy - 0.025, yy + 0.025,
			z - 0.045, z + 0.045, "metal", 0.0)


# ----------------------------------------------------------------- поле ----

static func _field(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var fl: Dictionary = d.get("FIELD", {})
	if fl.is_empty():
		return

	# Дальний амбар — модель на коробке-заместителе: силуэт в тумане.
	var bn: Dictionary = fl.get("barn", {})
	if bn.size() > 0:
		var bb: Array = bn["box"]
		_solid(b, out, float(bb[0]), float(bb[1]), 0.0, float(bn.get("y", 3.2)),
			float(bb[2]), float(bb[3]), "field-barn")

	# Пугало в телогрейке Вити. Крест, ватник, ведро вместо головы — и ни
	# одного испуга на нём: оно страшное само по себе, ровно пока к нему
	# не приделали механику.
	var sc: Array = fl.get("scarecrow", [])
	if sc.size() == 3:
		var sx := float(sc[0])
		var sz := float(sc[2])
		_shell(b, sx - 0.05, sx + 0.05, 0.0, 2.05, sz - 0.05, sz + 0.05, "boards", 1.6)
		_shell(b, sx - 0.62, sx + 0.62, 1.34, 1.44, sz - 0.05, sz + 0.05, "boards", 1.2)
		_shell(b, sx - 0.42, sx + 0.42, 0.95, 1.62, sz - 0.14, sz + 0.14, "fabric", 1.0)
		_shell(b, sx - 0.16, sx + 0.16, 1.62, 1.92, sz - 0.16, sz + 0.16, "metal", 0.8)
		# ФАЗА 16. Коробка была 0.50 при видимом столбе 0.16: игрок обходил
		# пугало по дуге вдвое шире самого пугала и не понимал, обо что
		# споткнулся. Твёрдым остаётся столб, ватник и ведро — нет.
		_solid(b, out, sx - 0.08, sx + 0.08, 0.0, 2.05, sz - 0.08, sz + 0.08,
			"field-scarecrow")

	# Тропа в лес: полоса вытоптанной земли, уходящая за северный борт. Идти
	# по ней некуда — и это работает лучше запертой калитки.
	var tr: Array = fl.get("trail", [])
	if tr.size() == 3:
		_shell(b, float(tr[0]) - 0.7, float(tr[0]) + 0.7, 0.001, 0.02,
			float(tr[2]) - 1.4, -24.6, "dirt", 1.0)


# --------------------------------------------------------------- заборы ----

## Прясла Quaternius. Модель — из props.json, твёрдость — отсюда: забор,
## который видно и сквозь который ходят, читается ошибкой сборки, а не
## заброшенностью. Коробку раздувает до 16 см уже генератор данных: восемь
## сантиметров штакетника капсула задевает краем, не показывая, чем.
static func _fences(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var i := 0
	for fn: Variant in d.get("FENCES", []):
		if not (fn is Dictionary):
			continue
		var fb: Array = (fn as Dictionary)["box"]
		_solid(b, out, float(fb[0]), float(fb[1]), 0.0,
			float((fn as Dictionary).get("y", 0.6)), float(fb[2]), float(fb[3]),
			"fence-%d" % i)
		i += 1


# ------------------------------------------------------------- примитивы ----

# Коробка-помещение: четыре стены толщиной t, проём в южной (все три двери
# околицы смотрят на юг, к дороге) и перемычка над ним. Ровно те же шесть
# коробок, что руками расписаны у сельпо и красного дома, — но помещений
# здесь три, и третья копия того же кода была бы третьим местом для ошибки.
static func _hollow(b: WorldBuilder, out: Dictionary, x0: float, x1: float,
		y1: float, z0: float, z1: float, t: float,
		d0: float, d1: float, dtop: float, id := "") -> void:
	_solid(b, out, x0, x1, 0.0, y1, z0, z0 + t, id + "-n")
	_solid(b, out, x0, x0 + t, 0.0, y1, z0 + t, z1 - t, id + "-w")
	_solid(b, out, x1 - t, x1, 0.0, y1, z0 + t, z1 - t, id + "-e")
	_solid(b, out, x0, d0, 0.0, y1, z1 - t, z1, id + "-s0")
	_solid(b, out, d1, x1, 0.0, y1, z1 - t, z1, id + "-s1")
	_solid(b, out, d0, d1, dtop, y1, z1 - t, z1, id + "-lintel")


## Скат и фронтон — мягкими: WorldBuilder._gable() зовёт box() без
## collide = false и уходит в SET_STATIC целиком, а паритет этого не переживёт.
static func _slope_soft(b: WorldBuilder, x0: float, x1: float, z0: float, z1: float,
		ya: float, yb: float, key: String, t: float) -> void:
	b._slope(x0, x1, z0, z1, ya, yb, key, t, false)


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


static func _shell(b: WorldBuilder, x0: float, x1: float, y0: float, y1: float,
		z0: float, z1: float, key: String, seg := 0.0) -> void:
	b.box(x0, x1, y0, y1, z0, z1, key, seg, false)


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
	(out["boxes"] as Array).append(AABB(Vector3(ax, ay, az), Vector3(bx - ax, by - ay, bz - az)))


static func _holder(b: WorldBuilder, id: String, pos: Vector3, shown := true) -> Node3D:
	var n := Node3D.new()
	n.name = "outskirts-" + id
	n.position = pos
	n.visible = shown
	b.decor["outskirts-" + id] = n
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


static func _cylinder_mesh(b: WorldBuilder, radius: float, height: float,
		key: String, sides := 8) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	m.radial_segments = sides
	m.rings = 1
	m.material = b.mats.get_mat(key)
	return m


# Тот же гард по id, что village_world._zones(): GameData кэширует site.json
# по ссылке, мир собирают несколько тестов подряд, без гарда зоны бы удвоились.
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

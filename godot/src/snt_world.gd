# СНТ за околицей — район фазы 16.
#
# ЗАЧЕМ ОН ЕСТЬ. Пётр попросил полноценное садовое товарищество: не десять
# домов вдоль одной прямой, а сеть проездов с поворотами, участками, машинами
# у ворот, лесом и водой. И одно условие, которое перевешивает объём: игра
# обязана работать без лагов. Поэтому район строится ровно теми приёмами,
# которыми считался кадр в блоке 1, и меряется после каждого проезда.
#
# ПРАВИЛО, КОТОРОЕ ЗДЕСЬ ГЛАВНОЕ И МЕХАНИЧЕСКОЕ — то же, что у околицы:
#
#   видимое  -> _shell()      = b.box(..., collide = false)
#   твёрдое  -> _solid()      = col.add_box_d(SET_OVERLAY)
#   скат     -> _slope_soft() = b._slope(..., collide = false)
#   фронтон  -> _gable_soft() = ступеньками через _shell()
#
# Прямых вызовов b.box/slab/wall/fence/stairs/rail/roof/_slopeX/_gable здесь
# нет ни одного: _slopeX() не имеет параметра collide и ВСЕГДА пишет в
# SET_STATIC, а _gable() зовёт box() без collide = false. Одна такая строка —
# и паритет 311/4/83 разъедется. Сторожит tests/test_snt_overlay.gd: мир
# собирается с файлом и без него, оба раза обязан дать 311/4/83 и 3885.
#
# ГДЕ ОН ЛЕЖИТ. Всё севернее z = -34.4. Там нет ни полосы деда, ни кольца
# соседа, ни навграфа, и центральная улица остаётся прямой. Въезд — через
# тропу в лес на восточном краю околицы (outskirts.json FIELD.trail, x 37.5):
# сегодня она никуда не ведёт, и это единственное место карты, где игрок уже
# пробовал пройти дальше.
#
# КАДР. Каждый участок — свой кусок в общих merged-сетках (нарезка блока 1,
# клетка 32 м), планировка не даёт прострелов длиннее сорока метров, дороги и
# обочины — плоскости с уже существующими материалами, а не модели. Ни одного
# нового ключа материала, ни одного нового источника света с тенями.
#
# Нет data/snt.json — build() выходит первой строкой, и мир ровно тот, что
# принят в блоке 4.

class_name SntWorld
extends RefCounted

const DATA := "res://data/snt.json"

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
		"boxes": [],        # AABB твёрдой геометрии — тем же контрактом, что околица
		"nodes": {},        # id -> Node3D
		"roads": d.get("ROADS", []),
		"plots": d.get("PLOTS", []),
		"lake": d.get("LAKE", {}),
	}

	_ground(b, d, out)
	_roads(b, d)
	_border(b, d, out)
	var skin_entry := b.skin_begin("buildings", "snt", String((d.get("ENTRY", {}) as Dictionary).get("id", "")), "ENTRY")
	_entry(b, d, out)
	b.skin_end(skin_entry)
	_lake(b, d, out)
	for p: Variant in d.get("PLOTS", []):
		if p is Dictionary:
			_plot(b, p, out)
	_landmarks(b, d, out)
	RuralDressing.quest_props(b, out)
	preload("res://src/snt_episode_world.gd").build(b, out)
	_zones(d.get("ZONES", []))
	return out


# ----------------------------------------------------------------- земля ----

static func _ground(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var g: Dictionary = d.get("GROUND", {})
	if g.is_empty():
		return
	var gx: Array = g["x"]
	var gz: Array = g["z"]
	var x0 := float(gx[0])
	var x1 := float(gx[1])
	var z0 := float(gz[0])
	var z1 := float(gz[1])

	# Трава района одной плоскостью. Нарезка блока 1 разложит её по клеткам
	# 32 м сама — здесь важно только то, что это ПЛОСКОСТЬ с материалом, а не
	# набор тайлов: дорожные тайлы стоили бы по вызову отрисовки на каждый.
	_shell(b, x0, x1, -0.03, 0.0, z0, z1, "grass", 4.0)
	# Подложка грунта пошире: без неё край района читается чёрным провалом.
	_shell(b, x0 - 8.0, x1 + 8.0, -0.5, -0.32, z0 - 8.0, z1, "dirt", 10.0)
	# Твёрдая плита под всей ходовой землёй разом — одна коробка на район,
	# а не по одной на участок: игрок не должен проваливаться в стыке.
	_solid(b, out, x0, x1, -0.20, 0.0, z0, z1, "snt-floor")


# Дороги, колея и обочина — плоскости поверх травы. Тот же приём, что у
# переулков околицы, и по той же причине: тайлы дороги это модели, а модель
# на карту размером с СНТ стоит сотню вызовов отрисовки.
static func _roads(b: WorldBuilder, d: Dictionary) -> void:
	for r: Variant in d.get("ROADS", []):
		if not (r is Dictionary):
			continue
		var rd: Dictionary = r
		var rx: Array = rd["x"]
		var rz: Array = rd["z"]
		var mat := String(rd.get("mat", "gravel"))
		_shell(b, float(rx[0]), float(rx[1]), -0.02, 0.012,
			float(rz[0]), float(rz[1]), mat, 1.8)
		# Колея: две тёмные полосы вдоль длинной стороны. Их видно только
		# вблизи, и ровно этого достаточно, чтобы дорога перестала быть
		# прямоугольником другого цвета.
		var horiz := (float(rx[1]) - float(rx[0])) >= (float(rz[1]) - float(rz[0]))
		var cx := (float(rx[0]) + float(rx[1])) * 0.5
		var cz := (float(rz[0]) + float(rz[1])) * 0.5
		for s: float in [-0.72, 0.72]:
			if horiz:
				_shell(b, float(rx[0]) + 0.4, float(rx[1]) - 0.4, 0.012, 0.018,
					cz + s - 0.16, cz + s + 0.16, "dirt", 1.4)
			else:
				_shell(b, cx + s - 0.16, cx + s + 0.16, 0.012, 0.018,
					float(rz[0]) + 0.4, float(rz[1]) - 0.4, "dirt", 1.4)


# ----------------------------------------------------------------- борта ----

static func _border(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var bd: Dictionary = d.get("BORDER", {})
	if bd.is_empty():
		return
	var g: Dictionary = d.get("GROUND", {})
	var gx: Array = g["x"]
	var gz: Array = g["z"]
	var x0 := float(gx[0])
	var x1 := float(gx[1])
	var z0 := float(gz[0])          # самый север
	var z1 := float(gz[1])          # стык с околицей
	var t := float(bd.get("t", 0.4))
	var h := float(bd.get("h", 3.4))

	# Служебный проход справа от будки и выход лесной петли к Рябовым.
	_solid(b, out, x0, 8.6, 0.0, h, z0 - t, z0, "snt-north")
	_solid(b, out, 10.6, x1, 0.0, h, z0 - t, z0, "snt-north-east")
	_solid(b, out, x0 - t, x0, 0.0, h, z0, -56.0, "snt-west")
	_solid(b, out, x0 - t, x0, 0.0, h, -53.0, z1, "snt-west-south")
	_solid(b, out, x1, x1 + t, 0.0, h, z0, z1, "snt-east")

	# Южная сторона — борт околицы, он уже стоит. Кроме проёма въезда: там
	# в нём вырезана дыра (outskirts.json OUTER.gaps), и закрывать её нельзя.
	for seg: Variant in bd.get("south", []):
		if not (seg is Array) or (seg as Array).size() != 2:
			continue
		var s: Array = seg
		_solid(b, out, float(s[0]), float(s[1]), 0.0, h, z1, z1 + t, "snt-south")

	# Опушка по периметру: лес, а не невидимая стена. Тот же приём и тот же
	# материал, что у околицы, — нового ключа не заводим.
	StreetWorld.tree_line(b, z0 - t - 0.55, x0, x1, 2.6, 3.4, 6.4, 601, [[5.8,12.0]])
	StreetWorld.tree_line_side(b, x0 - t - 0.55, z0, -57.0, 2.6, 3.4, 6.4, 602, -1.0)
	StreetWorld.tree_line_side(b, x0 - t - 0.55, -52.0, z1, 2.6, 3.4, 6.4, 604, -1.0)
	StreetWorld.tree_line_side(b, x1 + t + 0.55, z0, z1, 2.6, 3.4, 6.4, 603, 1.0)


# ----------------------------------------------------------------- въезд ----

# Въездной коридор с воротами и вывеской.
#
# Это не украшение. В проёме борта игрок стоит между двумя районами, и оба
# оказываются в кадре разом: фрустум про стены не знает, отсечения по
# перекрытию в Compatibility нет, и вся околица честно уходила в GPU СКВОЗЬ
# трёхметровый борт — 776 вызовов отрисовки на въезде при 267 в середине
# самого района. Глухие щёки коридора закрывают её геометрией, а не
# настройкой, и заодно делают то, чем въезд в СНТ и должен быть: створ,
# вывеска, а дальше уже своя дорога.
static func _entry(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var en: Dictionary = d.get("ENTRY", {})
	if en.is_empty():
		return
	var ex: Array = en["x"]
	var ez: Array = en["z"]
	var x0 := float(ex[0])
	var x1 := float(ex[1])
	var z0 := float(ez[0])
	var z1 := float(ez[1])
	var h := float(en.get("h", 3.0))
	var t := float(en.get("t", 0.35))

	for sx: float in [x0, x1]:
		var a := sx - t if sx == x1 else sx
		var c := sx if sx == x1 else sx + t
		_shell(b, a, c, 0.0, h, z0, z1, "boards", 2.0)
		_solid(b, out, a, c, 0.0, h, z0, z1, "snt-entry-%d" % int(sx))
		# Столбы створа повыше щёк: издали видно, куда идти.
		_shell(b, a - 0.06, c + 0.06, 0.0, h + 0.42, z1 - 0.24, z1 + 0.06, "boards", 1.0)

	# Перекладина над въездом с вывеской. Высоко — под ней проезжают.
	_shell(b, x0, x1, h + 0.18, h + 0.42, z1 - 0.18, z1 - 0.02, "boards", 2.0)
	_shell(b, x0 + 0.9, x1 - 0.9, h + 0.44, h + 0.94, z1 - 0.14, z1 - 0.06, "tin", 1.6)
	_shell(b, x0 + 1.0, x1 - 1.0, h + 0.50, h + 0.88, z1 - 0.16, z1 - 0.14, "dark", 1.4)


# ------------------------------------------------------------------ вода ----

static func _lake(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var lk: Dictionary = d.get("LAKE", {})
	if lk.is_empty():
		return
	var lx: Array = lk["x"]
	var lz: Array = lk["z"]
	var x0 := float(lx[0])
	var x1 := float(lx[1])
	var z0 := float(lz[0])
	var z1 := float(lz[1])
	var outline: Array = lk.get("outline", [])
	var channels: Array = lk.get("channels", [])
	var water: Dictionary
	if outline.size() >= 3:
		water=LakeVisuals.add_waterway(b, "snt-lake", outline, channels,
			{"y": float(lk.get("y", 0.006)), "kind": "snt-river-lake"})
	else:
		water=LakeVisuals.add_lake(b, "snt-lake", x0, x1, z0, z1,
			float(lk.get("y", 0.006)))
	out["waterway"]=water
	var dry: Array[Rect2] = [Rect2(-46,-56.05,90,4.45)]

	# Мостки: настил на сваях, уходящий в воду. Собраны досками, а не моделью:
	# у модели свой материал и свой вызов отрисовки, у досок — общий бакет.
	var dk: Dictionary = lk.get("dock", {})
	if dk.size() > 0:
		var dx: Array = dk["x"]
		var dz: Array = dk["z"]
		var a := float(dx[0])
		var c := float(dx[1])
		var p := float(dz[0])
		var q := float(dz[1])
		# Неровные поперечные доски. Седьмая отсутствует физически в рисунке,
		# но непрерывный proxy ниже оставляет настил проходимым до самого конца.
		var board_count := maxi(9, int(ceil((q - p) / 0.34)))
		for k in board_count:
			if k == board_count / 2:
				continue
			var t0 := float(k) / float(board_count)
			var t1 := float(k + 1) / float(board_count)
			var zz0 := lerpf(p, q, t0) + 0.018
			var zz1 := lerpf(p, q, t1) - 0.018
			var nibble := 0.04 * sin(float(k) * 2.17)
			var yy := 0.16 + 0.012 * float(k % 3)
			_shell(b, a + maxf(0.0, nibble), c + minf(0.0, nibble), yy, yy + 0.06,
				zz0, zz1, "boards", 1.2)
		_solid(b, out, a, c, 0.0, 0.22, p, q, "snt-dock")
		for sx: float in [a + 0.16, c - 0.16]:
			for sz: float in [p + 0.2, (p + q) * 0.5, q - 0.2]:
				_shell(b, sx - 0.06, sx + 0.06, 0.0, 0.18, sz - 0.06, sz + 0.06,
					"boards", 0.0)
		# Водоросли на нижней кромке остаются в grass bucket.
		for sz: float in [p + 0.45, (p + q) * 0.5, q - 0.55]:
			_shell(b, a - 0.025, a + 0.045, 0.04, 0.15, sz - 0.24, sz + 0.24,
				"grass", 0.8)
		# Лодка у мостков, вросшая в ил. Её никто не столкнёт.
		var bt: Array = lk.get("boat", [])
		if bt.size() == 2:
			var bx := float(bt[0])
			var bz := float(bt[1])
			var boat := LakeVisuals.boat_node(b, "snt-lake-boat",
				Vector3(bx, 0.02, bz), 0.0)
			b.decor["snt-lake-boat"] = boat
			_solid(b, out, bx - 0.62, bx + 0.62, 0.0, 0.36, bz - 1.75, bz + 1.75,
				"snt-boat")

		# Общий контур блокируется за пределами настила, включая его торец.
		dry.append(Rect2(a,p,c-a,q-p))
	var water_boxes := LakeVisuals.add_water_blockers(b,out,"snt-water",water,dry)
	out["water_blockers"]=water_boxes
	var marker: Node3D = b.decor.get("snt-lake-waterway")
	if marker!=null:
		marker.set_meta("blocker_count",water_boxes.size())
		marker.set_meta("shared_collision_contour",true)

	# Узкая река проходит под вторым проездом, поэтому blocker разомкнут на
	# всей ширине дороги z [-56,-51.6]. Северный хвост заканчивается болотом
	# до третьего проезда; существующие дороги остаются сквозными.
	if not channels.is_empty():
		for k in 11:
			var zz0 := -56.0 + float(k) * 0.40
			var zz1 := zz0 + 0.35
			var edge := 0.05 * sin(float(k) * 1.71)
			_shell(b, -19.55 + edge, -16.25 + edge, 0.018, 0.055, zz0, zz1,
				"boards", 1.0)
		# Камышовое болото перед третьим проездом.
		for marsh: Vector2 in [Vector2(-18.9, -58.8), Vector2(-18.2, -59.15),
				Vector2(-17.4, -58.75), Vector2(-16.7, -59.05)]:
			_reed(b, marsh.x, marsh.y)

	# Камыш по берегу — billboard'ами, двумя скрещенными плоскостями на куст.
	for r: Variant in lk.get("reeds", []):
		if not (r is Array) or (r as Array).size() != 2:
			continue
		var rr: Array = r
		if EnvironmentLandscape.on_route(float(rr[0]),float(rr[1]),0.25): continue
		_reed(b, float(rr[0]), float(rr[1]))


# Камыш: два скрещенных полотна. В CC0 его найти не удалось, а модель ради
# травы у воды — это лишний материал и лишний вызов отрисовки.
static func _reed(b: WorldBuilder, x: float, z: float) -> void:
	for k in 3:
		var q := float(k)
		var off := -0.26 + 0.26 * q
		_shell(b, x + off - 0.02, x + off + 0.02, 0.0, 0.95 + 0.22 * sin(q * 2.1),
			z - 0.02, z + 0.02, "grass", 1.0)
	_shell(b, x - 0.30, x + 0.30, 0.0, 0.62, z - 0.03, z + 0.03, "grass", 1.2)
	_shell(b, x - 0.03, x + 0.03, 0.0, 0.62, z - 0.30, z + 0.30, "grass", 1.2)


# --------------------------------------------------------------- участок ----

const PL_FENCE_H := 1.15
const PL_WALL := 0.22
const PL_PLINTH := 0.22
const PL_DOOR_H := 2.00
const PL_TRIM := 0.08
const PL_OPENING_GAP := 0.12

## Размеры проёмов относятся к стеклу/полотну; trim расширяет их на 8 см.
static func facade_layout(hs: Dictionary, face: String) -> Dictionary:
	var sideways := face == "e" or face == "w"
	var hx: Array = hs["x"]
	var hz: Array = hs["z"]
	var span: Array = hz if sideways else hx
	var centre := (float(span[0])+float(span[1]))*0.5
	var dr: Array = hs.get("door", [centre-0.5,centre+0.5])
	if sideways:
		dr = hs.get("entry", [centre-0.5,centre+0.5])
	var windows: Array = hs.get("wins", []).duplicate(true)
	if sideways:
		windows = [[float(span[0])+0.30,centre-0.80],[centre+0.80,float(span[1])-0.30]]
	var accepted: Array = []
	for raw: Array in windows:
		var a := maxf(float(span[0])+0.18,float(raw[0]))
		var c := minf(float(span[1])-0.18,float(raw[1]))
		if (a+c)*0.5 < centre:
			c = minf(c,float(dr[0])-2.0*PL_TRIM-PL_OPENING_GAP)
		else:
			a = maxf(a,float(dr[1])+2.0*PL_TRIM+PL_OPENING_GAP)
		if c-a >= 0.26:
			accepted.append({"a": a,"c": c,"y0": PL_PLINTH+0.95,"y1": PL_PLINTH+1.72,"kind": "window"})
	var wall_at := (float(hx[1]) if face == "e" else float(hx[0])) if sideways else (float(hz[1]) if face == "s" else float(hz[0]))
	return {"sideways": sideways,"span": span,"wall_at": wall_at,
		"outward": 1.0 if face == "e" or face == "s" else -1.0,
		"door": {"a": float(dr[0]),"c": float(dr[1]),"y0": PL_PLINTH,"y1": PL_PLINTH+PL_DOOR_H,"kind": "door"},
		"windows": accepted,"entry_inset": float(hs.get("entryInset",0.16))}

static func porch_rect(hs: Dictionary, face: String) -> Rect2:
	var layout := facade_layout(hs, face)
	var door: Dictionary = layout["door"]
	var wall := float(layout["wall_at"])
	var outward := float(layout["outward"])
	var outside := wall+outward*float(hs.get("porchDepth",0.9))
	var inside := wall-outward*(float(layout["entry_inset"]) if hs.has("porchDepth") else 0.0)
	var a := float(door["a"])-0.42
	var c := float(door["c"])+0.42
	return Rect2(minf(inside,outside),a,absf(outside-inside),c-a) if layout["sideways"] else Rect2(a,minf(inside,outside),c-a,absf(outside-inside))

static func extra_rect(e: Dictionary) -> Rect2:
	var at: Array = e.get("at",[])
	if at.size() != 2:
		return Rect2()
	var size: Vector2 = {"woodpile": Vector2(2.10,0.52),"barrel": Vector2(0.68,0.68),
		"bench": Vector2(1.56,0.44),"repair": Vector2(0.28,0.92),
		"line": Vector2(float(e.get("w",3.4))+0.10,0.10),
		"greenhouse": Vector2(float(e.get("w",2.4)),float(e.get("d",3.6)))}.get(String(e.get("k","")),Vector2.ZERO)
	return Rect2(Vector2(float(at[0]),float(at[1]))-size*0.5,size)

static func _closed_shell(b: WorldBuilder, hs: Dictionary, face: String,
		id: String, x0: float, x1: float, z0: float, z1: float, eave: float, key: String) -> Dictionary:
	var layout := facade_layout(hs,face)
	var sideways: bool = layout["sideways"]
	var outward := float(layout["outward"])
	var at := float(layout["wall_at"])
	var depth := float(layout["entry_inset"])
	var backing_depth := maxf(PL_WALL,depth+0.04)
	var spans: Array = layout["span"]
	# Задник утоплен за проёмы. Физический дом остаётся прежней полной коробкой.
	var a := x0+backing_depth if face == "w" else x0
	var c := x1-backing_depth if face == "e" else x1
	var p := z0+backing_depth if face == "n" else z0
	var q := z1-backing_depth if face == "s" else z1
	_shell(b,a,c,PL_PLINTH,eave,p,q,key,0.0)
	var holes: Array = [layout["door"]]
	holes.append_array(layout["windows"])
	holes.sort_custom(func(l: Dictionary,r: Dictionary)->bool: return float(l["a"])<float(r["a"]))
	var cursor := float(spans[0])
	for hole: Dictionary in holes:
		var ha := float(hole["a"])
		var hc := float(hole["c"])
		var y0 := float(hole["y0"])
		var y1 := float(hole["y1"])
		_face_volume(b,sideways,at-outward*PL_WALL,at,cursor,ha,PL_PLINTH,eave,key)
		_face_volume(b,sideways,at-outward*PL_WALL,at,ha,hc,PL_PLINTH,y0,key)
		_face_volume(b,sideways,at-outward*PL_WALL,at,ha,hc,y1,eave,key)
		var recess := depth if hole["kind"] == "door" else 0.13
		# Притвор, откосы и закрытая створка читаются при скользящем свете.
		_face_volume(b,sideways,at-outward*recess,at,ha-0.025,ha,y0,y1,"boards")
		_face_volume(b,sideways,at-outward*recess,at,hc,hc+0.025,y0,y1,"boards")
		_face_piece(b,sideways,at-outward*recess,ha,hc,y0,y1,"shedwood" if hole["kind"] == "door" else "dark")
		_face_trim(b,sideways,at+outward*0.045,ha,hc,y0,y1)
		if hole["kind"] == "window":
			_face_piece(b,sideways,at-outward*0.045,ha+0.035,hc-0.035,y1-0.25,y1-0.04,"fabric")
			_face_piece(b,sideways,at-outward*0.02,ha+0.025,hc-0.025,y0+0.025,y1-0.025,"glass")
			_face_piece(b,sideways,at+outward*0.055,(ha+hc)*0.5-0.022,(ha+hc)*0.5+0.022,y0,y1,"trim")
			_face_piece(b,sideways,at+outward*0.06,ha-0.11,hc+0.11,y0-0.08,y0-0.03,"tin")
		else:
			_face_piece(b,sideways,at-outward*(recess-0.04),hc-0.13,hc-0.08,y0+1.00,y0+1.11,"metal")
		cursor = hc
	_face_volume(b,sideways,at-outward*PL_WALL,at,cursor,float(spans[1]),PL_PLINTH,eave,key)
	var porch := porch_rect(hs,face)
	_shell(b,porch.position.x,porch.end.x,0.0,0.20,porch.position.y,porch.end.y,"boards",0.0)
	return layout

static func _face_volume(b: WorldBuilder, sideways: bool, at0: float, at1: float,
		a: float,c: float,y0: float,y1: float,key: String) -> void:
	if c-a < 0.001 or y1-y0 < 0.001:
		return
	if sideways:
		_shell(b,at0,at1,y0,y1,a,c,key,0.0)
	else:
		_shell(b,a,c,y0,y1,at0,at1,key,0.0)


## Участок: забор по периметру с калиткой на дорогу, дом лицом к ней, крыльцо,
## машина у ворот и обвес. Всё из данных: рисунок один, а участков шестнадцать,
## и второй такой же код был бы вторым местом для ошибки.
static func _plot(b: WorldBuilder, p: Dictionary, out: Dictionary) -> void:
	var px: Array = p["x"]
	var pz: Array = p["z"]
	var x0 := float(px[0])
	var x1 := float(px[1])
	var z0 := float(pz[0])
	var z1 := float(pz[1])
	var id := String(p.get("id", "plot"))
	var face := String(p.get("face", "s"))

	_fence(b, out, x0, x1, z0, z1, face, p.get("wicket", []), id)

	var hs: Dictionary = p.get("house", {})
	if hs.size() > 0:
		var skin_house := b.skin_begin("buildings", "snt", String(p.get("id", "")), "PLOTS")
		_house(b, out, hs, face, id)
		b.skin_end(skin_house)
	RuralDressing.plot_details(b, p)

	# Машина у ворот. Модель ставит data/props.json — единственное место, где
	# модель может появиться; здесь только коробка-заместитель, иначе игрок
	# проходит сквозь неё.
	var car: Dictionary = p.get("car", {})
	if car.size() > 0:
		var cb: Array = VehicleVisuals.world_box(car)
		_shell(b, float(cb[0]) - 0.15, float(cb[1]) + 0.15, 0.005, 0.017,
			float(cb[2]) - 0.15, float(cb[3]) + 0.15, "gravel", 1.8)
		_solid(b, out, float(cb[0]), float(cb[1]), 0.0, VehicleVisuals.dimensions(car).y,
			float(cb[2]), float(cb[3]), id + "-car")

	for e: Variant in p.get("extras", []):
		if e is Dictionary:
			var kind := String(e.get("k", "extra"))
			var authored := kind in ["woodpile", "barrel", "bench", "greenhouse", "repair", "line"]
			var reserved := (id == "p07" and kind == "barrel") or (id == "p09" and kind == "bench")
			var skin_extra := b.skin_begin("interiors", "environment", "extra-" + id + "-" + kind) if authored and not reserved else \
				b.skin_begin("interiors", "snt", String(e.get("id", "")), id + "-" + kind)
			_extra(b, out, e, id)
			b.skin_end(skin_extra)


static func _fence(b: WorldBuilder, out: Dictionary, x0: float, x1: float,
		z0: float, z1: float, face: String, wicket: Array, id: String) -> void:
	var h := PL_FENCE_H
	# Четыре прясла. На стороне лица — разрыв под калитку.
	var runs: Array = []
	if face == "s":
		runs = [[x0, x1, z0, z0 + 0.08, false], [x0, x0 + 0.08, z0, z1, false],
			[x1 - 0.08, x1, z0, z1, false], [x0, x1, z1 - 0.08, z1, true]]
	elif face == "n":
		runs = [[x0, x1, z0, z0 + 0.08, true], [x0, x0 + 0.08, z0, z1, false],
			[x1 - 0.08, x1, z0, z1, false], [x0, x1, z1 - 0.08, z1, false]]
	elif face == "w":
		runs = [[x0, x1, z0, z0 + 0.08, false], [x0, x0 + 0.08, z0, z1, true],
			[x1 - 0.08, x1, z0, z1, false], [x0, x1, z1 - 0.08, z1, false]]
	else:
		runs = [[x0, x1, z0, z0 + 0.08, false], [x0, x0 + 0.08, z0, z1, false],
			[x1 - 0.08, x1, z0, z1, true], [x0, x1, z1 - 0.08, z1, false]]

	var n := 0
	for r: Array in runs:
		var a := float(r[0])
		var c := float(r[1])
		var p := float(r[2])
		var q := float(r[3])
		var gated := bool(r[4]) and wicket.size() == 2
		var horiz := (c - a) > (q - p)
		var segs: Array = [[a, c, p, q]]
		if gated:
			var g0 := float(wicket[0])
			var g1 := float(wicket[1])
			segs = [[a, g0, p, q], [g1, c, p, q]] if horiz \
				else [[a, c, p, g0], [a, c, g1, q]]
		for s: Array in segs:
			var sa := float(s[0])
			var sc := float(s[1])
			var sp := float(s[2])
			var sq := float(s[3])
			if sc - sa < 0.05 or sq - sp < 0.02:
				continue
			_shell(b, sa, sc, 0.12, h, sp, sq, "boards", 0.0)
			for rail: float in [0.40,0.90]:
				_shell(b,sa-0.012,sc+0.012,rail,rail+0.075,sp-0.025,sq+0.025,"boards",0.0)
			for edge: float in [0.07,0.93]:
				var post_x := lerpf(sa,sc,edge) if horiz else (sa+sc)*0.5
				var post_z := (sp+sq)*0.5 if horiz else lerpf(sp,sq,edge)
				_shell(b,post_x-0.055,post_x+0.055,0.0,h+0.11,post_z-0.055,post_z+0.055,"boards",0.0)
			_solid(b, out, sa, sc, 0.0, h, sp, sq, "%s-fence-%d" % [id, n])
			n += 1


static func _house(b: WorldBuilder, out: Dictionary, hs: Dictionary, face: String,
		id: String) -> void:
	var hx: Array = hs["x"]
	var hz: Array = hs["z"]
	var x0 := float(hx[0])
	var x1 := float(hx[1])
	var z0 := float(hz[0])
	var z1 := float(hz[1])
	var eave := float(hs.get("eave", 2.75))
	var ridge := float(hs.get("ridge", 3.95))
	var variant := RuralDressing.house_variant(id)
	ridge += float(variant-1)*0.12
	var wall_material := RuralDressing.wall_material(String(hs.get("family", "log" if id == "p01" else "")))
	var kind := String(hs.get("kind", "locked"))
	# Лицо смотрит на дорогу — на ту же сторону, что калитка.
	var fz := z1 if face == "s" else z0
	var open_front := kind == "veranda"

	# Дом СПЛОШНОЙ: внутрь заперто. Двадцать домов с интерьерами — это
	# двадцать помещений, которых игрок не увидит, и двадцать раз по кадру.
	# Веранда — исключение и потому одна.
	if open_front:
		# Веранда: передняя треть открыта, туда заходят.
		var vz := fz + (-1.9 if face == "s" else 1.9)
		var wall_z0: float = minf(z0, vz)
		var wall_z1: float = maxf(z0, vz) if face == "s" else maxf(vz, z1)
		if face == "s":
			wall_z0 = z0
			wall_z1 = vz
		else:
			wall_z0 = vz
			wall_z1 = z1
		_shell(b, x0, x1, PL_PLINTH, eave, wall_z0, wall_z1, wall_material, 2.6)
		_solid(b, out, x0, x1, 0.0, eave, wall_z0, wall_z1, id + "-house")
		# Пол веранды и её стойки. Стены нет — в этом вся веранда.
		var v0: float = minf(vz, fz)
		var v1: float = maxf(vz, fz)
		_shell(b, x0, x1, PL_PLINTH - 0.06, PL_PLINTH, v0, v1, "boards", 1.2)
		_solid(b, out, x0, x1, 0.0, PL_PLINTH, v0, v1, id + "-veranda")
		for sx: float in [x0 + 0.12, (x0 + x1) * 0.5, x1 - 0.12]:
			_shell(b, sx - 0.06, sx + 0.06, PL_PLINTH, eave, fz - 0.14, fz - 0.02,
				"boards", 1.4)
		# Перила веранды по бокам.
		for sx: float in [x0 + 0.06, x1 - 0.06]:
			_shell(b, sx - 0.05, sx + 0.05, PL_PLINTH, PL_PLINTH + 0.92, v0, v1,
				"boards", 1.2)
	else:
		var layout := _closed_shell(b, hs, face, id, x0, x1, z0, z1, eave, wall_material)
		out.get_or_add("facades", {})[id] = layout
		_solid(b, out, x0, x1, 0.0, eave, z0, z1, id + "-house")

	_shell(b, x0 - 0.07, x1 + 0.07, 0.0, PL_PLINTH, z0 - 0.07, z1 + 0.07, "plinth", 1.2)

	# Кровля: два ската и два фронтона. Оба мягкие — иначе паритет.
	var rz := (z0 + z1) * 0.5 + float(variant-1)*minf(0.20,(z1-z0)*0.04)
	if String(hs.get("family", "")) == "mansard":
		_mansard_roof(b, x0, x1, z0, z1, eave, ridge, wall_material, variant)
	elif String(hs.get("family", "")) == "garden":
		_garden_roof(b, x0, x1, z0, z1, eave, ridge, wall_material)
	else:
		_slope_soft(b, x0 - 0.34, x1 + 0.34, z0 - 0.34, rz, eave, ridge, "neighbourroof", 0.12)
		_slope_soft(b, x0 - 0.34, x1 + 0.34, rz, z1 + 0.34, ridge, eave, "neighbourroof", 0.12)
		for sx: float in [x0 + 0.04, x1 - 0.04]:
			_gable_soft(b, sx, z0, rz, z1, eave, ridge, wall_material)

	# Крыльцо рассчитывается тем же layout, который строит видимые проёмы.
	if not open_front:
		var porch_area := porch_rect(hs, face)
		_solid(b, out, porch_area.position.x, porch_area.end.x, 0.0, 0.20,
			porch_area.position.y, porch_area.end.y, id + "-porch")


static func _face_piece(b: WorldBuilder, sideways: bool, at: float, a: float,
		c: float, y0: float, y1: float, key: String) -> void:
	if sideways:
		_shell(b, at - 0.018, at + 0.018, y0, y1, a, c, key)
	else:
		_shell(b, a, c, y0, y1, at - 0.018, at + 0.018, key)


static func _face_trim(b: WorldBuilder, sideways: bool, at: float, a: float,
		c: float, y0: float, y1: float) -> void:
	_face_piece(b, sideways, at, a - 0.08, a + 0.01, y0 - 0.05, y1 + 0.08, "trim")
	_face_piece(b, sideways, at, c - 0.01, c + 0.08, y0 - 0.05, y1 + 0.08, "trim")
	_face_piece(b, sideways, at, a - 0.08, c + 0.08, y1, y1 + 0.08, "trim")
	_face_piece(b, sideways, at, a - 0.08, c + 0.08, y0 - 0.05, y0, "trim")


static func _trim(b: WorldBuilder, a: float, c: float, y0: float, y1: float,
		face_z: float) -> void:
	_shell(b, a - 0.09, a + 0.01, y0, y1 + 0.09, face_z - 0.04, face_z + 0.04, "trim", 0.0)
	_shell(b, c - 0.01, c + 0.09, y0, y1 + 0.09, face_z - 0.04, face_z + 0.04, "trim", 0.0)
	_shell(b, a - 0.09, c + 0.09, y1, y1 + 0.09, face_z - 0.04, face_z + 0.04, "trim", 0.0)


## Обвес участка: поленница, бочка под водосток, теплица, бельевая верёвка,
## скамья. Всё коробками в общие бакеты — ни одного нового вызова отрисовки.
static func _extra(b: WorldBuilder, out: Dictionary, e: Dictionary, id: String) -> void:
	var kind := String(e.get("k", ""))
	var at: Array = e.get("at", [])
	if at.size() != 2:
		return
	var x := float(at[0])
	var z := float(at[1])
	match kind:
		"woodpile":
			for k in 5:
				var y := 0.11 * float(k)
				_shell(b, x - 1.05, x + 1.05, y, y + 0.10, z - 0.24, z + 0.24,
					"boards", 1.4)
			_solid(b, out, x - 1.05, x + 1.05, 0.0, 0.58, z - 0.26, z + 0.26,
				id + "-woodpile")
		"barrel":
			# Полую бочку p07 и съёмную крышку рисует EverydayWorld.
			if id != "p07" and not _detailed_extra(b,"waterBarrel",id+"-barrel",Vector3(x,0,z)):
				_shell(b, x - 0.34, x + 0.34, 0.0, 0.86, z - 0.34, z + 0.34, "metal", 0.0)
				_shell(b, x - 0.30, x + 0.30, 0.86, 0.89, z - 0.30, z + 0.30, "water", 0.0)
			_solid(b, out, x - 0.34, x + 0.34, 0.0, 0.86, z - 0.34, z + 0.34,
				id + "-barrel")
		"greenhouse":
			# Каркас из брусков и полупрозрачные полотна: готовой теплицы
			# в CC0 нет, а собирать её примитивами уже принято (летний душ).
			var w := float(e.get("w", 2.4))
			var dp := float(e.get("d", 3.6))
			for sx: float in [x - w * 0.5, x + w * 0.5]:
				for sz: float in [z - dp * 0.5, z + dp * 0.5]:
					_shell(b, sx - 0.05, sx + 0.05, 0.0, 1.95, sz - 0.05, sz + 0.05,
						"boards", 1.2)
			_shell(b, x - w * 0.5, x + w * 0.5, 1.95, 2.02, z - dp * 0.5, z + dp * 0.5,
				"boards", 1.4)
			for sx2: float in [x - w * 0.5 + 0.05, x + w * 0.5 - 0.05]:
				_shell(b, sx2 - 0.02, sx2 + 0.02, 0.05, 1.95, z - dp * 0.5, z + dp * 0.5,
					"glass", 1.2)
			for sz2: float in [z - dp * 0.5 + 0.05, z + dp * 0.5 - 0.05]:
				_shell(b, x - w * 0.5, x + w * 0.5, 0.05, 1.95, sz2 - 0.02, sz2 + 0.02,
					"glass", 1.2)
			_solid(b, out, x - w * 0.5, x + w * 0.5, 0.0, 2.02,
				z - dp * 0.5, z + dp * 0.5, id + "-greenhouse")
		"line":
			# Бельевая верёвка между двумя столбиками. Твёрдости у неё нет:
			# верёвка, об которую спотыкаются, — это не верёвка.
			var ln := float(e.get("w", 3.4))
			for sx3: float in [x - ln * 0.5, x + ln * 0.5]:
				_shell(b, sx3 - 0.05, sx3 + 0.05, 0.0, 1.72, z - 0.05, z + 0.05,
					"boards", 1.0)
			_shell(b, x - ln * 0.5, x + ln * 0.5, 1.62, 1.65, z - 0.01, z + 0.01,
				"metal", 0.0)
			for k2 in 3:
				var cx := x - ln * 0.32 + ln * 0.32 * float(k2)
				_shell(b, cx - 0.22, cx + 0.22, 1.62 - 0.56 - 0.07 * float(k2), 1.62,
					z - 0.02, z + 0.02, "fabric", 0.9)
		"repair":
			for k in 4:
				b._emit_rot_box("boards", Vector3(x - 0.12, 0.58, z - 0.35 + float(k) * 0.22),
					Vector3(0.035, 0.60, 0.065), Basis(Vector3.FORWARD, 0.14), 1, 1, 1)
		"bench":
			if not _detailed_extra(b,"bench",id+"-bench",Vector3(x,0,z)):
				_shell(b, x - 0.78, x + 0.78, 0.40, 0.46, z - 0.20, z + 0.20, "boards", 0.0)
				for sx4: float in [x - 0.66, x + 0.66]:
					_shell(b, sx4 - 0.05, sx4 + 0.05, 0.0, 0.40, z - 0.16, z + 0.16,
						"boards", 0.0)
			_solid(b, out, x - 0.78, x + 0.78, 0.0, 0.46, z - 0.22, z + 0.22,
				id + "-bench")

static func _detailed_extra(b: WorldBuilder, kind: String, id: String, at: Vector3) -> bool:
	var holder := Node3D.new()
	if not preload("res://src/detailed_props.gd").build(b.mats,{"make":kind},holder):
		holder.free()
		return false
	for child: MeshInstance3D in holder.get_children():
		var key := String(child.get_meta("rural_bucket","boards"))
		if kind == "waterBarrel":
			key = "water" if child.name == "detail-2" else "metal"
		# Сохраняем shadow OFF исходной детали в пространственном visual bucket.
		b.append_mesh("visual:"+key,child.mesh,Transform3D(Basis.IDENTITY,at)*child.transform)
	var marker := Node3D.new()
	marker.name = "rural-extra:"+id
	marker.position = at
	marker.set_meta("detailed_prop",kind)
	b.decor[marker.name] = marker
	holder.free()
	return true


# ------------------------------------------------------- места с нутром ----

## Три места, куда заходят. Больше не надо: остальные двадцать домов заперты,
## и это не экономия, а правда — в августе восемьдесят восьмого на этих
## участках уже никого.
static func _landmarks(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	for m: Variant in d.get("INSIDE", []):
		if not (m is Dictionary):
			continue
		var s: Dictionary = m
		var sx: Array = s["x"]
		var sz: Array = s["z"]
		var x0 := float(sx[0])
		var x1 := float(sx[1])
		var z0 := float(sz[0])
		var z1 := float(sz[1])
		var h := float(s.get("y", 2.5))
		var t := float(s.get("wall", 0.24))
		var dr: Array = s["door"]
		var id := String(s.get("id", "inside"))
		var skin_inside := b.skin_begin("buildings", "snt", String(s.get("id", "")), "INSIDE")
		var mat := String(s.get("mat", "boards"))

		_hollow(b, out, x0, x1, h, z0, z1, t, float(dr[0]), float(dr[1]),
			float(s.get("doorTop", 2.0)), id)
		# Видимая шкура тем же рисунком: четыре стены с вырезанным проёмом.
		_shell(b, x0, x1, 0.0, h, z0, z0 + t, mat, 1.8)
		_shell(b, x0, x0 + t, 0.0, h, z0 + t, z1 - t, mat, 1.8)
		_shell(b, x1 - t, x1, 0.0, h, z0 + t, z1 - t, mat, 1.8)
		_shell(b, x0, float(dr[0]), 0.0, h, z1 - t, z1, mat, 1.8)
		if id == "snt-booth":
			# Три полосы вокруг стекла; физическая стена остаётся сплошной.
			_shell(b, float(dr[1]), 7.77, 0.0, h, z1 - t, z1, mat, 1.8)
			_shell(b, 8.37, x1, 0.0, h, z1 - t, z1, mat, 1.8)
			_shell(b, 7.77, 8.37, 0.0, 0.8, z1 - t, z1, mat, 1.8)
			_shell(b, 7.77, 8.37, 1.9, h, z1 - t, z1, mat, 1.8)
			_shell(b, 7.78, 8.36, 0.81, 1.89, z1 - 0.10, z1 - 0.08, "glass")
			_face_trim(b, false, z1 + 0.025, 7.77, 8.37, 0.80, 1.90)
		else:
			_shell(b, float(dr[1]), x1, 0.0, h, z1 - t, z1, mat, 1.8)
		_shell(b, float(dr[0]), float(dr[1]), float(s.get("doorTop", 2.0)), h,
			z1 - t, z1, mat, 1.8)
		# Пол и потолок.
		_shell(b, x0 + t, x1 - t, 0.0, 0.05, z0 + t, z1 - t, "boards", 1.4)
		_solid(b, out, x0 + t, x1 - t, -0.05, 0.05, z0 + t, z1 - t, id + "-floor")
		_shell(b, x0 + t, x1 - t, h - 0.08, h, z0 + t, z1 - t, "boards", 1.4)
		# Кровля.
		var rz := (z0 + z1) * 0.5
		if bool(s.get("flat", false)):
			_shell(b, x0 - 0.22, x1 + 0.22, h, h + 0.12, z0 - 0.22, z1 + 0.22,
				"tin", 1.4)
		else:
			_slope_soft(b, x0 - 0.3, x1 + 0.3, z0 - 0.3, rz, h, h + 0.9, "tin", 0.10)
			_slope_soft(b, x0 - 0.3, x1 + 0.3, rz, z1 + 0.3, h + 0.9, h, "tin", 0.10)
		b.skin_end(skin_inside)


# ------------------------------------------------------------- примитивы ----

# Копии из outskirts_world.gd — намеренно, а не общий модуль: правило
# «видимое мягко, твёрдое в оверлей» обязано читаться в файле, который его
# применяет. Общий хелпер прячет его на два файла вглубь, и первая же правка
# «на минутку» вернёт коробку в SET_STATIC.
static func _hollow(b: WorldBuilder, out: Dictionary, x0: float, x1: float,
		y1: float, z0: float, z1: float, t: float,
		d0: float, d1: float, dtop: float, id := "") -> void:
	_solid(b, out, x0, x1, 0.0, y1, z0, z0 + t, id + "-n")
	_solid(b, out, x0, x0 + t, 0.0, y1, z0 + t, z1 - t, id + "-w")
	_solid(b, out, x1 - t, x1, 0.0, y1, z0 + t, z1 - t, id + "-e")
	_solid(b, out, x0, d0, 0.0, y1, z1 - t, z1, id + "-s0")
	_solid(b, out, d1, x1, 0.0, y1, z1 - t, z1, id + "-s1")
	_solid(b, out, d0, d1, dtop, y1, z1 - t, z1, id + "-lintel")


static func _slope_soft(b: WorldBuilder, x0: float, x1: float, z0: float, z1: float,
		ya: float, yb: float, key: String, t: float) -> void:
	b._slope(x0, x1, z0, z1, ya, yb, key, t, false)


static func _gable_soft(b: WorldBuilder, x: float, z0: float, zr: float, z1: float,
		y_eave: float, y_ridge: float, key: String, t := 0.12) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var vertices := [Vector3(x-t*0.5,y_eave,z0),Vector3(x-t*0.5,y_ridge,zr),Vector3(x-t*0.5,y_eave,z1),
		Vector3(x+t*0.5,y_eave,z0),Vector3(x+t*0.5,y_ridge,zr),Vector3(x+t*0.5,y_eave,z1)]
	for tri: Array in [[0,2,1],[3,4,5],[0,1,4],[0,4,3],[1,2,5],[1,5,4],[2,0,3],[2,3,5]]:
		var a: Vector3 = vertices[tri[0]]
		var c: Vector3 = vertices[tri[1]]
		var d: Vector3 = vertices[tri[2]]
		var normal := (c-a).cross(d-a).normalized()
		for v: Vector3 in [a,c,d]:
			st.set_normal(normal)
			st.set_uv(WorldBuilder.world_uv(v,normal,2.0))
			st.add_vertex(v)
	b.append_mesh(key,st.commit())


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


# Тот же гард по id, что village_world._zones() и outskirts_world._zones().
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

static func _mansard_roof(b: WorldBuilder, x0: float, x1: float, z0: float,
		z1: float, eave: float, ridge: float, wall_mat: String, variant := 1) -> void:
	var middle := (z0 + z1) * 0.5
	var inset := minf(0.72, (z1 - z0) * 0.24)*(1.0+0.10*float(variant-1))
	var shoulder_fraction := 0.76+0.04*float(variant-1)
	var shoulder := lerpf(eave, ridge, shoulder_fraction)
	_slope_soft(b, x0 - 0.34, x1 + 0.34, z0 - 0.34, z0 + inset,
		eave, shoulder, "neighbourroof", 0.12)
	_slope_soft(b, x0 - 0.34, x1 + 0.34, z0 + inset, middle,
		shoulder, ridge, "neighbourroof", 0.12)
	_slope_soft(b, x0 - 0.34, x1 + 0.34, middle, z1 - inset,
		ridge, shoulder, "neighbourroof", 0.12)
	_slope_soft(b, x0 - 0.34, x1 + 0.34, z1 - inset, z1 + 0.34,
		shoulder, eave, "neighbourroof", 0.12)
	for x: float in [x0 + 0.04, x1 - 0.04]:
		for step in 8:
			var q0 := float(step) / 8.0
			var q1 := float(step + 1) / 8.0
			var inset_at := lerpf(0.0, inset, q1 / shoulder_fraction) if q1 <= shoulder_fraction \
				else lerpf(inset, middle - z0, (q1 - shoulder_fraction) / (1.0-shoulder_fraction))
			_shell(b, x - 0.06, x + 0.06, lerpf(eave, ridge, q0),
				lerpf(eave, ridge, q1), z0 + inset_at, z1 - inset_at, wall_mat)

static func _garden_roof(b: WorldBuilder, x0: float, x1: float, z0: float,
		z1: float, eave: float, ridge: float, wall_mat: String) -> void:
	_slope_soft(b, x0 - 0.34, x1 + 0.34, z0 - 0.34, z1 + 0.34,
		ridge, eave, "neighbourroof", 0.12)
	_shell(b, x0, x1, eave, ridge, z0 - 0.04, z0 + 0.04, wall_mat)
	for x: float in [x0 + 0.04, x1 - 0.04]:
		for step in 8:
			var q0 := float(step) / 8.0
			var q1 := float(step + 1) / 8.0
			_shell(b, x - 0.06, x + 0.06, lerpf(eave, ridge, q0),
				lerpf(eave, ridge, q1), z0, lerpf(z1, z0, q1), wall_mat)

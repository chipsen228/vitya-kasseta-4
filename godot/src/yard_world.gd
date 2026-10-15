# Участок с фотографии — оверлей поверх принятого мира (фаза 11).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. Тот же довод, что у street_world.gd, и он машинный:
# world_builder.gd строит участок дословно по данным прототипа, а его коробки
# сверяет tests/test_world_parity.gd — 311 статики, 4 блокера, 83 коллайдера
# реквизита и 3885 треугольников. Эталон снят с браузерного прототипа
# (tools/export_parity.js), новой геометрии в прототипе нет, и снять его заново
# нечем. Значит, ни одна коробка отсюда не имеет права попасть в те три набора.
#
# Правило одно и оно механическое:
#
#   видимое  -> _shell()      = b.box(..., collide = false)
#   твёрдое  -> _solid()      = col.add_box_d(SET_OVERLAY)
#   скат     -> _slope_soft() = b._slope(..., collide = false)
#   фронтон  -> _gable_soft() = свой, ступеньками через _shell()
#
# Прямых вызовов b.box/slab/wall/fence/stairs/rail/roof/_slopeX/_gable здесь
# нет ни одного, и это проверяется грепом на ревью: _slopeX() не имеет
# параметра collide и ВСЕГДА пишет в SET_STATIC, а _gable() зовёт box() без
# collide = false. Один такой вызов — и навграф деда считается по другому дому.
#
# ПЛАТА, НАЗВАННАЯ ВСЛУХ. SET_OVERLAY невидим для навграфа (nav_graph.gd
# выбрасывает всё, кроме пяти принятых слоёв) и для ai.gd — сквозь баню и
# погреб дед прошёл бы насквозь, и ни один существующий тест этого не поймает.
# Поэтому обе постройки стоят СТРОГО вне узлов и рёбер слоя plot, а сам зазор
# меряет tests/test_yard_nav_clear.gd по out["boxes"]. Внутрь бани дед не
# заходит вовсе: его присутствие там делается точками haunt/startle с явными
# координатами, которые навграфа не спрашивают.
#
# УГЛЫ. Стены каждой постройки не перекрываются: торцевые идут на всю длину,
# боковые — только между ними. Две коробки одного материала с совпавшей гранью
# дают дрожащий шов, и увидеть его можно только в игре, зато сразу.
#
# Нет data/yard.json — build() выходит первой строкой, и участок ровно тот,
# что принят в раунде 10. Палитра при этом остаётся: цвет выпущенной геометрии
# уже не отозвать, и это единственная необратимая часть фазы.

class_name YardWorld
extends RefCounted

const DATA := "res://data/yard.json"

static var _cache: Variant = null


## Данные участка или пустой словарь. Кэш на процесс: файл читают и сборка,
## и три теста.
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


## Сборка. Зовётся из WorldBuilder._build_all() сразу за StreetWorld.build():
## к этому моменту и участок, и улица собраны целиком, и обвес ложится поверх.
static func build(b: WorldBuilder) -> Dictionary:
	var d := data()
	if d.is_empty():
		return {}

	var out: Dictionary = {
		"enabled": true,
		"boxes": [],       # AABB всей твёрдой геометрии — для test_yard_nav_clear
		"nodes": {},       # id -> Node3D (квестовые предметы и створки)
		"banya": d.get("BANYA", {}),
		"shed": d.get("SHED", {}),
	}

	var exterior_mark := b.skin_begin("buildings", "site", "HOUSE-exterior-dressing")
	_plinth(b, d.get("PLINTH", {}))
	_casings(b)
	_chimney(b, d.get("CHIMNEY", {}))
	_antenna(b, d.get("ANTENNA", {}))
	b.skin_end(exterior_mark)
	_walks(b, d.get("WALKS", {}))
	_panels(b, d.get("PANELS", {}))
	_forest(b, d.get("FOREST", {}))
	var skin_shed := b.skin_begin("buildings", "yard", String((d.get("SHED", {}) as Dictionary).get("id", "")), "SHED")
	_cellar_shed(b, d.get("SHED", {}), out)
	b.skin_end(skin_shed)
	var skin_banya := b.skin_begin("buildings", "yard", String((d.get("BANYA", {}) as Dictionary).get("id", "")), "BANYA")
	_banya(b, d.get("BANYA", {}), out)
	b.skin_end(skin_banya)
	_wet_steps(b, out)
	_orchard(b, d.get("ORCHARD", {}), out)
	_garden(b, d.get("GARDEN", {}), out)
	_zones(d.get("ZONES", []))
	return out


# ------------------------------------------------------------- примитивы ----

## Видимое. collide зашит в false: это не забывчивость вызывающего, а условие
## паритета, и способа написать иначе здесь нет.
static func _shell(b: WorldBuilder, x0: float, x1: float, y0: float, y1: float,
		z0: float, z1: float, key: String, seg := 0.0) -> void:
	b.box(x0, x1, y0, y1, z0, z1, key, seg, false)


## Твёрдое — только в четвёртый набор. Попутно копит AABB: по нему
## test_yard_nav_clear меряет зазор до узлов и рёбер слоя plot, а
## test_yard_room ходит капсулой сквозь стены.
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
	var first := (b._bucket(key)["v"] as Array).size()
	b._slope(x0, x1, z0, z1, ya, yb, key, t, false)
	if key != "metal":
		return
	# Торец оцинковки рядом с камерой раньше превращался в белую полосу неба.
	# Верх листа остаётся металлом, срез и низ получают тусклую старую жесть.
	var source: Dictionary = b._bucket(key)
	var edge: Dictionary = b._bucket("dark")
	var kept := {"v": [], "n": [], "uv": []}
	var normals: Array = source["n"]
	for i in range(first,(source["v"] as Array).size(),3):
		var normal: Vector3 = normals[i]
		var target: Dictionary = edge if absf(normal.x)>0.9 or normal.y < -0.5 else kept
		for channel: String in ["v","n","uv"]:
			(target[channel] as Array).append_array((source[channel] as Array).slice(i,i+3))
	for channel: String in ["v","n","uv"]:
		(source[channel] as Array).resize(first)
		(source[channel] as Array).append_array(kept[channel])


## Свой фронтон. WorldBuilder._gable() зовёт box() без collide = false и уходит
## в SET_STATIC целиком — брать его нельзя. Ступенек столько же, шесть.
static func _gable_soft(b: WorldBuilder, x: float, z0: float, zr: float, z1: float,
		y_eave: float, y_ridge: float, key: String, t := 0.10) -> void:
	var steps := 6
	for i in steps:
		var q0 := float(i) / steps
		var q1 := float(i + 1) / steps
		var y0 := y_eave + (y_ridge - y_eave) * q0
		var y1 := y_eave + (y_ridge - y_eave) * q1
		var za := z0 + (zr - z0) * q1
		var zb := z1 - (z1 - zr) * q1
		_shell(b, x - t / 2.0, x + t / 2.0, y0, y1, za, zb, key, 1.5)


# ---------------------------------------------------------------- цоколь ----

# Дом стоит на кирпичной забирке (world_builder.ground()), и от ворот она
# читается полосой кладки под красной стеной. На снимке под домом камень,
# поэтому поверх забирки встаёт пояс на 6 см наружу: он же прячет стык грунта
# со стеной, который был виден по всему периметру.
static func _plinth(b: WorldBuilder, d: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var yr: Array = d["y"]
	var t := float(d.get("t", 0.12))
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var y0 := float(yr[0])
	var y1 := float(yr[1])
	_shell(b, x0, x1, y0, y1, z0, z0 + t, "plinth", 1.1)
	_shell(b, x0, x1, y0, y1, z1 - t, z1, "plinth", 1.1)
	_shell(b, x0, x0 + t, y0, y1, z0 + t, z1 - t, "plinth", 1.1)
	_shell(b, x1 - t, x1, y0, y1, z0 + t, z1 - t, "plinth", 1.1)


# ------------------------------------------------------------- наличники ----

# Белые наличники на девятнадцать оконных проёмов наружных стен. Координаты
# берутся из site.json WALLS, а не переписываются числами: подвинут окно —
# наличник поедет за ним, а не останется висеть на стене.
#
# Глубина считается ОТ существующей тёмной обналички (_frame_hole кладёт её на
# t/2 + 0.012): наличник уходит на CASE_OUT дальше и захватывает её лицевую
# кромку губой CASE_LIP. Тёмная коробка целиком оказывается внутри белой, и
# совпадающих плоскостей не остаётся — z-fighting исключён по построению,
# а не «на глаз».
const CASE_OUT := 0.045       # насколько наличник выступает за тёмную обналичку
const CASE_W := 0.09          # ширина доски наличника
const CASE_LIP := 0.008       # губа внутрь проёма: ею накрывается кромка тёмной
const SILL_W := 0.10          # свес подоконника по бокам
const SILL_H := 0.10


static func _casings(b: WorldBuilder) -> void:
	var site := GameData.site()
	for w: Dictionary in site["WALLS"]:
		if String(w.get("mat", "")) != "siding":
			continue
		var a: Array = w["a"]
		var bb: Array = w["b"]
		var horiz := absf(float(bb[0]) - float(a[0])) > absf(float(bb[1]) - float(a[1]))
		var line: float = float(a[1]) if horiz else float(a[0])
		var t := float(w.get("t", 0.12))
		var wy := float(w["y"])
		for hh: Dictionary in w.get("holes", []):
			var ry0 := float(hh.get("y0", 0.0))
			# Дверные проёмы пропускаются: у входной двери своя обналичка и своё
			# крыльцо, а белая доска поперёк порога читалась бы как ступенька.
			if ry0 <= 0.01:
				continue
			var c: float = float(hh["x"]) if horiz else float(hh["z"])
			var half := float(hh["w"]) / 2.0
			_casing(b, horiz, line, t, c - half, c + half, wy + ry0, wy + float(hh["y1"]))


static func _casing(b: WorldBuilder, horiz: bool, line: float, t: float,
		c0: float, c1: float, y0: float, y1: float) -> void:
	var d := t / 2.0 + 0.012 + CASE_OUT
	# Подоконник ниже проёма и чуть глубже щёк: он единственный, на что тут
	# ложится снег, и без свеса его не видно вовсе.
	_band(b, horiz, line, d + 0.015, c0 - SILL_W, c1 + SILL_W, y0 - SILL_H, y0)
	_band(b, horiz, line, d, c0 - CASE_W, c0 + CASE_LIP, y0, y1)
	_band(b, horiz, line, d, c1 - CASE_LIP, c1 + CASE_W, y0, y1)
	_band(b, horiz, line, d, c0 - CASE_W, c1 + CASE_W, y1, y1 + CASE_W)


static func _band(b: WorldBuilder, horiz: bool, line: float, d: float,
		a0: float, a1: float, y0: float, y1: float) -> void:
	if horiz:
		_shell(b, a0, a1, y0, y1, line - d, line + d, "trim", 0.0)
	else:
		_shell(b, line - d, line + d, y0, y1, a0, a1, "trim", 0.0)


# ------------------------------------------------------- труба и антенна ----

static func _chimney(b: WorldBuilder, d: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var yr: Array = d["y"]
	var cap := float(d.get("cap", 0.12))
	_shell(b, float(xr[0]), float(xr[1]), float(yr[0]), float(yr[1]),
		float(zr[0]), float(zr[1]), "brick", 1.4)
	# Оголовок: без него труба кончается срезом и читается как палка.
	_shell(b, float(xr[0]) - 0.08, float(xr[1]) + 0.08, float(yr[1]),
		float(yr[1]) + cap, float(zr[0]) - 0.08, float(zr[1]) + 0.08, "concrete", 1.0)


static func _antenna(b: WorldBuilder, d: Dictionary) -> void:
	if d.is_empty():
		return
	var x := float(d.get("x", -1.0))
	var z := float(d.get("z", 12.9))
	var yr: Array = d["y"]
	var y0 := float(yr[0])
	var y1 := float(yr[1])
	_shell(b, x - 0.03, x + 0.03, y0, y1, z - 0.03, z + 0.03, "metal", 2.0)
	for bar: Variant in d.get("bars", []):
		var y := float(bar)
		var k := 1.0 - (y - y0) / maxf(0.01, y1 - y0)
		var half := 0.35 + 0.55 * k
		_shell(b, x - 0.02, x + 0.02, y, y + 0.025, z - half, z + half, "metal", 1.2)
	# Растяжка к коньку: одна, с северной стороны.
	_shell(b, x - 0.012, x + 0.012, y0, y1 - 0.6, z - 1.4, z - 1.36, "dark", 2.0)


# -------------------------------------------------------------- дорожки ----

# Плитка 30 см. Швы идут по мировой сетке (worldUv), поэтому дорожка от калитки
# и дорожка у бани стыкуются без подрезки, а не расходятся на стыке полос.
# Гравийные и вытоптанные полосы прототипа не удаляются — они уходят под плитку
# с запасом в пять сантиметров.
static func _walks(b: WorldBuilder, d: Dictionary) -> void:
	if d.is_empty():
		return
	var yr: Array = d.get("y", [0.0, 0.06])
	for r: Array in d.get("rects", []):
		if r.size() != 4:
			continue
		_shell(b, float(r[0]), float(r[1]), float(yr[0]), float(yr[1]),
			float(r[2]), float(r[3]), "walkway", 1.2)


# --------------------------------------------------------------- заборы ----

# Профнастил по западной, восточной и задней сторонам. Сам забор и его коллизия
# принадлежат world_builder.fence() и не трогаются ни на байт: здесь только
# непрозрачная обшивка на 6 см внутрь плоскости, столбы и конёк-планка.
static func _panels(b: WorldBuilder, d: Dictionary) -> void:
	if d.is_empty():
		return
	var t := float(d.get("t", 0.06))
	var inset := float(d.get("inset", 0.06))
	var h := float(d.get("h", 1.46))
	var step := float(d.get("post", 2.5))
	var pw := float(d.get("postW", 0.08))
	var cap := float(d.get("capH", 0.05))

	for s: Dictionary in d.get("sides", []):
		var axis := String(s.get("axis", "x"))
		var line := float(s["line"])
		var inward := float(s.get("inward", 1.0))
		var a0 := float(s["from"])
		var a1 := float(s["to"])
		var lo := minf(line + inward * inset, line + inward * (inset + t))
		var hi := maxf(line + inward * inset, line + inward * (inset + t))
		# Столбы стоят с внутренней стороны листа: снаружи забор обязан читаться
		# сплошным, иначе профнастил превращается в штакетник пошире.
		var q0 := hi if inward > 0.0 else lo - pw
		var q1 := hi + pw if inward > 0.0 else lo
		if axis == "x":
			_shell(b, lo, hi, 0.0, h, a0, a1, "profile", 0.0)
			_shell(b, lo - 0.02, hi + 0.02, h, h + cap, a0, a1, "metal", 1.2)
		else:
			_shell(b, a0, a1, 0.0, h, lo, hi, "profile", 0.0)
			_shell(b, a0, a1, h, h + cap, lo - 0.02, hi + 0.02, "metal", 1.2)

		var n := maxi(1, int((a1 - a0) / step))
		for i in n + 1:
			var a := a0 + (a1 - a0) * float(i) / float(n)
			if axis == "x":
				_shell(b, q0, q1, 0.0, h + cap, a - pw / 2.0, a + pw / 2.0, "profile", 1.0)
			else:
				_shell(b, a - pw / 2.0, a + pw / 2.0, 0.0, h + cap, q0, q1, "profile", 1.0)


# ------------------------------------------------------------------ лес ----

# Хвойный лес за задним забором. Шестигранный ствол и два конических яруса
# складываются в общий мировой MultiMesh.
# Высоты гуляют по синусу, а не по randf — сборка мира обязана быть
# повторяемой, иначе два запуска дают разные картинки в одном кадре.
static func _forest(b: WorldBuilder, d: Dictionary) -> void:
	if d.is_empty():
		return
	var n := int(d.get("n", 26))
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var hr: Array = d["h"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var lo := float(hr[0])
	var hi := float(hr[1])

	# Газонный фартук: за забором грунт лежит на −0.32, и без него от бани
	# виден уступ в тридцать два сантиметра ровно по линии леса.
	var ap: Array = d.get("apron", [])
	if ap.size() == 4:
		_shell(b, float(ap[0]), float(ap[1]), -0.35, 0.0, float(ap[2]), float(ap[3]),
			"grass", 3.8)

	var trees: Array = []
	for i in n:
		var x := x0 + (x1 - x0) * (float(i) + 0.5) / float(n)
		var k := 0.5 + 0.5 * sin(float(i) * 1.9)
		var z := z0 + (z1 - z0) * (0.2 + 0.6 * (0.5 + 0.5 * sin(float(i) * 0.7)))
		var th := lo + (hi - lo) * k
		# Полуширина кроны меньше шага по x: между ёлками обязано просвечивать
		# небо. Сплошной стеной лес перестаёт быть лесом и становится краем
		# карты — это и было первым, что показали снимки.
		var w := 0.62 + 0.30 * (1.0 - k)
		trees.append({"x": x, "z": z, "h": th, "w": w, "trunk": 0.11})
	StreetWorld.add_low_poly_trees(b, "yard-forest", trees)


# --------------------------------------------------------- погреб-гараж ----

# Низкая красная пристройка слева от ворот. Дверь на восток: игрок видит её
# сразу, как вошёл, и она же первая постройка, до которой он дойдёт.
static func _cellar_shed(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var xr: Array = d["x"]
	var zr: Array = d["z"]
	var x0 := float(xr[0])
	var x1 := float(xr[1])
	var z0 := float(zr[0])
	var z1 := float(zr[1])
	var t := float(d.get("wall", 0.16))
	var fl := float(d.get("floor", 0.10))
	var eave := float(d.get("eave", 2.20))
	var ridge := float(d.get("ridge", 2.85))
	var rz := float(d.get("ridgeZ", (z0 + z1) / 2.0))
	var dr: Array = d.get("door", [1.85, 2.75])
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	var dtop := float(d.get("doorTop", 1.98))
	var cr: Array = d.get("ceil", [2.02, 2.14])
	var c0 := float(cr[0])
	var c1 := float(cr[1])

	# --- твёрдое ---
	_solid(b, out, x0, x1, 0.0, fl, z0, z1)                        # пол
	_solid(b, out, x0, x1, fl, eave, z0, z0 + t)                   # север
	_solid(b, out, x0, x1, fl, eave, z1 - t, z1)                   # юг
	_solid(b, out, x0, x0 + t, fl, eave, z0 + t, z1 - t)           # запад
	_solid(b, out, x1 - t, x1, fl, eave, z0 + t, d0)               # восток до проёма
	_solid(b, out, x1 - t, x1, fl, eave, d1, z1 - t)               # восток после
	_solid(b, out, x1 - t, x1, dtop, eave, d0, d1)                 # перемычка
	_solid(b, out, x0 + t, x1 - t, c0, c1, z0 + t, z1 - t)         # потолок

	# --- видимое ---
	_shell(b, x0 - 0.06, x1 + 0.06, 0.0, fl, z0 - 0.06, z1 + 0.06, "plinth", 1.1)
	_shell(b, x0, x1, fl, eave, z0, z0 + t, "siding", 0.0)
	_shell(b, x0, x1, fl, eave, z1 - t, z1, "siding", 0.0)
	_shell(b, x0, x0 + t, fl, eave, z0 + t, z1 - t, "siding", 0.0)
	_shell(b, x1 - t, x1, fl, eave, z0 + t, d0, "siding", 0.0)
	_shell(b, x1 - t, x1, fl, eave, d1, z1 - t, "siding", 0.0)
	_shell(b, x1 - t, x1, dtop, eave, d0, d1, "siding", 0.0)
	_shell(b, x0 + t, x1 - t, c0, c1, z0 + t, z1 - t, "boards", 1.4)
	_shell(b, x0 + t, x1 - t, fl - 0.02, fl + 0.006, z0 + t, z1 - t, "concrete", 1.2)
	# Обналичка проёма — белая, как на окнах дома.
	_shell(b, x1 - 0.02, x1 + 0.07, fl, dtop + 0.09, d0 - 0.09, d0 + 0.01, "trim", 0.0)
	_shell(b, x1 - 0.02, x1 + 0.07, fl, dtop + 0.09, d1 - 0.01, d1 + 0.09, "trim", 0.0)
	_shell(b, x1 - 0.02, x1 + 0.07, dtop, dtop + 0.09, d0 - 0.09, d1 + 0.09, "trim", 0.0)

	# Кровля: два ската и два фронтона, свес 0.3 по кругу.
	_slope_soft(b, x0 - 0.30, x1 + 0.30, z0 - 0.30, rz, eave, ridge, "roof", 0.12)
	_slope_soft(b, x0 - 0.30, x1 + 0.30, rz, z1 + 0.30, ridge, eave, "roof", 0.12)
	_gable_soft(b, x0 + 0.05, z0, rz, z1, eave, ridge, "siding")
	_gable_soft(b, x1 - 0.05, z0, rz, z1, eave, ridge, "siding")

	# Створка. Петля на северной кромке проёма, полотно поворотом группы —
	# ровно как у двери правления. Коробка полотна живёт в четвёртом наборе
	# под своим именем, и гасить её нужно там же (col.set_blocker_active).
	var leaf := Node3D.new()
	leaf.name = "door-cellar-shed"
	var mi := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, dtop - fl - 0.04, d1 - d0 - 0.04)
	bm.material = b.mats.get_mat("shedwood")
	mi.mesh = bm
	mi.position = Vector3(0.0, (dtop - fl) / 2.0, (d1 - d0) / 2.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	leaf.add_child(mi)
	var hasp := MeshInstance3D.new()
	var hm := BoxMesh.new()
	hm.size = Vector3(0.05, 0.11, 0.09)
	hm.material = b.mats.flat(0x7d8288, true)
	hasp.mesh = hm
	hasp.name = "lock"
	hasp.position = Vector3(0.04, (dtop - fl) * 0.52, d1 - d0 - 0.14)
	hasp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	leaf.add_child(hasp)
	leaf.position = Vector3(x1 - 0.02, fl, d0)
	b.decor["yard-door-cellar-shed"] = leaf
	(out["nodes"] as Dictionary)["cellar-shed-door"] = leaf
	_solid(b, out, x1 - 0.08, x1 + 0.04, fl, dtop, d0, d1, "door-cellar-shed")

	# --- начинка ---
	# Верстак: керосинке надо на чём-то стоять, а полкам с банками — во что
	# упираться.
	_shell(b, x0 + t, x0 + t + 0.62, fl, fl + 0.84, z1 - t - 0.95, z1 - t, "boards", 1.0)
	_solid(b, out, x0 + t, x0 + t + 0.62, fl, fl + 0.84, z1 - t - 0.95, z1 - t)
	var nodes: Dictionary = out["nodes"]
	nodes["cellar-shed-jars"] = _jars(b, Vector3(x0 + t + 0.30, fl, z0 + t + 0.30))
	nodes["cellar-shed-rope"] = _rope(b, Vector3((x0 + x1) / 2.0, fl + 1.62,
		(z0 + z1) / 2.0), x1 - x0 - 2.0 * t - 0.3)
	nodes["cellar-shed-lantern"] = _lantern(b,
		Vector3(x0 + t + 0.30, fl + 0.98, z1 - t - 0.48))


# ---------------------------------------------------------------- баня ----

# Отдельная постройка со своим интерьером — решение Петра. Стоит в дальнем углу
# за огородом, вход с севера, лицом к дому: из окна общей комнаты её видно,
# и дым из трубы читается раньше, чем игрок туда дойдёт.
static func _banya(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
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
	var eave := float(d.get("eave", 2.35))
	var ridge := float(d.get("ridge", 3.15))
	var rz := float(d.get("ridgeZ", (z0 + z1) / 2.0))
	var dr: Array = d["door"]
	var d0 := float(dr[0])
	var d1 := float(dr[1])
	var dtop := float(d.get("doorTop", 1.95))
	var sp: Array = d["split"]
	var s0 := float(sp[0])
	var s1 := float(sp[1])
	var ir: Array = d["inner"]
	var i0 := float(ir[0])
	var i1 := float(ir[1])
	var itop := float(d.get("innerTop", 1.75))
	var cr: Array = d["ceil"]
	var c0 := float(cr[0])
	var c1 := float(cr[1])
	var ww: Array = d["winW"]
	var we: Array = d["winE"]
	var st: Array = d["stove"]
	var bn: Array = d["bench"]
	var sl: Array = d["shelfLow"]
	var sh: Array = d["shelfHigh"]

	# --- твёрдое ---
	_solid(b, out, x0, x1, 0.0, fl, z0, z1)                        # пол
	_solid(b, out, x0, d0, fl, eave, z0, z0 + t)                   # север слева
	_solid(b, out, d1, x1, fl, eave, z0, z0 + t)                   # север справа
	_solid(b, out, d0, d1, dtop, eave, z0, z0 + t)                 # перемычка входа
	_solid(b, out, x0, x1, fl, eave, z1 - t, z1)                   # юг
	_wall_with_window(b, out, x0, x0 + t, fl, eave, z0 + t, z1 - t,
		float(ww[0]), float(ww[1]), float(ww[2]), float(ww[3]))    # запад с окошком
	_wall_with_window(b, out, x1 - t, x1, fl, eave, z0 + t, z1 - t,
		float(we[0]), float(we[1]), float(we[2]), float(we[3]))    # восток с окошком
	_solid(b, out, x0 + t, i0, fl, eave, s0, s1)                   # перегородка
	_solid(b, out, i1, x1 - t, fl, eave, s0, s1)
	_solid(b, out, i0, i1, itop, eave, s0, s1)
	_solid(b, out, x0 + t, x1 - t, c0, c1, z0 + t, z1 - t)         # потолок
	_solid(b, out, float(st[0]), float(st[1]), fl, fl + float(st[4]),
		float(st[2]), float(st[3]))                                # печь-каменка
	_solid(b, out, float(bn[0]), float(bn[1]), fl, float(bn[4]),
		float(bn[2]), float(bn[3]))                                # лавка
	_solid(b, out, float(sl[0]), float(sl[1]), fl, float(sl[4]),
		float(sl[2]), float(sl[3]))                                # полок нижний
	_solid(b, out, float(sh[0]), float(sh[1]), float(sl[4]), float(sh[4]),
		float(sh[2]), float(sh[3]))                                # полок верхний

	# --- видимое ---
	_shell(b, x0 - 0.05, x1 + 0.05, 0.0, fl, z0 - 0.05, z1 + 0.05, "plinth", 1.0)
	_shell(b, x0, d0, fl, eave, z0, z0 + t, "log", 0.0)
	_shell(b, d1, x1, fl, eave, z0, z0 + t, "log", 0.0)
	_shell(b, d0, d1, dtop, eave, z0, z0 + t, "log", 0.0)
	_shell(b, x0, x1, fl, eave, z1 - t, z1, "log", 0.0)
	_wall_skin(b, x0, x0 + t, fl, eave, z0 + t, z1 - t,
		float(ww[0]), float(ww[1]), float(ww[2]), float(ww[3]), "log")
	_wall_skin(b, x1 - t, x1, fl, eave, z0 + t, z1 - t,
		float(we[0]), float(we[1]), float(we[2]), float(we[3]), "log")
	_shell(b, x0 + t, i0, fl, eave, s0, s1, "boards", 0.0)
	_shell(b, i1, x1 - t, fl, eave, s0, s1, "boards", 0.0)
	_shell(b, i0, i1, itop, eave, s0, s1, "boards", 0.0)
	_shell(b, x0 + t, x1 - t, c0, c1, z0 + t, z1 - t, "boards", 1.4)
	_shell(b, x0 + t, x1 - t, fl - 0.02, fl + 0.006, z0 + t, z1 - t, "boards", 1.2)
	# Белая обналичка входа — та же, что на окнах дома.
	_shell(b, d0 - 0.09, d0 + 0.01, fl, dtop + 0.09, z0 - 0.03, z0 + t + 0.02, "trim", 0.0)
	_shell(b, d1 - 0.01, d1 + 0.09, fl, dtop + 0.09, z0 - 0.03, z0 + t + 0.02, "trim", 0.0)
	_shell(b, d0 - 0.09, d1 + 0.09, dtop, dtop + 0.09, z0 - 0.03, z0 + t + 0.02, "trim", 0.0)

	# Венцы: двадцать выпусков по углам. Это и превращает коробку в сруб —
	# без них баня читается щитовой будкой, как всё остальное на участке.
	_crowns(b, x0, x1, z0, z1, t, fl, eave)

	# Печь, полки, лавка.
	_shell(b, float(st[0]), float(st[1]), fl, fl + float(st[4]),
		float(st[2]), float(st[3]), "brick", 1.0)
	_shell(b, float(st[0]) + 0.08, float(st[1]) - 0.08, fl + float(st[4]),
		fl + float(st[4]) + 0.12, float(st[2]) + 0.08, float(st[3]) - 0.08, "dark", 1.0)
	var sx := (float(st[0]) + float(st[1])) / 2.0
	var sz := (float(st[2]) + float(st[3])) / 2.0
	_shell(b, sx - 0.13, sx + 0.13, fl + float(st[4]) + 0.12, ridge + 0.75,
		sz - 0.13, sz + 0.13, "metal", 1.6)
	_shell(b, float(bn[0]), float(bn[1]), float(bn[4]), float(bn[4]) + 0.055,
		float(bn[2]), float(bn[3]), "boards", 0.8)
	_shell(b, float(sl[0]), float(sl[1]), float(sl[4]), float(sl[4]) + 0.055,
		float(sl[2]), float(sl[3]), "boards", 0.8)
	_shell(b, float(sh[0]), float(sh[1]), float(sh[4]), float(sh[4]) + 0.055,
		float(sh[2]), float(sh[3]), "boards", 0.8)

	# Кровля — оцинковка, а не синее железо: баню крыли тем, что осталось.
	_slope_soft(b, x0 - 0.32, x1 + 0.32, z0 - 0.42, rz, eave, ridge, "metal", 0.10)
	_slope_soft(b, x0 - 0.32, x1 + 0.32, rz, z1 + 0.32, ridge, eave, "metal", 0.10)
	_gable_soft(b, x0 + 0.05, z0, rz, z1, eave, ridge, "log")
	_gable_soft(b, x1 - 0.05, z0, rz, z1, eave, ridge, "log")

	# Приставная лестница на чердак бани. Своей коллизии у неё НЕТ намеренно:
	# её AABB ловил бы игрока в полуметре от стены, где на самом деле пусто.
	var ld: Array = d.get("ladder", [])
	if ld.size() == 2:
		_ladder(b, float(ld[0]), float(ld[1]), fl, eave)
		_bathloft_visuals(b, out, x0, x1, z0, z1, fl, eave, ridge,
			Vector2(float(ld[0]), float(ld[1])))

	# inward: в какую сторону от плоскости стекла лежит помещение. Западное
	# окно смотрит наружу на запад, восточное — на восток, и отпечаток на них
	# приходится на противоположные грани.
	_window(b, out, "banya-win-w", x0, x0 + t, float(ww[0]), float(ww[1]),
		float(ww[2]), float(ww[3]), 1.0)
	_window(b, out, "banya-win-e", x1 - t, x1, float(we[0]), float(we[1]),
		float(we[2]), float(we[3]), -1.0)

	# Кран у восточной стены — узел цепочки полива. Точка banya-tap живёт здесь
	# с фазы 14, а полигонов у неё не было НИ ОДНОГО: ни трубы, ни вентиля, ни
	# лужи. Игрок приходил к бане с северной дорожки, упирался в дверь, и
	# обходить сруб ему было незачем — задача говорила «кран у бани» и стороны
	# не называла. Всё через _shell: точка стоит в ладони от стены, и любой
	# коллайдер отжал бы игрока за пределы её радиуса 1.9 м.
	var tp: Array = d.get("tap", [])
	if tp.size() == 3:
		_tap(b, float(tp[0]), float(tp[1]), float(tp[2]), x1, fl)

	var nodes: Dictionary = out["nodes"]
	nodes["banya-clothes"] = _clothes(b,
		Vector3((float(bn[0]) + float(bn[1])) / 2.0, float(bn[4]) + 0.055, 22.35))
	nodes["banya-ladle"] = _ladle(b,
		Vector3(float(st[1]) + 0.26, fl + 1.34, float(st[2]) + 0.10))
	# Large tagged key on a conspicuous nail beside the INNER face of the
	# entrance.  The north wall needs the old X-facing model turned by 90°.
	nodes["cellar-shed-key"] = _nail_key(b,
		Vector3(d1 + 0.22, fl + 1.42, z0 + t + 0.035), PI / 2.0)


## Стена с окошком — четырьмя твёрдыми кусками. Проём вырезается и в коллизии
## тоже: сплошная стена с нарисованным окном читается как обман ровно в тот
## момент, когда игрок подходит вплотную.
static func _wall_with_window(b: WorldBuilder, out: Dictionary,
		a0: float, a1: float, y0: float, y1: float, c0: float, c1: float,
		w0: float, w1: float, wy0: float, wy1: float) -> void:
	_solid(b, out, a0, a1, y0, y1, c0, w0)
	_solid(b, out, a0, a1, y0, y1, w1, c1)
	_solid(b, out, a0, a1, y0, wy0, w0, w1)
	_solid(b, out, a0, a1, wy1, y1, w0, w1)


static func _wall_skin(b: WorldBuilder, a0: float, a1: float, y0: float, y1: float,
		c0: float, c1: float, w0: float, w1: float, wy0: float, wy1: float,
		key: String) -> void:
	_shell(b, a0, a1, y0, y1, c0, w0, key, 0.0)
	_shell(b, a0, a1, y0, y1, w1, c1, key, 0.0)
	_shell(b, a0, a1, y0, wy0, w0, w1, key, 0.0)
	_shell(b, a0, a1, wy1, y1, w0, w1, key, 0.0)


# Уличный кран у восточной стены бани (фаза 16).
#
# Три вещи, и каждая делает свою работу.
#
# СТОЯК, НОСИК, БАРАШЕК — то, во что игрок целится. Без них подсказка
# «набрать воду» появлялась на голой стене, и найти её можно было только
# случайно, водя головой вдоль сруба.
#
# МОКРОЕ ПЯТНО И ТАЗ — ПРИЧИНА ОБОЙТИ СРУБ. Это не украшение: до фазы 16 у
# игрока не было ни одной причины заглянуть за баню. С северной дорожки он
# видит дверь, а кран у него за углом, на противоположной стороне. Тёмная
# полоса на земле, которая уходит за угол, — единственное, что читается с
# дорожки и говорит «там что-то мокрое».
#
# Всё collide = false. Коллайдер у стояка отжал бы игрока за 1.9 м радиуса
# точки, и кран стал бы виден, но недосягаем — то есть ровно та же беда
# другой стороной.
static func _tap(b: WorldBuilder, tx: float, ty: float, tz: float,
		wall_x: float, fl: float) -> void:
	# Ось стояка — ровно точка из данных: труба идёт по стене, носик наружу.
	# Так координата в yard.json BANYA.tap и геометрия не могут разъехаться.
	var px := tx
	_shell(b, px - 0.035, px + 0.035, 0.0, ty + 0.19, tz - 0.035, tz + 0.035, "metal", 1.2)
	# Хомут, которым стояк прихвачен к бревну.
	_shell(b, px - 0.05, wall_x, ty - 0.12, ty - 0.06, tz - 0.05, tz + 0.05, "metal", 0.0)
	# Носик: вылет на восток на высоте, с которой наливают в лейку, и загнутый
	# вниз кончик. Без загиба труба читается обрубком, а не краном.
	_shell(b, px, px + 0.17, ty - 0.028, ty + 0.028, tz - 0.030, tz + 0.030, "metal", 0.0)
	_shell(b, px + 0.12, px + 0.175, ty - 0.10, ty + 0.028, tz - 0.030, tz + 0.030,
		"metal", 0.0)
	# Барашек-вентиль: шайба и короткая ось поверх стояка.
	_shell(b, px - 0.065, px + 0.065, ty + 0.19, ty + 0.225, tz - 0.065, tz + 0.065,
		"metal", 0.0)
	_shell(b, px - 0.018, px + 0.018, ty + 0.225, ty + 0.27, tz - 0.018, tz + 0.018,
		"metal", 0.0)
	# Мокрое пятно под краном — материалом "water", а не "dark": плоский
	# тёмный прямоугольник на земле читается дырой, а полупрозрачная вода
	# читается лужей. Ключ уже есть (пруд околицы), нового бакета не заводим.
	# Пятно лежит ВОСТОЧНЕЕ цоколя (тот идёт до wall_x + 0.05 и высотой fl):
	# плоскость под цоколем не видно вовсе.
	#
	# Три захлёста вместо одного прямоугольника: у лужи нет прямых углов, а
	# один бокс на земле выглядит ковриком.
	_shell(b, wall_x + 0.07, wall_x + 0.62, 0.004, 0.009, tz - 0.30, tz + 0.31,
		"water", 1.0)
	_shell(b, wall_x + 0.14, wall_x + 0.44, 0.004, 0.010, tz - 0.46, tz + 0.12,
		"water", 1.0)
	_shell(b, wall_x + 0.22, wall_x + 0.78, 0.004, 0.008, tz - 0.12, tz + 0.44,
		"water", 1.0)
	# ПРИЧИНА ОБОЙТИ СРУБ. Ручеёк за угол не читается: с дорожки он двадцать
	# сантиметров тёмного на траве. Читается ВЫТОПТАННАЯ ЗЕМЛЯ — тропа, по
	# которой к крану ходят с вёдрами. Она заворачивает за северо-восточный
	# угол бани и обрывается из виду, и это единственное на участке, что
	# говорит «туда ходят». Тот же приём, что тропа в лес на околице.
	_shell(b, wall_x - 2.40, wall_x + 0.78, 0.001, 0.012, tz - 2.90, tz - 2.20,
		"dirt", 1.0)
	_shell(b, wall_x + 0.05, wall_x + 0.72, 0.001, 0.012, tz - 2.90, tz + 0.55,
		"dirt", 1.0)
	# Таз рядом: перевёрнут, дно вверх, как их и оставляют. Бортик отдельной
	# долькой — без него таз читается плоской жестянкой на земле.
	_shell(b, wall_x + 0.32, wall_x + 0.76, 0.0, 0.155, tz + 0.50, tz + 0.94,
		"metal", 0.0)
	_shell(b, wall_x + 0.28, wall_x + 0.80, 0.155, 0.185, tz + 0.46, tz + 0.98,
		"metal", 0.0)
	# Цоколь под краном потемневший — по нему и течёт.
	_shell(b, wall_x + 0.049, wall_x + 0.053, 0.0, fl, tz - 0.22, tz + 0.22,
		"dark", 0.0)


# Выпуски венцов по углам. Пять на угол, через один по вертикали: рубка в чашу
# именно так и выглядит с улицы.
static func _crowns(b: WorldBuilder, x0: float, x1: float, z0: float, z1: float,
		t: float, fl: float, eave: float) -> void:
	var n := 5
	var out_len := 0.24
	var h := 0.155
	for i in n:
		var y := fl + 0.28 + (eave - fl - 0.55) * float(i) / float(n - 1)
		if i % 2 == 0:
			# Венец идёт вдоль x: торцы вылезают на западе и востоке.
			_shell(b, x0 - out_len, x0, y, y + h, z0, z0 + t, "log", 0.8)
			_shell(b, x0 - out_len, x0, y, y + h, z1 - t, z1, "log", 0.8)
			_shell(b, x1, x1 + out_len, y, y + h, z0, z0 + t, "log", 0.8)
			_shell(b, x1, x1 + out_len, y, y + h, z1 - t, z1, "log", 0.8)
		else:
			# Венец вдоль z: торцы на севере и юге.
			_shell(b, x0, x0 + t, y, y + h, z0 - out_len, z0, "log", 0.8)
			_shell(b, x1 - t, x1, y, y + h, z0 - out_len, z0, "log", 0.8)
			_shell(b, x0, x0 + t, y, y + h, z1, z1 + out_len, "log", 0.8)
			_shell(b, x1 - t, x1, y, y + h, z1, z1 + out_len, "log", 0.8)


static func _ladder(b: WorldBuilder, x: float, z: float, fl: float, top: float) -> void:
	for s: float in [-0.21, 0.21]:
		_shell(b, x - 0.04, x + 0.04, fl, top + 0.35, z + s - 0.04, z + s + 0.04,
			"boards", 1.2)
	var n := 7
	for i in n:
		var y := fl + 0.25 + (top - fl) * float(i) / float(n)
		_shell(b, x - 0.03, x + 0.03, y, y + 0.045, z - 0.21, z + 0.21, "boards", 0.6)


## Visual-only attic set.  None of these pieces enters SET_OVERLAY, so the
## ladder, opening and cramped roof space cannot alter collision parity.
static func _bathloft_visuals(b: WorldBuilder, out: Dictionary,
		x0: float, x1: float, z0: float, z1: float, fl: float,
		eave: float, ridge: float, ladder: Vector2) -> void:
	# Dark opening behind the ladder, centred on the east gable.
	var hatch := _holder(b, "bathloft-hatch",
		Vector3(x1 + 0.012, eave + 0.29, ladder.y))
	_piece(hatch, _box_mesh(b, Vector3(0.025, 0.58, 0.72), "", 0x090807), Vector3.ZERO)
	(out["nodes"] as Dictionary)["bathloft-hatch"] = hatch

	var loft := _holder(b, "bathloft-interior", Vector3.ZERO)
	# Four rough rafters under the existing roof and a dusty cross-beam.
	# Keep the two central members away from the hatch axis: at z=23.0/24.8
	# the prone camera started less than a metre from a beam and its near face
	# filled the whole view before the player could turn.
	for z: float in [z0 + 0.45, z0 + 1.30, z1 - 1.30, z1 - 0.45]:
		for side: float in [-1.0, 1.0]:
			var x_mid := (x0 + x1) * 0.5
			var x_end := x_mid + side * (x1 - x0) * 0.46
			var length := Vector2(x_end - x_mid, eave - ridge).length()
			var angle := atan2(eave - ridge, x_end - x_mid)
			_piece(loft, _box_mesh(b, Vector3(length, 0.075, 0.085), "boards"),
				Vector3((x_mid + x_end) * 0.5, (ridge + eave) * 0.5, z),
				Vector3(0.0, 0.0, angle))
	# The cross-member belongs at the far western cassette beam. A member along
	# the hatch axis put the crawl camera's near plane inside the timber.
	_piece(loft, _box_mesh(b, Vector3(0.16, 0.14, 2.40), "boards"),
		Vector3(x0 + 1.08, ridge - 0.20, z1 - 1.45))
	# A short crawl route: hanging mushrooms at the entrance, then two solid-
	# looking clutter islands that force an S-shaped approach to the far beam.
	# These remain visual-only; OutskirtsQuest owns the matching runtime bounds.
	for z: float in [22.34, 22.72, 23.10]:
		_piece(loft, _attic_atlas_tile(0, Vector2(0.34, 0.62)),
			Vector3(6.03, 2.83, z), Vector3(0.0, PI / 2.0, 0.0))
	for row: Array in [
		[Vector3(5.12, 2.48, 22.62), Vector3(0.58, 0.38, 0.72), 0x5b4b35],
		[Vector3(5.13, 2.52, 23.30), Vector3(0.54, 0.46, 0.62), 0x76684d],
		[Vector3(5.48, 2.48, 24.78), Vector3(0.68, 0.40, 0.64), 0x4b3b2a],
		[Vector3(5.30, 2.61, 25.34), Vector3(0.50, 0.62, 0.48), 0x756b51],
	]:
		_piece(loft, _box_mesh(b, row[1], "", int(row[2])), row[0],
			Vector3(0.0, 0.17 if row[0].z < 24.0 else -0.22, 0.0))
	# Brooms, herbs, jars, icon, bast doll, child's boot and rafter scratches.
	var cards := [
		[1, Vector3(6.18, 2.74, 25.55), Vector2(0.42, 0.70), Vector3(0, PI / 2, 0)],
		[2, Vector3(5.76, 2.80, 25.63), Vector2(0.38, 0.58), Vector3(0, PI / 2, 0)],
		[3, Vector3(4.72, 2.55, 25.48), Vector2(0.45, 0.42), Vector3.ZERO],
		[6, Vector3(4.30, 2.78, 22.25), Vector2(0.38, 0.52), Vector3(0, -PI / 2, 0)],
		[7, Vector3(4.08, 2.50, 24.30), Vector2(0.30, 0.48), Vector3.ZERO],
		[8, Vector3(4.55, 2.43, 25.02), Vector2(0.34, 0.28), Vector3.ZERO],
		[9, Vector3(4.02, 2.91, 23.35), Vector2(0.44, 0.34), Vector3(0, PI / 2, 0)],
	]
	for card: Array in cards:
		_piece(loft, _attic_atlas_tile(int(card[0]), card[2]), card[1], card[3])
	(out["nodes"] as Dictionary)["bathloft-interior"] = loft

	var tape := _holder(b, "bathloft-tape",
		Vector3(x0 + 1.20, eave + 0.47, z1 - 1.35), false)
	_piece(tape, _box_mesh(b, Vector3(0.34, 0.065, 0.22), "", 0x252423), Vector3.ZERO,
		Vector3(0.0, 0.18, -0.06))
	_piece(tape, _box_mesh(b, Vector3(0.12, 0.008, 0.14), "", 0xc7bea2),
		Vector3(0.0, 0.038, 0.0), Vector3(0.0, 0.18, -0.06))
	# Карандашный знак старой мельницы на этикетке: мачта и косой крест.
	# Он намеренно собран той же дешёвой геометрией, а не текстом/декалью.
	var pencil := 0x514c43
	_piece(tape, _box_mesh(b, Vector3(0.010, 0.004, 0.075), "", pencil),
		Vector3(-0.035, 0.044, 0.010), Vector3(0.0, 0.18, -0.06))
	for angle: float in [-PI * 0.25, PI * 0.25]:
		_piece(tape, _box_mesh(b, Vector3(0.010, 0.004, 0.074), "", pencil),
			Vector3(-0.035, 0.046, -0.035), Vector3(0.0, 0.18 + angle, -0.06))
	for dz: float in [-0.065, 0.065]:
		var reel := CylinderMesh.new()
		reel.top_radius = 0.043
		reel.bottom_radius = 0.043
		reel.height = 0.010
		reel.radial_segments = 8
		reel.rings = 1
		reel.material = b.mats.flat(0x77736a, true)
		_piece(tape, reel, Vector3(0.0, 0.047, dz))
	tape.set_meta("visual_only", true)
	(out["nodes"] as Dictionary)["bathloft-tape"] = tape


static func _attic_atlas_tile(tile: int, size: Vector2) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var col := tile % 4
	var row := tile / 4
	var u0 := float(col) / 4.0
	var v0 := float(row) / 3.0
	var u1 := float(col + 1) / 4.0
	var v1 := float(row + 1) / 3.0
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	for point: Array in [
		[Vector3(-hx, -hy, 0), Vector2(u0, v1)],
		[Vector3(hx, -hy, 0), Vector2(u1, v1)],
		[Vector3(hx, hy, 0), Vector2(u1, v0)],
		[Vector3(-hx, -hy, 0), Vector2(u0, v1)],
		[Vector3(hx, hy, 0), Vector2(u1, v0)],
		[Vector3(-hx, hy, 0), Vector2(u0, v0)],
	]:
		st.set_normal(Vector3(0, 0, 1))
		st.set_uv(point[1])
		st.add_vertex(point[0])
	var mesh := st.commit()
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	mat.alpha_scissor_threshold = 0.28
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	var path := "res://assets/atlases/attic-props-atlas-v2.png"
	if ResourceLoader.exists(path):
		mat.albedo_texture = load(path) as Texture2D
	mesh.surface_set_material(0, mat)
	return mesh


static func _steam_window_mesh(inward: float,
		height: float, width: float) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	var x := inward * 0.022
	var hy := height * 0.5
	var hz := width * 0.5
	# Front (+inward X), readable from inside.
	for v: Vector3 in [Vector3(x, -hy, -hz), Vector3(x, -hy, hz),
			Vector3(x, hy, hz), Vector3(x, hy, -hz)]:
		vertices.append(v)
		normals.append(Vector3(inward, 0.0, 0.0))
	for uv: Vector2 in [Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)]:
		uvs.append(uv)
	# Godot treats clockwise winding (viewed from the supplied normal) as front.
	indices.append_array(PackedInt32Array([0, 1, 2, 0, 2, 3]) if inward > 0.0 \
		else PackedInt32Array([0, 2, 1, 0, 3, 2]))
	# The outside face lives on the opposite physical side of the base pane.
	# It keeps the same y/z -> UV mapping, so walking around the glass mirrors
	# the writing by viewpoint instead of drawing a second, re-typeset label.
	for i in 4:
		var outside := vertices[i]
		outside.x = -x
		vertices.append(outside)
		normals.append(Vector3(-inward, 0.0, 0.0))
		uvs.append(uvs[i])
	indices.append_array(PackedInt32Array([4, 6, 5, 4, 7, 6]) if inward > 0.0 \
		else PackedInt32Array([4, 5, 6, 4, 6, 7]))
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	var path := "res://assets/pictures/banya-window-steam-v2.webp"
	if ResourceLoader.exists(path):
		mat.albedo_texture = load(path) as Texture2D
	else:
		mat.albedo_color = Color("b8c0ba")
	mesh.surface_set_material(0, mat)
	mesh.set_meta("steam_texture", path)
	mesh.set_meta("physical_mirror", true)
	return mesh


# Окошко бани. Стекло — своей нодой, а не в общей прозрачной куче: на нём
# меняется материал (запотевшее стекло и отпечаток ладони), а мировая сетка
# держит по одному материалу на ключ.
static func _window(b: WorldBuilder, out: Dictionary, id: String,
		a0: float, a1: float, w0: float, w1: float, wy0: float, wy1: float,
		inward: float) -> void:
	var cx := (a0 + a1) / 2.0
	var cz := (w0 + w1) / 2.0
	var cy := (wy0 + wy1) / 2.0
	var pane := MeshInstance3D.new()
	pane.name = id
	var bm := BoxMesh.new()
	bm.size = Vector3(0.03, wy1 - wy0, w1 - w0)
	bm.material = b.mats.get_mat("glass")
	pane.mesh = bm
	pane.position = Vector3(cx, cy, cz)
	pane.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Отпечаток ладони на запотевшем стекле. Ребёнок панели и невидим до знака
	# omens «banya-print»: подмена, увиденная в момент смены, читается как
	# поп-ин текстуры, а не как ужас (тот же вывод, что у лица наблюдателя
	# в фазе 9). Ставится с ВНУТРЕННЕЙ стороны — там, где его и оставили.
	var mark := MeshInstance3D.new()
	mark.name = "print"
	var pm := BoxMesh.new()
	pm.size = Vector3(0.004, 0.17, 0.13)
	pm.material = b.mats.glow(0xbfc6c2, 0.55)
	mark.mesh = pm
	mark.position = Vector3(inward * 0.02, -0.02, 0.02)
	mark.visible = false
	mark.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	pane.add_child(mark)

	# The plot clue is separate from the old optional palm-print omen above.
	# It lives on the inner face of the west pane and becomes visible when the
	# bathhouse heat timer completes; OutskirtsQuest owns that state transition.
	if id == "banya-win-w":
		# One opaque PSX mesh carries both physical faces of the steamed pane.
		# The outside vertices keep the same spatial UV orientation, so the words
		# are naturally mirrored through the glass instead of being re-typeset.
		var writing := MeshInstance3D.new()
		writing.name = "story-writing"
		writing.mesh = _steam_window_mesh(inward, wy1 - wy0, w1 - w0)
		writing.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		writing.visible = false
		writing.set_meta("story_clue", true)
		writing.set_meta("story_text", "НЕ ХОДИ НА ОЗЕРО\nКЛЮЧ У ДВЕРИ")
		pane.add_child(writing)

	b.decor["yard-" + id] = pane
	(out["nodes"] as Dictionary)[id] = pane
	# Обналичка и переплёт.
	_shell(b, a0 - 0.03, a1 + 0.03, wy0 - 0.07, wy0, w0 - 0.07, w1 + 0.07, "trim", 0.0)
	_shell(b, a0 - 0.03, a1 + 0.03, wy1, wy1 + 0.07, w0 - 0.07, w1 + 0.07, "trim", 0.0)
	_shell(b, a0 - 0.03, a1 + 0.03, wy0, wy1, w0 - 0.07, w0, "trim", 0.0)
	_shell(b, a0 - 0.03, a1 + 0.03, wy0, wy1, w1, w1 + 0.07, "trim", 0.0)
	_shell(b, a0 + 0.01, a1 - 0.01, cy - 0.015, cy + 0.015, w0, w1, "dark", 1.0)


# --------------------------------------------------------- мокрые следы ----

# Босые мокрые следы от бани к крыльцу (глава ТЕМНОТА). Одна нода со всеми
# отпечатками: показывать и прятать их надо разом, а по одному — это полтора
# десятка лишних вызовов отрисовки.
static func _wet_steps(b: WorldBuilder, out: Dictionary) -> void:
	var route: Array = [
		Vector2(5.0, 20.80), Vector2(5.0, 19.65), Vector2(9.20, 19.65),
		Vector2(9.20, 3.70), Vector2(-2.30, 3.70), Vector2(-2.30, 5.00),
	]
	var holder := Node3D.new()
	holder.name = "yard-wet-steps"
	holder.visible = false
	var mesh := BoxMesh.new()
	mesh.size = Vector3(0.11, 0.006, 0.24)
	mesh.material = b.mats.flat(0x3a3f43, true)
	var step := 2.2
	var side := 1.0
	var carry := 0.0
	for i in route.size() - 1:
		var a: Vector2 = route[i]
		var c: Vector2 = route[i + 1]
		var seg := a.distance_to(c)
		var dir := (c - a).normalized()
		var nrm := Vector2(-dir.y, dir.x)
		var tt := carry
		while tt < seg:
			var p := a + dir * tt + nrm * (0.11 * side)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.position = Vector3(p.x, 0.062, p.y)
			mi.rotation = Vector3(0.0, atan2(dir.x, dir.y), 0.0)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			holder.add_child(mi)
			side = -side
			tt += step
		carry = tt - seg
	b.decor["yard-wet-steps"] = holder
	(out["nodes"] as Dictionary)["wet-steps"] = holder


# ----------------------------------------------------------------- сад ----

# Яблони (фаза 13). Пётр просил яблони — вот они, и на участке они обычные:
# ствол, две развилки, крона тремя ярусами и плоды. Смеются они В КАССЕТЕ,
# и это решение Петра, а не экономия: гэг, повторённый в мире, перестаёт быть
# гэгом и становится механикой.
#
# Ствол идёт в SET_OVERLAY, то есть в четвёртый набор коллизий, невидимый для
# nav_graph.gd и ai.gd. Значит, дерево, поставленное на узел или на ребро
# навграфа, — это дед, идущий сквозь ствол, и ни один тест этого не заметит,
# кроме одного: test_yard_nav_clear меряет зазор по out["boxes"] и требует
# 0.60 м. Координаты в data/yard.json выбраны под этот замер.
static func _orchard(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var tr := float(d.get("trunk", 0.19))
	var nodes: Dictionary = out["nodes"]
	var tree_visuals: Array = []
	var resolved := resolved_orchard(d)
	for i in (d.get("trees", []) as Array).size():
		if not resolved.has(i):
			continue
		var accepted: Dictionary = resolved[i]
		var x := float(accepted["x"])
		var z := float(accepted["z"])
		var h := float(accepted["h"])
		var w := float(accepted["w"])
		# Всё ниже создаётся только после принятия позиции. Поэтому collider,
		# крона, apples-i и apple-tree-i никогда не расходятся по координатам.
		# Твёрд только ствол: в крону игрок и так не влезет, а лишняя коробка
		# в четвёртом наборе — это лишний метр зазора, который надо держать.
		_solid(b, out, x - tr, x + tr, 0.0, h * 0.62, z - tr, z + tr)
		# Две развилки: без них ствол читается столбом, а не яблоней.
		for s: float in [-1.0, 1.0]:
			b._slope(x + s * 0.34 - 0.07, x + s * 0.34 + 0.07,
				z - 0.05, z + 0.05, h * 0.46, h * 0.72, "log", 0.14, false)
		# Крона тремя ярусами вразнобой: одинаковые шары превращают четыре
		# дерева в один повторённый объект.
		tree_visuals.append({"x": x, "z": z, "h": h, "w": w, "trunk": tr,
			"kind": "orchard", "variant": i % 3, "tree_index": i, "placement_resolved": true})
		# Плоды: своя нода, потому что ГАСНУТ они по одному дереву — обтряс
		# яблоню, и она стоит голой. Прогресс задания виден в мире, а не только
		# в строке задачи.
		var fruit := _holder(b, "apples-%d" % i, Vector3(x, 0.0, z))
		var fruit_surface := SurfaceTool.new()
		fruit_surface.begin(Mesh.PRIMITIVE_TRIANGLES)
		for k in 11:
			var ang := float(k) * TAU / 9.0 + float(i) * 0.4
			var rr := w * (0.55 + 0.32 * float(k % 3) / 2.0)
			var apple := SphereMesh.new()
			var apple_r := 0.055 + 0.009 * float((k + i) % 3)
			apple.radius = apple_r
			apple.height = apple_r * 1.82
			apple.radial_segments = 6
			apple.rings = 3
			fruit_surface.append_from(apple, 0, Transform3D(Basis(Vector3.UP, ang),
				Vector3(cos(ang) * rr, h * (0.64 + 0.24 * float(k % 4) / 3.0),
					sin(ang) * rr)))
		var fruit_mesh := fruit_surface.commit()
		fruit_mesh.surface_set_material(0, b.mats.flat(0x9c6a3a, true))
		_piece(fruit, fruit_mesh, Vector3.ZERO)
		fruit.set_meta("combined_surface", true)
		fruit.set_meta("apple_count", 11)
		fruit.set_meta("tree_id", "apple-tree-%d" % i)
		nodes["apples-%d" % i] = fruit
	StreetWorld.add_low_poly_trees(b, "yard-orchard", tree_visuals)
	out["orchard"] = {"trees": resolved, "paired": true}


## Принятые позиции по исходному индексу save-флага. Возвращаем Dictionary,
## а не плотный Array: отклонённая строка не сдвигает apple-picked-i.
static func resolved_orchard(d: Dictionary) -> Dictionary:
	var accepted: Dictionary = {}
	var footprints := StreetWorld.tree_footprints()
	var rows: Array = d.get("trees", [])
	for i in rows.size():
		var row: Variant = rows[i]
		if not (row is Array) or (row as Array).size() != 3:
			continue
		var a: Array = row
		var w := 1.05 + 0.18 * sin(float(i) * 1.7)
		var crown := w * 1.15 + 0.45
		var pos: Variant = StreetWorld.resolve_tree_position("apple-tree-%d" % i,
			Vector2(float(a[0]), float(a[1])), crown,
			Rect2(-9.30, 0.20, 19.60, 29.45), footprints)
		# Обрезанная садовая крона занимает меньше места, сохраняя дерево и save-id.
		# Подбираем размер до принятия пары: плоды и ствол используют те же w/x/z.
		if not pos is Vector2:
			for factor: float in [0.90,0.80,0.70,0.60]:
				var compact_w := w*factor
				var compact_crown := compact_w*1.15+0.45
				pos = StreetWorld.resolve_tree_position("apple-tree-%d" % i,
					Vector2(float(a[0]),float(a[1])),compact_crown,
					Rect2(-9.30,0.20,19.60,29.45),footprints)
				if pos is Vector2:
					w=compact_w
					crown=compact_crown
					break
		if not (pos is Vector2):
			continue
		accepted[i] = {"x": (pos as Vector2).x, "z": (pos as Vector2).y,
			"h": float(a[2]), "w": w, "crown": crown}
		# Последующие яблони не накладывают кроны на уже принятую пару.
		footprints.append(Rect2((pos as Vector2).x - crown,
			(pos as Vector2).y - crown, crown * 2.0, crown * 2.0))
	return accepted


# Обвес заданий фазы 13: бочка под раствор, поленница у бани, опрыскиватель
# в предбаннике, бутыль с ядом на полке погреба, плешь от щавеля и клоп на
# листе. Всё, кроме бочки и поленницы, — узлы без коллизии: это предметы,
# а не постройки.
static func _garden(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	if d.is_empty():
		return
	var nodes: Dictionary = out["nodes"]

	var bp := _at(d, "barrel", Vector3(4.60, 0.0, 18.20))
	nodes["spray-barrel"] = _barrel(b, bp)
	_solid(b, out, bp.x - 0.32, bp.x + 0.32, bp.y, bp.y + 0.92,
		bp.z - 0.32, bp.z + 0.32)

	var wd: Array = d.get("wood", [])
	if wd.size() == 4:
		_woodpile(b, out, float(wd[0]), float(wd[1]), float(wd[2]), float(wd[3]))

	nodes["sprayer"] = _sprayer(b, _at(d, "sprayer", Vector3(3.23, 0.52, 22.40)))
	nodes["poison"] = _poison(b, _at(d, "poison", Vector3(-8.59, 1.36, 2.71)))
	nodes["sorrel-bald"] = _bald(b, _at(d, "bald", Vector3(-3.20, 0.02, 22.60)))
	nodes["garden-bug"] = _bug(b, _at(d, "bug", Vector3(-1.80, 0.34, 24.90)))
	nodes["forks"] = _forks(b, _at(d, "forks", Vector3(1.20, 0.0, 20.20)))
	_garden_rows(b, nodes)
	_garden_crops(b, nodes)


# Four watering rectangles remain at their first four parity coordinates in
# WorldBuilder.ground().  End caps make each crosswise section legible, while
# one hidden wet-soil mesh per flag can change without rebuilding the world.
static func _garden_rows(b: WorldBuilder, nodes: Dictionary) -> void:
	for i in 4:
		var z := 17.4 + float(i) * 2.1
		_shell(b, -4.23, 3.03, 0.16, 0.21, z - 0.035, z + 0.035, "boards", 1.2)
		_shell(b, -4.23, 3.03, 0.16, 0.21, z + 1.065, z + 1.135, "boards", 1.2)
		var wet := MeshInstance3D.new()
		wet.name = "yard-wet-row-%d" % i
		var mesh := BoxMesh.new()
		mesh.size = Vector3(7.12, 0.014, 1.00)
		mesh.material = b.mats.flat(0x3b3025, true)
		wet.mesh = mesh
		wet.position = Vector3(-0.60, 0.174, z + 0.55)
		wet.visible = false
		wet.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		b.decor[wet.name] = wet
		nodes["wet-row-%d" % i] = wet


# Cheap crops: three MultiMeshes for four recognisable plant families.  Onion
# and sunflower share a tapered shoot mesh at very different scales; potatoes
# and cabbages use separate low-poly leaf/head silhouettes.  None casts a
# shadow or enters CollisionWorld.
static func _garden_crops(b: WorldBuilder, nodes: Dictionary) -> void:
	var potato := SphereMesh.new()
	potato.radius = 0.18
	potato.height = 0.24
	potato.radial_segments = 6
	potato.rings = 3
	var potato_xf: Array = []
	for row in 2:
		for i in 5:
			potato_xf.append(Transform3D(Basis().scaled(Vector3(1.15, 0.70, 0.90)),
				Vector3(-3.05 + row * 0.58, 0.35, 17.62 + i * 0.22)))
	_add_crop_multimesh(b, nodes, "garden-crops-potato", potato,
		b.mats.flat(0x49613a, true), potato_xf)

	var cabbage := SphereMesh.new()
	cabbage.radius = 0.22
	cabbage.height = 0.32
	cabbage.radial_segments = 8
	cabbage.rings = 4
	var cabbage_xf: Array = []
	for row in 2:
		for i in 5:
			var yaw := 0.22 * float((i + row) % 3)
			cabbage_xf.append(Transform3D(Basis(Vector3.UP, yaw),
				Vector3(1.10 + row * 0.56, 0.40, 21.82 + i * 0.22)))
	_add_crop_multimesh(b, nodes, "garden-crops-cabbage", cabbage,
		b.mats.flat(0x60754b, true), cabbage_xf)

	var shoot := _shoot_mesh()
	var shoot_xf: Array = []
	# Low shoots fill the second section; tall plants fill the fourth.
	for i in 10:
		shoot_xf.append(Transform3D(Basis().scaled(Vector3(0.72, 0.48, 0.72)),
			Vector3(-2.15 + float(i % 2) * 0.52, 0.34, 19.72 + float(i / 2) * 0.22)))
	# Four tall boundary plants provide the familiar sunflower rhythm.
	for i in 4:
		shoot_xf.append(Transform3D(Basis(Vector3.UP, 0.18 * i).scaled(
			Vector3(1.55, 2.8, 1.55)), Vector3(2.25 - i * 1.35, 1.04, 24.25)))
	_add_crop_multimesh(b, nodes, "garden-crops-onion-sunflower", shoot,
		b.mats.flat(0x75804b, true), shoot_xf)


static func _add_crop_multimesh(b: WorldBuilder, nodes: Dictionary, id: String,
		mesh: Mesh, material: Material, transforms: Array) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = transforms.size()
	for i in transforms.size():
		mm.set_instance_transform(i, transforms[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = id
	mmi.multimesh = mm
	mmi.material_override = material
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.visibility_range_end = 42.0
	mmi.visibility_range_end_margin = 5.0
	mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_DISABLED
	b.decor[id] = mmi
	nodes[id] = mmi


# Six-sided tapered stalk plus a two-sided hexagonal head, committed as one
# surface.  At onion scale it is a pointed shoot with a small bulb; at the tall
# boundary scale the head gives the sunflower its unmistakable silhouette.
static func _shoot_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var seg := 6
	var y0 := -0.31
	var y1 := 0.31
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var p00 := Vector3(cos(a0) * 0.065, y0, sin(a0) * 0.065)
		var p01 := Vector3(cos(a1) * 0.065, y0, sin(a1) * 0.065)
		var p10 := Vector3(cos(a0) * 0.025, y1, sin(a0) * 0.025)
		var p11 := Vector3(cos(a1) * 0.025, y1, sin(a1) * 0.025)
		var normal := Vector3(cos((a0 + a1) * 0.5), 0.0, sin((a0 + a1) * 0.5))
		for p: Vector3 in [p00, p10, p11, p00, p11, p01]:
			st.set_normal(normal)
			st.add_vertex(p)
	var center := Vector3(0.0, 0.39, 0.0)
	for i in seg:
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var p0 := center + Vector3(cos(a0) * 0.14, sin(a0) * 0.14, 0.0)
		var p1 := center + Vector3(cos(a1) * 0.14, sin(a1) * 0.14, 0.0)
		for p: Vector3 in [center, p0, p1]:
			st.set_normal(Vector3.FORWARD)
			st.add_vertex(p)
		for p: Vector3 in [center, p1, p0]:
			st.set_normal(Vector3.BACK)
			st.add_vertex(p)
	return st.commit()


# Бочка под раствор. Стоит открытая и пустая; налитое в неё — отдельный
# ребёнок, потому что показывать раствор надо ровно с той минуты, как игрок
# его развёл, а бочка стоит с загрузки.
static func _barrel(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "spray-barrel", pos)
	var body := CylinderMesh.new()
	body.top_radius = 0.31
	body.bottom_radius = 0.29
	body.height = 0.90
	body.radial_segments = 10
	body.rings = 1
	body.material = b.mats.flat(0x4e5459, true)
	_piece(n, body, Vector3(0, 0.45, 0))
	for y: float in [0.24, 0.68]:
		var ring := CylinderMesh.new()
		ring.top_radius = 0.325
		ring.bottom_radius = 0.325
		ring.height = 0.05
		ring.radial_segments = 10
		ring.rings = 1
		ring.material = b.mats.flat(0x3a3f43, true)
		_piece(n, ring, Vector3(0, y, 0))
	var mix := MeshInstance3D.new()
	mix.name = "mix"
	var mm := CylinderMesh.new()
	mm.top_radius = 0.285
	mm.bottom_radius = 0.285
	mm.height = 0.02
	mm.radial_segments = 10
	mm.rings = 1
	mm.material = b.mats.flat(0x4a5f52, true)
	mix.mesh = mm
	mix.position = Vector3(0, 0.74, 0)
	mix.visible = false
	mix.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.add_child(mix)
	return n


# Поленница вдоль западной стены бани. Твёрдая: обойти её игрок должен,
# а не пройти сквозь.
static func _woodpile(b: WorldBuilder, out: Dictionary, x0: float, x1: float,
		z0: float, z1: float) -> void:
	var h := 1.05
	_solid(b, out, x0, x1, 0.0, h, z0, z1)
	# Торцы поленьев рядами: шесть рядов по высоте, шаг по z — чтобы видно
	# было, что это поленница, а не ящик.
	var rows := 6
	var n := maxi(3, int((z1 - z0) / 0.22))
	for r in rows:
		var y := h * float(r) / float(rows)
		for i in n:
			var z := z0 + (z1 - z0) * (float(i) + 0.5) / float(n)
			var w := 0.085 + 0.02 * sin(float(i * 3 + r) * 1.9)
			_shell(b, x0, x1, y + 0.01, y + h / float(rows) - 0.01,
				z - w, z + w, "boards", 0.6)
	_shell(b, x0 - 0.05, x1 + 0.05, h, h + 0.06, z0 - 0.05, z1 + 0.05, "roof", 1.0)


# Опрыскиватель: бачок с насосом и шлангом. Тот самый, которым Тоня загубила
# щавель, — и это одна и та же вещь, а не две похожие.
static func _sprayer(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "sprayer", pos)
	var body := CylinderMesh.new()
	body.top_radius = 0.115
	body.bottom_radius = 0.125
	body.height = 0.40
	body.radial_segments = 9
	body.rings = 1
	body.material = b.mats.flat(0x54703f, true)
	_piece(n, body, Vector3(0, 0.20, 0))
	_piece(n, _box_mesh(b, Vector3(0.05, 0.16, 0.05), "", 0x7d8288), Vector3(0, 0.47, 0))
	_piece(n, _box_mesh(b, Vector3(0.03, 0.03, 0.34), "", 0x3a3f43),
		Vector3(0.13, 0.12, 0.12), Vector3(0.5, 0.0, 0.0))
	_piece(n, _box_mesh(b, Vector3(0.26, 0.02, 0.02), "", 0x8b9095),
		Vector3(0.20, 0.05, 0.24), Vector3(0.0, 0.6, 0.0))
	return n


# Бутыль с ядом на полке. Тёмное стекло и светлая этикетка: по этикетке её
# и находят среди двенадцати банок с огурцами.
static func _poison(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "poison", pos)
	var body := CylinderMesh.new()
	body.top_radius = 0.055
	body.bottom_radius = 0.062
	body.height = 0.24
	body.radial_segments = 8
	body.rings = 1
	body.material = b.mats.flat(0x3d4b52, true)
	_piece(n, body, Vector3(0, 0.12, 0))
	_piece(n, _box_mesh(b, Vector3(0.09, 0.09, 0.09), "", 0x1c1e21), Vector3(0, 0.27, 0))
	_piece(n, _box_mesh(b, Vector3(0.085, 0.11, 0.006), "", 0xc9c3ac),
		Vector3(0.0, 0.13, 0.064))
	return n


# Плешь на месте щавеля. Гэг без задания: игрок видит выжженное пятно ровно
# той формы, какой его описывает Витя на кассете, — и это всё.
static func _bald(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "sorrel-bald", pos)
	_piece(n, _box_mesh(b, Vector3(1.55, 0.012, 1.15), "", 0x7f7663), Vector3(0, 0.006, 0),
		Vector3(0.0, 0.12, 0.0))
	# Обугленные остатки по краю: без них пятно читается ковриком.
	for i in 7:
		var a := float(i) * TAU / 7.0 + 0.3
		_piece(n, _box_mesh(b, Vector3(0.16, 0.03, 0.05), "", 0x3a3f43),
			Vector3(cos(a) * 0.62, 0.015, sin(a) * 0.46), Vector3(0.0, a, 0.0))
	return n


# Вилы, воткнутые в газон. Невидимы до знака 'garden-forks' (omens.gd) и
# появляются только после того, как игрок посмотрел кассету «ОГОРОД», — тем
# самым последним её кадром, на котором ровный газон и воткнутые вилы.
# Коллизии нет: знак обязан ставиться за спиной и не толкать игрока.
static func _forks(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "forks", pos, false)
	n.rotation = Vector3(0.0, 0.5, 0.11)
	_piece(n, _box_mesh(b, Vector3(0.045, 1.32, 0.045), "", 0x6d4c31), Vector3(0, 0.66, 0))
	_piece(n, _box_mesh(b, Vector3(0.17, 0.05, 0.05), "", 0x6d4c31), Vector3(0, 1.30, 0))
	_piece(n, _box_mesh(b, Vector3(0.28, 0.05, 0.05), "", 0x7d8288), Vector3(0, 0.12, 0))
	for i in 4:
		_piece(n, _box_mesh(b, Vector3(0.03, 0.26, 0.03), "", 0x7d8288),
			Vector3(-0.105 + float(i) * 0.07, -0.01, 0))
	return n


# Мраморный клоп на листе. Крупный — Пётр просил крупного, — и лицо у него
# намечено ровно настолько, чтобы игрок не был уверен, что оно там есть.
static func _bug(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "garden-bug", pos)
	_piece(n, _box_mesh(b, Vector3(0.30, 0.008, 0.22), "", 0x4a5f52),
		Vector3(0, 0.0, 0), Vector3(0.0, 0.35, 0.0))
	_piece(n, _box_mesh(b, Vector3(0.14, 0.045, 0.115), "", 0x5d4530),
		Vector3(0.0, 0.026, 0.0), Vector3(0.0, 0.35, 0.0))
	_piece(n, _box_mesh(b, Vector3(0.09, 0.02, 0.055), "", 0x8a6a45),
		Vector3(0.02, 0.052, 0.02), Vector3(0.0, 0.35, 0.0))
	# Две светлые точки там, где у щитника их не бывает.
	for s: float in [-0.02, 0.02]:
		_piece(n, _box_mesh(b, Vector3(0.012, 0.006, 0.012), "", 0xc9c3ac),
			Vector3(0.055 + s * 0.4, 0.063, s))
	return n


# ------------------------------------------------------------- предметы ----

static func _at(d: Dictionary, key: String, def: Vector3) -> Vector3:
	var a: Array = d.get(key, [])
	if a.size() != 3:
		return def
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func _holder(b: WorldBuilder, id: String, pos: Vector3, shown := true) -> Node3D:
	var n := Node3D.new()
	n.name = "yard-" + id
	n.position = pos
	n.visible = shown
	b.decor["yard-" + id] = n
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


# Банки на полках погреба: три ряда по четыре. Те самые, за которыми в доме
# лежит тайник, — и в этом вся шутка: банки на участке везде.
static func _jars(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "cellar-shed-jars", pos)
	for row in 3:
		var y := 0.34 + row * 0.46
		_piece(n, _box_mesh(b, Vector3(0.40, 0.05, 2.00), "boards"), Vector3(0.0, y, 0.95))
		for i in 4:
			var jar := CylinderMesh.new()
			jar.top_radius = 0.075
			jar.bottom_radius = 0.075
			jar.height = 0.30
			jar.radial_segments = 8
			jar.rings = 1
			jar.material = b.mats.flat(0x9c6a3a if (row + i) % 2 == 0 else 0x54703f, true)
			_piece(n, jar, Vector3(0.0, y + 0.18, 0.30 + i * 0.42))
	return n


static func _rope(b: WorldBuilder, pos: Vector3, span: float) -> Node3D:
	var n := _holder(b, "cellar-shed-rope", pos)
	_piece(n, _box_mesh(b, Vector3(span, 0.012, 0.012), "", 0xb6ae9a), Vector3.ZERO)
	# Бельё: четыре простыни разной длины. Ими же закрыт вид на дальний угол —
	# и в главе ТЕМНОТА это работает лучше любой постановки.
	for i in 4:
		var w := 0.42 + 0.1 * float(i % 3)
		var h := 0.55 + 0.18 * float((i + 1) % 3)
		_piece(n, _box_mesh(b, Vector3(w, h, 0.02), "", 0xc9c3ac),
			Vector3(-span * 0.35 + i * span * 0.23, -h / 2.0 - 0.02, 0.0))
	return n


static func _lantern(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "cellar-shed-lantern", pos)
	_piece(n, _box_mesh(b, Vector3(0.13, 0.05, 0.13), "", 0x4e5459), Vector3(0, -0.10, 0))
	_piece(n, _box_mesh(b, Vector3(0.10, 0.14, 0.10), "", 0xc9c3ac), Vector3(0, 0.0, 0))
	_piece(n, _box_mesh(b, Vector3(0.12, 0.05, 0.12), "", 0x4e5459), Vector3(0, 0.10, 0))
	_piece(n, _box_mesh(b, Vector3(0.015, 0.09, 0.015), "", 0x3a3f43), Vector3(0, 0.17, 0))
	return n


# Чужая сухая одежда на лавке предбанника. Сухая — в этом и дело: дом стоял
# месяц, а из трубы бани тянет дымом.
static func _clothes(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "banya-clothes", pos, false)
	_piece(n, _box_mesh(b, Vector3(0.46, 0.10, 0.34), "", 0x4a5f52), Vector3(0, 0.05, 0),
		Vector3(0.0, 0.22, 0.0))
	_piece(n, _box_mesh(b, Vector3(0.30, 0.08, 0.26), "", 0x5d4530), Vector3(0.04, 0.13, 0.02),
		Vector3(0.0, -0.35, 0.0))
	_piece(n, _box_mesh(b, Vector3(0.22, 0.10, 0.15), "", 0x1c1e21), Vector3(-0.13, 0.10, -0.10))
	return n


static func _ladle(b: WorldBuilder, pos: Vector3) -> Node3D:
	var n := _holder(b, "banya-ladle", pos)
	var cup := CylinderMesh.new()
	cup.top_radius = 0.075
	cup.bottom_radius = 0.062
	cup.height = 0.09
	cup.radial_segments = 8
	cup.rings = 1
	cup.material = b.mats.flat(0x8b9095, true)
	_piece(n, cup, Vector3(0, -0.14, 0))
	_piece(n, _box_mesh(b, Vector3(0.022, 0.30, 0.022), "", 0x8a6a45), Vector3(0, 0.0, 0))
	return n


# Ключ от погреба на гвозде. Тот же приём, что с ключом от правления: вещь
# висит там, где висела всегда, и найти её можно только зайдя.
static func _nail_key(b: WorldBuilder, pos: Vector3, yaw := 0.0) -> Node3D:
	var n := _holder(b, "cellar-shed-key", pos, false)
	n.rotation.y = yaw
	# Key, nail and a pale physical tag.  All dimensions are deliberately twice
	# the old token's size so it remains readable under the 360-line PSX pass.
	_piece(n, _box_mesh(b, Vector3(0.020, 0.18, 0.020), "", 0xb1b5b4), Vector3(0, -0.09, 0))
	_piece(n, _box_mesh(b, Vector3(0.020, 0.085, 0.085), "", 0xb1b5b4), Vector3(0, 0.02, 0))
	_piece(n, _box_mesh(b, Vector3(0.020, 0.040, 0.060), "", 0xb1b5b4), Vector3(0, -0.17, 0.04))
	_piece(n, _box_mesh(b, Vector3(0.09, 0.018, 0.018), "", 0x3a3f43), Vector3(-0.035, 0.075, 0))
	_piece(n, _box_mesh(b, Vector3(0.018, 0.16, 0.13), "", 0xd8cfae), Vector3(0.016, -0.04, -0.12), Vector3(0.22, 0.0, 0.0))
	n.set_meta("tag", "погреб")
	return n


# ----------------------------------------------------------------- зоны ----

# Акустические зоны бани и погреба. Гард обязателен: тест собирает мир дважды
# в одном процессе, а GameData кэширует site.json по ссылке — без гарда зон
# стало бы четыре, и zone_at() возвращал бы вторую копию.
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

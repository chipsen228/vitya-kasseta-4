# Мир бабки Вали: камни, покос, тропа, холм, озеро (фаза 15, часть 2).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ФАЙЛ. Тот же довод, что у street_world/yard_world/
# outskirts_world и он машинный: коробки world_builder.gd сверяет
# tests/test_world_parity.gd (311 статики, 4 блокера, 83 коллайдера реквизита,
# 3885 треугольников), а data/props.json заморожен с фазы 8.
#
# ЧТО ЗДЕСЬ НЕЛЬЗЯ. Ни одной твёрдой коробки. И это не осторожность:
# камни лежат в двух метрах от кольца, по которому ходит Аркадий
# (z -6.2..-0.3), и в четырёх от полосы деда — коробка здесь ломает не
# картинку, а погоню и маршрут соседа, а поймать это нечем. Единственное
# исключение — лодка на берегу озера: она стоит на околице, где ни один
# маршрут не проходит, но и её мы кладём видимой, чтобы правило было ОДНО.
#
# ЧТО МЕНЯЕТСЯ НА РАНТАЙМЕ. Три полосы травы, тропа, крышка холма и ряска
# на озере — узлы `decor`, которые квест гасит и зажигает. Геометрию после
# сборки не трогаем ни разу: скошенная полоса — это `visible = false`,
# а не пересобранный меш.
#
# Нет data/valya.json — build() выходит первой строкой, и мир ровно тот,
# что принят в части 1.

class_name ValyaWorld
extends RefCounted

const DATA := "res://data/valya.json"

static var _cache: Variant = null


## Данные или пустой словарь. Кэш на процесс: файл читают и сборка, и квест.
static func data() -> Dictionary:
	if _cache is Dictionary:
		return _cache
	if not FileAccess.file_exists(DATA):
		_cache = {}
		return _cache
	var txt := FileAccess.get_file_as_string(DATA)
	var got: Variant = JSON.parse_string(txt)
	_cache = got if got is Dictionary else {}
	return _cache


## Сборка. Зовётся из WorldBuilder._build_all() ПОСЛЕ околицы и ДО зелени:
## тропа и полосы травы должны лечь на готовую землю второй линии, а Scatter
## обязан увидеть их уже стоящими — иначе куст вырастет посреди тропы.
static func build(b: WorldBuilder) -> Dictionary:
	var d := data()
	if d.is_empty():
		return {}

	var out: Dictionary = {"enabled": true, "boxes": [], "nodes": {}}
	_sign(b, d, out)
	_stones(b, d, out)
	_scythe(b, d, out)
	_mow(b, d, out)
	_grave(b, d, out)
	_bed(b, d, out)
	_lake(b, d, out)
	return out


# ------------------------------------------------------------ указатель ----

## Столб с доской у устья западного переулка. Ставится здесь, а не в
## outskirts_world: там кончается фаза 14, а это правка её слепого пятна —
## переулок был отмечен стрелкой, то есть не отмечен ничем.
static func _sign(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var sg: Dictionary = d.get("SIGN", {})
	if sg.is_empty():
		return
	var at: Array = sg.get("at", [-25.9, 0.0, -13.6])
	var h := float(sg.get("h", 1.85))
	var n := _holder(b, "farm-sign",
		Vector3(float(at[0]), float(at[1]), float(at[2])))
	n.rotation.y = float(sg.get("yaw", 0.0))
	_piece(n, _box(b, Vector3(0.09, h, 0.09), "log"), Vector3(0.0, h / 2.0, 0.0))
	# Доски и настоящий кириллический текст. Label3D использует локальный
	# шрифт и детерминированный mipmapped glyph-atlas Godot; сетевых/системных
	# шрифтов здесь нет.
	_piece(n, _box(b, Vector3(1.05, 0.26, 0.04), "shedwood"),
		Vector3(0.0, h - 0.22, 0.0))
	# ФАЗА 18. Вторая доска, ниже первой: «ВОДОКАЧКА», десять букв, и оттого
	# она шире и мельче. Зачем — жалоба Петра, пункт шестой: до фазы 18 будку
	# закрывал дом, и первым словом про воду в игре была просьба деда,
	# сказанная у крана в тридцати метрах отсюда. Указатель называет её
	# ДО того, как она понадобится, — тем же приёмом, что доска «ФЕРМА» выше.
	_piece(n, _box(b, Vector3(1.36, 0.22, 0.04), "shedwood"),
		Vector3(0.06, h - 0.56, 0.0))
	var font := load("res://assets/fonts/pt-mono-cyrillic-400.woff2") as Font
	for row: Array in [["ФЕРМА →", h - 0.22, 30, 0.0048],
		["ВОДОКАЧКА →", h - 0.56, 26, 0.0041]]:
		var label := Label3D.new()
		label.name = "sign-text-" + String(row[0]).replace(" ", "-")
		label.text = String(row[0])
		label.font = font
		label.font_size = int(row[2])
		label.pixel_size = float(row[3])
		label.modulate = Color("2b2620")
		# Label3D faces +Z. Keep it on that same (road/approach) face of the
		# board; the old negative offset put the glyphs behind the wood and made
		# them visible only as mirrored text from the lane side.
		label.position = Vector3(0.03, float(row[1]), 0.032)
		label.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
		label.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		label.set_meta("atlas_text", String(row[0]))
		n.add_child(label)
	out["nodes"]["farm-sign"] = n


# ---------------------------------------------------------------- камни ----

## Пять камней у ограды и круг, в который их надо сложить. Каждый камень —
## свой узел: квест переставляет их поштучно, и переставляет НЕ данные,
## а позицию узла.
static func _stones(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var st: Dictionary = d.get("STONES", {})
	if st.is_empty():
		return
	var row: Array = st.get("row", [])
	var marks: Array = st.get("marks", [])
	for i in row.size():
		var p: Array = row[i]
		var n := _holder(b, "stone-%d" % i,
			Vector3(float(p[0]), 0.0, float(p[1])))
		# Валун и зарубка на нём. Зарубки — тонкие светлые бруски поперёк:
		# читать их надо в упор, и это правильно, за этим и наклоняешься.
		_piece(n, _box(b, Vector3(0.44, 0.26, 0.38), "silhouette", 0x6f6a5e),
			Vector3(0.0, 0.13, 0.0))
		var m: int = int(marks[i]) if i < marks.size() else i
		for k in m + 1:
			_piece(n, _box(b, Vector3(0.035, 0.012, 0.16), "", 0xbdb7a4),
				Vector3(-0.13 + 0.055 * k, 0.262, 0.0))
		out["nodes"]["stone-%d" % i] = n

	# Круг. Пять лунок в земле, по которым видно, что камни ложатся сюда
	# и что их пять. Пустой круг у забора — это уже загадка, ещё до Вали.
	var c: Array = st.get("circle", [0.6, -5.95])
	var rad := float(st.get("radius", 0.62))
	var ring := _holder(b, "stone-ring", Vector3(float(c[0]), 0.0, float(c[1])))
	for i in 5:
		var a := TAU * float(i) / 5.0
		_piece(ring, _box(b, Vector3(0.30, 0.03, 0.30), "", 0x3a352c),
			Vector3(sin(a) * rad, 0.015, cos(a) * rad))
	out["nodes"]["stone-ring"] = ring


# ---------------------------------------------------------------- сарай ----

## Шкаф с инструментом в сарае дачи и коса в нём. Шкаф стоит закрытым,
## коса появляется, когда его открыли ключом Вали.
static func _scythe(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var s: Dictionary = d.get("SCYTHE", {})
	if s.is_empty():
		return
	var lp: Array = s.get("locker", [6.9, 1.05, 13.55])
	var locker := _holder(b, "shed-locker",
		Vector3(float(lp[0]), float(lp[1]), float(lp[2])))
	_piece(locker, _box(b, Vector3(0.90, 1.30, 0.34), "shedwood"), Vector3.ZERO)
	# Амбарный замок на петле — единственное, что объясняет запертость молча.
	_piece(locker, _box(b, Vector3(0.09, 0.13, 0.05), "metal"),
		Vector3(0.0, 0.0, -0.20))
	out["nodes"]["shed-locker"] = locker

	var sp: Array = s.get("scythe", [6.9, 1.15, 13.35])
	var sc := _holder(b, "scythe",
		Vector3(float(sp[0]), float(sp[1]), float(sp[2])), false)
	# Косовище и полотно. Полотно — три коротких бруска под углом друг к другу:
	# на дистанции, с которой её видно, дуга из трёх звеньев читается дугой.
	_piece(sc, _box(b, Vector3(0.05, 0.05, 1.55), "log"), Vector3(0.0, 0.0, 0.0))
	var blade := _box(b, Vector3(0.30, 0.012, 0.07), "metal")
	_piece(sc, blade, Vector3(0.14, 0.0, -0.74), Vector3(0.0, 0.24, 0.0))
	_piece(sc, blade, Vector3(0.41, 0.0, -0.66), Vector3(0.0, 0.55, 0.0))
	_piece(sc, blade, Vector3(0.64, 0.0, -0.51), Vector3(0.0, 0.88, 0.0))
	out["nodes"]["scythe"] = sc


# ----------------------------------------------------------------- покос ----

## Три полосы высокой травы и тропа под ними. Полоса — ряд плоских стеблей
## поперёк: MultiMesh здесь не нужен, стеблей на полосу десятка два.
static func _mow(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var m: Dictionary = d.get("MOW", {})
	if m.is_empty():
		return
	var h := float(m.get("height", 1.15))
	var step := float(m.get("step", 0.42))
	var strips: Array = m.get("strips", [])
	for i in strips.size():
		var r: Array = strips[i]
		var x0 := float(r[0])
		var x1 := float(r[1])
		var z0 := float(r[2])
		var z1 := float(r[3])
		var n := _holder(b, "mow-%d" % i,
			Vector3((x0 + x1) / 2.0, 0.0, (z0 + z1) / 2.0))
		var cols := maxi(2, int((x1 - x0) / step))
		var rows := maxi(2, int((z1 - z0) / step))
		# Полоса — ОДИН MultiMesh, а не полсотни узлов. Довод тот же, что
		# у scatter.gd: стебель стоит столько же, сколько дом, если у него
		# свой draw call, а стеблей на три полосы шесть десятков.
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _box(b, Vector3(0.035, 1.0, 0.16), "", 0x6b6f43)
		mm.instance_count = cols * rows
		var k := 0
		for cx in cols:
			for cz in rows:
				# Джиттер тем же приёмом, что в scatter.layout: sin-хеш,
				# ни одного randf(). Полоса обязана быть одинаковой в каждом
				# прогоне — по ней снимают кадры приёмки.
				var seed := float(i * 991 + cx * 37 + cz)
				var jx := (0.5 + 0.5 * sin(seed * 12.9898)) - 0.5
				var jz := (0.5 + 0.5 * sin(seed * 78.2330)) - 0.5
				var hh := h * (0.75 + 0.5 * (0.5 + 0.5 * sin(seed * 43.7585)))
				var yaw := TAU * (0.5 + 0.5 * sin(seed * 2.3170))
				# Высота идёт масштабом по Y: меш у всех один, иначе MultiMesh
				# не соберётся вовсе.
				var xf := Transform3D.IDENTITY.rotated(Vector3.UP, yaw)
				xf = xf.scaled(Vector3(1.0, hh, 1.0))
				xf.origin = Vector3(
					(float(cx) + 0.5) * step - (x1 - x0) / 2.0 + jx * step * 0.6,
					hh / 2.0,
					(float(cz) + 0.5) * step - (z1 - z0) / 2.0 + jz * step * 0.6)
				mm.set_instance_transform(k, xf)
				k += 1
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		n.add_child(mi)
		out["nodes"]["mow-%d" % i] = n

	var pth: Dictionary = m.get("path", {})
	if pth.is_empty():
		return
	var px: Array = pth["x"]
	var pz: Array = pth["z"]
	var path := _holder(b, "mow-path",
		Vector3((float(px[0]) + float(px[1])) / 2.0, 0.0,
			(float(pz[0]) + float(pz[1])) / 2.0), false)
	var mi := MeshInstance3D.new()
	var pm := BoxMesh.new()
	pm.size = Vector3(float(px[1]) - float(px[0]), 0.04,
		float(pz[1]) - float(pz[0]))
	pm.material = b.mats.get_mat(String(pth.get("mat", "dirt")))
	mi.mesh = pm
	mi.position = Vector3(0.0, 0.02, 0.0)
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	path.add_child(mi)
	out["nodes"]["mow-path"] = path


# ----------------------------------------------------------------- холм ----

## Свежий холм, крест из штакетника и лопата рядом. Деревья вокруг — не
## украшение: без них поляна за второй линией читается пустырём, а не местом,
## куда унесли и закопали.
static func _grave(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var g: Dictionary = d.get("GRAVE", {})
	if g.is_empty():
		return
	var mo: Array = g.get("mound", [])
	if mo.size() == 4:
		var mh := float(g.get("mound_h", 0.34))
		var n := _holder(b, "grave-mound",
			Vector3((float(mo[0]) + float(mo[1])) / 2.0, 0.0,
				(float(mo[2]) + float(mo[3])) / 2.0))
		# Насыпь — две коробки одна на другой, верхняя уже: под PSX-фильтром
		# ступенька читается склоном, а купол стоил бы своего меша.
		_piece(n, _box(b, Vector3(float(mo[1]) - float(mo[0]), mh * 0.6,
			float(mo[3]) - float(mo[2])), "", 0x4a3f30), Vector3(0.0, mh * 0.3, 0.0))
		_piece(n, _box(b, Vector3((float(mo[1]) - float(mo[0])) * 0.72, mh * 0.4,
			(float(mo[3]) - float(mo[2])) * 0.72), "", 0x53483a),
			Vector3(0.0, mh * 0.8, 0.0))
		out["nodes"]["grave-mound"] = n
		# Разрытая яма: та же насыпь, но раскиданная, и тёмный провал в ней.
		var pit := _holder(b, "grave-pit",
			Vector3((float(mo[0]) + float(mo[1])) / 2.0, 0.0,
				(float(mo[2]) + float(mo[3])) / 2.0), false)
		_piece(pit, _box(b, Vector3((float(mo[1]) - float(mo[0])) * 0.8, 0.06,
			(float(mo[3]) - float(mo[2])) * 0.8), "", 0x14110d), Vector3(0.0, 0.03, 0.0))
		_piece(pit, _box(b, Vector3(0.55, 0.22, 0.5), "", 0x4a3f30),
			Vector3(-0.85, 0.11, 0.35))
		_piece(pit, _box(b, Vector3(0.5, 0.18, 0.45), "", 0x4a3f30),
			Vector3(0.9, 0.09, -0.3))
		out["nodes"]["grave-pit"] = pit

	# ФАЗА 18. Лопата обретает тело. Ключ GRAVE.shovel лежал в данных с фазы 15
	# и не читался НИ РАЗУ: точка Interact «взять лопату» висела в пустом
	# воздухе на y 0.45, и задача «раскопать» отправляла к предмету, которого
	# в мире нет (жалоба Петра, пункт седьмой). У косы меш есть с той же фазы —
	# контракт «предмет виден до взятия» был нарушен ровно для лопаты.
	# Декор без коллизии, как всё в этом файле: паритет не двигается.
	var sh: Array = g.get("shovel", [])
	if sh.size() == 3:
		var sn := _holder(b, "grave-shovel",
			Vector3(float(sh[0]), float(sh[1]), float(sh[2])))
		# Воткнута в землю у насыпи, не брошена: черенок под наклон, полотно
		# в грунте. Так её видно с двух метров силуэтом, а не пятном в траве.
		# Развёрнута ЛИЦОМ к дороге (yaw -1.0, а не -0.4): черенок сам по себе
		# читается палкой в траве, и опознать лопату можно только по полотну,
		# а полотно надо видеть плашмя. Проверено кадром 131-лопата-у-холма.
		sn.rotation.y = -0.72
		# Толщины взяты с запасом против «настоящих»: черенок 7 см вместо
		# четырёх с половиной, полотно 26 на 34. С трёх метров в сумерках
		# сорокапятимиллиметровый черенок — вертикальная линия в один пиксель.
		_piece(sn, _box(b, Vector3(0.075, 1.30, 0.075), "log"),
			Vector3(0.20, 0.66, 0.0), Vector3(0.0, 0.0, 0.36))
		_piece(sn, _box(b, Vector3(0.34, 0.42, 0.035), "", 0xaeb5b9),
			Vector3(-0.17, 0.17, 0.0), Vector3(0.0, 0.0, 0.36))
		# Отвал у полотна: полоса поперёк, по ней лопата и отличается от доски.
		_piece(sn, _box(b, Vector3(0.34, 0.055, 0.07), "", 0xaeb5b9),
			Vector3(-0.10, 0.39, 0.0), Vector3(0.0, 0.0, 0.36))
		# Рукоять хомутиком поверху: по ней лопата и читается лопатой.
		_piece(sn, _box(b, Vector3(0.22, 0.055, 0.055), "log"),
			Vector3(0.58, 1.23, 0.0), Vector3(0.0, 0.0, 0.36))
		out["nodes"]["grave-shovel"] = sn

	# ФАЗА 18. Жестянка из холма. До этой фазы после раскопки была видна одна
	# яма, а коробка существовала тостом «Жестяная коробка: кассета и детский
	# сапог» — то есть уликой, которую игрок не видел ни секунды. Появляется
	# по grave-dug, гаснет по valya-3: к Вале её уносят в руках.
	var dgp: Array = g.get("dig", [])
	if dgp.size() == 3:
		var tin := _holder(b, "grave-tin",
			Vector3(float(dgp[0]) + 0.62, 0.0, float(dgp[2]) + 0.30), false)
		tin.rotation.y = 0.35
		_piece(tin, _box(b, Vector3(0.34, 0.13, 0.24), "metal"),
			Vector3(0.0, 0.065, 0.0))
		# Крышка рядом, вверх дном: коробку открыли тут же, у ямы.
		_piece(tin, _box(b, Vector3(0.30, 0.025, 0.21), "metal"),
			Vector3(0.30, 0.012, 0.14), Vector3(0.0, 0.5, 0.0))
		out["nodes"]["grave-tin"] = tin

	var cr: Array = g.get("cross", [])
	if cr.size() == 2:
		var ch := float(g.get("cross_h", 1.15))
		var n2 := _holder(b, "grave-cross",
			Vector3(float(cr[0]), 0.0, float(cr[1])))
		# Крест сбит из двух штакетин, и это видно: не памятник, а то, что
		# нашлось у забора.
		_piece(n2, _box(b, Vector3(0.075, ch, 0.035), "shedwood"),
			Vector3(0.0, ch / 2.0, 0.0), Vector3(0.0, 0.0, 0.06))
		_piece(n2, _box(b, Vector3(0.44, 0.07, 0.035), "shedwood"),
			Vector3(0.0, ch * 0.74, 0.0), Vector3(0.0, 0.0, 0.06))
		out["nodes"]["grave-cross"] = n2

	for i in (g.get("trees", []) as Array).size():
		var t: Array = (g["trees"] as Array)[i]
		if t.size() < 3:
			continue
		var tr := _holder(b, "grave-tree-%d" % i,
			Vector3(float(t[0]), 0.0, float(t[1])))
		var hh := float(t[2])
		_piece(tr, _box(b, Vector3(0.26, hh, 0.26), "", 0x3b3128),
			Vector3(0.0, hh / 2.0, 0.0))
		_piece(tr, _box(b, Vector3(2.1, hh * 0.5, 2.1), "", 0x2e3a25),
			Vector3(0.0, hh * 0.82, 0.0))
		out["nodes"]["grave-tree-%d" % i] = tr


# --------------------------------------------------------------- грядка ----

## Four optional excavation reveals. They are decorative nodes only: no body,
## collision box or navigation obstacle is created here.
static func _bed(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	for i in 4:
		var n := _holder(b, "garden-dug-%d" % i,
			Vector3(-0.60, 0.16, 17.95 + float(i) * 2.1), false)
		_piece(n, _box(b, Vector3(6.75, 0.045, 0.88), "", 0x17120e), Vector3.ZERO)
		if i == 0:
			for k in 7:
				_piece(n, _sphere(b, 0.12, 0x8a6842),
					Vector3(-2.2 + float(k) * 0.68, 0.10, 0.12 * float(k % 2)))
		elif i == 1:
			for k in 7:
				var x := -2.2 + float(k) * 0.68
				_piece(n, _sphere(b, 0.11, 0xb09a68), Vector3(x, 0.11, 0.0))
				_piece(n, _box(b, Vector3(0.025, 0.22, 0.025), "", 0x657243),
					Vector3(x, 0.23, 0.0))
		elif i == 2:
			for k in 5:
				var x := -2.0 + float(k)
				_piece(n, _sphere(b, 0.20, 0x73865c), Vector3(x, 0.17, 0.0))
				_piece(n, _box(b, Vector3(0.035, 0.20, 0.035), "", 0x8b7650),
					Vector3(x, 0.03, 0.0))
		else:
			_piece(n, _sphere(b, 0.19, 0xd1c5a4), Vector3(-1.72, 0.16, 0.0))
			_piece(n, _box(b, Vector3(1.10, 0.10, 0.12), "", 0xc8bb9b),
				Vector3(-0.98, 0.12, 0.02), Vector3(0.0, 0.35, 0.0))
			for k in 4:
				_piece(n, _box(b, Vector3(0.72, 0.055, 0.055), "", 0xc8bb9b),
					Vector3(-0.75 + float(k) * 0.18, 0.11, -0.24 + float(k) * 0.15),
					Vector3(0.0, -0.55 + float(k) * 0.24, 0.0))
			var jar := CylinderMesh.new()
			jar.top_radius = 0.16
			jar.bottom_radius = 0.14
			jar.height = 0.30
			jar.radial_segments = 8
			jar.rings = 1
			jar.material = b.mats.flat(0x756f62, true)
			_piece(n, jar, Vector3(1.72, 0.15, 0.0), Vector3(0.18, 0.0, -0.20))
			for k in 3:
				_piece(n, _box(b, Vector3(0.18, 0.035, 0.11), "", 0x282522),
					Vector3(1.46 + float(k) * 0.22, 0.08, 0.22))
		out["nodes"]["garden-dug-%d" % i] = n


static func _sphere(b: WorldBuilder, radius: float, hex: int) -> SphereMesh:
	var mesh := SphereMesh.new()
	mesh.radius = radius
	mesh.height = radius * 2.0
	mesh.radial_segments = 6
	mesh.rings = 3
	mesh.material = b.mats.flat(hex, true)
	return mesh


# ---------------------------------------------------------------- озеро ----

## Лодка на берегу, колья с сетью и ряска. Само зеркало и мостки строит
## outskirts_world._pond() по своим числам — здесь только то, что на них.
static func _lake(b: WorldBuilder, d: Dictionary, out: Dictionary) -> void:
	var lk: Dictionary = d.get("LAKE", {})
	if lk.is_empty():
		return

	var bt: Array = lk.get("boat", [])
	if bt.size() == 3:
		var n := LakeVisuals.boat_node(b, "valya-lake-boat",
			Vector3(float(bt[0]), float(bt[1]), float(bt[2])),
			float(lk.get("boat_yaw", 0.0)))
		b.decor["valya-lake-boat"] = n
		out["nodes"]["lake-boat"] = n

	var stakes: Array = lk.get("stakes", [])
	if stakes.size() >= 2:
		var n2 := _holder(b, "lake-net", Vector3.ZERO)
		for p: Variant in stakes:
			if not (p is Array) or (p as Array).size() < 2:
				continue
			var a: Array = p
			_piece(n2, _box(b, Vector3(0.06, 1.05, 0.06), "log"),
				Vector3(float(a[0]), 0.42, float(a[1])))
		# Полотно сети между крайними кольями — сетчатая текстура забора:
		# другой сквозной у нас нет, а сеть обязана быть сквозной.
		var a0: Array = stakes[0]
		var a1: Array = stakes[stakes.size() - 1]
		var mid := Vector3((float(a0[0]) + float(a1[0])) / 2.0, 0.62,
			(float(a0[1]) + float(a1[1])) / 2.0)
		var dx := float(a1[0]) - float(a0[0])
		var dz := float(a1[1]) - float(a0[1])
		var mesh := PlaneMesh.new()
		mesh.size = Vector2(sqrt(dx * dx + dz * dz), 0.75)
		mesh.orientation = PlaneMesh.FACE_Z
		mesh.material = b.mats.mesh_fence()
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.position = mid
		mi.rotation = Vector3(0.0, atan2(dx, dz) + PI / 2.0, 0.0)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		n2.add_child(mi)
		out["nodes"]["lake-net"] = n2

	var dw: Array = lk.get("duckweed", [])
	if dw.size() == 4:
		var n3 := _holder(b, "lake-duckweed",
			Vector3((float(dw[0]) + float(dw[1])) / 2.0, 0.0,
				(float(dw[2]) + float(dw[3])) / 2.0))
		_piece(n3, _box(b, Vector3(float(dw[1]) - float(dw[0]), 0.02,
			float(dw[3]) - float(dw[2])), "", 0x4d6134), Vector3(0.0, 0.0, 0.0))
		out["nodes"]["lake-duckweed"] = n3


# ------------------------------------------------------------ примитивы ----

static func _holder(b: WorldBuilder, id: String, pos: Vector3,
		shown := true) -> Node3D:
	var n := Node3D.new()
	n.name = "valya-" + id
	n.position = pos
	n.visible = shown
	b.decor["valya-" + id] = n
	return n


static func _piece(parent: Node3D, mesh: Mesh, at: Vector3,
		rot := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = at
	mi.rotation = rot
	# Тень отсюда не отбрасывает ничто: см. фазу 15, часть 1 — теневой атлас
	# луны и так был главной статьёй расхода кадра.
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


static func _box(b: WorldBuilder, size: Vector3, key: String,
		exact_hex := -1) -> BoxMesh:
	var m := BoxMesh.new()
	m.size = size
	m.material = b.mats.flat(exact_hex, true) if exact_hex >= 0 \
		else b.mats.get_mat(key)
	return m

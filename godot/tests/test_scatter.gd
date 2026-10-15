# Зелень MultiMesh'ем: раскладка, которая обязана быть одинаковой (фаза 14).
#
# Scatter — единственный модуль фазы, который ставит геометрию НЕ по данным,
# а по правилу. Правило легко нарушить незаметно, поэтому проверяется всё
# сразу и на живом мире, а не на выдуманном.
#
# 1. ДЕТЕРМИНИЗМ. Мир собирается дважды, и обе раскладки сравниваются числом
#    к числу. Один randf() вместо sin() — и кадры, снятые вчера, перестают
#    совпадать с сегодняшними, а понять это по картинке нельзя.
#
# 2. НИЧЕГО ВНУТРИ ТВЁРДОГО. Куст в стене сарая видно только оттуда, куда
#    игрок не заходит.
#
# 3. НИЧЕГО В ПОЛОСЕ ДЕДА И В КОЛЬЦЕ АРКАДИЯ. Границы взяты не из scatter.json,
#    а из тех же чисел, что сторожит test_street_clear.gd: иначе тест
#    проверял бы данные сами против себя.
#
# 4. НИЧЕГО НА ДОРОГЕ И В ПРОЁМАХ. Полосы CLEAR — контракт: по ним ходят.
#
# 5. ВСЁ ВНУТРИ СВОИХ ПЛОЩАДОК. Вид, объявленный «только на околице», не имеет
#    права вырасти во дворе.
#
# 6. НИЧЕГО ВНУТРИ ПОМЕЩЕНИЯ (фаза 15). Отдельно от пункта 2, и вот почему:
#    куст, выпавший в комнату, стоит в ВОЗДУХЕ между полом и потолком, и
#    проба «внутри твёрдого» его пропускает — снизу пусто, сверху пусто.
#    Ровно так на половицах вырос куст с цветами, который Пётр увидел первым.
#    Прямоугольники считаются здесь заново, а не спрашиваются у Scatter:
#    тест, зовущий проверяемый код, проверяет сам себя.
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_scatter.gd
extends SceneTree

# Полоса, по которой дед ходит в главе ТЕМНОТА (street_stalk.gd: LANE_Z -3.2,
# LANE_HALF 2.30) и кольцо, по которому ходит Аркадий. Числа продублированы
# сознательно: тест обязан падать, если их поменяют в данных.
const LANE_Z0 := -5.50
const LANE_Z1 := -0.90
const RING_Z0 := -6.20
const RING_Z1 := -0.30
const LANE_X0 := -30.0
const LANE_X1 := 26.0

# Ручная береговая постановка: эти предметы по замыслу стоят в иле или прямо
# в мелководье сюжетного пруда. Новые водные blockers запрещают туда идти
# игроку, но не делают намеренный aquatic dressing ошибкой Scatter.
const AQUATIC_HAND_OK := {
	"nat-grass-tall": true,
	"ok-barrel-rust": true,
	"ok-can": true,
	"ok-lily": true,
	"ok-rocks": true,
}


func _initialize() -> void:
	var errs: Array[String] = []
	var w := _build()
	var col: CollisionWorld = w["col"]
	var sc: Dictionary = (w["built"] as Dictionary).get("scatter", {}) as Dictionary

	if sc.is_empty() or int(sc.get("instances", 0)) == 0:
		print("FAIL test_scatter: Scatter не собрался — нет data/scatter.json?")
		_drop(w)
		quit(1)
		return

	var d := Scatter.data()
	var clear: Array = d.get("CLEAR", [])
	var areas_all: Dictionary = d.get("AREAS", {})
	var layout: Dictionary = sc.get("layout", {}) as Dictionary

	var rooms := _rooms()

	var total := 0
	for k: Dictionary in d.get("KINDS", []):
		var name := String(k.get("m", ""))
		var rows: Array = layout.get(name, [])
		var n := rows.size() / 5
		total += n
		if n == 0:
			errs.append("вид «%s»: ни одного инстанса" % name)
			continue
		# Меньше половины заказанного — раскладка задыхается: либо площадки
		# заставлены, либо gap великоват. Молча недосадить хуже, чем упасть.
		var want := int(k.get("count", 0))
		if want > 0 and n < want / 2:
			errs.append("вид «%s»: поставлено %d из %d — раскладке негде"
				% [name, n, want])
		var mine: Array = []
		for key: String in k.get("areas", []):
			for r: Array in areas_all.get(key, []):
				mine.append(r)
		# Экземпляры, поставленные руками (поле at), идут в раскладке первыми
		# и от двух проверок освобождены — от площадок и от CLEAR. Это не
		# дыра: обе проверки сторожат СЛУЧАЙНУЮ раскладку, у которой места
		# никто не выбирал. Бидон, положенный в обочину нарочно, коллизии
		# не имеет вовсе (MultiMesh) и пройти по ней не мешает. Всё
		# остальное — полоса деда, кольцо Аркадия, твёрдое — спрашивается
		# с них наравне: там дело не в красоте, а в погоне.
		var hand := int((k.get("at", []) as Array).size())
		for i in n:
			var x := float(rows[i * 5])
			var z := float(rows[i * 5 + 2])
			var by_hand := i < hand
			if not by_hand and _in(x, z, clear):
				errs.append("«%s» [%.2f, %.2f] стоит в полосе CLEAR" % [name, x, z])
				break
			if x >= LANE_X0 and x <= LANE_X1 \
					and ((z >= LANE_Z0 and z <= LANE_Z1) or (z >= RING_Z0 and z <= RING_Z1)):
				errs.append("«%s» [%.2f, %.2f] стоит в полосе деда" % [name, x, z])
				break
			if not by_hand and not _in(x, z, mine):
				errs.append("«%s» [%.2f, %.2f] выросло вне своих площадок" % [name, x, z])
				break
			if col.point_hit(x, 0.25, z, CollisionWorld.ALL_SOLID) \
					or col.point_hit(x, 0.40, z, CollisionWorld.ALL_SOLID) \
					or col.point_hit(x, 1.20, z, CollisionWorld.ALL_SOLID):
				# Крупный объект имеет право стоять внутри СОБСТВЕННОГО объявленного
				# proxy; чужой proxy или любая иная твёрдая геометрия всё ещё ошибка.
				if not _scatter_proxy(sc, x, z) \
						and not (by_hand and AQUATIC_HAND_OK.has(name)):
					errs.append("«%s» [%.2f, %.2f] стоит внутри твёрдого" % [name, x, z])
					break
			# Поставленный руками — по-прежнему исключение: поленница внутри
			# амбара лежит там нарочно, и это единственный способ положить
			# что-нибудь в помещение осознанно. Спрашивается со СЛУЧАЙНОЙ
			# раскладки, у которой места никто не выбирал.
			var room := "" if by_hand else _room_at(rooms, x, z)
			if room != "":
				errs.append("«%s» [%.2f, %.2f] стоит в помещении «%s»"
					% [name, x, z, room])
				break

	if total != int(sc.get("instances", 0)):
		errs.append("счётчик инстансов %d, а в раскладках %d"
			% [int(sc.get("instances", 0)), total])

	# ---- детерминизм ----
	_drop(w)
	var w2 := _build()
	var sc2: Dictionary = (w2["built"] as Dictionary).get("scatter", {}) as Dictionary
	var layout2: Dictionary = sc2.get("layout", {}) as Dictionary
	if layout.size() != layout2.size():
		errs.append("во второй сборке видов %d, а было %d" % [layout2.size(), layout.size()])
	else:
		for name: String in layout.keys():
			var a: Array = layout[name]
			var b2: Array = layout2.get(name, [])
			if a.size() != b2.size():
				errs.append("вид «%s»: во второй сборке %d чисел, а было %d"
					% [name, b2.size(), a.size()])
				continue
			for i in a.size():
				if float(a[i]) != float(b2[i]):
					errs.append("вид «%s»: число %d разошлось (%.9f против %.9f)"
						% [name, i, float(a[i]), float(b2[i])])
					break
	_drop(w2)

	print("зелени: %d инстансов, %d видов, %d draw call"
		% [total, layout.size(), int(sc.get("surfaces", 0))])
	if errs.is_empty():
		print("test_scatter: PASS")
		quit(0)
		return
	print("FAIL test_scatter: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


func _scatter_proxy(sc: Dictionary, x: float, z: float) -> bool:
	for p: Dictionary in sc.get("collision_proxies", []):
		var box: Array = p.get("box", [])
		if box.size() == 6 and x >= float(box[0]) and x <= float(box[1]) \
				and z >= float(box[4]) and z <= float(box[5]):
			return true
	return false


# Помещения: комнаты site.json с высотой и зоны с НЕуличной реверберацией.
# Второй источник обязателен — баня, погреб, амбар и клуб живут не в ROOMS,
# а в ZONES овердеев, и к концу сборки они уже дописаны в site["ZONES"].
# Возвращает [[x0, x1, z0, z1, имя], ...]: имя нужно, чтобы в отчёте было
# видно, КУДА выросло, а не только что куда-то выросло.
func _rooms() -> Array:
	var out: Array = []
	var site := GameData.site()
	var all_rooms: Dictionary = site.get("ROOMS", {})
	for key: String in all_rooms.keys():
		var r: Dictionary = all_rooms[key]
		if float(r.get("h", 0.0)) <= 0.01:
			continue
		var rx: Array = r["x"]
		var rz: Array = r["z"]
		out.append([float(rx[0]), float(rx[1]), float(rz[0]), float(rz[1]), key])
	for zn: Variant in site.get("ZONES", []):
		if not (zn is Dictionary):
			continue
		var z: Dictionary = zn
		if String(z.get("reverb", "outdoor")) == "outdoor":
			continue
		var rect: Array = z.get("rect", [])
		if rect.size() < 4:
			continue
		out.append([float(rect[0]), float(rect[1]), float(rect[2]), float(rect[3]),
			String(z.get("id", "?"))])
	return out


func _room_at(rooms: Array, x: float, z: float) -> String:
	for r: Array in rooms:
		if x >= float(r[0]) and x <= float(r[1]) and z >= float(r[2]) and z <= float(r[3]):
			return String(r[4])
	return ""


func _in(x: float, z: float, rects: Array) -> bool:
	for r: Array in rects:
		if x >= float(r[0]) and x <= float(r[1]) and z >= float(r[2]) and z <= float(r[3]):
			return true
	return false


func _build() -> Dictionary:
	var mats := Materials.new()
	mats.load_all()
	var col := CollisionWorld.new()
	var root := Node3D.new()
	var built := WorldBuilder.build(root, mats, col)
	return {"col": col, "root": root, "built": built}


func _drop(w: Dictionary) -> void:
	(w["root"] as Node3D).free()

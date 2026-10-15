# Переходы между слоями навграфа — то, чего у деда не было вовсе.
#
# ЗАЧЕМ. Навграф фазы 2 разложен по пяти слоям (plot, floor1, attic, roof,
# cellar), и межслойных рёбер в нём ноль: лестница, крыльцо и оба люка
# в граф не попали, потому что рёбра там пришлось бы вести по наклонной,
# а построение графа плоское. Дед из-за этого между этажами не ходил вовсе —
# он телепортировался раз в 6–10 секунд (_relocate). Это и читалось как
# «статично ходит»: фигура появлялась там, где ты, и ты не видел как.
#
# ПОЧЕМУ ОТДЕЛЬНАЯ ТАБЛИЦА, А НЕ РЁБРА В ГРАФЕ. parity/nav_graph.json — эталон
# из живой браузерной игры, его сверяет приёмка, и дописать в него четыре ребра
# значит переснять эталон целиком. Здесь вместо этого пять полей на переход:
# два конца-узла в разных слоях, ломаная между ними, блокер, если по дороге
# дверь, и цена в секундах. Планирование двухуровневое: сначала цепочка
# переходов по слоям (граф из четырёх рёбер, обход в ширину), потом обычный A*
# внутри каждого слоя.
#
# ЧЕТЫРЕ, А НЕ ПЯТЬ. Нижний и верхний марши лестницы — один переход: между ними
# площадка на отметке 2.05, а её нет в навграфе ни узлом, ни слоем, и резать
# переход надвое не по чему. Ломаная проходит площадку пятью точками.
#
# Нет файла data/nav_links.json — links пуст, chain() всегда возвращает пустое,
# и дед ведёт себя ровно как в фазе 6: телепорт между этажами и никаких
# переходов. Это тот же откат, что у звука фаз 5–6.
class_name NavLinks
extends RefCounted

const PATH := "res://data/nav_links.json"

# [{id, a, b, cost, needs_open, points: Array[Vector3]}]
var links: Array = []

var _from_layer: Dictionary = {}   # слой -> [индекс перехода]
var _layers: Dictionary = {}       # id перехода -> [слой a, слой b]


static func load_all() -> NavLinks:
	var nl := NavLinks.new()
	nl._read()
	return nl


func _read() -> void:
	if not FileAccess.file_exists(PATH):
		return
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	if not (parsed is Dictionary):
		return
	var raw: Variant = (parsed as Dictionary).get("LINKS", [])
	if not (raw is Array):
		return
	for r: Variant in raw:
		if not (r is Dictionary):
			continue
		var d: Dictionary = r
		var pts: Array = []
		for p: Variant in d.get("points", []):
			if p is Array and (p as Array).size() >= 3:
				var a: Array = p
				pts.append(Vector3(float(a[0]), float(a[1]), float(a[2])))
		if pts.is_empty():
			continue
		links.append({
			"id": String(d.get("id", "")),
			"a": String(d.get("a", "")),
			"b": String(d.get("b", "")),
			"cost": float(d.get("cost", 10.0)),
			"needs_open": String(d.get("needsOpen", "")),
			"points": pts,
		})


## Разложить переходы по слоям. Слои берутся у настоящих узлов графа, а не
## из имени: имя узла — деталь построения, и однажды оно поменяется.
func bind(nav: NavGraph) -> void:
	_from_layer = {}
	_layers = {}
	if nav == null:
		return
	var keep: Array = []
	for l: Dictionary in links:
		var na: Variant = nav.node(String(l["a"]))
		var nb: Variant = nav.node(String(l["b"]))
		if na == null or nb == null:
			push_warning("nav_links: у перехода %s нет узла %s или %s"
				% [l["id"], l["a"], l["b"]])
			continue
		var la := String((na as Dictionary)["layer"])
		var lb := String((nb as Dictionary)["layer"])
		if la == lb:
			push_warning("nav_links: переход %s ведёт внутри слоя %s" % [l["id"], la])
			continue
		var idx := keep.size()
		keep.append(l)
		_layers[l["id"]] = [la, lb]
		for lay: String in [la, lb]:
			if not _from_layer.has(lay):
				_from_layer[lay] = []
			(_from_layer[lay] as Array).append(idx)
	links = keep


func layers_of(link: Dictionary) -> Array:
	return _layers.get(String(link["id"]), [])


## Цепочка переходов из слоя в слой. Возвращает список
## [{link, from, to, node_from, node_to}] — по одному шагу на переход.
## usable — что сейчас разрешено брать (запертая входная дверь, например).
## Обход в ширину: переходов четыре, и любая цепочка короче трёх шагов.
func chain(from_layer: String, to_layer: String, usable: Callable) -> Array:
	if from_layer == to_layer or links.is_empty():
		return []
	var came: Dictionary = {from_layer: null}
	var queue: Array = [from_layer]
	while not queue.is_empty():
		var cur: String = queue.pop_front()
		for idx: int in _from_layer.get(cur, []):
			var l: Dictionary = links[idx]
			if usable.is_valid() and not bool(usable.call(l)):
				continue
			var pair: Array = _layers[String(l["id"])]
			var forward: bool = String(pair[0]) == cur
			var next: String = String(pair[1]) if forward else String(pair[0])
			if came.has(next):
				continue
			came[next] = {
				"link": l,
				"from": cur,
				"to": next,
				"node_from": String(l["a"]) if forward else String(l["b"]),
				"node_to": String(l["b"]) if forward else String(l["a"]),
				"forward": forward,
			}
			if next == to_layer:
				return _unwind(came, to_layer)
			queue.append(next)
	return []


func _unwind(came: Dictionary, to_layer: String) -> Array:
	var out: Array = []
	var cur := to_layer
	while came.get(cur) != null:
		var step: Dictionary = came[cur]
		out.push_front(step)
		cur = String(step["from"])
	return out


## Точки ломаной в порядке движения. forward — идём от a к b.
func points(link: Dictionary, forward: bool) -> Array:
	var pts: Array = (link["points"] as Array).duplicate()
	if not forward:
		pts.reverse()
	return pts

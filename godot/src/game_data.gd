# Доступ к конвертированным данным прототипа (data/*.json).
# Источник правды — src/data/*.js браузерной игры; руками эти JSON не правятся.
class_name GameData

static var _cache: Dictionary = {}

static func _load(name: String) -> Dictionary:
	if _cache.has(name):
		return _cache[name]
	var f := FileAccess.open("res://data/%s.json" % name, FileAccess.READ)
	assert(f != null, "нет data/%s.json — прогнать tools/convert_data.mjs" % name)
	var parsed: Variant = JSON.parse_string(f.get_as_text())
	assert(parsed is Dictionary, "битый data/%s.json" % name)
	_cache[name] = parsed
	return parsed

static func site() -> Dictionary: return _load("site")
static func props() -> Dictionary:
	# Положение/поворот/семейство машин и их коллизии берутся из PLOTS.car.
	# Пересборка списка сохраняет тестовый сценарий SntWorld._cache = {}.
	var data := _load("props").duplicate(true)
	var items: Array = []
	for prop: Dictionary in data["PROPS"]:
		if not prop.has("_snt"):
			items.append(prop)
	for plot: Dictionary in SntWorld.data().get("PLOTS", []):
		if not (plot.get("car", {}) as Dictionary).is_empty():
			items.append(VehicleVisuals.prop_def(plot))
	data["PROPS"] = items
	return data
static func nav() -> Dictionary: return _load("nav")
## Кассеты с наложенным оверлеем data/tapes_ext.json (фаза 13).
##
## ЗАЧЕМ ОВЕРЛЕЙ. data/tapes.json заморожен, и не по привычке: тексты его
## реплик держат sha1 файлов озвучки (voice_manifest.json), а времена событий
## держат окна tape_windows. Правка одной буквы там валит test_voice_manifest
## и оставляет полсотни осиротевших ogg. Кассету при этом заменить надо
## целиком — у новой плёнки другие сцены, другие времена и другое число
## реплик, полумерами не обойтись.
##
## Слияние идёт по кассете, а не по полю: ключ TAPES из оверлея КЛАДЁТСЯ
## ПОВЕРХ одноимённого. Это одна функция и один проход, и на ней держится
## всё остальное — меню кассет (main.gd читает GameData.tapes()), плеер,
## tools/gen_voice.py и тесты видят уже слитую картину и про оверлей ничего
## не знают. Нет файла — поведение ровно прежнее, до последнего знака.
static func tapes() -> Dictionary:
	if _cache.has("tapes+ext"):
		return _cache["tapes+ext"]
	var base: Dictionary = _load("tapes")
	var merged: Dictionary = base
	var f := FileAccess.open("res://data/tapes_ext.json", FileAccess.READ)
	if f != null:
		var parsed: Variant = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			merged = base.duplicate(true)
			var ext: Dictionary = parsed
			var into: Dictionary = merged.get("TAPES", {})
			for id: Variant in (ext.get("TAPES", {}) as Dictionary):
				into[String(id)] = (ext["TAPES"] as Dictionary)[id]
			merged["TAPES"] = into
			# Порядок в меню оверлей тоже вправе переписать, но не обязан:
			# замена одной плёнки на её месте порядка не меняет вовсе.
			var order: Variant = ext.get("TAPE_ORDER", null)
			if order is Array:
				merged["TAPE_ORDER"] = order
		else:
			push_warning("tapes_ext.json не разобран как объект — плёнки как в фазе 8")
	_cache["tapes+ext"] = merged
	return merged

static func shots() -> Dictionary: return _load("shots")
static func texts() -> Dictionary: return _load("texts")

# Цвета в данных — целые 0xRRGGBB (наследие three.js).
static func color(n: int) -> Color:
	return Color8((n >> 16) & 255, (n >> 8) & 255, n & 255)

static func vec3(a: Array) -> Vector3:
	return Vector3(a[0], a[1], a[2])

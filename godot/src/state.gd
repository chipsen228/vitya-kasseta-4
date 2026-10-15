# Состояние прохождения (порт game/state.js).
#
# Флаги — обычное множество строк, а не два десятка булевых полей: так их видно
# разом в отладке и не приходится помнить, что `hasFuse` на самом деле называется
# `powerOn`. Ровно эта путаница ломала инвентарь в старой версии.
#
# snapshot/restore снимают состояние целиком, а не по полям. После третьего
# провала главы «R» должно возвращать в ту же точку, а не в ту же точку
# с потраченными флагами.
#
# ИМЕНА. Поля и методы оставлены как в state.js (chapterTime, tapesWatched,
# hasItem, atLeast...): это самый общий объект игры, и main.gd, ai.gd, phone.gd
# переносят обращения к нему дословно из JS. Единственное исключение вынужденное:
# set(flag) переименован в set_flag(flag) — переопределять Object.set() GDScript
# не даёт (native_method_override у Годо по умолчанию ошибка, а не предупреждение).
#
# Множества JS (Set) стали Dictionary: добавление `d[key] = true`, проверка
# `d.has(key)`, размер `d.size()`. Своего Set в GDScript нет, а Array дал бы
# линейный поиск на каждом кадре в find()/task().

class_name GameState
extends RefCounted

# ПОРЯДОК ГЛАВ — ЭТО КОНТРАКТ. По нему считается atLeast(), по нему же
# tests/test_dread.gd и tests/test_omens.gd решают, не проскочил ли акцент
# раньше 23:40. Вставка главы сдвигает индексы у ВСЕХ, кто зовёт atLeast, —
# поэтому 'street' встала ровно между 'tapes' и 'dark', и ни одно прежнее
# сравнение от этого не поменяло смысла: всё, что было «не раньше ТЕМНОТЫ»,
# осталось не раньше ТЕМНОТЫ.
#
# ФАЗА 12: 'village' встала между 'dark' и 'gate'. atLeast() работает по имени,
# а не по числу, поэтому ни одно существующее сравнение смысла не поменяло:
# всё, что было «не раньше ТЕМНОТЫ», осталось не раньше ТЕМНОТЫ, а всё, что
# было «не раньше ВОРОТ», теперь просто наступает на одну главу позже.
const CHAPTERS := ["prologue", "arrive", "light", "loft", "tapes", "street",
	"dark", "village", "gate", "end"]

# Отметка на плёнке в начале каждой главы, в секундах от полуночи.
const CLOCK := {
	"prologue": 20 * 3600 + 41 * 60,
	"arrive": 20 * 3600 + 41 * 60,
	"light": 21 * 3600 + 5 * 60,
	"loft": 21 * 3600 + 50 * 60,
	"tapes": 22 * 3600 + 30 * 60,
	# УЛИЦА — самая длинная глава игры (двадцать с лишним минут), и на плёнке
	# она обязана занимать столько же: часы идут втрое быстрее реального
	# времени и упираются в начало следующей главы. Пятьдесят минут ленты
	# на 22:50…23:40 — это ровно семнадцать минут за воротами до потолка.
	"street": 22 * 3600 + 50 * 60,
	"dark": 23 * 3600 + 40 * 60,
	# ДЕРЕВНЯ включает последний обход СНТ: девяносто минут ленты
	# до ворот. Внутри главы время по-прежнему идёт втрое быстрее.
	"village": 24 * 3600 + 20 * 60,
	"gate": 25 * 3600 + 50 * 60,
	"end": 26 * 3600 + 30 * 60,
}

# Внутри главы время идёт втрое быстрее реального и упирается в начало следующей:
# иначе за двадцать одну минуту игры до 23:40 не доехать.
const RATE := 3.0

var chapter := "prologue"
var chapterTime := 0.0
var flags: Dictionary = {}
var inventory: Dictionary = {}
var tapesWatched: Dictionary = {}
var callsMade: Dictionary = {}
var looked: Dictionary = {}
var task: Variant = null
var taskShownAt := -99.0
var failCount := 0
var ending: Variant = null
var evidence := false
var threatState := "absent"
var hidden := false
# Контрольная точка объявлена здесь, чтобы «Начать заново» её обнуляло.
# Без объявления она до первого go() читалась как undefined и переживала сброс —
# новая игра откатывалась в главу прошлого прохождения.
var checkpoint: Variant = null
# Только runtime-инвалидация производных систем. В snapshot не входит и формат
# сохранения не меняет; HeldItems по ней избегает кадровых Array/Dictionary.
var runtime_revision := 0
var horror_seen: Dictionary = {}
var recovery: Dictionary = {}
var recovery_completed_count := 0


func _init() -> void:
	reset()


func reset() -> GameState:
	chapter = "prologue"
	chapterTime = 0.0
	flags = {}
	inventory = {}
	tapesWatched = {}
	callsMade = {}
	looked = {}
	task = null
	taskShownAt = -99.0
	failCount = 0
	ending = null
	evidence = false
	threatState = "absent"
	hidden = false
	checkpoint = null
	horror_seen = {}
	recovery = {}
	recovery_completed_count = 0
	runtime_revision += 1
	return self


func has(flag: String) -> bool:
	return flags.has(flag)


# Это state.set() оригинала. Имя занято Object.set() — см. шапку файла.
func set_flag(flag: String, on := true) -> GameState:
	if on:
		if not flags.has(flag):
			flags[flag] = true
			runtime_revision += 1
	else:
		if flags.erase(flag):
			runtime_revision += 1
	return self


func toggle(flag: String) -> bool:
	if flags.has(flag):
		flags.erase(flag)
	else:
		flags[flag] = true
	runtime_revision += 1
	return flags.has(flag)


func give(item: String) -> GameState:
	if not inventory.has(item):
		inventory[item] = true
		runtime_revision += 1
	return self


func hasItem(item: String) -> bool:
	return inventory.has(item)


func chapterIndex() -> int:
	return CHAPTERS.find(chapter)


func atLeast(ch: String) -> bool:
	return chapterIndex() >= CHAPTERS.find(ch)


func tick(dt: float) -> void:
	chapterTime += dt


# Непрерывное время на плёнке. После полуночи оно остаётся больше 86400:
# освещение должно отличать 00:20 следующего дня от утра до приезда.
func clock_seconds() -> float:
	var start := float(CLOCK.get(chapter, CLOCK["arrive"]))
	var nxt := start + 3600.0
	var i := chapterIndex() + 1
	if i >= 0 and i < CHAPTERS.size():
		var name: String = CHAPTERS[i]
		if CLOCK.has(name) and float(CLOCK[name]) > start:
			nxt = float(CLOCK[name])
	return minf(nxt - 30.0, start + chapterTime * RATE)


# Строка таймкода для HUD форматирует непрерывные секунды по модулю суток.
func timecode() -> String:
	var s := int(floor(clock_seconds())) % 86400
	return "%02d:%02d:%02d" % [s / 3600, (s / 60) % 60, s % 60]


# checkpoint сюда не входит намеренно. Chapters.go() пишет
# state.checkpoint = snapshot(), и если снимок начнёт включать предыдущий снимок,
# каждая глава удвоит строку: к седьмой это сотня килобайт JSON на пустом месте.
func snapshot() -> String:
	return JSON.stringify({
		"chapter": chapter,
		"chapterTime": chapterTime,
		"flags": flags.keys(),
		"inventory": inventory.keys(),
		"tapesWatched": tapesWatched.keys(),
		"callsMade": callsMade.keys(),
		"looked": looked.keys(),
		"task": task,
		"failCount": failCount,
		"evidence": evidence,
		"threatState": threatState,
		"horror_seen": horror_seen.keys(),
		"recovery": recovery,
		"recovery_completed_count": recovery_completed_count,
	})


func restore(json: String) -> GameState:
	var parsed: Variant = JSON.parse_string(json)
	if not (parsed is Dictionary):
		push_warning("state: битый снимок, откат пропущен")
		return self
	var d: Dictionary = parsed
	# Старые модули помечают одноразовые моменты флагами. Сохраняем только
	# эту историю, сюжетные флаги ниже по-прежнему восстанавливаем из снимка.
	for flag: String in flags:
		if flag.begins_with("startle-") or flag.begins_with("dread-") or flag.begins_with("omen-"):
			horror_seen[flag] = true
	chapter = String(d.get("chapter", "prologue"))
	chapterTime = float(d.get("chapterTime", 0.0))
	flags = _set_of(d.get("flags", []))
	inventory = _set_of(d.get("inventory", []))
	tapesWatched = _set_of(d.get("tapesWatched", []))
	callsMade = _set_of(d.get("callsMade", []))
	looked = _set_of(d.get("looked", []))
	task = d.get("task", null)
	failCount = int(d.get("failCount", 0))
	evidence = bool(d.get("evidence", false))
	threatState = String(d.get("threatState", "absent"))
	# Пройденные постановки переживают откат; новую игру очищает reset().
	horror_seen.merge(_set_of(d.get("horror_seen", [])), true)
	for id: String in horror_seen:
		if id.begins_with("startle-") or id.begins_with("dread-") or id.begins_with("omen-"):
			flags[id] = true
	var old_recovery: Variant = d.get("recovery", {})
	recovery = old_recovery.duplicate(true) if old_recovery is Dictionary else {}
	recovery_completed_count = maxi(recovery_completed_count, int(d.get("recovery_completed_count", 0)))
	hidden = false
	ending = null
	runtime_revision += 1
	# checkpoint не трогаем: его сразу после restore выставляет Chapters.retry().
	# Обнулить здесь значит потерять точку возврата на втором же провале.
	return self


static func _set_of(items: Variant) -> Dictionary:
	var out: Dictionary = {}
	if items is Array:
		for k: Variant in items:
			out[String(k)] = true
	return out

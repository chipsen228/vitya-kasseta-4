# Глава ВОРОТА как проходимая комната (фаза 17).
#
# ЗАЧЕМ ОТДЕЛЬНЫЙ ТЕСТ, КОГДА ЕСТЬ test_reachable И smoke_final.
#
# test_reachable перед заливкой ОТКРЫВАЕТ ВСЕ БЛОКЕРЫ РАЗОМ — иначе он ругался
# бы на каждую запертую по сюжету дверь. То есть к дефекту, ради которого
# написан этот файл, он слеп по построению.
#
# smoke_final.gd ходит подстановкой interact.target, то есть телепортом, и
# забора не касается вовсе: у него сумка на веранде берётся из точки у машины.
#
# ДЕФЕКТ. Калитка участка (site.json FENCES, id "wicket") встаёт твёрдой в
# world_builder.gd и не гасится НИКОГДА: set_blocker_active("wicket", …) не
# зовётся ни из одного модуля. Глава ВОРОТА при этом начинается СНАРУЖИ участка
# (игрок у капота) и первым же делом снова запирает ворота — а первая её задача
# отправляет в дом за кассетами. Порядок принудительно обратный объявленному.
#
# ТРИ УТВЕРЖДЕНИЯ.
#   1. Глава ВОРОТА обязана калитку ОТПЕРЕТЬ. Строка про неё написана давно:
#      LOOKS.wicket — «Калитка не заперта. Она тут отродясь не запиралась».
#   2. При твёрдой калитке и закрытых воротах от капота до сумки НЕ ДОЙТИ.
#   3. При погашенной — тот же путь обязан пройти. Односторонняя проверка
#      пропустила бы и вечно запертую калитку, и калитку-декорацию.
#
# Заливка та же, что в test_reachable: капсула радиуса 0.30, рост 1.78, порог
# шага Player.STEP_UP. Маска ALL_SOLID — все четыре набора, иначе «проход есть»
# значило бы «нет стен участка», а не «игрок пройдёт».
#
# Прогон:
#   Godot_v4.7.1-stable_win64_console.exe --headless --path godot \
#       --script res://tests/test_gate_room.gd
extends SceneTree

const BOOT_FRAMES := 600

const R := 0.30              # радиус капсулы игрока (player.gd RADIUS)
const H := 1.78              # рост
const CELL := 0.25           # шаг сетки заливки
const CLIMB := 0.25          # player.gd STEP_UP — ровно он
const DROP := 1.40
const NO_FLOOR := -1.0e30
const LIMIT := 60000

# Рамка заливки: участок целиком (site.json FENCES, x [-9.5, 10.5], z [0, 30])
# плюс полоса улицы перед воротами, где стоит машина.
const X0 := -10.4
const X1 := 11.4
const Z0 := -6.4
const Z1 := 20.0

# Капот. Ровно та точка, с которой начинается глава: interact.gd 'car-drive'
# стоит на (1.1, -3.6), крышка капота — на полметра ближе к забору.
const HOOD := Vector2(1.10, -3.35)
# Сумка на веранде: interact.gd 'final-bag', pos (-1.10, 1.02, 9.15).
const BAG := Vector2(-1.10, 9.15)
# Насколько близко к сумке обязана подойти заливка, чтобы считать «дошёл».
# Радиус точки 1.9 м, но полтора метра — это уже «стоит рядом».
const NEAR := 1.50

const DIRS := [[CELL, 0.0], [-CELL, 0.0], [0.0, CELL], [0.0, -CELL]]

var _col: CollisionWorld = null


func _initialize() -> void:
	_run()


func _run() -> void:
	var scene: PackedScene = load("res://src/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)

	var waited := 0
	while main.get("chapters") == null and waited < BOOT_FRAMES:
		await process_frame
		waited += 1
	if main.get("chapters") == null:
		printerr("test_gate_room: боут не завершился")
		quit(1)
		return

	main.call("_start_game")
	await process_frame

	var state: GameState = main.get("state")
	var chapters: Chapters = main.get("chapters")
	var ui: Overlays = main.get("ui")
	_col = main.get("col")

	var errs: Array[String] = []

	# ---- 1. глава ВОРОТА отпирает калитку ----
	state.give("flashlight")
	state.give("car-key")
	state.give("chain-key")
	state.set_flag("tank-full")
	chapters.go("gate")
	await _cards(ui)
	if state.chapter != "gate":
		errs.append("go('gate') не встало: глава %s" % state.chapter)
	if _col.is_blocker_active("gate"):
		pass        # цепь накинута — так и задумано, см. _gate_enter
	else:
		errs.append("глава ВОРОТА не накинула цепь: ворота открыты с порога")
	if _col.is_blocker_active("wicket"):
		errs.append("глава ВОРОТА не отперла калитку: игрок стоит у капота "
			+ "СНАРУЖИ участка, ворота заперты цепью, а первая задача главы — "
			+ "в дом за кассетами. Пройти нечем")
	var built: Dictionary = main.get("built")
	var wicket_node: Node3D = null
	var gate_node: Node3D = null
	for blocker: Dictionary in built.get("blockers", []):
		var id := String(blocker.get("id", ""))
		var box: AABB = blocker.get("box", AABB())
		if id == "wicket":
			wicket_node = blocker.get("node") as Node3D
			if box.position.distance_to(Vector3(2.36, 0.0, -0.04)) > 0.001 \
					or box.size.distance_to(Vector3(1.28, 1.50, 0.08)) > 0.001:
				errs.append("закрытая AABB калитки изменила базовый контракт")
		elif id == "gate":
			gate_node = blocker.get("node") as Node3D
			if box.position.distance_to(Vector3(-1.64, 0.0, -0.04)) > 0.001 \
					or box.size.distance_to(Vector3(3.28, 1.60, 0.08)) > 0.001:
				errs.append("закрытая AABB ворот изменила базовый контракт")
	if wicket_node == null or wicket_node.get_node_or_null("WicketHinge") == null:
		errs.append("калитка не пересобрана вокруг крайнего шарнира")
	else:
		var hinge := wicket_node.get_node("WicketHinge") as Node3D
		if not is_equal_approx(hinge.rotation.y,
				float(hinge.get_meta("home", 0.0)) + 1.35):
			errs.append("визуальная калитка не открылась внутрь на 1.35 рад")
		main.call("_ctx_set_wicket", false, true)
		if not _col.is_blocker_active("wicket") \
				or not is_equal_approx(hinge.rotation.y, float(hinge.get_meta("home", 0.0))):
			errs.append("setWicket(false) не синхронизировал физику и шарнир")
		main.call("_ctx_set_wicket", true, true)
	if gate_node == null or gate_node.get_node_or_null("LeftHinge") == null \
			or gate_node.get_node_or_null("RightHinge") == null:
		errs.append("ворота не пересобраны на двух крайних шарнирах")

	# ---- 2 и 3. чем именно держит калитка ----
	# Дверь дома открыта, и это не поблажка: к главе ВОРОТА игрок провёл в доме
	# всю ночь и вышел из него на улицу. Её замок — предмет своих точек, здесь
	# он был бы вторым «нет» поверх того единственного, который проверяется.
	_col.set_blocker_active("door-front", false)
	_col.set_blocker_active("gate", true)

	_col.set_blocker_active("wicket", true)
	var shut := _reach()
	if shut["ok"]:
		errs.append("калитка активна, ворота закрыты — а до сумки всё равно "
			+ "дошли (%d клеток): проверка ничего не сторожит" % int(shut["cells"]))

	_col.set_blocker_active("wicket", false)
	var open := _reach()
	if not open["ok"]:
		errs.append("калитка погашена, а от капота [%.2f, %.2f] до сумки "
			% [HOOD.x, HOOD.y] + "[%.2f, %.2f] всё равно не дойти: залито %d клеток, "
			% [BAG.x, BAG.y, int(open["cells"])]
			+ "ближе %.2f м не подошли" % float(open["best"]))

	print("заливка: калитка твёрдая — %d клеток (ближе %.2f м), "
		% [int(shut["cells"]), float(shut["best"])]
		+ "погашена — %d клеток (ближе %.2f м)"
		% [int(open["cells"]), float(open["best"])])

	if errs.is_empty():
		print("test_gate_room: PASS")
		quit(0)
		return
	print("FAIL test_gate_room: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


# ------------------------------------------------------------- заливка ----

## Залить участок от капота и посмотреть, дошли ли до сумки. Возвращает
## {ok, cells, best}: best — с какого расстояния до сумки подошли ближе всего,
## по нему и видно, где именно путь оборвался.
func _reach() -> Dictionary:
	var fy0 := _floor_at(HOOD.x, HOOD.y, 2.6)
	if fy0 == NO_FLOOR:
		return {"ok": false, "cells": 0, "best": 1e9}

	var cx := PackedFloat64Array()
	var cz := PackedFloat64Array()
	var cy := PackedFloat64Array()
	var seen := {}
	cx.append(HOOD.x); cz.append(HOOD.y); cy.append(fy0)
	seen[_key(HOOD.x, HOOD.y)] = true

	var best := 1e9
	var head := 0
	while head < cx.size() and head < LIMIT:
		var x := cx[head]
		var z := cz[head]
		var y := cy[head]
		head += 1

		var d := Vector2(float(x) - BAG.x, float(z) - BAG.y).length()
		if d < best:
			best = d

		for dd: Array in DIRS:
			var nx: float = x + float(dd[0])
			var nz: float = z + float(dd[1])
			if nx < X0 or nx > X1 or nz < Z0 or nz > Z1:
				continue
			var k := _key(nx, nz)
			if seen.has(k):
				continue
			# Пол ищем ОТ ГОЛОВЫ текущей клетки: луч с трёх метров нашёл бы
			# навес крыльца, и заливка пошла бы поверх дома.
			var ny := _floor_at(nx, nz, y + H)
			if ny == NO_FLOOR:
				continue
			if ny - y > CLIMB or y - ny > DROP:
				continue
			if not _fits(nx, nz, ny):
				continue
			seen[k] = true
			cx.append(nx); cz.append(nz); cy.append(ny)

	return {"ok": best <= NEAR, "cells": cx.size(), "best": best}


func _key(x: float, z: float) -> int:
	return roundi(x / CELL) * 100003 + roundi(z / CELL)


func _floor_at(x: float, z: float, from_y: float) -> float:
	var hit := _col.ray_down(x, from_y, z, CollisionWorld.ALL_SOLID)
	if hit.is_empty():
		return NO_FLOOR
	return float(hit["y"])


## Помещается ли игрок ногами на (x, z, feet_y). Проба точкой — про
## вложенность: ЦЕЛИКОМ ВНУТРИ коробки капсула не даёт удара вовсе, и сплошной
## сруб читался бы открытой комнатой.
func _fits(x: float, z: float, feet_y: float) -> bool:
	if _col.point_hit(x, feet_y + 0.90, z, CollisionWorld.ALL_SOLID):
		return false
	var hit := _col.capsule_hit_d(x, feet_y + R + 0.03, z, x, feet_y + H - R, z, R,
		CollisionWorld.ALL_SOLID)
	if hit.is_empty():
		return true
	# Пол под ногами капсулу тоже задевает — стену отличаем по наклону нормали.
	return not (float(hit["depth"]) > 0.06 and absf(float(hit["ny"])) < 0.5)


func _cards(ui: Overlays) -> void:
	for _i in 40:
		if not ui.card.open:
			await process_frame
			continue
		ui.advanceCard()
		await process_frame
	await process_frame

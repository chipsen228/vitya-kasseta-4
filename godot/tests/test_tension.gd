# Приёмка шкалы напряжения (tension.gd).
#
# Директор страха — единственный модуль фазы 8, у которого нет ни звука,
# ни картинки: он только разрешает и запрещает. Ошибка в его таблицах не
# падает и не слышна, она проявляется формой всей ночи — «то пусто, то густо»
# за час игры. Поэтому здесь проверяется не измеритель давления (он зависит
# от живого мира), а РЕШАЮЩАЯ часть, и она чистая функция от состояния:
#
#   · таблицы осмысленны: окна вложены по возрастанию интенсивности и все
#     лежат под потолком, тишина растёт с интенсивностью;
#   · окно работает в обе стороны: слабое событие не проходит на пике так же,
#     как акцент не проходит в покое;
#   · выше потолка не проходит ничто — это и есть «директор не добивает»;
#   · после события своя тишина, после пика — покой и кулдаун между пиками;
#   · принудительная разрядка срабатывает ровно через RELEASE_AFTER секунд
#     над потолком, роняет шкалу до RELEASE_TO и даёт тишину.
#
# Шкала гоняется напрямую (set("_value", …)) вместо живого мира: собрать
# в headless игрока, деда, зоны и свет ради проверки трёх неравенств значит
# проверять сборку мира, а не директора. Измеритель давления смотрится глазами
# по строке F3 за полное прохождение — это в приёмке фазы и записано.
#
# Прогон:
#   Godot…_console.exe --headless --path godot --script res://tests/test_tension.gd
extends SceneTree

const DT := 0.25


func _initialize() -> void:
	var errs: Array[String] = []

	# 1. Таблицы.
	for i in [1, 2, 3]:
		if not Tension.WINDOWS.has(i):
			errs.append("нет окна для интенсивности %d" % i)
			continue
		var w: Array = Tension.WINDOWS[i]
		if float(w[0]) >= float(w[1]):
			errs.append("окно %d: [%.2f, %.2f] — нижняя граница не ниже верхней"
				% [i, float(w[0]), float(w[1])])
		if float(w[1]) > Tension.CEIL:
			errs.append("окно %d: верх %.2f выше потолка %.2f — событие прошло бы "
				% [i, float(w[1]), Tension.CEIL] + "там, где не проходит ничто")
		if not Tension.QUIET.has(i):
			errs.append("нет тишины для интенсивности %d" % i)
	if float(Tension.WINDOWS[1][0]) >= float(Tension.WINDOWS[3][0]):
		errs.append("акцент доступен не позже слабого события — окна не вложены")
	if float(Tension.QUIET[1]) >= float(Tension.QUIET[3]):
		errs.append("после акцента тишина не длиннее, чем после скрипа")
	if Tension.DECOYS.size() < 3:
		errs.append("точек-приманок %d — уводить деда некуда" % Tension.DECOYS.size())

	# 2. Окно работает в обе стороны.
	var t := Tension.new(null, 1)
	_at(t, 0.05)
	if not t.allows(1):
		errs.append("в покое не проходит даже слабое событие")
	if t.allows(3):
		errs.append("акцент проходит в покое — правило «недосказанное страшнее» "
			+ "сломано с первой главы")
	_at(t, 0.60)
	if t.allows(1):
		errs.append("слабое событие проходит при шкале 0.60 — оно там не слышно")
	if not t.allows(3):
		errs.append("акцент не проходит при шкале 0.60, хотя это его окно")

	# 3. Потолок.
	_at(t, Tension.CEIL + 0.05)
	for i in [1, 2, 3]:
		if t.allows(i):
			errs.append("выше потолка проходит событие интенсивности %d" % i)

	# 4. Тишина после события.
	_at(t, 0.30)
	t.spent(1)
	if t.allows(1):
		errs.append("сразу за событием проходит следующее — тишины нет")
	_run(t, float(Tension.QUIET[1]) - 1.0)
	_at(t, 0.30)
	if t.allows(1):
		errs.append("тишина после события короче QUIET[1]")
	_run(t, 2.0)
	_at(t, 0.30)
	if not t.allows(1):
		errs.append("тишина после события длиннее QUIET[1] — модуль замолкает")

	# 5. Пик: покой, затем кулдаун между пиками.
	var p := Tension.new(null, 2)
	_at(p, 0.60)
	p.spent(3)
	_run(p, Tension.COOL - 2.0)
	_at(p, 0.30)
	if p.allows(1):
		errs.append("после пика покой короче COOL")
	_run(p, 4.0)
	_at(p, 0.30)
	if not p.allows(1):
		errs.append("после COOL не проходит даже слабое событие")
	_at(p, 0.60)
	if p.allows(3):
		errs.append("второй акцент проходит раньше PEAK_CD — «нарастание, пик, "
			+ "выдох, покой» превращается в сплошной пик")
	_run(p, Tension.PEAK_CD)
	_at(p, 0.60)
	if not p.allows(3):
		errs.append("после PEAK_CD акцент так и не проходит")

	# 6. Принудительная разрядка.
	var r := Tension.new(null, 3)
	_at(r, Tension.CEIL + 0.10)
	_run_hold(r, Tension.RELEASE_AFTER - 1.0, Tension.CEIL + 0.10)
	if r.quiet_left() > 0.0:
		errs.append("разрядка сработала раньше RELEASE_AFTER")
	_run_hold(r, 2.0, Tension.CEIL + 0.10)
	if r.value() > Tension.RELEASE_TO + 0.001:
		errs.append("после разрядки шкала %.2f, а должна упасть до %.2f"
			% [r.value(), Tension.RELEASE_TO])
	if r.quiet_left() < Tension.RELEASE_QUIET - DT * 2.0:
		errs.append("после разрядки тишина %.1f с вместо %.1f"
			% [r.quiet_left(), Tension.RELEASE_QUIET])

	if errs.is_empty():
		print("PASS test_tension: окна %s, потолок %.2f, покой %.0f с, между "
			% [_windows_str(), Tension.CEIL, Tension.COOL]
			+ "пиками %.0f с, разрядка через %.0f с над потолком"
			% [Tension.PEAK_CD, Tension.RELEASE_AFTER])
		quit(0)
		return
	print("FAIL test_tension: расхождений ", errs.size())
	for e in errs:
		print("  - ", e)
	quit(1)


## Поставить шкалу вручную. Измеритель давления к решениям отношения не имеет,
## и подменять ради него весь мир — значит проверять другой модуль.
func _at(t: Tension, v: float) -> void:
	t.set("_value", v)


## Прогнать время. Давление с пустым ctx нулевое, поэтому шкала заодно
## сползает вниз — таймеры от этого не зависят.
func _run(t: Tension, seconds: float) -> void:
	var left := seconds
	while left > 0.0:
		t.update(DT)
		left -= DT


## То же, но шкала удерживается сверху: так ведёт себя игрок, забившийся
## в угол, пока дед ходит рядом.
func _run_hold(t: Tension, seconds: float, v: float) -> void:
	var left := seconds
	while left > 0.0:
		t.set("_value", v)
		t.update(DT)
		left -= DT
		# Как только разрядка случилась, держать перестаём: дальше меряется
		# именно её результат, а не то, что игрок опять залез в угол.
		if t.quiet_left() > 0.0:
			return


func _windows_str() -> String:
	var out := PackedStringArray()
	for i in [1, 2, 3]:
		var w: Array = Tension.WINDOWS[i]
		out.append("%d:[%.2f..%.2f]" % [i, float(w[0]), float(w[1])])
	return " ".join(out)

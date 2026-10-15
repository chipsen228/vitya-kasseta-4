# Чекпойнт-утилита lead: грузит и перекомпилирует все .gd проекта.
# Ловит ошибки компиляции в модулях, которые остальные тесты не трогают
# (рендер, фонарь, игрок, звук). Шейдеры headless не компилируются вовсе —
# их проверяет только оконный смоук.
extends SceneTree

func _initialize() -> void:
	var bad := 0
	for p in _gd_files():
		var res := ResourceLoader.load(p, "GDScript", ResourceLoader.CACHE_MODE_REPLACE)
		if res == null:
			printerr("НЕ ГРУЗИТСЯ: ", p)
			bad += 1
			continue
		var err: int = (res as GDScript).reload()
		if err != OK:
			printerr("НЕ КОМПИЛИРУЕТСЯ (код %d): %s" % [err, p])
			bad += 1
	if bad == 0:
		print("check_compile: PASS")
	else:
		print("check_compile: FAIL (%d)" % bad)
	quit(0 if bad == 0 else 1)

func _gd_files() -> Array:
	var out: Array = []
	for dirname in ["res://src", "res://tests"]:
		var d := DirAccess.open(dirname)
		if d == null:
			continue
		d.list_dir_begin()
		var f := d.get_next()
		while f != "":
			# Себя не трогаем: reload у выполняющегося скрипта запрещён.
			if f.ends_with(".gd") and f != "check_compile.gd":
				out.append(dirname + "/" + f)
			f = d.get_next()
	return out

# Контракт runtime-растров визуального прохода: точные размеры, прозрачность
# только у патины и политика mipmaps, не затрагивающая лица и кассеты.
extends SceneTree

const ASSETS := {
	"res://assets/tex/retro-floorboards.webp": [[512, 512], true, false],
	"res://assets/tex/retro-wallpaper.webp": [[512, 512], true, false],
	"res://assets/tex/retro-red-siding.webp": [[512, 512], true, false],
	"res://assets/tex/retro-shedwood.webp": [[256, 256], true, false],
	"res://assets/tex/retro-sooted-brick.webp": [[256, 256], true, false],
	"res://assets/tex/retro-whitewash.webp": [[256, 256], true, false],
	"res://assets/tex/retro-august-grass.webp": [[256, 256], true, false],
	"res://assets/tex/retro-blue-roof.webp": [[256, 256], true, false],
	"res://assets/tex/retro-log.webp": [[256, 256], true, false],
	"res://assets/tex/retro-concrete-slabs.webp": [[256, 256], true, false],
	"res://assets/tex/retro-green-counter.webp": [[256, 256], true, false],
	"res://assets/tex/retro-linoleum.webp": [[512, 512], true, false],
	"res://assets/tex/retro-neighbour-siding.webp": [[256, 256], true, false],
	"res://assets/atlases/paper-atlas.webp": [[512, 512], true, false],
	"res://assets/atlases/patina-atlas.png": [[512, 512], true, true],
	"res://assets/pictures/vatnik-v2.webp": [[512, 512], true, false],
	"res://assets/pictures/prorub-v2.webp": [[512, 512], true, false],
	"res://assets/pictures/lake-1-v2.webp": [[512, 512], true, false],
	"res://assets/pictures/lake-2-v2.webp": [[512, 512], true, false],
	"res://assets/face/arkady-v2.webp": [[128, 128], false, false],
	"res://assets/face/valya-v2.webp": [[128, 128], false, false],
	"res://assets/face/shouter-v3.webp": [[128, 128], false, false],
	# Versioned candidate retained without switching the runtime until its paired expression exists.
	"res://assets/face/watcher-1-v2.webp": [[128, 128], false, false],
	"res://assets/face/vitya-v2.webp": [[128, 128], false, false],
	"res://assets/face/vitya-scare-v2.webp": [[256, 256], false, false],
	"res://assets/face/vitya-scare-2-v2.webp": [[256, 256], false, false],
	"res://assets/face/vitya-scare-3-v2.webp": [[256, 256], false, false],
	"res://assets/face/vitya-scare-4-v2.webp": [[256, 256], false, false],
	"res://assets/face/vitya-scare-5-v2.webp": [[256, 256], false, false],
	"res://assets/tex/late-evening-sky.webp": [[512, 256], true, false],
}


func _initialize() -> void:
	var errs: Array[String] = []
	for path: String in ASSETS:
		_check_asset(path, ASSETS[path], errs)
	if errs.is_empty():
		print("test_retro_assets: PASS (%d assets)" % ASSETS.size())
		quit(0)
		return
	print("test_retro_assets: FAIL (%d)" % errs.size())
	for e: String in errs:
		print("  - ", e)
	quit(1)


func _check_asset(path: String, spec: Array, errs: Array[String]) -> void:
	if not FileAccess.file_exists(path):
		errs.append("нет файла %s" % path)
		return
	var image := Image.new()
	var load_err := image.load(path)
	if load_err != OK:
		errs.append("не декодируется %s: %s" % [path, error_string(load_err)])
		return
	var size := Vector2i(image.get_width(), image.get_height())
	var expected := Vector2i(int(spec[0][0]), int(spec[0][1]))
	if size != expected:
		errs.append("%s имеет %s вместо %s" % [path, size, expected])
	var has_alpha := image.detect_alpha() != Image.ALPHA_NONE
	if has_alpha != bool(spec[2]):
		errs.append("%s alpha=%s вместо %s" % [path, has_alpha, spec[2]])

	var import_path := path + ".import"
	if not FileAccess.file_exists(import_path):
		errs.append("нет import-настроек %s" % import_path)
		return
	var import_text := FileAccess.get_file_as_string(import_path)
	var want_mips := "mipmaps/generate=%s" % ("true" if bool(spec[1]) else "false")
	if not import_text.contains(want_mips):
		errs.append("%s: ожидалось %s" % [import_path, want_mips])

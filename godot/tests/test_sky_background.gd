# Небо остаётся чисто визуальным фоном: Compatibility получает маленькую
# панораму, ambient по-прежнему задаёт LightRig, любая ошибка возвращает BG_COLOR.
extends SceneTree


func _initialize() -> void:
	_run()


func _run() -> void:
	var errs: Array[String] = []
	var chain := RenderChain.new()
	root.add_child(chain)
	await process_frame

	if not chain.panorama_enabled():
		errs.append("валидная панорама не включилась в Compatibility")
	if chain.world_env.ambient_light_source != Environment.AMBIENT_SOURCE_COLOR:
		errs.append("панорама подменила ambient LightRig")
	if chain.world_env.sky == null:
		errs.append("Environment не получил Sky")

	if chain.try_set_panorama("res://assets/tex/__missing_sky__.webp"):
		errs.append("отсутствующая панорама принята")
	if chain.world_env.background_mode != Environment.BG_COLOR or chain.world_env.sky != null:
		errs.append("ошибка ресурса не вернула BG_COLOR")

	if not chain.try_set_panorama(RenderChain.WORLD_SKY):
		errs.append("панорама не включилась повторно")
	chain.free()

	if errs.is_empty():
		print("test_sky_background: PASS")
		quit(0)
		return
	print("test_sky_background: FAIL (%d)" % errs.size())
	for e: String in errs:
		print("  - ", e)
	quit(1)

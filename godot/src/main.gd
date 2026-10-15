# Точка входа: загрузка, игровой цикл, разводка ввода — порт src/main.js.
#
# Сюжет живёт в chapters.gd, мир — в world_builder.gd, интерфейс — в overlays.gd.
# Здесь только склейка: контекст ctx, который все они получают, и раскладка клавиш.
#
# ctx — ОДИН Dictionary на всю игру. Замыкания модулей читают его ключи в момент
# вызова, поэтому поля можно дозаполнять по ходу загрузки, но сам словарь
# подменять нельзя.
extends Node

const EYEBROW_START := "запись 04 · август 2003"

# ---------- ядро (собирается в _ready, до первого кадра) ----------

var render_chain: RenderChain
var ui: Overlays
var audio: GameAudio
var state: GameState
var tape_player: TapePlayer
var phone: Phone
var _dialogue_attempt_id := 0
var _dialogue_frozen := false
var scare: Scare
var voice: GameVoice

# ---------- мир (собирается в _boot) ----------

var mats: Materials
var col: CollisionWorld
var physics: PhysicsBodies
var built: Dictionary = {}
var props: Props
var props_skin: SkinLayer
var environment_static_interiors: Variant
var environment_occlusion: Variant
var player: Player
var flashlight: Flashlight
var held_items: HeldItems
var actors: Actors
var lights: LightRig
# Дождь и гроза (фаза 15). Три числа и ни одного партикла — см. weather.gd.
var weather: Weather
var nav: NavGraph
var nav_links: NavLinks
var interact: Interact
var chapters: Chapters
var threat: Threat
var tension: Tension
var haunt: Haunt
# Сценарная камера (фаза 16). Пуста, пока не играет: финал — единственное
# место, где она сейчас нужна.
var cutscene: Cutscene
var dread: GameDread
var omens: Omens
var startle: Startle
var horror: HorrorDirector
var capture: CaptureRecovery
var pursuit: SntPursuit
var episode_actors: Variant
var everyday: EverydayInteractions
# Улица за воротами (фаза 9). Обоих может не быть вовсе: без data/street.json
# built.street пуст, соседи не строятся, глава УЛИЦА проходится за один шаг —
# игра ведёт себя ровно как принятая фаза 8.
var neighbours: Neighbours
var street: StreetQuest
var stalk: StreetStalk

# ---------- состояние приложения ----------

var boot_ready := false
var running := false
var paused := false
var debug := false
var _frame_probe_on := "--frame-profile" in OS.get_cmdline_user_args()
var _frame_probe: Dictionary = {}
var _frame_probe_us := 0

## Сухой режим отладки (фаза 17). Включается словом `dry` в аргументах после
## `++`. Держит дождь на нуле и поднимает экспозицию: в грозу и ночь 1.0
## финал отлаживать нельзя — экран в VHS-помехах, точек интеракта не видно.
var debug_dry := false
var started := false
var busy := false             # переход через люк идёт, [E] не принимается
var zone: Dictionary = {}
# Кулдаун люка: без него кадр, следующий за переходом, тут же ловит [E] ещё раз
# и игрока швыряет обратно.
var hatch_cooldown := 0.0
var _hatch: Variant = null    # люк рядом, когда цели интеракта нет
var _hatches: Array = []
var _fps := 60.0
var _clock_acc := 0.0
var _clock_frames := 0
# Состояние игрока прошлого кадра — для звуков приседа, бега и одышки (фаза 5).
var _was_crouch := false
var _was_running := false
var _cloth_at := 0.0
var _breath_cool := 0.0
var _fade_tween: Tween
var _water_surface := "dry"

var ctx: Dictionary = {}


func _ready() -> void:
	render_chain = RenderChain.new()
	render_chain.name = "RenderChain"
	add_child(render_chain)

	ui = Overlays.new()
	ui.name = "Overlays"
	add_child(ui)

	audio = GameAudio.new()
	audio.name = "Audio"
	add_child(audio)

	# Голос идёт своими плеерами мимо пула audio.gd — почему именно так,
	# написано в шапке voice.gd. Модуля озвучки может не быть вовсе: без
	# godot/audio/voice/ игра звучит ровно как принятая версия фазы 4.
	voice = GameVoice.new(audio)
	voice.name = "Voice"
	add_child(voice)
	voice.ui = ui
	ui.audio = audio

	state = GameState.new()
	voice.state = state
	# Рендерер плееру нужен по-настоящему: кадр кассеты идёт через шейдер VHS
	# (render_chain.begin_tape_mode), а не поверх него отдельной канвой.
	tape_player = TapePlayer.new(audio, render_chain, self)
	tape_player.voice = voice
	phone = Phone.new(audio, self)
	phone.voice = voice
	scare = Scare.new(audio, self)

	_hatches = GameData.site().get("HATCHES", [])
	_make_ctx()
	_wire_ui()

	ui.showLoadScreen(true)
	_boot()


# ---------- контекст, который получают главы и предметы ----------

func _make_ctx() -> void:
	ctx = {
		"state": state,
		"ui": ui,
		"audio": audio,
		"phone": phone,
		"voice": voice,
		"renderer": render_chain,
		"texts": GameData.texts(),
		# Появляются по ходу загрузки; ключи заводим сразу, чтобы _cx() модулей
		# отличал «ещё не создан» от опечатки в имени.
		"controls": null, "flashlight": null, "heldItems": null,
		"lights": null, "props": null,
		# Погода (фаза 15): главы зовут c["weather"].set_rain()/storm().
		"weather": null,
		"world": {}, "actors": null, "threat": null, "nav": null, "col": null,
		# Шкала давления (фаза 8). Ключа нет — модули страха работают по своим
		# кулдаунам, ровно как в фазе 7.
		"tension": null,
		# Улица (фаза 9). mats и physics нужны второму витку (подмена материалов
		# в рамах) и створке правления: её коробка живёт в четвёртом наборе
		# коллизий, и после гашения обязателен physics.sync().
		"mats": null, "physics": null, "interact": null,
		"neighbours": null, "street": null, "stalk": null,
		# Знаки (фаза 8): меняют мир, а не звучат. Нет data/omens.json — модуль
		# создаётся выключенным и update() выходит первой строкой.
		"omens": null, "dread": null,
		# Испуги по местам (раунд 10). Двойник у них общий с haunt и stalk,
		# и очередь к нему startle.gd соблюдает сам.
		"startle": null,
		"horror": null, "capture": null, "haunt": null,
		"drive_attempt_id": 0,
		"resumeControl": _resume_control,
		"resumeRecovery": _ctx_resume_recovery,
		"terminalCaught": _ctx_terminal_caught,
		"contextScare": _ctx_context_scare,
		# Отладочный флаг: ai/haunt пишут предупреждения под ctx.debug —
		# синхронизируется в момент нажатия F3.
		"debug": false,
		"emit": _ctx_emit,
		"slowThreat": _ctx_slow_threat,
		"onFinished": _show_end,
		"resetThreat": _ctx_reset_threat,
		"holdEcho": _ctx_hold_echo,
		"scare": _ctx_scare,
		"scaresOn": _ctx_scares_on,
		"setDoor": _ctx_set_door,
		"setGate": _ctx_set_gate,
		"setWicket": _ctx_set_wicket,
		"openPhone": _ctx_open_phone,
		"cancelDialogue": _cancel_dialogue_runtime,
		"openTapeMenu": _ctx_open_tape_menu,
		"playDialogue": _ctx_play_dialogue,
		"playWalkDialogue": _ctx_play_walk_dialogue,
	}


func _ctx_emit(event: String, payload: Variant = null) -> void:
	if capture != null and capture.active():
		return
	if horror != null:
		horror.observe(event, payload)
	# После поимки дед говорит другое — не «стой», а «опять ушёл, как отец».
	if event == "caught" and voice != null:
		voice.mark_caught()
	if held_items != null:
		held_items.sync(state)
		held_items.show_story_event(event)
	if chapters != null:
		chapters.emit(event, payload)


func _ctx_slow_threat(k: float) -> void:
	if threat != null:
		threat.speedScale = k


## Развести угрозу с игроком. Без этого в главе ВОРОТА поимка зацикливается
## насмерть: [R] возвращает игрока в ту же точку, а дед остаётся стоять
## вплотную и ловит его в том же кадре.
func _ctx_reset_threat() -> void:
	if threat != null:
		threat.reset(player.feet())
	if tension != null:
		tension.reset()
	if haunt != null:
		haunt.reset()
	if dread != null:
		dread.reset()
	if omens != null:
		omens.reset()
	if startle != null:
		startle.reset()


## Занять двойника постановочной сценой из главы. Двойник один на всю игру,
## и мелькание в окне, начавшееся посреди сцены у калитки, увело бы фигуру
## с места прямо на глазах. Вызывать ДО actors.show('echo', true).
func _ctx_hold_echo(seconds: float, owner := "mandatory") -> void:
	if seconds <= 0.0 and owner == "stalk":
		if horror != null and horror.owner != "stalk": return
		if horror != null:
			horror.hold_left = 0.0
			horror.owner = ""
		if haunt != null:
			haunt.global_cd = minf(haunt.global_cd, HorrorDirector.STRONG_COOLDOWN)
		return
	if horror != null:
		horror.hold(seconds, owner)
	if haunt != null:
		haunt.hold(seconds)
	# Испуги по местам берут ту же фигуру. Свой момент они гасят молча: сцена
	# главы поставит двойника на своё место в этом же кадре, и «испуг посреди
	# сцены» не должен уводить его оттуда. Рекурсии здесь нет — startle зовёт
	# holdEcho до того, как заводит свой момент.
	if startle != null:
		startle.clear()


## Скример перед экраном провала. Выключенный в настройках гасит фотографию,
## но не саму паузу: звук и трекинг ставит вызывающий, и они должны успеть
## отыграть до карточки.
func _ctx_scare(on_done: Variant = null) -> void:
	_ctx_context_scare()
	if on_done is Callable and on_done.is_valid():
		on_done.call()


func _ctx_context_scare(id := "local-noise", sound := "horror-window-hit") -> void:
	if horror != null:
		horror.context(String(id), String(sound))


func _ctx_resume_recovery(checkpoint: Dictionary) -> void:
	if chapters != null:
		chapters.resume_after_recovery(checkpoint)


func _ctx_terminal_caught() -> void:
	if chapters != null:
		chapters.end("caught")


## Включены ли резкие эффекты. Один источник правды на всех: галочка живёт
## в scare.gd (user://vitya.cfg), а спрашивают её главы (сила ударов, мягкие
## испуги) и знаки (акценты и мигание фонаря).
func _ctx_scares_on() -> bool:
	return true if scare == null else bool(scare.enabled)


## quiet — открыть или закрыть БЕЗ звука. Аргумент с умолчанием: два вызова
## из interact.gd остаются как были, а омен «дверь, которую игрок закрыл, снова
## открыта» обязан молчать — в этом и вся его сила. Игрок не слышит момента,
## он видит результат.
func _ctx_set_door(id: String, open: bool, quiet := false) -> void:
	var b := _blocker(id)
	if b.is_empty():
		return
	b["active"] = not open
	col.set_blocker_active(id, not open)
	physics.sync()
	var node: Node3D = b.get("node")
	if node != null:
		if open:
			node.rotation.y = -1.5 if String(node.get_meta("axis", "")) == "x" else 1.5
		else:
			node.rotation.y = 0.0
	if not quiet:
		audio.door(open)


func _ctx_set_gate(open: bool) -> void:
	var b := _blocker("gate")
	if b.is_empty():
		return
	b["active"] = not open
	col.set_blocker_active("gate", not open)
	physics.sync()
	var node: Node3D = b.get("node")
	if node != null:
		_set_hinged_fence_visual(node, open, 1.20)
	audio.chain()


## Калитка имеет собственную створку и blocker, но тот же контракт, что дверь:
## физика и вид синхронизируются одним вызовом, в том числе после retry/load.
func _ctx_set_wicket(open: bool, quiet := false) -> void:
	var b := _blocker("wicket")
	if b.is_empty():
		return
	b["active"] = not open
	col.set_blocker_active("wicket", not open)
	physics.sync()
	var node: Node3D = b.get("node")
	if node != null:
		_set_hinged_fence_visual(node, open, 1.35)
	if not quiet:
		audio.door(open)


func _set_hinged_fence_visual(node: Node3D, open: bool, angle: float) -> void:
	node.set_meta("open", open)
	var left := node.get_node_or_null("LeftHinge") as Node3D
	var right := node.get_node_or_null("RightHinge") as Node3D
	var wicket := node.get_node_or_null("WicketHinge") as Node3D
	if left != null and right != null:
		left.rotation.y = float(left.get_meta("home", 0.0)) + (-angle if open else 0.0)
		right.rotation.y = float(right.get_meta("home", 0.0)) + (angle if open else 0.0)
	elif wicket != null:
		wicket.rotation.y = float(wicket.get_meta("home", 0.0)) + (angle if open else 0.0)
	else:
		# Совместимость с мирами, собранными до появления hinge-контейнеров.
		node.rotation.y = float(node.get_meta("home", 0.0)) + (angle if open else 0.0)


func _blocker(id: String) -> Dictionary:
	for b in built.get("blockers", []):
		if b.get("id", "") == id:
			return b
	return {}


func _dialogue_token() -> Dictionary:
	_cancel_dialogue_runtime()
	return {"attempt": _dialogue_attempt_id, "chapter": state.chapter,
		"horror": horror.generation if horror != null else -1,
		"capture": capture.generation if capture != null else -1}


func _dialogue_valid(token: Dictionary) -> bool:
	return running and int(token.get("attempt", -1)) == _dialogue_attempt_id \
		and String(token.get("chapter", "")) == state.chapter \
		and (horror == null or int(token.get("horror", -1)) == horror.generation) \
		and (capture == null or (int(token.get("capture", -1)) == capture.generation and not capture.active()))


func _cancel_dialogue_runtime() -> void:
	_dialogue_attempt_id += 1
	if everyday != null:
		everyday.cancel_runtime()
	if phone != null:
		phone.onPick = Callable()
		phone.onDialogueEnd = Callable()
		phone.subtitleSink = Callable()
		phone.dialogue.clear()
		phone.set("_talking", false)
		phone.hide()
	if voice != null: voice.stop_dialogue()
	if _dialogue_frozen and player != null: player.frozen = false
	_dialogue_frozen = false


func _ctx_open_phone(_which: Variant = null) -> void:
	if capture != null and capture.active(): return
	var token := _dialogue_token()
	player.enabled = false
	player.release_lock()
	audio.sfx("ring-tone")
	phone.show(phone.callOptions(state), func(opt: Variant) -> void:
		if not _dialogue_valid(token): return
		_resume_control()
		if not (opt is Dictionary) or String(opt.get("id", "")) == "cancel":
			return
		var id := String(opt["id"])
		var lines: Variant = phone.scriptFor(id)
		if lines == null: return
		audio.phone_bed(true)
		var begin := func() -> void:
			if not _dialogue_valid(token): return
			audio.sfx("line-connect")
			phone.playLines(lines,
				func(text: String, sec: float) -> void:
					if _dialogue_valid(token): ui.say(text, sec, GameVoice.PRIO_LINE),
				func() -> void:
					if not _dialogue_valid(token): return
					state.callsMade[id] = true
					_ctx_emit("call", id))
		# Набор номера живёт по игровому времени и отменяется вместе со сценой.
		if audio.sfx("dial"):
			if horror != null: horror.after(1.6, begin)
			else: audio.after(1.6, begin)
		else:
			begin.call())


func _ctx_open_tape_menu() -> void:
	var tapes_data := GameData.tapes()
	var tape_defs: Dictionary = tapes_data.get("TAPES", {})
	var owned: Array = []
	for n in tapes_data.get("TAPE_ORDER", []):
		if state.hasItem("tape-" + String(n)):
			owned.append(String(n))
	if owned.is_empty():
		ui.say("Кассет нет. Они наверху, у Витьки на полке.", 3.6)
		return
	if capture != null and capture.active(): return
	var token := _dialogue_token()
	player.enabled = false
	player.release_lock()
	var opts: Array = []
	for n in owned:
		var td: Dictionary = tape_defs.get(n, {})
		opts.append({"id": n, "label": td.get("label", n), "done": state.tapesWatched.has(n)})
	opts.append({"id": "cancel", "label": "закрыть"})
	phone.show(opts, func(opt: Variant) -> void:
		if not _dialogue_valid(token): return
		# Кассету пустили — управление вернёт колбэк её конца. Вернуть его здесь
		# нельзя: кадр на время просмотра заморожен, а живой поворот мыши успел бы
		# накрутить yaw_target, и на выходе камеру развернуло бы рывком.
		if not (opt is Dictionary) or String(opt.get("id", "")) == "cancel":
			_resume_control()
			return
		# HUD игры уходит на время записи: прицел и «REC» поверх плёнки
		# читаются как часть кадра.
		ui.setTapeMode(true)
		var started_tape := tape_player.play(String(opt["id"]),
			func(id: String, watched: bool) -> void:
				if not _dialogue_valid(token): return
				ui.setTapeMode(false)
				if watched:
					state.tapesWatched[id] = true
					_ctx_emit("watch-tape", id)
				_resume_control())
		if not started_tape:
			ui.setTapeMode(false)
			_resume_control())


func _ctx_play_dialogue(lines: Variant, on_end: Variant = null) -> void:
	if capture != null and capture.active(): return
	# Прервать текущие появления, сохранив резерв фигуры у патруля/главы.
	if horror != null:
		if not horror._live.is_empty(): horror._end_live()
		if horror.thresholds.active(): horror.thresholds._end()
	if haunt != null and haunt.point != null: haunt._hide(false)
	if startle != null: startle.clear()
	var token := _dialogue_token()
	_dialogue_frozen = true
	player.frozen = true
	phone.playLines(lines,
		func(text: String, sec: float) -> void:
			if _dialogue_valid(token): ui.say(text, sec, GameVoice.PRIO_LINE),
		func() -> void:
			if not _dialogue_valid(token): return
			player.frozen = false
			_dialogue_frozen = false
			if on_end is Callable and (on_end as Callable).is_valid():
				(on_end as Callable).call())


## Walk dialogue shares Phone timing without freezing movement.
func _ctx_play_walk_dialogue(lines: Variant, on_end: Variant = null) -> void:
	if capture != null and capture.active(): return
	var token := _dialogue_token()
	phone.playLines(lines,
		func(text: String, sec: float) -> void:
			if _dialogue_valid(token): ui.say(text, sec, GameVoice.PRIO_LINE),
		func() -> void:
			if not _dialogue_valid(token): return
			if on_end is Callable and (on_end as Callable).is_valid():
				(on_end as Callable).call())


# ---------- загрузка ----------

func _boot() -> void:
	var tree := get_tree()

	ui.setProgress(0.04, "материалы")
	await tree.process_frame
	render_chain.bind_settings_ui(ui)
	render_chain.apply_render_args()
	mats = Materials.new().load_all()
	ctx["mats"] = mats

	ui.setProgress(0.30, "участок")
	await tree.process_frame
	col = CollisionWorld.new()
	built = WorldBuilder.build(render_chain.world_root, mats, col)
	built["everyday"] = EverydayWorld.build(render_chain.world_root, mats, col, built)
	ctx["world"] = built
	if audio.has_method("bind_spatial_world"):
		audio.call("bind_spatial_world", render_chain.world_root)
		render_chain.world_view.audio_listener_enable_3d = true
	ctx["col"] = col
	physics = PhysicsBodies.new()
	physics.name = "PhysicsBodies"
	render_chain.world_root.add_child(physics)
	# Улица уже собрана — WorldBuilder кладёт её последним шагом, и её твёрдые
	# коробки лежат в четвёртом наборе. PhysicsBodies строит тела циклом по
	# SET_COUNT, поэтому улица становится проходимой без единой строки здесь.
	physics.build(col)
	ctx["physics"] = physics

	ui.setProgress(0.38, "обстановка")
	await tree.process_frame
	var pdata := GameData.props()
	var static_props: Array = pdata.get("PROPS", [])
	var dynamic_props: Array = pdata.get("DYNAMIC_PROPS", [])
	# Знаки (фаза 8) заводятся здесь, а не рядом с dread: два их предмета —
	# банка на своём месте и та же банка под люком — обязаны попасть в общую
	# сборку реквизита. Оба идут с "col": false, поэтому 83 коробки паритета
	# не двигаются по построению (props.gd выходит до записи коробки).
	omens = Omens.new(ctx, randi())
	ctx["omens"] = omens
	dynamic_props = dynamic_props + omens.extra_props()
	# Три рамки из ТЗ (фаза 9) висят с самого начала — они часть обстановки,
	# а не события главы. Все с "col": false, поэтому 83 коллайдера паритета
	# не двигаются: props.spawn выходит до записи коробки.
	static_props = static_props + Photos.extra_props()
	props = Props.new(mats)
	props.load_models(static_props + dynamic_props)
	ctx["props"] = props

	ui.setProgress(0.78, "расстановка")
	await tree.process_frame
	props.build(render_chain.world_root, static_props, col)
	# Предметы, которые появляются по ходу глав, стоят на местах, но невидимы.
	props.build_dynamic(dynamic_props)
	props.rebuild_collision(col)
	physics.sync()
	# Скины (фаза 7) — ПОСЛЕ коллизий и строго поверх: они меняют только вид,
	# и массив props.colliders к этому моменту уже посчитан и роздан.
	props_skin = SkinLayer.load_all()
	if props_skin.apply(render_chain.world_root, props, mats) > 0:
		print("реквизит: ", props_skin.report())
	built["environment_vehicle"] = VehicleVisuals.refresh_story_car(render_chain.world_root.get_node_or_null("props/car") as Node3D, mats)
	built["environment"] = EnvironmentRegistry.apply(render_chain.world_root, built, mats)
	built["environment_public"] = preload("res://src/environment_public.gd").apply(render_chain.world_root, built, mats)
	built["environment_interiors"] = preload("res://src/environment_interiors.gd").apply(render_chain.world_root, mats, built)
	built["environment_verge"] = preload("res://src/environment_verge.gd").apply(render_chain.world_root, col)
	built["environment_detail_ranges"] = preload("res://src/environment_detail_ranges.gd").apply(render_chain.world_root, built, props)
	built["environment_shadow_batch"] = StaticShadowBatch.rebuild(render_chain.world_root)

	player = Player.new()
	player.name = "Player"
	render_chain.world_root.add_child(player)
	player.camera = render_chain.camera
	player.step.connect(_on_step)
	player.land.connect(_on_land)
	ctx["controls"] = player
	flashlight = Flashlight.new(render_chain)
	flashlight.name = "Flashlight"
	add_child(flashlight)
	flashlight.build(render_chain)
	ctx["flashlight"] = flashlight
	held_items = HeldItems.new()
	held_items.name = "HeldItems"
	add_child(held_items)
	held_items.configure(render_chain, flashlight)
	held_items.selection_changed.connect(func(_id: String, label: String) -> void:
		ui.setHeldItem(label))
	ctx["heldItems"] = held_items
	ui.setHeldItem(held_items.selected_label())

	ui.setProgress(0.86, "люди")
	await tree.process_frame
	actors = Actors.new(render_chain.world_root, mats).build()
	ctx["actors"] = actors

	# Соседи и глава УЛИЦА (фаза 9). Оба живут на built.street: нет
	# data/street.json — build() выходит первой строкой, соседи не появляются,
	# уличные точки не регистрируются, и игра идёт как принятая фаза 8.
	neighbours = Neighbours.new(ctx, built.get("street", {}), randi())
	neighbours.build(render_chain.world_root)
	ctx["neighbours"] = neighbours
	# Дед на линии (раунд 10). Соседям он не родня: те безопасны по контракту,
	# а этот ловит. Живёт отдельным модулем и без нав-графа — сорок метров
	# прямой дороги обходить нечего.
	stalk = StreetStalk.new(ctx, randi())
	ctx["stalk"] = stalk
	street = StreetQuest.new(ctx, built.get("street", {}), neighbours, stalk)
	ctx["street"] = street

	ui.setProgress(0.92, "свет")
	await tree.process_frame
	lights = LightRig.new(render_chain, mats)
	lights.name = "LightRig"
	render_chain.world_root.add_child(lights)
	ctx["lights"] = lights
	weather = Weather.new(render_chain, lights, audio)
	ctx["weather"] = weather

	ui.setProgress(0.96, "сюжет")
	await tree.process_frame
	nav = NavGraph.from_baked(col, built.get("blockers", []))
	ctx["nav"] = nav
	# Переходы между слоями (фаза 7). Файла нет — links пуст, и дед ведёт себя
	# ровно как в фазе 6: между этажами телепорт, ногами не ходит.
	nav_links = NavLinks.load_all()
	nav_links.bind(nav)
	ctx["navLinks"] = nav_links
	interact = Interact.new()
	interact.occluder = col   # чтобы не целиться сквозь стены и перекрытия
	ctx["interact"] = interact
	Interact.registerObjects(interact, ctx)
	everyday = EverydayInteractions.new(ctx, built.get("everyday", {}))
	ctx["everyday"] = everyday
	everyday.register(interact)
	interact.addLookTargets(props)
	chapters = Chapters.new(ctx)
	ctx["chapters"] = chapters
	threat = Threat.new(ctx, actors, nav, col, randi())
	threat.links = nav_links
	ctx["threat"] = threat
	# Шкала давления (фаза 8) — до haunt и dread: они её спрашивают.
	tension = Tension.new(ctx, randi())
	ctx["tension"] = tension
	voice.tension = tension
	haunt = Haunt.new(ctx, actors, col, randi())
	ctx["haunt"] = haunt
	# Хоррор-слой. Node, а не RefCounted, поэтому вешаем в дерево — иначе
	# на выходе Godot ругается утечкой. Тик у него ручной, как у haunt:
	# редкие события обязаны замирать вместе с игрой, а не идти под паузой.
	dread = GameDread.new(ctx, randi())
	dread.name = "Dread"
	add_child(dread)
	ctx["dread"] = dread
	# Испуги по местам (раунд 10) — последними из хоррор-слоя: они занимают
	# двойника через holdEcho и обязаны видеть уже созданные haunt и dread.
	startle = Startle.new(ctx, actors, col)
	ctx["startle"] = startle
	# Сценарная камера. Своего состояния до первой сцены у неё нет, узлов она
	# не заводит — только на время игры сцены.
	cutscene = Cutscene.new()
	ctx["cutscene"] = cutscene
	horror = HorrorDirector.new(ctx)
	ctx["horror"] = horror
	capture = CaptureRecovery.new(ctx)
	ctx["capture"] = capture
	capture.register(interact)
	episode_actors = preload("res://src/snt_episode_actors.gd").new(render_chain.world_root, mats).build()
	ctx["episodeActors"] = episode_actors
	phone.spatial_dialogue_source = func(who: String) -> Vector3:
		if who == "snt-radio":
			return (built.get("snt", {}).get("quest", {}) as Dictionary).get("radio", Vector3(7.1, 0.7, -58.86))
		if who in ["nina", "semyon"]:
			var person: Node3D = episode_actors.figure(who)
			if person != null: return person.global_position + Vector3.UP * 1.35
		return Vector3.INF
	pursuit = SntPursuit.new(ctx, built.get("snt", {}))
	ctx["pursuit"] = pursuit
	var snt_quest: Variant = ctx.get("snt")
	if snt_quest != null: snt_quest.resync(state)

	ui.setProgress(1.0, "готово")
	await tree.process_frame

	# Прогрев шейдеров под экраном загрузки. В Compatibility шейдер
	# компилируется в момент первого показа материала, и без прогрева фриз
	# приходится ровно на первый выход за ворота — то есть на скример.
	# Квадики в сантиметр стоят вплотную к камере три кадра и удаляются.
	_apply_settings()
	render_chain.bind_settings_ui(ui)
	render_chain.skin_enabled_changed.connect(_set_skin_enabled)
	render_chain.apply_render_args()
	render_chain._apply_scene_material_quality(render_chain.render_preset() == RenderChain.PRESET_HQ)
	if EnvironmentRegistry.active():
		environment_static_interiors = preload("res://src/environment_static_interiors.gd").prepare(render_chain.world_root, built, props)
		built["environment_static_interiors"] = environment_static_interiors.report
	var environment_coverage: Dictionary = built["environment"]
	environment_coverage["retained_objects"] = preload("res://src/environment_retained.gd").apply(render_chain.world_root, built, mats)
	environment_coverage["retained_count"] = environment_coverage["retained_objects"].size()
	environment_coverage["interiors"] = built["environment_interiors"]
	environment_coverage["verge"] = built["environment_verge"]
	environment_coverage["errors"].append_array(built["environment_verge"]["errors"])
	environment_coverage["public"] = built["environment_public"]
	environment_coverage["story_vehicle"] = built["environment_vehicle"]
	environment_coverage["detail_ranges"] = built["environment_detail_ranges"]
	environment_coverage["static_interiors"] = built.get("environment_static_interiors", {})
	environment_coverage["shadow_batch"] = built["environment_shadow_batch"]
	if EnvironmentRegistry.active():
		environment_occlusion = preload("res://src/environment_occlusion.gd").prepare(render_chain.world_view, render_chain.world_root)
		environment_occlusion.set_hq(render_chain.render_preset() == RenderChain.PRESET_HQ)
		built["environment_occlusion"] = environment_occlusion.report
		environment_coverage["occlusion"] = environment_occlusion.report
	var warm := mats.warm_up(render_chain.camera, Vector3.ZERO, render_chain)
	if warm != null:
		# Обычный свет, Omni и Spot с тенями требуют разных GLES-вариантов.
		for mode in 4:
			warm.get_node("WarmOmni").visible = mode == 1 or mode == 3
			warm.get_node("WarmSpot").visible = mode >= 2
			for _i in 3:
				await tree.process_frame
		warm.queue_free()
		await tree.process_frame
	await _warm_world_views()
	var reader_guard := _warm_visual_snapshot()
	var reader_physics := [col.get("_data").duplicate(true), col.get("_active").duplicate(true)]
	var reader_proof := await ui.warm_reader_pages(everyday.definitions)
	reader_proof["world_restored"] = reader_guard == _warm_visual_snapshot()
	reader_proof["physics_restored"] = reader_physics == [col.get("_data"), col.get("_active")]
	set_meta("boot_reader_warm", reader_proof)
	if environment_occlusion != null:
		environment_occlusion.set_enabled(true)
		environment_occlusion.update()
		# Первый native BVH/raster кадр остаётся под экраном загрузки.
		await tree.process_frame
		await tree.process_frame
		await _warm_world_views(true)
	environment_coverage["scene_inventory"] = preload("res://src/environment_inventory.gd").capture(render_chain.world_root)
	environment_coverage["render_texture_bytes"] = RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED)
	boot_ready = true

	ui.showLoadScreen(false)
	ui.showStartScreen(true, EYEBROW_START)
	print("мир: ", int(built.get("triangles", 0)), " тр., ",
		props.by_id.size(), " объектов, ", interact.list.size(), " точек взаимодействия")


## Материальные квады не показывают GLES реальные сочетания воды, теневых
## мешей и скелета. Первый такой кадр у берега занимал 0.8–1.1 с при 2 мс
## игрового кода. Рисуем эти варианты под уже открытым экраном загрузки.
## Игрок, сюжет, звук и настройки не участвуют; восстанавливаем все визуальные
## состояния до стартового меню. Headless не имеет GLES-кэша для прогрева.
func _warm_world_views(forest_only := false) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var visual_guard := _warm_visual_snapshot()
	var environment_process: Array = []
	for node: Node in SkinLayer._nodes(render_chain.world_root):
		if node is EnvironmentLod:
			environment_process.append({"node":node,"enabled":node.is_processing()})
			node.set_process(false)
	var occlusion_guard: Array = []
	if forest_only:
		occlusion_guard = _warm_occlusion_snapshot()
	var camera := render_chain.camera
	var camera_saved := camera.global_transform
	var light_saved := lights.snapshot()
	var clock_saved: float = lights.get("_clock_night")
	var hemi_saved: float = lights.get("_hemi_energy")
	var moon_saved: float = lights.get("_moon_energy")
	var flash_saved := flashlight.snapshot()
	var flash_runtime: Dictionary = {}
	for key: String in ["_body", "_aim", "_flicker", "_shake", "_shadow_on", "_proj_on", "_proj_cone", "_cinematic_suppressed"]:
		flash_runtime[key] = flashlight.get(key)
	var flash_transform := flashlight.light.global_transform
	var flash_energy := flashlight.light.light_energy
	var flash_shadow := flashlight.light.shadow_enabled
	var flash_visible := flashlight.light.visible
	var flash_uniforms: Dictionary = {}
	for key: StringName in [&"flashlight_on", &"flashlight_proj", &"flashlight_pos"]:
		flash_uniforms[key] = RenderChain.get_shader_global(key)
	var visual_saved: Array = []
	for node: Node3D in [flashlight.cone, flashlight.halo, flashlight.model]:
		visual_saved.append({"node": node, "transform": node.transform, "visible": node.visible})
	var pool_saved: Array = []
	for lamp: OmniLight3D in lights.pool:
		pool_saved.append({"node": lamp, "transform": lamp.transform, "visible": lamp.visible,
			"energy": lamp.light_energy, "color": lamp.light_color, "range": lamp.omni_range})
	var echo: Node3D = actors.figures["echo"]
	var echo_transform := echo.transform
	var echo_visible := echo.visible
	var rain_saved: Variant = render_chain.get_vhs(&"rain")
	var warm_lamps: Array[OmniLight3D] = []
	for _i in 3:
		var lamp := OmniLight3D.new()
		lamp.omni_range = 18.0
		lamp.light_energy = 2.0
		lamp.shadow_enabled = false
		render_chain.world_root.add_child(lamp)
		warm_lamps.append(lamp)
	# Берег со стороны пруда, подход к мельнице, стекло служебной будки.
	var views: Array = [
		[Vector3(-14.2, 1.62, -22.3), -0.08, -0.01],
		[Vector3(3.0, 1.62, -22.7), -0.90, 0.08],
		[Vector3(8.07, 1.62, -66.3), 0.0, 0.0],
		[Vector3(-12, 1.62, -78), 0.0, 0.0],
		[Vector3(-34, 1.62, -78), PI * 0.5, 0.0],
	]
	# Первые дворовые кадры включают домашние лампы, которых нет у берега.
	for t: float in [0.0, 0.35, 0.70, 1.05, 1.40]:
		var blend := smoothstep(0.0, 1.0, t * 16.0 / 60.0)
		views.append([Vector3(0, 1.68, -1.2).lerp(Vector3(-2.3, 1.68, 3.4), blend),
			PI + sin(t * 1.7) * 0.32, sin(t * 0.9) * 0.12, "plot", true,
			lerpf(0.10, 0.25, blend)])
	views.append([Vector3(-2.3, 1.68, 3.4), PI, 0.0, "plot", true, 1.0])
	views.append([Vector3(-3.0, 2.13, 11.0), PI, 0.0, "floor1", false, 0.55])
	views.append([Vector3(-0.4, 2.13, 11.4), PI * 1.25, 0.0, "floor1", false, 1.0])
	if forest_only:
		views.clear()
		for eye: Vector3 in [Vector3(-12,1.62,-78),Vector3(-12,1.62,-82),Vector3(-34,1.62,-82),Vector3(-34,1.62,-78)]:
			for yaw: float in [0.0,PI*0.5,PI,PI*1.5]:
				views.append([eye,yaw,0.08])
	lights.powerOn = false
	lights.set_night_immediate(1.0)
	flashlight.on = true
	flashlight.light.visible = true
	flashlight.set("_cinematic_suppressed", false)
	render_chain.set_vhs(&"rain", 0.85)
	var forest_warm_draws: Array = []
	var real_lamp_views := 0
	var real_lamp_draws: Array = []
	for view: Array in views:
		var home_view := view.size() > 3
		var zone_id := String(view[3]) if home_view else "plot"
		var outdoor := bool(view[4]) if home_view else true
		lights.powerOn = home_view
		lights.set_night_immediate(float(view[5]) if home_view else 1.0)
		if home_view:
			for id: String in lights.state:
				lights.setLamp(id, id in ["porch", "hall", "kitchen", "landing", "vitya"])
		render_chain.set_vhs(&"rain", 0.15 if home_view else 0.85)
		camera.global_transform = Transform3D(Basis.from_euler(Vector3(float(view[2]), float(view[1]), 0)), view[0])
		for item: Dictionary in environment_process: (item["node"] as EnvironmentLod)._process(0.0)
		var direction := -camera.global_basis.z
		var emitter := camera.global_position + camera.global_basis.x * 0.17 - camera.global_basis.y * 0.13 + direction * 0.18
		flashlight.set("_body", emitter)
		flashlight.set("_aim", camera.global_position + direction * 6.0)
		flashlight.light.light_energy = 14.0
		flashlight.update(0.0)
		echo.global_position = camera.global_position + direction * 3.0 - Vector3(0, 1.62, 0)
		echo.visible = true
		# Сначала рисуем выбранный реальный пул, затем независимые Omni-варианты.
		for lamp: OmniLight3D in warm_lamps: lamp.visible = false
		lights.update(1.0, camera.global_position, zone_id, outdoor)
		for _frame in 3: await get_tree().process_frame
		await RenderingServer.frame_post_draw
		if forest_only or camera.global_position in [Vector3(-12, 1.62, -78), Vector3(-34, 1.62, -78)]:
			forest_warm_draws.append(_forest_warm_record())
		if home_view:
			var picked: Array = lights.get("_lit")
			var lamp_ids: Array[String] = []
			for i in mini(picked.size(), lights.pool.size()):
				var lamp: OmniLight3D = lights.pool[i]
				if lamp.is_visible_in_tree() and lamp.light_energy > 0.02:
					lamp_ids.append(String(picked[i]["lamp"]["id"]))
			if not lamp_ids.is_empty(): real_lamp_views += 1
			real_lamp_draws.append({"eye": camera.global_position, "zone": zone_id,
				"outdoor": outdoor, "ids": lamp_ids})
		for count in 4:
			lights.update(1.0, camera.global_position, zone_id, outdoor)
			for lamp: OmniLight3D in lights.pool:
				lamp.visible = false
			for i in warm_lamps.size():
				warm_lamps[i].visible = i < count
				warm_lamps[i].global_position = camera.global_position + direction * (3.0 + i * 2.0)
			if count == 2:
				lights.moon.light_energy += 1.0
			for _frame in 3:
				await get_tree().process_frame
		if forest_only or camera.global_position in [Vector3(-12, 1.62, -78), Vector3(-34, 1.62, -78)]:
			# Actual colored forest meshes need the zero-Spot GLES variant too;
			# material preview quads have a different vertex layout.
			flashlight.on = false
			flashlight.light.light_energy = 0.0
			flashlight.light.visible = false
			flashlight.update(0.0)
			for count in 4:
				for i in warm_lamps.size(): warm_lamps[i].visible = i < count
				for _frame in 3: await get_tree().process_frame
				await RenderingServer.frame_post_draw
			forest_warm_draws.append(_forest_warm_record())
			flashlight.on = true
			flashlight.light.visible = true
	if not forest_only:
		set_meta("boot_label_warm", await preload("res://src/label_warmup.gd").warm(render_chain,warm_lamps,flashlight.light))
		await _warm_episode_figures(warm_lamps)
		await _warm_hand_models()
		await _warm_capture_views(warm_lamps)
		await _warm_departure_views(warm_lamps)
	else:
		await _warm_forest_corner_strip(warm_lamps)
	for lamp: OmniLight3D in warm_lamps:
		lamp.queue_free()
	camera.global_transform = camera_saved
	echo.transform = echo_transform
	echo.visible = echo_visible
	lights.restore(light_saved)
	lights.set("_clock_night", clock_saved)
	lights.set("_hemi_energy", hemi_saved)
	lights.set("_moon_energy", moon_saved)
	for saved: Dictionary in pool_saved:
		var lamp: OmniLight3D = saved["node"]
		lamp.transform = saved["transform"]
		lamp.visible = saved["visible"]
		lamp.light_energy = saved["energy"]
		lamp.light_color = saved["color"]
		lamp.omni_range = saved["range"]
	flashlight.restore(flash_saved)
	flashlight.light.global_transform = flash_transform
	flashlight.light.light_energy = flash_energy
	flashlight.light.shadow_enabled = flash_shadow
	flashlight.light.visible = flash_visible
	for key: String in flash_runtime:
		flashlight.set(key, flash_runtime[key])
	for key: StringName in flash_uniforms:
		RenderChain.set_shader_global(key, flash_uniforms[key])
	for saved: Dictionary in visual_saved:
		var node: Node3D = saved["node"]
		node.transform = saved["transform"]
		node.visible = saved["visible"]
	render_chain.set_vhs(&"rain", rain_saved)
	_restore_warm_visual(visual_guard)
	if forest_only: environment_occlusion.update()
	await get_tree().process_frame
	var restored_visual := _warm_visual_snapshot()
	var restore_differences: Array[String] = []
	for key: String in visual_guard:
		if visual_guard[key] != restored_visual.get(key): restore_differences.append(key)
	set_meta("boot_world_restore_differences",restore_differences)
	for item: Dictionary in environment_process: (item["node"] as EnvironmentLod).set_process(item["enabled"])
	if forest_only:
		set_meta("boot_occluded_forest_warm", forest_warm_draws)
		set_meta("boot_occluded_forest_restored", visual_guard == restored_visual)
		set_meta("boot_occluded_forest_policy_restored",occlusion_guard == _warm_occlusion_snapshot())
		return
	set_meta("boot_warm_ran", true)
	set_meta("boot_warm_restored", visual_guard == _warm_visual_snapshot())
	set_meta("boot_world_warm_views", views.size())
	set_meta("boot_episode_forest_warm", forest_warm_draws)
	set_meta("boot_world_real_lamp_views", real_lamp_views)
	set_meta("boot_world_real_lamp_draws", real_lamp_draws)
	set_meta("boot_world_warm_omni_counts", [0, 1, 2, 3])


func _warm_episode_figures(warm_lamps: Array[OmniLight3D]) -> void:
	var saved: Array = []
	for who: String in SntEpisodeActors.KEYS:
		var node: Node3D = episode_actors.figure(who)
		saved.append({"who":who,"node":node,"transform":node.transform,"visible":node.visible})
		node.visible = false
	var camera := render_chain.camera
	var direction := -camera.global_basis.z
	var records: Array = []
	for lamp: OmniLight3D in lights.pool: lamp.visible = false
	for item: Dictionary in saved:
		var who: String = item["who"]
		var at := camera.global_position+direction*2.8
		if who != "window_face": at -= Vector3(0,1.5,0)
		episode_actors.place(who,at.x,at.y,at.z)
		episode_actors.face(who,camera.global_position.x,camera.global_position.z)
		episode_actors.show(who,true)
		for on: bool in [false,true]:
			flashlight.on = on
			flashlight.light.visible = on
			flashlight.light.light_energy = 14.0 if on else 0.0
			flashlight.update(0.0)
			for count in 4:
				for i in warm_lamps.size():
					warm_lamps[i].visible = i < count
					warm_lamps[i].global_position = at+Vector3(i*.2,1,0)
				for frame in 3: await get_tree().process_frame
				await RenderingServer.frame_post_draw
				records.append({"who":who,"spot":on,"omni":count,"draw":render_chain.stats()})
		episode_actors.show(who,false)
	var restored := true
	for item: Dictionary in saved:
		var node: Node3D = item["node"]
		node.transform = item["transform"]
		node.visible = item["visible"]
		restored = restored and node.transform == item["transform"] and node.visible == item["visible"]
	set_meta("boot_episode_figure_warm",{"records":records,"restored":restored})


func _warm_forest_corner_strip(warm_lamps: Array[OmniLight3D]) -> void:
	var poses := [
		[Vector3(-9.5,1.68,-78),.50,-.006], [Vector3(-11.5,1.68,-78),.25,-.006],
		[Vector3(-11.98478,1.68,-78),-.07922,-.00639], [Vector3(-12,1.68,-78),0.0,-.007],
		[Vector3(-12,1.68,-79),0.0,-.012], [Vector3(-12,1.68,-80.7),.25,-.022],
		[Vector3(-12,1.68,-81.11296),.14712,-.02520], [Vector3(-12,1.68,-81.3),.50,-.027],
		[Vector3(-12,1.68,-81.75),PI*.5-.12,-.03], [Vector3(-12,1.68,-82),PI*.5+.12,-.03],
		[Vector3(-32,1.68,-82),PI*.5+.12,-.03], [Vector3(-34,1.68,-82),PI-.12,-.03],
		[Vector3(-34,1.68,-81.1),PI+.12,-.025], [Vector3(-34,1.68,-79),PI-.12,-.012],
		[Vector3(-34,1.68,-78),PI*.5+.12,-.006], [Vector3(-35,1.68,-78),PI*.5-.12,-.006]]
	var geometry: Array = SkinLayer._nodes(render_chain.world_root)
	var camera := render_chain.camera
	var records: Array = []
	for index in poses.size():
		var pose: Array = poses[index]
		var eye: Vector3 = pose[0]
		camera.global_transform = Transform3D(Basis.from_euler(Vector3(pose[2],pose[1],0),EULER_ORDER_YXZ),eye)
		for node: Node in geometry:
			if node is ForestLodMesh: node.update_for_camera(eye)
			elif node is EnvironmentLod: node._process(0.0)
		for lamp: OmniLight3D in warm_lamps: lamp.visible = false
		var feet := eye-Vector3(0,Player.STAND_HEIGHT-Player.EYE_DROP,0)
		var area: Dictionary = built["zone_at"].call(feet.x,feet.y,feet.z)
		lights.powerOn = true
		lights.set_night_immediate(.9)
		for on: bool in [false,true]:
			flashlight.on = on
			flashlight.light.visible = on
			flashlight.light.light_energy = 14.0 if on else 0.0
			var direction := -camera.global_basis.z
			flashlight.set("_body",eye+camera.global_basis.x*.17-camera.global_basis.y*.13+direction*.18)
			flashlight.set("_aim",eye+direction*6)
			flashlight.update(0.0)
			lights.update(1.0,eye,String(area.get("id","")),bool(area.get("outdoor",true)))
			environment_occlusion.update()
			for frame in 3: await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var record := _forest_warm_record()
			record["pose"] = index
			record["pitch"] = float(pose[2])
			record["forced_current_lod"] = true
			records.append(record)
	set_meta("boot_forest_corner_strip",records)


func _forest_warm_record() -> Dictionary:
	var camera := render_chain.camera
	var admitted: Array[String] = []
	for node: Node in SkinLayer._nodes(render_chain.world_root):
		if not node is MeshInstance3D or not node.has_meta("forest_background"): continue
		var mesh := node as MeshInstance3D
		var center := mesh.global_transform * mesh.mesh.get_aabb().get_center()
		if mesh.is_visible_in_tree() and (mesh.layers & camera.cull_mask) != 0 \
				and camera.is_position_in_frustum(center) \
				and (mesh.visibility_range_end == 0 or center.distance_to(camera.global_position) < mesh.visibility_range_end):
			admitted.append(String(mesh.get_path()))
	return {"eye":camera.global_position,"yaw":camera.rotation.y,"flashlight":flashlight.on,
		"spot_energy":flashlight.light.light_energy,"spot_visible":flashlight.light.is_visible_in_tree(),
		"forest_meshes_in_frustum":admitted,"native_occlusion":render_chain.world_view.use_occlusion_culling,
		"draw":render_chain.stats()}


func _warm_occlusion_snapshot() -> Array:
	var planes: Array[bool] = []
	for plane: RefCounted in environment_occlusion.get("_planes"):
		planes.append(bool(plane.get("active")))
	return [render_chain.world_view.use_occlusion_culling,planes,environment_occlusion.get("_light_policy_on")]


## HandView имеет собственные мир, прозрачный environment и свет. Квадраты
## Materials.warm_up в WorldView не прогревают его первый draw/mesh upload.
## Показываем реальные меши без выдачи/выбора предметов и восстанавливаем позы.
func _warm_hand_models() -> void:
	var visual_saved := _warm_visual_snapshot()
	var physics_saved := [col.get("_data").duplicate(true), col.get("_active").duplicate(true)]
	var models: Dictionary = (held_items.get("_models") as Dictionary).duplicate()
	models[HeldItems.FLASHLIGHT] = flashlight.model
	var post: ShaderMaterial = render_chain.get("_post_mat")
	var glass: StandardMaterial3D = flashlight.get("_glass_mat")
	var glass_saved := glass.albedo_color
	var records: Array = []
	var errors: Array[String] = []
	var expected_ids: Array[String] = []
	for id: String in HeldItems.SLOT_ORDER:
		if id != HeldItems.EMPTY: expected_ids.append(id)
	for model: Node3D in models.values(): model.visible = false
	render_chain.set("_hands_on", true)
	post.set_shader_parameter("hand_mix", 1.0)
	render_chain.hand_view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	for id: String in expected_ids:
		var model: Node3D = models.get(id)
		if model == null:
			errors.append("missing model: " + id)
			continue
		var geometry: Array[GeometryInstance3D] = []
		for node: Node in SkinLayer._nodes(model):
			if node is MeshInstance3D and node.mesh != null and node.layers != 0:
				geometry.append(node)
			elif node is MultiMeshInstance3D and node.multimesh != null \
					and node.multimesh.mesh != null and node.multimesh.instance_count > 0 and node.layers != 0:
				geometry.append(node)
		if geometry.is_empty(): errors.append("empty model: " + id)
		_warm_hand_fit(model, geometry)
		model.visible = true
		var variants: Array[String] = []
		variants.assign(["on", "off"] if id == HeldItems.FLASHLIGHT else ["base"])
		for variant: String in variants:
			if id == HeldItems.FLASHLIGHT:
				glass.albedo_color = Color(glass_saved, 0.85 if variant == "on" else 0.1)
			for node: GeometryInstance3D in geometry: node.visible = true
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var whole := _warm_hand_render_info()
			if int(whole["draw_calls"]) <= 0: errors.append("no model draw: " + id + "/" + variant)
			for node: GeometryInstance3D in geometry: node.visible = false
			# Один drawable за кадр: положительный GPU counter относится именно
			# к этим surface/material IDs, а не к соседнему видимому предмету.
			for node: GeometryInstance3D in geometry:
				node.visible = true
				await get_tree().process_frame
				await RenderingServer.frame_post_draw
				var draw := _warm_hand_render_info()
				var mesh: Mesh = node.mesh if node is MeshInstance3D else node.multimesh.mesh
				var instances := 1
				if node is MultiMeshInstance3D:
					instances = node.multimesh.instance_count
					if node.multimesh.visible_instance_count >= 0:
						instances = mini(instances, node.multimesh.visible_instance_count)
				var surfaces: Array = []
				for surface in mesh.get_surface_count():
					var material: Material = node.get_active_material(surface) if node is MeshInstance3D \
						else (node.material_override if node.material_override != null else mesh.surface_get_material(surface))
					surfaces.append({"surface": surface, "material_id": material.get_instance_id() if material != null else 0,
						"shader": material.shader.resource_path if material is ShaderMaterial and material.shader != null else "StandardMaterial3D"})
				var triangles := mesh.get_faces().size() / 3 * instances
				var verified := int(draw["draw_calls"]) >= mesh.get_surface_count() and int(draw["triangles"]) >= triangles
				if not verified: errors.append("incomplete drawable: " + String(node.get_path()) + "/" + variant)
				records.append({"id": id, "variant": variant, "node": String(node.get_path()),
					"mesh_id": mesh.get_instance_id(), "instances": instances, "surfaces": surfaces,
					"expected_triangles": triangles, "draw": draw, "model_draw": whole, "verified": verified})
				node.visible = false
		model.visible = false
	glass.albedo_color = glass_saved
	_restore_warm_visual(visual_saved)
	await get_tree().process_frame
	set_meta("boot_hand_warm", {"ids": expected_ids, "records": records, "errors": errors,
		"viewport": String(render_chain.hand_view.get_path()), "render_info_type": "visible",
		"restored": visual_saved == _warm_visual_snapshot(),
		"physics_restored": physics_saved == [col.get("_data"), col.get("_active")]})


func _warm_hand_render_info() -> Dictionary:
	var viewport := render_chain.hand_view.get_viewport_rid()
	return {"draw_calls": RenderingServer.viewport_get_render_info(viewport,
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_DRAW_CALLS_IN_FRAME),
		"triangles": RenderingServer.viewport_get_render_info(viewport,
		RenderingServer.VIEWPORT_RENDER_INFO_TYPE_VISIBLE, RenderingServer.VIEWPORT_RENDER_INFO_PRIMITIVES_IN_FRAME)}


func _warm_hand_fit(model: Node3D, geometry: Array[GeometryInstance3D]) -> void:
	var bounds := AABB()
	var first := true
	var parent_inverse := model.get_parent_node_3d().global_transform.affine_inverse()
	for node: GeometryInstance3D in geometry:
		var local := AABB()
		if node is MeshInstance3D:
			local = node.mesh.get_aabb()
		else:
			var mm: MultiMesh = node.multimesh
			for i in mm.instance_count:
				var part := mm.get_instance_transform(i) * mm.mesh.get_aabb()
				local = part if i == 0 else local.merge(part)
		var box: AABB = parent_inverse * node.global_transform * local
		bounds = box if first else bounds.merge(box)
		first = false
	if first: return
	var tangent := tan(deg_to_rad(render_chain.hand_camera.fov * 0.5))
	var aspect := float(render_chain.hand_view.size.x) / maxf(float(render_chain.hand_view.size.y), 1.0)
	var half := bounds.size * 0.5
	var depth := maxf(half.y / tangent, half.x / (tangent * aspect)) * 1.2 + half.z + 0.08
	model.position += Vector3(0, 0, -maxf(depth, 0.4)) - bounds.get_center()


func _warm_hand_snapshot() -> Dictionary:
	var nodes: Array = []
	for node: Node in SkinLayer._nodes(render_chain.hand_root):
		if not node is Node3D: continue
		var record := {"node": node, "transform": node.transform, "visible": node.visible}
		if node is GeometryInstance3D:
			record["material"] = node.material_override
			record["overlay"] = node.material_overlay
		if node is MeshInstance3D:
			record["mesh"] = node.mesh
		elif node is MultiMeshInstance3D:
			record["multimesh"] = node.multimesh
		nodes.append(record)
	var runtime: Dictionary = {}
	for key: String in ["_selected", "_available", "_known_available", "_synced", "_state_ref", "_state_revision",
			"_story_id", "_story_timer", "_action_timer", "_sway", "_pulse", "_cinematic_hidden"]:
		var value: Variant = held_items.get(key)
		runtime[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	return {"nodes": nodes, "runtime": runtime, "hands_on": render_chain.get("_hands_on"),
		"mode": render_chain.hand_view.render_target_update_mode,
		"mix": (render_chain.get("_post_mat") as ShaderMaterial).get_shader_parameter("hand_mix"),
		"flash_selection": flashlight.get("_viewmodel_selected"), "camera": render_chain.hand_camera.transform}


func _restore_warm_hand(saved: Dictionary) -> void:
	for record: Dictionary in saved["nodes"]:
		var node: Node3D = record["node"]
		node.transform = record["transform"]
		node.visible = record["visible"]
	render_chain.set("_hands_on", saved["hands_on"])
	render_chain.hand_view.render_target_update_mode = saved["mode"]
	(render_chain.get("_post_mat") as ShaderMaterial).set_shader_parameter("hand_mix", saved["mix"])


## Реальные меши кистей/лопаты и emissive лампы требуют первого GPU draw.
## Здесь нет поимки, аудио, таймеров или выдачи предметов.
func _warm_capture_views(warm_lamps: Array[OmniLight3D] = []) -> void:
	var visual_saved := _warm_visual_snapshot()
	var camera := render_chain.camera
	var echo: Node3D = actors.figures["echo"]
	var camera_saved := camera.global_transform
	var echo_saved := echo.transform
	var echo_visible := echo.visible
	var capture_saved := [capture.phase, capture.generation, state.snapshot()]
	camera.global_transform = Transform3D(Basis.IDENTITY, Vector3(-12.0, 1.62, -6.0))
	echo.global_position = camera.global_position + Vector3(0, -1.62, -2.0)
	echo.rotation.y = PI
	echo.visible = true
	var stages := {"run": 0.2, "stop": 0.15, "shovel_windup": 0.40, "shovel_impact": 0.08}
	var approach_views := [Vector3(-12.0, 1.62, -6.0), Vector3(0, 1.68, 2.0)]
	for eye: Vector3 in approach_views:
		camera.global_transform = Transform3D(Basis.IDENTITY, eye)
		echo.global_position = eye + Vector3(0, -1.62, -2.0)
		for action: String in stages:
			actors.sample_action("echo", action, float(stages[action]))
			for count in 4:
				for i in warm_lamps.size():
					warm_lamps[i].visible = i < count
					warm_lamps[i].global_position = echo.global_position + Vector3(0, 1.5, 0.5 + i)
				# Удар идёт без фонаря; его обычный вариант тоже прогревается.
				for flash_on: bool in [false, true]:
					flashlight.on = flash_on
					flashlight.light.visible = flash_on
					flashlight.set("_body", camera.global_position + Vector3(0.17, -0.13, -0.18))
					flashlight.set("_aim", echo.global_position + Vector3(0, 1.0, 0))
					flashlight.update(0.0)
					for _frame in 3: await get_tree().process_frame
	actors.end_action("echo")
	echo.visible = false
	for lamp: OmniLight3D in warm_lamps: lamp.visible = false
	# Первый кадр переноса стоит на росте1.68, после проверки потолка игрок приседает.
	for eye_height: float in [Player.STAND_HEIGHT - Player.EYE_DROP, 1.30, Player.CROUCH_HEIGHT - Player.EYE_DROP]:
		camera.global_transform = Transform3D(Basis.IDENTITY, CaptureRecovery.CELLAR + Vector3(0, eye_height, 0))
		lights.update(0.0, camera.global_position, "cellar", false)
		for light_on: bool in [false, true]:
			capture._make_light(light_on)
			for flash_on: bool in [false, true]:
				flashlight.on = flash_on
				flashlight.light.visible = flash_on
				flashlight.set("_body", camera.global_position + Vector3(0.17, -0.13, -0.18))
				flashlight.set("_aim", CaptureRecovery.CELLAR + Vector3(0, 1.1, -0.55))
				flashlight.update(0.0)
				# Нижний взгляд гарантирует первый draw emissive колбы и доски.
				camera.look_at(CaptureRecovery.CELLAR + Vector3(-0.7, 0.8, -1.3))
				for _frame in 3: await get_tree().process_frame
				camera.basis = Basis.IDENTITY
				for _frame in 3: await get_tree().process_frame
	capture._free_light()
	camera.global_transform = camera_saved
	echo.transform = echo_saved
	echo.visible = echo_visible
	lights.restore(visual_saved["lights"])
	flashlight.restore(visual_saved["flash"])
	for key: String in visual_saved["flash_runtime"]: flashlight.set(key, visual_saved["flash_runtime"][key])
	flashlight.light.global_transform = visual_saved["flash_node"][0]
	flashlight.light.visible = visual_saved["flash_node"][1]
	flashlight.light.light_energy = visual_saved["flash_node"][2]
	flashlight.light.shadow_enabled = visual_saved["flash_node"][3]
	(flashlight.get("_visual_rng") as RandomNumberGenerator).state = visual_saved["visual_rng"]
	for i in lights.pool.size():
		var lamp: OmniLight3D = lights.pool[i]
		lamp.transform = visual_saved["pool"][i][0]
		lamp.visible = visual_saved["pool"][i][1]
		lamp.light_energy = visual_saved["pool"][i][2]
		lamp.light_color = visual_saved["pool"][i][3]
		lamp.omni_range = visual_saved["pool"][i][4]
	_restore_warm_visual(visual_saved)
	await get_tree().process_frame
	set_meta("boot_capture_warm_ran", true)
	set_meta("boot_capture_warm_approaches", approach_views.size())
	set_meta("boot_capture_warm_restored", capture_saved == [capture.phase, capture.generation, state.snapshot()] \
		and (actors.get("_actions") as Dictionary).is_empty() and capture.get("_fixture") == null and capture.get("_board") == null \
		and visual_saved == _warm_visual_snapshot())


## Рисуем реквизит и ракурсы отъезда, не запуская главу, звук или Cutscene.
func _warm_departure_views(warm_lamps: Array[OmniLight3D] = []) -> void:
	var visual_saved := _warm_visual_snapshot()
	var physics_saved := [col.get("_data").duplicate(true), col.get("_active").duplicate(true)]
	var runtime_saved := [cutscene.playing, cutscene.paused, cutscene.time(), horror.generation,
		chapters.timers.duplicate(true), running, paused, busy]
	var camera := render_chain.camera
	var echo: Node3D = actors.figures["echo"]
	var fixture := Node3D.new()
	fixture.name = "BootDepartureWarm"
	render_chain.world_root.add_child(fixture)
	var car: Node3D = props.get_prop("car")
	var car_origin := car.global_position if car != null else Vector3(1.15, 0, -2.72)
	# Копируем только видимые меши: сюжетный holder, pivots и physics не трогаем.
	var car_visual := Node3D.new()
	car_visual.name = "CarVisual"
	fixture.add_child(car_visual)
	var car_meshes := 0
	if car != null:
		car_visual.global_transform = car.global_transform
		for node: Node in SkinLayer._nodes(car):
			if not node is MeshInstance3D: continue
			var source := node as MeshInstance3D
			if source.mesh == null or source.layers == 0 or not source.is_visible_in_tree(): continue
			var copy := MeshInstance3D.new()
			copy.mesh = source.mesh
			copy.material_override = source.material_override
			copy.material_overlay = source.material_overlay
			copy.layers = source.layers
			copy.cast_shadow = source.cast_shadow
			copy.lod_bias = source.lod_bias
			copy.extra_cull_margin = source.extra_cull_margin
			copy.custom_aabb = source.custom_aabb
			copy.transparency = source.transparency
			for i in source.get_surface_override_material_count():
				copy.set_surface_override_material(i, source.get_surface_override_material(i))
			car_visual.add_child(copy)
			copy.transform = car.global_transform.affine_inverse() * source.global_transform
			car_meshes += 1
	var lamps: Array[OmniLight3D] = []
	var cones: Array[MeshInstance3D] = []
	var halos: Array[MeshInstance3D] = []
	var pools: Array[MeshInstance3D] = []
	for i in 3:
		var lamp := OmniLight3D.new()
		lamp.shadow_enabled = false
		lamp.omni_range = 11.0 if i < 2 else 5.0
		lamp.light_color = GameData.color(0xf3e6bd if i < 2 else 0xb8c49c)
		lamp.light_energy = 2.6 if i < 2 else 1.30
		fixture.add_child(lamp)
		lamps.append(lamp)
		if i == 2: continue
		var cone := LightCone.make_headlight("WarmHeadlightCone")
		fixture.add_child(cone)
		cones.append(cone)
		var halo := LightCone.make_headlight_halo("WarmHeadlightHalo")
		fixture.add_child(halo)
		halos.append(halo)
		var pool_spot := LightCone.make_headlight_pool("WarmHeadlightPool")
		fixture.add_child(pool_spot)
		pools.append(pool_spot)
	var smoke := StandardMaterial3D.new()
	smoke.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	smoke.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	smoke.albedo_color = Color(0.48, 0.49, 0.48, 0.17)
	# BaseMaterial освобождает generated shader при последнем владельце.
	# Resource остаётся жить, временные Node3D полностью удаляются.
	set_meta("boot_departure_resources", [smoke])
	var exhaust: Array[MeshInstance3D] = []
	for i in 6:
		var sphere := SphereMesh.new()
		sphere.radius = 0.18
		sphere.height = 0.30
		sphere.radial_segments = 8
		sphere.rings = 4
		sphere.material = smoke
		var puff := MeshInstance3D.new()
		puff.mesh = sphere
		puff.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		fixture.add_child(puff)
		exhaust.append(puff)
	flashlight.on = false
	flashlight.set_cinematic_suppressed(true)
	flashlight.update(0.0)
	for lamp: OmniLight3D in warm_lamps: lamp.visible = false
	lights.powerOn = false
	lights.set_night_immediate(1.0)
	var shot_start := 0.0
	var views := 0
	var shots_warmed: Array[int] = []
	for shot_index in Chapters.DRIVE_SHOTS.size():
		var shot: Dictionary = Chapters.DRIVE_SHOTS[shot_index]
		for fraction: float in [0.0, 0.5, 1.0]:
			var q := smoothstep(0.0, 1.0, fraction)
			var eye: Vector3 = shot["pos"].lerp(shot.get("pos_to", shot["pos"]), q)
			var at: Vector3 = shot["look_at"].lerp(shot.get("look_at_to", shot["look_at"]), q)
			camera.global_transform = Transform3D(Basis.looking_at((at - eye).normalized(), Vector3.UP), eye)
			var t := shot_start + float(shot["sec"]) * fraction
			var travel := 40.0 * pow(clampf((t - Chapters.DRIVE_START) / (Chapters.DRIVE_LEN - Chapters.DRIVE_START), 0.0, 1.0), 2)
			car_visual.global_position = car_origin + Vector3(-travel, 0, 0)
			echo.global_position = Vector3(minf(0.35, car_visual.global_position.x + 3.05), 0, car_origin.z + 0.10)
			echo.visible = true
			actors.face("echo", car_visual.global_position.x, car_visual.global_position.z)
			var running_pose := t >= Chapters.DRIVE_START and t < Chapters.DRIVE_STOP_CHASE
			actors.sample_action("echo", "run" if running_pose else "stop", maxf(0.0, t - (Chapters.DRIVE_START if running_pose else Chapters.DRIVE_STOP_CHASE)))
			for i in 2:
				var origin := car_visual.global_position + Vector3(-2.05, 0.62, -0.62 + 1.24 * i)
				lamps[i].global_position = origin
				LightCone.aim(cones[i], origin, origin + Vector3(-11, -0.75, 0))
				cones[i].visible = render_chain.render_preset() == RenderChain.PRESET_HQ
				halos[i].visible = cones[i].visible
				pools[i].visible = cones[i].visible
				LightCone.update_halo(halos[i], origin, eye)
				LightCone.place_pool(pools[i], Vector3(origin.x - 5.0, LightCone.POOL_Y_OFFSET, origin.z), LightCone.HEADLIGHT_POOL_STRENGTH)
			lamps[2].global_position = echo.global_position + Vector3(0, 1.45, -1.20)
			for i in exhaust.size():
				exhaust[i].global_position = car_visual.global_position + Vector3(2.20 + i * 0.12, 0.40 + i * 0.035, 0.55)
				exhaust[i].scale = Vector3.ONE * (0.55 + i * 0.15)
			for count in 4:
				lights.update(1.0, eye, "plot", true)
				for lamp: OmniLight3D in lights.pool: lamp.visible = false
				for i in lamps.size(): lamps[i].visible = i < count
				for _frame in 3: await get_tree().process_frame
			views += 1
		shots_warmed.append(shot_index)
		shot_start += float(shot["sec"])
	actors.end_action("echo")
	fixture.free()
	camera.global_transform = visual_saved["camera"]
	echo.transform = visual_saved["echo"][0]
	echo.visible = visual_saved["echo"][1]
	lights.restore(visual_saved["lights"])
	flashlight.restore(visual_saved["flash"])
	for key: String in visual_saved["flash_runtime"]: flashlight.set(key, visual_saved["flash_runtime"][key])
	flashlight.light.global_transform = visual_saved["flash_node"][0]
	flashlight.light.visible = visual_saved["flash_node"][1]
	flashlight.light.light_energy = visual_saved["flash_node"][2]
	flashlight.light.shadow_enabled = visual_saved["flash_node"][3]
	(flashlight.get("_visual_rng") as RandomNumberGenerator).state = visual_saved["visual_rng"]
	for i in lights.pool.size():
		var lamp: OmniLight3D = lights.pool[i]
		lamp.transform = visual_saved["pool"][i][0]
		lamp.visible = visual_saved["pool"][i][1]
		lamp.light_energy = visual_saved["pool"][i][2]
		lamp.light_color = visual_saved["pool"][i][3]
		lamp.omni_range = visual_saved["pool"][i][4]
	_restore_warm_visual(visual_saved)
	await get_tree().process_frame
	set_meta("boot_departure_warm_ran", true)
	set_meta("boot_departure_warm_views", views)
	set_meta("boot_departure_warm_shots", shots_warmed)
	set_meta("boot_departure_warm_omni_counts", [0, 1, 2, 3])
	set_meta("boot_departure_warm_car_meshes", car_meshes)
	set_meta("boot_departure_warm_physics_restored", physics_saved == [col.get("_data"), col.get("_active")])
	set_meta("boot_departure_warm_restored", visual_saved == _warm_visual_snapshot() \
		and runtime_saved == [cutscene.playing, cutscene.paused, cutscene.time(), horror.generation, chapters.timers, running, paused, busy] \
		and (actors.get("_actions") as Dictionary).is_empty())


func _warm_actor_snapshot() -> Array:
	var snapshot: Array = []
	var stack: Array[Node] = [actors.figures["echo"]]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child: Node in node.get_children(): stack.append(child)
		if node is Node3D:
			var saved := {"node": node, "transform": node.transform, "visible": node.visible}
			if node is MeshInstance3D:
				saved["mesh"] = node.mesh
				saved["material"] = node.material_override
				var surfaces: Array = []
				for i in node.get_surface_override_material_count(): surfaces.append(node.get_surface_override_material(i))
				saved["surfaces"] = surfaces
			snapshot.append(saved)
	return snapshot


## Снимок guard хранится только на время boot. В metadata остаётся bool,
## а сохранение игрока и пользовательский профиль здесь только читаются.
func _warm_visual_snapshot() -> Dictionary:
	var environment: Dictionary = {}
	for key: String in ["ambient_light_color", "ambient_light_energy", "background_color",
			"background_energy_multiplier", "fog_enabled", "fog_light_color", "fog_density",
			"fog_light_energy", "fog_sky_affect"]:
		environment[key] = render_chain.world_env.get(key)
	var shader_globals: Dictionary = {}
	for key: StringName in [&"psx_fog_color", &"psx_fog_near", &"psx_fog_far",
			&"flashlight_on", &"flashlight_proj", &"flashlight_pos"]:
		shader_globals[key] = RenderChain.get_shader_global(key)
	var cache: Dictionary = {}
	for key: String in ["_clock_night", "_hemi_energy", "_moon_energy", "_last_hq", "_lit", "_bulb_lit"]:
		var value: Variant = lights.get(key)
		cache[key] = value.duplicate(true) if value is Array or value is Dictionary else value
	var colors := PackedColorArray()
	for i in lights.bulbs.multimesh.instance_count:
		colors.append(lights.bulbs.multimesh.get_instance_color(i))
	var nodes: Array = [flashlight.cone, flashlight.halo, flashlight.model]
	nodes.append_array(lights.cones.values())
	nodes.append_array(lights.halos.values())
	nodes.append_array(lights.light_pools.values())
	var effects: Array = []
	for node: Node3D in nodes:
		var effect := {"node": node, "transform": node.transform, "visible": node.visible}
		if node is GeometryInstance3D:
			var params: Dictionary = {}
			var names: Array[StringName] = [&"pool_strength"]
			if node == flashlight.cone or lights.cones.values().has(node):
				names = [&"beam_strength"]
			elif node == flashlight.halo or lights.halos.values().has(node):
				names = [&"halo_size", &"halo_strength"]
			for key: StringName in names:
				params[key] = node.get_instance_shader_parameter(key)
			effect["params"] = params
		effects.append(effect)
	var flash_runtime: Dictionary = {}
	for key: String in ["_body", "_aim", "_flicker", "_shake", "_shadow_on", "_proj_on", "_proj_cone", "_cinematic_suppressed"]:
		flash_runtime[key] = flashlight.get(key)
	var lamp_pool: Array = []
	for lamp: OmniLight3D in lights.pool:
		lamp_pool.append([lamp.transform, lamp.visible, lamp.light_energy, lamp.light_color, lamp.omni_range])
	var echo: Node3D = actors.figures["echo"]
	return {"state": state.snapshot(), "checkpoint": JSON.stringify(state.checkpoint),
		"forest_lod":_warm_forest_lod_snapshot(),
		"environment_lod":_warm_environment_lod_snapshot(),
		"revision": state.runtime_revision, "settings": ui.settings().duplicate(true),
		"player": [player.transform, player.yaw, player.pitch, player.yaw_target, player.pitch_target, player.enabled],
		"camera": render_chain.camera.global_transform, "preset": render_chain.render_preset(),
		"lights": lights.snapshot(), "cache": cache, "pool": lamp_pool,
		"moon": [lights.moon.light_color, lights.moon.light_energy], "environment": environment,
		"globals": shader_globals, "bulbs": colors, "effects": effects,
		"flash": flashlight.snapshot(), "flash_runtime": flash_runtime,
		"flash_node": [flashlight.light.global_transform, flashlight.light.visible,
			flashlight.light.light_energy, flashlight.light.shadow_enabled],
		"flash_brightness": (flashlight.cone.material_override as ShaderMaterial).get_shader_parameter("brightness"),
		"flash_glass": (flashlight.get("_glass_mat") as StandardMaterial3D).albedo_color,
		"visual_rng": (flashlight.get("_visual_rng") as RandomNumberGenerator).state,
		"echo": [echo.transform, echo.visible], "echo_pose": _warm_actor_snapshot(),
		"capture": [capture.phase, capture.generation], "rain": render_chain.get_vhs(&"rain"),
		"world_children": render_chain.world_root.get_child_count(), "hand": _warm_hand_snapshot()}


func _restore_warm_visual(saved: Dictionary) -> void:
	for item: Dictionary in saved.get("environment_lod",[]):
		var node: EnvironmentLod = item["node"]
		node.current_level = item["level"]
		node.mesh = item["mesh"]
		node._sync_shadow_caster()
	for item: Dictionary in saved.get("forest_lod",[]):
		var tree: ForestLodMesh = item["node"]
		tree.mesh = item["mesh"]
		tree.far_ids = item["far_ids"].duplicate()
		tree.background_ids = item["background_ids"].duplicate()
		tree.far_active = item["far_active"]
		tree.set_meta("forest_lod_far_ids",tree.far_ids.keys())
		tree.set_meta("forest_lod_background_ids",tree.background_ids.keys())
		tree.set("_elapsed",0.0)
		tree.call("_invalidate_camera_inputs")
	_restore_warm_hand(saved["hand"])
	for key: String in saved["environment"]:
		render_chain.world_env.set(key, saved["environment"][key])
	for key: StringName in saved["globals"]:
		RenderChain.set_shader_global(key, saved["globals"][key])
	for key: String in saved["cache"]:
		lights.set(key, saved["cache"][key])
	lights.moon.light_color = saved["moon"][0]
	lights.moon.light_energy = saved["moon"][1]
	var colors: PackedColorArray = saved["bulbs"]
	for i in colors.size():
		lights.bulbs.multimesh.set_instance_color(i, colors[i])
	for effect: Dictionary in saved["effects"]:
		var node: Node3D = effect["node"]
		node.transform = effect["transform"]
		node.visible = effect["visible"]
		if node is GeometryInstance3D:
			for key: StringName in effect["params"]:
				node.set_instance_shader_parameter(key, effect["params"][key])
	(flashlight.cone.material_override as ShaderMaterial).set_shader_parameter("brightness", saved["flash_brightness"])
	(flashlight.get("_glass_mat") as StandardMaterial3D).albedo_color = saved["flash_glass"]


func _warm_forest_lod_snapshot() -> Array:
	var result: Array = []
	for node: Node in SkinLayer._nodes(render_chain.world_root):
		if node is ForestLodMesh:
			result.append({"node":node,"mesh":node.mesh,"far_ids":node.far_ids.duplicate(),
				"background_ids":node.background_ids.duplicate(),"far_active":node.far_active})
	return result

func _warm_environment_lod_snapshot() -> Array:
	var result: Array = []
	for node: Node in SkinLayer._nodes(render_chain.world_root):
		if node is EnvironmentLod: result.append({"node":node,"level":node.current_level,"mesh":node.mesh})
	return result


func _set_skin_enabled(active: bool) -> void:
	if environment_static_interiors != null:
		environment_static_interiors.restore()
		environment_static_interiors = null
	if props_skin != null:
		props_skin.set_active(render_chain.world_root, active, props, mats)


## Настройки экрана паузы. Скример хранит свой флаг в user://vitya.cfg —
## галочка синхронизируется с сохранённым значением, а не наоборот.
func _apply_settings() -> void:
	# Яркость и чёткость читаются из того же user://vitya.cfg, где лежат
	# скримеры: галочка синхронизируется с сохранённым значением, а не наоборот.
	ui.setSettings({
		"scares": scare.enabled,
		"brightness": Overlays.read_brightness(),
		"sharpness": Overlays.read_sharpness(get_window().size.y),
	})
	var s := ui.settings()
	player.sensitivity = float(s.get("sens", player.sensitivity))
	player.look_smooth = float(s.get("smooth", player.look_smooth))
	player.invert_y = bool(s.get("invert", player.invert_y))
	audio.set_volume(float(s.get("volume", audio.volume)))
	render_chain.set_exposure(float(s.get("brightness", RenderChain.TONEMAP_EXPOSURE)))
	render_chain.set_sharpness(Overlays.sharpness_height(int(s.get("sharpness", 1))))


func _wire_ui() -> void:
	ui.start_pressed.connect(_start_game)
	ui.resume_pressed.connect(func() -> void:
		_set_paused(false)
		player.request_lock())
	ui.restart_pressed.connect(_on_restart)
	ui.fullscreen_pressed.connect(_on_fullscreen)
	ui.sens_changed.connect(func(v: float) -> void:
		if player != null:
			player.sensitivity = v)
	ui.smooth_changed.connect(func(v: float) -> void:
		if player != null:
			player.look_smooth = v)
	ui.volume_changed.connect(func(v: float) -> void: audio.set_volume(v))
	ui.invert_changed.connect(func(on: bool) -> void:
		if player != null:
			player.invert_y = on)
	ui.scares_changed.connect(func(on: bool) -> void: scare.enabled = on)
	ui.brightness_changed.connect(func(v: float) -> void: render_chain.set_exposure(v))
	ui.sharpness_changed.connect(func(h: int) -> void: render_chain.set_sharpness(h))


# ---------- цикл ----------

func _everyday_suspended() -> bool:
	if (capture != null and capture.active()) or (cutscene != null and cutscene.playing) \
			or (horror != null and horror.exclusive()):
		return true
	for key: String in ["outskirts", "snt"]:
		var quest: Variant = ctx.get(key)
		if quest != null and quest.has_method("exclusive_runtime") and bool(quest.exclusive_runtime()):
			return true
	return false

func _process(delta: float) -> void:
	if _frame_probe_on:
		_frame_probe.clear()
		_frame_probe_us = Time.get_ticks_usec()
	var dt := clampf(delta, 0.0, 0.05)
	if running and capture != null and not capture.active() and not state.recovery.is_empty():
		if everyday != null:
			everyday.cancel_runtime()
		capture.resume_saved()

	ui.update(dt)
	if running and not paused and capture != null:
		capture.update_external(dt)
	if not paused and not (capture != null and capture.active()):
		phone.update(dt)
	tape_player.update(dt)
	# Скример идёт поверх заморозки, которую сам же и создаёт через ui.busy,
	# поэтому обновляется до проверки frozen, а не внутри неё.
	scare.update(dt)
	ui.scareOpen = scare.open
	_frame_probe_step("ui-dialogue")
	if horror != null and running:
		horror.update(dt, paused or ui.busy or phone.open or phone.talking or tape_player.open or busy)
	_frame_probe_step("horror")
	if everyday != null and _everyday_suspended():
		everyday.cancel_runtime()

	# Катсцена идёт СВОИМ временем и поверх заморозки: игрок в ней не участвует,
	# а кадр обязан жить. Ставится до frozen — сцена сама и есть причина того,
	# что мир на это время замер.
	if cutscene != null and cutscene.playing and not paused:
		cutscene.update(dt)

	var frozen := paused or ui.busy or phone.open or tape_player.open \
		or (cutscene != null and cutscene.playing)
	if audio.has_method("set_spatial_paused"):
		audio.call("set_spatial_paused", not running or paused or ui.busy or phone.open or tape_player.open,
			not running or paused or ui.busy or tape_player.open)
	if held_items != null:
		held_items.sync(state)
	if running and not frozen:
		EnvironmentLandscape.update(built, dt)

	_frame_probe_step("held-sync-environment")
	if running and not frozen:
		player.update(dt)
		_frame_probe_step("player")
		if pursuit != null and not capture.active(): pursuit.update(dt)
		_frame_probe_step("pursuit")
		if episode_actors != null: episode_actors.update(dt)
		held_items.update(dt, player)
		var outskirts_runtime: Variant = ctx.get("outskirts")
		if (capture == null or not capture.active()) and outskirts_runtime != null and outskirts_runtime.has_method("update"):
			outskirts_runtime.update(dt)
		var snt_runtime: Variant = ctx.get("snt")
		if snt_runtime != null and (capture == null or not capture.active()):
			snt_runtime.update(dt)
		_frame_probe_step("actors-quests")
		var exclusive_runtime: bool = outskirts_runtime != null \
			and outskirts_runtime.has_method("exclusive_runtime") \
			and bool(outskirts_runtime.exclusive_runtime())
		if snt_runtime != null:
			exclusive_runtime = exclusive_runtime or bool(snt_runtime.exclusive_runtime())
		if pursuit != null:
			exclusive_runtime = exclusive_runtime or pursuit.active()
		if everyday != null:
			if _everyday_suspended():
				everyday.cancel_runtime()
			else:
				everyday.update(dt)
		# Зона считается сразу после движения: свет, погода и остальные системы
		# этого кадра должны видеть помещение, в которое игрок уже вошёл.
		_frame_probe_step("everyday")
		var feet := player.feet()
		var zone_now: Dictionary = (built["zone_at"] as Callable).call(feet.x, feet.y, feet.z)
		if zone_now.get("id", "") != zone.get("id", ""):
			zone = zone_now
			var reverb := String(zone.get("reverb", "outdoor"))
			audio.set_zone(reverb)
			audio.set_outdoor_level(1.0 if reverb == "outdoor" else 0.25)
		var outdoor := String(zone.get("reverb", "outdoor")) == "outdoor"
		_frame_probe_step("zone")
		_update_water_surface(feet)
		_player_sfx(dt)
		flashlight.update(dt, player)
		lights.set_clock_seconds(state.clock_seconds())
		lights.update(dt, render_chain.camera.global_position, String(zone.get("id", "")), outdoor)
		# Строго после света: вспышка грозы — это прибавка к той энергии луны,
		# которую свет только что посчитал.
		# ОТЛАДКА (фаза 17). Сухой режим держит дождь на нуле КАЖДЫЙ кадр,
		# а не гасит его один раз. Однократно бесполезно: главы ставят погоду
		# сами и не по одному разу (_gate_enter 0.45, _gate_storm 0.9 плюс
		# разряды), и через минуту экран снова в помехах. Шейдер рисует дождь
		# той же VHS-рябью, что и плёнку, — отлаживать финал в грозу нельзя,
		# не видно ни геометрии, ни точек интеракта.
		if debug_dry:
			weather.set_rain(0.0)
		weather.update(dt, outdoor)
		_frame_probe_step("lights-weather-sfx")
		if not exclusive_runtime and not _dialogue_frozen and (capture == null or not capture.active()):
			chapters.update(dt)
		if _runtime_free():
			threat.update(dt)
		# Порядок threat -> tension -> haunt -> dread -> omens не случайный:
		# шкала обязана видеть позицию деда ЭТОГО кадра, а все, кто её
		# спрашивает, — уже посчитанную шкалу.
		if _runtime_free(): tension.update(dt)
		if (_runtime_free() and horror.random_allowed()) or (horror.owner == "haunt" and not phone.talking and not capture.active()):
			var was_shown := haunt.shown
			haunt.update(dt)
			if haunt.shown > was_shown:
				horror.ambient_started("haunt", haunt.ttl + 0.1)
		if _runtime_free() and horror.random_allowed():
			var was_shown := dread.shown
			dread.update(dt)
			if dread.shown > was_shown: horror.ambient_started("dread")
		if _runtime_free():
			omens.global_cd = maxf(omens.global_cd, horror.cooldown)
			var was_shown := omens.shown
			omens.update(dt)
			if omens.shown > was_shown: horror.ambient_started("omens")
		# Испуги по местам — после знаков: двойника они берут через holdEcho,
		# то есть haunt в этом кадре уже отработал и с дороги ушёл.
		if (_runtime_free() and horror.random_allowed()) or \
			(horror.owner == "ambient" and not phone.talking and String(startle.get("_live")) != "" and not capture.active()):
			startle.update(dt)
		# Соседи и улица — последними: на угрозу они не влияют, а точка
		# «заговорить» едет за Аркадием и обязана встать на место в том же
		# кадре, в котором её будет искать interact.find() ниже.
		if _runtime_free():
			neighbours.update(dt)
		elif not capture.active() and neighbours.enabled:
			# Постоянная жительница остаётся видна во время постановочных испугов.
			# Случайные появления остальных соседей ждут освобождения сцены.
			neighbours._valya(dt)
		if _street_runtime_free(): street.update(dt)
		# Дед на линии — после квеста: квест решает, вышел ли он вообще.
		if _street_runtime_free(): stalk.update(dt)
		if capture == null or not capture.active(): state.tick(dt)
		# Любой контроллер выше мог синхронно начать поимку.
		if capture != null and capture.phase == "hit":
			interact.target = null
			_hatch = null
			ui.setPrompt(null, null)
			return
		if hatch_cooldown > 0.0:
			hatch_cooldown -= dt

		# Люк уступает только сюжетному действию. Осмотр и выключатель рядом
		# с ним не должны отнимать «спуститься»: приоритет 2 и выше — двери,
		# щиток, кассеты, тайник — важнее люка, на них смотрят в упор.
		_frame_probe_step("runtime-ai")
		var found: Variant = interact.find(render_chain.camera, state)
		var hatch: Variant = _hatch_near(feet)
		var minor := found is Dictionary \
			and (String(found.get("kind", "")) == "look" or int(found.get("priority", 0)) <= 1)
		var target: Variant = null if (hatch != null and minor) else found
		if target == null:
			interact.target = null
		# Спрятавшись, игрок видит одну подсказку и ничего больше: пока он
		# сидит в шкафу, ему нечего осматривать и нечего включать.
		if state.hidden:
			ui.setPrompt("E", "выйти")
		elif target != null:
			ui.setPrompt("E", interact.promptFor(target, state))
		elif hatch != null:
			ui.setPrompt("E", ("спуститься · " if hatch["down"] else "подняться · ")
				+ String(hatch["hatch"].get("label", "")))
		else:
			ui.setPrompt(null, null)
		_hatch = null if target != null else hatch

		_frame_probe_step("interact-prompt")
		ui.setClock(state.timecode())
	elif running:
		if street != null: street.cancel_runtime()
		flashlight.update(dt, player)

	_frame_probe_step("ui-clock")
	render_chain.render(dt)

	_frame_probe_step("render-prepare")
	_clock_acc += dt
	_clock_frames += 1
	if _clock_acc > 0.5:
		_fps = _clock_frames / _clock_acc
		_clock_acc = 0.0
		_clock_frames = 0
	if debug:
		_draw_debug()

	if flashlight != null:
		ui.setBattery(flashlight.owned, flashlight.battery)
		ui.setLockHint(running and not paused and not ui.busy
			and not phone.open and not tape_player.open and not player.is_locked())


func _frame_probe_step(label: String) -> void:
	if not _frame_probe_on: return
	var now := Time.get_ticks_usec()
	_frame_probe[label] = float(now - _frame_probe_us) / 1000.0
	_frame_probe_us = now


## Люк рядом? Три условия сверх попадания в прямоугольник: onFloor (в полёте
## и на лестнице подсказка мигала), взгляд в сторону проёма (стоя спиной
## игрок жал [E] по инерции) и кулдаун. Стоя ровно на точке перехода
## направление не определено — там проверку взгляда пропускаем.
func _hatch_near(pos: Vector3) -> Variant:
	if not player.on_floor or hatch_cooldown > 0.0:
		return null
	var fx := -sin(player.yaw)
	var fz := -cos(player.yaw)

	for h in _hatches:
		if capture != null and capture.active() and not capture.hatch_allowed(String(h.get("id", "")), false):
			continue
		var rect: Array = h["rect"]
		var pad := 0.75
		if pos.x <= float(rect[0]) - pad or pos.x >= float(rect[1]) + pad \
				or pos.z <= float(rect[2]) - pad or pos.z >= float(rect[3]) + pad:
			continue

		var dx := (float(rect[0]) + float(rect[1])) * 0.5 - pos.x
		var dz := (float(rect[2]) + float(rect[3])) * 0.5 - pos.z
		var len := sqrt(dx * dx + dz * dz)
		if len > 0.35 and (dx / len) * fx + (dz / len) * fz < 0.2:
			continue

		if absf(pos.y - float(h["top"][1])) < 1.4:
			return {"hatch": h, "down": true}
		if absf(pos.y - float(h["bottom"][1])) < 1.9:
			return {"hatch": h, "down": false}
	return null


## Выйти из укрытия. Живёт рядом с _use_hatch, потому что это тот же класс
## действия: не предмет под прицелом, а состояние, из которого выходят.
func _leave_hiding() -> void:
	state.hidden = false
	player.frozen = false
	player.enabled = not paused
	audio.sfx("hide-leave")
	ui.say("Тихо. Пока тихо.", 2.6)


func _use_hatch(h: Dictionary) -> void:
	var hatch: Dictionary = h["hatch"]
	if capture != null and not capture.hatch_allowed(String(hatch.get("id", "")), bool(h["down"])):
		return
	if hatch.get("needs") == "ladder" and not state.hasItem("ladder"):
		ui.say("Высоко. Нужна стремянка — она в кладовке под лестницей.", 4.2)
		return
	if busy:
		return
	busy = true
	var recovery_exit := capture != null and capture.phase == "cellar"
	var capture_generation := capture.generation if capture != null else -1
	if recovery_exit: capture.begin_exit()
	player.enabled = false
	audio.creak(1.0)
	# Люк, до которого дотягиваются стремянкой, скрипит не так, как половица.
	if hatch.get("needs") == "ladder":
		audio.sfx("ladder-step")
	await _fade_to(0.0, 0.4)
	if capture != null and capture_generation != capture.generation:
		return
	var t: Array = hatch["bottom"] if h["down"] else hatch["top"]
	player.place(float(t[0]), float(t[1]), float(t[2]), player.yaw)
	if String(hatch.get("id", "")) == "hatch-roof" and not h["down"]:
		_ctx_emit("roof-entered")
	await get_tree().process_frame
	await _fade_to(1.0, 0.5)
	if capture != null and capture_generation != capture.generation:
		return
	if recovery_exit: capture.finish_exit()
	player.enabled = not paused
	busy = false
	hatch_cooldown = 0.6


func _fade_to(target: float, seconds: float) -> void:
	if _fade_tween != null and _fade_tween.is_valid(): _fade_tween.kill()
	var tw := create_tween()
	_fade_tween = tw
	tw.tween_method(render_chain.set_fade, render_chain.get_fade(), target, seconds)
	if paused: tw.pause()
	await tw.finished


func _draw_debug() -> void:
	var s := render_chain.stats()
	var f := player.feet() if player != null else Vector3.ZERO
	var target_id := "—"
	if interact != null and interact.target is Dictionary:
		target_id = String((interact.target as Dictionary).get("id", "—"))
	ui.setDebug(
		"fps    %.0f\n" % _fps
		+ "calls  %s   tris %s\n" % [s.get("calls", 0), s.get("tris", 0)]
		+ "buffer %s\n" % s.get("buffer", "—")
		+ "pos    %.2f %.2f %.2f\n" % [f.x, f.y, f.z]
		+ "zone   %s\n" % (String(zone.get("id")) if not zone.is_empty() else "—")
		+ "глава  %s  %s\n" % [state.chapter, state.timecode()]
		+ "задача %s\n" % (String(state.task) if state.task != null else "—")
		+ "угроза %s  провалов %d\n" % [state.threatState, state.failCount]
		+ "мельк. %s\n" % (haunt.debug_line() if haunt != null else "—")
		+ "%s\n" % (dread.debug_line() if dread != null else "тревога —")
		+ "%s\n" % (tension.debug_line() if tension != null else "давл —")
		+ "%s\n" % (omens.debug_line() if omens != null else "знаки —")
		+ "%s\n" % (startle.debug_line() if startle != null else "испуг —")
		+ "цель   %s" % target_id)


# Порт visibilitychange: свернули окно — пауза и тишина.
func _notification(what: int) -> void:
	if audio == null:
		return
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		audio.mute(true)
		if running and not paused and not ui.busy and not phone.open and not tape_player.open:
			_set_paused(true)
	elif what == NOTIFICATION_APPLICATION_FOCUS_IN:
		if not paused:
			audio.mute(false)


# ---------- шаги ----------

func _on_step(run: bool, crouch: bool) -> void:
	_update_water_surface(player.feet())
	var surface := "water" if _water_surface != "dry" else String(zone.get("floor", "wood"))
	audio.step(surface, run, crouch)
	# Третья ступенька скрипит. Витя всегда через неё перешагивал.
	var f := player.feet()
	if f.x < -4.4 and f.x > -5.6 and f.z > 10.4 and f.z < 10.9 and f.y > 0.8 and f.y < 1.3:
		if randf() < 0.8:
			audio.creak(1.1)


# Присед, шорох куртки и одышка — поллингом по смене состояния игрока.
# Заводить ради них два сигнала в player.gd значит трогать контракт фазы 1
# без нужды: состояния и так лежат открытыми полями, а звук — дело склейки.
func _player_sfx(dt: float) -> void:
	if player.crouching != _was_crouch:
		_was_crouch = player.crouching
		audio.sfx("crouch-down" if _was_crouch else "crouch-up")

	# Куртка шуршит по времени, а не по шагам: повешенная на шаг, она слышится
	# как вторая подошва под первой.
	if player.running and player.on_floor:
		_cloth_at -= dt
		if _cloth_at <= 0.0:
			_cloth_at = 0.72
			audio.sfx("cloth-run")
	else:
		_cloth_at = 0.0

	# Одышка приходит, когда добежал: стамина выработана, а человек уже идёт.
	# Кулдаун — чтобы она не повторялась на каждом переходе бег-шаг.
	if _breath_cool > 0.0:
		_breath_cool -= dt
	elif _was_running and not player.running and player.stamina < 1.2:
		_breath_cool = 12.0
		audio.sfx("breath-tired")
	_was_running = player.running


func _update_water_surface(feet: Vector3) -> void:
	var outskirts: Dictionary = built.get("outskirts", {})
	var pond: Dictionary = outskirts.get("pond", {})
	var now := LakeVisuals.sample_water(feet, pond.get("water", {}))
	# Deep water is normally unreachable, but treating it as wet keeps debug
	# placement and old saves deterministic instead of falling back to grass.
	if now != _water_surface:
		if _water_surface == "dry" and now != "dry":
			audio.sfx("water-enter")
		elif _water_surface != "dry" and now == "dry":
			audio.sfx("water-exit")
		_water_surface = now


func _on_land() -> void:
	# Приземление — своё событие, а не «беговой шаг плюс скрип»: та связка
	# звучала как ещё один шаг, и высоты в ней не слышно.
	if audio.sfx("land"):
		return
	var surface := "water" if _water_surface != "dry" else String(zone.get("floor", "wood"))
	audio.step(surface, true, false)
	audio.creak(0.5)


# ---------- интерфейс ----------

func _set_paused(p: bool) -> void:
	if not running:
		return
	paused = p
	if _fade_tween != null and _fade_tween.is_valid():
		if p: _fade_tween.pause()
		else: _fade_tween.play()
	if cutscene != null: cutscene.paused = p
	if voice != null: voice.set_paused(p)
	audio.set_spatial_paused(p or ui.busy or phone.open or tape_player.open)
	ui.showPauseScreen(p)
	player.enabled = not p and not busy and not ui.busy and not (cutscene != null and cutscene.playing)
	if p:
		player.release_lock()
		audio.mute(true)
	else:
		audio.mute(false)


## Игра идёт и никакой оверлей её не держит — значит, мышь можно захватывать.
func _can_lock() -> bool:
	return running and not paused and not ui.busy and not phone.open and not tape_player.open \
		and not (cutscene != null and cutscene.playing)


## Возврат управления после оверлея. Одного enabled мало: меню и кассета
## закрываются клавишей, и без перезахвата ходьба работает, а голова — нет.
func _resume_control() -> void:
	player.enabled = not paused
	if _can_lock():
		player.request_lock()


func _start_game() -> void:
	_cancel_horror_runtime()
	ui.showStartScreen(false)
	ui.showHud(true)
	running = true
	started = true
	audio.arm()
	var s := ui.settings()
	audio.set_volume(float(s.get("volume", 0.8)))
	state.reset()
	if everyday != null:
		everyday.resync(state)
	flashlight.owned = false
	flashlight.on = false
	flashlight.battery = 100.0
	_water_surface = "dry"
	held_items.clear_runtime()
	held_items.sync(state)
	# place() не выпрямляет взгляд (иначе люк рвёт камеру), поэтому горизонт
	# на старте выставляем здесь — один раз за прохождение.
	player.pitch = 0.0
	player.pitch_target = 0.0
	hatch_cooldown = 0.0
	scare.enabled = bool(s.get("scares", true))
	# Второе прохождение начиналось с дедом на скорости и позиции первого:
	# без hard_reset() замедление и таймеры переживали откат.
	if threat != null:
		threat.hard_reset()
	ui.clearTask()
	chapters.start()
	player.enabled = true
	player.request_lock()
	_debug_jump()


## Отладочный прыжок по главам. Включается ТОЛЬКО явным аргументом запуска —
## в обычной сборке get_cmdline_user_args() пуст, и эта ветка не существует:
##
##   Godot..._console.exe --path godot ++ chapter village
##
## Старая короткая форма (++ street) осталась: ею пользуются заметки фаз
## 12-14. Новая длинная нужна затем, что аргументов у запуска стало больше
## одного, и «первый и есть глава» перестало быть правдой.
##
## ЧТО ЭТО НЕ ДЕЛАЕТ. Флаги пропущенных глав не выставляются: кассеты не
## просмотрены, дневник не прочитан, улик нет. Годится посмотреть сцену
## и проверить сцепку внутри одной главы; приёмка всей цепочки и концовок —
## только полным прохождением.
func _debug_jump() -> void:
	var extra := OS.get_cmdline_user_args()
	if extra.is_empty():
		return
	var want := String(extra[0]).strip_edges()
	for i in extra.size() - 1:
		if String(extra[i]).strip_edges() == "chapter":
			want = String(extra[i + 1]).strip_edges()
			break
	# Сухой режим — отдельным словом в тех же аргументах: `++ chapter gate dry`.
	for a: String in extra:
		if a.strip_edges() == "dry":
			debug_dry = true
			render_chain.set_exposure(1.35)
			weather.clear()
			print("ОТЛАДКА: сухой режим — дождя нет, экспозиция 1.35")
	if want == "" or not GameState.CHAPTERS.has(want):
		return
	# Фонарь выдаётся всегда, кроме первых двух глав: без него в доме темно,
	# и прыжок читался бы как чёрный экран.
	if GameState.CHAPTERS.find(want) >= GameState.CHAPTERS.find("light"):
		state.give("flashlight")
		flashlight.give()
	_debug_kit(want)
	chapters.go(want)
	# И перенести туда же, где глава начинается: без этого прыжок в УЛИЦУ
	# оставлял игрока на точке пролога, за полтора десятка метров от крыльца,
	# и первое, что он видел, — стук в пустоту за спиной.
	var back := chapters.respawn_of(want)
	if not back.is_empty():
		var at: Array = back["at"]
		player.place(float(at[0]), float(at[1]), float(at[2]), float(back["yaw"]))
	print("ОТЛАДКА: прыжок в главу %s" % want)


## Чем доукомплектовать состояние при отладочном прыжке (фаза 17).
##
## ЗАЧЕМ. Прыжок ставил только фонарь, и глава ВОРОТА от этого была
## НЕПРОХОДИМА: цепь на воротах спрашивает ключ из тайника в подполе, машина —
## ключи и полный бак, а точка «ехать» с фазы 17 держит ещё и три линии
## деревни. Ничего из этого прыжок не выдавал, и отладочный вход в финал
## упирался в первую же запертую вещь. Это ровно тот случай, когда инструмент
## отладки врёт: глава выглядит сломанной, хотя сломан вход в неё.
##
## Правило: выдаётся МИНИМУМ, с которым глава проходима целиком, и ничего
## сверх. Прыжок остаётся отладкой, а не читом: сюжетные шаги самой главы
## по-прежнему делает игрок.
func _debug_kit(want: String) -> void:
	var at := GameState.CHAPTERS.find(want)
	if at < GameState.CHAPTERS.find("village"):
		return
	# ДЕРЕВНЯ и дальше: ключи от машины и бензин — это шаги ТЕМНОТЫ.
	#
	# КЛЮЧ ОТ ДОМА — ПЕРВЫМ. Входная дверь заперта на два оборота
	# (interact.gd 'front-door-use'), ключ лежит в жестянке в сарае, и без него
	# в дом НЕ ПОПАСТЬ. Прыжок в ВОРОТА без ключа выглядел так: задача велит
	# забрать из дома всё, что нашёл, а дом заперт наглухо — игрок ходит вокруг
	# и ищет сумку, которой не видит, потому что она за дверью.
	state.give("key")
	state.give("car-key")
	state.set_flag("tank-full")
	if at < GameState.CHAPTERS.find("gate"):
		return
	# ВОРОТА: ключ от амбарного замка лежит в тайнике за банками, и без него
	# цепь не снять ничем. Плюс три линии деревни, которые с фазы 17
	# обязательны, и обе половины улики — иначе финал приходит к концовке
	# «один», а проверять надо полную.
	state.give("chain-key")
	state.give("kovrigin-tapes")
	# И дом стоит ОТКРЫТЫМ. К главе ВОРОТА игрок провёл в нём всю ночь и вышел
	# на улицу: запертая дверь в этот момент — не задача, а лишний замок между
	# ним и последним шагом сюжета. Тихо, без хлопка: звук двери из ниоткуда
	# на первой секунде главы читается как то, что кто-то вошёл.
	state.set_flag("house-open")
	_ctx_set_door("door-front", true, true)
	state.set_flag("water-done")
	state.set_flag("valya-gone")
	state.set_flag("boarded-tapes")
	state.set_flag("kovrigin-letter")
	# ФАЗА 18. Баня и погреб вошли в замок главы (village_chores_done):
	# отладочный прыжок в ВОРОТА без них теперь упирается в отказ у капота.
	state.set_flag("banya-written")
	state.set_flag("bathloft-found")
	state.set_flag("mill-seen")
	state.set_flag("mill-braked")
	state.set_flag("mill-clue")
	if want in ["gate", "end"]:
		for flag: String in SntQuest.FLAGS:
			state.set_flag(flag)
	state.evidence = true
	print("ОТЛАДКА: выдан комплект для главы %s" % want)


func _show_end(which: String) -> void:
	_cancel_horror_runtime()
	ui.showHud(false)
	# Задач больше нет. Иначе строка доживает до первой pushTask() следующего
	# прохождения и висит невыполненной целью поверх экрана концовки.
	ui.clearTask()
	# Подпись берётся ИЗ ТЕКСТОВ, а не из цепочки if. Цепочка знала три
	# концовки из четырёх: «ПИСЬМО» показывалось как «ОДИН» с фазы 12, и
	# заметить это можно было только пройдя игру нужным способом. Пятая
	# концовка фазы 15 («ДОМА») сюда доезжает сама, и шестая доедет тоже.
	var titles: Dictionary = (ctx["texts"] as Dictionary).get("ENDINGS", {})
	var e: Dictionary = titles.get(which, {})
	var eyebrow := "концовка · " + String(e.get("title", "ОДИН"))
	ui.showStartScreen(true, eyebrow)
	running = false
	player.release_lock()


func _on_restart() -> void:
	_cancel_horror_runtime()
	_set_paused(false)
	state.reset()
	flashlight.owned = false
	flashlight.on = false
	flashlight.battery = 100.0
	_water_surface = "dry"
	held_items.clear_runtime()
	held_items.sync(state)
	player.pitch = 0.0
	player.pitch_target = 0.0
	hatch_cooldown = 0.0
	if threat != null:
		threat.hard_reset()
	if weather != null:
		weather.clear()
	ui.clearTask()
	chapters.start()
	player.request_lock()


func _on_fullscreen() -> void:
	var w := get_window()
	if w.mode == Window.MODE_FULLSCREEN or w.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		w.mode = Window.MODE_WINDOWED
	else:
		w.mode = Window.MODE_FULLSCREEN


# ---------- клавиши ----------

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.echo:
		return

	# Катсцена пропускается ЛЮБОЙ клавишей И МЫШЬЮ, и проверка стоит ПЕРВОЙ —
	# до захвата мыши, до отладки и до всех оверлеев: пока сцена жива, ввод
	# принадлежит ей целиком, иначе клавиша проваливается в интеракт и в паузу
	# поверх кадра.
	#
	# ФАЗА 17. Два изменения, и оба по одной жалобе — «отъезд толком не
	# показали». Первое: мышь теперь ДЕЙСТВИТЕЛЬНО пропускает. Комментарий
	# обещал это с фазы 16, а кликом сцена не гасилась: ветка захвата мыши
	# стояла выше и забирала событие себе. Второе: пропуск не работает первые
	# Cutscene.SKIP_AFTER секунд — сцену запускает то же нажатие, которым
	# игрок завёл машину, и оно её же и гасило.
	if running and cutscene.playing:
		if event.is_action_pressed("pause"):
			_set_paused(not paused)
			return
		if paused: return
		if event is InputEventKey and event.pressed:
			cutscene.skip()
		elif event is InputEventMouseButton and event.pressed:
			cutscene.skip()
		return

	# Колесо проверяется до общей ветки мыши: та нужна для клика-захвата и
	# намеренно съедает остальные кнопки. В блокирующих режимах выбор остаётся
	# нетронутым, и событие дальше принадлежит соответствующему экрану.
	if event.is_action_pressed("equip_prev") or event.is_action_pressed("equip_next"):
		if _held_items_input_enabled():
			held_items.cycle(-1 if event.is_action_pressed("equip_prev") else 1)
		return

	# Клик по экрану возвращает мышь — единственный выход, если захват
	# потерялся вне паузы (порт pointerdown по канвасу).
	if event is InputEventMouseButton and event.pressed:
		if _can_lock() and not player.is_locked():
			player.request_lock()
		return

	if event.is_action_pressed("debug_toggle"):
		debug = not debug
		ctx["debug"] = debug
		ui.showDebug(debug)
		return
	if not running:
		return

	# Оверлеи забирают ввод себе. Скример первым: он длится секунду с небольшим,
	# и [R], нажатая в это время, откатила бы главу до показа карточки провала.
	if ui.scareOpen:
		return
	if ui.card.open:
		if event.is_action_pressed("advance"):
			ui.advanceCard()
		return
	if ui.failOpen:
		if event.is_action_pressed("retry"):
			chapters.retry()
		return
	# Фотография в руках закрывается той же клавишей, что и записка. Управление
	# возвращаем здесь, а не в колбэке ui: снимок открывают из осмотра, и после
	# него нужен перезахват мыши, а не только enabled.
	if ui.photo.open:
		if event.is_action_pressed("interact") or event.is_action_pressed("pause") \
				or event.is_action_pressed("advance"):
			ui.closePhoto()
			_resume_control()
		return
	if ui.reader.open:
		if event.is_action_pressed("interact") or event.is_action_pressed("pause"):
			ui.closeReader()
		elif event.is_action_pressed("ui_page_left"):
			ui.pageReader(-1)
		elif event.is_action_pressed("ui_page_right"):
			ui.pageReader(1)
		return
	if tape_player.open:
		if event.is_action_pressed("interact") or event.is_action_pressed("pause"):
			tape_player.stop(false)
		return
	if phone.open:
		if event.is_action_pressed("move_forward"):
			phone.move(-1)
		elif event.is_action_pressed("move_back"):
			phone.move(1)
		elif event.is_action_pressed("interact") or event.is_action_pressed("advance"):
			phone.pick()
		elif event.is_action_pressed("pause"):
			phone.hide()
			_resume_control()
		return
	if phone.talking:
		if event.is_action_pressed("pause"):
			_set_paused(not paused)
		elif not paused and (event.is_action_pressed("interact") or event.is_action_pressed("advance")):
			phone.skipLine()
		return

	if event.is_action_pressed("interact"):
		# Выход из укрытия обрабатываем здесь, а не дескриптором: точка укрытия
		# задана на 0.78 ниже глаз и в конус взгляда не попадает.
		if state.hidden:
			_leave_hiding()
		elif interact.target != null:
			interact.use(ctx)
		elif _hatch != null:
			_use_hatch(_hatch)
	elif event.is_action_pressed("flashlight"):
		held_items.sync(state)
		if held_items.equip(HeldItems.FLASHLIGHT) and flashlight.toggle():
			audio.click()
		elif not flashlight.owned:
			ui.say("Фонаря нет. Он в машине, в багажнике.", 3.0)
	elif event.is_action_pressed("call_out"):
		_call_out()
	elif event.is_action_pressed("show_task"):
		if capture != null and capture.active():
			var instruction := "Включить аварийную лампу. Освободить люк."
			if bool(state.recovery.get("hatch_free", false)):
				instruction = "Подняться через люк."
			elif bool(state.recovery.get("light_on", false)):
				instruction = "Отодвинуть доску под люком."
			ui.say(instruction, 3.6)
			return
		ui.showTask()
		# ФАЗА 18. [TAB] ПРОИЗНОСИТ задачу, а не только мигает ею в углу.
		# Вспышка держится две секунды 12-м кеглем на краю кадра — её и
		# нажимают-то потому, что строку не разглядели. Реплика идёт в центр,
		# туда же, куда всё остальное, и читается сколько нужно.
		if state.task != null and str(state.task) != "":
			ui.say(str(state.task), 3.6)
		if state.hasItem("mobile"):
			ui.toast("«Сименс»: сеть ловит у ворот и на балконе")
	elif event.is_action_pressed("pause"):
		if not paused:
			_set_paused(true)


func _held_items_input_enabled(ignore_mouse_lock := false) -> bool:
	return running and held_items != null and not paused and not ui.busy \
		and not ui.scareOpen and not ui.card.open and not ui.failOpen \
		and not ui.photo.open and not ui.reader.open and not tape_player.open \
		and not phone.open and not phone.talking and player != null and player.enabled \
		and (ignore_mouse_lock or player.is_locked()) \
		and not (cutscene != null and cutscene.playing)


func _runtime_free() -> bool:
	return running and state.chapter != "end" and not paused and not phone.talking \
		and not (capture != null and capture.active()) \
		and not (horror != null and horror.exclusive())


func _street_runtime_free() -> bool:
	if not running or state.chapter == "end" or paused or busy: return false
	if phone != null and (phone.open or phone.talking): return false
	if ui != null and ui.busy: return false
	if tape_player != null and tape_player.open: return false
	if cutscene != null and cutscene.playing: return false
	if capture != null and capture.active(): return false
	if horror == null or not horror.exclusive(): return true
	return stalk != null and stalk.active() and horror.owner == "stalk" \
		and not horror.external_exclusive() and horror._live.is_empty() \
		and not horror.thresholds.active()


func _cancel_horror_runtime() -> void:
	if street != null: street.cancel_runtime()
	if pursuit != null: pursuit.cancel()
	_cancel_dialogue_runtime()
	if _fade_tween != null and _fade_tween.is_valid(): _fade_tween.kill()
	_fade_tween = null
	if horror != null: horror.invalidate()
	if capture != null: capture.cancel()
	if cutscene != null: cutscene.cancel()
	if startle != null: startle.clear()
	if stalk != null: stalk.finish()
	busy = false
	_hatch = null
	if render_chain != null:
		render_chain.set_tracking(0.0)
		render_chain.set_fade(1.0)


## [Q] «позвать». В первой главе — безобидное действие с задачей.
## В главе «ТЕМНОТА» крик приводит его к тебе. В финале — заканчивает запись.
func _call_out() -> void:
	if capture != null and capture.active():
		return
	# Единственная реплика Сергея, которая звучит голосом: её слышит дед
	# (threat.hear ниже), а не игрок про себя. Во дворе к ней приходит эхо
	# от забора, в доме его нет.
	var outdoor := String(zone.get("reverb", "outdoor")) == "outdoor"
	var shouted := voice.shout(outdoor) if voice != null else -1.0
	if shouted <= 0.0:
		audio.tone({"freq": 300.0, "to": 190.0, "dur": 0.75,
			"gain": 0.14, "type": "sawtooth", "attack": 0.05})
		audio.mumble(0.9)
	var beats: Dictionary = (ctx["texts"] as Dictionary).get("BEATS", {})
	ui.say(String(beats.get("calledVitya", "")), 2.6, GameVoice.PRIO_VITYA)
	if state.chapter == "arrive":
		_ctx_emit("called")
	elif state.atLeast("dark"):
		state.set_flag("shouted")
		if threat != null:
			threat.hear(player.feet(), 3.0)

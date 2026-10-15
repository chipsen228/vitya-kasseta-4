# Мелькания. Порт game/haunt.js. Он в кадре с первой главы, но за ним никто
# не гонится: дед стоит в окне, в конце коридора, в щели между домом и сараем —
# шесть-девять секунд, ровно там, куда игрок в эту секунду не смотрит. Не идёт,
# не зовёт, не ловит. Задача этих появлений одна: к главе «ТЕМНОТА» игрок должен
# уже не доверять периферии кадра.
#
# Контракт владения фигурами, третьего владельца нет:
#   'threat' — ai.gd, позиция и видимость каждый кадр;
#   'echo'   — этот файл, короткие постановочные появления.
#
# Двойник обязателен: Threat.update в состоянии 'absent' каждый кадр прячет свою
# фигуру, а до «ТЕМНОТЫ» он в 'absent' всё время. Повесь мелькание на ту же
# модель — Threat погасит её в том же кадре, до отрисовки. Фигуры слеплены
# по одной мерке и с одним лицом: для игрока это один и тот же человек.
#
# Правило темпа держится здесь же. До главы 'dark' появления идут молча:
# ни стингера, ни тряски камеры, ни реакции интерфейса.
class_name Haunt
extends RefCounted

# Высота лица над ногами не константа: её считает actors.gd из собранного
# скелета (meta face_y ~ 1.596). Все три проверки — дистанция, угол и луч —
# идут до лица, а не до ног: игрок ловит взглядом голову в проёме.
# Запасное значение на случай, если фигура ещё не собрана.
const FACE_FALLBACK := 1.58

# Двойника не показываем, пока настоящий дед рядом: две одинаковые фигуры
# в одном кадре — не жутко, а смешно. Порогов два, и это не перестраховка.
# Голый радиус 25 м выключал механику там, где она должна окупаться: участок
# 20 x 30, в «ТЕМНОТЕ» дед почти всегда ближе 25 м к камере. Обе беды —
# «двое в кадре» и двойная цена отрисовки — случаются только когда дед
# РИСУЕТСЯ. Поэтому: ближе 12 м — молчим всегда, от 12 до 25 — только если
# он в пирамиде видимости.
const THREAT_NEAR := 12.0
const THREAT_FRUSTUM := 25.0

const TRY_EVERY := 0.9        # как часто вообще проверяются условия
const TRY_CHANCE := 0.35      # и с какой вероятностью пробуем показать
const NEAR := 4.0             # ближе — видно, что это картонка
const FAR := 24.0             # дальше — туман, и появление проходит впустую
# Порог «не смотрит». Край кадра при FOV 70 и обычном соотношении сторон — это
# dot 0.626, так что 0.55 гарантирует появление за границей кадра, а не на
# глазах. Тот же порог гасит фигуру: посмотрел и отвернулся — её уже нет.
const LOOK_AWAY := 0.55
const TOO_CLOSE := 3.5        # подошёл вплотную — гаснет, разглядывать нечего
const TTL_MIN := 6.0
const TTL_MAX := 9.0
const POINT_CD := 300.0       # одна и та же точка не повторяется пять минут
const GLOBAL_CD := 45.0
const START_CD := 20.0        # тишина в начале главы и после [R]

# Бюджет по главам (фаза 8). Было «два-три в любой главе», включая пролог,
# где двойнику появиться негде. Ночью его больше, но не втрое: мелькание
# держится редкостью, и в ТЕМНОТЕ его перебивает сам дед.
const BUDGET := {
	"prologue": [0, 0],
	"arrive": [1, 2],
	"light": [2, 3],
	"loft": [2, 3],
	"tapes": [2, 3],
	"dark": [3, 4],
	# ДЕРЕВНЯ (фаза 12): четыре новых створа на девяносто метров линии.
	"village": [3, 4],
	"gate": [1, 2],
	"end": [0, 0],
}

# Интенсивность мелькания для шкалы напряжения (tension.gd): это не бытовой
# звук и не акцент, это ровно середина.
const INTENSITY := 2

var c: Variant = null
var actors: Variant = null
var col: CollisionWorld = null
var rng := RandomNumberGenerator.new()

var points: Array = []

var point: Variant = null     # активная точка либо null
var ttl := 0.0
var looked := false           # игрок уже поворачивался к ней
var global_cd := START_CD
var cooldowns: Dictionary = {}    # id точки -> сколько секунд ещё нельзя
var _cd_dead: Array[String] = []  # истёкшие имена кадра, см. update()
var chapter: Variant = null
var shown := 0
var budget := 2
var try_in := TRY_EVERY
var face_y := 0.0             # берётся из фигуры при первом обращении, см. _face

# main.js читает строку для F3 как геттер (`app.haunt.debugLine`) — держим оба
# написания, чтобы склейка не зависела от того, кто как вспомнил.
var debugLine: String:
	get:
		return debug_line()

var _eye := Vector3.ZERO
var _to := Vector3.ZERO
var _fwd := Vector3.ZERO


func _init(ctx: Variant, actors_in: Variant, col_in: Variant = null,
		rng_seed: int = 0) -> void:
	c = ctx
	actors = actors_in
	var cw: Variant = col_in if col_in != null else _cx("col")
	if cw is CollisionWorld:
		col = cw
	rng.seed = rng_seed
	points = _make_points()


# Шестнадцать постановочных точек.
#
#   pos  — ноги фигуры. Снаружи это 0 (земля), в доме 0.45 (пол первого этажа),
#          в мансарде ATTIC_FEET. Полоса окон первого этажа 1.30…2.30 принимает
#          и то, и другое: снаружи лицо приходится на 1.60, изнутри на 2.05.
#   look — куда фигура повёрнута. Всегда туда, откуда на неё смотрят.
#   zones— в какой зоне (world.zone_at) должен стоять игрок. Точка вне своей
#          зоны бессмысленна: её либо не видно, либо видно под таким углом,
#          под каким в окне никто не стоит.
#   see_through — пропустить проверку луча. Стёкла окон в статику не попадают,
#          а стёкла теплицы и коллизия сетки забора попадают, и честный луч
#          отсекал бы ровно те две точки, ради которых стекло и забор нужны.
#
# Ноги в окне мансарды — на 25 см ниже пола: полоса мансардного окна 4.10…5.00,
# и поставь фигуру на пол, лицо (3.30 + 1.596) придётся в перемычку. Утопленными
# ногами платим за то, что лицо садится на 4.65, посреди створа.
#
# Чердачное окно w-n3 не используется нигде: фигура туда не влезает по высоте.
func _make_points() -> Array:
	var y: Dictionary = GameData.site()["Y"]
	var attic_feet: float = float(y["ATTIC"]) - 0.25
	return [
		# ---------- окна первого этажа: он снаружи, игрок в доме ----------
		{
			"id": "win-n-veranda", "pos": [-4.30, 0.00, 6.24], "look": [-3.60, 9.00],
			"zones": ["veranda"], "see_through": false
		},
		{
			# Восточное окно общей комнаты, он снаружи, в проходе между домом
			# и сараем. Фаза 8: до неё точка стояла у ЗАПАДНОГО окна на z=10.9,
			# и tests/test_haunt_points.gd показал, что за всю игру её не видно
			# ни с одной позиции — створ намертво закрыт лестничным маршем
			# (луч упирается на x≈-4.55). Восточное окно видно с 79 позиций
			# первого этажа из 193.
			"id": "win-e-living", "pos": [4.78, 0.00, 14.40], "look": [0.00, 14.40],
			"zones": ["floor1"], "see_through": false
		},
		{
			"id": "win-s-living", "pos": [3.30, 0.00, 16.56], "look": [0.00, 13.60],
			"zones": ["floor1"], "see_through": false
		},

		# ---------- окна первого этажа: он в доме, игрок на участке ----------
		{
			# Первое, что можно увидеть за всю игру: окно веранды с дорожки от ворот.
			"id": "win-n-inside", "pos": [-0.20, 0.45, 6.96], "look": [-0.20, 1.50],
			"zones": ["plot", "porch"], "see_through": false
		},
		{
			"id": "win-s-inside", "pos": [1.20, 0.45, 15.84], "look": [1.20, 21.00],
			"zones": ["plot"], "see_through": false
		},
		{
			"id": "win-e-inside", "pos": [4.04, 0.45, 14.40], "look": [8.50, 15.00],
			"zones": ["plot"], "see_through": false
		},

		# ---------- мансарда ----------
		{
			# Окно комнаты деда выходит на балкон. Игрок вышел подышать — а он
			# в той самой комнате, из которой игрок минуту назад вышел.
			"id": "attic-n", "pos": [-0.40, attic_feet, 9.96], "look": [-2.40, 7.60],
			"zones": ["balcony"], "see_through": false
		},
		{
			"id": "attic-s", "pos": [0.60, attic_feet, 15.84], "look": [0.60, 21.00],
			"zones": ["plot"], "see_through": false
		},
		{
			"id": "attic-w", "pos": [-5.24, attic_feet, 11.40], "look": [-9.00, 11.40],
			"zones": ["plot"], "see_through": false
		},

		# ---------- дом, вблизи ----------
		{
			# Конец коридора прихожей. Игрок входит из кухни через дверь на z=13.6,
			# и коридор кончается им.
			"id": "hall-end", "pos": [-3.00, 0.45, 14.60], "look": [-3.00, 10.20],
			"zones": ["floor1"], "see_through": false
		},

		# ---------- участок ----------
		{
			# Щель 0.46 м между восточной стеной дома (x=4.4) и западной стеной
			# сарая (x=5.0). По плечам он туда не влезает, и это правильно:
			# в просвете видно вжатый силуэт. Видно её только с севера.
			"id": "win-e-gap", "pos": [4.73, 0.00, 12.20], "look": [4.73, 6.00],
			"zones": ["plot"], "see_through": false
		},
		{
			# За стеклом теплицы. Стекло мутное и в коллизии — луч не считаем.
			"id": "greenhouse", "pos": [-7.00, 0.10, 21.00], "look": [-2.50, 20.00],
			"zones": ["plot"], "see_through": true
		},
		{
			# Западная тропа, сразу за яблоней на z=5.0: половину фигуры съедает ствол.
			"id": "path-tree", "pos": [-7.40, 0.00, 6.60], "look": [-2.50, 2.60],
			"zones": ["plot"], "see_through": false
		},
		{
			# Тёмный участок соседа, за сеткой. Ноги на -0.32: за забором лежит
			# общий грунтовый настил, и на нуле фигура висит в воздухе.
			"id": "neighbour", "pos": [-11.60, -0.32, 9.40], "look": [-2.00, 9.40],
			"zones": ["plot"], "see_through": true
		},
		{
			# Глубина огорода. На двадцати метрах туман съедает всё, кроме силуэта.
			"id": "garden-deep", "pos": [1.40, 0.00, 26.60], "look": [0.40, 15.00],
			"zones": ["plot"], "see_through": false
		},
		{
			"id": "garden-fence", "pos": [-4.60, 0.00, 28.40], "look": [-2.00, 16.50],
			"zones": ["plot"], "see_through": false
		},

		# ---------- фаза 8: внутри дома ----------
		# Одиннадцать из шестнадцати точек требовали, чтобы игрок был на участке;
		# внутри дома их было четыре на весь дом. Отсюда и «в доме не страшно»:
		# периферии кадра игрок не переставал доверять просто потому, что в ней
		# ничего не происходило. Все семь створов ниже — из site.json WALLS,
		# по проёмам, и проверены tests/test_haunt_points.gd: точка обязана быть
		# и проходимой, и ВИДИМОЙ хотя бы с двенадцати позиций своей зоны.
		{
			# Проём прихожей с веранды (дыра x=-3.6 в w-veranda-s).
			"id": "hall-door", "pos": [-3.60, 0.45, 11.40], "look": [-3.60, 7.60],
			"zones": ["veranda"], "see_through": false
		},
		{
			# Проём кухни с веранды (дыра x=-0.4 в той же стене).
			"id": "kitchen-door", "pos": [-0.40, 0.45, 11.80], "look": [-0.40, 7.60],
			"zones": ["veranda"], "see_through": false
		},
		{
			# Общая комната СКВОЗЬ ДВА ПРОЁМА подряд: кухонная дверь веранды
			# (x=-0.4) и проём w-living-n (x=-0.6) стоят почти на одной оси,
			# и с веранды простреливается шесть с половиной метров через две
			# комнаты. Другого такого створа в доме нет.
			"id": "living-far", "pos": [-0.50, 0.45, 15.10], "look": [-0.50, 8.00],
			"zones": ["veranda"], "see_through": false
		},
		{
			# Общая комната из прихожей, через проём z=13.6 в w-hall-e.
			"id": "living-from-hall", "pos": [-1.00, 0.45, 13.60], "look": [-4.00, 13.60],
			"zones": ["floor1"], "see_through": false
		},
		{
			# Комната за запечатанным проёмом (дыра x=0.6 в w-sealed). Игрок
			# на мансарде, а он стоит там, куда ходу нет.
			"id": "attic-sealed", "pos": [0.60, 3.30, 14.60], "look": [0.60, 10.50],
			"zones": ["attic"], "see_through": false
		},
		{
			# Дальний угол подпола. Потолок там 0.35, фигура в него не встаёт —
			# ноги на дне, лицо на 0.05, и видно ровно голову над полом.
			"id": "cellar-far", "pos": [3.40, -1.55, 11.60], "look": [-2.50, 11.00],
			"zones": ["cellar"], "see_through": false
		},
		{
			# Чердак: гнездо в дальнем конце, за стропилами.
			"id": "roofspace-nest", "pos": [-4.40, 5.90, 14.60], "look": [-2.60, 11.00],
			"zones": ["roofspace"], "see_through": false
		},

		# ---------- фаза 11: зоны, в которых не было ни одной точки ----------
		# Пять помещений игрок посещает по сюжету обязательно, и во всех пяти
		# периферия кадра была мертва. Фигура ставится СНАРУЖИ и видна через
		# створ — из тесной комнаты в четырёх метрах она читалась бы декорацией,
		# а вилка haunt начинается ровно с четырёх.
		{
			# Из сарая — сквозь его единственную дверь (shed-n, x = 6.8).
			"id": "shed-door", "pos": [6.80, 0.00, 6.40], "look": [6.80, 12.00],
			"zones": ["shed"], "see_through": false
		},
		{
			# Из туалета — сквозь проём privy-n (x = 8.6). Полтора метра, дверь
			# и он в конце тропы.
			"id": "privy-path", "pos": [8.60, 0.00, 16.40], "look": [8.60, 21.00],
			"zones": ["privy"], "see_through": false
		},
		{
			# Из теплицы — сквозь мутное стекло. Оно в коллизии, поэтому луч
			# не считаем, ровно как у точки greenhouse с обратной стороны.
			"id": "greenhouse-out", "pos": [-3.80, 0.00, 22.60], "look": [-7.00, 21.00],
			"zones": ["greenhouse"], "see_through": true
		},
		{
			# Из дальней комнаты — сквозь северное окно во двор. Через восточное
			# было бы ближе, но вся зона умещается в 3.4 на 3.0 м, и оттуда
			# до фигуры меньше четырёх метров: точка не выпала бы ни разу.
			"id": "aunt-window", "pos": [2.70, 0.00, 5.20], "look": [2.70, 9.00],
			"zones": ["aunt"], "see_through": false
		},
		{
			# Из правления — сквозь ту самую дверь, которую игрок только что
			# отпер. Он стоит на дороге и ждёт.
			"id": "office-road", "pos": [-30.00, 0.00, -3.60], "look": [-30.00, -10.00],
			"zones": ["office"], "see_through": false
		},

		# ---------- фаза 11: новые постройки ----------
		# Обе точки стоят СНАРУЖИ построек намеренно: стены бани и погреба живут
		# в четвёртом наборе коллизий, а луч haunt читает только статику —
		# фигура внутри показывалась бы игроку сквозь стену.
		{
			# Из бани — сквозь входной проём, вдоль дорожки к дому.
			"id": "banya-path", "pos": [5.00, 0.00, 17.60], "look": [5.00, 23.00],
			"zones": ["banya"], "see_through": false
		},
		{
			# Из погреба — сквозь дверь на восток, посреди двора.
			"id": "cellar-shed-yard", "pos": [-3.20, 0.00, 2.35], "look": [-7.00, 2.35],
			"zones": ["cellar-shed"], "see_through": false
		},

		# ---------- фаза 12: деревня ----------
		# Тот же вывод, что и в фазе 11, и по той же причине: стены сельпо
		# и заколоченного дома живут в четвёртом наборе, а луч haunt читает
		# только статику. Все четыре фигуры стоят СНАРУЖИ и видны через проём.
		{
			# Из сельпо — сквозь дверь, на дороге. Он стоит между игроком
			# и машиной, и это единственный створ, который тот обязан пройти.
			"id": "shop-road", "pos": [28.90, 0.00, -4.20], "look": [28.90, -10.00],
			"zones": ["shop"], "see_through": false
		},
		{
			# Из заколоченного дома — сквозь проём, из которого отодрали доски.
			# Он снаружи, там, куда игрок сейчас пойдёт обратно.
			"id": "boarded-road", "pos": [-5.50, 0.00, -5.20], "look": [-5.50, -10.00],
			"zones": ["boarded"], "see_through": false
		},
		{
			# С погоста — от калитки, спиной к крестам. Зона просторная,
			# и вилка 4..24 м набирается по всей её длине.
			"id": "grave-gate", "pos": [40.05, 0.00, -6.90], "look": [40.05, -11.00],
			"zones": ["graveyard"], "see_through": false
		},
		{
			# На самой линии: он на обочине, там, где до него ровно столько,
			# чтобы разобрать силуэт и не разобрать лица.
			#
			# ФАЗА 13 сдвинула точку с x = -0.60 на -3.40. Причина механическая:
			# на прежнем месте между заколоченным домом и домом наблюдателя
			# теперь стоит красный дом со штакетником и крыльцом, и фигура
			# оказывалась на чужом настиле за забором.
			"id": "street-verge", "pos": [-3.40, 0.00, -7.30], "look": [-3.40, -2.00],
			"zones": ["street"], "see_through": false
		},

		# ---------- фаза 13: красный дом ----------
		{
			# Из красного дома — сквозь открытый проём, на дороге. Тот же вывод,
			# что у сельпо и заколоченного: стены дома живут в четвёртом наборе,
			# а луч haunt читает только статику, поэтому фигура стоит СНАРУЖИ
			# и видна через дверь. Она стоит ровно между игроком и его воротами.
			"id": "redhouse-road", "pos": [0.90, 0.00, -4.60], "look": [0.90, -10.00],
			"zones": ["redhouse"], "see_through": false
		},

		# ---------- фаза 14: околица и второй этаж ----------
		# Тот же вывод, что в фазах 11-13, и уже без оговорок: ВСЯ геометрия
		# околицы живёт в четвёртом наборе коллизий, а луч haunt читает
		# только статику. Фигура, поставленная в амбар или в зал клуба,
		# показалась бы игроку сквозь стену. Поэтому все пять стоят
		# на открытом, и каждая — на линии, по которой игрок сюда пришёл.
		{
			# Со двора фермы — назад, к выходу. Игрок минуту назад прошёл там
			# сам, и обратная дорога у него одна.
			#
			# ФАЗА 16. Точка стояла на [-35.50, -21.20] — с фазы 16 это НУТРО
			# дома участка 21: соседские дома второй линии перестали быть
			# призраками и получили тело. Фигура показалась бы игроку внутри
			# стены. Переехала в тот самый коридор 1.5 м между южной стеной
			# амбара и домом, по которому игрок сюда и пришёл.
			"id": "farm-back", "pos": [-36.30, 0.00, -25.20], "look": [-36.30, -30.00],
			"zones": ["farm"], "see_through": false
		},
		{
			# Со второй линии — в устье западного переулка. Единственный
			# выезд с дороги на этом конце деревни, и в нём кто-то стоит.
			"id": "lane-mouth", "pos": [-28.60, 0.00, -15.80], "look": [-28.60, -22.00],
			"zones": ["outskirts"], "see_through": false
		},
		{
			# С поля — у скирды на краю. Дальше только тропа в лес, и туда
			# не ходят.
			"id": "field-stack", "pos": [30.40, 0.00, -25.40], "look": [33.00, -30.00],
			"zones": ["field"], "see_through": false
		},
		{
			# Из окна второго этажа красного дома — вниз, на дорогу, ровно
			# между домом и Витиными воротами. Тот же створ, что у
			# redhouse-road, только сверху: игрок смотрит на своё крыльцо.
			"id": "redhouse-below", "pos": [0.90, 0.00, -5.40], "look": [0.90, -10.00],
			"zones": ["redhouse-up"], "see_through": false
		},
		{
			# Из зала клуба — сквозь дверной проём, на площадке перед входом.
			# Выход из клуба один, и он занят.
			#
			# ФАЗА 16. Точка стояла на [9.10, -25.20] — это нутро дома
			# участка 19. Зал клуба при этом отодвинулся на 0.6 м к северу
			# (между ним и домом было 0.9 м), и площадка перед входом уехала
			# следом: теперь она в полутораметровом коридоре между ними.
			"id": "club-door", "pos": [9.10, 0.00, -26.30], "look": [9.10, -30.00],
			"zones": ["club"], "see_through": false
		},
		{
			# ФАЗА 16, СНТ. На ТОМ берегу озера, за водой. Идти к нему
			# двадцать метров в обход, и пока обойдёшь — там уже никого.
			#
			# Открытое место, как и все пять точек околицы, и по той же
			# причине: луч haunt читает только статику, а весь новый район
			# живёт в четвёртом наборе. Фигура, поставленная в дом СНТ,
			# показалась бы игроку сквозь стену.
			"id": "snt-lake", "pos": [-9.60, 0.00, -42.00], "look": [-4.00, -53.00],
			"zones": ["snt"], "see_through": false
		},
	]


# Звать каждый кадр, пока игра идёт.
func update(dt: float) -> void:
	var st: Variant = _cx("state")
	if st == null:
		return

	var cur := String(st.get("chapter"))
	if chapter == null or cur != String(chapter):
		chapter = cur
		shown = 0
		budget = _budget_for(cur)

	global_cd -= dt
	# Обход СЛОВАРЯ, а не keys(): тот выделяет новый массив каждый кадр.
	# Стирать во время обхода нельзя — истёкшие копятся в переиспользуемый
	# массив и убираются после него.
	if not cooldowns.is_empty():
		_cd_dead.clear()
		for id: String in cooldowns:
			var left: float = float(cooldowns[id]) - dt
			if left <= 0.0:
				_cd_dead.append(id)
			else:
				cooldowns[id] = left
		for id: String in _cd_dead:
			cooldowns.erase(id)

	# Двоих одинаковых в одном кадре быть не должно — и это ровно то, что
	# считает _threat_near(): ближе двенадцати метров либо в пирамиде видимости
	# до двадцати пяти. Фаза 8: гейт по состоянию 'hunt' снят. Он выключал
	# механику во всей главе ВОРОТА, включая минуты, когда дед гонится за шумом
	# в другом конце участка и в кадр не попадает вовсе.
	# Постановочные появления глав это не трогает: они ставят двойника сами,
	# point при них пуст, и _hide выходит первой же строкой.
	if _threat_near():
		_hide(false)
		return
	# ФАЗА 18. И то же самое про деда на линии. Он занимает двойника на всю
	# главу через holdEcho, но global_cd — не запрет, а отсрочка: 600 секунд
	# кончались раньше, чем глава ДЕРЕВНЯ, выросшая до двух десятков ступеней,
	# и мелькание в окне уводило фигуру прямо с дороги. Гейт по состоянию, а
	# не по секундомеру, — по образцу уже написанного startle._stalking().
	if _stalking():
		_hide(false)
		return

	if point != null:
		_hold(dt)
		return

	try_in -= dt
	if try_in > 0.0:
		return
	try_in = TRY_EVERY

	if global_cd > 0.0 or shown >= budget:
		return
	# Из укрытия отвернуться нельзя физически, и мелькание в щели шкафа
	# читается как сбой, а не как испуг.
	if bool(st.get("hidden")):
		return
	if rng.randf() > TRY_CHANCE:
		return
	# Шкала напряжения: у мелькания своё окно. Нет шкалы в ctx — модуль
	# работает ровно как в фазе 7.
	var ten: Variant = _cx("tension")
	if ten != null and not bool(ten.allows(INTENSITY)):
		return
	_pick()


# Отдать двойника главе на seconds секунд: погасить текущее мелькание и не
# начинать нового. Глава ставит и гасит фигуру сама — здесь только гарантия,
# что haunt в это время в неё не полезет.
func hold(seconds: float) -> void:
	_hide(false)
	global_cd = maxf(global_cd, seconds)


# При [R]: погасить двойника и снять кулдауны точек.
func reset() -> void:
	_hide(false)
	# Безусловно, а не только через _hide: постановочные сцены глав ставят
	# двойника сами, при этом point остаётся пустым, и _hide выходит сразу.
	# Умерев в сцене у ворот, игрок возвращался к деду, застывшему за створкой.
	# Ключ 'echo' наш, гасить его — наша обязанность.
	_actor_show(false)
	cooldowns.clear()
	shown = 0
	budget = _budget_for(String(chapter) if chapter != null else "dark")
	try_in = TRY_EVERY
	# Глобальный кулдаун не в ноль: [R] возвращает игрока в начало главы,
	# и фигура в окне в первую же секунду читается как часть перезапуска.
	global_cd = START_CD


# Отладка: показать точку по id немедленно, мимо всех условий.
func force(id: String) -> bool:
	for p: Dictionary in points:
		if String(p["id"]) == id:
			_hide(false)
			_show(p)
			return true
	var names := PackedStringArray()
	for p: Dictionary in points:
		names.append(String(p["id"]))
	push_warning("haunt: нет точки «%s»; есть %s" % [id, ", ".join(names)])
	return false


# Одна строка для экрана F3.
func debug_line() -> String:
	var where := "—"
	if point != null:
		var p: Dictionary = point
		where = "%s %.1fс" % [String(p["id"]), maxf(0.0, ttl)]
	return "эхо    %s   кд %dс   %d/%d за главу" % [
		where, roundi(maxf(0.0, global_cd)), shown, budget]


# ---------- внутреннее ----------

func _budget_for(ch: String) -> int:
	var b: Array = BUDGET.get(ch, [2, 3])
	return rng.randi_range(int(b[0]), int(b[1]))


# Настоящий дед рядом с камерой? Позицию берём у самой угрозы (ai.gd держит её
# в pos), а не у фигуры: фигура едет за pos с довортом и на кадр отстаёт.
## Дед на линии сейчас ходит? Тогда двойник его, и мелькать нечем.
func _stalking() -> bool:
	var s: Variant = _cx("stalk")
	return s != null and bool(s.active())


func _threat_near() -> bool:
	var tv: Variant = _cx("threat")
	if not (tv is Threat):
		return false
	var t: Threat = tv
	if not t.is_active():
		return false
	var cam := _camera()
	if cam == null:
		return false
	var tp: Vector3 = t.pos
	var d := cam.global_position.distance_to(tp)
	if d < THREAT_NEAR:
		return true
	if d > THREAT_FRUSTUM:
		return false
	# Сфера по груди фигуры радиусом в полроста: пирамиду видимости считаем
	# по той же матрице, по которой рендерер решает, рисовать ли его.
	return _in_frustum(cam, Vector3(tp.x, tp.y + 0.9, tp.z), 0.9)


# Сфера против пирамиды. Ориентацию нормалей get_frustum() не угадываем:
# знак берём по заведомо внутренней точке — середине отрезка near..far
# по оси взгляда.
func _in_frustum(cam: Camera3D, center: Vector3, radius: float) -> bool:
	var planes := cam.get_frustum()
	if planes.size() < 6:
		return true
	var fwd := -cam.global_transform.basis.z
	var inside := cam.global_position + fwd * (cam.near + (cam.far - cam.near) * 0.5)
	for pl: Plane in planes:
		var s := 1.0 if pl.distance_to(inside) >= 0.0 else -1.0
		if pl.distance_to(center) * s < -radius:
			return false
	return true


# Высота лица над ногами. Спрашиваем фигуру один раз: у неё она посчитана
# из скелета, и держать здесь своё число значит однажды развести их.
func _face() -> float:
	if face_y == 0.0:
		var g := _actor_fig()
		var v := 0.0
		if g != null and g.has_meta("face_y"):
			v = float(g.get_meta("face_y"))
		face_y = v if v > 0.0 else FACE_FALLBACK
	return face_y


# Пока фигура стоит. Гасится за один кадр и без анимации: исчезновение
# не должно быть событием, о котором игрок может рассказать точно.
func _hold(dt: float) -> void:
	ttl -= dt
	var p: Dictionary = point
	var d := _aim(p)
	var dot := _to.dot(_fwd)
	if dot >= LOOK_AWAY:
		looked = true
	if ttl <= 0.0 or d < TOO_CLOSE or (looked and dot < LOOK_AWAY):
		_hide(true)


func _pick() -> void:
	var player: Variant = _cx("controls")
	if player == null:
		return
	var feet: Vector3 = player.feet()
	var zone_id := _zone_id(feet)

	var found: Array = []
	for p: Dictionary in points:
		if cooldowns.has(String(p["id"])):
			continue
		var zones: Array = p["zones"]
		if not zones.has(zone_id):
			continue
		var d := _aim(p)
		if d < NEAR or d > FAR:
			continue
		if _to.dot(_fwd) >= LOOK_AWAY:
			continue
		if not bool(p["see_through"]) and not _clear(d):
			continue
		found.append(p)
	if found.is_empty():
		return

	var chosen: Dictionary = found[rng.randi_range(0, found.size() - 1)]
	_show(chosen)
	shown += 1
	var ten: Variant = _cx("tension")
	if ten != null:
		ten.spent(INTENSITY)


# Готовит взгляд и единичный вектор на лицо точки, возвращает расстояние
# до лица. Один вектор на три проверки: угол, дистанция и луч смотрят в одну
# и ту же точку, иначе фигура появлялась бы на границе видимости.
func _aim(p: Dictionary) -> float:
	var cam := _camera()
	if cam == null:
		return INF
	_fwd = (-cam.global_transform.basis.z).normalized()
	_eye = cam.global_position
	var pp: Array = p["pos"]
	_to = Vector3(
		float(pp[0]) - _eye.x,
		float(pp[1]) + _face() - _eye.y,
		float(pp[2]) - _eye.z)
	var d := _to.length()
	_to = _to / (d if d > 0.0 else 1.0)
	return d


# Не упирается ли луч в стену. Та же логика, что у Interact: только статика
# (без стёкол и силуэтов) и допуск 0.2 м на то, что фигура стоит вплотную
# к проёму.
func _clear(l: float) -> bool:
	if col == null:
		return true
	var t := Threat.ray_static(col, _eye.x, _eye.y, _eye.z, _to.x, _to.y, _to.z, l)
	return t == INF or t > l - 0.2


func _show(p: Dictionary) -> void:
	point = p
	ttl = TTL_MIN + rng.randf() * (TTL_MAX - TTL_MIN)
	looked = false
	var pp: Array = p["pos"]
	var lk: Array = p["look"]
	_actor_place(float(pp[0]), float(pp[1]), float(pp[2]))
	_actor_face(float(lk[0]), float(lk[1]))
	_actor_show(true)
	# Походку не крутим: он стоит. Шевелящаяся на месте фигура выдаёт себя
	# как анимацию, а неподвижная — как то, что игроку показалось.

	# Звук — только с «ТЕМНОТЫ» и только бытовой. Стингер и тряска сюда
	# не приходят никогда: пугает то, что появление ничем не отмечено.
	var st: Variant = _cx("state")
	if st != null and bool(st.atLeast("dark")) and rng.randf() < 0.5:
		# Уличным точкам звука не даём вовсе: скрип половицы, когда он стоит
		# в огороде, врёт игроку о том, где он, — а врать про это нельзя.
		var y: Dictionary = GameData.site()["Y"]
		var feet_y := float(pp[1])
		if feet_y > float(y["ATTIC"]) - 0.5:
			_audio_call("steps_above", [1])
		elif feet_y > float(y["FLOOR1"]) - 0.1:
			_audio_call("creak", [0.6])


func _hide(spend: bool) -> void:
	if point == null:
		return
	if spend:
		var p: Dictionary = point
		cooldowns[String(p["id"])] = POINT_CD
		global_cd = GLOBAL_CD
	point = null
	ttl = 0.0
	looked = false
	_actor_show(false)


# ---------- ctx ----------

func _cx(key: String) -> Variant:
	if c is Dictionary:
		var d: Dictionary = c
		return d.get(key, null)
	if c == null:
		return null
	return c.get(key)


func _audio_call(method: String, args: Array) -> void:
	var a: Variant = _cx("audio")
	if a != null and a.has_method(method):
		a.callv(method, args)


# Имя поля — как в state.gd и в оригинале: threatState.
func _state_str(st: Variant) -> String:
	if st == null:
		return "absent"
	var v: Variant = st.get("threatState")
	return "absent" if v == null else String(v)


func _camera() -> Camera3D:
	var r: Variant = _cx("renderer")
	if r == null:
		return null
	var cam: Variant = r.camera
	return cam as Camera3D


# Зона игрока. world.zone_at — Callable из world_builder.build().
func _zone_id(feet: Vector3) -> String:
	var w: Variant = _cx("world")
	if not (w is Dictionary):
		return ""
	var d: Dictionary = w
	if not d.has("zone_at"):
		return ""
	var f: Variant = d["zone_at"]
	if not (f is Callable):
		return ""
	var cb: Callable = f
	var z: Variant = cb.call(feet.x, feet.y, feet.z)
	if z is Dictionary:
		var zd: Dictionary = z
		return String(zd.get("id", ""))
	return ""


# ---------- актёр ----------
# Имена place/face берём из оригинала; get и show в GDScript заняты Object
# и Node3D, поэтому у actors.gd они называются иначе — ищем по нескольким.

func _actor_fig() -> Node3D:
	if actors == null:
		return null
	for m: String in ["get_actor", "figure", "get_figure"]:
		if actors.has_method(m):
			var g: Variant = actors.call(m, "echo")
			return g as Node3D
	return null


func _actor_show(on: bool) -> void:
	if actors == null:
		return
	if actors.has_method("show_actor"):
		actors.show_actor("echo", on)
	elif actors.has_method("set_shown"):
		actors.set_shown("echo", on)


func _actor_place(x: float, y: float, z: float) -> void:
	if actors != null and actors.has_method("place"):
		actors.place("echo", x, y, z, 0.0)


func _actor_face(x: float, z: float) -> void:
	if actors != null and actors.has_method("face"):
		actors.face("echo", x, z)

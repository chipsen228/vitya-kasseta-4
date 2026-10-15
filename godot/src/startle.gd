# Испуги по местам: пятнадцать точек, где дом бьёт первым (раунд 10).
#
# ЧЕМ ЭТО НЕ ЯВЛЯЕТСЯ. В игре уже три модуля страха, и ни один не делает того,
# что просили: haunt.gd ставит фигуру ТУДА, КУДА ИГРОК НЕ СМОТРИТ, и по случаю;
# dread.gd играет звук из соседней комнаты; omens.gd меняет мир за спиной.
# Все трое ОППОРТУНИСТЫ: они ждут, пока сложатся условия, и оттого никогда
# не совпадают с сюжетом. Выйти из сарая и получить силуэт в лицо — это другое.
# Здесь испуг привязан к МЕСТУ И МОМЕНТУ: порог сарая, середина лестничного
# марша, первый шаг на веранду после улицы. Игрок проходит там ровно раз,
# и ровно там его ждут.
#
# ПОЧЕМУ ЭТО НЕ ПРЕВРАЩАЕТСЯ В ТИР. Четыре ограничителя, и каждый нужен:
#   * once     — точка срабатывает один раз за прохождение (флаг в состоянии);
#   * BUDGET   — не больше трёх-четырёх за главу, сколько бы точек ни прошёл;
#   * GLOBAL_CD— семьдесят пять секунд тишины после любого испуга;
#   * tension  — шкала фазы 8 решает последней: на пике не проходит ничто.
# Не сложилось — точка НЕ сгорает: бюджет не тратится, флаг не ставится, и
# игрок получит её при следующем заходе. Пропущенный испуг лучше испуга,
# который лёг поверх другого.
#
# ЧЕТЫРЕ ВИДА, И ТОЛЬКО ЧЕТЫРЕ:
#   flash  — 0.3–0.5 с силуэта прямо в кадре, стингер, встряска фонаря. Резкий
#            удар. Требует ЧИСТОГО ЛУЧА: испуг за стеной — потраченная точка.
#   window — фигура стоит 2.5–4 с и гаснет, когда на неё посмотрели и
#            отвернулись. Ставится, только пока игрок её НЕ ВИДИТ (угол или
#            стена), иначе появление читается как поп-ин, а не как ужас.
#   pass   — кто-то проходит мимо проёма за 0.9–1.2 с. Звук зовёт обернуться,
#            движение застаётся хвостом.
#   sign   — без фигуры вовсе: звук, мигание фонаря. Там, где двойника ставить
#            некуда, а вздрогнуть надо.
#
# ДВОЙНИК ОДИН НА ВСЮ ИГРУ, и очередь к нему уже занята: 'threat' принадлежит
# ai.gd, 'echo' — haunt.gd, а в главе УЛИЦА того же 'echo' держит street_stalk.
# Поэтому здесь: holdEcho перед показом (haunt уходит с дороги), отказ, пока
# stalk.active(), и отказ, пока настоящий дед ближе THREAT_NEAR. Два одинаковых
# деда в одном кадре не пугают, а смешат.
class_name Startle
extends RefCounted

const TRY_EVERY := 0.2        # как часто вообще смотрим, где стоит игрок
const GLOBAL_CD := 75.0
const START_CD := 8.0         # тишина в начале главы и после [R]
const THREAT_NEAR := 16.0
const FACE_FALLBACK := 1.58
# Порог «смотрит». Тот же, что у haunt: край кадра при FOV 70 — это dot 0.626.
const LOOK_AWAY := 0.55

# Сколько испугов за главу. Меньше, чем точек в ней: игрок, обошедший дом
# кругом, не должен собрать их все подряд.
#
# ФАЗА 11: бюджеты подняты вслед за пропускной способностью арбитра. Числа
# раунда 10 (0·2·3·3·3·2·4·1) держали первую половину ночи почти пустой,
# а у ВОРОТ бюджет 1 при полном отсутствии точек с min:"gate" означал ноль.
const BUDGET := {
	"prologue": 0,
	"arrive": 3,
	"light": 4,
	"loft": 5,
	"tapes": 4,
	"street": 5,
	"dark": 6,
	# ДЕРЕВНЯ (фаза 12): карта вдвое больше улицы, и точек в ней ровно шесть.
	# Бюджет пять — то есть игрок, обошедший всю линию, соберёт почти все,
	# а прошедший её насквозь по делу увидит два-три раза.
	"village": 5,
	"gate": 2,
	"end": 0,
}

const ONCE_PREFIX := "startle-"

# Точка. Поля:
#   at    — центр триггера [x, y, z]; r — радиус в плане, dy — допуск по высоте
#           ног. Высота нужна: лестница проходит над прихожей, и без dy
#           лестничный испуг срабатывал бы снизу.
#   from  — id зоны, в которой игрок был ДО этой. «Вышел из сарая» — это
#           не координата, это переход, и ловится он только так.
#   min   — минимальная глава (state.atLeast).
#   need  — флаг состояния, без которого точка не имеет смысла.
#   kind  — flash | window | pass | sign.
#   pos   — ноги фигуры; look — [x, z], куда она повёрнута. Нет look — смотрит
#           на игрока.
#   to    — вторая точка для pass.
#   hold  — сколько длится.
#   sfx   — имя звука; gain — его громкость.
#   i     — интенсивность для шкалы напряжения.
const POINTS := [
	# ---------- сарай ----------
	{
		# Порог сарая изнутри наружу. Дверь одна (shed-n, x=6.8), мимо неё
		# не выйти, и в двух с половиной метрах прямо по курсу стоит он.
		"id": "shed-out", "at": [6.80, 0.00, 9.30], "r": 1.05, "dy": 1.30,
		"from": "shed", "min": "arrive", "kind": "flash",
		"pos": [6.90, 0.00, 6.90], "hold": 0.38,
		"sfx": "stinger-2", "i": 3,
	},
	{
		# Тот же порог, обратно. Игрок вошёл и смотрит вглубь сарая — за спиной
		# у него проём, и вдоль проёма кто-то проходит. Скрип зовёт обернуться.
		"id": "shed-in", "at": [6.80, 0.00, 10.90], "r": 1.05, "dy": 1.30,
		"from": "plot", "min": "arrive", "kind": "pass",
		"pos": [8.60, 0.00, 9.20], "to": [5.00, 0.00, 9.20], "hold": 1.10,
		"sfx": "creak-hard", "gain": 0.8, "i": 2,
	},

	# ---------- лестница ----------
	{
		# Верхний марш. Он идёт по x от -4.55 до -2.66 и упирается ровно
		# в проём комнаты деда (w-vitya-w, x=-1.8, z=12.9) — то есть человек,
		# поднимающийся на мансарду, всю дорогу смотрит в этот проём.
		# Полсекунды в нём кто-то стоит.
		"id": "stairs-up", "at": [-3.60, 2.68, 12.70], "r": 1.15, "dy": 0.80,
		"min": "light", "kind": "flash",
		"pos": [-1.30, 3.30, 12.90], "hold": 0.34,
		"sfx": "stinger", "i": 3,
	},
	{
		# Нижний марш вниз, уже ночью. Фигуру сюда не поставить: сверху
		# перекрытие, снизу прихожая, и любая точка либо в стене, либо
		# не видна. Значит — шаги над головой и мигание фонаря.
		"id": "stairs-down", "at": [-5.05, 1.10, 10.80], "r": 1.10, "dy": 0.90,
		"min": "dark", "kind": "sign",
		"sfx": "steps-above", "hold": 0.0, "i": 2,
	},

	# ---------- первый этаж ----------
	{
		# Вход в прихожую с веранды. Фигура ставится, пока игрок ещё на веранде
		# и створ закрыт стеной: он делает шаг — и лестница уже занята.
		# Стоит она НА МАРШЕ, выше вошедшего, и смотрит на дверь. Конец коридора
		# (куда её ставили сперва) отпал по замеру: прихожая перегорожена
		# мебелью на уровне лица, и оттуда её не видно ни с одной позиции —
		# см. tests/test_startle_points.
		"id": "hall-first", "at": [-3.60, 0.45, 9.05], "r": 0.85, "dy": 0.60,
		"from": "veranda", "min": "light", "kind": "window",
		"pos": [-5.05, 1.27, 11.00], "look": [-3.60, 10.60], "hold": 3.50,
		"seen_from": [-3.60, 0.45, 10.60], "i": 3,
	},
	{
		# Вход на кухню с веранды. Кухня заперта между четырьмя комнатами,
		# окон наружу у неё нет вовсе — поэтому он стоит в дальнем проёме,
		# в трёх с половиной метрах, ровно по курсу.
		"id": "kitchen-first", "at": [-0.40, 0.45, 9.05], "r": 0.85, "dy": 0.60,
		"from": "veranda", "min": "light", "kind": "flash",
		"pos": [-0.60, 0.45, 12.60], "hold": 0.42,
		"sfx": "stinger-3", "i": 3,
	},
	{
		# Общая комната из прихожей. Восточное окно (z=14.4) — единственный
		# створ первого этажа, который простреливается с большинства позиций;
		# это посчитано tests/test_haunt_points.gd, и точка взята оттуда же.
		"id": "living-first", "at": [-2.30, 0.45, 13.60], "r": 0.90, "dy": 0.60,
		"min": "light", "kind": "window",
		"pos": [4.78, 0.00, 14.40], "look": [0.00, 14.40], "hold": 3.20,
		"sfx": "glass-tap", "gain": 0.7, "i": 2,
	},
	{
		# Дальняя комната. За северным окном (w-n1, x=2.7) — двор, из которого
		# он и приходит.
		"id": "aunt-first", "at": [2.60, 0.45, 8.60], "r": 1.50, "dy": 0.60,
		"min": "light", "kind": "window",
		"pos": [2.70, 0.00, 6.35], "look": [2.70, 9.00], "hold": 2.80,
		"i": 2,
	},

	# ---------- мансарда и чердак ----------
	{
		# Ступил на мансарду — за стеной, в комнате деда, скрипнула кровать.
		"id": "attic-first", "at": [-2.60, 3.30, 12.60], "r": 1.30, "dy": 0.60,
		"min": "loft", "kind": "sign",
		"sfx": "bed-creak", "hold": 0.0, "i": 2,
	},
	{
		# Чердак. Фигуру сюда не поставить: потолок 1.85, всё пространство
		# режут стропила, и tests/test_startle_points показал, что из люка
		# не видно ни одной точки дальнего конца. Значит — половица над
		# головой у того, кто и так стоит под самой крышей.
		"id": "roof-in", "at": [-3.20, 5.90, 13.40], "r": 1.10, "dy": 0.80,
		"min": "loft", "kind": "sign",
		"sfx": "floor-creak-far", "hold": 0.0, "i": 2,
	},
	{
		# Балкон. Вышел подышать — а он внизу, у калитки, и смотрит вверх.
		# Ближе поставить нельзя: парапет (h=1.0) срезает всё, что ближе
		# ворот, — луч упирается в него, и фигуры просто не видно.
		"id": "balcony-out", "at": [-2.40, 3.30, 7.40], "r": 1.40, "dy": 0.70,
		"min": "loft", "kind": "window",
		"pos": [-2.40, 0.00, 0.60], "look": [-2.40, 8.10], "hold": 3.40,
		"i": 2,
	},

	# ---------- подпол ----------
	{
		# Дальний угол подпола. Потолок 1.9, фигура стоит впритык, и видно
		# её только по грудь — остальное съедает темнота.
		"id": "cellar-in", "at": [-3.00, -1.55, 10.50], "r": 1.60, "dy": 0.80,
		"min": "light", "kind": "window",
		"pos": [3.40, -1.55, 11.60], "look": [-2.50, 11.00], "hold": 2.60,
		"sfx": "whisper-close", "gain": 0.6, "i": 3,
	},

	# ---------- участок ----------
	{
		# Теплица. Стекло мутное и лежит в статике — луч сквозь него не идёт,
		# поэтому see_through, ровно как у одноимённой точки мелькания.
		"id": "greenhouse-in", "at": [-8.00, 0.00, 21.00], "r": 1.00, "dy": 0.80,
		"min": "light", "kind": "window", "see_through": true,
		"pos": [-5.00, 0.00, 21.00], "look": [-7.00, 21.00], "hold": 2.80,
		"i": 2,
	},
	{
		# Уличный туалет. Полтора метра, дверной проём, деваться некуда.
		"id": "privy-in", "at": [8.60, 0.00, 21.00], "r": 0.80, "dy": 0.80,
		"min": "light", "kind": "flash",
		"pos": [8.60, 0.00, 19.40], "hold": 0.36,
		"sfx": "stinger", "i": 3,
	},

	# ---------- улица и возврат ----------
	{
		# Первый шаг за ворота. Дед ещё не вышел на линию (это делает
		# street_quest позже), и полосу занять некому.
		"id": "gate-out", "at": [0.00, 0.00, -1.00], "r": 2.60, "dy": 1.00,
		"from": "plot", "min": "street", "kind": "flash",
		"pos": [-4.20, 0.00, -1.60], "hold": 0.40,
		"sfx": "stinger-2", "i": 3,
	},
	{
		# Правление. Кирпичная коробка на тридцати метрах западнее, внутри
		# темно и тесно.
		"id": "office-in", "at": [-30.00, 0.00, -9.50], "r": 1.80, "dy": 0.90,
		"min": "street", "kind": "flash",
		"pos": [-31.60, 0.00, -11.80], "hold": 0.40,
		"sfx": "stinger-3", "i": 3,
	},
	{
		# Возврат в дом после улицы. Дом уже не тот, и первое, что от него
		# достаётся, — фигура в проёме прихожей, в трёх метрах.
		"id": "veranda-back", "at": [-2.30, 0.45, 6.90], "r": 1.10, "dy": 0.60,
		"from": "porch", "min": "dark", "kind": "flash",
		"pos": [-3.60, 0.45, 9.70], "hold": 0.36,
		"sfx": "stinger-2", "i": 3,
	},

	# ---------- фаза 11: отрезок ворота -> правление ----------
	# Двадцать девять метров грунтовки без единой точки, а игрок проходит их
	# четырежды: за ключом, к правлению, обратно и к бочке. Три события на всю
	# дорогу — это по одному на два прохода.
	{
		# Бочка у столба. Пока игрок стоит к ней спиной и держит [E], на обочине
		# кто-то есть. Вид window: появление в кадре читалось бы поп-ином.
		"id": "barrel-side", "at": [-13.00, 0.00, -2.60], "r": 2.20, "dy": 1.00,
		"min": "street", "kind": "window",
		"pos": [-13.00, 0.00, -6.75], "look": [-13.00, -1.00], "hold": 3.20,
		"sfx": "cloth-run", "gain": 0.7, "i": 2,
	},
	{
		# Столб на повороте к правлению. Фигуре тут стоять негде — до леса
		# семь метров открытой обочины, — поэтому крик из тумана и ничего больше.
		"id": "pole-cry", "at": [-29.00, 0.00, -2.20], "r": 2.60, "dy": 1.00,
		"min": "street", "kind": "sign",
		"sfx": "scream-far", "gain": 0.5, "hold": 0.0, "i": 2,
	},
	{
		# Заколоченный дом. Через дорогу перед ним кто-то проходит — слева
		# направо, за секунду с небольшим. В проём его собственной двери фигуру
		# не поставить: она заложена тёмной доской, и за ней ничего не видно.
		"id": "boarded-pass", "at": [-5.50, 0.00, -3.20], "r": 2.40, "dy": 1.00,
		"min": "street", "kind": "pass",
		"pos": [-6.60, 0.00, -6.60], "to": [-4.40, 0.00, -6.60], "hold": 1.20,
		"sfx": "cloth-run", "gain": 0.8, "i": 2,
	},

	# ---------- фаза 11: баня и погреб ----------
	{
		# Выход из парной в предбанник. Низкий проём, за ним темно, и ровно
		# в момент, когда игрок под него ныряет, предбанник занят.
		"id": "banya-out", "at": [4.80, 0.12, 23.60], "r": 0.90, "dy": 0.50,
		"min": "loft", "kind": "flash",
		"pos": [3.60, 0.12, 21.90], "hold": 0.36,
		"sfx": "stinger", "i": 3,
	},
	{
		# Погреб: игрок вошёл, а дальний угол за бельевой верёвкой уже занят.
		"id": "cellar-shed-in", "at": [-6.20, 0.10, 2.35], "r": 0.90, "dy": 0.50,
		"from": "plot", "min": "loft", "kind": "window",
		"pos": [-8.60, 0.10, 3.80], "look": [-5.70, 2.30], "hold": 3.00,
		"sfx": "cloth-run", "gain": 0.6, "i": 2,
	},

	# ---------- фаза 11: огород и подпол ----------
	{
		# Глубина грядок: шестнадцать метров от дома, дальний забор в тумане.
		"id": "garden-far", "at": [0.00, 0.00, 24.00], "r": 2.00, "dy": 0.80,
		"min": "tapes", "kind": "window",
		"pos": [-4.60, 0.00, 28.40], "look": [0.00, 20.00], "hold": 3.20,
		"i": 2,
	},
	{
		# Подпол у тайника. Фигуру сюда не поставить: потолок 0.35 над ногами,
		# и всё, что не в створе лестницы, срезано. Значит — жестянка, которую
		# кто-то открыл в двух метрах за спиной.
		"id": "cellar-tin", "at": [0.60, -1.55, 15.20], "r": 1.60, "dy": 0.80,
		"min": "dark", "kind": "sign",
		"sfx": "tin-open", "hold": 0.0, "i": 3,
	},

	# ---------- фаза 11: ВОРОТА ----------
	# У главы был бюджет 1 и НИ ОДНОЙ точки с min:"gate" — то есть ноль.
	# Последние тридцать метров до машины проходились в полной пустоте.
	{
		# Двор по дороге к воротам. Он стоит у восточного угла и не двигается.
		"id": "gate-yard", "at": [-1.20, 0.00, 2.80], "r": 1.80, "dy": 0.80,
		"min": "gate", "kind": "flash",
		"pos": [5.20, 0.00, 4.40], "hold": 0.38,
		"sfx": "stinger-3", "i": 3,
	},
	{
		# Дверь машины. Триггер стоит СБОКУ от кузова: коробка «жигулей»
		# занимает x −1…3.2, z −3.6…−1.8, и точка внутри неё мертва —
		# игрок туда не помещается вовсе.
		"id": "gate-car", "at": [3.90, 0.00, -2.70], "r": 1.60, "dy": 0.90,
		"min": "gate", "kind": "window",
		"pos": [9.40, 0.00, -4.60], "look": [3.90, -2.70], "hold": 3.20,
		"i": 2,
	},

	# ---------- фаза 12: ДЕРЕВНЯ ----------
	# Шесть точек на девяносто метров линии, по одной на место. Все звуки —
	# из уже запечённого и уже сгенерированного: новых wav фаза не заводит,
	# и это не экономия ради экономии, а остаток счёта ElevenLabs, целиком
	# отданный шестнадцати репликам.
	{
		# Автобусная остановка, западный конец. Под навесом на скамье сидят.
		# Триггер стоит на дороге, лицом к навесу: створ открыт, стенок между
		# ними нет — остановка открыта на юг.
		"id": "stop-bench", "at": [-42.40, 0.00, -5.00], "r": 1.35, "dy": 1.30,
		"min": "village", "kind": "flash",
		"pos": [-43.80, 0.00, -6.80], "hold": 0.40,
		"sfx": "stinger-3", "i": 3,
	},
	{
		# Остов трактора в бурьяне. Фигура выходит из-за него — с той стороны,
		# с которой её не ждут: игрок смотрит на кабину, а она у колеса.
		"id": "tractor-side", "at": [-36.50, 0.00, -7.20], "r": 1.60, "dy": 1.30,
		"min": "village", "kind": "flash",
		"pos": [-37.60, 0.00, -9.40], "hold": 0.38,
		"sfx": "stinger-2", "i": 3,
	},
	{
		# Колодец. Фигуре тут стоять негде — сруб, стойки и домик занимают
		# весь пятачок, — поэтому знак: цепь размоталась сама. Звук
		# запечённый, тот же, что у ворот.
		"id": "well-chain", "at": [-23.50, 0.00, -7.60], "r": 2.10, "dy": 1.30,
		"min": "village", "kind": "sign",
		"sfx": "chain", "hold": 0.0, "i": 2,
	},
	{
		# Трансформаторная будка. Кто-то проходит вдоль её стены и уходит
		# за угол: створ полтора метра, и в кадре он ровно секунду.
		"id": "booth-pass", "at": [22.50, 0.00, -6.40], "r": 1.60, "dy": 1.30,
		"min": "village", "kind": "pass",
		"pos": [24.60, 0.00, -8.20], "to": [20.60, 0.00, -8.20], "hold": 1.10,
		"sfx": "creak-hard", "gain": 0.8, "i": 2,
	},
	{
		# Выход из сельпо. Тот же приём, что на пороге сарая в первой главе:
		# дверь одна, мимо неё не выйти, и в двух шагах прямо по курсу стоят.
		"id": "shop-out", "at": [28.90, 0.00, -6.60], "r": 1.30, "dy": 1.40,
		"from": "shop", "min": "village", "kind": "flash",
		"pos": [26.40, 0.00, -5.80], "hold": 0.36,
		"sfx": "stinger", "i": 3,
	},
	{
		# Погост. Триггер у калитки, фигура — между дальними крестами,
		# то есть ровно там, где её и ждут. Тем и берёт.
		"id": "grave-cross", "at": [40.05, 0.00, -8.00], "r": 1.30, "dy": 1.30,
		"min": "village", "kind": "flash",
		"pos": [42.30, 0.00, -11.20], "hold": 0.42,
		"sfx": "sting-soft", "i": 2,
	},

	# ---------- фаза 13 ----------
	# Две точки, и обе — в местах, которые эта фаза открыла. Без них новые
	# пространства читаются декорацией: игрок проводит в саду и в красном
	# доме по несколько минут и не встречает там ровно ничего.
	{
		# Сад за огородом. Фигура стоит между яблонями — там, где её не ждут,
		# потому что до этой фазы за грядками не было вообще ничего.
		# Створ открыт: между триггером и точкой только трава.
		"id": "orchard-tree", "at": [-6.20, 0.00, 26.80], "r": 1.60, "dy": 1.30,
		"min": "dark", "kind": "flash",
		"pos": [-8.60, 0.00, 28.80], "hold": 0.40,
		"sfx": "sting-soft", "i": 2,
	},
	{
		# Выход из красного дома. Тот же приём, что на пороге сарая и сельпо,
		# и работает он по той же причине: дверь одна, мимо неё не выйти.
		"id": "redhouse-out", "at": [0.90, 0.00, -6.90], "r": 1.30, "dy": 1.40,
		"from": "redhouse", "min": "village", "kind": "flash",
		"pos": [-1.40, 0.00, -6.10], "hold": 0.36,
		"sfx": "stinger-2", "i": 3,
	},

	# ---------- фаза 14: околица и второй этаж ----------
	# Шесть точек на семь новых участков, и распределены они не поровну.
	# Карта выросла вдвое, а страх на площади размазывается: пустое большое
	# пугает хуже тесного. Поэтому точки стоят там, где игрок ОСТАНАВЛИВАЕТСЯ
	# по делу — у гвоздя с ключом, на мостках, в будке, на лестнице, у
	# банной стремянки, в зале клуба, — а не «по одной на участок».
	{
		# Стойло амбара. Игрок стоит в пустой западной половине и снимает
		# ключ; фигура — за перегородками, в третьем стойле. Досок ей по
		# грудь: над ними видно голову, и только голову.
		"id": "barn-stall", "at": [-36.60, 0.00, -29.60], "r": 1.50, "dy": 1.20,
		"min": "village", "kind": "flash",
		"pos": [-34.20, 0.00, -30.40], "hold": 0.38,
		"sfx": "stinger-2", "i": 3,
	},
	{
		# Мостки пожарного пруда. Вид window: игрок стоит к воде лицом,
		# а появляется тот, кто на восточном берегу, — за спиной.
		"id": "pond-planks", "at": [-23.00, 0.00, -28.50], "r": 1.40, "dy": 1.00,
		"min": "village", "kind": "window",
		"pos": [-19.20, 0.00, -32.60], "look": [-23.00, -28.50], "hold": 3.00,
		"sfx": "cloth-run", "gain": 0.7, "i": 2,
	},
	{
		# Будка водокачки. Фигуру сюда не поставить: единственный проём —
		# дверь, и стоящий в ней перекрывает игроку выход, то есть читается
		# не испугом, а тупиком. Поэтому звук и мутное стекло, за которым
		# ничего не разобрать.
		"id": "pump-glass", "at": [-15.00, 0.00, -29.20], "r": 1.20, "dy": 0.90,
		"from": "pumphouse", "min": "village", "kind": "sign",
		"sfx": "sting-soft", "hold": 0.0, "i": 2,
	},
	{
		# Верхняя площадка лестницы красного дома. Игрок только что поднялся
		# и стоит спиной к маршу; фигура — у кровати, в трёх метрах, между
		# ним и единственным окном.
		"id": "redhouse-stair", "at": [2.76, 2.64, -12.20], "r": 0.80, "dy": 1.20,
		"from": "redhouse-up", "min": "village", "kind": "flash",
		"pos": [0.60, 2.64, -12.40], "hold": 0.36,
		"sfx": "stinger-3", "i": 3,
	},
	{
		# Стремянка на чердак бани. Наверху темно и низко, и ставить туда
		# фигуру нельзя по той же причине, что в будку: подъём один.
		# Скрип над головой ровно в ту секунду, когда берёшься за перекладину.
		"id": "banya-ladder", "at": [7.42, 0.00, 23.90], "r": 1.20, "dy": 1.10,
		"min": "village", "kind": "sign",
		"sfx": "sting-soft", "hold": 0.0, "i": 2,
	},
	{
		# Зал клуба. Шесть метров пустоты между дверью и дальней стеной —
		# единственное на околице место, где фигуру видно целиком и издалека.
		"id": "club-hall", "at": [9.00, 0.00, -28.40], "r": 1.60, "dy": 1.20,
		"from": "club", "min": "village", "kind": "flash",
		"pos": [7.90, 0.00, -31.40], "hold": 0.40,
		"sfx": "stinger-3", "i": 3,
	},

	# СНТ принадлежит SntQuest: сигнал у будки и тихие местные звуки.

]

var c: Dictionary = {}
var actors: Variant = null
var col: CollisionWorld = null

var chapter := ""
var shown := 0
var cool := START_CD

var _try := TRY_EVERY
var _live := ""               # id идущего испуга, пусто — ничего не идёт
var _kind := ""
var _left := 0.0
var _span := 0.0
var _from := Vector3.ZERO
var _to_pt := Vector3.ZERO
var _looked := false
var _zone := ""
var _zone_prev := ""
var _face_y := 0.0
var _played := 0              # всего за прохождение, для F3

var _eye := Vector3.ZERO
var _dir := Vector3.ZERO
var _fwd := Vector3.ZERO


func _init(ctx: Dictionary, actors_in: Variant = null, col_in: Variant = null) -> void:
	c = ctx
	actors = actors_in if actors_in != null else ctx.get("actors")
	var cw: Variant = col_in if col_in != null else ctx.get("col")
	if cw is CollisionWorld:
		col = cw


# ------------------------------------------------------------------ кадр ----

func update(dt: float) -> void:
	var st: Variant = c.get("state")
	if st == null:
		return

	if _live != "":
		# Дед мог выйти на линию ровно в эту секунду: улица занимает двойника
		# на всю главу, и спорить с ней нельзя — свой момент бросаем.
		if _kind != "sign" and _stalking():
			_hide()
		else:
			_run(dt)
			return

	cool = maxf(0.0, cool - dt)
	_try -= dt
	if _try > 0.0:
		return
	_try = TRY_EVERY

	var cur := String(st.get("chapter"))
	if cur != chapter:
		chapter = cur
		shown = 0

	var feet := _feet()
	# Зону считаем ВСЕГДА, даже когда испуг сыграть нельзя: переход
	# «сарай -> участок» случается один раз, и пропустив его на кулдауне,
	# мы потеряли бы половину точек.
	_track(feet)

	if cool > 0.0 or shown >= int(BUDGET.get(cur, 2)):
		return
	if bool(st.get("hidden")):
		return

	for p: Dictionary in POINTS:
		if _fits(p, st, feet):
			_fire(p, st)
			return


## При [R] и при разводе с угрозой: погасить фигуру и вернуть тишину.
## Флаги «уже было» НЕ снимаются — они живут в состоянии игры и уходят
## вместе с ним, иначе смерть у ворот возвращала бы испуги на второй заход.
func reset() -> void:
	_hide()
	cool = START_CD
	shown = 0
	_zone = ""
	_zone_prev = ""


## Отдать двойника тому, кто его требует. Зовётся из holdEcho: у постановочных
## сцен глав приоритет выше — они ставят фигуру сами и на своё место.
##
## ФАЗА 18. Первая строка новая и она чинит «деда на линии не видно никогда».
## Отдавать нечего, когда ничего не идёт: _live пуст — момента нет, и _hide()
## гасил не свою фигуру, а чужую, поставленную сценой главы полкадра назад.
## Через holdEcho сюда приходят ВСЕ постановки игры, и каждая гасила себя
## этой строкой.
func clear() -> void:
	if _live == "":
		return
	if _kind != "sign":
		_hide()


## Отладка: сыграть точку по id немедленно, мимо всех условий.
func force(id: String) -> bool:
	for p: Dictionary in POINTS:
		if String(p["id"]) == id:
			_hide()
			var before := _played
			_fire(p, c.get("state"))
			return _played > before
	return false


## Одна строка для экрана F3.
func debug_line() -> String:
	var where := "—" if _live == "" else "%s %.1fс" % [_live, maxf(0.0, _left)]
	return "испуг  %s   кд %dс   %d/%d за главу   всего %d" % [
		where, roundi(cool), shown, int(BUDGET.get(chapter, 2)), _played]


# --------------------------------------------------------------- отбор ------

func _fits(p: Dictionary, st: Variant, feet: Vector3) -> bool:
	var id := String(p["id"])
	if c.get("horror") != null and ThresholdScares.RETIRED_STARTLE.has(id): return false
	if bool(st.has(ONCE_PREFIX + id)):
		return false
	if st is GameState and (st as GameState).horror_seen.has("startle/" + id):
		return false
	# Дешёвое вперёд дорогого: сначала прямоугольник, и только потом флаги,
	# лучи и шкала. Точек пятнадцать, а проверка идёт пять раз в секунду.
	var at: Array = p["at"]
	var dx := feet.x - float(at[0])
	var dz := feet.z - float(at[2])
	var r := float(p.get("r", 1.2))
	if dx * dx + dz * dz > r * r:
		return false
	if absf(feet.y - float(at[1])) > float(p.get("dy", 1.0)):
		return false
	if not bool(st.atLeast(String(p.get("min", "arrive")))):
		return false
	var from := String(p.get("from", ""))
	if from != "" and _zone_prev != from:
		return false
	var need := String(p.get("need", ""))
	if need != "" and not bool(st.has(need)):
		return false

	var kind := String(p.get("kind", "flash"))
	if kind != "sign":
		# Двойник занят: настоящий дед рядом, либо он же ходит по улице.
		if _threat_near() or _stalking():
			return false
		if actors == null:
			return false
	# Резкие эффекты выключены в настройках — удары не играем вовсе. Тихие
	# появления остаются: галочка снимает вздрагивание, а не атмосферу.
	if not _scares_on():
		return false

	# Шкала напряжения решает последней. Нет её в ctx — модуль работает
	# ровно как без фазы 8.
	var ten: Variant = c.get("tension")
	if ten != null and not bool(ten.allows(int(p.get("i", 2)))):
		return false

	if kind == "window":
		# Ставим, только пока игрок точку НЕ ВИДИТ: появление в кадре
		# читается как поп-ин.
		return not _visible(p)
	if kind == "flash" or kind == "pass":
		# И наоборот: удар за стеной — потраченная точка.
		return _visible(p)
	return true


# --------------------------------------------------------------- показ ------

func _fire(p: Dictionary, st: Variant) -> void:
	var director_guard: Variant = c.get("horror")
	if director_guard != null:
		if ThresholdScares.RETIRED_STARTLE.has(String(p["id"])): return
		if not director_guard.random_allowed(): return
	if not _scares_on(): return
	var kind := String(p.get("kind", "flash"))
	var hold := float(p.get("hold", 0.4))

	if kind != "sign":
		# Двойника занимаем ДО показа: haunt гасит своё мелькание и в это
		# время к фигуре не подходит.
		_call("holdEcho", [hold + 2.0])
		var director: Variant = c.get("horror")
		if director != null: director.ambient_started("ambient", hold + 2.0)
		var pos: Array = p["pos"]
		_from = Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
		_to_pt = _from
		if p.has("to"):
			var t: Array = p["to"]
			_to_pt = Vector3(float(t[0]), float(t[1]), float(t[2]))
		actors.place("echo", _from.x, _from.y, _from.z, 0.0)
		_aim_figure(p)
		actors.show("echo", true)

	var snd := String(p.get("sfx", ""))
	var heard := false
	if snd != "":
		var a: Variant = c.get("audio")
		if a != null:
			var sound_at := _from if kind != "sign" else Vector3(float(p["at"][0]),float(p["at"][1])+1.4,float(p["at"][2]))
			if a.has_method("spatial_sfx"):
				heard = bool(a.spatial_sfx(snd, sound_at, float(p.get("gain", 1.0)), 20.0))
			else:
				heard = bool(a.sfx(snd, float(p.get("gain", 1.0))))
			# Тот же звук у dread'а — занимаем имя, чтобы дом не скрипнул
			# той же половицей через десять секунд.
			var dr: Variant = c.get("dread")
			if dr != null and dr.has_method("force_cooldown"):
				dr.force_cooldown(snd, 90.0)
	if director_guard != null and kind == "sign":
		if not heard: return
		director_guard.ambient_started("ambient", 0.6)

	if kind == "flash":
		var fl: Variant = c.get("flashlight")
		if fl != null:
			fl.shake(1.0)

	_live = String(p["id"])
	_kind = kind
	_left = hold
	_span = maxf(hold, 0.001)
	_looked = false
	shown += 1
	_played += 1
	cool = GLOBAL_CD
	if st != null:
		st.set_flag(ONCE_PREFIX + _live)
		if st is GameState:
			(st as GameState).horror_seen["startle/" + _live] = true
	var ten: Variant = c.get("tension")
	if ten != null:
		ten.spent(int(p.get("i", 2)))
	if kind == "sign":
		# Знаку держать нечего: звук уже ушёл, фигуры нет.
		_live = ""
		var fl2: Variant = c.get("flashlight")
		if fl2 != null:
			fl2.flicker(0.45)


func _run(dt: float) -> void:
	_left -= dt
	if _kind == "pass" and actors != null:
		var k := clampf(1.0 - _left / _span, 0.0, 1.0)
		var at := _from.lerp(_to_pt, k)
		var d := _to_pt - _from
		var yaw := atan2(d.x, d.z) + PI
		actors.place("echo", at.x, at.y, at.z, yaw)
		if actors.has_method("walk_anim"):
			actors.walk_anim("echo", dt, {})
	elif _kind == "window":
		# Гаснет по тому же правилу, что мелькание: посмотрел и отвернулся —
		# её уже нет. Иначе игрок успевает подойти и разглядеть картонку.
		var seen := _aim(_from) != INF and _dir.dot(_fwd) >= LOOK_AWAY
		if seen:
			_looked = true
		elif _looked:
			_hide()
			return
	if _left <= 0.0:
		_hide()


func _hide() -> void:
	_live = ""
	_kind = ""
	_left = 0.0
	_looked = false
	if actors != null:
		actors.show("echo", false)


# Куда фигура повёрнута. Нет look — смотрит на игрока: у резкого появления
# в двух метрах это единственный правильный ответ.
func _aim_figure(p: Dictionary) -> void:
	if actors == null:
		return
	if p.has("look"):
		var lk: Array = p["look"]
		actors.face("echo", float(lk[0]), float(lk[1]))
		return
	var feet := _feet()
	actors.face("echo", feet.x, feet.z)


# --------------------------------------------------------------- взгляд -----

# Видно ли точку прямо сейчас: и в конусе, и без стены между.
func _visible(p: Dictionary) -> bool:
	var pos: Array = p["pos"]
	var at := Vector3(float(pos[0]), float(pos[1]), float(pos[2]))
	var d := _aim(at)
	if d == INF or _dir.dot(_fwd) < LOOK_AWAY:
		return false
	# Стекло теплицы и сетка забора лежат в статике, и честный луч отсекал бы
	# ровно те точки, ради которых стекло и нужно.
	if bool(p.get("see_through", false)):
		return true
	return _clear(d)


# Заполняет _eye/_dir/_fwd и отдаёт расстояние до ЛИЦА точки. Один вектор
# на обе проверки: угол и луч смотрят в одну и ту же точку — в голову,
# а не в ноги. Игрок ловит взглядом голову в проёме.
func _aim(at: Vector3) -> float:
	var cam := _camera()
	if cam == null:
		return INF
	_fwd = (-cam.global_transform.basis.z).normalized()
	_eye = cam.global_position
	_dir = Vector3(at.x - _eye.x, at.y + _face() - _eye.y, at.z - _eye.z)
	var d := _dir.length()
	_dir = _dir / (d if d > 0.0 else 1.0)
	return d


# Не упирается ли луч в стену. Та же логика, что у haunt: только статика
# и допуск 0.2 м на то, что фигура стоит вплотную к проёму.
func _clear(l: float) -> bool:
	if col == null:
		return true
	var t := Threat.ray_static(col, _eye.x, _eye.y, _eye.z,
		_dir.x, _dir.y, _dir.z, l)
	return t == INF or t > l - 0.2


func _face() -> float:
	if _face_y == 0.0:
		var v := 0.0
		if actors != null and actors.has_method("figure"):
			var g: Node3D = actors.figure("echo")
			if g != null and g.has_meta("face_y"):
				v = float(g.get_meta("face_y"))
		_face_y = v if v > 0.0 else FACE_FALLBACK
	return _face_y


# ------------------------------------------------------------- служебное ----

func _track(feet: Vector3) -> void:
	var w: Variant = c.get("world")
	if not (w is Dictionary):
		return
	var d: Dictionary = w
	var f: Variant = d.get("zone_at")
	if not (f is Callable):
		return
	var z: Variant = (f as Callable).call(feet.x, feet.y, feet.z)
	var id := ""
	if z is Dictionary:
		id = String((z as Dictionary).get("id", ""))
	if id != "" and id != _zone:
		_zone_prev = _zone
		_zone = id


func _threat_near() -> bool:
	var tv: Variant = c.get("threat")
	if not (tv is Threat):
		return false
	var t: Threat = tv
	if not t.is_active():
		return false
	var cam := _camera()
	if cam == null:
		return false
	return cam.global_position.distance_to(t.pos) < THREAT_NEAR


func _stalking() -> bool:
	var s: Variant = c.get("stalk")
	return s != null and bool(s.active())


func _scares_on() -> bool:
	var f: Variant = c.get("scaresOn")
	if f is Callable:
		return bool((f as Callable).call())
	return true


func _feet() -> Vector3:
	var ctrl: Variant = c.get("controls")
	return Vector3.ZERO if ctrl == null else ctrl.feet()


func _camera() -> Camera3D:
	var r: Variant = c.get("renderer")
	if r == null:
		return null
	return r.camera as Camera3D


func _call(key: String, args: Array) -> void:
	var f: Variant = c.get(key)
	if f is Callable:
		(f as Callable).callv(args)

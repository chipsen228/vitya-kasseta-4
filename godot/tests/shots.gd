# Оконный смоук со скриншотами (lead, фаза 7).
#
# Не тест: ничего не проверяет и всегда возвращает 0. Это инструмент приёмки
# картинки — боут main.tscn в ОКНЕ (не headless: в Compatibility без окна
# SubViewport'ы не рисуются вовсе), расстановка игрока по точкам маршрута
# и снимок композита в PNG.
#
# Снимается PostView, а не окно целиком: это ровно тот буфер, который потом
# растягивается ближайшим соседом, без HUD и подсказок поверх. Размер файла
# и есть текущий размер буфера — по нему сразу видно, сработала ли чёткость.
#
# Запуск (ОКОННЫЙ, без --headless):
#   Godot…_console.exe --path godot --resolution 1920x1080 \
#       --script res://tests/shots.gd ++ <папка> <экспозиция> <фильтр[,фильтр...]>
#
# Без ++ снимки лягут в vitya-godot/shots.
extends SceneTree

const BOOT_FRAMES := 900
const SETTLE_FRAMES := 26      # кадров на «дожить» после расстановки
const CAPTURE_FRAMES := 4      # кадров между расстановкой и снимком

# Маршрут приёмки: двор, крыльцо, дом, оба марша, мансарда, кухня, «Шестёрка».
# night — шкала сумерки(0) → ночь(1), lamps — какие лампы горят на снимке.
#
# КУДА СМОТРИТ yaw. Направление взгляда — (-sin yaw, 0, -cos yaw), то есть
# 0 — на север (-z, в сторону улицы), PI/2 — на ЗАПАД, PI — на юг, 3PI/2 —
# на восток. Наводка на точку T из точки P: yaw = atan2(P.x - T.x, P.z - T.z).
# Правило записано после того, как половина снимков фазы 12 сняла забор:
# в именах 23 и 24 запад с востоком перепутаны с фазы 9, и по ним сверялись.
const SHOTS := [
	{"name": "01-двор-от-ворот", "pos": [0.0, 0.0, -1.2], "yaw": PI, "pitch": -0.04,
		"night": 0.10, "lamps": []},
	{"name": "02-двор-восточный-угол", "pos": [7.6, 0.0, 4.2], "yaw": PI * 0.82, "pitch": 0.10,
		"night": 0.10, "lamps": []},
	{"name": "03-крыльцо", "pos": [-2.3, 0.0, 3.4], "yaw": PI, "pitch": 0.06,
		"night": 0.25, "lamps": ["porch"]},
	{"name": "04-прихожая", "pos": [-3.0, 0.45, 11.0], "yaw": PI, "pitch": 0.0,
		"night": 0.55, "lamps": ["hall", "kitchen"]},
	{"name": "05-низ-лестницы", "pos": [-3.2, 0.45, 9.3], "yaw": PI * 0.92, "pitch": -0.16,
		"night": 0.55, "lamps": ["hall", "landing"]},
	{"name": "06-середина-марша", "pos": [-5.05, 1.34, 11.2], "yaw": PI, "pitch": 0.10,
		"night": 0.55, "lamps": ["hall", "landing"]},
	{"name": "07-площадка", "pos": [-5.05, 2.05, 12.7], "yaw": PI * 0.5, "pitch": -0.08,
		"night": 0.55, "lamps": ["landing"]},
	{"name": "08-мансарда", "pos": [-2.6, 3.3, 11.4], "yaw": PI * 0.5, "pitch": 0.0,
		"night": 0.60, "lamps": ["landing", "vitya"]},
	{"name": "09-с-площадки-на-балкон", "pos": [-3.9, 3.3, 10.2], "yaw": 0.0, "pitch": 0.02,
		"night": 0.60, "lamps": ["landing"]},
	{"name": "10-балкон", "pos": [-2.4, 3.3, 8.1], "yaw": 0.0, "pitch": 0.05,
		"night": 0.60, "lamps": []},
	{"name": "11-кухня", "pos": [-0.4, 0.45, 11.4], "yaw": PI, "pitch": 0.0,
		"night": 0.55, "lamps": ["kitchen"]},
	{"name": "12-шестёрка", "pos": [2.6, 0.0, -1.4], "yaw": PI * 1.28, "pitch": -0.02,
		"night": 0.10, "lamps": []},
	{"name": "13-дом-с-юго-востока", "pos": [7.4, 0.0, 17.4], "yaw": PI * 1.34, "pitch": 0.22,
		"night": 0.10, "lamps": []},
	{"name": "14-дом-с-запада", "pos": [-8.8, 0.0, 11.4], "yaw": PI * 1.5, "pitch": 0.16,
		"night": 0.10, "lamps": []},
	{"name": "15-дом-с-востока", "pos": [9.6, 0.0, 6.4], "yaw": PI * 0.62, "pitch": 0.16,
		"night": 0.10, "lamps": []},
	{"name": "16-дом-с-северо-запада", "pos": [-8.4, 0.0, 1.6], "yaw": PI * 1.20, "pitch": 0.18,
		"night": 0.10, "lamps": []},
	{"name": "17-крыша-от-ворот-крупно", "pos": [0.0, 0.0, 1.2], "yaw": PI, "pitch": 0.26,
		"night": 0.10, "lamps": []},
	{"name": "18-чердак", "pos": [-2.6, 5.9, 13.0], "yaw": 0.0, "pitch": 0.14,
		"night": 0.60, "lamps": ["roofspace"]},
	{"name": "19-комната-деда-потолок", "pos": [0.2, 3.3, 11.6], "yaw": PI * 1.5, "pitch": 0.30,
		"night": 0.60, "lamps": ["vitya"]},
	{"name": "20-подпол", "pos": [-3.0, -1.55, 10.5], "yaw": PI, "pitch": 0.0,
		"night": 0.60, "lamps": ["cellar"]},
	# Фаза 8: телефон встал на крышку тумбы с мойкой — точка ровно на него.
	# Сверху видно и аппарат, и листок с номерами: оба лежат на плоскости 1.12,
	# а не висят в воздухе на 1.5 и 1.4, как было в данных прототипа.
	{"name": "21-телефон-на-тумбе", "pos": [-0.6, 0.45, 10.4], "yaw": PI * 0.796, "pitch": -0.50,
		"night": 0.55, "lamps": ["kitchen"]},

	# Фаза 9: улица за воротами. Все восемь — в глухую ночь (night 1.0), потому
	# что играется она в 22:50 и другой её никто не увидит. Туман 32 м: дальше
	# ставить нечего, и на снимках это должно быть видно.
	{"name": "22-улица-от-ворот", "pos": [0.0, 0.0, -1.0], "yaw": 0.0, "pitch": 0.02,
		"night": 1.0, "lamps": []},
	{"name": "23-улица-на-запад", "pos": [-2.0, 0.0, -3.4], "yaw": PI * 1.5, "pitch": 0.04,
		"night": 1.0, "lamps": []},
	{"name": "24-улица-на-восток", "pos": [2.0, 0.0, -3.4], "yaw": PI * 0.5, "pitch": 0.04,
		"night": 1.0, "lamps": []},
	{"name": "25-окно-наблюдателя", "pos": [5.6, 0.0, -3.6], "yaw": 0.0, "pitch": 0.10,
		"night": 1.0, "lamps": []},
	{"name": "26-дом-аркадия", "pos": [15.6, 0.0, -3.6], "yaw": 0.0, "pitch": 0.08,
		"night": 1.0, "lamps": []},
	{"name": "27-заколоченный-дом", "pos": [-5.5, 0.0, -3.6], "yaw": 0.0, "pitch": 0.08,
		"night": 1.0, "lamps": []},
	{"name": "28-правление", "pos": [-30.0, 0.0, -4.2], "yaw": 0.0, "pitch": 0.06,
		"night": 1.0, "lamps": ["office", "office-porch"]},
	{"name": "29-бочка-у-столба", "pos": [-13.0, 0.0, -0.6], "yaw": PI * 1.1, "pitch": -0.20,
		"night": 1.0, "lamps": []},
	# Тот же вид в сумерках. Ночью улица почти чёрная — это и есть замысел,
	# но принимать по такому кадру геометрию нельзя, а по этому можно.
	{"name": "30-улица-в-сумерках", "pos": [0.0, 0.0, -1.0], "yaw": 0.0, "pitch": 0.05,
		"night": 0.10, "lamps": []},

	# Фаза 11: участок с фотографии. Восемь снимков в сумерках (night 0.10) —
	# принимается ГЕОМЕТРИЯ и цвет, а ночью не видно ни того, ни другого.
	# Девятый и десятый ночные: дверь правления чинилась ровно ради ночи,
	# и мерить её надо в темноте, с тех же тридцати одного метра.
	{"name": "31-баня-снаружи", "pos": [5.0, 0.0, 17.6], "yaw": PI, "pitch": 0.10,
		"night": 0.10, "lamps": []},
	{"name": "32-баня-предбанник", "pos": [5.0, 0.12, 22.2], "yaw": PI, "pitch": 0.02,
		"night": 0.60, "lamps": ["banya"]},
	{"name": "33-баня-парная", "pos": [4.9, 0.12, 24.4], "yaw": PI * 0.5, "pitch": 0.06,
		"night": 0.60, "lamps": ["banya"]},
	{"name": "34-погреб-от-ворот", "pos": [-2.0, 0.0, 2.4], "yaw": PI * 0.5, "pitch": 0.06,
		"night": 0.10, "lamps": []},
	{"name": "35-дорожка-от-калитки", "pos": [3.0, 0.0, 0.4], "yaw": PI, "pitch": -0.14,
		"night": 0.10, "lamps": []},
	{"name": "36-забор-со-стороны-улицы", "pos": [-4.0, 0.0, -2.2], "yaw": PI, "pitch": 0.04,
		"night": 0.10, "lamps": []},
	{"name": "37-лес-за-задним-забором", "pos": [0.0, 0.0, 26.0], "yaw": PI, "pitch": 0.12,
		"night": 0.10, "lamps": []},
	{"name": "38-дом-с-огорода-перекрашен", "pos": [0.5, 0.0, 23.0], "yaw": 0.0,
		"pitch": 0.20, "night": 0.10, "lamps": []},
	{"name": "39-дверь-правления-вблизи", "pos": [-30.0, 0.0, -5.6], "yaw": 0.0, "pitch": 0.10,
		"night": 1.0, "lamps": ["office-porch"]},
	{"name": "40-дверь-правления-с-десяти-шагов", "pos": [-30.0, 0.0, -0.9], "yaw": 0.0,
		"pitch": 0.06, "night": 1.0, "lamps": ["office-porch"]},

	# Фаза 12: деревня. Половина в сумерках (принимается геометрия новых мест),
	# половина ночью с лампами — сельпо и остановка сделаны ради ночи, и мерить
	# их днём бессмысленно. Все точки помечены village: перед ними вещи главы
	# ставятся на места руками, см. _stage_village().
	{"name": "41-остановка", "pos": [-42.6, 0.0, -3.2], "yaw": 0.0, "pitch": 0.04,
		"night": 1.0, "lamps": ["stop"], "village": true},
	{"name": "42-остановка-в-сумерках", "pos": [-41.0, 0.0, -2.6], "yaw": PI * 0.12,
		"pitch": 0.06, "night": 0.10, "lamps": [], "village": true},
	{"name": "43-трактор", "pos": [-36.4, 0.0, -4.0], "yaw": 0.0, "pitch": 0.06,
		"night": 0.10, "lamps": [], "village": true},
	{"name": "44-колодец", "pos": [-24.0, 0.0, -4.4], "yaw": 0.0, "pitch": 0.02,
		"night": 0.10, "lamps": [], "village": true},
	{"name": "45-колодец-ночью", "pos": [-24.0, 0.0, -5.4], "yaw": 0.0, "pitch": 0.06,
		"night": 1.0, "lamps": [], "village": true},
	{"name": "46-будка", "pos": [22.5, 0.0, -5.2], "yaw": 0.0, "pitch": 0.06,
		"night": 1.0, "lamps": ["booth"], "village": true},
	{"name": "47-сельпо-снаружи", "pos": [29.0, 0.0, -3.8], "yaw": 0.0, "pitch": 0.06,
		"night": 1.0, "lamps": ["shop-win"], "village": true},
	{"name": "48-сельпо-снаружи-в-сумерках", "pos": [29.0, 0.0, -3.0], "yaw": 0.0,
		"pitch": 0.08, "night": 0.10, "lamps": [], "village": true},
	{"name": "49-сельпо-внутри", "pos": [28.9, 0.06, -7.9], "yaw": 0.0, "pitch": 0.02,
		"night": 1.0, "lamps": ["shop-in"], "village": true},
	{"name": "50-сельпо-прилавок", "pos": [28.6, 0.06, -10.9], "yaw": PI, "pitch": -0.10,
		"night": 1.0, "lamps": ["shop-in"], "village": true},
	{"name": "51-заколоченный-снаружи", "pos": [-5.5, 0.0, -4.4], "yaw": 0.0, "pitch": 0.08,
		"night": 1.0, "lamps": [], "village": true},
	{"name": "52-заколоченный-внутри", "pos": [-5.5, 0.12, -8.2], "yaw": PI * 0.244,
		"pitch": 0.0, "night": 0.10, "lamps": [], "village": true},
	{"name": "53-щель-и-штатив", "pos": [-4.9, 0.12, -9.6], "yaw": PI * 1.22, "pitch": -0.21,
		"night": 0.10, "lamps": [], "village": true},
	{"name": "54-погост", "pos": [40.0, 0.0, -8.2], "yaw": 0.0, "pitch": 0.02,
		"night": 0.10, "lamps": [], "village": true},
	{"name": "55-вырытая-яма", "pos": [41.35, 0.0, -6.9], "yaw": 0.0, "pitch": -0.30,
		"night": 1.0, "lamps": [], "village": true},
	{"name": "56-улица-с-западного-конца", "pos": [-44.0, 0.0, -3.2], "yaw": PI * 1.5,
		"pitch": 0.02, "night": 0.10, "lamps": [], "village": true},
	{"name": "57-улица-с-восточного-конца", "pos": [44.0, 0.0, -3.2], "yaw": PI * 0.5,
		"pitch": 0.02, "night": 0.10, "lamps": [], "village": true},
	{"name": "58-машина-с-капотом", "pos": [-2.6, 0.0, -4.4], "yaw": PI * 1.29, "pitch": -0.12,
		"night": 1.0, "lamps": [], "village": true},
	{"name": "59-кухня-тёрка-и-миска", "pos": [0.4, 0.45, 10.9], "yaw": PI * 0.412,
		"pitch": -0.45, "night": 0.55, "lamps": ["kitchen"]},
	{"name": "60-кухня-телефон-на-тумбе", "pos": [0.1, 0.45, 10.3], "yaw": PI * 0.431,
		"pitch": -0.37, "night": 0.55, "lamps": ["kitchen"]},
	{"name": "61-сарай-вещи-на-верстаке", "pos": [6.6, 0.0, 12.2], "yaw": PI * 1.713,
		"pitch": -0.48, "night": 0.60, "lamps": ["shed"], "shed": true},

	# ФАЗА 13. Одиннадцать снимков, и первые четыре — это три бага, которые
	# Пётр увидел глазами. Их и надо смотреть первыми: форточку с лестницы,
	# конец улицы, соседей от восточного забора и забор у крыльца Аркадия.
	{"name": "62-лестница-и-форточка", "pos": [-4.9, 1.34, 11.3], "yaw": PI * 0.94,
		"pitch": 0.06, "night": 0.55, "lamps": ["hall", "landing"]},
	{"name": "63-коридор-к-форточке", "pos": [-4.4, 2.05, 13.9], "yaw": PI * 0.62,
		"pitch": 0.02, "night": 0.55, "lamps": ["landing"]},
	# Улица и деревня СНАРУЖИ снимаются в сумерках (night 0.10), а не в ночь.
	# Это правило фазы 12, и первый прогон фазы 13 напомнил, почему оно есть:
	# при night 1.0 и тумане 32 м в кадре чёрный прямоугольник, по которому
	# нельзя принять ни опушку, ни забор, ни дом. Игра играется ночью,
	# приёмка геометрии — нет.
	# Просвет между домом наблюдателя (кончается на x 10) и домом Аркадия
	# (начинается на 12): единственное место линии, откуда опушка видна
	# в упор и не закрыта ничем.
	{"name": "64-край-улицы-опушка", "pos": [11.0, 0.0, -3.0], "yaw": 0.0,
		"pitch": 0.12, "night": 0.10, "lamps": [], "village": true},
	{"name": "65-соседи-от-восточного-забора", "pos": [9.9, 0.0, 8.6], "yaw": PI * 1.5,
		"pitch": 0.14, "night": 0.10, "lamps": []},
	# Камера стоит В ПРОЁМЕ забора и смотрит на крыльцо: если прожилины
	# по-прежнему шли бы через дверь, они пересекли бы кадр ровно посередине.
	{"name": "66-забор-у-крыльца-аркадия", "pos": [15.9, 0.0, -5.4], "yaw": 0.0,
		"pitch": -0.06, "night": 0.10, "lamps": [], "village": true},
	{"name": "67-забор-у-крыльца-крикуна", "pos": [-16.0, 0.0, -5.4], "yaw": 0.0,
		"pitch": -0.06, "night": 0.10, "lamps": [], "village": true},
	# Участок: яблони и растопленная баня. Точка 68 наведена на два дерева
	# в дальнем северо-западном углу — с середины огорода их видно оба.
	{"name": "68-яблони-за-огородом", "pos": [8.90, 0.0, 29.20], "yaw": 0.0,
		"pitch": 0.16, "night": 0.10, "lamps": []},
	{"name": "69-баня-и-поленница", "pos": [1.2, 0.0, 21.6], "yaw": PI * 1.62,
		"pitch": 0.04, "night": 0.60, "lamps": ["banya"]},
	# Красный дом снаружи и изнутри. Внутри горит только холодильник — ровно
	# то, ради чего лампа 'redhouse' и заведена; точка стоит у двери и смотрит
	# в дальний угол, где диван в плёнке и нераспакованные коробки.
	{"name": "70-красный-дом-снаружи", "pos": [0.9, 0.0, -4.2], "yaw": 0.0,
		"pitch": 0.06, "night": 0.10, "lamps": [], "village": true},
	{"name": "71-красный-дом-внутри", "pos": [2.60, 0.14, -8.30], "yaw": PI * 0.203,
		"pitch": -0.02, "night": 0.10, "lamps": ["redhouse"], "village": true},
	# Линия: остановка со сложенным расписанием, кабина трактора, колодец
	# с поднятым ведром. Остановка снимается С ДОРОГИ, а не изнутри навеса:
	# в первом прогоне камера стояла в тридцати сантиметрах от щита.
	{"name": "72-остановка-расписание", "pos": [-42.7, 0.0, -4.4], "yaw": 0.0,
		"pitch": 0.02, "night": 1.0, "lamps": ["stop"], "village": true},
	{"name": "73-кабина-трактора", "pos": [-35.2, 0.0, -9.9], "yaw": PI * 1.5,
		"pitch": -0.10, "night": 0.10, "lamps": [], "village": true},
	{"name": "74-колодец-с-ведром", "pos": [-22.2, 0.0, -8.0], "yaw": PI * 0.339,
		"pitch": -0.04, "night": 0.10, "lamps": [], "village": true},

	# ФАЗА 14. Восемнадцать снимков: карта выросла вдвое, и принимать её
	# надо не по одному кадру на участок, а по местам, где игрок реально
	# стоит. Всё, что под открытым небом, снимается в сумерках (night 0.10)
	# — то же правило фаз 12-13 и по той же причине: при night 1.0 и тумане
	# 32 м на месте околицы чёрный прямоугольник.
	#
	# Сеть дорог: устье переулка с центральной, сам переулок, восточный
	# проулок и вторая линия. Первые три — единственный ответ на вопрос
	# «видно ли с дороги, что отсюда есть выезд»; если не видно, весь новый
	# мир для игрока не существует.
	{"name": "75-устье-западного-переулка", "pos": [-28.6, 0.0, -12.4], "yaw": 0.0,
		"pitch": 0.06, "night": 0.10, "lamps": ["lane-pole"], "outskirts": true},
	{"name": "76-западный-переулок", "pos": [-28.6, 0.0, -15.2], "yaw": 0.0,
		"pitch": 0.04, "night": 0.10, "lamps": ["lane-pole"], "outskirts": true},
	{"name": "77-восточный-проулок", "pos": [34.6, 0.0, -14.4], "yaw": 0.0,
		"pitch": 0.02, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "78-вторая-линия", "pos": [-18.0, 0.0, -21.0], "yaw": PI * 0.5,
		"pitch": 0.04, "night": 0.10, "lamps": [], "outskirts": true},

	# Семь участков околицы, с запада на восток.
	# Камера стоит на второй линии, а не во дворе: с трёх метров в кадре был
	# один бок навеса, и ни амбара, ни силоса, ни того, как они стоят друг
	# к другу. Девять метров — то расстояние, с которого двор читается двором.
	{"name": "79-двор-фермы", "pos": [-26.0, 0.0, -21.0], "yaw": 0.89,
		"pitch": 0.10, "night": 0.10, "lamps": ["barn"], "outskirts": true},
	# Внутри амбара камера смотрит В СТОЙЛА, а не в ворота: принимать надо
	# перегородки и гвоздь с ключом, ради которых он и стал помещением.
	{"name": "80-амбар-изнутри", "pos": [-36.5, 0.0, -27.2], "yaw": TAU - 0.46,
		"pitch": -0.02, "night": 0.10, "lamps": ["barn"], "outskirts": true},
	{"name": "81-пруд-с-мостками", "pos": [-23.0, 0.0, -25.2], "yaw": 0.0,
		"pitch": -0.06, "night": 0.10, "lamps": [], "outskirts": true},
	# Ветряк стоит на кровле будки и уходит вверх на девять метров: без
	# задранного pitch в кадр попадает один кирпич.
	{"name": "82-водокачка", "pos": [-15.0, 0.0, -24.8], "yaw": 0.0,
		"pitch": 0.24, "night": 0.10, "lamps": ["pump"], "outskirts": true},
	{"name": "83-куриный-двор", "pos": [-6.0, 0.0, -24.6], "yaw": 0.53,
		"pitch": 0.06, "night": 0.10, "lamps": ["hen-yard"], "outskirts": true},
	{"name": "84-клуб-снаружи", "pos": [9.1, 0.0, -23.6], "yaw": 0.0,
		"pitch": 0.14, "night": 0.10, "lamps": ["club-win"], "outskirts": true},
	{"name": "85-клуб-в-зале", "pos": [9.1, 0.0, -27.6], "yaw": 0.0,
		"pitch": 0.0, "night": 0.10, "lamps": ["club-win"], "outskirts": true},
	{"name": "86-свалка-с-остовом", "pos": [21.0, 0.0, -25.2], "yaw": TAU - 0.12,
		"pitch": -0.02, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "87-поле-с-пугалом", "pos": [33.0, 0.0, -26.2], "yaw": 0.0,
		"pitch": 0.04, "night": 0.10, "lamps": [], "outskirts": true},

	# Цепочка полива на участке: с чего началась и чем кончилась.
	{"name": "88-бочка-и-лейка", "pos": [-4.9, 0.0, 17.7], "yaw": PI,
		"pitch": -0.20, "night": 0.10, "lamps": []},
	{"name": "89-теплица-с-рассадой", "pos": [-7.0, 0.0, 23.2], "yaw": 0.0,
		"pitch": -0.04, "night": 0.10, "lamps": []},
	{"name": "90-стремянка-на-чердак-бани", "pos": [7.9, 0.0, 21.6], "yaw": PI * 0.5,
		"pitch": 0.10, "night": 0.10, "lamps": []},

	# Красный дом в два этажа и детская наверху. Снаружи — с дороги, чтобы
	# в кадр попал весь второй ряд окон; внутри — с верхней площадки марша
	# на детский стол, где лежит улика и стоит скример №2.
	{"name": "91-красный-дом-в-два-этажа", "pos": [0.9, 0.0, -3.4], "yaw": 0.0,
		"pitch": 0.24, "night": 0.10, "lamps": ["redhouse-up"], "village": true},
	{"name": "92-детская-второго-этажа", "pos": [2.00, 2.64, -12.40], "yaw": 2.63,
		"pitch": -0.04, "night": 0.10, "lamps": ["redhouse-up"], "village": true},

	# ФАЗА 15. Окно изнутри — приёмка форточки: в проёме обязан читаться ОДИН
	# предмет, а не три. Камера стоит в двух метрах от стены и смотрит в упор,
	# потому что спор створки с переплётом виден только вплотную.
	{"name": "93-окно-прихожей-изнутри", "pos": [-2.60, 0.45, 13.60], "yaw": PI * 0.5,
		"pitch": 0.0, "night": 0.55, "lamps": ["hall"]},
	{"name": "94-окно-тётиной-изнутри", "pos": [2.20, 0.45, 8.40], "yaw": PI * 1.5,
		"pitch": 0.0, "night": 0.55, "lamps": ["kitchen"]},
	{"name": "95-окно-тётиной-снаружи", "pos": [7.00, 0.0, 8.40], "yaw": PI * 1.5,
		"pitch": 0.12, "night": 0.10, "lamps": ["kitchen"]},

	# ФАЗА 15, финал. Все три — в глухую ночь, потому что играются они
	# в 01:05 и другими их никто не увидит; здесь темнота и есть предмет
	# приёмки, а не помеха ей.
	#
	# Крыльцо в грозу: дождь идёт полосами в кадре, а по деревне ни одного
	# окна. Камера смотрит на север, к воротам, — то есть туда, куда игрок
	# сейчас пойдёт.
	{"name": "96-крыльцо-в-грозу", "pos": [-2.30, 0.45, 5.90], "yaw": 0.0,
		"pitch": 0.02, "night": 1.0, "lamps": [], "final": true},
	# Ворота со скримером: двойник стоит по ту сторону створки, вплотную.
	# Два метра, а не полтора: с полутора в кадре один ватник без головы.
	# night 0.35, а не 1.0: в глухой темноте фигура в ватнике — чёрное на чёрном,
	# и принимать по такому снимку нечего. Правило то же, по которому улица
	# фазы 12 снимается в сумерках, а играется ночью.
	{"name": "97-ворота-со-скримером", "pos": [0.0, 0.0, 2.00], "yaw": 0.0,
		"pitch": 0.06, "night": 0.35, "lamps": ["porch"], "final": true, "echo": true},
	# Погоня: игрок у машины, дед в семи метрах, уже за воротами.
	# Камера стоит ЗА «Шестёркой», а не в ней: точка car-drive лежит внутри
	# кузова, и оттуда весь нижний кадр занимает капот изнутри.
	{"name": "98-погоня-у-машины", "pos": [1.10, 0.0, -5.60], "yaw": PI,
		"pitch": 0.04, "night": 0.20, "lamps": ["porch"], "final": true, "chase": true},

	# ФАЗА 15, часть 2. Линия Вали. Все в сумерках (night 0.10) по правилу
	# фазы 12: играется это ночью, а принимать геометрию в темноте нечем.
	# valya — постановка её собственных вещей (см. _stage_valya).
	{"name": "99-валя-у-ограды", "pos": [3.45, 0.0, -3.60], "yaw": 0.0,
		"pitch": 0.06, "night": 0.10, "lamps": ["redhouse", "redhouse-up"],
		"village": true, "valya": true},
	{"name": "100-камни-у-ограды", "pos": [0.60, 0.0, -3.40], "yaw": 0.0,
		"pitch": -0.28, "night": 0.10, "lamps": ["redhouse"],
		"village": true, "valya": true},
	# Три полосы травы и тропа под третьей. Камера на второй линии, лицом
	# на север — то есть туда, куда тропа уводит.
	{"name": "101-полосы-за-домами", "pos": [0.90, 0.0, -17.60], "yaw": 0.0,
		"pitch": 0.02, "night": 0.10, "lamps": [], "outskirts": true, "valya": true},
	{"name": "102-кладбище-за-домами", "pos": [0.90, 0.0, -25.40], "yaw": 0.0,
		"pitch": -0.06, "night": 0.10, "lamps": [], "outskirts": true, "valya": true},
	{"name": "103-озеро-с-сетью", "pos": [-21.60, 0.0, -28.20], "yaw": 0.0,
		"pitch": -0.02, "night": 0.10, "lamps": [], "outskirts": true, "valya": true},
	{"name": "104-указатель-на-ферму", "pos": [-25.90, 0.0, -11.60], "yaw": 0.0,
		"pitch": 0.04, "night": 0.10, "lamps": [], "outskirts": true, "valya": true},
	# Баня в пару: надпись на стекле изнутри. Точка — в парилке, лицом
	# на западное окно.
	{"name": "105-баня-в-пару", "pos": [4.60, 0.12, 22.30], "yaw": PI * 0.5,
		"pitch": 0.0, "night": 0.10, "lamps": ["banya"]},
	# ФАЗА 16. Кран у восточной стены бани: до этой фазы у точки banya-tap не
	# было ни одного полигона, и игрок не мог набрать воду. Снимок — приёмка
	# того, что кран видно: стояк, носик, барашек, мокрое пятно и таз.
	{"name": "106-кран-у-бани", "pos": [9.40, 0.0, 22.80], "yaw": PI * 0.44,
		"pitch": -0.40, "night": 0.10, "lamps": []},
	# И с северной дорожки — та точка, с которой игрок к бане и приходит:
	# отсюда за угол должна уходить мокрая полоса, иначе обходить сруб
	# по-прежнему незачем.
	{"name": "107-подход-к-бане-с-дорожки", "pos": [6.20, 0.0, 19.40], "yaw": 3.73,
		"pitch": -0.25, "night": 0.10, "lamps": []},
	# ФАЗА 16. Вторая линия перестала быть газоном с призраками: у пяти домов
	# site.json NEIGHBOURS появились тело, лицо, крыльцо и забор.
	{"name": "108-вторая-линия-на-запад", "pos": [6.00, 0.0, -18.00], "yaw": PI * 0.5,
		"pitch": 0.04, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "109-дом-второй-линии", "pos": [10.00, 0.0, -17.40], "yaw": 0.0,
		"pitch": 0.14, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "110-вторая-линия-на-восток", "pos": [6.00, 0.0, -18.00], "yaw": PI * 1.5,
		"pitch": 0.04, "night": 0.10, "lamps": [], "outskirts": true},
	# ФАЗА 16, СНТ за околицей. Все точки — в ночь: район играется в главе
	# ДЕРЕВНЯ, и другим его никто не увидит. Плюс две в сумерках на геометрию.
	{"name": "113-снт-въезд", "pos": [36.80, 0.0, -36.60], "yaw": 0.0,
		"pitch": 0.06, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "114-снт-первый-проезд", "pos": [36.80, 0.0, -38.30], "yaw": PI * 0.5,
		"pitch": 0.02, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "115-снт-озеро", "pos": [-4.00, 0.0, -53.60], "yaw": PI,
		"pitch": -0.04, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "116-снт-участок", "pos": [19.00, 0.0, -38.60], "yaw": 0.0,
		"pitch": 0.10, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "117-снт-тупик", "pos": [7.10, 0.0, -65.20], "yaw": 0.0,
		"pitch": 0.04, "night": 1.0, "lamps": ["snt-booth"], "outskirts": true},
	{"name": "118-снт-второй-проезд-ночью", "pos": [4.00, 0.0, -53.80], "yaw": PI * 0.5,
		"pitch": 0.02, "night": 1.0, "lamps": ["snt-lane"], "outskirts": true},
	# ФАЗА 17. Третий проём в северном борте улицы и дорога, которую он
	# открывает: покос, тропа, холм. Геометрия — в сумерках (то же правило
	# фаз 12-16), а один кадр в ночь, ради нового столба: маршрут стал
	# обязательным, и ночью он обязан ЧИТАТЬСЯ, а не только существовать.
	#
	# 119 — та самая щель между домом наблюдателя (кончается на x 10) и домом
	# Аркадия (начинается на 12), с дороги. Вопрос кадра ровно один: видно ли
	# с улицы, что отсюда есть выход. Если не видно, весь маршрут к покосу
	# остаётся там же, где был две фазы, — в данных.
	{"name": "119-третий-проём-с-улицы", "pos": [11.00, 0.0, -12.00], "yaw": 0.0,
		"pitch": 0.06, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "120-третий-проём-со-второй-линии", "pos": [11.00, 0.0, -18.20], "yaw": PI,
		"pitch": 0.06, "night": 0.10, "lamps": [], "outskirts": true},
	# С устья проёма — на запад, вдоль второй линии, в сторону оси Вали.
	# В ночь и с новым столбом: до фазы 17 на 78 м дороги горел один
	# источник, и до оси покоса от него было 29.5 м.
	{"name": "121-вторая-линия-от-проёма-ночью", "pos": [12.50, 0.0, -17.20],
		"yaw": PI * 0.5, "pitch": 0.02, "night": 1.0,
		"lamps": ["lane-pole", "lane-pole-2"], "outskirts": true},
	# Полосы покоса от второй линии и тропа с холмом за третьей полосой.
	# Тропа раздвинута с обоих концов: до фазы 17 она не смыкалась ни с
	# травой, ни с насыпью, и игрок скашивал третью полосу, не видя, куда идти.
	{"name": "122-полосы-покоса", "pos": [0.90, 0.0, -17.60], "yaw": 0.0,
		"pitch": -0.06, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "123-тропа-и-холм", "pos": [0.90, 0.0, -24.00], "yaw": 0.0,
		"pitch": -0.02, "night": 0.10, "lamps": [], "outskirts": true},

	# ФАЗА 18. Семь кадров приёмки: два проезда сквозь дома второй линии,
	# амбар и водокачка С ДОРОГИ (то, ради чего проезды и прорезаны), два
	# новых проёма северного борта и лопата с жестянкой у холма. Все
	# в сумерках (night 0.10) по правилу фазы 12: играется ночью, а принимать
	# геометрию в темноте нечем. Лампы новых проездов — в списке: у них своя
	# работа, и без них половина смысла кадра пропадает.
	#
	# Камера стоит на ДОРОГЕ ВТОРОЙ ЛИНИИ (z -17.6) и смотрит на север —
	# то есть ровно оттуда и туда, откуда игрок и увидит подворотню.
	{"name": "125-проезд-к-амбару", "pos": [-36.30, 0.0, -17.60], "yaw": 0.0,
		"pitch": 0.02, "night": 0.10, "lamps": ["barn-gate", "barn"],
		"outskirts": true},
	{"name": "126-амбар-с-дороги", "pos": [-36.30, 0.0, -22.00], "yaw": 0.0,
		"pitch": 0.02, "night": 0.10, "lamps": ["barn-gate", "barn"],
		"outskirts": true},
	{"name": "127-проезд-к-водокачке", "pos": [-15.00, 0.0, -17.60], "yaw": 0.0,
		"pitch": 0.02, "night": 0.10, "lamps": ["pump-lane"], "outskirts": true},
	{"name": "128-водокачка-с-дороги", "pos": [-12.00, 0.0, -26.00], "yaw": 0.79,
		"pitch": 0.52, "night": 0.10, "lamps": ["pump-lane", "pump"],
		"outskirts": true},
	# Два новых проёма северного борта, с обочины первой линии на север.
	# Западный — самый широкий (x [-35.0,-24.6], бывший переулок слился
	# с двумя соседними просветами); восточный — новый, между домом Аркадия
	# и будкой. По ним и видно, стена там теперь или лес.
	# Точка стоит на оси западного переулка (x -28.6, та же, что у
	# WEST_LANE_WALK), а НЕ на -30.0: там стоит правление, и камера была
	# внутри его стен — кадр выходил чёрным прямоугольником.
	{"name": "129-проём-западный", "pos": [-28.60, 0.0, -12.80], "yaw": 0.0,
		"pitch": 0.02, "night": 0.10, "lamps": ["lane-pole"], "outskirts": true},
	{"name": "130-проём-у-будки", "pos": [22.00, 0.0, -12.00], "yaw": 0.0,
		"pitch": 0.02, "night": 0.10, "lamps": ["booth"], "outskirts": true},
	# Лопата у насыпи и жестянка у ямы: до фазы 18 у обеих не было ни одного
	# полигона. Кадр снимается ДО раскопки — с лопатой и целым холмом.
	{"name": "131-лопата-у-холма", "pos": [1.50, 0.0, -24.60], "yaw": 0.0,
		"pitch": -0.14, "night": 0.10, "lamps": [], "outskirts": true,
		"valya": true},

	# Вьюмодели снимаются одним блоком с одинаковым миром и светом: так
	# сравниваются силуэт, масштаб и посадка в кадре, а не фон за предметом.
	# Acceptance close-ups for the new garden -> banya -> cellar -> bath-loft chain.
	# They deliberately precede held-item and actor probes: the actor block freezes
	# main._process(), while these frames need the ordinary world resync path.
	{"name": "accept-story-garden-before", "pos": [-0.60, 0.0, 27.10], "yaw": 0.0,
		"pitch": -0.30, "night": 0.72, "lamps": [], "story_stage": "garden-before"},
	{"name": "accept-story-garden-after", "pos": [-0.60, 0.0, 27.10], "yaw": 0.0,
		"pitch": -0.30, "night": 0.72, "lamps": [], "story_stage": "garden-after"},
	{"name": "accept-story-banya-warning", "pos": [1.65, 0.12, 22.30], "yaw": -PI * 0.5,
		"pitch": -0.18, "night": 0.86, "lamps": ["banya"], "story_stage": "banya-warning"},
	{"name": "accept-story-banya-key", "pos": [5.10, 0.0, 22.35], "yaw": 0.0,
		"pitch": -0.05, "night": 0.86, "lamps": ["banya"], "story_stage": "banya-key"},
	{"name": "accept-story-cellar-lantern", "pos": [-7.20, 0.10, 2.55], "yaw": 2.20,
		"pitch": -0.12, "night": 0.95, "lamps": ["lantern"], "story_stage": "cellar-lantern"},
	{"name": "accept-story-bathloft-ready", "pos": [9.15, 0.0, 23.90], "yaw": PI * 0.5,
		"pitch": 0.30, "night": 0.95, "lamps": ["lantern"], "story_stage": "bathloft-ready"},
	{"name": "accept-story-bathloft-attic", "pos": [6.10, 1.36, 24.00], "yaw": 2.10,
		"pitch": -0.34, "night": 0.95, "lamps": ["lantern"],
		"story_stage": "bathloft-attic", "forced_crouch": true},
	# Фаза 20: деревья/яблони, обязательная мельница и водная система.
	{"name": "accept-world-orchard-variety", "pos": [-1.50, 0.0, 25.00], "yaw": 1.95,
		"pitch": 0.12, "night": 0.22, "lamps": []},
	{"name": "accept-world-orchard-apples", "pos": [-2.80, 0.0, 26.80], "yaw": 2.21,
		"pitch": 0.08, "night": 0.16, "lamps": []},
	{"name": "accept-world-house-canopy-clearance", "pos": [-9.10, 0.0, 13.20], "yaw": -1.08,
		"pitch": 0.18, "night": 0.22, "lamps": []},
	{"name": "accept-world-old-windmill", "pos": [16.00, 0.0, -24.00], "yaw": -0.79,
		"pitch": 0.22, "night": 0.22, "lamps": [], "outskirts": true},
	{"name": "accept-water-story-pond", "pos": [-23.00, 0.0, -22.10], "yaw": 0.0,
		"pitch": -0.20, "night": 0.22, "lamps": [], "outskirts": true, "valya": true},
	{"name": "accept-water-snt-lake-dock", "pos": [-0.45, 0.22, -39.70], "yaw": 0.0,
		"pitch": -0.16, "night": 0.22, "lamps": [], "outskirts": true},
	{"name": "accept-water-river-culvert", "pos": [-14.80, 0.0, -54.60], "yaw": 0.95,
		"pitch": -0.24, "night": 0.18, "lamps": [], "outskirts": true},
	{"name": "accept-water-river-channel", "pos": [-15.40, 0.10, -58.30], "yaw": 2.16,
		"pitch": -0.28, "night": 0.18, "lamps": [], "outskirts": true},

	# Phase 21 acceptance set. These fixed cameras cover every intentionally
	# changed location without relying on story AI or a manually positioned save.
	{"name": "p21-01-tonya-doorway", "pos": [0.60, 3.30, 13.05], "yaw": PI,
		"pitch": 0.02, "night": 0.48, "lamps": ["vitya", "landing"]},
	{"name": "p21-02-tonya-room", "pos": [0.62, 3.30, 14.05], "yaw": PI * 0.78,
		"pitch": -0.12, "night": 0.48, "lamps": ["vitya", "landing"]},
	{"name": "p21-03-car-keys", "pos": [3.00, -1.55, 14.25], "yaw": PI,
		"pitch": -0.55, "night": 0.72, "lamps": ["lantern"], "story_stage": "cellar-keys"},
	{"name": "p21-04-shop-key", "pos": [16.30, 0.0, -5.95], "yaw": -0.19,
		"pitch": -0.18, "night": 0.22, "lamps": ["lantern"], "village": true,
		"story_stage": "shop-key-shot"},
	{"name": "p21-05-shovel", "pos": [1.50, 0.0, -24.60], "yaw": 0.0,
		"pitch": -0.14, "night": 0.18, "lamps": [], "outskirts": true, "valya": true,
		"story_stage": "grave-shovel-shot"},
	{"name": "p21-06-first-line-trees", "pos": [-19.50, 0.0, -20.50], "yaw": PI,
		"pitch": 0.13, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "p21-06b-first-line-trees", "pos": [18.00, 0.0, -20.50], "yaw": PI,
		"pitch": 0.13, "night": 0.10, "lamps": [], "outskirts": true},
	{"name": "p21-07-orchard-apples", "pos": [-2.80, 0.0, 26.80], "yaw": 2.21,
		"pitch": 0.08, "night": 0.16, "lamps": []},
	{"name": "p21-08-farm-sign", "pos": [-25.90, 0.0, -11.80], "yaw": 0.0,
		"pitch": 0.05, "night": 0.22, "lamps": ["lantern"], "outskirts": true,
		"valya": true, "story_stage": "farm-sign-shot"},
	{"name": "p21-09-pond-shallows", "pos": [-23.00, 0.0, -22.10], "yaw": 0.0,
		"pitch": -0.20, "night": 0.22, "lamps": [], "outskirts": true, "valya": true},
	{"name": "p21-10-windmill-overview", "pos": [15.50, 0.0, -23.00], "yaw": -0.74,
		"pitch": 0.25, "night": 0.22, "lamps": [], "outskirts": true},
	{"name": "p21-11-windmill-ground", "pos": [19.28, 0.0, -23.80], "yaw": 0.0,
		"pitch": 0.12, "night": 0.22, "lamps": [], "outskirts": true},
	{"name": "p21-12-windmill-lower", "pos": [18.80, 4.10, -25.50], "yaw": -0.56,
		"pitch": -0.06, "night": 0.22, "lamps": [], "outskirts": true},
	{"name": "p21-13-windmill-upper", "pos": [25.00, 8.30, -29.00], "yaw": PI * 0.5,
		"pitch": -0.10, "night": 0.22, "lamps": [], "outskirts": true},
	{"name": "p21-14-open-wicket", "pos": [3.00, 0.0, -2.20], "yaw": PI,
		"pitch": 0.02, "night": 1.0, "lamps": [], "final": true},
	{"name": "accept-photo-grandson", "pos": [2.72, 0.0, 13.20], "yaw": PI * 1.5,
		"pitch": -0.02, "night": 0.42, "lamps": ["living"], "story_stage": "photo"},

	# One fixed exterior view for all nine monotonic story-light targets.
	{"name": "accept-light-00-arrival", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.04, "night": 0.00, "lamps": []},
	{"name": "accept-light-12-lights-on", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.04, "night": 0.12, "lamps": ["porch"]},
	{"name": "accept-light-24-power-restored", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.04, "night": 0.24, "lamps": ["porch"]},
	{"name": "accept-light-42-loft", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.04, "night": 0.42, "lamps": ["porch"]},
	{"name": "accept-light-58-tapes", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.04, "night": 0.58, "lamps": ["porch"]},
	{"name": "accept-light-72-street", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.04, "night": 0.72, "lamps": ["porch"]},
	{"name": "accept-light-86-blackout", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.04, "night": 0.86, "lamps": []},
	{"name": "accept-light-95-village", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.04, "night": 0.95, "lamps": []},
	{"name": "accept-light-100-gate", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.04, "night": 1.00, "lamps": []},

	{"name": "предмет-01-фонарик", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "flashlight"},
	{"name": "предмет-02-керосинка", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "lantern"},
	{"name": "предмет-03-сумка", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "bag"},
	{"name": "предмет-04-дрова", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "firewood"},
	{"name": "предмет-05-корзина-яблок", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "apple-basket"},
	{"name": "предмет-06-яд", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "poison"},
	{"name": "предмет-07-опрыскиватель", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "sprayer"},
	{"name": "предмет-08-канистра", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "canister"},
	{"name": "предмет-09-лейка", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "leyka"},
	{"name": "предмет-10-коса", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "scythe"},
	{"name": "предмет-11-лопата", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "tool-shovel"},
	{"name": "предмет-12-распределитель", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "distributor"},
	{"name": "предмет-13-лом", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.0, "night": 0.35, "lamps": ["porch"], "held": "crowbar"},

	# Лицевые render-пробы. Одинаковые камера, свет и фон отделяют ошибки
	# winding/UV/портрета от постановки сюжетных сцен; 3/4 проверяет, что фото
	# повторяет овал головы, а не читается отдельной плоской наклейкой.
	{"name": "beam-01-close-wall", "pos": [-3.0,0.45,13.8], "yaw": PI,
		"pitch": 0.0, "night": 1.0, "lamps": [], "held": "flashlight", "beam": true},
	{"name": "beam-02-floor", "pos": [-3.0,0.45,11.0], "yaw": PI,
		"pitch": -0.8, "night": 1.0, "lamps": [], "held": "flashlight", "beam": true},
	{"name": "beam-03-stairs", "pos": [-3.2,0.45,9.3], "yaw": PI * 0.92,
		"pitch": -0.16, "night": 1.0, "lamps": [], "held": "flashlight", "beam": true},
	{"name": "beam-04-water", "pos": [-23.0,0.0,-22.1], "yaw": 0.0,
		"pitch": -0.30, "night": 1.0, "lamps": [], "outskirts": true, "held": "flashlight", "beam": true},
	{"name": "beam-05-foliage", "pos": [-2.8,0.0,26.8], "yaw": 2.21,
		"pitch": 0.08, "night": 1.0, "lamps": [], "held": "flashlight", "beam": true},
	{"name": "actor-01-threat-front", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "threat"},
	{"name": "actor-02-threat-three-quarter", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "threat", "actor_angle": 0.45},
	{"name": "actor-03-echo-front", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "echo"},
	{"name": "actor-04-echo-three-quarter", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "echo", "actor_angle": 0.45},
	{"name": "actor-05-arkady-front", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "arkady"},
	{"name": "actor-06-arkady-three-quarter", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "arkady", "actor_angle": 0.45},
	{"name": "actor-07-shouter-front", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "shouter"},
	{"name": "actor-08-shouter-three-quarter", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "shouter", "actor_angle": 0.45},
	{"name": "actor-09-watcher-front", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "watcher"},
	{"name": "actor-10-watcher-three-quarter", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "watcher", "actor_angle": 0.45},
	{"name": "actor-11-valya-front", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "valya"},
	{"name": "actor-12-valya-three-quarter", "pos": [0.0, 0.0, 2.0], "yaw": PI,
		"pitch": 0.04, "night": 0.35, "lamps": ["porch"], "actor_probe": "valya", "actor_angle": 0.45},

	# Финальный отъезд — ровно четыре плана десятисекундной сцены. Они идут
	# последними: завершение сцены открывает титры и намеренно замораживает
	# обычный свет, поэтому никакая следующая приёмочная камера не должна
	# наследовать это финальное состояние.
	{"name": "accept-drive-01-стартер-и-выхлоп", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.0, "night": 1.0, "lamps": [], "final": true, "drive_at": 1.2},
	{"name": "accept-drive-02-витя-у-двери", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.0, "night": 1.0, "lamps": [], "final": true, "drive_at": 3.7},
	{"name": "accept-drive-03-боковой-трекинг", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.0, "night": 1.0, "lamps": [], "final": true, "drive_at": 6.5},
	{"name": "accept-drive-04-витя-остановился", "pos": [0.0, 0.0, -1.20], "yaw": 0.0,
		"pitch": 0.0, "night": 1.0, "lamps": [], "final": true, "drive_at": 9.1},
]


func _initialize() -> void:
	_run()


func _run() -> void:
	var dir := "res://../shots"
	var extra: PackedStringArray = []
	var render_override := ""
	var night_override := -1.0
	var capture_size := Vector2i.ZERO
	for argument: String in OS.get_cmdline_user_args():
		if argument.begins_with("--render="):
			render_override = argument.trim_prefix("--render=")
		elif argument.begins_with("--skin="):
			if argument.trim_prefix("--skin=") not in ["on", "off"]:
				printerr("shots: --skin принимает on или off")
				quit(2)
				return
		elif argument.begins_with("--capture-size="):
			var dimensions := argument.trim_prefix("--capture-size=").split("x")
			capture_size = Vector2i(int(dimensions[0]), int(dimensions[1]))
		elif argument.begins_with("--night="):
			night_override = clampf(float(argument.trim_prefix("--night=")), 0.0, 1.0)
		else:
			extra.append(argument)
	if extra.size() > 0:
		dir = extra[0]
	var out := ProjectSettings.globalize_path(dir) if dir.begins_with("res://") else dir
	DirAccess.make_dir_recursive_absolute(out)
	# Второй аргумент — экспозиция: подбор яркости прогоняется вилкой,
	# а не пересборкой render_chain.gd на каждое число.
	var exposure := -1.0
	if extra.size() > 1:
		exposure = float(extra[1])
	# Третий — один или несколько фильтров по имени через запятую. Так матрица
	# разрешений грузит мир один раз и снимает только контрольные точки прохода.
	var filters: PackedStringArray = []
	if extra.size() > 2:
		for part: String in String(extra[2]).split(",", false):
			var clean := part.strip_edges()
			if not clean.is_empty():
				filters.append(clean)

	if capture_size != Vector2i.ZERO:
		# Win32 ограничивает обычное окно рабочей областью монитора.
		# Минимальный размер и отсутствие рамки позволяют снять полный UI.
		root.borderless = true
		root.min_size = capture_size
		root.size = capture_size
		root.position = Vector2i.ZERO
		await process_frame
		if root.size != capture_size:
			printerr("shots: requested window %s, actual %s" % [capture_size, root.size])
			quit(3)
			return
	var scene: PackedScene = load("res://src/main.tscn")
	var main: Node = scene.instantiate()
	root.add_child(main)

	var waited := 0
	while main.get("chapters") == null and waited < BOOT_FRAMES:
		await process_frame
		waited += 1
	if main.get("chapters") == null:
		printerr("shots: боут не завершился за %d кадров" % BOOT_FRAMES)
		quit(1)
		return

	var ui: Overlays = main.get("ui")
	while bool(ui.get("_load").visible) and waited < BOOT_FRAMES:
		await process_frame
		waited += 1
	if bool(ui.get("_load").visible):
		printerr("shots: material warmup did not finish")
		quit(1)
		return
	var player: Player = main.get("player")
	var lights: LightRig = main.get("lights")
	var chain: RenderChain = main.get("render_chain")
	if not render_override.is_empty() and not chain.apply_preset(render_override):
		printerr("shots: неизвестный --render=" + render_override)
		main.queue_free()
		quit(2)
		return

	main.call("_start_game")
	# Интро-карточки держат ui.busy, а с ним заморожен весь кадр игрока.
	for i in 90:
		if ui.card.open:
			ui.advanceCard()
		await process_frame
	# Мышь захватывать некому — окно под скриптом, курсор не нужен.
	player.release_lock()
	# Угроза и хоррор-слой в кадре приёмки только мешают: дед, вставший
	# в дверях, меняет картинку от прогона к прогону.
	var threat: Variant = main.get("threat")
	if threat != null:
		threat.speedScale = 0.0
	lights.powerOn = true

	if exposure > 0.0:
		chain.set_exposure(exposure)

	var made := 0
	var staged_village := false
	var staged_shed := false
	var staged_outskirts := false
	var staged_final := false
	var staged_valya := false
	for shot: Dictionary in SHOTS:
		if not _matches_filters(String(shot["name"]), filters):
			continue
		if bool(shot.get("final", false)) and not staged_final:
			staged_final = true
			_stage_final(main)
		if bool(shot.get("valya", false)) and not staged_valya:
			staged_valya = true
			_stage_valya(main)
		if shot.has("story_stage"):
			_stage_story_acceptance(main, String(shot["story_stage"]))
		if not shot.has("held"):
			var held_items: HeldItems = main.get("held_items")
			if held_items != null:
				held_items.sync(main.get("state") as GameState)
				held_items.equip(HeldItems.EMPTY)
		_stage_figures(main, shot)
		if shot.has("held"):
			_stage_held(main, String(shot["held"]))
		if bool(shot.get("village", false)) and not staged_village:
			staged_village = true
			_stage_village(main)
		if bool(shot.get("shed", false)) and not staged_shed:
			staged_shed = true
			_stage_shed(main)
		if bool(shot.get("outskirts", false)) and not staged_outskirts:
			staged_outskirts = true
			_stage_outskirts(main)
		var p: Array = shot["pos"]
		lights.set_night_immediate(night_override if night_override >= 0.0 else float(shot["night"]))
		for id: String in lights.state.keys():
			lights.setLamp(id, false)
		for id: Variant in shot["lamps"]:
			lights.setLamp(String(id), true)

		if bool(shot.get("beam", false)):
			(main.get("flashlight") as Flashlight).on = true

		# Расстановка держится не один кадр: главы и фонарь успевают дёрнуть
		# игрока, а пул ламп разгоняется за SKY_TAU. Ставим каждый кадр.
		for i in SETTLE_FRAMES:
			if bool(shot.get("forced_crouch", false)):
				player.crouching = true
				player.height = Player.CROUCH_HEIGHT
				player.height_target = Player.CROUCH_HEIGHT
			player.place(float(p[0]), float(p[1]), float(p[2]), float(shot["yaw"]))
			player.pitch = float(shot["pitch"])
			player.pitch_target = float(shot["pitch"])
			await process_frame
		if shot.has("actor_probe"):
			# Keep the ordinary loop alive while lamps and the camera settle, then
			# freeze story AI only for the portrait frames: threat/haunt otherwise
			# hide their shared figures before the renderer sees them.
			main.set("running", false)
			_stage_actor_probe(main, shot)
		for i in CAPTURE_FRAMES:
			# Story callbacks and chapter resync may still touch the gameplay camera
			# during these last frames. Keep every ordinary acceptance probe pinned
			# just like actor probes; only the drive-away shot owns another camera.
			if not shot.has("drive_at"):
				if bool(shot.get("forced_crouch", false)):
					player.crouching = true
					player.height = Player.CROUCH_HEIGHT
					player.height_target = Player.CROUCH_HEIGHT
				player.place(float(p[0]), float(p[1]), float(p[2]), float(shot["yaw"]))
				player.pitch = float(shot["pitch"])
				player.pitch_target = float(shot["pitch"])
				player.call("_apply_camera")
			if shot.has("actor_probe"):
				_stage_actor_probe(main, shot)
			await process_frame

		# ФАЗА 16. Катсцена отъезда снимается СВОЕЙ камерой, и расстановка
		# игрока к ней отношения не имеет: сцену запускают и ждут её
		# собственного времени, чтобы снимок пришёлся ровно на середину
		# отъезда, а не «через сколько-то кадров».
		if shot.has("drive_at"):
			await _stage_drive(main, float(shot["drive_at"]))

		await RenderingServer.frame_post_draw
		var tex: Texture2D = chain.post_view.get_texture()
		var img: Image = tex.get_image()
		if img == null:
			printerr("shots: пустой кадр на %s" % shot["name"])
			continue
		var path := out.path_join("%s.png" % shot["name"])
		if img.save_png(path) != OK:
			printerr("shots: не сохранился %s" % path)
			continue
		if String(shot["name"]).begins_with("01-"):
			var window_image := root.get_texture().get_image()
			if window_image != null:
				window_image.save_png(out.path_join("window-%dx%d.png" % [root.size.x, root.size.y]))
		made += 1
		print("%s — %dx%d" % [shot["name"], img.get_width(), img.get_height()])
		var shot_stats := chain.stats()
		print("stats %s: buffer=%s calls=%s tris=%s" % [shot["name"],
			shot_stats.get("buffer", "—"), shot_stats.get("calls", 0),
			shot_stats.get("tris", 0)])
		# The final acceptance frame is intentionally at 9.1 s of a 10 s scene.
		# Finish it here so its private camera and scene-only lights cannot leak
		# into the following attic/world probes.
		if shot.has("drive_at") and float(shot["drive_at"]) >= 9.0:
			var cut: Variant = main.get("cutscene")
			if cut != null and bool(cut.playing):
				cut.skip()
				await process_frame
				await process_frame

	var s := chain.stats()
	print("shots: %d снимков в %s" % [made, out])

	print("буфер %s, draw calls %s, треугольников %s"
		% [s.get("buffer", "—"), s.get("calls", 0), s.get("tris", 0)])
	main.queue_free()
	await process_frame
	await process_frame
	quit(0)


func _matches_filters(shot_name: String, filters: PackedStringArray) -> bool:
	if filters.is_empty():
		return true
	for needle: String in filters:
		if shot_name.begins_with(needle):
			return true
	return false


func _stage_story_acceptance(main: Node, stage: String) -> void:
	var ctx: Dictionary = main.get("ctx")
	var state: GameState = ctx.get("state")
	if state == null:
		return
	state.chapter = "village"
	match stage:
		"cellar-keys":
			# The ordinary cellar bulb does not reach the far wall. A staged lantern
			# makes the board, nail, key ring and red tag readable in the acceptance frame.
			pass
		"shop-key-shot":
			pass
		"grave-shovel-shot":
			state.set_flag("mow-done")
		"farm-sign-shot":
			pass
		"garden-after":
			for i in 4:
				state.set_flag("watered-%d" % i)
				state.set_flag("garden-dug-%d" % i)
			state.set_flag("water-done")
			state.set_flag("garden-skeleton")
			state.set_flag("bed-dug")
		"banya-warning":
			state.set_flag("banya-hot")
			state.set_flag("banya-written")
		"banya-key":
			state.set_flag("banya-hot")
			state.set_flag("banya-written")
		"cellar-lantern":
			state.set_flag("banya-written")
			state.set_flag("cellar-shed-open")
			Interact._yard_door(ctx, true)
			var lights: LightRig = ctx.get("lights")
			if lights != null:
				lights.move_lamp("lantern", Vector3(-8.57, 1.25, 3.58))
		"bathloft-ready", "bathloft-attic":
			state.set_flag("banya-written")
			state.set_flag("cellar-shed-open")
			state.give("lantern")
			state.set_flag("lantern-lit")
			Interact._yard_door(ctx, true)
	Interact.resync_world(ctx)
	if stage == "cellar-keys":
		var key_lights: LightRig = ctx.get("lights")
		if key_lights != null:
			key_lights.move_lamp("lantern", Vector3(2.35, -0.10, 14.45))
	elif stage == "shop-key-shot":
		var shop_lights: LightRig = ctx.get("lights")
		if shop_lights != null:
			shop_lights.move_lamp("lantern", Vector3(16.15, 2.10, -5.85))
	elif stage == "farm-sign-shot":
		var sign_lights: LightRig = ctx.get("lights")
		if sign_lights != null:
			sign_lights.move_lamp("lantern", Vector3(-25.45, 2.10, -11.90))
	if stage == "banya-warning":
		# The optional clothes omen sits directly between the western pane and
		# this close-up camera. Resync owns prop visibility, so hide it afterwards
		# and only in the isolated acceptance probe; gameplay remains unchanged.
		var yard: Dictionary = (ctx.get("world", {}) as Dictionary).get("yard", {})
		var yard_nodes: Dictionary = yard.get("nodes", {})
		for prop_id: String in ["banya-clothes", "sprayer"]:
			var prop: Variant = yard_nodes.get(prop_id)
			if prop is Node3D:
				(prop as Node3D).visible = false
	if stage == "bathloft-ready" or stage == "bathloft-attic":
		var yard: Dictionary = (ctx.get("world", {}) as Dictionary).get("yard", {})
		var yard_nodes: Dictionary = yard.get("nodes", {})
		var lights: LightRig = ctx.get("lights")
		if lights != null:
			lights.move_lamp("lantern", Vector3(8.8, 1.15, 23.90) if stage == "bathloft-ready" \
				else Vector3(6.18, 2.38, 24.00))
		if stage == "bathloft-attic":
			var tape: Variant = yard_nodes.get("bathloft-tape")
			if tape is Node3D:
				(tape as Node3D).visible = true


func _stage_held(main: Node, id: String) -> void:
	var state: GameState = main.get("state")
	var held: HeldItems = main.get("held_items")
	if state == null or held == null:
		return
	var done_flags := {
		"bag": ["groceries"], "firewood": ["banya-fired"],
		"apple-basket": ["apples-tossed"], "poison": ["spray-mixed"],
		"sprayer": ["bugs-done"], "canister": ["tank-full"],
		"leyka": ["water-done", "seedlings-done"], "scythe": ["mow-done"],
		"tool-shovel": ["grave-dug", "bed-dug"],
		"distributor": ["distributor-in"], "crowbar": ["well-freed"],
	}
	for flag: String in done_flags.get(id, []):
		state.set_flag(flag, false)
	state.give(id)
	if id == HeldItems.FLASHLIGHT:
		var light: Flashlight = main.get("flashlight")
		light.give()
		light.on = false
	held.sync(state)
	held.equip(id)


func _stage_actor_probe(main: Node, shot: Dictionary) -> void:
	# Portrait capture sets main.running=false after the initial settle. The main
	# node still drives the render chain, while story AI no longer steals the
	# threat/echo figures from this deterministic probe.
	var ctx: Dictionary = main.get("ctx")
	var actors: Variant = ctx.get("actors")
	if actors == null:
		return
	for key: String in Actors.KEYS:
		actors.show(key, false)
	var who := String(shot.get("actor_probe", ""))
	if not Actors.KEYS.has(who):
		return
	actors.place(who, 0.0, 0.0, 3.2)
	actors.face(who, 0.0, 2.0)
	var figure: Node3D = actors.figure(who)
	if figure != null:
		figure.rotation.y += float(shot.get("actor_angle", 0.0))
	actors.show(who, true)


## Вещи главы ДЕРЕВНЯ ставятся на места руками, а не через VillageQuest.enter():
## enter() поднимает деда на улицу (stalk.begin), и он попадал бы в кадр
## приёмки то в одном снимке, то в другом. Здесь нужен интерьер, а не сцена.
func _stage_village(main: Node) -> void:
	var ctx: Dictionary = main.get("ctx")
	var vq: Variant = ctx.get("village")
	if vq == null:
		return
	var st: GameState = ctx["state"]
	st.set_flag("shop-open")
	vq.call("_open_shop", true)
	vq.call("_unboard")
	vq.call("_show", "kovrigin-letter", true)
	vq.call("_show", "shop-key", true)
	vq.call("_show", "shop-rotor", true)
	vq.call("_show", "arkady-tv-glow", true)
	var leaf: Variant = (vq.get("nodes") as Dictionary).get("arkady-door")
	if leaf is Node3D:
		(leaf as Node3D).rotation.y = -0.62
	# Капот «Шестёрки» поднят: снимок 58 принимается вместе с пустым гнездом
	# трамблёра, ради которого вся глава и существует.
	vq.call("_show", "car-hood-open", true)
	# ФАЗА 13. Колодец с ПОДНЯТЫМ ведром и свёртком: принимать надо конец
	# цепочки, а не её начало. И холодильник в красном доме — единственный
	# ток на линии, без него дом на снимке чёрная коробка.
	vq.call("_show", "well-raised", true)
	vq.call("_show", "well-bundle", true)
	var lg: Variant = ctx.get("lights")
	if lg != null:
		lg.setLamp("redhouse", true)


## Околица (фаза 14). Замок водокачки снимается, створка гасится и полотно
## отводится — ровно то, что делает игрок ключом с фермы. Без этого снимок
## 82 принимал бы запертую дверь, а принимать надо постройку.
func _stage_outskirts(main: Node) -> void:
	var ctx: Dictionary = main.get("ctx")
	var col: Variant = ctx.get("col")
	if col != null:
		col.set_blocker_active("door-pump", false)
	var ph: Variant = ctx.get("physics")
	if ph != null:
		ph.sync()
	var built: Dictionary = main.get("built")
	var nodes: Dictionary = ((built.get("outskirts", {}) as Dictionary)
		.get("nodes", {}) as Dictionary)
	var leaf: Variant = nodes.get("door-pump")
	if leaf is Node3D:
		(leaf as Node3D).rotation.y = -1.35


## Линия Вали (фаза 15, часть 2). Ставится руками, как и всё остальное:
## пройти её честно — это три разговора, пять камней и три полосы, а снимку
## нужен результат. Показываем то, чего до своего шага не видно: скошенные
## полосы, тропу, разрытый холм и Валю у ограды.
func _stage_valya(main: Node) -> void:
	var ctx: Dictionary = main.get("ctx")
	var st: GameState = ctx["state"]
	# Глава ставится ПОЛЕМ, а не chapters.go(): go() поднял бы деда на линию
	# и запустил бы постановки главы, а снимку нужна только видимость Вали —
	# neighbours спрашивает atLeast("village") и ничего больше.
	st.chapter = "village"
	# Флаги ставим напрямую: постановка снимка — единственное место, где
	# это можно, и она не притворяется прохождением.
	for f: String in ["valya-seen", "valya-1", "stones-done", "valya-2",
			"mown-0", "mown-1", "mown-2", "mow-done", "lake-told"]:
		st.set_flag(f)
	var q: Variant = ctx.get("valya")
	if q != null:
		q.call("_show", "mow-0", false)
		q.call("_show", "mow-1", false)
		q.call("_show", "mow-2", false)
		q.call("_show", "mow-path", true)
		q.call("_show", "grave-mound", false)
		q.call("_show", "grave-pit", true)
	# Соседи строятся один раз и по своему флагу: без build() Валя остаётся
	# невидимой болванкой в начале координат.
	var nb: Variant = main.get("neighbours")
	if nb != null:
		nb.update(0.1)


## Финал (фаза 15): гроза, погасшая деревня, снятая цепь. Ставится руками,
## а не главой: Chapters.go("gate") подняло бы деда в режим погони, и он
## приезжал бы в кадр то в одном снимке, то в другом.
## Запустить катсцену отъезда и довести её до секунды at. Титры при этом
## не показываются: снимок делается до того, как сцена кончится сама.
func _stage_drive(main: Node, at: float) -> void:
	var chapters: Chapters = main.get("chapters")
	var ctx: Dictionary = main.get("ctx")
	var cut: Variant = main.get("cutscene")
	if chapters == null or cut == null:
		return
	# Сцену запускаем ОДИН раз на прогон: четыре плана отъезда снимаются из
	# одной и той же сцены — повторный запуск поверх
	# первого просто вернул бы false и показал титры.
	if not bool(cut.playing):
		chapters.call("_drive_away", ctx, "alone")
	var guard := 0
	while bool(cut.playing) and float(cut.call("time")) < at and guard < 2000:
		guard += 1
		await process_frame


func _stage_final(main: Node) -> void:
	var ctx: Dictionary = main.get("ctx")
	var w: Variant = ctx.get("weather")
	if w != null:
		w.set_rain(0.9)
		# Дождь в кадре ползёт к цели, а снимок ждать не будет: ставим сразу.
		for _i in 30:
			w.update(0.1, true)
	var lg: Variant = ctx.get("lights")
	if lg != null:
		for id: String in Chapters.VILLAGE_LAMPS:
			lg.setLamp(id, false)
	var set_wicket: Variant = ctx.get("setWicket")
	if set_wicket is Callable:
		(set_wicket as Callable).call(true, true)
	else:
		# Compatibility fallback for old fixture contexts which predate setWicket.
		var col: Variant = ctx.get("col")
		if col != null:
			col.set_blocker_active("wicket", false)
	var ph: Variant = ctx.get("physics")
	if ph != null:
		ph.sync()


## Фигуры в кадре: двойник у створки и дед в погоне. Обе гасятся на снимках,
## которые их не просят, — иначе они доживают до следующего кадра.
func _stage_figures(main: Node, shot: Dictionary) -> void:
	# Идёт катсцена — фигуры расставляет она, и трогать их нельзя: двойник
	# в ней и есть Витя, смотрящий вслед машине.
	var cut0: Variant = main.get("cutscene")
	if cut0 != null and bool(cut0.playing):
		return
	var ctx: Dictionary = main.get("ctx")
	var actors: Variant = ctx.get("actors")
	if actors == null:
		return
	# Двойника надо не просто показать, а ЗАБРОНИРОВАТЬ: haunt.update() держит
	# его своим и гасит в том же кадре, в котором его тут включили.
	var hold: Variant = ctx.get("holdEcho")
	var want_echo := bool(shot.get("echo", false))
	if want_echo:
		var p: Array = shot["pos"]
		if hold is Callable:
			(hold as Callable).call(30.0)
		actors.place("echo", 0.2, 0.0, -0.9, 0.0)
		actors.show("echo", true)
		actors.face("echo", float(p[0]), float(p[2]))
	else:
		actors.show("echo", false)

	var threat: Variant = main.get("threat")
	if threat == null:
		return
	var st: GameState = ctx["state"]
	if bool(shot.get("chase", false)):
		# Тем же приёмом: без активной угрозы Threat.update() гасит фигуру
		# первой же строкой, а режим погони заодно отключает и детектор
		# застревания — иначе он выдернул бы стоящего деда телепортом.
		st.threatState = "hunt"
		threat.set("final_mode", true)
		var p2: Array = shot["pos"]
		# Сбоку от машины и УЖЕ ЗА ВОРОТАМИ: на оси кадра «Шестёрка» закрывает
		# фигуру целиком, а за забором её съедает частокол. Три метра — тот
		# момент погони, ради которого она и сделана.
		threat.call("place_at", float(p2[0]) - 2.3, 0.0, float(p2[2]) + 2.4)
		actors.show("threat", true)
		actors.face("threat", float(p2[0]), float(p2[2]))
	else:
		st.threatState = "absent"
		threat.set("final_mode", false)
		actors.show("threat", false)


## Вещи Вити на верстаке появляются после блэкаута. Показать их без блэкаута —
## единственный способ снять сарай при свете, а не в полной темноте.
func _stage_shed(main: Node) -> void:
	var ctx: Dictionary = main.get("ctx")
	var i: Variant = ctx.get("interact")
	if i != null and i.has_method("_home_show"):
		i.call("_home_show", ctx, "shed-things", true)

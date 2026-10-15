# ВИТЯ. КАССЕТА №4

Игра на Godot 4.7.1, перенесённая из основной рабочей папки с исправлениями от 5 октября 2026 года. Рендерер Compatibility, физика Jolt. Игровые исходники, модели, текстуры, звук и тесты находятся в `godot/`.

[Windows-сборка](https://github.com/chipsen228/vitya-kasseta-4/releases/tag/v2026.10.05-public) содержит движок и PLAY_VITYA.cmd. Распакуйте ZIP целиком и запустите PLAY_VITYA.cmd. Первый запуск импортирует ресурсы; дождитесь его завершения.

[Приватный архив и восстановление](https://github.com/chipsen228/vitya-kasseta-4-archive) доступны владельцу аккаунта.

Для разработки установите Godot 4.7.1 и откройте `godot/project.godot`. При первом запуске движок импортирует ресурсы. Папка `.godot` воспроизводится и в репозиторий не входит. Генерация озвучки и платные API для запуска игры не нужны.

Проверки из PowerShell, когда консольный Godot доступен как `godot`:

```powershell
godot --headless --path .\godot --editor --import --quit
godot --headless --path .\godot --script res://tests/check_compile.gd
godot --headless --path .\godot --script res://tests/test_fuel_hold.gd
godot --headless --path .\godot --script res://tests/test_intro_shop.gd
godot --headless --path .\godot --script res://tests/test_threshold_scares.gd
godot --headless --path .\godot --script res://tests/test_startle.gd
godot --headless --path .\godot --script res://tests/test_scares_budget.gd
```

Некоторые исторические тесты окружения используют материалы приёмки из приватного архива. Для них нужны исходные отчёты и снимки соответствующей разработки. Примеры `skin.example.json` показывают необязательный слой HQ; отсутствие `skin.json` и `props_skin.json` предусмотрено движком игры.

Актуальные источники текстур окружения и условия использования указаны в `NOTICES/CURRENT_ENVIRONMENT_CREDITS.md` и `NOTICES/texture-provenance.json`. Уведомления старых моделей находятся в `godot/assets/models/CREDITS.md`. PT Mono распространяется с приложенным `NOTICES/PT-Mono-OFL.txt`. Уведомления Godot находятся в `NOTICES/`.

`NOTICES/ASSET_CREDITS.md` описывает также исторические варианты и отбракованные источники разработки. Исходные наборы Fab/Quixel из этой истории входят в приватный архив; текущие игровые модели окружения используют созданную для игры геометрию и текстуры CC0. Публикация авторского кода сама по себе не предоставляет отдельную открытую лицензию на весь проект. Условия сторонних компонентов сохраняются.

Прежняя история Git, пять рабочих состояний, прототип, исходные документы и материалы разработки предназначены для приватного репозитория `vitya-kasseta-4-archive`. Восстановление должно следовать его манифесту и проверять SHA-256.

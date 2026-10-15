# Источники окружения

Общая карта 1024×1024 получена из проверенного CC0 atlas `tex_src/session1_exterior`. Исходные UV1, карты normal/ORM и рисунок дерева сохранены; цвет краски и оцинковки задаёт воспроизводимый Blender-генератор. Полные лицензии, crop и SHA256 исходников записаны в `texture-provenance.json`.

- `wood`: S/crate_box/wooden_crate_02 — https://polyhaven.com/a/wooden_crate_02; CC0.
- `red`: S/bath_bench/painted_wooden_bench — https://polyhaven.com/a/painted_wooden_bench; CC0.
- `pale`: S/crate_box/wooden_crate_02 — https://polyhaven.com/a/wooden_crate_02; CC0.
- `metal`: S/barrel_metal/barrel_03 — https://polyhaven.com/a/barrel_03; CC0.

AO запекается отдельно для каждого владельца на UV2 в Cycles CPU, 16 samples, дистанция 0.55 м. Нижняя граница 0.35 сохраняет читаемость в глубоких стыках. Все три LOD используют одну AO карту владельца. GLB содержит встроенные карты для переносимости; runtime назначает общие внешние карты и освобождает исходные embedded material keys.

| Runtime карта | SHA256 |
|---|---|
| `trim-diff.png` | `707330a54ed33eb1daef842bbba5b5cbdd0207909692a6df49c95b37a6d55501` |
| `trim-nor_gl.png` | `1c44084a0525d4d663618a54a47cf7ac65f9bc9a4fca0db671562d6de4e40bd6` |
| `trim-orm.png` | `6f23e7c2e18f11e08ba41da9d15f269ac74a1c2add2fc1c080e96e2a121e584a` |

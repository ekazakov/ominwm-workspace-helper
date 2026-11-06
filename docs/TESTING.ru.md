# Проверка MVP

Дата: 6 ноября 2026, Europe/Berlin.

## Что проверено на целевой машине

Установленный `omniwmctl`: `/opt/homebrew/bin/omniwmctl`.

```text
0.7.6 (protocol 19, build 3c078395, release, sha256 b05749a79055)
```

Выполнены read-only запросы `version`, `workspace-bar`, `workspaces`, `focused-window`, `commands`, `capabilities`, `windows`. Доступны 7 workspace на двух мониторах, включая пустой workspace. У источника подтверждены `mode = "tiling"`, `columnIndex` и native `windowId`.

На реальных ответах дополнительно выполнены Lua-функции `normalize.unwrap`, `capabilities`, `workspaces`, `mergeBar`, `focused`, `column`: структура принята, workspace и приложения объединены по UUID. Личные заголовки окон и opaque ID в репозиторий не включены.

Подтверждён контракт 0.7.6:

- Envelope: `ok → result → kind/payload`.
- `workspace-bar.payload.monitors[].workspaces[].windows[]` содержит `appName`, `bundleId`.
- `workspaces` содержит UUID `id`, числовой `number`, `displayName`, `layout`, `counts`, `display`.
- `focused-window.payload.window.id` — opaque ID, workspace — вложенный объект.
- `windows` содержит `mode = "tiling"`, `columnIndex`, `windowId`, `isFocused`.
- `move-column-to-workspace` принимает **workspace-number**, не UUID.
- В `windowActions` доступен `window focus <opaque-id>`.

## Измерения CLI

Пять последовательных запусков на запрос, monotonic clock, включая создание процесса и чтение JSON. Это измерения CLI из среды разработки, не времени Hammerspoon UI.

| Запрос | min, ms | median, ms | max, ms |
| --- | ---: | ---: | ---: |
| capabilities | 7.1 | 8.2 | 12.3 |
| workspace-bar | 5.1 | 5.3 | 5.9 |
| workspaces | 5.4 | 6.0 | 6.4 |
| focused-window | 4.7 | 5.0 | 5.8 |
| windows | 5.3 | 5.5 | 6.0 |

Cold/warm menu latency, refresh через `hs.task` и перенос не измерены: Hammerspoon на машине не обнаружен. Цель warm start <100 ms пока не подтверждена. Реальные окна при проверках не перемещались.

## Автоматические тесты

Команда: `/opt/homebrew/bin/luajit tests/run.lua`.

Результат: **27 passed, 0 failed**. Также выполнена синтаксическая загрузка всех runtime-модулей Lua.

Покрыты нормализация envelope и ошибок, реальные имена полей 0.7.6, дублирующиеся Unicode-имена, workspace 12/14, пустые workspace, группировка приложений, отсутствующие bundle ID, LRU и повторное использование canvas/иконок; восстановление/проверка фокуса, закрытие источника, изменение колонки, удаление назначения до и после восстановления фокуса, свежий числовой аргумент, no-op на текущем workspace; невалидный JSON, ненулевой exit code, отказ запуска task, timeout и поздние callbacks; refresh fallback; повторный start/stop, замена экземпляра, быстрые повторные шорткаты, сохранение поиска/выделения, холодная загрузка и Enter.

Mock-тесты проверяют последовательность запросов и условия отмены. Они не проверяют AppKit, реальную отрисовку canvas, macOS Accessibility и фактический перенос колонок сервером OmniWM.

## Ручная приёмка после установки Hammerspoon

- [ ] Hyper + W открывает/закрывает меню; Escape отменяет.
- [ ] Видны все workspace обоих мониторов, пустые workspace и актуальные имена.
- [ ] Иконки читаемы, неизвестные приложения имеют нейтральную иконку, `+N` виден.
- [ ] Поиск по номеру/имени/приложению и стрелки работают; Unicode и длинные имена читаемы.
- [ ] Enter переносит все окна колонки из нескольких окон, остальные колонки остаются на месте.
- [ ] Перенос между мониторами соответствует возможностям OmniWM.
- [ ] Текущий workspace даёт no-op; реальный workspace с номером >9 работает.
- [ ] Закрытие источника/изменение колонки во время меню отменяет перенос.
- [ ] Floating и scratchpad отменяют перенос.
- [ ] Повторные открытия не увеличивают `iconBuilds` при неизменных приложениях.
- [ ] Фоновый refresh обновляет приложения без сброса поиска и выбранного workspace.
- [ ] Остановка/перезапуск OmniWM обрабатывается без зависания.
- [ ] Reload Config оставляет один hotkey; после `stop()` нет tasks/timers/canvas расширения.
- [ ] Многократное открытие/закрытие не вызывает устойчивого роста памяти.
- [ ] Замерены cold/warm start, refresh и move через `diagnostics()` на настоящем Hammerspoon.

Отдельно проверить конкурентную смену фокуса: CLI 0.7.6 не имеет атомарной команды переноса по исходному opaque ID. Между финальной проверкой и выполнением остаётся гонка, описанная в README. Абсолютная гарантия при одновременном внешнем изменении требует поддержки OmniWM.

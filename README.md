# OmniWM Workspace Column Mover

Расширение Hammerspoon: **Hyper + W** открывает список воркспейсов с иконками приложений, Enter переносит исходную Niri-колонку целиком. Escape или повторный шорткат отменяет выбор. Поиск работает по номеру, имени и приложениям.

Реализован MVP для **OmniWM 0.7.6 / protocol 19**. Совместимость проверена на установленном OmniWM; GUI и реальный перенос пока требуют проверки в Hammerspoon. [Исходное ТЗ](docs/SPEC.ru.md), [результаты проверок](docs/TESTING.ru.md).

## Установка

Нужны macOS, [Hammerspoon](https://www.hammerspoon.org/) и работающий OmniWM 0.7.6 с доступным IPC и `omniwmctl`. Воркспейсы источника и назначения должны использовать Niri. Дополнительные зависимости для расширения не требуются.

Из папки проекта:

```sh
./setup.sh
```

Скрипт копирует runtime-модули в `~/.hammerspoon/omniwm-workspace-chooser`, создаёт отдельную конфигурацию `~/.hammerspoon/omniwm-workspace-chooser-config.lua` и подключает её из `init.lua`. Перед обновлением существующие модули и `init.lua` сохраняются в каталог резервной копии; путь выводится в Terminal. Повторный запуск сохраняет пользовательскую конфигурацию и не добавляет повторный loader. Если в `init.lua` уже найдено упоминание расширения, скрипт оставляет подключение без изменений — проверьте существующий loader самостоятельно.

Для нестандартного расположения конфигурации Hammerspoon:

```sh
./setup.sh --config-dir "/path/to/hammerspoon"
```

Скрипт устанавливает файлы расширения; Hammerspoon и OmniWM должны быть установлены отдельно. После установки настройки можно изменить в `omniwm-workspace-chooser-config.lua`:

```lua
if omniwmWorkspaceChooser then omniwmWorkspaceChooser:stop() end

omniwmWorkspaceChooser = require("omniwm-workspace-chooser").new({
    hotkey = {
        modifiers = { "ctrl", "alt", "shift" },
        key = "W",
    },
    maxIcons = 5,
    iconSize = 22,
    -- cliPath = "/opt/homebrew/bin/omniwmctl",
    -- debug = true,
}):start()
```

Полный готовый фрагмент: [examples/hammerspoon-init.lua](examples/hammerspoon-init.lua). При ручной установке скопируйте файлы `*.lua` в `~/.hammerspoon/omniwm-workspace-chooser` и добавьте этот фрагмент в `~/.hammerspoon/init.lua`. Перезагрузите конфигурацию через **Reload Config** в меню Hammerspoon.

В **System Settings → Privacy & Security → Accessibility** разрешите доступ Hammerspoon и OmniWM. Если macOS дополнительно запросит разрешение на обработку клавиатурного ввода, предоставьте его Hammerspoon. OmniWM должен уже управлять окнами и отвечать на CLI-запросы.

Сфокусируйте обычное tiled-окно, нажмите Hyper + W, выберите workspace стрелками или поиском и нажмите Enter. Точка `●` обозначает workspace исходного окна. Выбор этого же workspace ничего не перемещает.

## Конфигурация

Параметры передаются в `.new({...})`; значения по умолчанию находятся в [config.lua](config.lua).

| Параметр               | По умолчанию | Назначение                                                  |
| ---------------------- | ------------ | ----------------------------------------------------------- |
| `hotkey`               | Hyper + W    | `modifiers` и `key` для `hs.hotkey`                         |
| `maxIcons`             | `5`          | От 1 до 5 приложений; остальные обозначаются `+N`           |
| `iconSize`             | `22`         | Размер ячейки изображения в pt до масштабирования chooser   |
| `theme`                | `"dark"`     | `"dark"` или `"light"`                                      |
| `showEmptyWorkspaces`  | `true`       | Показывать пустые workspace                                 |
| `showCurrentWorkspace` | `true`       | Показывать workspace источника                              |
| `searchAppNames`       | `true`       | Включать штатный поиск по `subText` с названиями приложений |
| `refreshOnOpen`        | `true`       | Обновлять данные после открытия из кеша                     |
| `debug`                | `false`      | Выводить измерения в Hammerspoon Console                    |
| `cliPath`              | `nil`        | Полный путь; иначе поиск в стандартных каталогах и `PATH`   |
| `taskTimeout`          | `5`          | Таймаут одного CLI-запроса, секунды                         |
| `iconCacheLimit`       | `128`        | Максимум записей кеша приложений                            |
| `compositeCacheLimit`  | `128`        | Максимум записей кеша составных изображений                 |
| `rows`                 | `8`          | Число видимых строк                                         |
| `width`                | `48`         | Ширина chooser в процентах экрана                           |

Иконки объединены в компактную мозаику. Стандартный `hs.chooser` ограничивает область `image` и масштабирует составное изображение: фактический размер отдельных значков может быть меньше `iconSize`. Широкую строку из пяти полноразмерных иконок этот MVP не обещает. Длинные имена сохраняются целиком в данных поиска; видимый текст обрезает стандартный chooser. Unicode и emoji не обрезаются вручную.

## Как устроен перенос

1. До показа chooser фиксируются native window ID, opaque ID OmniWM, UUID исходного workspace, индекс колонки и ID всех её окон. При смене фокуса во время захвата меню не открывается.
2. После выбора UUID назначения проверяется по свежему `query workspaces`. Источник и назначение должны оставаться Niri-workspace.
3. Повторно проверяется состав исходной колонки. Закрытое окно, floating/scratchpad, отсутствие `columnIndex` или изменение состава отменяют операцию.
4. `window focus <opaque-id>` восстанавливает исходное окно. Затем повторно разрешается назначение и проверяются live-фокус OmniWM, native-фокус macOS и состав колонки.
5. Отправляется именно `command move-column-to-workspace <number>`.

В 0.7.6 UUID из `query workspaces` **не является аргументом** команды переноса колонки. Её установленный контракт — `workspace-number`. Поэтому в UI и кеше хранится UUID, а непосредственно перед переносом он разрешается в актуальный числовой `number`. Отображаемые имена для адресации не используются.

CLI 0.7.6 не предоставляет атомарную операцию «проверь opaque ID и перенеси его колонку». Между последней проверкой и выполнением команды остаётся короткое окно гонки с внешней сменой фокуса/конфигурации. Проверки предотвращают обнаруженные расхождения, но не дают абсолютной гарантии при одновременных внешних изменениях. Для устранения этого ограничения нужна атомарная команда на стороне OmniWM.

При таймауте команды результат может быть неизвестен; автоматического повторного переноса нет. Ошибки показываются кратким уведомлением и записываются через `hs.logger`.

## Кеши и жизненный цикл

При старте выполняется асинхронная проверка capabilities и прогрев данных workspace. При открытии сначала фиксируется источник двумя короткими асинхронными запросами. Заполненный список показывается без ожидания обновления приложений. При пустом кеше появляется невыбираемая строка загрузки.

`workspace-bar` — основной источник приложений; неполная или недоступная проекция заменяется данными `query windows`. Полный список и порядок берутся из `workspaces`, сортировка — по числовому `number`.

Кеш workspace заменяет предыдущий снимок. Два отдельных LRU-кеша хранят иконки приложений (включая отрицательные результаты поиска) и составные изображения. Один скрытый canvas переиспользуется; изображения перестраиваются при изменении приложений. Фоновый refresh сохраняет запрос и выбранный workspace, насколько это позволяет chooser. Постоянного polling или подписки нет.

```lua
omniwmWorkspaceChooser:toggle()
omniwmWorkspaceChooser:stop()  -- hotkey, chooser, tasks, timers, canvas, caches
omniwmWorkspaceChooser:start()
```

Повторный `start()` идемпотентен. Новый экземпляр останавливает предыдущий через общий реестр; незавершённые callbacks после `stop()` не продолжают перенос. Во время операции переноса повторные шорткаты игнорируются.

## Диагностика

В Terminal:

```sh
omniwmctl version
omniwmctl query capabilities --format json
omniwmctl query commands --format json
omniwmctl query workspaces --format json
omniwmctl query workspace-bar --format json
omniwmctl query focused-window --format json
omniwmctl query windows --format json
```

В Hammerspoon Console:

```lua
hs.inspect(omniwmWorkspaceChooser:diagnostics())
```

Результат содержит путь CLI, совместимость, число workspace, размеры кешей, число построений изображений и последние измерения в миллисекундах: `coldOpenMs`, `warmOpenMs`, `refreshMs`, `moveMs`. Включите `debug = true` перед `start()`, чтобы видеть их в журнале. `coldOpenMs` измеряет готовность списка, а не появление строки загрузки; `moveMs` — время до ответа команды, а не завершение анимации macOS.

| Симптом                                   | Что проверить                                                                             |
| ----------------------------------------- | ----------------------------------------------------------------------------------------- |
| `omniwmctl not found`                     | `command -v omniwmctl`; задайте полный `cliPath`                                          |
| `transport_failure`, timeout              | OmniWM запущен, IPC доступен, CLI работает из Terminal                                    |
| `Supported OmniWM version...`             | MVP разрешает только 0.7.6/protocol 19; для новой версии нужна проверка схем и команд     |
| `No native window focused`                | Accessibility Hammerspoon и фокус обычного окна приложения                                |
| `Source window is not in a Niri column`   | Niri, tiled-окно, отсутствие floating/scratchpad; наличие `columnIndex` в `query windows` |
| `Source column changed...`                | Повторите выбор: во время меню изменился состав или положение колонки                     |
| `Could not confirm original column focus` | Восстановление фокуса не подтверждено; перенос отменён                                    |

Для отображения chooser поверх native fullscreen окон Hammerspoon документирует `hs.dockicon.hide()`. Это пользовательская настройка Hammerspoon; см. [hs.chooser](https://www.hammerspoon.org/docs/hs.chooser.html). API процессов и композиции: [hs.task](https://www.hammerspoon.org/docs/hs.task.html), [hs.canvas](https://www.hammerspoon.org/docs/hs.canvas.html).

## Проверки разработки

Автотесты используют подмену Hammerspoon API и синтетические fixtures без пользовательских заголовков окон:

```sh
luajit tests/run.lua
# или Lua 5.3/5.4:
lua tests/run.lua
```

Интерпретатор нужен только для разработки; установленное расширение исполняет Lua внутри Hammerspoon. Подробности и ручной чеклист — в [docs/TESTING.ru.md](docs/TESTING.ru.md).

# OmniWM Workspace Column Mover


Press and release Right Command twice within 200 ms to open or close the window switcher. Each window has a letter shortcut centered on its preview. Empty workspaces have no letter shortcuts. Hyper+W (Ctrl+Alt+Shift+W) opens the column move panel.

Shortcuts follow `asdfghjklqwertyuiopzxcvbnm` across display groups, workspace rows, and windows. Up to 26 targets use one letter. Up to 676 targets use two letters. Larger lists use longer sequences. Shortcuts use physical key positions across keyboard layouts.

Press sequence letters one after another. After each correct letter, matching badges show only the remaining letters. Other badges disappear. The default timeout between letters is 300 ms. Set `shortcutSequenceTimeoutMs` to a positive integer to change this timeout in milliseconds. A timeout or wrong letter restores all badges. Holding a key does not complete a sequence.

Left/right selects a window within a workspace row. Up/down changes workspace rows. The panel initially selects the currently focused window. Enter or Space focuses the selected window, or switches workspaces when the selected row is empty. Click a preview to focus that window. Clicking workspace label text only highlights the row. The panel scrolls the selected preview into view.

Press number keys to switch by workspace number. For example, press `1` then `2` for workspace 12. If a number also starts a longer number, the helper waits for the sequence timeout. Enter or Space activates the selected window or empty workspace immediately. Escape clears a partial letter sequence first. Otherwise, Escape closes the panel. Navigation resets partial input. The switch panel has no search bar. The move panel retains Command+number shortcuts and direct text search.

Assignments stay fixed during refresh. New targets receive unused shortcuts. Removed targets reserve their shortcuts until closing. If capacity runs out, the panel increases the shortcut length, reassigns all targets, and resets partial input.

The switcher shows only workspace numbers and omits the active workspace dot. Empty workspace rows show one gray placeholder, 90 px high with the aspect ratio of the workspace display. Workspace numbers appear in white at the top of the first column. The switcher shows separate previews for windows from the same app. Display names appear only when more than one display is connected. Each preview is 90 px high and keeps its proportions. App icons are 16 px square and align to the bottom left, 5 px inside the preview edges. Window titles appear beside icons in white 11 px text, vertically centered beside the icon, with a 3 px blurred shadow. Long titles end with an ellipsis. All workspace rows are 102 px high. The workspace label column fits the longest label. A 5 px gap separates previews and labels. Panel padding is 10 px horizontally and 6 px vertically. Preview rows have 6 px of vertical padding on each side. The panel fits the longest preview row and workspace labels, including gaps and padding. Its maximum width is 80% of the screen. Its height fits the content and stops at the available screen height. Longer lists scroll. Scroll horizontally over previews, or use Shift+wheel, to see more windows.

Set `switchDoublePress.intervalMs` to change the tap interval. The interval measures the gap from the first release to the second press. Each press must also finish within that interval. Left Command does not trigger the switcher. The default `keyCode = 54` identifies the physical Right Command key. A key press, click, scroll, or extra modifier cancels the gesture. The helper observes modifier changes without consuming events. Set `switchDoublePress.enabled = false` to use `switchHotkey` instead. The existing `omniwmWorkspaceChooser:toggleSwitch()` method opens or closes the window switcher.

Window screenshots stay in memory across panel openings. The helper refreshes windows across all workspaces every 30 seconds, even while the panel is closed. Visible windows receive priority. Each capture runs in a separate timer callback. If capture fails, the helper keeps the previous screenshot or uses an app icon. Closed windows leave the cache after a successful workspace refresh. Stopping the helper releases all screenshots. The helper never saves screenshots to disk. Set `previewRefreshInterval = 0` to disable background refresh. The move panel keeps its compact app icons.



Расширение Hammerspoon: **Hyper + W** открывает список воркспейсов с иконками приложений, Enter переносит исходную Niri-колонку целиком. Escape или повторный шорткат отменяет выбор. Поиск работает по номеру, имени и приложениям.

Меню использует `hs.canvas`. Слева расположен номер и название workspace, справа — иконки приложений одного размера `iconSize`, затем подсказки ⌘1–⌘9 шрифтом 15 pt. Названия приложений скрыты. Воркспейсы сгруппированы по ID дисплея, а имя дисплея показано общим подзаголовком группы. Поиск сохраняет группировку; заголовки не выбираются стрелками или кликом и не занимают позиции ⌘1–⌘9. Управление: стрелки, Enter, Escape, ⌘1–⌘9, клик по строке, прокрутка, Backspace, ⌘V для вставки, ⌘A для очистки запроса. Клик вне меню закрывает его.

Выделение следует за курсором при наведении на строку workspace. Стрелки ↑/↓ переключают доступные workspace по кругу, включая переход между последней и первой строками; подзаголовки дисплеев пропускаются. Это работает и для результатов поиска.

Canvas не активирует Hammerspoon. Перехват клавиатуры работает только при открытом меню и отключается при закрытии и `stop()`. Если macOS блокирует перехват через Secure Input или отсутствуют разрешения, меню отменяется с уведомлением. Поиск поддерживает Unicode и регистронезависимое сравнение, однако Canvas не является системным текстовым полем: стандартные IME и редактирование текста с курсором не реализованы.

Реализован MVP для **OmniWM 0.7.6 / protocol 19**. Совместимость проверена на установленном OmniWM; GUI и реальный перенос пока требуют проверки в Hammerspoon. [Исходное ТЗ](docs/SPEC.ru.md), [результаты проверок](docs/TESTING.ru.md).

## Установка

Нужны macOS, [Hammerspoon](https://www.hammerspoon.org/) и работающий OmniWM 0.7.6 (protocol 19) или 0.8.0 (protocol 22) с доступным IPC и `omniwmctl`. Воркспейсы источника и назначения должны использовать Niri. Дополнительные зависимости для расширения не требуются.

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

Интерфейс и уведомления поддерживают английский, немецкий и русский. Язык выбирается автоматически при `start()` по первому языку в системных настройках macOS (`hs.host.locale.preferredLanguages()`); региональные варианты вроде `de-DE` и `en-GB` поддерживаются. Для других языков используется английский. После изменения системного языка выполните **Reload Config** в Hammerspoon. Названия воркспейсов, приложений и мониторов сохраняются; технические сообщения в журнале остаются на английском. Выбранный язык доступен в `diagnostics().language`.

Параметры передаются в `.new({...})`; значения по умолчанию находятся в [config.lua](config.lua).

| Параметр               | По умолчанию | Назначение                                                  |
| ---------------------- | ------------ | ----------------------------------------------------------- |
| `hotkey`               | Hyper + W    | `modifiers` и `key` для `hs.hotkey`                         |
| `maxIcons`             | `5`          | От 1 до 5 приложений; остальные обозначаются `+N`           |
| `iconSize`             | `22`         | Одинаковый размер каждой иконки в pt                         |
| `theme`                | `"dark"`     | `"dark"` или `"light"`                                      |
| `showEmptyWorkspaces`  | `true`       | Показывать пустые workspace                                 |
| `showCurrentWorkspace` | `true`       | Показывать workspace источника                              |
| `searchAppNames`       | `true`       | Искать также по скрытым названиям приложений                 |
| `refreshOnOpen`        | `true`       | Обновлять данные после открытия из кеша                     |
| `debug`                | `false`      | Выводить измерения в Hammerspoon Console                    |
| `cliPath`              | `nil`        | Полный путь; иначе поиск в стандартных каталогах и `PATH`   |
| `previewRefreshInterval` | `30` | Seconds between background preview refreshes. Use `0` to disable. |
| `taskTimeout`          | `5`          | Таймаут одного CLI-запроса, секунды                         |
| `iconCacheLimit`       | `128`        | Максимум записей кеша приложений                            |
| `compositeCacheLimit`  | `128`        | Максимум записей кеша составных изображений                 |
| `rows`                 | `8`          | Число видимых строк                                         |
| `width`                | `28.8`       | Ширина Canvas-меню в процентах экрана (на 40% меньше прежних 48%) |

Иконки объединены в кешируемое горизонтальное изображение и выводятся без уменьшения при увеличении числа приложений. Длинные имена workspace обрезаются только при отрисовке; поиск использует полные строки.

## Как устроен перенос

1. До показа chooser фиксируются native window ID, opaque ID OmniWM, UUID исходного workspace, индекс колонки и ID всех её окон. При смене фокуса во время захвата меню не открывается.
2. После выбора UUID назначения проверяется по свежему `query workspaces`. Источник и назначение должны оставаться Niri-workspace.
3. Повторно проверяется состав исходной колонки. Закрытое окно, floating/scratchpad, отсутствие `columnIndex` или изменение состава отменяют операцию.
4. `window focus <opaque-id>` восстанавливает исходное окно. Затем повторно разрешается назначение и проверяются live-фокус OmniWM, native-фокус macOS и состав колонки.
5. Отправляется именно `command move-column-to-workspace <number>`.

В 0.7.6 и 0.8.0 UUID из `query workspaces` **не является аргументом** команды переноса колонки. Её установленный контракт — `workspace-number`. Поэтому в UI и кеше хранится UUID, а непосредственно перед переносом он разрешается в актуальный числовой `number`. Отображаемые имена для адресации не используются.

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
| `Supported OmniWM version...`             | Поддерживаются 0.7.6/protocol 19 и 0.8.0/protocol 22; для других версий нужна проверка схем и команд |
| `No native window focused`                | Accessibility Hammerspoon и фокус обычного окна приложения                                |
| `Source window is not in a Niri column`   | Niri, tiled-окно, отсутствие floating/scratchpad; наличие `columnIndex` в `query windows` |
| `Source column changed...`                | Повторите выбор: во время меню изменился состав или положение колонки                     |
| `Could not confirm original column focus` | Восстановление фокуса не подтверждено; перенос отменён                                    |

Canvas-меню использует поведение `canJoinAllSpaces` / `fullScreenAuxiliary`. API процессов и отрисовки: [hs.task](https://www.hammerspoon.org/docs/hs.task.html), [hs.canvas](https://www.hammerspoon.org/docs/hs.canvas.html).

## Проверки разработки

Автотесты используют подмену Hammerspoon API и синтетические fixtures без пользовательских заголовков окон:

```sh
luajit tests/run.lua
# или Lua 5.3/5.4:
lua tests/run.lua
```

Интерпретатор нужен только для разработки; установленное расширение исполняет Lua внутри Hammerspoon. Подробности и ручной чеклист — в [docs/TESTING.ru.md](docs/TESTING.ru.md).


CLI output capture

The helper captures CLI output in temporary files with owner-only access. It reads stdout and stderr after the process exits. This avoids truncated or reordered JSON from asynchronous pipe callbacks. The helper deletes these files after completion, cancellation, or a timeout.

Run `/opt/homebrew/bin/luajit tests/run.lua` to test the helper. Run `python3 tests/test_task_output.py --live-cli` to test large output and the installed OmniWM capabilities query.

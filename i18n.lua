-- Prefer the macOS UI language over its regional/number-formatting locale.
local M = {}
local strings = {
    en = {
        keyboardUnavailable = "Cannot capture keyboard input. Check Hammerspoon permissions and close password fields (Secure Input).",
        placeholder = "Move column → workspace…", loading = "Loading workspaces…",
        empty = "No apps", unknownApp = "Unknown app", noDestinations = "No available destinations",
        filters = "Check your filter settings", failed = "Operation failed. See Hammerspoon Console for details.",
        noFocus = "No application window is focused.", focusChanged = "Focus changed. Please try again.",
        closed = "The source window has closed.", moved = "The source window changed workspace. Please try again.",
        notColumn = "The source window is not in a Niri column (floating/scratchpad/unknown).",
        columnChanged = "The source column changed while the menu was open. Please try again.",
        focusFailed = "Could not restore the source column’s focus. Move cancelled.",
        workspaceGone = "A workspace was removed or its layout changed. Move cancelled.",
        niri = "Both workspaces must use the Niri layout.", noWorkspaces = "No available workspaces.",
        incompatible = "OmniWM 0.7.6 / protocol 19 is required. Check compatibility in Hammerspoon Console.",
        cliMissing = "omniwmctl was not found. Set cliPath to its absolute path.",
        timeout = "OmniWM timed out. The command outcome may be unknown.",
        cliFailed = "OmniWM could not complete the command. See Hammerspoon Console for details.",
        invalidData = "OmniWM returned unexpected data. See Hammerspoon Console for details.",
    },
    de = {
        keyboardUnavailable = "Tastatureingabe nicht verfügbar. Hammerspoon-Berechtigungen prüfen und Passwortfelder schließen (Secure Input).",
        placeholder = "Spalte verschieben → Arbeitsbereich…", loading = "Arbeitsbereiche werden geladen…",
        empty = "Keine Apps", unknownApp = "Unbekannte App", noDestinations = "Keine verfügbaren Ziele",
        filters = "Filtereinstellungen prüfen", failed = "Vorgang fehlgeschlagen. Details stehen in der Hammerspoon-Konsole.",
        noFocus = "Kein Anwendungsfenster ist fokussiert.", focusChanged = "Der Fokus hat sich geändert. Bitte erneut versuchen.",
        closed = "Das Quellfenster wurde geschlossen.", moved = "Das Quellfenster hat den Arbeitsbereich gewechselt. Bitte erneut versuchen.",
        notColumn = "Das Quellfenster gehört zu keiner Niri-Spalte (schwebend/Scratchpad/unbekannt).",
        columnChanged = "Die Quellspalte wurde bei geöffnetem Menü geändert. Bitte erneut versuchen.",
        focusFailed = "Der Fokus der Quellspalte konnte nicht wiederhergestellt werden. Verschieben abgebrochen.",
        workspaceGone = "Ein Arbeitsbereich wurde entfernt oder sein Layout geändert. Verschieben abgebrochen.",
        niri = "Beide Arbeitsbereiche müssen das Niri-Layout verwenden.", noWorkspaces = "Keine verfügbaren Arbeitsbereiche.",
        incompatible = "OmniWM 0.7.6 / Protokoll 19 ist erforderlich. Kompatibilität in der Hammerspoon-Konsole prüfen.",
        cliMissing = "omniwmctl wurde nicht gefunden. Den vollständigen Pfad unter cliPath angeben.",
        timeout = "Zeitüberschreitung bei OmniWM. Das Ergebnis des Befehls ist möglicherweise unbekannt.",
        cliFailed = "OmniWM konnte den Befehl nicht ausführen. Details stehen in der Hammerspoon-Konsole.",
        invalidData = "OmniWM hat unerwartete Daten zurückgegeben. Details stehen in der Hammerspoon-Konsole.",
    },
    ru = {
        keyboardUnavailable = "Не удалось перехватить клавиатуру. Проверьте разрешения Hammerspoon и закройте поля паролей (Secure Input).",
        placeholder = "Перенести колонку → воркспейс…", loading = "Загрузка воркспейсов…",
        empty = "Нет приложений", unknownApp = "Неизвестное приложение", noDestinations = "Нет доступных назначений",
        filters = "Проверьте настройки фильтрации", failed = "Не удалось выполнить операцию. Подробности в консоли Hammerspoon.",
        noFocus = "Нет сфокусированного окна приложения.", focusChanged = "Фокус изменился. Повторите попытку.",
        closed = "Исходное окно закрыто.", moved = "Исходное окно сменило воркспейс. Повторите попытку.",
        notColumn = "Исходное окно не принадлежит Niri-колонке (floating/scratchpad/неизвестно).",
        columnChanged = "Исходная колонка изменилась, пока меню было открыто. Повторите попытку.",
        focusFailed = "Не удалось восстановить фокус исходной колонки. Перенос отменён.",
        workspaceGone = "Воркспейс удалён или его раскладка изменилась. Перенос отменён.",
        niri = "Оба воркспейса должны использовать раскладку Niri.", noWorkspaces = "Нет доступных воркспейсов.",
        incompatible = "Требуется OmniWM 0.7.6 / protocol 19. Проверьте совместимость в консоли Hammerspoon.",
        cliMissing = "omniwmctl не найден. Укажите полный путь в cliPath.",
        timeout = "OmniWM не ответил вовремя. Результат команды может быть неизвестен.",
        cliFailed = "OmniWM не смог выполнить команду. Подробности в консоли Hammerspoon.",
        invalidData = "OmniWM вернул неожиданные данные. Подробности в консоли Hammerspoon.",
    },
}

-- Error text remains stable in the CLI/normalization layers for diagnostics.
-- Translate it at the UI boundary, including errors prefixed with a Lua source location.
local errors = {
    { "No native window focused", "noFocus" }, { "no managed window focused", "noFocus" },
    { "Focus changed", "focusChanged" }, { "Source window has closed", "closed" },
    { "Source window changed workspace", "moved" }, { "not in a Niri column", "notColumn" },
    { "Source column changed", "columnChanged" }, { "Could not confirm original column focus", "focusFailed" },
    { "Source or destination workspace was removed", "workspaceGone" },
    { "Workspace was removed or its layout changed", "workspaceGone" },
    { "Both workspaces must use Niri layout", "niri" }, { "No available workspaces", "noWorkspaces" },
    { "Supported OmniWM version", "incompatible" }, { "Required OmniWM commands/queries", "incompatible" },
    { "compatibility has not been verified", "incompatible" }, { "omniwmctl not found", "cliMissing" },
    { "omniwmctl timed out", "timeout" }, { "Invalid CLI JSON", "invalidData" },
    { "Unexpected", "invalidData" }, { "Missing", "invalidData" }, { "Duplicate", "invalidData" },
    { "Invalid workspace", "invalidData" }, { "JSON envelope", "invalidData" },
    { "omniwmctl", "cliFailed" },
}

function M.new(hs)
    local language = "en"
    local locale = hs.host and hs.host.locale
    if locale then
        local ok, preferred = pcall(locale.preferredLanguages)
        local tag = ok and type(preferred) == "table" and preferred[1]
        if not tag then
            local currentOK, current = pcall(locale.current)
            if currentOK then tag = current end
        end
        local code = type(tag) == "string" and tag:lower():match("^([a-z]+)")
        if strings[code] then language = code end
    end
    local self = { language = language }
    function self:text(key) return strings[self.language][key] or strings.en[key] or key end
    function self:error(value)
        local message = tostring(value)
        for _, entry in ipairs(errors) do
            if message:find(entry[1], 1, true) then return self:text(entry[2]) end
        end
        return self:text("failed")
    end
    return self
end
return M

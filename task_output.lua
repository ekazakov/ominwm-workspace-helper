-- Spool CLI output to private files instead of Hammerspoon's competing pipe readers.
local M = {}
local script = 'capture_stdout=$1; capture_stderr=$2; shift 2; exec "$@" > "$capture_stdout" 2> "$capture_stderr"'
function M.new(path, arguments)
    local self = {}
    function self:cleanup()
        if self.stdoutPath then os.remove(self.stdoutPath) end
        if self.stderrPath then os.remove(self.stderrPath) end
    end
    local ok, err = pcall(function()
        -- On macOS, os.tmpname reserves a file with mkstemp and mode 0600.
        self.stdoutPath = os.tmpname()
        self.stderrPath = os.tmpname()
    end)
    if not ok then self:cleanup(); error(err) end
    self.arguments = { "-c", script, "omniwm-output", self.stdoutPath, self.stderrPath, path }
    for _, argument in ipairs(arguments) do self.arguments[#self.arguments + 1] = argument end
    function self:read()
        local function read(path)
            local file, why = io.open(path, "rb")
            assert(file, why)
            local value, readError = file:read("*a")
            file:close()
            assert(value, readError)
            return value
        end
        return read(self.stdoutPath), read(self.stderrPath)
    end
    return self
end
return M

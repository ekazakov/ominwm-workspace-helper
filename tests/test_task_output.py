"""Exercise the production capture arguments with real subprocesses and large output."""
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

LUA = r'''
local args
if os.getenv("TASK_OUTPUT_LIVE") == "1" then
    args = { "query", "capabilities", "--format", "json" }
else
    args = { "-c", os.getenv("TASK_OUTPUT_PROGRAM"), os.getenv("TASK_OUTPUT_ARGUMENT") }
end
local output = require("task_output").new(os.getenv("TASK_OUTPUT_EXECUTABLE"), args)
for _, value in ipairs(output.arguments) do io.write(value, "\0") end
'''


def capture(executable, program="", argument="", live=False):
    environment = dict(os.environ, TASK_OUTPUT_EXECUTABLE=executable,
                       TASK_OUTPUT_PROGRAM=program, TASK_OUTPUT_ARGUMENT=argument,
                       TASK_OUTPUT_LIVE="1" if live else "0")
    arguments = subprocess.check_output(["/opt/homebrew/bin/luajit", "-e", LUA], env=environment).split(b"\0")[:-1]
    arguments = [os.fsdecode(value) for value in arguments]
    stdout, stderr = Path(arguments[3]), Path(arguments[4])
    try:
        assert stat.S_IMODE(stdout.stat().st_mode) == 0o600
        assert stat.S_IMODE(stderr.stat().st_mode) == 0o600
        process = subprocess.run(["/bin/sh", *arguments], capture_output=True, timeout=15)
        assert process.stdout == b"" and process.stderr == b""
        return process.returncode, stdout.read_bytes(), stderr.read_bytes()
    finally:
        stdout.unlink(missing_ok=True)
        stderr.unlink(missing_ok=True)


argument = "spaces ' quotes `printf INJECTED` $(printf INJECTED); newline\nЮникод"
program = "import json,sys; print(json.dumps({'value':sys.argv[1], 'large':'🚀'*100000})); sys.stderr.write('error'*30000); sys.exit(7)"
code, stdout, stderr = capture(sys.executable, program, argument)
assert code == 7
assert json.loads(stdout) == {"value": argument, "large": "🚀" * 100000}
assert stderr == b"error" * 30000
print("PASS: large stdout/stderr, Unicode, literal shell characters, exit status, private files, cleanup")

if "--live-cli" in sys.argv:
    code, stdout, stderr = capture("/opt/homebrew/bin/omniwmctl", live=True)
    response = json.loads(stdout)
    assert code == 0 and response["ok"] is True and response["result"]["kind"] == "capabilities"
    print(f"PASS: real OmniWM capabilities response ({len(stdout)} bytes)")

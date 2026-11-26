"""The Windows scripts the workstation's scheduled tasks run, under `windows/`.

They are PowerShell by necessity (each says why in its header), so what Python can hold
them to is that each one parses, and that each writes only under the checkout's ignored
`logs/`: the tasks run them from the static checkout, and a log beside the script would
leave that checkout dirty, which stops the fix pass fast-forwarding it.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tomllib
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPTS = sorted((ROOT / "windows").glob("*.ps1"))
EXPECTED = {
    "d2r-disconnect-guard.ps1",
    "d2r-netlog.ps1",
    "dell-idle-blank.ps1",
    "hardware-health.ps1",
}

PARSE = (
    "$errors = $null; "
    "[System.Management.Automation.Language.Parser]::ParseFile($env:SCRIPT_TO_PARSE,"
    " [ref]$null, [ref]$errors)"
    " | Out-Null; "
    "$errors | ForEach-Object { $_.Message }; "
    "exit $errors.Count"
)


def _shell() -> str:
    found = shutil.which("pwsh") or shutil.which("powershell")
    if not found:
        pytest.fail("neither pwsh nor powershell is on PATH: install PowerShell to parse windows/")
    return found


def test_every_scheduled_script_is_here():
    assert {p.name for p in SCRIPTS} == EXPECTED


@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
def test_each_script_parses(script):
    # The path goes by environment: `-Command` joins any further argument onto the
    # command text, where a path is a parse error of its own.
    done = subprocess.run(  # noqa: S603 - a fixed command over this repo's own files
        [_shell(), "-NoProfile", "-NonInteractive", "-Command", PARSE],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
        env={**os.environ, "SCRIPT_TO_PARSE": str(script)},
    )
    assert done.returncode == 0, done.stdout + done.stderr


@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
def test_each_script_writes_only_under_logs(script):
    text = script.read_text(encoding="utf-8")
    assert "..\\logs" in text, "its output goes to the checkout's ignored logs/"
    assert not re.search(r"C:\\Users\\", text), "no hard-coded home: it runs from the checkout"
    for line in text.splitlines():
        if "Join-Path $PSScriptRoot" in line:
            assert "..\\logs" in line, f"a path beside the script: {line.strip()}"


@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
def test_each_header_states_the_headless_launch(script):
    # The task's action lives in the scheduler, not in this repo, so the header is the
    # only record of it: a bare `powershell.exe` action shows a window at every logon.
    header = []
    for line in script.read_text(encoding="utf-8").splitlines():
        if not line.startswith("#"):
            break
        header.append(line)
    assert "conhost.exe --headless powershell.exe" in " ".join(header)


TASK_NAMED = re.compile(r'^# Runs from the "([^"]+)" scheduled task', re.MULTILINE)


def _claimed_tasks() -> set[str]:
    with (ROOT / ".devkit.toml").open("rb") as fh:
        return set(tomllib.load(fh)["schedule"]["tasks"])


@pytest.mark.parametrize("script", SCRIPTS, ids=lambda p: p.name)
def test_each_scripts_task_is_claimed(script):
    # devkit's fix pass files any hand-made task no project claims as
    # `scheduled-job-unowned`; "Dell Idle Blank" was, before it was claimed here.
    found = TASK_NAMED.search(script.read_text(encoding="utf-8"))
    assert found, 'its header names its task: # Runs from the "<name>" scheduled task'
    assert found.group(1) in _claimed_tasks(), "claim it in .devkit.toml [schedule] tasks"


def test_every_claimed_task_has_its_script():
    named = {m.group(1) for p in SCRIPTS for m in TASK_NAMED.finditer(p.read_text("utf-8"))}
    assert _claimed_tasks() == named

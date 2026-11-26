"""The pure decisions in `windows/dell-idle-blank.ps1`.

The script returns before its Win32 setup when `DELL_IDLE_BLANK_TEST` is set, so a test
can dot-source it and call the decision functions without touching a monitor.
"""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[1] / "windows" / "dell-idle-blank.ps1"


def _ps(expression: str) -> str:
    shell = shutil.which("pwsh") or shutil.which("powershell")
    if not shell:
        pytest.fail("neither pwsh nor powershell is on PATH: install PowerShell to test windows/")
    done = subprocess.run(  # noqa: S603 - a fixed command over this repo's own file
        [
            shell,
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            f". $env:SCRIPT_UNDER_TEST; {expression}",
        ],
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
        env={**os.environ, "SCRIPT_UNDER_TEST": str(SCRIPT), "DELL_IDLE_BLANK_TEST": "1"},
    )
    assert done.returncode == 0, done.stdout + done.stderr
    return done.stdout.strip()


@pytest.mark.parametrize(
    ("idle", "blanked", "game_on_dell", "expected"),
    [
        (30, False, False, "none"),  # active: leave it on
        (600, False, False, "off"),  # idle for exactly the timeout
        (5000, False, False, "off"),  # long idle, e.g. Kodi playing all evening
        (5000, False, True, "none"),  # a game focused on the Dell keeps it on
        (5000, True, False, "none"),  # already in standby: do not resend
        (1, True, False, "on"),  # input came back
        (1, True, True, "on"),  # input came back while a game is in front
    ],
)
def test_blank_action(idle, blanked, game_on_dell, expected):
    b = "$true" if blanked else "$false"
    g = "$true" if game_on_dell else "$false"
    assert _ps(f"Get-BlankAction {idle} 600 {b} {g}") == expected


@pytest.mark.parametrize(
    ("path", "name", "expected"),
    [
        (r"D:\SteamLibrary\steamapps\common\Hades\Hades.exe", "Hades", "True"),
        (r"C:\Program Files (x86)\Steam\steamapps\common\Portal 2\portal2.exe", "portal2", "True"),
        (r"C:\Program Files (x86)\Diablo II Resurrected\D2R.exe", "D2R", "True"),
        (r"C:\Program Files\Kodi\kodi.exe", "kodi", "False"),
        (r"C:\Program Files (x86)\Steam\steam.exe", "steam", "False"),  # the client is not a game
        ("", "explorer", "False"),  # a process whose path is unreadable
    ],
)
def test_game_process(path, name, expected):
    assert _ps(f"Test-GameProcess -Path '{path}' -Name '{name}'") == expected


def _pad(buttons=0, lt=0, rt=0, lx=0, ly=0, rx=0, ry=0) -> str:
    return (
        f"([pscustomobject]@{{Buttons={buttons};LT={lt};RT={rt};LX={lx};LY={ly};RX={rx};RY={ry}}})"
    )


@pytest.mark.parametrize(
    ("prev", "now", "expected"),
    [
        (_pad(), _pad(), "False"),  # nothing moved
        (_pad(), _pad(buttons=4096), "True"),  # A pressed
        (_pad(), _pad(rt=200), "True"),  # trigger pulled
        (_pad(), _pad(lx=20000), "True"),  # stick pushed
        (_pad(lx=1200, ly=-900), _pad(lx=3000, ly=-2500), "False"),  # drift inside the deadzone
        (_pad(), _pad(lt=20), "False"),  # trigger noise
        ("$null", _pad(buttons=1), "False"),  # a pad just plugged in has no previous state
    ],
)
def test_pad_activity(prev, now, expected):
    assert _ps(f"Test-PadActivity {prev} {now}") == expected

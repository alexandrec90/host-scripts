# D2R hardcore guard: when the Moonlight stream drops, Sunshine logs
# "CLIENT DISCONNECTED". The game keeps running on this PC with the character
# standing still, so we kill D2R immediately. Killing the process closes the
# socket cleanly and the server pulls the character out (the HC "alt-F4" exit).
#
# PowerShell, not Python: a Windows-host tool with no other OS to run on, and the
# 200 ms reaction time is the whole point -- kept exactly as it ran from ~/Scripts.
# Runs from the "D2R Disconnect Guard" scheduled task.
# The task starts it as `conhost.exe --headless powershell.exe ...`: with Windows Terminal as
# the default terminal, `-WindowStyle Hidden` alone still opens a visible window.

$logPath  = 'C:\Program Files\Sunshine\config\sunshine.log'
$logDir   = Join-Path $PSScriptRoot '..\logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$guardLog = Join-Path $logDir 'd2r-disconnect-guard.log'

function Write-GuardLog($msg) {
    "[{0:yyyy-MM-dd HH:mm:ss.fff}] {1}" -f (Get-Date), $msg | Add-Content $guardLog
}

Write-GuardLog 'Guard started'
$pos = (Get-Item $logPath).Length  # only react to lines written from now on

while ($true) {
    try {
        $len = (Get-Item $logPath).Length
        if ($len -lt $pos) { $pos = 0 }  # Sunshine restarted and rotated the log
        if ($len -gt $pos) {
            $fs = [System.IO.FileStream]::new($logPath, 'Open', 'Read', 'ReadWrite')
            $fs.Seek($pos, 'Begin') | Out-Null
            $sr = [System.IO.StreamReader]::new($fs)
            $new = $sr.ReadToEnd()
            $pos = $fs.Position
            $sr.Close()
            if ($new -match 'CLIENT DISCONNECTED') {
                $d2r = Get-Process D2R -ErrorAction SilentlyContinue
                if ($d2r) {
                    $d2r | Stop-Process -Force
                    Write-GuardLog 'Stream disconnected - killed D2R'
                } else {
                    Write-GuardLog 'Stream disconnected - D2R not running'
                }
            }
        }
    } catch {
        Write-GuardLog "Error: $_"
    }
    Start-Sleep -Milliseconds 200
}

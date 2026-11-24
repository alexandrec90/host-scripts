# D2R network logger: while D2R.exe runs, sample its game-server connection once
# a second so rubber-banding / disconnects can be matched to what the network did.
# One CSV per day in d2r-netlog\, plus events.log for connection changes.
#
# Columns: rtt_game / rtt_gw are ms (-1 = lost), rx/tx are kB/s on the Ethernet NIC,
# retrans = TCPv4 segments retransmitted/s (whole machine), warp = WARP adapter up,
# udp = total UDP endpoints (sampled every 10s; >16000 means port exhaustion).
#
# PowerShell, not Python: performance counters, Get-NetTCPConnection and
# Get-NetUDPEndpoint are Windows APIs the standard library has no reach into.
# Runs from the "D2R Net Logger" scheduled task.
# The task starts it as `conhost.exe --headless powershell.exe ...`: with Windows Terminal as
# the default terminal, `-WindowStyle Hidden` alone still opens a visible window.

$outDir = Join-Path $PSScriptRoot '..\logs\d2r-netlog'
New-Item -ItemType Directory -Force $outDir | Out-Null
$events = Join-Path $outDir 'events.log'

function Write-Event($msg) {
    "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg | Add-Content $events
}

$nic = 'Intel[R] Ethernet Connection [14] I219-V'
$rx  = [Diagnostics.PerformanceCounter]::new('Network Interface', 'Bytes Received/sec', $nic)
$tx  = [Diagnostics.PerformanceCounter]::new('Network Interface', 'Bytes Sent/sec', $nic)
$rtx = [Diagnostics.PerformanceCounter]::new('TCPv4', 'Segments Retransmitted/sec')
$gw  = (Get-NetIPConfiguration -InterfaceAlias Ethernet).IPv4DefaultGateway.NextHop

Write-Event 'Logger started'
$lastServers = ''
$udp = 0
$tick = 0

while ($true) {
    try {
        $d2r = Get-Process D2R -ErrorAction SilentlyContinue
        if (-not $d2r) {
            if ($lastServers -ne 'NO_D2R') { Write-Event 'D2R not running'; $lastServers = 'NO_D2R' }
            Start-Sleep 5
            continue
        }

        # Game/lobby servers: D2R's non-loopback, non-HTTPS TCP connections (port 1119 in practice)
        $conns = Get-NetTCPConnection -OwningProcess $d2r[0].Id -State Established -ErrorAction SilentlyContinue |
            Where-Object { $_.RemoteAddress -ne '127.0.0.1' -and $_.RemotePort -ne 443 }
        $servers = ($conns | ForEach-Object { "$($_.RemoteAddress):$($_.RemotePort)" } | Sort-Object -Unique) -join ' '
        if ($servers -ne $lastServers) {
            if ($lastServers -and $lastServers -ne 'NO_D2R' -and -not $servers) {
                Write-Event "GAME CONNECTION LOST (was $lastServers)"
            } else {
                Write-Event "Servers: '$lastServers' -> '$servers'"
            }
            $lastServers = $servers
        }

        $target = @($conns)[0].RemoteAddress
        $pGw = [Net.NetworkInformation.Ping]::new().SendPingAsync($gw, 1000)
        $pGame = if ($target) { [Net.NetworkInformation.Ping]::new().SendPingAsync($target, 1000) }
        try { $pGw.Wait() } catch {}
        if ($pGame) { try { $pGame.Wait() } catch {} }
        $rttGw = if ($pGw.Status -eq 'RanToCompletion' -and $pGw.Result.Status -eq 'Success') { $pGw.Result.RoundtripTime } else { -1 }
        $rttGame = if (-not $pGame) { '' }
                   elseif ($pGame.Status -eq 'RanToCompletion' -and $pGame.Result.Status -eq 'Success') { $pGame.Result.RoundtripTime }
                   else { -1 }

        if ($tick % 10 -eq 0) {
            $udp = (Get-NetUDPEndpoint -ErrorAction SilentlyContinue).Count
            if ($udp -gt 8000) {
                $top = Get-NetUDPEndpoint | Group-Object OwningProcess | Sort-Object Count -Descending | Select-Object -First 1
                Write-Event "HIGH UDP PORT USE: $udp total, top PID $($top.Name) ($((Get-Process -Id $top.Name -ErrorAction SilentlyContinue).ProcessName)) = $($top.Count)"
            }
        }
        $warp = [int]((Get-NetAdapter -Name CloudflareWARP -ErrorAction SilentlyContinue).Status -eq 'Up')

        $csv = Join-Path $outDir ('{0:yyyy-MM-dd}.csv' -f (Get-Date))
        if (-not (Test-Path $csv)) { 'time,server,rtt_game,rtt_gw,rx_kBps,tx_kBps,retrans,warp,udp' | Set-Content $csv }
        '{0:HH:mm:ss},{1},{2},{3},{4:F0},{5:F0},{6:F0},{7},{8}' -f (Get-Date), $target, $rttGame, $rttGw,
            ($rx.NextValue() / 1KB), ($tx.NextValue() / 1KB), $rtx.NextValue(), $warp, $udp |
            Add-Content $csv
        $tick++
    } catch {
        Write-Event "Error: $_"
    }
    Start-Sleep -Milliseconds 1000
}

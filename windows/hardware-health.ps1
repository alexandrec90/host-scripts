# Hourly hardware health check for an always-on PC.
# Logs CPU/GPU/SSD temperature, CPU fan speed and SSD health; raises a toast only when something is wrong.
# Runs from the "Hardware Health Check" scheduled task (elevated: SSD counters need admin).
# The task starts it as `conhost.exe --headless powershell.exe ...`: with Windows Terminal as
# the default terminal, `-WindowStyle Hidden` alone still opens a visible window.
#
# PowerShell, not Python: LibreHardwareMonitorLib is a .NET assembly, the storage
# reliability counters are a CIM cmdlet, and the toast is WinRT -- none reachable from
# the standard library.

$logDir    = Join-Path $PSScriptRoot '..\logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log       = Join-Path $logDir 'hardware-health.log'
$gpuMaxC   = 83   # RTX 3060 Ti starts throttling around 83 C
$ssdMaxC   = 70   # NVMe drives throttle ~75-85 C; warn before that
$ssdWear   = 80   # percent of rated endurance used
$cpuMaxC   = 90   # i5-10400 TjMax is 100 C
$cpuFan    = 'Fan #2'   # only fan header reporting RPM on this board (~950 RPM idle; likely CPU_FAN)
$since     = (Get-Date).AddMinutes(-65)
$alerts    = @()

# CPU and fan, via LibreHardwareMonitorLib (installed with winget; uses the PawnIO driver)
$cpu = $null
try {
    $lhm = (Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Directory -Filter 'LibreHardwareMonitor*')[0].FullName
    Add-Type -Path "$lhm\LibreHardwareMonitorLib.dll"
    $pc = New-Object LibreHardwareMonitor.Hardware.Computer
    $pc.IsCpuEnabled = $true; $pc.IsMotherboardEnabled = $true
    $pc.Open()
    $sensors = foreach ($h in $pc.Hardware) {
        $h.Update(); $h.Sensors
        foreach ($sub in $h.SubHardware) { $sub.Update(); $sub.Sensors }
    }
    $pc.Close()
    $pkg  = ($sensors | Where-Object { $_.SensorType -eq 'Temperature' -and $_.Name -eq 'CPU Package' }).Value
    $watt = ($sensors | Where-Object { $_.SensorType -eq 'Power' -and $_.Name -eq 'CPU Package' }).Value
    $rpm  = ($sensors | Where-Object { $_.SensorType -eq 'Fan' -and $_.Name -eq $cpuFan }).Value
    $cpu  = "CPU {0:N0}C {1:N0}W fan {2:N0}rpm" -f $pkg, $watt, $rpm
    if ($pkg -ge $cpuMaxC) { $alerts += "CPU at $([int]$pkg)C" }
    if ($rpm -lt 200)      { $alerts += "CPU fan ($cpuFan) stopped: $([int]$rpm) rpm" }
} catch {
    $cpu = "CPU sensors unavailable: $($_.Exception.Message)"
}

# GPU
$gpu = $null
try {
    $q = & nvidia-smi --query-gpu=temperature.gpu,power.draw,fan.speed --format=csv,noheader,nounits 2>$null
    if ($q) {
        $t, $p, $f = ($q -split ',') | ForEach-Object { $_.Trim() }
        $gpu = "GPU ${t}C ${p}W fan ${f}%"
        if ([int]$t -ge $gpuMaxC) { $alerts += "GPU at ${t}C" }
    }
} catch {}

# SSD
$ssd = @()
foreach ($d in Get-PhysicalDisk) {
    $r = $d | Get-StorageReliabilityCounter -ErrorAction SilentlyContinue
    $ssd += "$($d.FriendlyName) $($r.Temperature)C (max $($r.TemperatureMax)C) wear $($r.Wear)% $($d.HealthStatus)"
    if ($d.HealthStatus -ne 'Healthy')          { $alerts += "$($d.FriendlyName) health: $($d.HealthStatus)" }
    if ($r.Temperature -ge $ssdMaxC)            { $alerts += "$($d.FriendlyName) at $($r.Temperature)C" }
    if ($r.Wear -ge $ssdWear)                   { $alerts += "$($d.FriendlyName) wear $($r.Wear)%" }
}

# Hardware errors and unclean shutdowns in the last hour
$events = Get-WinEvent -FilterHashtable @{ LogName = 'System'; StartTime = $since; Level = 1,2,3
    ProviderName = 'Microsoft-Windows-WHEA-Logger','disk','stornvme','Ntfs' } -ErrorAction SilentlyContinue
if ($events) { $alerts += "$($events.Count) hardware/disk error event(s): $(($events.ProviderName | Sort-Object -Unique) -join ', ')" }
if (Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41; StartTime = $since } -ErrorAction SilentlyContinue) {
    $alerts += 'Unexpected shutdown (power loss or crash) detected'
}

$line = "{0:yyyy-MM-dd HH:mm}  {1}  |  {2}  |  {3}" -f (Get-Date), $cpu, $gpu, ($ssd -join '; ')
if ($alerts) { $line += "  |  ALERT: " + ($alerts -join '; ') }
Add-Content -Path $log -Value $line

# Keep the log to ~90 days of hourly lines
$lines = Get-Content $log
if ($lines.Count -gt 2200) { $lines | Select-Object -Last 2160 | Set-Content $log }

if ($alerts) {
    [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
    $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
    $text = $xml.GetElementsByTagName('text')
    $text.Item(0).InnerText = 'Hardware health warning'
    $text.Item(1).InnerText = $alerts -join "`n"
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show([Windows.UI.Notifications.ToastNotification]::new($xml))
}

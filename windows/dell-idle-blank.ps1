# Puts the Dell U2412M into standby after the PC has been idle for a while, even while Kodi
# or a game keeps the plasma TV playing, and wakes it on the next keyboard, mouse or
# controller input. Playback holds a "display required" request, which keeps Windows' own
# monitor timeout from ever firing, so without this the Dell stays lit all night.
# Runs from the "Dell Idle Blank" scheduled task (at logon, not elevated).
# The task starts it as `conhost.exe --headless powershell.exe ...`: with Windows Terminal as
# the default terminal, `-WindowStyle Hidden` alone still opens a visible window.
#
# The Dell is switched over DDC/CI (VCP 0xD6, through dxva2.dll) rather than by removing it
# from the Windows display layout: a layout change moves windows and makes a fullscreen
# game or Kodi on the TV reset its mode. A game focused on the Dell keeps it on, and
# controller input (XInput, which Windows' idle clock ignores) counts as activity.
#
# PowerShell, not Python: GetLastInputInfo, dxva2's monitor calls and XInput are Win32
# APIs the standard library cannot reach without ctypes structure plumbing PowerShell's
# Add-Type does in place, and the task runs in the logged-on session with no venv.

param(
    [int]$IdleMinutes = 10,          # matches the power plan's monitor timeout
    [int]$PollSeconds = 2,
    [string]$MonitorId = 'DELA07A'   # Dell U2412M's hardware ID, from its EDID
)

# Pure decision: what to do with the Dell this tick.
#   'off'  -- idle long enough, Dell is on, and no game is in front on it
#   'on'   -- input came back while we had it in standby
#   'none' -- nothing to change
function Get-BlankAction([double]$IdleSeconds, [double]$TimeoutSeconds, [bool]$Blanked, [bool]$GameOnDell) {
    if ($Blanked) {
        if ($IdleSeconds -lt $TimeoutSeconds) { return 'on' }
        return 'none'
    }
    if ($GameOnDell) { return 'none' }
    if ($IdleSeconds -ge $TimeoutSeconds) { return 'off' }
    return 'none'
}

# Pure: is this executable a game? Steam installs every game under steamapps\common;
# Diablo II: Resurrected comes from Battle.net, so it is named.
function Test-GameProcess([string]$Path, [string]$Name) {
    if ($Name -eq 'D2R') { return $true }
    if ($Path -and $Path -match '\\steamapps\\common\\') { return $true }
    return $false
}

# Pure: does a controller report a real change? Stick drift wobbles the packet counter, so
# only buttons, a trigger pull or a stick moved past the deadzone count as input.
function Test-PadActivity($Prev, $Now) {
    if ($null -eq $Prev -or $null -eq $Now) { return $false }
    if ($Prev.Buttons -ne $Now.Buttons) { return $true }
    foreach ($k in 'LT', 'RT') { if ([math]::Abs($Now.$k - $Prev.$k) -gt 30) { return $true } }
    foreach ($k in 'LX', 'LY', 'RX', 'RY') { if ([math]::Abs($Now.$k - $Prev.$k) -gt 8000) { return $true } }
    return $false
}

if ($env:DELL_IDLE_BLANK_TEST) { return }   # the tests dot-source the functions above

$logDir = Join-Path $PSScriptRoot '..\logs'
New-Item -ItemType Directory -Force $logDir | Out-Null
$log = Join-Path $logDir 'dell-idle-blank.log'
function Write-BlankLog($msg) { "[{0:yyyy-MM-dd HH:mm:ss}] {1}" -f (Get-Date), $msg | Add-Content $log }

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

// Top level, not nested in DellBlank: Windows PowerShell 5.1 cannot name a nested type.
[StructLayout(LayoutKind.Sequential)] public struct DellBlankPad { public uint Packet;
    public ushort Buttons; public byte LT, RT; public short LX, LY, RX, RY; }

public static class DellBlank {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct PHYSICAL_MONITOR { public IntPtr h;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string desc; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct MONITORINFOEX { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct DISPLAY_DEVICE { public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey; }
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    delegate bool MonitorEnumProc(IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr hMon, ref MONITORINFOEX mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern bool EnumDisplayDevices(string dev, uint i, ref DISPLAY_DEVICE dd, uint flags);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO li);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr hWnd, uint flags);
    [DllImport("kernel32.dll")] static extern ulong GetTickCount64();
    [DllImport("xinput1_4.dll")] public static extern uint XInputGetState(uint pad, out DellBlankPad s);
    [DllImport("dxva2.dll")] static extern bool GetNumberOfPhysicalMonitorsFromHMONITOR(IntPtr hMon, out uint n);
    [DllImport("dxva2.dll")] static extern bool GetPhysicalMonitorsFromHMONITOR(IntPtr hMon, uint n, [Out] PHYSICAL_MONITOR[] arr);
    [DllImport("dxva2.dll")] static extern bool DestroyPhysicalMonitor(IntPtr h);
    [DllImport("dxva2.dll")] static extern bool GetVCPFeatureAndVCPFeatureReply(IntPtr h, byte code, IntPtr type, out uint cur, out uint max);
    [DllImport("dxva2.dll")] static extern bool SetVCPFeature(IntPtr h, byte code, uint value);

    // Seconds since the last keyboard or mouse input in this session.
    public static double IdleSeconds() {
        var li = new LASTINPUTINFO(); li.cbSize = (uint)Marshal.SizeOf(li);
        if (!GetLastInputInfo(ref li)) return 0;
        return (uint)((uint)GetTickCount64() - li.dwTime) / 1000.0;
    }

    // HMONITOR of the display whose hardware ID contains idPart, or zero.
    public static IntPtr FindMonitor(string idPart) {
        IntPtr found = IntPtr.Zero;
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, delegate (IntPtr hMon, IntPtr hdc, ref RECT r, IntPtr d) {
            var mi = new MONITORINFOEX(); mi.cbSize = Marshal.SizeOf(mi);
            if (!GetMonitorInfo(hMon, ref mi)) return true;
            var dd = new DISPLAY_DEVICE(); dd.cb = Marshal.SizeOf(dd);
            for (uint i = 0; EnumDisplayDevices(mi.szDevice, i, ref dd, 0); i++) {
                if (dd.DeviceID != null && dd.DeviceID.IndexOf(idPart, StringComparison.OrdinalIgnoreCase) >= 0) {
                    found = hMon; return false;
                }
                dd.cb = Marshal.SizeOf(dd);
            }
            return true;
        }, IntPtr.Zero);
        return found;
    }

    // One VCP get (setValue < 0: returns the value) or set (returns 1), -1 on failure.
    public static long Vcp(IntPtr hMon, byte code, long setValue) {
        uint n;
        if (hMon == IntPtr.Zero || !GetNumberOfPhysicalMonitorsFromHMONITOR(hMon, out n) || n == 0) return -1;
        var arr = new PHYSICAL_MONITOR[n];
        if (!GetPhysicalMonitorsFromHMONITOR(hMon, n, arr)) return -1;
        try {
            if (setValue >= 0) return SetVCPFeature(arr[0].h, code, (uint)setValue) ? 1 : -1;
            uint cur, max;
            return GetVCPFeatureAndVCPFeatureReply(arr[0].h, code, IntPtr.Zero, out cur, out max) ? (long)cur : -1L;
        } finally { foreach (var m in arr) DestroyPhysicalMonitor(m.h); }
    }
}
'@

$VCP_POWER = 0xD6   # 1 = on, 4 = standby (DDC can wake it), 5 = hard off (needs the button)

function Get-PadStates {
    $states = @{}
    foreach ($i in 0..3) {
        $s = New-Object DellBlankPad
        if ([DellBlank]::XInputGetState($i, [ref]$s) -eq 0) {
            $states[$i] = [pscustomobject]@{ Buttons = $s.Buttons; LT = $s.LT; RT = $s.RT
                LX = $s.LX; LY = $s.LY; RX = $s.RX; RY = $s.RY }
        }
    }
    $states
}

function Test-GameOnDell($dell) {
    $hwnd = [DellBlank]::GetForegroundWindow()
    if ($hwnd -eq [IntPtr]::Zero) { return $false }
    if ([DellBlank]::MonitorFromWindow($hwnd, 2) -ne $dell) { return $false }
    $procId = [uint32]0
    [DellBlank]::GetWindowThreadProcessId($hwnd, [ref]$procId) | Out-Null
    $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    Test-GameProcess -Path $p.Path -Name $p.ProcessName
}

Write-BlankLog "Watcher started (idle $IdleMinutes min)"
$timeout = $IdleMinutes * 60
$blanked = $false
$pads = Get-PadStates
$lastPadInput = Get-Date

try {
    while ($true) {
        try {
            $now = Get-PadStates
            foreach ($k in $now.Keys) { if (Test-PadActivity $pads[$k] $now[$k]) { $lastPadInput = Get-Date } }
            $pads = $now

            $idle = [math]::Min([DellBlank]::IdleSeconds(), ((Get-Date) - $lastPadInput).TotalSeconds)
            $dell = [DellBlank]::FindMonitor($MonitorId)
            if ($dell -ne [IntPtr]::Zero) {
                $action = Get-BlankAction $idle $timeout $blanked (Test-GameOnDell $dell)
                if ($action -eq 'off') {
                    if ([DellBlank]::Vcp($dell, $VCP_POWER, 4) -eq 1) { $blanked = $true; Write-BlankLog 'Idle: Dell to standby' }
                } elseif ($action -eq 'on') {
                    # Right after Windows wakes its displays the DDC bus can refuse a command;
                    # stay "blanked" until the Dell confirms it is on, and retry next tick.
                    [DellBlank]::Vcp($dell, $VCP_POWER, 1) | Out-Null
                    Start-Sleep -Milliseconds 500
                    if ([DellBlank]::Vcp($dell, $VCP_POWER, -1) -eq 1) { $blanked = $false; Write-BlankLog 'Input: Dell back on' }
                }
            }
        } catch {
            Write-BlankLog "Tick failed: $($_.Exception.Message)"
        }
        Start-Sleep -Seconds $PollSeconds
    }
} finally {
    if ($blanked) { [DellBlank]::Vcp([DellBlank]::FindMonitor($MonitorId), $VCP_POWER, 1) | Out-Null }
}

#Requires -RunAsAdministrator
<#
    GameBoost v1.2 - Gamepad Edition
    - Своё консольное окно (крестик = в трей)
    - Самодиагностика при старте
    - Трей не может уронить запуск
    - Heroic авто-буст, Ctrl+Alt+B, автозапуск через планировщик
    - ГЕЙМПАД: мёртвые зоны (Circular/Square/Cross), визуализация стиков
    - БЕЗ авто-починки звука
#>

param(
    [switch]$Hidden
)

#region === БАЗА ===

$ErrorActionPreference = 'SilentlyContinue'

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

$ScriptDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$ConfigPath = Join-Path $ScriptDir 'GameBoost_config.ini'

$script:LogPath          = Join-Path $ScriptDir 'GameBoost_log.txt'
$script:Config           = $null
$script:Paused           = $false
$script:ExitRequested    = $false
$script:AllowClose       = $false
$script:Form             = $null
$script:Rtb              = $null
$script:Tray             = $null
$script:Hotkey           = $null
$script:MenuPause        = $null
$script:MenuHeroic       = $null
$script:MenuStartup      = $null
$script:LastProcessCheck = [datetime]::MinValue
$script:LastOptCheck     = [datetime]::MinValue

$mutex = New-Object System.Threading.Mutex($false, 'Global\GameBoost_v12')
if (-not $mutex.WaitOne(0, $false)) {
    [System.Windows.Forms.MessageBox]::Show(
        'GameBoost уже запущен. Закрой его через трей: ПКМ -> Выход.',
        'GameBoost'
    )
    exit
}

#endregion

#region === NATIVE (C#) ===

try {
    if (-not ('User32Foreground' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class User32Foreground {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@
    }
} catch {}

try {
    if (-not ('NtTimer' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class NtTimer {
    [DllImport("ntdll.dll")]
    public static extern int NtSetTimerResolution(uint DesiredResolution, bool SetResolution, out uint CurrentResolution);
}
'@
    }
} catch {}

try {
    if (-not ('MemTrim' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class MemTrim {
    [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
    [DllImport("psapi.dll")]    public static extern bool EmptyWorkingSet(IntPtr h);
    public static bool Trim(int pid) {
        IntPtr h = OpenProcess(0x0400 | 0x0100, false, pid);
        if (h == IntPtr.Zero) return false;
        bool ok = EmptyWorkingSet(h);
        CloseHandle(h);
        return ok;
    }
}
'@
    }
} catch {}

try {
    if (-not ('GbHotkey' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;
public class GbHotkey : NativeWindow {
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint fsModifiers, uint vk);
    public const int WM_HOTKEY = 0x0312;
    public static int HotkeyCount = 0;
    public void Setup() {
        CreateHandle(new CreateParams());
        RegisterHotKey(Handle, 1, 0x0002 | 0x0004, 0x42);
    }
    protected override void WndProc(ref Message m) {
        if (m.Msg == WM_HOTKEY) Interlocked.Increment(ref HotkeyCount);
        base.WndProc(ref m);
    }
}
'@ -ReferencedAssemblies 'System.Windows.Forms'
    }
} catch {}

#endregion

#region === УТИЛИТЫ ===

function ConvertTo-Bool {
    param([string]$Value, [bool]$Default = $false)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }
    $v = $Value.Trim().ToLower()
    if (@('1', 'true', 'yes', 'on', 'enabled') -contains $v) { return $true }
    if (@('0', 'false', 'no', 'off', 'disabled') -contains $v) { return $false }
    return $Default
}

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    if (-not $script:Config -or -not $script:Config.EnableLog) { return }
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Add-Content -LiteralPath $script:LogPath -Value $line -ErrorAction SilentlyContinue
}

function Set-IniValue {
    param([string]$Key, [string]$Value)
    if (-not (Test-Path $ConfigPath)) { return }
    try {
        $content = Get-Content $ConfigPath -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($content)) {
            Set-Content -Path $ConfigPath -Value "$Key=$Value" -Encoding UTF8
            return
        }
        $escaped = [regex]::Escape($Key)
        $pattern = "(?mi)^(\s*$escaped\s*=).*$"
        $safe = $Value.Replace('$', '$$')
        if ($content -match $pattern) {
            $content = $content -replace $pattern, ('$1' + $safe)
            Set-Content -Path $ConfigPath -Value $content -Encoding UTF8 -NoNewline
        }
        else {
            Add-Content -Path $ConfigPath -Value "$Key=$Value" -Encoding UTF8
        }
    }
    catch { Write-Log "Set-IniValue error: $_" 'WARN' }
}

function Add-ProcessToConfigList {
    param([string]$Key, [string]$ProcessName)
    if ([string]::IsNullOrWhiteSpace($ProcessName)) { return }
    try {
        if (-not (Test-Path $ConfigPath)) {
            Set-Content -Path $ConfigPath -Value "$Key=$ProcessName" -Encoding UTF8
            return
        }
        $content = Get-Content $ConfigPath -Raw -Encoding UTF8
        $escaped = [regex]::Escape($Key)
        $m = [regex]::Match($content, "(?mi)^\s*$escaped\s*=(.*)$")
        if ($m.Success) {
            $items = @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($items -notcontains $ProcessName) {
                $items += $ProcessName
                $newValue = ($items -join ',').Replace('$', '$$')
                $content = $content -replace "(?mi)^(\s*$escaped\s*=).*$", ('$1' + $newValue)
                Set-Content -Path $ConfigPath -Value $content -Encoding UTF8 -NoNewline
            }
        }
        else {
            Add-Content -Path $ConfigPath -Value "$Key=$ProcessName" -Encoding UTF8
        }
    }
    catch { Write-Log "Add-ProcessToConfigList error: $_" 'WARN' }
}

function Get-ForegroundProcessId {
    try {
        $hwnd = [User32Foreground]::GetForegroundWindow()
        if ($hwnd -eq [IntPtr]::Zero) { return 0 }
        $procId = 0
        [void][User32Foreground]::GetWindowThreadProcessId($hwnd, [ref]$procId)
        return [int]$procId
    }
    catch { return 0 }
}

function Test-NameMatch {
    param([string]$Name, [array]$List)
    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    foreach ($item in $List) {
        if ([string]::IsNullOrWhiteSpace($item)) { continue }
        if ($Name -like $item.ToLower()) { return $true }
    }
    return $false
}

function Set-SafePriority {
    param($Process, [string]$Class)
    try {
        if ($Process.PriorityClass -ne $Class) {
            $Process.PriorityClass = $Class
            return $true
        }
    }
    catch {}
    return $false
}

function Set-RegistryDword {
    param([string]$Path, [string]$Name, [object]$Value, [bool]$Create = $true)
    try {
        if (-not (Test-Path $Path)) {
            if ($Create) { New-Item -Path $Path -Force | Out-Null }
            else { return }
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type DWord -Force | Out-Null
    }
    catch {}
}

function Set-RegistryString {
    param([string]$Path, [string]$Name, [string]$Value, [bool]$Create = $false)
    try {
        if (-not (Test-Path $Path)) {
            if ($Create) { New-Item -Path $Path -Force | Out-Null }
            else { return }
        }
        Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type String -Force | Out-Null
    }
    catch {}
}

function Set-TimerResolution {
    try {
        $current = [uint32]0
        [void][NtTimer]::NtSetTimerResolution([uint32]5000, $true, [ref]$current)
    }
    catch {}
}

function Get-ActivePowerPlan {
    try {
        $out = & powercfg /getactivescheme 2>$null
        if ($out -match '\((.+)\)') { return $matches[1] }
        return 'неизвестно'
    }
    catch { return 'неизвестно' }
}

function Test-IsAdmin {
    try {
        $id = [Security.Principal.WindowsIdentity]::GetCurrent()
        $pr = New-Object Security.Principal.WindowsPrincipal($id)
        return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

#endregion

#region === КОНФИГ ===

function Read-Config {
    $cfg = @{
        EnableLog = $false
        LogPath = ''
        LowPriority = @('Discord', 'DiscordPTB', 'DiscordCanary', 'chrome', 'msedge', 'brave', 'opera')
        HighPriority = @('cs2', 'csgo', 'valorant', 'RocketLeague', 'dota2', 'FortniteClient-Win64', 'eldenring', 'GTA5', 'apex', 'rustclient', 'League of Legends', 'Wow', 'Wow-64', 'Destiny2', 'Warframe')
        LowPriorityClass = 'BelowNormal'
        HighPriorityClass = 'High'
        ProcessCheckInterval = 3
        OnlyForegroundGame = $false
        TrimLowPriorityMemory = $true
        HeroicMode = $true
        HeroicLauncherPriority = 'BelowNormal'
        HeroicSettingsBoost = $true
        HeroicGameProcesses = @()
        HotkeyEnabled = $true
        ApplyOptimizations = $true
        OptimizationCheckInterval = 10
        PowerPlan = 'HighPerformance'
        DisableGameDVR = $true
        DisableFullscreenOptimizations = $true
        DisablePowerThrottling = $true
        NetworkThrottling = $true
        DisableNagle = $true
        TimerResolution = $true
        GameTaskPriority = $true
        HardwareGPU = $false
    }

    if (-not (Test-Path $ConfigPath)) { return $cfg }

    foreach ($raw in (Get-Content $ConfigPath -Encoding UTF8)) {
        $line = $raw.Trim()
        if (-not $line) { continue }
        if ($line.StartsWith(';')) { continue }
        if ($line.StartsWith('#')) { continue }
        if ($line.StartsWith('[')) { continue }

        if ($line -match '^([^=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()

            switch ($key) {
                'EnableLog'        { $cfg.EnableLog = ConvertTo-Bool $val }
                'LogPath'          { if ($val) { $cfg.LogPath = $val } }
                'LowPriority'      { $cfg.LowPriority = @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                'HighPriority'     { $cfg.HighPriority = @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                'LowPriorityClass' { if ($val -match '^(Idle|BelowNormal|Normal|AboveNormal|High)$') { $cfg.LowPriorityClass = $val } }
                'HighPriorityClass'{ if ($val -match '^(Normal|AboveNormal|High)$') { $cfg.HighPriorityClass = $val } }
                'ProcessCheckInterval' {
                    $p = 0
                    if ([int]::TryParse($val, [ref]$p) -and $p -ge 1) { $cfg.ProcessCheckInterval = $p }
                }
                'OnlyForegroundGame'    { $cfg.OnlyForegroundGame = ConvertTo-Bool $val }
                'TrimLowPriorityMemory' { $cfg.TrimLowPriorityMemory = ConvertTo-Bool $val }
                'HeroicMode'            { $cfg.HeroicMode = ConvertTo-Bool $val }
                'HeroicLauncherPriority' { if ($val -match '^(Idle|BelowNormal|Normal|AboveNormal|High)$') { $cfg.HeroicLauncherPriority = $val } }
                'HeroicSettingsBoost'   { $cfg.HeroicSettingsBoost = ConvertTo-Bool $val }
                'HeroicGameProcesses'   { $cfg.HeroicGameProcesses = @($val -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
                'HotkeyEnabled'         { $cfg.HotkeyEnabled = ConvertTo-Bool $val }
                'ApplyOptimizations'    { $cfg.ApplyOptimizations = ConvertTo-Bool $val }
                'OptimizationCheckInterval' {
                    $p = 0
                    if ([int]::TryParse($val, [ref]$p) -and $p -ge 0) { $cfg.OptimizationCheckInterval = $p }
                }
                'PowerPlan'        { if ($val -match '^(HighPerformance|Ultimate|Balanced)$') { $cfg.PowerPlan = $val } }
                'DisableGameDVR'   { $cfg.DisableGameDVR = ConvertTo-Bool $val }
                'DisableFullscreenOptimizations' { $cfg.DisableFullscreenOptimizations = ConvertTo-Bool $val }
                'DisablePowerThrottling' { $cfg.DisablePowerThrottling = ConvertTo-Bool $val }
                'NetworkThrottling' { $cfg.NetworkThrottling = ConvertTo-Bool $val }
                'DisableNagle'     { $cfg.DisableNagle = ConvertTo-Bool $val }
                'TimerResolution'  { $cfg.TimerResolution = ConvertTo-Bool $val }
                'GameTaskPriority' { $cfg.GameTaskPriority = ConvertTo-Bool $val }
                'HardwareGPU'      { $cfg.HardwareGPU = ConvertTo-Bool $val }
            }
        }
    }

    if ($cfg.LogPath) { $script:LogPath = $cfg.LogPath }
    else { $script:LogPath = Join-Path $ScriptDir 'GameBoost_log.txt' }

    return $cfg
}

#endregion

#region === HEROIC ===

function Optimize-HeroicSettings {
    param($Config)
    if (-not $Config.HeroicSettingsBoost) { return }

    $candidates = @(
        (Join-Path $env:APPDATA 'heroic\config.json'),
        (Join-Path $env:USERPROFILE '.config\heroic\config.json')
    )

    foreach ($path in $candidates) {
        if (-not (Test-Path $path)) { continue }
        try {
            $obj = (Get-Content $path -Raw -Encoding UTF8) | ConvertFrom-Json
            if (-not $obj) { continue }

            $changed = $false
            if ($obj.discordRPC -ne $false) {
                Add-Member -InputObject $obj -Name 'discordRPC' -Value $false -MemberType NoteProperty -Force
                $changed = $true
            }
            if ($obj.checkUpdatesEveryLaunch -ne $false) {
                Add-Member -InputObject $obj -Name 'checkUpdatesEveryLaunch' -Value $false -MemberType NoteProperty -Force
                $changed = $true
            }
            if ($obj.disableLogs -ne $true) {
                Add-Member -InputObject $obj -Name 'disableLogs' -Value $true -MemberType NoteProperty -Force
                $changed = $true
            }

            if ($changed) {
                $bak = "$path.gameboost-backup"
                if (-not (Test-Path $bak)) { Copy-Item $path $bak -Force }
                ($obj | ConvertTo-Json -Depth 10) | Set-Content $path -Encoding UTF8
                Write-Log "Heroic config optimized: $path"
            }
        }
        catch { Write-Log "Heroic config patch error: $_" 'WARN' }
    }
}

function Get-ProcessTree {
    try {
        return Get-CimInstance Win32_Process -Property Name, ProcessId, ParentProcessId, ExecutablePath -ErrorAction SilentlyContinue
    }
    catch { return $null }
}

function Test-IsHeroicChild {
    param([int]$ProcId, [hashtable]$ParentOf, [hashtable]$HeroicPids)
    $cur = $ProcId
    for ($i = 0; $i -lt 10; $i++) {
        if (-not $ParentOf.ContainsKey($cur)) { return $false }
        $cur = $ParentOf[$cur]
        if ($cur -eq 0) { return $false }
        if ($HeroicPids.ContainsKey($cur)) { return $true }
    }
    return $false
}

#endregion

#region === ОПТИМИЗАЦИИ WINDOWS ===

function Apply-WindowsOptimizations {
    param($Config, [switch]$Force)

    if (-not $Config) { return }
    if (-not $Config.ApplyOptimizations -and -not $Force) { return }

    try {
        $guid = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
        if ($Config.PowerPlan -eq 'Balanced') { $guid = '381b4222-f694-41f0-9685-ff5bb260df2e' }
        if ($Config.PowerPlan -eq 'Ultimate') { $guid = 'e9a42b02-d5df-448d-aa00-03f14749eb61' }
        $null = & powercfg /setactive $guid 2>$null
    }
    catch {}

    if ($Config.DisableGameDVR) {
        $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        Set-RegistryDword $mm 'GameDVR_Enabled' 0 $false
        Set-RegistryDword $mm 'GameDVR_FSEBehaviorMode' 2 $false
        Set-RegistryDword 'HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 0 $true
        Set-RegistryDword 'HKCU:\Software\Microsoft\GameBar' 'UseNexusForGameBarEnabled' 0 $true
        Set-RegistryDword 'HKCU:\Software\Microsoft\GameBar' 'ShowStartupPanel' 0 $true
    }

    if ($Config.DisableFullscreenOptimizations) {
        Set-RegistryDword 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehaviorMode' 2 $false
        Set-RegistryDword 'HKCU:\System\GameConfigStore' 'GameDVR_FSEBehavior' 2 $false
    }

    if ($Config.DisablePowerThrottling) {
        Set-RegistryDword 'HKLM:\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 1 $true
    }

    if ($Config.NetworkThrottling) {
        Set-RegistryDword 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' 'NetworkThrottlingIndex' ([uint32]::MaxValue) $false
    }

    if ($Config.DisableNagle) {
        Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces' -ErrorAction SilentlyContinue | ForEach-Object {
            Set-RegistryDword $_.PSPath 'TcpAckFrequency' 1 $false
            Set-RegistryDword $_.PSPath 'TCPNoDelay' 1 $false
        }
    }

    if ($Config.GameTaskPriority) {
        $mm = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile'
        Set-RegistryDword $mm 'SystemResponsiveness' 0 $false
        $games = Join-Path $mm 'Tasks\Games'
        Set-RegistryDword $games 'GPU Priority' 8 $true
        Set-RegistryDword $games 'Priority' 6 $true
        Set-RegistryString $games 'Scheduling Category' 'High' $true
        Set-RegistryString $games 'SFIO Priority' 'High' $true
    }

    if ($Config.HardwareGPU) {
        Set-RegistryDword 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode' 2 $true
    }

    if ($Config.TimerResolution) { Set-TimerResolution }
}

#endregion

#region === ПРИОРИТЕТЫ + RAM ===

function Set-ProcessPriorities {
    param($Config)

    $low = @($Config.LowPriority)
    $high = @($Config.HighPriority)
    $heroicGames = @($Config.HeroicGameProcesses)

    $heroicPids = @{}
    $parentOf = @{}
    if ($Config.HeroicMode) {
        $tree = Get-ProcessTree
        if ($tree) {
            foreach ($w in $tree) {
                $isHeroic = ($w.Name -match 'heroic|legendary') -or
                            ($w.ExecutablePath -and ($w.ExecutablePath -match 'heroic|legendary'))
                if ($isHeroic) { $heroicPids[[int]$w.ProcessId] = $true }
                $parentOf[[int]$w.ProcessId] = [int]$w.ParentProcessId
            }
        }
    }

    $fgId = 0
    if ($Config.OnlyForegroundGame) { $fgId = Get-ForegroundProcessId }

    $protectedNames = @('idle','system','csrss','wininit','winlogon','services','lsass','smss','svchost','dwm','conhost','powershell','pwsh','cmd','gameboost')

    $procs = Get-Process -ErrorAction SilentlyContinue
    if (-not $procs) { return }

    foreach ($p in $procs) {
        try { if ($p.Id -eq $PID) { continue } } catch {}
        try { $name = $p.ProcessName.ToLower() } catch { continue }
        if ($protectedNames -contains $name) { continue }

        if ($Config.HeroicMode -and (($name -match 'heroic|legendary') -or $heroicPids.ContainsKey($p.Id))) {
            if ($name -match 'heroic|legendary') {
                if (Set-SafePriority $p $Config.HeroicLauncherPriority) {
                    Write-Log "Heroic launcher: $name -> $($Config.HeroicLauncherPriority)"
                }
            }
            continue
        }

        if (Test-NameMatch $name $low) {
            if (Set-SafePriority $p $Config.LowPriorityClass) {
                Write-Log "Low: $name -> $($Config.LowPriorityClass)"
            }
            if ($Config.TrimLowPriorityMemory) {
                try { [void][MemTrim]::Trim($p.Id) } catch {}
            }
            continue
        }

        $canHigh = $true
        if ($Config.OnlyForegroundGame) { $canHigh = ($p.Id -eq $fgId) }
        if (-not $canHigh) { continue }

        if ($Config.HeroicMode -and (Test-IsHeroicChild $p.Id $parentOf $heroicPids)) {
            if (Set-SafePriority $p $Config.HighPriorityClass) {
                Write-Log "Heroic game (auto): $name -> $($Config.HighPriorityClass)"
            }
            continue
        }

        if ($Config.HeroicMode -and (Test-NameMatch $name $heroicGames)) {
            if (Set-SafePriority $p $Config.HighPriorityClass) {
                Write-Log "Heroic game: $name -> $($Config.HighPriorityClass)"
            }
            continue
        }

        if (Test-NameMatch $name $high) {
            if (Set-SafePriority $p $Config.HighPriorityClass) {
                Write-Log "High: $name -> $($Config.HighPriorityClass)"
            }
        }
    }
}

#endregion

#region === АВТОЗАПУСК ===

function Get-TaskName { 'GameBoost' }

function Test-StartupEnabled {
    try {
        $null = & schtasks /query /tn (Get-TaskName) 2>$null
        return ($LASTEXITCODE -eq 0)
    }
    catch { return $false }
}

function Add-ToStartup {
    try {
        $startupFolder = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Startup)
        $oldLnk = Join-Path $startupFolder 'GameBoost Lite.lnk'
        if (Test-Path $oldLnk) { Remove-Item $oldLnk -Force }
        $oldLnk2 = Join-Path $startupFolder 'GameBoost.lnk'
        if (Test-Path $oldLnk2) { Remove-Item $oldLnk2 -Force }
        $oldWrap = Join-Path $ScriptDir 'GameBoost_Startup.ps1'
        if (Test-Path $oldWrap) { Remove-Item $oldWrap -Force }

        $ps1 = Join-Path $ScriptDir 'GameBoost.ps1'
        $tr = "powershell.exe -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$ps1`" -Hidden"
        $null = & schtasks /create /tn (Get-TaskName) /tr $tr /sc onlogon /rl highest /f 2>$null
        Write-Log 'Startup: task created'
        return ($LASTEXITCODE -eq 0)
    }
    catch {
        Write-Log "Startup add error: $_" 'WARN'
        return $false
    }
}

function Remove-FromStartup {
    try {
        $null = & schtasks /delete /tn (Get-TaskName) /f 2>$null
        Write-Log 'Startup: task removed'
        return $true
    }
    catch { return $false }
}

#endregion

#region === КОНСОЛЬНОЕ ОКНО ===

function Write-Con {
    param([string]$Text, [string]$Color = 'White')
    if (-not $script:Rtb) { return }
    try {
        $script:Rtb.SelectionStart = $script:Rtb.TextLength
        $script:Rtb.SelectionLength = 0
        try { $script:Rtb.SelectionColor = [System.Drawing.Color]::FromName($Color) }
        catch { $script:Rtb.SelectionColor = [System.Drawing.Color]::White }
        $script:Rtb.AppendText($Text + "`r`n")
        $script:Rtb.SelectionColor = [System.Drawing.Color]::White
        $script:Rtb.ScrollToCaret()
    }
    catch {}
}

function Clear-Con {
    try { $script:Rtb.Clear() } catch {}
}

function Show-UiMessage {
    param([string]$Message, [string]$Color = 'Green')
    Write-Con "  $Message" $Color
    Write-Log $Message
}

function Show-Balloon {
    param([string]$Text)
    if (-not $script:Tray) { return }
    try {
        $script:Tray.ShowBalloonTip(3000, 'GameBoost v1.1', $Text, [System.Windows.Forms.ToolTipIcon]::Info)
    }
    catch {}
}

function Hide-ConsoleWindow {
    try { $script:Form.Hide() } catch {}
    Show-Balloon 'GameBoost работает в трее. ПКМ по иконке - меню.'
}

function Show-ConsoleWindow {
    try {
        $script:Form.Show()
        $script:Form.WindowState = 'Normal'
        $script:Form.BringToFront()
        Show-Menu
        Invoke-SelfTest
    }
    catch {}
}

function Show-Status {
    Write-Con '' 'Cyan'
    Write-Con '  --- Статус ---' 'Cyan'

    $state = if ($script:Paused) { 'пауза' } else { 'активен' }
    $stateColor = if ($script:Paused) { 'Yellow' } else { 'Green' }
    Write-Con "  Состояние: $state" $stateColor

    $heroic = if ($script:Config.HeroicMode) { 'вкл' } else { 'выкл' }
    Write-Con "  Heroic профиль: $heroic" 'Cyan'

    $startup = if (Test-StartupEnabled) { 'вкл' } else { 'выкл' }
    Write-Con "  Автозапуск: $startup" 'Cyan'

    $hotkey = if ($script:Hotkey) { 'Ctrl+Alt+B' } else { 'выкл' }
    Write-Con "  Горячая клавиша: $hotkey" 'Cyan'

    $plan = Get-ActivePowerPlan
    Write-Con "  Схема питания: $plan" 'Cyan'

    $all = Get-Process -ErrorAction SilentlyContinue
    $lowCount = 0
    $highCount = 0
    foreach ($pr in $all) {
        $nm = $pr.ProcessName.ToLower()
        if (Test-NameMatch $nm $script:Config.LowPriority) { $lowCount++ }
        elseif (Test-NameMatch $nm $script:Config.HighPriority) { $highCount++ }
    }
    Write-Con "  Процессов с низким приоритетом: $lowCount" 'DarkGray'
    Write-Con "  Процессов с высоким приоритетом: $highCount" 'DarkGray'
    Write-Con ("  Низкий список: " + ($script:Config.LowPriority -join ', ')) 'DarkGray'
    Write-Con ("  Высокий список: " + ($script:Config.HighPriority -join ', ')) 'DarkGray'
    Write-Con '' 'White'
}

function Show-Menu {
    Clear-Con

    $pauseState = if ($script:Paused) { 'вкл' } else { 'выкл' }
    $pauseColor = if ($script:Paused) { 'Yellow' } else { 'Green' }
    $heroicState = if ($script:Config.HeroicMode) { 'вкл' } else { 'выкл' }
    $heroicColor = if ($script:Config.HeroicMode) { 'Green' } else { 'Yellow' }
    $startupState = if (Test-StartupEnabled) { 'вкл' } else { 'выкл' }
    $startupColor = if (Test-StartupEnabled) { 'Green' } else { 'Yellow' }

    Write-Con '  ==================================================' 'Cyan'
    Write-Con '           GAMEBOOST v1.2 - Gamepad Edition' 'Green'
    Write-Con '  ==================================================' 'Cyan'
    Write-Con '' 'White'
    Write-Con '  [1] Статус' 'White'
    Write-Con '  [2] Применить оптимизации сейчас' 'White'
    Write-Con "  [3] Пауза мониторинга: $pauseState" $pauseColor
    Write-Con "  [4] Heroic профиль: $heroicState" $heroicColor
    Write-Con '  [5] Захватить игру (отсчёт 5 сек)' 'White'
    Write-Con '  [6] Добавить процесс в буст вручную' 'White'
    Write-Con '  [7] Обновить конфиг' 'White'
    Write-Con "  [8] Автозапуск: $startupState" $startupColor
    Write-Con '  [9] Показать лог-файл' 'White'
    Write-Con '  [0] Скрыть окно в трей' 'White'
    Write-Con '  [G] Настройки геймпада (мёртвые зоны)' 'Yellow'
    Write-Con '  [C] Калибровка под активную игру' 'Yellow'
    Write-Con '  [Q] Полный выход' 'Red'
    Write-Con '' 'White'
    Write-Con '  Ctrl+Alt+B - добавить активную игру, не выходя из игры' 'DarkGray'
    Write-Con '  Крестик окна = свернуть в трей. GameBoost продолжает работать!' 'DarkGray'
    Write-Con '' 'White'
}

function Invoke-SelfTest {
    Write-Con '  --- Самодиагностика ---' 'Cyan'

    $admin = Test-IsAdmin
    Write-Con ("  Права администратора: " + $(if ($admin) { '[OK]' } else { '[FAIL]' })) $(if ($admin) { 'Green' } else { 'Red' })

    $formOk = [bool]$script:Form
    Write-Con ("  Консольное окно: " + $(if ($formOk) { '[OK]' } else { '[FAIL]' })) $(if ($formOk) { 'Green' } else { 'Red' })

    $trayOk = [bool]$script:Tray
    Write-Con ("  Трей: " + $(if ($trayOk) { '[OK]' } else { '[FAIL]' })) $(if ($trayOk) { 'Green' } else { 'Red' })

    $hotOk = [bool]$script:Hotkey
    Write-Con ("  Горячая клавиша Ctrl+Alt+B: " + $(if ($hotOk) { '[OK]' } else { '[FAIL]' })) $(if ($hotOk) { 'Green' } else { 'Yellow' })

    $cfgOk = [bool]$script:Config
    Write-Con ("  Конфиг: " + $(if ($cfgOk) { '[OK]' } else { '[FAIL]' })) $(if ($cfgOk) { 'Green' } else { 'Red' })

    $schOk = [bool](Get-Command schtasks -ErrorAction SilentlyContinue)
    Write-Con ("  Планировщик заданий: " + $(if ($schOk) { '[OK]' } else { '[FAIL]' })) $(if ($schOk) { 'Green' } else { 'Red' })

    Write-Con '' 'White'
}

function New-ConsoleForm {
    $f = $null
    try {
        $f = New-Object System.Windows.Forms.Form
        $f.Text = 'GameBoost v1.1'
        $f.BackColor = [System.Drawing.Color]::Black
        $f.Size = New-Object System.Drawing.Size(800, 500)
        $f.StartPosition = 'CenterScreen'
        $f.Font = New-Object System.Drawing.Font('Consolas', 10)
        $f.KeyPreview = $true
        $f.ShowInTaskbar = $true
        $f.MinimumSize = New-Object System.Drawing.Size(500, 300)

        $rtb = New-Object System.Windows.Forms.RichTextBox
        $rtb.Dock = 'Fill'
        $rtb.BackColor = [System.Drawing.Color]::Black
        $rtb.ForeColor = [System.Drawing.Color]::White
        $rtb.Font = New-Object System.Drawing.Font('Consolas', 10)
        $rtb.ReadOnly = $true
        $rtb.WordWrap = $true
        $rtb.ScrollBars = 'Vertical'
        $rtb.ShortcutsEnabled = $false
        $rtb.BorderStyle = 'None'
        $f.Controls.Add($rtb)

        $f.Add_KeyDown({
            param($s, $e)
            try { Handle-Key ($e.KeyCode.ToString()) } catch { Write-Log "Key error: $_" 'WARN' }
            $e.SuppressKeyPress = $true
        })

        $f.Add_FormClosing({
            param($s, $e)
            if (-not $script:AllowClose) {
                $e.Cancel = $true
                $script:Form.Hide()
                Show-Balloon 'GameBoost всё ещё работает в трее.'
            }
        })

        $script:Rtb = $rtb
    }
    catch {
        Write-Log "Form creation error: $_" 'WARN'
        $f = $null
    }
    return $f
}

#endregion

#region === ЗАХВАТ ИГРЫ ===

function Capture-ForegroundGame {
    $fg = Get-ForegroundProcessId
    if ($fg -eq 0 -or $fg -eq $PID) {
        Show-Balloon 'Не удалось определить окно игры.'
        return
    }

    $proc = Get-Process -Id $fg -ErrorAction SilentlyContinue
    if (-not $proc) {
        Show-Balloon 'Процесс уже закрыт.'
        return
    }

    $name = $proc.ProcessName
    $bad = @('explorer','powershell','pwsh','cmd','conhost','searchui','applicationframehost','shellexperiencehost','startmenuexperiencehost','textinputhost','taskmgr','heroic','legendary','gameboost')
    if ($bad -contains $name.ToLower()) {
        Show-Balloon "Окно '$name' - это не игра. Переключись в игру и попробуй снова."
        return
    }

    if ($script:Config.HighPriority -contains $name) {
        Show-Balloon "Игра '$name' уже в списке буста."
        return
    }

    Add-ProcessToConfigList 'HighPriority' $name
    $script:Config = Read-Config
    Show-Balloon "Игра '$name' добавлена в буст (High)."
    Show-UiMessage "Игра '$name' добавлена в HighPriority." 'Green'
}

function Start-DelayedCapture {
    Show-UiMessage 'Переключись в игру! Захват через 5 секунд...' 'Yellow'
    Show-Balloon 'Переключись в игру - захват через 5 секунд.'
    for ($i = 5; $i -ge 1; $i--) {
        Start-Sleep -Seconds 1
        [System.Windows.Forms.Application]::DoEvents()
    }
    Capture-ForegroundGame
}

#endregion

#region === ДЕЙСТВИЯ ===

function Invoke-ActionApplyNow {
    Apply-WindowsOptimizations $script:Config -Force
    Show-UiMessage 'Оптимизации применены.' 'Green'
}

function Invoke-ActionTogglePause {
    $script:Paused = -not $script:Paused
    Update-State
    Show-Menu
    Invoke-SelfTest
    if ($script:Paused) { Show-UiMessage 'Мониторинг приостановлен.' 'Yellow' }
    else { Show-UiMessage 'Мониторинг возобновлён.' 'Green' }
}

function Invoke-ActionToggleHeroic {
    $script:Config.HeroicMode = -not $script:Config.HeroicMode
    Set-IniValue 'HeroicMode' $(if ($script:Config.HeroicMode) { '1' } else { '0' })
    Update-State
    Show-Menu
    Invoke-SelfTest
    $s = if ($script:Config.HeroicMode) { 'вкл' } else { 'выкл' }
    Show-UiMessage "Heroic профиль: $s" 'Cyan'
}

function Invoke-ActionToggleStartup {
    if (Test-StartupEnabled) { Remove-FromStartup | Out-Null }
    else { Add-ToStartup | Out-Null }
    Update-State
    Show-Menu
    Invoke-SelfTest
    $s = if (Test-StartupEnabled) { 'вкл' } else { 'выкл' }
    Show-UiMessage "Автозапуск: $s" 'Cyan'
    Show-Balloon "Автозапуск: $s"
}

function Invoke-ActionRefreshConfig {
    $script:Config = Read-Config
    Update-State
    Show-Menu
    Invoke-SelfTest
    Show-UiMessage 'Конфиг обновлён.' 'Cyan'
}

function Invoke-ActionShowLog {
    if (Test-Path $script:LogPath) {
        try { Invoke-Item $script:LogPath } catch {}
    }
    else {
        Show-UiMessage 'Лог не найден. Включи EnableLog=1 в конфиге.' 'Yellow'
    }
}

function Invoke-ActionManualAdd {
    $manual = [Microsoft.VisualBasic.Interaction]::InputBox(
        'Имя процесса без .exe (например: HellLetLooseClient):',
        'GameBoost v1.1 - добавить в буст',
        ''
    )
    if (-not [string]::IsNullOrWhiteSpace($manual)) {
        $manual = $manual.Trim()
        Add-ProcessToConfigList 'HighPriority' $manual
        $script:Config = Read-Config
        Show-UiMessage "Процесс '$manual' добавлен в HighPriority." 'Green'
    }
    else {
        Show-UiMessage 'Отменено.' 'Yellow'
    }
}

function Handle-Key {
    param([string]$Key)
    
    # Если открыто меню геймпада - обрабатываем там
    if ($script:InGamepadMenu) {
        $script:GamepadMenuKey = $Key
        return
    }
    
    # Главное меню - только цифры и буквы
    switch ($Key) {
        'D1'      { Show-Status }
        'NumPad1' { Show-Status }
        'D2'      { Invoke-ActionApplyNow }
        'NumPad2' { Invoke-ActionApplyNow }
        'D3'      { Invoke-ActionTogglePause }
        'NumPad3' { Invoke-ActionTogglePause }
        'D4'      { Invoke-ActionToggleHeroic }
        'NumPad4' { Invoke-ActionToggleHeroic }
        'D5'      { Start-DelayedCapture }
        'NumPad5' { Start-DelayedCapture }
        'D6'      { Invoke-ActionManualAdd }
        'NumPad6' { Invoke-ActionManualAdd }
        'D7'      { Invoke-ActionRefreshConfig }
        'NumPad7' { Invoke-ActionRefreshConfig }
        'D8'      { Invoke-ActionToggleStartup }
        'NumPad8' { Invoke-ActionToggleStartup }
        'D9'      { Invoke-ActionShowLog }
        'NumPad9' { Invoke-ActionShowLog }
        'D0'      { Hide-ConsoleWindow }
        'NumPad0' { Hide-ConsoleWindow }
        'G'       { Show-GamepadMenu }
        'C'       { Start-GamepadCalibration }
        'Escape'  { Hide-ConsoleWindow }
        'Q'       { $script:ExitRequested = $true }
    }
}

# === GAMEPAD MANAGER - ВСТРАИВАЕМЫЙ МОДУЛЬ ===

# Глобальные переменные геймпада
$script:LeftDeadzone = 0.15
$script:RightDeadzone = 0.15
$script:LeftShape = 'Circular'
$script:RightShape = 'Circular'
$script:LeftSensitivity = 1.0
$script:RightSensitivity = 1.0
$script:ActiveGamePid = 0
$script:GamepadMenuKey = $null
$script:InGamepadMenu = $false

# C# классы для XInput и Deadzone (добавляем если ещё не загружены)
try {
    if (-not ('XInputState' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public struct XInputState { public uint dwPacketNumber; public XInputGamepad Gamepad; }
public struct XInputGamepad { public ushort wButtons; public byte bLeftTrigger; public byte bRightTrigger; public short sThumbLX; public short sThumbLY; public short sThumbRX; public short sThumbRY; }
public enum XInputError : uint { Success = 0, DeviceNotConnected = 1167 }
public class XInputNative {
    [DllImport("xinput1_4.dll")] public static extern XInputError XInputGetState(uint dwUserIndex, out XInputState pState);
    [DllImport("xinput1_3.dll")] public static extern XInputError XInputGetStateEx(uint dwUserIndex, out XInputState pState);
}
public enum DeadzoneShape { Circular, Square, Cross }
public class DeadzoneProcessor {
    public static void ProcessAxis(short rawX, short rawY, double innerDz, double sensitivity, DeadzoneShape shape, out short outX, out short outY) {
        float nx = rawX / 32768.0f, ny = rawY / 32768.0f, px, py;
        switch (shape) {
            case DeadzoneShape.Square: ProcessSquare(nx, ny, innerDz, sensitivity, out px, out py); break;
            case DeadzoneShape.Cross: ProcessCross(nx, ny, innerDz, sensitivity, out px, out py); break;
            default: ProcessCircular(nx, ny, innerDz, sensitivity, out px, out py); break;
        }
        outX = (short)(Math.Max(-1.0, Math.Min(1.0, px)) * 32767);
        outY = (short)(Math.Max(-1.0, Math.Min(1.0, py)) * 32767);
    }
    private static void ProcessCircular(float x, float y, double dz, double sens, out float ox, out float oy) {
        float mag = (float)Math.Sqrt(x * x + y * y);
        if (mag <= dz) { ox = 0; oy = 0; return; }
        float angle = (float)Math.Atan2(y, x), norm = (mag - dz) / (1.0 - dz);
        norm = (float)Math.Pow(norm, 1.0 / sens);
        ox = (float)(Math.Cos(angle) * norm); oy = (float)(Math.Sin(angle) * norm);
    }
    private static void ProcessSquare(float x, float y, double dz, double sens, out float ox, out float oy) {
        float ax = Math.Abs(x), ay = Math.Abs(y);
        ax = ax <= dz ? 0 : (ax - dz) / (1.0 - dz); ay = ay <= dz ? 0 : (ay - dz) / (1.0 - dz);
        ax = (float)Math.Pow(ax, 1.0 / sens); ay = (float)Math.Pow(ay, 1.0 / sens);
        ox = Math.Sign(x) * ax; oy = Math.Sign(y) * ay;
    }
    private static void ProcessCross(float x, float y, double dz, double sens, out float ox, out float oy) {
        float ax = Math.Abs(x), ay = Math.Abs(y);
        float effDz = (ax > dz && ay > dz) ? dz * 1.3f : dz;
        float factor = (ax > 0.1f && ay > 0.1f) ? 1.0f - (Math.Min(ax, ay) / Math.Max(ax, ay)) * 0.5f : 1.0f;
        ax = ax <= effDz ? 0 : (ax - effDz) / (1.0 - effDz) * factor;
        ay = ay <= effDz ? 0 : (ay - effDz) / (1.0 - effDz) * factor;
        ax = (float)Math.Pow(ax, 1.0 / sens); ay = (float)Math.Pow(ay, 1.0 / sens);
        ox = Math.Sign(x) * ax; oy = Math.Sign(y) * ay;
    }
}
'@
    }
} catch {}

function Get-XInputState {
    param([uint]$PlayerIndex = 0)
    $state = New-Object XInputState
    $result = [XInputNative]::XInputGetState($PlayerIndex, [ref]$state)
    if ($result -eq [XInputError]::Success) {
        return @{ Connected = $true; PacketNumber = $state.dwPacketNumber; Buttons = $state.Gamepad.wButtons
                  LeftTrigger = $state.Gamepad.bLeftTrigger; RightTrigger = $state.Gamepad.bRightTrigger
                  LeftX = $state.Gamepad.sThumbLX; LeftY = $state.Gamepad.sThumbLY
                  RightX = $state.Gamepad.sThumbRX; RightY = $state.Gamepad.sThumbRY }
    } else { return @{ Connected = $false } }
}

function Format-StickVisual {
    param([short]$x, [short]$y, [int]$width = 15, [int]$height = 5)
    $centerX = [math]::Floor($width / 2); $centerY = [math]::Floor($height / 2)
    $displayX = $centerX + [math]::Round(($x / 32768.0) * ($centerX - 1))
    $displayY = $centerY - [math]::Round(($y / 32768.0) * ($centerY - 1))
    $displayX = [math]::Max(0, [math]::Min($width - 1, $displayX)); $displayY = [math]::Max(0, [math]::Min($height - 1, $displayY))
    $grid = @()
    for ($row = 0; $row -lt $height; $row++) {
        $line = ""
        for ($col = 0; $col -lt $width; $col++) {
            if ($row -eq $centerY -and $col -eq $centerX) { $line += "+" }
            elseif ($row -eq $displayY -and $col -eq $displayX) { $line += "O" }
            elseif ($row -eq $centerY) { $line += "-" }
            elseif ($col -eq $centerX) { $line += "|" }
            else { $line += "." }
        }
        $grid += $line
    }
    return $grid
}

function Save-GamepadConfig {
    $configPath = Join-Path $ScriptDir 'GameBoost_Gamepad.json'
    @{ LeftDeadzone = $script:LeftDeadzone; RightDeadzone = $script:RightDeadzone
       LeftShape = $script:LeftShape; RightShape = $script:RightShape
       LeftSensitivity = $script:LeftSensitivity; RightSensitivity = $script:RightSensitivity } | ConvertTo-Json | Set-Content -Path $configPath -Encoding UTF8
}

function Load-GamepadConfig {
    $configPath = Join-Path $ScriptDir 'GameBoost_Gamepad.json'
    if (Test-Path $configPath) {
        $cfg = Get-Content -Path $configPath -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.LeftDeadzone) { $script:LeftDeadzone = $cfg.LeftDeadzone }
        if ($cfg.RightDeadzone) { $script:RightDeadzone = $cfg.RightDeadzone }
        if ($cfg.LeftShape) { $script:LeftShape = $cfg.LeftShape }
        if ($cfg.RightShape) { $script:RightShape = $cfg.RightShape }
    }
}

function Show-GamepadMenu {
    $script:InGamepadMenu = $true
    Load-GamepadConfig
    $selected = 0
    $items = @("Левый стик - Мёртвая зона: $($script:LeftDeadzone.ToString("F2"))",
               "Левый стик - Форма: $($script:LeftShape)",
               "Правый стик - Мёртвая зона: $($script:RightDeadzone.ToString("F2"))",
               "Правый стик - Форма: $($script:RightShape)",
               "Сохранить и выйти")
    $lastUpdate = [datetime]::Now
    while ($true) {
        Clear-Con
        Write-Con "╔═══════════════════════════════════════╗" "Cyan"
        Write-Con "║   НАСТРОЙКИ ГЕЙМПАДА                ║" "Cyan"
        Write-Con "╚═══════════════════════════════════════╝" "Cyan"
        Write-Con ""; Write-Con "  ↑/↓ Выбор  ←/→ Значение  Enter Применить  ESC Выход" "Gray"; Write-Con ""
        for ($i = 0; $i -lt $items.Length; $i++) {
            if ($i -eq $selected) { Write-Con "  ► $($items[$i])" "Yellow" } else { Write-Con "    $($items[$i])" "White" }
        }
        Write-Con ""
        if (([datetime]::Now - $lastUpdate).TotalMilliseconds -ge 100) {
            $lastUpdate = [datetime]::Now
            $gp = Get-XInputState -PlayerIndex 0
            if ($gp.Connected) {
                Write-Con "  ┌───── ВИЗУАЛИЗАЦИЯ ─────┐" "Green"
                $lg = Format-StickVisual -x $gp.LeftX -y $gp.LeftY
                Write-Con "  LS: $($lg[0])" "White"; Write-Con "      $($lg[1])" "White"
                Write-Con "      $($lg[2])" "White"; Write-Con "      $($lg[3])" "White"
                Write-Con "      $($lg[4])" "White"
                $rg = Format-StickVisual -x $gp.RightX -y $gp.RightY
                Write-Con "  RS: $($rg[0])" "White"; Write-Con "      $($rg[1])" "White"
                Write-Con "      $($rg[2])" "White"; Write-Con "      $($rg[3])" "White"
                Write-Con "      $($rg[4])" "White"
                Write-Con "  └────────────────────────┘" "Green"
            } else { Write-Con "  [!] Геймпад не подключён" "Red" }
        }
        [System.Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50
        if ($script:GamepadMenuKey -eq 'Escape') { $script:GamepadMenuKey = $null; break }
        elseif ($script:GamepadMenuKey -eq 'Up') { $script:GamepadMenuKey = $null; $selected = [math]::Max(0, $selected - 1) }
        elseif ($script:GamepadMenuKey -eq 'Down') { $script:GamepadMenuKey = $null; $selected = [math]::Min($items.Length - 1, $selected + 1) }
        elseif ($script:GamepadMenuKey -eq 'Left') {
            $script:GamepadMenuKey = $null
            if ($selected -eq 0) { $script:LeftDeadzone = [math]::Max(0.0, [math]::Round($script:LeftDeadzone - 0.01, 2)) }
            if ($selected -eq 2) { $script:RightDeadzone = [math]::Max(0.0, [math]::Round($script:RightDeadzone - 0.01, 2)) }
            $items = @("Левый стик - Мёртвая зона: $($script:LeftDeadzone.ToString("F2"))", "Левый стик - Форма: $($script:LeftShape)",
                       "Правый стик - Мёртвая зона: $($script:RightDeadzone.ToString("F2"))", "Правый стик - Форма: $($script:RightShape)", "Сохранить и выйти")
        }
        elseif ($script:GamepadMenuKey -eq 'Right') {
            $script:GamepadMenuKey = $null
            if ($selected -eq 0) { $script:LeftDeadzone = [math]::Min(1.0, [math]::Round($script:LeftDeadzone + 0.01, 2)) }
            if ($selected -eq 2) { $script:RightDeadzone = [math]::Min(1.0, [math]::Round($script:RightDeadzone + 0.01, 2)) }
            $items = @("Левый стик - Мёртвая зона: $($script:LeftDeadzone.ToString("F2"))", "Левый стик - Форма: $($script:LeftShape)",
                       "Правый стик - Мёртвая зона: $($script:RightDeadzone.ToString("F2"))", "Правый стик - Форма: $($script:RightShape)", "Сохранить и выйти")
        }
        elseif ($script:GamepadMenuKey -eq 'Enter') {
            $script:GamepadMenuKey = $null
            if ($selected -eq 1) {
                switch ($script:LeftShape) { 'Circular' { $script:LeftShape = 'Square' }; 'Square' { $script:LeftShape = 'Cross' }; 'Cross' { $script:LeftShape = 'Circular' } }
                $items = @("Левый стик - Мёртвая зона: $($script:LeftDeadzone.ToString("F2"))", "Левый стик - Форма: $($script:LeftShape)",
                           "Правый стик - Мёртвая зона: $($script:RightDeadzone.ToString("F2"))", "Правый стик - Форма: $($script:RightShape)", "Сохранить и выйти")
            }
            if ($selected -eq 3) {
                switch ($script:RightShape) { 'Circular' { $script:RightShape = 'Square' }; 'Square' { $script:RightShape = 'Cross' }; 'Cross' { $script:RightShape = 'Circular' } }
                $items = @("Левый стик - Мёртвая зона: $($script:LeftDeadzone.ToString("F2"))", "Левый стик - Форма: $($script:LeftShape)",
                           "Правый стик - Мёртвая зона: $($script:RightDeadzone.ToString("F2"))", "Правый стик - Форма: $($script:RightShape)", "Сохранить и выйти")
            }
            if ($selected -eq 4) { Save-GamepadConfig; Show-UiMessage "Настройки геймпада сохранены!" "Green"; break }
        }
    }
    $script:InGamepadMenu = $false
    $script:GamepadMenuKey = $null
    Show-Menu
}

function Start-GamepadCalibration {
    Show-UiMessage "КАЛИБРОВКА ПОД ИГРУ (5 сек)" "Yellow"; Show-Balloon "Переключись в игру..."
    for ($i = 5; $i -ge 1; $i--) { Clear-Con; Write-Con "  Переключись в игру... $i" "Yellow"; Start-Sleep -Seconds 1; [System.Windows.Forms.Application]::DoEvents() }
    $fg = Get-ForegroundProcessId
    if ($fg -gt 0) { $script:ActiveGamePid = $fg; $proc = Get-Process -Id $fg -ErrorAction SilentlyContinue
        if ($proc) { Show-UiMessage "Игра: $($proc.ProcessName)" "Green"; Show-Balloon "Применено для: $($proc.ProcessName)" } }
}

#endregion

#region === ТРЕЙ (ЗАЩИЩЁННЫЙ) ===

function Update-State {
    try {
        if ($script:MenuPause) { $script:MenuPause.Checked = $script:Paused }
        if ($script:MenuHeroic) { $script:MenuHeroic.Checked = [bool]$script:Config.HeroicMode }
        if ($script:MenuStartup) {
            $st = if (Test-StartupEnabled) { 'вкл' } else { 'выкл' }
            $script:MenuStartup.Text = "Автозапуск: $st"
        }
        if ($script:Tray) {
            if ($script:Paused) { $script:Tray.Text = 'GameBoost v1.1: пауза' }
            else { $script:Tray.Text = 'GameBoost v1.1: активен' }
        }
    }
    catch { Write-Log "Update-State error: $_" 'WARN' }
}

function New-Tray {
    $ni = $null
    try { $ni = New-Object System.Windows.Forms.NotifyIcon } catch { $ni = $null }
    if (-not $ni) {
        Write-Log 'NotifyIcon creation failed - running without tray' 'WARN'
        return $null
    }

    try {
        $iconFile = Join-Path $ScriptDir 'GameBoost.ico'
        if (Test-Path $iconFile) {
            try { $ni.Icon = New-Object System.Drawing.Icon($iconFile) }
            catch { $ni.Icon = [System.Drawing.SystemIcons]::Application }
        }
        else {
            $ni.Icon = [System.Drawing.SystemIcons]::Application
        }
    }
    catch {
        try { $ni.Icon = [System.Drawing.SystemIcons]::Application } catch {}
    }

    $ni.Text = 'GameBoost v1.1: активен'
    $ni.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip

    $miOpen = $menu.Items.Add('Открыть консоль')
    $miOpen.Add_Click({
        try { Show-ConsoleWindow } catch { Write-Log "Tray open error: $_" 'WARN' }
    })

    $script:MenuPause = $menu.Items.Add('Пауза мониторинга')
    $script:MenuPause.CheckOnClick = $true
    $script:MenuPause.Checked = $script:Paused
    $script:MenuPause.Add_Click({
        try {
            $script:Paused = $script:MenuPause.Checked
            Update-State
            if ($script:Paused) { Show-UiMessage 'Мониторинг приостановлен.' 'Yellow' }
            else { Show-UiMessage 'Мониторинг возобновлён.' 'Green' }
        }
        catch { Write-Log "Tray pause error: $_" 'WARN' }
    })

    $null = $menu.Items.Add('-')

    $miApply = $menu.Items.Add('Применить оптимизации сейчас')
    $miApply.Add_Click({
        try {
            Apply-WindowsOptimizations $script:Config -Force
            Show-UiMessage 'Оптимизации применены.' 'Green'
            Show-Balloon 'Оптимизации применены.'
        }
        catch { Write-Log "Tray apply error: $_" 'WARN' }
    })

    $miCapture = $menu.Items.Add('Захватить игру (5 сек)')
    $miCapture.Add_Click({
        try { Start-DelayedCapture } catch { Write-Log "Tray capture error: $_" 'WARN' }
    })

    $script:MenuHeroic = $menu.Items.Add('Heroic профиль')
    $script:MenuHeroic.CheckOnClick = $true
    $script:MenuHeroic.Checked = [bool]$script:Config.HeroicMode
    $script:MenuHeroic.Add_Click({
        try {
            $script:Config.HeroicMode = $script:MenuHeroic.Checked
            Set-IniValue 'HeroicMode' $(if ($script:Config.HeroicMode) { '1' } else { '0' })
            Update-State
            $s = if ($script:Config.HeroicMode) { 'вкл' } else { 'выкл' }
            Show-UiMessage "Heroic профиль: $s" 'Cyan'
        }
        catch { Write-Log "Tray heroic error: $_" 'WARN' }
    })

    $script:MenuStartup = $menu.Items.Add('Автозапуск: выкл')
    $script:MenuStartup.Add_Click({
        try { Invoke-ActionToggleStartup } catch { Write-Log "Tray startup error: $_" 'WARN' }
    })

    $miRefresh = $menu.Items.Add('Обновить конфиг')
    $miRefresh.Add_Click({
        try {
            $script:Config = Read-Config
            Update-State
            Show-UiMessage 'Конфиг перечитан.' 'Cyan'
        }
        catch { Write-Log "Tray refresh error: $_" 'WARN' }
    })

    $null = $menu.Items.Add('-')

    $miExit = $menu.Items.Add('Выход')
    $miExit.Add_Click({ $script:ExitRequested = $true })

    $ni.ContextMenuStrip = $menu

    # ВАЖНО: событие через add_DoubleClick + try/catch - падение трея больше не убивает запуск
    try { $ni.add_DoubleClick({ try { Show-ConsoleWindow } catch {} }) } catch {}

    return $ni
}

#endregion

#region === СТАРТ ===

$script:Config = Read-Config

$script:Form = New-ConsoleForm

if ($script:Config.HotkeyEnabled) {
    try {
        $script:Hotkey = New-Object GbHotkey
        $script:Hotkey.Setup()
    }
    catch { $script:Hotkey = $null }
}
$lastHotkeyCount = 0

Apply-WindowsOptimizations $script:Config
Optimize-HeroicSettings $script:Config
Set-ProcessPriorities $script:Config
$script:LastProcessCheck = Get-Date
$script:LastOptCheck = Get-Date

$script:Tray = New-Tray
Update-State

if (-not $Hidden) {
    if ($script:Form) { $script:Form.Show() }
    Show-Menu
    Invoke-SelfTest
}

Show-Balloon 'GameBoost v1.2 запущен. G - настройки геймпада, C - калибровка.'

#endregion

#region === ГЛАВНЫЙ ЦИКЛ ===

try {
    while (-not $script:ExitRequested) {
        try {
            if ($script:Hotkey -and ([GbHotkey]::HotkeyCount -gt $lastHotkeyCount)) {
                $lastHotkeyCount = [GbHotkey]::HotkeyCount
                Capture-ForegroundGame
            }

            [System.Windows.Forms.Application]::DoEvents()

            $now = Get-Date
            if (-not $script:Paused) {
                if (($now - $script:LastProcessCheck).TotalSeconds -ge $script:Config.ProcessCheckInterval) {
                    $script:LastProcessCheck = $now
                    Set-ProcessPriorities $script:Config
                }
                if ($script:Config.ApplyOptimizations -and
                    $script:Config.OptimizationCheckInterval -gt 0 -and
                    ($now - $script:LastOptCheck).TotalMinutes -ge $script:Config.OptimizationCheckInterval) {
                    $script:LastOptCheck = $now
                    Apply-WindowsOptimizations $script:Config
                }
            }
        }
        catch {
            Write-Log "Loop error: $_" 'WARN'
        }

        Start-Sleep -Milliseconds 120
    }
}
finally {
    try {
        $script:AllowClose = $true
        if ($script:Form) { $script:Form.Close(); $script:Form.Dispose() }
    }
    catch {}
    if ($script:Tray) {
        try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch {}
    }
    try { $mutex.ReleaseMutex() } catch {}
    try { $mutex.Dispose() } catch {}
}

#endregion
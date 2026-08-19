#Requires -RunAsAdministrator
# GameBoost - process priorities, audio, Windows optimizations
# Launched from GameBoost.bat

$ErrorActionPreference = "SilentlyContinue"
$script:Config = $null
$script:LogPath = $null

function Get-ScriptDir {
    Split-Path -Parent $MyInvocation.ScriptName
}

$ScriptDir = Get-ScriptDir
$ConfigPath = Join-Path $ScriptDir "GameBoost_config.ini"

function Write-Log {
    param([string]$Msg, [string]$Level = "INFO")
    if (-not $script:Config -or $script:Config.EnableLog -ne "1") { return }
    $path = $script:LogPath
    if ([string]::IsNullOrWhiteSpace($path)) { $path = Join-Path $ScriptDir "GameBoost_log.txt" }
    $line = "{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}" -f (Get-Date), $Level, $Msg
    Add-Content -LiteralPath $path -Value $line -ErrorAction SilentlyContinue
}

function Read-Config {
    $config = @{
        LowPriority = @("Discord", "DiscordPTB", "DiscordCanary", "chrome")
        HighPriority = @("Rocket League", "RocketLeague", "csgo", "cs2", "Valorant", "dota 2", "dota2", "FortniteClient-Win64", "GTA5", "Overwatch", "apex", "League of Legends", "Wow", "Wow-64", "Destiny2", "Warframe")
        ProcessCheckInterval = 3
        AudioCheckInterval = 5
        OptimizationCheckInterval = 5
        FixAudio = "1"
        RestartAudioService = "1"
        RestartAudioEndpoint = "1"
        ApplyOptimizations = "1"
        HighPerformancePower = "1"
        GameMode = "1"
        DisableNagle = "1"
        TimerResolution = "1"
        BackgroundServices = "0"
        NetworkThrottling = "1"
        HardwareAccelGPU = "1"
        DisableIndexing = "0"
        EnableLog = "0"
        LogPath = ""
    }
    if (-not (Test-Path $ConfigPath)) { return $config }
    $content = Get-Content $ConfigPath -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if (-not $content) { return $config }
    foreach ($line in ($content -split "`r?`n")) {
        $line = $line.Trim()
        if ($line -match '^\[(.+)\]') { continue }
        if ($line -match '^([^;#=]+)=(.*)$') {
            $key = $matches[1].Trim()
            $val = $matches[2].Trim()
            switch ($key) {
                "LowPriority"  { $config.LowPriority = ($val -split ',').Trim() | Where-Object { $_ } }
                "HighPriority"  { $config.HighPriority = ($val -split ',').Trim() | Where-Object { $_ } }
                "ProcessCheckInterval" {
                    $parsed = 0
                    if ([int]::TryParse($val, [ref]$parsed)) { $config.ProcessCheckInterval = $parsed }
                    else { $config.ProcessCheckInterval = 3 }
                }
                "AudioCheckInterval" {
                    $parsed = 0
                    if ([int]::TryParse($val, [ref]$parsed)) { $config.AudioCheckInterval = $parsed }
                    else { $config.AudioCheckInterval = 5 }
                }
                "OptimizationCheckInterval" {
                    $parsed = 0
                    if ([int]::TryParse($val, [ref]$parsed)) { $config.OptimizationCheckInterval = $parsed }
                    else { $config.OptimizationCheckInterval = 5 }
                }
                "FixAudio"      { $config.FixAudio = $val }
                "RestartAudioService"  { $config.RestartAudioService = $val }
                "RestartAudioEndpoint" { $config.RestartAudioEndpoint = $val }
                "ApplyOptimizations"   { $config.ApplyOptimizations = $val }
                "HighPerformancePower" { $config.HighPerformancePower = $val }
                "GameMode"      { $config.GameMode = $val }
                "DisableNagle"  { $config.DisableNagle = $val }
                "TimerResolution" { $config.TimerResolution = $val }
                "BackgroundServices" { $config.BackgroundServices = $val }
                "NetworkThrottling" { $config.NetworkThrottling = $val }
                "HardwareAccelGPU" { $config.HardwareAccelGPU = $val }
                "DisableIndexing" { $config.DisableIndexing = $val }
                "EnableLog"     { $config.EnableLog = $val }
                "LogPath"       { $config.LogPath = $val }
            }
        }
    }
    return $config
}

function Set-ProcessPriorities {
    param($Config)
    $low  = $Config.LowPriority  | ForEach-Object { $_.ToLower() }
    $high = $Config.HighPriority | ForEach-Object { $_.ToLower() }
    try {
        $processes = Get-Process -ErrorAction SilentlyContinue
        foreach ($p in $processes) {
            $name = $p.ProcessName
            $base = $name -replace '\.exe$', ''
            $nameLower = $base.ToLower()
            try {
                $isLow = $false
                foreach ($l in $low) {
                    if ($nameLower -eq $l -or $nameLower -like "*$l*") { $isLow = $true; break }
                }
                if ($isLow) {
                    if ($p.PriorityClass -ne "Idle" -and $p.PriorityClass -ne "BelowNormal") {
                        $p.PriorityClass = "Idle"
                        Write-Log "Low: $name"
                    }
                    continue
                }
                $isHigh = $false
                foreach ($h in $high) {
                    if ($nameLower -eq $h -or $nameLower -like "*$h*") { $isHigh = $true; break }
                }
                if ($isHigh) {
                    if ($p.PriorityClass -ne "High" -and $p.PriorityClass -ne "RealTime") {
                        $p.PriorityClass = "High"
                        Write-Log "High: $name"
                    }
                }
            } catch {}
        }
    } catch {}
}

function Test-AudioWorking {
    try {
        $srv = Get-Service -Name "Audiosrv" -ErrorAction Stop
        if ($srv.Status -ne "Running") { 
            Write-Log "Audio service Audiosrv is not running (Status: $($srv.Status))" "AUDIO"
            return $false 
        }
        $endpoint = Get-Service -Name "AudioEndpointBuilder" -ErrorAction SilentlyContinue
        if ($endpoint -and $endpoint.Status -ne "Running") { 
            Write-Log "Audio service AudioEndpointBuilder is not running (Status: $($endpoint.Status))" "AUDIO"
            return $false 
        }
        return $true
    } catch { 
        Write-Log "Audio check error: $_" "AUDIO"
        return $false 
    }
}

function Repair-Audio {
    param($Config)
    if ($Config.RestartAudioService -eq "1") {
        try {
            Write-Log "Attempting to restart audio services..." "AUDIO"
            Stop-Service -Name "Audiosrv" -Force -ErrorAction SilentlyContinue
            Stop-Service -Name "AudioEndpointBuilder" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
            Start-Service -Name "AudioEndpointBuilder" -ErrorAction Stop
            Start-Sleep -Seconds 1
            Start-Service -Name "Audiosrv" -ErrorAction Stop
            Start-Sleep -Seconds 1
            if (Test-AudioWorking) {
                Write-Log "Audio services successfully restarted" "AUDIO"
            } else {
                Write-Log "Audio services restarted but still not working" "WARN"
            }
        } catch { 
            Write-Log "Audio restart error: $_" "WARN"
        }
    }
    if ($Config.RestartAudioEndpoint -eq "1") {
        try {
            $devcon = Join-Path $ScriptDir "devcon.exe"
            if (Test-Path $devcon) {
                Write-Log "Attempting to restart audio endpoint via devcon..." "AUDIO"
                & $devcon restart "AudioEndpointBuilder" 2>$null
                Start-Sleep -Seconds 2
            }
        } catch {
            Write-Log "Audio endpoint restart error: $_" "WARN"
        }
    }
}

function Get-PowerGuid {
    $list = powercfg /list 2>$null
    if (-not $list) { return "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" }
    $line = $list | Select-String "High performance|Vysokaya proizvoditelnost" | Select-Object -First 1
    if (-not $line) { return "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c" }
    $s = $line.Line
    $parts = $s -split "\s+"
    $hexClass = "[" + "0-9a-fA-F\-" + "]"
    $guidRe = "^" + $hexClass + "{36}$"
    foreach ($p in $parts) {
        if ($p -match $guidRe) { return $p }
    }
    return "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
}

function Apply-WindowsOptimizations {
    param($Config)
    if ($Config.ApplyOptimizations -ne "1") { return }
    try {
        if ($Config.HighPerformancePower -eq "1") {
            $guid = Get-PowerGuid
            powercfg /setactive $guid 2>$null
        }
        if ($Config.GameMode -eq "1") {
            $path = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile"
            if (Test-Path $path) {
                Set-ItemProperty -Path $path -Name "GameDVR_Enabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $path -Name "GameDVR_FSEBehaviorMode" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            }
            $path2 = "HKCU:\Software\Microsoft\Windows\CurrentVersion\GameDVR"
            if (Test-Path $path2) { Set-ItemProperty -Path $path2 -Name "AppCaptureEnabled" -Value 0 -Type DWord -Force -ErrorAction SilentlyContinue }
        }
        if ($Config.DisableNagle -eq "1") {
            Get-ChildItem "HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces" -ErrorAction SilentlyContinue | ForEach-Object {
                try { Set-ItemProperty -Path $_.PSPath -Name "TcpAckFrequency" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
                try { Set-ItemProperty -Path $_.PSPath -Name "TCPNoDelay" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue } catch {}
            }
        }
        if ($Config.BackgroundServices -eq "0") {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NoLazyMode" -Value 1 -Type DWord -Force -ErrorAction SilentlyContinue
            $gamesPath = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile\Tasks\Games"
            if (Test-Path $gamesPath) {
                Set-ItemProperty -Path $gamesPath -Name "GPU Priority" -Value 8 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $gamesPath -Name "Priority" -Value 6 -Type DWord -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path $gamesPath -Name "Scheduling Category" -Value "High" -Type String -Force -ErrorAction SilentlyContinue
            }
        }
        if ($Config.NetworkThrottling -eq "1") {
            Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile" -Name "NetworkThrottlingIndex" -Value 0xffffffff -Type DWord -Force -ErrorAction SilentlyContinue
        }
        if ($Config.HardwareAccelGPU -eq "1") {
            $gpuPath = "HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers"
            if (Test-Path $gpuPath) {
                Set-ItemProperty -Path $gpuPath -Name "HwSchMode" -Value 2 -Type DWord -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {}
}

function Set-TimerResolution {
    try {
        $tdef = "using System; using System.Runtime.InteropServices; public class NtTimer { [DllImport(`"ntdll.dll`")] public static extern int NtSetTimerResolution(uint r, bool s, out uint c); }"
        $nt = Add-Type -TypeDefinition $tdef -PassThru -ErrorAction SilentlyContinue
        if ($nt) {
            $cur = [uint]0
            $nt::NtSetTimerResolution([uint]5000, $true, [ref]$cur) | Out-Null
        }
    } catch {}
}

function Get-StartupShortcutPath {
    $startup = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::Startup)
    Join-Path $startup "GameBoost.lnk"
}

function Test-StartupEnabled {
    $path = Get-StartupShortcutPath
    Test-Path $path
}

function Add-ToStartup {
    try {
        $batPath = Join-Path $ScriptDir "GameBoost.bat"
        $shortcutPath = Get-StartupShortcutPath
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($shortcutPath)
        
        # Create PowerShell wrapper script that elevates
        $wrapperScript = Join-Path $ScriptDir "GameBoost_Startup.ps1"
        $wrapperContent = @"
# GameBoost Startup Wrapper
# This script runs GameBoost.bat with admin rights
`$batPath = '$batPath'
`$scriptDir = '$ScriptDir'
Set-Location `$scriptDir
Start-Process -FilePath `$batPath -Verb RunAs -WorkingDirectory `$scriptDir
"@
        [System.IO.File]::WriteAllText($wrapperScript, $wrapperContent, [System.Text.Encoding]::UTF8)
        
        # Create shortcut pointing to PowerShell wrapper
        $sc.TargetPath = "powershell.exe"
        $sc.Arguments = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -File `"$wrapperScript`""
        $sc.WorkingDirectory = $ScriptDir
        $sc.Description = "GameBoost"
        $sc.WindowStyle = 7
        $sc.Save()
        
        [System.Runtime.Interopservices.Marshal]::ReleaseComObject($shell) | Out-Null
        Write-Log "Added to startup" "INFO"
        return $true
    } catch { 
        Write-Log "Startup add error: $_" "WARN"
        return $false 
    }
}

function Remove-FromStartup {
    try {
        $path = Get-StartupShortcutPath
        if (Test-Path $path) { Remove-Item $path -Force }
        $wrapperScript = Join-Path $ScriptDir "GameBoost_Startup.ps1"
        if (Test-Path $wrapperScript) { Remove-Item $wrapperScript -Force -ErrorAction SilentlyContinue }
        Write-Log "Removed from startup" "INFO"
        return $true
    } catch { 
        Write-Log "Startup remove error: $_" "WARN"
        return $false 
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutexName = "Global\GameBoost_SingleInstance"
$mutex = New-Object System.Threading.Mutex($false, $mutexName)
if (-not $mutex.WaitOne(0, $false)) {
    [System.Windows.Forms.MessageBox]::Show("GameBoost is already running. Close it via tray icon (right-click -> Exit).", "GameBoost")
    exit
}

$script:ExitRequested = $false
$script:Config = Read-Config
if ($script:Config.LogPath) { $script:LogPath = $script:Config.LogPath }

$form = New-Object System.Windows.Forms.Form
$form.Visible = $false
$form.ShowInTaskbar = $false
$form.WindowState = "Minimized"
$form.Load += { $form.WindowState = "Minimized"; $form.Hide() }

$ni = New-Object System.Windows.Forms.NotifyIcon
$ni.Icon = [System.Drawing.SystemIcons]::Application
$ni.Text = "GameBoost - running"
$ni.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$item1 = $menu.Items.Add("Pause monitoring", $null, {
    $script:Paused = -not $script:Paused
    if ($script:Paused) { $ni.Text = "GameBoost - paused" } else { $ni.Text = "GameBoost - running" }
})
$item2 = $menu.Items.Add("Apply optimizations now", $null, {
    $script:Config = Read-Config
    Apply-WindowsOptimizations $script:Config
    Set-TimerResolution
    [System.Windows.Forms.MessageBox]::Show("Optimizations applied.", "GameBoost")
})
$item3 = $menu.Items.Add("Restore audio", $null, {
    $script:Config = Read-Config
    Repair-Audio $script:Config
    [System.Windows.Forms.MessageBox]::Show("Audio services restarted.", "GameBoost")
})
$item4 = $menu.Items.Add("Refresh config", $null, { $script:Config = Read-Config })
$startupLabel = if (Test-StartupEnabled) { "Start with Windows: On" } else { "Start with Windows: Off" }
$itemStartup = $menu.Items.Add($startupLabel, $null, {
    if (Test-StartupEnabled) {
        Remove-FromStartup | Out-Null
        $itemStartup.Text = "Start with Windows: Off"
        [System.Windows.Forms.MessageBox]::Show("Removed from startup. GameBoost will not run at logon.", "GameBoost")
    } else {
        if (Add-ToStartup) {
            $itemStartup.Text = "Start with Windows: On"
            [System.Windows.Forms.MessageBox]::Show("Added to startup. GameBoost will run when you log on (UAC prompt may appear).", "GameBoost")
        } else {
            [System.Windows.Forms.MessageBox]::Show("Failed to add to startup.", "GameBoost")
        }
    }
})
$item5 = $menu.Items.Add("Exit", $null, {
    $script:ExitRequested = $true
    $mutex.ReleaseMutex() | Out-Null
    $mutex.Dispose()
    $form.Close()
})
$ni.ContextMenuStrip = $menu

$ni.DoubleClick += {
    $script:Config = Read-Config
    $msg = "GameBoost active. Paused: $($script:Paused). Low: $($script:Config.LowPriority -join ', '). High: $($script:Config.HighPriority -join ', ')"
    [System.Windows.Forms.MessageBox]::Show($msg, "GameBoost")
}

Apply-WindowsOptimizations $script:Config
if ($script:Config.TimerResolution -eq "1") { Set-TimerResolution }

$script:LastProcessCheck = [datetime]::MinValue
$script:LastAudioCheck   = [datetime]::MinValue
$script:LastOptCheck     = [datetime]::MinValue
$script:Paused           = $false

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    if ($script:ExitRequested) {
        $timer.Stop()
        $ni.Visible = $false
        $form.Close()
        return
    }
    if ($script:Paused) {
        [System.Windows.Forms.Application]::DoEvents()
        return
    }
    $script:Config = Read-Config
    $now = Get-Date
    if (($now - $script:LastProcessCheck).TotalSeconds -ge $script:Config.ProcessCheckInterval) {
        $script:LastProcessCheck = $now
        Set-ProcessPriorities $script:Config
    }
    if ($script:Config.FixAudio -eq "1" -and ($now - $script:LastAudioCheck).TotalSeconds -ge $script:Config.AudioCheckInterval) {
        $script:LastAudioCheck = $now
        try {
            if (-not (Test-AudioWorking)) {
                Write-Log "Audio not working, attempting repair..." "AUDIO"
                Repair-Audio $script:Config
            }
        } catch {
            Write-Log "Audio check/repair error in timer: $_" "WARN"
        }
    }
    if ($script:Config.ApplyOptimizations -eq "1" -and $script:Config.OptimizationCheckInterval -gt 0 -and ($now - $script:LastOptCheck).TotalMinutes -ge $script:Config.OptimizationCheckInterval) {
        $script:LastOptCheck = $now
        Apply-WindowsOptimizations $script:Config
    }
    [System.Windows.Forms.Application]::DoEvents()
})

$timer.Start()

$hideConsole = "[DllImport(`"user32.dll`")]`npublic static extern bool ShowWindow(IntPtr hwnd, int nCmdShow);"
try {
    $null = Add-Type -MemberDefinition $hideConsole -Name "Win32ShowWindow" -Namespace "Native" -PassThru -ErrorAction SilentlyContinue
    $hwnd = (Get-Process -Id $pid).MainWindowHandle
    if ($hwnd -ne [IntPtr]::Zero) {
        [Native.Win32ShowWindow]::ShowWindow($hwnd, 0)
    }
} catch {}

try {
    [void][System.Windows.Forms.Application]::Run($form)
} finally {
    try { $mutex.ReleaseMutex() | Out-Null } catch {}
    try { $mutex.Dispose() } catch {}
}
$ni.Dispose()

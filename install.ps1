# SteamBond installer.
# Copies the app to %LOCALAPPDATA%\SteamBond, downloads mihomo from its official GitHub release
# (SHA-256 checked), adds Desktop + Start Menu shortcuts, an Apps & Features entry, and a scheduled
# task so SteamBond opens with admin rights without a popup every time.
#
#   Run from a downloaded copy:  powershell -ExecutionPolicy Bypass -File install.ps1
#   Or straight from GitHub:     irm https://raw.githubusercontent.com/brutal888/SteamBond/main/install.ps1 | iex
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'SteamBond'),
    [switch]$Test   # files + mihomo only: no admin, task, shortcuts, registry or launch (used for testing)
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$Repo     = 'brutal888/SteamBond'
$Branch   = 'main'
$Version  = '2.1.2'
$TaskName = 'SteamBond'
$Mihomo = @{
    Version = 'v1.19.32'
    amd64   = @{ File = 'mihomo-windows-amd64-compatible-v1.19.32.zip'; Sha256 = '974a4d7ad69aed27aa2e8f91d61113573c14dadb14562c63e58effabf59816f0' }
    arm64   = @{ File = 'mihomo-windows-arm64-v1.19.32.zip';            Sha256 = '7a4f6e58af9a120920935f2150cf642d945085fdb3e753314505b334234e1d1e' }
}
$AppFiles = @('SteamBond.ps1', 'SteamBond.ico', 'uninstall.ps1')

function Say($msg, $color = 'Gray') { Write-Host $msg -ForegroundColor $color }
function Finish($code) {
    if (-not $Test -and $Host.Name -eq 'ConsoleHost') { Write-Host ''; Read-Host 'Press Enter to close' | Out-Null }
    if ($PSCommandPath) { exit $code }
}

Say ''
Say "  SteamBond $Version setup" 'Cyan'
Say '  Combine your internet connections for game downloads' 'DarkGray'
Say ''

# ---- admin (needed for the no-popup task); -Wait so a self-extracting setup keeps its files ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $Test) {
    Say '  Asking for administrator rights...' 'Yellow'
    $script = $PSCommandPath
    if (-not $script) {
        # Running via "irm | iex": save a copy so the elevated window can run it
        $script = Join-Path $env:TEMP 'steambond-install.ps1'
        Invoke-WebRequest "https://raw.githubusercontent.com/$Repo/$Branch/install.ps1" -OutFile $script -UseBasicParsing
    }
    try {
        $p = Start-Process powershell.exe -Verb RunAs -Wait -PassThru -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$script`"", '-InstallDir', "`"$InstallDir`"")
        if ($PSCommandPath) { exit $p.ExitCode } else { return }
    } catch {
        Say '  Setup needs administrator rights (Windows asked and it was declined).' 'Red'
        Finish 1; return
    }
}

try {
    # ---- where the app files come from: next to this script, or GitHub ----
    $src = $PSScriptRoot
    if (-not $src -or -not (Test-Path (Join-Path $src 'SteamBond.ps1'))) {
        $src = Join-Path $env:TEMP "steambond-src-$PID"
        New-Item -ItemType Directory -Force $src | Out-Null
        Say '  Downloading SteamBond from GitHub...'
        foreach ($f in $AppFiles) { Invoke-WebRequest "https://raw.githubusercontent.com/$Repo/$Branch/$f" -OutFile (Join-Path $src $f) -UseBasicParsing }
    }

    # ---- stop a running copy before replacing files ----
    $running = Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$InstallDir\SteamBond.ps1*" }
    if ($running) { Say '  Closing the running SteamBond...'; $running | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue } }
    Get-Process mihomo -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$InstallDir\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500

    # ---- app files ----
    New-Item -ItemType Directory -Force $InstallDir | Out-Null
    foreach ($f in $AppFiles) { Copy-Item (Join-Path $src $f) (Join-Path $InstallDir $f) -Force }
    @'
@echo off
rem Opens SteamBond: through the no-popup task if it exists, otherwise asks for admin.
schtasks /run /tn "SteamBond" >nul 2>&1 && exit /b
net session >nul 2>&1 || (powershell -NoProfile -Command "Start-Process '%~f0' -Verb RunAs" & exit /b)
start "" powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0SteamBond.ps1"
'@ | Set-Content (Join-Path $InstallDir 'Start SteamBond.bat') -Encoding ASCII
    Get-ChildItem $InstallDir -File | Unblock-File
    Say "  Installed app to $InstallDir" 'Green'

    # ---- mihomo (official release, hash-checked) ----
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'amd64' }
    $build = $Mihomo[$arch]
    $stamp = Join-Path $InstallDir 'mihomo.version'
    $exe = Join-Path $InstallDir 'mihomo.exe'
    if ((Test-Path $exe) -and (Test-Path $stamp) -and ((Get-Content $stamp -Raw).Trim() -eq $build.File)) {
        Say "  mihomo $($Mihomo.Version) already installed" 'Green'
    } else {
        Say "  Downloading mihomo $($Mihomo.Version) ($arch) from github.com/MetaCubeX/mihomo..."
        $zip = Join-Path $env:TEMP $build.File
        Invoke-WebRequest "https://github.com/MetaCubeX/mihomo/releases/download/$($Mihomo.Version)/$($build.File)" -OutFile $zip -UseBasicParsing
        $hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($hash -ne $build.Sha256) { Remove-Item $zip -Force; throw "mihomo download failed its checksum ($hash). Nothing was installed from it." }
        $unz = Join-Path $env:TEMP "steambond-mihomo-$PID"
        Expand-Archive $zip $unz -Force
        $found = Get-ChildItem $unz -Filter '*.exe' -Recurse | Select-Object -First 1
        Copy-Item $found.FullName $exe -Force
        Unblock-File $exe
        Set-Content $stamp $build.File
        Remove-Item $zip, $unz -Recurse -Force -ErrorAction SilentlyContinue
        Say '  mihomo downloaded and verified' 'Green'
    }

    if (-not $Test) {
        # ---- no-popup task ----
        $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$InstallDir\SteamBond.ps1`"" -WorkingDirectory $InstallDir
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $settings -Description 'Opens SteamBond with admin rights without a popup' -Force | Out-Null
        Say '  SteamBond will open without the admin popup' 'Green'

        # ---- shortcuts ----
        $sh = New-Object -ComObject WScript.Shell
        $places = @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) ''))
        foreach ($dir in $places) {
            $lnk = $sh.CreateShortcut((Join-Path $dir 'SteamBond.lnk'))
            $lnk.TargetPath = Join-Path $env:WINDIR 'System32\schtasks.exe'
            $lnk.Arguments = "/run /tn `"$TaskName`""
            $lnk.WorkingDirectory = $InstallDir
            $lnk.IconLocation = "$InstallDir\SteamBond.ico,0"
            $lnk.Description = 'Combine your internet connections for game downloads'
            $lnk.WindowStyle = 7
            $lnk.Save()
        }
        Say '  Added Desktop and Start Menu shortcuts' 'Green'

        # ---- Apps & Features entry ----
        $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SteamBond'
        New-Item $key -Force | Out-Null
        $vals = @{
            DisplayName = 'SteamBond'; DisplayVersion = $Version; Publisher = 'brutal888'
            DisplayIcon = "$InstallDir\SteamBond.ico"; InstallLocation = $InstallDir
            UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$InstallDir\uninstall.ps1`""
            URLInfoAbout = "https://github.com/$Repo"
        }
        foreach ($k in $vals.Keys) { Set-ItemProperty $key $k $vals[$k] }
        Set-ItemProperty $key NoModify 1 -Type DWord; Set-ItemProperty $key NoRepair 1 -Type DWord

        Say ''
        Say '  Done! Opening SteamBond...' 'Cyan'
        Start-ScheduledTask -TaskName $TaskName
    }
    Finish 0
} catch {
    Say ''
    Say "  Setup failed: $($_.Exception.Message)" 'Red'
    Finish 1
}

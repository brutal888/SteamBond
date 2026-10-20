# Removes SteamBond: stops it, deletes the task, shortcuts, Apps & Features entry and the install folder.
$ErrorActionPreference = 'SilentlyContinue'
$InstallDir = $PSScriptRoot
$TaskName = 'SteamBond'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    try { Start-Process powershell.exe -Verb RunAs -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"") } catch {}
    exit
}

Add-Type -AssemblyName System.Windows.Forms
if ([Windows.Forms.MessageBox]::Show('Remove SteamBond from this PC?', 'SteamBond', 'YesNo', 'Question') -ne 'Yes') { exit }

# Stop the app and mihomo (your internet goes back to normal)
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$InstallDir\SteamBond.ps1*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
Get-Process mihomo | Where-Object { $_.Path -like "$InstallDir\*" } | Stop-Process -Force

Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Remove-Item (Join-Path ([Environment]::GetFolderPath('Desktop')) 'SteamBond.lnk') -Force
Remove-Item (Join-Path ([Environment]::GetFolderPath('Programs')) 'SteamBond.lnk') -Force
Remove-Item 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\SteamBond' -Recurse -Force

[Windows.Forms.MessageBox]::Show('SteamBond has been removed.', 'SteamBond') | Out-Null
# This script lives in the folder being deleted, so delete it a moment after exiting
Start-Process cmd.exe -WindowStyle Hidden -ArgumentList "/c timeout /t 2 >nul & rmdir /s /q `"$InstallDir`""

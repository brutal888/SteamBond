# Builds dist\SteamBond-Setup.exe (a self-extracting installer made with Windows' built-in IExpress)
# and dist\SteamBond-Setup.zip. mihomo is not bundled: setup downloads it from the official release.
$ErrorActionPreference = 'Stop'
$Root  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dist  = Join-Path $Root 'dist'
$Stage = Join-Path $Dist 'stage'
New-Item -ItemType Directory -Force $Stage | Out-Null
$files = 'install.ps1', 'SteamBond.ps1', 'SteamBond.ico', 'uninstall.ps1'
foreach ($f in $files) { Copy-Item (Join-Path $Root $f) $Stage -Force }

$exe = Join-Path $Dist 'SteamBond-Setup.exe'
$sed = Join-Path $Dist 'setup.sed'
$fileLines = for ($i = 0; $i -lt $files.Count; $i++) { "FILE$i=`"$($files[$i])`"" }
$srcLines  = for ($i = 0; $i -lt $files.Count; $i++) { "%FILE$i%=" }
@"
[Version]
Class=IEXPRESS
SEDVersion=3
[Options]
PackagePurpose=InstallApp
ShowInstallProgramWindow=0
HideExtractAnimation=1
UseLongFileName=1
InsideCompressed=0
CAB_FixedSize=0
CAB_ResvCodeSigning=0
RebootMode=N
InstallPrompt=%InstallPrompt%
DisplayLicense=%DisplayLicense%
FinishMessage=%FinishMessage%
TargetName=%TargetName%
FriendlyName=%FriendlyName%
AppLaunched=%AppLaunched%
PostInstallCmd=%PostInstallCmd%
AdminQuietInstCmd=%AdminQuietInstCmd%
UserQuietInstCmd=%UserQuietInstCmd%
SourceFiles=SourceFiles
[Strings]
InstallPrompt=
DisplayLicense=
FinishMessage=
TargetName=$exe
FriendlyName=SteamBond Setup
AppLaunched=powershell.exe -NoProfile -ExecutionPolicy Bypass -File install.ps1
PostInstallCmd=<None>
AdminQuietInstCmd=
UserQuietInstCmd=
$($fileLines -join "`r`n")
[SourceFiles]
SourceFiles0=$Stage\
[SourceFiles0]
$($srcLines -join "`r`n")
"@ -replace "`r?`n", "`r`n" | Set-Content $sed -Encoding ASCII   # IExpress needs Windows line endings

Remove-Item $exe -ErrorAction SilentlyContinue
# IExpress only works when run from the .sed file's folder with a bare file name
Push-Location $Dist
cmd /c "`"$env:WINDIR\System32\iexpress.exe`" /N /Q setup.sed"
Pop-Location
if (-not (Test-Path $exe)) { throw 'IExpress failed to build the setup' }

$zip = Join-Path $Dist 'SteamBond-Setup.zip'
Copy-Item (Join-Path $Root 'README.md') $Stage -Force
@'
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1"
'@ | Set-Content (Join-Path $Stage 'Install SteamBond.bat') -Encoding ASCII
Compress-Archive -Path "$Stage\*" -DestinationPath $zip -Force
Remove-Item $sed, $Stage -Recurse -Force
Get-ChildItem $Dist | Select-Object Name, Length

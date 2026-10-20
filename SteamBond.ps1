# SteamBond: combine several internet connections for game downloads.
# mihomo runs in TUN mode; game launchers go through a weighted round-robin of the networks you tick,
# everything else stays on your main network.
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
# Own taskbar identity, so Windows shows SteamBond's icon instead of grouping it under PowerShell.
Add-Type -Namespace SteamBond -Name Shell -MemberDefinition '[DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID([MarshalAs(UnmanagedType.LPWStr)] string id);'
[void][SteamBond.Shell]::SetCurrentProcessExplicitAppUserModelID('33S.SteamBond')
[System.Windows.Forms.Application]::EnableVisualStyles()

# One copy at a time: a second launch just brings the first one's window back.
$created = $false
$script:Mutex = New-Object Threading.Mutex($true, 'Local\33S.SteamBond', [ref]$created)
$script:ShowEvent = New-Object Threading.EventWaitHandle($false, 'AutoReset', 'Local\33S.SteamBond.Show')
if (-not $created) { [void]$script:ShowEvent.Set(); exit }

$Root         = Split-Path -Parent $MyInvocation.MyCommand.Path
$Exe          = Join-Path $Root 'mihomo.exe'
$Config       = Join-Path $Root 'config.yaml'
$LogFile      = Join-Path $Root 'mihomo.log'
$SettingsFile = Join-Path $Root 'settings.json'
$HistoryFile  = Join-Path $Root 'history.json'
$IconFile     = Join-Path $Root 'SteamBond.ico'
$Api          = 'http://127.0.0.1:9090'
$TaskName     = 'SteamBond'
$TunName      = 'SteamBond'

# ---------- launchers ----------
# group 'bond' = round-robin per connection (fastest for launchers that open many connections)
# group 'bond-web' = each website sticks to one network (keeps logins and banking working)
$Launchers = [ordered]@{
    'Steam'           = @{ Group = 'bond';     Procs = @('steam.exe', 'steamservice.exe'); Domains = @('steamcontent.com') }
    'Epic Games'      = @{ Group = 'bond';     Procs = @('EpicGamesLauncher.exe', 'EpicWebHelper.exe'); Domains = @('download.epicgames.com', 'download2.epicgames.com', 'download3.epicgames.com', 'download4.epicgames.com', 'epicgames-download1.akamaized.net', 'fastly-download.epicgames.com') }
    'EA app'          = @{ Group = 'bond';     Procs = @('EADesktop.exe', 'EABackgroundService.exe', 'EALocalHostSvc.exe'); Domains = @() }
    'Ubisoft Connect' = @{ Group = 'bond';     Procs = @('UbisoftConnect.exe', 'upc.exe', 'UplayWebCore.exe', 'UbisoftGameLauncher.exe'); Domains = @() }
    'Battle.net'      = @{ Group = 'bond';     Procs = @('Battle.net.exe', 'Agent.exe'); Domains = @() }
    'Browsers'        = @{ Group = 'bond-web'; Procs = @('chrome.exe', 'msedge.exe', 'firefox.exe', 'brave.exe', 'opera.exe'); Domains = @() }
}
$script:ProcLabel = @{}
foreach ($k in $Launchers.Keys) { foreach ($p in $Launchers[$k].Procs) { $script:ProcLabel[$p.ToLower()] = $k } }

# ---------- settings & history ----------
function ConvertTo-NumberHash($o) {
    $h = @{}
    if ($o) { foreach ($p in $o.PSObject.Properties) { $h[$p.Name] = [double]$p.Value } }
    $h
}

$script:Settings = @{
    networks = @(); main = ''; smartSplit = $true; weights = @{}; speeds = @{}
    apps = @('Steam'); downloadDir = ''; watchClipboard = $true; autoMode = $false; autoRestartSteam = $false; closeToTray = $true; trayHintShown = $false
}
if (Test-Path $SettingsFile) {
    try {
        $j = Get-Content $SettingsFile -Raw | ConvertFrom-Json
        foreach ($p in $j.PSObject.Properties) {
            if ($p.Name -in 'weights', 'speeds') { $script:Settings[$p.Name] = ConvertTo-NumberHash $p.Value }
            elseif ($p.Name -in 'networks', 'apps') { $script:Settings[$p.Name] = @($p.Value | Where-Object { $_ }) }
            else { $script:Settings[$p.Name] = $p.Value }
        }
    } catch {}
}
function Save-Settings { $script:Settings | ConvertTo-Json -Depth 5 | Set-Content $SettingsFile -Encoding UTF8 }

$script:History = @{}
if (Test-Path $HistoryFile) {
    try {
        $j = Get-Content $HistoryFile -Raw | ConvertFrom-Json
        foreach ($d in $j.PSObject.Properties) {
            $script:History[$d.Name] = @{ networks = ConvertTo-NumberHash $d.Value.networks; apps = ConvertTo-NumberHash $d.Value.apps; games = ConvertTo-NumberHash $d.Value.games; files = ConvertTo-NumberHash $d.Value.files }
        }
    } catch {}
}
function Save-History { try { $script:History | ConvertTo-Json -Depth 5 | Set-Content $HistoryFile -Encoding UTF8 } catch {} }
function Add-History($kind, $name, [double]$bytes) {
    if ($bytes -le 0 -or -not $name) { return }
    $day = (Get-Date).ToString('yyyy-MM-dd')
    if (-not $script:History.ContainsKey($day)) { $script:History[$day] = @{ networks = @{}; apps = @{}; games = @{}; files = @{} } }
    if (-not $script:History[$day].ContainsKey($kind)) { $script:History[$day][$kind] = @{} }
    $bucket = $script:History[$day][$kind]
    if ($bucket.ContainsKey($name)) { $bucket[$name] += $bytes } else { $bucket[$name] = $bytes }
}

# ---------- networks ----------
function Get-Networks {
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback' -or $ni.Name -in $TunName, 'Meta') { continue }
        $props = $ni.GetIPProperties()
        $gw = $props.GatewayAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' -and $_.Address.ToString() -ne '0.0.0.0' } | Select-Object -First 1
        $ip = $props.UnicastAddresses | Where-Object { $_.Address.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if (-not $gw -or -not $ip -or $ip.Address.ToString() -like '198.18.*') { continue }
        [pscustomobject]@{ Name = $ni.Name; IP = $ip.Address.ToString(); Iface = $ni }
    }
}

$SpeedTestUrls = @(
    'https://sin-speed.hetzner.com/100MB.bin'
    'http://speedtest.singapore.linode.com/100MB-singapore.bin'
    'https://speed.cloudflare.com/__down?bytes=100000000'
    'https://proof.ovh.net/files/100Mb.dat'
)
function Measure-Speeds($nets) {
    # Parallel 6-second download test on each network, bound to that network's IP.
    # A server that refuses or errors (tiny download) is skipped and the next one tried.
    $r = @{}
    foreach ($n in $nets) { $r[$n.Name] = 0.0 }
    $todo = @($nets)
    foreach ($url in $SpeedTestUrls) {
        if (-not $todo.Count) { break }
        $jobs = foreach ($n in $todo) {
            $out = Join-Path $env:TEMP "steambond-speed-$($n.IP).txt"
            $p = Start-Process curl.exe -ArgumentList @('-4', '-s', '-o', 'NUL', '-m', '6', '--interface', $n.IP, '-w', '%{http_code}_%{size_download}_%{speed_download}', $url) -WindowStyle Hidden -PassThru -RedirectStandardOutput $out
            [pscustomobject]@{ Net = $n; Proc = $p; Out = $out }
        }
        while ($jobs | Where-Object { -not $_.Proc.HasExited }) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
        $next = @()
        foreach ($j in $jobs) {
            $parts = ('' + (Get-Content $j.Out -Raw -ErrorAction SilentlyContinue)).Trim() -split '_'
            Remove-Item $j.Out -ErrorAction SilentlyContinue
            $size = 0.0; $speed = 0.0
            if ($parts.Count -ge 3) {
                [void][double]::TryParse($parts[1], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$size)
                [void][double]::TryParse($parts[2], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$speed)
            }
            if ($parts[0] -eq '200' -and $size -ge 2MB) { $r[$j.Net.Name] = $speed } else { $next += $j.Net }
        }
        $todo = $next
    }
    $r
}

function Get-Weights($speeds) {
    $w = @{}
    $pos = @($speeds.Values | Where-Object { $_ -gt 0 })
    $min = if ($pos.Count) { ($pos | Measure-Object -Minimum).Minimum } else { 0 }
    foreach ($k in $speeds.Keys) {
        $w[$k] = if ($min -le 0 -or $speeds[$k] -le 0) { 1 } else { [int][math]::Min(5, [math]::Max(1, [math]::Round($speeds[$k] / $min))) }
    }
    $w
}

function Get-Weight($name) {
    if ($script:Settings.smartSplit -and $script:Settings.weights.ContainsKey($name)) { [int]$script:Settings.weights[$name] } else { 1 }
}

# The networks SteamBond should use right now: ticked and connected, main first.
function Get-WantedNets {
    $up = @($script:Nets | ForEach-Object { $_.Name })
    $want = @($script:Settings.networks | Where-Object { $_ -in $up })
    $main = if ($script:Settings.main -in $want) { $script:Settings.main } elseif ($want.Count) { $want[0] } else { $null }
    if ($main) { @($main) + @($want | Where-Object { $_ -ne $main }) } else { @() }
}
function Get-WantKey { $n = Get-WantedNets; (($n | ForEach-Object { "$_=$(Get-Weight $_)" }) -join '|') + '#' + ($script:Settings.apps -join ',') }

function Q($s) { '"' + ($s -replace '"', '\"') + '"' }

function Write-Config($nets) {
    $proxies = @(); $bond = @()
    $maxW = ($nets | ForEach-Object { Get-Weight $_ } | Measure-Object -Maximum).Maximum
    foreach ($n in $nets) {
        for ($i = 1; $i -le (Get-Weight $n); $i++) {
            $name = if ($i -eq 1) { $n } else { "$n #$i" }
            $proxies += "  - { name: $(Q $name), type: direct, interface-name: $(Q $n) }"
        }
    }
    # Interleave copies so a 3:1 split goes A,B,A,A rather than A,A,A,B
    for ($r = 1; $r -le $maxW; $r++) { foreach ($n in $nets) { if ((Get-Weight $n) -ge $r) { $bond += $(if ($r -eq 1) { Q $n } else { Q "$n #$r" }) } } }
    $plain = ($nets | ForEach-Object { Q $_ }) -join ', '

    $rules = @()
    foreach ($app in $script:Settings.apps) {
        if (-not $Launchers.Contains($app)) { continue }
        $l = $Launchers[$app]
        foreach ($p in $l.Procs) { $rules += "  - PROCESS-NAME,$p,$($l.Group)" }
        foreach ($d in $l.Domains) { $rules += "  - DOMAIN-SUFFIX,$d,$($l.Group)" }
    }
    $rules += '  - MATCH,main'

    @"
# Written by SteamBond.ps1 - change settings in the app, not here.
mixed-port: 7890
external-controller: 127.0.0.1:9090
mode: rule
log-level: warning
ipv6: false
find-process-mode: always

tun:
  enable: true
  device: $TunName
  stack: mixed
  auto-route: true
  auto-detect-interface: true
  dns-hijack:
    - any:53

dns:
  enable: true
  ipv6: false
  enhanced-mode: redir-host
  nameserver:
    - 1.1.1.1#main
    - 8.8.8.8#main

proxies:
$($proxies -join "`n")

proxy-groups:
  - name: bond
    type: load-balance
    strategy: round-robin
    proxies: [$($bond -join ', ')]
    url: http://www.gstatic.com/generate_204
    interval: 30
    lazy: false
  - name: bond-web
    type: load-balance
    strategy: consistent-hashing
    proxies: [$plain]
    url: http://www.gstatic.com/generate_204
    interval: 30
    lazy: false
  - name: main
    type: fallback
    proxies: [$plain]
    url: http://www.gstatic.com/generate_204
    interval: 30

rules:
$($rules -join "`n")
"@ | Set-Content -Path $Config -Encoding UTF8
}

# ---------- Steam ----------
function Get-SteamPath {
    $p = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue).SteamPath
    if ($p) { $p -replace '/', '\' } else { 'C:\Program Files (x86)\Steam' }
}
function Get-SteamLibraries {
    $steam = Get-SteamPath
    $libs = @($steam)
    $vdf = Join-Path $steam 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) { foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) { $libs += ($m.Groups[1].Value -replace '\\\\', '\') } }
    $unique = [ordered]@{}   # Steam stores the same folder in different letter case
    foreach ($l in $libs) { $k = $l.TrimEnd('\').ToLower(); if (-not $unique.Contains($k) -and (Test-Path (Join-Path $l 'steamapps'))) { $unique[$k] = $l.TrimEnd('\') } }
    @($unique.Values)
}
$script:SteamLibs = Get-SteamLibraries

# Steam writes "Current download rate" to content_log.txt about once a minute while it downloads.
function Get-SteamDownload {
    $res = @{ Active = $false; Game = $null; Mbps = $null }
    $log = Join-Path (Get-SteamPath) 'logs\content_log.txt'
    if (Test-Path $log) {
        $last = Get-Content $log -Tail 60 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'Current download rate: ([\d.]+) Mbps' } | Select-Object -Last 1
        if ($last -and $last -match '^\[(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d)\].*rate: ([\d.]+)') {
            $when = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss', [Globalization.CultureInfo]::InvariantCulture)
            $mbps = [double]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture)
            if (((Get-Date) - $when).TotalSeconds -lt 100 -and $mbps -gt 0) { $res.Active = $true; $res.Mbps = $mbps }
        }
    }
    # Which game: the app whose manifest says "update running" (StateFlags bit 1024), newest download folder first
    $best = $null
    foreach ($lib in $script:SteamLibs) {
        foreach ($d in (Get-ChildItem (Join-Path $lib 'steamapps\downloading') -Directory -ErrorAction SilentlyContinue)) {
            $acf = Join-Path $lib "steamapps\appmanifest_$($d.Name).acf"
            if (-not (Test-Path $acf)) { continue }
            $t = Get-Content $acf -Raw -Encoding UTF8
            $flags = [int]([regex]::Match($t, '"StateFlags"\s+"(\d+)"').Groups[1].Value)
            if (($flags -band 1024) -and (-not $best -or $d.LastWriteTime -gt $best.Time)) {
                $best = @{ Time = $d.LastWriteTime; Name = [regex]::Match($t, '"name"\s+"([^"]+)"').Groups[1].Value }
            }
        }
    }
    if ($best) { $res.Game = $best.Name }
    $res
}

function Restart-Steam {
    $exe = Join-Path (Get-SteamPath) 'steam.exe'
    if (-not (Test-Path $exe)) { Show-Tip 'Could not find steam.exe'; return }
    if (Get-Process steam -ErrorAction SilentlyContinue) {
        Set-Status 'Closing Steam...' 'DimGray'
        Start-Process $exe -ArgumentList '-shutdown'
        $deadline = (Get-Date).AddSeconds(30)
        while ((Get-Process steam -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 200 }
        Get-Process steam -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    }
    # Launch through Explorer so Steam runs as you, not as administrator
    Start-Process explorer.exe -ArgumentList "`"$exe`""
    Show-Tip 'Steam restarted - its downloads now go through SteamBond'
    Update-Buttons
}

# ---------- mihomo control ----------
$script:Running = $false
$script:StartedByAuto = $false
$script:ActiveKey = ''
$script:Proc = $null
$script:CrashRestarts = 0

function Start-Bond([bool]$measure, [bool]$auto = $false) {
    $script:Nets = @(Get-Networks)
    $nets = Get-WantedNets
    if ($nets.Count -lt 1) { Set-Status 'Tick at least one connected network first' 'DarkOrange'; return $false }
    Stop-Bond -Quiet
    if ($measure -and $script:Settings.smartSplit -and $nets.Count -gt 1) {
        Set-Status 'Measuring each network''s speed (6 seconds)...' 'DimGray'
        $sp = Measure-Speeds @($script:Nets | Where-Object { $_.Name -in $nets })
        $script:Settings.speeds = $sp
        $script:Settings.weights = Get-Weights $sp
        Save-Settings
        Update-SpeedLabel
    }
    Write-Config $nets
    $test = & $Exe -t -d $Root 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { [Windows.Forms.MessageBox]::Show("Config error:`n$test", 'SteamBond') | Out-Null; return $false }
    $script:Proc = Start-Process -FilePath $Exe -ArgumentList @('-d', "`"$Root`"") -WindowStyle Hidden -PassThru -RedirectStandardOutput $LogFile -RedirectStandardError "$LogFile.err"
    $deadline = (Get-Date).AddSeconds(2)
    while ((Get-Date) -lt $deadline -and -not $script:Proc.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 100 }
    if ($script:Proc.HasExited) {
        $err = (Get-Content "$LogFile.err", $LogFile -ErrorAction SilentlyContinue | Select-Object -Last 8) -join "`n"
        [Windows.Forms.MessageBox]::Show("SteamBond could not start:`n$err", 'SteamBond') | Out-Null
        $script:Proc = $null; return $false
    }
    $script:Running = $true
    $script:StartedByAuto = $auto
    $script:ActiveKey = Get-WantKey
    $script:Seen = @{}
    Set-Status "Running on $($nets -join ' + ')$(if (-not $auto) { '  -  press Restart Steam' })" 'ForestGreen'
    Update-Buttons
    $true
}

function Reload-Bond {
    $nets = Get-WantedNets
    if ($nets.Count -lt 1) { return }
    Write-Config $nets
    try {
        Invoke-RestMethod -Method Put "$Api/configs?force=true" -Body (@{ path = $Config } | ConvertTo-Json) -ContentType 'application/json' -TimeoutSec 5 | Out-Null
        $script:ActiveKey = Get-WantKey
        Set-Status "Running on $($nets -join ' + ')" 'ForestGreen'
    } catch { [void](Start-Bond $false $script:StartedByAuto) }
}

function Stop-Bond([switch]$Quiet) {
    Get-Process mihomo -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $script:Proc = $null; $script:Running = $false; $script:StartedByAuto = $false
    if (-not $Quiet) { Set-Status 'Stopped - internet is back to normal' 'Black'; Update-Buttons }
}

# ---------- split downloads ----------
# A file is cut into chunks; each network runs a few curl.exe workers (more on faster networks) bound to
# that network's IP, taking chunks from a shared queue. Works whether or not Start is pressed.
$UserAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36'
$script:Downloads = New-Object Collections.Generic.List[object]
$script:NextDownloadId = 1

function Get-DownloadDir {
    $d = $script:Settings.downloadDir
    if ($d -and (Test-Path $d)) { return $d }
    try { $d = (New-Object -ComObject Shell.Application).Namespace('shell:Downloads').Self.Path } catch {}
    if (-not $d) { $d = Join-Path $env:USERPROFILE 'Downloads' }
    $d
}

function Quote-Arg($a) { '"' + ($a -replace '"', '\"') + '"' }
function Start-Curl($argList) {
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = 'curl.exe'
    $psi.Arguments = ($argList | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    [Diagnostics.Process]::Start($psi)
}

function Get-SafeName($name) {
    foreach ($ch in [IO.Path]::GetInvalidFileNameChars()) { $name = ('' + $name).Replace([string]$ch, '_') }
    $name = $name.Trim(' ', '.')
    if (-not $name) { 'download' } else { $name }
}

function Get-FreePath($dir, $name) {
    $p = Join-Path $dir $name
    $base = [IO.Path]::GetFileNameWithoutExtension($name); $ext = [IO.Path]::GetExtension($name); $i = 1
    while ((Test-Path $p) -or ($script:Downloads.ToArray() | Where-Object { $_.Path -eq $p -and $_.Status -notmatch '^(Failed|Cancelled)' })) { $p = Join-Path $dir "$base ($i)$ext"; $i++ }
    $p
}

# Asks the server for byte 0 only: a 206 answer means it can be split, Content-Range gives the size.
function Test-DownloadUrl($url, $ip) {
    $hdr = Join-Path $env:TEMP "steambond-probe-$PID.txt"
    $a = @('-4', '-s', '-L', '--max-redirs', '10', '-r', '0-0', '--max-filesize', '1', '-m', '20', '-A', $UserAgent, '-D', $hdr, '-o', 'NUL', '-w', '%{http_code}|%{url_effective}')
    if ($ip) { $a += @('--interface', $ip) }
    $p = Start-Curl ($a + $url)
    while (-not $p.HasExited) { [Windows.Forms.Application]::DoEvents(); Start-Sleep -Milliseconds 50 }
    $res = @{ Code = 0; Size = -1; Ranges = $false; Name = $null; Error = $null }
    $headers = if (Test-Path $hdr) { Get-Content $hdr -Raw } else { '' }
    Remove-Item $hdr -ErrorAction SilentlyContinue
    # keep only the last response (after redirects)
    $blocks = @($headers -split '(?m)^(?=HTTP/)') | Where-Object { $_.Trim() }
    $last = if ($blocks.Count) { $blocks[-1] } else { '' }
    if ($last -match '^HTTP/\S+\s+(\d+)') { $res.Code = [int]$Matches[1] }
    if ($last -match '(?im)^content-range:\s*bytes\s+\d+-\d+/(\d+)') { $res.Size = [int64]$Matches[1]; $res.Ranges = ($res.Code -eq 206) }
    elseif ($last -match '(?im)^content-length:\s*(\d+)') { $res.Size = [int64]$Matches[1] }
    if ($last -match "(?im)^content-disposition:.*filename\*=(?:UTF-8|utf-8)''([^;\r\n]+)") { $res.Name = [uri]::UnescapeDataString($Matches[1].Trim('"')) }
    elseif ($last -match '(?im)^content-disposition:.*filename="?([^";\r\n]+)"?') { $res.Name = $Matches[1].Trim() }
    if (-not $res.Name) {
        try { $u = [uri]$url; $res.Name = [uri]::UnescapeDataString(($u.AbsolutePath -split '/')[-1]) } catch {}
    }
    if ($res.Code -eq 0) { $res.Error = 'Could not reach the server' }
    elseif ($res.Code -in 401, 403) { $res.Error = "Server refused ($($res.Code)) - the link may need you to be logged in, so download it in Chrome instead" }
    elseif ($res.Code -ge 400) { $res.Error = "Server error $($res.Code) - the link may have expired" }
    $res
}

function Get-DownloadWorkers {
    # Slots per network follow the smart-split weights; one network alone still gets 4 parallel streams.
    $nets = @(Get-WantedNets | ForEach-Object { $n = $_; $script:Nets | Where-Object { $_.Name -eq $n } | Select-Object -First 1 })
    if (-not $nets.Count) { $nets = @($script:Nets | Select-Object -First 1) }
    $slots = @()
    foreach ($n in $nets) {
        $k = if ($nets.Count -eq 1) { 4 } else { [math]::Min(6, 1 + (Get-Weight $n.Name)) }
        for ($i = 0; $i -lt $k; $i++) { $slots += @{ Net = $n.Name; IP = $n.IP; Proc = $null; Chunk = $null; Seen = 0L } }
    }
    $slots
}

function Add-Download($url) {
    $url = $url.Trim()
    if ($url -notmatch '^https?://') { [Windows.Forms.MessageBox]::Show('Paste a link starting with http:// or https://', 'SteamBond') | Out-Null; return }
    $script:Nets = @(Get-Networks)
    Set-DlStatus 'Checking the link...'
    # Try the main network first, then the others, in case one of them is down
    $ips = @(Get-WantedNets | ForEach-Object { $n = $_; ($script:Nets | Where-Object { $_.Name -eq $n } | Select-Object -First 1).IP }) + @($null)
    foreach ($ip in $ips) { $info = Test-DownloadUrl $url $ip; if ($info.Code -ne 0) { break } }
    if ($info.Error) { Set-DlStatus ''; [Windows.Forms.MessageBox]::Show($info.Error, 'SteamBond') | Out-Null; return }
    $dir = Get-DownloadDir
    $path = Get-FreePath $dir (Get-SafeName $info.Name)
    $id = $script:NextDownloadId++
    $temp = Join-Path $dir ".steambond-$PID-$id"
    New-Item -ItemType Directory -Force $temp | Out-Null
    (Get-Item $temp).Attributes = 'Hidden, Directory'

    $chunks = New-Object Collections.Generic.List[object]
    $workers = @(Get-DownloadWorkers)
    if ($info.Ranges -and $info.Size -gt 0) {
        $size = [int64][math]::Min([math]::Max($info.Size / ($workers.Count * 6), 4MB), 128MB)
        for ($start = 0L; $start -lt $info.Size; $start += $size) {
            $chunks.Add(@{ Start = $start; End = [math]::Min($start + $size, $info.Size) - 1; State = 'todo'; Tries = 0 })
        }
    } else {
        $chunks.Add(@{ Start = 0L; End = -1L; State = 'todo'; Tries = 0 })   # server can't split: one stream
        $workers = @($workers | Select-Object -First 1)
    }
    $dl = @{
        Id = $id; Url = $url; Name = [IO.Path]::GetFileName($path); Path = $path; Temp = $temp
        Size = $info.Size; Ranges = $info.Ranges; Chunks = $chunks; Workers = $workers
        Status = 'Downloading'; Done = 0L; NetBytes = @{}; Samples = New-Object Collections.Generic.List[object]
        Speed = 0.0; Merge = $null; Started = Get-Date
    }
    $script:Downloads.Add($dl)
    Set-DlStatus "Downloading $($dl.Name)$(if (-not $info.Ranges) { ' (this server only allows one stream)' })"
    Refresh-DownloadList
}

function Get-PartPath($dl, $chunk) { Join-Path $dl.Temp ('{0:D6}.part' -f $dl.Chunks.IndexOf($chunk)) }
function Get-FileLength($p) { try { (New-Object IO.FileInfo($p)).Length } catch { 0L } }

function Stop-DownloadWorkers($dl) {
    foreach ($w in $dl.Workers) {
        if ($w.Proc -and -not $w.Proc.HasExited) { try { $w.Proc.Kill() } catch {} }
        if ($w.Chunk -and $w.Chunk.State -eq 'run') { $w.Chunk.State = 'todo' }
        $w.Proc = $null; $w.Chunk = $null; $w.Seen = 0L
    }
}

# Runs every 200 ms: collect finished chunks, hand out new ones, count bytes per network.
function Step-Downloads {
    $upNames = @($script:Nets | ForEach-Object { $_.Name })
    foreach ($dl in $script:Downloads.ToArray()) {
        if ($dl.Status -eq 'Merging') {
            if ($dl.Merge.Handle.IsCompleted) {
                $ok = -not $dl.Merge.PS.HadErrors
                $dl.Merge.PS.Dispose(); $dl.Merge = $null
                $dl.Status = if ($ok) { 'Done' } else { 'Failed: could not join the pieces (disk full?)' }
                if ($ok) { Show-Tip "Downloaded $($dl.Name)"; Set-DlStatus "Finished $($dl.Name)"; Add-History 'files' $dl.Name ([double]$dl.Done) } else { Set-DlStatus "$($dl.Name): $($dl.Status)" }
                Refresh-DownloadList
            }
            continue
        }
        if ($dl.Status -ne 'Downloading') { continue }

        foreach ($w in $dl.Workers) {
            # count bytes of the running piece
            if ($w.Chunk) {
                $len = Get-FileLength (Get-PartPath $dl $w.Chunk)
                $delta = $len - $w.Seen
                if ($delta -gt 0) {
                    $w.Seen = $len
                    if ($dl.NetBytes.ContainsKey($w.Net)) { $dl.NetBytes[$w.Net] += $delta } else { $dl.NetBytes[$w.Net] = [double]$delta }
                    Add-History 'networks' $w.Net $delta; Add-History 'apps' 'Downloads' $delta
                }
            }
            # piece finished?
            if ($w.Proc -and $w.Proc.HasExited) {
                $c = $w.Chunk
                $len = Get-FileLength (Get-PartPath $dl $c)
                $expected = if ($c.End -ge 0) { $c.End - $c.Start + 1 } else { $len }
                if ($w.Proc.ExitCode -eq 0 -and $len -eq $expected -and $len -gt 0) {
                    $c.State = 'done'; $c.Len = $len
                } elseif ($c.End -ge 0 -and $len -gt $expected) {
                    $c.State = 'todo'; $c.Tries = 99   # server ignored the range request
                } else {
                    $c.State = 'todo'; $c.Tries++
                    Remove-Item (Get-PartPath $dl $c) -ErrorAction SilentlyContinue
                }
                $w.LastExit = $w.Proc.ExitCode
                $w.Proc = $null; $w.Chunk = $null; $w.Seen = 0L
                if ($c.Tries -ge 6) {
                    Stop-DownloadWorkers $dl
                    Set-DlStatus "$($dl.Name) failed"; $dl.Status = if ($c.Tries -eq 99) { 'Failed: server sent the wrong piece' } else { "Failed: piece kept failing (curl error $($w.LastExit))" }
                    Refresh-DownloadList; break
                }
            }
            # give an idle worker the next piece (skip networks that are unplugged)
            if (-not $w.Proc -and $w.Net -in $upNames) {
                $c = $dl.Chunks | Where-Object { $_.State -eq 'todo' } | Select-Object -First 1
                if ($c) {
                    $part = Get-PartPath $dl $c
                    Remove-Item $part -ErrorAction SilentlyContinue
                    $a = @('-4', '-s', '-L', '--fail', '--max-redirs', '10', '--connect-timeout', '15', '--speed-limit', '2048', '--speed-time', '30', '-A', $UserAgent, '--interface', $w.IP, '-o', $part)
                    if ($c.End -ge 0) { $a += @('-r', "$($c.Start)-$($c.End)") }
                    $w.Proc = Start-Curl ($a + $dl.Url)
                    $w.Chunk = $c; $w.Seen = 0L; $c.State = 'run'; $c.Net = $w.Net
                }
            }

        }
        if ($dl.Status -ne 'Downloading') { continue }

        # progress and speed (averaged over the last 3 seconds)
        $done = 0L
        foreach ($c in $dl.Chunks) {
            if ($c.State -eq 'done') { $done += $c.Len } elseif ($c.State -eq 'run') { $done += Get-FileLength (Get-PartPath $dl $c) }
        }
        $dl.Done = $done
        $now = Get-Date
        $dl.Samples.Add(@{ T = $now; B = $done })
        while ($dl.Samples.Count -gt 2 -and ($now - $dl.Samples[0].T).TotalSeconds -gt 3) { $dl.Samples.RemoveAt(0) }
        $span = ($now - $dl.Samples[0].T).TotalSeconds
        $dl.Speed = if ($span -gt 0.5) { ($done - $dl.Samples[0].B) / $span } else { 0 }

        # all pieces in: join them in the background so the window stays responsive
        if (-not ($dl.Chunks | Where-Object { $_.State -ne 'done' })) {
            $parts = @(for ($i = 0; $i -lt $dl.Chunks.Count; $i++) { Join-Path $dl.Temp ('{0:D6}.part' -f $i) })
            $dl.Status = 'Merging'; $dl.Speed = 0
            $ps = [PowerShell]::Create()
            [void]$ps.AddScript({
                param($parts, $dest, $temp)
                $ErrorActionPreference = 'Stop'
                if ($parts.Count -eq 1) { Move-Item $parts[0] $dest }
                else {
                    $out = [IO.File]::Create($dest)
                    try { foreach ($p in $parts) { $in = [IO.File]::OpenRead($p); try { $in.CopyTo($out, 4MB) } finally { $in.Close() } } } finally { $out.Close() }
                }
                Remove-Item $temp -Recurse -Force
            }).AddArgument($parts).AddArgument($dl.Path).AddArgument($dl.Temp)
            $dl.Merge = @{ PS = $ps; Handle = $ps.BeginInvoke() }
            Refresh-DownloadList
        }
    }
}

function Suspend-Download($dl) { if ($dl.Status -eq 'Downloading') { Stop-DownloadWorkers $dl; $dl.Status = 'Paused'; $dl.Speed = 0 } }
function Resume-Download($dl) {
    if ($dl.Status -ne 'Paused') { return }
    $script:Nets = @(Get-Networks)
    if ($dl.Ranges) { $dl.Workers = @(Get-DownloadWorkers) }
    foreach ($c in $dl.Chunks) { if ($c.State -eq 'run') { $c.State = 'todo' } }
    $dl.Samples.Clear(); $dl.Status = 'Downloading'
}
function Remove-DownloadTemp($dl) { Stop-DownloadWorkers $dl; Remove-Item $dl.Temp -Recurse -Force -ErrorAction SilentlyContinue }
function Stop-AllDownloads { foreach ($dl in $script:Downloads) { if ($dl.Status -in 'Downloading', 'Paused') { Remove-DownloadTemp $dl } } }

# ---------- UI ----------
function Font([float]$size, [switch]$Bold) { New-Object Drawing.Font('Segoe UI', $size, $(if ($Bold) { [Drawing.FontStyle]::Bold } else { [Drawing.FontStyle]::Regular })) }
function Add-Label($parent, $text, $x, $y, $w, $h, [switch]$Dim) {
    $l = New-Object Windows.Forms.Label; $l.Text = $text; $l.SetBounds($x, $y, $w, $h)
    if ($Dim) { $l.ForeColor = [Drawing.Color]::DimGray }
    $parent.Controls.Add($l); $l
}
function Add-Button($parent, $text, $x, $y, $w, $h) {
    $b = New-Object Windows.Forms.Button; $b.Text = $text; $b.SetBounds($x, $y, $w, $h); $parent.Controls.Add($b); $b
}
function Add-Check($parent, $text, $x, $y, $w, $checked) {
    $c = New-Object Windows.Forms.CheckBox; $c.Text = $text; $c.SetBounds($x, $y, $w, 24); $c.Checked = [bool]$checked; $parent.Controls.Add($c); $c
}

$form = New-Object Windows.Forms.Form
$form.Text = 'SteamBond'
$form.ClientSize = New-Object Drawing.Size(600, 600)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.Font = Font 9.5
if (Test-Path $IconFile) { $form.Icon = New-Object Drawing.Icon($IconFile) }

$tabs = New-Object Windows.Forms.TabControl
$tabs.SetBounds(8, 8, 584, 584)
$form.Controls.Add($tabs)
$tabMain = New-Object Windows.Forms.TabPage('Connect')
$tabDl   = New-Object Windows.Forms.TabPage('Downloads')
$tabApps = New-Object Windows.Forms.TabPage('Apps')
$tabHist = New-Object Windows.Forms.TabPage('History')
$tabSet  = New-Object Windows.Forms.TabPage('Settings')
$tabs.TabPages.AddRange(@($tabMain, $tabDl, $tabApps, $tabHist, $tabSet))

# --- Connect tab ---
$t = Add-Label $tabMain 'Networks to combine' 12 10 300 20; $t.Font = Font 10 -Bold
$netList = New-Object Windows.Forms.CheckedListBox
$netList.CheckOnClick = $true
$netList.SetBounds(12, 34, 330, 84)
$tabMain.Controls.Add($netList)
[void](Add-Label $tabMain 'Normal internet uses:' 356 34 200 20)
$mainCombo = New-Object Windows.Forms.ComboBox
$mainCombo.DropDownStyle = 'DropDownList'
$mainCombo.SetBounds(356, 56, 204, 26)
$tabMain.Controls.Add($mainCombo)
[void](Add-Label $tabMain 'Browsing, Discord etc. stay on this one.' 356 86 210 34 -Dim)

$startBtn = Add-Button $tabMain 'Start' 12 128 176 40
$startBtn.Font = Font 11 -Bold
$startBtn.BackColor = [Drawing.Color]::FromArgb(46, 125, 50); $startBtn.ForeColor = [Drawing.Color]::White; $startBtn.FlatStyle = 'Flat'
$stopBtn = Add-Button $tabMain 'Stop' 196 128 176 40
$stopBtn.Font = Font 11 -Bold
$steamBtn = Add-Button $tabMain 'Restart Steam' 380 128 180 40
$steamBtn.Font = Font 10 -Bold

$status = Add-Label $tabMain 'Stopped' 12 176 550 20
$status.Font = Font 9.5 -Bold

$graph = New-Object Windows.Forms.Panel
$graph.SetBounds(12, 200, 548, 150)
$graph.BackColor = [Drawing.Color]::FromArgb(24, 27, 34)
$graph.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($graph, $true, $null)
$tabMain.Controls.Add($graph)

$grid = New-Object Windows.Forms.ListView
$grid.View = 'Details'; $grid.FullRowSelect = $true; $grid.HeaderStyle = 'Nonclickable'
$grid.SetBounds(12, 358, 548, 110)
foreach ($c in @(@('Network', 130), @('Now', 90), @('Share', 70), @('Game connections', 125), @('Game data', 110))) { [void]$grid.Columns.Add($c[0], $c[1]) }
$tabMain.Controls.Add($grid)

$total = Add-Label $tabMain '' 12 474 550 28
$total.Font = Font 13 -Bold
$steamInfo = Add-Label $tabMain '' 12 504 550 40 -Dim

# --- Downloads tab ---
$t = Add-Label $tabDl 'Download a file over all your networks' 12 10 540 20; $t.Font = Font 10 -Bold
[void](Add-Label $tabDl 'In Chrome: right-click the download link > Copy link address. It appears here.' 12 32 550 20 -Dim)
$urlBox = New-Object Windows.Forms.TextBox
$urlBox.SetBounds(12, 60, 430, 26)
$tabDl.Controls.Add($urlBox)
$dlBtn = Add-Button $tabDl 'Download' 450 57 110 31
$dlBtn.Font = Font 10 -Bold
$dlBtn.BackColor = [Drawing.Color]::FromArgb(46, 125, 50); $dlBtn.ForeColor = [Drawing.Color]::White; $dlBtn.FlatStyle = 'Flat'
$dirLbl = Add-Label $tabDl '' 12 98 430 20 -Dim
$dirBtn = Add-Button $tabDl 'Change folder' 450 93 110 28

$dlView = New-Object Windows.Forms.ListView
$dlView.View = 'Details'; $dlView.FullRowSelect = $true; $dlView.HeaderStyle = 'Nonclickable'; $dlView.MultiSelect = $false; $dlView.HideSelection = $false
$dlView.SetBounds(12, 128, 548, 300)
foreach ($c in @(@('File', 170), @('Size', 75), @('Done', 55), @('Speed / status', 110), @('Split', 120))) { [void]$dlView.Columns.Add($c[0], $c[1]) }
$tabDl.Controls.Add($dlView)

$dlStatus = Add-Label $tabDl '' 12 434 548 20 -Dim
$pauseBtn  = Add-Button $tabDl 'Pause' 12 458 100 30
$cancelBtn = Add-Button $tabDl 'Cancel' 118 458 90 30
$openBtn   = Add-Button $tabDl 'Open' 214 458 80 30
$showBtn   = Add-Button $tabDl 'Show in folder' 300 458 120 30
$clearBtn  = Add-Button $tabDl 'Clear finished' 426 458 134 30
$clipChk = Add-Check $tabDl 'Pick up download links I copy' 12 498 400 $script:Settings.watchClipboard
[void](Add-Label $tabDl 'Works without pressing Start. Links that need you logged in (some Google Drive, Mega) won''t work - use Chrome for those.' 12 524 550 36 -Dim)

# --- Apps tab ---
$t = Add-Label $tabApps 'Which apps get the combined speed' 12 10 500 20; $t.Font = Font 10 -Bold
[void](Add-Label $tabApps 'Everything not ticked stays on your normal internet.' 12 32 540 20 -Dim)
$appChecks = @{}
$y = 62
$appNotes = @{
    'Steam' = 'Game downloads and updates'
    'Epic Games' = 'Epic Games Launcher downloads'
    'EA app' = 'EA app downloads'
    'Ubisoft Connect' = 'Ubisoft Connect downloads'
    'Battle.net' = 'Blizzard games (Battle.net and its Agent)'
    'Browsers' = 'Chrome, Edge, Firefox, Brave, Opera - each website sticks to one network so logins keep working. Helps several downloads at once, not a single file.'
}
foreach ($k in $Launchers.Keys) {
    $c = Add-Check $tabApps $k 16 $y 200 ($k -in $script:Settings.apps)
    $c.Font = Font 10 -Bold
    $n = Add-Label $tabApps $appNotes[$k] 36 ($y + 24) 520 $(if ($k -eq 'Browsers') { 36 } else { 18 }) -Dim
    $appChecks[$k] = $c
    $y += $(if ($k -eq 'Browsers') { 70 } else { 52 })
}

# --- History tab ---
$t = Add-Label $tabHist 'Data downloaded through SteamBond' 12 10 500 20; $t.Font = Font 10 -Bold
$histView = New-Object Windows.Forms.ListView
$histView.View = 'Details'; $histView.FullRowSelect = $true; $histView.HeaderStyle = 'Nonclickable'
$histView.SetBounds(12, 36, 548, 470)
[void]$histView.Columns.Add('What', 360); [void]$histView.Columns.Add('Data', 160)
$tabHist.Controls.Add($histView)
$clearHist = Add-Button $tabHist 'Clear history' 12 514 130 30
[void](Add-Label $tabHist 'Counts only traffic of the ticked apps. Last 30 days.' 152 520 400 20 -Dim)

# --- Settings tab ---
$t = Add-Label $tabSet 'Speed split' 12 10 300 20; $t.Font = Font 10 -Bold
$smartChk = Add-Check $tabSet 'Smart split: give faster networks more connections' 16 34 520 $script:Settings.smartSplit
$measureBtn = Add-Button $tabSet 'Measure speeds now' 36 62 170 30
$speedLbl = Add-Label $tabSet '' 214 64 350 44 -Dim

$t = Add-Label $tabSet 'Automatic' 12 118 300 20; $t.Font = Font 10 -Bold
$autoChk = Add-Check $tabSet 'Auto mode: switch on when Steam starts downloading, off when it finishes' 16 142 550 $script:Settings.autoMode
$autoSteamChk = Add-Check $tabSet 'Also restart Steam automatically when auto mode switches on' 36 168 520 $script:Settings.autoRestartSteam
[void](Add-Label $tabSet 'Without the restart, Steam''s already-open connections keep using one network until it opens new ones.' 36 194 520 36 -Dim)

$t = Add-Label $tabSet 'Window' 12 240 300 20; $t.Font = Font 10 -Bold
$trayChk = Add-Check $tabSet 'Closing the window keeps SteamBond running in the tray (by the clock)' 16 264 550 $script:Settings.closeToTray

$t = Add-Label $tabSet 'Admin popup' 12 304 300 20; $t.Font = Font 10 -Bold
$taskBtn = Add-Button $tabSet 'Open without admin popup' 16 330 220 32
$taskLbl = Add-Label $tabSet '' 246 336 320 40 -Dim

$folderBtn = Add-Button $tabSet 'Open SteamBond folder' 16 520 200 30

# --- tray ---
$tray = New-Object Windows.Forms.NotifyIcon
$tray.Icon = if (Test-Path $IconFile) { New-Object Drawing.Icon($IconFile) } else { [Drawing.SystemIcons]::Application }
$tray.Text = 'SteamBond'
$tray.Visible = $true
$menu = New-Object Windows.Forms.ContextMenuStrip
$miOpen  = $menu.Items.Add('Open SteamBond')
$miStart = $menu.Items.Add('Start')
$miStop  = $menu.Items.Add('Stop')
$miSteam = $menu.Items.Add('Restart Steam')
[void]$menu.Items.Add('-')
$miExit  = $menu.Items.Add('Exit SteamBond')
$miOpen.Font = Font 9 -Bold
$tray.ContextMenuStrip = $menu

# ---------- UI helpers ----------
function Set-Status($text, $color) { $status.Text = $text; $status.ForeColor = [Drawing.Color]::FromName($color) }
function Show-Tip($text) { $tray.ShowBalloonTip(3000, 'SteamBond', $text, 'Info') }
function Show-Window { $form.Show(); $form.WindowState = 'Normal'; $form.Activate() }
function Update-Buttons {
    $startBtn.Enabled = -not $script:Running; $stopBtn.Enabled = $script:Running
    $steamBtn.Enabled = $script:Running -or -not (Get-Process steam -ErrorAction SilentlyContinue)
    $miStart.Enabled = -not $script:Running; $miStop.Enabled = $script:Running
}
function Fmt($bytes) { if ($bytes -ge 1GB) { '{0:N2} GB' -f ($bytes / 1GB) } else { '{0:N0} MB' -f ($bytes / 1MB) } }
function Update-SpeedLabel {
    $sp = $script:Settings.speeds
    if (-not $sp -or -not $sp.Count) { $speedLbl.Text = 'Not measured yet - happens automatically when you press Start.'; return }
    $speedLbl.Text = ($sp.Keys | ForEach-Object { '{0}: {1:N0} Mbps (x{2})' -f $_, ($sp[$_] * 8 / 1e6), (Get-Weight $_) }) -join "`n"
}
function Update-TaskLabel {
    $has = [bool](Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue)
    $taskLbl.Text = if ($has) { 'Done - the desktop shortcut opens SteamBond without the popup.' } else { 'One-time setup: the desktop shortcut will open SteamBond straight away.' }
    $taskBtn.Text = if ($has) { 'Repair shortcut' } else { 'Open without admin popup' }
}

$script:ListNames = @()
$script:Filling = $false
function Fill-Networks {
    $script:Filling = $true
    $netList.Items.Clear(); $script:ListNames = @()
    $up = @($script:Nets | ForEach-Object { $_.Name })
    foreach ($n in $script:Nets) {
        [void]$netList.Items.Add("$($n.Name)   ($($n.IP))", ($n.Name -in $script:Settings.networks)); $script:ListNames += $n.Name
    }
    foreach ($n in $script:Settings.networks) {
        if ($n -notin $up) { [void]$netList.Items.Add("$n   (not connected)", $true); $script:ListNames += $n }
    }
    $mainCombo.Items.Clear()
    foreach ($n in $script:Nets) { [void]$mainCombo.Items.Add($n.Name) }
    $sel = if ($script:Settings.main -in $up) { $script:Settings.main } elseif ($up.Count) { (Get-WantedNets | Select-Object -First 1) } else { $null }
    if ($sel) { $mainCombo.SelectedIndex = $mainCombo.Items.IndexOf([string]$sel) }
    $script:Filling = $false
}

function Fill-History {
    $histView.BeginUpdate(); $histView.Items.Clear(); $histView.Groups.Clear()
    $days = @($script:History.Keys | Sort-Object -Descending | Select-Object -First 30)
    foreach ($d in $days) {
        $h = $script:History[$d]
        $sum = ($h.networks.Values | Measure-Object -Sum).Sum
        $g = New-Object Windows.Forms.ListViewGroup("$d   -   total $(Fmt $sum)")
        [void]$histView.Groups.Add($g)
        foreach ($kind in @(@('games', 'Game'), @('files', 'File'), @('apps', 'App'), @('networks', 'Network'))) {
            foreach ($k in ($h[$kind[0]].Keys | Sort-Object { -$h[$kind[0]][$_] })) {
                $it = New-Object Windows.Forms.ListViewItem("$($kind[1]):  $k", $g)
                [void]$it.SubItems.Add((Fmt $h[$kind[0]][$k]))
                [void]$histView.Items.Add($it)
            }
        }
    }
    if (-not $days.Count) { [void]$histView.Items.Add('Nothing yet - start SteamBond and download a game.') }
    $histView.EndUpdate()
}

# ---------- live data ----------
$script:Nets = @(Get-Networks)
$script:PrevBytes = @{}
$script:PrevTime = Get-Date
$script:GraphData = @{}          # network -> last 60 samples (bytes/s)
$script:GraphTotal = New-Object Collections.Generic.List[double]
$script:Seen = @{}
$script:Tick = 0
$script:SteamState = @{ Active = $false; Game = $null; Mbps = $null }
$script:LastDownloadSeen = Get-Date
$Palette = @([Drawing.Color]::FromArgb(102, 192, 244), [Drawing.Color]::FromArgb(91, 214, 120), [Drawing.Color]::FromArgb(255, 167, 38), [Drawing.Color]::FromArgb(236, 104, 160))

function Push-Sample($list, [double]$v) { $list.Add($v); while ($list.Count -gt 60) { $list.RemoveAt(0) } }

$graph.Add_Paint({
    param($s, $e)
    $g = $e.Graphics; $g.SmoothingMode = 'AntiAlias'
    $w = $graph.Width; $h = $graph.Height; $top = 22; $plotH = $h - $top - 6
    $max = 1MB
    foreach ($v in $script:GraphTotal) { if ($v -gt $max) { $max = $v } }
    $max *= 1.15
    $gridPen = New-Object Drawing.Pen([Drawing.Color]::FromArgb(50, 56, 68))
    foreach ($f in 0.25, 0.5, 0.75) { $yy = $top + $plotH * (1 - $f); $g.DrawLine($gridPen, 0, $yy, $w, $yy) }
    $small = Font 8
    $g.DrawString(('{0:N0} Mbps' -f ($max * 8 / 1e6)), $small, [Drawing.Brushes]::Gray, $w - 80, 4)
    $series = @(@{ Name = 'Total'; Data = $script:GraphTotal; Color = [Drawing.Color]::FromArgb(200, 200, 200) })
    $i = 0
    foreach ($n in ($script:GraphData.Keys | Sort-Object)) { $series += @{ Name = $n; Data = $script:GraphData[$n]; Color = $Palette[$i % $Palette.Count] }; $i++ }
    $lx = 8
    foreach ($sr in $series) {
        $pen = New-Object Drawing.Pen($sr.Color, $(if ($sr.Name -eq 'Total') { 1.5 } else { 2 }))
        if ($sr.Name -eq 'Total') { $pen.DashStyle = 'Dash' }
        $d = $sr.Data
        if ($d.Count -gt 1) {
            $pts = New-Object 'Drawing.PointF[]' $d.Count
            for ($k = 0; $k -lt $d.Count; $k++) { $pts[$k] = New-Object Drawing.PointF(($w * ($k + 60 - $d.Count) / 59), ($top + $plotH * (1 - $d[$k] / $max))) }
            $g.DrawLines($pen, $pts)
        }
        $b = New-Object Drawing.SolidBrush($sr.Color)
        $g.DrawString($sr.Name, $small, $b, $lx, 4)
        $lx += $g.MeasureString($sr.Name, $small).Width + 12
    }
})

function Update-Live {
    $now = Get-Date
    $secs = [math]::Max(($now - $script:PrevTime).TotalSeconds, 0.2)
    $script:PrevTime = $now

    # Per-network game traffic and history, from mihomo's live connection table
    $per = @{}
    if ($script:Running) {
        try {
            $c = Invoke-RestMethod "$Api/connections" -TimeoutSec 1
            $seen = @{}
            foreach ($x in $c.connections) {
                $group = $x.chains[$x.chains.Count - 1]
                if ($group -notin 'bond', 'bond-web') { continue }
                $net = $x.chains[0] -replace ' #\d+$', ''
                if (-not $per[$net]) { $per[$net] = @{ n = 0; b = 0.0 } }
                $per[$net].n++; $per[$net].b += $x.download
                $prev = if ($script:Seen.ContainsKey($x.id)) { $script:Seen[$x.id] } else { 0 }
                $delta = [double]$x.download - $prev
                $seen[$x.id] = [double]$x.download
                if ($delta -gt 0) {
                    $proc = [string]$x.metadata.process
                    $app = if ($proc -and $script:ProcLabel.ContainsKey($proc.ToLower())) { $script:ProcLabel[$proc.ToLower()] } elseif ($group -eq 'bond') { 'Steam' } else { 'Other' }
                    Add-History 'networks' $net $delta
                    Add-History 'apps' $app $delta
                    if ($app -eq 'Steam' -and $script:SteamState.Game) { Add-History 'games' $script:SteamState.Game $delta }
                }
            }
            $script:Seen = $seen
        } catch {}
    }

    $grid.BeginUpdate(); $grid.Items.Clear()
    $sum = 0.0
    $wanted = Get-WantedNets
    $wsum = ($wanted | ForEach-Object { Get-Weight $_ } | Measure-Object -Sum).Sum
    foreach ($n in $script:Nets) {
        try { $rx = [double]$n.Iface.GetIPStatistics().BytesReceived } catch { continue }
        $rate = 0.0
        if ($script:PrevBytes.ContainsKey($n.Name)) { $rate = [math]::Max(($rx - $script:PrevBytes[$n.Name]) / $secs, 0) }
        $script:PrevBytes[$n.Name] = $rx
        $sum += $rate
        if (-not $script:GraphData.ContainsKey($n.Name)) { $script:GraphData[$n.Name] = New-Object Collections.Generic.List[double] }
        Push-Sample $script:GraphData[$n.Name] $rate
        $it = New-Object Windows.Forms.ListViewItem($n.Name)
        [void]$it.SubItems.Add(('{0:N1} MB/s' -f ($rate / 1MB)))
        [void]$it.SubItems.Add($(if ($script:Running -and $n.Name -in $wanted -and $wsum) { '{0:N0}%' -f (100 * (Get-Weight $n.Name) / $wsum) } else { '-' }))
        $p = $per[$n.Name]
        [void]$it.SubItems.Add($(if ($p) { "$($p.n)" } else { '-' }))
        [void]$it.SubItems.Add($(if ($p) { Fmt $p.b } else { '-' }))
        [void]$grid.Items.Add($it)
    }
    $grid.EndUpdate()
    foreach ($k in @($script:GraphData.Keys)) { if ($k -notin @($script:Nets | ForEach-Object { $_.Name })) { $script:GraphData.Remove($k) } }
    Push-Sample $script:GraphTotal $sum
    $graph.Invalidate()
    $total.Text = 'Total: {0:N1} MB/s  ({1:N0} Mbps)' -f ($sum / 1MB), ($sum * 8 / 1e6)
    $tip = if ($script:Running) { 'SteamBond - on, {0:N1} MB/s' -f ($sum / 1MB) } else { 'SteamBond - off' }
    $tray.Text = $tip.Substring(0, [math]::Min(63, $tip.Length))

    $ss = $script:SteamState
    $steamInfo.Text = if ($ss.Active) { "Steam is downloading$(if ($ss.Game) { " $($ss.Game)" })  -  Steam reports $([math]::Round($ss.Mbps)) Mbps" } elseif ($ss.Game) { "Steam: $($ss.Game) is queued or paused" } else { 'Steam is not downloading anything' }
}

# Every 5 seconds: networks coming and going, Steam state, auto mode
function Watch-Things {
    $before = ($script:Nets | ForEach-Object { $_.Name }) -join '|'
    $script:Nets = @(Get-Networks)
    $after = ($script:Nets | ForEach-Object { $_.Name }) -join '|'
    if ($before -ne $after) {
        Fill-Networks
        $gone = @($before -split '\|' | Where-Object { $_ -and $_ -notin ($after -split '\|') })
        $new  = @($after -split '\|' | Where-Object { $_ -and $_ -notin ($before -split '\|') })
        if ($script:Running) {
            if ($gone) { Show-Tip "$($gone -join ', ') disconnected - carrying on with the rest" }
            if ($new | Where-Object { $_ -in $script:Settings.networks }) { Show-Tip "$($new -join ', ') is back - added again" }
        }
    }
    if ($script:Running -and (Get-WantKey) -ne $script:ActiveKey) { Reload-Bond }

    # mihomo died on its own: restart it (up to 3 times)
    if ($script:Running -and $script:Proc -and $script:Proc.HasExited) {
        if ($script:CrashRestarts -lt 3) { $script:CrashRestarts++; [void](Start-Bond $false $script:StartedByAuto) }
        else { Stop-Bond; Set-Status 'SteamBond keeps stopping - see mihomo.log in the folder' 'Red' }
    }

    $script:SteamState = Get-SteamDownload
    if ($script:SteamState.Active) { $script:LastDownloadSeen = Get-Date }
    if ($script:Settings.autoMode) {
        if (-not $script:Running -and $script:SteamState.Active) {
            if (Start-Bond $false $true) {
                Show-Tip "Steam started downloading$(if ($script:SteamState.Game) { " $($script:SteamState.Game)" }) - combining networks"
                if ($script:Settings.autoRestartSteam) { Restart-Steam }
            }
        } elseif ($script:Running -and $script:StartedByAuto -and ((Get-Date) - $script:LastDownloadSeen).TotalSeconds -gt 180) {
            Stop-Bond; Show-Tip 'Steam finished downloading - SteamBond switched off'
        }
    }
    Update-Buttons
}

# ---------- events ----------
$netList.Add_ItemCheck({
    param($s, $e)
    if ($script:Filling) { return }
    $name = $script:ListNames[$e.Index]
    $list = @($script:Settings.networks | Where-Object { $_ -ne $name })
    if ($e.NewValue -eq 'Checked') { $list += $name }
    $script:Settings.networks = $list
    Save-Settings
})
$mainCombo.Add_SelectedIndexChanged({ if (-not $script:Filling -and $mainCombo.SelectedItem) { $script:Settings.main = [string]$mainCombo.SelectedItem; Save-Settings } })

$startBtn.Add_Click({ $script:CrashRestarts = 0; [void](Start-Bond $true $false) })
$stopBtn.Add_Click({ Stop-Bond })
$steamBtn.Add_Click({ Restart-Steam })

foreach ($k in $appChecks.Keys) {
    $appChecks[$k].Add_CheckedChanged({
        $script:Settings.apps = @($Launchers.Keys | Where-Object { $appChecks[$_].Checked })
        Save-Settings
    })
}

$clearHist.Add_Click({
    if ([Windows.Forms.MessageBox]::Show('Delete all download history?', 'SteamBond', 'YesNo') -eq 'Yes') { $script:History = @{}; Save-History; Fill-History }
})
$tabs.Add_SelectedIndexChanged({ if ($tabs.SelectedTab -eq $tabHist) { Fill-History } })

$smartChk.Add_CheckedChanged({ $script:Settings.smartSplit = $smartChk.Checked; Save-Settings; Update-SpeedLabel })
$measureBtn.Add_Click({
    $wasRunning = $script:Running
    if ($wasRunning) { Stop-Bond -Quiet }
    $nets = @($script:Nets | Where-Object { $_.Name -in (Get-WantedNets) })
    if ($nets.Count -lt 1) { $speedLbl.Text = 'Tick a connected network on the Connect tab first.'; return }
    $speedLbl.Text = 'Measuring (6 seconds)...'
    $script:Settings.speeds = Measure-Speeds $nets
    $script:Settings.weights = Get-Weights $script:Settings.speeds
    Save-Settings; Update-SpeedLabel
    if ($wasRunning) { [void](Start-Bond $false $false) }
})
$autoChk.Add_CheckedChanged({ $script:Settings.autoMode = $autoChk.Checked; Save-Settings })
$autoSteamChk.Add_CheckedChanged({ $script:Settings.autoRestartSteam = $autoSteamChk.Checked; Save-Settings })
$trayChk.Add_CheckedChanged({ $script:Settings.closeToTray = $trayChk.Checked; Save-Settings })
$folderBtn.Add_Click({ Start-Process explorer.exe -ArgumentList "`"$Root`"" })

$taskBtn.Add_Click({
    try {
        $ps = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$Root\SteamBond.ps1`"" -WorkingDirectory $Root
        $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Highest
        $set = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew
        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $set -Description 'Opens SteamBond with admin rights without a popup' -Force | Out-Null
        $sh = New-Object -ComObject WScript.Shell
        $lnk = $sh.CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'SteamBond.lnk'))
        $lnk.TargetPath = Join-Path $env:WINDIR 'System32\schtasks.exe'
        $lnk.Arguments = "/run /tn `"$TaskName`""
        $lnk.WorkingDirectory = $Root
        $lnk.IconLocation = "$IconFile,0"
        $lnk.WindowStyle = 7
        $lnk.Save()
        Update-TaskLabel
        Show-Tip 'Done - next time the desktop shortcut opens without the admin popup'
    } catch { [Windows.Forms.MessageBox]::Show("Setup failed:`n$($_.Exception.Message)", 'SteamBond') | Out-Null }
})

# ---------- Downloads tab logic ----------
function Set-DlStatus($text) { $dlStatus.Text = $text; [Windows.Forms.Application]::DoEvents() }
function Get-SelectedDownload {
    if ($dlView.SelectedItems.Count -eq 0) { return $null }
    $id = $dlView.SelectedItems[0].Tag
    $script:Downloads.ToArray() | Where-Object { $_.Id -eq $id } | Select-Object -First 1
}
function Update-DlButtons {
    $dl = Get-SelectedDownload
    $pauseBtn.Text = if ($dl -and $dl.Status -eq 'Paused') { 'Resume' } else { 'Pause' }
    $pauseBtn.Enabled = $dl -and $dl.Status -in 'Downloading', 'Paused'
    $cancelBtn.Enabled = $dl -and $dl.Status -in 'Downloading', 'Paused'
    $openBtn.Enabled = $dl -and $dl.Status -eq 'Done'
    $showBtn.Enabled = [bool]$dl
}
function Refresh-DownloadList {
    $selId = if ($dlView.SelectedItems.Count) { $dlView.SelectedItems[0].Tag } else { $null }
    $dlView.BeginUpdate(); $dlView.Items.Clear()
    foreach ($dl in $script:Downloads.ToArray()) {
        $it = New-Object Windows.Forms.ListViewItem($dl.Name)
        $it.Tag = $dl.Id
        [void]$it.SubItems.Add($(if ($dl.Size -gt 0) { Fmt $dl.Size } else { '?' }))
        [void]$it.SubItems.Add($(if ($dl.Status -eq 'Done') { '100%' } elseif ($dl.Size -gt 0) { '{0:N0}%' -f (100 * $dl.Done / $dl.Size) } else { Fmt $dl.Done }))
        [void]$it.SubItems.Add($(if ($dl.Status -eq 'Downloading') { '{0:N1} MB/s' -f ($dl.Speed / 1MB) } else { $dl.Status }))
        $sum = ($dl.NetBytes.Values | Measure-Object -Sum).Sum
        [void]$it.SubItems.Add($(if ($sum -gt 0) { ($dl.NetBytes.Keys | Sort-Object | ForEach-Object { '{0} {1:N0}%' -f $_, (100 * $dl.NetBytes[$_] / $sum) }) -join ', ' } else { '-' }))
        if ($dl.Status -like 'Failed*') { $it.ForeColor = [Drawing.Color]::Firebrick } elseif ($dl.Status -eq 'Done') { $it.ForeColor = [Drawing.Color]::ForestGreen }
        $it.ToolTipText = $dl.Status
        [void]$dlView.Items.Add($it)
        if ($selId -eq $dl.Id) { $it.Selected = $true }
    }
    $dlView.EndUpdate()
    Update-DlButtons
}
function Update-DirLabel { $dirLbl.Text = "Saves to: $(Get-DownloadDir)" }

$startDownload = {
    $u = $urlBox.Text
    if (-not $u.Trim()) { return }
    $dlBtn.Enabled = $false
    try { Add-Download $u; $urlBox.Text = '' } finally { $dlBtn.Enabled = $true }
}
$dlBtn.Add_Click($startDownload)
$urlBox.Add_KeyDown({ param($s, $e) if ($e.KeyCode -eq 'Enter') { $e.SuppressKeyPress = $true; & $startDownload } })
$dirBtn.Add_Click({
    $fb = New-Object Windows.Forms.FolderBrowserDialog
    $fb.SelectedPath = Get-DownloadDir
    if ($fb.ShowDialog() -eq 'OK') { $script:Settings.downloadDir = $fb.SelectedPath; Save-Settings; Update-DirLabel }
})
$dlView.Add_SelectedIndexChanged({ Update-DlButtons })
$pauseBtn.Add_Click({
    $dl = Get-SelectedDownload
    if (-not $dl) { return }
    if ($dl.Status -eq 'Paused') { Resume-Download $dl } else { Suspend-Download $dl }
    Refresh-DownloadList
})
$cancelBtn.Add_Click({
    $dl = Get-SelectedDownload
    if ($dl -and $dl.Status -in 'Downloading', 'Paused') { Remove-DownloadTemp $dl; $dl.Status = 'Cancelled'; $dl.Speed = 0; Refresh-DownloadList }
})
# Explorer opens files as you, not as administrator
$openBtn.Add_Click({ $dl = Get-SelectedDownload; if ($dl -and (Test-Path $dl.Path)) { Start-Process explorer.exe -ArgumentList "`"$($dl.Path)`"" } })
$showBtn.Add_Click({
    $dl = Get-SelectedDownload
    if (-not $dl) { return }
    if (Test-Path $dl.Path) { Start-Process explorer.exe -ArgumentList "/select,`"$($dl.Path)`"" } else { Start-Process explorer.exe -ArgumentList "`"$(Split-Path $dl.Path)`"" }
})
$clearBtn.Add_Click({
    foreach ($dl in $script:Downloads.ToArray()) { if ($dl.Status -eq 'Done' -or $dl.Status -like 'Failed*' -or $dl.Status -eq 'Cancelled') { [void]$script:Downloads.Remove($dl) } }
    Refresh-DownloadList
})
$clipChk.Add_CheckedChanged({ $script:Settings.watchClipboard = $clipChk.Checked; Save-Settings })

# Clipboard: a copied link fills the box; a link to a file also pops a tray message when the window is hidden
$script:LastClip = ''
$FileExt = 'zip|rar|7z|exe|msi|iso|img|bin|apk|xapk|obb|dmg|pkg|tar|gz|tgz|xz|bz2|zst|mp4|mkv|avi|mov|webm|mp3|flac|pdf|cab|appx|msix'
function Watch-Clipboard {
    if (-not $script:Settings.watchClipboard) { return }
    try { if (-not [Windows.Forms.Clipboard]::ContainsText()) { return }; $txt = [Windows.Forms.Clipboard]::GetText().Trim() } catch { return }
    if ($txt -eq $script:LastClip) { return }
    $script:LastClip = $txt
    if ($txt -notmatch '^https?://\S+$' -or $txt.Length -gt 4000) { return }
    $urlBox.Text = $txt
    $isFile = $txt -match "\.($FileExt)(\?|#|$)"
    Set-DlStatus 'Link picked up from the clipboard - press Download'
    if ($isFile -and -not $form.Visible) { $script:ClipBalloon = $true; $tray.ShowBalloonTip(4000, 'SteamBond', 'Download link copied - click here to download it with all your networks', 'Info') }
}
$tray.Add_BalloonTipClicked({ if ($script:ClipBalloon) { $script:ClipBalloon = $false; Show-Window; $tabs.SelectedTab = $tabDl } })

$dlTimer = New-Object Windows.Forms.Timer
$dlTimer.Interval = 250
$dlTimer.Add_Tick({ if ($script:Downloads.Count) { Step-Downloads } })

$exitApp = {
    $script:Exiting = $true
    if ($script:Running) { Stop-Bond -Quiet }; Stop-AllDownloads
    Save-History; Save-Settings
    $tray.Visible = $false
    $form.Close()
}
$tray.Add_MouseDoubleClick({ Show-Window })
$miOpen.Add_Click({ Show-Window })
$miStart.Add_Click({ $script:CrashRestarts = 0; [void](Start-Bond $true $false) })
$miStop.Add_Click({ Stop-Bond })
$miSteam.Add_Click({ Restart-Steam })
$miExit.Add_Click($exitApp)

$script:Exiting = $false
$form.Add_FormClosing({
    param($s, $e)
    if (-not $script:Exiting -and $script:Settings.closeToTray) {
        $e.Cancel = $true
        $form.Hide()
        if (-not $script:Settings.trayHintShown) {
            Show-Tip 'Still running here. Right-click this icon to stop or exit.'
            $script:Settings.trayHintShown = $true; Save-Settings
        }
        return
    }
    $script:Exiting = $true
    if ($script:Running) { Stop-Bond -Quiet }; Stop-AllDownloads
    Save-History; Save-Settings
    $tray.Visible = $false
})

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    $script:Tick++
    if ($script:ShowEvent.WaitOne(0)) { Show-Window }
    Update-Live
    Watch-Clipboard
    if ($script:Downloads.Count -and $tabs.SelectedTab -eq $tabDl -and $form.Visible) { Refresh-DownloadList }
    if ($script:Tick % 5 -eq 0) { Watch-Things }
    if ($script:Tick % 30 -eq 0) { Save-History; if ($tabs.SelectedTab -eq $tabHist -and $form.Visible) { Fill-History } }
    if ($script:Tick % 300 -eq 0) { $script:SteamLibs = Get-SteamLibraries }
})

# A copy of mihomo left over from a crash would block the TUN adapter
if ((Get-Process mihomo -ErrorAction SilentlyContinue) -and -not $env:STEAMBOND_SMOKETEST) {
    $script:Running = $true; $script:ActiveKey = ''
    $script:Proc = Get-Process mihomo | Select-Object -First 1
    Set-Status 'Already running - picked up the existing connection' 'ForestGreen'
}

$form.Add_Shown({
    if (-not $script:Settings.networks.Count) { $script:Settings.networks = @($script:Nets | ForEach-Object { $_.Name }); Save-Settings }
    Fill-Networks; Update-SpeedLabel; Update-TaskLabel; Update-Buttons; Update-DirLabel; Update-DlButtons; $dlTimer.Start()
    $script:SteamState = Get-SteamDownload
    $timer.Start()
    if ($env:STEAMBOND_SMOKETEST) { $t2 = New-Object Windows.Forms.Timer; $t2.Interval = [int]$env:STEAMBOND_SMOKETEST; $t2.Add_Tick({ $script:Exiting = $true; $form.Close() }); $t2.Start() }
})
[Windows.Forms.Application]::Run($form)
$tray.Dispose()
$script:Mutex.ReleaseMutex()

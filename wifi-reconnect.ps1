# ============================================================
#  Public WiFi Reconnect
#  Auto-reconnects on public Wi-Fi when the session drops on a timer.
#  Detects the current network automatically. Windows only. MIT license.
#
#  Use only on networks you are allowed to use.
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http

# --- Settings ---
$ManualSsid       = ""                       # empty = follow the current network
$ProbeUrl         = "http://www.msftconnecttest.com/connecttest.txt"
$ProbeExpect      = "Microsoft Connect Test"  # body the probe URL returns on a working connection
$ProbeTimeoutMs   = 2000
$CheckHosts       = @("8.8.8.8","1.1.1.1")   # ping fallback, for networks that block the probe URL
$PingTimeoutMs    = 1000
$DownSecondsNeeded= 4                         # seconds of sustained loss before reconnecting
$TickMs           = 1000
$BaseCooldownSn   = 20                        # quiet period after a reconnect
$MaxCooldownSn    = 120                       # longest back-off on a bad network
$ClusterSn        = 120                       # reconnect again within this -> back off
$LogPath          = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "wifi-log.csv"
# ----------------

function Write-Log($evt, $outageSec, $minSinceLast) {
    if (-not (Test-Path $LogPath)) {
        "Time;Event;OutageSec;MinSinceLast;TotalReconnects" | Out-File -FilePath $LogPath -Encoding UTF8
    }
    "{0};{1};{2};{3};{4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $evt, $outageSec, $minSinceLast, $script:RefreshCnt |
        Out-File -FilePath $LogPath -Encoding UTF8 -Append
}

# ---------- Wi-Fi state ----------
# netsh labels are translated, except "SSID". The interface name is always the
# first line of a block; the profile label is matched in the common languages.
$ProfileLabel = '^\s*(Profile|Profil|Perfil|Profilo|Profiel|Profiili|\u041f\u0440\u043e\u0444\u0438\u043b\u044c|\u03a0\u03c1\u03bf\u03c6\u03af\u03bb)\s*:\s*(.+)$'

function Get-WlanInterfaces([string[]]$lines) {
    $blocks = @(); $cur = @()
    foreach ($l in $lines + "") {
        if ([string]::IsNullOrWhiteSpace($l)) { if ($cur.Count) { $blocks += ,$cur; $cur = @() } }
        else { $cur += $l }
    }
    foreach ($b in $blocks) {
        $ssid = $b | Select-String '^\s*SSID\s*:\s*(.+)$' | Select-Object -First 1
        if (-not $ssid) { continue }
        $name = if ($b[0] -match '^\s*[^:]+?\s*:\s*(.+)$') { $Matches[1].Trim() } else { $null }
        $prof = $b | Select-String $ProfileLabel | Select-Object -First 1
        [pscustomobject]@{
            Interface = $name
            Ssid      = $ssid.Matches[0].Groups[1].Value.Trim()
            Profile   = if ($prof) { $prof.Matches[0].Groups[2].Value.Trim() } else { $null }
        }
    }
}

# Refreshes $script:Ssid / Profile / Iface from the adapter that is connected now.
# In manual mode only the matching adapter is picked up; the SSID never changes.
function Update-WlanState {
    $ifs = @(Get-WlanInterfaces (netsh wlan show interfaces))
    if ($ManualSsid) {
        $m = $ifs | Where-Object { $_.Ssid -eq $ManualSsid } | Select-Object -First 1
        $script:Ssid = $ManualSsid
        if ($m) { $script:Iface = $m.Interface; if ($m.Profile) { $script:Profile = $m.Profile } }
        if (-not $script:Profile) { $script:Profile = $ManualSsid }
    } else {
        $m = $ifs | Where-Object { $_.Ssid -eq $script:Ssid } | Select-Object -First 1
        if (-not $m) { $m = $ifs | Select-Object -First 1 }
        if ($m) {
            $script:Ssid    = $m.Ssid
            $script:Iface   = $m.Interface
            $script:Profile = if ($m.Profile) { $m.Profile } else { $m.Ssid }
        }
        # Not connected: keep the last network so a dropped session can still be reconnected.
    }
    $lblSsid.Text = if ($script:Ssid) { $script:Ssid } else { "(no Wi-Fi network yet)" }
}

# ---------- Connectivity check (runs off the UI thread) ----------
$handler = New-Object System.Net.Http.HttpClientHandler
$handler.AllowAutoRedirect = $false
$http = New-Object System.Net.Http.HttpClient($handler)
$http.Timeout = [TimeSpan]::FromMilliseconds($ProbeTimeoutMs)
$http.DefaultRequestHeaders.CacheControl = New-Object System.Net.Http.Headers.CacheControlHeaderValue -Property @{ NoCache = $true }

function Start-Check {
    $pings = foreach ($h in $CheckHosts) {
        $p = New-Object System.Net.NetworkInformation.Ping
        [pscustomobject]@{ Ping = $p; Task = $p.SendPingAsync($h, $PingTimeoutMs) }
    }
    [pscustomobject]@{ Http = $http.GetAsync($ProbeUrl); Pings = @($pings); StartedAt = Get-Date }
}

function Test-CheckDone($c) {
    if (-not $c.Http.IsCompleted) { return $false }
    foreach ($p in $c.Pings) { if (-not $p.Task.IsCompleted) { return $false } }
    return $true
}

# "Online", "Portal" (a login page answered instead of the probe) or "Offline"
function Get-CheckResult($c) {
    $httpState = "Failed"
    if ($c.Http.Status -eq 'RanToCompletion') {
        $r = $c.Http.Result
        $body = try { $r.Content.ReadAsStringAsync().Result } catch { "" }
        $httpState = if ([int]$r.StatusCode -eq 200 -and $body -like "$ProbeExpect*") { "Ok" } else { "Portal" }
        $r.Dispose()
    }
    $pingOk = $false
    foreach ($p in $c.Pings) {
        if ($p.Task.Status -eq 'RanToCompletion' -and $p.Task.Result.Status -eq 'Success') { $pingOk = $true }
        $p.Ping.Dispose()
    }
    if ($httpState -eq "Ok")     { return "Online" }
    if ($httpState -eq "Portal") { return "Portal" }
    if ($pingOk)                 { return "Online" }  # probe URL blocked, but the internet works
    return "Offline"
}

$script:Ssid           = $null
$script:Profile        = $null
$script:Iface          = $null
$script:RefreshCnt     = 0
$script:DownSince      = $null
$script:FailSince      = $null
$script:LastRefAt      = $null
$script:CooldownUntil  = $null
$script:CurrentCooldown= $BaseCooldownSn
$script:Pending        = $null
$script:Reconnecting   = $false
$script:InPortal       = $false
$script:OkCount        = 0

# ---------- Window ----------
$form              = New-Object System.Windows.Forms.Form
$form.Text         = "Public WiFi Reconnect"
$form.Size         = New-Object System.Drawing.Size(360, 285)
$form.StartPosition= "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox  = $false
$form.BackColor    = [System.Drawing.Color]::FromArgb(30,30,35)

function New-Label($text,$x,$y,$w,$h,$size,$color,$bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text=$text; $l.Location=New-Object System.Drawing.Point($x,$y); $l.Size=New-Object System.Drawing.Size($w,$h)
    $st = if($bold){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}
    $l.Font=New-Object System.Drawing.Font("Segoe UI",$size,$st); $l.ForeColor=$color; $l.TextAlign="MiddleCenter"
    $form.Controls.Add($l); return $l
}

$lblSsid = New-Label "" 20 14 320 24 11 ([System.Drawing.Color]::Gainsboro) $true
$lblNet  = New-Label "..." 20 46 320 52 25 ([System.Drawing.Color]::White) $true
$lblInfo = New-Label "watching..." 20 104 320 18 9 ([System.Drawing.Color]::Silver) $false
$lblCnt  = New-Label "Reconnects this session: 0" 20 124 320 18 9 ([System.Drawing.Color]::Gray) $false

$btn = New-Object System.Windows.Forms.Button
$btn.Text="Reconnect Now"; $btn.Location=New-Object System.Drawing.Point(20,154); $btn.Size=New-Object System.Drawing.Size(200,46)
$btn.FlatStyle="Flat"; $btn.BackColor=[System.Drawing.Color]::FromArgb(0,120,200); $btn.ForeColor=[System.Drawing.Color]::White
$btn.Font=New-Object System.Drawing.Font("Segoe UI",12,[System.Drawing.FontStyle]::Bold); $form.Controls.Add($btn)

$btnLog = New-Object System.Windows.Forms.Button
$btnLog.Text="Open Log"; $btnLog.Location=New-Object System.Drawing.Point(230,154); $btnLog.Size=New-Object System.Drawing.Size(110,46)
$btnLog.FlatStyle="Flat"; $btnLog.BackColor=[System.Drawing.Color]::FromArgb(70,70,80); $btnLog.ForeColor=[System.Drawing.Color]::White
$btnLog.Font=New-Object System.Drawing.Font("Segoe UI",10,[System.Drawing.FontStyle]::Bold); $form.Controls.Add($btnLog)
$btnLog.add_Click({ if (Test-Path $LogPath) { Start-Process notepad.exe $LogPath } })

$lblHint = New-Label "Minimize to send it to the tray." 20 210 320 18 8 ([System.Drawing.Color]::DimGray) $false

# ---------- Tray icon ----------
function New-DotIcon($color) {
    $bmp = New-Object System.Drawing.Bitmap 16,16
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = "AntiAlias"
    $g.FillEllipse((New-Object System.Drawing.SolidBrush $color), 2, 2, 12, 12)
    $g.Dispose()
    return [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
}
$icons = @{
    Ok     = New-DotIcon ([System.Drawing.Color]::LimeGreen)
    Wait   = New-DotIcon ([System.Drawing.Color]::Goldenrod)
    Down   = New-DotIcon ([System.Drawing.Color]::Tomato)
    Portal = New-DotIcon ([System.Drawing.Color]::Orange)
}
$form.Icon = $icons.Wait

$tray = New-Object System.Windows.Forms.NotifyIcon
$tray.Icon = $icons.Wait
$tray.Text = "Public WiFi Reconnect"
$tray.Visible = $true

function Show-Main { $form.Show(); $form.WindowState = "Normal"; $form.Activate() }
$menu = New-Object System.Windows.Forms.ContextMenuStrip
[void]$menu.Items.Add("Show", $null, { Show-Main })
[void]$menu.Items.Add("Reconnect Now", $null, { Do-Refresh "Manual" })
[void]$menu.Items.Add("Exit", $null, { $form.Close() })
$tray.ContextMenuStrip = $menu
$tray.add_DoubleClick({ Show-Main })
$form.add_Resize({ if ($form.WindowState -eq "Minimized") { $form.Hide() } })

function Set-Status($text, $color, $icon, $info) {
    $lblNet.Text = $text; $lblNet.ForeColor = $color
    if ($info) { $lblInfo.Text = $info }
    $tray.Icon = $icon; $form.Icon = $icon
    $tip = "WiFi Reconnect: $text"
    $tray.Text = $tip.Substring(0, [math]::Min($tip.Length, 63))
}

# ---------- Reconnect ----------
$connectTimer = New-Object System.Windows.Forms.Timer
$connectTimer.Interval = 700

function Do-Refresh($why) {
    if ($script:Reconnecting) { return }
    Update-WlanState
    if (-not $script:Ssid) {
        Set-Status "NO WI-FI" ([System.Drawing.Color]::Tomato) $icons.Down "connect to a Wi-Fi network first"
        return
    }
    $now = Get-Date

    # Back off if we had to reconnect again too soon
    if ($script:LastRefAt -and ($now - $script:LastRefAt).TotalSeconds -lt $ClusterSn) {
        $script:CurrentCooldown = [math]::Min($script:CurrentCooldown * 2, $MaxCooldownSn)
    } else {
        $script:CurrentCooldown = $BaseCooldownSn
    }
    $script:MinSince = if ($script:LastRefAt) { [math]::Round(($now - $script:LastRefAt).TotalMinutes, 1) } else { "" }
    $script:LastRefAt = $now
    $script:RefreshWhy = $why
    $script:Reconnecting = $true
    $script:CooldownUntil = $now.AddSeconds($script:CurrentCooldown)

    $lblInfo.Text = "$why - reconnecting..."
    if ($script:Iface) { netsh wlan disconnect interface="$($script:Iface)" | Out-Null }
    else               { netsh wlan disconnect | Out-Null }
    $connectTimer.Start()   # connect after a short pause, without blocking the window
}

$connectTimer.add_Tick({
    $connectTimer.Stop()
    $netshArgs = @("wlan", "connect", "name=`"$($script:Profile)`"", "ssid=`"$($script:Ssid)`"")
    if ($script:Iface) { $netshArgs += "interface=`"$($script:Iface)`"" }
    $out = & netsh @netshArgs 2>&1 | Out-String
    $ok  = ($LASTEXITCODE -eq 0)
    $now = Get-Date

    $script:RefreshCnt++
    $lblCnt.Text = "Reconnects this session: $($script:RefreshCnt)"
    if ($ok) {
        $lblInfo.Text = "Last reconnect: $($now.ToString('HH:mm:ss')) ($($script:RefreshWhy))"
        Write-Log $script:RefreshWhy "" $script:MinSince
    } else {
        $lblInfo.Text = "Reconnect failed - profile '$($script:Profile)' not found?"
        Write-Log ("{0} - connect failed: {1}" -f $script:RefreshWhy, ($out.Trim() -replace '[;\r\n]+', ' ')) "" $script:MinSince
    }
    $script:FailSince = $null
    $script:CooldownUntil = $now.AddSeconds($script:CurrentCooldown)
    $script:Reconnecting = $false
})
$btn.add_Click({ Do-Refresh "Manual" })

# ---------- Timer ----------
function Handle-Result($result, $checkedAt) {
    $now = Get-Date
    if ($result -ne "Portal" -and $script:InPortal) { $script:InPortal = $false }

    if ($result -eq "Online") {
        if ($script:DownSince -ne $null) {
            $gap = [int]($now - $script:DownSince).TotalSeconds
            if ($gap -ge 2) { Write-Log "Recovered" $gap "" }
            $script:DownSince = $null
        }
        $script:FailSince = $null
        Set-Status "INTERNET OK" ([System.Drawing.Color]::LimeGreen) $icons.Ok "watching..."
        # Follow network changes every few seconds while things are fine
        if (($script:OkCount % 5) -eq 0) { Update-WlanState }
        $script:OkCount++
        return
    }

    if ($result -eq "Portal") {
        # Reconnecting will not get past a login page, so do nothing but tell the user
        $script:FailSince = $null
        if (-not $script:InPortal) {
            $script:InPortal = $true
            Write-Log "LoginPage" "" ""
            $tray.ShowBalloonTip(5000, "Public WiFi Reconnect", "This network wants you to sign in. Open a browser to log in.", "Warning")
        }
        Set-Status "LOGIN PAGE" ([System.Drawing.Color]::Orange) $icons.Portal "sign in from a browser - reconnecting won't help"
        return
    }

    # Offline
    if ($script:DownSince -eq $null) { $script:DownSince = $now }
    if ($script:Reconnecting) { return }
    if ($script:CooldownUntil -ne $null -and $now -lt $script:CooldownUntil) {
        # Staying quiet after a reconnect - no action (prevents reconnect loops)
        $left = [int]($script:CooldownUntil - $now).TotalSeconds
        $script:FailSince = $null
        Set-Status "SHORT OUTAGE" ([System.Drawing.Color]::Goldenrod) $icons.Wait "waiting for the network to recover ($left s)..."
        return
    }
    # Count from when the failing check started, not when its timeout ran out
    if ($script:FailSince -eq $null) { $script:FailSince = $checkedAt }
    $down = [int]($now - $script:FailSince).TotalSeconds
    if ($down -lt $DownSecondsNeeded) {
        Set-Status "SHORT OUTAGE" ([System.Drawing.Color]::Goldenrod) $icons.Wait "waiting ($down/$DownSecondsNeeded s)... most fix themselves"
    } else {
        Set-Status "NO INTERNET" ([System.Drawing.Color]::Tomato) $icons.Down
        Do-Refresh "Outage detected"
    }
}

$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $TickMs
$timer.add_Tick({
    if ($script:Pending -eq $null) { $script:Pending = Start-Check; return }
    if (-not (Test-CheckDone $script:Pending)) { return }
    $done = $script:Pending
    $script:Pending = Start-Check
    Handle-Result (Get-CheckResult $done) $done.StartedAt
})

Update-WlanState
Write-Log "Started" "" ""
$timer.Start()

$form.add_FormClosing({
    $timer.Stop(); $connectTimer.Stop()
    $tray.Visible = $false; $tray.Dispose()
    $http.Dispose()
    Write-Log "Closed" "" ""
})
[void]$form.ShowDialog()

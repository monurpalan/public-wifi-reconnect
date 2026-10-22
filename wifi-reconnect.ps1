# ============================================================
#  Public WiFi Reconnect
#  Auto-reconnects on public Wi-Fi when the session drops on a timer.
#  Detects the current network automatically. Windows only. MIT license.
#
#  Use only on networks you are allowed to use.
# ============================================================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- Settings ---
$script:Ssid    = ""                       # empty = use the current network
$CheckHosts     = @("8.8.8.8","1.1.1.1")   # internet is "up" if any of these reply
$PingTimeoutMs  = 600
$FailsNeeded    = 4                         # seconds of sustained loss before reconnecting
$TickMs         = 1000
$BaseCooldownSn = 20                        # quiet period after a reconnect
$MaxCooldownSn  = 120                       # longest back-off on a bad network
$ClusterSn      = 120                       # reconnect again within this -> back off
$LogPath        = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "wifi-log.csv"
# ----------------

$pinger = New-Object System.Net.NetworkInformation.Ping

function Write-Log($event, $outageSec, $minSinceLast) {
    if (-not (Test-Path $LogPath)) {
        "Time;Event;OutageSec;MinSinceLast;TotalReconnects" | Out-File -FilePath $LogPath -Encoding UTF8
    }
    "{0};{1};{2};{3};{4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $event, $outageSec, $minSinceLast, $script:RefreshCnt |
        Out-File -FilePath $LogPath -Encoding UTF8 -Append
}

function Get-CurrentSsid {
    $line = (netsh wlan show interfaces) | Select-String '^\s*SSID\s*:\s*(.+)$'
    if ($line) { return $line.Matches[0].Groups[1].Value.Trim() }
    return $null
}
if ([string]::IsNullOrWhiteSpace($script:Ssid)) {
    $s = Get-CurrentSsid
    if ($s) { $script:Ssid = $s } else { $script:Ssid = "(not connected)" }
}

function Test-Internet {
    foreach ($h in $CheckHosts) {
        try { if ($pinger.Send($h, $PingTimeoutMs).Status -eq 'Success') { return $true } }
        catch { }
    }
    return $false
}

$script:Fails          = 0
$script:RefreshCnt     = 0
$script:DownSince      = $null
$script:LastRefAt      = Get-Date
$script:CooldownUntil  = $null
$script:CurrentCooldown= $BaseCooldownSn

Write-Log "Started" "" ""

# ---------- Window ----------
$form              = New-Object System.Windows.Forms.Form
$form.Text         = "Public WiFi Reconnect"
$form.Size         = New-Object System.Drawing.Size(360, 285)
$form.StartPosition= "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox  = $false
$form.BackColor    = [System.Drawing.Color]::FromArgb(30,30,35)
$form.TopMost      = $true

function New-Label($text,$x,$y,$w,$h,$size,$color,$bold) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text=$text; $l.Location=New-Object System.Drawing.Point($x,$y); $l.Size=New-Object System.Drawing.Size($w,$h)
    $st = if($bold){[System.Drawing.FontStyle]::Bold}else{[System.Drawing.FontStyle]::Regular}
    $l.Font=New-Object System.Drawing.Font("Segoe UI",$size,$st); $l.ForeColor=$color; $l.TextAlign="MiddleCenter"
    $form.Controls.Add($l); return $l
}

$lblSsid = New-Label $script:Ssid 20 14 320 24 11 ([System.Drawing.Color]::Gainsboro) $true
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

function Do-Refresh($why) {
    $now = Get-Date
    $minSince = [math]::Round(($now - $script:LastRefAt).TotalMinutes, 1)

    # Back off if we had to reconnect again too soon
    if (($now - $script:LastRefAt).TotalSeconds -lt $ClusterSn) {
        $script:CurrentCooldown = [math]::Min($script:CurrentCooldown * 2, $MaxCooldownSn)
    } else {
        $script:CurrentCooldown = $BaseCooldownSn
    }
    $script:LastRefAt = $now

    $lblInfo.Text = "$why - reconnecting..."
    $form.Refresh()
    netsh wlan disconnect | Out-Null
    Start-Sleep -Milliseconds 700
    netsh wlan connect name="$($script:Ssid)" ssid="$($script:Ssid)" | Out-Null

    $script:RefreshCnt++
    $lblInfo.Text = "Last reconnect: $($now.ToString('HH:mm:ss')) ($why)"
    $lblCnt.Text  = "Reconnects this session: $($script:RefreshCnt)"
    Write-Log $why "" $minSince
    $script:Fails = 0
    $script:CooldownUntil = (Get-Date).AddSeconds($script:CurrentCooldown)
}
$btn.add_Click({ Do-Refresh "Manual" })

# ---------- Timer ----------
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = $TickMs
$timer.add_Tick({
    if (Test-Internet) {
        if ($script:DownSince -ne $null) {
            $gap = [int]((Get-Date) - $script:DownSince).TotalSeconds
            if ($gap -ge 2) { Write-Log "Recovered" $gap "" }
            $script:DownSince = $null
        }
        $script:Fails = 0
        $lblNet.Text = "INTERNET OK"; $lblNet.ForeColor = [System.Drawing.Color]::LimeGreen
        $lblInfo.Text = "watching..."
    } else {
        if ($script:DownSince -eq $null) { $script:DownSince = Get-Date }
        if ($script:CooldownUntil -ne $null -and (Get-Date) -lt $script:CooldownUntil) {
            # Staying quiet after a reconnect - no action (prevents reconnect loops)
            $left = [int]($script:CooldownUntil - (Get-Date)).TotalSeconds
            $lblNet.Text = "SHORT OUTAGE"; $lblNet.ForeColor = [System.Drawing.Color]::Goldenrod
            $lblInfo.Text = "waiting for the network to recover ($left s)..."
            $script:Fails = 0
        } else {
            $script:Fails++
            if ($script:Fails -lt $FailsNeeded) {
                $lblNet.Text = "SHORT OUTAGE"; $lblNet.ForeColor = [System.Drawing.Color]::Goldenrod
                $lblInfo.Text = "waiting ($($script:Fails)/$FailsNeeded s)... most fix themselves"
            } else {
                $lblNet.Text = "NO INTERNET"; $lblNet.ForeColor = [System.Drawing.Color]::Tomato
                Do-Refresh "Outage detected"
            }
        }
    }
})
$timer.Start()

$form.add_FormClosing({ $timer.Stop(); Write-Log "Closed" "" "" })
[void]$form.ShowDialog()

# Publish GPS state + the accumulated journey track for the web page.
#
# Holds ONE persistent TCP connection to gpsd on the Pi (over Tailscale) and
# writes files as reports arrive. Costs the Pi nothing: no SSH handshakes, no
# polling -- those previously stole enough CPU from its single ARMv6 core to
# cause audio dropouts.
#
# Two outputs:
#   gps.json   - current position / fix / satellites, plus last known fix so
#                the map can show where the rig was when the signal drops.
#   track.json - the walked path so far. Kept HERE rather than in the browser so it
#                survives page reloads and browser restarts; the journey is
#                ~74 km on foot and takes many hours.

# --- configuration (environment, with sensible defaults) ---------------
# Set these as system environment variables, or edit the defaults here.
if (-not $env:ARCHIVE_DIR) { $env:ARCHIVE_DIR = "D:\xhome" }      # recordings + GPS logs
if (-not $env:APP_DIR)     { $env:APP_DIR     = "C:\broadcast" }  # scripts + state files
if (-not $env:PI_HOST)     { $env:PI_HOST     = "192.168.1.50" }   # the Raspberry Pi
# ----------------------------------------------------------------------

$ErrorActionPreference = "SilentlyContinue"

$piHost    = "$env:PI_HOST"
$piPort    = 2947
$dest      = "C:\broadcast\gps.json"
$trackFile = "C:\broadcast\track.json"
$gpsLogDir = "D:\xhome\gps"
$log       = "C:\broadcast\gps-pull.log"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$writeEvery    = 5      # seconds between gps.json rewrites
$trackMinMove  = 20     # metres before a new track point is recorded
$trackMinTime  = 120    # ...or this many seconds, whichever comes first
$trackMaxPts   = 4000   # cap so the file stays small over a long journey

function Log($m) {
    Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
    $f = Get-Item $log -ErrorAction SilentlyContinue
    if ($f -and $f.Length -gt 200000) { [System.IO.File]::WriteAllLines($log, (Get-Content $log -Tail 200)) }
}
function Now-Epoch { [int][double]::Parse((Get-Date -Date (Get-Date).ToUniversalTime() -UFormat %s)) }

function Haversine($lat1, $lon1, $lat2, $lon2) {
    $R = 6371000.0
    $p1 = $lat1 * [math]::PI / 180; $p2 = $lat2 * [math]::PI / 180
    $dp = ($lat2 - $lat1) * [math]::PI / 180
    $dl = ($lon2 - $lon1) * [math]::PI / 180
    $a = [math]::Sin($dp/2) * [math]::Sin($dp/2) +
         [math]::Cos($p1) * [math]::Cos($p2) * [math]::Sin($dl/2) * [math]::Sin($dl/2)
    return 2 * $R * [math]::Asin([math]::Sqrt($a))
}

# Recover state written before a restart.
$lastLat = $null; $lastLon = $null; $lastAlt = $null; $lastFixTime = $null
if (Test-Path $dest) {
    try {
        $prev = Get-Content $dest -Raw | ConvertFrom-Json
        if ($null -ne $prev.last_lat) {
            $lastLat = $prev.last_lat; $lastLon = $prev.last_lon
            $lastAlt = $prev.last_alt; $lastFixTime = $prev.last_fix_time
        }
    } catch { }
}

$track = New-Object System.Collections.ArrayList
if (Test-Path $trackFile) {
    try {
        $t = Get-Content $trackFile -Raw | ConvertFrom-Json
        foreach ($p in $t.points) { [void]$track.Add(@($p[0], $p[1], $p[2])) }
        Log ("recovered track: " + $track.Count + " points")
    } catch { }
}

function Save-Track {
    $obj = [ordered]@{ points = $track; updated = (Now-Epoch); count = $track.Count }
    [System.IO.File]::WriteAllText($trackFile, ($obj | ConvertTo-Json -Compress -Depth 4), $utf8NoBom)
}

Log "gpsd reader started -> ${piHost}:${piPort}"

while ($true) {
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $iar = $client.BeginConnect($piHost, $piPort, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne(10000)) { throw "connect timeout" }
        $client.EndConnect($iar)

        $stream = $client.GetStream(); $stream.ReadTimeout = 30000
        $reader = New-Object System.IO.StreamReader($stream)
        $writer = New-Object System.IO.StreamWriter($stream); $writer.AutoFlush = $true
        $writer.WriteLine('?WATCH={"enable":true,"json":true}')
        Log "connected"

        $fix = 0; $fixText = "no fix"; $lat = $null; $lon = $null; $alt = $null
        $speed = $null; $track_deg = $null; $satsUsed = 0; $satsSeen = 0
        $hdop = $null; $snr = @(); $gpsTime = $null
        $lastWrite = [DateTime]::MinValue
        $lastTrackSave = [DateTime]::MinValue

        while ($client.Connected) {
            $line = $reader.ReadLine()
            if ($null -eq $line) { throw "stream closed" }
            $d = $null
            try { $d = $line | ConvertFrom-Json } catch { continue }
            if (-not $d) { continue }

            switch ($d.class) {
                "TPV" {
                    $m = if ($null -ne $d.mode) { [int]$d.mode } else { 0 }
                    $fix = $m
                    $fixText = switch ($m) { 0 {"no data"} 1 {"no fix"} 2 {"2D fix"} 3 {"3D fix"} default {"unknown"} }
                    if ($m -ge 2 -and $null -ne $d.lat -and $null -ne $d.lon) {
                        $lat = $d.lat; $lon = $d.lon; $alt = $d.alt
                        $speed = $d.speed; $track_deg = $d.track
                        $lastLat = $d.lat; $lastLon = $d.lon; $lastAlt = $d.alt
                        $lastFixTime = Now-Epoch

                        # Append to the journey track, thinned by distance/time
                        # so a stationary rig does not fill the file.
                        $add = $false
                        if ($track.Count -eq 0) { $add = $true }
                        else {
                            $p = $track[$track.Count - 1]
                            $moved = Haversine $p[0] $p[1] $d.lat $d.lon
                            $elapsed = (Now-Epoch) - $p[2]
                            if ($moved -ge $trackMinMove -or $elapsed -ge $trackMinTime) { $add = $true }
                        }
                        if ($add) {
                            $ts = Now-Epoch
                            [void]$track.Add(@([math]::Round($d.lat,6), [math]::Round($d.lon,6), $ts))
                            while ($track.Count -gt $trackMaxPts) { $track.RemoveAt(0) }

                            # Append-only history on the archive volume, one file
                            # per UTC day. Archived video is named by UTC start
                            # time, so playback can look up where the rig was at
                            # any moment in a recording.
                            try {
                                if (-not (Test-Path $gpsLogDir)) { New-Item -ItemType Directory -Path $gpsLogDir -Force | Out-Null }
                                $day = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")
                                $rec = @{ t = $ts; lat = [math]::Round($d.lat,6); lon = [math]::Round($d.lon,6) }
                                if ($null -ne $d.alt) { $rec.alt = [math]::Round($d.alt,1) }
                                Add-Content -Path (Join-Path $gpsLogDir "$day.jsonl") -Value ($rec | ConvertTo-Json -Compress)
                            } catch { }
                        }
                    } else {
                        $lat = $null; $lon = $null; $alt = $null; $speed = $null; $track_deg = $null
                    }
                    $gpsTime = $d.time
                }
                "SKY" {
                    $sats = @($d.satellites)
                    $satsSeen = $sats.Count
                    $satsUsed = @($sats | Where-Object { $_.used }).Count
                    $hdop = $d.hdop
                    $snr = @($sats | ForEach-Object { if ($_.ss) { [int]$_.ss } else { 0 } } |
                             Sort-Object -Descending | Select-Object -First 6)
                }
            }

            if (((Get-Date) - $lastWrite).TotalSeconds -ge $writeEvery) {
                $state = [ordered]@{
                    fix = $fix; fix_text = $fixText
                    lat = $lat; lon = $lon; alt = $alt
                    speed = $speed; track = $track_deg
                    sats_used = $satsUsed; sats_seen = $satsSeen
                    hdop = $hdop; snr = $snr; gps_time = $gpsTime
                    last_lat = $lastLat; last_lon = $lastLon; last_alt = $lastAlt
                    last_fix_time = $lastFixTime
                    track_points = $track.Count
                    updated = (Now-Epoch)
                }
                [System.IO.File]::WriteAllText($dest, ($state | ConvertTo-Json -Compress), $utf8NoBom)
                $lastWrite = Get-Date
            }
            if (((Get-Date) - $lastTrackSave).TotalSeconds -ge 15) {
                Save-Track
                $lastTrackSave = Get-Date
            }
        }
    } catch {
        Log ("connection lost: " + $_.Exception.Message)
        Save-Track
    } finally { if ($client) { $client.Close() } }
    Start-Sleep -Seconds 5
}

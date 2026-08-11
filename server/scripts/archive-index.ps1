# Build per-day VOD HLS playlists over the archived segments.
#
# The archive is segmented on disk (crash-safe, prunable), but a playlist
# stitches a whole day into ONE continuous timeline -- the viewer scrubs
# freely and never sees the split.
#
# Each segment carries EXT-X-PROGRAM-DATE-TIME, so hls.js can report the exact
# wall-clock time of the frame on screen. That is what the GPS lookup keys off,
# with no filename arithmetic.
#
# Where recording stopped and resumed, EXT-X-DISCONTINUITY marks the join so
# the player does not assume a continuous decode timeline across the gap.

# --- configuration (environment, with sensible defaults) ---------------
# Set these as system environment variables, or edit the defaults here.
if (-not $env:ARCHIVE_DIR) { $env:ARCHIVE_DIR = "D:\xhome" }      # recordings + GPS logs
if (-not $env:APP_DIR)     { $env:APP_DIR     = "C:\broadcast" }  # scripts + state files
if (-not $env:PI_HOST)     { $env:PI_HOST     = "192.168.1.50" }   # the Raspberry Pi
# ----------------------------------------------------------------------

$ErrorActionPreference = "SilentlyContinue"

$videoDir  = "D:\xhome\video"
$root      = "D:\xhome"
$cacheFile = "D:\xhome\.durations.json"

# The walk ended at 17:30 JST on 2026-08-11. Recordings either side of that
# moment are different things -- the journey, and whatever the hardware kept
# filming afterwards -- so they are indexed as separate playlists rather than
# one continuous day.
$GIVEUP_EPOCH = 0    # unix seconds; 0 = no split
$log       = "C:\broadcast\archive-index.log"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Log($m) {
    Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
    $f = Get-Item $log -ErrorAction SilentlyContinue
    if ($f -and $f.Length -gt 100000) { [System.IO.File]::WriteAllLines($log, (Get-Content $log -Tail 100)) }
}

function Probe-Duration($name) {
    try {
        $out = docker run --rm --entrypoint ffprobe -v D:\xhome:/archive `
                 jrottenberg/ffmpeg:8.1-nvidia2404 `
                 -v error -show_entries format=duration -of default=nk=1:nw=1 "/archive/video/$name" 2>$null
        $v = [double]::Parse(($out | Select-Object -First 1), [Globalization.CultureInfo]::InvariantCulture)
        if ($v -gt 0) { return [math]::Round($v, 3) }
    } catch { }
    return $null
}

$durations = @{}
if (Test-Path $cacheFile) {
    try {
        $c = Get-Content $cacheFile -Raw | ConvertFrom-Json
        foreach ($p in $c.PSObject.Properties) { $durations[$p.Name] = $p.Value }
    } catch { }
}

Log "archive indexer started (VOD playlists)"

while ($true) {
    $files = Get-ChildItem "$videoDir\*.ts" -ErrorAction SilentlyContinue | Sort-Object Name
    $newest = if ($files) { ($files | Select-Object -Last 1).Name } else { $null }

    $segs = @()
    foreach ($f in $files) {
        $m = [regex]::Match($f.BaseName, '^(\d{4})-(\d{2})-(\d{2})_(\d{2})-(\d{2})-(\d{2})$')
        if (-not $m.Success) { continue }
        $start = [datetime]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value,
                                 [int]$m.Groups[4].Value, [int]$m.Groups[5].Value, [int]$m.Groups[6].Value,
                                 [DateTimeKind]::Utc)

        # Never cache the newest file's duration: it is still being written.
        $dur = $durations[$f.Name]
        if ($null -eq $dur -or $f.Name -eq $newest) {
            $dur = Probe-Duration $f.Name
            if ($null -ne $dur -and $f.Name -ne $newest) { $durations[$f.Name] = $dur }
        }
        if ($null -eq $dur) { continue }

        $segs += [pscustomobject]@{
            Name = $f.Name; Start = $start; Dur = $dur
            Day = $start.ToString("yyyy-MM-dd")
            Epoch = [int][double]::Parse((Get-Date -Date $start -UFormat %s))
            SizeMB = [math]::Round($f.Length / 1MB, 1)
        }
    }

    # Tag each segment with which side of the give-up it belongs to.
    foreach ($s in $segs) {
        $ph = "after"
        if ($s.Epoch -lt $GIVEUP_EPOCH) { $ph = "walk" }
        $s | Add-Member -NotePropertyName Phase -NotePropertyValue $ph -Force
        $s | Add-Member -NotePropertyName DayPhase -NotePropertyValue ("$($s.Day)|$ph") -Force
    }

    $days = @()
    foreach ($grp in ($segs | Group-Object DayPhase | Sort-Object Name)) {
        $items = $grp.Group | Sort-Object Start
        $maxDur = [math]::Ceiling((($items | Measure-Object -Property Dur -Maximum).Maximum))
        if ($maxDur -lt 1) { $maxDur = 1 }

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.AppendLine("#EXTM3U")
        [void]$sb.AppendLine("#EXT-X-VERSION:3")
        [void]$sb.AppendLine("#EXT-X-PLAYLIST-TYPE:VOD")
        [void]$sb.AppendLine("#EXT-X-TARGETDURATION:$maxDur")
        [void]$sb.AppendLine("#EXT-X-MEDIA-SEQUENCE:0")

        $prevEnd = $null
        foreach ($it in $items) {
            # A gap between the previous segment's end and this start means
            # recording stopped; tell the player so it re-bases timestamps.
            if ($null -ne $prevEnd) {
                $gap = ($it.Start - $prevEnd).TotalSeconds
                if ($gap -gt 2) { [void]$sb.AppendLine("#EXT-X-DISCONTINUITY") }
            }
            [void]$sb.AppendLine("#EXT-X-PROGRAM-DATE-TIME:" + $it.Start.ToString("yyyy-MM-ddTHH:mm:ss.fffZ"))
            [void]$sb.AppendLine("#EXTINF:" + $it.Dur.ToString([Globalization.CultureInfo]::InvariantCulture) + ",")
            [void]$sb.AppendLine("video/" + $it.Name)
            $prevEnd = $it.Start.AddSeconds($it.Dur)
        }
        # Only close the playlist for days that are finished; leaving the
        # current day open lets the player pick up newly written segments.
        $dayName = $grp.Name.Split("|")[0]
        $phase   = $grp.Name.Split("|")[1]
        $slug    = "$dayName-$phase"
        # Only the still-growing "after" set of today stays open-ended; the walk
        # is finished by definition and can be closed.
        $isToday = ($dayName -eq (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")) -and ($phase -eq "after")
        if (-not $isToday) { [void]$sb.AppendLine("#EXT-X-ENDLIST") }

        [System.IO.File]::WriteAllText((Join-Path $root ("day-" + $slug + ".m3u8")), $sb.ToString(), $utf8NoBom)

        $total = ($items | Measure-Object -Property Dur -Sum).Sum
        $days += [ordered]@{
            day      = $dayName
            phase    = $phase
            playlist = "day-" + $slug + ".m3u8"
            segments = $items.Count
            start    = ($items | Select-Object -First 1).Epoch
            end      = [int]((($items | Select-Object -Last 1).Epoch) + ($items | Select-Object -Last 1).Dur)
            duration = [math]::Round($total, 1)
            size_mb  = [math]::Round((($items | Measure-Object -Property SizeMB -Sum).Sum), 1)
            live     = $isToday
        }
    }

    $obj = [ordered]@{
        days    = @($days | Sort-Object -Property day, phase -Descending)
        count   = $days.Count
        updated = [int][double]::Parse((Get-Date -Date (Get-Date).ToUniversalTime() -UFormat %s))
    }
    [System.IO.File]::WriteAllText((Join-Path $root "archive.json"), ($obj | ConvertTo-Json -Compress -Depth 5), $utf8NoBom)
    ($durations | ConvertTo-Json -Compress) | Set-Content -Path $cacheFile -Encoding utf8

    Start-Sleep -Seconds 45
}

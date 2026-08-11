# Publish a component-level health summary for the web page.
#
# Purpose: when the stream looks wrong, say WHICH part is at fault -- the Pi,
# the transcoder, or the website -- instead of leaving it ambiguous.
#
# Costs the Pi NOTHING. Every signal is read on this machine:
#
#   pi        - MediaMTX serves /live/index.m3u8 only while a publisher is
#               connected, so a 200 there means the Pi's RTMP push is arriving.
#               404 means the Pi is not publishing.
#   transcode - freshness of the HLS output the transcoder writes to disk.
#               Stale output while the Pi IS publishing isolates the fault to
#               the transcoder.
#   (website)  - judged in the browser itself; it knows its own playback state.
#
# Deliberately avoids polling the Pi over SSH: those handshakes cost real CPU
# on its single ARMv6 core and previously caused audio dropouts.

# --- configuration (environment, with sensible defaults) ---------------
# Set these as system environment variables, or edit the defaults here.
if (-not $env:ARCHIVE_DIR) { $env:ARCHIVE_DIR = "D:\xhome" }      # recordings + GPS logs
if (-not $env:APP_DIR)     { $env:APP_DIR     = "C:\broadcast" }  # scripts + state files
if (-not $env:PI_HOST)     { $env:PI_HOST     = "192.168.1.50" }   # the Raspberry Pi
# ----------------------------------------------------------------------

$ErrorActionPreference = "SilentlyContinue"

$dest      = "C:\broadcast\status.json"
$log       = "C:\broadcast\status-collect.log"
$hlsDir    = "C:\broadcast\hlsout"
$srcProbe  = "http://localhost:18888/live/index.m3u8"
$piHost    = "$env:PI_HOST"      # Pi over Tailscale
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# Output older than this means the component has stopped, not just jittered.
$STALE_SEC = 12

function Log($m) {
    Add-Content -Path $log -Value ("[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $m)
    $f = Get-Item $log -ErrorAction SilentlyContinue
    if ($f -and $f.Length -gt 120000) { [System.IO.File]::WriteAllLines($log, (Get-Content $log -Tail 120)) }
}

function Now-Epoch { [int][double]::Parse((Get-Date -Date (Get-Date).ToUniversalTime() -UFormat %s)) }

Log "status collector started"
$lastSummary = ""

while ($true) {
    # --- is the Pi publishing? -------------------------------------------
    $piPublishing = $false
    try {
        $r = Invoke-WebRequest -Uri $srcProbe -TimeoutSec 8 -UseBasicParsing
        $piPublishing = ($r.StatusCode -eq 200)
    } catch { $piPublishing = $false }

    # --- is the Pi even alive on the network? -----------------------------
    # Separates "Pi is dead/offline" from "Pi is up but not sending video",
    # which are different faults with different fixes.
    $piPing = $false
    try { $piPing = Test-Connection -ComputerName $piHost -Count 1 -Quiet -ErrorAction SilentlyContinue } catch { $piPing = $false }

    # --- is the transcoder producing? ------------------------------------
    $segAge = $null
    $seg = Get-ChildItem "$hlsDir\*.ts" -ErrorAction SilentlyContinue |
           Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($seg) { $segAge = [math]::Round(((Get-Date) - $seg.LastWriteTime).TotalSeconds, 1) }
    $transcodeOk = ($segAge -ne $null -and $segAge -lt $STALE_SEC)

    # --- containers up? ---------------------------------------------------
    $ingest = (docker inspect -f '{{.State.Running}}' xhomeTranscoder 2>$null) -eq 'true'
    $worker = (docker inspect -f '{{.State.Running}}' xhomeTranscodeWorker 2>$null) -eq 'true'

    # --- overall verdict, phrased as "where is the fault" ------------------
    $fault = "none"
    if (-not $piPing) { $fault = "pi_offline" }
    elseif (-not $piPublishing -and -not $transcodeOk) { $fault = "pi" }
    elseif ($piPublishing -and -not $transcodeOk)  { $fault = "transcode" }
    elseif (-not $piPublishing -and $transcodeOk)  { $fault = "pi" }   # output draining out

    $state = [ordered]@{
        pi_ping        = $piPing
        pi_publishing  = $piPublishing
        transcode_ok   = $transcodeOk
        segment_age    = $segAge
        ingest_up      = $ingest
        worker_up      = $worker
        fault          = $fault          # none | pi_offline | pi | transcode
        updated        = (Now-Epoch)
    }

    [System.IO.File]::WriteAllText($dest, ($state | ConvertTo-Json -Compress), $utf8NoBom)

    $summary = "ping=$piPing pub=$piPublishing transcode=$transcodeOk fault=$fault"
    if ($summary -ne $lastSummary) { Log $summary; $lastSummary = $summary }

    Start-Sleep -Seconds 8
}

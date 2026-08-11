# Count who is actually watching, from Caddy's access log.
#
# Measures real video consumption -- distinct clients fetching media segments
# in the last minute -- rather than open browser tabs. A tab left open on a
# paused player stops requesting segments and correctly drops out of the count.
#
# The client IP must come from Cf-Connecting-Ip: every request arrives through
# the Cloudflare tunnel, so remote_ip is always ::1 and would collapse every
# viewer into one.
#
# Costs the Pi nothing; this is all read on the broadcast server.

# --- configuration (environment, with sensible defaults) ---------------
# Set these as system environment variables, or edit the defaults here.
if (-not $env:ARCHIVE_DIR) { $env:ARCHIVE_DIR = "D:\xhome" }      # recordings + GPS logs
if (-not $env:APP_DIR)     { $env:APP_DIR     = "C:\broadcast" }  # scripts + state files
if (-not $env:PI_HOST)     { $env:PI_HOST     = "192.168.1.50" }   # the Raspberry Pi
# ----------------------------------------------------------------------

$ErrorActionPreference = "SilentlyContinue"

$logFile   = "C:\broadcast\access-xhome.log"
$dest      = "C:\broadcast\viewers.json"
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$WINDOW   = 60      # seconds counted as "currently watching"
$TAIL     = 4000    # log lines scanned per pass

function Now-Epoch { [int][double]::Parse((Get-Date -Date (Get-Date).ToUniversalTime() -UFormat %s)) }

while ($true) {
    $liveIps = New-Object System.Collections.Generic.HashSet[string]
    $archIps = New-Object System.Collections.Generic.HashSet[string]
    $cut = (Now-Epoch) - $WINDOW

    if (Test-Path $logFile) {
        foreach ($line in (Get-Content $logFile -Tail $TAIL -ErrorAction SilentlyContinue)) {
            if ($line -notmatch '\.ts"') { continue }        # cheap pre-filter
            $o = $null
            try { $o = $line | ConvertFrom-Json } catch { continue }
            if (-not $o -or -not $o.ts) { continue }
            if ($o.ts -lt $cut) { continue }

            $uri = $o.request.uri
            if (-not $uri) { continue }

            $ip = $o.request.headers.'Cf-Connecting-Ip'
            if ($ip -is [array]) { $ip = $ip[0] }
            if (-not $ip) { $ip = $o.request.remote_ip }
            if (-not $ip) { continue }

            if ($uri -like "/live/hd/*.ts")        { [void]$liveIps.Add($ip) }
            elseif ($uri -like "/archive/video/*") { [void]$archIps.Add($ip) }
        }
    }

    $all = New-Object System.Collections.Generic.HashSet[string]
    foreach ($i in $liveIps) { [void]$all.Add($i) }
    foreach ($i in $archIps) { [void]$all.Add($i) }

    $state = [ordered]@{
        live    = $liveIps.Count
        archive = $archIps.Count
        total   = $all.Count
        window  = $WINDOW
        updated = (Now-Epoch)
    }
    [System.IO.File]::WriteAllText($dest, ($state | ConvertTo-Json -Compress), $utf8NoBom)

    Start-Sleep -Seconds 6
}

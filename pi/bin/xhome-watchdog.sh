#!/bin/bash
# Restart the broadcast when it wedges without dying.
#
# Failure mode this exists for: if the RTMP push stalls (degraded LTE), ffmpeg
# blocks on write, stops draining the pipe, and rpicam-vid blocks writing to
# stdout. Both processes stay alive, so systemd sees a healthy service and
# never restarts it -- the stream simply freezes, indefinitely. Observed
# frozen for 30 minutes with the service reporting "active".
#
# ffmpeg's rtmp protocol has no write timeout option (only -timeout, which is
# for incoming connections), so it cannot self-terminate. Hence this.
#
# Liveness is measured as actual bytes leaving wwan0, which is what we care
# about -- not whether a process exists.

set -u

IFACE=wwan0
UNIT=xhome-broadcast.service
CHECK_EVERY=45           # seconds between samples
MIN_KBPS=30              # stream runs ~220 kbps; below this it is not sending
STRIKES_TO_RESTART=2     # consecutive bad samples before acting
COOLDOWN=240             # min seconds between restarts

log() { echo "[watchdog] $*"; }

tx_bytes() { cat "/sys/class/net/$IFACE/statistics/tx_bytes" 2>/dev/null || echo 0; }

strikes=0
last_restart=0

log "started (iface=$IFACE, min=${MIN_KBPS}kbps, window=${CHECK_EVERY}s)"

while true; do
    a=$(tx_bytes)
    sleep "$CHECK_EVERY"
    b=$(tx_bytes)

    # Only judge a service that is supposed to be running.
    if ! systemctl is-active --quiet "$UNIT"; then
        strikes=0
        continue
    fi

    # The bitrate test cannot see a picture-less stream: if rpicam-vid dies,
    # ffmpeg keeps pushing the silent audio track at ~100 kbps, which is above
    # MIN_KBPS, so the stream reads healthy while carrying no video at all.
    # Check the capture process itself; re-check once to avoid firing during
    # the few seconds of a legitimate restart.
    if ! pgrep -x rpicam-vid >/dev/null 2>&1; then
        sleep 5
        if ! pgrep -x rpicam-vid >/dev/null 2>&1; then
            now=$(date +%s)
            log "rpicam-vid NOT RUNNING while unit is active -- no video being captured"
            if [ $((now - last_restart)) -ge "$COOLDOWN" ]; then
                log "RESTARTING $UNIT (camera process gone)"
                systemctl restart "$UNIT"
                last_restart=$now
                strikes=0
                sleep 30
            else
                log "within cooldown, not restarting yet"
            fi
            continue
        fi
    fi

    kbps=$(( (b - a) * 8 / CHECK_EVERY / 1000 ))

    if [ "$kbps" -lt "$MIN_KBPS" ]; then
        strikes=$((strikes + 1))
        log "low upload: ${kbps}kbps (strike ${strikes}/${STRIKES_TO_RESTART})"

        if [ "$strikes" -ge "$STRIKES_TO_RESTART" ]; then
            now=$(date +%s)
            if [ $((now - last_restart)) -lt "$COOLDOWN" ]; then
                log "within cooldown, not restarting yet"
            else
                log "RESTARTING $UNIT (stream appears wedged)"
                systemctl restart "$UNIT"
                last_restart=$now
                strikes=0
                sleep 30      # let it come up before judging again
            fi
        fi
    else
        [ "$strikes" -gt 0 ] && log "recovered: ${kbps}kbps"
        strikes=0
    fi
done

#!/bin/bash
set -u

# --- configuration ----------------------------------------------------
# Values come from /etc/xhome.env (see xhome.env.example). Sourced rather
# than hard-coded so no address or credential lives in this script.
[ -f /etc/xhome.env ] && . /etc/xhome.env
: "${RTMP_URL:?set RTMP_URL in /etc/xhome.env, e.g. rtmp://host:1935/live?user=U&pass=P}"
# ----------------------------------------------------------------------
# Deliberately NOT `set -e`: a failure in the audio pre-flight must not abort
# the script -- video is the priority and has to go out regardless.


# ---------------------------------------------------------------------------
# Audio pre-flight.
#
# Video must stream even when audio is lost. If the mic cannot be opened (a
# loose wire has done this more than once), fall back to a silent source so
# ffmpeg still has two inputs and keeps publishing video. Without this, a dead
# mic takes the whole broadcast down: ffmpeg exits, systemd restarts it, and it
# fails again in a loop with no video at all.
#
# Note this only detects an unopenable device. A mic that opens but returns
# digital silence still "passes" -- and that is the right call, because video
# keeps flowing either way.
# ---------------------------------------------------------------------------
AUDIO_ARGS=()
if timeout 6 arecord -D miccap -f S16_LE -c 1 -r 48000 -d 1 -q -t raw /tmp/mictest.raw 2>/dev/null; then
    # Opening the device is NOT proof of a working mic: a disconnected I2S data
    # line still yields a perfectly valid capture of pure zeros, which then goes
    # out as a silent broadcast with nothing in the logs. Check for real samples.
    if [ "$(tr -d '\0' < /tmp/mictest.raw | wc -c)" -eq 0 ]; then
        echo "[xhome] MIC SILENT -- device opens but every sample is zero."
        echo "[xhome] Hardware fault: check the I2S mic DATA line (GPIO20 / pin 38) and its 3V3+GND."
    else
        echo "[xhome] mic OK -> using miccap"
    fi
    AUDIO_ARGS=(-thread_queue_size 256 -f alsa -ac 1 -ar 48000 -i miccap)
else
    echo "[xhome] MIC UNAVAILABLE -> streaming video with silent audio"
    AUDIO_ARGS=(-f lavfi -i anullsrc=channel_layout=mono:sample_rate=48000)
fi

# Video: 320x240 @ 5fps, encoded by the VideoCore GPU (no CPU cost).
# --intra 5 puts an IDR every 5 frames = 1s, letting the server cut clean 1s
# HLS segments with -c:v copy (no re-encode, no generation loss).
# --rotation 180 is done in the sensor readout, also free.
# A service restart can outrace the previous instance releasing the camera.
# rpicam-vid then exits with "no cameras available", ffmpeg drops the video
# stream and keeps running on the silent audio input alone -- a stream that
# looks perfectly healthy downstream but carries no picture, indefinitely.
# Wait for the old capture to let go, then confirm we can actually acquire.
for i in $(seq 1 30); do
    pgrep -x rpicam-vid >/dev/null 2>&1 || break
    [ "$i" = 1 ] && echo "[xhome] waiting for previous rpicam-vid to exit..."
    sleep 1
done
for i in $(seq 1 10); do
    if timeout 20 rpicam-hello -t 300 --nopreview >/dev/null 2>&1; then
        echo "[xhome] camera acquired OK"
        break
    fi
    echo "[xhome] camera not acquirable (attempt $i/10), retrying..."
    sleep 3
    if [ "$i" = 10 ]; then
        echo "[xhome] CAMERA UNAVAILABLE -- exiting so systemd restarts us"
        exit 1
    fi
done

rpicam-vid -t 0 \
  --width 320 --height 240 --framerate 5 --rotation 180 \
  --codec h264 --inline --intra 5 --bitrate 300000 \
  -o - \
| ffmpeg -loglevel warning \
  -fflags +nobuffer -flags +low_delay \
  -thread_queue_size 64 -use_wallclock_as_timestamps 1 \
  -analyzeduration 10M -probesize 10M -f h264 -i - \
  "${AUDIO_ARGS[@]}" \
  -c:v copy \
  -c:a aac -b:a 96k -ar 48000 \
  -vsync 1 \
  -f flv "$RTMP_URL"

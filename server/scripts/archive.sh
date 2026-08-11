#!/bin/sh
# Continuously archive the broadcast to disk in wall-clock chunks.
#
# Runs as its own container reading from MediaMTX, deliberately separate from
# the live transcoder: if archiving stalls or the disk fills, the live stream
# is unaffected.
#
# Video is copied (already H.264 from the Pi, no re-encode, no quality loss).
# Audio gets the same gain chain as the live path, so recordings are audible.
#
# Segments are named with their UTC start time, which is what lets the web
# player line a playback position up against the GPS log.
#
# MPEG-TS rather than MP4: it needs no index, so a segment is complete the
# moment it is written (survives a kill mid-write), and HLS can stitch the
# segments into ONE continuous timeline for playback -- the viewer never sees
# that the archive is split at all.

# Source stream, e.g. rtmp://ingest:1935/live?user=U&pass=P
SRC="${RTMP_SOURCE:?set RTMP_SOURCE}"
OUT=/archive/video
SEG=300          # 5 minute chunks (finer seek granularity in the playlist)

mkdir -p "$OUT"

while true; do
  echo "[archive] connecting to source..."
  ffmpeg -hide_banner -loglevel warning -y \
    -i "$SRC" \
    -c:v copy \
    -af "volume=45dB,highpass=f=80,arnndn=m=/archive/sh.rnnn:mix=0.7,volume=5dB,alimiter=limit=0.95:attack=5:release=50,aresample=async=1:min_hard_comp=0.100000:first_pts=0" \
    -c:a aac -b:a 160k -ar 48000 \
    -f segment -segment_time "$SEG" -reset_timestamps 1 -strftime 1 \
    -segment_format mpegts \
    "$OUT/%Y-%m-%d_%H-%M-%S.ts"
  echo "[archive] ffmpeg exited, retrying in 10s..."
  sleep 10
done

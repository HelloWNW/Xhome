#!/bin/sh
# Source stream, e.g. rtmp://ingest:1935/live?user=U&pass=P
SRC="${RTMP_SOURCE:?set RTMP_SOURCE}"

mkdir -p /hlsout

# Video is passed through untouched (-c:v copy): the Pi already emits H.264
# with an IDR every 1s (--intra 15 @ 15fps), so HLS can cut 1s segments on
# those keyframes. Copying avoids a GPU re-encode, its latency, and the
# quality loss of a second generation.
#
# Audio is the only thing re-encoded, which is where the gain chain lives:
#   volume     - +45dB, the I2S mic is very quiet (raw peak ~-60dBFS)
#   highpass   - drops rumble below 80Hz (handling/wind/LTE hash)
#   arnndn     - RNN denoiser. Measured on live audio it dropped the noise
#                floor 46dB (SNR 6.4 -> 32.5dB). It costs ~20dB of level,
#                hence the makeup volume immediately after it (+29dB:
#                14 to restore the level, +15 requested on top).
#   alimiter   - catches the peaks that gain would otherwise clip
#   aresample  - async=1 corrects capture/clock drift WITHOUT chunking the
#                audio (the old `-async 1` flag did chunk it). This is what
#                holds A/V sync, so it must stay.
#
# Latency: 1s segments. The list is 20 deep while the player targets 6s back --
# it must NOT sit on the oldest segment, or delete_segments removes files out
# from under it and playback stalls periodically.
while true; do
  echo "[transcode] waiting for source stream..."
  ffmpeg -y \
    -fflags +nobuffer -flags +low_delay \
    -i "$SRC" \
    -c:v copy \
    -af "volume=45dB,highpass=f=80,arnndn=m=/models/sh.rnnn:mix=0.7,volume=5dB,alimiter=limit=0.95:attack=5:release=50,aresample=async=1:min_hard_comp=0.100000:first_pts=0" \
    -c:a aac -b:a 160k -ar 48000 \
    -f hls -hls_time 1 -hls_list_size 20 \
    -hls_flags delete_segments+independent_segments+temp_file+program_date_time \
    -hls_segment_filename /hlsout/hd_%03d.ts \
    /hlsout/hd.m3u8
  echo "[transcode] ffmpeg exited, retrying in 3s..."
  sleep 3
done

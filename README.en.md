[日本語](README.md) | **English**

# Xhome — Extreme Homecoming

A self-hosted live broadcast system that streams **video, audio and GPS** from a
Raspberry Pi Zero W over a cellular link, and shows on a public website where
the walker currently is, in real time.

It broadcasts an entire long-distance walk, draws the track on a map, and keeps
everything as a recording you can replay later with the GPS position in sync.

```
┌──────────────┐   RTMP/LTE   ┌─────────────────┐   HLS    ┌──────────────┐
│ Raspberry Pi │ ───────────▶ │ Broadcast server│ ───────▶ │   Website    │
│  Zero W      │              │ (Docker + Caddy)│          │ (static host)│
│              │              │                 │          │              │
│ camera       │              │ · audio chain   │          │ · video      │
│ I2S mic      │              │ · HLS packaging │          │ · map / GPS  │
│ GPS (UART)   │              │ · archiving     │          │ · archive    │
│ LTE modem    │              │ · health checks │          │ · PWA        │
└──────────────┘              └─────────────────┘          └──────────────┘
```

---

## Features

| | |
|---|---|
| **Low latency** | 1-second HLS segments; ~4 s measured end to end |
| **A/V sync** | 12–19 ms between video and audio |
| **Audio chain** | gain, high-pass, RNN noise suppression, limiter |
| **Live map** | current position, walked track, projected route to the goal |
| **GPS-synced archive** | scrub the recording and the map follows that moment |
| **Self-healing** | watchdog restarts a stream that has wedged |
| **PWA** | installable on iPhone; notifies when the stream recovers |
| **Bilingual** | Japanese / English, auto-selected by visitor country |

---

## Layout

```
pi/                     Raspberry Pi side
  bin/
    xhome-broadcast.sh    camera + mic -> RTMP
    xhome-watchdog.sh     detect and restart a wedged stream
    xhome-lte-up.sh       LTE (QMI raw-IP) session supervisor
    xhome-miclevel.sh     live mic level, for tracing wiring faults
  systemd/              service units
  etc/                  asound.conf and config.txt additions

server/                 broadcast server (Windows + Docker)
  scripts/
    transcode.sh          audio processing + HLS packaging
    archive.sh            recording (5-minute MPEG-TS segments)
    gps-pull.ps1          pull position from the Pi's gpsd
    status-collect.ps1    per-component health
    archive-index.ps1     build playlists over the recordings
    viewers.ps1           count who is actually watching
  caddy/
    Caddyfile.example     the broadcast origin

web/                    public site (static hosting)
  public/
    index.html            the whole app, single file
    config.example.js     per-installation settings (copy and edit)
    manifest.webmanifest  PWA
    sw.js                 service worker
```

---

## Setup

### 1. Raspberry Pi

```bash
sudo apt install -y ffmpeg rpicam-apps gpsd libqmi-utils

# configuration — the only place credentials live
sudo cp xhome.env.example /etc/xhome.env
sudo chmod 600 /etc/xhome.env
sudo nano /etc/xhome.env          # set RTMP_URL

sudo cp pi/bin/*.sh /usr/local/bin/ && sudo chmod +x /usr/local/bin/xhome-*.sh
sudo cp pi/etc/asound.conf /etc/asound.conf
sudo cp pi/systemd/*.service /etc/systemd/system/
cat pi/etc/config.txt.snippet | sudo tee -a /boot/firmware/config.txt

sudo systemctl daemon-reload
sudo systemctl enable --now xhome-broadcast xhome-watchdog
sudo reboot
```

### 2. Broadcast server

Needs Docker and an RTMP ingest (MediaMTX or similar).

```powershell
setx RTMP_SOURCE "rtmp://ingest:1935/live?user=USER&pass=PASSWORD" /M
setx APP_DIR     "C:\broadcast" /M
setx ARCHIVE_DIR "D:\xhome" /M

# transcoder (audio chain + HLS)
docker run -d --name xhomeTranscodeWorker --restart unless-stopped `
  -v C:\broadcast:/app -v C:\broadcast\hlsout:/hlsout -v C:\broadcast\models:/models `
  --entrypoint sh jrottenberg/ffmpeg:8.1-nvidia2404 /app/transcode.sh

# archiver
docker run -d --name xhomeArchiver --restart unless-stopped `
  -v C:\broadcast:/app -v D:\xhome:/archive `
  --entrypoint sh jrottenberg/ffmpeg:8.1-nvidia2404 /app/archive.sh
```

Import `server/caddy/Caddyfile.example` into your Caddyfile, and register
`gps-pull.ps1`, `status-collect.ps1`, `archive-index.ps1` and `viewers.ps1`
as scheduled tasks that run at startup.

Fetch the RNNoise model separately:

```bash
curl -o models/sh.rnnn https://raw.githubusercontent.com/GregorR/rnnoise-models/master/somnolent-hogwash-2018-09-01/sh.rnnn
```

### 3. Website

```bash
cp web/public/config.example.js web/public/config.js
# edit config.js: origin URL, start/goal coordinates, names
```

Deploy `web/public` to any static host (Cloudflare Pages, etc.).

---

## Configuration

Every installation-specific value lives **outside the code**.

| Where | What |
|---|---|
| `/etc/xhome.env` | the Pi's RTMP destination and credentials |
| environment (server) | source URL, directories, Pi address |
| `web/public/config.js` | origin URL, coordinates, place names, passcode hash |

`passSha256` in `config.js` **only hides the UI** — it does not protect the
stream URLs, which remain publicly fetchable. If you need real protection, put
authentication in front of the origin (Caddy `basic_auth`, Cloudflare Access).

---

## Engineering notes

Things that had to be learned the hard way to get this stable on very small
hardware.

### The ALSA period size was the cause of the audio dropouts

At 48 kHz the default `period_size 32` fires a DMA interrupt roughly **1500
times a second**, saturating the Pi Zero's single core. Moving to 1024 via
`dsnoop` drops that to ~47/sec and costs only ~21 ms of latency.

### `-thread_queue_size` is measured in seconds

On an ALSA input this becomes buffered seconds. 2048 produced **43.7 seconds of
permanent latency**. 256 is about the practical floor.

### MBIM is unusable on the Pi Zero

`cdc_ncm` aggregation trips the `dwc_otg` TX watchdog and gives 100 % packet
loss. QMI raw-IP is stable.

### A stream dies while every process stays alive

When the RTMP push stalls, ffmpeg blocks on write and the camera blocks writing
to stdout. Both processes stay alive, so systemd sees a healthy service while
the stream is frozen. The watchdog therefore checks **bytes actually leaving
the interface** and **whether the capture process still exists**.

### "The mic works" cannot be proven by opening the device

With the I2S data line disconnected, a capture still succeeds — and returns a
perfectly valid recording of pure zeros. The pre-flight check has to verify
that **non-zero samples exist**.

### A stream with no picture looks perfectly healthy

If the camera fails to start, ffmpeg keeps publishing the audio track alone.
That is ~100 kbps, comfortably above any bitrate floor, so bitrate monitoring
can never catch it. The capture process itself has to be watched.

---

## Hardware

- Raspberry Pi Zero W (ARMv6, single core, 512 MB)
- Raspberry Pi Camera Module (imx219)
- I2S MEMS microphone (via the `googlevoicehat-soundcard` overlay)
- GPS module (UART / NMEA)
- LTE modem with QMI support (optional)
- Broadcast server: anything that runs Docker
- Website: any static host

---

## License

MIT — see [LICENSE](LICENSE).

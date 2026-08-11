#!/bin/bash
# Live microphone level, for locating an intermittent I2S connection.
#
# The mic fault is intermittent: it produces real audio for minutes, then pure
# digital zeros, with no reboot in between. That points at a physical joint
# rather than software, and the way to find a bad joint is to watch the level
# while gently moving each wire -- the one that kills or restores the signal is
# the bad one.
#
# Reads through the shared dsnoop device, so this runs safely alongside the
# live broadcast without taking the mic away from it.
#
# Usage:  xhome-miclevel.sh          (Ctrl-C to stop)

set -u

if [ -t 1 ]; then
    # Interactive: arecord's own VU meter, which costs almost no CPU.
    echo "Watch the bar. Wiggle each mic wire in turn: DATA (pin 38), 3V3, GND,"
    echo "BCLK (pin 12), LRCLK (pin 35). Ctrl-C to stop."
    exec arecord -D miccap -f S16_LE -c 1 -r 48000 -V mono -t raw >/dev/null
fi

# Non-interactive: print one numeric line per second instead.
arecord -D miccap -f S16_LE -c 1 -r 48000 -t raw 2>/dev/null \
| python3 -u -c '
import sys, math, struct
CH = 48000 * 2
while True:
    b = sys.stdin.buffer.read(CH)
    if not b or len(b) < CH: break
    v = struct.unpack("<%dh" % (len(b)//2), b)
    peak = max(abs(x) for x in v)
    rms = math.sqrt(sum(x*x for x in v)/len(v)) or 1e-9
    db = 20*math.log10(rms/32768)
    bar = "#" * max(0, min(40, int((db+70)/70*40)))
    print(f"{db:7.1f} dB  peak {peak:6d}  {'"'"'SILENT'"'"' if peak==0 else bar}")
'

#!/usr/bin/env bash
# ----------------------------------------------------------------------
# preflight.sh — verify the upload port is free before flashing.
# ----------------------------------------------------------------------
# arduino-cli's 1200-baud touch needs exclusive access to the port to
# trigger bootloader entry. If anything else holds the port (Serial
# Monitor, screen, minicom, cu, picocom, stray cat, etc.) the touch
# silently fails and bossac reports "No device found" — the most
# common bench-iteration failure mode for the ClearCore.
#
# Exit codes:
#   0 — port is free, safe to upload
#   1 — port is held by another process (printed to stderr)
#   2 — port does not exist (device unplugged?)
# ----------------------------------------------------------------------

set -euo pipefail

PORT="${1:-/dev/ttyACM0}"

if [[ ! -e "$PORT" ]]; then
    echo "preflight: $PORT does not exist (device unplugged?)" >&2
    exit 2
fi

HOLDERS="$(lsof -t "$PORT" 2>/dev/null || true)"

if [[ -n "$HOLDERS" ]]; then
    {
        echo "preflight: $PORT is held by another process:"
        echo
        ps -p $HOLDERS -o pid,comm,args 2>/dev/null || ps -p "$HOLDERS" 2>/dev/null
        echo
        echo "Close it before uploading. Common offenders:"
        echo "  serial-monitor   — Arduino IDE 2 Serial Monitor (close the panel / hit Disconnect)"
        echo "  screen / cu / minicom / picocom — old terminal session"
        echo "  cat              — stray 'cat /dev/ttyACM0' left running"
    } >&2
    exit 1
fi

echo "preflight: $PORT is free."

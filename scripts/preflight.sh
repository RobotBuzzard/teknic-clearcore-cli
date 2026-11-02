#!/usr/bin/env bash
# ----------------------------------------------------------------------
# preflight.sh — verify no process of yours holds the upload port.
# ----------------------------------------------------------------------
# The 1200-baud touch (flash.sh's stty, or arduino-cli upload's own)
# resets the board into the bootloader only when DTR drops while the line
# rate is 1200, and Linux drops DTR only on the last close of the port.
# If anything else holds the port open (Serial Monitor, screen, minicom,
# cu, picocom, a stray cat), the touch does nothing or its open fails.
# flash.sh then times out waiting for the bootloader, and a raw
# arduino-cli upload fails with "Failed to open port at 1200bps" / "No
# device found". This is the most common bench-iteration failure mode.
# Note: lsof run as a normal user only sees your own processes.
#
# Exit codes:
#   0 — port is free, safe to upload
#   1 — port is held by another process (printed to stderr), or lsof
#       is not installed
#   2 — port does not exist (device unplugged?)
# ----------------------------------------------------------------------

set -euo pipefail

PORT="${1:-/dev/ttyACM0}"

if ! command -v lsof &> /dev/null; then
    # Without lsof we cannot tell whether the port is free, and an
    # empty result would wrongly look like "free".
    echo "preflight: 'lsof' not found — install it (scripts/install-toolchain.sh does this)" >&2
    exit 1
fi

if [[ ! -e "$PORT" ]]; then
    echo "preflight: $PORT does not exist (device unplugged?)" >&2
    exit 2
fi

HOLDERS="$(lsof -t "$PORT" 2>/dev/null || true)"

if [[ -n "$HOLDERS" ]]; then
    {
        echo "preflight: $PORT is held by another process:"
        echo
        ps -o pid,comm,args -p "${HOLDERS//$'\n'/,}" 2>/dev/null || echo "  pids: ${HOLDERS//$'\n'/ }"
        echo
        echo "Close it before uploading. Common offenders:"
        echo "  serial-monitor   — Arduino IDE 2 Serial Monitor (close the panel / hit Disconnect)"
        echo "  screen / cu / minicom / picocom — old terminal session"
        echo "  cat              — stray 'cat /dev/ttyACM0' left running"
        echo "  sudo screen/minicom — root-owned, invisible to this check without sudo"
    } >&2
    exit 1
fi

echo "preflight: $PORT is free (no process of yours holds it; root-owned holders need: sudo lsof $PORT)."

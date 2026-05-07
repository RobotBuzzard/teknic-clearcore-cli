#!/usr/bin/env bash
# ----------------------------------------------------------------------
# flash.sh — robust compile-and-upload for the Teknic ClearCore.
# ----------------------------------------------------------------------
# Wraps arduino-cli compile + a bossac-direct upload with explicit
# state detection, settle delays, and bounded retry. Designed to match
# Arduino IDE 2's reliability without leaving the device stuck in
# bootloader on transient failures.
#
# Usage:  flash.sh <sketch_dir> [port]
#
# Strategy:
#   1. Preflight (port not held by Serial Monitor / screen / etc.)
#   2. Compile to a clean build dir with arduino-cli
#   3. Determine device state via USB VID/PID
#       2890:8022 = application running
#       2890:0022 = bootloader waiting
#       (none)    = unplugged → bail with clear message
#   4. If in app mode: trigger bootloader entry ourselves with a
#      controlled 1200-baud touch (Python's pyserial), then poll for
#      the bootloader USB descriptor and let CDC settle
#   5. Call bossac directly — no -a flag (no second touch — that's
#      what races against the freshly-enumerated CDC and produces
#      "Set binary mode / No device found")
#   6. Retry bossac up to N times with backoff. The bootloader has
#      no timeout; it patiently waits, so retry is safe and converges
#   7. Verify the device returns to PID 8022 (running new firmware)
#
# Exit codes:
#   0  success
#   1  preflight / compile failure
#   2  device not detected
#   3  bootloader entry failed
#   4  bossac flash failed after retries
#   5  device didn't return to app mode after flash
# ----------------------------------------------------------------------

set -euo pipefail

# -------- config --------
SKETCH="${1:-}"
PORT="${2:-/dev/ttyACM0}"
PORT_NAME="$(basename "$PORT")"
FQBN="ClearCore:sam:clearcore"
OFFSET="0x4000"
BUILD_DIR="${TMPDIR:-/tmp}/cc-flash-build"
BOSSAC_RETRIES=3
BOSSAC_RETRY_DELAY=2
BL_POLL_TIMEOUT=10
APP_RETURN_TIMEOUT=10

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"

if [[ -z "$SKETCH" ]]; then
    echo "usage: $(basename "$0") <sketch_dir> [port]" >&2
    exit 1
fi
if [[ ! -d "$SKETCH" ]]; then
    echo "flash: sketch dir not found: $SKETCH" >&2
    exit 1
fi

# -------- helpers --------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m==> OK:\033[0m %s\n' "$*"; }
err()  { printf '\033[1;31m==> ERR:\033[0m %s\n' "$*" >&2; }

cc_pid() {
    # Returns the ClearCore's current USB PID (8022 app, 0022 boot, empty if unplugged)
    lsusb 2>/dev/null | awk '/2890:/ { split($6, a, ":"); print a[2]; exit }'
}

find_bossac() {
    local b
    b="$(find "${HOME}/.arduino15/packages/arduino/tools/bossac" -name bossac -type f -executable 2>/dev/null | sort -V | tail -1)"
    if [[ -z "$b" ]]; then
        err "bossac not found in ~/.arduino15/packages/arduino/tools/bossac/*"
        err "run scripts/install-toolchain.sh first"
        exit 1
    fi
    echo "$b"
}

trigger_bootloader() {
    log "Triggering bootloader (1200-baud touch on $PORT)..."
    python3 - <<PYEOF || true
import serial, time
try:
    s = serial.Serial("$PORT", 1200)
    time.sleep(0.2)
    s.close()
except Exception:
    pass
PYEOF

    local i
    for i in $(seq 1 $((BL_POLL_TIMEOUT * 5))); do
        if [[ "$(cc_pid)" == "0022" ]]; then
            log "Bootloader detected (PID 0022) after $((i * 200))ms"
            sleep 1   # extra CDC settle window — what the IDE does implicitly
            return 0
        fi
        sleep 0.2
    done
    err "Bootloader entry timed out after ${BL_POLL_TIMEOUT}s"
    return 1
}

flash_with_bossac() {
    local bossac="$1"
    local bin="$2"
    local attempt
    for attempt in $(seq 1 $BOSSAC_RETRIES); do
        if [[ $attempt -gt 1 ]]; then
            log "bossac retry $attempt/$BOSSAC_RETRIES (waiting ${BOSSAC_RETRY_DELAY}s for CDC to settle)..."
            sleep $BOSSAC_RETRY_DELAY
        fi
        # No -a (don't let bossac do its own 1200-baud touch — we did it
        # already and a second touch on an already-bootloader device
        # races against the CDC re-enumeration, producing the classic
        # "Set binary mode / No device found" failure).
        if "$bossac" -i -d --port="$PORT_NAME" -U -e -w -v --offset="$OFFSET" "$bin" -R 2>&1 | tee /tmp/cc-flash-bossac.log | grep -q "Verify successful"; then
            return 0
        fi
        if grep -q "Verify successful" /tmp/cc-flash-bossac.log; then
            return 0
        fi
    done
    err "bossac failed after $BOSSAC_RETRIES attempts. Last 15 lines of bossac output:"
    tail -15 /tmp/cc-flash-bossac.log >&2
    return 1
}

wait_for_app_mode() {
    local i
    for i in $(seq 1 $((APP_RETURN_TIMEOUT * 5))); do
        if [[ "$(cc_pid)" == "8022" ]]; then
            log "Device returned to application mode (PID 8022) after $((i * 200))ms"
            return 0
        fi
        sleep 0.2
    done
    return 1
}

# -------- run --------

# Step 1: preflight
"${SCRIPT_DIR}/preflight.sh" "$PORT" || exit 1

# Step 2: compile
log "Compiling $SKETCH..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"
arduino-cli compile --fqbn "$FQBN" --output-dir "$BUILD_DIR" "$SKETCH" || exit 1

# Find the .bin (arduino-cli names it after the .ino's basename)
SKETCH_NAME="$(basename "$SKETCH")"
BIN="$BUILD_DIR/${SKETCH_NAME}.ino.bin"
if [[ ! -f "$BIN" ]]; then
    BIN="$(find "$BUILD_DIR" -name "*.ino.bin" -type f | head -1)"
fi
if [[ ! -f "$BIN" ]]; then
    err "Compiled .bin not found in $BUILD_DIR"
    exit 1
fi

BOSSAC="$(find_bossac)"
log "Using bossac: $BOSSAC"
log "Binary: $BIN ($(stat -c%s "$BIN") bytes)"

# Step 3: determine device state
case "$(cc_pid)" in
    8022)
        # App mode → trigger bootloader
        trigger_bootloader || exit 3
        ;;
    0022)
        log "Device is already in bootloader (PID 0022) — skipping touch"
        sleep 1   # let any in-flight CDC activity drain
        ;;
    "")
        err "ClearCore not detected on USB. Plug in the cable and retry."
        exit 2
        ;;
    *)
        err "Unknown ClearCore USB PID: $(cc_pid). Expected 8022 or 0022."
        exit 2
        ;;
esac

# Step 4: flash
flash_with_bossac "$BOSSAC" "$BIN" || exit 4

# Step 5: verify
log "Waiting for device to return to application mode..."
wait_for_app_mode || {
    err "Device didn't return to PID 8022 after flash. Bossac reported success but device may not be running new firmware."
    exit 5
}

ok "Flash complete."

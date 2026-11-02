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
#   1. Preflight (port not held by Serial Monitor / screen / etc.),
#      then the quick device checks (one board, port permission,
#      board present) so those fail before the slow compile
#   2. Compile to a clean build dir with arduino-cli
#   3. Determine device state via USB VID/PID
#       2890:8022 = application running
#       2890:0022 = bootloader waiting
#       (none)    = unplugged → bail with clear message
#   4. If in app mode: trigger bootloader entry ourselves with a
#      controlled 1200-baud touch (stty: set 1200 baud, drop DTR on
#      close), then poll for the bootloader USB descriptor and let
#      CDC settle
#   5. Call bossac directly — no -a flag (no second touch — that's
#      what races against the freshly-enumerated CDC and produces
#      "Set binary mode / No device found") and no -R (see 6).
#      Retry it up to N times with backoff: a bootloader entered on
#      purpose (1200-baud touch, double-tap) has no timeout; it
#      patiently waits, so retry is safe and converges
#   6. Start the application with boot-app.sh instead of bossac's -R.
#      After a plain reset the bootloader waits a moment for a second
#      reset (its double-tap detection) before starting the
#      application; boot-app.sh writes the bootloader's own "start the
#      application now" word first, so it starts at once. See "How the
#      bootloader decides" in the README
#   7. Verify the device returns to PID 8022 (running new firmware).
#      If it is still in the bootloader, send the start command again:
#      that's safe to repeat
#
# Requires: arduino-cli, lsusb (usbutils), stty (coreutils), lsof.
# scripts/install-toolchain.sh installs them. Linux only (WSL2 works).
#
# Timeouts can be raised for slow re-enumeration (e.g. WSL + usbipd):
#   CC_BL_POLL_TIMEOUT=20 CC_APP_RETURN_TIMEOUT=20 flash.sh <sketch_dir>
#
# Exit codes:
#   0  success
#   1  preflight / compile / missing-dependency failure, or no
#      permission to open the port (see 'dialout' in the README)
#   2  device not detected (or more than one ClearCore connected)
#   3  bootloader entry failed (on WSL: is bootloader mode, 2890:0022,
#      shared with usbipd?)
#   4  bossac flash failed after retries
#   5  device didn't return to app mode after flash (on WSL: is app
#      mode, 2890:8022, shared with usbipd?)
# ----------------------------------------------------------------------

set -euo pipefail

# -------- config --------
SKETCH="${1:-}"
PORT="${2:-/dev/ttyACM0}"
PORT_NAME="$(basename "$PORT")"
FQBN="ClearCore:sam:clearcore"
OFFSET="0x4000"
CC_TMP="${TMPDIR:-/tmp}/cc-flash-$(id -u)"
BUILD_DIR="$CC_TMP/build"
BOSSAC_LOG="$CC_TMP/bossac.log"
BOSSAC_RETRIES=3
BOSSAC_RETRY_DELAY=2
BL_POLL_TIMEOUT="${CC_BL_POLL_TIMEOUT:-10}"
APP_RETURN_TIMEOUT="${CC_APP_RETURN_TIMEOUT:-10}"

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

require_cmd() {
    # require_cmd <command> <package that provides it>
    if ! command -v "$1" &> /dev/null; then
        err "'$1' not found — install $2 (scripts/install-toolchain.sh does this)"
        exit 1
    fi
}

cc_count() {
    # Number of ClearCores on USB (app or bootloader mode)
    lsusb 2>/dev/null | grep -c ' 2890:' || true
}

cc_pid() {
    # Returns the ClearCore's current USB PID (8022 app, 0022 boot, empty if unplugged)
    lsusb 2>/dev/null | awk '/ 2890:/ { split($6, a, ":"); print a[2]; exit }' || true
}

is_wsl() {
    grep -qi microsoft /proc/version 2>/dev/null
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
    # The firmware reboots to the bootloader when DTR drops while the
    # line rate is 1200 (libClearCore UsbManager::CBLineStateChanged).
    # stty opens the port (DTR up), sets 1200 baud, and closes it —
    # with hupcl set, the close drops DTR.
    if ! stty -F "$PORT" 1200 hupcl 2>/dev/null; then
        err "Could not open $PORT at 1200 baud (permissions? see 'dialout' in the README;"
        err "if the sketch is hung, press RESET twice quickly and re-run flash.sh)"
        return 1
    fi

    local i
    for i in $(seq 1 $((BL_POLL_TIMEOUT * 5))); do
        if [[ "$(cc_pid)" == "0022" ]]; then
            log "Bootloader detected (PID 0022) after $((i * 200))ms"
            sleep 1   # extra CDC settle window — what the IDE does implicitly
            return 0
        fi
        sleep 0.2
    done
    err "Bootloader entry timed out after ${BL_POLL_TIMEOUT}s (the board never showed up as 2890:0022)."
    err "If the running sketch is hung or crashed, press RESET twice quickly (the board stays in the"
    err "bootloader), then re-run flash.sh; it skips the touch when the board is already in the bootloader."
    if is_wsl; then
        err "On WSL: is bootloader mode (2890:0022) shared, and is 'usbipd attach --wsl --busid <BUSID> --auto-attach'"
        err "still running? If re-attach is just slow, raise CC_BL_POLL_TIMEOUT (see 'WSL2' in the README)."
        err "Once the board is attached in the bootloader, re-run flash.sh or start the application with scripts/boot-app.sh."
    fi
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
        #
        # No -R either: step 6 starts the application without the
        # bootloader's double-tap wait.
        #
        # Run bossac to completion and check its log afterwards; the
        # last lines are shown if it fails.
        rm -f "$BOSSAC_LOG"
        "$bossac" -i -d --port="$PORT_NAME" -U -e -w -v --offset="$OFFSET" "$bin" \
            > "$BOSSAC_LOG" 2>&1 || true
        if grep -q "Verify successful" "$BOSSAC_LOG"; then
            return 0
        fi
    done
    err "bossac failed after $BOSSAC_RETRIES attempts. Last 15 lines of bossac output:"
    tail -15 "$BOSSAC_LOG" >&2
    return 1
}

boot_app() {
    # Leave the bootloader into the new application at once, without
    # the double-tap wait (see scripts/boot-app.sh).
    sleep 0.5   # let bossac's close settle before reopening the port
    "${SCRIPT_DIR}/boot-app.sh" "$PORT"
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

check_port_access() {
    # Without read/write access the 1200-baud touch and bossac fail with
    # misleading messages ("No device found"), so say it plainly.
    if [[ -e "$PORT" && ( ! -r "$PORT" || ! -w "$PORT" ) ]]; then
        err "No permission to open $PORT; add yourself to the 'dialout' group (README step 4a)."
        exit 1
    fi
}

for v in BL_POLL_TIMEOUT APP_RETURN_TIMEOUT; do
    [[ "${!v}" =~ ^[1-9][0-9]*$ ]] || { err "CC_${v} must be a whole number of seconds (got '${!v}')"; exit 1; }
done

# -------- run --------

require_cmd arduino-cli "arduino-cli"
require_cmd lsusb "usbutils"
require_cmd stty "coreutils"
require_cmd lsof "lsof"

# Step 1: preflight. A missing port (preflight exit 2) isn't fatal here:
# the device check below reports a missing device, with the usbipd hint on WSL.
preflight_rc=0
"${SCRIPT_DIR}/preflight.sh" "$PORT" || preflight_rc=$?
if [[ $preflight_rc -ne 0 && $preflight_rc -ne 2 ]]; then
    exit 1
fi

# Cheap device checks before the slow compile.
if [[ "$(cc_count)" -gt 1 ]]; then
    err "More than one ClearCore is connected. Unplug all but the one on $PORT and retry."
    exit 2
fi
check_port_access
if [[ -z "$(cc_pid)" ]]; then
    err "ClearCore not detected on USB. Plug in the cable and retry (or press RESET twice quickly if the sketch doesn't start USB)."
    if is_wsl; then
        err "On WSL the device must be attached with usbipd-win — see 'WSL2' in the README."
    fi
    exit 2
fi

# Step 2: compile
log "Compiling $SKETCH..."
mkdir -p "$CC_TMP"
if [[ ! -w "$CC_TMP" ]]; then
    err "$CC_TMP is not writable (left by another user or sudo?). Remove it or set TMPDIR."
    exit 1
fi
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

# Steps 3-4: determine device state; enter the bootloader if needed
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
        if is_wsl; then
            err "On WSL the device must be attached with usbipd-win — see 'WSL2' in the README."
        fi
        exit 2
        ;;
    *)
        err "Unknown ClearCore USB PID: $(cc_pid). Expected 8022 or 0022."
        exit 2
        ;;
esac

# Step 5: flash
flash_with_bossac "$BOSSAC" "$BIN" || exit 4

# Step 6: start the application at once (no double-tap wait). If this
# fails, step 7 still checks where the board is and tries again.
log "Starting the application..."
boot_app || err "The start command didn't go through; checking the device..."

# Step 7: verify
log "Waiting for device to return to application mode..."
if ! wait_for_app_mode; then
    pid="$(cc_pid)"
    if [[ "$pid" == "0022" && -c "$PORT" ]]; then
        # Still in the bootloader. Sending the start command again is safe.
        log "Still in the bootloader — sending the start command again..."
        if boot_app && wait_for_app_mode; then
            ok "Flash complete."
            exit 0
        fi
        err "Device is still in the bootloader. The new firmware is written and verified;"
        err "start it with scripts/boot-app.sh, or power-cycle the ClearCore."
    elif [[ -z "$pid" ]] && is_wsl; then
        err "The ClearCore left the bootloader but isn't visible in WSL; the new firmware is most"
        err "likely running. Check that application mode (2890:8022) is shared and attached"
        err "(see 'WSL2' in the README)."
    else
        err "Device didn't return to PID 8022 after flash (USB PID now: ${pid:-none}). Bossac"
        err "reported success, but the device may not be running the new firmware."
    fi
    exit 5
fi

ok "Flash complete."

#!/usr/bin/env bash
# ----------------------------------------------------------------------
# boot-app.sh — leave the ClearCore bootloader and start the application
# at once. No power cycle, no double-tap wait.
# ----------------------------------------------------------------------
# Usage:  boot-app.sh [port]        (default /dev/ttyACM0)
#
# Why: after a plain reset (bossac's -R included) the ClearCore
# bootloader doesn't start the application straight away. For an Arduino
# sketch it first waits a moment for a second reset (its RESET
# double-tap detection), and a reset in that wait keeps it in the
# bootloader. This script skips that wait. It also gets a board that is
# sitting in the bootloader with good firmware back into the application
# without a power cycle.
#
# How: the bootloader (UF2 Bootloader v2.3.1-Teknic.4, Teknic's fork of
# Microsoft's uf2-samdx1) clears the last word of RAM (0x2002FFFC) and
# starts the application at once when that word holds 0xF02669EF,
# uf2-samdx1's DBL_TAP_MAGIC_QUICK_BOOT. The bootloader's own
# resetIntoApp() works the same way. This script checks that the port is
# a ClearCore bootloader answering SAM-BA, writes that word, then
# requests a system reset (AIRCR.SYSRESETREQ).
# See "How the bootloader decides" in the README.
#
# Exit codes:
#   0  start requested, or the application is already running
#   1  no permission to open the port, the port is held by another
#      process, or no SAM-BA answer
#   2  the port doesn't exist, no ClearCore on it, or it vanished while opening it
# ----------------------------------------------------------------------

set -euo pipefail

PORT="${1:-/dev/ttyACM0}"

QUICK_BOOT_ADDR="2002FFFC"      # uf2-samdx1 DBL_TAP_PTR: last word of RAM
QUICK_BOOT_MAGIC="F02669EF"     # uf2-samdx1 DBL_TAP_MAGIC_QUICK_BOOT
AIRCR_ADDR="E000ED0C"
AIRCR_SYSRESETREQ="05FA0004"

if [[ ! -c "$PORT" ]]; then
    echo "boot-app: $PORT doesn't exist; is the ClearCore connected?" >&2
    if grep -qi microsoft /proc/version 2>/dev/null; then
        echo "boot-app: on WSL, attach it with usbipd-win (see 'WSL2' in the README)" >&2
    fi
    exit 2
fi

# Which USB device owns the port? sysfs: tty -> USB interface -> device.
# $PORT may be a symlink (/dev/clearcore-boot, /dev/serial/by-id/...), and
# sysfs is named after the real tty.
real_port="$(readlink -f -- "$PORT")"
usb_dir="$(readlink -f "/sys/class/tty/$(basename "$real_port")/device/..")" || usb_dir=""
vid="$(cat "$usb_dir/idVendor" 2>/dev/null || true)"
pid="$(cat "$usb_dir/idProduct" 2>/dev/null || true)"

case "$vid:$pid" in
    2890:8022)
        echo "boot-app: the application is already running ($PORT is 2890:8022)"
        exit 0
        ;;
    2890:0022)
        ;;
    *)
        echo "boot-app: $PORT isn't a ClearCore bootloader (USB ID '$vid:$pid')" >&2
        exit 2
        ;;
esac

if [[ ! -r "$PORT" || ! -w "$PORT" ]]; then
    echo "boot-app: no permission to open $PORT; add yourself to 'dialout' (README step 4a)" >&2
    exit 1
fi

# Another program on the port (an upload, a serial monitor) would compete
# for the reply, or be cut off by the reset. Skipped when lsof is missing.
if command -v lsof >/dev/null 2>&1 && holders="$(lsof -t "$PORT" 2>/dev/null)" && [[ -n "$holders" ]]; then
    echo "boot-app: $PORT is held by another process (PID ${holders//$'\n'/ }); close it first" >&2
    exit 1
fi

# Raw bytes, and don't wait for carrier. The bootloader ignores the baud
# rate.
stty -F "$PORT" raw -echo clocal 921600 || {
    echo "boot-app: can't configure $PORT (did the board re-enumerate?); try again" >&2
    exit 2
}
exec 3<>"$PORT" || {
    echo "boot-app: can't open $PORT (did the board re-enumerate?); try again" >&2
    exit 2
}

# Drop anything already waiting, then send N# and ask the monitor for its
# version (V#), which it answers with a line like "v1.1 [Arduino:XYZ]
# ...\n\r". This bootloader treats N# (bossac's opening command) as a
# no-op and doesn't answer it, but right after a bossac session a V# sent
# on its own often went unanswered; with N# first it is answered. One
# retry, then give up without writing anything.
read -r -t 0.2 -N 256 -u 3 _ || true
reply=""
for _ in 1 2; do
    printf 'N#' >&3
    sleep 0.05
    printf 'V#' >&3
    if IFS= read -r -t 2 -d $'\r' -u 3 reply && [[ "$reply" == v* ]]; then
        break
    fi
    reply=""
done
if [[ -z "$reply" ]]; then
    echo "boot-app: no SAM-BA answer on $PORT; nothing written (is another program reading $PORT?)" >&2
    exit 1
fi

printf 'W%s,%s#' "$QUICK_BOOT_ADDR" "$QUICK_BOOT_MAGIC" >&3
sleep 0.1
# The device resets while we're still talking to it, so this write (and
# the close) may fail; ignore errors, as bossac does.
printf 'W%s,%s#' "$AIRCR_ADDR" "$AIRCR_SYSRESETREQ" >&3 2>/dev/null || true
exec 3>&-

echo "boot-app: asked the bootloader to start the application"

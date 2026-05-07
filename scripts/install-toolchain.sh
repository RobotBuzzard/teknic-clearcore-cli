#!/usr/bin/env bash
# ----------------------------------------------------------------------
# install-toolchain.sh — set up the Teknic ClearCore CLI toolchain.
# ----------------------------------------------------------------------
# Idempotent: re-running is safe. Prompts for sudo only at the steps
# that actually need it (group add, ModemManager mask, udev rule).
# ----------------------------------------------------------------------

set -euo pipefail

CLEARCORE_INDEX_URL="https://www.teknic.com/files/downloads/package_clearcore_index.json"
ARDUINO_CLI_BINDIR="${ARDUINO_CLI_BINDIR:-$HOME/bin}"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/.." &> /dev/null && pwd)"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> WARN:\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m==> OK:\033[0m %s\n' "$*"; }

# ----------------------------------------------------------------------
# 1. arduino-cli
# ----------------------------------------------------------------------
if [[ -x "$ARDUINO_CLI_BINDIR/arduino-cli" ]]; then
    ok "arduino-cli already installed at $ARDUINO_CLI_BINDIR/arduino-cli"
else
    log "Installing arduino-cli into $ARDUINO_CLI_BINDIR"
    mkdir -p "$ARDUINO_CLI_BINDIR"
    curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh \
        | BINDIR="$ARDUINO_CLI_BINDIR" sh
fi
export PATH="$ARDUINO_CLI_BINDIR:$PATH"
arduino-cli version

# ----------------------------------------------------------------------
# 2. arduino-cli config + Teknic board manager URL
# ----------------------------------------------------------------------
if [[ ! -f "$HOME/.arduino15/arduino-cli.yaml" ]]; then
    log "Initialising arduino-cli config"
    arduino-cli config init
fi

if arduino-cli config dump | grep -qF "$CLEARCORE_INDEX_URL"; then
    ok "Teknic board manager URL already configured"
else
    log "Adding Teknic board manager URL"
    arduino-cli config add board_manager.additional_urls "$CLEARCORE_INDEX_URL"
fi

log "Updating board index"
arduino-cli core update-index

# ----------------------------------------------------------------------
# 3. ClearCore platform
# ----------------------------------------------------------------------
if arduino-cli core list | grep -q "^ClearCore:sam"; then
    ok "ClearCore:sam platform already installed"
else
    log "Installing ClearCore:sam platform (gcc + bossac + CMSIS)"
    arduino-cli core install ClearCore:sam
fi

arduino-cli board listall ClearCore || true

# ----------------------------------------------------------------------
# 4. Linux gotchas
# ----------------------------------------------------------------------
if [[ "$(uname)" == "Linux" ]]; then

    # 4a. dialout group
    if id -nG "$USER" | tr ' ' '\n' | grep -qx dialout; then
        ok "User $USER already in dialout"
    else
        log "Adding $USER to dialout group (sudo)"
        sudo usermod -aG dialout "$USER"
        warn "Log out and back in (or run 'newgrp dialout') for dialout to take effect"
    fi

    # 4b. ModemManager
    if systemctl is-enabled ModemManager &> /dev/null; then
        log "Masking ModemManager (sudo) — it interferes with bossac uploads"
        sudo systemctl mask --now ModemManager
    else
        ok "ModemManager already masked or absent"
    fi

    # 4c. udev rule
    UDEV_SRC="$REPO_ROOT/udev/99-teknic-clearcore.rules"
    UDEV_DST="/etc/udev/rules.d/99-teknic-clearcore.rules"
    if [[ -f "$UDEV_SRC" ]]; then
        if [[ -f "$UDEV_DST" ]] && cmp -s "$UDEV_SRC" "$UDEV_DST"; then
            ok "udev rule already installed and current"
        else
            log "Installing udev rule (sudo)"
            sudo cp "$UDEV_SRC" "$UDEV_DST"
            sudo udevadm control --reload-rules
            sudo udevadm trigger
        fi
    else
        warn "udev rule not found at $UDEV_SRC — skipping"
    fi
fi

log "Done."
echo
echo "Smoke test (recommended):"
echo "  $REPO_ROOT/scripts/flash.sh $REPO_ROOT/examples/BlinkLED"
echo
echo "flash.sh wraps preflight + compile + a state-aware bossac upload"
echo "with bounded retries. The on-board USR LED should blink at 1 Hz"
echo "after a successful flash."

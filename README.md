# Teknic ClearCore — CLI Toolchain & Flashing Guide

Compile and flash sketches for the [Teknic ClearCore](https://www.teknic.com/products/io-motion-controller-clearcore/) industrial controller from a Linux command line. Project-agnostic — applies to any sketch you'd write for the platform.

This guide reflects what actually works on a clean Ubuntu 24.04 install in 2026 with `ClearCore:sam@1.7.1`. Notes for macOS/Windows where the path diverges.

---

## What this is

The ClearCore is a SAME53N19A-based motion controller (Cortex-M4F, 120 MHz, 512 KB flash, 192 KB RAM). Teknic ships an Arduino board package, so `arduino-cli` + the standard `arm-none-eabi-gcc` + `bossac` toolchain compiles and flashes it like any other SAMD-family board — **once you've cleared two Linux gotchas that bit us hard**: ModemManager grabbing the bootloader port, and udev probing the bootloader's mass-storage interface.

Both are documented below with the exact symptoms.

---

## Hardware reference

| Property | Value |
|---|---|
| MCU | Microchip SAME53N19A (Cortex-M4F, FPU, 120 MHz) |
| Flash | 512 KB total; sketch space `0x4000`–`0x80000` (496 KB after bootloader) |
| RAM | 192 KB |
| USB VID | `2890` (Teknic) |
| USB PID — application | `8022` |
| USB PID — bootloader | `0022` |
| Bootloader interfaces | CDC ACM (SAM-BA), USB Mass Storage (UF2-style), HID |
| Programming | USB-C on the front, exposes as `/dev/ttyACM*` |

The bootloader is reached via the **1200-baud touch reset** — open `/dev/ttyACM0` at 1200 baud and close it; the running firmware sees the magic baud and reboots into the bootloader, which re-enumerates as PID `0022`. `arduino-cli upload` and the Arduino IDE handle this automatically; the rest of this guide assumes it.

---

## Quick install (Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/RobotBuzzard/teknic-clearcore-cli/main/scripts/install-toolchain.sh | bash
```

Or run [`scripts/install-toolchain.sh`](scripts/install-toolchain.sh) from a clone — it's idempotent, runs the steps below, asks for `sudo` only where required.

If you'd rather do it by hand, the manual procedure follows.

---

## Manual install — Linux

### 1. Install `arduino-cli`

```bash
mkdir -p ~/bin
curl -fsSL https://raw.githubusercontent.com/arduino/arduino-cli/master/install.sh | BINDIR=~/bin sh
```

Add `~/bin` to your `PATH` if it isn't already:

```bash
echo 'export PATH="$HOME/bin:$PATH"' >> ~/.bashrc
source ~/.bashrc
arduino-cli version
```

### 2. Initialise the config and add Teknic's board index

```bash
arduino-cli config init
arduino-cli config add board_manager.additional_urls \
  https://www.teknic.com/files/downloads/package_clearcore_index.json
arduino-cli core update-index
```

### 3. Install the ClearCore platform

```bash
arduino-cli core install ClearCore:sam
```

This pulls the platform (`ClearCore:sam@1.7.1` at time of writing) plus the Linux builds of:

- `arduino:arm-none-eabi-gcc@7-2017q4` — toolchain
- `arduino:bossac@1.9.1-arduino1` — flasher (binary self-reports as `1.8-66` but **does** include the SAMD51/SAME53 chip table; verify with `strings $(which bossac) | grep ATSAMD51`)
- `arduino:CMSIS@4.5.0` — Cortex-M support headers

Confirm:

```bash
arduino-cli core list | grep ClearCore
arduino-cli board listall ClearCore
# → Teknic ClearCore   ClearCore:sam:clearcore
```

The FQBN is **`ClearCore:sam:clearcore`** (board ID is lowercase even though Teknic's user-facing branding is "ClearCore").

### 4. Linux prerequisites — the things that bite you

**4a. Add yourself to `dialout`** so you can open `/dev/ttyACM0` without `sudo`:

```bash
sudo usermod -aG dialout $USER
# Log out and back in, OR start a new login shell:
newgrp dialout
```

**4b. Mask ModemManager.** This is the single most likely cause of `arduino-cli upload` failing on Ubuntu/Debian. ModemManager probes every new `tty` device with AT commands the moment it appears. The bootloader's CDC interface comes up *briefly* after the 1200-baud touch, ModemManager grabs it, bossac can't negotiate the SAM-BA chip-ID handshake, and you get:

```
Performing 1200-bps touch reset on serial port /dev/ttyACM0
Waiting for upload port...
Upload port found on /dev/ttyACM0
"…/bossac" -i -d -a --port=ttyACM0 -U -e -w -v --offset=0x4000 "…/sketch.ino.bin" -R
Set binary mode
No device found on ttyACM0
Failed uploading: uploading error: exit status 1
```

Kill it permanently:

```bash
sudo systemctl mask --now ModemManager
```

(Use `unmask` later if you need it back for a cell modem.)

**4c. Install the udev rule** (recommended, optional). Without it, every USB re-enumeration resets `/dev/ttyACM0` to `root:dialout 0660`, which means `arduino-cli` running outside a fresh login shell can hit a permission race during the brief bootloader window. The rule also tells `udev` not to probe the bootloader's USB Mass Storage interface, which otherwise hangs `blkid` for ~30 s and leaves `/dev/sdc` in a half-mounted state if your desktop tries to auto-mount it.

```bash
sudo cp udev/99-teknic-clearcore.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**4d.** *Skip this unless you also want the IDE.* The Arduino IDE 2.x AppImage needs `libfuse2` on Ubuntu 24+:

```bash
sudo apt install -y libfuse2t64    # or libfuse2 on older Ubuntu
```

### 5. Verify with the BlinkLED example

```bash
git clone https://github.com/RobotBuzzard/teknic-clearcore-cli.git
cd teknic-clearcore-cli
arduino-cli compile --fqbn ClearCore:sam:clearcore examples/BlinkLED
arduino-cli upload  --fqbn ClearCore:sam:clearcore -p /dev/ttyACM0 examples/BlinkLED
```

The on-board USR LED should blink at 1 Hz. If it does, the toolchain is good.

---

## macOS

```bash
brew install arduino-cli
arduino-cli config init
arduino-cli config add board_manager.additional_urls \
  https://www.teknic.com/files/downloads/package_clearcore_index.json
arduino-cli core update-index
arduino-cli core install ClearCore:sam
```

No ModemManager equivalent. No udev. Port is usually `/dev/cu.usbmodem*`. Otherwise identical.

## Windows

Use Teknic's **ClearCore Arduino Wrapper Installer** (Windows MSI from teknic.com) — it bundles arduino-cli + the platform + the Windows toolchain + Teknic's ClearCore Editor for Atmel/Microchip Studio. Or install `arduino-cli.exe` standalone and run the same commands as Linux. Port is `COMx`.

---

## Compile

Sketch folder convention is **Arduino-standard**: the folder name must match the `.ino` filename. Headers and `.cpp` files in the same folder are compiled and linked automatically.

```
MySketch/
├── MySketch.ino       ← entry point
├── MyModule.h
├── MyModule.cpp
└── ...
```

Compile:

```bash
arduino-cli compile --fqbn ClearCore:sam:clearcore /path/to/MySketch
```

Useful flags:

```bash
--verbose                      # full toolchain invocations
--build-property build.extra_flags=-DDEBUG=1
--output-dir ./build           # keep the .bin/.elf/.map next to the sketch
--warnings all
```

A clean build produces:

```
Sketch uses NNNNNN bytes (NN%) of program storage space. Maximum is 507904 bytes.
Global variables use NNNN bytes of dynamic memory.
```

`Maximum is 507904 bytes` confirms the ClearCore linker script — bootloader takes the first 16 KB.

---

## Upload

```bash
arduino-cli upload --fqbn ClearCore:sam:clearcore -p /dev/ttyACM0 /path/to/MySketch
```

What happens under the hood (with `--verbose`):

1. **1200-bps touch reset** on `/dev/ttyACM0` — `arduino-cli` opens the port at 1200 baud, closes it. The application firmware reboots into the bootloader.
2. **Wait for upload port** — the bootloader re-enumerates with USB PID `0022`. `/dev/ttyACM0` reappears (kernel often re-uses the same name).
3. **`bossac`** is invoked:
   ```
   bossac -i -d -a --port=ttyACM0 -U -e -w -v --offset=0x4000 sketch.ino.bin -R
   ```
   - Connects at 921600 baud
   - Reads chip ID `0x61830303` → identifies as `ATSAME53x19`
   - Erases flash from `0x4000`
   - Writes the binary in 4 KB pages
   - Verifies via per-page checksum
   - Issues `writeWord(0xe000ed0c, 0x5fa0004)` — Cortex-M `AIRCR.SYSRESETREQ`, soft-reset
4. The new firmware boots, USB re-enumerates back to PID `8022`.

Total time for a 137 KB sketch: ~3 seconds.

---

## Troubleshooting

| Symptom | Probable cause | Fix |
|---|---|---|
| `Set binary mode` then `No device found on ttyACM0` | **ModemManager** grabbed the port during bootloader re-enumeration | `sudo systemctl mask --now ModemManager` (step 4b) |
| `No upload port found, using /dev/ttyACM0 as fallback` followed by `Failed to open port at 1200bps`, device stays at PID `8022` | Another process holds `/dev/ttyACM0`, so the 1200-bps touch never reaches the firmware. **Most common offender: the Arduino IDE's Serial Monitor.** Also `screen`, `minicom`, `cu`, `picocom`, or a `cat` left running. | Close the Serial Monitor (or whatever has the port), then retry. Diagnose with `sudo fuser -v /dev/ttyACM0` or `sudo lsof /dev/ttyACM0`. |
| `Failed to open port at 1200bps` | User not in `dialout`, or perm race after re-enum | Step 4a (relog into `dialout`) and/or 4c (udev rule) |
| `No upload port found, using /dev/ttyACM0 as fallback` | Bootloader entered but the kernel hasn't created a new tty yet | Usually benign — bossac retries. If persistent, increase the bootloader-wait timeout or use the udev rule. |
| `arduino-cli board list` shows `No boards found` after a failed upload | Device stuck in bootloader (PID `0022`) | Power-cycle the ClearCore. The bootloader doesn't time out on its own. |
| Desktop shows "failed to mount, mount in progress" | GNOME/KDE auto-mount is fighting `udev`'s `blkid` probe of the bootloader mass-storage | Step 4c udev rule (`UDISKS_IGNORE=1`) |
| `mount /dev/sdc` hangs | Same root cause — udev hasn't released the device | Same — udev rule. As a one-off: `sudo kill -9 $(sudo fuser /dev/sdc)` |
| Upload starts, hangs at `Erase flash` for >5 s | USB cable or hub flake. SAM-BA traffic at 921600 is sensitive to bad cables. | Try a different cable, plug directly into a host port (skip hubs) |
| `Invalid FQBN: board ClearCore:sam:ClearCore not found` | Capital `C` in the board ID | Use `ClearCore:sam:clearcore` (lowercase board) |

If a fresh upload fails and the device is stuck in bootloader mode, you can also flash via the **UF2 mass-storage path** as a fallback — but with the udev rule in place, the bossac path is more reliable. UF2 details deliberately omitted here to keep the canonical path simple.

---

## Verifying bossac handles SAME53

If you're suspicious about the bossac you have:

```bash
strings ~/.arduino15/packages/arduino/tools/bossac/*/bossac | grep -E "ATSAMD51|ATSAME53|FAMILY_SAMD51"
```

You should see `ATSAMD51x18/19/20` and `FAMILY_SAMD51` — the SAME53 family is in the same chip table. If those strings are absent, your bossac predates SAMD51 support and you'll need a newer one (Adafruit's fork in `adafruit/ArduinoCore-samd` ships a current build).

---

## Files in this repo

- `examples/BlinkLED/` — minimal sketch toggling `LED_BUILTIN` (the on-board USR LED). Use as a smoke test.
- `scripts/install-toolchain.sh` — runs all the steps above. Idempotent.
- `udev/99-teknic-clearcore.rules` — the udev rule referenced in step 4c.

---

## References

- [Teknic ClearCore product page](https://www.teknic.com/products/io-motion-controller-clearcore/)
- [Teknic ClearCore library on GitHub](https://github.com/Teknic-Inc/ClearCore-library)
- [arduino-cli documentation](https://arduino.github.io/arduino-cli/)
- [Microchip SAME53 datasheet](https://www.microchip.com/en-us/product/atsame53n19a)
- [BOSSA flasher](https://github.com/shumatech/BOSSA)

---

## License

MIT — see [LICENSE](LICENSE).

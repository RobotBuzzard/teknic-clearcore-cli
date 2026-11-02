# Teknic ClearCore — CLI Toolchain & Flashing Guide

Compile and flash sketches for the [Teknic ClearCore](https://www.teknic.com/products/io-motion-controller-clearcore/) industrial controller from a Linux command line. Project-agnostic — applies to any sketch you'd write for the platform.

This guide reflects what actually works on a clean Ubuntu 24.04 install in 2026 with `ClearCore:sam@1.7.1`, and on Windows through WSL2 and usbipd-win (see [WSL2](#wsl2-windows-subsystem-for-linux)). Notes for macOS and native Windows where the path diverges.

---

## What this is

The ClearCore is a SAME53N19A-based motion controller (Cortex-M4F, 120 MHz, 512 KB flash, 192 KB RAM). Teknic ships an Arduino board package, so `arduino-cli` + the standard `arm-none-eabi-gcc` + `bossac` toolchain compiles and flashes it like any other SAMD-family board — **once you've cleared two Linux gotchas**: ModemManager grabbing the bootloader port, and udev probing the bootloader's mass-storage interface.

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
| Programming | USB type-B on the front (A-to-B cable), exposes as `/dev/ttyACM*` |

The bootloader is reached via the **1200-baud touch reset** — open `/dev/ttyACM0` at 1200 baud and close it; the running firmware sees the magic baud and reboots into the bootloader, which re-enumerates as PID `0022`. `arduino-cli upload`, the Arduino IDE and `scripts/flash.sh` all do this for you; the rest of this guide assumes this entry path.

---

## Quick install (Linux)

```bash
git clone https://github.com/RobotBuzzard/teknic-clearcore-cli.git
cd teknic-clearcore-cli
scripts/install-toolchain.sh
```

[`scripts/install-toolchain.sh`](scripts/install-toolchain.sh) must run from a clone (it needs the udev rule and the example sketch from the repo), not piped from `curl`. It's idempotent, runs steps 1–4d below (not the optional IDE step 4e), and asks for `sudo` only where required. To compile and flash a sketch afterwards, see [Upload](#upload).

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
- `arduino:bossac@1.9.1-arduino1` — flasher (binary self-reports as `1.8-66` but **does** include the SAMD51/SAME53 chip table; verify with `strings ~/.arduino15/packages/arduino/tools/bossac/*/bossac | grep ATSAMD51`)
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
# Then log out and back in (newgrp isn't shipped on every image)
id -nG | grep -w dialout   # after logging back in: must list dialout
```

**4b. Keep ModemManager off the ClearCore.** This is the most likely cause of `arduino-cli upload` failing on Ubuntu/Debian. ModemManager probes every new `tty` device with AT commands the moment it appears. The bootloader's CDC interface comes up *briefly* after the 1200-baud touch, ModemManager grabs it, bossac can't negotiate the SAM-BA chip-ID handshake, and you get:

```
Performing 1200-baud touch reset on serial port /dev/ttyACM0
Waiting for upload port...
Upload port found on /dev/ttyACM0
"…/bossac" -i -d -a --port=ttyACM0 -U -e -w -v --offset=0x4000 "…/sketch.ino.bin" -R
Set binary mode
No device found on ttyACM0
Failed uploading: uploading error: exit status 1
```

The udev rule in step 4c tags the ClearCore's application and bootloader ports `ID_MM_DEVICE_IGNORE`, so ModemManager leaves them alone and other modems keep working. Install it. If the failure persists, mask ModemManager instead:

```bash
sudo systemctl mask --now ModemManager
```

Masking disables WWAN and cell modems system-wide. To undo it: `sudo systemctl unmask ModemManager && sudo systemctl start ModemManager`. The installer leaves ModemManager running; set `CLEARCORE_MASK_MM=1` to have it mask ModemManager.

**4c. Install the udev rule** (recommended). It adds stable `/dev/clearcore` (application) and `/dev/clearcore-boot` (bootloader) names, tells ModemManager to ignore the ClearCore (step 4b), and tells `udev` not to probe the bootloader's USB Mass Storage interface, which otherwise hangs `blkid` for ~30 s and leaves `/dev/sdc` in a half-mounted state if your desktop tries to auto-mount it.

```bash
sudo cp udev/99-teknic-clearcore.rules /etc/udev/rules.d/
sudo udevadm control --reload-rules
sudo udevadm trigger
```

**4d. Install the tools `flash.sh` uses** — `lsusb` (to read the device's USB ID) and `lsof` (to check nothing holds the port). `stty` comes with coreutils.

```bash
sudo apt update && sudo apt install -y usbutils lsof
```

**4e.** *Skip this unless you also want the IDE.* The Arduino IDE 2.x AppImage needs `libfuse2` on Ubuntu 24+:

```bash
sudo apt install -y libfuse2t64    # or libfuse2 on older Ubuntu
```

### 5. Verify with the BlinkLED example

```bash
git clone https://github.com/RobotBuzzard/teknic-clearcore-cli.git
cd teknic-clearcore-cli
scripts/flash.sh examples/BlinkLED
```

The IO-4 (green) and IO-5 (red) LEDs should fade up and down in turn, then together (amber), about 2 s per sweep. If they do, the toolchain is good. The sketch also prints each phase on USB serial.

**This is the canonical iterate-loop for every sketch on every flash:**

```bash
scripts/flash.sh <sketch_dir>
```

[`scripts/flash.sh`](scripts/flash.sh) wraps preflight + compile + a state-aware upload that brings the board back into the new application without a power cycle. It:

- Runs `preflight.sh` first
- Refuses to run with more than one ClearCore connected (it can't tell which one is on the port), checks it can open the port (says so plainly if not: `dialout`, step 4a) and that a board is present. These run before the compile so they fail fast
- Compiles to a clean output dir with `arduino-cli compile`
- Detects current device state (PID `8022` application, `0022` bootloader, or absent)
- If in application mode: triggers bootloader entry with a controlled 1200-baud touch via `stty` (set 1200 baud, drop DTR on close, which is what the firmware listens for), polls for the bootloader USB descriptor, and gives CDC an extra 1 s settle window, which is what the IDE does implicitly
- If already in the bootloader: skips the touch (the bootloader ignores it, and uploads that touch an already-booted bootloader have been seen to fail with `Set binary mode / No device found`; the cause isn't established, see Troubleshooting)
- Calls `bossac` directly **without `-a`** (no second touch) and **without `-R`** (see below), retrying up to 3 times with 2 s backoff (a bootloader entered on purpose has no timeout, so retry converges instead of getting stuck). It lets `bossac` run to completion and checks its log afterwards (the last lines are shown if it fails)
- Starts the new application with [`scripts/boot-app.sh`](scripts/boot-app.sh) instead of bossac's `-R` reset. After a plain reset the bootloader waits a moment for a second reset (its double-tap detection) before starting the application; `boot-app.sh` writes the bootloader's own "start the application now" word first, so the application starts at once. See [How the bootloader decides](#how-the-bootloader-decides)
- Verifies the device returns to PID `8022`; if it is still in the bootloader, sends the start command again (safe to repeat). On WSL it tells you when the application isn't reaching WSL

If you need the lower-level commands (e.g., to integrate into a different build system), the raw arduino-cli flow still works:

```bash
scripts/preflight.sh && \
arduino-cli compile --fqbn ClearCore:sam:clearcore <sketch_dir> && \
arduino-cli upload  --fqbn ClearCore:sam:clearcore -p /dev/ttyACM0 <sketch_dir>
```

…but the raw `arduino-cli upload` can leave the board in the bootloader when it starts from that state or after a failed upload. `flash.sh` exists specifically to avoid that. If a board is ever left in the bootloader with good firmware on it, `scripts/boot-app.sh` starts the application without a power cycle.

---

## WSL2 (Windows Subsystem for Linux)

WSL2 does not see USB devices by default. Use [usbipd-win](https://github.com/dorssel/usbipd-win) to pass the ClearCore through, then follow the Linux steps above. WSL2 must have systemd enabled (`[boot] systemd=true` in `/etc/wsl.conf`, then `wsl --shutdown`; the default on current Ubuntu WSL images): the Linux steps rely on udev, which WSL only runs under systemd. Without it the udev rule (and the `dialout` permissions it sets) isn't applied. ModemManager is normally absent under WSL.

The catch: entering the bootloader makes the ClearCore **re-enumerate with a different USB ID** (`2890:8022` → `2890:0022`), and again on the way back. To WSL that is a device unplugging and a new one appearing, so both IDs must be shared and re-attached automatically.

**1. Install usbipd-win** (Windows, once):

```powershell
winget install usbipd
```

**2. Share both modes of the device** (PowerShell **as Administrator**, once per board). Sharing is per mode — `2890:8022` (application) and `2890:0022` (bootloader) are separate entries to usbipd — so bind whichever mode it's in now, switch modes, and bind again:

```powershell
usbipd list                        # note the BUSID of the 2890:xxxx device (e.g. 2-3)
usbipd bind --busid <BUSID>
# Switch modes (application → bootloader: double-tap RESET;
#               bootloader → application: press RESET once, or power-cycle the ClearCore), then:
usbipd list                        # the other 2890:xxxx ID on the same BUSID
usbipd bind --busid <BUSID>        # only if it shows "Not shared"
```

usbipd records each share against the device's instance ID (VID:PID plus the board's USB serial number), so a different ClearCore needs its own two binds. While the board is in the other mode, the share you just made appears under `Persisted:` in `usbipd list`; that is expected.

Both are required. If application mode isn't shared, `flash.sh` can't see the board while your application runs: it can't start an upload from there, and after an upload it exits with code 5 because the application never appears in WSL.

**3. Attach with auto-attach** (normal PowerShell, with a WSL terminal already open: `usbipd` refuses to attach unless a WSL 2 distribution is running; leave this window open while you work):

```powershell
usbipd attach --wsl --busid <BUSID> --auto-attach
```

`--auto-attach` re-attaches the device on that BUSID whenever it reappears, as long as that mode is shared (step 2), so the bootloader and the restarted application both reach WSL without manual steps. The loop runs inside WSL and stops when you close this window or run `wsl --shutdown`; after either, re-run the `attach` command.

**4. Flash as usual** from WSL. Re-attaching adds a second or two to each mode switch; if `flash.sh` times out waiting for the bootloader or the application, raise its timeouts:

```bash
CC_BL_POLL_TIMEOUT=20 CC_APP_RETURN_TIMEOUT=20 scripts/flash.sh <sketch_dir>
```

Known to work with Windows 11 (build 26200), usbipd-win 5.3.0 and WSL2 Ubuntu 26.04.

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

No ModemManager equivalent. No udev. Port is usually `/dev/cu.usbmodem*`. The `arduino-cli` commands are the same, but the scripts in `scripts/` are Linux-only (they use `lsusb` and GNU `stty -F`), so use the raw `arduino-cli` flow on macOS.

## Windows

Use Teknic's **ClearCore Arduino Wrapper Installer** (Windows MSI from teknic.com) — it bundles arduino-cli + the platform + the Windows toolchain + Teknic's ClearCore Editor for Atmel/Microchip Studio. Or install `arduino-cli.exe` standalone and run the same `arduino-cli` commands as on Linux. Port is `COMx`; the bootloader (`2890:0022`) usually gets a different COM number from the application (`2890:8022`).

For native Windows (no WSL), `scripts/flash.ps1` and `scripts/boot-app.ps1` are PowerShell ports of `flash.sh` and `boot-app.sh`, with the same steps and exit codes. They need `arduino-cli` (`winget install ArduinoSA.CLI`) and the `ClearCore:sam` core. They find the board's COM ports by USB ID, so no port argument is needed:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\flash.ps1 .\examples\BlinkLED
powershell -ExecutionPolicy Bypass -File .\scripts\boot-app.ps1      # board left in the bootloader
```

`flash.ps1` options: `-Port COMx` (the application-mode port, if auto-detect picks the wrong one), `-BootloaderTimeout` and `-AppReturnTimeout` (seconds, default 10), `-Retries`, `-RetryDelay`. A board attached to WSL with usbipd-win is invisible to Windows; both scripts say so and print the `usbipd detach` command. Windows COM ports are exclusive, so a port held by a Serial Monitor shows up as an access-denied error before anything is compiled.

The bash scripts in `scripts/` don't run on Windows itself; to use them from a Windows PC, run them in WSL2 (see [WSL2](#wsl2-windows-subsystem-for-linux)). A board left in the bootloader starts its application again with `boot-app.ps1`, a single RESET press or a power cycle.

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

**Recommended:** `scripts/flash.sh <sketch_dir>` (compiles + uploads with state detection and bounded retries; see [the canonical iterate-loop](#5-verify-with-the-blinkled-example)).

For a raw upload command:

```bash
arduino-cli upload --fqbn ClearCore:sam:clearcore -p /dev/ttyACM0 /path/to/MySketch
```

> ⚠️ **Before every raw upload: close any Serial Monitor / terminal that's holding the port.** This is the single most common cause of `arduino-cli upload` failures during bench iteration. The 1200-baud touch needs to *open the port itself* — if anything else has it (Arduino IDE 2's Serial Monitor, `screen`, `minicom`, `cu`, `picocom`, a stray `cat`), the touch silently fails, the device never enters bootloader, and bossac then fails with `Set binary mode / No device found / Failed to open port at 1200bps`. The IDE's own upload sidesteps this because it auto-closes its monitor first; `arduino-cli` doesn't. `flash.sh` runs the preflight automatically.
>
> Manual check: `lsof /dev/ttyACM0` (empty output = free of your own processes; it doesn't show root-owned holders, `sudo lsof /dev/ttyACM0` does). Or run [`scripts/preflight.sh`](scripts/preflight.sh), which names the offending process.

What happens under the hood (with `--verbose`):

1. **1200-baud touch reset** on `/dev/ttyACM0` — `arduino-cli` opens the port at 1200 baud, closes it. The application firmware writes `0xF01669EF` to the last word of RAM and resets; the bootloader sees that word and stays, with no timeout.
2. **Wait for upload port** — the bootloader re-enumerates with USB PID `0022`. `/dev/ttyACM0` reappears (kernel often re-uses the same name).
3. **`bossac`** is invoked:
   ```
   bossac -i -d -a --port=ttyACM0 -U -e -w -v --offset=0x4000 sketch.ino.bin -R
   ```
   - Connects at 921600 baud
   - Reads chip ID `0x61830303` → identifies as `ATSAME53x19`
   - Erases flash from `0x4000`
   - Writes the binary in 4 KB SAM-BA buffers (`Y` command; the SAME53N19A's flash pages are 512 B)
   - Verifies with a CRC-16 per 512-byte flash page (`Z` command)
   - Issues `writeWord(0xe000ed0c, 0x5fa0004)` — Cortex-M `AIRCR.SYSRESETREQ`, soft-reset
4. The bootloader runs its double-tap wait ([next section](#how-the-bootloader-decides)), then starts the new application, and USB re-enumerates back to PID `8022`. `flash.sh` replaces this reset with `boot-app.sh`, which skips the wait.

Total time for a 137 KB sketch: ~3 s with `arduino-cli upload`; `flash.sh` adds a few seconds of settle delays, and on WSL each mode switch also waits for usbipd to re-attach the device.

---

## How the bootloader decides

The ClearCore's bootloader is **UF2 Bootloader v2.3.1-Teknic.4**, Teknic's fork of Microsoft's [uf2-samdx1](https://github.com/microsoft/uf2-samdx1). (Its SAM-BA monitor reports `v1.1 [Arduino:XYZ] Sep 14 2020`; that's the monitor's version, not the bootloader's.) The image read back from a ClearCore with `bossac -r` is byte-identical to `bootloader/bootloader-ClearCore-v2.3.1-Teknic.4.bin` in `ClearCore:sam` 1.7.1.

On every reset, `check_start_application()` decides between staying in the bootloader and starting the application, using the reset cause and one word at the end of RAM, `0x2002FFFC`. For an Arduino sketch built with `ClearCore:sam` 1.7.1 it checks, top to bottom:

| Condition | Bootloader action | Checked |
|---|---|---|
| No application: the reset vector at `0x4004` is outside `0x4000`–`0x80000` (e.g. erased flash) | Stays in the bootloader | code |
| Power-on | Clears the word, starts the application | code + bench |
| The word is `0xF01669EF` (uf2-samdx1's `DBL_TAP_MAGIC`) | Clears it, stays in the bootloader with no timeout | code + bench |
| The word is `0xF02669EF` (`DBL_TAP_MAGIC_QUICK_BOOT`) | Clears it, starts the application at once | code + bench |
| Anything else, e.g. bossac's `-R` | Writes `DBL_TAP_MAGIC`, waits a moment (`delay(500)`, not measured), clears it, starts the application. A second reset during that wait finds `DBL_TAP_MAGIC` and stays: this is the RESET double-tap | code + bench |

So bossac's `-R` works unless something resets or redirects the board during that short wait. `flash.sh` doesn't rely on it: it ends an upload with `boot-app.sh`, which sends `N#` (bossac's opening command, a no-op in this bootloader) and checks that the SAM-BA monitor answers `V#` with its version line, writes `DBL_TAP_MAGIC_QUICK_BOOT` (`W2002FFFC,F02669EF#`) and resets (`WE000ED0C,05FA0004#`), so the application starts with no wait. `flash.sh` then checks the board came back in application mode and sends the start command again if it is still in the bootloader. On its own, `boot-app.sh` gets a board that is sitting in the bootloader with good firmware back into the application without a power cycle.

Who writes the word, the single-reset mode, how a board can still end up in the bootloader after `-R`, and the addresses to check all of this against are in [docs/bootloader.md](docs/bootloader.md).

---

## Troubleshooting

| Symptom | Probable cause | Fix |
|---|---|---|
| `Set binary mode` then `No device found on ttyACM0` | **ModemManager** grabbed the port during bootloader re-enumeration | Install the udev rule (step 4c); if it persists, mask ModemManager (step 4b, disables cell modems) |
| `No upload port found, using /dev/ttyACM0 as fallback` followed by `Failed to open port at 1200bps`, device stays at PID `8022` | Another process holds `/dev/ttyACM0`, so the 1200-baud touch never reaches the firmware. **Most common offender: the Arduino IDE's Serial Monitor.** Also `screen`, `minicom`, `cu`, `picocom`, or a `cat` left running. **See the warning at the top of the Upload section.** | Close the Serial Monitor (or whatever has the port), then retry. Diagnose with `lsof /dev/ttyACM0` (your own processes only; `sudo lsof` shows root-owned holders) or run `scripts/preflight.sh`. |
| Device stuck at PID `0022` (bootloader), `arduino-cli upload` fails with `Set binary mode / No device found` even with port free | Seen when the device is already in the bootloader as `arduino-cli upload` starts. (Its 1200-baud touch doesn't reach the bootloader, which ignores line-coding and DTR changes, so the exact failure point isn't established.) We didn't find a way to make `arduino-cli` skip the touch (not re-verified on 1.5.x; `--upload-property` keys need the `upload.` prefix, `upload.use_1200bps_touch=false`, and with `--verbose` the ClearCore core also passes `-a` to bossac, so bossac performs a 1200-baud touch of its own). | Use `scripts/flash.sh` instead — it detects bootloader state and skips the touch when the device is already there. As a last resort, power-cycle the ClearCore. |
| `Failed to open port at 1200bps` (arduino-cli) or `flash.sh`: `No permission to open /dev/ttyACM0` | Not in `dialout`, or added to it in this login session (group changes apply to new logins; terminals already open keep the old groups), or on WSL systemd is off, so no udev rules ran | Step 4a, then log out and back in; `id -nG` must list `dialout`. On WSL also check that systemd is enabled (see WSL2) |
| After an upload the board sits in the bootloader (I/O LEDs streaming, PID `0022`): `flash.sh` says `Device is still in the bootloader`, or a raw `arduino-cli upload` prints bossac's `Verify successful` but the application doesn't start | The `-R` reset didn't take (BOSSA ignores errors from that write; the bootloader then stays and re-enters itself when USB goes idle), a second reset during the double-tap wait, or a 1200-baud touch from another program (see [docs/bootloader.md](docs/bootloader.md)) | `scripts/boot-app.sh`, or a power cycle. `flash.sh` starts the application with `boot-app.sh` and checks that it came back |
| `No upload port found, using /dev/ttyACM0 as fallback` | `arduino-cli` waited 10 s (fixed) for a new port and fell back to the old name; on Linux the bootloader normally reappears as the same `/dev/ttyACM0` | Benign if bossac then reports `Verify successful`. If it fails with `No device found` / `Failed to open port`, see the rows above (ModemManager, a program holding the port). `flash.sh` doesn't use arduino-cli's port wait; its own wait is `CC_BL_POLL_TIMEOUT` |
| `arduino-cli board list` shows `No boards found` after a failed upload | Device stuck in bootloader (PID `0022`) | `scripts/boot-app.sh` if the application is intact (otherwise flash again with `flash.sh`), or power-cycle the ClearCore. A bootloader entered on purpose doesn't time out on its own. |
| Desktop shows "failed to mount, mount in progress" | GNOME/KDE auto-mount is fighting `udev`'s `blkid` probe of the bootloader mass-storage | Step 4c udev rule (`UDISKS_IGNORE=1`) |
| `mount /dev/sdc` hangs | Same root cause — udev hasn't released the device | Same — udev rule. As a one-off: `sudo kill -9 $(sudo fuser /dev/sdc)` |
| Upload starts, hangs at `Erase flash` for >5 s | USB cable or hub flake. SAM-BA traffic at 921600 is sensitive to bad cables. | Try a different cable, plug directly into a host port (skip hubs) |
| `Invalid FQBN: board ClearCore:sam:ClearCore not found` | Capital `C` in the board ID | Use `ClearCore:sam:clearcore` (lowercase board) |
| `flash.sh`: `'lsusb' not found` or `'lsof' not found` | Missing `usbutils` / `lsof` | `sudo apt update && sudo apt install -y usbutils lsof` (step 4d), or re-run `install-toolchain.sh` |
| `flash.sh`: `More than one ClearCore is connected` | Two or more ClearCores on USB; the script can't tell which is on the port | Unplug all but the one you're flashing |
| WSL: `ClearCore not detected on USB` | The device isn't attached to WSL, or the auto-attach loop stopped (window closed, `wsl --shutdown`) | `usbipd attach --wsl --busid <BUSID> --auto-attach` (see WSL2) |
| WSL: `flash.sh`: `Bootloader entry timed out after 10s` (exit 3; the number is `CC_BL_POLL_TIMEOUT`, default 10) | Bootloader mode isn't shared, the `usbipd attach … --auto-attach` from step 3 isn't running any more (closed window, `wsl --shutdown`, or a plain `attach` without `--auto-attach`), or re-attach is slow | Bind the bootloader mode (WSL2 step 2) and check the auto-attach command is still running; raise `CC_BL_POLL_TIMEOUT` |
| WSL: `flash.sh` exits 5 with `The ClearCore left the bootloader but isn't visible in WSL`; the board is running the new firmware | Application mode (`2890:8022`) isn't shared, or auto-attach isn't running, so it never reaches WSL | While it's running, in Administrator PowerShell: `usbipd bind --busid <BUSID>` (WSL2 step 2); a running auto-attach picks it up on its next poll. The firmware is already written and verified, so there's no need to flash again. If it's only slow, raise `CC_APP_RETURN_TIMEOUT` |
| Device resets during upload and bossac fails partway. Afterwards the old application is running (the reset came before the erase), the board sits in the bootloader (during the erase), or the board is starting a partially written image (during the write) | Firmware set the watchdog to Always-On (e.g. [ClearCoreWatchdog](https://github.com/RobotBuzzard/ClearCoreWatchdog) `enableAlwaysOn()`). It keeps running in the bootloader, and a power cycle alone doesn't help: the application boots and sets it again | Set the watchdog period well above the time from the 1200-baud touch to the end of bossac's write. That time grows with sketch size (the ~3 s above is for a 137 KB sketch; up to 496 KB fits) and on WSL includes usbipd re-attach time. Check it against `flash.sh`'s own timestamps. 16 s is the SAME53 maximum, so large sketches may not fit; then the firmware needs a maintenance escape (see the ClearCoreWatchdog README, Always-On mode). If the watchdog fired during the write, the board may be running a partial image, and a power cycle won't fix that, because the bootloader only checks the reset vector: keep outputs de-energised, double-tap RESET and run `flash.sh` again straight away, since the bootloader holds only until the next watchdog reset |
| `boot-app.sh` (alone or inside `flash.sh`): `no SAM-BA answer on <port>` or `isn't a ClearCore bootloader` | Another program has the port open, or the port isn't the bootloader's tty (wrong `ttyACM` number, or the board isn't in the bootloader) | Close the other program (`scripts/preflight.sh <port>`); find the right port with `lsusb \| grep 2890` and `ls /dev/ttyACM*`, then pass it as the argument |

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

- `scripts/flash.sh` — recommended one-shot compile-and-upload wrapper (`flash.sh <sketch_dir> [port]`, port default `/dev/ttyACM0`). Detects device state, manages timing, retries safely. Use this for every flash unless you have a reason not to. Needs `arduino-cli`, `lsusb`, `lsof` and `stty`.
- `scripts/boot-app.sh` — starts the application from the bootloader at once, with no double-tap wait (`boot-app.sh [port]`, default `/dev/ttyACM0`; see [How the bootloader decides](#how-the-bootloader-decides)). Called by `flash.sh` after every flash; run it yourself when a board is sitting in the bootloader with good firmware on it. Checks that the port is free and is a ClearCore bootloader that answers before writing anything; a no-op if the application is already running. Exit 0 means the start was requested, not that the application started: if the board is still at PID `0022` a few seconds later (allow longer on WSL), there's no valid application to start; flash it with `flash.sh`.
- `scripts/flash.ps1`, `scripts/boot-app.ps1` — native Windows (PowerShell 5.1+) ports of `flash.sh` and `boot-app.sh`; see [Windows](#windows).
- `scripts/preflight.sh` — checks that `/dev/ttyACM0` (or `$1`) isn't held by another process of yours. Called automatically by `flash.sh`; safe to invoke standalone for diagnosis.
- `scripts/install-toolchain.sh` — runs steps 1–4d above (not the optional IDE step). Idempotent. Run it from a clone.
- `udev/99-teknic-clearcore.rules` — the udev rule referenced in step 4c.
- `examples/BlinkLED/` — minimal sketch that fades the IO-4 (green) and IO-5 (red) LEDs up and down with PWM: IO-4, then IO-5, then both together (amber). The on-board USR LED, which is hard to see inside the unit, toggles at each phase. Use as a smoke test.
- `docs/bootloader.md` — details behind [How the bootloader decides](#how-the-bootloader-decides).

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

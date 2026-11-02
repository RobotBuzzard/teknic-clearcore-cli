# How the ClearCore bootloader decides: details

Background for the [How the bootloader decides](../README.md#how-the-bootloader-decides) section of the README: where the RAM word comes from, the single-reset mode, how a board can end up in the bootloader after an upload, and where to find each piece in the bootloader image.

The bootloader is **UF2 Bootloader v2.3.1-Teknic.4**. The image read back from a ClearCore with `bossac -r` is byte-identical to `bootloader/bootloader-ClearCore-v2.3.1-Teknic.4.bin` in `ClearCore:sam` 1.7.1. The `.elf` next to it has symbols, so everything below can be checked with:

```bash
arm-none-eabi-addr2line -f -e bootloader-ClearCore-v2.3.1-Teknic.4.elf <address>
```

## Who writes the word

The word is at `0x2002FFFC`, the last word of RAM.

- `DBL_TAP_MAGIC` (`0xF01669EF`): the application's 1200-baud touch (libClearCore's `ResetBoard(RESET_TO_BOOTLOADER)` writes it, then resets); the wait in the last row of the README's table; and the bootloader's own `resetIntoBootloader()`, which it calls, among other things, when the USB bus goes into suspend while it is in the SAM-BA monitor (cable unplugged, or the host suspends the port). Closing the serial port by itself doesn't do that; only a bus that then goes idle does.
- `DBL_TAP_MAGIC_QUICK_BOOT` (`0xF02669EF`): `boot-app.sh`, and the bootloader's own `resetIntoApp()`, for example after a UF2 file is copied to it.

## Bench observations

After a 1200-baud touch and after a RESET double-tap, the word read back as `0` with the board in the bootloader. A plain reset from there started the application. Writing `DBL_TAP_MAGIC_QUICK_BOOT` and resetting started it at once. A power cycle started it. These are the observations behind the "code + bench" entries in the README's table.

The SAM-BA monitor answers `V#` with its version line (`v1.1 [Arduino:XYZ] Sep 14 2020 14:10:57`). It sends nothing in reply to `N#` or `T#`: in uf2-samdx1 those handlers exist only when `USE_CDC_TERMINAL` is set, and the Teknic build leaves it at 0. bossac sends `N#` first; here it is a no-op, so there is no binary mode to switch to. `boot-app.sh` still sends `N#` before `V#`: right after a bossac session, a `V#` sent on its own often went unanswered, and with `N#` first it is answered. `N#` and `T#` jump straight to the end-of-command code at `0x1F18` (`sam_ba_monitor.c:277`).

## The start command, step by step

`boot-app.sh` sends two SAM-BA commands after the `V#` check:

- `W2002FFFC,F02669EF#` writes `DBL_TAP_MAGIC_QUICK_BOOT` to the RAM word.
- `WE000ED0C,05FA0004#` writes `AIRCR.SYSRESETREQ`, a soft reset.

On the next reset the bootloader finds `DBL_TAP_MAGIC_QUICK_BOOT`, clears it and starts the application with no double-tap wait.

## Single-reset firmware

Firmware with the word `0x87EEB07C` at `0x4268` gets uf2-samdx1's single-reset mode (`USE_SINGLE_RESET`) instead. Nothing in `ClearCore:sam` 1.7.1 adds that word, so this is from the code only. On power-on, and on any other reset unless the word is `DBL_TAP_MAGIC_QUICK_BOOT`, the bootloader writes `DBL_TAP_MAGIC_QUICK_BOOT`, brings up USB as `2890:0022` and starts a timeout (300 ticks of a counter driven by its USB polling, not measured; upstream uses 50, commented "around 1.5s"). If the host finishes enumerating it (SET_CONFIGURATION) before the timeout, it stays in the bootloader; otherwise it starts the application. A second reset in the meantime starts the application at once.

## Not yet explained

An upload that ends with bossac's `-R` can leave a verified board in the bootloader. The cause isn't established. By the rules in the README, the ways `-R` can leave a board in the bootloader are:

- The AIRCR write didn't reset the chip. BOSSA deliberately ignores errors from that write; the bootloader then stays in its monitor and re-enters itself with `resetIntoBootloader()` when the USB bus goes into suspend.
- A second reset during the double-tap wait.
- Another program sending the new application a 1200-baud touch.

A USB drop during the double-tap wait can't keep the board in the bootloader by itself: USB is initialised only after the application check (`usb_init` at `0x177E`, after the jump at `0x1764`).

`boot-app.sh` or a power cycle recovers the board.

## Where to look in the bootloader image

- `check_start_application()` (inlined into `main()`) at `0x16F4`-`0x1856`:
  - application check at `0x16F4`
  - single-reset check at `0x1706`
  - power-on at `0x1714`
  - `DBL_TAP_MAGIC` at `0x1720` and `0x1824`
  - `DBL_TAP_MAGIC_QUICK_BOOT` at `0x172A`
  - double-tap wait at `0x1734`-`0x174C`
  - application start sequence at `0x174E`-`0x1764` (the `bx` into the sketch's reset handler is at `0x1764`)
  - single-reset set-up at `0x1840`
- `resetIntoApp()` at `0x0724`.
- `resetIntoBootloader()` at `0x0774`, called from `sam_ba_monitor_run()` at `0x1E6C`.
- `USB_Disconnected()` at `0x0C18` (reads `FSMSTATUS.SUSPEND`), polled by `sam_ba_monitor_run()` at `0x1E40` and `0x1E64`.
- The timeout check in `timerTick()` at `0x0754`.
- SET_CONFIGURATION in `AT91F_CDC_Enumerate()` at `0x0FD8`.
- The timeout cleared in `main()` at `0x179E`.
- The SAM-BA command dispatch (`V`, `N`, `T`) in `sam_ba_monitor_run()` at `0x1ECC`-`0x1F14`.

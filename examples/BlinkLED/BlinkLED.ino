// ======================================================================
// BlinkLED.ino — Smoke test for the Teknic ClearCore toolchain.
// ======================================================================
// Fades the LEDs on IO-4 (green) and IO-5 (red) up and down with PWM:
// IO-4 alone, then IO-5 alone, then both together (they mix to amber),
// and repeats. The on-board USR LED is tiny and hidden inside the unit,
// so the IO LEDs are the visible signal; USR still toggles at each
// phase as a heartbeat, and each phase is printed on USB serial.
//
// If the IO LEDs sweep, you've successfully:
//   - Installed arduino-cli
//   - Installed the ClearCore:sam platform
//   - Compiled with arm-none-eabi-gcc
//   - Flashed via 1200-baud touch + bossac
//   - Cleared any ModemManager / dialout / udev gotchas
//
// FQBN: ClearCore:sam:clearcore
// Compile: arduino-cli compile --fqbn ClearCore:sam:clearcore .
// Upload:  scripts/flash.sh examples/BlinkLED   (Windows: scripts\flash.ps1)
// ======================================================================

#include "ClearCore.h"

#define GREEN ConnectorIO4
#define RED   ConnectorIO5

static const uint32_t STEP_MS = 4;   // 2 x 256 steps x 4 ms ~= 2 s per sweep

// Square the ramp so the fade looks even to the eye (LED brightness is
// perceived roughly logarithmically).
static uint8_t gamma8(uint8_t level) {
  return (uint8_t)(((uint16_t)level * level + 255) >> 8);
}

static void setDuty(bool green, bool red, uint8_t duty) {
  GREEN.PwmDuty(green ? duty : 0);
  RED.PwmDuty(red ? duty : 0);
}

// Ramp the selected LEDs 0 -> full -> 0.
static void sweep(const char *name, bool green, bool red) {
  Serial.print("sweep: ");
  Serial.println(name);
  digitalWrite(LED_BUILTIN, !digitalRead(LED_BUILTIN));   // heartbeat
  for (int level = 0; level <= 255; level++) {
    setDuty(green, red, gamma8(level));
    delay(STEP_MS);
  }
  for (int level = 255; level >= 0; level--) {
    setDuty(green, red, gamma8(level));
    delay(STEP_MS);
  }
  delay(250);
}

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  GREEN.Mode(Connector::OUTPUT_PWM);
  RED.Mode(Connector::OUTPUT_PWM);
  setDuty(true, true, 0);

  Serial.begin(115200);
  Serial.println("ClearCore BlinkLED: setup complete (IO-4 green, IO-5 red)");
}

void loop() {
  sweep("IO-4 (green)", true, false);
  sweep("IO-5 (red)", false, true);
  sweep("IO-4 + IO-5 (amber)", true, true);
}

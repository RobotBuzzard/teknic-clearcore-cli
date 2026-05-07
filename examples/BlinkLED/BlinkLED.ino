// ======================================================================
// BlinkLED.ino — Smoke test for the Teknic ClearCore toolchain.
// ======================================================================
// Toggles the on-board USR LED at 1 Hz. Uses only the standard Arduino
// API + ClearCore's LED_BUILTIN macro; no peripherals, no libraries.
//
// If the LED blinks, you've successfully:
//   - Installed arduino-cli
//   - Installed the ClearCore:sam platform
//   - Compiled with arm-none-eabi-gcc
//   - Flashed via 1200-baud touch + bossac
//   - Cleared any ModemManager / dialout / udev gotchas
//
// FQBN: ClearCore:sam:clearcore
// Compile: arduino-cli compile --fqbn ClearCore:sam:clearcore .
// Upload:  arduino-cli upload  --fqbn ClearCore:sam:clearcore -p /dev/ttyACM0 .
// ======================================================================

void setup() {
  pinMode(LED_BUILTIN, OUTPUT);
  Serial.begin(115200);
  Serial.println("ClearCore BlinkLED: setup complete");
}

void loop() {
  digitalWrite(LED_BUILTIN, HIGH);
  delay(500);
  digitalWrite(LED_BUILTIN, LOW);
  delay(500);
}

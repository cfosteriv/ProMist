// Bit-banged AP1651 panel bus. Timing and open-drain transitions are kept here
// so the UI layer works with button/display semantics rather than bus pulses.
#include "AP1651.h"

#include <esp_log.h>
#include <esp_rom_sys.h>

namespace {
constexpr char TAG[] = "AP1651";
}

AP1651::AP1651(uint8_t clockPin, uint8_t dataPin)
  : _clockPin(static_cast<gpio_num_t>(clockPin)),
    _dataPin(static_cast<gpio_num_t>(dataPin)) {}

void AP1651::begin() {
  gpio_config_t output = {};
  output.pin_bit_mask = 1ULL << static_cast<uint32_t>(_clockPin);
  output.mode = GPIO_MODE_OUTPUT;
  output.pull_up_en = GPIO_PULLUP_DISABLE;
  output.pull_down_en = GPIO_PULLDOWN_DISABLE;
  output.intr_type = GPIO_INTR_DISABLE;
  esp_err_t result = gpio_config(&output);
  if (result == ESP_OK) result = gpio_set_level(_clockPin, 1);

  gpio_config_t input = {};
  input.pin_bit_mask = 1ULL << static_cast<uint32_t>(_dataPin);
  input.mode = GPIO_MODE_INPUT;
  input.pull_up_en = GPIO_PULLUP_ENABLE;
  input.pull_down_en = GPIO_PULLDOWN_DISABLE;
  input.intr_type = GPIO_INTR_DISABLE;
  if (result == ESP_OK) result = gpio_config(&input);
  _ready = result == ESP_OK;
  if (!_ready) {
    ESP_LOGE(TAG, "Panel bus setup failed: %s", esp_err_to_name(result));
  }
}

void AP1651::busDelay() {
  esp_rom_delay_us(BUS_HALF_PERIOD_US);
}

bool AP1651::setClockLevel(int level) {
  if (!_ready) return false;
  const esp_err_t result = gpio_set_level(_clockPin, level);
  _ready = result == ESP_OK;
  return _ready;
}

bool AP1651::dataLow() {
  if (!_ready) return false;
  esp_err_t result = gpio_set_level(_dataPin, 0);
  if (result == ESP_OK) {
    result = gpio_set_direction(_dataPin, GPIO_MODE_OUTPUT);
  }
  _ready = result == ESP_OK;
  return _ready;
}

bool AP1651::dataRelease() {
  if (!_ready) return false;
  esp_err_t result = gpio_set_direction(_dataPin, GPIO_MODE_INPUT);
  if (result == ESP_OK) {
    result = gpio_set_pull_mode(_dataPin, GPIO_PULLUP_ONLY);
  }
  _ready = result == ESP_OK;
  return _ready;
}

bool AP1651::busStart() {
  if (!dataRelease() || !setClockLevel(1)) return false;
  busDelay();

  if (!dataLow()) return false;
  busDelay();

  if (!setClockLevel(0)) return false;
  busDelay();
  return true;
}

bool AP1651::busStop() {
  if (!setClockLevel(0) || !dataLow()) return false;
  busDelay();

  if (!setClockLevel(1)) return false;
  busDelay();

  if (!dataRelease()) return false;
  busDelay();
  return true;
}

bool AP1651::writeByte(uint8_t value) {
  if (!_ready) return false;
  for (uint8_t bit = 0; bit < 8; bit++) {
    if (!setClockLevel(0)) return false;

    if (value & 0x01) {
      if (!dataRelease()) return false;
    } else {
      if (!dataLow()) return false;
    }

    busDelay();
    if (!setClockLevel(1)) return false;
    busDelay();

    value >>= 1;
  }

  if (!setClockLevel(0) || !dataRelease()) return false;
  busDelay();

  if (!setClockLevel(1)) return false;
  busDelay();

  bool acknowledged = gpio_get_level(_dataPin) == 0;

  if (!setClockLevel(0)) return false;
  busDelay();

  return acknowledged;
}

bool AP1651::readByte(uint8_t &value) {
  value = 0;

  if (!dataRelease()) return false;

  for (uint8_t bit = 0; bit < 8; bit++) {
    if (!setClockLevel(0)) return false;
    busDelay();

    if (!setClockLevel(1)) return false;
    busDelay();

    if (gpio_get_level(_dataPin) != 0) {
      value |= 1U << bit;
    }
  }

  // Finish the read with a NACK.
  if (!setClockLevel(0) || !dataRelease()) return false;
  busDelay();

  if (!setClockLevel(1)) return false;
  busDelay();

  if (!setClockLevel(0)) return false;
  busDelay();

  return true;
}

bool AP1651::sendCommand(uint8_t command) {
  if (!busStart()) return false;
  const bool acknowledged = writeByte(command);
  const bool stopped = busStop();

  return acknowledged && stopped;
}

uint8_t AP1651::readButtons(bool &acknowledged) {
  acknowledged = busStart();

  acknowledged &= writeByte(COMMAND_READ_KEYS);
  uint8_t value = 0;
  acknowledged &= readByte(value);

  acknowledged &= busStop();

  return value;
}

bool AP1651::setDisplay(
  uint8_t whiteLedMask,
  uint8_t rgbLedMask,
  uint8_t brightness
) {
  uint8_t registers[4] = {
    static_cast<uint8_t>(whiteLedMask & 0x1F),
    0x00,
    static_cast<uint8_t>(rgbLedMask & 0x38),
    0x00
  };

  bool acknowledged = true;

  acknowledged &= sendCommand(COMMAND_WRITE_AUTO);

  acknowledged &= busStart();
  acknowledged &= writeByte(COMMAND_ADDRESS_0);

  for (uint8_t index = 0; index < 4; index++) {
    acknowledged &= writeByte(registers[index]);
  }

  acknowledged &= busStop();

  acknowledged &= sendCommand(
    COMMAND_DISPLAY_ON | (brightness & 0x07)
  );

  return acknowledged;
}

bool AP1651::displayOff() {
  return sendCommand(COMMAND_DISPLAY_OFF);
}

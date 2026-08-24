// Safe binary pump output. The retained hardware has no feedback, so this class
// intentionally reports output state rather than claiming verified mist flow.
#include "MisterPump.h"

#include <esp_log.h>

namespace {
constexpr char TAG[] = "MisterPump";
}

MisterPump::MisterPump(uint8_t pumpPin)
  : _pumpPin(static_cast<gpio_num_t>(pumpPin)) {}

void MisterPump::begin() {
  gpio_config_t config = {};
  config.pin_bit_mask = 1ULL << static_cast<uint32_t>(_pumpPin);
  config.mode = GPIO_MODE_OUTPUT;
  config.pull_up_en = GPIO_PULLUP_DISABLE;
  config.pull_down_en = GPIO_PULLDOWN_DISABLE;
  config.intr_type = GPIO_INTR_DISABLE;
  const esp_err_t result = gpio_config(&config);
  if (result != ESP_OK) {
    ESP_LOGE(TAG, "GPIO configuration failed: %s", esp_err_to_name(result));
    return;
  }
  const esp_err_t safeLevelResult = gpio_set_level(_pumpPin, 0);
  if (safeLevelResult != ESP_OK) {
    ESP_LOGE(
      TAG,
      "Could not establish safe/off level: %s",
      esp_err_to_name(safeLevelResult)
    );
    return;
  }
  _on = false;
  _initialized = true;
  ESP_LOGI(TAG, "Ready: GPIO %u, active high", static_cast<unsigned>(_pumpPin));
  ESP_LOGI(TAG, "Pump off");
}

void MisterPump::update(bool on) {
  if (!_initialized) {
    begin();
  }
  if (!_initialized || on == _on) {
    return;
  }
  setPump(on);
}

bool MisterPump::isOn() const {
  return _on;
}

void MisterPump::setPump(bool on) {
  const esp_err_t result = gpio_set_level(_pumpPin, on ? 1 : 0);
  if (result != ESP_OK) {
    ESP_LOGE(TAG, "Pump GPIO update failed: %s", esp_err_to_name(result));
    _initialized = false;
    return;
  }
  _on = on;
  ESP_LOGI(TAG, "Pump %s", on ? "on" : "off");
}

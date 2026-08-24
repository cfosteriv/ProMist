#pragma once

#include <cstdint>

#include <driver/gpio.h>

class MisterPump {
 public:
  /// @param pumpPin Binary output controlling the retained pump circuit.
  explicit MisterPump(uint8_t pumpPin);

  /// Configures the output safe/off before normal control begins.
  void begin();
  /// Applies requested output state; there is no flow/current feedback.
  void update(bool on);
  bool isOn() const;

 private:
  gpio_num_t _pumpPin;
  bool _on = false;
  bool _initialized = false;

  void setPump(bool on);
};

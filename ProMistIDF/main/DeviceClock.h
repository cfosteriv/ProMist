#pragma once

#include <cstdint>

#include <esp_timer.h>

// Monotonic time owned by the ProMist platform boundary. Domain/controller
// code receives explicit timestamps; hardware adapters use this clock directly.
class DeviceClock final {
 public:
  static uint64_t microseconds() {
    return static_cast<uint64_t>(esp_timer_get_time());
  }

  static uint64_t milliseconds() { return microseconds() / 1000ULL; }

  static uint32_t protocolMilliseconds() {
    return static_cast<uint32_t>(milliseconds());
  }

  static uint32_t protocolSeconds() {
    return static_cast<uint32_t>(milliseconds() / 1000ULL);
  }
};

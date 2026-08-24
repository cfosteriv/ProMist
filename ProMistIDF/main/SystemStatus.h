#pragma once

#include <cstdint>

// Ordered by display priority. The main loop selects the highest status
// reported by any controller.
enum SystemStatus : std::uint8_t {
  STATUS_OK = 0,
  STATUS_OSCILLATION_SEARCHING = 1,
  STATUS_FAN_SPEED_LOW = 2,
  STATUS_OSCILLATION_SAFETY_FAULT = 3,
  STATUS_FAN_SPEED_HIGH = 4,
  STATUS_FAN_NOT_TURNING = 5,
  STATUS_HARDWARE_NO_START = 6
};

inline SystemStatus moreSevereStatus(SystemStatus first, SystemStatus second) {
  return first >= second ? first : second;
}

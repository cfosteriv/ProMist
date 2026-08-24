// Pins the severity ordering used when independent hardware adapters report
// simultaneous faults to the retained display.
#include <cassert>

#include "SystemStatus.h"

int main() {
  assert(moreSevereStatus(STATUS_OK, STATUS_FAN_SPEED_LOW) ==
         STATUS_FAN_SPEED_LOW);
  assert(moreSevereStatus(STATUS_FAN_NOT_TURNING,
                          STATUS_OSCILLATION_SAFETY_FAULT) ==
         STATUS_FAN_NOT_TURNING);
  assert(moreSevereStatus(STATUS_HARDWARE_NO_START,
                          STATUS_HARDWARE_NO_START) ==
         STATUS_HARDWARE_NO_START);
  assert(moreSevereStatus(STATUS_FAN_SPEED_HIGH, STATUS_OK) ==
         STATUS_FAN_SPEED_HIGH);
}

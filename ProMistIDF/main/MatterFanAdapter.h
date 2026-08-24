#pragma once

#include "DeviceController.h"

// The platform bridge is intentionally tiny: production esp-matter code and
// host tests implement the same attribute sink without giving Matter access to
// motors or GPIO.
class MatterFanAttributeSink {
 public:
  virtual ~MatterFanAttributeSink() = default;
  virtual void setPower(bool value) = 0;
  virtual void setPercent(uint8_t value) = 0;
  virtual void setRocking(bool value) = 0;
};

class MatterFanAdapter {
 public:
  /// Bridges controller state to a platform sink without exposing GPIO to Matter.
  MatterFanAdapter(DeviceController &controller, MatterFanAttributeSink &sink);

  /// Installs the observer and publishes the initial attribute snapshot.
  bool begin();
  /// Maps Matter FanMode off/on intent into a validated Matter-origin command.
  CommandResult writePower(bool value);
  /// Maps 0...100 percent into the nearest supported five-level fan speed.
  CommandResult writePercent(uint8_t value);
  /// Resolves FanMode and PercentSetting from one Matter interaction. When
  /// both are present, FanMode is authoritative for power.
  CommandResult writeAttributes(
    bool hasPower,
    bool power,
    bool hasPercent,
    uint8_t percent
  );
  /// Maps Matter rocking to the firmware's standard oscillation mode.
  CommandResult writeRocking(bool value);
  /// Republishes only attributes that differ from the last sink snapshot.
  void reconcile();

 private:
  DeviceController &_controller;
  MatterFanAttributeSink &_sink;
  DeviceState _published;
  uint32_t _nextRequestId = 1;
  bool _hasPublished = false;

  static void stateChanged(const DeviceState &state, void *context);
  CommandResult submit(DeviceCommandType type, int32_t value);
  static uint8_t speedToPercent(uint8_t speed);
  static uint8_t percentToSpeed(uint8_t percent);
  void publish(const DeviceState &state);
};

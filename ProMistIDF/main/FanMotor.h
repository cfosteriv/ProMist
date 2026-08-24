#pragma once

#include <cstdint>

#include <driver/gpio.h>
#include <driver/ledc.h>
#include <freertos/FreeRTOS.h>
#include "SystemStatus.h"
#include "SafetyPolicy.h"

class FanMotor {
 public:
  /// @param pwmPin Motor command output.
  /// @param feedbackPin Tachometer input used for closed-loop qualification.
  FanMotor(uint8_t pwmPin, uint8_t feedbackPin);

  /// Configures safe output and tach capture.
  void begin();
  /// Applies output and advances feedback qualification.
  /// @param powered Master logical power state.
  /// @param fanLevel Supported target level in 1...5.
  /// @param dutyPercent Optional calibrated override; zero uses level mapping.
  void update(bool powered, uint8_t fanLevel, uint8_t dutyPercent = 0);
  SystemStatus status() const;
  bool speedConfirmed() const;

 private:
  static constexpr uint32_t PWM_FREQUENCY = 25000;
  static constexpr uint8_t PWM_RESOLUTION = 8;
  static constexpr uint8_t MIN_MOTOR_DUTY_PERCENT = 25;
  static constexpr uint8_t MAX_MOTOR_DUTY_PERCENT = 85;
  static constexpr uint32_t FEEDBACK_REPORT_INTERVAL_MS = 2000;
  static constexpr uint32_t SPIN_UP_GRACE_MS = 5000;
  static constexpr uint8_t BAD_SAMPLE_LIMIT = 2;
  static constexpr uint8_t GOOD_SAMPLE_LIMIT = 2;
  // Lower tach qualification bands for 25%, 40%, 55%, 70%, 85%, and 100%
  // calls. The high-speed check is a flat safety limit, not a target-relative
  // qualification band.
  static constexpr float MIN_EXPECTED_HZ[6] = {
    8.0f, 14.0f, 20.0f, 26.0f, 32.0f, 38.0f
  };
  // The observed 25% and 40% calls are approximately 54 Hz and 83 Hz. A
  // 245 Hz hard limit leaves headroom above the projected full-call speed
  // while still detecting an actual runaway regardless of requested duty.
  static constexpr float MAX_SAFE_HZ = 245.0f;

  gpio_num_t _pwmPin;
  gpio_num_t _feedbackPin;
  uint8_t _appliedLevel = 255;
  uint8_t _appliedDutyPercent = 0;
  bool _usingDutyOverride = false;
  bool _appliedPower = true;
  volatile uint32_t _feedbackPulses = 0;
  uint64_t _previousFeedbackMillis = 0;
  uint64_t _poweredSinceMillis = 0;
  portMUX_TYPE _feedbackLock = portMUX_INITIALIZER_UNLOCKED;
  SystemStatus _status = STATUS_OK;
  uint8_t _lowSamples = 0;
  uint8_t _highSamples = 0;
  FanOverspeedPolicy _overspeedPolicy;
  uint8_t _goodSamples = 0;
  bool _speedConfirmed = false;
  bool _outputReady = false;
  bool _feedbackReady = false;

  static void IRAM_ATTR handleFeedbackInterrupt(void *context);
  void applyOutput(bool powered, uint8_t fanLevel, uint8_t dutyPercent);
  bool configureOutput();
  bool configureFeedback();
  bool writeDuty(uint8_t duty);
  void reportFeedback();
  void clearFeedbackFaults();
};

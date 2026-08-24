#pragma once

#include <cstddef>
#include <cstdint>

#include <driver/gpio.h>
#include <freertos/FreeRTOS.h>

enum RemoteCommand : uint8_t {
  REMOTE_NONE = 0,
  REMOTE_POWER,
  REMOTE_FORWARD,
  REMOTE_MIST,
  REMOTE_BREEZE,
  REMOTE_OSCILLATE,
  REMOTE_FAN_MINUS,
  REMOTE_FAN_PLUS,
  REMOTE_CW_JOG,
  REMOTE_CCW_JOG
};

class RemoteControl {
 public:
  /// rfPin carries demodulated RF data; wakePin is input-only and is not used
  /// for command semantics.
  RemoteControl(uint8_t rfPin, uint8_t wakePin);

  /// Starts the proven falling/rising-edge capture used by the discovery
  /// recognizer. Short receiver glitches are rejected before buffering.
  void begin();
  /// Completes a capture after measured quiet time and returns one command.
  RemoteCommand update();
  static const char *commandName(RemoteCommand command);

 private:
  struct Fingerprint {
    RemoteCommand command;
    const char *symbols;
  };

  // These values intentionally match rf_input_capture.ino.
  static constexpr uint32_t PACKET_QUIET_US = 50000;
  static constexpr uint32_t MAX_CAPTURE_US = 1000000;
  static constexpr uint32_t MIN_RF_LOW_PULSE_US = 100;
  static constexpr uint32_t LONG_PULSE_THRESHOLD_US = 600;
  static constexpr uint32_t SYNC_PULSE_THRESHOLD_US = 5000;
  static constexpr size_t FINGERPRINT_SYMBOL_COUNT = 40;
  // The discovery buffer stores two edges per accepted LOW pulse. Store the
  // already-computed width once so the same 4096-edge capacity uses 8 KiB
  // instead of 32 KiB in the Matter firmware's constrained internal DRAM.
  static constexpr size_t MAX_EVENTS = 4096;
  static constexpr size_t MAX_PULSES = MAX_EVENTS / 2;

  static const Fingerprint FINGERPRINTS[9];

  gpio_num_t _rfPin;
  gpio_num_t _wakePin;

  volatile uint32_t _lowPulseWidthsUs[MAX_PULSES];
  volatile size_t _pulseCount = 0;
  volatile uint64_t _firstEdgeUs = 0;
  volatile uint64_t _lastEdgeUs = 0;
  volatile uint64_t _rfLowStartUs = 0;
  volatile bool _captureActive = false;
  volatile bool _bufferFull = false;
  volatile bool _rfLowActive = false;
  portMUX_TYPE _captureLock = portMUX_INITIALIZER_UNLOCKED;

  static void handleRfEdge(void *context);
  void captureRfEdge();
  void recordPulse(
    uint32_t widthUs,
    uint64_t lowStartUs,
    uint64_t lowEndUs
  );

  void resetCapture();
  RemoteCommand finishCapture();
  RemoteCommand recognizeFingerprint(char *symbols, size_t capacity) const;
};

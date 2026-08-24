#pragma once

#include <cstddef>
#include <cstdint>
#include <driver/gpio.h>
#include "SystemStatus.h"

class OscillationController {
 public:
  /// Coil-driver inputs are in1...in4; hallPin supplies the home reference.
  OscillationController(
    uint8_t in1,
    uint8_t in2,
    uint8_t in3,
    uint8_t in4,
    uint8_t hallPin
  );

  /// Initializes released coils, Hall state, and any valid learned travel.
  void begin(bool trustPersistedReference = true);
  /// Advances the non-blocking state machine for the supplied power/arc target.
  void update(bool powered, uint8_t oscillationMode);
  /// Requests an asynchronous return to the Hall-defined home reference.
  void requestParkHome();
  /// Requests one bounded movement; negative is CCW and positive is CW.
  void requestJog(int8_t direction);
  /// Requests a fixed logical preset in the inclusive range -3...3.
  void requestPreset(int8_t preset);

  bool isHomed() const;
  /// True while oscillation is paused and a Hall reference search is active.
  bool isSearching() const;
  int32_t currentPosition() const;
  int8_t currentPreset() const;
  bool isPositioning() const;
  int8_t targetPreset() const;
  SystemStatus status() const;

 private:
  enum HomingState {
    HOMING_IDLE,
    HOMING_LEAVE_INITIAL_ZONE,
    HOMING_REENTER_INITIAL_ZONE,
    HOMING_SEEK_FIRST_EDGE,
    HOMING_MEASURE_ACTIVE_ZONE,
    HOMING_RETURN_TO_CENTER,
    HOMING_COMPLETE,
    HOMING_FAILED
  };

  // Eight-state half stepping doubles the command resolution while retaining
  // the same motor, ULN2003 driver, and mechanical travel.
  static constexpr uint8_t STEP_SCALE = 2;
  static constexpr int32_t STEPS_PER_REVOLUTION = 2048 * STEP_SCALE;
  // A complete measured 180-degree span must finish comfortably inside the
  // 15-second requirement (4344 default half-steps take about 13 seconds).
  static constexpr uint32_t STEP_INTERVAL_US = 3000;
  static constexpr uint32_t TURNAROUND_PAUSE_MS = 800;
  static constexpr uint8_t HALL_STABLE_SAMPLES = 4;
  static constexpr int HALL_ACTIVE_LEVEL = 0;
  static constexpr int32_t MIN_PLAUSIBLE_HALL_WIDTH_STEPS = 64 * STEP_SCALE;
  static constexpr int32_t MAX_PLAUSIBLE_HALL_WIDTH_STEPS = 768 * STEP_SCALE;
  static constexpr int32_t PRESET_LIMIT_EXTENSION_STEPS = 50 * STEP_SCALE;
  // Missing Hall feedback is passive: reverse periodically and keep looking.
  // The pause plus one search leg remains below 15 seconds.
  static constexpr uint32_t HOMING_SEARCH_LEG_MS = 14000;
  // Initial value measured repeatedly on this mechanism (2164-2202 steps).
  // Later complete 180-degree sweeps refine and persist this value.
  static constexpr int32_t DEFAULT_FULL_SAFE_TRAVEL_STEPS = 2172 * STEP_SCALE;
  static_assert(
    static_cast<uint64_t>(DEFAULT_FULL_SAFE_TRAVEL_STEPS) * STEP_INTERVAL_US <=
      15000000ULL,
    "Default 180-degree sweep must complete within 15 seconds"
  );
  static_assert(
    HOMING_SEARCH_LEG_MS + TURNAROUND_PAUSE_MS <= 15000,
    "Passive homing search cadence must remain within 15 seconds"
  );
  static constexpr int32_t SAFE_TRAVEL_SAVE_THRESHOLD_STEPS = 64 * STEP_SCALE;
  static constexpr uint32_t SAFE_TRAVEL_SAVE_INTERVAL_MS = 60000;

  gpio_num_t _in1;
  gpio_num_t _in2;
  gpio_num_t _in3;
  gpio_num_t _in4;
  gpio_num_t _hallPin;

  uint8_t _halfStepPhase = 0;

  HomingState _homingState = HOMING_IDLE;
  int8_t _homingDirection = 1;
  int8_t _oscillationDirection = 1;
  int8_t _resumeDirection = 1;
  int32_t _position = 0;
  int32_t _activeEntryStep = 0;
  int32_t _activeExitStep = 0;
  int32_t _centerTargetStep = 0;
  int32_t _hallWidthSteps = 0;
  int32_t _measuredFullSafeTravelSteps =
    DEFAULT_FULL_SAFE_TRAVEL_STEPS;
  int32_t _persistedFullSafeTravelSteps = 0;
  int32_t _persistedPosition = 0;
  int32_t _persistedHallWidthSteps = 0;
  int32_t _measuredCwTurnaroundStep = 0;
  int32_t _measuredCcwTurnaroundStep = 0;
  uint64_t _homingSweepStartMillis = 0;
  uint64_t _lastSafeTravelSaveMillis = 0;
  uint64_t _previousStepMicros = 0;
  uint64_t _turnaroundPauseMillis = 0;

  bool _stableHallActive = false;
  bool _candidateHallActive = false;
  uint8_t _candidateHallSamples = 0;
  bool _previousStableHallActive = false;
  bool _trackingHallCrossing = false;
  bool _hallExitSeenThisSweep = false;
  bool _measuredCwTurnaround = false;
  bool _measuredCcwTurnaround = false;
  bool _turnaroundPauseActive = false;
  int32_t _crossingEntryStep = 0;

  bool _previousPowered = false;
  bool _homeEstablished = false;
  bool _oscillationLockedOut = false;
  bool _manualPositionRequested = false;
  bool _manualPositionCanInitiateHoming = false;
  bool _hardwareReady = false;
  int8_t _manualTargetPreset = 0;
  uint8_t _previousMode = 0;
  uint8_t _lastReportedWidthMode = 255;
  int32_t _lastReportedHallWidth = -1;

  bool readHallActive() const;
  void updateHallState();
  void processHallTransition(uint8_t oscillationMode);
  void startHoming(bool recoveringFromError = false);
  void updateHoming();
  void updateOscillation(uint8_t oscillationMode);
  void updateManualPosition();
  void startTurnaroundPause();
  bool takeStep(int8_t direction, bool enforceEnvelope = true);
  bool hallWidthIsPlausible(int32_t width) const;
  bool stepIsDue();
  bool releaseMotor();
  void loadMeasuredSafeTravel();
  void savePositionReference();
  void invalidatePositionReference();
  void saveMeasuredSafeTravelIfNeeded();
  void recordSafeTurnaround(int32_t position, uint8_t oscillationMode);
  void reportOscillationWidth(uint8_t oscillationMode);
  int32_t halfArcSteps(uint8_t oscillationMode) const;
  int32_t presetPosition(int8_t preset) const;
};

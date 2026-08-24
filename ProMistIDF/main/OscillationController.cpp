// Non-blocking stepper/Hall state machine for homing, bounded travel, presets,
// and fault recovery. Long movements advance incrementally from the main loop.
#include "OscillationController.h"
#include "SafetyPolicy.h"

#include <algorithm>

#include <esp_log.h>

#include "DeviceClock.h"
#include "NvsNamespace.h"

namespace {

constexpr char TAG[] = "Oscillation";
// Installed-controller upgrades reuse measured travel and position data. The
// physical recovery gesture remains the supported way to discard it.
constexpr const char *OSCILLATION_NAMESPACE = "sharkosc";

}  // namespace

OscillationController::OscillationController(
  uint8_t in1,
  uint8_t in2,
  uint8_t in3,
  uint8_t in4,
  uint8_t hallPin
)
  : _in1(static_cast<gpio_num_t>(in1)),
    _in2(static_cast<gpio_num_t>(in2)),
    _in3(static_cast<gpio_num_t>(in3)),
    _in4(static_cast<gpio_num_t>(in4)),
    _hallPin(static_cast<gpio_num_t>(hallPin)) {}

void OscillationController::begin(bool trustPersistedReference) {
  gpio_config_t outputs = {};
  outputs.pin_bit_mask =
    (1ULL << static_cast<uint32_t>(_in1)) |
    (1ULL << static_cast<uint32_t>(_in2)) |
    (1ULL << static_cast<uint32_t>(_in3)) |
    (1ULL << static_cast<uint32_t>(_in4));
  outputs.mode = GPIO_MODE_OUTPUT;
  outputs.pull_up_en = GPIO_PULLUP_DISABLE;
  outputs.pull_down_en = GPIO_PULLDOWN_DISABLE;
  outputs.intr_type = GPIO_INTR_DISABLE;
  const esp_err_t outputResult = gpio_config(&outputs);
  const bool released = outputResult == ESP_OK && releaseMotor();

  loadMeasuredSafeTravel();
  if (!trustPersistedReference && _homeEstablished) {
    ESP_LOGD(TAG, "OSCILLATION POSITION: unclean reset invalidated saved reference");
    invalidatePositionReference();
    _homingState = HOMING_IDLE;
  }

  gpio_config_t hall = {};
  hall.pin_bit_mask = 1ULL << static_cast<uint32_t>(_hallPin);
  hall.mode = GPIO_MODE_INPUT;
  hall.pull_up_en = GPIO_PULLUP_ENABLE;
  hall.pull_down_en = GPIO_PULLDOWN_DISABLE;
  hall.intr_type = GPIO_INTR_DISABLE;
  const esp_err_t hallResult = gpio_config(&hall);
  _hardwareReady = released && hallResult == ESP_OK;
  if (!_hardwareReady) {
    ESP_LOGE(
      TAG,
      "GPIO setup failed: outputs=%s safe-level=%s hall=%s",
      esp_err_to_name(outputResult),
      released ? "ok" : "failed",
      esp_err_to_name(hallResult)
    );
    return;
  }
  _stableHallActive = readHallActive();
  _candidateHallActive = _stableHallActive;
  _previousStableHallActive = _stableHallActive;
  _candidateHallSamples = HALL_STABLE_SAMPLES;

  ESP_LOGD(TAG, "Oscillation motor ready: GPIO 18, 19, 21, 22");
  ESP_LOGD(TAG,
    "Starting Hall state on GPIO 26: %s\n",
    _stableHallActive ? "ACTIVE" : "INACTIVE"
  );
  ESP_LOGD(TAG,
    "Measured full safe oscillation travel: %ld steps; "
    "full-span recovery limit: %ld steps\n",
    static_cast<long>(_measuredFullSafeTravelSteps),
    static_cast<long>(_measuredFullSafeTravelSteps)
  );
}

void OscillationController::requestParkHome() {
  requestPreset(0);
}

void OscillationController::requestPreset(int8_t preset) {
  _manualTargetPreset = std::clamp<int8_t>(preset, -3, 3);
  _manualPositionRequested = true;
  // An absolute preset may establish the missing position reference before
  // it can be resolved. Jog requests are deliberately different: they must
  // never turn an arrow press into a calibration/homing operation.
  _manualPositionCanInitiateHoming = true;
  _trackingHallCrossing = false;
  _turnaroundPauseActive = false;
  if (_manualTargetPreset == 0) {
    ESP_LOGD(TAG, "MANUAL POSITION: requested HOME");
  } else {
    ESP_LOGD(TAG,
      "MANUAL POSITION: requested fixed preset %+d\n",
      _manualTargetPreset
    );
  }
}

void OscillationController::requestJog(int8_t direction) {
  direction = direction >= 0 ? 1 : -1;

  // CW/CCW are manual-position commands, not calibration commands. Without
  // a known home and Hall width the preset positions are undefined, so
  // ignore the request rather than starting an unexpected home search.
  if (!isHomed() || _hallWidthSteps <= 0) {
    ESP_LOGD(TAG,
      "MANUAL POSITION: %s ignored; oscillation is not homed\n",
      direction > 0 ? "CW" : "CCW"
    );
    return;
  }

  if (direction > 0) {
    _manualTargetPreset = 3;
    for (int8_t preset = -3; preset <= 3; preset++) {
      if (presetPosition(preset) > _position + 2) {
        _manualTargetPreset = preset;
        break;
      }
    }
  } else {
    _manualTargetPreset = -3;
    for (int8_t preset = 3; preset >= -3; preset--) {
      if (presetPosition(preset) < _position - 2) {
        _manualTargetPreset = preset;
        break;
      }
    }
  }

  _manualPositionRequested = true;
  _manualPositionCanInitiateHoming = false;
  _trackingHallCrossing = false;
  _turnaroundPauseActive = false;

  ESP_LOGD(TAG,
    "MANUAL POSITION: requested %s preset %+d\n",
    direction > 0 ? "CW" : "CCW",
    _manualTargetPreset
  );
}

void OscillationController::update(bool powered, uint8_t oscillationMode) {
  if (!_hardwareReady) {
    (void)releaseMotor();
    return;
  }

  updateHallState();

  if (_stableHallActive != _previousStableHallActive) {
    _previousStableHallActive = _stableHallActive;
    ESP_LOGD(TAG,
      "HALL: %s at relative step %ld\n",
      _stableHallActive ? "ACTIVE" : "INACTIVE",
      static_cast<long>(_position)
    );

    if (powered && oscillationMode != 0) {
      processHallTransition(oscillationMode);
    }
  }

  if (!powered) {
    // Logical power-off releases the coils, but that alone is not evidence
    // that the fan was moved. Save and retain the last trusted reference so
    // the next run resumes from it instead of calibrating every time.
    if (_previousPowered && _homeEstablished) {
      savePositionReference();
    }
    _homingState = _homeEstablished ? HOMING_COMPLETE : HOMING_IDLE;
    _oscillationLockedOut = false;
    _trackingHallCrossing = false;
    _turnaroundPauseActive = false;
    _manualPositionRequested = false;
    _manualPositionCanInitiateHoming = false;
    _manualTargetPreset = 0;
    _oscillationDirection = _resumeDirection;
    releaseMotor();
    _previousPowered = false;
    _previousMode = oscillationMode;
    return;
  }

  if (_manualPositionRequested) {
    if (_oscillationLockedOut) {
      releaseMotor();
      return;
    }

    if (_homingState != HOMING_COMPLETE) {
      if (
        _manualPositionCanInitiateHoming &&
        (
          _homingState == HOMING_IDLE ||
          _homingState == HOMING_FAILED
        )
      ) {
        startHoming();
      }

      if (!_manualPositionCanInitiateHoming) {
        _manualPositionRequested = false;
        releaseMotor();
        ESP_LOGD(TAG,
          "MANUAL POSITION: jog cancelled because home is unavailable"
        );
        return;
      }

      if (
        _homingState != HOMING_COMPLETE &&
        _homingState != HOMING_FAILED
      ) {
        updateHoming();
      }
      return;
    }

    updateManualPosition();
    _previousPowered = powered;
    _previousMode = oscillationMode;
    return;
  }

  if (oscillationMode == 0) {
    _trackingHallCrossing = false;
    _turnaroundPauseActive = false;
    _oscillationDirection = _resumeDirection;
    releaseMotor();
    _previousPowered = powered;
    _previousMode = oscillationMode;
    return;
  }

  if (_oscillationLockedOut) {
    releaseMotor();
    _previousPowered = powered;
    _previousMode = oscillationMode;
    return;
  }

  if (
    !_previousPowered ||
    (_previousMode == 0 && oscillationMode != 0)
  ) {
    if (_homingState != HOMING_COMPLETE) {
      startHoming();
    }
  }

  _previousPowered = powered;
  _previousMode = oscillationMode;

  if (
    _homingState != HOMING_COMPLETE &&
    _homingState != HOMING_FAILED
  ) {
    updateHoming();
    return;
  }

  if (_homingState == HOMING_COMPLETE) {
    updateOscillation(oscillationMode);
  }
}

bool OscillationController::isHomed() const {
  return _homingState == HOMING_COMPLETE;
}

bool OscillationController::isSearching() const {
  return
    _homingState != HOMING_IDLE &&
    _homingState != HOMING_COMPLETE &&
    _homingState != HOMING_FAILED;
}

int32_t OscillationController::currentPosition() const {
  return _position;
}

int8_t OscillationController::currentPreset() const {
  if (!isHomed() || _hallWidthSteps <= 0) {
    return -128;
  }

  int8_t nearestPreset = 0;
  int32_t nearestDistance = abs(_position);
  for (int8_t preset = -3; preset <= 3; ++preset) {
    const int32_t distance = abs(_position - presetPosition(preset));
    if (distance < nearestDistance) {
      nearestDistance = distance;
      nearestPreset = preset;
    }
  }
  return nearestPreset;
}

bool OscillationController::isPositioning() const {
  return _manualPositionRequested &&
    !_oscillationLockedOut &&
    _homingState != HOMING_FAILED;
}

int8_t OscillationController::targetPreset() const {
  return isPositioning()
    ? _manualTargetPreset
    : -128;
}

SystemStatus OscillationController::status() const {
  if (!_hardwareReady) {
    return STATUS_HARDWARE_NO_START;
  }

  if (_oscillationLockedOut || _homingState == HOMING_FAILED) {
    return STATUS_OSCILLATION_SAFETY_FAULT;
  }

  // A missing home reference is now a normal, passive search condition. Keep
  // the ordinary panel indication instead of flashing a fault while searching.
  return STATUS_OK;
}

bool OscillationController::readHallActive() const {
  // The measured sensor switches between approximately 3.1 V and 0.1 V.
  // This assumes the magnet-present state is the LOW state.
  return gpio_get_level(_hallPin) == HALL_ACTIVE_LEVEL;
}

void OscillationController::updateHallState() {
  const bool reading = readHallActive();

  if (reading == _candidateHallActive) {
    if (_candidateHallSamples < HALL_STABLE_SAMPLES) {
      _candidateHallSamples++;
    }
  } else {
    _candidateHallActive = reading;
    _candidateHallSamples = 1;
  }

  if (_candidateHallSamples >= HALL_STABLE_SAMPLES) {
    _stableHallActive = _candidateHallActive;
  }
}

void OscillationController::processHallTransition(uint8_t oscillationMode) {
  // Homing has its own edge-measurement state machine. Runtime crossings
  // are used to keep refining the measured 45-degree reference width and
  // to correct any accumulated step-position drift.
  if (_homingState != HOMING_COMPLETE) {
    return;
  }

  if (_stableHallActive) {
    _crossingEntryStep = _position;
    _trackingHallCrossing = true;
    return;
  }

  if (!_trackingHallCrossing) {
    // Homing finishes at the middle of the active zone, so the first
    // active-to-inactive transition may occur without a preceding runtime
    // entry transition. It is still an absolute, direction-specific edge.
    if (_hallWidthSteps > 0) {
      const int8_t travelDirection = _oscillationDirection >= 0 ? 1 : -1;
      const int32_t halfWidth = _hallWidthSteps / 2;

      _position = travelDirection > 0 ? halfWidth : -halfWidth;
      _resumeDirection = -travelDirection;
      _hallExitSeenThisSweep = true;

      ESP_LOGD(TAG,
        "HALL BOUNDARY: %s edge, position=%ld, next start=%s\n",
        travelDirection > 0 ? "CW" : "CCW",
        static_cast<long>(_position),
        _resumeDirection > 0 ? "CW" : "CCW"
      );

      if (oscillationMode == 1) {
        ESP_LOGD(TAG,
          "OSCILLATION: Hall edge recorded; continuing %ld half-steps outward\n",
          static_cast<long>(PRESET_LIMIT_EXTENSION_STEPS)
        );
      }
    }

    return;
  }

  const int32_t crossingExitStep = _position;
  const int32_t signedWidth = crossingExitStep - _crossingEntryStep;
  const int32_t measuredWidth = signedWidth >= 0
    ? signedWidth
    : -signedWidth;

  _trackingHallCrossing = false;

  if (!hallWidthIsPlausible(measuredWidth)) {
    ESP_LOGD(TAG,
      "HALL CALIBRATION REJECTED: implausible width=%ld; retaining=%ld\n",
      static_cast<long>(measuredWidth),
      static_cast<long>(_hallWidthSteps)
    );
    return;
  }

  const int32_t measuredCenter = _crossingEntryStep + signedWidth / 2;
  _hallWidthSteps = measuredWidth;

  // Rebase the live step counter so the measured Hall midpoint is always
  // forward/zero, even if the stepper has accumulated a little drift.
  _position -= measuredCenter;

  const int8_t travelDirection = signedWidth >= 0 ? 1 : -1;
  _resumeDirection = -travelDirection;
  _hallExitSeenThisSweep = true;

  ESP_LOGD(TAG,
    "HALL CALIBRATION: width=%ld steps, front correction=%ld, "
    "position=%ld, next start=%s\n",
    static_cast<long>(_hallWidthSteps),
    static_cast<long>(measuredCenter),
    static_cast<long>(_position),
    _resumeDirection > 0 ? "CW" : "CCW"
  );

  if (oscillationMode == 1) {
    ESP_LOGD(TAG,
      "OSCILLATION: Hall edge recorded; continuing %ld half-steps outward\n",
      static_cast<long>(PRESET_LIMIT_EXTENSION_STEPS)
    );
  }
}

void OscillationController::startHoming(bool recoveringFromError) {
  // Search is deliberately non-faulting. If the Hall gate is not encountered,
  // updateHoming() reverses on a timer and continues until power is removed or
  // the reference is found.
  _homingState = _stableHallActive
    ? HOMING_LEAVE_INITIAL_ZONE
    : HOMING_SEEK_FIRST_EDGE;
  _homingDirection = _resumeDirection;
  _homingSweepStartMillis = DeviceClock::milliseconds();
  _activeEntryStep = 0;
  _activeExitStep = 0;

  ESP_LOGD(TAG,
    "%s: searching %s; Hall starts %s",
    recoveringFromError
      ? "OSCILLATION RECOVERY"
      : "OSCILLATION CALIBRATION",
    _homingDirection > 0 ? "CW" : "CCW",
    _stableHallActive ? "ACTIVE" : "INACTIVE"
  );

  if (_stableHallActive) {
    ESP_LOGD(TAG, "; Hall gate already found; measuring active window");
  } else {
    ESP_LOGD(TAG,
      "; passive search reverses every %lu ms\n",
      static_cast<unsigned long>(HOMING_SEARCH_LEG_MS)
    );
  }
}

void OscillationController::updateHoming() {
  if (_turnaroundPauseActive) {
    if (DeviceClock::milliseconds() - _turnaroundPauseMillis < TURNAROUND_PAUSE_MS) {
      return;
    }

    _turnaroundPauseActive = false;
    ESP_LOGD(TAG, "OSCILLATION HOMING: limit pause complete");
  }

  if (!stepIsDue()) {
    return;
  }

  // Homing entry is intentionally simple and immediate: the first raw
  // active Hall sample wins before any timeout or step-bound decision.
  // Holding position here also gives the normal debounce logic time to
  // confirm the signal without carrying the mechanism through the gate.
  if (
    (
      _homingState == HOMING_SEEK_FIRST_EDGE ||
      _homingState == HOMING_REENTER_INITIAL_ZONE
    ) &&
    readHallActive()
  ) {
    _stableHallActive = true;
    _candidateHallActive = true;
    _candidateHallSamples = HALL_STABLE_SAMPLES;
    _activeEntryStep = _position;
    _homingState = HOMING_MEASURE_ACTIVE_ZONE;

    ESP_LOGD(TAG,
      "OSCILLATION HOMING: raw Hall entry detected immediately at "
      "step %ld while moving %s\n",
      static_cast<long>(_activeEntryStep),
      _homingDirection > 0 ? "CW" : "CCW"
    );
    return;
  }

  const bool searchLegExpired =
    _homingState == HOMING_SEEK_FIRST_EDGE &&
    !_candidateHallActive &&
    DeviceClock::milliseconds() - _homingSweepStartMillis >= HOMING_SEARCH_LEG_MS;

  if (searchLegExpired) {
    _homingDirection = -_homingDirection;
    // The position is not trusted until Hall is found. Rebase each leg so a
    // continuously running search cannot accumulate the logical step counter.
    _position = 0;
    _homingSweepStartMillis = DeviceClock::milliseconds() + TURNAROUND_PAUSE_MS;
    _homingState = HOMING_SEEK_FIRST_EDGE;
    ESP_LOGD(TAG,
      "OSCILLATION PASSIVE HOME SEARCH: no Hall gate within %lu ms; "
      "reversing %s and continuing\n",
      static_cast<unsigned long>(HOMING_SEARCH_LEG_MS),
      _homingDirection > 0 ? "CW" : "CCW"
    );
    startTurnaroundPause();
    return;
  }

  switch (_homingState) {
    case HOMING_LEAVE_INITIAL_ZONE:
      if (_stableHallActive) {
        takeStep(_homingDirection, false);
        return;
      }

      // We started somewhere inside the zone. Reverse, cross the full
      // active window, and use its two real edges for the midpoint.
      _homingDirection = -_homingDirection;
      _homingState = HOMING_REENTER_INITIAL_ZONE;
      ESP_LOGD(TAG,
        "OSCILLATION HOMING: left initial active zone; reversing"
      );
      startTurnaroundPause();
      break;

    case HOMING_REENTER_INITIAL_ZONE:
      if (!_stableHallActive) {
        takeStep(_homingDirection, false);
        return;
      }

      _activeEntryStep = _position;
      _homingState = HOMING_MEASURE_ACTIVE_ZONE;
      ESP_LOGD(TAG,
        "OSCILLATION HOMING: active-zone entry=%ld\n",
        static_cast<long>(_activeEntryStep)
      );
      break;

    case HOMING_SEEK_FIRST_EDGE:
      if (!_stableHallActive) {
        // A raw active sample must be allowed to finish debouncing without
        // moving farther or tripping the search boundary in the meantime.
        if (_candidateHallActive) {
          return;
        }

        takeStep(_homingDirection, false);
        return;
      }

      _activeEntryStep = _position;
      _homingState = HOMING_MEASURE_ACTIVE_ZONE;
      ESP_LOGD(TAG,
        "OSCILLATION HOMING: active-zone entry=%ld\n",
        static_cast<long>(_activeEntryStep)
      );
      break;

    case HOMING_MEASURE_ACTIVE_ZONE: {
      if (_stableHallActive) {
        takeStep(_homingDirection, false);
        return;
      }

      _activeExitStep = _position;
      _centerTargetStep = _activeEntryStep +
        (_activeExitStep - _activeEntryStep) / 2;
      const int32_t measuredHallWidth = _activeExitStep >= _activeEntryStep
        ? _activeExitStep - _activeEntryStep
        : _activeEntryStep - _activeExitStep;
      if (!hallWidthIsPlausible(measuredHallWidth)) {
        _homingState = HOMING_FAILED;
        _oscillationLockedOut = true;
        releaseMotor();
        invalidatePositionReference();
        ESP_LOGE(TAG, "FAULT: implausible homing Hall width=%ld\n",
                      static_cast<long>(measuredHallWidth));
        return;
      }
      _hallWidthSteps = measuredHallWidth;
      _homingState = HOMING_RETURN_TO_CENTER;

      ESP_LOGD(TAG,
        "OSCILLATION HOMING: exit=%ld width=%ld center=%ld\n",
        static_cast<long>(_activeExitStep),
        static_cast<long>(_hallWidthSteps),
        static_cast<long>(_centerTargetStep)
      );
      startTurnaroundPause();
      break;
    }

    case HOMING_RETURN_TO_CENTER:
      if (_position < _centerTargetStep) {
        takeStep(1, false);
        return;
      }

      if (_position > _centerTargetStep) {
        takeStep(-1, false);
        return;
      }

      _position = 0;
      _homingState = HOMING_COMPLETE;
      _homeEstablished = true;
      _oscillationDirection = _resumeDirection;
      _hallExitSeenThisSweep = false;
      releaseMotor();
      savePositionReference();
      ESP_LOGI(TAG, "OSCILLATION HOMED: forward center is step 0");
      startTurnaroundPause();
      break;

    case HOMING_IDLE:
    case HOMING_COMPLETE:
    case HOMING_FAILED:
      break;

  }
}

void OscillationController::updateOscillation(uint8_t oscillationMode) {
  reportOscillationWidth(oscillationMode);

  if (_turnaroundPauseActive) {
    if (DeviceClock::milliseconds() - _turnaroundPauseMillis < TURNAROUND_PAUSE_MS) {
      return;
    }

    _turnaroundPauseActive = false;
    ESP_LOGD(TAG, "OSCILLATION: turnaround pause complete");
    takeStep(_oscillationDirection);
    return;
  }

  if (!stepIsDue()) {
    return;
  }

  const int32_t limit = halfArcSteps(oscillationMode);
  const int32_t hardSafetyLimit = _measuredFullSafeTravelSteps > 0
    ? _measuredFullSafeTravelSteps / 2
    : limit + STEPS_PER_REVOLUTION;

  if (_position >= limit) {
    if (!_hallExitSeenThisSweep) {
      // The predicted preset limit can arrive before the debounced physical
      // Hall exit. Keep moving until ACTIVE -> INACTIVE is confirmed. Only
      // the distant learned travel boundary may turn this into recovery.
      if (_position >= hardSafetyLimit) {
        ESP_LOGW(TAG,
          "WARNING: CW Hall exit missed before hard safety limit; "
          "home lost, re-searching"
        );
        startHoming(true);
        return;
      }

      takeStep(_oscillationDirection);
      return;
    }
    recordSafeTurnaround(_position, oscillationMode);
    _hallExitSeenThisSweep = false;
    _oscillationDirection = -1;
    startTurnaroundPause();
    return;
  } else if (_position <= -limit) {
    if (!_hallExitSeenThisSweep) {
      if (_position <= -hardSafetyLimit) {
        ESP_LOGW(TAG,
          "WARNING: CCW Hall exit missed before hard safety limit; "
          "home lost, re-searching"
        );
        startHoming(true);
        return;
      }

      takeStep(_oscillationDirection);
      return;
    }
    recordSafeTurnaround(_position, oscillationMode);
    _hallExitSeenThisSweep = false;
    _oscillationDirection = 1;
    startTurnaroundPause();
    return;
  }

  takeStep(_oscillationDirection);
}

void OscillationController::updateManualPosition() {
  if (_turnaroundPauseActive) {
    if (DeviceClock::milliseconds() - _turnaroundPauseMillis < TURNAROUND_PAUSE_MS) {
      return;
    }
    _turnaroundPauseActive = false;
  }

  const int32_t requestedTarget = presetPosition(_manualTargetPreset);
  // Presets are derived from the Hall width and can extend slightly beyond a
  // separately learned travel span. Manual movement should finish at that
  // safe boundary, not request one extra step and latch a safety fault.
  const int32_t target = OscillationSafetyPolicy::clampTarget(
    requestedTarget,
    _measuredFullSafeTravelSteps
  );

  if (_position == target) {
    _manualPositionRequested = false;
    _manualPositionCanInitiateHoming = false;
    releaseMotor();
    savePositionReference();
    if (target != requestedTarget) {
      ESP_LOGD(TAG,
        "MANUAL POSITION: preset %+d stopped at safe boundary step %ld "
        "(requested %ld)\n",
        _manualTargetPreset,
        static_cast<long>(_position),
        static_cast<long>(requestedTarget)
      );
    } else {
      ESP_LOGD(TAG,
        "MANUAL POSITION: reached preset %+d at step %ld\n",
        _manualTargetPreset,
        static_cast<long>(_position)
      );
    }
    return;
  }

  if (!stepIsDue()) {
    return;
  }

  takeStep(_position < target ? 1 : -1);
}

void OscillationController::startTurnaroundPause() {
  _turnaroundPauseActive = true;
  _turnaroundPauseMillis = DeviceClock::milliseconds();
  ESP_LOGD(TAG,
    "OSCILLATION: pausing %lu ms at turnaround\n",
    static_cast<unsigned long>(TURNAROUND_PAUSE_MS)
  );
}

bool OscillationController::takeStep(
  int8_t direction,
  bool enforceEnvelope
) {
  if (!_hardwareReady) {
    return false;
  }

  direction = direction >= 0 ? 1 : -1;
  const int32_t hardSafetyLimit = _measuredFullSafeTravelSteps / 2;
  const int32_t nextPosition = _position + direction;
  if (enforceEnvelope && !OscillationSafetyPolicy::permitsStep(
        _position, direction, _measuredFullSafeTravelSteps)) {
    releaseMotor();
    _oscillationLockedOut = true;
    _homingState = HOMING_FAILED;
    invalidatePositionReference();
    ESP_LOGD(TAG,
      "FAULT: oscillation step rejected outside physical envelope next=%ld limit=%ld\n",
      static_cast<long>(nextPosition), static_cast<long>(hardSafetyLimit)
    );
    return false;
  }

  _halfStepPhase = static_cast<uint8_t>(
    (_halfStepPhase + (direction > 0 ? 1 : 7)) & 0x07
  );

  // Adjacent entries alternate one and two energized windings. The phase
  // order matches the known-good IN1, IN2, IN3, IN4 sequence for this motor.
  static constexpr uint8_t HALF_STEP_PATTERN[8] = {
    0b0011, 0b0010, 0b0110, 0b0100,
    0b1100, 0b1000, 0b1001, 0b0001
  };
  const uint8_t pattern = HALF_STEP_PATTERN[_halfStepPhase];
  esp_err_t result = gpio_set_level(_in1, (pattern & 0b0001) != 0 ? 1 : 0);
  if (result == ESP_OK) {
    result = gpio_set_level(_in2, (pattern & 0b0010) != 0 ? 1 : 0);
  }
  if (result == ESP_OK) {
    result = gpio_set_level(_in3, (pattern & 0b0100) != 0 ? 1 : 0);
  }
  if (result == ESP_OK) {
    result = gpio_set_level(_in4, (pattern & 0b1000) != 0 ? 1 : 0);
  }
  if (result != ESP_OK) {
    _hardwareReady = false;
    (void)releaseMotor();
    ESP_LOGE(TAG, "Stepper GPIO update failed: %s", esp_err_to_name(result));
    return false;
  }
  _position += direction;
  return true;
}

bool OscillationController::hallWidthIsPlausible(int32_t width) const {
  return OscillationSafetyPolicy::plausibleHallWidth(width, _hallWidthSteps);
}

bool OscillationController::stepIsDue() {
  const uint64_t now = DeviceClock::microseconds();

  if (now - _previousStepMicros < STEP_INTERVAL_US) {
    return false;
  }

  _previousStepMicros = now;
  return true;
}

bool OscillationController::releaseMotor() {
  // Attempt every release even if an earlier GPIO write failed. A single
  // failed coil must not prevent the remaining coils from being de-energized.
  const esp_err_t in1Result = gpio_set_level(_in1, 0);
  const esp_err_t in2Result = gpio_set_level(_in2, 0);
  const esp_err_t in3Result = gpio_set_level(_in3, 0);
  const esp_err_t in4Result = gpio_set_level(_in4, 0);
  const esp_err_t result = in1Result != ESP_OK ? in1Result
    : in2Result != ESP_OK ? in2Result
    : in3Result != ESP_OK ? in3Result
    : in4Result;
  if (result != ESP_OK) {
    const bool wasReady = _hardwareReady;
    _hardwareReady = false;
    if (wasReady) {
      ESP_LOGE(TAG, "Could not release stepper coils: %s", esp_err_to_name(result));
    }
  }
  return result == ESP_OK;
}

void OscillationController::loadMeasuredSafeTravel() {
  NvsNamespace storage;

  if (storage.open(OSCILLATION_NAMESPACE, NVS_READONLY) == ESP_OK) {
    uint8_t savedStepScale = 1;
    (void)storage.getU8("stepScale", savedStepScale);
    const int32_t migrationScale = savedStepScale == STEP_SCALE
      ? 1
      : STEP_SCALE;
    int32_t rawSafeTravel = DEFAULT_FULL_SAFE_TRAVEL_STEPS / STEP_SCALE;
    int32_t rawPosition = 0;
    int32_t rawHallWidth = 0;
    uint8_t rawReferenceValid = 0;
    int8_t rawResumeDirection = 1;
    (void)storage.getI32("safeTravel", rawSafeTravel);
    (void)storage.getU8("refValid", rawReferenceValid);
    (void)storage.getI32("position", rawPosition);
    (void)storage.getI32("hallWidth", rawHallWidth);
    (void)storage.getI8("resumeDir", rawResumeDirection);
    const bool referenceValid = rawReferenceValid != 0;
    int32_t savedPosition = 0;
    int32_t savedHallWidth = 0;
    const bool storedValuesScaleSafely =
      OscillationSafetyPolicy::scalePersistedValue(
        rawSafeTravel, migrationScale, _measuredFullSafeTravelSteps
      ) &&
      OscillationSafetyPolicy::scalePersistedValue(
        rawPosition, migrationScale, savedPosition
      ) &&
      OscillationSafetyPolicy::scalePersistedValue(
        rawHallWidth, migrationScale, savedHallWidth
      );
    if (!storedValuesScaleSafely) _measuredFullSafeTravelSteps = 0;
    const int8_t savedResumeDirection = rawResumeDirection >= 0 ? 1 : -1;

    if (
      referenceValid &&
      storedValuesScaleSafely &&
      savedHallWidth >= MIN_PLAUSIBLE_HALL_WIDTH_STEPS &&
      savedHallWidth <= MAX_PLAUSIBLE_HALL_WIDTH_STEPS &&
      OscillationSafetyPolicy::validPersistedPosition(
        savedPosition,
        _measuredFullSafeTravelSteps
      )
    ) {
      _position = savedPosition;
      _hallWidthSteps = savedHallWidth;
      _resumeDirection = savedResumeDirection;
      _oscillationDirection = _resumeDirection;
      _homeEstablished = true;
      _homingState = HOMING_COMPLETE;
      _persistedPosition = _position;
      _persistedHallWidthSteps = _hallWidthSteps;
    }
    storage.close();

    // Early installed builds stored full-step calibration. Convert all related
    // values together so a later save cannot mix full- and half-step units.
    if (migrationScale != 1 && storedValuesScaleSafely) {
      NvsNamespace migrationStorage;
      if (migrationStorage.open(OSCILLATION_NAMESPACE, NVS_READWRITE) == ESP_OK) {
        const bool migrated =
          migrationStorage.setI32("safeTravel", _measuredFullSafeTravelSteps) == ESP_OK &&
          migrationStorage.setI32("position", savedPosition) == ESP_OK &&
          migrationStorage.setI32("hallWidth", savedHallWidth) == ESP_OK &&
          migrationStorage.setU8("stepScale", STEP_SCALE) == ESP_OK &&
          migrationStorage.commit() == ESP_OK;
        if (!migrated) {
          ESP_LOGW(TAG, "WARNING: unable to commit legacy position migration");
        }
      }
    }
    if (referenceValid && !_homeEstablished) {
      // Persist the rejection as well as keeping in-memory positional trust
      // false, so corrupt/out-of-envelope data is never reconsidered as valid.
      invalidatePositionReference();
    }
  }

  if (_measuredFullSafeTravelSteps <= 0) {
    _measuredFullSafeTravelSteps = DEFAULT_FULL_SAFE_TRAVEL_STEPS;
  }

  _persistedFullSafeTravelSteps = _measuredFullSafeTravelSteps;

  if (_homeEstablished) {
    ESP_LOGD(TAG,
      "OSCILLATION POSITION: restored step %ld, Hall width %ld; "
      "assuming last saved position\n",
      static_cast<long>(_position),
      static_cast<long>(_hallWidthSteps)
    );
  } else {
    ESP_LOGD(TAG,
      "OSCILLATION POSITION: no trusted saved reference; homing required"
    );
  }
}

void OscillationController::savePositionReference() {
  if (
    !_homeEstablished ||
    _hallWidthSteps <= 0 ||
    (
      _position == _persistedPosition &&
      _hallWidthSteps == _persistedHallWidthSteps
    )
  ) {
    return;
  }

  NvsNamespace storage;
  if (storage.open(OSCILLATION_NAMESPACE, NVS_READWRITE) != ESP_OK) {
    ESP_LOGW(TAG, "WARNING: unable to open position-reference storage");
    return;
  }

  if (storage.setU8("refValid", 1) == ESP_OK &&
      storage.setI32("position", _position) == ESP_OK &&
      storage.setI32("hallWidth", _hallWidthSteps) == ESP_OK &&
      storage.setI8("resumeDir", _resumeDirection >= 0 ? 1 : -1) == ESP_OK &&
      storage.setU8("stepScale", STEP_SCALE) == ESP_OK &&
      storage.commit() == ESP_OK) {
    _persistedPosition = _position;
    _persistedHallWidthSteps = _hallWidthSteps;
    ESP_LOGD(TAG,
      "OSCILLATION POSITION: saved trusted step %ld\n",
      static_cast<long>(_position)
    );
  } else {
    ESP_LOGW(TAG, "WARNING: unable to save complete position reference");
  }
}

void OscillationController::invalidatePositionReference() {
  _homeEstablished = false;

  NvsNamespace storage;
  if (storage.open(OSCILLATION_NAMESPACE, NVS_READWRITE) != ESP_OK) {
    ESP_LOGW(TAG, "WARNING: unable to invalidate position reference");
    return;
  }
  if (storage.setU8("refValid", 0) != ESP_OK || storage.commit() != ESP_OK) {
    ESP_LOGW(TAG, "WARNING: unable to commit invalid position reference");
  }
}

void OscillationController::saveMeasuredSafeTravelIfNeeded() {
  const int32_t difference = abs(
    _measuredFullSafeTravelSteps - _persistedFullSafeTravelSteps
  );
  const uint64_t now = DeviceClock::milliseconds();

  if (
    difference < SAFE_TRAVEL_SAVE_THRESHOLD_STEPS ||
    (
      _lastSafeTravelSaveMillis != 0 &&
      now - _lastSafeTravelSaveMillis < SAFE_TRAVEL_SAVE_INTERVAL_MS
    )
  ) {
    return;
  }

  NvsNamespace storage;

  if (storage.open(OSCILLATION_NAMESPACE, NVS_READWRITE) != ESP_OK) {
    ESP_LOGW(TAG, "WARNING: unable to open safe-travel storage");
    return;
  }

  if (storage.setI32("safeTravel", _measuredFullSafeTravelSteps) == ESP_OK &&
      storage.setU8("stepScale", STEP_SCALE) == ESP_OK &&
      storage.commit() == ESP_OK) {
    _persistedFullSafeTravelSteps = _measuredFullSafeTravelSteps;
    _lastSafeTravelSaveMillis = now;
    ESP_LOGD(TAG,
      "OSCILLATION SAFE TRAVEL: saved %ld steps\n",
      static_cast<long>(_measuredFullSafeTravelSteps)
    );
  } else {
    ESP_LOGW(TAG, "WARNING: unable to save safe-travel measurement");
  }
}

void OscillationController::recordSafeTurnaround(
  int32_t position,
  uint8_t oscillationMode
) {
  // Only the widest, 180-degree mode represents the complete configured
  // safe travel span. Narrower modes must not shrink the recovery range.
  if (oscillationMode != 3) {
    return;
  }

  if (position > 0) {
    _measuredCwTurnaroundStep = position;
    _measuredCwTurnaround = true;
  } else if (position < 0) {
    _measuredCcwTurnaroundStep = position;
    _measuredCcwTurnaround = true;
  }

  if (!_measuredCwTurnaround || !_measuredCcwTurnaround) {
    return;
  }

  _measuredFullSafeTravelSteps =
    _measuredCwTurnaroundStep - _measuredCcwTurnaroundStep;

  ESP_LOGD(TAG,
    "OSCILLATION SAFE TRAVEL: measured %ld steps (%ld to %ld)\n",
    static_cast<long>(_measuredFullSafeTravelSteps),
    static_cast<long>(_measuredCcwTurnaroundStep),
    static_cast<long>(_measuredCwTurnaroundStep)
  );

  saveMeasuredSafeTravelIfNeeded();
}

void OscillationController::reportOscillationWidth(
  uint8_t oscillationMode
) {
  if (
    oscillationMode == 0 ||
    _hallWidthSteps <= 0 ||
    (
      oscillationMode == _lastReportedWidthMode &&
      _hallWidthSteps == _lastReportedHallWidth
    )
  ) {
    return;
  }

  const int32_t totalWidthSteps = halfArcSteps(oscillationMode) * 2;
  uint16_t requestedDegrees = 0;

  switch (oscillationMode) {
    case 1:
      requestedDegrees = 45;
      break;

    case 2:
      requestedDegrees = 90;
      break;

    case 3:
      requestedDegrees = 180;
      break;

    default:
      return;
  }

  _lastReportedWidthMode = oscillationMode;
  _lastReportedHallWidth = _hallWidthSteps;

  ESP_LOGD(TAG,
    "OSCILLATION STEP WIDTH: %u degrees | %ld steps\n",
    requestedDegrees,
    static_cast<long>(totalWidthSteps)
  );
}

int32_t OscillationController::halfArcSteps(uint8_t oscillationMode) const {
  if (_hallWidthSteps <= 0) {
    return 0;
  }

  switch (oscillationMode) {
    case 1:
      // The two Hall boundaries define the complete 45-degree arc.
      return (
        _hallWidthSteps / 2 > 0
          ? _hallWidthSteps / 2
          : 1
      ) + PRESET_LIMIT_EXTENSION_STEPS;

    case 2:
      // A 90-degree total arc is twice the measured Hall width.
      return _hallWidthSteps + PRESET_LIMIT_EXTENSION_STEPS;

    case 3:
      // A 180-degree total arc is four times the measured Hall width.
      return _hallWidthSteps * 2 + PRESET_LIMIT_EXTENSION_STEPS;

    default:
      return 0;
  }
}

int32_t OscillationController::presetPosition(int8_t preset) const {
  preset = std::clamp<int8_t>(preset, -3, 3);
  if (preset == 0) {
    return 0;
  }

  const uint8_t magnitude = preset > 0 ? preset : -preset;
  const int32_t position = halfArcSteps(magnitude);
  return preset > 0 ? position : -position;
}

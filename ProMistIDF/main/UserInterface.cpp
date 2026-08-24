// Physical button/display policy, animations, and local command translation.
// It preserves appliance usability even when every network transport is absent.
#include "UserInterface.h"

#include <algorithm>

#include <esp_log.h>

#include "DeviceClock.h"

namespace {
constexpr char TAG[] = "UserInterface";
}

UserInterface::UserInterface(
  AP1651 &board,
  DeviceController &controller,
  CustomBreezeStore &breezeStore
)
  : _board(board),
    _controller(controller),
    _breezeStore(breezeStore) {}

void UserInterface::begin() {
  // Electrical power detection owns the RGB status LED for ten seconds. This
  // is deliberately independent of the appliance's logical power state.
  _bootRgbActive = true;
  _bootRgbMillis = DeviceClock::milliseconds();
  setDisplay(0, RGB_GREEN);
  _observedPower = isPowered();
  _commandFeedbackQueue = xQueueCreate(16, sizeof(QueuedCommandFeedback));
  if (_commandFeedbackQueue == nullptr ||
      !_controller.addCommandObserver(commandCompleted, this)) {
    ESP_LOGE(TAG, "UI FAILED: unable to register unified command feedback");
  }

  ESP_LOGD(TAG, "ProMist UI controller");
  ESP_LOGD(TAG, "System is off. Press POWER.");

  printCurrentState();
}

void UserInterface::update() {
  retryDisplayWrite();
  processCommandFeedback();
  reconcilePowerState();
  pollButtons();
  processBootRgbTimeout();
  processSecurityGestureHold();
  if (processSecurityFeedback()) {
    return;
  }
  if (_securityDisplaySuppressed) {
    return;
  }
  // Power transitions must continue internally even while a fault owns the
  // LED. This lets POWER OFF clear latched, power-cycle-resettable faults.
  const bool powerAnimationWasActive =
    _powerTransition != POWER_TRANSITION_NONE;
  processPowerAnimation();

  // Power animation exclusively owns the display for the complete loop in
  // which it is active (including its final frame). This prevents a fault
  // color write from fighting the animation and producing visible flicker.
  if (powerAnimationWasActive) {
    return;
  }

  // Breeze timing controls the motor as well as the display, so it must keep
  // advancing even while a fault temporarily owns the LEDs.
  processBreezeSequence();

  if (_systemStatus != STATUS_OK) {
    updateStatusDisplay();
    return;
  }

  processSprinklerAnimation();
  processDisplayTimeout();
}

void UserInterface::commandCompleted(
  const DeviceCommand &command,
  CommandResult result,
  void *context
) {
  auto *interface = static_cast<UserInterface *>(context);
  if (interface->_commandFeedbackQueue == nullptr) return;
  const QueuedCommandFeedback feedback = {command, result};
  if (xQueueSend(interface->_commandFeedbackQueue, &feedback, 0) != pdTRUE) {
    ESP_LOGD(TAG, "UI FEEDBACK: command queue full");
  }
}

void UserInterface::processCommandFeedback() {
  if (_commandFeedbackQueue == nullptr) return;
  QueuedCommandFeedback feedback;
  while (xQueueReceive(_commandFeedbackQueue, &feedback, 0) == pdTRUE) {
    handleCommandFeedback(
      feedback.command.type,
      feedback.command.value,
      feedback.command.metadata.origin,
      feedback.result == CommandResult::Accepted
    );
  }
}

bool UserInterface::isPowered() const {
  return _controller.state().power;
}

bool UserInterface::isFanOutputEnabled() const {
  // Breeze modes vary speed but never intentionally stop the fan.
  return isPowered();
}

uint8_t UserInterface::fanLevel() const {
  return _controller.state().targetFanSpeed;
}

uint8_t UserInterface::breezeFanLevel() const {
  const uint8_t breezeMode = _controller.state().breezeMode;
  if (breezeMode == 1) {
    // Pulse close to maximum without dropping the motor to zero RPM.
    return (_breezeStep % 2) == 0 ? 5 : 4;
  }

  if (breezeMode == 2) {
    static constexpr uint8_t levels[] = { 5, 3, 5, 3, 5 };
    return levels[_breezeStep % 5];
  }

  if (breezeMode == 3) {
    static constexpr uint8_t levels[] = { 3, 5, 3, 5, 3 };
    return levels[_breezeStep % 5];
  }

  if (const CustomBreezeProfile *profile =
        _breezeStore.profileForMode(breezeMode)) {
    return profile->segments[_breezeStep % profile->segmentCount].level;
  }

  return _controller.state().targetFanSpeed;
}

uint8_t UserInterface::fanDutyPercent() const {
  const uint8_t breezeMode = _controller.state().breezeMode;
  if (breezeMode == 2 || breezeMode == 3) {
    return fanLevel() == 5 ? 80 : 30;
  }

  // Zero tells FanMotor to use its normal level-to-duty mapping.
  return 0;
}

uint8_t UserInterface::oscillationMode() const {
  return _controller.state().oscillationMode;
}

bool UserInterface::isMisterEnabled() const {
  return _controller.state().mistMode != 0;
}

bool UserInterface::isBreezeEnabled() const {
  return _controller.state().breezeMode != 0;
}

void UserInterface::setFanSpeedConfirmed(bool confirmed) {
  _fanSpeedConfirmed = confirmed;
}

UserInterface::SecurityGesture UserInterface::consumeSecurityGesture() {
  const SecurityGesture gesture = _securityGesture;
  _securityGesture = SecurityGesture::None;
  return gesture;
}

UserInterface::SecurityGesture
UserInterface::consumeCompletedSecurityFeedback() {
  const SecurityGesture gesture = _completedSecurityFeedbackGesture;
  _completedSecurityFeedbackGesture = SecurityGesture::None;
  return gesture;
}

void UserInterface::showSecurityFeedback(SecurityGesture gesture) {
  if (gesture == SecurityGesture::None) return;
  _activeSecurityFeedbackGesture = gesture;
  _securityDisplaySuppressed = false;
  _provisioningFeedbackActive = gesture == SecurityGesture::Provision;
  _securityFeedbackIsProvisioning = _provisioningFeedbackActive;
  _securityFeedbackRgbMask = _provisioningFeedbackActive ? RGB_BLUE : RGB_RED;
  _securityFeedbackPhase = SECURITY_FEEDBACK_ON;
  _securityFeedbackFrame = 0;
  _securityFeedbackMillis = DeviceClock::milliseconds();
  // Match the normal power-on animation; only its semantic RGB color differs.
  setDisplay(powerAnimationMask(0), 0);
}

void UserInterface::updateProvisioningFeedback(bool provisioning) {
  if (!_provisioningFeedbackActive || provisioning) return;
  _provisioningFeedbackActive = false;
  // Successful enrollment, explicit cancellation, and timeout all release the
  // provisioning-only display/control state. A button already being held must
  // be released before it can start a normal gesture in the newly active mode.
  _securityDisplaySuppressed = false;
  if (_stableButton != 0) {
    _securityGestureFiredForPress = true;
  }
  if (_securityFeedbackPhase == SECURITY_FEEDBACK_HOLD) {
    _securityFeedbackPhase = SECURITY_FEEDBACK_OFF;
    _securityFeedbackFrame = 0;
    _securityFeedbackMillis = DeviceClock::milliseconds();
    setDisplay(0x1F, 0);
  }
}

void UserInterface::processSecurityGestureHold() {
  if (_securityGestureFiredForPress || _stableButton == 0) {
    return;
  }
  const uint64_t heldMillis = DeviceClock::milliseconds() - _buttonPressedMillis;
  if (_provisioningFeedbackActive) {
    // The press that entered provisioning is already marked as fired. Only a
    // newly pressed-and-held FAN button may close the active window.
    if (_stableButton == BUTTON_FAN && heldMillis >= PROVISION_HOLD_MS) {
      _securityGesture = SecurityGesture::CancelProvisioning;
      _securityGestureFiredForPress = true;
    }
    return;
  }
  // A reboot is deliberately available regardless of logical power so a
  // wedged radio can always be recovered from the physical panel. It does not
  // erase ownership, Matter fabrics, names, diagnostics, or other NVS state.
  if (_stableButton == BUTTON_MISTER && heldMillis >= RESTART_HOLD_MS) {
    _securityGesture = SecurityGesture::Restart;
    _securityGestureFiredForPress = true;
    return;
  }
  if (isPowered()) {
    return;
  }
  if (_stableButton == BUTTON_FAN && heldMillis >= PROVISION_HOLD_MS) {
    _securityGesture = SecurityGesture::Provision;
    _securityGestureFiredForPress = true;
  } else if (
    _stableButton == BUTTON_STEPPER &&
    heldMillis >= FACTORY_RESET_HOLD_MS
  ) {
    _securityGesture = SecurityGesture::FactoryReset;
    _securityGestureFiredForPress = true;
  }
}

bool UserInterface::processSecurityFeedback() {
  if (_securityFeedbackPhase == SECURITY_FEEDBACK_NONE) return false;
  if (_securityFeedbackPhase == SECURITY_FEEDBACK_HOLD) return true;
  if (DeviceClock::milliseconds() - _securityFeedbackMillis < POWER_FRAME_MS) return true;

  _securityFeedbackMillis = DeviceClock::milliseconds();
  ++_securityFeedbackFrame;

  if (_securityFeedbackPhase == SECURITY_FEEDBACK_ON) {
    const uint8_t finalOnFrame = _securityFeedbackIsProvisioning ? 5 : 7;
    if (_securityFeedbackFrame <= finalOnFrame) {
      const uint8_t whiteMask = _securityFeedbackFrame >= 4
        ? 0x1F
        : static_cast<uint8_t>((1U << (_securityFeedbackFrame + 1)) - 1U);
      setDisplay(
        whiteMask,
        _securityFeedbackFrame >= 5 ? _securityFeedbackRgbMask : 0
      );
      return true;
    }
    if (_securityFeedbackIsProvisioning && _provisioningFeedbackActive) {
      _securityFeedbackPhase = SECURITY_FEEDBACK_HOLD;
      setDisplay(0x1F, _securityFeedbackRgbMask);
    } else {
      _securityFeedbackPhase = SECURITY_FEEDBACK_OFF;
      _securityFeedbackFrame = 0;
      setDisplay(0x1F, 0);
    }
    return true;
  }

  if (_securityFeedbackFrame < 5) {
    const uint8_t whiteMask = static_cast<uint8_t>(0x1F >> _securityFeedbackFrame);
    setDisplay(whiteMask, 0);
    return true;
  }

  const SecurityGesture completedGesture = _activeSecurityFeedbackGesture;
  _securityFeedbackPhase = SECURITY_FEEDBACK_NONE;
  turnDisplayOff();
  // Factory reset owns the blank display until its immediate reboot. Normal
  // provisioning completion must never leave the UI state machine latched.
  _securityDisplaySuppressed =
    completedGesture == SecurityGesture::FactoryReset;
  _completedSecurityFeedbackGesture = completedGesture;
  _activeSecurityFeedbackGesture = SecurityGesture::None;
  return true;
}

void UserInterface::remotePowerToggle() {
  ESP_LOGD(TAG, "REMOTE INPUT: POWER");
  togglePower(CommandOrigin::RfRemote);
}

void UserInterface::remoteMistToggle() {
  ESP_LOGD(TAG, "REMOTE INPUT: MIST");
  if (!isPowered() || _powerTransition != POWER_TRANSITION_NONE) {
    ESP_LOGD(TAG, "REMOTE IGNORED: system is off or transitioning");
    return;
  }

  if (!submitCommand(
        DeviceCommandType::SetMistMode,
        isMisterEnabled() ? 0 : 1,
        CommandOrigin::RfRemote
      )) {
    return;
  }
}

void UserInterface::remoteBreezeToggle() {
  ESP_LOGD(TAG, "REMOTE INPUT: BREEZE");
  if (!isPowered() || _powerTransition != POWER_TRANSITION_NONE) {
    ESP_LOGD(TAG, "REMOTE IGNORED: system is off or transitioning");
    return;
  }

  selectBreezeMode(
    nextAvailableBreezeMode(_controller.state().breezeMode),
    CommandOrigin::RfRemote
  );
}

void UserInterface::remoteAdjustFan(int8_t adjustment) {
  ESP_LOGD(TAG,
    "REMOTE INPUT: FAN %s\n",
    adjustment >= 0 ? "+" : "-"
  );
  if (!isPowered() || _powerTransition != POWER_TRANSITION_NONE) {
    ESP_LOGD(TAG, "REMOTE IGNORED: system is off or transitioning");
    return;
  }

  const int16_t adjustedLevel =
    _controller.state().targetFanSpeed + adjustment;
  submitCommand(
    DeviceCommandType::SetFanSpeed,
    std::clamp<int16_t>(adjustedLevel, 1, 5),
    CommandOrigin::RfRemote
  );
}

void UserInterface::remoteCycleOscillation() {
  ESP_LOGD(TAG, "REMOTE INPUT: OSCILLATE");
  if (!isPowered() || _powerTransition != POWER_TRANSITION_NONE) {
    ESP_LOGD(TAG, "REMOTE IGNORED: system is off or transitioning");
    return;
  }

  submitCommand(
    DeviceCommandType::SetOscillationMode,
    (_controller.state().oscillationMode + 1) % 4,
    CommandOrigin::RfRemote
  );
}

bool UserInterface::remoteSetDirection(DirectionRequest direction) {
  if (!isPowered()) {
    return false;
  }

  if (!submitCommand(
        DeviceCommandType::SetDirection,
        static_cast<int8_t>(direction),
        CommandOrigin::RfRemote
      )) {
    return false;
  }
  return true;
}

void UserInterface::handleCommandFeedback(
  DeviceCommandType type,
  int32_t value,
  CommandOrigin origin,
  bool stateChanged
) {
  ESP_LOGD(TAG,
    "COMMAND FEEDBACK: type=%u value=%ld origin=%u changed=%s\n",
    static_cast<unsigned>(type),
    static_cast<long>(value),
    static_cast<unsigned>(origin),
    stateChanged ? "YES" : "NO"
  );

  if (type == DeviceCommandType::SetPower) {
    if (stateChanged) {
      reconcilePowerState();
    }
    return;
  }

  if (_powerTransition != POWER_TRANSITION_NONE) {
    ESP_LOGD(TAG, "COMMAND FEEDBACK: power animation owns LEDs");
    return;
  }

  if (!isPowered()) {
    return;
  }

  registerUserInput();
  switch (type) {
    case DeviceCommandType::SetFanSpeed:
      _selectedDisplayView = PanelDisplayView::Fan;
      break;

    case DeviceCommandType::SetMistMode:
      _sprinklerFrame = 0;
      _sprinklerAnimationMillis = DeviceClock::milliseconds();
      _selectedDisplayView = isMisterEnabled()
        ? PanelDisplayView::Mist
        : PanelDisplayView::Fan;
      break;

    case DeviceCommandType::SetBreezeMode:
      if (stateChanged) {
        resetBreezeSequenceForCurrentMode();
      }
      _selectedDisplayView = isBreezeEnabled()
        ? PanelDisplayView::Breeze
        : PanelDisplayView::Fan;
      break;

    case DeviceCommandType::SetOscillationMode:
      _selectedDisplayView = oscillationMode() == 0
        ? PanelDisplayView::Fan
        : PanelDisplayView::Oscillation;
      break;

    case DeviceCommandType::SetDirection:
    case DeviceCommandType::SetOscillationPosition:
    case DeviceCommandType::SetTimerMinutes:
      // Manual positioning cancels automatic oscillation; retain the live fan
      // level. App-only timer changes likewise need no panel-only display.
      _selectedDisplayView = PanelDisplayView::Fan;
      break;

    case DeviceCommandType::ClearFaults:
      reconcilePowerState();
      break;

    case DeviceCommandType::SetPower:
      break;
  }
  updateNormalDisplay();
  printCurrentState();
}

void UserInterface::setSystemStatus(SystemStatus status) {
  if (status == _systemStatus) {
    return;
  }

  ESP_LOGD(TAG,
    "SYSTEM STATUS: %s -> %s\n",
    statusName(_systemStatus),
    statusName(status)
  );

  _systemStatus = status;
  _statusFlashOn = true;
  _statusFlashMillis = DeviceClock::milliseconds();
  _statusReportMillis = DeviceClock::milliseconds();

  if (status == STATUS_OK) {
    updateNormalDisplay();
  } else {
    updateStatusDisplay();
  }
}

void UserInterface::updateStatusDisplay() {
  const uint64_t now = DeviceClock::milliseconds();

  if (now - _statusReportMillis >= STATUS_REPORT_INTERVAL_MS) {
    _statusReportMillis = now;
    ESP_LOGE(TAG, "FAULT STILL ACTIVE: %s\n", statusName(_systemStatus));
  }

  const bool flashing =
    _systemStatus == STATUS_OSCILLATION_SEARCHING ||
    _systemStatus == STATUS_FAN_SPEED_LOW;

  if (
    flashing &&
    now - _statusFlashMillis >= STATUS_FLASH_INTERVAL_MS
  ) {
    _statusFlashMillis = now;
    _statusFlashOn = !_statusFlashOn;
  }

  uint8_t color = RGB_RED | RGB_GREEN;  // Yellow.

  if (
    _systemStatus == STATUS_FAN_NOT_TURNING ||
    _systemStatus == STATUS_HARDWARE_NO_START
  ) {
    color = RGB_RED;
  }

  setDisplay(0, flashing && !_statusFlashOn ? 0 : color);
}

uint8_t UserInterface::powerAnimationMask(uint8_t frame) {
  // Ramp LEDs 1..5 up, hold the peak for the RGB transition, then ramp down.
  static constexpr uint8_t frames[] = {
    0x01,
    0x03,
    0x07,
    0x0F,
    0x1F,
    0x1F,
    0x1F,
    0x0F,
    0x07,
    0x03,
    0x01
  };

  constexpr uint8_t frameCount = sizeof(frames) / sizeof(frames[0]);
  return frame < frameCount ? frames[frame] : 0x00;
}

uint8_t UserInterface::powerOffAnimationMask(uint8_t frame) {
  static constexpr uint8_t frames[] = {
    0x01,
    0x03,
    0x07,
    0x0F,
    0x1F,
    0x1F,
    0x1F,
    0x1F,
    0x0F,
    0x07,
    0x03,
    0x01
  };

  constexpr uint8_t frameCount = sizeof(frames) / sizeof(frames[0]);
  return frame < frameCount ? frames[frame] : 0x00;
}

uint8_t UserInterface::sprinklerMask(uint8_t frame) {
  static constexpr uint8_t frames[] = {
    0x01,
    0x03,
    0x07,
    0x0F,
    0x1F
  };

  return frames[frame % 5];
}

void UserInterface::setDisplay(uint8_t whiteMask, uint8_t rgbMask) {
  whiteMask &= 0x1F;
  rgbMask &= RGB_RED | RGB_GREEN | RGB_BLUE;
  if (_bootRgbActive && rgbMask == 0) {
    rgbMask = RGB_GREEN;
  }

  if (
    _displayHardwareEnabled &&
    _displayWriteConfirmed &&
    whiteMask == _currentWhiteMask &&
    rgbMask == _currentRgbMask
  ) {
    return;
  }

  _currentWhiteMask = whiteMask;
  _currentRgbMask = rgbMask;

  const bool acknowledged = _board.setDisplay(
    whiteMask,
    rgbMask,
    DISPLAY_BRIGHTNESS
  );

  _displayHardwareEnabled = true;
  _displayWriteConfirmed = acknowledged;

  if (!acknowledged) {
    ESP_LOGW(TAG, "WARNING: display write not acknowledged");
  }
}

void UserInterface::turnDisplayOff() {
  if (_bootRgbActive) {
    setDisplay(0, RGB_GREEN);
    return;
  }

  if (!_displayHardwareEnabled && _displayWriteConfirmed) {
    return;
  }

  const bool acknowledged = _board.displayOff();

  _displayHardwareEnabled = false;
  _currentWhiteMask = 0;
  _currentRgbMask = 0;
  _displayWriteConfirmed = acknowledged;

  if (!acknowledged) {
    ESP_LOGW(TAG, "WARNING: display-off not acknowledged");
  }
}

void UserInterface::retryDisplayWrite() {
  if (_displayWriteConfirmed ||
      DeviceClock::milliseconds() - _lastDisplayRetryMillis < BUTTON_POLL_INTERVAL_MS) {
    return;
  }
  _lastDisplayRetryMillis = DeviceClock::milliseconds();
  const bool acknowledged = _displayHardwareEnabled
    ? _board.setDisplay(
        _currentWhiteMask,
        _currentRgbMask,
        DISPLAY_BRIGHTNESS
      )
    : _board.displayOff();
  _displayWriteConfirmed = acknowledged;
  if (acknowledged) {
    ESP_LOGD(TAG, "DISPLAY: deferred state write acknowledged");
  }
}

void UserInterface::updateNormalDisplay() {
  if (!isPowered() || !_displayAwake) {
    turnDisplayOff();
    return;
  }

  uint8_t animatedWhiteMask = 0;
  if (_selectedDisplayView == PanelDisplayView::Mist) {
    animatedWhiteMask = sprinklerMask(_sprinklerFrame);
  } else if (_selectedDisplayView == PanelDisplayView::Breeze) {
    animatedWhiteMask = breezeMask();
  }

  const PanelDisplayIntent intent = normalPanelDisplayIntent(
    _controller.state(),
    _selectedDisplayView,
    animatedWhiteMask
  );
  if (!intent.enabled) {
    turnDisplayOff();
    return;
  }
  setDisplay(intent.whiteMask, intent.rgbMask);
}

void UserInterface::togglePower(CommandOrigin origin) {
  uint32_t *requestId = origin == CommandOrigin::RfRemote
    ? &_remoteRequestId
    : &_physicalRequestId;
  const CommandResult result = _controller.togglePower(
    {origin, ++(*requestId)}
  );
  if (result != CommandResult::Accepted) {
    ESP_LOGD(TAG,
      "POWER TOGGLE REJECTED: origin=%u result=%u\n",
      static_cast<unsigned>(origin),
      static_cast<unsigned>(result)
    );
    return;
  }
}

void UserInterface::reconcilePowerState() {
  if (isPowered() == _observedPower) {
    return;
  }
  if (isPowered()) {
    beginPowerOnAnimation();
  } else {
    beginPowerOffAnimation();
  }
}

void UserInterface::beginPowerOnAnimation() {
  _observedPower = true;
  // If RGB LED 6 already has a color, restore that color at the midpoint;
  // otherwise introduce green.
  _powerAnimationRgbMask =
    _displayHardwareEnabled && _currentRgbMask != 0
      ? _currentRgbMask
      : RGB_GREEN;

  _selectedDisplayView = PanelDisplayView::Fan;
  _displayAwake = true;
  _lastUserInputMillis = DeviceClock::milliseconds();

  _powerTransition = POWER_TRANSITION_ON;
  _powerAnimationFrame = 0;
  _powerAnimationMillis = DeviceClock::milliseconds();

  setDisplay(powerAnimationMask(0), 0);
  ESP_LOGI(TAG, "POWERING ON");
}

void UserInterface::beginPowerOffAnimation() {
  _observedPower = false;
  // Preserve LED 6's current color through the first half of shutdown.
  _powerAnimationRgbMask =
    _displayHardwareEnabled && _currentRgbMask != 0
      ? _currentRgbMask
      : RGB_GREEN;

  _powerTransition = POWER_TRANSITION_OFF;
  _displayAwake = true;
  _lastUserInputMillis = DeviceClock::milliseconds();

  _powerAnimationFrame = 0;
  _powerAnimationMillis = DeviceClock::milliseconds();

  setDisplay(powerOffAnimationMask(0), _powerAnimationRgbMask);
  ESP_LOGI(TAG, "POWERING OFF");
}

void UserInterface::processPowerAnimation() {
  if (_powerTransition == POWER_TRANSITION_NONE) {
    return;
  }

  if (DeviceClock::milliseconds() - _powerAnimationMillis < POWER_FRAME_MS) {
    return;
  }

  _powerAnimationMillis = DeviceClock::milliseconds();
  _powerAnimationFrame++;

  const bool poweringOn = _powerTransition == POWER_TRANSITION_ON;
  const uint8_t powerFrameCount = poweringOn ? 11 : 12;

  if (_powerAnimationFrame < powerFrameCount) {
    const uint8_t rgbMask = poweringOn
      ? (_powerAnimationFrame >= 5 ? _powerAnimationRgbMask : 0)
      : (_powerAnimationFrame < 5
          ? _powerAnimationRgbMask
          : (_powerAnimationFrame < 7 ? RGB_GREEN : 0));

    setDisplay(
      poweringOn
        ? powerAnimationMask(_powerAnimationFrame)
        : powerOffAnimationMask(_powerAnimationFrame),
      rgbMask
    );
    return;
  }

  if (_powerTransition == POWER_TRANSITION_ON) {
    _powerTransition = POWER_TRANSITION_NONE;
    // Startup finishes by showing the controller's authoritative fan level.
    _selectedDisplayView = PanelDisplayView::Fan;
    updateNormalDisplay();

    ESP_LOGD(TAG, "POWER ON: fan level %u\n", fanLevel());
  } else {
    _powerTransition = POWER_TRANSITION_NONE;

    _selectedDisplayView = PanelDisplayView::Fan;
    _displayAwake = false;

    turnDisplayOff();
    ESP_LOGI(TAG, "POWER OFF");
  }

  printCurrentState();
}

void UserInterface::processSprinklerAnimation() {
  if (
    !isPowered() ||
    !_displayAwake ||
    !isMisterEnabled() ||
    _selectedDisplayView != PanelDisplayView::Mist ||
    _powerTransition != POWER_TRANSITION_NONE
  ) {
    return;
  }

  if (DeviceClock::milliseconds() - _sprinklerAnimationMillis < SPRINKLER_FRAME_MS) {
    return;
  }

  _sprinklerAnimationMillis = DeviceClock::milliseconds();
  _sprinklerFrame = (_sprinklerFrame + 1) % 5;

  updateNormalDisplay();
}

void UserInterface::processBreezeSequence() {
  if (
    !isPowered() ||
    !isBreezeEnabled() ||
    _powerTransition != POWER_TRANSITION_NONE
  ) {
    return;
  }

  const uint64_t now = DeviceClock::milliseconds();
  bool displayChanged = false;
  bool segmentReady = true;

  if (
    _controller.state().breezeMode >= 2
  ) {
    if (!_breezeDwellStarted) {
      if (_fanSpeedConfirmed) {
        _breezeDwellStarted = true;
        _breezeStepMillis = now;
        ESP_LOGD(TAG,
          "BREEZE SPEED CONFIRMED: PWM=%u%%; dwell started\n",
          fanDutyPercent()
        );
      } else {
        segmentReady = false;
      }
    }
  }

  if (
    segmentReady &&
    now - _breezeStepMillis >= breezeStepDurationMs()
  ) {
    _breezeStepMillis = now;
    if (_controller.state().breezeMode == 1) {
      _breezeStep = (_breezeStep + 1) % 2;
    } else if (const CustomBreezeProfile *profile =
                 _breezeStore.profileForMode(_controller.state().breezeMode)) {
      _breezeStep = static_cast<uint8_t>(
        (_breezeStep + 1) % profile->segmentCount
      );
    } else {
      // After the displayed five-segment pattern, continue at segment 2 so
      // the matching first/last speeds do not merge into one double-long
      // segment at the loop boundary.
      _breezeStep = _breezeStep >= 4 ? 1 : _breezeStep + 1;
    }
    _fanSpeedConfirmed = false;
    _breezeDwellStarted = false;
    _controller.reportBreezeFanTarget(breezeFanLevel());
    displayChanged = true;
  }

  if (now - _breezeLedAnimationMillis >= BREEZE_LED_FRAME_MS) {
    _breezeLedAnimationMillis = now;
    _breezeLedFrame++;
    _breezePreviewLevel = previewLevelAt(
      now - _breezePreviewStartedMillis
    );
    displayChanged = true;
  }

  if (
    displayChanged &&
    _displayAwake &&
    _systemStatus == STATUS_OK &&
    _selectedDisplayView == PanelDisplayView::Breeze
  ) {
    updateNormalDisplay();
  }
}

void UserInterface::processDisplayTimeout() {
  if (
    !isPowered() ||
    !_displayAwake ||
    _powerTransition != POWER_TRANSITION_NONE
  ) {
    return;
  }

  if (!panelIntervalElapsed(
        DeviceClock::milliseconds(),
        _lastUserInputMillis,
        PANEL_DISPLAY_TIMEOUT_MS
      )) {
    return;
  }

  _displayAwake = false;
  turnDisplayOff();

  ESP_LOGI(TAG, "DISPLAY ASLEEP: 30 seconds without input");
  printCurrentState();
}

void UserInterface::processBootRgbTimeout() {
  if (
    !_bootRgbActive ||
    !panelIntervalElapsed(
      DeviceClock::milliseconds(),
      _bootRgbMillis,
      PANEL_BOOT_RGB_DURATION_MS
    )
  ) {
    return;
  }

  _bootRgbActive = false;
  if (_securityFeedbackPhase != SECURITY_FEEDBACK_NONE) {
    return;
  }
  if (_securityDisplaySuppressed) {
    turnDisplayOff();
  } else if (_powerTransition == POWER_TRANSITION_NONE) {
    if (_systemStatus == STATUS_OK) {
      updateNormalDisplay();
    } else {
      updateStatusDisplay();
    }
  }
  ESP_LOGD(TAG, "BOOT RGB: 10-second indication complete");
}

void UserInterface::registerUserInput() {
  _lastUserInputMillis = DeviceClock::milliseconds();

  if (!_displayAwake) {
    _displayAwake = true;
    _sprinklerFrame = 0;
    _sprinklerAnimationMillis = DeviceClock::milliseconds();

    ESP_LOGI(TAG, "DISPLAY AWAKE");
  }
}

void UserInterface::handleButtonPressed(uint8_t code) {
  ESP_LOGD(TAG, "PRESSED: %s (0x%02X)\n", buttonName(code), code);
  if (_provisioningFeedbackActive) {
    if (code == BUTTON_POWER) {
      // POWER exits provisioning but is consumed in that mode. A subsequent
      // fresh press is required to power on the appliance.
      _securityGesture = SecurityGesture::CancelProvisioning;
      _securityGestureFiredForPress = true;
      ESP_LOGI(TAG, "PAIRING: POWER requested provisioning exit");
    } else if (code == BUTTON_FAN) {
      ESP_LOGD(TAG, "PAIRING: hold FAN for five seconds to exit");
    } else {
      ESP_LOGD(TAG, "PAIRING: panel control disabled");
    }
    return;
  }
  // Any new deliberate interaction releases the post-security blank display.
  _securityDisplaySuppressed = false;

  if (_powerTransition != POWER_TRANSITION_NONE) {
    if (code == BUTTON_POWER) {
      // Power is a safety/control action, not an animation lockout. Reverse
      // the live state immediately and restart the display in that direction.
      togglePower(CommandOrigin::PhysicalUi);
    } else {
      ESP_LOGD(TAG, "IGNORED: power animation active");
    }
    return;
  }

  if (!isPowered()) {
    if (code == BUTTON_POWER) {
      togglePower(CommandOrigin::PhysicalUi);
    } else {
      ESP_LOGD(TAG, "IGNORED: system is off");
    }

    return;
  }

  switch (code) {
    case BUTTON_POWER:
      togglePower(CommandOrigin::PhysicalUi);
      break;

    case BUTTON_FAN:
      cyclePhysicalFan();
      break;

    case BUTTON_STEPPER:
      cyclePhysicalOscillation();
      break;

    case BUTTON_MISTER:
      // Defer this action until release so the ten-second recovery hold never
      // runs the mister before restarting the controller.
      break;
  }
}

void UserInterface::handleButtonReleased(uint8_t code, uint64_t heldMillis) {
  ESP_LOGD(TAG,
    "RELEASED: %s after %lu ms\n",
    buttonName(code),
    static_cast<unsigned long>(heldMillis)
  );
  const bool securityGestureFired = _securityGestureFiredForPress;
  _securityGestureFiredForPress = false;
  if (code == BUTTON_MISTER && !securityGestureFired && isPowered() &&
      heldMillis < RESTART_HOLD_MS) {
    submitCommand(
      DeviceCommandType::SetMistMode,
      isMisterEnabled() ? 0 : 1,
      CommandOrigin::PhysicalUi
    );
  }
}

void UserInterface::cyclePhysicalFan() {
  if (isBreezeEnabled()) {
    const uint8_t nextMode = nextAvailableBreezeMode(
      _controller.state().breezeMode
    );
    if (nextMode > _controller.state().breezeMode) {
      selectBreezeMode(
        nextMode,
        CommandOrigin::PhysicalUi
      );
    } else {
      submitCommand(
        DeviceCommandType::SetFanSpeed,
        1,
        CommandOrigin::PhysicalUi
      );
    }
  } else if (_controller.state().targetFanSpeed < 5) {
    submitCommand(
      DeviceCommandType::SetFanSpeed,
      _controller.state().targetFanSpeed + 1,
      CommandOrigin::PhysicalUi
    );
  } else {
    selectBreezeMode(1, CommandOrigin::PhysicalUi);
  }

}

void UserInterface::cyclePhysicalOscillation() {
  submitCommand(
    DeviceCommandType::SetOscillationMode,
    (oscillationMode() + 1) % 4,
    CommandOrigin::PhysicalUi
  );
}

void UserInterface::changeStableButton(uint8_t newButton) {
  uint64_t now = DeviceClock::milliseconds();

  if (_stableButton != 0) {
    handleButtonReleased(
      _stableButton,
      now - _buttonPressedMillis
    );
  }

  _stableButton = newButton;

  if (_stableButton != 0) {
    _buttonPressedMillis = now;
    _securityGestureFiredForPress = false;

    handleButtonPressed(_stableButton);
  }
}

void UserInterface::processButtonSample(uint8_t rawCode) {
  uint8_t detectedButton = isKnownButton(rawCode) ? rawCode : 0;

  if (detectedButton == _candidateButton) {
    if (_candidateSamples < BUTTON_DEBOUNCE_SAMPLES) {
      _candidateSamples++;
    }
  } else {
    _candidateButton = detectedButton;
    _candidateSamples = 1;
  }

  if (
    _candidateSamples >= BUTTON_DEBOUNCE_SAMPLES &&
    _candidateButton != _stableButton
  ) {
    changeStableButton(_candidateButton);
  }

}

void UserInterface::pollButtons() {
  static uint64_t previousPollMillis = 0;
  static bool previousAcknowledgement = true;

  if (DeviceClock::milliseconds() - previousPollMillis < BUTTON_POLL_INTERVAL_MS) {
    return;
  }

  previousPollMillis = DeviceClock::milliseconds();

  bool acknowledged = false;
  uint8_t rawCode = _board.readButtons(acknowledged);

  if (acknowledged != previousAcknowledgement) {
    previousAcknowledgement = acknowledged;

    ESP_LOGD(TAG,
      "AP1651 communication: %s\n",
      acknowledged ? "ACK" : "NO ACK"
    );
  }

  processButtonSample(acknowledged ? rawCode : 0);
}

bool UserInterface::isKnownButton(uint8_t code) {
  switch (code) {
    case BUTTON_POWER:
    case BUTTON_FAN:
    case BUTTON_STEPPER:
    case BUTTON_MISTER:
      return true;

    default:
      return false;
  }
}

const char *UserInterface::buttonName(uint8_t code) {
  switch (code) {
    case BUTTON_POWER:
      return "POWER";

    case BUTTON_FAN:
      return "FAN SPEED";

    case BUTTON_STEPPER:
      return "OSCILLATION";

    case BUTTON_MISTER:
      return "MISTER";

    default:
      return "UNKNOWN";
  }
}

const char *UserInterface::oscillationName() const {
  switch (oscillationMode()) {
    case 1:
      return "45 degrees";

    case 2:
      return "90 degrees";

    case 3:
      return "180 degrees";

    default:
      return "OFF";
  }
}

uint8_t UserInterface::breezeMask() const {
  // This is a deliberately compressed preview of the expected waveform, not
  // a real-time motor display. Every breeze loops through its complete shape
  // in the same steady 1.8-second animation window.
  return panelFanLevelMask(_breezePreviewLevel);
}

uint8_t UserInterface::previewLevelAt(uint32_t elapsedMs) const {
  const uint32_t normalized = elapsedMs % BREEZE_PREVIEW_CYCLE_MS;
  const uint8_t mode = _controller.state().breezeMode;
  if (mode == 1) return normalized < BREEZE_PREVIEW_CYCLE_MS / 2 ? 5 : 4;

  if (mode == 2 || mode == 3) {
    static constexpr uint8_t highFirst[] = {5, 3, 5, 3, 5};
    static constexpr uint8_t lowFirst[] = {3, 5, 3, 5, 3};
    const uint8_t index = static_cast<uint8_t>(
      normalized * 5U / BREEZE_PREVIEW_CYCLE_MS
    );
    return mode == 2 ? highFirst[index] : lowFirst[index];
  }

  const CustomBreezeProfile *profile = _breezeStore.profileForMode(mode);
  if (profile == nullptr) return _controller.state().targetFanSpeed;
  const uint32_t waveformSecond =
    normalized * profile->cycleSeconds / BREEZE_PREVIEW_CYCLE_MS;
  uint32_t cursor = 0;
  for (uint8_t index = 0; index < profile->segmentCount; ++index) {
    cursor += profile->segments[index].durationSeconds;
    if (waveformSecond < cursor) return profile->segments[index].level;
  }
  return profile->segments[profile->segmentCount - 1].level;
}

uint8_t UserInterface::nextAvailableBreezeMode(uint8_t currentMode) const {
  for (uint8_t mode = static_cast<uint8_t>(currentMode + 1);
       mode <= CUSTOM_BREEZE_LAST_MODE; ++mode) {
    if (mode <= 3 || _breezeStore.hasMode(mode)) return mode;
  }
  return 1;
}

uint32_t UserInterface::breezeStepDurationMs() const {
  if (_controller.state().breezeMode == 1) {
    return BREEZE_LONG_STEP_MS;
  }

  if (const CustomBreezeProfile *profile =
        _breezeStore.profileForMode(_controller.state().breezeMode)) {
    return static_cast<uint32_t>(
      profile->segments[_breezeStep % profile->segmentCount].durationSeconds
    ) * 1000U;
  }

  // Both five-step modes alternate long/short durations. Because their fan
  // levels are opposites, mode 2 emphasizes high speed while mode 3
  // emphasizes mid speed.
  return (_breezeStep % 2) == 0
    ? BREEZE_LONG_STEP_MS
    : BREEZE_SHORT_STEP_MS;
}

void UserInterface::selectBreezeMode(uint8_t mode, CommandOrigin origin) {
  if (mode > 3 && !_breezeStore.hasMode(mode)) return;
  submitCommand(
    DeviceCommandType::SetBreezeMode,
    std::clamp<uint8_t>(mode, 0, CUSTOM_BREEZE_LAST_MODE),
    origin
  );
}

void UserInterface::resetBreezeSequenceForCurrentMode() {
  _breezeStep = 0;
  _breezeLedFrame = 0;
  _breezePreviewLevel = previewLevelAt(0);
  _fanSpeedConfirmed = false;
  _breezeDwellStarted = false;
  _breezeStepMillis = DeviceClock::milliseconds();
  _breezeLedAnimationMillis = DeviceClock::milliseconds();
  _breezePreviewStartedMillis = _breezeLedAnimationMillis;
  if (isBreezeEnabled()) {
    _controller.reportBreezeFanTarget(breezeFanLevel());
  }
}

const char *UserInterface::breezeName() const {
  switch (_controller.state().breezeMode) {
    case 1: return "pulsing high";
    case 2: return "high-mid-high-mid-high";
    case 3: return "mid-high-mid-high-mid";
    case 4: case 5: case 6: {
      const CustomBreezeProfile *profile = _breezeStore.profileForMode(
        _controller.state().breezeMode
      );
      return profile == nullptr ? "custom unavailable" : profile->name;
    }
    default: return "OFF";
  }
}

bool UserInterface::submitCommand(
  DeviceCommandType type,
  int32_t value,
  CommandOrigin origin
) {
  uint32_t *requestId = origin == CommandOrigin::RfRemote
    ? &_remoteRequestId
    : &_physicalRequestId;
  const DeviceCommand command = {
    type,
    value,
    {origin, ++(*requestId)}
  };
  const CommandResult result = _controller.submit(command);
  if (
    result == CommandResult::Accepted ||
    result == CommandResult::NoChange
  ) {
    return true;
  }
  ESP_LOGD(TAG,
    "COMMAND REJECTED: type=%u origin=%u result=%u\n",
    static_cast<unsigned>(type),
    static_cast<unsigned>(origin),
    static_cast<unsigned>(result)
  );
  return false;
}

const char *UserInterface::statusName(SystemStatus status) {
  switch (status) {
    case STATUS_OSCILLATION_SEARCHING:
      return "passive oscillation home search";
    case STATUS_FAN_SPEED_LOW:
      return "fan speed low";
    case STATUS_OSCILLATION_SAFETY_FAULT:
      return "oscillation safety fault";
    case STATUS_FAN_SPEED_HIGH:
      return "fan speed high";
    case STATUS_FAN_NOT_TURNING:
      return "fan not turning";
    case STATUS_HARDWARE_NO_START:
      return "hardware no-start";
    case STATUS_OK:
    default:
      return "normal";
  }
}

void UserInterface::printCurrentState() const {
  ESP_LOGD(TAG,
    "STATE: power=%s fan=%u oscillation=%s mister=%s breeze=%s display=%s\n",
    isPowered() ? "ON" : "OFF",
    fanLevel(),
    oscillationName(),
    isMisterEnabled() ? "ON" : "OFF",
    breezeName(),
    _displayHardwareEnabled ? "ON" : "OFF"
  );
}

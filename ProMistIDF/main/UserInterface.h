#pragma once

// Local-first panel policy and display state machine. All user actions become
// DeviceController commands so local and network control share validation.

#include <cstdint>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "AP1651.h"
#include "CustomBreezeStore.h"
#include "DeviceController.h"
#include "PanelDisplayPolicy.h"
#include "SystemStatus.h"

/**
 * Translates retained panel/RF input into DeviceController commands and renders
 * controller state, animations, faults, and security feedback on the AP1651.
 */
class UserInterface {
 public:
  enum class SecurityGesture : uint8_t {
    None,
    Provision,
    CancelProvisioning,
    FactoryReset,
    Restart
  };
  UserInterface(
    AP1651 &board,
    DeviceController &controller,
    CustomBreezeStore &breezeStore
  );

  /** Creates the command-feedback queue and initializes the retained panel. */
  void begin();
  /** Polls input and advances display, animation, and gesture state machines. */
  void update();

  bool isPowered() const;
  bool isFanOutputEnabled() const;
  uint8_t fanLevel() const;
  uint8_t fanDutyPercent() const;
  uint8_t oscillationMode() const;
  bool isMisterEnabled() const;
  bool isBreezeEnabled() const;
  void setSystemStatus(SystemStatus status);
  void setFanSpeedConfirmed(bool confirmed);
  /** Returns and clears one completed physical security gesture. */
  SecurityGesture consumeSecurityGesture();
  /** Returns and clears the gesture whose panel feedback animation finished. */
  SecurityGesture consumeCompletedSecurityFeedback();
  /** Starts the panel confirmation sequence for a physical security action. */
  void showSecurityFeedback(SecurityGesture gesture);
  /** Reflects the bounded owner-enrollment window on the panel. */
  void updateProvisioningFeedback(bool provisioning);

  /** Converts one decoded RF power action into a sequenced controller command. */
  void remotePowerToggle();
  void remoteMistToggle();
  void remoteBreezeToggle();
  void remoteAdjustFan(int8_t adjustment);
  void remoteCycleOscillation();
  /**
   * Submits a home or jog action from RF input.
   * @return false when the direction is invalid or the command is rejected.
   */
  bool remoteSetDirection(DirectionRequest direction);

 private:
  struct QueuedCommandFeedback {
    DeviceCommand command;
    CommandResult result;
  };

  enum SecurityFeedbackPhase : uint8_t { SECURITY_FEEDBACK_NONE,
    SECURITY_FEEDBACK_ON, SECURITY_FEEDBACK_HOLD, SECURITY_FEEDBACK_OFF };
  enum PowerTransition {
    POWER_TRANSITION_NONE,
    POWER_TRANSITION_ON,
    POWER_TRANSITION_OFF
  };

  static constexpr uint8_t BUTTON_POWER = 0xF2;
  static constexpr uint8_t BUTTON_FAN = 0xF5;
  static constexpr uint8_t BUTTON_STEPPER = 0xF7;
  static constexpr uint8_t BUTTON_MISTER = 0xF6;

  static constexpr uint8_t RGB_RED = 0x08;
  static constexpr uint8_t RGB_GREEN = 0x10;
  static constexpr uint8_t RGB_BLUE = 0x20;

  static constexpr uint8_t DISPLAY_BRIGHTNESS = 7;

  static constexpr uint32_t BUTTON_POLL_INTERVAL_MS = 20;
  static constexpr uint8_t BUTTON_DEBOUNCE_SAMPLES = 3;

  static constexpr uint32_t POWER_FRAME_MS = 120;
  static constexpr uint32_t SPRINKLER_FRAME_MS = 150;
  static constexpr uint32_t BREEZE_LED_FRAME_MS = SPRINKLER_FRAME_MS / 2;
  static constexpr uint32_t BREEZE_PREVIEW_CYCLE_MS = 1800;
  static constexpr uint32_t BREEZE_LONG_STEP_MS = 2000;
  static constexpr uint32_t BREEZE_SHORT_STEP_MS = 1000;
  static constexpr uint32_t STATUS_FLASH_INTERVAL_MS = 500;
  static constexpr uint32_t STATUS_REPORT_INTERVAL_MS = 5000;
  static constexpr uint32_t PROVISION_HOLD_MS = 5000;
  static constexpr uint32_t FACTORY_RESET_HOLD_MS = 10000;
  static constexpr uint32_t RESTART_HOLD_MS = 10000;

  AP1651 &_board;
  DeviceController &_controller;
  CustomBreezeStore &_breezeStore;
  QueueHandle_t _commandFeedbackQueue = nullptr;

  bool _displayAwake = false;
  bool _bootRgbActive = false;
  PanelDisplayView _selectedDisplayView = PanelDisplayView::Fan;
  PowerTransition _powerTransition = POWER_TRANSITION_NONE;

  uint64_t _lastUserInputMillis = 0;
  uint64_t _bootRgbMillis = 0;
  uint64_t _powerAnimationMillis = 0;
  uint64_t _sprinklerAnimationMillis = 0;
  uint64_t _breezeLedAnimationMillis = 0;
  uint64_t _breezePreviewStartedMillis = 0;
  uint64_t _breezeStepMillis = 0;

  uint8_t _powerAnimationFrame = 0;
  uint8_t _powerAnimationRgbMask = 0;
  uint8_t _sprinklerFrame = 0;
  uint8_t _breezeLedFrame = 0;
  uint8_t _breezePreviewLevel = 1;
  uint8_t _breezeStep = 0;
  bool _fanSpeedConfirmed = false;
  bool _breezeDwellStarted = false;

  uint8_t _stableButton = 0;
  uint8_t _candidateButton = 0;
  uint8_t _candidateSamples = 0;

  uint64_t _buttonPressedMillis = 0;

  uint8_t _currentWhiteMask = 0;
  uint8_t _currentRgbMask = 0;
  bool _displayHardwareEnabled = false;
  bool _displayWriteConfirmed = true;
  uint64_t _lastDisplayRetryMillis = 0;
  bool _observedPower = false;
  SystemStatus _systemStatus = STATUS_OK;
  bool _statusFlashOn = true;
  uint64_t _statusFlashMillis = 0;
  uint64_t _statusReportMillis = 0;
  uint32_t _physicalRequestId = 0;
  uint32_t _remoteRequestId = 0;
  SecurityGesture _securityGesture = SecurityGesture::None;
  SecurityGesture _activeSecurityFeedbackGesture = SecurityGesture::None;
  SecurityGesture _completedSecurityFeedbackGesture = SecurityGesture::None;
  bool _securityGestureFiredForPress = false;
  SecurityFeedbackPhase _securityFeedbackPhase = SECURITY_FEEDBACK_NONE;
  uint64_t _securityFeedbackMillis = 0;
  uint8_t _securityFeedbackFrame = 0;
  uint8_t _securityFeedbackRgbMask = 0;
  bool _securityDisplaySuppressed = false;
  bool _provisioningFeedbackActive = false;
  bool _securityFeedbackIsProvisioning = false;

  void pollButtons();
  static void commandCompleted(
    const DeviceCommand &command,
    CommandResult result,
    void *context
  );
  void processCommandFeedback();
  void handleCommandFeedback(
    DeviceCommandType type,
    int32_t value,
    CommandOrigin origin,
    bool stateChanged
  );
  void processSecurityGestureHold();
  bool processSecurityFeedback();
  void processButtonSample(uint8_t rawCode);
  void changeStableButton(uint8_t newButton);

  void handleButtonPressed(uint8_t code);
  void handleButtonReleased(uint8_t code, uint64_t heldMillis);

  void registerUserInput();

  void togglePower(CommandOrigin origin);
  void reconcilePowerState();
  void beginPowerOnAnimation();
  void beginPowerOffAnimation();
  void processPowerAnimation();
  void processSprinklerAnimation();
  void processBreezeSequence();
  void processDisplayTimeout();
  void processBootRgbTimeout();
  void cyclePhysicalOscillation();
  void cyclePhysicalFan();

  void updateNormalDisplay();
  void updateStatusDisplay();
  void setDisplay(uint8_t whiteMask, uint8_t rgbMask);
  void turnDisplayOff();
  void retryDisplayWrite();

  uint8_t breezeFanLevel() const;
  uint8_t breezeMask() const;
  uint8_t previewLevelAt(uint32_t elapsedMs) const;
  uint8_t nextAvailableBreezeMode(uint8_t currentMode) const;
  uint32_t breezeStepDurationMs() const;
  static uint8_t powerAnimationMask(uint8_t frame);
  static uint8_t powerOffAnimationMask(uint8_t frame);
  static uint8_t sprinklerMask(uint8_t frame);

  static bool isKnownButton(uint8_t code);
  static const char *buttonName(uint8_t code);
  static const char *statusName(SystemStatus status);
  const char *oscillationName() const;
  const char *breezeName() const;
  void selectBreezeMode(uint8_t mode, CommandOrigin origin);
  void resetBreezeSequenceForCurrentMode();
  bool submitCommand(
    DeviceCommandType type,
    int32_t value,
    CommandOrigin origin
  );
  void printCurrentState() const;
};

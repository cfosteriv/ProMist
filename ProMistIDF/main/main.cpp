// ESP-IDF composition root and cooperative loop. This file wires transports,
// domain state, hardware adapters, and diagnostics without duplicating policy.
#include "AP1651.h"
#include "BleManager.h"
#include "CustomBreezeStore.h"
#include "DeviceClock.h"
#include "DeviceController.h"
#include "DiagnosticLog.h"
#include "EspMatterFanEndpoint.h"
#include "FanMotor.h"
#include "FaultHistoryStore.h"
#include "MisterPump.h"
#include "OscillationController.h"
#include "RemoteControl.h"
#include "UserInterface.h"
#include <driver/gpio.h>
#include <esp_log.h>
#include <esp_mac.h>
#include <esp_system.h>
#include <esp_task_wdt.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <freertos/task.h>
#include <nvs_flash.h>

#ifndef PROMIST_FIRMWARE_VERSION
#define PROMIST_FIRMWARE_VERSION "1.0"
#endif

namespace {
constexpr char TAG[] = "ProMist";
constexpr uint32_t APPLICATION_TASK_STACK_SIZE = 12288;
constexpr UBaseType_t APPLICATION_TASK_PRIORITY = 5;
}

constexpr uint8_t AP1651_CLK_PIN = 23;
constexpr uint8_t AP1651_DIO_PIN = 22;

constexpr uint8_t REMOTE_WAKE_PIN = 19;
constexpr uint8_t REMOTE_RF_PIN = 21;

// GPIO25 is an internal RF-switch control on ESP32-WROOM-DA. Driving fan PWM
// there disables/corrupts the selected antenna and makes BLE unusable.
constexpr uint8_t FAN_PWM_PIN = 14;
constexpr uint8_t FAN_FG_PIN = 27;
static_assert(
  FAN_PWM_PIN != 2 && FAN_PWM_PIN != 25,
  "ESP32-WROOM-DA reserves GPIO2/GPIO25 for its RF antenna switch"
);

constexpr uint8_t PUMP_PIN = 18;

constexpr uint8_t OSCILLATION_IN1_PIN = 33;
constexpr uint8_t OSCILLATION_IN2_PIN = 32;
constexpr uint8_t OSCILLATION_IN3_PIN = 15;
constexpr uint8_t OSCILLATION_IN4_PIN = 13;
constexpr uint8_t OSCILLATION_HALL_PIN = 26;

AP1651 uiBoard(AP1651_CLK_PIN, AP1651_DIO_PIN);
DeviceController deviceController;
EspMatterFanEndpoint matterEndpoint(deviceController);
DiagnosticLog diagnosticLog;
FaultHistoryStore faultHistoryStore(diagnosticLog);
CustomBreezeStore customBreezeStore;
UserInterface userInterface(uiBoard, deviceController, customBreezeStore);
BleManager bleManager(deviceController, diagnosticLog, customBreezeStore);
FanMotor fanMotor(FAN_PWM_PIN, FAN_FG_PIN);
MisterPump misterPump(PUMP_PIN);
OscillationController oscillationController(
  OSCILLATION_IN1_PIN,
  OSCILLATION_IN2_PIN,
  OSCILLATION_IN3_PIN,
  OSCILLATION_IN4_PIN,
  OSCILLATION_HALL_PIN
);
RemoteControl remoteControl(REMOTE_RF_PIN, REMOTE_WAKE_PIN);
SystemStatus lastLoggedFanStatus = STATUS_OK;
SystemStatus lastLoggedOscillationStatus = STATUS_OK;
bool lastLoggedOscillationSearching = false;
QueueHandle_t orientationCommandQueue = nullptr;
bool timerParkingStarted = false;
bool applicationWatchdogRegistered = false;
uint64_t timerParkingStartedMs = 0;
constexpr uint32_t TIMER_PARK_TIMEOUT_MS = 30000;

void synchronizeBleProvisioningState() {
  const bool active = bleManager.isProvisioning();
  deviceController.setBleProvisioningActive(active);
  userInterface.updateProvisioningFeedback(active);
}

void routeHardwareCommand(
  const DeviceCommand &command,
  CommandResult result,
  void *
) {
  if (
    result != CommandResult::Accepted ||
    (command.type != DeviceCommandType::SetDirection &&
      command.type != DeviceCommandType::SetOscillationPosition) ||
    orientationCommandQueue == nullptr
  ) return;

  // New orientation actions supersede older ones. Commands for independent
  // subsystems never enter this queue and therefore do not disturb motion.
  xQueueOverwrite(orientationCommandQueue, &command);
}

void applyLatestOrientationCommand() {
  if (orientationCommandQueue == nullptr) return;
  DeviceCommand command;
  if (xQueueReceive(orientationCommandQueue, &command, 0) != pdTRUE) return;
  if (!deviceController.state().power) return;

  if (command.type == DeviceCommandType::SetOscillationPosition) {
    oscillationController.requestPreset(static_cast<int8_t>(command.value));
    return;
  }
  const DirectionRequest direction =
    static_cast<DirectionRequest>(command.value);
  if (direction == DirectionRequest::Home) {
    oscillationController.requestParkHome();
  } else {
    oscillationController.requestJog(
      direction == DirectionRequest::ClockwiseJog ? 1 : -1
    );
  }
}

void logDiagnostic(
  DiagnosticEventId eventId,
  int32_t first = 0,
  int32_t second = 0
) {
  if (!diagnosticLog.append(
        DeviceClock::protocolMilliseconds(),
        eventId,
        first,
        second
      )) {
    ESP_LOGW(
      TAG,
      "Diagnostic rejected: event=%u",
      static_cast<unsigned>(eventId)
    );
    return;
  }
  const DiagnosticLogMetadata metadata = diagnosticLog.metadata();
  ESP_LOGD(
    TAG,
    "Diagnostic: seq=%lu uptime_ms=%lu event=%u a=%ld b=%ld",
    static_cast<unsigned long>(metadata.newestSequence),
    static_cast<unsigned long>(DeviceClock::protocolMilliseconds()),
    static_cast<unsigned>(eventId),
    static_cast<long>(first),
    static_cast<long>(second)
  );
}

ResetReason currentResetReason() {
  switch (esp_reset_reason()) {
    case ESP_RST_POWERON: return ResetReason::PowerOn;
    case ESP_RST_SW: return ResetReason::Software;
    case ESP_RST_PANIC:
    case ESP_RST_INT_WDT:
    case ESP_RST_TASK_WDT:
    case ESP_RST_WDT: return ResetReason::Watchdog;
    case ESP_RST_BROWNOUT: return ResetReason::Brownout;
    case ESP_RST_EXT: return ResetReason::External;
    default: return ResetReason::Unknown;
  }
}

DeviceFault toDeviceFault(SystemStatus status) {
  return static_cast<DeviceFault>(status);
}

void logStatusTransitions(
  SystemStatus fanStatus,
  SystemStatus oscillationStatus,
  bool oscillationSearching
) {
  if (
    lastLoggedOscillationSearching &&
    !oscillationSearching
  ) {
    logDiagnostic(DiagnosticEventId::OscillationSearching, 1, 0);
  }

  if (fanStatus != lastLoggedFanStatus) {
    switch (fanStatus) {
      case STATUS_FAN_SPEED_LOW:
      case STATUS_FAN_SPEED_HIGH:
      case STATUS_FAN_NOT_TURNING:
        logDiagnostic(
          DiagnosticEventId::FanTargetObservedMismatch,
          deviceController.state().targetFanSpeed,
          static_cast<int32_t>(fanStatus)
        );
        break;
      case STATUS_HARDWARE_NO_START:
        logDiagnostic(
          DiagnosticEventId::MotorStartFailure,
          static_cast<int32_t>(fanStatus),
          0
        );
        break;
      default:
        break;
    }
  }

  if (
    oscillationSearching &&
    !lastLoggedOscillationSearching
  ) {
    logDiagnostic(DiagnosticEventId::OscillationSearching, 0, 1);
  }
  if (
    oscillationStatus != lastLoggedOscillationStatus &&
    oscillationStatus == STATUS_OSCILLATION_SAFETY_FAULT
  ) {
    logDiagnostic(
      DiagnosticEventId::OscillationSafetyFault,
      static_cast<int32_t>(oscillationStatus),
      0
    );
  }
  lastLoggedFanStatus = fanStatus;
  lastLoggedOscillationStatus = oscillationStatus;
  lastLoggedOscillationSearching = oscillationSearching;
}

void handleRemoteCommand(RemoteCommand command) {
  if (command == REMOTE_NONE) {
    return;
  }

  if (deviceController.bleProvisioningActive()) {
    ESP_LOGD(
      TAG,
      "Remote ignored during BLE provisioning: %s",
      RemoteControl::commandName(command)
    );
    return;
  }

  ESP_LOGD(
    TAG,
    "Remote recognized: %s",
    RemoteControl::commandName(command)
  );

  switch (command) {
    case REMOTE_POWER:
      userInterface.remotePowerToggle();
      break;

    case REMOTE_MIST:
      userInterface.remoteMistToggle();
      break;

    case REMOTE_BREEZE:
      userInterface.remoteBreezeToggle();
      break;

    case REMOTE_OSCILLATE:
      userInterface.remoteCycleOscillation();
      break;

    case REMOTE_FAN_MINUS:
      userInterface.remoteAdjustFan(-1);
      break;

    case REMOTE_FAN_PLUS:
      userInterface.remoteAdjustFan(1);
      break;

    case REMOTE_FORWARD:
      if (!userInterface.isPowered()) {
        ESP_LOGD(TAG, "Remote forward ignored: system is off");
        break;
      }
      userInterface.remoteSetDirection(DirectionRequest::Home);
      break;

    case REMOTE_CW_JOG:
      if (!userInterface.isPowered()) {
        ESP_LOGD(TAG, "Remote clockwise jog ignored: system is off");
        break;
      }
      userInterface.remoteSetDirection(DirectionRequest::ClockwiseJog);
      break;

    case REMOTE_CCW_JOG:
      if (!userInterface.isPowered()) {
        ESP_LOGD(TAG, "Remote counterclockwise jog ignored: system is off");
        break;
      }
      userInterface.remoteSetDirection(
        DirectionRequest::CounterClockwiseJog
      );
      break;

    case REMOTE_NONE:
    default:
      break;
  }
}

bool initializePlatform() {
  esp_err_t nvsResult = nvs_flash_init();
  if (nvsResult == ESP_ERR_NVS_NO_FREE_PAGES ||
      nvsResult == ESP_ERR_NVS_NEW_VERSION_FOUND) {
    ESP_LOGW(
      TAG,
      "NVS requires defined recovery (%s); erasing runtime partition",
      esp_err_to_name(nvsResult)
    );
    nvsResult = nvs_flash_erase();
    if (nvsResult == ESP_OK) nvsResult = nvs_flash_init();
  }
  if (nvsResult != ESP_OK) {
    ESP_LOGE(TAG, "NVS initialization failed: %s", esp_err_to_name(nvsResult));
    return false;
  }

  const esp_err_t isrResult = gpio_install_isr_service(ESP_INTR_FLAG_IRAM);
  if (isrResult != ESP_OK && isrResult != ESP_ERR_INVALID_STATE) {
    ESP_LOGE(TAG, "GPIO ISR service initialization failed: %s", esp_err_to_name(isrResult));
    return false;
  }
  return true;
}

bool initializeApplication() {
  if (!initializePlatform()) return false;

  uint8_t baseMac[6] = {};
  const esp_err_t macResult = esp_efuse_mac_get_default(baseMac);
  if (macResult != ESP_OK) {
    ESP_LOGE(TAG, "Hardware identity unavailable: %s", esp_err_to_name(macResult));
    return false;
  }
  uint64_t deviceId = 0;
  for (uint8_t byte : baseMac) {
    deviceId = (deviceId << 8) | byte;
  }
  const ResetReason resetReason = currentResetReason();
  deviceController.initializeIdentity(deviceId, PROMIST_FIRMWARE_VERSION);
  orientationCommandQueue = xQueueCreate(1, sizeof(DeviceCommand));
  if (
    orientationCommandQueue == nullptr ||
    !deviceController.addCommandObserver(routeHardwareCommand, nullptr)
  ) {
    ESP_LOGE(TAG, "Command router unavailable: orientation actions disabled");
  }
  deviceController.reportSystemInfo(DeviceClock::protocolSeconds(), resetReason);
  faultHistoryStore.begin();
  customBreezeStore.begin();
  logDiagnostic(
    DiagnosticEventId::Boot,
    2,
    0
  );
  logDiagnostic(
    DiagnosticEventId::ResetReason,
    static_cast<int32_t>(resetReason),
    0
  );

  uiBoard.begin();
  userInterface.begin();
  fanMotor.begin();
  misterPump.begin();
  const bool trustPersistedOscillationReference =
    resetReason == ResetReason::PowerOn ||
    resetReason == ResetReason::Software ||
    resetReason == ResetReason::External;
  oscillationController.begin(trustPersistedOscillationReference);
  remoteControl.begin();
  if (!bleManager.begin()) {
    ESP_LOGW(TAG, "BLE unavailable; local panel, RF, motors, and safety remain active");
  }
  if (!matterEndpoint.begin()) {
    ESP_LOGE(TAG, "Matter fan endpoint initialization failed");
  } else {
    bleManager.setMatterOnboardingPayload(matterEndpoint.manualPairingCode());
  }
  const esp_err_t watchdogResult = esp_task_wdt_add(nullptr);
  applicationWatchdogRegistered = watchdogResult == ESP_OK;
  if (!applicationWatchdogRegistered) {
    ESP_LOGW(TAG, "Application watchdog registration failed: %s", esp_err_to_name(watchdogResult));
  }
  ESP_LOGI(TAG, "Native ESP-IDF application initialized");
  return true;
}

void applicationCycle() {
  // Detect a provisioning timeout before accepting input from any external
  // control surface in this cycle.
  synchronizeBleProvisioningState();
  handleRemoteCommand(remoteControl.update());
  userInterface.update();
  const UserInterface::SecurityGesture securityGesture =
    userInterface.consumeSecurityGesture();
  if (securityGesture == UserInterface::SecurityGesture::Restart) {
    ESP_LOGW(TAG, "Recovery gesture: restarting ESP32");
    vTaskDelay(pdMS_TO_TICKS(50));
    esp_restart();
    return;
  } else if (securityGesture == UserInterface::SecurityGesture::Provision) {
    if (bleManager.enterProvisioning()) {
      userInterface.showSecurityFeedback(securityGesture);
    }
    synchronizeBleProvisioningState();
  } else if (
    securityGesture == UserInterface::SecurityGesture::CancelProvisioning
  ) {
    bleManager.cancelProvisioning();
    synchronizeBleProvisioningState();
  } else if (securityGesture == UserInterface::SecurityGesture::FactoryReset) {
    userInterface.showSecurityFeedback(securityGesture);
    ESP_LOGW(TAG, "Recovery animation started; reset deferred");
  }
  const UserInterface::SecurityGesture completedSecurityFeedback =
    userInterface.consumeCompletedSecurityFeedback();
  if (
    completedSecurityFeedback ==
    UserInterface::SecurityGesture::FactoryReset
  ) {
    ESP_LOGW(TAG, "Recovery animation complete; starting full persistent reset");
    matterEndpoint.factoryResetAndRestart();
  }
  bleManager.update();
  // A successful owner exchange closes the window inside bleManager.update().
  // Release both the command gate and panel feedback before Matter is serviced.
  synchronizeBleProvisioningState();
  matterEndpoint.update();

  deviceController.updateTimer(DeviceClock::protocolSeconds());
  if (deviceController.timerShutdownPending() && !timerParkingStarted) {
    timerParkingStarted = true;
    timerParkingStartedMs = DeviceClock::milliseconds();
    oscillationController.requestParkHome();
  } else if (!deviceController.timerShutdownPending()) {
    timerParkingStarted = false;
  }

  applyLatestOrientationCommand();

  const bool localOutputsEnabled = deviceController.state().power;

  fanMotor.update(
    localOutputsEnabled,
    userInterface.fanLevel(),
    userInterface.fanDutyPercent()
  );
  userInterface.setFanSpeedConfirmed(fanMotor.speedConfirmed());
  deviceController.reportFanSpeedConfirmed(fanMotor.speedConfirmed());

  misterPump.update(
    localOutputsEnabled &&
    deviceController.state().mistMode != 0
  );

  oscillationController.update(
    localOutputsEnabled,
    localOutputsEnabled ? deviceController.state().oscillationMode : 0
  );
  deviceController.reportOscillationPosition(
    oscillationController.currentPreset()
  );
  deviceController.reportOscillationMotion(
    oscillationController.isPositioning(),
    oscillationController.targetPreset()
  );

  if (deviceController.timerShutdownPending()) {
    const bool parked = oscillationController.isHomed() &&
      oscillationController.currentPreset() == 0 &&
      !oscillationController.isPositioning();
    const bool parkTimedOut =
      DeviceClock::milliseconds() - timerParkingStartedMs >=
        TIMER_PARK_TIMEOUT_MS;
    if (parked || parkTimedOut) {
      deviceController.completeTimerShutdown();
      timerParkingStarted = false;
    }
  }

  const SystemStatus systemStatus = moreSevereStatus(
    fanMotor.status(),
    oscillationController.status()
  );
  userInterface.setSystemStatus(systemStatus);
  deviceController.reportFault(toDeviceFault(systemStatus));
  logStatusTransitions(
    fanMotor.status(),
    oscillationController.status(),
    oscillationController.isSearching()
  );
  deviceController.reportSystemInfo(
    DeviceClock::protocolSeconds(),
    deviceController.state().resetReason
  );
  faultHistoryStore.update();

  // Future non-blocking controllers belong here:
  // homeKit.update();

  if (applicationWatchdogRegistered) {
    const esp_err_t watchdogResult = esp_task_wdt_reset();
    if (watchdogResult != ESP_OK) {
      applicationWatchdogRegistered = false;
      ESP_LOGE(TAG, "Application watchdog reset failed: %s", esp_err_to_name(watchdogResult));
    }
  }

  // The application task runs on CPU 1 while Matter/Wi-Fi/BLE run on CPU 0.
  // Give CPU 1's
  // idle task one scheduler tick so the task watchdog can run normally. A
  // 1 ms delay remains well below the oscillation controller's 3 ms step
  // interval and avoids watchdog interrupts during Matter commissioning.
  vTaskDelay(pdMS_TO_TICKS(1));
}

void applicationTask(void *) {
  if (!initializeApplication()) {
    ESP_LOGE(TAG, "Initialization failed; application task stopped safely");
    vTaskDelete(nullptr);
    return;
  }
  while (true) applicationCycle();
}

extern "C" void app_main(void) {
  const BaseType_t created = xTaskCreatePinnedToCore(
    applicationTask,
    "promist_app",
    APPLICATION_TASK_STACK_SIZE,
    nullptr,
    APPLICATION_TASK_PRIORITY,
    nullptr,
    1
  );
  if (created != pdPASS) {
    ESP_LOGW(TAG, "Dedicated application task allocation failed; using main task");
    applicationTask(nullptr);
  }
}

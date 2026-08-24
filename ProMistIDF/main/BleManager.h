#pragma once

// Proprietary GATT lifecycle and queue boundary. NimBLE callbacks capture
// bounded events; update() performs authenticated application work.

#include <atomic>

#include <cstddef>
#include <cstdint>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <host/ble_gap.h>
#include <host/ble_gatt.h>

#include "BleProtocol.h"
#include "BleSecurity.h"
#include "CustomBreezeStore.h"
#include "DiagnosticLog.h"

/**
 * Registers the proprietary GATT service on Matter's NimBLE host and moves
 * callback data through bounded queues for application-task processing.
 */
class BleManager {
 public:
  BleManager(
    DeviceController &controller,
    DiagnosticLog &diagnosticLog,
    CustomBreezeStore &breezeStore
  );

  /// Registers the service and begins lifecycle management on the shared host.
  bool begin();
  /// Drains callback queues, advances authentication, and publishes notifications.
  void update();
  /// Opens the physical owner-enrollment window.
  bool enterProvisioning();
  /// Closes the physical owner-enrollment window without changing ownership.
  bool cancelProvisioning();
  /// Erases BLE ownership/bonds as part of physical whole-device recovery.
  void physicalFactoryReset();
  /** Returns whether the physical owner-enrollment window remains active. */
  bool isProvisioning() const;
  /// Caches the Matter manual pairing code after the Matter stack starts.
  /// The string is copied into a fixed 21-character payload buffer.
  void setMatterOnboardingPayload(const char *payload);

  static constexpr const char *SERVICE_UUID =
    "6f8a0001-7c5a-4d8f-9b21-8d12d9b00100";

 private:
  enum class AttributeKind : uint8_t {
    Info,
    Security,
    State,
    Command,
    Response,
    LogMetadata,
    LogRequest,
    LogData,
    FriendlyName,
    MatterOnboarding,
    Provisioning,
    BreezeSlot0,
    BreezeSlot1,
    BreezeSlot2
  };
  enum class WriteKind : uint8_t {
    Command, LogRequest, FriendlyName, Security, MatterOnboarding, Provisioning,
    BreezeSlot0, BreezeSlot1, BreezeSlot2
  };
  enum class LifecycleEventKind : uint8_t {
    Connected,
    Disconnected,
    SubscriptionChanged
  };

  static constexpr uint16_t INVALID_CONNECTION_HANDLE = 0xFFFF;
  static constexpr size_t MAX_PROPRIETARY_LINKS = 2;
  static constexpr size_t NOTIFIABLE_CHARACTERISTICS = 9;
  static constexpr size_t MAX_SUBSCRIPTIONS =
    MAX_PROPRIETARY_LINKS * NOTIFIABLE_CHARACTERISTICS;
  struct Subscription { uint16_t connHandle = INVALID_CONNECTION_HANDLE; uint16_t valueHandle = 0; };

  DeviceController &_controller;
  DiagnosticLog &_diagnosticLog;
  CustomBreezeStore &_breezeStore;
  BleSecurity _security;
  QueueHandle_t _commandQueue = nullptr;
  QueueHandle_t _logQueue = nullptr;
  QueueHandle_t _nameQueue = nullptr;
  QueueHandle_t _securityQueue = nullptr;
  QueueHandle_t _matterOnboardingQueue = nullptr;
  QueueHandle_t _provisioningQueue = nullptr;
  QueueHandle_t _breezeQueue = nullptr;
  QueueHandle_t _lifecycleQueue = nullptr;
  QueueHandle_t _disconnectQueue = nullptr;
  ble_gap_event_listener _gapListener = {};
  bool _gapListenerRegistered = false;
  std::atomic<bool> _deviceNameConfigured = false;
  bool _deviceNameFailureReported = false;
  bool _readyReported = false;
  bool _advertisingEnableFailureReported = false;
  std::atomic<bool> _matterBleWorkPending = false;
  std::atomic<uint32_t> _droppedQueueEventCount = 0;
  std::atomic<bool> _disconnectRecoveryRequired = false;
  portMUX_TYPE _snapshotLock = portMUX_INITIALIZER_UNLOCKED;
  Subscription _subscriptions[MAX_SUBSCRIPTIONS] = {};
  bool _available = false;
  uint8_t _infoValue[BLE_DEVICE_INFORMATION_SIZE] = {};
  uint8_t _stateValue[BLE_STATE_SIZE] = {};
  uint8_t _responseValue[BLE_RESPONSE_SIZE] = {};
  uint8_t _logMetadataValue[20] = {};
  uint8_t _breezeSlotValues[CUSTOM_BREEZE_SLOT_COUNT]
    [CUSTOM_BREEZE_WIRE_SIZE] = {};
  uint16_t _infoHandle = 0;
  uint16_t _securityHandle = 0;
  uint16_t _stateHandle = 0;
  uint16_t _commandHandle = 0;
  uint16_t _responseHandle = 0;
  uint16_t _logMetadataHandle = 0;
  uint16_t _logRequestHandle = 0;
  uint16_t _logDataHandle = 0;
  uint16_t _friendlyNameHandle = 0;
  uint16_t _matterOnboardingHandle = 0;
  uint16_t _provisioningHandle = 0;
  uint16_t _breezeSlotHandles[CUSTOM_BREEZE_SLOT_COUNT] = {};
  char _advertisedName[16] = {};
  char _pairingName[12] = {};
  char _friendlyName[25] = {};
  char _matterOnboardingPayload[22] = {};
  uint32_t _publishedRevision = UINT32_MAX;
  uint64_t _lastTelemetryPublishMs = 0;

  static int gattAccess(
    uint16_t connHandle,
    uint16_t attrHandle,
    ble_gatt_access_ctxt *context,
    void *argument
  );
  static int gapEvent(ble_gap_event *event, void *argument);
  static void updateMatterBleOnChipThread(intptr_t argument);
  int handleGattAccess(
    uint16_t connHandle,
    ble_gatt_access_ctxt *context,
    AttributeKind kind
  );
  int handleGapEvent(ble_gap_event *event);
  void clearConnection(uint16_t connHandle);
  void setSubscribed(uint16_t connHandle, uint16_t attrHandle, bool subscribed);
  bool isSubscribed(uint16_t connHandle, uint16_t attrHandle) const;
  bool notify(uint16_t connHandle, uint16_t attrHandle, const uint8_t *bytes, size_t length);
  void notifyAll(uint16_t attrHandle, const uint8_t *bytes, size_t length);
  bool enqueueWrite(WriteKind kind, uint16_t connHandle, const uint8_t *bytes, size_t length);
  void enqueueLifecycleEvent(
    LifecycleEventKind kind,
    uint16_t connHandle,
    uint16_t attrHandle = 0,
    bool subscribed = false
  );
  void processLifecycleEvents();
  void clearAllConnections();
  void processCommand(uint16_t connHandle, const uint8_t *bytes, size_t length);
  void processLogRequest(uint16_t connHandle, const uint8_t *bytes, size_t length);
  void processFriendlyName(uint16_t connHandle, const uint8_t *bytes, size_t length);
  void processSecurity(uint16_t connHandle, const uint8_t *bytes, size_t length);
  void processMatterOnboardingRequest(
    uint16_t connHandle,
    const uint8_t *bytes,
    size_t length
  );
  void processBreezeSlot(
    uint16_t connHandle,
    uint8_t expectedSlot,
    const uint8_t *bytes,
    size_t length
  );
  void loadFriendlyName();
  void publishState();
  void publishMetadata();
  void updateBleLifecycle();
  void sendResponse(
    uint16_t connHandle,
    BleProtocolResult result,
    BleOpcode opcode,
    uint32_t requestId
  );
};

// Proprietary GATT service and callback-to-loop handoff. Callback work is kept
// bounded; decoded/authenticated operations execute from application context.
#include "BleManager.h"

#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>
#include <esp_log.h>
#include <host/ble_att.h>
#include <host/ble_hs.h>
#include <host/ble_hs_mbuf.h>
#include <lib/support/Span.h>
#include <os/os_mbuf.h>
#include <platform/internal/CHIPDeviceLayerInternal.h>
#include <platform/ESP32/BLEManagerImpl.h>
#include <services/gap/ble_svc_gap.h>

#include <vector>

#include "DiagnosticEvents.h"
#include "DeviceClock.h"
#include "NvsNamespace.h"

namespace {

constexpr char TAG[] = "BleManager";
// Installed-controller upgrades retain the friendly name; authenticated reset
// or physical recovery remains responsible for clearing it.
constexpr const char *CONFIG_NAMESPACE = "sharkcfg";
constexpr const char *FRIENDLY_NAME_KEY = "friendlyName";
constexpr size_t MAX_FRIENDLY_NAME_LENGTH = 24;

#define PROMIST_UUID(id) \
  BLE_UUID128_INIT(0x00, 0x01, 0xb0, 0xd9, 0x12, 0x8d, 0x21, 0x9b, \
                   0x8f, 0x4d, 0x5a, 0x7c, id, 0x00, 0x8a, 0x6f)

const ble_uuid128_t SERVICE_ID = PROMIST_UUID(0x01);
const ble_uuid128_t INFO_ID = PROMIST_UUID(0x02);
const ble_uuid128_t SECURITY_ID = PROMIST_UUID(0x03);
const ble_uuid128_t STATE_ID = PROMIST_UUID(0x04);
const ble_uuid128_t COMMAND_ID = PROMIST_UUID(0x05);
const ble_uuid128_t RESPONSE_ID = PROMIST_UUID(0x06);
const ble_uuid128_t LOG_META_ID = PROMIST_UUID(0x07);
const ble_uuid128_t LOG_REQUEST_ID = PROMIST_UUID(0x08);
const ble_uuid128_t LOG_DATA_ID = PROMIST_UUID(0x09);
const ble_uuid128_t FRIENDLY_NAME_ID = PROMIST_UUID(0x0a);
const ble_uuid128_t MATTER_ONBOARDING_ID = PROMIST_UUID(0x0b);
const ble_uuid128_t PROVISIONING_ID = PROMIST_UUID(0x0c);
const ble_uuid128_t BREEZE_SLOT_0_ID = PROMIST_UUID(0x0d);
const ble_uuid128_t BREEZE_SLOT_1_ID = PROMIST_UUID(0x0e);
const ble_uuid128_t BREEZE_SLOT_2_ID = PROMIST_UUID(0x0f);

struct QueuedWrite {
  uint16_t connHandle;
  uint8_t kind;
  uint8_t length;
  uint8_t bytes[CUSTOM_BREEZE_WIRE_SIZE];
};

struct QueuedLifecycleEvent {
  uint8_t kind;
  uint16_t connHandle;
  uint16_t attrHandle;
  bool subscribed;
};

void write32(uint8_t *output, uint32_t value) {
  for (uint8_t i = 0; i < 4; ++i) {
    output[i] = static_cast<uint8_t>(value >> (8 * i));
  }
}

bool isContinuationByte(uint8_t value) {
  return (value & 0xC0) == 0x80;
}

bool isValidUtf8(const uint8_t *bytes, size_t length) {
  size_t index = 0;
  while (index < length) {
    const uint8_t first = bytes[index];
    if (first <= 0x7F) {
      ++index;
      continue;
    }
    if (first >= 0xC2 && first <= 0xDF) {
      if (index + 1 >= length || !isContinuationByte(bytes[index + 1])) {
        return false;
      }
      index += 2;
      continue;
    }
    if (first >= 0xE0 && first <= 0xEF) {
      if (
        index + 2 >= length ||
        !isContinuationByte(bytes[index + 1]) ||
        !isContinuationByte(bytes[index + 2]) ||
        (first == 0xE0 && bytes[index + 1] < 0xA0) ||
        (first == 0xED && bytes[index + 1] > 0x9F)
      ) {
        return false;
      }
      index += 3;
      continue;
    }
    if (first >= 0xF0 && first <= 0xF4) {
      if (
        index + 3 >= length ||
        !isContinuationByte(bytes[index + 1]) ||
        !isContinuationByte(bytes[index + 2]) ||
        !isContinuationByte(bytes[index + 3]) ||
        (first == 0xF0 && bytes[index + 1] < 0x90) ||
        (first == 0xF4 && bytes[index + 1] > 0x8F)
      ) {
        return false;
      }
      index += 4;
      continue;
    }
    return false;
  }
  return true;
}

}  // namespace

BleManager *promistBleManagerInstance = nullptr;

BleManager::BleManager(
  DeviceController &controller,
  DiagnosticLog &diagnosticLog,
  CustomBreezeStore &breezeStore
)
  : _controller(controller),
    _diagnosticLog(diagnosticLog),
    _breezeStore(breezeStore),
    _security(controller.state().identity.deviceId) {}

bool BleManager::begin() {
  _commandQueue = xQueueCreate(4, sizeof(QueuedWrite));
  _logQueue = xQueueCreate(2, sizeof(QueuedWrite));
  _nameQueue = xQueueCreate(2, sizeof(QueuedWrite));
  _securityQueue = xQueueCreate(2, sizeof(QueuedWrite));
  _matterOnboardingQueue = xQueueCreate(2, sizeof(QueuedWrite));
  _provisioningQueue = xQueueCreate(2, sizeof(QueuedWrite));
  _breezeQueue = xQueueCreate(3, sizeof(QueuedWrite));
  // Each of the two supported links can subscribe to all nine notifiable
  // ProMist characteristics in one burst. Leave room for unsubscribe churn;
  // disconnects use their own priority queue so ownership cleanup cannot be
  // displaced by subscription events.
  _lifecycleQueue = xQueueCreate(24, sizeof(QueuedLifecycleEvent));
  _disconnectQueue = xQueueCreate(4, sizeof(uint16_t));
  if (
    _commandQueue == nullptr ||
    _logQueue == nullptr ||
    _nameQueue == nullptr ||
    _securityQueue == nullptr ||
    _matterOnboardingQueue == nullptr ||
    _provisioningQueue == nullptr ||
    _breezeQueue == nullptr ||
    _lifecycleQueue == nullptr ||
    _disconnectQueue == nullptr
  ) {
    ESP_LOGE(TAG, "BLE FAILED: unable to allocate bounded queues");
    return false;
  }

  const uint64_t deviceId = _controller.state().identity.deviceId;
  snprintf(
    _advertisedName,
    sizeof(_advertisedName),
    "ProMist-%06lX",
    static_cast<unsigned long>(deviceId & 0xFFFFFFULL)
  );
  snprintf(
    _pairingName,
    sizeof(_pairingName),
    "ProMist-%03lX",
    static_cast<unsigned long>(deviceId & 0xFFFULL)
  );
  loadFriendlyName();
  if (!_security.begin(deviceId)) {
    ESP_LOGE(TAG, "BLE SECURITY FAILED: ownership state unavailable; provisioning disabled");
    return false;
  }
  promistBleManagerInstance = this;

  encodeBleDeviceInformation(deviceId, _infoValue);
  for (uint8_t slot = 0; slot < CUSTOM_BREEZE_SLOT_COUNT; ++slot) {
    encodeCustomBreezeProfile(_breezeStore.profile(slot), _breezeSlotValues[slot]);
  }

  static ble_gatt_chr_def characteristics[] = {
    { &INFO_ID.u, gattAccess, reinterpret_cast<void *>(
        static_cast<uintptr_t>(AttributeKind::Info)),
      nullptr, BLE_GATT_CHR_F_READ, 0, nullptr, nullptr },
    { &SECURITY_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::Security)), nullptr,
      BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY, 0, nullptr, nullptr },
    { &STATE_ID.u, gattAccess, reinterpret_cast<void *>(
        static_cast<uintptr_t>(AttributeKind::State)),
      nullptr, BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY, 0, nullptr, nullptr },
    { &COMMAND_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::Command)), nullptr,
      BLE_GATT_CHR_F_WRITE, 0, nullptr, nullptr },
    { &RESPONSE_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::Response)), nullptr,
      BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_NOTIFY, 0, nullptr, nullptr },
    { &LOG_META_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::LogMetadata)), nullptr,
      BLE_GATT_CHR_F_READ, 0, nullptr, nullptr },
    { &LOG_REQUEST_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::LogRequest)), nullptr,
      BLE_GATT_CHR_F_WRITE, 0, nullptr, nullptr },
    { &LOG_DATA_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::LogData)), nullptr,
      BLE_GATT_CHR_F_NOTIFY, 0, nullptr, nullptr },
    { &FRIENDLY_NAME_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::FriendlyName)), nullptr,
      BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY,
      0, nullptr, nullptr },
    { &MATTER_ONBOARDING_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::MatterOnboarding)),
      nullptr, BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY, 0, nullptr, nullptr },
    { &PROVISIONING_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::Provisioning)),
      nullptr, BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_ENC, 0, nullptr, nullptr },
    { &BREEZE_SLOT_0_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::BreezeSlot0)),
      nullptr, BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY,
      0, nullptr, nullptr },
    { &BREEZE_SLOT_1_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::BreezeSlot1)),
      nullptr, BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY,
      0, nullptr, nullptr },
    { &BREEZE_SLOT_2_ID.u, gattAccess,
      reinterpret_cast<void *>(static_cast<uintptr_t>(AttributeKind::BreezeSlot2)),
      nullptr, BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_NOTIFY,
      0, nullptr, nullptr },
    { nullptr, nullptr, nullptr, nullptr, 0, 0, nullptr, nullptr }
  };
  characteristics[0].val_handle = &_infoHandle;
  characteristics[1].val_handle = &_securityHandle;
  characteristics[2].val_handle = &_stateHandle;
  characteristics[3].val_handle = &_commandHandle;
  characteristics[4].val_handle = &_responseHandle;
  characteristics[5].val_handle = &_logMetadataHandle;
  characteristics[6].val_handle = &_logRequestHandle;
  characteristics[7].val_handle = &_logDataHandle;
  characteristics[8].val_handle = &_friendlyNameHandle;
  characteristics[9].val_handle = &_matterOnboardingHandle;
  characteristics[10].val_handle = &_provisioningHandle;
  characteristics[11].val_handle = &_breezeSlotHandles[0];
  characteristics[12].val_handle = &_breezeSlotHandles[1];
  characteristics[13].val_handle = &_breezeSlotHandles[2];
  const ble_gatt_svc_def service = {
    BLE_GATT_SVC_TYPE_PRIMARY, &SERVICE_ID.u, nullptr, characteristics
  };
  std::vector<ble_gatt_svc_def> extraServices = { service };
  auto &matterBle = chip::DeviceLayer::Internal::BLEMgrImpl();
  CHIP_ERROR error = matterBle.ConfigureExtraServices(extraServices, false);
  if (error != CHIP_NO_ERROR) {
    ESP_LOGD(TAG,
      "BLE FAILED: Matter rejected ProMist GATT service (%lu)\n",
      static_cast<unsigned long>(error.AsInteger())
    );
    return false;
  }

  uint8_t scanResponse[31] = {
    17, 0x07,
    0x00, 0x01, 0xb0, 0xd9, 0x12, 0x8d, 0x21, 0x9b,
    0x8f, 0x4d, 0x5a, 0x7c, 0x01, 0x00, 0x8a, 0x6f,
    12, 0x08, 'P', 'r', 'o', 'M', 'i', 's', 't', '-', '0', '0', '0'
  };
  memcpy(scanResponse + 20, _pairingName, 11);
  error = matterBle.ConfigureScanResponseData(
    chip::ByteSpan(scanResponse, sizeof(scanResponse))
  );
  if (error != CHIP_NO_ERROR) {
    ESP_LOGD(TAG,
      "BLE FAILED: Matter rejected ProMist discovery data (%lu)\n",
      static_cast<unsigned long>(error.AsInteger())
    );
    return false;
  }

  publishState();
  publishMetadata();
  ESP_LOGD(TAG,
    "BLE CONFIGURED: name=%s, service %s queued for Matter NimBLE host\n",
    _advertisedName,
    SERVICE_UUID
  );
  _available = true;
  return true;
}

void BleManager::update() {
  if (!_available) return;
  processLifecycleEvents();
  const uint32_t droppedQueueEvents =
    _droppedQueueEventCount.exchange(0, std::memory_order_relaxed);
  if (droppedQueueEvents != 0) {
    _diagnosticLog.append(
      DeviceClock::protocolMilliseconds(),
      DiagnosticEventId::BleSessionFailure,
      2,
      static_cast<int32_t>(droppedQueueEvents)
    );
  }

  QueuedWrite write;
  while (xQueueReceive(_breezeQueue, &write, 0) == pdTRUE) {
    const WriteKind kind = static_cast<WriteKind>(write.kind);
    const uint8_t slot = kind == WriteKind::BreezeSlot0 ? 0
      : kind == WriteKind::BreezeSlot1 ? 1 : 2;
    processBreezeSlot(write.connHandle, slot, write.bytes, write.length);
  }
  while (xQueueReceive(_commandQueue, &write, 0) == pdTRUE) {
    processCommand(write.connHandle, write.bytes, write.length);
  }
  while (xQueueReceive(_logQueue, &write, 0) == pdTRUE) {
    processLogRequest(write.connHandle, write.bytes, write.length);
  }
  while (xQueueReceive(_nameQueue, &write, 0) == pdTRUE) {
    processFriendlyName(write.connHandle, write.bytes, write.length);
  }
  while (xQueueReceive(_securityQueue, &write, 0) == pdTRUE) {
    processSecurity(write.connHandle, write.bytes, write.length);
  }
  while (xQueueReceive(_matterOnboardingQueue, &write, 0) == pdTRUE) {
    processMatterOnboardingRequest(write.connHandle, write.bytes, write.length);
  }
  while (xQueueReceive(_provisioningQueue, &write, 0) == pdTRUE) {
    processSecurity(write.connHandle, write.bytes, write.length);
  }
  if (_controller.state().revision != _publishedRevision ||
      DeviceClock::milliseconds() - _lastTelemetryPublishMs >= 5000) {
    publishState();
  }
  updateBleLifecycle();
}

void BleManager::updateBleLifecycle() {
  if (!ble_hs_is_enabled()) {
    return;
  }

  if (!_gapListenerRegistered) {
    const int result = ble_gap_event_listener_register(
      &_gapListener,
      gapEvent,
      this
    );
    if (result == 0) {
      _gapListenerRegistered = true;
      ESP_LOGD(TAG, "BLE LIFECYCLE: ProMist listener attached to Matter host");
    } else {
      return;
    }
  }

  auto &matterBle = chip::DeviceLayer::Internal::BLEMgr();
  if ((!_deviceNameConfigured || !matterBle.IsAdvertisingEnabled()) &&
      !_matterBleWorkPending.exchange(true)) {
    const CHIP_ERROR error = chip::DeviceLayer::PlatformMgr().ScheduleWork(
      updateMatterBleOnChipThread,
      reinterpret_cast<intptr_t>(this)
    );
    if (error != CHIP_NO_ERROR) {
      _matterBleWorkPending.store(false);
      ESP_LOGD(TAG,
        "BLE LIFECYCLE: Matter task scheduling failed (%lu)\n",
        static_cast<unsigned long>(error.AsInteger())
      );
    }
  }
  if (_deviceNameConfigured && _gapListenerRegistered && !_readyReported) {
    _readyReported = true;
    ESP_LOGD(TAG,
      "BLE READY: name=%s, pairing=%s, service %s on Matter NimBLE host\n",
      _advertisedName,
      _pairingName,
      SERVICE_UUID
    );
  }
}

void BleManager::updateMatterBleOnChipThread(intptr_t argument) {
  auto *manager = reinterpret_cast<BleManager *>(argument);
  auto &matterBle = chip::DeviceLayer::Internal::BLEMgr();

  if (!manager->_deviceNameConfigured) {
    const CHIP_ERROR error = matterBle.SetDeviceName(manager->_pairingName);
    // Matter caches its name after advertising starts. Also update NimBLE's
    // live GAP name so Apple's pairing sheet does not show Matter-####.
    const int gapError = error == CHIP_NO_ERROR
      ? ble_svc_gap_device_name_set(manager->_pairingName)
      : 0;
    if (error == CHIP_NO_ERROR && gapError == 0) {
      manager->_deviceNameConfigured = true;
      manager->_deviceNameFailureReported = false;
    } else if (!manager->_deviceNameFailureReported) {
      manager->_deviceNameFailureReported = true;
      ESP_LOGD(TAG,
        "BLE NAME: Matter setup deferred (matter=%lu gap=%d)\n",
        static_cast<unsigned long>(error.AsInteger()),
        gapError
      );
    }
  }

  if (!matterBle.IsAdvertisingEnabled()) {
    const CHIP_ERROR error = matterBle.SetAdvertisingEnabled(true);
    if (error == CHIP_NO_ERROR) {
      manager->_advertisingEnableFailureReported = false;
      ESP_LOGI(TAG, "BLE ADVERTISING: Matter-owned advertising enabled");
    } else if (!manager->_advertisingEnableFailureReported) {
      manager->_advertisingEnableFailureReported = true;
      ESP_LOGD(TAG,
        "BLE ADVERTISING: Matter enable failed (%lu)\n",
        static_cast<unsigned long>(error.AsInteger())
      );
    }
  }

  manager->_matterBleWorkPending.store(false);
}

int BleManager::gattAccess(
  uint16_t connHandle,
  uint16_t,
  ble_gatt_access_ctxt *context,
  void *argument
) {
  if (promistBleManagerInstance == nullptr) {
    return BLE_ATT_ERR_UNLIKELY;
  }
  return promistBleManagerInstance->handleGattAccess(
    connHandle,
    context,
    static_cast<AttributeKind>(reinterpret_cast<uintptr_t>(argument))
  );
}

int BleManager::gapEvent(ble_gap_event *event, void *argument) {
  return static_cast<BleManager *>(argument)->handleGapEvent(event);
}

int BleManager::handleGattAccess(
  uint16_t connHandle,
  ble_gatt_access_ctxt *context,
  AttributeKind kind
) {
  if (context->op == BLE_GATT_ACCESS_OP_READ_CHR) {
    uint8_t snapshot[CUSTOM_BREEZE_WIRE_SIZE] = {};
    size_t length = 0;
    portENTER_CRITICAL(&_snapshotLock);
    switch (kind) {
      case AttributeKind::Info:
        length = sizeof(_infoValue);
        memcpy(snapshot, _infoValue, length);
        break;
      case AttributeKind::State:
        length = sizeof(_stateValue);
        memcpy(snapshot, _stateValue, length);
        break;
      case AttributeKind::Response:
        length = sizeof(_responseValue);
        memcpy(snapshot, _responseValue, length);
        break;
      case AttributeKind::LogMetadata:
        length = sizeof(_logMetadataValue);
        memcpy(snapshot, _logMetadataValue, length);
        break;
      case AttributeKind::FriendlyName:
        length = strlen(_friendlyName);
        memcpy(snapshot, _friendlyName, length);
        break;
      case AttributeKind::BreezeSlot0:
      case AttributeKind::BreezeSlot1:
      case AttributeKind::BreezeSlot2: {
        const uint8_t slot = static_cast<uint8_t>(kind) -
          static_cast<uint8_t>(AttributeKind::BreezeSlot0);
        length = CUSTOM_BREEZE_WIRE_SIZE;
        memcpy(snapshot, _breezeSlotValues[slot], length);
        break;
      }
      default:
        portEXIT_CRITICAL(&_snapshotLock);
        return BLE_ATT_ERR_READ_NOT_PERMITTED;
    }
    portEXIT_CRITICAL(&_snapshotLock);
    if (context->offset > length) {
      return BLE_ATT_ERR_INVALID_OFFSET;
    }
    length -= context->offset;
    return os_mbuf_append(context->om, snapshot + context->offset, length) == 0
      ? 0
      : BLE_ATT_ERR_INSUFFICIENT_RES;
  }
  if (context->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
    return BLE_ATT_ERR_UNLIKELY;
  }

  WriteKind writeKind;
  switch (kind) {
    case AttributeKind::Command:
      writeKind = WriteKind::Command;
      break;
    case AttributeKind::LogRequest:
      writeKind = WriteKind::LogRequest;
      break;
    case AttributeKind::FriendlyName:
      writeKind = WriteKind::FriendlyName;
      break;
    case AttributeKind::Security:
      writeKind = WriteKind::Security;
      break;
    case AttributeKind::MatterOnboarding:
      writeKind = WriteKind::MatterOnboarding;
      break;
    case AttributeKind::Provisioning:
      writeKind = WriteKind::Provisioning;
      break;
    case AttributeKind::BreezeSlot0:
      writeKind = WriteKind::BreezeSlot0;
      break;
    case AttributeKind::BreezeSlot1:
      writeKind = WriteKind::BreezeSlot1;
      break;
    case AttributeKind::BreezeSlot2:
      writeKind = WriteKind::BreezeSlot2;
      break;
    default:
      return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
  }
  if (
    writeKind == WriteKind::Command &&
    _controller.bleProvisioningActive()
  ) {
    // Reject at ingress so a command received during setup cannot remain
    // queued and execute after successful enrollment releases the gate.
    return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
  }
  const size_t length = OS_MBUF_PKTLEN(context->om);
  if (length > CUSTOM_BREEZE_WIRE_SIZE) {
    return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
  }
  uint8_t bytes[CUSTOM_BREEZE_WIRE_SIZE] = {};
  uint16_t copied = 0;
  if (ble_hs_mbuf_to_flat(context->om, bytes, sizeof(bytes), &copied) != 0 ||
      copied != length) {
    return BLE_ATT_ERR_UNLIKELY;
  }
  if (writeKind == WriteKind::Security && length > 0 &&
      bytes[0] == static_cast<uint8_t>(BleSecurityMessage::ProvisionRequest)) {
    // Owner-key delivery is permitted only through the separately encrypted,
    // non-bonding enrollment characteristic.
    return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
  }
  if (writeKind == WriteKind::Provisioning &&
      (length == 0 || bytes[0] !=
        static_cast<uint8_t>(BleSecurityMessage::ProvisionRequest))) {
    return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
  }
  return enqueueWrite(writeKind, connHandle, bytes, length)
    ? 0
    : BLE_ATT_ERR_INSUFFICIENT_RES;
}

int BleManager::handleGapEvent(ble_gap_event *event) {
  if (event->type == BLE_GAP_EVENT_CONNECT) {
    // No application state is created until a subscription or authenticated
    // write arrives, so a successful link needs no queued bookkeeping.
  } else if (event->type == BLE_GAP_EVENT_DISCONNECT) {
    const uint16_t connHandle = event->disconnect.conn.conn_handle;
    if (_disconnectQueue == nullptr ||
        xQueueSend(_disconnectQueue, &connHandle, 0) != pdTRUE) {
      // Losing a disconnect can permanently strand the authenticated owner.
      // Recover conservatively from application context on the next update.
      _disconnectRecoveryRequired.store(true, std::memory_order_release);
    }
  } else if (event->type == BLE_GAP_EVENT_SUBSCRIBE) {
    const uint16_t handle = event->subscribe.attr_handle;
    if (handle == _securityHandle || handle == _stateHandle ||
        handle == _responseHandle || handle == _logDataHandle ||
        handle == _friendlyNameHandle || handle == _matterOnboardingHandle ||
        handle == _breezeSlotHandles[0] || handle == _breezeSlotHandles[1] ||
        handle == _breezeSlotHandles[2]) {
      enqueueLifecycleEvent(
        LifecycleEventKind::SubscriptionChanged,
        event->subscribe.conn_handle,
        handle,
        event->subscribe.cur_notify != 0
      );
    }
  }
  return 0;
}

void BleManager::clearConnection(uint16_t connHandle) {
  if (_security.disconnect(connHandle)) {
    _controller.resetRequestSequence(CommandOrigin::Ble);
  }
  for (Subscription &subscription : _subscriptions) {
    if (subscription.connHandle == connHandle) subscription = {};
  }
}

void BleManager::setSubscribed(uint16_t connHandle, uint16_t attrHandle, bool subscribed) {
  for (size_t index = 0; index < MAX_SUBSCRIPTIONS; ++index) {
    if (_subscriptions[index].connHandle == connHandle &&
        _subscriptions[index].valueHandle == attrHandle) {
      if (!subscribed) {
        _subscriptions[index] = {};
      }
      return;
    }
  }
  if (!subscribed) {
    return;
  }
  for (size_t index = 0; index < MAX_SUBSCRIPTIONS; ++index) {
    if (_subscriptions[index].valueHandle == 0) {
      _subscriptions[index] = {connHandle, attrHandle};
      return;
    }
  }
}

bool BleManager::isSubscribed(uint16_t connHandle, uint16_t attrHandle) const {
  for (const Subscription &subscription : _subscriptions) {
    if (subscription.connHandle == connHandle &&
        subscription.valueHandle == attrHandle) {
      return true;
    }
  }
  return false;
}

bool BleManager::notify(
  uint16_t connHandle,
  uint16_t attrHandle,
  const uint8_t *bytes,
  size_t length
) {
  if (connHandle == INVALID_CONNECTION_HANDLE ||
      !isSubscribed(connHandle, attrHandle)) {
    return false;
  }
  os_mbuf *packet = ble_hs_mbuf_from_flat(bytes, length);
  if (packet == nullptr) {
    _diagnosticLog.append(
      DeviceClock::protocolMilliseconds(), DiagnosticEventId::BleSessionFailure, 3, attrHandle
    );
    return false;
  }
  const int result = ble_gatts_notify_custom(
    connHandle,
    attrHandle,
    packet
  );
  if (result != 0) {
    _diagnosticLog.append(
      DeviceClock::protocolMilliseconds(), DiagnosticEventId::BleSessionFailure, 3, attrHandle
    );
    return false;
  }
  return true;
}

void BleManager::notifyAll(uint16_t attrHandle, const uint8_t *bytes, size_t length) {
  for (const Subscription &subscription : _subscriptions) {
    if (subscription.valueHandle == attrHandle) {
      notify(subscription.connHandle, attrHandle, bytes, length);
    }
  }
}

bool BleManager::enqueueWrite(
  WriteKind kind,
  uint16_t connHandle,
  const uint8_t *bytes,
  size_t length
) {
  QueuedWrite write = {};
  write.connHandle = connHandle;
  write.kind = static_cast<uint8_t>(kind);
  if (length > sizeof(write.bytes)) {
    return false;
  }
  write.length = static_cast<uint8_t>(length);
  memcpy(write.bytes, bytes, length);
  QueueHandle_t queue = _nameQueue;
  if (kind == WriteKind::Command) {
    queue = _commandQueue;
  } else if (kind == WriteKind::LogRequest) {
    queue = _logQueue;
  } else if (kind == WriteKind::Security) {
    queue = _securityQueue;
  } else if (kind == WriteKind::MatterOnboarding) {
    queue = _matterOnboardingQueue;
  } else if (kind == WriteKind::Provisioning) {
    queue = _provisioningQueue;
  } else if (kind == WriteKind::BreezeSlot0 ||
             kind == WriteKind::BreezeSlot1 ||
             kind == WriteKind::BreezeSlot2) {
    queue = _breezeQueue;
  }
  if (queue == nullptr || xQueueSend(queue, &write, 0) != pdTRUE) {
    _droppedQueueEventCount.fetch_add(1, std::memory_order_relaxed);
    return false;
  }
  return true;
}

void BleManager::enqueueLifecycleEvent(
  LifecycleEventKind kind,
  uint16_t connHandle,
  uint16_t attrHandle,
  bool subscribed
) {
  if (_lifecycleQueue == nullptr) return;
  const QueuedLifecycleEvent event = {
    static_cast<uint8_t>(kind), connHandle, attrHandle, subscribed
  };
  if (xQueueSend(_lifecycleQueue, &event, 0) != pdTRUE) {
    _droppedQueueEventCount.fetch_add(1, std::memory_order_relaxed);
  }
}

void BleManager::processLifecycleEvents() {
  QueuedLifecycleEvent event;
  while (xQueueReceive(_lifecycleQueue, &event, 0) == pdTRUE) {
    switch (static_cast<LifecycleEventKind>(event.kind)) {
      case LifecycleEventKind::Connected:
        break;
      case LifecycleEventKind::Disconnected:
        clearConnection(event.connHandle);
        break;
      case LifecycleEventKind::SubscriptionChanged:
        setSubscribed(event.connHandle, event.attrHandle, event.subscribed);
        break;
    }
  }

  uint16_t disconnectedHandle = INVALID_CONNECTION_HANDLE;
  while (xQueueReceive(
           _disconnectQueue,
           &disconnectedHandle,
           0
         ) == pdTRUE) {
    clearConnection(disconnectedHandle);
  }
  if (_disconnectRecoveryRequired.exchange(false, std::memory_order_acq_rel)) {
    clearAllConnections();
    _diagnosticLog.append(
      DeviceClock::protocolMilliseconds(), DiagnosticEventId::BleSessionFailure, 4, 0
    );
    ESP_LOGW(TAG, "BLE LIFECYCLE: disconnect overflow; volatile sessions cleared");
  }
}

void BleManager::clearAllConnections() {
  if (_security.disconnectAll()) {
    _controller.resetRequestSequence(CommandOrigin::Ble);
  }
  for (Subscription &subscription : _subscriptions) {
    subscription = {};
  }
}

void BleManager::loadFriendlyName() {
  strlcpy(_friendlyName, "ProMist", sizeof(_friendlyName));
  NvsNamespace storage;
  const esp_err_t openResult = storage.open(CONFIG_NAMESPACE, NVS_READONLY);
  if (openResult == ESP_ERR_NVS_NOT_FOUND) {
    ESP_LOGD(TAG, "BLE FRIENDLY NAME: using default; no stored name");
    return;
  }
  if (openResult != ESP_OK) {
    ESP_LOGE(
      TAG,
      "BLE FRIENDLY NAME: using default; storage unavailable: %s",
      esp_err_to_name(openResult)
    );
    return;
  }
  size_t length = 0;
  const esp_err_t sizeResult = storage.blobSize(FRIENDLY_NAME_KEY, length);
  if (sizeResult == ESP_ERR_NVS_NOT_FOUND) length = 0;
  if (length > 0 && length <= MAX_FRIENDLY_NAME_LENGTH) {
    uint8_t stored[MAX_FRIENDLY_NAME_LENGTH] = {};
    size_t readLength = length;
    if (storage.getBlob(FRIENDLY_NAME_KEY, stored, readLength) == ESP_OK &&
        readLength == length &&
        isValidUtf8(stored, length)) {
      bool valid = false;
      for (size_t index = 0; index < length; ++index) {
        if (stored[index] < 0x20 || stored[index] == 0x7F) {
          valid = false;
          break;
        }
        valid = valid || stored[index] != ' ';
      }
      if (valid) {
        memcpy(_friendlyName, stored, length);
        _friendlyName[length] = '\0';
      }
    }
  }
  ESP_LOGD(TAG, "BLE FRIENDLY NAME: %s\n", _friendlyName);
}

void BleManager::processFriendlyName(uint16_t connHandle, const uint8_t *bytes, size_t length) {
  if (!_security.isAuthenticated(connHandle)) {
    ESP_LOGW(TAG, "BLE FRIENDLY NAME: unauthorized write rejected");
    return;
  }
  if (
    length == 0 ||
    length > MAX_FRIENDLY_NAME_LENGTH ||
    !isValidUtf8(bytes, length)
  ) {
    ESP_LOGW(TAG, "BLE FRIENDLY NAME: rejected invalid length");
    return;
  }
  bool hasVisibleCharacter = false;
  for (size_t index = 0; index < length; ++index) {
    if (bytes[index] < 0x20 || bytes[index] == 0x7F) {
      ESP_LOGW(TAG, "BLE FRIENDLY NAME: rejected control character");
      return;
    }
    if (bytes[index] != ' ') {
      hasVisibleCharacter = true;
    }
  }
  if (!hasVisibleCharacter) {
    ESP_LOGW(TAG, "BLE FRIENDLY NAME: rejected blank name");
    return;
  }

  const bool changed = strlen(_friendlyName) != length ||
    memcmp(_friendlyName, bytes, length) != 0;
  if (!changed) {
    notify(connHandle, _friendlyNameHandle, bytes, length);
    ESP_LOGD(TAG, "BLE FRIENDLY NAME: unchanged %s\n", _friendlyName);
    return;
  }

  NvsNamespace storage;
  if (storage.open(CONFIG_NAMESPACE, NVS_READWRITE) != ESP_OK) {
    ESP_LOGE(TAG, "BLE FRIENDLY NAME: persistent write failed");
    return;
  }
  if (storage.setBlob(FRIENDLY_NAME_KEY, bytes, length) != ESP_OK ||
      storage.commit() != ESP_OK) {
    ESP_LOGE(TAG, "BLE FRIENDLY NAME: persistent write failed");
    return;
  }

  portENTER_CRITICAL(&_snapshotLock);
  memcpy(_friendlyName, bytes, length);
  _friendlyName[length] = '\0';
  portEXIT_CRITICAL(&_snapshotLock);
  notify(connHandle, _friendlyNameHandle, bytes, length);
  ESP_LOGD(TAG, "BLE FRIENDLY NAME: saved %s\n", _friendlyName);
}

void BleManager::setMatterOnboardingPayload(const char *payload) {
  if (payload == nullptr) return;
  const size_t length = strnlen(payload, sizeof(_matterOnboardingPayload));
  if (length == 0 || length >= sizeof(_matterOnboardingPayload)) {
    ESP_LOGW(TAG, "BLE MATTER SETUP: invalid onboarding payload rejected");
    return;
  }
  portENTER_CRITICAL(&_snapshotLock);
  memcpy(_matterOnboardingPayload, payload, length);
  _matterOnboardingPayload[length] = '\0';
  portEXIT_CRITICAL(&_snapshotLock);
  ESP_LOGD(TAG, "BLE MATTER SETUP: authenticated handoff payload ready");
}

void BleManager::processMatterOnboardingRequest(
  uint16_t connHandle,
  const uint8_t *bytes,
  size_t length
) {
  if (length != 1 || bytes[0] != BLE_PROTOCOL_VERSION) {
    ESP_LOGW(TAG, "BLE MATTER SETUP: malformed request rejected");
    return;
  }
  if (!_security.isAuthenticated(connHandle)) {
    ESP_LOGW(TAG, "BLE MATTER SETUP: unauthorized request rejected");
    return;
  }
  uint8_t payload[sizeof(_matterOnboardingPayload)] = {};
  size_t payloadLength = 0;
  portENTER_CRITICAL(&_snapshotLock);
  payloadLength = strnlen(
    _matterOnboardingPayload,
    sizeof(_matterOnboardingPayload)
  );
  memcpy(payload, _matterOnboardingPayload, payloadLength);
  portEXIT_CRITICAL(&_snapshotLock);
  if (payloadLength == 0 ||
      !notify(connHandle, _matterOnboardingHandle, payload, payloadLength)) {
    ESP_LOGE(TAG, "BLE MATTER SETUP: payload unavailable or notification failed");
    return;
  }
  ESP_LOGD(TAG, "BLE MATTER SETUP: payload delivered to authenticated owner");
}

void BleManager::processCommand(uint16_t connHandle, const uint8_t *bytes, size_t length) {
  BleCommandPacket packet;
  BleProtocolResult error;
  if (!decodeBleCommand(bytes, length, packet, error)) {
    sendResponse(connHandle, error, BleOpcode::SetPower, 0);
    return;
  }
  if (!_security.isAuthenticated(connHandle)) {
    sendResponse(connHandle, BleProtocolResult::Unauthorized, packet.opcode, packet.requestId);
    return;
  }
  DeviceCommand command;
  const bool togglesPower = packet.opcode == BleOpcode::TogglePower;
  if (!togglesPower && !bleCommandToDeviceCommand(packet, command)) {
    sendResponse(connHandle,
      BleProtocolResult::UnsupportedCommand,
      packet.opcode,
      packet.requestId
    );
    return;
  }
  if (!togglesPower && command.type == DeviceCommandType::SetBreezeMode &&
      command.value > 3 && !_breezeStore.hasMode(static_cast<uint8_t>(command.value))) {
    sendResponse(connHandle, BleProtocolResult::InvalidValue, packet.opcode, packet.requestId);
    return;
  }
  CommandResult result;
  if (togglesPower) {
    command = {
      DeviceCommandType::SetPower,
      0,
      {CommandOrigin::Ble, packet.requestId}
    };
    result = _controller.togglePower(command.metadata);
    command.value = _controller.state().power ? 1 : 0;
  } else {
    result = _controller.submit(command);
  }
  ESP_LOGD(TAG,
    "BLE COMMAND: opcode=%u value=%d request=%lu result=%u\n",
    static_cast<unsigned>(packet.opcode),
    static_cast<int>(packet.value),
    static_cast<unsigned long>(packet.requestId),
    static_cast<unsigned>(result)
  );
  sendResponse(connHandle,
    bleResultFromCommandResult(result), packet.opcode, packet.requestId
  );
}

void BleManager::processBreezeSlot(
  uint16_t connHandle,
  uint8_t expectedSlot,
  const uint8_t *bytes,
  size_t length
) {
  if (!_security.isAuthenticated(connHandle)) {
    ESP_LOGW(TAG, "BLE BREEZE SLOT: unauthorized write rejected");
    return;
  }
  CustomBreezeProfile profile;
  if (!decodeCustomBreezeProfile(bytes, length, profile) ||
      profile.slot != expectedSlot || !_breezeStore.save(profile)) {
    ESP_LOGW(TAG, "BLE BREEZE SLOT %u: invalid profile rejected\n", expectedSlot + 1);
    return;
  }
  const uint8_t activeMode = customBreezeModeForSlot(expectedSlot);
  if (_controller.state().breezeMode == activeMode) {
    _controller.submit({
      DeviceCommandType::SetFanSpeed,
      _controller.state().targetFanSpeed,
      {CommandOrigin::System, 0}
    });
  }
  portENTER_CRITICAL(&_snapshotLock);
  memcpy(_breezeSlotValues[expectedSlot], bytes, CUSTOM_BREEZE_WIRE_SIZE);
  portEXIT_CRITICAL(&_snapshotLock);
  notifyAll(
    _breezeSlotHandles[expectedSlot], bytes, CUSTOM_BREEZE_WIRE_SIZE
  );
  ESP_LOGD(TAG,
    "BLE BREEZE SLOT %u: %s%s%s\n",
    expectedSlot + 1,
    profile.occupied ? "saved " : "cleared",
    profile.occupied ? profile.name : "",
    profile.occupied ? "" : ""
  );
}

void BleManager::processLogRequest(uint16_t connHandle, const uint8_t *bytes, size_t length) {
  if (!_security.isAuthenticated(connHandle)) return;
  BleLogPageRequest framedRequest;
  if (decodeBleLogPageRequest(bytes, length, framedRequest)) {
    DiagnosticRecord records[8];
    bool hasMore = false;
    const size_t count = _diagnosticLog.readPage(
      framedRequest.startSequence, records, framedRequest.maxRecords, hasMore
    );
    for (size_t i = 0; i < count; ++i) {
      uint8_t record[DIAGNOSTIC_RECORD_WIRE_SIZE];
      uint8_t frame[BLE_LOG_RECORD_FRAME_SIZE];
      if (encodeDiagnosticRecord(records[i], record, sizeof(record))) {
        encodeBleLogRecordFrame(framedRequest.requestId, record, frame);
        notify(connHandle, _logDataHandle, frame, sizeof(frame));
      }
    }
    BleLogPageComplete complete;
    complete.requestId = framedRequest.requestId;
    complete.returnedCount = static_cast<uint8_t>(count);
    complete.firstSequence = count == 0 ? 0 : records[0].sequence;
    complete.lastSequence = count == 0 ? framedRequest.startSequence : records[count - 1].sequence;
    complete.nextSequence = complete.lastSequence;
    complete.hasMore = hasMore;
    uint8_t frame[BLE_LOG_PAGE_COMPLETE_SIZE];
    encodeBleLogPageComplete(complete, frame);
    notify(connHandle, _logDataHandle, frame, sizeof(frame));
    return;
  }
  ESP_LOGW(TAG, "BLE DIAGNOSTICS: malformed page request rejected");
}

void BleManager::publishState() {
  portENTER_CRITICAL(&_snapshotLock);
  encodeBleState(_controller.state(), _stateValue);
  portEXIT_CRITICAL(&_snapshotLock);
  _publishedRevision = _controller.state().revision;
  _lastTelemetryPublishMs = DeviceClock::milliseconds();
  notifyAll(_stateHandle, _stateValue, sizeof(_stateValue));
}

void BleManager::processSecurity(uint16_t connHandle, const uint8_t *bytes, size_t length) {
  const uint16_t ownerHandle = _security.ownerConnectionHandle();
  if (ownerHandle != INVALID_CONNECTION_HANDLE && ownerHandle != connHandle) {
    ble_gap_conn_desc ownerDescription = {};
    if (ble_gap_conn_find(ownerHandle, &ownerDescription) != 0) {
      // Defense in depth: even if a disconnect callback was lost, never let a
      // nonexistent NimBLE handle permanently retain proprietary ownership.
      ESP_LOGD(TAG,
        "BLE SECURITY: clearing stale owner connection=%u\n",
        static_cast<unsigned>(ownerHandle)
      );
      clearConnection(ownerHandle);
    }
  }
  const bool wasAuthenticated = _security.isAuthenticated(connHandle);
  uint8_t response[BLE_SECURITY_PACKET_SIZE] = {};
  size_t responseLength = 0;
  const bool accepted = _security.handle(
    connHandle, bytes, length, DeviceClock::milliseconds(), response, responseLength
  );
  const bool isAuthenticated = _security.isAuthenticated(connHandle);
  if (!wasAuthenticated && isAuthenticated) {
    // The single BLE request-ID sequence belongs to the newly authenticated
    // proprietary session, never to unrelated NimBLE/Matter links.
    _controller.resetRequestSequence(CommandOrigin::Ble);
  }
  const bool delivered = responseLength != 0 &&
    notify(connHandle, _securityHandle, response, responseLength);
  ESP_LOGD(TAG,
    "BLE SECURITY: request=0x%02X accepted=%s response=0x%02X "
    "bytes=%u delivered=%s owned=%s authenticated=%s\n",
    length == 0 ? 0 : bytes[0],
    accepted ? "YES" : "NO",
    responseLength == 0 ? 0 : response[0],
    static_cast<unsigned>(responseLength),
    delivered ? "YES" : "NO",
    _security.isOwned() ? "YES" : "NO",
    isAuthenticated ? "YES" : "NO"
  );
}

bool BleManager::enterProvisioning() {
  const uint64_t nowMs = DeviceClock::milliseconds();
  _security.enterProvisioning(nowMs);
  const bool active = _security.isProvisioning(nowMs);
  if (active) {
    ESP_LOGI(TAG, "BLE SECURITY: physical provisioning window opened for 60 seconds");
  } else {
    ESP_LOGI(TAG, "BLE SECURITY: physical provisioning window not opened");
  }
  return active;
}

bool BleManager::cancelProvisioning() {
  const bool wasActive = isProvisioning();
  _security.cancelProvisioning();
  if (wasActive) {
    ESP_LOGI(TAG, "BLE SECURITY: physical provisioning window cancelled");
  }
  return wasActive;
}

void BleManager::physicalFactoryReset() {
  _security.factoryReset();
  _controller.resetRequestSequence(CommandOrigin::Ble);
  ESP_LOGD(TAG, "BLE SECURITY: ownership erased by physical recovery");
}

bool BleManager::isProvisioning() const {
  return _security.isProvisioning(DeviceClock::milliseconds());
}

void BleManager::publishMetadata() {
  const DiagnosticLogMetadata metadata = _diagnosticLog.metadata();
  portENTER_CRITICAL(&_snapshotLock);
  memset(_logMetadataValue, 0, sizeof(_logMetadataValue));
  _logMetadataValue[0] = BLE_PROTOCOL_VERSION;
  _logMetadataValue[1] = static_cast<uint8_t>(metadata.capacity);
  _logMetadataValue[2] = static_cast<uint8_t>(metadata.count);
  write32(_logMetadataValue + 4, metadata.oldestSequence);
  write32(_logMetadataValue + 8, metadata.newestSequence);
  write32(_logMetadataValue + 12, metadata.overwrittenCount);
  portEXIT_CRITICAL(&_snapshotLock);
}

void BleManager::sendResponse(
  uint16_t connHandle,
  BleProtocolResult result,
  BleOpcode opcode,
  uint32_t requestId
) {
  portENTER_CRITICAL(&_snapshotLock);
  encodeBleResponse(result, opcode, requestId, _responseValue);
  portEXIT_CRITICAL(&_snapshotLock);
  notify(connHandle, _responseHandle, _responseValue, sizeof(_responseValue));
}

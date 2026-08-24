#include "EspMatterFanEndpoint.h"

#include <app/server/Server.h>
#include <app-common/zap-generated/cluster-objects.h>
#include <esp_log.h>
#include <esp_system.h>
#include <nvs_flash.h>
#include <platform/ESP32/ESP32Config.h>
#include <setup_payload/OnboardingCodesUtil.h>

#include "DeviceClock.h"

using namespace chip::app::Clusters;

namespace {
constexpr char TAG[] = "MatterEndpoint";
constexpr uint8_t ROCK_LEFT_RIGHT =
  static_cast<uint8_t>(FanControl::RockBitmap::kRockLeftRight);
constexpr uint8_t FAN_MODE_OFF =
  static_cast<uint8_t>(FanControl::FanModeEnum::kOff);
constexpr uint8_t FAN_MODE_ON =
  static_cast<uint8_t>(FanControl::FanModeEnum::kOn);
constexpr uint8_t FAN_MODE_SEQUENCE =
  static_cast<uint8_t>(FanControl::FanModeSequenceEnum::kOffLowMedHigh);
constexpr uint16_t EXPECTED_FAN_ENDPOINT_ID = 1;
}

EspMatterFanEndpoint::EspMatterFanEndpoint(DeviceController &controller)
  : _controller(controller), _adapter(controller, *this) {}

bool EspMatterFanEndpoint::begin() {
  _writeQueue = xQueueCreate(8, sizeof(PendingWrite));
  if (_writeQueue == nullptr) {
    ESP_LOGE(TAG, "Unable to allocate command queue");
    return false;
  }

  esp_matter::node::config_t nodeConfig;
  _node = esp_matter::node::create(
    &nodeConfig,
    attributeUpdate,
    nullptr,
    nullptr
  );
  if (_node == nullptr) {
    ESP_LOGE(TAG, "Node creation failed");
    return false;
  }

  esp_matter::endpoint::fan::config_t fanConfig;
  fanConfig.fan_control.fan_mode = FAN_MODE_OFF;
  fanConfig.fan_control.fan_mode_sequence = FAN_MODE_SEQUENCE;
  fanConfig.fan_control.percent_setting = static_cast<uint8_t>(0);
  fanConfig.fan_control.percent_current = static_cast<uint8_t>(0);
  _endpoint = esp_matter::endpoint::fan::create(
    _node,
    &fanConfig,
    esp_matter::ENDPOINT_FLAG_NONE,
    this
  );
  if (_endpoint == nullptr) {
    ESP_LOGE(TAG, "Fan endpoint creation failed");
    return false;
  }
  _endpointId = esp_matter::endpoint::get_id(_endpoint);
  if (_endpointId != EXPECTED_FAN_ENDPOINT_ID) {
    ESP_LOGE(
      TAG,
      "Endpoint identity changed: expected %u, created %u",
      EXPECTED_FAN_ENDPOINT_ID,
      _endpointId
    );
    return false;
  }

  esp_matter::cluster_t *fanControl = esp_matter::cluster::get(
    _endpointId,
    FanControl::Id
  );
  esp_matter::cluster::fan_control::feature::rocking::config_t rocking;
  rocking.rock_support = ROCK_LEFT_RIGHT;
  rocking.rock_setting = 0;
  if (fanControl == nullptr ||
      esp_matter::cluster::fan_control::feature::rocking::add(
        fanControl,
        &rocking
      ) != ESP_OK) {
    ESP_LOGE(TAG, "Left/right rocking feature creation failed");
    return false;
  }

  char serialNumber[24] = {};
  snprintf(
    serialNumber,
    sizeof(serialNumber),
    "ProMist-%012llX",
    static_cast<unsigned long long>(
      _controller.state().identity.deviceId & 0xFFFFFFFFFFFFULL
    )
  );
  const CHIP_ERROR serialError =
    chip::DeviceLayer::Internal::ESP32Config::WriteConfigValueStr(
      chip::DeviceLayer::Internal::ESP32Config::kConfigKey_SerialNum,
      serialNumber
    );
  if (serialError != CHIP_NO_ERROR) {
    ESP_LOGE(
      TAG,
      "Serial persistence failed: %lu",
      static_cast<unsigned long>(serialError.AsInteger())
    );
    return false;
  }

  // Reconcile the endpoint to authoritative application state before the
  // server becomes externally visible, including after persisted Matter data
  // was restored by esp-matter.
  if (!_adapter.begin()) {
    ESP_LOGE(TAG, "DeviceController observer registration failed");
    return false;
  }

  const esp_err_t startResult = esp_matter::start(
    matterEvent,
    reinterpret_cast<intptr_t>(this)
  );
  if (startResult != ESP_OK) {
    ESP_LOGE(TAG, "esp-matter start failed: %s", esp_err_to_name(startResult));
    return false;
  }
  _started = true;

  chip::RendezvousInformationFlags rendezvous(
    chip::RendezvousInformationFlag::kBLE
  );
  chip::MutableCharSpan pairingCode(
    _manualPairingCode,
    sizeof(_manualPairingCode)
  );
  const CHIP_ERROR pairingResult = GetManualPairingCode(
    pairingCode,
    rendezvous
  );
  if (pairingResult != CHIP_NO_ERROR) {
    _manualPairingCode[0] = '\0';
    ESP_LOGE(
      TAG,
      "Manual pairing code generation failed: %lu",
      static_cast<unsigned long>(pairingResult.AsInteger())
    );
  }

  ESP_LOGI(TAG, "Native fan endpoint %u ready; left/right rocking enabled", _endpointId);
  ESP_LOGI(TAG, "Identity: Charles Foster ProMist firmware 1.0 serial %s", serialNumber);
  _lastCommissioned = isCommissioned();
  _controller.reportMatterCommissioning(commissioningState());
  if (!_lastCommissioned) printCommissioningInformation();
  return true;
}

void EspMatterFanEndpoint::update() {
  if (!_started) return;
  PendingWrite write;
  while (xQueueReceive(_writeQueue, &write, 0) == pdTRUE) {
    if (write.kind == PendingWriteKind::Mode) {
      _hasPendingMode = true;
      _pendingPower = write.value != FAN_MODE_OFF;
      _pendingFanWriteMs = DeviceClock::milliseconds();
    } else if (write.kind == PendingWriteKind::Percent) {
      _hasPendingPercent = true;
      _pendingPercent = write.value;
      _pendingFanWriteMs = DeviceClock::milliseconds();
    } else {
      const CommandResult result = _adapter.writeRocking(write.value != 0);
      if (result != CommandResult::Accepted && result != CommandResult::NoChange) {
        ESP_LOGW(TAG, "Rocking write rejected: %u", static_cast<unsigned>(result));
      }
    }
  }
  applyPendingFanWrite();

  (void)_commissioningStateMayHaveChanged.exchange(
    false,
    std::memory_order_acq_rel
  );
  const bool commissioned = isCommissioned();
  if (commissioned != _lastCommissioned) {
    _lastCommissioned = commissioned;
    _controller.reportMatterCommissioning(commissioningState());
    ESP_LOGI(TAG, "State=%s", commissioned ? "commissioned" : "commissionable");
  }
  if (!commissioned &&
      DeviceClock::milliseconds() - _lastStatusPrintMs >= 30000) {
    printCommissioningInformation();
  }
}

void EspMatterFanEndpoint::factoryResetAndRestart() {
  ESP_LOGW(TAG, "Erasing runtime NVS (Matter, Wi-Fi, BLE ownership, settings)");
  const esp_err_t result = nvs_flash_erase();
  if (result != ESP_OK) {
    ESP_LOGE(TAG, "NVS erase failed: %s (0x%x)", esp_err_to_name(result), result);
  }
  esp_restart();
}

MatterCommissioningState EspMatterFanEndpoint::commissioningState() const {
  if (!_started) return MatterCommissioningState::NotConfigured;
  return isCommissioned() ? MatterCommissioningState::Commissioned
                          : MatterCommissioningState::Commissionable;
}

void EspMatterFanEndpoint::setPower(bool value) {
  esp_matter_attr_val_t mode = esp_matter_enum8(
    value ? FAN_MODE_ON : FAN_MODE_OFF
  );
  (void)updateAttribute(FanControl::Attributes::FanMode::Id, mode);
}

void EspMatterFanEndpoint::setPercent(uint8_t value) {
  esp_matter_attr_val_t setting = esp_matter_nullable_uint8(value);
  esp_matter_attr_val_t current = esp_matter_uint8(value);
  (void)updateAttribute(FanControl::Attributes::PercentSetting::Id, setting);
  (void)updateAttribute(FanControl::Attributes::PercentCurrent::Id, current);
}

void EspMatterFanEndpoint::setRocking(bool value) {
  esp_matter_attr_val_t setting = esp_matter_bitmap8(
    value ? ROCK_LEFT_RIGHT : 0
  );
  (void)updateAttribute(FanControl::Attributes::RockSetting::Id, setting);
}

esp_err_t EspMatterFanEndpoint::attributeUpdate(
  esp_matter::attribute::callback_type_t type,
  uint16_t endpointId,
  uint32_t clusterId,
  uint32_t attributeId,
  esp_matter_attr_val_t *value,
  void *context
) {
  if (context == nullptr) return ESP_OK;
  return static_cast<EspMatterFanEndpoint *>(context)->handleAttributeUpdate(
    type,
    endpointId,
    clusterId,
    attributeId,
    value
  );
}

esp_err_t EspMatterFanEndpoint::handleAttributeUpdate(
  esp_matter::attribute::callback_type_t type,
  uint16_t endpointId,
  uint32_t clusterId,
  uint32_t attributeId,
  esp_matter_attr_val_t *value
) {
  if (type != esp_matter::attribute::PRE_UPDATE ||
      endpointId != _endpointId || clusterId != FanControl::Id ||
      value == nullptr || _publishing.load(std::memory_order_acquire)) {
    return ESP_OK;
  }

  // Do not retain Home/Matter writes received during physical BLE owner setup;
  // otherwise a queued write could execute immediately after pairing ends.
  if (_controller.bleProvisioningActive()) {
    return ESP_ERR_INVALID_STATE;
  }

  if (attributeId == FanControl::Attributes::FanMode::Id) {
    if (value->val.u8 > static_cast<uint8_t>(FanControl::FanModeEnum::kSmart)) {
      return ESP_ERR_INVALID_ARG;
    }
    return enqueueWrite(PendingWriteKind::Mode, value->val.u8)
      ? ESP_OK : ESP_ERR_NO_MEM;
  }
  if (attributeId == FanControl::Attributes::PercentSetting::Id) {
    const nullable<uint8_t> percent(value->val.u8);
    if (percent.is_null() || percent.value() > 100) return ESP_ERR_INVALID_ARG;
    return enqueueWrite(PendingWriteKind::Percent, percent.value())
      ? ESP_OK : ESP_ERR_NO_MEM;
  }
  if (attributeId == FanControl::Attributes::RockSetting::Id) {
    if ((value->val.u8 & ~ROCK_LEFT_RIGHT) != 0) return ESP_ERR_INVALID_ARG;
    return enqueueWrite(PendingWriteKind::Rocking, value->val.u8)
      ? ESP_OK : ESP_ERR_NO_MEM;
  }
  return ESP_OK;
}

void EspMatterFanEndpoint::matterEvent(
  const chip::DeviceLayer::ChipDeviceEvent *event,
  intptr_t context
) {
  auto *endpoint = reinterpret_cast<EspMatterFanEndpoint *>(context);
  if (event == nullptr || endpoint == nullptr) return;
  using namespace chip::DeviceLayer;
  switch (event->Type) {
    case DeviceEventType::kCHIPoBLEAdvertisingChange:
      ESP_LOGD(TAG, "BLE advertising state changed");
      break;
    case DeviceEventType::kCHIPoBLEConnectionEstablished:
      ESP_LOGI(TAG, "BLE commissioner connected");
      break;
    case DeviceEventType::kCHIPoBLEConnectionClosed:
      ESP_LOGI(TAG, "BLE commissioner disconnected");
      break;
    case DeviceEventType::kOperationalNetworkEnabled:
      ESP_LOGI(TAG, "Operational network enabled");
      break;
    case DeviceEventType::kWiFiConnectivityChange:
      ESP_LOGI(TAG, "Wi-Fi connectivity changed");
      break;
    case DeviceEventType::kFailSafeTimerExpired:
      ESP_LOGW(TAG, "Commissioning fail-safe expired");
      break;
    case DeviceEventType::kCommissioningComplete:
    case DeviceEventType::kServerReady:
      endpoint->_commissioningStateMayHaveChanged.store(
        true,
        std::memory_order_release
      );
      break;
    default:
      break;
  }
}

bool EspMatterFanEndpoint::enqueueWrite(
  PendingWriteKind kind,
  uint8_t value
) {
  if (_writeQueue == nullptr) return false;
  const PendingWrite write{kind, value};
  return xQueueSend(_writeQueue, &write, 0) == pdTRUE;
}

void EspMatterFanEndpoint::applyPendingFanWrite() {
  if ((!_hasPendingMode && !_hasPendingPercent) ||
      DeviceClock::milliseconds() - _pendingFanWriteMs <
        MATTER_WRITE_QUIET_MS) {
    return;
  }
  const bool hasPower = _hasPendingMode;
  const bool power = _pendingPower;
  const bool hasPercent = _hasPendingPercent;
  const uint8_t percent = _pendingPercent;
  _hasPendingMode = false;
  _hasPendingPercent = false;
  const CommandResult result = _adapter.writeAttributes(
    hasPower,
    power,
    hasPercent,
    percent
  );
  if (result != CommandResult::Accepted && result != CommandResult::NoChange) {
    ESP_LOGW(
      TAG,
      "Combined write rejected: power=%d percent=%u result=%u",
      power ? 1 : 0,
      static_cast<unsigned>(percent),
      static_cast<unsigned>(result)
    );
  } else if (result == CommandResult::NoChange) {
    const DeviceState &state = _controller.state();
    setPower(state.power);
    setPercent(state.power
      ? static_cast<uint8_t>(state.targetFanSpeed * 20U)
      : 0);
  }
}

void EspMatterFanEndpoint::printCommissioningInformation() {
  _lastStatusPrintMs = DeviceClock::milliseconds();
  ESP_LOGI(TAG, "Ready for commissioning");
  if (_manualPairingCode[0] != '\0') {
    ESP_LOGI(TAG, "Manual pairing code: %s", _manualPairingCode);
  }
  chip::RendezvousInformationFlags rendezvous(
    chip::RendezvousInformationFlag::kBLE
  );
  PrintOnboardingCodes(rendezvous);
}

bool EspMatterFanEndpoint::isCommissioned() const {
  return _started &&
    chip::Server::GetInstance().GetFabricTable().FabricCount() != 0;
}

bool EspMatterFanEndpoint::updateAttribute(
  uint32_t attributeId,
  esp_matter_attr_val_t &value
) {
  if (_endpointId == 0xFFFF) return false;
  _publishing.store(true, std::memory_order_release);
  esp_err_t result = ESP_OK;
  if (esp_matter::is_started()) {
    esp_matter::lock::ScopedChipStackLock lock(portMAX_DELAY);
    result = esp_matter::attribute::update(
      _endpointId,
      FanControl::Id,
      attributeId,
      &value
    );
  } else {
    result = esp_matter::attribute::set_val(
      _endpointId,
      FanControl::Id,
      attributeId,
      &value,
      false
    );
  }
  _publishing.store(false, std::memory_order_release);
  if (result != ESP_OK && result != ESP_ERR_NOT_FINISHED) {
    ESP_LOGE(
      TAG,
      "Attribute 0x%08lx update failed: %s",
      static_cast<unsigned long>(attributeId),
      esp_err_to_name(result)
    );
    return false;
  }
  return true;
}

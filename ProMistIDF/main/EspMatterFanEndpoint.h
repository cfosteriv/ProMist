#pragma once

#include <atomic>
#include <cstdint>

#include <esp_matter.h>
#include <freertos/FreeRTOS.h>
#include <freertos/queue.h>

#include "MatterFanAdapter.h"

// Owns the native esp-matter node, Fan endpoint, callbacks, and reporting.
// It deliberately has no access to GPIO or actuator controllers.
class EspMatterFanEndpoint final : public MatterFanAttributeSink {
 public:
  explicit EspMatterFanEndpoint(DeviceController &controller);

  /** Creates endpoint 1, reconciles initial attributes, and starts Matter. */
  bool begin();
  /** Drains queued CHIP writes and publishes commissioning-state changes. */
  void update();
  /** Erases Matter fabrics and restarts through the CHIP platform API. */
  void factoryResetAndRestart();
  /** Returns fabric-derived state observed by the application task. */
  MatterCommissioningState commissioningState() const;
  /** Returns the generated manual pairing code after begin(), or an empty string. */
  const char *manualPairingCode() const { return _manualPairingCode; }

  void setPower(bool value) override;
  void setPercent(uint8_t value) override;
  void setRocking(bool value) override;

 private:
  enum class PendingWriteKind : uint8_t { Mode, Percent, Rocking };
  struct PendingWrite {
    PendingWriteKind kind;
    uint8_t value;
  };

  DeviceController &_controller;
  MatterFanAdapter _adapter;
  esp_matter::node_t *_node = nullptr;
  esp_matter::endpoint_t *_endpoint = nullptr;
  uint16_t _endpointId = 0xFFFF;
  bool _started = false;
  bool _lastCommissioned = false;
  std::atomic<bool> _commissioningStateMayHaveChanged = false;
  std::atomic<bool> _publishing = false;
  uint64_t _lastStatusPrintMs = 0;
  QueueHandle_t _writeQueue = nullptr;
  bool _hasPendingMode = false;
  bool _pendingPower = false;
  bool _hasPendingPercent = false;
  uint8_t _pendingPercent = 0;
  uint64_t _pendingFanWriteMs = 0;
  char _manualPairingCode[21] = {};

  static constexpr uint32_t MATTER_WRITE_QUIET_MS = 20;

  static esp_err_t attributeUpdate(
    esp_matter::attribute::callback_type_t type,
    uint16_t endpointId,
    uint32_t clusterId,
    uint32_t attributeId,
    esp_matter_attr_val_t *value,
    void *context
  );
  static void matterEvent(
    const chip::DeviceLayer::ChipDeviceEvent *event,
    intptr_t context
  );

  esp_err_t handleAttributeUpdate(
    esp_matter::attribute::callback_type_t type,
    uint16_t endpointId,
    uint32_t clusterId,
    uint32_t attributeId,
    esp_matter_attr_val_t *value
  );
  bool enqueueWrite(PendingWriteKind kind, uint8_t value);
  void applyPendingFanWrite();
  void printCommissioningInformation();
  bool isCommissioned() const;
  bool updateAttribute(uint32_t attributeId, esp_matter_attr_val_t &value);
};

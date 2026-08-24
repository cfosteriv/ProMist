#pragma once

// Public, hardware-independent wire contract for proprietary BLE v2.

#include <cstddef>
#include <cstdint>

#include "DeviceController.h"

constexpr uint8_t BLE_PROTOCOL_VERSION = 2;
constexpr uint8_t BLE_HARDWARE_REVISION = 1;
constexpr size_t BLE_DEVICE_INFORMATION_SIZE = 16;
constexpr size_t BLE_COMMAND_SIZE = 8;
constexpr size_t BLE_RESPONSE_SIZE = 8;
// Retained for the app's reconnect window while installed firmware is updated.
constexpr size_t BLE_LEGACY_STATE_SIZE = 24;
constexpr size_t BLE_STATE_SIZE = 32;
constexpr size_t BLE_LOG_PAGE_REQUEST_SIZE = 12;
constexpr size_t BLE_LOG_RECORD_FRAME_SIZE = 28;
constexpr size_t BLE_LOG_PAGE_COMPLETE_SIZE = 24;

enum class BleDeviceFeature : uint16_t {
  FanControl = 1U << 0,
  MistControl = 1U << 1,
  Oscillation = 1U << 2,
  Positioning = 1U << 3,
  BreezeModes = 1U << 4,
  Diagnostics = 1U << 5,
  Rename = 1U << 6,
  Matter = 1U << 7,
  Timer = 1U << 8,
  FaultRecovery = 1U << 9
  // Bits 10...15 are reserved for future device capabilities.
};

constexpr uint16_t bleFeatureBit(BleDeviceFeature feature) {
  return static_cast<uint16_t>(feature);
}

constexpr uint16_t BLE_CURRENT_DEVICE_FEATURES =
  bleFeatureBit(BleDeviceFeature::FanControl) |
  bleFeatureBit(BleDeviceFeature::MistControl) |
  bleFeatureBit(BleDeviceFeature::Oscillation) |
  bleFeatureBit(BleDeviceFeature::Positioning) |
  bleFeatureBit(BleDeviceFeature::BreezeModes) |
  bleFeatureBit(BleDeviceFeature::Diagnostics) |
  bleFeatureBit(BleDeviceFeature::Rename) |
  bleFeatureBit(BleDeviceFeature::Matter) |
  bleFeatureBit(BleDeviceFeature::Timer) |
  bleFeatureBit(BleDeviceFeature::FaultRecovery);

enum class BleLogFrameType : uint8_t { Record = 1, PageComplete = 2 };

struct BleLogPageRequest {
  uint8_t maxRecords = 0;
  uint32_t startSequence = 0;
  uint32_t requestId = 0;
};

struct BleLogPageComplete {
  uint32_t requestId = 0;
  uint32_t firstSequence = 0;
  uint32_t lastSequence = 0;
  uint8_t returnedCount = 0;
  uint32_t nextSequence = 0;
  bool hasMore = false;
};

enum class BleOpcode : uint8_t {
  SetPower = 1,
  SetFanSpeed = 2,
  SetMistMode = 3,
  SetBreezeMode = 4,
  SetOscillationMode = 5,
  SetDirection = 6,
  SetOscillationPosition = 7,
  TogglePower = 8,
  SetTimerMinutes = 9,
  ClearFaults = 10
};

enum class BleProtocolResult : uint8_t {
  Success = 0,
  NoChange = 1,
  Malformed = 2,
  UnsupportedVersion = 3,
  UnsupportedCommand = 4,
  InvalidValue = 5,
  InvalidTransition = 6,
  DuplicateRequest = 7,
  Unauthorized = 8
};

struct BleCommandPacket {
  BleOpcode opcode = BleOpcode::SetPower;
  int16_t value = 0;
  uint32_t requestId = 0;
};

/// Encodes the fixed 16-byte device-information value. Feature flags and the
/// device ID are little-endian; bytes 14...15 remain reserved and zero.
void encodeBleDeviceInformation(
  uint64_t deviceId,
  uint8_t output[BLE_DEVICE_INFORMATION_SIZE]
);

/// Decodes and validates one command packet.
/// @param bytes Untrusted GATT payload bytes.
/// @param length Available byte count; it must equal BLE_COMMAND_SIZE.
/// @param packet Receives the decoded opcode, signed value, and request ID.
/// @param error Receives the precise protocol rejection when decoding fails.
/// @return true only when every field, including version/reserved bytes, is valid.
bool decodeBleCommand(
  const uint8_t *bytes,
  size_t length,
  BleCommandPacket &packet,
  BleProtocolResult &error
);
/// Encodes the result correlated to the original opcode and request ID.
void encodeBleResponse(
  BleProtocolResult result,
  BleOpcode opcode,
  uint32_t requestId,
  uint8_t output[BLE_RESPONSE_SIZE]
);
/// Serializes an authoritative controller snapshot into BLE_STATE_SIZE bytes.
void encodeBleState(
  const DeviceState &state,
  uint8_t output[BLE_STATE_SIZE]
);
/// Maps a decoded BLE operation into the transport-neutral domain command.
/// TogglePower is intentionally handled by the controller's atomic toggle API.
bool bleCommandToDeviceCommand(
  const BleCommandPacket &packet,
  DeviceCommand &command
);
/** Maps domain acceptance/rejection into the proprietary response code. */
BleProtocolResult bleResultFromCommandResult(CommandResult result);
/** Decodes an authenticated diagnostic page request. */
bool decodeBleLogPageRequest(const uint8_t *bytes, size_t length, BleLogPageRequest &request);
/** Encodes one diagnostic record with the page request ID prefix. */
void encodeBleLogRecordFrame(uint32_t requestId, const uint8_t record[20], uint8_t output[BLE_LOG_RECORD_FRAME_SIZE]);
/** Encodes the terminal cursor/count frame for a diagnostic page. */
void encodeBleLogPageComplete(const BleLogPageComplete &complete, uint8_t output[BLE_LOG_PAGE_COMPLETE_SIZE]);

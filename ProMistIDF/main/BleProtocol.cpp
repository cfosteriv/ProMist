// Pure BLE v2 codec and command mapper. No radio or hardware dependency is used
// so the byte contract can be compiled and tested on the host.
#include "BleProtocol.h"

#include <cstring>

namespace {

void write32(uint8_t *output, uint32_t value) {
  for (uint8_t i = 0; i < 4; ++i) {
    output[i] = static_cast<uint8_t>(value >> (8 * i));
  }
}

uint32_t read32(const uint8_t *input) {
  uint32_t value = 0;
  for (uint8_t i = 0; i < 4; ++i) {
    value |= static_cast<uint32_t>(input[i]) << (8 * i);
  }
  return value;
}

}  // namespace

void encodeBleDeviceInformation(
  uint64_t deviceId,
  uint8_t output[BLE_DEVICE_INFORMATION_SIZE]
) {
  memset(output, 0, BLE_DEVICE_INFORMATION_SIZE);
  output[0] = BLE_PROTOCOL_VERSION;
  output[1] = BLE_HARDWARE_REVISION;
  output[2] = static_cast<uint8_t>(BLE_CURRENT_DEVICE_FEATURES);
  output[3] = static_cast<uint8_t>(BLE_CURRENT_DEVICE_FEATURES >> 8);
  for (uint8_t i = 0; i < 8; ++i) {
    output[4 + i] = static_cast<uint8_t>(deviceId >> (8 * i));
  }
  // Existing firmware-version slot: minor=0, major=2, patch=0, reserved=0.
  output[13] = 2;
}

bool decodeBleCommand(
  const uint8_t *bytes,
  size_t length,
  BleCommandPacket &packet,
  BleProtocolResult &error
) {
  if (bytes == nullptr || length != BLE_COMMAND_SIZE) {
    error = BleProtocolResult::Malformed;
    return false;
  }
  if (bytes[0] != BLE_PROTOCOL_VERSION) {
    error = BleProtocolResult::UnsupportedVersion;
    return false;
  }
  if (bytes[2] != 0) {
    error = BleProtocolResult::Malformed;
    return false;
  }
  const uint8_t opcode = bytes[1];
  if (
    opcode < static_cast<uint8_t>(BleOpcode::SetPower) ||
    opcode > static_cast<uint8_t>(BleOpcode::ClearFaults)
  ) {
    error = BleProtocolResult::UnsupportedCommand;
    return false;
  }
  packet.opcode = static_cast<BleOpcode>(opcode);
  packet.value = static_cast<int8_t>(bytes[3]);
  packet.requestId = read32(bytes + 4);
  if (packet.requestId == 0) {
    error = BleProtocolResult::Malformed;
    return false;
  }
  error = BleProtocolResult::Success;
  return true;
}

void encodeBleResponse(
  BleProtocolResult result,
  BleOpcode opcode,
  uint32_t requestId,
  uint8_t output[BLE_RESPONSE_SIZE]
) {
  output[0] = BLE_PROTOCOL_VERSION;
  output[1] = static_cast<uint8_t>(result);
  output[2] = static_cast<uint8_t>(opcode);
  output[3] = 0;
  write32(output + 4, requestId);
}

void encodeBleState(
  const DeviceState &state,
  uint8_t output[BLE_STATE_SIZE]
) {
  const bool hasPositionTarget =
    state.oscillationPositioning &&
    state.oscillationTargetPosition >= -3 &&
    state.oscillationTargetPosition <= 3;
  output[0] = BLE_PROTOCOL_VERSION;
  output[1] = static_cast<uint8_t>(
    (state.power ? 0x01 : 0) |
    (state.fanSpeedConfirmed ? 0x02 : 0) |
    (hasPositionTarget ? 0x04 : 0) |
    (hasPositionTarget
      ? static_cast<uint8_t>(
          (state.oscillationTargetPosition + 3) << 3
        )
      : 0) |
    (static_cast<uint8_t>(state.matterCommissioning) << 6)
  );
  output[2] = state.targetFanSpeed;
  output[3] = state.mistMode;
  output[4] = state.breezeMode;
  output[5] = state.oscillationMode;
  output[6] = static_cast<uint8_t>(state.oscillationPosition);
  output[7] = static_cast<uint8_t>(state.fault);
  write32(output + 8, state.revision);
  write32(output + 12, state.uptimeSeconds);
  uint64_t id = state.identity.deviceId;
  for (uint8_t i = 0; i < 8; ++i) {
    output[16 + i] = static_cast<uint8_t>(id >> (8 * i));
  }
  write32(output + 24, state.timerRemainingSeconds);
  write32(output + 28, state.timerDurationSeconds);
}

bool bleCommandToDeviceCommand(
  const BleCommandPacket &packet,
  DeviceCommand &command
) {
  if (packet.opcode == BleOpcode::TogglePower) {
    return false;
  }
  if (packet.opcode == BleOpcode::SetTimerMinutes) {
    command.type = DeviceCommandType::SetTimerMinutes;
    command.value = packet.value;
    command.metadata = {CommandOrigin::Ble, packet.requestId};
    return true;
  }
  if (packet.opcode == BleOpcode::ClearFaults) {
    command.type = DeviceCommandType::ClearFaults;
    command.value = packet.value;
    command.metadata = {CommandOrigin::Ble, packet.requestId};
    return true;
  }
  if (
    static_cast<uint8_t>(packet.opcode) < 1 ||
    static_cast<uint8_t>(packet.opcode) > 7
  ) {
    return false;
  }
  command.type = static_cast<DeviceCommandType>(
    static_cast<uint8_t>(packet.opcode) - 1
  );
  command.value = packet.value;
  command.metadata = {CommandOrigin::Ble, packet.requestId};
  return true;
}

BleProtocolResult bleResultFromCommandResult(CommandResult result) {
  switch (result) {
    case CommandResult::Accepted: return BleProtocolResult::Success;
    case CommandResult::NoChange: return BleProtocolResult::NoChange;
    case CommandResult::InvalidValue: return BleProtocolResult::InvalidValue;
    case CommandResult::InvalidTransition:
      return BleProtocolResult::InvalidTransition;
    case CommandResult::DuplicateRequest:
      return BleProtocolResult::DuplicateRequest;
  }
  return BleProtocolResult::Malformed;
}

bool decodeBleLogPageRequest(const uint8_t *bytes, size_t length, BleLogPageRequest &request) {
  if (bytes == nullptr || length != BLE_LOG_PAGE_REQUEST_SIZE ||
      bytes[0] != BLE_PROTOCOL_VERSION || bytes[1] == 0 || bytes[1] > 8 ||
      bytes[2] != 0 || bytes[3] != 0) return false;
  request.maxRecords = bytes[1];
  request.startSequence = read32(bytes + 4);
  request.requestId = read32(bytes + 8);
  return request.requestId != 0;
}

void encodeBleLogRecordFrame(uint32_t requestId, const uint8_t record[20], uint8_t output[BLE_LOG_RECORD_FRAME_SIZE]) {
  output[0] = BLE_PROTOCOL_VERSION;
  output[1] = static_cast<uint8_t>(BleLogFrameType::Record);
  output[2] = output[3] = 0;
  write32(output + 4, requestId);
  memcpy(output + 8, record, 20);
}

void encodeBleLogPageComplete(const BleLogPageComplete &complete, uint8_t output[BLE_LOG_PAGE_COMPLETE_SIZE]) {
  memset(output, 0, BLE_LOG_PAGE_COMPLETE_SIZE);
  output[0] = BLE_PROTOCOL_VERSION;
  output[1] = static_cast<uint8_t>(BleLogFrameType::PageComplete);
  output[2] = complete.hasMore ? 1 : 0;
  write32(output + 4, complete.requestId);
  write32(output + 8, complete.firstSequence);
  write32(output + 12, complete.lastSequence);
  output[16] = complete.returnedCount;
  write32(output + 20, complete.nextSequence);
}

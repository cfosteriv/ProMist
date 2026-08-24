// Pins the firmware's versioned BLE byte contract, invalid-input behavior,
// command mapping, and request-ID rules without requiring a radio.
#include <cassert>
#include <cstring>

#include "BleProtocol.h"

int main() {
  // Canonical current-device manifest: 0201ff03080706050403020100020000
  uint8_t information[BLE_DEVICE_INFORMATION_SIZE];
  const uint8_t expectedInformation[BLE_DEVICE_INFORMATION_SIZE] = {
    0x02, 0x01, 0xFF, 0x03, 0x08, 0x07, 0x06, 0x05,
    0x04, 0x03, 0x02, 0x01, 0x00, 0x02, 0x00, 0x00
  };
  encodeBleDeviceInformation(0x0102030405060708ULL, information);
  assert(std::memcmp(information, expectedInformation, sizeof(information)) == 0);
  assert(BLE_PROTOCOL_VERSION == 2 && BLE_HARDWARE_REVISION == 1);
  assert(bleFeatureBit(BleDeviceFeature::FanControl) == 0x0001);
  assert(bleFeatureBit(BleDeviceFeature::MistControl) == 0x0002);
  assert(bleFeatureBit(BleDeviceFeature::Oscillation) == 0x0004);
  assert(bleFeatureBit(BleDeviceFeature::Positioning) == 0x0008);
  assert(bleFeatureBit(BleDeviceFeature::BreezeModes) == 0x0010);
  assert(bleFeatureBit(BleDeviceFeature::Diagnostics) == 0x0020);
  assert(bleFeatureBit(BleDeviceFeature::Rename) == 0x0040);
  assert(bleFeatureBit(BleDeviceFeature::Matter) == 0x0080);
  assert(bleFeatureBit(BleDeviceFeature::Timer) == 0x0100);
  assert(bleFeatureBit(BleDeviceFeature::FaultRecovery) == 0x0200);
  assert(BLE_CURRENT_DEVICE_FEATURES == 0x03FF);

  // Canonical fixture: 0203000178563412
  uint8_t mistFixture[BLE_COMMAND_SIZE] = {2, 3, 0, 1, 0x78, 0x56, 0x34, 0x12};
  BleCommandPacket fixturePacket;
  BleProtocolResult fixtureError;
  assert(decodeBleCommand(mistFixture, sizeof(mistFixture), fixturePacket, fixtureError));
  assert(fixturePacket.opcode == BleOpcode::SetMistMode);
  assert(fixturePacket.value == 1 && fixturePacket.requestId == 0x12345678);

  // Canonical fixture: 0208030078563412
  uint8_t responseFixture[BLE_RESPONSE_SIZE] = {};
  const uint8_t expectedResponse[BLE_RESPONSE_SIZE] = {2, 8, 3, 0, 0x78, 0x56, 0x34, 0x12};
  encodeBleResponse(BleProtocolResult::Unauthorized, BleOpcode::SetMistMode,
                    0x12345678, responseFixture);
  assert(std::memcmp(responseFixture, expectedResponse, BLE_RESPONSE_SIZE) == 0);

  uint8_t bytes[BLE_COMMAND_SIZE] = {2, 2, 0, 5, 42, 0, 0, 0};
  BleCommandPacket packet;
  BleProtocolResult error;
  assert(decodeBleCommand(bytes, sizeof(bytes), packet, error));
  assert(packet.opcode == BleOpcode::SetFanSpeed);
  assert(packet.value == 5);
  assert(packet.requestId == 42);

  DeviceCommand command;
  assert(bleCommandToDeviceCommand(packet, command));
  assert(command.type == DeviceCommandType::SetFanSpeed);
  assert(command.metadata.origin == CommandOrigin::Ble);

  assert(!decodeBleCommand(bytes, 7, packet, error));
  assert(error == BleProtocolResult::Malformed);
  bytes[0] = 1;
  assert(!decodeBleCommand(bytes, sizeof(bytes), packet, error));
  assert(error == BleProtocolResult::UnsupportedVersion);
  bytes[0] = 2;
  bytes[1] = 99;
  assert(!decodeBleCommand(bytes, sizeof(bytes), packet, error));
  assert(error == BleProtocolResult::UnsupportedCommand);
  bytes[1] = 7;
  bytes[3] = static_cast<uint8_t>(-3);
  assert(decodeBleCommand(bytes, sizeof(bytes), packet, error));
  assert(packet.opcode == BleOpcode::SetOscillationPosition);
  assert(packet.value == -3);
  assert(bleCommandToDeviceCommand(packet, command));
  assert(command.type == DeviceCommandType::SetOscillationPosition);
  bytes[1] = 8;
  bytes[3] = 0;
  assert(decodeBleCommand(bytes, sizeof(bytes), packet, error));
  assert(packet.opcode == BleOpcode::TogglePower);
  assert(!bleCommandToDeviceCommand(packet, command));
  bytes[1] = 9;
  bytes[3] = 45;
  assert(decodeBleCommand(bytes, sizeof(bytes), packet, error));
  assert(bleCommandToDeviceCommand(packet, command));
  assert(command.type == DeviceCommandType::SetTimerMinutes);
  bytes[1] = 10;
  bytes[3] = 0;
  assert(decodeBleCommand(bytes, sizeof(bytes), packet, error));
  assert(packet.opcode == BleOpcode::ClearFaults);
  assert(bleCommandToDeviceCommand(packet, command));
  assert(command.type == DeviceCommandType::ClearFaults);
  bytes[1] = 1;
  std::memset(bytes + 4, 0, 4);
  assert(!decodeBleCommand(bytes, sizeof(bytes), packet, error));

  DeviceState state;
  state.power = true;
  state.targetFanSpeed = 4;
  state.oscillationPosition = -2;
  state.oscillationPositioning = true;
  state.oscillationTargetPosition = 3;
  state.revision = 0x12345678;
  state.identity.deviceId = 0x0102030405060708ULL;
  state.timerRemainingSeconds = 899;
  state.timerDurationSeconds = 900;
  uint8_t encoded[BLE_STATE_SIZE] = {};
  encodeBleState(state, encoded);
  assert(encoded[0] == 2);
  assert((encoded[1] & 1) != 0);
  assert((encoded[1] & 0x04) != 0);
  assert(((encoded[1] >> 3) & 0x07) == 6);
  assert(encoded[2] == 4);
  assert(static_cast<int8_t>(encoded[6]) == -2);
  assert(encoded[8] == 0x78);
  assert(encoded[16] == 0x08);
  assert(encoded[23] == 0x01);
  assert(encoded[24] == 0x83 && encoded[25] == 0x03);
  assert(encoded[28] == 0x84 && encoded[29] == 0x03);

  uint8_t requestBytes[BLE_LOG_PAGE_REQUEST_SIZE] = {2, 8, 0, 0, 9, 0, 0, 0, 44, 0, 0, 0};
  BleLogPageRequest logRequest;
  assert(decodeBleLogPageRequest(requestBytes, sizeof(requestBytes), logRequest));
  assert(logRequest.startSequence == 9 && logRequest.requestId == 44);
  requestBytes[8] = 0;
  assert(!decodeBleLogPageRequest(requestBytes, sizeof(requestBytes), logRequest));

  uint8_t record[20] = {};
  record[0] = 10;
  uint8_t recordFrame[BLE_LOG_RECORD_FRAME_SIZE];
  encodeBleLogRecordFrame(44, record, recordFrame);
  assert(recordFrame[0] == 2 && recordFrame[1] == 1 && recordFrame[4] == 44);
  assert(recordFrame[8] == 10);

  BleLogPageComplete completion{44, 10, 17, 8, 17, true};
  uint8_t completionFrame[BLE_LOG_PAGE_COMPLETE_SIZE];
  encodeBleLogPageComplete(completion, completionFrame);
  assert(completionFrame[1] == 2 && completionFrame[2] == 1);
  assert(completionFrame[4] == 44 && completionFrame[8] == 10);
  assert(completionFrame[12] == 17 && completionFrame[16] == 8);
}

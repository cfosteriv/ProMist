#include <cassert>

#include "BleSessionOwnership.h"
#include "DeviceController.h"

namespace {
DeviceCommand command(uint32_t requestId, int32_t speed) {
  return {
    DeviceCommandType::SetFanSpeed,
    speed,
    {CommandOrigin::Ble, requestId}
  };
}
}

int main() {
  constexpr uint16_t connectionA = 7;
  constexpr uint16_t connectionB = 9;

  BleSessionOwnership ownership;
  DeviceController controller;
  assert(controller.submit({
    DeviceCommandType::SetPower, 1, {CommandOrigin::PhysicalUi, 1}
  }) == CommandResult::Accepted);

  // A authenticates and receives a clean proprietary request sequence.
  assert(ownership.authenticate(connectionA));
  assert(ownership.hasOwner());
  assert(ownership.owner() == connectionA);
  assert(controller.resetRequestSequence(CommandOrigin::Ble));
  assert(controller.submit(command(1, 2)) == CommandResult::Accepted);
  assert(controller.submit(command(2, 3)) == CommandResult::Accepted);

  // B may share the NimBLE host, but cannot acquire or disturb A's session.
  assert(!ownership.canAuthenticate(connectionB));
  assert(!ownership.authenticate(connectionB));
  assert(!ownership.disconnect(connectionB));
  assert(ownership.owns(connectionA));
  assert(controller.submit(command(2, 4)) == CommandResult::DuplicateRequest);
  assert(controller.submit(command(3, 4)) == CommandResult::Accepted);

  // Disconnecting A invalidates its ownership and sequence.
  assert(ownership.disconnect(connectionA));
  assert(!ownership.owns(connectionA));
  assert(!ownership.hasOwner());
  assert(ownership.owner() == BleSessionOwnership::INVALID_CONNECTION_HANDLE);
  assert(controller.resetRequestSequence(CommandOrigin::Ble));

  // A newly authenticated session starts request numbering from a clean state.
  assert(ownership.authenticate(connectionB));
  assert(controller.resetRequestSequence(CommandOrigin::Ble));
  assert(controller.submit(command(1, 5)) == CommandResult::Accepted);
}

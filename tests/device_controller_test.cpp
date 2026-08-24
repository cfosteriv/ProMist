// Exercises the central state/transition authority, including origin-specific
// sequencing, observer publication, safety semantics, and wraparound IDs.
#include <cassert>
#include <cstdint>
#include <string>

#include "DeviceController.h"

struct Observation {
  uint32_t calls = 0;
  uint32_t revision = 0;
  CommandOrigin origin = CommandOrigin::System;
};

struct CommandObservation {
  uint32_t calls = 0;
  DeviceCommand command;
  CommandResult result = CommandResult::InvalidValue;
};

static void observe(const DeviceState &state, void *context) {
  auto *observation = static_cast<Observation *>(context);
  ++observation->calls;
  observation->revision = state.revision;
  observation->origin = state.lastCommand.origin;
}

static void observeCommand(
  const DeviceCommand &command,
  CommandResult result,
  void *context
) {
  auto *observation = static_cast<CommandObservation *>(context);
  ++observation->calls;
  observation->command = command;
  observation->result = result;
}

static DeviceCommand command(
  DeviceCommandType type,
  int32_t value,
  CommandOrigin origin,
  uint32_t requestId
) {
  return {type, value, {origin, requestId}};
}

int main() {
  DeviceController provisioningController;
  assert(!provisioningController.bleProvisioningActive());
  provisioningController.setBleProvisioningActive(true);
  assert(provisioningController.bleProvisioningActive());

  // Physical pairing mode is an authoritative external-command gate, not a
  // transport convention. Rejected IDs remain retryable once setup ends.
  assert(provisioningController.submit(command(
           DeviceCommandType::SetPower, 1, CommandOrigin::PhysicalUi, 1
         )) == CommandResult::InvalidTransition);
  assert(provisioningController.submit(command(
           DeviceCommandType::SetPower, 1, CommandOrigin::RfRemote, 1
         )) == CommandResult::InvalidTransition);
  assert(provisioningController.submit(command(
           DeviceCommandType::SetPower, 1, CommandOrigin::Ble, 1
         )) == CommandResult::InvalidTransition);
  assert(provisioningController.submit(command(
           DeviceCommandType::SetPower, 1, CommandOrigin::Matter, 1
         )) == CommandResult::InvalidTransition);
  assert(provisioningController.submit(command(
           DeviceCommandType::SetPower, 1, CommandOrigin::Diagnostics, 1
         )) == CommandResult::InvalidTransition);
  assert(!provisioningController.state().power);
  assert(provisioningController.state().revision == 0);
  provisioningController.setBleProvisioningActive(false);
  assert(!provisioningController.bleProvisioningActive());
  assert(provisioningController.submit(command(
           DeviceCommandType::SetPower, 1, CommandOrigin::Ble, 1
         )) == CommandResult::Accepted);

  DeviceController wrappingController;
  assert(wrappingController.submit(command(
           DeviceCommandType::SetPower,
           1,
           CommandOrigin::Ble,
           UINT32_MAX
         )) == CommandResult::Accepted);
  assert(wrappingController.submit(command(
           DeviceCommandType::SetMistMode,
           1,
           CommandOrigin::Ble,
           1
         )) == CommandResult::Accepted);

  DeviceController controller;
  Observation observation;
  CommandObservation commandObservation;
  assert(controller.addObserver(observe, &observation));
  assert(controller.addCommandObserver(observeCommand, &commandObservation));
  assert(controller.initializeIdentity(0x102030405060ULL, "0.2.0-dev"));
  assert(!controller.initializeIdentity(7, "replacement"));
  assert(controller.state().identity.deviceId == 0x102030405060ULL);
  assert(std::string(controller.state().identity.manufacturer) ==
         "Charles Foster");
  assert(std::string(controller.state().identity.model) == "ProMist");
  assert(controller.state().firmwareVersion[0] == '0');
  assert(!controller.state().power);
  assert(controller.state().targetFanSpeed == 1);
  assert(
    controller.state().oscillationPosition ==
    OSCILLATION_POSITION_UNKNOWN
  );

  // Central range and transition validation.
  assert(controller.submit(command(DeviceCommandType::SetFanSpeed, 3,
                                   CommandOrigin::Ble, 1)) ==
         CommandResult::InvalidTransition);
  assert(controller.submit(command(DeviceCommandType::SetPower, 1,
                                   CommandOrigin::Ble, 0)) ==
         CommandResult::InvalidValue);
  assert(controller.submit(command(DeviceCommandType::SetPower, 2,
                                   CommandOrigin::Ble, 2)) ==
         CommandResult::InvalidValue);
  assert(controller.submit(command(DeviceCommandType::SetPower, 1,
                                   CommandOrigin::PhysicalUi, 1)) ==
         CommandResult::Accepted);
  assert(commandObservation.calls == 1);
  assert(commandObservation.command.type == DeviceCommandType::SetPower);
  assert(commandObservation.command.metadata.origin == CommandOrigin::PhysicalUi);
  assert(commandObservation.result == CommandResult::Accepted);
  assert(controller.submit(command(DeviceCommandType::SetFanSpeed, 0,
                                   CommandOrigin::Ble, 3)) ==
         CommandResult::InvalidValue);
  assert(controller.submit(command(DeviceCommandType::SetFanSpeed, 6,
                                   CommandOrigin::Ble, 4)) ==
         CommandResult::InvalidValue);

  // Accepted metadata, revision and independent per-origin sequencing.
  assert(controller.submit(command(DeviceCommandType::SetFanSpeed, 5,
                                   CommandOrigin::RfRemote, 10)) ==
         CommandResult::Accepted);
  assert(controller.state().targetFanSpeed == 5);
  assert(controller.state().lastCommand.origin == CommandOrigin::RfRemote);
  const uint32_t revision = controller.state().revision;
  assert(controller.submit(command(DeviceCommandType::SetFanSpeed, 4,
                                   CommandOrigin::RfRemote, 10)) ==
         CommandResult::DuplicateRequest);
  assert(controller.submit(command(DeviceCommandType::SetFanSpeed, 4,
                                   CommandOrigin::RfRemote, 9)) ==
         CommandResult::DuplicateRequest);
  assert(controller.state().revision == revision);
  assert(controller.submit(command(DeviceCommandType::SetFanSpeed, 4,
                                   CommandOrigin::Ble, 1)) ==
         CommandResult::Accepted);

  // No-change commands neither increment revision nor notify, but consume a
  // request ID so retransmission cannot later become a command.
  const uint32_t beforeNoChange = controller.state().revision;
  const uint32_t callsBeforeNoChange = observation.calls;
  assert(controller.submit(command(DeviceCommandType::SetFanSpeed, 4,
                                   CommandOrigin::Ble, 2)) ==
         CommandResult::NoChange);
  assert(commandObservation.command.type == DeviceCommandType::SetFanSpeed);
  assert(commandObservation.command.value == 4);
  assert(commandObservation.result == CommandResult::NoChange);
  assert(controller.state().revision == beforeNoChange);
  assert(observation.calls == callsBeforeNoChange);
  assert(controller.submit(command(DeviceCommandType::SetMistMode, 1,
                                   CommandOrigin::Ble, 2)) ==
         CommandResult::DuplicateRequest);
  assert(controller.resetRequestSequence(CommandOrigin::Ble));
  assert(!controller.resetRequestSequence(CommandOrigin::System));
  assert(controller.submit(command(DeviceCommandType::SetMistMode, 1,
                                   CommandOrigin::Ble, 1)) ==
         CommandResult::Accepted);

  // Fan selection cancels breeze; direction selection cancels oscillation.
  assert(controller.submit(command(DeviceCommandType::SetBreezeMode, 3,
                                   CommandOrigin::PhysicalUi, 2)) ==
         CommandResult::Accepted);
  assert(controller.reportBreezeFanTarget(3));
  assert(controller.state().targetFanSpeed == 3);
  assert(!controller.reportBreezeFanTarget(0));
  assert(controller.submit(command(DeviceCommandType::SetFanSpeed, 2,
                                   CommandOrigin::PhysicalUi, 3)) ==
         CommandResult::Accepted);
  assert(controller.state().breezeMode == 0);

  DeviceState poweredState;
  poweredState.power = true;
  DeviceController breezeRangeController(poweredState);
  assert(breezeRangeController.submit(command(DeviceCommandType::SetBreezeMode, 6,
                                              CommandOrigin::Ble, 1)) ==
         CommandResult::Accepted);
  assert(breezeRangeController.submit(command(DeviceCommandType::SetBreezeMode, 7,
                                              CommandOrigin::Ble, 2)) ==
         CommandResult::InvalidValue);
  assert(controller.submit(command(DeviceCommandType::SetOscillationMode, 3,
                                   CommandOrigin::Matter, 1)) ==
         CommandResult::Accepted);

  // The timer is device-owned, accepts only app presets, and expires into a
  // pending park-before-power-off sequence.
  DeviceController timerController;
  assert(timerController.submit(command(DeviceCommandType::SetPower, 1,
                                        CommandOrigin::Ble, 1)) ==
         CommandResult::Accepted);
  assert(timerController.submit(command(DeviceCommandType::SetTimerMinutes, 12,
                                        CommandOrigin::Ble, 2)) ==
         CommandResult::InvalidValue);
  assert(timerController.submit(command(DeviceCommandType::SetTimerMinutes, 15,
                                        CommandOrigin::Ble, 3)) ==
         CommandResult::Accepted);
  assert(timerController.submit(command(DeviceCommandType::SetTimerMinutes, 0,
                                        CommandOrigin::Ble, 4)) ==
         CommandResult::Accepted);
  assert(timerController.state().timerRemainingSeconds == 0);
  assert(timerController.submit(command(DeviceCommandType::SetTimerMinutes, 30,
                                        CommandOrigin::Ble, 5)) ==
         CommandResult::Accepted);
  // Even an absolute power write matching current power resets the timer.
  assert(timerController.submit(command(DeviceCommandType::SetPower, 1,
                                        CommandOrigin::Ble, 6)) ==
         CommandResult::Accepted);
  assert(timerController.state().timerRemainingSeconds == 0);
  assert(timerController.submit(command(DeviceCommandType::SetTimerMinutes, 15,
                                        CommandOrigin::Ble, 7)) ==
         CommandResult::Accepted);
  assert(timerController.state().timerRemainingSeconds == 900);
  assert(timerController.state().timerDurationSeconds == 900);
  assert(timerController.updateTimer(899));
  assert(timerController.state().timerRemainingSeconds == 1);
  assert(timerController.updateTimer(900));
  assert(timerController.state().timerRemainingSeconds == 0);
  assert(timerController.timerShutdownPending());
  assert(timerController.completeTimerShutdown() == CommandResult::Accepted);
  assert(!timerController.state().power);
  assert(!timerController.timerShutdownPending());
  assert(commandObservation.command.type ==
         DeviceCommandType::SetOscillationMode);
  assert(commandObservation.command.metadata.origin == CommandOrigin::Matter);
  assert(commandObservation.result == CommandResult::Accepted);
  assert(controller.submit(command(DeviceCommandType::SetDirection, -1,
                                   CommandOrigin::RfRemote, 11)) ==
         CommandResult::Accepted);
  assert(controller.state().oscillationMode == 0);
  assert(controller.state().direction ==
         DirectionRequest::CounterClockwiseJog);
  assert(controller.submit(command(
           DeviceCommandType::SetOscillationPosition, 3,
           CommandOrigin::Ble, 3
         )) == CommandResult::Accepted);
  assert(controller.state().oscillationMode == 0);
  assert(controller.submit(command(
           DeviceCommandType::SetOscillationPosition, 4,
           CommandOrigin::Ble, 4
         )) == CommandResult::InvalidValue);

  const uint32_t beforePosition = controller.state().revision;
  assert(controller.reportOscillationPosition(2));
  assert(controller.state().oscillationPosition == 2);
  assert(controller.state().revision == beforePosition + 1);
  assert(!controller.reportOscillationPosition(2));
  assert(!controller.reportOscillationPosition(4));
  assert(controller.reportOscillationMotion(true, 3));
  assert(controller.state().oscillationPositioning);
  assert(controller.state().oscillationTargetPosition == 3);
  assert(!controller.reportOscillationMotion(true, 3));
  assert(!controller.reportOscillationMotion(true, 4));
  assert(controller.reportOscillationMotion(false, 4));
  assert(!controller.state().oscillationPositioning);
  assert(
    controller.state().oscillationTargetPosition ==
    OSCILLATION_POSITION_UNKNOWN
  );

  // Observations are authoritative, revised, and do not masquerade as a
  // transport command. Routine uptime remains observable without revision churn.
  const uint32_t beforeObservation = controller.state().revision;
  assert(controller.reportFanSpeedConfirmed(true));
  assert(controller.state().revision == beforeObservation + 1);
  assert(controller.state().lastCommand.origin == CommandOrigin::System);
  assert(controller.reportFault(DeviceFault::FanSpeedLow));
  assert(!controller.reportFault(DeviceFault::FanSpeedLow));
  const uint32_t beforeUptime = controller.state().revision;
  assert(controller.reportSystemInfo(12, ResetReason::PowerOn));
  assert(controller.state().uptimeSeconds == 12);
  assert(controller.state().revision == beforeUptime + 1);
  const uint32_t afterResetReason = controller.state().revision;
  assert(controller.reportSystemInfo(13, ResetReason::PowerOn));
  assert(controller.state().revision == afterResetReason);

  DeviceState faultedState;
  faultedState.power = true;
  faultedState.targetFanSpeed = 5;
  faultedState.mistMode = 1;
  faultedState.oscillationMode = 3;
  faultedState.fault = DeviceFault::FanNotTurning;
  DeviceController recoveryController(faultedState);
  assert(recoveryController.submit(command(DeviceCommandType::ClearFaults, 1,
                                           CommandOrigin::Ble, 1)) ==
         CommandResult::InvalidValue);
  assert(recoveryController.submit(command(DeviceCommandType::ClearFaults, 0,
                                           CommandOrigin::Ble, 1)) ==
         CommandResult::Accepted);
  assert(recoveryController.state().fault == DeviceFault::None);
  assert(!recoveryController.state().power);
  assert(recoveryController.state().targetFanSpeed == 1);
  assert(recoveryController.state().mistMode == 0);
  assert(recoveryController.state().oscillationMode == 0);

  // Power-off centrally restores safe target defaults.
  assert(controller.submit(command(DeviceCommandType::SetPower, 0,
                                   CommandOrigin::PhysicalUi, 4)) ==
         CommandResult::Accepted);
  assert(!controller.state().power);
  assert(controller.state().targetFanSpeed == 1);
  assert(controller.state().mistMode == 0);
  assert(controller.state().breezeMode == 0);
  assert(controller.state().oscillationMode == 0);
  assert(
    controller.state().oscillationPosition ==
    OSCILLATION_POSITION_UNKNOWN
  );
  assert(!controller.state().fanSpeedConfirmed);

  // A toggle is resolved from the controller's current state, so interleaved
  // app, panel, RF, and Matter inputs cannot maintain independent power bits.
  assert(controller.submit(command(DeviceCommandType::SetPower, 1,
                                   CommandOrigin::Ble, 4)) ==
         CommandResult::Accepted);
  assert(controller.togglePower({CommandOrigin::PhysicalUi, 5}) ==
         CommandResult::Accepted);
  assert(!controller.state().power);
  assert(controller.togglePower({CommandOrigin::RfRemote, 12}) ==
         CommandResult::Accepted);
  assert(controller.state().power);
  assert(controller.submit(command(DeviceCommandType::SetPower, 0,
                                   CommandOrigin::Matter, 2)) ==
         CommandResult::Accepted);
  assert(controller.togglePower({CommandOrigin::Ble, 5}) ==
         CommandResult::Accepted);
  assert(controller.state().power);
}

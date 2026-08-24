// Authoritative logical state machine shared by every control surface. It
// validates before mutation and publishes immutable snapshots to observers.
#include "DeviceController.h"

DeviceController::DeviceController(const DeviceState &initialState)
  : _state(initialState) {}

const DeviceState &DeviceController::state() const {
  return _state;
}

bool DeviceController::initializeIdentity(
  uint64_t deviceId,
  const char *firmwareVersion
) {
  if (
    _identityInitialized ||
    deviceId == 0 ||
    firmwareVersion == nullptr ||
    firmwareVersion[0] == '\0'
  ) {
    return false;
  }
  _state.identity.deviceId = deviceId;
  _state.firmwareVersion = firmwareVersion;
  _identityInitialized = true;
  return true;
}

CommandResult DeviceController::submit(const DeviceCommand &command) {
  const size_t origin = static_cast<size_t>(command.metadata.origin);
  if (origin >= ORIGIN_COUNT) {
    return CommandResult::InvalidValue;
  }
  if (
    command.metadata.origin != CommandOrigin::System &&
    command.metadata.requestId == 0
  ) {
    return CommandResult::InvalidValue;
  }

  // Owner enrollment is a physically authorized appliance mode. Keep the
  // device off and stable while it is active, regardless of which external
  // transport happens to deliver a command.
  if (
    command.metadata.origin != CommandOrigin::System &&
    bleProvisioningActive()
  ) {
    return CommandResult::InvalidTransition;
  }

  if (
    command.metadata.requestId != 0 &&
    _requestSeen[origin] &&
    static_cast<int32_t>(
      command.metadata.requestId - _lastRequestIds[origin]
    ) <= 0
  ) {
    return CommandResult::DuplicateRequest;
  }

  if (!validate(command)) {
    return CommandResult::InvalidValue;
  }
  if (!transitionAllowed(command)) {
    return CommandResult::InvalidTransition;
  }

  if (command.metadata.requestId != 0) {
    _requestSeen[origin] = true;
    _lastRequestIds[origin] = command.metadata.requestId;
  }

  if (!apply(command)) {
    publishCommand(command, CommandResult::NoChange);
    return CommandResult::NoChange;
  }

  changed(command.metadata);
  publishCommand(command, CommandResult::Accepted);
  return CommandResult::Accepted;
}

CommandResult DeviceController::togglePower(const CommandMetadata &metadata) {
  // Resolve toggles at the authoritative state boundary. A caller must not
  // convert a possibly stale UI/transport snapshot into an absolute write.
  return submit({DeviceCommandType::SetPower, _state.power ? 0 : 1, metadata});
}

void DeviceController::setBleProvisioningActive(bool active) {
  _bleProvisioningActive.store(active, std::memory_order_release);
}

bool DeviceController::bleProvisioningActive() const {
  return _bleProvisioningActive.load(std::memory_order_acquire);
}

bool DeviceController::resetRequestSequence(CommandOrigin origin) {
  const size_t index = static_cast<size_t>(origin);
  if (origin == CommandOrigin::System || index >= ORIGIN_COUNT) {
    return false;
  }
  _lastRequestIds[index] = 0;
  _requestSeen[index] = false;
  return true;
}

bool DeviceController::validate(const DeviceCommand &command) const {
  switch (command.type) {
    case DeviceCommandType::SetPower:
      return command.value == 0 || command.value == 1;
    case DeviceCommandType::SetFanSpeed:
      return command.value >= 1 && command.value <= 5;
    case DeviceCommandType::SetMistMode:
      return command.value >= 0 && command.value <= 1;
    case DeviceCommandType::SetBreezeMode:
      return command.value >= 0 && command.value <= 6;
    case DeviceCommandType::SetOscillationMode:
      return command.value >= 0 && command.value <= 3;
    case DeviceCommandType::SetDirection:
      return command.value >= -1 && command.value <= 1;
    case DeviceCommandType::SetOscillationPosition:
      return command.value >= -3 && command.value <= 3;
    case DeviceCommandType::SetTimerMinutes:
      return command.value == 0 || command.value == 15 ||
        command.value == 30 || command.value == 45 || command.value == 60;
    case DeviceCommandType::ClearFaults:
      return command.value == 0;
  }
  return false;
}

bool DeviceController::transitionAllowed(const DeviceCommand &command) const {
  if (command.type == DeviceCommandType::SetPower ||
      command.type == DeviceCommandType::ClearFaults) {
    return true;
  }
  return _state.power;
}

bool DeviceController::apply(const DeviceCommand &command) {
  switch (command.type) {
    case DeviceCommandType::SetPower: {
      const bool power = command.value != 0;
      const bool changed = _state.power != power ||
        _state.timerRemainingSeconds != 0 || _timerShutdownPending;
      _state.timerRemainingSeconds = 0;
      _state.timerDurationSeconds = 0;
      _timerShutdownPending = false;
      _timerLastUptimeSeconds = _state.uptimeSeconds;
      if (!changed) {
        return false;
      }
      _state.power = power;
      if (!power) {
        _state.targetFanSpeed = 1;
        _state.mistMode = 0;
        _state.breezeMode = 0;
        _state.oscillationMode = 0;
        _state.direction = DirectionRequest::Home;
        _state.oscillationPosition = OSCILLATION_POSITION_UNKNOWN;
        _state.oscillationPositioning = false;
        _state.oscillationTargetPosition = OSCILLATION_POSITION_UNKNOWN;
        _state.fanSpeedConfirmed = false;
      }
      return true;
    }
    case DeviceCommandType::SetFanSpeed: {
      const uint8_t speed = static_cast<uint8_t>(command.value);
      const bool changed =
        _state.targetFanSpeed != speed || _state.breezeMode != 0;
      _state.targetFanSpeed = speed;
      _state.breezeMode = 0;
      return changed;
    }
    case DeviceCommandType::SetMistMode: {
      const uint8_t mode = static_cast<uint8_t>(command.value);
      if (_state.mistMode == mode) {
        return false;
      }
      _state.mistMode = mode;
      return true;
    }
    case DeviceCommandType::SetBreezeMode: {
      const uint8_t mode = static_cast<uint8_t>(command.value);
      if (_state.breezeMode == mode) {
        return false;
      }
      _state.breezeMode = mode;
      return true;
    }
    case DeviceCommandType::SetOscillationMode: {
      const uint8_t mode = static_cast<uint8_t>(command.value);
      if (_state.oscillationMode == mode) {
        return false;
      }
      _state.oscillationMode = mode;
      return true;
    }
    case DeviceCommandType::SetDirection: {
      const DirectionRequest direction =
        static_cast<DirectionRequest>(command.value);
      _state.direction = direction;
      _state.oscillationMode = 0;
      // Direction is a one-shot action as well as state. A new request ID must
      // be observable even when it repeats the previous direction.
      return true;
    }
    case DeviceCommandType::SetOscillationPosition:
      // A fixed position is a one-shot action. It always remains observable
      // and stops automatic rotation before the hardware moves to the preset.
      _state.oscillationMode = 0;
      return true;
    case DeviceCommandType::SetTimerMinutes: {
      const uint32_t seconds = static_cast<uint32_t>(command.value) * 60U;
      if (_state.timerRemainingSeconds == seconds && !_timerShutdownPending) {
        return false;
      }
      _state.timerRemainingSeconds = seconds;
      _state.timerDurationSeconds = seconds;
      _timerLastUptimeSeconds = _state.uptimeSeconds;
      _timerShutdownPending = false;
      return true;
    }
    case DeviceCommandType::ClearFaults: {
      const bool changed = _state.power ||
        _state.fault != DeviceFault::None ||
        _state.timerRemainingSeconds != 0 || _timerShutdownPending;
      _state.power = false;
      _state.targetFanSpeed = 1;
      _state.fanSpeedConfirmed = false;
      _state.mistMode = 0;
      _state.breezeMode = 0;
      _state.oscillationMode = 0;
      _state.timerRemainingSeconds = 0;
      _state.timerDurationSeconds = 0;
      _state.direction = DirectionRequest::Home;
      _state.oscillationPosition = OSCILLATION_POSITION_UNKNOWN;
      _state.oscillationPositioning = false;
      _state.oscillationTargetPosition = OSCILLATION_POSITION_UNKNOWN;
      _state.fault = DeviceFault::None;
      _timerShutdownPending = false;
      _timerLastUptimeSeconds = _state.uptimeSeconds;
      return changed;
    }
  }
  return false;
}

bool DeviceController::reportFanSpeedConfirmed(bool confirmed) {
  if (_state.fanSpeedConfirmed == confirmed) {
    return false;
  }
  _state.fanSpeedConfirmed = confirmed;
  changed({CommandOrigin::System, 0});
  return true;
}

bool DeviceController::reportBreezeFanTarget(uint8_t targetFanSpeed) {
  if (
    !_state.power ||
    _state.breezeMode == 0 ||
    targetFanSpeed < 1 ||
    targetFanSpeed > 5 ||
    _state.targetFanSpeed == targetFanSpeed
  ) {
    return false;
  }
  _state.targetFanSpeed = targetFanSpeed;
  changed({CommandOrigin::System, 0});
  return true;
}

bool DeviceController::reportOscillationPosition(int8_t position) {
  if (
    (position != OSCILLATION_POSITION_UNKNOWN &&
      (position < -3 || position > 3)) ||
    _state.oscillationPosition == position
  ) {
    return false;
  }
  _state.oscillationPosition = position;
  changed({CommandOrigin::System, 0});
  return true;
}

bool DeviceController::reportOscillationMotion(
  bool positioning,
  int8_t targetPosition
) {
  if (positioning && (targetPosition < -3 || targetPosition > 3)) {
    return false;
  }
  const int8_t reportedTarget = positioning
    ? targetPosition
    : OSCILLATION_POSITION_UNKNOWN;
  if (
    _state.oscillationPositioning == positioning &&
    _state.oscillationTargetPosition == reportedTarget
  ) {
    return false;
  }
  _state.oscillationPositioning = positioning;
  _state.oscillationTargetPosition = reportedTarget;
  changed({CommandOrigin::System, 0});
  return true;
}

bool DeviceController::reportFault(DeviceFault fault) {
  if (_state.fault == fault) {
    return false;
  }
  _state.fault = fault;
  changed({CommandOrigin::System, 0});
  return true;
}

bool DeviceController::reportSystemInfo(
  uint32_t uptimeSeconds,
  ResetReason resetReason
) {
  const bool resetReasonChanged = _state.resetReason != resetReason;
  if (_state.uptimeSeconds == uptimeSeconds && !resetReasonChanged) {
    return false;
  }
  _state.uptimeSeconds = uptimeSeconds;
  _state.resetReason = resetReason;
  // Uptime is telemetry, not authoritative control state. Publishing it must
  // not make every elapsed second look like a control-state transition.
  if (resetReasonChanged) {
    changed({CommandOrigin::System, 0});
  }
  return true;
}

bool DeviceController::reportMatterCommissioning(
  MatterCommissioningState state
) {
  if (static_cast<uint8_t>(state) >
        static_cast<uint8_t>(MatterCommissioningState::Commissioned) ||
      _state.matterCommissioning == state) {
    return false;
  }
  _state.matterCommissioning = state;
  changed({CommandOrigin::System, 0});
  return true;
}

bool DeviceController::updateTimer(uint32_t uptimeSeconds) {
  if (!_state.power || _state.timerRemainingSeconds == 0 ||
      _timerShutdownPending) {
    _timerLastUptimeSeconds = uptimeSeconds;
    return false;
  }
  const uint32_t elapsed = uptimeSeconds - _timerLastUptimeSeconds;
  if (elapsed == 0) return false;
  _timerLastUptimeSeconds = uptimeSeconds;
  if (elapsed >= _state.timerRemainingSeconds) {
    _state.timerRemainingSeconds = 0;
    _state.oscillationMode = 0;
    _state.direction = DirectionRequest::Home;
    _timerShutdownPending = true;
  } else {
    _state.timerRemainingSeconds -= elapsed;
  }
  changed({CommandOrigin::System, 0});
  return true;
}

bool DeviceController::timerShutdownPending() const {
  return _timerShutdownPending;
}

CommandResult DeviceController::completeTimerShutdown() {
  if (!_timerShutdownPending) return CommandResult::InvalidTransition;
  return submit({DeviceCommandType::SetPower, 0, {CommandOrigin::System, 0}});
}

bool DeviceController::addObserver(StateObserver observer, void *context) {
  if (observer == nullptr) {
    return false;
  }
  for (ObserverSlot &slot : _observers) {
    if (slot.callback == nullptr) {
      slot.callback = observer;
      slot.context = context;
      return true;
    }
  }
  return false;
}

bool DeviceController::addCommandObserver(
  CommandObserver observer,
  void *context
) {
  if (observer == nullptr) return false;
  for (CommandObserverSlot &slot : _commandObservers) {
    if (slot.callback == nullptr) {
      slot.callback = observer;
      slot.context = context;
      return true;
    }
  }
  return false;
}

void DeviceController::changed(const CommandMetadata &metadata) {
  _state.lastCommand = metadata;
  ++_state.revision;
  publish();
}

void DeviceController::publish() {
  for (const ObserverSlot &slot : _observers) {
    if (slot.callback != nullptr) {
      slot.callback(_state, slot.context);
    }
  }
}

void DeviceController::publishCommand(
  const DeviceCommand &command,
  CommandResult result
) {
  for (const CommandObserverSlot &slot : _commandObservers) {
    if (slot.callback != nullptr) {
      slot.callback(command, result, slot.context);
    }
  }
}

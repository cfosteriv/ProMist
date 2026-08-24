// Transport-neutral mapping between Matter fan attributes and DeviceController
// commands. Observer reconciliation publishes changes from all other inputs.
#include "MatterFanAdapter.h"

MatterFanAdapter::MatterFanAdapter(
  DeviceController &controller,
  MatterFanAttributeSink &sink
) : _controller(controller), _sink(sink) {}

bool MatterFanAdapter::begin() {
  if (!_controller.addObserver(stateChanged, this)) return false;
  reconcile();
  return true;
}

CommandResult MatterFanAdapter::writePower(bool value) {
  const CommandResult result = submit(DeviceCommandType::SetPower, value);
  if (result != CommandResult::Accepted && result != CommandResult::NoChange) {
    reconcile();
  }
  return result;
}

CommandResult MatterFanAdapter::writePercent(uint8_t value) {
  if (value > 100) return CommandResult::InvalidValue;
  if (value == 0) return writePower(false);
  if (!_controller.state().power) {
    const CommandResult power = writePower(true);
    if (power != CommandResult::Accepted && power != CommandResult::NoChange) {
      return power;
    }
  }
  return submit(DeviceCommandType::SetFanSpeed, percentToSpeed(value));
}

CommandResult MatterFanAdapter::writeAttributes(
  bool hasPower,
  bool power,
  bool hasPercent,
  uint8_t percent
) {
  if (!hasPower && !hasPercent) return CommandResult::NoChange;
  if (hasPercent && percent > 100) return CommandResult::InvalidValue;

  // Home commonly writes FanMode and PercentSetting back-to-back. Treat them
  // as one intent: FanMode decides power and PercentSetting only refines speed.
  // Otherwise On+0% can turn itself back off and Off+an old nonzero percent can
  // turn itself back on.
  if (hasPower) {
    const CommandResult powerResult = writePower(power);
    if (powerResult != CommandResult::Accepted &&
        powerResult != CommandResult::NoChange) {
      return powerResult;
    }
    if (!power || !hasPercent || percent == 0) return powerResult;
    return submit(DeviceCommandType::SetFanSpeed, percentToSpeed(percent));
  }
  return writePercent(percent);
}

CommandResult MatterFanAdapter::writeRocking(bool value) {
  return submit(DeviceCommandType::SetOscillationMode, value ? 2 : 0);
}

void MatterFanAdapter::reconcile() { publish(_controller.state()); }

void MatterFanAdapter::stateChanged(const DeviceState &state, void *context) {
  static_cast<MatterFanAdapter *>(context)->publish(state);
}

CommandResult MatterFanAdapter::submit(DeviceCommandType type, int32_t value) {
  DeviceCommand command;
  command.type = type;
  command.value = value;
  command.metadata = {CommandOrigin::Matter, _nextRequestId++};
  const CommandResult result = _controller.submit(command);
  if (result != CommandResult::Accepted && result != CommandResult::NoChange) {
    reconcile();
  }
  return result;
}

uint8_t MatterFanAdapter::speedToPercent(uint8_t speed) {
  return static_cast<uint8_t>(speed * 20);
}

uint8_t MatterFanAdapter::percentToSpeed(uint8_t percent) {
  const uint8_t rounded = static_cast<uint8_t>((percent + 19) / 20);
  return rounded < 1 ? 1 : (rounded > 5 ? 5 : rounded);
}

void MatterFanAdapter::publish(const DeviceState &state) {
  // Store the snapshot before touching Matter. Attribute updates can invoke
  // the application callback synchronously; a re-entrant observer must see
  // this state as already published instead of echoing it recursively.
  const bool hadPublished = _hasPublished;
  const DeviceState previous = _published;
  _published = state;
  _hasPublished = true;

  const bool powerChanged = !hadPublished || previous.power != state.power;
  const uint8_t oldPercent = previous.power
    ? speedToPercent(previous.targetFanSpeed) : 0;
  const uint8_t newPercent = state.power
    ? speedToPercent(state.targetFanSpeed) : 0;
  const bool percentChanged = !hadPublished || oldPercent != newPercent;

  // Home observes FanMode and Percent as separate reports. During shutdown,
  // make FanMode=Off the final authoritative report; otherwise the later 0%
  // report can be rendered as "On, 0%". Startup uses the natural inverse so
  // the endpoint is on before its nonzero speed is announced.
  if (powerChanged && !state.power) {
    if (percentChanged) _sink.setPercent(newPercent);
    _sink.setPower(false);
  } else {
    if (powerChanged) _sink.setPower(state.power);
    if (percentChanged) _sink.setPercent(newPercent);
  }
  if (!hadPublished ||
      (previous.oscillationMode != 0) != (state.oscillationMode != 0)) {
    _sink.setRocking(state.oscillationMode != 0);
  }
}

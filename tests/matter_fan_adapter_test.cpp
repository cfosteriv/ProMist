// Verifies Matter conversion and two-way reconciliation through an in-memory
// attribute sink, keeping CHIP and physical hardware out of the test.
#include "MatterFanAdapter.h"
#include <cassert>
#include <vector>

struct Sink final : MatterFanAttributeSink {
  bool power = false, rocking = false;
  uint8_t percent = 0;
  unsigned writes = 0;
  enum class Write { PowerOn, PowerOff, PercentZero, PercentNonzero, Rocking };
  std::vector<Write> order;
  void setPower(bool value) override {
    power = value;
    order.push_back(value ? Write::PowerOn : Write::PowerOff);
    ++writes;
  }
  void setPercent(uint8_t value) override {
    percent = value;
    order.push_back(value == 0 ? Write::PercentZero : Write::PercentNonzero);
    ++writes;
  }
  void setRocking(bool value) override {
    rocking = value;
    order.push_back(Write::Rocking);
    ++writes;
  }
};

int main() {
  DeviceController controller;
  Sink sink;
  MatterFanAdapter adapter(controller, sink);
  assert(adapter.begin());
  assert(sink.writes == 3);
  controller.setBleProvisioningActive(true);
  assert(adapter.writePower(true) == CommandResult::InvalidTransition);
  assert(!controller.state().power);
  assert(!sink.power && sink.percent == 0);
  controller.setBleProvisioningActive(false);
  assert(adapter.writePower(true) == CommandResult::Accepted);
  assert(controller.state().lastCommand.origin == CommandOrigin::Matter);
  assert(adapter.writePercent(61) == CommandResult::Accepted);
  assert(controller.state().targetFanSpeed == 4);
  assert(sink.percent == 80);
  assert(adapter.writePercent(101) == CommandResult::InvalidValue);
  assert(adapter.writeRocking(true) == CommandResult::Accepted);
  assert(sink.rocking);

  const unsigned unchangedWrites = sink.writes;
  assert(adapter.writeRocking(true) == CommandResult::NoChange);
  assert(sink.writes == unchangedWrites);

  DeviceCommand ble{DeviceCommandType::SetFanSpeed, 2, {CommandOrigin::Ble, 1}};
  assert(controller.submit(ble) == CommandResult::Accepted);
  assert(sink.percent == 40);
  const size_t shutdownWrite = sink.order.size();
  DeviceCommand rf{DeviceCommandType::SetPower, 0, {CommandOrigin::RfRemote, 1}};
  assert(controller.submit(rf) == CommandResult::Accepted);
  assert(!sink.power && sink.percent == 0);
  assert(sink.order[shutdownWrite] == Sink::Write::PercentZero);
  assert(sink.order[shutdownWrite + 1] == Sink::Write::PowerOff);

  // FanMode is authoritative when Home delivers a companion percent write.
  // Neither stale percentage may invert the requested power state.
  assert(adapter.writeAttributes(true, true, true, 0) == CommandResult::Accepted);
  assert(controller.state().power);
  assert(adapter.writeAttributes(true, false, true, 80) == CommandResult::Accepted);
  assert(!controller.state().power);
  assert(adapter.writeAttributes(false, false, true, 60) == CommandResult::Accepted);
  assert(controller.state().power && controller.state().targetFanSpeed == 3);
}

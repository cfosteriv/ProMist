#include <cassert>

#include "OtaUpdatePolicy.h"

namespace {
constexpr uint32_t HARDWARE_TARGET = 0x50524F31;

OtaImageMetadata validCandidate() {
  return {1, HARDWARE_TARGET, {1, 1, 0}, 2, 1024, true};
}
}

int main() {
  const OtaVersion installed = {1, 0, 0};
  assert(evaluateOtaImage(validCandidate(), HARDWARE_TARGET, installed, 1) ==
         OtaAdmission::Accepted);

  OtaImageMetadata downgrade = validCandidate();
  downgrade.version = {0, 9, 9};
  assert(evaluateOtaImage(downgrade, HARDWARE_TARGET, installed, 1) ==
         OtaAdmission::DowngradeRejected);
  downgrade = validCandidate();
  downgrade.secureVersion = 0;
  assert(evaluateOtaImage(downgrade, HARDWARE_TARGET, installed, 1) ==
         OtaAdmission::DowngradeRejected);

  OtaImageMetadata malformed = validCandidate();
  malformed.digestPresent = false;
  assert(evaluateOtaImage(malformed, HARDWARE_TARGET, installed, 1) ==
         OtaAdmission::InvalidMetadata);

  OtaImageMetadata wrongTarget = validCandidate();
  wrongTarget.hardwareTarget += 1;
  assert(evaluateOtaImage(wrongTarget, HARDWARE_TARGET, installed, 1) ==
         OtaAdmission::WrongHardwareTarget);

  OtaImageMetadata installedAgain = validCandidate();
  installedAgain.version = installed;
  installedAgain.secureVersion = 1;
  assert(evaluateOtaImage(installedAgain, HARDWARE_TARGET, installed, 1) ==
         OtaAdmission::AlreadyInstalled);

  OtaLifecyclePolicy interrupted;
  assert(interrupted.begin(100));
  assert(interrupted.receive(80));
  interrupted.interruptedBeforeBootSwitch();
  assert(interrupted.state() == OtaLifecyclePolicy::State::Idle);

  OtaLifecyclePolicy confirmed;
  assert(confirmed.begin(100));
  assert(confirmed.receive(100));
  assert(confirmed.verificationCompleted(true));
  assert(confirmed.prepareBootSwitch() ==
         OtaLifecyclePolicy::Action::SetBootPartition);
  confirmed.beginBootValidation(1000, 5000);
  assert(confirmed.healthCheckCompleted(true) ==
         OtaLifecyclePolicy::Action::MarkApplicationValid);
  assert(confirmed.state() == OtaLifecyclePolicy::State::Confirmed);

  OtaLifecyclePolicy timedOut;
  assert(timedOut.begin(1));
  assert(timedOut.receive(1));
  assert(timedOut.verificationCompleted(true));
  assert(timedOut.prepareBootSwitch() ==
         OtaLifecyclePolicy::Action::SetBootPartition);
  timedOut.beginBootValidation(100, 50);
  assert(timedOut.update(149) == OtaLifecyclePolicy::Action::None);
  assert(timedOut.update(150) ==
         OtaLifecyclePolicy::Action::MarkApplicationInvalidAndReboot);
  assert(timedOut.state() == OtaLifecyclePolicy::State::RollbackRequired);
  timedOut.bootloaderReportedRollback();
  assert(timedOut.state() == OtaLifecyclePolicy::State::RolledBack);

  return 0;
}

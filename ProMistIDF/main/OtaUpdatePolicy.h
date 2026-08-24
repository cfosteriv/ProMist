#pragma once

// Hardware-independent OTA admission and boot-validation policy. This file is
// intentionally not an OTA transport or ESP-IDF flash installer; those remain
// unimplemented until a production update channel is selected.

#include <cstddef>
#include <cstdint>

struct OtaVersion {
  uint16_t major = 0;
  uint16_t minor = 0;
  uint16_t patch = 0;
};

inline int compareOtaVersion(const OtaVersion &left, const OtaVersion &right) {
  if (left.major != right.major) return left.major < right.major ? -1 : 1;
  if (left.minor != right.minor) return left.minor < right.minor ? -1 : 1;
  if (left.patch != right.patch) return left.patch < right.patch ? -1 : 1;
  return 0;
}

struct OtaImageMetadata {
  uint8_t formatVersion = 0;
  uint32_t hardwareTarget = 0;
  OtaVersion version;
  uint32_t secureVersion = 0;
  size_t imageSize = 0;
  bool digestPresent = false;
};

enum class OtaAdmission : uint8_t {
  Accepted,
  InvalidMetadata,
  WrongHardwareTarget,
  DowngradeRejected,
  AlreadyInstalled
};

/**
 * Applies hardware target, semantic version, secure-version, and digest
 * admission checks without writing flash.
 */
inline OtaAdmission evaluateOtaImage(
  const OtaImageMetadata &candidate,
  uint32_t expectedHardwareTarget,
  const OtaVersion &installedVersion,
  uint32_t installedSecureVersion
) {
  if (candidate.formatVersion != 1 || candidate.hardwareTarget == 0 ||
      candidate.imageSize == 0 || !candidate.digestPresent) {
    return OtaAdmission::InvalidMetadata;
  }
  if (candidate.hardwareTarget != expectedHardwareTarget) {
    return OtaAdmission::WrongHardwareTarget;
  }
  const int versionOrder = compareOtaVersion(candidate.version, installedVersion);
  if (candidate.secureVersion < installedSecureVersion || versionOrder < 0) {
    return OtaAdmission::DowngradeRejected;
  }
  if (versionOrder == 0 && candidate.secureVersion == installedSecureVersion) {
    return OtaAdmission::AlreadyInstalled;
  }
  return OtaAdmission::Accepted;
}

/**
 * Pure boot-decision state machine for a future ESP-IDF OTA installer.
 * Returned actions must be executed by a platform adapter; this type does not
 * write partitions, switch boot targets, validate signatures, or burn eFuses.
 */
class OtaLifecyclePolicy {
 public:
  enum class State : uint8_t {
    Idle,
    Receiving,
    Verified,
    BootPending,
    Validating,
    Confirmed,
    RollbackRequired,
    RolledBack,
    Failed
  };

  enum class Action : uint8_t {
    None,
    SetBootPartition,
    MarkApplicationValid,
    MarkApplicationInvalidAndReboot
  };

  bool begin(size_t expectedBytes) {
    if (expectedBytes == 0 || (_state != State::Idle && _state != State::Failed)) {
      return false;
    }
    _expectedBytes = expectedBytes;
    _receivedBytes = 0;
    _state = State::Receiving;
    return true;
  }

  bool receive(size_t byteCount) {
    if (_state != State::Receiving ||
        byteCount > _expectedBytes - _receivedBytes) {
      _state = State::Failed;
      return false;
    }
    _receivedBytes += byteCount;
    return true;
  }

  bool verificationCompleted(bool valid) {
    if (_state != State::Receiving || _receivedBytes != _expectedBytes) {
      return false;
    }
    _state = valid ? State::Verified : State::Failed;
    return valid;
  }

  Action prepareBootSwitch() {
    if (_state != State::Verified) return Action::None;
    _state = State::BootPending;
    return Action::SetBootPartition;
  }

  void interruptedBeforeBootSwitch() {
    if (_state == State::Receiving || _state == State::Verified) {
      _expectedBytes = 0;
      _receivedBytes = 0;
      _state = State::Idle;
    }
  }

  void beginBootValidation(uint32_t nowMs, uint32_t timeoutMs) {
    if (_state != State::BootPending || timeoutMs == 0) return;
    _validationStartedMs = nowMs;
    _validationTimeoutMs = timeoutMs;
    _state = State::Validating;
  }

  Action healthCheckCompleted(bool healthy) {
    if (_state != State::Validating) return Action::None;
    _state = healthy ? State::Confirmed : State::RollbackRequired;
    return healthy ? Action::MarkApplicationValid
                   : Action::MarkApplicationInvalidAndReboot;
  }

  Action update(uint32_t nowMs) {
    if (_state != State::Validating) return Action::None;
    if (static_cast<uint32_t>(nowMs - _validationStartedMs) <
        _validationTimeoutMs) {
      return Action::None;
    }
    _state = State::RollbackRequired;
    return Action::MarkApplicationInvalidAndReboot;
  }

  void bootloaderReportedRollback() {
    _state = State::RolledBack;
  }

  State state() const { return _state; }
  size_t receivedBytes() const { return _receivedBytes; }

 private:
  State _state = State::Idle;
  size_t _expectedBytes = 0;
  size_t _receivedBytes = 0;
  uint32_t _validationStartedMs = 0;
  uint32_t _validationTimeoutMs = 0;
};

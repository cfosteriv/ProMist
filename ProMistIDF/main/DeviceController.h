#pragma once

// Single validation, transition, sequencing, and publication authority for the
// device. Transports and hardware adapters exchange typed commands/snapshots.

#include <atomic>
#include <cstddef>
#include <cstdint>

enum class CommandOrigin : uint8_t {
  System = 0,
  PhysicalUi,
  RfRemote,
  Ble,
  Matter,
  Diagnostics,
  Count
};

enum class DeviceCommandType : uint8_t {
  SetPower = 0,
  SetFanSpeed,
  SetMistMode,
  SetBreezeMode,
  SetOscillationMode,
  SetDirection,
  SetOscillationPosition,
  SetTimerMinutes,
  ClearFaults
};

enum class DirectionRequest : int8_t {
  CounterClockwiseJog = -1,
  Home = 0,
  ClockwiseJog = 1
};

constexpr int8_t OSCILLATION_POSITION_UNKNOWN = -128;

enum class DeviceFault : uint8_t {
  None = 0,
  OscillationSearching = 1,
  FanSpeedLow = 2,
  OscillationSafetyFault = 3,
  FanSpeedHigh = 4,
  FanNotTurning = 5,
  HardwareNoStart = 6
};

enum class ResetReason : uint8_t {
  Unknown = 0,
  PowerOn,
  Software,
  Watchdog,
  Brownout,
  External
};

enum class MatterCommissioningState : uint8_t {
  NotConfigured = 0,
  Commissionable = 1,
  Commissioned = 2
};

struct CommandMetadata {
  CommandOrigin origin = CommandOrigin::System;
  uint32_t requestId = 0;
};

struct DeviceCommand {
  DeviceCommandType type = DeviceCommandType::SetPower;
  int32_t value = 0;
  CommandMetadata metadata;
};

enum class CommandResult : uint8_t {
  Accepted = 0,
  NoChange,
  InvalidValue,
  InvalidTransition,
  DuplicateRequest
};

struct DeviceIdentity {
  uint64_t deviceId;
  const char *manufacturer;
  const char *model;
  const char *hardwareRevision;
};

struct DeviceState {
  bool power = false;
  uint8_t targetFanSpeed = 1;
  bool fanSpeedConfirmed = false;
  uint8_t mistMode = 0;
  uint8_t breezeMode = 0;
  uint8_t oscillationMode = 0;
  uint32_t timerRemainingSeconds = 0;
  uint32_t timerDurationSeconds = 0;
  DirectionRequest direction = DirectionRequest::Home;
  int8_t oscillationPosition = OSCILLATION_POSITION_UNKNOWN;
  bool oscillationPositioning = false;
  int8_t oscillationTargetPosition = OSCILLATION_POSITION_UNKNOWN;
  DeviceFault fault = DeviceFault::None;
  const char *firmwareVersion = "1.0";
  DeviceIdentity identity = {
    0,
    "Charles Foster",
    "ProMist",
    "WROOM-DA-prototype"
  };
  uint32_t uptimeSeconds = 0;
  ResetReason resetReason = ResetReason::Unknown;
  MatterCommissioningState matterCommissioning =
    MatterCommissioningState::NotConfigured;
  uint32_t revision = 0;
  CommandMetadata lastCommand;
};

using StateObserver = void (*)(const DeviceState &state, void *context);
using CommandObserver = void (*)(
  const DeviceCommand &command,
  CommandResult result,
  void *context
);

class DeviceController {
 public:
  /// Starts from a supplied state so host tests and controlled restore are deterministic.
  explicit DeviceController(const DeviceState &initialState = DeviceState{});

  /// Returns the current authoritative snapshot.
  const DeviceState &state() const;
  /// Installs immutable hardware/firmware identity after boot discovery.
  bool initializeIdentity(
    uint64_t deviceId,
    const char *firmwareVersion
  );
  /// Validates and atomically applies a command from any control surface.
  CommandResult submit(const DeviceCommand &command);
  /// Toggles against authoritative power, avoiding stale client read-modify-write.
  CommandResult togglePower(const CommandMetadata &metadata);
  /// Inhibits every external control surface while physical BLE owner
  /// provisioning is active. System-owned safety/housekeeping remains live.
  void setBleProvisioningActive(bool active);
  bool bleProvisioningActive() const;
  /// Resets deduplication for a new session owned by the specified origin.
  bool resetRequestSequence(CommandOrigin origin);
  /// Reports whether tach feedback currently qualifies the requested speed,
  /// publishing the observation through the controller state model.
  bool reportFanSpeedConfirmed(bool confirmed);
  /** Publishes the momentary fan target chosen by a breeze profile. */
  bool reportBreezeFanTarget(uint8_t targetFanSpeed);
  /** Reports a logical fixed position in -3...3, or UNKNOWN. */
  bool reportOscillationPosition(int8_t position);
  /** Reports asynchronous fixed-position movement and its target. */
  bool reportOscillationMotion(bool positioning, int8_t targetPosition);
  /** Publishes the most severe current hardware fault. */
  bool reportFault(DeviceFault fault);
  bool reportSystemInfo(
    uint32_t uptimeSeconds,
    ResetReason resetReason
  );
  bool reportMatterCommissioning(MatterCommissioningState state);
  /// Advances the device-owned countdown from monotonic uptime.
  bool updateTimer(uint32_t uptimeSeconds);
  bool timerShutdownPending() const;
  /// Completes an expired timer after the oscillation assembly has parked.
  CommandResult completeTimerShutdown();
  /** Registers a state observer in a fixed slot; no ownership is transferred. */
  bool addObserver(StateObserver observer, void *context);
  /** Registers a command-result observer in a fixed slot. */
  bool addCommandObserver(CommandObserver observer, void *context);

 private:
  static constexpr size_t MAX_OBSERVERS = 4;
  static constexpr size_t MAX_COMMAND_OBSERVERS = 2;
  static constexpr size_t ORIGIN_COUNT =
    static_cast<size_t>(CommandOrigin::Count);

  struct ObserverSlot {
    StateObserver callback = nullptr;
    void *context = nullptr;
  };

  struct CommandObserverSlot {
    CommandObserver callback = nullptr;
    void *context = nullptr;
  };

  DeviceState _state;
  ObserverSlot _observers[MAX_OBSERVERS];
  CommandObserverSlot _commandObservers[MAX_COMMAND_OBSERVERS];
  uint32_t _lastRequestIds[ORIGIN_COUNT] = {};
  bool _requestSeen[ORIGIN_COUNT] = {};
  std::atomic<bool> _bleProvisioningActive = false;
  bool _identityInitialized = false;
  uint32_t _timerLastUptimeSeconds = 0;
  bool _timerShutdownPending = false;

  bool validate(const DeviceCommand &command) const;
  bool transitionAllowed(const DeviceCommand &command) const;
  bool apply(const DeviceCommand &command);
  void publish();
  void publishCommand(const DeviceCommand &command, CommandResult result);
  void changed(const CommandMetadata &metadata);
};

#pragma once

#include <cstddef>
#include <cstdint>

enum class DiagnosticSeverity : uint8_t {
  Debug = 0,
  Info = 1,
  Warning = 2,
  Error = 3,
  Critical = 4
};

enum class DiagnosticComponent : uint8_t {
  System = 0,
  Configuration = 1,
  Fan = 3,
  Oscillation = 4,
  Mist = 5,
  Ble = 6,
  Wifi = 7,
  Matter = 8,
  Ota = 9
};

enum class DiagnosticPayloadType : uint8_t {
  None = 0,
  TwoInt32 = 1,
  Transition = 2,
  ResultCode = 3
};

enum class DiagnosticEventId : uint16_t {
  Boot = 100,
  ResetReason = 101,
  ConfigurationReset = 110,
  FanTargetObservedMismatch = 200,
  MotorStartFailure = 201,
  OscillationSearching = 300,
  OscillationSafetyFault = 301,
  MistControllerFault = 400,
  BleSessionFailure = 500,
  WifiConnectivityChanged = 600,
  MatterConnectivityChanged = 610,
  OtaStarted = 700,
  OtaVerification = 701,
  OtaInstall = 702,
  OtaHealthCheck = 703,
  OtaRollback = 704,
  OtaResult = 705
};

struct DiagnosticPayload {
  DiagnosticPayloadType type = DiagnosticPayloadType::None;
  int32_t first = 0;
  int32_t second = 0;
};

struct DiagnosticRecord {
  uint32_t sequence = 0;
  uint32_t uptimeMs = 0;
  DiagnosticEventId eventId = DiagnosticEventId::Boot;
  DiagnosticSeverity severity = DiagnosticSeverity::Info;
  DiagnosticComponent component = DiagnosticComponent::System;
  DiagnosticPayload payload;
};

struct DiagnosticEventDefinition {
  DiagnosticEventId id;
  DiagnosticSeverity defaultSeverity;
  DiagnosticComponent component;
  DiagnosticPayloadType payloadType;
};

/** Returns the fixed catalog definition for an event ID, or nullptr. */
const DiagnosticEventDefinition *diagnosticEventDefinition(
  DiagnosticEventId eventId
);
/** Verifies that severity, component, and payload match the fixed catalog. */
bool validateDiagnosticRecord(const DiagnosticRecord &record);

// Fixed wire format used by BLE pagination: little-endian, no pointers,
// strings, padding, credentials, or authorization tokens.
constexpr size_t DIAGNOSTIC_RECORD_WIRE_SIZE = 20;
/** Encodes one validated record into the fixed little-endian wire format. */
bool encodeDiagnosticRecord(
  const DiagnosticRecord &record,
  uint8_t *output,
  size_t outputSize
);
/** Decodes an untrusted fixed-size record and validates it against the catalog. */
bool decodeDiagnosticRecord(
  const uint8_t *input,
  size_t inputSize,
  DiagnosticRecord &record
);

// For development serial messages that may eventually include untrusted text.
// Persistent DiagnosticRecord payloads are numeric-only and never accept text.
/**
 * Copies development text while replacing credential-like tokens.
 *
 * @return false when inputs are null or output space cannot hold a terminator.
 */
bool redactDiagnosticText(
  const char *input,
  char *output,
  size_t outputSize
);

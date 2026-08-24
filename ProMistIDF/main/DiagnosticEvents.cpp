// Diagnostic event catalog, validation, redaction, and fixed-width wire codec.
// Central definitions keep persisted and BLE event meaning versionable.
#include "DiagnosticEvents.h"

#include <cstring>

namespace {

constexpr DiagnosticEventDefinition DEFINITIONS[] = {
  {DiagnosticEventId::Boot, DiagnosticSeverity::Info,
   DiagnosticComponent::System, DiagnosticPayloadType::TwoInt32},
  {DiagnosticEventId::ResetReason, DiagnosticSeverity::Info,
   DiagnosticComponent::System, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::ConfigurationReset, DiagnosticSeverity::Warning,
   DiagnosticComponent::Configuration, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::FanTargetObservedMismatch, DiagnosticSeverity::Warning,
   DiagnosticComponent::Fan, DiagnosticPayloadType::TwoInt32},
  {DiagnosticEventId::MotorStartFailure, DiagnosticSeverity::Critical,
   DiagnosticComponent::Fan, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::OscillationSearching, DiagnosticSeverity::Info,
   DiagnosticComponent::Oscillation, DiagnosticPayloadType::Transition},
  {DiagnosticEventId::OscillationSafetyFault, DiagnosticSeverity::Error,
   DiagnosticComponent::Oscillation, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::MistControllerFault, DiagnosticSeverity::Error,
   DiagnosticComponent::Mist, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::BleSessionFailure, DiagnosticSeverity::Warning,
   DiagnosticComponent::Ble, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::WifiConnectivityChanged, DiagnosticSeverity::Info,
   DiagnosticComponent::Wifi, DiagnosticPayloadType::Transition},
  {DiagnosticEventId::MatterConnectivityChanged, DiagnosticSeverity::Info,
   DiagnosticComponent::Matter, DiagnosticPayloadType::Transition},
  {DiagnosticEventId::OtaStarted, DiagnosticSeverity::Info,
   DiagnosticComponent::Ota, DiagnosticPayloadType::TwoInt32},
  {DiagnosticEventId::OtaVerification, DiagnosticSeverity::Info,
   DiagnosticComponent::Ota, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::OtaInstall, DiagnosticSeverity::Info,
   DiagnosticComponent::Ota, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::OtaHealthCheck, DiagnosticSeverity::Info,
   DiagnosticComponent::Ota, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::OtaRollback, DiagnosticSeverity::Error,
   DiagnosticComponent::Ota, DiagnosticPayloadType::ResultCode},
  {DiagnosticEventId::OtaResult, DiagnosticSeverity::Info,
   DiagnosticComponent::Ota, DiagnosticPayloadType::ResultCode}
};

void write16(uint8_t *output, uint16_t value) {
  output[0] = static_cast<uint8_t>(value);
  output[1] = static_cast<uint8_t>(value >> 8);
}

void write32(uint8_t *output, uint32_t value) {
  for (uint8_t index = 0; index < 4; ++index) {
    output[index] = static_cast<uint8_t>(value >> (index * 8));
  }
}

uint16_t read16(const uint8_t *input) {
  return static_cast<uint16_t>(
    static_cast<uint16_t>(input[0]) |
    static_cast<uint16_t>(static_cast<uint16_t>(input[1]) << 8)
  );
}

uint32_t read32(const uint8_t *input) {
  uint32_t value = 0;
  for (uint8_t index = 0; index < 4; ++index) {
    value |= static_cast<uint32_t>(input[index]) << (index * 8);
  }
  return value;
}

char asciiLower(char value) {
  return value >= 'A' && value <= 'Z' ? value + ('a' - 'A') : value;
}

bool containsInsensitive(const char *text, const char *pattern) {
  for (size_t start = 0; text[start] != '\0'; ++start) {
    size_t offset = 0;
    while (
      pattern[offset] != '\0' &&
      text[start + offset] != '\0' &&
      asciiLower(text[start + offset]) == pattern[offset]
    ) {
      ++offset;
    }
    if (pattern[offset] == '\0') {
      return true;
    }
  }
  return false;
}

}  // namespace

const DiagnosticEventDefinition *diagnosticEventDefinition(
  DiagnosticEventId eventId
) {
  for (const DiagnosticEventDefinition &definition : DEFINITIONS) {
    if (definition.id == eventId) {
      return &definition;
    }
  }
  return nullptr;
}

bool validateDiagnosticRecord(const DiagnosticRecord &record) {
  const DiagnosticEventDefinition *definition =
    diagnosticEventDefinition(record.eventId);
  return
    record.sequence != 0 &&
    definition != nullptr &&
    record.severity == definition->defaultSeverity &&
    record.component == definition->component &&
    record.payload.type == definition->payloadType;
}

bool encodeDiagnosticRecord(
  const DiagnosticRecord &record,
  uint8_t *output,
  size_t outputSize
) {
  if (
    output == nullptr ||
    outputSize < DIAGNOSTIC_RECORD_WIRE_SIZE ||
    !validateDiagnosticRecord(record)
  ) {
    return false;
  }
  write32(output, record.sequence);
  write32(output + 4, record.uptimeMs);
  write16(output + 8, static_cast<uint16_t>(record.eventId));
  output[10] = static_cast<uint8_t>(record.severity);
  output[11] = static_cast<uint8_t>(record.component);
  write32(output + 12, static_cast<uint32_t>(record.payload.first));
  write32(output + 16, static_cast<uint32_t>(record.payload.second));
  return true;
}

bool decodeDiagnosticRecord(
  const uint8_t *input,
  size_t inputSize,
  DiagnosticRecord &record
) {
  if (input == nullptr || inputSize != DIAGNOSTIC_RECORD_WIRE_SIZE) {
    return false;
  }
  record.sequence = read32(input);
  record.uptimeMs = read32(input + 4);
  record.eventId = static_cast<DiagnosticEventId>(read16(input + 8));
  record.severity = static_cast<DiagnosticSeverity>(input[10]);
  record.component = static_cast<DiagnosticComponent>(input[11]);
  const DiagnosticEventDefinition *definition =
    diagnosticEventDefinition(record.eventId);
  if (definition == nullptr) {
    return false;
  }
  record.payload.type = definition->payloadType;
  record.payload.first = static_cast<int32_t>(read32(input + 12));
  record.payload.second = static_cast<int32_t>(read32(input + 16));
  return validateDiagnosticRecord(record);
}

bool redactDiagnosticText(
  const char *input,
  char *output,
  size_t outputSize
) {
  if (input == nullptr || output == nullptr || outputSize == 0) {
    return false;
  }
  static constexpr const char *SENSITIVE[] = {
    "password", "passwd", "token", "secret", "private key",
    "api key", "credential", "setup code", "setup pin", "ssid"
  };
  bool sensitive = false;
  for (const char *pattern : SENSITIVE) {
    if (containsInsensitive(input, pattern)) {
      sensitive = true;
      break;
    }
  }
  const char *source = sensitive ? "[REDACTED]" : input;
  const size_t length = std::strlen(source);
  if (length + 1 > outputSize) {
    output[0] = '\0';
    return false;
  }
  std::memcpy(output, source, length + 1);
  return !sensitive;
}

// Verifies diagnostic validation, redaction, wire encoding, cursor paging,
// bounded overwrite behavior, and persistence restore assumptions.
#include <cassert>
#include <cstring>
#include <type_traits>

#include "DiagnosticEvents.h"
#include "DiagnosticLog.h"

int main() {
  static_assert(std::is_trivially_copyable<DiagnosticRecord>::value,
                "records must contain no owned strings or secret-bearing objects");

  DiagnosticLog log;
  assert(!log.append(1, static_cast<DiagnosticEventId>(9999)));
  assert(log.append(10, DiagnosticEventId::Boot, 2, 0));
  assert(log.append(20, DiagnosticEventId::ResetReason, 1, 0));

  DiagnosticRecord page[1];
  bool hasMore = false;
  assert(log.readPage(0, page, 1, hasMore) == 1);
  assert(hasMore);
  assert(page[0].sequence == 1);
  const uint32_t cursor = page[0].sequence;
  assert(log.readPage(cursor, page, 1, hasMore) == 1);
  assert(!hasMore);
  assert(page[0].sequence == 2);

  uint8_t wire[DIAGNOSTIC_RECORD_WIRE_SIZE] = {};
  assert(encodeDiagnosticRecord(page[0], wire, sizeof(wire)));
  DiagnosticRecord decoded;
  assert(decodeDiagnosticRecord(wire, sizeof(wire), decoded));
  assert(decoded.sequence == page[0].sequence);
  assert(decoded.eventId == page[0].eventId);
  assert(decoded.payload.first == page[0].payload.first);
  assert(!decodeDiagnosticRecord(wire, sizeof(wire) - 1, decoded));
  wire[8] = 0xFF;
  wire[9] = 0xFF;
  assert(!decodeDiagnosticRecord(wire, sizeof(wire), decoded));

  DiagnosticRecord malformed = page[0];
  malformed.sequence = 0;
  assert(!validateDiagnosticRecord(malformed));
  malformed = page[0];
  malformed.component = DiagnosticComponent::Ble;
  assert(!validateDiagnosticRecord(malformed));
  malformed = page[0];
  malformed.payload.type = DiagnosticPayloadType::Transition;
  assert(!validateDiagnosticRecord(malformed));

  // Capacity is fixed. New records overwrite the oldest and increment a
  // monotonic loss counter rather than allocating or blocking.
  log.clear();
  for (size_t index = 0; index < DiagnosticLog::CAPACITY + 7; ++index) {
    assert(log.append(
      static_cast<uint32_t>(index),
      DiagnosticEventId::FanTargetObservedMismatch,
      static_cast<int32_t>(index),
      0
    ));
  }
  const DiagnosticLogMetadata metadata = log.metadata();
  assert(metadata.count == DiagnosticLog::CAPACITY);
  assert(metadata.capacity == DiagnosticLog::CAPACITY);
  assert(metadata.overwrittenCount == 7);
  DiagnosticRecord all[DiagnosticLog::CAPACITY];
  assert(log.readPage(0, all, DiagnosticLog::CAPACITY, hasMore) ==
         DiagnosticLog::CAPACITY);
  assert(!hasMore);
  for (size_t index = 1; index < DiagnosticLog::CAPACITY; ++index) {
    assert(all[index].sequence == all[index - 1].sequence + 1);
  }

  DiagnosticLog restored;
  assert(restored.restore(
    all,
    DiagnosticLog::CAPACITY,
    metadata.overwrittenCount
  ));
  const DiagnosticLogMetadata restoredMetadata = restored.metadata();
  assert(restoredMetadata.count == DiagnosticLog::CAPACITY);
  assert(restoredMetadata.oldestSequence == all[0].sequence);
  assert(restoredMetadata.newestSequence == all[DiagnosticLog::CAPACITY - 1].sequence);
  assert(restoredMetadata.overwrittenCount == 7);
  assert(restored.append(500, DiagnosticEventId::Boot, 2, 0));
  assert(restored.metadata().newestSequence ==
         all[DiagnosticLog::CAPACITY - 1].sequence + 1);
  DiagnosticRecord invalid[1] = {all[0]};
  invalid[0].sequence = 0;
  assert(!restored.restore(invalid, 1, 0));

  // Text never enters persistent records. If a future development serial path
  // handles text, sensitive labels redact the complete value.
  char redacted[32] = {};
  assert(redactDiagnosticText("fan target mismatch", redacted,
                              sizeof(redacted)));
  assert(std::strcmp(redacted, "fan target mismatch") == 0);
  assert(!redactDiagnosticText("WiFi password=hunter2", redacted,
                               sizeof(redacted)));
  assert(std::strcmp(redacted, "[REDACTED]") == 0);
  assert(!redactDiagnosticText("Authorization TOKEN: abc", redacted,
                               sizeof(redacted)));
  assert(std::strcmp(redacted, "[REDACTED]") == 0);
  char tooSmall[4] = {};
  assert(!redactDiagnosticText("normal", tooSmall, sizeof(tooSmall)));
  assert(tooSmall[0] == '\0');
}

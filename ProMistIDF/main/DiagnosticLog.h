#pragma once

// Fixed-capacity structured history with cursor paging and a change observer
// used to schedule persistence outside the append operation.

#include "DiagnosticEvents.h"

struct DiagnosticLogMetadata {
  size_t capacity = 0;
  size_t count = 0;
  uint32_t oldestSequence = 0;
  uint32_t newestSequence = 0;
  uint32_t overwrittenCount = 0;
};

class DiagnosticLog {
 public:
  static constexpr size_t CAPACITY = 64;
  using ChangeObserver = void (*)(void *context);

  /**
   * Appends a catalog-defined event and overwrites the oldest record when full.
   *
   * @return false when eventId is not in the fixed event catalog.
   */
  bool append(
    uint32_t uptimeMs,
    DiagnosticEventId eventId,
    int32_t first = 0,
    int32_t second = 0
  );
  /**
   * Copies records whose rollover-safe sequence follows an exclusive cursor.
   *
   * @param afterSequence Exclusive sequence cursor; zero starts at the oldest.
   * @param output Caller-owned record buffer.
   * @param outputCapacity Number of available record slots.
   * @param hasMore Receives whether another matching record remains.
   * @return Number of records copied.
   */
  size_t readPage(
    uint32_t afterSequence,
    DiagnosticRecord *output,
    size_t outputCapacity,
    bool &hasMore
  ) const;
  /** Returns ring occupancy, sequence bounds, and overwrite count. */
  DiagnosticLogMetadata metadata() const;
  /**
   * Replaces the ring from validated, strictly increasing persisted records.
   *
   * @return false without changing the ring when the snapshot is invalid.
   */
  bool restore(
    const DiagnosticRecord *records,
    size_t count,
    uint32_t overwrittenCount
  );
  /** Installs a callback used to schedule persistence after mutations. */
  void setChangeObserver(ChangeObserver observer, void *context);
  /** Clears records and sequence history, then calls the change observer. */
  void clear();

 private:
  DiagnosticRecord _records[CAPACITY];
  size_t _head = 0;
  size_t _count = 0;
  uint32_t _nextSequence = 1;
  uint32_t _overwrittenCount = 0;
  ChangeObserver _changeObserver = nullptr;
  void *_changeContext = nullptr;

  void changed();
};

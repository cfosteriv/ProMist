// Bounded in-memory diagnostic ring. Sequence cursors support stable paging even
// when old entries are overwritten; no dynamic allocation is required.
#include "DiagnosticLog.h"

bool DiagnosticLog::append(
  uint32_t uptimeMs,
  DiagnosticEventId eventId,
  int32_t first,
  int32_t second
) {
  const DiagnosticEventDefinition *definition =
    diagnosticEventDefinition(eventId);
  if (definition == nullptr) {
    return false;
  }

  if (_nextSequence == 0) {
    _nextSequence = 1;
  }
  const DiagnosticRecord record = {
    _nextSequence++,
    uptimeMs,
    eventId,
    definition->defaultSeverity,
    definition->component,
    {definition->payloadType, first, second}
  };

  size_t index = (_head + _count) % CAPACITY;
  if (_count == CAPACITY) {
    index = _head;
    _head = (_head + 1) % CAPACITY;
    ++_overwrittenCount;
  } else {
    ++_count;
  }
  _records[index] = record;
  changed();
  return true;
}

size_t DiagnosticLog::readPage(
  uint32_t afterSequence,
  DiagnosticRecord *output,
  size_t outputCapacity,
  bool &hasMore
) const {
  hasMore = false;
  if (output == nullptr || outputCapacity == 0) {
    hasMore = _count != 0;
    return 0;
  }

  size_t written = 0;
  for (size_t logical = 0; logical < _count; ++logical) {
    const DiagnosticRecord &record =
      _records[(_head + logical) % CAPACITY];
    const bool followsCursor =
      afterSequence == 0 ||
      static_cast<int32_t>(record.sequence - afterSequence) > 0;
    if (!followsCursor) {
      continue;
    }
    if (written == outputCapacity) {
      hasMore = true;
      break;
    }
    output[written++] = record;
  }
  return written;
}

DiagnosticLogMetadata DiagnosticLog::metadata() const {
  DiagnosticLogMetadata result;
  result.capacity = CAPACITY;
  result.count = _count;
  result.overwrittenCount = _overwrittenCount;
  if (_count != 0) {
    result.oldestSequence = _records[_head].sequence;
    result.newestSequence =
      _records[(_head + _count - 1) % CAPACITY].sequence;
  }
  return result;
}

bool DiagnosticLog::restore(
  const DiagnosticRecord *records,
  size_t count,
  uint32_t overwrittenCount
) {
  if (count > CAPACITY || (count != 0 && records == nullptr)) {
    return false;
  }
  for (size_t index = 0; index < count; ++index) {
    if (!validateDiagnosticRecord(records[index])) {
      return false;
    }
    if (
      index != 0 &&
      static_cast<int32_t>(
        records[index].sequence - records[index - 1].sequence
      ) <= 0
    ) {
      return false;
    }
  }

  _head = 0;
  _count = count;
  _overwrittenCount = overwrittenCount;
  for (size_t index = 0; index < count; ++index) {
    _records[index] = records[index];
  }
  _nextSequence = count == 0 ? 1 : records[count - 1].sequence + 1;
  if (_nextSequence == 0) {
    _nextSequence = 1;
  }
  return true;
}

void DiagnosticLog::setChangeObserver(
  ChangeObserver observer,
  void *context
) {
  _changeObserver = observer;
  _changeContext = context;
}

void DiagnosticLog::clear() {
  _head = 0;
  _count = 0;
  _overwrittenCount = 0;
  _nextSequence = 1;
  changed();
}

void DiagnosticLog::changed() {
  if (_changeObserver != nullptr) {
    _changeObserver(_changeContext);
  }
}

// Crash-tolerant diagnostic persistence using versioned alternating NVS slots,
// generations, and CRC validation before an in-memory log is restored.
#include "FaultHistoryStore.h"

#include <esp_log.h>

#include "NvsNamespace.h"

namespace {

// Installed-controller upgrades retain diagnostic history until the owner
// clears it or performs whole-device recovery.
constexpr const char *NAMESPACE = "sharkfaults";
constexpr const char *SLOT_A = "historyA";
constexpr const char *SLOT_B = "historyB";
constexpr char TAG[] = "FaultHistory";

bool generationIsNewer(uint32_t candidate, uint32_t current) {
  return current == 0 || static_cast<int32_t>(candidate - current) > 0;
}

}  // namespace

FaultHistoryStore::FaultHistoryStore(DiagnosticLog &log) : _log(log) {}

bool FaultHistoryStore::begin() {
  uint32_t bestGeneration = 0;
  const bool loadedA = loadSlot(SLOT_A, bestGeneration);
  const bool loadedB = loadSlot(SLOT_B, bestGeneration);
  _generation = bestGeneration;
  _log.setChangeObserver(handleLogChanged, this);
  ESP_LOGI(
    TAG,
    "FAULT HISTORY: %s generation=%lu records=%u\n",
    (loadedA || loadedB) ? "restored" : "empty",
    static_cast<unsigned long>(_generation),
    static_cast<unsigned>(_log.metadata().count)
  );
  return loadedA || loadedB;
}

void FaultHistoryStore::update() {
  if (!_dirty) {
    return;
  }
  if (persist()) {
    _dirty = false;
  }
}

void FaultHistoryStore::handleLogChanged(void *context) {
  if (context != nullptr) {
    static_cast<FaultHistoryStore *>(context)->_dirty = true;
  }
}

bool FaultHistoryStore::loadSlot(
  const char *key,
  uint32_t &bestGeneration
) {
  NvsNamespace storage;
  if (storage.open(NAMESPACE, NVS_READONLY) != ESP_OK) return false;
  size_t length = 0;
  if (storage.blobSize(key, length) != ESP_OK) return false;
  if (length < HEADER_SIZE || length > MAX_SNAPSHOT_SIZE) {
    return false;
  }

  uint8_t bytes[MAX_SNAPSHOT_SIZE] = {};
  size_t read = length;
  if (storage.getBlob(key, bytes, read) != ESP_OK || read != length ||
      read32(bytes) != MAGIC || read16(bytes + 4) != VERSION) {
    return false;
  }

  const uint16_t count = read16(bytes + 6);
  const uint32_t generation = read32(bytes + 8);
  const uint32_t overwritten = read32(bytes + 12);
  const uint32_t storedCrc = read32(bytes + 16);
  const size_t expectedLength =
    HEADER_SIZE + count * DIAGNOSTIC_RECORD_WIRE_SIZE;
  if (
    count > DiagnosticLog::CAPACITY ||
    length != expectedLength ||
    !generationIsNewer(generation, bestGeneration)
  ) {
    return false;
  }

  write32(bytes + 16, 0);
  if (crc32(bytes, length) != storedCrc) {
    ESP_LOGW(TAG, "Rejected corrupt slot %s", key);
    return false;
  }

  DiagnosticRecord records[DiagnosticLog::CAPACITY];
  for (uint16_t index = 0; index < count; ++index) {
    if (!decodeDiagnosticRecord(
          bytes + HEADER_SIZE + index * DIAGNOSTIC_RECORD_WIRE_SIZE,
          DIAGNOSTIC_RECORD_WIRE_SIZE,
          records[index]
        )) {
      return false;
    }
  }
  if (!_log.restore(records, count, overwritten)) {
    return false;
  }
  bestGeneration = generation;
  return true;
}

bool FaultHistoryStore::persist() {
  DiagnosticRecord records[DiagnosticLog::CAPACITY];
  bool hasMore = false;
  const DiagnosticLogMetadata metadata = _log.metadata();
  const size_t count = _log.readPage(
    0,
    records,
    DiagnosticLog::CAPACITY,
    hasMore
  );
  if (hasMore || count != metadata.count) {
    return false;
  }

  uint8_t bytes[MAX_SNAPSHOT_SIZE] = {};
  uint32_t nextGeneration = _generation + 1;
  if (nextGeneration == 0) {
    nextGeneration = 1;
  }
  const size_t length =
    HEADER_SIZE + count * DIAGNOSTIC_RECORD_WIRE_SIZE;
  write32(bytes, MAGIC);
  write16(bytes + 4, VERSION);
  write16(bytes + 6, static_cast<uint16_t>(count));
  write32(bytes + 8, nextGeneration);
  write32(bytes + 12, metadata.overwrittenCount);
  for (size_t index = 0; index < count; ++index) {
    if (!encodeDiagnosticRecord(
          records[index],
          bytes + HEADER_SIZE + index * DIAGNOSTIC_RECORD_WIRE_SIZE,
          DIAGNOSTIC_RECORD_WIRE_SIZE
        )) {
      return false;
    }
  }
  write32(bytes + 16, 0);
  write32(bytes + 16, crc32(bytes, length));

  NvsNamespace storage;
  if (storage.open(NAMESPACE, NVS_READWRITE) != ESP_OK) return false;
  const char *key = (nextGeneration & 1U) != 0 ? SLOT_A : SLOT_B;
  if (storage.setBlob(key, bytes, length) != ESP_OK ||
      storage.commit() != ESP_OK) {
    ESP_LOGE(TAG, "Persistent write failed");
    return false;
  }

  _generation = nextGeneration;
  ESP_LOGD(
    TAG,
    "FAULT HISTORY: saved generation=%lu records=%u\n",
    static_cast<unsigned long>(_generation),
    static_cast<unsigned>(count)
  );
  return true;
}

uint32_t FaultHistoryStore::crc32(const uint8_t *bytes, size_t length) {
  uint32_t crc = 0xFFFFFFFFU;
  for (size_t index = 0; index < length; ++index) {
    crc ^= bytes[index];
    for (uint8_t bit = 0; bit < 8; ++bit) {
      crc = (crc >> 1) ^ (0xEDB88320U & (0U - (crc & 1U)));
    }
  }
  return ~crc;
}

uint16_t FaultHistoryStore::read16(const uint8_t *bytes) {
  return static_cast<uint16_t>(bytes[0]) |
    static_cast<uint16_t>(bytes[1]) << 8;
}

uint32_t FaultHistoryStore::read32(const uint8_t *bytes) {
  uint32_t value = 0;
  for (uint8_t index = 0; index < 4; ++index) {
    value |= static_cast<uint32_t>(bytes[index]) << (8 * index);
  }
  return value;
}

void FaultHistoryStore::write16(uint8_t *bytes, uint16_t value) {
  bytes[0] = static_cast<uint8_t>(value);
  bytes[1] = static_cast<uint8_t>(value >> 8);
}

void FaultHistoryStore::write32(uint8_t *bytes, uint32_t value) {
  for (uint8_t index = 0; index < 4; ++index) {
    bytes[index] = static_cast<uint8_t>(value >> (8 * index));
  }
}

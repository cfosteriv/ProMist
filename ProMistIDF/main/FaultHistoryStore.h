#pragma once

#include <cstddef>
#include <cstdint>

#include "DiagnosticLog.h"

/** Persists DiagnosticLog snapshots in alternating CRC-protected NVS slots. */
class FaultHistoryStore {
 public:
  explicit FaultHistoryStore(DiagnosticLog &log);

  /**
   * Restores the newest valid generation and starts observing log changes.
   *
   * @return true when at least one valid persisted slot was restored.
   */
  bool begin();
  /** Persists a dirty log from application-task context. */
  void update();

 private:
  static constexpr uint32_t MAGIC = 0x31484653;  // "SFH1"
  static constexpr uint16_t VERSION = 1;
  static constexpr size_t HEADER_SIZE = 20;
  static constexpr size_t MAX_SNAPSHOT_SIZE =
    HEADER_SIZE + DiagnosticLog::CAPACITY * DIAGNOSTIC_RECORD_WIRE_SIZE;

  DiagnosticLog &_log;
  volatile bool _dirty = false;
  uint32_t _generation = 0;

  static void handleLogChanged(void *context);
  bool loadSlot(const char *key, uint32_t &bestGeneration);
  bool persist();
  static uint32_t crc32(const uint8_t *bytes, size_t length);
  static uint16_t read16(const uint8_t *bytes);
  static uint32_t read32(const uint8_t *bytes);
  static void write16(uint8_t *bytes, uint16_t value);
  static void write32(uint8_t *bytes, uint32_t value);
};

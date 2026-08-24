#pragma once

#include <cstddef>
#include <cstdint>

#include <esp_err.h>
#include <nvs.h>

// RAII ownership for one native NVS namespace. This intentionally exposes
// esp_err_t and typed NVS operations instead of recreating a generic facade.
class NvsNamespace final {
 public:
  NvsNamespace() = default;
  ~NvsNamespace();

  NvsNamespace(const NvsNamespace &) = delete;
  NvsNamespace &operator=(const NvsNamespace &) = delete;
  NvsNamespace(NvsNamespace &&other) noexcept;
  NvsNamespace &operator=(NvsNamespace &&other) noexcept;

  /**
   * Closes any current handle and opens one namespace.
   *
   * @return ESP_OK or the original ESP-IDF NVS error.
   */
  esp_err_t open(const char *name, nvs_open_mode_t mode);
  bool isOpen() const { return _handle != 0; }
  void close();

  /** Queries a blob's exact byte count without reading its contents. */
  esp_err_t blobSize(const char *key, size_t &size) const;
  /** Reads a blob using ESP-IDF's in/out size contract. */
  esp_err_t getBlob(const char *key, void *value, size_t &size) const;
  /** Stages a blob write; call commit() to make it durable. */
  esp_err_t setBlob(const char *key, const void *value, size_t size);
  esp_err_t getI8(const char *key, int8_t &value) const;
  esp_err_t setI8(const char *key, int8_t value);
  esp_err_t getU8(const char *key, uint8_t &value) const;
  esp_err_t setU8(const char *key, uint8_t value);
  esp_err_t getI32(const char *key, int32_t &value) const;
  esp_err_t setI32(const char *key, int32_t value);
  esp_err_t erase(const char *key);
  /** Commits staged writes in this namespace. */
  esp_err_t commit();

 private:
  nvs_handle_t _handle = 0;
};

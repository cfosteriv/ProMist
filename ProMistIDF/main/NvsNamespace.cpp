#include "NvsNamespace.h"

#include <utility>

NvsNamespace::~NvsNamespace() { close(); }

NvsNamespace::NvsNamespace(NvsNamespace &&other) noexcept
  : _handle(std::exchange(other._handle, 0)) {}

NvsNamespace &NvsNamespace::operator=(NvsNamespace &&other) noexcept {
  if (this != &other) {
    close();
    _handle = std::exchange(other._handle, 0);
  }
  return *this;
}

esp_err_t NvsNamespace::open(const char *name, nvs_open_mode_t mode) {
  close();
  return nvs_open(name, mode, &_handle);
}

void NvsNamespace::close() {
  if (_handle != 0) {
    nvs_close(_handle);
    _handle = 0;
  }
}

esp_err_t NvsNamespace::blobSize(const char *key, size_t &size) const {
  size = 0;
  return isOpen() ? nvs_get_blob(_handle, key, nullptr, &size)
                  : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::getBlob(
  const char *key,
  void *value,
  size_t &size
) const {
  return isOpen() ? nvs_get_blob(_handle, key, value, &size)
                  : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::setBlob(
  const char *key,
  const void *value,
  size_t size
) {
  return isOpen() ? nvs_set_blob(_handle, key, value, size)
                  : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::getI8(const char *key, int8_t &value) const {
  return isOpen() ? nvs_get_i8(_handle, key, &value) : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::setI8(const char *key, int8_t value) {
  return isOpen() ? nvs_set_i8(_handle, key, value) : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::getU8(const char *key, uint8_t &value) const {
  return isOpen() ? nvs_get_u8(_handle, key, &value) : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::setU8(const char *key, uint8_t value) {
  return isOpen() ? nvs_set_u8(_handle, key, value) : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::getI32(const char *key, int32_t &value) const {
  return isOpen() ? nvs_get_i32(_handle, key, &value) : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::setI32(const char *key, int32_t value) {
  return isOpen() ? nvs_set_i32(_handle, key, value) : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::erase(const char *key) {
  return isOpen() ? nvs_erase_key(_handle, key) : ESP_ERR_INVALID_STATE;
}

esp_err_t NvsNamespace::commit() {
  return isOpen() ? nvs_commit(_handle) : ESP_ERR_INVALID_STATE;
}

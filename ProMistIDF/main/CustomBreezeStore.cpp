#include "CustomBreezeStore.h"

#include <esp_log.h>

#include "NvsNamespace.h"

namespace {
constexpr const char *BREEZE_NAMESPACE = "promistbreeze";
constexpr const char *SLOT_KEYS[CUSTOM_BREEZE_SLOT_COUNT] = {
  "slot0", "slot1", "slot2"
};
constexpr char TAG[] = "BreezeStore";
}

void CustomBreezeStore::begin() {
  NvsNamespace storage;
  const bool available =
    storage.open(BREEZE_NAMESPACE, NVS_READONLY) == ESP_OK;
  for (uint8_t slot = 0; slot < CUSTOM_BREEZE_SLOT_COUNT; ++slot) {
    _profiles[slot] = {};
    _profiles[slot].slot = slot;
    size_t length = 0;
    if (!available || storage.blobSize(SLOT_KEYS[slot], length) != ESP_OK ||
        length != CUSTOM_BREEZE_WIRE_SIZE) {
      continue;
    }
    uint8_t bytes[CUSTOM_BREEZE_WIRE_SIZE] = {};
    if (storage.getBlob(SLOT_KEYS[slot], bytes, length) != ESP_OK ||
        length != sizeof(bytes) ||
        !decodeCustomBreezeProfile(bytes, sizeof(bytes), _profiles[slot]) ||
        _profiles[slot].slot != slot) {
      _profiles[slot] = {};
      _profiles[slot].slot = slot;
      ESP_LOGW(TAG, "Slot %u: invalid stored profile ignored", slot + 1);
    }
  }
}

const CustomBreezeProfile &CustomBreezeStore::profile(uint8_t slot) const {
  static CustomBreezeProfile empty;
  return slot < CUSTOM_BREEZE_SLOT_COUNT ? _profiles[slot] : empty;
}

const CustomBreezeProfile *CustomBreezeStore::profileForMode(uint8_t mode) const {
  const uint8_t slot = customBreezeSlotForMode(mode);
  return slot < CUSTOM_BREEZE_SLOT_COUNT && _profiles[slot].occupied
    ? &_profiles[slot]
    : nullptr;
}

bool CustomBreezeStore::hasMode(uint8_t mode) const {
  return profileForMode(mode) != nullptr;
}

bool CustomBreezeStore::save(const CustomBreezeProfile &profile) {
  if (!validateCustomBreezeProfile(profile)) return false;
  uint8_t bytes[CUSTOM_BREEZE_WIRE_SIZE] = {};
  encodeCustomBreezeProfile(profile, bytes);
  NvsNamespace storage;
  if (storage.open(BREEZE_NAMESPACE, NVS_READWRITE) != ESP_OK ||
      storage.setBlob(SLOT_KEYS[profile.slot], bytes, sizeof(bytes)) != ESP_OK ||
      storage.commit() != ESP_OK) return false;
  _profiles[profile.slot] = profile;
  return true;
}

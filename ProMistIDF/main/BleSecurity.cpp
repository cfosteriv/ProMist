// Proprietary owner enrollment and challenge-response authentication. Secret
// material is persisted only in NVS and is never emitted through diagnostics.
#include "BleSecurity.h"

#include <cstring>

#include <esp_random.h>
#include <esp_system.h>
#include <mbedtls/md.h>

#include "BleProtocol.h"
#include "NvsNamespace.h"

namespace {
constexpr const char *NAMESPACE = "promistsec";
constexpr const char *OWNER_KEY = "owner-key";

void write64(uint8_t *output, uint64_t value) {
  for (uint8_t i = 0; i < 8; ++i) {
    output[i] = static_cast<uint8_t>(value >> (8 * i));
  }
}

class NvsBleSecurityStore final : public BleSecurityStore {
 public:
  BleSecurityLoadResult load() override {
    BleSecurityLoadResult result;
    // A read-only open fails when this namespace has never been created. That
    // is the normal first-boot/unowned state, so create the empty namespace
    // while loading instead of treating a new device as unavailable.
    NvsNamespace storage;
    if (storage.open(NAMESPACE, NVS_READWRITE) != ESP_OK) return result;
    size_t length = 0;
    const esp_err_t sizeResult = storage.blobSize(OWNER_KEY, length);
    if (sizeResult == ESP_ERR_NVS_NOT_FOUND) {
      result.status = BleSecurityLoadStatus::Unowned;
    } else if (sizeResult != ESP_OK) {
      result.status = BleSecurityLoadStatus::Unavailable;
    } else if (length != BLE_OWNER_KEY_SIZE) {
      result.status = BleSecurityLoadStatus::Corrupt;
    } else if (storage.getBlob(OWNER_KEY, result.ownerKey, length) == ESP_OK &&
               length == BLE_OWNER_KEY_SIZE) {
      result.status = BleSecurityLoadStatus::Owned;
    } else {
      result.status = BleSecurityLoadStatus::Unavailable;
    }
    return result;
  }
  bool save(const uint8_t *key, size_t length) override {
    if (key == nullptr || length != BLE_OWNER_KEY_SIZE) return false;
    NvsNamespace storage;
    return storage.open(NAMESPACE, NVS_READWRITE) == ESP_OK &&
      storage.setBlob(OWNER_KEY, key, length) == ESP_OK &&
      storage.commit() == ESP_OK;
  }
  bool erase() override {
    NvsNamespace storage;
    if (storage.open(NAMESPACE, NVS_READWRITE) != ESP_OK) return false;
    const esp_err_t erased = storage.erase(OWNER_KEY);
    return erased == ESP_ERR_NVS_NOT_FOUND ||
      (erased == ESP_OK && storage.commit() == ESP_OK);
  }
};

NvsBleSecurityStore defaultStore;
}

BleSecurity::BleSecurity(uint64_t deviceId) : _deviceId(deviceId), _store(&defaultStore) {}
BleSecurity::BleSecurity(uint64_t deviceId, BleSecurityStore &store)
  : _deviceId(deviceId), _store(&store) {}

bool BleSecurity::begin(uint64_t deviceId) {
  _deviceId = deviceId;
  clearSessions();
  _sessionOwnership.clear();
  memset(_ownerKey, 0, sizeof(_ownerKey));
  _ownershipState = BleOwnershipState::Unavailable;
  const BleSecurityLoadResult loaded = _store->load();
  if (loaded.status == BleSecurityLoadStatus::Unowned) {
    _ownershipState = BleOwnershipState::Unowned;
  } else if (loaded.status == BleSecurityLoadStatus::Owned) {
    memcpy(_ownerKey, loaded.ownerKey, sizeof(_ownerKey));
    _ownershipState = BleOwnershipState::Owned;
  } else {
    return false;
  }
  return true;
}

bool BleSecurity::isAuthenticated(uint16_t connHandle) const {
  if (_ownershipState != BleOwnershipState::Owned ||
      !_sessionOwnership.owns(connHandle)) return false;
  for (const Session &item : _sessions)
    if (item.connHandle == connHandle) return item.authenticated;
  return false;
}

bool BleSecurity::isProvisioning(uint64_t nowMs) const {
  return _ownershipState == BleOwnershipState::Unowned &&
    _provisioningUntil > nowMs;
}

void BleSecurity::enterProvisioning(uint64_t nowMs, uint32_t durationMs) {
  if (_ownershipState == BleOwnershipState::Unowned) {
    _provisioningUntil = nowMs + durationMs;
  }
}

void BleSecurity::cancelProvisioning() {
  _provisioningUntil = 0;
}

bool BleSecurity::disconnect(uint16_t connHandle) {
  const bool ownedSession = _sessionOwnership.disconnect(connHandle);
  Session *item = session(connHandle, false);
  if (item != nullptr) *item = Session{};
  return ownedSession;
}

bool BleSecurity::disconnectAll() {
  const bool ownedSession = _sessionOwnership.hasOwner();
  clearSessions();
  _sessionOwnership.clear();
  return ownedSession;
}

bool BleSecurity::factoryReset() {
  const bool removed = _store->erase();
  clearSessions();
  _sessionOwnership.clear();
  memset(_ownerKey, 0, sizeof(_ownerKey));
  _ownershipState = removed ? BleOwnershipState::Unowned
                            : BleOwnershipState::Unavailable;
  _provisioningUntil = 0;
  return removed;
}

bool BleSecurity::randomBytes(uint8_t *output, size_t length) {
  if (output == nullptr) return false;
  esp_fill_random(output, length);
  return true;
}

bool BleSecurity::persistKey() {
  return _store->save(_ownerKey, sizeof(_ownerKey));
}

BleSecurity::Session *BleSecurity::session(uint16_t connHandle, bool create) {
  for (Session &item : _sessions) if (item.connHandle == connHandle) return &item;
  if (!create) return nullptr;
  for (Session &item : _sessions) if (item.connHandle == UINT16_MAX) {
    item.connHandle = connHandle;
    return &item;
  }
  return nullptr;
}

void BleSecurity::clearSessions() {
  for (Session &item : _sessions) item = Session{};
}

void BleSecurity::expectedHmac(const Session &session, uint8_t output[32]) const {
  uint8_t message[1 + 8 + 32 + 32] = {};
  message[0] = BLE_PROTOCOL_VERSION;
  write64(message + 1, _deviceId);
  memcpy(message + 9, session.clientNonce, 32);
  memcpy(message + 41, session.deviceNonce, 32);
  const mbedtls_md_info_t *info = mbedtls_md_info_from_type(MBEDTLS_MD_SHA256);
  mbedtls_md_hmac(info, _ownerKey, sizeof(_ownerKey), message, sizeof(message), output);
}

bool BleSecurity::constantTimeEqual(const uint8_t *a, const uint8_t *b, size_t n) {
  uint8_t difference = 0;
  for (size_t i = 0; i < n; ++i) difference |= a[i] ^ b[i];
  return difference == 0;
}

void BleSecurity::resultPacket(
  BleSecurityResult result,
  uint8_t output[BLE_SECURITY_PACKET_SIZE],
  size_t &length
) {
  output[0] = static_cast<uint8_t>(BleSecurityMessage::AuthenticationResult);
  output[1] = BLE_PROTOCOL_VERSION;
  output[2] = static_cast<uint8_t>(result);
  length = 3;
}

bool BleSecurity::handle(
  uint16_t connHandle,
  const uint8_t *input,
  size_t length,
  uint64_t nowMs,
  uint8_t output[BLE_SECURITY_PACKET_SIZE],
  size_t &outputLength
) {
  outputLength = 0;
  if (input == nullptr || output == nullptr || length < 2 ||
      input[1] != BLE_PROTOCOL_VERSION) {
    resultPacket(BleSecurityResult::Malformed, output, outputLength);
    return false;
  }
  const auto message = static_cast<BleSecurityMessage>(input[0]);
  if (_ownershipState == BleOwnershipState::Unavailable) {
    resultPacket(BleSecurityResult::SecurityStateUnavailable, output, outputLength);
    return false;
  }
  if (message == BleSecurityMessage::ProvisionRequest) {
    if (length != 2) {
      resultPacket(BleSecurityResult::Malformed, output, outputLength);
    } else if (isOwned()) {
      resultPacket(BleSecurityResult::AlreadyOwned, output, outputLength);
    } else if (!isProvisioning(nowMs)) {
      resultPacket(BleSecurityResult::NotProvisioning, output, outputLength);
    } else if (!randomBytes(_ownerKey, sizeof(_ownerKey)) || !persistKey()) {
      memset(_ownerKey, 0, sizeof(_ownerKey));
      resultPacket(BleSecurityResult::AuthenticationFailed, output, outputLength);
    } else {
      _ownershipState = BleOwnershipState::Owned;
      Session *item = session(connHandle, true);
      if (item == nullptr) {
        memset(_ownerKey, 0, sizeof(_ownerKey));
        _ownershipState = BleOwnershipState::Unavailable;
        resultPacket(BleSecurityResult::SecurityStateUnavailable, output, outputLength);
        return false;
      }
      item->authenticated = true;
      _sessionOwnership.authenticate(connHandle);
      _provisioningUntil = 0;
      output[0] = static_cast<uint8_t>(BleSecurityMessage::Provisioned);
      output[1] = BLE_PROTOCOL_VERSION;
      memcpy(output + 2, _ownerKey, sizeof(_ownerKey));
      outputLength = BLE_SECURITY_PACKET_SIZE;
    }
    return true;
  }
  if (!isOwned()) {
    resultPacket(BleSecurityResult::Unauthorized, output, outputLength);
    return false;
  }
  if (message == BleSecurityMessage::AuthenticationRequest && length == 34) {
    if (!_sessionOwnership.canAuthenticate(connHandle)) {
      resultPacket(BleSecurityResult::Unauthorized, output, outputLength);
      return false;
    }
    Session *item = session(connHandle, true);
    if (item == nullptr) {
      resultPacket(BleSecurityResult::SecurityStateUnavailable, output, outputLength);
      return false;
    }
    item->authenticated = false;
    memcpy(item->clientNonce, input + 2, 32);
    randomBytes(item->deviceNonce, sizeof(item->deviceNonce));
    item->challengeActive = true;
    output[0] = static_cast<uint8_t>(BleSecurityMessage::AuthenticationChallenge);
    output[1] = BLE_PROTOCOL_VERSION;
    memcpy(output + 2, item->deviceNonce, 32);
    outputLength = BLE_SECURITY_PACKET_SIZE;
    return true;
  }
  if (message == BleSecurityMessage::AuthenticationResponse && length == 34) {
    Session *item = session(connHandle, false);
    if (item == nullptr || !item->challengeActive) {
      resultPacket(BleSecurityResult::NoChallenge, output, outputLength);
      return false;
    }
    uint8_t expected[32];
    expectedHmac(*item, expected);
    item->challengeActive = false;  // Consume before comparison to prevent replay.
    const bool hmacValid = constantTimeEqual(expected, input + 2, sizeof(expected));
    const bool authenticated = hmacValid && _sessionOwnership.authenticate(connHandle);
    item->authenticated = authenticated;
    memset(item->clientNonce, 0, sizeof(item->clientNonce));
    memset(item->deviceNonce, 0, sizeof(item->deviceNonce));
    memset(expected, 0, sizeof(expected));
    resultPacket(authenticated
      ? BleSecurityResult::Success
      : (hmacValid ? BleSecurityResult::Unauthorized
                   : BleSecurityResult::AuthenticationFailed),
      output, outputLength);
    return authenticated;
  }
  if (message == BleSecurityMessage::ResetOwnership && length == 2) {
    if (!isAuthenticated(connHandle)) {
      resultPacket(BleSecurityResult::Unauthorized, output, outputLength);
      return false;
    }
    factoryReset();
    resultPacket(BleSecurityResult::Success, output, outputLength);
    return true;
  }
  resultPacket(BleSecurityResult::Malformed, output, outputLength);
  return false;
}

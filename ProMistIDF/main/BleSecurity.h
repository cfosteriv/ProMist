#pragma once

// Physically authorized enrollment and per-connection HMAC authentication.

#include <cstddef>
#include <cstdint>

#include "BleSessionOwnership.h"

constexpr size_t BLE_SECURITY_NONCE_SIZE = 32;
constexpr size_t BLE_OWNER_KEY_SIZE = 32;
constexpr size_t BLE_SECURITY_PACKET_SIZE = 34;

enum class BleSecurityMessage : uint8_t {
  ProvisionRequest = 0x10,
  Provisioned = 0x11,
  AuthenticationRequest = 0x20,
  AuthenticationChallenge = 0x21,
  AuthenticationResponse = 0x22,
  AuthenticationResult = 0x23,
  ResetOwnership = 0x30
};

enum class BleSecurityResult : uint8_t {
  Success = 0,
  Malformed = 1,
  NotProvisioning = 2,
  AlreadyOwned = 3,
  NoChallenge = 4,
  AuthenticationFailed = 5,
  Unauthorized = 6,
  SecurityStateUnavailable = 7
};

enum class BleOwnershipState : uint8_t { Unavailable, Unowned, Owned };

enum class BleSecurityLoadStatus : uint8_t { Unowned, Owned, Unavailable, Corrupt };

struct BleSecurityLoadResult {
  BleSecurityLoadStatus status = BleSecurityLoadStatus::Unavailable;
  uint8_t ownerKey[BLE_OWNER_KEY_SIZE] = {};
};

class BleSecurityStore {
 public:
  virtual ~BleSecurityStore() = default;
  virtual BleSecurityLoadResult load() = 0;
  virtual bool save(const uint8_t *key, size_t length) = 0;
  virtual bool erase() = 0;
};

class BleSecurity {
 public:
  /// Creates security state bound to the full identity used in HMAC transcripts.
  explicit BleSecurity(uint64_t deviceId);
  BleSecurity(uint64_t deviceId, BleSecurityStore &store);
  /// Loads an existing owner key, or initializes an unowned device.
  bool begin(uint64_t deviceId);
  bool isOwned() const { return _ownershipState == BleOwnershipState::Owned; }
  bool isAvailable() const { return _ownershipState != BleOwnershipState::Unavailable; }
  bool isAuthenticated(uint16_t connHandle) const;
  uint16_t ownerConnectionHandle() const { return _sessionOwnership.owner(); }
  bool isProvisioning(uint64_t nowMs) const;
  /// Opens a bounded physical provisioning window.
  /// @param nowMs Current monotonic milliseconds.
  /// @param durationMs Window length; defaults to sixty seconds.
  void enterProvisioning(uint64_t nowMs, uint32_t durationMs = 60000);
  /// Closes an active physical provisioning window without changing ownership.
  void cancelProvisioning();
  /// Clears nonce and authentication state when the BLE link ends. Returns
  /// true only when that link owned the proprietary-control session.
  bool disconnect(uint16_t connHandle);
  /// Clears every volatile link/session after lifecycle event loss. Returns
  /// true when an authenticated owner was invalidated.
  bool disconnectAll();
  /// Erases proprietary owner material; the caller coordinates wider reset state.
  bool factoryReset();

  /// Processes one untrusted security-characteristic write and, when applicable,
  /// encodes a notification into caller-owned output/outputLength. Secrets are
  /// returned only once during a physically authorized provisioning window.
  bool handle(
    uint16_t connHandle,
    const uint8_t *input,
    size_t length,
    uint64_t nowMs,
    uint8_t output[BLE_SECURITY_PACKET_SIZE],
    size_t &outputLength
  );

 private:
  uint64_t _deviceId;
  BleSecurityStore *_store;
  BleOwnershipState _ownershipState = BleOwnershipState::Unavailable;
  struct Session {
    uint16_t connHandle = UINT16_MAX;
    bool authenticated = false;
    bool challengeActive = false;
    uint8_t clientNonce[BLE_SECURITY_NONCE_SIZE] = {};
    uint8_t deviceNonce[BLE_SECURITY_NONCE_SIZE] = {};
  };
  // Pending challenge storage follows the two-link NimBLE host capacity;
  // BleSessionOwnership still permits only one authenticated control owner.
  static constexpr size_t MAX_SESSIONS = 2;
  Session _sessions[MAX_SESSIONS];
  uint64_t _provisioningUntil = 0;
  uint8_t _ownerKey[BLE_OWNER_KEY_SIZE] = {};
  BleSessionOwnership _sessionOwnership;

  bool persistKey();
  bool randomBytes(uint8_t *output, size_t length);
  Session *session(uint16_t connHandle, bool create);
  void clearSessions();
  void expectedHmac(const Session &session, uint8_t output[32]) const;
  static bool constantTimeEqual(const uint8_t *a, const uint8_t *b, size_t n);
  static void resultPacket(
    BleSecurityResult result,
    uint8_t output[BLE_SECURITY_PACKET_SIZE],
    size_t &length
  );
};

#pragma once

#include <cstdint>

// Ownership policy for the proprietary ProMist GATT control surface. The
// NimBLE host can carry more than one link so Matter commissioning can coexist,
// but only one connection may own an authenticated proprietary-control session.
class BleSessionOwnership {
 public:
  static constexpr uint16_t INVALID_CONNECTION_HANDLE = UINT16_MAX;

  bool canAuthenticate(uint16_t connHandle) const {
    return connHandle != INVALID_CONNECTION_HANDLE &&
      (_owner == INVALID_CONNECTION_HANDLE || _owner == connHandle);
  }

  bool authenticate(uint16_t connHandle) {
    if (!canAuthenticate(connHandle)) return false;
    _owner = connHandle;
    return true;
  }

  bool owns(uint16_t connHandle) const {
    return connHandle != INVALID_CONNECTION_HANDLE && _owner == connHandle;
  }

  bool hasOwner() const { return _owner != INVALID_CONNECTION_HANDLE; }
  uint16_t owner() const { return _owner; }

  // Returns true only when the disconnected link owned the proprietary session.
  bool disconnect(uint16_t connHandle) {
    if (!owns(connHandle)) return false;
    _owner = INVALID_CONNECTION_HANDLE;
    return true;
  }

  void clear() { _owner = INVALID_CONNECTION_HANDLE; }

 private:
  uint16_t _owner = INVALID_CONNECTION_HANDLE;
};

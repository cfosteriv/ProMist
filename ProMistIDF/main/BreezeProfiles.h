#pragma once

// Bounded custom-breeze representation shared by persistence, BLE and the
// local playback engine. Profiles deliberately use whole-second segments and
// the fan's calibrated levels instead of accepting arbitrary PWM values.

#include <cstddef>
#include <cstdint>

constexpr uint8_t CUSTOM_BREEZE_SLOT_COUNT = 3;
constexpr uint8_t CUSTOM_BREEZE_FIRST_MODE = 4;
constexpr uint8_t CUSTOM_BREEZE_LAST_MODE = 6;
constexpr uint8_t CUSTOM_BREEZE_MAX_SEGMENTS = 16;
constexpr uint8_t CUSTOM_BREEZE_MAX_NAME_BYTES = 20;
constexpr size_t CUSTOM_BREEZE_WIRE_SIZE = 64;

struct BreezeSegment {
  uint8_t level = 1;
  uint8_t durationSeconds = 1;
};

struct CustomBreezeProfile {
  bool occupied = false;
  uint8_t slot = 0;
  uint8_t cycleSeconds = 0;
  uint8_t segmentCount = 0;
  uint32_t profileId = 0;
  char name[CUSTOM_BREEZE_MAX_NAME_BYTES + 1] = {};
  BreezeSegment segments[CUSTOM_BREEZE_MAX_SEGMENTS] = {};
};

/** Computes the CRC-16/CCITT value stored in a custom-breeze packet. */
uint16_t breezeProfileCrc16(const uint8_t *bytes, size_t length);
/**
 * Validates slot, UTF-8 name, cycle duration, segments, levels, and adjacent
 * level transitions for an in-memory profile.
 */
bool validateCustomBreezeProfile(const CustomBreezeProfile &profile);
/** Serializes a validated profile into the fixed 64-byte version-2 format. */
void encodeCustomBreezeProfile(
  const CustomBreezeProfile &profile,
  uint8_t output[CUSTOM_BREEZE_WIRE_SIZE]
);
/**
 * Decodes and validates an untrusted fixed-size profile, including its CRC.
 *
 * @param bytes Input buffer.
 * @param length Must equal CUSTOM_BREEZE_WIRE_SIZE.
 * @param profile Receives the decoded value only on success.
 * @return true when the complete packet is valid.
 */
bool decodeCustomBreezeProfile(
  const uint8_t *bytes,
  size_t length,
  CustomBreezeProfile &profile
);

inline uint8_t customBreezeSlotForMode(uint8_t mode) {
  return mode >= CUSTOM_BREEZE_FIRST_MODE && mode <= CUSTOM_BREEZE_LAST_MODE
    ? static_cast<uint8_t>(mode - CUSTOM_BREEZE_FIRST_MODE)
    : UINT8_MAX;
}

inline uint8_t customBreezeModeForSlot(uint8_t slot) {
  return slot < CUSTOM_BREEZE_SLOT_COUNT
    ? static_cast<uint8_t>(CUSTOM_BREEZE_FIRST_MODE + slot)
    : 0;
}

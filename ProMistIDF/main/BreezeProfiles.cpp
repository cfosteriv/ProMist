#include "BreezeProfiles.h"

#include <cstring>

namespace {

constexpr uint8_t PROFILE_FLAG_OCCUPIED = 0x01;
constexpr size_t NAME_OFFSET = 10;
constexpr size_t SEGMENT_OFFSET = 30;
constexpr size_t CRC_OFFSET = 62;

void write32(uint8_t *output, uint32_t value) {
  for (uint8_t index = 0; index < 4; ++index) {
    output[index] = static_cast<uint8_t>(value >> (8 * index));
  }
}

uint32_t read32(const uint8_t *input) {
  uint32_t value = 0;
  for (uint8_t index = 0; index < 4; ++index) {
    value |= static_cast<uint32_t>(input[index]) << (8 * index);
  }
  return value;
}

bool isAllowedCycle(uint8_t seconds) {
  return seconds == 15 || seconds == 30 || seconds == 45 || seconds == 60;
}

bool isContinuationByte(uint8_t value) {
  return (value & 0xC0) == 0x80;
}

bool isValidUtf8(const uint8_t *bytes, size_t length) {
  size_t index = 0;
  while (index < length) {
    const uint8_t first = bytes[index];
    if (first >= 0x20 && first <= 0x7E) { ++index; continue; }
    if (first >= 0xC2 && first <= 0xDF) {
      if (index + 1 >= length || !isContinuationByte(bytes[index + 1])) return false;
      index += 2;
      continue;
    }
    if (first >= 0xE0 && first <= 0xEF) {
      if (index + 2 >= length || !isContinuationByte(bytes[index + 1]) ||
          !isContinuationByte(bytes[index + 2]) ||
          (first == 0xE0 && bytes[index + 1] < 0xA0) ||
          (first == 0xED && bytes[index + 1] > 0x9F)) return false;
      index += 3;
      continue;
    }
    if (first >= 0xF0 && first <= 0xF4) {
      if (index + 3 >= length || !isContinuationByte(bytes[index + 1]) ||
          !isContinuationByte(bytes[index + 2]) ||
          !isContinuationByte(bytes[index + 3]) ||
          (first == 0xF0 && bytes[index + 1] < 0x90) ||
          (first == 0xF4 && bytes[index + 1] > 0x8F)) return false;
      index += 4;
      continue;
    }
    return false;
  }
  return true;
}

size_t profileNameLength(const CustomBreezeProfile &profile) {
  size_t length = 0;
  while (length <= CUSTOM_BREEZE_MAX_NAME_BYTES && profile.name[length] != '\0') {
    ++length;
  }
  return length;
}

}  // namespace

uint16_t breezeProfileCrc16(const uint8_t *bytes, size_t length) {
  uint16_t crc = 0xFFFF;
  for (size_t index = 0; index < length; ++index) {
    const uint16_t shiftedByte = static_cast<uint16_t>(
      static_cast<uint16_t>(bytes[index]) << 8U
    );
    crc = static_cast<uint16_t>(crc ^ shiftedByte);
    for (uint8_t bit = 0; bit < 8; ++bit) {
      const bool highBitSet = (crc & UINT16_C(0x8000)) != 0U;
      const uint16_t shifted = static_cast<uint16_t>(crc << 1U);
      crc = highBitSet
        ? static_cast<uint16_t>(shifted ^ UINT16_C(0x1021))
        : shifted;
    }
  }
  return crc;
}

bool validateCustomBreezeProfile(const CustomBreezeProfile &profile) {
  if (profile.slot >= CUSTOM_BREEZE_SLOT_COUNT) return false;
  if (!profile.occupied) {
    return profile.cycleSeconds == 0 && profile.segmentCount == 0 &&
      profile.profileId == 0 && profile.name[0] == '\0';
  }
  const size_t nameLength = profileNameLength(profile);
  if (profile.profileId == 0 || nameLength == 0 ||
      nameLength > CUSTOM_BREEZE_MAX_NAME_BYTES ||
      !isValidUtf8(reinterpret_cast<const uint8_t *>(profile.name), nameLength) ||
      !isAllowedCycle(profile.cycleSeconds) || profile.segmentCount == 0 ||
      profile.segmentCount > CUSTOM_BREEZE_MAX_SEGMENTS) {
    return false;
  }
  uint16_t totalSeconds = 0;
  for (uint8_t index = 0; index < profile.segmentCount; ++index) {
    const BreezeSegment &segment = profile.segments[index];
    if (segment.level < 1 || segment.level > 5 || segment.durationSeconds == 0) {
      return false;
    }
    totalSeconds += segment.durationSeconds;
    const BreezeSegment &next = profile.segments[
      static_cast<uint8_t>((index + 1) % profile.segmentCount)
    ];
    const int difference = static_cast<int>(segment.level) - next.level;
    if (difference < -2 || difference > 2) return false;
  }
  return totalSeconds == profile.cycleSeconds;
}

void encodeCustomBreezeProfile(
  const CustomBreezeProfile &profile,
  uint8_t output[CUSTOM_BREEZE_WIRE_SIZE]
) {
  memset(output, 0, CUSTOM_BREEZE_WIRE_SIZE);
  output[0] = 2;
  output[1] = profile.slot;
  if (profile.occupied) {
    const size_t nameLength = profileNameLength(profile);
    output[2] = PROFILE_FLAG_OCCUPIED;
    output[3] = static_cast<uint8_t>(nameLength);
    output[4] = profile.segmentCount;
    output[5] = profile.cycleSeconds;
    write32(output + 6, profile.profileId);
    memcpy(output + NAME_OFFSET, profile.name, nameLength);
    for (uint8_t index = 0; index < profile.segmentCount; ++index) {
      output[SEGMENT_OFFSET + index * 2] = profile.segments[index].level;
      output[SEGMENT_OFFSET + index * 2 + 1] =
        profile.segments[index].durationSeconds;
    }
  }
  const uint16_t crc = breezeProfileCrc16(output, CRC_OFFSET);
  output[CRC_OFFSET] = static_cast<uint8_t>(crc);
  output[CRC_OFFSET + 1] = static_cast<uint8_t>(crc >> 8);
}

bool decodeCustomBreezeProfile(
  const uint8_t *bytes,
  size_t length,
  CustomBreezeProfile &profile
) {
  if (bytes == nullptr || length != CUSTOM_BREEZE_WIRE_SIZE || bytes[0] != 2 ||
      bytes[1] >= CUSTOM_BREEZE_SLOT_COUNT || (bytes[2] & ~PROFILE_FLAG_OCCUPIED) != 0 ||
      bytes[3] > CUSTOM_BREEZE_MAX_NAME_BYTES ||
      bytes[4] > CUSTOM_BREEZE_MAX_SEGMENTS) {
    return false;
  }
  const uint16_t storedCrc = static_cast<uint16_t>(
    static_cast<uint16_t>(bytes[CRC_OFFSET]) |
    static_cast<uint16_t>(static_cast<uint16_t>(bytes[CRC_OFFSET + 1]) << 8)
  );
  if (storedCrc != breezeProfileCrc16(bytes, CRC_OFFSET)) return false;

  CustomBreezeProfile decoded;
  decoded.slot = bytes[1];
  decoded.occupied = (bytes[2] & PROFILE_FLAG_OCCUPIED) != 0;
  if (!decoded.occupied) {
    for (size_t index = 3; index < CRC_OFFSET; ++index) {
      if (bytes[index] != 0) return false;
    }
  }
  if (decoded.occupied) {
    decoded.segmentCount = bytes[4];
    decoded.cycleSeconds = bytes[5];
    decoded.profileId = read32(bytes + 6);
    memcpy(decoded.name, bytes + NAME_OFFSET, bytes[3]);
    decoded.name[bytes[3]] = '\0';
    for (uint8_t index = 0; index < decoded.segmentCount; ++index) {
      decoded.segments[index] = {
        bytes[SEGMENT_OFFSET + index * 2],
        bytes[SEGMENT_OFFSET + index * 2 + 1]
      };
    }
  }
  if (!validateCustomBreezeProfile(decoded)) return false;
  profile = decoded;
  return true;
}

#include <cassert>
#include <cstring>

#include "BreezeProfiles.h"

int main() {
  const uint8_t crcFixture[] = {'1', '2', '3', '4', '5', '6', '7', '8', '9'};
  assert(breezeProfileCrc16(crcFixture, sizeof(crcFixture)) == 0x29B1);

  CustomBreezeProfile profile;
  profile.occupied = true;
  profile.slot = 1;
  profile.cycleSeconds = 15;
  profile.segmentCount = 3;
  profile.profileId = 0x12345678;
  std::strcpy(profile.name, "Porch Wave");
  profile.segments[0] = {3, 5};
  profile.segments[1] = {5, 5};
  profile.segments[2] = {3, 5};
  assert(validateCustomBreezeProfile(profile));

  uint8_t bytes[CUSTOM_BREEZE_WIRE_SIZE] = {};
  encodeCustomBreezeProfile(profile, bytes);
  CustomBreezeProfile decoded;
  assert(decodeCustomBreezeProfile(bytes, sizeof(bytes), decoded));
  assert(decoded.slot == 1);
  assert(decoded.profileId == profile.profileId);
  assert(std::strcmp(decoded.name, "Porch Wave") == 0);
  assert(decoded.segments[1].level == 5);

  bytes[31] ^= 1;
  assert(!decodeCustomBreezeProfile(bytes, sizeof(bytes), decoded));

  profile.segments[1].level = 1;
  profile.segments[0].level = 5;
  assert(!validateCustomBreezeProfile(profile));
  profile.segments[0].level = 3;
  profile.segments[1].level = 5;
  profile.segments[2].durationSeconds = 4;
  assert(!validateCustomBreezeProfile(profile));

  CustomBreezeProfile empty;
  empty.slot = 2;
  assert(validateCustomBreezeProfile(empty));
  encodeCustomBreezeProfile(empty, bytes);
  assert(decodeCustomBreezeProfile(bytes, sizeof(bytes), decoded));
  assert(!decoded.occupied && decoded.slot == 2);
}

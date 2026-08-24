#include <cassert>
#include "SafetyPolicy.h"

int main() {
  assert(OscillationSafetyPolicy::permitsStep(99, 1, 200));
  assert(!OscillationSafetyPolicy::permitsStep(100, 1, 200));
  assert(OscillationSafetyPolicy::permitsStep(-99, -1, 200));
  assert(!OscillationSafetyPolicy::permitsStep(-100, -1, 200));
  assert(!OscillationSafetyPolicy::permitsStep(0, 1, 0));
  assert(OscillationSafetyPolicy::clampTarget(99, 200) == 99);
  assert(OscillationSafetyPolicy::clampTarget(100, 200) == 100);
  assert(OscillationSafetyPolicy::clampTarget(101, 200) == 100);
  assert(OscillationSafetyPolicy::clampTarget(-100, 200) == -100);
  assert(OscillationSafetyPolicy::clampTarget(-101, 200) == -100);
  assert(OscillationSafetyPolicy::clampTarget(INT32_MAX, 200) == 100);
  assert(OscillationSafetyPolicy::clampTarget(INT32_MIN, 200) == -100);
  assert(OscillationSafetyPolicy::clampTarget(50, 0) == 0);
  assert(OscillationSafetyPolicy::validPersistedPosition(99, 200));
  assert(OscillationSafetyPolicy::validPersistedPosition(100, 200));
  assert(OscillationSafetyPolicy::validPersistedPosition(-100, 200));
  assert(!OscillationSafetyPolicy::validPersistedPosition(101, 200));
  assert(!OscillationSafetyPolicy::validPersistedPosition(-101, 200));
  assert(!OscillationSafetyPolicy::validPersistedPosition(INT32_MAX, 200));
  assert(!OscillationSafetyPolicy::validPersistedPosition(INT32_MIN, 200));
  assert(!OscillationSafetyPolicy::validPersistedPosition(0, 0));
  int32_t scaled = 0;
  assert(OscillationSafetyPolicy::scalePersistedValue(100, 2, scaled));
  assert(scaled == 200);
  assert(!OscillationSafetyPolicy::scalePersistedValue(INT32_MAX, 2, scaled));
  assert(!OscillationSafetyPolicy::scalePersistedValue(INT32_MIN, 2, scaled));
  assert(!OscillationSafetyPolicy::plausibleHallWidth(127, 0));
  assert(OscillationSafetyPolicy::plausibleHallWidth(128, 0));
  assert(OscillationSafetyPolicy::plausibleHallWidth(1536, 0));
  assert(!OscillationSafetyPolicy::plausibleHallWidth(1537, 0));
  assert(OscillationSafetyPolicy::plausibleHallWidth(300, 400));
  assert(!OscillationSafetyPolicy::plausibleHallWidth(199, 400));

  FanOverspeedPolicy fan;
  assert(!fan.observe(200));
  assert(!fan.observe(246));
  assert(!fan.observe(200));
  assert(!fan.observe(246));
  assert(fan.observe(246));
  assert(fan.observe(300));
  fan.reset();
  assert(!fan.observe(20000));
  assert(!fan.observe(246));
}

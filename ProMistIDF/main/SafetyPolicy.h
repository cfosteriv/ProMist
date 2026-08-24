#pragma once

#include <cstdint>

struct FanOverspeedPolicy {
  static constexpr float HARD_SHUTDOWN_HZ = 245.0f;
  static constexpr uint8_t REQUIRED_SAMPLES = 2;
  uint8_t highSamples = 0;
  bool observe(float hz) {
    if (!(hz >= 0.0f) || hz > 10000.0f) { highSamples = 0; return false; }
    if (hz > HARD_SHUTDOWN_HZ) {
      if (highSamples < REQUIRED_SAMPLES) ++highSamples;
    } else highSamples = 0;
    return highSamples >= REQUIRED_SAMPLES;
  }
  void reset() { highSamples = 0; }
};

struct OscillationSafetyPolicy {
  static constexpr int32_t MIN_HALL_WIDTH = 128;
  static constexpr int32_t MAX_HALL_WIDTH = 1536;
  static bool permitsStep(int32_t position, int8_t direction, int32_t fullSafeTravel) {
    if (fullSafeTravel <= 0) return false;
    const int32_t next = position + (direction >= 0 ? 1 : -1);
    const int32_t limit = fullSafeTravel / 2;
    return next >= -limit && next <= limit;
  }
  static int32_t clampTarget(int32_t target, int32_t fullSafeTravel) {
    if (fullSafeTravel <= 0) return 0;
    const int32_t limit = fullSafeTravel / 2;
    if (target < -limit) return -limit;
    if (target > limit) return limit;
    return target;
  }
  static bool validPersistedPosition(int32_t position, int32_t fullSafeTravel) {
    if (fullSafeTravel <= 0) return false;
    const int32_t limit = fullSafeTravel / 2;
    return position >= -limit && position <= limit;
  }
  static bool scalePersistedValue(int32_t value, int32_t scale, int32_t &output) {
    if (scale <= 0) return false;
    const int64_t scaled = static_cast<int64_t>(value) * scale;
    if (scaled < INT32_MIN || scaled > INT32_MAX) return false;
    output = static_cast<int32_t>(scaled);
    return true;
  }
  static bool plausibleHallWidth(int32_t width, int32_t trustedWidth) {
    if (width < MIN_HALL_WIDTH || width > MAX_HALL_WIDTH) return false;
    if (trustedWidth <= 0) return true;
    const int32_t deviation = width >= trustedWidth ? width - trustedWidth : trustedWidth - width;
    return deviation <= trustedWidth / 2;
  }
};

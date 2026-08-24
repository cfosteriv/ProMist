#pragma once

#include "BreezeProfiles.h"

/** Loads and saves the three versioned custom-breeze slots in NVS. */
class CustomBreezeStore {
 public:
  /** Loads valid profiles and leaves missing or corrupt slots empty. */
  void begin();
  /**
   * Returns a slot value; an out-of-range request returns an empty sentinel.
   */
  const CustomBreezeProfile &profile(uint8_t slot) const;
  /** Returns the occupied profile mapped to a custom mode, or nullptr. */
  const CustomBreezeProfile *profileForMode(uint8_t mode) const;
  /** Returns whether a selectable occupied profile exists for the mode. */
  bool hasMode(uint8_t mode) const;
  /**
   * Validates, encodes, commits, and caches one profile.
   *
   * @return false when validation, NVS access, or commit fails.
   */
  bool save(const CustomBreezeProfile &profile);

 private:
  CustomBreezeProfile _profiles[CUSTOM_BREEZE_SLOT_COUNT] = {};
};

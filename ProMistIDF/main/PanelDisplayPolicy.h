#pragma once

// Pure normal-operation display policy. DeviceState remains the authority;
// animations, security feedback, and faults are temporary overlays applied by
// UserInterface.

#include <cstdint>

#include "DeviceController.h"

enum class PanelDisplayView : uint8_t {
  Fan,
  Oscillation,
  Mist,
  Breeze
};

struct PanelDisplayIntent {
  bool enabled = false;
  uint8_t whiteMask = 0;
  uint8_t rgbMask = 0;
};

constexpr uint8_t PANEL_RGB_GREEN = 0x10;
constexpr uint32_t PANEL_DISPLAY_TIMEOUT_MS = 30000;
constexpr uint32_t PANEL_BOOT_RGB_DURATION_MS = 10000;

inline bool panelIntervalElapsed(
  uint32_t now,
  uint32_t started,
  uint32_t duration
) {
  // Unsigned subtraction keeps this protocol-sized deadline rollover-safe.
  return now - started >= duration;
}

inline uint8_t panelFanLevelMask(uint8_t targetFanSpeed) {
  if (targetFanSpeed < 1 || targetFanSpeed > 5) return 0;
  return static_cast<uint8_t>((1U << targetFanSpeed) - 1U);
}

inline uint8_t panelOscillationMask(uint8_t oscillationMode) {
  switch (oscillationMode) {
    case 1: return 0x04;
    case 2: return 0x0E;
    case 3: return 0x1F;
    default: return 0;
  }
}

inline PanelDisplayIntent normalPanelDisplayIntent(
  const DeviceState &state,
  PanelDisplayView selectedView,
  uint8_t animatedWhiteMask
) {
  if (!state.power) return {};

  // A powered appliance always has a fan-level base display. Feature views
  // replace it only while that feature is active; disabling a feature falls
  // directly back to the authoritative fan state.
  uint8_t whiteMask = panelFanLevelMask(state.targetFanSpeed);
  switch (selectedView) {
    case PanelDisplayView::Oscillation:
      if (state.oscillationMode != 0) {
        whiteMask = panelOscillationMask(state.oscillationMode);
      }
      break;
    case PanelDisplayView::Mist:
      if (state.mistMode != 0) whiteMask = animatedWhiteMask;
      break;
    case PanelDisplayView::Breeze:
      if (state.breezeMode != 0) whiteMask = animatedWhiteMask;
      break;
    case PanelDisplayView::Fan:
      break;
  }

  return {true, whiteMask, PANEL_RGB_GREEN};
}

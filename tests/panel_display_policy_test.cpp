// Verifies normal panel output and the timing boundaries used by UserInterface.
// The UI applies its awake/asleep gate around this authoritative state policy.
#include <cassert>

#include "PanelDisplayPolicy.h"

int main() {
  static_assert(PANEL_DISPLAY_TIMEOUT_MS == 30000);
  static_assert(PANEL_BOOT_RGB_DURATION_MS == 10000);
  assert(!panelIntervalElapsed(29999, 0, PANEL_DISPLAY_TIMEOUT_MS));
  assert(panelIntervalElapsed(30000, 0, PANEL_DISPLAY_TIMEOUT_MS));
  // The same subtraction remains valid when the 32-bit millisecond clock wraps.
  assert(panelIntervalElapsed(5, UINT32_MAX - 4, 10));

  DeviceState state;

  PanelDisplayIntent intent = normalPanelDisplayIntent(
    state, PanelDisplayView::Fan, 0
  );
  assert(!intent.enabled);
  assert(intent.whiteMask == 0);
  assert(intent.rgbMask == 0);

  state.power = true;
  state.targetFanSpeed = 3;
  intent = normalPanelDisplayIntent(state, PanelDisplayView::Fan, 0);
  assert(intent.enabled);
  assert(intent.whiteMask == 0x07);
  assert(intent.rgbMask == PANEL_RGB_GREEN);

  // An inactive feature view falls back to the fan level instead of leaving
  // the powered appliance with a blank panel.
  intent = normalPanelDisplayIntent(state, PanelDisplayView::Mist, 0x1F);
  assert(intent.enabled);
  assert(intent.whiteMask == 0x07);

  state.mistMode = 1;
  intent = normalPanelDisplayIntent(state, PanelDisplayView::Mist, 0x0F);
  assert(intent.whiteMask == 0x0F);

  state.mistMode = 0;
  state.oscillationMode = 2;
  intent = normalPanelDisplayIntent(
    state, PanelDisplayView::Oscillation, 0
  );
  assert(intent.whiteMask == 0x0E);

  state.oscillationMode = 0;
  intent = normalPanelDisplayIntent(
    state, PanelDisplayView::Oscillation, 0
  );
  assert(intent.whiteMask == 0x07);

  state.breezeMode = 2;
  intent = normalPanelDisplayIntent(state, PanelDisplayView::Breeze, 0x15);
  assert(intent.whiteMask == 0x15);

  // Authoritative power wins over every selected view and animation mask.
  state.power = false;
  intent = normalPanelDisplayIntent(state, PanelDisplayView::Breeze, 0x1F);
  assert(!intent.enabled);
  assert(intent.whiteMask == 0);
  assert(intent.rgbMask == 0);
}

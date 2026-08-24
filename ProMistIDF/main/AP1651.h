#pragma once

// Minimal retained-panel bus driver. Higher-level button policy and animations
// belong to UserInterface rather than this electrical protocol boundary.

#include <cstdint>

#include <driver/gpio.h>

/** Bit-banged driver for the retained AP1651 panel bus. */
class AP1651 {
 public:
  /**
   * Creates a driver for the measured clock/data wiring.
   *
   * @param clockPin Push-pull clock output.
   * @param dataPin Bidirectional data line released to its pull-up for HIGH.
   */
  AP1651(uint8_t clockPin, uint8_t dataPin);

  /** Configures an idle-high clock and released data line. */
  void begin();

  /**
   * Reads the current raw panel key code.
   *
   * @param acknowledged Receives whether every bus phase was acknowledged.
   * @return Raw AP1651 key byte; use acknowledged before interpreting it.
   */
  uint8_t readButtons(bool &acknowledged);

  /**
   * Writes the retained panel's five white LEDs and three RGB channels.
   *
   * @param whiteLedMask Low five bits select the white LEDs.
   * @param rgbLedMask Bits 3...5 select RGB channels.
   * @param brightness AP1651 brightness in the inclusive range 0...7; higher
   * bits are ignored.
   * @return true when all commands and data bytes were acknowledged.
   */
  bool setDisplay(
    uint8_t whiteLedMask,
    uint8_t rgbLedMask,
    uint8_t brightness = 7
  );

  /** @return true when the display-off command was acknowledged. */
  bool displayOff();

 private:
  static constexpr uint8_t COMMAND_WRITE_AUTO = 0x40;
  static constexpr uint8_t COMMAND_READ_KEYS = 0x42;
  static constexpr uint8_t COMMAND_ADDRESS_0 = 0xC0;
  static constexpr uint8_t COMMAND_DISPLAY_OFF = 0x80;
  static constexpr uint8_t COMMAND_DISPLAY_ON = 0x88;

  static constexpr uint32_t BUS_HALF_PERIOD_US = 12;

  gpio_num_t _clockPin;
  gpio_num_t _dataPin;
  bool _ready = false;

  void busDelay();
  bool setClockLevel(int level);
  bool dataLow();
  bool dataRelease();
  bool busStart();
  bool busStop();

  bool writeByte(uint8_t value);
  bool readByte(uint8_t &value);
  bool sendCommand(uint8_t command);
};

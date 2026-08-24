// Proven RF receiver-line capture from the discovery recognizer. The ISR
// waits for each LOW pulse to finish and rejects the receiver's measured
// 7-70 us idle glitches before they can enter the capture buffer.
#include "RemoteControl.h"

#include <cstring>

#include <esp_log.h>
#include <esp_timer.h>

namespace {
constexpr char TAG[] = "RemoteControl";
}

const RemoteControl::Fingerprint RemoteControl::FINGERPRINTS[9] = {
  {REMOTE_POWER,     "LSSLLSSSSSSLSSLSSLSSSLSSLSLSLSLSSLSLSLSL"},
  {REMOTE_FORWARD,   "LSSLLSSSSSSLSSLSSLSSSLSSLLSLSSSSSSLSLLLL"},
  {REMOTE_MIST,      "LSSLLSSSSSSLSSLSSLSSSLSSLLLSLLSSSSSLSSLL"},
  {REMOTE_BREEZE,    "LSSLLSSSSSSLSSLSSLSSSLSSLLSLLSSSSSLSSLLL"},
  {REMOTE_OSCILLATE, "LSSLLSSSSSSLSSLSSLSSSLSSLSLSSLLSSLSLLSSL"},
  {REMOTE_FAN_MINUS, "LSSLLSSSSSSLSSLSSLSSSLSSLSLLSLSLSLSSLSLS"},
  {REMOTE_FAN_PLUS,  "LSSLLSSSSSSLSSLSSLSSSLSSLSSLSLLLSLLSLSSS"},
  {REMOTE_CW_JOG,    "LSSLLSSSSSSLSSLSSLSSSLSSLLLSSSLLSSSLLLSS"},
  {REMOTE_CCW_JOG,   "LSSLLSSSSSSLSSLSSLSSSLSSLLSSLSLLSSLLSLSS"}
};

RemoteControl::RemoteControl(uint8_t rfPin, uint8_t wakePin)
  : _rfPin(static_cast<gpio_num_t>(rfPin)),
    _wakePin(static_cast<gpio_num_t>(wakePin)) {}

void RemoteControl::begin() {
  gpio_config_t input = {};
  input.pin_bit_mask =
    (1ULL << static_cast<uint32_t>(_rfPin)) |
    (1ULL << static_cast<uint32_t>(_wakePin));
  input.mode = GPIO_MODE_INPUT;
  input.pull_up_en = GPIO_PULLUP_DISABLE;
  input.pull_down_en = GPIO_PULLDOWN_DISABLE;
  input.intr_type = GPIO_INTR_DISABLE;
  esp_err_t result = gpio_config(&input);
  resetCapture();

  if (result == ESP_OK) result = gpio_set_intr_type(_rfPin, GPIO_INTR_ANYEDGE);
  if (result == ESP_OK) {
    result = gpio_isr_handler_add(_rfPin, handleRfEdge, this);
  }
  if (result != ESP_OK) {
    ESP_LOGE(TAG, "RF interrupt setup failed: %s", esp_err_to_name(result));
    return;
  }

  ESP_LOGI(
    TAG,
    "Ready: RF GPIO %u, WAKE GPIO %u; rejecting low pulses under %lu us",
    static_cast<unsigned>(_rfPin),
    static_cast<unsigned>(_wakePin),
    static_cast<unsigned long>(MIN_RF_LOW_PULSE_US)
  );
}

RemoteCommand RemoteControl::update() {
  portENTER_CRITICAL(&_captureLock);
  const bool active = _captureActive;
  const bool full = _bufferFull;
  const uint64_t lastEdgeUs = _lastEdgeUs;
  const uint64_t firstEdgeUs = _firstEdgeUs;
  portEXIT_CRITICAL(&_captureLock);
  if (!active) {
    return REMOTE_NONE;
  }

  const uint64_t now = static_cast<uint64_t>(esp_timer_get_time());
  if (
    !full &&
    now - lastEdgeUs < PACKET_QUIET_US &&
    now - firstEdgeUs < MAX_CAPTURE_US
  ) {
    return REMOTE_NONE;
  }

  return finishCapture();
}

void IRAM_ATTR RemoteControl::handleRfEdge(void *context) {
  static_cast<RemoteControl *>(context)->captureRfEdge();
}

void IRAM_ATTR RemoteControl::captureRfEdge() {
  const uint64_t now = static_cast<uint64_t>(esp_timer_get_time());
  const uint8_t level = gpio_get_level(_rfPin) != 0 ? 1 : 0;

  portENTER_CRITICAL_ISR(&_captureLock);

  if (level == 0) {
    _rfLowStartUs = now;
    _rfLowActive = true;
    portEXIT_CRITICAL_ISR(&_captureLock);
    return;
  }

  if (!_rfLowActive) {
    portEXIT_CRITICAL_ISR(&_captureLock);
    return;
  }

  const uint64_t lowStart = _rfLowStartUs;
  const uint64_t lowDuration = now - lowStart;
  _rfLowActive = false;

  if (lowDuration < MIN_RF_LOW_PULSE_US) {
    portEXIT_CRITICAL_ISR(&_captureLock);
    return;
  }

  // Preserve the discovery sketch's accepted event stream while storing its
  // already-computed width only once instead of two redundant edge records.
  recordPulse(static_cast<uint32_t>(lowDuration), lowStart, now);
  portEXIT_CRITICAL_ISR(&_captureLock);
}

void IRAM_ATTR RemoteControl::recordPulse(
  uint32_t widthUs,
  uint64_t lowStartUs,
  uint64_t lowEndUs
) {
  const size_t index = _pulseCount;

  if (!_captureActive) {
    _captureActive = true;
    _firstEdgeUs = lowStartUs;
  }
  _lastEdgeUs = lowEndUs;

  if (index >= MAX_PULSES) {
    _bufferFull = true;
    return;
  }

  _lowPulseWidthsUs[index] = widthUs;
  _pulseCount = index + 1;
}

void RemoteControl::resetCapture() {
  portENTER_CRITICAL(&_captureLock);
  _pulseCount = 0;
  _firstEdgeUs = 0;
  _lastEdgeUs = 0;
  _rfLowStartUs = 0;
  _captureActive = false;
  _bufferFull = false;
  _rfLowActive = false;
  portEXIT_CRITICAL(&_captureLock);
}

RemoteCommand RemoteControl::finishCapture() {
  const esp_err_t disableResult = gpio_intr_disable(_rfPin);
  if (disableResult != ESP_OK) {
    ESP_LOGE(TAG, "RF interrupt disable failed: %s", esp_err_to_name(disableResult));
    resetCapture();
    return REMOTE_NONE;
  }
  portENTER_CRITICAL(&_captureLock);
  portEXIT_CRITICAL(&_captureLock);

  RemoteCommand command = REMOTE_NONE;
  if (!_bufferFull && _pulseCount >= 2) {
    char symbols[FINGERPRINT_SYMBOL_COUNT + 1] = {0};
    command = recognizeFingerprint(symbols, sizeof(symbols));
  }

  resetCapture();
  const esp_err_t enableResult = gpio_intr_enable(_rfPin);
  if (enableResult != ESP_OK) {
    ESP_LOGE(TAG, "RF interrupt re-enable failed: %s", esp_err_to_name(enableResult));
    return REMOTE_NONE;
  }

  return command;
}

RemoteCommand RemoteControl::recognizeFingerprint(
  char *symbols,
  size_t capacity
) const {
  if (capacity < FINGERPRINT_SYMBOL_COUNT + 1) {
    return REMOTE_NONE;
  }

  // A press repeats its fingerprint. Accept any exact frame between two
  // consecutive synchronization pulses, just as rf_input_capture.ino does.
  int previousSync = -1;

  for (size_t index = 0; index < _pulseCount; ++index) {
    const uint32_t widthUs = _lowPulseWidthsUs[index];

    if (widthUs < SYNC_PULSE_THRESHOLD_US) {
      continue;
    }

    const int currentSync = static_cast<int>(index);

    if (previousSync >= 0) {
      size_t symbolCount = 0;
      bool valid = true;

      for (int pulse = previousSync + 1;
           pulse < currentSync;
           ++pulse) {
        if (symbolCount >= FINGERPRINT_SYMBOL_COUNT) {
          valid = false;
          break;
        }

        const uint32_t pulseWidthUs = _lowPulseWidthsUs[pulse];
        symbols[symbolCount++] =
          pulseWidthUs >= LONG_PULSE_THRESHOLD_US ? 'L' : 'S';
      }

      if (valid && symbolCount == FINGERPRINT_SYMBOL_COUNT) {
        symbols[symbolCount] = '\0';

        for (const Fingerprint &fingerprint : FINGERPRINTS) {
          if (strcmp(symbols, fingerprint.symbols) == 0) {
            return fingerprint.command;
          }
        }
      }
    }

    previousSync = currentSync;
  }

  return REMOTE_NONE;
}

const char *RemoteControl::commandName(RemoteCommand command) {
  switch (command) {
    case REMOTE_POWER: return "POWER";
    case REMOTE_FORWARD: return "FORWARD";
    case REMOTE_MIST: return "MIST";
    case REMOTE_BREEZE: return "BREEZE";
    case REMOTE_OSCILLATE: return "OSCILLATE";
    case REMOTE_FAN_MINUS: return "FAN_MINUS";
    case REMOTE_FAN_PLUS: return "FAN_PLUS";
    case REMOTE_CW_JOG: return "CW_JOG";
    case REMOTE_CCW_JOG: return "CCW_JOG";
    case REMOTE_NONE:
    default: return "NONE";
  }
}

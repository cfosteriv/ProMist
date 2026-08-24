// Fan PWM output and tachometer qualification. Requested speed and observed
// motion remain separate so a commanded motor is never mistaken for a healthy one.
#include "FanMotor.h"

#include <algorithm>

#include <esp_log.h>

#include "DeviceClock.h"

constexpr float FanMotor::MIN_EXPECTED_HZ[6];
constexpr float FanMotor::MAX_SAFE_HZ;

namespace {
constexpr char TAG[] = "FanMotor";
}

FanMotor::FanMotor(uint8_t pwmPin, uint8_t feedbackPin)
  : _pwmPin(static_cast<gpio_num_t>(pwmPin)),
    _feedbackPin(static_cast<gpio_num_t>(feedbackPin)) {}

void FanMotor::begin() {
  const bool outputConfigured = configureOutput();
  const bool safeOff = outputConfigured && writeDuty(0);
  const bool feedbackConfigured = configureFeedback();

  _previousFeedbackMillis = DeviceClock::milliseconds();
  _appliedPower = false;
  _appliedLevel = 0;

  if (outputConfigured && safeOff && feedbackConfigured) {
    ESP_LOGI(
      TAG,
      "Ready: PWM GPIO %u, FG GPIO %u",
      static_cast<unsigned>(_pwmPin),
      static_cast<unsigned>(_feedbackPin)
    );
  } else {
    ESP_LOGE(TAG, "Unavailable; output remains disabled pending safe retry");
  }
}

void FanMotor::update(bool powered, uint8_t fanLevel, uint8_t dutyPercent) {
  fanLevel = std::clamp<uint8_t>(fanLevel, 1, 5);
  dutyPercent = std::min<uint8_t>(dutyPercent, 100);

  if (
    powered != _appliedPower ||
    fanLevel != _appliedLevel ||
    dutyPercent != _appliedDutyPercent ||
    (powered && (!_outputReady || !_feedbackReady))
  ) {
    applyOutput(powered, fanLevel, dutyPercent);
  }

  reportFeedback();
}

SystemStatus FanMotor::status() const {
  return _status;
}

bool FanMotor::speedConfirmed() const {
  return _speedConfirmed;
}

void FanMotor::applyOutput(
  bool powered,
  uint8_t fanLevel,
  uint8_t dutyPercent
) {
  _appliedPower = powered;
  _appliedLevel = fanLevel;
  _appliedDutyPercent = dutyPercent;
  _usingDutyOverride = dutyPercent != 0;
  _speedConfirmed = false;
  _goodSamples = 0;

  if (!powered) {
    if (!_outputReady) {
      (void)configureOutput();
    }
    (void)writeDuty(0);
    clearFeedbackFaults();
    ESP_LOGI(TAG, "Off");
    return;
  }

  // Hardware faults are re-qualified at the point of use. A previous failed
  // attach therefore does not permanently poison later power-on attempts.
  if (!_outputReady && !configureOutput()) {
    (void)writeDuty(0);
    return;
  }
  if (!_feedbackReady && !configureFeedback()) {
    (void)writeDuty(0);
    return;
  }

  if (_status == STATUS_FAN_NOT_TURNING || _status == STATUS_FAN_SPEED_HIGH) {
    (void)writeDuty(0);
    return;
  }

  _poweredSinceMillis = DeviceClock::milliseconds();
  _lowSamples = 0;
  _highSamples = 0;
  if (
    _status == STATUS_FAN_SPEED_LOW ||
    _status == STATUS_FAN_SPEED_HIGH
  ) {
    _status = STATUS_OK;
  }

  if (!_usingDutyOverride) {
    dutyPercent = static_cast<uint8_t>(MIN_MOTOR_DUTY_PERCENT +
      (static_cast<uint32_t>(fanLevel - 1) *
       (MAX_MOTOR_DUTY_PERCENT - MIN_MOTOR_DUTY_PERCENT)) / 4U);
  }

  const uint8_t rawDuty = static_cast<uint8_t>(
    (static_cast<uint32_t>(dutyPercent) * 255U) / 100U
  );
  if (!writeDuty(rawDuty)) return;

  ESP_LOGI(
    TAG,
    "Level=%u PWM=%u%% raw=%u/255%s",
    fanLevel,
    dutyPercent,
    rawDuty,
    _usingDutyOverride ? " (breeze override)" : ""
  );
}

bool FanMotor::configureOutput() {
  ledc_timer_config_t timer = {};
  timer.speed_mode = LEDC_HIGH_SPEED_MODE;
  timer.duty_resolution = static_cast<ledc_timer_bit_t>(PWM_RESOLUTION);
  timer.timer_num = LEDC_TIMER_0;
  timer.freq_hz = PWM_FREQUENCY;
  timer.clk_cfg = LEDC_AUTO_CLK;
  esp_err_t result = ledc_timer_config(&timer);

  ledc_channel_config_t channel = {};
  channel.gpio_num = static_cast<int>(_pwmPin);
  channel.speed_mode = LEDC_HIGH_SPEED_MODE;
  channel.channel = LEDC_CHANNEL_0;
  channel.intr_type = LEDC_INTR_DISABLE;
  channel.timer_sel = LEDC_TIMER_0;
  channel.duty = 0;
  channel.hpoint = 0;
  channel.flags.output_invert = 0;
  if (result == ESP_OK) result = ledc_channel_config(&channel);
  _outputReady = result == ESP_OK;

  if (!_outputReady) {
    _status = STATUS_HARDWARE_NO_START;
    ESP_LOGE(TAG, "PWM configuration failed: %s", esp_err_to_name(result));
    return false;
  }

  if (_feedbackReady && _status == STATUS_HARDWARE_NO_START) {
    _status = STATUS_OK;
    ESP_LOGI(TAG, "Fan hardware recovered");
  }

  return true;
}

bool FanMotor::configureFeedback() {
  gpio_config_t input = {};
  input.pin_bit_mask = 1ULL << static_cast<uint32_t>(_feedbackPin);
  input.mode = GPIO_MODE_INPUT;
  input.pull_up_en = GPIO_PULLUP_ENABLE;
  input.pull_down_en = GPIO_PULLDOWN_DISABLE;
  input.intr_type = GPIO_INTR_NEGEDGE;
  const esp_err_t gpioResult = gpio_config(&input);
  const esp_err_t isrResult = gpioResult == ESP_OK
    ? gpio_isr_handler_add(_feedbackPin, handleFeedbackInterrupt, this)
    : gpioResult;
  _feedbackReady = isrResult == ESP_OK;
  if (!_feedbackReady) {
    _status = STATUS_HARDWARE_NO_START;
    ESP_LOGE(TAG, "Tach interrupt setup failed: %s", esp_err_to_name(isrResult));
    return false;
  }

  if (_outputReady && _status == STATUS_HARDWARE_NO_START) {
    _status = STATUS_OK;
    ESP_LOGI(TAG, "Fan hardware recovered");
  }
  return true;
}

bool FanMotor::writeDuty(uint8_t duty) {
  if (!_outputReady) return false;
  esp_err_t result = ledc_set_duty(LEDC_HIGH_SPEED_MODE, LEDC_CHANNEL_0, duty);
  if (result == ESP_OK) {
    result = ledc_update_duty(LEDC_HIGH_SPEED_MODE, LEDC_CHANNEL_0);
  }
  if (result != ESP_OK) {
    ESP_LOGE(TAG, "PWM duty update failed: %s", esp_err_to_name(result));
    const esp_err_t stopResult = ledc_stop(
      LEDC_HIGH_SPEED_MODE,
      LEDC_CHANNEL_0,
      0
    );
    if (stopResult != ESP_OK) {
      ESP_LOGE(
        TAG,
        "PWM emergency stop failed: %s",
        esp_err_to_name(stopResult)
      );
    }
    _outputReady = false;
    _status = STATUS_HARDWARE_NO_START;
  }
  return result == ESP_OK;
}

void IRAM_ATTR FanMotor::handleFeedbackInterrupt(void *context) {
  auto *motor = static_cast<FanMotor *>(context);
  portENTER_CRITICAL_ISR(&motor->_feedbackLock);
  motor->_feedbackPulses++;
  portEXIT_CRITICAL_ISR(&motor->_feedbackLock);
}

void FanMotor::reportFeedback() {
  if (!_outputReady || !_feedbackReady) {
    return;
  }

  const uint64_t now = DeviceClock::milliseconds();

  if (now - _previousFeedbackMillis < FEEDBACK_REPORT_INTERVAL_MS) {
    return;
  }

  const uint64_t elapsedMillis = now - _previousFeedbackMillis;
  _previousFeedbackMillis = now;

  portENTER_CRITICAL(&_feedbackLock);
  const uint32_t pulses = _feedbackPulses;
  _feedbackPulses = 0;
  portEXIT_CRITICAL(&_feedbackLock);

  const float frequencyHz = elapsedMillis > 0
    ? pulses * 1000.0f / elapsedMillis
    : 0.0f;

  if (_appliedPower) {
    ESP_LOGD(
      TAG,
      "FG: %lu pulses, %.1f Hz",
      static_cast<unsigned long>(pulses),
      frequencyHz
    );

    if (now - _poweredSinceMillis < SPIN_UP_GRACE_MS) {
      return;
    }

    const uint8_t index = _usingDutyOverride
      ? std::clamp(
          static_cast<int>(_appliedDutyPercent) -
            MIN_MOTOR_DUTY_PERCENT + 7,
          0,
          5 * 15
        ) / 15
      : std::clamp<uint8_t>(_appliedLevel, 1, 5) - 1;

    if (pulses == 0) {
      _speedConfirmed = false;
      _goodSamples = 0;
      if (++_lowSamples >= BAD_SAMPLE_LIMIT) {
        _status = STATUS_FAN_NOT_TURNING;
        (void)writeDuty(0);
        ESP_LOGE(TAG, "Fan not turning; output disabled until power off");
      }
      return;
    }

    if (frequencyHz < MIN_EXPECTED_HZ[index]) {
      _speedConfirmed = false;
      _goodSamples = 0;
      _lowSamples++;
      _highSamples = 0;
      if (_lowSamples >= BAD_SAMPLE_LIMIT) {
        _status = STATUS_FAN_SPEED_LOW;
      }
    } else if (frequencyHz > MAX_SAFE_HZ) {
      _speedConfirmed = false;
      _goodSamples = 0;
      _highSamples++;
      const bool shutdown = _overspeedPolicy.observe(frequencyHz);
      _lowSamples = 0;
      if (shutdown) {
        _status = STATUS_FAN_SPEED_HIGH;
        (void)writeDuty(0);
        const uint8_t configuredDuty = _usingDutyOverride
          ? _appliedDutyPercent
          : static_cast<uint8_t>(MIN_MOTOR_DUTY_PERCENT +
              (static_cast<uint32_t>(_appliedLevel - 1) *
               (MAX_MOTOR_DUTY_PERCENT - MIN_MOTOR_DUTY_PERCENT)) / 4U);
        ESP_LOGE(
          TAG,
          "Sustained overspeed; output disabled until power cycle; observed=%.1f Hz ceiling=%.1f Hz call=%u%%",
          frequencyHz,
          MAX_SAFE_HZ,
          static_cast<unsigned>(configuredDuty)
        );
      }
    } else {
      _overspeedPolicy.observe(frequencyHz);
      clearFeedbackFaults();
      if (_goodSamples < GOOD_SAMPLE_LIMIT) {
        _goodSamples++;
      }
      _speedConfirmed = _goodSamples >= GOOD_SAMPLE_LIMIT;
    }
  }
}

void FanMotor::clearFeedbackFaults() {
  _lowSamples = 0;
  _highSamples = 0;
  _overspeedPolicy.reset();
  if (_status != STATUS_HARDWARE_NO_START) {
    _status = STATUS_OK;
  }
}

#!/bin/sh
# Sanitizer flags are an intentional whitespace-separated compiler option list.
# shellcheck disable=SC2086
set -eu

CXX="${CXX:-c++}"
OUTPUT_DIR="${PROMIST_TEST_OUTPUT_DIR:-/tmp/promist-tests}"
SANITIZER_FLAGS="${PROMIST_SANITIZER_FLAGS:-}"
mkdir -p "$OUTPUT_DIR"

COMMON_FLAGS="-std=c++17 -Wall -Wextra -Wpedantic -Wconversion -Wsign-conversion -Werror"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main \
  tests/system_status_test.cpp -o "$OUTPUT_DIR/system-status-test"
"$OUTPUT_DIR/system-status-test"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main \
  tests/panel_display_policy_test.cpp -o "$OUTPUT_DIR/panel-display-policy-test"
"$OUTPUT_DIR/panel-display-policy-test"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main \
  tests/breeze_profiles_test.cpp ProMistIDF/main/BreezeProfiles.cpp \
  -o "$OUTPUT_DIR/breeze-profiles-test"
"$OUTPUT_DIR/breeze-profiles-test"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main \
  tests/device_controller_test.cpp ProMistIDF/main/DeviceController.cpp \
  -o "$OUTPUT_DIR/device-controller-test"
"$OUTPUT_DIR/device-controller-test"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main \
  tests/ble_session_ownership_test.cpp ProMistIDF/main/DeviceController.cpp \
  -o "$OUTPUT_DIR/ble-session-ownership-test"
"$OUTPUT_DIR/ble-session-ownership-test"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main tests/matter_fan_adapter_test.cpp \
  ProMistIDF/main/DeviceController.cpp ProMistIDF/main/MatterFanAdapter.cpp \
  -o "$OUTPUT_DIR/matter-fan-adapter-test"
"$OUTPUT_DIR/matter-fan-adapter-test"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main \
  tests/diagnostic_log_test.cpp \
  ProMistIDF/main/DiagnosticEvents.cpp ProMistIDF/main/DiagnosticLog.cpp \
  -o "$OUTPUT_DIR/diagnostic-log-test"
"$OUTPUT_DIR/diagnostic-log-test"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main \
  tests/ble_protocol_test.cpp ProMistIDF/main/BleProtocol.cpp \
  -o "$OUTPUT_DIR/ble-protocol-test"
"$OUTPUT_DIR/ble-protocol-test"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main tests/safety_policy_test.cpp \
  -o "$OUTPUT_DIR/safety-policy-test"
"$OUTPUT_DIR/safety-policy-test"

"$CXX" $COMMON_FLAGS $SANITIZER_FLAGS \
  -IProMistIDF/main tests/ota_update_policy_test.cpp \
  -o "$OUTPUT_DIR/ota-update-policy-test"
"$OUTPUT_DIR/ota-update-policy-test"

echo "Host tests passed"

set(PROMIST_SOURCES
  AP1651.cpp
  BleManager.cpp
  BleProtocol.cpp
  BleSecurity.cpp
  BreezeProfiles.cpp
  CustomBreezeStore.cpp
  DeviceController.cpp
  DiagnosticEvents.cpp
  DiagnosticLog.cpp
  EspMatterFanEndpoint.cpp
  FanMotor.cpp
  FaultHistoryStore.cpp
  MatterFanAdapter.cpp
  MisterPump.cpp
  NvsNamespace.cpp
  OscillationController.cpp
  RemoteControl.cpp
  UserInterface.cpp
  main.cpp)
idf_component_register(
  SRCS ${PROMIST_SOURCES}
  INCLUDE_DIRS "."
  PRIV_REQUIRES
    bt
    esp_driver_gpio
    esp_driver_ledc
    esp_system
    esp_timer
    espressif__esp_matter
    freertos
    mbedtls
    nvs_flash)

# Keep project-owned firmware sources on the requested language baseline even
# though the pinned Matter dependency currently selects a newer dialect for
# its own generated/runtime sources.
target_compile_options(${COMPONENT_LIB} PRIVATE -std=gnu++17)

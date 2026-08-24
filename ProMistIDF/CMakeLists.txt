cmake_minimum_required(VERSION 3.16)

# Matter Basic Information identity. The serial number is installed at runtime
# from the ESP32's unique hardware ID before the Matter server starts.
add_compile_definitions(
  CHIP_DEVICE_CONFIG_DEVICE_VENDOR_NAME="Charles Foster"
  CHIP_DEVICE_CONFIG_DEVICE_PRODUCT_NAME="ProMist"
  CHIP_DEVICE_CONFIG_DEVICE_SOFTWARE_VERSION_STRING="1.0"
)

include($ENV{IDF_PATH}/tools/cmake/project.cmake)
project(promist_matter)

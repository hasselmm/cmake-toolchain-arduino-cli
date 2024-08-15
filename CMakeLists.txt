cmake_minimum_required(VERSION 3.19)
project(arduino-cli-toolchain VERSION 0.1 LANGUAGES)
enable_testing()

add_custom_target(
    toolchain SOURCES
    toolchain/arduino-cli-toolchain.cmake
    toolchain/Arduino/RulesOverride.cmake
    .github/workflows/IntegrationTests.yml
    .github/workflows/Test-ATTinyCore.yml
    .github/workflows/Test-ArduinoAVR.yml
    .github/workflows/Test-ArduinoSAMD.yml
    .github/workflows/Test-ESP32.yml
    .github/workflows/Test-ESP8266.yml
    .github/workflows/Test-STM32.yml
    .github/FUNDING.yml
    README.md
    LICENSE
)

add_subdirectory(tests)

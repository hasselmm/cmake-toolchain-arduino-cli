cmake_minimum_required(VERSION 3.19)
project(arduino-cli-toolchain VERSION 0.1 LANGUAGES)
enable_testing()

add_custom_target(
    toolchain SOURCES
    toolchain/Arduino/CollectLibraries.cmake
    toolchain/Arduino/Preprocess.cmake
    toolchain/Arduino/RulesOverride.cmake
    toolchain/arduino-cli-toolchain.cmake
)

add_custom_target(
    tools SOURCES
    tests/platforms.cmake
    tools/check-platform-support.cmake
)

add_custom_target(
    github SOURCES
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

cmake_minimum_required(VERSION 3.19)
project(arduino-cli-toolchain VERSION 0.1 LANGUAGES)
enable_testing()

add_custom_target(
    toolchain SOURCES
    toolchain/Arduino/RulesOverride.cmake
    toolchain/Arduino/ScriptMode.cmake
    toolchain/Platform/Arduino.cmake
    toolchain/Scripts/Preprocess.cmake
    toolchain/Templates/ArduinoLibraryCMakeLists.txt.in
    toolchain/Templates/PreprocessConfig.cmake.in
    toolchain/arduino-cli-toolchain.cmake)

add_custom_target(
    tools SOURCES
    tests/platforms.cmake
    tools/check-platform-support.cmake
)

add_custom_target(
    github SOURCES
    .github/workflows/badge-arduino-avr.yml
    .github/workflows/badge-arduino-samd.yml
    .github/workflows/badge-attinycore.yml
    .github/workflows/badge-esp32.yml
    .github/workflows/badge-esp8266.yml
    .github/workflows/badge-stm32.yml
    .github/workflows/run-testsuite.yml
    .github/workflows/main.yml
    .github/FUNDING.yml
    README.md
    LICENSE
)

add_subdirectory(tests)

cmake_minimum_required(VERSION 3.19)
project(arduino-cli-toolchain VERSION 0.1 LANGUAGES)
enable_testing()

add_custom_target(
    toolchain SOURCES
    toolchain/arduino-cli-toolchain.cmake
    toolchain/Arduino/RulesOverride.cmake
    .github/workflows/IntegrationTests.yaml
    .github/FUNDING.yml
    README.md
    LICENSE
)

add_subdirectory(tests)

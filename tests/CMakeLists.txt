if (NOT ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS)
    set(ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS
        ATTinyCore:avr:attiny1634
        ATTinyCore:avr:attiny43
        ATTinyCore:avr:attiny828
        ATTinyCore:avr:attinyx313
        ATTinyCore:avr:attinyx4
        ATTinyCore:avr:attinyx41
        ATTinyCore:avr:attinyx5
        ATTinyCore:avr:attinyx7
        ATTinyCore:avr:attinyx8
        STMicroelectronics:stm32:Nucleo_64:pnum=NUCLEO_F103RB
        arduino:avr:nano
        arduino:samd:nano_33_iot
        esp32:esp32:nodemcu-32s
        esp8266:esp8266:nodemcuv2)
endif()

function(arduino_cli_toolchain_add_test NAME)
    add_custom_target("${NAME}" SOURCES "${NAME}/CMakeLists.txt")

    foreach(_board_name IN LISTS ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS)
        string(REPLACE ":" ";" _board_name_components "${_board_name}")
        list(GET _board_name_components 2 _board_id)

        set(_test_name "${_board_id}/${NAME}")
        set(_workdir "${CMAKE_BINARY_DIR}/${_test_name}")

        file(REMOVE_RECURSE "${_workdir}")
        file(MAKE_DIRECTORY "${_workdir}")

        add_test( # <---------------------------------------------------------- try an initial configuration of the test
            NAME "${_test_name}/configure"
            WORKING_DIRECTORY "${_workdir}"

            COMMAND "${CMAKE_COMMAND}"
                --toolchain "${CMAKE_SOURCE_DIR}/toolchain/arduino-cli-toolchain.cmake"
                -S "${CMAKE_CURRENT_SOURCE_DIR}/${NAME}" -G "${CMAKE_GENERATOR}"
                -D "ARDUINO_BOARD:STRING=${_board_name}"
                -D "CMAKE_MESSAGE_LOG_LEVEL=Trace")

        set_tests_properties(
            "${_test_name}/configure" PROPERTIES
            FIXTURES_SETUP "${_board_id}/configure"
            LABELS "${_board_name}")

        add_test( # <-------------------------------------------------------- verify that CMake can be run a second time
            NAME "${_test_name}/reconfigure"
            WORKING_DIRECTORY "${_workdir}"
            COMMAND "${CMAKE_COMMAND}" -S "${CMAKE_CURRENT_SOURCE_DIR}/${NAME}")

        set_tests_properties(
            "${_test_name}/reconfigure" PROPERTIES
            FIXTURES_REQUIRED "${_board_id}/configure"
            FIXTURES_SETUP "${_board_id}/reconfigure"
            LABELS "${_board_name}")

        add_test( # <-------------------------------------------------------------- finally build the Sketch using CMake
            NAME "${_test_name}/build"
            WORKING_DIRECTORY "${_workdir}"
            COMMAND "${CMAKE_COMMAND}" --build ".")

        set_tests_properties(
            "${_test_name}/build" PROPERTIES
            FIXTURES_REQUIRED "${_board_id}/reconfigure"
            LABELS "${_board_name}")
    endforeach()
endfunction()

arduino_cli_toolchain_add_test(CMakeBlink)

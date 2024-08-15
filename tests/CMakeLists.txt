if (NOT ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS)
    set(ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS
        arduino:avr:nano
        #arduino:samd:nano_33_iot
        esp32:esp32:nodemcu-32s
        esp8266:esp8266:nodemcuv2:baud=512000)
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

        add_test( # <----------------------------------------------------------------------------- define the test steps
            NAME "${_test_name}/configure"
            WORKING_DIRECTORY "${_workdir}"

            COMMAND "${CMAKE_COMMAND}"
                --toolchain "${CMAKE_SOURCE_DIR}/toolchain/arduino-cli-toolchain.cmake"
                -S "${CMAKE_CURRENT_SOURCE_DIR}/${NAME}" -G "${CMAKE_GENERATOR}"
                -D "ARDUINO_BOARD:STRING=${_board_name}"
                -D "CMAKE_MESSAGE_LOG_LEVEL=Trace")

        add_test(
            NAME "${_test_name}/reconfigure"
            WORKING_DIRECTORY "${_workdir}"
            COMMAND "${CMAKE_COMMAND}" -S "${CMAKE_CURRENT_SOURCE_DIR}/${NAME}")

        add_test(
            NAME "${_test_name}/build"
            WORKING_DIRECTORY "${_workdir}"
            COMMAND "${CMAKE_COMMAND}" --build ".")

        set_property( # <---------------------------------------------------------------- define dependencies and labels
            TEST "${_test_name}/configure"
            PROPERTY LABELS "${_board_name}")

        set_property(
            TEST "${_test_name}/reconfigure"
            PROPERTY LABELS "${_board_name}")
        set_property(
            TEST "${_test_name}/reconfigure"
            PROPERTY DEPENDS "${_test_name}/configure")

        set_property(
            TEST "${_test_name}/build"
            PROPERTY LABELS "${_board_name}")
        set_property(
            TEST "${_test_name}/build"
            PROPERTY DEPENDS "${_test_name}/reconfigure")
    endforeach()
endfunction()

arduino_cli_toolchain_add_test(CMakeBlink)

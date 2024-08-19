include(platforms.cmake)

cmake_host_system_information(RESULT _logical_cores QUERY NUMBER_OF_LOGICAL_CORES)
set(CTEST_RESOURCE_SPEC_FILE "${CMAKE_BINARY_DIR}/CTestResources.json")
configure_file(CTestResources.json.in "${CTEST_RESOURCE_SPEC_FILE}")

function(arduino_cli_toolchain_add_test NAME)
    cmake_parse_arguments(_TEST "" "" "SKIP" ${ARGN})

    add_custom_target("${NAME}" SOURCES "${NAME}/CMakeLists.txt" "${NAME}/${NAME}.ino")

    foreach(_board_name IN LISTS ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS)
        string(REPLACE ":" ";" _board_name_components "${_board_name}")
        list(GET _board_name_components 2 _board_id)

        if (_board_id IN_LIST _TEST_SKIP) # <------------------------------ skip boards that are known to fail this test
            set(_test_disabled YES)
        else()
            set(_test_disabled NO)
        endif()

        set(_test_name "${_board_id}/${NAME}")
        set(_workdir "${CMAKE_BINARY_DIR}/${_test_name}")

        file(REMOVE_RECURSE "${_workdir}")
        file(MAKE_DIRECTORY "${_workdir}")

        add_test( # <---------------------------------------------------------- try an initial configuration of the test
            NAME "${_test_name}/configure"
            WORKING_DIRECTORY "${_workdir}"

            COMMAND "${CMAKE_COMMAND}"
                --profiling-format=google-trace
                --profiling-output=configure-trace.json
                --toolchain "${CMAKE_SOURCE_DIR}/toolchain/arduino-cli-toolchain.cmake"
                -S "${CMAKE_CURRENT_SOURCE_DIR}/${NAME}" -G "${CMAKE_GENERATOR}"
                -D "ARDUINO_BOARD:STRING=${_board_name}"
                -D "CMAKE_MESSAGE_LOG_LEVEL=Trace")

        set_tests_properties(
            "${_test_name}/configure" PROPERTIES
            FIXTURES_SETUP "${_test_name}/configure"
            RESOURCE_GROUPS "cpu-cores:1"
            DISABLED "${_test_disabled}"
            LABELS "${_board_name}")

        add_test( # <-------------------------------------------------------- verify that CMake can be run a second time
            NAME "${_test_name}/reconfigure"
            WORKING_DIRECTORY "${_workdir}"

            COMMAND "${CMAKE_COMMAND}"
                --profiling-format=google-trace
                --profiling-output=reconfigure-trace.json
                -S "${CMAKE_CURRENT_SOURCE_DIR}/${NAME}")

        set_tests_properties(
            "${_test_name}/reconfigure" PROPERTIES
            FIXTURES_REQUIRED "${_test_name}/configure"
            FIXTURES_SETUP "${_test_name}/reconfigure"
            RESOURCE_GROUPS "cpu-cores:1"
            DISABLED "${_test_disabled}"
            LABELS "${_board_name}")

        add_test( # <-------------------------------------------------------------- finally build the Sketch using CMake
            NAME "${_test_name}/build"
            WORKING_DIRECTORY "${_workdir}"
            COMMAND "${CMAKE_COMMAND}" --build ".")

        set_tests_properties(
            "${_test_name}/build" PROPERTIES
            FIXTURES_REQUIRED "${_test_name}/reconfigure"
            RESOURCE_GROUPS "cpu-cores:${_logical_cores}"
            DISABLED "${_test_disabled}"
            LABELS "${_board_name}")
    endforeach()
endfunction()

arduino_cli_toolchain_add_test(CMakeBlink)

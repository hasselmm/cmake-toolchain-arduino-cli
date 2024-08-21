cmake_minimum_required(VERSION 3.18)
cmake_policy(SET CMP0057 NEW)

if (NOT CMAKE_SCRIPT_MODE_FILE)
    message(FATAL_ERROR "${CMAKE_CURRENT_LIST_FILE} must be run in script mode.")
    return()
endif()

# ----------------------------------------------------------------------------------------------------------------------
# Verifies that all required variables are defined for running the current CMake script
# ----------------------------------------------------------------------------------------------------------------------
function(arduino_script_require) # [ARGUMENT_NAME...]
    message(TRACE "Validating parameters for ${CMAKE_SCRIPT_MODE_FILE}")

    cmake_parse_arguments(REQUIRE "" "" "OPTIONAL" ${ARGV})

    foreach(_parameter IN LISTS REQUIRE_UNPARSED_ARGUMENTS REQUIRE_OPTIONAL)
        if (NOT DEFINED "${_parameter}")
            message(FATAL_ERROR "The required parameter ${_parameter} is missing.")
        elseif (NOT ${_parameter} AND NOT "${_parameter}" IN_LIST REQUIRE_OPTIONAL)
            message(FATAL_ERROR "The required parameter ${_parameter} is empty")
        endif()

        message(TRACE "  ${_parameter}: ${${_parameter}}")
    endforeach()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Some generally useful variables
# ----------------------------------------------------------------------------------------------------------------------
string(ASCII  35 _hash)

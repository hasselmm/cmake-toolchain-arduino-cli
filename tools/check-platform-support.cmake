cmake_minimum_required(VERSION 3.18)

if (NOT CMAKE_SCRIPT_MODE_FILE)
    message(FATAL_ERROR "${CMAKE_CURRENT_LIST_FILE} must be run in script mode.")
    return()
endif()

# ----------------------------------------------------------------------------------------------------------------------
# Runs `FUNCTION` for each installed libray reported by `arduino-cli`.
# ----------------------------------------------------------------------------------------------------------------------
function(foreach_library FUNCTION)
    foreach(_board IN LISTS ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS)
        message(STATUS "Checking ${_board}")

        execute_process(
            COMMAND arduino-cli lib list --fqbn "${_board}" --format json
            ENCODING UTF-8 OUTPUT_VARIABLE _json)

        string(JSON _count LENGTH "${_json}" installed_libraries)
        math(EXPR _last "${_count} - 1")

        foreach(_index RANGE ${_last})
            string(JSON _library GET "${_json}" installed_libraries ${_index} library)
            cmake_language(CALL "${FUNCTION}" "${_library}")
        endforeach()
    endforeach()

    foreach(_variable IN LISTS ARGN)
        set("${_variable}" "${${_variable}}" PARENT_SCOPE)
    endforeach()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Prints the supported and the unsupported boards.
# ----------------------------------------------------------------------------------------------------------------------
function(show_supported_boards)
    set(_show_supported_boards ${ARGN})
    set(_unsupported_boards ${ARDUINO_CLI_TOOLCHAIN_TESTED_BOARDS})
    list(REMOVE_ITEM _unsupported_boards ${_supported_boards})

    list(JOIN _supported_boards ", " _supported_boards)
    list(JOIN _unsupported_boards ", " _unsupported_boards)

    message(STATUS "Supported boards: ${_supported_boards}")
    message(STATUS "Unsupported boards: ${_unsupported_boards}")
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Filter that searches for libraries having examples that match `LIBRARY` and `EXAMPLE`.
# ----------------------------------------------------------------------------------------------------------------------
function(check_example _library)
    string(JSON _name GET "${_library}" name)
    string(JSON _examples ERROR_VARIABLE _error GET "${_library}" examples)

    if (NOT _examples)
        return()
    endif()

    if (LIBRARY AND NOT _name MATCHES "^${LIBRARY}\$")
        return()
    endif()

    if (EXAMPLE MATCHES "^(\\*|list)\$")
        message(STATUS "${_examples}")
        return()
    endif()

    string(JSON _count LENGTH "${_examples}")
    math(EXPR _last "${_count} - 1")

    foreach(_index RANGE ${_last})
        string(JSON _dirpath GET "${_examples}" ${_index})
        cmake_path(GET _dirpath FILENAME _dirname)

        if (_dirname MATCHES "^${EXAMPLE}\$")
            list(APPEND _supported_boards "${_board}")
            break()
        endif()
    endforeach()

    set(_supported_boards ${_supported_boards} PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Filter that searches for libraries with a name matching `LIBRARY`.
# ----------------------------------------------------------------------------------------------------------------------
function(check_library _library)
    string(JSON _name GET "${_library}" name)

    if (_name MATCHES "^${LIBRARY}\$")
        list(APPEND _supported_boards "${_board}")
    endif()

    set(_supported_boards ${_supported_boards} PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# The actual main routine
# ----------------------------------------------------------------------------------------------------------------------
include("${CMAKE_SCRIPT_MODE_FILE}/../../tests/platforms.cmake")

if (EXAMPLE)
    foreach_library(check_example _supported_boards)
    show_supported_boards(${_supported_boards})
elseif (LIBRARY)
    foreach_library(check_library _supported_boards)
    show_supported_boards(${_supported_boards})
else()
    message(FATAL_ERROR "Unsupported mode")
    return()
endif()

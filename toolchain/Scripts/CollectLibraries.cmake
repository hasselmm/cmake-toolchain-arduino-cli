include(Arduino/ScriptMode NO_POLICY_SCOPE)
include("${ARGUMENTS}" OPTIONAL)

arduino_script_require(
    COLLECT_LIBRARIES_CACHE
    COLLECT_LIBRARIES_TARGET
    COLLECT_LIBRARIES_OUTPUT
    COLLECT_LIBRARIES_SOURCES)

# ----------------------------------------------------------------------------------------------------------------------
# Extracts include directives from the files in `SOURCES_LIST` and stores the filename list in `OUTPUT_VARIABLE`.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_collect_required_libraries SOURCES_LIST OUTPUT_VARIABLE)
    unset(_required_includes)

    foreach(_filepath IN LISTS SOURCES_LIST)
        message(STATUS "  Scanning ${_filepath} for include directives")

        # FIXME actually run preprocessor on the file to handle conditional includes (#ifdef/#else)
        file(STRINGS "${_filepath}" _include_directives REGEX "^${_hash}[ /t]*include")

        foreach(_line IN LISTS _include_directives)
            if (_line MATCHES "${_hash}[ /t]*include[ /t]*<([^>]+\\.[Hh])>")
                list(APPEND _required_includes "${CMAKE_MATCH_1}")
            endif()
        endforeach()
    endforeach()

    list(REMOVE_DUPLICATES _required_includes)
    list(REMOVE_ITEM _required_includes "Arduino.h")

    set("${OUTPUT_VARIABLE}" ${_required_includes} PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Filters the known installed libraries by `LOCATION` and reports the result in `OUTPUT_VARIABLE`.
# The result is a list of `(type, name, dirpath)` tuples separated by '|'.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_find_installed_libraries LOCATION OUTPUT_VARIABLE)
    message(VERBOSE "Reading installed libraries from ${COLLECT_LIBRARIES_CACHE}")
    file(READ "${COLLECT_LIBRARIES_CACHE}" _installed_libraries)

    string(JSON _installed_libraries GET "${_installed_libraries}" "installed_libraries")
    string(JSON _count LENGTH "${_installed_libraries}")
    math(EXPR _last "${_count} - 1")

    unset(_library_list)

    foreach(_library_index RANGE ${_last})
        string(JSON _dirpath  GET "${_installed_libraries}" ${_library_index} "library" "source_dir")
        string(JSON _type     GET "${_installed_libraries}" ${_library_index} "library" "location")
        string(JSON _name     GET "${_installed_libraries}" ${_library_index} "library" "name")

        cmake_path(NORMAL_PATH _dirpath)
        list(APPEND _library_list "${_type}|${_name}|${_dirpath}")
    endforeach()

    set("${OUTPUT_VARIABLE}" ${_library_list} PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Splits a `LIBRARY` tuple into its components `(type, name, dirpath)`.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_split_library_tuple LIBRARY TYPE_VARIABLE NAME_VARIABLE DIRPATH_VARIABLE)
    string(REGEX MATCH "^([^|]+)\\|([^|]+)\\|([^|]+)" _ "${_library}")

    set("${TYPE_VARIABLE}"    "${CMAKE_MATCH_1}" PARENT_SCOPE)
    set("${NAME_VARIABLE}"    "${CMAKE_MATCH_2}" PARENT_SCOPE)
    set("${DIRPATH_VARIABLE}" "${CMAKE_MATCH_3}" PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Tries to find the libraries that provide `REQUIRED_INCLUDES`
# and stores the identified library tuples in `OUTPUT_VARIABLE`.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_resolve_libraries REQUIRED_INCLUDES OUTPUT_VARIABLE)
    # FIXME Read LINK_LIBRARIES of COLLECT_LIBRARIES_TARGET

    # Cluster the libraries reported by arduino-cli by location to implement the location priority
    # described by https://arduino.github.io/arduino-cli/1.0/sketch-build-process/#location-priority

    __arduino_find_installed_libraries("user"         _user_librarys)
    __arduino_find_installed_libraries("platform"     _platform_librarys)
    __arduino_find_installed_libraries("ref-platform" _board_librarys)
    __arduino_find_installed_libraries("ide"          _ide_libraries)

    unset(_resolved_includes)
    unset(_required_libraries)
    unset(_unresolved_includes)

    while (REQUIRED_INCLUDES)
        list(POP_FRONT REQUIRED_INCLUDES _next_include)
        message(VERBOSE "  Searching library that provides ${_next_include}")

        unset(_matching_library)

        foreach(_library IN LISTS _user_librarys _platform_librarys _board_librarys _ide_libraries)
            __arduino_split_library_tuple("${_library}" _type _name _dirpath)
            message(TRACE "Checking ${_type} library ${_name} at ${_dirpath}")

            if (EXISTS "${_dirpath}/${_next_include}"
                    AND NOT IS_DIRECTORY "${_dirpath}/${_next_include}")
                set(_matching_library "${_library}")
                break()
            endif()
        endforeach()

        if (_matching_library)
            message(VERBOSE "  Using ${_next_include} from ${_type} library ${_name} at ${_dirpath}")

            list(APPEND _resolved_includes "${_next_include}")
            list(APPEND _required_libraries "${_matching_library}")
        else()
            list(APPEND _unresolved_includes "${_next_include}")
        endif()
    endwhile()

    if (_unresolved_includes)
        list(JOIN _unresolved_includes ", " _unresolved_includes)
        message(WARNING "Could not resolve all required libraries. Unresolved includes: ${_unresolved_includes}")
    endif()

    list(REMOVE_DUPLICATES _required_libraries)
    set("${OUTPUT_VARIABLE}" "${_required_libraries}" PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Generates a CMake file that defines import libraries from `REQUIRED_LIBRARIES` and links `TARGET` with them.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_generate_library_definitions TARGET REQUIRED_LIBRARIES OUTPUT_FILEPATH)
    set(_library_definitions "# Generated by ${CMAKE_SCRIPT_MODE_FILE}")
    unset(_link_libraries)

    foreach(_library IN LISTS REQUIRED_LIBRARIES) # <--------------------- generate __arduino_add_import_library() calls
        __arduino_split_library_tuple("${_library}" _ _name _dirpath)
        string(REPLACE " " "_" _target_name "${_name}")

        if (_target_name MATCHES "[^A-Za-z0-9]_")
            message(FATAL_ERROR "Unexpected character '${CMAKE_MATCH_0}' in library name '${_name}'")
            return()
        endif()

        list(
            APPEND _library_definitions
            ""
            "if (NOT TARGET Arduino::${_target_name})"
            "    __arduino_add_import_library(${_target_name} \"${_dirpath}\")"
            "endif()")

        list(APPEND _link_libraries "Arduino::${_target_name}")
    endforeach()

    if (_link_libraries) # <-------------------------------------------- link `TARGET` with the defined import libraries
        list(APPEND _library_definitions
            ""
            "target_link_libraries(\"${TARGET}\" PUBLIC ${_link_libraries})")
    endif()

    list(JOIN _library_definitions "\n" _library_definitions) # <------------ write the definitions to `OUTPUT_FILEPATH`

    if (EXISTS "${OUTPUT_FILEPATH}")
        file(READ "${OUTPUT_FILEPATH}" _previous_definitions)
    else()
        unset(_previous_definitions)
    endif()

    if (NOT _library_definitions STREQUAL _previous_definitions)
        message(STATUS "Generating ${OUTPUT_FILEPATH}")
        file(WRITE "${OUTPUT_FILEPATH}" "${_library_definitions}")
    endif()
endfunction()

__arduino_collect_required_libraries("${COLLECT_LIBRARIES_SOURCES}" _required_includes)
__arduino_resolve_libraries("${_required_includes}" _required_libraries)

__arduino_generate_library_definitions(
    "${COLLECT_LIBRARIES_TARGET}" "${_required_libraries}"
    "${COLLECT_LIBRARIES_OUTPUT}")

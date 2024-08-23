if (CMAKE_VERSION VERSION_LESS 3.18)
    message(FATAL_ERROR "This toolchain file requires CMake 3.18 at least")
    return()
endif()

# ======================================================================================================================
# The following functions are the public API of the toolchain.
# ======================================================================================================================

# ----------------------------------------------------------------------------------------------------------------------
# Finds the specified Arduino library and defines an interface library for it.
# ----------------------------------------------------------------------------------------------------------------------
function(arduino_find_libraries NAME)
    cmake_parse_arguments(_FIND_LIBRARY "REQUIRED" "VERSION" "" ${ARGN})
    set(_requested_libraries "${NAME}" ${_FIND_LIBRARY_UNPARSED_ARGUMENTS})
    list(REMOVE_DUPLICATES _requested_libraries)

    list(LENGTH _requested_libraries _length) # <------------------------------ check if VERSION option is properly used

    if (_FIND_LIBRARY_VERSION AND NOT _length EQUAL 1)
        message(FATAL_ERROR "The VERSION option must be used with exactly one library ${_length}")
        return()
    endif()

    string(JSON _length LENGTH "${__ARDUINO_INSTALLED_LIBRARIES}") # <---------------- iterate all libraries in the JSON
    math(EXPR _last "${_length} - 1")

    foreach(_index RANGE ${_last})
        string(JSON _library GET "${__ARDUINO_INSTALLED_LIBRARIES}" "${_index}" library)
        string(JSON _version ERROR_VARIABLE _ignore GET "${_library}" version)
        string(JSON _name GET "${_library}" name)

        if (NOT _name IN_LIST _requested_libraries) # <-------------------------- skip libraries that were not requested
            continue()
        endif()

        if (_FIND_LIBRARY_VERSION) # <----------------------------------- check if the library has the requested version
            if (NOT _version OR _version VERSION_LESS _FIND_LIBRARY_VERSION)
                message(FATAL_ERROR "Library ${_name} ${_version} found, but ${_FIND_LIBRARY_VERSION} was requested")
                return()
            endif()
        endif()

        string(JSON  _source_dirpath GET "${_library}"  _source_dir) # <---------- tell CMake about this Arduino library
        string(JSON        _location GET "${_library}"    _location)

        message(STATUS "Arduino library ${_name} found: version ${_version}, ${_location}")
        __arduino_add_import_library("${_name}" "${_source_dir}")
        list(REMOVE_ITEM _requested_libraries "${_name}")
    endforeach()

    if (_FIND_LIBRARY_REQUIRED AND _requested_libraries) # <----------------------------------- report missing libraries
        message(FATAL_ERROR "Could not find all required libraries: ${_requested_libraries}")
        return()
    endif()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Queries the Arduino Board specific property `NAME`, and places it in `OUTPUT_VARIABLE`.
# Pass the `UNEXPANDED` option to retrieve values without placeholders being expanded.
# ----------------------------------------------------------------------------------------------------------------------
function(arduino_get_property NAME OUTPUT_VARIABLE)
    if (NOT NAME)
        message(FATAL_ERROR "The property name must not be empty!")
        return()
    endif()

    set(options CACHED FULLY_EXPANDED REQUIRED UNEXPANDED)
    set(single_values CONTEXT TARGET)

    cmake_parse_arguments(_GET_PROPERTY "${options}" "${single_values}" "" ${ARGN})
    __arduino_reject_unparsed_arguments(_GET_PROPERTY)

    if (_GET_PROPERTY_UNEXPANDED) # <-------------------------------------------------- select namespace of the variable
        __arduino_property_to_variable("${NAME}" _property UNEXPANDED)
    else()
        __arduino_property_to_variable("${NAME}" _property)
    endif()

    if (_GET_PROPERTY_REQUIRED AND NOT DEFINED "${_property}") # <-------------------------- enforce required properties
        message(FATAL_ERROR "Could not find required board property: ${NAME}")
        return()
    endif()

    set(_property_value "${${_property}}")
    set(_expand_args "${NAME}" _property_value) # <-------------------------- expand remaining placeholders if requested

    if (_GET_PROPERTY_CONTEXT)
        list(APPEND _expand_args CONTEXT "${_GET_PROPERTY_CONTEXT}")
        set(_GET_PROPERTY_FULLY_EXPANDED YES)
    endif()

    if (_GET_PROPERTY_TARGET)
        list(APPEND _expand_args TARGET "${_GET_PROPERTY_TARGET}")
        set(_GET_PROPERTY_FULLY_EXPANDED YES)
    endif()

    if (_GET_PROPERTY_FULLY_EXPANDED)
        __arduino_expand_properties(${_expand_args})
    endif()

    # FIXME These SHELL-QUOTE HACK hacks are needed, but first of all it needs a better place, and a better
    # invokation method. And secondly FIXME: I absolutely have to find and understand how android-cli
    # turns these very random and very wild shell-quoted strings into actual commands.

    if (NAME MATCHES ".*o\\.pattern") # <---------------------------- preserve C-string literals in command-line defines
        # This SHELL-QUOTE HACK is needed for ESP32 builds.
        string(REGEX REPLACE "(-D[^=]+)=\"([^\"]*)\"" "\\1=\\\\\"\\2\\\\\"" _property_value "${_property_value}")

        # Another SHELL-QUOTE HACK for Arduino SAM D.
        string(REPLACE "'" "\"" _property_value "${_property_value}")
    endif()

    if (_GET_PROPERTY_CACHED) # <------------------------------------------------------- cache the variable if requested
        if ("${OUTPUT_VARIABLE}" MATCHES "_PATH$")
            set(_type "PATH")
        else()
            set(_type "STRING")
        endif()

        set("${OUTPUT_VARIABLE}"
            "${_property_value}" CACHE "${_type}"
            "Initialized from Arduino property ${NAME}")
    endif()

    set("${OUTPUT_VARIABLE}" "${_property_value}" PARENT_SCOPE)
endfunction()

# ======================================================================================================================
# Generic utility functions.
# ======================================================================================================================

# ----------------------------------------------------------------------------------------------------------------------
# Checks if `cmake_parse_arguments()` found unparsed arguments for `prefix`,
# and creates a fatal error if that's the case.
# ----------------------------------------------------------------------------------------------------------------------
macro(__arduino_reject_unparsed_arguments PREFIX)
    if (${PREFIX}_UNPARSED_ARGUMENTS)
        message(FATAL_ERROR "Unexpected arguments for ${CMAKE_CURRENT_FUNCTION}(): ${${PREFIX}_UNPARSED_ARGUMENTS}")
        return()
    endif()
endmacro()

# ----------------------------------------------------------------------------------------------------------------------
# Adds a CMake script to serve as code generator.
# This script is run directly during configuration, but also as custom command during regular builds.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_add_code_generator)
    set(_single_values
        COMMENT             # comment when executing directly or as custom command
        CONFIG_TEMPLATE     # the template file for passing arguments to SCRIPT_FILEPATH
        CONFIG_FILEPATH     # output filepath for the processed CONFIG_TEMPLATE
        SCRIPT_FILEPATH     # the script to run
        SCRIPT_OUTPUT)      # the file file(s) the script generates
    set(_multiple_values DEPENDS)

    cmake_parse_arguments(_CODEGEN "" "${_single_values}" "${_multiple_values}" ${ARGN})
    __arduino_reject_unparsed_arguments(_CODEGEN)

    configure_file("${_CODEGEN_CONFIG_TEMPLATE}" "${_CODEGEN_CONFIG_FILEPATH}")

    set(_command "${CMAKE_COMMAND}"
        -D "CMAKE_MESSAGE_LOG_LEVEL=${CMAKE_MESSAGE_LOG_LEVEL}"
        -D "CMAKE_MODULE_PATH=${ARDUINO_TOOLCHAIN_DIR}"
        -D "ARGUMENTS=${_CODEGEN_CONFIG_FILEPATH}"
        -P "${_CODEGEN_SCRIPT_FILEPATH}")

    add_custom_command(
        OUTPUT  "${_CODEGEN_SCRIPT_OUTPUT}"
        DEPENDS "${_CODEGEN_SCRIPT_FILEPATH}" ${_CODEGEN_DEPENDS}
        COMMENT "${_CODEGEN_COMMENT}"
        COMMAND  ${_command})

    message(STATUS "${_CODEGEN_COMMENT}")
    execute_process(COMMAND ${_command} COMMAND_ERROR_IS_FATAL ANY)
endfunction()

# ======================================================================================================================
# Internal utility functions that process Arduino's build properties
# ======================================================================================================================

# ----------------------------------------------------------------------------------------------------------------------
# Queries the CMake variable name for an Arduino Board specific property, and places
# it in `OUTPUT_VARIABLE`. For instance the property "compiler.cpp.flags" gets stored
# in "ARDUINO_PROPERTIES_EXPANDED_COMPILER_CPP_FLAGS". Pass the `UNEXPANDED` option
# to retrieve the variable name without expanded placeholders.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_property_to_variable PROPERTY_NAME OUTPUT_VARIABLE)
    cmake_parse_arguments(_BOARD_PROPERTY_NAME "UNEXPANDED" "" "" ${ARGN})
    __arduino_reject_unparsed_arguments(_BOARD_PROPERTY_NAME)

    string(REPLACE "." "_" _name "${PROPERTY_NAME}")
    string(TOUPPER "${_name}" _name)

    if (_BOARD_PROPERTY_NAME_UNEXPANDED) # <---------------------------- choose between expanded and unexpanded property
        string(PREPEND _name ARDUINO_PROPERTIES_UNEXPANDED_)
    else()
        string(PREPEND _name ARDUINO_PROPERTIES_EXPANDED_)
    endif()

    string(TOUPPER "${ARDUINO_PROPERTIES_EXPANDED_RUNTIME_OS}" _host_suffix) # <-------- consider host specific override
    set(_host_variable "${_name}_${_host_suffix}")

    # Must check for empty _host_suffix because it will be empty initially
    # while filling the alias variables in __arduino_find_properties().
    if (_host_suffix AND DEFINED "${_host_variable}")
        set("${OUTPUT_VARIABLE}" "${_host_variable}" PARENT_SCOPE)
    else()
        set("${OUTPUT_VARIABLE}" "${_name}" PARENT_SCOPE)
    endif()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Expands the Arduino build property references in `VARIABLE_NAME`.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_expand_properties PROPERTY_NAME VARIABLE_NAME)
    cmake_parse_arguments(_EXPAND_PROPERTIES "" "CONTEXT;TARGET" "" ${ARGN})
    __arduino_reject_unparsed_arguments(_EXPAND_PROPERTIES)

    cmake_path(NATIVE_PATH CMAKE_BINARY_DIR NORMALIZE _binary_dirpath)  # FIXME initialize from target's BINARY_DIR
    cmake_path(NATIVE_PATH CMAKE_SOURCE_DIR NORMALIZE _source_dirpath)  # FIXME initialize from target's SOURCE_DIR
    set(_target_output  "${CMAKE_PROJECT_NAME}")                        # FIXME initialize from target's OUTPUT_NAME

    if (PROPERTY_NAME STREQUAL "recipe.ar.pattern") # <---------------------- this property needs some custom expansions
        set(_archive_filepath "<TARGET>")
        set(_object_file "<LINK_FLAGS> <OBJECTS>")
    else()
        set(_archive_filepath "") # FIXME initialize from _binary_dirpath and _archive_filepath
        set(_object_file "<OBJECT>")
    endif()

    set(_archive_filename "") # FIXME initialize from target's OUTPUT_NAME and SUFFIX

    if (_EXPAND_PROPERTIES_TARGET)
        get_property(_warning_shown GLOBAL PROPERTY __ARDUINO_CLI_EXPAND_TARGET_WARNING_SHOWN)

        if (NOT _warning_shown)
            message(WARNING "TARGET specific property expansions are not supported yet") # FIXME implement this
            set_property(GLOBAL PROPERTY __ARDUINO_CLI_EXPAND_TARGET_WARNING_SHOWN YES)
        endif()
    endif()

    if (ARDUINO_UPLOAD_VERBOSE) # <--------------------------------------- prepare the context property {upload.verbose}
       set(_upload_verbose_property "upload.params.quiet")
    else()
        set(_upload_verbose_property "upload.params.verbose")
    endif()

    set(_variable "${${VARIABLE_NAME}}") # <--------------------------------------------------- start property expansion

    string(REPLACE
        "{build.path}/{archive_file}"   # this sequence is problematic for empty ${_archive_filename}
        "{archive_file_path}"           # replace it by something more reliable
        _variable "${_variable}")

    while (_variable MATCHES "{([^}]+)}")
        set(_pattern  "${CMAKE_MATCH_0}")
        set(_property "${CMAKE_MATCH_1}")
        set(_value_found NO)
        set(_value)

        if (_EXPAND_PROPERTIES_CONTEXT) # <------------ first expand context properties; like {cmd} and {path} for tools
            if (_property STREQUAL "upload.verbose")
                set(_context_property "${_EXPAND_PROPERTIES_CONTEXT}.${_upload_verbose_property}")
            else()
                set(_context_property "${_EXPAND_PROPERTIES_CONTEXT}.${_property}")
            endif()

            __arduino_property_to_variable("${_context_property}" _context_variable)

            if (DEFINED "${_context_variable}")
                set(_value "${${_context_variable}}")
                set(_value_found TRUE)
            endif()
        endif()

        if (NOT _value_found) # <------------------------------ expand properties injected by arduino-cli while building
            if (_property STREQUAL "build.path")
                set(_value "${_binary_dirpath}")
            elseif (_property STREQUAL "build.source.path")
                set(_value "${_source_dirpath}")
            elseif (_property STREQUAL "build.project_name")
                set(_value "${_target_output}")
            elseif (_property STREQUAL "includes")
                set(_value "<DEFINES> <INCLUDES> <FLAGS>")
            elseif (_property STREQUAL "source_file")
                set(_value "<SOURCE>")
            elseif (_property STREQUAL "object_file")
                set(_value "${_object_file}")
            elseif (_property STREQUAL "object_files")
                set(_value "<OBJECTS> <LINK_LIBRARIES>")
            elseif (_property STREQUAL "archive_file")
                set(_value "${_archive_filename}")
            elseif (_property STREQUAL "archive_file_path")
                set(_value "${_archive_filepath}")
            elseif (_property STREQUAL "serial.port")
                set(_value "${ARDUINO_UPLOAD_SERIAL_PORT}")
            elseif (_property STREQUAL "serial.port.file")
                cmake_path(GET ARDUINO_UPLOAD_SERIAL_PORT FILENAME _value)
            elseif (_property STREQUAL "upload.protocol")
                set(_value "${ARDUINO_UPLOAD_PROTOCOL}")
            elseif (_property STREQUAL "upload.speed")
                set(_value "${ARDUINO_UPLOAD_SPEED}")
            elseif (_property STREQUAL "upload.port.address")
                set(_value "${ARDUINO_UPLOAD_NETWORK_ADDRESS}")
            elseif (_property STREQUAL "upload.port.properties.port")
                set(_value "${ARDUINO_UPLOAD_NETWORK_PORT}")
            elseif (_property STREQUAL "upload.port.properties.endpoint_upload"
                 OR _property STREQUAL "upload.network.endpoint_upload")
                set(_value "${ARDUINO_UPLOAD_NETWORK_ENDPOINT_UPLOAD}")
            elseif (_property STREQUAL "upload.port.properties.endpoint_sync"
                 OR _property STREQUAL "upload.network.endpoint_sync")
                set(_value "${ARDUINO_UPLOAD_NETWORK_ENDPOINT_SYNC}")
            elseif (_property STREQUAL "upload.port.properties.endpoint_reset"
                 OR _property STREQUAL "upload.network.endpoint_reset")
                set(_value "${ARDUINO_UPLOAD_NETWORK_ENDPOINT_RESET}")
            elseif (_property STREQUAL "upload.port.properties.sync_return"
                 OR _property STREQUAL "upload.network.sync_return")
                set(_value "${ARDUINO_UPLOAD_NETWORK_SYNC_RETURN}")
            else()
                arduino_get_property("${_property}" _value REQUIRED)
            endif()
        endif()

        string(REPLACE "\"${_pattern}\"" "${_value}" _expanded "${_variable}")
        string(REPLACE   "${_pattern}"   "${_value}" _expanded "${_expanded}")

        if (_expanded STREQUAL _variable)
            message(FATAL_ERROR "Replacing '${_property}' by '${_value}' has failed. Aborting.")
        endif()

        set(_variable "${_expanded}")
    endwhile()

    set("${VARIABLE_NAME}" "${_variable}" PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Retrieves the command defined for HOOK at INDEX as COMMAND list for execute_process().
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_get_hook_command HOOK_NAME INDEX OUTPUT_VARIABLE)
    set(_command_list)

    set(_hook_candiates "${HOOK_NAME}.${INDEX}.pattern")

    if (INDEX LESS 10) # <----------------------------------------------- also try zero padded variants of small indexes
        # Arduino sorts hook keys lexically, not numerically to resolve hook order.
        # Therefore small indexes must be padded with zero if more than nine hooks are used.
        list(APPEND _hook_candiates "${HOOK_NAME}.0${INDEX}.pattern")
    endif()

    foreach(_hook IN LISTS _hook_candiates)
        __arduino_property_to_variable("${_hook}" _variable)

        if (DEFINED "${_variable}") # <---------------------------------------------- check if there is a hook for INDEX
            set(_command "${${_variable}}")
            __arduino_expand_properties("${_hook}" _command)
            __arduino_make_command_list("${_command}" _command_list)
            break()
        endif()
    endforeach()

    set("${OUTPUT_VARIABLE}" ${_command_list} PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Retrieves all the commands defined for HOOK as COMMAND list for execute_process().
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_generate_hook_commands HOOK_NAME OUTPUT_VARIABLE)
    set(_command_list)

    foreach(_index RANGE 1 99)
        __arduino_get_hook_command("${HOOK_NAME}" ${_index} _command)

        if (_command) # the hook sequence is not continous; it is common to skip indexes
            list(APPEND _command_list COMMAND ${_command})
        endif()
    endforeach()

    set("${OUTPUT_VARIABLE}" ${_command_list} PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Runs all the commands defined for `HOOK` right now via execute_process().
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_run_hooks HOOK_NAME)
    message(VERBOSE "Running hook ${HOOK_NAME}")

    foreach(_index RANGE 1 99)
        __arduino_get_hook_command("${HOOK_NAME}" ${_index} _command_list)

        if (_command_list) # the hook sequence is not continous; it is common to skip indexes
            execute_process(
                COMMAND ${_command_list} RESULT_VARIABLE _result
                OUTPUT_VARIABLE _output ERROR_VARIABLE _error)

            if (NOT _result EQUAL 0) # <------------------------------------ produce a detailed error message on failure
                set(_error_message "The hook ${HOOK_NAME}.${_index} has failed with return code ${_result}")

                if (_output)
                    string(APPEND _error_message "\nStandard output was: ${_output}")
                else()
                    string(APPEND _error_message "\nThere was no standard output.")
                endif()

                if (_error)
                    string(APPEND _error_message "\nError output was: ${_error}")
                else()
                    string(APPEND _error_message "\nThere was no error output.")
                endif()

                list(JOIN _command_list "\n  " _display_command_list)
                string(APPEND _error_message "\nCOMMAND list:\n  ${_display_command_list}\n")
                message(FATAL_ERROR "${_error_message}")
            endif()
        endif()
    endforeach()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Converts a shell quoted command string into a COMMAND list for execute_process().
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_make_command_list SHELL_QUOTED OUTPUT_VARIABLE)
    set(_quoted   "\"([^\"]*)\"")               # quoted command line argument
    set(_exquoted "([\\]\"[^\"]*[\\]\")")       # explicitly quoted
    set(_literal  "([^\"\t ]+)")                # literal command line argument without spaces or quotes
    set(_tail     "[ \t]+(.*)|$")               # the next argument separating space and the remaining text
    set(_argument "${_quoted}|${_exquoted}|${_literal}")

    set(_command "${SHELL_QUOTED}")
    set(_command_list)

    # This SHELL-QUOTE HACK is needed for STM32 builds.
    string(REPLACE "\"\"" "\\\"" _command "${_command}")

    while (_command AND _command MATCHES "^(${_argument})(${_tail})") # <------------------------ split the command line
        list(APPEND _command_list "${CMAKE_MATCH_2}${CMAKE_MATCH_3}${CMAKE_MATCH_4}") # one of them
        set(_command "${CMAKE_MATCH_6}")
    endwhile()

    if (_command)
        message(FATAL_ERROR "BUG: Unexpected state: ${_command}") # we should have consumed everything
        return()
    endif()

    set("${OUTPUT_VARIABLE}" ${_command_list} PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Initializes `VARIABLE` from `DEFAULT_VALUE` if that variable is not yet set. Optionally pairs
# of `if()` expressions and alternate default values can be passed for platform specific default.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_set_default VARIABLE DEFAULT_VALUE) # [CONDITION DEFAULT_VALUE ...]
    if ("${VARIABLE}") # <------------------------------------------------- nothing to do, if the variable is already set
        return()
    endif()

    if (ARGN) # <---------------------------------------------------------------- parse the list of conditional defaults
        list(LENGTH ARGN _condition_count)

        foreach(_value_index RANGE 1 ${_condition_count} 2)
            math(EXPR _condition_index "${_value_index} - 1")
            list(GET ARGN ${_condition_index} _condition)

            cmake_language( # <----------------------------------------------- check if this conditional default applies
                EVAL CODE "if (${_condition})
                    set(_accepted YES)
                endif()")

            if (_accepted)
                list(GET ARGN ${_value_index} DEFAULT_VALUE)
                break()
            endif()
        endforeach()
    endif()

    set("${VARIABLE}" "${DEFAULT_VALUE}" PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Defines and describes toolchain file options. They are peristed per cached variables.
# See __arduino_set_default() for the sophisticated default value mechanism.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_option TYPE NAME DEFAULT_VALUE) # [CONDITION DEFAULT_VALUE ...] DOCSTRING
    list(POP_BACK ARGN _docstring)
    set(_conditional_defaults ${ARGN})

    __arduino_set_default("${NAME}" "${DEFAULT_VALUE}" ${_conditional_defaults})
    set("${NAME}" "${${NAME}}" CACHE "${TYPE}" "${_docstring}")
endfunction()

# ======================================================================================================================
# Internal utility functions that find Arduino components and configurations.
# ======================================================================================================================

# ----------------------------------------------------------------------------------------------------------------------
# Collects build properties for the current board from arduino-cli,
# and stores them in prefixed CMake variables.
#
# See `arduino_get_property()` and `__arduino_property_to_variable()`.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_find_properties MODE)
    if (MODE STREQUAL UNEXPANDED) # <---------------------------------------------------------- parse function arguments
        set(_property_mode UNEXPANDED)
    elseif (MODE STREQUAL EXPANDED)
        set(_property_mode)
    else()
        message(FATAL_ERROR "Unsupported mode: ${MODE}")
        return()
    endif()

    string(TOLOWER "${MODE}" _mode)

    set(_use_property_cache YES) # <----------------------------------------- figure out if a cached version can be used
    set(_cachefile_variable "__ARDUINO_PROPERTIES_${MODE}_CACHE")

    if (DEFINED "${_cachefile_variable}")
        set(_arduino_cache_filepath "${${_cachefile_variable}}")
        set(_cmake_dump_filepath) # do not dump already cached variables
    else()
        set(_arduino_cache_filepath "${CMAKE_BINARY_DIR}/ArduinoFiles/properties-${_mode}.txt")
        set(_cmake_dump_filepath    "${CMAKE_BINARY_DIR}/ArduinoFiles/properties-${_mode}.cmake")

        if (NOT EXISTS "${_arduino_cache_filepath}"
                OR NOT EXISTS "${CMAKE_BINARY_DIR}/CMakeCache.txt"
                OR NOT "${_arduino_cache_filepath}" IS_NEWER_THAN "${CMAKE_BINARY_DIR}/CMakeCache.txt")
            set(_use_property_cache NO)
        endif()
    endif()

    set("${_cachefile_variable}" "${_arduino_cache_filepath}" PARENT_SCOPE)

    if (_use_property_cache) # <---------------------------------------------------------- try to read cached properties
        message(STATUS "Reading ${_mode} build properties from ${_arduino_cache_filepath}")
        file(READ "${_arduino_cache_filepath}" _properties)
    else() # <------------------------------------------------------------------------------------- run arduino-cli tool
        message(STATUS "Running android-cli to read ${_mode} build properties...")

        execute_process(
            COMMAND "${ARDUINO_CLI_EXECUTABLE}"
            board details "--fqbn=${ARDUINO_BOARD}"
            --show-properties=${_mode} --format=text

            ENCODING UTF-8
            COMMAND_ERROR_IS_FATAL ANY
            OUTPUT_STRIP_TRAILING_WHITESPACE
            OUTPUT_VARIABLE _properties)

        file(WRITE "${_arduino_cache_filepath}" "${_properties}")
    endif()

    if (NOT _property_list)
        string(REPLACE ";" "\\;" _properties "${_properties}") # <------------------ split into lines; preserving semicolons
        string(REGEX REPLACE "[ \t\r]*\n" ";" _property_list "${_properties}")
    endif()

    if (NOT _use_property_cache)
        list(LENGTH _property_list _count)
        message(STATUS "  ${_count} properties found")
    endif()

    set(_variable_dump "")

    foreach (_property IN LISTS _property_list) # <--------------------------------- set CMake variables from properties
        if (_property MATCHES "([^=]+)=(.*)")
            set(_property_name  "${CMAKE_MATCH_1}")
            set(_property_value "${CMAKE_MATCH_2}")

            __arduino_property_to_variable("${_property_name}" _variable ${_property_mode})

            if (_variable MATCHES "_PATH$")
                cmake_path(CONVERT "${_property_value}" TO_CMAKE_PATH_LIST _property_value)
            endif()

            set("${_variable}" "${_property_value}" PARENT_SCOPE)
            string(APPEND _property_dump "${_variable}=${_property_value}\n")
        elseif (_property)
            message(FATAL_ERROR "Unexpected output from arduino-cli tool: ${_property}")
            return()
        endif()
    endforeach()

    if ("${_cmake_dump_filepath}") # <---------------------------------------------- only dump after running arduino-cli
        file(WRITE "${_cmake_dump_filepath}" "${_property_dump}")
    endif()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Collects available libraries for the current board from arduino-cli.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_find_libraries)
    set(_use_library_cache YES) # <------------------------------------------ figure out if a cached version can be used

    if (__ARDUINO_INSTALLED_LIBRARIES_CACHE)
        set(_arduino_cache_filepath "${__ARDUINO_INSTALLED_LIBRARIES_CACHE}")
    else()
        set(_arduino_cache_filepath "${CMAKE_BINARY_DIR}/ArduinoFiles/libraries.json")

        if (NOT EXISTS "${_arduino_cache_filepath}"
                OR NOT EXISTS "${CMAKE_BINARY_DIR}/CMakeCache.txt"
                OR NOT "${_arduino_cache_filepath}" IS_NEWER_THAN "${CMAKE_BINARY_DIR}/CMakeCache.txt")
            set(_use_library_cache NO)
        endif()
    endif()

    if (_use_library_cache) # <------------------------------------------------------------ try to read cached libraries
        message(STATUS "Reading installed Arduino libraries from ${_arduino_cache_filepath}")
        file(READ "${_arduino_cache_filepath}" _json)
    else() # <------------------------------------------------------------------------------------- run arduino-cli tool
        message(STATUS "Running android-cli to read installed Arduino libraries...")

        execute_process(
            COMMAND "${ARDUINO_CLI_EXECUTABLE}"
            lib list "--fqbn=${ARDUINO_BOARD}" --format=json

            ENCODING UTF-8
            COMMAND_ERROR_IS_FATAL ANY
            OUTPUT_STRIP_TRAILING_WHITESPACE
            OUTPUT_VARIABLE _json)

        file(WRITE "${_arduino_cache_filepath}" "${_json}")
    endif()

    string(JSON _installed_libraries GET "${_json}" installed_libraries) # <-------------- parse the library information

    if (NOT _use_library_cache)
        string(JSON _count LENGTH "${_installed_libraries}")
        message(STATUS "  ${_count} libraries found")
    endif()

    set(__ARDUINO_INSTALLED_LIBRARIES       "${_installed_libraries}"    PARENT_SCOPE)
    set(__ARDUINO_INSTALLED_LIBRARIES_CACHE "${_arduino_cache_filepath}" PARENT_SCOPE)
endfunction()

# ======================================================================================================================
# Internal utility functions that inspect CMake targets.
# ======================================================================================================================

# ----------------------------------------------------------------------------------------------------------------------
# Finds all C, C++ and Assembler sources in `DIRECTORY`, and lists them in `OUTPUT_VARIABLE`.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_collect_source_files OUTPUT_VARIABLE DIRECTORY) # [DIRECTORY...]
    unset(_glob_pattern_list)

    foreach(_dirpath IN ITEMS "${DIRECTORY}" LISTS ARGN)
        list(APPEND _glob_pattern_list
            "${_dirpath}/*.[cC]"
            "${_dirpath}/*.[cC][cC]"
            "${_dirpath}/*.[cCiItT][pP][pP]"
            "${_dirpath}/*.[cC][xX][xX]"
            "${_dirpath}/*.[hH]"
            "${_dirpath}/*.[hH][hH]"
            "${_dirpath}/*.[hH][pP][pP]"
            "${_dirpath}/*.[hH][xX][xX]"
            "${_dirpath}/*.[sS]")
    endforeach()

    file(GLOB_RECURSE _source_file_list ${_glob_pattern_list})
    set("${OUTPUT_VARIABLE}" ${_source_file_list} PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Resolves the absolute filepath where arduino-cli would store `FILENAME` after processing.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_resolve_preprocessed_filepath SOURCE_DIRPATH FILENAME OUTPUT_DIRPATH OUTPUT_VARIABLE)
    cmake_path(
        ABSOLUTE_PATH FILENAME
        BASE_DIRECTORY "${SOURCE_DIRPATH}"
        OUTPUT_VARIABLE _absolute_filepath
        NORMALIZE)

    string(FIND "${_absolute_filepath}" "${SOURCE_DIRPATH}" _offset)

    if (_offset EQUAL 0)
        cmake_path(
            RELATIVE_PATH _absolute_filepath
            BASE_DIRECTORY "${SOURCE_DIRPATH}"
            OUTPUT_VARIABLE _relative_filepath)

        if (_relative_filepath MATCHES "${__ARDUINO_SKETCH_SUFFIX}")
            string(APPEND _relative_filepath ".cpp")
        endif()

        set("${OUTPUT_VARIABLE}" "${OUTPUT_DIRPATH}/${_relative_filepath}" PARENT_SCOPE)
    else()
        unset("${OUTPUT_VARIABLE}" PARENT_SCOPE)
    endif()
endfunction()

# ======================================================================================================================
# Internal utility functions that manipulate CMake targets.
# ======================================================================================================================

# ----------------------------------------------------------------------------------------------------------------------
# Creates an import library for the given Arduino library. To avoid polluting the current project with dozens,
# if not hundreds of out-of-tree sources the library is built separately and later gets pulled as IMPORT library.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_add_import_library NAME SOURCE_DIR) # [SOURCE_DIR...]
    string(TOUPPER "ARDUINO_${NAME}" _prefix)

    set(_libname "Arduino${NAME}")
    set(_target  "Arduino::${NAME}")

    if (${_prefix}_FILEPATH)
        message(STATUS "Using ${_target} from ${${_prefix}_FILEPATH}")

        set(_library_binary_dir     "${${_prefix}_BINARY_DIR}")
        set(_library_source_dir     "${${_prefix}_BINARY_DIR}")
        set(_library_directories    "${${_prefix}_INCLUDE_DIRS}")
        set(_library_filepath       "${${_prefix}_FILEPATH}")
    else()
        message(STATUS "Building ${_target} from scratch")

        set(_library_binary_dir "${CMAKE_BINARY_DIR}/Arduino/${NAME}")
        set(_library_source_dir "${CMAKE_BINARY_DIR}/ArduinoFiles/${NAME}")
        set(_library_filepath   "${_library_binary_dir}/lib${_libname}.a")

        set(_library_directories "${SOURCE_DIR}" ${ARGN}) # <---------------- normalize the library's source directories
        list(FILTER _library_directories EXCLUDE REGEX "^ *\$")
        list(REMOVE_DUPLICATES _library_directories)

        __arduino_collect_source_files(_library_sources ${_library_directories}) # <--------- find the library's sources

        list(LENGTH _library_sources _source_file_count)
        message(STATUS "  ${_source_file_count} source files found for ${_target}")

        list(JOIN _library_sources     "\"\n    \"" _quoted_library_sources) # <----- prepare CMake to build out of tree
        list(JOIN _library_directories "\"\n    \"" _quoted_library_directories)

        set(_library_template "${ARDUINO_TOOLCHAIN_DIR}/Templates/ArduinoLibraryCMakeLists.txt.in")
        configure_file("${_library_template}" "${_library_source_dir}/CMakeLists.txt")

        add_custom_command(
            OUTPUT "${_library_binary_dir}/CMakeCache.txt"
            DEPENDS "${_library_template}" "${CMAKE_CURRENT_LIST_FILE}"
            COMMENT "Configuring ${_target} library"
            WORKING_DIRECTORY "${_library_binary_dir}"

            COMMAND "${CMAKE_COMMAND}"
            --toolchain "${CMAKE_CURRENT_FUNCTION_LIST_FILE}"
            -G "${CMAKE_GENERATOR}" -S "${_library_source_dir}"
            -D "__ARDUINO_IMPORTED_TARGET_CACHE=${__ARDUINO_IMPORTED_TARGET_CACHE}"
            -D "ARDUINO_BOARD:STRING=${ARDUINO_BOARD}")

        add_custom_command(
            OUTPUT "${_library_filepath}"
            DEPENDS ${_library_sources} "${_library_binary_dir}/CMakeCache.txt"
            COMMENT "Building ${_target} library"
            WORKING_DIRECTORY "${_library_binary_dir}"

            COMMAND "${CMAKE_COMMAND}" --build "${_library_binary_dir}")

        add_custom_target("${_libname}_compile" DEPENDS "${_library_filepath}")

        set(${_prefix}_BINARY_DIR   "${_library_binary_dir}"    PARENT_SCOPE) # <------------------- set cache variables
        set(${_prefix}_SOURCE_DIR   "${_library_source_dir}"    PARENT_SCOPE)
        set(${_prefix}_FILEPATH     "${_library_filepath}"      PARENT_SCOPE)
        set(${_prefix}_INCLUDE_DIRS "${_library_directories}"   PARENT_SCOPE)

        file(
            APPEND "${__ARDUINO_IMPORTED_TARGET_CACHE}"
            "set(${_prefix}_BINARY_DIR   \"${_library_binary_dir}\")\n"
            "set(${_prefix}_SOURCE_DIR   \"${_library_source_dir}\")\n"
            "set(${_prefix}_FILEPATH     \"${_library_filepath}\")\n"
            "set(${_prefix}_INCLUDE_DIRS \"${_library_directories}\")\n")
    endif()

    add_library("${_target}" STATIC IMPORTED) # <-------------------- define import library for the built static library

    if (TARGET "${_libname}_compile")
        add_dependencies("${_target}" "${_libname}_compile")
    endif()

    if (NOT NAME STREQUAL "Core")
        target_link_libraries("${_target}" INTERFACE Arduino::Core)
    endif()

    target_include_directories("${_target}" INTERFACE ${_library_directories})
    set_property(TARGET "${_target}" PROPERTY IMPORTED_LOCATION "${_library_filepath}")
    set_property(TARGET "${_target}" PROPERTY SYSTEM NO) # otherwise AVR builds will fail

    # The inlining from unity builds greatly increases the binary size. At least for the ESP8266 this results in
    # a core too large for empty sketches.  Besides that, some of the Arduino core headers are not self-contained,
    # resulting in randomly failing unity builds.  Therefore strictly disable unity builds for Arduino libraries.
    set_property(TARGET "${_target}" PROPERTY UNITY_BUILD NO)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Creates an import library for Arduino's core library.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_add_arduino_core_library)
    cmake_path(
        CONVERT "${ARDUINO_PROPERTIES_EXPANDED_BUILD_CORE_PATH}"
        TO_CMAKE_PATH_LIST _core_dirpath
        NORMALIZE)

    cmake_path(
        CONVERT "${ARDUINO_PROPERTIES_EXPANDED_BUILD_VARIANT_PATH}"
        TO_CMAKE_PATH_LIST _variant_dirpath
        NORMALIZE)

    set(_library_directories "${_core_dirpath}" "${_variant_dirpath}")
    __arduino_add_import_library(Core ${_library_directories})

    foreach(_suffix IN ITEMS BINARY_DIR SOURCE_DIR FILEPATH)
        set("ARDUINO_CORE_${_suffix}" "${ARDUINO_CORE_${_suffix}}" PARENT_SCOPE)
    endforeach()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Generates the rules for building TARGET's firmware and reports the firmware's filename in OUTPUT_VARIABLE.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_add_firmware_target TARGET OUTPUT_VARIABLE)
    __arduino_generate_hook_commands("recipe.objcopy.hex" _objcopy_commands) # FIXME also pass TARGET
    arduino_get_property("recipe.output.tmp_file" _firmware_filename REQUIRED TARGET "${TARGET}")

    add_custom_command(
        OUTPUT "${_firmware_filename}" DEPENDS "${TARGET}"
        COMMENT "Building firmware ${_firmware_filename}"
        ${_objcopy_commands})

    add_custom_target(
        "${TARGET}_firmware" ALL DEPENDS "${_firmware_filename}")

    set("${OUTPUT_VARIABLE}" "${_firmware_filename}" PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Generates the rules for uploading TARGET's firmware
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_add_upload_target TARGET UPLOAD_TARGET FIRMWARE_FILENAME UPLOAD_TOOL)
    arduino_get_property("${UPLOAD_TOOL}" _tool_name)

    if (_tool_name)
        arduino_get_property(
            "tools.${_tool_name}.upload.pattern" _command
            CONTEXT "tools.${_tool_name}" TARGET "${TARGET}")

        __arduino_make_command_list("${_command}" _command_list)

        add_custom_target(
            "${UPLOAD_TARGET}" DEPENDS "${FIRMWARE_FILENAME}"
            COMMENT "Uploading ${FIRMWARE_FILENAME} to attached device"
            COMMAND ${_command_list})
    endif()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Preprocesses `SOURCE_FILENAME..` in `MODE`, similar like arduino-cli would do.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_preprocess OUTPUT_VARIABLE OUTPUT_DIRPATH SOURCE_DIRPATH MODE SOURCE_FILENAME) # [OTHER_SKETCHES...]
    set(OTHER_SKETCHES ${ARGN})

    cmake_path(
        ABSOLUTE_PATH SOURCE_FILENAME
        BASE_DIRECTORY "${SOURCE_DIRPATH}"
        OUTPUT_VARIABLE _source_filepath
        NORMALIZE)

    __arduino_resolve_preprocessed_filepath(
        "${SOURCE_DIRPATH}" "${_source_filepath}"
        "${OUTPUT_DIRPATH}" _output_filepath)

    string(MD5 _filepath_hash "${_output_filepath}")
    set(_config_filepath "${CMAKE_BINARY_DIR}/ArduinoFiles/${_target}/preprocess-config-${_filepath_hash}.cmake")

    __arduino_add_code_generator(
        SCRIPT_OUTPUT   "${_output_filepath}"
        SCRIPT_FILEPATH "${__ARDUINO_TOOLCHAIN_PREPROCESS}"
        CONFIG_TEMPLATE "${ARDUINO_TOOLCHAIN_DIR}/Templates/PreprocessConfig.cmake.in"
        CONFIG_FILEPATH "${_config_filepath}"
        COMMENT         "Preprocessing ${SOURCE_FILENAME}"
        DEPENDS         "${_source_filepath}" ${OTHER_SKETCHES})

    set("${OUTPUT_VARIABLE}" "${_output_filepath}" PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Preprocesses the source files of `TARGET`, similar like arduino-cli would do.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_preprocess_sketch TARGET OUTPUT_DIRPATH SOURCE_DIRPATH SOURCES)
    set(_sketch_list ${SOURCES}) # <------------------------------------------------------ collect sketches from SOURCES
    list(FILTER _sketch_list INCLUDE REGEX "${__ARDUINO_SKETCH_SUFFIX}")
    list(PREPEND _sketch_list "${TARGET}.ino")
    list(REMOVE_DUPLICATES _sketch_list)

    __arduino_preprocess( # <----------------------------------------------------------------------- preprocess sketches
        _preprocessed_filepath "${OUTPUT_DIRPATH}"
        "${SOURCE_DIRPATH}" SKETCH ${_sketch_list})

    target_sources("${TARGET}" PUBLIC "${_preprocessed_filepath}")

    list(REMOVE_ITEM SOURCES ${_sketch_list}) # <-------------------------------------- preprocess regular/other sources

    foreach(_filename IN LISTS SOURCES)
        __arduino_preprocess(
            _preprocessed_filepath "${OUTPUT_DIRPATH}"
            "${SOURCE_DIRPATH}" SOURCE "${_filename}")

        target_sources("${TARGET}" PUBLIC "${_preprocessed_filepath}")
    endforeach()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Iterates all subdirectories of the project and finalizes Arduino sketches.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_toolchain_finalize DIRECTORY)
    get_property( # <-------------------------------------------------------- iterate build targets in current directory
        _target_list DIRECTORY "${DIRECTORY}"
        PROPERTY BUILDSYSTEM_TARGETS)

    foreach(_target IN LISTS _target_list)
        get_property(_binary_dirpath TARGET "${_target}" PROPERTY BINARY_DIR)
        get_property(_source_dirpath TARGET "${_target}" PROPERTY SOURCE_DIR)
        get_property(_source_list TARGET "${_target}" PROPERTY SOURCES)

        cmake_path(ABSOLUTE_PATH _source_dirpath NORMALIZE)
        set(_sketch_dirpath "${_binary_dirpath}/sketch")
        set(_is_sketch NO)

        foreach(_filename IN LISTS _source_list)
            if (_filename MATCHES "${__ARDUINO_SKETCH_SUFFIX}") # <--------------------------- finalize Arduino sketches
                message(TRACE "Finalizing Arduino sketch ${_filename} in ${DIRECTORY}")

                set_property( # <-------------------------------------- tell CMake that Arduino sketches are in fact C++
                    SOURCE "${_filename}"
                    DIRECTORY "${DIRECTORY}"
                    PROPERTY LANGUAGE CXX)

                set_property( # <-------------------------- also tell the compiler that Arduino sketches are in fact C++
                    SOURCE "${_filename}"
                    DIRECTORY "${DIRECTORY}"
                    APPEND PROPERTY COMPILE_OPTIONS --lang c++ --include Arduino.h)

                set(_is_sketch YES) # FIXME also check target type?
            endif()
        endforeach()

        if (_is_sketch)
            foreach(_filename IN LISTS _source_list)
                set_property( # <------------------------------ disable sources as we compile from copy in sketch folder
                    SOURCE "${_filename}"
                    DIRECTORY "${_source_dirpath}"
                    PROPERTY HEADER_FILE_ONLY YES)
            endforeach()

            __arduino_preprocess_sketch( # <----------------------------------------------------------- build the sketch
                "${_target}" "${_sketch_dirpath}"
                "${_source_dirpath}" "${_source_list}")

            target_link_libraries("${_target}" PUBLIC Arduino::Core)

            set_property(TARGET "${_target}" PROPERTY SUFFIX ".elf") # <----------------------- build the final firmware
            __arduino_add_firmware_target("${_target}" _firmware_filename)

            __arduino_add_upload_target( # <-------------------------------------------------- allow to upload to device
                "${_target}" "${_target}_upload"
                "${_firmware_filename}"
                "upload.tool.default")

            __arduino_add_upload_target(
                "${_target}" "${_target}_upload_ota"
                "${_firmware_filename}"
                "upload.tool.network")
        endif()
    endforeach()

    get_property( # <---------------------------------------------------------------------- also finalize subdirectories
        _subdir_list DIRECTORY "${DIRECTORY}"
        PROPERTY SUBDIRECTORIES)

    foreach(_subdir IN LISTS _subdir_List)
        __arduino_toolchain_finalize("${_subdir}")
    endforeach()
endfunction()

# ======================================================================================================================
# This are the toolchain's setup steps.
# ======================================================================================================================

if (ARDUINO_BOARD MATCHES "^([^:]+):([^:]+):([^:]+)(:(.*))?\$")
    set(ARDUINO_BOARD_VENDOR  "${CMAKE_MATCH_1}")
    set(ARDUINO_BOARD_CORE    "${CMAKE_MATCH_2}")
    set(ARDUINO_BOARD_ID      "${CMAKE_MATCH_3}")
    set(ARDUINO_BOARD_OPTIONS "${CMAKE_MATCH_5}")
else()
    message(
        FATAL_ERROR "Invalid value for ARDUINO_BOARD: ${ARDUINO_BOARD}\n"
        "This Parameter must be set, and provide a proper FQBN, a \"fully qualified "
        "board name\", selecting the Arduino compatible hardware for which this "
        "project shall be build. For more information visit the arduino-cli wiki: "
        "https://arduino.github.io/arduino-cli/1.0/FAQ/#whats-the-fqbn-string\n"
        "Examples for proper strings FQBN are:\n"
        "- arduino:avr:nano\n"
        "- esp8266:esp8266:nodemcuv2:baud=512000,led=2")

    return()
endif()

message(STATUS "Configuring Arduino for board id ${ARDUINO_BOARD}")
message(TRACE  "  in ${CMAKE_BINARY_DIR}")
message(TRACE  "  from ${CMAKE_PARENT_LIST_FILE}")

cmake_path(GET CMAKE_CURRENT_LIST_FILE PARENT_PATH ARDUINO_TOOLCHAIN_DIR) # <------ register "Arduino" as CMake platform
list(APPEND CMAKE_MODULE_PATH ${ARDUINO_TOOLCHAIN_DIR})

set(__ARDUINO_SKETCH_SUFFIX "\\.(ino|pde)\$") # <-------------------------------------------- generally useful constants
set(__ARDUINO_TOOLCHAIN_PREPROCESS "${ARDUINO_TOOLCHAIN_DIR}/Scripts/Preprocess.cmake")

list(APPEND CMAKE_CONFIGURE_DEPENDS # <------------------------------------- rerun CMake when helper scripts are changed
    "${__ARDUINO_TOOLCHAIN_PREPROCESS}")

find_program( # <-------------------------------------------------------------------------------------- find android-cli
    ARDUINO_CLI_EXECUTABLE arduino-cli REQUIRED HINTS
    [HKLM/SOFTWARE/Arduino CLI;InstallDir]
    "$ENV{PROGRAMFILES}/Arduino CLI")

__arduino_find_properties(EXPANDED) # <-------------------------------------- collect properties and installed libraries
__arduino_find_properties(UNEXPANDED)
__arduino_find_libraries()

find_program( # <----------------------------------------------------------------------- find ctags from Arduino runtime
    ARDUINO_CTAGS_EXECUTABLE ctags REQUIRED HINTS
    "${ARDUINO_PROPERTIES_EXPANDED_RUNTIME_TOOLS_CTAGS_PATH}")

math(EXPR ARDUINO_VERSION_MAJOR "(${ARDUINO_PROPERTIES_EXPANDED_RUNTIME_IDE_VERSION} / 10000) % 100") # <-- find version
math(EXPR ARDUINO_VERSION_MINOR "(${ARDUINO_PROPERTIES_EXPANDED_RUNTIME_IDE_VERSION} /   100) % 100")
math(EXPR ARDUINO_VERSION_PATCH "(${ARDUINO_PROPERTIES_EXPANDED_RUNTIME_IDE_VERSION} /     1) % 100")

set(ARDUINO_VERSION "${ARDUINO_VERSION_MAJOR}.${ARDUINO_VERSION_MINOR}.${ARDUINO_VERSION_PATCH}")

set(CMAKE_SYSTEM_NAME       "Arduino") # <----------------------------------------- tell CMake the name of this platform
set(CMAKE_SYSTEM_VERSION    "${ARDUINO_VERSION}")
set(CMAKE_SYSTEM_PROCESSOR  "${ARDUINO_PROPERTIES_EXPANDED_BUILD_ARCH}")


# <---------------------------------------------------------------------------------------------------- find build rules
arduino_get_property("recipe.S.o.pattern"         CMAKE_ASM_COMPILE_OBJECT        FULLY_EXPANDED CACHED)
arduino_get_property("recipe.c.o.pattern"         CMAKE_C_COMPILE_OBJECT          FULLY_EXPANDED CACHED)
arduino_get_property("recipe.c.combine.pattern"   CMAKE_C_LINK_EXECUTABLE         FULLY_EXPANDED CACHED)
arduino_get_property("recipe.ar.pattern"          CMAKE_C_CREATE_STATIC_LIBRARY   FULLY_EXPANDED CACHED)
arduino_get_property("recipe.cpp.o.pattern"       CMAKE_CXX_COMPILE_OBJECT        FULLY_EXPANDED CACHED)
arduino_get_property("recipe.c.combine.pattern"   CMAKE_CXX_LINK_EXECUTABLE       FULLY_EXPANDED CACHED)
arduino_get_property("recipe.ar.pattern"          CMAKE_CXX_CREATE_STATIC_LIBRARY FULLY_EXPANDED CACHED)

find_program( # <------------------------------------------------------------------------------------ find the compilers
    "CMAKE_C_COMPILER"
    "${ARDUINO_PROPERTIES_EXPANDED_COMPILER_C_CMD}"
    PATHS "${ARDUINO_PROPERTIES_EXPANDED_COMPILER_PATH}"
    REQUIRED)

find_program(
    "CMAKE_CXX_COMPILER"
    "${ARDUINO_PROPERTIES_EXPANDED_COMPILER_CPP_CMD}"
    PATHS "${ARDUINO_PROPERTIES_EXPANDED_COMPILER_PATH}"
    REQUIRED)

find_program(
    "CMAKE_ASM_COMPILER"
    "${ARDUINO_PROPERTIES_EXPANDED_COMPILER_S_CMD}"
    "${ARDUINO_PROPERTIES_EXPANDED_COMPILER_C_CMD}"
    PATHS "${ARDUINO_PROPERTIES_EXPANDED_COMPILER_PATH}"
    REQUIRED)

__arduino_run_hooks("recipe.hooks.core.prebuild") # <------------------------------------------------ run prebuild hooks
__arduino_run_hooks("recipe.hooks.linking.prelink")
__arduino_run_hooks("recipe.hooks.prebuild")

# FIXME also handle these hooks
# https://arduino.github.io/arduino-cli/1.0/platform-specification/#pre-and-post-build-hooks-since-arduino-ide-165
# recipe.hooks.core.postbuild
# recipe.hooks.objcopy.postobjcopy
# recipe.hooks.sketch.prebuild.pattern

list( # <--------------------------------------------------------------------------------------- configure try_compile()
    APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES
    ARDUINO_BOARD                                                                                  # make it just work
    __ARDUINO_PROPERTIES_EXPANDED_CACHE                                                            # make it MUCH faster
    __ARDUINO_PROPERTIES_UNEXPANDED_CACHE
    __ARDUINO_INSTALLED_LIBRARIES_CACHE
    __ARDUINO_IMPORTED_TARGET_CACHE)

set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)                     # try_compile() doesn't provide setup() and loop()

set(CMAKE_USER_MAKE_RULES_OVERRIDE # <------------------ align object and library filenames with Arduino for convenience
    "${ARDUINO_TOOLCHAIN_DIR}/Arduino/RulesOverride.cmake")

if (CMAKE_PARENT_LIST_FILE MATCHES "CMakeSystem\\.cmake$") # <----------------- define additonal API, additional targets
    if (__ARDUINO_IMPORTED_TARGET_CACHE)
        message(STATUS "Using library cache from ${__ARDUINO_IMPORTED_TARGET_CACHE}")
        include("${__ARDUINO_IMPORTED_TARGET_CACHE}")
    else()
        set(__ARDUINO_IMPORTED_TARGET_CACHE "${CMAKE_BINARY_DIR}/ArduinoFiles/ArduinoLibraries.cmake")
        file(WRITE "${__ARDUINO_IMPORTED_TARGET_CACHE}" "# Generated from toolchain\n")
    endif()

    if (NOT CMAKE_PROJECT_NAME STREQUAL ArduinoCore) # FIXME Rather check for __ARDUINO_CORE_FILEPATH
        __arduino_add_arduino_core_library()
    endif()

    cmake_language( # <------------------------------------------------------------------------ finalize, polish targets
        DEFER CALL cmake_language
        EVAL CODE "__arduino_toolchain_finalize(\"\${CMAKE_SOURCE_DIR}\")")

    __arduino_option( # <--------------------------------------- define and describe the toolchain's optional parameters
        BOOL ARDUINO_UPLOAD_VERBOSE "${ARDUINO_UPLOAD_VERBOSE}"
        "Enable verbose logging when uploading compiled sketches.")

    __arduino_option(
        STRING ARDUINO_UPLOAD_SERIAL_PORT "COM3" "UNIX" "/dev/ttyacm0"
        "The serial port to use for uploading compiled sketches.")
    __arduino_option(
        STRING ARDUINO_UPLOAD_PROTOCOL "serial"
        "The protocol to use for uploading compiled sketches.")
    __arduino_option(
        STRING ARDUINO_UPLOAD_SPEED "115200"
        "The transfer speed when uploading compiled sketches.")

    __arduino_option(
        STRING ARDUINO_UPLOAD_NETWORK_ADDRESS "192.168.4.1"
        "The host address for uploading compiled sketches via Arduino OTA.")
    __arduino_option(
        STRING ARDUINO_UPLOAD_NETWORK_PORT "8266" "ARDUINO_BOARD_CORE MATCHES \"esp32\"" "3232"
        "The network port for uploading compiled sketches via Arduino OTA.")

    __arduino_option(
        STRING ARDUINO_UPLOAD_NETWORK_ENDPOINT_UPLOAD "/pgm/upload"
        "The upload endpoint's path of the Arduino OTA service.")
    __arduino_option(
        STRING ARDUINO_UPLOAD_NETWORK_ENDPOINT_SYNC "/pgm/sync"
        "The sync endpoint's path of the Arduino OTA service.")
    __arduino_option(
        STRING ARDUINO_UPLOAD_NETWORK_ENDPOINT_RESET "/log/reset"
        "The reset endpoint's path of the Arduino OTA service.")
    __arduino_option(
        STRING ARDUINO_UPLOAD_NETWORK_SYNC_RETURN "204:SYNC"
        "The additional sync parameters of the Arduino OTA service.")

    define_property( # <-------------------------------------------------- document the toolchain's mandatory parameters
        CACHED_VARIABLE PROPERTY ARDUINO_BOARD BRIEF_DOCS
        "The FQBN of the Arduino device for which this project shall be built."
        "See https://arduino.github.io/arduino-cli/1.0/FAQ/#whats-the-fqbn-string for details.")
endif()

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

        set(_target "Arduino${_name}") # <-------------------------- create an INTERFACE library for the Arduino library
        add_library("${_target}" INTERFACE)

        string(JSON _install_dirpath GET "${_library}" install_dir)
        string(JSON  _source_dirpath GET "${_library}"  source_dir)
        string(JSON        _location GET "${_library}"    location)

        target_include_directories("${_target}" INTERFACE "${_source_dirpath}")
        target_link_libraries("${_target}" INTERFACE Arduino::Core)

        add_library("Arduino::${_name}" ALIAS "${_target}")
        message(TRACE "Arduino library ${_name} found: version ${_version}, ${_location}")
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
    # while filling the alias variables in __arduino_find_board_details().
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
        message(WARNING "TARGET specific property expansions are not supported yet") # FIXME implement this
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
    message(VERBOSE "running hook ${HOOK_NAME}")

    foreach(_index RANGE 1 99)
        __arduino_get_hook_command("${HOOK_NAME}" ${_index} _command)

        if (_command) # the hook sequence is not continous; it is common to skip indexes
            execute_process(
                COMMAND ${_command} RESULT_VARIABLE _result
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

                message(FATAL_ERROR "${_error_message}")
            endif()
        endif()
    endforeach()
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Converts a shell quoted command string into a COMMAND list for execute_process().
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_make_command_list SHELL_QUOTED OUTPUT_VARIABLE)
    set(_quoted   "\"([^\"]*)\"")   # quoted command line argument
    set(_literal  "([^\"\t ]+)")    # literal command line argument without spaces or quotes
    set(_tail     "[ \t]+(.*)|$")   # the next argument separating space and the remaining text
    set(_argument "${_quoted}|${_literal}")

    set(_command "${SHELL_QUOTED}")
    set(_command_list)

    while (_command AND _command MATCHES "^(${_argument})(${_tail})") # <------------------------ split the command line
        list(APPEND _command_list "${CMAKE_MATCH_2}${CMAKE_MATCH_3}") # one of them
        set(_command "${CMAKE_MATCH_5}")
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
function(__arduino_set_default VARIABLE DEFAULT_VALUE)
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

# ======================================================================================================================
# Internal utility functions that find Arduino components and configurations.
# ======================================================================================================================

# ----------------------------------------------------------------------------------------------------------------------
# Finds the `arduini-cli` tool which is the entire toolchain file's backend.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_find_arduino_cli)
    find_program(
        ARDUINO_CLI_EXECUTABLE
        arduino-cli REQUIRED

        HINTS
            [HKLM/SOFTWARE/Arduino CLI;InstallDir]
            "$ENV{PROGRAMFILES}/Arduino CLI"
        )
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Collects build properties for the current board from arduino-cli,
# and stores them in prefixed CMake variables.
#
# See `arduino_get_property()` and `__arduino_property_to_variable()`.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_find_board_details MODE)
    if (MODE STREQUAL UNEXPANDED) # <---------------------------------------------------------- parse function arguments
        set(_property_mode UNEXPANDED)
    elseif (MODE STREQUAL EXPANDED)
        set(_property_mode)
    else()
        message(FATAL_ERROR "Unsupported mode: ${MODE}")
        return()
    endif()

    string(TOLOWER "${MODE}" _mode)
    message(TRACE "Searching Arduino ${_mode} build properties...")

    execute_process( # <--------------------------------------------------------------------------- run arduino-cli tool
        COMMAND "${ARDUINO_CLI_EXECUTABLE}"
            board details --fqbn "${ARDUINO_BOARD}"
            --show-properties=${_mode} --format=text

        ENCODING UTF-8
        COMMAND_ERROR_IS_FATAL ANY
        OUTPUT_STRIP_TRAILING_WHITESPACE
        OUTPUT_VARIABLE _properties)

    file(WRITE "${CMAKE_BINARY_DIR}/ArduinoFiles/preferences-${_mode}.txt" "${_properties}")
    string(REGEX REPLACE "[ \t\r]*\n" ";" _property_list "${_properties}") # <------ set CMake variables from properties

    foreach (_property IN LISTS _property_list)
        if (_property MATCHES "([^=]+)=(.*)")
            set(_property_name  "${CMAKE_MATCH_1}")
            set(_property_value "${CMAKE_MATCH_2}")

            __arduino_property_to_variable("${_property_name}" _variable ${_property_mode})

            if (_variable MATCHES "_PATH$")
                cmake_path(CONVERT "${_property_value}" TO_CMAKE_PATH_LIST _property_value)
            endif()

            set("${_variable}" "${_property_value}" PARENT_SCOPE)
        elseif (_property)
            message(FATAL_ERROR "Unexpected output from arduino-cli tool: ${_property}")
            return()
        endif()
    endforeach()

    list(LENGTH _property_list _count)
    message(TRACE "Searching Arduino build properties: ${_count} properties found")
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Collects available libraries for the current board from arduino-cli.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_find_libraries)
    message(TRACE "Searching installed Arduino libraries...")

    execute_process(
        COMMAND "${ARDUINO_CLI_EXECUTABLE}"
            lib list --fqbn "${ARDUINO_BOARD}" --json

        ENCODING UTF-8
        COMMAND_ERROR_IS_FATAL ANY
        OUTPUT_STRIP_TRAILING_WHITESPACE
        OUTPUT_VARIABLE _json)

    file(WRITE "${CMAKE_BINARY_DIR}/ArduinoFiles/libraries.json" "${_json}")
    string(JSON _installed_libraries GET "${_json}" installed_libraries)
    string(JSON _count LENGTH "${_installed_libraries}")

    message(TRACE "Searching installed Arduino libraries: ${_count} libraries found")
    set(__ARDUINO_INSTALLED_LIBRARIES "${_installed_libraries}" PARENT_SCOPE)
endfunction()

# ======================================================================================================================
# Internal utility functions that manipulate CMake targets.
# ======================================================================================================================

# ----------------------------------------------------------------------------------------------------------------------
# Creates an import library for Android's core library.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_add_arduino_core_library)
    add_library(ArduinoCore INTERFACE)

    target_include_directories(
        ArduinoCore INTERFACE
        "${ARDUINO_PROPERTIES_EXPANDED_BUILD_CORE_PATH}"
        "${ARDUINO_PROPERTIES_EXPANDED_BUILD_SYSTEM_PATH}"
        "${ARDUINO_PROPERTIES_EXPANDED_BUILD_VARIANT_PATH}")

    # FIXME
    target_link_libraries(
        ArduinoCore INTERFACE
        "C:/Users/Mathias/AppData/Local/Temp/arduino/cores/591583add5880351c432cdac5904e8cc/core.a")

    add_library(Arduino::Core ALIAS ArduinoCore)
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

    arduino_get_property(
        "tools.${_tool_name}.upload.pattern" _command
        CONTEXT "tools.${_tool_name}" TARGET "${TARGET}")

    __arduino_make_command_list("${_command}" _command_list)

    add_custom_target(
        "${UPLOAD_TARGET}" DEPENDS "${FIRMWARE_FILENAME}"
        COMMENT "Uploading ${FIRMWARE_FILENAME} to attached device"
        COMMAND ${_command_list}
    )
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Iterates all subdirectories of the project and finalizes Arduino sketches.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_toolchain_finalize DIRECTORY)
    get_property( # <-------------------------------------------------------- iterate build targets in current directory
        _target_list DIRECTORY "${DIRECTORY}"
        PROPERTY BUILDSYSTEM_TARGETS)

    foreach(_target IN LISTS _target_list)
        get_property(_source_list TARGET "${_target}" PROPERTY SOURCES)
        set(_is_sketch NO)

        foreach(_filename IN LISTS _source_list)
            if (_filename MATCHES "\\.(ino|pde)\$") # <--------------------------------------- finalize Arduino sketches
                message(TRACE "Finalizing Arduino sketch ${_filename} in ${DIRECTORY}")

                set_property( # <-------------------------------------- tell CMake that Arduino sketches are in fact C++
                    SOURCE "${_filename}"
                    DIRECTORY "${DIRECTORY}"
                    PROPERTY LANGUAGE CXX)

                set_property( # <-------------------------- also tell the compiler that Arduino sketches are in fact C++
                    SOURCE "${_filename}"
                    DIRECTORY "${DIRECTORY}"
                    APPEND PROPERTY COMPILE_OPTIONS --lang c++)

                set(_is_sketch YES) # FIXME also check target type?
            endif()
        endforeach()

        if (_is_sketch)
            target_link_libraries("${_target}" PUBLIC Arduino::Core) # <---------------------------- let's be convenient
            set_property(TARGET "${_target}" PROPERTY SUFFIX ".elf") # <----------------------- avoid pointless rebuilds
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

__arduino_find_arduino_cli() # <----------------------------------------------------------- find components and settings
__arduino_find_board_details(EXPANDED)
__arduino_find_board_details(UNEXPANDED)
__arduino_find_libraries()

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

# FIXME also handle these hooks - maybe invoking them fixes the segment size issue for GlockeDeluxe
# recipe.hooks.core.postbuild
# recipe.hooks.objcopy.postobjcopy
# recipe.hooks.sketch.prebuild.pattern

list(APPEND CMAKE_TRY_COMPILE_PLATFORM_VARIABLES ARDUINO_BOARD) # <----------------------------- configure try_compile()
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY) #                     try_compile() doesn't provide setup() and loop()

cmake_path(GET CMAKE_CURRENT_LIST_FILE PARENT_PATH ARDUINO_TOOLCHAIN_DIR) # <---------- really use ".o" for object files
set(CMAKE_USER_MAKE_RULES_OVERRIDE "${ARDUINO_TOOLCHAIN_DIR}/Arduino/RulesOverride.cmake")

if (CMAKE_PARENT_LIST_FILE MATCHES "CMakeSystem\\.cmake$") # <----------------- define additonal API, additional targets
    __arduino_add_arduino_core_library()

    cmake_language( # <------------------------------------------------------------------------ finalize, polish targets
        DEFER CALL cmake_language
        EVAL CODE "__arduino_toolchain_finalize(\"\${CMAKE_SOURCE_DIR}\")")

    __arduino_set_default(ARDUINO_UPLOAD_VERBOSE NO)# <------------ set defaults for the toolchain's optional parameters
    __arduino_set_default(ARDUINO_UPLOAD_SERIAL_PORT                "COM3" "UNIX" "/dev/ttyacm0")
    __arduino_set_default(ARDUINO_UPLOAD_NETWORK_ADDRESS            "192.168.4.1")
    __arduino_set_default(ARDUINO_UPLOAD_NETWORK_PORT               "8266"
                          "ARDUINO_BOARD_CORE MATCHES \"esp32\""    "3232")
    __arduino_set_default(ARDUINO_UPLOAD_NETWORK_ENDPOINT_UPLOAD    "/pgm/upload")
    __arduino_set_default(ARDUINO_UPLOAD_NETWORK_ENDPOINT_SYNC      "/pgm/sync")
    __arduino_set_default(ARDUINO_UPLOAD_NETWORK_ENDPOINT_RESET     "/log/reset")
    __arduino_set_default(ARDUINO_UPLOAD_NETWORK_SYNC_RETURN        "204:SYNC")

    define_property( # <---------------------------------------------- document the toolchain's configuration parameters
        CACHED_VARIABLE PROPERTY ARDUINO_BOARD BRIEF_DOCS
        "The FQBN of the Arduino device for which this project shall be built."
        "See https://arduino.github.io/arduino-cli/1.0/FAQ/#whats-the-fqbn-string for details.")

    set(ARDUINO_UPLOAD_SERIAL_PORT "${ARDUINO_UPLOAD_SERIAL_PORT}"
        CACHE STRING "The serial port to use for uploading compiled sketches.")
    set(ARDUINO_UPLOAD_NETWORK_ADDRESS "${ARDUINO_UPLOAD_NETWORK_ADDRESS}"
        CACHE STRING "The host address for uploading compiled sketches via ArduinoOTA.")
    set(ARDUINO_UPLOAD_NETWORK_PORT "${ARDUINO_UPLOAD_NETWORK_PORT}"
        CACHE STRING "The network port for uploading compiled sketches via ArduinoOTA.")
    set(ARDUINO_UPLOAD_VERBOSE "${ARDUINO_UPLOAD_VERBOSE}"
        CACHE BOOL "Enable verbose logging when uploading compiled sketches.")
endif()

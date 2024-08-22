include(Arduino/ScriptMode NO_POLICY_SCOPE)
include("${ARGUMENTS}" OPTIONAL)

arduino_script_require(
    ARDUINO_CTAGS_EXECUTABLE        # the full path to the ctags executable used by arduino-cli
    PREPROCESS_MODE                 # the preprocessing mode: "SKETCH" or "SOURCE"
    PREPROCESS_SOURCE_DIRPATH       # base directory for for source files
    PREPROCESS_SOURCE_FILENAME      # the path of the source file to preprocess
    PREPROCESS_OUTPUT_DIRPATH       # base directory for preprocessed sketches
    PREPROCESS_OUTPUT_FILEPATH      # where to store the preprocessed code

    OPTIONAL
    PREPROCESS_OTHER_SKETCHES       # additional sketches which get merged with `PREPROCESS_SOURCE_FILENAME`
)

# ----------------------------------------------------------------------------------------------------------------------
# Runs ctags on `FILEPATH...` and reports the findings from ctags in `OUTPUT_VARIABLE`
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_ctags OUTPUT_VARIABLE FILEPATH) # [FILEPATH...]
    # FIXME figure out why android-cli also collects structs and variables (--c++-kinds=svpf)

    execute_process(
        COMMAND "${ARDUINO_CTAGS_EXECUTABLE}"
        --language-force=C++ --c++-kinds=pf --fields=KSTtzns
        --sort=no -nf - ${ARGN} "${OUTPUT_FILEPATH}"
        OUTPUT_VARIABLE _ctags_output RESULT_VARIABLE _result)

    if (NOT _result EQUAL 0)
        message(FATAL_ERROR "Running ctags has failed on ${OUTPUT_FILEPATH}:\n${_ctags_output}")
        return()
    endif()

    string(REPLACE ";" ":" _ctags_output "${_ctags_output}")
    string(REPLACE "\n" ";" _ctags_output "${_ctags_output}")

    set("${OUTPUT_VARIABLE}" ${_ctags_output} PARENT_SCOPE)
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Runs ctags on `FILEPATH...` and reports the findings from ctags in `OUTPUT_VARIABLE`
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_preprocess_sketches SOURCE_DIRPATH MAIN_FILENAME OTHER_FILENAME_LIST OUTPUT_DIRPATH OUTPUT_FILEPATH)
    message(VERBOSE "Preprocessing ${MAIN_FILENAME} as Arduino sketch")

    unset(_combined_text) # <----------------------------------------- combine all the sketches into one single C++ file

    foreach(_filename IN ITEMS "${MAIN_FILENAME}" LISTS OTHER_FILENAME_LIST)
        cmake_path(
            ABSOLUTE_PATH _filename
            BASE_DIRECTORY "${SOURCE_DIRPATH}"
            OUTPUT_VARIABLE _filepath)

        message(VERBOSE "  Merging ${_filepath}")
        file(READ "${_filepath}" _text)

        string(APPEND _combined_text "${_hash}line 1 \"${_filepath}\"\n${_text}")
    endforeach()

    file(WRITE "${OUTPUT_FILEPATH}" "${_combined_text}")

    set(ENV{TMP} "${OUTPUT_DIRPATH}/ctags/first-run")       # work around Arduino's ctags having problems with tempfiles
    file(MAKE_DIRECTORY "$ENV{TMP}")

    __arduino_ctags(_symbols "${OUTPUT_FILEPATH}" --line-directives=no) # <-------- find first declaration in merged C++

    list(GET _symbols 0 _first_symbol)

    if (NOT _first_symbol MATCHES "\tline:([0-9]+).*")
        message(FATAL_ERROR "Could not find any symbols in ctags output")
        return()
    else()
        math(EXPR _line_before_first_symbol "${CMAKE_MATCH_1} - 2")
    endif()

    set(ENV{TMP} "${OUTPUT_DIRPATH}/ctags/second-run")      # work around Arduino's ctags having problems with tempfiles
    file(MAKE_DIRECTORY "$ENV{TMP}")

    __arduino_ctags(_symbols "${OUTPUT_FILEPATH}" --line-directives=yes) # <------- extract declarations from merged C++

    unset(_prototypes)
    unset(_first_symbol_tags)

    foreach(_line IN LISTS _symbols)
        string(REGEX REPLACE ".*\tkind:([^\t]+).*"          "\\1" _type     "${_line}")
        string(REGEX REPLACE "^([^\t]+)\t.*"                "\\1" _name     "${_line}")
        string(REGEX REPLACE ".*\tsignature:([^\t]+).*"     "\\1" _args     "${_line}")
        string(REGEX REPLACE ".*\treturntype:([^\t]+).*"    "\\1" _return   "${_line}")
        string(REGEX REPLACE "^[^\t]+\t([^\t]+)\t.*"        "\\1" _filepath "${_line}")
        string(REGEX REPLACE ".*\tline:([^\t]+).*"          "\\1" _line     "${_line}")

        if (NOT _filepath)
            continue()
        endif()

        string(REPLACE "${OUTPUT_DIRPATH}/" "" _filepath "${_filepath}") # <---------- repair paths for ctags on Windows
        string(APPEND _prototypes "${_hash}line ${_line} \"${_filepath}\"\n")

        if (NOT _first_symbol_tags)
            set(_first_symbol_tags "${_prototypes}")
        endif()

        string(APPEND _prototypes "${_return} ${_name}${_args};\n")
    endforeach()

    string(APPEND _prototypes "${_first_symbol_tags}") # <----------------------- preserve position of first declaration

    unset(_text_before_first_symbol) # <------------------------------- backup all the code before the first declaration

    if (_line_before_first_symbol)
        foreach(_index RANGE ${_line_before_first_symbol})
            string(APPEND _text_before_first_symbol "[^\n]*\n")
        endforeach()
    endif()

    if (_text_before_first_symbol)
        string(REGEX MATCH "^${_text_before_first_symbol}" _match "${_combined_text}")
        string(LENGTH "${_match}" _length)
    else()
        set(_length 0)
    endif()

    string(SUBSTRING "${_combined_text}" 0 ${_length} _before_prototypes) # <------- split code around first declaration
    string(SUBSTRING "${_combined_text}" ${_length} -1 _after_prototypes)

    file(WRITE "${OUTPUT_FILEPATH}" # <------------------------------------ rebuild source code with injected prototypes
         "${_hash}include <Arduino.h>\n"
         "${_before_prototypes}"
         "${_prototypes}"
         "${_after_prototypes}")
 endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# Simply copies SOURCE_FILEPATH to OUTPUT_FILEPATH and prepends a preprocessor directive
# to track the origin of this file for user-friendly compiler errors.
# ----------------------------------------------------------------------------------------------------------------------
function(__arduino_preprocess_regular_sources SOURCE_DIRPATH SOURCE_FILENAME OUTPUT_FILEPATH)
    message(VERBOSE "Preprocessing ${SOURCE_FILENAME} as regular source code")

    cmake_path(
        ABSOLUTE_PATH SOURCE_FILENAME
        BASE_DIRECTORY "${SOURCE_DIRPATH}"
        OUTPUT_VARIABLE _filepath)

    file(READ "${_filepath}" _text)

    file(WRITE "${OUTPUT_FILEPATH}"
        "${_hash}line 1 \"${_filepath}\"\n"
        "${_text}")
endfunction()

# ----------------------------------------------------------------------------------------------------------------------
# The main routine of this module.
# ----------------------------------------------------------------------------------------------------------------------
if (PREPROCESS_MODE STREQUAL "SKETCH")
    __arduino_preprocess_sketches(
        "${PREPROCESS_SOURCE_DIRPATH}" "${PREPROCESS_SOURCE_FILENAME}" "${PREPROCESS_OTHER_SKETCHES}"
        "${PREPROCESS_OUTPUT_DIRPATH}" "${PREPROCESS_OUTPUT_FILEPATH}")
elseif (PREPROCESS_MODE STREQUAL "SOURCE")
    __arduino_preprocess_regular_sources(
        "${PREPROCESS_SOURCE_DIRPATH}" "${PREPROCESS_SOURCE_FILENAME}"
        "${PREPROCESS_OUTPUT_FILEPATH}")
else()
    message(FATAL_ERROR "Invalid mode ${PREPROCESS_MODE}")
endif()

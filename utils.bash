#!/bin/bash

# Safeguards
#   -u not specified because of associative array use
#   -e not specified to allow proper error management
set -o pipefail
IFS=$'\n\t'

# Input parameters
declare -i  should_move_files
export      should_move_files

declare -i  is_dry_run
export      is_dry_run

# Execution variables
declare -A  input_stream_data
export      input_stream_data

declare     output_extension
export      output_extension

declare     HELP_TEXT
export      HELP_TEXT

# Constants
declare -r      FOLDER_FORBIDDEN_CHARS='{}|\<:>?*"'
export          FOLDER_FORBIDDEN_CHARS
declare -r      FORBIDDEN_EXTRA_CHARS="${FORBIDDEN_CHARS}/"
export          FORBIDDEN_EXTRA_CHARS
declare -r -a   ACCEPTED_SOURCE_CODECS=("flac" "ogg" "dsf" "mp3" "m4a")
export          ACCEPTED_SOURCE_CODECS

declare -r COMMON_HELP_TEXT="Common parameters:
    -l  --log-level                 Log level, between 0 and 3, both included.
                                        0: quiet            (only errors)
                                        1: standard         (default)
                                        2: verbose          (debug logs)
                                        3: HYPER-verbose    (set -x)
Common flags:
    -dy --dry-run                   Do not touch or create any file, but prompt what would
                                    have been done.
    -mv --move                      Delete original files.
    -h  --help                      Display help"

################################################################################
# Functions to output workflow feedback to user.
# Returns:
#   echoes          text given in parameter
################################################################################
declare -i  log_level
export      log_level

function err () {
  echo "[Error]: ${*}" >&2
}

function log () {
    if [[ ${log_level} -ge 1 ]] ; then
        echo "[Info ]: ${*}" > /dev/tty
    fi
}

function debug () {
    if [[ ${log_level} -eq 2 ]] ; then
        echo "[Debug]: ${*}" > /dev/tty
    fi
}

################################################################################
# Checks if a path exists and is a directory. Optionally, creates it or prompts
# choice to user.
# Arguments:
#   target!         *path* to check
#   should_prompt?  *flag* whether prompts user for creation
#                       0: create folder if missing
#                       1: prompt user for creation
# Returns:
#   0               directory was created
#   1               invalid user choice during prompt
#   2               user refused creation
#   3               path led to a file
#   4               path contains forbidden chars
################################################################################
function check_path_exists_and_is_directory () {
    local _target="${1}"
    local _should_prompt_decision="${2:-${2:-0}}"

    if [[ ${_target} =~ [${FORBIDDEN_CHARS}] ]] ; then
        return 4
    fi

    if [[ ! -d ${_target} ]] ; then
        if [[ -f ${_target} ]] ; then
            return 3
        fi
        if [[ ${_should_prompt_decision} -eq 0 ]] ; then
            mkdir -p "${_target}"
            log "Created ${_target}"
            return 0
        fi

        echo "${_target} does not exist" > /dev/tty
        read -p "Do you want to create it ? (y/n) : " -n 1 -r
        echo > /dev/tty
        case "${REPLY}" in
            y|Y )
                mkdir -p "${_target}"
                log "Created ${_target}"
                return 0 ;;
            n|N ) return 2 ;;
            * ) return 1 ;;
        esac
    fi
    # directory exists
    return 0
}

################################################################################
# Analyzes a music file using ffprobe.
# Parameters:
#   input!                  *path* of the file to analyze
#   should_keep_tags_only?  *flag* to keep tag only. defaults to 0.
# Global companion:
#   RAW_MUSIC_FILE_STREAM  use this global var to obtain the result afterwards.
################################################################################
declare -a RAW_MUSIC_FILE_STREAM
export     RAW_MUSIC_FILE_STREAM

function ffprobe_music_file () {
    RAW_MUSIC_FILE_STREAM=()
    local _input="${1}"
    local _should_keep_tags_only="${2:-${2:-0}}"
    if [[ ${_should_keep_tags_only} -eq 1 ]] ; then
        local _grep_key="TAG:"
    else
        local _grep_key="="
    fi

    readarray -t RAW_MUSIC_FILE_STREAM < <(ffprobe                        \
                                           -v fatal                     \
                                           -print_format default        \
                                           -show_streams:a "${_input}"  \
                                           | grep "${_grep_key}"        \
                                           | sed s/TAG://               \
                                           | sed s/DISPOSITION://)

    for i in "${!RAW_MUSIC_FILE_STREAM[@]}" ; do
        if [[ -z ${RAW_MUSIC_FILE_STREAM[$i]} ]] ; then
            unset 'RAW_MUSIC_FILE_STREAM[$i]';
        fi
    done

    debug "Probed ${#RAW_MUSIC_FILE_STREAM[@]} tags"
}

################################################################################
# Format an ffprobe-obtained stream of data to a dictionary. "default" format
# is expected for the stream.
# Global companion:
#   DICTIONARY  use this global var to obtain the result afterwards.
# Return:
#   0           situation nominal
#   1           key was probably corrupted
################################################################################
declare -A  DICTIONARY
export      DICTIONARY

function music_data_to_dictionary () {
    DICTIONARY=()

    for _data in "${@}" ; do
        if [[ -z ${_data} ]] ; then
          return 1
        fi

        local _key="${_data%=*}"
              _key="${_key^^}"
              _key="${_key/[_ ]/}"
        local _value="${_data#*=}"

        debug "Parsed data: '[${_key}]=${_value}'"
        DICTIONARY+=( [${_key}]="${_value}" )
        case "${?}" in
            0) ;;
            1) return 1 ;;
        esac
    done
}

################################################################################
# Find music files in a specified directory and populate a global var.
# Global companion:
#   MUSIC_FILES   use this global var to obtain the result afterwards.
################################################################################
declare -a MUSIC_FILES
export     MUSIC_FILES

function find_music_files () {
    local _source="${1}"

    declare -a find_cmd_flags
    MUSIC_FILES=()

    find_cmd_flags=(-type f)
    for extension in "${ACCEPTED_SOURCE_CODECS[@]}" ; do
        if [[ ${extension} == "${ACCEPTED_SOURCE_CODECS[-1]}" ]] ; then
            find_cmd_flags+=(-name *."${extension}")
        else
            find_cmd_flags+=(-name *."${extension}" -o)
        fi
    done

    debug "Find command is \`find '${_source}' ${find_cmd_flags[*]}\`"
    readarray -t MUSIC_FILES < <(find "${_source}" "${find_cmd_flags[@]}")
}

################################################################################
# Extract a piece of data about a music file value from the list of
# available key/value.
# Arguments:
#   needle!               *string* to search for.
# Use globals:
#  +input_stream_data!*   *key/value*-formatted music file data
# Returns:
#   echoes          extracted value
#   0               nominal
#   1               no value found
################################################################################
function extract_music_file_data () {
    local _needle="${1}"

    if [[ ${_needle} == "extension" ]] ; then
        echo "${output_extension}"
        return 0
    fi

    if [[ -n ${input_stream_data[$_needle]} ]] ; then
        echo "${input_stream_data[$_needle]}"
        return 0
    fi

    return 1
}

################################################################################
# Formats path with trailing slash if needed.
# Arguments:
#   base!           *path* to format.
# Returns:
#   echoes          formatted path
################################################################################
function add_trailing_slash () {
    local _base="${1}"
    _last=${_base:(-1)}

    if [[ ! ${_last} == "/" ]] ; then
        debug "Added trailing slash to ${1}"
        echo "${_base}/"
    else
        debug "No trailing slash added to ${1}"
        echo "${_base}"
    fi
}

################################################################################
# Formats path without trailing slash if needed.
# Arguments:
#   base!           *path* to format.
# Returns:
#   echoes          formatted path
################################################################################
function remove_trailing_slash () {
    local _base="${1}"
    _last=${_base:(-1)}

    if [[ ${_last} == "/" ]] ; then
        debug "Removed trailing slash of ${1}"
        echo "${_base::-1}"
    else
        debug "No trailing slash in ${1}"
        echo "${_base}"
    fi
}

################################################################################
# Check input folder argument.
# Error codes:
#   0       execution nominal, path leads to a valid folder
#   1       user-related error (forbidden chars in path)
#   2       path is missing or blank
#   3       path exists but is wrong (file or missing permissions)
################################################################################
function check_input_argument () {
    # Check if path is null / empty
    debug "${1}"
    if [[ -z ${1} ]] ; then
        err "Input parameter is missing or empty (--input <path> must be set)"
        return 2
    fi

    # Folder checks
    local _source=$(remove_trailing_slash "${1}")
    check_path_exists_and_is_directory "${_source}"
    case "${?}" in
        0 ) ;;
        3 ) err "Path exists but is a file rather than directory";  return 3 ;;
        4 ) err "Input path contains forbidden characters";         return 1 ;;
    esac

    # Folder permissions check
    if [[ ! -d ${_source} ]] ; then
        err "Input folder must be a valid directory (${_source})"
        return 3
    fi
    if [[ ! -r ${_source} ]] ; then
        err "Lacking READ permissions on input folder (${_source})"
        return 3
    fi

    source="${_source}"
}

################################################################################
# Check output folder argument.
# Error codes:
#   0       execution nominal, path leads to a valid folder
#   1       user-related error (refusal or forbidden chars in path)
#   2       path is missing or blank
#   3       path exists but is wrong (file or missing permissions)
################################################################################
function check_output_argument () {
    # Check folder path
    if [[ -z ${1} ]] ; then
        err "Output parameter is missing (--output <path> must be set)"
        return 2
    fi

    # Folder checks
    local _target=$(remove_trailing_slash "${1}")
    check_path_exists_and_is_directory "${_target}" 1
    case "${?}" in
        0 ) ;;
        1 ) err "Invalid choice";                                   return 1 ;;
        2 ) log "Directory was not created";                        return 1 ;;
        3 ) err "Path exists but is a file rather than directory";  return 3 ;;
        4 ) err "Output path contains forbidden characters";        return 1 ;;
    esac

    # Folder permissions check
    if [[ ! -w ${_target} ]] ; then
        err "Lacking READ permissions on output folder (${_target})"
        return 3
    fi

    target="${_target}"
}

################################################################################
# Parse common arguments such as the log level.
# Error codes:
#   0       execution nominal, parsed an argument correctly
#   1       could not parse argument
#   2       end of argument list reached (should not happen)
# Global companion:
#   SHIFT   *int* indicating how much the script argument list should be
#           shifted by
################################################################################
declare -i  SHIFT
export      SHIFT
function parse_common_argument () {
    if [[ -z ${1+x} ]] ; then
        return 1
    fi

    case "${1}" in
        -mv | --move)
            should_move_files=1
            readonly should_move_files
            SHIFT=1
            return 0
            ;;
        -h | --help)
            display_help
            return 10
            ;;
        -l | --log-level)
            if [[ ! "${2}" =~ ^[0-3]$ ]] ; then
                err "The log level parameter only accepts integer values (between 0-3, both included)"
                return 2
            fi
            if [[ ${2} -eq 3 ]] ; then
                set -x
            fi
            log_level=${2}
            readonly log_level
            SHIFT=2
            ;;
        --) # End of all options
            SHIFT=1
            return 0
            ;;
        -*) # Unknown
            err "Unknown argument: ${1}"
            return 1
            ;;
        *)  # No more options
            debug "Should not happen"
            return 2
            ;;
    esac
}

################################################################################
# Performs operations on global common arguments:
#   - sets defaults for optional arguments
# Sets globals:
#   log_level?          *int*  between 1-3 indicating the verbosity
#   should_move_files?  *flag* indicating whether to move or copy files
#   is_dry_run?         *flag* indicating whether to effectively run the script
################################################################################
function check_common_arguments () {
    if [[ -z ${log_level+x} ]] ; then
        log_level=1
        readonly log_level
    fi
    if [[ -z ${should_move_files+x} ]] ; then
        should_move_files=0
        readonly should_move_files
    fi
    if [[ -z ${is_dry_run+x} ]] ; then
        is_dry_run=0
        readonly is_dry_run
    fi

    debug "Log level: ${log_level}"
    debug "Flag move: ${should_move_files}"
    debug "Flag dry run: ${is_dry_run}"
}

################################################################################
# Display help
# Use globals:
#   +HELP_TEXT          help text coming from the currently invoked command
#   +COMMON_HELP_TEXT   help text for common arguments
################################################################################
function display_help () {
    printf "%s\n%s" "${HELP_TEXT}" "${COMMON_HELP_TEXT}" >/dev/tty
}
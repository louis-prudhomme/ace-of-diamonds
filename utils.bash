#!/bin/bash

# Safeguards
#   -u not specified because of associative array use
#   -e not specified to allow proper error management
set -o pipefail
IFS=$'\n\t'

# Constants
declare -r -a ACCEPTED_SOURCE_CODECS=("flac" "ogg" "dsf" "mp3" "m4a")
declare -A    input_stream_data
declare       output_extension

export ACCEPTED_SOURCE_CODECS
export input_stream_data
export output_extension

################################################################################
# Functions to output workflow feedback to user.
# Returns:
#   echoes          text given in parameter
################################################################################
declare -i log_level
export log_level

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
################################################################################
function check_path_exists_and_is_directory () {
    local _target="${1}"
    local _should_prompt_decision="${2:-${2:-0}}"
# TODO prevent creation when forbidden chars such as {}
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
declare -A DICTIONARY
export DICTIONARY
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
# Use globals:
# Arguments:
#   needle!               *string* to search for.
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
# Formats path with trailing slash if needeed.
# Arguments:
#   base!           *path* to format.
# Returns:
#   echoes          formatted path
################################################################################
function add_trailing_slash () {
    local _base="${1}"

    _last=${_base:(-1)}
    debug "${_last}"

    if [[ ! ${_last} == "/" ]] ; then
      echo "${_base}/"
    else
      echo "${_base}"
    fi
}
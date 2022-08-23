#!/usr/local/bin/bash

# This script helps split music files.
# Return codes:
#   0     Execution terminated faithfully
#   1     User-related error (bad arguments)
#   2     Could not parse provided arguments (probably user-related, please otherwise)
#   3     Could not split files
#   4     Issue with input / output paths

# Safeguards
#   -u not specified because of associative array use
#   -e not specified to allow proper error management
set -o pipefail
IFS=$'\n\t'

source "./utils.bash"

# Globals
## Once set, they should be read-only
## Parameters
declare    source
declare    target
declare -a list_titles=()
declare -a list_starts=()
declare -a list_ends=()
# Constants
declare -r -A TO_MILLISECONDS_MULTIPLIERS=([h]=$(( 60*60*1000 )) [m]=$(( 60*1000 )) [s]=1000 [ms]=1)
declare -r -A DOTTED_TIME_COMPONENTS_IDENTIFIERS=([0]=s [1]=m [2]=h)
declare -r -A DOTTED_TIME_COMPONENTS_IDENTIFIERS_WITH_MS=([0]=ms [1]=s [2]=m [3]=h)

HELP_TEXT="Usage ${0} --input <FILE> --output <DIRECTORY> <TRACK SPEC>+
Parameters:
    -i  --input <FILE>          *path* to input file which will be split
    -o  --output <DIRECTORY>    *path* to output folder, into which tracks will be created

TRACK SPEC: --track <TITLE> (--start <TIME>|--end <TIME>)
-t --track                      *string* which will be used as the track's title
-s --start                      *TIME* of start of track ; optional if --end is specified.
                                If absent, the previous track end time will be taken.
                                If first track, 0 will be taken.
-e --end                        *TIME* of end of track ; optional if --start is specified.
                                If absent, the next track start time will be taken.
                                If first track, end of music file will be taken.
TIME (S[h|m|s|ms] | [HH:]MM:SS[:MS])
    S                           *int* amount of time
    h,m,s,ms                    *unit* of time (hours, minutes...)
    HH,MM,SS,MS                 *int* amount of time
Somewhat mirrored from ffmpeg time duration format
See: https://ffmpeg.org/ffmpeg-utils.html#Time-duration
"
readonly HELP_TEXT

################################################################################
# Check input path argument.
#   subject!    *path* leading to a file
# Error codes:
#   0           execution nominal, path leads to a valid file
#   1           path is missing or blank
#   2           path exists but is wrong (folder or missing permissions)
################################################################################
function check_input_argument_file () {
    local _subject="${1}"
    # Check if path is null / empty
    if [[ -z ${_subject} ]] ; then
        err "Input parameter is missing or empty (--input <file> must be set)"
        return 1
    fi

    # Folder permissions check
    if [[ ! -f ${_subject} ]] ; then
        err "Input folder must be a valid file (${_subject})"
        return 2
    fi
    if [[ ! -r ${_subject} ]] ; then
        err "Lacking READ permissions on input file (${_subject})"
        return 2
    fi
}

################################################################################
# Parse track argument declaration.
#   title!      *string* title of the track
#   args*       *array* containing remaining parameters
# Error codes:
#   0           execution nominal, path leads to a valid file
#   1           could not parse start time
#   2           could not parse end time
#   3           unknown track specifier argument
################################################################################
declare -i SHIFT
function parse_track_declaration_argument () {
    SHIFT=2
    local _title="${2}"
    local _start
    local _end
    shift 2

    while : ; do
        case "${1}" in
            -s | --start)
                parse_time_formats "${2}"
                case "${?}" in
                    0) ;;
                    *) return 1
                esac
                _start="${MILLISECONDS}"
                (( SHIFT += 2 ))
                shift 2
                ;;
            -e | --end)
                parse_time_formats "${2}"
                case "${?}" in
                    0) ;;
                    *) return 2
                esac
                _end="${MILLISECONDS}"
                (( SHIFT += 2 ))
                shift 2
                ;;
            -t | --track)
                # new track specifier
                break
                ;;
            --) # End of all options
                (( SHIFT +=1 ))
                break
                ;;
            -*) # Unknown
                return 3
                ;;
            *)  # No more options
                break
                ;;
        esac
    done

    list_titles+=( "${_title}" )
    list_starts+=( "${_start}" )
    list_ends+=( "${_end}" )
}

################################################################################
# Parse arguments.
#   args*       *array* containing parameters and options
# Error codes:
#   0           execution nominal
#   1           error while parsing common argument
#   2           unknown argument
#   3           could not parse track time specification
################################################################################
function parse_arguments () {
    declare -i _track_count=0

    while : ; do
        case "${1}" in
            -i | --input)
                # not readonly because of subsequent formatting
                source="${2}"
                shift 2
                ;;
            -o | --output)
                target="${2}"
                shift 2
                ;;
            -t | --track)
                parse_track_declaration_argument "${@}"
                case "${?}" in
                    0) debug "Parsed $(( _track_count++ + 1 ))-th track specification";;
                    1) err "Could not parse track start time";  return 3 ;;
                    2) err "Could not parse track end time";    return 3 ;;
                    3) err "Unknown argument";                  return 2 ;;
                esac
                shift "${SHIFT}"
                ;;
            --) # End of all options
                break
                ;;
            -*) # Unknown
                parse_common_arguments "${@}"
                case "${?}" in
                    0 ) debug "Parsed common argument ${1}"; shift "${SHIFT}" ;;
                    1 ) return 1  ;;
                    2 ) break     ;;
                    10) return 10 ;;
                esac
                ;;
            *)  # No more options
                break
                ;;
        esac
    done
}

################################################################################
# Parse a time argument
# Arguments:
#   subject?    *time* of start or end ; accepted formats :
#                   S[h|m|s|ms]
#                   [HH:]MM:SS[:MS]
#               somewhat mirrored from ffmpeg time duration format
#               see: https://ffmpeg.org/ffmpeg-utils.html#Time-duration
# Error codes:
#   0           execution nominal, time was parsed
#   1           dotted time had a non-standard amount of columns
#   2           time amount was not an int
################################################################################
declare -i PARSED_MILLISECONDS
function parse_dotted_time_components () {
    # necessary to avoid octal cast
    PARSED_MILLISECONDS=10#0

    # read time spec into array
    declare -a _time_components=()
    readarray -d ':' -t _time_components <<<"${1}"
    local _time_components_count="${#_time_components[@]}"

    # detect base unit (second or millisecond)
    if [[ ${_time_components_count} -eq 4 ]] ; then
        debug "Parsing millisecond-based dotted time ${1}"
        declare -n _identifiers="DOTTED_TIME_COMPONENTS_IDENTIFIERS_WITH_MS"
    elif [[ ${_time_components_count} -lt 4 && ${_time_components_count} -ne 0 ]] ; then
        debug "Parsing second-based dotted time ${1}"
        declare -n _identifiers="DOTTED_TIME_COMPONENTS_IDENTIFIERS"
    else
        err "${_time_components_count} columns detected in the dotted time specification '${1}'; must be between 0-3 included."
        return 1
    fi

    # get time amounts and and units
    declare -i _component
    declare -i _opposite
    for (( i = 0; i < _time_components_count; i++ )) ; do
        (( _opposite = i - _time_components_count + 1 ))
        _opposite="${_opposite#-}"

        _component=$(sed 's/^0*//' <<<"${_time_components[$_opposite]}")
        if [[ ! ${_component} =~ ^[0-9]+$ ]] ; then
            debug "${_component} is not a number"
            return 2
        fi
        local _unit=${_identifiers[$i]}
        local _multiplier=${TO_MILLISECONDS_MULTIPLIERS[$_unit]}
        debug "Recognized unit '${_unit}' (x${_multiplier})"
        debug "Summing amount $(( _component * _multiplier )) (${_component} * ${_multiplier}) into ${PARSED_MILLISECONDS}"
        (( PARSED_MILLISECONDS = PARSED_MILLISECONDS + _component * _multiplier ))
    done
    debug "Total is ${PARSED_MILLISECONDS}ms"
}

################################################################################
# Parse a time argument
# Arguments:
#   subject!    *time* of start or end ; accepted formats :
#                   S[h|m|s|ms]
#                   [HH:]MM:SS[:MS]
#               somewhat mirrored from ffmpeg time duration format
#               see: https://ffmpeg.org/ffmpeg-utils.html#Time-duration
# Error codes:
#   0           execution nominal, time was parsed
#   1           time was empty
#   2           could not parse dotted component
#   2           time format was not recognized
################################################################################
declare -i MILLISECONDS
function parse_time_formats () {
    MILLISECONDS=0
    local _subject="${1}"
    local _time_format
    if [[ -z "${_subject}" ]] ; then
        return 1
    fi

    # simple time
    if [[ ${_subject} =~ ^[0-9]+$ ]] ; then
        local _multiplier=${TO_MILLISECONDS_MULTIPLIERS["s"]}
        (( MILLISECONDS = _subject * _multiplier ))
        _time_format="simple time"
    # dotted time
    elif [[ ${_subject} =~ : ]] ; then
        parse_dotted_time_components "${_subject}"
        case "${?}" in
            0) ;;
            *) return 2 ;;
        esac
        MILLISECONDS=${PARSED_MILLISECONDS}
        _time_format="dotted time"
    # united time
    elif [[ ${_subject} =~ ^([0-9]+)(h|m|s|ms)$ ]] ; then
        local _quantum=${BASH_REMATCH[1]}
        local _unit=${BASH_REMATCH[2]}
        local _multiplier=${TO_MILLISECONDS_MULTIPLIERS[$_unit]}
        (( MILLISECONDS = _quantum * _multiplier ))
        _time_format="united time"
    else
        return 3
    fi
    debug "Parsed ${_subject} as ${MILLISECONDS}ms (${_time_format})"
}

################################################################################
# Performs operations on global arguments:
#   - checks if correctly set for mandatory arguments
#   - sets defaults for optional arguments
# Sets globals:
#   list_titles*?       *array* of all track titles
#   list_starts*?       *array* of all track starts
#   list_ends*?         *array* of all track endings
# Returns
#   0                   situation nominal
#   1                   could not parse source file duration
#   2                   start time superior or equal to end time
#   3                   issue with source file
#   4                   issue with target folder
#   5                   no track specification provided
################################################################################
function check_arguments_validity () {
    if [[ ${#list_titles[@]} -eq 0 ]] ; then
          return 5
    fi

    # check input / output
    check_input_argument_file "${source}"
    case "${?}" in
        0) ;;
        *) return 3;;
    esac
    check_output_argument "${target}"
    case "${?}" in
        0) ;;
        *) return 4;;
    esac

    log "Extracting source duration, which can take a long time"
    # extract and parse source music file length
    local _music_file_dotted_length=$(ffmpeg                    \
                                        -nostats                \
                                        -i "${source}"          \
                                        -f null - 2>&1          \
                                        | grep 'time='          \
                                        | cut -d ' ' -f 2       \
                                        | cut -c 6-             \
                                        | tr '.' ':')
    debug "Music file length is ${_music_file_dotted_length}"
    parse_dotted_time_components "${_music_file_dotted_length}"
    case "${?}" in
        0) ;;
        *) return 1;;
    esac
    declare -i _music_file_length="${PARSED_MILLISECONDS}"

    # compute starts and ends for each track
    for i in "${!list_titles[@]}" ; do
        if [[ -z ${list_starts[$i]} ]] ; then
            if [[ ${i} -eq 0 ]] ; then
                list_starts[$i]=0
            else
                (( _previous = i - 1 ))
                list_starts[$i]="${list_ends[$_previous]}"
            fi
            log "Computed '${list_starts[$i]}' for the start of '${list_titles[$i]}'"
        fi

        if [[ -z ${list_ends[$i]} ]] ; then
            if [[ $(( i + 1 )) -eq ${#list_titles[@]} ]] ; then
                list_ends[$i]=${_music_file_length}
            else
                (( _next = i + 1 ))
                list_ends[$i]="${list_starts[$_next]}"
            fi
            log "Computed '${list_ends[$i]}' for the end of '${list_titles[$i]}'"
        fi

        if [[ ${list_starts[$i]} -ge ${list_ends[$i]} ]] ; then
            return 2
        fi

        debug "'${list_titles[$i]}': from ${list_starts[$i]}ms to ${list_ends[$i]}ms"
    done
}

################################################################################
# Does the heavy lifting. Will split the provided music file following the spec.
# Uses globals:
#   source
#   target
#   list_titles
#   list_starts
#   list_ends
#   log_level
# Returns:
#   0                   completed split
#   1                   could not copy file (ffmpeg-related error)
################################################################################
function main () {
    local _extension="${source#*.}"
    for i in "${!list_titles[@]}" ; do
        local _destination="${target}/${list_titles[$i]}.${_extension}"

        if [[ ${is_dry_run:?} -eq 0 ]] ; then
            ffmpeg -y -i "${source}"        \
                -v error                    \
                -ss "${list_starts[$i]}ms"  \
                -to "${list_ends[$i]}ms"    \
                -c copy "${_destination}"
        else
            true # to mock return code
        fi
        case "${?}" in
            0 ) log "Created ${_destination}" ;;
            * ) err "While handling ${_destination}"; return 1 ;;
        esac
    done

    log "Finished splitting. Congratulations!"
}

# Core
parse_arguments "${@}"
case "${?}" in
    0 ) ;;
    1 ) err "Bad common argument";                  exit 1 ;;
    2 ) err "Unrecognized argument";                exit 1 ;;
    3 ) err "Could not parse time specification";   exit 2 ;;
    10) debug "Help was displayed";                 exit 0 ;;
    * ) err "Unrecognized error";                   exit 255 ;;
esac

check_common_arguments
if [[ ${should_move_files:?} -eq 1 ]] ; then
    log "Move flag enabled; in this script, it is useless."
fi
check_arguments_validity
case "${?}" in
    0 ) ;;
    1 ) err "Could not parse source file duration";     exit 2 ;;
    2 ) err "Start time superior or equal to end time"; exit 2 ;;
    3 ) err "Issue with the source file";               exit 4 ;;
    4 ) err "Issue with the target folder";             exit 4 ;;
    5 ) err "No track specification provided";          exit 1 ;;
    * ) err "Unrecognized error";                       exit 255;;
esac

main
case "${?}" in
    0 ) ;;
    1 ) err "Could not split files";    exit 3 ;;
    * ) err "Unrecognized error";       exit 255 ;;
esac

#!/usr/local/bin/bash

# TODO more useful debug logs

# Safeguards
#   -u not specified because of associative array use
#   -e not specified to allow proper error management
set -o pipefail
IFS=$'\n\t'

source "./utils.bash"

# Globals
## Once set, they should be read-only
## Parameters
declare     source
declare     target
declare     format
declare     placeholder
declare -i  flag_move
declare -i  log_level
## Execution
declare -A  input_stream_data
declare     output_extension

# CONSTANTS
## taking windows limitations in account, to guarantee maximum portability
declare -r      FORBIDDEN_CHARS='{}/|\<:>?*"'
declare -r      REPLACER_MARKER="?"
declare -r      ADDITION_MARKER="+"
declare -r      TOKEN_COMPOSITION_OPENER="{"
declare -r      TOKEN_COMPOSITION_CLOSER="}"
declare -r      TOKEN_COMPOSITION_CLOSERS="${TOKEN_COMPOSITION_CLOSER}${REPLACER_MARKER}${ADDITION_MARKER}"
declare -r      DEFAULT_PLACEHOLDER="_"
declare -r      DEFAULT_FORMAT="{album_artist}/{orig_year?year+ – }{album}/{disc+-}{track?track_number} – {title}.{extension}"
declare -r  -A  AVAILABLE_TAGS=( [ALBUM]=ALBUM [ALBUMARTIST]=ALBUMARTIST [ARTIST]=ARTIST \
                                [BARCODE]=BARCODE [BPM]=BPM [BY]=BY [CATALOGID]=CATALOGID \
                                [CATALOGNUMBER]=CATALOGNUMBER [COMPOSER]=COMPOSER [CONDUCTOR]=CONDUCTOR \
                                [COPYRIGHT]=COPYRIGHT [COUNTRY]=COUNTRY [CREDITS]=CREDITS \
                                [DATE]=DATE [DESCRIPTION]=DESCRIPTION [DISCNUMBER]=DISCNUMBER \
                                [DISCTOTAL]=DISCTOTAL [ENCODEDBY]=ENCODEDBY [GAIN]=GAIN \
                                [GENRE]=GENRE [GROUPING]=GROUPING [ID]=ID [ISRC]=ISRC \
                                [LABEL]=LABEL [LANGUAGE]=LANGUAGE [LENGTH]=LENGTH [LOCATION]=LOCATION \
                                [LYRICS]=LYRICS [MCDI]=MCDI [MEDIA]=MEDIA [MEDIATYPE]=MEDIATYPE \
                                [NORM]=NORM [ORGANIZATION]=ORGANIZATION [ORIGYEAR]=ORIGYEAR \
                                [PEAK]=PEAK [PERFORMER]=PERFORMER [PGAP]=PGAP [PMEDIA]=PMEDIA \
                                [PROVIDER]=PROVIDER [PUBLISHER]=PUBLISHER [RELEASECOUNTRY]=RELEASECOUNTRY \
                                [SMPB]=SMPB [STYLE]=STYLE [TBPM]=TBPM [TITLE]=TITLE [TLEN]=TLEN \
                                [TMED]=TMED [TOOL]=TOOL [TOTALDISCS]=TOTALDISCS [TOTALTRACKS]=TOTALTRACKS \
                                [TRACKNUMBER]=TRACKNUMBER [TRACKTOTAL]=TRACKTOTAL \
                                [TSRC]=TSRC [TYPE]=TYPE [UPC]=UPC [UPLOADER]=UPLOADER [URL]=URL \
                                [WEBSITE]=WEBSITE [WMCOLLECTIONID]=WMCOLLECTIONID [WORK]=WORK \
                                [WWW]=WWW [WWWAUDIOFILE]=WWWAUDIOFILE [WWWAUDIOSOURCE]=WWWAUDIOSOURCE \
                                [DISC]=DISCNUMBER [TRACK]=TRACK [YEAR]=DATE \
                                [EXTENSION]=extension )

################################################################################
# Format a raw key by removing underscores and uppercase the string.
# Also, checks if the key is an accepted tag.
# Arguments:
#   raw!            *string* to format.
# Returns:
#   echoes          formatted key
#   0               valid key (not amongst AVAILABLE_TAGS)
#   1               invalid key
################################################################################
function get_tag_from_formatter () {
    local _raw="${1}"
    local _formatted="${_raw/_/}"
    local _formatted="${_formatted^^}"

    if [[ -n ${AVAILABLE_TAGS[$_formatted]+x} ]] ; then
        echo "${AVAILABLE_TAGS[$_formatted]}"
        return 0
    fi
    return 1
}

################################################################################
# Remove forbidden characters from a string, in the context of a file path.
# The placeholder will be used instead.
# Arguments:
#   subject!        *string* to replace
# Returns:
#   echoes          formatted key
################################################################################
function remove_forbidden_chars () {
    local _subject="${1}"

    echo "${_subject//[$FORBIDDEN_CHARS]/$placeholder}"
}

################################################################################
# Display help
################################################################################
function display_help () {
    cat <<EOF
Usage ${0} --input <DIRECTORY> --output <DIRECTORY> --format <PATTERN> [OPTIONS]...
Parameters:
    -i  --input <DIRECTORY>         Input folder, containing the music files
    -o  --output <DIRECTORY>        Output folder, into which music files will be transcoded
    -f  --format <PATTERN>          Pattern used to format file names.
                                    Default value is ${DEFAULT_FORMAT}.
    -p  --placeholder <CHAR>        Placeholder character used to replace forbidden characters.
                                    Default value is ${DEFAULT_PLACEHOLDER}.
    -l  --log-level                 Log level, between 0 and 3, both included.
                                        0: quiet            (only errors)
                                        1: standard         (default)
                                        2: verbose          (debug logs)
                                        3: HYPER-verbose    (set -x)
Flags:
    -mv --move                      Delete original files after transcoding.
    -h  --help                      Display help
EOF
}

################################################################################
# Compute a filename for a globally set music file.
# Arguments:
#   +format!        *pattern* to compute filename
#   +placeholder!   *char* to replace forbidden ones with
# Returns:
#   echoes          formatted filename
#   0               situation nominal
#   1               invalid format
#   2               invalid tag
################################################################################
function build_file_name () {
    ## vars
    local _raw
    local _tokens=()
    #local _aggregated will be set at some point
    ## operation flags
    local _should_zap_till_closer=0
    local _should_pile_on_till_closer=0

    while read -r -n 1 _latest ; do
        if [[ -z ${_latest} ]] ; then
            continue
        fi
        # if an addendum marker was encountered before,
        # ignore new tokens until a strict closure marker
        if [[ ${_should_zap_till_closer} -eq 1 ]] ; then
            if [[ ${_latest} == "${TOKEN_COMPOSITION_CLOSER}" ]] ; then
                _should_zap_till_closer=0
            fi
            continue
        fi
        # if an addendum marker was encountered before,
        # pile all the new tokens until any closure marker
        if [[ ${_should_pile_on_till_closer} -eq 1 ]] ; then
            if [[ ${_latest} =~ [${TOKEN_COMPOSITION_CLOSERS}] ]] ; then
                _should_pile_on_till_closer=0

                # stop handling closure, zap until it ends
                if [[ ! ${_latest} == "${TOKEN_COMPOSITION_CLOSER}" ]] ; then
                    _should_zap_till_closer=1
                fi
            else
                _tokens+=( "${_latest}" )
            fi
            continue
        fi
        
        ## currently not composing a token
        if [[ -z ${_aggregated+x} ]] ; then
            if [[ ${_latest} == "${TOKEN_COMPOSITION_CLOSERS}" ]] ; then
                return 1
            elif [[ ${_latest} == "${TOKEN_COMPOSITION_OPENER}" ]] ; then
                _aggregated=""
            else
                _tokens+=( "${_latest}" )
            fi
        ## currently composing a token
        else
            if [[ ${_latest} =~ [${TOKEN_COMPOSITION_CLOSERS}] ]] ; then
                if [[ -z ${_aggregated+x} \
                   || ${_latest} == "${TOKEN_COMPOSITION_OPENER}" ]] ; then
                    return 1
                fi
                
                _token=$(get_tag_from_formatter "${_aggregated}")
                case "${?}" in
                    0 ) ;;
                    1 ) err "Wrong token ${_aggregated}"; return 2;;
                esac
                
                unset _aggregated
                _raw="$(extract_music_file_data "${_token}")"
                case "${?}" in
                    0 ) # if value found, stop handling closure
                        _tokens+=( "$(remove_forbidden_chars "${_raw}")" )
                        
                        case "${_latest}" in
                            "${ADDITION_MARKER}" )
                                _should_pile_on_till_closer=1
                                ;;
                            "${REPLACER_MARKER}" ) 
                                _should_zap_till_closer=1 
                                ;;
                            "${TOKEN_COMPOSITION_CLOSER}" )
                                ;;
                        esac
                        ;;
                    1 ) # if tag comes up empty, check if a replacer is available
                        # or insert the placeholder character
                        case "${_latest}" in
                            "${ADDITION_MARKER}" )
                                _should_zap_till_closer=1 
                                ;;
                            "${REPLACER_MARKER}" ) 
                                _aggregated=""
                                ;;
                            "${TOKEN_COMPOSITION_CLOSER}" )
                                _tokens+=( "${placeholder}" )
                                ;;
                        esac
                        ;;
                esac
                
                unset _raw
            else
                _aggregated="${_aggregated}${_latest}"
            fi
        fi
    done <<< "${format}"

    printf "%s" "${_tokens[@]}"
    return 0
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
# Parse arguments from the command line and set global parameters.
# Arguments:
#   arguments!*         *array* of arguments from the command line
# Sets globals:
#   source!             *path* to source directory
#   target!             *path* to target directory
#   format?             *string* modeling the expected file path & name
#   flag_move?          *flag* indicating to move / delete files
#   log_level?          *integer* representing the logging level
# Returns:
#   0                   arguments parsed faithfully
#   1                   Unknown option
#   2                   Bad option
#   10                  Help displayed
################################################################################
function parse_arguments () {
    debug "Parsing arguments"
    
    while : ; do
        if [[ -z ${1+x} ]] ; then
            break
        fi

        case "${1}" in
            -i | --input)
                source="${2}"
                readonly source
                shift 2
                ;;
            -o | --output)
                target="${2}"
                readonly target
                shift 2
                ;;
            -f | --format)
                format="${2}"
                readonly format
                shift 2
                ;;
            -p | --placeholder)
                placeholder="${2}"
                readonly placeholder
                shift 2
                ;;
            -mv | --move)
                flag_move=1
                readonly flag_move
                shift 
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
                shift 2
                ;;
            --) # End of all options
                shift
                break
                ;;
            -*) # Unknown
                err "Unknown option: ${1}"
                return 1
                ;;
            *)  # No more options
                break
                ;;
        esac
    done
    debug "Parsed arguments"
}

################################################################################
# Performs operations on global arguments:
#   - checks if correctly set for mandatory arguments
#   - sets defaults for optional arguments
# Sets globals:
#   format?             *pattern* with which file name will be formatted
#   placeholder?        *char* to replace forbidden characters with
#   flag_move?          *flag* indicating to move / delete files
#   log_level?          *integer* representing the logging level
# Returns
#   0                   situation nominal
#   1                   user-related issue (wrong parameter, refusal...)
#   2                   missing parameter
#   3                   external issue (permissions, path exists as file...)
################################################################################
function check_arguments_validity () {
    # Mandatory arguments check
    if [[ -z ${source+x} || -z ${target+x} ]] ; then
        err "One or more mandatory parameters are missing (--input and --output must be set)"
        return 2
    fi

    # Input & output folder checks
    check_path_exists_and_is_directory "${target}" 1
    case "${?}" in
        0 ) log "Created ${target}" ;;
        1 ) err "Invalid directory";                                return 1 ;;
        2 ) log "Directory was not created";                        return 1 ;;
        3 ) err "Path exists but is a file rather than directory";  return 3 ;;
    esac

    # Folder permissions check
    if [[ ! -d ${source} ]] ; then
        err "Input folder must be a valid directory (${source})"
        return 3
    fi
    if [[ ! -r ${source} ]] ; then
        err "Lacking READ permissions on input folder (${source})"
        return 3
    fi
    if [[ ! -w ${target} ]] ; then
        err "Lacking READ permissions on output folder (${target})"
        return 3
    fi

    # Optional parameters
    # TODO constants
    if [[ -z ${format+x} ]] ; then
        format="${DEFAULT_FORMAT}"
        readonly format
    fi
    if [[ -z ${placeholder+x} ]] ; then
        placeholder="${DEFAULT_PLACEHOLDER}"
        readonly placeholder
    fi
    if [[ -z ${log_level+x} ]] ; then
        log_level=1
        readonly log_level
    fi
    if [[ -z ${flag_move+x} ]] ; then
        flag_move=0
        readonly flag_move
    fi

    # Debug vitals
    debug "Input: ${source}"
    debug "Output: ${target}"
    debug "Placeholder: ${placeholder}"
    debug "Log level: ${log_level}"
    debug "Flag move: ${flag_move}"
}

################################################################################
# Does the heavy lifting. Will find and organize music files using the provided
# format.
# Sets global:
#   input_stream_data
# Returns:
#   0                   completed transcoding
#   1                   no files in source
#   2                   destination folder is a file
################################################################################
function populate_target_data () {
    input_stream_data=()

    for _data in "${@}" ; do
        local _key="${_data%=*}"
              _key="${_key^^}"
              _key="${_key/[_ ]/}"
        local _value="${_data#*=}"

        debug "Parsed data: '[${_key}]=${_value}'"
        input_stream_data+=( [${_key}]="${_value}" )
    done
}

################################################################################
# Does the heavy lifting. Will find and organize music files using the provided
# format.
# Uses globals:
#   source
#   target
#   format
#   placeholder
#   flag_move
#   log_level
# Returns:
#   0                   completed transcoding
#   1                   no files in source
#   2                   destination folder is a file
################################################################################
function main () {
    declare -a find_cmd_flags
    find_cmd_flags=(-type f)
    for extension in "${ACCEPTED_SOURCE_CODECS[@]}" ; do
        if [[ ${extension} == "${ACCEPTED_SOURCE_CODECS[-1]}" ]] ; then
            find_cmd_flags+=(-name \"*."${extension}"\")
        else
            find_cmd_flags+=(-name \"*."${extension}"\" -o)
        fi
    done

    formatted_cmd_parameters="$(printf "%s " "${find_cmd_flags[@]}")"
    formatted_find_command="find ${source} ${formatted_cmd_parameters}"
    debug "Find command is \`${formatted_find_command}\`"

    # FIXME
    music_files_count=$(eval "${formatted_find_command}" | wc -l)
    #readarray -d music_files < <(find "${source}" ${find_cmd_flags[*]})
    debug "${music_files_count} files found"
    if [[ ${music_files_count} -eq 0 ]] ; then
        return 1
    fi

    music_files_handled_count=0
    # Heavy lifting
    for input in $(eval "${formatted_find_command}") ; do
        debug "Probing ${input}"
        
        # Analyze existing music file
        output_extension="${input##*.}"

        raw_stream_data=( $(ffprobe                        \
                               -v fatal                    \
                               -print_format default       \
                               -show_streams:a "${input}"  \
                               | grep -E '^TAG:'           \
                               | sed s/TAG://) )
        populate_target_data "${raw_stream_data[@]}"

        case "${?}" in
            0 ) ;;
            * ) return 3 ;;
        esac

        # Compute file name and destination
        destination=$(build_file_name)
        case "${?}" in
            0 ) ;;
            1 ) err "Failed to build file name"; return 4 ;;
        esac
        destination="${target}/${destination}"
        log "Filename built: $destination"

        # Check destination is valid
        check_path_exists_and_is_directory "$(dirname "${destination}")"
        case "${?}" in
            0 ) ;;
            3 ) err "Path exists but is a file rather than directory"; return 2 ;;
        esac

        # Move or copy file to destination
        # if [[ ${flag_move} -eq 1 ]] ; then
        #     mv "${input}" "${destination}"
        #     debug "Moved ${input} to ${destination}"
        # else
        #     cp "${input}" "${destination}"
        #     debug "Copied ${input} to ${destination}"
        # fi
        log "Done !"

        # Stats
        (( music_files_handled_count+=1 ))
        ratio=$(( (100 * music_files_handled_count) / music_files_count ))
        log "Handled ${ratio}% of all files (${music_files_handled_count}/${music_files_count})"

        unset ratio
        unset output_extension
        unset destination
        unset raw_stream_data
    done
    log "All done, congratulations!"
}

# Core
parse_arguments "${@}"
case "${?}" in
    0 | 10 ) ;;
    1 ) err "Unrecognized argument";    exit 1;;
    2 ) err "Bad argument";             exit 1;;
    * ) err "Unrecognized error";       exit 255 ;;
esac

check_arguments_validity
case "${?}" in
    0 ) ;;
    1 ) err "User input issue (wrong parameter, refusal...)";                           exit 1;;
    2 ) err "Missing parameter"; display_help;                                          exit 1;;
    3 ) err "External dysfunction (wrong permissions, path exists but is a file...)";   exit 2;;
    * ) err "Unrecognized error";                                                       exit 255;;
esac

main
case "${?}" in
    0 ) ;;
    1 ) err "No files in source";               exit 0;;
    2 ) err "Destination folder is a file";     exit 2;;
    3 ) err "Cannot parse source file data";    exit 3;;
    4 ) err "Parser-related error";             exit 4;;
    * ) err "Unrecognized error";               exit 255 ;;
esac
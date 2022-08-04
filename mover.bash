#!/bin/bash

# TODO help

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
declare -i flag_move
declare -i log_level
## Execution
declare -a input_stream_data
declare    output_extension

# CONSTANTS
declare -r    FORBIDDEN_CHARS='{}/|\<:>?*"'
declare -r    TOKEN_COMPOSITION_OPENER="{"
declare -r    TOKEN_COMPOSITION_CLOSER="}"
declare -r    PLACEHOLDER="_"
declare -r    DEFAULT_FORMAT="{album_artist}/{date} – {album}/{disc}-{track} – {title}.{extension}"
declare -r -A AVAILABLE_TAGS=( [EXTENSION]=extension [ALBUM]=ALBUM [ALBUMARTIST]=ALBUMARTIST [ARTIST]=ARTIST [BARCODE]=BARCODE [BPM]=BPM [BY]=BY [CATALOGID]=CATALOGID [CATALOGNUMBER]=CATALOGNUMBER [COMPOSER]=COMPOSER [CONDUCTOR]=CONDUCTOR [COPYRIGHT]=COPYRIGHT [COUNTRY]=COUNTRY [CREDITS]=CREDITS [DATE]=DATE [DESCRIPTION]=DESCRIPTION [DISCNUMBER]=DISCNUMBER [DISC]=DISCNUMBER [DISCTOTAL]=DISCTOTAL [ENCODEDBY]=ENCODEDBY [GAIN]=GAIN [GENRE]=GENRE [GROUPING]=GROUPING [ID]=ID [ISRC]=ISRC [LABEL]=LABEL [LANGUAGE]=LANGUAGE [LENGTH]=LENGTH [LOCATION]=LOCATION [LYRICS]=LYRICS [MCDI]=MCDI [MEDIA]=MEDIA [MEDIATYPE]=MEDIATYPE [NORM]=NORM [ORGANIZATION]=ORGANIZATION [ORIGYEAR]=ORIGYEAR [PEAK]=PEAK [PERFORMER]=PERFORMER [PGAP]=PGAP [PMEDIA]=PMEDIA [PROVIDER]=PROVIDER [PUBLISHER]=PUBLISHER [RELEASECOUNTRY]=RELEASECOUNTRY [SMPB]=SMPB [STYLE]=STYLE [TBPM]=TBPM [TITLE]=TITLE [TLEN]=TLEN [TMED]=TMED [TOOL]=TOOL [TOTALDISCS]=TOTALDISCS [TOTALTRACKS]=TOTALTRACKS [TRACKNUMBER]=TRACKNUMBER [TRACK]=TRACKNUMBER [TRACKTOTAL]=TRACKTOTAL [TSRC]=TSRC [TYPE]=TYPE [UPC]=UPC [UPLOADER]=UPLOADER [URL]=URL [WEBSITE]=WEBSITE [WMCOLLECTIONID]=WMCOLLECTIONID [WORK]=WORK [WWW]=WWW [WWWAUDIOFILE]=WWWAUDIOFILE [WWWAUDIOSOURCE]=WWWAUDIOSOURCE )

# TODO comment
function get_tag_from_formatter () {
    local _formatted="${1/_/}"
    local _formatted="${_formatted^^}"

    if [[ -n ${AVAILABLE_TAGS[$_formatted]+x} ]] ; then
        echo "${AVAILABLE_TAGS[$_formatted]}"
        return 0
    fi
    return 1
}

# TODO comment
function remove_forbidden_chars () {
    local _subject="${1}"

    echo "${_subject//[$FORBIDDEN_CHARS]/$PLACEHOLDER}"
}

function build_file_name () {
    #local _aggregated
    local _is_composing=0
    local _tokens=()
    local _n=()
    local _i=0
    local _raw

    while read -n 1 _latest ; do
        if [[ -z ${_latest} ]] ; then
            continue;
        fi
        
        ## currently not composing a token
        if [[ -z ${_aggregated+x} ]] ; then
            if [[ ${_latest} == "${TOKEN_COMPOSITION_CLOSER}" ]] ; then
                return 1 # TODO codes
            elif [[ ${_latest} == "${TOKEN_COMPOSITION_OPENER}" ]] ; then
                _aggregated=""
            else
                _tokens+=( "${_latest}" )
            fi
        ## currently composing a token
        else
            if [[ ${_latest} == "${TOKEN_COMPOSITION_CLOSER}" ]] ; then
                if [[ -z ${_aggregated+x} \
                   || ${_latest} == "${TOKEN_COMPOSITION_OPENER}" ]] ; then
                    return 1 # TODO codes
                fi
                _token=$(get_tag_from_formatter "${_aggregated}")
                case "${?}" in
                    0 ) ;;
                    1 ) err "Wrong token"; return 1;; # TODO codes
                esac
                _raw="$(extract_music_file_data "${_token}")"
                _tokens+=( "$(remove_forbidden_chars "${_raw}")" )
                unset _raw
                unset _aggregated
            else
                _aggregated="${_aggregated}${_latest}"
            fi
        fi
    done <<< "${DEFAULT_FORMAT}"

    printf "%s" "${_tokens[@]}"
}

###############################################################################
# Extract a stream value from the list of available key/value
# Arguments:
#   needle!         key to search for.
#   haystack!*      key/value stream data. 'ini' or 'flat' formats are assumed.
# Returns:
#   echoes          value obtained from
#   0               returned along with extracted value
#   1               no value found
###############################################################################
function extract_music_file_data () {
    local _needle="${1}"

    if [[ ${_needle} == "extension" ]] ; then
        echo "${output_extension}"
        return 0
    fi

    shift
    local _haystack=("${input_stream_data[@]}")

    for stream_data in "${_haystack[@]}" ; do
        if [[ ${stream_data} =~ ${_needle}=(.+)$ ]] ; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    done

    echo "${PLACEHOLDER}"
    return 1
}

###############################################################################
# Parses arguments from the command line and sets global parameters.
# Arguments:
#   arguments!*         *array* of arguments from the command line
# Sets globals:
#   source!             *path* to source directory
#   target!       *path* to target directory
#   flag_move?          *flag* indicating to move / delete files
#   log_level?          *integer* representing the logging level
# Returns:
#   0                   arguments parsed faithfully
#   1                   Unknown option
#   2                   Bad option
#   10                  Help displayed
###############################################################################
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
            -mv | --move)
                # TODO 
                flag_move=1
                readonly flag_move
                shift 
                ;;
            -h | --help)
                #display_help TODO
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

###############################################################################
# Performs operations on global arguments:
#   - checks if correctly set for mandatory arguments
#   - sets defaults for optional arguments
# Arguments:
#   none
# Sets globals:
#   target_sample_fmt?  *sample format* to transcode source files with
#   target_sample_rate? *integer* representing the wanted sample rate
#   target_quality?     *integer* representing the wanted quality
#   flag_move?          *flag* indicating to move / delete files
#   log_level?          *integer* representing the logging level
# Returns
#   0                   situation nominal
#   1                   user-related issue (wrong parameter, refusal...)
#   2                   missing parameter
#   3                   external issue (permissions, path exists as file...)
###############################################################################
function check_arguments_validity () {
    # Mandatory arguments check
    if [[ -z ${source+x} || -z ${target+x} ]] ; then
        err "One or more mandatory parameters are missing (--input, --output and --codec must be set)"
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
    debug "Log level: ${log_level}"
    debug "Flag move: ${flag_move}"
}


# TODO modularize ?
###############################################################################
# Does the heavy lifting. Will find and transcode music files to the prescripted
# codec using specified parameters
# Arguments:
#   none, but
# Uses globals:
#   source
#   target
#   codec
#   target_sample_fmt
#   target_sample_rate
#   target_quality
#   flag_move
#   log_level
# Returns:
#   0                   completed transcoding
#   1                   no files in source
#   2                   destination folder is a file
###############################################################################
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

    # FIXME
    music_files_count=$(eval "${formatted_find_command}" | wc -l)
    #readarray -d music_files < <(find "${source}" ${find_cmd_flags[*]})
    debug "${music_files_count} files found"
    if [[ ${music_files_count} -eq 0 ]] ; then
        err "No files in ${source}"
        return 1
    fi

    music_files_handled_count=0
    # Heavy lifting
    for input in $(eval "${formatted_find_command}") ; do
        # Analyze existing music file
        debug "Probing ${input}"
        
        output_extension="${input##*.}"
        input_stream_data+=( $(vorbiscomment "${input}") )

        destination=$(build_file_name)
        case "${?}" in
            0 ) ;;
            1 ) err "Failed to build file name"; return 2 ;; # todo codes
        esac
        destination="${target}/${destination}"
        log "Filename built: $destination"

        check_path_exists_and_is_directory "$(dirname "${destination}")"
        case "${?}" in
            0 ) ;;
            3 ) err "Path exists but is a file rather than directory"; return 2 ;;
        esac

        if [[ ${flag_move} -eq 1 ]] ; then
            mv "${input}" "${destination}"
            debug "Moved ${input} to ${destination}"
        else
            cp "${input}" "${destination}"
            debug "Copied ${input} to ${destination}"
        fi
        log "Done !"

        (( music_files_handled_count+=1 ))
        ratio=$(( (100 * music_files_handled_count) / music_files_count ))
        log "Handled ${ratio}% of all files (${music_files_handled_count}/${music_files_count})"

        unset ratio
        unset output_extension
        unset destination
        unset input_stream_data
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
# TODO error handling
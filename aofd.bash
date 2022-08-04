#!/bin/bash

# TODO add "rebuts"

# This script helps transcode music files to either FLAC or Vorbis (OGG).
# Return codes:
# 0     Execution terminated faithfully
# 1     User-related issue (wrong parameters...)
# 2     External issue (directory permission...)
# 3     Source stream issue
# 4     Ffmpeg-related problem

# Safeguards
#   -u not specified because of associative array use
#   -e not specified to allow proper error management
set -o pipefail
IFS=$'\n\t'

source "./utils.bash"

# Constants
declare -r    PROBABLY_MISTAKE="; while this might be intended, be advised this is likely a mistake"
declare -r -a ACCEPTED_TARGET_CODECS=("flac" "vorbis")
declare -r -a ACCEPTED_SOURCE_CODECS=("flac" "ogg" "dsf" "mp3" "m4a")
declare -r -a LOSSY_CODECS=("mp3" "vorbis")
declare -r -a LOSSLESS_CODECS=("flac" "alac")
declare -r -a ACCEPTED_SAMPLE_FORMATS=("s16" "s32")
declare -r -A OPTION_CODEC_TO_FFMPEG_CODEC=( [flac]=flac [vorbis]=libvorbis )
declare -r -A OPTION_CODEC_TO_EXTENSION=( [flac]=flac [vorbis]=ogg )
declare -r -A COMPARE_SAMPLE_FMTS=( [u8]=0 [s16]=1 [s32]=2 [flt]=-1 [dbl]=-1 [u8p]=0 [s16p]=1 [s32p]=2 [fltp]=-1 [dblp]=-1 [s64]=3 [s64p]=3 )

# Globals
## Once set, they should be read-only
declare    source
declare    target
declare    target_codec
declare    target_sample_fmt
declare -i target_sample_rate
declare -i target_quality
declare -i flag_move
declare -i log_level

################################################################################
# Extract a stream value from the list of available key/value
# Arguments:
#   needle!         key to search for.
#   haystack!*      key/value stream data. 'ini' or 'flat' formats are assumed.
# Returns:
#   echoes          value obtained from
#   0               returned along with extracted value
#   1               no value found
################################################################################
function extract_stream_data () {
    local _needle="${1}"
    shift
    local _haystack=("${@}")

    for stream_data in "${_haystack[@]}" ; do
        if [[ ${stream_data} =~ ${_needle}=\"([a-zA-Z0-9/]+)\" ]] ; then
            echo "${BASH_REMATCH[1]}"
            return 0
        fi
    done

    return 1
}

################################################################################
# Display help
################################################################################
function display_help () {
    cat <<EOF
Usage ${0} --input <DIRECTORY> --output <DIRECTORY> --codec <CODEC> [OPTIONS]...
Parameters:
    -i  --input <DIRECTORY>         Input folder, containing the music files
    -o  --output <DIRECTORY>        Output folder, into which music files will be transcoded
    -c  --codec <CODEC>             Codec to transcode music files to (must be \"flac\" or \"vorbis\")
    -sf --sample-format <FORMAT>    Sample format. See \`ffprobe -sample_fmts\` for more information.
                                    Incompatible with lossy codecs.
    -sr --sample-rate <FREQUENCY>   Sample rate, in Hz. Default value is 48000 Hz.
                                    Incompatible with lossy codecs.
    -sr --sample-rate <FREQUENCY>   Quality for transcoding, 1-12 scale. Default value is 8.
                                    Incompatible with non-Vorbis codecs.
    -l  --log-level                 Log level, between 0 and 3, both included.
                                        0: quiet            (only errors)
                                        1: standard         (default)
                                        2: verbose          (debug logs)
                                        3: HYPER-verbose    (set -x)
Flags:
    -mv --move                      Deletes original files after transcoding.
    -h  --help                      Displays help
EOF
}

################################################################################
# Compute the sample rate. If target sample rate is superior to source,
# source sample rate is taken. Otherwise, target rate will be used.
# If source sample rate is null, target sample rate is used.
# Arguments:
#   source!     *integer* sample rate of the source file in Hz
#   target!     *integer* sample rate of the target file in Hz
# Returns:
#   echoes      the final sample rate
################################################################################
function get_sample_rate () {
    local _source="${1}"
    local _target="${2}"

    if [[ -z ${source+x} ]] ; then
        echo "${target}"
    else
        if [[ ${_source} -gt ${_target} ]] ; then
            echo "${_target}"
        else
            echo "${_source}"
        fi
    fi
}

################################################################################
# Compute the sample format. If target sample format is superior to source,
# source sample format is taken. Otherwise, target format will be used.
# If source sample format is a lossy-related, defaults to "s16".
# If source sample format is null, target sample format is used.
# See:
#   `ffprobe -sample_fmts` for available formats
# Arguments:
#   source!     *integer* sample format of the source file
#   target!     *integer* sample format of the target file
# Returns:
#   echoes      the final sample format
################################################################################
function get_sample_fmt () {
    local _source="${1}"
    local _target="${2}"

    if [[ -z ${_source+x} ]] ; then
        echo "${_target}"
    else
        local _source_fmt_val=${COMPARE_SAMPLE_FMTS[$_source]}
        local _target_fmt_val=${COMPARE_SAMPLE_FMTS[$_target]}
        if [[ ${_source_fmt_val} -eq -1 ]] ; then
            echo "s16" # TODO constant
        elif [[ ${_source_fmt_val} -gt ${_target_fmt_val} ]] ; then
            echo "${_target}"
        else
            echo "${_source}"
        fi
    fi
}

################################################################################
# Parse arguments from the command line and set global parameters.
# Arguments:
#   arguments!*         *array* of arguments from the command line
# Sets globals:
#   source!             *path* to source directory
#   target_codec!       *path* to target directory
#   codec!              *codec* to transcode source files to (FLAC or Vorbis)
#   target_sample_fmt?  *sample format* to transcode source files with
#   target_sample_rate? *integer* representing the wanted sample rate
#   target_quality?     *integer* representing the wanted quality
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
            -c | --codec)
                found=0
                for codec in "${ACCEPTED_TARGET_CODECS[@]}"; do
                    if [[ ${codec} == "$(echo "${2}" | tr '[:upper:]' '[:lower:]')" ]] ; then
                        found=1
                    fi
                done

                if [[ ${found} ]] ; then
                    target_codec="${2}"
                    readonly target_codec
                    shift 2
                else
                    err "Unknown codec: ${2}"
                    return 2
                fi
                ;;
            -sf | --sample-format)
                found=0
                for format in "${ACCEPTED_SAMPLE_FORMATS[@]}"; do
                    if [[ ${format} == "${2}" ]] ; then
                        found=1
                    fi
                done

                if [[ ${found} ]] ; then
                    target_sample_fmt="${2}"
                    readonly target_sample_fmt
                    shift 2
                else
                    err "Unknown format: ${2}"
                    return 2
                fi
                ;;
            -sr | --sample-rate)
                if [[ ! "${2}" =~ ^[0-9]+$ ]] ; then
                    err "The sample rate parameter only accepts integer values (in Hz)"
                    return 2
                fi

                if [[ ${2} -lt 44100 ]] ; then
                    warn "Sample rate parameter inferior to 44.1 kHz can lead to information loss ${PROBABLY_MISTAKE}"
                elif [[ ${2} -ge 48000 && ${2} -lt 96000 ]] ; then
                    warn "Sample rate parameter superior to 48 kHz will not be read be many services (ex: Sonos) ${PROBABLY_MISTAKE}"
                elif [[ ${2} -ge 96000 ]] ; then
                    warn "Sample rate parameter superior to 96 kHz will not be read be many services ${PROBABLY_MISTAKE}"
                fi

                target_sample_rate="${2}"
                readonly target_sample_rate
                shift 2
                ;;
            -qs | --quality-scale)
                if [[ ! "${2}" =~ ^[0-9]+$ ]] ; then
                    err "The quality parameter only accepts integer values"
                    return 2
                fi
                if [[ ${2} -lt 1 || ${2} -gt 10 ]] ; then
                    err "Quality parameter not within 1 < quality < 10"
                    return 2
                fi

                target_quality="${2}"
                readonly target_quality
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
################################################################################
function check_arguments_validity () {
    # Mandatory arguments check
    if [[ -z ${source+x} || -z ${target+x} || -z ${target_codec+x} ]] ; then
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

    # Incompatible parameters
    if [[ -n "${target_sample_fmt+x}" && "${target_codec}" == "vorbis" ]] ; then
        warn "The sample format parameter is not supported with ${target_codec}"
    fi
    if [[ -n "${target_sample_rate+x}" && "${target_codec}" == "vorbis" ]] ; then
        warn "The sample rate parameter is not supported with ${target_codec}"
    fi
    if [[ -n "${target_quality+x}" && "${target_codec}" == "flac" ]] ; then
        warn "The quality parameter is not supported with ${target_codec}"
    fi

    # Optional parameters
    # TODO constants
    if [[ -z ${target_sample_fmt+x} ]] ; then
        target_sample_fmt="s32"
        readonly target_sample_fmt
    fi
    if [[ -z ${target_quality+x} ]] ; then
        target_quality=9
        readonly target_quality
    fi
    if [[ -z ${target_sample_rate+x} ]] ; then
        target_sample_rate=48000
        readonly target_sample_rate
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
    debug "Quality: ${target_quality}"
    debug "Target sample format: ${target_sample_fmt}"
    debug "Target sample rate: ${target_sample_rate}"
    debug "Log level: ${log_level}"
    debug "Flag move: ${flag_move}"
}

################################################################################
# Does the heavy lifting. Will find and transcode music files to the prescribed
# codec using specified parameters
# Parameters
#  +source!
#  +target!
#  +codec!
#  +target_sample_fmt!
#  +target_sample_rate!
#  +target_quality!
#  +flag_move!
#  +log_level!
# Returns:
#   0                   completed transcoding
#   1                   no files in source
#   2                   destination folder is a file
#   3                   cannot parse source stream data
#   4                   ffmpeg-related error
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
        # Compute destination folder
        destination="${input/$source/$target}"
        destination="${destination%.*}.${OPTION_CODEC_TO_EXTENSION[$target_codec]}"

        destination_folder="$(dirname "${destination}")"
        check_path_exists_and_is_directory "${destination_folder}"
        case "${?}" in
            0 ) ;;
            3 ) err "Path exists but is a file rather than directory"; return 2 ;;
        esac

        # Analyze existing music file
        debug "Probing ${input}"
        input_stream_data=$(ffprobe                     \
                            -v fatal                    \
                            -print_format flat          \
                            -show_streams:a "${input}"  \
                            | grep stream.0)

        ## Codec
        source_codec=$(extract_stream_data "codec_name" "${input_stream_data[@]}")
        case "${?}" in
            0 ) debug "Source codec is ${source_codec}" ;;
            1 ) err "Cannot parse codec of ${input}"; return 3 ;;
        esac

        ## Sample Rate
        source_sample_rate=$(extract_stream_data "sample_rate" "${input_stream_data[@]}")
        case "${?}" in
            0 ) debug "Source sample rate is ${source_sample_rate} Hz" ;;
            1 ) err "Cannot parse sample rate of ${input}"; return 3 ;;
        esac

        ## For lossless codecs, sample format
        if [[ ${LOSSLESS_CODECS[$source_codec]} ]] ; then
            source_sample_fmt=$(extract_stream_data "sample_fmt" "${input_stream_data[@]}")
            case "${?}" in
                0 ) debug "Source sample format is ${source_sample_fmt}" ;;
                1 ) err "Cannot parse sample format of ${input}"; return 3 ;;
            esac
        fi

        # Build FFMPEG command
        declare -a ffmpeg_cmd_flags
        ffmpeg_cmd_flags+=(-v fatal)            # only prompt unrecoverable errors
        ffmpeg_cmd_flags+=(-y)                  # overwrite existing files
        ffmpeg_cmd_flags+=(-i "${input}")       # input file
        ffmpeg_cmd_flags+=(-vn)                 # strip non-audio streams (see footnote #1)
        ffmpeg_cmd_flags+=(-c:a "${OPTION_CODEC_TO_FFMPEG_CODEC[$target_codec]}")

        ## Configure for lossless codec target
        if [[ ${LOSSLESS_CODECS[$target_codec]} -eq 1 ]] ; then
            sample_fmt=$(get_sample_fmt "${source_sample_fmt}" "${target_sample_fmt}")
            ffmpeg_cmd_flags+=(-sample_fmt "${sample_fmt}")

            if [[ ${sample_fmt} == "s32" || ${sample_fmt} == "s32p" ]] ; then
                ffmpeg_cmd_flags+=(-bits_per_raw_sample 24)
            fi

            sample_rate=$(get_sample_rate "${source_sample_rate}" "${target_sample_rate}")
            ffmpeg_cmd_flags+=(-ar "${sample_rate}")

            if [[ ${target_codec} == "flac" ]] ; then
                ffmpeg_cmd_flags+=(-compression_level 12) # TODO option
            fi
        fi

        ## Configure for lossy codec target
        if [[ "${LOSSY_CODECS[$target_codec]}" -eq 1 ]] ; then
            if [[ ${target_codec} == "vorbis" ]] ; then
                ffmpeg_cmd_flags+=(-q:a "${target_quality}")
            fi
        fi

        ffmpeg_cmd_flags+=("${destination}")

        log "Handling ${input}... "
        # if input file similar to output file, copy input to output
        if [[ ${source_codec} == "flac" \
            && ${source_codec} == "${target_codec}" \
            && ${source_sample_fmt} == "${sample_fmt}" \
            && ${source_sample_rate} == "${sample_rate}" ]] ; then
            if [[ ${flag_move} -eq 1 ]] ; then
                mv "${input}" "${destination}"
                debug "Moved ${input} to ${destination}"
            else
                cp "${input}" "${destination}"
                debug "Copied ${input} to ${destination}"
            fi
        else
            formatted_cmd_parameters=$(printf "%s " "${ffmpeg_cmd_flags[@]}")
            debug "Ffmpeg command is \`ffmpeg ${formatted_cmd_parameters}\`"

            potential_error=$(ffmpeg "${ffmpeg_cmd_flags[@]}" 2>&1)
            case "${?}" in
                0 ) debug "Transcoded ${input}" ;;
                * ) err "${potential_error}"; return 4 ;;
            esac
            if [[ ${flag_move} -eq 1 ]] ; then
                rm "${input}"
                debug "Deleted ${destination}"
            fi
        fi
        log "Done !"

        (( music_files_handled_count+=1 ))
        ratio=$(( (100 * music_files_handled_count) / music_files_count ))
        log "Handled ${ratio}% of all files (${music_files_handled_count}/${music_files_count})"

        unset ratio
        unset source_sample_fmt
        unset source_sample_rate
        unset ffmpeg_cmd_flags
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
    3 ) err "Cannot parse source stream data";  exit 3;;
    4 ) err "Ffmpeg-related error";             exit 4;;
    * ) err "Unrecognized error";               exit 255 ;;
esac

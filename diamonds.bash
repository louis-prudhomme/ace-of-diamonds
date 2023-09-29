#!/usr/bin/env bash

# This script helps transcode music files to either FLAC or Vorbis .
# Return codes:
# 0     Execution terminated faithfully
# 1     User-related issue (wrong parameters...)
# 2     External issue (directory permission...)
# 3     Source stream issue
# 4     Ffmpeg-related problem

# Safeguards
#   -e not specified to allow proper error management
set -uo pipefail
IFS=$'\n\t'

SCRIPT_REAL_PATH=$(dirname "${0}")
readonly SCRIPT_REAL_PATH
source "${SCRIPT_REAL_PATH}/utils.bash"

declare -r    PROBABLY_MISTAKE="; while this might be intended, be advised this is likely a mistake"

declare -r    DEFAULT_MAX_SAMPLE_RATE=48000
declare -r    DEFAULT_BIT_RATE=128000
declare -r    DEFAULT_MAX_BIT_DEPTH=32
declare -r    DEFAULT_REPACKAGING_BIT_DEPTH=16
declare -r    DEFAULT_REPACKAGING_BIT_RATE=128000
declare -r    DEFAULT_TARGET_CONTAINER="ogg"
declare -r -i DEFAULT_SHOULD_AVOID_LOSS=0

declare -r -i MAX_BIT_RATE=512000
declare -r    BIT_RATE_MULTIPLIER_PER_CHANNELS="2" # can be a float
declare -r -a ACCEPTED_TARGET_CONTAINERS=("flac" "ogg")
declare -r -a ACCEPTED_BIT_DEPTHS=("8" "16" "24" "32" "64")
declare -r -a LOSSY_CODECS=("mp3" "mp2" "aac" "vorbis" "opus" "ac3" "wma" "libvorbis")
declare -r -a LOSSLESS_CODECS=("flac" "alac" "dsf" "dst" "wmalossless" "truehd" "als")
declare -r -A SAMPLE_FMT_TO_BIT_DEPTH=( [u8]=8 [s16]=16 [s32]=32 [u8p]=8 [s16p]=16 [s32p]=32 [s64]=64 [s64p]=64 )
declare -r -A BIT_DEPTH_TO_SAMPLE_FMT=( [16]=s16 [32]=s32 [64]=s64 )
declare -r -A CODEC_NAME_TO_FFMPEG_CODEC_ID=( [opus]=libopus [flac]=flac )

HELP_TEXT="Usage ${0} --input <DIRECTORY> --output <DIRECTORY> --codec <CODEC> [OPTIONS]...
Parameters:
    -i    --input <DIRECTORY>       Input folder containing the music files.
    -o    --output <DIRECTORY>      Output folder into which music files will be transcoded.
    -c    --container <CONTAINER>   Container to package music files into (must be \"FLAC\" or \"OGG\").
                                    This also determines the codec:
                                        FLAC => flac
                                        OGG  => opus (& flac when source is a lossy codec)
    -bd   --max-bit-depth <DEPTH>   Max bit depth. When transcoding to flac from a lossless codec,
                                    the bit depth will be capped to this value.
                                    Must be one of $(printf "%s " "${ACCEPTED_BIT_DEPTHS[@]}")(default: ${DEFAULT_MAX_BIT_DEPTH}).
                                    Has no effect with the OGG container mode.
    -sr   --max-sample-rate <RATE>  Max sample rate, in Hz. When transcoding to flac from a lossless codec,
                                    the bit depth will be capped to this value.
                                    Has no effect with the OGG container mode.
    -br   --bitrate <RATE>          Desired bitrate, in Hz, when transcoding to opus (default: ${DEFAULT_BIT_RATE}).
                                    Has no effect with the FLAC container mode.
    -rly --rpkg-to-lossy            Flag which sets the mode for the repackaging; ie, whether to encode lossy-encoded
                                    files to another lossy codec or not, thereby risking audio loss (default: YES).
    -rls --rpkg-to-lossless         Flag which sets the mode for the repackaging; ie, whether to encode lossy-encoded
                                    files to a lossless codec or not, to avoid audio loss (default: NO).
    -rbd  --rpkg-bit-depth <DEPTH>  Repackaging bit depth to use when transcoding to flac/OGG from a lossy codec.
                                    Must be one of $(printf "%s " "${ACCEPTED_BIT_DEPTHS[@]}")(default: ${DEFAULT_MAX_BIT_DEPTH}).
                                    Has no effect with the FLAC container mode.
    -rbr  --rpkg-bit-rate <RATE>    Repackaging bit rate to use when transcoding to opus/OGG from a lossy codec.
                                    (default: ${DEFAULT_REPACKAGING_BIT_RATE}).
                                    Has no effect with the FLAC container mode."
readonly HELP_TEXT

# Globals
## Once set, they should be read-only
declare    source
declare    target
declare    target_container
declare -i target_max_bit_depth
declare -i target_max_sample_rate
declare -i target_bit_rate
declare -i should_avoid_loss
declare -i target_repackaging_bit_depth
declare -i target_repackaging_bit_rate

################################################################################
# Parse arguments from the command line and set global parameters.
# Arguments:
#   arguments!*             *array* of arguments from the command line
# Sets globals:
#   source!                         *path* to source directory
#   target!                         *path* to target directory
#   target_container!               *container* to package source files to (FLAC or OGG)
#   target_bit_depth?               *bit depth* to transcode source files with
#   target_max_sample_rate?         *integer* representing the wanted sample rate
#   target_bit_rate?                *integer* representing the wanted bit rate
#   target_repackaging_bit_rate?    *integer* representing the wanted bit rate for repackaging
#   target_repackaging_bit_depth?   *integer* representing the wanted bit depth for repackaging
#   should_move_files?              *flag* indicating to move / delete files
#   is_dry_run?                     *flag* whether should not do any real file mingling
#   log_level?                      *integer* representing the logging level
# Returns:
#   0                       arguments parsed faithfully
#   1                       Unknown option
#   2                       Bad option
#   10                      Help displayed
################################################################################
function parse_arguments () {
    debug "Parsing arguments"
    while : ; do
        case "${1:---}" in
            -i | --input)
                # not readonly because of subsequent formatting
                source="${2}"
                shift 2
                ;;
            -o | --output)
                target="${2}"
                shift 2
                ;;
            -c | --container)
                found=0
                local _tentative
                _tentative="$(echo "${2}" | tr '[:upper:]' '[:lower:]')"

                for container in "${ACCEPTED_TARGET_CONTAINERS[@]}"; do
                    if [[ ${container} == "${_tentative}" ]] ; then
                        found=1
                    fi
                done

                if [[ ${found} ]] ; then
                    target_container="${2}"
                    readonly target_container
                    shift 2
                else
                    err "Unknown codec: ${2}"
                    return 2
                fi
                ;;
            -bd | --max-bit-depth)
                found=0
                for depth in "${ACCEPTED_BIT_DEPTHS[@]}"; do
                    if [[ ${depth} == "${2}" ]] ; then
                        found=1
                    fi
                done

                if [[ ${found} ]] ; then
                    target_bit_depth="${2}"
                    readonly target_bit_depth
                    shift 2
                else
                    err "Unsupported bit depth: ${2}"
                    return 2
                fi
                ;;
            -rly | --rpkg-to-lossy)
                should_avoid_loss=0
                shift 1
                ;;
            -rls | --rpkg-to-lossless)
                should_avoid_loss=1
                shift 1
                ;;
            -rbd | --rpkg-bit-depth)
                found=0
                for depth in "${ACCEPTED_BIT_DEPTHS[@]}"; do
                    if [[ ${depth} == "${2}" ]] ; then
                        found=1
                    fi
                done

                if [[ ${found} ]] ; then
                    target_repackaging_bit_depth="${2}"
                    readonly target_repackaging_bit_depth
                    shift 2
                else
                    err "Unsupported bit depth: ${2}"
                    return 2
                fi
                ;;
            -sr | --sample-rate)
                if [[ ! "${2}" =~ ^[0-9]+$ ]] ; then
                    err "The sample rate parameter only accepts integer values (in Hz)"
                    return 2
                fi

                if [[ ${2} -lt 44100 ]] ; then
                    log "Sample rate parameter inferior to 44.1 kHz can lead to information loss ${PROBABLY_MISTAKE}"
                elif [[ ${2} -gt 48000 ]] ; then
                    log "Sample rate parameter superior to 48 kHz will not be read be many services (ex: Sonos) ${PROBABLY_MISTAKE}"
                fi

                target_max_sample_rate="${2}"
                readonly target_max_sample_rate
                shift 2
                ;;
            -br | --bitrate)
                if [[ ! "${2}" =~ ^[0-9]+$ ]] ; then
                    err "The bitrate parameter only accepts integer values"
                    return 2
                fi

                if [[ ${2} -lt 64000 ]] ; then
                    warn "Bit rates inferior to 64 kb/s can lead to audio distortion ${PROBABLY_MISTAKE}"
                elif [[ ${2} -gt 510000 ]] ; then
                    warn "Bit rates superior to 510 kb/s are undefined behavior for Opus ${PROBABLY_MISTAKE}"
                fi

                target_bit_rate="${2}"
                readonly target_bit_rate
                shift 2
                ;;
            -rbr | --rpkg-bitrate)
                if [[ ! "${2}" =~ ^[0-9]+$ ]] ; then
                    err "The repackaging bitrate parameter only accepts integer values"
                    return 2
                fi

                if [[ ${2} -lt 64000 ]] ; then
                    log "Bit rates inferior to 64 kb/s can lead to audio distortion ${PROBABLY_MISTAKE}"
                elif [[ ${2} -gt 510000 ]] ; then
                    log "Bit rates superior to 510 kb/s are undefined behavior for Opus ${PROBABLY_MISTAKE}"
                fi

                target_repackaging_bit_rate="${2}"
                readonly target_repackaging_bit_rate
                shift 2
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
    debug "Parsed arguments"
}

################################################################################
# Performs operations on global arguments:
#   - checks if correctly set for mandatory arguments
#   - sets defaults for optional arguments
# Sets globals:
#   target_bit_depth?       *sample format* to transcode source files with
#   target_max_sample_rate? *integer* representing the wanted sample rate
#   target_bit_rate?        *integer* representing the wanted quality
#   target_rpkg_bit_depth?  *integer* representing the wanted quality
#   should_avoid_loss?      *flag* whether to avoid repackaging to lossy
#   is_dry_run?             *flag* whether to ignore all execution
#   should_move_files?      *flag* indicating to move / delete files
#   log_level?              *integer* representing the logging level
# Returns
#   0                   situation nominal
#   1                   user-related issue (wrong parameter, refusal...)
#   2                   missing parameter
#   3                   external issue (permissions, path exists as file...)
################################################################################
function check_arguments_validity () {
    # Mandatory arguments check
    if [[ -z ${target_container+x} ]] ; then
        target_container="ogg"
        readonly target_container
    fi

    check_input_argument "${source}"
    case "${?}" in
        0) ;;
        *) return ${?}
    esac
    readonly source

    check_output_argument "${target}"
    case "${?}" in
        0) ;;
        *) return ${?}
    esac
    readonly target

    if [[ -z ${should_avoid_loss+x} ]] ; then
        should_avoid_loss="${DEFAULT_SHOULD_AVOID_LOSS}"
    fi
    debug "Should avoid losses: ${should_avoid_loss}"
    readonly should_avoid_loss

    # Incompatibilities
    if [[ -n ${target_max_bit_depth+x} && "${target_container}" == "ogg" ]] ; then
        log "The max bit depth parameter is not supported with ${target_container}"
    fi
    if [[ -n ${target_max_sample_rate+x} && "${target_container}" == "ogg" ]] ; then
        log "The max sample rate parameter is not supported with ${target_container}"
    fi
    if [[ -n ${target_bit_rate+x} && "${target_container}" == "flac" ]] ; then
        log "The bitrate parameter is not supported with ${target_container}"
    fi
    if [[ -n ${target_repackaging_bit_depth+x} && "${target_container}" == "flac" ]] ; then
        log "The repackaging bit depth parameter is not supported with ${target_container}"
    fi

    # Optional parameters
    if [[ -z ${target_max_bit_depth+x} ]] ; then
        target_max_bit_depth="${DEFAULT_MAX_BIT_DEPTH}"
        readonly target_max_bit_depth
    fi
    if [[ -z ${target_max_sample_rate+x} ]] ; then
        target_max_sample_rate="${DEFAULT_MAX_SAMPLE_RATE}"
        readonly target_max_sample_rate
    fi
    debug "Target max bit depth: ${target_max_bit_depth}"
    debug "Target max sample rate: ${target_max_sample_rate}"

    if [[ -z ${target_bit_rate+x} ]] ; then
        target_bit_rate="${DEFAULT_BIT_RATE}"
        readonly target_bit_rate
    fi

    if [[ -z ${target_repackaging_bit_depth+x} ]] ; then
        target_repackaging_bit_depth="${DEFAULT_REPACKAGING_BIT_DEPTH}"
        readonly target_repackaging_bit_depth
    fi
    if [[ -z ${target_repackaging_bit_rate+x} ]] ; then
        debug "zobk"
        target_repackaging_bit_rate="${DEFAULT_REPACKAGING_BIT_RATE}"
        readonly target_repackaging_bit_rate
    fi
    debug "Target bitrate: ${target_bit_rate}"
    debug "Target repackaging bit depth: ${target_repackaging_bit_depth}"
    debug "Target repackaging bit rate: ${target_repackaging_bit_rate}"
}

################################################################################
# Compute the final decoder to use. Essentially, whether to use flac to
# avoid lossy encoding of files already lossy encoded.
# Arguments:
#   source_codec_type!      *string* lossy/lossless
#   target_container!       *string* ogg/flac
#   should_avoid_loss!      *bool* avoid re-encode lossy to lossy
# Returns:
#   echoes      the final sample rate
################################################################################
function get_target_encoder () {
    local _source_codec_type="${1}"
    local _target_container="${2}"
    local _should_avoid_loss="${3}"

    if [[ ${_source_codec_type} == "lossy" && ${_target_container} == "ogg" ]] ; then
        if [[ ${_should_avoid_loss} -eq 1 ]] ; then
            echo "flac"
        else
            echo "opus"
        fi
    elif [[ ${_source_codec_type} == "lossless" && ${_target_container} == "ogg" ]] ; then
        echo "opus"
    elif [[ ${_source_codec_type} == "lossy" && ${_target_container} == "flac" ]] ; then
        echo "flac"
    elif [[ ${_source_codec_type} == "lossless" && ${_target_container} == "flac" ]] ; then
        echo "flac"
    fi
}

################################################################################
# Compute the final sample rate. If target sample rate is superior to source,
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
# Compute the final bit depth from the bit depth of a file and the one we desire.
# Arguments:
#   source!     *integer* bit depth of the source file
#   target!     *integer* bit depth of the target file
# Returns:
#   echoes      the final bit depth
################################################################################
function get_bit_depth () {
    local _source="${1}"
    local _target="${2}"

    if [[ -z ${_source+x} ]] ; then
        echo "${_target}"
    else
        if [[ ${_source} -gt ${_target} ]] ; then
            echo "${_target}"
        else
            echo "${_source}"
        fi
    fi
}

################################################################################
# Compute the final bit rate from the original encoding & channels
# Arguments:
#   source_encoding_type!   *string* lossy / lossless
#   source_channels!        *integer* number of channels
# Returns:
#   echoes      the final bit rate
################################################################################
function get_bit_rate () {
    local _source_encoding_type="${1}"
    local _source_channels="${2}"
    local _tentative_bit_rate

    if [[ ${_source_encoding_type} == "lossy" ]] ; then
        _tentative_bit_rate=${target_repackaging_bit_rate}
    else
        _tentative_bit_rate=${target_bit_rate}
    fi

    if [[ ${_source_channels} -gt 1 ]] ; then
        _tentative_bit_rate=$(echo "${_tentative_bit_rate}*${BIT_RATE_MULTIPLIER_PER_CHANNELS}" | bc -l)
        _tentative_bit_rate=$(printf "%.0f" "${_tentative_bit_rate}")
        if [[ ${_tentative_bit_rate} -gt ${MAX_BIT_RATE} ]] ; then
            log "Tried to adjust the bitrate for ${_source_channels} channels: ${_tentative_bit_rate} ;" \
                "since this is more than the authorized bitrate, setting it to the maximum: ${MAX_BIT_RATE}."
            echo "${MAX_BIT_RATE}"
        else
            echo "${_tentative_bit_rate}"
        fi
    else
        echo "${_tentative_bit_rate}"
    fi
}

################################################################################
# Compute the final sample format from the sample format of the source file and
# the bit depth we desire.
# See:
#   `ffprobe -sample_fmts` for available formats
# Arguments:
#   source_fmt!             *string* sample format of the source file
#   final_bit_depth!        *int* final bit depth of the target file
#   repackaging_bit_depth!  *int* bit depth to use for repacking
# Returns:
#   echoes      the final sample format
################################################################################
function get_sample_fmt () {
    local _final_bit_depth="${2}"
    echo "${BIT_DEPTH_TO_SAMPLE_FMT[$_final_bit_depth]}"
}

################################################################################
# Does the heavy lifting. Will find and transcode music files to the prescribed
# codec using specified parameters
# Parameters
#  +source!
#  +target!
#  +container!
#  +target_max_bit_depth!
#  +target_max_sample_rate!
#  +target_bit_rate!
#  +should_avoid_loss!
#  +target_repackaging_bit_depth!
#  +target_repackaging_bit_rate!
# Returns:
#   0                   completed transcoding
#   1                   no files in source
#   2                   destination folder is a file
#   3                   cannot parse source stream data
#   4                   ffmpeg-related error
################################################################################
function main () {
    find_music_files "${source}"
    declare -r -i music_files_count=${#MUSIC_FILES[@]}
    debug "${music_files_count} files found"

    if [[ ${music_files_count} -eq 0 ]] ; then
        err "No files in ${source}"
        return 1
    fi

    music_files_handled_count=0
    # Heavy lifting
    for input in "${MUSIC_FILES[@]}" ; do
        # Compute destination folder
        destination="${input/$source/$target}"
        destination="${destination%.*}.${target_container}"

        destination_folder="$(dirname "${destination}")"
        check_path_exists_and_is_directory "${destination_folder}"
        case "${?}" in
            0 ) ;;
            3 ) err "Path exists but is a file rather than directory"; return 2 ;;
            4 ) err "Destination path contains forbidden characters";  return 1 ;;
        esac

        # Analyze existing music file
        debug "Probing ${input}"

        ffprobe_music_file "${input}" # into RAW_MUSIC_FILE_STREAM
        music_data_to_dictionary "${RAW_MUSIC_FILE_STREAM[@]}" # into DICTIONARY
        case "${?}" in
            0) ;;
            1) return 3 ;;
        esac
        # var DICTIONARY is referenced as input_stream_data
        declare -n "input_stream_data=DICTIONARY"

        # Base info
        source_container="${source##*.}"
        source_codec=$(extract_music_file_data "codec_name")
        case "${?}" in
            0 ) debug "Source codec is ${source_codec}" ;;
            1 ) err "Cannot parse codec of ${input}"; return 3 ;;
        esac


        if [[ $(echo "${LOSSLESS_CODECS[@]}" | grep -o "${source_codec}" | wc -w) -gt 0 ]] ; then
            source_codec_type="lossless"
        elif [[ $(echo "${LOSSY_CODECS[@]}" | grep -o "${source_codec}" | wc -w) -gt 0 ]] ; then
            source_codec_type="lossy"
        else
            err "Codec ${source_codec} could not be profiled."
            return 3
        fi
        debug "${source_codec} is ${source_codec_type}"

        # Sample Rate
        source_sample_rate=$(extract_music_file_data "sample_rate")
        case "${?}" in
            0 ) debug "Source sample rate is ${source_sample_rate} Hz" ;;
            1 ) err "Cannot parse sample rate of ${input}"; return 3 ;;
        esac

        # For lossless codecs, sample format
        if [[ ${source_codec_type} == "lossless" ]] ; then
            source_sample_fmt=$(extract_music_file_data "sample_fmt")
            case "${?}" in
                0 ) debug "Source sample format is ${source_sample_fmt}" ;;
                1 ) err "Cannot parse sample format of ${input}"; return 3 ;;
            esac
            source_bit_depth=$(extract_music_file_data "bits_per_raw_sample")
            case "${?}" in
                0 ) debug "Source bit depth is ${source_bit_depth}" ;;
                1 ) err "Cannot parse sample format of ${input}"; return 3 ;;
            esac
        fi

        target_codec=$(get_target_encoder "${source_codec_type}" "${target_container}" "${should_avoid_loss}")

        # Build FFMPEG command
        declare -a ffmpeg_cmd_flags
        ffmpeg_cmd_flags+=(-v fatal)            # only prompt unrecoverable errors
        ffmpeg_cmd_flags+=(-y)                  # overwrite existing files
        ffmpeg_cmd_flags+=(-i "${input}")       # input file
        ffmpeg_cmd_flags+=(-vn)                 # strip non-audio streams (see footnote #1)
        formatted_target_codec=${CODEC_NAME_TO_FFMPEG_CODEC_ID[$target_codec]}
        ffmpeg_cmd_flags+=(-c:a "${formatted_target_codec}")

        if [[ ${target_codec} == "flac" ]] ; then
            if [[ ${source_codec_type} == "lossy" ]] ; then
                final_bit_depth="${target_repackaging_bit_depth}"
            else
                final_bit_depth=$(get_bit_depth "${source_bit_depth}" "${target_bit_depth}")
            fi
            # sample rate
            sample_rate=$(get_sample_rate "${source_sample_rate}" "${target_max_sample_rate}")
            ffmpeg_cmd_flags+=(-ar "${sample_rate}")
            # sample fmt
            sample_fmt=$(get_sample_fmt "${source_sample_fmt}" "${final_bit_depth}" "${target_repackaging_bit_depth}")
            ffmpeg_cmd_flags+=(-sample_fmt "${sample_fmt}")

            # footnote 4
            if [[ ${final_bit_depth} -eq 24 ]] ; then
                ffmpeg_cmd_flags+=(-bits_per_raw_sample 24)
            fi
        elif [[ ${target_codec} == "opus" ]] ; then
            source_channels=$(extract_music_file_data "channels")
            final_bit_rate=$(get_bit_rate "${source_codec_type}" "${source_channels}")
            ffmpeg_cmd_flags+=(-b:a "${final_bit_rate}")
            ffmpeg_cmd_flags+=(-vbr on)
            ffmpeg_cmd_flags+=(-compression_level 10)
            ffmpeg_cmd_flags+=(-application audio)
        fi

        ffmpeg_cmd_flags+=("${destination}")

        log "Handling ${input}... "
        local is_treated_directly=0
        # if input file similar to output file, copy input to output
        if [[ ${source_container} == "${target_container}" ]] ; then
            if [[ ${source_codec} == "flac" && ${target_codec} == "flac" ]] ; then
                if [[ ${source_sample_fmt} == "${sample_fmt}" && ${source_sample_rate} == "${sample_rate}" ]] ; then
                    is_treated_directly=1
                    debug "Target file would be (almost) identical to source."
                fi
            elif [[ ${source_codec} == "vorbis" || ${source_codec} == "opus" ]] ; then
                is_treated_directly=1
            else
                is_treated_directly=0
            fi
        fi

        if [[ ${is_treated_directly} -eq 1 ]] ; then
            if [[ ${is_dry_run:?} -eq 0 ]] ; then
                if [[ ${should_move_files:?} -eq 1 ]] ; then
                    mv "${input}" "${destination}"
                    debug "Moved ${input} to ${destination}"
                else
                    cp "${input}" "${destination}"
                    debug "Copied ${input} to ${destination}"
                fi
            else
               debug "Treated ${input} to ${destination}"
            fi
        else
            formatted_cmd_parameters=$(printf "%s " "${ffmpeg_cmd_flags[@]}")
            debug "Ffmpeg command is \`ffmpeg ${formatted_cmd_parameters}\`"

            if [[ ${is_dry_run} -eq 0 ]] ; then
                ffmpeg "${ffmpeg_cmd_flags[@]}" 2>/dev/tty
            else
                true # to mock return code
            fi
            case "${?}" in
                0 ) debug "Transcoded ${input}" ;;
                * ) return 4 ;;
            esac
            if [[ ${should_move_files} -eq 1 ]] ; then
                if [[ ${is_dry_run} -eq 0 ]] ; then
                    rm "${input}"
                fi
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
    0 ) ;;
    1 ) err "Unrecognized argument";    exit 1;;
    2 ) err "Bad argument";             exit 1;;
    10) debug "Help displayed";         exit 0;;
    * ) err "Unrecognized error";       exit 255 ;;
esac

check_common_arguments
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

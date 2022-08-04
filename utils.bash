#!/bin/bash

# Safeguards
#   -u not specified because of associative array use
#   -e not specified to allow proper error management
set -o pipefail
IFS=$'\n\t'

################################################################################
# Functions to output workflow feedback to user.
# Returns:
#   echoes          text given in parameter
################################################################################
function err () {
  echo "[Error]: ${*}" >&2
}

# TODO make log_level and other global parameters common
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
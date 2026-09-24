#!/bin/bash

#shared helpers for the reshimboot build scripts

set -e
if [ "$DEBUG" ]; then
  set -x
  export DEBUG=1
fi

#reshimboot only targets a single board
# shellcheck disable=SC2034  # sourced by the build scripts
SHIMBOOT_BOARD="dedede"
SHIMBOOT_ARCH="amd64"

base_dir="$(realpath -m "$(dirname "${BASH_SOURCE[0]}")")"
tools_dir="$base_dir/tools"

# shellcheck disable=SC2034  # some colors are only used by scripts that source this
ANSI_CLEAR='\033[0m'
ANSI_BOLD='\033[1m'
ANSI_RED='\033[1;31m'
ANSI_GREEN='\033[1;32m'
ANSI_YELLOW='\033[1;33m'
ANSI_BLUE='\033[1;34m'

check_deps() {
  local needed_commands="$1"
  for command in $needed_commands; do
    if ! command -v "$command" &> /dev/null; then
      echo " - $command"
    fi
  done
}

assert_deps() {
  local needed_commands="$1"
  local missing_commands
  missing_commands="$(check_deps "$needed_commands")"
  if [ "${missing_commands}" ]; then
    print_error "You are missing dependencies needed for this script."
    print_error "Commands needed:"
    print_error "${missing_commands}"
    exit 1
  fi
}

#parse key=value arguments into the global "args" array
#arguments without an "=" are stored with an empty value
parse_args() {
  declare -g -A args
  for argument in "$@"; do
    if [ "$argument" = "-h" ] || [ "$argument" = "--help" ]; then
      print_help
      exit 0
    fi

    if [[ "$argument" == *=* ]]; then
      args["${argument%%=*}"]="${argument#*=}"
    else
      args["$argument"]=""
    fi
  done
}

#treat 1/true/yes/y/on as true, and anything else (including an empty string) as false
is_true() {
  case "${1,,}" in
    1|true|yes|y|on) return 0 ;;
    *) return 1 ;;
  esac
}

assert_root() {
  if [ "$EUID" -ne 0 ]; then
    print_error "This script needs to be run as root."
    exit 1
  fi
}

assert_args() {
  if [ -z "$1" ]; then
    print_help
    exit 1
  fi
}

print_title() {
  printf ">> ${ANSI_GREEN}%s${ANSI_CLEAR}\n" "$1"
}

print_info() {
  printf "${ANSI_BOLD}%s${ANSI_CLEAR}\n" "$1"
}

print_warning() {
  printf "${ANSI_YELLOW}%s${ANSI_CLEAR}\n" "$1" >&2
}

print_error() {
  printf "${ANSI_RED}%s${ANSI_CLEAR}\n" "$1" >&2
}

#cleanup actions run in reverse order when the script exits for any reason
#this makes sure that mounts, loop devices, and luks mappings are not leaked
cleanup_actions=()
add_cleanup() {
  cleanup_actions+=("$1")
}

run_cleanups() {
  local i
  for ((i=${#cleanup_actions[@]}-1; i>=0; i--)); do
    eval "${cleanup_actions[$i]}" || true
  done
  cleanup_actions=()
}
trap run_cleanups EXIT
trap 'exit 130' INT TERM

#run a command up to 5 times, for network operations that fail randomly
retry_cmd() {
  local i
  for i in 1 2 3 4 5; do
    if "$@"; then
      return 0
    fi
    print_warning "command failed (attempt $i/5): $*"
    sleep "$((i * 2))"
  done
  return 1
}

shimtool() {
  python3 "$tools_dir/shimtool.py" "$@"
}

#free space in MiB for the filesystem containing a path
free_space_mb() {
  local path="$1"
  mkdir -p "$path"
  df -Pm "$path" | tail -n1 | awk '{print $4}'
}

#!/bin/bash
##############################################
##                                          ##
##  install_all                             ##
##                                          ##
##############################################

SCRIPT_TITLE="install_all"
SCRIPT_VERSION="1.1"

SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
SYS_ARCH=$(dpkg --print-architecture)
PREREQS=( dpkg sed )

for i in "$@"
do
  case $i in
    -q|--quiet)
    quiet="-q"
    shift # past argument
    ;;
    -f|--force)
    force="-f"
    shift # past argument
    ;;
    -i|--install)
    [ "$CMD" == "" ] && CMD="install" || CMD="help"
    shift # past argument
    ;;
    -d|--deinstall)
    [ "$CMD" == "" ] && CMD="deinstall" || CMD="help"
    shift # past argument
    ;;
    -v|--version)
    [ "$CMD" == "" ] && CMD="version" || CMD="help"
    shift # past argument
    ;;
    -h|--help)
    CMD="help"
    shift # past argument
    ;;
    *)
    if [ "$i" != "" ]
    then
      echo "Unknown option: $i"
      exit 1
    fi
    ;;
  esac
done
[ "$CMD" == "" ] && CMD="help"

handle_error() {
  local exit_code=$1
  local error_message="$2"
  if [ -z "$exit_code" ] || [ "$exit_code" == "0" ]; then
    exit_code=1
  fi
  echo -e "error: $error_message (Exit Code: $exit_code)"
  exit $exit_code
}

do_check_start() {
  if [ $UID -ne 0 ]; then
    handle_error "1" "This script can only run with Superuser privileges!"
  fi
  if ! [ -f "/etc/debian_version" ]; then
    handle_error "1" "This script is only supported on Debian-based systems."
  fi
  local apt
  local apt_res=""
  IFS=$' '
  if [ "${#PREREQS[@]}" -ne 0 ]; then
    for apt in "${PREREQS[@]}"; do
      if ! dpkg -s "$apt" &>/dev/null || ! dpkg -s "$apt" | grep -q "Status: install ok installed"; then
        apt_res+="${apt}, "
      fi
    done
    [ -n "$apt_res" ] && handle_error "1" "Not installed APT packages: ${apt_res%, }! Cannot continue with this script!"
  fi
  unset IFS
}

scripts_setup() {
  local filetype
  local entry
  local test
  local old_IFS="$IFS"
  IFS=$'\n'
  test=($(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "*-installer.sh" 2>/dev/null))
  if [ "${#test[@]}" != "0" ]; then
    for entry in "${test[@]}"; do
      filetype=$(file -b --mime-type "$entry" 2>/dev/null)
      if [[ "$filetype" =~ "text" ]]
      then
        sed -i 's/\r$//g' "$entry" >/dev/null 2>&1
        filetype="$(file -b --mime-type ""$entry"" 2>/dev/null)"
      fi
      if [[ "$filetype" =~ "executable" ]] || [[ "$filetype" =~ "script" ]] || [[ "$entry" == *".sh" ]]; then
        chmod -f 755 "$entry"
        "$entry" $1 $quiet $force
      fi
    done
  fi
  IFS="$old_IFS"
}

deb_setup() {
  local filetype
  local pkg_arch
  local entry
  local test
  local old_IFS="$IFS"
  IFS=$'\n'
  test=($(find "$SCRIPT_DIR" -maxdepth 1 -type f -name "*.deb" 2>/dev/null))
  if [ "${#test[@]}" != "0" ]; then
    local apt_opts=()
    if [ "$1" == "" ]; then
      [ "$force" != "" ] && apt_opts=( --reinstall --allow-downgrades )
      [ "$quiet" == "" ] && echo -n "--> run apt-get update ... "
      apt-get -qy update >/dev/null 2>&1
      if [ $? -ne 0 ]; then 
        [ "$quiet" == "" ] && echo "error." || echo "apt-get update error! abort."
        exit 1
      fi
      [ "$quiet" == "" ] && echo "done."
    fi
    for entry in "${test[@]}"; do
      filetype=$(file -b --mime-type "$entry" 2>/dev/null)
      if [[ "$filetype" =~ "package" ]]; then
        pkg_arch=$(dpkg-deb -f "$entry" Architecture 2>/dev/null)
        if [ "$pkg_arch" = "$SYS_ARCH" ] || [ "$pkg_arch" = "all" ]; then
          if [ "$quiet" != "" ] && [ "$1" == "" ]; then
            apt-get install -qq "${apt_opts[@]}" "$entry" >/dev/null 2>&1
          elif [ "$1" == "" ]; then
            apt-get install -qq "${apt_opts[@]}" "$entry"
          elif [ "$quiet" != "" ] && [ "$1" == "-d" ]; then
            apt-get remove -qq "$(dpkg-deb -W "$entry" | cut -d$'\t' -f1)" >/dev/null 2>&1
          elif [ "$1" == "-d" ]; then
            apt-get remove -qq "$(dpkg-deb -W "$entry" | cut -d$'\t' -f1)"
          fi
        else
          [ -z "$quiet" ] && echo "Skipping $entry (arch: $pkg_arch, needed: $SYS_ARCH)"
        fi
      fi
    done
  fi
  IFS="$old_IFS"
}

function cmd_install() {
  scripts_setup
  deb_setup
}

function cmd_deinstall() {
  scripts_setup -d
  deb_setup -d
}

function cmd_print_version() {
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
}

function cmd_print_help() {
  echo "Usage: $SCRIPT_NAME [OPTION]"
  echo "$SCRIPT_TITLE v$SCRIPT_VERSION"
  echo " "
  echo "runs all installer scripts that ends with '-installer.sh'"
  echo "and debian installer packages (.deb)"
  echo "in the same directory as this script"
  echo " "
  echo "-i, --install           install all scripts and packages"
  echo "-d, --deinstall         deinstall all scripts and packages"
  echo "-f, --force             force deinstall or reinstall all scripts and packages"
  echo "-q, --quiet             do not print informations while de/installation"
  echo "-v, --version           print version info and exit"
  echo "-h, --help              print this help and exit"
  echo " "
  echo "Author: aragon25 <aragon25.01@web.de>"
}

[ "$CMD" != "version" ] && [ "$CMD" != "help" ] &&  do_check_start
[[ "$CMD" == "version" ]] && cmd_print_version
[[ "$CMD" == "help" ]] && cmd_print_help
[[ "$CMD" == "install" ]] && cmd_install
[[ "$CMD" == "deinstall" ]] && cmd_deinstall

exit 0
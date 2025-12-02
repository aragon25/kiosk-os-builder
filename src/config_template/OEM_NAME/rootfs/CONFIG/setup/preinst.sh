#!/bin/bash
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_NAME="$(basename "$SCRIPT_PATH")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
export LC_ALL=C
export LANG=C

for i in "$@"
do
  case $i in
    -V|--verbose)
    verbose="--verbose"
    shift # past argument
    ;;
    -q|--quiet)
    quiet="--quiet"
    shift # past argument
    ;;
    -f|--force)
    force="--force"
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

[ -z "$quiet" ] && echo "preinst $1 $2 $3"

exit 0
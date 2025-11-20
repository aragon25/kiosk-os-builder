#!/bin/bash
SCRIPT_DIR="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_DIR")"
sudo chmod +x "${SCRIPT_DIR}/builder/build_images.sh"
"${SCRIPT_DIR}/builder/build_images.sh" -C="$SCRIPT_DIR/config/bullseye-rpi3-full.conf"

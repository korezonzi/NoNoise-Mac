#!/bin/bash
set -euo pipefail
DEST="/Library/Audio/Plug-Ins/HAL/NoNoiseMic.driver"
sudo rm -rf "$DEST"
sudo killall coreaudiod 2>/dev/null || true
echo "Removed NoNoise Mic. (Audio dropped briefly to restart coreaudiod.)"

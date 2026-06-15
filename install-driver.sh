#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DRIVER="NoNoiseMic.driver"
DEST="/Library/Audio/Plug-Ins/HAL"
[ -d "$DRIVER" ] || { echo "Build first: ./build-driver.sh"; exit 1; }
echo "Installing to $DEST (requires admin; ALL audio will briefly drop on coreaudiod restart)…"
sudo rm -rf "$DEST/$DRIVER"
sudo cp -R "$DRIVER" "$DEST/"
sudo killall coreaudiod 2>/dev/null || true
sleep 3
# Verify: the device must now exist. system_profiler is the simplest user-space probe; the
# authoritative check is the app's driverInstalled state (UID translate) on next device scan.
if system_profiler SPAudioDataType 2>/dev/null | grep -q "NoNoise Mic"; then
  echo "✅ NoNoise Mic installed and visible."
else
  echo "❌ NoNoise Mic did NOT appear. Check Console.app for coreaudiod plug-in errors"
  echo "   (common causes: bad CFPlugInFactories/CFPlugInTypes keys, invalid signature)."
  exit 1
fi

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
# Verify: both device pairs published by the plug-in must now exist. system_profiler is the
# simplest user-space probe; the authoritative check is the app's driverInstalled state (UID
# translate) on next device scan. "NoNoise Mic" also matches the hidden "NoNoise Mic Engine" and
# "NoNoise Speaker" also matches "NoNoise Speaker Tap" (both hidden devices are still listed here;
# system_profiler enumerates them even though the HAL enumeration API excludes hidden devices).
PROFILE="$(system_profiler SPAudioDataType 2>/dev/null || true)"
MIC_OK=0; SPEAKER_OK=0
echo "$PROFILE" | grep -q "NoNoise Mic" && MIC_OK=1
echo "$PROFILE" | grep -q "NoNoise Speaker" && SPEAKER_OK=1
if [ "$MIC_OK" = 1 ] && [ "$SPEAKER_OK" = 1 ]; then
  echo "✅ NoNoise Mic and NoNoise Speaker installed and visible."
else
  [ "$MIC_OK" = 1 ] || echo "❌ NoNoise Mic did NOT appear."
  [ "$SPEAKER_OK" = 1 ] || echo "❌ NoNoise Speaker did NOT appear."
  echo "   Check Console.app for coreaudiod plug-in errors"
  echo "   (common causes: bad CFPlugInFactories/CFPlugInTypes keys, invalid signature)."
  exit 1
fi

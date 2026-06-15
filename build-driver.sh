#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
DRIVER="NoNoiseMic.driver"
SRC="Driver/NoNoiseMic"
rm -rf "$DRIVER"
mkdir -p "$DRIVER/Contents/MacOS"
cp "$SRC/Info.plist" "$DRIVER/Contents/Info.plist"
clang -bundle -std=c11 -O2 -arch arm64 \
  -framework CoreAudio -framework CoreFoundation -framework AudioToolbox \
  "$SRC/NoNoiseMic.c" "$SRC/nn_ring.c" "$SRC/nn_clock.c" \
  -o "$DRIVER/Contents/MacOS/NoNoiseMic"
# Sign AFTER the bundle is fully assembled — any post-sign edit invalidates the signature and the
# plug-in then silently fails to load in coreaudiod.
codesign --force --sign - "$DRIVER"
codesign -dv --verbose=4 "$DRIVER" 2>&1 | sed -n '1,6p'
echo "Built $DRIVER"

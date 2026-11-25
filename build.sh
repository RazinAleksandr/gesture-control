#!/bin/bash
# Builds build/GestureControl.app (stable launcher, built once) + build/libGestureCore.dylib (all logic).
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build
APP=build/GestureControl.app
if [ ! -x "$APP/Contents/MacOS/GestureControl" ] || [ "${REBUILD_LAUNCHER:-0}" = 1 ]; then
  mkdir -p "$APP/Contents/MacOS"
  cp Launcher/Info.plist "$APP/Contents/Info.plist"
  xcrun clang -O2 -mmacosx-version-min=14.0 -o "$APP/Contents/MacOS/GestureControl" Launcher/main.c
  codesign --force --sign - --identifier dev.local.gesturecontrol "$APP"
  echo "launcher built"
fi
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -emit-library -module-name GestureCore \
  -o build/libGestureCore.dylib Sources/*.swift \
  -framework AppKit -framework AVFoundation -framework Vision -framework CoreMedia \
  -framework QuartzCore -framework ApplicationServices
echo "core built"

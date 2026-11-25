#!/bin/bash
# Builds a standalone, universal (Apple Silicon + Intel) "Gesture Control.app" and a zip for releases.
#   scripts/build-app.sh   →  dist/Gesture Control.app, dist/GestureControl-macOS.zip
set -euo pipefail
cd "$(dirname "$0")/.."
APP="dist/Gesture Control.app"
rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist/obj

echo "• icon"
swift scripts/make-icon.swift dist/obj/AppIcon.iconset
iconutil -c icns dist/obj/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

echo "• Info.plist"
python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open("Launcher/Info.plist", "rb"))
p["CFBundleIdentifier"] = "io.github.razinaleksandr.gesturecontrol"
p["CFBundleIconFile"] = "AppIcon"
p["NSHumanReadableCopyright"] = "MIT License"
plistlib.dump(p, open(sys.argv[1], "wb"))
PY

echo "• compile (arm64 + x86_64)"
FRAMEWORKS="-framework AppKit -framework AVFoundation -framework Vision -framework CoreMedia -framework QuartzCore -framework ApplicationServices"
for ARCH in arm64 x86_64; do
  xcrun swiftc -O -swift-version 5 -target $ARCH-apple-macos14.0 -module-name GestureControl \
    -o dist/obj/GestureControl-$ARCH Sources/*.swift Launcher/main.swift $FRAMEWORKS
done
lipo -create dist/obj/GestureControl-arm64 dist/obj/GestureControl-x86_64 -output "$APP/Contents/MacOS/GestureControl"

echo "• sign (ad-hoc) and zip"
codesign --force --deep --sign - "$APP"
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$APP" dist/GestureControl-macOS.zip
rm -rf dist/obj
echo "done: $APP"
ls -lh dist/GestureControl-macOS.zip

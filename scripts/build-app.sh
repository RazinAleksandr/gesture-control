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
p["CFBundleDevelopmentRegion"] = "en"
p["CFBundleLocalizations"] = ["en", "ru", "zh-Hans"]
p["NSCameraUsageDescription"] = "The camera is used to see your hand gestures. Video is processed only on this Mac and never leaves it."
plistlib.dump(p, open(sys.argv[1], "wb"))
PY
for L in en ru zh-Hans; do mkdir -p "$APP/Contents/Resources/$L.lproj"; done
printf '"NSCameraUsageDescription" = "The camera is used to see your hand gestures. Video is processed only on this Mac and never leaves it.";\n' > "$APP/Contents/Resources/en.lproj/InfoPlist.strings"
printf '"NSCameraUsageDescription" = "Камера нужна, чтобы видеть жесты руки. Видео обрабатывается только на этом Mac и никуда не отправляется.";\n' > "$APP/Contents/Resources/ru.lproj/InfoPlist.strings"
printf '"NSCameraUsageDescription" = "需要使用摄像头识别你的手势。视频只在这台 Mac 上处理，不会离开设备。";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

echo "• compile (arm64 + x86_64)"
FRAMEWORKS="-framework AppKit -framework AVFoundation -framework Vision -framework CoreMedia -framework QuartzCore -framework ApplicationServices -framework SwiftUI"
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

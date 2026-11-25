#!/bin/bash
# Regenerates the README images in docs/ from REAL screenshots of the running UI.
# Takes over the screen for ~2 minutes (a wallpaper window covers your desktop; the camera is not used).
# Needs Screen Recording permission for the terminal, and ffmpeg.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
FW="-framework AppKit -framework AVFoundation -framework Vision -framework CoreMedia -framework QuartzCore -framework ApplicationServices -framework SwiftUI"

swift scripts/make-icon.swift build/icon.iconset build/icon512.png
cp build/icon512.png docs/icon.png && sips -Z 256 docs/icon.png >/dev/null

echo "• screenshots"
xcrun swiftc -O -swift-version 5 -o build/shots Sources/*.swift scripts/shots/main.swift $FW
rm -rf build/shots-out
build/shots build/shots-out

echo "• banners"
xcrun swiftc -O -swift-version 5 -o build/render-assets Sources/*.swift scripts/assets/main.swift $FW
build/render-assets docs build/shots-out build/icon512.png

echo "• assemble"
for L in en ru zh; do
  SFX=""; [ "$L" != en ] && SFX="-$L"
  D=build/shots-out/$L
  ffmpeg -loglevel error -y -framerate 20 -i $D/frames/f%03d.jpg \
    -vf "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=200[p];[b][p]paletteuse=dither=sierra2_4a" \
    -loop 0 docs/demo$SFX.gif
  cp $D/hud.png docs/hud$SFX.png && sips -Z 820 docs/hud$SFX.png >/dev/null
  cp $D/hud-collapsed.png docs/hud-collapsed$SFX.png && sips -Z 820 docs/hud-collapsed$SFX.png >/dev/null
  cp $D/toast.png docs/toast$SFX.png && sips -Z 700 docs/toast$SFX.png >/dev/null
  sips -Z 1500 -s format jpeg -s formatOptions 88 $D/guide.png --out docs/guide$SFX.jpg >/dev/null
  sips -Z 1600 docs/banner$SFX.png >/dev/null
done
ls -lh docs

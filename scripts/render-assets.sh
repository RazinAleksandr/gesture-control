#!/bin/bash
# Regenerates README images in docs/ (needs ffmpeg for the GIF).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swift scripts/make-icon.swift build/icon.iconset build/icon512.png
cp build/icon512.png docs/icon.png && sips -Z 256 docs/icon.png >/dev/null
xcrun swiftc -O -swift-version 5 -o build/render-assets Sources/*.swift scripts/assets/main.swift \
  -framework AppKit -framework AVFoundation -framework Vision -framework CoreMedia -framework QuartzCore \
  -framework ApplicationServices -framework SwiftUI
rm -rf build/frames
build/render-assets docs build/frames build/icon512.png
ffmpeg -loglevel error -y -framerate 20 -i build/frames/f%03d.png \
  -vf "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=192[p];[b][p]paletteuse=dither=sierra2_4a" \
  -loop 0 docs/demo.gif
sips -Z 1400 -s format jpeg -s formatOptions 88 docs/guide.png --out docs/guide.jpg >/dev/null && rm docs/guide.png
sips -Z 1600 docs/banner.png >/dev/null
ls -lh docs

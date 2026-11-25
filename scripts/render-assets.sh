#!/bin/bash
# Regenerates README images in docs/ (needs ffmpeg for the GIF).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -O -swift-version 5 -o build/render-assets Sources/*.swift scripts/assets/main.swift \
  -framework AppKit -framework AVFoundation -framework Vision -framework CoreMedia -framework QuartzCore -framework ApplicationServices
rm -rf build/frames
build/render-assets docs build/frames
ffmpeg -loglevel error -y -framerate 20 -i build/frames/f%03d.png \
  -vf "scale=960:-1:flags=lanczos,split[a][b];[a]palettegen=max_colors=160[p];[b][p]paletteuse=dither=sierra2_4a" \
  -loop 0 docs/demo.gif
swift scripts/make-icon.swift build/icon.iconset docs/icon.png && sips -Z 256 docs/icon.png >/dev/null
ls -lh docs/demo.gif docs/hud.png docs/icon.png

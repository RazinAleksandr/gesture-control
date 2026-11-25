#!/bin/bash
# Starts the app as its own process (so macOS asks permissions for "Gesture Control", not for the terminal).
cd "$(dirname "$0")"
pkill -f "GestureControl.app/Contents/MacOS/GestureControl" 2>/dev/null && sleep 0.5
: > build/run.log
open -n build/GestureControl.app --stdout "$PWD/build/run.log" --stderr "$PWD/build/run.log" --args "$@"
echo "started; log: $PWD/build/run.log"

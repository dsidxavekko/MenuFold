#!/usr/bin/env bash
# Generate the Xcode project and build MenuFold (Debug). `scripts/build.sh run` also (re)launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

# Use full Xcode without needing `sudo xcode-select` when the active dir is only Command Line Tools.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* && -d /Applications/Xcode.app ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

xcodegen generate
xcodebuild -project MenuFold.xcodeproj -scheme MenuFold -configuration Debug -derivedDataPath build build

APP="$(pwd)/build/Build/Products/Debug/MenuFold.app"
echo "Built: $APP"

if [[ "${1:-}" == "run" ]]; then
    pkill -x MenuFold 2>/dev/null || true
    sleep 0.5
    open "$APP"
fi

#!/usr/bin/env bash
# Generate the Xcode project and run the App/ unit tests (target MenuFoldTests, hosted by the app).
# Extra arguments go to xcodebuild, e.g. scripts/test-app.sh -only-testing:MenuFoldTests/GridMetricsTests
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == *CommandLineTools* ]]; then
    for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode*.app/Contents/Developer; do
        if [[ -d "$candidate" ]]; then
            export DEVELOPER_DIR="$candidate"
            break
        fi
    done
fi

xcodegen generate
# Same derived data as scripts/build.sh, so the build is shared.
xcodebuild test -project MenuFold.xcodeproj -scheme MenuFold -configuration Debug \
    -destination 'platform=macOS' -derivedDataPath build "$@"

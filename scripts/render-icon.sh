#!/usr/bin/env bash
# Renders Design/AppIcon.svg into every PNG of App/Assets.xcassets/AppIcon.appiconset.
# Uses headless Google Chrome (no other SVG renderer is needed). Re-run after editing the SVG.
set -euo pipefail
cd "$(dirname "$0")/.."

chrome="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
[[ -x "$chrome" ]] || { echo "error: Google Chrome not found at $chrome" >&2; exit 1; }

svg="$PWD/Design/AppIcon.svg"
out="App/Assets.xcassets/AppIcon.appiconset"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

render() { # size, file
    local size=$1 file=$2
    printf '<!doctype html><style>html,body{margin:0;background:transparent}</style><img src="file://%s" width="%s" height="%s" style="display:block">' \
        "$svg" "$size" "$size" > "$tmp/page.html"
    "$chrome" --headless=new --disable-gpu --hide-scrollbars --default-background-color=00000000 \
        --force-device-scale-factor=1 --window-size="$size,$size" \
        --screenshot="$tmp/shot.png" "file://$tmp/page.html" >/dev/null 2>&1
    mv "$tmp/shot.png" "$out/$file"
}

for base in 16 32 128 256 512; do
    render "$base" "icon_${base}x${base}.png"
    render "$((base * 2))" "icon_${base}x${base}@2x.png"
done
echo "Rendered $(ls "$out"/*.png | wc -l | tr -d ' ') PNGs into $out"

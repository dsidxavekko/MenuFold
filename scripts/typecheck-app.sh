#!/usr/bin/env bash
# Typecheck App/ against the built MenuFoldCore package without building the whole app.
# Used by agents and CI: fast (~10 s) and needs only the Swift toolchain.
#
# App/ cannot be typechecked in place without Xcode because @State and #Preview are macros whose
# plugins ship only with Xcode (see CLAUDE.md). When Xcode is installed this script uses it, so the
# real sources are checked. Without Xcode it falls back to a scratch copy with `@State` aliased to
# `SwiftUI.State` and the `#Preview` blocks stripped.
#
# Usage: scripts/typecheck-app.sh            # quiet, exit code only
#        scripts/typecheck-app.sh -v       # keep the scratch dir and print the full log path
set -euo pipefail
cd "$(dirname "$0")/.."

verbose="${1:-}"
pkg="Packages/MenuFoldCore"

echo "== building $pkg =="
(cd "$pkg" && swift build)

repo="$(pwd)"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/menufold-typecheck.XXXXXX")"
trap 'if [[ -z "$verbose" ]]; then rm -rf "$scratch"; else echo "scratch: $scratch"; fi' EXIT

log="$scratch/typecheck.log"

if [[ -x /Applications/Xcode.app/Contents/Developer/usr/bin/swiftc ]]; then
    echo "== typechecking App/ with Xcode =="
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun swiftc -typecheck -swift-version 5 \
        -target arm64-apple-macosx26.0 \
        -I "$pkg/.build/out/Products/Debug" \
        -I "$pkg/.build/debug" \
        $(find App -name '*.swift') >"$log" 2>&1 || { cat "$log"; exit 1; }
else
    echo "== typechecking App/ with Command Line Tools (scratch copy) =="
    mkdir -p "$scratch/App"
    while IFS= read -r -d '' f; do
        rel="${f#App/}"
        mkdir -p "$(dirname "$scratch/App/$rel")"
        python3 - "$f" "$scratch/App/$rel" <<'PY'
import re, sys
src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()
# Strip every #Preview { ... } block (balanced braces).
out, i = [], 0
while True:
    j = text.find('#Preview', i)
    if j < 0:
        out.append(text[i:]); break
    out.append(text[i:j])
    k = text.find('{', j)
    depth = 0
    while k < len(text):
        if text[k] == '{': depth += 1
        elif text[k] == '}':
            depth -= 1
            if depth == 0: break
        k += 1
    out.append('\n')
    i = k + 1
text = ''.join(out)
# @State -> MenuFoldStateShim: SwiftUI.State's own setter is mutating, but the @State macro expands
# to a nonmutating setter, so Views write to it from plain methods. The shim reproduces that.
text = re.sub(r'(?<![\w.\$])@State\b(?!\s*\.)', '@MenuFoldStateShim ', text)
# @Entry (the EnvironmentValues macro, also Xcode-only) -> a generated EnvironmentKey + property.
def entry(m):
    name, default = m.group(1), m.group(2)
    return ('var %s: Bool { get { self[MenuFoldEntryKey_%s.self] } set { self[MenuFoldEntryKey_%s.self] = newValue } }\n'
            'private struct MenuFoldEntryKey_%s: EnvironmentKey { static let defaultValue = %s }' % (name, name, name, name, default))
text = re.sub(r'@Entry var (\w+) = (\w+)', entry, text)
open(dst, 'w', encoding='utf-8').write(text)
PY
    done < <(find App -name '*.swift' -print0)

    import_dirs=()
    for d in "$pkg/.build/out/Products/Debug" "$pkg/.build/debug" "$pkg/.build/arm64-apple-macosx/debug"; do
        [[ -d "$d" ]] && import_dirs+=(-I "$d")
    done
    cat > "$scratch/StateShim.swift" <<'SWIFT'
import SwiftUI

/// Stand-in for the @State macro (its plugin ships only with Xcode).
@propertyWrapper struct MenuFoldStateShim<Value> {
    private final class Box { var value: Value; init(_ v: Value) { value = v } }
    private let box: Box
    init(wrappedValue: Value) { box = Box(wrappedValue) }
    var wrappedValue: Value {
        get { box.value }
        nonmutating set { box.value = newValue }
    }
    var projectedValue: Binding<Value> {
        Binding(get: { [box] in box.value }, set: { [box] in box.value = $0 })
    }
}
SWIFT
    xcrun swiftc -typecheck -swift-version 5 -target arm64-apple-macosx26.0 \
        "${import_dirs[@]}" "$scratch/StateShim.swift" $(find "$scratch/App" -name '*.swift') >"$log" 2>&1 || { cat "$log"; exit 1; }
fi

echo "OK: App/ typechecks"

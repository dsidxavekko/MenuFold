#!/usr/bin/env bash
# Typecheck App/ against the built MenuFoldCore package (no full app build, no signing).
# Fast (~5 s) and needs only the Swift toolchain, so agents and CI can run it.
#
# App/ cannot be typechecked in place without Xcode: @State, @Entry and #Preview are macros whose
# plugins ship only with Xcode (see CLAUDE.md). When Xcode is installed this script checks the real
# sources. Without Xcode it checks a scratch copy in which:
#   - `@State`  becomes a stand-in property wrapper with a nonmutating setter and `$value` binding
#               (the same shape the macro expands to),
#   - `@Entry`  becomes an explicit EnvironmentKey + computed property,
#   - `#Preview` blocks are wrapped in `#if canImport(XcodeSupport)` so they stay unparsed.
# The copy is checked with `-parse-as-library` (App has @main) and `-warnings-as-errors` is NOT set,
# so only real errors fail the run.
#
# Usage: scripts/typecheck-app.sh        # quiet: exit code only
#        scripts/typecheck-app.sh -v   # keep the scratch dir and print it
set -euo pipefail
cd "$(dirname "$0")/.."

verbose="${1:-}"
pkg="Packages/MenuFoldCore"

echo "== building $pkg =="
(cd "$pkg" && swift build 2>&1 | grep -E "error|Build complete" || true)

# Where the built MenuFoldCore module lives. Ask SwiftPM instead of guessing the directory name
# (it varies between Xcode and Command Line Tools toolchains and between host platforms).
import_args=()
while IFS= read -r dir; do
    [[ -n "$dir" && -d "$dir" ]] && import_args+=(-I "$dir")
done < <(cd "$pkg" && swift build --show-bin-path 2>/dev/null)
if [[ ${#import_args[@]} -eq 0 ]]; then
    echo "error: cannot locate the built MenuFoldCore module" >&2
    exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/menufold-typecheck.XXXXXX")"
trap 'if [[ -z "$verbose" ]]; then rm -rf "$scratch"; else echo "scratch: $scratch"; fi' EXIT
log="$scratch/typecheck.log"

# A full Xcode, not just its Command Line Tools: only Xcode ships the SwiftUI macro plugins, and
# whether xcode-select points at it is often not the case on a machine that has both installed.
xcode_swiftc="$(DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun -f swiftc 2>/dev/null || true)"
if [[ -n "$xcode_swiftc" && -x "$xcode_swiftc" ]]; then
    echo "== typechecking App/ with Xcode =="
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
        xcrun swiftc -typecheck -warnings-as-errors -parse-as-library -swift-version 5 -target arm64-apple-macosx26.0 \
        "${import_args[@]}" $(find App -name '*.swift') >"$log" 2>&1 || { cat "$log"; exit 1; }
else
    echo "== typechecking App/ without Xcode (scratch copy) =="
    mkdir -p "$scratch/App"
    while IFS= read -r -d '' f; do
        rel="${f#App/}"
        mkdir -p "$(dirname "$scratch/App/$rel")"
        python3 - "$f" "$scratch/App/$rel" <<'PY'
import re, sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src, encoding='utf-8').read()


def block_end(text, start):
    """Index of the '}' closing the brace block that starts at/after `start`."""
    k = text.find('{', start)
    depth = 0
    while k < len(text):
        if text[k] == '{':
            depth += 1
        elif text[k] == '}':
            depth -= 1
            if depth == 0:
                return k
        k += 1
    return len(text) - 1


# #Preview { ... } -> #if canImport(XcodeSupport) #Preview { ... } #endif
out, i = [], 0
while True:
    j = text.find('#Preview', i)
    if j < 0:
        out.append(text[i:])
        break
    k = block_end(text, j)
    out.append(text[i:j])
    out.append('#if canImport(XcodeSupport)\n' + text[j:k + 1] + '\n#endif\n')
    i = k + 1
text = ''.join(out)

# @State -> stand-in wrapper (SwiftUI.State's own setter is mutating; the macro's is not).
text = re.sub(r'(?<![\w.\$])@State\b(?!\s*\.)', '@MenuFoldStateShim ', text)


# @Entry var x = false -> computed property backed by a generated EnvironmentKey. The key must be
# at file scope, so the generated code closes the enclosing extension and reopens it afterwards.
def entry(m):
    name, default = m.group(1), m.group(2)
    return ('var %s: Bool {\n'
            '        get { self[MenuFoldEntryKey_%s.self] }\n'
            '        set { self[MenuFoldEntryKey_%s.self] = newValue }\n'
            '    }\n'
            '}\n'
            'struct MenuFoldEntryKey_%s: EnvironmentKey { static let defaultValue = %s }\n'
            'extension EnvironmentValues {' % (name, name, name, name, default))


text = re.sub(r'@Entry var (\w+) = (\w+)', entry, text)

open(dst, 'w', encoding='utf-8').write(text)
PY
    done < <(find App -name '*.swift' -print0)

    cat > "$scratch/StateShim.swift" <<'SWIFT'
import SwiftUI

/// Stand-in for the @State macro (its plugin ships only with Xcode): nonmutating setter + $binding.
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

    xcrun swiftc -typecheck -warnings-as-errors -parse-as-library -swift-version 5 -target arm64-apple-macosx26.0 \
        "${import_args[@]}" "$scratch/StateShim.swift" $(find "$scratch/App" -name '*.swift') \
        >"$log" 2>&1 || { cat "$log"; exit 1; }
fi

echo "OK: App/ typechecks"

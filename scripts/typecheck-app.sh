#!/usr/bin/env bash
# Typecheck App/ against the built MenuFoldCore package (no full app build, no signing).
# Fast (~5 s) and needs only the Swift toolchain, so agents and CI can run it.
#
# App/ cannot be typechecked in place without Xcode: @State, @Entry and #Preview are macros whose
# plugins ship only with Xcode (see CLAUDE.md). With a full Xcode this script checks the real
# sources. Otherwise (Command Line Tools only, or a macOS SDK older than the app's deployment
# target) it checks a scratch copy in which:
#   - `@State`  becomes a stand-in property wrapper with a nonmutating setter and `$value` binding
#               (the same shape the macro expands to),
#   - `@Entry`  becomes an explicit EnvironmentKey + computed property,
#   - `#Preview` blocks are wrapped in `#if canImport(XcodeSupport)` so they stay unparsed.
# The copy is checked with `-parse-as-library` (App has @main) and `-warnings-as-errors` is NOT set,
# so only real errors fail the run.
#
# One toolchain, start to finish: the package module and the App/ typecheck are always produced by
# the SAME swift (the `DEVELOPER_DIR` chosen below). Mixing them (e.g. a module built by Command Line
# Tools' swift then read by Xcode's swiftc, or vice versa) is what broke CI on runners where
# `xcode-select` points at the Command Line Tools while `/Applications/Xcode.app` also exists.
#
# Usage: scripts/typecheck-app.sh        # quiet: exit code only
#        scripts/typecheck-app.sh -v   # keep the scratch dir and print diagnostics
# Env:   MENUFOLD_TYPE_CHECK=real|shim|auto   (default auto; CI uses this to forbid the shim)
#        MENUFOLD_MIN_SDK_MAJOR=26             (minimum macOS SDK for the real check)
set -euo pipefail
cd "$(dirname "$0")/.."

verbose="${1:-}"
pkg="Packages/MenuFoldCore"
min_sdk_major="${MENUFOLD_MIN_SDK_MAJOR:-26}"
mode="${MENUFOLD_TYPE_CHECK:-auto}"
case "$mode" in
    auto|real|shim) ;;
    *) echo "error: MENUFOLD_TYPE_CHECK must be auto, real or shim (got '$mode')" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------------------------------
# Toolchain: pick one DEVELOPER_DIR and keep it for both the package build and the typecheck.
# ---------------------------------------------------------------------------------------------------
# Find a full Xcode anywhere under /Applications: GitHub runners install it as
# /Applications/Xcode_26.6.app, and a hard-coded Xcode.app path made CI fall back to the CLT.
xcode_dir=""
for candidate in "${MENUFOLD_XCODE_DEVELOPER_DIR:-}" /Applications/Xcode.app/Contents/Developer /Applications/Xcode*.app/Contents/Developer; do
    [[ -n "$candidate" && -d "$candidate" ]] || continue
    if DEVELOPER_DIR="$candidate" xcrun -f swiftc >/dev/null 2>&1; then
        xcode_dir="$candidate"
        break
    fi
done
has_xcode=false
[[ -n "$xcode_dir" ]] && has_xcode=true
if [[ "$has_xcode" == true ]]; then
    export DEVELOPER_DIR="$xcode_dir"
    # /Applications/Xcode_26.6.app/Contents/Developer -> "Xcode_26.6.app"
    toolchain="Xcode ($(basename "$(cd "$xcode_dir/../.." && pwd)"))"
    # The shim is only for a CLT-only machine; when Xcode is there, the CLT's swift must never build
    # the module. Forcing the Xcode toolchain again makes that impossible even with the shim forced.
    if [[ "$mode" == "shim" ]]; then export TOOLCHAINS=com.apple.dt.toolchain.XcodeDefault; fi
else
    toolchain="$(xcode-select -p 2>/dev/null || echo "unknown")"
fi

swift_version="unknown"
sdk_version="unknown"
sdk_major=0
if command -v swift >/dev/null 2>&1; then
    swift_version="$(swift --version 2>&1 | head -1)"
    sdk_version="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || echo unknown)"
fi
if [[ "$sdk_version" =~ ^([0-9]+) ]]; then
    sdk_major="${BASH_REMATCH[1]}"
else
    sdk_major=0
fi

# ---------------------------------------------------------------------------------------------------
# Branch: real sources need Xcode (macro plugins) AND an SDK at least as new as the app targets.
# ---------------------------------------------------------------------------------------------------
branch="shim"
skip_reason=""
if [[ "$mode" == "shim" ]]; then
    skip_reason="MENUFOLD_TYPE_CHECK=shim"
elif [[ "$has_xcode" == false ]]; then
    skip_reason="no full Xcode at $xcode_dir (Command Line Tools have no SwiftUI macro plugins)"
elif (( sdk_major < min_sdk_major )); then
    skip_reason="macOS SDK $sdk_version < $min_sdk_major, the app targets macOS $min_sdk_major"
else
    branch="real"
fi

if [[ "$mode" == "real" && "$branch" != "real" ]]; then
    echo "error: MENUFOLD_TYPE_CHECK=real but the real check cannot run: $skip_reason" >&2
    exit 1
fi
if [[ "$branch" == "shim" && -n "${CI:-}" ]]; then
    echo "error: refusing to run the shimmed typecheck on CI ($skip_reason):" >&2
    echo "       its stand-ins are not the real macros, so it can pass while the app does not build." >&2
    echo "       Set MENUFOLD_TYPE_CHECK=auto to build the app with xcodebuild instead." >&2
    exit 1
fi

diagnostics() {
    echo "---- typecheck-app diagnostics ----------------------------------------"
    echo "branch:        $branch$([[ -n "$skip_reason" ]] && echo " (reason: $skip_reason)")"
    echo "toolchain:     $toolchain"
    echo "DEVELOPER_DIR: ${DEVELOPER_DIR:-<unset, xcode-select>}"
    echo "swift:         $swift_version"
    echo "macOS SDK:     $sdk_version (need >= $min_sdk_major for the real check)"
    echo "module path:   ${import_args[*]:-<none>}"
    echo "host:          $(uname -m) $(sw_vers -productVersion 2>/dev/null || true)"
    echo "----------------------------------------------------------------------"
}

fail() {
    # `fail <message> [log]`: print diagnostics and the log head, then exit 1.
    echo "error: $1" >&2
    diagnostics >&2
    if [[ -n "${2:-}" && -s "$2" ]]; then
        echo "---- compiler output (first 60 lines of $(wc -l <"$2" | tr -d ' ') ) ----" >&2
        head -60 "$2" >&2
    fi
    exit 1
}

# CI must judge the real thing: a run that falls back to the shim there would prove nothing.
if [[ -n "${GITHUB_ACTIONS:-}" && "$branch" != "real" ]]; then
    echo "error: on GitHub Actions the real App/ typecheck is required, but: $skip_reason" >&2
    exit 1
fi

scratch="$(mktemp -d "${TMPDIR:-/tmp}/menufold-typecheck.XXXXXX")"
trap 'if [[ -z "$verbose" ]]; then rm -rf "$scratch"; else echo "scratch: $scratch"; fi' EXIT
log="$scratch/typecheck.log"

echo "== building $pkg ($toolchain) =="
build_log="$scratch/build.log"
(cd "$pkg" && swift build) >"$build_log" 2>&1 || fail "swift build failed" "$build_log"
grep -E "Build complete" "$build_log" || true

# Where the built MenuFoldCore module lives. Ask SwiftPM (from the same DEVELOPER_DIR) instead of
# guessing the directory name, then require the module to really be there: `swift build --show-bin-path`
# happily prints a path even when that build failed, which is exactly how CI ended up with
# "no such module 'MenuFoldCore'" instead of the real error.
bin_path="$(cd "$pkg" && swift build --show-bin-path 2>/dev/null || true)"
import_args=()
declare -a bin_candidates=("$bin_path" "$pkg/.build/debug" "$pkg/.build/out/Products/Debug" "$pkg/.build/arm64-apple-macosx/debug")
# Newer SwiftPM (e.g. Swift 6.3 on CI) puts the module in a Modules/ subfolder of the bin path.
for base in "${bin_candidates[@]}"; do
    [[ -n "$base" ]] && bin_candidates+=("$base/Modules")
done
for dir in "${bin_candidates[@]}"; do
    [[ -n "$dir" && -d "$dir" ]] || continue
    # A directory in older SwiftPM, a single file in Modules/ in newer ones (Swift 6.3).
    [[ -e "$dir/MenuFoldCore.swiftmodule" ]] || continue
    [[ " ${import_args[*]-} " == *" -I $dir "* ]] && continue
    import_args+=(-I "$dir")
done
if [[ ${#import_args[@]} -eq 0 ]]; then
    # Last resort for yet another layout: wherever SwiftPM put the module under .build.
    found="$(find "$pkg/.build" -maxdepth 6 -name MenuFoldCore.swiftmodule -not -path '*/index/*' 2>/dev/null | head -1)"
    [[ -n "$found" ]] && import_args+=(-I "$(dirname "$found")")
fi
if [[ ${#import_args[@]} -eq 0 ]]; then
    fail "cannot locate the built MenuFoldCore module (bin path: ${bin_path:-<none>})" "$build_log"
fi

# Sparkle (in-app updates) is a binary SwiftPM package that only xcodebuild downloads. When a build
# already fetched it, check App/Updater.swift against it; otherwise that file falls back to its
# `#if canImport(Sparkle)` no-op branch.
for fw in build/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-* \
          build-release/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-*; do
    if [[ -d "$fw/Sparkle.framework" ]]; then
        import_args+=(-F "$fw")
        break
    fi
done

if [[ "$branch" == "real" ]]; then
    echo "== typechecking App/ with Xcode =="
    declare -a app_sources=()
    while IFS= read -r -d '' f; do app_sources+=("$f"); done < <(find App -name '*.swift' -print0)
    xcrun swiftc -typecheck -warnings-as-errors -parse-as-library -swift-version 5 \
        -target "arm64-apple-macosx$min_sdk_major.0" \
        "${import_args[@]}" "${app_sources[@]}" >"$log" 2>&1 \
        || fail "App/ does not typecheck" "$log"
else
    echo "== typechecking App/ without Xcode (scratch copy) =="
    echo "   reason: $skip_reason"
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

    declare -a shim_sources=()
    while IFS= read -r -d '' f; do shim_sources+=("$f"); done < <(find "$scratch/App" -name '*.swift' -print0)
    xcrun swiftc -typecheck -warnings-as-errors -parse-as-library -swift-version 5 \
        -target "arm64-apple-macosx$min_sdk_major.0" \
        "${import_args[@]}" "$scratch/StateShim.swift" "${shim_sources[@]}" \
        >"$log" 2>&1 || fail "App/ does not typecheck (shimmed copy)" "$log"
fi

echo "OK: App/ typechecks"

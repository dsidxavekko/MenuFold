#!/usr/bin/env bash
# Build the MenuFold release app, verify it, and package it for a GitHub Release.
#
#   scripts/release.sh [version] [--allow-dirty] [--no-downloads]
#
#   version          defaults to MARKETING_VERSION in project.yml (e.g. 0.1.0)
#   --allow-dirty    build even when App/ or Packages/ has uncommitted changes (the zip is then
#                    stamped with the git state, so it is obvious it is not a clean release)
#   --no-downloads   don't copy the zip into ~/Downloads (CI: the runner's home is throwaway)
#
# Output:
#   dist/MenuFold-<version>-macos26-arm64.zip   the app (ditto, resource-fork safe)
#   dist/SHA256SUMS                             shasum -a 256 of that zip only
#   ~/Downloads/<same zip name>                 a copy for the user to install
#
# Idempotent: every run rebuilds from scratch (build-release/ is wiped) and rewrites dist/ files.
# Exit codes: 1 = bad usage/state, 2 = missing toolchain, 3 = build/verification failure.
set -euo pipefail
cd "$(dirname "$0")/.."
repo_root="$(pwd)"

# ---------------------------------------------------------------- output helpers
if [[ -t 1 ]]; then
    bold=$'\033[1m'; red=$'\033[31m'; green=$'\033[32m'; yellow=$'\033[33m'; reset=$'\033[0m'
else
    bold=""; red=""; green=""; yellow=""; reset=""
fi
step() { printf '\n%s==> %s%s\n' "$bold" "$*" "$reset"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s✓%s %s\n' "$green" "$reset" "$*"; }
warn() { printf '    %s!%s %s\n' "$yellow" "$reset" "$*" >&2; }
die()  { local code=$1; shift; printf '\n%sERROR:%s %s\n' "$red" "$reset" "$*" >&2; exit "$code"; }

# ---------------------------------------------------------------- arguments
usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$0"; }

version=""
allow_dirty=0
copy_to_downloads=1
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --allow-dirty) allow_dirty=1 ;;
        --no-downloads) copy_to_downloads=0 ;;
        -*) die 1 "Unknown option: $arg (see --help)" ;;
        *)
            [[ -z "$version" ]] || die 1 "Only one version argument is allowed."
            version="$arg"
            ;;
    esac
done

# ---------------------------------------------------------------- toolchain
step "Checking toolchain"
# The machine's xcode-select may point at Command Line Tools; the app needs the full Xcode.
xcode_dir="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
[[ -d "$xcode_dir" ]] || die 2 "Xcode not found at $xcode_dir. Install Xcode (macOS 26+ SDK) or set DEVELOPER_DIR."
export DEVELOPER_DIR="$xcode_dir"
command -v xcodebuild >/dev/null || die 2 "xcodebuild not found (is Xcode installed?)."
command -v xcodegen  >/dev/null || die 2 "xcodegen not found. Install it with: brew install xcodegen"
command -v ditto     >/dev/null || die 2 "ditto not found (part of macOS; is your PATH sane?)."
command -v shasum    >/dev/null || die 2 "shasum not found (part of macOS; is your PATH sane?)."
[[ "$(uname -m)" == "arm64" ]] || die 2 "Release builds are arm64-only; this host is $(uname -m)."
ok "$(xcodebuild -version | tr '\n' ' ')(DEVELOPER_DIR=$DEVELOPER_DIR)"
sdk_version="$(xcodebuild -version -sdk macosx ProductVersion 2>/dev/null || true)"
info "macOS SDK: ${sdk_version:-unknown}"
# Liquid Glass APIs are used unconditionally, so the deployment target needs a macOS 26 SDK.
if [[ -n "$sdk_version" ]] && [[ "$(printf '%s\n26.0\n' "$sdk_version" | sort -V | head -1)" != "26.0" ]]; then
    die 2 "macOS SDK $sdk_version is older than 26.0; MenuFold needs the macOS 26 SDK."
fi

# ---------------------------------------------------------------- version
project_version="$(sed -n 's/^ *MARKETING_VERSION: *"\{0,1\}\([^"[:space:]]*\)"\{0,1\}$/\1/p' project.yml | head -1)"
[[ -n "$project_version" ]] || die 1 "Could not read MARKETING_VERSION from project.yml."
[[ -n "$version" ]] || version="$project_version"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?(-[0-9A-Za-z.-]+)?$ ]] || die 1 "Invalid version '$version' (expected e.g. 0.1.0)."
if [[ "$version" != "$project_version" ]]; then
    warn "Building $version, but project.yml says $project_version: the app's CFBundleShortVersionString will be $project_version."
fi

# ---------------------------------------------------------------- git state
step "Checking git state"
git_commit="$(git rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
dirty_paths="$(git status --porcelain --untracked-files=all -- App Packages project.yml 2>/dev/null || true)"
if [[ -n "$dirty_paths" ]]; then
    if [[ "$allow_dirty" -eq 1 ]]; then
        warn "Building from a DIRTY tree (--allow-dirty); $git_commit+local-changes, not reproducible:"
        printf '%s\n' "$dirty_paths" | sed 's/^/        /' >&2
    else
        printf '%s\n' "$dirty_paths" | sed 's/^/        /' >&2
        die 1 "App/, Packages/ or project.yml has uncommitted changes. Commit them, or pass --allow-dirty."
    fi
else
    ok "clean tree at $git_commit"
fi

zip_name="MenuFold-${version}-macos26-arm64.zip"
dist_dir="$repo_root/dist"
out_zip="$dist_dir/$zip_name"
build_dir="$repo_root/build-release"
app_path="$build_dir/Build/Products/Release/MenuFold.app"

# ---------------------------------------------------------------- build
step "Building MenuFold $version (Release, arm64)"
rm -rf "$build_dir"
mkdir -p "$dist_dir"
# Keep the previously published artifacts until the new ones verify, so a failed run never
# leaves dist/ with a deleted or half-written zip.
tmp_zip="$dist_dir/.$zip_name.tmp"

xcodegen generate >"$build_dir.log" 2>&1 || { cat "$build_dir.log" >&2; rm -f "$build_dir.log"; die 3 "xcodegen generate failed."; }
info "xcodegen: regenerated MenuFold.xcodeproj"
rm -f "$build_dir.log"

log="$dist_dir/.build-$version.log"
if ! xcodebuild \
        -project MenuFold.xcodeproj \
        -scheme MenuFold \
        -configuration Release \
        -derivedDataPath "$build_dir" \
        -arch arm64 \
        ONLY_ACTIVE_ARCH=NO \
        CODE_SIGN_IDENTITY=- \
        build >"$log" 2>&1; then
    printf '\n%s--- last 60 lines of the build log ---%s\n' "$bold" "$reset" >&2
    tail -60 "$log" >&2
    die 3 "xcodebuild failed. Full log: $log"
fi
grep -E "^(\*\* )?BUILD SUCCEEDED" "$log" | tail -1 | sed 's/^/    /' || true
# appintentsmetadataprocessor always warns about a missing AppIntents.framework; not a code warning.
warnings="$(grep -E "warning:" "$log" | grep -vc "no AppIntents.framework" || true)"
if [[ "${warnings:-0}" -gt 0 ]]; then warn "$warnings compiler warning(s); see $log"; else rm -f "$log"; fi
rm -rf "$build_dir/Build/Intermediates.noindex"

# ---------------------------------------------------------------- verify
step "Verifying the built app"
[[ -d "$app_path" ]] || die 3 "No app produced at $app_path"
[[ -f "$app_path/Contents/MacOS/MenuFold" ]] || die 3 "Bundle has no executable."
ok "bundle: $app_path"

codesign --verify --strict --verbose=1 "$app_path" 2>&1 | sed 's/^/    /'
ok "codesign --verify --strict"

plutil -lint "$app_path/Contents/Info.plist" >/dev/null || die 3 "Info.plist is not a valid property list."
for plist in "$app_path"/Contents/**/Info.plist; do
    [[ -f "$plist" ]] && plutil -lint "$plist" >/dev/null || true
done
ok "plutil -lint"

plist_version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
[[ "$plist_version" == "$version" ]] || die 3 "Bundle version '$plist_version' != requested '$version'."
ok "CFBundleShortVersionString = $plist_version"

min_os="$(plutil -extract LSMinimumSystemVersion raw "$app_path/Contents/Info.plist")"
ok "LSMinimumSystemVersion = $min_os"

# App icon: actool writes Assets.car, and for a single-size-icons asset catalog it may also emit
# AppIcon.icns (project.yml sets ASSETCATALOG_COMPILER_APPICON_NAME). Require the catalog output and
# a CFBundleIconName/CFBundleIconFile that points at something present.
[[ -f "$app_path/Contents/Resources/Assets.car" ]] || die 3 "Missing Contents/Resources/Assets.car (app icon not compiled)."
icon_name="$(plutil -extract CFBundleIconName raw "$app_path/Contents/Info.plist" 2>/dev/null || true)"
icon_file="$(plutil -extract CFBundleIconFile raw "$app_path/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$icon_name" || -n "$icon_file" ]] || die 3 "Info.plist names no app icon (CFBundleIconName/CFBundleIconFile)."
if [[ -n "$icon_file" ]]; then
    # actool writes CFBundleIconFile *without* the extension ("AppIcon"), the file has it.
    icon_path="$app_path/Contents/Resources/$icon_file"
    [[ -f "$icon_path" ]] || icon_path="$icon_path.icns"
    [[ -f "$icon_path" ]] || die 3 "CFBundleIconFile '$icon_file' is not in Contents/Resources (looked for it and '$icon_file.icns')."
fi
ok "icon: Assets.car$( [[ -n "$icon_file" ]] && printf ', %s' "$icon_file" )$( [[ -n "$icon_name" ]] && printf ' (%s)' "$icon_name" )"

archs="$(lipo -archs "$app_path/Contents/MacOS/MenuFold")"
[[ "$archs" == "arm64" ]] || die 3 "Executable is '$archs', expected arm64 only."
ok "arch: $archs"

# The app must not be a debug/release mix-up: no Swift Testing or preview dylibs in the bundle.
if find "$app_path" -name '*.test' -o -name 'XCTest*' | grep -q .; then
    die 3 "Test bundles found inside the release app."
fi
ok "no test/preview artifacts in the bundle"

info "bundle size: $(du -sh "$app_path" | cut -f1)"

# ---------------------------------------------------------------- package
step "Packaging"
ditto -c -k --sequesterRsrc --keepParent "$app_path" "$tmp_zip"
mv -f "$tmp_zip" "$out_zip"
ok "$out_zip ($(du -h "$out_zip" | cut -f1))"

# Prove the archive unpacks into a launchable bundle before it is published.
verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/menufold-release.XXXXXX")"
trap 'rm -rf "$verify_dir"' EXIT
ditto -x -k "$out_zip" "$verify_dir"
[[ -f "$verify_dir/MenuFold.app/Contents/MacOS/MenuFold" ]] || die 3 "The zip does not unpack to MenuFold.app."
codesign --verify --strict "$verify_dir/MenuFold.app" >/dev/null || die 3 "The unpacked app fails codesign --verify."
ok "zip round-trips and the unpacked copy verifies"

# ---------------------------------------------------------------- checksums
step "Checksums"
(cd "$dist_dir" && shasum -a 256 "$zip_name" > SHA256SUMS)
sha="$(shasum -a 256 "$out_zip" | awk '{print $1}')"
ok "dist/SHA256SUMS written"
printf '    sha256 %s  %s\n' "$sha" "$zip_name"

if [[ "$copy_to_downloads" -eq 1 ]]; then
    downloads="$HOME/Downloads"
    if mkdir -p "$downloads" 2>/dev/null && cp -f "$out_zip" "$downloads/$zip_name"; then
        ok "copied to $downloads/$zip_name"
    else
        warn "Could not copy to $downloads (continuing; the zip is in $dist_dir)."
    fi
fi

# ---------------------------------------------------------------- summary
step "Done"
info "zip:    $out_zip"
info "sha256: $sha"
info "state:  $git_commit$( [[ "$allow_dirty" -eq 1 && -n "$dirty_paths" ]] && printf ' + local changes' )"
printf '\n    Install: unzip, move MenuFold.app to /Applications, then right-click → Open the first time\n'
printf '    (the app is ad-hoc signed, not notarised). Requires macOS %s+ on Apple silicon.\n\n' "$min_os"

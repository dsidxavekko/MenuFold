#!/usr/bin/env bash
# Build the MenuFold release app, verify it, and package it for a GitHub Release.
#
#   scripts/release.sh [version] [--allow-dirty] [--no-downloads] [--no-appcast]
#
#   version          defaults to MARKETING_VERSION in project.yml (e.g. 0.1.0)
#   --allow-dirty    build even when App/ or Packages/ has uncommitted changes (the zip is then
#                    stamped with the git state, so it is obvious it is not a clean release)
#   --no-downloads   don't copy the DMG into ~/Downloads (CI: the runner's home is throwaway)
#   --no-appcast     skip the Sparkle signature and appcast.xml (no signing key at hand)
#
# Output:
#   dist/MenuFold-<version>.dmg                 for people: drag MenuFold into Applications
#   dist/MenuFold-<version>-macos26-arm64.zip   the app (ditto, resource-fork safe); Sparkle downloads this
#   dist/appcast.xml                            the Sparkle feed (one item: this version)
#   dist/release-notes.md                       this version's section of CHANGELOG.md
#   dist/SHA256SUMS                             shasum -a 256 of the DMG and the zip
#   ~/Downloads/<same DMG name>                 a copy for the user to install
#
# The build number (CFBundleVersion, which Sparkle compares) is the commit count of HEAD, so it grows
# with every release. The update signature uses the EdDSA key from the login Keychain (made once with
# Sparkle's generate_keys), or from $SPARKLE_PRIVATE_KEY when that is set (CI).
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
make_appcast=1
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --allow-dirty) allow_dirty=1 ;;
        --no-downloads) copy_to_downloads=0 ;;
        --no-appcast) make_appcast=0 ;;
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
# Order: an explicit DEVELOPER_DIR, then the selected Xcode (CI selects one), then any
# /Applications/Xcode*.app (GitHub runners name it e.g. Xcode_26.6.app).
xcode_dir="${DEVELOPER_DIR:-}"
if [[ -z "$xcode_dir" ]]; then
    selected="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "$selected" && "$selected" != *CommandLineTools* && -d "$selected" ]]; then
        xcode_dir="$selected"
    else
        for candidate in /Applications/Xcode.app/Contents/Developer /Applications/Xcode*.app/Contents/Developer; do
            [[ -d "$candidate" ]] && { xcode_dir="$candidate"; break; }
        done
    fi
fi
[[ -n "$xcode_dir" && -d "$xcode_dir" ]] || die 2 "No full Xcode found (looked at DEVELOPER_DIR, xcode-select and /Applications/Xcode*.app). Install Xcode (macOS 26+ SDK) or set DEVELOPER_DIR."
export DEVELOPER_DIR="$xcode_dir"
command -v xcodebuild >/dev/null || die 2 "xcodebuild not found (is Xcode installed?)."
command -v xcodegen  >/dev/null || die 2 "xcodegen not found. Install it with: brew install xcodegen"
command -v ditto     >/dev/null || die 2 "ditto not found (part of macOS; is your PATH sane?)."
command -v shasum    >/dev/null || die 2 "shasum not found (part of macOS; is your PATH sane?)."
command -v hdiutil   >/dev/null || die 2 "hdiutil not found (part of macOS; is your PATH sane?)."
command -v python3   >/dev/null || die 2 "python3 not found (it comes with the Command Line Tools)."
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
    # The requested version is passed to xcodebuild as MARKETING_VERSION, so the bundle reports it.
    warn "Building $version, but project.yml says $project_version: overriding MARKETING_VERSION for this build (update project.yml to keep them in sync)."
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

# Sparkle installs an update only when its CFBundleVersion is higher than the running one.
build_number="$(git rev-list --count HEAD 2>/dev/null || true)"
[[ "$build_number" =~ ^[0-9]+$ ]] || die 1 "Could not count commits for the build number (shallow clone? use fetch-depth: 0)."
ok "build number $build_number (commit count)"

zip_name="MenuFold-${version}-macos26-arm64.zip"
dmg_name="MenuFold-${version}.dmg"
dist_dir="$repo_root/dist"
out_zip="$dist_dir/$zip_name"
out_dmg="$dist_dir/$dmg_name"
build_dir="$repo_root/build-release"
app_path="$build_dir/Build/Products/Release/MenuFold.app"
repo_url="https://github.com/dsidxavekko/MenuFold"

# ---------------------------------------------------------------- release notes
step "Release notes"
notes_md="$dist_dir/release-notes.md"
mkdir -p "$dist_dir"
# The "## <version>" section of CHANGELOG.md, up to the next "## " heading.
awk -v v="$version" '
    /^## / { if (found) exit; split($0, h, /[ \t]+/); if (h[2] == v) { found = 1; next } }
    found { print }
' CHANGELOG.md 2>/dev/null | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}' > "$notes_md.tmp" || true
if [[ -s "$notes_md.tmp" ]] && grep -q '[^[:space:]]' "$notes_md.tmp"; then
    mv -f "$notes_md.tmp" "$notes_md"
    ok "CHANGELOG.md section for $version ($(grep -c '^- ' "$notes_md" || true) item(s))"
else
    rm -f "$notes_md.tmp"
    [[ -n "${CI:-}" ]] && die 1 "CHANGELOG.md has no '## $version' section. Add one before releasing."
    warn "CHANGELOG.md has no '## $version' section; the update window will show no notes."
    : > "$notes_md"
fi

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
        MARKETING_VERSION="$version" \
        CURRENT_PROJECT_VERSION="$build_number" \
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

# Every Info.plist in the bundle, nested ones included (bash 3.2 has no globstar, so use find).
plist_count=0
while IFS= read -r -d '' plist; do
    plutil -lint "$plist" >/dev/null || die 3 "Not a valid property list: ${plist#"$app_path"/}"
    plist_count=$((plist_count + 1))
done < <(find "$app_path/Contents" -name Info.plist -type f -print0)
[[ "$plist_count" -gt 0 ]] || die 3 "No Info.plist found in the bundle."
ok "plutil -lint ($plist_count Info.plist)"

plist_version="$(plutil -extract CFBundleShortVersionString raw "$app_path/Contents/Info.plist")"
[[ "$plist_version" == "$version" ]] || die 3 "Bundle version '$plist_version' != requested '$version'."
ok "CFBundleShortVersionString = $plist_version"

plist_build="$(plutil -extract CFBundleVersion raw "$app_path/Contents/Info.plist")"
[[ "$plist_build" == "$build_number" ]] || die 3 "Bundle build '$plist_build' != expected '$build_number'."
ok "CFBundleVersion = $plist_build"

feed_url="$(plutil -extract SUFeedURL raw "$app_path/Contents/Info.plist" 2>/dev/null || true)"
public_key="$(plutil -extract SUPublicEDKey raw "$app_path/Contents/Info.plist" 2>/dev/null || true)"
[[ -n "$feed_url" && -n "$public_key" ]] || die 3 "Info.plist lacks SUFeedURL or SUPublicEDKey (Sparkle)."
[[ -d "$app_path/Contents/Frameworks/Sparkle.framework" ]] || die 3 "Sparkle.framework is not embedded."
codesign --verify --strict "$app_path/Contents/Frameworks/Sparkle.framework" || die 3 "Embedded Sparkle.framework fails codesign --verify."
ok "Sparkle: framework embedded, feed $feed_url"

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

# A disk image with the app and an Applications shortcut: the usual "drag it across" install.
stage="$verify_dir/dmg"
mkdir -p "$stage"
ditto "$app_path" "$stage/MenuFold.app"
ln -s /Applications "$stage/Applications"
tmp_dmg="$dist_dir/.$dmg_name.tmp.dmg"
rm -f "$tmp_dmg"
hdiutil create -quiet -volname "MenuFold" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$tmp_dmg" \
    || die 3 "hdiutil create failed."
mv -f "$tmp_dmg" "$out_dmg"
ok "$out_dmg ($(du -h "$out_dmg" | cut -f1))"

hdiutil verify -quiet "$out_dmg" || die 3 "hdiutil verify failed for the DMG."
mount_dir="$verify_dir/mnt"
mkdir -p "$mount_dir"
hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount_dir" "$out_dmg" || die 3 "Could not mount the DMG."
dmg_ok=1
[[ -f "$mount_dir/MenuFold.app/Contents/MacOS/MenuFold" ]] || dmg_ok=0
[[ -L "$mount_dir/Applications" ]] || dmg_ok=0
codesign --verify --strict "$mount_dir/MenuFold.app" >/dev/null 2>&1 || dmg_ok=0
hdiutil detach -quiet "$mount_dir" || hdiutil detach -quiet -force "$mount_dir" || true
[[ "$dmg_ok" -eq 1 ]] || die 3 "The DMG does not hold a verified MenuFold.app and an Applications link."
ok "DMG mounts, holds MenuFold.app + Applications, and the app verifies"

# ---------------------------------------------------------------- Sparkle
appcast="$dist_dir/appcast.xml"
if [[ "$make_appcast" -eq 1 ]]; then
    step "Sparkle update feed"
    sparkle_bin="$build_dir/SourcePackages/artifacts/sparkle/Sparkle/bin"
    [[ -x "$sparkle_bin/sign_update" ]] || die 2 "Sparkle's sign_update is missing at $sparkle_bin."
    key_args=()
    if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
        key_file="$verify_dir/sparkle.key"
        (umask 077; printf '%s' "$SPARKLE_PRIVATE_KEY" > "$key_file")
        key_args=(--ed-key-file "$key_file")
        info "signing key: \$SPARKLE_PRIVATE_KEY"
    else
        info "signing key: login Keychain (Sparkle generate_keys)"
    fi
    signature="$("$sparkle_bin/sign_update" "${key_args[@]+"${key_args[@]}"}" -p "$out_zip")" \
        || die 3 "sign_update failed. Make the key once with $sparkle_bin/generate_keys, set SPARKLE_PRIVATE_KEY, or pass --no-appcast."
    # The signature must match the public key built into this app, or no install would accept it.
    # Checked with CryptoKit, so no third-party tools are needed.
    cat > "$verify_dir/check-key.swift" <<'SWIFT'
import CryptoKit
import Foundation
let args = CommandLine.arguments
guard let rawKey = Data(base64Encoded: args[1]), let rawSignature = Data(base64Encoded: args[2]),
      let key = try? Curve25519.Signing.PublicKey(rawRepresentation: rawKey),
      let data = FileManager.default.contents(atPath: args[3]),
      key.isValidSignature(rawSignature, for: data)
else { exit(1) }
SWIFT
    swift "$verify_dir/check-key.swift" "$public_key" "$signature" "$out_zip" \
        || die 3 "The signing key does not match SUPublicEDKey in Info.plist."
    ok "zip signed (EdDSA) and matches SUPublicEDKey"

    zip_length="$(stat -f %z "$out_zip")"
    python3 - "$notes_md" "$appcast" "$version" "$build_number" "$min_os" "$zip_length" "$signature" \
        "$repo_url/releases/download/v$version/$zip_name" "$repo_url/releases/tag/v$version" <<'PY' \
        || die 3 "Could not write appcast.xml."
import html, re, sys
from email.utils import formatdate
notes_path, out, version, build, min_os, length, signature, url, page = sys.argv[1:]

def inline(text):
    text = html.escape(text, quote=False)
    text = re.sub(r"`([^`]+)`", r"<code>\1</code>", text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"<b>\1</b>", text)
    return text

# The few Markdown shapes CHANGELOG.md uses: "### heading", "- item" and paragraphs.
parts, in_list = [], False
for line in open(notes_path, encoding="utf-8").read().splitlines():
    if line.startswith("- "):
        if not in_list:
            parts.append("<ul>"); in_list = True
        parts.append("<li>" + inline(line[2:].strip()) + "</li>")
        continue
    if line.startswith("  ") and in_list and parts:
        parts[-1] = parts[-1][:-5] + " " + inline(line.strip()) + "</li>"
        continue
    if in_list:
        parts.append("</ul>"); in_list = False
    if line.startswith("### "):
        parts.append("<h3>" + inline(line[4:].strip()) + "</h3>")
    elif line.strip():
        parts.append("<p>" + inline(line.strip()) + "</p>")
if in_list:
    parts.append("</ul>")
notes = "\n".join(parts).replace("]]>", "]]&gt;")

attr = lambda s: html.escape(s, quote=True)
xml = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>MenuFold</title>
    <link>{attr(page)}</link>
    <item>
      <title>MenuFold {attr(version)}</title>
      <pubDate>{formatdate(usegmt=True)}</pubDate>
      <sparkle:version>{attr(build)}</sparkle:version>
      <sparkle:shortVersionString>{attr(version)}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>{attr(min_os)}</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>{attr(page)}</sparkle:fullReleaseNotesLink>
      <description><![CDATA[{notes}]]></description>
      <enclosure url="{attr(url)}" length="{attr(length)}" type="application/octet-stream" sparkle:edSignature="{attr(signature)}"/>
    </item>
  </channel>
</rss>
'''
open(out, "w", encoding="utf-8").write(xml)
PY
    plutil -lint "$appcast" >/dev/null 2>&1 || xmllint --noout "$appcast" || die 3 "appcast.xml is not well-formed XML."
    ok "dist/appcast.xml (version $version, build $build_number)"
else
    rm -f "$appcast"
    warn "--no-appcast: no update feed; installed copies will not be offered this version."
fi

# ---------------------------------------------------------------- checksums
step "Checksums"
(cd "$dist_dir" && shasum -a 256 "$dmg_name" "$zip_name" > SHA256SUMS)
ok "dist/SHA256SUMS written"
sed 's/^/    /' "$dist_dir/SHA256SUMS"

if [[ "$copy_to_downloads" -eq 1 ]]; then
    downloads="$HOME/Downloads"
    if mkdir -p "$downloads" 2>/dev/null && cp -f "$out_dmg" "$downloads/$dmg_name"; then
        ok "copied to $downloads/$dmg_name"
    else
        warn "Could not copy to $downloads (continuing; the DMG is in $dist_dir)."
    fi
fi

# ---------------------------------------------------------------- summary
step "Done"
info "dmg:     $out_dmg"
info "zip:     $out_zip"
[[ "$make_appcast" -eq 1 ]] && info "appcast: $appcast"
info "state:  $git_commit$( [[ "$allow_dirty" -eq 1 && -n "$dirty_paths" ]] && printf ' + local changes' )"
printf '\n    Install: open the DMG, drag MenuFold to Applications and open it. The app is ad-hoc signed, not\n'
printf '    notarised, so macOS blocks the first launch: System Settings → Privacy & Security → Open Anyway.\n'
printf '    Requires macOS %s+ on Apple silicon.\n\n' "$min_os"

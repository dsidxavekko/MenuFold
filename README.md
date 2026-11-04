# MenuFold

[![CI](https://github.com/dsidxavekko/MenuFold/actions/workflows/ci.yml/badge.svg)](https://github.com/dsidxavekko/MenuFold/actions/workflows/ci.yml)

**MenuFold** is a native macOS SwiftUI & AppKit application that replaces the default Dock "Applications" stack with a polished, fast, and feature-rich app grid.

Pinned directly in your Dock like a normal app, clicking MenuFold opens a borderless panel centered on your screen, featuring:
- **Grid of all installed apps** with smooth scrolling and responsive layout.
- **Custom folders** created instantly via simple drag-and-drop (one level deep, with custom titles, colors, and SF symbols).
- **Automatic category tabs** to easily browse apps by type (e.g. Productivity, Games, Utilities, Social, etc.).
- **Instant search** that searches across all apps and inside folders simultaneously.
- **Finder folders integration**, automatically surfacing real subfolders of `/Applications` and `~/Applications` (such as Utilities).
- **Liquid Glass aesthetics** leveraging modern macOS visual effects (`NSGlassEffectView`) with smooth scale and blur animations.

![MenuFold](screenshot.png)

MenuFold operates entirely independently without patching the Dock or any system process (no SIP changes required).

---

## System Requirements

- **macOS** 26+ (developed on macOS 27)
- **Xcode** (for building from source)
- **XcodeGen** (`brew install xcodegen`)

---

## Architecture & Structure

MenuFold is split into two layers:
1. **`Packages/MenuFoldCore`**: Pure Swift business logic package (App catalog scanning via Spotlight, app filtering rules, layout persistence, finder folders virtualization, and `@Observable` grid models). Fully unit-tested with Swift Testing.
2. **`App/`**: AppKit & SwiftUI presentation layer (`MenuFoldApp`, `PanelController`, window chrome, Liquid Glass glass layer, Dock geometry calculations, and views).

---

## Building and Running

### Building Logic & Running Tests (Command Line Tools only)
```bash
cd Packages/MenuFoldCore
swift build
swift test

# From the repository root: typecheck App/ against the built package (~5 s, no Xcode needed)
scripts/typecheck-app.sh
```

### Building & Running the App (Xcode required)
```bash
# Generate Xcode project and build into ./build
scripts/build.sh

# Build, terminate any running copy, and open the new one
scripts/build.sh run
```

---

## Continuous Integration

Every push and pull request runs [`.github/workflows/ci.yml`](.github/workflows/ci.yml):
`swift build` + `swift test` for `MenuFoldCore`, `scripts/typecheck-app.sh` for the App layer, and a full
`scripts/build.sh` app build when the runner's macOS SDK is 26 or newer.

---

## Security & Privacy

MenuFold is a personal, locally built app, so it is **not sandboxed** and signed **ad-hoc**. It needs no
Accessibility or Screen Recording permission. It reads Spotlight metadata (`NSMetadataQuery`) to find
applications, the `com.apple.dock` defaults (tile size and orientation only) to tell whether a click came
from the Dock, and the app bundles' `Info.plist` files for names and categories. It writes exactly one file:
`~/Library/Application Support/MenuFold/layout.json`, atomically; an unusable copy is moved aside to
`layout.corrupt-<date>.json` instead of being overwritten, and Settings warns you when that happens.

Drags out of the panel carry the app's file URL with a `.link` operation only, so Finder can create an
alias but can never move or copy a bundle; internal drops accept only MenuFold's private pasteboard type.

## Known limitations

- With ad-hoc signing, the "open at login" item (`SMAppService`) can need re-approval after each rebuild.
- Apps are listed only from local, standard locations: external volumes (`/Volumes`), the Trash and temp
  directories are ignored, so Time Machine copies of apps never show up in the grid.
- A layout written by a newer version of MenuFold is moved aside rather than downgraded.

---

## License

This project is licensed under the [MIT License](LICENSE).

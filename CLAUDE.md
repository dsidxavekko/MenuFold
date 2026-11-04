# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

MenuFold is a macOS (26+, developed on macOS 27) SwiftUI app that replaces the Dock "Applications" stack. It is pinned in the Dock like a normal app. Clicking its icon opens a borderless panel centered on the screen, holding a grid of all apps with user-made folders (one level deep, made by drag-and-drop), automatic category tabs and search. It does not patch the Dock or any system process (no SIP changes). UI strings are Ukrainian. Personal project for now, so there is no sandbox and signing is ad-hoc.

## Commands

```bash
# Logic package: build + tests (works with Command Line Tools only, no Xcode needed)
cd Packages/MenuFoldCore && swift build && swift test
swift test --filter GridModelTests                 # one suite
swift test --filter "GridModelTests/previewModel"  # one test

# App (needs full Xcode at /Applications/Xcode.app + `brew install xcodegen`)
scripts/build.sh        # xcodegen generate + xcodebuild into ./build
scripts/build.sh run    # same, then kill the running copy and open the new one
```

- `MenuFold.xcodeproj` is generated from `project.yml` and gitignored. Edit `project.yml`, never the project. Re-run `xcodegen generate` after adding or removing files.
- `scripts/build.sh` sets `DEVELOPER_DIR` to Xcode by itself when `xcode-select` still points at Command Line Tools, so `sudo xcode-select` is not required.
- Tests use Swift Testing, not XCTest (XCTest is missing on CLT). `Package.swift` adds a `-plugin-path` flag to the test target only when CLT is the selected developer dir. Leave that block alone.
- Without Xcode, `swiftc -typecheck` on `App/` fails on `@State` and `#Preview`. On this SDK both are macros, and their plugins (SwiftUIMacros, PreviewsMacros) come only with Xcode. To typecheck anyway, use a scratch copy with `@State` aliased to `SwiftUI.State` and the `#Preview` blocks stripped. Pass `-I Packages/MenuFoldCore/.build/out/Products/Debug`.

## Architecture

There are two layers. Only the package is unit-tested.

**`Packages/MenuFoldCore`** holds all logic and has no views. Its public API was the contract that the app layer was written against, so keep signatures stable.
- `AppCatalog.swift`: `AppCatalogProviding`. `SpotlightAppCatalog` runs an `NSMetadataQuery` for `com.apple.application-bundle` and reads Info.plists off the main thread. It publishes `apps` and calls `onChange` on the main actor, only when the list changed, debounced about 0.3 s after the first scan. `StaticAppCatalog` serves previews and tests.
- `AppFilter.swift`: a pure `filter([AppCandidate]) -> [AppEntry]` that holds all the "which apps to show" rules, and it has tests:
  - It drops apps nested in any bundle (`.app`, `.framework`, `.xpc`, …).
  - It drops everything under `/System/Library`, `/Library` and `~/Library`, except Finder and `CoreServices/Applications/*`.
  - It de-duplicates by bundle ID, preferring `/Applications`, then `/System/Applications`, then `~/Applications`, then the newest copy.
  - It removes MenuFold itself.
- `Layout.swift` / `LayoutStore.swift`: the persisted state is folders (bundle-ID lists, colour, optional SF Symbol), category overrides and hidden IDs. It is saved as JSON at `~/Library/Application Support/MenuFold/layout.json` with atomic writes. Decoding is lenient. A missing file gives an empty layout. A file that can't be read or decoded is first renamed to `layout.corrupt-<date>.json`, so it is never silently overwritten.
- `GridModel.swift`: the `@MainActor @Observable` hub. It merges catalog and layout into `GridItem`s for the current `tab` and `query`. Every mutating intent saves right away. Rules:
  - A folder left with ≤1 app is dissolved.
  - Folders keep the IDs of uninstalled apps, so an app goes back into its folder after reinstall. A folder with no visible apps is not shown.
  - A non-empty search ignores the tab and finds apps inside folders too.
  - Category tabs are flat lists that ignore folders.
  - `GridModel.preview` is the sample model every `#Preview` uses.
- `FinderFolders.swift` covers Finder folders. A real subfolder of `/Applications` or `~/Applications` (keyed by its top-level folder), as well as `/System/Applications/Utilities`, is shown as a folder:
  - It is one-way and read-only, so MenuFold never moves files.
  - These folders are synthesized on every query (`Folder.finderPath != nil`, with a stable id derived from the path) and are never stored in `layout.folders`.
  - Manual folders win.
  - `rename` does nothing on them. `add` (an app dropped onto the tile) is virtual: it goes to `finderAdditions` (bundle ID → path), which beats the real location and exclusions. `dissolve` goes to `ignoredFinderFolders`. Pulling an app out removes its addition, or goes to `finderExclusions` if the app really lives in a Finder folder. Colours live in `finderStyles`.

**`App/`** is the AppKit + SwiftUI shell.
- `MenuFoldApp.swift`: `AppDelegate` owns the single `GridModel` and `PanelController`, and keeps them alive for the app's lifetime. A Dock click arrives as `applicationShouldHandleReopen` and toggles the panel. The panel is also shown on launch. `model.onLaunched` hides the panel.
- `PanelController.swift`: a borderless key-capable `NSPanel`. It draws the window chrome as an AppKit `NSGlassEffectView` (Liquid Glass, `Theme.panelCorner`) hosting the SwiftUI root, and it runs the open/close scale+blur animation with Core Animation on the glass layer. The views must not draw their own background. It hides on resign-key, Esc, app launch or a second Dock click. A 0.3 s guard stops the hide-then-reopen flicker from Dock clicks. Esc closes an open folder first, then the panel.
- `DockGeometry.swift`: the anchor is `NSEvent.mouseLocation` at the moment of the Dock click, so no Accessibility permission is needed. The panel is always centered on that screen; the user prefers this over sitting above the icon. `isNearDock` uses the Dock orientation, `tilesize` and magnification from `com.apple.dock` defaults, because auto-hide reserves no space in `visibleFrame`. It only drives the reopen guard.
- `IconCache.shared.icon(for:)`: the only place where icons are loaded, and it caches them. Views call it from `body`.
- `Views/`: `MenuFoldRootView(model:)` (fixed 844×577 like the system Apps launcher, see `GridMetrics`; transparent) contains `SearchField`, `CategoryTabs`, `GridView`, `FolderOverlayView` (iPhone-style expanded folder with an editable title), and the tiles together with their context menus. Tiles drag via an AppKit `NSDraggingSource` (`AppDragSource.swift`). The pasteboard holds the file URL plus the private `com.menufold.app-id`. Outside the app only `.link` is allowed (Finder makes an alias, never a move or copy), with `.generic` added only over the Dock for pinning. Internal drops accept only the private type. Folder-making drops are enabled only on the "Все" tab with an empty query. `MenuFoldCore.GridItem` clashes with `SwiftUI.GridItem`, so write out the full name.

Styling is Liquid Glass (macOS 26 APIs used directly, with no `#available`). All motion and shape constants live in `App/Views/Theme.swift`, so reuse them. Every animation has a Reduce Motion fallback.

Any separate window or sheet opened from the panel takes key status and closes the panel. Put new UI inside the panel or in the Settings scene.

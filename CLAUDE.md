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
- `scripts/typecheck-app.sh` typechecks `App/` in about 5 s against the built package (it builds `MenuFoldCore` first), without building or signing the app. With Xcode installed it checks the real sources; without Xcode it checks a scratch copy with stand-ins for the Xcode-only macros (`@State`, `@Entry`) and `#Preview` wrapped in `#if canImport(XcodeSupport)`, using `-parse-as-library -warnings-as-errors`. CI runs it, so App/ changes are checked even when nobody has Xcode.
- Tests use Swift Testing, not XCTest (XCTest is missing on CLT). `Package.swift` adds a `-plugin-path` flag to the test target only when CLT is the selected developer dir. Leave that block alone.
- Without Xcode, `swiftc -typecheck` on `App/` fails on `@State`, `@Entry` and `#Preview`. On this SDK all three are macros whose plugins (SwiftUIMacros, PreviewsMacros) come only with Xcode. `scripts/typecheck-app.sh` handles that fallback; it is the supported way to check `App/` without Xcode (do not hand-roll another scratch copy).

## Architecture

There are two layers. Only the package is unit-tested.

**`Packages/MenuFoldCore`** holds all logic and has no views. Its public API was the contract that the app layer was written against, so keep signatures stable.
- `AppCatalog.swift`: `AppCatalogProviding`. `SpotlightAppCatalog` runs an `NSMetadataQuery` for `com.apple.application-bundle` and reads Info.plists off the main thread. It publishes `apps` and calls `onChange` on the main actor, only when the list changed, debounced about 0.3 s after the first scan. `StaticAppCatalog` serves previews and tests.
- `AppFilter.swift`: a pure `filter([AppCandidate]) -> [AppEntry]` that holds all the "which apps to show" rules, and it has tests:
  - It drops apps nested in any bundle (`.app`, `.framework`, `.xpc`, …).
  - It drops everything under `/System/Library`, `/Library` and `~/Library`, except Finder and `CoreServices/Applications/*`.
  - It de-duplicates by bundle ID, preferring `/Applications`, then `/System/Applications`, then `~/Applications`, then the newest copy.
  - It removes MenuFold itself.
- `Layout.swift` / `LayoutStore.swift`: the persisted state is folders (bundle-ID lists, colour, optional SF Symbol), category overrides, custom categories and hidden IDs. It is saved as JSON at `~/Library/Application Support/MenuFold/layout.json` with atomic writes. Decoding has two levels of leniency: a missing key keeps its default (old/newer files load), but a key that is present with the wrong shape is corruption. A missing file gives an empty layout. A file that can't be decoded, or that comes from a newer app version (`version > Layout.currentVersion`), is moved aside to `layout.corrupt-<date>.json` and `GridModel` immediately writes a fresh layout, so the next launch has a valid file; `GridModel.layoutOutcome` / `LayoutStore.lastQuarantineFailed` tell Settings to warn. A file that can't be *read* (permissions, lock, I/O) is left untouched and retried next launch. Load-time validation drops duplicate folder ids, manual folders with fewer than two apps, and finder paths with dot segments.
- `GridModel.swift`: the `@MainActor @Observable` hub. It merges catalog and layout into `GridItem`s for the current `tab` and `query`. Every mutating intent saves right away. Rules:
  - A folder left with ≤1 app is dissolved.
  - Folders keep the IDs of uninstalled apps, so an app goes back into its folder after reinstall. A folder with no visible apps is not shown.
  - A non-empty search ignores the tab and finds apps inside folders too.
  - Category tabs are flat lists that ignore folders.
  - Custom categories (`Layout.customCategories`, ids prefixed `custom.`) are user-made tabs. Apps join one through `categoryOverrides`. Their tabs come right after "Все" and show even when empty. Deleting one drops its overrides, so its apps go back to their automatic category. They are created from the tile menu ("Нова категорія…", then renamed inline on the tab via `renamingCategoryID`), renamed or deleted from the tab's context menu, and managed in Settings.
  - Tab order: `Layout.categoryOrder` holds category ids (system or custom) in the user's order; categories not in it follow in the default order (custom, then system by name, "Інше" last). "Все" is always first. Tabs are reordered by dragging in the panel or "Пересунути ліворуч/праворуч" in the tab's context menu; Settings can reset the order.
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

Any separate window or sheet opened from the panel takes key status and closes the panel. Put new UI inside the panel or in the Settings window. The panel has no settings button: Settings open from the app menu (⌘,, "Про MenuFold") or the Dock icon's menu (`applicationDockMenu`). Settings is an AppKit window with toolbar tabs (`SettingsWindowController`, `SettingsTab`: Загальне, Категорії, Програми, Про програму), opened with `AppDelegate.showSettings(tab:)`. Do not go back to the SwiftUI `Settings` scene for it: it cannot be opened from code (`showSettingsWindow:` is ignored with "Please use SettingsLink"). Debug builds accept `--args -openSettings <tab>` to open a tab on launch.

App icon: the source is `Design/AppIcon.svg`; `scripts/render-icon.sh` renders it (headless Chrome) into every PNG of `App/Assets.xcassets/AppIcon.appiconset`. Never edit the PNGs by hand. The Dock icon can be switched in Settings (`DockIconStyle`: MenuFold logo or the system Applications folder icon). It is applied at runtime (`NSApp.applicationIconImage`) and also written as a Finder custom icon onto the .app bundle (`NSWorkspace.setIcon`), so the Dock keeps it while MenuFold is closed. macOS App Management may refuse the bundle write; Settings then says so. An update replaces the bundle, so launch re-writes the custom icon.

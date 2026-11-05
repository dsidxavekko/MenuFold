<p align="center">
  <img src="App/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="MenuFold icon">
</p>

<h1 align="center">MenuFold</h1>

<p align="center">
  An app launcher for the macOS Dock: every app in one grid, with your own folders, categories and search.<br>
  A replacement for the Dock's Applications stack, in Liquid Glass.
</p>

<p align="center">
  <a href="https://github.com/dsidxavekko/MenuFold/releases/latest"><img src="https://img.shields.io/github/v/release/dsidxavekko/MenuFold?label=download" alt="Latest release"></a>
  <a href="https://github.com/dsidxavekko/MenuFold/actions/workflows/ci.yml"><img src="https://github.com/dsidxavekko/MenuFold/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/macOS-26%2B-blue" alt="macOS 26+">
  <img src="https://img.shields.io/badge/Apple%20silicon-arm64-lightgrey" alt="Apple silicon">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/dsidxavekko/MenuFold" alt="License"></a>
</p>

<p align="center">
  <img src="docs/screenshots/panel.png" width="844" alt="MenuFold panel: search field, category tabs, a row of frequent apps and the grid of all apps">
</p>

Pin MenuFold to the Dock like any other app. Click its icon and a panel opens in the middle of the screen
with all your apps. Click an app to launch it, or press Esc to close the panel.

MenuFold doesn't patch the Dock or any system process, so you don't need to change SIP. It also needs no
Accessibility or Screen Recording permission.

## Features

- **Every app in one grid.** Apps are found through Spotlight, so new installs show up on their own. Copies
  inside other bundles, helper apps under `/Library` and duplicates are skipped.
- **Folders.** Drop one app onto another to make a folder, just like on iPhone. You can rename a folder and
  pick its colour and an SF Symbol. Subfolders of `/Applications` (such as Utilities) appear as folders too.
  MenuFold never moves any files.
- **Category tabs.** Apps are sorted into tabs by their App Store category. You can move an app to another
  category, make your own categories, and drag tabs into any order.
- **Running tab.** The apps that are open right now, with a Dock-style dot under each one that is running.
- **Frequent apps.** The apps you open most often sit in a row above the grid.
- **Search.** Type to find an app, including apps inside folders. Names match in the system language and
  in English, so both «Калькулятор» and "Calculator" work.
- **Keyboard.** Use the arrow keys to move, Return to launch, ⌘R to show in Finder and ⌘⌫ to move to the
  Trash. Esc closes a folder, then the panel.
- **Per-app actions.** Right-click an app to open it, show it in Finder, quit it, hide it from the grid,
  give it a custom icon, change its category or move it to the Trash (MenuFold asks first).
- **Dock icon.** Choose the MenuFold logo, the macOS launcher icon, the Applications folder icon or your own
  picture.
- **English and Ukrainian** interface.

<table>
  <tr>
    <td><img src="docs/screenshots/folder.png" alt="An open folder showing its apps"></td>
    <td><img src="docs/screenshots/search.png" alt="Search results for “ca”"></td>
  </tr>
  <tr>
    <td align="center">An open folder</td>
    <td align="center">Search</td>
  </tr>
</table>

<p align="center">
  <img src="docs/screenshots/settings.png" width="560" alt="Settings window, General tab: open at login, Dock icon choice, frequent apps">
</p>

## Install

1. Download `MenuFold-<version>.dmg` from the
   [latest release](https://github.com/dsidxavekko/MenuFold/releases/latest).
2. Open the DMG and drag **MenuFold** onto **Applications**. (If you open it straight from the disk
   image, MenuFold offers to move itself there.)
3. Open MenuFold from Applications. It is not notarised by Apple, so macOS blocks the first launch with
   "Apple could not verify…". Click **Done**, go to **System Settings → Privacy & Security**, scroll down
   and click **Open Anyway**, then confirm with your password. You only do this once.
4. Keep MenuFold in the Dock: right-click its icon → **Options → Keep in Dock**. You can then remove the
   Dock's own Applications stack.

Requires macOS 26 or later on Apple silicon.

To check the download, run `shasum -a 256 -c SHA256SUMS` in the folder that holds both files.

### Updates

MenuFold updates itself with [Sparkle](https://sparkle-project.org). On the second launch it asks whether
to check for updates automatically. You can also use **Check for Updates…** in the app menu or in the
Dock icon's menu, and change the setting in **Settings → General → Updates**. Every update is signed, and
MenuFold refuses an update whose signature does not match. Updates install without the **Open Anyway** step.

Versions up to 0.3 have no updater: install 0.4 or newer from the DMG once.

### Uninstall

Quit MenuFold, move `MenuFold.app` to the Trash and delete `~/Library/Application Support/MenuFold/`.

What changed in each version is listed on the [Releases](https://github.com/dsidxavekko/MenuFold/releases) page.

## Using it

| Action | How |
| --- | --- |
| Open or close the panel | Click MenuFold in the Dock |
| Launch an app | Click it, or select it and press Return |
| Make a folder | Drag an app onto another app (on the **All** tab, with an empty search) |
| Take an app out of a folder | Drag it outside the open folder |
| Rename a folder | Click its title while it is open |
| Reorder tabs | Drag a tab, or right-click it → Move Left / Move Right |
| Settings | ⌘, while MenuFold is active, or right-click its Dock icon |

Your layout (folders, categories, hidden apps, custom icons) is saved in
`~/Library/Application Support/MenuFold/`. **Settings → General → Show in Finder** takes you there.

## Settings

| Tab | What's there |
| --- | --- |
| **General** | Open at login, Dock icon, the frequent apps row and its history, show or reset the layout |
| **Categories** | Turn the **Running** tab on or off, add, rename or delete your own categories, reset the tab order |
| **Apps** | Bring back hidden apps, change or reset custom icons, show Finder folders you dissolved again |
| **About** | Version and links |

## Privacy

MenuFold runs entirely on your Mac. Its only network request is the update check: once a day (if you
allow it) it downloads `appcast.xml` from this repository's GitHub releases. It sends no data about you
or your apps; GitHub sees the request like any download. It reads:

- Spotlight metadata, to find apps;
- each app's `Info.plist`, for its name and category;
- the `com.apple.dock` preferences (tile size and orientation only), to tell whether a click came from the Dock.

It writes only inside `~/Library/Application Support/MenuFold/`. If `layout.json` gets damaged, MenuFold
moves it aside as `layout.corrupt-<date>.json` and warns you in Settings, so your old layout is not lost.

When you drag an app out of the panel, Finder can only make an alias of it. It cannot move or copy the app.

## Build from source

You need macOS 26+, Xcode with the macOS 26 SDK, and [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(`brew install xcodegen`).

```bash
scripts/build.sh run          # generate the project, build Debug into ./build and launch it
scripts/release.sh            # Release build, verified, packed into ./dist (DMG, zip, appcast.xml)
```

The logic lives in a Swift package that builds and tests with just the Command Line Tools:

```bash
cd Packages/MenuFoldCore && swift build && swift test
scripts/typecheck-app.sh      # typecheck App/ in a few seconds, without building the app
```

`MenuFold.xcodeproj` is generated from `project.yml`. Edit `project.yml`, not the project.

### Layout

- `Packages/MenuFoldCore`: the app catalog (Spotlight), filtering rules, the saved layout, Finder folders
  and the `GridModel` that drives the UI. It has no views and is unit-tested with Swift Testing.
- `App/`: the AppKit + SwiftUI shell, made up of the panel window, Dock click handling, keyboard input, the
  views and Settings.

CI builds and tests the package and typechecks `App/` on every push. Pushing a `v*` tag builds the app and
publishes a GitHub release.

### Releasing

1. Add a `## <version>` section to [CHANGELOG.md](CHANGELOG.md) and set `MARKETING_VERSION` in
   `project.yml`. Commit.
2. `git tag v<version> && git push origin v<version>`. The Release workflow builds the DMG, the zip and
   `appcast.xml` and publishes them. Installed copies pick the version up from
   `releases/latest/download/appcast.xml`, so do not mark a release you don't want installed as latest.

Updates are signed with an EdDSA key. It was made once with Sparkle's `generate_keys` and lives in the
maintainer's login Keychain; its public half is `SUPublicEDKey` in `App/Info.plist`. CI reads the private
key from the `SPARKLE_PRIVATE_KEY` repository secret:

```bash
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x sparkle.key   # after scripts/build.sh
gh secret set SPARKLE_PRIVATE_KEY < sparkle.key && rm -P sparkle.key
```

Keep a backup of this key (for example in a password manager). Without it, existing installs can no
longer be updated.

## Known limitations

- The app is not notarised, so the first launch needs **Open Anyway** (see Install). Notarisation needs a
  paid Apple Developer account.
- With ad-hoc signing, **Open at Login** may need to be approved again after an update.

## License

MenuFold is released under the [MIT License](LICENSE): you may use, copy, change and share it freely, as
long as the copyright notice stays with it.

# Changelog

Each `## <version>` section becomes the release notes: on the GitHub release page and in the update
window inside MenuFold (`scripts/release.sh` reads the section of the version it builds). Write for
people who use the app, in English, as a `- ` list, with optional `### ` subheadings.

## 0.4.2

- Fixed: a layout file that could not be read (permissions, a lock) is no longer overwritten by the
  first action in the panel — your folders, categories and hidden apps survive, and the unreadable
  file is kept as a backup.
- Fixed: if opening the freshly installed copy from the disk image fails, MenuFold now tells you and
  keeps running instead of sitting invisible.
- Running MenuFold from an external volume no longer shows the "move to Applications" offer on every
  launch — only a real read-only disk image gets it.
- Apps can now be pinned to the Dock by dragging from MenuFold even when the Dock sits on the left or
  right edge of the screen.
- Settings show current values every time the window is opened: the login item, layout health, the
  Dock icon and the update settings used to go stale until relaunch.
- The "last update check" row now updates right after the check finishes.
- Failed launches no longer pollute the "Frequent apps" row; custom app icons survive a failed save;
  an app updated in place gets its new icon without a restart.
- Small fixes: the keyboard selection survives a category rename, the wallet copy button no longer
  flickers, Esc closes a folder with the same animation everywhere, the panel closes cleanly when the
  display setup changes, and the app bundle is not modified while it is quarantined.

## 0.4.1

- **Support MenuFold.** Settings → About now lists crypto addresses (BTC, ETH, SOL, TRX) for donations,
  with a copy button and a QR code for each.

## 0.3.1

- Re-release of 0.3.0 with a bumped build number; no functional changes.

## 0.4.0

- **Automatic updates.** MenuFold checks for a new version once a day and installs it for you.
  Use **Check for Updates…** in the app menu or the Dock icon's menu, and switch the checks off in
  Settings → General.
- **Disk image.** MenuFold now comes as a DMG: open it and drag MenuFold to Applications.
- If you open MenuFold straight from the disk image, it offers to move itself to Applications.
- From now on, updates install without the **Open Anyway** step.
- Fixed: in Settings → Categories, category names are left-aligned again.

## 0.3.0

- **Running tab**: the apps that are open right now, right after "All".
- **Keyboard navigation**: arrow keys to move, Return to launch, ⌘R to show in Finder, ⌘⌫ to move to
  the Trash.
- **Frequent apps** in a row above the grid.
- A Dock-style dot under each running app, plus Quit / Force Quit in its menu.
- **Move to Trash**, with a confirmation that offers to quit the app first.
- **Custom app icons** and more Dock icon choices.
- **English interface** next to Ukrainian.

## 0.2.0

- Settings window, About tab and a new logo.
- Choice of Dock icon.

## 0.1.0

- First release: the app grid, folders, category tabs and search.

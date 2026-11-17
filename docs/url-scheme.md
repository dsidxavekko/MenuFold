# menufold:// URL scheme

Use it from scripts (`open "menufold://..."`), launchers and Shortcuts. Parsing is in
`MenuFoldCore.URLCommand` (tested); `App/URLCommandHandler.swift` runs the commands.
Malformed or unknown URLs are logged and ignored. Values must be URL-encoded.

Apps are named by `id` (bundle id, matched first) or `name` (exact, case-insensitive; the
unlocalized name works too). Only apps the panel shows are addressed; an ambiguous name matches
nothing. Fields are limited to 256 characters.

## Panel

| URL | Effect |
|---|---|
| `menufold://toggle` | show or hide the panel |
| `menufold://show` (also `open`, or no command) | show the panel |
| `menufold://hide` | hide the panel |
| `menufold://search?q=TEXT` | show the panel with TEXT in search (max 1000 characters) |
| `menufold://folder?name=NAME` | show the panel with that folder open |
| `menufold://tab?name=NAME` | show the panel on a tab (title or category id) |
| `menufold://profile?name=NAME` | switch profile; empty or `none` = no profile |
| `menufold://settings` | open Settings |

## Apps

| URL | Effect |
|---|---|
| `launch?id=` (or `bundleid=`, `name=`) | launch the app, panel not shown |
| `quit?id=` | ask the running app to quit |
| `hide?id=` | hide the running app (without `id`/`name`, `hide` hides the panel) |
| `reveal?id=` | reveal in Finder |
| `copy-path?id=` | copy the .app path to the clipboard |

## Layout changes

These use the normal model intents, so they are saved and can be undone with ⌘Z. None of them
shows the panel.

| URL | Effect |
|---|---|
| `pin?id=` / `unpin?id=` | add to or remove from the "Закріплені" row |
| `new-folder?name=NAME&apps=ID,ID,...` | new folder; needs at least 2 resolvable apps, at most 50 are used; apps leave their old folders |
| `move-to-folder?id=&folder=` | move an app into a folder (folder name or UUID) |
| `remove-from-folder?id=` | take an app out of its folder |
| `category?id=BUNDLE_ID&name=CATEGORY` | assign a category (custom or system, by id or title); empty or `none` = automatic |

`name=` can replace `id=` in every app command except `category`, which takes the bundle id.

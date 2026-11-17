import Foundation

extension GridModel {
    /// Shortcut of an app or folder, or nil.
    public func hotkey(forApp appID: String) -> AppHotkey? { layout.appHotkeys[AppHotkey.key(appID: appID)] }
    public func hotkey(forFolder folderID: UUID) -> AppHotkey? { layout.appHotkeys[AppHotkey.key(folderID: folderID)] }

    /// Sets (or, with nil, removes) the shortcut stored under `key`. Another entry with the same
    /// combination loses it, so one combination never means two things.
    public func setHotkey(_ hotkey: AppHotkey?, forKey key: String) {
        guard !key.isEmpty, layout.appHotkeys[key] != hotkey else { return }
        var l = layout
        if let hotkey {
            for (other, value) in l.appHotkeys where value == hotkey && other != key { l.appHotkeys[other] = nil }
            l.appHotkeys[key] = hotkey
        } else {
            l.appHotkeys[key] = nil
        }
        commit(l)
    }

    public func setHotkey(_ hotkey: AppHotkey?, forApp appID: String) {
        setHotkey(hotkey, forKey: AppHotkey.key(appID: appID))
    }

    public func setHotkey(_ hotkey: AppHotkey?, forFolder folderID: UUID) {
        setHotkey(hotkey, forKey: AppHotkey.key(folderID: folderID))
    }

    /// Apps by id, for resolving a shortcut or an intent (installed and not hidden or not: any
    /// catalog app, since the user may want to launch a hidden one by a shortcut).
    public func app(withID id: String) -> AppEntry? { apps.first { $0.id == id } }

    /// Apps matching `text` (ranked like the panel search, hidden ones excluded), for Shortcuts.
    public func searchApps(_ text: String) -> [AppEntry] {
        items(tab: .all, query: text).compactMap { if case .app(let a) = $0 { a } else { nil } }
    }

    /// Folders with visible apps whose name matches `text` (all of them when blank).
    public func searchFolders(_ text: String) -> [Folder] {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return visibleFolders }
        return items(tab: .all, query: q).compactMap { if case .folder(let f, _) = $0 { f } else { nil } }
    }
}

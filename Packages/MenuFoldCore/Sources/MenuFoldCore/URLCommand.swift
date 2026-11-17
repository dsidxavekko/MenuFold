import Foundation

/// How a `menufold://` URL names an app: by bundle id or by display name.
public struct URLAppRef: Hashable, Sendable {
    public let text: String
    public init(_ text: String) { self.text = text }
}

/// A parsed `menufold://` command. Pure: `URLCommand.parse` only looks at the URL, so it is tested
/// without the app. Malformed or unknown input gives nil (the caller ignores it).
public enum URLCommand: Equatable, Sendable {
    case toggle, show, hide
    case search(String)
    case folder(name: String)
    case tab(name: String)
    case profile(name: String)          // empty = no profile
    case launch(URLAppRef)
    case settings
    case pin(URLAppRef)
    case unpin(URLAppRef)
    case newFolder(name: String, apps: [URLAppRef])
    case moveToFolder(app: URLAppRef, folder: String)
    case removeFromFolder(URLAppRef)
    case category(app: URLAppRef, name: String)   // empty = automatic
    case quit(URLAppRef)
    case hideApp(URLAppRef)
    case reveal(URLAppRef)
    case copyPath(URLAppRef)

    public static let scheme = "menufold"
    public static let maxApps = 50
    public static let maxFieldLength = 256
    public static let maxSearchLength = 1000

    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == scheme,
              url.absoluteString.count <= 8192,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // `menufold://search?q=x` has the command as its host; `menufold:search?q=x` as its path.
        let command = (components.host ?? components.path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let items = components.queryItems ?? []
        func raw(_ names: String...) -> String? {
            for n in names { if let v = items.first(where: { $0.name.lowercased() == n })?.value { return v } }
            return nil
        }
        func field(_ names: String...) -> String? {
            for n in names {
                if let v = items.first(where: { $0.name.lowercased() == n })?.value {
                    let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
                    return t.isEmpty || t.count > maxFieldLength || t.contains("\0") ? nil : t
                }
            }
            return nil
        }
        func app(_ names: String...) -> URLAppRef? {
            for n in names { if let v = field(n) { return URLAppRef(v) } }
            return nil
        }

        switch command {
        case "toggle": return .toggle
        case "show", "open", "": return .show
        case "hide": return app("id", "name").map { .hideApp($0) } ?? .hide   // with id: hide that running app
        case "search":
            let q = raw("q", "query") ?? ""
            return .search(String(q.prefix(maxSearchLength)))
        case "folder": return field("name").map { .folder(name: $0) }
        case "tab": return field("name").map { .tab(name: $0) }
        case "profile":
            let n = (raw("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard n.count <= maxFieldLength else { return nil }
            return .profile(name: n.lowercased() == "none" ? "" : n)
        case "launch": return app("id", "bundleid", "name").map { .launch($0) }
        case "settings", "preferences": return .settings
        case "pin": return app("id", "name").map { .pin($0) }
        case "unpin": return app("id", "name").map { .unpin($0) }
        case "new-folder":
            guard let name = field("name"), let list = raw("apps") else { return nil }
            var seen = Set<String>()
            var refs: [URLAppRef] = []
            for part in list.split(separator: ",", omittingEmptySubsequences: true) {
                let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t.count <= maxFieldLength, seen.insert(t).inserted else { continue }
                refs.append(URLAppRef(t))
                if refs.count == maxApps { break }
            }
            return refs.count >= 2 ? .newFolder(name: name, apps: refs) : nil
        case "move-to-folder":
            guard let a = app("id", "name"), let f = field("folder") else { return nil }
            return .moveToFolder(app: a, folder: f)
        case "remove-from-folder": return app("id", "name").map { .removeFromFolder($0) }
        case "category":
            guard let a = app("id") else { return nil }
            let n = (raw("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard n.count <= maxFieldLength else { return nil }
            return .category(app: a, name: n.lowercased() == "none" ? "" : n)
        case "quit": return app("id", "name").map { .quit($0) }
        case "reveal": return app("id", "name").map { .reveal($0) }
        case "copy-path": return app("id", "name").map { .copyPath($0) }
        default: return nil
        }
    }
}

extension GridModel {
    /// Bundle id first, then exact case-insensitive name (display or alternate). Only apps the panel
    /// shows. An ambiguous name (several apps) resolves to nothing.
    public func resolveApp(_ ref: URLAppRef) -> AppEntry? {
        let wanted = ref.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        let apps = visibleApps
        if let byID = apps.first(where: { $0.id == wanted }) { return byID }
        let lower = apps.filter { $0.id.caseInsensitiveCompare(wanted) == .orderedSame }
        if lower.count == 1 { return lower[0] }
        let named = apps.filter {
            $0.name.compare(wanted, options: .caseInsensitive) == .orderedSame
                || $0.alternateName?.compare(wanted, options: .caseInsensitive) == .orderedSame
        }
        return named.count == 1 ? named[0] : nil
    }

    /// Category assignable by URL: a custom or system category by id or display name.
    /// Smart categories are rule-driven and not assignable.
    public func assignableCategory(named name: String) -> AppCategory? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return nil }
        var pool = customCategories
        for tab in availableTabs { if case .category(let c) = tab { pool.append(c) } }
        pool.append(.other)
        return pool.first {
            !$0.isSmart && ([$0.id, $0.displayName].contains { s in
                s.compare(wanted, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame })
        }
    }

    /// New manual folder holding the resolved apps, as one undo step. Apps leave their old manual
    /// folders. Needs ≥2 distinct resolved apps. Returns the folder id.
    @discardableResult
    public func createFolder(named name: String, apps refs: [URLAppRef]) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var ids: [String] = []
        for ref in refs.prefix(URLCommand.maxApps) {
            if let app = resolveApp(ref), !ids.contains(app.id) { ids.append(app.id) }
        }
        guard ids.count >= 2 else { return nil }
        var l = layout
        for id in ids { Self.detach(id, from: &l) }
        let folder = Folder(name: trimmed, appIDs: ids)
        l.folders.append(folder)
        Self.dissolveSingleAppFolders(&l)
        commit(l)
        return folder.id
    }

    /// Folder by UUID or by name, for `move-to-folder`.
    public func folderForURL(_ text: String) -> Folder? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let uuid = UUID(uuidString: t), let f = folder(id: uuid) { return f }
        return folder(named: t)
    }

    /// Runs a model-only URL command (everything that needs no AppKit side effect). Returns false
    /// when it could not be applied (unknown app, folder, category).
    @discardableResult
    public func apply(_ command: URLCommand) -> Bool {
        switch command {
        case .pin(let r):
            guard let a = resolveApp(r) else { return false }
            pin(a.id); return true
        case .unpin(let r):
            guard let a = resolveApp(r) else { return false }
            unpin(a.id); return true
        case .newFolder(let name, let apps):
            return createFolder(named: name, apps: apps) != nil
        case .moveToFolder(let r, let folderText):
            guard let a = resolveApp(r), let f = folderForURL(folderText) else { return false }
            add(a.id, to: f.id); return true
        case .removeFromFolder(let r):
            guard let a = resolveApp(r) else { return false }
            removeFromFolder(a.id); return true
        case .category(let r, let name):
            guard let a = resolveApp(r) else { return false }
            if name.isEmpty { setCategory(nil, for: a.id); return true }
            guard let c = assignableCategory(named: name) else { return false }
            setCategory(c, for: a.id); return true
        default:
            return false
        }
    }
}

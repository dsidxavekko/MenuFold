import AppKit
import MenuFoldCore

/// `menufold://` URLs (CFBundleURLTypes in Info.plist), for scripts, launchers and other apps:
///
/// - `menufold://toggle`, `menufold://show`, `menufold://hide`
/// - `menufold://search?q=TEXT`: open the panel with TEXT in the search field
/// - `menufold://folder?name=NAME`: open the panel with that folder expanded
/// - `menufold://tab?name=NAME`: open the panel on the tab with that title (or category id)
/// - `menufold://settings`
///
/// Anything else is logged and ignored.
@MainActor
enum URLCommandHandler {
    static let scheme = "menufold"

    static func handle(_ url: URL, delegate: AppDelegate) {
        guard url.scheme?.lowercased() == scheme else { return }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        // `menufold://search?q=x` has the command as its host; `menufold:search?q=x` as its path.
        let command = (components?.host ?? components?.path ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let items = components?.queryItems ?? []
        delegate.noteExternalCommand()
        func value(_ name: String) -> String? {
            items.first { $0.name.lowercased() == name }?.value
        }

        switch command {
        case "toggle":
            delegate.togglePanelFromCommand()
        case "show", "open", "":
            delegate.showPanel()
        case "hide":
            delegate.panel.hide()
        case "search":
            delegate.showPanel(search: value("q") ?? value("query") ?? "")
        case "folder":
            guard let name = value("name"), delegate.showPanel(folderNamed: name) else {
                NSLog("%@", "MenuFold: no folder for \(url.absoluteString)")
                return
            }
        case "tab":
            guard let name = value("name"), delegate.showPanel(tabNamed: name) else {
                NSLog("%@", "MenuFold: no tab for \(url.absoluteString)")
                return
            }
        case "settings", "preferences":
            delegate.showSettings()
        default:
            NSLog("%@", "MenuFold: ignoring unknown URL \(url.absoluteString)")
        }
    }
}

extension AppDelegate {
    /// Records that a URL or Shortcuts action is being handled. Called first by every such command,
    /// so a cold start by one (which can arrive before `applicationDidFinishLaunching`) skips the
    /// default launch-time `show()`, which would reset the query/folder/tab or undo a "hide".
    func noteExternalCommand() {
        if !didFinishLaunching { handledCommandDuringLaunch = true }
    }

    /// True for a short while after launch (`justLaunchedInterval`).
    var isJustLaunched: Bool {
        Date().timeIntervalSince(launchDate) < Self.justLaunchedInterval
    }

    /// "toggle" from a URL or Shortcuts: right after a launch that the command itself caused, the
    /// panel may already be up from the launch, and hiding it would make the command look broken.
    func togglePanelFromCommand() {
        if isJustLaunched {
            showPanel()
        } else {
            panel.toggle(bypassingDockGuard: true)
        }
    }

    /// Shows the panel unless it is already up (a second `show()` would replay the open motion and
    /// reset the query). Never blocked by the Dock reopen guard: these requests don't come from the Dock.
    func showPanel() {
        if !panel.isShown { panel.show() }
    }

    /// Shows the panel with `text` in the search field.
    func showPanel(search text: String) {
        showPanel()
        model.openFolderID = nil
        model.query = text
    }

    /// Shows the panel with the folder called `name` expanded (case-insensitive). False if none.
    @discardableResult
    func showPanel(folderNamed name: String) -> Bool {
        guard let folder = model.folder(named: name) else { return false }
        showPanel()
        model.query = ""
        model.tab = .all
        model.openFolderID = folder.id
        return true
    }

    /// Shows the panel on the tab whose title or category id is `name` (case-insensitive). False if none.
    @discardableResult
    func showPanel(tabNamed name: String) -> Bool {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tab = model.availableTabs.first(where: { Self.matches($0, wanted) }) else { return false }
        showPanel()
        model.query = ""
        model.openFolderID = nil
        model.tab = tab
        return true
    }

    private static func matches(_ tab: GridTab, _ name: String) -> Bool {
        let candidates: [String]
        switch tab {
        case .all: candidates = ["all", String(localized: "Все")]
        case .running: candidates = ["running", String(localized: "Запущені")]
        case .recent: candidates = ["recent", String(localized: "Недавні")]
        case .category(let category): candidates = [category.id, category.displayName]
        }
        return candidates.contains { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}

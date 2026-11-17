import AppKit
import MenuFoldCore

/// `menufold://` URLs (CFBundleURLTypes in Info.plist), for scripts, launchers and other apps:
///
/// - `menufold://toggle`, `menufold://show`, `menufold://hide`
/// - `menufold://search?q=TEXT`: open the panel with TEXT in the search field
/// - `menufold://folder?name=NAME`: open the panel with that folder expanded
/// - `menufold://tab?name=NAME`: open the panel on the tab with that title (or category id)
/// - `menufold://launch?id=BUNDLE_ID`: launch (or bring forward) that app, without showing the panel
/// - `menufold://settings`
///
/// Parsing lives in `MenuFoldCore.URLCommand`; see docs/url-scheme.md for every command.
/// Anything else is logged and ignored.
@MainActor
enum URLCommandHandler {
    static let scheme = "menufold"

    static func handle(_ url: URL, delegate: AppDelegate) {
        guard url.scheme?.lowercased() == scheme else { return }
        delegate.noteExternalCommand()
        guard let command = URLCommand.parse(url) else {
            NSLog("%@", "MenuFold: ignoring unknown or malformed URL \(url.absoluteString)")
            return
        }
        let model = delegate.model
        func fail() { NSLog("%@", "MenuFold: could not apply \(url.absoluteString)") }

        switch command {
        case .toggle:
            delegate.togglePanelFromCommand()
        case .show:
            delegate.showPanel()
        case .hide:
            delegate.panel.hide()
        case .search(let text):
            delegate.showPanel(search: text)
        case .folder(let name):
            if !delegate.showPanel(folderNamed: name) { fail() }
        case .tab(let name):
            if !delegate.showPanel(tabNamed: name) { fail() }
        case .profile(let name):
            if name.isEmpty {
                model.setActiveProfile(nil)
            } else if !model.setActiveProfile(named: name) {
                fail()
            }
        case .launch(let ref):
            // Only apps the panel shows: a hidden app is not launchable from a URL.
            if let app = model.resolveApp(ref) { model.launch(app) } else { fail() }
        case .settings:
            delegate.showSettings()
        case .pin, .unpin, .newFolder, .moveToFolder, .removeFromFolder, .category:
            if !model.apply(command) { fail() }
        case .quit(let ref):
            if let app = model.resolveApp(ref) { RunningAppsMonitor.shared.quit(app.id) } else { fail() }
        case .hideApp(let ref):
            if let app = model.resolveApp(ref) {
                NSRunningApplication.runningApplications(withBundleIdentifier: app.id).forEach { $0.hide() }
            } else { fail() }
        case .reveal(let ref):
            if let app = model.resolveApp(ref) { model.revealInFinder(app) } else { fail() }
        case .copyPath(let ref):
            if let app = model.resolveApp(ref) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(app.url.path, forType: .string)
            } else { fail() }
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

    /// Shows the panel with the folder `id` expanded. False if there is none.
    @discardableResult
    func showPanel(folderID id: UUID) -> Bool {
        guard let folder = model.folder(id: id) else { return false }
        showPanel()
        model.query = ""
        model.tab = .all
        model.openFolderID = folder.id
        return true
    }

    /// Launches the visible app with this bundle id. False if unknown or hidden.
    @discardableResult
    func launchApp(id: String) -> Bool {
        let wanted = id.trimmingCharacters(in: .whitespacesAndNewlines)
        // Only apps the panel shows: a hidden app is not launchable from a URL.
        guard let app = model.visibleApps.first(where: { $0.id == wanted }) else { return false }
        model.launch(app)
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
        case .clipboard: candidates = ["clipboard", String(localized: "Буфер обміну")]
        case .all: candidates = ["all", String(localized: "Все")]
        case .running: candidates = ["running", String(localized: "Запущені")]
        case .recent: candidates = ["recent", String(localized: "Недавні")]
        case .category(let category): candidates = [category.id, category.displayName]
        }
        return candidates.contains { $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}

#if canImport(AppIntents)
import AppIntents
import AppKit

// Shortcuts actions. Each one runs in the app (`openAppWhenRun`) and goes through the AppDelegate,
// the same path as the `menufold://` URLs.

/// Opens (or closes) the panel.
struct ToggleMenuFoldIntent: AppIntent {
    static let title: LocalizedStringResource = "Відкрити MenuFold"
    static let description = IntentDescription("Показує або ховає панель MenuFold.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate else { return .result() }
        delegate.noteExternalCommand()
        delegate.togglePanelFromCommand()
        return .result()
    }
}

/// Opens the panel with a search.
struct SearchMenuFoldIntent: AppIntent {
    static let title: LocalizedStringResource = "Шукати в MenuFold"
    static let description = IntentDescription("Відкриває панель MenuFold із цим текстом у пошуку.")
    static let openAppWhenRun = true

    @Parameter(title: "Текст")
    var text: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate else { return .result() }
        delegate.noteExternalCommand()
        delegate.showPanel(search: text)
        return .result()
    }
}

/// Opens the panel with a folder expanded.
struct OpenMenuFoldFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Відкрити папку MenuFold"
    static let description = IntentDescription("Відкриває панель MenuFold із цією папкою.")
    static let openAppWhenRun = true

    @Parameter(title: "Назва папки")
    var name: String

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate else { return .result() }
        delegate.noteExternalCommand()
        if !delegate.showPanel(folderNamed: name) {
            // No such folder: still open the panel, with the name as a search, so the user sees why.
            delegate.showPanel(search: name)
        }
        return .result()
    }
}

struct MenuFoldShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleMenuFoldIntent(),
            phrases: ["Відкрити \(.applicationName)", "Open \(.applicationName)"],
            shortTitle: "Відкрити MenuFold",
            systemImageName: "square.grid.3x3.fill"
        )
        AppShortcut(
            intent: SearchMenuFoldIntent(),
            phrases: ["Шукати в \(.applicationName)", "Search in \(.applicationName)"],
            shortTitle: "Шукати в MenuFold",
            systemImageName: "magnifyingglass"
        )
        AppShortcut(
            intent: OpenMenuFoldFolderIntent(),
            phrases: ["Відкрити папку в \(.applicationName)", "Open a folder in \(.applicationName)"],
            shortTitle: "Відкрити папку MenuFold",
            systemImageName: "folder"
        )
    }
}
#endif

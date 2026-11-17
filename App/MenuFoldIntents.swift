#if canImport(AppIntents)
import AppIntents
import AppKit
import MenuFoldCore

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

// MARK: - Entities
//
// Apps, folders, categories and profiles as Shortcuts parameters. Ids are stable (bundle id, folder
// UUID, category id, profile id), so a saved shortcut keeps working after a rename. The queries read
// the live `GridModel` on the main actor.

@MainActor
private enum IntentModel {
    /// The app's model. Right after a cold start by a shortcut the catalog may still be empty, so
    /// the callers wait a moment for the first scan.
    static func current() async -> GridModel? {
        guard let delegate = NSApp.delegate as? AppDelegate else { return nil }
        for _ in 0..<30 where delegate.model.apps.isEmpty {
            try? await Task.sleep(for: .milliseconds(100))
        }
        return delegate.model
    }
}

/// A failure Shortcuts shows to the user.
struct MenuFoldIntentError: Error, CustomLocalizedStringResourceConvertible {
    let localizedStringResource: LocalizedStringResource
    static let appNotFound = MenuFoldIntentError(localizedStringResource: "Програму не знайдено")
    static let folderNotFound = MenuFoldIntentError(localizedStringResource: "Папку не знайдено")
    static let profileNotFound = MenuFoldIntentError(localizedStringResource: "Профіль не знайдено")
}

struct MenuFoldAppEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Програма")
    static let defaultQuery = MenuFoldAppQuery()

    /// Bundle identifier.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ app: AppEntry) { id = app.id; name = app.name }
}

struct MenuFoldAppQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MenuFoldAppEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return identifiers.compactMap { model.app(withID: $0) }.map(MenuFoldAppEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MenuFoldAppEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return model.searchApps(string).map(MenuFoldAppEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MenuFoldAppEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return (model.frequentApps + model.visibleApps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            .reduce(into: [AppEntry]()) { list, app in if !list.contains(where: { $0.id == app.id }) { list.append(app) } }
            .map(MenuFoldAppEntity.init)
    }
}

struct MenuFoldFolderEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Папка")
    static let defaultQuery = MenuFoldFolderQuery()

    /// Folder UUID string.
    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ folder: Folder) { id = folder.id.uuidString; name = folder.name }
}

struct MenuFoldFolderQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MenuFoldFolderEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return identifiers.compactMap { UUID(uuidString: $0).flatMap(model.folder(id:)) }.map(MenuFoldFolderEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MenuFoldFolderEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return model.searchFolders(string).map(MenuFoldFolderEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MenuFoldFolderEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return model.visibleFolders.map(MenuFoldFolderEntity.init)
    }
}

struct MenuFoldCategoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Категорія")
    static let defaultQuery = MenuFoldCategoryQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ category: AppCategory) { id = category.id; name = category.displayName }

    /// Your own categories first, then the system ones.
    @MainActor
    static func all(in model: GridModel) -> [MenuFoldCategoryEntity] {
        (model.customCategories + AppCategory.known + [AppCategory.other]).map(MenuFoldCategoryEntity.init)
    }
}

struct MenuFoldCategoryQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MenuFoldCategoryEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return MenuFoldCategoryEntity.all(in: model).filter { identifiers.contains($0.id) }
    }

    @MainActor
    func entities(matching string: String) async throws -> [MenuFoldCategoryEntity] {
        guard let model = await IntentModel.current() else { return [] }
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return MenuFoldCategoryEntity.all(in: model).filter {
            q.isEmpty || $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    @MainActor
    func suggestedEntities() async throws -> [MenuFoldCategoryEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return MenuFoldCategoryEntity.all(in: model)
    }
}

struct MenuFoldProfileEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Профіль")
    static let defaultQuery = MenuFoldProfileQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }

    init(_ profile: Profile) { id = profile.id; name = profile.name }
}

struct MenuFoldProfileQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [MenuFoldProfileEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return model.profiles.filter { identifiers.contains($0.id) }.map(MenuFoldProfileEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [MenuFoldProfileEntity] {
        guard let model = await IntentModel.current() else { return [] }
        let q = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.profiles.filter {
            q.isEmpty || $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }.map(MenuFoldProfileEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [MenuFoldProfileEntity] {
        guard let model = await IntentModel.current() else { return [] }
        return model.profiles.map(MenuFoldProfileEntity.init)
    }
}

// MARK: - Actions
//
// These change data or launch an app without showing the panel, so they don't foreground MenuFold.

struct LaunchAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Запустити програму"
    static let description = IntentDescription("Запускає програму або виводить її наперед.")

    @Parameter(title: "Програма")
    var app: MenuFoldAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate else { return .result() }
        delegate.noteExternalCommand()
        _ = await IntentModel.current()
        guard delegate.launchApp(id: app.id) else { throw MenuFoldIntentError.appNotFound }
        return .result()
    }
}

struct PinAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Закріпити програму"
    static let description = IntentDescription("Додає програму до рядка «Закріплені» в MenuFold.")

    @Parameter(title: "Програма")
    var app: MenuFoldAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate else { return .result() }
        delegate.noteExternalCommand()
        guard let model = await IntentModel.current(), model.app(withID: app.id) != nil else {
            throw MenuFoldIntentError.appNotFound
        }
        model.pin(app.id)
        return .result()
    }
}

struct UnpinAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Відкріпити програму"
    static let description = IntentDescription("Прибирає програму з рядка «Закріплені» в MenuFold.")

    @Parameter(title: "Програма")
    var app: MenuFoldAppEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate else { return .result() }
        delegate.noteExternalCommand()
        guard let model = await IntentModel.current() else { throw MenuFoldIntentError.appNotFound }
        model.unpin(app.id)
        return .result()
    }
}

struct AddToFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Додати до папки"
    static let description = IntentDescription("Кладе програму в папку MenuFold.")

    @Parameter(title: "Програма")
    var app: MenuFoldAppEntity

    @Parameter(title: "Папка")
    var folder: MenuFoldFolderEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate else { return .result() }
        delegate.noteExternalCommand()
        guard let model = await IntentModel.current(), model.app(withID: app.id) != nil else {
            throw MenuFoldIntentError.appNotFound
        }
        guard let folderID = UUID(uuidString: folder.id), model.folder(id: folderID) != nil else {
            throw MenuFoldIntentError.folderNotFound
        }
        model.add(app.id, to: folderID)
        return .result()
    }
}

struct AssignCategoryIntent: AppIntent {
    static let title: LocalizedStringResource = "Призначити категорію"
    static let description = IntentDescription("Переносить програму до категорії. Без категорії програма повертається до автоматичної.")

    @Parameter(title: "Програма")
    var app: MenuFoldAppEntity

    @Parameter(title: "Категорія")
    var category: MenuFoldCategoryEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate else { return .result() }
        delegate.noteExternalCommand()
        guard let model = await IntentModel.current(), model.app(withID: app.id) != nil else {
            throw MenuFoldIntentError.appNotFound
        }
        let chosen = category.map { AppCategory(id: $0.id, displayName: $0.name) }
        model.setCategory(chosen, for: app.id)
        return .result()
    }
}

struct SwitchProfileIntent: AppIntent {
    static let title: LocalizedStringResource = "Перемкнути профіль"
    static let description = IntentDescription("Вмикає профіль MenuFold. Без профілю діє звичайний вигляд.")

    @Parameter(title: "Профіль")
    var profile: MenuFoldProfileEntity?

    @MainActor
    func perform() async throws -> some IntentResult {
        guard let delegate = NSApp.delegate as? AppDelegate else { return .result() }
        delegate.noteExternalCommand()
        guard let model = await IntentModel.current() else { return .result() }
        if let profile {
            guard model.profiles.contains(where: { $0.id == profile.id }) else { throw MenuFoldIntentError.profileNotFound }
            model.setActiveProfile(profile.id)
        } else {
            model.setActiveProfile(nil)
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
        AppShortcut(
            intent: LaunchAppIntent(),
            phrases: ["Запустити \(\.$app) через \(.applicationName)", "Launch \(\.$app) with \(.applicationName)"],
            shortTitle: "Запустити програму",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: PinAppIntent(),
            phrases: ["Закріпити \(\.$app) в \(.applicationName)", "Pin \(\.$app) in \(.applicationName)"],
            shortTitle: "Закріпити програму",
            systemImageName: "pin"
        )
        AppShortcut(
            intent: UnpinAppIntent(),
            phrases: ["Відкріпити \(\.$app) в \(.applicationName)", "Unpin \(\.$app) in \(.applicationName)"],
            shortTitle: "Відкріпити програму",
            systemImageName: "pin.slash"
        )
        AppShortcut(
            intent: AddToFolderIntent(),
            phrases: ["Додати \(\.$app) до папки в \(.applicationName)", "Add \(\.$app) to a folder in \(.applicationName)"],
            shortTitle: "Додати до папки",
            systemImageName: "folder.badge.plus"
        )
        AppShortcut(
            intent: AssignCategoryIntent(),
            phrases: ["Призначити категорію для \(\.$app) в \(.applicationName)", "Set the category of \(\.$app) in \(.applicationName)"],
            shortTitle: "Призначити категорію",
            systemImageName: "tag"
        )
        AppShortcut(
            intent: SwitchProfileIntent(),
            phrases: ["Перемкнути профіль в \(.applicationName)", "Switch profile in \(.applicationName)"],
            shortTitle: "Перемкнути профіль",
            systemImageName: "person.crop.circle"
        )
    }
}
#endif

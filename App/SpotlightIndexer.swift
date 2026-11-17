import AppKit
@preconcurrency import CoreSpotlight
import MenuFoldCore
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Puts MenuFold's folders and your own categories into the system Spotlight index, so typing a
/// folder name in Spotlight opens it in MenuFold (apps themselves are already in Spotlight).
///
/// Each item carries `contentURL` = `menufold://folder?name=` / `menufold://tab?name=`, and
/// `application(_:continue:)` handles the Core Spotlight activity too, so both ways land in the same
/// `AppDelegate.showPanel(...)`. The index follows the layout live (renames, new and deleted
/// folders), and anything that no longer exists is removed.
///
/// Ad-hoc signing risk: the app has no stable code identity, and Core Spotlight ties indexed items to
/// it. After an update (a new binary hash) macOS may drop the old items or refuse them; they are
/// rebuilt from scratch at every launch (`deleteAll` + index), so the worst case is a gap until the
/// next launch. Indexing failures are only logged. Settings → Загальне has a switch (on by default);
/// turning it off removes everything MenuFold indexed.
@MainActor
final class SpotlightIndexer {
    static let shared = SpotlightIndexer()
    static let enabledKey = "indexesInSpotlight"
    static let domain = "com.menufold.items"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    private var model: GridModel?
    private var defaultsObserver: NSObjectProtocol?
    private var pending: Task<Void, Never>?
    /// What was indexed last (ids + names), to skip identical rebuilds.
    private var lastSignature: [String] = []
    private var wasEnabled = false

    private init() {}

    func start(model: GridModel) {
        guard self.model == nil else { return }
        self.model = model
        observe()
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Self.isEnabled != self.wasEnabled else { return }
                self.schedule(delay: .milliseconds(100))
            }
        }
        schedule(delay: .seconds(3))
    }

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            _ = model.visibleFolders
            _ = model.layout.customCategories
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.schedule(delay: .seconds(1))
                self?.observe()
            }
        }
    }

    /// Debounced: a burst of layout changes (a drag, a rename) reindexes once.
    private func schedule(delay: Duration) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reindex()
        }
    }

    private struct Entry {
        let id: String
        let title: String
        let detail: String
        let url: URL?
        let keywords: [String]
    }

    private func entries() -> [Entry] {
        guard let model else { return [] }
        func url(_ command: String, name: String) -> URL? {
            var c = URLComponents()
            c.scheme = URLCommandHandler.scheme
            c.host = command
            c.queryItems = [URLQueryItem(name: "name", value: name)]
            return c.url
        }
        var list: [Entry] = []
        for folder in model.visibleFolders {
            let count = model.apps(in: folder).count
            list.append(Entry(
                id: "folder:" + folder.id.uuidString,
                title: folder.name,
                detail: String(localized: "Папка MenuFold · програм: \(count)"),
                url: url("folder", name: folder.name),
                keywords: ["MenuFold", String(localized: "Папка")]
            ))
        }
        for category in model.layout.customCategories {
            list.append(Entry(
                id: "category:" + category.id,
                title: category.name,
                detail: String(localized: "Категорія MenuFold"),
                url: url("tab", name: category.name),
                keywords: ["MenuFold", String(localized: "Категорія")]
            ))
        }
        return list
    }

    private func reindex() {
        let index = CSSearchableIndex.default()
        let enabled = Self.isEnabled
        wasEnabled = enabled
        guard enabled else {
            lastSignature = []
            index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { error in
                if let error { NSLog("%@", "MenuFold: Spotlight cleanup failed: \(error.localizedDescription)") }
            }
            return
        }
        let list = entries()
        let signature = list.map { "\($0.id)|\($0.title)|\($0.detail)" }
        guard signature != lastSignature else { return }
        lastSignature = signature
        let items = list.map { entry -> CSSearchableItem in
            let attributes = CSSearchableItemAttributeSet(contentType: .content)
            attributes.title = entry.title
            attributes.displayName = entry.title
            attributes.contentDescription = entry.detail
            attributes.keywords = entry.keywords
            attributes.contentURL = entry.url
            return CSSearchableItem(uniqueIdentifier: entry.id, domainIdentifier: Self.domain, attributeSet: attributes)
        }
        // Delete the whole domain first: items of removed folders and categories disappear with it.
        index.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { error in
            if let error { NSLog("%@", "MenuFold: Spotlight cleanup failed: \(error.localizedDescription)") }
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items) { error in
                if let error { NSLog("%@", "MenuFold: Spotlight indexing failed: \(error.localizedDescription)") }
            }
        }
    }
}

extension AppDelegate {
    /// A click on a MenuFold result in Spotlight (Core Spotlight activity).
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == CSSearchableItemActionType,
              let id = userActivity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return false }
        noteExternalCommand()
        if id.hasPrefix("folder:"), let uuid = UUID(uuidString: String(id.dropFirst(7))) {
            return showPanel(folderID: uuid)
        }
        if id.hasPrefix("category:") {
            return showPanel(tabNamed: String(id.dropFirst(9)))
        }
        return false
    }
}

/// Settings switch for the Spotlight index (Settings → Загальне).
struct SpotlightSettingsSection: View {
    @AppStorage(SpotlightIndexer.enabledKey) private var enabled = true

    var body: some View {
        Section {
            Toggle("Показувати папки й категорії в Spotlight", isOn: $enabled)
        } header: {
            Label("Spotlight", systemImage: "magnifyingglass")
        } footer: {
            Text("Назва папки або власної категорії в Spotlight відкриє її в MenuFold. Через підпис без Apple Developer ID macOS інколи губить такі записи після оновлення; MenuFold перестворює їх при кожному запуску.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

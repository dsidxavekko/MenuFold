import AppKit
import MenuFoldCore
import SwiftUI
import UniformTypeIdentifiers

/// Settings → Дані: export/import of the layout, dated backups, the data folder (which may be a
/// synced folder shared between Macs) and the layout file itself.
///
/// Like the other tabs it is created once and cached, so the backup list and the data folder are
/// re-read on appear and whenever the Settings window becomes key.
struct DataSettingsView: View {
    let model: GridModel

    @State private var backups: [LayoutBackup] = []
    @State private var confirmReset = false
    @Bindable private var prefs = AppPreferences.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Папки, категорії, закріплені й приховані програми та власні значки в одному файлі.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Експортувати…") { exportLayout() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Button("Імпортувати…") { importLayout() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                .font(.callout)
            } header: {
                Label("Експорт та імпорт", systemImage: "square.and.arrow.up.on.square")
            }

            Section {
                if backups.isEmpty {
                    Text("Резервних копій ще немає")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(backups) { backup in
                        HStack(spacing: 8) {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            Text(backup.date.formatted(date: .long, time: .shortened))
                            Spacer()
                            Button("Показати у Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([backup.url])
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            Button("Відновити…") { restore(backup) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Label("Резервні копії", systemImage: "clock.arrow.circlepath")
            } footer: {
                Text("MenuFold щодня під час запуску зберігає копію розкладки й тримає сім останніх.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                VStack(alignment: .leading, spacing: 2) {
                    if isDefault(activeDirectory) {
                        Text("Типова тека")
                    } else {
                        Text("Власна тека")
                    }
                    pathText(activeDirectory)
                }
                if let pending = pendingDirectory {
                    // Only when a restart did not happen after a change: the new folder is stored
                    // but this session still reads and writes the old one shown above.
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Після перезапуску")
                        pathText(pending)
                    }
                }
                HStack {
                    Button("Показати у Finder") { revealDataFolder() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Spacer()
                    if !isDefault(configuredDirectory) {
                        Button("Типова") { changeDataDirectory(to: nil) }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    Button("Змінити…") { chooseDataDirectory() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
            } header: {
                Label("Тека даних", systemImage: "folder")
            } footer: {
                Text("Тут лежать розкладка (layout.json) і власні значки. Якщо вибрати теку, що синхронізується (iCloud Drive, Dropbox), папки й категорії будуть спільними для всіх ваших Mac; коли розкладку змінено на іншому Mac, MenuFold підхоплює її сам. У вибраній теці створюється тека «MenuFold». Після зміни MenuFold перезапускається.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Text("Розкладка зберігається у файлі layout.json")
                    Spacer()
                    Button("Показати у Finder") { revealLayoutFile() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                Button("Скинути розкладку…", role: .destructive) { confirmReset = true }
                    .buttonStyle(.glass)
                    .tint(.red)
                    .confirmationDialog(
                        "Скинути розкладку?",
                        isPresented: $confirmReset,
                        titleVisibility: .visible
                    ) {
                        Button("Скинути", role: .destructive) {
                            model.resetLayout()
                            refreshAllTabs()
                        }
                        Button("Скасувати", role: .cancel) {}
                    } message: {
                        Text("Усі папки, власні й перевизначені категорії, власні значки та приховані програми буде видалено.")
                    }
            } header: {
                Label("Розкладка", systemImage: "square.grid.3x3")
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.contentDidBecomeKey)) { _ in
            refresh()
        }
    }

    // MARK: State

    private func refresh() {
        backups = model.backups
    }

    /// The layout changed under the other tabs (reset, import, restore): the General tab's
    /// layout-health warning and other cached rows re-read their state on this notification.
    private func refreshAllTabs() {
        NotificationCenter.default.post(name: SettingsWindowController.contentDidBecomeKey, object: nil)
    }

    private static var defaultDirectory: URL {
        LayoutStore.defaultURL.deletingLastPathComponent()
    }

    /// The folder this session really reads and writes (the store's), not the stored preference.
    private var activeDirectory: URL {
        (model.layoutFileURL ?? LayoutStore.defaultURL).deletingLastPathComponent()
    }

    /// The folder the next launch will use.
    private var configuredDirectory: URL {
        prefs.dataDirectory ?? Self.defaultDirectory
    }

    /// The configured folder when it is not the active one yet (a restart is pending).
    private var pendingDirectory: URL? {
        Self.samePath(configuredDirectory, activeDirectory) ? nil : configuredDirectory
    }

    private func isDefault(_ url: URL) -> Bool {
        Self.samePath(url, Self.defaultDirectory)
    }

    private static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func pathText(_ url: URL) -> some View {
        Text(url.path(percentEncoded: false))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    // MARK: Export / import / backups

    private func exportLayout() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Експортувати налаштування")
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "MenuFold-layout.json"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.exportLayout(to: url)
        } catch {
            SettingsAlerts.showError(error, title: String(localized: "Не вдалося експортувати"))
        }
    }

    private func importLayout() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Імпортувати налаштування")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard SettingsAlerts.confirm(
            String(localized: "Імпортувати розкладку?"),
            message: String(localized: "Поточну розкладку буде замінено вмістом файлу. Це можна скасувати сполученням ⌘Z у панелі."),
            confirm: String(localized: "Імпортувати")
        ) else { return }
        do {
            try model.importLayout(from: url)
        } catch {
            SettingsAlerts.showError(error, title: String(localized: "Не вдалося імпортувати"))
        }
        refreshAllTabs()
    }

    private func restore(_ backup: LayoutBackup) {
        guard SettingsAlerts.confirm(
            String(localized: "Відновити розкладку від \(backup.date.formatted(date: .long, time: .shortened))?"),
            message: String(localized: "Поточну розкладку буде замінено копією. Це можна скасувати сполученням ⌘Z у панелі."),
            confirm: String(localized: "Відновити")
        ) else { return }
        do {
            try model.restore(backup)
        } catch {
            SettingsAlerts.showError(error, title: String(localized: "Не вдалося відновити"))
        }
        refreshAllTabs()
    }

    // MARK: Files

    private func revealLayoutFile() {
        reveal(model.layoutFileURL ?? LayoutStore.defaultURL)
    }

    private func revealDataFolder() {
        reveal(activeDirectory, select: false)
    }

    /// Selects `url` in Finder, or opens the nearest existing parent folder (layout.json and its
    /// folder are created only on the first save).
    private func reveal(_ url: URL, select: Bool = true) {
        let fm = FileManager.default
        if select, fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        var dir = select ? url.deletingLastPathComponent() : url
        while !fm.fileExists(atPath: dir.path), dir.pathComponents.count > 1 {
            dir = dir.deletingLastPathComponent()
        }
        NSWorkspace.shared.open(dir)
    }

    // MARK: Data folder

    private func chooseDataDirectory() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Тека даних MenuFold")
        panel.message = String(localized: "Виберіть теку для розкладки та значків, наприклад у iCloud Drive.")
        panel.prompt = String(localized: "Вибрати")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let iCloud = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        // Start in the folder that holds the current custom data folder (its parent: the user picks
        // the containing folder, MenuFold makes its own "MenuFold" folder inside).
        panel.directoryURL = prefs.dataDirectory?.deletingLastPathComponent()
            ?? (FileManager.default.fileExists(atPath: iCloud.path) ? iCloud : nil)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        changeDataDirectory(to: url)
    }

    /// Switches the data folder to `target`, a folder the user picked (nil = the default one). The
    /// data goes into a dedicated "MenuFold" folder inside it (see `DataFolderMigration`). The
    /// current layout and icons are carried over unless that folder already has a MenuFold layout,
    /// in which case the user chooses which one wins.
    ///
    /// The running store keeps writing to the old folder until MenuFold restarts, so edits made
    /// meanwhile would be lost; the change therefore takes effect only together with a restart.
    /// Cancelling leaves the preference as it was and deletes nothing (the copied files stay).
    private func changeDataDirectory(to target: URL?) {
        let destination: URL
        do {
            destination = try target.map(DataFolderMigration.dedicatedFolder(for:)) ?? Self.defaultDirectory
        } catch {
            SettingsAlerts.showError(error, title: String(localized: "Не вдалося змінити теку даних"))
            return
        }
        let source = activeDirectory
        if Self.samePath(destination, source) {
            // Back to the folder in use (a pending change is undone): nothing to copy or restart.
            prefs.dataDirectory = isDefault(destination) ? nil : destination
            return
        }

        do {
            switch try DataFolderMigration.prepare(from: source, to: destination) {
            case .cancelled:
                return
            case .done:
                break
            }
        } catch {
            SettingsAlerts.showError(error, title: String(localized: "Не вдалося змінити теку даних"))
            return
        }

        let alert = NSAlert()
        alert.messageText = String(localized: "Перезапустити MenuFold, щоб застосувати теку?")
        alert.informativeText = String(localized: "Нова тека: \(destination.path(percentEncoded: false))")
        alert.addButton(withTitle: String(localized: "Перезапустити"))
        alert.addButton(withTitle: String(localized: "Скасувати"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let previous = prefs.dataDirectory
        prefs.dataDirectory = isDefault(destination) ? nil : destination
        guard let delegate = NSApp.delegate as? AppDelegate else {
            prefs.dataDirectory = previous
            return
        }
        delegate.relaunch()
    }
}

/// Copies the layout and icons into a new data folder before MenuFold switches to it.
@MainActor
enum DataFolderMigration {
    enum Outcome { case done, cancelled }

    enum MigrationError: LocalizedError {
        /// The folder has a layout.json that is not a MenuFold layout this version can use.
        case foreignLayoutFile(URL)
        /// "MenuFold" exists in the picked folder but is a file, not a folder.
        case notAFolder(URL)

        var errorDescription: String? {
            switch self {
            case .foreignLayoutFile(let url):
                String(localized: "У теці «\(url.deletingLastPathComponent().lastPathComponent)» уже є файл layout.json, який не є розкладкою MenuFold (або створений новішою версією). MenuFold не змінюватиме його; виберіть іншу теку.")
            case .notAFolder(let url):
                String(localized: "«\(url.path(percentEncoded: false))» — це файл, а не тека. Виберіть іншу теку.")
            }
        }
    }

    static let folderName = "MenuFold"

    /// MenuFold's own folder for a folder the user picked: `picked/MenuFold`, unless `picked` is
    /// already such a folder (named "MenuFold" and holding a MenuFold layout, e.g. the shared folder
    /// another Mac set up). MenuFold never keeps its files loose in a folder of the user's own.
    static func dedicatedFolder(for picked: URL) throws -> URL {
        let picked = picked.standardizedFileURL
        if picked.lastPathComponent == folderName,
           case .menuFold = layoutKind(at: picked.appendingPathComponent("layout.json")) {
            return picked
        }
        let folder = picked.appendingPathComponent(folderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            throw MigrationError.notAFolder(folder)
        }
        return folder
    }

    enum LayoutKind { case none, menuFold, foreign }

    /// Whether `url` holds a MenuFold layout this version can use. Mirrors
    /// `LayoutStore.decodeValidated(_:)` (internal to MenuFoldCore): size limit, a `Layout`
    /// decode, no newer schema. `Layout` decodes leniently (missing keys keep defaults), so a
    /// `version` key is also required; otherwise any JSON object would pass as a layout.
    static func layoutKind(at url: URL) -> LayoutKind {
        guard FileManager.default.fileExists(atPath: url.path) else { return .none }
        guard let data = try? Data(contentsOf: url),
              data.count <= LayoutStore.maxFileSize,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["version"] is Int,
              let layout = try? JSONDecoder().decode(Layout.self, from: data),
              layout.version <= Layout.currentVersion
        else { return .foreign }
        return .menuFold
    }

    /// When `destination` already has a MenuFold layout.json, asks whether to keep it or overwrite
    /// it with the current one. A layout.json that is not a MenuFold layout is never overwritten:
    /// the change is refused. Icons are merged (their file names are unique UUIDs, so nothing clashes).
    static func prepare(from source: URL, to destination: URL) throws -> Outcome {
        let fm = FileManager.default
        let destinationLayout = destination.appendingPathComponent("layout.json")
        let existing = layoutKind(at: destinationLayout)
        if case .foreign = existing { throw MigrationError.foreignLayoutFile(destinationLayout) }

        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let sourceLayout = source.appendingPathComponent("layout.json")

        var copyLayout = fm.fileExists(atPath: sourceLayout.path)
        if copyLayout, case .menuFold = existing {
            let alert = NSAlert()
            alert.messageText = String(localized: "У цій теці вже є розкладка MenuFold")
            alert.informativeText = String(localized: "Можна почати користуватися нею (наприклад, розкладкою з іншого Mac) або замінити її поточною.")
            alert.addButton(withTitle: String(localized: "Використати наявну"))
            alert.addButton(withTitle: String(localized: "Замінити поточною"))
            alert.addButton(withTitle: String(localized: "Скасувати"))
            switch alert.runModal() {
            case .alertFirstButtonReturn: copyLayout = false
            case .alertSecondButtonReturn: copyLayout = true
            default: return .cancelled
            }
        }

        if copyLayout {
            // Written atomically, so a synced folder never sees a half-written file.
            try Data(contentsOf: sourceLayout).write(to: destinationLayout, options: .atomic)
        }

        let sourceIcons = source.appendingPathComponent("Icons", isDirectory: true)
        let destinationIcons = destination.appendingPathComponent("Icons", isDirectory: true)
        if let names = try? fm.contentsOfDirectory(atPath: sourceIcons.path), !names.isEmpty {
            try fm.createDirectory(at: destinationIcons, withIntermediateDirectories: true)
            for name in names where !name.hasPrefix(".") {
                let to = destinationIcons.appendingPathComponent(name)
                guard !fm.fileExists(atPath: to.path) else { continue }
                try fm.copyItem(at: sourceIcons.appendingPathComponent(name), to: to)
            }
        }
        return .done
    }
}

#Preview {
    DataSettingsView(model: .preview)
        .frame(width: 520, height: 600)
}

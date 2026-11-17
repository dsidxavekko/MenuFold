import AppKit
import MenuFoldCore
import Observation
import SwiftUI

/// Hand-off from a tile's "Гаряча клавіша…" menu item to Settings → Програми: the row of that app
/// or folder is shown (empty) so the shortcut can be recorded right away.
@MainActor
@Observable
final class HotkeyEditRequest {
    static let shared = HotkeyEditRequest()
    var pendingKey: String?
    private init() {}

    static func request(key: String) {
        shared.pendingKey = key
        (NSApp.delegate as? AppDelegate)?.showSettings(tab: .apps)
    }
}

/// Settings → Програми: global shortcuts that launch an app or open a folder from anywhere.
struct AppHotkeysSection: View {
    let model: GridModel
    private let manager = HotKeyManager.shared
    private let request = HotkeyEditRequest.shared

    /// Stored shortcuts, plus the row the tile menu asked for.
    private var keys: [String] {
        var all = Set(model.layout.appHotkeys.keys)
        if let pending = request.pendingKey { all.insert(pending) }
        return all.sorted { name(of: $0).localizedStandardCompare(name(of: $1)) == .orderedAscending }
    }

    var body: some View {
        Section {
            ForEach(keys, id: \.self) { key in
                row(key)
            }
            Menu("Додати сполучення…") {
                Menu("Програма") {
                    ForEach(model.apps.filter { !model.layout.hidden.contains($0.id) }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { app in
                        Button(app.name) { request.pendingKey = AppHotkey.key(appID: app.id) }
                    }
                }
                Menu("Папка") {
                    ForEach(model.visibleFolders) { folder in
                        Button(folder.name) { request.pendingKey = AppHotkey.key(folderID: folder.id) }
                    }
                }
            }
        } header: {
            Label("Гарячі клавіші", systemImage: "keyboard")
        } footer: {
            Text("Сполучення запускає програму або відкриває папку з будь-якої програми. Воно діє, поки працює MenuFold; потрібен ⌘, ⌥ або ⌃ (або F1–F12).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ key: String) -> some View {
        HStack(spacing: 8) {
            icon(of: key)
            Text(name(of: key))
                .lineLimit(1)
            Spacer()
            if manager.conflicts[key] != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(Text("Це сполучення вже зайняте іншою програмою або системою."))
                    .accessibilityLabel(Text("Це сполучення вже зайняте іншою програмою або системою."))
            }
            HotKeyRecorder(hotKey: Binding(
                get: { model.layout.appHotkeys[key].map(HotKey.init) },
                set: { new in
                    model.setHotkey(new?.stored, forKey: key)
                    if request.pendingKey == key { request.pendingKey = nil }
                }
            ))
        }
    }

    private func name(of key: String) -> String {
        if key.hasPrefix("app:") {
            let id = String(key.dropFirst(4))
            return model.app(withID: id)?.name ?? id
        }
        if key.hasPrefix("folder:"), let id = UUID(uuidString: String(key.dropFirst(7))),
           let folder = model.folder(id: id) {
            return folder.name
        }
        return key
    }

    @ViewBuilder
    private func icon(of key: String) -> some View {
        if key.hasPrefix("app:"), let app = model.app(withID: String(key.dropFirst(4))) {
            Image(nsImage: IconCache.shared.icon(for: app))
                .resizable()
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: "folder.fill")
                .frame(width: 24, height: 24)
                .foregroundStyle(.secondary)
        }
    }
}

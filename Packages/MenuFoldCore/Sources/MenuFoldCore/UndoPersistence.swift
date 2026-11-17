import Foundation

/// Undo history that survives a relaunch: the last `limit` undo steps, LZFSE-compressed, in
/// `undo.json` next to layout.json. The file also stores the layout those steps lead to
/// (`current`), so a history that no longer matches the loaded layout (edited by hand or by
/// another version) is ignored instead of undoing into unrelated state.
///
/// Never used for a shared (synced) data folder: undo across a sync would push stale state out.
struct UndoPersistence {
    static let limit = 10

    private struct Payload: Codable {
        var version = 1
        var current: Layout
        var undo: [Layout]
    }

    let url: URL

    init(store: LayoutStore) {
        url = store.fileURL.deletingLastPathComponent().appendingPathComponent("undo.json")
    }

    func save(current: Layout, undo: [Layout]) {
        guard !undo.isEmpty else { remove(); return }
        let payload = Payload(current: current, undo: Array(undo.suffix(Self.limit)))
        guard let json = try? JSONEncoder().encode(payload),
              let packed = try? (json as NSData).compressed(using: .lzfse) as Data else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? packed.write(to: url, options: .atomic)
    }

    /// The saved steps when the file matches `current`; otherwise empty.
    func load(matching current: Layout) -> [Layout] {
        guard let size = LayoutStore.fileSize(at: url), size <= LayoutStore.maxFileSize,
              let packed = try? Data(contentsOf: url), packed.count <= LayoutStore.maxFileSize,
              let json = try? (packed as NSData).decompressed(using: .lzfse) as Data,
              let payload = try? JSONDecoder().decode(Payload.self, from: json),
              payload.version == 1, payload.current == current else { return [] }
        // Steps go through the same validation as layout.json; one that fails ends the history.
        var steps: [Layout] = []
        for step in payload.undo.suffix(Self.limit) {
            guard let valid = try? LayoutStore.validated(step) else { return [] }
            steps.append(valid)
        }
        return steps
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}

extension GridModel {
    /// Writes the undo steps next to layout.json (not for a shared folder or without a store).
    func persistUndo() {
        guard let store = layoutStore, !store.isShared else { return }
        var current = layout
        current.version = Layout.currentVersion
        UndoPersistence(store: store).save(current: current, undo: undoStack)
    }

    /// Restores the steps saved by an earlier launch; called once after a real layout load.
    func restorePersistedUndo() {
        guard let store = layoutStore, !store.isShared else { return }
        var current = layout
        current.version = Layout.currentVersion
        undoStack = UndoPersistence(store: store).load(matching: current)
    }
}

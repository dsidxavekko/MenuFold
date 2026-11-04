import Foundation

/// Loads/saves `Layout` as JSON. Atomic writes; missing file → empty layout.
/// An unreadable/undecodable file is moved aside to `layout.corrupt-<yyyyMMdd-HHmmss>.json`
/// (so the next save can't destroy the user's data) and an empty layout is returned.
public final class LayoutStore: Sendable {
    public let fileURL: URL

    /// ~/Library/Application Support/MenuFold/layout.json
    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MenuFold", isDirectory: true).appendingPathComponent("layout.json")
    }

    public init(fileURL: URL = LayoutStore.defaultURL) {
        self.fileURL = fileURL
    }

    public func load() -> Layout {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return Layout() }
        do {
            let data = try Data(contentsOf: fileURL)
            return try JSONDecoder().decode(Layout.self, from: data)
        } catch {
            NSLog("MenuFold: failed to load layout: \(error.localizedDescription)")
            quarantineCorruptFile()
            return Layout()
        }
    }

    /// Renames the current file to `layout.corrupt-<yyyyMMdd-HHmmss>.json` in the same directory.
    private func quarantineCorruptFile() {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let dir = fileURL.deletingLastPathComponent()
        let stem = fileURL.deletingPathExtension().lastPathComponent + ".corrupt-" + formatter.string(from: Date())
        var dest = dir.appendingPathComponent(stem + ".json")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(stem)-\(n).json")
            n += 1
        }
        do { try FileManager.default.moveItem(at: fileURL, to: dest) } catch {
            NSLog("MenuFold: failed to move corrupt layout aside: \(error.localizedDescription)")
        }
    }

    public func save(_ layout: Layout) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var copy = layout
        copy.version = Layout.currentVersion
        let data = try encoder.encode(copy)
        try data.write(to: fileURL, options: .atomic)
    }
}

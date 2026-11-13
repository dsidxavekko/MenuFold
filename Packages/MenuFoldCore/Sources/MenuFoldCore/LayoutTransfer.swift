import AppKit
import Foundation

/// The file written by "Експортувати розкладку": the layout plus the custom icon pictures it
/// refers to, in one self-contained JSON document, so it can be moved to another Mac.
///
///     { "format": "menufold-layout", "version": 1, "layout": {…}, "icons": { "<file>": "<base64 png>" } }
struct LayoutTransfer: Codable {
    static let formatName = "menufold-layout"
    static let currentVersion = 1

    var format: String
    var version: Int
    var layout: Layout
    /// Icon file name (as in `layout.customIcons`) → PNG bytes (base64 in JSON).
    var icons: [String: Data]

    init(format: String, version: Int, layout: Layout, icons: [String: Data]) {
        self.format = format
        self.version = version
        self.layout = layout
        self.icons = icons
    }

    private enum CodingKeys: String, CodingKey { case format, version, layout, icons }

    /// `icons` may be missing (a file edited by hand, or a layout without custom icons).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(String.self, forKey: .format)
        version = try c.decode(Int.self, forKey: .version)
        layout = try c.decode(Layout.self, forKey: .layout)
        icons = try c.decodeIfPresent([String: Data].self, forKey: .icons) ?? [:]
    }

    /// Builds the document from a layout and the icons folder. Only icons the layout refers to are
    /// included; an entry whose file is gone is dropped from the exported layout too.
    static func make(layout: Layout, iconsDirectory: URL) -> LayoutTransfer {
        var exported = layout
        var icons: [String: Data] = [:]
        for (appID, file) in layout.customIcons {
            guard Layout.isValidIconFileName(file),
                  let data = try? Data(contentsOf: iconsDirectory.appendingPathComponent(file)) else {
                exported.customIcons[appID] = nil
                continue
            }
            icons[file] = data
        }
        exported.version = Layout.currentVersion
        return LayoutTransfer(format: formatName, version: currentVersion, layout: exported, icons: icons)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// Reads and validates an export file: the right format, a version this app understands, and
    /// a layout that passes the same checks as layout.json.
    static func decode(_ data: Data) throws -> LayoutTransfer {
        // An export embeds icons, so it may be larger than layout.json; still refuse absurd files.
        guard data.count <= 256 * 1024 * 1024 else { throw LayoutDataError.damaged }
        // Check the header first, so a random JSON file says "not a MenuFold file", not "damaged".
        struct Header: Decodable { var format: String?; var version: Int? }
        guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
            throw LayoutDataError.notMenuFoldFile
        }
        guard header.format == formatName else { throw LayoutDataError.notMenuFoldFile }
        guard (header.version ?? 0) <= currentVersion else { throw LayoutDataError.newerVersion }
        var transfer: LayoutTransfer
        do {
            transfer = try JSONDecoder().decode(LayoutTransfer.self, from: data)
        } catch {
            throw LayoutDataError.damaged
        }
        transfer.layout = try LayoutStore.validated(transfer.layout)
        return transfer
    }

    /// Writes the icons the layout uses into `directory` under fresh UUID names and returns the
    /// layout with `customIcons` pointing at them. Entries without (valid image) data are dropped.
    /// `written` receives the new files, so a failed import can delete them again.
    func installIcons(into directory: URL, written: inout [URL]) throws -> Layout {
        var result = layout
        result.customIcons = [:]
        var renamed: [String: String] = [:]
        for (appID, file) in layout.customIcons.sorted(by: { $0.key < $1.key }) {
            if let name = renamed[file] {
                result.customIcons[appID] = name
                continue
            }
            // Only real pictures are written: the file may come from anywhere.
            guard let data = icons[file], NSBitmapImageRep(data: data) != nil else { continue }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = UUID().uuidString + ".png"
            let url = directory.appendingPathComponent(name)
            try data.write(to: url, options: .atomic)
            written.append(url)
            renamed[file] = name
            result.customIcons[appID] = name
        }
        return result
    }
}

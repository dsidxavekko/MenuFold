import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

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
    static let maxFileSize = 256 * 1024 * 1024
    /// Import limits for custom icons: how many, bytes each, and pixels on the longer side.
    static let maxIcons = 1000
    static let maxIconBytes = 8 * 1024 * 1024
    static let maxIconPixels = 4096
    /// Imported icons are stored at most this many pixels on the longer side (as `CustomIcons` does).
    static let storedIconPixels = 512

    /// Like `decode(_:)` for a file: its size is checked BEFORE reading, so an absurd file is
    /// refused without loading it. An unreadable file is "not a MenuFold file".
    static func decode(contentsOf url: URL) throws -> LayoutTransfer {
        let data: Data
        do { data = try LayoutStore.readLimited(url, limit: maxFileSize) }
        catch let error as LayoutDataError { throw error }
        catch { throw LayoutDataError.notMenuFoldFile }
        return try decode(data)
    }

    static func decode(_ data: Data) throws -> LayoutTransfer {
        // An export embeds icons, so it may be larger than layout.json; still refuse absurd files.
        guard data.count <= maxFileSize else { throw LayoutDataError.damaged }
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
    /// layout with `customIcons` pointing at them. Entries without a usable image are dropped.
    /// The file may come from anywhere, so every icon is checked (size in bytes and pixels, at
    /// most `maxIcons` of them) and RE-ENCODED as a PNG of at most `storedIconPixels`; the original
    /// bytes are never written. `written` receives the new files, so a failed import can delete them.
    func installIcons(into directory: URL, written: inout [URL]) throws -> Layout {
        var result = layout
        result.customIcons = [:]
        var renamed: [String: String] = [:]
        var installed = 0
        for (appID, file) in layout.customIcons.sorted(by: { $0.key < $1.key }) {
            if let name = renamed[file] {
                result.customIcons[appID] = name
                continue
            }
            guard installed < Self.maxIcons, let data = icons[file],
                  let png = Self.reencodedIcon(data) else { continue }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = UUID().uuidString + ".png"
            let url = directory.appendingPathComponent(name)
            try png.write(to: url, options: .atomic)
            written.append(url)
            installed += 1
            renamed[file] = name
            result.customIcons[appID] = name
        }
        return result
    }

    /// PNG bytes of an imported icon, or nil when it is not an image or exceeds the limits.
    /// The pixel size is read from the header, so a decompression bomb is rejected before decoding.
    static func reencodedIcon(_ data: Data) -> Data? {
        guard !data.isEmpty, data.count <= maxIconBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) >= 1,
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int,
              let h = props[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0, max(w, h) <= maxIconPixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: storedIconPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}

import AppKit
import UniformTypeIdentifiers

/// Turns a file the user picked into a custom app icon: a square PNG in the icons folder.
public enum CustomIconError: Error, LocalizedError, Equatable {
    /// The file is not an image MenuFold can read.
    case unreadableImage

    public var errorDescription: String? {
        switch self {
        case .unreadableImage: L("Цей файл не вдалося прочитати як зображення.")
        }
    }
}

public enum CustomIcons {
    /// Side of the stored PNG, in pixels. Tiles are 64 pt, so this stays sharp at 2× and in drags.
    static let pixelSize = 512

    /// `source` (an image, or any file by its Finder icon) as a square 512 px PNG.
    @MainActor
    public static func pngData(from source: URL) throws -> Data {
        try pngData(for: image(from: source))
    }

    /// The picture to use for `source`: the image itself for image files (PNG, JPEG, HEIC, ICNS,
    /// SVG, …); for anything else, such as another app, the icon Finder shows for it.
    @MainActor
    static func image(from source: URL) throws -> NSImage {
        let type = (try? source.resourceValues(forKeys: [.contentTypeKey]))?.contentType
        if let type, type.conforms(to: .image) {
            guard let image = NSImage(contentsOf: source), image.isValid, image.size.width > 0, image.size.height > 0 else {
                throw CustomIconError.unreadableImage
            }
            return image
        }
        guard FileManager.default.fileExists(atPath: source.path) else { throw CustomIconError.unreadableImage }
        return NSWorkspace.shared.icon(forFile: source.path)
    }

    /// Draws `image` aspect-fit and centred into a transparent square and encodes it as PNG.
    @MainActor
    static func pngData(for image: NSImage) throws -> Data {
        let side = pixelSize
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else {
            throw CustomIconError.unreadableImage
        }
        rep.size = NSSize(width: side, height: side)
        let size = image.size
        let scale = min(CGFloat(side) / size.width, CGFloat(side) / size.height)
        let drawn = NSSize(width: size.width * scale, height: size.height * scale)
        let rect = NSRect(x: (CGFloat(side) - drawn.width) / 2, y: (CGFloat(side) - drawn.height) / 2,
                          width: drawn.width, height: drawn.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CustomIconError.unreadableImage }
        return data
    }
}

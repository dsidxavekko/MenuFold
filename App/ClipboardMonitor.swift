import AppKit
import ImageIO
import MenuFoldCore
import UniformTypeIdentifiers

/// Watches the general pasteboard and feeds `GridModel.clipboard`. Polls `changeCount` (macOS has no
/// pasteboard notification) once a second (and on every panel open, see `refresh()`), only while enabled. Texts a password manager or another
/// app marks as concealed, transient or auto-generated (nspasteboard.org) are never recorded, and the
/// history lives in memory only. A copied picture (no text on the pasteboard) is encoded to PNG and
/// shrunk to a thumbnail off the main thread (`ClipboardImageEncoder`).
@MainActor
final class ClipboardMonitor {
    static let shared = ClipboardMonitor()

    private weak var model: GridModel?
    private var timer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount

    private init() {}

    func attach(to model: GridModel) {
        self.model = model
    }

    /// Starts or stops polling; the history is dropped when stopped (turning the tab off forgets it).
    func setEnabled(_ enabled: Bool) {
        if enabled {
            guard timer == nil else { return }
            lastChangeCount = NSPasteboard.general.changeCount
            // What is on the clipboard now is not recorded: every launch starts with an empty history.
            let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
            timer.tolerance = 0.5
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            model?.clipboard = ClipboardHistory()
        }
    }

    /// Puts an entry back on the pasteboard (the user then pastes it with ⌘V) without recording
    /// the write as a new copy.
    func copy(_ entry: ClipboardEntry) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let image = entry.image {
            pasteboard.setData(image.data, forType: .png)
        } else {
            pasteboard.setString(entry.text, forType: .string)
        }
        lastChangeCount = pasteboard.changeCount
        if let image = entry.image {
            model?.clipboard.add(image: image)
        } else {
            model?.clipboard.add(entry.text)
        }
    }

    /// Catches a copy made within the last polling interval; called when the panel opens.
    func refresh() {
        guard timer != nil else { return }
        poll()
    }

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard ClipboardPolicy.changed(current: pasteboard.changeCount, last: lastChangeCount) else { return }
        lastChangeCount = pasteboard.changeCount
        let types = Set(pasteboard.types ?? [])
        let text = pasteboard.string(forType: .string)
        // Text wins over a picture; a picture is PNG as is, else TIFF (screenshots, most editors).
        let source: Data?
        switch ClipboardPolicy.decide(types: Set(types.map(\.rawValue)), hasText: text != nil) {
        case .skip: return
        case .text:
            if let text { model?.clipboard.add(text) }
            return
        case .image(.png): source = pasteboard.data(forType: .png)
        case .image(.tiff): source = pasteboard.data(forType: .tiff)
        }
        guard let source, ClipboardPolicy.isAcceptableImageSize(source.count, limit: ClipboardImageEncoder.maxSourceBytes) else { return }
        let count = lastChangeCount
        Task { @MainActor [weak self] in
            let image = await Task.detached(priority: .utility) { ClipboardImageEncoder.encode(source) }.value
            // The user copied something else meanwhile: that copy is recorded on its own.
            guard let self, let image, ClipboardPolicy.isStillCurrent(count: count, last: self.lastChangeCount) else { return }
            self.model?.clipboard.add(image: image)
        }
    }
}

/// Turns copied picture data into a `ClipboardImage` (PNG + small thumbnail). Pure ImageIO, so it
/// runs off the main actor.
enum ClipboardImageEncoder {
    /// Raw pasteboard data larger than this is not even decoded (TIFF is uncompressed).
    static let maxSourceBytes = 60_000_000
    static let thumbnailPixels = 120

    static func encode(_ data: Data) -> ClipboardImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              image.width > 0, image.height > 0 else { return nil }
        // Already PNG: keep the bytes untouched.
        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        guard let png = isPNG ? data : pngData(image) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixels,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let thumbData = pngData(thumb) else { return nil }
        return ClipboardImage(data: png, thumbnail: thumbData, width: image.width, height: image.height)
    }

    private static func pngData(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? out as Data : nil
    }
}

import AppKit
import MenuFoldCore
import Observation
import SwiftUI

/// "Документи" section with `model.fileResults`, placed by GridView after the System Settings panes
/// while searching. Each tile has `.id(GridModel.fileSelectionID(path))`, so the keyboard selection
/// and `scrollTo` treat a file like any other tile. Draws nothing when no file matched.
struct FileResultsSection: View {
    @Bindable var model: GridModel
    /// Rows to draw instead of `model.fileResults`. Previews only: a preview model has no Spotlight
    /// provider, so it could never fill the section on its own.
    var items: [FileItem]? = nil

    private var files: [FileItem] { items ?? model.fileResults }

    var body: some View {
        let files = files
        if !files.isEmpty {
            let columns = Array(
                repeating: SwiftUI.GridItem(.flexible(), spacing: 4),
                count: GridMetrics.columns
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(String(localized: "Документи"))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(files) { file in
                        FileResultTile(
                            item: file,
                            isSelected: model.selectedItemID == GridModel.fileSelectionID(file.id)
                        ) {
                            model.openFile(file)
                        }
                        .id(GridModel.fileSelectionID(file.id))
                        .contextMenu {
                            Button(String(localized: "Відкрити")) { model.openFile(file) }
                            Button(String(localized: "Показати у Finder")) { model.revealFile(file) }
                            Button(String(localized: "Копіювати шлях")) { Self.copyPath(of: file) }
                        }
                    }
                }
            }
            .padding(.top, 8)
        }
    }

    /// Full path, not the shortened one the row shows: a copied path is pasted into a terminal or a
    /// dialog, where "~" is not expanded.
    private static func copyPath(of file: FileItem) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(file.url.path, forType: .string)
    }
}

/// A file or document as a tile, laid out like `SettingsPaneTile`: the Finder icon on the square the
/// app icons take, the name on two lines and, smaller, the folder it lives in, so two files with the
/// same name can be told apart.
private struct FileResultTile: View {
    let item: FileItem
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.menuFoldReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                FileArtwork(item: item, isHovered: isHovered, isSelected: isSelected)
                Text(item.name)
                    .font(Theme.labelFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(height: 34, alignment: .top)
                Text(item.displayPath)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            }
            .padding(6)
            .frame(width: GridMetrics.tileWidth)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Theme.snappy, value: isHovered)
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: isSelected)
        .help(item.url.path)
        // One element: the name, then the folder it is in (two files can share a name).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name)
        .accessibilityValue(item.displayPath)
        .accessibilityHint(String(localized: "Відкриває файл"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The file's own Finder icon, from `FileIconCache`; a document symbol stands in until it is loaded,
/// on exactly the square the icon takes so the row never jumps.
private struct FileArtwork: View {
    let item: FileItem
    let isHovered: Bool
    let isSelected: Bool

    @Environment(\.isTilePressed) private var isPressed
    @Environment(\.menuFoldReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if isPressed { return Theme.pressScale }
        if isHovered || isSelected { return Theme.hoverScale }
        return 1
    }

    var body: some View {
        let size = GridMetrics.iconSize
        let shape = RoundedRectangle(cornerRadius: GridMetrics.tileCorner, style: .continuous)
        Group {
            if let icon = FileIconCache.shared.cachedIcon(for: item.url) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                Image(systemName: "doc")
                    .font(.system(size: size * 0.45, weight: .regular))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: size, height: size)
                    .glassEffect(.regular.tint(Color.gray.opacity(0.35)), in: shape)
            }
        }
        .overlay {
            if isSelected { SelectionRing(cornerRadius: GridMetrics.tileCorner) }
        }
        .scaleEffect(scale)
        .animation(Theme.snappy, value: isPressed)
        .accessibilityHidden(true)
    }
}

// MARK: - Icons

/// Finder icons for the "Документи" rows.
///
/// `NSWorkspace.icon(forFile:)` reads the disk, so a tile never calls it from `body`: it draws
/// `cachedIcon` or the placeholder, and the grid calls `warm` for the rows of a fresh answer. The
/// icons are loaded in small batches on the main actor with a yield in between, so a keystroke, a
/// scroll or the reveal animation is never queued behind eight disk reads.
@MainActor
@Observable
final class FileIconCache {
    static let shared = FileIconCache()

    /// Grows after every loaded batch (and on `removeAll`). `cachedIcon` reads it, which is what
    /// makes a tile's body re-evaluate once the icon is in the cache.
    private(set) var version = 0

    /// Icons per yield. Small on purpose: the lookups are synchronous, so the main thread is handed
    /// back often and a cold section fills in progressively.
    private static let batchSize = 8

    // The cache and the queue are not view state: touching them must never invalidate a body.
    @ObservationIgnored private let cache = NSCache<NSURL, NSImage>()
    @ObservationIgnored private var pending: [URL] = []
    @ObservationIgnored private var queued: Set<NSURL> = []
    @ObservationIgnored private var isWarming = false

    private init() {
        // A file search never revisits a path often; a few hundred rows cover a session's queries.
        cache.countLimit = 400
    }

    /// The icon if it is already in memory, otherwise nil. Never does any work, so a tile's body may
    /// call it. Reading `version` is deliberate: it subscribes the body to icon arrivals.
    func cachedIcon(for url: URL) -> NSImage? {
        _ = version
        return cache.object(forKey: url as NSURL)
    }

    /// Queues the icons of `files` that are not loaded yet. Cheap to call repeatedly (duplicates are
    /// dropped), so the grid can call it for every answer.
    func warm(_ files: [FileItem]) {
        for file in files {
            let key = file.url as NSURL
            guard cache.object(forKey: key) == nil, !queued.contains(key) else { continue }
            pending.append(file.url)
            queued.insert(key)
        }
        guard !pending.isEmpty, !isWarming else { return }
        isWarming = true
        Task { await drain() }
    }

    /// Drops everything, the queue included: called when the panel's views are unloaded.
    func removeAll() {
        cache.removeAllObjects()
        pending.removeAll()
        queued.removeAll()
        version += 1
    }

    private func drain() async {
        while !pending.isEmpty {
            let batch = Array(pending.prefix(Self.batchSize))
            pending.removeFirst(batch.count)
            for url in batch {
                let key = url as NSURL
                let image = NSWorkspace.shared.icon(forFile: url.path)
                // 32 pt by default; ask for 128 pt so the 64 pt tile gets the sharpest representation.
                image.size = NSSize(width: 128, height: 128)
                cache.setObject(image, forKey: key)
                queued.remove(key)
            }
            // Let SwiftUI, the run loop and pending input run before the next batch.
            await Task.yield()
            // Only now tell the views: they re-read the cache once per batch, not once per icon.
            version += 1
        }
        isWarming = false
    }
}

#Preview {
    VStack(alignment: .leading) {
        FileResultsSection(model: .preview, items: [
            FileItem(url: URL(fileURLWithPath: "/Users/me/Documents/Звіт.pdf")),
            FileItem(url: URL(fileURLWithPath: "/Users/me/Documents/Договір 2024.docx")),
            FileItem(url: URL(fileURLWithPath: "/Users/me/Desktop/notes.txt")),
        ])
    }
    .padding()
    .frame(width: GridMetrics.panelWidth)
}

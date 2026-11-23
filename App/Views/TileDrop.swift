import AppKit
import MenuFoldCore
import SwiftUI
import UniformTypeIdentifiers

// Drops onto a grid tile on "Все": the middle of the tile keeps the folder behaviour (app onto app
// makes a folder, app onto folder adds it), the left/right edges reorder ("Все" switches to the
// user's order through `GridModel.moveItem`). One delegate decides both, from the pointer position
// inside the tile, so the two gestures never fight over the same drop.

/// Where over a tile a drag currently is.
enum TileDropZone: Equatable {
    /// Insert the dragged item before (left of) the tile.
    case before
    /// Folder drop (make a folder / add to the folder).
    case center
    /// Insert the dragged item after (right of) the tile.
    case after
}

/// Geometry and look of the reorder drop.
enum TileReorder {
    /// Share of the tile's width on each side that means "insert here" instead of "make a folder".
    static let edgeFraction: CGFloat = 0.22
    /// The insertion caret (a vertical accent capsule in the gap next to the tile).
    static let caretWidth: CGFloat = 3
    static let caretWidthHighContrast: CGFloat = 5
    @MainActor static var caretHeight: CGFloat { GridMetrics.iconSize + 8 }
    /// Pushes the caret into the gap between two tiles (half the column spacing plus a bit).
    static let caretOutset: CGFloat = 3

    /// The zone for a pointer at `x` in a tile `width` wide. With `allowsReorder == false` only
    /// the center exists; with `allowsCenter == false` the nearer edge wins.
    static func zone(x: CGFloat, width: CGFloat, allowsCenter: Bool, allowsReorder: Bool) -> TileDropZone? {
        guard width > 0 else { return allowsCenter ? .center : nil }
        if allowsReorder {
            let edge = width * edgeFraction
            if x < edge { return .before }
            if x > width - edge { return .after }
            if !allowsCenter { return x < width / 2 ? .before : .after }
        }
        return allowsCenter ? .center : nil
    }
}

/// What a drag over a tile carries.
private enum TileDragKind {
    case app(String?)      // a MenuFold app drag (id from the shared session; nil = foreign pasteboard)
    case folder(String)    // a MenuFold folder drag (`GridItem.id`), reorder only
    case file              // files from outside (Finder, Desktop): "open with this app"
}

/// Probe state of a file drag over one tile: whether the app declares it can open the files.
/// Lives in the tile (not in the delegate, which SwiftUI rebuilds on every render).
@MainActor
final class FileDropProbe {
    var supported: Bool?
    var generation = 0
    func reset() { supported = nil; generation += 1 }
}

/// Spring-loaded folders: an app held over a folder tile for `Theme.springLoadDelay` opens it.
/// One drag has one target at a time, so a single shared timer is enough.
@MainActor
enum SpringLoad {
    private static var timer: Timer?

    /// The action is `@Sendable` because it is handed to the timer's block, which is one; it stays on
    /// the main actor (a `Timer` fires on the main run loop and the block calls it there).
    static func schedule(_ action: @escaping @MainActor @Sendable () -> Void) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: Theme.springLoadDelay, repeats: false) { _ in
            MainActor.assumeIsolated {
                timer = nil
                action()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

/// Drop delegate for a grid tile; accepts MenuFold app and folder drags (private types) and, when the
/// tile asks for it, files from outside.
struct TileDropDelegate: DropDelegate {
    /// The tile takes folder drops in its center.
    var allowsCenter: Bool
    /// The tile takes reorder drops on its edges (the "Все" tab, no search, no open folder).
    var allowsReorder: Bool
    /// Width of the tile, to split it into zones (`DropInfo.location` is in the tile's space).
    var width: CGFloat
    /// Validates a dropped bundle ID against the live catalog.
    var isKnownApp: (String) -> Bool
    /// Whether this dragged app may be reordered here (it is a top-level "Все" item, not the tile).
    var canReorder: (String) -> Bool
    var setZone: (TileDropZone?) -> Void
    var performCenter: (String) -> Bool
    var performReorder: (_ appID: String, _ after: Bool) -> Bool
    /// Folder drags: this tile's own `GridItem.id` and the reorder (nil = folders can't land here).
    var ownItemID: String?
    var performItemReorder: ((_ itemID: String, _ after: Bool) -> Bool)?
    /// Files from outside: whether the app can open them, the highlight, and the open itself.
    var supportsFiles: (([URL]) -> Bool)?
    var openFiles: (([URL]) -> Void)?
    var setFileTarget: ((Bool) -> Void)?
    var probe: FileDropProbe?
    /// An app held over the center for `Theme.springLoadDelay` (opens a folder).
    var springLoad: (@MainActor @Sendable () -> Void)?

    private static let acceptedTypes: [UTType] = [.menuFoldAppID, .menuFoldFolderID, .fileURL]

    func validateDrop(info: DropInfo) -> Bool {
        if info.hasItemsConforming(to: [.menuFoldAppID]) { return allowsCenter || allowsReorder }
        if info.hasItemsConforming(to: [.menuFoldFolderID]) { return allowsReorder && performItemReorder != nil }
        return supportsFiles != nil && info.hasItemsConforming(to: [.fileURL])
    }

    @MainActor
    private func kind(of info: DropInfo) -> TileDragKind {
        let session = AppDragSession.shared
        if let folder = session.folderItemID { return .folder(folder) }
        if let id = session.appID { return .app(id) }
        if info.hasItemsConforming(to: [.menuFoldAppID]) { return .app(nil) }
        return .file
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated {
            switch kind(of: info) {
            case .file:
                startProbe(info)
            default:
                DragActivity.shared.setActive(true)
            }
        }
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let zone = update(info)
        return MainActor.assumeIsolated {
            switch kind(of: info) {
            case .file:
                return DropProposal(operation: probe?.supported == true ? .copy : .forbidden)
            default:
                return DropProposal(operation: zone == nil ? .forbidden : .move)
            }
        }
    }

    func dropExited(info: DropInfo) {
        setZone(nil)
        setFileTarget?(false)
        MainActor.assumeIsolated {
            SpringLoad.cancel()
            probe?.reset()
            DragActivity.shared.setActive(false)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = zone(for: info)
        setZone(nil)
        setFileTarget?(false)
        MainActor.assumeIsolated {
            SpringLoad.cancel()
            DragActivity.shared.setActive(false)
        }
        switch MainActor.assumeIsolated({ kind(of: info) }) {
        case .file:
            return performFileDrop(info)
        case .folder(let itemID):
            guard let zone, zone != .center, let performItemReorder else { return false }
            return MainActor.assumeIsolated { performItemReorder(itemID, zone == .after) }
        case .app(let sessionID):
            guard let zone else { return false }
            // The source is in this process: read the ID synchronously from the shared session.
            if let id = sessionID { return MainActor.assumeIsolated { apply(id, zone: zone) } }
            // Fallback: the pasteboard, asynchronously. Re-validate against the live state then, like
            // `AppDropDelegate` (the world may have changed in between).
            guard let provider = info.itemProviders(for: [.menuFoldAppID]).first else { return false }
            let delegate = self
            provider.loadDataRepresentation(forTypeIdentifier: UTType.menuFoldAppID.identifier) { data, _ in
                guard let data, let id = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard !AppDragSession.shared.isDragging else { return }
                        _ = delegate.apply(id, zone: zone)
                    }
                }
            }
            return true
        }
    }

    /// Refreshes the zone state and the spring-loading timer; returns the zone.
    @discardableResult
    private func update(_ info: DropInfo) -> TileDropZone? {
        let zone = zone(for: info)
        setZone(zone)
        MainActor.assumeIsolated {
            if case .app = kind(of: info), zone == .center, let springLoad {
                SpringLoad.schedule(springLoad)
            } else {
                SpringLoad.cancel()
            }
        }
        return zone
    }

    @MainActor
    private func apply(_ id: String, zone: TileDropZone) -> Bool {
        guard isKnownApp(id) else { return false }
        switch zone {
        case .center:
            return allowsCenter && performCenter(id)
        case .before, .after:
            return allowsReorder && canReorder(id) && performReorder(id, zone == .after)
        }
    }

    /// The zone under the pointer for what is being dragged right now; reorder only for items that
    /// may move here. Files have no zone (the whole tile is the target).
    private func zone(for info: DropInfo) -> TileDropZone? {
        MainActor.assumeIsolated {
            switch kind(of: info) {
            case .file:
                return nil
            case .folder(let itemID):
                let ok = allowsReorder && performItemReorder != nil && itemID != ownItemID
                return TileReorder.zone(x: info.location.x, width: width, allowsCenter: false, allowsReorder: ok)
            case .app(let id):
                let reorder = allowsReorder && (id.map(canReorder) ?? true)
                return TileReorder.zone(x: info.location.x, width: width,
                                        allowsCenter: allowsCenter, allowsReorder: reorder)
            }
        }
    }

    // MARK: Files

    @MainActor
    private func startProbe(_ info: DropInfo) {
        guard let supportsFiles, let probe else { return }
        probe.reset()
        let generation = probe.generation
        let setFileTarget = setFileTarget
        Self.loadFileURLs(from: info.itemProviders(for: [.fileURL])) { urls in
            guard probe.generation == generation else { return }
            let ok = !urls.isEmpty && supportsFiles(urls)
            probe.supported = ok
            setFileTarget?(ok)
        }
    }

    private func performFileDrop(_ info: DropInfo) -> Bool {
        guard let openFiles, MainActor.assumeIsolated({ probe?.supported == true }) else { return false }
        Self.loadFileURLs(from: info.itemProviders(for: [.fileURL])) { urls in
            guard !urls.isEmpty else { return }
            openFiles(urls)
        }
        return true
    }

    /// Loads every provider's file URL, then calls back on the main actor (in the providers' order).
    private static func loadFileURLs(from providers: [NSItemProvider],
                                     completion: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        // `nonisolated(unsafe)`: `urls` is guarded by `lock` on every writer, and the reader runs in
        // `group.notify`, i.e. only after all the providers left the group.
        nonisolated(unsafe) var urls = [Int: URL]()
        let lock = NSLock()
        for (index, provider) in providers.enumerated() {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls[index] = url; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let ordered = urls.sorted { $0.key < $1.key }.map(\.value)
            MainActor.assumeIsolated { completion(ordered) }
        }
    }
}

/// Applies `TileDropDelegate` to a tile and owns its file-probe state.
private struct TileDropModifier: ViewModifier {
    var allowsCenter: Bool
    var allowsReorder: Bool
    var width: CGFloat
    var isKnownApp: (String) -> Bool
    var canReorder: (String) -> Bool
    var zone: (TileDropZone?) -> Void
    var performCenter: (String) -> Bool
    var performReorder: (String, Bool) -> Bool
    var ownItemID: String?
    var performItemReorder: ((String, Bool) -> Bool)?
    var supportsFiles: (([URL]) -> Bool)?
    var openFiles: (([URL]) -> Void)?
    var fileTarget: ((Bool) -> Void)?
    var springLoad: (@MainActor @Sendable () -> Void)?

    @State private var probe = FileDropProbe()

    func body(content: Content) -> some View {
        content.onDrop(of: [.menuFoldAppID, .menuFoldFolderID, .fileURL], delegate: TileDropDelegate(
            allowsCenter: allowsCenter, allowsReorder: allowsReorder, width: width,
            isKnownApp: isKnownApp, canReorder: canReorder, setZone: zone,
            performCenter: performCenter, performReorder: performReorder,
            ownItemID: ownItemID, performItemReorder: performItemReorder,
            supportsFiles: supportsFiles, openFiles: openFiles, setFileTarget: fileTarget,
            probe: probe, springLoad: springLoad))
    }
}

extension View {
    /// Folder drops in the tile's center, reorder drops on its edges (see `TileDropDelegate`).
    /// The optional parameters add folder-drag reorder (`ownItemID` + `performItemReorder`), "open
    /// these files with this app" (`supportsFiles`, `openFiles`, `fileTarget`) and spring-loading.
    @MainActor
    func tileDropDestination(
        allowsCenter: Bool,
        allowsReorder: Bool,
        width: CGFloat? = nil,
        isKnownApp: @escaping (String) -> Bool,
        canReorder: @escaping (String) -> Bool,
        zone: @escaping (TileDropZone?) -> Void,
        performCenter: @escaping (String) -> Bool,
        performReorder: @escaping (String, Bool) -> Bool,
        ownItemID: String? = nil,
        performItemReorder: ((String, Bool) -> Bool)? = nil,
        supportsFiles: (([URL]) -> Bool)? = nil,
        openFiles: (([URL]) -> Void)? = nil,
        fileTarget: ((Bool) -> Void)? = nil,
        springLoad: (@MainActor @Sendable () -> Void)? = nil
    ) -> some View {
        modifier(TileDropModifier(
            allowsCenter: allowsCenter, allowsReorder: allowsReorder, width: width ?? GridMetrics.tileWidth,
            isKnownApp: isKnownApp, canReorder: canReorder, zone: zone,
            performCenter: performCenter, performReorder: performReorder,
            ownItemID: ownItemID, performItemReorder: performItemReorder,
            supportsFiles: supportsFiles, openFiles: openFiles, fileTarget: fileTarget,
            springLoad: springLoad))
    }

    /// Draws the insertion caret on the side `zone` points at (nothing for `.center`/nil).
    func reorderCaret(_ zone: TileDropZone?) -> some View {
        modifier(ReorderCaretModifier(zone: zone))
    }
}

/// Vertical accent capsule in the gap next to a tile while a reorder drop targets that side.
private struct ReorderCaretModifier: ViewModifier {
    let zone: TileDropZone?
    @Environment(\.menuFoldReduceMotion) private var reduceMotion
    @Environment(\.menuFoldContrast) private var contrast

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .topLeading) { caret(visible: zone == .before, leading: true) }
            .overlay(alignment: .topTrailing) { caret(visible: zone == .after, leading: false) }
            .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: zone)
    }

    @ViewBuilder
    private func caret(visible: Bool, leading: Bool) -> some View {
        if visible {
            Capsule()
                .fill(Color.accentColor)
                .frame(width: contrast == .increased ? TileReorder.caretWidthHighContrast : TileReorder.caretWidth,
                       height: TileReorder.caretHeight)
                .overlay {
                    if contrast == .increased {
                        Capsule().strokeBorder(Color.primary.opacity(0.6), lineWidth: 0.75)
                    }
                }
                // Centered on the icon (the tile has 6 pt padding above the 64 pt icon).
                .padding(.top, 6 + (GridMetrics.iconSize - TileReorder.caretHeight) / 2)
                .offset(x: leading ? -TileReorder.caretOutset : TileReorder.caretOutset)
                // Increase Contrast: a thicker caret with a stronger glow and a hairline outline.
                .shadow(color: Color.accentColor.opacity(contrast == .increased ? 0.9 : 0.4),
                        radius: contrast == .increased ? 4 : 3)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .transition(reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .center).combined(with: .opacity))
        }
    }
}

/// Reorder helpers shared by app and folder tiles (drops and the "Пересунути…" menu items).
@MainActor
enum TileReorderSupport {
    /// The app is its own item on "Все" right now (not inside a folder), so it can be moved.
    static func isTopLevel(appID: String, in model: GridModel) -> Bool {
        let id = "app:" + appID
        return model.visibleItems.contains { $0.id == id }
    }

    /// Drop of a dragged app beside the tile `targetID`.
    static func move(appID: String, relativeTo targetID: String, after: Bool,
                     model: GridModel, reduceMotion: Bool) -> Bool {
        let itemID = "app:" + appID
        guard itemID != targetID else { return false }
        withAnimation(reduceMotion ? Theme.crossfade : Theme.content) {
            model.moveItem(itemID, relativeTo: targetID, after: after)
        }
        return true
    }

    /// Drop of a dragged folder (`GridItem.id`) beside the tile `targetID`.
    static func moveItem(_ itemID: String, relativeTo targetID: String, after: Bool,
                         model: GridModel, reduceMotion: Bool) -> Bool {
        guard itemID != targetID else { return false }
        withAnimation(Theme.motion(Theme.content, reduceMotion: reduceMotion)) {
            model.moveItem(itemID, relativeTo: targetID, after: after)
        }
        return true
    }

    /// The neighbour of `itemID` on "Все" in `direction` (-1 left, +1 right), if any.
    static func neighbour(of itemID: String, by direction: Int, in model: GridModel) -> String? {
        let items = model.visibleItems
        guard let index = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let target = index + direction
        guard items.indices.contains(target) else { return nil }
        return items[target].id
    }

    /// Moves `itemID` one place left/right on "Все" (switches it to the user's order).
    static func step(_ itemID: String, by direction: Int, in model: GridModel) {
        guard let target = neighbour(of: itemID, by: direction, in: model) else { return }
        withAnimation(ThemeOverrides.reduceMotion ? Theme.crossfade : Theme.content) {
            model.moveItem(itemID, relativeTo: target, after: direction > 0)
        }
    }
}

/// "Пересунути ліворуч/праворуч" for a top-level tile on "Все", and "Сортувати за алфавітом" once
/// the user's order is in use. The menu way to reorder (dragging works too).
struct ItemMoveMenuItems: View {
    let itemID: String
    let model: GridModel

    var body: some View {
        Button("Пересунути ліворуч") { TileReorderSupport.step(itemID, by: -1, in: model) }
            .disabled(TileReorderSupport.neighbour(of: itemID, by: -1, in: model) == nil)
        Button("Пересунути праворуч") { TileReorderSupport.step(itemID, by: 1, in: model) }
            .disabled(TileReorderSupport.neighbour(of: itemID, by: 1, in: model) == nil)
        if model.hasManualOrder {
            Button("Сортувати за алфавітом") {
                withAnimation(ThemeOverrides.reduceMotion ? Theme.crossfade : Theme.content) {
                    model.resetManualOrder()
                }
            }
        }
    }
}

/// Dropping files on an app tile: "open these with this app", only for types the app declares.
@MainActor
enum TileFileOpening {
    /// At most this many files are checked (and opened) per drop; LaunchServices queries are not free.
    static let maxFiles = 20
    private static let executableExtensions: Set<String> = [
        "command", "terminal", "sh", "bash", "zsh", "csh", "tcsh", "ksh", "scpt", "scptd", "applescript",
        "workflow", "action", "app", "pkg", "mpkg", "jar", "py", "pl", "rb", "tool", "osax", "dmg",
    ]
    /// Results for the current drag session (cleared after a drop is opened); bounded.
    private static var cache: [String: Bool] = [:]

    /// Files that run code when opened: never opened by a drop, whatever the app claims.
    static func isExecutable(_ url: URL) -> Bool {
        if executableExtensions.contains(url.pathExtension.lowercased()) { return true }
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            if type.conforms(to: .executable) || type.conforms(to: .unixExecutable)
                || type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return true }
        }
        return false
    }

    /// Every file is one the app says it can open (and none is the app itself or something executable).
    static func canOpen(_ urls: [URL], with app: AppEntry) -> Bool {
        guard !urls.isEmpty, urls.count <= maxFiles else { return false }
        let appPath = app.url.resolvingSymlinksInPath().path
        return urls.allSatisfy { url in
            let key = appPath + "\n" + url.path
            if let hit = cache[key] { return hit }
            let ok: Bool
            if url.resolvingSymlinksInPath().path == appPath || isExecutable(url) {
                ok = false
            } else {
                ok = NSWorkspace.shared.urlsForApplications(toOpen: url).contains {
                    $0.resolvingSymlinksInPath().path == appPath
                }
            }
            if cache.count > 200 { cache.removeAll() }
            cache[key] = ok
            return ok
        }
    }

    static func open(_ urls: [URL], with app: AppEntry, model: GridModel) {
        guard canOpen(urls, with: app) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open(urls, withApplicationAt: app.url, configuration: config) { _, error in
            guard let error else { return }
            NSLog("%@", "MenuFold: failed to open files with \(app.url.path): \(error.localizedDescription)")
        }
        cache.removeAll()
        model.onLaunched?()
    }
}

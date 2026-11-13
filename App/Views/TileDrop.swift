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

/// Drop delegate for a grid tile; accepts only MenuFold app drags (the private type).
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

    func validateDrop(info: DropInfo) -> Bool {
        (allowsCenter || allowsReorder) && info.hasItemsConforming(to: [.menuFoldAppID])
    }

    func dropEntered(info: DropInfo) {
        MainActor.assumeIsolated { DragActivity.shared.setActive(true) }
        setZone(zone(for: info))
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let zone = zone(for: info)
        setZone(zone)
        return DropProposal(operation: zone == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        setZone(nil)
        MainActor.assumeIsolated { DragActivity.shared.setActive(false) }
    }

    func performDrop(info: DropInfo) -> Bool {
        let zone = zone(for: info)
        setZone(nil)
        MainActor.assumeIsolated { DragActivity.shared.setActive(false) }
        guard let zone else { return false }
        // The source is in this process: read the ID synchronously from the shared session.
        if let id = MainActor.assumeIsolated({ AppDragSession.shared.appID }) {
            return MainActor.assumeIsolated { apply(id, zone: zone) }
        }
        // Fallback: the pasteboard, asynchronously. Re-validate against the live state then, like
        // `AppDropDelegate` (the world may have changed in between).
        guard let provider = info.itemProviders(for: [.menuFoldAppID]).first else { return false }
        let delegate = self
        provider.loadDataRepresentation(forTypeIdentifier: UTType.menuFoldAppID.identifier) { data, _ in
            guard let data, let id = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard AppDragSession.shared.appID == nil else { return }
                    _ = delegate.apply(id, zone: zone)
                }
            }
        }
        return true
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

    /// The zone under the pointer for the app being dragged right now; reorder only for apps that
    /// may move here.
    private func zone(for info: DropInfo) -> TileDropZone? {
        let reorder = allowsReorder && MainActor.assumeIsolated {
            AppDragSession.shared.appID.map(canReorder) ?? true
        }
        return TileReorder.zone(x: info.location.x, width: width,
                                allowsCenter: allowsCenter, allowsReorder: reorder)
    }
}

extension View {
    /// Folder drops in the tile's center, reorder drops on its edges (see `TileDropDelegate`).
    @MainActor
    func tileDropDestination(
        allowsCenter: Bool,
        allowsReorder: Bool,
        width: CGFloat? = nil,
        isKnownApp: @escaping (String) -> Bool,
        canReorder: @escaping (String) -> Bool,
        zone: @escaping (TileDropZone?) -> Void,
        performCenter: @escaping (String) -> Bool,
        performReorder: @escaping (String, Bool) -> Bool
    ) -> some View {
        onDrop(of: [.menuFoldAppID], delegate: TileDropDelegate(
            allowsCenter: allowsCenter, allowsReorder: allowsReorder, width: width ?? GridMetrics.tileWidth,
            isKnownApp: isKnownApp, canReorder: canReorder, setZone: zone,
            performCenter: performCenter, performReorder: performReorder))
    }

    /// Draws the insertion caret on the side `zone` points at (nothing for `.center`/nil).
    func reorderCaret(_ zone: TileDropZone?) -> some View {
        modifier(ReorderCaretModifier(zone: zone))
    }
}

/// Vertical accent capsule in the gap next to a tile while a reorder drop targets that side.
private struct ReorderCaretModifier: ViewModifier {
    let zone: TileDropZone?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .frame(width: TileReorder.caretWidth, height: TileReorder.caretHeight)
                // Centered on the icon (the tile has 6 pt padding above the 64 pt icon).
                .padding(.top, 6 + (GridMetrics.iconSize - TileReorder.caretHeight) / 2)
                .offset(x: leading ? -TileReorder.caretOutset : TileReorder.caretOutset)
                .shadow(color: Color.accentColor.opacity(0.4), radius: 3)
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
        withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Theme.crossfade : Theme.content) {
            model.moveItem(itemID, relativeTo: target, after: direction > 0)
        }
    }
}

/// "Пересунути ліворуч/праворуч" for a top-level tile on "Все", and "Сортувати за алфавітом" once
/// the user's order is in use. The menu way to reorder (folders are not drag sources).
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
                withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Theme.crossfade : Theme.content) {
                    model.resetManualOrder()
                }
            }
        }
    }
}

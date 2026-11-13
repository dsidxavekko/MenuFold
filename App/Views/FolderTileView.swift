import AppKit
import MenuFoldCore
import SwiftUI

/// Small tinted Liquid Glass rounded square with a 3×3 mini-icon grid (or an SF Symbol).
/// `isExpanded` (drop targeting) spreads the mini-grid slightly, as if the folder opens up.
struct FolderArtwork: View {
    let folder: Folder
    let apps: [AppEntry]
    var size: CGFloat = GridMetrics.iconSize
    var isExpanded: Bool = false

    var body: some View {
        let radius = size * 0.23
        ZStack {
            if let symbol = folder.symbol {
                FolderSymbolImage(symbol: symbol, size: size * 0.42, color: folder.color.color)
                    .scaleEffect(isExpanded ? 1.1 : 1)
            } else {
                miniGrid
            }
        }
        .frame(width: size, height: size)
        .glassEffect(
            .regular.tint(folder.color.color.opacity(isExpanded ? 0.45 : 0.3)),
            in: .rect(cornerRadius: radius, style: .continuous)
        )
    }

    private var miniGrid: some View {
        // Expanded: smaller inset, larger gaps; cell size stays the same, so the icons spread out.
        let inset = size * (isExpanded ? 0.09 : 0.12)
        let spacing = size * (isExpanded ? 0.08 : 0.05)
        let cell = (size - size * 0.12 * 2 - size * 0.05 * 2) / 3
        let shown = Array(apps.prefix(9))
        return VStack(spacing: spacing) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: spacing) {
                    ForEach(0..<3, id: \.self) { col in
                        let index = row * 3 + col
                        if index < shown.count {
                            Image(nsImage: IconCache.shared.icon(for: shown[index]))
                                .resizable()
                                .interpolation(.high)
                                .frame(width: cell, height: cell)
                        } else {
                            Color.clear.frame(width: cell, height: cell)
                        }
                    }
                }
            }
        }
        .padding(inset)
    }
}

/// Folder tile in the main grid: click opens it, accepts app drops, folder context menu.
struct FolderTileView: View {
    let folder: Folder
    let apps: [AppEntry]
    @Bindable var model: GridModel
    var namespace: Namespace.ID?
    var acceptsDrops: Bool = true
    /// Accept reorder drops on the tile's left/right edges ("Все" with no search).
    var acceptsReorder: Bool = false

    @State private var isHovered = false
    /// The part of the tile a drag is over: center = add to the folder, edges = reorder.
    @State private var dropZone: TileDropZone?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isTargeted: Bool { dropZone == .center }
    private var itemID: String { MenuFoldCore.GridItem.folder(folder, apps: apps).id }

    private var isOpen: Bool { model.openFolderID == folder.id }
    /// Keyboard selection (`GridItem` id "folder:…").
    private var isSelected: Bool {
        model.selectedItemID == MenuFoldCore.GridItem.folder(folder, apps: apps).id
    }
    /// Drops into Finder folders are virtual (files are not moved).
    private var canAcceptDrops: Bool { acceptsDrops }

    var body: some View {
        // Read the preference in `body` so toggling it in Settings re-renders the tile.
        let showsCount = AppPreferences.shared.showsFolderCounts && !apps.isEmpty
        Button {
            withAnimation(Theme.morph) {
                model.openFolderID = folder.id
            }
        } label: {
            VStack(spacing: 6) {
                Group {
                    if isOpen {
                        // The overlay owns the matched geometry while open.
                        Color.clear.frame(width: GridMetrics.iconSize, height: GridMetrics.iconSize)
                    } else {
                        FolderTileArtwork(
                            folder: folder,
                            apps: apps,
                            namespace: namespace,
                            isHovered: isHovered,
                            isSelected: isSelected,
                            isTargeted: isTargeted,
                            count: showsCount ? apps.count : nil
                        )
                    }
                }
                Text(folder.name)
                    .font(Theme.labelFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(height: 34, alignment: .top)
                    .opacity(isOpen ? 0 : 1)
            }
            .padding(6)
            .frame(width: GridMetrics.tileWidth)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovered = $0 }
        .animation(Theme.snappy, value: isHovered)
        .animation(Theme.snappy, value: isTargeted)
        .animation(Theme.snappy, value: isSelected)
        .reorderCaret(dropZone)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityValue(String(localized: "Програм: \(apps.count)"))
        .help(folder.isFinder ? String(localized: "\(folder.name) — папка з Finder") : folder.name)
        .accessibilityLabel(folder.isFinder ? String(localized: "Папка \(folder.name), з Finder") : String(localized: "Папка \(folder.name)"))
        .tileDropDestination(
            allowsCenter: canAcceptDrops,
            allowsReorder: acceptsReorder,
            isKnownApp: { _ in true },
            canReorder: { id in TileReorderSupport.isTopLevel(appID: id, in: model) },
            zone: { dropZone = $0 },
            performCenter: { id in
                guard canAcceptDrops, !folder.appIDs.contains(id) else { return false }
                withAnimation(Theme.content) { model.add(id, to: folder.id) }
                return true
            },
            performReorder: { id, after in
                TileReorderSupport.move(appID: id, relativeTo: itemID, after: after,
                                        model: model, reduceMotion: reduceMotion)
            }
        )
        .contextMenu {
            FolderContextMenu(folder: folder, model: model,
                              itemID: acceptsReorder ? itemID : nil)
        }
    }
}

/// Folder artwork + Finder badge with hover lift, press shrink and the drop-target "open up".
/// Keeps the folder's `matchedGeometryEffect` id (`FolderGeometryID.container`) that the overlay
/// morphs from.
private struct FolderTileArtwork: View {
    let folder: Folder
    let apps: [AppEntry]
    let namespace: Namespace.ID?
    let isHovered: Bool
    let isSelected: Bool
    let isTargeted: Bool
    /// Number shown in the corner badge; nil hides it.
    var count: Int?

    @Environment(\.isTilePressed) private var isPressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if isTargeted { return Theme.dropTargetScale }
        if isPressed { return Theme.pressScale }
        if isHovered || isSelected { return Theme.hoverScale }
        return 1
    }

    var body: some View {
        let lifted = (isHovered || isSelected) && !isPressed && !isTargeted
        FolderArtwork(
            folder: folder,
            apps: apps,
            isExpanded: isTargeted && !reduceMotion
        )
        .matchedGeometry(id: FolderGeometryID.container(folder.id), in: namespace)
        .overlay(alignment: .bottomTrailing) {
            if folder.isFinder { FinderBadge().offset(x: 5, y: 5) }
        }
        // Top corner, so it never covers the name under the artwork (or the Finder badge).
        .overlay(alignment: .topTrailing) {
            if let count {
                FolderCountBadge(count: count)
                    .offset(x: 6, y: -6)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.5).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: count)
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: GridMetrics.iconSize * 0.23, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                    .transition(.opacity)
            } else if isSelected {
                SelectionRing(cornerRadius: GridMetrics.iconSize * 0.23)
            }
        }
        .shadow(color: .black.opacity(lifted ? 0.2 : 0), radius: lifted ? 6 : 0, y: lifted ? 3 : 0)
        .scaleEffect(scale)
        .animation(Theme.snappy, value: isPressed)
    }
}

/// Small corner badge marking a folder mirrored from Finder.
struct FinderBadge: View {
    var body: some View {
        Image(systemName: "macwindow")
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 19, height: 19)
            .background(.regularMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
            .accessibilityLabel("Папка з Finder")
    }
}

/// Small glass capsule with the number of visible apps in a folder (Settings → "showsFolderCounts").
struct FolderCountBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: count > 99 ? "99+" : "\(count)")
            .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5.5)
            .frame(minWidth: 19, minHeight: 19)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
            .contentTransition(.numericText())
            // The tile carries the count as its accessibility value.
            .accessibilityHidden(true)
    }
}

enum FolderGeometryID: Hashable {
    case container(UUID)
}

/// Context menu for a folder tile.
struct FolderContextMenu: View {
    let folder: Folder
    let model: GridModel
    /// The tile's `GridItem` id when it is a top-level item of "Все" (offers moving it); nil otherwise.
    var itemID: String?

    var body: some View {
        Button("Відкрити") {
            withAnimation(Theme.morph) { model.openFolderID = folder.id }
        }
        Button("Відкрити всі") { model.launchAll(in: folder) }
            .disabled(model.apps(in: folder).isEmpty)
        if let path = folder.finderPath {
            Button("Показати у Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
        } else {
            Button("Перейменувати") {
                model.renamingFolderID = folder.id
                withAnimation(Theme.morph) { model.openFolderID = folder.id }
            }
        }
        if let itemID {
            Divider()
            ItemMoveMenuItems(itemID: itemID, model: model)
        }
        Divider()
        FolderStyleMenus(folder: folder, model: model)
        Divider()
        Button(folder.isFinder ? String(localized: "Не показувати як папку") : String(localized: "Розформувати")) {
            withAnimation(Theme.content) {
                if model.openFolderID == folder.id { model.openFolderID = nil }
                model.dissolve(folder: folder.id)
            }
        }
    }
}

/// "Колір" and "Іконка" submenus for a folder (SF Symbols by group, plus an "Емодзі" palette).
struct FolderStyleMenus: View {
    let folder: Folder
    let model: GridModel

    var body: some View {
        Menu("Колір") {
            ForEach(FolderColor.allCases, id: \.self) { color in
                Button {
                    model.setStyle(folder: folder.id, color: color, symbol: folder.symbol)
                } label: {
                    Label {
                        Text(color == folder.color ? "\(color.displayName) ✓" : color.displayName)
                    } icon: {
                        Image(nsImage: color.menuSwatch)
                    }
                }
            }
        }
        Menu("Іконка") {
            Toggle("Без іконки", isOn: Binding(
                get: { folder.symbol == nil },
                set: { _ in setSymbol(nil) }
            ))
            ForEach(FolderSymbols.groups, id: \.symbols) { group in
                Section {
                    ForEach(group.symbols, id: \.self) { symbol in
                        Button {
                            setSymbol(symbol)
                        } label: {
                            Label(symbol == folder.symbol ? "\(symbol) ✓" : symbol, systemImage: symbol)
                        }
                    }
                } header: {
                    Text(group.title)
                }
            }
            Divider()
            Menu("Емодзі") {
                ForEach(FolderSymbols.emoji, id: \.self) { emoji in
                    let stored = FolderSymbols.symbol(forEmoji: emoji)
                    Button(stored == folder.symbol ? "\(emoji) ✓" : emoji) { setSymbol(stored) }
                }
            }
        }
    }

    private func setSymbol(_ symbol: String?) {
        model.setStyle(folder: folder.id, color: folder.color, symbol: symbol)
    }
}

#Preview {
    let model = GridModel.preview
    if let folder = model.layout.folders.first {
        HStack {
            FolderTileView(folder: folder, apps: model.apps(in: folder), model: model)
            FolderArtwork(folder: Folder(name: "Ігри", color: .purple, symbol: "gamecontroller", appIDs: []), apps: [])
        }
        .padding()
    }
}

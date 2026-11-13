import AppKit
import MenuFoldCore
import SwiftUI

/// One app tile: 64pt icon + two-line label, hover lift, press shrink, launch pulse,
/// drop-target halo, keyboard-selection ring, running dot, AppKit drag source, context menu.
struct AppIconView: View {
    let app: AppEntry
    @Bindable var model: GridModel
    /// True when shown inside the expanded folder overlay.
    var insideFolder: Bool = false
    /// Accept app-onto-app drops (creates a folder).
    var acceptsFolderDrops: Bool = false
    /// Keyboard-selection id of this tile; nil → its `GridItem` id ("app:…"). The "Часті" row passes
    /// `GridModel.frequentSelectionID(_:)`, so the same app can be selected there or in the grid.
    var selectionID: String?
    /// Accept reorder drops on the tile's left/right edges ("Все" with no search, see `TileDropDelegate`).
    var acceptsReorder: Bool = false

    @State private var isHovered = false
    /// The part of the tile a drag is over: center = folder drop, edges = reorder.
    @State private var dropZone: TileDropZone?
    @State private var launchPulse = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isTargeted: Bool { dropZone == .center }
    private var itemID: String { MenuFoldCore.GridItem.app(app).id }
    private var isSelected: Bool {
        model.selectedItemID == (selectionID ?? MenuFoldCore.GridItem.app(app).id)
    }

    var body: some View {
        let isRunning = RunningAppsMonitor.shared.isRunning(app.id)
        // Read the preference in `body` so toggling it in Settings re-renders the tile.
        let isNew = AppPreferences.shared.showsNewAppDots && model.isNew(app.id)
        Button {
            launchPulse += 1
            model.launch(app)
        } label: {
            VStack(spacing: 6) {
                AppIconArtwork(
                    image: IconCache.shared.icon(for: app),
                    isHovered: isHovered,
                    isSelected: isSelected,
                    isTargeted: isTargeted,
                    launchPulse: launchPulse
                )
                // Dock-like dot in the gap under the icon; it takes no layout space.
                .overlay(alignment: .bottom) {
                    if isRunning {
                        Circle()
                            .fill(Theme.runningDotColor)
                            .frame(width: Theme.runningDotSize, height: Theme.runningDotSize)
                            .offset(y: Theme.runningDotSize + 1)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                            .accessibilityHidden(true)
                    }
                }
                // Recently installed: a small accent dot at the icon's top-right corner, like the
                // Launchpad "new" marker; it takes no layout space.
                .overlay(alignment: .topTrailing) {
                    if isNew {
                        NewAppDot()
                            .offset(x: 3, y: -3)
                            .transition(reduceMotion ? .opacity : .scale(scale: 0.2).combined(with: .opacity))
                    }
                }
                .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: isRunning)
                .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: isNew)
                Text(app.name)
                    .font(Theme.labelFont)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .multilineTextAlignment(.center)
                    .frame(height: 34, alignment: .top)
            }
            .padding(6)
            .frame(width: GridMetrics.tileWidth)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            // AppKit drag source (alias in Finder, pin in the Dock, private type for internal drops).
            // Inside the label so forwarded clicks still reach the button.
            // `.id(app.id)` gives each tile its own representable, so SwiftUI never reuses a drag
            // source view for a different app when the grid re-sorts (tab switch, search, catalog
            // refresh). The view also freezes the app identity on mouse-down (bug 1).
            // `.accessibilityHidden` keeps the unlabeled NSView out of the VoiceOver tree, which
            // would otherwise expose an empty element inside the button (bug 8).
            .overlay {
                AppDragSource(appID: app.id, url: app.url)
                    .id(app.id)
                    .accessibilityHidden(true)
            }
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovered = $0 }
        .animation(Theme.snappy, value: isHovered)
        .animation(Theme.snappy, value: isTargeted)
        .animation(Theme.snappy, value: isSelected)
        .reorderCaret(dropZone)
        .help(app.name)
        .accessibilityLabel(app.name)
        .accessibilityValue([
            isNew ? String(localized: "Нова") : nil,
            isRunning ? String(localized: "Запущено") : nil,
        ].compactMap { $0 }.joined(separator: ", "))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .tileDropDestination(
            allowsCenter: acceptsFolderDrops,
            allowsReorder: acceptsReorder,
            isKnownApp: { id in model.apps.contains { $0.id == id } },
            canReorder: { id in id != app.id && TileReorderSupport.isTopLevel(appID: id, in: model) },
            zone: { dropZone = $0 },
            performCenter: { dropped in
                guard acceptsFolderDrops, dropped != app.id else { return false }
                guard let folderID = model.createFolder(dropping: dropped, onto: app.id) else { return false }
                withAnimation(Theme.morph) { model.openFolderID = folderID }
                return true
            },
            performReorder: { dropped, after in
                TileReorderSupport.move(appID: dropped, relativeTo: itemID, after: after,
                                        model: model, reduceMotion: reduceMotion)
            }
        )
        .contextMenu {
            AppContextMenu(app: app, model: model, insideFolder: insideFolder,
                           inPinnedRow: selectionID?.hasPrefix("pinned:") == true,
                           inMainGrid: acceptsReorder)
        }
    }
}

/// The icon part of a tile: scales on hover/selection/press/drop-target (the label stays), soft
/// shadow, accent ring when selected with the keyboard, glass halo while an app is dragged over it,
/// and a quick pulse on launch.
private struct AppIconArtwork: View {
    let image: NSImage
    let isHovered: Bool
    let isSelected: Bool
    let isTargeted: Bool
    let launchPulse: Int

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
        let size = GridMetrics.iconSize
        let lifted = (isHovered || isSelected) && !isPressed
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(
                color: .black.opacity(lifted ? 0.22 : 0),
                radius: lifted ? 6 : 0,
                y: lifted ? 3 : 0
            )
            .overlay {
                if isSelected && !isTargeted {
                    SelectionRing(cornerRadius: GridMetrics.tileCorner)
                }
            }
            .background {
                if isTargeted {
                    // Drop target halo: a tinted glass square with an accent ring behind the icon.
                    RoundedRectangle(cornerRadius: GridMetrics.tileCorner + 4, style: .continuous)
                        .fill(.clear)
                        .glassEffect(
                            .regular.tint(Color.accentColor.opacity(0.35)),
                            in: .rect(cornerRadius: GridMetrics.tileCorner + 4, style: .continuous)
                        )
                        .overlay {
                            RoundedRectangle(cornerRadius: GridMetrics.tileCorner + 4, style: .continuous)
                                .strokeBorder(Color.accentColor.opacity(0.7), lineWidth: 1.5)
                        }
                        .padding(-6)
                        .transition(
                            reduceMotion ? .opacity : .scale(scale: 0.8).combined(with: .opacity)
                        )
                }
            }
            .scaleEffect(scale)
            .animation(Theme.snappy, value: isPressed)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: reduceMotion ? 0 : launchPulse) { content, pulse in
                content.scaleEffect(pulse)
            } keyframes: { _ in
                SpringKeyframe(1.14, duration: 0.09, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.16, spring: .bouncy)
            }
    }
}

/// Accent ring around a keyboard-selected tile's artwork.
struct SelectionRing: View {
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius - Theme.selectionRingInset, style: .continuous)
            .strokeBorder(Color.accentColor.opacity(Theme.selectionRingOpacity), lineWidth: Theme.selectionRingWidth)
            .padding(Theme.selectionRingInset)
            .allowsHitTesting(false)
            .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
    }
}

/// Small accent dot on a recently installed app's icon (`GridModel.isNew`).
struct NewAppDot: View {
    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .frame(width: 9, height: 9)
            .overlay(Circle().strokeBorder(.white.opacity(0.85), lineWidth: 1.5))
            .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// Context menu for an app tile.
struct AppContextMenu: View {
    let app: AppEntry
    let model: GridModel
    let insideFolder: Bool
    /// The tile is in the "Закріплені" row: offers moving it within the row.
    var inPinnedRow = false
    /// The tile is a top-level item of "Все" (no search, no open folder): offers moving it.
    var inMainGrid = false

    var body: some View {
        let isRunning = RunningAppsMonitor.shared.isRunning(app.id)
        Button("Відкрити") { model.launch(app) }
        if isRunning {
            Button("Новий екземпляр") { model.launch(app, newInstance: true) }
        }
        Button("Показати у Finder") { model.revealInFinder(app) }
            .keyboardShortcut("r", modifiers: .command)
        if isRunning {
            Button("Завершити") { RunningAppsMonitor.shared.quit(app.id) }
                .modifierKeyAlternate(.option) {
                    Button("Завершити примусово") { RunningAppsMonitor.shared.quit(app.id, force: true) }
                }
        }
        Divider()
        pinItems
        if inMainGrid {
            ItemMoveMenuItems(itemID: MenuFoldCore.GridItem.app(app).id, model: model)
        }
        Divider()
        Button("Змінити значок…") { CustomIconPicker.choose(for: app, model: model) }
        if model.customIconURL(for: app.id) != nil {
            Button("Стандартний значок") { model.resetCustomIcon(for: app.id) }
        }
        Menu("Змінити категорію") {
            let hasOverride = model.layout.categoryOverrides[app.id] != nil
            let current = model.category(of: app)
            Toggle("Автоматично", isOn: Binding(
                get: { !hasOverride },
                set: { _ in model.setCategory(nil, for: app.id) }
            ))
            let custom = model.customCategories
            if !custom.isEmpty {
                Section("Мої категорії") {
                    ForEach(custom) { category in
                        Toggle(category.displayName, isOn: Binding(
                            get: { hasOverride && current == category },
                            set: { _ in model.setCategory(category, for: app.id) }
                        ))
                    }
                }
            }
            Section("Системні") {
                ForEach(AppCategory.known + [AppCategory.other]) { category in
                    Toggle(category.displayName, isOn: Binding(
                        get: { hasOverride && current == category },
                        set: { _ in model.setCategory(category, for: app.id) }
                    ))
                }
            }
            Divider()
            Button("Нова категорія…") {
                // Created with a placeholder name, then renamed inline on its tab (like a new folder).
                let category = model.createCategory(assigning: app.id)
                model.query = ""
                model.openFolderID = nil
                withAnimation(Theme.content) { model.tab = .category(category) }
                model.renamingCategoryID = category.id
            }
        }
        if insideFolder {
            Button("Прибрати з папки") {
                withAnimation(Theme.content) { model.removeFromFolder(app.id) }
            }
        }
        Divider()
        Button("Скопіювати шлях") { copy(app.url.path) }
        Button("Скопіювати ідентифікатор") { copy(app.id) }
        Button("Показати вміст пакета") {
            // Selecting `Contents` makes Finder open the bundle like a folder.
            NSWorkspace.shared.activateFileViewerSelecting([app.url.appendingPathComponent("Contents")])
        }
        if let storeID = app.appStoreID,
           let url = URL(string: "macappstore://apps.apple.com/app/id\(storeID)") {
            Button("Відкрити в App Store") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Приховати") {
            withAnimation(Theme.content) { model.hide(app.id) }
        }
        if model.canTrash(app) {
            Divider()
            // Asks first, in the panel (`TrashConfirmationCard`).
            Button("Перемістити в Кошик…") { model.pendingTrashAppID = app.id }
                .keyboardShortcut(.delete, modifiers: .command)
        }
    }

    @ViewBuilder
    private var pinItems: some View {
        if model.isPinned(app.id) {
            Button("Відкріпити") {
                withAnimation(Theme.content) { model.unpin(app.id) }
            }
            if inPinnedRow {
                let pinned = model.pinnedApps.map(\.id)
                Button("Пересунути ліворуч") {
                    withAnimation(Theme.content) { model.movePinned(app.id, by: -1) }
                }
                .disabled(pinned.first == app.id)
                Button("Пересунути праворуч") {
                    withAnimation(Theme.content) { model.movePinned(app.id, by: 1) }
                }
                .disabled(pinned.last == app.id)
            }
        } else {
            Button("Закріпити") {
                withAnimation(Theme.content) { model.pin(app.id) }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

#Preview {
    let model = GridModel.preview
    if let app = model.apps.first {
        AppIconView(app: app, model: model, acceptsFolderDrops: true)
            .padding()
    }
}

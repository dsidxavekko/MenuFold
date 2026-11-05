import AppKit
import MenuFoldCore
import SwiftUI

/// One app tile: 64pt icon + two-line label, hover lift, press shrink, launch pulse,
/// drop-target halo, AppKit drag source, context menu.
struct AppIconView: View {
    let app: AppEntry
    @Bindable var model: GridModel
    /// True when shown inside the expanded folder overlay.
    var insideFolder: Bool = false
    /// Accept app-onto-app drops (creates a folder).
    var acceptsFolderDrops: Bool = false

    @State private var isHovered = false
    @State private var isTargeted = false
    @State private var launchPulse = 0

    var body: some View {
        Button {
            launchPulse += 1
            model.launch(app)
        } label: {
            VStack(spacing: 6) {
                AppIconArtwork(
                    image: IconCache.shared.icon(for: app),
                    isHovered: isHovered,
                    isTargeted: isTargeted,
                    launchPulse: launchPulse
                )
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
        .help(app.name)
        .accessibilityLabel(app.name)
        .appDropDestination(isEnabled: acceptsFolderDrops, isKnownApp: { id in
            model.apps.contains { $0.id == id }
        }) { targeted in
            isTargeted = acceptsFolderDrops && targeted
        } perform: { dropped in
            guard acceptsFolderDrops, dropped != app.id else { return false }
            guard let folderID = model.createFolder(dropping: dropped, onto: app.id) else { return false }
            withAnimation(Theme.morph) { model.openFolderID = folderID }
            return true
        }
        .contextMenu { AppContextMenu(app: app, model: model, insideFolder: insideFolder) }
    }
}

/// The icon part of a tile: scales on hover/press/drop-target (the label stays), soft shadow,
/// glass halo while an app is dragged over it, and a quick pulse on launch.
private struct AppIconArtwork: View {
    let image: NSImage
    let isHovered: Bool
    let isTargeted: Bool
    let launchPulse: Int

    @Environment(\.isTilePressed) private var isPressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if isTargeted { return Theme.dropTargetScale }
        if isPressed { return Theme.pressScale }
        if isHovered { return Theme.hoverScale }
        return 1
    }

    var body: some View {
        let size = GridMetrics.iconSize
        let lifted = isHovered && !isPressed
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .shadow(
                color: .black.opacity(lifted ? 0.22 : 0),
                radius: lifted ? 6 : 0,
                y: lifted ? 3 : 0
            )
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

/// Context menu for an app tile.
struct AppContextMenu: View {
    let app: AppEntry
    let model: GridModel
    let insideFolder: Bool

    var body: some View {
        Button("Відкрити") { model.launch(app) }
        Button("Показати у Finder") { model.revealInFinder(app) }
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
        Button("Приховати") {
            withAnimation(Theme.content) { model.hide(app.id) }
        }
    }
}

#Preview {
    let model = GridModel.preview
    if let app = model.apps.first {
        AppIconView(app: app, model: model, acceptsFolderDrops: true)
            .padding()
    }
}

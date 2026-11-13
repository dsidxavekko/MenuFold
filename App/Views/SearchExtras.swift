import MenuFoldCore
import SwiftUI

/// Chips for `model.matchingTabs` above the search results; a click switches to that tab and clears
/// the query. Draws nothing when there are no matching tabs.
/// Typing a category's name ("Ігри", "Запущені") is a quick way to jump to its tab, so the chips
/// sit right above the results instead of making the user clear the field and hunt in the strip.
struct TabChipsView: View {
    @Bindable var model: GridModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tabs = model.matchingTabs
        if !tabs.isEmpty {
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(tabs, id: \.self) { tab in
                            TabChip(title: Self.title(for: tab), symbol: Self.symbol(for: tab)) {
                                withAnimation(reduceMotion ? Theme.crossfade : Theme.content) {
                                    model.query = ""
                                    model.tab = tab
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }
            .scrollIndicators(.never)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Категорії")
        }
    }

    /// Same titles as the tab strip.
    static func title(for tab: GridTab) -> String {
        switch tab {
        case .all: String(localized: "Все")
        case .running: String(localized: "Запущені")
        case .recent: String(localized: "Недавні")
        case .category(let category): category.displayName
        }
    }

    private static func symbol(for tab: GridTab) -> String {
        switch tab {
        case .all: "square.grid.2x2"
        case .running: "circle.fill"
        case .recent: "clock"
        case .category: "tag"
        }
    }
}

private struct TabChip: View {
    let title: String
    let symbol: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text(title)
                    .font(Theme.tabFont)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.capsuleHeight - 4)
            .glassEffect(.regular.tint(isHovered ? Color.accentColor.opacity(0.18) : nil).interactive(), in: .capsule)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.snappy, value: isHovered)
        .help(String(localized: "Перейти до категорії «\(title)»"))
    }
}

/// "Системні параметри" section with `model.settingsPaneResults`, placed by GridView at the end of
/// the scroll content while searching. Each tile has `.id(GridModel.paneSelectionID(pane.id))` and
/// shows the keyboard selection like app tiles. Draws nothing when there are no results.
struct SettingsPaneSection: View {
    @Bindable var model: GridModel

    var body: some View {
        let panes = model.settingsPaneResults
        if !panes.isEmpty {
            let columns = Array(
                repeating: SwiftUI.GridItem(.flexible(), spacing: 4),
                count: GridMetrics.columns
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("Системні параметри")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .accessibilityAddTraits(.isHeader)
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(panes) { pane in
                        SettingsPaneTile(
                            pane: pane,
                            isSelected: model.selectedItemID == GridModel.paneSelectionID(pane.id)
                        ) {
                            model.openSettingsPane(pane)
                        }
                        .id(GridModel.paneSelectionID(pane.id))
                    }
                }
            }
            .padding(.top, 8)
        }
    }
}

/// A System Settings pane as a tile: its SF Symbol on a gray glass square the size of an app icon.
private struct SettingsPaneTile: View {
    let pane: SystemSettingsPane
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                PaneArtwork(symbol: pane.symbol, isHovered: isHovered, isSelected: isSelected)
                Text(pane.name)
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
        }
        .buttonStyle(TileButtonStyle())
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Theme.snappy, value: isHovered)
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: isSelected)
        .help(pane.name)
        .accessibilityLabel(pane.name)
        .accessibilityHint("Відкриває Системні параметри")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PaneArtwork: View {
    let symbol: String
    let isHovered: Bool
    let isSelected: Bool

    @Environment(\.isTilePressed) private var isPressed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var scale: CGFloat {
        if reduceMotion { return 1 }
        if isPressed { return Theme.pressScale }
        if isHovered || isSelected { return Theme.hoverScale }
        return 1
    }

    var body: some View {
        let size = GridMetrics.iconSize
        let shape = RoundedRectangle(cornerRadius: GridMetrics.tileCorner, style: .continuous)
        Image(systemName: symbol)
            .font(.system(size: size * 0.45, weight: .regular))
            .foregroundStyle(.primary.opacity(0.8))
            .frame(width: size, height: size)
            .glassEffect(.regular.tint(Color.gray.opacity(0.35)), in: shape)
            .overlay {
                if isSelected { SelectionRing(cornerRadius: GridMetrics.tileCorner) }
            }
            .scaleEffect(scale)
            .animation(Theme.snappy, value: isPressed)
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack {
        TabChipsView(model: .preview)
        SettingsPaneSection(model: .preview)
    }
    .padding()
    .frame(width: GridMetrics.panelWidth)
}

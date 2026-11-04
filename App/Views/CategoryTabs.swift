import MenuFoldCore
import SwiftUI

/// Horizontal capsule tabs: [Все] + one per category, bound to `model.tab`.
/// The selected tab is a tinted Liquid Glass capsule that morphs between tabs (`glassEffectID`
/// inside a `GlassEffectContainer`); the others are plain labels with a hover highlight.
struct CategoryTabs: View {
    @Bindable var model: GridModel
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(model.availableTabs, id: \.self) { tab in
                        TabCapsule(
                            title: title(for: tab),
                            isSelected: model.tab == tab,
                            namespace: selectionNamespace
                        ) {
                            withAnimation(reduceMotion ? nil : Theme.snappy) { model.tab = tab }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
        }
        .scrollIndicators(.never)
        .onChange(of: model.availableTabs) { _, tabs in
            // The selected category may disappear (last app hidden/recategorized).
            if !tabs.contains(model.tab) { model.tab = .all }
        }
    }

    private func title(for tab: GridTab) -> String {
        switch tab {
        case .all: "Все"
        case .category(let category): category.displayName
        }
    }
}

private struct TabCapsule: View {
    let title: String
    let isSelected: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovered = false

    private static let selectionID = "category-tab-selection"

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Theme.tabFont)
                .padding(.horizontal, 12)
                .frame(height: Theme.capsuleHeight - 4)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .background {
                    if !isSelected {
                        Capsule().fill(Color.primary.opacity(isHovered ? 0.10 : 0.04))
                    }
                }
                .modifier(SelectionGlass(isSelected: isSelected, namespace: namespace, id: Self.selectionID))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(Theme.snappy, value: isHovered)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The morphing selection pill: only the selected tab carries the glass element with the shared id,
/// so the container morphs it from the old tab to the new one.
private struct SelectionGlass: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID
    let id: String

    func body(content: Content) -> some View {
        if isSelected {
            content
                .glassEffect(.regular.tint(.accentColor).interactive(), in: .capsule)
                .glassEffectID(id, in: namespace)
        } else {
            content
        }
    }
}

#Preview {
    CategoryTabs(model: .preview)
        .padding()
        .frame(width: GridMetrics.panelWidth)
}

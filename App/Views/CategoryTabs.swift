import MenuFoldCore
import SwiftUI

/// Horizontal capsule tabs: [Все] + one per category, bound to `model.tab`.
/// The selected tab is a tinted Liquid Glass capsule that morphs between tabs (`glassEffectID`
/// inside a `GlassEffectContainer`); the others are plain labels with a hover highlight.
/// Category tabs can be dragged to a new place or moved from their context menu (String(localized: "Все") stays
/// first). Custom categories are also renamed inline (while `model.renamingCategoryID` names one,
/// its tab is a text field) and deleted from the same menu.
struct CategoryTabs: View {
    @Bindable var model: GridModel
    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Category ids in the order shown while a tab is being dragged; nil otherwise. The model is
    /// updated once, when the drag ends, so a drag saves the layout one time.
    @State private var liveOrder: [String]?
    @State private var draggingID: String?
    /// Tab frames in the strip's coordinate space, for finding the tab under the pointer.
    @State private var frames: [String: CGRect] = [:]

    private static let space = "category-tabs"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach(displayedTabs, id: \.self) { tab in
                            tabView(tab)
                                .id(tabID(tab))
                        }
                    }
                    .coordinateSpace(.named(Self.space))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 2)
                }
            }
            .scrollIndicators(.never)
            .onChange(of: model.renamingCategoryID) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : Theme.snappy) { proxy.scrollTo(id, anchor: .center) }
            }
        }
        .onChange(of: model.availableTabs) { _, tabs in
            // The selected category may disappear (last app hidden/recategorized, category deleted).
            if !tabs.contains(model.tab) { model.tab = .all }
        }
    }

    /// The model's tabs, or the live order during a drag.
    private var displayedTabs: [GridTab] {
        let tabs = model.availableTabs
        guard let liveOrder else { return tabs }
        var byID: [String: GridTab] = [:]
        for tab in tabs { byID[tabID(tab)] = tab }
        // "Все" and "Запущені" stay in front; only categories are reordered.
        let fixed = tabs.filter { if case .category = $0 { false } else { true } }
        return fixed + liveOrder.compactMap { byID[$0] }
    }

    /// Category ids in the model's order (without String(localized: "Все")).
    private var categoryIDs: [String] {
        model.availableTabs.compactMap { tab in
            if case .category(let category) = tab { category.id } else { nil }
        }
    }

    @ViewBuilder
    private func tabView(_ tab: GridTab) -> some View {
        if case .category(let category) = tab {
            if model.renamingCategoryID == category.id {
                CategoryNameField(model: model, category: category)
            } else {
                let ids = categoryIDs
                let isDragged = draggingID == category.id
                capsule(for: tab)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.space)) } action: { frames[category.id] = $0 }
                    .simultaneousGesture(reorderGesture(for: category.id))
                    .scaleEffect(isDragged ? 1.08 : 1)
                    .opacity(isDragged ? 0.85 : 1)
                    .zIndex(isDragged ? 1 : 0)
                    .animation(reduceMotion ? nil : Theme.snappy, value: isDragged)
                    .contextMenu {
                        Button("Пересунути ліворуч") { move(category.id, by: -1) }
                            .disabled(ids.first == category.id)
                        Button("Пересунути праворуч") { move(category.id, by: 1) }
                            .disabled(ids.last == category.id)
                        if category.isCustom {
                            Divider()
                            Button("Перейменувати") { model.renamingCategoryID = category.id }
                            Button("Видалити категорію", role: .destructive) {
                                withAnimation(reduceMotion ? nil : Theme.content) { model.deleteCategory(id: category.id) }
                            }
                        }
                    }
                    .accessibilityAction(named: "Пересунути ліворуч") { move(category.id, by: -1) }
                    .accessibilityAction(named: "Пересунути праворуч") { move(category.id, by: 1) }
                    .accessibilityHint(category.isCustom
                        ? String(localized: "Власна категорія. Перетягніть, щоб змінити порядок; контекстне меню: перейменувати або видалити")
                        : String(localized: "Перетягніть, щоб змінити порядок"))
            }
        } else {
            capsule(for: tab)
        }
    }

    private func move(_ id: String, by offset: Int) {
        withAnimation(reduceMotion ? nil : Theme.snappy) { model.moveCategory(id: id, by: offset) }
    }

    /// Drag a category tab along the strip: it swaps places once the pointer passes the middle of
    /// another tab (the middle rule stops two tabs of different widths from swapping back and forth).
    private func reorderGesture(for id: String) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(Self.space))
            .onChanged { value in
                if liveOrder == nil {
                    liveOrder = categoryIDs
                    draggingID = id
                }
                guard var order = liveOrder, let from = order.firstIndex(of: id) else { return }
                let x = value.location.x
                for (index, other) in order.enumerated() where other != id {
                    guard let frame = frames[other], frame.minX <= x, x <= frame.maxX else { continue }
                    if (index > from && x > frame.midX) || (index < from && x < frame.midX) {
                        order.remove(at: from)
                        order.insert(id, at: index)
                        withAnimation(reduceMotion ? nil : Theme.snappy) { liveOrder = order }
                    }
                    break
                }
            }
            .onEnded { _ in
                if let order = liveOrder, order != categoryIDs { model.setCategoryOrder(order) }
                liveOrder = nil
                draggingID = nil
            }
    }

    private func capsule(for tab: GridTab) -> some View {
        TabCapsule(
            title: title(for: tab),
            isSelected: model.tab == tab,
            namespace: selectionNamespace
        ) {
            withAnimation(reduceMotion ? nil : Theme.snappy) { model.tab = tab }
        }
    }

    /// Scroll id: stable across renames (the tab value carries the display name).
    private func tabID(_ tab: GridTab) -> String {
        switch tab {
        case .all: "all"
        case .running: "running"
        case .category(let category): category.id
        }
    }

    private func title(for tab: GridTab) -> String {
        switch tab {
        case .all: String(localized: "Все")
        case .running: String(localized: "Запущені")
        case .category(let category): category.displayName
        }
    }
}

/// Inline name editor that replaces a custom category's tab. Enter or clicking away saves,
/// Esc (`.menuFoldCategoryEscape`) keeps the old name; either way editing ends.
private struct CategoryNameField: View {
    let model: GridModel
    let category: AppCategory

    @State private var name = ""
    @State private var finished = false
    @FocusState private var focused: Bool

    var body: some View {
        // A hidden Text sizes the field to its contents so the capsule hugs the name.
        Text(name.isEmpty ? String(localized: "Назва категорії") : name)
            .font(Theme.tabFont)
            .lineLimit(1)
            .hidden()
            .overlay {
                TextField("Назва категорії", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.tabFont)
                    .multilineTextAlignment(.center)
                    .focused($focused)
                    .onSubmit { finish(saving: true) }
            }
            .frame(minWidth: 60, maxWidth: 240)
            .padding(.horizontal, 12)
            .frame(height: Theme.capsuleHeight - 4)
            .glassEffect(.regular, in: .capsule)
            .overlay {
                Capsule()
                    .strokeBorder(Color.accentColor.opacity(0.6), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .help("Назва категорії. Enter — зберегти, Esc — скасувати.")
            .accessibilityLabel("Назва категорії")
            .accessibilityHint("Enter зберігає нову назву, Esc повертає попередню")
            .onAppear {
                name = category.displayName
                // Wait for the field to be in the window before taking focus.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(120))
                    if !finished { focused = true }
                }
            }
            .onChange(of: focused) { old, new in
                if old, !new { finish(saving: true) }
            }
            .onDisappear { finish(saving: true) }
            .onReceive(NotificationCenter.default.publisher(for: .menuFoldCategoryEscape)) { _ in
                finish(saving: false)
            }
    }

    private func finish(saving: Bool) {
        guard !finished else { return }
        finished = true
        if saving { model.renameCategory(id: category.id, to: name) }
        if model.renamingCategoryID == category.id { model.renamingCategoryID = nil }
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

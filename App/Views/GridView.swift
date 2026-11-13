import AppKit
import MenuFoldCore
import SwiftUI

/// Grid of `model.visibleItems` (apps and folders) with empty states, under the "Закріплені"
/// (`model.pinnedApps`) and "Часті" (`model.frequentApps`) rows, which the model only fills on "Все"
/// with an empty query. While searching, matching tabs come as chips on top and System Settings
/// panes as a section at the bottom.
struct GridView: View {
    @Bindable var model: GridModel
    var namespace: Namespace.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the staggered fade/scale-in of the first rows each time the panel opens.
    @State private var isRevealed = false

    /// Column count from Settings. Read from `body` (through here), so a change re-renders the grid.
    private var columnCount: Int { AppPreferences.shared.columns }

    private var columns: [SwiftUI.GridItem] {
        Array(repeating: SwiftUI.GridItem(.flexible(), spacing: 4), count: columnCount)
    }

    /// Folder-making drops only on the manual layout (`.all`, no search), and never while a folder is
    /// open: the blurred grid behind the overlay is `allowsHitTesting(false)`, but SwiftUI still routes
    /// drops to it, so a drop on the overlay backdrop would land on the tile underneath.
    /// Reordering by drag has the same conditions.
    private var allowsFolderDrops: Bool {
        model.tab == .all && model.query.isEmpty && model.openFolderID == nil
    }

    private var isSearching: Bool {
        !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Which of the grid's states is showing, so switching between them can crossfade.
    private enum Phase: Hashable { case loading, noApps, empty, grid }

    var body: some View {
        let items = model.visibleItems
        let panes = isSearching ? model.settingsPaneResults : []
        let phase: Phase = !model.isLoaded ? .loading
            : model.apps.isEmpty ? .noApps
            // A search with only System Settings matches still shows them instead of "nothing found".
            : items.isEmpty && panes.isEmpty ? .empty : .grid
        Group {
            switch phase {
            case .loading:
                EmptyStateView(title: String(localized: "Завантаження…"), showsSpinner: true)
            case .noApps:
                EmptyStateView(
                    title: String(localized: "Програм не знайдено"),
                    subtitle: String(localized: "Можливо, індексування Spotlight вимкнене."),
                    systemImage: "square.grid.3x3"
                )
            case .empty:
                VStack(spacing: 0) {
                    // Even with no app results a matching tab is one click away.
                    if isSearching { TabChipsView(model: model) }
                    EmptyStateView(
                        title: model.query.isEmpty ? String(localized: "Тут поки порожньо") : String(localized: "Нічого не знайдено"),
                        subtitle: model.query.isEmpty ? nil : String(localized: "Спробуйте іншу назву."),
                        systemImage: model.query.isEmpty ? "tray" : "magnifyingglass",
                        effectTrigger: model.query
                    )
                }
            case .grid:
                grid(items: items)
            }
        }
        .transition(.opacity)
        .animation(Theme.content, value: phase)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear(perform: reveal)
        // Panel re-shown: replay the quick cascade. Only for the panel (settings is an NSWindow).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            guard note.object is NSPanel else { return }
            var hide = Transaction()
            hide.disablesAnimations = true
            withTransaction(hide) { isRevealed = false }
            reveal()
        }
    }

    @ViewBuilder
    private func grid(items: [MenuFoldCore.GridItem]) -> some View {
        let cols = columnCount
        ScrollViewReader { proxy in
            let pinned = model.pinnedApps
            let frequent = model.frequentApps
            // The "Закріплені" row cascades first, then "Часті", then the grid's rows.
            let frequentOffset = Self.rowsSpan(pinned.count, columns: cols)
            let gridOffset = frequentOffset + Self.rowsSpan(frequent.count, columns: cols)
            ScrollView {
                VStack(spacing: 0) {
                    if isSearching {
                        TabChipsView(model: model)
                    }
                    if !pinned.isEmpty {
                        appRow(pinned, revealOffset: 0, selectionID: GridModel.pinnedSelectionID)
                            .accessibilityLabel("Закріплені")
                            .transition(.opacity)
                    }
                    if !frequent.isEmpty {
                        appRow(frequent, revealOffset: frequentOffset, selectionID: GridModel.frequentSelectionID)
                            .accessibilityLabel("Часті")
                            .transition(.opacity)
                    }
                    LazyVGrid(columns: columns, spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            // The ForEach id ("app:…"/"folder:…") is the selection id.
                            tile(for: item)
                                .modifier(StaggeredReveal(
                                    index: index + gridOffset,
                                    columns: cols,
                                    isRevealed: isRevealed
                                ))
                                .transition(itemTransition)
                        }
                    }
                    // Tab switch, search, folder created/dissolved, reorder: items fade/scale/move.
                    .animation(reduceMotion ? .easeInOut(duration: 0.15) : Theme.content,
                               value: items.map(\.id))
                    if isSearching {
                        // Its tiles carry `GridModel.paneSelectionID` ids, so `scrollTo` finds them.
                        SettingsPaneSection(model: model)
                    }
                }
                .padding(.vertical, 4)
                .id(ScrollTop.id)
                .animation(reduceMotion ? .easeInOut(duration: 0.15) : Theme.content,
                           value: pinned.map(\.id) + frequent.map(\.id))
            }
            .scrollIndicators(.automatic)
            .autoScrollsWhileDragging(isEnabled: model.openFolderID == nil)
            .onChange(of: model.tab) { proxy.scrollTo(ScrollTop.id, anchor: .top) }
            .onChange(of: model.query) { proxy.scrollTo(ScrollTop.id, anchor: .top) }
            // Keyboard selection: keep the selected tile in view (inside an open folder the
            // overlay scrolls its own grid). Covers "app:", "folder:", "pinned:", "frequent:" and
            // "pane:" ids alike.
            .onChange(of: model.selectedItemID) { _, id in
                guard let id, model.openFolderID == nil else { return }
                withAnimation(reduceMotion ? nil : Theme.snappy) { proxy.scrollTo(id) }
            }
            // Every opening starts from the top: reset when the panel hides (so there is no
            // visible jump on the next open) and again when it is shown, without animation.
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                guard note.object is NSPanel else { return }
                scrollToTopInstantly(proxy)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                guard note.object is NSPanel else { return }
                scrollToTopInstantly(proxy)
            }
        }
    }

    /// Reveal indices taken by a row of `count` tiles (whole grid rows, so the next section starts
    /// its cascade on a new row).
    private static func rowsSpan(_ count: Int, columns: Int) -> Int {
        guard count > 0, columns > 0 else { return 0 }
        return (count + columns - 1) / columns * columns
    }

    private func scrollToTopInstantly(_ proxy: ScrollViewProxy) {
        var instant = Transaction()
        instant.disablesAnimations = true
        withTransaction(instant) { proxy.scrollTo(ScrollTop.id, anchor: .top) }
    }

    private var itemTransition: AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.85).combined(with: .opacity)
    }

    private func reveal() {
        guard !reduceMotion else {
            isRevealed = true
            return
        }
        Task { @MainActor in isRevealed = true }
    }

    /// A row of apps above the grid ("Закріплені" or "Часті"), laid out like the grid, then a
    /// divider. Its tiles never make folders (dragging them out still works) and are selected by
    /// their own ids ("pinned:…" / "frequent:…"), so the same app can be selected there or in the grid.
    private func appRow(_ apps: [AppEntry], revealOffset: Int,
                        selectionID: @escaping (String) -> String) -> some View {
        let cols = columnCount
        return VStack(spacing: Theme.frequentDividerSpacing) {
            LazyVGrid(columns: columns, spacing: 10) {
                // Identified by the selection id, so `scrollTo` finds the tile.
                let tiles = apps.enumerated().map { (index: $0.offset, app: $0.element,
                                                     id: selectionID($0.element.id)) }
                ForEach(tiles, id: \.id) { tile in
                    AppIconView(app: tile.app, model: model, acceptsFolderDrops: false, selectionID: tile.id)
                        .modifier(StaggeredReveal(
                            index: revealOffset + tile.index,
                            columns: cols,
                            isRevealed: isRevealed
                        ))
                        .transition(itemTransition)
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : Theme.content, value: apps.map(\.id))
            Divider()
                .padding(.horizontal, 12)
                .padding(.bottom, Theme.frequentDividerSpacing)
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func tile(for item: MenuFoldCore.GridItem) -> some View {
        switch item {
        case .app(let app):
            AppIconView(app: app, model: model, acceptsFolderDrops: allowsFolderDrops,
                        acceptsReorder: allowsFolderDrops)
        case .folder(let folder, let apps):
            FolderTileView(
                folder: folder,
                apps: apps,
                model: model,
                namespace: namespace,
                acceptsDrops: allowsFolderDrops,
                acceptsReorder: allowsFolderDrops
            )
        }
    }
}

private enum ScrollTop { static let id = "grid-top" }

struct EmptyStateView: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var showsSpinner = false
    /// Changing this replays the symbol's bounce (e.g. the search query).
    var effectTrigger: String = ""

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = 0

    var body: some View {
        VStack(spacing: 10) {
            if showsSpinner {
                ProgressView().controlSize(.regular)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                    .symbolRenderingMode(.hierarchical)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : appeared)
                    .symbolEffect(.wiggle, options: .nonRepeating, value: reduceMotion ? "" : effectTrigger)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            if let subtitle {
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { appeared += 1 }
    }
}

#Preview {
    GridView(model: .preview)
        .padding()
        .frame(width: GridMetrics.panelWidth, height: GridMetrics.panelHeight - 80)
}

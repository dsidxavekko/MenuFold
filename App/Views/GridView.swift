import AppKit
import MenuFoldCore
import SwiftUI

/// Alphabetical grid of `model.visibleItems` (apps and folders) with empty states.
struct GridView: View {
    @Bindable var model: GridModel
    var namespace: Namespace.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the staggered fade/scale-in of the first rows each time the panel opens.
    @State private var isRevealed = false

    private let columns = Array(
        repeating: SwiftUI.GridItem(.flexible(), spacing: 4),
        count: GridMetrics.columns
    )

    /// Folder-making drops only on the manual layout (`.all`, no search), and never while a folder is
    /// open: the blurred grid behind the overlay is `allowsHitTesting(false)`, but SwiftUI still routes
    /// drops to it, so a drop on the overlay backdrop would land on the tile underneath.
    private var allowsFolderDrops: Bool {
        model.tab == .all && model.query.isEmpty && model.openFolderID == nil
    }

    /// Which of the grid's states is showing, so switching between them can crossfade.
    private enum Phase: Hashable { case loading, noApps, empty, grid }

    var body: some View {
        let items = model.visibleItems
        let phase: Phase = !model.isLoaded ? .loading
            : model.apps.isEmpty ? .noApps
            : items.isEmpty ? .empty : .grid
        Group {
            switch phase {
            case .loading:
                EmptyStateView(title: "Завантаження…", showsSpinner: true)
            case .noApps:
                EmptyStateView(
                    title: "Програм не знайдено",
                    subtitle: "Можливо, індексування Spotlight вимкнене.",
                    systemImage: "square.grid.3x3"
                )
            case .empty:
                EmptyStateView(
                    title: model.query.isEmpty ? "Тут поки порожньо" : "Нічого не знайдено",
                    subtitle: model.query.isEmpty ? nil : "Спробуйте іншу назву.",
                    systemImage: model.query.isEmpty ? "tray" : "magnifyingglass",
                    effectTrigger: model.query
                )
            case .grid:
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                                tile(for: item)
                                    .modifier(StaggeredReveal(
                                        index: index,
                                        columns: GridMetrics.columns,
                                        isRevealed: isRevealed
                                    ))
                                    .transition(itemTransition)
                            }
                        }
                        .padding(.vertical, 4)
                        .id(ScrollTop.id)
                        // Tab switch, search, folder created/dissolved: items fade/scale in and out.
                        .animation(reduceMotion ? .easeInOut(duration: 0.15) : Theme.content,
                                   value: items.map(\.id))
                    }
                    .scrollIndicators(.automatic)
                    .autoScrollsWhileDragging(isEnabled: model.openFolderID == nil)
                    .onChange(of: model.tab) { proxy.scrollTo(ScrollTop.id, anchor: .top) }
                    .onChange(of: model.query) { proxy.scrollTo(ScrollTop.id, anchor: .top) }
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

    @ViewBuilder
    private func tile(for item: MenuFoldCore.GridItem) -> some View {
        switch item {
        case .app(let app):
            AppIconView(app: app, model: model, acceptsFolderDrops: allowsFolderDrops)
        case .folder(let folder, let apps):
            FolderTileView(
                folder: folder,
                apps: apps,
                model: model,
                namespace: namespace,
                acceptsDrops: allowsFolderDrops
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

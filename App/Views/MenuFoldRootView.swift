import MenuFoldCore
import SwiftUI

/// Panel content: search, category tabs, grid, the expanded folder overlay and the trash card.
/// Transparent: the shell draws the window chrome (rounded glass/vibrancy background).
struct MenuFoldRootView: View {
    @Bindable var model: GridModel
    @Namespace private var folderNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Height of the soft fade at the grid's top/bottom edges (kept inside the content margin, so
    /// the first and last rows are fully opaque when scrolled to an end).
    private static let edgeFade: CGFloat = 14

    init(model: GridModel) {
        self.model = model
    }

    private var openFolder: Folder? {
        model.openFolderID.flatMap { model.folder(id: $0) }
    }

    /// App waiting for the "move to Trash" confirmation (nil once it is gone from the catalog).
    private var trashApp: AppEntry? {
        model.pendingTrashAppID.flatMap { id in model.apps.first { $0.id == id } }
    }

    private var showsTabs: Bool {
        model.query.isEmpty && model.availableTabs.count > 1
    }

    /// Backdrop blur/dim follow the folder: the morph on open, the quicker spring on close.
    private func backdropMotion(opening: Bool) -> Animation {
        reduceMotion ? Theme.crossfade : opening ? Theme.morph : Theme.folderClose
    }

    var body: some View {
        let folder = openFolder
        let isOpen = folder != nil
        let trashApp = trashApp
        let isModal = trashApp != nil
        ZStack {
            VStack(spacing: 0) {
                SearchField(model: model)
                    .padding(.horizontal, 4)

                if showsTabs {
                    CategoryTabs(model: model)
                        .padding(.top, 12)
                        .transition(
                            .opacity.combined(with: .scale(scale: 0.97, anchor: .top))
                        )
                }

                GridView(model: model, namespace: folderNamespace)
                    .contentMargins(.vertical, Self.edgeFade, for: .scrollContent)
                    .mask(edgeFadeMask)
                    .padding(.top, 8)
            }
            .padding(.top, 18)
            .padding(.horizontal, 18)
            .padding(.bottom, 4)
            .animation(Theme.content, value: showsTabs)
            .blur(radius: isOpen || isModal ? Theme.backdropBlur : 0)
            .animation(backdropMotion(opening: isOpen), value: isOpen)
            .animation(backdropMotion(opening: isModal), value: isModal)
            .allowsHitTesting(!isOpen && !isModal)

            // Dim over the whole panel (the window clips it to the rounded chrome).
            Color.black
                .opacity(isOpen ? Theme.backdropDim : 0)
                .animation(backdropMotion(opening: isOpen), value: isOpen)
                .allowsHitTesting(false)

            if let folder {
                FolderOverlayView(folder: folder, model: model, namespace: folderNamespace)
                    .id(folder.id)
                    .blur(radius: isModal ? Theme.backdropBlur : 0)
                    .animation(backdropMotion(opening: isModal), value: isModal)
                    .allowsHitTesting(!isModal)
                    .zIndex(1)
                    .transition(.opacity)
            }

            if let trashApp {
                // Modal: a click outside the card cancels, nothing underneath takes clicks.
                Color.black
                    .opacity(Theme.cardBackdropDim)
                    .contentShape(Rectangle())
                    .onTapGesture { if !model.isTrashing { model.pendingTrashAppID = nil } }
                    .zIndex(2)
                    .transition(.opacity)
                TrashConfirmationCard(app: trashApp, model: model)
                    .id(trashApp.id)
                    .zIndex(3)
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity))
            }
        }
        .animation(backdropMotion(opening: isModal), value: model.pendingTrashAppID)
        // The app was trashed or uninstalled meanwhile: drop the request (the key monitor swallows
        // typing while one is pending).
        .onChange(of: model.pendingTrashAppID != nil && trashApp == nil) { _, stale in
            if stale { model.pendingTrashAppID = nil }
        }
        .frame(width: GridMetrics.panelWidth, height: GridMetrics.panelHeight)
        .onKeyPress(.escape) {
            // Esc cancels a tab rename, then closes an open folder; otherwise let it through to the
            // shell (closes panel). An open trash card is dismissed before anything else.
            if model.pendingTrashAppID != nil {
                // While the system is trashing, the card stays so its result is seen.
                if !model.isTrashing { model.pendingTrashAppID = nil }
                return .handled
            }
            if model.renamingCategoryID != nil {
                NotificationCenter.default.post(name: .menuFoldCategoryEscape, object: nil)
                return .handled
            }
            guard model.openFolderID != nil else { return .ignored }
            NotificationCenter.default.post(name: .menuFoldFolderEscape, object: nil)
            withAnimation(reduceMotion ? Theme.crossfade : Theme.folderClose) {
                model.openFolderID = nil
            }
            return .handled
        }
        .onChange(of: model.openFolderID) { _, id in
            // Folder dissolved while open (e.g. last app dragged out) → nothing to show.
            if let id, model.folder(id: id) == nil { model.openFolderID = nil }
        }
    }

    /// Opaque in the middle, fading to clear over `edgeFade` at the top and bottom.
    private var edgeFadeMask: some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.edgeFade)
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.edgeFade)
        }
    }
}

#Preview {
    MenuFoldRootView(model: .preview)
        .background(.regularMaterial)
}

import AppKit
import MenuFoldCore
import SwiftUI

/// iPhone-style expanded folder over the grid.
///
/// The Liquid Glass surface carries the folder's `matchedGeometryEffect` id, so on open it grows out
/// of the tile's artwork and on close shrinks back into it. The folder's contents are laid out once
/// at full size and scaled with the surface (clipped to it), the way iOS folders do; their opacity
/// follows the scale, so whoever opens or closes the folder (tile, Esc, backdrop, panel) gets the
/// same motion. The blur and dim of the grid behind are drawn by `MenuFoldRootView`.
struct FolderOverlayView: View {
    let folder: Folder
    @Bindable var model: GridModel
    var namespace: Namespace.ID?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var name = ""
    @State private var isBackdropTargeted = false
    @State private var iconsShown = false
    @State private var isTitleHovered = false
    @FocusState private var titleFocused: Bool

    private let columns = Array(
        repeating: SwiftUI.GridItem(.fixed(GridMetrics.tileWidth), spacing: 4),
        count: GridMetrics.folderColumns
    )

    var body: some View {
        ZStack {
            backdrop
            container
        }
        .onAppear {
            name = folder.name
            iconsShown = true
            startRenameIfRequested()
        }
        .onChange(of: model.renamingFolderID) { startRenameIfRequested() }
        .onChange(of: titleFocused) { _, focused in
            if !focused { commitName() }
        }
        .onChange(of: folder.name) { _, newName in
            if !titleFocused { name = newName }
        }
        .onDisappear(perform: commitName)
        // Esc closes the folder (root view or panel `onCancel`); posted just before the close,
        // so a title being edited is reverted instead of committed by the unfocus/disappear handlers.
        .onReceive(NotificationCenter.default.publisher(for: .menuFoldFolderEscape)) { _ in
            if titleFocused { revertName() }
        }
    }

    // MARK: Backdrop

    /// Click target and drop zone over the (blurred) grid; the dim itself lives in the root view.
    private var backdrop: some View {
        Rectangle()
            .fill(Color.black.opacity(isBackdropTargeted ? 0.12 : 0.001))
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .appDropDestination { isBackdropTargeted = $0 } perform: { id in
                guard model.folderContaining(appID: id)?.id == folder.id else { return false }
                withAnimation(Theme.content) { model.removeFromFolder(id) }
                return true
            }
            .animation(Theme.snappy, value: isBackdropTargeted)
    }

    // MARK: Container

    private var container: some View {
        let shape = FolderSurfaceShape()
        return shape
            .fill(.clear)
            .glassEffect(.regular.tint(folder.color.color.opacity(0.15)), in: shape)
            .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
            .overlay {
                // Scale factor of the morphing surface relative to its resting size.
                GeometryReader { geo in
                    let scale = min(
                        geo.size.width / GridMetrics.folderWidth,
                        geo.size.height / GridMetrics.folderHeight,
                        1
                    )
                    content
                        .frame(width: GridMetrics.folderWidth, height: GridMetrics.folderHeight)
                        .scaleEffect(scale)
                        .opacity(Double(min(max((scale - 0.3) / 0.45, 0), 1)))
                        .frame(width: geo.size.width, height: geo.size.height)
                }
                .clipShape(shape)
            }
            .contentShape(shape)
            .onTapGesture { titleFocused = false }
            .matchedGeometry(
                id: FolderGeometryID.container(folder.id),
                in: reduceMotion ? nil : namespace
            )
            .frame(width: GridMetrics.folderWidth, height: GridMetrics.folderHeight)
    }

    private var content: some View {
        let apps = model.apps(in: folder)
        return VStack(spacing: 14) {
            title
                .frame(height: 40)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 10) {
                        // Identified by the selection id ("app:…"), so `scrollTo` finds the tile.
                        ForEach(Array(apps.enumerated()), id: \.element.id) { index, app in
                            AppIconView(app: app, model: model, insideFolder: true)
                                .id(MenuFoldCore.GridItem.app(app).id)
                                .scaleEffect(iconsShown || reduceMotion ? 1 : 0.8)
                                .opacity(iconsShown ? 1 : 0)
                                .animation(staggered(index), value: iconsShown)
                        }
                    }
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.automatic)
                .autoScrollsWhileDragging()
                .onChange(of: model.selectedItemID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : Theme.snappy) { proxy.scrollTo(id) }
                }
            }

            if !apps.isEmpty {
                Text("Перетягніть програму за межі папки, щоб вийняти її")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.top, 18)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    /// Icons pop in one after another: 0.15 s each, start offsets capped so the whole run ≤ 0.25 s.
    private func staggered(_ index: Int) -> Animation {
        .easeOut(duration: 0.15).delay(0.04 + min(Double(index) * 0.012, 0.06))
    }

    // MARK: Title

    @ViewBuilder
    private var title: some View {
        if folder.isFinder {
            // Mirrors a real folder on disk: the name is read-only.
            HStack(spacing: 8) {
                Text(folder.name)
                    .font(Theme.headerFont)
                    .fontDesign(.rounded)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Label("з Finder", systemImage: "macwindow")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                    .fixedSize()
            }
            .padding(.horizontal, 40)
            .help(folder.finderPath ?? "")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Папка \(folder.name), з Finder")
            .accessibilityHint(folder.finderPath ?? "")
        } else {
            editableTitle
        }
    }

    /// Looks like plain text; a glass capsule appears behind it on hover or while editing.
    private var editableTitle: some View {
        let showsCapsule = isTitleHovered || titleFocused
        // A hidden Text sizes the field to its contents so the capsule hugs the name.
        return Text(name.isEmpty ? String(localized: "Назва папки") : name)
            .font(Theme.headerFont)
            .fontDesign(.rounded)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .hidden()
            .overlay {
                TextField("Назва папки", text: $name)
                    .textFieldStyle(.plain)
                    .font(Theme.headerFont)
                    .fontDesign(.rounded)
                    .multilineTextAlignment(.center)
                    .focused($titleFocused)
                    .onSubmit {
                        commitName()
                        titleFocused = false
                    }
            }
            .frame(minWidth: 80, maxWidth: 440)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .glassEffect(showsCapsule ? .regular : .identity, in: .capsule)
            .contentShape(.capsule)
            .onHover { isTitleHovered = $0 }
            .animation(Theme.snappy, value: showsCapsule)
            .help("Назва папки. Enter — зберегти, Esc — скасувати.")
            .accessibilityLabel("Назва папки")
            .accessibilityHint("Enter зберігає нову назву, Esc повертає попередню")
    }

    // MARK: Actions

    private func startRenameIfRequested() {
        guard model.renamingFolderID == folder.id else { return }
        model.renamingFolderID = nil
        guard !folder.isFinder else { return }
        // Wait for the overlay to be in the window before taking focus.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            // The folder may be gone within the wait (dissolved, Esc): do not focus the removed field.
            guard model.openFolderID == folder.id else { return }
            titleFocused = true
        }
    }

    private func commitName() {
        guard !folder.isFinder else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let current = model.folder(id: folder.id) else { return }
        if trimmed.isEmpty {
            name = current.name
        } else if trimmed != current.name {
            model.rename(folder: folder.id, to: trimmed)
        }
    }

    private func revertName() {
        name = model.folder(id: folder.id)?.name ?? folder.name
    }

    private func close() {
        commitName()
        withAnimation(reduceMotion ? Theme.crossfade : Theme.folderClose) {
            model.openFolderID = nil
        }
    }
}

/// Rounded rect whose corner radius follows its size: `Theme.folderCorner` at full size, the tile
/// artwork's ratio (0.23 of the side, see `FolderArtwork`) when small. So the morph between the
/// tile and the open folder keeps a matching outline at both ends.
private struct FolderSurfaceShape: Shape {
    func path(in rect: CGRect) -> Path {
        let radius = min(Theme.folderCorner, min(rect.width, rect.height) * 0.23)
        return RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: rect)
    }
}

#Preview {
    let model = GridModel.preview
    if let folder = model.layout.folders.first {
        FolderOverlayView(folder: folder, model: model)
            .frame(width: GridMetrics.panelWidth, height: GridMetrics.panelHeight)
            .background(.regularMaterial)
    }
}

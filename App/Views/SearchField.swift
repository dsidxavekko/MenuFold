import AppKit
import MenuFoldCore
import SwiftUI

/// Search field at the top of the panel. Focused on appear and whenever the query is reset;
/// Enter acts on the first result. While a folder is open the field is disabled and unfocused,
/// so typing can't change the hidden query and Enter can't launch a grid app.
/// Settings open from the app menu (⌘,) or the Dock icon's menu, not from the panel.
struct SearchField: View {
    @Bindable var model: GridModel
    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isDisabled: Bool { model.openFolderID != nil }
    /// A dragged tile carries its file URL, which an editable field would paste as text; a disabled
    /// field refuses the drop, so the field is disabled (without dimming) while a tile is dragged.
    private var isDraggingApp: Bool { AppDragSession.shared.appID != nil }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20))
                .foregroundStyle(isFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .accessibilityHidden(true)
            TextField("Пошук", text: $model.query)
                .textFieldStyle(.plain)
                .font(Theme.headerFont)
                .focused($isFocused)
                .disabled(isDisabled || isDraggingApp)
                .onSubmit(launchFirst)
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Очистити")
                .accessibilityLabel("Очистити пошук")
                .transition(
                    reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity)
                )
            }
            if let version = Updater.shared.availableUpdateVersion {
                UpdatePill(version: version)
                    .transition(
                        reduceMotion ? .opacity : .scale(scale: 0.6, anchor: .trailing).combined(with: .opacity)
                    )
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.searchHeight)
        .glassEffect(
            .regular.tint(isFocused ? Color.accentColor.opacity(0.10) : nil),
            in: .capsule
        )
        .overlay {
            // Subtle focus ring, drawn inside the capsule so nothing is clipped by the panel.
            Capsule()
                .strokeBorder(Color.accentColor.opacity(isFocused ? 0.5 : 0), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .opacity(isDisabled ? 0.6 : 1)
        .animation(Theme.snappy, value: model.query.isEmpty)
        .animation(Theme.snappy, value: isFocused)
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: Updater.shared.availableUpdateVersion)
        .onAppear(perform: focusSoon)
        .onChange(of: model.query) { _, query in
            if query.isEmpty, model.openFolderID == nil { isFocused = true }
        }
        .onChange(of: isDraggingApp) { _, dragging in
            if !dragging { focusSoon() }
        }
        .onChange(of: model.openFolderID) { _, id in
            if id == nil { focusSoon() } else { isFocused = false }
        }
        // A category tab finished its inline rename: typing goes back to search.
        .onChange(of: model.renamingCategoryID) { _, id in
            if id == nil { focusSoon() }
        }
        // Panel re-shown (query may already be empty, so onChange wouldn't fire).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            // Only the panel matters: another window (Settings) must not steal the focus from a
            // hidden panel's field.
            guard note.object is NSPanel, model.openFolderID == nil else { return }
            focusSoon()
        }
    }

    private func focusSoon() {
        Task { @MainActor in
            if model.openFolderID == nil { isFocused = true }
        }
    }

    /// Enter acts on the first ranked result, like a click on it: an app launches, a folder opens
    /// (same morph as its tile), and with no app or folder the first System Settings pane opens.
    private func launchFirst() {
        guard model.openFolderID == nil else { return }
        switch model.visibleItems.first {
        case .app(let app):
            model.launch(app)
        case .folder(let folder, _):
            withAnimation(reduceMotion ? Theme.crossfade : Theme.morph) { model.openFolderID = folder.id }
        case nil:
            if let pane = model.settingsPaneResults.first { model.openSettingsPane(pane) }
        }
    }
}

#Preview {
    SearchField(model: .preview)
        .padding()
        .frame(width: GridMetrics.panelWidth)
}

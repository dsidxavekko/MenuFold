import AppKit
import MenuFoldCore
import SwiftUI

/// Search field at the top of the panel. Focused on appear and whenever the query is reset;
/// Enter launches the first visible app. While a folder is open the field is disabled and unfocused,
/// so typing can't change the hidden query and Enter can't launch a grid app.
/// A glass gear button sits at the right of the row and opens the Settings scene.
struct SearchField: View {
    @Bindable var model: GridModel
    /// Opens Settings; nil hides the button (previews, or a shell without a Settings scene).
    var onOpenSettings: (() -> Void)?
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
            if let onOpenSettings {
                // Tab order: the search field comes first, so the gear never steals focus on open.
                // Only the glyph is hit-testable (`.plain`), so Tab never lands on it by accident
                // before the query is typed — it is still reachable with Tab afterwards.
                SettingsButton(action: onOpenSettings)
                    .disabled(isDisabled)
                    .opacity(isDisabled ? 0 : 1)
                    .allowsHitTesting(!isDisabled)
                    .accessibilityHidden(isDisabled)
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
        // Panel re-shown (query may already be empty, so onChange wouldn't fire).
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if model.openFolderID == nil { focusSoon() }
        }
    }

    private func focusSoon() {
        Task { @MainActor in
            if model.openFolderID == nil { isFocused = true }
        }
    }

    private func launchFirst() {
        guard model.openFolderID == nil else { return }
        for item in model.visibleItems {
            if case .app(let app) = item {
                model.launch(app)
                return
            }
        }
    }
}

/// Icon-only gear button: opens the Settings scene through the responder chain.
/// On macOS 26 SwiftUI's Settings scene installs `showSettingsWindow:`; older builds used
/// `showPreferencesWindow:`. Sending the action through the chain (rather than calling
/// `NSApp.sendAction` with a hard-coded target) lets SwiftUI route it to the scene's handler.
struct SettingsButton: View {
    let action: () -> Void

    @State private var isHovered = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            Image(systemName: "gearshape")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isHovered ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 26, height: 26)
                .contentShape(Circle())
                // Reduce Motion: the glass appears instantly instead of easing in.
                .glassEffect(isHovered ? .regular.interactive() : .identity, in: .circle)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : Theme.snappy, value: isHovered)
        .help("Налаштування")
        .accessibilityLabel("Налаштування")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    SearchField(model: .preview, onOpenSettings: {})
        .padding()
        .frame(width: GridMetrics.panelWidth)
}

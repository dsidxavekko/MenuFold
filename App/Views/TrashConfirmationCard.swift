import AppKit
import MenuFoldCore
import SwiftUI

/// In-panel "move to Trash" confirmation for `model.pendingTrashAppID` (an alert or sheet would take
/// key status and close the panel). `MenuFoldRootView` draws the dim/blur behind it and cancels on a
/// click outside. Return runs the default button (posted by the panel's key monitor as
/// `.menuFoldTrashConfirm`, since the search field would otherwise eat it); Esc cancels.
///
/// States: running → "quit first" with a Завершити button; otherwise the confirmation; after a
/// failure → the system's message with Показати у Finder.
struct TrashConfirmationCard: View {
    let app: AppEntry
    @Bindable var model: GridModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBusy = false
    @State private var isQuitting = false
    @State private var errorMessage: String?

    private var isRunning: Bool { RunningAppsMonitor.shared.isRunning(app.id) }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: IconCache.shared.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: GridMetrics.iconSize, height: GridMetrics.iconSize)
                .accessibilityHidden(true)

            Text("Перемістити «\(app.name)» у Кошик?")
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            message
                .font(.callout)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button("Скасувати", action: cancel)
                    .buttonStyle(.glass)
                    .keyboardShortcut(.cancelAction)
                primaryButton
            }
            .controlSize(.large)
            .disabled(isBusy)
        }
        .padding(22)
        .frame(width: Theme.cardWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardCorner, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 22, y: 8)
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: isRunning)
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: errorMessage)
        .onChange(of: isRunning) { _, running in
            if !running { isQuitting = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .menuFoldTrashConfirm)) { _ in
            primaryAction()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    @ViewBuilder
    private var message: some View {
        if let errorMessage {
            Text(errorMessage).foregroundStyle(.red)
        } else if isRunning {
            Text("Спершу завершіть програму.").foregroundStyle(.secondary)
        } else {
            Text("Її можна буде повернути з Кошика.").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var primaryButton: some View {
        if errorMessage != nil {
            Button("Показати у Finder", action: primaryAction)
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.defaultAction)
        } else if isRunning {
            Button(action: primaryAction) {
                HStack(spacing: 6) {
                    if isQuitting { ProgressView().controlSize(.small) }
                    Text("Завершити")
                }
            }
            .buttonStyle(.glassProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(isQuitting)
        } else {
            Button(role: .destructive, action: primaryAction) {
                HStack(spacing: 6) {
                    if isBusy { ProgressView().controlSize(.small) }
                    Text("Перемістити")
                }
            }
            .buttonStyle(.glassProminent)
            .tint(.red)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func primaryAction() {
        guard !isBusy else { return }
        if errorMessage != nil {
            model.revealInFinder(app)
        } else if isRunning {
            quit()
        } else {
            moveToTrash()
        }
    }

    private func quit() {
        guard !isQuitting else { return }
        isQuitting = true
        RunningAppsMonitor.shared.quit(app.id)
        // The app may refuse (unsaved documents): offer the button again after a while.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            isQuitting = false
        }
    }

    private func moveToTrash() {
        isBusy = true
        Task { @MainActor in
            do {
                try await model.moveToTrash(app)
                // Only close this card, never one opened for another app meanwhile.
                if model.pendingTrashAppID == app.id { model.pendingTrashAppID = nil }
            } catch TrashError.running {
                // Started meanwhile: the card shows the "quit first" state by itself.
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func cancel() {
        model.pendingTrashAppID = nil
    }
}

#Preview {
    let model = GridModel.preview
    if let app = model.apps.first {
        TrashConfirmationCard(app: app, model: model)
            .padding(40)
            .background(.regularMaterial)
    }
}

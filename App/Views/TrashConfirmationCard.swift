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
///
/// Uninstaller: the app's support files in ~/Library (`GridModel.leftovers(for:)`) are looked up
/// after the card is on screen and offered as a checkbox (on by default) with a list of the paths,
/// so the user sees exactly what else goes to the Trash.
struct TrashConfirmationCard: View {
    let app: AppEntry
    @Bindable var model: GridModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBusy = false
    @State private var isQuitting = false
    @State private var errorMessage: String?
    /// Support files found for the app; nil while still looking.
    @State private var leftovers: [Leftover]?
    @State private var includesLeftovers = true
    @State private var showsLeftoverPaths = false

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

            if errorMessage == nil, !isRunning, let leftovers, !leftovers.isEmpty {
                leftoversSection(leftovers)
                    .transition(.opacity)
            }

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
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: leftovers)
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: showsLeftoverPaths)
        .task(id: app.id) { await findLeftovers() }
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

    private func leftoversSection(_ leftovers: [Leftover]) -> some View {
        let total = leftovers.reduce(Int64(0)) { $0 + max($1.size, 0) }
        let size = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Toggle(isOn: $includesLeftovers) {
                    Text("Також видалити файли підтримки (\(leftovers.count), \(size))")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                Spacer(minLength: 0)
                Button {
                    showsLeftoverPaths.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(showsLeftoverPaths ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(showsLeftoverPaths ? String(localized: "Сховати список") : String(localized: "Показати список"))
                .accessibilityLabel(showsLeftoverPaths ? String(localized: "Сховати список") : String(localized: "Показати список"))
            }
            if showsLeftoverPaths {
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(leftovers) { leftover in
                            Text((leftover.url.path as NSString).abbreviatingWithTildeInPath)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(leftover.url.path)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 110)
                .transition(.opacity)
            }
        }
        .disabled(isBusy)
    }

    /// Looks for support files once the card is shown, off the main actor (see below). It waits
    /// a moment first, so the card appears (and animates in) before the disk scan starts.
    private func findLeftovers() async {
        // Apps under /System can't be trashed at all; nothing to offer.
        guard !app.url.path.hasPrefix("/System/") else { leftovers = []; return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        // The same lookup as `model.leftovers(for:)`, but off the main actor: sizing a large
        // container or cache folder can take a while and must not freeze the panel.
        let others = Set(model.apps.map(\.id)).subtracting([app.id])
        let id = app.id, url = app.url
        let found = await Task.detached(priority: .userInitiated) {
            AppLeftovers().find(bundleID: id, appURL: url, otherBundleIDs: others)
        }.value
        guard !Task.isCancelled else { return }
        leftovers = found
        includesLeftovers = !found.isEmpty
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
                    Text("У Кошик")
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
                if includesLeftovers, let leftovers, !leftovers.isEmpty {
                    try await model.moveToTrash(app, leftovers: leftovers.map(\.url))
                } else {
                    try await model.moveToTrash(app)
                }
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

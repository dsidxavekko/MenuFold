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

    @Environment(\.menuFoldReduceMotion) private var reduceMotion
    @State private var isBusy = false
    @State private var isQuitting = false
    @State private var errorMessage: String?
    /// Dry run (app size + support files); nil while still counting.
    @State private var plan: UninstallPlan?
    @State private var includesLeftovers = true
    @State private var showsLeftoverPaths = false

    private var leftovers: [Leftover]? { plan?.leftovers }

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

            if errorMessage == nil, !isRunning, !app.url.path.hasPrefix("/System/") {
                sizeSummary
                    .transition(.opacity)
            }

            if errorMessage == nil, !isRunning, let plan, !plan.leftovers.isEmpty {
                leftoversSection(plan)
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
        .cardShadow()
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: isRunning)
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: errorMessage)
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: plan?.leftovers)
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

    /// "Програма: 120 MB · файли підтримки: 80 MB · Звільниться 200 MB" (with "≥" when some part
    /// could not be read), or a spinner while the counting runs.
    @ViewBuilder
    private var sizeSummary: some View {
        if let plan {
            let total = includesLeftovers ? plan.totalSize : plan.appSize
            VStack(spacing: 2) {
                Text("Програма: \(plan.appSize.formatted) · файли підтримки: \(plan.leftoversSize.formatted)")
                    .foregroundStyle(.secondary)
                Text("Звільниться \(total.formatted)")
                    .fontWeight(.medium)
            }
            .font(.callout)
            .monospacedDigit()
            .multilineTextAlignment(.center)
        } else {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Рахую розмір…").foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }

    private func title(for kind: LeftoverKind) -> String {
        switch kind {
        case .caches: String(localized: "Кеші")
        case .preferences: String(localized: "Налаштування")
        case .containers: String(localized: "Контейнери")
        case .other: String(localized: "Інше")
        }
    }

    private func leftoversSection(_ plan: UninstallPlan) -> some View {
        let leftovers = plan.leftovers
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Toggle(isOn: $includesLeftovers) {
                    Text("Також видалити файли підтримки (\(leftovers.count), \(plan.leftoversSize.formatted))")
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
                        ForEach(plan.groups) { group in
                            HStack {
                                Text(title(for: group.kind)).font(.caption.weight(.semibold))
                                Spacer(minLength: 4)
                                Text(group.size.formatted).font(.caption).monospacedDigit()
                            }
                            .foregroundStyle(.primary)
                            .padding(.top, 3)
                            ForEach(group.items) { leftover in
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
                }
                .frame(maxHeight: 130)
                .transition(.opacity)
            }
            if !plan.caches.isEmpty {
                // Frees space without uninstalling: the app stays, only its rebuildable caches go.
                Button(action: trashCachesOnly) {
                    Text("Очистити лише кеші (\(plan.caches.totalSize.formatted))")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.regular)
                .help(Text("Програма залишиться встановленою"))
            }
        }
        .disabled(isBusy)
    }

    /// Counts the app and its support files once the card is shown, off the main actor. It waits
    /// a moment first, so the card appears (and animates in) before the disk scan starts.
    private func findLeftovers() async {
        // Apps under /System can't be trashed at all; nothing to offer.
        guard !app.url.path.hasPrefix("/System/") else { plan = UninstallPlan(appSize: .zero, leftovers: []); return }
        try? await Task.sleep(for: .milliseconds(150))
        guard !Task.isCancelled else { return }
        let found = await model.uninstallPlan(for: app)
        guard !Task.isCancelled else { return }
        plan = found
        includesLeftovers = !found.leftovers.isEmpty
    }

    private func trashCachesOnly() {
        guard !isBusy, let caches = plan?.caches, !caches.isEmpty else { return }
        isBusy = true
        Task { @MainActor in
            do {
                try await model.moveLeftoversToTrash(of: app, caches.map(\.url))
                if model.pendingTrashAppID == app.id { model.pendingTrashAppID = nil }
            } catch {
                errorMessage = error.localizedDescription
            }
            isBusy = false
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

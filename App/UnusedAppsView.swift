import AppKit
import MenuFoldCore
import SwiftUI

/// Settings → Програми → "Давно не використовувані": apps not opened for a chosen period, with
/// their size on disk and a way to reveal or trash them.
///
/// The trash card of the panel can't be used here (the panel is closed while Settings is key), so
/// trashing confirms with an `NSAlert` instead; its checkbox also removes the app's support files.
struct UnusedAppsSection: View {
    let model: GridModel

    @State private var days = 90
    /// Dry-run plans (app size + support files) by app id, filled lazily as rows appear. The same
    /// `GridModel.uninstallPlan(for:)` the panel's trash card uses; counted off the main actor.
    @State private var plans: [String: UninstallPlan] = [:]
    /// Apps currently being trashed, so their buttons are disabled.
    @State private var trashing: Set<String> = []
    /// Apps whose support files are being looked up before the confirmation alert.
    @State private var scanning: Set<String> = []

    private static let periods = [30, 90, 180]

    var body: some View {
        Section {
            Picker("Не відкривалися понад", selection: $days) {
                ForEach(Self.periods, id: \.self) { d in
                    Text("\(d) днів").tag(d)
                }
            }
            let apps = model.unusedApps(olderThan: TimeInterval(days) * 86_400)
            if apps.isEmpty {
                Text("Таких програм немає")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(apps) { app in
                    row(app)
                }
            }
        } header: {
            Label("Давно не використовувані", systemImage: "hourglass")
        } footer: {
            Text("Дата останнього запуску береться з історії MenuFold і зі Spotlight. Системні програми не показано: їх не можна видалити.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(_ app: AppEntry) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: IconCache.shared.icon(for: app))
                .resizable()
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(lastUsedText(app))
                    if UsageLogger.shared.totalLaunches(of: app.id) > 0 {
                        Text(verbatim: "·")
                        Text("Запусків за рік: \(UsageLogger.shared.totalLaunches(of: app.id))")
                    }
                    if let plan = plans[app.id] {
                        Text(verbatim: "·")
                        Text(sizeText(plan))
                            .monospacedDigit()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
            Button("Показати у Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([app.url])
            }
            .buttonStyle(.glass)
            .controlSize(.small)
            if scanning.contains(app.id) {
                // The leftover scan can take seconds (large caches); show it instead of freezing.
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(Text("Пошук допоміжних файлів…"))
            }
            Button("У Кошик…", role: .destructive) { confirmTrash(app) }
                .buttonStyle(.glass)
                .tint(.red)
                .controlSize(.small)
                .disabled(trashing.contains(app.id) || scanning.contains(app.id))
        }
        .task(id: app.url) {
            guard plans[app.id] == nil else { return }
            let plan = await model.uninstallPlan(for: app)
            // A cancelled count (the row scrolled away) is only a lower bound: don't keep it.
            guard !Task.isCancelled else { return }
            plans[app.id] = plan
        }
    }

    /// "120 MB" or "120 MB + 80 MB файлів підтримки" ("≥" when some part could not be read).
    private func sizeText(_ plan: UninstallPlan) -> String {
        guard !plan.leftovers.isEmpty else { return plan.appSize.formatted }
        return String(localized: "\(plan.appSize.formatted) + \(plan.leftoversSize.formatted) файлів підтримки")
    }

    private func lastUsedText(_ app: AppEntry) -> String {
        guard let date = model.lastUsed(app) else { return String(localized: "Ніколи") }
        return date.formatted(.relative(presentation: .named))
    }

    /// Counts the app and its support files off the main actor first (reusing the row's plan when
    /// it is already there), then confirms.
    private func confirmTrash(_ app: AppEntry) {
        guard !scanning.contains(app.id) else { return }
        scanning.insert(app.id)
        let known = plans[app.id]
        Task {
            let plan: UninstallPlan
            if let known, !known.appSize.isLowerBound, !known.leftovers.contains(where: \.isLowerBound) { plan = known }
            else { plan = await model.uninstallPlan(for: app) }
            plans[app.id] = plan
            scanning.remove(app.id)
            confirmTrash(app, plan: plan)
        }
    }

    private func confirmTrash(_ app: AppEntry, plan: UninstallPlan) {
        let leftovers = plan.leftovers
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Перемістити «\(app.name)» у Кошик?")
        alert.informativeText = String(localized: "Програма: \(plan.appSize.formatted) · файли підтримки: \(plan.leftoversSize.formatted)")
            + "\n" + String(localized: "Програму можна буде повернути з Кошика, поки його не очищено.")
        if !leftovers.isEmpty {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = String(localized: "Також її допоміжні файли (\(leftovers.count), \(plan.leftoversSize.formatted))")
            alert.suppressionButton?.state = .on
        }
        alert.addButton(withTitle: String(localized: "У Кошик"))
        alert.addButton(withTitle: String(localized: "Скасувати"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let extra = alert.suppressionButton?.state == .on ? leftovers.map(\.url) : []

        trashing.insert(app.id)
        Task {
            defer { trashing.remove(app.id) }
            do {
                try await model.moveToTrash(app, leftovers: extra)
            } catch {
                SettingsAlerts.showError(error, title: String(localized: "Не вдалося перемістити в Кошик"))
            }
        }
    }
}

/// Settings → Програми → "Закріплені": the pinned row's apps in order, with move and unpin buttons.
/// Iterates `layout.pinned` (it keeps the ids of uninstalled and hidden apps, and its indices are
/// what `movePinned` moves) and looks each id up in `visiblePinnedApps`, the apps the row really
/// shows; `pinnedApps` would be empty unless the panel is on "Все". Ids that are not visible are
/// marked as hidden or not installed, so the list explains why the row in the panel is shorter.
struct PinnedAppsSection: View {
    let model: GridModel

    var body: some View {
        Section {
            let ids = model.layout.pinned
            if ids.isEmpty {
                Text("Немає закріплених програм")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(ids.enumerated()), id: \.element) { index, id in
                    row(id: id, index: index, count: ids.count)
                }
            }
        } header: {
            Label("Закріплені", systemImage: "pin")
        } footer: {
            Text("Програма закріплюється через її контекстне меню: «Закріпити». Закріплені програми стоять рядом над сіткою на вкладці «Все».")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func row(id: String, index: Int, count: Int) -> some View {
        let visible = model.visiblePinnedApps.first { $0.id == id }
        let hiddenApp = visible == nil ? model.apps.first { $0.id == id } : nil
        return HStack(spacing: 8) {
            if let app = visible {
                Image(nsImage: IconCache.shared.icon(for: app))
                    .resizable()
                    .frame(width: 24, height: 24)
                Text(app.name)
            } else if let app = hiddenApp {
                Image(nsImage: IconCache.shared.icon(for: app))
                    .resizable()
                    .frame(width: 24, height: 24)
                    .opacity(0.5)
                VStack(alignment: .leading, spacing: 1) {
                    Text(app.name)
                        .lineLimit(1)
                    Text("Приховано")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Image(systemName: "questionmark.app.dashed")
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(id)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("Не встановлено")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                model.movePinned(id, by: -1)
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .help(Text("Вище"))
            .accessibilityLabel(Text("Вище"))
            Button {
                model.movePinned(id, by: 1)
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == count - 1)
            .help(Text("Нижче"))
            .accessibilityLabel(Text("Нижче"))
            Button("Відкріпити") { model.unpin(id) }
        }
        .buttonStyle(.glass)
        .controlSize(.small)
    }
}

/// Modal alerts used by the Settings tabs (the panel is closed while Settings is key, so an
/// app-modal alert is the natural place for errors and confirmations).
@MainActor
enum SettingsAlerts {
    static func showError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: String(localized: "OK"))
        alert.runModal()
    }

    /// Returns true when the user chose the first (confirming) button.
    static func confirm(_ title: String, message: String, confirm: String, destructive: Bool = false) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = destructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: confirm)
        alert.addButton(withTitle: String(localized: "Скасувати"))
        if destructive { alert.buttons.first?.hasDestructiveAction = true }
        return alert.runModal() == .alertFirstButtonReturn
    }
}

#Preview {
    Form {
        UnusedAppsSection(model: .preview)
        PinnedAppsSection(model: .preview)
    }
    .formStyle(.grouped)
    .frame(width: 560, height: 600)
}

import AppKit
import MenuFoldCore
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: GridModel

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var confirmReset = false
    /// Layout-file health, refreshed when the window appears and after a reset.
    @State private var layoutHealth = LayoutHealth.ok

    var body: some View {
        Form {
            if layoutHealth.isWarning {
                layoutWarning
            }

            Section {
                Toggle("Відкривати при вході", isOn: Binding(
                    get: { launchAtLogin },
                    set: { setLaunchAtLogin($0) }
                ))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Потрібно дозволити в Системних параметрах.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Відкрити") { SMAppService.openSystemSettingsLoginItems() }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                    }
                    .font(.callout)
                }
                if let loginError {
                    Text(loginError)
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            } header: {
                Label("Загальне", systemImage: "gearshape")
            }
            Section {
                let hidden = model.hiddenApps
                if hidden.isEmpty {
                    Text("Немає прихованих програм")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hidden) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.shared.icon(for: app.url))
                                .resizable()
                                .frame(width: 24, height: 24)
                            Text(app.name)
                            Spacer()
                            Button("Показати") { model.unhide(app.id) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Label("Приховані програми", systemImage: "eye.slash")
            }

            Section {
                let ignored = model.ignoredFinderFolders
                if ignored.isEmpty {
                    Text("Усі папки з Finder показано")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(ignored) { ref in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ref.name)
                                Text(ref.id)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("Показати знову") { model.restoreFinderFolder(path: ref.id) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Label("Папки з Finder", systemImage: "folder")
            } footer: {
                Text("Підпапки в «Програмах» у Finder автоматично з’являються в MenuFold як папки. Програми можна додавати й виймати перетягуванням — файли на диску при цьому не переміщуються. Назва береться з Finder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button("Скинути розкладку…", role: .destructive) { confirmReset = true }
                    .buttonStyle(.glass)
                    .tint(.red)
                    .confirmationDialog(
                        "Скинути розкладку?",
                        isPresented: $confirmReset,
                        titleVisibility: .visible
                    ) {
                        Button("Скинути", role: .destructive) { resetLayout() }
                        Button("Скасувати", role: .cancel) {}
                    } message: {
                        Text("Усі папки, перевизначені категорії та приховані програми буде видалено.")
                    }
            } header: {
                Label("Розкладка", systemImage: "square.grid.3x3")
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .frame(minHeight: 380)
        .onAppear {
            refreshLoginStatus()
            refreshLayoutHealth()
        }
    }

    /// Warning row shown when the layout file could not be used (corrupt, unreadable, newer schema).
    /// Purely informational: it never writes to disk, it only points at the file that was set aside.
    private var layoutWarning: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(layoutHealth.message)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = layoutHealth.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                Spacer(minLength: 0)
            }
            if layoutHealth.fileToReveal != nil {
                Button("Показати у Finder") { LayoutHealthActions.reveal(layoutHealth) }
                    .buttonStyle(.glass)
                    .controlSize(.small)
            }
        } header: {
            Label("Розкладка пошкоджена", systemImage: "exclamationmark.triangle")
        } footer: {
            Text("Розкладка починається з чистої — папки, категорії та приховані програми доведеться налаштувати знову. Попередній файл не видалено: його можна вивчити або відновити вручну.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refreshLayoutHealth() {
        layoutHealth = LayoutHealth.current(model: model)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            loginError = "Не вдалося змінити: \(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    private func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
        launchAtLogin = loginStatus == .enabled || loginStatus == .requiresApproval
    }

    /// Resets the layout, then re-checks the file: a successful save clears a previous warning.
    private func resetLayout() {
        model.resetLayout()
        refreshLayoutHealth()
    }
}

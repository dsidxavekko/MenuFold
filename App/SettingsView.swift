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

    var body: some View {
        Form {
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
                        Button("Скинути", role: .destructive) { model.resetLayout() }
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
        .onAppear(perform: refreshLoginStatus)
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
}

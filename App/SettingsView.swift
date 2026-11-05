import AppKit
import MenuFoldCore
import ServiceManagement
import SwiftUI

/// Content of one Settings tab. `SettingsWindowController` hosts one instance per tab.
struct SettingsView: View {
    let model: GridModel
    let tab: SettingsTab

    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var confirmReset = false
    /// Layout-file health, refreshed when the window appears and after a reset.
    @State private var layoutHealth = LayoutHealth.ok
    @State private var dockIcon = DockIconStyle.current
    @State private var dockIconWriteFailed = false
    /// Bumped when the custom Dock picture changes, so its preview redraws.
    @State private var dockIconRevision = 0
    @State private var showsFrequent = UserDefaults.standard.object(forKey: AppDelegate.showsFrequentKey) as? Bool ?? true
    @State private var showsRunningTab = UserDefaults.standard.object(forKey: AppDelegate.showsRunningTabKey) as? Bool ?? true
    @State private var autoChecksUpdates = Updater.shared.automaticallyChecks
    @State private var autoDownloadsUpdates = Updater.shared.automaticallyDownloads
    @State private var lastUpdateCheck = Updater.shared.lastCheckDate

    var body: some View {
        Group {
            switch tab {
            case .general: generalTab
            case .categories: categoriesTab
            case .apps: appsTab
            case .about: AboutView()
            }
        }
        .onAppear {
            refreshLoginStatus()
            refreshLayoutHealth()
            autoChecksUpdates = Updater.shared.automaticallyChecks
            autoDownloadsUpdates = Updater.shared.automaticallyDownloads
            lastUpdateCheck = Updater.shared.lastCheckDate
        }
    }

    // MARK: Вкладки

    private var generalTab: some View {
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
                Label("Запуск", systemImage: "power")
            } footer: {
                Text("MenuFold відкривається кліком по його значку в Dock. Права кнопка на значку — налаштування та інформація про програму.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack(spacing: 8) {
                    ForEach(DockIconStyle.available) { style in
                        DockIconChoice(style: style, isSelected: dockIcon == style, revision: dockIconRevision) {
                            if style == .custom && !DockIconStyle.hasCustomImage {
                                chooseCustomDockIcon()
                            } else {
                                dockIcon = style
                                dockIconWriteFailed = !DockIconStyle.select(style)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                if dockIcon == .custom {
                    HStack {
                        Text("Своє зображення або значок іншої програми.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Вибрати інше…") { chooseCustomDockIcon() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    .font(.callout)
                }
                if dockIconWriteFailed {
                    HStack {
                        Text("macOS не дозволила змінити значок самої програми, тому він зміниться лише поки MenuFold запущено. Дозвольте MenuFold у розділі «Керування програмами».")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("Відкрити") { openAppManagementSettings() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                    .font(.callout)
                }
            } header: {
                Label("Значок у Dock", systemImage: "dock.rectangle")
            }

            Section {
                Toggle("Показувати часті програми", isOn: Binding(
                    get: { showsFrequent },
                    set: { on in
                        showsFrequent = on
                        UserDefaults.standard.set(on, forKey: AppDelegate.showsFrequentKey)
                        model.showsFrequent = on
                    }
                ))
                HStack {
                    Text("Ряд над сіткою на вкладці «Все».")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Очистити історію запусків") { model.clearUsage() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                .font(.callout)
            } header: {
                Label("Часті", systemImage: "clock.arrow.circlepath")
            }

            if Updater.shared.isEnabled {
                updatesSection
            }

            Section {
                HStack {
                    Text("Розкладка зберігається у файлі layout.json")
                    Spacer()
                    Button("Показати у Finder") { revealLayoutFolder() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
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
                        Text("Усі папки, власні й перевизначені категорії, власні значки та приховані програми буде видалено.")
                    }
            } header: {
                Label("Розкладка", systemImage: "square.grid.3x3")
            }
        }
        .formStyle(.grouped)
    }

    private var updatesSection: some View {
        Section {
            Toggle("Перевіряти оновлення автоматично", isOn: Binding(
                get: { autoChecksUpdates },
                set: { on in
                    autoChecksUpdates = on
                    Updater.shared.automaticallyChecks = on
                }
            ))
            Toggle("Завантажувати й установлювати самостійно", isOn: Binding(
                get: { autoDownloadsUpdates },
                set: { on in
                    autoDownloadsUpdates = on
                    Updater.shared.automaticallyDownloads = on
                }
            ))
            .disabled(!autoChecksUpdates)
            HStack {
                Group {
                    if let lastUpdateCheck {
                        Text("Остання перевірка: \(lastUpdateCheck.formatted(date: .abbreviated, time: .shortened))")
                    } else {
                        Text("Ще не перевірялося.")
                    }
                }
                .foregroundStyle(.secondary)
                Spacer()
                Button("Перевірити зараз") {
                    Updater.shared.checkForUpdates()
                    lastUpdateCheck = Updater.shared.lastCheckDate
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .font(.callout)
        } header: {
            Label("Оновлення", systemImage: "arrow.triangle.2.circlepath")
        } footer: {
            Text("MenuFold раз на день звертається до GitHub, щоб дізнатися, чи вийшла нова версія. Інших даних він не надсилає.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var categoriesTab: some View {
        Form {
            Section {
                Toggle("Показувати вкладку «Запущені»", isOn: Binding(
                    get: { showsRunningTab },
                    set: { on in
                        showsRunningTab = on
                        UserDefaults.standard.set(on, forKey: AppDelegate.showsRunningTabKey)
                        model.showsRunningTab = on
                    }
                ))
            } footer: {
                Text("Програми, які зараз відкриті. Вкладка стоїть одразу після «Все».")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                let custom = model.customCategories
                if custom.isEmpty {
                    Text("Немає власних категорій")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(custom) { category in
                        CustomCategoryRow(model: model, category: category)
                    }
                }
                HStack {
                    Button("Додати категорію") { model.createCategory() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    Spacer()
                    if model.hasCustomCategoryOrder {
                        Button("Скинути порядок вкладок") { model.resetCategoryOrder() }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                    }
                }
            } header: {
                Label("Мої категорії", systemImage: "tag")
            } footer: {
                Text("Власні категорії з’являються вкладками в MenuFold. Програму можна додати через її контекстне меню: «Змінити категорію». Після видалення категорії її програми повертаються до автоматичних категорій. Порядок вкладок змінюється перетягуванням у панелі.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var appsTab: some View {
        Form {
            Section {
                let hidden = model.hiddenApps
                if hidden.isEmpty {
                    Text("Немає прихованих програм")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(hidden) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.shared.icon(for: app))
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
                let custom = model.appsWithCustomIcons
                if custom.isEmpty {
                    Text("Немає власних значків")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(custom) { app in
                        HStack(spacing: 8) {
                            Image(nsImage: IconCache.shared.icon(for: app))
                                .resizable()
                                .frame(width: 24, height: 24)
                            Text(app.name)
                            Spacer()
                            Button("Змінити…") { CustomIconPicker.choose(for: app, model: model) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            Button("Стандартний") { model.resetCustomIcon(for: app.id) }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                        }
                    }
                }
            } header: {
                Label("Власні значки", systemImage: "photo")
            } footer: {
                Text("Значок програми змінюється через її контекстне меню: «Змінити значок…». Підійде будь-яке зображення або інша програма. Файли програм не змінюються.")
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
        }
        .formStyle(.grouped)
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

    /// Opens the folder that holds layout.json (created on the first save, so it may not exist yet).
    private func revealLayoutFolder() {
        let file = LayoutStore.defaultURL
        let dir = file.deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else if FileManager.default.fileExists(atPath: dir.path) {
            NSWorkspace.shared.open(dir)
        } else {
            NSWorkspace.shared.open(dir.deletingLastPathComponent())
        }
    }

    /// System Settings → Privacy & Security → App Management.
    private func openAppManagementSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles") {
            NSWorkspace.shared.open(url)
        }
    }

    private func refreshLayoutHealth() {
        layoutHealth = LayoutHealth.current(model: model)
    }

    private func chooseCustomDockIcon() {
        guard let url = CustomIconPicker.pickFile(title: String(localized: "Значок MenuFold у Dock")) else { return }
        do {
            dockIconWriteFailed = !(try DockIconStyle.setCustomImage(from: url))
            dockIcon = .custom
            dockIconRevision += 1
        } catch {
            CustomIconPicker.showError(error)
        }
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
            loginError = String(localized: "Не вдалося змінити: \(error.localizedDescription)")
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

/// A selectable Dock icon in Settings: the icon itself with its name underneath.
private struct DockIconChoice: View {
    let style: DockIconStyle
    let isSelected: Bool
    /// Changes when the custom picture is replaced; part of the view's input, so it redraws.
    let revision: Int
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                Image(nsImage: style.image)
                    .resizable()
                    .frame(width: 56, height: 56)
                    .foregroundStyle(.secondary)
                Text(style.title)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                    .lineLimit(2, reservesSpace: true)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: 92)
            .padding(.horizontal, 6)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Значок у Dock: \(style.title)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One custom category in Settings: an editable name (saved on Enter or when the field loses
/// focus), how many apps it holds, and a delete button.
private struct CustomCategoryRow: View {
    let model: GridModel
    let category: AppCategory

    @State private var name = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
                .frame(width: 24)
            // A grouped Form turns a TextField's title into a row label and right-aligns the value,
            // so hide the label and keep the title only as the empty-field prompt.
            TextField("Назва категорії", text: $name, prompt: Text("Назва категорії"))
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(save)
            Text(countLabel(model.apps(inCategory: category.id).count))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Видалити", role: .destructive) { model.deleteCategory(id: category.id) }
                .buttonStyle(.glass)
                .controlSize(.small)
        }
        .onAppear { name = category.displayName }
        .onChange(of: category.displayName) { _, newName in
            if !focused { name = newName }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { save() }
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            name = category.displayName
        } else {
            model.renameCategory(id: category.id, to: trimmed)
        }
    }

    /// "1 програма", "3 програми", "5 програм"; the plural forms live in the string catalog.
    private func countLabel(_ n: Int) -> String {
        String(localized: "\(n) програм", comment: "Number of apps in a category")
    }
}

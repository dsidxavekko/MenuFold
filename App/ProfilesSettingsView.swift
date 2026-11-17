import SwiftUI
import MenuFoldCore

/// Settings → Категорії: smart categories (rules) and profiles. Both are `Form` sections.

// MARK: - Smart categories

struct SmartRulesSection: View {
    let model: GridModel
    @State private var draft = SmartRuleDraft()

    var body: some View {
        Section {
            ForEach(model.smartRules) { rule in
                SmartRuleRow(model: model, rule: rule)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Нове правило")
                    .font(.subheadline.weight(.medium))
                SmartRuleFields(draft: $draft)
                HStack {
                    Spacer()
                    Button("Додати правило") {
                        if model.addSmartRule(draft.rule(id: nil)) != nil { draft = SmartRuleDraft() }
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(!draft.isValid)
                }
            }
        } header: {
            Label("Розумні категорії", systemImage: "sparkles")
        } footer: {
            Text("Програма потрапляє в розумну категорію, якщо виконано всі задані умови. Вкладка з’являється, лише коли в ній є програми. Категорія, яку ви вказали вручну, завжди важливіша; з кількох правил діє перше зверху.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// Editable copy of a `SmartRule` (text fields need strings).
struct SmartRuleDraft: Equatable {
    var name = ""
    var prefixes = ""
    var source: AppInstallSource?
    var sizeMB = ""
    var unusedDays = ""

    init() {}
    init(_ rule: SmartRule) {
        name = rule.name
        prefixes = rule.bundlePrefixes.joined(separator: ", ")
        source = rule.source
        sizeMB = rule.minSizeMB.map(String.init) ?? ""
        unusedDays = rule.unusedDays.map(String.init) ?? ""
    }

    func rule(id: String?) -> SmartRule {
        let list = prefixes.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        let size = Int(sizeMB.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        let days = Int(unusedDays.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil }
        if let id {
            return SmartRule(id: id, name: name, bundlePrefixes: list, source: source, minSizeMB: size, unusedDays: days)
        }
        return SmartRule(name: name, bundlePrefixes: list, source: source, minSizeMB: size, unusedDays: days)
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && rule(id: nil).hasCriteria
    }
}

private struct SmartRuleFields: View {
    @Binding var draft: SmartRuleDraft

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
            GridRow {
                Text("Назва")
                TextField("Назва", text: $draft.name, prompt: Text("Назва категорії")).labelsHidden()
            }
            GridRow {
                Text("Виробник")
                TextField("Виробник", text: $draft.prefixes, prompt: Text("com.adobe., com.microsoft.")).labelsHidden()
            }
            GridRow {
                Text("Джерело")
                Picker("Джерело", selection: $draft.source) {
                    Text("Будь-яке").tag(AppInstallSource?.none)
                    Text("App Store").tag(AppInstallSource?.some(.appStore))
                    Text("Homebrew Cask").tag(AppInstallSource?.some(.homebrew))
                    Text("Setapp").tag(AppInstallSource?.some(.setapp))
                }
                .labelsHidden()
            }
            GridRow {
                Text("Розмір від, МБ")
                TextField("Розмір від, МБ", text: $draft.sizeMB, prompt: Text("500")).labelsHidden()
            }
            GridRow {
                Text("Не запускали, днів")
                TextField("Не запускали, днів", text: $draft.unusedDays, prompt: Text("30")).labelsHidden()
            }
        }
    }
}

private struct SmartRuleRow: View {
    let model: GridModel
    let rule: SmartRule
    @State private var draft = SmartRuleDraft()
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                SmartRuleFields(draft: $draft)
                HStack {
                    Button("Угору") { model.moveSmartRule(id: rule.id, by: -1) }
                    Button("Униз") { model.moveSmartRule(id: rule.id, by: 1) }
                    Spacer()
                    Button("Зберегти") { model.updateSmartRule(draft.rule(id: rule.id)) }
                        .disabled(!draft.isValid || draft.rule(id: rule.id) == rule)
                    Button("Видалити", role: .destructive) { model.deleteSmartRule(id: rule.id) }
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(.secondary).frame(width: 24)
                Text(rule.name)
                Spacer()
                Text(String(localized: "\(model.apps(matching: rule).count) програм", comment: "Number of apps in a category"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = SmartRuleDraft(rule) }
        .onChange(of: rule) { _, new in draft = SmartRuleDraft(new) }
    }
}

// MARK: - Profiles

struct ProfilesSection: View {
    let model: GridModel
    @State private var newName = ""

    var body: some View {
        Section {
            Picker("Активний профіль", selection: Binding(
                get: { model.activeProfileID },
                set: { model.setActiveProfile($0) }
            )) {
                Text("Без профілю").tag(String?.none)
                ForEach(model.profiles) { Text($0.name).tag(String?.some($0.id)) }
            }
            ForEach(model.profiles) { profile in
                ProfileRow(model: model, profile: profile)
            }
            HStack {
                TextField("Назва профілю", text: $newName, prompt: Text("Робота, Дім, Ігри…")).labelsHidden()
                Button("Додати профіль") {
                    model.createProfile(named: newName)
                    newName = ""
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        } header: {
            Label("Профілі", systemImage: "person.crop.rectangle.stack")
        } footer: {
            Text("Профіль — це фільтр поверх ваших папок і категорій: можна приховати програми, закріпити свої та показати лише вибрані категорії. Перемикати профіль можна в меню значка в Dock або в рядку меню, посиланням menufold://profile?name=… і в Командах. Перемикання профілю не скасовується ⌘Z.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ProfileRow: View {
    let model: GridModel
    let profile: Profile
    @State private var name = ""
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    TextField("Назва профілю", text: $name).labelsHidden().onSubmit(saveName)
                    Button("Видалити", role: .destructive) { model.deleteProfile(id: profile.id) }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
                categoriesEditor
                Text("Приховані в профілі").font(.subheadline.weight(.medium))
                AppChecklist(model: model, selection: Binding(
                    get: { profile.hidden },
                    set: { var p = profile; p.hidden = $0; model.updateProfile(p) }
                ))
                Text("Закріплені в профілі").font(.subheadline.weight(.medium))
                AppChecklist(model: model, selection: Binding(
                    get: { Set(profile.pinned) },
                    set: { new in
                        var p = profile
                        p.pinned = p.pinned.filter(new.contains) + new.subtracting(p.pinned).sorted()
                        model.updateProfile(p)
                    }
                ))
            }
            .padding(.top, 4)
        } label: {
            HStack {
                Image(systemName: profile.id == model.activeProfileID ? "checkmark.circle.fill" : "person.crop.rectangle")
                    .foregroundStyle(profile.id == model.activeProfileID ? Color.accentColor : .secondary)
                    .frame(width: 24)
                Text(profile.name)
            }
        }
        .onAppear { name = profile.name }
        .onChange(of: profile.name) { _, new in name = new }
    }

    private func saveName() {
        var p = profile
        p.name = name
        model.updateProfile(p)
        name = model.profiles.first { $0.id == profile.id }?.name ?? profile.name
    }

    private var allCategories: [AppCategory] {
        AppCategory.known + [.other] + model.customCategories + model.smartRules.map(\.category)
    }

    private var categoriesEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Усі категорії", isOn: Binding(
                get: { profile.visibleCategories == nil },
                set: { all in
                    var p = profile
                    p.visibleCategories = all ? nil : Set(allCategories.map(\.id))
                    model.updateProfile(p)
                }
            ))
            if let visible = profile.visibleCategories {
                ForEach(allCategories) { category in
                    Toggle(category.displayName, isOn: Binding(
                        get: { visible.contains(category.id) },
                        set: { on in
                            var p = profile
                            if on { p.visibleCategories?.insert(category.id) } else { p.visibleCategories?.remove(category.id) }
                            model.updateProfile(p)
                        }
                    ))
                    .padding(.leading, 16)
                }
            }
        }
    }
}

/// A scrollable list of all apps with a checkbox each.
private struct AppChecklist: View {
    let model: GridModel
    @Binding var selection: Set<String>

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.apps) { app in
                    Toggle(isOn: Binding(
                        get: { selection.contains(app.id) },
                        set: { on in
                            if on { selection.insert(app.id) } else { selection.remove(app.id) }
                        }
                    )) {
                        HStack(spacing: 6) {
                            Image(nsImage: IconCache.shared.icon(for: app)).resizable().frame(width: 16, height: 16)
                            Text(app.name).lineLimit(1)
                        }
                    }
                }
            }
        }
        .frame(height: 140)
    }
}

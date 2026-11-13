import AppKit
import MenuFoldCore
import SwiftUI

/// Identifies an open bulk-category sheet and the category it starts with.
struct BulkCategoryTarget: Identifiable, Hashable {
    let categoryID: String
    var id: String { categoryID }
}

/// Sheet in Settings → Категорії that moves several apps into one category at once: a target
/// picker (custom categories, the automatic ones, or "Автоматично" to drop overrides) above a
/// searchable checklist of every visible app.
///
/// Applying is one `setCategory(_:for: [String])` call: one save and one ⌘Z step for all apps.
struct BulkCategoryView: View {
    let model: GridModel

    @Environment(\.dismiss) private var dismiss
    @State private var targetID: String
    @State private var query = ""
    @State private var checked: Set<String> = []

    /// Picker tag for "remove the override, use the automatic category".
    private static let automaticTag = "\u{0}automatic"

    init(model: GridModel, initialCategoryID: String) {
        self.model = model
        _targetID = State(initialValue: initialCategoryID)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Змінити категорію програм")
                    .font(.headline)
                Picker("Категорія", selection: $targetID) {
                    if !model.customCategories.isEmpty {
                        Section("Мої категорії") {
                            ForEach(model.customCategories) { Text($0.displayName).tag($0.id) }
                        }
                    }
                    Section("Системні категорії") {
                        ForEach(systemCategories) { Text($0.displayName).tag($0.id) }
                    }
                    Divider()
                    Text("Автоматично").tag(Self.automaticTag)
                }
                if resolvedTarget == nil {
                    // The category was deleted meanwhile (e.g. in the panel); never guess another one.
                    Label("Цієї категорії більше немає. Виберіть іншу.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                TextField("Пошук", text: $query, prompt: Text("Пошук програм"))
                    .textFieldStyle(.roundedBorder)
            }
            .padding(16)

            Divider()

            List {
                ForEach(filteredApps) { app in
                    row(app)
                }
            }
            .listStyle(.inset)
            .overlay {
                if filteredApps.isEmpty {
                    Text("Нічого не знайдено")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Button(allFilteredChecked ? String(localized: "Зняти всі") : String(localized: "Вибрати всі")) { toggleAllFiltered() }
                    .disabled(filteredApps.isEmpty)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Вибрано: \(checkedApps.count)")
                    if hiddenCheckedCount > 0 {
                        // Checked apps the search hides are applied too; say so, and offer to drop them.
                        HStack(spacing: 4) {
                            Text("З них поза пошуком: \(hiddenCheckedCount)")
                            Button("Зняти") { checked.formIntersection(filteredApps.map(\.id)) }
                                .buttonStyle(.link)
                        }
                        .font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .font(.callout)
                Spacer()
                Button("Скасувати", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Застосувати") { apply() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(checkedApps.isEmpty || resolvedTarget == nil)
            }
            .padding(16)
        }
        .frame(width: 460, height: 520)
    }

    private func row(_ app: AppEntry) -> some View {
        Toggle(isOn: Binding(
            get: { checked.contains(app.id) },
            set: { on in
                if on { checked.insert(app.id) } else { checked.remove(app.id) }
            }
        )) {
            HStack(spacing: 8) {
                Image(nsImage: IconCache.shared.icon(for: app))
                    .resizable()
                    .frame(width: 22, height: 22)
                Text(app.name)
                    .lineLimit(1)
                Spacer()
                Text(model.category(of: app).displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .toggleStyle(.checkbox)
    }

    private var systemCategories: [AppCategory] {
        AppCategory.known + [.other]
    }

    /// Visible apps (hidden ones are left out), filtered by the search field, by name.
    private var filteredApps: [AppEntry] {
        let hidden = model.layout.hidden
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return model.apps
            .filter { !hidden.contains($0.id) && (q.isEmpty || $0.matches(q)) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var allFilteredChecked: Bool {
        let ids = filteredApps.map(\.id)
        return !ids.isEmpty && ids.allSatisfy(checked.contains)
    }

    private func toggleAllFiltered() {
        let ids = filteredApps.map(\.id)
        if allFilteredChecked {
            checked.subtract(ids)
        } else {
            checked.formUnion(ids)
        }
    }

    /// The picked target: `.some(nil)` = automatic (drop overrides), `.some(category)`, or nil when
    /// the picked id no longer exists. Nil must never fall through to "remove overrides".
    private var resolvedTarget: AppCategory?? {
        if targetID == Self.automaticTag { return .some(nil) }
        if let custom = model.customCategories.first(where: { $0.id == targetID }) { return .some(custom) }
        if let system = systemCategories.first(where: { $0.id == targetID }) { return .some(system) }
        return nil
    }

    /// Checked apps that are still listable (installed, not hidden), whether or not the search
    /// shows them right now; this is exactly what Apply changes and what the counter shows.
    private var checkedApps: [String] {
        let hidden = model.layout.hidden
        return model.apps.map(\.id).filter { checked.contains($0) && !hidden.contains($0) }.sorted()
    }

    /// Checked apps that the current search hides.
    private var hiddenCheckedCount: Int {
        let shown = Set(filteredApps.map(\.id))
        return checkedApps.count { !shown.contains($0) }
    }

    private func apply() {
        guard let target = resolvedTarget else { return }
        let ids = checkedApps
        guard !ids.isEmpty else { return }
        model.setCategory(target, for: ids)
        dismiss()
    }
}

#Preview {
    BulkCategoryView(model: .preview, initialCategoryID: AppCategory.otherID)
}

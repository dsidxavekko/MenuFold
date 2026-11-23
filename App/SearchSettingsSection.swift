import MenuFoldCore
import SwiftUI

/// Settings section for the file search: one switch for the whole feature, and what it does with the
/// disk. Insert it into any `Form` of `SettingsView` (`SearchSettingsSection()`), next to the other
/// search switches.
///
/// The switch lives in `AppPreferences` (default on); `AppDelegate` copies it into
/// `GridModel.searchesFiles` after every change, so the panel follows immediately. The footer says
/// the truth the user cares about: the query runs on this Mac, in the system's own index.
struct SearchSettingsSection: View {
    @Bindable private var prefs = AppPreferences.shared

    var body: some View {
        Section {
            Toggle(String(localized: "Шукати файли й документи"), isOn: $prefs.searchesFiles)
        } header: {
            Label(String(localized: "Документи"), systemImage: "doc.text.magnifyingglass")
        } footer: {
            Text(String(localized: "Знайдені файли з’являються під результатами програм, після системних параметрів. Префікс «~» у полі пошуку шукає лише документи. Пошук іде локально через Spotlight у вашій домашній теці: назви файлів нікуди не надсилаються, інтернет не використовується."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    Form {
        SearchSettingsSection()
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 220)
}

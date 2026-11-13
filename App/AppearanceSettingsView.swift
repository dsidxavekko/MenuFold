import AppKit
import SwiftUI

/// Settings → Вигляд: the panel's grid size and the optional decorations of the grid.
/// Everything lives in `AppPreferences` (observable), so the rows need no refresh-on-key logic;
/// the shell applies size changes the next time the panel opens.
struct AppearanceSettingsView: View {
    @Bindable private var prefs = AppPreferences.shared

    private static let defaultColumns = 7
    private static let defaultRows = 4

    var body: some View {
        Form {
            Section {
                Stepper(value: $prefs.columns, in: AppPreferences.columnRange) {
                    LabeledContent("Стовпці", value: "\(prefs.columns)")
                }
                Stepper(value: $prefs.rows, in: AppPreferences.rowRange) {
                    LabeledContent("Рядки", value: "\(prefs.rows)")
                }
                HStack {
                    Text("Розмір панелі: \(Int(GridMetrics.panelWidth)) × \(Int(GridMetrics.panelHeight)) пт")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    Button("Типовий розмір") {
                        prefs.columns = Self.defaultColumns
                        prefs.rows = Self.defaultRows
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(prefs.columns == Self.defaultColumns && prefs.rows == Self.defaultRows)
                }
                .font(.callout)
                if !fitsScreen {
                    Label("Панель більша за екран — її буде обрізано.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
            } header: {
                Label("Розмір сітки", systemImage: "square.grid.3x3")
            } footer: {
                Text("Типово — 7 стовпців і 4 рядки, як у системному «Програми». Решта програм прокручується.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Показувати закріплені", isOn: $prefs.showsPinned)
                Toggle("Показувати лічильники в папках", isOn: $prefs.showsFolderCounts)
                Toggle("Позначати нові програми", isOn: $prefs.showsNewAppDots)
            } header: {
                Label("Сітка", systemImage: "app.badge")
            } footer: {
                Text("Закріплені програми стоять рядом над сіткою на вкладці «Все». Нові програми — встановлені за останній тиждень і ще не відкриті — позначаються крапкою.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// False when the panel at the chosen size would not fit the largest screen's visible area.
    private var fitsScreen: Bool {
        let screens = NSScreen.screens.map(\.visibleFrame.size)
        guard !screens.isEmpty else { return true }
        return screens.contains { $0.width >= GridMetrics.panelWidth && $0.height >= GridMetrics.panelHeight }
    }
}

#Preview {
    AppearanceSettingsView()
        .frame(width: 520, height: 600)
}

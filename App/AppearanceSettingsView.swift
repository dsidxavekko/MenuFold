import AppKit
import MenuFoldCore
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
                HStack(alignment: .center, spacing: 16) {
                    VStack(spacing: 4) {
                        Stepper(value: $prefs.columns, in: AppPreferences.columnRange) {
                            LabeledContent("Стовпці", value: "\(prefs.columns)")
                        }
                        .accessibilityValue(Text("\(prefs.columns)"))
                        Stepper(value: $prefs.rows, in: AppPreferences.rowRange) {
                            LabeledContent("Рядки", value: "\(prefs.rows)")
                        }
                        .accessibilityValue(Text("\(prefs.rows)"))
                    }
                    GridDiagram(columns: prefs.columns, rows: prefs.rows)
                        .frame(width: 96, height: 72)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text("Схема сітки"))
                        .accessibilityValue(Text("\(prefs.columns) × \(prefs.rows)"))
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
                Picker("Відкривати панель", selection: $prefs.panelScreenPolicy) {
                    Text("Де курсор").tag(PanelScreenPolicy.cursor)
                    Text("На основному екрані").tag(PanelScreenPolicy.primary)
                    Text("Де активне вікно").tag(PanelScreenPolicy.activeWindow)
                }
            } header: {
                Label("Екран", systemImage: "display.2")
            } footer: {
                Text("На малому екрані сітка автоматично зменшується, щоб панель вмістилась.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Жести трекпада", isOn: $prefs.usesGestures)
            } footer: {
                Text("Проведення двома пальцями вбік перемикає вкладки, щипок змінює розмір сітки.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Зменшити рух усередині програми", isOn: $prefs.forcesReduceMotion)
                Toggle("Підвищений контраст", isOn: $prefs.forcesIncreaseContrast)
            } header: {
                Label("Доступність", systemImage: "accessibility")
            } footer: {
                Text("Вмикає ці режими лише в MenuFold, навіть якщо системні вимкнені. Якщо системні ввімкнені, вони діють завжди.")
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

/// Miniature of the grid: `columns` × `rows` rounded squares.
private struct GridDiagram: View {
    private var reduceMotion: Bool { ThemeOverrides.reduceMotion }
    let columns: Int
    let rows: Int

    var body: some View {
        Canvas { ctx, size in
            let gap: CGFloat = 3
            let w = (size.width - gap * CGFloat(columns - 1)) / CGFloat(columns)
            let h = (size.height - gap * CGFloat(rows - 1)) / CGFloat(rows)
            let side = max(1, min(w, h))
            let totalW = side * CGFloat(columns) + gap * CGFloat(columns - 1)
            let totalH = side * CGFloat(rows) + gap * CGFloat(rows - 1)
            let ox = (size.width - totalW) / 2, oy = (size.height - totalH) / 2
            for r in 0..<rows {
                for c in 0..<columns {
                    let rect = CGRect(x: ox + CGFloat(c) * (side + gap), y: oy + CGFloat(r) * (side + gap),
                                      width: side, height: side)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: side * 0.28), with: .color(.accentColor.opacity(0.75)))
                }
            }
        }
        .animation(reduceMotion ? nil : .default, value: columns)
        .animation(reduceMotion ? nil : .default, value: rows)
    }
}

#Preview {
    AppearanceSettingsView()
        .frame(width: 520, height: 600)
}

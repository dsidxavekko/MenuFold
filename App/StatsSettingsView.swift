import Charts
import MenuFoldCore
import SwiftUI

/// Settings → Статистика: how often apps are opened (top apps, weekdays, last 30 days) from
/// `UsageLogger`. Counts are aggregates per day kept on this Mac only; the switch stops collecting
/// and "Стерти" removes everything.
struct StatsSettingsView: View {
    let model: GridModel
    @State private var logger = UsageLogger.shared
    @State private var confirmErase = false
    @State private var unusedCount = 0

    /// One hue for every bar (a single series), dark enough on a light background and light enough
    /// on a dark one; the value is also printed, so colour is never the only carrier.
    private let barColor = Color.accentColor

    var body: some View {
        let report = logger.report()
        Form {
            Section {
                Toggle("Вести статистику запусків", isOn: Binding(get: { logger.isEnabled }, set: { logger.isEnabled = $0 }))
            } footer: {
                Text("Зберігаються лише підсумки за днями (без часу запусків) на цьому Mac, до року. У теку даних для синхронізації вони не потрапляють.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if report.totalLaunches == 0 {
                Section {
                    Text(logger.isEnabled ? "Поки немає даних: статистика з'явиться, коли ви відкриватимете програми."
                                          : "Статистика вимкнена.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    LabeledContent("Усього запусків") { Text(report.totalLaunches, format: .number).monospacedDigit() }
                    LabeledContent("Не відкривалися 90 днів") { Text(unusedCount, format: .number).monospacedDigit() }
                }
                Section {
                    topChart(report)
                } header: {
                    Label("Найчастіші програми (90 днів)", systemImage: "chart.bar")
                }
                Section {
                    weekdayChart(report)
                } header: {
                    Label("Активність за днями тижня (90 днів)", systemImage: "calendar")
                }
                Section {
                    recentChart(report)
                } header: {
                    Label("Останні 30 днів", systemImage: "chart.xyaxis.line")
                }
            }

            Section {
                Button("Стерти статистику…", role: .destructive) { confirmErase = true }
                    .disabled(logger.log.isEmpty)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: SettingsWindowController.contentDidBecomeKey)) { _ in refresh() }
        .confirmationDialog("Стерти всю статистику запусків?", isPresented: $confirmErase) {
            Button("Стерти", role: .destructive) { logger.erase(); refresh() }
            Button("Скасувати", role: .cancel) {}
        }
    }

    private func refresh() {
        unusedCount = model.unusedApps(olderThan: 90 * 86_400).count
    }

    private func name(_ id: String) -> String {
        model.apps.first { $0.id == id }?.name ?? id
    }

    private func topChart(_ report: UsageReport) -> some View {
        Chart(report.top) { item in
            BarMark(x: .value(String(localized: "Запусків"), item.count),
                    y: .value(String(localized: "Програма"), name(item.appID)))
                .foregroundStyle(barColor)
                .annotation(position: .trailing) {
                    Text(item.count, format: .number).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
        }
        .chartYScale(domain: report.top.map { name($0.appID) })
        .chartXAxis(.hidden)
        .frame(height: CGFloat(max(report.top.count, 1)) * 26 + 8)
        .accessibilityLabel(Text("Найчастіші програми"))
    }

    private func weekdayChart(_ report: UsageReport) -> some View {
        let symbols = Calendar.current.shortWeekdaySymbols
        let rows = zip(report.weekdayNumbers, report.weekdayCounts).map { (symbols[$0 - 1], $1) }
        return Chart(Array(rows.enumerated()), id: \.offset) { _, row in
            BarMark(x: .value(String(localized: "День"), row.0), y: .value(String(localized: "Запусків"), row.1))
                .foregroundStyle(barColor)
                .annotation(position: .top) {
                    Text(row.1, format: .number).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                }
        }
        .chartXScale(domain: rows.map(\.0))
        .chartYAxis(.hidden)
        .frame(height: 120)
        .accessibilityLabel(Text("Активність за днями тижня"))
    }

    private func recentChart(_ report: UsageReport) -> some View {
        Chart(report.recent) { day in
            BarMark(x: .value(String(localized: "Дата"), day.date, unit: .day),
                    y: .value(String(localized: "Запусків"), day.count))
                .foregroundStyle(barColor)
        }
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 7)) { _ in
            AxisGridLine(); AxisValueLabel(format: .dateTime.day().month(.abbreviated))
        } }
        .frame(height: 120)
        .accessibilityLabel(Text("Запуски за останні 30 днів"))
    }
}

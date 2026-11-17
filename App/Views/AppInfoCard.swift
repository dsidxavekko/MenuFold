import AppKit
import MenuFoldCore
import SwiftUI

/// ⌘I "Інформація про програму": a card inside the panel for `model.infoAppID` (an alert, sheet or
/// Get Info window would take key status and close the panel). `MenuFoldRootView` draws the dim
/// behind it and closes it on a click outside; Esc closes it (via the panel's `onCancel`).
/// The bundle is read off the main actor (`GridModel.appInfo(for:)`), so the card appears at once
/// and the size fills in when the walk is done.
struct AppInfoCard: View {
    let app: AppEntry
    @Bindable var model: GridModel

    @Environment(\.menuFoldReduceMotion) private var reduceMotion
    @State private var info: AppInfo?

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: IconCache.shared.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: GridMetrics.iconSize, height: GridMetrics.iconSize)
                .accessibilityHidden(true)
            Text(app.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)

            VStack(alignment: .leading, spacing: 7) {
                row(String(localized: "Версія"), versionText)
                row(String(localized: "Розмір"), sizeText)
                row(String(localized: "Встановлено"), date(info?.installedDate))
                row(String(localized: "Джерело"), info?.source.title)
                if let update = model.availableUpdates[app.id] {
                    row(String(localized: "Оновлення"), String(localized: "Доступна версія \(update.newVersion)"))
                }
                row(String(localized: "Ідентифікатор"), app.id, monospaced: true)
                row(String(localized: "Шлях"), (app.url.path as NSString).abbreviatingWithTildeInPath,
                    monospaced: true, help: app.url.path)
                Divider().padding(.vertical, 2)
                row(String(localized: "Вперше побачено"), date(info?.firstSeen))
                row(String(localized: "Останній запуск"), date(info?.lastLaunched, time: true))
                row(String(localized: "Запусків"), info?.launchCount.map { "\($0)" })
            }
            .font(.callout)

            HStack(spacing: 10) {
                Button("Показати у Finder") { model.revealInFinder(app) }
                    .buttonStyle(.glass)
                Button("Готово") { model.infoAppID = nil }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(width: 380)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardCorner, style: .continuous))
        .cardShadow()
        .animation(reduceMotion ? Theme.crossfade : Theme.snappy, value: info)
        .task(id: app.id) { info = await model.appInfo(for: app.id) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    private var versionText: String? {
        guard let version = info?.version else { return info?.build }
        if let build = info?.build, build != version { return "\(version) (\(build))" }
        return version
    }

    private var sizeText: String? {
        info?.sizeBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
    }

    private func date(_ date: Date?, time: Bool = false) -> String? {
        date?.formatted(date: .abbreviated, time: time ? .shortened : .omitted)
    }

    /// A label and its value; while the info is loading, or when the value is unknown, a dash.
    private func row(_ title: String, _ value: String?, monospaced: Bool = false, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .foregroundStyle(.secondary)
                .frame(width: 112, alignment: .leading)
            Text(value ?? "—")
                .font(monospaced ? .callout.monospaced() : .callout)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .help(help ?? "")
            Spacer(minLength: 0)
        }
    }
}

#Preview {
    let model = GridModel.preview
    if let app = model.apps.first {
        AppInfoCard(app: app, model: model)
            .padding(40)
            .background(.regularMaterial)
    }
}

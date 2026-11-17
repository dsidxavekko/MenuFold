import AppKit
import MenuFoldCore
import SwiftUI

extension QuickAction {
    var title: String {
        switch self {
        case .quit: String(localized: "Завершити")
        case .hide: String(localized: "Сховати")
        case .restart: String(localized: "Перезапустити")
        case .showPackageContents: String(localized: "Показати вміст пакета")
        case .revealInFinder: String(localized: "Показати у Finder")
        case .copyPath: String(localized: "Скопіювати шлях")
        case .copyBundleID: String(localized: "Скопіювати ідентифікатор")
        }
    }

    var symbol: String {
        switch self {
        case .quit: "power"
        case .hide: "eye.slash"
        case .restart: "arrow.clockwise"
        case .showPackageContents: "shippingbox"
        case .revealInFinder: "folder"
        case .copyPath: "doc.on.doc"
        case .copyBundleID: "number"
        }
    }
}

/// Runs a quick action (AppKit side of `QuickAction`).
@MainActor
enum QuickActionRunner {
    static func actions(for appID: String) -> [QuickAction] {
        QuickAction.available(isRunning: RunningAppsMonitor.shared.isRunning(appID))
    }

    static func run(_ action: QuickAction, app: AppEntry, model: GridModel) {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id)
        switch action {
        case .quit: RunningAppsMonitor.shared.quit(app.id)
        case .hide: running.forEach { _ = $0.hide() }
        case .restart: restart(app, running)
        case .showPackageContents:
            NSWorkspace.shared.open(app.url.appendingPathComponent("Contents"))
        case .revealInFinder: model.revealInFinder(app)
        case .copyPath: copy(app.url.path)
        case .copyBundleID: copy(app.id)
        }
    }

    private static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Asks the app to quit, then opens it again once it is gone (gives up after 15 s).
    private static func restart(_ app: AppEntry, _ running: [NSRunningApplication]) {
        running.forEach { $0.terminate() }
        let url = app.url
        Task { @MainActor in
            for _ in 0..<60 {
                if running.allSatisfy(\.isTerminated) {
                    _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                    return
                }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}

/// Tab on a selected tile: a small action list in the panel for `model.quickActionsAppID`.
/// `MenuFoldRootView` draws the dim behind it; the key monitor drives `model.quickActionIndex`.
struct QuickActionsList: View {
    let app: AppEntry
    @Bindable var model: GridModel

    var body: some View {
        let actions = QuickActionRunner.actions(for: app.id)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(nsImage: IconCache.shared.icon(for: app))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 24, height: 24)
                    .accessibilityHidden(true)
                Text(app.name)
                    .font(.headline)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            ForEach(Array(actions.enumerated()), id: \.element) { index, action in
                let selected = index == model.quickActionIndex
                Button {
                    model.quickActionIndex = index
                    QuickActionRunner.run(action, app: app, model: model)
                    model.quickActionsAppID = nil
                } label: {
                    Label(action.title, systemImage: action.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(selected ? Color.accentColor.opacity(0.25) : .clear,
                                    in: .rect(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(action.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(12)
        .frame(width: 260)
        .glassEffect(.regular, in: .rect(cornerRadius: Theme.cardCorner, style: .continuous))
        .cardShadow()
        .themedAnimation(Theme.snappy, value: model.quickActionIndex)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(String(localized: "Дії"))
        .accessibilityAddTraits(.isModal)
    }
}

import SwiftUI
import MenuFoldCore

/// Runs `DefaultAppUpdateChecker` on launch and every 12 hours while
/// `AppPreferences.checksForAppUpdates` is on, and publishes the result into `GridModel`.
@MainActor
@Observable
final class AppUpdateScheduler {
    static let shared = AppUpdateScheduler()
    static let interval: TimeInterval = 12 * 3600
    private static let lastCheckKey = "lastAppUpdateCheck"

    private(set) var isChecking = false
    private(set) var lastCheck: Date? = UserDefaults.standard.object(forKey: AppUpdateScheduler.lastCheckKey) as? Date

    @ObservationIgnored private weak var model: GridModel?
    @ObservationIgnored private let checker = DefaultAppUpdateChecker()
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var started = false

    func start(model: GridModel) {
        guard !started else { return }
        started = true
        self.model = model
        NotificationCenter.default.addObserver(forName: .menuFoldPreferencesChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesChanged() }
        }
        preferencesChanged()
    }

    private var wasEnabled = false

    private func preferencesChanged() {
        let enabled = AppPreferences.shared.checksForAppUpdates
        guard enabled != wasEnabled else { return }
        wasEnabled = enabled
        timer?.invalidate()
        timer = nil
        if enabled {
            timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkNow() }
            }
            checkNow()
        } else {
            model?.clearAvailableUpdates()
        }
    }

    /// Checks once. At launch the catalog may not be scanned yet, so it waits for it (up to ~1 min).
    func checkNow() {
        guard !isChecking, let model else { return }
        isChecking = true
        Task { @MainActor in
            var waited = 0
            while model.apps.isEmpty, waited < 30 {
                try? await Task.sleep(for: .seconds(2))
                waited += 1
            }
            if AppPreferences.shared.checksForAppUpdates {
                await model.refreshAvailableUpdates(using: checker)
                lastCheck = Date()
                UserDefaults.standard.set(lastCheck, forKey: Self.lastCheckKey)
            }
            isChecking = false
        }
    }
}

/// Settings → Загальне: switch, "Перевірити зараз" and a status line.
struct AppUpdatesSettingsSection: View {
    let model: GridModel
    @State private var prefs = AppPreferences.shared
    private var scheduler: AppUpdateScheduler { .shared }

    var body: some View {
        Section {
            Toggle("Шукати оновлення встановлених програм", isOn: $prefs.checksForAppUpdates)
            if prefs.checksForAppUpdates {
                HStack {
                    Group {
                        if scheduler.isChecking {
                            Text("Перевіряється…")
                        } else if let last = scheduler.lastCheck {
                            let count = model.availableUpdates.count
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Остання перевірка: \(last.formatted(date: .abbreviated, time: .shortened))")
                                Text(count == 0 ? String(localized: "Усі програми актуальні") : String(localized: "Оновлень: \(count)"))
                            }
                        } else {
                            Text("Ще не перевірялося.")
                        }
                    }
                    .foregroundStyle(.secondary)
                    Spacer()
                    Button("Перевірити зараз") { scheduler.checkNow() }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(scheduler.isChecking)
                }
                .font(.callout)
            }
        } header: {
            Label("Оновлення програм", systemImage: "arrow.down.circle")
        } footer: {
            Text("Позначає програми з новою версією. Homebrew: запускається brew outdated. App Store: на сервер Apple надсилаються лише ідентифікатори таких програм. Sparkle: завантажується стрічка оновлень самої програми. MenuFold нічого не встановлює.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

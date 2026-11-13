import AppKit
import Observation
#if canImport(Sparkle)
import Sparkle
#endif

/// In-app updates through Sparkle. The feed is `SUFeedURL` in Info.plist (`appcast.xml` attached to the
/// latest GitHub release by `scripts/release.sh`), and every update archive is checked against
/// `SUPublicEDKey`, so updates work with the ad-hoc code signature.
///
/// `Updater` is also Sparkle's delegate: every finished check (update found, none found, or a fetch
/// failure) is re-posted as `didCheckNotification`, so Settings can refresh the "last checked" row —
/// Sparkle stamps `lastUpdateCheckDate` asynchronously after `checkForUpdates()`.
///
/// Debug builds never start the updater (their build number is not a release one, so every check
/// would offer to replace the dev build). Pass `--args -enableUpdates YES` to try it anyway.
///
/// `scripts/typecheck-app.sh` has no Sparkle module when nothing was built yet; it then checks the
/// no-op branch below.
@MainActor
@Observable
final class Updater: NSObject {
    /// Version string of an update Sparkle found and the user has not installed yet; nil when none.
    /// Drives the "є оновлення" pill in the panel and the Dock-menu item. (CONTRACT, set by the Shell agent.)
    var availableUpdateVersion: String?

    /// Posted after any finished update check (update found, none found, or fetch failed), so
    /// Settings can refresh the "last checked" row — Sparkle stamps `lastUpdateCheckDate`
    /// asynchronously after `checkForUpdates()`.
    static let didCheckNotification = Notification.Name("menuFoldUpdaterDidCheck")

    static let shared = Updater()

    #if canImport(Sparkle)
    /// Lazy so the initializer is done before the delegate (`self`) is referenced — an init that
    /// passed `self` before `super.init` would not compile. The updater starts on the first access
    /// (`Self.isEnabled` decides whether it runs at all).
    @ObservationIgnored private lazy var controller: SPUStandardUpdaterController = {
        SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: self, userDriverDelegate: nil)
    }()
    #endif

    /// False in Debug builds: the menu item and the Settings section are hidden.
    nonisolated static let isEnabled: Bool = {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "enableUpdates")
        #else
        true
        #endif
    }()

    var isEnabled: Bool { Self.isEnabled }

    private override init() {
        super.init()
    }

    /// "Перевірити оновлення…": Sparkle shows its own window (progress, "you're up to date" or the update).
    func checkForUpdates() {
        #if canImport(Sparkle)
        guard isEnabled else { return }
        NSApp.activate()
        controller.checkForUpdates(nil)
        #endif
    }

    /// The daily background check. Sparkle asks the user once, on the second launch, whether to turn it on.
    var automaticallyChecks: Bool {
        get {
            #if canImport(Sparkle)
            controller.updater.automaticallyChecksForUpdates
            #else
            false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller.updater.automaticallyChecksForUpdates = newValue
            #endif
        }
    }

    /// Download and install a found update in the background, then apply it when MenuFold quits.
    var automaticallyDownloads: Bool {
        get {
            #if canImport(Sparkle)
            controller.updater.automaticallyDownloadsUpdates
            #else
            false
            #endif
        }
        set {
            #if canImport(Sparkle)
            controller.updater.automaticallyDownloadsUpdates = newValue
            #endif
        }
    }

    var lastCheckDate: Date? {
        #if canImport(Sparkle)
        controller.updater.lastUpdateCheckDate
        #else
        nil
        #endif
    }
}

#if canImport(Sparkle)
extension Updater: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableUpdateVersion = item.displayVersionString
        NotificationCenter.default.post(name: Self.didCheckNotification, object: nil)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableUpdateVersion = nil
        NotificationCenter.default.post(name: Self.didCheckNotification, object: nil)
    }

    /// The update is being applied: this copy is about to quit, so the badge must not linger.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        availableUpdateVersion = nil
    }

    // Sparkle 2 has no `updater:failedToFetchAppcastWithError:` (a Sparkle 1.x method): a failed
    // appcast fetch aborts the update driver, which reports through `updater:didAbortWithError:`.
    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        NotificationCenter.default.post(name: Self.didCheckNotification, object: nil)
    }
}
#endif

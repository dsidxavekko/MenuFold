import AppKit
#if canImport(Sparkle)
import Sparkle
#endif

/// In-app updates through Sparkle. The feed is `SUFeedURL` in Info.plist (`appcast.xml` attached to the
/// latest GitHub release by `scripts/release.sh`), and every update archive is checked against
/// `SUPublicEDKey`, so updates work with the ad-hoc code signature.
///
/// Debug builds never start the updater (their build number is not a release one, so every check
/// would offer to replace the dev build). Pass `--args -enableUpdates YES` to try it anyway.
///
/// `scripts/typecheck-app.sh` has no Sparkle module when nothing was built yet; it then checks the
/// no-op branch below.
@MainActor
final class Updater {
    static let shared = Updater()

    #if canImport(Sparkle)
    private let controller: SPUStandardUpdaterController
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

    private init() {
        #if canImport(Sparkle)
        controller = SPUStandardUpdaterController(startingUpdater: Self.isEnabled, updaterDelegate: nil, userDriverDelegate: nil)
        #endif
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

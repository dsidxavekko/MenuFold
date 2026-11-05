import AppKit
import Observation

/// Bundle IDs of the apps running right now, for the Dock-like dot under a tile, the "Завершити"
/// menu item and the trash card. KVO on `NSWorkspace.runningApplications` (main thread).
@MainActor
@Observable
final class RunningAppsMonitor {
    static let shared = RunningAppsMonitor()

    private(set) var bundleIDs: Set<String> = [] {
        didSet { onChange?(bundleIDs) }
    }
    /// Called on the main actor whenever `bundleIDs` changes (feeds `GridModel.runningAppIDs`).
    @ObservationIgnored var onChange: ((Set<String>) -> Void)?

    @ObservationIgnored private var observation: NSKeyValueObservation?

    private init() {
        observation = NSWorkspace.shared.observe(\.runningApplications, options: [.initial, .new]) { [weak self] workspace, _ in
            // KVO for this key is delivered on the main thread.
            MainActor.assumeIsolated {
                let ids = Set(workspace.runningApplications.compactMap(\.bundleIdentifier))
                guard let self, ids != self.bundleIDs else { return }
                self.bundleIDs = ids
            }
        }
    }

    func isRunning(_ id: String) -> Bool {
        bundleIDs.contains(id)
    }

    /// Asks every instance of the app to quit (`force`: kills it without asking to save).
    func quit(_ id: String, force: Bool = false) {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
            if force { app.forceTerminate() } else { app.terminate() }
        }
    }
}

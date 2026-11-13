import AppKit

/// First-launch help for the downloaded app: MenuFold must live in /Applications to stay in the Dock
/// and to be updated by Sparkle.
///
/// - Opened straight from the mounted DMG: offer to copy it into /Applications, open the copy and quit.
/// - Run from a translocated copy (a quarantined app opened where it was unzipped): macOS runs it
///   from a random read-only path, so only explain how to move it.
@MainActor
enum InstallLocation {
    private static let applications = URL(filePath: "/Applications", directoryHint: .isDirectory)

    /// Returns true when MenuFold is about to quit because its copy in /Applications is opening.
    static func offerMoveIfNeeded(onOpenFailed: @escaping () -> Void = {}) -> Bool {
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        // A deliberately installed copy on an external/secondary volume lives in /Volumes too, but
        // its volume is writable — only a mounted disk image (read-only) gets the move offer.
        if bundle.path.hasPrefix("/Volumes/"), !volumeIsWritable(at: bundle) {
            return offerMove(from: bundle, onOpenFailed: onOpenFailed)
        }
        if bundle.path.contains("/AppTranslocation/") {
            explainTranslocation()
        }
        return false
    }

    /// False when it cannot be determined: falling back to the move offer keeps the old behavior.
    /// There is no "volume is writable" resource key, so test the bundle's own directory: a mounted
    /// disk image is read-only, while an app deliberately placed on an external volume sits in a
    /// folder the user can write.
    private static func volumeIsWritable(at bundle: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: bundle.path)
    }

    private static func offerMove(from source: URL, onOpenFailed: @escaping () -> Void) -> Bool {
        let destination = applications.appending(path: source.lastPathComponent, directoryHint: .isDirectory)
        let replacing = FileManager.default.fileExists(atPath: destination.path)

        let alert = NSAlert()
        alert.messageText = String(localized: "Перемістити MenuFold у «Програми»?")
        alert.informativeText = replacing
            ? String(localized: "MenuFold запущено з образу диска. Щоб він залишався в Dock і міг оновлюватися, його треба скопіювати в папку «Програми». Наявну там копію буде переміщено в Смітник.")
            : String(localized: "MenuFold запущено з образу диска. Щоб він залишався в Dock і міг оновлюватися, його треба скопіювати в папку «Програми».")
        alert.addButton(withTitle: String(localized: "Перемістити"))
        alert.addButton(withTitle: String(localized: "Не зараз"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        do {
            try copy(source, to: destination, replacing: replacing)
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = String(localized: "Не вдалося скопіювати MenuFold у «Програми»")
            failure.informativeText = String(localized: "Перетягніть MenuFold у папку «Програми» у Finder. (\(error.localizedDescription))")
            failure.runModal()
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            Task { @MainActor in
                guard let error else {
                    ejectWhenGone(volumeOf: source)
                    NSApp.terminate(nil)
                    return
                }
                // Opening the fresh copy failed (Gatekeeper refusal, LaunchServices, the copy vanished):
                // say so and keep running from here, or the process would sit invisible with no panel.
                NSLog("%@", "MenuFold: could not open the Applications copy: \(error.localizedDescription)")
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = String(localized: "Не вдалося відкрити копію в «Програмах»")
                alert.informativeText = String(localized: "MenuFold продовжить працювати звідси. Спробуйте відкрити копію з папки «Програми» вручну. (\(error.localizedDescription))")
                alert.addButton(withTitle: "OK")
                NSApp.activate()
                alert.runModal()
                onOpenFailed()
            }
        }
        return true
    }

    private static func copy(_ source: URL, to destination: URL, replacing: Bool) throws {
        let files = FileManager.default
        if replacing {
            // An older copy may be running (pinned in the Dock): quit it before it moves to the Trash.
            let me = ProcessInfo.processInfo.processIdentifier
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app.processIdentifier != me {
                app.terminate()
            }
            try files.trashItem(at: destination, resultingItemURL: nil)
        }
        try files.copyItem(at: source, to: destination)
        // The user already allowed this download to open; keep Gatekeeper from asking again for the copy.
        removeQuarantine(at: destination)
    }

    private static func removeQuarantine(at url: URL) {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    /// Detaches the DMG a moment after this process quits (its files are in use until then).
    private static func ejectWhenGone(volumeOf source: URL) {
        let parts = source.pathComponents  // ["/", "Volumes", "MenuFold", "MenuFold.app"]
        guard parts.count >= 3 else { return }
        let volume = "/Volumes/" + parts[2]
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sh")
        process.arguments = ["-c", "sleep 2; /usr/bin/hdiutil detach -quiet \"$0\"", volume]
        try? process.run()
    }

    private static func explainTranslocation() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Перемістіть MenuFold у «Програми»")
        alert.informativeText = String(localized: "macOS запустила MenuFold із тимчасової копії, бо його не перенесли з папки, куди він завантажився. Закрийте MenuFold, перетягніть його у Finder у папку «Програми» і відкрийте звідти. Тоді він залишатиметься в Dock і зможе оновлюватися.")
        alert.addButton(withTitle: "OK")
        NSApp.activate()
        alert.runModal()
    }
}

import AppKit
import MenuFoldCore
import UniformTypeIdentifiers

/// Lets the user pick a picture (or another app, whose icon is then used) as an icon.
/// The open panel takes key status, so the MenuFold panel closes while it is up.
@MainActor
enum CustomIconPicker {
    /// Custom icon of an app in the grid.
    static func choose(for app: AppEntry, model: GridModel) {
        // Out of the context menu's tracking loop first, or the open panel can appear behind it.
        DispatchQueue.main.async {
            guard let url = pickFile(title: String(localized: "Значок для «\(app.name)»")) else { return }
            do {
                try model.setCustomIcon(for: app.id, from: url)
            } catch {
                showError(error)
            }
        }
    }

    /// Runs the open panel; nil when the user cancels.
    static func pickFile(title: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.message = String(localized: "Виберіть зображення (PNG, JPEG, HEIC, ICNS, SVG…) або програму, чий значок узяти.")
        panel.prompt = String(localized: "Вибрати")
        panel.allowedContentTypes = [.image, .applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        NSApp.activate()
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Не вдалося змінити значок")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

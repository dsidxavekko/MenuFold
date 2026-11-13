import AppKit
import MenuFoldCore
import SwiftUI

// Shared helpers for MenuFold views.

extension FolderColor {
    var color: Color {
        switch self {
        case .gray: .gray
        case .blue: .blue
        case .green: .green
        case .orange: .orange
        case .red: .red
        case .purple: .purple
        case .pink: .pink
        case .yellow: .yellow
        }
    }

    var nsColor: NSColor {
        switch self {
        case .gray: .systemGray
        case .blue: .systemBlue
        case .green: .systemGreen
        case .orange: .systemOrange
        case .red: .systemRed
        case .purple: .systemPurple
        case .pink: .systemPink
        case .yellow: .systemYellow
        }
    }

    var displayName: String {
        switch self {
        case .gray: String(localized: "Сірий")
        case .blue: String(localized: "Синій")
        case .green: String(localized: "Зелений")
        case .orange: String(localized: "Помаранчевий")
        case .red: String(localized: "Червоний")
        case .purple: String(localized: "Фіолетовий")
        case .pink: String(localized: "Рожевий")
        case .yellow: String(localized: "Жовтий")
        }
    }

    /// Non-template colored dot for use in menus (macOS menus tint SF Symbols as templates).
    @MainActor
    var menuSwatch: NSImage {
        let size = NSSize(width: 12, height: 12)
        let image = NSImage(size: size, flipped: false) { rect in
            self.nsColor.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}

/// Grid geometry. Columns and visible rows come from `AppPreferences` (Settings); the defaults
/// (7 × 4) give the system Apps launcher's panel size (measured on macOS 27: 844 × 577 pt).
@MainActor
enum GridMetrics {
    static let iconSize: CGFloat = 64
    static let tileWidth: CGFloat = 108
    static let tileCorner: CGFloat = 15
    static var columns: Int { AppPreferences.shared.columns }
    static let folderColumns = 6
    /// Height of one grid row (tile + spacing), used to size the panel for `rows`.
    static let rowHeight: CGFloat = 116
    static var panelWidth: CGFloat { 844 + CGFloat(columns - 7) * tileWidth }
    static var panelHeight: CGFloat { 577 + CGFloat(AppPreferences.shared.rows - 4) * rowHeight }
    static let folderWidth: CGFloat = 680
    static let folderHeight: CGFloat = 450
}

/// Icons offered for folders in the "Іконка" menu: SF Symbols in groups, plus a fixed emoji palette.
///
/// `Folder.symbol` stays a plain string so the core needs no schema change: an SF Symbol name, or
/// `"emoji:<text>"` for an emoji. A text field (popover/sheet) would take key status and close the
/// panel, so emoji come from a fixed palette in a submenu instead of free input.
enum FolderSymbols {
    /// SF Symbols by theme, in menu order. Titles are localized when shown.
    static let groups: [(title: LocalizedStringResource, symbols: [String])] = [
        ("Робота", ["folder", "briefcase", "doc.text", "tray.full", "calendar", "envelope",
                     "chart.bar", "chart.pie", "list.bullet.clipboard", "signature"]),
        ("Розробка", ["hammer", "terminal", "wrench.and.screwdriver", "chevron.left.forwardslash.chevron.right",
                       "cpu", "server.rack", "ladybug", "shippingbox"]),
        ("Творчість", ["paintbrush", "paintpalette", "pencil.and.ruler", "camera", "photo",
                        "film", "music.note", "waveform", "mic"]),
        ("Інше", ["gamecontroller", "globe", "book", "graduationcap", "message", "person.2",
                   "cart", "creditcard", "heart", "star", "lock.shield", "gearshape", "cloud", "leaf"]),
    ]

    /// Every offered SF Symbol, flat.
    static let all: [String] = groups.flatMap(\.symbols)

    /// Emoji offered in the "Емодзі" submenu (stored as `emojiPrefix + emoji`).
    static let emoji: [String] = [
        "📁", "⭐️", "❤️", "🔥", "🎮", "🎵", "🎨", "📷",
        "🎬", "📚", "💼", "💻", "🛠️", "🧪", "📈", "💬",
        "🌍", "✈️", "🏠", "🛒", "💰", "🔒", "⚙️", "🚀",
    ]

    static let emojiPrefix = "emoji:"

    /// The emoji a stored folder symbol stands for, or nil when it is an SF Symbol name.
    static func emoji(in symbol: String) -> String? {
        guard symbol.hasPrefix(emojiPrefix) else { return nil }
        let text = String(symbol.dropFirst(emojiPrefix.count))
        return text.isEmpty ? nil : text
    }

    /// Stored form of an emoji folder icon.
    static func symbol(forEmoji emoji: String) -> String { emojiPrefix + emoji }
}

/// Draws a folder's `symbol`: the emoji text for "emoji:…", otherwise the SF Symbol. The one place
/// that interprets the stored string, so the tile, the open folder and menus stay consistent.
struct FolderSymbolImage: View {
    let symbol: String
    let size: CGFloat
    let color: Color

    var body: some View {
        if let emoji = FolderSymbols.emoji(in: symbol) {
            Text(verbatim: emoji)
                .font(.system(size: size * 1.15))
                .accessibilityHidden(true)
        } else {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
                .symbolRenderingMode(.hierarchical)
                .accessibilityHidden(true)
        }
    }
}

extension View {
    /// Applies `matchedGeometryEffect` only when a namespace is provided (previews pass nil).
    @ViewBuilder
    func matchedGeometry(id: some Hashable, in namespace: Namespace.ID?, isSource: Bool = true) -> some View {
        if let namespace {
            matchedGeometryEffect(id: id, in: namespace, isSource: isSource)
        } else {
            self
        }
    }

    /// Liquid Glass surface in `shape` (kept as a helper; the deployment target is macOS 26).
    func glassOrMaterial(in shape: some Shape) -> some View {
        glassEffect(.regular, in: shape)
    }
}

extension EnvironmentValues {
    /// True while the enclosing `TileButtonStyle` button is pressed. Lets a tile shrink just its
    /// artwork (not the label) on press.
    @Entry var isTilePressed = false
}

// Layout-persistence health shown in Settings.
//
// Data-loss transparency: when `LayoutStore` cannot use `layout.json` it moves the file aside
// (`layout.corrupt-<date>.json`) or leaves it in place when even that fails. The user must be told,
// because from their point of view the whole layout simply disappeared.
//
// Source of truth resolution, in order:
//  1. `GridModel.layoutHealth` — the core model reports the `LoadOutcome` of its store (preferred).
//  2. otherwise the store's own `layout.json` on disk is inspected directly, so the warning still
//     appears on builds whose core does not surface the outcome yet.
// The Settings row never writes anything: showing the notice does not "fix" the file.

/// What the user needs to know about the layout file right now.
enum LayoutHealth: Equatable {
    /// Everything is fine (file is present and readable, or there is nothing to warn about yet).
    case ok
    /// The unusable layout was moved aside; `quarantine` is where the old copy went.
    case quarantined(quarantine: URL)
    /// The unusable layout could NOT be moved aside, so saving is blocked to protect it.
    case quarantineFailedInPlace(file: URL)
    /// The file exists but could not be read (permissions, lock, I/O). It is untouched.
    case unreadable(file: URL, cause: String)
    /// Written by a newer MenuFold. Moved aside rather than rewritten in an older schema.
    case incompatible(quarantine: URL)

    /// The file the user should be shown in Finder, if any.
    var fileToReveal: URL? {
        switch self {
        case .ok: nil
        case .quarantined(let url), .incompatible(let url): url
        case .quarantineFailedInPlace(let url), .unreadable(let url, _): url
        }
    }

    var isWarning: Bool { self != .ok }

    /// One-line localized message; `fileName` keeps long paths out of the text.
    var message: String {
        switch self {
        case .ok:
            return ""
        case .quarantined(let url), .incompatible(let url):
            return String(localized: "Розкладку пошкоджено, попередню копію збережено в «\(url.lastPathComponent)».")
        case .quarantineFailedInPlace(let url):
            return String(localized: "Розкладку пошкоджено, але її не вдалося відкласти. Файл «\(url.lastPathComponent)» лишився на місці, збереження зупинено, щоб не втратити дані.")
        case .unreadable(let url, _):
            return String(localized: "Не вдалося прочитати розкладку («\(url.lastPathComponent)»). Файл не змінено — спробуйте перезапустити MenuFold.")
        }
    }

    /// Secondary detail line (cause / next step), nil when there is nothing to add.
    var detail: String? {
        switch self {
        case .ok:
            return nil
        case .quarantined(let url), .incompatible(let url):
            // Show the full location so the backup can be found without Finder.
            return url.deletingLastPathComponent().path
        case .quarantineFailedInPlace:
            return String(localized: "Закрийте MenuFold, зробіть копію файлу вручну й видаліть оригінал.")
        case .unreadable(_, let cause):
            return cause
        }
    }

    /// Builds the state from the core outcome when `GridModel` exposes one.
    /// Kept separate so the core API can be swapped in without touching the view.
    static func from(outcome: LoadOutcome, fileURL: URL, quarantineFailedInPlace: Bool) -> LayoutHealth {
        switch outcome {
        case .loaded, .missing:
            return .ok
        case .quarantined(let url):
            return quarantineFailedInPlace ? .quarantineFailedInPlace(file: fileURL) : .quarantined(quarantine: url)
        case .incompatible(let url):
            return .incompatible(quarantine: url)
        case .unreadable(let cause):
            return .unreadable(file: fileURL, cause: cause)
        }
    }

}

extension LayoutHealth {
    /// Reads the health the core model knows about: `GridModel.layoutOutcome` is the outcome of the
    /// actual load this session started with, so nothing has to be guessed from the filesystem.
    /// A store-less model (previews, tests) reports `.missing`, i.e. nothing to warn about.
    @MainActor
    static func current(model: GridModel) -> LayoutHealth {
        from(outcome: model.layoutOutcome,
             // The file this session really loaded (a custom data folder may hold it), not the default.
             fileURL: model.layoutFileURL ?? LayoutStore.defaultURL,
             quarantineFailedInPlace: model.quarantineFailedInPlace)
    }
}

/// Reveals the affected file in Finder (the quarantined copy, or the file that could not be moved).
@MainActor
enum LayoutHealthActions {
    static func reveal(_ health: LayoutHealth) {
        guard let url = health.fileToReveal else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

/// Plain tile button that publishes its pressed state to the label via `isTilePressed`.
/// The scale itself is applied by the tile artwork so the label text stays put.
struct TileButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.isTilePressed, configuration.isPressed)
            .contentShape(Rectangle())
    }
}

/// Quick staggered fade/scale-in of the first rows when the panel opens.
/// Delay grows with the row (capped after the 4th) plus a tiny per-column offset, so the whole
/// cascade finishes in about 0.25 s.
struct StaggeredReveal: ViewModifier {
    let index: Int
    let columns: Int
    let isRevealed: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let row = min(index / max(columns, 1), 3)
        let col = index % max(columns, 1)
        let delay = Double(row) * 0.035 + Double(col) * 0.004
        content
            .opacity(isRevealed || reduceMotion ? 1 : 0)
            .scaleEffect(isRevealed || reduceMotion ? 1 : 0.9)
            .animation(
                reduceMotion || !isRevealed ? nil : .smooth(duration: 0.12).delay(delay),
                value: isRevealed
            )
    }
}

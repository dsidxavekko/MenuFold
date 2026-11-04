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
        case .gray: "Сірий"
        case .blue: "Синій"
        case .green: "Зелений"
        case .orange: "Помаранчевий"
        case .red: "Червоний"
        case .purple: "Фіолетовий"
        case .pink: "Рожевий"
        case .yellow: "Жовтий"
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

enum GridMetrics {
    static let iconSize: CGFloat = 64
    static let tileWidth: CGFloat = 96
    static let tileCorner: CGFloat = 15
    static let columns = 7
    static let folderColumns = 6
    /// Same size as the system Apps launcher panel (measured on macOS 27: 844 × 577 pt).
    static let panelWidth: CGFloat = 844
    static let panelHeight: CGFloat = 577
    static let folderWidth: CGFloat = 680
    static let folderHeight: CGFloat = 450
}

/// SF Symbols offered for folders in the "Іконка" menu.
enum FolderSymbols {
    static let all: [String] = [
        "folder", "hammer", "gamecontroller", "paintbrush", "music.note",
        "briefcase", "globe", "wrench.and.screwdriver", "camera", "book",
        "terminal", "chart.bar",
    ]
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

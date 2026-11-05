import SwiftUI

/// Shared look & motion for MenuFold (macOS 26+ Liquid Glass). Use these instead of ad-hoc values
/// so the panel, grid, tabs and folders feel like one system.
enum Theme {
    // MARK: Motion
    /// Panel open/close, folder open/close (morphs).
    static let morph = Animation.spring(response: 0.42, dampingFraction: 0.86)
    /// Small UI feedback: hover, press, tab selection, drop targeting.
    static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.8)
    /// Content changes: tab switch, search results, items appearing/disappearing.
    static let content = Animation.smooth(duration: 0.28)
    /// Folder close: the reverse morph, a little quicker than `morph` so dismissal feels snappy.
    static let folderClose = Animation.spring(response: 0.34, dampingFraction: 0.9)
    /// Reduce Motion replacement for the morphs: a plain crossfade.
    static let crossfade = Animation.easeInOut(duration: 0.2)

    // MARK: Panel window motion (Core Animation, see PanelController)
    /// Spring response / damping of the panel open scale; a bit livelier than `morph` so the
    /// overshoot is visible, like the system Apps launcher.
    static let panelOpenResponse: CGFloat = 0.42
    static let panelOpenDamping: CGFloat = 0.74
    /// Scale the panel grows from when opening, and shrinks to when closing.
    static let panelOpenScale: CGFloat = 0.94
    static let panelCloseScale: CGFloat = 0.97
    /// Fade-in / close durations (seconds).
    static let panelFadeIn: TimeInterval = 0.2
    static let panelClose: TimeInterval = 0.18
    /// Content blur radius at the start of the open animation (sharpens to 0).
    static let panelOpenBlur: CGFloat = 8

    // MARK: Shape
    static let panelCorner: CGFloat = 26
    static let folderCorner: CGFloat = 30
    static let capsuleHeight: CGFloat = 30
    static let searchHeight: CGFloat = 46

    // MARK: Type (measured from the system Apps launcher; all regular weight)
    static let labelFont = Font.system(size: 13)
    static let tabFont = Font.system(size: 15)
    static let headerFont = Font.system(size: 26)

    // MARK: Folder overlay
    /// Blur radius of the grid behind an open folder.
    static let backdropBlur: CGFloat = 14
    /// Black dim over the grid behind an open folder.
    static let backdropDim: Double = 0.12

    // MARK: Feedback
    static let hoverScale: CGFloat = 1.06
    static let pressScale: CGFloat = 0.92
    static let dropTargetScale: CGFloat = 1.12

    // MARK: Keyboard selection
    /// Accent ring around the selected tile's icon (drawn just outside the icon).
    static let selectionRingWidth: CGFloat = 2
    static let selectionRingOpacity: Double = 0.75
    static let selectionRingInset: CGFloat = -4

    // MARK: Running dot (Dock-like, under the label)
    static let runningDotSize: CGFloat = 4
    static let runningDotColor = Color.primary.opacity(0.55)

    // MARK: "Часті" row
    /// Gap above and below the divider between the "Часті" row and the grid.
    static let frequentDividerSpacing: CGFloat = 8

    // MARK: Trash confirmation card
    static let cardCorner: CGFloat = 24
    static let cardWidth: CGFloat = 340
    /// Dim over the panel behind the card (stronger than a folder's: the card is modal).
    static let cardBackdropDim: Double = 0.18
}
